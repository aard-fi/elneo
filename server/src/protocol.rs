//! Framed stdio protocol: command/event enums and frame helpers.
//!
//! Framing: requests arrive as `send <size>\n<json>\n`, events leave as
//! `event <size>\n<json>\n`.  Every request carries an `@req` id assigned by
//! Emacs; events that are the terminal response to a request echo it.  The
//! wrapper fields `@ok`/`@error` are injected at serialization time by
//! [`OutEvent`].
//!
//! Versioning: the wire contract is identified by [`PROTOCOL_VERSION`], which
//! is bumped in lockstep with the Emacs-side `elneo-daemon-protocol` constant
//! whenever the shape pinned by the golden tests here changes.  The daemon
//! reports it (plus the informational [`RELEASE_VERSION`]) in a `daemonInfo`
//! greeting that is always the first frame of a connection, and Emacs gates
//! session activation on it.
//!
//! Gate semantics: Emacs keeps two constants — the protocol it speaks and a
//! minimum, the oldest one still activated.  The minimum rises only when an
//! old daemon would misbehave in a way Emacs cannot paper over; everything
//! short of that degrades gracefully and keeps the minimum at the current
//! version.  A daemon below the minimum (or predating version reporting) is
//! not activated: Emacs registers its event handlers only after the gate
//! passes, so a blocked activation is truly inert, and a daemon speaking
//! a quenched protocol (2 onward) is sent `stopSync` — daemons survive the
//! Emacs that spawned them and may still be running a sync loop whose events
//! would otherwise keep filling the room registry and alerts right under the
//! "activation blocked" warning.  Older daemons cannot be quenched; the inert
//! handlers then make the guarantee one-sided — nothing animates, the daemon
//! just streams into an unguarded pipe until its process is restarted.

use serde::{Deserialize, Serialize};

/// Version of the framed JSON wire contract pinned by the golden tests
/// below.  Bump on any change to an event/command shape, in lockstep with
/// Emacs `elneo-daemon-protocol`.
///
/// History:
///
/// 1: daemonInfo greeting, base commands
/// 2: added the `stopSync` command (see its docs)
/// 3: `MessageEntry.geo` (m.location OSM links), unknown and `m.server_notice`
///    msgtypes ship instead of dropping
/// 4: `MessageEntry.mentions` (`m.mentions`, MSC3952, for the alert
///    refinement)
/// 5: `RoomSummary.room_state`, invited rooms ride the room list, and the
///    acceptInvite/declineInvite/joinRoom/leaveRoom/forgetRoom membership
///    commands
/// 6: the `getRoomMembers` command / `updateRoomMembers` event (the member
///    roster behind @-completion), and `sendMessage` carries `mentions` (a
///    user-id list landing as an `m.mentions` block, MSC3952) plus
///    `room_mentions` (the `@room` everyone-flag)
/// 7: the room-management commands inviteUser, kickUser, banUser, unbanUser,
///    setRoomName, setRoomTopic
/// 8: the createRoom command (with invites/is_direct, the start-DM case) and
///    the roomJoined response event, which now also rides joinRoom's ack
/// 9: the createRoom `encrypted` field (the DM default) and m.direct
///    book-keeping following the flag: the daemon marks a room as direct at
///    creation and when joining a direct-flagged invite, because a joined
///    room's is-direct state reads the `m.direct` account data, not the invite
/// 10: the setDisplayName/setAvatar commands (own profile editing: a display
///    name or an avatar file path, an omitted field clearing it)
/// 11: polls (MSC3381): `MessageEntry` and `updateNewMessage` carry `poll`
///    (the aggregated question/options/votes, see `PollEntry`), the
///    `updatePoll` event re-renders a live-polled line, and the
///    `pollCreate`/`pollVote`/`pollEnd` commands send poll events
/// 12: threads (MSC3440): `MessageEntry` and `updateNewMessage` carry
///    `thread_root` (the thread's root event id, feeding the client's inline
///    thread marks and `openThread`), and the
///    `getThreadMessages`/`updateThreadMessages` pair paginates a single
///    thread
/// 13: the `sendImage`/`sendFile` commands carry an optional `thread_root`
///    (attachments sent from thread views thread into the thread)
/// 14: the `setOwnDisplayName` command (own per-room nick: the `m.room.member`
///    displayname for one room, the global profile untouched; an omitted
///    `name` clears it back to the profile default)
/// 15: the `setRoomAvatar` command (a room's avatar image, an omitted path
///    removing it) and the `roomPermissions` command/response pair (own power
///    level plus the can-X gates, by which the client hides edit actions it
///    cannot perform)
/// 16: the `getProfile` command and `profile` response (this session's own
///    global display name and avatar mxc, straight from the homeserver; the
///    client's account page prints them with the edit buttons)
/// 17: `recoveryEnabled` carries `stored_path`: the daemon now keeps its own
///    copy of the recovery key in the session's data dir (0600), both for the
///    manual `enableRecovery` and for the new background bring-up that gives a
///    first-time account (no cross-signing identity on the homeserver) its
///    keys, secret storage and a key backup without asking — and adopts a
///    stored key silently on a re-login
/// 18: space discovery: the `getRoomHierarchy`/`roomHierarchy` pair (one level
///    of a space's offered rooms, join rule, member count and the
///    already-joined flag included) and the `getRoomSpaces`/`roomSpaces` pair
///    (a room's declared parent spaces, from `m.space.parent` state); the
///    client's space page lists and joins a space's rooms
/// 19: the `RoomSummary` gains `upgraded_to` / `upgraded_from`: the room's
///    upgrade links (`m.room.tombstone` -> `replacement_room`,
///    `m.room.create`/`m.room.predecessor` -> the older room), so the client
///    marks a tombstoned room in the bar, links both directions in the room
///    overview and offers "join and leave the older room" on an upgrade
///    successor's invite
/// 20: joins carry `via` servers: `joinRoom` gains an optional `via` list
///    (passed on as the join endpoint's `server_name` query entries) and every
///    `HierarchyRoom` row names the `via` servers its parents' `m.space.child`
///    state gave it, so a join from the space page or a shared link reaches
///    remote rooms with no resolvable alias
/// 21: the `rotateRecoveryKey`/`disableRecovery` commands: rotation builds a
///    new secret store under a fresh recovery key and re-uploads the locally
///    held secrets (`old_key` present routes through a recover-then-rotate,
///    for sessions the store distrusts), disable deletes the server-side key
///    backup (MSC4287's disabled flag set) and clears secret storage — the
///    daemon then also removes its stale recovery-key stash.  Both answer with
///    already-pinned shapes (`RecoveryEnabled` / `updateRecoveryState`); the
///    client confirms each behind a typed word
/// 22: message pinning: `RoomSummary` gains `pinned_events` (absent when the
///    `m.room.pinned_events` state is unset), and the `pinMessage` command
///    toggles an event on the pinned list — a fresh state event is sent only
///    when the list would actually change; re-reading happens from the state
///    echo (`updateRoom`).  The client marks pinned messages and lists them in
///    the room overview
/// 23: the `updateVerificationNeeded` event: the background crypto bring-up
///    found an identity this session cannot adopt alone (no secret storage,
///    or storage but no recovery key on this machine) and says so instead of
///    returning silently — Emacs offers the verify/recovery flows once per
///    profile per session.  Old daemons never emit it and old clients ignore
///    it, so the activation minimum stays put.
pub const PROTOCOL_VERSION: u32 = 23;

/// serde `skip_serializing_if` helper: false-valued createRoom flags
/// (public, is_direct) stay off the wire — deserialization defaults
/// them, so a minimal create is name-less noise-free.
fn is_false(v: &bool) -> bool {
    !*v
}

