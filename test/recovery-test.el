;;; recovery-test.el --- the recovery-key display and the background enable -*- lexical-binding: t; -*-

;; The `recoveryEnabled' display: `elneo-verify--show-recovery-key'
;; renders the once-shown key plus, where the daemon stored its copy
;; (protocol 17's `stored_path'), the data-dir's 0600 note.  The
;; daemon's background bring-up for a first-time account emits the
;; event untagged; the client-layer handler picks it up like the
;; manual `enableRecovery' response.  All batch, no real daemon.
;;
;; Run: emacs -Q --batch -L lisp -l test/recovery-test.el

(require 'elneo-client)
(require 'elneo-verify)

(let ((pass 0) (fail 0))
  (defvar mx--shown)
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  ;; --- the display, the daemon's copy noted

  (cl-letf (((symbol-function 'pop-to-buffer) (lambda (buffer &rest _) buffer)))
    (elneo-verify--show-recovery-key "mxrec" "KEY12"
                                     "/x/elneo/mxrec/recovery-key")
    (let ((text (with-current-buffer "*Matrix recovery key: mxrec*"
                  (buffer-string))))
      (mx-check "show: the key itself is there"
                (and (string-search "KEY12" text) t) t)
      (mx-check "show: shown-once is said"
                (and (string-search "It is shown only this once." text) t) t)
      (mx-check "show: the stored copy and its 0600 note"
                (and (string-search "/x/elneo/mxrec/recovery-key" text)
                     (string-search "0600" text)
                     t)
                t)
      (mx-check "show: an off-machine safe copy is asked for"
                (and (string-search "the safe copy is the one only you hold" text) t) t))

    ;; --- no stored copy (storing failed): the old wording

    (elneo-verify--show-recovery-key "mxrec" "KEY12" nil)
    (let ((text (with-current-buffer "*Matrix recovery key: mxrec*"
                  (buffer-string))))
      (mx-check "show: unstored copy is said"
                (and (string-search "It is not stored anywhere." text) t) t)
      (mx-check "show: no data-dir note without a path"
                (string-search "0600" text) nil)))

  ;; --- the untagged event handler

  (cl-letf (((symbol-function 'elneo-verify--show-recovery-key)
             (lambda (profile key stored)
               (setq mx--shown (list profile key stored)))))
    (setq mx--shown nil)
    (elneo-client--on-recovery-enabled
     "mxrec" '((recovery_key . "K9") (stored_path . "/d/rk")))
    (mx-check "handler: passes key and stored path on"
              mx--shown '("mxrec" "K9" "/d/rk"))
    (setq mx--shown 'untouched)
    (elneo-client--on-recovery-enabled "mxrec" '((stored_path . "/d/rk")))
    (mx-check "handler: no key leaves the buffer count untouched"
              mx--shown 'untouched))

  ;; --- the handler is registered for the spontaneous event

  (elneo-client--register-handlers "mxrec")
  (mx-check "registration: recoveryEnabled handler registered"
            (gethash "recoveryEnabled" (elneo-server--get-callbacks "mxrec"))
            #'elneo-client--on-recovery-enabled)

  ;; --- the protocol-21 senders' payload shapes (synthetic constant)

  (let (sent)
    (cl-letf (((symbol-function 'elneo-server--call)
               (lambda (_p payload _cb) (setq sent payload))))
      (elneo-verification-rotate-recovery-key "mxrec" nil)
      (mx-check "rotate sender: no old key ships by default"
                sent '((@type . "rotateRecoveryKey")))
      (elneo-verification-rotate-recovery-key "mxrec" nil "OLDDK")
      (mx-check "rotate sender: the old key rides along when given"
                sent '((@type . "rotateRecoveryKey") (old_key . "OLDDK")))
      (elneo-verification-disable-recovery "mxrec" nil)
      (mx-check "disable sender: the bare disable payload"
                sent '((@type . "disableRecovery")))))

  ;; --- the protocol lockstep

  (mx-check "lockstep: the protocol constant is 25" elneo-daemon-protocol 25)

  (message "%d ok, %d failed" pass fail)
  (when (> fail 0) (kill-emacs 1)))

;;; recovery-test.el ends here