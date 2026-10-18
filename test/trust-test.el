;;; trust-test.el --- per-message sender trust marks -*- lexical-binding: t; -*-

;; The trust marks: the daemon's optional `sender_trust' string rides
;; the message plists (live and history alike), a glyph mark renders
;; after the body when `elneo-room-trust-marks' is on (default off),
;; the `T' toggle flips buffer-local vs global default like the other
;; display toggles, and a completed verification re-renders the open
;; marked buffers.
;;
;; The direct render checks call `elneo-room--insert-message' (the
;; code the marks live in) rather than a whole `elneo-room--rebuild'
;; — that re-render needs the input area and a fresh daemon round
;; trip, which batch cannot serve.  The toggle/registry checks stub
;; `elneo-room--rebuild' to a counter instead.
;;
;; Run: emacs -Q --batch -L lisp -l test/trust-test.el

(require 'elneo-room)
(require 'elneo-verify)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defun mx-trust-setup (room-id)
    "A backfilled room buffer holding one verified message; returns it.
Marks follow the global default (i.e. off): tests turn them on per
buffer.  Not registered in `elneo-room--buffers' — tests do that
explicitly, under the id they picked."
    (let ((buf (generate-new-buffer " *mx-trust*")))
      (with-current-buffer buf
        (let ((elneo-room-avatars nil))
          (elneo-room-mode)
          (setq-local elneo-room--profile "mxtest")
          (setq-local elneo-room--room-id room-id)
          (setq elneo-room--seen (make-hash-table :test 'equal))
          (setq elneo-room--backfilled t)
          (insert "header\n"))
      buf)))

  ;; Entry mapping: the daemon's sender_trust rides the message plist.
  (let ((entry '((event_id . "$a") (sender . "@a:hs") (sender_name . "Ann")
                 (content . ((msgtype . "m.text") (body . "hi")))
                 (origin_server_ts . 1700000000000)
                 (event_id_key . "$a"))))
    (mx-check "entry: sender_trust mapped"
              (let ((entry (append entry '((sender_trust . "violation")))))
                (plist-get (elneo-room--message-from-entry entry)
                           :sender-trust))
              "violation")
    (mx-check "entry: absent sender_trust stays nil"
              (plist-get (elneo-room--message-from-entry entry)
                         :sender-trust)
              nil))

  ;; Render: mark rides after the body, in the right face.
  (let ((buf (mx-trust-setup "!room1")))
    (unwind-protect
        (with-current-buffer buf
          ;; Marks on (the global default is off).
          (setq-local elneo-room-trust-marks t)
          (goto-char (point-max))
          (elneo-room--insert-message
           (list :event-id "$a" :sender "@a:hs" :sender-name "Ann"
                 :ts 1700000000000 :msgtype "m.text" :is-own nil
                 :body "hello" :sender-trust "verified"))
          (goto-char (point-min))
          (search-forward "hello")
          (mx-check "marks on: glyph after the body"
                    (buffer-substring (point) (+ 2 (point)))
                    " ✓")
          ;; One char forward: the glyph position.
          (mx-check "marks on: verified face"
                    (get-text-property (1+ (point)) 'face)
                    'elneo-room-trust-verified)
          ;; Unverified → warning; violation/mismatch → broken.
          (goto-char (point-max))
          (elneo-room--insert-message
           (list :event-id "$b" :sender "@b:hs" :ts 1700000001000
                 :msgtype "m.text" :is-own nil :body "sus"
                 :sender-trust "violation"))
          (goto-char (point-min))
          (mx-check "violation: glyph and broken face"
                    (and (search-forward "sus" nil t)
                         (search-forward "✗" (line-end-position) t)
                         (get-text-property (1- (point)) 'face))
                    'elneo-room-trust-broken)
          ;; Unknown trust value ("unsigned" maps to ⚠; check that)
          ;; and no trust at all render no mark.
          (goto-char (point-max))
          (elneo-room--insert-message
           (list :event-id "$c" :sender "@b:hs" :ts 1700000002000
                 :msgtype "m.text" :is-own nil :body "odd"
                 :sender-trust "hyperviolation"))
          (goto-char (point-max))
          (elneo-room--insert-message
           (list :event-id "$d" :sender "@b:hs" :ts 1700000003000
                 :msgtype "m.text" :is-own nil :body "plain"
                 :sender-trust nil))
          (goto-char (point-min))
          (mx-check "unknown/nil trust: no glyph"
                    (and (string-match-p "odd" (buffer-string))
                         (string-match-p "plain" (buffer-string))
                         (not (string-match-p "✓\\|⚠\\|✗"
                                              (buffer-substring
                                               (line-beginning-position 4)
                                               (line-end-position 4))))
                         (not (string-match-p "✓\\|⚠\\|✗"
                                              (buffer-substring
                                               (line-beginning-position 5)
                                               (line-end-position 5))))
                         t)
                    t)
          ;; Marks off: nothing, whatever the trust.
          (setq-local elneo-room-trust-marks nil)
          (goto-char (point-max))
          (elneo-room--insert-message
           (list :event-id "$e" :sender "@b:hs" :ts 1700000004000
                 :msgtype "m.text" :is-own nil :body "quiet"
                 :sender-trust "verified"))
          (goto-char (point-min))
          (mx-check "marks off: no glyph on that line"
                    (and (progn (goto-char (point-max))
                                (search-backward "quiet"))
                         ;; and-chains must not end in string-match-p.
                         (not (string-match-p "✓" (buffer-substring
                                                   (line-beginning-position)
                                                   (line-end-position))))
                         t)
                    t))
      (kill-buffer buf)))

  ;; Toggle: buffer-local flip, ARG drops the override, rebuild counts.
  (let ((buf (mx-trust-setup "!room2"))
        (rebuilds 0))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'elneo-room--rebuild)
                     (lambda () (cl-incf rebuilds))))
            ;; The setup left no override: marks follow off; the first
            ;; flip turns them on locally.
            (elneo-room-toggle-trust-marks)
            (mx-check "toggle: flipped on, buffer-local"
                      (and (eq elneo-room-trust-marks t)
                           (local-variable-p 'elneo-room-trust-marks)
                           (= rebuilds 1))
                      t)
            (elneo-room-toggle-trust-marks)
            (mx-check "toggle: flipped back off"
                      (and (eq elneo-room-trust-marks nil)
                           (local-variable-p 'elneo-room-trust-marks)
                           (= rebuilds 2))
                      t)
            ;; C-u: drop the override and follow the global default.
            (elneo-room-toggle-trust-marks '(4))
            (mx-check "toggle: ARG drops the override"
                      (local-variable-p 'elneo-room-trust-marks)
                      nil)))
      (kill-buffer buf)))

  ;; The rebuild helper: live+backfilled+marked buffers rebuild.
  (let ((rebuilds 0))
    (let ((marked  (mx-trust-setup "!roomA"))
          (marked2 (mx-trust-setup "!roomB"))
          (unmarked (mx-trust-setup "!roomC")))
      (unwind-protect
          (progn
            (puthash (cons "mxtest" "!roomA") marked elneo-room--buffers)
            (puthash (cons "mxtest" "!roomB") marked2 elneo-room--buffers)
            (puthash (cons "mxtest" "!roomC") unmarked elneo-room--buffers)
            ;; Two of the three show marks, buffer-local.
            (with-current-buffer marked  (setq-local elneo-room-trust-marks t))
            (with-current-buffer marked2 (setq-local elneo-room-trust-marks t))
            (cl-letf (((symbol-function 'elneo-room--rebuild)
                       (lambda () (cl-incf rebuilds))))
              (elneo-room--rebuild-trust-buffers)
              (mx-check "rebuild helper: marked buffers only"
                        rebuilds 2)
              (kill-buffer marked2)
              (elneo-room--rebuild-trust-buffers)
              (mx-check "rebuild helper: dead buffers skipped"
                        rebuilds 3)))
        (remhash (cons "mxtest" "!roomA") elneo-room--buffers)
        (remhash (cons "mxtest" "!roomB") elneo-room--buffers)
        (remhash (cons "mxtest" "!roomC") elneo-room--buffers)
        (mapc (lambda (b) (when (buffer-live-p b) (kill-buffer b)))
              (list marked marked2 unmarked)))))

  ;; A completed verification re-renders the marked buffers; other
  ;; update states do not.
  (let ((buf (mx-trust-setup "!roomD"))
        (rebuilds 0))
    (unwind-protect
        (progn
          (with-current-buffer buf (setq-local elneo-room-trust-marks t))
          (puthash (cons "mxtest" "!roomD") buf elneo-room--buffers)
          (cl-letf (((symbol-function 'elneo-room--rebuild)
                     (lambda () (cl-incf rebuilds))))
            (elneo-verify--on-update
             (list :profile "mxtest" :flow-id "f1" :user-id "@a:hs"
                   :we-started nil :state "done"))
            (mx-check "verify done: marked buffers re-render"
                      rebuilds 1)
            (elneo-verify--on-update
             (list :profile "mxtest" :flow-id "f2" :user-id "@a:hs"
                   :we-started nil :state "cancelled"))
            (mx-check "verify cancelled: no re-render"
                      rebuilds 1)))
      (remhash (cons "mxtest" "!roomD") elneo-room--buffers)
      (when (buffer-live-p buf) (kill-buffer buf))))

  (message "results: %d passed, %d failed" pass fail)
  (kill-emacs (if (zerop fail) 0 1)))