use super::*;
use matrix_sdk::ruma::events::relation::Thread;
use matrix_sdk::ruma::{OwnedEventId, OwnedRoomId};

fn event_id(s: &str) -> OwnedEventId {
    matrix_sdk::ruma::EventId::parse(s).unwrap()
}

fn room_id(s: &str) -> OwnedRoomId {
    matrix_sdk::ruma::RoomId::parse(s).unwrap()
}

#[test]
fn pin_toggle_toggles_by_membership() {
    let base = vec!["$a:hs".to_owned(), "$b:hs".to_owned()];
    // Pinning a new id appends it; order is kept.
    assert_eq!(
        pin_toggle(&base, "$c:hs", false),
        Some(vec![
            "$a:hs".to_owned(),
            "$b:hs".to_owned(),
            "$c:hs".to_owned()
        ])
    );
    // Pinning an already-pinned id changes nothing.
    assert_eq!(pin_toggle(&base, "$a:hs", false), None);
    // Unpinning removes; unpinning something absent changes nothing.
    assert_eq!(
        pin_toggle(&base, "$a:hs", true),
        Some(vec!["$b:hs".to_owned()])
    );
    assert_eq!(pin_toggle(&base, "$z:hs", true), None);
    // The empty list pins and rejects unpins like any other.
    assert_eq!(
        pin_toggle(&[], "$a:hs", false),
        Some(vec!["$a:hs".to_owned()])
    );
    assert_eq!(pin_toggle(&[], "$a:hs", true), None);
}

#[test]
fn pinned_from_state_reads_the_content_array() {
    let events = vec![
        serde_json::json!({"content": {"pinned": ["$a:hs", "$b:hs"]}}),
        // A second state value (a later write) and dupes across them.
        serde_json::json!({"content": {"pinned": ["$b:hs"]}}),
        // Unset content and non-string entries pass through quietly.
        serde_json::json!({"content": {}}),
        serde_json::json!({"content": {"pinned": [3]}}),
    ];
    assert_eq!(
        pinned_from_state(&events),
        vec!["$a:hs".to_owned(), "$b:hs".to_owned()]
    );
    assert_eq!(pinned_from_state(&[]), Vec::<String>::new());
}

#[test]
fn key_arrivals_coalesce_to_distinct_rooms() {
    let rooms = coalesce_rooms([
        room_id("!a:hs"),
        room_id("!b:hs"),
        room_id("!a:hs"),
        room_id("!c:hs"),
    ]);
    let names: Vec<&str> = rooms.iter().map(|r| r.as_str()).collect();
    assert_eq!(names, ["!a:hs", "!b:hs", "!c:hs"]);
}

#[test]
fn reactions_merge_is_idempotent() {
    let mut state = ReactionState::new();
    merge_reaction(&mut state, "$t:hs", "👍", "$r1:hs", "@a:hs");
    merge_reaction(&mut state, "$t:hs", "👍", "$r2:hs", "@b:hs");
    // Same reaction event id re-merged (live + backfill overlap).
    merge_reaction(&mut state, "$t:hs", "👍", "$r1:hs", "@a:hs");

    let entries = reaction_entries(&state, "$t:hs", "@a:hs");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].key, "👍");
    assert_eq!(entries[0].count, 2);
    assert!(entries[0].own);

    let entries = reaction_entries(&state, "$t:hs", "@c:hs");
    assert!(!entries[0].own);

    assert!(reaction_entries(&state, "$other:hs", "@a:hs").is_empty());
}

#[test]
fn reactions_remove_prunes_empty_keys() {
    let mut state = ReactionState::new();
    merge_reaction(&mut state, "$t:hs", "👍", "$r1:hs", "@a:hs");
    merge_reaction(&mut state, "$t:hs", "❤", "$r2:hs", "@a:hs");
    merge_reaction(&mut state, "$other:hs", "👍", "$r3:hs", "@a:hs");

    // Not a tracked reaction: redacted message, say.
    assert_eq!(remove_reaction(&mut state, "$nope:hs"), None);

    assert_eq!(
        remove_reaction(&mut state, "$r1:hs").as_deref(),
        Some("$t:hs")
    );
    let entries = reaction_entries(&state, "$t:hs", "@a:hs");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].key, "❤");

    assert_eq!(
        remove_reaction(&mut state, "$r2:hs").as_deref(),
        Some("$t:hs")
    );
    // Target fully pruned, other targets untouched.
    assert!(!state.contains_key("$t:hs"));
    assert!(state.contains_key("$other:hs"));
    assert!(reaction_entries(&state, "$t:hs", "@a:hs").is_empty());
}

#[test]
fn receipts_merge_newest_wins() {
    let mut map: HashMap<String, ReceiptPos> = HashMap::new();
    assert!(merge_receipt(
        &mut map,
        "@a:hs",
        ReceiptPos {
            event_id: "$e1:hs".into(),
            ts: 100
        }
    ));
    // Older receipt for the same user (sync replay): no change.
    assert!(!merge_receipt(
        &mut map,
        "@a:hs",
        ReceiptPos {
            event_id: "$e0:hs".into(),
            ts: 50
        }
    ));
    // Same ts, same state: no change either.
    assert!(!merge_receipt(
        &mut map,
        "@a:hs",
        ReceiptPos {
            event_id: "$e1:hs".into(),
            ts: 100
        }
    ));
    // Newer receipt moves the user on.
    assert!(merge_receipt(
        &mut map,
        "@a:hs",
        ReceiptPos {
            event_id: "$e2:hs".into(),
            ts: 200
        }
    ));
    assert!(merge_receipt(
        &mut map,
        "@b:hs",
        ReceiptPos {
            event_id: "$e1:hs".into(),
            ts: 100
        }
    ));

    assert_eq!(map["@a:hs"].event_id, "$e2:hs");
    assert_eq!(map["@a:hs"].ts, 200);
    assert_eq!(map["@b:hs"].event_id, "$e1:hs");
    assert_eq!(map.len(), 2);
}

#[test]
fn own_receipt_pos_takes_the_latest_of_the_block() {
    let mut event_ts = HashMap::new();
    event_ts.insert("$pub:hs".to_owned(), 100);
    event_ts.insert("$priv:hs".to_owned(), 200);

    let ts = |id| Some(id);
    // Private older, public later: the public one wins regardless
    // of delivery or iteration order.
    let pos = own_receipt_pos(
        vec![
            ("$pub:hs".to_owned(), ts(100)),
            ("$priv:hs".to_owned(), ts(50)),
        ],
        &event_ts,
    );
    assert_eq!(pos.unwrap().0, "$pub:hs");
    // Private later: it wins.
    let pos = own_receipt_pos(
        vec![
            ("$pub:hs".to_owned(), ts(100)),
            ("$priv:hs".to_owned(), ts(300)),
        ],
        &event_ts,
    );
    assert_eq!(pos.unwrap().0, "$priv:hs");
    // Two own receipts on one kind — a batched sync can carry
    // several — with the winner's ts coming from the map either
    // way the pool is ordered (the old per-variable last-wins
    // moved the marker backwards for exactly this shape).
    event_ts.insert("$later:hs".to_owned(), 300);
    event_ts.insert("$earlier:hs".to_owned(), 200);
    let pos = own_receipt_pos(
        vec![
            ("$later:hs".to_owned(), None),
            ("$earlier:hs".to_owned(), None),
        ],
        &event_ts,
    );
    assert_eq!(pos.unwrap().0, "$later:hs");
    let pos = own_receipt_pos(
        vec![
            ("$earlier:hs".to_owned(), None),
            ("$later:hs".to_owned(), None),
        ],
        &event_ts,
    );
    assert_eq!(pos.unwrap().0, "$later:hs");
    // No receipt ts either side: positions come from the map.
    let pos = own_receipt_pos(
        vec![("$pub:hs".to_owned(), None), ("$priv:hs".to_owned(), None)],
        &event_ts,
    );
    assert_eq!(pos.unwrap().0, "$priv:hs");
    // A single receipt stands on its own; an empty block is none.
    assert_eq!(
        own_receipt_pos(vec![("$e:hs".to_owned(), None)], &event_ts)
            .unwrap()
            .0,
        "$e:hs"
    );
    assert_eq!(own_receipt_pos(Vec::new(), &event_ts), None);
}

#[test]
fn receipt_ts_falls_back_to_event_ts() {
    let mut event_ts = HashMap::new();
    event_ts.insert("$e:hs".to_string(), 42);
    // A timed receipt orders by its own read time.
    assert_eq!(receipt_ts(Some(7), &event_ts, "$e:hs"), 7);
    // A ts-less receipt orders by the targeted event's timestamp.
    assert_eq!(receipt_ts(None, &event_ts, "$e:hs"), 42);
    // Unknown event: 0, which never displaces a timed receipt.
    assert_eq!(receipt_ts(None, &event_ts, "$x:hs"), 0);
}

