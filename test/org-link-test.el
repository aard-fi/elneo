;;; org-link-test.el --- elneo-org: links, follows, store-link, capture -*- lexical-binding: t; -*-

;; The `elneo-org' integration: the three link types' follow behavior
;; (arguments reach the room machinery; errors on dead daemons and
;; broken paths), `C-c l' storing from a room buffer (event under
;; point, the one-character-past case, plain room otherwise), person
;; links from the roster, and the real `org-capture' roundtrip.  The
;; follows are stubbed at the room machinery's commands
;; (`elneo-room--open', `elneo-room-jump-to-event', `elneo-start-dm').

;; Run: emacs -Q --batch -L lisp -l test/org-link-test.el

(require 'org)
(require 'org-capture)
(require 'elneo-org)
(require 'elneo-room)

(defun mx--room-buffer ()
  "A room buffer with a marked message line, a roster, a room record.
The message line carries the `elneo-room-event-id' text property the
way renders put it on (no synthetic quote id — that branch is the
media pipeline's).  The room record lands in a fresh buffer-local
`elneo--rooms' so the label lookup answers."
  (let ((buf (generate-new-buffer " *mx-org-room*"))
        (beg))
    (with-current-buffer buf
      (elneo-room-mode)
      (setq-local elneo-room--profile "mxtest")
      (setq-local elneo-room--room-id "!room:hs.example")
      (setq-local elneo-room--seen (make-hash-table :test 'equal))
      (setq-local elneo-room--members
                  (list (list :user-id "@bob:example.org" :name "Bob")
                        (list :user-id "@eve:example.org")
                        (list :user-id "@me:example.org" :name "Me")))
      (setq-local elneo--rooms (make-hash-table :test 'equal))
      (puthash (cons "mxtest" "!room:hs.example")
               (list :profile "mxtest" :room-id "!room:hs.example"
                     :display-name "Ops")
               elneo--rooms)
      (insert "\n\n")
      (setq beg (point))
      (insert "Alice: hello\nworld\n")
      ;; The id reaches through the line's trailing newline, the way
      ;; the one-past fallback reads it.
      (put-text-property beg (point)
                         'elneo-room-event-id "$alice1")
      ;; The seen record answers for snippet and sender.
      (puthash "$alice1" (list :sender "@alice:x" :sender-name "Alice"
                               :body "hello\nworld\nlast line" :ts 1)
               elneo-room--seen)
      buf)))

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  ;; --- the path split and its errors ---

  (mx-check "split: profile/rest at the first slash"
            (elneo-org--link-split "p/!r:hs" "room")
            '("p" "!r:hs"))

  (mx-check "split: only the FIRST slash splits"
            (elneo-org--link-split "p/!r:hs/$e1" "event")
            '("p" "!r:hs/$e1"))

  (mx-check "split: no slash errors"
            (condition-case err (elneo-org--link-split "noslash" "room")
              (user-error t) (error nil))
            t)

  (mx-check "split: bare leading slash errors"
            (condition-case err (elneo-org--link-split "/room" "room")
              (user-error t) (error nil))
            t)

  ;; --- follows ---

  ;; Room: the record lookup answers, the open takes the record.
  (mx-check "follow room: opens the looked-up record"
            (let ((opened nil))
              (cl-letf (((symbol-function 'elneo-server-live-p) (lambda (_p) t))
                        ((symbol-function 'elneo-room-get)
                         (lambda (_p _r) 'room-record))
                        ((symbol-function 'elneo-room--open)
                         (lambda (room &optional _stay) (setq opened room))))
                (elneo-org-follow-room "mxtest/!room:hs.example")
                opened))
            'room-record)

  (mx-check "follow room: no record errors with the sync words"
            (cl-letf (((symbol-function 'elneo-server-live-p) (lambda (_p) t))
                      ((symbol-function 'elneo-room-get) (lambda (_p _r) nil))
                      ((symbol-function 'elneo-room--open) #'ignore))
              (condition-case err
                  (elneo-org-follow-room "mxtest/!missing")
                (user-error (error-message-string err)) (error nil)))
            "Matrix: no room record for !missing — the room appears once the daemon syncs")

  (mx-check "follow room: dead daemon errors"
            (cl-letf (((symbol-function 'elneo-server-live-p) (lambda (_p) nil))
                      ((symbol-function 'elneo-room-get)
                       (lambda (_p _r) 'record)))
              (condition-case err (elneo-org-follow-room "mxtest/!room")
                (user-error t) (error nil)))
            t)

  ;; Event: profile, room id (up to the second slash) and the event
  ;; id verbatim — even when it itself carries slashes.
  (mx-check "follow event: arguments reach the jump"
            (let ((jumped nil))
              (cl-letf (((symbol-function 'elneo-room-jump-to-event)
                         (lambda (p r e &optional _stay) (setq jumped (list p r e)))))
                (elneo-org-follow-event "mxtest/!room:hs.example/$alice1")
                jumped))
            '("mxtest" "!room:hs.example" "$alice1"))

  (mx-check "follow event: slashes inside the event id stay"
            (let ((jumped nil))
              (cl-letf (((symbol-function 'elneo-room-jump-to-event)
                         (lambda (p r e &optional _stay) (setq jumped (list p r e)))))
                (elneo-org-follow-event "mxtest/!r/$a/b/c")
                jumped))
            '("mxtest" "!r" "$a/b/c"))

  (mx-check "follow event: missing event part errors"
            (condition-case err (elneo-org-follow-event "mxtest/!r")
              (user-error t) (error nil))
            t)

  ;; User: the DM start takes profile and id.
  (mx-check "follow user: starts the DM"
            (let ((started nil))
              (cl-letf (((symbol-function 'elneo-server-live-p) (lambda (_p) t))
                        ((symbol-function 'elneo-start-dm)
                         (lambda (p u) (setq started (list p u)))))
                (elneo-org-follow-user "mxtest/@bob:example.org")
                started))
            '("mxtest" "@bob:example.org"))

  (mx-check "follow user: dead daemon errors"
            (cl-letf (((symbol-function 'elneo-server-live-p) (lambda (_p) nil)))
              (condition-case err (elneo-org-follow-user "mxtest/@bob:x")
                (user-error t) (error nil)))
            t)

  ;; --- store-link from room buffers ---

  ;; Non-interactive `org-store-link' still fills `org-store-link-plist' —
  ;; the link and description come from there.
  (mx-check "store: on a message line the link names the event"
            (with-current-buffer (mx--room-buffer)
              (goto-char (point-min))
              (search-forward "hello")
              (org-store-link nil nil)
              (plist-get org-store-link-plist :link))
            "elneo-event:mxtest/!room:hs.example/$alice1")

  (mx-check "store: the event description is sender + snippet"
            (with-current-buffer (mx--room-buffer)
              (goto-char (point-min))
              (search-forward "hello")
              (org-store-link nil nil)
              (plist-get org-store-link-plist :description))
            "Alice: hello world last line")

  (mx-check "store: one past the line still counts as on the event"
            (with-current-buffer (mx--room-buffer)
              (goto-char (point-max))
              (org-store-link nil nil)
              (plist-get org-store-link-plist :link))
            "elneo-event:mxtest/!room:hs.example/$alice1")

  (mx-check "store: elsewhere in the room, the room link"
            (with-current-buffer (mx--room-buffer)
              (goto-char (point-min))
              (org-store-link nil nil)
              (plist-get org-store-link-plist :link))
            "elneo-room:mxtest/!room:hs.example")

  (mx-check "store: the room description is the display name"
            (with-current-buffer (mx--room-buffer)
              (goto-char (point-min))
              (org-store-link nil nil)
              (plist-get org-store-link-plist :description))
            "Ops")

  ;; Outside room buffers the store function declines (nil) — the
  ;; real `org-store-link' then reports nothing to store.
  (mx-check "store: outside rooms the store function declines"
            (with-temp-buffer (elneo-org-store-link))
            nil)

  (mx-check "store: real org-store-link reports nothing from elsewhere"
            (condition-case err (with-temp-buffer (org-store-link nil t))
              (error (error-message-string err)))
            "No method for storing a link from this buffer")

  ;; --- person links ---

  (mx-check "store user: the roster pick becomes an elneo-user link"
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_p _c &rest _)
                         "Bob (@bob:example.org)")))
              (with-current-buffer (mx--room-buffer)
                (elneo-org-store-user-link)
                (list (plist-get org-store-link-plist :type)
                      (plist-get org-store-link-plist :link)
                      (plist-get org-store-link-plist :description))))
            '("elneo-user" "elneo-user:mxtest/@bob:example.org"
              "@bob:example.org"))

  (mx-check "store user: a name-less roster entry still parses"
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_p _c &rest _)
                         "@eve:example.org (@eve:example.org)")))
              (with-current-buffer (mx--room-buffer)
                (elneo-org-store-user-link)
                (plist-get org-store-link-plist :link)))
            "elneo-user:mxtest/@eve:example.org")

  ;; Outside rooms the profile is picked from the registered accounts;
  ;; `elneo-accounts-loaded' is let true so the load never touches the
  ;; real accounts file.
  ;; Outside rooms the profile is picked from the registered accounts;
  ;; `elneo-accounts-loaded' is let true so the load never touches the
  ;; real accounts file.
  (let (link)
    (let ((elneo-accounts '(("mxtest" . (:homeserver "x"))))
          (elneo-accounts-loaded t))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_p _c &rest _) "mxtest"))
                ((symbol-function 'read-string)
                 (lambda (_p &optional _i _h _d) "@zed:example.org")))
        (with-temp-buffer
          (elneo-org-store-user-link)
          (setq link (plist-get org-store-link-plist :link)))))
    (mx-check "store user: outside rooms the profile is picked"
              link
              "elneo-user:mxtest/@zed:example.org"))

  ;; --- the completion functions ---

  ;; org's :complete contract: the return IS the link string.
  (mx-check "complete room: returns the plain full link"
            (cl-letf (((symbol-function 'elneo-completing-read-room)
                       (lambda () '(:profile "mxtest" :room-id "!r:hs"))))
              (with-current-buffer (mx--room-buffer)
                (elneo-org-complete-room)))
            "elneo-room:mxtest/!r:hs")

  (mx-check "complete user (rooms): returns the plain full link"
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_p _c &rest _) "Me (@me:example.org)")))
              (with-current-buffer (mx--room-buffer)
                (elneo-org-complete-user)))
            "elneo-user:mxtest/@me:example.org")

  ;; The :insert-description hooks shape what org proposes as label.
  (mx-check "insert-description room: the display name"
            (cl-letf (((symbol-function 'elneo-room-get)
                       (lambda (_p _r) (list :display-name "Ops"))))
              (elneo-org-insert-description-room
               "elneo-room:mxtest/!room:hs.example"))
            "Ops")

  (mx-check "insert-description user: the id itself"
            (elneo-org-insert-description-user
             "elneo-user:mxtest/@bob:example.org")
            "@bob:example.org")

  ;; --- the whole flow: real org-capture, inside the room buffer ---

  ;; Batch quirk (previously learned): `org-capture' builds its CAPTURE
  ;; buffer but never switches to it — finalize must be called with
  ;; that buffer current, read off the capture plist.
  (let ((target (make-temp-file "mx-org-capture-target")))
    (let ((org-capture-templates
           (list (list "k" "Link note" 'plain
                       (list 'file target)
                       "%a\n"))))
      (with-current-buffer (mx--room-buffer)
        (goto-char (point-min))
        (search-forward "hello")
        (org-capture nil "k"))
      ;; Batch quirk: `org-capture' builds its CAPTURE buffer but never
      ;; switches to it — finalize must be called with that buffer
      ;; current; the plist's :buffer is the target, not CAPTURE-.
      (with-current-buffer (or (get-buffer
                                (concat "CAPTURE-"
                                        (file-name-nondirectory target)))
                               (current-buffer))
        (org-capture-finalize))
      (mx-check
       "capture: the stored event link lands in the target"
       (with-temp-buffer
         (insert-file-contents target)
         (string-trim (buffer-string)))
       "[[elneo-event:mxtest/!room:hs.example/$alice1][Alice: hello world last line]]")))

  ;; --- registration happened at file load ---

  (mx-check "registration: the three types are known"
            (let ((types (org-link-types)))
              (list (and (member "elneo-room" types) t)
                    (and (member "elneo-event" types) t)
                    (and (member "elneo-user" types) t)))
            '(t t t))

  (mx-check "registration: follows bound on each type"
            (list (functionp (org-link-get-parameter "elneo-room" :follow))
                  (functionp (org-link-get-parameter "elneo-event" :follow))
                  (functionp (org-link-get-parameter "elneo-user" :follow)))
            '(t t t))

  ;; Store support rides the `elneo-room' parameter — org 9.7 calls
  ;; parameters, not the hook variable.
  (mx-check "registration: store rides the elneo-room parameter"
            (org-link-get-parameter "elneo-room" :store)
            #'elneo-org-store-link)

  (message "%d ok, %d failed" pass fail)
  (when (> fail 0) (kill-emacs 1)))

;;; org-link-test.el ends here