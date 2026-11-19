;;; jump-search-test.el --- how a reply jump's search ends -*- lexical-binding: t; -*-

;; RET on a quote whose parent is not loaded searches older pages.
;; The search fetches at most `elneo-room-jump-page-limit' pages, and
;; a page that fails to load ends it, in a room and in a thread view.
;; Pages and failures arrive through the handlers the daemon's
;; responses take — no daemon.
;;
;; Run: emacs -Q --batch -L lisp -l test/jump-search-test.el

(require 'cl-lib)
(require 'elneo-room)
(require 'elneo-thread)

(let ((pass 0) (fail 0)
      (requests nil)
      (said nil)
      buf)
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defun mx-entry (id ts body)
    (list (cons 'event_id id) (cons 'sender "@a:mx.org") (cons 'body body)
          (cons 'ts ts) (cons 'msgtype "m.text")))

  ;; An `updateRoomMessages' page of one message older than TS, or the
  ;; parent itself with PARENT-P.
  (defun mx-page (ts end &optional parent-p)
    (list (cons '@ok t) (cons 'room_id "!r:mxtest.org")
          (cons 'messages
                (vector (if parent-p
                            (mx-entry "$parent" ts "the parent")
                          (mx-entry (format "$f%d" ts) ts "filler"))))
          (cons 'end end)))

  (defun mx-room ()
    (when (buffer-live-p buf) (kill-buffer buf))
    (setq buf (get-buffer-create "*mx-search-room*")
          requests nil)
    (with-current-buffer buf
      (elneo-room-mode)
      (setq elneo-room--profile "mxtest"
            elneo-room--room-id "!r:mxtest.org"
            elneo-room--seen (make-hash-table :test 'equal))
      (puthash (cons "mxtest" "!r:mxtest.org") buf elneo-room--buffers)
      (elneo-room--header (list :display-name "Search Room"
                                :room-id "!r:mxtest.org"))
      (elneo-room--append-messages
       (list (list :event-id "$reply" :ts 100000 :sender "@a:mx.org"
                   :is-own nil :msgtype "m.text" :body "the reply"
                   :reply-to "$parent")))
      (elneo-room--reset-input-area "")
      (setq elneo-room--backfilled t
            elneo-room--end-token "t0")))

  (defmacro mx-quietly (&rest body)
    "Run BODY with the daemon stubbed and echo-area messages collected."
    `(cl-letf (((symbol-function 'elneo-room-messages)
                (lambda (_p _room _limit from _cb) (push from requests)))
               ((symbol-function 'message)
                (lambda (fmt &rest args)
                  (push (apply #'format fmt args) said))))
       ,@body))

  (defun mx-deliver (page)
    (mx-quietly (elneo-room--on-history "mxtest" page)))

  (unwind-protect
      (progn
        ;; --- the page limit counts every page fetched ---
        (mx-room)
        (let ((elneo-room-jump-page-limit 3))
          (with-current-buffer buf
            (mx-quietly (elneo-room--jump-to-reply "$parent")))
          (dotimes (i 3)
            (mx-deliver (mx-page (- 90000 i) (format "t%d" (1+ i)))))
          (mx-check "a limit of 3 fetches 3 pages"
                    (length requests) 3)
          (mx-check "and then the search has ended"
                    (with-current-buffer buf elneo-room--jump-target) nil)
          (mx-check "saying so"
                    (car said)
                    "Matrix: could not find the referenced message in nearby history"))

        ;; --- a failed page ends the search ---
        (mx-room)
        (setq said nil)
        (with-current-buffer buf
          (mx-quietly (elneo-room--jump-to-reply "$parent"))
          (mx-quietly
           (elneo-room--history-failed
            (list (cons '@ok nil) (cons '@error "boom"))))
          (mx-check "a failed page ends the search" elneo-room--jump-target nil)
          (goto-char (point-max)))
        ;; A page loaded later, by PageUp say, holds the parent: the
        ;; ended search must not land on it.
        (mx-deliver (mx-page 80000 "t9" t))
        (mx-check "a later page does not resume the search"
                  (with-current-buffer buf
                    (elneo-room--event-id-enclosing (point)))
                  nil)

        ;; --- a thread view's failed page ends its search too ---
        (let ((thread
               (cl-letf (((symbol-function 'elneo-room-thread-messages) #'ignore)
                         ((symbol-function 'pop-to-buffer) #'ignore))
                 (elneo-thread-open "mxtest" "!r:mxtest.org" "$root"))))
          (unwind-protect
              (with-current-buffer thread
                (setq elneo-room--backfilled t
                      elneo-room--jump-target "$parent"
                      said nil)
                (mx-quietly
                 (elneo-thread--page-failed
                  (list (cons '@ok nil) (cons '@error "boom"))))
                (mx-check "a failed thread page ends the search"
                          elneo-room--jump-target nil))
            (kill-buffer thread))))
    (when (buffer-live-p buf) (kill-buffer buf)))

  (message "results: %d passed, %d failed" pass fail)
  (kill-emacs (if (zerop fail) 0 1)))