#[test]
fn prune_keeps_newest_half_over_cap() {
    let mut edits = EditState::new();
    for i in 0..MAX_TRACKED {
        edits.insert(format!("$old{i}:hs"), edit_info("x", i as u64));
    }
    // Over the cap: the newest insertion and one more.
    edits.insert("$new:hs".into(), edit_info("new", MAX_TRACKED as u64));
    prune_edits(&mut edits);
    assert!(edits.len() <= MAX_TRACKED);
    assert!(edits.contains_key("$new:hs"));
    assert!(edits.contains_key("$old400:hs"));
    assert!(!edits.contains_key("$old0:hs"));

    let mut receipts: HashMap<String, ReceiptPos> = HashMap::new();
    for i in 0..MAX_TRACKED + 1 {
        receipts.insert(
            format!("@u{i}:hs"),
            ReceiptPos {
                event_id: "$e:hs".into(),
                ts: i as u64,
            },
        );
    }
    prune_receipts(&mut receipts);
    assert!(receipts.len() <= MAX_TRACKED);
    assert!(receipts.contains_key("@u400:hs"));
    assert!(!receipts.contains_key("@u0:hs"));

    // Reaction targets with unknown timestamps go first.
    let mut event_ts: HashMap<String, u64> = HashMap::new();
    let mut reactions = ReactionState::new();
    for i in 0..MAX_TRACKED + 1 {
        let target = format!("$t{i}:hs");
        let mut inner: HashMap<String, String> = HashMap::new();
        inner.insert(format!("$r{i}:hs"), "@a:hs".into());
        let mut key: HashMap<String, HashMap<String, String>> = HashMap::new();
        key.insert("👍".into(), inner);
        reactions.insert(target, key);
        if i > 100 {
            event_ts.insert(format!("$r{i}:hs"), i as u64);
        }
    }
    prune_reactions(&mut reactions, &event_ts);
    assert!(reactions.len() <= MAX_TRACKED);
    assert!(!reactions.contains_key("$t0:hs"));
    assert!(reactions.contains_key("$t400:hs"));
}

#[test]
fn event_ts_cache_is_bounded_and_updates_in_place() {
    let mut map: HashMap<String, u64> = HashMap::new();
    for i in 0..1024 {
        note_event_ts(&mut map, &format!("$e{i}:hs"), i as u64);
    }
    assert_eq!(map.len(), 1024);
    // Re-noting an existing id neither grows the map nor evicts.
    note_event_ts(&mut map, "$e5:hs", 5000);
    assert_eq!(map.len(), 1024);
    assert_eq!(map["$e5:hs"], 5000);
    // One more fresh id trips the cap: the newer half is kept.
    note_event_ts(&mut map, "$new:hs", 99999);
    assert_eq!(map.len(), 513);
    assert_eq!(map["$new:hs"], 99999);
    assert!(map.contains_key("$e5:hs"));
    assert!(!map.contains_key("$e0:hs"));
}

#[test]
fn reply_target_relations() {
    let mut content =
        matrix_sdk::ruma::events::room::message::RoomMessageEventContent::text_plain("hi");
    assert_eq!(reply_target(&content), None);

    content.relates_to = Some(Relation::Reply(Reply::with_event_id(event_id("$p:hs"))));
    assert_eq!(reply_target(&content).as_deref(), Some("$p:hs"));

    // Threaded reply: genuine in_reply_to.
    content.relates_to = Some(Relation::Thread(Thread::reply(
        event_id("$root:hs"),
        event_id("$p:hs"),
    )));
    assert_eq!(reply_target(&content).as_deref(), Some("$p:hs"));

    // Thread fallback (is_falling_back): not a reply.
    content.relates_to = Some(Relation::Thread(Thread::plain(
        event_id("$root:hs"),
        event_id("$latest:hs"),
    )));
    assert_eq!(reply_target(&content), None);

    // Thread without any in_reply_to at all.
    content.relates_to = Some(Relation::Thread(Thread::without_fallback(event_id(
        "$root:hs",
    ))));
    assert_eq!(reply_target(&content), None);

    // The generalized form reads a sticker's relation type the same
    // way (Element can send a sticker as a reply).
    use matrix_sdk::ruma::events::sticker::StickerEventContent;
    let mut sticker = StickerEventContent::new(
        "cat".to_string(),
        Default::default(),
        "mxc://hs/sticker".into(),
    );
    assert_eq!(reply_target_of(&sticker.relates_to), None);
    sticker.relates_to = Some(Relation::Reply(Reply::with_event_id(event_id("$p:hs"))));
    assert_eq!(
        reply_target_of(&sticker.relates_to).as_deref(),
        Some("$p:hs")
    );
}

#[test]
fn threads_fold() {
    let mut threads = ThreadState::new();
    let mut thread_of = ThreadOf::new();

    // A reply names its root and registers itself.
    merge_thread(&mut threads, &mut thread_of, "$root:hs", "$r1:hs", 100);
    assert_eq!(thread_of["$r1:hs"], "$root:hs");
    assert_eq!(
        threads["$root:hs"].latest_event_id.as_deref(),
        Some("$r1:hs")
    );
    assert_eq!(threads["$root:hs"].latest_ts, Some(100));

    // A root registering itself just makes the fold entry exist.
    merge_thread(&mut threads, &mut thread_of, "$root2:hs", "$root2:hs", 5);
    assert_eq!(
        threads["$root2:hs"].latest_event_id.as_deref(),
        Some("$root2:hs")
    );

    // Older arrivals (backfill after live) register the member but
    // never move the latest.
    merge_thread(&mut threads, &mut thread_of, "$root:hs", "$r0:hs", 50);
    assert_eq!(
        threads["$root:hs"].latest_event_id.as_deref(),
        Some("$r1:hs")
    );
    assert_eq!(thread_of["$r0:hs"], "$root:hs");

    // Newer arrival advances.
    merge_thread(&mut threads, &mut thread_of, "$root:hs", "$r2:hs", 200);
    assert_eq!(
        threads["$root:hs"].latest_event_id.as_deref(),
        Some("$r2:hs")
    );
    // Equal ts re-merges (live + backfill overlap) — harmless.
    merge_thread(&mut threads, &mut thread_of, "$root:hs", "$r2:hs", 200);
    assert_eq!(
        threads["$root:hs"].latest_event_id.as_deref(),
        Some("$r2:hs")
    );

    // Threads are independent.
    merge_thread(&mut threads, &mut thread_of, "$root2:hs", "$r3:hs", 10);
    assert_eq!(
        threads["$root2:hs"].latest_event_id.as_deref(),
        Some("$r3:hs")
    );
    assert_eq!(
        threads["$root:hs"].latest_event_id.as_deref(),
        Some("$r2:hs")
    );

    // Thread relations: both shapes name the root, only the
    // genuine reply carries a reply leg.
    let mut content =
        matrix_sdk::ruma::events::room::message::RoomMessageEventContent::text_plain("in");
    content.relates_to = Some(Relation::Thread(Thread::reply(
        event_id("$root:hs"),
        event_id("$p:hs"),
    )));
    assert_eq!(
        thread_rel(&content),
        Some(("$root:hs".to_string(), Some("$p:hs".to_string())))
    );
    content.relates_to = Some(Relation::Thread(Thread::plain(
        event_id("$root:hs"),
        event_id("$latest:hs"),
    )));
    assert_eq!(thread_rel(&content), Some(("$root:hs".to_string(), None)));
    content.relates_to = None;
    assert_eq!(thread_rel(&content), None);
}

#[test]
fn thread_relation_for_shapes() {
    // Plain send, fold has the latest: the fallback names it.
    let rel = thread_relation_for(&event_id("$root:hs"), None, Some(&event_id("$r4:hs")));
    match rel {
        Relation::Thread(t) => {
            assert_eq!(t.event_id.as_str(), "$root:hs");
            assert_eq!(t.in_reply_to.as_ref().unwrap().event_id.as_str(), "$r4:hs");
            assert!(t.is_falling_back);
        }
        _ => panic!("expected a thread relation"),
    }

    // Plain send whose fold latest IS the root: the root stands
    // in for itself.
    let rel = thread_relation_for(&event_id("$root:hs"), None, Some(&event_id("$root:hs")));
    match rel {
        Relation::Thread(t) => {
            assert_eq!(
                t.in_reply_to.as_ref().unwrap().event_id.as_str(),
                "$root:hs"
            );
            assert!(t.is_falling_back);
        }
        _ => panic!("expected a thread relation"),
    }

    // Plain send with an empty fold (cold session): the root is
    // the fallback; servers accept this shape.
    let rel = thread_relation_for(&event_id("$root:hs"), None, None);
    match rel {
        Relation::Thread(t) => {
            assert_eq!(
                t.in_reply_to.as_ref().unwrap().event_id.as_str(),
                "$root:hs"
            );
            assert!(t.is_falling_back);
        }
        _ => panic!("expected a thread relation"),
    }

    // Genuine in-thread reply: reply leg kept, fallback off.
    let rel = thread_relation_for(
        &event_id("$root:hs"),
        Some(&event_id("$p:hs")),
        Some(&event_id("$r4:hs")),
    );
    match rel {
        Relation::Thread(t) => {
            assert_eq!(t.in_reply_to.as_ref().unwrap().event_id.as_str(), "$p:hs");
            assert!(!t.is_falling_back);
        }
        _ => panic!("expected a thread relation"),
    }
}

