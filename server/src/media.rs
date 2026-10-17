//! Media download manager: a telega-style on-disk cache in front of the
//! SDK's media fetches.
//!
//! `downloadMedia` streams content into `<data-dir>/media/<format>/<key>`
//! (keyed by mxc + format, so a thumbnail and the full file of one media
//! do not collide) and responds only when the bytes are on disk.  Requests
//! for a file already cached respond immediately; concurrent requests for
//! the same key join the in-flight download instead of fetching twice.
//! `updateDownload` events carry the lifecycle (the SDK fetches content
//! in one piece, so there is no byte progress to report yet).
//!
//! Commands run sequentially on the dispatch task, so downloads happen on
//! spawned tasks: a slow fetch must not stall the daemon's input loop.

use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Result};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use matrix_sdk::media::{MediaFormat, MediaRequestParameters, MediaThumbnailSettings};
use matrix_sdk::ruma::events::room::MediaSource;
use serde_json::Value;
use sha2::{Digest, Sha256};
use tracing::{error, info, warn};

use crate::daemon::SharedDaemon;
use crate::protocol::Event;

/// One in-flight download: the spawned fetch task plus the requests
/// waiting for its terminal response.
pub struct Download {
    pub handle: tokio::task::JoinHandle<()>,
    pub waiters: Vec<Waiter>,
}

/// One request waiting on an in-flight download: the id to answer and
/// the cache path its own filename asked for.  The spawner's bytes
/// serve them all, but each filename differs in extension, so each
/// gets its own cache entry and its own path in the response.
pub struct Waiter {
    pub req: Option<u64>,
    pub path: PathBuf,
}

/// Max length of a sanitized cache file name; mxc media ids are short in
/// practice, this only guards against hostile servers.  Ids too long for
/// it do not truncate (that would let two long ids share one cache
/// file) — they keep a readable head and get a digest tail.
const MAX_KEY_LEN: usize = 180;

/// Largest file we will pull into the download cache, in bytes.  The
/// fetch happens in one piece, so this caps the disk the cache can
/// consume; memory is normally pre-checked via HEAD (see
/// `probe_download_size`), with this as the backstop when the probe
/// cannot answer.
const MAX_DOWNLOAD_BYTES: usize = 100 * 1024 * 1024;

/// How long one download may take before we give up on it.
const DOWNLOAD_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);

/// The mxc URI a serialized `MediaSource` points at, as the cache key seed.
fn mxc_of(source: &Value) -> Result<String> {
    let parsed: MediaSource =
        serde_json::from_value(source.clone()).map_err(|e| anyhow!("Bad media source: {e}"))?;
    let url = match parsed {
        MediaSource::Plain(url) => url,
        MediaSource::Encrypted(file) => file.url,
    };
    // An mxc URI naming nothing — a bridge's `avatar_url: ""`, or a bare
    // `mxc://` — must not become a cache key: sanitized it is empty, so
    // the cache path would be the thumb directory itself, and the
    // stat-based "already cached" check cannot tell a directory from
    // real media.  Reject it at the door instead.
    anyhow::ensure!(
        !sanitize(url.as_str()).is_empty(),
        "Empty or invalid mxc URI: {url:?}"
    );
    Ok(url.to_string())
}

/// Normalize "thumb" vs everything else (which means the full file), as in
/// `downloadMedia`.
fn format_dir(format: &str) -> &'static str {
    if format == "thumb" {
        "thumb"
    } else {
        "file"
    }
}

