;;; url-test.el --- URL recognition in message text -*- lexical-binding: t; -*-

;; `elneo-room--linkify-string' marks bare http(s) URLs in plain bodies
;; (same regex as the outbound markup converter, trailing sentence
;; punctuation trimmed); `elneo-room--url-at-point' finds a link at
;; point (or one char back, also shr's rich-body links); `w' copies it;
;; mouse/RET browse it.  All batch.
;;
;; Run: emacs -Q --batch -L lisp -l test/url-test.el

(require 'elneo-room)
(require 'elneo-client) ; the room keymap bindings for --w/--ret

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defun mx-url-at (str pos)
    (get-text-property pos 'elneo-room-url str))

  ;; --- linkifier basics ---

  (let ((out (elneo-room--linkify-string "no links here, just words")))
    (mx-check "no URL → unchanged text" out "no links here, just words")
    (mx-check "no URL → no url prop" (mx-url-at out 0) nil))

  (let ((out (elneo-room--linkify-string "see https://example.com/foo now")))
    (mx-check "URL value on the span"
              (mx-url-at out 6) "https://example.com/foo")
    (mx-check "span reaches its end"
              (mx-url-at out (- (length "see https://example.com/foo") 1))
              "https://example.com/foo")
    (mx-check "past the span there is none" (mx-url-at out 30) nil)
    (mx-check "link face on the span"
              (get-text-property 6 'face out) 'elneo-room-url-face)
    (mx-check "keymap on the span"
              (eq (get-text-property 6 'keymap out)
                  elneo-room--url-keymap) t)
    (mx-check "mouse-face at hover"
              (get-text-property 6 'mouse-face out) 'highlight))

  (let ((out (elneo-room--linkify-string "go to https://example.com/x.")))
    ;; "go to " is 6 chars; the link runs 0-based [6,26], the dot sits
    ;; at the last position.
    (mx-check "trailing sentence dot trimmed"
              (mx-url-at out 6) "https://example.com/x")
    (mx-check "the dot itself stays unlinked"
              (mx-url-at out (1- (length out))) nil))

  (let ((out (elneo-room--linkify-string "(https://example.org/q)")))
    (mx-check "closing paren trimmed"
              (mx-url-at out 1) "https://example.org/q")
    (mx-check "the paren itself stays unlinked" (mx-url-at out 0) nil))

  (let ((out (elneo-room--linkify-string
              "GNU (see https://en.wikipedia.org/wiki/X_(node)) here")))
    (mx-check "balanced internal parens keep their closer"
              (mx-url-at out 9)
              "https://en.wikipedia.org/wiki/X_(node)"))

  (let ((out (elneo-room--linkify-string
              "a https://one.example/1 and https://two.example/2 b")))
    (mx-check "two URLs, two spans (first)"
              (mx-url-at out 2) "https://one.example/1")
    (mx-check "two URLs, two spans (second)"
              (mx-url-at out 31) "https://two.example/2"))

  ;; The stored message body must never be mutated: rendering keeps
  ;; working off the pristine plist strings.
  (let ((body "https://example.com/keep"))
    (elneo-room--linkify-string body)
    (mx-check "linkify does not mutate its input"
              (get-text-property 0 'elneo-room-url body) nil))

  ;; --- with the newline indenter applied after (render order) ---

  (let* ((body (elneo-room--indent-newlines
                (elneo-room--linkify-string
                 "one https://a.example/1\ntwo https://b.example/2")))
         (spots (cl-remove-if-not
                 (lambda (i) (eq (get-text-property i 'face body)
                                 'elneo-room-url-face))
                 (number-sequence 0 (1- (length body))))))
    (mx-check "links on both lines after newline indent (face spans)"
              (>= (length spots) 2) t)
    (mx-check "first line's URL readable"
              (string-prefix-p "https://a.example/1"
                               (mx-url-at body (cl-first spots))) t)
    (mx-check "second line's URL readable"
              (string-prefix-p "https://b.example/2"
                               (mx-url-at body (car (last spots)))) t))

  ;; --- url-at-point in a buffer ---

  (with-temp-buffer
    (insert (elneo-room--linkify-string
             "pre https://click.example/here post"))
    (goto-char (1+ (string-match "https" (buffer-string))))
    (mx-check "at span start" (elneo-room--url-at-point)
              "https://click.example/here")
    (forward-char 10)
    (mx-check "inside the span" (elneo-room--url-at-point)
              "https://click.example/here")
    ;; point on the first char PAST the span (the space after "here")
    ;; still counts, per the buffer's span convention.
    (goto-char (+ 1 (string-match " post" (buffer-string))))
    (mx-check "one char past the span" (elneo-room--url-at-point)
              "https://click.example/here")
    (goto-char (point-max))
    (mx-check "plain text after → nothing" (elneo-room--url-at-point) nil))

  ;; shr's rich-body links count too.
  (with-temp-buffer
    (insert (propertize "linked text" 'shr-url "https://rich.example/h"))
    (goto-char 2)
    (mx-check "shr-url fallback"
              (elneo-room--url-at-point) "https://rich.example/h"))

  ;; --- rich bodies: recovers the bare URLs the sender left unlinked
  ;; (the pills-then-words-then-a-URL message).  shr links only its
  ;; anchors; `elneo-room--linkify-rich' adds the plain-body span
  ;; properties to the rendered region, skipping anchor spans.

  (with-temp-buffer
    (insert (propertize "@a:hs" 'shr-url "https://matrix.to/#/@a:hs")
            " hello "
            (propertize "https://shown.example/p"
                        'shr-url "https://shown.example/p")
            " see "
            (propertize "https://also-shown.example/q"
                        'shr-url "https://also-shown.example/q")
            " then "
            "https://bare.example/r."
            " tail")
    (elneo-room--linkify-rich (point-min) (point-max))
    (let ((pill (1+ (string-match "@a:hs" (buffer-string))))
          (shown (1+ (string-search "https://shown.example/p" (buffer-string))))
          (bare (1+ (string-search "https://bare.example/r." (buffer-string)))))
      (mx-check "rich: the bare URL gets the link property"
                (get-text-property bare 'elneo-room-url)
                "https://bare.example/r")
      (mx-check "rich: the bare URL is link-faced"
                (get-text-property bare 'face) 'elneo-room-url-face)
      (mx-check "rich: the bare URL has the click keymap"
                (get-text-property bare 'keymap) elneo-room--url-keymap)
      (mx-check "rich: the pill span stays an anchor only"
                (list (get-text-property pill 'shr-url)
                      (get-text-property pill 'elneo-room-url))
                (list "https://matrix.to/#/@a:hs" nil))
      (mx-check "rich: an anchor displaying a URL is not re-linked"
                (get-text-property shown 'elneo-room-url) nil)
      (mx-check "rich: that anchor's shr-url survived"
                (get-text-property shown 'shr-url)
                "https://shown.example/p")))

  ;; End to end, the reported shape: two pills, text, one bare URL —
  ;; rendered through the real rich path (shr), the trailing URL ends
  ;; up clickable like its plain-body siblings.
  (when (fboundp 'libxml-parse-html-region)
    (with-temp-buffer
      (elneo-room--insert-rich-body
       (list :event-id "$r1"
             :formatted-body
             "<a href=\"https://matrix.to/#/@a:hs\">@a</a> and <b>bold</b> words final https://last.example/page"))
      (let* ((text (buffer-substring (point-min) (point-max)))
             (pill-ix (string-search "@a" text))
             (bare-ix (string-search "https://last.example/page" text)))
        (mx-check "rich end to end: the pill rode the anchor"
                  (get-text-property pill-ix 'shr-url text)
                  "https://matrix.to/#/@a:hs")
        (mx-check "rich end to end: the trailing URL carries the link"
                  (get-text-property bare-ix 'elneo-room-url text)
                  "https://last.example/page")
        (mx-check "rich end to end: it is link-faced"
                  (get-text-property bare-ix 'face text) 'elneo-room-url-face)
        (mx-check "rich end to end: url-at-point finds the new link"
                  (progn (goto-char (1+ bare-ix))
                         (elneo-room--url-at-point))
                  "https://last.example/page"))))

  ;; --- `w' copies, and stays typing in the draft ---

  (with-temp-buffer
    (insert (elneo-room--linkify-string
             "look at https://copy.example/go now"))
    (goto-char (1+ (string-match "copy" (buffer-string))))
    (let (killed)
      (cl-letf (((symbol-function 'kill-new)
                 (lambda (s &optional _) (setq killed s)))
                ((symbol-function 'elneo-room--input-beg-pos)
                 (lambda () 999999)))
        (setq elneo-room--backfilled t)
        (elneo-room--w))
      (mx-check "`w' kills the URL" killed "https://copy.example/go")))

  ;; In the draft area `w' self-inserts instead (defkey discipline).
  (with-temp-buffer
    (insert "draft")
    (goto-char (point-max))
    (let (selfed)
      (cl-letf (((symbol-function 'elneo-room--in-input-p) (lambda () t))
                ((symbol-function 'self-insert-command)
                 (lambda (_n _c) (setq selfed ?w))))
        (elneo-room--w))
      (mx-check "draft-area `w' self-inserts" selfed ?w)))

  ;; --- RET dispatch ---

  (with-temp-buffer
    (insert (elneo-room--linkify-string
             "open https://ret.example/this"))
    (goto-char (1+ (string-match "ret.example" (buffer-string))))
    (let ((browsed nil) (sent nil))
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (u &rest _) (setq browsed u)))
                ((symbol-function 'elneo-room-send)
                 (lambda () (setq sent t)))
                ((symbol-function 'elneo-room--input-beg-pos)
                 (lambda () 999999))
                (elneo-room--backfilled t))
        (elneo-room--ret))
      (mx-check "RET on a URL browses it" browsed "https://ret.example/this")
      (mx-check "RET on a URL does not prompt to send" sent nil)))

  (with-temp-buffer
    (insert "no links in this line")
    (goto-char (point-min))
    (let (sent)
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (_u &rest _) t))
                ((symbol-function 'elneo-room-send)
                 (lambda () (setq sent t)))
                ((symbol-function 'elneo-room--input-beg-pos)
                 (lambda () 999999))
                (elneo-room--backfilled t))
        (elneo-room--ret))
      (mx-check "RET off a link still sends the draft" sent t)))

  ;; --- m.location: the protocol-3 `geo' field becomes an OSM link ---
  ;; The tag is a URL span (mouse-1, `o'/`RET', `w') only when the
  ;; daemon shipped a geo URI; protocol-2 daemons render an inert tag.

  (mx-check "osm url parses a plain geo: URI"
            (elneo-room--osm-url "geo:52.5163,13.3777")
            "https://www.openstreetmap.org/?mlat=52.5163&mlon=13.3777#map=17/52.5163/13.3777")
  (mx-check "osm url drops trailing parameters"
            (elneo-room--osm-url "geo:52.5163,13.3777;u=30")
            "https://www.openstreetmap.org/?mlat=52.5163&mlon=13.3777#map=17/52.5163/13.3777")
  (mx-check "osm url: nil geo → nil" (elneo-room--osm-url nil) nil)
  (mx-check "osm url: unparsable geo → nil" (elneo-room--osm-url "geo:xyz") nil)

  (let ((buf (generate-new-buffer " *mx-url-room*")))
    (with-current-buffer buf
      (elneo-room-mode)
      (let ((elneo-room-avatars nil)
            (elneo-room--profile "mxtest"))
        (setq elneo-room--seen (make-hash-table :test 'equal))
        (insert "header\n")
        (goto-char (point-max))
        (elneo-room--append-messages
         (copy-tree
          `((:event-id "$l1" :sender "@a:hs" :sender-name "Ann" :ts 1700000000000
             :msgtype "m.location" :is-own nil :body "the bakery"
             :geo "geo:52.5163,13.3777")
            (:event-id "$l2" :sender "@a:hs" :sender-name "Ann" :ts 1700000060000
             :msgtype "m.location" :is-own nil :body "no coordinates here")))))
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-min))
            (let ((tag-beg (string-match "\\[location: the bakery\\]" (buffer-string))))
              (mx-check "location tag with caption rendered"
                        (and tag-beg t) t)
              (when tag-beg
                (mx-check "geo tag carries the OSM link"
                          (get-text-property (1+ tag-beg) 'elneo-room-url)
                          "https://www.openstreetmap.org/?mlat=52.5163&mlon=13.3777#map=17/52.5163/13.3777")
                (mx-check "geo tag is link-faced"
                          (get-text-property (1+ tag-beg) 'face) 'elneo-room-url-face)))
            (let ((plain-beg (string-match "\\[location: no coordinates here\\]"
                                           (buffer-string))))
              (when plain-beg
                (mx-check "geo-less tag stays inert"
                          (get-text-property (1+ plain-beg) 'elneo-room-url) nil)
                (mx-check "geo-less tag is dim, not link-faced"
                          (get-text-property (1+ plain-beg) 'face) 'shadow)))))
      (kill-buffer buf)))

  (message "results: %d passed, %d failed" pass fail)
  (when (> fail 0) (kill-emacs 1)))