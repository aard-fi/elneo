//! Daemon core: client lifecycle, the framed stdio run loop, and command
//! dispatch.
//!
//! Runtime shape: a single writer thread owns stdout (sync handlers would
//! otherwise interleave framed events from concurrent tasks); stdin is read on
//! a blocking thread feeding a command channel; commands run sequentially.

use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader, Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex};

use anyhow::{Context, Result};
use matrix_sdk::authentication::matrix::MatrixSession;
use matrix_sdk::authentication::SessionTokens;
use matrix_sdk::encryption::verification::VerificationRequest;
use matrix_sdk::{Client, ServerName};
use serde_json::Value;
use tokio::sync::mpsc;
use tokio::sync::Mutex;
use tracing::{debug, error, info, warn};

use crate::media;
use crate::protocol::{Command, Event, OutEvent};
use crate::sync;
use crate::verification;

pub type SharedDaemon = Arc<Inner>;

pub struct Inner {
    pub profile: String,
    pub data_dir: std::path::PathBuf,
    /// Client, absent until login or restore.  Shared with sync handlers.
    pub client: Mutex<Option<Client>>,
    /// All outgoing events funnel through this channel to the writer thread.
    pub events: mpsc::UnboundedSender<OutEvent>,
    /// Daemon-local per-room display state.
    pub room_locals: Mutex<HashMap<matrix_sdk::ruma::OwnedRoomId, sync::RoomLocal>>,
    /// Guards against double-starting the sync loop.
    pub syncing: AtomicBool,
    /// The running sync loop task's abort handle, if any.  Logout aborts
    /// it and clears `syncing`: without that, a re-login's startSync
    /// sees "already running" and acks ok while no loop serves the new
    /// client — no live events until a daemon restart.
    pub sync_task: StdMutex<Option<tokio::task::AbortHandle>>,
    /// Cached session info (for getSession).
    pub session: StdMutex<Option<SessionInfo>>,
    /// Verification flows in progress, keyed by flow id.
    pub verifications: StdMutex<HashMap<String, VerificationRequest>>,
    /// Room ids whose key-arrival watcher task is already running.
    pub key_watchers: StdMutex<HashSet<String>>,
    /// The machine-wide room-key arrival watcher's abort handle, if any.
    /// Client-bound: replaced (and the old task aborted) whenever a new
    /// client is installed, so a relogin's stale client cannot emit.
    pub received_keys_task: StdMutex<Option<tokio::task::AbortHandle>>,
    /// In-flight media downloads, keyed by cache key (the media file's path
    /// without extension).  See `media.rs`.
    pub downloads: StdMutex<HashMap<String, media::Download>>,
}

#[derive(Debug, Clone)]
pub struct SessionInfo {
    pub user_id: String,
    pub device_id: String,
    pub access_token: String,
}

impl Inner {
    /// Send an event to the writer thread (framed, in order).
    pub fn send(&self, out: OutEvent) {
        if let Err(e) = self.events.send(out) {
            error!("Event channel closed: {}", e);
        }
    }

    /// Unsolicited event.
    pub fn emit(&self, event: Event) {
        self.send(OutEvent::event(event));
    }

    /// Terminal response to request `req`.
    pub fn respond(&self, req: Option<u64>, event: Event) {
        self.send(OutEvent::response(req, event));
    }

    pub fn ack(&self, req: Option<u64>, ok: bool, error: Option<String>) {
        self.send(OutEvent::ack(req, ok, error));
    }

    /// Clone of the current client, if any.
    pub async fn client(&self) -> Option<Client> {
        self.client.lock().await.clone()
    }

    pub fn set_syncing(&self, value: bool) {
        self.syncing.store(value, Ordering::SeqCst);
    }

    /// Remember the sync loop task's abort handle, replacing any previous.
    pub fn set_sync_task(&self, handle: tokio::task::AbortHandle) {
        *self.sync_task_guard() = Some(handle);
    }

    /// Abort the sync loop task (if any) and clear the `syncing` flag.
    /// Called on logout; aborting an already-finished task is a no-op.
    /// Also drops the machine-wide room-key watcher — it belongs to the
    /// client being torn down, so a relogin cannot have its stale clone
    /// emit anything (add_sync_handlers spawns a fresh one).
    pub fn stop_sync(&self) {
        if let Some(handle) = self.sync_task_guard().take() {
            handle.abort();
        }
        if let Some(handle) = self.received_keys_task_guard().take() {
            handle.abort();
        }
        self.set_syncing(false);
    }

    /// Lock the sync-task slot, recovering from poison (same policy as
    /// the session cache: nothing in the guarded sections can panic).
    fn sync_task_guard(&self) -> std::sync::MutexGuard<'_, Option<tokio::task::AbortHandle>> {
        match self.sync_task.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    /// Lock the session cache, recovering from poison.  One policy for
    /// every accessor: nothing in the guarded sections can panic, but if
    /// one ever does, a lost cache beats a dead daemon — and beats the
    /// old mix of tolerating reads but panicking on writes.
    fn session_guard(&self) -> std::sync::MutexGuard<'_, Option<SessionInfo>> {
        match self.session.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    /// Lock the download table, same poison-recovery policy as the
    /// session cache: a lost in-flight table (the waiters re-request)
    /// beats a poisoned `unwrap` cascading into the dispatch task.
    pub(crate) fn downloads_guard(
        &self,
    ) -> std::sync::MutexGuard<'_, HashMap<String, media::Download>> {
        match self.downloads.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    pub fn session(&self) -> Option<SessionInfo> {
        self.session_guard().clone()
    }

    pub fn set_session(&self, info: SessionInfo) {
        *self.session_guard() = Some(info);
    }

    pub fn clear_session(&self) {
        *self.session_guard() = None;
    }

