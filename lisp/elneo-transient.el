;;; elneo-transient.el --- Transient menu for the room bar options -*- lexical-binding: t; -*-

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published
;; by the Free Software Foundation; either version 3, or (at your
;; option) any later version.

;;; Commentary:

;; The room bar's header buttons cover the frequent toggles, but a
;; side window only fits so many of them.  This menu exposes every
;; option with its current value and stays open after each choice,
;; so several can be flipped in one visit.
;;
;; Entry point is `elneo-room-bar-options' (in elneo-room-bar.el,
;; which degrades gracefully when transient is not installed): `m'
;; in the bar, `C-c C-b' in a room buffer, or any global binding you
;; like — every setting is global, not buffer-local.

;;; Code:

(require 'transient)
(require 'elneo-room-bar)

(defun elneo-transient--sort-label ()
  "Human label for the current sort order."
  (elneo-room-bar-sort-label elneo-room-bar-sort))

(defun elneo-transient--preview-label ()
  "Human label for the current preview style."
  (pcase elneo-room-bar-preview-style
    ('inline "inline") ('below "second line") ('none "off")
    (_ (symbol-name elneo-room-bar-preview-style))))

(defun elneo-transient--account-label ()
  "Human label for the current account filter."
  (or elneo-room-bar-account-filter "all accounts"))

(defun elneo-transient--dm-label ()
  "Human label for the current DM filter."
  (pcase elneo-room-bar-dm-filter
    ('dm "direct messages only")
    ('rooms "group rooms only")
    (_ "all")))

(defun elneo-transient-set-account (profile)
  "Filter the bar to PROFILE's rooms; \"all\" (or empty input) shows every account."
  (interactive
   (let* ((accounts (elneo-room-bar--account-list))
          (choice (completing-read
                   (format "Show rooms of account (%s): "
                           (or elneo-room-bar-account-filter "all"))
                   (cons "all" accounts))))
     (list choice)))
  (elneo-room-bar-set-account
   (and (not (member profile '("" "all"))) profile)))

(defun elneo-transient-clear-search ()
  "Drop the search filter."
  (interactive)
  (elneo-room-bar-set-search ""))

(defun elneo-transient-toggle-room-avatars ()
  "Toggle the global default for sender avatars, re-rendering open rooms.
This is the default new room buffers follow; buffers with an
explicit per-buffer override (`A' in the room) keep theirs."
  (interactive)
  ;; Lazy require, mirroring the v key in room buffers: elneo-room
  ;; is not needed until the menu is used.
  (require 'elneo-room)
  (elneo-room--set-default-and-redraw 'elneo-room-avatars))

(defun elneo-transient-toggle-trust-marks ()
  "Toggle the global default for trust marks, re-rendering open rooms.
This is the default new room buffers follow; buffers with an
explicit per-buffer override (`T' in the room) keep theirs."
  (interactive)
  ;; Lazy require, mirroring elneo-transient-toggle-room-avatars:
  ;; elneo-room is not needed until the menu is used.
  (require 'elneo-room)
  (elneo-room--set-default-and-redraw 'elneo-room-trust-marks))
;;;###autoload (autoload 'elneo-transient-dispatch "elneo-transient" nil t)
(transient-define-prefix elneo-transient-dispatch ()
  "Room bar options: sorting, display modes, filters."
  [["Sort and layout"
    ("s" (lambda () (format "Sort order: %s" (elneo-transient--sort-label)))
     elneo-room-bar-cycle-sort :transient t)
    ("l" (lambda () (format "Live re-sort on updates: %s"
                            (if elneo-room-bar-live-sort "on" "off")))
     elneo-room-bar-toggle-live-sort :transient t)
    ("g" (lambda () (format "Grouped view: %s"
                            (if elneo-room-bar-grouped "on" "off")))
     elneo-room-bar-toggle-grouped :transient t)
    ("p" (lambda () (format "Message preview: %s"
                            (elneo-transient--preview-label)))
     elneo-room-bar-cycle-preview :transient t)
    ("v" (lambda () (format "Avatar column: %s"
                            (if elneo-room-bar-avatars "on" "off")))
     elneo-room-bar-toggle-avatars :transient t)]
   ["Filter"
    ("a" (lambda () (format "Account filter: %s"
                            (elneo-transient--account-label)))
     elneo-transient-set-account :transient t)
    ("d" (lambda () (format "DM filter: %s"
                            (elneo-transient--dm-label)))
     elneo-room-bar-cycle-dm :transient t)
    ("/" (lambda () (format "Search: %s"
                            (if (equal elneo-room-bar-search "")
                                "(none)"
                              (format "“%s”" elneo-room-bar-search))))
     elneo-room-bar-set-search :transient t)
    ("c" "Clear search" elneo-transient-clear-search :transient t)]
   ["Room buffers"
    ("A" (lambda () (format "Sender avatars: %s"
                            (if elneo-room-avatars "on" "off")))
     elneo-transient-toggle-room-avatars :transient t)
    ("T" (lambda () (format "Trust marks: %s"
                            (if elneo-room-trust-marks "on" "off")))
     elneo-transient-toggle-trust-marks :transient t)]
   ["Bar"
    ("k" (lambda () (format "Mouse click on a room: %s"
                            (pcase elneo-room-bar-click-action
                              ('open "opens it") ('double "opens on double click")
                              (_ "moves point only"))))
     elneo-room-bar-cycle-click-action :transient t)
    ("w" (lambda () (format "Bar shape: %s"
                            (if (and (buffer-live-p elneo-room-bar--buffer)
                                     (with-current-buffer elneo-room-bar--buffer
                                       (eq elneo-room-bar--state 'rail)))
                                "rail" "wide bar")))
     elneo-room-bar-toggle-state :transient t)
    ("r" "Refresh now" elneo-room-bar-refresh-full :transient t)
    ("b" "Toggle the room bar (show/hide)"
     elneo-room-bar-toggle-visibility :transient t)]])

;;;###autoload (autoload 'elneo-room-actions-dispatch "elneo-transient" nil t)
(transient-define-prefix elneo-room-actions-dispatch ()
  "Room actions: manage the current room, or reach another one.
The This-room column runs in a room buffer (the `C-c ?' settings
view shows the same actions on the room facts); the Anywhere
column works without one.  The menu closes after an action — one
visit, one action."
  [["This room"
    ("s" "Settings and notifications" elneo-room-settings)
    ("n" "Set the room's name" elneo-room-set-name)
    ("t" "Set the topic" elneo-room-set-topic)
    ("a" "Set the room's avatar" elneo-room-set-avatar)
    ("m" "Set the notification mode" elneo-room-set-notification-mode)
    ("N" "Set your nick in this room" elneo-room-set-nick)
    ("i" "Invite a user" elneo-room-invite)
    ("k" "Kick a user" elneo-room-kick)
    ("b" "Ban a user" elneo-room-ban)
    ("l" "Leave the room" elneo-room-leave)
    ("f" "Forget the room" elneo-room-forget)]
   ["Anywhere"
    ("j" "Join a room" elneo-room-join)
    ("S" "Browse a space's rooms" elneo-space-browse)
    ("c" "Create a new room" elneo-room-create)
    ("d" "Start a direct message" elneo-start-dm)
    ("p" "Your account (profile and security)" elneo-account)]])

(provide 'elneo-transient)
;;; elneo-transient.el ends here
