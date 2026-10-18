;;; elneo-anon.el --- screenshot mode: fake data at render time -*- lexical-binding: t; -*-

;;; Commentary:

;; A global toggle that rewrites every user-identifiable display string
;; (message bodies, sender and room names, the room bar's rows, poll
;; text) to deterministic plausible fakes while it is on, so the client
;; can be screenshotted without disclosing anyone's real data.
;;
;; Render-time only: the message history (`elneo-room--seen') and the
;; room registry are never touched, so toggling off (which re-renders
;; every room buffer and the bar) restores the real text verbatim.
;; Real images keep rendering; the colored-initial avatar fallback
;; derives from the faked name.
;;
;; Fakes are deterministic per session: a salt picked at first use
;; feeds a SHA-256 of (category, key) into pool indices, so the same
;; person, room or message body fakes identically everywhere in the
;; session — a reply quote shows the same fake name as the message
;; line, the bar preview shows the same fake prose as the body.  The
;; salt is not persistent: a restart reshuffles the fakes, which keeps
;; screenshots across sessions from correlating.
;;
;; Out of scope deliberately: alert/echo-area text, buffer names,
;; transient menus, the wire protocol, room ids and `elneo-room-key'
;; text properties.  See `elneo-anon-mode''s docstring.

;;; Code:

(require 'cl-lib)

(defgroup elneo-anon nil
  "Screenshot mode: fake data rendered in place of real names."
  :group 'applications
  :prefix "elneo-")

(defvar elneo-anon--salt nil
  "Hash salt for this session.  Kept nil until the first fake is
generated: each Emacs run generates its own fakes.")

(defvar elneo-anon--cache (make-hash-table :test 'equal)
  "SHA-256 digests by \"CATEGORY:KEY\".  Caching turns repeated
render passes (bar re-renders, replace-message) into hash-table
lookups and guarantees byte-identical fakes across passes.")

;;; Word pools

(defconst elneo-anon--first-names
  ["Avery" "Bailey" "Casey" "Dana" "Ellis" "Finley" "Harper" "Ira"
   "Jamie" "Kelly" "Logan" "Morgan" "Noor" "Perry" "Quinn" "Reese"
   "Sasha" "Teo" "Uma" "Vic" "Willow" "Wren"]
  "Pool of fake first names.")

(defconst elneo-anon--last-names
  ["Abbott" "Bramble" "Calloway" "Dunmore" "Eastwick" "Fairbairn"
   "Greenwood" "Hartley" "Irving" "Jessup" "Kestrel" "Larkspur"
   "Merriweather" "Oakes" "Pemberton" "Quill" "Radcliffe" "Sinclair"
   "Thistlewood" "Underhill" "Vance" "Winthrop"]
  "Pool of fake last names.")

(defconst elneo-anon--room-adjectives
  ["Amber" "Bright" "Calm" "Deep" "Fern" "Gentle" "Highland" "Ivy"
   "Juniper" "Kindred" "Limebrook" "Mistral" "Narrow" "Oldbridge"
   "Quiet" "Rushmere" "Silver" "Thornfield" "Upland" "Winter"]
  "Pool of fake room-name adjectives.")

(defconst elneo-anon--room-nouns
  ["Arbor" "Cellar" "Doorway" "Field" "Garden" "Hillside" "Isle"
   "Junction" "Kitchen" "Lighthouse" "Meadow" "Notch" "Orchard"
   "Pond" "Quay" "Rookery" "Stable" "Tunnel" "Workshop" "Yard"]
  "Pool of fake room-name nouns.")

(defconst elneo-anon--words
  ["branch" "build" "cache" "calendar" "cleanup" "config" "crash"
   "daemon" "dashboard" "default" "deploy" "desktop" "draft" "editor"
   "error" "export" "feature" "filter" "fix" "format" "gallery"
   "header" "hook" "import" "index" "install" "issue" "keymap"
   "library" "license" "lint" "log" "menu" "module" "network" "note"
   "outline" "package" "parser" "patch" "prefix" "profile" "prompt"
   "query" "queue" "relay" "release" "render" "report" "review" "room"
   "runtime" "script" "search" "server" "session" "setting" "shortcut"
   "snapshot" "stack" "startup" "theme" "thread" "upload" "viewer"
   "widget" "window" "wrapper" "buffer"]
  "Pool of words filling the sentence templates' %s slots.")

(defconst elneo-anon--sentences
  ["I think the %s is finally working again."
   "Can you take a look at the %s when you get a chance?"
   "The %s looks good to me, thanks for running it."
   "Not sure about the %s yet, still reading through it."
   "That %s from yesterday turned out fine in the end."
   "The meeting about the %s got pushed to tomorrow."
   "I'll wrap up the %s on Monday if nothing else comes up."
   "Good catch on the %s, wouldn't have spotted that myself."
   "Just pushed a fix for the %s, can someone double-check it?"
   "The %s has been quiet all week, worth a second look."
   "Seems the %s only breaks right after a deploy, funny timing."
   "I keep losing the %s whenever the window closes, any ideas?"]
  "One-sentence chat templates; each %s takes a word from
`elneo-anon--words'.  Longer fakes repeat a template with
different slots.")

(defconst elneo-anon--tags
  ["amber" "bay" "cedar" "dune" "elm" "fern" "glen" "harbor" "iris"
   "juniper" "kettle" "larch" "maple" "orchard"]
  "Pool of fake account tags (lowercase, one word).")

(defconst elneo-anon--stems
  ["meadow" "fox" "river" "stone" "bramble" "cloud" "fern" "hollow"
   "lantern" "moss" "reed" "spur" "thicket" "vale" "willow" "creek"]
  "Pool of words for fake file-name stems (two joined with a -).")

(defconst elneo-anon--member-fallback
  ["The room's membership changed."
   "A membership update landed in the room."]
  "Whole-sentence fakes for member lines that no longer parse —
wording drift between client and daemon, or a name the roster
misses.  Rare; keeps a line from shipping real names uncaught.")

;;; Hashing

(defun elneo-anon--digest (category key)
  "SHA-256 hex digest for CATEGORY/KEY, byte-identical all session."
  (when (null elneo-anon--salt)
    (setq elneo-anon--salt
          (format "%s %s" (emacs-pid) (current-time))))
  (let ((ckey (concat category ":" (if (stringp key) key (format "%S" key)))))
    (or (gethash ckey elneo-anon--cache)
        (let ((v (secure-hash 'sha256
                              (concat "mx-anon:" elneo-anon--salt ":" ckey))))
          (puthash ckey v elneo-anon--cache)
          v))))

(defun elneo-anon--index (digest offset pool)
  "A POOL index carried in the 4 hex digits at OFFSET of DIGEST.
Offsets wrap around the 64-char digest, so any template/slot count
stays in range."
  (mod (string-to-number
        (substring digest (mod offset 64) (min 64 (+ (mod offset 64) 4)))
        16)
       (length pool)))

(defun elneo-anon--pick (digest offset pool)
  "A POOL element from the 4 hex digits at OFFSET of DIGEST."
  (aref pool (elneo-anon--index digest offset pool)))

;;; Generators

(defun elneo-anon--person (id name)
  "Fake person for MXID ID or display name NAME.
An MXID keys the fake (so a roster name and a sender name resolve
to the same fake person); without one, the name itself keys it."
  (let ((digest (elneo-anon--digest
                 "person"
                 (if (and id (> (length id) 0))
                     (concat "id:" id)
                   (concat "dn:" (or name ""))))))
    (concat (elneo-anon--pick digest 0 elneo-anon--first-names)
            " "
            (elneo-anon--pick digest 4 elneo-anon--last-names))))

(defun elneo-anon--room-name (room-id name direct)
  "Fake room name for the room record's NAME and DIRECT flag.
A parenthesized bridge tag at the end (`(telegram)') belongs to
the structure, not the person — it is kept verbatim on the fake."
  (let* ((digest (elneo-anon--digest "room" (or room-id (or name ""))))
         (fake
          (if direct
              (concat (elneo-anon--pick digest 0 elneo-anon--first-names)
                      " "
                      (elneo-anon--pick digest 4 elneo-anon--last-names))
            (concat (elneo-anon--pick digest 0 elneo-anon--room-adjectives)
                    " "
                    (elneo-anon--pick digest 4 elneo-anon--room-nouns)))))
    (if (and (stringp name)
             (string-match "(\\([^()]+\\))[ \t]*\\'" name))
        (concat fake " " (match-string 0 name))
      fake)))

(defun elneo-anon--prose (room-id text)
  "Plausible fake prose replacing TEXT in ROOM-ID.
Empty bodies stay empty — the media arms and the bar's preview
checks on `= 0' keep working.  A body's key is its room plus its
raw text: the bar preview of a message and that message's body in
the buffer render the very same fake."
  (cond
   ((or (null text) (= (length text) 0)) text)
   (t
    (let* ((base (concat room-id "\0" text))
           ;; Sentence count tracks the original's length in three
           ;; coarse buckets — long posts stay long, one-liners stay
           ;; short, and nothing leaks the exact size.
           (count (cond
                   ((< (length text) 90) 1)
                   ((< (length text) 220) 2)
                   (t 3))))
      (mapconcat
       (lambda (i)
         (let* ((digest (elneo-anon--digest
                         "sentence"
                         (concat base "\0" (number-to-string i))))
                (template (aref elneo-anon--sentences
                                (elneo-anon--index digest 0
                                                   elneo-anon--sentences))))
           ;; Each %s slot takes its own sub-hash so a sentence never
           ;; repeats a word.
           (let ((k 0))
             (replace-regexp-in-string
              "%s"
              (lambda (_)
                (let ((word (elneo-anon--pick
                             (elneo-anon--digest
                              "word" (concat base "\0" (number-to-string i) ":" (number-to-string k)))
                             0 elneo-anon--words)))
                  (setq k (1+ k))
                  word))
              template
              t t))))
       (number-sequence 0 (1- count))
       " ")))))

(defun elneo-anon--short-text (room-id text)
  "A short fake (poll options, captions) for TEXT in ROOM-ID."
  (if (or (null text) (= (length text) 0)) text
    (let ((digest (elneo-anon--digest "short" (concat room-id "\0" text))))
      (concat (capitalize (elneo-anon--pick digest 0 elneo-anon--words))
              " "
              (capitalize (elneo-anon--pick digest 4 elneo-anon--words))))))

(defun elneo-anon--file-name (room-id name)
  "Fake a media file NAME: two lowercase words plus the extension."
  (if (or (null name) (= (length name) 0)) name
    (let* ((digest (elneo-anon--digest "file" (concat room-id "\0" name)))
           (stem (concat (elneo-anon--pick digest 0 elneo-anon--stems)
                         "-"
                         (elneo-anon--pick digest 4 elneo-anon--stems)))
           (ext (and (string-match "\\.[^./\\\\]+$" name)
                     (match-string 0 name))))
      (concat stem (or ext "")))))

(defun elneo-anon--tag (profile)
  "A fake one-word account tag for PROFILE."
  (elneo-anon--pick (elneo-anon--digest "tag" profile)
                    0 elneo-anon--tags))

;;; Member system lines

;; The daemon composes membership sentences server-side ("Quinn
;; kicked Dana"), so the client fakes them by replacing the names
;; they contain.  Every name resolves through its mxid when the
;; roster knows it, so a person keeps one fake across sender lines,
;; quotes and member sentences.

(defun elneo-anon--member-line (body roster sender sender-name)
  "Fake the daemon's precomposed membership sentence BODY.
ROSTER is the room member list (plists with :user-id/:name),
SENDER the acting member's mxid, SENDER-NAME their display name.
Unknown names in a display-name change's old->new pair fake by
name; a sentence nothing parsed degrades to a generic line rather
than shipping a real name."
  (if (or (null body) (= (length body) 0))
      body
    (let* ((cands nil)
           ;; Display-name changes carry history inside parens:
           ;; "(old -> new)" fakes by name (no id to key on).
           (paren (and (string-search "display name (" body)
                       (string-match
                        "display name ([[:space:]]*\\([^→()]*?\\) → \\([^→()]*?\\))"
                        body)))
           (paren-old (and paren (match-string 1 body)))
           (paren-new (and paren (match-string 2 body)))
           (add-cand
            (lambda (real fake)
              (when (and (stringp real) (> (length real) 0)
                         (stringp fake) (> (length fake) 0)
                         (not (string= real "You"))
                         ;; Longer first wins below; skip duplicates.
                         (not (assoc real cands #'equal))
                         (string-match-p (regexp-quote real) body))
                (push (cons real fake) cands)))))
      (when paren-old
        (funcall add-cand paren-old (elneo-anon--person nil paren-old))
        (funcall add-cand paren-new (elneo-anon--person nil paren-new)))
      ;; Roster names resolve through their ids.
      (when (listp roster)
        (dolist (m roster)
          (let ((id (plist-get m :user-id))
                (name (plist-get m :name)))
            (when (and id name (not (equal name id)))
              (funcall add-cand name (elneo-anon--person id name))))))
      ;; The acting member's name even while the roster is missing,
      ;; and their bare localpart fallback ("alice").
      (when (and sender-name (> (length sender-name) 0))
        (funcall add-cand sender-name (elneo-anon--person sender
                                                          sender-name)))
      (when (and sender (string-match "\\`@\\([^:]+\\):" sender))
        (funcall add-cand (match-string 1 sender)
                 (elneo-anon--person sender nil)))
      ;; Longer names first: "Alice" must not eat "Alice Chen".
      (setq cands
            (sort cands (lambda (a b) (> (length (car a)) (length (car b))))))
      (let ((out body) (hits 0))
        (dolist (c cands)
          (when (string-match-p (regexp-quote (car c)) out)
            (cl-incf hits)
            (setq out (replace-regexp-in-string
                       (regexp-quote (car c)) (cdr c) out t t))))
        ;; Nothing matched and the sentence names someone: drop to a
        ;; generic line instead of shipping real names.
        (if (and (= hits 0) (not (string-prefix-p "You" body)))
            (elneo-anon--pick (elneo-anon--digest "member" body)
                              0 elneo-anon--member-fallback)
          out)))))

;;; Wrappers over the plists

(defun elneo-anon--fake-body (copy room-id roster)
  "Set COPY's `:body' (and friends) to their fakes; return COPY.
Dispatch by msgtype: membership sentences through the roster,
media bodies through the file-name fake, locations and polls
through short text, undecryptable/redacted markers literal, and
everything else through prose."
  (let* ((msgtype (plist-get copy :msgtype))
         (body (plist-get copy :body))
         (new-body
          (cond
           ((and msgtype (string= msgtype "m.member"))
            (elneo-anon--member-line body roster
                                     (plist-get copy :sender)
                                     (plist-get copy :sender-name)))
           ;; A poll's body is its question — fake with the same
           ;; short-text key the :poll question uses, so the body
           ;; line and the (p) pickups agree.
           ((and msgtype (string= msgtype "m.poll.start"))
            (elneo-anon--short-text room-id body))
           ;; "[unable to decrypt]" stays literal: nothing to fake,
           ;; and the marker text the user recognizes must not change.
           ((and msgtype (string= msgtype "m.undecryptable"))
            body)
           ;; Media bodies name the file; a location's caption fakes
           ;; like poll text.  The `[image: ...]' tags render from
           ;; this body.
           ((and msgtype
                 (member msgtype '("m.image" "m.sticker" "m.file"
                                   "m.video" "m.audio")))
            (elneo-anon--file-name room-id body))
           ((and msgtype (string= msgtype "m.location"))
            (elneo-anon--short-text room-id body))
           (t (elneo-anon--prose room-id body)))))
    (plist-put copy :body new-body)
    ;; Rich markup cannot be reproduced from a fake — the fake
    ;; renders as plain prose (inline-image markers vanish, a
    ;; documented limitation).
    (when (plist-get copy :formatted-body)
      (plist-put copy :formatted-body
                 (elneo-anon--prose room-id body)))
    (when (plist-get copy :redacted-body)
      (plist-put copy :redacted-body
                 (elneo-anon--prose room-id (plist-get copy :redacted-body))))
    (when (plist-get copy :media)
      (let* ((media (copy-alist (plist-get copy :media)))
             (cell (and media (assq 'filename media))))
        (when (and cell (cdr cell))
          (setcdr cell (elneo-anon--file-name room-id (cdr cell))))
        (plist-put copy :media media)))
    (when (plist-get copy :poll)
      (let ((poll (copy-sequence (plist-get copy :poll))))
        ;; The question fakes with the body's own key (the body IS the
        ;; question); option texts get theirs, and voters resolve
        ;; through their display names.
        (plist-put poll :question (elneo-anon--short-text room-id body))
        (plist-put poll :options
                   (mapcar (lambda (option)
                             (let ((o (copy-sequence option)))
                               (plist-put o :text
                                          (elneo-anon--short-text
                                           room-id (plist-get o :text)))
                               (plist-put o :voters
                                          (mapcar (lambda (voter)
                                                    (if (and (stringp voter)
                                                             (string-prefix-p
                                                              "@" voter))
                                                        (elneo-anon--person
                                                         voter nil)
                                                      (elneo-anon--person
                                                       nil voter)))
                                                  (plist-get o :voters)))
                               o))
                           (plist-get poll :options)))
        (plist-put copy :poll poll)))
    copy))

(defun elneo-anon--message (msg room-id &optional roster)
  "Render-copy of message plist MSG with every name faked.
The seen table keeps the real plist: hooks copy before rendering.
ROOM-ID keys the fake text (one room, one fake); ROSTER is the
room member list (plists with :user-id/:name) used to fake the
names inside membership sentences."
  (when msg
    (let ((copy (copy-sequence msg)))
      (plist-put copy :sender-name
                 (elneo-anon--person (plist-get copy :sender)
                                     (plist-get copy :sender-name)))
      (elneo-anon--fake-body copy room-id roster)
      copy)))

(defun elneo-anon--room (room)
  "Render-copy of room record ROOM with name and preview faked.
Everything else — the registry keys, `:profile', `:avatar' (an
image keeps rendering), `:unread', `:room-id' — stays raw."
  (when room
    (let* ((copy (copy-sequence room))
           (room-id (plist-get copy :room-id))
           (preview (plist-get copy :preview)))
      (when (plist-get copy :display-name)
        (plist-put copy :display-name
                   (elneo-anon--room-name
                    room-id (plist-get copy :display-name)
                    (plist-get copy :direct))))
      ;; The canonical room name (the settings view shows it next to
      ;; the display name) and the alias and topic (the room
      ;; header's subtitle) fake like the display name.
      (when (plist-get copy :name)
        (plist-put copy :name
                   (elneo-anon--short-text room-id (plist-get copy :name))))
      (when (plist-get copy :alias)
        (plist-put copy :alias
                   (elneo-anon--short-text room-id (plist-get copy :alias))))
      (when (and (plist-get copy :topic) (> (length (plist-get copy :topic)) 0))
        (plist-put copy :topic
                   (elneo-anon--prose room-id (plist-get copy :topic))))
      (when (and preview (> (length preview) 0))
        (plist-put copy :preview (elneo-anon--prose room-id preview)))
      copy)))

;;; The mode

;;;###autoload
(define-minor-mode elneo-anon-mode
  "Global toggle: render fake names and text in all Matrix buffers.
For screenshots.  Every visible user-identifiable string is
rewritten — message and member-line bodies, sender and room
names, poll text, the room bar's rows and previews, the room
header and the settings view's name/alias/topic — while the bar's
structure, unread counts, images, days and times stay real.

The rewrite happens at render time: toggling (each direction)
re-renders every room buffer and the bar from the untouched
history, restoring real text byte for byte on toggle-off.  Not
rewritten: alert and echo-area text, buffer names, the wire
protocol, and room ids.  Real avatars/thumbnails keep rendering by
design; the colored-initial fallbacks derive from the fake names.

Fakes differ per Emacs session on purpose (a restart reshuffles
them), and the bar's `s' search matches real names while fake text
displays — the sidebar still finds your rooms."
  :global t
  :group 'elneo-anon
  ;; The client may not be loaded yet (the mode is autoloaded); the
  ;; toggled rebuilds cover every direction, and nothing happens
  ;; before any Matrix buffer exists.
  (when (fboundp 'elneo-room--rebuild-all-buffers)
    (elneo-room--rebuild-all-buffers))
  (when (fboundp 'elneo-room-bar-refresh-full)
    (elneo-room-bar-refresh-full)))

(provide 'elneo-anon)

;;; elneo-anon.el ends here
