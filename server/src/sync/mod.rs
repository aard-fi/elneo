//! Continuous sync loop, sync event handlers, and room-summary derivation.
//!
//! Loop lifecycle: `handle_start_sync` runs a first `sync_once` so the
//! state store is filled before the seed pass reads it, seeds every room
//! (`updateRoom` per known room, `updateRoomMessages` for the initial
//! pages), spawns the room-key watchers for encryption, and then enters
//! the SDK's long-poll loop (30s timeout, callback form).  The loop only
//! returns on error; both error and the defensive plain return sleep 5s
//! and restart, and every transition is announced with `updateSyncState`
//! ("syncing" -> "synced", or "error") so the client can display and
//! schedule around connection health.  Handlers are registered when the
//! client is installed (login/session restore), not per `startSync` — a
//! failed-then-retried sync must not fire each handler twice.
//!
//! Dispatch-arm shape: the daemon registry calls each handler with its
//! command's own parameters — no `Value` picking beyond the parse.
//!
//! Room summaries: `room_summary` merges the SDK's room state with a
//! local `RoomLocal` (unread/highlight counters, marker positions).
//! Invited rooms have no timeline local content is derived from, so they
//! run on a bare default local.  The `room_state` field distinguishes
//! "joined" from "invited"; invited rooms ride the ordinary room list
//! so the client can offer accept/decline.
//!
//! Change events: edits (`updateEdited`), reactions and read receipts
//! (`updateReactions`, `updateReadReceipts`) arrive as full refreshed
//! lists per event/room — consumers may always replace whatever they
//! hold, no merge logic client-side.  Both must not touch room-bar
//! unread state (only new messages move counters).

use std::collections::{HashMap, HashSet};
use std::time::Duration;

use futures::{future::join_all, StreamExt};
use matrix_sdk::config::SyncSettings;
use matrix_sdk::ruma::events::{
    poll::end::OriginalSyncPollEndEvent,
    poll::response::OriginalSyncPollResponseEvent,
    poll::start::{OriginalSyncPollStartEvent, PollStartEventContent},
    reaction::{OriginalSyncReactionEvent, ReactionEventContent},
    relation::{Annotation, RelationType, Reply, Thread},
    room::encrypted::RoomEncryptedEventContent,
    room::member::{MembershipChange, OriginalSyncRoomMemberEvent, SyncRoomMemberEvent},
    room::message::{
        FormattedBody, MessageFormat, MessageType, OriginalSyncRoomMessageEvent, Relation,
        RoomMessageEventContent,
    },
    room::name::OriginalSyncRoomNameEvent,
    room::redaction::{OriginalSyncRoomRedactionEvent, SyncRoomRedactionEvent},
    room::MediaSource,
    sticker::StickerEventContent,
    AnySyncEphemeralRoomEvent, AnySyncMessageLikeEvent, AnySyncStateEvent, AnySyncTimelineEvent,
    SyncMessageLikeEvent,
};
use matrix_sdk::{
    deserialized_responses::{EncryptionInfo, TimelineEvent, VerificationLevel, VerificationState},
    notification_settings::RoomNotificationMode,
    room::{IncludeRelations, MessagesOptions, RelationsOptions},
    ruma::{
        api::client::filter::RoomEventFilter, api::Direction, serde::Raw, OwnedRoomId, OwnedUserId,
        RoomId, UInt, UserId,
    },
    Client, LoopCtrl, Room, RoomMemberships, RoomState,
};
use tracing::{debug, info, warn};

use crate::daemon::SharedDaemon;
use crate::protocol::{
    Event, HierarchyRoom, MediaEntry, MemberEntry, Mentions, MessageEntry, OutEvent, PollEntry,
    PollOption, ReactionEntry, ReceiptEntry, RoomSummary, SendInfo,
};

/// Aggregated reaction state: target event id -> key -> reaction event id ->
/// sender.  Keying the innermost map by reaction event id makes live and
/// backfill merges idempotent — the same reaction arriving twice just
/// overwrites its own entry.
pub type ReactionState = HashMap<String, HashMap<String, HashMap<String, String>>>;

/// One folded edit (`m.replace`): the winning — newest — replacement
/// for a target event, carrying the edit's own timestamp.
#[derive(Debug, Clone, PartialEq)]
pub struct EditInfo {
    pub msgtype: String,
    pub body: String,
    /// `org.matrix.custom.html` version of `body`, when the edit
    /// carries one.
    pub formatted_body: Option<String>,
    pub media: Option<MediaEntry>,
    /// A `geo:` URI when the edited content is a location (see
    /// `ContentDisplay.geo`).
    pub geo: Option<String>,
    /// `m.mentions` (MSC3952) of the edited content; edits never
    /// alert, this keeps the folded view data-complete.
    pub mentions: Option<Mentions>,
    pub ts: u64,
}

/// Aggregated edit state: target event id -> newest replacement.
pub type EditState = HashMap<String, EditInfo>;

/// One folded thread (MSC3440): the newest reply's event id and ts, so
/// a send can name the thread's latest event in the fallback relation
/// thread-less clients use to follow a thread.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ThreadInfo {
    pub latest_event_id: Option<String>,
    pub latest_ts: Option<u64>,
}

/// Aggregated thread state: root event id -> newest reply.
pub type ThreadState = HashMap<String, ThreadInfo>;

/// Thread member event id -> its thread root.  Lookup map for redaction
/// book-keeping and sends; populated from live sync and backfill alike.
pub type ThreadOf = HashMap<String, String>;

/// Aggregated poll state (MSC3381): poll start event id -> poll.  Live
/// sync and history backfill fold into the same map, like `reactions`.
pub type PollState = HashMap<String, PollVotes>;

/// The data one `m.poll.start` (original or its `m.replace` edit)
/// carries.  Kept raw-ish: the wire kind string is preserved verbatim
/// so custom kinds render as undisclosed rather than guessing.
#[derive(Debug, Clone, PartialEq)]
pub struct PollStartInfo {
    /// The raw `m.poll.kind` value (`m.disclosed` / `m.undisclosed` or
    /// a client's custom kind).
    pub kind: String,
    pub max_selections: u64,
    pub question: String,
    /// Answer `(m.id, text)` pairs in wire order.
    pub answers: Vec<(String, String)>,
    /// Origin ts of the winning start content (original or newest
    /// edit) — the merge tiebreaker and the prune key.
    pub ts: u64,
}

/// One folded `m.poll.response`: who voted what, and when.
#[derive(Debug, Clone, PartialEq)]
pub struct PollVoteRecord {
    pub sender: String,
    pub ts: u64,
    /// The raw `m.selections`; validated against the poll's answers
    /// (and capped to its `max_selections`) at projection time, so a
    /// response folded before its start still holds everything.
    pub selections: Vec<String>,
}

/// One poll's fold.  `start` is missing when a response arrived before
/// the start did (a backfill page splits them, or the start predates
/// this daemon's history window); `replaces` maps the edit ids a
/// response/`poll.end` may name back to this poll.
#[derive(Debug, Clone, Default)]
pub struct PollVotes {
    pub start: Option<PollStartInfo>,
    /// An `m.poll.end` folded; ts of the end event.  Responses past it
    /// stop counting.
    pub ended: Option<u64>,
    /// `m.replace` event ids whose new content is this poll.
    pub replaces: Vec<String>,
    /// Responses by their own event id (live + backfill merge
    /// idempotent, like reactions).
    pub responses: HashMap<String, PollVoteRecord>,
}

/// Mutable sibling of [`poll_id_of`].
fn poll_votes_of_mut<'s>(state: &'s mut PollState, target: &str) -> Option<&'s mut PollVotes> {
    if state.contains_key(target) {
        return state.get_mut(target);
    }
    let poll_id = state
        .iter()
        .find(|(_, votes)| votes.replaces.iter().any(|id| id == target))
        .map(|(id, _)| id.clone())?;
    state.get_mut(&poll_id)
}

/// Fold one `m.poll.start` — original (`poll_id` is the event's own id)
/// or replacement edit (`poll_id` is the edited event's id,
/// `replacement_event_id` the edit's) — into the poll state.  A newer
/// content wins; re-folding the same event is a no-op.  An entry keyed
/// by the replacement event id (votes that folded before their edit
/// arrived, under the edit id) merges back in.
fn merge_poll_start(
    state: &mut PollState,
    poll_id: &str,
    replacement_event_id: Option<&str>,
    info: PollStartInfo,
) {
    let drift = match replacement_event_id {
        Some(repl) if repl != poll_id => state.remove(repl),
        _ => None,
    };
    let votes = state.entry(poll_id.to_owned()).or_default();
    if let Some(removed) = drift {
        for (id, rec) in removed.responses {
            votes.responses.entry(id).or_insert(rec);
        }
        for r in removed.replaces {
            if r != poll_id && !votes.replaces.contains(&r) {
                votes.replaces.push(r);
            }
        }
        if votes.start.is_none() {
            votes.start = removed.start;
        }
        if votes.ended.is_none() {
            votes.ended = removed.ended;
        }
    }
    if let Some(repl) = replacement_event_id {
        if repl != poll_id && !votes.replaces.iter().any(|x| x == repl) {
            votes.replaces.push(repl.to_owned());
        }
    }
    if votes.start.as_ref().is_none_or(|old| old.ts <= info.ts) {
        votes.start = Some(info);
    }
}

/// Fold one `m.poll.response` into the poll state (target = the event
/// the response references).  Unresolvable targets fold under the raw
/// id — the start may still arrive and unify, since its own state key
/// is its id.
fn merge_poll_response(
    state: &mut PollState,
    target: &str,
    event_id: &str,
    sender: &str,
    ts: u64,
    selections: Vec<String>,
) {
    state
        .entry(target.to_owned())
        .or_default()
        .responses
        .entry(event_id.to_owned())
        .or_insert(PollVoteRecord {
            sender: sender.to_owned(),
            ts,
            selections,
        });
}

/// Fold one `m.poll.end`.
fn merge_poll_end(state: &mut PollState, target: &str, ts: u64) {
    let votes = match poll_votes_of_mut(state, target) {
        Some(votes) => votes,
        None => {
            // The end landed first; key it under the raw target id.
            state.entry(target.to_owned()).or_default()
        }
    };
    votes.ended = Some(votes.ended.map_or(ts, |old| old.min(ts)));
}

/// Fold a redaction into the poll state: a redacted response record is
/// just dropped (an earlier response from that voter survives, which is
/// how the spec orders it); a redacted start removes the poll
/// entirely.  Returns the affected poll ids — start removals first —
/// so the caller re-renders each.
fn poll_redaction(state: &mut PollState, redacted_event_id: &str) -> Vec<String> {
    let mut affected: Vec<(String, bool)> = Vec::new();
    let mut to_remove: Vec<String> = Vec::new();
    for (poll_id, votes) in state.iter_mut() {
        if votes.responses.remove(redacted_event_id).is_some() {
            affected.push((poll_id.clone(), false));
        } else if poll_id == redacted_event_id {
            to_remove.push(poll_id.clone());
        }
    }
    for id in to_remove {
        affected.push((id.clone(), true));
        state.remove(&id);
    }
    affected.into_iter().map(|(id, _)| id).collect()
}

/// One voter's effective selections, validated against the poll:
/// known answer ids only, capped to `max_selections`, and empty when
/// their response is gone (redacted).
///
/// Returns the per-option aggregates: `(count, voters, own_ids)` — the
/// count is the number of voters per option, voters are user ids in
/// first-vote order (capped at [`VOTERS_SHOWN_MAX`]), own_ids the own
/// account's picks.
fn effective_votes(
    votes: &PollVotes,
    own_user_id: &str,
) -> (Vec<u64>, Vec<Vec<String>>, Vec<String>) {
    let max = votes
        .start
        .as_ref()
        .map(|s| s.max_selections as usize)
        .unwrap_or(1);
    let option_pos: HashMap<&str, usize> = votes
        .start
        .as_ref()
        .map(|s| {
            s.answers
                .iter()
                .enumerate()
                .map(|(i, (id, _))| (id.as_str(), i))
                .collect()
        })
        .unwrap_or_default();
    // One response per voter counts — the newest non-redacted, not
    // behind an end event.  Ties (same ts, sync replays) order by the
    // response event id.
    let mut effective: HashMap<String, (&PollVoteRecord, (u64, String))> = HashMap::new();
    for (id, rec) in &votes.responses {
        if votes.ended.is_some_and(|end| rec.ts > end) {
            continue;
        }
        let key = (rec.ts, id.clone());
        match effective.get_mut(&rec.sender) {
            Some(slot) if slot.1 >= key => {}
            Some(slot) => *slot = (rec, key),
            None => {
                effective.insert(rec.sender.clone(), (rec, key));
            }
        }
    }
    let mut by_key: Vec<(&PollVoteRecord, (u64, String))> = effective.into_values().collect();
    by_key.sort_by_key(|(_, key)| key.clone());

    let len = votes.start.as_ref().map(|s| s.answers.len()).unwrap_or(0);
    let mut counts: Vec<u64> = vec![0; len];
    let mut voters: Vec<Vec<String>> = vec![Vec::new(); len];
    let mut own_ids: Vec<String> = Vec::new();
    for (rec, _) in by_key {
        let own = rec.sender == own_user_id;
        let mut used = 0usize;
        for sel in &rec.selections {
            if used >= max {
                break;
            }
            let Some(&pos) = option_pos.get(sel.as_str()) else {
                continue;
            };
            if voters[pos].contains(&rec.sender) {
                // A duplicate id inside one response: the first counts.
                continue;
            }
            counts[pos] += 1;
            if voters[pos].len() < VOTERS_SHOWN_MAX {
                voters[pos].push(rec.sender.clone());
            }
            used += 1;
            if own {
                own_ids.push(sel.clone());
            }
        }
    }
    (counts, voters, own_ids)
}

/// How many voter ids a poll option ships at most (the count comes
/// from folding, not from this list's length).
const VOTERS_SHOWN_MAX: usize = 100;

/// The fold data of one `m.poll.start` content block.  The question
/// and answers read their plain-text representation, falling back to
/// the answer id for answers without one.
fn poll_start_info(
    poll: &matrix_sdk::ruma::events::poll::start::PollContentBlock,
    ts: u64,
) -> PollStartInfo {
    PollStartInfo {
        kind: poll.kind.to_string(),
        max_selections: u64::from(poll.max_selections),
        question: poll.question.text.find_plain().unwrap_or("").to_owned(),
        answers: poll
            .answers
            .iter()
            .map(|a| {
                (
                    a.id.clone(),
                    a.text
                        .find_plain()
                        .map_or_else(|| a.id.clone(), |t| t.to_owned()),
                )
            })
            .collect(),
        ts,
    }
}

/// Whether a wire poll-kind string (any client's namespace spelling)
/// discloses results before the poll ends.  The final spec uses
/// `m.disclosed`, Element's parsers `m.poll.disclosed` and the MSC3381
/// unstable revision `org.matrix.msc3381.poll.disclosed`.
fn kind_is_disclosed(kind: &str) -> bool {
    matches!(
        kind,
        "m.disclosed" | "m.poll.disclosed" | "org.matrix.msc3381.poll.disclosed"
    )
}

/// The poll event kind behind a wire event type, stable (`m.`) or
/// MSC3381-unstable (`org.matrix.msc3381.`) namespace.
#[derive(Debug, Clone, Copy, PartialEq)]
enum PollEventKind {
    Start,
    Response,
    End,
}

fn poll_wire_kind(event_type: &str) -> Option<PollEventKind> {
    let suffix = event_type
        .strip_prefix("org.matrix.msc3381.")
        .unwrap_or(event_type.strip_prefix("m.").unwrap_or(""));
    match suffix {
        "poll.start" => Some(PollEventKind::Start),
        "poll.response" => Some(PollEventKind::Response),
        "poll.end" => Some(PollEventKind::End),
        _ => None,
    }
}

/// Plain text from an extensible-text field: a string (Element's wire
/// form) or the block array the spec uses, else empty.
fn poll_plain_text(v: Option<&serde_json::Value>) -> String {
    match v {
        Some(serde_json::Value::String(s)) => s.clone(),
        // Each block carries `m.body` (spec) or `body`/`mimetype`; the
        // first plain-text block wins, like ruma's find_plain.
        Some(serde_json::Value::Array(blocks)) => blocks
            .iter()
            .filter(|b| {
                b.get("mimetype")
                    .and_then(serde_json::Value::as_str)
                    .is_none_or(|mime| mime == "text/plain")
            })
            .find_map(|b| {
                b.get("m.body")
                    .or_else(|| b.get("body"))
                    .and_then(serde_json::Value::as_str)
            })
            .unwrap_or("")
            .to_owned(),
        _ => String::new(),
    }
}

/// Plain text out of a poll text field: the spec `m.text` block or the
/// MSC1767 unstable string form.
fn poll_text_field(v: &serde_json::Value) -> String {
    poll_plain_text(v.get("m.text").or_else(|| v.get("org.matrix.msc1767.text")))
}

/// A block-array `m.text` with one plain-text entry.
fn poll_text_block(text: &str) -> serde_json::Value {
    serde_json::json!([{ "mimetype": "text/plain", "body": text }])
}

/// The spec `m.poll` payload block for a start, built from one of the
/// client-compat blocks Element and pre-spec clients send (keys `id`
/// without the `m.` prefix, string texts, `m.poll.`-prefixed kinds).
/// `None` when the foreign block carries no answers.
fn poll_spec_block(block: &serde_json::Value) -> Option<serde_json::Value> {
    let answers = block.get("answers")?.as_array()?;
    let kind = match block.get("kind").and_then(serde_json::Value::as_str) {
        Some("m.disclosed")
        | Some("m.poll.disclosed")
        | Some("org.matrix.msc3381.poll.disclosed") => "m.disclosed",
        _ => "m.undisclosed",
    };
    let max_selections = block
        .get("max_selections")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(1)
        .max(1);
    let answers = answers
        .iter()
        .filter_map(|a| {
            let id = a
                .get("m.id")
                .or_else(|| a.get("id"))
                .and_then(serde_json::Value::as_str)?;
            let mut text = poll_text_field(a);
            if text.is_empty() {
                text = id.to_owned();
            }
            Some(serde_json::json!({ "m.id": id, "m.text": poll_text_block(&text) }))
        })
        .collect::<Vec<_>>();
    (!answers.is_empty()).then(|| {
        serde_json::json!({
            "kind": kind,
            "max_selections": max_selections,
            "question": {
                "m.text": poll_text_block(&poll_text_field(
                    block.get("question").unwrap_or(&serde_json::Value::Null),
                )),
            },
            "answers": answers,
        })
    })
}

/// Re-shape one raw poll event's content into the final MSC3381 payload
/// form, in place.  Element and pre-spec clients ship the legacy
/// blocks (`m.poll.start`, `org.matrix.msc3381.poll.*`), string text
/// fields and Element's answer shape — the typed ruma contents cannot
/// parse those, so this folds everything into the spec keys (`m.poll`
/// block, `m.selections`, block-array `m.text`).  Events that already
/// follow the spec pass through unchanged, as do non-poll events.
fn normalize_poll_event(ev: &mut serde_json::Value) {
    let Some(event_type) = ev.get("type").and_then(serde_json::Value::as_str) else {
        return;
    };
    let Some(kind) = poll_wire_kind(event_type) else {
        return;
    };
    let Some(content) = ev
        .get_mut("content")
        .and_then(serde_json::Value::as_object_mut)
    else {
        return;
    };
    match kind {
        PollEventKind::Start => {
            // A poll edit (`m.replace`) carries its new payload at the
            // content top level (`m.new_content`); normalize there
            // instead — the typed Replacement variant reads exactly
            // this block, and no top-level spec block of the edited
            // event must be invented.
            if content
                .get("m.relates_to")
                .and_then(|r| r.get("rel_type"))
                .and_then(serde_json::Value::as_str)
                == Some("m.replace")
            {
                // The new payload block: `m.new_content` at the content
                // top (the standard replacement shape), else the
                // nested-under-the-relation spelling.
                let new_content = if let Some(nc) = content.get_mut("m.new_content") {
                    Some(nc)
                } else {
                    content
                        .get_mut("m.relates_to")
                        .and_then(|r| r.get_mut("m.new_content"))
                };
                if let Some(new_content) = new_content.and_then(serde_json::Value::as_object_mut) {
                    let foreign = ["m.poll.start", "org.matrix.msc3381.poll.start"]
                        .iter()
                        .find_map(|key| new_content.get(*key).filter(|b| b.is_object()))
                        .cloned();
                    if let Some(block) = foreign.and_then(|b| poll_spec_block(&b)) {
                        new_content.insert("m.poll".to_owned(), block);
                    }
                    // The typed replacement's embedded content wants
                    // its fallback text to parse.
                    if !new_content.contains_key("m.text") {
                        let text = new_content
                            .get("m.poll")
                            .map(|b| {
                                poll_text_field(
                                    b.get("question").unwrap_or(&serde_json::Value::Null),
                                )
                            })
                            .unwrap_or_default();
                        new_content.insert("m.text".to_owned(), poll_text_block(&text));
                    }
                }
                // The stable typed content still reads the top-level
                // `m.poll`/`m.text` even on a replacement; mirror the
                // new content's block there.
                if content.get("m.poll").is_none_or(|b| !b.is_object()) {
                    if let Some(block) = content
                        .get("m.new_content")
                        .and_then(|nc| nc.get("m.poll"))
                        .filter(|b| b.is_object())
                        .cloned()
                    {
                        content.insert("m.poll".to_owned(), block);
                    }
                }
                if !content.contains_key("m.text") {
                    let text = poll_text_field(
                        content
                            .get("m.poll")
                            .and_then(|b| b.get("question"))
                            .unwrap_or(&serde_json::Value::Null),
                    );
                    content.insert("m.text".to_owned(), poll_text_block(&text));
                }
                return;
            }
            // The spec block wins; otherwise build it from the
            // foreign one (Element's `m.poll.start` or the unstable
            // revision).
            if content.get("m.poll").is_none_or(|b| !b.is_object()) {
                let foreign = ["m.poll.start", "org.matrix.msc3381.poll.start"]
                    .iter()
                    .find_map(|key| content.get(*key).filter(|b| b.is_object()))
                    .cloned();
                if let Some(block) = foreign.and_then(|b| poll_spec_block(&b)) {
                    content.insert("m.poll".to_owned(), block);
                }
            }
            // The fallback `m.text`: Element sends it as a string, the
            // unstable revision as `org.matrix.msc1767.text` — both
            // become the block array the typed content wants.  From
            // the question when nothing shipped.
            let has_text_array = content
                .get("m.text")
                .is_some_and(serde_json::Value::is_array);
            if !has_text_array {
                let text = content
                    .get("m.text")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned)
                    .or_else(|| {
                        content
                            .get("org.matrix.msc1767.text")
                            .and_then(serde_json::Value::as_str)
                            .map(str::to_owned)
                    })
                    .unwrap_or_else(|| {
                        content
                            .get("m.poll")
                            .map(|b| {
                                poll_text_field(
                                    b.get("question").unwrap_or(&serde_json::Value::Null),
                                )
                            })
                            .unwrap_or_default()
                    });
                content.insert("m.text".to_owned(), poll_text_block(&text));
            }
        }
        PollEventKind::Response => {
            // Element keeps its selections inside the block, the spec
            // expects them at the top level.
            if content.get("m.selections").is_none() {
                let answers = ["m.poll.response", "org.matrix.msc3381.poll.response"]
                    .iter()
                    .find_map(|key| content.get(*key).and_then(|b| b.get("answers")))
                    .filter(|a| a.is_array())
                    .cloned();
                if let Some(answers) = answers {
                    content.insert("m.selections".to_owned(), answers);
                }
            }
        }
        PollEventKind::End => {
            // The typed end content requires a block-array `m.text`;
            // Element sends a string.
            let has_text_array = content
                .get("m.text")
                .is_some_and(serde_json::Value::is_array);
            if !has_text_array {
                let text = content
                    .get("m.text")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("Poll ended");
                content.insert("m.text".to_owned(), poll_text_block(text));
            }
        }
    }
}

/// A typed `m.poll.start` event from its raw JSON, with foreign
/// payloads (Element and pre-spec clients) normalized into the final
/// spec form first.  Shared by the stable and unstable live handlers —
/// the wire event type does not matter for the typed parse.
fn poll_start_typed(json: &str) -> Option<OriginalSyncPollStartEvent> {
    normalized_typed(json)
}

/// Typed `T` from raw JSON parsed into a normalized `Value` — the
/// parse -> `normalize_poll_event` -> re-serialize -> deserialize dance
/// in one helper, shared by the poll wrappers (and the unstable
/// re-typing, which rewrites `type` in between).
fn normalized_typed<T: serde::de::DeserializeOwned>(json: &str) -> Option<T> {
    let mut val = serde_json::from_str::<serde_json::Value>(json).ok()?;
    normalize_poll_event(&mut val);
    raw_deserialized(&val)
}

/// The tail of the dance: a `Value` (already in wire shape) back
/// through `Raw` into the typed event.
fn raw_deserialized<T: serde::de::DeserializeOwned>(val: &serde_json::Value) -> Option<T> {
    Raw::<T>::from_json_string(val.to_string())
        .ok()?
        .deserialize()
        .ok()
}

/// The stable-typed event behind a poll event's raw JSON: the
/// MSC3381-unstable revision swaps to the stable type name, the shape
/// normalizes (see `normalize_poll_event`), the result re-parses as
/// `AnySyncTimelineEvent`.  Clients that never migrated to the stable
/// types (older Element poll builds, FluffyChat) send the revision —
/// ruma's typed parse handles it, but only the stable variants are
/// known to the backfill fold and render passes.  `None` when the
/// re-parse fails (with the stable name kept, e.g. for a foreign
/// `m.poll.start` block shape).
fn unstable_poll_retyped(event_type: &str, json: &str) -> Option<AnySyncTimelineEvent> {
    let stable_type = event_type
        .strip_prefix("org.matrix.msc3381.")
        .map(|suffix| format!("m.{suffix}"))
        .unwrap_or_else(|| event_type.to_owned());
    let mut val = serde_json::from_str::<serde_json::Value>(json).ok()?;
    val["type"] = stable_type.into();
    normalize_poll_event(&mut val);
    raw_deserialized(&val)
}

/// The typed `m.poll.response` behind raw JSON, foreign shapes
/// normalized (see `normalize_poll_event`).
fn poll_response_typed(json: &str) -> Option<OriginalSyncPollResponseEvent> {
    normalized_typed(json)
}

/// The typed `m.poll.end` behind raw JSON, foreign shapes normalized
/// (see `normalize_poll_event`).
fn poll_end_typed(json: &str) -> Option<OriginalSyncPollEndEvent> {
    normalized_typed(json)
}

/// The room's newest-timeline-event pointer, updated per folded event
/// whether or not it renders a line: reactions, poll votes, edits and
/// redactions exist in the timeline and can carry it further on, and
/// in an encrypted room the server counts every ciphertext event
/// unread (`.m.rule.encrypted` fires without decryption) — the
/// read-marker fallback must be able to pass over them.  The bar's
/// display state (activity, preview) is a separate field on
/// `RoomLocal`; see `on_reaction`.
fn note_last_event(local: &mut RoomLocal, event_id: &str) {
    local.last_event_id = Some(event_id.to_owned());
}

/// Project one poll onto the wire entry.  `None` when the poll has no
/// fold (nothing in this session's state).
fn poll_entry(state: &PollState, poll_id: &str, own_user_id: &str) -> Option<PollEntry> {
    let votes = state.get(poll_id)?;
    let start = votes.start.as_ref()?;
    // Undisclosed polls keep their intermediate results off the wire;
    // the own vote stays visible (voters see what they picked).
    let results_visible = kind_is_disclosed(&start.kind) || votes.ended.is_some();
    let (counts, voters, own_ids) = effective_votes(votes, own_user_id);
    let options = start
        .answers
        .iter()
        .enumerate()
        .map(|(i, (id, text))| {
            let own = own_ids.iter().any(|sel| sel == id);
            let (count, these_voters) = if results_visible || (own && counts[i] > 0) {
                (counts[i], voters[i].clone())
            } else {
                (u64::from(own), Vec::new())
            };
            PollOption {
                id: id.clone(),
                text: text.clone(),
                count,
                own,
                voters: if results_visible {
                    these_voters
                } else {
                    Vec::new()
                },
            }
        })
        .collect();
    Some(PollEntry {
        question: start.question.clone(),
        kind: start.kind.clone(),
        max_selections: start.max_selections,
        options,
        ended: votes.ended.is_some(),
    })
}

/// Fold one replacement into the room's edit state.  Newest edit wins;
/// re-folding the same edit (live and backfill overlap) is a no-op.
fn merge_edit(edits: &mut EditState, target: &str, info: EditInfo) {
    if edits.get(target).is_none_or(|old| old.ts <= info.ts) {
        edits.insert(target.to_owned(), info);
    }
}

