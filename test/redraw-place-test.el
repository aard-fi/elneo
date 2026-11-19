;;; redraw-place-test.el --- point across full re-renders -*- lexical-binding: t; -*-

;; A full re-render (display toggles, room keys refetching the first
;; page, C-c C-r, a thread view's refill) puts the buffer's point and
;; every window's back where they were: in the same message at the
;; same offset, or at the same offset in the draft.  A message the
;; refetch no longer renders falls back to the oldest one rendered.
;; Batch Emacs never redisplays, so whether a window shows the
;; buffer's end is stated rather than computed.
;;
;; Run: emacs -Q --batch -L lisp -l test/redraw-place-test.el

(require 'cl-lib)
(require 'elneo-room)
(require 'elneo-thread)

(let ((pass 0) (fail 0)
      (at-end nil)
      buf)
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defun mx-entry (id ts body &optional thread-root)
    (append (list (cons 'event_id id) (cons 'sender "@a:mx.org")
                  (cons 'body body) (cons 'ts ts) (cons 'msgtype "m.text"))
            (when thread-root (list (cons 'thread_root thread-root)))))

  (defun mx-newest-page ()
    "The room's newest page as the daemon sends it: $n1 .. $n6."
    (list (cons '@ok t) (cons 'room_id "!r:mxtest.org")
          (cons 'messages
                (vconcat (cl-loop for i from 1 to 6
                                  collect (mx-entry (format "$n%d" i)
                                                    (+ 100000 i)
                                                    (format "newer message %d" i)))))
          (cons 'end "t0")))

  (defun mx-older-page ()
    (list (cons '@ok t) (cons 'room_id "!r:mxtest.org")
          (cons 'messages (vector (mx-entry "$o1" 90000 "older message one")))
          (cons 'end "t1")))

  (defmacro mx-with-stubs (&rest body)
    `(cl-letf (((symbol-function 'elneo-room-messages) #'ignore)
               ((symbol-function 'elneo-room-receipts) #'ignore)
               ((symbol-function 'elneo-server-live-p) (lambda (_p) t))
               ((symbol-function 'elneo-room--window-at-end-p)
                (lambda (_w) at-end)))
       ,@body))

  (defun mx-deliver (page)
    (mx-with-stubs (elneo-room--on-history "mxtest" page)))

  ;; A room rendered through the daemon path, shown in the selected
  ;; window, with "hello" in the draft.
  (defun mx-room ()
    (when (buffer-live-p buf) (kill-buffer buf))
    (delete-other-windows)
    (setq buf (get-buffer-create "*mx-redraw-room*")
          at-end nil)
    (with-current-buffer buf
      (elneo-room-mode)
      (setq elneo-room--profile "mxtest"
            elneo-room--room-id "!r:mxtest.org")
      (puthash (cons "mxtest" "!r:mxtest.org") buf elneo-room--buffers))
    (switch-to-buffer buf)
    (mx-deliver (mx-newest-page))
    (with-current-buffer buf
      (goto-char (point-max))
      (insert "hello")))

  ;; Where point is: the message and the offset into its block, or the
  ;; draft and the offset into it.
  (defun mx-place (pos)
    (with-current-buffer buf
      (if (>= pos (elneo-room--input-beg-pos))
          (list 'draft (- pos (elneo-room--input-beg-pos)))
        (let ((id (elneo-room--event-id-enclosing pos)))
          (list id (and id (- pos (car (elneo-room--block-bounds id)))))))))

  (defun mx-goto-in (id offset)
    (with-current-buffer buf
      (goto-char (+ (car (elneo-room--block-bounds id)) offset))))

  (defun mx-history-in-view ()
    (set-window-start (selected-window)
                      (with-current-buffer buf (elneo-room--find-event "$n1"))))

  (unwind-protect
      (progn
        ;; --- a display toggle, history in view ---
        (mx-room)
        (mx-history-in-view)
        (mx-goto-in "$n3" 8)
        (with-current-buffer buf
          (mx-with-stubs (elneo-room-toggle-trust-marks)))
        (mx-check "a toggle keeps point in its message, at its offset"
                  (mx-place (with-current-buffer buf (point))) '("$n3" 8))

        ;; --- a display toggle with the end in view ---
        (mx-room)
        (setq at-end t)
        (mx-goto-in "$n5" 3)
        (with-current-buffer buf
          (mx-with-stubs (elneo-room-toggle-trust-marks)))
        (mx-check "with the end in view point stays off the draft"
                  (mx-place (with-current-buffer buf (point))) '("$n5" 3))

        ;; --- the draft cursor of a window that is not selected ---
        (mx-room)
        (let ((room-win (selected-window)))
          (mx-with-stubs
           (with-current-buffer buf
             (set-window-point room-win (+ (elneo-room--input-beg-pos) 2))))
          (select-window (split-window))
          (switch-to-buffer "*scratch*")
          (with-current-buffer buf
            (mx-with-stubs (elneo-room-toggle-trust-marks)))
          (mx-check "a non-selected window keeps its draft offset"
                    (mx-place (window-point room-win)) '(draft 2))
          (mx-check "and the draft itself survives"
                    (with-current-buffer buf (elneo-room--draft-text))
                    "hello"))

        ;; --- a room shown in no window ---
        (mx-room)
        (mx-goto-in "$n3" 2)
        (switch-to-buffer "*scratch*")
        (with-current-buffer buf
          (mx-with-stubs (elneo-room-toggle-trust-marks)))
        (mx-check "a hidden room keeps point in its message"
                  (mx-place (with-current-buffer buf (point))) '("$n3" 2))

        ;; --- room keys refetch the first page ---
        (mx-room)
        (mx-deliver (mx-older-page))
        (mx-history-in-view)
        (mx-goto-in "$n4" 1)
        (with-current-buffer buf (setq elneo-room--backfilled nil))
        (mx-deliver (mx-newest-page))
        (mx-check "a refetched page keeps point in its message"
                  (mx-place (with-current-buffer buf (point))) '("$n4" 1))

        ;; --- the refetch drops the page point was on ---
        (mx-room)
        (mx-deliver (mx-older-page))
        (mx-goto-in "$o1" 4)
        (with-current-buffer buf (setq elneo-room--backfilled nil))
        (mx-deliver (mx-newest-page))
        (mx-check "a dropped message falls back to the oldest rendered"
                  (mx-place (with-current-buffer buf (point))) '("$n1" 0))

        ;; --- C-c C-r empties the room before its page arrives ---
        (mx-room)
        (mx-goto-in "$n2" 5)
        (with-current-buffer buf
          (mx-with-stubs (elneo-room-refetch)))
        (mx-deliver (mx-newest-page))
        (mx-check "C-c C-r keeps point in its message"
                  (mx-place (with-current-buffer buf (point))) '("$n2" 5))

        ;; --- the first page of a room never rendered: the draft ---
        (when (buffer-live-p buf) (kill-buffer buf))
        (setq buf (get-buffer-create "*mx-redraw-room*"))
        (with-current-buffer buf
          (elneo-room-mode)
          (setq elneo-room--profile "mxtest"
                elneo-room--room-id "!r:mxtest.org")
          (puthash (cons "mxtest" "!r:mxtest.org") buf elneo-room--buffers))
        (switch-to-buffer buf)
        (setq at-end t)
        (mx-deliver (mx-newest-page))
        (mx-check "a first render still opens in the draft"
                  (mx-place (with-current-buffer buf (point))) '(draft 0))

        ;; --- a thread view refilled (room keys) ---
        (let ((thread
               (cl-letf (((symbol-function 'elneo-room-thread-messages) #'ignore)
                         ((symbol-function 'pop-to-buffer) #'ignore))
                 (elneo-thread-open "mxtest" "!r:mxtest.org" "$root")))
              (page (list (cons '@ok t) (cons 'room_id "!r:mxtest.org")
                          (cons 'thread_root "$root")
                          (cons 'root (mx-entry "$root" 1 "the root"))
                          (cons 'messages
                                (vector (mx-entry "$t1" 2 "first reply" "$root")
                                        (mx-entry "$t2" 3 "second reply" "$root")))
                          (cons 'end "tt"))))
          (unwind-protect
              (progn
                (elneo-thread--on-history "mxtest" page)
                (with-current-buffer thread
                  (goto-char (+ (car (elneo-room--block-bounds "$t1")) 3))
                  (setq elneo-room--backfilled nil))
                (elneo-thread--on-history "mxtest" page)
                (with-current-buffer thread
                  (mx-check "a refilled thread view keeps point in its reply"
                            (list (elneo-room--event-id-enclosing (point))
                                  (- (point)
                                     (car (elneo-room--block-bounds "$t1"))))
                            '("$t1" 3))))
            (kill-buffer thread))))
    (when (buffer-live-p buf) (kill-buffer buf)))

  (message "results: %d passed, %d failed" pass fail)
  (kill-emacs (if (zerop fail) 0 1)))
