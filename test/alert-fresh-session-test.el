;;; alert-fresh-session-test.el --- alert hook with the room module unloaded -*- lexical-binding: t; -*-

;; elneo-alert loads behind `alert' and `elneo-client' alone, but its
;; `elneo-new-message-hook' consumer looks up the live room buffer —
;; which lives in elneo-room, a module only loaded when a room or a
;; thread is opened.  In a fresh session (no rooms open, only the bar
;; — or not even that) the first live updateNewMessage fired the hook
;; into `elneo-room--buffer-for': void-function.  The lookups are
;; fboundp-guarded now, like the bar's (`elneo-alert--bar-visible-p')
;; already was; this suite pins the fresh-session behavior by loading
;; elneo-alert WITHOUT elneo-room and firing the hook.
;;
;; Run: emacs -Q --batch -L lisp -l test/alert-fresh-session-test.el

(require 'elneo-client)

;; `elneo-alert' (require)s alert.el, absent from batch -Q; the stub
;; path never calls into alert machinery — the single `alert' call is
;; stubbed below.
(unless (featurep 'alert) (provide 'alert))

(require 'elneo-alert)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  ;; The precondition is the bug: the room module must be absent.
  (mx-check "the room module is unloaded" (featurep 'elneo-room) nil)
  (mx-check "the room-buffer lookup is guarded"
            (elneo-alert--room-buffer "p" "!r:hs") nil)

  ;; The consumer fires end to end with elneo-room absent: no
  ;; void-function, one stubbed alert delivery.
  (let ((alerts 0))
    (cl-letf (((symbol-function 'alert)
               (lambda (&rest _args) (cl-incf alerts))))
      (condition-case err
          (elneo-alert--on-new-message
           (list :profile "p" :room-id "!r:hs" :event-id "$fresh1"
                 :sender "@s:hs" :sender-name "S" :body "hello"
                 :msgtype "m.text" :ts 100 :is-own nil))
        (error (cl-incf fail)
               (message "FAIL: hook consumer signaled: %S" err)))
      (mx-check "the hook fires without the room module" alerts 1)))

  ;; The same through the client dispatch, the wire's entry point.
  (let ((alerts 0))
    (cl-letf (((symbol-function 'alert)
               (lambda (&rest _args) (cl-incf alerts))))
      (condition-case err
          (elneo-client--on-update-new-message
           "p" '((room_id . "!r:hs")
                 (event_id . "$fresh2")
                 (sender . "@s:hs")
                 (body . "second")
                 (msgtype . "m.text")
                 (ts . 101)))
        (error (cl-incf fail)
               (message "FAIL: dispatch signaled: %S" err)))
      (mx-check "the updateNewMessage dispatch stays intact" alerts 1)))

  (message "results: %d passed, %d failed" pass fail)
  (when (> fail 0) (kill-emacs 1)))