/// What one message content renders as: the wire msgtype, body,
/// formatted body and media metadata.
struct ContentDisplay {
    msgtype: String,
    body: String,
    formatted_body: Option<String>,
    media: Option<MediaEntry>,
    /// A `geo:` URI for `m.location` (MSC3489); Emacs turns it into an
    /// OSM link.  Absent for protocol-2-era daemons and every other
    /// msgtype.
    geo: Option<String>,
    /// `m.mentions` (MSC3952), read from the same raw JSON, when the
    /// sender sent the block.
    mentions: Option<Mentions>,
}

/// MSC3245 voice-note details from a raw message content JSON.  ruma's
/// typed content drops the unstable `m.voice` / `m.audio` blocks, so
/// these are read from the event JSON directly.
#[derive(Debug, Clone, PartialEq)]
struct VoiceInfo {
    /// Duration in milliseconds (`m.audio.duration`; some senders keep
    /// it only in `info.duration`, which the media entry carries).
    duration: Option<u64>,
    /// Waveform amplitudes, clamped to 0..=1024 (MSC3246).
    waveform: Vec<u32>,
}

/// Voice-note details from a raw `m.room.message` content JSON, or
/// `None` when it is not a voice message.  A voice message carries one
/// of the marker blocks — `m.voice` (the current draft name, also used
/// by Element), `org.matrix.msc3245.voice` or the ancient
/// `org.matrix.msc2516.voice` — with the duration and waveform in the
/// `m.audio` block (`org.matrix.msc1767.audio` in extensible-event-era
/// clients).  Waveform values are clamped, and a hostile oversize
/// array is capped, so the wire entry stays small no matter what the
/// sender shipped.
fn voice_info(content: &serde_json::Value) -> Option<VoiceInfo> {
    const MARKERS: [&str; 3] = [
        "m.voice",
        "org.matrix.msc3245.voice",
        "org.matrix.msc2516.voice",
    ];
    if !MARKERS.iter().any(|k| content.get(k).is_some()) {
        return None;
    }
    let audio = content
        .get("m.audio")
        .or_else(|| content.get("org.matrix.msc1767.audio"));
    let duration = audio
        .and_then(|a| a.get("duration"))
        .and_then(serde_json::Value::as_f64)
        .filter(|d| d.is_finite() && *d >= 0.0)
        .map(|d| d.round() as u64);
    let waveform = audio
        .and_then(|a| a.get("waveform"))
        .and_then(serde_json::Value::as_array)
        .map(|a| {
            a.iter()
                .take(1024)
                .filter_map(|v| v.as_f64())
                .filter(|v| v.is_finite())
                .map(|v| v.round().clamp(0.0, 1024.0) as u32)
                .collect()
        })
        .unwrap_or_default();
    Some(VoiceInfo { duration, waveform })
}

/// `m.mentions` (MSC3952) from a raw `m.room.message` content JSON,
/// or `None` when the sender sent no block (or an empty one).  ruma's
/// typed content drops it, so the raw JSON is read like the voice
/// blocks.  The spec key comes first (`m.mentions`, what ruma and
/// Element-family clients ship); some very early MSC3952 builds used
/// the `.m.mentions` spelling — accepted as a fallback so an old
/// client's mention still alerts.
fn mentions_info(content: &serde_json::Value) -> Option<Mentions> {
    let mentions = content
        .get("m.mentions")
        .or_else(|| content.get(".m.mentions"))?;
    let user_ids: Vec<String> = mentions
        .get("user_ids")
        .and_then(serde_json::Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(serde_json::Value::as_str)
                .take(64)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default();
    let room = mentions
        .get("room")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    if user_ids.is_empty() && !room {
        return None;
    }
    Some(Mentions { user_ids, room })
}

/// Build the `.m.mentions` block for an outgoing message from client
/// supplied user-id strings and the `@room` everyone-flag.  Ids that
/// fail to parse are skipped (a malformed mention must not break the
/// send); a room flag with or without ids means a block with
/// `.room: true`, otherwise no block at all.
fn mentions_from(ids: &[String], room: bool) -> Option<matrix_sdk::ruma::events::Mentions> {
    let user_ids: Vec<matrix_sdk::ruma::OwnedUserId> = ids
        .iter()
        .filter_map(|id| matrix_sdk::ruma::UserId::parse(id).ok())
        .take(64)
        .collect();
    if user_ids.is_empty() && !room {
        return None;
    }
    let mut mentions = matrix_sdk::ruma::events::Mentions::with_user_ids(user_ids);
    mentions.room = room;
    Some(mentions)
}

/// Extract the display pieces for one message content.  Shared by the
/// live new-message handler, the history fold and edit new-content
/// extraction.  `None` means "do not render at all".  `content` is the
/// event's raw content JSON — voice messages hide their marker and
/// waveform in unstable blocks the typed content drops — and `None`
/// covers callers without raw JSON at hand (tests).
fn content_display(
    msgtype: &MessageType,
    content: Option<&serde_json::Value>,
) -> Option<ContentDisplay> {
    // Every arm carries the block when the sender sent one.
    let mentions = content.and_then(mentions_info);
    Some(match msgtype {
        MessageType::Text(t) => ContentDisplay {
            msgtype: "m.text".to_owned(),
            body: t.body.clone(),
            formatted_body: formatted_html(&t.formatted),
            media: None,
            geo: None,
            mentions: mentions.clone(),
        },
        MessageType::Notice(t) => ContentDisplay {
            msgtype: "m.notice".to_owned(),
            body: t.body.clone(),
            formatted_body: formatted_html(&t.formatted),
            media: None,
            geo: None,
            mentions: mentions.clone(),
        },
        MessageType::Emote(t) => ContentDisplay {
            msgtype: "m.emote".to_owned(),
            body: t.body.clone(),
            formatted_body: formatted_html(&t.formatted),
            media: None,
            geo: None,
            mentions: mentions.clone(),
        },
        // Media and other non-text content: keep the event (dimmed in
        // Emacs) so media-heavy rooms do not render empty.  Every
        // media-bearing type ships its media metadata so Emacs can
        // download/open it.  Each arm binds `info` once — ruma's
        // image/file/audio info structs carry the same members but no
        // common trait, so `media_entry` reads the fields the arm
        // passes.
        MessageType::Image(t) => {
            let info = t.info.as_ref();
            ContentDisplay {
                media: Some(media_entry(
                    &t.source,
                    None,
                    info.and_then(|i| i.mimetype.clone()),
                    info.and_then(|i| i.size).map(u64::from),
                    None,
                    info.and_then(|i| i.width).map(u64::from),
                    info.and_then(|i| i.height).map(u64::from),
                    info.and_then(|i| i.thumbnail_source.as_ref()),
                )),
                msgtype: "m.image".to_owned(),
                body: t.body.clone(),
                formatted_body: None,
                geo: None,
                mentions: mentions.clone(),
            }
        }
        MessageType::File(t) => {
            let info = t.info.as_ref();
            ContentDisplay {
                media: Some(media_entry(
                    &t.source,
                    t.filename.clone(),
                    info.and_then(|i| i.mimetype.clone()),
                    info.and_then(|i| i.size).map(u64::from),
                    None,
                    None,
                    None,
                    info.and_then(|i| i.thumbnail_source.as_ref()),
                )),
                msgtype: "m.file".to_owned(),
                body: t.body.clone(),
                formatted_body: None,
                geo: None,
                mentions: mentions.clone(),
            }
        }
        MessageType::Audio(t) => {
            // Voice notes (MSC3245) ship duration and waveform in the
            // unstable `m.audio` block, not in `info` — only the raw
            // JSON knows.  The block's duration wins when both exist.
            let voice = content.and_then(voice_info);
            let info = t.info.as_ref();
            let mut media = media_entry(
                &t.source,
                None,
                info.and_then(|i| i.mimetype.clone()),
                info.and_then(|i| i.size).map(u64::from),
                info.and_then(|i| i.duration).map(duration_ms),
                None,
                None,
                None,
            );
            if let Some(v) = &voice {
                media.duration = v.duration.or(media.duration);
                media.voice = Some(v.waveform.clone());
            }
            ContentDisplay {
                media: Some(media),
                msgtype: "m.audio".to_owned(),
                body: t.body.clone(),
                formatted_body: None,
                geo: None,
                mentions: mentions.clone(),
            }
        }
        MessageType::Video(t) => {
            let info = t.info.as_ref();
            ContentDisplay {
                media: Some(media_entry(
                    &t.source,
                    None,
                    info.and_then(|i| i.mimetype.clone()),
                    info.and_then(|i| i.size).map(u64::from),
                    info.and_then(|i| i.duration).map(duration_ms),
                    info.and_then(|i| i.width).map(u64::from),
                    info.and_then(|i| i.height).map(u64::from),
                    info.and_then(|i| i.thumbnail_source.as_ref()),
                )),
                msgtype: "m.video".to_owned(),
                body: t.body.clone(),
                formatted_body: None,
                geo: None,
                mentions: mentions.clone(),
            }
        }
        MessageType::Location(t) => ContentDisplay {
            msgtype: "m.location".to_owned(),
            body: t.body.clone(),
            formatted_body: None,
            media: None,
            geo: Some(t.geo_uri.clone()),
            mentions: mentions.clone(),
        },
        // Moderation notices from the homeserver (shutdown warnings and
        // the like): render like a text body under their real msgtype.
        MessageType::ServerNotice(t) => ContentDisplay {
            msgtype: "m.server_notice".to_owned(),
            body: t.body.clone(),
            formatted_body: None,
            media: None,
            geo: None,
            mentions: mentions.clone(),
        },
        // Unknown m.room.message msgtypes (extensions or other clients'
        // namespaced types): keep the event, still under its real
        // msgtype, so nothing a sender sends silently vanishes.  Emacs
        // renders the msgtype as a subdued tag with the body beneath.
        MessageType::_Custom(_t) => ContentDisplay {
            msgtype: msgtype.msgtype().to_owned(),
            body: msgtype.body().to_owned(),
            formatted_body: None,
            media: None,
            geo: None,
            mentions: mentions.clone(),
        },
        // Everything else (verification requests, the gallery MSC):
        // interactive or not yet designed for — skip.
        _ => return None,
    })
}

/// The `org.matrix.custom.html` body of a text-like message, when it
/// carries one.  Other formats (there are none today, but the field
/// is open) render as plain.
fn formatted_html(formatted: &Option<FormattedBody>) -> Option<String> {
    formatted
        .as_ref()
        .filter(|f| matches!(f.format, MessageFormat::Html))
        .map(|f| f.body.clone())
}

/// Daemon-local per-room display state (SDK store holds everything else).
#[derive(Debug, Clone, Default)]
pub struct RoomLocal {
    pub last_activity: Option<u64>,
    pub last_event_preview: Option<String>,
    pub last_event_id: Option<String>,
    /// The newest timeline event the user was marked read over
    /// (rendered messages and, via the event_id-less mark, everything
    /// that stands after them — votes, reactions, edits).  The
    /// event_id-less mark dedups against this: the marker is the
    /// server's own newest-event pointer, and re-sending "to the
    /// newest" while the newest has not moved is a no-op.
    pub last_read_sent: Option<String>,
    /// Last unread counts announced to Emacs; the sync callback diffs
    /// against these to notice reads made by other clients.
    pub unread_notifications: u64,
    pub unread_highlights: u64,
    /// Aggregated reactions seen so far (live sync + backfill merged).
    pub reactions: ReactionState,
    /// Aggregated polls seen so far (live sync + backfill merged).
    pub polls: PollState,
    /// Folded threads (MSC3440) seen so far (live sync + backfill
    /// merged): root -> newest reply.
    pub threads: ThreadState,
    /// Thread member event id -> root, parallel to `threads`.
    pub thread_of: ThreadOf,
    /// Newest `m.replace` per target event (live sync + backfill merged).
    pub edits: EditState,
    /// Latest public `m.read` receipt per other member (live sync +
    /// store seeding merged), for the incoming read-receipt display.
    pub receipts: HashMap<String, ReceiptPos>,
    /// Bounded cache of timeline events the daemon has seen (live sync
    /// and backfill): event id -> origin-server ts.  Lets `receipt_entries`
    /// resolve a receipt target to its true timeline position instead
    /// of guessing from the read time.
    pub event_ts: HashMap<String, u64>,
}

/// Where one other member's public `m.read` receipt points.
#[derive(Debug, Clone, PartialEq)]
pub struct ReceiptPos {
    pub event_id: String,
    pub ts: u64,
}

/// Resolve a receipt's ordering timestamp.  Receipts without a read time
/// (ancient clients) order by the targeted event's timestamp instead, so
/// a ts-less reader's receipts still advance past the first event we
/// saw them read; an unknown event falls back to 0, which never
/// displaces a timed receipt (an older `ts` never wins the merge).
fn receipt_ts(receipt_ts: Option<u64>, event_ts: &HashMap<String, u64>, event_id: &str) -> u64 {
    receipt_ts
        .or_else(|| event_ts.get(event_id).copied())
        .unwrap_or(0)
}

/// How many targets/users one room's reactions, edits and receipts may
/// track.  These maps only ever grow otherwise — redactions are the only
/// reaction prune, and nothing at all removes old edits or departed
/// users' receipts — so a long-lived daemon in busy rooms would hold
/// state for events nobody will ever look at again.
const MAX_TRACKED: usize = 512;

/// Evict the oldest half once over the cap.  "Oldest" is the newest
/// timestamp inside the entry; entries with no known timestamps sort
/// as 0 and go first.  The one policy lives here; the `prune_*`
/// wrappers below own what "newest" means for their family.
fn evict_oldest_half<V>(map: &mut HashMap<String, V>, ts_of: impl Fn(&V) -> u64) {
    if map.len() <= MAX_TRACKED {
        return;
    }
    let mut order: Vec<(String, u64)> = map.iter().map(|(k, v)| (k.clone(), ts_of(v))).collect();
    order.sort_unstable_by_key(|&(_, ts)| ts);
    for (id, _) in order.into_iter().take(map.len() / 2) {
        map.remove(&id);
    }
}

fn prune_edits(edits: &mut EditState) {
    evict_oldest_half(edits, |e| e.ts);
}

fn prune_receipts(receipts: &mut HashMap<String, ReceiptPos>) {
    evict_oldest_half(receipts, |r| r.ts);
}

/// See `evict_oldest_half` for the policy.  Reaction events carry no
/// timestamps of their own, so targets order by their newest reaction
/// event's noted timestamp.
fn prune_reactions(reactions: &mut ReactionState, event_ts: &HashMap<String, u64>) {
    evict_oldest_half(reactions, |keys| {
        keys.values()
            .flat_map(|events| events.keys())
            .filter_map(|id| event_ts.get(id).copied())
            .max()
            .unwrap_or(0)
    });
}

/// See `evict_oldest_half` for the policy.  A poll orders by the
/// newest timestamp inside its fold (newest start content, end event
/// or response).
fn prune_polls(polls: &mut PollState) {
    evict_oldest_half(polls, |votes| {
        votes
            .start
            .as_ref()
            .map(|s| s.ts)
            .into_iter()
            .chain(votes.ended)
            .chain(votes.responses.values().map(|r| r.ts))
            .max()
            .unwrap_or(0)
    });
}

/// See `evict_oldest_half` for the policy.  A thread orders by its
/// newest reply's timestamp; reply->root lookups for evicted roots
/// drop too, so the maps stay consistent.
fn prune_threads(threads: &mut ThreadState, thread_of: &mut ThreadOf) {
    evict_oldest_half(threads, |info| info.latest_ts.unwrap_or(0));
    thread_of.retain(|_, root| threads.contains_key(root));
}

/// Merge one user's receipt into the room's map; newer `ts` wins so
/// sync replays are idempotent.  Returns whether anything changed, so
/// replays stay quiet on the wire.
fn merge_receipt(map: &mut HashMap<String, ReceiptPos>, user: &str, pos: ReceiptPos) -> bool {
    match map.get(user) {
        Some(old) if old.ts >= pos.ts => false,
        _ => {
            map.insert(user.into(), pos);
            true
        }
    }
}

/// The read position one receipt block leaves the account at.  A block
/// can carry the user's receipts on several events — public and
/// private, and more than one of each (a batched sync); the latest
/// position wins, because delivery order (or arbitrary iteration order
/// over the block) must not regress it.  Unknown positions (no receipt
/// ts, event not in the ts map) count as 0, matching `receipt_ts`.
fn own_receipt_pos(
    receipts: Vec<(String, Option<u64>)>,
    event_ts: &HashMap<String, u64>,
) -> Option<(String, Option<u64>)> {
    receipts.into_iter().max_by(|a, b| {
        let pa = receipt_ts(a.1, event_ts, &a.0);
        let pb = receipt_ts(b.1, event_ts, &b.0);
        pa.cmp(&pb)
    })
}

/// Record an event's origin-server timestamp so receipt targets can be
/// resolved to their true timeline position later.  Bounded: receipts
/// only ever target recent events, so past `EVENT_TS_MAX` only
/// `MAX_TRACKED` newest entries survive.
const EVENT_TS_MAX: usize = 1024;

fn note_event_ts(map: &mut HashMap<String, u64>, id: &str, ts: u64) {
    if map.len() >= EVENT_TS_MAX && !map.contains_key(id) {
        let mut kept: Vec<(String, u64)> = map.iter().map(|(k, v)| (k.clone(), *v)).collect();
        kept.sort_unstable_by_key(|(_, ts)| std::cmp::Reverse(*ts));
        kept.truncate(MAX_TRACKED);
        map.clear();
        map.extend(kept);
    }
    map.insert(id.to_owned(), ts);
}

/// Project the per-room receipt map into the wire list, display names
/// and resolved target timestamps included.  Own receipts are filtered
/// at merge time; this is a pure projection for the event payload.
/// The name lookups and the target resolutions are independent, so
/// they run batched instead of one serial await per entry.
async fn receipt_entries(
    room: &Room,
    receipts: &HashMap<String, ReceiptPos>,
    event_ts: &HashMap<String, u64>,
) -> Vec<ReceiptEntry> {
    let items: Vec<(String, ReceiptPos, OwnedUserId)> = receipts
        .iter()
        .filter_map(|(user, pos)| {
            UserId::parse(user.as_str())
                .ok()
                .map(|id| (user.clone(), pos.clone(), id))
        })
        .collect();
    let names = join_all(items.iter().map(|(_, _, id)| member_display_name(room, id))).await;
    let mut entries: Vec<ReceiptEntry> = items
        .into_iter()
        .zip(names)
        .map(|((user_id, pos, _), user_name)| ReceiptEntry {
            user_id,
            user_name,
            target_ts: event_ts.get(&pos.event_id).copied(),
            event_id: pos.event_id,
            ts: pos.ts,
        })
        .collect();
    // Deterministic wire order: by read time, then user id.
    entries.sort_by(|a, b| a.ts.cmp(&b.ts).then_with(|| a.user_id.cmp(&b.user_id)));
    entries
}

fn ts_u64(ts: matrix_sdk::ruma::MilliSecondsSinceUnixEpoch) -> u64 {
    i64::from(ts.get()) as u64
}

/// Wire string for the sender's trust snapshot carried by a
/// `TimelineEvent`/decrypted live message (`EncryptionInfo`. The SDK
/// records the verification state at decryption time — like Element's
/// per-message shield, a device verified *after* delivery stays
/// unverified for that message).  `None` means no encryption info:
/// unencrypted rooms, undecryptable placeholders, redacted events.
fn sender_trust(info: Option<&EncryptionInfo>) -> Option<String> {
    let info = info?;
    match &info.verification_state {
        VerificationState::Verified => Some("verified".to_owned()),
        VerificationState::Unverified(level) => match level {
            // The SDK-level "no verifiable device at all" problems —
            // missing keys on this sender, insecure source — and an
            // ordinary never-verified identity all render the same
            // "cannot vouch for this sender" warning.
            VerificationLevel::UnverifiedIdentity | VerificationLevel::None(_) => {
                Some("unverified".to_owned())
            }
            // Signed but never verified by the user.
            VerificationLevel::UnsignedDevice => Some("unsigned".to_owned()),
            // The identity was verified but this sending device is not
            // part of it (Element's red shields): an actual anomaly.
            VerificationLevel::VerificationViolation => Some("violation".to_owned()),
            VerificationLevel::MismatchedSender => Some("mismatch".to_owned()),
        },
    }
}

/// Start (or join an already running) sync loop.
pub async fn handle_start_sync(daemon: SharedDaemon, req: Option<u64>) -> anyhow::Result<()> {
    let client = daemon
        .client()
        .await
        .ok_or_else(|| anyhow::anyhow!("No active session"))?;

    if daemon
        .syncing
        .swap(true, std::sync::atomic::Ordering::SeqCst)
    {
        info!("Sync loop already running");
        daemon.send(OutEvent::ack(req, true, None));
        return Ok(());
    }

    // Event handlers are registered when the client is installed (login
    // or session restore), not here: registering per startSync made a
    // failed-then-retried sync fire every handler twice.

    info!("Starting continuous sync");
    let task_daemon = daemon.clone();
    let task = tokio::spawn(async move { sync_task(task_daemon, client).await });
    daemon.set_sync_task(task.abort_handle());
    daemon.send(OutEvent::ack(req, true, None));
    Ok(())
}

async fn sync_task(daemon: SharedDaemon, client: Client) {
    daemon.send(OutEvent::event(Event::UpdateSyncState {
        state: "syncing".into(),
        error: None,
    }));

    // First tick via sync_once: fills the state store so the seed pass can
    // find rooms and events without racing the sync loop.
    match client.sync_once(SyncSettings::default()).await {
        Ok(_) => {
            seed_rooms(&daemon, &client).await;
            spawn_room_key_watchers(&daemon, &client);
            daemon.send(OutEvent::event(Event::UpdateSyncState {
                state: "synced".into(),
                error: None,
            }));
            info!("Initial sync complete, seeding done");
        }
        Err(e) => {
            warn!("Initial sync failed: {}", e);
            daemon.set_syncing(false);
            daemon.send(OutEvent::event(Event::UpdateSyncState {
                state: "error".into(),
                error: Some(e.to_string()),
            }));
            return;
        }
    }

    // client.sync() loops internally and returns only on error.  We use the
    // callback form for one hook: unread counters can change without any
    // event we already watch (another client of this user marked the room
    // read), and the room bar would keep stale badges without this diff.
    //
    // The SDK loop only returns on error, so a recovered retry must be
    // announced explicitly, or the client keeps its "error" chip and send
    // gate through a working connection.  Retry after an announced error:
    // "syncing", one sync_once, "synced" (or "error" again).  No
    // re-seeding — mid-outage joins arrive as new-joined-room events.
    let mut announced_error = false;
    loop {
        if announced_error {
            daemon.send(OutEvent::event(Event::UpdateSyncState {
                state: "syncing".into(),
                error: None,
            }));
            match client.sync_once(SyncSettings::default()).await {
                Ok(_) => {
                    daemon.send(OutEvent::event(Event::UpdateSyncState {
                        state: "synced".into(),
                        error: None,
                    }));
                }
                Err(e) => {
                    warn!("Sync retry failed: {}", e);
                    daemon.send(OutEvent::event(Event::UpdateSyncState {
                        state: "error".into(),
                        error: Some(e.to_string()),
                    }));
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    continue;
                }
            }
        }
        let cb_daemon = daemon.clone();
        let cb_client = client.clone();
        match client
            .sync_with_callback(
                SyncSettings::default().timeout(Duration::from_secs(30)),
                move |response| {
                    let daemon = cb_daemon.clone();
                    let client = cb_client.clone();
                    async move {
                        emit_unread_changes(&daemon, &client, &response).await;
                        // A push-rules change (e.g. a mute set from another
                        // client) arrives as account data with no per-room
                        // event, so no room handler re-emits the affected
                        // summaries — re-announce every room when one shows
                        // up.  Push-rules changes are rare, so the burst of
                        // updateRooms costs nothing in the common case.
                        if response.account_data.iter().any(|ev| {
                            matches!(ev.get_field::<String>("type"),
                                     Ok(Some(t)) if t == "m.push_rules")
                        }) {
                            emit_all_room_summaries(&daemon, &client).await;
                        }
                        LoopCtrl::Continue
                    }
                },
            )
            .await
        {
            Ok(()) => {
                // Defensive only: our callback always returns Continue, so
                // a plain Ok means the sync loop stopped for some other
                // reason.  Sleep briefly and restart rather than spin.
                // `announced_error` is left alone: an announced error is
                // re-announced next iteration, otherwise "synced" stands.
                tokio::time::sleep(Duration::from_secs(5)).await;
            }
            Err(e) => {
                warn!("Sync error: {}", e);
                daemon.send(OutEvent::event(Event::UpdateSyncState {
                    state: "error".into(),
                    error: Some(e.to_string()),
                }));
                announced_error = true;
                tokio::time::sleep(Duration::from_secs(5)).await;
            }
        }
    }
}

/// Push an `updateRoom` for every room whose unread counters changed in a
/// sync response, and announce rooms newly joined mid-session (the seed
/// pass only covers rooms present at startup).
///
/// Reads made by another client of this user show up only as changed
/// server-side counts in the next sync — no receipt event is dispatched to
/// event handlers — so without this diff the room bar keeps stale unread
/// badges forever.  New messages change counts too; the duplicate of the
/// message handler's own `updateRoom` is an idempotent row rewrite.
async fn emit_unread_changes(
    daemon: &SharedDaemon,
    client: &Client,
    response: &matrix_sdk::sync::SyncResponse,
) {
    for (room_id, update) in &response.rooms.joined {
        let counts = &update.unread_notifications;
        // `changed` — a known room's counters moved; `fresh` — the room
        // has no local state yet: either the initial seeding still races
        // the loop, or it was joined mid-session.  Fresh rooms get the
        // full seed-and-announce treatment so a mid-session join shows
        // up in the bar immediately.
        let (changed, fresh) = {
            let mut locals = daemon.room_locals.lock().await;
            match locals.entry(room_id.clone()) {
                std::collections::hash_map::Entry::Occupied(mut entry) => {
                    let local = entry.get_mut();
                    let same = local.unread_notifications == counts.notification_count
                        && local.unread_highlights == counts.highlight_count;
                    local.unread_notifications = counts.notification_count;
                    local.unread_highlights = counts.highlight_count;
                    (!same, false)
                }
                std::collections::hash_map::Entry::Vacant(entry) => {
                    // Only record the counts here; the seed-and-announce
                    // below re-reads the last event and merges over this
                    // entry (keeping the counts).
                    entry.insert(RoomLocal {
                        unread_notifications: counts.notification_count,
                        unread_highlights: counts.highlight_count,
                        ..Default::default()
                    });
                    (false, true)
                }
            }
        };
        if let Some(room) = client.get_room(room_id) {
            if fresh {
                seed_room(daemon, &room).await;
            } else if changed {
                emit_room_summary(daemon, &room).await;
            }
        }
    }
    // A mid-session invite has no `rooms.joined` entry and no handlers
    // of ours fire for its stripped state block — announce it here, or
    // the invite would stay invisible until the next getRooms/restart.
    // Invites are rare and the updateRoom is an idempotent row rewrite,
    // so re-emitting on every sync tick costs nothing.
    for room in client
        .invited_rooms()
        .into_iter()
        .filter(|room| response.rooms.invited.contains_key(room.room_id()))
    {
        emit_room_summary(daemon, &room).await;
    }
}

/// One-time pass after the initial sync: populate last-activity/preview for
/// every joined room and announce all rooms to Emacs (invites included —
/// they must be visible to accept or decline, but carry no timeline).
async fn seed_rooms(daemon: &SharedDaemon, client: &Client) {
    let rooms = client.joined_rooms();
    // The last-event fetches are independent per room: batch them instead
    // of paying a serial round-trip each.
    join_all(rooms.iter().map(|room| seed_room(daemon, room))).await;
    let invites = client.invited_rooms();
    // Invites have no timeline this side may fetch — announcing is the
    // whole job (and stores no local, so a later join takes the
    // fresh-room path in emit_unread_changes).
    join_all(invites.iter().map(|room| emit_room_summary(daemon, room))).await;
    info!("Seeded {} rooms, {} invites", rooms.len(), invites.len());
}

/// Seed one room's last-activity/preview state and announce it.  Merges
/// into any existing `RoomLocal` instead of replacing it — the live sync
/// handlers may have populated reactions/edits/receipts already, and a
/// plain insert wiped all of that.
pub async fn seed_room(daemon: &SharedDaemon, room: &Room) {
    let fresh = latest_event_local(room).await;
    {
        let mut locals = daemon.room_locals.lock().await;
        match locals.entry(room.room_id().to_owned()) {
            std::collections::hash_map::Entry::Occupied(mut entry) => {
                let local = entry.get_mut();
                local.last_activity = fresh.last_activity;
                local.last_event_preview = fresh.last_event_preview;
                local.last_event_id = fresh.last_event_id;
            }
            std::collections::hash_map::Entry::Vacant(entry) => {
                entry.insert(fresh);
            }
        }
    }
    // The merge is committed by now, so the helper's plain re-read sees it.
    emit_room_summary(daemon, room).await;
}

/// Watch for room-key arrivals (backup imports) for one room and notify
/// Emacs, so an open room buffer can re-fetch its history and replace
/// "[unable to decrypt]" placeholders.
///
/// The SDK's olm-machine-wide key stream is not publicly reachable, so we use
/// the per-room backup-import stream: one task per watched room.  Keys that
/// arrive by live forwarding usually land together with the event itself, so
/// backup imports are the case that leaves stale placeholders behind.
fn spawn_room_key_watcher(daemon: SharedDaemon, client: &Client, room_id: OwnedRoomId) {
    let already = {
        let mut set = daemon.key_watchers_guard();
        !set.insert(room_id.to_string())
    };
    if already {
        return;
    }
    let profile = daemon.profile.clone();
    let daemon = daemon.clone();
    let client = client.clone();
    tokio::spawn(async move {
        let mut stream = Box::pin(
            client
                .encryption()
                .backups()
                .room_keys_for_room_stream(&room_id),
        );
        while let Some(result) = stream.next().await {
            // Ok(map) with a non-empty session set means keys were imported
            // for this room (Lagged means we missed some — still worth
            // refreshing).
            let arrived = match result {
                Ok(sessions) => !sessions.is_empty(),
                Err(_) => true,
            };
            if arrived {
                info!("Room keys arrived for {}", room_id);
                daemon.send(OutEvent::event(Event::UpdateRoomKeys {
                    profile: profile.clone(),
                    room_id: room_id.to_string(),
                }));
                // The seeded preview can predate the keys — "[unable to
                // decrypt]" from the first backfill.  Re-read the newest
                // event and push a fresh summary, so the room bar's
                // preview and activity sort recover too, not just an
                // open room buffer.
                if let Some(live) = client.get_room(room_id.as_ref()) {
                    seed_room(&daemon, &live).await;
                }
            }
        }
        info!("Room-key watcher for {} ended", room_id);
        daemon.key_watchers_guard().remove(room_id.as_str());
    });
}

/// Spawn key-arrival watchers for all joined rooms (called once per sync run,
/// after the initial sync seeded the rooms).
fn spawn_room_key_watchers(daemon: &SharedDaemon, client: &Client) {
    for room in client.joined_rooms() {
        spawn_room_key_watcher(daemon.clone(), client, room.room_id().to_owned());
    }
}

/// Room ids a batch of key arrivals touches, deduplicated and ordered.
/// The batch's own type is not nameable from here (`RoomKeyInfo` is not
/// re-exported), so callers hand in the extracted room ids.
fn coalesce_rooms(
    rooms: impl IntoIterator<Item = matrix_sdk::ruma::OwnedRoomId>,
) -> std::collections::BTreeSet<matrix_sdk::ruma::OwnedRoomId> {
    rooms.into_iter().collect()
}

/// Watch every room-key arrival — live forwarding, backup import, keys
/// imported by a recovery — and notify Emacs, so an open room buffer can
/// replace its "[unable to decrypt]" placeholders however the key got
/// here.  This is the machine-wide stream of the store's inbound-group-
/// session broadcast; the per-room backup watcher above sees backup
/// imports only.  One task per client: add_sync_handlers replaces the
/// task (aborting the old one) whenever a new client is installed.
pub(crate) fn spawn_received_room_key_watcher(daemon: SharedDaemon, client: &Client) {
    // Abort a watcher from a previous client: its stream lives as long
    // as its client clone, and a relogin must not have the stale client
    // fire updates.
    if let Some(handle) = daemon.received_keys_task_guard().take() {
        handle.abort();
    }
    let profile = daemon.profile.clone();
    let daemon_clone = daemon.clone();
    let client = client.clone();
    let task = tokio::spawn(async move {
        let Some(mut stream) = client.encryption().room_keys_received_stream().await else {
            warn!("No room-key arrival stream (no olm machine?)");
            return;
        };
        while let Some(result) = stream.next().await {
            let batch = match result {
                Ok(batch) => batch,
                Err(e) => {
                    warn!("Room-key arrival stream lagged, missed updates: {e}");
                    continue;
                }
            };
            for room_id in coalesce_rooms(batch.iter().map(|key| key.room_id.clone())) {
                info!("Room keys via forwarding/recovery arrived for {}", room_id);
                daemon_clone.send(OutEvent::event(Event::UpdateRoomKeys {
                    profile: profile.clone(),
                    room_id: room_id.to_string(),
                }));
                // The seeded preview can predate the keys — see the
                // per-room watcher for the same preview repair.
                if let Some(live) = client.get_room(room_id.as_ref()) {
                    seed_room(&daemon_clone, &live).await;
                }
            }
        }
        info!("Room-key arrival watcher ended");
    });
    *daemon.received_keys_task_guard() = Some(task.abort_handle());
}

/// Ensure a key-arrival watcher is running for ROOM (rooms joined after
/// the seed pass, or first backfills).
fn ensure_room_key_watcher(daemon: &SharedDaemon, client: &Client, room: &Room) {
    spawn_room_key_watcher(daemon.clone(), client, room.room_id().to_owned());
}

/// Whether the chunk contains megolm events we could not decrypt.
///
/// `/messages` backfills do not run the sync-side UTD handler that pulls
/// missing room keys from the server-side backup, so the caller uses this
/// to trigger that download explicitly and re-fetch.
fn chunk_has_undecrypted(chunk: &[TimelineEvent]) -> bool {
    chunk.iter().any(|item| item.kind.is_utd())
}

/// Fetch the newest message events (a small backward window) to
/// populate last-activity data for a room.
///
/// The window matters: the single newest event in a room is often a
/// state event or a reaction, not a message — a join or a topic
/// change on a channel that has not seen a message in years must not
/// sort it to the top.  The newest *renderable* message in the window
/// wins (and gives the bar preview the real last message); a window
/// without any falls back to the *oldest* raw timestamp it saw, since
/// the last real activity is at least that old — quiet rooms stay low
/// in the activity sort either way.
async fn latest_event_local(room: &Room) -> RoomLocal {
    let mut options = MessagesOptions::backward();
    options.limit = 20u32.into();
    match room.messages(options).await {
        Ok(messages) => {
            let entries = messages_to_entries(&messages.chunk, room, None).await;
            match entries.into_iter().next() {
                Some(entry) => RoomLocal {
                    last_activity: Some(entry.ts),
                    last_event_preview: Some(entry.body),
                    last_event_id: Some(entry.event_id),
                    ..Default::default()
                },
                None => {
                    // No renderable message in the window: no preview,
                    // but the activity sort still needs a timestamp.
                    RoomLocal {
                        last_activity: messages
                            .chunk
                            .last()
                            .and_then(|ev| ev.timestamp)
                            .map(ts_u64),
                        last_event_preview: None,
                        last_event_id: None,
                        ..Default::default()
                    }
                }
            }
        }
        Err(e) => {
            debug!("No history for {}: {}", room.room_id(), e);
            RoomLocal::default()
        }
    }
}

/// Fold one reaction event into the room's reaction state.
fn merge_reaction(
    state: &mut ReactionState,
    target: &str,
    key: &str,
    event_id: &str,
    sender: &str,
) {
    state
        .entry(target.to_owned())
        .or_default()
        .entry(key.to_owned())
        .or_default()
        .insert(event_id.to_owned(), sender.to_owned());
}

/// Remove one reaction event (its redaction).  Returns the id of the target
/// whose aggregated list changed, pruning now-empty keys and targets — or
/// `None` if the redacted id is not a tracked reaction (e.g. a redacted
/// message).
fn remove_reaction(state: &mut ReactionState, reaction_event_id: &str) -> Option<String> {
    let found = state.iter().find_map(|(target, keys)| {
        keys.iter()
            .find(|(_, events)| events.contains_key(reaction_event_id))
            .map(|(key, _)| (target.clone(), key.clone()))
    });
    let (target, key) = found?;
    if let Some(keys) = state.get_mut(&target) {
        if let Some(events) = keys.get_mut(&key) {
            events.remove(reaction_event_id);
        }
        keys.retain(|_, events| !events.is_empty());
    }
    if state.get(&target).is_none_or(|keys| keys.is_empty()) {
        state.remove(&target);
    }
    Some(target)
}

/// Aggregated reaction entries for one target event, in stable key order.
/// `own` is true when any reaction with this key came from us.
fn reaction_entries(state: &ReactionState, target: &str, own_user_id: &str) -> Vec<ReactionEntry> {
    let Some(keys) = state.get(target) else {
        return Vec::new();
    };
    let mut entries: Vec<ReactionEntry> = keys
        .iter()
        .map(|(key, events)| ReactionEntry {
            key: key.clone(),
            count: events.len() as u64,
            own: events.values().any(|s| s == own_user_id),
        })
        .collect();
    entries.sort_by(|a, b| a.key.cmp(&b.key));
    entries
}

/// The event a message replies to: the `m.in_reply_to` relation, or a
/// thread relation that is a genuine reply rather than the no-threads
/// fallback threaded clients add to plain messages.
fn reply_target_of<T>(rel: &Option<Relation<T>>) -> Option<String> {
    match rel.as_ref()? {
        Relation::Reply(r) => Some(r.in_reply_to.event_id.to_string()),
        Relation::Thread(t) if !t.is_falling_back => {
            t.in_reply_to.as_ref().map(|r| r.event_id.to_string())
        }
        _ => None,
    }
}

/// `m.room.message` wrapper of [`reply_target_of`].
fn reply_target(
    content: &matrix_sdk::ruma::events::room::message::RoomMessageEventContent,
) -> Option<String> {
    reply_target_of(&content.relates_to)
}

/// The thread relation (MSC3440) an event carries: `(root, reply)`,
/// where `reply` is the event a genuine in-thread reply targets.
/// `is_falling_back` is ignored for the root — both the no-threads
/// fallback and the reply shape name the same thread.  Deliberately
/// distinct from [`reply_target_of`]: a fallback relation renders no
/// quote, but it still says which thread the event belongs to.
fn thread_rel_of<T>(rel: &Option<Relation<T>>) -> Option<(String, Option<String>)> {
    match rel.as_ref()? {
        Relation::Thread(t) => {
            let reply = t
                .in_reply_to
                .as_ref()
                .map(|r| r.event_id.to_string())
                .filter(|_| !t.is_falling_back);
            Some((t.event_id.to_string(), reply))
        }
        _ => None,
    }
}

/// `m.room.message` wrapper of [`thread_rel_of`].
fn thread_rel(
    content: &matrix_sdk::ruma::events::room::message::RoomMessageEventContent,
) -> Option<(String, Option<String>)> {
    thread_rel_of(&content.relates_to)
}

/// The relation of an in-thread send (MSC3440, Element interop): a
/// genuine in-thread reply keeps its reply leg (`is_falling_back:
/// false`, Element's thread panel renders the quote); a plain send
/// carries the no-threads fallback — `m.in_reply_to` naming the
/// thread's latest event — so clients without thread support keep
/// following the thread.  Fold holds nothing yet: the root stands in
/// as the latest, which every server accepts.
fn thread_relation_for(
    root: &matrix_sdk::ruma::EventId,
    reply_to: Option<&matrix_sdk::ruma::EventId>,
    fold_latest: Option<&matrix_sdk::ruma::EventId>,
) -> Relation<matrix_sdk::ruma::events::room::message::RoomMessageEventContentWithoutRelation> {
    match reply_to {
        Some(reply) => Relation::Thread(Thread::reply(root.to_owned(), reply.to_owned())),
        None => {
            let latest = fold_latest.filter(|l| l != &root).unwrap_or(root);
            Relation::Thread(Thread::plain(root.to_owned(), latest.to_owned()))
        }
    }
}

/// The fold's newest event for thread root ROOT — the fallback leg an
/// ordinary client's `m.in_reply_to` follows — as a parsed event id.
async fn thread_fold_latest(
    daemon: &SharedDaemon,
    room: &Room,
    root: &str,
) -> Option<matrix_sdk::ruma::OwnedEventId> {
    let locals = daemon.room_locals.lock().await;
    let local = locals.get(room.room_id())?;
    local
        .threads
        .get(root)
        .and_then(|info| info.latest_event_id.clone())
        .and_then(|id| matrix_sdk::ruma::EventId::parse(id).ok())
}

/// Fold one thread member event into the room's state: register the
/// event->root lookup and advance the root's latest reply.  Newer ts
/// wins, so sync replays and bundle seeds (which re-read older pages)
/// are idempotent and never clobber fresher live data.  A root may
/// register itself: the fold entry must exist so later members merge.
fn merge_thread(
    threads: &mut ThreadState,
    thread_of: &mut ThreadOf,
    root: &str,
    event_id: &str,
    ts: u64,
) {
    thread_of.insert(event_id.to_owned(), root.to_owned());
    let info = threads.entry(root.to_owned()).or_default();
    if info.latest_ts.is_none_or(|latest| ts >= latest) {
        info.latest_ts = Some(ts);
        info.latest_event_id = Some(event_id.to_owned());
    }
}

/// A redacted thread reply left the fold: drop the reply->root lookup
/// and — when the reply was the thread's tracked latest — the fold
/// entry itself (the next send falls back to naming the root, legal
/// per MSC3440; the thread re-seeds from the next bundle, see
/// [`thread_bundle_of`]).  A thread_of entry keys into `threads`, so
/// evicting one without the other only leaves inert lookups.
fn unmerge_thread(threads: &mut ThreadState, thread_of: &mut ThreadOf, event_id: &str) {
    if let Some(root) = thread_of.remove(event_id) {
        if threads
            .get(&root)
            .and_then(|info| info.latest_event_id.as_deref())
            .is_some_and(|latest| latest == event_id)
        {
            threads.remove(&root);
        }
    }
}

/// The thread root named by an event's raw `/content` object: the
/// `m.thread` relation's event id.  For fold and bundle passes that
/// read events whose typed shape varies with the wire (Element's
/// re-shaped polls, edits of thread replies) — the rel_type check is
/// exact, unlike the typed parse's per-type relation enums.
fn thread_root_of_json(content: &serde_json::Value) -> Option<String> {
    let rel = content.get("m.relates_to")?;
    if rel.get("rel_type")?.as_str()? != "m.thread" {
        return None;
    }
    Some(rel.get("event_id")?.as_str()?.to_owned())
}

/// The bundled thread summary (MSC3440) riding an event's unsigned
/// block: `(latest event id, latest ts)`.  Takes the FULL event JSON —
/// the bundled summary lives at the event level, a sibling of
/// `content`, not inside it.  Read straight off the raw JSON — a typed
/// `BundledThread` parse fails on bundles from encrypted rooms, where
/// the bundled `latest_event` ships encrypted.
fn thread_bundle_of(event: &serde_json::Value) -> Option<(String, u64)> {
    let latest = event.pointer("/unsigned/m.relations/m.thread/latest_event")?;
    let event_id = latest.get("event_id")?.as_str()?;
    let ts = latest.get("origin_server_ts")?.as_f64()? as u64;
    Some((event_id.to_owned(), ts))
}

/// The wire display for an `m.sticker` event.  A sticker IS a picture
/// (with alt text): the media entry carries the same fields an
/// `m.image` does, so Emacs renders it through the image thumbnail
/// pipeline under its real `m.sticker` msgtype.
fn sticker_display(
    content: &matrix_sdk::ruma::events::sticker::StickerEventContent,
) -> ContentDisplay {
    let source: MediaSource = content.source.clone().into();
    let info = &content.info;
    let media = media_entry(
        &source,
        None,
        info.mimetype.clone(),
        info.size.map(u64::from),
        None,
        info.width.map(u64::from),
        info.height.map(u64::from),
        info.thumbnail_source.as_ref(),
    );
    ContentDisplay {
        media: Some(media),
        msgtype: "m.sticker".to_owned(),
        body: content.body.clone(),
        formatted_body: None,
        geo: None,
        mentions: None,
    }
}

/// Build the wire `MediaEntry` shared by all media-bearing content types.
/// Callers pull the differing `info` fields per message type; the ruma
/// info structs have no common trait to extract them here.
#[allow(clippy::too_many_arguments)]
fn media_entry(
    source: &MediaSource,
    filename: Option<String>,
    mimetype: Option<String>,
    size: Option<u64>,
    duration: Option<u64>,
    width: Option<u64>,
    height: Option<u64>,
    thumb: Option<&MediaSource>,
) -> MediaEntry {
    MediaEntry {
        source: serde_json::to_value(source).unwrap_or(serde_json::Value::Null),
        thumb_source: thumb.and_then(|s| serde_json::to_value(s).ok()),
        mimetype,
        filename,
        size,
        duration,
        voice: None,
        width,
        height,
    }
}

/// Playback duration (ruma Duration) as milliseconds.
fn duration_ms(d: std::time::Duration) -> u64 {
    d.as_millis() as u64
}

/// The sender of a chunk item that will become a `MessageEntry`
/// (encrypted placeholders included) — used to batch the display-name
/// lookups.
fn renderable_sender(ev: &AnySyncTimelineEvent) -> Option<&UserId> {
    match ev {
        AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::RoomEncrypted(m)) => {
            Some(m.sender())
        }
        AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::RoomMessage(m)) => {
            Some(m.sender())
        }
        AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::Sticker(m)) => Some(m.sender()),
        AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::PollStart(m)) => {
            Some(m.sender())
        }
        _ => None,
    }
}