/// Filesystem-safe form of an mxc URI (kept readable so the cache dir can
/// be browsed by hand).
///
/// Over-long ids do not truncate: two distinct ids sharing a 180-char
/// prefix would collapse onto one cache file and the second request
/// would be served the first's bytes. The readable head survives, the
/// rest becomes a digest of the whole id.
fn sanitize(mxc: &str) -> String {
    let key: String = mxc
        .trim_start_matches("mxc://")
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_') {
                c
            } else {
                '_'
            }
        })
        .collect();
    if key.len() <= MAX_KEY_LEN {
        return key;
    }
    // The maps only keep ASCII, so byte slicing is on a char boundary.
    // The digest covers the whole id, not the overflow, so no prefix
    // games (a change to the head still reshuffles the tail).
    let digest = Sha256::digest(key.as_bytes());
    let digest = URL_SAFE_NO_PAD.encode(&digest[..16]);
    let keep = MAX_KEY_LEN - digest.len() - 1;
    format!("{}_{}", &key[..keep], digest)
}

/// Lowercase extension (1-8 alphanumeric chars) of a file name, if any.
fn ext_of(filename: Option<&str>) -> Option<String> {
    let ext = Path::new(filename?)
        .extension()?
        .to_str()?
        .to_ascii_lowercase();
    (!ext.is_empty() && ext.len() <= 8 && ext.chars().all(|c| c.is_ascii_alphanumeric()))
        .then_some(ext)
}

/// Cache key of a source fetched in `format`: the path without extension.
/// This is the dedupe identity shared by every downloader of the file.
fn cache_key(daemon: &SharedDaemon, source: &Value, format: &str) -> Result<PathBuf> {
    let mxc = mxc_of(source)?;
    Ok(daemon
        .data_dir
        .join("media")
        .join(format_dir(format))
        .join(sanitize(&mxc)))
}

/// Cache path for a source: the key plus an extension picked from the
/// original file name, so `find-file`-style openers see a sane type.
fn cache_path(key: &Path, filename: Option<&str>) -> PathBuf {
    match ext_of(filename) {
        Some(ext) => key.with_file_name(format!(
            "{}.{ext}",
            key.file_name()
                .map(|n| n.to_string_lossy())
                .unwrap_or_default()
        )),
        None => key.to_path_buf(),
    }
}

/// Write `content` to `path` atomically: a `.part` temp file first, so
/// a cancelled or crashed writer never leaves a half-written file
/// behind.  Named for the media cache it lives in, but every crash-
/// sensitive write should go through it — session persistence uses it
/// the same way.
pub(crate) fn write_atomic(path: &Path, content: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    // The temp name derives from the whole file name, not the stem:
    // cache keys are sanitized mxc URIs like `wachter.fi_<id>` — a dot
    // included — and `with_extension("part")` collapsed every key in
    // the directory onto one shared `.part` file, so concurrent
    // downloads raced on it and their renames lost files (ENOENT).
    let part = path.with_file_name(format!(
        "{}.part",
        path.file_name()
            .map(|n| n.to_string_lossy())
            .unwrap_or_default()
    ));
    let mut file = std::fs::File::create(&part)?;
    file.write_all(content)?;
    file.flush()?;
    std::fs::rename(&part, path)?;
    Ok(())
}

/// Remove the in-flight entry for `key` and return its waiters.
/// The one-way door out of the download map: the normal terminal paths
/// and the drop fail-safe below both funnel through here, so the map
/// never keeps an entry whose task is gone.
fn take_download(daemon: &SharedDaemon, key: &str) -> Vec<Waiter> {
    daemon
        .downloads_guard()
        .remove(key)
        .map(|mut d| std::mem::take(&mut d.waiters))
        .unwrap_or_default()
}

/// Drop fail-safe for a download task: if the task ends without
/// reaching a terminal path (a panic, an abort), the entry still sits
/// in the map, its waiters would wait forever, and every later
/// download of the key would join the dead entry.  Drop removes the
/// entry and fails the waiters.  Terminal paths call `take_waiters`
/// first, which disarms the guard.
struct DownloadGuard {
    daemon: SharedDaemon,
    key: String,
    source: Value,
    format: String,
    consumed: bool,
}

impl DownloadGuard {
    /// Take the waiters (removing the entry) and disarm the guard.
    fn take_waiters(&mut self) -> Vec<Waiter> {
        self.consumed = true;
        take_download(&self.daemon, &self.key)
    }
}

