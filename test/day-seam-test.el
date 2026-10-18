;;; day-seam-test.el --- day separator at the older-page seam -*- lexical-binding: t; -*-

;; Day-separator-at-the-seam test: prepend an older page whose newest
;; message is 23:59 of the day before the rendered page's 00:05 first
;; message.  A separator must appear at the seam.  Plus regression
;; controls: no separator within a same-day page, separator between
;; prepended messages of different days still works.
;;
;; Run: emacs -Q --batch -L lisp -l test/day-seam-test.el

(require 'elneo-room)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected &optional truthy)
    (if (if truthy (and got t) (equal got expected))
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (let ((buf (get-buffer-create " *mx-seam-room*"))
        (ts-seam-new (* 1000 (time-to-seconds
                              (encode-time '(0 5 0 13 10 2026)))))   ; Oct 13 00:05
        (ts-seam-old (* 1000 (time-to-seconds
                              (encode-time '(0 59 23 12 10 2026))))) ; Oct 12 23:59
        (ts-mid      (* 1000 (time-to-seconds
                              (encode-time '(0 30 12 11 10 2026)))))) ; Oct 11 12:30
    (with-current-buffer buf
      (elneo-room-mode)
      (setq elneo-room--profile "mxtest"
            elneo-room--room-id "!r:mxtest.org"
            elneo-room--seen (make-hash-table :test 'equal))
      (puthash (cons "mxtest" "!r:mxtest.org") buf elneo-room--buffers)
      (elneo-room--header (list :display-name "Seam Room"
                                 :room-id "!r:mxtest.org"))
      ;; rendered page: one message, Oct 13 00:05
      (elneo-room--append-messages
       (list (list :event-id "$new" :ts ts-seam-new :sender "@a:mx.org"
                   :is-own nil :msgtype "m.text" :body "seam-new-day message")))
      (elneo-room--reset-input-area "")
      (setq elneo-room--backfilled t)

      ;; 1. day flips exactly at the seam -> separator present
      (elneo-room--prepend-older-page
       (list (list :event-id "$old" :ts ts-seam-old :sender "@a:mx.org"
                   :is-own nil :msgtype "m.text" :body "seam-old-day message"))
       "end-token" nil)
      (goto-char (point-min))
      (mx-check "seam: separator between old 23:59 and new 00:05"
                (and (search-forward "seam-old-day message" nil t)
                     (search-forward (elneo-room--day ts-seam-new) nil t)
                     (search-forward "seam-new-day message" nil t))
                t t)

      ;; 2. same-day prepended message -> no extra separator
      (elneo-room--prepend-older-page
       (list (list :event-id "$same" :ts (- ts-seam-old 60000) :sender "@a:mx.org"
                   :is-own nil :msgtype "m.text" :body "seam-same-day message"))
       "end-token" nil)
      (goto-char (point-min))
      (let ((count 0))
        (save-excursion
          (while (search-forward
                  (propertize (elneo-room--day ts-seam-new)
                               'face 'elneo-room-day-separator)
                  nil t)
            (cl-incf count)))
        (mx-check "seam: same-day prepend adds no second separator" count 1))

      ;; 3. per-message path: two prepended messages on different days
      ;; (Oct 11 then Oct 12) -> separator between them AND at the seam
      (elneo-room--prepend-older-page
       (list (list :event-id "$m1" :ts ts-mid :sender "@a:mx.org"
                   :is-own nil :msgtype "m.text" :body "mid-oct-11 message")
             (list :event-id "$m2" :ts ts-seam-old :sender "@a:mx.org"
                   :is-own nil :msgtype "m.text" :body "late-oct-12 message"))
       "end-token" nil)
      (goto-char (point-min))
      (mx-check "per-message: Oct12 separator between Oct11 and Oct12 messages"
                (and (search-forward "mid-oct-11 message" nil t)
                     (search-forward (elneo-room--day ts-seam-old) nil t)
                     (search-forward "late-oct-12 message" nil t))
                t t)))

  (message "results: %d passed, %d failed" pass fail)
  (kill-emacs (if (zerop fail) 0 1)))