// The createRoom initial_state entry must serialize as a complete
// state event: Synapse reads val["content"] (KeyError 500 on the
// bare-content form it used to be).
#[test]
fn create_room_encryption_state_is_a_full_event() {
    let json: serde_json::Value = encryption_initial_state().deserialize_as().unwrap();
    assert_eq!(json["type"], "m.room.encryption");
    assert_eq!(json["content"]["algorithm"], "m.megolm.v1.aes-sha2");
    assert_eq!(json["state_key"], "");
}

#[test]
fn threads_bundle_seeding() {
    // A bundle on the root: no relation on the event (roots never
    // carry one), the rides-alone arm names it.
    let root_page = serde_json::json!({
        "content": {"body": "root", "msgtype": "m.text"},
        "unsigned": {"m.relations": {"m.thread": {"latest_event": {
            "event_id": "$r3:hs", "origin_server_ts": 300,
        }}}}
    });
    assert_eq!(
        thread_bundle_of(&root_page),
        Some(("$r3:hs".to_string(), 300))
    );
    assert_eq!(thread_root_of_json(&root_page["content"]), None);

    // A bundle on a reply; the reply's relation names the root.
    let reply_page = serde_json::json!({
        "content": {"m.relates_to": {
            "rel_type": "m.thread", "event_id": "$root:hs",
            "m.in_reply_to": {"event_id": "$root:hs"}, "is_falling_back": true,
        }},
        "unsigned": {"m.relations": {"m.thread": {"latest_event": {
            "event_id": "$r4:hs", "origin_server_ts": 400,
        }}}}
    });
    assert_eq!(
        thread_root_of_json(&reply_page["content"]).as_deref(),
        Some("$root:hs")
    );

    let mut threads = ThreadState::new();
    let mut thread_of = ThreadOf::new();
    // Seed pattern: the bundle names a latest the fold is missing.
    merge_thread(&mut threads, &mut thread_of, "$root:hs", "$r3:hs", 300);
    assert_eq!(
        threads["$root:hs"].latest_event_id.as_deref(),
        Some("$r3:hs")
    );

    // Live data seen since the page was fetched stays ahead; the
    // older bundle re-merge never clobbers it.
    merge_thread(&mut threads, &mut thread_of, "$root:hs", "$r4:hs", 400);
    merge_thread(&mut threads, &mut thread_of, "$root:hs", "$r3:hs", 300);
    assert_eq!(
        threads["$root:hs"].latest_event_id.as_deref(),
        Some("$r4:hs")
    );

    // Non-thread and opaque content carry nothing.
    assert_eq!(thread_bundle_of(&serde_json::json!({"content": {}})), None);
    assert_eq!(
        thread_root_of_json(&serde_json::json!({
            "m.relates_to": {"rel_type": "m.replace", "event_id": "$orig:hs"}
        })),
        None,
        "an edit replaces, it does not thread"
    );
}

#[test]
fn chunk_folds_project_into_the_snapshots() {
    // The render pass projects the RETURNED snapshots, not the
    // room locals: a fold that merges but returns fresh empty
    // maps renders every fetched page without the folded state
    // (the regression the 932ac03 split introduced — its tail
    // returned the empty head locals).  This pins the apply pass
    // and its snapshot-clone tail.
    let mut local = RoomLocal::default();
    let folds = ChunkFolds {
        notes: vec![("$t:hs".to_owned(), 100)],
        merges: vec![(
            "$t:hs".to_owned(),
            "👍".to_owned(),
            "$r1:hs".to_owned(),
            "@a:hs".to_owned(),
        )],
        removes: Vec::new(),
        edits: vec![(
            "$t:hs".to_owned(),
            EditInfo {
                msgtype: "m.text".to_owned(),
                body: "edited body".to_owned(),
                formatted_body: None,
                media: None,
                geo: None,
                mentions: None,
                ts: 200,
            },
        )],
        poll_starts: Vec::new(),
        poll_responses: Vec::new(),
        poll_ends: Vec::new(),
        thread_merges: Vec::new(),
        thread_bundles: Vec::new(),
    };
    let (reactions, edits, _polls) = apply_chunk_folds(&mut local, folds);
    // The snapshot the render pass reads.
    let agg = reaction_entries(&reactions, "$t:hs", "@a:hs");
    assert_eq!(agg.len(), 1);
    assert_eq!(agg[0].key, "👍");
    assert!(agg[0].own);
    assert_eq!(
        edits.get("$t:hs").map(|e| e.body.as_str()),
        Some("edited body")
    );
    assert_eq!(edits.get("$t:hs").map(|e| e.ts), Some(200));
    // And the room local itself, the persistent state.
    assert_eq!(local.event_ts.get("$t:hs"), Some(&100));
    assert!(local.edits.contains_key("$t:hs"));
}

#[test]
fn chunk_folds_collect_bundles_from_the_top_level_unsigned() {
    // thread_bundle_of reads the FULL event JSON: the bundled
    // summary rides the top-level `unsigned`, a sibling of
    // `content`.  Feeding the content object alone (the pre-fix
    // call shape) never matched — bundle seeding was silently
    // dead in production while the bare-helper test passed.
    let raw = serde_json::json!({
        "type": "m.room.message",
        "event_id": "$root:hs",
        "sender": "@a:hs",
        "origin_server_ts": 300,
        "content": {"body": "root", "msgtype": "m.text"},
        "unsigned": {"m.relations": {"m.thread": {"latest_event": {
            "event_id": "$r3:hs", "origin_server_ts": 300,
        }, "count": 1, "current_user_participated": true}}}
    });
    let raw_str = raw.to_string();
    let parsed = vec![serde_json::from_str::<AnySyncTimelineEvent>(&raw_str).ok()];
    let contents = vec![raw.get("content").cloned().unwrap()];
    let folds = collect_chunk_folds(&parsed, &contents, std::slice::from_ref(&raw));
    // No relation on the event, so the bundle's rides-alone arm
    // seeds the event itself as the root.
    assert_eq!(
        folds.thread_bundles,
        vec![("$root:hs".to_owned(), "$r3:hs".to_owned(), 300)]
    );
    assert!(folds.thread_merges.is_empty());

    // The pre-fix shape — the content object standing in for the
    // event — collects nothing.
    let content_only = raw["content"].clone();
    let folds = collect_chunk_folds(&parsed, &contents, std::slice::from_ref(&content_only));
    assert!(folds.thread_bundles.is_empty());
}

#[test]
fn threads_redaction_drops() {
    let mut threads = ThreadState::new();
    let mut thread_of = ThreadOf::new();
    merge_thread(&mut threads, &mut thread_of, "$root:hs", "$r0:hs", 100);
    merge_thread(&mut threads, &mut thread_of, "$root:hs", "$r1:hs", 200);

    // Redacting an old reply keeps the fold.
    unmerge_thread(&mut threads, &mut thread_of, "$r0:hs");
    assert_eq!(
        threads["$root:hs"].latest_event_id.as_deref(),
        Some("$r1:hs")
    );
    assert_eq!(thread_of["$r1:hs"], "$root:hs");

    // Redacting the latest drops the fold entry — the next page's
    // bundle re-seeds it.  The other reply's lookup stays valid
    // but keys into nothing (reads inert).
    unmerge_thread(&mut threads, &mut thread_of, "$r1:hs");
    assert!(!threads.contains_key("$root:hs"));

    // A redacted root member event is inert; roots never sit in
    // thread_of, and their fold survives redactions.
    merge_thread(&mut threads, &mut thread_of, "$root2:hs", "$r2:hs", 10);
    unmerge_thread(&mut threads, &mut thread_of, "$root2:hs");
    assert!(threads.contains_key("$root2:hs"));
    assert_eq!(
        threads["$root2:hs"].latest_event_id.as_deref(),
        Some("$r2:hs")
    );

    // Untracked ids leave everything alone.
    unmerge_thread(&mut threads, &mut thread_of, "$nope:hs");
    assert_eq!(threads.len(), 1);
    assert_eq!(thread_of.len(), 1);
}

#[test]
fn mentions_from_skips_dedups_and_flags_room() {
    assert!(mentions_from(&[], false).is_none());
    assert!(
        mentions_from(&["garbage".to_string()], false).is_none(),
        "no parseable id: no block"
    );
    let m = mentions_from(
        &["@a:hs".to_string(), "@a:hs".to_string(), "junk".to_string()],
        false,
    )
    .unwrap();
    assert_eq!(m.user_ids.len(), 1);
    assert!(!m.room);
    // The @room flag alone carries a block, ids or not.
    assert!(mentions_from(&[], false).is_none());
    let room = mentions_from(&[], true).unwrap();
    assert!(room.user_ids.is_empty());
    assert!(room.room);
    let both = mentions_from(&["@a:hs".to_string()], true).unwrap();
    assert_eq!(both.user_ids.len(), 1);
    assert!(both.room);
}