impl Drop for DownloadGuard {
    fn drop(&mut self) {
        if !self.consumed {
            let waiters = take_download(&self.daemon, &self.key);
            if !waiters.is_empty() {
                error!("downloadMedia: task for {} died unexpectedly", self.key);
                download_failed(
                    &self.daemon,
                    &waiters,
                    &self.key,
                    &self.source,
                    &self.format,
                    &anyhow!("Download task died unexpectedly"),
                );
            }
        }
    }
}

/// Best-effort remote size probe via HEAD, before the SDK buffers the
/// whole file into memory.  The SDK's fetch (0.19) has no streaming
/// API — it returns one `Vec<u8>` — so without this a multi-GB file
/// is fully resident before the in-memory cap can reject it.  The
/// probe rides the daemon client's own HTTP stack (TLS, proxies,
/// redirect policy) and tries the authenticated media endpoint first,
/// falling back to the legacy one.  `None` means "unknown": the fetch
/// proceeds and the in-memory cap still applies.
///
/// Only the full-file format is probed: thumbnails are generated
/// server-side at bounded size.
async fn probe_download_size(
    client: &matrix_sdk::Client,
    daemon: &SharedDaemon,
    source: &MediaSource,
) -> Option<u64> {
    let uri = match source {
        MediaSource::Plain(uri) => uri,
        MediaSource::Encrypted(file) => &file.url,
    };
    // from_uri validates the mxc and splits it into server/media id.
    let request =
        matrix_sdk::ruma::api::client::authenticated_media::get_content::v1::Request::from_uri(uri)
            .ok()?;
    // The token from the daemon's cached session, not the SDK's auth
    // state: it is exactly what finish_login stored for this client.
    let token = daemon.session()?.access_token;
    let auth = head_content_length(
        client,
        &token,
        format!(
            "/_matrix/client/v1/media/download/{}/{}",
            request.server_name, request.media_id
        ),
    )
    .await;
    match auth {
        Some(len) => Some(len),
        None => {
            head_content_length(
                client,
                &token,
                format!(
                    "/_matrix/media/v3/download/{}/{}",
                    request.server_name, request.media_id
                ),
            )
            .await
        }
    }
}

/// HEAD one media URL and return its Content-Length, if the server
/// answers a HEAD with a success and a length.
async fn head_content_length(
    client: &matrix_sdk::Client,
    token: &str,
    path: String,
) -> Option<u64> {
    let url = client.homeserver().join(&path).ok()?;
    let response = client
        .http_client()
        .head(url)
        .bearer_auth(token)
        .send()
        .await
        .ok()?;
    response.error_for_status().ok()?.content_length()
}

