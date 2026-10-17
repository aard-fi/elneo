//! elneo-server: Matrix client daemon for Emacs.
//!
//! We run one daemon process per profile, communicating with Emacs over framed
//! JSON on stdio (see [`protocol`]); rooms and E2EE state persist under a per-
//! profile data directory.
//!
//! # System layout
//!
//! Emacs and the daemon are separate processes with deliberately separate
//! responsibilities.  On the Emacs side only UI lives:
//! `elneo-server.el` is transport only (frame writes/reads and `@req`
//! correlation), `elneo-client.el` keeps the account/room registry and
//! fans every daemon event into hooks the UI layers subscribe to
//! (`elneo-room.el` room buffers, `elneo-room-bar.el` the fixed
//! side-window bar, alerting).  Everything Matrix lives here: the client
//! lifecycle, homeserver connection and continuous sync, E2EE, and the
//! encrypted persistent stores (one data directory per profile — the
//! `matrix-rust-sdk` sqlite state and crypto stores plus `session.json`;
//! the Emacs side keeps only non-secrets).
//!
//! The modules of this crate:
//!
//! - [`daemon`]: core — client lifecycle, the framed stdio run loop
//!   (a single writer thread owns stdout; stdin is read on a blocking
//!   thread and commands dispatch sequentially), and the command handlers
//!   not owning their own module.  The `daemonInfo` greeting is queued
//!   in `main` before anything can emit, so it is always frame one.
//! - [`protocol`]: the wire contract — command/event enums, framing, and
//!   the `PROTOCOL_VERSION` gate Emacs activates sessions on.
//! - [`sync`]: the continuous sync loop and the per-event derivations
//!   (room summaries, edits/reactions/receipts merging).
//! - [`media`]: an on-disk media cache in front of the SDK's media
//!   fetches, running downloads as spawned tasks so they cannot stall
//!   command dispatch.
//! - [`verification`]: interactive SAS device verification and key
//!   recovery/SSSS flows.
//!
//! # Testing the daemon by hand
//!
//! ```bash
//! cargo run -- -p test -v 4
//! # then feed a frame on stdin, e.g.:
//! # send 28
//! # {"@type":"getSession","@req":1}
//! ```
//!
//! The daemon's first outbound frame is its `daemonInfo` greeting;
//! `elneo-server --version` prints the release version.  Tracing output
//! goes to stderr unless a `-l` log file is given: the framed protocol
//! owns stdout, so it must stay clean (the Emacs side normally passes
//! `-l` explicitly).

mod daemon;
mod media;
mod protocol;
mod sync;
mod verification;

use anyhow::Result;
use clap::Parser;

#[derive(Parser, Debug)]
#[command(name = "elneo-server")]
#[command(about = "Matrix client daemon for Emacs", long_about = None)]
#[command(version)]
struct Args {
    /// Profile name for this session (allows multiple concurrent sessions)
    #[arg(short, long, default_value = "default")]
    profile: String,

    /// Verbosity level (0-5)
    #[arg(short, long, default_value = "3")]
    verbosity: u8,

    /// Log file path
    #[arg(short, long)]
    logfile: Option<std::path::PathBuf>,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    // Setup logging.  The framed protocol uses stdout, so logs go to stderr
    // unless a log file is given (Emacs merges stderr into the process
    // buffer, so it should normally pass -l explicitly).
    let level = match args.verbosity {
        0 => tracing::Level::ERROR,
        1 => tracing::Level::WARN,
        2 => tracing::Level::INFO,
        3 => tracing::Level::DEBUG,
        _ => tracing::Level::TRACE,
    };
    if let Some(logfile) = &args.logfile {
        let file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(logfile)?;
        let writer = std::sync::Mutex::new(file);
        tracing_subscriber::fmt()
            .with_max_level(level)
            .with_writer(writer)
            .init();
    } else {
        tracing_subscriber::fmt()
            .with_max_level(level)
            .with_writer(std::io::stderr)
            .init();
    }

    let (ev_tx, ev_rx) = tokio::sync::mpsc::unbounded_channel();
    // Greeting first: queue it before spawning the writer (and before
    // anything else can emit, including restore_session inside
    // ElneoDaemon::new), so it is frame 1 of the connection.
    let greeting = protocol::OutEvent::event(protocol::Event::DaemonInfo {
        protocol: protocol::PROTOCOL_VERSION,
        release: protocol::RELEASE_VERSION.into(),
    });
    if let Err(err) = ev_tx.send(greeting) {
        anyhow::bail!("event channel closed before greeting: {err}");
    }
    tracing::info!(
        "elneo-server {} speaking protocol {}",
        protocol::RELEASE_VERSION,
        protocol::PROTOCOL_VERSION
    );
    daemon::spawn_writer(ev_rx);

    let daemon = daemon::ElneoDaemon::new(args.profile, ev_tx)?;
    daemon.run().await
}