/// Filter a `Messages` chunk down to renderable text messages, newest-first
/// as the chunk is ordered.  With `daemon`, reactions and their redactions
/// from the chunk are folded into the room's persistent reaction state and
/// each entry carries its aggregated list — the preview caller passes
/// `None` and skips all of that.
/// Per-event render context for the entry builders below: the room
/// (own-user resolution), the fold pass's state snapshots and the
/// batched sender name/avatar lookups.
struct EntryCtx<'a> {
    room: &'a Room,
    reactions: &'a ReactionState,
    name_of: &'a HashMap<String, Option<String>>,
    avatar_of: &'a HashMap<String, Option<String>>,
}

/// `(!agg.is_empty()).then_some(agg)`: empty reaction lists are
/// omitted from the wire, not carried as an empty array.
fn agg_of(ctx: &EntryCtx, event_id: &str) -> Option<Vec<ReactionEntry>> {
    let agg = reaction_entries(ctx.reactions, event_id, ctx.room.own_user_id().as_str());
    (!agg.is_empty()).then_some(agg)
}

/// The shell every undecryptable placeholder and redacted slot
/// renders: no content, no reply relation, no edit — the aggregates
/// are the only thing it carries.
#[allow(clippy::too_many_arguments)]
fn placeholder_entry(
    ctx: &EntryCtx,
    event_id: &str,
    sender: &UserId,
    ts: u64,
    msgtype: &str,
    body: &str,
    redacted: Option<bool>,
    trust: Option<String>,
) -> MessageEntry {
    MessageEntry {
        event_id: event_id.to_string(),
        sender: sender.to_string(),
        sender_name: ctx.name_of.get(sender.as_str()).cloned().flatten(),
        sender_avatar: ctx.avatar_of.get(sender.as_str()).cloned().flatten(),
        sender_trust: trust,
        body: body.to_string(),
        formatted_body: None,
        ts,
        msgtype: msgtype.to_string(),
        is_own: sender == ctx.room.own_user_id(),
        media: None,
        reply_to: None,
        thread_root: None,
        edited: None,
        redacted,
        reactions: agg_of(ctx, event_id),
        geo: None,
        mentions: None,
        poll: None,
    }
}

/// The RoomMessage original: the whole `content_display` render with
/// its aggregated edits override.  `None` skips: replacements (folded
/// into their original) and a display the render pipeline cannot
/// produce.
fn room_message_entry(
    ctx: &EntryCtx,
    m: &OriginalSyncRoomMessageEvent,
    content: &serde_json::Value,
    edits: &EditState,
    trust: Option<String>,
) -> Option<MessageEntry> {
    let event_id = m.event_id.to_string();
    let is_own = m.sender == *ctx.room.own_user_id();
    if matches!(
        m.content.relates_to.as_ref(),
        Some(Relation::Replacement(_))
    ) {
        return None;
    }
    let reply_to = reply_target(&m.content);
    let thread_root = thread_rel(&m.content).map(|(root, _)| root);
    let agg = agg_of(ctx, &event_id);
    let plain = content_display(&m.content.msgtype, Some(content))?;
    // An aggregated replacement — from this chunk or an earlier one —
    // overrides the original content and marks the entry with the
    // edit's timestamp.
    let (msgtype, body, formatted_body, media, edited, geo, mentions) = match edits.get(&event_id) {
        Some(info) => (
            info.msgtype.clone(),
            info.body.clone(),
            info.formatted_body.clone(),
            info.media.clone(),
            Some(info.ts),
            info.geo.clone(),
            info.mentions.clone(),
        ),
        None => (
            plain.msgtype.clone(),
            plain.body,
            plain.formatted_body,
            plain.media,
            None,
            plain.geo.clone(),
            plain.mentions,
        ),
    };
    Some(MessageEntry {
        event_id,
        sender: m.sender.to_string(),
        sender_name: ctx.name_of.get(m.sender.as_str()).cloned().flatten(),
        sender_avatar: ctx.avatar_of.get(m.sender.as_str()).cloned().flatten(),
        // The plaintext arm of a chunk item has no
        // encryption info; the decrypted arm's
        // snapshot rides along at the same index.
        sender_trust: trust,
        body,
        formatted_body,
        ts: ts_u64(m.origin_server_ts),
        msgtype,
        is_own,
        media,
        reply_to,
        thread_root,
        edited,
        redacted: None,
        reactions: agg,
        geo,
        mentions,
        poll: None,
    })
}

/// Stickers (m.sticker) ship as the same media shape an m.image
/// carries; the image thumbnail pipeline renders the picture.
fn sticker_entry(
    ctx: &EntryCtx,
    m: &matrix_sdk::ruma::events::sticker::OriginalSyncStickerEvent,
    trust: Option<String>,
) -> MessageEntry {
    let display = sticker_display(&m.content);
    let event_id = m.event_id.to_string();
    let agg = agg_of(ctx, &event_id);
    MessageEntry {
        event_id,
        sender: m.sender.to_string(),
        sender_name: ctx.name_of.get(m.sender.as_str()).cloned().flatten(),
        sender_avatar: ctx.avatar_of.get(m.sender.as_str()).cloned().flatten(),
        sender_trust: trust,
        body: display.body,
        formatted_body: display.formatted_body,
        ts: ts_u64(m.origin_server_ts),
        msgtype: display.msgtype,
        is_own: m.sender == *ctx.room.own_user_id(),
        media: display.media,
        reply_to: reply_target_of(&m.content.relates_to),
        thread_root: thread_rel_of(&m.content.relates_to).map(|(root, _)| root),
        edited: None,
        redacted: None,
        reactions: agg,
        geo: None,
        mentions: None,
        poll: None,
    }
}

/// Poll starts (m.poll.start, MSC3381) render as their question with
/// the answer blocks below; the body carries the question text so
/// previews, searches and older clients still read it.  Responses and
/// ends never render — they fold into the start's aggregated state.
fn poll_start_entry(
    ctx: &EntryCtx,
    polls: &PollState,
    m: &OriginalSyncPollStartEvent,
    trust: Option<String>,
) -> Option<MessageEntry> {
    // Replacements folded into their original; they never render as
    // separate messages.
    if matches!(
        m.content.relates_to.as_ref(),
        Some(Relation::Replacement(_))
    ) {
        return None;
    }
    let event_id = m.event_id.to_string();
    let (poll_id, reply_to) = match m.content.relates_to.as_ref() {
        // An edited poll's line keys to the original; the
        // answers come from the newest replacement.
        Some(Relation::Reply(r)) => (event_id.clone(), Some(r.in_reply_to.event_id.to_string())),
        _ => (event_id.clone(), None),
    };
    let thread_root = thread_rel_of(&m.content.relates_to).map(|(root, _)| root);
    let agg = agg_of(ctx, &event_id);
    Some(MessageEntry {
        event_id,
        sender: m.sender.to_string(),
        sender_name: ctx.name_of.get(m.sender.as_str()).cloned().flatten(),
        sender_avatar: ctx.avatar_of.get(m.sender.as_str()).cloned().flatten(),
        sender_trust: trust,
        body: m
            .content
            .poll
            .question
            .text
            .find_plain()
            .unwrap_or("")
            .to_string(),
        formatted_body: None,
        ts: ts_u64(m.origin_server_ts),
        msgtype: "m.poll.start".to_string(),
        is_own: m.sender == *ctx.room.own_user_id(),
        media: None,
        reply_to,
        thread_root,
        edited: None,
        redacted: None,
        reactions: agg,
        geo: None,
        mentions: None,
        poll: poll_entry(polls, &poll_id, ctx.room.own_user_id().as_str()),
    })
}

/// Timeline member events render as the same subdued system lines
/// live arrivals do.  (Topic changes are room state, not timeline
/// lines — the bar handles those.)  Avatar-only profile bumps and
/// no-ops render no line: `member_body` says `None`.
#[allow(clippy::too_many_arguments)]
fn member_entry(
    ctx: &EntryCtx,
    member_names: &HashMap<String, String>,
    state_key: &UserId,
    sender: &UserId,
    event_id: &str,
    ts: u64,
    change: MembershipChange,
    redacted: Option<bool>,
    trust: Option<String>,
) -> Option<MessageEntry> {
    let body = member_body(
        member_names,
        ctx.room.own_user_id(),
        state_key,
        sender,
        change,
    )?;
    Some(MessageEntry {
        event_id: event_id.to_string(),
        sender: sender.to_string(),
        sender_name: member_names.get(sender.as_str()).cloned(),
        sender_avatar: None,
        sender_trust: trust,
        body,
        formatted_body: None,
        ts,
        msgtype: "m.member".to_string(),
        is_own: state_key == ctx.room.own_user_id(),
        media: None,
        reply_to: None,
        thread_root: None,
        edited: None,
        redacted,
        reactions: agg_of(ctx, event_id),
        geo: None,
        mentions: None,
        poll: None,
    })
}

// --- Per-timeline-family entry builders: one helper per event family,
// --- so `messages_to_entries` stays a visible dispatch chain over them.

/// The m.room.encrypted family: an undecryptable original keeps its
/// `m.undecryptable` placeholder so encrypted rooms never render empty
/// — the key may arrive later (backup download, key forwarding), after
/// which reopening the room re-fetches.  A redacted event keeps its
/// slot too: redaction prunes the ciphertext, so it can never be
/// decrypted into a RoomMessage and would otherwise fall through every
/// arm and drop out of freshly opened buffers without a placeholder.
fn room_encrypted_entry(
    ctx: &EntryCtx,
    m: SyncMessageLikeEvent<RoomEncryptedEventContent>,
    trust: Option<String>,
) -> MessageEntry {
    match m {
        SyncMessageLikeEvent::Original(m) => placeholder_entry(
            ctx,
            m.event_id.as_ref(),
            &m.sender,
            ts_u64(m.origin_server_ts),
            "m.undecryptable",
            "[unable to decrypt]",
            None,
            trust,
        ),
        SyncMessageLikeEvent::Redacted(m) => {
            // Redaction pruned the ciphertext: no trust either.
            placeholder_entry(
                ctx,
                m.event_id.as_ref(),
                &m.sender,
                ts_u64(m.origin_server_ts),
                "m.text",
                "",
                Some(true),
                trust,
            )
        }
    }
}

/// The m.room.message family: a redacted original keeps its slot so
/// the history page's layout stays stable — Emacs renders its
/// [redacted] marker from the `redacted` flag, and redaction strips
/// the content, so no reply relation or edit survives either.  An
/// original renders through `room_message_entry` (replacements fold
/// into their original and return None).
fn room_message_family_entry(
    ctx: &EntryCtx,
    msg: SyncMessageLikeEvent<RoomMessageEventContent>,
    content: &serde_json::Value,
    edits: &EditState,
    trust: Option<String>,
) -> Option<MessageEntry> {
    match msg {
        SyncMessageLikeEvent::Redacted(_) => Some(placeholder_entry(
            ctx,
            msg.event_id().as_ref(),
            msg.sender(),
            ts_u64(msg.origin_server_ts()),
            "m.text",
            "",
            Some(true),
            trust,
        )),
        SyncMessageLikeEvent::Original(m) => room_message_entry(ctx, &m, content, edits, trust),
    }
}