/// Human-facing release version of the daemon binary (informational only;
/// code checks [`PROTOCOL_VERSION`]).
pub const RELEASE_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "@type")]
pub enum Command {
    /// Password login on a homeserver, optionally naming the device.
    /// Responds with an `updateSession` carrying the credentials; the
    /// session is persisted in the daemon's data directory, so re-logins
    /// reuse it instead of creating new devices.
    #[serde(rename = "login")]
    Login {
        homeserver: String,
        username: String,
        password: String,
        #[serde(default)]
        device_name: Option<String>,
    },
    /// Log out server-side and drop the session credentials.
    #[serde(rename = "logout")]
    Logout,
    /// Snapshot of the persisted session.  Responds with an
    /// `updateSession`; `@ok: false` when no session exists.
    #[serde(rename = "getSession")]
    GetSession,
    /// Start an SAS/emoji verification flow with another device of the
    /// account.  The other client pops an accept dialog; both sides then
    /// compare the short auth string (`updateVerificationEmojis`).
    #[serde(rename = "verifyDevice")]
    VerifyDevice { user_id: String, device_id: String },
    /// List pending and in-progress verification flows:
    /// `updateVerificationRequest` per flow.
    #[serde(rename = "getVerificationRequests")]
    GetVerificationRequests,
    /// Responds with an `updateDevices` listing all devices of the
    /// account (for the session manager and stale-device cleanup).
    #[serde(rename = "getDevices")]
    GetDevices,
    /// Log out a device of the account.  Optional password feeds the
    /// UIA confirmation step; without it the daemon asks the homeserver
    /// once (`@ok: false` if it insists on a password).
    #[serde(rename = "deleteDevice")]
    DeleteDevice {
        device_id: String,
        #[serde(default)]
        password: Option<String>,
    },
    /// Accept an incoming verification request (flow id from
    /// `updateVerificationRequest`); the flow advances through
    /// `updateVerificationEmojis`.
    #[serde(rename = "acceptVerification")]
    AcceptVerification { flow_id: String },
    /// Start the SAS (emoji/decimals) phase of a verification flow.
    #[serde(rename = "startSas")]
    StartSas { flow_id: String },
    /// Confirm the compared short auth string matches, completing the
    /// flow.
    #[serde(rename = "confirmSas")]
    ConfirmSas { flow_id: String },
    /// Cancel a verification flow; `@ok: false` with the SDK's error
    /// when the SDK refuses.
    #[serde(rename = "cancelVerification")]
    CancelVerification { flow_id: String },
    /// Cross-signing status: whether keys exist (`enabled`) and this
    /// session trusts them (`trusted`) — the data behind the bar's
    /// `Verify: ACCOUNT` row.
    #[serde(rename = "getCrossSigningStatus")]
    GetCrossSigningStatus,
    /// Bootstrap the account's cross-signing keys (identity users
    /// once, then all devices verify against them).
    #[serde(rename = "setupCrossSigning")]
    SetupCrossSigning,
    /// Create secret storage and a server-side key backup.  Responds
    /// ok, then a `RecoveryEnabled` event carries the base58 recovery
    /// key — shown to the user once, and stored as a file (0600) in
    /// the session's data dir; the same dance runs by itself for a
    /// first-time account (see version 17's history above).
    #[serde(rename = "enableRecovery")]
    EnableRecovery,
    /// Restore secret storage and key backup from the given base58
    /// recovery key (fresh sessions and crypto-store-less restarts).
    #[serde(rename = "recoverRecoveryKey")]
    RecoverRecoveryKey { key: String },
    /// Terminal response to the recovery commands: an
    /// `updateRecoveryState`.
    #[serde(rename = "getRecoveryState")]
    GetRecoveryState,
    /// Build a new secret store under a fresh recovery key and
    /// re-upload the locally held secrets into it; the key backup stays
    /// active and its versions are untouched.  Responds with a
    /// `RecoveryEnabled` event carrying the new key.  When the session
    /// is not trusted by the store, `old_key` must name the current
    /// recovery key — the daemon then imports from it before rotating
    /// (an untrusted session alone cannot fill a fresh store).
    #[serde(rename = "rotateRecoveryKey")]
    RotateRecoveryKey {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        old_key: Option<String>,
    },
    /// Delete the server-side key backup and clear secret storage
    /// (MSC4287's disabled flag included).  The backup's history is
    /// gone for every device that cannot already decrypt it.  The
    /// daemon also removes its own recovery-key stash.
    #[serde(rename = "disableRecovery")]
    DisableRecovery,
    /// Deprecated alias for `startSync`.
    #[serde(rename = "sync")]
    Sync,
    /// Start the continuous sync loop for the logged-in session.  The
    /// loop self-reconnects with backoff and reports its health through
    /// `updateSyncState`; incoming events flow as the other `update*`
    /// events.
    #[serde(rename = "startSync")]
    StartSync,
    /// Stop the running sync loop.  Lets a client that declined to
    /// activate (the protocol gate) quiet a daemon that outlived a
    /// previous session and is still streaming update events nobody
    /// authorized in the new session.  Acknowledge ok whether or not a
    /// loop was running.
    #[serde(rename = "stopSync")]
    StopSync,
    /// Accept a pending invite: join the room.  Responds ok and then a
    /// full `updateRoom` (the joined state, seeded with the last event)
    /// runs ahead of the ack, so the UI can open the room from the
    /// ack's success.  `@ok: false` when there is no pending invite for
    /// this room id.
    #[serde(rename = "acceptInvite")]
    AcceptInvite { room_id: String },
    /// Decline a pending invite: leave (and forget) the invited room.
    /// Responds ok and follows with an `updateRoomGone`.
    #[serde(rename = "declineInvite")]
    DeclineInvite { room_id: String },
    /// Voluntarily join a room by id or `#alias`.  Responds ok and
    /// follows with a seeded `updateRoom`.  VIA, when present, rides
    /// the join as `server_name` query entries — the servers a
    /// room-id join (no resolvable alias) needs to find the room
    /// through; shared matrix.to links and space listings carry it.
    #[serde(rename = "joinRoom")]
    JoinRoom {
        room_id_or_alias: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        via: Option<Vec<String>>,
    },
    /// Leave a joined room.  Responds ok and follows with an
    /// `updateRoomGone`.
    #[serde(rename = "leaveRoom")]
    LeaveRoom { room_id: String },
    /// Forget a room this side has left (clears it from account data;
    /// the server refuses for rooms still joined).
    #[serde(rename = "forgetRoom")]
    ForgetRoom { room_id: String },
    /// Invite USER_ID into a joined room.  Responds ok; the change
    /// flows back through normal sync (the invitee's membership).
    /// `@ok: false` with the homeserver's error when USER_ID is
    /// malformed or not invited-able.
    #[serde(rename = "inviteUser")]
    InviteUser { room_id: String, user_id: String },
    /// Remove USER_ID from a joined room (they can rejoin on invite).
    /// REASON is optional and lands in the reason field of the
    /// kick event.  Responds ok.
    #[serde(rename = "kickUser")]
    KickUser {
        room_id: String,
        user_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    /// Ban USER_ID from a room (they cannot rejoin until unbanned).
    /// REASON is optional.  Responds ok.
    #[serde(rename = "banUser")]
    BanUser {
        room_id: String,
        user_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    /// Lift a ban on USER_ID (does not reinvite them — kick-free
    /// rejoining still needs a new invite).  Responds ok; `@ok: false`
    /// when the user was not banned.
    #[serde(rename = "unbanUser")]
    UnbanUser { room_id: String, user_id: String },
    /// Set a joined room's canonical name.  Responds ok; the state
    /// change flows back as a normal `updateRoom`.
    #[serde(rename = "setRoomName")]
    SetRoomName { room_id: String, name: String },
    /// Set a joined room's topic.  Responds ok; the state change
    /// flows back as a normal `updateRoom`.
    #[serde(rename = "setRoomTopic")]
    SetRoomTopic { room_id: String, topic: String },
    /// Set the session account's display name AS THIS ROOM SEES IT:
    /// the `m.room.member` state displayname, not the global profile
    /// (an omitted NAME clears it back — the room then falls to the
    /// global display name, like the CS API treats a null member
    /// displayname).  Responds ok; the change flows back through the
    /// room member events.
    #[serde(rename = "setOwnDisplayName")]
    SetOwnDisplayName {
        room_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
    },
    /// Create a room and join it.  NAME and TOPIC are optional
    /// metadata; ALIAS is the alias local part (#local:server, the
    /// session's homeserver implied — the server owns the full
    /// uniqueness check); PUBLIC lists the room in the directory,
    /// otherwise it is private.  INVITES are user ids to invite at
    /// creation, IS_DIRECT marks the invite as DM (the start-DM
    /// case) and files the room under m.direct so every client's
    /// DM flag agrees — a joined room's is-direct state reads the
    /// account data, not the invite.  ENCRYPTED lays the initial
    /// m.room.encryption event (direct messages are encrypted by
    /// default on every modern client).  A malformed invite id
    /// rejects the whole request.
    /// Responds ok and the room id — the seeded `updateRoom` rides
    /// ahead of the ack, and a `roomJoined` rides on it.
    #[serde(rename = "createRoom")]
    CreateRoom {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        alias: Option<String>,
        #[serde(default, skip_serializing_if = "crate::protocol::is_false")]
        public: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        topic: Option<String>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        invites: Vec<String>,
        #[serde(default, skip_serializing_if = "crate::protocol::is_false")]
        is_direct: bool,
        #[serde(default, skip_serializing_if = "crate::protocol::is_false")]
        encrypted: bool,
    },
    /// Set the session account's display name.  An omitted NAME
    /// clears it — the CS API treats null as unset.  The change
    /// flows back through the room member events.
    #[serde(rename = "setDisplayName")]
    SetDisplayName {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
    },
    /// Set the session account's avatar.  LOCAL_PATH is the image to
    /// upload (mime guessed from the path — the upload and the
    /// profile write land as one server call); an omitted PATH
    /// clears the avatar.  Responds ok.
    #[serde(rename = "setAvatar")]
    SetAvatar {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        local_path: Option<String>,
    },
    /// Set (or clear) the avatar of one room.  LOCAL_PATH is the
    /// image to upload (mime guessed from the path — the upload and
    /// the state write land as back-to-back server calls); an
    /// omitted LOCAL_PATH removes the room's avatar.  The room's
    /// summary (and the permission-gated UI state) follows via the
    /// usual `updateRoom`.  Responds ok.
    #[serde(rename = "setRoomAvatar")]
    SetRoomAvatar {
        room_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        local_path: Option<String>,
    },
    /// This session's permissions in one joined room: the own power
    /// level (with a creator standing as "infinite") and what it
    /// allows.  Responds with a `roomPermissions` event; the UI gates
    /// the room's edit actions on it and the room overview prints it.
    #[serde(rename = "roomPermissions")]
    RoomPermissions { room_id: String },
    /// This session's own profile, straight from the homeserver: the
    /// global display name and avatar mxc (both may be unset — the
    /// response fields stay off the wire then).  Responds with a
    /// `profile` event; the UI account page prints it with its edit
    /// buttons.
    #[serde(rename = "getProfile")]
    GetProfile,
    /// Snapshot of every joined and invited room: responds ok, then
    /// each room rides its own `updateRoom` (store-backed: rooms that
    /// already carry local state keep it, only genuinely new rooms pay
    /// a last-event fetch).
    #[serde(rename = "getRooms")]
    GetRooms,
    /// The member roster of one joined room: user ids and display
    /// names, store-backed (no homeserver round trip).  Responds with a
    /// single `updateRoomMembers` riding the ack.
    #[serde(rename = "getRoomMembers")]
    GetRoomMembers { room_id: String },
    /// One level of a space's offered rooms (`max_depth` 1): the
    /// response is a `roomHierarchy` event whose `next_batch` pages on
    /// (an empty first page is legal, the space itself is the first
    /// row).  World-readable spaces answer for sessions not joined;
    /// others say so in the ack's error.
    #[serde(rename = "getRoomHierarchy")]
    GetRoomHierarchy {
        room_id: String,
        /// Pagination token from a previous response's `next_batch`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        from: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        limit: Option<u32>,
    },
    /// A joined room's declared parent spaces (the `m.space.parent`
    /// state events it carries, canonical parent first).  Responds
    /// with a `roomSpaces` event; `@ok: false` when ROOM_ID is not in
    /// this session's store (only a joined room's state can be read).
    #[serde(rename = "getRoomSpaces")]
    GetRoomSpaces { room_id: String },
    /// Send a text message.  Responds with an `updateSendResult`
    /// carrying the homeserver's event id (a failed send is a bare
    /// `@ok: false` instead); the fields below cover reply, edit and
    /// mention shapes.
    #[serde(rename = "sendMessage")]
    SendMessage {
        room_id: String,
        body: String,
        /// `org.matrix.custom.html` rendering of BODY, when the sender
        /// typed markup.  The plain body stays mandatory — clients
        /// without rich rendering (and notifications) fall back to it.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        formatted_body: Option<String>,
        /// Event id this message replies to (`m.in_reply_to`), if any.
        /// In a thread (`thread_root` set) this is the in-thread reply
        /// target; the daemon folds it into the thread relation.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reply_to: Option<String>,
        /// Thread root (MSC3440): the event ids under which `reply_to`
        /// and this send carry an `m.thread` relation.  Mutually
        /// exclusive with `replaces`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        thread_root: Option<String>,
        /// Event id this message edits (`m.replace`), if any.  Text
        /// edits only: the body becomes the message's whole new
        /// content.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        replaces: Option<String>,
        /// User ids the sender explicitly mentioned (completion picks).
        /// Lands as an `m.mentions` block (MSC3952) so receivers'
        /// mention-aware alerts fire.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        mentions: Option<Vec<String>>,
        /// `@room` in the sender's body: the everyone-flag
        /// (`m.mentions.room`).  A plain "@room" token in the body is
        /// the textual convention; this is the explicit form the
        /// client ships so the body needn't be pattern-matched again.
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        room_mentions: bool,
    },
    /// Redact (delete) an event.  The server strips the original's
    /// content everywhere; clients render a `[redacted]` marker.
    #[serde(rename = "redactMessage")]
    RedactMessage {
        room_id: String,
        event_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    /// Add a reaction (`m.reaction`) to an event, or — with `remove` —
    /// redact every own reaction event with that key (toggle).
    #[serde(rename = "sendReaction")]
    SendReaction {
        room_id: String,
        event_id: String,
        key: String,
        /// With `true`, toggle the reaction off (redact own reaction event)
        /// instead of adding it.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        remove: Option<bool>,
    },
    /// Pin EVENT_ID in ROOM_ID (`m.room.pinned_events`), or — with
    /// `unpin` — take it off the list.  The state event only goes out
    /// when the list would actually change; the resulting list arrives
    /// in every room summary as `pinned_events`.
    #[serde(rename = "pinMessage")]
    PinMessage {
        room_id: String,
        event_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        unpin: Option<bool>,
    },
    /// Create a poll (`m.poll.start`, MSC3381).  `options` are the
    /// answer texts (2..=20; the daemon assigns opaque answer ids).
    /// `disclosed` picks the kind — live results for everyone (the
    /// default is undisclosed), and `max_selections` (default 1) is the
    /// per-voter choice cap for multi-choice polls.
    #[serde(rename = "pollCreate")]
    PollCreate {
        room_id: String,
        question: String,
        options: Vec<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        max_selections: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        disclosed: Option<bool>,
    },
    /// Vote in a poll (`m.poll.response`): `selections` is the full set
    /// of answer ids the own account wants selected — re-send the
    /// complete set every time (a second response replaces the first).
    /// An empty list removes the own vote.
    #[serde(rename = "pollVote")]
    PollVote {
        room_id: String,
        event_id: String,
        selections: Vec<String>,
    },
    /// End a poll (`m.poll.end`): results freeze; votes no longer count.
    #[serde(rename = "pollEnd")]
    PollEnd { room_id: String, event_id: String },
    /// Upload and send a local image as an `m.image` message; responds
    /// with an `updateSendResult`.
    #[serde(rename = "sendImage")]
    SendImage {
        room_id: String,
        /// Local filesystem path of the image to upload and send.
        path: String,
        /// When set, the attachment threads into this thread root
        /// (MSC3440) instead of the room timeline.
        #[serde(default)]
        thread_root: Option<String>,
    },
    /// Send any file as an attachment; the message type follows the
    /// content type the daemon guesses from the file name.
    #[serde(rename = "sendFile")]
    SendFile {
        room_id: String,
        /// Local filesystem path of the file to upload and send.
        path: String,
        /// When set, the attachment threads into this thread root
        /// (MSC3440) instead of the room timeline.
        #[serde(default)]
        thread_root: Option<String>,
    },
    /// Fetch a history page: the `limit` newest messages ending at the
    /// token `from` (None = the most recent end), with a
    /// `updateRoomMessages` response whose `end` feeds the next older
    /// page.
    #[serde(rename = "getRoomMessages")]
    GetRoomMessages {
        room_id: String,
        #[serde(default)]
        limit: Option<u32>,
        #[serde(default)]
        from: Option<String>,
        /// Event-type narrowing for the page: "image" keeps only
        /// `m.image` messages (the photo-browser walk).  None — the
        /// room-buffer path — returns every event type.
        #[serde(default)]
        filter: Option<String>,
    },
    /// Paginate one thread (MSC3440): the `limit` newest events in the
    /// thread rooted at `thread_root` ending at the token `from`
    /// (None = the most recent).  Repeats the bundled-summary seeding
    /// the history pages do, so listing a thread refreshes its fold's
    /// latest.
    #[serde(rename = "getThreadMessages")]
    GetThreadMessages {
        room_id: String,
        thread_root: String,
        #[serde(default)]
        limit: Option<u32>,
        #[serde(default)]
        from: Option<String>,
    },
    /// Advance the room's read state: the private `m.read.private`
    /// receipt and the `m.fully_read` marker always go out; a public
    /// `m.read` receipt only when `public_receipt` is set.  The move
    /// echoes back through `updateOwnReadReceipt` when the account's
    /// own sync reports it.
    #[serde(rename = "markRoomRead")]
    MarkRoomRead {
        room_id: String,
        #[serde(default)]
        event_id: Option<String>,
        /// Also send a public `m.read` receipt.  Off by default: the public
        /// receipt is federated to every room member, while the private
        /// `m.read.private` receipt and `m.fully_read` marker (always sent)
        /// keep the user's own unread counters without telling anyone.
        #[serde(default)]
        public_receipt: Option<bool>,
    },
    /// Seed incoming read receipts for a room: every other joined
    /// member's latest public `m.read` receipt from the SDK store.
    #[serde(rename = "getRoomReceipts")]
    GetRoomReceipts { room_id: String },
    /// Fetch media into the on-disk cache (`media.rs`); the terminal
    /// `updateMediaFile` arrives only when the bytes are on disk, the
    /// lifecycle ("downloading"/error) rides `updateDownload`.
    #[serde(rename = "downloadMedia")]
    DownloadMedia {
        source: serde_json::Value,
        /// "thumb" (server-side thumbnail, plain sources) or "file" (full
        /// content, also for encrypted sources — the SDK decrypts), and
        /// part of the cache key: the thumbnail and the full file of one
        /// mxc are different content.
        format: String,
        /// Original file name (the message's `filename`); used only to pick
        /// the cache file's extension.
        #[serde(default)]
        filename: Option<String>,
    },
    /// Cancel an in-flight download (cache-keyed like `downloadMedia`).
    #[serde(rename = "cancelDownload")]
    CancelDownload {
        source: serde_json::Value,
        format: String,
    },
    /// Query the cache: response says where the file would live and whether
    /// it is already there.  Never starts a download.
    #[serde(rename = "getMediaFile")]
    GetMediaFile {
        source: serde_json::Value,
        format: String,
    },
}

/// Media metadata attached to an image message entry.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MediaEntry {
    /// Serialized ruma `MediaSource`: `{"url": "mxc://..."}` for plain
    /// content, or the full encrypted-file object for e2e rooms.
    pub source: serde_json::Value,
    /// The sender-provided thumbnail source, when present (usually a plain
    /// mxc even inside encrypted rooms).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thumb_source: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mimetype: Option<String>,
    /// Original file name (`filename` content field; empty for most
    /// images, where `body` doubles as the name).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub filename: Option<String>,
    /// Content size in bytes (`info.size`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size: Option<u64>,
    /// Playback duration in milliseconds (audio/video).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration: Option<u64>,
    /// Voice-note waveform amplitudes, each 0..=1024 (MSC3246).  Present
    /// only for voice messages (an MSC3245 voice marker block); its
    /// presence is the voice flag — the UI renders the bars and plays
    /// the note instead of showing a generic audio file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub voice: Option<Vec<u32>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub width: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub height: Option<u64>,
}

/// One aggregated reaction key on a target event.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReactionEntry {
    /// The reaction key (usually an emoji, but any string is valid).
    pub key: String,
    /// Number of distinct reaction events with this key.
    pub count: u64,
    /// Whether this user is among the senders (drives the UI toggle).
    pub own: bool,
}

/// One aggregated poll answer, with the votes the daemon has seen.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PollOption {
    /// The answer id (the `m.id` on `m.poll.start`; an opaque short
    /// string the daemon assigns when creating).
    pub id: String,
    /// The answer's text.
    pub text: String,
    /// Number of voters whose latest remaining response selects this
    /// answer.  Zeroed while a poll is undisclosed and not ended
    /// (MSC3381: intermediate results must not leak).
    pub count: u64,
    /// Whether the own account is among this answer's voters.
    pub own: bool,
    /// The voters' user ids, in first-vote order.  Filled only for
    /// disclosed kinds (and once a poll ended).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub voters: Vec<String>,
}