pub async fn handle_download_media(
    daemon: SharedDaemon,
    req: Option<u64>,
    source: Value,
    format: String,
    filename: Option<String>,
) {
    let Some(client) = daemon.client().await else {
        crate::sync::no_session(&daemon, req);
        return;
    };

    let key = match cache_key(&daemon, &source, &format) {
        Ok(k) => k,
        Err(e) => {
            fail_req(&daemon, req, e.to_string());
            return;
        }
    };
    let key_str = key.to_string_lossy().into_owned();
    let path = cache_path(&key, filename.as_deref());

    // Already cached: respond immediately, no fetch.  Only a regular
    // file counts — a directory at this path never passes for media
    // (defense against pathological cache contents, since `mxc_of`
    // now rejects empty keys outright).
    if let Ok(meta) = std::fs::metadata(&path) {
        if meta.is_file() {
            daemon.send(crate::protocol::OutEvent::response(
                req,
                Event::UpdateMediaFile {
                    path: path.to_string_lossy().into_owned(),
                    complete: true,
                    size: Some(meta.len()),
                },
            ));
            return;
        }
    }

    let media_source: MediaSource = match serde_json::from_value(source.clone()) {
        Ok(s) => s,
        Err(e) => {
            fail_req(&daemon, req, format!("Bad media source: {e}"));
            return;
        }
    };
    let media_format = if format == "thumb" {
        MediaFormat::Thumbnail(MediaThumbnailSettings::new(128u32.into(), 128u32.into()))
    } else {
        MediaFormat::File
    };

    // Join-or-spawn, atomically: the lock is held across the spawn, so
    // the task (which removes itself from the map once it finishes)
    // cannot possibly run before its own entry exists — the old
    // spawn-then-insert let a fast task strand its request forever.
    let task_daemon = daemon.clone();
    let task_key = key_str.clone();
    {
        let mut downloads = daemon.downloads_guard();
        if let Some(download) = downloads.get_mut(&key_str) {
            download.waiters.push(Waiter {
                req,
                path: path.clone(),
            });
            info!("downloadMedia: joining in-flight download of {key_str}");
            return;
        }
        let handle = tokio::spawn(download_task(
            task_daemon,
            client,
            task_key,
            path.clone(),
            source,
            media_source,
            format,
            media_format,
        ));
        downloads.insert(
            key_str.clone(),
            Download {
                handle,
                waiters: vec![Waiter {
                    req,
                    path: path.clone(),
                }],
            },
        );
    }
}

/// Body of one spawned download task: probe the remote size, fetch,
/// write every cache path involved, and settle the waiters.  The
/// DownloadGuard arms on entry and is disarmed by every terminal path
/// below; a panic or abort leaves Drop to fail the waiters.
// The eight parameters are the task's disentangled payload; binding
// them into a struct would thread it through every branch below for
// no other reader's benefit.
#[allow(clippy::too_many_arguments)]
async fn download_task(
    daemon: SharedDaemon,
    client: matrix_sdk::Client,
    key: String,
    path: PathBuf,
    source: Value,
    media_source: MediaSource,
    format: String,
    media_format: MediaFormat,
) {
    daemon.emit(Event::UpdateDownload {
        source: source.clone(),
        format: format.clone(),
        state: "downloading".into(),
        size: None,
        error: None,
    });

    // Disarmed by every terminal path; if the task dies
    // before one (panic, abort), Drop fails the waiters.
    let mut guard = DownloadGuard {
        daemon: daemon.clone(),
        key: key.clone(),
        source: source.clone(),
        format: format.clone(),
        consumed: false,
    };

    // The fetch happens in one piece: bound it in both time and
    // size so a stuck or oversized download cannot hang or eat
    // the daemon.
    let is_file = matches!(media_format, MediaFormat::File);
    let params = MediaRequestParameters {
        source: media_source,
        format: media_format,
    };

    // HEAD the remote size first when we can (full files only):
    // the SDK has no streaming fetch, so the in-memory cap
    // otherwise bites only after a multi-GB buffer exists.
    // An unanswered probe (no HEAD support, no length header)
    // just falls through to the fetch below.
    if is_file {
        if let Some(len) = tokio::time::timeout(
            std::time::Duration::from_secs(30),
            probe_download_size(&client, &daemon, &params.source),
        )
        .await
        .ok()
        .flatten()
        {
            if len > MAX_DOWNLOAD_BYTES as u64 {
                let waiters = guard.take_waiters();
                download_failed(
                    &daemon,
                    &waiters,
                    &key,
                    &source,
                    &format,
                    &anyhow!(
                        "Media too large for the download cache (limit {} MiB): \
                         {len} bytes on the server",
                        MAX_DOWNLOAD_BYTES / (1024 * 1024)
                    ),
                );
                return;
            }
        }
    }

    let media = client.media();
    let fetch = media.get_media_content(&params, true);
    let outcome: Result<Vec<u8>, anyhow::Error> =
        match tokio::time::timeout(DOWNLOAD_TIMEOUT, fetch).await {
            Ok(Ok(content)) => Ok(content),
            Ok(Err(e)) => Err(e.into()),
            Err(_) => Err(anyhow!("Download timed out after {DOWNLOAD_TIMEOUT:?}")),
        };

    // Take ownership of the waiters.  If we were cancelled, the entry
    // is gone and the waiters are empty — respond to nobody.
    let waiters = guard.take_waiters();

    let emit_state = |state: &str, size: Option<u64>, error: Option<String>| {
        daemon.emit(Event::UpdateDownload {
            source: source.clone(),
            format: format.clone(),
            state: state.into(),
            size,
            error,
        });
    };

    let content = match outcome {
        Ok(content) => content,
        Err(e) => {
            download_failed(&daemon, &waiters, &key, &source, &format, &e);
            return;
        }
    };
    if content.len() > MAX_DOWNLOAD_BYTES {
        // Backstop for the HEAD probe coming back empty: the
        // file was buffered to get here, but it never reaches
        // the disk.
        download_failed(
            &daemon,
            &waiters,
            &key,
            &source,
            &format,
            &anyhow!(
                "Media too large for the download cache (limit {} MiB)",
                MAX_DOWNLOAD_BYTES / (1024 * 1024)
            ),
        );
        return;
    }
    let len = content.len() as u64;
    // Write the spawner's cache entry, then every waiter whose
    // filename (and so extension) differs: the bytes are one
    // download, but each filename owns its own cache entry, so
    // the waiter's next request answers from the cache instead
    // of re-joining forever.  All writes ride one blocking
    // task; a failure anywhere fails everyone (the entry is
    // gone either way).
    let mut paths: Vec<PathBuf> = vec![path];
    for waiter in &waiters {
        if !paths.contains(&waiter.path) {
            paths.push(waiter.path.clone());
        }
    }
    let write = match tokio::task::spawn_blocking(move || {
        paths
            .iter()
            .map(|p| write_atomic(p, &content))
            .collect::<Vec<_>>()
    })
    .await
    {
        Ok(writes) => writes.into_iter().collect::<Result<Vec<_>, _>>(),
        Err(e) => Err(e.into()),
    };
    if let Err(e) = write {
        download_failed(&daemon, &waiters, &key, &source, &format, &e);
        return;
    }
    info!("downloadMedia: {key} ({len} bytes)");
    emit_state("done", Some(len), None);
    for waiter in waiters {
        daemon.send(crate::protocol::OutEvent::response(
            waiter.req,
            Event::UpdateMediaFile {
                path: waiter.path.to_string_lossy().into_owned(),
                complete: true,
                size: Some(len),
            },
        ));
    }
}

