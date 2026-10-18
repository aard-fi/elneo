//! Interactive device verification: SAS/emoji flows and key recovery.
//!
//! The sync loop feeds all verification to-device events into the SDK's
//! crypto machine; this module only observes: an event handler discovers
//! incoming `m.key.verification.request` to-device events, each tracked
//! request gets a watcher task on its `changes()` stream, and SAS flows get
//! a nested watcher for the emoji/decimal short auth string.
//!
//! Emacs drives the flow with commands (accept/startSas/confirmSas/…) and
//! renders `updateVerificationRequest` / `updateVerificationEmojis` events.
//!
//! Pending requests do not survive a daemon restart: they live in
//! to-device events that this side's store consumed on delivery.  After
//! a restart the other device simply re-requests — from Emacs the flow
//! list starts empty and the incoming request reappears.

use std::sync::Arc;

use futures::{future::join_all, pin_mut, StreamExt};
use matrix_sdk::encryption::verification::{
    SasState, SasVerification, Verification, VerificationRequest, VerificationRequestState,
};
use matrix_sdk::ruma::api::client::uiaa;
use matrix_sdk::ruma::events::key::verification::request::ToDeviceKeyVerificationRequestEvent;
use matrix_sdk::ruma::{OwnedDeviceId, OwnedUserId};
use matrix_sdk::Client;
use tracing::{debug, error, info, warn};

use crate::daemon::SharedDaemon;
use crate::protocol::{DeviceSummary, Event, OutEvent};

/// Look up a tracked verification request by flow id.
fn tracked_request(daemon: &SharedDaemon, flow_id: &str) -> Option<VerificationRequest> {
    daemon
        .verifications
        .lock()
        .ok()
        .and_then(|map| map.get(flow_id).cloned())
}

fn remove_tracked(daemon: &SharedDaemon, flow_id: &str) {
    if let Ok(mut map) = daemon.verifications.lock() {
        map.remove(flow_id);
    }
}

/// Register the to-device event handler that discovers incoming requests.
/// Called from `add_sync_handlers`, before the sync loop starts.
pub fn add_verification_handlers(daemon: &SharedDaemon, client: &Client) {
    let d = Arc::clone(daemon);
    client.add_event_handler(move |ev: ToDeviceKeyVerificationRequestEvent| {
        let d = d.clone();
        async move { on_incoming_request(d, ev).await }
    });
}

/// An `m.key.verification.request` to-device event arrived: the crypto
/// machine has already processed it, so fetch the request object and track it.
async fn on_incoming_request(daemon: SharedDaemon, ev: ToDeviceKeyVerificationRequestEvent) {
    let Some(client) = daemon.client().await else {
        return;
    };
    let user_id = ev.sender.clone();
    let transaction_id = ev.content.transaction_id.clone();
    match client
        .encryption()
        .get_verification_request(&user_id, &transaction_id)
        .await
    {
        Some(request) => track(daemon, request).await,
        None => warn!(
            "Verification request from {} ({}) but the SDK has no request object",
            user_id, ev.content.from_device
        ),
    }
}

/// Begin tracking a verification request: emit its current state and spawn a
/// watcher for subsequent changes.
async fn track(daemon: SharedDaemon, request: VerificationRequest) {
    let flow_id = request.flow_id().to_string();
    let already = tracked_request(&daemon, &flow_id).is_some();
    if !already {
        if let Ok(mut map) = daemon.verifications.lock() {
            map.insert(flow_id.clone(), request.clone());
        }
    }
    emit_request_state(&daemon, &request, None);
    if !already {
        let d = daemon.clone();
        tokio::spawn(async move { watch_request(d, request).await });
    }
}

/// Map a request state to the protocol's state string.
fn request_state_string(state: &VerificationRequestState) -> &'static str {
    match state {
        VerificationRequestState::Created { .. } => "created",
        VerificationRequestState::Requested { .. } => "requested",
        VerificationRequestState::Ready { .. } => "ready",
        VerificationRequestState::Transitioned { .. } => "sas_started",
        VerificationRequestState::Done => "done",
        VerificationRequestState::Cancelled(_) => "cancelled",
    }
}

/// Emit one `updateVerificationRequest` for REQUEST (or an explicit STATE).
fn emit_request_state(
    daemon: &SharedDaemon,
    request: &VerificationRequest,
    state: Option<&VerificationRequestState>,
) {
    let current;
    let state = match state {
        Some(state) => state,
        None => {
            current = request.state();
            &current
        }
    };
    let device_id = match state {
        VerificationRequestState::Requested {
            other_device_data, ..
        }
        | VerificationRequestState::Ready {
            other_device_data, ..
        } => Some(other_device_data.device_id().to_string()),
        _ => None,
    };
    let reason = match state {
        VerificationRequestState::Cancelled(info) => Some(info.reason().to_string()),
        _ => None,
    };
    debug!(
        "Verification {} with {}: {:?}",
        request.flow_id(),
        request.other_user_id(),
        request_state_string(state)
    );
    daemon.send(OutEvent::event(Event::UpdateVerificationRequest {
        flow_id: request.flow_id().to_string(),
        user_id: request.other_user_id().to_string(),
        device_id,
        we_started: request.we_started(),
        state: request_state_string(state).to_string(),
        reason,
    }));
}