    /// Lock the room-key watcher set, recovering from poison: a panicking
    /// watcher must not disable watchers for the rest of the daemon's
    /// life.  Same policy as the session cache.
    pub fn key_watchers_guard(&self) -> std::sync::MutexGuard<'_, HashSet<String>> {
        match self.key_watchers.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    /// Lock the machine-wide key-arrival watcher's slot, same poison
    /// policy as the room-key watcher set.
    pub fn received_keys_task_guard(
        &self,
    ) -> std::sync::MutexGuard<'_, Option<tokio::task::AbortHandle>> {
        match self.received_keys_task.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    /// Register the sync event handlers on the client.  Called from the
    /// two sites that install a client (login completion and session
    /// restore), so handlers attach exactly once per client — never from
    /// startSync, where a failed-then-retried sync would double them up.
    pub fn add_sync_handlers(self: &Arc<Self>, client: &Client) {
        verification::add_verification_handlers(self, client);
        crate::sync::spawn_received_room_key_watcher(self.clone(), client);
        let d = Arc::clone(self);
        client.add_event_handler(
            // Raw, not typed: voice messages carry their marker and
            // waveform in unstable content blocks (MSC3245) that ruma's
            // typed content drops; the raw JSON keeps them.  The SDK
            // hands the raw handler the same (decrypted-in-e2e-rooms)
            // event the typed one would get.  The third context arg is
            // optional (`Option<EncryptionInfo>` implements
            // EventHandlerContext): decryption details — sender device
            // and its trust state — for encrypted rooms, nothing for
            // plaintext ones.
            move |ev: matrix_sdk::ruma::serde::Raw<
                matrix_sdk::ruma::events::room::message::OriginalSyncRoomMessageEvent,
            >,
                  info: Option<matrix_sdk::deserialized_responses::EncryptionInfo>,
                  room: matrix_sdk::Room| {
                let d = d.clone();
                async move { crate::sync::on_room_message(d, ev, room, info).await }
            },
        );
        let d = Arc::clone(self);
        client.add_event_handler(
            move |ev: matrix_sdk::ruma::serde::Raw<
                matrix_sdk::ruma::events::sticker::OriginalSyncStickerEvent,
            >,
                  info: Option<matrix_sdk::deserialized_responses::EncryptionInfo>,
                  room: matrix_sdk::Room| {
                let d = d.clone();
                async move { crate::sync::on_sticker(d, ev, info, room).await }
            },
        );
        let d = Arc::clone(self);
        client.add_event_handler(
            move |ev: matrix_sdk::ruma::events::room::member::OriginalSyncRoomMemberEvent,
                  room: matrix_sdk::Room| {
                let d = d.clone();
                async move { crate::sync::on_room_member(d, ev, room).await }
            },
        );
        let d = Arc::clone(self);
        client.add_event_handler(
            move |ev: matrix_sdk::ruma::events::room::name::OriginalSyncRoomNameEvent,
                  room: matrix_sdk::Room| {
                let d = d.clone();
                async move { crate::sync::on_room_name(d, ev, room).await }
            },
        );
        let d = Arc::clone(self);
        client.add_event_handler(
            move |ev: matrix_sdk::ruma::events::room::topic::OriginalSyncRoomTopicEvent,
                  room: matrix_sdk::Room| {
                let d = d.clone();
                async move { crate::sync::on_room_topic(d, ev, room).await }
            },
        );
        let d = Arc::clone(self);
        client.add_event_handler(
            move |ev: matrix_sdk::ruma::events::room::avatar::OriginalSyncRoomAvatarEvent,
                  room: matrix_sdk::Room| {
                let d = d.clone();
                async move { crate::sync::on_room_avatar(d, ev, room).await }
            },
        );
        let d = Arc::clone(self);
        client.add_event_handler(
            move |ev: matrix_sdk::ruma::events::room::pinned_events::OriginalSyncRoomPinnedEventsEvent,
                  room: matrix_sdk::Room| {
                let d = d.clone();
                async move { crate::sync::on_room_pinned(d, ev, room).await }
            },
        );
        let d = Arc::clone(self);
        client.add_event_handler(
            move |ev: matrix_sdk::ruma::events::reaction::OriginalSyncReactionEvent,
                  room: matrix_sdk::Room| {
                let d = d.clone();
                async move { crate::sync::on_reaction(d, ev, room).await }
            },
        );
        let d = Arc::clone(self);
        client.add_event_handler(
            move |ev: matrix_sdk::ruma::serde::Raw<
                matrix_sdk::ruma::events::poll::start::OriginalSyncPollStartEvent,
            >,
                  info: Option<matrix_sdk::deserialized_responses::EncryptionInfo>,
                  room: matrix_sdk::Room| {
                let d = d.clone();
                async move { crate::sync::on_poll_start(d, ev, info, room).await }
            },
        );
        let d = Arc::clone(self);
        client.add_event_handler(
            move |ev: matrix_sdk::ruma::serde::Raw<
                matrix_sdk::ruma::events::poll::response::OriginalSyncPollResponseEvent,
            >,
                  room: matrix_sdk::Room| {
                let d = d.clone();
                async move { crate::sync::on_poll_response(d, ev, room).await }
            },
        );
        let d = Arc::clone(self);
        client.add_event_handler(
            move |ev: matrix_sdk::ruma::serde::Raw<
                matrix_sdk::ruma::events::poll::end::OriginalSyncPollEndEvent,
            >,
                  room: matrix_sdk::Room| {
                let d = d.clone();
                async move { crate::sync::on_poll_end(d, ev, room).await }
            },
        );
        // The MSC3381 unstable types: clients that predate the final
        // spec (and spec clients that dual-send during migration) ship
        // these event types.  The handlers re-shape their payloads and
        // follow the exact same fold path as the stable ones.
        let d = Arc::clone(self);
        client.add_event_handler(
            move |ev: matrix_sdk::ruma::serde::Raw<
                matrix_sdk::ruma::events::poll::unstable_start::OriginalSyncUnstablePollStartEvent,
            >,
                  info: Option<matrix_sdk::deserialized_responses::EncryptionInfo>,
                  room: matrix_sdk::Room| {
                let d = d.clone();
                async move { crate::sync::on_unstable_poll_start(d, ev, info, room).await }
            },
        );
        let d = Arc::clone(self);
        client.add_event_handler(
            move |ev: matrix_sdk::ruma::serde::Raw<
                    matrix_sdk::ruma::events::poll::unstable_response::OriginalSyncUnstablePollResponseEvent,
                >,
                  room: matrix_sdk::Room| {
                let d = d.clone();
                async move { crate::sync::on_unstable_poll_response(d, ev, room).await }
            },
        );
        let d = Arc::clone(self);
        client.add_event_handler(
            move |ev: matrix_sdk::ruma::serde::Raw<
                matrix_sdk::ruma::events::poll::unstable_end::OriginalSyncUnstablePollEndEvent,
            >,
                  room: matrix_sdk::Room| {
                let d = d.clone();
                async move { crate::sync::on_unstable_poll_end(d, ev, room).await }
            },
        );
        let d = Arc::clone(self);
        client.add_event_handler(
            move |ev: matrix_sdk::ruma::events::room::redaction::OriginalSyncRoomRedactionEvent,
                  room: matrix_sdk::Room| {
                let d = d.clone();
                async move { crate::sync::on_redaction(d, ev, room).await }
            },
        );
        let d = Arc::clone(self);
        client.add_event_handler(
            move |ev: matrix_sdk::ruma::events::AnySyncEphemeralRoomEvent,
                  room: matrix_sdk::Room| {
                let d = d.clone();
                async move { crate::sync::on_receipt(d, ev, room).await }
            },
        );
        let d = Arc::clone(self);
        client.add_event_handler(
            move |ev: matrix_sdk::ruma::events::RoomAccountDataEvent<
                matrix_sdk::ruma::events::fully_read::FullyReadEventContent,
            >,
                  room: matrix_sdk::Room| {
                let d = d.clone();
                async move { crate::sync::on_fully_read(d, ev, room) }
            },
        );
    }