/// Fail one request that never got far enough to join the download
/// map (bad source, unusable cache key): log it, then ack it false.
/// The download_failed counterpart below handles everything that did
/// become a download.
fn fail_req(daemon: &SharedDaemon, req: Option<u64>, msg: String) {
    error!("downloadMedia: {msg}");
    daemon.send(crate::protocol::OutEvent::ack(req, false, Some(msg)));
}

/// Common error path: notify listeners and fail all waiters.
fn download_failed(
    daemon: &SharedDaemon,
    waiters: &[Waiter],
    key: &str,
    source: &Value,
    format: &str,
    e: &anyhow::Error,
) {
    error!("downloadMedia: {key} failed: {e:#}");
    daemon.emit(Event::UpdateDownload {
        source: source.clone(),
        format: format.to_string(),
        state: "error".into(),
        size: None,
        error: Some(format!("{e:#}")),
    });
    for waiter in waiters {
        daemon.send(crate::protocol::OutEvent::ack(
            waiter.req,
            false,
            Some(format!("Media download failed: {e:#}")),
        ));
    }
}

/// Cancel the in-flight download of `source`, if any.  Idempotent: with no
/// matching download it still succeeds.
pub fn handle_cancel_download(
    daemon: SharedDaemon,
    req: Option<u64>,
    source: Value,
    format: String,
) {
    let key = match cache_key(&daemon, &source, &format) {
        Ok(k) => k.to_string_lossy().into_owned(),
        Err(e) => {
            fail_req(&daemon, req, e.to_string());
            return;
        }
    };

    let download = daemon.downloads_guard().remove(&key);
    if let Some(download) = download {
        download.handle.abort();
        for waiter in download.waiters {
            daemon.send(crate::protocol::OutEvent::ack(
                waiter.req,
                false,
                Some("Download cancelled".into()),
            ));
        }
        warn!("downloadMedia: cancelled {key}");
        daemon.emit(Event::UpdateDownload {
            source,
            format,
            state: "cancelled".into(),
            size: None,
            error: None,
        });
    }
    daemon.send(crate::protocol::OutEvent::ack(req, true, None));
}

