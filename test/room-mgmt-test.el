;;; room-mgmt-test.el --- room management: wire payloads and commands -*- lexical-binding: t; -*-

;; The room-management slice: six transport wrappers in elneo-client.el
;; (invite/kick/ban/unban/set-name/set-topic), the interactive layer in
;; elneo-room.el (completing over the member roster, confirmations,
;; ack wording) and the [action] buttons in the C-c ? settings view.
;; Also join/create (elneo-room-join/-create over elneo-join-room and
;; elneo-create-room, protocol 8's roomJoined response).
;; The command payloads are captured at `elneo-server--call', the
;; interactive reads are stubbed (`completing-read', `y-or-n-p'), the
;; settings render is driven with `standard-output' bound like a help
;; window binds it.
;;
;; Run: emacs -Q --batch -L lisp -l test/room-mgmt-test.el

(require 'elneo-room)
(require 'elneo-client)
;; The avatar buttons' actions load elneo-image lazily; preloading
;; keeps the later stubbing intact (a first require redefines the
;; function right out of the cl-letf).
(require 'elneo-image)

(defvar mx--calls nil)

(defun mx--capture (profile event callback)
  "A elneo-server--call stub: remember EVENT, ack to CALLBACK."
  (push (cons profile event) mx--calls)
  (funcall callback profile '((@ok . t))))

(defmacro mx--with-capture (&rest body)
  "Run BODY capturing every elneo-server--call payload, newest last."
  `(let ((mx--calls nil))
     (cl-letf (((symbol-function 'elneo-server--call) #'mx--capture))
       ,@body)
     (nreverse mx--calls)))

