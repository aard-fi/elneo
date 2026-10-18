;;; invite-test.el --- invite display and accept/decline flow -*- lexical-binding: t; -*-

;; Protocol 5 exposes invited rooms in the room list (room_state
;; "invited"); the bar shows them per `elneo-room-invite-display' (an
;; Invites section or an inline dimmed row with a glyph, or nothing),
;; and clicking/RET on an invite row prompts join / decline / ignore
;; (via the membership daemon commands instead of a room buffer).  All
;; batch, no real processes.
;;
;; Run: emacs -Q --batch -L lisp -l test/invite-test.el

(require 'elneo-client)
(require 'elneo-room-bar)
(require 'elneo-room)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  ;; --- the invite predicate ---

  (mx-check "invite-p: invited record" (elneo-room-bar--invite-p '(:room-state "invited")) t)
  (mx-check "invite-p: joined record" (elneo-room-bar--invite-p '(:room-state "joined")) nil)
  (mx-check "invite-p: old record without the field" (elneo-room-bar--invite-p '(:room-id "!r")) nil)

  ;; --- list partitioning per display mode ---

  ;; Explicit last-activity values make the activity sort
  ;; deterministic; sort is not stable for equal keys.
  (let ((rooms '((:profile "a" :room-id "!j" :display-name "Joined"
                   :room-state "joined" :last-activity 300 :unread 3)
                 (:profile "a" :room-id "!i" :display-name "Invited"
                   :room-state "invited" :last-activity 100))))
    (cl-letf (((symbol-function 'elneo-rooms-all) (lambda () rooms)))
      (let ((elneo-room-invite-display 'section))
        (mx-check "section mode: invites hidden from the room list"
                  (mapcar (lambda (r) (plist-get r :room-id))
                          (elneo-room-bar--visible-rooms))
                  '("!j"))
        (mx-check "section mode: invites under their own section"
                  (mapcar (lambda (r) (plist-get r :room-id))
                          (elneo-room-bar--invites))
                  '("!i")))
      (let ((elneo-room-invite-display 'inline))
        (mx-check "inline mode: invites stay in the sorted list"
                  (mapcar (lambda (r) (plist-get r :room-id))
                          (elneo-room-bar--visible-rooms))
                  '("!j" "!i"))
        (mx-check "inline mode: no separate section"
                  (elneo-room-bar--invites) nil))
      (let ((elneo-room-invite-display 'hide))
        (mx-check "hide mode: neither list shows the invite"
                  (list (elneo-room-bar--visible-rooms)
                        (elneo-room-bar--invites))
                  '(((:profile "a" :room-id "!j" :display-name "Joined"
                     :room-state "joined" :last-activity 300 :unread 3))
                    nil)))))

  ;; --- row text: the glyph is inline-mode-only ---

  (let ((elneo-room-bar-avatars nil)
        (elneo-room-bar-account-display 'none)
        (elneo-room-bar-preview-style 'none))
    (let ((elneo-room-invite-display 'inline))
      (mx-check "inline row carries the invite glyph"
                (string-prefix-p
                 elneo-room-bar-invite-glyph
                 (elneo-room-bar--row-text
                  '(:room-state "invited" :display-name "Foo" :unread 0 :highlights 0)))
                t))
    (let ((elneo-room-invite-display 'section))
      (mx-check "section row: no glyph (the header says it)"
                (string-prefix-p
                 "Foo"
                 (elneo-room-bar--row-text
                  '(:room-state "invited" :display-name "Foo" :unread 0 :highlights 0)))
                t)))

  ;; --- put-row dims an invite row ---

  (let ((buf (generate-new-buffer " *mx-invite-row*")))
    (with-current-buffer buf
      (let ((elneo-room-bar--buffer buf)
            (elneo-room-bar--markers (make-hash-table :test 'equal))
            (elneo-room-bar-avatars nil)
            (elneo-room-bar-account-display 'none)
            (elneo-room-bar-preview-style 'none))
        (elneo-room-bar--put-row
         '(:profile "a" :room-id "!i" :display-name "Invited"
           :room-state "invited" :unread 0 :highlights 0))
        (mx-check "invite row carries the dim face"
                  (get-text-property (point-min) 'face)
                  'elneo-room-bar-invite)))
    (kill-buffer buf))

  ;; A joined row (even a zero-unread one) has no invite face.
  (let ((buf (generate-new-buffer " *mx-joined-row*")))
    (with-current-buffer buf
      (let ((elneo-room-bar--buffer buf)
            (elneo-room-bar--markers (make-hash-table :test 'equal))
            (elneo-room-bar-avatars nil)
            (elneo-room-bar-account-display 'none)
            (elneo-room-bar-preview-style 'none))
        (elneo-room-bar--put-row
         '(:profile "a" :room-id "!j" :display-name "Joined"
           :room-state "joined" :unread 0 :highlights 0))
        (mx-check "joined row has no invite face"
                  (get-text-property (point-min) 'face)
                  nil)))
    (kill-buffer buf))

  ;; --- the Invites section in a full render ---

  (let ((buf (generate-new-buffer " *mx-invite-bar*")))
    (unwind-protect
        (let ((elneo-room-bar--buffer buf)
              (elneo-room-bar--markers (make-hash-table :test 'equal))
              (elneo-room-bar-avatars nil)
              (elneo-room-bar-account-display 'none)
              (elneo-room-bar-preview-style 'none)
              (elneo-room-invite-display 'section))
          (cl-letf (((symbol-function 'elneo-room-bar--ensure) #'ignore)
                    ((symbol-function 'elneo-room-bar--insert-controls) #'ignore)
                    ((symbol-function 'elneo-rooms-all)
                     (lambda ()
                       '((:profile "a" :room-id "!j" :display-name "Joined"
                          :room-state "joined" :last-activity 300
                          :unread 3 :highlights 0)
                         (:profile "a" :room-id "!i" :display-name "Invited"
                          :room-state "invited" :last-activity 100
                          :unread 0 :highlights 0)))))
            (elneo-room-bar-refresh-full)
            (with-current-buffer buf
              ;; The render leaves point at the buffer end (the
              ;; room-row loop appends from there), so anchor every
              ;; search at point-min.
              (goto-char (point-min))
              (mx-check "section header with count"
                        (and (search-forward "Invites (1)" nil t) t) t)
              (goto-char (point-min))
              (search-forward "Invites (1)")
              (mx-check "header carries the section face"
                        (get-text-property (line-beginning-position) 'face)
                        'elneo-room-bar-section)
              (goto-char (point-min))
              ;; search-forward stops after the match; the key lives on
              ;; the last header character.
              (let ((key (get-text-property
                          (1- (search-forward "Invites (1)")) 'elneo-room-key)))
                (mx-check "header key is the invites pseudo-key"
                          (and (consp key) (eq (car key) :invites)) t)))))
      (kill-buffer buf)))

  ;; --- opening dispatches the prompt for invites ---

  (let ((prompted nil) (opened 0))
    (cl-letf (((symbol-function 'elneo-room-invite-prompt)
               (lambda (room) (setq prompted room)))
              ((symbol-function 'elneo-room--open)
               (lambda (_room &optional _stay-put) (cl-incf opened))))
      (elneo-room-open '(:profile "a" :room-id "!i" :room-state "invited"))
      (mx-check "invite open prompts instead of opening" (and prompted t) t)
      (mx-check "invite open opens no room buffer" opened 0)
      (setq prompted nil)
      (elneo-room-open '(:profile "a" :room-id "!j" :room-state "joined"))
      (mx-check "joined room still opens the buffer" opened 1)
      (mx-check "joined room does not prompt" prompted nil)))

  ;; --- the invite prompt ---

  ;; Join: read j, the accept command's ack finds the registry record
  ;; (already the seeded joined one), and the room opens.
  (let ((accepted nil) (declined nil) (opened 0)
        (elneo--rooms (make-hash-table :test 'equal)))
    (puthash (cons "main" "!i:hs")
             '(:profile "main" :room-id "!i:hs" :display-name "Invited"
               :room-state "joined")
             elneo--rooms)
    (cl-letf (((symbol-function 'read-char) (lambda (&rest _) ?j))
              ((symbol-function 'elneo-accept-invite)
               (lambda (profile room-id cb)
                 (setq accepted (list profile room-id)) (funcall cb profile '((@ok . t)))))
              ((symbol-function 'elneo-decline-invite)
               (lambda (&rest _) (setq declined t)))
              ((symbol-function 'elneo-room--open)
               (lambda (_room &optional _stay-put) (cl-incf opened))))
      (elneo-room-invite-prompt '(:profile "main" :room-id "!i:hs"
                                 :display-name "Invited" :room-state "invited"))
      (mx-check "join: accept sent" accepted '("main" "!i:hs"))
      (mx-check "join: no decline" declined nil)
      (mx-check "join: room opened after the ack" opened 1)))

  ;; Join failure: nothing opens (and nothing crashes).
  (let ((opened 0))
    (cl-letf (((symbol-function 'read-char) (lambda (&rest _) ?j))
              ((symbol-function 'elneo-accept-invite)
               (lambda (profile room-id cb)
                 (funcall cb profile '((@ok . nil) (@error . "no invite"))))))
      (elneo-room-invite-prompt
       '(:profile "main" :room-id "!i:hs" :display-name "Invited"))
      (mx-check "failed accept opens nothing" opened 0)))

  ;; Decline.
  (let ((declined nil) (opened 0))
    (cl-letf (((symbol-function 'read-char) (lambda (&rest _) ?d))
              ((symbol-function 'elneo-decline-invite)
               (lambda (profile room-id cb)
                 (setq declined (list profile room-id))
                 (funcall cb profile '((@ok . t))))))
      (elneo-room-invite-prompt
       '(:profile "main" :room-id "!i:hs" :display-name "Invited"))
      (mx-check "decline: decline command sent" declined '("main" "!i:hs"))
      (mx-check "decline: nothing opened" opened 0)))

  ;; Anything else ignores — no command fires.
  (let ((accepted nil) (declined nil))
    (cl-letf (((symbol-function 'read-char) (lambda (&rest _) ?x))
              ((symbol-function 'elneo-accept-invite) #'ignore)
              ((symbol-function 'elneo-decline-invite) #'ignore))
      (elneo-room-invite-prompt
       '(:profile "main" :room-id "!i:hs" :display-name "Invited"))
      (mx-check "ignore: no command at all" (list accepted declined)
                '(nil nil))))

  ;; --- the upgrade-successor invite: the prompt's extra choice ---

  ;; The prompt string only gains the explicit leave choice when the
  ;; invite names a still-joined predecessor.
  (let ((plain (elneo-room--invite-prompt-string "Ops" nil))
        (upgrade (elneo-room--invite-prompt-string "Ops" t)))
    (mx-check "prompt: plain invite reads j/d/i"
              (and (string-search "[j]oin, [d]ecline, [i]gnore?" plain) t)
              t)
    (mx-check "prompt: upgrade invite reads the leave choice"
              (and (string-search "[L]eave old too" upgrade) t)
              t))

  ;; The predecessor lookup: only a still-joined registry record
  ;; counts; a record the session never knew, a removed one and a
  ;; left one each offer no choice.
  (let ((elneo--rooms (make-hash-table :test 'equal)))
    (puthash (cons "main" "!old:hs")
             '(:profile "main" :room-id "!old:hs" :display-name "Old"
               :room-state "joined")
             elneo--rooms)
    (mx-check "upgrade-predecessor: joined predecessor answers"
              (elneo-room--invite-upgrade-predecessor
               '(:profile "main" :room-id "!new:hs" :upgraded-from "!old:hs"))
              "!old:hs")
    (mx-check "upgrade-predecessor: unknown old says nil"
              (elneo-room--invite-upgrade-predecessor
               '(:profile "main" :room-id "!new:hs" :upgraded-from "!never:hs"))
              nil)
    (puthash (cons "main" "!gone:hs")
             '(:profile "main" :room-id "!gone:hs" :room-state "left"
               :removed t)
             elneo--rooms)
    (mx-check "upgrade-predecessor: removed old says nil"
              (elneo-room--invite-upgrade-predecessor
               '(:profile "main" :room-id "!new:hs" :upgraded-from "!gone:hs"))
              nil)
    (mx-check "upgrade-predecessor: no link at all says nil"
              (elneo-room--invite-upgrade-predecessor
               '(:profile "main" :room-id "!new:hs"))
              nil))

  ;; [L]: accept, then leave the older room in the accept's wake —
  ;; with the auto setting off, the explicit choice must still work.
  ;; The registry carries the successor's seeded joined record, so the
  ;; ack opens it like any plain join's ack.
  (let ((accepted nil) (left nil) (opened 0)
        (elneo--rooms (make-hash-table :test 'equal)))
    (puthash (cons "main" "!old:hs")
             '(:profile "main" :room-id "!old:hs" :display-name "Old"
               :room-state "joined")
             elneo--rooms)
    (puthash (cons "main" "!new:hs")
             '(:profile "main" :room-id "!new:hs" :display-name "Successor"
               :room-state "joined")
             elneo--rooms)
    (cl-letf (((symbol-function 'read-char) (lambda (&rest _) ?L))
              ((symbol-function 'elneo-accept-invite)
               (lambda (profile room-id cb)
                 (setq accepted (list profile room-id))
                 (funcall cb profile '((@ok . t)))))
              ((symbol-function 'elneo-leave-room)
               (lambda (profile room-id cb)
                 (setq left (list profile room-id))
                 (funcall cb profile '((@ok . t)))))
              ((symbol-function 'elneo-room--open)
               (lambda (_room &optional _stay-put) (cl-incf opened))))
      (elneo-room-invite-prompt
       '(:profile "main" :room-id "!new:hs" :display-name "Successor"
         :room-state "invited" :upgraded-from "!old:hs"))
      (mx-check "leave-old: invite accepted" accepted '("main" "!new:hs"))
      (mx-check "leave-old: the old room left too" left '("main" "!old:hs"))
      (mx-check "leave-old: the successor opened" opened 1)))

  ;; A failed accept leaves the old room alone — nothing moves unless
  ;; the join did.
  (let ((left nil))
    (cl-letf (((symbol-function 'read-char) (lambda (&rest _) ?l))
              ((symbol-function 'elneo-accept-invite)
               (lambda (profile room-id cb)
                 (funcall cb profile '((@ok . nil) (@error . "no invite")))))
              ((symbol-function 'elneo-leave-room)
               (lambda (&rest _) (setq left t))))
      (elneo-room-invite-prompt
       '(:profile "main" :room-id "!new:hs" :display-name "Successor"
         :upgraded-from "!old:hs"))
      (mx-check "leave-old: failed accept leaves nothing" left nil)))

  ;; Plain [j] never leaves anything while `elneo-room-upgrade-leave'
  ;; is off; turning it on makes [j] do the move too.
  (let ((left nil) (elneo--rooms (make-hash-table :test 'equal))
        (elneo-room-upgrade-leave nil))
    (puthash (cons "main" "!old:hs")
             '(:profile "main" :room-id "!old:hs" :room-state "joined")
             elneo--rooms)
    (cl-letf (((symbol-function 'read-char) (lambda (&rest _) ?j))
              ((symbol-function 'elneo-accept-invite)
               (lambda (p _r cb) (funcall cb p '((@ok . t)))))
              ((symbol-function 'elneo-leave-room)
               (lambda (&rest _) (setq left t)))
              ((symbol-function 'elneo-room--open) #'ignore))
      (elneo-room-invite-prompt
       '(:profile "main" :room-id "!new:hs" :display-name "Successor"
         :upgraded-from "!old:hs"))
      (mx-check "join: default setting leaves nothing" left nil)
      (let ((elneo-room-upgrade-leave t))
        (cl-letf (((symbol-function 'elneo-leave-room)
                   (lambda (profile room-id _cb)
                     (setq left (list profile room-id))))
                  ((symbol-function 'elneo-room--open) #'ignore))
          (elneo-room-invite-prompt
           '(:profile "main" :room-id "!new:hs" :display-name "Successor"
             :upgraded-from "!old:hs"))))
    (mx-check "join: upgrade-leave setting makes j leave the old room"
              left '("main" "!old:hs"))))

  ;; --- client-side command shapes ---

  (let (sent)
    (cl-letf (((symbol-function 'elneo-server--call)
               (lambda (_p cmd _cb) (setq sent cmd))))
      (elneo-accept-invite "main" "!i:hs" #'ignore)
      (mx-check "acceptInvite command"
                (list (cdr (assq '@type sent)) (cdr (assq 'room_id sent)))
                '("acceptInvite" "!i:hs"))
      (setq sent nil)
      (elneo-decline-invite "main" "!i:hs" #'ignore)
      (mx-check "declineInvite command"
                (list (cdr (assq '@type sent)) (cdr (assq 'room_id sent)))
                '("declineInvite" "!i:hs"))
      (setq sent nil)
      (elneo-join-room "main" "#r:hs" #'ignore)
      (mx-check "joinRoom command carries the alias field"
                (list (cdr (assq '@type sent)) (cdr (assq 'room_id_or_alias sent)))
                '("joinRoom" "#r:hs"))
      (setq sent nil)
      (elneo-leave-room "main" "!r:hs" #'ignore)
      (mx-check "leaveRoom command"
                (list (cdr (assq '@type sent)) (cdr (assq 'room_id sent)))
                '("leaveRoom" "!r:hs"))
      (setq sent nil)
      (elneo-forget-room "main" "!r:hs" #'ignore)
      (mx-check "forgetRoom command"
                (list (cdr (assq '@type sent)) (cdr (assq 'room_id sent)))
                '("forgetRoom" "!r:hs"))))

  ;; A decline of an old room whose row is gone stays quiet.

  (message "results: %d passed, %d failed" pass fail)
  (when (> fail 0) (kill-emacs 1)))