/// The sticker family.  Stickers never reach the RoomMessage arm —
/// Element sends them as their own message-like event type, so they
/// get a dedicated builder instead of falling through the dispatch's
/// `_` arm (which keeps only a debug trace).  A redacted one degrades
/// to the marker alone (redaction strips the media with the content).
fn sticker_family_entry(
    ctx: &EntryCtx,
    msg: SyncMessageLikeEvent<StickerEventContent>,
    trust: Option<String>,
) -> MessageEntry {
    match msg {
        SyncMessageLikeEvent::Original(m) => sticker_entry(ctx, &m, trust),
        SyncMessageLikeEvent::Redacted(m) => placeholder_entry(
            ctx,
            m.event_id.as_ref(),
            &m.sender,
            ts_u64(m.origin_server_ts),
            "m.sticker",
            "",
            Some(true),
            trust,
        ),
    }
}

/// Poll starts (m.poll.start, MSC3381) render as their question with
/// the answer blocks below; a redacted one keeps its slot like every
/// other renderable message.
fn poll_start_family_entry(
    ctx: &EntryCtx,
    polls: &PollState,
    msg: SyncMessageLikeEvent<PollStartEventContent>,
    trust: Option<String>,
) -> Option<MessageEntry> {
    match msg {
        SyncMessageLikeEvent::Original(m) => poll_start_entry(ctx, polls, &m, trust),
        SyncMessageLikeEvent::Redacted(m) => Some(placeholder_entry(
            ctx,
            m.event_id.as_ref(),
            &m.sender,
            ts_u64(m.origin_server_ts),
            "m.poll.start",
            "",
            Some(true),
            trust,
        )),
    }
}

/// Timeline member events render as the same subdued system lines
/// live arrivals do (topic changes are room state, not timeline lines
/// — the bar handles those).  A redacted member event keeps its
/// membership (the spec preserves the field) but loses the profile
/// and previous content; the change still reads — Element shows these
/// too, without the actor's part in name changes.
fn member_family_entry(
    ctx: &EntryCtx,
    member_names: &HashMap<String, String>,
    m: SyncRoomMemberEvent,
    trust: Option<String>,
) -> Option<MessageEntry> {
    match m {
        SyncRoomMemberEvent::Original(m) => member_entry(
            ctx,
            member_names,
            &m.state_key,
            &m.sender,
            m.event_id.as_ref(),
            ts_u64(m.origin_server_ts),
            m.membership_change(),
            None,
            trust,
        ),
        SyncRoomMemberEvent::Redacted(m) => member_entry(
            ctx,
            member_names,
            &m.state_key,
            &m.sender,
            m.event_id.as_ref(),
            ts_u64(m.origin_server_ts),
            m.membership_change(None),
            Some(true),
            trust,
        ),
    }
}

/// Pass 1: polls in foreign namespaces and shapes.  The typed parse
/// either fails outright (Element's content blocks and string texts,
/// and our own older events) or yields ruma's `UnstablePoll`
/// variants (the `org.matrix.msc3381.*` wire types) — none of which
/// the fold and render passes below know.  Everything re-types and
/// re-shapes into the stable final-spec form; from then on the event
/// folds, takes votes and renders exactly like our own polls.
/// Redacted poll events parse typed already and take their normal
/// arms.  `parsed` is repaired in place: the wire type comes from the
/// typed event when the parse succeeded, else from the raw JSON.
fn retype_chunk_polls(
    chunk: &[TimelineEvent],
    room: &Room,
    parsed: &mut [Option<AnySyncTimelineEvent>],
) {
    let mut unparsed_types: Vec<String> = Vec::new();
    for (i, item) in chunk.iter().enumerate() {
        let event_type = match parsed[i].as_ref() {
            Some(ev) => Some(ev.event_type().to_string()),
            None => serde_json::from_str::<serde_json::Value>(item.raw().json().get())
                .ok()
                .and_then(|v| {
                    v.get("type")
                        .and_then(serde_json::Value::as_str)
                        .map(str::to_owned)
                }),
        };
        let Some(event_type) = event_type else {
            continue;
        };
        if poll_wire_kind(&event_type).is_none() {
            if parsed[i].is_none() && !unparsed_types.contains(&event_type) {
                unparsed_types.push(event_type);
            }
            continue;
        }
        // A stable-typed poll already parsed: leave it be.
        if parsed[i].is_some() && event_type.starts_with("m.") {
            continue;
        }
        match unstable_poll_retyped(&event_type, item.raw().json().get()) {
            Some(stable) => {
                debug!("poll event {event_type} re-typed to the stable form");
                parsed[i] = Some(stable);
            }
            None => {
                // A stable-typed event whose re-parse failed keeps the
                // (typed) original; an unparsed one is lost.
                if parsed[i].is_none() {
                    debug!("poll event {event_type} failed re-parse after normalize");
                }
            }
        }
    }
    if !unparsed_types.is_empty() {
        debug!(
            "backfill unparsed event types for {}: {:?}",
            room.room_id(),
            unparsed_types
        );
    }
}

/// Pass 2: fold the chunk's relation-bearing events (reactions,
/// redactions, edits, the poll shapes, threads) into the room's
/// persistent local state under its lock, then run the prunes and
/// return the snapshots the render pass projects.  `daemon == None`
/// (the preview path) folds nothing and returns the empty snapshots.
async fn fold_chunk_state(
    parsed: &[Option<AnySyncTimelineEvent>],
    contents: &[serde_json::Value],
    raws: &[serde_json::Value],
    room: &Room,
    daemon: Option<&SharedDaemon>,
) -> (ReactionState, EditState, PollState) {
    let Some(daemon) = daemon else {
        return (HashMap::new(), HashMap::new(), HashMap::new());
    };
    let folds = collect_chunk_folds(parsed, contents, raws);
    let mut locals = daemon.room_locals.lock().await;
    let local = locals.entry(room.room_id().to_owned()).or_default();
    apply_chunk_folds(local, folds)
}

/// The relation folds a chunk carries, collected by
/// `collect_chunk_folds` and applied by `apply_chunk_folds`.
struct ChunkFolds {
    notes: Vec<(String, u64)>,
    merges: Vec<(String, String, String, String)>,
    removes: Vec<String>,
    edits: Vec<(String, EditInfo)>,
    // Poll folds, queues like the reaction ones above.
    poll_starts: Vec<(String, Option<String>, PollStartInfo)>,
    poll_responses: Vec<(String, String, String, u64, Vec<String>)>,
    poll_ends: Vec<(String, u64)>,
    // Thread folds, same shape: merges carry events' own
    // relations, bundles the summaries riding the chunk (see
    // `thread_bundle_of`).
    thread_merges: Vec<(String, String, u64)>,
    thread_bundles: Vec<(String, String, u64)>,
}

/// Pass 2a: collect the chunk's relation folds.  `contents` holds each
/// item's raw `/content` object (relations live inside); `raws` the
/// full event JSON — the bundled thread summary rides the top-level
/// `unsigned`, a sibling of `content`, so it is read from there.
fn collect_chunk_folds(
    parsed: &[Option<AnySyncTimelineEvent>],
    contents: &[serde_json::Value],
    raws: &[serde_json::Value],
) -> ChunkFolds {
    let mut folds = ChunkFolds {
        notes: Vec::new(),
        merges: Vec::new(),
        removes: Vec::new(),
        edits: Vec::new(),
        poll_starts: Vec::new(),
        poll_responses: Vec::new(),
        poll_ends: Vec::new(),
        thread_merges: Vec::new(),
        thread_bundles: Vec::new(),
    };
    for ((ev, content), raw) in parsed.iter().zip(contents.iter()).zip(raws.iter()) {
        // Every timeline event, not just renderable ones: receipts
        // target whatever the reader's client last showed, which is
        // often a reaction or an edit.
        let Some(ev) = ev else { continue };
        folds
            .notes
            .push((ev.event_id().to_string(), ts_u64(ev.origin_server_ts())));
        // Thread fold (MSC3440): a relation names its thread; a
        // bundled summary with no relation rides the root itself
        // (replies always carry the relation, roots never do).
        if let Some((latest_id, ts)) = thread_bundle_of(raw) {
            let root = thread_root_of_json(content).unwrap_or_else(|| ev.event_id().to_string());
            folds.thread_bundles.push((root, latest_id, ts));
        }
        if let Some(root) = thread_root_of_json(content) {
            folds.thread_merges.push((
                root,
                ev.event_id().to_string(),
                ts_u64(ev.origin_server_ts()),
            ));
        }
        match ev {
            AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::Reaction(
                SyncMessageLikeEvent::Original(m),
            )) => folds.merges.push((
                m.content.relates_to.event_id.to_string(),
                m.content.relates_to.key.clone(),
                m.event_id.to_string(),
                m.sender.to_string(),
            )),
            AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::RoomRedaction(
                SyncRoomRedactionEvent::Original(m),
            )) => {
                // v11 moved the redacted id into the content; older room
                // versions keep the top-level field.
                let redacted = m.redacts.clone().or_else(|| m.content.redacts.clone());
                if let Some(redacted) = redacted {
                    folds.removes.push(redacted.to_string());
                }
            }
            AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::PollStart(
                SyncMessageLikeEvent::Original(m),
            )) => {
                // Replacements fold into their original — an edit
                // may swap the answers (MSC2676, same-type
                // replacements); responses may address either id.
                let ts = ts_u64(m.origin_server_ts);
                let (poll_id, replacement) = match m.content.relates_to.as_ref() {
                    Some(Relation::Replacement(r)) => {
                        (r.event_id.to_string(), Some(m.event_id.to_string()))
                    }
                    _ => (m.event_id.to_string(), None),
                };
                folds.poll_starts.push((
                    poll_id,
                    replacement,
                    poll_start_info(&m.content.poll, ts),
                ));
            }
            AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::PollResponse(
                SyncMessageLikeEvent::Original(m),
            )) => folds.poll_responses.push((
                m.content.relates_to.event_id.to_string(),
                m.event_id.to_string(),
                m.sender.to_string(),
                ts_u64(m.origin_server_ts),
                m.content.selections.iter().cloned().collect(),
            )),
            AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::PollEnd(
                SyncMessageLikeEvent::Original(m),
            )) => folds.poll_ends.push((
                m.content.relates_to.event_id.to_string(),
                ts_u64(m.origin_server_ts),
            )),
            AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::RoomMessage(
                SyncMessageLikeEvent::Original(m),
            )) => {
                // Replacements fold into their original below (pass 2);
                // they must never render as separate messages.
                if let Some(Relation::Replacement(r)) = m.content.relates_to.as_ref() {
                    if let Some(display) = content_display(
                        &r.new_content.msgtype,
                        content.pointer("/m.relates_to/m.replace/m.new_content"),
                    ) {
                        folds.edits.push((
                            r.event_id.to_string(),
                            EditInfo {
                                msgtype: display.msgtype.clone(),
                                body: display.body,
                                formatted_body: display.formatted_body,
                                media: display.media,
                                geo: display.geo.clone(),
                                mentions: display.mentions.clone(),
                                ts: ts_u64(m.origin_server_ts),
                            },
                        ));
                    }
                }
            }
            _ => {}
        }
    }
    folds
}

/// Pass 2b: apply the collected folds to a room's local state, prune,
/// and return the snapshots the render pass projects.  Callers hold
/// the room's `room_locals` lock across the whole call.
fn apply_chunk_folds(
    local: &mut RoomLocal,
    folds: ChunkFolds,
) -> (ReactionState, EditState, PollState) {
    let ChunkFolds {
        notes,
        merges,
        removes,
        edits,
        poll_starts,
        poll_responses,
        poll_ends,
        thread_bundles,
        thread_merges,
    } = folds;
    for (id, ts) in notes {
        note_event_ts(&mut local.event_ts, &id, ts);
    }
    for (target, key, event_id, sender) in merges {
        merge_reaction(&mut local.reactions, &target, &key, &event_id, &sender);
    }
    for event_id in removes {
        remove_reaction(&mut local.reactions, &event_id);
        // A redacted poll response record (or a whole poll, when
        // the start itself was redacted) drops out of the state —
        // the render pass below projects the reduced aggregates.
        poll_redaction(&mut local.polls, &event_id);
    }
    for (poll_id, replacement, info) in poll_starts {
        merge_poll_start(&mut local.polls, &poll_id, replacement.as_deref(), info);
    }
    for (target, event_id, sender, ts, selections) in poll_responses {
        merge_poll_response(
            &mut local.polls,
            &target,
            &event_id,
            &sender,
            ts,
            selections,
        );
    }
    for (target, ts) in poll_ends {
        merge_poll_end(&mut local.polls, &target, ts);
    }
    for (target, info) in edits {
        merge_edit(&mut local.edits, &target, info);
    }
    // Page-fetched bundles go in first: they are the snapshot the
    // chunk was served from.  The events' own relations merge
    // after, so a fresher in-chunk reply always leads the fold.
    for (root, latest_id, ts) in thread_bundles {
        merge_thread(
            &mut local.threads,
            &mut local.thread_of,
            &root,
            &latest_id,
            ts,
        );
    }
    for (root, event_id, ts) in thread_merges {
        merge_thread(
            &mut local.threads,
            &mut local.thread_of,
            &root,
            &event_id,
            ts,
        );
    }
    prune_reactions(&mut local.reactions, &local.event_ts);
    prune_edits(&mut local.edits);
    prune_receipts(&mut local.receipts);
    prune_polls(&mut local.polls);
    prune_threads(&mut local.threads, &mut local.thread_of);
    // The render pass projects FROM THESE SNAPSHOT CLONES, not from
    // the room locals: returned fresh empty maps instead would render
    // every fetched page without the folded state (reactions, edited
    // bodies, poll votes).
    (
        local.reactions.clone(),
        local.edits.clone(),
        local.polls.clone(),
    )
}

/// Display-name lookups are independent per sender: fetch each unique
/// sender once, batched, instead of a serial round-trip per entry.
/// The same batched pass covers avatar URLs (member state, another
/// in-memory read) — one pass keeps the page path round-trip-free.
async fn batch_sender_info(
    room: &Room,
    parsed: &[Option<AnySyncTimelineEvent>],
) -> (
    HashMap<String, Option<String>>,
    HashMap<String, Option<String>>,
) {
    let mut name_of: HashMap<String, Option<String>> = HashMap::new();
    let mut avatar_of: HashMap<String, Option<String>> = HashMap::new();
    let mut seen: HashSet<&str> = HashSet::new();
    let senders: Vec<&UserId> = parsed
        .iter()
        .flatten()
        .filter_map(renderable_sender)
        .filter(|s| seen.insert(s.as_str()))
        .collect();
    let infos = join_all(senders.iter().map(|s| async {
        let name = member_display_name(room, s).await;
        let avatar = member_avatar_url(room, s).await;
        (name, avatar)
    }))
    .await;
    name_of.extend(
        senders
            .iter()
            .zip(infos.iter())
            .map(|(s, (name, _))| (s.to_string(), name.clone())),
    );
    avatar_of.extend(
        senders
            .into_iter()
            .zip(infos)
            .map(|(s, (_, avatar))| (s.to_string(), avatar)),
    );
    (name_of, avatar_of)
}

/// Filter a `Messages` chunk down to renderable text messages, newest-first
/// as the chunk is ordered.  Three passes: `retype_chunk_polls`
/// (foreign poll shapes into the stable forms), `fold_chunk_state`
/// (relation events into the room's persistent state, returning the
/// snapshots this render pass projects — the preview caller passes
/// `None` for the daemon and skips the fold), then the render loop
/// below, which pushes one `MessageEntry` per renderable event.
async fn messages_to_entries(
    chunk: &[TimelineEvent],
    room: &Room,
    daemon: Option<&SharedDaemon>,
) -> Vec<MessageEntry> {
    // Deserialize each item exactly once; the passes match on the
    // stored value instead of re-parsing the raw JSON repeatedly.
    let mut parsed: Vec<Option<AnySyncTimelineEvent>> = chunk
        .iter()
        .map(|item| item.raw().deserialize().ok())
        .collect();
    retype_chunk_polls(chunk, room, &mut parsed);
    // Raw content JSON per item, parallel to `parsed`.  Voice messages
    // (MSC3245) hide the marker and waveform in unstable blocks the
    // typed content drops, so the entries pass reads them from here.
    let contents: Vec<serde_json::Value> = chunk
        .iter()
        .map(|item| {
            serde_json::from_str::<serde_json::Value>(item.raw().json().get())
                .ok()
                .and_then(|v| v.get("content").cloned())
                .unwrap_or(serde_json::Value::Null)
        })
        .collect();
    // Full event JSON per item, parallel to `parsed`.  Thread bundles
    // (MSC3440) ride the top-level `unsigned`, a sibling of `content`,
    // so the fold pass reads them here.
    let raws: Vec<serde_json::Value> = chunk
        .iter()
        .map(|item| {
            serde_json::from_str::<serde_json::Value>(item.raw().json().get())
                .unwrap_or(serde_json::Value::Null)
        })
        .collect();
    // Trust snapshot per item, parallel to `parsed` (see `sender_trust`).
    let trusts: Vec<Option<String>> = chunk
        .iter()
        .map(|item| sender_trust(item.encryption_info().map(std::sync::Arc::as_ref)))
        .collect();
    let (reactions, edits_snapshot, polls_snapshot) =
        fold_chunk_state(&parsed, &contents, &raws, room, daemon).await;
    let (name_of, avatar_of) = batch_sender_info(room, &parsed).await;
    let ctx = EntryCtx {
        room,
        reactions: &reactions,
        name_of: &name_of,
        avatar_of: &avatar_of,
    };
    let mut entries: Vec<MessageEntry> = Vec::new();
    // Timeline member events render as system lines; their names come
    // from the in-memory store, resolved once so the fold stays sync.
    let mut member_users: Vec<OwnedUserId> = Vec::new();
    for ev in parsed.iter().flatten() {
        if let AnySyncTimelineEvent::State(AnySyncStateEvent::RoomMember(m)) = ev {
            member_users.push(m.sender().to_owned());
            member_users.push(m.state_key().to_owned());
        }
    }
    let member_names = member_names_from(room, &member_users).await;
    let member_names = &member_names;

    for ((ev, trust), content) in parsed
        .into_iter()
        .zip(trusts)
        .zip(contents)
        .filter_map(|((ev, trust), content)| ev.map(|ev| ((ev, trust), content)))
    {
        match ev {
            AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::RoomEncrypted(m)) => {
                entries.push(room_encrypted_entry(&ctx, m, trust));
            }
            AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::RoomMessage(msg)) => {
                if let Some(entry) =
                    room_message_family_entry(&ctx, msg, &content, &edits_snapshot, trust)
                {
                    entries.push(entry);
                }
            }
            AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::Sticker(msg)) => {
                entries.push(sticker_family_entry(&ctx, msg, trust));
            }
            AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::PollStart(msg)) => {
                if let Some(entry) = poll_start_family_entry(&ctx, &polls_snapshot, msg, trust) {
                    entries.push(entry);
                }
            }
            AnySyncTimelineEvent::State(AnySyncStateEvent::RoomMember(m)) => {
                if let Some(entry) = member_family_entry(&ctx, member_names, m, trust) {
                    entries.push(entry);
                }
            }
            _ => {
                // A typed event no render arm matches: keep a one-line
                // trace so a future event type is not silently dropped.
                debug!(
                    "backfill drop: {} at {}",
                    ev.event_type(),
                    ts_u64(ev.origin_server_ts())
                );
            }
        }
    }
    entries
}

/// Stable wire strings for `RoomNotificationMode`.  Hand-mapped, not
/// serde-derived: the SDK enum has no serde renames and would serialize
/// as "MentionsAndKeywordsOnly" etc.
fn notification_mode_string(mode: RoomNotificationMode) -> &'static str {
    match mode {
        RoomNotificationMode::AllMessages => "all_messages",
        RoomNotificationMode::MentionsAndKeywordsOnly => "mentions_and_keywords",
        RoomNotificationMode::Mute => "mute",
    }
}

/// Protocol name of the bridge relaying this room, read from a bridge
/// state event's content (MSC 2346): `protocol.displayname` when set,
/// else `protocol.id`.  An empty content object means the bridge is
/// gone.
fn bridge_protocol_from_content(content: &serde_json::Value) -> Option<String> {
    let protocol = content.get("protocol")?;
    let name = protocol
        .get("displayname")
        .and_then(serde_json::Value::as_str)
        .filter(|s| !s.is_empty())
        .or_else(|| {
            protocol
                .get("id")
                .and_then(serde_json::Value::as_str)
                .filter(|s| !s.is_empty())
        })?;
    Some(name.to_owned())
}

/// The bridge protocol this room is relayed into, from room state:
/// `m.bridge` (MSC 2346), with older bridges only announcing themselves
/// in the legacy `uk.half-shot.bridge`.  Any state key can carry one,
/// so every event of both types is consulted and the first with
/// protocol info wins.  Both reads are served from the in-memory state
/// store — no server round-trip.
async fn bridge_protocol(room: &Room) -> Option<String> {
    for event_type in ["m.bridge", "uk.half-shot.bridge"] {
        let Ok(events) = room.get_state_events(event_type.into()).await else {
            continue;
        };
        for raw in events {
            // Sync (joined/left) vs Stripped (invited) differ only in the
            // wrapper; the bytes are the event JSON either way.
            let json = match raw {
                matrix_sdk::deserialized_responses::RawAnySyncOrStrippedState::Sync(raw) => {
                    raw.json().to_string()
                }
                matrix_sdk::deserialized_responses::RawAnySyncOrStrippedState::Stripped(raw) => {
                    raw.json().to_string()
                }
            };
            let content = serde_json::from_str::<serde_json::Value>(&json)
                .ok()
                .and_then(|v| v.get("content").cloned());
            if let Some(protocol) = content.as_ref().and_then(bridge_protocol_from_content) {
                return Some(protocol);
            }
        }
    }
    None
}

/// Wire spelling of a room's state, shipped in every `RoomSummary` so
/// Emacs can treat an invite (no timeline, no counts) differently from
/// a joined room.
fn room_state_string(room: &Room) -> &'static str {
    match room.state() {
        RoomState::Joined => "joined",
        RoomState::Invited => "invited",
        RoomState::Left => "left",
        RoomState::Knocked => "knocked",
        RoomState::Banned => "banned",
    }
}

/// Build the summary the room bar renders from.
pub async fn room_summary(room: &Room, local: &RoomLocal) -> RoomSummary {
    let display_name = room
        .display_name()
        .await
        .map(|n| n.to_string())
        .unwrap_or_else(|_| room.room_id().to_string());
    let is_direct = room.is_direct().await.unwrap_or(false);
    let counts = room.unread_notification_counts();
    // Both are cheap in-memory reads of the cached push rules; the SDK
    // refreshes that cache itself on every PushRulesEvent, so the mode
    // is always current without extra subscriptions on our side.
    let user_defined_mode = room.user_defined_notification_mode().await;
    let notification_mode = room.notification_mode().await;
    // The room's upgrade links, straight from its state store: cheap
    // local reads (`state_values` swallows a failed read as linkless),
    // None for a room with no upgrade history — the tombstone's
    // replacement room this one died into, and the older room this one
    // continues.
    let upgraded_to = first_link_id(successor_ids(&state_values(room, "m.room.tombstone").await));
    let upgraded_from = first_link_id(predecessor_ids(
        &[
            state_values(room, "m.room.create").await,
            state_values(room, "m.room.predecessor").await,
        ]
        .concat(),
    ));

    RoomSummary {
        room_id: room.room_id().to_string(),
        room_state: room_state_string(room).to_owned(),
        name: room.name(),
        display_name,
        avatar_url: room.avatar_url().map(|u| u.to_string()),
        topic: room.topic(),
        canonical_alias: room.canonical_alias().map(|a| a.to_string()),
        is_encrypted: room
            .latest_encryption_state()
            .await
            .map(|s| s.is_encrypted())
            .unwrap_or(false),
        is_direct,
        is_space: room.is_space(),
        unread_notifications: counts.notification_count,
        unread_highlights: counts.highlight_count,
        last_activity: local.last_activity,
        last_event_preview: local.last_event_preview.clone(),
        last_event_id: local.last_event_id.clone(),
        notification_mode: notification_mode.map(|m| notification_mode_string(m).to_owned()),
        user_defined_notification_mode: user_defined_mode
            .map(|m| notification_mode_string(m).to_owned()),
        bridge_protocol: bridge_protocol(room).await,
        upgraded_to,
        upgraded_from,
        pinned_events: room_summary_pinned(room).await,
    }
}

/// The room's pinned event ids (`m.room.pinned_events`), None when the
/// state is unset or empty.  Another in-memory state read along the
/// upgraded_to/from lines — no server round-trip.
async fn room_summary_pinned(room: &Room) -> Option<Vec<String>> {
    let pinned = pinned_from_state(&state_values(room, "m.room.pinned_events").await);
    if pinned.is_empty() {
        None
    } else {
        Some(pinned)
    }
}

/// Announce one room's current summary as an unsolicited `updateRoom`.
/// Callers that need the summary itself (or must respond to a request)
/// still build it via `room_summary`.
async fn emit_room_summary(daemon: &SharedDaemon, room: &Room) {
    let local = daemon
        .room_locals
        .lock()
        .await
        .get(room.room_id())
        .cloned()
        .unwrap_or_default();
    let summary = room_summary(room, &local).await;
    daemon.send(OutEvent::event(Event::UpdateRoom {
        profile: daemon.profile.clone(),
        room: summary,
    }));
}

/// Re-announce every room in the list.  A push-rules change (e.g. a
/// mute set from another client) arrives as account data with no
/// per-room event, so nothing else would re-emit the affected
/// summaries.  Invited rooms re-announce too (they carry no
/// notification state, so the burst costs nothing and keeps their rows
/// fresh).
pub async fn emit_all_room_summaries(daemon: &SharedDaemon, client: &Client) {
    let mut rooms = client.joined_rooms();
    rooms.extend(client.invited_rooms());
    join_all(rooms.iter().map(|room| emit_room_summary(daemon, room))).await;
}

/// A live `m.room.message` arrived.  The handler takes the event raw:
/// voice notes carry their marker, duration and waveform in unstable
/// content blocks (`m.voice` / `m.audio`, MSC3245/3246) that ruma's
/// typed content drops, so the content JSON is read before the typed
/// view is deserialized out of the same bytes.  `info` is the SDK's
/// decryption context (`None` for plaintext rooms) — its trust state
/// is snapshotted into the wire event's `sender_trust`.
pub(crate) async fn on_room_message(
    daemon: SharedDaemon,
    raw: Raw<OriginalSyncRoomMessageEvent>,
    room: Room,
    info: Option<EncryptionInfo>,
) {
    let content = serde_json::from_str::<serde_json::Value>(raw.json().get())
        .ok()
        .and_then(|v| v.get("content").cloned());
    let Ok(ev) = raw.deserialize() else {
        return;
    };
    if room.state() != RoomState::Joined {
        return;
    }
    // An edit is not a new message: fold it and announce the original
    // event's new content instead (Emacs re-renders the line in place).
    if matches!(
        ev.content.relates_to.as_ref(),
        Some(Relation::Replacement(_))
    ) {
        on_edit(daemon, ev, content.as_ref(), room).await;
        return;
    }
    // Text renders normally; media events render as dimmed entries (and
    // image thumbnails where supported).  Other content types stay out.
    let Some(display) = content_display(&ev.content.msgtype, content.as_ref()) else {
        return;
    };
    // Fresh messages cannot have reactions yet; the live updateReactions
    // handler paints them as they arrive.
    let reply_to = reply_target(&ev.content);
    let thread_root = thread_rel(&ev.content).map(|(root, _)| root);

    let ts = ts_u64(ev.origin_server_ts);
    let is_own = ev.sender == *room.own_user_id();
    let sender_name = member_display_name(&room, &ev.sender).await;
    let sender_avatar = member_avatar_url(&room, &ev.sender).await;

    // Update local display state.
    {
        let mut locals = daemon.room_locals.lock().await;
        let local = locals.entry(room.room_id().to_owned()).or_default();
        local.last_activity = Some(ts);
        local.last_event_preview = Some(display.body.clone());
        note_last_event(local, ev.event_id.as_str());
        note_event_ts(&mut local.event_ts, ev.event_id.as_ref(), ts);
        if let Some(root) = thread_root.as_deref() {
            merge_thread(
                &mut local.threads,
                &mut local.thread_of,
                root,
                ev.event_id.as_ref(),
                ts,
            );
            prune_threads(&mut local.threads, &mut local.thread_of);
        }
    }

    daemon.send(OutEvent::event(Event::UpdateNewMessage {
        profile: daemon.profile.clone(),
        room_id: room.room_id().to_string(),
        event_id: ev.event_id.to_string(),
        sender: ev.sender.to_string(),
        sender_name,
        sender_avatar,
        sender_trust: sender_trust(info.as_ref()),
        body: display.body,
        formatted_body: display.formatted_body,
        ts,
        msgtype: display.msgtype.clone(),
        is_own,
        media: display.media,
        reply_to,
        // The event's own thread (MSC3440), when it replies under one;
        // Emacs paints its thread marks from it.
        thread_root,
        reactions: None,
        mentions: display.mentions,
        poll: None,
    }));

    emit_room_summary(&daemon, &room).await;
}

