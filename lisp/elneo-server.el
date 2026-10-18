;;; elneo-server.el --- Matrix server daemon interface -*- lexical-binding: t -*-

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;;; Commentary:

;; Interface to the elneo-server Rust daemon process: process
;; lifecycle, the framed JSON protocol over stdin/stdout, and
;; request/response correlation.  The daemon owns all Matrix protocol
;; communication; this file never talks to a homeserver directly.
;;
;; The layers are deliberately separate (the daemon-side narrative
;; lives in the daemon's rustdoc, server/src/main.rs): this file is
;; transport only — framing and `@req' correlation; elneo-client.el
;; holds the account/room registry and fans daemon events into
;; `elneo-room-update-hook' and `elneo-new-message-hook'; the bar
;; and room buffers subscribe to those hooks instead of talking to
;; daemons directly.  Keep that order when adding features.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'url)

(defgroup elneo nil
  "Matrix client for Emacs."
  :group 'comm
  :prefix "elneo-")

(defcustom elneo-server-command "elneo-server"
  "Command to start the elneo-server daemon."
  :type 'string
  :group 'elneo)

(defcustom elneo-server-verbosity 3
  "Verbosity level for elneo-server (0-5).
0 = error, 1 = warn, 2 = info, 3 = debug, 4+ = trace"
  :type 'integer
  :group 'elneo)

(defcustom elneo-server-logfile nil
  "Log file path for elneo-server.
If nil, logs to stderr."
  :type '(choice (const :tag "stderr" nil)
                 (file :tag "Log file"))
  :group 'elneo)

(defcustom elneo-default-profile "default"
  "Default profile name for Matrix sessions."
  :type 'string
  :group 'elneo)

(defcustom elneo-device-name
  (concat "ElNeo " (system-name))
  "Display name for the device a login creates.
Shown to other clients in their session list (and in this client's
own security view); the hostname makes concurrent sessions on
different machines distinguishable."
  :type 'string
  :group 'elneo)

(defcustom elneo-debug nil
  "When non-nil, log protocol chatter to the *Matrix Debug* buffer.
Covers outgoing commands, process state changes, session restores
and cross-signing updates.  Genuine errors are always shown in the
echo area regardless of this setting."
  :type 'boolean
  :group 'elneo)

(defconst elneo-daemon-protocol 23
  "Wire protocol version this Emacs side speaks.
Not a setting — this names what this code implements, and must mirror
the daemon's `PROTOCOL_VERSION' in server/src/protocol.rs: bump the two
together in one commit, whenever a golden-tested event or command
shape changes.  defconst rather than defcustom/defvar: `elneo-reload'
must refresh it in a running session (defvar semantics would keep a
stale binding from an older build and misgrade every greeting).
History: the canonical list lives in the `PROTOCOL_VERSION' doc
comment in server/src/protocol.rs — read it there instead of
maintaining two copies.")

(defconst elneo-daemon-protocol-minimum 1
  "Oldest daemon protocol version this client still activates with.
Not a setting — a maintainership constant, reviewed with every
protocol change.  It stays at the value of `elneo-daemon-protocol'
as long as an old daemon degrades gracefully; raise it only when a
daemon older than that misbehaves in a way the client cannot paper
over.

Per-feature guards use the version via
`elneo-server--daemon-protocol' — never compare it unguarded against
a number: a pre-versioning daemon reports no version at all.")

(defcustom elneo-daemon-protocol-allow-outdated nil
  "When non-nil, start a session even with a daemon below the minimum.
For emergencies only: below-minimum daemons can misbehave in ways
the client cannot paper over."
  :type 'boolean
  :group 'elneo)

(defcustom elneo-server-auto-restart t
  "Restart a daemon that died on its own, with a backoff.
A deliberate stop (`elneo-server-stop', logout, forget, quit)
suppresses the restarter — only an unattended death or a dead
sync counts.  Restarting walks `elneo-server-restart-backoff'
doubling up to `elneo-server-restart-backoff-max'."
  :type 'boolean
  :group 'elneo)

(defcustom elneo-server-restart-backoff 5
  "Seconds before the first automatic restart of a dead daemon.
Doubling every attempt (5, 10, 20, ...), capped by
`elneo-server-restart-backoff-max'."
  :type 'integer
  :group 'elneo)

(defcustom elneo-server-restart-backoff-max 30
  "Cap of the automatic restart backoff, in seconds."
  :type 'integer
  :group 'elneo)

(defcustom elneo-server-auto-restart-max-attempts nil
  "Give up automatic restarts after this many failed attempts.
nil retries forever at the capped backoff; an integer stops the
restarter with a final message pointing at
`M-x elneo-restart-server', useful when a corrupt state store
keeps the daemon crashlooping."
  :type '(choice (const :tag "Retry forever" nil)
                 (integer :tag "Max attempts"))
  :group 'elneo)

(defun elneo--debug-log (format &rest args)
  "Append a timestamped FORMAT line to the *Matrix Debug* buffer.
Does nothing when `elneo-debug' is nil."
  (when elneo-debug
    (with-current-buffer (get-buffer-create "*Matrix Debug*")
      (goto-char (point-max))
      (insert (format-time-string "[%H:%M:%S] ")
              (apply #'format format args) "\n"))))

;;; Server runtime variables

(defvar elneo-server--buffers nil
  "Alist of (PROFILE . BUFFER) for active elneo-server processes.")

(defvar elneo-server--callbacks nil
  "Alist of (PROFILE . CALLBACK-TABLE) for server callbacks.
Each callback table is a hash table mapping event types to callback functions.")

(defvar elneo-server--pending nil
  "Alist of (PROFILE . PENDING-TABLE) for in-flight requests.
Each pending table maps a request id (integer) to a callback function
called with (PROFILE RESPONSE-EVENT) when the matching response arrives.")

(defvar elneo-server--next-req 1
  "Next request id for `elneo-server--call'.")

(defvar elneo-server--sessions nil
  "Alist of (PROFILE . SESSION-INFO) for active sessions.
SESSION-INFO is a plist with :user-id, :device-id, and :access-token.")

(defvar elneo-server--trust nil
  "Alist of (PROFILE . ENABLED-AND-TRUSTED) for live sessions.
ENABLED-AND-TRUSTED is the cons (ENABLED . TRUSTED) the daemon
reports from its cross-signing state: whether the account has
cross-signing keys at all, and whether this session trusts them.
Entries are only kept while the daemon lives — `elneo-server--sentinel'
prunes them — and a nil ENABLED means an account that never
bootstrapped (no bar row, no nagging: there is nothing to verify).")

(defvar elneo-server--daemon-info nil
  "Alist of (PROFILE . INFO) recorded from the daemon's greeting.
INFO is a plist (:protocol VERSION :release RELEASE) from the
daemonInfo frame, which the daemon sends as the very first frame
of every connection.  Entries are only kept while the daemon
lives; a missing entry means a pre-versioning daemon.")

(defvar elneo-server--sync-states nil
  "Alist of (PROFILE . (STATE . ERROR)) — each daemon's sync state.
STATE is the daemon's own sync-state report (\"starting\",
\"syncing\", \"synced\", \"error\") or \"offline\" after the
process died; ERROR is the daemon's error string for the error
state, or the exit status for \"offline\".  Unlike
`elneo-server--trust' this is a state, not a live snapshot: the
sentinel *writes* the offline entry and must not prune it — if the
sentinel's prune block is ever extended to sweep all per-profile
alists, this one is the exception that keeps the bar's state row
telling the truth about what is down.")

(defvar elneo-server--manual-stops nil
  "Alist of (PROFILE . t) while a deliberate `elneo-server-stop' holds.
Set before `delete-process' runs the sentinel, cleared by the next
`elneo-server-start': logout, forget-profile, quit and manual
restart all flow through the stop, so they suppress the automatic
restarter without any of them needing to know about it.")

(defvar elneo-server--restarts nil
  "Alist of (PROFILE . (:attempts N :timer TIMER)).
Auto-restart bookkeeping per dead daemon; the timer is non-nil
only while a restart is actually pending.")

(defcustom elneo-session-trust-hook nil
  "Hook run when a PROFILE's cross-signing state changes.
Called with PROFILE, ENABLED and TRUSTED, exactly as recorded in
`elneo-server--trust'.  Runs on every updateCrossSigningStatus
event, including the duplicates the daemon emits at login and on
piggybacked getSession calls."
  :type 'hook
  :group 'elneo)

(defcustom elneo-session-sync-hook nil
  "Hook run when a PROFILE's daemon sync state changes.
Called with PROFILE, STATE and ERROR-MESSAGE, exactly as recorded in
`elneo-server--sync-states'.  The daemon repeats updateSyncState on
every reconnect loop and at every login — unlike
`elneo-session-trust-hook' this fires only on transitions, which is
what the UI consumers (the bar's state row, the mode line, the
auto-restart scheduler) want."
  :type 'hook
  :group 'elneo)

;;; Process management

(defun elneo-server--get-buffer (profile)
  "Get the server buffer for PROFILE, or nil if not running."
  (cdr (assoc profile elneo-server--buffers)))

(defun elneo-server--get-process (profile)
  "Get the server process for PROFILE, or nil if not running."
  (when-let* ((buffer (elneo-server--get-buffer profile)))
    (get-buffer-process buffer)))

(defun elneo-server-live-p (profile)
  "Return non-nil if elneo-server process is alive for PROFILE."
  (process-live-p (elneo-server--get-process profile)))

(defun elneo-server--ensure-callbacks (profile)
  "Ensure callback table exists for PROFILE, with its defaults.
Always re-asserts the greeting handler, however this session came to
have a table: a table built by an older build, a stale .elc, or a hot
reload into a running session would otherwise drop the greeting
silently, and the protocol gate would block on :unknown with no way
to recover (client handlers register only past the gate)."
  ;; The greeting is always the daemon's first frame, arriving before
  ;; the client layer registers its handlers; the transport owns it.
  (let ((table (or (cdr (assoc profile elneo-server--callbacks))
                   (let ((fresh (make-hash-table :test 'equal)))
                     (push (cons profile fresh) elneo-server--callbacks)
                     fresh))))
    (puthash "daemonInfo" #'elneo-server--on-daemon-info table)
    ;; Sync state tracking is likewise transport-owned: it must work
    ;; even for an inert (gate-blocked or never-activated) session.
    (puthash "updateSyncState" #'elneo-server--on-update-sync-state table)))

(defun elneo-server--get-callbacks (profile)
  "Get callback table for PROFILE."
  (elneo-server--ensure-callbacks profile)
  (cdr (assoc profile elneo-server--callbacks)))

(defun elneo-server--pending-table (profile)
  "Get (creating if needed) the pending-request table for PROFILE."
  (let ((entry (assoc profile elneo-server--pending)))
    (unless entry
      (setq entry (cons profile (make-hash-table :test 'eq)))
      (push entry elneo-server--pending))
    (cdr entry)))

;;; Event handling

(defun elneo-server--dispatch-event (profile event)
  "Dispatch EVENT for PROFILE.
Events carrying an `@req' id are routed to the pending callback for
that request; all others dispatch to the typed callback table."
  (let ((req (alist-get '@req event nil nil #'equal)))
    (if req
        (let ((callback (gethash req (elneo-server--pending-table profile))))
          (when callback
            (remhash req (elneo-server--pending-table profile))
            (condition-case err
                (funcall callback profile event)
              (error
               (message "Matrix [%s] error in response callback for request %s: %s"
                        profile req err)))))
      (let* ((event-type (alist-get '@type event))
             (callbacks (elneo-server--get-callbacks profile))
             (callback (gethash event-type callbacks)))
        (when callback
          (condition-case err
              (funcall callback profile event)
            (error
             (message "Matrix [%s] error in callback for %s: %s"
                      profile event-type err))))))))

(defun elneo-server--parse-event (profile)
  "Parse a single event from the server buffer for PROFILE.
Returns the parsed event as an alist, or nil if incomplete.
The process buffer is unibyte (see `elneo-server-start'), so
buffer positions and `event' sizes are byte counts — the frame
protocol counts UTF-8 bytes, not characters."
  (condition-case err
      (with-current-buffer (elneo-server--get-buffer profile)
        (goto-char (point-min))
        (when (re-search-forward "^event \\([0-9]+\\)\n" nil t)
          (let ((event-size (string-to-number (match-string 1))))
            (when (>= (- (point-max) (point)) (+ event-size 1))
              (let* ((json-start (point))
                     (json-end (+ json-start event-size))
                     ;; Raw UTF-8 bytes; decode before json.el sees them.
                     (json-str (decode-coding-string
                                (buffer-substring-no-properties
                                 json-start json-end)
                                'utf-8))
                     ;; JSON false/null must arrive as nil: json.el's defaults
                     ;; (:false / :json-null) are truthy symbols, which would
                     ;; turn "@ok": false into a success.
                     (event (let ((json-false nil) (json-null nil))
                              (json-read-from-string json-str))))
                ;; Delete processed data including trailing newline
                (delete-region (point-min) (1+ json-end))
                event)))))
    ;; A malformed frame must not kill the drain loop; drop up to the first
    ;; newline and continue.
    (error
     (message "Matrix [%s] malformed event frame: %s" profile err)
     (with-current-buffer (elneo-server--get-buffer profile)
       (goto-char (point-min))
       (when (re-search-forward "\n" nil t)
         (delete-region (point-min) (point))))
     nil)))

(defun elneo-server--filter (profile proc output)
  "Process filter for elneo-server PROC with PROFILE.
OUTPUT is the new data received."
  (when-let* ((buffer (process-buffer proc)))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert output)
      ;; Process all available events; an error in one event must not
      ;; abandon the rest.
      (let (event)
        (while (setq event (condition-case nil
                               (elneo-server--parse-event profile)
                             (error nil)))
          (condition-case err
              (elneo-server--dispatch-event profile event)
            (error (message "Matrix [%s] event dispatch error: %s" profile err))))))))

(defun elneo-server--flush-pending (profile reason)
  "Fail every in-flight request of PROFILE with REASON.
Each callback fires as a failed wire response would — a bare
`@req'-less ack, `@ok' false, `@error' REASON — so a view waiting
on an answer learns the daemon went away instead of waiting
forever (a room buffer left unfilled by a dropped backfill would
show its failure notice, not just sit empty)."
  (let ((entry (assoc profile elneo-server--pending)))
    (when entry
      (let ((table (cdr entry))
            (event (list (cons '@error reason))))
        (maphash (lambda (req callback)
                   (when callback
                     (condition-case err
                         ;; The daemon is gone; a callback that tries
                         ;; to answer it can only fail — one callback
                         ;; erroring must not strand the rest.
                         (funcall callback profile event)
                       (error
                        (message "Matrix [%s] flushed callback for request %s: %s"
                                 profile req err)))))
                 table)
        (clrhash table))))
  (setq elneo-server--pending
        (assoc-delete-all profile elneo-server--pending)))

(defun elneo-server--sentinel (profile proc event)
  "Process sentinel for elneo-server PROC with PROFILE.
EVENT describes the state change."
  (let ((status (substring event 0 -1)))
    (elneo--debug-log "Matrix [%s] server: %s" profile status)
    (unless (process-live-p proc)
      (unless (string= status "deleted")
        ;; A daemon that died on its own is worth a message.
        (message "Matrix [%s] server exited: %s" profile status))
      (setq elneo-server--buffers
            (assoc-delete-all profile elneo-server--buffers))
      (setq elneo-server--sessions
            (assoc-delete-all profile elneo-server--sessions))
      (elneo-server--flush-pending profile status)
      ;; The daemon's trust snapshot is gone with it; stale cons cells
      ;; must not keep a verify row in the bar.
      (setq elneo-server--trust
            (assoc-delete-all profile elneo-server--trust))
      (setq elneo-server--daemon-info
            (assoc-delete-all profile elneo-server--daemon-info))
      ;; The sync-state entry, by contrast, is the death's own record
      ;; ("offline" + exit status) — deliberately NOT pruned; see its
      ;; defvar.
      (elneo-server--record-sync-state profile "offline" status))))

;;; Communication with server

(defun elneo-server--send (profile command)
  "Send COMMAND to elneo-server for PROFILE.
COMMAND should be an alist that will be JSON-encoded."
  (unless (elneo-server-live-p profile)
    (user-error "Matrix server not running for profile: %s" profile))
  (let* ((json-str (json-encode command))
         (json-bytes (encode-coding-string json-str 'utf-8))
         (size (length json-bytes))
         (proc (elneo-server--get-process profile)))
    (elneo--debug-log "Matrix [%s] sending: %s" profile (json-encode-alist command))
    (process-send-string proc (format "send %d\n" size))
    (process-send-string proc json-bytes)
    (process-send-string proc "\n")))

(defun elneo-server--call (profile command callback)
  "Send COMMAND to elneo-server for PROFILE with request correlation.
CALLBACK (PROFILE RESPONSE-EVENT) is invoked exactly once when the
terminal response arrives (or with an event whose `@ok' is nil on
failure).  Returns the request id.
Cross-module contract: elneo-verify.el and the client both build
commands on this despite the `--' name."
  (let ((req elneo-server--next-req)
        (command (append command `((@req . ,elneo-server--next-req)))))
    (setq elneo-server--next-req (1+ elneo-server--next-req))
    (when callback
      (puthash req callback (elneo-server--pending-table profile)))
    (elneo-server--send profile command)
    req))

(defun elneo-server--error-string (event)
  "Extract the error message from a failed response EVENT."
  (or (alist-get '@error event nil nil #'equal)
      "unknown error"))

;;; Release downloads

;; The CI (`.github/workflows/ci.yml') publishes the built daemon
;; binaries plus SHA256SUMS on every `v*' tag.  When this machine has
;; no working `elneo-server-command' — or a daemon turns out below the
;; supported protocol minimum — elneo can offer to fetch the matching
;; latest release; both call sites ask with `y-or-n-p' first, and a no
;; changes nothing.  A download is synchronous, verified against the
;; release's SHA256SUMS, mode 0755, and installed next to the daemon's
;; own state in the elneo data dir — no PATH convention is relied on.

(defvar elneo-release-repo "aard-fi/elneo"
  "GitHub slug whose latest release carries the daemon binaries.
Also what to point at a fork: downloads fetch
`elneo-release--url' under this repository.")

(defvar elneo-server--download-offered nil
  "Alist of (PROFILE . t) once PROFILE's missing-binary offer ran.
Both a no and a failed download land here — the auto-restart tick
starts daemons too, and every backoff cycle must not re-ask
through the echo area.  Cleared by the next successful
`elneo-server-start', which re-arms the offer the next time the
machine has no binary.")

(declare-function elneo--data-dir-base "elneo-client" nil)

(defun elneo-release--arch ()
  "The release asset architecture word for this machine, or nil."
  (cond
   ((string-prefix-p "x86_64" system-configuration) "x86_64")
   ((string-prefix-p "aarch64" system-configuration) "arm64")
   (t nil)))

(defun elneo-release--platform ()
  "The release platform (OS . ARCH) of this machine, or nil.
OS is \"linux\", \"macos\" or \"windows\", ARCH is \"x86_64\"
or \"arm64\" — the CI release asset vocabulary
(`elneo-server-OS-ARCH').  nil means no built binary matches this
combination; the user keeps building or installing their own way,
exactly as before the offer existed."
  (let ((os (pcase system-type
              ('darwin "macos")
              ('gnu/linux "linux")
              ((or 'windows-nt 'ms-dos 'cygwin) "windows")
              (_ nil)))
        (arch (elneo-release--arch)))
    (and os arch (cons os arch))))

(defun elneo-release--asset-name ()
  "The release asset filename for this machine, or nil.
Windows assets keep their `.exe' suffix."
  (when-let* ((platform (elneo-release--platform)))
    (format "elneo-server-%s-%s%s"
            (car platform) (cdr platform)
            (if (equal (car platform) "windows") ".exe" ""))))

(defun elneo-release--url (name)
  "The URL downloading NAME from `elneo-release-repo''s latest release.
The redirect-based stable link avoids the JSON API — no rate
limit, nothing to parse."
  (concat "https://github.com/" elneo-release-repo
          "/releases/latest/download/" name))

(defun elneo-release--bin-dir (base)
  "The directory under BASE that release downloads install into."
  (expand-file-name "bin" base))

(defun elneo-release--installed-path ()
  "An already-downloaded release binary for this machine, or nil."
  (when-let* ((asset (elneo-release--asset-name)))
    (let ((path (expand-file-name
                 asset (elneo-release--bin-dir (elneo--data-dir-base)))))
      (when (file-exists-p path) path))))

(defun elneo-release--file-hash (file)
  "SHA256 hex digest of FILE's raw bytes."
  (with-temp-buffer
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun elneo-release--recorded-hash (sums asset)
  "The hash a SHA256SUMS file SUMS records for ASSET, or nil.
Filename matching ignores any path the checksums were generated
on — only the last segment must agree."
  (with-temp-buffer
    (insert-file-contents-literally sums)
    (goto-char (point-min))
    (catch 'found
      (while (re-search-forward "^\\([0-9a-fA-F]\\{64\\}\\)[ \t]+\\(.+\\)$"
                                nil t)
        (when (equal (car (last (split-string (match-string 2) "/"))) asset)
          (throw 'found (downcase (match-string 1))))))))

(defun elneo-release-download (base)
  "Download and install this machine's release under BASE.
Fetches the matching asset and the release's SHA256SUMS
synchronously, verifies the checksum, then installs the binary
mode 0755 under BASE's `bin'.  Returns the installed path, nil on
any failure (the reason is messaged).  The caller asks the user
before getting here; this function itself never prompts, and a
nil asset name (no matching platform) signals an error."
  (let ((asset (elneo-release--asset-name)))
    (when asset
      (let* ((bin (elneo-release--bin-dir base))
             (dest (expand-file-name asset bin))
             (tmpsums (make-temp-file "elneo-sums-"))
             tmpbin)
        (make-directory bin t)
        (setq tmpbin (make-temp-file (expand-file-name "elneo-asset-" bin)))
        (unwind-protect
            (condition-case err
                (progn
                  (url-copy-file (elneo-release--url asset) tmpbin t)
                  (url-copy-file (elneo-release--url "SHA256SUMS") tmpsums t)
                  (let ((recorded (elneo-release--recorded-hash tmpsums asset)))
                    (unless (and recorded
                                 (string-equal-ignore-case
                                  recorded (elneo-release--file-hash tmpbin)))
                      (error "SHA256 mismatch (expected %s)"
                             (or recorded "no entry in SHA256SUMS")))
                    ;; A running daemon keeps its inode alive past a
                    ;; replacement — rename, never in-place rewrite.
                    (ignore-errors (delete-file dest))
                    (rename-file tmpbin dest)
                    (set-file-modes dest #o755)
                    (message "Matrix: installed %s from %s (SHA256 verified)"
                             dest elneo-release-repo)
                    dest))
              (error
               (message "Matrix: release download failed: %s"
                        (error-message-string err))
               nil))
          (ignore-errors (delete-file tmpbin))
          (ignore-errors (delete-file tmpsums)))))))

(defun elneo-server--offer-release-download (profile &optional force)
  "Once per PROFILE, offer downloading this machine's release binary.
Asks with `y-or-n-p'; on yes the download runs synchronously and
the binary's installed path comes back.  A decline, a failed
download and a platform this machine has no binary for return nil
after marking the once-per-streak guard — the auto-restart tick
starts daemons too, and every backoff cycle must not re-ask
through the echo area.  The guard is cleared by the next
successful `elneo-server-start'.  Non-nil FORCE re-asks a marked
PROFILE: the onboarding preflight is a user-initiated run, where
silence would lock a decliner out of ever being asked again."
  (let ((platform (elneo-release--platform)))
    (when (and platform (or force
                            (not (assoc profile elneo-server--download-offered))))
      (let ((downloaded (and (y-or-n-p
                              (format
                               "Matrix [%s]: no elneo-server binary found — download the latest release from %s (%s-%s)? "
                               profile elneo-release-repo (car platform)
                               (cdr platform)))
                             (elneo-release-download (elneo--data-dir-base)))))
        (unless downloaded
          (setf (alist-get profile elneo-server--download-offered
                           nil nil #'equal)
                t))
        downloaded))))

(defun elneo-server--preflight-binary (profile)
  "Non-nil when PROFILE's next daemon start can find a binary.
The onboarding preflight: `elneo-add-account' calls this before it
collects credentials, because `elneo-server-start' would only
offer the release download after the account prompts, and a start
failing on a missing binary would strand the just-answered
password prompt.  Otherwise unchanged: the same offer
`elneo-server--command-to-run' asks, the same install.  Nil means
onboarding should stop with a clear user-error — set
`elneo-server-command', put a binary on PATH, or re-run and
accept the download."
  (or (file-name-absolute-p elneo-server-command)
      (executable-find elneo-server-command)
      (elneo-release--installed-path)
      ;; A user-initiated run re-asks even after an earlier decline.
      (elneo-server--offer-release-download profile t)))

(defun elneo-server--command-to-run (profile)
  "The command string `elneo-server-start' spawns PROFILE with.
`elneo-server-command' with an absolute path wins untouched.  A
bare name resolves on `exec-path'; failing that a previously
downloaded release binary silently takes over, and with neither,
this offers a download once per PROFILE until a start succeeds.  A
declined or failed offer returns `elneo-server-command' itself,
leaving the caller the same file-error signal it always gave."
  (or (and (file-name-absolute-p elneo-server-command) elneo-server-command)
      (executable-find elneo-server-command)
      (elneo-release--installed-path)
      (and (elneo-server--offer-release-download profile)
           (elneo-release--installed-path))
      elneo-server-command))

;;; Server lifecycle

(defun elneo-server--logfile-for (profile)
  "Log file path for PROFILE's daemon.
Tracing output goes to a file rather than stderr, because Emacs
merges the child's stderr into the process buffer, which would
corrupt the framed event stream."
  (or (and elneo-server-logfile (expand-file-name elneo-server-logfile))
      (expand-file-name (format "elneo-server-%s.log" profile)
                        user-emacs-directory)))

(defun elneo-server-start (profile)
  "Start elneo-server daemon for PROFILE."
  (interactive (list (read-string "Profile name: " elneo-default-profile)))
  (when (elneo-server-live-p profile)
    (user-error "Matrix server already running for profile: %s" profile))

  (elneo-server--ensure-callbacks profile)

  (let* ((buffer-name (format " *elneo-server-%s*" profile))
         (buffer (generate-new-buffer buffer-name))
         (process-connection-type nil)
         (process-adaptive-read-buffering nil)
         (logfile (elneo-server--logfile-for profile))
         ;; Resolving may ask (missing binary -> release download
         ;; offer); the message below names whatever this settled on.
         (command (elneo-server--command-to-run profile))
         (args (list "-p" profile
                     "-v" (number-to-string elneo-server-verbosity)
                     "-l" logfile)))

    (with-current-buffer buffer
      (setq buffer-read-only nil))

    (message "Matrix [%s] starting server: %s %s"
             profile command (mapconcat #'identity args " "))

    (let ((proc (apply #'start-process
                       (format "elneo-server-%s" profile)
                       buffer
                       command
                       args)))
      ;; A start — automatic or manual — takes over from any pending
      ;; or armed auto-restart: the deliberate-stop suppression ends
      ;; here, and the restarter's attempts counter is reset (a
      ;; successful start is the definition of "back to normal"; a
      ;; still-born one records "offline" via the sentinel again).
      (setq elneo-server--manual-stops
            (assoc-delete-all profile elneo-server--manual-stops))
      (set-process-query-on-exit-flag proc nil)
      (set-process-sentinel proc
                            (lambda (proc event)
                              (elneo-server--sentinel profile proc event)))
      (set-process-filter proc
                          (lambda (proc output)
                            (elneo-server--filter profile proc output)))
      ;; The process buffer must stay unibyte: the framed protocol counts
      ;; UTF-8 bytes, and a decoded (multibyte) buffer would make buffer
      ;; positions disagree with the `event <size>' byte counts — any JSON
      ;; containing non-ASCII characters then never parses (or corrupts the
      ;; following frames).  JSON strings are decoded in `parse-event'.
      (set-process-coding-system proc 'binary 'binary)

      (push (cons profile buffer) elneo-server--buffers)
      ;; A start that came up re-arms the missing-binary download
      ;; offer for the next streak without one.
      (setq elneo-server--download-offered
            (assoc-delete-all profile elneo-server--download-offered))
      (message "Matrix [%s] server started" profile)
      proc)))

(defun elneo-server-stop (profile)
  "Stop elneo-server daemon for PROFILE."
  ;; completing-read with REQUIRE-MATCH and an empty collection leaves
  ;; the user stuck in the prompt; the spec must refuse before it.
  (interactive
   (progn (unless elneo-server--buffers
            (user-error "No Matrix daemons running"))
          (list (completing-read "Profile: "
                                 (mapcar #'car elneo-server--buffers)
                                 nil t))))
  (when-let* ((proc (elneo-server--get-process profile)))
    ;; Capture the buffer before delete-process: it runs the sentinel
    ;; synchronously, the sentinel prunes `elneo-server--buffers'
    ;; first, and a lookup afterwards would find nothing to kill —
    ;; the process buffer would leak on every stop.
    (let ((buffer (elneo-server--get-buffer profile)))
      ;; Set the deliberate-stop flag BEFORE the sentinel runs: the
      ;; sentinel records "offline" and fires `elneo-session-sync-hook',
      ;; whose auto-restart consumer looks at this flag and must see
      ;; the stop as deliberate.
      (push (cons profile t) elneo-server--manual-stops)
      (delete-process proc)
      (when buffer
        (kill-buffer buffer))
      (message "Matrix [%s] server stopped" profile))))

;;; Session event handlers

(defun elneo-server--on-update-session (profile event)
  "Handle updateSession event for PROFILE."
  (let ((session-info (list :user-id (alist-get 'user_id event)
                            :device-id (alist-get 'device_id event)
                            :access-token (alist-get 'access_token event))))
    (setf (alist-get profile elneo-server--sessions
                     nil nil #'equal)
          session-info)
    (elneo--debug-log "Matrix [%s] logged in as %s (device: %s)"
                      profile
                      (plist-get session-info :user-id)
                      (plist-get session-info :device-id))))

(defun elneo-server--on-update-cross-signing-status (profile event)
  "Handle updateCrossSigningStatus event for PROFILE.
Record the state and announce it: the room bar adds a verify row
from this, and anything else interested hangs on
`elneo-session-trust-hook'."
  (let ((enabled (eq (alist-get 'enabled event) t))
        (trusted (eq (alist-get 'trusted event) t)))
    (elneo--debug-log "Matrix [%s] cross-signing: %s%s"
                      profile
                      (if enabled "enabled" "disabled")
                      (if trusted " (trusted)" ""))
    (setf (alist-get profile elneo-server--trust nil nil #'equal)
          (cons enabled trusted))
    (run-hook-with-args 'elneo-session-trust-hook profile enabled trusted)))

(defun elneo-server--record-sync-state (profile state error-msg)
  "Record PROFILE's STATE (with ERROR-MESSAGE) and announce a change.
The hook fires only when the (STATE . ERROR-MESSAGE) pair actually
changes: the daemon repeats updateSyncState on every reconnect cycle
and at login, and the consumers want transitions, not confirmation
floods.  Noisy states are echoed here once per transition — the echo
is the fallback for a session with neither the bar nor the mode line."
  (let ((entry (cons state error-msg))
        (current (alist-get profile elneo-server--sync-states
                            nil nil #'equal)))
    (unless (equal current entry)
      (setf (alist-get profile elneo-server--sync-states
                       nil nil #'equal)
            entry)
      (when (equal state "error")
        (message "Matrix [%s] sync error: %s" profile (or error-msg "unknown")))
      (elneo--debug-log "Matrix [%s] sync state: %s" profile entry)
      (run-hook-with-args 'elneo-session-sync-hook profile state error-msg))))

(defun elneo-server--on-update-sync-state (profile event)
  "Handle the updateSyncState event for PROFILE.
The transport layer owns this handler: the event streams from the
moment a daemon's sync task starts, client session or not."
  (let ((state (alist-get 'state event nil nil #'equal))
        (error-msg (alist-get 'error event)))
    (when (stringp state)
      (elneo-server--record-sync-state profile state error-msg))))

(defun elneo-server-sync-state (profile)
  "The recorded sync state cons (STATE . ERROR) for PROFILE, or nil."
  (when (boundp 'elneo-server--sync-states)
    (alist-get profile elneo-server--sync-states nil nil #'equal)))

(defun elneo-server--on-daemon-info (profile event)
  "Handle the daemonInfo greeting event for PROFILE.
Stored last-wins, so a daemon restart's second greeting replaces
the first."
  (let ((info (list :protocol (alist-get 'protocol event)
                    :release (alist-get 'release event))))
    (setf (alist-get profile elneo-server--daemon-info nil nil #'equal) info)
    ;; A greeting means a live (possibly re-started) daemon again: put
    ;; the state row into a non-degraded state, whatever it said before.
    (elneo-server--record-sync-state profile "starting" nil)
    (elneo--debug-log "Matrix [%s] daemon is release %s, protocol %s"
                      profile (plist-get info :release)
                      (plist-get info :protocol))))

(defun elneo-server--daemon-info-for (profile)
  "The greeting plist recorded for PROFILE, or nil."
  (cdr (assoc profile elneo-server--daemon-info)))

(defun elneo-server--user-id (profile)
  "The Matrix user id this Emacs side logged in as on PROFILE.
The session record only exists once the daemon has logged in; nil
before that (e.g. mention checks run against an inert session)."
  (plist-get (alist-get profile elneo-server--sessions
                        nil nil #'equal)
             :user-id))

(defun elneo-server--daemon-protocol (profile)
  "The protocol version the daemon for PROFILE reports, or nil.
Nil means the daemon predates version reporting.  Never compare
this unguarded against a number — a nil version must read as too
old/unknown, not as any particular protocol:

  (when (and (elneo-server--daemon-protocol profile)
             (>= (elneo-server--daemon-protocol profile) 2)) ...)"
  (plist-get (elneo-server--daemon-info-for profile) :protocol))

(defun elneo-server--protocol-verdict (mine minimum daemon)
  "Classify DAEMON (version or nil) for a client speaking MINE.
MINIMUM is the oldest protocol still welcome.  Returns `:ok',
`:too-old', `:too-new', or `:unknown' — a daemon with no greeting
(nil) is `:unknown'."
  (cond
   ((not (numberp daemon)) :unknown)
   ((< daemon minimum) :too-old)
   ((> daemon mine) :too-new)
   (t :ok)))

;;; Interactive utilities

;;;###autoload
(defun elneo-setup-cross-signing (profile)
  "Bootstrap cross-signing for PROFILE from this session.
For an account whose FIRST device this is (no other session could
have set it up): creates the self-signing keys this session then
trusts on its own.  With any other verified device, use
`elneo-verify-device' instead — that device signs this one and
everything cascades from there."
  (interactive
   (progn (unless elneo-server--sessions
            (user-error "No logged-in Matrix sessions"))
          (list (completing-read "Profile: "
                                 (mapcar #'car elneo-server--sessions)
                                 nil t))))
  (elneo-server--call profile
                      '((@type . "setupCrossSigning"))
                      (lambda (profile event)
                        (if (alist-get '@ok event nil nil #'equal)
                            (message "Matrix [%s] cross-signing set up" profile)
                          (message "Matrix [%s] %s" profile
                                   (elneo-server--error-string event))))))

(provide 'elneo-server)
;;; elneo-server.el ends here
