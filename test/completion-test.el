;;; completion-test.el --- @-mention completion and mention sends -*- lexical-binding: t; -*-

;; Mentions: the roster cache fills from the `updateRoomMembers'
;; wire (own user filtered out of the candidates), the `@'-fragment
;; before point is read and replaced by the picked display name (a
;; typed raw user id stays), the draft's mention list dedups and
;; self-retracts — the send filters entries whose display text no
;; longer occurs in the body and tags `sendMessage' with the rest,
;; on this send and on the retry of a failed one.  The daemon is
;; stubbed at `elneo-room-members' and `elneo-send-message'.
;;
;; Run: emacs -Q --batch -L lisp -l test/completion-test.el

(require 'elneo-room)

;; Sends must not leak into this test process's real draft state.
(setq elneo-room-drafts-file (make-temp-file "mx-completion-drafts"))

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defvar mx-req 0)
  (defvar mx-sent nil)
  (defun mx-send-stub (_profile _room body callback
                                &optional formatted reply-to replaces
                                mentions room-mention thread-root)
    "Stub `elneo-send-message': record the call, return a fresh req.
THREAD-ROOT (the MSC3440 relation this suite never sends) rides
after ROOM-MENTION and is ignored."
    (push (list body callback formatted reply-to replaces mentions
                room-mention thread-root)
          mx-sent)
    (cl-incf mx-req)
    mx-req)

  (defun mx-own-stub (fun)
    "Run FUN with the logged-in user stubbed to @me:hs."
    (cl-letf (((symbol-function 'elneo-server--user-id)
               (lambda (_profile) "@me:hs")))
      (funcall fun)))

  (defun mx-room-setup ()
    "A backfilled room buffer with a draft area and a canned roster."
    (let ((buf (generate-new-buffer " *mx-completion-room*")))
      (with-current-buffer buf
        (elneo-room-mode)
        (setq elneo-room--profile "mxtest"
              elneo-room--room-id "!room"
              elneo-room--seen (make-hash-table :test 'equal)
              elneo-room--backfilled t
              ;; Draft persistence: diff against an empty store.
              elneo-room--draft-saved-text nil
              elneo-room--draft-mentions nil)
        (insert "header\n")
        (elneo-room--reset-input-area "")
        (setq elneo-room--members
              '((:user-id "@a:hs" :name "Alice")
                (:user-id "@b:hs" :name nil)
                (:user-id "@me:hs" :name "Me")))
        (puthash (cons "mxtest" "!room") buf elneo-room--buffers)
        buf)))

  ;; --- roster from the wire ---

  (let ((buf (mx-room-setup)))
    (unwind-protect
        (with-current-buffer buf
          (setq elneo-room--members nil)
          (cl-letf (((symbol-function 'elneo-room-members)
                     (lambda (_profile _room callback)
                       (funcall callback "mxtest"
                                `((@ok . t) (@req . 1) (room_id . "!room")
                                  (members
                                   . [((user_id . "@a:hs")
                                       (display_name . "Alice"))
                                      ((user_id . "@c:hs"))]))))))
            (elneo-room--fetch-members)
            (mx-check "roster fills from the wire"
                      elneo-room--members
                      '((:user-id "@a:hs" :name "Alice")
                        (:user-id "@c:hs" :name nil)))))
      (kill-buffer buf)))

  ;; --- candidates: labels, own user, display texts ---

  (let ((buf (mx-room-setup)))
    (unwind-protect
        (with-current-buffer buf
          (let ((cands (mx-own-stub
                        (lambda () (elneo-room--mention-candidates)))))
            (mx-check "candidates: @room leads, labels in roster order"
                      (mapcar #'car cands)
                      '("@room (everyone)" "Alice (@a:hs)" "@b:hs"))
            (mx-check "candidates: id and display text"
                      (list (cadr (cadr cands)) (cddr (cadr cands)))
                      '("@a:hs" "Alice"))
            (mx-check "candidates: nameless entry stays id-shaped"
                      (list (cadr (caddr cands)) (cddr (caddr cands)))
                      '("@b:hs" "@b:hs"))
            (mx-check "candidates: own user left out"
                      (cl-member "@me:hs" cands :test #'equal :key #'cadr)
                      nil)))
      (kill-buffer buf)))

  ;; --- fragment extraction ---

  (let ((buf (mx-room-setup)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "hi @Al")
          (let ((at-max nil) (frag nil))
            (setq at-max (point)
                  frag (elneo-room--mention-fragment))
            (mx-check "fragment: word chars after an @"
                      (and frag (list (car frag) (cdr frag)))
                      (list (- at-max 3) "Al")))
          (goto-char (point-max))
          (insert "!")
          (mx-check "fragment: a closing non-word char ends it"
                    (progn (elneo-room--mention-fragment) nil) nil)
          (goto-char (point-max))
          (insert " @")
          (let ((frag (elneo-room--mention-fragment)))
            (mx-check "fragment: fresh @ is an empty fragment"
                      (and frag (equal (cdr frag) "")
                           (equal (char-after (car frag)) ?@))
                      t))
          (delete-region (car (elneo-room--mention-fragment)) (point-max))
          (insert "x")
          (goto-char (point-max))
          (mx-check "fragment: no @ behind point -> nil"
                    (elneo-room--mention-fragment) nil)
          (goto-char (point-min))
          (mx-check "fragment: history area -> nil"
                    (elneo-room--mention-fragment) nil))
      (kill-buffer buf)))

  ;; --- completion: roster pick, nameless, dedup, free text ---

  (let ((buf (mx-room-setup)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "hi @Al")
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_p _c &rest _) "Alice (@a:hs)")))
            (elneo-room--complete-mention))
          (mx-check "pick replaces the fragment with the display name"
                    (elneo-room--draft-text) "hi Alice")
          (mx-check "pick notes the mention"
                    elneo-room--draft-mentions '(("Alice" . "@a:hs")))
          (insert " @b")
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_p _c &rest _) "@b:hs")))
            (elneo-room--complete-mention))
          (mx-check "nameless member completes to the user id"
                    (string-suffix-p "@b:hs" (elneo-room--draft-text)) t)
          (mx-check "the user id itself is noted"
                    (car (cl-remove-if-not
                          (lambda (p) (equal (cdr p) "@b:hs"))
                          elneo-room--draft-mentions))
                    '("@b:hs" . "@b:hs"))
          ;; Dedup by user id: picking @a:hs again adds nothing.
          (goto-char (point-max))
          (insert " @A")
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_p _c &rest _) "Alice (@a:hs)")))
            (elneo-room--complete-mention))
          (mx-check "pick dedups by user id"
                    (length elneo-room--draft-mentions) 2)
          ;; Not a roster label, not an id-shaped raw entry: no-op.
          (goto-char (point-max))
          (insert " @zzz")
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_p _c &rest _) "Bob")))
            (elneo-room--complete-mention))
          (mx-check "free text without id shape inserts nothing"
                    (string-suffix-p "zzz" (elneo-room--draft-text)) t)
          (mx-check "free text adds no mention"
                    (length elneo-room--draft-mentions) 2))
      (kill-buffer buf)))

  ;; --- the @ room mention: plain token, no user id ---

  (let ((buf (mx-room-setup)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "hi @ro")
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_p _c &rest _) "@room (everyone)")))
            (elneo-room--complete-mention))
          (mx-check "@room pick inserts the plain token"
                    (string-suffix-p "hi @room" (elneo-room--draft-text)) t)
          (mx-check "@room pick notes no user id"
                    elneo-room--draft-mentions nil)
          ;; The send turns the token into the everyone-flag.
          (setq mx-req 0 mx-sent nil)
          (cl-letf (((symbol-function 'elneo-send-message) #'mx-send-stub))
            (elneo-room--input-send))
          (mx-check "room send: body carries the token"
                    (nth 0 (car mx-sent)) "hi @room")
          (mx-check "room send: no id list" (nth 5 (car mx-sent)) nil)
          (mx-check "room send: everyone-flag rides along"
                    (nth 6 (car mx-sent)) t))
      (kill-buffer buf)))

  ;; --- an aborted picker is quiet: no minibuffer-quit escape, no edit ---

  (let ((buf (mx-room-setup)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "hi @Al")
          (dolist (abort '(minibuffer-quit quit))
            (let ((escaped nil))
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (&rest _)
                           (signal abort nil))))
                ;; Must not signal — it would land in post-command-hook.
                (condition-case nil
                    (elneo-room--complete-mention)
                  (t (setq escaped t))))
              (mx-check (format "abort with %s raises nothing" abort)
                        escaped nil)))
          (mx-check "aborted pick leaves the fragment untouched"
                    (elneo-room--draft-text) "hi @Al")
          (mx-check "aborted pick notes nothing"
                    elneo-room--draft-mentions nil))
      (kill-buffer buf)))

  ;; --- send-time filtering ---

  (mx-check "send-mentions: text in body"
            (let ((buf (mx-room-setup)))
              (unwind-protect
                  (with-current-buffer buf
                    (setq elneo-room--draft-mentions
                          '(("Alice" . "@a:hs") ("@Bob" . "@b:hs")))
                    (elneo-room--send-mentions "Alice hi"))
                (kill-buffer buf)))
            '(:ids ("@a:hs") :room nil :pairs (("Alice" . "@a:hs"))))

  (mx-check "send-mentions: edited-away text retracts itself"
            (let ((buf (mx-room-setup)))
              (unwind-protect
                  (with-current-buffer buf
                    (setq elneo-room--draft-mentions '(("Alice" . "@a:hs")))
                    (elneo-room--send-mentions "hi"))
                (kill-buffer buf)))
            '(:ids nil :room nil :pairs nil))

  (mx-check "send-mentions: no bookkeeping, no block"
            (let ((buf (mx-room-setup)))
              (unwind-protect
                  (with-current-buffer buf
                    (elneo-room--send-mentions "Alice hi"))
                (kill-buffer buf)))
            '(:ids nil :room nil :pairs nil))

  (mx-check "send-mentions: a standalone @room sets the flag"
            (let ((buf (mx-room-setup)))
              (unwind-protect
                  (with-current-buffer buf
                    (elneo-room--send-mentions "hi @room!"))
                (kill-buffer buf)))
            '(:ids nil :room t :pairs nil))

  (mx-check "send-mentions: x@room and @rooms stay unmentioned"
            (let ((buf (mx-room-setup)))
              (unwind-protect
                  (with-current-buffer buf
                    (elneo-room--send-mentions "x@room and @rooms"))
                (kill-buffer buf)))
            '(:ids nil :room nil :pairs nil))

  (mx-check "send-mentions: @room and ids together"
            (let ((buf (mx-room-setup)))
              (unwind-protect
                  (with-current-buffer buf
                    (setq elneo-room--draft-mentions '(("Alice" . "@a:hs")))
                    (elneo-room--send-mentions "@room Alice"))
                (kill-buffer buf)))
            '(:ids ("@a:hs") :room t :pairs (("Alice" . "@a:hs"))))

  ;; --- the pills: surviving display texts render as matrix.to anchors ---

  (mx-check "pill: display text becomes a matrix.to anchor"
            (elneo-room--mention-pill-html
             "hi Alice!" '(("Alice" . "@a:hs")) nil)
            "hi <a href=\"https://matrix.to/#/@a:hs\">Alice</a>!")

  (mx-check "pill: an escaped name anchors on its escaped form"
            (elneo-room--mention-pill-html
             "hi A&amp;B!" '(("A&B" . "@b:hs")) nil)
            "hi <a href=\"https://matrix.to/#/@b:hs\">A&amp;B</a>!")

  (mx-check "pill: adjacent mentions keep their boundary characters"
            (elneo-room--mention-pill-html
             "Bob,Cathy" '(("Bob" . "@b:hs") ("Cathy" . "@c:hs")) nil)
            "<a href=\"https://matrix.to/#/@b:hs\">Bob</a>,\
<a href=\"https://matrix.to/#/@c:hs\">Cathy</a>")

  (mx-check "pill: prefix of a longer name pillifies the longer one whole"
            (elneo-room--mention-pill-html
             "Bob Bobby" '(("Bob" . "@b:hs") ("Bobby" . "@o:hs")) nil)
            "<a href=\"https://matrix.to/#/@b:hs\">Bob</a> \
<a href=\"https://matrix.to/#/@o:hs\">Bobby</a>")

  (mx-check "pill: a name inside a word stays plain"
            (elneo-room--mention-pill-html
             "Bobby waves" '(("Bob" . "@b:hs")) nil)
            "Bobby waves")

  (mx-check "pill: the standalone @room token pills on the room flag"
            (elneo-room--mention-pill-html
             "tell @room now" '(("Bob" . "@b:hs")) t)
            "tell <a href=\"https://matrix.to/#/@room\">@room</a> now")

  (mx-check "pill: x@room and @rooms never pill"
            (elneo-room--mention-pill-html
             "x@room and @rooms" nil nil) ; the room flag would be nil too
            "x@room and @rooms")

  (mx-check "pill: code regions stay literal"
            (elneo-room--mention-pill-html
             "<pre><code>Alice</code></pre> and Alice <code>Bob</code>"
             '(("Alice" . "@a:hs") ("Bob" . "@b:hs")) nil)
            "<pre><code>Alice</code></pre> and \
<a href=\"https://matrix.to/#/@a:hs\">Alice</a> <code>Bob</code>")

  (mx-check "pill: names inside markup runs anchor inside them"
            (elneo-room--mention-pill-html
             "<strong>Alice</strong>" '(("Alice" . "@a:hs")) nil)
            "<strong><a href=\"https://matrix.to/#/@a:hs\">Alice</a></strong>")

  (mx-check "pill: without pairs and no room flag, the html rides on"
            (elneo-room--mention-pill-html "plain" nil nil)
            "plain")

  ;; --- the send: mentions ride `elneo-send-message' ---

  (let ((buf (mx-room-setup)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "hi @Al")
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_p _c &rest _) "Alice (@a:hs)")))
            (elneo-room--complete-mention))
          (setq mx-req 0 mx-sent nil)
          (cl-letf (((symbol-function 'elneo-send-message) #'mx-send-stub))
            (elneo-room--input-send))
          (mx-check "send: draft carried the mention text"
                    (nth 0 (car mx-sent)) "hi Alice")
          (mx-check "send: the mention id rides along"
                    (nth 5 (car mx-sent)) '("@a:hs"))
          (mx-check "send: no room flag" (nth 6 (car mx-sent)) nil)
          (mx-check "send: draft cleared"
                    (string-trim (elneo-room--draft-text)) ""))
      (kill-buffer buf)))

  ;; --- a failed send keeps the draft and the mention; retry mentions ---

  (let ((buf (mx-room-setup)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-max))
          (insert "hi @Al")
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_p _c &rest _) "Alice (@a:hs)")))
            (elneo-room--complete-mention))
          (cl-letf (((symbol-function 'elneo-send-message)
                     (lambda (&rest _) (error "daemon dead"))))
            (condition-case nil
                (elneo-room--input-send)
              (error t)))
          (mx-check "failed send: draft intact"
                    (elneo-room--draft-text) "hi Alice")
          (mx-check "failed send: mention note intact"
                    elneo-room--draft-mentions '(("Alice" . "@a:hs")))
          ;; The retry (same RET again) carries the mention out.
          (setq mx-req 0 mx-sent nil)
          (cl-letf (((symbol-function 'elneo-send-message) #'mx-send-stub))
            (elneo-room--input-send))
          (mx-check "retry after failed send still mentions"
                    (cons (nth 0 (car mx-sent)) (nth 5 (car mx-sent)))
                    '("hi Alice" "@a:hs")))
      (kill-buffer buf)))

  ;; --- triggers: TAB in history is inert; a typed @ fires ---

  (let ((buf (mx-room-setup))
        (mx-called nil))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _) (setq mx-called t) "Alice (@a:hs)")))
            (goto-char (point-min))
            (elneo-room--complete-mention)
            (mx-check "TAB in the history area does not open the picker"
                      mx-called nil)
            (setq mx-called nil)
            (goto-char (point-max))
            ;; A typed @ (this-command still self-insert), via the
            ;; post-command hook the way interactive use runs it.
            (let ((this-command 'self-insert-command))
              (insert "@")
              (elneo-room--post-command))
            (mx-check "a typed @ opens the picker" mx-called t)
            (mx-check "...and its pick landed in the draft"
                      (elneo-room--draft-text) "Alice")
            ;; The config-off path: no trigger, no call, draft untouched.
            (setq mx-called nil elneo-room--draft-mentions nil)
            (delete-region (elneo-room--input-beg-pos) (point-max))
            (insert " @")
            (let ((elneo-room-mention-auto-complete nil))
              (let ((this-command 'self-insert-command))
                (elneo-room--post-command)))
            (mx-check "config off: no trigger, draft keeps the @"
                      (list mx-called
                            (string-suffix-p "@" (elneo-room--draft-text)))
                      '(nil t)))
      (kill-buffer buf))))

  (message "results: %d passed, %d failed" pass fail)
  (kill-emacs (if (zerop fail) 0 1)))