/// Watch one verification request until it finishes or the stream ends.
async fn watch_request(daemon: SharedDaemon, request: VerificationRequest) {
    let flow_id = request.flow_id().to_string();
    let stream = request.changes();
    pin_mut!(stream);
    // Set once the request transitioned to a SAS flow: from then on the
    // SAS watcher reports the terminal state, and emitting it here as
    // well would duplicate the final line in the Emacs buffer.
    let mut sas = false;
    while let Some(state) = stream.next().await {
        match &state {
            VerificationRequestState::Transitioned { verification } => match verification {
                Verification::SasV1(sas_flow) => {
                    sas = true;
                    emit_request_state(&daemon, &request, Some(&state));
                    let sas_flow = sas_flow.clone();
                    let d = daemon.clone();
                    let flow_id = flow_id.clone();
                    tokio::spawn(async move { watch_sas(d, sas_flow, flow_id).await });
                }
                _ => {
                    // QR verification is not part of the UI (no qrcode
                    // feature); report the transition and move on.
                    warn!(
                        "Verification {} transitioned to an unsupported flow",
                        flow_id
                    );
                    emit_request_state(&daemon, &request, Some(&state));
                }
            },
            VerificationRequestState::Done | VerificationRequestState::Cancelled(_) => {
                if !sas {
                    emit_request_state(&daemon, &request, Some(&state));
                }
                remove_tracked(&daemon, &flow_id);
                if matches!(state, VerificationRequestState::Done) {
                    info!("Verification {} done", flow_id);
                    emit_cross_signing_status(&daemon).await;
                    // Completing verification makes the other client gossip
                    // this account's secrets (backup key, cross-signing
                    // keys) to this device over the next seconds.  Report
                    // the recovery state now, and again once that gossip
                    // has typically landed, so Emacs can show key backup
                    // as available without asking for a recovery key.
                    emit_recovery_state(&daemon).await;
                    let d = daemon.clone();
                    tokio::spawn(async move {
                        tokio::time::sleep(std::time::Duration::from_secs(10)).await;
                        emit_recovery_state(&d).await;
                    });
                }
                return;
            }
            _ => emit_request_state(&daemon, &request, Some(&state)),
        }
    }
    // Stream ended without a terminal state; stop tracking.
    remove_tracked(&daemon, &flow_id);
}

/// Watch the SAS flow: emoji/decimal short auth string, confirmation, result.
/// FLOW_ID comes from the owning request (the SAS type itself has no
/// flow-id accessor).
async fn watch_sas(daemon: SharedDaemon, sas: SasVerification, flow_id: String) {
    // A SAS the peer started waits for our `m.key.verification.accept`
    // before either side sends its key — the SDK only hands us the
    // accept through an explicit call, so a flow that starts on the
    // other side deadlocked here: both devices sat "waiting for keys"
    // until the request's 10-minute timer cancelled with `m.timeout`.
    // Accepting is a no-op for a SAS we started ourselves: only the
    // peer-started state produces the event, and once accepted the
    // call is idempotent.
    if let Err(e) = sas.accept().await {
        warn!("SAS accept failed: {e:#}");
    }
    let stream = sas.changes();
    pin_mut!(stream);
    // The same SAS state can surface more than once: SasState::Confirmed
    // maps from two inner states — InnerSas::Confirmed (we confirmed) and
    // InnerSas::WaitingForDone (their MAC arrived) — so consecutive
    // identical states are expected and only the first is reported.
    let mut last = "";
    while let Some(state) = stream.next().await {
        let name = match &state {
            SasState::KeysExchanged { .. } => "sas_keys_exchanged",
            SasState::Confirmed => "sas_confirmed",
            SasState::Done { .. } => "done",
            SasState::Cancelled(_) => "cancelled",
            _ => continue,
        };
        if name == last {
            continue;
        }
        last = name;
        match &state {
            SasState::KeysExchanged { emojis, decimals } => {
                let (d0, d1, d2) = *decimals;
                let pairs: Vec<[String; 2]> = emojis
                    .iter()
                    .flat_map(|eas| eas.emojis.iter())
                    .map(|emoji| [emoji.symbol.to_string(), emoji.description.to_string()])
                    .collect();
                daemon.send(OutEvent::event(Event::UpdateVerificationEmojis {
                    flow_id: flow_id.clone(),
                    emojis: pairs,
                    decimals: [d0, d1, d2],
                }));
                emit_sas_state(&daemon, &sas, &flow_id, "sas_keys_exchanged");
            }
            SasState::Confirmed => emit_sas_state(&daemon, &sas, &flow_id, "sas_confirmed"),
            SasState::Done { .. } => {
                emit_sas_state(&daemon, &sas, &flow_id, "done");
                info!("SAS verification {} done", flow_id);
                return;
            }
            SasState::Cancelled(_) => {
                emit_sas_state(&daemon, &sas, &flow_id, "cancelled");
                return;
            }
            _ => {}
        }
    }
}

/// Emit an `updateVerificationRequest` with a SAS-level state string.
fn emit_sas_state(daemon: &SharedDaemon, sas: &SasVerification, flow_id: &str, state: &str) {
    daemon.send(OutEvent::event(Event::UpdateVerificationRequest {
        flow_id: flow_id.to_string(),
        user_id: sas.other_user_id().to_string(),
        device_id: Some(sas.other_device().device_id().to_string()),
        we_started: sas.we_started(),
        state: state.to_string(),
        reason: sas.cancel_info().map(|c| c.reason().to_string()),
    }));
}