#[test]
fn sticker_display_maps_to_image_media() {
    use matrix_sdk::ruma::events::sticker::StickerEventContent;

    let mut info = matrix_sdk::ruma::events::room::ImageInfo::default();
    info.width = Some(64u32.into());
    info.height = Some(64u32.into());
    info.mimetype = Some("image/png".to_string());
    info.size = Some(4096u32.into());
    let content = StickerEventContent::new("cat".to_string(), info, "mxc://hs/sticker".into());
    let display = sticker_display(&content);
    assert_eq!(display.msgtype, "m.sticker");
    assert_eq!(display.body, "cat");
    assert_eq!(display.formatted_body, None);
    let media = display.media.expect("carries media");
    let source = media.source.get("url").and_then(serde_json::Value::as_str);
    assert_eq!(source, Some("mxc://hs/sticker"));
    assert_eq!(media.width, Some(64));
    assert_eq!(media.height, Some(64));
    assert_eq!(media.mimetype.as_deref(), Some("image/png"));
    assert_eq!(media.size, Some(4096));

    // Empty body (stickers often skip alt text): the display stays
    // empty, the live preview path names the msgtype instead.
    let bare = StickerEventContent::new(String::new(), Default::default(), "mxc://hs/bare".into());
    assert_eq!(sticker_display(&bare).body, "");
}

#[test]
fn bridge_protocol_prefers_displayname() {
    use serde_json::json;

    // Full MSC 2346 content: displayname wins.
    let content = json!({
        "bridgebot": "@bot:hs",
        "protocol": {"id": "telegram", "displayname": "Telegram",
                    "avatar_url": "mxc://hs/tg", "external_url": "https://t.me"},
        "channel": {"id": "@user:telegram"}
    });
    assert_eq!(
        bridge_protocol_from_content(&content).as_deref(),
        Some("Telegram")
    );

    // Legacy or bare content without displayname: fall back to id.
    let content = json!({"protocol": {"id": "gitter"}});
    assert_eq!(
        bridge_protocol_from_content(&content).as_deref(),
        Some("gitter")
    );

    // Empty displayname falls back too.
    let content = json!({"protocol": {"id": "irc", "displayname": ""}});
    assert_eq!(
        bridge_protocol_from_content(&content).as_deref(),
        Some("irc")
    );

    // Empty content object: the bridge is gone.
    assert_eq!(bridge_protocol_from_content(&json!({})), None);
    // No protocol key at all, or non-string garbage: no bridge.
    assert_eq!(
        bridge_protocol_from_content(&json!({"bridgebot": "@bot:hs"})),
        None
    );
    assert_eq!(
        bridge_protocol_from_content(&json!({"protocol": {"id": 42}})),
        None
    );
}

fn edit_info(body: &str, ts: u64) -> EditInfo {
    EditInfo {
        msgtype: "m.text".into(),
        body: body.into(),
        formatted_body: None,
        media: None,
        geo: None,
        mentions: None,
        ts,
    }
}

#[test]
fn edits_merge_latest_wins() {
    let mut state = EditState::new();
    merge_edit(&mut state, "$t:hs", edit_info("v1", 100));
    assert_eq!(state["$t:hs"].body, "v1");

    // Older edit arriving after a newer one (backfill after live):
    // the newer content stays.
    merge_edit(&mut state, "$t:hs", edit_info("v0", 50));
    assert_eq!(state["$t:hs"].body, "v1");
    assert_eq!(state["$t:hs"].ts, 100);

    // Same timestamp re-merged (live + backfill overlap): the ts
    // compare is `<=`, so the re-merge wins — harmless, since an
    // equal-ts event is the same edit carrying the same content.
    merge_edit(&mut state, "$t:hs", edit_info("v1-again", 100));
    assert_eq!(state["$t:hs"].body, "v1-again");
    assert_eq!(state["$t:hs"].ts, 100);

    // Newer edit replaces.
    merge_edit(&mut state, "$t:hs", edit_info("v2", 200));
    assert_eq!(state["$t:hs"].body, "v2");
    assert_eq!(state["$t:hs"].ts, 200);

    // Targets are independent.
    merge_edit(&mut state, "$u:hs", edit_info("other", 1));
    assert_eq!(state["$u:hs"].body, "other");
    assert_eq!(state["$t:hs"].body, "v2");
}

#[test]
fn content_display_covers_all_rendered_types() {
    use matrix_sdk::ruma::events::room::message::{
        ImageMessageEventContent, LocationMessageEventContent, MessageType,
    };
    use matrix_sdk::ruma::events::room::MediaSource;

    let cases: Vec<(&str, MessageType)> = vec![
        ("m.text", MessageType::text_plain(String::from("hello"))),
        ("m.notice", MessageType::notice_plain(String::from("note"))),
        ("m.emote", MessageType::emote_plain(String::from("waves"))),
        ("m.location", {
            let loc = LocationMessageEventContent::new("somewhere".into(), "geo:52,13".into());
            MessageType::Location(loc)
        }),
    ];
    for (want, msgtype) in cases {
        let Some(display) = content_display(&msgtype, None) else {
            panic!("content_display dropped {want}");
        };
        assert_eq!(display.msgtype, want);
        assert!(display.media.is_none());
        assert!(!display.body.is_empty());
    }

    // A media-bearing type ships its MediaEntry.
    let image = MessageType::Image(ImageMessageEventContent::new(
        String::from("pic.png"),
        MediaSource::Plain(<&matrix_sdk::ruma::MxcUri>::from("mxc://hs/abc").to_owned()),
    ));
    let display = content_display(&image, None).expect("image display");
    assert_eq!(display.msgtype, "m.image");
    assert!(display.media.is_some());

    // Unknown content (a custom msgtype from another client) is
    // kept under its real msgtype — nothing a sender sends may
    // silently vanish; Emacs renders a subdued tag.
    let unknown = MessageType::new("m.custom", "x".into(), serde_json::Map::new()).unwrap();
    let display = content_display(&unknown, None).expect("unknown kept");
    assert_eq!(display.msgtype, "m.custom");
    assert_eq!(display.body, "x");
    assert!(display.media.is_none());
}

#[test]
fn mentions_info_reads_the_raw_block() {
    use serde_json::json;

    // User ids and the @room flag, straight from the block — the
    // spec spelling (`m.mentions`, what ruma and real clients ship).
    let with_both = json!({
        "msgtype": "m.text",
        "body": "hi",
        "m.mentions": {"user_ids": ["@a:hs", "@b:hs"], "room": true},
    });
    assert_eq!(
        mentions_info(&with_both),
        Some(Mentions {
            user_ids: vec!["@a:hs".into(), "@b:hs".into()],
            room: true
        })
    );

    // Ids only, room flag absent.
    let ids_only = json!({"m.mentions": {"user_ids": ["@a:hs"]}});
    assert_eq!(
        mentions_info(&ids_only),
        Some(Mentions {
            user_ids: vec!["@a:hs".into()],
            room: false
        })
    );

    // The early `.m.mentions` spelling stays accepted as a fallback.
    let legacy = json!({".m.mentions": {"user_ids": ["@a:hs"]}});
    assert_eq!(
        mentions_info(&legacy),
        Some(Mentions {
            user_ids: vec!["@a:hs".into()],
            room: false
        })
    );

    // An empty block (no ids, no room) is not an alerting fact.
    assert_eq!(mentions_info(&json!({"m.mentions": {}})), None);

    // No block at all — the common case, and non-object blocks
    // degrade the same way.
    assert_eq!(
        mentions_info(&json!({"msgtype": "m.text", "body": "x"})),
        None
    );
    assert_eq!(mentions_info(&json!({"m.mentions": "nope"})), None);

    // Hostile oversize id lists cap at 64.
    let hostile = json!({
        "m.mentions": {"user_ids": (0..500).map(|i| format!("@u{i}:hs")).collect::<Vec<_>>()}
    });
    let Some(mi) = mentions_info(&hostile) else {
        panic!("hostile dropped")
    };
    assert_eq!(mi.user_ids.len(), 64);
    assert_eq!(mi.user_ids[63], "@u63:hs");
}

#[test]
fn voice_info_reads_the_marker_and_data_blocks() {
    use serde_json::json;

    // Current draft shape (Element): `m.voice` marker, `m.audio` data.
    let v2 = json!({
        "msgtype": "m.audio",
        "body": "voice message",
        "m.voice": {},
        "m.audio": {"duration": 4321, "waveform": [0, 256, 1024]},
    });
    assert_eq!(
        voice_info(&v2),
        Some(VoiceInfo {
            duration: Some(4321),
            waveform: vec![0, 256, 1024]
        })
    );

    // Unstable aliases: the marker and the data block under the
    // extensible-event-era names.
    let v1 = json!({
        "msgtype": "m.audio",
        "org.matrix.msc3245.voice": {},
        "org.matrix.msc1767.audio": {"duration": 1000, "waveform": [10, 20]},
    });
    assert_eq!(
        voice_info(&v1),
        Some(VoiceInfo {
            duration: Some(1000),
            waveform: vec![10, 20]
        })
    );

    // The ancient marker still marks a voice note; a marker without
    // a data block degrades to no waveform rather than vanishing.
    let ancient = json!({"org.matrix.msc2516.voice": {}});
    assert_eq!(
        voice_info(&ancient),
        Some(VoiceInfo {
            duration: None,
            waveform: vec![]
        })
    );

    // Plain audio (no marker) is not a voice note.
    let plain = json!({"msgtype": "m.audio", "m.audio": {"duration": 99}});
    assert_eq!(voice_info(&plain), None);

    // Clamping and capping hostile input: out-of-range amplitudes
    // clamp to 0..=1024, non-numbers drop out.
    let hostile = json!({
        "m.voice": {},
        "m.audio": {"duration": 2.4, "waveform": [-5, 2048, "x", 128.6]},
    });
    assert_eq!(
        voice_info(&hostile),
        Some(VoiceInfo {
            duration: Some(2),
            waveform: vec![0, 1024, 129]
        })
    );
}

