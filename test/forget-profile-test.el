;;; forget-profile-test.el --- elneo-forget-profile teardown test -*- lexical-binding: t; -*-

;; Batch test: `elneo-forget-profile' must complete its whole teardown
;; when only elneo-client is loaded (elneo-room.el never loaded):
;; elneo-room--buffers is void then, and the Round 2 review found the
;; old (hash-table-p ...) guard referencing it — aborting AFTER the
;; daemon data-dir delete and BEFORE accounts-save, leaving the
;; registration on disk with its session/crypto stores gone.
;;
;; Run: emacs -Q --batch -L lisp -l test/forget-profile-test.el

(require 'elneo-client)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  ;; The precondition of the finding: a valueless defvar declaration
  ;; leaves the variable void, not nil.
  (mx-check "elneo-room--buffers is void when elneo-room never loaded"
            (boundp 'elneo-room--buffers) nil)

  (let* ((accounts-file (make-temp-file "mx-accounts-test"))
         (elneo-account-file accounts-file))
    ;; make-temp-file leaves an empty file behind; accounts-save must be
    ;; the thing that recreates it, so the existence check means
    ;; something.
    (delete-file accounts-file)
    (setq elneo-accounts '(("mxtest-void-guard" . ((user . "x")))))
    (unwind-protect
        (progn
          (mx-check "forget completes (no void-variable abort)"
                    (progn (elneo-forget-profile "mxtest-void-guard"
                                                 'no-confirm)
                           t)
                    t)
          (mx-check "profile dropped from the registry"
                    elneo-accounts nil)
          (mx-check "accounts saved to disk"
                    (file-exists-p accounts-file) t))
      (ignore-errors (delete-file accounts-file))))

  ;; --- elneo-logout-account: the session's local state follows the
  ;;     server logout (rooms announced :removed, buffers killed), the
  ;;     daemon stopped; the registration stays for a re-login.

  ;; The helper on its own, with only elneo-client loaded (the void
  ;; vars guard it the same way they guarded forget).
  (mx-check "logout cleanup completes without elneo-room loaded"
            (progn (elneo--profile-local-cleanup "mxtest-nobody") t)
            t)

  ;; elneo-room is deliberately not loaded here; without a defvar its
  ;; `elneo-room--buffers' is void, and a plain let in this lexical
  ;; file would bind a lexical variable the cleanup helper (dynamic
  ;; scope) can never see.  The bare defvar makes the let special,
  ;; which is what the in-use code path relies on.
  (defvar elneo-room--buffers)

  (setq elneo-accounts '(("mxtest-logout" . ((user . "x")))))
  (let ((elneo--rooms (make-hash-table :test 'equal))
        (elneo-room--buffers (make-hash-table :test 'equal))
        (stopped nil)
        (hooked 0))
    (puthash (cons "mxtest-logout" "!r1")
             (list :profile "mxtest-logout" :room-id "!r1")
             elneo--rooms)
    (let ((room-buf (generate-new-buffer " *mx-logout-room*")))
      (puthash (cons "mxtest-logout" "!r1") room-buf elneo-room--buffers)
      (add-hook 'elneo-room-update-hook
                (lambda (room) (when (plist-get room :removed) (cl-incf hooked))))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'elneo-server--call)
                       (lambda (_p _cmd cb)
                         (funcall cb "mxtest-logout" '((@ok . t)))))
                      ((symbol-function 'elneo-server-stop)
                       (lambda (p) (setq stopped p))))
              (elneo-logout-account "mxtest-logout"))
            (mx-check "logout: the daemon is stopped"
                      (equal stopped "mxtest-logout") t)
            (mx-check "logout: the profile's rooms are announced gone"
                      hooked 1)
            (mx-check "logout: the room registry is pruned"
                      (hash-table-count elneo--rooms) 0)
            (mx-check "logout: the open room buffer is killed"
                      (buffer-live-p room-buf) nil)
            (mx-check "logout: the registration stays (re-login keeps it)"
                      (and (assoc "mxtest-logout" elneo-accounts) t) t))
      ;; A closure is never eq to its own source form; clear the hook
      ;; wholesale instead of remove-hook.
      (setq elneo-room-update-hook nil))))

  (message "results: %d passed, %d failed" pass fail)
  (kill-emacs (if (zerop fail) 0 1)))