/// Answer where `source` lives in the cache; never starts a download.
pub fn handle_get_media_file(
    daemon: SharedDaemon,
    req: Option<u64>,
    source: Value,
    format: String,
) {
    let key = match cache_key(&daemon, &source, &format) {
        Ok(k) => k,
        Err(e) => {
            fail_req(&daemon, req, e.to_string());
            return;
        }
    };
    // The exact path depends on the (unknown here) extension; look for any
    // cache file under this key.  In-flight `.part` files never count as
    // complete.
    let key_name = key
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let cached = std::fs::read_dir(key.parent().unwrap_or(key.as_path()))
        .ok()
        .and_then(|entries| {
            // Exact match, or this key plus an extension ("hs_abc.mp4"):
            // a longer key that merely shares the prefix ("hs_abcdef")
            // is a different file.  With both shapes present the
            // extensionless one wins, so the answer does not depend on
            // read_dir's ordering.
            let mut with_ext = None;
            let mut exact = None;
            for entry in entries.filter_map(Result::ok) {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                let matches = name == key_name
                    || name
                        .strip_prefix(&key_name)
                        .is_some_and(|rest| rest.starts_with('.'));
                if !matches {
                    continue;
                }
                let path = entry.path();
                if path.extension().map(|ext| ext != "part").unwrap_or(true) {
                    let len = entry.metadata().ok().map(|m| m.len());
                    if let Some(len) = len {
                        if name == key_name {
                            exact = Some((path, len));
                        } else {
                            with_ext = with_ext.or(Some((path, len)));
                        }
                    }
                }
            }
            exact.or(with_ext)
        });
    let (path, complete, size) = match cached {
        Some((path, len)) => (path.to_string_lossy().into_owned(), true, Some(len)),
        None => (key.to_string_lossy().into_owned(), false, None),
    };
    daemon.send(crate::protocol::OutEvent::response(
        req,
        Event::UpdateMediaFile {
            path,
            complete,
            size,
        },
    ));
}
#[cfg(test)]
mod tests {
    use super::*;