#[test]
fn audio_content_display_merges_voice_into_media() {
    use matrix_sdk::ruma::events::room::message::{AudioMessageEventContent, MessageType};
    use matrix_sdk::ruma::events::room::MediaSource;
    use serde_json::json;

    let audio = MessageType::Audio(AudioMessageEventContent::new(
        String::from("voice message"),
        MediaSource::Plain(<&matrix_sdk::ruma::MxcUri>::from("mxc://hs/v").to_owned()),
    ));
    // info.duration is absent; the voice block is the only source.
    let content = json!({
        "m.voice": {},
        "m.audio": {"duration": 4321, "waveform": [10, 300]},
    });
    let display = content_display(&audio, Some(&content)).expect("audio display");
    let media = display.media.expect("audio media");
    assert_eq!(media.duration, Some(4321));
    assert_eq!(media.voice, Some(vec![10, 300]));

    // A plain audio message (no marker in the content JSON) keeps
    // voice unset.
    let plain = json!({"msgtype": "m.audio"});
    let display = content_display(&audio, Some(&plain)).expect("audio display");
    let media = display.media.expect("audio media");
    assert_eq!(media.voice, None);
    assert_eq!(media.duration, None);
}

fn poll_info(kind: &str, ts: u64) -> PollStartInfo {
    PollStartInfo {
        kind: kind.into(),
        max_selections: 1,
        question: "Lunch?".into(),
        answers: vec![("o1".into(), "Pizza".into()), ("o2".into(), "Sushi".into())],
        ts,
    }
}

#[test]
fn polls_merge_and_project() {
    let mut state = PollState::new();
    merge_poll_start(&mut state, "$p:hs", None, poll_info("m.disclosed", 100));
    merge_poll_response(
        &mut state,
        "$p:hs",
        "$r1:hs",
        "@a:hs",
        110,
        vec!["o1".into()],
    );
    merge_poll_response(
        &mut state,
        "$p:hs",
        "$r2:hs",
        "@b:hs",
        120,
        vec!["o2".into()],
    );
    // Own vote in, re-folded (live + backfill overlap).
    merge_poll_response(
        &mut state,
        "$p:hs",
        "$r3:hs",
        "@own:hs",
        130,
        vec!["o1".into()],
    );
    merge_poll_response(
        &mut state,
        "$p:hs",
        "$r3:hs",
        "@own:hs",
        130,
        vec!["o1".into()],
    );
    // A response before the start in the same page (backfill split):
    // folds under the poll id and unifies.
    merge_poll_response(
        &mut state,
        "$p:hs",
        "$r4:hs",
        "@c:hs",
        125,
        vec!["o2".into()],
    );
    merge_poll_start(&mut state, "$p:hs", None, poll_info("m.disclosed", 100));

    let entry = poll_entry(&state, "$p:hs", "@own:hs").unwrap();
    assert_eq!(entry.question, "Lunch?");
    assert_eq!(entry.kind, "m.disclosed");
    assert!(!entry.ended);
    let counts: Vec<u64> = entry.options.iter().map(|o| o.count).collect();
    assert_eq!(counts, vec![2, 2]);
    assert_eq!(entry.options[0].voters, vec!["@a:hs", "@own:hs"]);
    let own: Vec<bool> = entry.options.iter().map(|o| o.own).collect();
    assert_eq!(own, vec![true, false]);
}

#[test]
fn polls_newest_response_wins_and_caps_selections() {
    let mut state = PollState::new();
    merge_poll_start(&mut state, "$p:hs", None, poll_info("m.disclosed", 100));

    // One response per voter: the newest counts (ties by event id).
    merge_poll_response(
        &mut state,
        "$p:hs",
        "$r1:hs",
        "@a:hs",
        110,
        vec!["o1".into()],
    );
    merge_poll_response(
        &mut state,
        "$p:hs",
        "$r2:hs",
        "@a:hs",
        120,
        vec!["o2".into()],
    );
    let entry = poll_entry(&state, "$p:hs", "@z:hs").unwrap();
    assert_eq!(entry.options[0].count, 0);
    assert_eq!(entry.options[1].count, 1);
    assert_eq!(entry.options[1].voters, vec!["@a:hs"]);

    // Selections cap to max_selections at projection time — the
    // first selection fits max 1, the rest drop out.
    merge_poll_response(
        &mut state,
        "$p:hs",
        "$r3:hs",
        "@b:hs",
        130,
        vec!["o1".into(), "o2".into(), "o1".into()],
    );
    let entry = poll_entry(&state, "$p:hs", "@z:hs").unwrap();
    assert_eq!(entry.options[0].count, 1);
    assert_eq!(entry.options[1].count, 1);
    assert_eq!(entry.options[0].voters, vec!["@b:hs"]);

    // A higher cap admits a second selection (and a repeated id
    // inside one response never counts twice — @b picked o1, o2, o1
    // and now lands once in each option's voter list).
    state
        .get_mut("$p:hs")
        .unwrap()
        .start
        .as_mut()
        .unwrap()
        .max_selections = 2;
    let entry = poll_entry(&state, "$p:hs", "@z:hs").unwrap();
    assert_eq!(entry.options[0].count, 1);
    assert_eq!(entry.options[1].count, 2);
    assert_eq!(entry.options[0].voters, vec!["@b:hs"]);
    assert_eq!(entry.options[1].voters, vec!["@a:hs", "@b:hs"]);

    // Unknown answer ids drop out.
    merge_poll_response(
        &mut state,
        "$p:hs",
        "$r4:hs",
        "@c:hs",
        140,
        vec!["oX".into()],
    );
    let entry = poll_entry(&state, "$p:hs", "@z:hs").unwrap();
    assert_eq!(entry.options[0].count, 1);
    assert_eq!(entry.options[1].count, 2);
}

#[test]
fn polls_undisclosed_hides_counts_until_end() {
    let mut state = PollState::new();
    merge_poll_start(&mut state, "$p:hs", None, poll_info("m.undisclosed", 100));
    merge_poll_response(
        &mut state,
        "$p:hs",
        "$r1:hs",
        "@a:hs",
        110,
        vec!["o1".into()],
    );
    merge_poll_response(
        &mut state,
        "$p:hs",
        "$r2:hs",
        "@own:hs",
        120,
        vec!["o2".into()],
    );

    // Others' picks hidden; the own option shows its mark (and the
    // count 1 a viewer can deduce from it).
    let entry = poll_entry(&state, "$p:hs", "@own:hs").unwrap();
    assert_eq!(entry.options[0].count, 0);
    assert!(!entry.options[0].own);
    assert!(entry.options[0].voters.is_empty());
    assert!(entry.options[1].own);
    assert_eq!(entry.options[1].count, 1);
    assert!(entry.options[1].voters.is_empty());

    // An end event opens the results and stops later votes.
    merge_poll_end(&mut state, "$p:hs", 200);
    merge_poll_response(
        &mut state,
        "$p:hs",
        "$r3:hs",
        "@b:hs",
        300,
        vec!["o1".into()],
    );
    let entry = poll_entry(&state, "$p:hs", "@own:hs").unwrap();
    assert!(entry.ended);
    assert_eq!(entry.options[0].count, 1);
    assert_eq!(entry.options[0].voters, vec!["@a:hs"]);
    // The vote behind the end did not count.
    assert!(!entry.options[0].voters.contains(&"@b:hs".into()));
}

#[test]
fn polls_replacements_unify_drifted_votes() {
    let mut state = PollState::new();
    // The start lands after some votes folded (backfill split), and
    // a response named an edit id that never had its own start.
    merge_poll_response(
        &mut state,
        "$p:hs",
        "$r1:hs",
        "@a:hs",
        110,
        vec!["o1".into()],
    );
    merge_poll_response(
        &mut state,
        "$edit:hs",
        "$r2:hs",
        "@b:hs",
        120,
        vec!["o2".into()],
    );
    merge_poll_start(
        &mut state,
        "$p:hs",
        Some("$edit:hs"),
        poll_info("m.disclosed", 200),
    );

    // The drifted response entry merged under the poll's key; the
    // end's `m.reference` to the edit id still resolves.
    merge_poll_end(&mut state, "$edit:hs", 300);
    let entry = poll_entry(&state, "$p:hs", "@z:hs").unwrap();
    assert!(entry.ended);
    assert_eq!(entry.options[0].count, 1);
    assert_eq!(entry.options[1].count, 1);
    assert!(!state.contains_key("$edit:hs"));
}