    /// Build a client with a persistent sqlite state/crypto store.
    ///
    /// Tries `.well-known` auto-discovery for `server_name` first (it yields
    /// the right base URL for delegated servers); if discovery fails, falls
    /// back to `homeserver_url` (or `https://<server_name>` when restoring a
    /// session) — some servers serve `/_matrix` from a bare domain without
    /// publishing a `.well-known/matrix/client` file.
    pub async fn build_client(
        &self,
        server_name: &ServerName,
        homeserver_url: Option<&str>,
    ) -> Result<Client> {
        let store_dir = self.data_dir.join("store");

        match Client::builder()
            .server_name(server_name)
            .sqlite_store(&store_dir, None)
            .build()
            .await
        {
            Ok(client) => return Ok(client),
            Err(e) => {
                warn!(
                    "Auto-discovery for {server_name} failed, using a direct homeserver URL instead: {e:#}"
                );
            }
        }

        let url = homeserver_url
            .map(str::to_owned)
            .unwrap_or_else(|| format!("https://{server_name}"));
        Client::builder()
            .homeserver_url(url)
            .sqlite_store(&store_dir, None)
            .build()
            .await
            .context("Failed to build client")
    }
}

pub struct ElneoDaemon {
    inner: SharedDaemon,
}

/// Store-layout version written into each profile's data dir.  Dirs written
/// by the matrix-rust-sdk 0.7 daemon carry no marker and are refused rather
/// than migrated: their sqlite state/crypto stores are unreadable by the
/// current SDK.
const STORE_LAYOUT_VERSION: u32 = 2;

impl ElneoDaemon {
    pub fn new(profile: String, events: mpsc::UnboundedSender<OutEvent>) -> Result<Self> {
        let data_dir = get_profile_data_dir(&profile)?;
        check_profile_version(&data_dir, &profile)?;
        std::fs::create_dir_all(&data_dir)?;
        std::fs::write(data_dir.join("VERSION"), STORE_LAYOUT_VERSION.to_string())?;

        Ok(Self {
            inner: Arc::new(Inner {
                profile,
                data_dir,
                client: Mutex::new(None),
                events,
                room_locals: Mutex::new(HashMap::new()),
                syncing: AtomicBool::new(false),
                sync_task: StdMutex::new(None),
                session: StdMutex::new(None),
                verifications: StdMutex::new(HashMap::new()),
                key_watchers: StdMutex::new(HashSet::new()),
                received_keys_task: StdMutex::new(None),
                downloads: StdMutex::new(HashMap::new()),
            }),
        })
    }

    // -- login --------------------------------------------------------------

    /// Wire shape shared by both login paths: the session as an
    /// `updateSession` response.
    fn respond_session(&self, req: Option<u64>, session: &SessionInfo) {
        self.inner.respond(
            req,
            Event::UpdateSession {
                user_id: session.user_id.clone(),
                device_id: session.device_id.clone(),
                access_token: session.access_token.clone(),
            },
        );
    }

    async fn handle_login(
        &self,
        homeserver: String,
        username: String,
        password: String,
        device_name: Option<String>,
        req: Option<u64>,
    ) {
        let result = self
            .login_inner(&homeserver, &username, &password, device_name)
            .await;
        match result {
            Ok(session) => self.respond_session(req, &session),
            Err(e) => {
                error!("Login failed: {e:#}");
                self.inner
                    .ack(req, false, Some(format!("Login failed: {e}")));
            }
        }
    }

    async fn login_inner(
        &self,
        homeserver: &str,
        username: &str,
        password: &str,
        device_name: Option<String>,
    ) -> Result<SessionInfo> {
        let server_name = parse_server_name(homeserver)?;
        let client = self
            .inner
            .build_client(&server_name, Some(homeserver))
            .await?;

        info!("Logging in as {username} to {homeserver}");
        // No `.device_id(...)`: the homeserver generates a fresh device id
        // per login, so each new session is a distinct device — reusing a
        // fixed one made Element treat every re-login as the same known
        // (and already-dismissed) session, skipping its verification
        // prompt.
        let response = client
            .matrix_auth()
            .login_username(username, password)
            .initial_device_display_name(device_name.as_deref().unwrap_or("ElNeo"))
            .send()
            .await
            .context("Login request failed")?;

        info!("Login successful, device_id: {}", response.device_id);
        self.finish_login(
            &client,
            &response.user_id,
            &response.device_id,
            &response.access_token,
        )
        .await
    }

    /// Shared post-login work: persist session, install client, check crypto.
    async fn finish_login(
        &self,
        client: &Client,
        user_id: &matrix_sdk::ruma::OwnedUserId,
        device_id: &matrix_sdk::ruma::OwnedDeviceId,
        access_token: &str,
    ) -> Result<SessionInfo> {
        let session = MatrixSession {
            meta: matrix_sdk::SessionMeta {
                user_id: user_id.to_owned(),
                device_id: device_id.to_owned(),
            },
            tokens: SessionTokens {
                access_token: access_token.to_owned(),
                refresh_token: None,
            },
        };
        self.persist_session(&session).await?;

        let info = SessionInfo {
            user_id: user_id.to_string(),
            device_id: device_id.to_string(),
            access_token: access_token.to_owned(),
        };
        self.inner.set_session(info.clone());
        {
            let mut client_slot = self.inner.client.lock().await;
            *client_slot = Some(client.clone());
            // Handlers attach exactly once per installed client.
            self.inner.add_sync_handlers(client);
        }

        self.setup_encryption(client).await?;
        Ok(info)
    }

    // TODO: key material is stored unencrypted at rest — the access token
    // in session.json, and the Olm/Megolm identity + room keys plus
    // cross-signing material in the sqlite stores.  Look into encrypted
    // storage (OS keyring/secret service, or wrapping with an SSSS-derived
    // key) later; not a problem right now.
    async fn persist_session(&self, session: &MatrixSession) -> Result<()> {
        let session_file = self.inner.data_dir.join("session.json");
        let session_json = serde_json::to_string_pretty(session)?;
        // Atomic (media.rs's .part-then-rename): a daemon killed
        // mid-write once left a truncated session.json that wedged the
        // profile across restarts — `restore_session` quarantines the
        // result, but never having the corrupt file is better.
        crate::media::write_atomic(&session_file, session_json.as_bytes())
    }

    async fn setup_encryption(&self, client: &Client) -> Result<()> {
        if let Some(event) = verification::cross_signing_event(client).await {
            if let Event::UpdateCrossSigningStatus { enabled: false, .. } = &event {
                info!("Cross-signing not set up yet");
            }
            self.inner.emit(event);
        }
        // Invisible crypto (see `auto_crypto_onboarding`): a fresh
        // account picks up keys, recovery and key backup on its own,
        // a re-login adopts the stored recovery key.  Detached — the
        // dance takes seconds (uploads, waiting for backups) and must
        // not hold up login's response.
        let daemon = self.inner.clone();
        let background = client.clone();
        tokio::spawn(async move {
            verification::auto_crypto_onboarding(&daemon, &background).await;
        });
        Ok(())
    }