/// The `updateCrossSigningStatus` event for the current session.
///
/// `enabled` — the account has complete cross-signing keys (the SDK's
/// status).  `trusted` — this device has verified its own cross-signing
/// identity (by verifying against an existing device, or by holding the
/// private keys from a bootstrap).  They are genuinely different states:
/// after a fresh daemon start on an already-cross-signed account, the
/// identity exists but this session has not adopted it yet.
pub(crate) async fn cross_signing_event(client: &Client) -> Option<Event> {
    let status = client.encryption().cross_signing_status().await?;
    let enabled = status.is_complete();
    let trusted = session_trusted(client).await;
    Some(Event::UpdateCrossSigningStatus { enabled, trusted })
}

/// Whether this session has verified its own cross-signing identity —
/// the same signal the `updateCrossSigningStatus` event reports as
/// `trusted`.
async fn session_trusted(client: &Client) -> bool {
    match client.user_id() {
        Some(user_id) => client
            .encryption()
            .get_user_identity(user_id)
            .await
            .ok()
            .flatten()
            .map(|identity| identity.is_verified())
            .unwrap_or(false),
        None => false,
    }
}

/// Re-emit the cross-signing status after a verification completes.
/// Also called on `getSession`, so a freshly started Emacs learns the
/// trust state of the restored session.
pub(crate) async fn emit_cross_signing_status(daemon: &SharedDaemon) {
    if let Some(client) = daemon.client().await {
        if let Some(event) = cross_signing_event(&client).await {
            daemon.emit(event);
        }
    }
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

/// `getDevices`: list the account's devices with their verification state.
pub async fn handle_get_devices(daemon: SharedDaemon, req: Option<u64>) {
    let Some(client) = daemon.client().await else {
        crate::sync::no_session(&daemon, req);
        return;
    };

    match client.devices().await {
        Ok(response) => {
            let own_user_id = client.user_id().map(|u| u.to_owned());
            let own_device = client.device_id().map(|d| d.to_owned());
            // Cross-signing completion is what "this session is trusted"
            // means for the current device: is_verified() would trivially
            // be true (we hold our own device keys), telling the user
            // nothing.
            let current_trusted = client
                .encryption()
                .cross_signing_status()
                .await
                .map(|s| s.is_complete())
                .unwrap_or(false);
            // The per-device trust lookups are independent: batch them
            // instead of a serial round-trip per device.
            let futs = response.devices.into_iter().map(|device| {
                let client = client.clone();
                let own_user_id = own_user_id.clone();
                let own_device = own_device.clone();
                async move {
                    let is_current = own_device.as_ref() == Some(&device.device_id);
                    let verified = if is_current {
                        current_trusted
                    } else {
                        match &own_user_id {
                            Some(user_id) => client
                                .encryption()
                                .get_device(user_id, &device.device_id)
                                .await
                                .ok()
                                .flatten()
                                .map(|d| d.is_verified())
                                .unwrap_or(false),
                            // A client without a session user cannot
                            // verify anything; report unverified rather
                            // than panic.
                            None => false,
                        }
                    };
                    DeviceSummary {
                        device_id: device.device_id.to_string(),
                        display_name: device.display_name,
                        last_seen_ts: device.last_seen_ts.map(|ts| i64::from(ts.get()) as u64),
                        is_current,
                        verified,
                    }
                }
            });
            let mut summaries: Vec<DeviceSummary> = join_all(futs).await;
            summaries.sort_by_key(|d| std::cmp::Reverse(d.is_current));
            daemon.respond(req, Event::UpdateDevices { devices: summaries });
        }
        Err(e) => {
            warn!("getDevices failed: {e}");
            daemon.ack(req, false, Some(format!("getDevices failed: {e}")));
        }
    }
}

/// `deleteDevice`: log one of the account's devices out.
///
/// Homeservers (Synapse at least) always run user-interactive auth on
/// device deletion: the first attempt carries no auth data and is
/// expected to come back as a UIA challenge.  The daemon answers that
/// challenge internally when the command carried the password —
/// Emacs never sees UIA sessions — and otherwise reports that a
/// password is needed, so the caller re-sends with one.
pub async fn handle_delete_device(
    daemon: SharedDaemon,
    req: Option<u64>,
    device_id: String,
    password: Option<String>,
) {
    let Some(client) = daemon.client().await else {
        crate::sync::no_session(&daemon, req);
        return;
    };
    // Device ids are opaque strings; no validation needed.
    let device_id: OwnedDeviceId = device_id.as_str().into();
    let device_id_str = device_id.to_string();
    match client
        .delete_devices(std::slice::from_ref(&device_id), None)
        .await
    {
        // No UIA challenge on this homeserver: gone already.
        Ok(_) => daemon.ack(req, true, None),
        Err(e) => {
            let Some(uiaa) = e.as_uiaa_response() else {
                warn!("deleteDevice failed: {e}");
                daemon.ack(req, false, Some(format!("deleteDevice failed: {e}")));
                return;
            };
            let Some(password) = password else {
                daemon.ack(
                    req,
                    false,
                    Some("Password required to delete a device".into()),
                );
                return;
            };
            let user_id = client
                .user_id()
                .map(|u| u.to_owned())
                .map(|u| u.to_string());
            let Some(user_id) = user_id else {
                daemon.ack(req, false, Some("No session user for the UIA retry".into()));
                return;
            };
            let mut auth = uiaa::Password::new(
                uiaa::UserIdentifier::Matrix(uiaa::MatrixUserIdentifier::new(user_id)),
                password,
            );
            auth.session = uiaa.session.clone();
            match client
                .delete_devices(
                    std::slice::from_ref(&device_id),
                    Some(uiaa::AuthData::Password(auth)),
                )
                .await
            {
                Ok(_) => daemon.ack(req, true, None),
                Err(e) => {
                    warn!("deleteDevice of {device_id_str} failed after UIA: {e}");
                    daemon.ack(req, false, Some(format!("Deleting the device failed: {e}")));
                }
            }
        }
    }
}

/// `verifyDevice`: start a verification flow with another device.
pub async fn handle_verify_device(
    daemon: SharedDaemon,
    req: Option<u64>,
    user_id: String,
    device_id: String,
) {
    let Some(client) = daemon.client().await else {
        crate::sync::no_session(&daemon, req);
        return;
    };
    let Ok(user_id) = user_id.parse::<OwnedUserId>() else {
        daemon.ack(req, false, Some("Invalid user id".into()));
        return;
    };
    // Device ids are opaque strings; no validation needed.
    let device_id: OwnedDeviceId = device_id.as_str().into();
    let device_id_str = device_id.to_string();
    match client.encryption().get_device(&user_id, &device_id).await {
        Ok(Some(device)) => match device.request_verification().await {
            Ok(request) => {
                track(daemon.clone(), request).await;
                daemon.ack(req, true, None);
            }
            Err(e) => {
                warn!("requestVerification failed: {e}");
                daemon.ack(
                    req,
                    false,
                    Some(format!("Verification request failed: {e}")),
                );
            }
        },
        Ok(None) => {
            daemon.ack(
                req,
                false,
                Some(format!("No known device {device_id_str} for {user_id}")),
            );
        }
        Err(e) => {
            warn!("get_device failed: {e}");
            daemon.ack(req, false, Some(format!("Device lookup failed: {e}")));
        }
    }
}

/// Re-emit every tracked request so Emacs can reconcile after (re)connect.
pub async fn handle_get_verification_requests(daemon: SharedDaemon, req: Option<u64>) {
    let requests: Vec<VerificationRequest> = match daemon.verifications.lock() {
        Ok(map) => map.values().cloned().collect(),
        Err(_) => Vec::new(),
    };
    for request in requests {
        emit_request_state(&daemon, &request, None);
    }
    daemon.ack(req, true, None);
}

/// `acceptVerification`: accept an incoming request (we become the responder).
pub async fn handle_accept_verification(daemon: SharedDaemon, req: Option<u64>, flow_id: String) {
    let Some(request) = tracked_request(&daemon, &flow_id) else {
        daemon.ack(
            req,
            false,
            Some(format!("No verification request {flow_id}")),
        );
        return;
    };
    match request.accept().await {
        Ok(()) => daemon.ack(req, true, None),
        Err(e) => {
            warn!("acceptVerification failed: {e}");
            daemon.ack(req, false, Some(format!("Accept failed: {e}")));
        }
    }
}

/// `startSas`: transition a ready request into the SAS flow.
pub async fn handle_start_sas(daemon: SharedDaemon, req: Option<u64>, flow_id: String) {
    let Some(request) = tracked_request(&daemon, &flow_id) else {
        daemon.ack(
            req,
            false,
            Some(format!("No verification request {flow_id}")),
        );
        return;
    };
    match request.start_sas().await {
        Ok(Some(_)) => daemon.ack(req, true, None),
        Ok(None) => daemon.ack(
            req,
            false,
            Some("Cannot start SAS (not ready, or unsupported methods)".into()),
        ),
        Err(e) => {
            warn!("startSas failed: {e}");
            daemon.ack(req, false, Some(format!("SAS start failed: {e}")));
        }
    }
}

/// `confirmSas`: the user says the emojis match.
pub async fn handle_confirm_sas(daemon: SharedDaemon, req: Option<u64>, flow_id: String) {
    let Some(request) = tracked_request(&daemon, &flow_id) else {
        daemon.ack(
            req,
            false,
            Some(format!("No verification request {flow_id}")),
        );
        return;
    };
    let sas = match request.state() {
        VerificationRequestState::Transitioned { verification } => match verification {
            Verification::SasV1(sas) => sas,
            _ => {
                daemon.ack(req, false, Some("Verification is not a SAS flow".into()));
                return;
            }
        },
        state => {
            daemon.ack(
                req,
                false,
                Some(format!(
                    "Verification not in SAS phase: {}",
                    request_state_string(&state)
                )),
            );
            return;
        }
    };
    match sas.confirm().await {
        Ok(()) => daemon.ack(req, true, None),
        Err(e) => {
            warn!("confirmSas failed: {e}");
            daemon.ack(req, false, Some(format!("Confirm failed: {e}")));
        }
    }
}

/// `cancelVerification`: either side aborts the flow.
pub async fn handle_cancel_verification(daemon: SharedDaemon, req: Option<u64>, flow_id: String) {
    let Some(request) = tracked_request(&daemon, &flow_id) else {
        daemon.ack(
            req,
            false,
            Some(format!("No verification request {flow_id}")),
        );
        return;
    };
    match request.cancel().await {
        Ok(()) => daemon.ack(req, true, None),
        Err(e) => {
            warn!("cancelVerification failed: {e}");
            daemon.ack(req, false, Some(format!("Cancel failed: {e}")));
        }
    }
}

// ---------------------------------------------------------------------------
// Invisible crypto: first-time accounts adopt keys without being asked.
// ---------------------------------------------------------------------------

/// Path of the daemon's own copy of the recovery key, in the session's
/// data dir.
fn recovery_key_path(data_dir: &std::path::Path) -> std::path::PathBuf {
    data_dir.join("recovery-key")
}

/// Store the recovery key next to the session (0600 on unix).  The data
/// dir already holds the access token and the crypto stores, so this
/// adds no new at-rest surface — and it is what makes a re-login adopt
/// the account's keys invisibly (see [`auto_crypto_onboarding`]) and
/// gives off-machine restores a file to copy.
fn store_recovery_key(
    data_dir: &std::path::Path,
    key: &str,
) -> std::io::Result<std::path::PathBuf> {
    let path = recovery_key_path(data_dir);
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .mode(0o600)
            .open(&path)?;
        file.write_all(key.as_bytes())?;
        file.flush()?;
    }
    #[cfg(not(unix))]
    std::fs::write(&path, key)?;
    Ok(path)
}