#[test]
fn polls_redaction_prunes() {
    let mut state = PollState::new();
    merge_poll_start(&mut state, "$p:hs", None, poll_info("m.disclosed", 100));
    merge_poll_response(
        &mut state,
        "$p:hs",
        "$r1:hs",
        "@a:hs",
        110,
        vec!["o1".into()],
    );
    merge_poll_response(
        &mut state,
        "$p:hs",
        "$r2:hs",
        "@a:hs",
        120,
        vec!["o2".into()],
    );

    // An unknown redaction touches nothing.
    assert!(poll_redaction(&mut state, "$nope:hs").is_empty());

    // Redacting a voter's newest response falls back to their
    // earlier one (the spec renders responses in order).
    assert_eq!(poll_redaction(&mut state, "$r2:hs"), vec!["$p:hs"]);
    let entry = poll_entry(&state, "$p:hs", "@z:hs").unwrap();
    assert_eq!(entry.options[0].count, 1);
    assert_eq!(entry.options[0].voters, vec!["@a:hs"]);
    assert_eq!(entry.options[1].count, 0);

    // Redacting the start removes the poll entirely.
    assert_eq!(poll_redaction(&mut state, "$p:hs"), vec!["$p:hs"]);
    assert!(poll_entry(&state, "$p:hs", "@z:hs").is_none());
}

// === Poll interop: Element and pre-spec payloads normalize into
// the final MSC3381 shapes, and our own wire carries every
// namespace a known parser reads ===

/// A typed start behind its (normalized) event JSON.
fn typed_start(ev: &serde_json::Value) -> OriginalSyncPollStartEvent {
    Raw::<OriginalSyncPollStartEvent>::from_json_string(ev.to_string())
        .expect("raw")
        .deserialize()
        .expect("typed")
}

/// A typed response behind its (normalized) event JSON.
fn typed_response(ev: &serde_json::Value) -> OriginalSyncPollResponseEvent {
    Raw::<OriginalSyncPollResponseEvent>::from_json_string(ev.to_string())
        .expect("raw")
        .deserialize()
        .expect("typed")
}

/// A typed end behind its (normalized) event JSON.
fn typed_end(ev: &serde_json::Value) -> OriginalSyncPollEndEvent {
    Raw::<OriginalSyncPollEndEvent>::from_json_string(ev.to_string())
        .expect("raw")
        .deserialize()
        .expect("typed")
}

#[test]
fn poll_start_normalize_element_shape() {
    use serde_json::json;
    // Element (matrix-js-sdk) builds its question and answer texts
    // as strings, keys answers by `id` and uses `m.poll.`-prefixed
    // kinds.
    let mut ev = json!({
        "type": "m.poll.start",
        "event_id": "$p:hs",
        "sender": "@a:hs",
        "origin_server_ts": 10,
        "content": {
            "m.text": "Lunch?\n1. Socks",
            "m.poll.start": {
                "question": {"m.text": "Lunch?"},
                "kind": "m.poll.disclosed",
                "max_selections": 2,
                "answers": [
                    {"id": "o1", "m.text": "Socks"},
                    {"id": "o2", "m.text": "Shoes"},
                ],
            },
        },
    });
    normalize_poll_event(&mut ev);
    let ev = typed_start(&ev);
    let info = poll_start_info(&ev.content.poll, 10);
    assert_eq!(info.question, "Lunch?");
    assert!(kind_is_disclosed(&info.kind));
    assert_eq!(info.max_selections, 2);
    assert_eq!(
        info.answers,
        vec![("o1".into(), "Socks".into()), ("o2".into(), "Shoes".into())]
    );
    // The string fallback became the block array the typed parse
    // demands — the parse above already proves it.
    assert!(
        kind_is_disclosed("m.disclosed")
            && !kind_is_disclosed("m.undisclosed")
            && !kind_is_disclosed("m.poll.undisclosed")
            && kind_is_disclosed("org.matrix.msc3381.poll.disclosed")
            && !kind_is_disclosed("org.matrix.msc3381.poll.undisclosed")
    );
}

#[test]
fn poll_start_normalize_unstable_shape() {
    use serde_json::json;
    // The MSC3381 unstable revision: `org.matrix.msc3381.*` keys
    // and string `org.matrix.msc1767.text` fields everywhere.
    let mut ev = json!({
        "type": "org.matrix.msc3381.poll.start",
        "event_id": "$p:hs",
        "sender": "@a:hs",
        "origin_server_ts": 11,
        "content": {
            "org.matrix.msc1767.text": "Lunch? 1. Socks",
            "org.matrix.msc3381.poll.start": {
                "question": {"org.matrix.msc1767.text": "Lunch?"},
                "kind": "org.matrix.msc3381.poll.undisclosed",
                "answers": [{"id": "o1", "org.matrix.msc1767.text": "Socks"}],
            },
        },
    });
    normalize_poll_event(&mut ev);
    let ev = typed_start(&ev);
    let info = poll_start_info(&ev.content.poll, 11);
    assert_eq!(info.question, "Lunch?");
    assert!(!kind_is_disclosed(&info.kind));
    // No max_selections on the wire: the default 1.
    assert_eq!(info.max_selections, 1);
    assert_eq!(info.answers, vec![("o1".into(), "Socks".into())]);
}

#[test]
fn poll_unstable_types_retype_to_stable() {
    use serde_json::json;
    // SchildiChat variants (and FluffyChat) send polls under the
    // MSC3381-unstable revision: the typed parse yields ruma's
    // `UnstablePoll*` variants — which the backfill fold and render
    // passes do not know — so the re-type pass must yield the
    // stable `m.poll.*` variants with identical payloads.
    let ev = json!({
        "type": "org.matrix.msc3381.poll.start",
        "event_id": "$p1:hs",
        "sender": "@a:hs",
        "origin_server_ts": 10,
        "content": {
            "org.matrix.msc1767.text": "Lunch?\n1. Socks",
            "org.matrix.msc3381.poll.start": {
                "question": {"org.matrix.msc1767.text": "Lunch?"},
                "kind": "org.matrix.msc3381.poll.disclosed",
                "answers": [
                    {"id": "o1", "org.matrix.msc1767.text": "Socks"},
                    {"id": "o2", "org.matrix.msc1767.text": "Shoes"},
                ],
            },
        },
    });

    // The unstable wire type typed-parses — into an unstable
    // variant (this is exactly how these polls slipped through the
    // backfill pass 1 unnoticed).
    let unstable = Raw::<AnySyncTimelineEvent>::from_json_string(ev.to_string())
        .expect("raw")
        .deserialize()
        .expect("typed");
    match &unstable {
        AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::UnstablePollStart(_)) => {}
        other => panic!("expected an UnstablePollStart variant, got {other:?}"),
    }

    let stable =
        unstable_poll_retyped("org.matrix.msc3381.poll.start", &ev.to_string()).expect("re-typed");
    match &stable {
        AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::PollStart(
            SyncMessageLikeEvent::Original(m),
        )) => {
            assert_eq!(m.event_id.as_str(), "$p1:hs");
            let info = poll_start_info(&m.content.poll, 10);
            assert_eq!(info.question, "Lunch?");
            assert!(kind_is_disclosed(&info.kind));
            assert_eq!(info.max_selections, 1);
            assert_eq!(
                info.answers,
                vec![("o1".into(), "Socks".into()), ("o2".into(), "Shoes".into())]
            );
        }
        other => panic!("expected a stable PollStart, got {other:?}"),
    }
}

#[test]
fn poll_unstable_response_and_end_retype_to_stable() {
    use serde_json::json;
    let response = json!({
        "type": "org.matrix.msc3381.poll.response",
        "event_id": "$v:hs",
        "sender": "@a:hs",
        "origin_server_ts": 11,
        "content": {
            "m.relates_to": {"rel_type": "m.reference", "event_id": "$p1:hs"},
            "org.matrix.msc3381.poll.response": {"answers": ["o1"]},
        },
    });
    let stable = unstable_poll_retyped("org.matrix.msc3381.poll.response", &response.to_string())
        .expect("re-typed");
    match &stable {
        AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::PollResponse(
            SyncMessageLikeEvent::Original(m),
        )) => {
            assert_eq!(m.event_id.as_str(), "$v:hs");
            assert_eq!(m.content.relates_to.event_id.as_str(), "$p1:hs");
            assert_eq!(
                m.content.selections.iter().cloned().collect::<Vec<_>>(),
                vec!["o1"]
            );
        }
        other => panic!("expected a stable PollResponse, got {other:?}"),
    }

    let end = json!({
        "type": "org.matrix.msc3381.poll.end",
        "event_id": "$e:hs",
        "sender": "@a:hs",
        "origin_server_ts": 12,
        "content": {
            "m.relates_to": {"rel_type": "m.reference", "event_id": "$p1:hs"},
        },
    });
    let stable =
        unstable_poll_retyped("org.matrix.msc3381.poll.end", &end.to_string()).expect("re-typed");
    match &stable {
        AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::PollEnd(
            SyncMessageLikeEvent::Original(m),
        )) => {
            assert_eq!(m.content.relates_to.event_id.as_str(), "$p1:hs");
        }
        other => panic!("expected a stable PollEnd, got {other:?}"),
    }
}