/// A live `m.poll.start` arrived: fold it into the room's poll state
/// and announce it as the new message its line renders (the poll block
/// rides the entry, so a poll is vote-ready the moment it appears).
pub(crate) async fn on_poll_start(
    daemon: SharedDaemon,
    raw: Raw<OriginalSyncPollStartEvent>,
    info: Option<EncryptionInfo>,
    room: Room,
) {
    poll_start_apply(daemon, raw.json().get(), info, room).await;
}

/// A live `org.matrix.msc3381.poll.start` arrived (pre-spec clients;
/// Element's current polls arrive under the stable type): the same
/// fold, with the payload normalized first.
pub(crate) async fn on_unstable_poll_start(
    daemon: SharedDaemon,
    raw: Raw<matrix_sdk::ruma::events::poll::unstable_start::OriginalSyncUnstablePollStartEvent>,
    info: Option<EncryptionInfo>,
    room: Room,
) {
    poll_start_apply(daemon, raw.json().get(), info, room).await;
}

async fn poll_start_apply(
    daemon: SharedDaemon,
    raw: &str,
    info: Option<EncryptionInfo>,
    room: Room,
) {
    let Some(ev) = poll_start_typed(raw) else {
        return;
    };
    if room.state() != RoomState::Joined {
        return;
    }
    let ts = ts_u64(ev.origin_server_ts);
    let thread_root = thread_rel_of(&ev.content.relates_to).map(|(root, _)| root);
    let (poll_id, state_entry, replacement) = match ev.content.relates_to.as_ref() {
        Some(Relation::Replacement(r)) => (
            r.event_id.to_string(),
            r.event_id.to_string(),
            Some(ev.event_id.to_string()),
        ),
        _ => (ev.event_id.to_string(), ev.event_id.to_string(), None),
    };
    {
        let mut locals = daemon.room_locals.lock().await;
        let local = locals.entry(room.room_id().to_owned()).or_default();
        // A poll start IS a message as far as the bar is concerned:
        // it bumps activity and the preview read like a text send.
        note_event_ts(&mut local.event_ts, ev.event_id.as_ref(), ts);
        if let Some(root) = thread_root.as_deref() {
            merge_thread(
                &mut local.threads,
                &mut local.thread_of,
                root,
                ev.event_id.as_ref(),
                ts,
            );
            prune_threads(&mut local.threads, &mut local.thread_of);
        }
        merge_poll_start(
            &mut local.polls,
            &poll_id,
            replacement.as_deref(),
            poll_start_info(&ev.content.poll, ts),
        );
        prune_polls(&mut local.polls);
    }
    // Replacements fold into their original; the original's updatePoll
    // (or its history render) carries the new answers.  A poll start
    // REPLACEMENT is not a new message — only the fold above.
    if replacement.is_some() {
        if let Some(poll) = poll_entry_of(&daemon, &room, &poll_id).await {
            daemon.send(OutEvent::event(Event::UpdatePoll {
                profile: daemon.profile.clone(),
                room_id: room.room_id().to_string(),
                event_id: poll_id,
                poll: Some(poll),
                // This runs only when `ev' IS the replacement: the
                // arriving start-edit is a timeline event here.
                source_event_id: Some(ev.event_id.to_string()),
            }));
        }
        return;
    }
    let is_own = ev.sender == *room.own_user_id();
    let sender_name = member_display_name(&room, &ev.sender).await;
    let sender_avatar = member_avatar_url(&room, &ev.sender).await;
    let question = ev
        .content
        .poll
        .question
        .text
        .find_plain()
        .unwrap_or("")
        .to_string();
    {
        let mut locals = daemon.room_locals.lock().await;
        if let Some(local) = locals.get_mut(room.room_id()) {
            local.last_activity = Some(ts);
            local.last_event_preview = Some(question.clone());
            note_last_event(local, ev.event_id.as_str());
        }
    }
    daemon.send(OutEvent::event(Event::UpdateNewMessage {
        profile: daemon.profile.clone(),
        room_id: room.room_id().to_string(),
        event_id: ev.event_id.to_string(),
        sender: ev.sender.to_string(),
        sender_name,
        sender_avatar,
        sender_trust: sender_trust(info.as_ref()),
        body: question,
        formatted_body: None,
        ts,
        msgtype: "m.poll.start".to_string(),
        is_own,
        media: None,
        reply_to: None,
        thread_root,
        reactions: None,
        mentions: None,
        poll: poll_entry_of(&daemon, &room, &state_entry).await,
    }));
    emit_room_summary(&daemon, &room).await;
}

/// The state key of the poll a `m.reference` target names: the raw
/// target id when the state already keys on it, else the owning entry
/// (the target may be a poll-start replacement id).
fn poll_id_of(state: &PollState, target: &str) -> Option<String> {
    if state.contains_key(target) {
        Some(target.to_owned())
    } else {
        state
            .iter()
            .find(|(_, votes)| votes.replaces.iter().any(|id| id == target))
            .map(|(id, _)| id.clone())
    }
}

/// Re-announce one poll's aggregate (`updatePoll`): the live response/
/// end path.  A poll without fold data ships `poll: None` — Emacs
/// blanks the block.  `source_event_id` is the *arriving* event the
/// update rides (the vote's or the end's own id) — Emacs needs it for
/// read markers: events it never renders as messages still count
/// unread on the homeserver, and live-following the room reads over
/// them.
async fn announce_poll(
    daemon: SharedDaemon,
    room: &Room,
    poll_id: &str,
    source_event_id: Option<String>,
) {
    let poll = {
        let locals = daemon.room_locals.lock().await;
        locals
            .get(room.room_id())
            .and_then(|local| poll_entry(&local.polls, poll_id, room.own_user_id().as_str()))
    };
    daemon.send(OutEvent::event(Event::UpdatePoll {
        profile: daemon.profile.clone(),
        room_id: room.room_id().to_string(),
        event_id: poll_id.to_string(),
        poll,
        source_event_id,
    }));
}

/// The current projection of one poll for the live handlers: locks the
/// room locals and renders `poll_entry`.
async fn poll_entry_of(daemon: &SharedDaemon, room: &Room, poll_id: &str) -> Option<PollEntry> {
    let locals = daemon.room_locals.lock().await;
    locals
        .get(room.room_id())
        .and_then(|local| poll_entry(&local.polls, poll_id, room.own_user_id().as_str()))
}

/// A live `m.poll.response` arrived: fold it and re-announce the poll's
/// aggregate.  Display-only, like `on_reaction` — it must not touch
/// room-bar state.
pub(crate) async fn on_poll_response(
    daemon: SharedDaemon,
    raw: Raw<matrix_sdk::ruma::events::poll::response::OriginalSyncPollResponseEvent>,
    room: Room,
) {
    poll_response_apply(daemon, raw.json().get(), room).await;
}

/// A live `org.matrix.msc3381.poll.response` arrived (pre-spec
/// clients; Element's current votes arrive under the stable type).
pub(crate) async fn on_unstable_poll_response(
    daemon: SharedDaemon,
    raw: Raw<
        matrix_sdk::ruma::events::poll::unstable_response::OriginalSyncUnstablePollResponseEvent,
    >,
    room: Room,
) {
    poll_response_apply(daemon, raw.json().get(), room).await;
}

async fn poll_response_apply(daemon: SharedDaemon, raw: &str, room: Room) {
    let Some(ev) = poll_response_typed(raw) else {
        return;
    };
    if room.state() != RoomState::Joined {
        return;
    }
    let target = ev.content.relates_to.event_id.to_string();
    let ts = ts_u64(ev.origin_server_ts);
    let poll_id = {
        let mut locals = daemon.room_locals.lock().await;
        let local = locals.entry(room.room_id().to_owned()).or_default();
        merge_poll_response(
            &mut local.polls,
            &target,
            ev.event_id.as_ref(),
            ev.sender.as_ref(),
            ts,
            ev.content.selections.iter().cloned().collect(),
        );
        note_last_event(local, ev.event_id.as_str());
        poll_id_of(&local.polls, &target)
    };
    if let Some(poll_id) = poll_id {
        announce_poll(daemon, &room, &poll_id, Some(ev.event_id.to_string())).await;
    }
}

/// A live `m.poll.end` arrived: fold it and re-announce the poll —
/// results become visible for undisclosed kinds.
pub(crate) async fn on_poll_end(
    daemon: SharedDaemon,
    raw: Raw<matrix_sdk::ruma::events::poll::end::OriginalSyncPollEndEvent>,
    room: Room,
) {
    poll_end_apply(daemon, raw.json().get(), room).await;
}

/// A live `org.matrix.msc3381.poll.end` arrived (pre-spec clients;
/// Element's current ends arrive under the stable type).
pub(crate) async fn on_unstable_poll_end(
    daemon: SharedDaemon,
    raw: Raw<matrix_sdk::ruma::events::poll::unstable_end::OriginalSyncUnstablePollEndEvent>,
    room: Room,
) {
    poll_end_apply(daemon, raw.json().get(), room).await;
}

async fn poll_end_apply(daemon: SharedDaemon, raw: &str, room: Room) {
    let Some(ev) = poll_end_typed(raw) else {
        return;
    };
    if room.state() != RoomState::Joined {
        return;
    }
    let target = ev.content.relates_to.event_id.to_string();
    let ts = ts_u64(ev.origin_server_ts);
    let poll_id = {
        let mut locals = daemon.room_locals.lock().await;
        let local = locals.entry(room.room_id().to_owned()).or_default();
        merge_poll_end(&mut local.polls, &target, ts);
        note_last_event(local, ev.event_id.as_str());
        poll_id_of(&local.polls, &target)
    };
    if let Some(poll_id) = poll_id {
        announce_poll(daemon, &room, &poll_id, Some(ev.event_id.to_string())).await;
    }
}

/// A live `m.sticker` event: rides `on_room_message`'s pattern (raw
/// handler, decryption info context, joined-room gate) but with fully
/// typed content — a sticker carries no unstable blocks and is never
/// edited, only redacted.
pub(crate) async fn on_sticker(
    daemon: SharedDaemon,
    raw: Raw<matrix_sdk::ruma::events::sticker::OriginalSyncStickerEvent>,
    info: Option<EncryptionInfo>,
    room: Room,
) {
    let Ok(ev) = raw.deserialize() else {
        // The compat-encrypted-stickers form (a `file` block) fails
        // typed deserialization only when the feature is off.
        return;
    };
    if room.state() != RoomState::Joined {
        return;
    }
    let display = sticker_display(&ev.content);

    let ts = ts_u64(ev.origin_server_ts);
    let thread_root = thread_rel_of(&ev.content.relates_to).map(|(root, _)| root);
    let is_own = ev.sender == *room.own_user_id();
    let sender_name = member_display_name(&room, &ev.sender).await;
    let sender_avatar = member_avatar_url(&room, &ev.sender).await;

    // Update local display state.
    {
        let mut locals = daemon.room_locals.lock().await;
        let local = locals.entry(room.room_id().to_owned()).or_default();
        local.last_activity = Some(ts);
        // A sticker's alt text is often empty; keep the bar preview
        // readable by naming the thing when the sender did not.
        let preview = if display.body.is_empty() {
            "[sticker]".to_string()
        } else {
            display.body.clone()
        };
        local.last_event_preview = Some(preview);
        note_last_event(local, ev.event_id.as_str());
        note_event_ts(&mut local.event_ts, ev.event_id.as_ref(), ts);
        if let Some(root) = thread_root.as_deref() {
            merge_thread(
                &mut local.threads,
                &mut local.thread_of,
                root,
                ev.event_id.as_ref(),
                ts,
            );
            prune_threads(&mut local.threads, &mut local.thread_of);
        }
    }

    daemon.send(OutEvent::event(Event::UpdateNewMessage {
        profile: daemon.profile.clone(),
        room_id: room.room_id().to_string(),
        event_id: ev.event_id.to_string(),
        sender: ev.sender.to_string(),
        sender_name,
        sender_avatar,
        sender_trust: sender_trust(info.as_ref()),
        body: display.body,
        formatted_body: display.formatted_body,
        ts,
        msgtype: display.msgtype,
        is_own,
        media: display.media,
        // Fresh messages cannot have reactions yet; the live
        // updateReactions handler paints them as they arrive.
        reply_to: reply_target_of(&ev.content.relates_to),
        thread_root,
        reactions: None,
        mentions: None,
        poll: None,
    }));

    emit_room_summary(&daemon, &room).await;
}

pub(crate) async fn on_room_member(
    daemon: SharedDaemon,
    ev: OriginalSyncRoomMemberEvent,
    room: Room,
) {
    if room.state() != RoomState::Joined {
        return;
    }
    let own = room.own_user_id();
    let names = member_names_from(&room, &[ev.sender.clone(), ev.state_key.clone()]).await;
    let Some(body) = member_body(
        &names,
        own,
        ev.state_key.as_ref(),
        &ev.sender,
        ev.membership_change(),
    ) else {
        return;
    };
    let ts = ts_u64(ev.origin_server_ts);
    {
        let mut locals = daemon.room_locals.lock().await;
        let local = locals.entry(room.room_id().to_owned()).or_default();
        local.last_activity = Some(ts);
        local.last_event_preview = Some(body.clone());
        note_last_event(local, ev.event_id.as_str());
        note_event_ts(&mut local.event_ts, ev.event_id.as_ref(), ts);
    }
    daemon.send(OutEvent::event(Event::UpdateNewMessage {
        profile: daemon.profile.clone(),
        room_id: room.room_id().to_string(),
        event_id: ev.event_id.to_string(),
        sender: ev.sender.to_string(),
        sender_name: names.get(ev.sender.as_str()).cloned(),
        // System lines carry no avatar; Emacs renders them dimmed
        // without the sender column.
        sender_avatar: None,
        // Member events travel unencrypted state, no trust snapshot.
        sender_trust: None,
        body,
        formatted_body: None,
        ts,
        msgtype: "m.member".to_owned(),
        is_own: ev.state_key == *room.own_user_id(),
        media: None,
        reply_to: None,
        thread_root: None,
        reactions: None,
        mentions: None,
        poll: None,
    }));
    emit_room_summary(&daemon, &room).await;
}

pub(crate) async fn on_room_name(daemon: SharedDaemon, _ev: OriginalSyncRoomNameEvent, room: Room) {
    if room.state() != RoomState::Joined {
        return;
    }
    emit_room_summary(&daemon, &room).await;
}

/// Two more room-state changes the bar shows: topic and avatar.  Like
/// the room name, neither is a timeline event — both only re-announce
/// the room summary so the name column, topic line and avatar glyph
/// keep current without waiting for an unrelated event to push one.
pub(crate) async fn on_room_topic(
    daemon: SharedDaemon,
    _ev: matrix_sdk::ruma::events::room::topic::OriginalSyncRoomTopicEvent,
    room: Room,
) {
    if room.state() != RoomState::Joined {
        return;
    }
    emit_room_summary(&daemon, &room).await;
}

pub(crate) async fn on_room_avatar(
    daemon: SharedDaemon,
    _ev: matrix_sdk::ruma::events::room::avatar::OriginalSyncRoomAvatarEvent,
    room: Room,
) {
    if room.state() != RoomState::Joined {
        return;
    }
    emit_room_summary(&daemon, &room).await;
}

/// A `m.room.pinned_events` state change: the summary's `pinned_events`
/// is the single source of truth the client renders pinned marks from,
/// so the echo re-announces it.
pub(crate) async fn on_room_pinned(
    daemon: SharedDaemon,
    _ev: matrix_sdk::ruma::events::room::pinned_events::OriginalSyncRoomPinnedEventsEvent,
    room: Room,
) {
    if room.state() != RoomState::Joined {
        return;
    }
    emit_room_summary(&daemon, &room).await;
}

/// A live `m.replace` arrived: fold the winning edit into the room's
/// state and announce the original event's new content.  Like
/// `on_reaction`, this deliberately touches no room-bar state — an edit
/// must not twitch unread counters or previews.  `content` is the raw
/// JSON of the edit's content (the edited voice blocks live there, in
/// `m.relates_to.m.replace.m.new_content`).
pub(crate) async fn on_edit(
    daemon: SharedDaemon,
    ev: OriginalSyncRoomMessageEvent,
    content: Option<&serde_json::Value>,
    room: Room,
) {
    if room.state() != RoomState::Joined {
        return;
    }
    let Some(Relation::Replacement(r)) = ev.content.relates_to.as_ref() else {
        return;
    };
    let Some(display) = content_display(
        &r.new_content.msgtype,
        content.and_then(|c| c.pointer("/m.relates_to/m.replace/m.new_content")),
    ) else {
        return;
    };
    let target = r.event_id.to_string();
    let edited_ts = ts_u64(ev.origin_server_ts);
    let edit_id = ev.event_id.to_string();
    {
        let mut locals = daemon.room_locals.lock().await;
        let local = locals.entry(room.room_id().to_owned()).or_default();
        note_event_ts(&mut local.event_ts, ev.event_id.as_ref(), edited_ts);
        note_last_event(local, ev.event_id.as_str());
        merge_edit(
            &mut local.edits,
            &target,
            EditInfo {
                msgtype: display.msgtype.clone(),
                body: display.body.clone(),
                formatted_body: display.formatted_body.clone(),
                media: display.media.clone(),
                geo: display.geo.clone(),
                mentions: display.mentions.clone(),
                ts: edited_ts,
            },
        );
        prune_edits(&mut local.edits);
    }
    daemon.send(OutEvent::event(Event::UpdateEdited {
        profile: daemon.profile.clone(),
        room_id: room.room_id().to_string(),
        event_id: target,
        // The edit's own event id: read-marker pass-over (see
        // on_reaction's locals block).
        source_event_id: Some(edit_id),
        body: display.body,
        formatted_body: display.formatted_body,
        msgtype: display.msgtype.clone(),
        media: display.media,
        geo: display.geo.clone(),
        edited_ts,
    }));
}

/// A live `m.reaction` arrived: fold it into the room's state and announce
/// the target's refreshed aggregated list.  Deliberately touches nothing
/// else — reactions must not twitch the room bar, previews or unread
/// counters.
pub(crate) async fn on_reaction(daemon: SharedDaemon, ev: OriginalSyncReactionEvent, room: Room) {
    if room.state() != RoomState::Joined {
        return;
    }
    let target = ev.content.relates_to.event_id.to_string();
    let key = ev.content.relates_to.key;
    let reaction_id = ev.event_id.to_string();
    let sender = ev.sender.to_string();

    let reactions = {
        let mut locals = daemon.room_locals.lock().await;
        let local = locals.entry(room.room_id().to_owned()).or_default();
        note_event_ts(
            &mut local.event_ts,
            &reaction_id,
            ts_u64(ev.origin_server_ts),
        );
        merge_reaction(&mut local.reactions, &target, &key, &reaction_id, &sender);
        prune_reactions(&mut local.reactions, &local.event_ts);
        note_last_event(local, &reaction_id);
        reaction_entries(&local.reactions, &target, room.own_user_id().as_str())
    };

    daemon.send(OutEvent::event(Event::UpdateReactions {
        profile: daemon.profile.clone(),
        room_id: room.room_id().to_string(),
        event_id: target,
        // The arriving reaction's own id: read-marker pass-over (see
        // the locals block above).
        source_event_id: Some(reaction_id),
        reactions,
    }));
}

/// A live `m.room.redaction` arrived.  If it removed one of our tracked
/// reaction events, refresh that target's aggregated list; otherwise
/// announce the redacted message so Emacs renders its marker.  Like
/// `on_reaction`, this must not touch room-bar state.
pub(crate) async fn on_redaction(
    daemon: SharedDaemon,
    ev: OriginalSyncRoomRedactionEvent,
    room: Room,
) {
    if room.state() != RoomState::Joined {
        return;
    }
    // v11 moved the redacted id into the content; older room versions keep
    // the top-level field.
    let redacted = ev.redacts.clone().or_else(|| ev.content.redacts.clone());
    let redacted = match redacted {
        Some(id) => id.to_string(),
        None => return,
    };

    let (reaction_update, affected_polls, poll_state) = {
        let mut locals = daemon.room_locals.lock().await;
        let local = locals.entry(room.room_id().to_owned()).or_default();
        note_event_ts(
            &mut local.event_ts,
            ev.event_id.as_ref(),
            ts_u64(ev.origin_server_ts),
        );
        // A redacted thread reply leaves the fold (see `unmerge_thread`);
        // a redacted root stays — replies' `thread_root` is still its id.
        unmerge_thread(&mut local.threads, &mut local.thread_of, &redacted);
        // A response redaction only prunes poll state (the updatePoll
        // announcements below); a start redaction drops the poll — its
        // rendered line blanks via the marked-message path.
        let was_poll_response = local
            .polls
            .values()
            .any(|votes| votes.responses.contains_key(&redacted));
        let affected_polls = poll_redaction(&mut local.polls, &redacted);
        if let Some(target) = remove_reaction(&mut local.reactions, &redacted) {
            let reactions =
                reaction_entries(&local.reactions, &target, room.own_user_id().as_str());
            (
                Some((target, reactions)),
                affected_polls,
                local.polls.clone(),
            )
        } else if was_poll_response {
            // Not a tracked reaction: a redacted poll response.
            // Responses are never rendered messages, so no
            // redacted-marker announcement.
            (None, affected_polls, local.polls.clone())
        } else {
            // A plain message (or something we never tracked) was
            // redacted.  The content is stripped server-side; announce
            // it and Emacs renders the marker.  What happens to the
            // content Emacs already holds locally is the user's
            // redaction-history setting, not ours.
            daemon.send(OutEvent::event(Event::UpdateMessageRedacted {
                profile: daemon.profile.clone(),
                room_id: room.room_id().to_string(),
                event_id: redacted,
            }));
            return;
        }
    };

    // Redacted responses still in this session's state re-render their
    // poll (a removed start is announced through the marker above).
    let own = room.own_user_id().as_str();
    for poll_id in &affected_polls {
        if let Some(poll) = poll_entry(&poll_state, poll_id, own) {
            daemon.send(OutEvent::event(Event::UpdatePoll {
                profile: daemon.profile.clone(),
                room_id: room.room_id().to_string(),
                event_id: poll_id.clone(),
                poll: Some(poll),
                // A redaction announcement re-renders; the redaction
                // event itself is not what the homeserver counts.
                source_event_id: None,
            }));
        }
    }

    if let Some((target, reactions)) = reaction_update {
        daemon.send(OutEvent::event(Event::UpdateReactions {
            profile: daemon.profile.clone(),
            room_id: room.room_id().to_string(),
            event_id: target,
            source_event_id: None,
            reactions,
        }));
    }
}

/// A live ephemeral `m.receipt` arrived: fold other members' public
/// `m.read` receipts into the room's state and announce the refreshed
/// list.  Other members' private receipts never reach us and would not
/// be display state either.  The own entries — public or private — are
/// the account's cross-device read position and go out as
/// `updateOwnReadReceipt` instead.  Like `on_reaction`, this must not
/// touch room-bar state — a receipt is display-only, not activity.
pub(crate) async fn on_receipt(daemon: SharedDaemon, ev: AnySyncEphemeralRoomEvent, room: Room) {
    use matrix_sdk::ruma::events::receipt::{ReceiptThread, ReceiptType};

    if room.state() != RoomState::Joined {
        return;
    }
    let receipts = match ev {
        AnySyncEphemeralRoomEvent::Receipt(ev) => ev.content,
        _ => return,
    };

    let own = room.own_user_id();
    // Every own receipt the block carries enters the same pool; the
    // latest position wins.  Iteration order over the block's event
    // map is arbitrary, so last-wins-per-variable once let an older
    // receipt move the read marker backwards (a batched sync can
    // carry own receipts for several events at once).
    let mut own_receipts: Vec<(String, Option<u64>)> = Vec::new();
    let mut fresh: Vec<(String, String, Option<u64>)> = Vec::new();
    for (event_id, event_receipts) in receipts.iter() {
        // Public receipts feed the other-member read-marker display;
        // own public receipts are also the account's read position.
        let Some(users) = event_receipts.get(&ReceiptType::Read) else {
            continue;
        };
        for (user, receipt) in users {
            if receipt.thread != ReceiptThread::Unthreaded {
                continue;
            }
            if user == own {
                own_receipts.push((event_id.to_string(), receipt.ts.map(ts_u64)));
                continue;
            }
            fresh.push((
                user.to_string(),
                event_id.to_string(),
                receipt.ts.map(ts_u64),
            ));
        }
    }
    // Private receipts come back only in the account's own sync (the
    // spec mechanism private-receipt clients like Element X rely on
    // for cross-device read state), so the own entries here are exactly
    // "this account read the room up to the event" — same update as an
    // own public receipt, just never shown to the room.  Other users'
    // private receipts would not appear even if servers leaked them;
    // they are not display state either, so they are ignored outright.
    for (event_id, event_receipts) in receipts.iter() {
        if let Some(users) = event_receipts.get(&ReceiptType::ReadPrivate) {
            for (user, receipt) in users {
                if user == own && receipt.thread == ReceiptThread::Unthreaded {
                    own_receipts.push((event_id.to_string(), receipt.ts.map(ts_u64)));
                }
            }
        }
    }
    let other_count = fresh.len();
    let (own, receipts) = {
        let mut locals = daemon.room_locals.lock().await;
        let local = locals.entry(room.room_id().to_owned()).or_default();
        // Ordering the account's receipts against each other needs the
        // event positions the ts map holds.
        let own = own_receipt_pos(own_receipts, &local.event_ts);
        let mut changed = false;
        for (user, event_id, ts) in fresh {
            changed |= merge_receipt(
                &mut local.receipts,
                &user,
                ReceiptPos {
                    ts: receipt_ts(ts, &local.event_ts, &event_id),
                    event_id,
                },
            );
        }
        if changed {
            prune_receipts(&mut local.receipts);
        }
        (
            own,
            changed.then(|| (local.receipts.clone(), local.event_ts.clone())),
        )
    };
    if let Some((event_id, ts)) = own {
        tracing::debug!(
            "on_receipt: own receipt {} up to {}",
            room.room_id(),
            event_id
        );
        daemon.send(OutEvent::event(Event::UpdateOwnReadReceipt {
            profile: daemon.profile.clone(),
            room_id: room.room_id().to_string(),
            event_id,
            ts,
        }));
    }
    if other_count == 0 {
        return;
    }
    let Some((receipts, event_ts)) = receipts else {
        return;
    };

    let receipts = receipt_entries(&room, &receipts, &event_ts).await;
    daemon.send(OutEvent::event(Event::UpdateReadReceipts {
        profile: daemon.profile.clone(),
        room_id: room.room_id().to_string(),
        receipts,
    }));
}

/// A room's `m.fully_read` account data moved: the account (on this or
/// another device) considers the room read up to the marker event.
/// Like `on_receipt`'s own path this is notification bookkeeping only —
/// display state and room-bar state are untouched.  The marker arrives
/// on initial sync too; consumers treat the update as idempotent.
pub(crate) fn on_fully_read(
    daemon: SharedDaemon,
    ev: matrix_sdk::ruma::events::RoomAccountDataEvent<
        matrix_sdk::ruma::events::fully_read::FullyReadEventContent,
    >,
    room: Room,
) {
    tracing::debug!(
        "on_fully_read fired: room={} event_id={}",
        room.room_id(),
        ev.content.event_id
    );
    if room.state() != RoomState::Joined {
        return;
    }
    daemon.send(OutEvent::event(Event::UpdateOwnReadReceipt {
        profile: daemon.profile.clone(),
        room_id: room.room_id().to_string(),
        event_id: ev.content.event_id.to_string(),
        ts: None,
    }));
}

