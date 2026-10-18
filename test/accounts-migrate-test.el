;;; accounts-migrate-test.el --- the rename's migrations -*- lexical-binding: t; -*-

;; The two data migrations the elneo rename ships, both driven from
;; tempdirs only (no real user data is ever opened):
;;
;; - `elneo--migrate-data-base', the elisp twin of the daemon's
;;   `migrate_data_base`: an old `matrix-client' base moves whole when
;;   the new `elneo' base does not exist yet (the result is memoized),
;;   a second pass is a no-op, and an old base reappearing next to the
;;   migrated one warns and is never merged or deleted.
;;
;; - `elneo--accounts-load''s copy-migration of the accounts file:
;;   `matrix-accounts.el' copies to `elneo-accounts.el' (never deleted
;;   or overwritten) and the load stays idempotent.
;;
;; Run: emacs -Q --batch -L lisp -l test/accounts-migrate-test.el

(require 'cl-lib)
(require 'elneo-client)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  ;; --- data base, darwin: the old base KEEPS the pre-rename name ---
  ;; The symbol-corrupted old-base name ("com.emacs.elneo-client") made
  ;; the elisp migration a permanent no-op on darwin, where the daemon's
  ;; own migrate_data_base looks for com.emacs.matrix-client — and a
  ;; daemon-independent write under the new base first would leave the
  ;; daemon booting an empty base.  The darwin branch of
  ;; elneo--migrate-data-base runs here on any platform: `system-type'
  ;; is read dynamically and expand-file-name's ~ takes HOME from the
  ;; environment.  The test plants the real old base (with a session)
  ;; NEXT TO the empty dir named by the corrupted string — migration
  ;; must use the former.
  (let* ((tmp (make-temp-file "mx-darwin" t))
         (home (file-name-concat tmp "home"))
         (lib (file-name-concat home "Library/Application Support"))
         (old-dir (file-name-concat lib "com.emacs.matrix-client"))
         (decoy-dir (file-name-concat lib "com.emacs.elneo-client"))
         (new-dir (file-name-concat tmp "elneo")))
    (mkdir (file-name-concat old-dir "p") t)
    (write-region "" nil (file-name-concat old-dir "p" "session.json"))
    (mkdir decoy-dir t)
    (let ((elneo--migrated-data-base nil)
          (system-type 'darwin)
          (process-environment (cons (concat "HOME=" home) process-environment)))
      (mx-check "darwin: the migrate picks the real old base"
                (elneo--migrate-data-base new-dir) new-dir)
      (mx-check "darwin: the session rode along from the real old base"
                (file-exists-p (file-name-concat new-dir "p" "session.json"))
                t)
      (mx-check "darwin: the old base is gone after the move"
                (file-exists-p old-dir)
                nil)
      (mx-check "darwin: the empty decoy stayed untouched"
                (and (file-directory-p decoy-dir)
                     (= (length (directory-files decoy-dir nil "^[^.]")) 0))
                t))
    (delete-directory tmp t))

  ;; The XDG-shaped sections below resolve the linux base names; on
  ;; darwin they would reach the real ~/Library paths, so run the pin
  ;; above and stop there.
  (when (eq system-type 'darwin)
    (message "accounts-migrate-test: darwin, XDG suites skipped")
    (when (> fail 0) (kill-emacs 1))
    (message "results: %d passed, %d failed" pass fail)
    (kill-emacs 0))

  ;; --- data base: move once, idempotent, never merge ---
  (let* ((tmp (make-temp-file "mx-base" t))
         (old-dir (file-name-concat tmp "matrix-client"))
         (new-dir (file-name-concat tmp "elneo")))
    (mkdir (file-name-concat old-dir "p") t)
    (write-region "" nil (file-name-concat old-dir "p" "session.json"))
    (let ((elneo--migrated-data-base nil)
          (process-environment
           (cons (concat "XDG_DATA_HOME=" tmp) process-environment)))
      (mx-check "base: the old base starts present" (file-exists-p old-dir) t)
      (mx-check "base: the new base is returned"
                (elneo--migrate-data-base new-dir) new-dir)
      (mx-check "base: the session rode along"
                (file-exists-p (file-name-concat new-dir "p" "session.json"))
                t)
      (mx-check "base: the old base is gone after the move"
                (file-exists-p old-dir) nil)
      ;; A second call: memoized, no re-move.
      (mx-check "base: the second call returns the same base"
                (elneo--migrate-data-base new-dir)
                new-dir)
      ;; An old base reappearing next to the migrated one: kept, alone.
      (mkdir old-dir t)
      (setq elneo--migrated-data-base nil)
      (mx-check "base: both exist — the new base is kept"
                (elneo--migrate-data-base new-dir)
                new-dir)
      (mx-check "base: both exist — the old one is never merged away"
                (file-exists-p old-dir)
                t)
      ;; Lost the move race: the check above passed, then a concurrent
      ;; mover's rename landed in the window — our rename fails with
      ;; the old base already gone and the new base present.  The stub
      ;; replays exactly that (winner moves old to new, our rename
      ;; signals): the loser must follow the winner, not the empty old
      ;; base (the live wachter bug).
      (delete-directory new-dir t)
      (mkdir (file-name-concat old-dir "p2") t)
      (setq elneo--migrated-data-base nil)
      (cl-letf (((symbol-function 'rename-file)
                 (lambda (_from _to &optional _ok)
                   (delete-directory old-dir t)
                   (mkdir new-dir t)
                   (error "No such file or directory"))))
        (mx-check "base: a lost rename race follows the winner"
                  (elneo--migrate-data-base new-dir)
                  new-dir)
        (mx-check "base: the raced-away old base is not used"
                  (file-exists-p old-dir)
                  nil))
      ;; A pre-created new base WITHOUT a session (stray empty dir,
      ;; elisp consumers creating it early, a symlink target) must not
      ;; strand the old session: the adoption moves the old base's
      ;; entries in (mirrors the daemon's base_has_sessions rule).
      ;; The race stub above left new present (p2, empty) and old gone;
      ;; this runs OUTSIDE the stub, with the real rename-file.
      (mkdir old-dir t)
      (mkdir (file-name-concat old-dir "p3") t)
      (write-region "" nil (file-name-concat old-dir "p3" "session.json"))
      (setq elneo--migrated-data-base nil)
      (mx-check "base: a session-less new base adopts the old one"
                (elneo--migrate-data-base new-dir)
                new-dir)
      (mx-check "base: the adopted session rode along"
                (file-exists-p (file-name-concat new-dir "p3" "session.json"))
                t)
      (mx-check "base: the adoption did not leave the old base"
                (file-exists-p old-dir)
                nil))
    (delete-directory tmp t))

  ;; --- accounts file: copy-migrate, never delete/overwrite ---
  (let* ((tmp (make-temp-file "mx-accounts" t))
         (old-f (expand-file-name "matrix-accounts.el" tmp))
         (new-f (expand-file-name "elneo-accounts.el" tmp))
         (saved '((("p" (:homeserver "https://hs"))))))
    (write-region (prin1-to-string saved) nil old-f)
    (let ((elneo-account-file new-f)
          (elneo-accounts nil)
          (elneo-accounts-loaded nil)
          (user-emacs-directory tmp))
      (elneo--accounts-load)
      (mx-check "accounts: the old file copy-migrated (both exist)"
                (list (file-exists-p new-f) (file-exists-p old-f))
                (list t t))
      (mx-check "accounts: the load read the migrated copy"
                elneo-accounts saved)
      ;; A reset load with the new file already present: no re-copy,
      ;; and the read comes off the migrated copy.
      (setq elneo-accounts nil
            elneo-accounts-loaded nil)
      (let ((copied-seen 0))
        (cl-letf (((symbol-function 'copy-file)
                   (lambda (_from _to &optional _ok)
                     (cl-incf copied-seen))))
          (elneo--accounts-load)
          (mx-check "accounts: an existing new file is not re-copied"
                    copied-seen 0)
          (mx-check "accounts: the load read the migrated copy"
                    elneo-accounts saved))
        ;; A truncated target file parses to nil: the load never
        ;; silently zeroes the accounts view while the intact old file
        ;; sits next to it — the warning names both paths.  Inside the
        ;; bindings above: the load must never reach the real user
        ;; files, whatever the scenario.
        (write-region "((\"p\"" nil new-f)
        (let ((warned nil))
          (cl-letf (((symbol-function 'warn)
                     (lambda (form &rest args)
                       (setq warned (apply #'format form args)))))
            (setq elneo-accounts nil
                  elneo-accounts-loaded nil)
            (elneo--accounts-load)
            (mx-check "accounts: a truncated copy loads no accounts"
                      elneo-accounts nil)
            (mx-check "accounts: the truncation warning names both files"
                      (and (string-match-p
                            (regexp-quote (file-name-nondirectory new-f)) warned)
                           (string-match-p
                            (regexp-quote (file-name-nondirectory old-f)) warned)
                           t)
                      t)))))
      (delete-file old-f)
      (delete-file new-f)
      (delete-directory tmp t))

  (message "results: %d passed, %d failed" pass fail)
  (when (> fail 0) (kill-emacs 1)))