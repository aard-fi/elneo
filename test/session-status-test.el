;;; session-status-test.el --- the interactive session status view -*- lexical-binding: t; -*-

;; The status buffer is what the room bar's [Verify: ACCOUNT] row and
;; `M-x elneo-session-status' open: per-device verify/remove buttons,
;; jump buttons for pending verification requests, `g' to refresh and
;; `q' (inherited from `special-mode') to bury.  The daemon-side parts
;; (the four queries) are stubbed; what is under test is the buffer
;; itself, the pending-request filter, and the button plumbing.
;;
;; Run: emacs -Q --batch -L lisp -l test/session-status-test.el

(require 'elneo-verify)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  ;; Pending-request filter: this daemon run's tracked flows only,
  ;; non-terminal states, the profile the view asked for.
  (let ((elneo-verifications (make-hash-table :test 'equal)))
    (puthash "f1" (list :profile "a" :flow-id "f1"
                        :user-id "@u:hs" :device-id "PENDINGPHONE"
                        :state "requested")
             elneo-verifications)
    (puthash "f2" (list :profile "a" :flow-id "f2"
                        :user-id "@u:hs" :device-id "OTHERDONE"
                        :state "done")
             elneo-verifications)
    (puthash "f3" (list :profile "a" :flow-id "f3"
                        :user-id "@u2:hs" :device-id "ALSOOTHER"
                        :state "cancelled")
             elneo-verifications)
    (puthash "f4" (list :profile "b" :flow-id "f4"
                        :user-id "@u3:hs" :device-id "BPROFILE"
                        :state "ready")
             elneo-verifications)
    (mx-check "pending: other profile and terminal states filtered"
              (mapcar (lambda (rec) (plist-get rec :device-id))
                      (elneo-session-status--pending-requests "a"))
              '("PENDINGPHONE")))

  ;; The render: fixture devices — current, remote unverified, remote
  ;; verified.  Buttons [verify]/[remove] land where they should.
  (let ((devices '(((device_id . "CUR") (display_name . "emacs")
                    (is_current . t) (verified . t))
                   ((device_id . "OLD1") (display_name . "phone")
                    (is_current . nil) (verified . nil))
                   ((device_id . "OLD2") (display_name . "tab")
                    (is_current . nil) (verified . t)))))
    (with-current-buffer
        (generate-new-buffer " *mx-status*")
      ;; The render reuses an existing buffer by name; make ours the
      ;; one it finds.  Name convention: *Matrix Status: PROFILE*.
      (rename-buffer "*Matrix Status: mxstat*")
      (unwind-protect
          (progn
            (let ((elneo-server--sessions
                   '(("mxstat" :user-id "@u:hs" :device-id "CUR"
                      :access-token "t"))))
              (elneo-session-status--render
               "mxstat" '(t . nil) "enabled" devices nil))
            (mx-check "render: buffer named for the profile"
                      (equal (buffer-name) "*Matrix Status: mxstat*")
                      t)
            (mx-check "render: read-only after render" buffer-read-only t)
            (mx-check "render: profile recorded buffer-locally"
                      elneo-session-status--profile "mxstat")
            (mx-check "render: session row NOT trusted"
                      (and (string-match-p "enabled, session NOT trusted"
                                           (buffer-string))
                           t)
                      t)
            ;; Device rows: current gets no buttons.  (CUR appears in
            ;; the header's Device: line first; the row is next.)
            (goto-char (point-min))
            (search-forward "CUR")
            (mx-check "render: current device without buttons"
                      (progn (search-forward "CUR")
                             (string-match-p
                              "\\[verify\\]\\|\\[remove\\]"
                              (buffer-substring (line-beginning-position)
                                                (line-end-position))))
                      nil)
            ;; Remote unverified: both buttons; verified remote:
            ;; remove only.
            (goto-char (point-min))
            (let ((row1 (progn (search-forward "OLD1")
                               (buffer-substring (line-beginning-position)
                                                 (line-end-position))))
                  (row2 (progn (goto-char (point-max))
                               (search-backward "OLD2")
                               (buffer-substring (line-beginning-position)
                                                 (line-end-position)))))
              (mx-check "render: unverified remote row"
                        (and (string-match-p "\\[verify\\] \\[remove\\]" row1)
                             t)
                        t)
              (mx-check "render: verified remote row"
                        (and (string-match-p "\\[remove\\]" row2)
                             (not (string-match-p "\\[verify\\]" row2))
                             t)
                        t))
            (mx-check "render: [jump] absent with no pending requests"
                      (not (string-match-p "\\[jump\\]" (buffer-string)))
                      t)
            ;; Buttons are real (keyboard-reachable) buttons.
            (goto-char (point-min))
            (mx-check "render: buttons present"
                      (and (next-button (point)) t) t)
            ;; Mode wiring: g refreshes, q inherited from special-mode.
            (mx-check "mode: g bound to refresh"
                      (key-binding (kbd "g"))
                      #'elneo-session-status-refresh)
            (mx-check "mode: q bound (special-mode's)"
                      (key-binding (kbd "q"))
                      #'quit-window)
            ;; Refresh re-runs the queries: 4 commands go out for the
            ;; profile.  The daemon must be live and its call stubbed.
            (let ((calls 0))
              (cl-letf (((symbol-function 'elneo-server-live-p)
                         (lambda (_p) t))
                        ((symbol-function 'elneo-server--call)
                         (lambda (p _cmd _cb)
                           (cl-incf calls)
                           (cons :req calls))))
                (elneo-session-status-refresh)
                (mx-check "refresh: re-runs the four queries" calls 4)))
            ;; The remove action: password prompt once, delete command
            ;; with it, re-open on ack.
            (let ((deleted nil) (prompted 0))
              (cl-letf (((symbol-function 'read-passwd)
                         (lambda (_prompt)
                           (cl-incf prompted)
                           "pw"))
                        ((symbol-function 'elneo-delete-device)
                         (lambda (_p id password _cb)
                           (setq deleted (list id password))))
                        ((symbol-function 'elneo-server--error-string)
                         (lambda (_e) "nope")))
                (elneo-session-status--remove-device "mxstat" "OLD1")
                ;; …and and-chains must not end in string-match-p.
                (mx-check "remove: one read-passwd, device and password out"
                          (and (= prompted 1)
                               (equal deleted '("OLD1" "pw"))
                               t)
                          t)))
        (kill-buffer (get-buffer "*Matrix Status: mxstat*"))))))

  ;; The verify action: a log line, the verify buffer raised, the
  ;; request command out.
  (let ((requested nil) (raised nil))
    (cl-letf (((symbol-function 'elneo-verify--show)
               (lambda (p) (setq raised p)))
              ((symbol-function 'elneo-verify--log)
               (lambda (_p _text &optional _face) t))
              ((symbol-function 'elneo-verification-request-device)
               (lambda (_p user-id device-id)
                 (setq requested (list user-id device-id)))))
      (elneo-session-status--verify-device "mxstat" "@u:hs" "OLD1")
      (mx-check "verify: buffer raised, the session's user, the picked device"
                (and (equal raised "mxstat")
                     (equal requested '("@u:hs" "OLD1"))
                     t)
                t)))

  (message "results: %d passed, %d failed" pass fail)
  (kill-emacs (if (zerop fail) 0 1)))