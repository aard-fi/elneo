;;; elneo-org.el --- org-mode links into elneo rooms, events, people -*- lexical-binding: t; -*-

;; Org-mode integration, the org-bug shape: link types registered at
;; file load, `org-store-link' support from room buffers, capture
;; works where links do.  Three link types:
;;
;;   elneo-room:profile/!room:server   — open the room
;;   elneo-event:profile/!room:server/$event — open and jump to it
;;   elneo-user:profile/@user:server   — start or open the direct chat
;;
;; Storing (C-c l) inside an elneo room buffer yields the event link
;; when point sits on a message line, the room link otherwise.  A
;; person link stores through `elneo-org-store-user-link', which
;; completes over the current room's roster.  `org-capture' picks all
;; of these up through the stored link like any other org link.

(require 'org)
(require 'elneo-client)

(declare-function elneo-room--open "elneo-room" (room &optional stay-put))
(declare-function elneo-room-jump-to-event "elneo-room"
                  (profile room-id event-id &optional stay-put))
(declare-function elneo-room--event-id-at "elneo-room" (pos))
(declare-function elneo-room--roster-entries "elneo-room" (&optional keep-own))
(declare-function elneo-start-dm "elneo-room" (profile user-id))
(declare-function elneo-server-live-p "elneo-server" (profile))

(defun elneo-org--link-split (path label)
  "Split PATH at the first slash into (PROFILE REST) or error.
LABEL names the link kind for the user-facing error: profiles are
plain names and never carry a slash, so the split is safe."
  (let ((slash (string-search "/" path)))
    (if (and slash (> slash 0))
        (list (substring path 0 slash) (substring path (1+ slash)))
      (user-error "Matrix %s link %S needs a profile/name path" label path))))

(defun elneo-org--label (profile room-id)
  "Human label of PROFILE's ROOM-ID: display name, room id fallback."
  (let ((record (elneo-room-get profile room-id)))
    (or (and record (plist-get record :display-name)) room-id)))

(defun elneo-org-follow-room (path)
  "Open the elneo-room link PATH (profile/room-id)."
  (pcase-let ((`(,profile ,room-id) (elneo-org--link-split path "room")))
    (unless (elneo-server-live-p profile)
      (user-error "Matrix daemon not running for profile %s" profile))
    (unless (elneo-room-get profile room-id)
      (user-error "Matrix: no room record for %s — the room appears once the daemon syncs" room-id))
    (elneo-room--open (elneo-room-get profile room-id))))

(defun elneo-org-follow-event (path)
  "Jump to the elneo-event link PATH (profile/room-id/$event-id).
The room id carries no slash, so everything after the room id's
colon-free segment up to the second slash is the event id — the
event id itself may contain further slashes (servers have issued
base64 with `/' in the past) and is taken verbatim."
  (pcase-let* ((`(,profile ,rest) (elneo-org--link-split path "event"))
               (slash (string-search "/" rest)))
    (unless slash
      (user-error "Matrix event link %S needs room-id/event-id" path))
    (elneo-room-jump-to-event profile (substring rest 0 slash)
                              (substring rest (1+ slash)))))

(defun elneo-org-follow-user (path)
  "Open the direct chat with the elneo-user link PATH (profile/mxid)."
  (pcase-let ((`(,profile ,user-id) (elneo-org--link-split path "user")))
    (unless (elneo-server-live-p profile)
      (user-error "Matrix daemon not running for profile %s" profile))
    (elneo-start-dm profile user-id)))

(defun elneo-org-store-link (&optional _interactive?)
  "Store a link to the elneo room or message under point.
Room buffers only: on a message line the link names the event
(`elneo-event'), otherwise the room (`elneo-room').  Returns non-nil
so `org-store-link' takes the stored link.  Registered as the
`elneo-room' link's `:store' parameter — org 9.7 calls parameters,
not the old hook variable."
  (when (derived-mode-p 'elneo-room-mode)
    (let* ((profile elneo-room--profile)
           (room-id elneo-room--room-id)
           ;; Point on the image glyph one past the line still counts
           ;; as "on the message", like the media commands.
           (event-id (or (elneo-room--event-id-at (point))
                         (and (> (point) (point-min))
                              (elneo-room--event-id-at (1- (point))))))
           (seen (and event-id (gethash event-id elneo-room--seen))))
      (if seen
          (org-link-store-props
           :type "elneo-event"
           :link (format "elneo-event:%s/%s/%s" profile room-id event-id)
           :description (format "%s: %s"
                                (or (plist-get seen :sender-name)
                                    (plist-get seen :sender) "?")
                                (elneo-org--body-snippet
                                 (plist-get seen :body))))
        (org-link-store-props
         :type "elneo-room"
         :link (format "elneo-room:%s/%s" profile room-id)
         :description (elneo-org--label profile room-id)))
      t)))

(defun elneo-org--body-snippet (body)
  "Single-line snippet of a message BODY for link descriptions."
  (let ((text (string-trim
               (replace-regexp-in-string "\n" " " (or body "")))))
    (if (> (length text) 48)
        (concat (substring text 0 45) "…")
      text)))

(defun elneo-org--choose-user ()
  "Pick a person for an elneo-user link, as (PROFILE . USER-ID).
In a room buffer the pick completes over that room's roster (the
room's own user stays in the list — links to the self-DM are
legitimate); elsewhere a profile is picked and the id typed."
  (if (derived-mode-p 'elneo-room-mode)
      ;; The roster answers only for room buffers, so this works in
      ;; one as-is; a fresh buffer may not have fetched it yet.
      (let* ((candidates (mapcar
                          (lambda (entry) (cons (car entry) (cadr entry)))
                          (elneo-room--roster-entries 'keep-own)))
             (choice (completing-read "Matrix person: " candidates nil t))
             ;; A named member's label puts the id in the trailing
             ;; parens; a nameless member's label is the bare id.
             (user-id (if (string-match "(\\(@.*\\))$" choice)
                          (match-string 1 choice)
                        choice)))
        (cons elneo-room--profile user-id))
    (elneo--accounts-load)
    (let ((profile (completing-read "Profile: " (mapcar #'car elneo-accounts)
                                    nil t)))
      (cons profile
            (read-string "Direct message user id (@user:server): ")))))

;;;###autoload
(defun elneo-org-store-user-link ()
  "Store a link to a person from the current room's roster.
The pick completes over `elneo-room--members'; outside a room
buffer, type the id.  The link's `elneo-user' opens (or starts) the
direct chat with that person."
  (interactive)
  (let ((picked (elneo-org--choose-user)))
    (elneo-org--store-user-link (car picked) (cdr picked))))

(defun elneo-org--store-user-link (profile user-id)
  "Register the elneo-user link for PROFILE's USER-ID with org."
  (org-link-store-props
   :type "elneo-user"
   :link (format "elneo-user:%s/%s" profile user-id)
   :description user-id))

(defun elneo-org-complete-room ()
  "Completion for an elneo-room link: pick a room, get its link.
Returns the full link string — org's `:complete' contract has the
return become the link directly.  The description elneo proposes
rides the `:insert-description' link parameter."
  (let* ((room (elneo-completing-read-room))
         (profile (plist-get room :profile))
         (room-id (plist-get room :room-id)))
    (format "elneo-room:%s/%s" profile room-id)))

(defun elneo-org-complete-user ()
  "Completion for an elneo-user link: pick a person, get its link.
In a room buffer the pick completes over that room's roster;
elsewhere the profile and id are typed.
`elneo-org--choose-user' does the picking."
  (pcase-let ((`(,profile . ,user-id) (elneo-org--choose-user)))
    (format "elneo-user:%s/%s" profile user-id)))

(defun elneo-org-insert-description-room (link &optional _default)
  "The description elneo proposes for the elneo-room LINK."
  (pcase-let ((`(,profile ,room-id) (elneo-org--link-split
                                     (substring link (length "elneo-room:")) "room")))
    (elneo-org--label profile room-id)))

(defun elneo-org-insert-description-user (link &optional _default)
  "The description elneo proposes for the elneo-user LINK.
The id is what the link says — a DM room record is not keyed by
the user id, so no display name is cheaply reachable here."
  (pcase-let ((`(_ ,user-id) (elneo-org--link-split
                              (substring link (length "elneo-user:")) "user")))
    user-id))

(org-link-set-parameters
 "elneo-room"
 :follow #'elneo-org-follow-room
 :complete #'elneo-org-complete-room
 :insert-description #'elneo-org-insert-description-room
 ;; Store support rides one link parameter: org 9.7 and later no
 ;; longer read the `org-store-link-functions' hook variable — it
 ;; collects the `:store' parameters instead, and would call a store
 ;; function registered on every type once per type.
 :store #'elneo-org-store-link)
(org-link-set-parameters "elneo-event" :follow #'elneo-org-follow-event)
(org-link-set-parameters
 "elneo-user"
 :follow #'elneo-org-follow-user
 :complete #'elneo-org-complete-user
 :insert-description #'elneo-org-insert-description-user)
;; The hook still works on org 9.6 and older, where the `:store'
;; parameter was never read; on newer org it is a no-op variable.
(add-hook 'org-store-link-functions #'elneo-org-store-link)

;;;###autoload
(defun elneo-org-install ()
  "Load elneo's org-mode integration and say so.
The link registration happens at file load (the org-bug way); this
is the entry point for `with-eval-after-load' on \\='org."
  (interactive)
  (require 'elneo-org)
  (message "Matrix org links installed"))

(provide 'elneo-org)
;;; elneo-org.el ends here