/// The aggregated state of a poll (MSC3381), carried on the `m.poll.start`
/// message entry (and the `updateNewMessage`/`updatePoll` events).  Votes
/// of undisclosed live polls ship count/voter-blind — `own` stays honest,
/// so the UI can highlight what the user picked.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PollEntry {
    pub question: String,
    /// `m.disclosed` (live results) or `m.undisclosed` (results only
    /// after the end event).  Custom/wire-unknown kinds count as
    /// undisclosed.
    pub kind: String,
    /// How many answers one response may select (1 for single choice).
    pub max_selections: u64,
    pub options: Vec<PollOption>,
    /// An `m.poll.end` event targeting this poll arrived: results are
    /// final; voting further is a client-side error.
    pub ended: bool,
}

/// One other member's latest public `m.read` receipt in a room.
/// Receipts are per-user: the target event id is what that user has
/// read up to.  Members whose clients only send private receipts
/// (Element X) never appear here.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReceiptEntry {
    pub user_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user_name: Option<String>,
    /// Event id the user has read up to.
    pub event_id: String,
    /// When the user read that far (ms since epoch).
    pub ts: u64,
    /// Origin-server timestamp of the target event — its true timeline
    /// position, independent of when the user read.  None when the
    /// daemon has not seen the target event; the client treats such
    /// receipts as covering nothing.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_ts: Option<u64>,
}

/// One member of a room in the `updateRoomMembers` roster —
/// `@`-completion's raw material.  A member with no set display name
/// ships None; Emacs offers the user id itself.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MemberEntry {
    pub user_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
}

/// `m.mentions` (MSC3952) from raw message content: the explicit user
/// ids the sender @-mentioned and the @room everyone-flag.  ruma's
/// typed content drops it for `m.room.message`, so the daemon reads
/// the raw JSON like the voice blocks.  Bounded: at most 64 ids ride
/// the wire.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Mentions {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub user_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub room: bool,
}

/// One rendered chat message, oldest->newest in list contexts.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MessageEntry {
    pub event_id: String,
    pub sender: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sender_name: Option<String>,
    /// The sender's avatar (`mxc://` URL from room member state), when
    /// set.  Emacs fetches it through the thumbnail path for the
    /// avatar column.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sender_avatar: Option<String>,
    /// Trust snapshot of the sender at decryption time: "verified",
    /// "unverified", "unsigned", "violation" or "mismatch".  Absent
    /// for unencrypted rooms, undecryptable placeholders and redacted
    /// events.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sender_trust: Option<String>,
    pub body: String,
    /// `org.matrix.custom.html` version of `body`, when the sender
    /// sent one.  Emacs renders it with shr; absent means plain only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub formatted_body: Option<String>,
    pub ts: u64,
    pub msgtype: String,
    pub is_own: bool,
    /// Media metadata for `m.image` entries, absent otherwise.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub media: Option<MediaEntry>,
    /// Event id this message replies to (`m.in_reply_to`), if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply_to: Option<String>,
    /// Thread (MSC3440): id of the thread root this message replies
    /// under, when it carries an `m.thread` relation.  Absent for
    /// ordinary timeline messages and the root itself.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thread_root: Option<String>,
    /// Aggregated reactions on this event, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reactions: Option<Vec<ReactionEntry>>,
    /// Timestamp of the newest edit (`m.replace`) folded into this
    /// message, if any.  Emacs renders an `(edited)` marker.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edited: Option<u64>,
    /// The event was redacted: the content is gone, Emacs renders a
    /// marker instead of the body.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub redacted: Option<bool>,
    /// `m.location` only: the `geo:` URI the sender shipped.  Emacs
    /// builds an OSM link from it; absent for protocol-2 daemons.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub geo: Option<String>,
    /// `m.mentions` (MSC3952), when the sender sent the block.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mentions: Option<Mentions>,
    /// Poll start event (MSC3381): the aggregated poll, rendered in
    /// place of the body text.  Absent for every other message and for
    /// protocol-10 daemons.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub poll: Option<PollEntry>,
}

/// Everything the room bar needs to display and sort one room.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RoomSummary {
    pub room_id: String,
    /// This side's state in the room: "joined" or "invited" (an invite
    /// has no timeline yet — its room appears in the list so it can be
    /// accepted or declined, but with no preview and zero counts).
    pub room_state: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub display_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub topic: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub canonical_alias: Option<String>,
    pub is_encrypted: bool,
    pub is_direct: bool,
    pub is_space: bool,
    pub unread_notifications: u64,
    pub unread_highlights: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_activity: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_event_preview: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_event_id: Option<String>,
    /// Effective notification mode: "all_messages",
    /// "mentions_and_keywords" or "mute".  Absent when the room is not
    /// joined or no mode could be determined.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notification_mode: Option<String>,
    /// The mode the user explicitly configured for this room, present
    /// only when there is one (as opposed to the room-type default).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_defined_notification_mode: Option<String>,
    /// Protocol the room is bridged into (`m.bridge` state, MSC 2346:
    /// e.g. "Telegram").  Absent for native Matrix rooms.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bridge_protocol: Option<String>,
    /// The room this one was upgraded to (`m.room.tombstone` ->
    /// `content.replacement_room`): present on the dead old room after
    /// an upgrade, so the client can point at its successor.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upgraded_to: Option<String>,
    /// The older room this one continues (`m.room.create` ->
    /// `content.predecessor.room_id`, or the dynamic `m.room.predecessor`
    /// event): present on the replacement room, so the client can point
    /// back at the history split.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upgraded_from: Option<String>,
    /// The events pinned via `m.room.pinned_events` (event-id strings);
    /// absent when the room carries no pinned-events state.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pinned_events: Option<Vec<String>>,
}

/// One room as a space offers it (the `getRoomHierarchy` response's
/// rows; also the parent rows of `roomSpaces`).  A discovery listing's
/// raw material: identity, metadata, the join rule and whether this
/// side is already in — so the UI offers Join only where it can.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HierarchyRoom {
    pub room_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub topic: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub canonical_alias: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
    pub num_joined_members: u64,
    /// The room's join rule ("public", "invite", "knock",
    /// "knock_restricted", "restricted", "private"; a custom rule
    /// ships its own string).
    pub join_rule: String,
    /// The room's `m.room.create` type ("space" et al.); absent for
    /// ordinary rooms.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub room_type: Option<String>,
    /// This session is already joined (the UI shows Open, not Join).
    pub joined: bool,
    /// The `via` servers this row's parents' `m.space.child` state
    /// carries: the join route for a remote room with no alias, fed
    /// back into `joinRoom`'s `via`.  Present only where the listing's
    /// raw chunk knew it (a child row under its parent's
    /// `children_state`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub via: Option<Vec<String>>,
}

/// One account device as listed for the verification picker.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeviceSummary {
    pub device_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_seen_ts: Option<u64>,
    pub is_current: bool,
    pub verified: bool,
}

