;;; elneo-alert.el --- Route incoming Matrix messages into alert.el -*- lexical-binding: t -*-

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;;; Commentary:

;; Opt-in bridge between live Matrix messages and the alert.el
;; ecosystem: each incoming message from another user produces one
;; `alert' call, carrying :category 'matrix, the live room buffer (for
;; status-based escalation) and a :data plist with the jump context
;; (:profile, :room-id, :event-id).  alert.el passes :data through to
;; style notifiers untouched, so an inbox consumer can implement
;; RET-jump-to-message via `elneo-room-jump-to-event' without any
;; advice — unlike telega, which calls alert deep inside its own code,
;; the Matrix side controls the call site.
;;
;; Enable with (require 'elneo-alert); the `alert' dependency stays
;; out of the core files.

;;; Code:

(require 'alert)
(require 'elneo-client)

(declare-function elneo-room--buffer-for "elneo-room" (profile room-id))
(declare-function elneo-room-bar-visible-p "elneo-room-bar" ())
(declare-function elneo-room-jump-to-event "elneo-room"
                  (profile room-id event-id))
(declare-function elneo-server--user-id "elneo-server" (profile))

(defgroup elneo-alert nil
  "Alerting for incoming Matrix messages."
  :group 'elneo
  :prefix "elneo-alert-")

(defcustom elneo-alert-enable t
  "Master switch for Matrix alerting.
Nil suppresses every alert (the hook consumer stays installed)."
  :type 'boolean
  :group 'elneo-alert)

;; Kept as an alias so existing configs keep working: the canonical
;; variable lives in elneo-client.el next to `elneo-room-muted-p',
;; the one predicate every UI uses.
(defvaralias 'elneo-alert-muted-modes 'elneo-muted-notification-modes)

(defcustom elneo-alert-skip-when 'buffer-or-bar
  "When a message you can already see should not alert.
nil always alerts (subject to the other filters).  `buffer' skips
the alert when the room's buffer is displayed in any window on
screen.  `buffer-or-bar', the default, also skips it when the room
bar is on screen: its unread badges and activity reordering
already surface every message, so the alert (and any flash the
alert style adds on top) would be pure noise.  Visibility follows
live windows only — under eyebrowse, a bar or room parked in
another perspective counts as not visible."
  :type '(choice (const :tag "Always alert (except own/muted)" nil)
                 (const :tag "Skip when the room buffer is displayed" buffer)
                 (const :tag "Skip when the room buffer or the room bar is displayed"
                        buffer-or-bar))
  :group 'elneo-alert)

(defvar elneo-alert--seen (make-hash-table :test 'equal)
  "Event ids that already went through the alert pipeline.
The daemon re-sends live messages when a sync gap closes (e.g.
after reconnecting), which would otherwise double-alert.  Cleared
wholesale when large: replays trail the original by seconds.")

(defun elneo-alert--event-fresh-p (event-id)
  "Non-nil when EVENT-ID has not alerted yet, recording it now."
  (when (> (hash-table-count elneo-alert--seen) 500)
    (clrhash elneo-alert--seen))
  (if (gethash event-id elneo-alert--seen)
      nil
    (puthash event-id t elneo-alert--seen)
    t))

(defun elneo-alert--bar-visible-p ()
  "Non-nil when the room bar is on screen.
Nil when elneo-room-bar is not loaded — an unloaded bar cannot
be visible."
  (and (fboundp 'elneo-room-bar-visible-p)
       (elneo-room-bar-visible-p)))

(defun elneo-alert--mentions-me-p (msg)
  "Non-nil when MSG carries an m.mentions block that targets me.
Either it lists this profile's own Matrix user id (MSC3952), or it
sets the @room everyone-flag.  A nil `m.mentions' block — the
overwhelmingly common case — targets no one."
  (let ((mentions (plist-get msg :mentions)))
    (and mentions
         (or (eq (plist-get mentions :room) t)
             (and (plist-get mentions :user-ids)
                  (member (elneo-server--user-id (plist-get msg :profile))
                          (plist-get mentions :user-ids)))))))

(defun elneo-alert--room-buffer (profile room-id)
  "The live room buffer for PROFILE's ROOM-ID, or nil.
Nil also when elneo-room is not yet loaded: this hook consumer can
fire before any room buffer (or the room module) exists, and there
is no visibility to pass on — the same reason the bar lookup below
is fboundp-guarded."
  (and (fboundp 'elneo-room--buffer-for)
       (elneo-room--buffer-for profile room-id)))

(defun elneo-alert--should-alert-p (msg room)
  "Non-nil when MSG in ROOM should produce an alert.
Own messages never alert; neither — per `elneo-alert-skip-when' —
does anything you can already see on screen.  Muted rooms stay
quiet unless the sender explicitly mentioned me: an @-mention or
@room is the signal to override the mute (this is exactly what the
\"mentions and keywords\" and \"mute\" modes mean, and the daemon
ships `m.mentions' so the client honors it).
A room with no record yet (a brand-new room whose first message
races its summary) or a nil notification mode (the daemon's
\"unset\", i.e. the server default of all messages) alerts: both
mean \"ordinary messages ping\", which is what `elneo-room-muted-p'
already tests for."
  (let* ((buffer (and room
                      (elneo-alert--room-buffer
                       (plist-get msg :profile) (plist-get msg :room-id)))))
    (and (not (plist-get msg :is-own))
         (or (elneo-alert--mentions-me-p msg)
             (not (elneo-room-muted-p room)))
         (not (and elneo-alert-skip-when
                   (or (and (memq elneo-alert-skip-when '(buffer buffer-or-bar))
                            (elneo-buffer-visible-p buffer))
                       (and (eq elneo-alert-skip-when 'buffer-or-bar)
                            (elneo-alert--bar-visible-p))))))))

(defun elneo-alert--message-text (msg)
  "The alert text for MSG: sender and body, or a media-type label."
  (let ((body (plist-get msg :body))
        (msgtype (or (plist-get msg :msgtype) "m.text"))
        (who (or (plist-get msg :sender-name) (plist-get msg :sender) "?")))
    (cond ((and body (> (length body) 0))
           (format "%s: %s" who body))
          ((string-prefix-p "m.image" msgtype) (format "%s sent an image" who))
          ((string-prefix-p "m.sticker" msgtype) (format "%s sent a sticker" who))
          ((string-prefix-p "m.audio" msgtype) (format "%s sent an audio message" who))
          ((string-prefix-p "m.video" msgtype) (format "%s sent a video" who))
          ((string-prefix-p "m.file" msgtype) (format "%s sent a file" who))
          (t (format "%s sent a message" who)))))

(defun elneo-alert-notify (msg room)
  "Send one new-message MSG for ROOM through `alert'.
The alert carries :category \\='matrix, the live room buffer as
:buffer (only for status-based escalation — notifiers that want
jump context use :data) and a :data plist with the profile, room id
and event id.  This is the single choke point for Matrix alerting,
the direct analogue of `telega-notifications--chat-msg0'."
  (let* ((profile (plist-get msg :profile))
         (room-id (plist-get msg :room-id))
         (buffer (elneo-alert--room-buffer profile room-id)))
    (alert (elneo-alert--message-text msg)
           :title (format "Matrix: %s"
                          (or (plist-get room :display-name) room-id))
           :severity 'normal
           :category 'matrix
           :buffer buffer
           :data (list :profile profile
                       :room-id room-id
                       :event-id (plist-get msg :event-id)))))

(defun elneo-alert--on-new-message (msg)
  "elneo-new-message-hook consumer: filter MSG, notify via `alert'.
A re-sent event id (sync-gap replay) is dropped before filtering,
so it cannot alert — or flash — twice.  Member system lines (\"X
joined the room\", protocol 4) are not messages and never alert."
  (when (and elneo-alert-enable
             (not (equal (plist-get msg :msgtype) "m.member"))
             (elneo-alert--event-fresh-p (plist-get msg :event-id)))
    (let ((room (elneo-room-get (plist-get msg :profile)
                                (plist-get msg :room-id))))
      (when (elneo-alert--should-alert-p msg room)
        (elneo-alert-notify msg room)))))

(add-hook 'elneo-new-message-hook #'elneo-alert--on-new-message)

(provide 'elneo-alert)
;;; elneo-alert.el ends here
