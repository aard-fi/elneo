;;; elneo-space.el --- space discovery: browse and join a space's rooms -*- lexical-binding: t; -*-

;;; Commentary:

;; The space page: one interactive buffer per space, listing the rooms
;; the space offers (`getRoomHierarchy', protocol 18) and joining them
;; from the listing.  Spaces exist in the ecosystem for findability —
;; the room bar covers navigating joined rooms; the discovery page
;; covers finding what one is not in yet.  Deliberately narrow: no
;; grouping, no space-tree navigation, no editing of spaces, no
;; knocking.
;;
;; Entry points:
;;   - the room bar: b on a row whose room IS a space;
;;   - M-x elneo-space-browse, which completes over joined spaces;
;;   - a room's overview: its "Spaces" line (the `m.space.parent'
;;     parents); a space shared as a matrix.to link enters through the
;;     join flow in `elneo-room--browse-url-at-point'.
;;
;; A space the session is not joined to answers only when it is
;; world-readable: the page surfaces the homeserver's denial as the
;; listing's error text, never as a silent "this space is empty".

;;; Code:

(require 'cl-lib)
(require 'elneo-client)
(require 'elneo-room-bar)

(declare-function elneo-room-open "elneo-room-bar" (room &optional stay-put))

;;; Guards

(defun elneo-space--protocol-guard (profile)
  "Non-nil when PROFILE's daemon speaks space discovery (protocol 18).
Every entry point guards through this: an older daemon never
answers `getRoomHierarchy', and its silence would render an
otherwise healthy space as empty."
  (let ((version (elneo-server--daemon-protocol profile)))
    (and version (>= version 18))))

;;; Reading the arguments