/// The session's crypto brought up as much as the account allows.
///
/// An account with no cross-signing identity on the homeserver — a
/// first-time account, or a dormant one nobody ever bootstrapped —
/// gets everything started in the background: keys, secret storage, a
/// key backup, and the recovery key stored next to the session (and
/// shown once by Emacs).  An account that already has an identity this
/// session does not trust, plus secret storage plus a stored recovery
/// key (an earlier bootstrap here), adopts that key silently — the
/// re-login needs no device-verification dance.  Everything else keeps
/// the manual flows — the daemon never replaces keys set up elsewhere,
/// and a silent background step must never speak over the user — but
/// now says so through `updateVerificationNeeded`, so Emacs can offer
/// those flows instead of leaving a never-trusted session unexplained.
pub(crate) async fn auto_crypto_onboarding(daemon: &SharedDaemon, client: &Client) {
    let encryption = client.encryption();
    let Some(user_id) = client.user_id().map(|u| u.to_owned()) else {
        return;
    };
    // Server-authoritative: `get_user_identity' reads the crypto store
    // only — on a fresh session (new data dir, forgotten profile) the
    // store is empty, so an account that is cross-signed on the
    // homeserver answers `None' and the daemon would wrongly take the
    // fresh-account bootstrap branch (with secret storage already on
    // the server, a silent no-op that never asks the user anything).
    // `request_user_identity' performs and awaits the initial key
    // query instead — the same thing `bootstrap_cross_signing_if_needed'
    // does inside its own guard — so the branch is decided on
    // homeserver truth.
    let identity = match client.encryption().request_user_identity(&user_id).await {
        Ok(identity) => identity,
        Err(e) => {
            warn!("Could not query the account's cross-signing identity: {e:#}");
            return;
        }
    };
    match identity {
        None => {
            info!("No cross-signing identity — bootstrapping keys and recovery in the background");
            if let Err(e) = encryption.bootstrap_cross_signing_if_needed(None).await {
                warn!("Background cross-signing bootstrap failed: {e:#}");
                return;
            }
            // Mirrors `handle_enable_recovery`'s guard: secret storage
            // set up elsewhere is left — and its recovery key with it.
            match encryption.secret_storage().is_enabled().await {
                Ok(true) => {
                    info!("Secret storage already exists; leaving it and its recovery key alone");
                }
                Ok(false) => {
                    info!("Enabling recovery in the background (SSSS + key backup)");
                    match encryption
                        .recovery()
                        .enable()
                        .wait_for_backups_to_upload()
                        .await
                    {
                        Ok(recovery_key) => {
                            let stored_path = store_recovery_key(&daemon.data_dir, &recovery_key)
                                .ok()
                                .map(|path| path.to_string_lossy().into_owned());
                            if stored_path.is_none() {
                                error!("Storing the recovery key in the data dir failed");
                            }
                            daemon.emit(Event::RecoveryEnabled {
                                recovery_key,
                                stored_path,
                            });
                            daemon.emit(Event::UpdateRecoveryState {
                                state: "enabled".into(),
                                error: None,
                            });
                            info!("Recovery enabled, keys uploaded");
                        }
                        Err(e) => warn!("Background recovery enable failed: {e:#}"),
                    }
                }
                Err(e) => warn!("Checking secret storage failed: {e:#}"),
            }
            // The bootstrap (or the refusal to repeat one) changed the
            // visible state; say so.
            if let Some(event) = cross_signing_event(client).await {
                daemon.emit(event);
            }
        }
        Some(identity) if !identity.is_verified() => {
            // A re-login the account's earlier bootstrap can absorb.
            let enabled = match encryption.secret_storage().is_enabled().await {
                Ok(enabled) => enabled,
                Err(e) => {
                    warn!("Checking secret storage failed: {e:#}");
                    return;
                }
            };
            if !enabled {
                // Identity unadopted, nothing stored to adopt it from:
                // the manual flows (verify this device, or recover from
                // a key the user holds) as always.  But a session that
                // never becomes trusted is a silent failure from the
                // user's side — say so, and Emacs offers those flows.
                daemon.emit(Event::UpdateVerificationNeeded {
                    reason: "no-storage".into(),
                });
                return;
            }
            let key = std::fs::read_to_string(recovery_key_path(&daemon.data_dir))
                .ok()
                .map(|key| key.trim().to_owned())
                .filter(|key| !key.is_empty());
            let Some(key) = key else {
                // Recovery set up on the homeserver, but this machine
                // was never handed the key: only the user has it.
                daemon.emit(Event::UpdateVerificationNeeded {
                    reason: "no-recovery-key".into(),
                });
                return;
            };
            info!("Adopting the account's stored recovery key for a fresh session");
            match encryption.recovery().recover(&key).await {
                Ok(()) => {
                    info!("Recovery key adopted — this session's trust is restored");
                    emit_recovery_state(daemon).await;
                    if let Some(event) = cross_signing_event(client).await {
                        daemon.emit(event);
                    }
                }
                // A wrong or rotated-away key stays a log line: this
                // runs behind the user's back, and the manual flows
                // decide what happens next.
                Err(e) => warn!("The stored recovery key did not adopt: {e:#}"),
            }
        }
        // Already trusted: nothing to do.
        Some(_) => {}
    }
}