#[test]
fn poll_unstable_replacement_retypes_with_new_content_block() {
    use serde_json::json;
    // A poll edit under the unstable revision: the new payload
    // lives in `m.new_content` (top level, the standard
    // replacement shape) in the pre-spec unstable block.  The
    // normalizer must build the spec block there.
    let ev = json!({
        "type": "org.matrix.msc3381.poll.start",
        "event_id": "$p1r:hs",
        "sender": "@a:hs",
        "origin_server_ts": 12,
        "content": {
            "m.relates_to": {"rel_type": "m.replace", "event_id": "$p1:hs"},
            "m.new_content": {
                "org.matrix.msc3381.poll.start": {
                    "question": {"org.matrix.msc1767.text": "Lunch?"},
                    "kind": "org.matrix.msc3381.poll.disclosed",
                    "answers": [{"id": "o1", "org.matrix.msc1767.text": "Socks"}],
                },
            },
        },
    });
    // The pre-spec replacement typed-parses fine — as an unstable
    // variant (its new payload sits in the pre-spec block, which
    // only the unstable shape knows) — so the pass-1 rewrite sees
    // it too, and the re-type must rebuild the new content's spec
    // block.
    let unstable = Raw::<AnySyncTimelineEvent>::from_json_string(ev.to_string())
        .expect("raw")
        .deserialize()
        .expect("typed");
    match &unstable {
        AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::UnstablePollStart(_)) => {}
        other => panic!("expected an UnstablePollStart variant, got {other:?}"),
    }
    let stable =
        unstable_poll_retyped("org.matrix.msc3381.poll.start", &ev.to_string()).expect("re-typed");
    match &stable {
        AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::PollStart(
            SyncMessageLikeEvent::Original(m),
        )) => {
            let Some(Relation::Replacement(r)) = m.content.relates_to.as_ref() else {
                panic!("expected a replacement relation");
            };
            assert_eq!(r.event_id.as_str(), "$p1:hs");
            let info = poll_start_info(&r.new_content.poll, 12);
            assert_eq!(info.question, "Lunch?");
            assert_eq!(info.answers, vec![("o1".into(), "Socks".into())]);
        }
        other => panic!("expected a stable PollStart, got {other:?}"),
    }
}

#[test]
fn poll_response_normalize_element_shape() {
    use serde_json::json;
    // Element keeps its selections inside the block; the spec
    // expects them at the top level.  This is the exact shape
    // whose absence made every Element vote spoiled (zero votes
    // shown).
    let mut ev = json!({
        "type": "m.poll.response",
        "event_id": "$r:hs",
        "sender": "@b:hs",
        "origin_server_ts": 12,
        "content": {
            "m.relates_to": {"rel_type": "m.reference", "event_id": "$p:hs"},
            "m.poll.response": {"answers": ["o1", "o2"]},
        },
    });
    normalize_poll_event(&mut ev);
    let ev = typed_response(&ev);
    let selections: Vec<String> = ev.content.selections.iter().cloned().collect();
    assert_eq!(selections, vec!["o1".to_owned(), "o2".to_owned()]);
    assert_eq!(ev.content.relates_to.event_id.to_string(), "$p:hs");
}

#[test]
fn poll_end_normalize_element_shape() {
    use serde_json::json;
    // Element ships the end with a string fallback text; the typed
    // content wants the block array.
    let mut ev = json!({
        "type": "m.poll.end",
        "event_id": "$e:hs",
        "sender": "@a:hs",
        "origin_server_ts": 13,
        "content": {
            "m.relates_to": {"rel_type": "m.reference", "event_id": "$p:hs"},
            "m.poll.end": {},
            "m.text": "The poll has ended.",
        },
    });
    normalize_poll_event(&mut ev);
    let ev = typed_end(&ev);
    assert_eq!(ev.content.relates_to.event_id.to_string(), "$p:hs");
}

#[test]
fn poll_normalize_passes_spec_events_through() {
    use serde_json::json;
    // Our own wire — the round trip through the fold path keeps
    // the fold data intact.
    let mut ev = json!({
        "type": "m.poll.start",
        "event_id": "$p:hs",
        "sender": "@a:hs",
        "origin_server_ts": 14,
        "content": poll_start_wire(
            "Lunch?",
            "Poll: Lunch?\n1. Socks\n2. Shoes",
            &["Socks".to_owned(), "Shoes".to_owned()],
            1,
            true,
        ),
    });
    normalize_poll_event(&mut ev);
    let ev = typed_start(&ev);
    let info = poll_start_info(&ev.content.poll, 14);
    assert_eq!(info.question, "Lunch?");
    assert!(kind_is_disclosed(&info.kind));
    assert_eq!(info.max_selections, 1);
    assert_eq!(
        info.answers,
        vec![("o1".into(), "Socks".into()), ("o2".into(), "Shoes".into())]
    );
}

#[test]
fn poll_votes_normalize_element_shape() {
    use serde_json::json;
    // Vote + end wire round trips parse back typed, and the wire
    // carries the Element/legacy keys the other clients read.
    let mut vote = json!({
        "type": "m.poll.response",
        "event_id": "$r:hs",
        "sender": "@b:hs",
        "origin_server_ts": 16,
        "content": poll_response_wire(&["o2".to_owned()], "$p:hs"),
    });
    normalize_poll_event(&mut vote);
    let vote = typed_response(&vote);
    let selections: Vec<String> = vote.content.selections.iter().cloned().collect();
    assert_eq!(selections, vec!["o2".to_owned()]);
    let vote_json = serde_json::to_value(&vote.content).expect("content");
    // The typed round trip keeps the selections (the Element block
    // itself is a receive-only key, dropped on the way back out).
    assert_eq!(vote_json.pointer("/m.selections"), Some(&json!(["o2"])));

    let end = poll_end_wire("$p:hs");
    assert!(end.get("m.poll.end").is_some());
    assert!(end.get("org.matrix.msc3381.poll.end").is_some());
    let mut end_ev = json!({
        "type": "m.poll.end",
        "event_id": "$e:hs",
        "sender": "@a:hs",
        "origin_server_ts": 17,
        "content": end,
    });
    normalize_poll_event(&mut end_ev);
    let end_ev = typed_end(&end_ev);
    assert_eq!(end_ev.content.relates_to.event_id.to_string(), "$p:hs");
}

#[test]
fn poll_start_wire_carries_all_namespaces() {
    let start = poll_start_wire(
        "Lunch?",
        "Poll: Lunch?\n1. Socks\n2. Shoes",
        &["Socks".to_owned(), "Shoes".to_owned()],
        2,
        false,
    );
    // Element's keys: the `m.poll.start` block, `id` answer keys,
    // plain string texts, `m.poll.`-prefixed kinds.
    assert_eq!(
        start.pointer("/m.poll.start/question/m.text"),
        Some(&serde_json::json!("Lunch?"))
    );
    assert_eq!(
        start.pointer("/m.poll.start/answers/0/id"),
        Some(&serde_json::json!("o1"))
    );
    assert_eq!(
        start.pointer("/m.poll.start/answers/1/m.text"),
        Some(&serde_json::json!("Shoes"))
    );
    assert_eq!(
        start.pointer("/m.poll.start/kind"),
        Some(&serde_json::json!("m.poll.undisclosed"))
    );
    // The unstable revision.
    assert_eq!(
        start.pointer("/org.matrix.msc3381.poll.start/kind"),
        Some(&serde_json::json!("org.matrix.msc3381.poll.undisclosed"))
    );
    // The final spec block.
    assert_eq!(
        start.pointer("/m.poll/kind"),
        Some(&serde_json::json!("m.undisclosed"))
    );
    assert_eq!(
        start.pointer("/m.poll/answers/0/m.id"),
        Some(&serde_json::json!("o1"))
    );
    assert_eq!(
        start.pointer("/m.poll/max_selections"),
        Some(&serde_json::json!(2))
    );
    // Answer ids line up across all three namespaces (existing
    // votes must survive the wire change).
    for ns in ["m.poll", "m.poll.start", "org.matrix.msc3381.poll.start"].iter() {
        let key = format!("/{ns}/answers");
        let ids: Vec<&str> = start
            .pointer(&key)
            .unwrap()
            .as_array()
            .unwrap()
            .iter()
            .map(|a| {
                a.get("m.id")
                    .or_else(|| a.get("id"))
                    .and_then(|v| v.as_str())
                    .unwrap()
            })
            .collect();
        assert_eq!(ids, vec!["o1", "o2"], "namespace {ns}");
    }
}

#[test]
fn poll_normalize_leaves_other_events_alone() {
    use serde_json::json;
    // Non-poll events keep every key — even ones that look like
    // poll blocks (a reply to a poll could quote keys).
    let mut ev = json!({
        "type": "m.room.message",
        "event_id": "$m:hs",
        "sender": "@a:hs",
        "origin_server_ts": 15,
        "content": {"msgtype": "m.text", "body": "hi", "m.poll.start": {"answers": []}},
    });
    normalize_poll_event(&mut ev);
    assert_eq!(ev.pointer("/content/m.poll"), None);
    // The fallback text alone stays untouched — a non-poll event
    // gains nothing.
    assert_eq!(ev.pointer("/content/m.text"), None);
    // The same for a missing type entirely.
    let mut odd = json!({"content": {"m.poll.response": {"answers": ["o1"]}}});
    normalize_poll_event(&mut odd);
    assert_eq!(odd.pointer("/content/m.selections"), None);
}