#[derive(Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "@type")]
pub enum Event {
    /// Terminal response to `login`/`getSession`: the active account's
    /// credentials (Emacs keeps non-secrets only; the access token
    /// stays daemon-side).
    #[serde(rename = "updateSession")]
    UpdateSession {
        user_id: String,
        device_id: String,
        access_token: String,
    },
    /// Sync loop health, deduped at the source: `state` is one of
    /// "synced", "syncing", "error" (with the latest error string).
    /// Only used for UI connection display and auto-restart planning
    /// downstream; a dead process is not reported here — that is the
    /// parent's exit observation.
    #[serde(rename = "updateSyncState")]
    UpdateSyncState {
        state: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    /// A verification flow opened or changed state: `we_started` says
    /// which side invoked `verifyDevice` vs. an incoming request from
    /// another device.
    #[serde(rename = "updateVerificationRequest")]
    UpdateVerificationRequest {
        flow_id: String,
        user_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        device_id: Option<String>,
        we_started: bool,
        state: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    /// The SAS short auth string of a flow: compare the 7 emoji pairs
    /// (or decimals) with the other side, `confirmSas` only on a match.
    #[serde(rename = "updateVerificationEmojis")]
    UpdateVerificationEmojis {
        flow_id: String,
        /// 7 × [symbol, description].
        emojis: Vec<[String; 2]>,
        decimals: [u16; 3],
    },
    /// Terminal response to `getDevices`: every device of the account.
    #[serde(rename = "updateDevices")]
    UpdateDevices { devices: Vec<DeviceSummary> },
    /// Key recovery/secret storage state moved (enabled, recovered,
    /// error) — the mirror of `getRecoveryState`.
    #[serde(rename = "updateRecoveryState")]
    UpdateRecoveryState {
        state: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    /// Follows `enableRecovery`'s ok (and its background twin, a
    /// first-time account's invisible crypto bring-up): the new
    /// backup's recovery key, shown once by Emacs — and stored at
    /// `stored_path` by the daemon.
    #[serde(rename = "recoveryEnabled")]
    RecoveryEnabled {
        /// Base58 recovery key, shown to the user once by Emacs.
        recovery_key: String,
        /// Where the daemon stored its copy (the session's data dir,
        /// 0600 file).  Absent only when storing failed.
        #[serde(skip_serializing_if = "Option::is_none")]
        stored_path: Option<String>,
    },
    /// Cross-signing enabled/trusted state of the session changed —
    /// drives the bar's `Verify: ACCOUNT` row.
    #[serde(rename = "updateCrossSigningStatus")]
    UpdateCrossSigningStatus { enabled: bool, trusted: bool },
    /// A new session found an identity it cannot adopt on its own:
    /// the account is cross-signed on the homeserver, but this machine
    /// holds no way to trust it (no secret storage to recover from, or
    /// storage without a stored recovery key here).  `reason` is
    /// `"no-storage"` (only verifying with another device helps) or
    /// `"no-recovery-key"` (entering the account's recovery key also
    /// would).  Emacs prompts once per profile per session, offering
    /// those flows.
    #[serde(rename = "updateVerificationNeeded")]
    UpdateVerificationNeeded { reason: String },
    /// Upsert one room's full summary (room bar sort/search/avatar
    /// state, invite display, the works).  Invited rooms ride this
    /// too, with `room_state: "invited"` in the summary.
    #[serde(rename = "updateRoom")]
    UpdateRoom { profile: String, room: RoomSummary },
    /// A room is gone from this account (left, invite declined,
    /// forgotten): Emacs prunes its registry entry.
    #[serde(rename = "updateRoomGone")]
    UpdateRoomGone { profile: String, room_id: String },
    /// A joinRoom/createRoom finished and the room is seeded.  The
    /// room id Emacs opens (the summary itself rides `updateRoom`
    /// ahead of this) — response event to the command's @req, so the
    /// caller can correlate a newly-created room it could not name.
    #[serde(rename = "roomJoined")]
    RoomJoined { room_id: String },
    /// The `getRoomHierarchy` response: one level (max_depth 1) of one
    /// room's offered rooms — the room itself is the first row, its
    /// direct children follow.  `next_batch` set means more pages
    /// follow (the request's `from` continues them).
    #[serde(rename = "roomHierarchy")]
    RoomHierarchy {
        room_id: String,
        rooms: Vec<HierarchyRoom>,
        #[serde(skip_serializing_if = "Option::is_none")]
        next_batch: Option<String>,
    },
    /// The `getRoomSpaces` response: the rooms a room declared itself
    /// a child of (`m.space.parent` state, canonical parent first).
    /// Parent metadata (name/avatar) rides only when this session is
    /// joined to the parent — otherwise the UI shows it by room id.
    #[serde(rename = "roomSpaces")]
    RoomSpaces {
        room_id: String,
        spaces: Vec<HierarchyRoom>,
    },
    /// The own account profile (the `getProfile` response): the
    /// homeserver's global display name and avatar mxc.  Both are
    /// optional — an unset profile keeps its fields off the wire,
    /// the way the CS API answers a never-set profile.
    #[serde(rename = "profile")]
    Profile {
        user_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        display_name: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        avatar_url: Option<String>,
    },
    /// This session's permissions in one room (the `roomPermissions`
    /// response): the own power level — a room creator rides INFINITE
    /// (`users' map absent under room v12+) — and what it allows, one
    /// gate per edit action.  The UI greys or refuses actions these
    /// deny and the room overview prints the line.
    #[serde(rename = "roomPermissions")]
    RoomPermissions {
        room_id: String,
        level: i64,
        /// Room creator, or not (with the level above).
        creator: bool,
        can_name: bool,
        can_topic: bool,
        can_avatar: bool,
        can_invite: bool,
        can_kick: bool,
        can_ban: bool,
        /// Editing the power levels themselves (for future UI).
        can_power: bool,
    },
    /// A new message arrived live (history pages ride
    /// `updateRoomMessages`).  The wire's richest event: body plus
    /// formatted body, media, reply/reactions/mentions contexts and
    /// the trust snapshot.
    #[serde(rename = "updateNewMessage")]
    UpdateNewMessage {
        profile: String,
        room_id: String,
        event_id: String,
        sender: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        sender_name: Option<String>,
        /// The sender's avatar (`mxc://` URL), when set.  Emacs fetches
        /// it through the thumbnail path for the avatar column.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sender_avatar: Option<String>,
        /// Trust snapshot of the sender at decryption time (see
        /// `MessageEntry::sender_trust`); absent for unencrypted rooms.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sender_trust: Option<String>,
        body: String,
        /// `org.matrix.custom.html` version of `body`, when present.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        formatted_body: Option<String>,
        ts: u64,
        msgtype: String,
        is_own: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        media: Option<MediaEntry>,
        /// Event id this message replies to, if any.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reply_to: Option<String>,
        /// Thread (MSC3440): id of the thread root, when this event
        /// replies under one.  Absent for ordinary timeline events.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        thread_root: Option<String>,
        /// Aggregated reactions on this event, if any.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reactions: Option<Vec<ReactionEntry>>,
        /// `m.mentions` (MSC3952), when the sender sent the block.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        mentions: Option<Mentions>,
        /// Poll start event (MSC3381): the aggregated poll.  Set only
        /// when MSGTYPE is `m.poll.start`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        poll: Option<PollEntry>,
    },
    /// Aggregated reactions of one event changed (reaction arrived, was
    /// redacted, or backfill aggregation learned about it).  An empty
    /// `reactions` list means no reactions remain — delete the display.
    #[serde(rename = "updateReactions")]
    UpdateReactions {
        profile: String,
        room_id: String,
        /// Id of the event the reactions attach to.
        event_id: String,
        /// The arriving event's own id (the reaction's or its
        /// redaction's): read-marker pass-over for events the client
        /// renders in place, never as messages.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        source_event_id: Option<String>,
        reactions: Vec<ReactionEntry>,
    },
    /// Aggregated state of one poll changed (a vote arrived, was
    /// redacted or replaced, the start was edited, or a poll end
    /// arrived).  Like `updateReactions`, this must not touch
    /// room-bar state; it re-renders one poll block in place.  A None
    /// `poll` means the start event was redacted — blank the block.
    #[serde(rename = "updatePoll")]
    UpdatePoll {
        profile: String,
        room_id: String,
        /// Id of the poll start event the block hangs on.
        event_id: String,
        /// The arriving event's own id (the vote's or the end's): like
        /// `updateReactions', read-marker pass-over for events the
        /// client never renders as messages.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        source_event_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        poll: Option<PollEntry>,
    },
    /// Public read receipts of other members changed (a receipt arrived
    /// live, or backfill seeding merged an older one).  Full refreshed
    /// list per room, like `updateReactions`; must not touch room-bar
    /// state.  Only members whose clients send public `m.read`
    /// receipts appear (Element Web/Desktop: yes; Element X: no).
    #[serde(rename = "updateReadReceipts")]
    UpdateReadReceipts {
        profile: String,
        room_id: String,
        receipts: Vec<ReceiptEntry>,
    },
    /// The room member roster (the `getRoomMembers` response): user
    /// ids and display names for @-completion.  Not a broadcast — a
    /// reply to the command's `@req`, so it stays out of event
    /// consumers' way; a client cache may simply replace its roster.
    #[serde(rename = "updateRoomMembers")]
    UpdateRoomMembers {
        profile: String,
        room_id: String,
        members: Vec<MemberEntry>,
    },
    /// The account's own read state moved: another device of this
    /// account marked the room read (own public `m.read` receipt or own
    /// private `m.read.private`, echoed back into this account's sync),
    /// or its `m.fully_read` marker moved (then TS is None).  One event
    /// per marker: the room is read up to EVENT-ID.  Never touches
    /// room-bar state; consumers use it to retire notification state
    /// for the room.
    #[serde(rename = "updateOwnReadReceipt")]
    UpdateOwnReadReceipt {
        profile: String,
        room_id: String,
        event_id: String,
        /// Receipt read-time, when the receipt carries one.
        ts: Option<u64>,
    },
    /// A message was edited (`m.replace`): EVENT-ID is the *original*
    /// event; the fields carry its whole new content.  Like
    /// `updateReactions`, this must not touch room-bar state.
    #[serde(rename = "updateEdited")]
    UpdateEdited {
        profile: String,
        room_id: String,
        event_id: String,
        body: String,
        /// `org.matrix.custom.html` version of `body`, when present.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        formatted_body: Option<String>,
        msgtype: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        media: Option<MediaEntry>,
        /// A `geo:` URI when the edited content is a location.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        geo: Option<String>,
        /// The edit event's own id: read-marker pass-over, like
        /// `updateReactions'.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        source_event_id: Option<String>,
        /// Timestamp of the edit event itself (for version history).
        edited_ts: u64,
    },
    /// A message was redacted: content is gone everywhere.  Emacs
    /// blanks its line to a marker and, only if the user opted into
    /// redaction history, keeps the original it still has locally.
    #[serde(rename = "updateMessageRedacted")]
    UpdateMessageRedacted {
        profile: String,
        room_id: String,
        event_id: String,
    },
    /// Terminal response to `getRoomMessages`: one history page
    /// (oldest->newest in `messages`), `end` the token for the next
    /// older page.
    #[serde(rename = "updateRoomMessages")]
    UpdateRoomMessages {
        profile: String,
        room_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        end: Option<String>,
        messages: Vec<MessageEntry>,
    },
    /// Terminal response to `getThreadMessages`: one thread page
    /// (oldest->newest in `messages`, every entry carrying
    /// `thread_root`), `end` the token for the next older page and
    /// `root` the thread root's own entry (None when it could not be
    /// loaded — Emacs pins a placeholder instead).
    #[serde(rename = "updateThreadMessages")]
    UpdateThreadMessages {
        profile: String,
        room_id: String,
        thread_root: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        root: Option<MessageEntry>,
        #[serde(skip_serializing_if = "Option::is_none")]
        end: Option<String>,
        messages: Vec<MessageEntry>,
    },
    /// Terminal response to the send commands (`sendMessage`,
    /// `sendImage`/`sendFile` via `handle_send_attachment`,
    /// `redactMessage`, `sendReaction`): `event_id` is the homeserver's
    /// id of the produced event; `None` only for an idempotent success
    /// producing no message (a `sendReaction` remove with nothing to
    /// remove).  A failed send answers a bare `@ok: false` ack.
    #[serde(rename = "updateSendResult")]
    UpdateSendResult {
        room_id: String,
        event_id: Option<String>,
    },
    /// Room keys changed (arrived with the room join, or rotated):
    /// consumers refresh decryption state for that room.
    #[serde(rename = "updateRoomKeys")]
    UpdateRoomKeys { profile: String, room_id: String },
    /// Terminal response to `downloadMedia`/`getMediaFile`: the cache path
    /// for the requested media.  `complete` says whether the bytes are on
    /// disk (`downloadMedia` responds only when they are; `getMediaFile`
    /// responds immediately with `complete: false` on a miss).
    #[serde(rename = "updateMediaFile")]
    UpdateMediaFile {
        path: String,
        complete: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        size: Option<u64>,
    },
    /// Unsolicited download lifecycle notification.  `state` is one of
    /// "downloading", "done", "error", "cancelled"; `source`/`format` echo
    /// the originating request so Emacs can match it.  The SDK fetches
    /// content in one piece, so there is no byte progress yet — the
    /// "downloading" event lets Emacs show an indeterminate indicator.
    #[serde(rename = "updateDownload")]
    UpdateDownload {
        source: serde_json::Value,
        format: String,
        state: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        size: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    /// Connection greeting, always the FIRST frame Emacs receives (main.rs
    /// queues it before anything can emit).  `release` is the daemon
    /// binary's human version, informational; `protocol` is the version
    /// Emacs gates activation on.
    #[serde(rename = "daemonInfo")]
    DaemonInfo { protocol: u32, release: String },
}

/// An event on its way out, with the request-correlation wrapper fields.
/// Terminal responses to a request carry `req`; pure notifications omit it.
#[derive(Debug)]
pub struct OutEvent {
    pub req: Option<u64>,
    pub ok: Option<bool>,
    pub error: Option<String>,
    pub event: Option<Event>,
}

impl OutEvent {
    /// Unsolicited event (no request correlation).
    pub fn event(event: Event) -> Self {
        Self {
            req: None,
            ok: None,
            error: None,
            event: Some(event),
        }
    }

    /// Terminal response carrying data; `@ok` defaults to true.
    pub fn response(req: Option<u64>, event: Event) -> Self {
        Self {
            req,
            ok: Some(true),
            error: None,
            event: Some(event),
        }
    }

    /// Bare ack, e.g. after a batch of unsolicited events.
    pub fn ack(req: Option<u64>, ok: bool, error: Option<String>) -> Self {
        Self {
            req,
            ok: Some(ok),
            error,
            event: None,
        }
    }

    /// Serialize to the JSON value that gets framed, injecting the wrapper
    /// fields into the object map.
    pub fn to_json(&self) -> serde_json::Value {
        use serde_json::Value;

        let mut obj = match &self.event {
            Some(event) => serde_json::to_value(event).expect("Event serialization cannot fail"),
            None => Value::Object(serde_json::Map::new()),
        };
        if let Some(req) = self.req {
            obj["@req"] = serde_json::json!(req);
        }
        if let Some(ok) = self.ok {
            obj["@ok"] = serde_json::json!(ok);
        }
        if let Some(error) = &self.error {
            obj["@error"] = serde_json::json!(error);
        }
        obj
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// Every command: serialize -> exact wire shape, and parse the exact wire
    /// shape back.  This is the daemon's half of the Emacs↔daemon contract —
    /// a change here means the lisp side must change too.
    #[test]
    fn command_golden_round_trips() {
        let cases: Vec<(Command, serde_json::Value)> = vec![
            (
                Command::Login {
                    homeserver: "matrix.org".into(),
                    username: "bernd".into(),
                    password: "s3cret".into(),
                    device_name: Some("Emacs".into()),
                },
                json!({
                    "@type": "login", "homeserver": "matrix.org",
                    "username": "bernd", "password": "s3cret",
                    "device_name": "Emacs"
                }),
            ),
            (Command::Logout, json!({"@type": "logout"})),
            (Command::GetSession, json!({"@type": "getSession"})),
            (
                Command::VerifyDevice {
                    user_id: "@a:hs".into(),
                    device_id: "DEV".into(),
                },
                json!({"@type": "verifyDevice", "user_id": "@a:hs", "device_id": "DEV"}),
            ),
            (
                Command::GetVerificationRequests,
                json!({"@type": "getVerificationRequests"}),
            ),
            (Command::GetDevices, json!({"@type": "getDevices"})),
            (
                Command::DeleteDevice {
                    device_id: "OLDDEV".into(),
                    password: Some("s3cret".into()),
                },
                json!({"@type": "deleteDevice", "device_id": "OLDDEV", "password": "s3cret"}),
            ),
            (
                Command::AcceptVerification {
                    flow_id: "flow1".into(),
                },
                json!({"@type": "acceptVerification", "flow_id": "flow1"}),
            ),
            (
                Command::StartSas {
                    flow_id: "flow1".into(),
                },
                json!({"@type": "startSas", "flow_id": "flow1"}),
            ),
            (
                Command::ConfirmSas {
                    flow_id: "flow1".into(),
                },
                json!({"@type": "confirmSas", "flow_id": "flow1"}),
            ),
            (
                Command::CancelVerification {
                    flow_id: "flow1".into(),
                },
                json!({"@type": "cancelVerification", "flow_id": "flow1"}),
            ),
            (
                Command::GetCrossSigningStatus,
                json!({"@type": "getCrossSigningStatus"}),
            ),
            (
                Command::SetupCrossSigning,
                json!({"@type": "setupCrossSigning"}),
            ),
            (Command::EnableRecovery, json!({"@type": "enableRecovery"})),
            (
                Command::RecoverRecoveryKey { key: "EsTp".into() },
                json!({"@type": "recoverRecoveryKey", "key": "EsTp"}),
            ),
            (
                Command::GetRecoveryState,
                json!({"@type": "getRecoveryState"}),
            ),
            (
                Command::RotateRecoveryKey { old_key: None },
                json!({"@type": "rotateRecoveryKey"}),
            ),
            (
                Command::RotateRecoveryKey {
                    old_key: Some("EsTp".into()),
                },
                json!({"@type": "rotateRecoveryKey", "old_key": "EsTp"}),
            ),
            (
                Command::DisableRecovery,
                json!({"@type": "disableRecovery"}),
            ),
            (Command::Sync, json!({"@type": "sync"})),
            (Command::StartSync, json!({"@type": "startSync"})),
            (Command::StopSync, json!({"@type": "stopSync"})),
            (
                Command::AcceptInvite {
                    room_id: "!r:hs".into(),
                },
                json!({"@type": "acceptInvite", "room_id": "!r:hs"}),
            ),
            (
                Command::DeclineInvite {
                    room_id: "!r:hs".into(),
                },
                json!({"@type": "declineInvite", "room_id": "!r:hs"}),
            ),
            (
                Command::JoinRoom {
                    room_id_or_alias: "#r:hs".into(),
                    via: None,
                },
                json!({"@type": "joinRoom", "room_id_or_alias": "#r:hs"}),
            ),
            (
                Command::JoinRoom {
                    room_id_or_alias: "!c:hs".into(),
                    via: Some(vec!["hs".into(), "mirror:hs".into()]),
                },
                json!({"@type": "joinRoom", "room_id_or_alias": "!c:hs",
                       "via": ["hs", "mirror:hs"]}),
            ),
            (
                Command::LeaveRoom {
                    room_id: "!r:hs".into(),
                },
                json!({"@type": "leaveRoom", "room_id": "!r:hs"}),
            ),
            (
                Command::ForgetRoom {
                    room_id: "!r:hs".into(),
                },
                json!({"@type": "forgetRoom", "room_id": "!r:hs"}),
            ),
            (
                Command::InviteUser {
                    room_id: "!r:hs".into(),
                    user_id: "@u:hs".into(),
                },
                json!({"@type": "inviteUser", "room_id": "!r:hs", "user_id": "@u:hs"}),
            ),
            (
                Command::KickUser {
                    room_id: "!r:hs".into(),
                    user_id: "@u:hs".into(),
                    reason: Some("bye".into()),
                },
                json!({"@type": "kickUser", "room_id": "!r:hs", "user_id": "@u:hs", "reason": "bye"}),
            ),
            (
                Command::KickUser {
                    room_id: "!r:hs".into(),
                    user_id: "@u:hs".into(),
                    reason: None,
                },
                json!({"@type": "kickUser", "room_id": "!r:hs", "user_id": "@u:hs"}),
            ),
            (
                Command::BanUser {
                    room_id: "!r:hs".into(),
                    user_id: "@u:hs".into(),
                    reason: Some("spam".into()),
                },
                json!({"@type": "banUser", "room_id": "!r:hs", "user_id": "@u:hs", "reason": "spam"}),
            ),
            (
                Command::BanUser {
                    room_id: "!r:hs".into(),
                    user_id: "@u:hs".into(),
                    reason: None,
                },
                json!({"@type": "banUser", "room_id": "!r:hs", "user_id": "@u:hs"}),
            ),
            (
                Command::UnbanUser {
                    room_id: "!r:hs".into(),
                    user_id: "@u:hs".into(),
                },
                json!({"@type": "unbanUser", "room_id": "!r:hs", "user_id": "@u:hs"}),
            ),
            (
                Command::SetRoomName {
                    room_id: "!r:hs".into(),
                    name: "New name".into(),
                },
                json!({"@type": "setRoomName", "room_id": "!r:hs", "name": "New name"}),
            ),
            (
                Command::SetRoomTopic {
                    room_id: "!r:hs".into(),
                    topic: "New topic".into(),
                },
                json!({"@type": "setRoomTopic", "room_id": "!r:hs", "topic": "New topic"}),
            ),
            (
                Command::SetOwnDisplayName {
                    room_id: "!r:hs".into(),
                    name: Some("Nick".into()),
                },
                json!({"@type": "setOwnDisplayName", "room_id": "!r:hs", "name": "Nick"}),
            ),
            (
                Command::SetOwnDisplayName {
                    room_id: "!r:hs".into(),
                    name: None,
                },
                json!({"@type": "setOwnDisplayName", "room_id": "!r:hs"}),
            ),
            (
                Command::CreateRoom {
                    name: Some("Ops".into()),
                    alias: Some("ops".into()),
                    public: false,
                    topic: Some("topic".into()),
                    invites: vec!["@u:hs".into()],
                    is_direct: true,
                    encrypted: true,
                },
                json!({"@type": "createRoom", "name": "Ops", "alias": "ops",
                       "topic": "topic", "invites": ["@u:hs"], "is_direct": true,
                       "encrypted": true}),
            ),
            (
                Command::CreateRoom {
                    name: Some("Pub".into()),
                    alias: None,
                    public: true,
                    topic: None,
                    invites: Vec::new(),
                    is_direct: false,
                    encrypted: false,
                },
                json!({"@type": "createRoom", "name": "Pub", "public": true}),
            ),
            (
                Command::SetDisplayName {
                    name: Some("Me".into()),
                },
                json!({"@type": "setDisplayName", "name": "Me"}),
            ),
            (
                Command::SetDisplayName { name: None },
                json!({"@type": "setDisplayName"}),
            ),
            (
                Command::SetAvatar {
                    local_path: Some("/tmp/a.png".into()),
                },
                json!({"@type": "setAvatar", "local_path": "/tmp/a.png"}),
            ),
            (
                Command::SetAvatar { local_path: None },
                json!({"@type": "setAvatar"}),
            ),
            (
                Command::SetRoomAvatar {
                    room_id: "!r:hs".into(),
                    local_path: Some("/tmp/r.png".into()),
                },
                json!({"@type": "setRoomAvatar", "room_id": "!r:hs",
                       "local_path": "/tmp/r.png"}),
            ),
            (
                Command::SetRoomAvatar {
                    room_id: "!r:hs".into(),
                    local_path: None,
                },
                json!({"@type": "setRoomAvatar", "room_id": "!r:hs"}),
            ),
            (
                Command::RoomPermissions {
                    room_id: "!r:hs".into(),
                },
                json!({"@type": "roomPermissions", "room_id": "!r:hs"}),
            ),
            (Command::GetProfile, json!({"@type": "getProfile"})),
            (Command::GetRooms, json!({"@type": "getRooms"})),
            (
                Command::GetRoomMembers {
                    room_id: "!r:hs".into(),
                },
                json!({"@type": "getRoomMembers", "room_id": "!r:hs"}),
            ),
            (
                Command::GetRoomHierarchy {
                    room_id: "!r:hs".into(),
                    from: None,
                    limit: None,
                },
                json!({"@type": "getRoomHierarchy", "room_id": "!r:hs"}),
            ),
            (
                Command::GetRoomHierarchy {
                    room_id: "!r:hs".into(),
                    from: Some("tok:hs".into()),
                    limit: Some(50),
                },
                json!({"@type": "getRoomHierarchy", "room_id": "!r:hs",
                       "from": "tok:hs", "limit": 50}),
            ),
            (
                Command::GetRoomSpaces {
                    room_id: "!r:hs".into(),
                },
                json!({"@type": "getRoomSpaces", "room_id": "!r:hs"}),
            ),
            (
                Command::SendMessage {
                    room_id: "!r:hs".into(),
                    body: "hello".into(),
                    formatted_body: None,
                    reply_to: None,
                    replaces: None,
                    thread_root: None,
                    mentions: None,
                    room_mentions: false,
                },
                json!({"@type": "sendMessage", "room_id": "!r:hs", "body": "hello"}),
            ),
            (
                Command::SendMessage {
                    room_id: "!r:hs".into(),
                    body: "hello".into(),
                    formatted_body: None,
                    reply_to: Some("$p:hs".into()),
                    replaces: None,
                    thread_root: None,
                    mentions: None,
                    room_mentions: false,
                },
                json!({"@type": "sendMessage", "room_id": "!r:hs", "body": "hello",
                       "reply_to": "$p:hs"}),
            ),
            (
                // Thread reply: thread_root names the thread,
                // reply_to the in-thread reply target (the two ids
                // may coincide on a plain thread send — the elisp
                // side sends reply_to only for genuine replies).
                Command::SendMessage {
                    room_id: "!r:hs".into(),
                    body: "thread reply".into(),
                    formatted_body: None,
                    reply_to: Some("$p:hs".into()),
                    thread_root: Some("$root:hs".into()),
                    replaces: None,
                    mentions: None,
                    room_mentions: false,
                },
                json!({"@type": "sendMessage", "room_id": "!r:hs", "body": "thread reply",
                       "reply_to": "$p:hs", "thread_root": "$root:hs"}),
            ),
            (
                Command::SendMessage {
                    room_id: "!r:hs".into(),
                    body: "hello".into(),
                    formatted_body: None,
                    reply_to: None,
                    replaces: Some("$orig:hs".into()),
                    thread_root: None,
                    mentions: None,
                    room_mentions: false,
                },
                json!({"@type": "sendMessage", "room_id": "!r:hs", "body": "hello",
                       "replaces": "$orig:hs"}),
            ),
            (
                Command::SendMessage {
                    room_id: "!r:hs".into(),
                    body: "hello".into(),
                    formatted_body: Some("<strong>hello</strong>".into()),
                    reply_to: None,
                    replaces: None,
                    thread_root: None,
                    mentions: None,
                    room_mentions: false,
                },
                json!({"@type": "sendMessage", "room_id": "!r:hs", "body": "hello",
                       "formatted_body": "<strong>hello</strong>"}),
            ),
            (
                Command::SendMessage {
                    room_id: "!r:hs".into(),
                    body: "Alice hi".into(),
                    formatted_body: None,
                    reply_to: None,
                    replaces: None,
                    thread_root: None,
                    mentions: Some(vec!["@a:hs".into()]),
                    room_mentions: false,
                },
                json!({"@type": "sendMessage", "room_id": "!r:hs", "body": "Alice hi",
                       "mentions": ["@a:hs"]}),
            ),
            (
                Command::SendMessage {
                    room_id: "!r:hs".into(),
                    body: "hi @room".into(),
                    formatted_body: None,
                    reply_to: None,
                    replaces: None,
                    thread_root: None,
                    mentions: None,
                    room_mentions: true,
                },
                json!({"@type": "sendMessage", "room_id": "!r:hs", "body": "hi @room",
                       "room_mentions": true}),
            ),
            (
                Command::RedactMessage {
                    room_id: "!r:hs".into(),
                    event_id: "$e:hs".into(),
                    reason: None,
                },
                json!({"@type": "redactMessage", "room_id": "!r:hs", "event_id": "$e:hs"}),
            ),
            (
                Command::RedactMessage {
                    room_id: "!r:hs".into(),
                    event_id: "$e:hs".into(),
                    reason: Some("on second thought".into()),
                },
                json!({"@type": "redactMessage", "room_id": "!r:hs", "event_id": "$e:hs",
                       "reason": "on second thought"}),
            ),
            (
                Command::SendReaction {
                    room_id: "!r:hs".into(),
                    event_id: "$e:hs".into(),
                    key: "👍".into(),
                    remove: None,
                },
                json!({"@type": "sendReaction", "room_id": "!r:hs", "event_id": "$e:hs",
                       "key": "👍"}),
            ),
            (
                Command::PinMessage {
                    room_id: "!r:hs".into(),
                    event_id: "$e:hs".into(),
                    unpin: None,
                },
                json!({"@type": "pinMessage", "room_id": "!r:hs", "event_id": "$e:hs"}),
            ),
            (
                Command::PinMessage {
                    room_id: "!r:hs".into(),
                    event_id: "$e:hs".into(),
                    unpin: Some(true),
                },
                json!({"@type": "pinMessage", "room_id": "!r:hs", "event_id": "$e:hs",
                       "unpin": true}),
            ),
            (
                Command::SendReaction {
                    room_id: "!r:hs".into(),
                    event_id: "$e:hs".into(),
                    key: "👍".into(),
                    remove: Some(true),
                },
                json!({"@type": "sendReaction", "room_id": "!r:hs", "event_id": "$e:hs",
                       "key": "👍", "remove": true}),
            ),
            (
                Command::SendImage {
                    room_id: "!r:hs".into(),
                    path: "/tmp/p.png".into(),
                    thread_root: None,
                },
                json!({"@type": "sendImage", "room_id": "!r:hs", "path": "/tmp/p.png",
                       "thread_root": null}),
            ),
            (
                Command::SendImage {
                    room_id: "!r:hs".into(),
                    path: "/tmp/p.png".into(),
                    thread_root: Some("$root:hs".into()),
                },
                json!({"@type": "sendImage", "room_id": "!r:hs", "path": "/tmp/p.png",
                       "thread_root": "$root:hs"}),
            ),
            (
                Command::SendFile {
                    room_id: "!r:hs".into(),
                    path: "/tmp/doc.pdf".into(),
                    thread_root: None,
                },
                json!({"@type": "sendFile", "room_id": "!r:hs", "path": "/tmp/doc.pdf",
                       "thread_root": null}),
            ),
            (
                Command::PollCreate {
                    room_id: "!r:hs".into(),
                    question: "lunch?".into(),
                    options: vec!["pizza".into(), "ramen".into()],
                    max_selections: None,
                    disclosed: None,
                },
                json!({"@type": "pollCreate", "room_id": "!r:hs", "question": "lunch?",
                       "options": ["pizza", "ramen"]}),
            ),
            (
                Command::PollCreate {
                    room_id: "!r:hs".into(),
                    question: "lunch?".into(),
                    options: vec!["pizza".into(), "ramen".into()],
                    max_selections: Some(3),
                    disclosed: Some(true),
                },
                json!({"@type": "pollCreate", "room_id": "!r:hs", "question": "lunch?",
                       "options": ["pizza", "ramen"], "max_selections": 3, "disclosed": true}),
            ),
            (
                Command::PollVote {
                    room_id: "!r:hs".into(),
                    event_id: "$start:hs".into(),
                    selections: vec!["o1".into()],
                },
                json!({"@type": "pollVote", "room_id": "!r:hs", "event_id": "$start:hs",
                       "selections": ["o1"]}),
            ),
            (
                Command::PollVote {
                    room_id: "!r:hs".into(),
                    event_id: "$start:hs".into(),
                    selections: vec![],
                },
                json!({"@type": "pollVote", "room_id": "!r:hs", "event_id": "$start:hs",
                       "selections": []}),
            ),
            (
                Command::PollEnd {
                    room_id: "!r:hs".into(),
                    event_id: "$start:hs".into(),
                },
                json!({"@type": "pollEnd", "room_id": "!r:hs", "event_id": "$start:hs"}),
            ),
            (
                Command::GetRoomMessages {
                    room_id: "!r:hs".into(),
                    limit: Some(25),
                    from: Some("tok_1".into()),
                    filter: None,
                },
                json!({
                    "@type": "getRoomMessages", "room_id": "!r:hs",
                    "limit": 25, "from": "tok_1", "filter": null
                }),
            ),
            (
                Command::GetRoomMessages {
                    room_id: "!r:hs".into(),
                    limit: Some(100),
                    from: Some("tok_1".into()),
                    filter: Some("image".into()),
                },
                json!({
                    "@type": "getRoomMessages", "room_id": "!r:hs",
                    "limit": 100, "from": "tok_1", "filter": "image"
                }),
            ),
            (
                Command::GetThreadMessages {
                    room_id: "!r:hs".into(),
                    thread_root: "$root:hs".into(),
                    limit: None,
                    from: None,
                },
                json!({
                    "@type": "getThreadMessages", "room_id": "!r:hs",
                    "thread_root": "$root:hs", "limit": null, "from": null
                }),
            ),
            (
                Command::MarkRoomRead {
                    room_id: "!r:hs".into(),
                    event_id: Some("$e:hs".into()),
                    public_receipt: None,
                },
                json!({"@type": "markRoomRead", "room_id": "!r:hs", "event_id": "$e:hs",
                       "public_receipt": null}),
            ),
            (
                Command::MarkRoomRead {
                    room_id: "!r:hs".into(),
                    event_id: Some("$e:hs".into()),
                    public_receipt: Some(true),
                },
                json!({"@type": "markRoomRead", "room_id": "!r:hs", "event_id": "$e:hs",
                       "public_receipt": true}),
            ),
            (
                Command::GetRoomReceipts {
                    room_id: "!r:hs".into(),
                },
                json!({"@type": "getRoomReceipts", "room_id": "!r:hs"}),
            ),
            (
                Command::DownloadMedia {
                    source: json!({"url": "mxc://hs/abc"}),
                    format: "file".into(),
                    filename: Some("clip.mp4".into()),
                },
                json!({
                    "@type": "downloadMedia", "source": {"url": "mxc://hs/abc"},
                    "format": "file", "filename": "clip.mp4"
                }),
            ),
            (
                Command::CancelDownload {
                    source: json!({"url": "mxc://hs/abc"}),
                    format: "file".into(),
                },
                json!({"@type": "cancelDownload", "source": {"url": "mxc://hs/abc"}, "format": "file"}),
            ),
            (
                Command::GetMediaFile {
                    source: json!({"url": "mxc://hs/abc"}),
                    format: "file".into(),
                },
                json!({"@type": "getMediaFile", "source": {"url": "mxc://hs/abc"}, "format": "file"}),
            ),
        ];
        for (cmd, golden) in cases {
            let wire =
                serde_json::to_value(&cmd).unwrap_or_else(|e| panic!("serialize {cmd:?}: {e}"));
            assert_eq!(wire, golden, "serialize {cmd:?}");
            assert_eq!(
                serde_json::from_value::<Command>(golden)
                    .unwrap_or_else(|e| panic!("parse {cmd:?}: {e}")),
                cmd,
                "parse {cmd:?}"
            );
        }
    }

    /// Optional command fields must parse to None when Emacs omits them
    /// (`#[serde(default)]`), not fail or demand explicit nulls.
    #[test]
    fn command_optional_fields_default() {
        let cmd =
            serde_json::from_str::<Command>(r#"{"@type":"getRoomMessages","room_id":"!r:hs"}"#)
                .unwrap();
        assert_eq!(
            cmd,
            Command::GetRoomMessages {
                room_id: "!r:hs".into(),
                limit: None,
                from: None,
                filter: None
            }
        );

        // getThreadMessages: limit/from ride only when Emacs sends them.
        let cmd = serde_json::from_str::<Command>(
            r#"{"@type":"getThreadMessages","room_id":"!r:hs","thread_root":"$root:hs"}"#,
        )
        .unwrap();
        assert_eq!(
            cmd,
            Command::GetThreadMessages {
                room_id: "!r:hs".into(),
                thread_root: "$root:hs".into(),
                limit: None,
                from: None,
            }
        );

        // deleteDevice: the password rides only when Emacs sends it.
        let cmd =
            serde_json::from_str::<Command>(r#"{"@type":"deleteDevice","device_id":"OLDDEV"}"#)
                .unwrap();
        assert_eq!(
            cmd,
            Command::DeleteDevice {
                device_id: "OLDDEV".into(),
                password: None
            }
        );

        let cmd = serde_json::from_str::<Command>(r#"{"@type":"markRoomRead","room_id":"!r:hs"}"#)
            .unwrap();
        assert_eq!(
            cmd,
            Command::MarkRoomRead {
                room_id: "!r:hs".into(),
                event_id: None,
                public_receipt: None,
            }
        );

        let cmd = serde_json::from_str::<Command>(
            r#"{"@type":"sendMessage","room_id":"!r:hs","body":"hello"}"#,
        )
        .unwrap();
        assert_eq!(
            cmd,
            Command::SendMessage {
                room_id: "!r:hs".into(),
                body: "hello".into(),
                formatted_body: None,
                reply_to: None,
                replaces: None,
                thread_root: None,
                mentions: None,
                room_mentions: false,
            }
        );

        let cmd = serde_json::from_str::<Command>(
            r#"{"@type":"redactMessage","room_id":"!r:hs","event_id":"$e:hs"}"#,
        )
        .unwrap();
        assert_eq!(
            cmd,
            Command::RedactMessage {
                room_id: "!r:hs".into(),
                event_id: "$e:hs".into(),
                reason: None,
            }
        );

        let cmd = serde_json::from_str::<Command>(
            r#"{"@type":"sendReaction","room_id":"!r:hs","event_id":"$e:hs","key":"👍"}"#,
        )
        .unwrap();
        assert_eq!(
            cmd,
            Command::SendReaction {
                room_id: "!r:hs".into(),
                event_id: "$e:hs".into(),
                key: "👍".into(),
                remove: None,
            }
        );

        let cmd = serde_json::from_str::<Command>(
            r#"{"@type":"login","homeserver":"h","username":"u","password":"p"}"#,
        )
        .unwrap();
        assert_eq!(
            cmd,
            Command::Login {
                homeserver: "h".into(),
                username: "u".into(),
                password: "p".into(),
                device_name: None,
            }
        );

        let cmd = serde_json::from_str::<Command>(
            r#"{"@type":"downloadMedia","source":{"url":"mxc://hs/abc"},"format":"file"}"#,
        )
        .unwrap();
        assert_eq!(
            cmd,
            Command::DownloadMedia {
                source: json!({"url": "mxc://hs/abc"}),
                format: "file".into(),
                filename: None,
            }
        );
    }

    /// Every event: serialize -> exact wire shape, and parse it back.  The
    /// lisp dispatches on `@type` and reads field names — both are pinned
    /// here.
    #[test]
    fn event_golden_round_trips() {
        let media = MediaEntry {
            source: json!({"url": "mxc://hs/abc"}),
            thumb_source: Some(json!({"url": "mxc://hs/thumb"})),
            mimetype: Some("image/png".into()),
            filename: Some("pic.png".into()),
            size: Some(64000),
            duration: Some(1500),
            voice: None,
            width: Some(640),
            height: Some(480),
        };
        let message = MessageEntry {
            event_id: "$e:hs".into(),
            sender: "@a:hs".into(),
            sender_name: Some("Alice".into()),
            sender_avatar: Some("mxc://hs/av1".into()),
            sender_trust: Some("verified".into()),
            body: "pic.png".into(),
            formatted_body: None,
            ts: 1737043200000u64,
            msgtype: "m.image".into(),
            is_own: false,
            media: Some(media),
            reply_to: None,
            thread_root: None,
            edited: None,
            redacted: None,
            mentions: None,
            reactions: None,
            geo: None,
            poll: None,
        };
        let room = RoomSummary {
            room_id: "!r:hs".into(),
            room_state: "joined".into(),
            name: Some("Room".into()),
            display_name: "Room".into(),
            avatar_url: None,
            topic: Some("Topic".into()),
            canonical_alias: None,
            is_encrypted: true,
            is_direct: false,
            is_space: false,
            unread_notifications: 3,
            unread_highlights: 1,
            last_activity: Some(1737043200000u64),
            last_event_preview: Some("hi".into()),
            last_event_id: Some("$e:hs".into()),
            notification_mode: Some("mute".into()),
            user_defined_notification_mode: Some("mute".into()),
            bridge_protocol: Some("Telegram".into()),
            upgraded_to: Some("!new:hs".into()),
            upgraded_from: Some("!old:hs".into()),
            pinned_events: Some(vec!["$e:hs".into()]),
        };
        let cases: Vec<(Event, serde_json::Value)> = vec![
            (
                Event::UpdateSession {
                    user_id: "@a:hs".into(),
                    device_id: "DEV".into(),
                    access_token: "tok".into(),
                },
                json!({"@type": "updateSession", "user_id": "@a:hs", "device_id": "DEV", "access_token": "tok"}),
            ),
            (
                Event::UpdateSyncState {
                    state: "synced".into(),
                    error: None,
                },
                json!({"@type": "updateSyncState", "state": "synced"}),
            ),
            (
                Event::UpdateVerificationRequest {
                    flow_id: "flow1".into(),
                    user_id: "@a:hs".into(),
                    device_id: Some("DEV".into()),
                    we_started: true,
                    state: "requested".into(),
                    reason: None,
                },
                json!({
                    "@type": "updateVerificationRequest", "flow_id": "flow1",
                    "user_id": "@a:hs", "device_id": "DEV",
                    "we_started": true, "state": "requested"
                }),
            ),
            (
                Event::UpdateVerificationEmojis {
                    flow_id: "flow1".into(),
                    emojis: vec![
                        ["🦄".into(), "unicorn".into()],
                        ["🍕".into(), "pizza".into()],
                    ],
                    decimals: [1234, 5678, 9012],
                },
                json!({
                    "@type": "updateVerificationEmojis", "flow_id": "flow1",
                    "emojis": [["🦄", "unicorn"], ["🍕", "pizza"]],
                    "decimals": [1234, 5678, 9012]
                }),
            ),
            (
                Event::UpdateDevices {
                    devices: vec![DeviceSummary {
                        device_id: "DEV".into(),
                        display_name: Some("Laptop".into()),
                        last_seen_ts: Some(1737043200000u64),
                        is_current: true,
                        verified: false,
                    }],
                },
                json!({
                    "@type": "updateDevices",
                    "devices": [{
                        "device_id": "DEV", "display_name": "Laptop",
                        "last_seen_ts": 1737043200000u64,
                        "is_current": true, "verified": false
                    }]
                }),
            ),
            (
                Event::UpdateRecoveryState {
                    state: "error".into(),
                    error: Some("boom".into()),
                },
                json!({"@type": "updateRecoveryState", "state": "error", "error": "boom"}),
            ),
            (
                Event::RecoveryEnabled {
                    recovery_key: "EsTp".into(),
                    stored_path: None,
                },
                json!({"@type": "recoveryEnabled", "recovery_key": "EsTp"}),
            ),
            (
                Event::RecoveryEnabled {
                    recovery_key: "EsTp".into(),
                    stored_path: Some("/x/elneo/acct/recovery-key".into()),
                },
                json!({
                    "@type": "recoveryEnabled", "recovery_key": "EsTp",
                    "stored_path": "/x/elneo/acct/recovery-key"
                }),
            ),
            (
                Event::UpdateCrossSigningStatus {
                    enabled: true,
                    trusted: true,
                },
                json!({"@type": "updateCrossSigningStatus", "enabled": true, "trusted": true}),
            ),
            (
                Event::UpdateVerificationNeeded {
                    reason: "no-recovery-key".into(),
                },
                json!({"@type": "updateVerificationNeeded", "reason": "no-recovery-key"}),
            ),
            (
                Event::UpdateRoom {
                    profile: "main".into(),
                    room: room.clone(),
                },
                json!({
                    "@type": "updateRoom", "profile": "main",
                    "room": {
                        "room_id": "!r:hs", "room_state": "joined",
                        "name": "Room", "display_name": "Room",
                        "topic": "Topic", "is_encrypted": true, "is_direct": false,
                        "is_space": false, "unread_notifications": 3,
                        "unread_highlights": 1, "last_activity": 1737043200000u64,
                        "last_event_preview": "hi", "last_event_id": "$e:hs",
                        "notification_mode": "mute",
                        "user_defined_notification_mode": "mute",
                        "bridge_protocol": "Telegram",
                        "upgraded_to": "!new:hs", "upgraded_from": "!old:hs",
                        "pinned_events": ["$e:hs"]
                    }
                }),
            ),
            (
                Event::UpdateRoom {
                    profile: "none".into(),
                    room: {
                        // A linked-back room: the fields ride only when
                        // they exist — a room with no upgrade links
                        // serializes without them.
                        let plain = room.clone();
                        RoomSummary {
                            upgraded_to: None,
                            upgraded_from: None,
                            pinned_events: None,
                            ..plain
                        }
                    },
                },
                json!({
                    "@type": "updateRoom", "profile": "none",
                    "room": {
                        "room_id": "!r:hs", "room_state": "joined",
                        "name": "Room", "display_name": "Room",
                        "topic": "Topic", "is_encrypted": true, "is_direct": false,
                        "is_space": false, "unread_notifications": 3,
                        "unread_highlights": 1, "last_activity": 1737043200000u64,
                        "last_event_preview": "hi", "last_event_id": "$e:hs",
                        "notification_mode": "mute",
                        "user_defined_notification_mode": "mute",
                        "bridge_protocol": "Telegram"
                    }
                }),
            ),
            (
                Event::UpdateRoomGone {
                    profile: "main".into(),
                    room_id: "!r:hs".into(),
                },
                json!({"@type": "updateRoomGone", "profile": "main", "room_id": "!r:hs"}),
            ),
            (
                Event::RoomJoined {
                    room_id: "!r:hs".into(),
                },
                json!({"@type": "roomJoined", "room_id": "!r:hs"}),
            ),
            (
                Event::RoomHierarchy {
                    room_id: "!r:hs".into(),
                    rooms: vec![
                        HierarchyRoom {
                            room_id: "!r:hs".into(),
                            name: Some("Ops".into()),
                            topic: None,
                            canonical_alias: Some("#ops:hs".into()),
                            avatar_url: Some("mxc://hs/av1".into()),
                            num_joined_members: 12,
                            join_rule: "public".into(),
                            room_type: None,
                            joined: true,
                            via: None,
                        },
                        HierarchyRoom {
                            room_id: "!c:hs".into(),
                            name: None,
                            topic: Some("Chat".into()),
                            canonical_alias: None,
                            avatar_url: None,
                            num_joined_members: 3,
                            join_rule: "invite".into(),
                            room_type: Some("m.space".into()),
                            joined: false,
                            via: Some(vec!["hs".into(), "mirror:hs".into()]),
                        },
                    ],
                    next_batch: Some("tok:hs".into()),
                },
                json!({
                    "@type": "roomHierarchy", "room_id": "!r:hs", "next_batch": "tok:hs",
                    "rooms": [
                        {"room_id": "!r:hs", "name": "Ops", "canonical_alias": "#ops:hs",
                         "avatar_url": "mxc://hs/av1", "num_joined_members": 12,
                         "join_rule": "public", "joined": true},
                        {"room_id": "!c:hs", "topic": "Chat", "num_joined_members": 3,
                         "join_rule": "invite", "room_type": "m.space", "joined": false,
                         "via": ["hs", "mirror:hs"]}
                    ]
                }),
            ),
            (
                Event::RoomHierarchy {
                    room_id: "!r:hs".into(),
                    rooms: Vec::new(),
                    next_batch: None,
                },
                json!({"@type": "roomHierarchy", "room_id": "!r:hs", "rooms": []}),
            ),
            (
                Event::RoomSpaces {
                    room_id: "!r:hs".into(),
                    spaces: vec![HierarchyRoom {
                        room_id: "!s:hs".into(),
                        name: Some("The Space".into()),
                        topic: None,
                        canonical_alias: Some("#space:hs".into()),
                        avatar_url: Some("mxc://hs/spav".into()),
                        num_joined_members: 40,
                        join_rule: "unknown".into(),
                        room_type: Some("m.space".into()),
                        joined: true,
                        via: None,
                    }],
                },
                json!({
                    "@type": "roomSpaces", "room_id": "!r:hs",
                    "spaces": [{"room_id": "!s:hs", "name": "The Space",
                                "canonical_alias": "#space:hs",
                                "avatar_url": "mxc://hs/spav",
                                "num_joined_members": 40, "join_rule": "unknown",
                                "room_type": "m.space", "joined": true}]
                }),
            ),
            (
                Event::Profile {
                    user_id: "@a:hs".into(),
                    display_name: Some("Alice".into()),
                    avatar_url: Some("mxc://hs/av1".into()),
                },
                json!({
                    "@type": "profile", "user_id": "@a:hs",
                    "display_name": "Alice", "avatar_url": "mxc://hs/av1"
                }),
            ),
            (
                Event::Profile {
                    user_id: "@a:hs".into(),
                    display_name: None,
                    avatar_url: None,
                },
                json!({"@type": "profile", "user_id": "@a:hs"}),
            ),
            (
                Event::RoomPermissions {
                    room_id: "!r:hs".into(),
                    level: 50,
                    creator: false,
                    can_name: true,
                    can_topic: true,
                    can_avatar: true,
                    can_invite: true,
                    can_kick: true,
                    can_ban: false,
                    can_power: true,
                },
                json!({
                    "@type": "roomPermissions", "room_id": "!r:hs", "level": 50,
                    "creator": false, "can_name": true, "can_topic": true,
                    "can_avatar": true, "can_invite": true, "can_kick": true,
                    "can_ban": false, "can_power": true
                }),
            ),
            (
                Event::UpdateNewMessage {
                    profile: "main".into(),
                    room_id: "!r:hs".into(),
                    event_id: "$e:hs".into(),
                    sender: "@a:hs".into(),
                    sender_name: Some("Alice".into()),
                    sender_avatar: Some("mxc://hs/av1".into()),
                    sender_trust: Some("verified".into()),
                    body: "pic.png".into(),
                    formatted_body: None,
                    ts: 1737043200000u64,
                    msgtype: "m.image".into(),
                    is_own: false,
                    media: Some(MediaEntry {
                        source: json!({"url": "mxc://hs/abc"}),
                        thumb_source: None,
                        mimetype: None,
                        filename: None,
                        size: None,
                        duration: None,
                        voice: None,
                        width: None,
                        height: None,
                    }),
                    reply_to: None,
                    thread_root: None,
                    reactions: None,
                    mentions: None,
                    poll: None,
                },
                json!({
                    "@type": "updateNewMessage", "profile": "main", "room_id": "!r:hs",
                    "event_id": "$e:hs", "sender": "@a:hs", "sender_name": "Alice",
                    "sender_avatar": "mxc://hs/av1", "sender_trust": "verified",
                    "body": "pic.png", "ts": 1737043200000u64, "msgtype": "m.image",
                    "is_own": false,
                    "media": {"source": {"url": "mxc://hs/abc"}}
                }),
            ),
            (
                Event::UpdateNewMessage {
                    profile: "main".into(),
                    room_id: "!r:hs".into(),
                    event_id: "$e2:hs".into(),
                    sender: "@a:hs".into(),
                    sender_name: None,
                    sender_avatar: None,
                    sender_trust: None,
                    body: "re: pic".into(),
                    formatted_body: None,
                    ts: 1737043200001u64,
                    msgtype: "m.text".into(),
                    is_own: true,
                    media: None,
                    reply_to: Some("$e:hs".into()),
                    thread_root: Some("$troot:hs".into()),
                    reactions: Some(vec![ReactionEntry {
                        key: "👍".into(),
                        count: 2,
                        own: true,
                    }]),
                    mentions: Some(Mentions {
                        user_ids: vec!["@bob:hs".into()],
                        room: false,
                    }),
                    poll: None,
                },
                json!({
                    "@type": "updateNewMessage", "profile": "main", "room_id": "!r:hs",
                    "event_id": "$e2:hs", "sender": "@a:hs",
                    "body": "re: pic", "ts": 1737043200001u64, "msgtype": "m.text",
                    "is_own": true, "reply_to": "$e:hs", "thread_root": "$troot:hs",
                    "reactions": [{"key": "👍", "count": 2, "own": true}],
                    "mentions": {"user_ids": ["@bob:hs"]}
                }),
            ),
            (
                Event::UpdateReactions {
                    profile: "main".into(),
                    room_id: "!r:hs".into(),
                    event_id: "$e:hs".into(),
                    // The reaction's own id, omitted on the wire (None).
                    source_event_id: None,
                    reactions: vec![
                        ReactionEntry {
                            key: "👍".into(),
                            count: 2,
                            own: true,
                        },
                        ReactionEntry {
                            key: "❤".into(),
                            count: 1,
                            own: false,
                        },
                    ],
                },
                json!({
                    "@type": "updateReactions", "profile": "main", "room_id": "!r:hs",
                    "event_id": "$e:hs",
                    "reactions": [
                        {"key": "👍", "count": 2, "own": true},
                        {"key": "❤", "count": 1, "own": false}
                    ]
                }),
            ),
            (
                Event::UpdateReactions {
                    profile: "main".into(),
                    room_id: "!r:hs".into(),
                    event_id: "$e:hs".into(),
                    // The reaction's own id, omitted on the wire (None).
                    source_event_id: None,
                    reactions: vec![],
                },
                json!({
                    "@type": "updateReactions", "profile": "main", "room_id": "!r:hs",
                    "event_id": "$e:hs", "reactions": []
                }),
            ),
            (
                Event::UpdatePoll {
                    profile: "main".into(),
                    room_id: "!r:hs".into(),
                    event_id: "$start:hs".into(),
                    source_event_id: Some("$vote:hs".into()),
                    poll: Some(PollEntry {
                        question: "lunch?".into(),
                        kind: "m.disclosed".into(),
                        max_selections: 1,
                        ended: false,
                        options: vec![
                            PollOption {
                                id: "o1".into(),
                                text: "pizza".into(),
                                count: 1,
                                own: true,
                                voters: vec!["@a:hs".into()],
                            },
                            PollOption {
                                id: "o2".into(),
                                text: "ramen".into(),
                                count: 0,
                                own: false,
                                voters: vec![],
                            },
                        ],
                    }),
                },
                json!({
                    "@type": "updatePoll", "profile": "main", "room_id": "!r:hs",
                    "event_id": "$start:hs", "source_event_id": "$vote:hs",
                    "poll": {
                        "question": "lunch?", "kind": "m.disclosed", "max_selections": 1,
                        "ended": false,
                        "options": [
                            {"id": "o1", "text": "pizza", "count": 1, "own": true,
                             "voters": ["@a:hs"]},
                            {"id": "o2", "text": "ramen", "count": 0, "own": false}
                        ]
                    }
                }),
            ),
            (
                // A redacted poll start re-renders as a blank marker.
                Event::UpdatePoll {
                    profile: "main".into(),
                    room_id: "!r:hs".into(),
                    event_id: "$start:hs".into(),
                    source_event_id: None,
                    poll: None,
                },
                json!({
                    "@type": "updatePoll", "profile": "main", "room_id": "!r:hs",
                    "event_id": "$start:hs"
                }),
            ),
            (
                Event::UpdateReadReceipts {
                    profile: "main".into(),
                    room_id: "!r:hs".into(),
                    receipts: vec![
                        ReceiptEntry {
                            user_id: "@a:hs".into(),
                            user_name: Some("Alice".into()),
                            event_id: "$e2:hs".into(),
                            ts: 1737043200005u64,
                            target_ts: Some(1737043200000u64),
                        },
                        ReceiptEntry {
                            user_id: "@b:hs".into(),
                            user_name: None,
                            event_id: "$e:hs".into(),
                            ts: 1737043200001u64,
                            target_ts: None,
                        },
                    ],
                },
                json!({
                    "@type": "updateReadReceipts", "profile": "main", "room_id": "!r:hs",
                    "receipts": [
                        {"user_id": "@a:hs", "user_name": "Alice",
                         "event_id": "$e2:hs", "ts": 1737043200005u64,
                         "target_ts": 1737043200000u64},
                        {"user_id": "@b:hs", "event_id": "$e:hs", "ts": 1737043200001u64}
                    ]
                }),
            ),
            (
                Event::UpdateReadReceipts {
                    profile: "main".into(),
                    room_id: "!r:hs".into(),
                    receipts: vec![],
                },
                json!({
                    "@type": "updateReadReceipts", "profile": "main", "room_id": "!r:hs",
                    "receipts": []
                }),
            ),
            (
                Event::UpdateRoomMembers {
                    profile: "main".into(),
                    room_id: "!r:hs".into(),
                    members: vec![
                        MemberEntry {
                            user_id: "@a:hs".into(),
                            display_name: Some("Alice".into()),
                        },
                        MemberEntry {
                            user_id: "@b:hs".into(),
                            display_name: None,
                        },
                    ],
                },
                json!({
                    "@type": "updateRoomMembers", "profile": "main", "room_id": "!r:hs",
                    "members": [
                        {"user_id": "@a:hs", "display_name": "Alice"},
                        {"user_id": "@b:hs"}
                    ]
                }),
            ),
            (
                Event::UpdateRoomMessages {
                    profile: "main".into(),
                    room_id: "!r:hs".into(),
                    end: Some("tok_1".into()),
                    messages: vec![message],
                },
                json!({
                    "@type": "updateRoomMessages", "profile": "main",
                    "room_id": "!r:hs", "end": "tok_1",
                    "messages": [{
                        "event_id": "$e:hs", "sender": "@a:hs", "sender_name": "Alice",
                        "sender_avatar": "mxc://hs/av1", "sender_trust": "verified",
                        "body": "pic.png", "ts": 1737043200000u64, "msgtype": "m.image",
                        "is_own": false,
                        "media": {
                            "source": {"url": "mxc://hs/abc"},
                            "thumb_source": {"url": "mxc://hs/thumb"},
                            "mimetype": "image/png", "filename": "pic.png",
                            "size": 64000, "duration": 1500,
                            "width": 640, "height": 480
                        }
                    }]
                }),
            ),
            (
                Event::UpdateRoomMessages {
                    profile: "main".into(),
                    room_id: "!r:hs".into(),
                    end: None,
                    messages: vec![MessageEntry {
                        event_id: "$e2:hs".into(),
                        sender: "@b:hs".into(),
                        sender_name: None,
                        sender_avatar: None,
                        sender_trust: None,
                        body: "re: pic (edited body)".into(),
                        formatted_body: Some("<em>re: pic</em> (edited body)".into()),
                        ts: 1737043200001u64,
                        msgtype: "m.text".into(),
                        is_own: false,
                        media: None,
                        reply_to: Some("$e:hs".into()),
                        thread_root: None,
                        edited: Some(1737043200009u64),
                        redacted: None,
                        reactions: Some(vec![ReactionEntry {
                            key: "👍".into(),
                            count: 3,
                            own: false,
                        }]),
                        geo: None,
                        mentions: None,
                        poll: None,
                    }],
                },
                json!({
                    "@type": "updateRoomMessages", "profile": "main",
                    "room_id": "!r:hs",
                    "messages": [{
                        "event_id": "$e2:hs", "sender": "@b:hs",
                        "body": "re: pic (edited body)",
                        "formatted_body": "<em>re: pic</em> (edited body)",
                        "ts": 1737043200001u64, "msgtype": "m.text",
                        "is_own": false, "reply_to": "$e:hs", "edited": 1737043200009u64,
                        "reactions": [{"key": "👍", "count": 3, "own": false}]
                    }]
                }),
            ),
            (
                Event::UpdateRoomMessages {
                    profile: "main".into(),
                    room_id: "!r:hs".into(),
                    end: None,
                    messages: vec![MessageEntry {
                        event_id: "$gone:hs".into(),
                        sender: "@b:hs".into(),
                        sender_name: Some("Bob".into()),
                        sender_avatar: None,
                        sender_trust: None,
                        body: String::new(),
                        formatted_body: None,
                        ts: 1737043200002u64,
                        msgtype: "m.text".into(),
                        is_own: false,
                        media: None,
                        reply_to: None,
                        thread_root: None,
                        edited: None,
                        redacted: Some(true),
                        reactions: None,
                        geo: None,
                        mentions: None,
                        poll: None,
                    }],
                },
                json!({
                    "@type": "updateRoomMessages", "profile": "main",
                    "room_id": "!r:hs",
                    "messages": [{
                        "event_id": "$gone:hs", "sender": "@b:hs", "sender_name": "Bob",
                        "body": "", "ts": 1737043200002u64, "msgtype": "m.text",
                        "is_own": false, "redacted": true
                    }]
                }),
            ),
            (
                Event::UpdateThreadMessages {
                    profile: "main".into(),
                    room_id: "!r:hs".into(),
                    thread_root: "$root:hs".into(),
                    root: Some(MessageEntry {
                        event_id: "$root:hs".into(),
                        sender: "@a:hs".into(),
                        sender_name: Some("Alice".into()),
                        sender_avatar: None,
                        sender_trust: None,
                        body: "thread root".into(),
                        formatted_body: None,
                        ts: 1737043200000u64,
                        msgtype: "m.text".into(),
                        is_own: false,
                        media: None,
                        reply_to: None,
                        thread_root: None,
                        edited: None,
                        redacted: None,
                        reactions: None,
                        geo: None,
                        mentions: None,
                        poll: None,
                    }),
                    end: Some("tok_t1".into()),
                    messages: vec![MessageEntry {
                        event_id: "$tr1:hs".into(),
                        sender: "@b:hs".into(),
                        sender_name: None,
                        sender_avatar: None,
                        sender_trust: None,
                        body: "thread reply".into(),
                        formatted_body: None,
                        ts: 1737043200003u64,
                        msgtype: "m.text".into(),
                        is_own: false,
                        media: None,
                        reply_to: None,
                        thread_root: Some("$root:hs".into()),
                        edited: None,
                        redacted: None,
                        reactions: None,
                        geo: None,
                        mentions: None,
                        poll: None,
                    }],
                },
                json!({
                    "@type": "updateThreadMessages", "profile": "main",
                    "room_id": "!r:hs", "thread_root": "$root:hs",
                    "root": {
                        "event_id": "$root:hs", "sender": "@a:hs",
                        "sender_name": "Alice", "body": "thread root",
                        "ts": 1737043200000u64, "msgtype": "m.text", "is_own": false
                    },
                    "end": "tok_t1",
                    "messages": [{
                        "event_id": "$tr1:hs", "sender": "@b:hs",
                        "body": "thread reply", "ts": 1737043200003u64,
                        "msgtype": "m.text", "is_own": false,
                        "thread_root": "$root:hs"
                    }]
                }),
            ),
            (
                Event::UpdateEdited {
                    profile: "main".into(),
                    room_id: "!r:hs".into(),
                    event_id: "$e:hs".into(),
                    body: "fixed typo".into(),
                    formatted_body: Some("<strong>fixed typo</strong>".into()),
                    msgtype: "m.text".into(),
                    media: None,
                    geo: None,
                    source_event_id: Some("$ed:hs".into()),
                    edited_ts: 1737043200009u64,
                },
                json!({
                    "@type": "updateEdited", "profile": "main", "room_id": "!r:hs",
                    "event_id": "$e:hs", "body": "fixed typo",
                    "formatted_body": "<strong>fixed typo</strong>", "msgtype": "m.text",
                    "source_event_id": "$ed:hs", "edited_ts": 1737043200009u64
                }),
            ),
            (
                Event::UpdateMessageRedacted {
                    profile: "main".into(),
                    room_id: "!r:hs".into(),
                    event_id: "$e:hs".into(),
                },
                json!({
                    "@type": "updateMessageRedacted", "profile": "main",
                    "room_id": "!r:hs", "event_id": "$e:hs"
                }),
            ),
            (
                Event::UpdateSendResult {
                    room_id: "!r:hs".into(),
                    event_id: Some("$e:hs".into()),
                },
                json!({"@type": "updateSendResult", "room_id": "!r:hs", "event_id": "$e:hs"}),
            ),
            (
                Event::UpdateRoomKeys {
                    profile: "main".into(),
                    room_id: "!r:hs".into(),
                },
                json!({"@type": "updateRoomKeys", "profile": "main", "room_id": "!r:hs"}),
            ),
            (
                Event::UpdateMediaFile {
                    path: "/cache/media/file/hs_abc.mp4".into(),
                    complete: true,
                    size: Some(1024u64),
                },
                json!({
                    "@type": "updateMediaFile", "path": "/cache/media/file/hs_abc.mp4",
                    "complete": true, "size": 1024
                }),
            ),
            (
                Event::UpdateMediaFile {
                    path: "/cache/media/file/hs_abc".into(),
                    complete: false,
                    size: None,
                },
                json!({"@type": "updateMediaFile", "path": "/cache/media/file/hs_abc", "complete": false}),
            ),
            (
                Event::UpdateDownload {
                    source: json!({"url": "mxc://hs/abc"}),
                    format: "file".into(),
                    state: "downloading".into(),
                    size: None,
                    error: None,
                },
                json!({
                    "@type": "updateDownload", "source": {"url": "mxc://hs/abc"},
                    "format": "file", "state": "downloading"
                }),
            ),
            (
                Event::UpdateDownload {
                    source: json!({"url": "mxc://hs/abc"}),
                    format: "file".into(),
                    state: "error".into(),
                    size: None,
                    error: Some("boom".into()),
                },
                json!({
                    "@type": "updateDownload", "source": {"url": "mxc://hs/abc"},
                    "format": "file", "state": "error", "error": "boom"
                }),
            ),
            // The greeting: serialize against the live constants, and
            // parse a literal, so a future version bump fails both ways
            // unless the golden here is consciously updated.
            (
                Event::DaemonInfo {
                    protocol: PROTOCOL_VERSION,
                    release: RELEASE_VERSION.into(),
                },
                json!({
                    "@type": "daemonInfo", "protocol": 23,
                    "release": env!("CARGO_PKG_VERSION")
                }),
            ),
        ];
        for (ev, golden) in cases {
            let wire =
                serde_json::to_value(&ev).unwrap_or_else(|e| panic!("serialize {ev:?}: {e}"));
            assert_eq!(wire, golden, "serialize {ev:?}");
            assert_eq!(
                serde_json::from_value::<Event>(golden)
                    .unwrap_or_else(|e| panic!("parse {ev:?}: {e}")),
                ev,
                "parse {ev:?}"
            );
        }
    }

    /// The request-correlation envelope: how `@req`/`@ok`/`@error` wrap the
    /// event payload, for terminal responses, bare acks, and pure
    /// notifications.
    #[test]
    fn out_event_envelope() {
        let response = OutEvent::response(
            Some(7),
            Event::UpdateRoomKeys {
                profile: "main".into(),
                room_id: "!r:hs".into(),
            },
        );
        assert_eq!(
            response.to_json(),
            json!({"@type": "updateRoomKeys", "profile": "main", "room_id": "!r:hs", "@req": 7, "@ok": true})
        );

        let ack = OutEvent::ack(Some(3), false, Some("boom".into()));
        assert_eq!(
            ack.to_json(),
            json!({"@req": 3, "@ok": false, "@error": "boom"})
        );
    }

    /// Pin one full frame to bytes: key ordering of what actually goes on the
    /// wire (serde_json sorts object keys) must not surprise the reader.
    #[test]
    fn framed_payload_exact_bytes() {
        let out = OutEvent::response(
            Some(42),
            Event::UpdateRoomKeys {
                profile: "main".into(),
                room_id: "!r:hs".into(),
            },
        );
        assert_eq!(
            out.to_json().to_string(),
            r#"{"@ok":true,"@req":42,"@type":"updateRoomKeys","profile":"main","room_id":"!r:hs"}"#
        );
    }

    /// `MediaEntry.source` carries a serialized ruma `MediaSource`.  Emacs
    /// stores it opaquely and may hand back records from an older daemon, so
    /// ruma's serde shape is part of the wire contract: plain and encrypted
    /// sources must round-trip unchanged through the current ruma.
    #[test]
    fn media_source_wire_shapes() {
        use matrix_sdk::ruma::events::room::MediaSource;

        let plain = json!({"url": "mxc://example.org/abc"});
        let parsed: MediaSource = serde_json::from_value(plain.clone()).unwrap();
        assert_eq!(serde_json::to_value(&parsed).unwrap(), plain);

        // Full encrypted-file shape as shipped in e2e rooms (and as old
        // emacs-side room records may still carry).  ruma validates base64
        // lengths on deserialize: key/sha256 are 32 bytes (43 unpadded
        // chars), the AES-CTR iv is 16 bytes (22 chars).
        let encrypted = json!({
            "file": {
                "url": "mxc://example.org/enc",
                "key": {
                    "kty": "oct",
                    "key_ops": ["decrypt", "encrypt"],
                    "alg": "A256CTR",
                    "ext": true,
                    "k": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                },
                "iv": "AAAAAAAAAAAAAAAAAAAAAA",
                "hashes": {"sha256": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"},
                "v": "v2"
            }
        });
        let parsed: MediaSource = serde_json::from_value(encrypted.clone()).unwrap();
        assert_eq!(serde_json::to_value(&parsed).unwrap(), encrypted);
    }
}
