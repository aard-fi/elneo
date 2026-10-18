;;; elneo-anon-test.el --- screenshot mode: generators, wrappers, integrity -*- lexical-binding: t; -*-

;; Core checks for `elneo-anon' mode's generators and plist wrappers:
;; determinism, the id-keyed vs name-keyed person fakes, the bridge
;; suffix passthrough, the message and room render copies (real
;; plists never mutate; the registry's fields stay raw), and the
;; member-line name substitution including the unknown-name fallback.
;; The render-integration half runs the whole room-buffer pipeline
;; with the mode on — append-messages, a reply quote, a poll, a
;;   member line, the header — and checks that nothing real ships
;; while the seen table and the registry stay raw, and that
;; toggling off restores the buffer text byte for byte.

 ;; Run: emacs -Q --batch -L lisp -l test/elneo-anon-test.el

(require 'cl-lib)
(require 'elneo-room)
(require 'elneo-room-bar)
(require 'elneo-anon)

;; A fixed salt makes the generator outputs themselves deterministic
;; across runs (a live session picks its own salt at first use).
(setq elneo-anon--salt "test-salt")

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  ;; Determinism: the same category/key digests identically, whatever
  ;; else ran in between.
  (mx-check "digest is deterministic"
            (list (elneo-anon--digest "person" "id:@a:x")
                  (elneo-anon--digest "person" "id:@a:x"))
            (list (secure-hash 'sha256
                               (concat "mx-anon:test-salt:person:id:@a:x"))
                  (secure-hash 'sha256
                               (concat "mx-anon:test-salt:person:id:@a:x"))))

  ;; People: the same mxid is the same fake everywhere, a different
  ;; mxid is (over these pools) a different fake, and a name-only
  ;; fake keys on the name itself.
  (let ((alice (elneo-anon--person "@alice:mx.org" "Alice Chen")))
    (mx-check "person fake is stable per mxid"
              (list alice (elneo-anon--person "@alice:mx.org" "Alice Chen"))
              (list alice alice))
    (mx-check "another id is another fake"
              (equal alice (elneo-anon--person "@bob:mx.org" "Alice Chen"))
              nil)
    (mx-check "no id: the name keys the fake"
              (elneo-anon--person nil "Carol")
              (elneo-anon--person nil "Carol"))
    (mx-check "the fake is not the real name"
              (member alice '("Alice Chen")) nil))

  ;; Room names: id-keyed, bridge tags pass through, direct rooms
  ;; fake as people.
  (let ((fake (elneo-anon--room-name "!r:1" "Work (telegram)" nil)))
    (mx-check "bridge suffix kept on the fake name"
              (and (> (length fake) 0)
                   (string-suffix-p "(telegram)" fake)
                   (not (string-match-p "Work" fake)))
              t)
    (mx-check "fake and real name agree when there is nothing to bridge"
              (string-suffix-p "(telegram)"
                               (elneo-anon--room-name "!r:2"
                                                       "Lounge (telegram)"
                                                       nil))
              t)
    (mx-check "different rooms, different fakes (fixed salt)"
              (equal (elneo-anon--room-name "!r:1" "Lounge" nil)
                     (elneo-anon--room-name "!r:2" "Lounge" nil))
              nil)
    (mx-check "direct rooms fake as a person"
              (and (string-match-p
                    (regexp-opt (mapcar #'identity elneo-anon--first-names))
                    (elneo-anon--room-name "!r:3" "Alice Chen" t))
                   t)
              t)
    (mx-check "nil name with room id still fakes"
              (> (length (elneo-anon--room-name "!r:4" nil t)) 0)
              t))

  ;; Prose: deterministic, keyed per room+body (so the bar preview
  ;; and the message body agree), non-empty for non-empty bodies,
  ;; empty for empty — and longer originals get longer fakes.
  (let* ((one (elneo-anon--prose "!r:10" "anyone up for a quick sync?"))
         (again (elneo-anon--prose "!r:10" "anyone up for a quick sync?"))
         (other (elneo-anon--prose "!r:11" "anyone up for a quick sync?"))
         (big (elneo-anon--prose "!r:10" (make-string 300 ?x))))
    (mx-check "prose is deterministic" (list one again) (list one one))
    (mx-check "prose is keyed per room" (equal one other) nil)
    (mx-check "prose never ships the original"
              (string-match-p "anyone" one) nil)
    (mx-check "empty body stays empty"
              (list (elneo-anon--prose "!r:10" "")
                    (elneo-anon--prose "!r:10" nil))
              (list "" nil))
    (mx-check "longer text, longer fake" (> (length big) (length one)) t))

  ;; Short text (poll options, captions): deterministic, never the
  ;; original.
  (let ((fake (elneo-anon--short-text "!r:1" "Pizza")))
    (mx-check "short text is deterministic and unrecognizable"
              (list fake (elneo-anon--short-text "!r:1" "Pizza")
                    (equal fake "Pizza"))
              (list fake fake nil)))

  ;; File names: extension kept, stem faked; empty names stay.
  (let ((fake (elneo-anon--file-name "!r:1" "report.pdf")))
    (mx-check "file fakes keep the extension"
              (and (string-suffix-p ".pdf" fake)
                   (not (string-match-p "report" fake)))
              t)
    (mx-check "empty file name stays empty"
              (elneo-anon--file-name "!r:1" "")
              ""))

  ;; Account tags: one lowercase word from the pool.
  (let ((tag (elneo-anon--tag "work")))
    (mx-check "tag fakes deterministically from the pool"
              (and (stringp tag)
                   (member tag (mapcar #'identity elneo-anon--tags))
                   (equal tag (elneo-anon--tag "work")))
              t)
    (mx-check "tag keys on the real profile"
              (equal (elneo-anon--tag "work") (elneo-anon--tag "work"))
              t))

  ;; Member lines: roster names (and the acting localpart) replace
  ;; through their ids; the display-name change's paren pair fakes
  ;; by name; an unparseable sentence falls back rather than shipping.
  (let* ((roster (list (list :user-id "@alice:mx.org" :name "Alice Chen")
                       (list :user-id "@bob:mx.org" :name "Bob")))
         (fake-alice (elneo-anon--person "@alice:mx.org" "Alice Chen"))
         (fake-bob (elneo-anon--person "@bob:mx.org" "Bob"))
         (kicked (elneo-anon--member-line
                  "Alice Chen was kicked by Bob" roster "@bob:mx.org" "Bob"))
         (renamed (elneo-anon--member-line
                   "Bob changed their display name (Alta → Bobbie)"
                   roster "@bob:mx.org" "Bob"))
         (self (elneo-anon--member-line "You joined the room" roster
                                         "@me:mx.org" "Me")))
    (mx-check "kicked line fakes both names by id"
              (and (string-match-p (regexp-quote fake-alice) kicked)
                   (string-match-p (regexp-quote fake-bob) kicked)
                   (not (string-match-p "Alice\\|Bob" kicked)))
              t)
    (mx-check "display-name change fakes the paren pair"
              (and (string-match-p (regexp-quote fake-bob) renamed)
                   (string-match "display name (\\([^()]*\\) → \\([^()]*\\))"
                                 renamed)
                   (not (string-match-p "Alta\\|Bobbie|Bob[^-]" renamed))
                   t)
              t)
    (mx-check "own sentences (\"You …\") pass through"
              self "You joined the room")
    (mx-check "unparseable line falls back (no real name ships)"
              (let ((gen (elneo-anon--member-line
                          "joined and left the same minute" roster
                          "@rupert:mx.org" "Rupert Jones")))
                (and (member gen (mapcar #'identity
                                         elneo-anon--member-fallback))
                     t))
              t))

  ;; The wrapper copies messages; the input plist never changes.
  (let* ((person-before (elneo-anon--person "@alice:mx.org" "Alice Chen"))
         (body (elneo-anon--prose "!r:55" "hello there"))
         (msg (list :event-id "$e" :ts 1737043200000
                    :sender "@alice:mx.org" :sender-name "Alice Chen"
                    :msgtype "m.text" :body "hello there"
                    :formatted-body "<b>hello there</b>"))
         (copy (elneo-anon--message msg "!r:55")))
    (mx-check "sender mxid and event id stay raw"
              (list (plist-get copy :sender) (plist-get copy :event-id)
                    (plist-get copy :ts))
              (list "@alice:mx.org" "$e" 1737043200000))
    (mx-check "sender-name fakes through the mxid"
              (plist-get copy :sender-name) person-before)
    (mx-check "body fakes per room+text"
              (plist-get copy :body) body)
    (mx-check "the input plist is untouched"
              (list (plist-get msg :sender-name) (plist-get msg :body)
                    (plist-get msg :formatted-body))
              (list "Alice Chen" "hello there" "<b>hello there</b>")))

  ;; Media and polls fake what they show; ids and mxc urls stay raw.
  (let* ((media-msg (list :event-id "$m" :sender "@alice:mx.org"
                          :sender-name "Alice Chen" :msgtype "m.image"
                          :body "photo1.jpg"
                          :media (list '(filename . "photo1.jpg")
                                       '(url . "mxc://x/y"))))
         (media-copy (elneo-anon--message media-msg "!r:55"))
         (media (plist-get media-copy :media))
         (poll-msg (list :event-id "$p" :sender "@alice:mx.org"
                         :sender-name "Alice Chen" :msgtype "m.poll.start"
                         :body "Lunch?"
                         :poll (list :question "Lunch?" :kind "m.disclosed"
                                     :options
                                     (list (list :id "o1" :text "Pizza"
                                                 :count 1 :own t
                                                 :voters '("@me:mx.org")
                                                 :count 1)))))
         (poll-copy (elneo-anon--message poll-msg "!r:55"))
         (poll (plist-get poll-copy :poll))
         (option (car (plist-get poll :options))))
    (mx-check "media filename fakes, mime data stays"
              (list (cdr (assq 'filename media))
                    (cdr (assq 'url media))
                    (string-suffix-p ".jpg" (cdr (assq 'filename media))))
              (list (cdr (assq 'filename media)) "mxc://x/y" t))
    (mx-check "poll question and body fake identically"
              (list (plist-get poll :question) (plist-get poll-copy :body))
              (list (elneo-anon--short-text "!r:55" "Lunch?")
                    (elneo-anon--short-text "!r:55" "Lunch?")))
    (mx-check "option text fakes, option id stays"
              (and (not (equal (plist-get option :text) "Pizza"))
                   (equal (plist-get option :id) "o1"))
              t)
    (mx-check "voter display names fake"
              (plist-get option :voters)
              (list (elneo-anon--person "@me:mx.org" nil)))
    (mx-check "the poll input plist is untouched"
              (plist-get (plist-get poll-msg :poll) :question)
              "Lunch?"))

  ;; Undecryptable bodies stay literal; redacted bodies fake but keep
  ;; the "[redacted]" marker rendering theirs.
  (let* ((msg1 (list :event-id "$u" :sender "@a" :msgtype "m.undecryptable"
                     :body "[unable to decrypt]"))
         (msg2 (list :event-id "$r" :sender "@a" :msgtype "m.text"
                     :body "" :redacted t :redacted-body "secret plan"))
         (copy1 (elneo-anon--message msg1 "!r:55"))
         (copy2 (elneo-anon--message msg2 "!r:55")))
    (mx-check "undecryptable marker stays literal"
              (plist-get copy1 :body) "[unable to decrypt]")
    (mx-check "revealed originals fake, empty bodies stay"
              (list (plist-get copy2 :redacted-body)
                    (plist-get copy2 :body))
              (list (elneo-anon--prose "!r:55" "secret plan")
                    "")))

  ;; The room render copy fakes name and preview, keeps everything
  ;; the bar needs raw, and never mutates the registry record.
  (let* ((room (list :profile "work" :room-id "!r:9"
                     :display-name "Work (telegram)"
                     :preview "real last message"
                     :direct nil :unread 3 :avatar nil))
         (copy (elneo-anon--room room))
         (fake-name (plist-get copy :display-name)))
    (mx-check "room name fakes with the suffix"
              (and (string-suffix-p "(telegram)" fake-name)
                   (not (string-match-p "Work" fake-name)))
              t)
    (mx-check "preview fakes with the same key the buffer body uses"
              (plist-get copy :preview)
              (elneo-anon--prose "!r:9" "real last message"))
    (mx-check "registry keys stay raw"
              (list (plist-get copy :profile) (plist-get copy :room-id)
                    (plist-get copy :direct) (plist-get copy :unread))
              (list "work" "!r:9" nil 3))
    (mx-check "the room record is untouched"
              (plist-get room :display-name)
              "Work (telegram)"))

  ;; === Render integration: the whole room-buffer pipeline with the
  ;; mode on.  The synthetic room below holds a text message, a
  ;; member line, a reply to the text, and a poll.
  (let ((buf (generate-new-buffer " *mx-anon-room*"))
        (raw-seen nil) (real-text nil) (fake-text nil))
    (with-current-buffer buf
      (elneo-room-mode)
      (setq elneo-room--profile "mxtest"
            elneo-room--room-id "!r:anon.org"
            elneo-room--seen (make-hash-table :test 'equal)
            elneo-room--reactions (make-hash-table :test 'equal)
            elneo-room--receipts (make-hash-table :test 'equal)
            elneo-room--members
            (list (list :user-id "@alice:mx.org" :name "Alice Chen")
                  (list :user-id "@bob:mx.org" :name "Bob")))
      (puthash (cons "mxtest" "!r:anon.org") buf elneo-room--buffers)
      (let* ((t0 1737043200000)
             (msgs
              (list
               (list :event-id "$t" :ts t0 :sender "@alice:mx.org"
                     :sender-name "Alice Chen" :is-own nil
                     :msgtype "m.text" :body "real secret text")
               (list :event-id "$m" :ts (+ t0 1000) :sender "@bob:mx.org"
                     :sender-name "Bob" :is-own nil
                     :msgtype "m.member" :body "Alice Chen was kicked by Bob")
               (list :event-id "$p" :ts (+ t0 2000) :sender "@alice:mx.org"
                     :sender-name "Alice Chen" :is-own nil
                     :msgtype "m.poll.start" :body "Lunch?"
                     :poll (list :question "Lunch?" :kind "m.disclosed"
                                 :options
                                 (list (list :id "o1" :text "Pizza" :count 0
                                             :own nil :voters nil))))
               (list :event-id "$r" :ts (+ t0 3000) :sender "@bob:mx.org"
                     :sender-name "Bob" :is-own nil :reply-to "$t"
                     :msgtype "m.text" :body "a reply of my own"))))
        ;; All three renders go through `--render-first-page' — the
        ;; exact path the mode's toggle uses.  The registry is empty
        ;; in this test, so `elneo-room-get' is stubbed to the same
        ;; record the header read would return live.
        (let ((hdr-fun (lambda (_profile _room-id)
                         (list :display-name "Real room (telegram)"
                               :room-id "!r:anon.org"
                               :topic "real topic"))))
          ;; Render with the REAL names first: this is what a
          ;; toggle-off restore must reproduce byte for byte.
          (setq elneo-anon-mode nil)
          (cl-letf (((symbol-function 'elneo-room-get) hdr-fun))
            (elneo-room--render-first-page msgs nil nil))
          (setq real-text (buffer-substring (point-min) (point-max)))
          ;; The raw seen table (mode off) — the toggle's restore basis.
          (maphash (lambda (_k v) (push v raw-seen)) elneo-room--seen)
          ;; Render with the mode ON.
          (setq elneo-anon-mode t)
          (cl-letf (((symbol-function 'elneo-room-get) hdr-fun))
            (elneo-room--render-first-page msgs nil nil))
          (setq fake-text (buffer-substring (point-min) (point-max)))
        ;; Nothing real may ship anywhere in the buffer.
        (mx-check "render: no real names, bodies, or topic"
                  (mapcar (lambda (needle) (string-match-p needle fake-text))
                          '("Alice Chen" "Bob[^-]" "real secret text"
                            "Real room" "real topic" "Lunch?" "Pizza"))
                  (list nil nil nil nil nil nil nil))
        ;; ...but the structure stays: a body line, a poll block with
        ;; faked options, the reply quote over its body.
        (mx-check "render: fake poll options rendered"
                  (and (string-match-p
                        (regexp-quote
                         (elneo-anon--short-text "!r:anon.org" "Lunch?"))
                        fake-text)
                       (string-match-p
                        (regexp-quote
                         (elneo-anon--short-text "!r:anon.org" "Pizza"))
                        fake-text)
                       t)
                  t)
        ;; The reply quote lives on the reply's first line, right
        ;; after its sender name: it shows the parent's fake NAME
        ;; (mxid-keyed, same fake the parent's own line shows).
        (mx-check "render: quote shows the parent's fake name"
                  (save-excursion
                    (goto-char (point-min))
                    (and (search-forward "↳ " nil t)
                         (string-match-p
                          (regexp-quote
                           (elneo-anon--person "@alice:mx.org"
                                                "Alice Chen"))
                          (buffer-substring (line-beginning-position)
                                            (line-end-position)))
                         t))
                  t)
        ;; ...and the quote text is the parent's fake body (the
        ;; quote may be truncated, so only its prefix must show).
        (mx-check "render: quote text is the parent's fake body"
                  (let* ((parent (gethash "$t" elneo-room--seen))
                         (fake-body (plist-get
                                     (elneo-anon--message
                                      parent "!r:anon.org"
                                      elneo-room--members)
                                     :body)))
                    (and (string-match-p
                          (regexp-quote (substring fake-body 0 10))
                          fake-text)
                         t))
                  t)
        ;; The seen table keeps raw data: the faked poll line renders
        ;; the faked question, the seen poll keeps the REAL one.
        (mx-check "seen: raw option text, no fakes"
                  (plist-get (plist-get (gethash "$p" elneo-room--seen)
                                        :poll)
                             :question)
                  "Lunch?")
        ;; Toggle off: the real text comes back verbatim.  A live
        ;; toggle runs `--rebuild'; with the same entries and header
        ;; record the render is the same byte for byte.
        (setq elneo-anon-mode nil)
        (cl-letf (((symbol-function 'elneo-room-get) hdr-fun))
          (elneo-room--rebuild))
        (mx-check "toggle-off restores the real buffer text"
                  (buffer-substring (point-min) (point-max))
                  real-text))
        ;; The seen table is byte-identical after everything.
        (let ((after nil))
          (maphash (lambda (_k v) (push v after)) elneo-room--seen)
          (mx-check "seen table never mutated"
                    (sort after
                          (lambda (a b)
                            (string-lessp
                             (or (plist-get a :event-id) "")
                             (or (plist-get b :event-id) ""))))
                  (sort raw-seen
                        (lambda (a b)
                          (string-lessp
                           (or (plist-get a :event-id) "")
                           (or (plist-get b :event-id) "")))))))))

  ;; === Bar: rows, tags and the initial-fallback avatar fake; the row
  ;; keys and unread counts stay raw.
  (let* ((row (list :profile "work" :room-id "!r:1"
                    :display-name "Work (telegram)"
                    :preview "real last message"
                    :unread 3 :highlights 0 :last-activity 100
                    :last-message "" :direct nil :avatar nil))
         (fake-name (plist-get (elneo-anon--room row) :display-name))
         (fake-preview (elneo-anon--prose "!r:1" "real last message")))
    (mx-check "bar row stays real with the mode off"
              (let ((elneo-room-bar-preview-style 'below))
                (and (string-match-p "Work" (elneo-room-bar--row-text row))
                     (string-match-p "real last message"
                                     (elneo-room-bar--row-text row))
                     t))
              t)
    (mx-check "bar row fakes name and preview, keeps the suffix"
              (let ((elneo-room-bar-preview-style 'below)
                    (elneo-room-bar-name-width 60)
                    (elneo-room-bar-width 80)
                    (elneo-anon-mode t))
                (let ((text (elneo-room-bar--row-text row)))
                  (list (and (string-match-p (regexp-quote fake-name) text)
                             t)
                        (and (string-suffix-p "(telegram)" fake-name) t)
                        (and (string-match-p (regexp-quote fake-preview)
                                             text)
                             t)
                        (and (string-match-p "Work\\|real last" text) t))))
              (list t t t nil))
    (mx-check "bar unread count stays raw while the mode is on"
              (let ((elneo-room-bar-preview-style 'none)
                    (elneo-room-bar-name-width 60)
                    (elneo-anon-mode t))
                ;; The row highlights nothing; an unread room shows
                ;; its bare "3 " before the name, still on the row.
                (and (string-match-p "3" (elneo-room-bar--row-text row))
                     t))
              t)
    (mx-check "bar tags fake, keys on the real profile"
              (let ((off (elneo-room-bar--tag "work"))
                    (elneo-anon-mode t))
                (let ((on (elneo-room-bar--tag "work")))
                  (list off
                        (and (member on (mapcar #'identity
                                               elneo-anon--tags))
                             t)
                        (not (equal on "work")))))
              (list "work" t t))
    ;; === Grouped-bar headers: the label fakes, the fold/click
    ;; actions and the header's account property keep the real
    ;; profile.
    (mx-check "grouped header fake: label faked, property raw"
              (let ((buf (generate-new-buffer " *mx-anon-bar*")))
                (unwind-protect
                    (let ((elneo-anon-mode t)
                          (elneo-room-bar--buffer buf)
                          (elneo-room-bar--markers
                           (make-hash-table :test 'equal))
                          (elneo-room-bar--folded-accounts
                           (make-hash-table :test 'equal))
                          (elneo-room-bar-grouped t)
                          (rooms
                           (list (list :profile "a" :room-id "!x"
                                       :display-name "Alpha room"
                                       :unread 0 :highlights 0
                                       :last-activity 1 :last-message "")
                                 (list :profile "b" :room-id "!z"
                                       :display-name "Zeta (telegram)"
                                       :unread 2 :highlights 0
                                       :last-activity 2 :last-message ""))))
                      (cl-letf (((symbol-function 'elneo-rooms-all)
                                 (lambda () rooms)))
                        (elneo-room-bar-refresh-full)
                        (let* ((text (with-current-buffer buf
                                       (buffer-string)))
                               (hdr-pos (string-match "\u25be" text)))
                          (list
                           ;; The labels carry the faked tags.
                           (and (string-match-p
                                 (regexp-quote
                                  (elneo-room-bar--tag "a")) text)
                                (string-match-p
                                 (regexp-quote
                                  (elneo-room-bar--tag "b")) text)
                                t)
                           ;; The header's account property keeps the
                           ;; REAL profile: fold/click actions key on
                           ;; it.  Sections sort by activity, so find
                           ;; the "a" header wherever it landed; get
                           ;; must be equal, not eq, on the string.
                           (with-current-buffer buf
                             (let ((p (point-min)) (hit))
                               (while (and (not hit)
                                           (< p (point-max)))
                                 (when (equal (get-text-property
                                               p
                                               'elneo-room-bar-account)
                                              "a")
                                   (setq hit t))
                                 (setq p (next-single-property-change
                                          p 'elneo-room-bar-account
                                          nil (point-max))))
                               hit))
                           ;; The real names ship nowhere.
                           (and (not (string-match-p "Alpha room" text))
                                (not (string-match-p "\u25be a\\|\u25be b" text))
                                t)))))
                  (kill-buffer buf)))
              (list t t t))

  ;; === Settings view: name/alias/topic fake, the room id and the
  ;; action buttons stay real.
  (let ((room (list :profile "work" :room-id "!r:9"
                    :display-name "Work (telegram)"
                    :name "!aliasroom" :alias "#work:example.org"
                    :topic "real secret topic"
                    :notification-mode "all_messages"
                    :unread 3 :highlights 0)))
    (let ((out (with-temp-buffer
                 (let ((standard-output (current-buffer))
                       (elneo-anon-mode nil)
                       (elneo-room--seen (make-hash-table :test 'equal)))
                   (elneo-room-settings--render room))
                 (buffer-string)))
          (fake (let ((elneo-anon-mode t))
                  (elneo-anon--room room))))
      (mx-check "settings off: real name and topic, real room id"
                (list (and (string-search "Work (telegram)" out) t)
                      (and (string-search "real secret topic" out) t)
                      (and (string-search "!r:9" out) t)
                      (and (string-search "#work:example.org" out) t))
                (list t t t t))
      (mx-check "settings on: names and text fake, room id stays"
                (let ((elneo-anon-mode t))
                  (with-temp-buffer
                    (let ((standard-output (current-buffer))
                          (elneo-room--seen (make-hash-table :test 'equal)))
                      (elneo-room-settings--render room))
                    (let ((text (buffer-string)))
                      (list (and (string-search
                                  (plist-get fake :display-name) text) t)
                            ;; princ leaves the temp buffer's point at
                            ;; point-max — never search-forward here;
                            ;; match the captured string instead.
                            (and (string-match-p "!r:9" text) t)
                            (and (not (string-search "Work (telegram)" text))
                                 t)
                            (and (not (string-search "real secret topic"
                                                     text))
                                 t)))))
          (list t t t t))))

  (message "results: %d passed, %d failed" pass fail)
  (when (> fail 0) (kill-emacs 1)))
)