#[test]
fn poll_entry_reveals_element_kinds() {
    // Element's disclosed spelling shows the running results like
    // our own does...
    let mut state = PollState::new();
    merge_poll_start(
        &mut state,
        "$p:hs",
        None,
        poll_info("m.poll.disclosed", 100),
    );
    merge_poll_response(
        &mut state,
        "$p:hs",
        "$r1:hs",
        "@a:hs",
        110,
        vec!["o1".into()],
    );
    let entry = poll_entry(&state, "$p:hs", "@z:hs").unwrap();
    assert_eq!(entry.options[0].count, 1);
    assert_eq!(entry.options[0].voters, vec!["@a:hs"]);
    assert_eq!(entry.kind, "m.poll.disclosed");

    // ...and the undisclosed spelling keeps them frozen until the
    // poll ends, in every namespace spelling.
    for kind in [
        "m.undisclosed",
        "m.poll.undisclosed",
        "org.matrix.msc3381.poll.undisclosed",
    ] {
        let mut state = PollState::new();
        merge_poll_start(&mut state, "$p:hs", None, poll_info(kind, 100));
        merge_poll_response(
            &mut state,
            "$p:hs",
            "$r1:hs",
            "@a:hs",
            110,
            vec!["o1".into()],
        );
        let entry = poll_entry(&state, "$p:hs", "@z:hs").unwrap();
        assert_eq!(entry.options[0].count, 0, "kind {kind}");
    }
}

fn value(json: &str) -> serde_json::Value {
    serde_json::from_str(json).unwrap()
}

#[test]
fn room_spaces_parents_parse_canonical_first() {
    let events = vec![
        value(r#"{"type":"m.space.parent","state_key":"!b:hs","content":{}}"#),
        value(r#"{"type":"m.space.parent","state_key":"!a:hs","content":{"canonical":true}}"#),
        value(r#"{"type":"m.room.member","state_key":"@u:hs","content":{}}"#),
        value(r#"{"type":"m.space.parent"}"#),
    ];
    assert_eq!(
        parent_ids_from_events(&events),
        vec![("!a:hs".to_owned(), true), ("!b:hs".to_owned(), false)]
    );
}

#[test]
fn upgrade_links_read_both_spec_shapes() {
    // The successor from the tombstone, the predecessor from the
    // spec's m.room.create place and the dynamic event's shape.
    let create = value(
        r#"{"type":"m.room.create","state_key":"","content":{
        "creator":"@u:hs","predecessor":{"room_id":"!old:hs","event_id":"$e"}}}"#,
    );
    let dynamic = value(
        r#"{"type":"m.room.predecessor","state_key":"","content":{
        "predecessor_room_id":"!older:hs"}}"#,
    );
    let tombstone = value(
        r#"{"type":"m.room.tombstone","state_key":"","content":{
        "body":"replaced","replacement_room":"!new:hs"}}"#,
    );

    assert_eq!(
        successor_ids(std::slice::from_ref(&tombstone)),
        vec!["!new:hs"]
    );
    assert_eq!(
        predecessor_ids(&[create, dynamic.clone()]),
        vec!["!old:hs", "!older:hs"]
    );
    // Redacted or unrelated state reads as linkless.
    let redacted = value(r#"{"type":"m.room.tombstone","state_key":""}"#);
    assert!(successor_ids(&[redacted]).is_empty());
    let empty = value(r#"{"type":"m.room.create","state_key":"","content":{}}"#);
    let mut with_dynamic = vec![empty];
    with_dynamic.push(dynamic);
    assert_eq!(predecessor_ids(&with_dynamic), vec!["!older:hs".to_owned()]);
}

#[test]
fn row_children_vias_reads_space_child_state() {
    // A parent's children_state carries each child's via servers in
    // content.via; entries without a usable via list are dropped.
    let parent = value(
        r#"{"room_id":"!s:hs","children_state":[
        {"type":"m.space.child","state_key":"!a:hs",
         "content":{"via":["hs","mirror:hs"]}},
        {"type":"m.space.child","state_key":"!b:hs","content":{}},
        {"type":"m.space.child","state_key":"!c:hs",
         "content":{"via":[]}},
        {"type":"m.space.child","content":{"via":["hs"]}},
        {"type":"m.space.child","state_key":"!d:hs",
         "content":{"via":["alt:hs"]}}
    ]}"#,
    );
    assert_eq!(
        row_children_vias(&parent),
        vec![
            (
                "!a:hs".to_owned(),
                vec!["hs".to_owned(), "mirror:hs".to_owned()]
            ),
            ("!d:hs".to_owned(), vec!["alt:hs".to_owned()]),
        ]
    );
    // No children_state at all reads as no vias.
    assert!(row_children_vias(&value(r#"{"room_id":"!s:hs"}"#)).is_empty());
}

#[test]
fn summary_upgrade_links_pick_the_first_id() {
    // The summary's link fields: the tombstone's replacement room,
    // and the first predecessor the create/dynamic reads yielded —
    // None on every linkless input, empty ids included.
    let create = value(
        r#"{"type":"m.room.create","state_key":"","content":{
        "creator":"@u:hs","predecessor":{"room_id":"!old:hs","event_id":"$e"}}}"#,
    );
    let dynamic = value(
        r#"{"type":"m.room.predecessor","state_key":"","content":{
        "predecessor_room_id":"!older:hs"}}"#,
    );
    let tombstone = value(
        r#"{"type":"m.room.tombstone","state_key":"","content":{
        "body":"replaced","replacement_room":"!new:hs"}}"#,
    );
    assert_eq!(
        first_link_id(successor_ids(&[tombstone])),
        Some("!new:hs".to_owned())
    );
    assert_eq!(
        first_link_id(predecessor_ids(&[create, dynamic])),
        Some("!old:hs".to_owned())
    );
    assert_eq!(first_link_id(successor_ids(&[])), None);
    assert_eq!(first_link_id(predecessor_ids(&[])), None);
}

#[test]
fn chain_walk_folds_and_never_cycles() {
    // A -> oldA (predecessor of oldA), oldA -> newerA; C cycles
    // back to A.  The walk from A ends after collecting each room
    // once — a cycle cannot re-add.
    let mut links: HashMap<String, (Vec<String>, Vec<String>)> = HashMap::new();
    links.insert(
        "!a:hs".to_owned(),
        (vec!["!c:hs".to_owned()], vec!["!old:hs".to_owned()]),
    );
    links.insert("!c:hs".to_owned(), (vec![], vec!["!a:hs".to_owned()]));
    links.insert(
        "!old:hs".to_owned(),
        (vec!["!a:hs".to_owned(), "!a2:hs".to_owned()], vec![]),
    );
    // Direct construction of the two hops the handler walks (the
    // loader's per-room reads are best-effort and untestable
    // without a client); the seen-set is the protection.
    let mut seen: HashSet<String> = HashSet::from(["!a:hs".to_owned()]);
    let next = chain_next_ids(&["!a:hs".to_owned()], &links, &mut seen);
    assert!(next.contains(&"!c:hs".to_owned()));
    assert!(next.contains(&"!old:hs".to_owned()));
    // The second hop: back to !a (seen, skipped), on to !a2.
    let next = chain_next_ids(&next, &links, &mut seen);
    assert_eq!(next, vec!["!a2:hs".to_owned()]);
    // A third pass adds nothing — the cycle is fully seen.
    let next = chain_next_ids(&next, &links, &mut seen);
    assert!(next.is_empty());
    // A room without links expands to nothing.
    let mut seen2: HashSet<String> = HashSet::from(["!x:hs".to_owned()]);
    assert!(chain_next_ids(&["!x:hs".to_owned()], &links, &mut seen2).is_empty());
}

#[test]
fn child_scan_matches_parent_side_room_ids() {
    let accept: HashSet<String> = HashSet::from(["!room:hs".to_owned(), "!old:hs".to_owned()]);
    // The space lists the room's predecessor: a match (the
    // upgrade-loop case), and so does the direct listing.
    let space_children = vec![
        value(r#"{"type":"m.space.child","state_key":"!old:hs","content":{"via":["hs"]}}"#),
        value(r#"{"type":"m.space.child","state_key":"!other:hs","content":{"via":["hs"]}}"#),
    ];
    assert!(child_matches(&space_children, &accept));
    let direct = vec![value(
        r#"{"type":"m.space.child","state_key":"!room:hs","content":{}}"#,
    )];
    assert!(child_matches(&direct, &accept));
    // A space that lists neither: no match, no parent.
    assert!(!child_matches(&space_children[1..], &accept));
    assert!(!child_matches(&[], &accept));
}

#[test]
fn merge_space_parents_keeps_their_place() {
    let parents = vec![("!a:hs".to_owned(), true), ("!b:hs".to_owned(), false)];
    let merged = merge_space_parents(
        parents,
        vec!["!c:hs".to_owned(), "!a:hs".to_owned(), "!b:hs".to_owned()],
    );
    // Parent-event rows keep their positions; the child-scan finds
    // append deduped, as non-canonical.
    assert_eq!(
        merged,
        vec![
            ("!a:hs".to_owned(), true),
            ("!b:hs".to_owned(), false),
            ("!c:hs".to_owned(), false)
        ]
    );
}