// ---------------------------------------------------------------------------
// Recovery keys: enable, restore, rotate, disable
// ---------------------------------------------------------------------------

/// `enableRecovery`: create secret storage + server-side key backup and return
/// the base58 recovery key.  The key is shown to the user exactly once, and
/// the daemon stores its own copy next to the session (0600) — it is what
/// later re-logins adopt silently, and what the security view can point at.
pub async fn handle_enable_recovery(daemon: SharedDaemon, req: Option<u64>) {
    let Some(client) = daemon.client().await else {
        crate::sync::no_session(&daemon, req);
        return;
    };
    // If secret storage already exists on the server (set up by another
    // session), enabling would silently replace it — orphaning that
    // recovery key.  Make the caller restore with the existing key instead
    // (only sensible after this session's secrets were gossiped over from
    // a verified device).
    match client.encryption().secret_storage().is_enabled().await {
        Ok(true) => {
            info!("Secret storage already exists; refusing to enable recovery");
            daemon.ack(
                req,
                false,
                Some(
                    "Secret storage already exists — recover with your \
existing recovery key instead"
                        .into(),
                ),
            );
            return;
        }
        Ok(false) => {}
        Err(e) => {
            warn!("Checking secret storage failed: {e}");
            daemon.ack(
                req,
                false,
                Some(format!("Checking secret storage failed: {e}")),
            );
            return;
        }
    }
    info!("Enabling recovery (SSSS + key backup)");
    let recovery = client.encryption().recovery();
    match recovery.enable().wait_for_backups_to_upload().await {
        Ok(recovery_key) => {
            let stored_path = store_recovery_key(&daemon.data_dir, &recovery_key)
                .ok()
                .map(|path| path.to_string_lossy().into_owned());
            if stored_path.is_none() {
                error!("Storing the recovery key in the data dir failed");
            }
            daemon.respond(
                req,
                Event::RecoveryEnabled {
                    recovery_key,
                    stored_path,
                },
            );
            daemon.emit(Event::UpdateRecoveryState {
                state: "enabled".into(),
                error: None,
            });
            info!("Recovery enabled, keys uploaded");
        }
        Err(e) => {
            warn!("enableRecovery failed: {e}");
            daemon.emit(Event::UpdateRecoveryState {
                state: "error".into(),
                error: Some(format!("Recovery enable failed: {e}")),
            });
            daemon.ack(req, false, Some(format!("Recovery enable failed: {e}")));
        }
    }
}