(defun elneo-space--read-profile ()
  "Read which registered account to browse a space on.
The current room buffer's profile wins, like the join command's
account pick; from elsewhere a completing-read over
`elneo-accounts', with a single account pre-chosen."
  (elneo--accounts-load)
  (unless elneo-accounts
    (user-error "No Matrix profiles registered"))
  (cond
   ((and (bound-and-true-p elneo-room--profile)
         (derived-mode-p 'elneo-room-mode))
    elneo-room--profile)
   (t
    (let ((names (mapcar #'car elneo-accounts)))
      (if (= (length names) 1) (car names)
        (completing-read "Profile: " names nil t))))))

(defun elneo-space--read (profile)
  "Complete-read over PROFILE's joined spaces; return the record.
A not-joined space enters through a shared link or a [Join], not
this picker."
  (let* ((spaces (cl-remove-if-not
                  (lambda (room)
                    (and (equal (plist-get room :profile) profile)
                         (plist-get room :space)
                         (equal (plist-get room :room-state) "joined")))
                  (elneo-rooms-all))))
    (unless spaces
      (user-error "No joined spaces for profile %s" profile))
    (let ((table
           (mapcar (lambda (room)
                     (cons (format "%s: %s" profile
                                   (or (plist-get room :display-name)
                                       (plist-get room :room-id)))
                           room))
                   spaces)))
      (cdr (assoc (completing-read "Matrix space: " (mapcar #'car table) nil t)
                  table #'equal)))))

(defun elneo-space--interactive-args ()
  "The arguments profile and room-id for `elneo-space-browse'.
A space row under the room bar's point wins; otherwise the account
is read (the current room's profile the default) and its joined
spaces completed over."
  (if (and (derived-mode-p 'elneo-room-bar-mode)
           (let ((room (elneo-room-bar--room-at-point)))
             (and room (plist-get room :space))))
      (let ((room (elneo-room-bar--room-at-point)))
        (list (plist-get room :profile) (plist-get room :room-id)))
    (let ((profile (elneo-space--read-profile)))
      (list profile (plist-get (elneo-space--read profile) :room-id)))))

;;; The page

(defvar elneo-space-page-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'elneo-space-page-refresh)
    map)
  "Keys of a space page buffer; `q' comes from `special-mode'.")

(define-derived-mode elneo-space-page-mode special-mode "Matrix Space"
  "Major mode for a space's discovery page.
\\[elneo-space-page-refresh] restarts the listing from the top,
\\[quit-window] buries the page.")

(defvar-local elneo-space-page--profile nil
  "Which account the space page browses through.")

(defvar-local elneo-space-page--room-id nil
  "The space whose page this is (room id).")

(defvar-local elneo-space-page--rooms nil
  "The hierarchy rooms accumulated so far, as received (alists).
Later pages append to these; the space's own row (first row of the
first page, when the homeserver sends it) renders as the page's
header facts, not a room row.")

(defvar-local elneo-space-page--next-batch nil
  "The pagination token of the listing's next page, when any.")

(defvar-local elneo-space-page--arrived nil
  "Non-nil once a listing has landed — an empty listing and a
missing listing read apart through this flag.")

(defvar-local elneo-space-page--error nil
  "The last fetch's failure text, when it failed.")

(defun elneo-space--page-name (name)
  "Buffer name for the space page titled NAME."
  (format "*Matrix Space: %s*" name))

;;;###autoload
(defun elneo-space-browse (profile room-id)
  "Open PROFILE's space ROOM-ID's discovery page.
ROOM-ID need not be in the registry (a link-joined space enters
here by its resolved id): the listing comes from the homeserver.
A space the session does not belong to surfaces the homeserver's
denial in the listing — browsing is only promised for joined
spaces (world-readable ones also answer).
\\[elneo-space-page-refresh] restarts the listing, `q' buries.
Returns the page buffer, like the account page's command does."
  (interactive (elneo-space--interactive-args))
  (unless (elneo-server-live-p profile)
    (user-error "Matrix daemon not running for profile %s" profile))
  (let ((version (elneo-server--daemon-protocol profile)))
    (unless (and version (>= version 18))
      (user-error "Space discovery needs protocol 18 — %s's daemon speaks %s; update elneo-server"
                  profile (or version "nothing"))))
  (elneo-space--browse profile room-id))

(defun elneo-space--browse (profile room-id)
  "Open the page and fetch, version already guarded."
  (let ((page (get-buffer-create (elneo-space--page-name room-id))))
    (with-current-buffer page
      (elneo-space-page-mode)
      (setq elneo-space-page--profile profile
            elneo-space-page--room-id room-id
            elneo-space-page--rooms nil
            elneo-space-page--next-batch nil
            elneo-space-page--arrived nil
            elneo-space-page--error nil)
      ;; An idle skeleton first: the page exists (the command "did
      ;; something"); the listing completes it on arrival.
      (elneo-space-page--render page profile room-id)
      (elneo-space-page--refresh page))
    page))

(defun elneo-space-page-refresh ()
  "Refetch this space page's listing from the top.
`g', like the account page's: the accumulated rooms, the
pagination token and any error stand down for a fresh first page."
  (interactive)
  (elneo-space-page--refresh (current-buffer)))

(defun elneo-space-page--refresh (page)
  "Start PAGE's first-page fetch, standing its state down."
  (when (buffer-live-p page)
    (with-current-buffer page
      (setq elneo-space-page--rooms nil
            elneo-space-page--next-batch nil
            elneo-space-page--arrived nil
            elneo-space-page--error nil)
      (let ((profile elneo-space-page--profile)
            (room-id elneo-space-page--room-id))
        (elneo-space--fetch page profile room-id nil)))))

(defun elneo-space--fetch (page profile room-id from)
  "Fetch PAGE's listing for PROFILE, ROOM-ID, page FROM."
  (elneo-space-hierarchy
   profile room-id from
   (lambda (_p event)
     (if (not (alist-get '@ok event nil nil #'equal))
         (elneo-space-page--failed page profile room-id
                                   (elneo-server--error-string event))
       (elneo-space-page--arrive page profile room-id event)))))

(defun elneo-space-page--failed (page profile room-id text)
  "Record PAGE's failed fetch as its listing's error TEXT."
  (elneo--debug-log "Matrix [%s] space listing: %s" profile text)
  (when (buffer-live-p page)
    (with-current-buffer page
      (setq elneo-space-page--error text)
      (elneo-space-page--render page profile room-id))))

(defun elneo-space-page--arrive (page profile room-id event)
  "Append EVENT's rows to PAGE's listing and re-render it.
Only a reply for the room this page is drops into it — a page
buffer repurposed for another space stays its own."
  (when (and (buffer-live-p page)
             (equal (buffer-local-value 'elneo-space-page--room-id page)
                    room-id))
    (with-current-buffer page
      (setq elneo-space-page--rooms
            (append elneo-space-page--rooms
                    ;; The wire's JSON arrays arrive as vectors; render
                    ;; (cl-remove-if, dolist) wants a proper list.
                    (append (alist-get 'rooms event nil nil #'equal) nil)))
      (setq elneo-space-page--next-batch
            (alist-get 'next_batch event nil nil #'equal))
      (setq elneo-space-page--arrived t)
      (elneo-space-page--render page profile room-id))))

(defun elneo-space-page--render (page profile room-id)
  "Render PAGE from its accumulated listing."
  (when (buffer-live-p page)
    (with-current-buffer page
      (let ((inhibit-read-only t))
        (erase-buffer)
        (elneo-space--render page profile room-id)
        (goto-char (point-min))
        ;; Display only when the page is nowhere on screen — like the
        ;; account page: an arrival re-render must not pop the page
        ;; over the user's reading.
        (unless (get-buffer-window page t)
          (pop-to-buffer page))))))

(defun elneo-space--render (page profile room-id)
  "The page body, into the current buffer.
The space's own row (the homeserver sends the browsed room first)
renders as the header facts; the rest list."
  (let* ((self (cl-find room-id elneo-space-page--rooms
                        :key (lambda (row)
                               (alist-get 'room_id row nil nil #'equal))
                        :test #'equal))
         (rooms (cl-remove-if
                 (lambda (row)
                   (equal (alist-get 'room_id row nil nil #'equal) room-id))
                 elneo-space-page--rooms))
         (name (or (and self (alist-get 'name self nil nil #'equal))
                   (and self (alist-get 'canonical_alias self nil nil #'equal))
                   room-id))
         (topic (and self (alist-get 'topic self nil nil #'equal)))
         (alias (and self (alist-get 'canonical_alias self nil nil #'equal)))
         (members (and self (alist-get 'num_joined_members self nil nil #'equal))))
    ;; The real title, once the listing names it.
    (when (and self (not (equal (buffer-name page) (elneo-space--page-name name))))
      (rename-buffer (elneo-space--page-name name) t))
    (insert (format "Matrix space %s\n\n" name))
    (insert (format "  Room id:       %s\n" room-id))
    (when alias (insert (format "  Alias:         %s\n" alias)))
    (when (stringp topic) (insert (format "  Topic:         %s\n" topic)))
    (when members (insert (format "  Members:       %s\n" members)))
    (cond
     (elneo-space-page--error
      (insert (format "\n\nThe space's rooms are not available: %s\n"
                      elneo-space-page--error))
      (insert "The space answers only when this session is in it or browses it\n")
      (insert "world-readable; an older daemon (before protocol 18) never answers.\n"))
     ((not elneo-space-page--arrived)
      (insert "\nThe room list has not landed yet.\n"))
     ((not rooms)
      (insert "\nThe space offers no rooms.\n"))
     (t
      (insert "\nRooms:\n")
      (dolist (row rooms)
        (elneo-space--render-row page profile room-id row)
        (insert "\n"))))
    (when (and elneo-space-page--next-batch (not elneo-space-page--error))
      (insert "\n  ")
      ;; The token read at render time, not at click time — the page
      ;; re-renders after each arrival anyway.
      (let ((from elneo-space-page--next-batch))
        (insert-text-button "[more]" 'action
                            (lambda (_)
                              (elneo-space--fetch page profile room-id from))
                            'help-echo "Fetch the next page of the listing")))))

(defun elneo-space--display-name (row)
  "The listing ROW's name: name, then alias, then the room id."
  (or (alist-get 'name row nil nil #'equal)
      (alist-get 'canonical_alias row nil nil #'equal)
      (alist-get 'room_id row nil nil #'equal)))

(defun elneo-space--row-record (profile row)
  "A registry-shaped pseudo-record for the listing ROW.
The room bar's avatar cell takes records; a hierarchy row is
wire-shaped (its `name' reads `:display-name')."
  (list :profile profile
        :room-id (alist-get 'room_id row nil nil #'equal)
        :display-name (elneo-space--display-name row)
        :avatar (alist-get 'avatar_url row nil nil #'equal)))

(defun elneo-space--avatar-cell (page profile room-id row)
  "The listing ROW's avatar cell, PAGE re-rendered on arrival.
The bar's cell over the shared avatar cache: the image once
downloaded, the bar's colored initial until then and for rooms
without an avatar.  An uncached avatar fetches in the background;
the page re-renders when it lands (only while on screen — a buried
page must not pop)."
  (let* ((record (elneo-space--row-record profile row))
         (mxc (plist-get record :avatar))
         (mxc (and (stringp mxc) (not (string-empty-p mxc)) mxc))
         (img (and mxc (elneo-room-bar--avatar-image
                        (elneo-client--avatar-file mxc)))))
    (when (and mxc (display-graphic-p)
               (not (gethash mxc elneo-client--avatar-cache))
               (not (gethash mxc elneo-client--avatar-pending)))
      (elneo-client-fetch-avatar
       profile mxc
       (lambda (_p _event)
         (when (and (buffer-live-p page) (get-buffer-window page t))
           (elneo-space-page--render page profile room-id)))))
    (concat (or img (elneo-room-bar--avatar-initial record)) " ")))

(defun elneo-space--join-hint (rule)
  "The listing's join-rule hint for RULE, or nil.
Public rooms need no hint — the absence of one is the ordinary
case; the rules that gate joining say their word here."
  (pcase rule
    ("invite" "invite-only")
    ("private" "private")
    ("knock" "knock")
    ("knock_restricted" "knock or invite")
    ("restricted" "restricted")))

(defun elneo-space--joinable-rule (rule)
  "Non-nil when RULE joins straight away.
Public rooms and the restricted shapes (the SDK joins them through
the user's space memberships — the bridges' case); invite-only and
knock-only rooms do not join from the listing and say their rule
as the hint instead.  An absent rule (an older daemon) reads
joinable, the honest side of trying."
  (member (or rule "public")
          '("public" "restricted" "knock_restricted")))

(defun elneo-space--render-row (page profile room-id row)
  "One listing ROW: avatar, name, member count, hint, buttons.
The row's state picks the actions: a joined room opens (a joined
space also browses), a joinable room offers [Join], a child space
always offers [Browse]; invite-only and knock-only rooms carry
their rule as the hint, no button.  On a join's ok the re-render
sees the registry's updated record and offers [Open]."
  (let* ((id (alist-get 'room_id row nil nil #'equal))
         (rule (alist-get 'join_rule row nil nil #'equal))
         (is-space (equal (alist-get 'room_type row nil nil #'equal)
                          "m.space"))
         (record (elneo-room-get profile id))
         (joined (or (eq (alist-get 'joined row nil nil #'equal) t)
                     (and record
                          (equal (plist-get record :room-state) "joined"))))
         (name (elneo-space--display-name row))
         (members (alist-get 'num_joined_members row nil nil #'equal))
         (hint (elneo-space--join-hint rule)))
    (insert (elneo-space--avatar-cell page profile room-id row))
    (insert name)
    (when members
      (insert (format " (%s member%s)"
                      members (if (= members 1) "" "s"))))
    (when hint (insert (format " (%s)" hint)))
    (when is-space
      (elneo-space--row-button "[Browse]" "List what this space offers"
                               (lambda (_)
                                 (elneo-space-browse profile id))))
    (when joined
      (elneo-space--row-button "[Open]" "Open this room"
                               (lambda (_)
                                 (elneo-room-open record))))
    (when (and (not joined) (elneo-space--joinable-rule rule))
      (elneo-space--row-button "[Join]" "Join this room"
                               (lambda (_)
                                 (elneo-space--join page profile room-id id
                                                    (elneo-space--row-via row)))))
    (insert "\n")
    (let ((topic (alist-get 'topic row nil nil #'equal)))
      ;; Every remote string is one line: the row keeps its shape
      ;; whatever the topic contains (newlines included).
      (when (stringp topic)
        (insert (format "      %s\n"
                        (replace-regexp-in-string "[\n\r]+" " " topic)))))))

(defun elneo-space--row-button (label help action)
  "Insert one listing-row button, LABEL with HELP-echo HELP, running ACTION.
The bar's control-button spacing: a space before, two after — the
separator is not part of the button, whatever face it carries."
  (insert " ")
  (insert-text-button label 'action action 'help-echo help)
  (insert "  "))

(defun elneo-space--row-via (row)
  "The ROW's via servers (a wire vector on older paths) as a list.
The route a remote room with no resolvable alias joins through —
its parents' m.space.child state named them."
  (append (alist-get 'via row nil nil #'equal) nil))

(defun elneo-space--join (page profile room-id id &optional via)
  "Join the listing row's room ID for PROFILE and re-render PAGE.
The row's registry record rides the ack (`updateRoom' ahead of
`roomJoined'), so the re-render reads joined and offers [Open].
The room's buffer does not open from here: the user stays on the
page and decides what to open next.  VIA is the row's join route."
  (elneo-join-room
   profile id
   (lambda (p event)
     (if (alist-get '@ok event nil nil #'equal)
         (elneo-space-page--render page p room-id)
       (message "Matrix: join failed — %s"
                (elneo-server--error-string event))))
   via))

(provide 'elneo-space)
;;; elneo-space.el ends here
