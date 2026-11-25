;;; older-page-point-test.el --- point across older history pages -*- lexical-binding: t; -*-

;; An older page lands above what the reader is on.  Auto-load and
;; reply jumps keep point, in the buffer and in every window, on the
;; text it was on; PageUp / M-< move it up into the page.  A reply
;; jump that lands marks where RET was pressed.  Pages arrive through
;; `elneo-room--on-history', the path daemon pages take — no daemon.
;; Batch Emacs never redisplays, so whether a window shows the
;; buffer's end is stated rather than computed.
;;
;; Run: emacs -Q --batch -L lisp -l test/older-page-point-test.el

(require 'cl-lib)
(require 'elneo-room)

(let ((pass 0) (fail 0)
      (requests nil)
      (at-end t)
      buf)
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defun mx-msg (id ts body &optional reply-to)
    (list :event-id id :ts ts :sender "@a:mx.org" :is-own nil
          :msgtype "m.text" :body body :reply-to reply-to))

  (defun mx-entry (id ts body)
    (list (cons 'event_id id) (cons 'sender "@a:mx.org") (cons 'body body)
          (cons 'ts ts) (cons 'msgtype "m.text")))

  ;; An `updateRoomMessages' page of N filler messages older than TS,
  ;; with PARENT-P adding the parent as its oldest entry.
  (defun mx-page (ts n end &optional parent-p)
    (list (cons '@ok t) (cons 'room_id "!r:mxtest.org")
          (cons 'messages
                (vconcat
                 (when parent-p
                   (list (mx-entry "$parent" (- ts n 1) "the parent")))
                 (cl-loop for i from n downto 1
                          collect (mx-entry (format "$f%d-%d" ts i) (- ts i)
                                            (format "filler %d-%d" ts i)))))
          (cons 'end end)))

  ;; A room in the selected window, the end of its history in view,
  ;; the last message a reply to the unloaded "$parent", point on its
  ;; quote.
  (defun mx-room ()
    (when (buffer-live-p buf) (kill-buffer buf))
    (delete-other-windows)
    (setq buf (get-buffer-create "*mx-jump-room*")
          requests nil)
    (with-current-buffer buf
      (elneo-room-mode)
      (setq elneo-room--profile "mxtest"
            elneo-room--room-id "!r:mxtest.org"
            elneo-room--seen (make-hash-table :test 'equal))
      (puthash (cons "mxtest" "!r:mxtest.org") buf elneo-room--buffers)
      (elneo-room--header (list :display-name "Jump Room"
                                :room-id "!r:mxtest.org"))
      (elneo-room--append-messages
       (append (cl-loop for i from 1 to 5
                        collect (mx-msg (format "$n%d" i) (+ 100000 i)
                                        (format "newer %d" i)))
               (list (mx-msg "$reply" 100010 "the reply" "$parent"))))
      (elneo-room--reset-input-area "")
      (setq elneo-room--backfilled t
            elneo-room--end-token "t0"))
    (switch-to-buffer buf)
    (elneo-room--show-end (selected-window))
    (with-current-buffer buf
      (goto-char (point-max))
      (search-backward "older message")))

  (defmacro mx-with-daemon (&rest body)
    `(cl-letf (((symbol-function 'elneo-room-messages)
                (lambda (_p _room _limit from _cb) (push from requests))))
       ,@body))

  (defun mx-ret ()
    (with-current-buffer buf
      (mx-with-daemon (elneo-room--ret))))

  (defun mx-deliver (page)
    (cl-letf (((symbol-function 'elneo-room--window-at-end-p)
               (lambda (_w) at-end)))
      (mx-with-daemon (elneo-room--on-history "mxtest" page))))

  (defun mx-line-at (pos)
    (with-current-buffer buf
      (save-excursion
        (goto-char pos)
        (buffer-substring-no-properties pos (line-end-position)))))

  (unwind-protect
      (progn
        ;; --- a jump paging with the end in view, then with history ---
        (dolist (history-p '(nil t))
          (let ((what (if history-p "history in view" "end in view")))
            (mx-room)
            (setq at-end (not history-p))
            (when history-p
              (set-window-start (selected-window)
                                (with-current-buffer buf
                                  (elneo-room--find-event "$n1"))))
            (let ((start-line (mx-line-at (window-start))))
              (mx-ret)
              (mx-check (format "%s: RET asks for an older page" what)
                        requests '("t0"))
              (dotimes (i 3)
                (mx-deliver (mx-page (- 90000 (* i 1000)) 10
                                     (format "t%d" (1+ i))))
                (mx-check (format "%s: point on the quote after page %d"
                                  what (1+ i))
                          (with-current-buffer buf
                            (and (get-text-property (point)
                                                    'elneo-room-reply-target)
                                 t))
                          t))
              (mx-check (format "%s: the window keeps its first line" what)
                        (mx-line-at (window-start)) start-line))))

        (setq at-end t)

        ;; --- the room in a window that is not selected ---
        (mx-room)
        (let ((room-win (selected-window)))
          (with-current-buffer buf
            (mx-with-daemon (elneo-room--jump-to-reply "$parent")))
          (select-window (split-window))
          (switch-to-buffer "*scratch*")
          (with-current-buffer buf (goto-char (point-min)))
          (let ((line (mx-line-at 1)))
            (mx-deliver (mx-page 90000 10 "t1"))
            (mx-check "a non-selected window's point stays on the quote"
                      (with-current-buffer buf
                        (and (get-text-property (window-point room-win)
                                                'elneo-room-reply-target)
                             t))
                      t)
            (mx-check "the buffer's own point stays on its text"
                      (with-current-buffer buf (mx-line-at (point)))
                      line)))

        ;; --- the room shown nowhere ---
        (mx-room)
        (mx-ret)
        (switch-to-buffer "*scratch*")
        (mx-deliver (mx-page 90000 10 "t1"))
        (mx-check "a hidden room keeps point on the quote"
                  (with-current-buffer buf
                    (and (get-text-property (point) 'elneo-room-reply-target)
                         t))
                  t)

        ;; --- point exactly where the page goes in (M-< mid-jump) ---
        (mx-room)
        (mx-ret)
        (with-current-buffer buf
          (goto-char (point-min)))
        (let ((line (mx-line-at 1)))
          (mx-deliver (mx-page 90000 10 "t1"))
          (mx-check "point at the top stays on its text below the page"
                    (with-current-buffer buf (mx-line-at (point)))
                    line)
          (mx-check "and the page went in above it"
                    (with-current-buffer buf (> (point) 1))
                    t))

        ;; --- auto-load, no jump: a reader on a message stays there ---
        (mx-room)
        (set-window-start (selected-window)
                          (with-current-buffer buf
                            (elneo-room--find-event "$n1")))
        (with-current-buffer buf
          (setq elneo-room--older-mode 'anchor)
          (goto-char (elneo-room--find-event "$n3")))
        (setq at-end nil)
        (mx-deliver (mx-page 90000 10 "t1"))
        (setq at-end t)
        (mx-check "auto-load leaves point on its message"
                  (with-current-buffer buf
                    (elneo-room--event-id-enclosing (point)))
                  "$n3")

        ;; --- PageUp still moves into the fresh page ---
        (mx-room)
        (with-current-buffer buf
          (setq elneo-room--older-mode 'scroll)
          (goto-char (elneo-room--find-event "$n3")))
        (mx-deliver (mx-page 90000 10 "t1"))
        (mx-check "PageUp puts point in the older page"
                  (with-current-buffer buf
                    (< (point) (elneo-room--find-event "$n1")))
                  t)

        ;; --- the parent arrives on the second page, the reader moved ---
        (mx-room)
        (let ((quote-pos (with-current-buffer buf (point-marker))))
          (mx-ret)
          (mx-deliver (mx-page 90000 10 "t1"))
          (with-current-buffer buf
            (goto-char (elneo-room--find-event "$n2")))
          (mx-deliver (mx-page 80000 10 "t2" t))
          (with-current-buffer buf
            (mx-check "the landing puts point on the parent"
                      (elneo-room--event-id-enclosing (point)) "$parent")
            (mx-check "the mark holds the quote RET was pressed on"
                      (mark t) (marker-position quote-pos))))

        ;; --- the parent is already drawn: no page, mark on the quote ---
        (with-current-buffer buf
          (goto-char (point-max))
          (search-backward "older message")
          (let ((quote-pos (point)))
            (setq requests nil)
            (mx-ret)
            (mx-check "a drawn parent needs no page" requests nil)
            (mx-check "a direct jump lands on the parent"
                      (elneo-room--event-id-enclosing (point)) "$parent")
            (mx-check "a direct jump marks the quote"
                      (mark t) quote-pos))))
    (when (buffer-live-p buf) (kill-buffer buf)))

  (message "results: %d passed, %d failed" pass fail)
  (kill-emacs (if (zerop fail) 0 1)))