/// `recoverRecoveryKey`: restore secret storage + backup access from a
/// previously saved recovery key.
pub async fn handle_recover_recovery_key(daemon: SharedDaemon, req: Option<u64>, key: String) {
    let Some(client) = daemon.client().await else {
        crate::sync::no_session(&daemon, req);
        return;
    };
    let recovery = client.encryption().recovery();
    match recovery.recover(&key).await {
        Ok(()) => {
            info!("Recovery key accepted, secrets recovered");
            // Stash what the user just told us, unless the stored copy
            // already agrees: the background adopt branch reads this same
            // file, so the next restore fixes itself silently.  The key
            // value itself never enters a log line — only this outcome.
            let same_as_stored = std::fs::read_to_string(recovery_key_path(&daemon.data_dir))
                .ok()
                .map(|stored| stored.trim().eq(key.trim()))
                == Some(true);
            if !same_as_stored {
                if let Err(e) = store_recovery_key(&daemon.data_dir, key.trim()) {
                    warn!("Storing the recovery key in the data dir failed: {e}");
                }
            }
            daemon.ack(req, true, None);
            // Truthful state: recover() can leave the subsystem Incomplete
            // (e.g. the server lost the backup) — do not claim "enabled".
            emit_recovery_state(&daemon).await;
            // The import re-derived the public keys and marked this
            // session's identity verified; say so, or the bar's Verify row
            // and the session-status view stay stale until the next
            // getSession.
            if let Some(event) = cross_signing_event(&client).await {
                daemon.emit(event);
            }
        }
        Err(e) => {
            warn!("recoverRecoveryKey failed: {e}");
            daemon.ack(req, false, Some(format!("Recovery failed: {e}")));
        }
    }
}

/// Map a RecoveryState to the protocol's state string.
fn recovery_state_name(state: matrix_sdk::encryption::recovery::RecoveryState) -> &'static str {
    match state {
        matrix_sdk::encryption::recovery::RecoveryState::Unknown => "unknown",
        matrix_sdk::encryption::recovery::RecoveryState::Enabled => "enabled",
        matrix_sdk::encryption::recovery::RecoveryState::Disabled => "disabled",
        matrix_sdk::encryption::recovery::RecoveryState::Incomplete => "incomplete",
    }
}

/// Report the current recovery subsystem state to Emacs.
pub(crate) async fn emit_recovery_state(daemon: &SharedDaemon) {
    if let Some(client) = daemon.client().await {
        let name = recovery_state_name(client.encryption().recovery().state());
        daemon.emit(Event::UpdateRecoveryState {
            state: name.into(),
            error: None,
        });
    }
}

