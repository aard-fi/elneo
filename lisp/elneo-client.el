;;; elneo-client.el --- Multi-account Matrix core: registry and fan-in -*- lexical-binding: t -*-

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;;; Commentary:

;; Core of the Emacs Matrix client.  Keeps a registry of accounts and a
;; merged view of all rooms across all online accounts, fanning daemon
;; events into `elneo-room-update-hook' and `elneo-new-message-hook'
;; for the UI layers (room bar, room buffers).
;;
;; One elneo-server daemon process runs per profile; all of them stay
;; online simultaneously.  Account credentials are not stored here —
;; the daemon keeps its own session per profile, so restarting Emacs
;; reconnects without re-login.
;;
;; This is the middle layer of three: elneo-server.el transports
;; framed JSON and correlates requests; this file keeps the
;; account/room registry and fans every daemon event into
;; `elneo-room-update-hook' and `elneo-new-message-hook'; the UI
;; layers (room bar, room buffers) subscribe to those hooks and never
;; talk to daemons directly.

;;; Code:

(require 'json)
(require 'elneo-server)

;; Loaded at runtime in `elneo-start' to avoid a load cycle.
(declare-function elneo-room-bar-show "elneo-room-bar" ())
;; The bar buffer, checked by `elneo-add-account' to avoid raising a
;; hidden bar.  No value: elneo-room-bar's own defvar owns the real one.
(defvar elneo-room-bar--buffer)
;; Defined (as the room buffer registry) in elneo-room.el, which
;; `elneo-quit' requires before touching it.  No value here: a value
;; would pre-bind the variable and stop elneo-room's own defvar from
;; creating its hash table when that loads later.
(defvar elneo-room--buffers)

;;;###autoload
(defun elneo-reload ()
  "Reload the elneo-client package from its source directory.
Run this after updating the elisp files.  Keymaps are rebuilt so
rebinding takes effect in already-open room buffers; room buffers
pick up new rendering on their next re-render, and buffers from an
older version get their draft area rebuilt when re-opened.
Files load in dependency order — `elneo-transient' last, since
its menu definition checks that every suffix command it names is
defined, so reloading it before `elneo-room-bar' would reject the
new layout.  A file that fails to load is reported; the rest still
load.  (elneo-alert is left out: it needs the external `alert'
package and is loaded only when configured.)"
  (interactive)
  (let ((dir (file-name-directory (locate-library "elneo-client")))
        (failures nil))
    (dolist (file '("elneo-server" "elneo-client" "elneo-room"
                    "elneo-image" "elneo-dired" "elneo-room-bar"
                    "elneo-account" "elneo-verify" "elneo-transient"))
      (condition-case err
          (load (expand-file-name (concat file ".el") dir) nil t)
        (error
         (push file failures)
         (message "Matrix: reload of %s failed: %s" file err))))
    (when failures
      (message "Matrix: reload failed for %s"
               (mapconcat #'identity (nreverse failures) ", ")))))

(defcustom elneo-account-file
  (locate-user-emacs-file "elneo-accounts.el")
  "File where registered Matrix accounts are saved.
Contains profile names and homeservers only; no secrets.  Session
tokens live in each daemon's own data directory."
  :type 'file
  :group 'elneo)

;;; Account registry

(defvar elneo-accounts nil
  "Alist of (PROFILE . PLIST) for registered Matrix accounts.
PLIST keys: :homeserver, :user-id, :device-id (last two filled once
a session is active).")

(defvar elneo-accounts-loaded nil
  "Non-nil once `elneo-accounts' has been loaded from disk.")

;;; Room registry

;; Keyed by (PROFILE . ROOM-ID); `equal' compares conses element-wise.
(defvar elneo--rooms (make-hash-table :test 'equal)
  "Hash table mapping (PROFILE . ROOM-ID) to a room record plist.
Record keys: :profile :room-id :room-state (\"joined\"/\"invited\")
:name :display-name :topic :alias :encrypted :direct :space :unread
:highlights :last-activity :preview :last-event-id :notification-mode
:notification-mode-user-defined :bridge :upgraded-to :upgraded-from
:buffer.  The upgrade links are the room's successor/predecessor
room ids (`m.room.tombstone' / the create predecessor), both absent
for a room with no upgrade history.")

(defun elneo--room-key (profile room-id)
  "Registry key for PROFILE's room ROOM-ID."
  (cons profile room-id))

(defun elneo-room-get (profile room-id)
  "Return the room record for PROFILE's ROOM-ID, or nil."
  (gethash (cons profile room-id) elneo--rooms))

(defun elneo--room-refuse-replaced (room)
  "Signal `user-error' naming the successor when ROOM was replaced.
A tombstoned room is openable for history, but sends there bounce
off the server; refusing locally says where the message goes
instead.  ROOM nil (no record) passes — an unknown room is not
known to be replaced."
  (when-let* ((successor (plist-get room :upgraded-to)))
    (user-error "Matrix: %s was replaced — send in %s instead"
                (or (plist-get room :display-name)
                    (plist-get room :room-id))
                successor)))

(defcustom elneo-muted-notification-modes '("mute" "mentions_and_keywords")
  "Notification modes that count as muted everywhere in the UI.
Mentions-and-keywords is included: a room that never pings on
ordinary messages is quiet for practical purposes."
  :group 'elneo
  :type '(repeat string))

(defun elneo-room-muted-p (room)
  "Non-nil when ROOM's notification settings disable notifications.
Covers both literal mute and mentions-and-keywords-only: a room that
never pings on ordinary messages is quiet for practical purposes."
  (and room
       (member (plist-get room :notification-mode)
               elneo-muted-notification-modes)
       t))

(defun elneo-buffer-visible-p (buffer)
  "Non-nil when BUFFER is shown in a window on any visible frame.
The one shared notion of \"on screen\": dired's implicit send target
and alert's skip-when-visible both use it.  (The bar checks its own
buffer the same way, live windows only, so a bar parked in another
eyebrowse perspective is not visible.)"
  (and (buffer-live-p buffer)
       (get-buffer-window buffer 'visible)))

(defun elneo-rooms-all ()
  "Return all room records across all accounts, as a list."
  (let (rooms)
    (maphash (lambda (_key room) (push room rooms)) elneo--rooms)
    rooms))

(defun elneo--room-pick-label (room)
  "The room-pick candidate string for ROOM: \"PROFILE: NAME\",
with \" [replaced]\" appended for a tombstoned room."
  (concat
   (format "%s: %s"
           (plist-get room :profile)
           (or (plist-get room :display-name)
               (plist-get room :room-id)))
   (and (plist-get room :upgraded-to) " [replaced]")))

(defun elneo-completing-read-room (&optional profile)
  "Read a room with completing-read, return its room record plist.
Without PROFILE the pick covers every registered account's rooms;
with PROFILE (an account name) only that account's rooms are
offered — `elneo-room-forward-cross-account' restricts its pick
this way.  Rooms replaced by an upgrade are marked \" [replaced]\"
and offered last: they are openable for history, but sends there
die on the server.
Rooms still sharing a label (two live same-name rooms) each get
their id appended, so both stay visible and pickable.  Signals
`user-error' on no choice or no room at all."
  (let* ((rooms
          ;; Live rooms first: a tombstoned twin must not be the
          ;; candidate at hand.
          (let (live dead)
            (dolist (room (if profile
                              (let (mine)
                                (maphash (lambda (_key room)
                                           (when (equal (plist-get room :profile)
                                                        profile)
                                             (push room mine)))
                                         elneo--rooms)
                                (nreverse mine))
                            (elneo-rooms-all)))
              (if (plist-get room :upgraded-to)
                  (push room dead) (push room live)))
            (nconc (nreverse live) (nreverse dead))))
         (counts
          (let ((table (make-hash-table :test 'equal)))
            (dolist (room rooms table)
              (let ((label (elneo--room-pick-label room)))
                (puthash label (1+ (gethash label table 0)) table)))))
         (table
          ;; assoc on the chosen string returns the first match, so a
          ;; shared label must never stand for two rooms.
          (mapcar (lambda (room)
                    (let ((label (elneo--room-pick-label room)))
                      (cons (if (> (gethash label counts) 1)
                                (format "%s [%s]"
                                        label (plist-get room :room-id))
                              label)
                            room)))
                  rooms))
         (choice (completing-read "Matrix room: " (mapcar #'car table) nil t)))
    (or (cdr (assoc choice table #'equal))
        (user-error "No room selected"))))

;;; Hooks

(defcustom elneo-room-update-hook nil
  "Hook run when a room record is created, changed or removed.
Called with one argument: the room record plist.  A removed room
has a `:removed' property set to t; recipients should drop it."
  :type 'hook
  :group 'elneo)

(defcustom elneo-new-message-hook nil
  "Hook run for each live message from any account.
Called with one argument: a plist with :profile :room-id :event-id
:sender :sender-name :body :formatted-body (the org.matrix.custom.html
version, when the sender's client sent one) :ts :msgtype :is-own
:reply-to (event id of the replied-to message, when the sender
replied), :media (the media metadata alist, for media messages),
:sender-trust (\"verified\"/\"unverified\"/\"unsigned\"/\"violation\"/
\"mismatch\" — the sending device's trust state at decryption time,
encrypted rooms only) and :reactions (reaction plists already run
through `elneo-client--reaction-plists').  Poll messages also
carry :poll (`elneo-client--poll-plist' shape).  A thread reply
carries :thread-root: the root event id its `m.thread' relation
(MSC3440) names the reply hangs under."
  :type 'hook
  :group 'elneo)

(defcustom elneo-reactions-update-hook nil
  "Hook run when an event's aggregated reactions change.
Called with one argument: a plist with :profile :room-id :event-id
(the target of the reactions) and :reactions — a list of plists with
:key :count :own.  An empty :reactions list means no reactions remain."
  :type 'hook
  :group 'elneo)

(defcustom elneo-poll-update-hook nil
  "Hook run when a poll's aggregate changed (a vote, a poll end,
a redacted vote).
Called with one argument: a plist with :profile :room-id :event-id
(the poll start event) and :poll — the refreshed
`elneo-client--poll-plist', nil when the poll has no fold here
(nothing to render)."
  :type 'hook
  :group 'elneo)

(defcustom elneo-read-receipts-update-hook nil
  "Hook run when other members' public read receipts change.
Called with one argument: a plist with :profile :room-id :receipts —
a list of plists with :user-id :user-name :event-id (what that user
has read up to) and :ts (when).  Only members whose clients send
public m.read receipts appear; Element X's private-only receipts
never do."
  :type 'hook
  :group 'elneo)

(defcustom elneo-own-read-receipt-update-hook nil
  "Hook run when this account's own read state moved.
That is the room having been marked read — by this device
(`elneo-room-mark-read' runs it locally once the daemon accepts
the mark, with :event-id possibly nil) or on another device of the
profile (or an echo of this device's own mark) — signalled by the
own public or private read receipt, or by the `m.fully_read'
marker.  Called with one argument: a plist with :profile :room-id
:event-id and :ts (nil for the marker) — the event the room was
read up to.  Uses for retiring room-scoped notification state (an
alert inbox entry whose room was read elsewhere); UI read-markers
are not part of this, other members' receipts stay on
`elneo-read-receipts-update-hook'."
  :type 'hook
  :group 'elneo)

(defcustom elneo-edited-update-hook nil
  "Hook run when a message is edited (m.replace).
Called with one argument: a plist with :profile :room-id :event-id
(the *original* event, not the replacement) :body :msgtype :media and
:edited-ts (the edit event's own timestamp)."
  :type 'hook
  :group 'elneo)

(defcustom elneo-redaction-update-hook nil
  "Hook run when a message is redacted (deleted).
Called with one argument: a plist with :profile :room-id :event-id.
What happens to any locally held original is the user's
`elneo-room-redaction-history' setting, handled by the room UI."
  :type 'hook
  :group 'elneo)

(defcustom elneo-room-keys-updated-hook nil
  "Hook run when room keys arrived for a room (e.g. from key backup).
Called with two arguments: PROFILE and ROOM-ID."
  :type 'hook
  :group 'elneo)

(defcustom elneo-session-activated-hook nil
  "Hook run after a profile's daemon session came up (restore or login).
Called with one argument: PROFILE.  Handlers can use this to reset
state that is tied to the previous daemon instance."
  :type 'hook
  :group 'elneo)

(defcustom elneo-verification-update-hook nil
  "Hook run on verification state changes.
Called with one argument: a plist with :profile :flow-id :user-id
:device-id :we-started :state :reason (see `elneo-verifications')."
  :type 'hook
  :group 'elneo)

(defcustom elneo-verification-emoji-hook nil
  "Hook run when a SAS short auth string is ready.
Called with one argument: a plist with :profile :flow-id :emojis
(list of (SYMBOL . DESCRIPTION)) and :decimals (list of 3 numbers)."
  :type 'hook
  :group 'elneo)

(defcustom elneo-recovery-state-hook nil
  "Hook run on recovery (key backup) state changes.
Called with one argument: a plist with :profile :state :error."
  :type 'hook
  :group 'elneo)

(defcustom elneo-download-update-hook nil
  "Hook run on media download state changes.
Called with one argument: a plist with :profile :source (the
serialized media source) :format (\"thumb\" or \"file\") :state
(\"downloading\", \"done\", \"error\" or \"cancelled\") :size and
:error.  The terminal response to a `elneo-download-media' request
is a separate `updateMediaFile' event, not a hook run."
  :type 'hook
  :group 'elneo)

;; Defined in elneo-verify.el (a UI layer); declared so code below can
;; clean it up without a byte-compile warning.
(defvar elneo-verify--buffers)
(declare-function elneo-verify--show-recovery-key "elneo-verify" (profile key stored-path))
(declare-function elneo-verify-device "elneo-verify" (profile))
(declare-function elneo-recover-keys "elneo-verify" (profile))

(defvar elneo-verifications (make-hash-table :test 'equal)
  "Hash table mapping flow ids to verification-state plists.
Keys: :profile :flow-id :user-id :device-id :we-started :state
:reason.  State strings: requested, ready, sas_started,
sas_keys_exchanged, sas_confirmed, done, cancelled.")

(defvar elneo-recovery-states (make-hash-table :test 'equal)
  "Hash table mapping profile names to recovery-state strings.")

;;; Account persistence

(defun elneo--accounts-load ()
  "Load registered accounts from `elneo-account-file' once.
Cross-module contract: elneo-verify.el and elneo-dired.el call
this from interactive specs — keep it idempotent and cheap."
  (unless elneo-accounts-loaded
    (setq elneo-accounts-loaded t)
    ;; A customized file name may carry `~' or a relative part; every
    ;; file primitive here (and in save) wants it absolute.
    (setq elneo-account-file (expand-file-name elneo-account-file))
    ;; The pre-rename accounts file is copy-migrated (never deleted —
    ;; the file holds the user's private login data and the old copy
    ;; stays as their backup), mirroring the data-base migration.
    ;; Copying to a temp file and renaming keeps a crashed copy from
    ;; ever appearing under the target name: the target is either the
    ;; complete copy or absent.
    (let ((old (locate-user-emacs-file "matrix-accounts.el")))
      (when (and (file-exists-p old)
                 (not (file-exists-p elneo-account-file))
                 (not (file-equal-p old elneo-account-file)))
        (let ((tmp-copy (make-temp-file
                         (expand-file-name "elneo-accounts-copy"
                                           (file-name-directory
                                            elneo-account-file)))))
          (condition-case err
              (progn (copy-file old tmp-copy t)
                     (rename-file tmp-copy elneo-account-file)
                     (message "elneo: accounts file copied %s -> %s"
                              old elneo-account-file))
            (error
             (warn "elneo: could not copy the accounts file %s to %s (%s)"
                   old elneo-account-file (nth 1 err)))))))
    (when (file-exists-p elneo-account-file)
      (with-temp-buffer
        (insert-file-contents elneo-account-file)
        (let ((saved (ignore-errors (read (current-buffer)))))
          (setq elneo-accounts (and (listp saved) saved))
          ;; A truncated elneo-account-file (the copy crashed, or a
          ;; stray write) parses to nil — loading zero accounts
          ;; silently would read as "lost my account".  The intact
          ;; pre-rename file sits next to it; name both paths.  (The
          ;; temp+rename copy above keeps new truncations from
          ;; happening; this is for one that predates it.)
          (when (and (null elneo-accounts)
                     (file-exists-p
                      (locate-user-emacs-file "matrix-accounts.el")))
            (warn "elneo: %s does not parse (truncated?); the \
pre-rename %s looks intact — check and copy it over"
                  elneo-account-file
                  (locate-user-emacs-file "matrix-accounts.el"))))))))

(defun elneo--accounts-save ()
  "Save registered accounts to `elneo-account-file'."
  (with-temp-file (expand-file-name elneo-account-file)
    (let ((print-length nil))
      ;; Only non-secret fields are persisted (:user-id and :device-id are
      ;; public identifiers; the password is only used for the login request
      ;; and never stored).  prin1's stream argument is required: unbound
      ;; standard-output means the echo area, which would silently write an
      ;; empty file.
      (prin1 elneo-accounts (current-buffer)))))

(defun elneo--account-register (profile homeserver)
  "Remember PROFILE with HOMESERVER in `elneo-accounts'."
  (setf (alist-get profile elneo-accounts nil nil #'equal)
        (plist-put (alist-get profile elneo-accounts nil nil #'equal)
                   :homeserver homeserver))
  (elneo--accounts-save))

;;; Event fan-in

(defun elneo-client--room-record (room-summary)
  "Build a room record plist from a daemon room-summary alist."
  (list
   :name (alist-get 'name room-summary)
   :display-name (or (alist-get 'display_name room-summary) "")
   :room-state (or (alist-get 'room_state room-summary) "joined")
   :avatar (alist-get 'avatar_url room-summary)
   :topic (alist-get 'topic room-summary)
   :alias (alist-get 'canonical_alias room-summary)
   :encrypted (eq (alist-get 'is_encrypted room-summary) t)
   :direct (eq (alist-get 'is_direct room-summary) t)
   :space (eq (alist-get 'is_space room-summary) t)
   :unread (or (alist-get 'unread_notifications room-summary) 0)
   :highlights (or (alist-get 'unread_highlights room-summary) 0)
   :last-activity (alist-get 'last_activity room-summary)
   :preview (alist-get 'last_event_preview room-summary)
   :last-event-id (alist-get 'last_event_id room-summary)
   :notification-mode (alist-get 'notification_mode room-summary)
   :notification-mode-user-defined
   (alist-get 'user_defined_notification_mode room-summary)
   :bridge (alist-get 'bridge_protocol room-summary)
   :upgraded-to (alist-get 'upgraded_to room-summary)
   :upgraded-from (alist-get 'upgraded_from room-summary)
   ;; Event-id strings; nil when the room carries no pinned-events
   ;; state (protocol 22).
   :pinned (append (alist-get 'pinned_events room-summary) nil)))

(defun elneo-client--on-update-room (profile event)
  "Handle updateRoom for PROFILE: merge into the registry, notify UIs."
  (let* ((summary (alist-get 'room event))
         (room-id (alist-get 'room_id summary))
         (key (cons profile room-id))
         (old (gethash key elneo--rooms))
         (record (append (elneo-client--room-record summary)
                         (list :profile profile :room-id room-id)
                         (and old (list :buffer (plist-get old :buffer))))))
    (puthash key record elneo--rooms)
    (run-hook-with-args 'elneo-room-update-hook record)))

(defun elneo-client--on-update-room-gone (profile event)
  "Handle updateRoomGone for PROFILE: drop the room, notify UIs."
  (let* ((room-id (alist-get 'room_id event))
         (key (cons profile room-id))
         (old (gethash key elneo--rooms)))
    (remhash key elneo--rooms)
    (when old
      (run-hook-with-args 'elneo-room-update-hook
                          (plist-put (copy-sequence old) :removed t)))))

(defun elneo-client--reaction-plists (reactions)
  "Convert wire REACTIONS (alist of ReactionEntry) to plists.
Owns the wire->plist shape so the live new-message handler, the
reactions handler and the history path cannot diverge: a raw alist
flowing into the room buffer signals wrong-type-argument the moment
a reaction line is rendered."
  (mapcar (lambda (r)
            (list :key (alist-get 'key r)
                  :count (alist-get 'count r)
                  :own (eq (alist-get 'own r) t)))
          reactions))

(defun elneo-client--poll-plist (poll)
  "Convert the wire POLL (alist of PollEntry) to a plist, or nil.
Owns the wire->plist shape so the live new-message handler, the
updatePoll handler and the history path cannot diverge.  The
options' `voters' list normalize the JSON vector to a list —
`json-read-from-string' yields vectors, and `member' never matches
a vector."
  (when poll
    (list :question (alist-get 'question poll)
          :kind (alist-get 'kind poll)
          :max-selections (or (alist-get 'max_selections poll) 1)
          :ended (eq (alist-get 'ended poll) t)
          :options (mapcar (lambda (o)
                             (list :id (alist-get 'id o)
                                   :text (alist-get 'text o)
                                   :count (alist-get 'count o)
                                   :own (eq (alist-get 'own o) t)
                                   :voters (append (alist-get 'voters o) nil)))
                           (alist-get 'options poll)))))

(defun elneo-client--mentions-plist (mentions)
  "Convert the wire MENTIONS (alist of Mentions) to a plist, or nil.
Owns the wire->plist shape so the live new-message handler, the
history path and the alert filter cannot diverge.  User ids
normalize the JSON vector to a list — `json-read-from-string'
yields vectors, and `member' never matches a vector."
  (when mentions
    (list :user-ids (append (alist-get 'user_ids mentions) nil)
          :room (eq (alist-get 'room mentions) t))))

(defun elneo-client--on-update-new-message (profile event)
  "Handle updateNewMessage for PROFILE: update the room, notify UIs."
  (let* ((room-id (alist-get 'room_id event))
         (record (elneo-room-get profile room-id)))
    (when record
      ;; Update the preview immediately; a fresh updateRoom also follows.
      (setq record (copy-sequence record))
      (plist-put record :preview (alist-get 'body event))
      (plist-put record :last-event-id (alist-get 'event_id event))
      (plist-put record :last-activity (alist-get 'ts event))
      (puthash (cons profile room-id) record elneo--rooms))
    (run-hook-with-args 'elneo-new-message-hook
                        (list :profile profile
                              :room-id room-id
                              :event-id (alist-get 'event_id event)
                              :sender (alist-get 'sender event)
                              :sender-name (alist-get 'sender_name event)
                              :sender-avatar (alist-get 'sender_avatar event)
                              :body (alist-get 'body event)
                              :formatted-body (alist-get 'formatted_body event)
                              :ts (alist-get 'ts event)
                              :msgtype (alist-get 'msgtype event)
                              :media (alist-get 'media event)
                              :is-own (eq (alist-get 'is_own event) t)
                              :sender-trust (alist-get 'sender_trust event)
                              :reply-to (alist-get 'reply_to event)
                              :thread-root (alist-get 'thread_root event)
                              :reactions (elneo-client--reaction-plists
                                          (alist-get 'reactions event))
                              :poll (elneo-client--poll-plist
                                     (alist-get 'poll event))
                              :mentions (elneo-client--mentions-plist
                                         (alist-get 'mentions event))))))

(defun elneo-client--on-update-poll (profile event)
  "Handle updatePoll for PROFILE: notify UIs.
EVENT-ID names the poll start event; :poll is the full refreshed
aggregate — the room buffer re-renders the poll block with it.  A
nil :poll means the poll has no fold in this session (nothing to
render); the room layer skips it."
  (run-hook-with-args 'elneo-poll-update-hook
                      (list :profile profile
                            :room-id (alist-get 'room_id event)
                            :event-id (alist-get 'event_id event)
                            ;; The arriving event's own id (the vote's
                            ;; or the poll end's): read-marker pass-over
                            ;; — it stands after the rendered newest
                            ;; message but counts unread on the server.
                            :source-event-id (alist-get 'source_event_id event)
                            :poll (elneo-client--poll-plist
                                   (alist-get 'poll event)))))

(defun elneo-client--on-update-reactions (profile event)
  "Handle updateReactions for PROFILE: notify UIs.
An empty reactions list means no reactions remain on the event."
  (run-hook-with-args 'elneo-reactions-update-hook
                      (list :profile profile
                            :room-id (alist-get 'room_id event)
                            :event-id (alist-get 'event_id event)
                            ;; The reaction's own id: read-marker pass-over.
                            :source-event-id (alist-get 'source_event_id event)
                            :reactions (elneo-client--reaction-plists
                                        (alist-get 'reactions event)))))

(defun elneo-client--receipt-plists (event)
  "Convert the wire receipts of EVENT (alist) to plists.
Owns the wire->plist shape so the live update handler and the seed
response cannot diverge."
  (mapcar (lambda (r)
            (list :user-id (alist-get 'user_id r)
                  :user-name (alist-get 'user_name r)
                  :event-id (alist-get 'event_id r)
                  :ts (alist-get 'ts r)
                  :target-ts (alist-get 'target_ts r)))
          (alist-get 'receipts event)))

(defun elneo-client--on-update-read-receipts (profile event)
  "Handle updateReadReceipts for PROFILE: notify UIs.
The receipts list is a full refresh of the room's other-member
public m.read receipts."
  (run-hook-with-args 'elneo-read-receipts-update-hook
                      (list :profile profile
                            :room-id (alist-get 'room_id event)
                            :receipts (elneo-client--receipt-plists event))))

(defun elneo-client--on-update-own-read-receipt (profile event)
  "Handle updateOwnReadReceipt for PROFILE: the account read up to
EVENT-ID, on another device (or an echo of this device's mark)."
  (run-hook-with-args 'elneo-own-read-receipt-update-hook
                      (list :profile profile
                            :room-id (alist-get 'room_id event)
                            :event-id (alist-get 'event_id event)
                            :ts (alist-get 'ts event))))

(defun elneo-client--on-update-edited (profile event)
  "Handle updateEdited for PROFILE: notify UIs.
EVENT-ID names the original event; the fields carry its new content."
  (run-hook-with-args 'elneo-edited-update-hook
                      (list :profile profile
                            :room-id (alist-get 'room_id event)
                            :event-id (alist-get 'event_id event)
                            :body (alist-get 'body event)
                            :formatted-body (alist-get 'formatted_body event)
                            :msgtype (alist-get 'msgtype event)
                            :media (alist-get 'media event)
                            :geo (alist-get 'geo event)
                            ;; The edit event's own id: read-marker pass-over.
                            :source-event-id (alist-get 'source_event_id event)
                            :edited-ts (alist-get 'edited_ts event))))

(defun elneo-client--on-update-message-redacted (profile event)
  "Handle updateMessageRedacted for PROFILE: notify UIs."
  (run-hook-with-args 'elneo-redaction-update-hook
                      (list :profile profile
                            :room-id (alist-get 'room_id event)
                            :event-id (alist-get 'event_id event))))

(defun elneo-client--on-update-room-keys (profile event)
  "Handle updateRoomKeys for PROFILE: notify UIs."
  (run-hook-with-args 'elneo-room-keys-updated-hook
                      profile (alist-get 'room_id event)))

(defun elneo-client--record-session (profile event)
  "Record PROFILE's session identity (user id, device id) from EVENT.
Both the login response and a restored-session updateSession carry
the same pair; this is the one writer of `elneo-accounts' session
fields."
  (elneo-server--on-update-session profile event)
  (setf (alist-get profile elneo-accounts nil nil #'equal)
        (plist-put (plist-put (alist-get profile elneo-accounts nil nil #'equal)
                              :user-id (alist-get 'user_id event))
                   :device-id (alist-get 'device_id event))))

(defun elneo-client--on-update-session (profile event)
  "Handle unsolicited updateSession for PROFILE (restored session)."
  (elneo-client--record-session profile event))

(defun elneo-client--on-update-verification (profile event)
  "Handle updateVerificationRequest for PROFILE: merge and notify UIs."
  (let* ((flow-id (alist-get 'flow_id event))
         (state (alist-get 'state event))
         (record (list :profile profile
                       :flow-id flow-id
                       :user-id (alist-get 'user_id event)
                       :device-id (alist-get 'device_id event)
                       :we-started (eq (alist-get 'we_started event) t)
                       :state state
                       :reason (alist-get 'reason event))))
    (if (member state '("done" "cancelled"))
        (remhash flow-id elneo-verifications)
      (puthash flow-id record elneo-verifications))
    (run-hook-with-args 'elneo-verification-update-hook record)))

(defun elneo-client--on-verification-emojis (profile event)
  "Handle updateVerificationEmojis for PROFILE: notify UIs."
  (run-hook-with-args 'elneo-verification-emoji-hook
                      (list :profile profile
                            :flow-id (alist-get 'flow_id event)
                            :emojis (mapcar (lambda (pair)
                                              (cons (aref pair 0) (aref pair 1)))
                                            (alist-get 'emojis event))
                            :decimals (append (alist-get 'decimals event) nil))))

(defun elneo-client--on-recovery-state (profile event)
  "Handle updateRecoveryState for PROFILE: record and notify UIs."
  (let ((state (alist-get 'state event))
        (error-msg (alist-get 'error event)))
    (puthash profile state elneo-recovery-states)
    (run-hook-with-args 'elneo-recovery-state-hook
                        (list :profile profile :state state :error error-msg))))

(defun elneo-client--on-recovery-enabled (profile event)
  "Handle `recoveryEnabled' for PROFILE: show the key, once.
This normally arrives as `enableRecovery's response; the daemon
also enables recovery by itself for an account without
cross-signing keys (the background bring-up), in which case the
event arrives untagged — and the one-time display still owes the
user their key."
  (when-let* ((key (alist-get 'recovery_key event nil nil #'equal)))
    (elneo-verify--show-recovery-key
     profile key (alist-get 'stored_path event nil nil #'equal))))

(defvar elneo-client--verification-nudged nil
  "Alist of (PROFILE . t) once the verification-needed prompt ran there.
The daemon repeats its background crypto check at every activation;
the guard makes one answer binding for the whole Emacs session —
but only until the profile's local state goes away: a logout or a
forget clears the entry, so a re-login on the same profile name
gets asked again.")

(defun elneo-client--on-verification-needed (profile event)
  "Handle updateVerificationNeeded for PROFILE: prompt once.
The daemon's background crypto bring-up found an identity this
session cannot adopt on its own — the account is cross-signed, but
this machine holds no way to trust it — and only the user can
bridge that gap, so Emacs asks.  Like the update offer
(`elneo-client--update-too-old'), this runs inside a process
filter: redisplay keeps working underneath, the answer blocks the
session's event stream until given.  At most once per profile per
Emacs session, whichever answer."
  (unless (assoc profile elneo-client--verification-nudged)
    ;; Marked before the ask, so the answer — whichever it was —
    ;; keeps the rest of this session quiet.  A restart of the
    ;; daemon re-runs the check, a restart of Emacs re-asks.
    (setf (alist-get profile elneo-client--verification-nudged nil nil #'equal) t)
    (require 'elneo-verify)
    (let* ((reason (alist-get 'reason event))
           ;; Storage set up elsewhere means the user may hold its key
           ;; on paper or in a password manager: entering it here is
           ;; the faster path, so offer it.  Without storage there is
           ;; nothing to recover from — only another device's
           ;; attestation can adopt the identity.
           (has-key (equal reason "no-recovery-key"))
           (blurb (pcase reason
                    ("no-storage"
                     "the account is cross-signed, but has no secret \
storage this machine could adopt its keys from")
                    ("no-recovery-key"
                     "the account has key recovery set up, but this \
machine holds no recovery key")
                    (_ "this machine cannot adopt its keys")))
           (choices (if has-key '(?v ?r ?q) '(?v ?q)))
           (answer
            (read-char-choice
             (format "Matrix [%s]: this session is not verified — %s. \
%s? "
                     profile blurb
                     (if has-key
                         "(v)erify with another device, enter the \
(r)ecovery key, or (q)uit"
                       "(v)erify with another device, or (q)uit"))
             choices)))
      (cond
       ((eq answer ?v) (elneo-verify-device profile))
       ((eq answer ?r) (elneo-recover-keys profile))
       (t (message "Matrix [%s] not verifying now — M-x \
elneo-verify-device or M-x elneo-recover-keys when ready"
                   profile))))))

(defun elneo-client--on-download-update (profile event)
  "Handle updateDownload for PROFILE: notify download watchers."
  (run-hook-with-args 'elneo-download-update-hook
                      (list :profile profile
                            :source (alist-get 'source event)
                            :format (alist-get 'format event)
                            :state (alist-get 'state event)
                            :size (alist-get 'size event)
                            :error (alist-get 'error event))))

(defun elneo-client--register-handlers (profile)
  "Register the client-layer event handlers for PROFILE."
  (let ((callbacks (elneo-server--get-callbacks profile)))
    (puthash "updateRoom" #'elneo-client--on-update-room callbacks)
    (puthash "updateRoomGone" #'elneo-client--on-update-room-gone callbacks)
    (puthash "updateNewMessage" #'elneo-client--on-update-new-message callbacks)
    (puthash "updateReactions" #'elneo-client--on-update-reactions callbacks)
    (puthash "updatePoll" #'elneo-client--on-update-poll callbacks)
    (puthash "updateReadReceipts" #'elneo-client--on-update-read-receipts callbacks)
    (puthash "updateOwnReadReceipt"
             #'elneo-client--on-update-own-read-receipt callbacks)
    (puthash "updateEdited" #'elneo-client--on-update-edited callbacks)
    (puthash "updateMessageRedacted"
             #'elneo-client--on-update-message-redacted callbacks)
    (puthash "updateRoomKeys" #'elneo-client--on-update-room-keys callbacks)
    ;; Sync state recording lives in the transport layer (it must work
    ;; even for an inert session); the auto-restart observer hangs on
    ;; the hook it fires.
    (puthash "updateSyncState" #'elneo-server--on-update-sync-state callbacks)
    (puthash "updateSession" #'elneo-client--on-update-session callbacks)
    (puthash "updateVerificationRequest"
             #'elneo-client--on-update-verification callbacks)
    (puthash "updateVerificationEmojis"
             #'elneo-client--on-verification-emojis callbacks)
    (puthash "updateRecoveryState" #'elneo-client--on-recovery-state callbacks)
    (puthash "recoveryEnabled" #'elneo-client--on-recovery-enabled callbacks)
    (puthash "updateVerificationNeeded"
             #'elneo-client--on-verification-needed callbacks)
    (puthash "updateDownload" #'elneo-client--on-download-update callbacks)
    ;; Keep the transport layer's defaults.
    (puthash "updateCrossSigningStatus"
             #'elneo-server--on-update-cross-signing-status callbacks)))

;;; Session activation


(defvar elneo-client--update-offered nil
  "Alist of (PROFILE . t) after PROFILE's stale-daemon download offer.
Both a no and a failed download mark the profile: the gate
re-evaluates on every auto-restart tick, and every backoff cycle
must not re-ask.  Cleared when the daemon next reports \"synced\",
so a genuinely new offline streak asks again.")

(defun elneo-client--update-too-old (profile daemon)
  "Offer PROFILE a release download for its below-minimum daemon.
The user is asked with `y-or-n-p' — nothing downloads without
confirmation.  On a no, or a failed download, exactly today's
block ensues.  On a yes the verified binary is installed (see
`elneo-release-download'), the stale process is stopped and its
auto-restarter re-armed: the respawned daemon greets the current
protocol, its reactivation passes the gate and the session
activates around it.  The offer itself asks at most once per
offline streak, and runs inside a process filter (the gate is
reached from the getSession response) — redisplay keeps working
underneath it, but keep the download's synchronous wait in mind
when reading this."
  (unless (assoc profile elneo-client--update-offered)
    ;; Marked before the ask, so the answer — whichever it was —
    ;; ends the streak's offers.
    (setf (alist-get profile elneo-client--update-offered nil nil #'equal) t)
    (when (y-or-n-p
           (format "Matrix [%s] daemon is outdated (protocol %s < %s) — download the latest release from %s? "
                   profile daemon elneo-daemon-protocol-minimum
                   elneo-release-repo))
      (let ((bin (elneo-release-download (elneo--data-dir-base))))
        (if (and bin (elneo-server-live-p profile))
            (progn
              (message "Matrix [%s] installed %s — restarting the daemon"
                       profile bin)
              (elneo-server-stop profile)
              ;; The stop was the update's bookkeeping, not a
              ;; decision to stay down: the deliberate-stop
              ;; suppression ends here and the restarter spawns the
              ;; new binary, whose greeting activates the session.
              (setq elneo-server--manual-stops
                    (assoc-delete-all profile elneo-server--manual-stops))
              (elneo-client--maybe-schedule-restart profile))
          (message "Matrix [%s] release download did not replace the running daemon — staying blocked" profile))))))

(defun elneo-client--protocol-gate (profile)
  "Check the daemon's protocol version for PROFILE against the client's.
Returns non-nil when activation may proceed; blocks below-minimum
and unknown (pre-versioning) daemons unless
`elneo-daemon-protocol-allow-outdated' is set, and only warns on a
daemon newer than this client.  A blocked verdict stops the event
stream it can: a daemon that outlived a previous client session may
still have a sync loop running, and its events must not animate the
UI under the blocked warning.  (Daemons speaking protocol 2 get a
stopSync command; older ones cannot be quenched this way — see the
handlers note in `elneo-client--activate'.)"
  (let* ((daemon (elneo-server--daemon-protocol profile))
         (verdict (elneo-server--protocol-verdict
                   elneo-daemon-protocol
                   elneo-daemon-protocol-minimum
                   daemon)))
    (pcase verdict
      (:ok t)
      (:too-new
       (message "Matrix [%s] daemon speaks protocol %d, newer than this client (%d) — update the Emacs packages"
                profile daemon elneo-daemon-protocol)
       t)
      ((or :too-old :unknown)
       (if elneo-daemon-protocol-allow-outdated
           t
         ;; Quench an inherited sync loop.  stopSync arrived with
         ;; protocol 2; daemons below that cannot be quenched and keep
         ;; streaming, into a now-inert session (the activation only
         ;; registers the client handlers past this point).
         (when (and (numberp daemon) (>= daemon 2))
           (elneo-server--call profile '((@type . "stopSync")) nil))
         ;; A below-minimum daemon is the one situation a fresh
         ;; release can actually fix; :unknown has no version to
         ;; compare — the block alone stays for those.
         (when (eq verdict :too-old)
           (elneo-client--update-too-old profile daemon))
         (message "Matrix [%s] activation blocked: %s (need protocol >= %d) — update elneo-server (`make server-install' or the new release), then M-x elneo-restart-server; set `elneo-daemon-protocol-allow-outdated' to override"
                  profile
                  (if (integerp daemon)
                      (format "daemon protocol %d is below the supported minimum" daemon)
                    "daemon did not report a protocol version")
                  elneo-daemon-protocol-minimum)
         nil)))))

(defun elneo-client--activate (profile)
  "Bring PROFILE online: check session, then sync and list rooms."
  (unless (elneo-server-live-p profile)
    (elneo-server-start profile))
  ;; Re-assert the greeting handler however this session's tables came
  ;; to be (stale build, hot reload): the gate below depends on having
  ;; processed it.
  (elneo-server--ensure-callbacks profile)
  ;; Client handlers register only after the gate passes, inside the
  ;; getSession callback: an activation that is about to be blocked
  ;; must stay inert, because a daemon that outlived the previous
  ;; client session still has its sync loop running and streams events
  ;; into this session — registered handlers would animate the room
  ;; registry, the bar and alerts right under the blocked warning.
  (elneo-server--call profile '((@type . "getSession"))
                      (lambda (profile event)
                        (if (alist-get '@ok event nil nil #'equal)
                            (if (elneo-client--protocol-gate profile)
                                (progn
                                  (elneo-client--register-handlers profile)
                                  (elneo-client--on-update-session profile event)
                                  (elneo-server--call profile '((@type . "getRooms")) nil)
                                  (run-hook-with-args 'elneo-session-activated-hook profile)
                                  (elneo-server--call profile '((@type . "startSync"))
                                                      (lambda (profile event)
                                                        (unless (alist-get '@ok event nil nil #'equal)
                                                          (message "Matrix [%s] %s" profile
                                                                   (elneo-server--error-string event))))))
                              (message "Matrix [%s] session found, but not activated — fix the daemon protocol mismatch above, then M-x elneo-restart-server"
                                       profile))
                          (message "Matrix [%s] not logged in — use M-x elneo-add-account"
                                   profile)))))

;;;###autoload
(defun elneo-restart-server (&optional profile)
  "Restart the daemon PROFILE, or every running daemon.
The daemon update flow: build the new binary and put it where
`elneo-server-command' finds it (replacing a running daemon's file
is safe — the old process keeps its image), then run this.
Open room buffers survive; re-activation refetches their state
once the new daemon comes back online."
  (interactive
   ;; Load accounts first: without a prefix-arg the list of running
   ;; daemons is enumerated over `elneo-accounts', which is empty
   ;; after an Emacs restart until something loads it.
   (progn (elneo--accounts-load)
          (list (when current-prefix-arg
                  (completing-read "Restart daemon for profile: "
                                   (mapcar #'car elneo-accounts)
                                   nil t (car (car elneo-accounts)))))))
  (let ((targets (if profile
                     (list profile)
                   (let (running)
                     (dolist (account elneo-accounts)
                       (when (elneo-server-live-p (car account))
                         (push (car account) running)))
                     (nreverse running)))))
    (if (null targets)
        (user-error "No running elneo-server daemon")
      (dolist (p targets)
        (message "Matrix [%s] restarting daemon" p)
        (elneo-server-stop p)
        ;; Give the old process a moment to release the sqlite store
        ;; before the new one opens it.
        (sleep-for 0.2)
        (elneo-client--activate p)))))

;;;###autoload
(defun elneo-upgrade-server ()
  "Upgrade the elneo-server daemon from the latest release.
The manual twin of the stale-daemon offer
(`elneo-client--update-too-old'): download this machine's asset
from `elneo-release-repo' (synchronous, SHA256-verified, the same
data-dir install), then restart every running daemon
(`elneo-restart-server' — replacing a running daemon's file is
safe, the old process keeps its image until it exits).

When `elneo-server-command' still resolves to a binary elsewhere —
a PATH install, an absolute path — a restart would spawn that one
and the downloaded binary would sit unused, since
`elneo-server--command-to-run' prefers the explicit command.  A
mismatching resolution asks to point the variable at the fresh
binary for this session; a permanent switch lives in Customize."
  (interactive)
  (elneo--accounts-load)
  (unless (elneo-release--asset-name)
    (user-error "No elneo-server release for this machine (%s)"
                system-configuration))
  (let ((live (let (running)
                (dolist (account elneo-accounts)
                  (when (elneo-server-live-p (car account))
                    (push (car account) running)))
                (nreverse running))))
    (if (not (if live
                 (y-or-n-p
                  (format "Download the latest elneo-server release and restart %d running daemon(s)? "
                          (length live)))
               (y-or-n-p "Download the latest elneo-server release? ")))
        (message "Matrix: upgrade skipped")
      ;; The download messages its own reason on failure.
      (unless (elneo-release-download (elneo--data-dir-base))
        (user-error "elneo-server upgrade failed (reason echoed above)"))
      ;; A PATH (or absolute) `elneo-server-command' outranks the
      ;; downloaded binary at start time — without this ask the fresh
      ;; install would never be picked up.
      (let* ((installed (elneo-release--installed-path))
             (effective (or (and (file-name-absolute-p elneo-server-command)
                                 elneo-server-command)
                            (executable-find elneo-server-command)
                            installed)))
        (when (and installed effective
                   (not (file-equal-p effective installed))
                   (y-or-n-p
                    (format "Point elneo-server-command at %s (it currently resolves to %s)? "
                            installed effective)))
          (setq elneo-server-command installed)
          ;; Session-only on purpose: persisting underneath Customize
          ;; would surprise the next session; a permanent switch is
          ;; the defcustom's own job (use-package, Customize, init).
          (message "Matrix: elneo-server-command points at the new \
binary for this session")))
      (if live
          (elneo-restart-server)
        (message "Matrix: nothing running — the new binary takes effect \
on the next `elneo-start'")))))

;;; Automatic restart

;; elneo-server.el records the states and fires
;; `elneo-session-sync-hook'; this side decides what a dead daemon
;; means for the account list and re-brings it up.  Split that way so
;; the transport layer never has to know how activation works.

(defun elneo-client--on-session-sync-state (profile state _error-msg)
  "React to a sync-state transition on `elneo-session-sync-hook'.
\"offline\" schedules the auto-restart; anything else cancels a
pending one (\"synced\" additionally resets the backoff attempts),
so a daemon that recovers on its own — or a user who restarted it —
never races an armed timer."
  (pcase state
    ("offline" (elneo-client--maybe-schedule-restart profile))
    ("synced" (elneo-client--reset-restart-state profile))
    (_ (elneo-client--clear-restart-timer profile))))

(defun elneo-client--reset-restart-state (profile)
  "A healthy session again: forget PROFILE's restart attempts and
timer, and re-arm its stale-daemon download offer for the next
offline streak."
  (let ((entry (assoc profile elneo-server--restarts)))
    (when entry
      (let ((timer (plist-get (cdr entry) :timer)))
        (when (and timer (timerp timer)) (cancel-timer timer)))
      (setq elneo-server--restarts
            (assoc-delete-all profile elneo-server--restarts))))
  (setq elneo-client--update-offered
        (assoc-delete-all profile elneo-client--update-offered)))

(defun elneo-client--clear-restart-timer (profile)
  "Cancel any pending auto-restart for PROFILE (attempts untouched)."
  (let ((entry (assoc profile elneo-server--restarts)))
    (when entry
      (let ((timer (plist-get (cdr entry) :timer)))
        (when (and timer (timerp timer)) (cancel-timer timer))
        (setcdr entry (list :attempts (plist-get (cdr entry) :attempts)))))))

(defun elneo-client--restart-cell (profile)
  "The (PROFILE . PLIST) restart bookkeeping cons for PROFILE.
Creates the entry on first use; PLIST holds :attempts and :timer."
  (or (assoc profile elneo-server--restarts)
      (progn
        (push (cons profile nil) elneo-server--restarts)
        (assoc profile elneo-server--restarts))))

(defun elneo-client--restart-timer-p (timer)
  "Non-nil when TIMER is both live and actually scheduled."
  (and timer (timerp timer) (memq timer timer-list) t))

(defun elneo-client--maybe-schedule-restart (profile)
  "Arm the auto-restart for a PROFILE whose daemon just went offline.
Suppressed when auto-restart is off (the setting), the profile never
activated (absent from `elneo-accounts' — a bare
`elneo-server-start' daemon belongs to no account), a deliberate
stop is in progress, or the give-up cap is reached.  The backoff
doubles each attempt from `elneo-server-restart-backoff' up to
`elneo-server-restart-backoff-max'."
  (when elneo-server-auto-restart
    (unless (assoc profile elneo-accounts)
      (elneo--debug-log "Matrix [%s] down but never activated — no restart" profile))
    (when (assoc profile elneo-accounts)
      (if (assoc profile elneo-server--manual-stops)
          (elneo--debug-log
           "Matrix [%s] deliberately stopped — no auto-restart" profile)
        (let* ((entry (elneo-client--restart-cell profile))
               (timer (plist-get (cdr entry) :timer)))
          (if (elneo-client--restart-timer-p timer)
              (elneo--debug-log "Matrix [%s] restart already armed" profile)
            (let ((attempts (or (plist-get (cdr entry) :attempts) 0)))
              (if (and elneo-server-auto-restart-max-attempts
                       (>= attempts elneo-server-auto-restart-max-attempts))
                  (message "Matrix [%s] auto-restart gave up after %d attempts\
 — run M-x elneo-restart-server" profile attempts)
                (let ((delay (min elneo-server-restart-backoff-max
                                  (* elneo-server-restart-backoff
                                     (ash 1 (min attempts 20))))))
                  (message "Matrix [%s] server is down — auto-restarting in\
 %ds" profile delay)
                  (setcdr entry (list :attempts (1+ attempts)
                                      :timer (run-at-time
                                              delay nil
                                              #'elneo-client--restart-tick
                                              profile))))))))))))

(defun elneo-client--restart-tick (profile)
  "One auto-restart attempt for a dead PROFILE's daemon.
`elneo-client--activate' is the same idempotent bring-up path a
manual restart takes.  Errors are caught: `elneo-server-start'
signals when `elneo-server-command' is unfindable, and an error
inside a timer must not crashloop without the backoff.  The entry's
timer is already fired when this runs; only :attempts survives."
  (let ((entry (assoc profile elneo-server--restarts)))
    (when entry
      (setcdr entry (list :attempts (plist-get (cdr entry) :attempts)))))
  (unless (elneo-server-live-p profile)
    (condition-case err
        (elneo-client--activate profile)
      (error
       (message "Matrix [%s] auto-restart failed: %s" profile
                (error-message-string err))))))

(add-hook 'elneo-session-sync-hook #'elneo-client--on-session-sync-state)

;;;###autoload
(defun elneo-quit ()
  "Stop every Matrix daemon and kill all Matrix buffers.
Server processes, room buffers, the room bar and the *Matrix Debug*
buffer go away; the room registry and pending requests are cleared.
Homeserver sessions persist on disk, so activating the profiles
again brings everything back with fresh state."
  (interactive)
  (require 'elneo-room)
  (let* ((daemons (copy-sequence elneo-server--buffers))
         (bar (get-buffer "*Matrix Rooms*"))
         (rooms (hash-table-count elneo-room--buffers)))
    (if (and (null daemons) (= rooms 0) (null bar))
        (message "Matrix: nothing to quit")
      (when (y-or-n-p
             (format "Stop %d server%s, kill %d room buffer%s and the room bar? "
                     (length daemons) (if (= (length daemons) 1) "" "s")
                     rooms (if (= rooms 1) "" "s")))
        ;; A pending auto-restart must not outlive a quit: stop them
        ;; all first (the deliberate-stop flag set below by
        ;; `elneo-server-stop' already suppresses new ones).
        (dolist (entry elneo-server--restarts)
          (let ((timer (plist-get (cdr entry) :timer)))
            (when (and timer (timerp timer)) (cancel-timer timer))))
        (setq elneo-server--restarts nil)
        ;; Daemons first: a live one could push another update into a
        ;; registry entry mid-teardown.
        (dolist (entry daemons)
          (ignore-errors (elneo-server-stop (car entry))))
        (maphash (lambda (_key buffer)
                   (when (buffer-live-p buffer) (kill-buffer buffer)))
                 elneo-room--buffers)
        (clrhash elneo-room--buffers)
        (when bar
          (let ((window (get-buffer-window bar 'all-frames)))
            (when window (ignore-errors (delete-window window))))
          (kill-buffer bar))
        (when (get-buffer "*Matrix Debug*")
          (kill-buffer "*Matrix Debug*"))
        ;; A cleared registry cannot show stale rooms after reconnecting;
        ;; pending responses belong to the stopped daemons.
        (clrhash elneo--rooms)
        (dolist (entry elneo-server--pending)
          (clrhash (cdr entry)))
        (message "Matrix: stopped")))))

;;; Account management

(defun elneo-client--on-login (profile event)
  "Handle the login response for PROFILE."
  (if (alist-get '@ok event nil nil #'equal)
      (progn
        (elneo-client--record-session profile event)
        (message "Matrix [%s] logged in" profile)
        (elneo-client--activate profile))
    (message "Matrix [%s] login failed: %s" profile
             (elneo-server--error-string event))))

(defun elneo--data-dir-base ()
  "Base directory of all daemon and client state for elneo.
Mirrors the daemon's `directories::ProjectDirs::from(\"fi\", \"aard\",
\"elneo\")' data dir: on macOS
~/Library/Application Support/fi.aard.elneo (the bundle id); on XDG
the directories crate ignores qualifier and organization and uses
the bare application name, so XDG_DATA_HOME/elneo (defaulting to
~/.local/share).  Mirrors the daemon's base-dir migration too (see
`elneo--migrate-data-base')."
  (elneo--migrate-data-base
   (if (eq system-type 'darwin)
       (file-name-concat
        (expand-file-name "~/Library/Application Support")
        "fi.aard.elneo")
     (let ((xdg (getenv "XDG_DATA_HOME")))
       (file-name-concat
        (if (and xdg (file-name-absolute-p xdg))
            xdg
          (expand-file-name ".local/share" (expand-file-name "~")))
        "elneo")))))

;; The pre-rename bases (`elneo--data-dir-base' used to be built from
;; these names); the daemon migrates them itself — this elisp twin
;; covers daemon-independent consumers so they never see a stale path.
(defvar elneo--migrated-data-base nil
  "The data base this session has already migrated, or nil.")

;; Whether BASE holds at least one top-level profile session — mirrors
;; the daemon's base_has_sessions: a directory entry carrying a
;; session.json is the whole of "has data worth migrating" (drafts.el
;; and the media cache ride along, but a session-less base holds
;; nothing a user would miss).
(defun elneo--base-has-sessions-p (base)
  "Return non-nil when the data base BASE holds a profile session."
  (let ((found))
    (when (file-directory-p base)
      (dolist (d (directory-files base t directory-files-no-dot-files-regexp))
        (when (file-exists-p (expand-file-name "session.json" d))
          (setq found t))))
    found))

(defun elneo--adopt-old-base (old new-base)
  "Move the old data base OLD's entries into the session-less NEW-BASE.
Mirrors the daemon's both-exists adoption: a pre-created new base
with no session of its own must not strand the old one.  Any
failure warns with both paths and falls back to OLD for this
session."
  (condition-case err
      (progn
        (dolist (entry (directory-files old t directory-files-no-dot-files-regexp))
          (rename-file entry
                       (expand-file-name (file-name-nondirectory entry)
                                         new-base)))
        (delete-directory old)
        (message "elneo: data directory contents adopted %s -> %s"
                 old new-base)
        new-base)
    (error
     (warn "elneo: could not adopt %s into the pre-created data \
directory %s (%s); using the old base for this session"
           old new-base (nth 1 err))
     old)))

(defun elneo--migrate-data-base (new-base)
  "Return the data base NEW-BASE, migrating the old one first.
Same re-checked rule as the daemon's `migrate_data_base': an
existing old base moves to the new one once (`rename-file', whole
base — the daemon owns profiles/media/crypto; elisp consumers only
ride along), both bases coexisting with sessions in both is
warned and never merged, a session-less new base adopts the old
base's entries instead, a failing rename keeps the old base (or
follows the concurrent winner, if the rename failed because the old
base vanished mid-move), and both sides are re-checked immediately
before the move.  Deliberately side-effect-cheap for repeated calls
(the result is memoized)."
  (or (and elneo--migrated-data-base
           (file-equal-p elneo--migrated-data-base new-base)
           elneo--migrated-data-base)
      (let (old)
        (if (eq system-type 'darwin)
            (setq old (file-name-concat
                       (expand-file-name "~/Library/Application Support")
                       "com.emacs.matrix-client"))
          (let ((xdg (getenv "XDG_DATA_HOME")))
            (setq old (file-name-concat
                       (if (and xdg (file-name-absolute-p xdg))
                           xdg
                         (expand-file-name ".local/share"
                                           (expand-file-name "~")))
                       "matrix-client"))))
        (setq elneo--migrated-data-base
              (cond
               ;; Nothing to migrate.
               ((not (and (file-exists-p old)
                          (not (file-equal-p old new-base))))
                new-base)
               ;; Nothing to migrate INTO: the rename.
               ((not (file-exists-p new-base))
                (condition-case err
                    (progn (rename-file old new-base)
                           (message "elneo: data dir moved %s -> %s"
                                    old new-base)
                           new-base)
                  (error
                   ;; A failed rename is also the lost-race case (the
                   ;; check above passed, then a concurrent mover's
                   ;; rename landed): if the old base is gone and the
                   ;; new one exists, the move already happened.
                   (if (and (not (file-exists-p old))
                            (file-exists-p new-base))
                       (progn
                         (message "elneo: data directory was moved to %s \
by a concurrent process; using it (%s)"
                                  new-base (nth 1 err))
                         new-base)
                     (warn "elneo: could not move the data directory %s to \
%s (%s); using the old base for this session"
                           old new-base (nth 1 err))
                     old))))
               ;; Both exist: adopt only a session-less new base;
               ;; otherwise never merge — match the daemon's warning.
               ((and (elneo--base-has-sessions-p old)
                     (not (elneo--base-has-sessions-p new-base)))
                (elneo--adopt-old-base old new-base))
               (t
                (warn "elneo: both data directories exist (%s and %s); \
using the new one, not merging" old new-base)
                new-base)))
        elneo--migrated-data-base)))

(defun elneo--daemon-data-dir (profile)
  "The daemon's per-profile data directory for PROFILE.
Cross-module contract: elneo-verify.el and elneo-dired.el call
this despite the `--' name — keep it stable and side-effect-free."
  (file-name-concat (elneo--data-dir-base) profile))

(defun elneo--session-exists-p (profile)
  "Non-nil when the daemon already has a persisted session for PROFILE."
  (file-exists-p (expand-file-name "session.json"
                                   (elneo--daemon-data-dir profile))))

(defun elneo-client--check-profile-name (profile)
  "Signal a `user-error' when PROFILE cannot name a profile.
The name lands in filesystem paths (the daemon's data directory),
buffer and process names; a \"/\" would silently create
subdirectories and break the log file.  Keep it to path-safe
characters."
  (unless (and (stringp profile)
               (> (length profile) 0)
               (string-match-p "\\`[A-Za-z0-9._-]+\\'" profile))
    (user-error "Profile names may only use letters, digits, and `. _ -'")))

;;;###autoload
(defun elneo-add-account (profile &optional homeserver username password)
  "Log in a new Matrix account as PROFILE at HOMESERVER.
If the daemon already has a persisted session for PROFILE, it is
reused and no credentials are asked for.  The profile is remembered
for future `elneo-start' sessions.  A fresh login with no PASSWORD
asks for it."
  (interactive
   (let ((profile (read-string "Profile name: " elneo-default-profile)))
     (elneo-client--check-profile-name profile)
     ;; Onboarding preflight: this machine needs a daemon binary before
     ;; login is worth any of it.  A start would offer the download only
     ;; after the credentials below, and its file-error on a missing
     ;; binary would strand the password just collected — so offer here,
     ;; explicitly asked, and stop with a clear message on a decline.
     ;; Non-interactive calls change nothing: they reach the offer
     ;; through `elneo-server-start', as before.
     (unless (elneo-server--preflight-binary profile)
       (user-error "Matrix [%s]: no elneo-server binary found — set \
`elneo-server-command', put one on PATH, or re-run and accept the \
download offer" profile))
     ;; If the daemon still has a persisted session for this profile,
     ;; restore it instead of asking for credentials again.
     (if (elneo--session-exists-p profile)
         (list profile)
       ;; No password here.  `call-interactively' records the values
       ;; this form returns in `command-history', in clear text, and
       ;; `savehist-mode' writes that list to disk.  The body asks
       ;; for the password instead: a prompt there is not recorded
       ;; (see the Elisp manual, node "Command History").
       (list profile
             (read-string "Homeserver: " "https://matrix.org")
             (read-string "Username: ")))))
  (elneo-client--check-profile-name profile)
  (elneo--accounts-load)
  (if (null homeserver)
      ;; Session recovery: the daemon's data directory already holds the
      ;; session (and crypto store); just bring the profile online.
      (progn
        (elneo--debug-log "Matrix [%s] reusing persisted session" profile)
        (elneo-client--activate profile))
    ;; Fresh login.
    (unless password
      (setq password (read-passwd "Password: ")))
    (elneo--account-register profile homeserver)
    (unless (elneo-server-live-p profile)
      (elneo-server-start profile))
    (elneo-client--register-handlers profile)
    (elneo-server--call profile
                        `((@type . "login")
                          (homeserver . ,homeserver)
                          (username . ,username)
                          (password . ,password)
                          (device_name . ,elneo-device-name))
                        #'elneo-client--on-login))
  ;; A first account on a machine that never ran `elneo-start' should
  ;; still land in the room bar — without this the daemon runs and
  ;; rooms arrive, but nothing shows until the user knows the command.
  ;; Only a missing bar is born: a hidden one keeps its toggle, a live
  ;; one is already on screen.  The bar resurrects from a kill on the
  ;; next room event anyway (its design), so a killed bar counts as
  ;; missing here.
  ;;
  ;; elneo-verify loads here too: a first-time account's background
  ;; bring-up emits recoveryEnabled (the once-only key display) while
  ;; this function is still the only thing that has run — without the
  ;; require, that handler would die on a void function and the user
  ;; would never see their key.
  (require 'elneo-room-bar)
  (require 'elneo-verify)
  (unless (buffer-live-p elneo-room-bar--buffer)
    (elneo-room-bar-show)))

;;;###autoload
(defun elneo-logout-account (profile)
  "Log PROFILE out, server-side, and forget its session.
On the server's ok the daemon has deleted the session — the
process has nothing left to serve, so it is stopped, and the
Emacs-side display state (bar rows, open room buffers, pending
verification flows) goes with it: a logged-out account shows
neither online nor its rooms."
  ;; completing-read with REQUIRE-MATCH and an empty collection leaves
  ;; the user stuck in the prompt: load the accounts here so a fresh
  ;; restart sees its profiles, and refuse when there are none.
  (interactive (progn (elneo--accounts-load)
                      (unless elneo-accounts
                        (user-error "No Matrix profiles registered"))
                      (list (completing-read "Profile: "
                                             (mapcar #'car elneo-accounts)
                                             nil t))))
  (elneo-server--call profile '((@type . "logout"))
                      (lambda (profile event)
                        (if (alist-get '@ok event nil nil #'equal)
                            (progn
                              (message "Matrix [%s] logged out" profile)
                              (elneo--profile-local-cleanup profile)
                              (elneo-server-stop profile))
                          (message "Matrix [%s] %s" profile
                                   (elneo-server--error-string event))))))

(defun elneo--profile-local-cleanup (profile)
  "Drop PROFILE's Emacs-side display state.
Used by `elneo-logout-account' (the daemon deleted the session —
everything local that rendered it is now stale) and by
`elneo-forget-profile'.  Announcing each of PROFILE's rooms as
:removed reuses the normal room-gone path, so the bar updates
itself instead of needing a bespoke refresh here; open room
buffers, pending verification flows and the profile's verify and
recovery state go with them."
  (let ((gone nil))
    (maphash (lambda (key _room)
               (when (equal (car key) profile) (push key gone)))
             elneo--rooms)
    (dolist (key gone)
      (let ((room (gethash key elneo--rooms)))
        (remhash key elneo--rooms)
        (when room
          (run-hook-with-args 'elneo-room-update-hook
                              (plist-put (copy-sequence room) :removed t))))))
  ;; Same unbound-guard as the verify block below: this is a defvar
  ;; in elneo-room.el, void when that file was never loaded.
  (when (bound-and-true-p elneo-room--buffers)
    (let ((bufs nil))
      (maphash (lambda (key buffer)
                 (when (equal (car key) profile) (push (cons key buffer) bufs)))
               elneo-room--buffers)
      (dolist (entry bufs)
        (remhash (car entry) elneo-room--buffers)
        (when (buffer-live-p (cdr entry))
          (kill-buffer (cdr entry))))))
  (maphash (lambda (flow record)
             (when (equal (plist-get record :profile) profile)
               (remhash flow elneo-verifications)))
           elneo-verifications)
  (remhash profile elneo-recovery-states)
  ;; The nudge guard too: a fresh login on the same profile name must
  ;; be able to ask again (defvar docstring).
  (setq elneo-client--verification-nudged
        (assoc-delete-all profile elneo-client--verification-nudged
                          #'equal))
  ;; elneo-verify.el is an autoloaded UI layer; when it has not been
  ;; loaded yet, its buffer table is unbound and `gethash' would
  ;; signal (see the room-buffers block above).
  (when (bound-and-true-p elneo-verify--buffers)
    (when-let* ((verify (gethash profile elneo-verify--buffers))
                ((buffer-live-p verify)))
      (kill-buffer verify))))

;;;###autoload
(defun elneo-forget-profile (profile &optional no-confirm)
  "Fully clean up after PROFILE.
Logs out server-side (when the daemon is live), stops the daemon,
deletes its per-profile data directory (`session.json' and the
sqlite state/crypto stores) and forgets the registration.  The
profile can be re-added later with `elneo-add-account'; trust,
verification and decrypted history do not carry over (use
`elneo-recover-keys' with the saved recovery key to restore room
keys on the new session).

This removes PROFILE's presence from THIS machine only.  The
Matrix account itself is not deactivated: it keeps its rooms and
whatever other sessions still exist.

With NO-CONFIRM non-nil, skip the confirmation prompt (used by
`elneo-forget-all-profiles', which confirms once for all)."
  (interactive (progn (elneo--accounts-load)
                      (list (completing-read
                             "Profile: "
                             (mapcar #'car elneo-accounts)
                             nil t))))
  (elneo--accounts-load)
  ;; The prompt must fit an 80-column minibuffer: if `(yes or no)' is
  ;; pushed off the visible edge, the command looks hung while it is
  ;; really waiting at the confirmation.
  (when (or no-confirm
            (yes-or-no-p (format "Forget profile %s (logout, stop \
daemon, delete data)? "
                                 profile)))
    (if (elneo-server-live-p profile)
        (elneo--forget-after-logout profile)
      ;; No live daemon: its logout command is unreachable.  The
      ;; token in the data dir's session.json would otherwise stay
      ;; valid on the homeserver for good — invalidate it directly
      ;; before the directory (and with it the token) is gone.
      (elneo--forget-logout-session-file profile)
      (elneo--forget-teardown profile))))

(defun elneo--forget-after-logout (profile)
  "Gate PROFILE's teardown on the daemon's logout ack.
The logout is one HTTP round trip; a fire-and-forget call plus the
immediate stop killed the daemon before the homeserver ever
revoked the token — forgotten profiles kept living on the server
as unrevoked devices with a live session.  Wait for the ack
(bounded: a wedged daemon must not wedge the forget), warn when
the confirmation is missing, then tear down."
  (let ((done nil) (ok nil) (note nil))
    (elneo-server--call profile '((@type . "logout"))
                        (lambda (_p event)
                          (setq done t
                                ok (alist-get '@ok event nil nil #'equal)
                                note (unless ok
                                       (elneo-server--error-string event)))))
    (let ((deadline (+ (float-time) 10)))
      (while (and (not done) (< (float-time) deadline))
        (accept-process-output (elneo-server--get-process profile) 1)))
    (if ok
        (message "Matrix [%s] logged out server-side" profile)
      (message "Matrix [%s] logout not confirmed (%s) — the homeserver \
may still know this device"
               profile
               (or note "timed out")))
    (elneo--forget-teardown profile)))

(defun elneo--forget-logout-session-file (profile)
  "Best-effort server logout for PROFILE's stored-but-offline session.
The daemon is not running, so its `logout' command is unreachable;
read the access token straight from the data dir's session.json and
invalidate it on the remembered homeserver.  Anything missing, or
any failure here, only degrades to the old behavior and never
blocks the teardown that follows."
  (let* ((file (expand-file-name "session.json"
                                 (elneo--daemon-data-dir profile)))
         (session (when (file-exists-p file)
                    (ignore-errors (json-read-file file))))
         (token (alist-get 'access_token (alist-get 'tokens session))))
    (when (and (stringp token) (not (string-empty-p token)))
      (let ((homeserver (plist-get
                         (alist-get profile elneo-accounts nil nil #'equal)
                         :homeserver)))
        (cond
         ((not (stringp homeserver))
          (message "Matrix [%s]: no homeserver remembered — its device \
was not logged out" profile))
         (t
          (require 'url)
          (message "Matrix [%s]: logging the stored session out on \
%s..." profile homeserver)
          (let ((url-request-method "POST")
                (url-request-extra-headers
                 (list (cons "Authorization" (concat "Bearer " token))))
                (url-request-data "{}"))
            (with-timeout (10
                           (message "Matrix [%s] stale-session logout \
timed out" profile))
              (with-current-buffer
                  (url-retrieve-synchronously
                   (concat homeserver "/_matrix/client/v3/logout"))
                (let ((status (progn (goto-char (point-min))
                                     (buffer-substring
                                      (point-min)
                                      (line-beginning-position 2)))))
                  (kill-buffer)
                  ;; Spec-wise logout answers 200 or 401; both mean no
                  ;; live token is left over.
                  (cond
                   ((string-match-p "HTTP/[0-9.]+ 401" status)
                    (message "Matrix [%s] stored session was already \
logged out" profile))
                   ((string-match-p "HTTP/[0-9.]+ 2[0-9][0-9]" status)
                    (message "Matrix [%s] logged out server-side" profile))
                   (t
                    (message "Matrix [%s] stale-session logout failed: %s"
                             profile
                             (string-trim status))))))))))))))

(defun elneo--forget-teardown (profile)
  "The machine-side half of forgetting PROFILE.
Runs after the logout is as sure as it can be: daemon stopped, the
per-profile data directory deleted and the registration dropped."
  (elneo-server-stop profile)
  (ignore-errors
    (delete-directory (elneo--daemon-data-dir profile) 'recursive))
  (setq elneo-accounts (assoc-delete-all profile elneo-accounts #'equal))
  ;; Emacs-side state for the profile: rooms (announced :removed),
  ;; open room buffers, pending verification flows, recovery state.
  (elneo--profile-local-cleanup profile)
  (elneo--accounts-save)
  (message "Matrix [%s] forgotten" profile))

;;;###autoload
(defun elneo-forget-all-profiles ()
  "Run `elneo-forget-profile' for every registered profile.
Asks for confirmation once, for all profiles — each profile is
logged out (when its daemon is live), its daemon stopped and its
data directory deleted, with progress reported per profile."
  (interactive)
  (elneo--accounts-load)
  (if (null elneo-accounts)
      (message "No Matrix profiles registered")
    (when (yes-or-no-p (format "Forget all %d profiles (logout, stop \
daemons, delete data)? "
                               (length elneo-accounts)))
      (dolist (profile (mapcar #'car elneo-accounts))
        (elneo-forget-profile profile 'no-confirm)))))

;;; Entry point

;;;###autoload
(defun elneo-start ()
  "Bring all registered Matrix accounts online and show the room bar."
  (interactive)
  (elneo--accounts-load)
  (if (null elneo-accounts)
      (progn
        (message "No Matrix accounts registered")
        (call-interactively #'elneo-add-account))
    (dolist (profile (mapcar #'car elneo-accounts))
      (elneo-client--activate profile))
    ;; UI layers load at runtime to avoid load cycles.
    (require 'elneo-room-bar)
    (require 'elneo-verify)
    (elneo-room-bar-show)))

;;; Wire API for the UI layers

(defun elneo-send-message (profile room-id body callback
                                   &optional formatted-body reply-to
                                   replaces mentions room-mention
                                   thread-root)
  "Send BODY to PROFILE's ROOM-ID.
With FORMATTED-BODY (an `org.matrix.custom.html' string), send it
alongside; plain BODY is the fallback for clients that ignore it.
With REPLY-TO (an event id), send it as a reply to that event.
With REPLACES (an event id), send it as an edit of that event — text
only; REPLY-TO and REPLACES are mutually exclusive (the Matrix
relation slot carries only one), and so are REPLACES and
THREAD-ROOT.
With THREAD-ROOT (an event id, MSC3440), send it as a thread reply
under that root; REPLY-TO then rides as the in-thread reply target
(a genuine reply, rendered as a quote on thread-capable clients).
With MENTIONS (a list of user id strings), attach an `m.mentions'
block (MSC3952): receivers' mention-aware alerts fire for those
users.  With ROOM-MENTION non-nil, the block sets @room — everyone
in the room alerts.  CALLBACK (PROFILE RESPONSE-EVENT) is called
once with the `updateSendResult' response; check `@ok'."
  (elneo-server--call profile
                      `((@type . "sendMessage")
                        (room_id . ,room-id)
                        (body . ,body)
                        ,@(when formatted-body `((formatted_body . ,formatted-body)))
                        ,@(when reply-to `((reply_to . ,reply-to)))
                        ,@(when replaces `((replaces . ,replaces)))
                        ,@(when (and thread-root (not replaces))
                            `((thread_root . ,thread-root)))
                        ,@(when (and mentions (not (zerop (length mentions))))
                            `((mentions . ,(vconcat mentions))))
                        ,@(when room-mention `((room_mentions . t))))
                      callback))

(defun elneo-redact-message (profile room-id event-id callback &optional reason)
  "Redact (delete) EVENT-ID in PROFILE's ROOM-ID.
REASON is an optional human-readable explanation.  CALLBACK (PROFILE
RESPONSE-EVENT) is called once with the `updateSendResult' response;
the display update arrives via `elneo-redaction-update-hook'."
  (elneo-server--call profile
                      `((@type . "redactMessage")
                        (room_id . ,room-id)
                        (event_id . ,event-id)
                        ,@(when reason `((reason . ,reason))))
                      callback))

(defun elneo-send-reaction (profile room-id event-id key callback &optional remove)
  "React to EVENT-ID in PROFILE's ROOM-ID with KEY (usually an emoji).
With REMOVE non-nil, toggle the reaction off instead: every own
reaction event with that key is redacted.  Idempotent — removing a
key you never reacted with still succeeds.  CALLBACK (PROFILE
RESPONSE-EVENT) is called once with the `updateSendResult' response;
the reaction-line display updates via `elneo-reactions-update-hook'."
  (elneo-server--call profile
                      `((@type . "sendReaction")
                        (room_id . ,room-id)
                        (event_id . ,event-id)
                        (key . ,key)
                        ,@(when remove `((remove . t))))
                      callback))

(defun elneo-send-pin (profile room-id event-id unpin callback)
  "Pin EVENT-ID in PROFILE's ROOM-ID, or unpin it (UNPIN non-nil).
The daemon toggles on the room's `m.room.pinned_events' list, and
the plain @ok answer carries nothing to render — the resulting
list arrives in a summary echo, as `pinned_events' on the record
(protocol 22)."
  (elneo-server--call profile
                      `((@type . "pinMessage")
                        (room_id . ,room-id)
                        (event_id . ,event-id)
                        ,@(when unpin '((unpin . t))))
                      callback))

(defun elneo-poll-create (profile room-id question options callback
                                  &optional disclosed max-selections)
  "Create a poll in PROFILE's ROOM-ID.
QUESTION is the poll's question string; OPTIONS is a list of 2..20
answer strings (the daemon derives the opaque answer ids).  With
DISCLOSED non-nil the results are visible to everyone while the
poll runs; undisclosed polls (the default) hide them until the
poll ends.  MAX-SELECTIONS is how many answers one vote may pick
(default 1).  CALLBACK (PROFILE RESPONSE-EVENT) is called once, on
`@ok' or on the failure.  Live updates ride
`elneo-poll-update-hook'."
  (elneo-server--call profile
                      `((@type . "pollCreate")
                        (room_id . ,room-id)
                        (question . ,question)
                        (options . ,(vconcat options))
                        ,@(when disclosed `((disclosed . t)))
                        ,@(when (and max-selections (> max-selections 1))
                            `((max_selections . ,max-selections))))
                      callback))

(defun elneo-poll-vote (profile room-id event-id selections callback)
  "Cast PROFILE's vote in the poll EVENT-ID of ROOM-ID.
SELECTIONS is the list of answer ids to mark — the full selection
set (max_selections at most); an empty list removes the own vote.
CALLBACK (PROFILE RESPONSE-EVENT) is called once, on `@ok' or on
the failure.  The aggregate refresh arrives through
`elneo-poll-update-hook'."
  (elneo-server--call profile
                      `((@type . "pollVote")
                        (room_id . ,room-id)
                        (event_id . ,event-id)
                        (selections . ,(vconcat selections)))
                      callback))

(defun elneo-poll-end (profile room-id event-id callback)
  "End the poll EVENT-ID in PROFILE's ROOM-ID.
The homeserver enforces the sender's rights (the poll's creator by
default).  CALLBACK (PROFILE RESPONSE-EVENT) is called once, on
`@ok' or on the failure.  The results-open aggregate arrives
through `elneo-poll-update-hook'."
  (elneo-server--call profile
                      `((@type . "pollEnd")
                        (room_id . ,room-id)
                        (event_id . ,event-id))
                      callback))

;;; Image scaling

;; Images can be scaled on the way out, on an explicit request: a C-u
;; prefix on a send command prompts once for a size (`elneo--scale-read')
;; and every image that command sends gets rescaled before the upload.
;; The actual resizing is left to external tools — Emacs cannot write a
;; scaled image file — probed per operation: magick (ImageMagick 7),
;; convert (6), gm convert (GraphicsMagick), sips (macOS).  Scaling is
;; an optimization: it never refuses a send, the worst case is the
;; original going out with a message.
;;
;; The size gate below is a second entry into the same scaler, on
;; size.  It runs at the caller level (draft RET, dired), never in
;; the async upload plumbing, which must not prompt.

(defcustom elneo-image-oversize-limit 1048576   ; 1 MiB
  "Byte size an outgoing image may not exceed without a second look.
0 disables.  Costs one `file-attributes' stat per image — on Tramp,
a remote round trip.  A client-side courtesy, not the daemon's
20 MiB upload limit; scaling stays best-effort."
  :type 'natnum
  :group 'elneo)

(defcustom elneo-image-oversize-action 'ask
  "What sending an image over `elneo-image-oversize-limit' does.
`ask' (the default) asks; a no opens the scale prompt, whose empty
answer means the original after all (C-u semantics).  `scale' opens
the prompt directly; `send' never asks.  The spec sticks to every
image of the send, like a C-u spec."
  :type '(choice (const :tag "Ask; no offers scaling" ask)
                 (const :tag "Ask for a scale spec" scale)
                 (const :tag "Send without asking" send))
  :group 'elneo)

(defvar elneo--scale-last nil
  "Raw last answer typed at the C-u image-scale prompt.
Held verbatim so the next prompt can pre-fill it; parsed through
`elneo--scale-parse' only at use.")

(defvar elneo--scale-history nil
  "Minibuffer history of the image-scale prompt (M-p).")

(defun elneo--image-file-p (path)
  "Non-nil when PATH's extension suggests an image.
The whitelist matches what the daemon will make of the file: mime
is guessed from the extension.  Lives in elneo-client, not
elneo-room, because the scaler runs at the upload choke point here
and elneo-client is the lower layer (elneo-room requires this
file, never the other way)."
  (and (string-match "\\.[a-zA-Z0-9]+\\'" path)
       (let ((ext (downcase (substring path (1+ (match-beginning 0))))))
         (member ext '("png" "jpg" "jpeg" "gif" "webp" "bmp" "tiff" "svg"
                       "ico" "heic" "avif")))))

(defun elneo--scale-parse (input)
  "Parse a scale prompt answer INPUT.
Empty (the user emptied the pre-filled last answer) returns nil —
send the original.  \"1920\" and \"1920px\" (suffix case-insensitive)
return (px . N): fit within N pixels on the longest edge, by
shrinking only — an image already within N goes out untouched.
\"50%\" returns (percent . P): P percent of the original dimensions,
up or down, and the aspect ratio is kept.  Anything else signals
`user-error'; the empty case is the only answer meaning \"no
scaling\", because C-u is an explicit request and a typo silently
sending originals would quietly contradict it."
  (setq input (string-trim input))
  (let ((bad (lambda ()
               (user-error "Matrix: bad image scale %S (use e.g. 1920, 1920px or 50%%)"
                           input))))
    (cond ((equal input "") nil)
          ((string-match "\\`\\([0-9]+\\)\\(?:px\\|PX\\)\\'" input)
           (elneo--scale-number (match-string 1 input) bad))
          ((string-match "\\`\\([0-9]+\\)\\'" input)
           (elneo--scale-number (match-string 1 input) bad))
          ((string-match "\\`\\([0-9]+\\)%\\'" input)
           (let ((p (string-to-number (match-string 1 input))))
             (if (> p 0) (cons 'percent p) (funcall bad))))
          (t (funcall bad)))))

(defun elneo--scale-number (digits bad)
  "The (px . N) spec for DIGITS, via BAD on zero.
BAD is the shared invalid-answer thunk of `elneo--scale-parse'."
  (let ((n (string-to-number digits)))
    (if (> n 0) (cons 'px n) (funcall bad))))

(defun elneo--scale-read ()
  "Ask for a scale specification, nil meaning send the original.
The input starts pre-filled with the last answer
(`elneo--scale-last'), so repeating a size is RET and \"this time
the original\" is emptying it first — both one keystroke away.
Every answer, the empty one included, feeds
`elneo--scale-history', so M-p reaches previous sizes across empty
answers."
  (let ((answer (read-string
                 "Scale image (e.g. 1920, 1920px, 50%; empty sends the original): "
                 (or elneo--scale-last "") 'elneo--scale-history)))
    (setq elneo--scale-last answer)
    (elneo--scale-parse answer)))

(defun elneo--scale-when-images (files)
  "The scale answer for a batch of FILES, nil without prompting.
The C-u prefix is a request to scale, not a scale value, so this
prompts — once for the whole batch, whatever its size — but only
when at least one file in FILES is an image by extension: the
scaler ignores non-images anyway, and an answer asked for an
imageless batch would have nothing to stick to."
  (let ((hit nil))
    (while (and files (not (setq hit (elneo--image-file-p (car files)))))
      (setq files (cdr files)))
    (when hit (elneo--scale-read))))

(defun elneo--size-string (bytes)
  "BYTES as a human-readable size."
  (cond ((>= bytes 1073741824) (format "%.1f GiB" (/ bytes 1073741824.0)))
        ((>= bytes 1048576)    (format "%.1f MiB" (/ bytes 1048576.0)))
        ((>= bytes 1024)       (format "%.1f KiB" (/ bytes 1024.0)))
        (t (format "%d B" bytes))))

(defun elneo--scale-oversize-files (files)
  "The oversize images among FILES, each as (PATH . SIZE), in order.
Limit 0 answers nil; unstatable files are skipped — the upload path
reports a missing file itself."
  (let ((limit elneo-image-oversize-limit)
        (oversize nil))
    (when (> limit 0)
      (dolist (file files)
        (when (elneo--image-file-p file)
          (let ((size (file-attribute-size (file-attributes file))))
            (when (and size (> size limit))
              (push (cons file size) oversize))))))
    (nreverse oversize)))

(defun elneo--scale-oversize-answer (files)
  "The scale spec for the oversize images among FILES, or nil —
nothing oversize, limit 0, action `send', or the user stood by
the originals.  One prompt per send, like
`elneo--scale-when-images'; the spec sticks to every image."
  (when-let* ((oversize (elneo--scale-oversize-files files)))
    (let ((limit (elneo--size-string elneo-image-oversize-limit)))
      (cond
       ((eq elneo-image-oversize-action 'send) nil)
       ((eq elneo-image-oversize-action 'scale)
        (if (cdr oversize)
            (message "Matrix: %d images over %s — the scale prompt follows"
                     (length oversize) limit)
          (message "Matrix: %s is %s — over the %s image limit"
                   (file-name-nondirectory (caar oversize))
                   (elneo--size-string (cdar oversize)) limit))
        (elneo--scale-read))
       (t
        (let ((largest (apply #'max (mapcar #'cdr oversize))))
          (if (y-or-n-p
               (if (cdr oversize)
                   (format "%d images over the limit, largest %s — \
send them all anyway? "
                           (length oversize) (elneo--size-string largest))
                 (format "%s is %s — send it anyway? "
                         (file-name-nondirectory (caar oversize))
                         (elneo--size-string (cdar oversize)))))
              nil
            (elneo--scale-read))))))))

(defun elneo--scale-backend ()
  "The resize backend present here, or nil.
Order: magick (ImageMagick 7), convert (6), gm convert
(GraphicsMagick), sips (macOS).  Probed with `executable-find' on
every scale, not cached — a cache would outlive an install or a
PATH change mid-session, and the probe is one PATH search."
  (cond ((executable-find "magick") 'magick)
        ((executable-find "convert") 'convert)
        ((executable-find "gm") 'gm)
        ((executable-find "sips") 'sips)))

(defun elneo--scale-geometry (spec)
  "The ImageMagick-family geometry string for SPEC.
(px . N) becomes \"NxN>\": fit inside an N-by-N box, shrink only —
the `>' is belt and braces, the caller normally decides the no-op
from a dimension probe (and a no-op through the tool would
re-encode the file it is supposed to leave alone).  (percent . P)
stays \"P%\": proportional, up or down."
  (if (eq (car spec) 'percent)
      (format "%d%%" (cdr spec))
    (format "%dx%d>" (cdr spec) (cdr spec))))

(defun elneo--scale-argv (backend in out spec)
  "The full argv scaling IN to OUT with BACKEND per SPEC.
A percent spec never reaches sips here — it needs the current pixel
size to become a resample target, which `elneo--scale-image' works
out first.  gm gets no `-auto-orient': its argument order and
EXIF-orientation support differ; sips cannot auto-orient at all, so
on sips-only machines a rotated-EXIF photo keeps its rotation."
  (cond ((eq backend 'magick)
         (list "magick" in "-auto-orient" "-resize"
               (elneo--scale-geometry spec) out))
        ((eq backend 'convert)
         (list "convert" in "-auto-orient" "-resize"
               (elneo--scale-geometry spec) out))
        ((eq backend 'gm)
         (list "gm" "convert" in "-resize"
               (elneo--scale-geometry spec) out))
        ((eq backend 'sips)
         (list "sips" "--resampleHeightWidthMax"
               (number-to-string (cdr spec)) in "--out" out))))

(defun elneo--scale-size (backend path)
  "The (WIDTH . HEIGHT) of PATH per BACKEND's own tools, or nil.
Sips prints `pixelWidth: 3024' lines, the identify family prints
`3024 4032'; two `re-search-forward's read both shapes.  The probe
decides the shrink-only rule of a pixel spec (only a tool that
knows the size can refuse a no-op) and sips' percent-to-pixel
conversion."
  (with-temp-buffer
    (let ((ok (condition-case _err
                  (cond ((eq backend 'sips)
                         (= 0 (call-process "sips" nil t nil
                                            "-g" "pixelWidth"
                                            "-g" "pixelHeight" path)))
                        ((memq backend '(magick convert))
                         (= 0 (call-process (symbol-name backend) nil t nil
                                            "identify" "-format" "%w %h"
                                            path)))
                        ((eq backend 'gm)
                         (= 0 (call-process "gm" nil t nil
                                            "identify" "-format" "%w %h"
                                            path))))
                (file-error nil)))
          w h)
      (when ok
        ;; The tool's output arrives where point is (after whatever a
        ;; probe like `identify' prints first); search from the start
        ;; of it, not from wherever the call left point.
        (goto-char (point-min))
        (setq w (and (re-search-forward "[0-9]+" nil t)
                     (string-to-number (match-string 0)))
              h (and (re-search-forward "[0-9]+" nil t)
                     (string-to-number (match-string 0)))))
      (when (and w h (> w 0) (> h 0)) (cons w h)))))

(defun elneo--scale-target (spec size)
  "The pixel target to run sips with for SPEC and SIZE, or nil.
SIZE is (WIDTH . HEIGHT).  A pixel spec answers only when the
longest edge of SIZE exceeds N — sips would resample to exactly N
and upsample otherwise.  A percentage answers with the longest edge
times P/100, rounded; going up is the point of a percentage."
  (if (eq (car spec) 'percent)
      (max 1 (round (* (max (car size) (cdr size)) (cdr spec) 0.01)))
    (when (> (max (car size) (cdr size)) (cdr spec))
      (cdr spec))))

(defun elneo--scale-run (argv)
  "Run the resize ARGV, non-nil on a zero exit.
Output is discarded; a program that cannot be run at all counts as
a failure like a non-zero exit does."
  (condition-case err
      (zerop (apply #'call-process (car argv) nil nil nil (cdr argv)))
    (file-error
     (message "Matrix: scaling failed — %s" (error-message-string err))
     nil)))

(defun elneo--scale-image (path spec)
  "Return \(SCALED . CLEANUP) scaling PATH per scale SPEC.
(SCALED . nil), the original expanded and untouched, whenever
nothing was scaled: SPEC nil, PATH not an existing file, not an
image by extension, svg (vector — its delivery size is its vector
rasterization, pixel dimensions are not what it weighs), gif on a
sips-only machine (a resample would flatten the animation to its
first frame; the ImageMagick family scales every frame), no
backend installed, or any probe or run failure.  Every degenerate
branch says why in a message and falls back to the original — a
scale request is an optimization, never worth losing the
attachment over.

A scaled copy goes into a fresh temporary directory
(`make-temp-file \"elneo-scale-\" t') under the original basename:
the daemon derives the message's name and mime type from the
extension of the path it reads.  CLEANUP deletes that directory and
must run once the send has settled, like the staging cleanup it
chains with — `elneo-room--send-upload' runs the pair.  A
Tramp-remote PATH is copied into the directory first — the resize
tools speak no Tramp — which also makes the staging pass-through
see a local file, for one remote round-trip either way."
  (setq path (expand-file-name path))
  (if (or (not spec) (not (file-exists-p path))
          (not (elneo--image-file-p path)))
      (cons path nil)
    (let* ((ext (downcase (substring path
                                     (1+ (string-match
                                          "\\.[a-zA-Z0-9]+\\'" path)))))
           (backend (elneo--scale-backend))
           (name (file-name-nondirectory path)))
      (cond
       ((string= ext "svg")
        (message "Matrix: %s is vector — scaling it changes nothing, sending as-is" name)
        (cons path nil))
       ((and (string= ext "gif") (eq backend 'sips))
        (message "Matrix: sips would flatten %s — sending the animation as-is" name)
        (cons path nil))
       ((null backend)
        (message "Matrix: no magick/convert/gm/sips found — sending %s unscaled" name)
        (cons path nil))
       (t (elneo--scale-image-1 name backend path spec))))))

(defun elneo--scale-image-1 (name backend path spec)
  "The actual resize behind `elneo--scale-image'.
NAME is the (original) basename to keep; BACKEND and SPEC as there.
The dimension probe (`elneo--scale-size') decides everything it
can: sips needs a pixel target it can only compute from a probed
size, and a probed image already within a pixel spec's N is a
no-op — running the tool anyway would re-encode the \"original\"
it is meant to leave alone.  When the tool cannot tell the size,
the ImageMagick family still gets its `>' geometry — shrink-only,
best effort, at the cost of a re-encode on a rare no-op — while
sips is refused, since it cannot be told not to upsample."
  (let* ((dir (make-temp-file "elneo-scale-" t))
         (out (expand-file-name name dir))
         (in path))
    (when (file-remote-p path)
      (setq in (expand-file-name name dir))
      (copy-file path in t))
    (let* ((size (elneo--scale-size backend in))
           (target (and size (elneo--scale-target spec size))))
      (cond
       ;; sips only understands a pixel target: without a probed size
       ;; it has none, and it cannot be told not to upsample.
       ((and (eq backend 'sips) (null size))
        (delete-directory dir t)
        (message "Matrix: cannot determine the size of %s — sending unscaled" name)
        (cons path nil))
       ;; The shrink-only rule, wherever the probe worked: a pixel
       ;; spec for an image already within its N scales nothing.
       ((and size (null target))
        (delete-directory dir t)
        (message "Matrix: %s is already within %dpx — sending as-is" name (cdr spec))
        (cons path nil))
       (t
        (let ((runspec (if (eq backend 'sips) (cons 'px target) spec)))
          (let ((argv (elneo--scale-argv backend in out runspec)))
            (if (and (elneo--scale-run argv) (file-exists-p out))
                (cons out (lambda () (delete-directory dir t)))
              (ignore-errors (delete-directory dir t))
              (message "Matrix: scaling %s failed — sending the original" name)
              (cons path nil)))))))))

(defun elneo--upload-stage (path)
  "Return \(STAGED . CLEANUP): a local path the daemon can read for PATH.
Local files pass through (expanded, no cleanup thunk).  A file
behind Tramp would reach the daemon as a remote path it cannot open,
so it is copied — `copy-file' rides the same Tramp connection as
everything else — into a fresh temporary directory keeping the
basename: the daemon derives the message's name and mime type from
it.  CLEANUP is then a thunk deleting that directory; call it once
the send has settled, success or failure.  A failed send leaves the
original where it was, so a retry just stages again.  No user
interaction beyond the credentials Tramp already has; if the daemon
never answers, the copy waits for the system's /tmp cleanup."
  (setq path (expand-file-name path))
  (if (not (file-remote-p path))
      (cons path nil)
    (let* ((dir (make-temp-file "elneo-upload-" t))
           (copy (expand-file-name
                  (file-name-nondirectory (file-local-name path)) dir)))
      (message "Matrix: staging %s from remote..." (file-name-nondirectory copy))
      (copy-file path copy t t)
      (cons copy (lambda () (delete-directory dir t))))))

(defun elneo-room--send-upload
    (profile room-id kind path callback &optional thread-root scale mime info-alist)
  "Shared upload body of `elneo-room-image' and `elneo-room-file'.
KIND is the daemon command (\"sendImage\"/\"sendFile\").  PATH is
scaled per SCALE (`elneo--scale-image', a no-op unless a spec was
given and the file is a scalable image) and staged through
`elneo--upload-stage'; every temporary copy the two steps made is
deleted once CALLBACK has run, success or failure, even when it
signals.  THREAD-ROOT, when non-nil, threads the attachment into
that Matrix thread (MSC3440).  MIME, when non-nil, rides the
command as its `mime' key — the content type the daemon sends the
attachment as, instead of its filename guess (a re-send that knows
its source's mimetype).  INFO-ALIST, when non-nil, rides as the
`info' object — the source event's media metadata (`width',
`height', `duration', `size'), re-sent with the attachment."
  (let* ((scaled (elneo--scale-image path scale))
         (path (car scaled))
         (staged (elneo--upload-stage path))
         ;; Either step can hold a cleanup; both live as long as the
         ;; send, and the scale copy is deleted with the staged one.
         (cleanups (delq nil (list (cdr scaled) (cdr staged))))
         (callback (if cleanups
                       (let ((once callback))
                         (lambda (profile event)
                           (unwind-protect
                               (funcall once profile event)
                             (dolist (cleanup cleanups)
                               (ignore-errors (funcall cleanup))))))
                     callback)))
    (elneo-server--call profile
                        `((@type . ,kind)
                          (room_id . ,room-id)
                          (path . ,(car staged))
                          ,@(when thread-root
                              `((thread_root . ,thread-root)))
                          ,@(when mime `((mime . ,mime)))
                          ,@(when info-alist `((info . ,info-alist))))
                        callback)))

(defun elneo-room-image (profile room-id path callback &optional thread-root scale mime info-alist)
  "Upload the image file at PATH and send it to PROFILE's ROOM-ID.
The daemon reads the file and guesses the mime type from the
extension.  A Tramp-remote path is staged to a local temporary copy
first (the daemon reads local paths only), which is removed once
CALLBACK has run.  CALLBACK (PROFILE RESPONSE-EVENT) is called once
with the `updateSendResult' response; check `@ok'.  THREAD-ROOT
threads the attachment into that thread.  SCALE, non-nil
(`elneo--scale-image' spec), rescales PATH before the upload; a
non-image path under a given SCALE, as with a `[file:' tag, is
sent as-is, matching the dired send.  MIME and INFO-ALIST name the
content type and media metadata to send (`elneo-room--send-upload'
docstring); a forward passes both from its source event."
  (elneo-room--send-upload
   profile room-id "sendImage" path callback thread-root scale mime info-alist))

(defun elneo-room-file (profile room-id path callback &optional thread-root scale mime info-alist)
  "Upload the file at PATH and send it to PROFILE's ROOM-ID.
Same as `elneo-room-image' for any content: the daemon guesses the
mime type from the extension, and the message type follows it
(video lands as `m.video', unknown types as `m.file') — unless MIME
names the content type, which a forward passes.  A Tramp-remote
path is staged to a local temporary copy first — the daemon reads
local paths only — which is removed once CALLBACK has run.
THREAD-ROOT threads the attachment into that thread.  SCALE,
non-nil (`elneo--scale-image' spec), rescales PATH before the
upload when PATH is an image by extension — dired and image-dired
sends come through here — and leaves other files untouched.
INFO-ALIST re-sends the source event's media metadata, a forward
passes it (`elneo-room--send-upload' docstring)."
  (elneo-room--send-upload
   profile room-id "sendFile" path callback thread-root scale mime info-alist))

(defun elneo-room-messages (profile room-id limit from callback &optional filter)
  "Fetch a page of history for PROFILE's ROOM-ID.
CALLBACK (PROFILE RESPONSE-EVENT) receives an `updateRoomMessages'
event (with `@ok'), or an error response.  FROM is the pagination
token from a previous call, or nil for the newest page.  LIMIT
defaults to 50 on the daemon side.  FILTER \"image\" narrows the
page to pictures — `m.image' and the `m.sticker' entries riding
the same media shape (the image viewer's photo walk); the
response's END token continues that filtered walk and must never
feed normal room-buffer pagination."
  (elneo-server--call profile
                      `((@type . "getRoomMessages")
                        (room_id . ,room-id)
                        ,@(when limit `((limit . ,limit)))
                        ,@(when from `((from . ,from)))
                        ,@(when filter `((filter . ,filter))))
                      callback))

(defun elneo-room-thread-messages (profile room-id thread-root limit from callback)
  "Fetch a page of a thread for PROFILE's ROOM-ID.
THREAD-ROOT is the thread's root event id (MSC3440).  CALLBACK
(PROFILE RESPONSE-EVENT) receives an `updateThreadMessages' event
(with `@ok'; its ROOT is the root's own entry, END the token for
the next older page), or an error response.  FROM is the
pagination token from a previous call, or nil for the newest
page.  LIMIT defaults to 50 on the daemon side."
  (elneo-server--call profile
                      `((@type . "getThreadMessages")
                        (room_id . ,room-id)
                        (thread_root . ,thread-root)
                        ,@(when limit `((limit . ,limit)))
                        ,@(when from `((from . ,from))))
                      callback))

(defun elneo-room-receipts (profile room-id callback)
  "Seed other members' public read receipts for PROFILE's ROOM-ID.
CALLBACK (PROFILE RESPONSE-EVENT) receives an `updateReadReceipts'
event (with `@ok'), or an error response.  The receipts are the
seed from the SDK store; live updates continue via
`elneo-read-receipts-update-hook'."
  (elneo-server--call profile
                      `((@type . "getRoomReceipts")
                        (room_id . ,room-id))
                      callback))

(defun elneo-room-members (profile room-id callback)
  "Fetch the member roster of PROFILE's ROOM-ID.
CALLBACK (PROFILE RESPONSE-EVENT) receives an `updateRoomMembers'
event (with `@ok'), listing user ids and display names (nil name
for members who never set one).  @-mention completion's raw
material."
  (elneo-server--call profile
                      `((@type . "getRoomMembers")
                        (room_id . ,room-id))
                      callback))

(defun elneo-accept-invite (profile room-id callback)
  "Accept PROFILE's pending invite to ROOM-ID and join the room.
CALLBACK (PROFILE RESPONSE-EVENT) receives the plain ack; the
seeded `updateRoom' event runs ahead of it, so by the ack the
room's registry record is already the joined one (open it from the
callback).  On failure — no pending invite, join refused — @ok is
nil and @error says why."
  (elneo-server--call profile
                      `((@type . "acceptInvite")
                        (room_id . ,room-id))
                      callback))

(defun elneo-decline-invite (profile room-id callback)
  "Decline PROFILE's pending invite to ROOM-ID (leave and forget it).
CALLBACK (PROFILE RESPONSE-EVENT) receives the plain ack; the
`updateRoomGone' event removing the room's row runs ahead of it."
  (elneo-server--call profile
                      `((@type . "declineInvite")
                        (room_id . ,room-id))
                      callback))

(defun elneo-join-room (profile room-id-or-alias callback &optional via)
  "Voluntarily join PROFILE's ROOM-ID-OR-ALIAS (a room id or #alias).
CALLBACK (PROFILE RESPONSE-EVENT) receives `roomJoined' with the
resolved `room_id' (an alias join gets no id back otherwise); a
seeded `updateRoom' runs ahead of it.  VIA, a list of server names,
rides along as the join's `server_name' entries — the route a remote
room with no resolvable alias needs, which the space page rows and
matrix.to links carry."
  (elneo-server--call profile
                      `((@type . "joinRoom")
                        (room_id_or_alias . ,room-id-or-alias)
                        ,@(when via (list (cons 'via via))))
                      callback))

(defun elneo-space-hierarchy (profile room-id from callback)
  "Fetch one level of PROFILE's ROOM-ID (a space)'s offered rooms.
CALLBACK (PROFILE RESPONSE-EVENT) receives `roomHierarchy' with
`rooms' — one hierarchy-room alist per offered room (room_id, name,
topic, canonical_alias, avatar_url, num_joined_members, join_rule,
room_type, joined) — and `next_batch' when more pages follow.  FROM,
nil on the first call, continues where that token left off.  Spaces
the session is joined to answer; a not-joined space answers only
when it is world-readable (`@ok: nil' then, `@error' the
homeserver's)."
  (elneo-server--call profile
                      `((@type . "getRoomHierarchy")
                        (room_id . ,room-id)
                        ,@(when from `((from . ,from))))
                      callback))

(defun elneo-room-spaces (profile room-id callback)
  "Fetch the parent spaces PROFILE's ROOM-ID declares (`m.space.parent').
CALLBACK (PROFILE RESPONSE-EVENT) receives `roomSpaces' with
`spaces': the parent rooms' hierarchy-room alists, metadata only
where the session is joined to the parent.  ROOM-ID itself must be
joined — the room's own state is where the declarations live."
  (elneo-server--call profile
                      `((@type . "getRoomSpaces")
                        (room_id . ,room-id))
                      callback))

(defun elneo-leave-room (profile room-id callback)
  "Leave PROFILE's ROOM-ID.
CALLBACK (PROFILE RESPONSE-EVENT) receives the plain ack; the
`updateRoomGone' event runs ahead of it.  Rejoining later works by
voluntary join id; the room is forgotten only by an explicit forget."
  (elneo-server--call profile
                      `((@type . "leaveRoom")
                        (room_id . ,room-id))
                      callback))

(defun elneo-forget-room (profile room-id callback)
  "Forget PROFILE's left ROOM-ID (the server refuses if still joined).
CALLBACK (PROFILE RESPONSE-EVENT) receives the plain ack; an
`updateRoomGone' event runs ahead of it."
  (elneo-server--call profile
                      `((@type . "forgetRoom")
                        (room_id . ,room-id))
                      callback))

(defun elneo-invite-user (profile room-id user-id callback)
  "Invite USER-ID to PROFILE's ROOM-ID.
CALLBACK (PROFILE RESPONSE-EVENT) receives the plain ack; the
member roster refreshes via `updateRoomMembers' independently."
  (elneo-server--call profile
                      `((@type . "inviteUser")
                        (room_id . ,room-id)
                        (user_id . ,user-id))
                      callback))

(defun elneo-kick-user (profile room-id user-id reason callback)
  "Kick USER-ID from PROFILE's ROOM-ID; REASON may be nil.
CALLBACK (PROFILE RESPONSE-EVENT) receives the plain ack."
  (elneo-server--call profile
                      `((@type . "kickUser")
                        (room_id . ,room-id)
                        (user_id . ,user-id)
                        ,@(when reason `((reason . ,reason))))
                      callback))

(defun elneo-ban-user (profile room-id user-id reason callback)
  "Ban USER-ID from PROFILE's ROOM-ID; REASON may be nil.
Bans outlast this session — undo with `elneo-unban-user'.
CALLBACK (PROFILE RESPONSE-EVENT) receives the plain ack."
  (elneo-server--call profile
                      `((@type . "banUser")
                        (room_id . ,room-id)
                        (user_id . ,user-id)
                        ,@(when reason `((reason . ,reason))))
                      callback))

(defun elneo-unban-user (profile room-id user-id callback)
  "Lift PROFILE's ban on USER-ID in ROOM-ID (they may rejoin).
CALLBACK (PROFILE RESPONSE-EVENT) receives the plain ack."
  (elneo-server--call profile
                      `((@type . "unbanUser")
                        (room_id . ,room-id)
                        (user_id . ,user-id))
                      callback))

(defun elneo-set-room-name (profile room-id name callback)
  "Set PROFILE's ROOM-ID's display NAME.
CALLBACK (PROFILE RESPONSE-EVENT) receives the plain ack; the
room's name updates everywhere via the seeded `updateRoom' event."
  (elneo-server--call profile
                      `((@type . "setRoomName")
                        (room_id . ,room-id)
                        (name . ,name))
                      callback))

(defun elneo-set-room-topic (profile room-id topic callback)
  "Set PROFILE's ROOM-ID's TOPIC (nil or empty clears it).
CALLBACK (PROFILE RESPONSE-EVENT) receives the plain ack; the
topic updates via the room's `C-c ?' view and `updateRoom' event."
  (elneo-server--call profile
                      `((@type . "setRoomTopic")
                        (room_id . ,room-id)
                        (topic . ,(or topic "")))
                      callback))

(defun elneo-set-notification-mode (profile room-id mode callback)
  "Set PROFILE's ROOM-ID's notification MODE.
MODE is a daemon wire word: \"all_messages\",
\"mentions_and_keywords\" or \"mute\".  Push rules are this
account's alone, so no permission gates the call.  CALLBACK
\(PROFILE RESPONSE-EVENT) receives the plain ack; the new mode
shows in the room's `C-c ?' view with the next sync's push-rules
echo."
  (elneo-server--call profile
                      `((@type . "setNotificationMode")
                        (room_id . ,room-id)
                        (mode . ,mode))
                      callback))

(defun elneo-set-room-avatar (profile room-id path callback)
  "Set PROFILE's ROOM-ID's avatar to the image at PATH.
PATH nil removes the avatar.  The mime type is the daemon's to
guess, from PATH; the upload and the state change land in one
server call.  PATH is expanded first, like the account avatar's
(`elneo-set-avatar').
CALLBACK (PROFILE RESPONSE-EVENT) receives the plain ack; the
avatar updates where it shows via the room's `updateRoom' event."
  (elneo-server--call
   profile
   `((@type . "setRoomAvatar")
     (room_id . ,room-id)
     ,@(when path `((local_path . ,(expand-file-name path)))))
   callback))

(defun elneo-room-permissions (profile room-id callback)
  "Fetch this session's permissions in PROFILE's ROOM-ID.
CALLBACK (PROFILE RESPONSE-EVENT) receives a `roomPermissions'
event — the own power level with the per-action can-X gates the
UI checks before offering an edit."
  (elneo-server--call profile
                      `((@type . "roomPermissions")
                        (room_id . ,room-id))
                      callback))

(defun elneo-create-room (profile props callback)
  "Create a new room on PROFILE and join it, per PROPS.
PROPS is a plist; recognized keys: `:name' (display name), `:alias'
(alias local part — \"ops\" means #ops:SERVER on this account's
homeserver), `:public' (directory-listed; nil is private),
`:topic', `:invites' (list of user ids to invite at creation),
`:is-direct' (mark the invites as DM; the daemon files the room
under m.direct — same on the invite side, when the account
accepts a direct-flagged invite) and `:encrypted' (initial
m.room.encryption state; a direct message is encrypted by
default on every modern client).  A malformed invite id fails
the whole creation.
CALLBACK (PROFILE RESPONSE-EVENT) receives `roomJoined' with the
new room's `room_id' — the seeded `updateRoom' runs ahead of it."
  (elneo-server--call
   profile
   `((@type . "createRoom")
     ,@(when (plist-get props :name) `((name . ,(plist-get props :name))))
     ,@(when (plist-get props :alias) `((alias . ,(plist-get props :alias))))
     ,@(when (plist-get props :public) `((public . t)))
     ,@(when (plist-get props :topic) `((topic . ,(plist-get props :topic))))
     ,@(when (plist-get props :invites) `((invites . ,(plist-get props :invites))))
     ,@(when (plist-get props :is-direct) `((is_direct . t)))
     ,@(when (plist-get props :encrypted) `((encrypted . t))))
   callback))

(defun elneo-set-display-name (profile name callback)
  "Set this account's display NAME on PROFILE.
NAME nil clears the display name (the wire sends no field, and the
CS API treats that as unset).  The change reaches the room buffers
through the room member events.
CALLBACK (PROFILE RESPONSE-EVENT) receives the ack."
  (elneo-server--call
   profile
   (append '((@type . "setDisplayName"))
           (when name `((name . ,name))))
   callback))

(defun elneo-set-own-room-display-name (profile room-id name callback)
  "Set this account's display name AS ROOM-ID on PROFILE sees it.
The room-scoped counterpart of `elneo-set-display-name': the
`m.room.member' state displayname, which overrides the profile both
for this room's rendering and for everyone else in it.  NAME nil
clears it (the wire sends no field — the room falls back to the
profile display name).  The change reaches the buffers through the
room member events, like the global change.
CALLBACK (PROFILE RESPONSE-EVENT) receives the ack."
  (elneo-server--call
   profile
   `((@type . "setOwnDisplayName")
     (room_id . ,room-id)
     ,@(when name `((name . ,name))))
   callback))

(defun elneo-set-avatar (profile path callback)
  "Upload PATH as this account's avatar on PROFILE, or clear it.
PATH nil clears the avatar.  The daemon uploads and sets in one
server call, the mime type guessed from PATH.  PATH is expanded
(`~'/relative) first — `read-file-name' can return it unexpanded,
and the daemon reads local paths only, like the uploads
(`elneo-room--send-upload') do through `elneo--upload-stage'.
CALLBACK (PROFILE RESPONSE-EVENT) receives the ack."
  (elneo-server--call
   profile
   (append '((@type . "setAvatar"))
           (when path `((local_path . ,(expand-file-name path)))))
   callback))

(defun elneo-account-profile (profile callback)
  "Fetch PROFILE's own profile from the homeserver.
CALLBACK (PROFILE RESPONSE-EVENT) receives a `profile' event — the
global display name and avatar mxc, either possibly unset (its
field then stays off the wire).  The account page's facts."
  (elneo-server--call profile '((@type . "getProfile")) callback))

(defun elneo-download-media (profile source format callback &optional filename)
  "Download SOURCE into PROFILE's on-disk media cache.
SOURCE is a serialized ruma MediaSource (as shipped in a message
entry's `media'), FORMAT is \"thumb\" or \"file\".  FILENAME is the
original file name, used to pick the cache file's extension.
CALLBACK (PROFILE RESPONSE-EVENT) receives an `updateMediaFile'
event with the cache `path' — immediately when the file is already
cached, otherwise once the download finishes.  Progress
notifications arrive via `elneo-download-update-hook'."
  (elneo-server--call
   profile
   `((@type . "downloadMedia")
     (source . ,source)
     (format . ,format)
     ,@(when filename `((filename . ,filename))))
   callback))

(defvar elneo-client--avatar-cache (make-hash-table :test 'equal)
  "Avatar MXC URL -> downloaded cache path, or `failed'.
Shared by every surface (room bar, room buffers): the same avatar
renders in many places and needs fetching once.")

(defvar elneo-client--avatar-pending (make-hash-table :test 'equal)
  "Avatar MXC URL -> callbacks of fetchers joined to the in-flight download.")

(defun elneo-client--avatar-file (mxc)
  "Cache path of avatar MXC, or nil when absent or failed."
  (let ((path (and mxc (gethash mxc elneo-client--avatar-cache))))
    (unless (eq path 'failed) path)))

(defun elneo-client--avatar-image (file &optional cols)
  "Image spec for a downloaded avatar FILE, capped near COLS columns.
nil when FILE is nil or this Emacs cannot display images (terminal
frame, batch): callers fall back to the mxc string or the initial
cell.  The bar's sender avatars and the avatar facts (room
overview, account page) build their cells from this, so one
download renders identically everywhere."
  (when (and file (display-graphic-p))
    (create-image
     file nil nil
     :max-height (default-font-height)
     :max-width (* (or cols 2) (default-font-width)))))

(defun elneo-client-fetch-avatar (profile mxc callback)
  "Fetch avatar MXC through PROFILE's daemon as a thumbnail.
CALLBACK (PROFILE RESPONSE-EVENT) runs once, immediately when the
file is already cached, otherwise when the download lands; concurrent
fetchers of the same MXC are joined into one download and all run.
A failed download marks the MXC `failed' in the cache — callers fall
back to the initial placeholder and do not re-request it forever.
An empty mxc is treated the same way without a fetch: bridges leave
`avatar_url' as \"\" in place of dropping it, and an empty key must
never reach the daemon — its cache path would be the thumb directory
itself, which then answers as already-cached media."
  (let ((cached (elneo-client--avatar-file mxc)))
    (cond
     ((and (stringp mxc) (string-empty-p mxc))
      (puthash mxc 'failed elneo-client--avatar-cache))
     (cached
      (funcall callback profile `((@ok . t) (path . ,cached))))
     (t
      (let ((pending (gethash mxc elneo-client--avatar-pending)))
        (if pending
            ;; Join the in-flight download instead of starting a second
            ;; one for the same avatar.
            (puthash mxc (nconc pending (list callback))
                     elneo-client--avatar-pending)
          (puthash mxc (list callback) elneo-client--avatar-pending)
          (let ((key mxc))
            ;; A failure to even start (daemon down, process gone) must
            ;; not signal into the caller: the avatar render path runs
            ;; inside message rendering.  Drop the pending entry so the
            ;; next render retries, and surface it as a message.
            (condition-case err
                (elneo-download-media
                 profile `((url . ,mxc)) "thumb"
                 (lambda (cb-profile event)
                   ;; The cache entry exists before the callbacks run:
                   ;; they re-render (open room buffers, open account
                   ;; and room overviews) and must see the freshly
                   ;; downloaded path, not a cache that still misses.
                   ;; The callback list leaves the table before it is
                   ;; pruned — the callbacks run below.
                   (let ((cbs (gethash key elneo-client--avatar-pending)))
                     (remhash key elneo-client--avatar-pending)
                     ;; Only a real file counts as arrived: a directory
                     ;; path (e.g. the degenerate empty-mxc key) must
                     ;; be marked failed, not rendered.
                     (if (and (alist-get '@ok event nil nil #'equal)
                              (let ((path (alist-get 'path event)))
                                (and (stringp path)
                                     (not (string-empty-p path))
                                     (not (file-directory-p path)))))
                         (puthash key (alist-get 'path event)
                                  elneo-client--avatar-cache)
                       (puthash key 'failed elneo-client--avatar-cache))
                     (dolist (cb cbs)
                       (funcall cb cb-profile event)))))
              (error
               (remhash key elneo-client--avatar-pending)
               (message "Matrix avatar fetch failed: %s" (cdr err)))))))))))

;;;###autoload
(defun elneo-avatars-flush-cache ()
  "Forget every downloaded avatar path and in-flight join.
The files stay in the daemon's on-disk media cache — this only drops
the Emacs-side MXC-to-path table, e.g. after a daemon restart that
moved the cache."
  (interactive)
  (clrhash elneo-client--avatar-cache)
  (clrhash elneo-client--avatar-pending))

(defcustom elneo-send-public-read-receipts nil
  "When non-nil, marking a room read also sends a public m.read receipt.
Public receipts are federated: every room member can see exactly
which messages you have read.  They are off by default — the
private receipt and fully-read marker (always sent) keep your own
unread counters and your other devices in sync without telling
anyone anything."
  :group 'elneo
  :type '(boolean))

(defun elneo-room-mark-read (profile room-id &optional event-id)
  "Mark PROFILE's ROOM-ID as read up to EVENT-ID (or the latest event).
On success, also runs
`elneo-own-read-receipt-update-hook' locally: this device just
moved the account's read state, so consumers need not wait for the
homeserver's echo (which may lag a long-poll window, or be
suppressed when the mark is a repeat of the current position)."
  (let ((target event-id))
    (elneo-server--call profile
                        `((@type . "markRoomRead")
                          (room_id . ,room-id)
                          ,@(when event-id `((event_id . ,event-id)))
                          (public_receipt . ,elneo-send-public-read-receipts))
                        (lambda (profile event)
                          (when (alist-get '@ok event nil nil #'equal)
                            (run-hook-with-args
                             'elneo-own-read-receipt-update-hook
                             (list :profile profile
                                   :room-id room-id
                                   :event-id target
                                   :ts nil)))))))

(defun elneo-get-devices (profile callback)
  "List PROFILE's account devices.
CALLBACK (PROFILE RESPONSE-EVENT) receives an `updateDevices'
response; the device list is in `devices'."
  (elneo-server--call profile '((@type . "getDevices")) callback))

(defun elneo-delete-device (profile device-id password callback)
  "Log DEVICE-ID out of PROFILE's account, asking PASSWORD when needed.
The homeserver usually demands user-interactive auth on device
deletion and the daemon drives it internally; when PASSWORD is nil
and the server insists, the daemon only reports that one is needed
and the caller re-sends.  CALLBACK (PROFILE RESPONSE-EVENT) gets
the ack — @ok true on success.  The password lives only in this
local framed protocol, never on the wire to the homeserver beyond
the SAS-authenticated login channel it belongs to."
  (elneo-server--call profile
                      `((@type . "deleteDevice")
                        (device_id . ,device-id)
                        ,@(when password `((password . ,password))))
                      callback))

(defun elneo-verification-request-device (profile user-id device-id)
  "Start a verification flow with USER-ID's DEVICE-ID for PROFILE.
Progress arrives via `elneo-verification-update-hook'."
  (elneo-server--call profile
                      `((@type . "verifyDevice")
                        (user_id . ,user-id)
                        (device_id . ,device-id))
                      nil))

(defun elneo-verification-accept (profile flow-id)
  "Accept the incoming verification request FLOW-ID for PROFILE."
  (elneo-server--call profile
                      `((@type . "acceptVerification") (flow_id . ,flow-id))
                      nil))

(defun elneo-verification-start-sas (profile flow-id)
  "Move verification request FLOW-ID for PROFILE into the SAS flow."
  (elneo-server--call profile
                      `((@type . "startSas") (flow_id . ,flow-id))
                      nil))

(defun elneo-verification-confirm (profile flow-id)
  "Confirm the short auth string of FLOW-ID for PROFILE (emojis match)."
  (elneo-server--call profile
                      `((@type . "confirmSas") (flow_id . ,flow-id))
                      nil))

(defun elneo-verification-cancel (profile flow-id)
  "Cancel verification request FLOW-ID for PROFILE."
  (elneo-server--call profile
                      `((@type . "cancelVerification") (flow_id . ,flow-id))
                      nil))

(defun elneo-verification-enable-recovery (profile callback)
  "Enable secret storage and key backup for PROFILE.
CALLBACK (PROFILE RESPONSE-EVENT) receives a `recoveryEnabled'
response whose `recovery_key' must be shown to the user exactly
once — it is never stored anywhere."
  (elneo-server--call profile '((@type . "enableRecovery")) callback))

(defun elneo-verification-rotate-recovery-key (profile callback &optional old-key)
  "Rotate PROFILE's secret storage under a fresh recovery key.
The callback receives the `recoveryEnabled' response (new key shown
once).  OLD-KEY, when non-nil, names the current recovery key: the
daemon then imports from it before rotating — a session the store
distrusts cannot fill a fresh store on its own."
  (if old-key
      (elneo-server--call profile
                          `((@type . "rotateRecoveryKey") (old_key . ,old-key))
                          callback)
    (elneo-server--call profile '((@type . "rotateRecoveryKey")) callback)))

(defun elneo-verification-disable-recovery (profile callback)
  "Disable PROFILE's key backup and secret storage.
The server-side backup is deleted as part of this; the callback
receives the ok/nok and an `updateRecoveryState' event reports the
new state.  Nothing re-enables it behind the user's back."
  (elneo-server--call profile '((@type . "disableRecovery")) callback))

(defun elneo-verification-recover-keys (profile key &optional callback)
  "Restore PROFILE's secrets from a previously saved recovery KEY."
  (elneo-server--call profile
                      `((@type . "recoverRecoveryKey") (key . ,key))
                      callback))

(provide 'elneo-client)
;;; elneo-client.el ends here
