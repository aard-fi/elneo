;;; elneo-verify.el --- Interactive device verification UI -*- lexical-binding: t -*-

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;;; Commentary:

;; Interactive verification of devices (SAS/emoji short auth string) and
;; key recovery, driven by the daemon's verification module.
;;
;; Two directions:
;; - We start: `elneo-verify-device' lists the account's devices, one is
;;   chosen, a verification request goes out; the other client accepts.
;; - They start: another client (e.g. Element) sends a verification
;;   request; it pops up here and `elneo-verify-accept-incoming' accepts.
;;
;; Once both sides are ready, the SAS flow exchanges keys and the daemon
;; sends the 7-emoji short auth string.  The verification buffer shows it
;; and asks whether the emojis match: `y' confirms, `n' cancels (mismatch).
;;
;; Key recovery (`elneo-enable-recovery') turns on secret storage +
;; server-side key backup and shows the base58 recovery key exactly once;
;; `elneo-recover-keys' restores it on a new session.  Without recovery,
;; encrypted history does not decrypt again after daemon restarts.

;;; Code:

(require 'cl-lib)
(require 'elneo-client)

(defgroup elneo-verify nil
  "Matrix interactive verification."
  :group 'elneo
  :prefix "elneo-verify-")

(defface elneo-verify-emoji
  '((t :height 1.8))
  "Face for the SAS short auth string emojis."
  :group 'elneo-verify)

(defface elneo-verify-status
  '((t :inherit header-line :weight bold))
  "Face for the verification buffer's status lines."
  :group 'elneo-verify)

(defvar elneo-verify--buffers (make-hash-table :test 'equal)
  "Hash mapping profile names to verification buffers.")

(defvar-local elneo-verify--emoji-flow nil
  "Buffer-local: flow id whose emojis are currently shown.")

(defvar-local elneo-verify--profile nil
  "Buffer-local: the profile this verification buffer belongs to.")

(defvar elneo-verify-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "y") #'elneo-verify-confirm)
    (define-key map (kbd "n") #'elneo-verify-cancel)
    (define-key map (kbd "q") #'bury-buffer)
    map))

(define-derived-mode elneo-verify-mode special-mode "Matrix Verify"
  "Major mode for the interactive verification buffer.
\\[elneo-verify-confirm] confirms the short auth string, \\
\\[elneo-verify-cancel] cancels it (mismatch)."
  (setq-local truncate-lines t)
  (setq buffer-read-only t))

;;; Buffer management

(defun elneo-verify--buffer (profile)
  "The verification buffer for PROFILE, creating it if needed."
  (or (let ((buffer (gethash profile elneo-verify--buffers)))
        (and (buffer-live-p buffer) buffer))
      (let ((buffer (generate-new-buffer (format "*Matrix Verify: %s*" profile))))
        (puthash profile buffer elneo-verify--buffers)
        (with-current-buffer buffer
          (elneo-verify-mode)
          (setq-local elneo-verify--profile profile))
        buffer)))

(defun elneo-verify--show (profile)
  "Display and select PROFILE's verification buffer, point at end."
  (let ((buffer (elneo-verify--buffer profile)))
    (pop-to-buffer buffer '(display-buffer-reuse-window
                            (display-buffer-pop-up-window)
                            (display-buffer-at-bottom)))
    (with-current-buffer buffer
      (goto-char (point-max)))))

(defun elneo-verify--log (profile text &optional face)
  "Append TEXT to PROFILE's verification buffer."
  (let ((buffer (elneo-verify--buffer profile)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (moving (= (point) (point-max))))
        (save-excursion
          (goto-char (point-max))
          (insert (if face (propertize text 'face face) text) "\n"))
        (when moving (goto-char (point-max)))))))

;;; Device picker

;;;###autoload
(defun elneo-verify-device (profile)
  "Verify this Emacs session against another device of PROFILE.
The other (already-trusted) client accepts the request and both
sides confirm the same emojis; that one flow attests the whole
session — other devices signed by the same self-signing key are
trusted automatically."
  ;; The interactive spec — not the body — must load the account list:
  ;; completing-read with REQUIRE-MATCH and an empty collection leaves
  ;; the user stuck in the prompt after an Emacs restart.
  (interactive
   (progn (elneo--accounts-load)
          (unless elneo-accounts
            (user-error "No Matrix profiles registered"))
          (list (completing-read
                 "Profile: "
                 (mapcar #'car elneo-accounts)
                 nil t))))
  (elneo-get-devices
   profile
   (lambda (profile event)
     (if (alist-get '@ok event nil nil #'equal)
         (let ((devices (alist-get 'devices event)))
           (if (not devices)
               (message "Matrix [%s] no devices found" profile)
             (let* ((choices
                     (mapcar
                      (lambda (device)
                        (let ((id (alist-get 'device_id device))
                              (name (alist-get 'display_name device))
                              (current (eq (alist-get 'is_current device) t))
                              (verified (eq (alist-get 'verified device) t)))
                          ;; The current device's own trust state is
                          ;; meaningless (the SDK always trusts itself) —
                          ;; show it without a trust tag.  The device id
                          ;; is never truncated: it is the unique key the
                          ;; choice is looked up by below, so truncating
                          ;; it could make two devices collide into one
                          ;; candidate.
                          (cons (if current
                                    (format "%-16.16s %s (this device)"
                                            (or name "?") id)
                                  (format "%-16.16s %s %s"
                                          (or name "?") id
                                          (if verified "[verified]"
                                            "[unverified]")))
                                (list id current verified))))
                      devices))
                    (choice (completing-read
                             "Device to verify this session with: "
                             choices nil t))
                    (info (cdr (assoc choice choices)))
                    (device-id (nth 0 info))
                    (current (nth 1 info)))
               (cond
                (current (message "That is this device itself"))
                ((nth 2 info) (message "Device is already verified"))
                (t (elneo-verify--log
                    profile
                    (format "Requesting verification with %s (%s)... \
accept the request on that device."
                            choice device-id)
                    'elneo-verify-status)
                   (elneo-verify--show profile)
                   (elneo-verification-request-device
                    profile
                    (plist-get (alist-get profile elneo-accounts nil nil #'equal)
                               :user-id)
                    device-id))))))
       (message "Matrix [%s] getDevices failed: %s"
                profile (elneo-server--error-string event))))))

;;; Incoming requests

;;;###autoload
(defun elneo-verify-accept-incoming (profile)
  "Accept a pending incoming verification request for PROFILE."
  ;; Load in the spec, not the body — see `elneo-verify-device'.
  (interactive
   (progn (elneo--accounts-load)
          (unless elneo-accounts
            (user-error "No Matrix profiles registered"))
          (list (completing-read
                 "Profile: "
                 (mapcar #'car elneo-accounts)
                 nil t))))
  (let ((pending (cl-remove-if-not
                  (lambda (record)
                    (and (equal (plist-get record :profile) profile)
                         (not (plist-get record :we-started))))
                  (let (records)
                    (maphash (lambda (_flow record) (push record records))
                             elneo-verifications)
                    records))))
    (pcase (length pending)
      (0 (message "No pending verification requests for %s" profile))
      (1 (elneo-verify--accept-one profile (car pending)))
      (_ (let* ((names
                 ;; The label must be unique: it is the assoc key for
                 ;; the flow id below.  Two pending requests can share
                 ;; user and device (e.g. both with device "?"), so
                 ;; later duplicates get a counter.
                 (let ((counts (make-hash-table :test 'equal)))
                   (mapcar
                    (lambda (record)
                      (let* ((base (format "%s (%s)"
                                           (plist-get record :user-id)
                                           (or (plist-get record :device-id)
                                               "?")))
                             (n (puthash base
                                         (1+ (gethash base counts 0))
                                         counts))
                             (label (if (= n 1) base (format "%s [%d]" base n))))
                        (cons label (plist-get record :flow-id))))
                    pending)))
                (choice (completing-read "Request: " names nil t)))
           (elneo-verify--accept-one profile
                                     (cdr (assoc choice names))))))))

(defun elneo-verify--accept-one (profile record)
  "Accept the incoming verification RECORD for PROFILE and open its buffer."
  (elneo-verify--log profile
                     (format "Verification request from %s (%s) — accepted"
                             (plist-get record :user-id)
                             (or (plist-get record :device-id) "?"))
                     'elneo-verify-status)
  (elneo-verify--show profile)
  (elneo-verification-accept profile (plist-get record :flow-id)))

;;; Event hooks

(defun elneo-verify--on-update (record)
  "Verification state hook: log the change in the buffer."
  (let ((profile (plist-get record :profile))
        (state (plist-get record :state))
        (user (plist-get record :user-id)))
    (pcase state
      ("requested"
       ;; A request we initiated ourselves echoes back through the
       ;; same hook; treat only requests from the other side as
       ;; incoming, or the user gets "verification request from
       ;; <themself> — accept incoming".
       (if (plist-get record :we-started)
           (elneo-verify--log
            profile (format "Verification request accepted by %s" user))
         (message "Matrix [%s] verification request from %s — M-x elneo-verify-accept-incoming"
                  profile user)
         (elneo-verify--log
          profile
          (format "Verification request from %s (%s)" user
                  (or (plist-get record :device-id) "?"))
          'elneo-verify-status)))
      ("ready"
       (elneo-verify--log profile
                          (format "Ready. Starting emoji verification...")
                          'elneo-verify-status)
       (elneo-verification-start-sas profile (plist-get record :flow-id)))
      ("sas_started"
       (elneo-verify--log profile "SAS flow started; waiting for keys..."))
      ("sas_confirmed"
       (elneo-verify--log profile "Confirmed; waiting for the other side..."))
      ("done"
       (elneo-verify--log
        profile "Verified — this session is now trusted." 'elneo-verify-status)
       (message "Matrix [%s] session verified" profile)
       ;; Trust marks in open room buffers: a completed verification
       ;; flips the session's cross-signing state; marked buffers
       ;; re-render so new arrivals pick the state up (per-message
       ;; marks are snapshots — history is not re-evaluated).
       ;; elneo-room does not load elneo-verify, hence the guard.
       (when (fboundp 'elneo-room--rebuild-trust-buffers)
         (elneo-room--rebuild-trust-buffers)))
      ("cancelled"
       (elneo-verify--log
        profile
        (format "Verification cancelled: %s" (or (plist-get record :reason) "unknown"))
        'elneo-verify-status)
       (message "Matrix [%s] verification cancelled" profile)))))

(defun elneo-verify--on-emojis (data)
  "Emoji hook: show the short auth string in PROFILE's buffer."
  (let ((profile (plist-get data :profile))
        (emojis (plist-get data :emojis))
        (decimals (plist-get data :decimals)))
    (elneo-verify--log profile "Do these emojis match on BOTH devices?")
    (let ((buffer (elneo-verify--buffer profile)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              (moving (= (point) (point-max))))
          (save-excursion
            (goto-char (point-max))
            (dolist (emoji emojis)
              (insert (propertize (concat "  " (car emoji) "  ")
                                  'face 'elneo-verify-emoji)
                      (format "  %s\n" (cdr emoji))))
            (insert (format "\n  Or compare the numbers: %s %s %s\n"
                            (nth 0 decimals) (nth 1 decimals) (nth 2 decimals)))
            (insert (propertize "  Press y if they match, n if not.\n"
                                'face 'elneo-verify-status)))
          (setq-local elneo-verify--emoji-flow (plist-get data :flow-id))
          (when moving (goto-char (point-max))))))
    (elneo-verify--show profile)))

(defun elneo-verify--on-recovery-state (data)
  "Log a key-backup state change in a live verify buffer.
After a verification completes, the daemon re-checks the recovery
state once the other client's secret gossip has had time to land;
when key backup is available as a result, report it positively in
the buffer the user is still looking at.  Silent otherwise — no
nagging to enable recovery (for accounts with another verified
device it is unnecessary: secrets and room keys arrive by gossip
and forwarding)."
  (let* ((profile (plist-get data :profile))
         (buffer (gethash profile elneo-verify--buffers)))
    (when (and (buffer-live-p buffer)
               (equal (plist-get data :state) "enabled"))
      (elneo-verify--log
       profile
       "Key backup active — encrypted history will survive restarts."
       'elneo-verify-status))))

(add-hook 'elneo-recovery-state-hook #'elneo-verify--on-recovery-state)

(defun elneo-verify-confirm ()
  "Confirm the short auth string shown in the current buffer."
  (interactive)
  (if elneo-verify--emoji-flow
      (let ((flow elneo-verify--emoji-flow)
            (profile elneo-verify--profile))
        (setq-local elneo-verify--emoji-flow nil)
        (elneo-verify--log profile "Match confirmed.  Waiting for the other side...")
        (elneo-verification-confirm profile flow))
    (user-error "No short auth string to confirm here")))

(defun elneo-verify-cancel ()
  "Cancel the SAS verification shown in the current buffer (mismatch)."
  (interactive)
  (if elneo-verify--emoji-flow
      (let ((flow elneo-verify--emoji-flow)
            (profile elneo-verify--profile))
        (setq-local elneo-verify--emoji-flow nil)
        (elneo-verify--log profile "Cancelled (mismatch).")
        (elneo-verification-cancel profile flow))
    (user-error "No verification in progress here")))

;;; Recovery / key backup

;;;###autoload
(defun elneo-enable-recovery (profile)
  "Enable key backup for PROFILE and show its recovery key once.
The daemon stores its copy of the key in the session's data dir
(0600), where later re-logins adopt it silently — write it down
somewhere safe (password manager, paper) anyway: it is the only
way to restore your encrypted history from a lost machine's
session."
  ;; Load in the spec, not the body — see `elneo-verify-device'.
  (interactive
   (progn (elneo--accounts-load)
          (unless elneo-accounts
            (user-error "No Matrix profiles registered"))
          (list (completing-read
                 "Profile: "
                 (mapcar #'car elneo-accounts)
                 nil t))))
  (message "Matrix [%s] enabling recovery..." profile)
  (elneo-verification-enable-recovery
   profile
   (lambda (profile event)
     (let ((error-string (and (not (alist-get '@ok event nil nil #'equal))
                              (elneo-server--error-string event))))
       (cond
        ((alist-get '@ok event nil nil #'equal)
         (elneo-verify--show-recovery-key
          profile (alist-get 'recovery_key event nil nil #'equal)
          (alist-get 'stored_path event nil nil #'equal)))
        ((and error-string (string-search "Secret storage already exists" error-string))
         (message "Matrix [%s] %s — enter the existing recovery key" profile error-string)
         (elneo-recover-keys profile))
        (t (message "Matrix [%s] recovery failed: %s"
                    profile error-string)))))))

(defun elneo-verify--show-recovery-key (profile key stored-path)
  "Display PROFILE's recovery KEY in a dedicated buffer, once.
STORED-PATH, when non-nil, names the daemon's own copy in the
session's data dir — the copy later re-logins adopt silently,
which is why even a shown-once key still deserves a safe place
off this machine."
  (let ((buffer (get-buffer-create (format "*Matrix recovery key: %s*" profile))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Your Matrix recovery key — store this somewhere safe NOW.\n"
                            'face 'elneo-verify-status)
                (propertize "It is shown only this once.\n"
                            'face 'shadow)
                "It restores your encrypted history and secrets on new sessions.\n")
        (if stored-path
            (insert (propertize
                     (format "The daemon also keeps its copy in its data dir (0600):\n    %s\n"
                             stored-path)
                     'face 'shadow))
          (insert (propertize "It is not stored anywhere.\n" 'face 'shadow)))
        (insert (propertize "Copies on this machine share its fate — the safe copy is \
the one only you hold.\n\n"
                            'face 'shadow))
        (insert key "\n\n"
                (propertize "Press q to bury this buffer after saving the key.\n"
                            'face 'shadow))
        (goto-char (point-min))
        (special-mode))
      (pop-to-buffer buffer))))

;;; Session status view

(defvar-local elneo-session-status--profile nil
  "Buffer-local: the profile this status buffer reports on.")

(defvar elneo-session-status-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'elneo-session-status-refresh)
    map)
  "Keys of a session status buffer; `q' comes from `special-mode'.")

(define-derived-mode elneo-session-status-mode special-mode "Matrix Status"
  "Major mode for a profile's session status buffer.
\\[elneo-session-status-refresh] refreshes, \\[quit-window] buries."
  nil)

(defun elneo-session-status-refresh ()
  "Re-run the status queries for this status buffer's profile."
  (interactive)
  (if elneo-session-status--profile
      (elneo-session-status elneo-session-status--profile)
    (user-error "This buffer does not know its profile")))

;;;###autoload
(defun elneo-recover-keys (profile)
  "Restore PROFILE's secrets from a previously saved recovery key."
  ;; Load in the spec, not the body — see `elneo-verify-device'.
  (interactive
   (progn (elneo--accounts-load)
          (unless elneo-accounts
            (user-error "No Matrix profiles registered"))
          (list (completing-read
                 "Profile: "
                 (mapcar #'car elneo-accounts)
                 nil t))))
  ;; read-passwd, not read-string: the recovery key is a secret —
  ;; echoing it and landing it in minibuffer history is a leak.
  (let ((key (or (read-passwd "Recovery key: ") "")))
    (when (> (length key) 0)
      (message "Matrix [%s] recovering from recovery key..." profile)
      (elneo-verification-recover-keys
       profile key
       (lambda (profile event)
         (if (alist-get '@ok event nil nil #'equal)
             (message "Matrix [%s] recovery key accepted" profile)
           (message "Matrix [%s] recovery failed: %s"
                    profile (elneo-server--error-string event))))))))

(defun elneo-verify--confirm-word (prompt word)
  "Read PROMPT and answer non-nil when the confirmation WORD was typed.
Case- and surrounding-space-insensitive; anything else is a no.  The
destructive recovery verbs sit behind a typed word rather than a y/n
reflex: a deleted key backup is not re-verifiable, so a slip of the
y finger should not reach it."
  (string= (downcase (string-trim (read-string prompt)))
           (downcase word)))

;;;###autoload
(defun elneo-rotate-recovery-key (profile)
  "Rotate PROFILE's secret storage under a fresh recovery key.
The key backup and its history stay as they are; the recovery key
held until now stops working — copies stored by other sessions,
machines and clients go stale and need the new key.  The new key
is shown once and stashed (0600) in the daemon's data dir,
replacing the old.  Confirmed by typing ROTATE, not y/n."
  ;; Load in the spec, not the body — see `elneo-verify-device'.
  (interactive
   (progn (elneo--accounts-load)
          (unless elneo-accounts
            (user-error "No Matrix profiles registered"))
          (list (completing-read
                 "Profile: "
                 (mapcar #'car elneo-accounts)
                 nil t))))
  (if (elneo-verify--confirm-word
       (format "Matrix [%s] rotate the recovery key?  Your backed-up keys \
stay, but the key you hold stops working and other sessions' stored \
copies go stale.  Type ROTATE to confirm: " profile)
       "rotate")
      (progn
        ;; A session the store distrusts cannot fill a fresh secret
        ;; store on its own — the old key is what lets the daemon
        ;; import first and rotate after.
        (let* ((untrusted (let ((trust (cdr (assoc profile
                                                   elneo-server--trust))))
                            (and trust (eq (car trust) t) (null (cdr trust)))))
               (old-key (when untrusted
                          (or (read-passwd "Old recovery key: ") ""))))
          (if (and untrusted (<= (length old-key) 0))
              (user-error "Rotation from an untrusted session needs the old \
recovery key"))
          (message "Matrix [%s] rotating the recovery key..." profile)
          (elneo-verification-rotate-recovery-key
           profile
           (lambda (profile event)
             (if (alist-get '@ok event nil nil #'equal)
                 (elneo-verify--show-recovery-key
                  profile
                  (alist-get 'recovery_key event nil nil #'equal)
                  (alist-get 'stored_path event nil nil #'equal))
               (message "Matrix [%s] rotation failed: %s"
                        profile (elneo-server--error-string event))))
           old-key)))
    (message "Matrix [%s] rotation set aside, nothing touched" profile)))

;;;###autoload
(defun elneo-disable-recovery (profile)
  "Delete PROFILE's server-side key backup and clear secret storage.
This is the irreversible one: the backup's encrypted history is gone
for every device that cannot already decrypt it.  The daemon also
drops its copy of the now-stale recovery key, and nothing re-enables
the backup behind the user's back.  Confirmed by typing DISABLE,
not y/n."
  ;; Load in the spec, not the body — see `elneo-verify-device'.
  (interactive
   (progn (elneo--accounts-load)
          (unless elneo-accounts
            (user-error "No Matrix profiles registered"))
          (list (completing-read
                 "Profile: "
                 (mapcar #'car elneo-accounts)
                 nil t))))
  (if (elneo-verify--confirm-word
       (format "Matrix [%s] disable recovery?  The server-side key backup \
is deleted — encrypted history no other device holds is gone with \
it — and secret storage is cleared.  Type DISABLE to confirm: "
               profile)
       "disable")
      (progn
        (message "Matrix [%s] disabling recovery..." profile)
        (elneo-verification-disable-recovery
         profile
         (lambda (profile event)
           (if (alist-get '@ok event nil nil #'equal)
               (message "Matrix [%s] recovery disabled" profile)
             (message "Matrix [%s] disabling failed: %s"
                      profile (elneo-server--error-string event))))))
    (message "Matrix [%s] disabling set aside, nothing touched" profile)))

;;;###autoload
(defun elneo-session-status (profile)
  "Show PROFILE's session status in an interactive buffer.
Cross-signing trust, key backup state, the account's devices with
their verification state, and the pending verification requests —
the things that decide whether encrypted history decrypts and
survives restarts.  Buttons in the buffer verify or remove a
device and jump into a pending request; `g' refreshes, `q' buries."
  (interactive
   (progn (elneo--accounts-load)
          (unless elneo-accounts
            (user-error "No Matrix profiles registered"))
          (list (let ((names (mapcar #'car elneo-accounts)))
                  (if (= (length names) 1)
                      (car names)
                    (completing-read "Profile: " names nil t))))))
  (unless (elneo-server-live-p profile)
    (user-error "Matrix daemon not running for profile %s" profile))
  ;; Four async queries; render once all answered.  A failed query
  ;; leaves its slot nil and renders as "unknown".
  (let ((cross-signing 'pending)
        (recovery 'pending)
        (devices 'pending)
        (requests 'pending))
    (cl-labels
        ((check ()
           (when (and (not (eq cross-signing 'pending))
                      (not (eq recovery 'pending))
                      (not (eq devices 'pending))
                      (not (eq requests 'pending)))
             (elneo-session-status--render
              profile cross-signing recovery devices requests))))
      (elneo-server--call
       profile '((@type . "getCrossSigningStatus"))
       (lambda (_p event)
         (setq cross-signing
               (when (alist-get '@ok event nil nil #'equal)
                 (cons (alist-get 'enabled event)
                       (alist-get 'trusted event))))
         (check)))
      (elneo-server--call
       profile '((@type . "getRecoveryState"))
       (lambda (_p event)
         (setq recovery
               (when (alist-get '@ok event nil nil #'equal)
                 (alist-get 'state event)))
         (check)))
      (elneo-server--call
       profile '((@type . "getDevices"))
       (lambda (_p event)
         (setq devices
               (when (alist-get '@ok event nil nil #'equal)
                 (append (alist-get 'devices event) nil)))
         (check)))
      (elneo-server--call
       profile '((@type . "getVerificationRequests"))
       (lambda (_p event)
         (setq requests
               (when (alist-get '@ok event nil nil #'equal)
                 (append (alist-get 'requests event) nil)))
         (check))))))

(defun elneo-session-status--pending-requests (profile)
  "The non-terminal verification records for PROFILE.
Reads `elneo-verifications' (the live hook keeps it current).
Only flows tracked in this daemon run are counted: pending
requests do not survive a daemon restart — the to-device events
they rode in are consumed by the store, so after a restart the
flow has to be re-requested."
  (cl-sort
   (cl-remove-if-not
    (lambda (rec)
      (and (equal (plist-get rec :profile) profile)
           (not (member (plist-get rec :state)
                        '("done" "cancelled")))))
    (hash-table-values elneo-verifications))
   #'string<
   :key (lambda (rec) (or (plist-get rec :user-id) ""))))

(defun elneo-session-status--verify-device (profile user-id device-id)
  "Button action: start verifying USER-ID's DEVICE-ID for PROFILE."
  (elneo-verify--show profile)
  (elneo-verify--log profile
                     (format "Starting verification of %s" device-id)
                     'elneo-verify-status)
  (elneo-verification-request-device profile user-id device-id))

(defun elneo-session-status--remove-device (profile device-id)
  "Button action: log DEVICE-ID out of PROFILE.
The account password authorizes the homeserver's interactive
challenge; when the server demands one anyway, the daemon reports
it and the user retries with the password in hand."
  (let ((password (read-passwd
                   (format "Account password (removes %s): " device-id))))
    (elneo-delete-device
     profile device-id password
     (lambda (p event)
       (if (alist-get '@ok event nil nil #'equal)
           (progn
             (message "Matrix [%s] device %s removed" p device-id)
             ;; Re-open: the device is gone from the list.
             (elneo-session-status p))
         (message "Matrix [%s] removing %s failed: %s"
                  p device-id (elneo-server--error-string event)))))))

(defun elneo-session-status--render-identity (session account cs-state rec-state)
  "The identity facts block: who SESSION is, then the two states.
SESSION and ACCOUNT are the alists looked up for it, CS-STATE and
REC-STATE the human-readable cross-signing and key-backup states;
a fact the session does not carry is skipped."
  (when-let* ((user-id (plist-get session :user-id)))
    (insert (format "  User:         %s\n" user-id)))
  (when-let* ((device-id (plist-get session :device-id)))
    (insert (format "  Device:        %s\n" device-id)))
  (when-let* ((homeserver (plist-get account :homeserver)))
    (insert (format "  Homeserver:    %s\n" homeserver)))
  (insert (format "  Cross-signing: %s\n" cs-state))
  (insert (format "  Key backup:    %s" rec-state)))

(defun elneo-session-status--render-devices (profile user-id devices)
  "The device list block with its per-device verify/remove buttons.
USER-ID keys the verify flow (`elneo-session-status--verify-device'
needs the remote device's owner)."
  (let ((verified (seq-count (lambda (d) (alist-get 'verified d))
                             devices)))
    (insert (format "\n  Devices:  %d of %d verified\n"
                    verified (length devices))))
  (dolist (device devices)
    (let* ((current (alist-get 'is_current device))
           (verified (alist-get 'verified device))
           (id (alist-get 'device_id device))
           (name (or (alist-get 'display_name device) "?")))
      (insert (format "    %s %-14s %s%s"
                      (if verified "✓" "✗")
                      name id
                      (if current " (this device)" "")))
      ;; The current device verifies itself from the status
      ;; view only when the session is not yet trusted (then
      ;; it needs ANOTHER device — that flow starts in
      ;; `elneo-verify-device'); remote devices verify and
      ;; are removed right here.
      (when (not current)
        (unless verified
          (insert " ")
          (insert-text-button
           "[verify]"
           'action (lambda (_)
                     (elneo-session-status--verify-device
                      profile user-id id))))
        (insert " ")
        (insert-text-button
         "[remove]"
         'action (lambda (_) (elneo-session-status--remove-device
                              profile id))))
      (insert "\n"))))

(defun elneo-session-status--render-requests (profile requests)
  "The pending-verification block: one line per REQUESTS record
with a jump into the flow on PROFILE."
  (dolist (rec requests)
    (insert (format "    %s %s (%s)"
                    (or (plist-get rec :user-id) "?")
                    (or (plist-get rec :device-id) "?")
                    (or (plist-get rec :state) "?")))
    (insert " ")
    (insert-text-button
     "[jump]"
     'action (lambda (_) (elneo-verify--show profile)))
    (insert "\n")))

(defun elneo-session-status--render-hints (cs-state rec-state)
  "The hint block: M-x routes only for what the buttons above cannot do."
  (cond
   ((string= cs-state "not set up")
    (insert "  Bootstrap cross-signing for a first device: M-x \
elneo-setup-cross-signing\n  (with another verified device: verify \
there, not here)\n"))
   ((string= cs-state "enabled, session NOT trusted")
    (insert "  Restore this session's trust with your existing \
recovery key: M-x elneo-recover-keys\n  (entering the key never \
creates a new key backup — that is elneo-enable-recovery's job)\n")))
  (cond
   ((string= rec-state "set up, but this session lacks the key")
    (insert "  Unlock with your security key: M-x \
elneo-recover-keys\n"))
   ((string= rec-state "not enabled")
    (insert "  For a single-device account: M-x \
elneo-enable-recovery\n"))))

(defun elneo-session-status--render (profile cross-signing recovery
                                             devices _requests)
  "Render the collected status of PROFILE into its status buffer.
CROSS-SIGNING is (ENABLED . TRUSTED) or nil, RECOVERY a recovery
state string or nil, DEVICES a list of device alists or nil;
_REQUESTS arrive through `elneo-session-status--pending-requests'
directly (the daemon's response just confirms the call served)."
  (let* ((buffer (get-buffer-create (format "*Matrix Status: %s*" profile)))
         (session (alist-get profile elneo-server--sessions nil nil #'equal))
         (account (alist-get profile elneo-accounts nil nil #'equal))
         (user-id (plist-get session :user-id))
         (cs-state (cond
                    ((null cross-signing) "unknown")
                    ((and (car cross-signing) (cdr cross-signing))
                     "enabled, session trusted")
                    ((car cross-signing) "enabled, session NOT trusted")
                    (t "not set up")))
         (rec-state (pcase recovery
                      (`"enabled" "active")
                      (`"incomplete" "set up, but this session lacks the key")
                      (`"disabled" "not enabled")
                      (`"unknown" "unknown")
                      (_ "unknown")))
         (requests (elneo-session-status--pending-requests profile)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'elneo-session-status-mode)
        (elneo-session-status-mode))
      (setq-local elneo-session-status--profile profile)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Matrix session %s\n\n" profile))
        (elneo-session-status--render-identity session account
                                               cs-state rec-state)
        ;; Rotate and disable sit one typed word behind their buttons;
        ;; shown only while the profile's daemon is around to take the
        ;; command.
        (when (elneo-server-live-p profile)
          (insert "   ")
          (insert-text-button
           "[rotate]"
           'action (lambda (_) (elneo-rotate-recovery-key profile)))
          (insert " ")
          (insert-text-button
           "[disable]"
           'action (lambda (_) (elneo-disable-recovery profile))))
        (insert "\n")
        (insert (format "  Protocol:      %s%s\n"
                        (or (elneo-server--daemon-protocol profile) "unknown (pre-versioning daemon)")
                        (if-let* ((release (plist-get (elneo-server--daemon-info-for profile) :release)))
                            (format " (daemon release %s)" release) "")))
        (when (and (listp devices) devices)
          (elneo-session-status--render-devices profile user-id devices))
        (when requests
          (insert "\n  Pending verification requests:\n")
          (elneo-session-status--render-requests profile requests))
        (elneo-session-status--render-hints cs-state rec-state)
        ;; Pending requests can also arrive while this buffer sits
        ;; open — point out the refresh key.
        (goto-char (point-min)))
      (pop-to-buffer buffer))))

;;; Rescue offer: one-time ask when a session cannot trust itself

(defcustom elneo-recovery-rescue-offer t
  "Offer, once per Emacs session, to restore an untrusted session's keys.
Fires when a profile's daemon reports cross-signing enabled but this
session does not trust it — the state where encrypted history stays
\"[unable to decrypt]\" until the recovery key is entered or the device
is verified against another one.  The offer appears at most once per
profile per Emacs session and only suggests existing commands; it never
asks to create a new key backup."
  :type 'boolean
  :group 'elneo)

(defvar elneo-verify--rescue-asked nil
  "Alist of (PROFILE . t) once the rescue offer fired (or was declined).
Never cleared within one Emacs session: one ask per profile per session.")

(defun elneo-verify--rescue-should-offer-p (profile enabled trusted)
  "Non-nil when the rescue offer is due for PROFILE.
ENABLED/TRUSTED as the `elneo-session-trust-hook' arguments: the offer
is for the state \"the account has keys, this session does not trust
them\" — an account that never bootstrapped has nothing to recover
with, and an already-trusted session has nothing to recover.  Off
switch is `elneo-recovery-rescue-offer'; a profile already asked stays
asked for the whole Emacs session."
  (and elneo-recovery-rescue-offer
       (eq enabled t)
       (null trusted)
       (not (assoc profile elneo-verify--rescue-asked))))

(defun elneo-verify--rescue-act (profile choice)
  "Dispatch the rescue prompt's CHOICE for PROFILE.
`r' enters the recovery key (`elneo-recover-keys'), `v' opens the
session-status view; anything else just notes the offer was set
aside.  Kept separate from the prompt so tests can assert the
routing."
  (pcase choice
    (?r (elneo-recover-keys profile))
    (?v (elneo-session-status profile))
    (_ (message "Matrix [%s]: rescue offer set aside (no new backup \
was offered)" profile))))

(defun elneo-verify--rescue-prompt (profile)
  "Ask how to restore PROFILE's session trust, and do it.
Echo-area, read-char (r/v/i-style) like the invite prompt."
  (let ((choice (read-char
                 (format
                  "Matrix [%s]: this session's keys are untrusted.  \
[r] enter recovery key, [v] session status, [other] ignore"
                  profile))))
    (elneo-verify--rescue-act profile choice)))

(defun elneo-verify--rescue-fire (profile)
  "The rescue timer's re-check and prompt for PROFILE.
Re-checks at fire time: the daemon may have gone away or the trust
state resolved meanwhile.  Recovery already disabled makes any key
entry pointless — the hint then points at `elneo-enable-recovery'
instead.  Kept as its own function so tests can fire it directly."
  (when-let* ((trust (cdr (assoc profile elneo-server--trust))))
    (when (and (elneo-server-live-p profile)
               (eq (car trust) t)
               (null (cdr trust))
               (not (equal (gethash profile elneo-recovery-states)
                           "disabled")))
      (elneo-verify--rescue-prompt profile))))

(defun elneo-verify--on-trust-rescue (profile enabled trusted)
  "Hook consumer: schedule the one-time rescue offer.
Runs inside event dispatch, so the ask is deferred to a timer whose
fire-time re-check (`elneo-verify--rescue-fire') sees the state as
it is then, not as this event claimed.  Marking the profile asked
happens before the timer is scheduled — exactly one offer per
profile per Emacs session, even across repeated trust events."
  (when (elneo-verify--rescue-should-offer-p profile enabled trusted)
    (setf (alist-get profile elneo-verify--rescue-asked nil nil #'equal) t)
    (run-with-timer 10 nil #'elneo-verify--rescue-fire profile)))

;;; Hook wiring

(add-hook 'elneo-verification-update-hook #'elneo-verify--on-update)
(add-hook 'elneo-verification-emoji-hook #'elneo-verify--on-emojis)
(add-hook 'elneo-session-trust-hook #'elneo-verify--on-trust-rescue)

(provide 'elneo-verify)
;;; elneo-verify.el ends here
