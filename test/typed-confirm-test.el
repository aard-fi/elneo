;;; typed-confirm-test.el --- the typed-word recovery confirmations -*- lexical-binding: t; -*-

;; The destructive recovery verbs — rotate and disable — sit behind a
;; typed word (ROTATE / DISABLE), not a y/n reflex: a deleted key
;; backup is not re-verifiable.  Everything here is synthetic — no
;; daemon, no real key material.
;;
;; Run: emacs -Q --batch -L lisp -l test/typed-confirm-test.el

(require 'elneo-client)
(require 'elneo-verify)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  ;; --- the confirmation word itself
  (cl-letf (((symbol-function 'read-string) (lambda (&optional _p &rest _) "ROTATE ")))
    (mx-check "confirm: surrounding space and case make no difference"
              (elneo-verify--confirm-word "p" "rotate") t)
    (mx-check "confirm: the exact word in any case"
              (elneo-verify--confirm-word "p" "ROTATE") t))
  (cl-letf (((symbol-function 'read-string) (lambda (&optional _p &rest _) "disable")))
    (mx-check "confirm: a different word is a no"
              (elneo-verify--confirm-word "p" "rotate") nil))
  (cl-letf (((symbol-function 'read-string) (lambda (&optional _p &rest _) "")))
    (mx-check "confirm: empty input is a no"
              (elneo-verify--confirm-word "p" "disable") nil))

  ;; --- rotate: the confirmed, trusted flow
  (let (sent)
    (cl-letf (((symbol-function 'elneo-server--call)
               (lambda (profile payload callback)
                 (setq sent (list profile payload callback))))
              ((symbol-function 'read-string)
               (lambda (&optional _p &rest _) "ROTATE")))
      (elneo-rotate-recovery-key "mxcon"))
    ;; The command went to the daemon as a plain payload — a trusted
    ;; session carries no old_key — and the success response's key is
    ;; shown once, like enable's.
    (mx-check "rotate: the confirmed command goes to the daemon"
              (car sent) "mxcon")
    (mx-check "rotate: a trusted session sends no old_key"
              (cadr sent) '((@type . "rotateRecoveryKey")))
    (mx-check "rotate: the success callback is there"
              (and (nth 2 sent) t) t)
    ;; The rotate response carries the recovery key shown once; the
    ;; callback does the showing — success shows the key buffer.
    (funcall (nth 2 sent) "mxcon"
             '((@ok . t) (recovery_key . "TESTKEY")
               (stored_path . "/tmp/t/recovery-key")))
    (mx-check "rotate: success shows the new key once"
              (and (get-buffer "*Matrix recovery key: mxcon*") t) t)
    (mx-check "rotate: the shown key is the response's"
              (and (string-search "TESTKEY"
                                  (with-current-buffer
                                      "*Matrix recovery key: mxcon*"
                                    (buffer-string)))
                   t)
              t))

  ;; --- rotate: an untrusted session must carry the old key
  (let (sent)
    (let ((elneo-server--trust '(("mxcon" . (t . nil)))))
      (cl-letf (((symbol-function 'elneo-server--call)
                 (lambda (_profile payload _callback) (setq sent payload)))
                ((symbol-function 'read-string)
                 (lambda (&optional _p &rest _) "rotate"))
                ((symbol-function 'read-passwd)
                 (lambda (&optional _p) "OLDDK")))
        (elneo-rotate-recovery-key "mxcon")))
    (mx-check "rotate: an untrusted session passes the old key"
              (assq 'old_key sent) '(old_key . "OLDDK")))

  ;; --- rotate: refusals and aborts send nothing
  (let ((elneo-server--trust '(("mxcon" . (t . nil)))))
    (cl-letf (((symbol-function 'elneo-server--call)
               (lambda (&rest _) (error "must not send")))
              ((symbol-function 'read-string)
               (lambda (&optional _p &rest _) "ROTATE"))
              ((symbol-function 'read-passwd)
               (lambda (&optional _p) "")))
      (mx-check "rotate: an empty old key refuses the whole command"
                (condition-case nil
                    (progn (elneo-rotate-recovery-key "mxcon") nil)
                  (error t))
                t)))
  (let (sent)
    (cl-letf (((symbol-function 'elneo-server--call)
               (lambda (_p _payload _cb) (setq sent t)))
              ((symbol-function 'read-string)
               (lambda (&optional _p &rest _) "maybe")))
      (elneo-rotate-recovery-key "mxcon"))
    (mx-check "rotate: a wrong word sends nothing" sent nil))
  (let (sent)
    (cl-letf (((symbol-function 'elneo-server--call)
               (lambda (_p _payload _cb) (setq sent t)))
              ((symbol-function 'read-string)
               (lambda (&optional _p &rest _) "no way")))
      (elneo-disable-recovery "mxcon"))
    (mx-check "disable: a wrong word sends nothing" sent nil))

  ;; --- disable: the confirmed flow
  (let (sent)
    (cl-letf (((symbol-function 'elneo-server--call)
               (lambda (_profile payload _callback) (setq sent payload)))
              ((symbol-function 'read-string)
               (lambda (&optional _p &rest _) "DISABLE")))
      (elneo-disable-recovery "mxcon"))
    (mx-check "disable: the confirmed payload has no extras"
              sent '((@type . "disableRecovery"))))

  ;; --- the session-status buttons
  (defun mx-status-text (live)
    "Render mxbtn's status for LIVE and return the buffer's text.
One device carrying four keys — not four single-pair alists
(alist-get walks a dotted singleton's string tail and errors)."
    (cl-letf (((symbol-function 'elneo-server-live-p) (lambda (_p) live)))
      (let ((elneo-server--sessions
             '(("mxbtn" :user-id "@u:hs" :device-id "CUR"
                :access-token "t"))))
        (elneo-session-status--render
         "mxbtn" '(t . t) "enabled"
         '((("display_name" . "phone") ("device_id" . "DEV")
            ("verified" . t) ("is_current" . t)))
         nil)))
    (with-current-buffer "*Matrix Status: mxbtn*"
      (buffer-string)))
  (let ((text (mx-status-text t)))
    (mx-check "status: the backup line offers both verbs"
              (and (string-search "[rotate]" text)
                   (string-search "[disable]" text) t)
              t))
  (let ((text (mx-status-text nil)))
    (mx-check "status: no buttons without a live daemon"
              (string-search "[rotate]" text) nil))

  ;; --- the rescue gate knows about the disabled subsystem
  (let ((elneo-server--trust '(("mxfire" . (t . nil))))
        (elneo-recovery-states (make-hash-table :test 'equal))
        mx-asked)
    (puthash "mxfire" "disabled" elneo-recovery-states)
    (cl-letf (((symbol-function 'elneo-server-live-p) (lambda (_p) t))
              ((symbol-function 'elneo-verify--rescue-prompt)
               (lambda (&rest _) (setq mx-asked t))))
      (elneo-verify--rescue-fire "mxfire")
      (mx-check "rescue: a disabled subsystem suppresses the offer"
                mx-asked nil)
      (puthash "mxfire" "enabled" elneo-recovery-states)
      (elneo-verify--rescue-fire "mxfire")
      (mx-check "rescue: an enabled subsystem still prompts"
                mx-asked t)))

  (message "%d ok, %d failed" pass fail)
  (when (> fail 0) (kill-emacs 1)))

;;; typed-confirm-test.el ends here