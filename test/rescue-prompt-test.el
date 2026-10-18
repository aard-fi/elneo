;;; rescue-prompt-test.el --- the one-time untrusted-session offer -*- lexical-binding: t; -*-

;; The rescue offer: when a profile's daemon reports cross-signing
;; enabled but this session untrusted, Emacs asks once per session
;; whether to enter the recovery key (or open the session-status
;; view).  Everything here is synthetic — no real daemon, no real
;; key material.
;;
;; Run: emacs -Q --batch -L lisp -l test/rescue-prompt-test.el

(require 'elneo-client)
(require 'elneo-verify)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  ;; --- the predicate's truth table

  (let ((elneo-recovery-rescue-offer t)
        (elneo-verify--rescue-asked nil))
    (mx-check "offer: untrusted keys are the offer's case"
              (elneo-verify--rescue-should-offer-p "mxres" t nil) t)
    (mx-check "offer: a trusted session needs nothing"
              (elneo-verify--rescue-should-offer-p "mxres" t t) nil)
    (mx-check "offer: an account that never bootstrapped has nothing to recover with"
              (elneo-verify--rescue-should-offer-p "mxres" nil nil) nil)
    (mx-check "offer: the inverted shape never offers"
              (elneo-verify--rescue-should-offer-p "mxres" nil t) nil))

  (let ((elneo-recovery-rescue-offer nil))
    (mx-check "offer: the defcustom switches it off"
              (elneo-verify--rescue-should-offer-p "mxres" t nil) nil))

  (let ((elneo-recovery-rescue-offer t)
        (elneo-verify--rescue-asked '(("mxres" . t))))
    (mx-check "offer: one ask per profile per Emacs session"
              (elneo-verify--rescue-should-offer-p "mxres" t nil) nil)
    (mx-check "offer: another profile has not been asked yet"
              (elneo-verify--rescue-should-offer-p "mxother" t nil) t))

  ;; --- the hook consumer schedules exactly one deferred ask

  (let ((elneo-recovery-rescue-offer t)
        (elneo-verify--rescue-asked nil)
        mx-timers)
    (cl-letf (((symbol-function 'run-with-timer)
               (lambda (&rest args) (push args mx-timers) (make-symbol "timer"))))
      (elneo-server--on-update-cross-signing-status
       "mxres" '((enabled . t) (trusted . nil)))
      (mx-check "hook: the ask is scheduled for a timer"
                (length mx-timers) 1)
      ;; Repeated trust events (the daemon re-emits at every getSession)
      ;; must not queue more prompts.
      (elneo-server--on-update-cross-signing-status
       "mxres" '((enabled . t) (trusted . nil)))
      (mx-check "hook: still exactly one ask after a re-emit"
                (length mx-timers) 1)
      (mx-check "hook: the profile is marked asked"
                (assoc "mxres" elneo-verify--rescue-asked) '("mxres" . t)))
    ;; A never-bootstrapped account schedules nothing.  (mx-timers
    ;; reset first: the accumulator still holds the earlier section's
    ;; timers.)
    (let ((elneo-verify--rescue-asked nil)
          mx-timers)
      (cl-letf (((symbol-function 'run-with-timer)
                 (lambda (&rest _args) (push 'asked mx-timers) (make-symbol "timer"))))
        (elneo-server--on-update-cross-signing-status
         "mxres" '((enabled . nil) (trusted . nil)))
        (mx-check "hook: no ask for an account without keys"
                  mx-timers nil)))
    ;; A live daemon is re-checked at fire time; the stale case does
    ;; not prompt, so a dead daemon's leftover timer is harmless.
    (when-let* ((entry (assq "mxother" elneo-verify--rescue-asked)))
      (setq elneo-verify--rescue-asked
            (delq entry elneo-verify--rescue-asked))))

  ;; --- the prompt's routing (kept in the dispatcher, testable)

  (let (recover-called status-called)
    (cl-letf (((symbol-function 'elneo-recover-keys)
               (lambda (&rest _) (setq recover-called t)))
              ((symbol-function 'elneo-session-status)
               (lambda (&rest _) (setq status-called t))))
      (elneo-verify--rescue-act "mxres" ?r)
      (mx-check "route: r goes to elneo-recover-keys" recover-called t)
      (mx-check "route: r does not open the status view" status-called nil)
      (setq recover-called nil status-called nil)
      (elneo-verify--rescue-act "mxres" ?v)
      (mx-check "route: v opens the session status view" status-called t)
      (mx-check "route: v does not read the recovery key" recover-called nil)
      (setq recover-called nil status-called nil)
      (elneo-verify--rescue-act "mxres" ?n)
      (mx-check "route: anything else ignores the offer" recover-called nil)
      (mx-check "route: ignoring touches nothing else" status-called nil)))

  ;; --- the session-status hint wording

  (defun mx-status-hint-text (cross-signing)
    (with-current-buffer (generate-new-buffer " *mx-status*")
      (unwind-protect
          (progn
            (rename-buffer "*Matrix Status: mxstat*")
            (let ((elneo-server--sessions
                   '(("mxstat" :user-id "@u:hs" :device-id "CUR"
                      :access-token "t"))))
              (elneo-session-status--render
               "mxstat" cross-signing "enabled"
               ;; ONE device carrying four keys — not four single-pair
               ;; alists (alist-get walks a dotted singleton's string
               ;; tail and errors).
               '((("display_name" . "phone") ("device_id" . "DEV")
                  ("verified" . t) ("is_current" . t)))
               nil))
            (buffer-string))
        (kill-buffer))))
  (let ((text (mx-status-hint-text '(t . nil))))
    (mx-check "status: untrusted session gets the recover-keys hint"
              (and (string-search "elneo-recover-keys" text) t) t)
    (mx-check "status: the hint names the recovery key as existing"
              (and (string-search "existing" text) t) t))
  (let ((text (mx-status-hint-text '(t . t))))
    (mx-check "status: trusted session shows no recover hint"
              (string-search "elneo-recover-keys" text) nil))

  ;; --- the hook registration

  (mx-check "registration: the trust hook carries the rescue consumer"
            (and (member #'elneo-verify--on-trust-rescue elneo-session-trust-hook) t) t)

  (message "%d ok, %d failed" pass fail)
  (when (> fail 0) (kill-emacs 1)))

;;; rescue-prompt-test.el ends here