    async fn handle_setup_cross_signing(&self, req: Option<u64>) {
        let Some(client) = self.inner.client().await else {
            self.inner.ack(req, false, Some("No active session".into()));
            return;
        };
        let encryption = client.encryption();
        // Bootstrap only when the account has no cross-signing identity at
        // all.  Unconditional bootstrap replaces existing account keys (e.g.
        // ones set up by another client), resetting the trust chain and
        // every other device's verification.  For an account that already
        // has cross-signing, the right move is to verify this device
        // against an existing one, not to create new keys.
        info!("Bootstrapping cross-signing (if needed)");
        if let Err(e) = encryption.bootstrap_cross_signing_if_needed(None).await {
            error!("Failed to bootstrap cross-signing: {e:#}");
            self.inner.ack(
                req,
                false,
                Some(format!("Cross-signing bootstrap failed: {e}")),
            );
            return;
        }
        match verification::cross_signing_event(&client).await {
            Some(event @ Event::UpdateCrossSigningStatus { enabled: true, .. }) => {
                info!("Cross-signing setup complete");
                self.inner.respond(req, event);
            }
            Some(_) => {
                // Any other state — in practice `enabled: false`: the
                // account already has cross-signing keys we don't hold
                // and bootstrap was skipped.  The user should verify
                // this device against an existing one to adopt them.
                info!("Cross-signing already exists on the account; skipped bootstrap");
                self.inner.ack(
                    req,
                    false,
                    Some(
                        "This account already has cross-signing keys — \
verify this device against an existing one (M-x elneo-verify-device) instead"
                            .into(),
                    ),
                );
            }
            // The crypto machine not being ready after a successful
            // bootstrap is not a success either.
            None => {
                self.inner.ack(
                    req,
                    false,
                    Some("Cross-signing state unavailable after bootstrap".into()),
                );
            }
        }
    }

    async fn handle_get_cross_signing_status(&self, req: Option<u64>) {
        let Some(client) = self.inner.client().await else {
            self.inner.ack(req, false, Some("No active session".into()));
            return;
        };
        match verification::cross_signing_event(&client).await {
            Some(event) => self.inner.respond(req, event),
            // No olm machine (yet): plain disabled beats a bare ok with
            // no payload.
            None => self.inner.respond(
                req,
                Event::UpdateCrossSigningStatus {
                    enabled: false,
                    trusted: false,
                },
            ),
        }
    }

    async fn handle_get_session(&self, req: Option<u64>) {
        if let Some(session) = self.inner.session() {
            self.inner.respond(
                req,
                Event::UpdateSession {
                    user_id: session.user_id,
                    device_id: session.device_id,
                    access_token: session.access_token,
                },
            );
            // Emacs asks for the session on every (re)connect; piggyback the
            // trust and recovery state of the restored session so a fresh
            // Emacs instance knows them without extra commands.
            if self.inner.client().await.is_some() {
                verification::emit_cross_signing_status(&self.inner).await;
                verification::emit_recovery_state(&self.inner).await;
            }
        } else {
            self.inner.ack(req, false, Some("No active session".into()));
        }
    }

    async fn handle_logout(&self, req: Option<u64>) {
        let Some(client) = self.inner.client().await else {
            self.inner.ack(req, false, Some("No active session".into()));
            return;
        };
        let result = client.matrix_auth().logout().await;
        match result {
            Ok(_) => {
                // Stop the sync loop BEFORE dropping the client: the loop
                // retries forever on error (a logged-out token just errors),
                // so without an abort it would keep `syncing` true across
                // the re-login and no loop would ever serve the new client.
                self.inner.stop_sync();
                let session_file = self.inner.data_dir.join("session.json");
                let _ = std::fs::remove_file(session_file);
                // Drop the live client and the cached session too: a
                // logged-out daemon must not answer session-dependent
                // commands as if it were still logged in.
                *self.inner.client.lock().await = None;
                self.inner.clear_session();
                info!("Logged out");
                self.inner.ack(req, true, None);
            }
            Err(e) => {
                error!("Logout failed: {e:#}");
                self.inner
                    .ack(req, false, Some(format!("Logout failed: {e}")));
            }
        }
    }

    async fn restore_session(&self) -> Result<bool> {
        let session_file = self.inner.data_dir.join("session.json");
        if !session_file.exists() {
            return Ok(false);
        }

        // Read + parse up front, so a truncated or malformed file (a
        // daemon killed mid-write, back when persist_session was a
        // plain write) can be quarantined: left in place it would
        // wedge the profile forever — every restart logged the same
        // error while getSession answered "No active session".  The
        // SDK restore below is different: it can fail transiently (a
        // flaky network must not log the user out), so that path keeps
        // the file untouched.
        let session: MatrixSession = {
            let read = || -> Result<MatrixSession> {
                Ok(serde_json::from_str(&std::fs::read_to_string(
                    &session_file,
                )?)?)
            };
            match read() {
                Ok(session) => session,
                Err(e) => {
                    let bad = self.inner.data_dir.join("session.json.bad");
                    match std::fs::rename(&session_file, &bad) {
                        Ok(()) => error!(
                            "Session restore failed: {e:#}; the corrupt session.json is \
                             preserved at {} — inspect or delete it, the next start opens \
                             without a session",
                            bad.display()
                        ),
                        Err(rename_err) => error!(
                            "Session restore failed: {e:#}; moving the corrupt \
                             session.json aside failed too: {rename_err:#}"
                        ),
                    }
                    return Ok(false);
                }
            }
        };

        let server_name = session.meta.user_id.server_name().to_owned();
        let client = self.inner.build_client(&server_name, None).await?;
        client.restore_session(session.clone()).await?;

        let info = SessionInfo {
            user_id: session.meta.user_id.to_string(),
            device_id: session.meta.device_id.to_string(),
            access_token: session.tokens.access_token.clone(),
        };
        self.inner.set_session(info.clone());
        {
            let mut client_slot = self.inner.client.lock().await;
            *client_slot = Some(client.clone());
            // Handlers attach exactly once per installed client.
            self.inner.add_sync_handlers(&client);
        }

        // The restored session gets the same invisible bring-up a login
        // gets: a fresh account bootstraps in the background, a re-login
        // adopts the stored recovery key.  The daemon's normal start is a
        // restore — without this call such a session never heals.
        self.setup_encryption(&client).await?;

        info!("Session restored for user {}", session.meta.user_id);
        self.inner.emit(Event::UpdateSession {
            user_id: session.meta.user_id.to_string(),
            device_id: session.meta.device_id.to_string(),
            access_token: session.tokens.access_token,
        });

        Ok(true)
    }

    // -- command dispatch ---------------------------------------------------

