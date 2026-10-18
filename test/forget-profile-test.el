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
         (elneo-account-file accounts-file)
         ;; A temp user-emacs-directory keeps the load's copy-migration
         ;; from finding (and importing!) the real pre-rename accounts
         ;; file on this machine.
         (user-emacs-directory (make-temp-file "mx-emacs-dir" t)))
    ;; The command itself loads `elneo-account-file' now (the stale-
    ;; session path wants the homeserver); a temp file keeps the user's
    ;; real registrations out of the test's view.
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

  ;; The nudge guard is profile-local state too: a `q' answered and
  ;; then a forget or logout must not keep the re-added profile name
  ;; silent for the rest of the session.
  (setq elneo-client--verification-nudged '(("mxtest-nobody" . t)))
  (elneo--profile-local-cleanup "mxtest-nobody")
  (mx-check "cleanup clears the nudged-guard entry"
            (assoc "mxtest-nobody" elneo-client--verification-nudged) nil)

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

  ;; --- forget: the daemon's logout is acked BEFORE anything dies ---
  ;; Round N: the old code fired the logout and immediately deleted the
  ;; process, so the HTTP round trip never reached the homeserver — the
  ;; token stayed valid and the device record lived on.  The teardown
  ;; must run only after the logout is confirmed (or bounded).

  (let* ((accounts-file (make-temp-file "mx-accounts-test"))
         (elneo-account-file accounts-file)
         (user-emacs-directory (make-temp-file "mx-emacs-dir" t))
         (trace nil)
         (cb-saved nil)
         (waits 0))
    (delete-file accounts-file)
    (setq elneo-accounts '(("mxtest-live" . ((user . "x")))))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'elneo-server-live-p) (lambda (_p) t))
                    ((symbol-function 'elneo-server--get-process)
                     (lambda (_p) 'fake-daemon-proc))
                    ((symbol-function 'elneo-server--call)
                     (lambda (_p cmd cb)
                       (setq trace (cons (cdr (assq '@type cmd)) trace))
                       (setq cb-saved cb)))
                    ;; The fake daemon answers the logout on the second
                    ;; serve cycle — strictly after the wait began.
                    ((symbol-function 'accept-process-output)
                     (lambda (&optional _proc _secs)
                       (cl-incf waits)
                       (when (= waits 2)
                         (setq trace (cons 'logout-acked trace))
                         (funcall cb-saved "mxtest-live" '((@ok . t))))
                       t))
                    ((symbol-function 'elneo-server-stop)
                     (lambda (p) (setq trace (cons 'stopped trace))))
                    ((symbol-function 'elneo-server--flush-pending)
                     (lambda (_p _reason) nil)))
            (elneo-forget-profile "mxtest-live" 'no-confirm))
          ;; The trace conses each step, so `(car trace)' is the
          ;; newest: stop last means the wait held everything back.
          (mx-check "live forget: logout on the wire"
                    (and (member "logout" trace) t) t)
          (mx-check "live forget: ack lands before the stop"
                    (and (equal (car trace) 'stopped)
                         (member 'logout-acked trace)
                         t)
                    t)
          (mx-check "live forget: the wait actually served the process"
                    (> waits 0) t)
          (mx-check "live forget: registration dropped"
                    (assoc "mxtest-live" elneo-accounts) nil))
      (ignore-errors (delete-file accounts-file))))

  ;; --- forget with a dead daemon: the stored token gets invalidated
  ;; directly via the homeserver, before the data directory goes.

  (let* ((accounts-file (make-temp-file "mx-accounts-test"))
         (elneo-account-file accounts-file)
         (user-emacs-directory (make-temp-file "mx-emacs-dir" t))
         (data-dir (make-temp-file "mx-data" t))
         (requests nil))
    (delete-file accounts-file)
    (setq elneo-accounts '(("mxtest-stale" . (:homeserver "https://hs.example"))))
    (with-temp-buffer
      (insert "{\"meta\": {\"user_id\": \"@u:hs\", \"device_id\": \"DEV\"},"
              " \"tokens\": {\"access_token\": \"syt_test\", "
              "\"refresh_token\": null}}")
      (write-file (expand-file-name "session.json" data-dir) nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'elneo-server-live-p) (lambda (_p) nil))
                    ((symbol-function 'elneo-server-stop) (lambda (_p) nil))
                    ((symbol-function 'elneo--daemon-data-dir)
                     (lambda (_p) data-dir))
                    ((symbol-function 'url-retrieve-synchronously)
                     (lambda (url)
                       (setq requests
                             (list :url url
                                   :headers url-request-extra-headers
                                   :method url-request-method))
                       (with-current-buffer
                           (generate-new-buffer " *mx-http-fake*")
                         (insert "HTTP/1.1 200 OK\r\nContent-Type: \
application/json\r\n\r\n{}")
                         (current-buffer)))))
            (elneo-forget-profile "mxtest-stale" 'no-confirm))
          (mx-check "stale forget: the homeserver logout endpoint was hit"
                    (plist-get requests :url)
                    "https://hs.example/_matrix/client/v3/logout")
          (mx-check "stale forget: the bearer token rode along"
                    (member '("Authorization" . "Bearer syt_test")
                            (plist-get requests :headers))
                    '(("Authorization" . "Bearer syt_test")))
          (mx-check "stale forget: POST, not GET"
                    (plist-get requests :method) "POST")
          (mx-check "stale forget: the data directory is gone"
                    (file-exists-p data-dir) nil)
          (mx-check "stale forget: registration dropped"
                    (assoc "mxtest-stale" elneo-accounts) nil))
      (ignore-errors (delete-directory data-dir 'recursive))
      (ignore-errors (delete-file accounts-file))))

  ;; --- forget with a dead daemon but no homeserver on record:
  ;; nothing is sent, the teardown still completes.

  (let* ((accounts-file (make-temp-file "mx-accounts-test"))
         (elneo-account-file accounts-file)
         (user-emacs-directory (make-temp-file "mx-emacs-dir" t))
         (data-dir (make-temp-file "mx-data" t))
         (requests nil))
    (delete-file accounts-file)
    (setq elneo-accounts '(("mxtest-homeserverless" . ((user . "x")))))
    (with-temp-buffer
      (insert "{\"tokens\": {\"access_token\": \"syt_orphan\"}}")
      (write-file (expand-file-name "session.json" data-dir) nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'elneo-server-live-p) (lambda (_p) nil))
                    ((symbol-function 'elneo-server-stop) (lambda (_p) nil))
                    ((symbol-function 'elneo--daemon-data-dir)
                     (lambda (_p) data-dir))
                    ((symbol-function 'url-retrieve-synchronously)
                     (lambda (&rest _)
                       (setq requests 'sent)
                       (generate-new-buffer " *mx-http-fake*"))))
            (elneo-forget-profile "mxtest-homeserverless" 'no-confirm))
          (mx-check "no homeserver on record: nothing is sent"
                    requests nil)
          (mx-check "no homeserver on record: teardown completed"
                    (and (assoc "mxtest-homeserverless" elneo-accounts)
                         t)
                    nil))
      (ignore-errors (delete-directory data-dir 'recursive))
      (ignore-errors (delete-file accounts-file))))

  (message "results: %d passed, %d failed" pass fail)
  (kill-emacs (if (zerop fail) 0 1)))