;;; poll-test.el --- room buffer poll render + live aggregate re-render -*- lexical-binding: t; -*-

;; Synthetic room-buffer test: a poll message renders its option lines
;; below the body (marks, counts, help-echo with the voter list), the
;; `elneo-poll-update-hook' re-renders the block in place with the
;; refreshed aggregate, an ended poll renders the end marker, a
;; tracked reaction line survives the re-render, and the block-bounds
;; walk keeps neighbors intact (re-rendering a poll in a full room
;; must not eat the messages around it).  The renderer paints the
;; aggregate as shipped: hiding undisclosed counts is the daemon's
;; projection, not a render-time property.
;;
;; Run: emacs -Q --batch -L lisp -l test/poll-test.el

(require 'cl-lib)
(require 'elneo-room)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defun mx-poll (ended &rest opts)
    "An aggregate plist in the `elneo-client--poll-plist' shape.
OPTS are \\='(id text count own voters) forms, quoted in the
callers — quoting again inside `mx-poll' would nest a `quote'."
    (list :question "Lunch?" :kind "m.disclosed" :max-selections 1
          :ended ended
          :options (mapcar
                    (lambda (o)
                      (list :id (nth 0 o) :text (nth 1 o) :count (nth 2 o)
                            :own (nth 3 o) :voters (nth 4 o)))
                    opts)))

  ;; The mark cell of the option line at point: everything between
  ;; the body column and the option text.
  (defun mx-mark-at ()
    (buffer-substring-no-properties
     (+ (line-beginning-position) (elneo-room--body-column))
     (+ (line-beginning-position) (elneo-room--body-column) 1)))

  (defun mx-face-at ()
    (get-text-property (line-beginning-position) 'face))

  (defun mx-echo-at ()
    (get-text-property (line-beginning-position) 'help-echo))

  (defun mx-props-at ()
    (list (get-text-property (line-beginning-position)
                             'elneo-room-poll-line)
          (get-text-property (line-beginning-position)
                             'elneo-room-poll-option)
          (get-text-property (line-beginning-position)
                             'elneo-room-event-id)))

  (let ((buf (get-buffer-create " *mx-poll-room*")))
    (with-current-buffer buf
      (elneo-room-mode)
      (setq elneo-room--profile "mxtest"
            elneo-room--room-id "!r:mxtest.org"
            elneo-room--seen (make-hash-table :test 'equal)
            elneo-room--reactions (make-hash-table :test 'equal)
            elneo-room--receipts (make-hash-table :test 'equal))
      (puthash (cons "mxtest" "!r:mxtest.org") buf elneo-room--buffers)
      (elneo-room--header (list :display-name "Test Room"
                                 :room-id "!r:mxtest.org"))
      (let* ((t0 1737043200000)
             (msgs
              (list
               (list :event-id "$before" :ts t0 :sender "@alice:mx.org"
                     :is-own nil :msgtype "m.text" :body "question coming up")
               (list :event-id "$poll" :ts (+ t0 1000) :sender "@bob:mx.org"
                     :is-own nil :msgtype "m.poll.start" :body "Lunch?"
                     :poll (mx-poll nil
                       '("o1" "Pizza" 1 t ("@me:mx.org"))
                       '("o2" "Sushi" 0 nil ())
                       '("o3" "Wrap" 1 nil ("@alice:mx.org"))))
               (list :event-id "$after" :ts (+ t0 2000) :sender "@alice:mx.org"
                     :is-own nil :msgtype "m.text" :body "all aboard"))))
        (elneo-room--append-messages msgs)
        (elneo-room--reset-input-area "")
        (setq elneo-room--backfilled t)

        ;; Render: the body line, the option lines below, the
        ;; neighbor messages intact.
        (goto-char (point-min))
        (search-forward "Lunch?")
        (mx-check "poll start's body line carries the block id"
                  (get-text-property (line-beginning-position)
                                     'elneo-room-msg-block)
                  "$poll")
        (mx-check "counts render with the option text"
                  (progn
                    (goto-char (point-min))
                    (list (and (search-forward "Pizza (1)" nil t) t)
                          (and (search-forward "Sushi\n" nil t) t)
                          (and (search-forward "Wrap (1)" nil t) t)))
                  (list t t t))
        (mx-check "zero-count options show no parenthesized count"
                  (save-excursion
                    (goto-char (point-min))
                    (search-forward "(0)" nil t))
                  nil)
        (goto-char (point-min))
        (search-forward "Pizza")
        (mx-check "option lines carry the poll properties" (mx-props-at)
                  (list t "o1" "$poll"))
        (mx-check "own option marks and faces"
                  (progn
                    (goto-char (point-min))
                    (search-forward "Pizza")
                    (list (mx-mark-at) (mx-face-at)))
                  (list "☑" 'elneo-room-poll-own))
        (mx-check "someone else's option is unmarked and plain"
                  (progn
                    (goto-char (point-min))
                    (search-forward "Wrap")
                    (list (mx-mark-at) (mx-face-at)))
                  (list "☐" 'elneo-room-poll))
        (mx-check "counts carry the voter list in help-echo"
                  (progn
                    (goto-char (point-min))
                    (search-forward "Pizza")
                    (mx-echo-at))
                  "@me:mx.org")
        (mx-check "no voters, no help-echo"
                  (progn
                    (goto-char (point-min))
                    (search-forward "Sushi")
                    (mx-echo-at))
                  nil)
        (mx-check "each option renders exactly once"
                  (list (count-matches "Pizza" (point-min) (point-max))
                        (count-matches "Sushi" (point-min) (point-max))
                        (count-matches "Wrap" (point-min) (point-max)))
                  (list 1 1 1))
        ;; The block bounds cover the block exactly: the walk-down
        ;; ends at the first char of the next content — the message
        ;; after the poll block must never be eaten.
        (mx-check "block-bounds end at the next message"
                  (save-excursion
                    (goto-char (point-min))
                    (search-forward "all aboard")
                    (line-beginning-position))
                  (cdr (elneo-room--block-bounds "$poll")))
        (mx-check "block-bounds start at or above the body line"
                  (and (< (car (elneo-room--block-bounds "$poll"))
                          (cdr (elneo-room--block-bounds "$poll")))
                       (save-excursion
                         (goto-char (point-min))
                         (search-forward "Lunch?")
                         (<= (car (elneo-room--block-bounds "$poll"))
                             (line-beginning-position))))
                  t)

        ;; A live vote re-renders the block in place.
        (elneo-room--on-poll-update
         (list :profile "mxtest" :room-id "!r:mxtest.org" :event-id "$poll"
               :poll (mx-poll nil
                '("o1" "Pizza" 1 t ("@me:mx.org"))
                '("o2" "Sushi" 2 t ("@alice:mx.org" "@me:mx.org"))
                '("o3" "Wrap" 1 nil ("@alice:mx.org")))))
        (goto-char (point-min))
        (search-forward "Sushi (2)")
        (mx-check "re-render shows the new count and own mark"
                  (list (mx-mark-at) (mx-face-at) (mx-props-at))
                  (list "☑" 'elneo-room-poll-own
                        (list t "o2" "$poll")))
        (mx-check "re-render keeps the neighbors"
                  (list (and (save-excursion (goto-char (point-min))
                                             (search-forward "question coming up"
                                                             nil t))
                             t)
                        (and (save-excursion (search-forward "all aboard" nil t))
                             t))
                  (list t t))
        (mx-check "re-render leaves no stale option lines"
                  (list (count-matches "Pizza" (point-min) (point-max))
                        (count-matches "Sushi" (point-min) (point-max))
                        (count-matches "Wrap" (point-min) (point-max)))
                  (list 1 1 1))

        ;; An undisclosed running poll ships the own mark only: zero
        ;; counts for other options, no help-echo where no voters rode.
        (elneo-room--on-poll-update
         (list :profile "mxtest" :room-id "!r:mxtest.org" :event-id "$poll"
               :poll (mx-poll nil
                '("o1" "Pizza" 1 t ())
                '("o2" "Sushi" 0 nil ())
                '("o3" "Wrap" 0 nil ()))))
        (goto-char (point-min))
        (search-forward "Pizza")
        (mx-check "undisclosed running: own vote shows"
                  (list (mx-mark-at) (mx-face-at) (mx-echo-at)
                        (buffer-substring (match-end 0) (line-end-position)))
                  (list "☑" 'elneo-room-poll-own nil " (1)"))
        (goto-char (point-min))
        (search-forward "Wrap")
        (mx-check "undisclosed running: other options show no count"
                  (buffer-substring (match-end 0) (line-end-position)) "")
        (mx-check "undisclosed running: no voter list on other options"
                  (mx-echo-at) nil)

        ;; A poll end re-renders with the final results and the end
        ;; marker.
        (elneo-room--on-poll-update
         (list :profile "mxtest" :room-id "!r:mxtest.org" :event-id "$poll"
               :poll (mx-poll t
                '("o1" "Pizza" 2 t ("@me:mx.org"))
                '("o2" "Sushi" 0 nil ())
                '("o3" "Wrap" 1 nil ("@alice:mx.org")))))
        (goto-char (point-min))
        (mx-check "poll end marker renders"
                  (save-excursion
                    (and (search-forward "· poll ended" nil t)
                         (mx-props-at)))
                  (list t nil "$poll"))
        (mx-check "neighbors still intact after the end re-render"
                  (list (and (save-excursion
                               (goto-char (point-min))
                               (search-forward "question coming up" nil t))
                             t)
                        (and (save-excursion
                               (search-forward "all aboard" nil t))
                             t))
                  (list t t))
        (mx-check "ended poll shows the final counts"
                  (and (save-excursion
                         (goto-char (point-min))
                         (search-forward "Pizza (2)" nil t))
                       t)
                  t)

        ;; A tracked reaction re-renders below the poll block and
        ;; survives the re-render.
        (puthash "$poll" (list (list :key "👍" :count 1 :own t))
                 elneo-room--reactions)
        (elneo-room--on-poll-update
         (list :profile "mxtest" :room-id "!r:mxtest.org" :event-id "$poll"
               :poll (mx-poll t
                '("o1" "Pizza" 2 t ("@me:mx.org"))
                '("o2" "Sushi" 0 nil ())
                '("o3" "Wrap" 1 nil ("@alice:mx.org")))))
        (goto-char (point-min))
        (mx-check "tracked reaction re-renders below the poll block"
                  (save-excursion
                    (and (search-forward "👍" nil t)
                         (get-text-property (line-beginning-position)
                                            'elneo-room-reaction-line)
                         (get-text-property (line-beginning-position)
                                            'elneo-room-event-id)))
                  "$poll")
        (mx-check "the reaction line is inside the block bounds"
                  (let ((bounds (elneo-room--block-bounds "$poll")))
                    (save-excursion
                      (search-forward "👍")
                      (< (line-beginning-position) (cdr bounds))))
                  t)
        (mx-check "the next message is still after it"
                  (save-excursion
                    (goto-char (cdr (elneo-room--block-bounds "$poll")))
                    (when (search-forward "all aboard" nil t) t))
                  t)

        ;; The update for another room or a poll not rendered here is
        ;; a no-op.
        (let ((before (buffer-size)))
          (elneo-room--on-poll-update
           (list :profile "other" :room-id "!r:mxtest.org" :event-id "$poll"
                 :poll (mx-poll t '("o1" "Pizza" 0 nil ()))))
          (elneo-room--on-poll-update
           (list :profile "mxtest" :room-id "!r:mxtest.org" :event-id "$gone"
                 :poll (mx-poll t '("o1" "Pizza" 0 nil ()))))
          (mx-check "stray updates are no-ops" (buffer-size) before))
        (mx-check "seen entry carries the last aggregate"
                  (plist-get (gethash "$poll" elneo-room--seen) :poll)
                  (mx-poll t
                           '("o1" "Pizza" 2 t ("@me:mx.org"))
                           '("o2" "Sushi" 0 nil ())
                           '("o3" "Wrap" 1 nil ("@alice:mx.org")))))))

  (message "results: %d passed, %d failed" pass fail)
  (when (> fail 0) (kill-emacs 1)))