    async fn handle_command(&self, req: Option<u64>, cmd: Command) {
        match cmd {
            Command::Login {
                homeserver,
                username,
                password,
                device_name,
            } => {
                self.handle_login(homeserver, username, password, device_name, req)
                    .await
            }
            Command::Logout => self.handle_logout(req).await,
            Command::GetSession => self.handle_get_session(req).await,
            Command::GetCrossSigningStatus => self.handle_get_cross_signing_status(req).await,
            Command::SetupCrossSigning => self.handle_setup_cross_signing(req).await,
            Command::Sync | Command::StartSync => {
                let daemon = self.inner.clone();
                if let Err(e) = sync::handle_start_sync(daemon, req).await {
                    error!("startSync failed: {e:#}");
                    self.inner
                        .ack(req, false, Some(format!("Sync failed: {e}")));
                }
            }
            Command::StopSync => {
                self.inner.stop_sync();
                info!("Sync loop stopped on client request");
                self.inner.ack(req, true, None);
            }
            Command::GetRooms => sync::handle_get_rooms(self.inner.clone(), req).await,
            Command::GetRoomMembers { room_id } => {
                sync::handle_get_room_members(self.inner.clone(), req, room_id).await
            }
            Command::GetRoomHierarchy {
                room_id,
                from,
                limit,
            } => {
                sync::handle_get_room_hierarchy(self.inner.clone(), req, room_id, from, limit).await
            }
            Command::GetRoomSpaces { room_id } => {
                sync::handle_get_room_spaces(self.inner.clone(), req, room_id).await
            }
            Command::AcceptInvite { room_id } => {
                sync::handle_accept_invite(self.inner.clone(), req, room_id).await
            }
            Command::DeclineInvite { room_id } => {
                sync::handle_decline_invite(self.inner.clone(), req, room_id).await
            }
            Command::JoinRoom {
                room_id_or_alias,
                via,
            } => sync::handle_join_room(self.inner.clone(), req, room_id_or_alias, via).await,
            Command::LeaveRoom { room_id } => {
                sync::handle_leave_room(self.inner.clone(), req, room_id).await
            }
            Command::ForgetRoom { room_id } => {
                sync::handle_forget_room(self.inner.clone(), req, room_id).await
            }
            Command::InviteUser { room_id, user_id } => {
                sync::handle_invite_user(self.inner.clone(), req, room_id, user_id).await
            }
            Command::KickUser {
                room_id,
                user_id,
                reason,
            } => sync::handle_kick_user(self.inner.clone(), req, room_id, user_id, reason).await,
            Command::BanUser {
                room_id,
                user_id,
                reason,
            } => sync::handle_ban_user(self.inner.clone(), req, room_id, user_id, reason).await,
            Command::UnbanUser { room_id, user_id } => {
                sync::handle_unban_user(self.inner.clone(), req, room_id, user_id).await
            }
            Command::SetRoomName { room_id, name } => {
                sync::handle_set_room_name(self.inner.clone(), req, room_id, name).await
            }
            Command::SetRoomTopic { room_id, topic } => {
                sync::handle_set_room_topic(self.inner.clone(), req, room_id, topic).await
            }
            Command::SetOwnDisplayName { room_id, name } => {
                sync::handle_set_own_display_name(self.inner.clone(), req, room_id, name).await
            }
            Command::CreateRoom {
                name,
                alias,
                public,
                topic,
                invites,
                is_direct,
                encrypted,
            } => {
                sync::handle_create_room(
                    self.inner.clone(),
                    req,
                    name,
                    alias,
                    public,
                    topic,
                    invites,
                    is_direct,
                    encrypted,
                )
                .await
            }
            Command::SetDisplayName { name } => {
                sync::handle_set_display_name(self.inner.clone(), req, name).await
            }
            Command::SetAvatar { local_path } => {
                sync::handle_set_avatar(self.inner.clone(), req, local_path).await
            }
            Command::SetRoomAvatar {
                room_id,
                local_path,
            } => sync::handle_set_room_avatar(self.inner.clone(), req, room_id, local_path).await,
            Command::RoomPermissions { room_id } => {
                sync::handle_room_permissions(self.inner.clone(), req, room_id).await
            }
            Command::GetProfile => sync::handle_get_profile(self.inner.clone(), req).await,
            Command::SendMessage {
                room_id,
                body,
                formatted_body,
                reply_to,
                thread_root,
                replaces,
                mentions,
                room_mentions,
            } => {
                sync::handle_send_message(
                    self.inner.clone(),
                    req,
                    room_id,
                    body,
                    formatted_body,
                    reply_to,
                    thread_root,
                    mentions,
                    room_mentions,
                    replaces,
                )
                .await
            }
            Command::RedactMessage {
                room_id,
                event_id,
                reason,
            } => {
                sync::handle_redact_message(self.inner.clone(), req, room_id, event_id, reason)
                    .await
            }
            Command::SendReaction {
                room_id,
                event_id,
                key,
                remove,
            } => {
                sync::handle_send_reaction(self.inner.clone(), req, room_id, event_id, key, remove)
                    .await
            }
            Command::PinMessage {
                room_id,
                event_id,
                unpin,
            } => sync::handle_pin_message(self.inner.clone(), req, room_id, event_id, unpin).await,
            Command::PollCreate {
                room_id,
                question,
                options,
                max_selections,
                disclosed,
            } => {
                sync::handle_poll_create(
                    self.inner.clone(),
                    req,
                    room_id,
                    question,
                    options,
                    max_selections,
                    disclosed,
                )
                .await
            }
            Command::PollVote {
                room_id,
                event_id,
                selections,
            } => {
                sync::handle_poll_vote(self.inner.clone(), req, room_id, event_id, selections).await
            }
            Command::PollEnd { room_id, event_id } => {
                sync::handle_poll_end(self.inner.clone(), req, room_id, event_id).await
            }
            Command::SendImage {
                room_id,
                path,
                thread_root,
                mime,
                info,
            } => {
                sync::handle_send_attachment(
                    self.inner.clone(),
                    req,
                    room_id,
                    path,
                    "image",
                    thread_root,
                    mime,
                    info,
                )
                .await
            }
            Command::SendFile {
                room_id,
                path,
                thread_root,
                mime,
                info,
            } => {
                sync::handle_send_attachment(
                    self.inner.clone(),
                    req,
                    room_id,
                    path,
                    "file",
                    thread_root,
                    mime,
                    info,
                )
                .await
            }
            Command::GetRoomMessages {
                room_id,
                limit,
                from,
                filter,
            } => {
                sync::handle_get_room_messages(
                    self.inner.clone(),
                    req,
                    room_id,
                    limit,
                    from,
                    filter,
                )
                .await
            }
            Command::GetThreadMessages {
                room_id,
                thread_root,
                limit,
                from,
            } => {
                sync::handle_get_thread_messages(
                    self.inner.clone(),
                    req,
                    room_id,
                    thread_root,
                    limit,
                    from,
                )
                .await
            }
            Command::MarkRoomRead {
                room_id,
                event_id,
                public_receipt,
            } => {
                sync::handle_mark_room_read(
                    self.inner.clone(),
                    req,
                    room_id,
                    event_id,
                    public_receipt,
                )
                .await
            }
            Command::GetRoomReceipts { room_id } => {
                sync::handle_get_room_receipts(self.inner.clone(), req, room_id).await
            }
            Command::DownloadMedia {
                source,
                format,
                filename,
            } => {
                media::handle_download_media(self.inner.clone(), req, source, format, filename)
                    .await
            }
            Command::CancelDownload { source, format } => {
                media::handle_cancel_download(self.inner.clone(), req, source, format)
            }
            Command::GetMediaFile { source, format } => {
                media::handle_get_media_file(self.inner.clone(), req, source, format)
            }
            Command::VerifyDevice { user_id, device_id } => {
                verification::handle_verify_device(self.inner.clone(), req, user_id, device_id)
                    .await
            }
            Command::GetVerificationRequests => {
                verification::handle_get_verification_requests(self.inner.clone(), req).await
            }
            Command::GetDevices => verification::handle_get_devices(self.inner.clone(), req).await,
            Command::DeleteDevice {
                device_id,
                password,
            } => {
                verification::handle_delete_device(self.inner.clone(), req, device_id, password)
                    .await
            }
            Command::AcceptVerification { flow_id } => {
                verification::handle_accept_verification(self.inner.clone(), req, flow_id).await
            }
            Command::StartSas { flow_id } => {
                verification::handle_start_sas(self.inner.clone(), req, flow_id).await
            }
            Command::ConfirmSas { flow_id } => {
                verification::handle_confirm_sas(self.inner.clone(), req, flow_id).await
            }
            Command::CancelVerification { flow_id } => {
                verification::handle_cancel_verification(self.inner.clone(), req, flow_id).await
            }
            Command::EnableRecovery => {
                verification::handle_enable_recovery(self.inner.clone(), req).await
            }
            Command::RecoverRecoveryKey { key } => {
                verification::handle_recover_recovery_key(self.inner.clone(), req, key).await
            }
            Command::GetRecoveryState => {
                verification::handle_get_recovery_state(self.inner.clone(), req).await
            }
            Command::RotateRecoveryKey { old_key } => {
                verification::handle_rotate_recovery_key(self.inner.clone(), req, old_key).await
            }
            Command::DisableRecovery => {
                verification::handle_disable_recovery(self.inner.clone(), req).await
            }
        }
    }

