;;; new-message-point-test.el --- point when a message arrives in view -*- lexical-binding: t; -*-

;; A message arriving while the room's window shows its end moves point
;; on a message into the draft under `elneo-room-point-on-new-message'
;; `draft', and leaves it, and the window, alone under `keep'.  Point in
;; the draft stays put and the window scrolls under either value.
;; Batch Emacs never redisplays, so whether a window shows the buffer's
;; end is stated rather than computed.
;;
;; Run: emacs -Q --batch -L lisp -l test/new-message-point-test.el

(require 'cl-lib)
(require 'elneo-room)

(let ((pass 0) (fail 0)
      (n 0)
      (scrolls 0)
      buf)
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defun mx-entry (id ts body)
    (list (cons 'event_id id) (cons 'sender "@a:mx.org")
          (cons 'body body) (cons 'ts ts) (cons 'msgtype "m.text")))

  (defmacro mx-with-stubs (&rest body)
    `(cl-letf (((symbol-function 'elneo-room-messages) #'ignore)
               ((symbol-function 'elneo-room-receipts) #'ignore)
               ((symbol-function 'elneo-room-mark-read) #'ignore)
               ((symbol-function 'elneo-server-live-p) (lambda (_p) t))
               ((symbol-function 'elneo-room--window-at-end-p)
                (lambda (_w) t)))
       ,@body))

  ;; A room of four messages shown in the selected window, its end in
  ;; view, with "hello" in the draft.
  (defun mx-room ()
    (when (buffer-live-p buf) (kill-buffer buf))
    (delete-other-windows)
    (setq buf (get-buffer-create "*mx-new-message-room*"))
    (with-current-buffer buf
      (elneo-room-mode)
      (setq elneo-room--profile "mxtest"
            elneo-room--room-id "!r:mxtest.org")
      (puthash (cons "mxtest" "!r:mxtest.org") buf elneo-room--buffers))
    (switch-to-buffer buf)
    (mx-with-stubs
     (elneo-room--on-history
      "mxtest"
      (list (cons '@ok t) (cons 'room_id "!r:mxtest.org")
            (cons 'messages
                  (vconcat (cl-loop for i from 1 to 4
                                    collect (mx-entry (format "$n%d" i)
                                                      (+ 100000 i)
                                                      (format "message %d" i)))))
            (cons 'end "t0"))))
    (with-current-buffer buf
      (goto-char (point-max))
      (insert "hello")))

  (defun mx-arrive ()
    (cl-incf n)
    (let ((show-end (symbol-function 'elneo-room--show-end)))
      (mx-with-stubs
       (cl-letf (((symbol-function 'elneo-room--show-end)
                  (lambda (&rest args)
                    (cl-incf scrolls)
                    (apply show-end args))))
         (elneo-room--on-new-message
          (list :profile "mxtest" :room-id "!r:mxtest.org"
                :event-id (format "$new%d" n) :sender "@b:mx.org"
                :sender-name "B" :ts (+ 200000 n) :msgtype "m.text"
                :body (format "arrived %d" n)))))))

  (defun mx-place ()
    (with-current-buffer buf
      (if (>= (point) (elneo-room--input-beg-pos))
          (list 'draft (- (point) (elneo-room--input-beg-pos)))
        (let ((id (elneo-room--event-id-enclosing (point))))
          (list id (- (point) (car (elneo-room--block-bounds id))))))))

  (defun mx-goto-in (id offset)
    (with-current-buffer buf
      (goto-char (+ (car (elneo-room--block-bounds id)) offset))))

  (unwind-protect
      (progn
        ;; --- `draft', the default: point on a message goes to the draft ---
        (mx-room)
        (mx-goto-in "$n3" 2)
        (setq scrolls 0)
        (mx-arrive)
        (mx-check "draft: point on a message moves to the draft's end"
                  (mx-place) '(draft 5))
        (mx-check "draft: the window scrolls" scrolls 1)

        (let ((elneo-room-point-on-new-message 'keep))
          ;; --- `keep': point on a message stays, the window too ---
          (mx-room)
          (mx-goto-in "$n3" 2)
          (let ((first (with-current-buffer buf
                         (car (elneo-room--block-bounds "$n1")))))
            (set-window-start (selected-window) first)
            (setq scrolls 0)
            (mx-arrive)
            (mx-check "keep: point stays in its message, at its offset"
                      (mx-place) '("$n3" 2))
            (mx-check "keep: the window does not scroll" scrolls 0)
            (mx-check "keep: the window still starts at the first message"
                      (window-start) first))
          (with-current-buffer buf
            (mx-check "keep: the new message is appended"
                      (and (elneo-room--find-event "$new2") t) t)
            (let ((last-command-event ?r))
              (call-interactively (key-binding "r")))
            (mx-check "keep: r after the arrival replies to the message"
                      (list elneo-room--reply-to (elneo-room--draft-text))
                      '("$n3" "hello")))

          ;; --- `keep': point in the draft stays and the window scrolls ---
          (mx-room)
          (with-current-buffer buf
            (goto-char (+ (elneo-room--input-beg-pos) 2)))
          (setq scrolls 0)
          (mx-arrive)
          (mx-check "keep: point in the draft stays at its offset"
                    (mx-place) '(draft 2))
          (mx-check "keep: with point in the draft the window scrolls"
                    scrolls 1)))
    (when (buffer-live-p buf)
      (kill-buffer buf)))

  (message "results: %d passed, %d failed" pass fail)
  (kill-emacs (if (zerop fail) 0 1)))