/// The subdued system line for a timeline `m.room.member` state
/// event (joins, leaves, kicks, bans, display-name changes).  The
/// sentence is built daemon-side because the same line feeds the
/// room-list preview.  Ruma's `membership_change` walks the spec's
/// transition table (kicked, invitation rejected, profile changes
/// and so on); no-op and avatar-only changes render nothing.
/// Avatar-only bumps are noise — Element shows them, elneo keeps
/// the system lines to facts about membership and names.
fn member_body(
    names: &HashMap<String, String>,
    own_id: &UserId,
    target: &UserId,
    actor: &UserId,
    change: MembershipChange,
) -> Option<String> {
    use MembershipChange as Ch;
    let who = |user: &UserId| -> String {
        if user == own_id {
            "You".to_owned()
        } else {
            names
                .get(user.as_str())
                .cloned()
                .unwrap_or_else(|| user.localpart().to_owned())
        }
    };
    let (t, a) = (who(target), who(actor));
    let self_target = target == own_id;
    match change {
        Ch::Joined if self_target => Some("You joined the room".to_owned()),
        Ch::Joined => Some(format!("{t} joined the room")),
        Ch::Left if self_target => Some("You left the room".to_owned()),
        Ch::Left => Some(format!("{t} left the room")),
        Ch::Banned => Some(format!("{t} was banned by {a}")),
        Ch::Unbanned => Some(format!("{t} was unbanned by {a}")),
        Ch::Kicked => Some(format!("{t} was kicked by {a}")),
        Ch::KickedAndBanned => Some(format!("{t} was kicked and banned by {a}")),
        Ch::Invited if self_target => Some(format!("{a} invited you")),
        Ch::Invited => Some(format!("{a} invited {t}")),
        Ch::InvitationAccepted => Some(format!("{t} accepted the invitation")),
        Ch::InvitationRejected if self_target => Some("You declined the invitation".to_owned()),
        Ch::InvitationRejected => Some(format!("{t} declined the invitation")),
        Ch::InvitationRevoked => Some(format!("{a} revoked {t}'s invitation")),
        Ch::Knocked => Some(format!("{t} asked to join the room")),
        Ch::KnockAccepted => Some(format!("{t} was invited (knock accepted)")),
        Ch::KnockRetracted => Some(format!("{t} retracted the request to join")),
        Ch::KnockDenied => Some(format!("{a} denied {t}'s request to join")),
        Ch::ProfileChanged {
            displayname_change: Some(c),
            ..
        } => match (c.old, c.new) {
            (Some(old), Some(new)) => {
                Some(format!("{t} changed their display name ({old} -> {new})"))
            }
            (None, Some(new)) => Some(format!("{t} is now known as {new}")),
            (Some(old), None) => Some(format!("{t} is no longer known as {old}")),
            (None, None) => None,
        },
        // Avatar-only bumps and no-ops: nothing to say.
        Ch::ProfileChanged { .. } | Ch::None | Ch::Error | Ch::NotImplemented => None,
        // The enum is non_exhaustive; anything newer than this build
        // is an unheard-of spec change — say nothing.
        _ => None,
    }
}

// The fold below stays sync, so member names come from a
// pre-resolved map built once per page.
async fn member_names_from(
    room: &Room,
    users: &[matrix_sdk::ruma::OwnedUserId],
) -> HashMap<String, String> {
    let mut names: HashMap<String, String> = HashMap::new();
    for user in users {
        if let Some(name) = member_display_name(room, user).await {
            names.insert(user.to_string(), name);
        }
    }
    names
}

async fn member_display_name(room: &Room, sender: &UserId) -> Option<String> {
    let member = room.get_member(sender).await.ok().flatten()?;
    member
        .display_name()
        .map(str::to_owned)
        .filter(|n| !n.is_empty())
}

async fn member_avatar_url(room: &Room, sender: &UserId) -> Option<String> {
    let member = room.get_member(sender).await.ok().flatten()?;
    member.avatar_url().map(|u| u.to_string())
}

// ---------------------------------------------------------------------------
// Commands handled against the sync client
// ---------------------------------------------------------------------------

fn room_of(client: &Client, room_id: &str) -> Option<Room> {
    let room_id = RoomId::parse(room_id).ok()?;
    let room = client.get_room(&room_id)?;
    (room.state() == RoomState::Joined).then_some(room)
}

fn not_found(daemon: &SharedDaemon, req: Option<u64>, room_id: &str) {
    daemon.send(OutEvent::ack(
        req,
        false,
        Some(format!("Room not found: {room_id}")),
    ));
}

pub(crate) fn no_session(daemon: &SharedDaemon, req: Option<u64>) {
    daemon.send(OutEvent::ack(req, false, Some("No active session".into())));
}

/// Parse an event id parameter, acking the request on failure — the
/// `None` result only needs `return` at the call site.
fn parse_event_id_or_ack(
    daemon: &SharedDaemon,
    req: Option<u64>,
    event_id: &str,
) -> Option<matrix_sdk::ruma::OwnedEventId> {
    match matrix_sdk::ruma::EventId::parse(event_id) {
        Ok(id) => Some(id),
        Err(e) => {
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Invalid event id: {e}")),
            ));
            None
        }
    }
}

/// The common handler prologue: an active session plus the joined room.
/// Both failure paths ack the request themselves, so a `None` result only
/// needs `return` at the call site.
async fn room_ctx(
    daemon: &SharedDaemon,
    req: Option<u64>,
    room_id: &str,
) -> Option<(Client, Room)> {
    let Some(client) = daemon.client().await else {
        no_session(daemon, req);
        return None;
    };
    let Some(room) = room_of(&client, room_id) else {
        not_found(daemon, req, room_id);
        return None;
    };
    Some((client, room))
}

/// Emit one `updateRoom` per joined and invited room, then ack.
pub async fn handle_get_rooms(daemon: SharedDaemon, req: Option<u64>) {
    let Some(client) = daemon.client().await else {
        no_session(&daemon, req);
        return;
    };

    let mut known: Vec<String> = Vec::new();
    for room in client
        .joined_rooms()
        .into_iter()
        .chain(client.invited_rooms())
    {
        // Rooms already carrying local state (seed pass, live handlers)
        // keep it — the state is current; only a genuinely new room pays
        // the last-event fetch.  Invited rooms never do: they have no
        // timeline this side may fetch, so their summary runs on a bare
        // default local and no local is stored — a later join then takes
        // the fresh-room path in emit_unread_changes.
        let local = if room.state() == RoomState::Invited {
            RoomLocal::default()
        } else {
            // The seed needs an await (`latest_event_local` fetches),
            // so the first guard drops before it; insert and clone-out
            // then share one guard instead of two.
            let mut locals = daemon.room_locals.lock().await;
            if locals.get(room.room_id()).is_none() {
                drop(locals);
                let local = latest_event_local(&room).await;
                locals = daemon.room_locals.lock().await;
                locals.entry(room.room_id().to_owned()).or_insert(local);
            }
            locals.get(room.room_id()).cloned().unwrap_or_default()
        };
        let summary = room_summary(&room, &local).await;
        known.push(summary.room_id.clone());
        daemon.send(OutEvent::event(Event::UpdateRoom {
            profile: daemon.profile.clone(),
            room: summary,
        }));
    }

    // Tell Emacs about rooms it may still know from a previous session,
    // and drop their daemon-side state so a re-join starts fresh.
    let count = known.len();
    let known: std::collections::HashSet<String> = known.into_iter().collect();
    let gone: Vec<OwnedRoomId> = {
        let locals = daemon.room_locals.lock().await;
        locals
            .keys()
            .filter(|id| !known.contains(id.as_str()))
            .cloned()
            .collect()
    };
    info!("getRooms: announced {} rooms, {} gone", count, gone.len());
    for room_id in &gone {
        daemon.send(OutEvent::event(Event::UpdateRoomGone {
            profile: daemon.profile.clone(),
            room_id: room_id.to_string(),
        }));
    }
    if !gone.is_empty() {
        daemon
            .room_locals
            .lock()
            .await
            .retain(|id, _| !gone.contains(id));
    }

    daemon.send(OutEvent::ack(req, true, None));
}

// ---------------------------------------------------------------------------
// Membership commands: invites, voluntary join, leave, forget
// ---------------------------------------------------------------------------

fn room_state_of(client: &Client, room_id: &str, state: RoomState) -> Option<Room> {
    let room_id = RoomId::parse(room_id).ok()?;
    let room = client.get_room(&room_id)?;
    (room.state() == state).then_some(room)
}

async fn update_room_gone(daemon: &SharedDaemon, profile: &str, room_id: &str) {
    daemon.send(OutEvent::event(Event::UpdateRoomGone {
        profile: profile.to_owned(),
        room_id: room_id.to_owned(),
    }));
}

pub(crate) async fn handle_accept_invite(daemon: SharedDaemon, req: Option<u64>, room_id: String) {
    let Some(client) = daemon.client().await else {
        no_session(&daemon, req);
        return;
    };
    let Some(room) = room_state_of(&client, &room_id, RoomState::Invited) else {
        not_found(&daemon, req, &room_id);
        return;
    };
    match room.join().await {
        Ok(()) => {
            // The invite carried no local state, so the full seed (last
            // event fetch, merge) runs right here — mid-session accepts
            // get a previewed joined room without waiting for the sync
            // tick.
            seed_room(&daemon, &room).await;
            daemon.send(OutEvent::ack(req, true, None));
        }
        Err(e) => {
            tracing::error!("acceptInvite {room_id} failed: {e}");
            daemon.send(OutEvent::ack(req, false, Some(format!("Join failed: {e}"))));
        }
    }
}

pub(crate) async fn handle_decline_invite(daemon: SharedDaemon, req: Option<u64>, room_id: String) {
    let Some(client) = daemon.client().await else {
        no_session(&daemon, req);
        return;
    };
    let Some(room) = room_state_of(&client, &room_id, RoomState::Invited) else {
        not_found(&daemon, req, &room_id);
        return;
    };
    // leave() declines for an invited room and forgets it on the way —
    // the invite should not linger in account data.
    match room.leave().await {
        Ok(()) => {
            update_room_gone(&daemon, &daemon.profile, &room_id).await;
            daemon.send(OutEvent::ack(req, true, None));
        }
        Err(e) => {
            tracing::error!("declineInvite {room_id} failed: {e}");
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Decline failed: {e}")),
            ));
        }
    }
}

pub(crate) async fn handle_set_display_name(
    daemon: SharedDaemon,
    req: Option<u64>,
    name: Option<String>,
) {
    let Some(client) = daemon.client().await else {
        no_session(&daemon, req);
        return;
    };
    match client.account().set_display_name(name.as_deref()).await {
        Ok(()) => daemon.send(OutEvent::ack(req, true, None)),
        Err(e) => {
            tracing::error!("setDisplayName failed: {e}");
            daemon.send(OutEvent::ack(req, false, Some(format!("Set failed: {e}"))));
        }
    }
}

pub(crate) async fn handle_set_avatar(
    daemon: SharedDaemon,
    req: Option<u64>,
    local_path: Option<String>,
) {
    let Some(client) = daemon.client().await else {
        no_session(&daemon, req);
        return;
    };
    let result = match local_path {
        // No path on the wire clears the avatar, mirroring the
        // omitted display name above.
        None => client.account().set_avatar_url(None).await.map(|_| ()),
        Some(path) => match tokio::fs::read(&path).await {
            Ok(data) => {
                let content_type = mime_guess::from_path(&path).first_or_octet_stream();
                client
                    .account()
                    .upload_avatar(&content_type, data)
                    .await
                    .map(|_| ())
            }
            Err(e) => {
                daemon.send(OutEvent::ack(
                    req,
                    false,
                    Some(format!("Cannot read {path}: {e}")),
                ));
                return;
            }
        },
    };
    match result {
        Ok(()) => daemon.send(OutEvent::ack(req, true, None)),
        Err(e) => {
            tracing::error!("setAvatar failed: {e}");
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Avatar failed: {e}")),
            ));
        }
    }
}

pub(crate) async fn handle_set_room_avatar(
    daemon: SharedDaemon,
    req: Option<u64>,
    room_id: String,
    local_path: Option<String>,
) {
    let Some((_, room)) = room_ctx(&daemon, req, &room_id).await else {
        return;
    };
    let result = match local_path {
        // No path on the wire removes the avatar, mirroring the
        // omitted path on setAvatar above.
        None => room.remove_avatar().await.map(|_| ()),
        Some(path) => match tokio::fs::read(&path).await {
            Ok(data) => {
                let content_type = mime_guess::from_path(&path).first_or_octet_stream();
                room.upload_avatar(&content_type, data, None)
                    .await
                    .map(|_| ())
            }
            Err(e) => {
                daemon.send(OutEvent::ack(
                    req,
                    false,
                    Some(format!("Cannot read {path}: {e}")),
                ));
                return;
            }
        },
    };
    match result {
        Ok(()) => daemon.send(OutEvent::ack(req, true, None)),
        Err(e) => {
            tracing::error!("setRoomAvatar {room_id} failed: {e}");
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Avatar change failed: {e}")),
            ));
        }
    }
}

/// This session's room permissions (the `roomPermissions` response):
/// the own power level with the per-action gates the UI checks.
pub(crate) async fn handle_room_permissions(
    daemon: SharedDaemon,
    req: Option<u64>,
    room_id: String,
) {
    let Some((client, room)) = room_ctx(&daemon, req, &room_id).await else {
        return;
    };
    let Some(own) = client.user_id().map(ToOwned::to_owned) else {
        no_session(&daemon, req);
        return;
    };
    use matrix_sdk::ruma::events::room::power_levels::UserPowerLevel;
    use matrix_sdk::ruma::events::StateEventType;
    match room.power_levels().await {
        Ok(pls) => {
            let (level, creator) = match pls.for_user(&own) {
                UserPowerLevel::Infinite => (i64::MAX, true),
                UserPowerLevel::Int(level) => (level.into(), false),
                // non_exhaustive: future variants report as a plain member
                _ => (0, false),
            };
            daemon.send(OutEvent::response(
                req,
                Event::RoomPermissions {
                    room_id,
                    level,
                    creator,
                    can_name: pls.user_can_send_state(&own, StateEventType::RoomName),
                    can_topic: pls.user_can_send_state(&own, StateEventType::RoomTopic),
                    can_avatar: pls.user_can_send_state(&own, StateEventType::RoomAvatar),
                    can_invite: pls.user_can_invite(&own),
                    can_kick: pls.user_can_kick(&own),
                    can_ban: pls.user_can_ban(&own),
                    can_power: pls.user_can_send_state(&own, StateEventType::RoomPowerLevels),
                },
            ));
        }
        Err(e) => {
            tracing::error!("roomPermissions {room_id} failed: {e}");
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Permission fetch failed: {e}")),
            ));
        }
    }
}

/// This session's own profile (the `getProfile` response): the
/// homeserver's global display name and avatar mxc, the facts the
/// account page prints and its buttons edit.
pub(crate) async fn handle_get_profile(daemon: SharedDaemon, req: Option<u64>) {
    use matrix_sdk::ruma::profile::{AvatarUrl, DisplayName};
    let Some(client) = daemon.client().await else {
        no_session(&daemon, req);
        return;
    };
    let Some(own) = client.user_id().map(ToOwned::to_owned) else {
        no_session(&daemon, req);
        return;
    };
    match client.account().fetch_user_profile().await {
        Ok(resp) => daemon.send(OutEvent::response(
            req,
            Event::Profile {
                user_id: own.to_string(),
                display_name: resp.data.get_static::<DisplayName>().unwrap_or(None),
                avatar_url: resp
                    .data
                    .get_static::<AvatarUrl>()
                    .unwrap_or(None)
                    .map(|u| u.to_string()),
            },
        )),
        Err(e) => {
            tracing::error!("getProfile failed: {e}");
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Profile fetch failed: {e}")),
            ));
        }
    }
}

/// ONE level of a room's offered rooms (MSC2946 hierarchy, max_depth
/// 1): the room itself is the first row, its direct children follow.
/// A raw GET, because matrix-sdk 0.19 has no hierarchy wrapper — the
/// same homeserver+bearer pattern the media HEAD probe already uses.
/// `from`/`limit` page on exactly what a previous response's
/// `next_batch` (and the caller's page size) carried.  World-readable
/// spaces answer for sessions not joined; the homeserver's error rides
/// the ack otherwise.
/// One raw hierarchy page: query-built URL over the client's
/// homeserver, fetched with the session token, parsed as JSON.  Every
/// failure path here acks the one shared "Hierarchy lookup failed"
/// string, so a `None` result only needs `return` at the call site.
async fn hierarchy_response(
    daemon: &SharedDaemon,
    client: &Client,
    req: Option<u64>,
    room_id: &str,
    from: Option<&str>,
    limit: Option<u32>,
) -> Option<serde_json::Value> {
    let mut url = match client
        .homeserver()
        .join(&format!("/_matrix/client/v1/rooms/{room_id}/hierarchy"))
    {
        Ok(url) => url,
        Err(e) => {
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Hierarchy lookup failed: {e}")),
            ));
            return None;
        }
    };
    {
        // form_urlencoded percent-encodes the from-token; next_batch
        // tokens are opaque and the homeserver expects them back as
        // sent, one wire-echo per query round.
        let mut query = url::form_urlencoded::Serializer::new(String::new());
        query.append_pair("max_depth", "1");
        if let Some(f) = from {
            query.append_pair("from", f);
        }
        if let Some(l) = limit {
            query.append_pair("limit", &l.to_string());
        }
        url.set_query(Some(&query.finish()));
    }
    let token = match daemon.session() {
        Some(session) => session.access_token,
        None => {
            no_session(daemon, req);
            return None;
        }
    };
    let http = client.http_client();
    let resp = match http.get(url).bearer_auth(&token).send().await {
        Ok(r) => match r.error_for_status() {
            Ok(r) => r,
            Err(e) => {
                daemon.send(OutEvent::ack(
                    req,
                    false,
                    Some(format!("Hierarchy lookup failed: {e}")),
                ));
                return None;
            }
        },
        Err(e) => {
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Hierarchy lookup failed: {e}")),
            ));
            return None;
        }
    };
    let body = match resp.bytes().await {
        Ok(b) => b,
        Err(e) => {
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Hierarchy lookup failed: {e}")),
            ));
            return None;
        }
    };
    match serde_json::from_slice::<serde_json::Value>(&body) {
        Ok(value) => Some(value),
        Err(_) => {
            daemon.send(OutEvent::ack(
                req,
                false,
                Some("Hierarchy lookup failed: unparsable response".to_owned()),
            ));
            None
        }
    }
}

pub(crate) async fn handle_get_room_hierarchy(
    daemon: SharedDaemon,
    req: Option<u64>,
    room_id: String,
    from: Option<String>,
    limit: Option<u32>,
) {
    let Some(client) = daemon.client().await else {
        no_session(&daemon, req);
        return;
    };
    if RoomId::parse(&room_id).is_err() {
        daemon.send(OutEvent::ack(
            req,
            false,
            Some(format!("Invalid room id: {room_id}")),
        ));
        return;
    };

    let Some(value) =
        hierarchy_response(&daemon, &client, req, &room_id, from.as_deref(), limit).await
    else {
        return;
    };
    let rooms = value
        .get("rooms")
        .and_then(serde_json::Value::as_array)
        .map(|rows| {
            // Via servers ride the parents' m.space.child state, not
            // the flattened child rows, so collect them per parent id
            // first and hand each row its own list back.
            let vias = rows
                .iter()
                .flat_map(row_children_vias)
                .collect::<std::collections::HashMap<String, Vec<String>>>();
            rows.iter()
                .filter_map(|row| {
                    let row_via = row
                        .get("room_id")
                        .and_then(serde_json::Value::as_str)
                        .and_then(|id| vias.get(id));
                    hierarchy_row(&client, row, row_via.map(|v| v.as_slice()))
                })
                .collect::<Vec<HierarchyRoom>>()
        })
        .unwrap_or_default();
    let next_batch = value
        .get("next_batch")
        .and_then(serde_json::Value::as_str)
        .map(ToOwned::to_owned);
    daemon.send(OutEvent::response(
        req,
        Event::RoomHierarchy {
            room_id,
            rooms,
            next_batch,
        },
    ));
}

/// The `Sync`/`Stripped` state wrappers as plain JSON values — both
/// wrappers differ only in the envelope; the state JSON is the event.
fn raw_state_values(
    events: Vec<matrix_sdk::deserialized_responses::RawAnySyncOrStrippedState>,
) -> Vec<serde_json::Value> {
    events
        .into_iter()
        .filter_map(|raw| {
            let json = match raw {
                matrix_sdk::deserialized_responses::RawAnySyncOrStrippedState::Sync(raw) => {
                    raw.json().to_string()
                }
                matrix_sdk::deserialized_responses::RawAnySyncOrStrippedState::Stripped(raw) => {
                    raw.json().to_string()
                }
            };
            serde_json::from_str(&json).ok()
        })
        .collect()
}

/// The (parent id, canonical) pairs in a room's `m.space.parent` state
/// values: parent from the `state_key`, the canonical flag from the
/// content; a room may carry several parent events (declared by
/// several spaces) and the canonical one (`content.canonical: true`)
/// sorts first, the rest follow.
fn parent_ids_from_events(events: &[serde_json::Value]) -> Vec<(String, bool)> {
    let mut parents: Vec<(String, bool)> = events
        .iter()
        .filter_map(|value| {
            if value.get("type").and_then(serde_json::Value::as_str) != Some("m.space.parent") {
                return None;
            }
            let parent = value.get("state_key").and_then(serde_json::Value::as_str)?;
            let canonical = value
                .pointer("/content/canonical")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(false);
            Some((parent.to_owned(), canonical))
        })
        .collect();
    parents.sort_by_key(|(_, canonical)| !*canonical);
    parents
}

/// The upgrade successor(s) in a room's `m.room.tombstone` values.
fn successor_ids(events: &[serde_json::Value]) -> Vec<String> {
    events
        .iter()
        .filter_map(|value| {
            value
                .pointer("/content/replacement_room")
                .and_then(serde_json::Value::as_str)
                .map(ToOwned::to_owned)
        })
        .collect()
}

/// The upgrade predecessor(s) in a room's state values: the
/// `predecessor` field of `m.room.create` (the spec's place), the
/// dynamic `m.room.predecessor` event (its content carries the room id
/// directly) whatever the homeserver recorded.
fn predecessor_ids(events: &[serde_json::Value]) -> Vec<String> {
    events
        .iter()
        .filter_map(|value| {
            value
                .pointer("/content/predecessor/room_id")
                .or_else(|| value.pointer("/content/predecessor_room_id"))
                .and_then(serde_json::Value::as_str)
                .map(ToOwned::to_owned)
        })
        .collect()
}

/// A room summary's upgrade link: the first id in an extracted link
/// list, None when the room carries no such link (an empty state read).
fn first_link_id(ids: Vec<String>) -> Option<String> {
    ids.into_iter().find(|id| !id.is_empty())
}

/// One chain walk step over gathered link tables: the ids reachable
/// one generation out of the frontier (successors forward,
/// predecessors back), skipping everything already seen.
fn chain_next_ids(
    frontier: &[String],
    links: &HashMap<String, (Vec<String>, Vec<String>)>,
    seen: &mut HashSet<String>,
) -> Vec<String> {
    let mut next = Vec::new();
    for id in frontier {
        let Some((successors, predecessors)) = links.get(id) else {
            continue;
        };
        for target in successors.iter().chain(predecessors.iter()) {
            if seen.insert(target.clone()) {
                next.push(target.clone());
            }
        }
    }
    next
}

/// Whether a space's `m.space.child` values list any of the accepted
/// room ids (the room itself or an upgrade-chain member).
fn child_matches(events: &[serde_json::Value], accept: &HashSet<String>) -> bool {
    events
        .iter()
        .filter_map(|value| value.get("state_key").and_then(serde_json::Value::as_str))
        .any(|child| accept.contains(child))
}

/// The ids that count as "this room" for space membership: the room
/// itself plus its upgrade chain, walking `m.room.tombstone` and
/// `m.room.create`/`m.room.predecessor` links out of the local state
/// store, generation by generation, at most [CHAIN_HOPS] far.  A
/// room without an upgrade history is a single no-op generation; the
/// per-read failures swallow as linkless (best effort, like every
/// other read of that shape).
async fn room_chain_ids(client: &Client, room_id: &RoomId) -> HashSet<String> {
    const CHAIN_HOPS: usize = 8;
    let mut accept: HashSet<String> = HashSet::from([room_id.to_string()]);
    let mut links: HashMap<String, (Vec<String>, Vec<String>)> = HashMap::new();
    let mut frontier: Vec<String> = vec![room_id.to_string()];
    for _ in 0..CHAIN_HOPS {
        if frontier.is_empty() {
            break;
        }
        let mut fetched: Vec<(String, Vec<String>, Vec<String>)> = Vec::new();
        for id in &frontier {
            let Ok(parsed) = RoomId::parse(id) else {
                continue;
            };
            let Some(room) = client.get_room(&parsed) else {
                continue;
            };
            let tombstones = state_values(&room, "m.room.tombstone").await;
            let mut predecessors = state_values(&room, "m.room.create").await;
            predecessors.extend(state_values(&room, "m.room.predecessor").await);
            fetched.push((
                id.clone(),
                successor_ids(&tombstones),
                predecessor_ids(&predecessors),
            ));
        }
        for (id, successors, predecessors) in fetched {
            links.insert(id, (successors, predecessors));
        }
        frontier = chain_next_ids(&frontier, &links, &mut accept);
    }
    accept
}

/// The state events of one type in a room, as plain JSON values; a
/// failed read is linkless, not an error (the chain walk is
/// best-effort).
async fn state_values(room: &Room, event_type: &str) -> Vec<serde_json::Value> {
    room.get_state_events(event_type.into())
        .await
        .map_or_else(|_| Vec::new(), raw_state_values)
}

/// The pinned event ids out of `m.room.pinned_events` state values:
/// the content's `pinned` array, strings only, order kept, deduped.
fn pinned_from_state(events: &[serde_json::Value]) -> Vec<String> {
    let mut seen = HashSet::new();
    events
        .iter()
        .filter_map(|v| v.pointer("/content/pinned"))
        .filter_map(|pinned| pinned.as_array())
        .flatten()
        .filter_map(|id| id.as_str())
        .filter(|id| seen.insert(id.to_string()))
        .map(str::to_owned)
        .collect()
}

/// Apply a pin/unpin to the pinned list: pin appends a missing id,
/// unpin removes it — `None` when the list would not change (the
/// handler then succeeds without sending anything).
fn pin_toggle(current: &[String], id: &str, unpin: bool) -> Option<Vec<String>> {
    let has = current.iter().any(|p| p == id);
    if unpin {
        if !has {
            return None;
        }
        Some(current.iter().filter(|p| *p != id).cloned().collect())
    } else {
        if has {
            return None;
        }
        Some(current.iter().cloned().chain([id.to_owned()]).collect())
    }
}

/// The `roomSpaces` supplement's merge: the child-scan finds fold in
/// after the parent-event parents (canonical first unchanged), deduped
/// by id, extras as non-canonical.
fn merge_space_parents(parents: Vec<(String, bool)>, extra: Vec<String>) -> Vec<(String, bool)> {
    let mut seen: HashSet<String> = HashSet::new();
    parents
        .into_iter()
        .chain(extra.into_iter().map(|id| (id, false)))
        .filter(|(id, _)| seen.insert(id.clone()))
        .collect()
}

/// One `getRoomSpaces` response: the `m.space.parent` state events a
/// room carries (state_key = the parent's room id), canonical parent
/// first — plus, folded in, every joined space of this session whose
/// `m.space.child` lists the room or one of its upgrade-chain ids
/// (rooms joined by invite often carry no own parent event; child
/// state is how other clients compute the same fact).  Metadata rides
/// only when this session knows the parent; `joined` says as much, and
/// a parent listed but not joined answers later hierarchy lookups with
/// the homeserver's honest refusal.
pub(crate) async fn handle_get_room_spaces(
    daemon: SharedDaemon,
    req: Option<u64>,
    room_id: String,
) {
    let Some(client) = daemon.client().await else {
        no_session(&daemon, req);
        return;
    };
    let Ok(parsed) = RoomId::parse(&room_id) else {
        daemon.send(OutEvent::ack(
            req,
            false,
            Some(format!("Invalid room id: {room_id}")),
        ));
        return;
    };
    let Some(room) = client.get_room(&parsed) else {
        daemon.send(OutEvent::ack(
            req,
            false,
            Some("Room not joined".to_owned()),
        ));
        return;
    };
    let values = match room.get_state_events("m.space.parent".into()).await {
        Ok(events) => raw_state_values(events),
        Err(e) => {
            tracing::error!("getRoomSpaces {room_id} state read failed: {e}");
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Parent lookup failed: {e}")),
            ));
            return;
        }
    };
    let mut parents = parent_ids_from_events(&values);
    // The supplement: other clients decide space membership from the
    // session's joined spaces' child state, and rooms migrated into a
    // space by invite or through an upgrade chain may carry no own
    // `m.space.parent` at all.  Every joined space whose child state
    // lists the room or one of its chain members folds in.
    let accept = room_chain_ids(&client, &parsed).await;
    let found = join_all(client.joined_rooms().into_iter().map(|room| {
        let accept = accept.clone();
        let parsed = parsed.clone();
        async move {
            if !room.is_space() || room.room_id().as_str() == parsed.as_str() {
                return None;
            }
            let listed = match room.get_state_events("m.space.child".into()).await {
                Ok(events) => raw_state_values(events),
                Err(_) => return None,
            };
            child_matches(&listed, &accept).then(|| room.room_id().to_string())
        }
    }))
    .await
    .into_iter()
    .flatten()
    .collect();
    parents = merge_space_parents(parents, found);

    let spaces = parents
        .iter()
        .map(|(parent, _)| {
            // Only the parent's identity and (when this session knows
            // the room locally) its metadata matter for the overview
            // line — the join rule of a PARENT is not a browsing fact,
            // so the field stays "unknown".
            match RoomId::parse(parent)
                .ok()
                .and_then(|id| client.get_room(&id))
            {
                Some(room) => HierarchyRoom {
                    room_id: parent.clone(),
                    name: room.name(),
                    topic: room.topic(),
                    canonical_alias: room.canonical_alias().map(|a| a.to_string()),
                    avatar_url: room.avatar_url().map(|u| u.to_string()),
                    num_joined_members: 0,
                    join_rule: "unknown".to_owned(),
                    room_type: Some("m.space".to_owned()),
                    joined: room.state() == RoomState::Joined,
                    via: None,
                },
                None => hierarchy_row_unjoined(parent),
            }
        })
        .collect::<Vec<HierarchyRoom>>();
    daemon.send(OutEvent::response(
        req,
        Event::RoomSpaces { room_id, spaces },
    ));
}