(defun mx--room-buffer ()
  "A room buffer with a three-member roster (own account included)."
  (let ((buf (generate-new-buffer " *mx-mgmt-room*")))
    (with-current-buffer buf
      (elneo-room-mode)
      (setq-local elneo-room--profile "mxtest")
      (setq-local elneo-room--room-id "!room")
      (setq-local elneo-room--seen (make-hash-table :test 'equal))
      (setq-local elneo-room--members
                  (list (list :user-id "@bob:example.org" :name "Bob")
                        (list :user-id "@eve:example.org" :name)
                        (list :user-id "@me:example.org" :name "Me")))
      buf)))

(defun mx--settings-bools (room buf labels)
  "Which of LABELS render as buttons for ROOM, with room buffer BUF.
Renders into a temp buffer with `standard-output' bound the way the
help window binds it, then checks each label with `string-search'."
  (with-temp-buffer
    (let ((standard-output (current-buffer)))
      (cl-letf (((symbol-function 'elneo-room--buffer-for)
                 (lambda (_p _r) buf)))
        (elneo-room-settings--render room)))
    (mapcar (lambda (label) (and (string-search label (buffer-string)) t))
            labels)))

(defun mx--overview (room &optional buf)
  "Render ROOM's settings overview into a string, BUF as its room buffer.
The same binding shape the `C-c ?' help window gives the render."
  (with-temp-buffer
    (let ((standard-output (current-buffer)))
      (cl-letf (((symbol-function 'elneo-room--buffer-for)
                 (lambda (_p _r) (or buf 'no-buffer))))
        (elneo-room-settings--render room)))
    (buffer-string)))

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  ;; --- transport wrappers: the wire payload

  (mx-check "wrapper: inviteUser payload"
            (cdar (mx--with-capture
                   (elneo-invite-user "p" "!r" "@bob:example.org" #'ignore)))
            '((@type . "inviteUser") (room_id . "!r") (user_id . "@bob:example.org")))

  (mx-check "wrapper: kickUser with reason"
            (cdar (mx--with-capture
                   (elneo-kick-user "p" "!r" "@bob:example.org" "bye" #'ignore)))
            '((@type . "kickUser") (room_id . "!r") (user_id . "@bob:example.org")
              (reason . "bye")))

  (mx-check "wrapper: kickUser without reason key (not null on the wire)"
            (assq 'reason (cdar (mx--with-capture
                                 (elneo-kick-user "p" "!r" "@bob:x" nil #'ignore))))
            nil)

  (mx-check "wrapper: banUser with reason"
            (cdar (mx--with-capture
                   (elneo-ban-user "p" "!r" "@bob:example.org" "spam" #'ignore)))
            '((@type . "banUser") (room_id . "!r") (user_id . "@bob:example.org")
              (reason . "spam")))

  (mx-check "wrapper: banUser without reason key"
            (assq 'reason (cdar (mx--with-capture
                                 (elneo-ban-user "p" "!r" "@bob:x" nil #'ignore))))
            nil)

  (mx-check "wrapper: unbanUser payload"
            (cdar (mx--with-capture
                   (elneo-unban-user "p" "!r" "@bob:example.org" #'ignore)))
            '((@type . "unbanUser") (room_id . "!r") (user_id . "@bob:example.org")))

  (mx-check "wrapper: setRoomName payload"
            (cdar (mx--with-capture (elneo-set-room-name "p" "!r" "Ops" #'ignore)))
            '((@type . "setRoomName") (room_id . "!r") (name . "Ops")))

  (mx-check "wrapper: setRoomTopic clears an empty topic as \"\""
            (cdar (mx--with-capture (elneo-set-room-topic "p" "!r" nil #'ignore)))
            '((@type . "setRoomTopic") (room_id . "!r") (topic . "")))

  (mx-check "wrapper: setOwnDisplayName payload"
            (cdar (mx--with-capture
                   (elneo-set-own-room-display-name "p" "!r" "Nick" #'ignore)))
            '((@type . "setOwnDisplayName") (room_id . "!r") (name . "Nick")))

  (mx-check "wrapper: setOwnDisplayName clears by omission (not null)"
            (assq 'name (cdar (mx--with-capture
                               (elneo-set-own-room-display-name
                                "p" "!r" nil #'ignore))))
            nil)

  ;; --- ack wording

  (mx-check "ack: success reports and returns t"
            (let ((inhibit-message t))
              (elneo-room--ack-message '((@ok . t)) "invited bob" "invite failed"))
            t)

  (mx-check "ack: failure returns nil (no @ok, daemon error only)"
            (let ((inhibit-message t))
              (elneo-room--ack-message '((error . "denied")) "x" "invite failed"))
            nil)

  ;; --- member completion: label → id, typed ids pass through

  (with-current-buffer (mx--room-buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt _coll _p _r _h _hist default) default)))
          (mx-check "read-user-id: a roster label maps back to the id"
                    (elneo-room--read-user-id "Pick: " "Bob (@bob:example.org)")
                    "@bob:example.org")
          (mx-check "read-user-id: a typed id not in the roster passes through"
                    (elneo-room--read-user-id "Pick: " "@new:example.org")
                    "@new:example.org"))
      (kill-buffer)))

  ;; --- invite: the picker also offers people from open sibling rooms

  ;; Members of the same profile's other open room buffers extend the
  ;; roster: a DM partner opened elsewhere shows up as a candidate.
  ;; Anything the current roster already answers for stays out (a
  ;; duplicate label would shadow its pick), so does the room's own
  ;; user, so does another profile's room, and a dead buffer is
  ;; never consulted.
  (let (dm other dead)
    (unwind-protect
        (with-current-buffer (mx--room-buffer)
          (setq dm (generate-new-buffer " *mx-known-dm*")
                other (generate-new-buffer " *mx-known-other*"))
          (puthash (cons "mxtest" "!dm-known") dm elneo-room--buffers)
          (puthash (cons "stranger" "!dm-known") other elneo-room--buffers)
          (with-current-buffer dm
            (elneo-room-mode)
            (setq-local elneo-room--profile "mxtest")
            (setq-local elneo-room--members
                        (list (list :user-id "@carol:example.org" :name "Carol")
                              (list :user-id "@dave:example.org")
                              (list :user-id "@bob:example.org" :name "Bob")
                              (list :user-id "@me:example.org" :name "Me"))))
          (with-current-buffer other
            (elneo-room-mode)
            (setq-local elneo-room--profile "stranger")
            (setq-local elneo-room--members
                        (list (list :user-id "@far:example.org" :name "Far"))))
          ;; A killed buffer stays in the hash: the sweep skips it.
          (setq dead (generate-new-buffer " *mx-known-dead*"))
          (kill-buffer dead)
          ;; The synthetic profile is unregistered — pin the own id so
          ;; the self-exclusion is under test, not the lookup.
          (cl-letf (((symbol-function 'elneo-server--user-id)
                     (lambda (_p) "@me:example.org")))
            (mx-check
             "known people: sibling rosters fill in past the current one"
             (mapcar #'cadr (elneo-room--known-people-entries))
             '("@bob:example.org" "@eve:example.org"
               "@carol:example.org" "@dave:example.org"))
            ;; The pick maps a sibling label back to its id, and the
            ;; label was really on offer; a typed stranger passes with
            ;; known candidates too.
            (let (collected picked)
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (_prompt coll &rest _)
                           (setq collected (mapcar #'car coll))
                           (car (car (last coll))))))
                (setq picked (elneo-room--read-user-id "Pick: " nil 'known)))
              (mx-check "pick: the offered collection carries the sibling"
                        (and (member "Carol (@carol:example.org)" collected) t)
                        t)
              (mx-check "pick: a sibling label maps back to the id"
                        picked "@dave:example.org"))
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (&rest _) "@new:example.org")))
              (mx-check "pick: with known, a typed stranger still wins"
                        (elneo-room--read-user-id "Pick: " nil 'known)
                        "@new:example.org"))))
      (remhash (cons "mxtest" "!dm-known") elneo-room--buffers)
      (remhash (cons "stranger" "!dm-known") elneo-room--buffers)
      (dolist (buf (list dm other dead))
        (when (buffer-live-p buf) (kill-buffer buf)))))

  ;; --- the auto-completion trigger opens only on a fresh @

  ;; this-command self-insert + char-before @ arms it; the context
  ;; decides: at the head of the draft or behind whitespace the picker
  ;; opens, glued onto text it stays quiet — foo@bar.com is an email.
  ;; The picker is stubbed; only the gating is under test.  In text
  ;; "@o @@\n@" the four @ sit before points 2 5 6 8, with head of
  ;; draft, space, another @ and a newline behind them: three fire,
  ;; the glued one does not.
  (let ((fired 0))
    (with-current-buffer (mx--room-buffer)
      (setq-local elneo-room--input-beg (copy-marker 1))
      (insert "@o @@\n@")
      (cl-letf (((symbol-function 'elneo-room--complete-mention)
                 (lambda () (cl-incf fired)))
                (elneo-room-mention-auto-complete t)
                (this-command 'self-insert-command))
        (dolist (p '(2 5 6 8))
          (goto-char p)
          (elneo-room--maybe-autocomplete-mention))))
    (mx-check "gate: three fresh @ fire, the glued one does not" fired 3))

  ;; The defcustom off: no trigger even on a fresh @.  A non-self-
  ;; insert @ (yank, quoted insert): silent as well.
  (let ((fired 0))
    (with-current-buffer (mx--room-buffer)
      (setq-local elneo-room--input-beg (copy-marker 1))
      (insert "@o")
      (cl-letf (((symbol-function 'elneo-room--complete-mention)
                 (lambda () (cl-incf fired))))
        (let ((this-command 'self-insert-command))
          (let ((elneo-room-mention-auto-complete nil))
            (goto-char 2) (elneo-room--maybe-autocomplete-mention))
          (let ((this-command 'mx-yank))
            (goto-char 2) (elneo-room--maybe-autocomplete-mention))))
      (mx-check "gate: silenced by auto-complete off and non-self-insert"
                fired 0)))

  ;; --- commands: empty reason dropped, real reason kept

  (with-current-buffer (mx--room-buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) "@bob:example.org")))
          (mx-check "command: invite payload to the picked member"
                    (cdr (car (mx--with-capture (elneo-room-invite "x"))))
                    '((@type . "inviteUser") (room_id . "!room")
                      (user_id . "x")))
          (mx-check "command: kick with an empty reason drops the key"
                    (cdr (car (mx--with-capture (elneo-room-kick "x" ""))))
                    '((@type . "kickUser") (room_id . "!room")
                      (user_id . "x")))
          (mx-check "command: kick keeps a real reason"
                    (assq 'reason (cdr (car (mx--with-capture
                                             (elneo-room-kick "x" "bye")))))
                    '(reason . "bye"))
          (mx-check "command: set-name payload"
                    (cdr (car (mx--with-capture (elneo-room-set-name "Ops v2"))))
                    '((@type . "setRoomName") (room_id . "!room") (name . "Ops v2")))
          (mx-check "command: set-topic payload"
                    (cdr (car (mx--with-capture (elneo-room-set-topic "hello"))))
                    '((@type . "setRoomTopic") (room_id . "!room") (topic . "hello")))
          ;; Nick: a nil NAME goes out as the omitted field.
          (mx-check "command: set-nick payload with a name"
                    (cdr (car (mx--with-capture (elneo-room-set-nick "Nick"))))
                    '((@type . "setOwnDisplayName") (room_id . "!room")
                      (name . "Nick")))
          (mx-check "command: set-nick clear omits the name key"
                    (assq 'name (cdr (car (mx--with-capture
                                           (elneo-room-set-nick nil)))))
                    nil))
      (kill-buffer)))

  ;; --- leave: confirmation, kill-on-ack

  (with-current-buffer (mx--room-buffer)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'elneo-room-get)
               (lambda (_p _r) (list :display-name "Ops" :room-state "joined"))))
      (let ((buf (current-buffer))
            (calls (mx--with-capture (elneo-room-leave))))
        (mx-check "leave: leaveRoom on the wire after confirmation"
                  (cdar calls)
                  '((@type . "leaveRoom") (room_id . "!room")))
        (mx-check "leave: the room buffer closes with the ack"
                  (buffer-live-p buf) nil))))

  (with-current-buffer (mx--room-buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
                  ((symbol-function 'elneo-room-get)
                   (lambda (_p _r) (list :display-name "Ops" :room-state "joined"))))
          (mx-check "leave: without confirmation nothing goes out"
                    (mx--with-capture (elneo-room-leave)) nil))
      (kill-buffer)))

  ;; --- forget: only left rooms, on the wire for left ones

  (with-current-buffer (mx--room-buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'elneo-room-get)
                   (lambda (_p _r) (list :display-name "Ops" :room-state "joined"))))
          (mx-check "forget: a joined room refuses"
                    (condition-case err (elneo-room-forget)
                      (user-error (error-message-string err)))
                    "Only left rooms can be forgotten — leave it first"))
      (kill-buffer)))

  (with-current-buffer (mx--room-buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'elneo-room-get)
                   (lambda (_p _r) (list :display-name "Ops" :room-state "left"))))
          (mx-check "forget: a left room sends forgetRoom"
                    (cdr (car (mx--with-capture (elneo-room-forget))))
                    '((@type . "forgetRoom") (room_id . "!room"))))
      (kill-buffer)))

  ;; --- the C-c ? actions row: buttons follow the room's state ---
  ;; The name and the topic anchor their own buttons on the facts
  ;; (joined rooms with a live buffer only); the actions row keeps
  ;; the anchorless ones.  The string searches run over the whole
  ;; render, so [rename]/[topic] still match — anchored, not rowed.

  (let ((room-buf (mx--room-buffer)))
    (unwind-protect
        (progn
          (mx-check "settings: joined room offers the full set"
                    (mx--settings-bools
                     (list :profile "mxtest" :room-id "!room"
                           :display-name "Ops" :unread 0 :highlights 0
                           :room-state "joined")
                     room-buf
                     '("[invite]" "[kick]" "[ban]" "[rename]" "[topic]"
                       "[nick]" "[leave]" "[forget]"))
                    '(t t t t t t t nil))
          (mx-check "settings: the Name fact carries the current nick"
                    (and (with-temp-buffer
                           (let ((standard-output (current-buffer)))
                             (cl-letf (((symbol-function 'elneo-room--buffer-for)
                                        (lambda (_p _r) room-buf)))
                               (elneo-room-settings--render
                                (list :profile "mxtest" :room-id "!room"
                                      :display-name "Ops" :unread 0
                                      :highlights 0 :room-state "joined"))))
                           (string-search "  Name:          Ops"
                                          (buffer-string)))
                         t)
                    t)
          (mx-check "settings: the Name button sits next to the fact"
                    (and (with-temp-buffer
                           (let ((standard-output (current-buffer)))
                             (cl-letf (((symbol-function 'elneo-room--buffer-for)
                                        (lambda (_p _r) room-buf)))
                               (elneo-room-settings--render
                                (list :profile "mxtest" :room-id "!room"
                                      :name "Real Name" :display-name "Ops"
                                      :unread 0 :highlights 0
                                      :room-state "joined"))))
                           (string-search "  Name:          Real Name [rename]"
                                          (buffer-string)))
                         t)
                    t)
          (mx-check "settings: the Topic button anchors the topic line"
                    (and (with-temp-buffer
                           (let ((standard-output (current-buffer)))
                             (cl-letf (((symbol-function 'elneo-room--buffer-for)
                                        (lambda (_p _r) room-buf)))
                               (elneo-room-settings--render
                                (list :profile "mxtest" :room-id "!room"
                                      :unread 0 :highlights 0
                                      :room-state "joined"
                                      :topic "hello\nsecond line"))))
                           (string-search
                            "  Topic:         hello [topic]"
                            (buffer-string)))
                         t)
                    t)
          (mx-check "settings: the multiline topic continues indented"
                    (with-temp-buffer
                      (let ((standard-output (current-buffer)))
                        (cl-letf (((symbol-function 'elneo-room--buffer-for)
                                   (lambda (_p _r) room-buf)))
                          (elneo-room-settings--render
                           (list :profile "mxtest" :room-id "!room"
                                 :unread 0 :highlights 0 :room-state "joined"
                                 :topic "hello\nsecond line"))))
                      (and (string-search "  Topic:         hello [topic]"
                                          (buffer-string))
                           (string-search "\n    second line"
                                          (buffer-string))
                           t))
                    t)
          (mx-check "settings: a topic-less room still offers [topic]"
                    (and (with-temp-buffer
                           (let ((standard-output (current-buffer)))
                             (cl-letf (((symbol-function 'elneo-room--buffer-for)
                                        (lambda (_p _r) room-buf)))
                               (elneo-room-settings--render
                                (list :profile "mxtest" :room-id "!room"
                                      :unread 0 :highlights 0
                                      :room-state "joined"))))
                           (string-search "  Topic:          [topic]"
                                          (buffer-string)))
                         t)
                    t)
          (mx-check "settings: a left room only offers forget"
                    (mx--settings-bools
                     (list :profile "mxtest" :room-id "!room"
                           :display-name "Ops" :unread 0 :highlights 0
                           :room-state "left")
                     nil
                     '("[forget]" "[leave]" "[invite]"
                       "[rename]" "[topic]" "[nick]"))
                    '(t nil nil nil nil nil))
          (mx-check "settings: without the room buffer the actions stay off"
                    (mx--settings-bools
                     (list :profile "mxtest" :room-id "!room"
                           :display-name "Ops" :unread 0 :highlights 0
                           :room-state "joined")
                     nil
                     '("[invite]" "[kick]" "[rename]" "[nick]"))
                    '(nil nil nil nil))
          ;; The nick fact reads the account's roster entry: the
          ;; display name as this room's member state sees it, next
          ;; to the Profile line it refines; its button joins the
          ;; joined-only facts (a live buffer is the only way the
          ;; roster is known — no row without one).
          (mx-check "settings: the Nick fact shows the room-active name"
                    (and (with-temp-buffer
                           (let ((standard-output (current-buffer))
                                 (elneo-server--sessions
                                  (list (cons "mxtest"
                                              '(:user-id "@me:example.org")))))
                             (cl-letf (((symbol-function 'elneo-room--buffer-for)
                                        (lambda (_p _r) room-buf)))
                               (elneo-room-settings--render
                                (list :profile "mxtest" :room-id "!room"
                                      :unread 0 :highlights 0
                                      :room-state "joined"))))
                           (string-search "  Nick:          Me"
                                          (buffer-string)))
                         t)
                    t)
          (mx-check "settings: no profile entry renders the fallback nick"
                    (and (with-temp-buffer
                           (let ((standard-output (current-buffer)))
                             (cl-letf (((symbol-function 'elneo-room--buffer-for)
                                        (lambda (_p _r) room-buf)))
                               (elneo-room-settings--render
                                (list :profile "mxtest" :room-id "!room"
                                      :unread 0 :highlights 0
                                      :room-state "joined"))))
                           (string-search "  Nick:          (the profile name)"
                                          (buffer-string)))
                         t)
                    t)
          ;; The nick's button anchors its fact line like [rename] does:
          ;; the newline comes after the button, not before it.
          (mx-check "settings: the Nick button anchors the nick line"
                    (and (with-temp-buffer
                           (let ((standard-output (current-buffer))
                                 (elneo-server--sessions
                                  (list (cons "mxtest"
                                              '(:user-id "@me:example.org")))))
                             (cl-letf (((symbol-function 'elneo-room--buffer-for)
                                        (lambda (_p _r) room-buf)))
                               (elneo-room-settings--render
                                (list :profile "mxtest" :room-id "!room"
                                      :unread 0 :highlights 0
                                      :room-state "joined"))))
                           (string-search "  Nick:          Me [nick]"
                                          (buffer-string)))
                         t)
                    t)
          ;; Unjoined (the left state), the button is gone but the
          ;; fact's newline is not: the line never merges into Room id.
          (mx-check "settings: an unjoined room's nick line never merges"
                    (and (with-temp-buffer
                           (let ((standard-output (current-buffer))
                                 (elneo-server--sessions
                                  (list (cons "mxtest"
                                              '(:user-id "@me:example.org")))))
                             (cl-letf (((symbol-function 'elneo-room--buffer-for)
                                        (lambda (_p _r) room-buf)))
                               (elneo-room-settings--render
                                (list :profile "mxtest" :room-id "!room"
                                      :unread 0 :highlights 0
                                      :room-state "left"))))
                           (string-search "  Nick:          Me\n  Room id:"
                                          (buffer-string)))
                         t)
                    t)
          ;; The fontify fix: the separator space is not part of the
          ;; button — the button's properties start AT the label, so
          ;; the face it carries underlines at the label's edge, not
          ;; one character early.
          (mx-check "settings: the separator space carries no button properties"
                    (and
                     (with-temp-buffer
                       (let ((standard-output (current-buffer)))
                         (elneo-room--settings-button "[x]" "help" #'ignore))
                       (let ((sep (text-properties-at (point-min))))
                         (and (= (char-after (point-min)) 32)
                              (not (plist-get sep 'help-echo))
                              (not (plist-get sep 'action))
                              (= (char-after (1+ (point-min))) 91)
                              (string= (plist-get
                                        (text-properties-at (1+ (point-min)))
                                        'help-echo)
                                       "help"))))
                     t)
                    t))
      (kill-buffer room-buf)))

  ;; --- join/create: the new-room slice

  (mx-check "wrapper: minimal create sends only the type"
            (cdar (mx--with-capture (elneo-create-room "p" nil #'ignore)))
            '((@type . "createRoom")))

  (mx-check "wrapper: full create payload"
            (cdar (mx--with-capture
                   (elneo-create-room "p" (list :name "Ops" :alias "ops"
                                                 :public t :topic "hi"
                                                 :invites '("@u:hs")
                                                 :is-direct t)
                                       #'ignore)))
            '((@type . "createRoom")
              (name . "Ops") (alias . "ops") (public . t)
              (topic . "hi") (invites . ("@u:hs")) (is_direct . t)))

  (mx-check "wrapper: create drops nil props (no null/nil on the wire)"
            (assq 'alias (cdar (mx--with-capture
                                (elneo-create-room "p" (list :name "X")
                                                    #'ignore))))
            nil)

  (mx-check "command: create drops empty name/alias/topic and nil public"
            (cdar (mx--with-capture (elneo-room-create "p" "" "ops" nil "" nil)))
            '((@type . "createRoom") (alias . "ops")))

  (mx-check "command: create full shape"
            (cdar (mx--with-capture (elneo-room-create "p" "Ops" "ops" t "hi" t)))
            '((@type . "createRoom") (name . "Ops") (alias . "ops")
              (public . t) (topic . "hi") (encrypted . t)))

  (mx-check "wrapper: create carries encrypted"
            (cdar (mx--with-capture
                   (elneo-create-room "p" (list :invites '("@u:hs")
                                                 :is-direct t :encrypted t)
                                       #'ignore)))
            '((@type . "createRoom")
              (invites . ("@u:hs")) (is_direct . t) (encrypted . t)))

  (mx-check "command: start-dm is direct, encrypted, invites only"
            (cdar (mx--with-capture
                   (elneo-room-start-dm "p" "@bob:example.org")))
            '((@type . "createRoom")
              (invites . ("@bob:example.org"))
              (is_direct . t) (encrypted . t)))

  (mx-check "command: join sends room_id_or_alias"
            (cdar (mx--with-capture (elneo-room-join "p" "#ops")))
            '((@type . "joinRoom") (room_id_or_alias . "#ops")))

  ;; --- profile editing: the account commands

  (mx-check "wrapper: setDisplayName carries the name"
            (cdar (mx--with-capture
                   (elneo-set-display-name "p" "Me" #'ignore)))
            '((@type . "setDisplayName") (name . "Me")))

  (mx-check "wrapper: setDisplayName nil clears (no field on the wire)"
            (cdar (mx--with-capture
                   (elneo-set-display-name "p" nil #'ignore)))
            '((@type . "setDisplayName")))

  (mx-check "wrapper: setAvatar carries the path"
            (cdar (mx--with-capture
                   (elneo-set-avatar "p" "/tmp/a.png" #'ignore)))
            '((@type . "setAvatar") (local_path . "/tmp/a.png")))

  ;; read-file-name hands back `~/'-abbrevations and relative names
  ;; as typed, and the daemon chokes on the unexpanded tilde.
  (mx-check "wrapper: setAvatar expands a home-abbrevated path"
            (cdar (mx--with-capture
                   (elneo-set-avatar "p" "~/avatars/me.png" #'ignore)))
            `((@type . "setAvatar")
              (local_path . ,(expand-file-name "~/avatars/me.png"))))

  (mx-check "wrapper: setRoomAvatar expands a relative path"
            (cdar (mx--with-capture
                   (elneo-set-room-avatar "p" "!r" "rel.png" #'ignore)))
            `((@type . "setRoomAvatar") (room_id . "!r")
              (local_path . ,(expand-file-name "rel.png"))))

  (mx-check "command: a display-name edit sends the name"
            (cdar (mx--with-capture (elneo-account-set-name "p" "New me")))
            '((@type . "setDisplayName") (name . "New me")))

  (mx-check "command: an empty display name clears"
            (cdar (mx--with-capture (elneo-account-set-name "p" "")))
            '((@type . "setDisplayName")))

  ;; --- protocol 15: room avatar + the permissions gates

  (mx-check "wrapper: setRoomAvatar carries the path"
            (cdar (mx--with-capture
                   (elneo-set-room-avatar "p" "!r" "/tmp/r.png" #'ignore)))
            '((@type . "setRoomAvatar") (room_id . "!r")
              (local_path . "/tmp/r.png")))

  (mx-check "wrapper: setRoomAvatar clears by omission (no path key)"
            (cdar (mx--with-capture
                   (elneo-set-room-avatar "p" "!r" nil #'ignore)))
            '((@type . "setRoomAvatar") (room_id . "!r")))

  (mx-check "wrapper: roomPermissions payload"
            (cdar (mx--with-capture
                   (elneo-room-permissions "p" "!r" #'ignore)))
            '((@type . "roomPermissions") (room_id . "!r")))

  ;; The snapshot: the response's booleans land as gate plist
  ;; (JSON false arrived as nil at parse time), cached and mirrored.
  (let* ((room-buf (mx--room-buffer))
         (perms '((@ok . t) (level . 50) (creator . nil)
                  (can_name . t) (can_topic . nil) (can_avatar . t)
                  (can_invite . t) (can_kick . nil) (can_ban . nil)
                  (can_power . nil))))
    (unwind-protect
        (with-current-buffer room-buf
          (cl-letf (((symbol-function 'elneo-server--call)
                     (lambda (_p _cmd cb)
                       (funcall cb "mxtest" perms)))
                    ((symbol-function 'elneo-room-get) (lambda (_p _r) nil)))
            (elneo-room--fetch-permissions))
          (mx-check "permissions: an allowed gate stored"
                    (plist-get elneo-room--permissions :can-name) t)
          (mx-check "permissions: a withheld gate stored"
                    (plist-get elneo-room--permissions :can-ban) nil)
          (mx-check "permissions: the level and creator ride the snapshot"
                    (list (plist-get elneo-room--permissions :level)
                          (plist-get elneo-room--permissions :creator))
                    '(50 nil))
          (mx-check "permissions: the cache carries the snapshot"
                    (gethash (cons "mxtest" "!room")
                             elneo-room--permissions-cache)
                    elneo-room--permissions)
          (mx-check "gate: an allowed action passes"
                    (condition-case err
                        (progn (elneo-room--ensure-permission :can-name
                                 "rename")
                               t)
                      (user-error (error-message-string err)))
                    t)
          (mx-check "gate: a withheld action refuses, level in the message"
                    (condition-case err
                        (progn (elneo-room--ensure-permission :can-ban "ban")
                               nil)
                      (user-error (error-message-string err)))
                    "Not allowed to ban here (power level 50)")
          (mx-check "gate: a creator snapshots as \"creator\""
                    (let ((elneo-room--permissions
                           (plist-put (copy-sequence
                                       elneo-room--permissions)
                                      :creator t)))
                      (elneo-room--permissions-level
                       elneo-room--permissions))
                    "creator")
          (mx-check "permissions-level: a plain member prints the integer"
                    (elneo-room--permissions-level elneo-room--permissions)
                    "50"))
      (kill-buffer room-buf)))

  ;; An unknown snapshot (never fetched) lets every action through —
  ;; the homeserver has the last word.
  (with-current-buffer (mx--room-buffer)
    (mx-check "gate: an unknown snapshot lets the action through"
              (condition-case err
                  (progn (elneo-room--ensure-permission :can-ban "ban") t)
                (user-error (error-message-string err)))
              t))

  ;; The settings view reads the room buffer's snapshot: withheld
  ;; gates hide their buttons; the Permissions section prints the
  ;; level with the can/cannot lists.
  (let ((room-buf (mx--room-buffer)))
    (unwind-protect
        (with-current-buffer room-buf
          (setq-local elneo-room--permissions
                      (list :fetched t :level 50 :creator nil
                            :can-name t :can-topic t :can-avatar nil
                            :can-invite t :can-kick nil :can-ban nil
                            :can-power t))
          (mx-check "settings: withheld gates hide their buttons"
                    (mx--settings-bools
                     (list :profile "mxtest" :room-id "!room"
                           :display-name "Ops" :unread 0 :highlights 0
                           :room-state "joined")
                     room-buf
                     '("[invite]" "[kick]" "[ban]" "[rename]" "[topic]"
                       "[set]" "[clear]" "[nick]" "[leave]"))
                    '(t nil nil t t nil nil t t))
          (mx-check "settings: the Permissions section prints the gates"
                    (and (with-temp-buffer
                           (let ((standard-output (current-buffer)))
                             (cl-letf (((symbol-function
                                         'elneo-room--buffer-for)
                                        (lambda (_p _r) room-buf)))
                               (elneo-room-settings--render
                                (list :profile "mxtest" :room-id "!room"
                                      :display-name "Ops" :unread 0
                                      :highlights 0
                                      :room-state "joined"))))
                           (let ((text (buffer-string)))
                             (and (string-search "  Level:         50"
                                                 text)
                                  (string-search
                                   "  Can change:    name, topic, invite, power levels"
                                   text)
                                  (string-search
                                   "  Not allowed:   avatar, kick, ban"
                                   text)
                                  t)))
                         t)
                    t))
      (kill-buffer room-buf)))

  ;; No snapshot yet (the fetch still running): the view says so and
  ;; every button still shows.
  (let ((room-buf (mx--room-buffer)))
    (unwind-protect
        (with-current-buffer room-buf
          (setq-local elneo-room--permissions nil)
          (mx-check "settings: an unknown snapshot keeps every button"
                    (mx--settings-bools
                     (list :profile "mxtest" :room-id "!room"
                           :display-name "Ops" :unread 0 :highlights 0
                           :room-state "joined")
                     room-buf
                     '("[invite]" "[kick]" "[ban]" "[rename]" "[topic]"
                       "[set]" "[clear]" "[nick]"))
                    '(t t t t t t nil t))
          (mx-check "settings: the pending Permissions line is printed"
                    (and (with-temp-buffer
                           (let ((standard-output (current-buffer)))
                             (cl-letf (((symbol-function
                                         'elneo-room--buffer-for)
                                        (lambda (_p _r) room-buf)))
                               (elneo-room-settings--render
                                (list :profile "mxtest" :room-id "!room"
                                      :display-name "Ops" :unread 0
                                      :highlights 0
                                      :room-state "joined"))))
                           (string-search
                            "the permissions snapshot has not landed yet"
                            (buffer-string)))
                         t)
                    t))
      (kill-buffer room-buf)))

  ;; The command sends the avatar change; the empty answer is a clear.
  (with-current-buffer (mx--room-buffer)
    (let ((path (make-temp-file "mx-avatar-test")))
      (unwind-protect
          (progn
            (mx-check "command: set-avatar sends the file"
                      (cdr (car (mx--with-capture
                                 (elneo-room--avatar-change path))))
                      `((@type . "setRoomAvatar") (room_id . "!room")
                        ,@(list (cons 'local_path (expand-file-name path)))))
            (mx-check "command: the clear sends no path key"
                      (assq 'local_path
                            (cdr (car (mx--with-capture
                                       (elneo-room--avatar-change "")))))
                      nil))
        (delete-file path))))

  ;; --- forwarding

  ;; Calling the command non-interactively with the room record in
  ;; hand: room picks complete only in the interactive form.

  (let ((calls (mx--with-capture
                (cl-letf (((symbol-function 'elneo-room--event-id-at)
                           (lambda (_pos) "$e1")))
                  (with-current-buffer (mx--room-buffer)
                    (puthash "$e1" (list :body "hello"
                                         :formatted-body "<b>hello</b>")
                             elneo-room--seen)
                    (elneo-room-forward (list :profile "tp" :room-id "!t")))))))
    (mx-check "forward: text body and formatted body go out"
              (cdr (car calls))
              '((@type . "sendMessage") (room_id . "!t") (body . "hello")
                (formatted_body . "<b>hello</b>"))))

  (let ((src (make-temp-file "mx-forward-test")))
    (write-region "x" nil src nil :silent)
    (let ((calls (mx--with-capture
                  (cl-letf (((symbol-function 'elneo-room--event-id-at)
                             (lambda (_pos) "$m1"))
                            ((symbol-function 'elneo-download-media)
                             (lambda (_p _source _format cb _name)
                               (funcall cb "tp"
                                        (list '(@ok . t)
                                              (cons 'path src))))))
                    (with-current-buffer (mx--room-buffer)
                      (puthash "$m1" (list :body "[image]"
                                           :media '((filename . "a.png")
                                                    (source . "mxc://x/y")))
                               elneo-room--seen)
                      (elneo-room-forward (list :profile "tp" :room-id "!t")))))))
      (mx-check "forward: media sends as a file to the picked room"
                (assq 'room_id (cdr (car calls)))
                '(room_id . "!t"))
      (mx-check "forward: media stages under its original name"
                (string-suffix-p
                 "a.png"
                 (file-name-nondirectory (cdr (assq 'path (cdr (car calls))))))
                t)
      (delete-file src)))

  ;; A nameless image (image events carry no filename field): the
  ;; staged copy goes out as "forwarded" and the source event's
  ;; mimetype and info ride the command instead — no name guess left
  ;; between the forward and the recipient's msgtype.
  (let ((src (make-temp-file "mx-forward-test")))
    (write-region "x" nil src nil :silent)
    (let ((calls (mx--with-capture
                  (cl-letf (((symbol-function 'elneo-room--event-id-at)
                             (lambda (_pos) "$m1"))
                            ((symbol-function 'elneo-download-media)
                             (lambda (_p _source _format cb _name)
                               (funcall cb "tp"
                                        (list '(@ok . t)
                                              (cons 'path src))))))
                    (with-current-buffer (mx--room-buffer)
                      (puthash "$m1" (list :body "[image]"
                                           :media '((source . "mxc://x/y")
                                                    (mimetype . "image/jpeg")
                                                    (width . 800) (height . 600)))
                               elneo-room--seen)
                      (elneo-room-forward (list :profile "tp" :room-id "!t")))))))
      (mx-check "forward: a nameless image stages as forwarded"
                (string-suffix-p
                 "forwarded"
                 (file-name-nondirectory (cdr (assq 'path (cdr (car calls))))))
                t)
      (mx-check "forward: the source mime rides the command"
                (cdr (assq 'mime (cdr (car calls)))) "image/jpeg")
      (mx-check "forward: only dims, no duration/size on an image"
                (cdr (assq 'info (cdr (car calls))))
                '((width . 800) (height . 600)))
      (delete-file src)))

  ;; The forward re-sends the source event's info, keyed per media
  ;; kind (dims/duration/size — `elneo-room--forward-params').
  (mx-check "forward-params: dims, duration, size in wire key order"
            (elneo-room--forward-params
             '((mimetype . "video/mp4") (width . 1280) (height . 720)
               (duration . 4500) (size . 9999)))
            '("video/mp4" ((width . 1280) (height . 720) (duration . 4500)
                           (size . 9999))))
  (mx-check "forward-params: an unknown mime sends nil (name guess)"
            (elneo-room--forward-params '((filename . "x")))
            '(nil nil))
  (mx-check "forward-params: absent info fields are skipped"
            (cadr (elneo-room--forward-params '((mimetype . "application/zip"))))
            nil)

  ;; The forward refuses a replaced target before anything is staged —
  ;; even before the message-at-point lookup.
  (mx-check "forward: a replaced target is refused first"
            (condition-case e
                (progn (elneo-room-forward
                        (list :profile "p" :room-id "!dead"
                              :display-name "Old" :upgraded-to "!new"))
                       'no-error)
              (user-error e))
            '(user-error "Matrix: Old was replaced — send in !new instead"))

  (let ((elneo--rooms (make-hash-table :test 'equal)))
    (puthash (cons "p1" "!r1")
             (list :profile "p1" :room-id "!r1" :display-name "Ops1")
             elneo--rooms)
    (puthash (cons "p2" "!r2")
             (list :profile "p2" :room-id "!r2" :display-name "Ops2")
             elneo--rooms)
    (let (offered)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_p coll &rest _) (setq offered (copy-sequence coll))
                                            (car coll))))
        (mx-check "pick: a profile filter limits the offering"
                  (elneo-completing-read-room "p2")
                  (list :profile "p2" :room-id "!r2" :display-name "Ops2"))
        (mx-check "pick: the filtered pool holds only that account"
                  offered '("p2: Ops2"))
        (setq offered nil)
        (let ((chosen (elneo-completing-read-room)))
          ;; the pick covers both accounts: one label per account,
          ;; and the returned record is the one behind the label
          (mx-check "pick: without the filter all accounts are offered"
                    (length offered) 2)
          (mx-check "pick: the unfiltered pool covers both accounts"
                    (sort (copy-sequence offered) #'string<)
                    '("p1: Ops1" "p2: Ops2"))
          (mx-check "pick: the chosen record matches its label"
                    (and (member (format "%s: %s" (plist-get chosen :profile)
                                         (plist-get chosen :display-name))
                                 offered)
                         t)
                    t)))))

  ;; Same profile and display name: an upgraded-away twin renders like
  ;; its successor.  The twin is marked " [replaced]" and offered
  ;; last, the successor keeps the plain label; before the fix assoc
  ;; returned whichever room hash order put first, and completion
  ;; showed one candidate.
  (let ((elneo--rooms (make-hash-table :test 'equal)))
    (puthash (cons "p1" "!dead")
             (list :profile "p1" :room-id "!dead" :display-name "Ops"
                   :upgraded-to "!live")
             elneo--rooms)
    (puthash (cons "p1" "!live")
             (list :profile "p1" :room-id "!live" :display-name "Ops")
             elneo--rooms)
    (let (offered)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_p coll &rest _)
                   (setq offered (copy-sequence coll))
                   (car coll))))
        (elneo-completing-read-room "p1")
        (mx-check "pick: the twin is marked and offered last"
                  offered
                  '("p1: Ops" "p1: Ops [replaced]"))
        (setq offered nil)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_p coll &rest _) (car (member "p1: Ops" coll)))))
          (let ((chosen (elneo-completing-read-room "p1")))
            (mx-check "pick: the plain label resolves to the successor"
                      (plist-get chosen :room-id) "!live")))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_p coll &rest _)
                     (car (member "p1: Ops [replaced]" coll)))))
          (let ((chosen (elneo-completing-read-room "p1")))
            (mx-check "pick: the marked twin resolves to itself"
                      (plist-get chosen :room-id) "!dead"))))))

  ;; A genuine collision — two live same-name rooms — still needs the
  ;; id fallback: the marker only speaks for upgraded rooms.
  (let ((elneo--rooms (make-hash-table :test 'equal)))
    (puthash (cons "p1" "!a")
             (list :profile "p1" :room-id "!a" :display-name "Twin")
             elneo--rooms)
    (puthash (cons "p1" "!b")
             (list :profile "p1" :room-id "!b" :display-name "Twin")
             elneo--rooms)
    (let (offered)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_p coll &rest _)
                   (setq offered (sort (copy-sequence coll) #'string<))
                   (car (member "p1: Twin [!b]" coll)))))
        (let ((chosen (elneo-completing-read-room "p1")))
          (mx-check "pick: two live same-name rooms get id-tagged labels"
                    offered
                    '("p1: Twin [!a]" "p1: Twin [!b]"))
          (mx-check "pick: an id-tagged label resolves to its own room"
                    (plist-get chosen :room-id) "!b")))))

  ;; The `f' key shares the keymap with the draft: a direct bind broke
  ;; typing f there.  The defkey wrapper must self-insert in the draft
  ;; and reach elneo-room-forward over history.
  (let (selfed forwarded)
    (cl-letf (((symbol-function 'self-insert-command)
               (lambda (_n _c) (setq selfed ?f)))
              ((symbol-function 'elneo-room-forward)
               #'(lambda (&rest _args) (interactive) (setq forwarded t)))
              ((symbol-function 'elneo-completing-read-room)
               (lambda (&optional _p) (list :profile "p" :room-id "!t")))
              ((symbol-function 'elneo-room--in-input-p) (lambda () t)))
      (elneo-room--f)
      (cl-letf (((symbol-function 'elneo-room--in-input-p) (lambda () nil)))
        (elneo-room--f))
      (mx-check "key: `f' in the draft self-inserts (regression: direct bind)"
                selfed ?f)
      (mx-check "key: `f' over history forwards" forwarded t)))

  (let (opened)
    (cl-letf (((symbol-function 'elneo-room-get)
               (lambda (_p _r) (list :profile "p" :room-id "!new")))
              ((symbol-function 'elneo-room--open)
               (lambda (room) (setq opened room))))
      (mx--with-capture (elneo-room-join "p" "!new")))
    (mx-check "command: join opens the room on the ack"
              opened '(:profile "p" :room-id "!new")))

  (let (opened)
    (cl-letf (((symbol-function 'elneo-room-get) (lambda (_p _r) 'room))
              ((symbol-function 'elneo-room--open)
               (lambda (room) (setq opened room))))
      (mx--with-capture (elneo-room-create "p" "Ops" "ops" nil "" nil)))
    (mx-check "command: create opens the room on the ack" opened 'room))

  (let (err-text)
    (cl-letf (((symbol-function 'elneo-server--call)
               (lambda (_p _event cb) (funcall cb "p" '((@error . "not allowed")))))
              ((symbol-function 'elneo-server--error-string)
               (lambda (_e) "not allowed"))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (when (string-prefix-p "Matrix:" fmt)
                   (setq err-text (apply #'format-message fmt args))))))
      (elneo-room-join "p" "#denied"))
    (mx-check "command: join failure reports the daemon error"
              err-text "Matrix: join failed — not allowed"))

  (mx-check "read-profile: outside a room buffer, completing over accounts"
            (with-temp-buffer
              (cl-letf (((symbol-function 'elneo--accounts-load) #'ignore)
                        ((symbol-function 'completing-read)
                         (lambda (_p _c &rest _) "p2")))
                (let ((elneo-accounts '(("p1") ("p2"))))
                  (elneo-room--read-profile))))
            "p2")

  (mx-check "read-profile: a room buffer answers its own profile"
            (let ((buf (mx--room-buffer)))
              (prog1 (with-current-buffer buf (elneo-room--read-profile))
                (kill-buffer buf)))
            "mxtest")

  (let (opened)
    (cl-letf (((symbol-function 'elneo-room-get)
               (lambda (_p _r) 'room))
              ((symbol-function 'elneo-room--open)
               (lambda (room) (setq opened room)))
              ((symbol-function 'elneo-room--read-user-id)
               (lambda (_p &optional _d) "@bob:example.org")))
      (with-current-buffer (mx--room-buffer)
        (mx--with-capture (elneo-room-start-dm "mxtest" "@bob:example.org"))
        (kill-buffer)))
    (mx-check "command: start-dm opens the room on the ack" opened 'room))

  ;; --- ack callbacks: the room name is captured at send time

  ;; The ack lambda runs later, in the daemon's process buffer, where
  ;; the room buffer's locals are gone — the name must ride the
  ;; closure, or the ack reads "set the topic of nil".

  (let (ack-done)
    (let ((elneo--rooms (make-hash-table :test 'equal)))
      (puthash (cons "mxtest" "!room")
               (list :display-name "Testroom")
               elneo--rooms)
      (with-current-buffer (mx--room-buffer)
        (unwind-protect
            (cl-letf (((symbol-function 'elneo-server--call)
                       (lambda (_p cmd cb) (setq ack-done cb) '($req ok))))
              (elneo-room-set-topic "the new topic"))
          (kill-buffer)))
      ;; the ack lands with a plain buffer current (the process
      ;; filter's context, not any room buffer)
      (with-temp-buffer
        (let ((caught nil))
          (cl-letf (((symbol-function 'message)
                     (lambda (fmt &rest args) (push (apply #'format fmt args) caught))))
            (funcall ack-done "mxtest" '((@ok . t))))
        (mx-check "ack: the topic ack names the room captured at send time"
                  (car caught) "Matrix: set the topic of Testroom")))))

  ;; --- settings view: live refresh on the room's updateRoom

  (let ((room-buf (mx--room-buffer)))
    (unwind-protect
        (let ((v1 (list :profile "mxtest" :room-id "!room"
                        :display-name "Testroom" :name "Testroom"
                        :room-state "joined" :unread 0 :highlights 0
                        :topic "the old topic"))
              (v2 (list :profile "mxtest" :room-id "!room"
                        :display-name "Renamed" :name "Renamed"
                        :room-state "joined" :unread 0 :highlights 0
                        :topic "the new topic")))
          ;; the view, opened and rendered like `elneo-room-settings'
          ;; leaves it (render records the room on the output buffer)
          (let ((view (get-buffer-create "*Matrix Room: Testroom*")))
            (unwind-protect
                (progn
                  (with-current-buffer view
                    (cl-letf (((symbol-function 'elneo-room--buffer-for)
                               (lambda (_p _r) room-buf))
                              ((symbol-function 'elneo-server--user-id)
                               (lambda (_p) "@me:example.org")))
                      (let ((standard-output (current-buffer)))
                        (elneo-room-settings--render v1))))
                  (mx-check "refresh: the view records its room key"
                            (buffer-local-value
                             'elneo-room-settings--room view)
                            (cons "mxtest" "!room"))
                  ;; a live updateRoom re-renders it in place
                  (cl-letf (((symbol-function 'elneo-room--buffer-for)
                             (lambda (_p _r) room-buf))
                            ((symbol-function 'elneo-server--user-id)
                             (lambda (_p) "@me:example.org")))
                    (elneo-room--settings-refresh v2))
                  ;; the updateRoom event renamed the room, so the
                  ;; view renames into the fresh title
                  (mx-check "refresh: a renamed room re-titles the view"
                            (and (get-buffer "*Matrix Room: Renamed*") t) t)
                  (mx-check "refresh: the view shows the new topic"
                            (with-current-buffer
                                (get-buffer "*Matrix Room: Renamed*")
                              (and (string-search "the new topic"
                                                  (buffer-string))
                                   t))
                            t)
                  (mx-check "refresh: the view left the old topic"
                            (with-current-buffer
                                (get-buffer "*Matrix Room: Renamed*")
                              (string-search "the old topic"
                                             (buffer-string)))
                            nil))
              ;; cleanup: the view lives under either title now
              (when (buffer-live-p view) (kill-buffer view))
              (when-let* ((renamed (get-buffer "*Matrix Room: Renamed*")))
                (kill-buffer renamed)))))
      (kill-buffer room-buf)))

  ;; --- the removed room closes its settings view

  (let ((view (get-buffer-create "*Matrix Room: Goneroom*")))
    (with-current-buffer view
      (setq-local elneo-room-settings--room (cons "mxtest" "!gone"))
      (let ((standard-output (current-buffer))
            (inhibit-read-only t))
        (erase-buffer)
        (insert "stale")))
    (cl-letf (((symbol-function 'elneo-room--buffer-for) (lambda (_p _r) nil))
              ((symbol-function 'elneo-server--user-id) (lambda (_p) "@me:example.org")))
      (elneo-room--settings-refresh
       (list :profile "mxtest" :room-id "!gone" :removed t)))
    (mx-check "refresh: a removed room closes its settings view"
              (and (buffer-live-p view) t) nil))

  ;; --- profile reading: join and start-dm always ask

  (let ((elneo-accounts '(("p1") ("p2"))))
    (with-current-buffer (mx--room-buffer)
      (cl-letf (((symbol-function 'elneo--accounts-load) #'ignore)
                ((symbol-function 'completing-read)
                 (lambda (_p _coll _pred _req _hist _hist2 default) default)))
        (mx-check "read-profile-anywhere: the room's profile is the default"
                  (elneo-room--read-profile-anywhere)
                  "mxtest")))
    (cl-letf (((symbol-function 'elneo--accounts-load) #'ignore)
              ((symbol-function 'completing-read)
               (lambda (&rest _) "p2"))
              ((symbol-function 'derived-mode-p) (lambda (&rest _) nil)))
      (mx-check "read-profile-anywhere: outside a room buffer nothing assumed"
                (let ((elneo-room--profile nil) (elneo-room--room-id nil))
                  (elneo-room--read-profile-anywhere))
                "p2")))

  ;; elneo-start-dm: the id-only entry point delegates to start-dm
  (let ((got nil))
    (cl-letf (((symbol-function 'elneo-room-start-dm)
               (lambda (profile user-id) (setq got (cons profile user-id)))))
      (elneo-start-dm "p1" "@bob:example.org")
      (mx-check "start-dm: the id-only wrapper delegates" got '("p1" . "@bob:example.org"))))

  ;; --- the actions transient

  ;; Without the transient package the menu entry point degrades with
  ;; a message, exactly like the room bar's options menu.
  (let (caught)
    (cl-letf (((symbol-function 'require)
               (lambda (_feat &optional _f _n) nil))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) caught))))
      (elneo-room-actions))
    (mx-check "actions: without transient the menu says so"
              (and (member "Matrix: the actions menu needs the transient package"
                           caught)
                   t)
              t))
  ;; With transient present the entry point dispatches the prefix.
  (when (require 'transient nil t)
    (let (dispatched)
      (cl-letf (((symbol-function 'call-interactively)
                 (lambda (cmd &rest _) (setq dispatched cmd))))
        (elneo-room-actions)
        (mx-check "actions: the menu dispatches the room-actions prefix"
                  dispatched 'elneo-room-actions-dispatch))))

      ;; --- overview layout: the receipts move to the very end, the
      ;;     avatar shows the image once it is in the cache

      (mx-check "overview: a no-avatar room says (none)"
                (and (string-search "  Avatar:        (none)"
                                    (mx--overview
                                     '(:profile "mxtest" :room-id "!room"
                                      :display-name "Ops" :unread 0
                                      :highlights 0 :room-state "joined")))
                     t)
                t)
      (mx-check "overview: an uncached avatar prints the mxc, batch-safe"
                (and (string-search "Avatar:        mxc://hs/rav"
                                    (mx--overview
                                     '(:profile "mxtest" :room-id "!room"
                                      :display-name "Ops" :unread 0
                                      :highlights 0 :room-state "joined"
                                      :avatar "mxc://hs/rav")))
                     t)
                t)

      ;; The buttons: the mxc string (in any clickable mode) and the
      ;; image cell (graphic only) open the full-size avatar view
      ;; (`elneo-avatar-show'); anon mode keeps the mxc plain.
      (let ((shown nil))
        (cl-letf (((symbol-function 'elneo-avatar-show)
                   (lambda (profile mxc) (setq shown (cons profile mxc)))))
          (let ((text (mx--overview
                       '(:profile "mxtest" :room-id "!room"
                                  :display-name "Ops" :unread 0
                                  :highlights 0 :room-state "joined"
                                  :avatar "mxc://hs/rav"))))
            (with-temp-buffer
              (insert text)
              (goto-char (point-min))
              (re-search-forward "mxc://hs/rav")
              (funcall (plist-get (text-properties-at (match-beginning 0))
                                  'action)
                       nil))
            (mx-check "overview: the avatar mxc opens the full-size view"
                      shown '("mxtest" . "mxc://hs/rav"))))
        ;; Anon mode: the mxc string stays plain, without the button.
        (with-temp-buffer
          (let ((standard-output (current-buffer))
                (elneo-anon-mode t))
            (cl-letf (((symbol-function 'elneo-room--buffer-for)
                       (lambda (_p _r) 'no-buffer)))
              (elneo-room-settings--render
               (list :profile "mxtest" :room-id "!room"
                     :display-name "Ops" :unread 0 :highlights 0
                     :room-state "joined" :avatar "mxc://hs/rav"))))
          (mx-check "overview: anon mode keeps the mxc string plain"
                    (and (string-search "Avatar:        mxc://hs/rav"
                                        (buffer-string))
                         t)
                    t)
          (goto-char (point-min))
          (search-forward "mxc://hs/rav")
          (mx-check "overview: anon mode's avatar mxc is no button"
                    (plist-get (text-properties-at (match-beginning 0))
                               'action)
                    nil)))

      ;; The image cell only renders in a graphic display; the batch
      ;; run asserts the mxc keeps standing in there (covered above).
      ;; The cached-then-graphic render is asserted with the display,
      ;; the real create-image and the avatar cache stubbed: the image
      ;; cell goes into the buffer's text (princ drops the display
      ;; property) with the mxc standing beside it.
      (let* ((av-cache (make-hash-table :test 'equal))
             (room (lambda ()
                     (list :profile "mxtest" :room-id "!room"
                           :display-name "Ops" :unread 0 :highlights 0
                           :room-state "joined" :avatar "mxc://hs/rav"))))
        (puthash "mxc://hs/rav" "/cache/room-av.png" av-cache)
        (let ((create-called nil) (fetched nil) (shown nil))
          (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                    ((symbol-function 'default-font-height) (lambda () 17))
                    ((symbol-function 'default-font-width) (lambda () 8))
                    ((symbol-function 'create-image)
                     (lambda (_file _t _d &rest _) (setq create-called t) 'fake-img))
                    ((symbol-function 'elneo-client-fetch-avatar)
                     (lambda (_p _m cb) (setq fetched 'again)
                       (funcall cb "mxtest" '((@ok . t)))))
                    ((symbol-function 'elneo-avatar-show)
                     (lambda (profile mxc) (setq shown (cons profile mxc))))
                    ((symbol-function 'elneo-room--settings-refresh)
                     nil)
                    (elneo-client--avatar-cache av-cache)
                    (elneo-client--avatar-pending (make-hash-table :test 'equal)))
            (let ((text (mx--overview (funcall room))))
              (mx-check "overview: graphic+cached avatar renders the mxc beside it"
                        (and (string-search "mxc://hs/rav" text) t) t)
              (mx-check "overview: it rendered through create-image"
                        (eq create-called t) t)
              (mx-check "overview: the cell carries the display property"
                        (with-temp-buffer
                          (insert text)
                          (goto-char (search-backward "mxc://hs/rav"))
                          (backward-char 2)   ; start of the 2-col cell
                          (eq (get-text-property (point) 'display) 'fake-img))
                        t)
              ;; The cell is a button too: clicking it opens the
              ;; full-size avatar view with the room's profile+mxc.
              (with-temp-buffer
                (insert text)
                (goto-char (search-backward "mxc://hs/rav"))
                (backward-char 2)
                (funcall (plist-get (text-properties-at (point)) 'action) nil))
              (mx-check "overview: the image cell opens the full-size view"
                        shown '("mxtest" . "mxc://hs/rav"))
              (mx-check "overview: a cached avatar fetches nothing"
                        (eq fetched nil) t))
            ;; The uncached twin: the fetch fires and its arrival
            ;; re-renders this room's open overview.  `elneo-room-get'
            ;; finds the room through `elneo--rooms' at runtime; the
            ;; stub hands the same record back.
            (let ((refreshed nil))
              (cl-letf ((elneo-client--avatar-cache (make-hash-table :test 'equal))
                        ((symbol-function 'elneo-room-get)
                         (lambda (_p _r) (funcall room)))
                        ((symbol-function 'elneo-room--settings-refresh)
                         (lambda (fresh) (setq refreshed (plist-get fresh :room-id)))))
                (mx--overview (funcall room))
                (mx-check "overview: an uncached avatar fetches"
                          (eq fetched 'again) t)
                (mx-check "overview: the arrival re-renders the overview"
                          (equal refreshed "!room") t))))))
          ;; The completion order: the cache entry is written before
          ;; the joined callbacks run — an on-arrival re-render reads
          ;; the path, not a cache that still misses.  (The bar's
          ;; deferred re-render papers over the old order; the
          ;; overview's ran inside the callback and never found it.)
          (let ((seen nil)
                (cache (make-hash-table :test 'equal))
                (pending (make-hash-table :test 'equal)))
            (cl-letf (((symbol-function 'elneo-download-media)
                       (lambda (_p query _f cb)
                         (if (string-suffix-p "broken" (alist-get 'url query))
                             (funcall cb "mxtest" '((@ok . nil)))
                           (funcall cb "mxtest" '((@ok . t) (path . "/cache/av.png"))))))
                      (elneo-client--avatar-cache cache)
                      (elneo-client--avatar-pending pending))
              (elneo-client-fetch-avatar
               "mxtest" "mxc://hs/ordered"
               (lambda (_p _e) (setq seen (elneo-client--avatar-file "mxc://hs/ordered"))))
              (mx-check "overview: the arrival callbacks see the cached path"
                        seen "/cache/av.png")
              ;; Same order for a failed download: the mark is in the
              ;; cache (`elneo-client--avatar-file' nil) before the
              ;; callbacks re-render.
              (setq seen t)
              (elneo-client-fetch-avatar
               "mxtest" "mxc://hs/broken"
               (lambda (_p _e)
                 (setq seen (elneo-client--avatar-file "mxc://hs/broken"))))
              (mx-check "overview: the failed mark exists before callbacks"
                        seen nil)))

      (let ((room-buf (mx--room-buffer)))
        (with-current-buffer room-buf
          (setq-local elneo-room--seen (make-hash-table :test 'equal))
          (setq-local elneo-room--receipts
                      (let ((tbl (make-hash-table :test 'equal)))
                        (puthash "@bob:example.org"
                                 (list :user-id "@bob:example.org"
                                       :user-name "Bob" :event-id "$e1")
                                 tbl)
                        tbl)))
        ;; The receipt's event is outside `elneo-room--seen' (an old
        ;; arrival, a trimmed seen map): the line prints the event id
        ;; as-is and the read-at time as "?".
        (let ((text (mx--overview
                     '(:profile "mxtest" :room-id "!room"
                                :display-name "Ops" :unread 0
                                :highlights 0 :room-state "joined")
                     room-buf)))
          (mx-check "overview: the receipts render"
                    (and (string-search
                          "  Bob             up to $e1 (read at ?)" text) t) t)
          (mx-check "overview: receipts sit after Permissions"
                    (> (string-search "Read by:" text)
                       (string-search "Permissions:" text)) t)
          ;; "At the very end" in practice: nothing of the settings
          ;; kind below the receipts.
          (mx-check "overview: receipts come after the notifications row"
                    (> (string-search "Read by:" text)
                       (string-search "Notifications:" text)) t)))

  (message "%d ok, %d failed" pass fail)
  (when (> fail 0) (kill-emacs 1)))

;;; room-mgmt-test.el ends here