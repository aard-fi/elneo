;;; bar-test.el --- room bar sort order, live re-sort, mouse clicks -*- lexical-binding: t; -*-

;; The bar's display order comes from `elneo-room-bar--visible-rooms'
;; (activity / unread / alphabetical), room updates re-sort the bar
;; live only when `elneo-room-bar-live-sort' is on, and a mouse-1
;; click on a room row opens the room per
;; `elneo-room-bar-click-action' (point always moves).  The
;; registry, the row renderer, the room opener and the coalesced full
;; re-render are stubbed; the dispatch logic itself is what's under
;; test.
;;
;; Run: emacs -Q --batch -L lisp -l test/bar-test.el

(require 'elneo-room-bar)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defvar mx-rooms
    '((:profile "a" :room-id "!quiet" :display-name "Quiet room"
                :unread 0 :last-activity 100 :last-message "")
      (:profile "a" :room-id "!loud" :display-name "Loud room"
                :unread 5 :last-activity 300 :last-message "")
      (:profile "b" :room-id "!middle" :display-name "Middle room"
                :unread 2 :last-activity 200 :last-message "")))

  ;; Display order per sort mode
  (cl-letf (((symbol-function 'elneo-rooms-all) (lambda () mx-rooms)))
    (let ((elneo-room-bar-sort 'activity))
      (mx-check "activity sort: newest first"
                (mapcar (lambda (r) (plist-get r :room-id))
                        (elneo-room-bar--visible-rooms))
                '("!loud" "!middle" "!quiet")))
    (let ((elneo-room-bar-sort 'unread))
      (mx-check "unread sort: counts descending"
                (mapcar (lambda (r) (plist-get r :room-id))
                        (elneo-room-bar--visible-rooms))
                '("!loud" "!middle" "!quiet")))
    (let ((elneo-room-bar-sort 'alpha))
      (mx-check "alpha sort: by display name"
                (mapcar (lambda (r) (plist-get r :room-id))
                        (elneo-room-bar--visible-rooms))
                '("!loud" "!middle" "!quiet"))))

  ;; Room updates: the dispatch decides between an in-place row
  ;; update, a coalesced full re-render (new rooms), and — with live
  ;; re-sorting on – a full re-render on every known-room update.
  (let ((buf (generate-new-buffer " *mx-bar-sort*"))
        (resorts 0) (row-updates 0))
    (unwind-protect
        (let ((elneo-room-bar--buffer buf)
              (elneo-room-bar--markers (make-hash-table :test 'equal)))
          (puthash (cons "a" "!loud")
                   (with-current-buffer buf (copy-marker (point-min)))
                   elneo-room-bar--markers)
          (cl-letf (((symbol-function 'elneo-room-bar--put-row)
                     (lambda (_room _marker) (cl-incf row-updates)))
                    ((symbol-function 'elneo-room-bar--schedule-full)
                     (lambda () (cl-incf resorts))))
            ;; Known room, live re-sort on: row update plus a
            ;; scheduled full re-render (the order may have changed).
            (let ((elneo-room-bar-live-sort t))
              (elneo-room-bar--on-room-update
               (list :profile "a" :room-id "!loud" :display-name "Loud room"))
              (mx-check "live: row updated in place" row-updates 1)
              (mx-check "live: re-sort scheduled" resorts 1))
            ;; Known room, live re-sort off: in-place only, the
            ;; order holds until a user action.
            (let ((elneo-room-bar-live-sort nil))
              (elneo-room-bar--on-room-update
               (list :profile "a" :room-id "!loud" :display-name "Loud room"))
              (mx-check "stable: row updated in place" row-updates 2)
              (mx-check "stable: no re-sort scheduled" resorts 1))
            ;; New room (no marker): full re-render whatever the
            ;; setting — a row has to be created.
            (let ((elneo-room-bar-live-sort nil))
              (elneo-room-bar--on-room-update
               (list :profile "b" :room-id "!middle" :display-name "M"))
              (mx-check "new room: full re-render scheduled" resorts 2)
              (mx-check "new room: no in-place row" row-updates 2))))
      (kill-buffer buf)))

  ;; The toggle command flips the setting (re-render stubbed out).
  (cl-letf (((symbol-function 'elneo-room-bar-refresh-full) (lambda () nil)))
    (let ((elneo-room-bar-live-sort t))
      (elneo-room-bar-toggle-live-sort)
      (mx-check "toggle: on -> off" elneo-room-bar-live-sort nil)
      (elneo-room-bar-toggle-live-sort)
      (mx-check "toggle: off -> on" elneo-room-bar-live-sort t)))

  ;; The DM filter: room records carry :direct (parsed by the client
  ;; from the daemon's is_direct).  nil shows everything, `dm' only
  ;; direct-message rooms, `rooms' only the rest; it composes with the
  ;; account filter.
  (let ((mx-dm-rooms
         '((:profile "a" :room-id "!dm1" :display-name "Dm friend"
                     :unread 0 :last-activity 150 :direct t)
           (:profile "b" :room-id "!dm2" :display-name "Other friend"
                     :unread 0 :last-activity 250 :direct t)
           (:profile "a" :room-id "!grp" :display-name "Group"
                     :unread 1 :last-activity 300)
           (:profile "b" :room-id "!gone" :display-name "Removed"
                     :unread 0 :last-activity 400 :removed t))))
    (cl-letf (((symbol-function 'elneo-rooms-all)
               (lambda () mx-dm-rooms)))
      (let (elneo-room-bar-dm-filter)
        (mx-check "dm-filter: nil shows every room, removed dropped"
                  (mapcar (lambda (r) (plist-get r :room-id))
                          (elneo-room-bar--visible-rooms))
                  '("!grp" "!dm2" "!dm1")))
      (let ((elneo-room-bar-dm-filter 'dm))
        (mx-check "dm-filter: dm shows only direct rooms"
                  (mapcar (lambda (r) (plist-get r :room-id))
                          (elneo-room-bar--visible-rooms))
                  '("!dm2" "!dm1")))
      (let ((elneo-room-bar-dm-filter 'rooms))
        (mx-check "dm-filter: rooms shows only non-direct rooms"
                  (mapcar (lambda (r) (plist-get r :room-id))
                          (elneo-room-bar--visible-rooms))
                  '("!grp")))
      ;; Composes with the account filter: DMs of account a only.
      (let ((elneo-room-bar-dm-filter 'dm)
            (elneo-room-bar-account-filter "a"))
        (mx-check "dm-filter: composes with account filter"
                  (mapcar (lambda (r) (plist-get r :room-id))
                          (elneo-room-bar--visible-rooms))
                  '("!dm1")))))
  ;; The `d' cycle: everything -> DMs -> rooms -> everything (refresh
  ;; stubbed; the state lives on the session var).
  (cl-letf (((symbol-function 'elneo-room-bar-refresh-full) (lambda () nil)))
    (let (elneo-room-bar-dm-filter)
      (elneo-room-bar-cycle-dm)
      (mx-check "dm-cycle: nil -> dm" elneo-room-bar-dm-filter 'dm)
      (elneo-room-bar-cycle-dm)
      (mx-check "dm-cycle: dm -> rooms" elneo-room-bar-dm-filter 'rooms)
      (elneo-room-bar-cycle-dm)
      (mx-check "dm-cycle: rooms -> nil" elneo-room-bar-dm-filter nil)))

  ;; The DM badge on a row: DM rows carry the ⓓ glyph in front, group
  ;; rows do not, and an empty glyph setting renders nothing anywhere.
  (let ((buf (generate-new-buffer " *mx-bar-dm*")))
    (unwind-protect
        (with-current-buffer buf
          (let ((dm-room '(:profile "a" :room-id "!dm" :display-name "Friend"
                                    :unread 0 :highlights 0 :last-activity 1
                                    :direct t))
                (grp-room '(:profile "a" :room-id "!grp" :display-name "Group"
                                      :unread 0 :highlights 0 :last-activity 1)))
            (mx-check "dm-glyph: direct row carries the badge"
                      (and (string-search elneo-room-bar-dm-glyph
                                          (elneo-room-bar--row-text dm-room))
                           t)
                      t)
            (mx-check "dm-glyph: group row has none"
                      (string-search elneo-room-bar-dm-glyph
                                     (elneo-room-bar--row-text grp-room))
                      nil)
            (let ((elneo-room-bar-dm-glyph ""))
              (mx-check "dm-glyph: empty setting renders nothing"
                        (list (string-search elneo-room-bar-dm-glyph
                                             (elneo-room-bar--row-text dm-room))
                              (string-match-p "ⓓ"
                                              (elneo-room-bar--row-text dm-room)))
                        (list 0 nil)))))
      (kill-buffer buf)))

  ;; The space badge: a room the daemon typed as a space carries the
  ;; ❒ glyph in front of its name (it IS an ordinary room row — its own
  ;; timeline previews like any other — the glyph is what says `b' on
  ;; it opens the space page); an ordinary room row and an empty glyph
  ;; setting render nothing.
  (let ((buf (generate-new-buffer " *mx-bar-space*")))
    (unwind-protect
        (with-current-buffer buf
          (let ((space-room '(:profile "a" :room-id "!sp" :display-name "Wings"
                                       :unread 0 :highlights 0 :last-activity 1
                                       :space t))
                (room-room '(:profile "a" :room-id "!r" :display-name "Rooms"
                                      :unread 0 :highlights 0 :last-activity 1)))
            (mx-check "space-glyph: space row carries the badge"
                      (and (string-search elneo-room-bar-space-glyph
                                          (elneo-room-bar--row-text space-room))
                           t)
                      t)
            (mx-check "space-glyph: ordinary row has none"
                      (string-search elneo-room-bar-space-glyph
                                     (elneo-room-bar--row-text room-room))
                      nil)
            (let ((elneo-room-bar-space-glyph ""))
              (mx-check "space-glyph: empty setting renders nothing"
                        (list (string-search elneo-room-bar-space-glyph
                                             (elneo-room-bar--row-text space-room))
                              (string-match-p "❒"
                                              (elneo-room-bar--row-text space-room)))
                        (list 0 nil)))))
      (kill-buffer buf)))

  ;; The upgrade marker: a tombstoned room (its `:upgraded-to' names
  ;; the replacement) carries the ⬆ glyph in front of its name — the
  ;; dead old row, the one people keep typing into; an ordinary row
  ;; and an empty glyph setting render nothing.
  (let ((buf (generate-new-buffer " *mx-bar-upgrade*")))
    (unwind-protect
        (with-current-buffer buf
          (let ((dead-room '(:profile "a" :room-id "!old" :display-name "Aged"
                                      :unread 0 :highlights 0 :last-activity 1
                                      :upgraded-to "!new"))
                (room-room '(:profile "a" :room-id "!r" :display-name "Rooms"
                                      :unread 0 :highlights 0 :last-activity 1)))
            (mx-check "upgrade-glyph: dead room row carries the marker"
                      (and (string-search elneo-room-bar-upgrade-glyph
                                          (elneo-room-bar--row-text dead-room))
                           t)
                      t)
            (mx-check "upgrade-glyph: ordinary row has none"
                      (string-search elneo-room-bar-upgrade-glyph
                                     (elneo-room-bar--row-text room-room))
                      nil)
            (let ((elneo-room-bar-upgrade-glyph ""))
              (mx-check "upgrade-glyph: empty setting renders nothing"
                        (list (string-search elneo-room-bar-upgrade-glyph
                                             (elneo-room-bar--row-text dead-room))
                              (string-search "⬆"
                                             (elneo-room-bar--row-text dead-room)))
                        (list 0 nil)))))
      (kill-buffer buf)))

  ;; The controls row exposes the DM filter state: [DM+] when showing
  ;; everything (no face change), [DMs] when DMs only, [NoDMs] for
  ;; the rooms-only filter, carrying the state faces like row one.
  (let ((buf (generate-new-buffer " *mx-bar-dmctl*")))
    (unwind-protect
        (let ((elneo-room-bar--buffer buf))
          (with-current-buffer buf
            (let (elneo-room-bar-dm-filter)
              (elneo-room-bar--insert-controls)
              (mx-check "dm-controls: everything shows DM+"
                        (and (string-search "[DM+]" (buffer-string)) t) t)
              (erase-buffer))
            (let ((elneo-room-bar-dm-filter 'dm))
              (elneo-room-bar--insert-controls)
              (mx-check "dm-controls: dm filter shows DMs"
                        (and (string-search "[DMs]" (buffer-string)) t) t)
              (erase-buffer))
            (let ((elneo-room-bar-dm-filter 'rooms))
              (elneo-room-bar--insert-controls)
              (mx-check "dm-controls: rooms filter shows NoDMs"
                        (and (string-search "[NoDMs]" (buffer-string)) t) t))))
      (kill-buffer buf)))

  ;; The filter buttons' faces: an inactive control shows as the
  ;; ordinary blue button link type — the explicit `button' face,
  ;; which is what an unfaced button inherits — and the ACTIVE
  ;; filter's button carries the header face.  (Passing an explicit
  ;; empty face would paint the default foreground instead; a
  ;; `face nil' property overrides the button category entirely, so
  ;; the face prop must be a real face in both states.)
  (let ((buf (generate-new-buffer " *mx-bar-faces*")))
    (unwind-protect
        (let ((elneo-room-bar--buffer buf) (got nil))
          (with-current-buffer buf
            (goto-char (point-min))
            (let (elneo-room-bar-account-filter elneo-room-bar-dm-filter)
              (elneo-room-bar--insert-controls)
              ;; search-forward returns the match's end — the face lives
              ;; on the label itself, so read at match-beginning.
              (goto-char (point-min))
              (search-forward "[All]")
              (setq got (list (get-char-property (match-beginning 0) 'face)))
              (goto-char (point-min))
              (search-forward "[DM+]")
              (nconc got (list (get-char-property (match-beginning 0) 'face)))
              (erase-buffer))
            (let ((elneo-room-bar-account-filter "one")
                  (elneo-room-bar-dm-filter 'dm))
              (elneo-room-bar--insert-controls)
              (goto-char (point-min))
              (search-forward "[All]")
              (nconc got (list (get-char-property (match-beginning 0) 'face)))
              (goto-char (point-min))
              (search-forward "[DMs]")
              (nconc got (list (get-char-property (match-beginning 0) 'face)))))
          ;; Default: the "All" view is the active one (header face),
          ;; the DM filter is not (blue button).  Filtered: inverted.
          (mx-check "control faces: inactive blue, active header"
                    got
                    (list 'elneo-room-bar-header 'button
                          'button 'elneo-room-bar-header)))
      (kill-buffer buf)))

  ;; Mouse-1 on a room row: point always moves to the click, the room
  ;; opens per `elneo-room-bar-click-action'.  Events are synthetic:
  ;; (mouse-1 (WINDOW POINT) CLICK-COUNT) is all the handler reads.
  (let ((buf (generate-new-buffer " *mx-bar-click*"))
        (opened 0)
        (row-pt 0))
    (unwind-protect
        (let ((elneo-room-bar--buffer buf)
              (elneo-room-bar--markers (make-hash-table :test 'equal)))
          (with-current-buffer buf
            (insert "controls row\n")
            (insert (propertize "  Loud room\n" 'elneo-room-key
                                (cons "a" "!loud")))
            (setq row-pt (save-excursion
                          (goto-char (point-min))
                          (search-forward "Loud")
                          (1- (point)))))
          (set-window-buffer (selected-window) buf)
          ;; defcustoms are special: plain `let' rebinds them
          ;; dynamically for the handler.
          (let ((elneo-room-bar-click-action 'open))
            (cl-letf (((symbol-function 'elneo-room-get)
                       (lambda (_profile _id) t))
                      ((symbol-function 'elneo-room-open)
                       (lambda (_room &optional _stay-put) (cl-incf opened))))
              ;; open: a single click opens, and point lands on the row.
              (elneo-room-bar--mouse-1 (list 'mouse-1
                                              (list (selected-window) row-pt)
                                              1))
              (mx-check "click: room opened" opened 1)
              (mx-check "click: point moved to the row" (point) row-pt)
              ;; point mode: the click only moves point.
              (let ((elneo-room-bar-click-action 'point))
                (elneo-room-bar--mouse-1 (list 'mouse-1
                                                (list (selected-window) row-pt)
                                                1))
                (mx-check "click: point mode never opens" opened 1))
              ;; double mode: single click no, double click yes.
              (let ((elneo-room-bar-click-action 'double))
                (elneo-room-bar--mouse-1 (list 'mouse-1
                                                (list (selected-window) row-pt)
                                                1))
                (mx-check "click: double mode ignores single" opened 1)
                (elneo-room-bar--mouse-1 (list 'mouse-1
                                                (list (selected-window) row-pt)
                                                2))
                (mx-check "click: double mode opens on double" opened 2))
              ;; A click on the controls row (no room key there) never
              ;; opens, whatever the setting.
              (let ((elneo-room-bar-click-action 'open))
                (elneo-room-bar--mouse-1 (list 'mouse-1
                                                (list (selected-window) 1)
                                                1))
                (mx-check "click: no room on controls rows" opened 2)
                (mx-check "click: point still moved" (point) 1))
              ;; The cycle command walks the three settings.
              (let ((elneo-room-bar-click-action 'open))
                (elneo-room-bar-cycle-click-action)
                (mx-check "cycle: open -> double"
                          elneo-room-bar-click-action 'double)
                (elneo-room-bar-cycle-click-action)
                (mx-check "cycle: double -> point"
                          elneo-room-bar-click-action 'point)
                (elneo-room-bar-cycle-click-action)
                (mx-check "cycle: point -> open"
                          elneo-room-bar-click-action 'open))))))
      (kill-buffer buf))

  ;; Point directly AFTER a room row: with previews off the row is
  ;; one short line, and point parks at its end — on the row's
  ;; terminating newline, which carries no properties of its own.
  ;; RET (and a click there) must still hit the row instead of
  ;; "No room on this line".
  (let ((buf (generate-new-buffer " *mx-bar-eol*"))
        (opened 0) (row-pt 0) (row-eol 0))
    (unwind-protect
        (let ((elneo-room-bar--buffer buf))
          (with-current-buffer buf
            (insert "controls row\n")
            (insert (propertize "  Loud room\n" 'elneo-room-key
                                (cons "a" "!loud")))
            (goto-char (point-min))
            (search-forward "Loud")
            (setq row-eol (line-end-position)))
          (set-window-buffer (selected-window) buf)
          (cl-letf (((symbol-function 'elneo-room-get)
                     (lambda (_profile _id) t))
                    ((symbol-function 'elneo-room-open)
                     (lambda (_room &optional _stay-put) (cl-incf opened))))
            (with-current-buffer buf
              ;; RET from end of the row's line.
              (goto-char row-eol)
              (setq row-pt (point))
              (call-interactively #'elneo-room-bar-open-at-point)
              (mx-check "RET at row end opens the room" opened 1)
              ;; A mouse-1 click parked after the name does too.
              (elneo-room-bar--mouse-1 (list 'mouse-1
                                              (list (selected-window) row-eol)
                                              1))
              (mx-check "click at row end opens the room" opened 2)
              (mx-check "click at row end moves point" (point) row-pt)
              ;; RET still refuses lines without a row.
              (goto-char (point-min))
              (mx-check "RET on a barren line still errors"
                        (condition-case e
                            (progn (call-interactively
                                    #'elneo-room-bar-open-at-point)
                                   'no-error)
                          (user-error e))
                        '(user-error "No room on this line")))))
      (kill-buffer buf)))

  ;; Grouped view: each account's header directly precedes its
  ;; rooms, in account order (put-row appends at point-max — the
  ;; header insertion must follow suit, or the headers pile up before
  ;; every row).  The real refresh runs against stubbed rooms.
  ;; The stub must hand out a fresh list per call: the renderer
  ;; sorts destructively, and a shared literal would leak the sort
  ;; into later calls (the real `elneo-rooms-all' builds its list
  ;; fresh every time).
  (let ((stub-rooms
         '((:profile "a" :room-id "!1" :display-name "A1"
                     :unread 0 :highlights 0 :last-activity 100 :last-message "")
           (:profile "b" :room-id "!2" :display-name "B1"
                     :unread 2 :highlights 0 :last-activity 500 :last-message "")
           (:profile "a" :room-id "!3" :display-name "A2"
                     :unread 1 :highlights 0 :last-activity 300 :last-message ""))))
    (cl-letf (((symbol-function 'elneo-rooms-all)
               (lambda () (append stub-rooms nil))))
      (let ((buf (generate-new-buffer " *mx-bar-grouped*"))
            (text nil))
        (unwind-protect
            (let ((elneo-room-bar--buffer buf)
                  (elneo-room-bar--markers (make-hash-table :test 'equal)))
              ;; Mixed first: activity order, no headers.
              (let ((elneo-room-bar-grouped nil))
                (elneo-room-bar-refresh-full)
                (setq text (with-current-buffer buf (buffer-string)))
                (mx-check "grouped off: no headers"
                          (and (or (string-match-p "▾ " text)
                                   (string-match-p "▸ " text))
                               t)
                          nil)
                (mx-check "grouped off: activity order"
                          (and (< (string-match "B1" text)
                                  (string-match "A2" text))
                               (< (string-match "A2" text)
                                  (string-match "A1" text)))
                          t))
              ;; Grouped: header directly before its rooms, sections in
              ;; account order, rooms in activity order inside a section.
              (let ((elneo-room-bar-grouped t))
                (elneo-room-bar-refresh-full)
                (setq text (with-current-buffer buf (buffer-string)))
                (mx-check "grouped on: a section before its rooms"
                          (and (< (string-match "▾ a" text)
                                  (string-match "A2" text))
                               (< (string-match "A2" text)
                                  (string-match "A1" text))
                               (< (string-match "A1" text)
                                  (string-match "▾ b" text))
                               (< (string-match "▾ b" text)
                                  (string-match "B1" text)))
                          t))
              ;; Folding: a folded section hides its rooms, the header
              ;; keeps a room/unread summary, other sections stay open.
              (let ((elneo-room-bar--folded-accounts
                     (make-hash-table :test 'equal)))
                (puthash "a" t elneo-room-bar--folded-accounts)
                (let ((elneo-room-bar-grouped t))
                  (elneo-room-bar-refresh-full)
                  (setq text (with-current-buffer buf (buffer-string)))
                  (mx-check "folded: header carries the summary"
                            (and (string-match-p
                                  "▸ a (2 rooms, 1 unread)" text)
                                 t)
                            t)
                  (mx-check "folded: other section stays open"
                            (and (string-match-p "▾ b" text) t)
                            t)
                  (mx-check "folded: the section's rooms are hidden"
                            (and (or (string-match-p "A2" text)
                                     (string-match-p "A1" text))
                                 t)
                            nil)
                  (mx-check "folded: other section's rooms stay"
                            (and (string-match-p "B1" text) t)
                            t)
                  ;; RET on the header unfolds: rooms back under a ▾.
                  (with-current-buffer buf
                    (goto-char (point-min))
                    (search-forward "▸ a")
                    (goto-char (match-beginning 0))
                    (call-interactively #'elneo-room-bar-open-at-point))
                  (setq text (with-current-buffer buf (buffer-string)))
                  (mx-check "RET on header unfolds the section"
                            (and (string-match-p "▾ a" text)
                                 (string-match-p "A2" text)
                                 (string-match-p "A1" text)
                                 t)
                            t)
                  ;; A click on the header folds it back — headers are
                  ;; buttons like the control row, so this holds even
                  ;; with the click-action set to point-only.
                  (set-window-buffer (selected-window) buf)
                  (let ((header-pt (with-current-buffer buf
                                     (save-excursion
                                       (goto-char (point-min))
                                       (search-forward "▾ a")
                                       (match-beginning 0)))))
                    (let ((elneo-room-bar-click-action 'point))
                      (elneo-room-bar--mouse-1 (list 'mouse-1
                                                      (list (selected-window)
                                                            header-pt)
                                                      1)))
                    (setq text (with-current-buffer buf (buffer-string)))
                    (mx-check "click on header folds (even in point mode)"
                              (and (string-match-p "▸ a" text)
                                   (not (string-match-p "A2" text)))
                              t)
                    ;; ...and every click still moves point.
                    (mx-check "click on header moves point"
                              (with-current-buffer buf (point))
                              header-pt)))))
          (kill-buffer buf)))))

  ;; The visibility toggle: b from the options menu shows the bar
  ;; when it is hidden and hides it when it shows.
  (let ((buf (generate-new-buffer " *mx-bar-toggle*"))
        (bar-window-p
         (lambda (buffer)
           (cl-find-if (lambda (w) (eq (window-buffer w) buffer))
                       (window-list (selected-frame) 'no-minibuf)))))
    (unwind-protect
        (let ((elneo-room-bar--buffer buf)
              (elneo-room-bar--markers (make-hash-table :test 'equal)))
          (elneo-room-bar-toggle-visibility)
          (mx-check "toggle: bar shown when hidden"
                    (and (funcall bar-window-p buf) t) t)
          (elneo-room-bar-toggle-visibility)
          (mx-check "toggle: bar hidden when shown"
                    (and (funcall bar-window-p buf) t) nil)
          ;; show is one-directional: never deletes an on-screen bar.
          (elneo-room-bar-show)
          (mx-check "show: raises without toggling off"
                    (and (funcall bar-window-p buf) t) t)
          ;; leave the window configuration as it was.
          (when-let* ((window (funcall bar-window-p buf)))
            (delete-window window)))
      (kill-buffer buf)))

  ;; Session trust: the daemon's updateCrossSigningStatus lands in
  ;; `elneo-server--trust' and fires the hook the bar hangs on.
  ;; The bar's require chain already loaded elneo-server.
  (let ((hook-fired nil)
        (elneo-session-trust-hook nil))
    (add-hook 'elneo-session-trust-hook
              (lambda (profile enabled trusted)
                (push (list profile enabled trusted) hook-fired)))
    (elneo-server--on-update-cross-signing-status
     "a" '((enabled . t) (trusted . nil)))
    (mx-check "trust: recorded in the alist"
              (cdr (assoc "a" elneo-server--trust))
              '(t . nil))
    (mx-check "trust: hook fired with the state"
              hook-fired '(("a" t nil)))
    (elneo-server--on-update-cross-signing-status
     "a" '((enabled . t) (trusted . t)))
    (mx-check "trust: overwritten on the next event"
              (cdr (assoc "a" elneo-server--trust))
              '(t . t))
    ;; Exit pruning: a dead daemon's trust row goes with it (the
    ;; single cleanup point is the sentinel).
    (setq elneo-server--trust '(("zap" t . nil)))
    (elneo-server--sentinel "zap" nil "deleted\n")
    (mx-check "trust: sentinel prunes dead profiles"
              (assoc "zap" elneo-server--trust)
              nil))

  ;; The bar's controls: a third row with a [Verify] button appears
  ;; only for an enabled-but-untrusted session.
  (let ((buf (generate-new-buffer " *mx-bar-trust*")))
    (unwind-protect
        (with-current-buffer buf
          (let ((elneo-room-bar--buffer buf))
            ;; Only the controls themselves matter here: no rooms in
            ;; the registry (the trust alist is the button source), no
            ;; re-render — this inserts direct.
            ;; No trust state at all (fresh bar): no third row.
            (let ((elneo-server--trust nil))
              (erase-buffer)
              (elneo-room-bar--insert-controls)
              (mx-check "trust: no row without state"
                        (and (string-match-p "Av:" (buffer-string))
                             (not (string-match-p "\\[Verify" (buffer-string)))
                             t)
                        t))
            ;; enabled=nil (lone device, never bootstrapped): no nag.
            (let ((elneo-server--trust '(("a" nil . nil))))
              (erase-buffer)
              (elneo-room-bar--insert-controls)
              (mx-check "trust: enabled-off account shows no button"
                        (and (string-match-p "Av:" (buffer-string))
                             (not (string-match-p "\\[Verify" (buffer-string)))
                             t)
                        t))
            ;; enabled=t trusted=t: verified, no row.
            (let ((elneo-server--trust '(("a" t . t))))
              (erase-buffer)
              (elneo-room-bar--insert-controls)
              (mx-check "trust: verified session shows no button"
                        (and (not (string-match-p "\\[Verify" (buffer-string)))
                             t)
                        t))
            ;; enabled=t trusted=nil: the one case that nags.
            (let ((elneo-server--trust '(("a" t . nil) ("b" nil . t))))
              (erase-buffer)
              (elneo-room-bar--insert-controls)
              (mx-check "trust: untrusted session shows its row"
                        (and (string-match-p "\\[Verify: a\\]" (buffer-string))
                             (not (string-match-p "\\[Verify: b\\]" (buffer-string)))
                             t)
                        t)
              ;; …and somewhere in it sits the unverified face.
              (let ((found nil) (pos (point-min)) end)
                (while (and (not found)
                            (< pos (point-max)))
                  (setq end (next-single-property-change
                             pos 'face nil (point-max)))
                  (let ((f (get-text-property pos 'face)))
                    (when (or (eq f 'elneo-room-bar-unverified)
                              (and (listp f)
                                   (memq 'elneo-room-bar-unverified f)))
                      (setq found t)))
                  (setq pos (or end (point-max))))
                (mx-check "trust: button carries its face" found t)))))
      (kill-buffer buf)))

  ;; The hook member defers to the coalesced renderer, and only with
  ;; a live bar buffer.
  (let ((buf (generate-new-buffer " *mx-bar-trust-hook*"))
        (scheduled 0))
    (unwind-protect
        (let ((elneo-room-bar--buffer buf))
          (cl-letf (((symbol-function 'elneo-room-bar--schedule-full)
                     (lambda () (cl-incf scheduled))))
            (elneo-room-bar--on-session-state "a" t nil)
            (mx-check "trust hook: schedules the re-render" scheduled 1)
            (let ((elneo-room-bar--buffer nil))
              (elneo-room-bar--on-session-state "a" t nil)
              (mx-check "trust hook: no buffer, no schedule" scheduled 1))))
      (kill-buffer buf)))

  ;; Killing the bar deliberately leaves the global hooks registered —
  ;; the bar returns on the next real room or session event.  What
  ;; must NOT survive the kill is a pending coalesced full render: its
  ;; idle callback would run --flush-full → refresh-full → --ensure
  ;; and resurrect the buffer with no user action.  The idle timer,
  ;; cancel-timer and the full re-render are stubbed, so the checks
  ;; see the real calls: the arm, the cancel of exactly the armed
  ;; timer, the pending flag reset, and a post-kill callback firing
  ;; with nothing to render and no buffer coming back.  It also pins
  ;; the --ensure wiring: the kill hook is registered on the bar
  ;; buffer itself (a top-level add-hook landed it on --ensure's
  ;; caller instead, and --on-kill never ran at all).
  (let (armed cancelled flushed)
    (unwind-protect
        (let ((elneo-room-bar--full-pending nil)
              (elneo-room-bar--full-timer nil))
          (cl-letf (((symbol-function 'run-with-idle-timer)
                     (lambda (_secs _repeat callback &rest args)
                       (setq armed (lambda () (apply callback args)))
                       'mx-armed-timer))
                    ((symbol-function 'cancel-timer)
                     (lambda (timer) (push timer cancelled)))
                    ((symbol-function 'elneo-room-bar-refresh-full)
                     (lambda () (setq flushed t))))
            (elneo-room-bar--ensure)
            (setq armed nil flushed nil)
            (mx-check "ensure: the kill hook sits on the bar buffer"
                      (not (not (memq #'elneo-room-bar--on-kill
                                      (buffer-local-value
                                       'kill-buffer-hook
                                       elneo-room-bar--buffer))))
                      t)
            (elneo-room-bar--schedule-full)
            (mx-check "kill: a full render is pending behind its timer"
                      (and armed (eq elneo-room-bar--full-timer 'mx-armed-timer)
                           elneo-room-bar--full-pending)
                      t)
            (kill-buffer elneo-room-bar--buffer)
            (mx-check "kill: the armed timer is cancelled"
                      cancelled '(mx-armed-timer))
            (mx-check "kill: the pending render is forgotten"
                      (and (not elneo-room-bar--full-pending)
                           (not elneo-room-bar--full-timer)) t)
            ;; The real idle timer would still fire post-kill without
            ;; the cancel; simulate that and expect a no-op.
            (when armed (funcall armed))
            (mx-check "kill: the stale callback cannot resurrect"
                      (and (not flushed)
                           (not (get-buffer "*Matrix Rooms*"))) t)))
      (remove-hook 'elneo-room-update-hook #'elneo-room-bar--on-room-update)
      (remove-hook 'elneo-session-trust-hook #'elneo-room-bar--on-session-state)
      (remove-hook 'elneo-session-sync-hook #'elneo-room-bar--on-session-state)
      (when (get-buffer "*Matrix Rooms*")
        (kill-buffer "*Matrix Rooms*"))))

  ;; --- room summaries convert their room state ---

  ;; The daemon (protocol 5) tags every summary "joined" or "invited";
  ;; a pre-5 daemon ships no field and the record keeps the sensible
  ;; default so old rows stay ordinary joined rooms.
  (let ((record (elneo-client--room-record
                 '((room_id . "!i:hs") (display_name . "Invite")
                   (room_state . "invited")))))
    (mx-check "room_state converts into :room-state"
              (plist-get record :room-state) "invited"))
  (mx-check "missing room_state falls back to \"joined\""
            (plist-get (elneo-client--room-record '((room_id . "!r:hs"))) :room-state)
            "joined")
  (let ((record (elneo-client--room-record
                 '((room_id . "!r:hs") (room_state . "joined")
                   (display_name . "Room") (topic . "hi")))))
    (mx-check "unrelated keys survive untouched"
              (list (plist-get record :display-name)
                    (plist-get record :topic) (plist-get record :room-state))
              '("Room" "hi" "joined")))

  ;; --- multi-line rows: newline flattening and marker-anchored rewrites ---

  ;; Names and previews come from message bodies: they routinely hold
  ;; newlines.  `elneo-room-bar--row-text' must flatten them, or a row
  ;; spans more than `elneo-room-bar--row-lines' lines and in-place
  ;; rewrites stop landing where they say they do.
  (let ((room (list :display-name "Aardvark" :preview "one\ntwo\nthree"
                    :profile "a" :room-id "!nl" :room-state "joined"
                    :unread 0 :highlights 0 :last-activity 1)))
    (let ((elneo-room-bar-preview-style 'below))
      (mx-check "flatten: below-style row stays exactly two lines"
                (cl-count ?\n (elneo-room-bar--row-text room))
                1))
    (let ((elneo-room-bar-preview-style 'inline))
      (mx-check "flatten: inline row stays one line"
                (string-match-p "\n" (elneo-room-bar--row-text room))
                nil))
    (let ((elneo-room-bar-preview-style 'none))
      (mx-check "flatten: none-style row stays one line"
                (string-match-p "\n" (elneo-room-bar--row-text room))
                nil))
    (let ((elneo-room-bar-preview-style 'below)
          (room2 (list :display-name "Two\nline\nname" :preview "single"
                       :profile "a" :room-id "!nl2" :room-state "joined"
                       :unread 0 :highlights 0 :last-activity 1)))
      (mx-check "flatten: multiline name flattens too"
                (cl-count ?\n (elneo-room-bar--row-text room2)) 1)))
  ;; A carriage return (paste from elsewhere) flattens as well.
  (mx-check "flatten: carriage returns flatten"
            (string-match-p "\r" (elneo-room-bar--flatten-newlines "a\rb\rc"))
            nil)

  ;; The marker-anchored rewrite: an in-place update replaces
  ;; everything from the row's marker to the next marker — not a fixed
  ;; line count.  A row that somehow rendered wide (pre-flattening
  ;; residue) is cleaned by its next update instead of leaving stale
  ;; lines between rows — and the following room is never eaten.
  (let* ((buf (generate-new-buffer " *mx-bar-residue*"))
         (key-wide (cons "a" "!wide"))
         (key-next (cons "a" "!next")))
    (unwind-protect
        (let ((elneo-room-bar--buffer buf)
              (elneo-room-bar--markers (make-hash-table :test 'equal)))
          (with-current-buffer buf
            (insert "controls row\n")
            ;; room A row as a wide 3-line row (simulated residue)
            (insert (propertize "Wide room\n  stale line one\n  stale line two\n"
                                'elneo-room-key key-wide))
            (let ((pos (point)))
              (insert (propertize "Next room\n" 'elneo-room-key key-next))
              (puthash key-wide (copy-marker
                                 (save-excursion
                                   (goto-char (point-min))
                                   (search-forward "Wide room")
                                   (line-beginning-position)))
                       elneo-room-bar--markers)
              (puthash key-next (copy-marker
                                 (save-excursion
                                   (goto-char pos)
                                   (line-beginning-position)))
                       elneo-room-bar--markers)))
          ;; in-place update of the wide room — one clean row, no stale
          ;; lines, next room intact.
          (elneo-room-bar--put-row
           (list :profile "a" :room-id "!wide" :display-name "Wide room"
                 :preview "short now" :unread 0 :highlights 0
                 :last-activity 1 :room-state "joined")
           (gethash key-wide elneo-room-bar--markers))
          (let ((text (with-current-buffer buf (buffer-string))))
            (mx-check "rewrite: wide row collapses to one row"
                      (and (string-match-p "Wide room\n" text)
                           (not (string-match-p "stale line" text))
                           (string-match-p "  short now\nNext room\n" text)
                           t)
                      t)
            (mx-check "rewrite: next room intact"
                      (not (string-match-p "stale" text))
                      t))
          ;; markers survived the rewrite, on their own rows
          (mx-check "rewrite: next room's marker stays on its row"
                    (with-current-buffer buf
                      (save-excursion
                        (goto-char (gethash key-next elneo-room-bar--markers))
                        (and (equal (get-text-property (point) 'elneo-room-key)
                                    key-next)
                             t)))
                    t)
          ;; remove-room with the same anchor: the wide room (grown wide
          ;; again) disappears along with its stale lines, next room stays.
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (goto-char (gethash key-wide elneo-room-bar--markers))
              (delete-region (point)
                             (gethash key-next elneo-room-bar--markers))
              (insert (propertize "Wide room\n  stale again\n" 'elneo-room-key
                                  key-wide))
              ;; the boundary marker must sit at the next row's start
              ;; again (the real code does this around its rewrites)
              (set-marker (gethash key-next elneo-room-bar--markers)
                          (point))))
          (elneo-room-bar--remove-room
           (list :profile "a" :room-id "!wide"))
          (let ((text (with-current-buffer buf (buffer-string))))
            (mx-check "remove: wide row and its residue both go"
                      (and (string-match-p "Next room\n" text)
                           (not (string-match-p "Wide" text))
                           (not (string-match-p "stale again" text)))
                      t)
            (mx-check "remove: marker entry pruned"
                      (gethash key-wide elneo-room-bar--markers)
                      nil)))
      (kill-buffer buf)))

  (message "results: %d passed, %d failed" pass fail)
  (kill-emacs (if (zerop fail) 0 1)))