/// One hierarchy row from the homeserver's JSON chunk (the flattened
/// `ruma_common::room::RoomSummary` fields the endpoint answers with):
/// the flat metadata, the join-rule string and this session's
/// membership state — the [Join]/[Open] fork's raw material.  VIA is
/// the row's own via list, extracted from the parent rows'
/// `children_state` by the caller (`row_children_vias`): a remote
/// room's join route when nothing resolves.
fn hierarchy_row(
    client: &Client,
    row: &serde_json::Value,
    via: Option<&[String]>,
) -> Option<HierarchyRoom> {
    let room_id = row.get("room_id").and_then(serde_json::Value::as_str)?;
    let parsed = RoomId::parse(room_id).ok()?;
    let joined = client
        .get_room(&parsed)
        .map(|room| room.state() == RoomState::Joined)
        .unwrap_or(false);
    Some(HierarchyRoom {
        room_id: room_id.to_owned(),
        name: row
            .get("name")
            .and_then(serde_json::Value::as_str)
            .map(ToOwned::to_owned),
        topic: row
            .get("topic")
            .and_then(serde_json::Value::as_str)
            .map(ToOwned::to_owned),
        canonical_alias: row
            .get("canonical_alias")
            .and_then(serde_json::Value::as_str)
            .map(ToOwned::to_owned),
        avatar_url: row
            .get("avatar_url")
            .and_then(serde_json::Value::as_str)
            .map(ToOwned::to_owned),
        num_joined_members: row
            .get("num_joined_members")
            .and_then(serde_json::Value::as_u64)
            .unwrap_or(0),
        join_rule: row
            .get("join_rule")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("invite")
            .to_owned(),
        room_type: row
            .get("room_type")
            .and_then(serde_json::Value::as_str)
            .map(ToOwned::to_owned),
        joined,
        via: via.map(<[String]>::to_vec),
    })
}

/// A row's `children_state` as (child room id, via servers) pairs.
/// The hierarchy answer only flattens the parents; a child's join
/// route rides its parent's `m.space.child` state here, and the
/// caller builds the room-id -> via map the rows feed on.  An entry
/// with no `via` (a same-server child, mostly) yields nothing.
fn row_children_vias(row: &serde_json::Value) -> Vec<(String, Vec<String>)> {
    row.get("children_state")
        .and_then(serde_json::Value::as_array)
        .map(|entries| {
            entries
                .iter()
                .filter_map(|entry| {
                    let state_key = entry.get("state_key").and_then(serde_json::Value::as_str)?;
                    let via = entry
                        .get("content")
                        .and_then(|c| c.get("via"))
                        .and_then(serde_json::Value::as_array)
                        .map(|servers| {
                            servers
                                .iter()
                                .filter_map(serde_json::Value::as_str)
                                .map(ToOwned::to_owned)
                                .collect::<Vec<String>>()
                        })
                        .unwrap_or_default();
                    if via.is_empty() {
                        None
                    } else {
                        Some((state_key.to_owned(), via))
                    }
                })
                .collect()
        })
        .unwrap_or_default()
}

/// A parent-room row for `roomSpaces` where the session knows nothing
/// about the parent (not joined, no local state): the identity only —
/// the overview shows it by room id and [Browse] asks the homeserver.
fn hierarchy_row_unjoined(parent: &str) -> HierarchyRoom {
    HierarchyRoom {
        room_id: parent.to_owned(),
        name: None,
        topic: None,
        canonical_alias: None,
        avatar_url: None,
        num_joined_members: 0,
        join_rule: "unknown".to_owned(),
        room_type: Some("m.space".to_owned()),
        joined: false,
        via: None,
    }
}

pub(crate) async fn handle_join_room(
    daemon: SharedDaemon,
    req: Option<u64>,
    room: String,
    via: Option<Vec<String>>,
) {
    let Some(client) = daemon.client().await else {
        no_session(&daemon, req);
        return;
    };
    let Ok(parsed) = matrix_sdk::ruma::RoomOrAliasId::parse(room.as_str()) else {
        daemon.send(OutEvent::ack(
            req,
            false,
            Some(format!("Invalid room id or alias: {room}")),
        ));
        return;
    };
    // Accepting a direct-flagged invite has to file the room under
    // m.direct: a joined room's is-direct state reads that account
    // data, and the invite's flag is lost on the transition to join.
    // Peek before joining — the stripped member event is gone after.
    let dm_peer = peek_dm_peer(&client, &parsed).await;
    let empty: Vec<String> = Vec::new();
    let servers: Vec<matrix_sdk::ruma::OwnedServerName> = via
        .unwrap_or(empty)
        .iter()
        .filter_map(|s| matrix_sdk::ruma::ServerName::parse(s).ok())
        .collect();
    match client.join_room_by_id_or_alias(&parsed, &servers).await {
        Ok(joined) => {
            if let Some(peer) = dm_peer {
                if let Err(e) = client.account().mark_as_dm(joined.room_id(), &[peer]).await {
                    tracing::error!("joinRoom mark_as_dm {} failed: {e}", joined.room_id());
                }
            }
            seed_room(&daemon, &joined).await;
            // The response event lets Emacs open the room even when the
            // command went in by alias.
            daemon.send(OutEvent::response(
                req,
                Event::RoomJoined {
                    room_id: joined.room_id().to_string(),
                },
            ));
        }
        Err(e) => {
            tracing::error!("joinRoom {room} failed: {e}");
            daemon.send(OutEvent::ack(req, false, Some(format!("Join failed: {e}"))));
        }
    }
}

/// The DM peer of an invited room, if the invite carries the direct
/// flag: our own member event is still in its stripped form, and its
/// sender is the inviter.  Aliases resolve first; anything but an
/// invite returns none, because joining your way into a room never
/// means "accept a DM".
async fn peek_dm_peer(
    client: &Client,
    target: &matrix_sdk::ruma::RoomOrAliasId,
) -> Option<OwnedUserId> {
    let room_id: OwnedRoomId = if target.as_str().starts_with('!') {
        RoomId::parse(target.as_str()).ok()?.to_owned()
    } else {
        let Ok(alias) = matrix_sdk::ruma::RoomAliasId::parse(target.as_str()) else {
            return None;
        };
        match client.resolve_room_alias(&alias).await {
            Ok(resolved) => resolved.room_id,
            Err(e) => {
                tracing::warn!("joinRoom alias resolve {target} failed: {e}");
                return None;
            }
        }
    };
    let room = client.get_room(&room_id)?;
    if room.state() != RoomState::Invited {
        return None;
    }
    let own = client.user_id()?;
    let member = room.get_member(own).await.ok().flatten()?;
    match member.event().as_ref() {
        matrix_sdk::deserialized_responses::MemberEvent::Stripped(event) => {
            if event.content.is_direct != Some(true) {
                None
            } else {
                Some(event.sender.clone())
            }
        }
        // A sync member event cannot be an invite; the flag would be
        // lost anyway, which is exactly why this runs before joining.
        _ => None,
    }
}

/// The encrypted-room initial_state entry as a complete state event:
/// `{"type":"m.room.encryption","content":{…},"state_key":""}`.
/// Synapse's createRoom reads `val["content"]` — a bare content
/// object makes the whole request fail with 500 M_UNKNOWN.
fn encryption_initial_state(
) -> matrix_sdk::ruma::serde::Raw<matrix_sdk::ruma::events::AnyInitialStateEvent> {
    matrix_sdk::ruma::events::InitialStateEvent::with_empty_state_key(
        matrix_sdk::ruma::events::room::encryption::RoomEncryptionEventContent::with_recommended_defaults(),
    )
    .to_raw_any()
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_create_room(
    daemon: SharedDaemon,
    req: Option<u64>,
    name: Option<String>,
    alias: Option<String>,
    public: bool,
    topic: Option<String>,
    invites: Vec<String>,
    is_direct: bool,
    encrypted: bool,
) {
    let Some(client) = daemon.client().await else {
        no_session(&daemon, req);
        return;
    };
    // One malformed id rejects the request — an invite half-ignored
    // here would silently skip a person the user asked for.
    let mut invitees = Vec::with_capacity(invites.len());
    for id in &invites {
        match matrix_sdk::ruma::UserId::parse(id) {
            Ok(uid) => invitees.push(uid),
            Err(_) => {
                daemon.send(OutEvent::ack(
                    req,
                    false,
                    Some(format!("Invalid user id: {id}")),
                ));
                return;
            }
        }
    }
    let mut request = matrix_sdk::ruma::api::client::room::create_room::v3::Request::new();
    request.name = name;
    request.topic = topic;
    request.room_alias_name = alias;
    request.preset = Some(if public {
        matrix_sdk::ruma::api::client::room::create_room::v3::RoomPreset::PublicChat
    } else {
        matrix_sdk::ruma::api::client::room::create_room::v3::RoomPreset::PrivateChat
    });
    request.visibility = if public {
        matrix_sdk::ruma::api::client::room::Visibility::Public
    } else {
        matrix_sdk::ruma::api::client::room::Visibility::Private
    };
    request.invite = invitees.clone();
    request.is_direct = is_direct;
    if encrypted {
        // Initial state rides the create request — a follow-up state
        // send would race the invites.  Direct messages are encrypted
        // by default on every modern client.
        request.initial_state = vec![encryption_initial_state()];
    }
    match client.create_room(request).await {
        Ok(created) => {
            if is_direct && !invitees.is_empty() {
                // File the room under m.direct: the room's own
                // is-direct state reads that account data, so the very
                // first summary may still say not-direct until the
                // next /sync turns dm_targets over.
                if let Err(e) = client
                    .account()
                    .mark_as_dm(created.room_id(), &invitees)
                    .await
                {
                    // The room exists; failing the whole create over a
                    // book-keeping write would strand it.  Report only.
                    tracing::error!("createRoom mark_as_dm failed: {e}");
                }
            }
            seed_room(&daemon, &created).await;
            daemon.send(OutEvent::response(
                req,
                Event::RoomJoined {
                    room_id: created.room_id().to_string(),
                },
            ));
        }
        Err(e) => {
            tracing::error!("createRoom failed: {e}");
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Create failed: {e}")),
            ));
        }
    }
}

pub(crate) async fn handle_leave_room(daemon: SharedDaemon, req: Option<u64>, room_id: String) {
    let Some((_, room)) = room_ctx(&daemon, req, &room_id).await else {
        return;
    };
    match room.leave().await {
        Ok(()) => {
            daemon.room_locals.lock().await.remove(room_id.as_str());
            update_room_gone(&daemon, &daemon.profile, &room_id).await;
            daemon.send(OutEvent::ack(req, true, None));
        }
        Err(e) => {
            tracing::error!("leaveRoom {room_id} failed: {e}");
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Leave failed: {e}")),
            ));
        }
    }
}

pub(crate) async fn handle_forget_room(daemon: SharedDaemon, req: Option<u64>, room_id: String) {
    let Some(client) = daemon.client().await else {
        no_session(&daemon, req);
        return;
    };
    let Some(room) = room_state_of(&client, &room_id, RoomState::Left) else {
        not_found(&daemon, req, &room_id);
        return;
    };
    // The server refuses to forget a room the user is still in; the
    // UI only offers forget on left rooms, and the error surfaces raw.
    match room.forget().await {
        Ok(()) => {
            daemon.room_locals.lock().await.remove(room_id.as_str());
            update_room_gone(&daemon, &daemon.profile, &room_id).await;
            daemon.send(OutEvent::ack(req, true, None));
        }
        Err(e) => {
            tracing::error!("forgetRoom {room_id} failed: {e}");
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Forget failed: {e}")),
            ));
        }
    }
}

pub(crate) async fn handle_invite_user(
    daemon: SharedDaemon,
    req: Option<u64>,
    room_id: String,
    user_id: String,
) {
    let Some((_, room)) = room_ctx(&daemon, req, &room_id).await else {
        return;
    };
    let Ok(uid) = matrix_sdk::ruma::UserId::parse(&user_id) else {
        daemon.send(OutEvent::ack(
            req,
            false,
            Some(format!("Invalid user id: {user_id}")),
        ));
        return;
    };
    match room.invite_user_by_id(&uid).await {
        Ok(()) => daemon.send(OutEvent::ack(req, true, None)),
        Err(e) => {
            tracing::error!("inviteUser {room_id} {user_id} failed: {e}");
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Invite failed: {e}")),
            ));
        }
    }
}

pub(crate) async fn handle_kick_user(
    daemon: SharedDaemon,
    req: Option<u64>,
    room_id: String,
    user_id: String,
    reason: Option<String>,
) {
    let Some((_, room)) = room_ctx(&daemon, req, &room_id).await else {
        return;
    };
    let Ok(uid) = matrix_sdk::ruma::UserId::parse(&user_id) else {
        daemon.send(OutEvent::ack(
            req,
            false,
            Some(format!("Invalid user id: {user_id}")),
        ));
        return;
    };
    match room.kick_user(&uid, reason.as_deref()).await {
        Ok(()) => daemon.send(OutEvent::ack(req, true, None)),
        Err(e) => {
            tracing::error!("kickUser {room_id} {user_id} failed: {e}");
            daemon.send(OutEvent::ack(req, false, Some(format!("Kick failed: {e}"))));
        }
    }
}

pub(crate) async fn handle_ban_user(
    daemon: SharedDaemon,
    req: Option<u64>,
    room_id: String,
    user_id: String,
    reason: Option<String>,
) {
    let Some((_, room)) = room_ctx(&daemon, req, &room_id).await else {
        return;
    };
    let Ok(uid) = matrix_sdk::ruma::UserId::parse(&user_id) else {
        daemon.send(OutEvent::ack(
            req,
            false,
            Some(format!("Invalid user id: {user_id}")),
        ));
        return;
    };
    match room.ban_user(&uid, reason.as_deref()).await {
        Ok(()) => daemon.send(OutEvent::ack(req, true, None)),
        Err(e) => {
            tracing::error!("banUser {room_id} {user_id} failed: {e}");
            daemon.send(OutEvent::ack(req, false, Some(format!("Ban failed: {e}"))));
        }
    }
}

pub(crate) async fn handle_unban_user(
    daemon: SharedDaemon,
    req: Option<u64>,
    room_id: String,
    user_id: String,
) {
    let Some((_, room)) = room_ctx(&daemon, req, &room_id).await else {
        return;
    };
    let Ok(uid) = matrix_sdk::ruma::UserId::parse(&user_id) else {
        daemon.send(OutEvent::ack(
            req,
            false,
            Some(format!("Invalid user id: {user_id}")),
        ));
        return;
    };
    match room.unban_user(&uid, None).await {
        Ok(()) => daemon.send(OutEvent::ack(req, true, None)),
        Err(e) => {
            tracing::error!("unbanUser {room_id} {user_id} failed: {e}");
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Unban failed: {e}")),
            ));
        }
    }
}

pub(crate) async fn handle_set_room_name(
    daemon: SharedDaemon,
    req: Option<u64>,
    room_id: String,
    name: String,
) {
    let Some((_, room)) = room_ctx(&daemon, req, &room_id).await else {
        return;
    };
    match room.set_name(name).await {
        Ok(_response) => daemon.send(OutEvent::ack(req, true, None)),
        Err(e) => {
            tracing::error!("setRoomName {room_id} failed: {e}");
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Name change failed: {e}")),
            ));
        }
    }
}

pub(crate) async fn handle_set_room_topic(
    daemon: SharedDaemon,
    req: Option<u64>,
    room_id: String,
    topic: String,
) {
    let Some((_, room)) = room_ctx(&daemon, req, &room_id).await else {
        return;
    };
    match room.set_room_topic(&topic).await {
        Ok(_response) => daemon.send(OutEvent::ack(req, true, None)),
        Err(e) => {
            tracing::error!("setRoomTopic {room_id} failed: {e}");
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Topic change failed: {e}")),
            ));
        }
    }
}

/// Own per-room nick: PUT the session account's `m.room.member` state
/// for this room with the new `displayname`, leaving the global
/// profile untouched (`setDisplayName`'s room-scoped counterpart —
/// SDK 0.19's `set_own_member_display_name` reads the current member
/// state, mutates only the displayname field and re-PUTs it).  An
/// omitted name clears the room-local one.
pub(crate) async fn handle_set_own_display_name(
    daemon: SharedDaemon,
    req: Option<u64>,
    room_id: String,
    name: Option<String>,
) {
    let Some((_, room)) = room_ctx(&daemon, req, &room_id).await else {
        return;
    };
    match room.set_own_member_display_name(name).await {
        Ok(_response) => daemon.send(OutEvent::ack(req, true, None)),
        Err(e) => {
            tracing::error!("setOwnDisplayName {room_id} failed: {e}");
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Nick change failed: {e}")),
            ));
        }
    }
}

#[allow(clippy::too_many_arguments)]
pub async fn handle_send_message(
    daemon: SharedDaemon,
    req: Option<u64>,
    room_id: String,
    body: String,
    formatted_body: Option<String>,
    reply_to: Option<String>,
    thread_root: Option<String>,
    mentions: Option<Vec<String>>,
    room_mentions: bool,
    replaces: Option<String>,
) {
    let Some((_, room)) = room_ctx(&daemon, req, &room_id).await else {
        return;
    };

    // `text_html` builds both bodies; the plain one stays the
    // fallback for clients without rich rendering.  Built before
    // `make_replacement`: it moves the whole content (formatted part
    // included) into `m.new_content`.
    let mut content = match formatted_body {
        Some(html) => {
            matrix_sdk::ruma::events::room::message::RoomMessageEventContent::text_html(body, html)
        }
        None => matrix_sdk::ruma::events::room::message::RoomMessageEventContent::text_plain(body),
    };
    if let Some(ids) = mentions.as_deref() {
        if let Some(mentions) = mentions_from(ids, room_mentions) {
            // `m.mentions` (MSC3952): receivers' mention-aware alerts
            // read this block, not the body.  Unparseable ids are
            // skipped, so a client bug never breaks the send.
            content.mentions = Some(mentions);
        }
    }
    if let Some(replaces) = replaces {
        // Text edits only: `make_replacement` moves the msgtype into
        // `m.new_content` and rewrites the body with the `* ` fallback
        // other clients render.  It owns `relates_to`, so editing and
        // replying in one event is not possible — the Emacs side keeps
        // them mutually exclusive.
        let Some(replaces_id) = parse_event_id_or_ack(&daemon, req, &replaces) else {
            return;
        };
        content = content.make_replacement(
            matrix_sdk::ruma::events::room::message::ReplacementMetadata::new(replaces_id, None),
        );
    } else if let Some(root) = thread_root.as_deref() {
        // Thread send (MSC3440): parse the root (and any reply leg)
        // here, so the fold's latest only feeds a validated relation.
        let Some(root_id) = parse_event_id_or_ack(&daemon, req, root) else {
            return;
        };
        let reply_id = match reply_to.as_deref() {
            None => None,
            Some(r) => {
                let Some(reply) = parse_event_id_or_ack(&daemon, req, r) else {
                    return;
                };
                Some(reply)
            }
        };
        // The fold's latest, for the fallback relation thread-less
        // clients follow.  The room_locals snapshot doubles as
        // Element-style freshness: an opening thread page merges its
        // bundled summaries before this read (getThreadMessages path
        // below), so the fallback lands on a true "the latest we saw".
        let fold_latest = thread_fold_latest(&daemon, &room, root).await;
        content.relates_to = Some(thread_relation_for(
            &root_id,
            reply_id.as_deref(),
            fold_latest.as_deref(),
        ));
    } else if let Some(reply_to) = reply_to {
        // ruma 0.35 generates no rich-reply fallback, so the bare
        // relation is the spec-valid minimal reply.
        let Some(reply_id) = parse_event_id_or_ack(&daemon, req, &reply_to) else {
            return;
        };
        content.relates_to = Some(Relation::Reply(Reply::with_event_id(reply_id)));
    }
    match room.send(content).await {
        Ok(response) => {
            daemon.send(OutEvent::response(
                req,
                Event::UpdateSendResult {
                    room_id,
                    event_id: Some(response.response.event_id.to_string()),
                },
            ));
        }
        Err(e) => {
            tracing::error!("sendMessage failed: {}", e);
            daemon.send(OutEvent::ack(req, false, Some(format!("Send failed: {e}"))));
        }
    }
}

/// Redact (delete) an event in a room.  The UI update arrives via the live
/// `on_redaction` handler, so the ack only reports success.
pub async fn handle_redact_message(
    daemon: SharedDaemon,
    req: Option<u64>,
    room_id: String,
    event_id: String,
    reason: Option<String>,
) {
    let Some((_, room)) = room_ctx(&daemon, req, &room_id).await else {
        return;
    };
    let Some(target) = parse_event_id_or_ack(&daemon, req, &event_id) else {
        return;
    };
    match room.redact(&target, reason.as_deref(), None).await {
        Ok(response) => {
            daemon.send(OutEvent::response(
                req,
                Event::UpdateSendResult {
                    room_id,
                    event_id: Some(response.event_id.to_string()),
                },
            ));
        }
        Err(e) => {
            tracing::error!("redactMessage failed: {}", e);
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Redaction failed: {e}")),
            ));
        }
    }
}

/// The user's own reaction event ids for `key` on `target`, straight
/// from the server: the in-memory aggregate only holds reactions this
/// daemon session saw (live sync or backfill), so a toggle-off for a
/// reaction added before a restart would otherwise find nothing and
/// silently no-op; the server always knows.  Paginates: a single
/// limited page is not enough — one message with 100+ annotations of
/// any kind can push the own reaction past the first page, and a
/// toggle that misses it would ack success while the reaction stays
/// on the server.  A completed listing finding nothing is a
/// legitimate empty result; an error (or a pathological room that
/// outlasts the page cap) must be reported, not treated as "nothing
/// to remove".
async fn own_reactions_from_server(
    room: &Room,
    target: &matrix_sdk::ruma::EventId,
    key: &str,
    own_user_id: &str,
) -> Result<Vec<String>, anyhow::Error> {
    const PAGE: u32 = 200;
    const MAX_PAGES: usize = 25;
    let mut from = None;
    let mut ids = Vec::new();
    for _ in 0..MAX_PAGES {
        let opts = RelationsOptions {
            include_relations: IncludeRelations::RelationsOfType(RelationType::Annotation),
            limit: Some(PAGE.into()),
            from: from.take(),
            ..Default::default()
        };
        let relations = room
            .relations(target.to_owned(), opts)
            .await
            .map_err(|e| anyhow::anyhow!("relation listing failed: {e}"))?;
        for item in relations.chunk {
            let Ok(AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::Reaction(
                SyncMessageLikeEvent::Original(m),
            ))) = item.raw().deserialize()
            else {
                continue;
            };
            if m.sender.as_str() == own_user_id && m.content.relates_to.key == key {
                ids.push(m.event_id.to_string());
            }
        }
        match relations.next_batch_token {
            Some(token) => from = Some(token),
            None => return Ok(ids),
        }
    }
    Err(anyhow::anyhow!(
        "relation listing did not finish in {MAX_PAGES} pages"
    ))
}

/// Add an `m.reaction` to an event, or — with `remove` — toggle it off by
/// redacting every own reaction event with that key.  UI updates arrive via
/// the live `on_redaction` handler; removing nothing still acks success so
/// the toggle stays idempotent.
pub async fn handle_send_reaction(
    daemon: SharedDaemon,
    req: Option<u64>,
    room_id: String,
    event_id: String,
    key: String,
    remove: Option<bool>,
) {
    let Some((_, room)) = room_ctx(&daemon, req, &room_id).await else {
        return;
    };
    let Some(target) = parse_event_id_or_ack(&daemon, req, &event_id) else {
        return;
    };

    if remove == Some(true) {
        remove_own_reactions(&daemon, req, room_id, &room, &target, &key).await;
    } else {
        let content = ReactionEventContent::new(Annotation::new(target, key));
        match room.send(content).await {
            Ok(response) => {
                daemon.send(OutEvent::response(
                    req,
                    Event::UpdateSendResult {
                        room_id,
                        event_id: Some(response.response.event_id.to_string()),
                    },
                ));
            }
            Err(e) => {
                tracing::error!("sendReaction failed: {}", e);
                daemon.send(OutEvent::ack(
                    req,
                    false,
                    Some(format!("Reaction failed: {e}")),
                ));
            }
        }
    }
}

/// The sendReaction remove branch: redact every own reaction event
/// found for the key on the target.  The in-memory aggregate answers
/// when this daemon session saw the reaction; empty there falls back
/// to the server's relation listing (the reaction may predate the
/// daemon start).  Acks the request itself on the failure paths; a
/// clean no-op and a completed remove both report success.
async fn remove_own_reactions(
    daemon: &SharedDaemon,
    req: Option<u64>,
    room_id: String,
    room: &Room,
    target: &matrix_sdk::ruma::EventId,
    key: &str,
) {
    let own_user_id = room.own_user_id().to_string();
    let mut own_reaction_ids: Vec<String> = {
        let locals = daemon.room_locals.lock().await;
        locals
            .get(room.room_id())
            .and_then(|l| l.reactions.get(target.as_str()))
            .and_then(|keys| keys.get(key))
            .map(|events| {
                events
                    .iter()
                    .filter(|(_, sender)| **sender == own_user_id)
                    .map(|(id, _)| id.clone())
                    .collect()
            })
            .unwrap_or_default()
    };
    if own_reaction_ids.is_empty() {
        // Nothing in this session's aggregate — the reaction predates
        // the daemon start (or its backfill).  Ask the server before
        // declaring the toggle a no-op; an unreadable listing is not
        // the same answer as "nothing there".
        match own_reactions_from_server(room, target, key, &own_user_id).await {
            Ok(found) => own_reaction_ids = found,
            Err(e) => {
                tracing::error!("sendReaction remove: {e}");
                daemon.send(OutEvent::ack(
                    req,
                    false,
                    Some(format!("Reaction check failed: {e}")),
                ));
                return;
            }
        }
    }
    if own_reaction_ids.is_empty() {
        // Nothing to remove anywhere; idempotent success.
        daemon.send(OutEvent::response(
            req,
            Event::UpdateSendResult {
                room_id,
                event_id: None,
            },
        ));
        return;
    }
    let mut error: Option<matrix_sdk::Error> = None;
    for id in own_reaction_ids {
        let Ok(id) = matrix_sdk::ruma::EventId::parse(id.as_str()) else {
            continue;
        };
        if let Err(e) = room.redact(&id, None, None).await {
            error = Some(e.into());
            break;
        }
    }
    match error {
        None => {
            daemon.send(OutEvent::response(
                req,
                Event::UpdateSendResult {
                    room_id,
                    event_id: None,
                },
            ));
        }
        Some(e) => {
            tracing::error!("sendReaction remove failed: {}", e);
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Reaction remove failed: {e}")),
            ));
        }
    }
}

