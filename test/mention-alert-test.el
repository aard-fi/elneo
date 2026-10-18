;;; mention-alert-test.el --- m.mentions plumbing and alert gating -*- lexical-binding: t; -*-

;; The protocol-4 `mentions' field rides the MessageEntry wire into the
;; message plists (`elneo-client--mentions-plist', history and live
;; paths); `elneo-server--user-id' reads the logged-in session; the
;; alert filter lets an explicit mention or @room punch through a
;; muted room while everything else keeps its old behavior.  All
;; batch, no real processes: `alert' is stood up as a stub feature so
;; elneo-alert loads without the package.
;;
;; Run: emacs -Q --batch -L lisp -l test/mention-alert-test.el

(require 'elneo-client)

;; `elneo-alert' (require)s alert.el, which batch -Q does not have on
;; its load path.  The gating code under test never calls `alert', a
;; bare feature stands in.
(unless (featurep 'alert) (provide 'alert))

(require 'elneo-alert)

(require 'elneo-room)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  ;; --- wire→plist conversion ---

  (mx-check "no mentions block → nil"
            (elneo-client--mentions-plist nil) nil)

  (let ((got (elneo-client--mentions-plist
              '((user_ids . ["@a:hs" "@b:hs"]) (room . t)))))
    (mx-check "ids + @room convert"
              got '(:user-ids ("@a:hs" "@b:hs") :room t)))

  (let ((got (elneo-client--mentions-plist '((user_ids . ["@a:hs"])))))
    (mx-check "ids only: room flag defaults nil"
              got '(:user-ids ("@a:hs") :room nil))
    ;; The ids stay a list, not the vector json-read produced.
    (mx-check "ids are a list (member-compatible)"
              (listp (plist-get got :user-ids)) t))

  ;; --- own user id, from the session record ---

  (let ((elneo-server--sessions
         '(("main" . (:user-id "@me:hs" :device-id "DEV"
                               :access-token "tok")))))
    (mx-check "user-id reads the session record"
              (elneo-server--user-id "main") "@me:hs")
    (mx-check "unknown profile has no session"
              (elneo-server--user-id "ghost") nil))

  ;; --- alert text labels ---

  (mx-check "sticker with alt text keeps its body"
            (elneo-alert--message-text
             '(:sender-name "Bee" :msgtype "m.sticker" :body "happy cat"))
            "Bee: happy cat")
  (mx-check "body-less sticker gets the label"
            (elneo-alert--message-text
             '(:sender-name "Bee" :msgtype "m.sticker" :body ""))
            "Bee sent a sticker")

  ;; --- the gating predicate ---

  ;; elneo-room is not loaded here, so the buffer lookup is stubbed
  ;; away for every gating check; visibility stays "not visible"
  ;; except where a test says otherwise.
  (cl-letf (((symbol-function 'elneo-room--buffer-for)
             (lambda (_p _r) nil))
            ((symbol-function 'elneo-buffer-visible-p)
             (lambda (_b) nil))
            ((symbol-function 'elneo-alert--bar-visible-p)
             (lambda () nil)))

    (let ((elneo-server--sessions
           '(("main" . (:user-id "@me:hs"))))
          (elneo-room-muted-notification-modes '("mute"))
          (elneo-alert-enable t)
          (elneo-alert-skip-when nil))
    (let ((muted '(:notification-mode "mute"))
          (loud '(:notification-mode "all_messages")))

      (mx-check "muted room, plain message → quiet"
                (elneo-alert--should-alert-p
                 (list :profile "main" :is-own nil) muted) nil)

      (mx-check "muted room, @room → alert"
                (elneo-alert--should-alert-p
                 (list :profile "main" :is-own nil
                       :mentions '(:room t :user-ids nil))
                 muted) t)

      (mx-check "muted room, mention of me → alert"
                (elneo-alert--should-alert-p
                 (list :profile "main" :is-own nil
                       :mentions '(:room nil :user-ids ("@other:hs" "@me:hs")))
                 muted) t)

      (mx-check "muted room, mention of someone else → quiet"
                (elneo-alert--should-alert-p
                 (list :profile "main" :is-own nil
                       :mentions '(:room nil :user-ids ("@other:hs")))
                 muted) nil)

      (mx-check "own message, even @room → never alerts"
                (elneo-alert--should-alert-p
                 (list :profile "main" :is-own t :mentions '(:room t))
                 muted) nil)

      (mx-check "loud room without a block still alerts"
                (elneo-alert--should-alert-p
                 (list :profile "main" :is-own nil) loud) t)

      ;; mention checks against a profile with no session (nil user id)
      ;; never match a real id: mentions of nobody in particular.
      (mx-check "session-less profile does not alert on others' ids"
                (elneo-alert--should-alert-p
                 (list :profile "ghost" :is-own nil
                       :mentions '(:room nil :user-ids ("@me:hs")))
                 muted) nil))))

  ;; --- mention logic without a full should-alert call ---

  (let ((elneo-server--sessions
         '(("main" . (:user-id "@me:hs")))))
    (mx-check "mentions-me: @room alone wins"
              (elneo-alert--mentions-me-p '(:mentions (:room t :user-ids nil))) t)
    (mx-check "mentions-me: id match"
              (not (null
                    (elneo-alert--mentions-me-p
                     '(:profile "main" :mentions (:room nil :user-ids ("@me:hs"))))))
              t)
    (mx-check "mentions-me: no block → nil"
              (elneo-alert--mentions-me-p '(:profile "main")) nil))

  ;; --- skip-when still applies to mentions ---

  ;; A mention in a buffer already on screen is readable where it
  ;; stands; the visibility skip does not become a second bell.
  (let ((elneo-alert-skip-when 'buffer-or-bar)
        (elneo-server--sessions '(("main" . (:user-id "@me:hs")))))
    (cl-letf (((symbol-function 'elneo-room--buffer-for)
               (lambda (_p _r) (get-buffer-create " *mx-mention-skip*")))
              ((symbol-function 'elneo-buffer-visible-p)
               (lambda (_b) t))
              ((symbol-function 'elneo-alert--bar-visible-p)
               (lambda () nil)))
      (mx-check "visible buffer stays quiet even for a mention"
                (elneo-alert--should-alert-p
                 (list :profile "main" :is-own nil :mentions '(:room t))
                 '(:notification-mode "all_messages"))
                nil)))

  ;; --- member system lines (protocol 4) ---

  ;; The daemon's m.member entries render as one subdued line: the
  ;; sentence is the body, no sender column, no media/reply machinery.
  (let ((buf (generate-new-buffer " *mx-member-room*")))
    (with-current-buffer buf
      (elneo-room-mode)
      (let ((elneo-room-avatars nil)
            (elneo-room--profile "mxtest"))
        (setq elneo-room--seen (make-hash-table :test 'equal))
        (insert "header\n")
        (goto-char (point-max))
        (elneo-room--append-messages
         (copy-tree
          `((:event-id "$j1" :sender "@alice:hs" :sender-name "Alice" :ts 1700000000000
             :msgtype "m.member" :is-own nil :body "Alice joined the room")
            (:event-id "$j2" :sender "@me:hs" :sender-name "Me" :ts 1700000060000
             :msgtype "m.member" :is-own t :body "You joined the room")))))
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-min))
            (let* ((body-beg (search-forward "Alice joined the room"))
                   (line-beg (line-beginning-position))
                   head)
              (mx-check "join line rendered" (and body-beg t) t)
              ;; System line = clock stamp + one space, then the
              ;; sentence: no padded sender column.
              (setq head (buffer-substring line-beg (- body-beg
                                                       (length "Alice joined the room"))))
              (mx-check "line starts with a clock stamp, no sender column"
                        (string-match "\\`[0-9][0-9]:[0-9][0-9] $" head) 0)
              (mx-check "system line is dimmed"
                        (get-text-property (- body-beg 1) 'face) 'shadow)
              (mx-check "msg-block marker carries the event id"
                        (get-text-property line-beg 'elneo-room-msg-block) "$j1"))
            (goto-char (point-min))
            (mx-check "own join rendered"
                      (and (search-forward "You joined the room" nil t) t) t))
        (kill-buffer buf))))

    ;; A m.member line never alerts (checked above by the should-alert
    ;; path); also verify the hook consumer's guard directly.
    (let ((alerts nil)
          (elneo-alert-enable t)
          (elneo-alert-skip-when nil))
      (cl-letf (((symbol-function 'elneo-alert--event-fresh-p) (lambda (_) t))
                ((symbol-function 'elneo-room-get) (lambda (_p _r) nil))
                ((symbol-function 'elneo-alert--should-alert-p)
                 (lambda (&rest _) (push :predicate alerts) t))
                ((symbol-function 'elneo-alert-notify)
                 (lambda (&rest _) (push :notified alerts))))
        (elneo-alert--on-new-message
         (list :msgtype "m.member" :event-id "$e" :profile "p" :room-id "!r:hs"))
        (mx-check "member line: alert pipeline never reached" alerts nil)
        (setq alerts nil)
        (elneo-alert--on-new-message
         (list :msgtype "m.text" :event-id "$e" :profile "p" :room-id "!r:hs"))
        (mx-check "text message: pipeline still reached"
                  (and (member :predicate alerts)
                       (member :notified alerts)
                       t)
                  t))

  (message "results: %d passed, %d failed" pass fail)
  (when (> fail 0) (kill-emacs 1))))