/// `getRecoveryState`: report the current recovery subsystem state.
/// The state rides on the request response itself (so a caller with a
/// callback receives it directly) and is also emitted as an untagged
/// event, keeping the client-side recovery-state hash in sync for
/// callback-less callers.
pub async fn handle_get_recovery_state(daemon: SharedDaemon, req: Option<u64>) {
    let Some(client) = daemon.client().await else {
        crate::sync::no_session(&daemon, req);
        return;
    };
    let name = recovery_state_name(client.encryption().recovery().state());
    daemon.respond(
        req,
        Event::UpdateRecoveryState {
            state: name.into(),
            error: None,
        },
    );
    daemon.emit(Event::UpdateRecoveryState {
        state: name.into(),
        error: None,
    });
}

// ---------------------------------------------------------------------------
// Recovery rotation and disable (protocol 21)
// ---------------------------------------------------------------------------

/// Which rotation verb applies, purely from the recovery state, this
/// session's trust and whether an old key was named.
///
/// An untrusted session must never call plain `reset_key`: rotation
/// re-uploads the secrets *this session holds*, so from a session the
/// store distrusts it would build a fresh secret store it cannot fill
/// (the SDK's own warning) — every other device would then be locked
/// out of secret storage.  The old key routes through
/// `recover_and_reset` instead, which imports the old store first.
#[derive(Debug, PartialEq, Eq)]
enum RotationRoute {
    /// `reset_key`: the store trusts this session to fill the new one.
    Reset,
    /// `recover_and_reset`: import the old store first, then rotate.
    RecoverAndReset(String),
    /// Refuse until the caller names the current recovery key.
    NeedsOldKey,
    /// Refuse: there is nothing set up to rotate.
    NotSetUp,
}

fn rotation_route(
    state: matrix_sdk::encryption::recovery::RecoveryState,
    trusted: bool,
    old_key: Option<&str>,
) -> RotationRoute {
    let old_key = old_key.map(str::trim).filter(|key| !key.is_empty());
    use matrix_sdk::encryption::recovery::RecoveryState::{Disabled, Enabled, Incomplete, Unknown};
    match state {
        Disabled | Unknown => RotationRoute::NotSetUp,
        Incomplete => match old_key {
            Some(key) => RotationRoute::RecoverAndReset(key.to_owned()),
            None => RotationRoute::NeedsOldKey,
        },
        Enabled => match (trusted, old_key) {
            (true, _) => RotationRoute::Reset,
            (false, Some(key)) => RotationRoute::RecoverAndReset(key.to_owned()),
            (false, None) => RotationRoute::NeedsOldKey,
        },
    }
}

/// `rotateRecoveryKey`: build a new secret store under a fresh recovery
/// key and re-upload this session's known secrets.  The key backup is
/// untouched.  The new key is stashed over the old one and answered in
/// the same `RecoveryEnabled` shape `enableRecovery` uses — the client
/// already shows it once and knows it lives at the stored path.
pub async fn handle_rotate_recovery_key(
    daemon: SharedDaemon,
    req: Option<u64>,
    old_key: Option<String>,
) {
    let Some(client) = daemon.client().await else {
        crate::sync::no_session(&daemon, req);
        return;
    };
    let recovery = client.encryption().recovery();
    let trusted = session_trusted(&client).await;
    let route = rotation_route(recovery.state(), trusted, old_key.as_deref());
    match route {
        RotationRoute::NotSetUp => {
            info!("rotateRecoveryKey refused: recovery is not set up");
            daemon.ack(
                req,
                false,
                Some("Recovery is not set up — elneo-enable-recovery creates it".into()),
            );
        }
        RotationRoute::NeedsOldKey => {
            info!("rotateRecoveryKey refused: untrusted session without an old key");
            daemon.ack(
                req,
                false,
                Some(
                    "This session can't rotate safely on its own — pass the old \
recovery key"
                        .into(),
                ),
            );
        }
        RotationRoute::Reset => {
            let rotated = recovery.reset_key().await;
            report_rotation(&daemon, req, rotated).await;
        }
        RotationRoute::RecoverAndReset(old) => {
            info!("Recovery key rotation goes through a recover-then-rotate (untrusted session)");
            let rotated = recovery.recover_and_reset(&old).await;
            report_rotation(&daemon, req, rotated).await;
        }
    }
}

/// Common rotate/recover-and-reset success path: stash the new key
/// (rotation always means a new one — no diff-guard, unlike the recover
/// path), answer in the `RecoveryEnabled` shape, and tell Emacs the new
/// subsystem state.  The key value itself never enters a log line.
async fn report_rotation(
    daemon: &SharedDaemon,
    req: Option<u64>,
    rotated: matrix_sdk::encryption::recovery::Result<String>,
) {
    match rotated {
        Ok(new_key) => {
            info!("Recovery key rotated, secrets re-uploaded");
            let stored_path = match store_recovery_key(&daemon.data_dir, new_key.trim()) {
                Ok(path) => Some(path.to_string_lossy().into_owned()),
                Err(e) => {
                    warn!("Storing the rotated recovery key failed: {e}");
                    None
                }
            };
            daemon.respond(
                req,
                Event::RecoveryEnabled {
                    recovery_key: new_key,
                    stored_path,
                },
            );
            emit_recovery_state(daemon).await;
        }
        Err(e) => {
            warn!("rotateRecoveryKey failed: {e}");
            // The stash stays: if the old key still works, the
            // background adopt keeps healing as before; if it does
            // not, the manual recover path re-stashes on a correct
            // entry.
            daemon.ack(req, false, Some(format!("Recovery rotate failed: {e}")));
        }
    }
}