    // -- run loop -----------------------------------------------------------

    pub async fn run(&self) -> Result<()> {
        info!(
            "Matrix daemon starting with profile '{}'",
            self.inner.profile
        );
        info!("Data directory: {}", self.inner.data_dir.display());

        let restored = self.restore_session().await;
        match restored {
            Ok(true) => info!("Session restored successfully"),
            Ok(false) => info!("No existing session found"),
            Err(e) => error!("Session restore failed: {e:#}"),
        }

        // Reader: blocking stdin reads on a dedicated thread.  Frames are
        // parsed there, once, and the channel carries the parsed command
        // (or its parse failure).
        let (cmd_tx, mut cmd_rx) =
            mpsc::unbounded_channel::<(Option<u64>, Result<Command, String>)>();
        tokio::task::spawn_blocking(move || read_commands(cmd_tx));

        while let Some((req, cmd)) = cmd_rx.recv().await {
            match cmd {
                Ok(cmd) => {
                    // Commands run detached: a handler held on a slow
                    // homeserver call (a createRoom stuck in a
                    // minutes-long SDK retry cycle once wedged the
                    // whole pipeline, starving the UI's history
                    // fetches) must not block the ones behind it.
                    // Responses route by request id, so out-of-order
                    // completion is harmless.
                    let daemon = ElneoDaemon {
                        inner: self.inner.clone(),
                    };
                    tokio::spawn(async move { daemon.handle_command(req, cmd).await });
                }
                Err(e) => {
                    error!("Failed to parse command: {e}");
                    // Ack when the frame at least identified itself, so a
                    // waiting Emacs callback fails fast instead of sitting
                    // until its timeout.  A frame with no recoverable id
                    // cannot be routed anywhere; all we can do is log.
                    if let Some(req) = req {
                        self.inner
                            .ack(Some(req), false, Some(format!("Invalid command: {e}")));
                    }
                }
            }
        }

        debug!("Input closed, daemon exiting");
        Ok(())
    }
}

fn get_profile_data_dir(profile: &str) -> Result<std::path::PathBuf> {
    Ok(migrate_data_base()?.join(profile))
}

/// The data base for this daemon: `ProjectDirs::from("fi", "aard", "elneo")`
/// — `~/.local/share/elneo` on XDG systems, the application-data directory
/// of the `fi.aard.elneo` bundle id on macOS.
///
/// Until the rename the base was
/// `ProjectDirs::from("com", "emacs", "matrix-client")`, i.e.
/// `~/.local/share/matrix-client`.  Before anything opens a profile
/// directory under the new base, an existing old base is moved in whole
/// (`std::fs::rename` — profiles, media cache, crypto stores and
/// `session.json` ride along; the store layout does not change).  The
/// cases, in order:
///
/// - old base exists, new base does not: the rename moves it; logged.
/// - only the new base exists: fresh install or already migrated —
///   nothing to do (this makes the migration idempotent).
/// - both exist and the new base holds a session of its own: never
///   merge — warn, and keep using the new base.
/// - both exist but the new base has no session while the old one
///   does (a stray empty dir, the elisp consumers creating it early,
///   a pre-created symlink to another disk): the old base's entries
///   are adopted into the new one, loudly, naming both paths on any
///   failure — an empty intentional-looking base must not strand a
///   real session.
/// - the rename fails for a real reason (typically a cross-filesystem
///   target): warn loudly and keep using the old base for this run; the
///   next start tries again.
/// - the rename fails with the old base already gone and the new base
///   present (the check passed, then a concurrent mover's rename landed
///   in the window — the multi-profile case, daemons starting in
///   parallel): the move already happened; use the new base.
///
/// Idempotent by construction: both sides are re-checked immediately
/// before the rename, and a lost rename race is re-checked after the
/// failure, so another process racing for the same move simply loses
/// ("first mover wins", the loser follows the winner).
/// Whether BASE holds at least one profile session.  Profiles are
/// top-level entries carrying their own session.json; that is the
/// whole of "has data worth migrating" here (drafts.el and the media
/// cache ride along, but a base without a session holds nothing a
/// user would miss).
fn base_has_sessions(base: &std::path::Path) -> bool {
    std::fs::read_dir(base)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .any(|e| e.path().join("session.json").exists())
        })
        .unwrap_or(false)
}

fn migrate_data_base() -> Result<std::path::PathBuf> {
    let old_base = directories::ProjectDirs::from("com", "emacs", "matrix-client")
        .map(|dirs| dirs.data_dir().to_path_buf());
    let dirs = directories::ProjectDirs::from("fi", "aard", "elneo")
        .context("Could not determine data directory")?;
    migrate_data_base_from(old_base, dirs.data_dir().to_path_buf())
}