/// Pin or unpin an event: read the current `m.room.pinned_events`
/// state, apply `pin_toggle`, and send the changed list as a fresh
/// state event — no-change requests succeed without sending.  The
/// resulting list flows back through the state echo (`on_room_pinned`
/// -> summary), like every room state change.
pub async fn handle_pin_message(
    daemon: SharedDaemon,
    req: Option<u64>,
    room_id: String,
    event_id: String,
    unpin: Option<bool>,
) {
    use matrix_sdk::ruma::events::{
        room::pinned_events::RoomPinnedEventsEventContent, StateEventType,
    };

    let Some((client, room)) = room_ctx(&daemon, req, &room_id).await else {
        return;
    };
    let Some(target) = parse_event_id_or_ack(&daemon, req, &event_id) else {
        return;
    };
    let Some(own) = client.user_id().map(ToOwned::to_owned) else {
        no_session(&daemon, req);
        return;
    };
    match room.power_levels().await {
        Ok(pls) if !pls.user_can_send_state(&own, StateEventType::RoomPinnedEvents) => {
            daemon.send(OutEvent::ack(
                req,
                false,
                Some("You cannot pin or unpin messages in this room".into()),
            ));
            return;
        }
        Err(e) => {
            tracing::error!("pinMessage {room_id}: power levels unavailable: {e}");
            daemon.send(OutEvent::ack(req, false, Some(format!("Pin failed: {e}"))));
            return;
        }
        Ok(_) => {}
    };

    let current = pinned_from_state(&state_values(&room, "m.room.pinned_events").await);
    let Some(list) = pin_toggle(&current, target.as_str(), unpin == Some(true)) else {
        // Nothing would change — succeed without sending a state event.
        daemon.send(OutEvent::ack(req, true, None));
        return;
    };
    let ids: Vec<matrix_sdk::ruma::OwnedEventId> = list
        .iter()
        .filter_map(|id| match matrix_sdk::ruma::EventId::parse(id) {
            Ok(parsed) => Some(parsed),
            Err(e) => {
                tracing::warn!("pinMessage {room_id}: dropping unparsable pinned id {id}: {e}");
                None
            }
        })
        .collect();
    match room
        .send_state_event(RoomPinnedEventsEventContent::new(ids))
        .await
    {
        Ok(_) => daemon.send(OutEvent::ack(req, true, None)),
        Err(e) => {
            tracing::error!("pinMessage {room_id} failed: {}", e);
            daemon.send(OutEvent::ack(req, false, Some(format!("Pin failed: {e}"))));
        }
    }
}

/// The wire content of a poll start, carrying every payload shape a
/// known parser reads: the final spec block (`m.poll`), Element's
/// variant (`m.poll.start`, with `id` answer keys and string texts),
/// the MSC3381 unstable revision and the plain-text fallback for
/// clients without poll support.  Sent via `send_raw` — the typed
/// ruma content cannot express the extra blocks.
///
/// Room reality (2026-10): the stable type renders in Element and
/// SchildiChat; SchildiChat Next rendered only a legacy-typed poll
/// (unstable senders), Sable's shipped build showed no poll at all —
/// both are client gaps their updates close.  Sending both type names
/// was rejected: every rendering client parses both, which would
/// duplicate every poll and fork the votes.
fn poll_start_wire(
    question: &str,
    fallback: &str,
    options: &[String],
    max_selections: u64,
    disclosed: bool,
) -> serde_json::Value {
    let kind = |element: bool| match (disclosed, element) {
        (true, false) => "m.disclosed",
        (true, true) => "m.poll.disclosed",
        (false, false) => "m.undisclosed",
        (false, true) => "m.poll.undisclosed",
    };
    let ids = |element: bool| {
        options.iter().enumerate().map(move |(i, text)| {
            let id = format!("o{}", i + 1);
            if element {
                serde_json::json!({ "id": id, "m.text": text })
            } else {
                serde_json::json!({ "m.id": id, "m.text": poll_text_block(text) })
            }
        })
    };
    serde_json::json!({
        "m.text": poll_text_block(fallback),
        "m.poll": {
            "kind": kind(false),
            "max_selections": max_selections,
            "question": { "m.text": poll_text_block(question) },
            "answers": ids(false).collect::<Vec<_>>(),
        },
        "m.poll.start": {
            "question": { "m.text": question },
            "kind": kind(true),
            "max_selections": max_selections,
            "answers": ids(true).collect::<Vec<_>>(),
        },
        "org.matrix.msc3381.poll.start": {
            "question": { "org.matrix.msc1767.text": question },
            "kind": format!("org.matrix.msc3381.poll.{}", if disclosed { "disclosed" } else { "undisclosed" }),
            "max_selections": max_selections,
            "answers": options.iter().enumerate().map(|(i, text)| {
                serde_json::json!({
                    "id": format!("o{}", i + 1),
                    "org.matrix.msc1767.text": text,
                })
            }).collect::<Vec<_>>(),
        },
    })
}

/// The wire content of a poll response: the spec `m.selections` plus
/// Element's `m.poll.response` block and the unstable revision.
fn poll_response_wire(selections: &[String], target: &str) -> serde_json::Value {
    serde_json::json!({
        "m.relates_to": { "rel_type": "m.reference", "event_id": target },
        "m.selections": selections,
        "m.poll.response": { "answers": selections },
        "org.matrix.msc3381.poll.response": { "answers": selections },
    })
}

/// The wire content of a poll end: the required `m.poll.end` block,
/// the fallback text and the unstable revision.
fn poll_end_wire(target: &str) -> serde_json::Value {
    serde_json::json!({
        "m.relates_to": { "rel_type": "m.reference", "event_id": target },
        "m.text": poll_text_block("Poll ended"),
        "m.poll.end": {},
        "org.matrix.msc3381.poll.end": {},
    })
}

/// Create a poll (`m.poll.create` command): send one `m.poll.start`
/// carrying the question, the answer ids (opaque, derived from the
/// option index) and the kind/max_selections the command picks.
pub async fn handle_poll_create(
    daemon: SharedDaemon,
    req: Option<u64>,
    room_id: String,
    question: String,
    options: Vec<String>,
    max_selections: Option<u64>,
    disclosed: Option<bool>,
) {
    if question.trim().is_empty() {
        daemon.send(OutEvent::ack(
            req,
            false,
            Some("The question must not be empty".into()),
        ));
        return;
    }
    if options.len() < 2 || options.len() > 20 {
        daemon.send(OutEvent::ack(
            req,
            false,
            Some("A poll takes 2 to 20 options".into()),
        ));
        return;
    }
    let max_sel = max_selections.unwrap_or(1).max(1);
    let Some((_, room)) = room_ctx(&daemon, req, &room_id).await else {
        return;
    };
    // The plain-text fallback (for clients without poll support): the
    // question with numbered options.
    let mut fallback = format!("Poll: {}\n", question.trim());
    for (i, text) in options.iter().enumerate() {
        fallback.push_str(&format!("{}. {}\n", i + 1, text));
    }
    // Every payload shape a known parser reads (Element, the unstable
    // revision, the final spec) ships inside one event; the wire forms
    // are hand-built because ruma's typed content carries the spec
    // shape only (and drops the required `m.poll.end` on ends).
    let content = poll_start_wire(
        question.trim(),
        fallback.trim_end(),
        &options,
        max_sel,
        disclosed.unwrap_or(false),
    );
    match room.send_raw("m.poll.start", content).await {
        Ok(response) => {
            daemon.send(OutEvent::response(
                req,
                Event::UpdateSendResult {
                    room_id,
                    event_id: Some(response.response.event_id.to_string()),
                },
            ));
        }
        Err(e) => {
            tracing::error!("pollCreate failed: {}", e);
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Poll create failed: {e}")),
            ));
        }
    }
}

/// Vote in a poll (`pollVote` command): one `m.poll.response` with the
/// full selection set (an empty list removes the own vote).
pub async fn handle_poll_vote(
    daemon: SharedDaemon,
    req: Option<u64>,
    room_id: String,
    event_id: String,
    selections: Vec<String>,
) {
    let Some((_, room)) = room_ctx(&daemon, req, &room_id).await else {
        return;
    };
    let Some(target) = parse_event_id_or_ack(&daemon, req, &event_id) else {
        return;
    };
    let content = poll_response_wire(&selections, target.as_str());
    match room.send_raw("m.poll.response", content).await {
        Ok(response) => {
            daemon.send(OutEvent::response(
                req,
                Event::UpdateSendResult {
                    room_id,
                    event_id: Some(response.response.event_id.to_string()),
                },
            ));
        }
        Err(e) => {
            tracing::error!("pollVote failed: {}", e);
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Poll vote failed: {e}")),
            ));
        }
    }
}

/// End a poll (`pollEnd` command): one `m.poll.end` with a plain
/// fallback text; results freeze.
pub async fn handle_poll_end(
    daemon: SharedDaemon,
    req: Option<u64>,
    room_id: String,
    event_id: String,
) {
    let Some((_, room)) = room_ctx(&daemon, req, &room_id).await else {
        return;
    };
    let Some(target) = parse_event_id_or_ack(&daemon, req, &event_id) else {
        return;
    };
    let content = poll_end_wire(target.as_str());
    match room.send_raw("m.poll.end", content).await {
        Ok(response) => {
            daemon.send(OutEvent::response(
                req,
                Event::UpdateSendResult {
                    room_id,
                    event_id: Some(response.response.event_id.to_string()),
                },
            ));
        }
        Err(e) => {
            tracing::error!("pollEnd failed: {}", e);
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Poll end failed: {e}")),
            ));
        }
    }
}

/// Largest file we accept for upload, in bytes.
const MAX_UPLOAD_BYTES: usize = 20 * 1024 * 1024;

/// The attachment's content type: `mime` when it parses — a re-send
/// that carries its source's mimetype, since the filename guess
/// fails once the name is a staging artifact or has no extension it
/// could carry — the extension guess otherwise, eventually
/// application/octet-stream.
fn attachment_content_type(path: &str, mime_override: Option<&str>) -> mime::Mime {
    if let Some(m) = mime_override {
        match m.parse() {
            Ok(parsed) => return parsed,
            Err(e) => warn!("sendAttachment: unparsable mime `{m}' ({e}); guessing by name"),
        }
    }
    mime_guess::from_path(path).first_or_octet_stream()
}

/// The carried-over `SendInfo` as the SDK attachment metadata the
/// content type selects: the ruma info structs have no common type,
/// so image dims, a video's duration, or an audio clip's length land
/// in their own structs — a mismatch would be ignored by the SDK.
fn attachment_info(
    content_type: &mime::Mime,
    info: SendInfo,
) -> matrix_sdk::attachment::AttachmentInfo {
    use matrix_sdk::attachment::{
        AttachmentInfo, BaseAudioInfo, BaseFileInfo, BaseImageInfo, BaseVideoInfo,
    };

    let width = info.width.and_then(|n| UInt::try_from(n).ok());
    let height = info.height.and_then(|n| UInt::try_from(n).ok());
    let size = info.size.and_then(|n| UInt::try_from(n).ok());
    let duration = info.duration.map(Duration::from_millis);
    match content_type.type_().as_str() {
        "image" => AttachmentInfo::Image(BaseImageInfo {
            height,
            width,
            size,
            ..Default::default()
        }),
        "video" => AttachmentInfo::Video(BaseVideoInfo {
            duration,
            height,
            width,
            size,
            ..Default::default()
        }),
        "audio" => AttachmentInfo::Audio(BaseAudioInfo {
            duration,
            size,
            ..Default::default()
        }),
        _ => AttachmentInfo::File(BaseFileInfo { size }),
    }
}

/// Send an attachment: `sendImage` and `sendFile` share the path; the
/// message type comes from the content type — `mime` when the caller
/// carries one (a re-send that kept its source's mimetype), the
/// filename guess otherwise (`image/*` renders as `m.image`,
/// video/audio likewise, everything else as `m.file`).
/// `fallback_name` is the body when PATH has no file name;
/// `carried` re-sends the source event's info (`SendInfo`), routed
/// into the ruma info struct the content type selects.
#[allow(clippy::too_many_arguments)]
pub async fn handle_send_attachment(
    daemon: SharedDaemon,
    req: Option<u64>,
    room_id: String,
    path: String,
    fallback_name: &str,
    thread_root: Option<String>,
    mime_override: Option<String>,
    carried: Option<SendInfo>,
) {
    let Some((_, room)) = room_ctx(&daemon, req, &room_id).await else {
        return;
    };

    // Size-check before reading: a huge file must not be pulled into
    // memory just to be refused.  `tokio::fs` keeps the actual read off
    // the dispatch task's thread.
    let size = match tokio::fs::metadata(&path).await {
        Ok(meta) => meta.len() as usize,
        Err(e) => {
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Cannot read {path}: {e}")),
            ));
            return;
        }
    };
    if size > MAX_UPLOAD_BYTES {
        daemon.send(OutEvent::ack(
            req,
            false,
            Some(format!(
                "File too large (limit {} MiB)",
                MAX_UPLOAD_BYTES / (1024 * 1024)
            )),
        ));
        return;
    }

    let data = match tokio::fs::read(&path).await {
        Ok(d) => d,
        Err(e) => {
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Cannot read {path}: {e}")),
            ));
            return;
        }
    };

    let content_type = attachment_content_type(&path, mime_override.as_deref());
    let body = std::path::Path::new(&path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(fallback_name)
        .to_owned();

    let mut config = matrix_sdk::attachment::AttachmentConfig::new();
    if let Some(info) = carried {
        config = config.info(attachment_info(&content_type, info));
    }
    if let Some(root) = thread_root.as_deref() {
        // Threaded attachment (MSC3440): a plain thread send, no reply
        // leg — the media content carries no relation of its own, so
        // the shaped one rides `extra_content` (top-level fields; the
        // event's own fields would win on conflicts, and this one is
        // theirs).
        let Some(root_id) = parse_event_id_or_ack(&daemon, req, root) else {
            return;
        };
        let fold_latest = thread_fold_latest(&daemon, &room, root).await;
        let relation =
            serde_json::to_value(thread_relation_for(&root_id, None, fold_latest.as_deref()))
                .unwrap_or(serde_json::Value::Null);
        let mut extra = serde_json::Map::new();
        extra.insert("m.relates_to".to_owned(), relation);
        config = config.extra_content(Some(extra));
    }
    match room
        .send_attachment(&body, &content_type, data, config)
        .await
    {
        Ok(response) => {
            info!(
                "sendAttachment {path}: {} bytes as {}",
                body.len(),
                content_type
            );
            daemon.send(OutEvent::response(
                req,
                Event::UpdateSendResult {
                    room_id,
                    event_id: Some(response.event_id.to_string()),
                },
            ));
        }
        Err(e) => {
            tracing::error!("sendAttachment failed: {}", e);
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("File send failed: {e}")),
            ));
        }
    }
}

/// The undecryptable-page treatment both history paths (getRoomMessages,
/// getThreadMessages) run: backfills bypass the sync-side "unable to
/// decrypt" handler that pulls missing room keys from the server-side
/// backup, so when a page carries undecryptable megolm events, download
/// this room's keys from the backup and re-fetch the page (FETCH
/// re-runs the caller's page request) so freshly imported keys apply;
/// events the second pass still cannot decrypt render as placeholders.
async fn page_with_key_backup<T, Fut>(
    daemon: &SharedDaemon,
    client: &Client,
    room: &Room,
    room_id: &str,
    context: &str,
    fetch: impl Fn() -> Fut,
) -> Option<T>
where
    Fut: std::future::Future<Output = Result<T, matrix_sdk::Error>>,
{
    info!(
        "{} of {} contains undecryptable events — downloading room keys from backup",
        context, room_id
    );
    ensure_room_key_watcher(daemon, client, room);
    if let Err(e) = client
        .encryption()
        .backups()
        .download_room_keys_for_room(room.room_id())
        .await
    {
        warn!("Room-key backup download failed for {}: {}", room_id, e);
    }
    match fetch().await {
        Ok(page) => Some(page),
        Err(e) => {
            warn!(
                "{} of {}: re-fetch after the backup download failed too: {e}",
                context, room_id
            );
            None
        }
    }
}

/// The filtered photo walk's retained message entries (`filter:
/// "image"` on getRoomMessages): the pictures the Emacs viewer
/// browses.  m.image, plus m.sticker — a sticker carries the same
/// MediaEntry, and one outside the room buffer's rendered window
/// must be found by the walk like any other picture.
fn image_filter_keeps(e: &MessageEntry) -> bool {
    e.msgtype == "m.image" || e.msgtype == "m.sticker"
}

pub async fn handle_get_room_messages(
    daemon: SharedDaemon,
    req: Option<u64>,
    room_id: String,
    limit: Option<u32>,
    from: Option<String>,
    filter: Option<String>,
) {
    let Some((client, room)) = room_ctx(&daemon, req, &room_id).await else {
        return;
    };

    // Photo-browser pages keep pictures.  The wire event filter
    // has no msgtype notion (and encrypted rooms ship every message as
    // m.room.encrypted), so narrow the server-side scan to the two
    // message-bearing types and keep the picture entries that
    // `image_filter_keeps' names (m.image, plus m.sticker — a sticker
    // is a picture riding the same media shape, and one beyond the
    // room buffer's rendered window must be walkable too).  An
    // unknown filter string is an error, not silently
    // everything: a typo'd value returning the unfiltered page would
    // hand the caller a pagination token from a different walk.
    let image_filter = match filter.as_deref() {
        None => false,
        Some("image") => true,
        Some(other) => {
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Unknown getRoomMessages filter: {other}")),
            ));
            return;
        }
    };
    let build_options = || {
        let mut options = MessagesOptions::backward();
        options.limit = limit.unwrap_or(50).into();
        options.from = from.clone();
        if image_filter {
            let mut f = RoomEventFilter::default();
            f.types = Some(vec!["m.room.message".into(), "m.room.encrypted".into()]);
            options.filter = f;
        }
        options
    };
    let mut messages = match room.messages(build_options()).await {
        Ok(m) => m,
        Err(e) => {
            tracing::error!("getRoomMessages failed: {}", e);
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("History failed: {e}")),
            ));
            return;
        }
    };
    // Backfills bypass the sync-side key pull — see `page_with_key_backup`.
    if chunk_has_undecrypted(&messages.chunk) {
        if let Some(retry) =
            page_with_key_backup(&daemon, &client, &room, &room_id, "History", || {
                room.messages(build_options())
            })
            .await
        {
            messages = retry;
        }
    }
    // Backward pagination returns newest-first; Emacs wants oldest->newest.
    let mut entries = messages_to_entries(&messages.chunk, &room, Some(&daemon)).await;
    if image_filter {
        entries.retain(image_filter_keeps);
    }
    entries.reverse();
    info!(
        "getRoomMessages {}: {} events in chunk, {} entries rendered",
        room_id,
        messages.chunk.len(),
        entries.len()
    );
    // `end` is the token for the next backward page (None = exhausted).
    let end = messages.end.clone();
    daemon.send(OutEvent::response(
        req,
        Event::UpdateRoomMessages {
            profile: daemon.profile.clone(),
            room_id,
            end,
            messages: entries,
        },
    ));
}

/// Paginate one thread (MSC3440): the `limit` newest events under
/// `thread_root`, ending at the token `from` (None = the most recent
/// end).  The server-side thread listing rides the same
/// `/relations` machinery the reaction toggles use, narrowed by
/// relation type.  Every page merges into the fold like a history
/// backfill does — bundled summaries included — so opening a thread
/// refreshes its send fallback (Element interop), and Emacs renders
/// the entries with their `thread_root` set.  The root's own entry
/// rides the response as `root` (None when it cannot be loaded: the
/// Emacs side pins a placeholder).  No receipts interaction: reading
/// a thread's events marks nothing — the room buffer's marker and
/// the per-thread unread slice are the deferred follow-ups.
pub async fn handle_get_thread_messages(
    daemon: SharedDaemon,
    req: Option<u64>,
    room_id: String,
    thread_root: String,
    limit: Option<u32>,
    from: Option<String>,
) {
    let Some((client, room)) = room_ctx(&daemon, req, &room_id).await else {
        return;
    };
    let Some(root) = parse_event_id_or_ack(&daemon, req, &thread_root) else {
        return;
    };

    let build_options = || RelationsOptions {
        from: from.clone(),
        // Backward pages list newest-first (the relations endpoint's
        // natural direction); the reverse below matches the history
        // pages' oldest->newest rendering order.
        dir: Direction::Backward,
        limit: Some(limit.unwrap_or(50).into()),
        include_relations: IncludeRelations::RelationsOfType(RelationType::Thread),
        recurse: false,
    };
    let mut relations = match room.relations(root.to_owned(), build_options()).await {
        Ok(relations) => relations,
        Err(e) => {
            tracing::error!("getThreadMessages failed: {}", e);
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Thread listing failed: {e}")),
            ));
            return;
        }
    };
    // The same undecryptable-page treatment the history path runs —
    // see `page_with_key_backup`.
    if chunk_has_undecrypted(&relations.chunk) {
        if let Some(retry) =
            page_with_key_backup(&daemon, &client, &room, &room_id, "Thread listing", || {
                room.relations(root.to_owned(), build_options())
            })
            .await
        {
            relations = retry;
        }
    }
    let mut entries = messages_to_entries(&relations.chunk, &room, Some(&daemon)).await;
    entries.reverse();
    info!(
        "getThreadMessages {} under {}: {} events in chunk, {} entries rendered",
        room_id,
        thread_root,
        relations.chunk.len(),
        entries.len()
    );
    // The root's own entry, tried after the page (a failed page must
    // not keep the root from showing even as a placeholder).
    let root_entry = {
        let fetched = room.load_or_fetch_event(&root, None).await;
        match fetched {
            Ok(event) => {
                let items = vec![event];
                messages_to_entries(&items, &room, Some(&daemon))
                    .await
                    .into_iter()
                    .next()
            }
            Err(e) => {
                debug!("getThreadMessages: root fetch for {thread_root} failed: {e}");
                None
            }
        }
    };
    // The continuation token for the next OLDER page, like the room
    // history's `end`.
    let end = relations.next_batch_token;
    daemon.send(OutEvent::response(
        req,
        Event::UpdateThreadMessages {
            profile: daemon.profile.clone(),
            room_id,
            thread_root,
            root: root_entry,
            end,
            messages: entries,
        },
    ));
}

pub async fn handle_mark_room_read(
    daemon: SharedDaemon,
    req: Option<u64>,
    room_id: String,
    event_id: Option<String>,
    public_receipt: Option<bool>,
) {
    let Some((_, room)) = room_ctx(&daemon, req, &room_id).await else {
        return;
    };

    let Some(event_id) = event_id else {
        // No event id: "mark read over the newest timeline event you
        // hold".  `last_event_id' is updated by every timeline
        // handler — rendered messages and the invisible kinds
        // (reactions, poll votes, edits) alike — so the receipt lands
        // past the standing-unread extras, which live handlers know
        // about even though no one ever rendered them as messages.
        // When that pointer has not moved since the last such mark,
        // say ok without sending: the event-less mark re-arms freely
        // (post-command hooks), and the receipt must not POST on
        // every keystroke pause.
        let target = {
            let locals = daemon.room_locals.lock().await;
            locals.get(room.room_id()).and_then(|l| {
                if l.last_event_id == l.last_read_sent {
                    None
                } else {
                    l.last_event_id.clone()
                }
            })
        };
        let Some(target) = target else {
            // Either nothing to mark (new session), or the pointer
            // has not moved since the last mark — both read already.
            daemon.send(OutEvent::ack(req, true, None));
            return;
        };
        // Continue through the shared tail with the concrete target;
        // `last_read_sent' is only maintained for this event-less
        // form (the explicit form dedups on the Emacs side).
        mark_read_form(daemon, req, room, target, public_receipt, true).await;
        return;
    };

    mark_read_form(daemon, req, room, event_id, public_receipt, false).await;
}

/// The marking tail both `markRoomRead' forms share: parse the target,
/// send the fully-read marker plus the private (and optional public)
/// read receipt, and answer with the room summary.
async fn mark_read_form(
    daemon: SharedDaemon,
    req: Option<u64>,
    room: Room,
    event_id: String,
    public_receipt: Option<bool>,
    track_last_read: bool,
) {
    use matrix_sdk::ruma::api::client::receipt::create_receipt::v3::ReceiptType;
    use matrix_sdk::ruma::events::receipt::ReceiptThread;

    let Some(event_id) = parse_event_id_or_ack(&daemon, req, &event_id) else {
        return;
    };

    // Always private: the fully-read marker (room account data, visible
    // only to this user) and the private read receipt, which moves this
    // user's own unread counters without telling anyone.  The public
    // m.read receipt — federated to every room member — is opt-in.
    let note_id = event_id.to_string();
    let mut error = None;
    if let Err(e) = room
        .send_single_receipt(
            ReceiptType::FullyRead,
            ReceiptThread::Unthreaded,
            event_id.clone(),
        )
        .await
    {
        error = Some(e);
    }
    if error.is_none() {
        if let Err(e) = room
            .send_single_receipt(
                ReceiptType::ReadPrivate,
                ReceiptThread::Unthreaded,
                event_id.clone(),
            )
            .await
        {
            error = Some(e);
        }
    }
    if error.is_none() && public_receipt == Some(true) {
        if let Err(e) = room
            .send_single_receipt(
                ReceiptType::Read,
                ReceiptThread::Unthreaded,
                event_id.clone(),
            )
            .await
        {
            error = Some(e);
        }
    }

    match error {
        None => {
            if track_last_read {
                let mut locals = daemon.room_locals.lock().await;
                if let Some(local) = locals.get_mut(room.room_id()) {
                    local.last_read_sent = Some(note_id);
                }
            }
            let local = {
                let locals = daemon.room_locals.lock().await;
                locals.get(room.room_id()).cloned().unwrap_or_default()
            };
            let summary = room_summary(&room, &local).await;
            daemon.send(OutEvent::response(
                req,
                Event::UpdateRoom {
                    profile: daemon.profile.clone(),
                    room: summary,
                },
            ));
        }
        Some(e) => {
            tracing::error!("markRoomRead failed: {}", e);
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Read mark failed: {e}")),
            ));
        }
    }
}

/// The member roster of one joined room: user ids plus display names
/// (None when the member never set one — Emacs offers the user id
/// then).  Store-backed, no homeserver round trip; the response event
/// rides the ack and the client's roster cache is replaced wholesale.
pub async fn handle_get_room_members(daemon: SharedDaemon, req: Option<u64>, room_id: String) {
    let Some((_, room)) = room_ctx(&daemon, req, &room_id).await else {
        return;
    };
    let members = match room.members_no_sync(RoomMemberships::JOIN).await {
        Ok(m) => m,
        Err(e) => {
            tracing::error!("getRoomMembers listing failed: {}", e);
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Member listing failed: {e}")),
            ));
            return;
        }
    };
    let roster: Vec<MemberEntry> = members
        .iter()
        .map(|m| MemberEntry {
            user_id: m.user_id().to_string(),
            display_name: m.display_name().map(str::to_owned),
        })
        .collect();
    daemon.send(OutEvent::response(
        req,
        Event::UpdateRoomMembers {
            profile: daemon.profile.clone(),
            room_id,
            members: roster,
        },
    ));
}

pub async fn handle_get_room_receipts(daemon: SharedDaemon, req: Option<u64>, room_id: String) {
    use matrix_sdk::ruma::events::receipt::{ReceiptThread, ReceiptType};

    let Some((_, room)) = room_ctx(&daemon, req, &room_id).await else {
        return;
    };

    let own = room.own_user_id();
    // Collect first (no lock held across the store reads), merge after.
    let members = match room.members_no_sync(RoomMemberships::JOIN).await {
        Ok(m) => m,
        Err(e) => {
            tracing::error!("getRoomReceipts member listing failed: {}", e);
            daemon.send(OutEvent::ack(
                req,
                false,
                Some(format!("Member listing failed: {e}")),
            ));
            return;
        }
    };
    let others: Vec<OwnedUserId> = members
        .into_iter()
        .filter(|m| m.user_id() != own)
        .map(|m| m.user_id().to_owned())
        .collect();
    let loaded =
        join_all(others.iter().map(|user| {
            room.load_user_receipt(ReceiptType::Read, &ReceiptThread::Unthreaded, user)
        }))
        .await;
    let mut fresh: Vec<(String, String, Option<u64>)> = Vec::new();
    for (user, res) in others.iter().zip(loaded) {
        match res {
            Ok(Some((event_id, receipt))) => fresh.push((
                user.to_string(),
                event_id.to_string(),
                receipt.ts.map(ts_u64),
            )),
            Ok(None) => {}
            Err(e) => {
                warn!("getRoomReceipts: no receipt for {}: {}", user, e);
            }
        }
    }

    let (receipts, event_ts) = {
        let mut locals = daemon.room_locals.lock().await;
        let local = locals.entry(room.room_id().to_owned()).or_default();
        for (user, event_id, ts) in fresh {
            merge_receipt(
                &mut local.receipts,
                &user,
                ReceiptPos {
                    ts: receipt_ts(ts, &local.event_ts, &event_id),
                    event_id,
                },
            );
        }
        prune_receipts(&mut local.receipts);
        (local.receipts.clone(), local.event_ts.clone())
    };

    let receipts = receipt_entries(&room, &receipts, &event_ts).await;
    daemon.send(OutEvent::response(
        req,
        Event::UpdateReadReceipts {
            profile: daemon.profile.clone(),
            room_id,
            receipts,
        },
    ));
}
#[cfg(test)]
mod tests;