/// Remove the recovery-key stash; a missing file is already the state
/// we want.  Called after a successful disable, so a later restore
/// neither adopts a stale key nor re-enables anything behind the
/// user's back.
fn remove_recovery_key_stash(data_dir: &std::path::Path) -> std::io::Result<()> {
    match std::fs::remove_file(recovery_key_path(data_dir)) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        other => other,
    }
}

/// `disableRecovery`: delete the server-side key backup and clear
/// secret storage — secret storage default key emptied, the disabled
/// flags written (MSC4287's included) and every known secret removed
/// from account data.  The backup's history is gone for every device
/// that cannot already decrypt it; only the typed-word confirmation on
/// the Emacs side stands in front of this.
pub async fn handle_disable_recovery(daemon: SharedDaemon, req: Option<u64>) {
    let Some(client) = daemon.client().await else {
        crate::sync::no_session(&daemon, req);
        return;
    };
    let recovery = client.encryption().recovery();
    if let matrix_sdk::encryption::recovery::RecoveryState::Disabled = recovery.state() {
        info!("disableRecovery refused: recovery is already disabled");
        daemon.ack(req, false, Some("Recovery is already disabled".into()));
        return;
    }
    // Recovery::disable deletes a locally known backup version from the
    // server first; if it knows of none (e.g. an incomplete store
    // without one) it refuses and leaves everything intact.  Honest
    // error to Emacs either way.
    match recovery.disable().await {
        Ok(()) => {
            if let Err(e) = remove_recovery_key_stash(&daemon.data_dir) {
                warn!("Removing the recovery-key stash failed: {e}");
            } else {
                info!("Removed the recovery-key stash after disabling recovery");
            }
            daemon.ack(req, true, None);
            emit_recovery_state(&daemon).await;
        }
        Err(e) => {
            warn!("disableRecovery failed: {e}");
            daemon.ack(req, false, Some(format!("Recovery disable failed: {e}")));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The stashed key lives at a fixed name inside the session's data
    /// dir, mode 0600 on unix, and an overwrite replaces the content.
    /// Only the synthetic constant appears here — real key material has
    /// no business in a test.
    #[test]
    fn recovery_key_stash_lands_in_the_data_dir() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = store_recovery_key(dir.path(), "TESTKEY").expect("store");
        assert_eq!(path, recovery_key_path(dir.path()));
        assert_eq!(
            path.file_name().and_then(|n| n.to_str()),
            Some("recovery-key")
        );

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path)
                .expect("metadata")
                .permissions()
                .mode()
                & 0o777;
            assert_eq!(mode, 0o600);
        }

        // Overwrite keeps the same file and the new content (still the
        // synthetic constant; a trimmed caller value is what arrives).
        store_recovery_key(dir.path(), "OTHERKEY").expect("re-store");
        assert_eq!(
            std::fs::read_to_string(&path).expect("read").trim(),
            "OTHERKEY"
        );
    }

    #[test]
    fn recovery_key_path_is_inside_the_data_dir() {
        let dir = std::path::Path::new("/tmp/whatever-data-dir");
        let path = recovery_key_path(dir);
        assert!(path.starts_with(dir));
        assert_eq!(path, dir.join("recovery-key"));
    }

    /// A disable removes the stash; an absent stash is already fine —
    /// same synthetic constants as the store test above.
    #[test]
    fn disable_removes_the_stash_and_ignores_a_missing_one() {
        let dir = tempfile::tempdir().expect("tempdir");
        remove_recovery_key_stash(dir.path()).expect("remove a missing stash");

        store_recovery_key(dir.path(), "TESTKEY").expect("store");
        remove_recovery_key_stash(dir.path()).expect("remove");
        assert!(!recovery_key_path(dir.path()).exists());

        // A second remove still reports success (idempotent disable).
        remove_recovery_key_stash(dir.path()).expect("remove again");
    }

    /// The rotation routing: an untrusted session never gets the plain
    /// reset (the SDK would build a store it cannot fill) — it takes
    /// the recover-then-rotate with the old key, or nothing.  An
    /// unconfigured or disabled subsystem never rotates.
    #[test]
    fn rotation_routes_by_state_trust_and_old_key() {
        use matrix_sdk::encryption::recovery::RecoveryState::{
            Disabled, Enabled, Incomplete, Unknown,
        };

        assert_eq!(rotation_route(Enabled, true, None), RotationRoute::Reset);
        assert_eq!(
            rotation_route(Enabled, true, Some("TESTKEY")),
            RotationRoute::Reset
        );
        assert_eq!(
            rotation_route(Enabled, false, None),
            RotationRoute::NeedsOldKey
        );
        assert_eq!(
            rotation_route(Enabled, false, Some(" TESTKEY ")),
            RotationRoute::RecoverAndReset("TESTKEY".into())
        );
        // Incomplete: SSSS exists but this session cannot decrypt it —
        // the old key is the only safe verb, even if the session were
        // otherwise trusted.
        assert_eq!(
            rotation_route(Incomplete, true, None),
            RotationRoute::NeedsOldKey
        );
        assert_eq!(
            rotation_route(Incomplete, false, Some("TESTKEY")),
            RotationRoute::RecoverAndReset("TESTKEY".into())
        );
        assert_eq!(
            rotation_route(Disabled, true, None),
            RotationRoute::NotSetUp
        );
        assert_eq!(rotation_route(Unknown, true, None), RotationRoute::NotSetUp);
        // A blank old key is no key at all.
        assert_eq!(
            rotation_route(Enabled, false, Some("   ")),
            RotationRoute::NeedsOldKey
        );
        assert_eq!(
            rotation_route(Incomplete, true, Some("")),
            RotationRoute::NeedsOldKey
        );
    }
}