/// The move itself, parameterized over the two bases: tests inject
/// tempdir paths instead of mutating the process-global XDG_DATA_HOME
/// (which macOS ProjectDirs ignores, so the env seam cannot drive the
/// test where it is developed).
fn migrate_data_base_from(
    old_base: Option<std::path::PathBuf>,
    new_base: std::path::PathBuf,
) -> Result<std::path::PathBuf> {
    if let Some(old) = old_base {
        if old.exists() && !new_base.exists() {
            match std::fs::rename(&old, &new_base) {
                Ok(()) => {
                    info!(
                        "Data directory moved: {} -> {}",
                        old.display(),
                        new_base.display()
                    );
                    return Ok(new_base);
                }
                // Graceful degradation: session integrity over the new path.
                Err(e) => {
                    // But not if a concurrent mover just beat us to the
                    // rename: the check above passed, and by rename time
                    // the old base was already gone (ENOENT).  The data
                    // then lives under the new base — using the old one
                    // would see an empty directory.
                    if !old.exists() && new_base.exists() {
                        info!(
                            "Data directory was moved to {} by a concurrent \
                             process; using it ({e})",
                            new_base.display()
                        );
                        return Ok(new_base);
                    }
                    warn!(
                        "Could not move the data directory {} to {} ({e}); \
                         keeping the old one for this run",
                        old.display(),
                        new_base.display()
                    );
                    return Ok(old);
                }
            }
        }
        if old.exists() && new_base.exists() {
            let (old_sessions, new_sessions) =
                (base_has_sessions(&old), base_has_sessions(&new_base));
            if old_sessions && !new_sessions {
                // The new base pre-exists but holds no session of its
                // own (a stray empty dir; the daemon-independent elisp
                // consumers creating it early; a symlinked target): an
                // intentional empty base must not strand the old
                // session — adopt the old base's entries into it.
                let mut moved = 0usize;
                let mut first_err = None;
                for entry in std::fs::read_dir(&old)
                    .map_err(|e| anyhow::anyhow!("Could not read {}: {e}", old.display()))?
                {
                    let entry = entry
                        .map_err(|e| anyhow::anyhow!("Could not read {}: {e}", old.display()))?;
                    match std::fs::rename(entry.path(), new_base.join(entry.file_name())) {
                        Ok(()) => moved += 1,
                        Err(e) => {
                            first_err = Some((entry.path(), e));
                            break;
                        }
                    }
                }
                match first_err {
                    // Abort loudly, naming both paths — the session is
                    // either now under the new base or still under the
                    // old one, and the daemon must not boot the other.
                    Some((path, e)) => anyhow::bail!(
                        "Could not adopt {} into the pre-created data \
                         directory {} (failed at {}: {e})",
                        old.display(),
                        new_base.display(),
                        path.display()
                    ),
                    None => {
                        // The per-entry moves leave the old base's
                        // own empty shell; the whole-base rename
                        // below (the ordinary path) does not.
                        let _ = std::fs::remove_dir(&old);
                        info!(
                            "Data directory moved: {} entries of {} -> \
                             pre-created {}",
                            moved,
                            old.display(),
                            new_base.display()
                        );
                        return Ok(new_base);
                    }
                }
            }
            warn!(
                "Both data directories exist ({} and {}); using the new one, \
                 not merging",
                old.display(),
                new_base.display()
            );
        }
    }
    Ok(new_base)
}

/// Refuse data dirs we cannot safely load:
///
/// - a `VERSION` marker from a different store layout, or
/// - no marker at all but existing 0.7-era content (`session.json`/`store/`).
///
/// Fresh (empty or missing) dirs pass and get the current marker written.
fn check_profile_version(data_dir: &std::path::Path, profile: &str) -> Result<()> {
    if !data_dir.exists() {
        return Ok(());
    }
    match std::fs::read_to_string(data_dir.join("VERSION")) {
        Ok(marker) => {
            let marker = marker.trim().parse::<u32>().unwrap_or(0);
            if marker != STORE_LAYOUT_VERSION {
                return Err(anyhow::anyhow!(
                    "Profile '{profile}' was written by an incompatible daemon version \
                     (store layout {marker}, expected {STORE_LAYOUT_VERSION}). \
                     Run M-x elneo-forget-profile and log in again."
                ));
            }
        }
        Err(_) => {
            if data_dir.join("session.json").exists() || data_dir.join("store").exists() {
                return Err(anyhow::anyhow!(
                    "Profile '{profile}' was written by the old daemon (matrix-rust-sdk 0.7) \
                     and cannot be loaded by this one. \
                     Run M-x elneo-forget-profile and log in again."
                ));
            }
        }
    }
    Ok(())
}

fn parse_server_name(homeserver: &str) -> Result<matrix_sdk::ruma::OwnedServerName> {
    matrix_sdk::sanitize_server_name(homeserver)
        .map_err(|e| anyhow::anyhow!("Invalid homeserver name: {e}"))
}

/// Upper bound on one command frame.  The size comes straight off the
/// wire; without a cap a bogus header makes the daemon allocate that
/// many bytes up front.
const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;

/// Parse one frame body: `@req` plus the command, or the parse failure.
/// The request id is extracted first so a well-formed frame that fails
/// command deserialization can still be acked to the right waiter.
/// A payload that is not even valid JSON (or not valid UTF-8) carries no
/// extractable `@req`, so its request can only time out client-side — but
/// the frame was size-delimited, so the stream stays aligned.
fn parse_frame(buf: &[u8]) -> (Option<u64>, Result<Command, String>) {
    let value = match serde_json::from_slice::<Value>(buf) {
        Ok(v) => v,
        Err(e) => return (None, Err(format!("Invalid JSON: {e}"))),
    };
    let req = value.get("@req").and_then(|v| v.as_u64());
    let cmd = serde_json::from_value::<Command>(value).map_err(|e| e.to_string());
    (req, cmd)
}

/// Blocking stdin reader: parse `send <size>\n<json>\n` frames and forward
/// the parsed commands to the command channel.  Runs until EOF.
fn read_commands(cmd_tx: mpsc::UnboundedSender<(Option<u64>, Result<Command, String>)>) {
    let stdin = std::io::stdin();
    let mut reader = BufReader::new(stdin.lock());

    loop {
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => break, // EOF
            Ok(_) => {}
            Err(e) => {
                error!("stdin read error: {e}");
                break;
            }
        }

        // One policy for every malformed frame-boundary line: bail out.
        // A garbage header means framing is already lost — either the
        // producer is broken or an earlier frame lied about its size —
        // and payload bytes would be reinterpreted as headers forever.
        // Dropping the connection surfaces the error immediately on
        // the Emacs side (process sentinel) instead of a request
        // timeout, and `elneo-server-start` brings the daemon back.
        let Some(rest) = line.strip_prefix("send ") else {
            error!("Expected a `send <size>` frame header, got {line:?}, dropping connection");
            break;
        };

        let size: usize = match rest.trim().parse() {
            Ok(s) if s <= MAX_FRAME_BYTES => s,
            Ok(s) => {
                // The frame cannot be trusted any further: bail out
                // rather than try to resync the stream mid-payload.
                error!("Frame of {s} bytes exceeds the {MAX_FRAME_BYTES} cap, dropping connection");
                break;
            }
            Err(_) => {
                error!("Bad frame header {line:?}, dropping connection");
                break;
            }
        };

        let mut json_buf = vec![0u8; size];
        // Read from the same buffered reader as the header line, or buffered
        // bytes would be lost.
        if let Err(e) = reader.read_exact(&mut json_buf) {
            error!("Truncated frame: {e}");
            break;
        }
        let mut newline = [0u8; 1];
        if let Err(e) = reader.read_exact(&mut newline) {
            error!("Truncated frame trailer: {e}");
            break;
        }

        let (req, cmd) = parse_frame(&json_buf);
        if cmd_tx.send((req, cmd)).is_err() {
            break;
        }
    }
}

/// The single writer thread: owns stdout, frames + flushes each event.
///
/// A plain OS thread, not a tokio task: a blocked write (Emacs stopped
/// reading, pipe full) parks this thread alone instead of stalling the
/// async runtime.  And if stdout dies, so does the daemon — there is
/// nothing left to serve.
fn writer_thread(mut ev_rx: mpsc::UnboundedReceiver<OutEvent>) {
    let stdout = std::io::stdout();
    while let Some(out) = ev_rx.blocking_recv() {
        let json = out.to_json();
        let payload = serde_json::to_string(&json).expect("Event serialization cannot fail");
        let mut out = stdout.lock();
        if writeln!(out, "event {}\n{}", payload.len(), payload).is_err() || out.flush().is_err() {
            error!("stdout write failed: the client is gone; exiting");
            std::process::exit(1);
        }
    }
}

