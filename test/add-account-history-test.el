;;; add-account-history-test.el --- the password stays out of command-history -*- lexical-binding: t; -*-

;; `call-interactively' records the values of an `interactive' form in
;; `command-history', and `savehist-mode' writes that list to disk.
;; `elneo-add-account' therefore reads the password in its body.  The
;; prompts, the daemon and the account file are all stubbed.
;;
;; Run: emacs -Q --batch -L lisp -l test/add-account-history-test.el

(require 'elneo-client)
;; Loaded now, so that the stubs below are not replaced when
;; `elneo-add-account' requires them.
(require 'elneo-room-bar)
(require 'elneo-verify)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (let ((elneo-accounts nil)
        (requests nil)
        (password-prompts 0))
    (cl-letf (((symbol-function 'elneo--accounts-load) (lambda ()))
              ((symbol-function 'elneo--accounts-save) (lambda ()))
              ((symbol-function 'elneo-server--preflight-binary)
               (lambda (_p) "/usr/bin/elneo-server"))
              ((symbol-function 'elneo--session-exists-p) (lambda (_p) nil))
              ((symbol-function 'read-string)
               (lambda (prompt &rest _)
                 (pcase prompt
                   ("Profile name: " "mxhistory")
                   ("Homeserver: " "https://mx.test")
                   (_ "tester"))))
              ((symbol-function 'read-passwd)
               (lambda (&rest _) (cl-incf password-prompts) "s3cret"))
              ((symbol-function 'elneo-server-live-p) (lambda (_p) t))
              ((symbol-function 'elneo-server-start) (lambda (_p)))
              ((symbol-function 'elneo-client--register-handlers) (lambda (_p)))
              ((symbol-function 'elneo-server--call)
               (lambda (_p request _cb) (push request requests)))
              ((symbol-function 'elneo-room-bar-show) (lambda ())))

      ;; As M-x runs it: RECORD-FLAG non-nil records the call.
      (setq command-history nil)
      (call-interactively #'elneo-add-account t)
      (mx-check "the password is nowhere in command-history"
                (string-search "s3cret" (format "%S" command-history))
                nil)
      (mx-check "the recorded call holds no password argument"
                (car command-history)
                '(elneo-add-account "mxhistory" "https://mx.test" "tester"))
      (mx-check "the password was asked for once"
                password-prompts 1)
      (mx-check "the login request still carries the password"
                (alist-get 'password (car requests))
                "s3cret")

      ;; A call from Lisp that passes the password is not asked again.
      (setq password-prompts 0 requests nil)
      (elneo-add-account "mxlisp" "https://mx.test" "tester" "given")
      (mx-check "a given password is not asked for"
                password-prompts 0)
      (mx-check "a given password reaches the login request"
                (alist-get 'password (car requests))
                "given")))

  (message "results: %d passed, %d failed" pass fail)
  (when (> fail 0) (kill-emacs 1)))