    /// The mxc URI is the dedupe seed: it must come out of both wire shapes
    /// of a `MediaSource`.
    #[test]
    fn mxc_of_both_source_shapes() {
        let plain = serde_json::json!({"url": "mxc://example.org/abc123"});
        assert_eq!(mxc_of(&plain).unwrap(), "mxc://example.org/abc123");

        let encrypted = serde_json::json!({"file": {
            "url": "mxc://example.org/enc123",
            "key": {
                "kty": "oct", "key_ops": ["decrypt", "encrypt"], "alg": "A256CTR",
                "ext": true, "k": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            },
            "iv": "AAAAAAAAAAAAAAAAAAAAAA",
            "hashes": {"sha256": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"},
            "v": "v2"
        }});
        assert_eq!(mxc_of(&encrypted).unwrap(), "mxc://example.org/enc123");

        assert!(mxc_of(&serde_json::json!({})).is_err());

        // Naming nothing: rejected before it can become a cache key
        // (an empty key makes the cache path the thumb directory).
        assert!(mxc_of(&serde_json::json!({"url": ""})).is_err());
        assert!(mxc_of(&serde_json::json!({"url": "mxc://"})).is_err());
    }

    /// Cache names stay readable and filesystem-safe.
    #[test]
    fn sanitize_is_filesystem_safe() {
        assert_eq!(sanitize("mxc://example.org/abc123"), "example.org_abc123");
        assert_eq!(sanitize("mxc://server/../evil"), "server_.._evil");
        assert_eq!(sanitize("mxc://"), "");
        let long = format!("mxc://{}", "a".repeat(300));
        assert_eq!(sanitize(&long).len(), MAX_KEY_LEN);
    }

    /// Only sane, short, lowercase extensions make it into the cache path.
    #[test]
    fn ext_of_filters_filenames() {
        assert_eq!(ext_of(Some("clip.mp4")).as_deref(), Some("mp4"));
        assert_eq!(ext_of(Some("Weird.VIDEO")).as_deref(), Some("video"));
        assert_eq!(ext_of(Some("archive.tar.gz")).as_deref(), Some("gz"));
        assert_eq!(ext_of(Some("noext")), None);
        assert_eq!(ext_of(None), None);
        // Too long, and not alphanumeric: dropped rather than trusted.
        assert_eq!(ext_of(Some("file.verylongextension")), None);
        assert_eq!(ext_of(Some("file.not/valid")), None);
    }

    /// The extension lands on the cache path next to the key; without one
    /// the key itself is the path.
    #[test]
    fn cache_path_appends_ext() {
        let key = std::path::Path::new("/cache/media/file/hs_abc");
        assert_eq!(
            cache_path(key, Some("clip.mp4")),
            std::path::PathBuf::from("/cache/media/file/hs_abc.mp4")
        );
        assert_eq!(
            cache_path(key, Some("noext")),
            std::path::PathBuf::from("/cache/media/file/hs_abc")
        );
        assert_eq!(
            cache_path(key, None),
            std::path::PathBuf::from("/cache/media/file/hs_abc")
        );
    }

    /// A dotted key (every sanitized mxc is one) keeps its full name in
    /// the temp file — `with_extension("part")` once collapsed all keys
    /// in a directory onto a single shared `.part` file.
    #[test]
    fn write_atomic_part_names_stay_unique() {
        let a = std::path::Path::new("/cache/media/thumb/wachter.fi_A");
        let b = std::path::Path::new("/cache/media/thumb/wachter.fi_B");
        let part_of = |p: &std::path::Path| {
            p.with_file_name(format!(
                "{}.part",
                p.file_name()
                    .map(|n| n.to_string_lossy())
                    .unwrap_or_default()
            ))
        };
        assert_ne!(part_of(a), part_of(b));
        assert_eq!(
            part_of(a),
            std::path::PathBuf::from("/cache/media/thumb/wachter.fi_A.part")
        );
    }

    /// Over-long ids do not truncate: two distinct ones sharing a
    /// 180-char prefix once collapsed onto one cache file, and the
    /// second request was served the first's bytes.  The digest tail
    /// keeps the full id in play.
    #[test]
    fn sanitize_does_not_truncate_long_ids_into_one_key() {
        let head = "wachter.fi_".to_string();
        let a = format!("mxc://{head}{}", "a".repeat(300));
        let b = format!("mxc://{head}a{}", "b".repeat(300));
        assert_eq!(sanitize(&a).len(), MAX_KEY_LEN);
        assert_ne!(sanitize(&a), sanitize(&b));
        // Deterministic, and the readable host survives up front.
        assert_eq!(sanitize(&a), sanitize(&a));
        assert!(sanitize(&a).starts_with(&head));
        // Short ids keep their plain shape (no digest sprinkled in).
        assert_eq!(sanitize("mxc://hs.abc/mediaid"), "hs.abc_mediaid");
        // And the digest really is a function of the full sanitized id.
        let c = format!("mxc://{head}a{}", "c".repeat(300));
        assert_ne!(sanitize(&a), sanitize(&c));
    }
}