pub fn spawn_writer(events: mpsc::UnboundedReceiver<OutEvent>) {
    std::thread::Builder::new()
        .name("writer".into())
        .spawn(move || writer_thread(events))
        .expect("spawning the writer thread cannot fail");
}

#[cfg(test)]
mod tests {
    use super::{check_profile_version, migrate_data_base_from, STORE_LAYOUT_VERSION};

    /// The rename's data-base migration, driven over explicit tempdir
    /// bases (the real `migrate_data_base` resolves both through
    /// ProjectDirs, which on macOS ignores XDG_DATA_HOME — the bases
    /// are injected, not the env): fresh install stays put, an old
    /// base moves whole, the move is idempotent, and both bases
    /// coexisting warns without merging.
    /// The parallel-daemons race (rename fails ENOENT because a
    /// concurrent mover already took the old base) has no
    /// deterministic seam in a single-threaded test —
    /// `migrate_data_base_from` re-checks the bases after the failed
    /// rename and follows the winner by inspection of that branch.
    #[test]
    fn migration_moves_the_old_base_once_and_never_merges() {
        let tmp = tempfile::tempdir().unwrap();
        let data = tmp.path().join("data");
        let old = data.join("matrix-client");
        let new_base = data.join("elneo");

        // Fresh install: neither base exists, and the new base resolves
        // without anything being created yet.
        let fresh = migrate_data_base_from(Some(old.clone()), new_base.clone()).unwrap();
        assert_eq!(fresh, new_base);
        assert!(!new_base.exists(), "a fresh pass creates nothing");

        // A pre-rename install: the old base moves whole.
        std::fs::create_dir_all(old.join("default/store")).unwrap();
        std::fs::write(old.join("default/session.json"), "{}").unwrap();
        let moved = migrate_data_base_from(Some(old.clone()), new_base.clone()).unwrap();
        assert_eq!(moved, new_base);
        assert!(!old.exists(), "the old base must be gone after the move");
        assert!(new_base.join("default/store").exists());

        // Idempotent: the next pass neither moves nor recreates.
        let again = migrate_data_base_from(Some(old.clone()), new_base.clone()).unwrap();
        assert_eq!(again, new_base);
        assert!(!old.exists());

        // An old base reappearing next to the migrated one: never
        // merged, the new base keeps being used.
        std::fs::create_dir_all(&old).unwrap();
        let both = migrate_data_base_from(Some(old.clone()), new_base.clone()).unwrap();
        assert_eq!(both, new_base);
        assert!(old.exists(), "the both-exist case must not delete");

        // A pre-created new base WITHOUT a session (stray empty dir,
        // the elisp consumers creating it early, a symlinked target):
        // the old base's entries are adopted into it — an empty new
        // base must not strand the old session.  (Same test fn: these
        // cases rebuild the bases and must run in serialization with
        // the flow above.)
        std::fs::remove_dir_all(&new_base).unwrap();
        std::fs::remove_dir_all(&old).unwrap();
        std::fs::create_dir_all(old.join("default/store")).unwrap();
        std::fs::write(old.join("default/session.json"), "{}").unwrap();
        std::fs::create_dir(&new_base).unwrap();
        let adopted = migrate_data_base_from(Some(old.clone()), new_base.clone()).unwrap();
        assert_eq!(adopted, new_base);
        assert!(
            new_base.join("default/store").exists(),
            "the old base's entries must be adopted into the new base"
        );
        assert!(!old.exists(), "the adoption moves, it does not copy");
        let again = migrate_data_base_from(Some(old.clone()), new_base.clone()).unwrap();
        assert_eq!(again, new_base);

        // Both bases holding sessions: still non-merging.
        std::fs::create_dir_all(old.join("default/store")).unwrap();
        std::fs::write(old.join("default/session.json"), "{}").unwrap();
        let both = migrate_data_base_from(Some(old.clone()), new_base.clone()).unwrap();
        assert_eq!(both, new_base);
        assert!(old.exists(), "the both-have-sessions case must not delete");
    }

    /// A profile dir that does not exist: fresh start, must pass.
    #[test]
    fn missing_dir_is_fresh() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("no-such-profile");
        assert!(check_profile_version(&dir, "main").is_ok());
    }

    /// An existing but empty dir: also fresh, must pass.
    #[test]
    fn empty_dir_is_fresh() {
        let tmp = tempfile::tempdir().unwrap();
        assert!(check_profile_version(tmp.path(), "main").is_ok());
    }

    /// Current marker, with and without surrounding whitespace / newline
    /// (the daemon writes it bare, but tolerate what editors leave behind).
    #[test]
    fn current_marker_ok() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(tmp.path().join("VERSION"), STORE_LAYOUT_VERSION.to_string()).unwrap();
        assert!(check_profile_version(tmp.path(), "main").is_ok());

        std::fs::write(
            tmp.path().join("VERSION"),
            format!("  {}\n", STORE_LAYOUT_VERSION),
        )
        .unwrap();
        assert!(check_profile_version(tmp.path(), "main").is_ok());
    }

    /// A marker from a different (future or past) layout: refuse, naming the
    /// layout, the profile, and the escape hatch.
    #[test]
    fn wrong_marker_refused() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(tmp.path().join("VERSION"), "1").unwrap();
        let err = check_profile_version(tmp.path(), "work")
            .unwrap_err()
            .to_string();
        assert!(err.contains("store layout 1"), "err: {err}");
        assert!(
            err.contains(&format!("expected {STORE_LAYOUT_VERSION}")),
            "err: {err}"
        );
        assert!(err.contains("'work'"), "err: {err}");
        assert!(err.contains("elneo-forget-profile"), "err: {err}");
    }

    /// A garbage marker is not any layout we know: refuse rather than
    /// treat as fresh.
    #[test]
    fn garbage_marker_refused() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(tmp.path().join("VERSION"), "not-a-number").unwrap();
        let err = check_profile_version(tmp.path(), "main")
            .unwrap_err()
            .to_string();
        assert!(err.contains("store layout 0"), "err: {err}");
        assert!(err.contains("elneo-forget-profile"), "err: {err}");
    }

    /// No marker but 0.7-era content (session.json): the old-SDK case.
    #[test]
    fn old_sdk_dir_refused() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(tmp.path().join("session.json"), "{}").unwrap();
        let err = check_profile_version(tmp.path(), "work")
            .unwrap_err()
            .to_string();
        assert!(err.contains("matrix-rust-sdk 0.7"), "err: {err}");
        assert!(err.contains("'work'"), "err: {err}");
        assert!(err.contains("elneo-forget-profile"), "err: {err}");
    }

    /// No marker and only a store/ dir: also unmistakably old.
    #[test]
    fn old_store_dir_refused() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::create_dir(tmp.path().join("store")).unwrap();
        assert!(check_profile_version(tmp.path(), "main").is_err());
    }
}
