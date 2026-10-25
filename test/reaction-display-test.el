;;; reaction-display-test.el --- reaction-line rendering -*- lexical-binding: t; -*-

;; Reactions used to render as one blind `%s %d' — a count ran into
;; the key text, and a sticker reaction showed its raw MXC URL.
;; Tests cover:
;;
;; - `elneo-room--image-reaction-key-p': keys on an MXC are image
;;   reactions, everything else is text.
;; - `elneo-room--reaction-entry-cell': text keys quote whitespace,
;;   every count renders as a separate `×N' set off from the key,
;;   and the face says who reacted.  Keys render inert — bidi
;;   controls strip out, a newline or carriage return shows as its
;;   symbol glyph, never as a physical line break.
;; - `elneo-room--X': the arbitrary-key react prompt sends the key
;;   verbatim — no filtering — and re-sending one of our own keys
;;   toggles it off.
;; - `elneo-room--reaction-image-cell': the sticker when it is
;;   displayable, the `[image react]' tag otherwise, both carrying
;;   the `elneo-room-reaction-image' marker the arrival pass keys on.
;; - `elneo-room--ensure-reaction-image': fetches a graphic-display
;;   miss exactly once (misses join the in-flight one), spends no
;;   download on plain text terminals, retry never, cache never.
;; - `elneo-room--reactions-arrived': lines whose sticker arrived
;;   redraw from the table, others keep the tag and arm their fetch,
;;   and no line redraws twice in a pass (a stale marker without a
;;   table entry draws nothing).
;;
;; Fetching and image creation go through stubs; nothing needs a
;; homeserver or a graphic frame.
;;
;; Run: emacs -Q --batch -L lisp -l test/reaction-display-test.el

(require 'cl-lib)
(require 'elneo-room)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defun mx-reset ()
    "Wipe the scratch buffer's read-only text between rounds."
    (let ((inhibit-read-only t)) (erase-buffer)))

  (defun mx-pad ()
    "The reaction line's leading padding, as a string."
    (make-string (elneo-room--body-column) ?\s))

  (defun mx-prop-pos (prop value)
    "First buffer position holding PROP equal VALUE, or nil.
`text-property-any' misses string values on some Emacs builds, so
scan the property's change positions directly."
    (save-excursion
      (goto-char (point-min))
      (catch 'found
        (while (< (point) (point-max))
          (when (equal (get-text-property (point) prop) value)
            (throw 'found (point)))
          (goto-char (or (next-single-property-change
                          (point) prop nil (point-max))
                         (point-max)))))))

  ;; The graphic-display stubs every rendering round below needs.
  (defmacro mx-with-display-stubs (&rest body)
    "Run BODY with a displayable sticker pipeline: a cache hit
converts and a `create-image' answers a fake image glyph."
    `(cl-letf (((symbol-function 'display-graphic-p) (lambda () t))
               ((symbol-function 'elneo--image-for-display)
                (lambda (path)
                  (if (string-prefix-p "/cache/" path)
                      "/t/conv.png" path)))
               ((symbol-function 'create-image)
                (lambda (&rest _) '(fake-image)))
               ((symbol-function 'default-font-height) (lambda () 24))
               ((symbol-function 'default-font-width) (lambda () 10)))
       ,@body))

  ;; ---- elneo-room--image-reaction-key-p.
  (mx-check "key-p: an mxc key is an image reaction"
            (elneo-room--image-reaction-key-p "mxc://hs/abc") t)
  (mx-check "key-p: text is not"
            (elneo-room--image-reaction-key-p "👍") nil)
  (mx-check "key-p: a non-string key is not"
            (elneo-room--image-reaction-key-p :unknown) nil)

  ;; ---- elneo-room--reaction-entry-cell, text keys.

  ;; A plain emoji: the key verbatim, no count at 1.
  (mx-check "cell: a count-1 emoji shows without a count"
            (elneo-room--reaction-entry-cell '(:key "👍"))
            (propertize "👍" 'face 'elneo-room-reaction))

  ;; The count is a separate `×N', never `%s %d' glued to the key.
  (mx-check "cell: the count renders as a separate xN"
            (elneo-room--reaction-entry-cell '(:key "👍" :count 2))
            (propertize "👍 ×2" 'face 'elneo-room-reaction))

  ;; A text react is quoted, so the quote and its count stay
  ;; distinct: "hier ein text react" ×2.
  (mx-check "cell: a whitespace key is quoted"
            (elneo-room--reaction-entry-cell '(:key "hier ein text react" :count 2))
            (propertize "\"hier ein text react\" ×2"
                        'face 'elneo-room-reaction))

  ;; An own reaction wears its own face.
  (mx-check "cell: own reactions wear the own face"
            (elneo-room--reaction-entry-cell '(:key "👍" :count 3 :own t))
            (propertize "👍 ×3" 'face 'elneo-room-reaction-own))

  ;; A key is an arbitrary string from any room member, so it
  ;; renders inert: quoted, and a line break shows as its symbol
  ;; glyph instead of starting a physical line.
  (mx-check "cell: a newline key renders as a symbol glyph"
            (elneo-room--reaction-entry-cell '(:key "first\nsecond" :count 1))
            (propertize "\"first␊second\"" 'face 'elneo-room-reaction))

  ;; Bidi controls exist to re-shape the text around them — a key
  ;; has nothing it may be trusted with (an override in the key
  ;; would scramble the count or the next cell's glyphs).
  (mx-check "cell: bidi controls strip out of the key"
            (elneo-room--reaction-entry-cell
             (list :key (concat "a" (string ?‮ ?⁦ ?‎) "b")))
            (propertize "ab" 'face 'elneo-room-reaction))

  (mx-check "cell: a carriage return shows as its symbol glyph"
            (elneo-room--reaction-entry-cell '(:key "a\rb" :count 1))
            (propertize "\"a␍b\"" 'face 'elneo-room-reaction))

  ;; Inertness is about the whole cell: no key smuggles a real line
  ;; break through, whatever else rides with it.
  (mx-check "cell: no key renders a physical newline"
            (substring-no-properties
             (elneo-room--reaction-entry-cell '(:key "l 1\n l2" :count 3)))
            "\"l 1␊ l2\" ×3")

  ;; ---- elneo-room--reaction-image-cell / entry, no arrival.

  ;; Without the sticker in the cache the cell is a tag, marked so
  ;; the arrival pass can find it.
  (cl-letf (((symbol-function 'elneo-client--reaction-file)
             (lambda (_mxc) nil)))
    (mx-check "cell: a missing sticker is a marked tag"
              (elneo-room--reaction-entry-cell '(:key "mxc://hs/doge" :count 1))
              (propertize "[image react]"
                          'face 'elneo-room-reaction
                          'elneo-room-reaction-image "mxc://hs/doge"))
    (mx-check "cell: the tag's count is still separate"
              (elneo-room--reaction-entry-cell '(:key "mxc://hs/doge" :count 2))
              (concat "[image react] "
                      (propertize "×2" 'face 'elneo-room-reaction))))

  ;; With a cache hit and a displayable conversion the cell is the
  ;; sticker glyph (a space carrying the display image): count 1
  ;; stays invisible behind the glyph, the count sits beside it, and
  ;; a cache hit needs no fetch at all.
  (cl-letf (((symbol-function 'elneo--image-for-display)
             (lambda (_file) "/t/conv.png"))
            ((symbol-function 'create-image) (lambda (&rest _) '(fake-image)))
            ((symbol-function 'default-font-height) (lambda () 24))
            ((symbol-function 'default-font-width) (lambda () 10))
            (elneo-client--reaction-cache
             (let ((h (make-hash-table :test 'equal)))
               (puthash "mxc://hs/doge" "/cache/doge.png" h)
               h))
            (mx-fetched nil))
    (cl-letf (((symbol-function 'elneo-client-fetch-reaction-image)
               (lambda (_profile mxc _cb) (push mxc mx-fetched))))
      (mx-check "cell: an arrived sticker renders as a glyph"
                (elneo-room--reaction-entry-cell '(:key "mxc://hs/doge" :count 1))
                (propertize " " 'display '(fake-image)
                            'elneo-room-reaction-image "mxc://hs/doge"))
      (mx-check "cell: a glyph's count sits in its own cell"
                (elneo-room--reaction-entry-cell '(:key "mxc://hs/doge" :count 3))
                (concat (propertize " " 'display '(fake-image)
                                    'elneo-room-reaction-image "mxc://hs/doge")
                        (propertize " ×3" 'face 'elneo-room-reaction)))
      (mx-check "cell: a cached sticker needs no fetch" mx-fetched nil)))

  ;; A cache file whose rescue fails (corrupt conversion) keeps the
  ;; tag instead of a nil image.
  (cl-letf (((symbol-function 'elneo-client--reaction-file)
             (lambda (_mxc) "/cache/doge.png"))
            ((symbol-function 'elneo--image-for-display)
             (lambda (_file) "/t/conv.png"))
            ((symbol-function 'create-image)
             (lambda (&rest _) (signal 'error '("corrupt")))))
    (mx-check "cell: a corrupt sticker degrades to the tag"
              (elneo-room--reaction-image-cell "mxc://hs/doge")
              (propertize "[image react]"
                          'face 'elneo-room-reaction
                          'elneo-room-reaction-image "mxc://hs/doge")))

  ;; ---- elneo-room--reaction-image-glyph / -annotation: the shared
  ;; sticker glyph, and the `a'-prompt annotation on top of it.

  ;; The glyph is nil without a cache file and under a corrupted
  ;; conversion; the annotation inherits that (a sticker without its
  ;; picture annotates with nothing; non-image keys never annotate).
  (cl-letf (((symbol-function 'elneo-client--reaction-file)
             (lambda (_mxc) nil)))
    (mx-check "glyph: no cache, no glyph"
              (elneo-room--reaction-image-glyph "mxc://hs/doge") nil)
    (mx-check "glyph: nil mxc, no glyph" (elneo-room--reaction-image-glyph nil) nil)
    (mx-check "annotation: a missing sticker annotates with nothing"
              (elneo-room--reaction-annotation "mxc://hs/doge") nil)
    (mx-check "annotation: an emoji annotates with nothing"
              (elneo-room--reaction-annotation "👍") nil)
    (mx-check "annotation: a text key annotates with nothing"
              (elneo-room--reaction-annotation "hier ein text react") nil))

  (cl-letf (((symbol-function 'elneo-client--reaction-file)
             (lambda (_mxc) "/cache/doge.png"))
            ((symbol-function 'elneo--image-for-display)
             (lambda (_file) "/t/conv.png"))
            ((symbol-function 'create-image)
             (lambda (&rest _) '(fake-image)))
            ((symbol-function 'default-font-height) (lambda () 24))
            ((symbol-function 'default-font-width) (lambda () 10)))
    (mx-check "annotation: a cached sticker annotates with its thumbnail"
              (elneo-room--reaction-annotation "mxc://hs/doge")
              (propertize " " 'display '(fake-image))))

  (cl-letf (((symbol-function 'elneo-client--reaction-file)
             (lambda (_mxc) "/cache/doge.png"))
            ((symbol-function 'elneo--image-for-display)
             (lambda (_file) "/t/conv.png"))
            ((symbol-function 'create-image)
             (lambda (&rest _) (signal 'error '("corrupt")))))
    (mx-check "annotation: a corrupt thumbnail annotates with nothing"
              (elneo-room--reaction-annotation "mxc://hs/doge") nil))

  ;; ---- elneo-room--ensure-reaction-image: fetch a graphic-display
  ;; miss exactly once, nothing on terminals and cache hits.

  (let ((mx-fetched nil)
        (buffer (get-buffer-create "mx-react")))
    (with-current-buffer buffer
      (mx-reset)
      (cl-letf (((symbol-function 'elneo-client-fetch-reaction-image)
                 ;; The real wrapper joins the in-flight one in
                 ;; `elneo-client-fetch-image': the stub mimics that,
                 ;; or a second call would just fetch again.
                 (lambda (profile mxc cb)
                   (push (cons profile mxc) mx-fetched)
                   (puthash mxc (list cb) elneo-client--reaction-pending))))
        (cl-letf (((symbol-function 'display-graphic-p) (lambda () t)))
          (elneo-room--ensure-reaction-image "mxc://hs/doge")
          (elneo-room--ensure-reaction-image "mxc://hs/doge")
          (mx-check "ensure: a miss fetches exactly once"
                    mx-fetched (list (cons elneo-room--profile "mxc://hs/doge"))))

        ;; A terminal spends no download.
        (clrhash elneo-client--reaction-pending)
        (setq mx-fetched nil)
        (cl-letf (((symbol-function 'display-graphic-p) (lambda () nil)))
          (elneo-room--ensure-reaction-image "mxc://hs/other")
          (mx-check "ensure: a terminal fetches nothing" mx-fetched nil))

        ;; A failed download is not retried.
        (clrhash elneo-client--reaction-pending)
        (puthash "mxc://hs/failed" 'failed elneo-client--reaction-cache)
        (cl-letf (((symbol-function 'display-graphic-p) (lambda () t)))
          (elneo-room--ensure-reaction-image "mxc://hs/failed")
          (mx-check "ensure: a failed fetch is not retried" mx-fetched nil))
        (remhash "mxc://hs/failed" elneo-client--reaction-cache)

        ;; An in-flight fetch is joined, not duplicated.
        (clrhash elneo-client--reaction-pending)
        (setq mx-fetched nil)
        (puthash "mxc://hs/doge" (list 'x) elneo-client--reaction-pending)
        (cl-letf (((symbol-function 'display-graphic-p) (lambda () t)))
          (elneo-room--ensure-reaction-image "mxc://hs/doge")
          (mx-check "ensure: an in-flight fetch is joined" mx-fetched nil))
        (remhash "mxc://hs/doge" elneo-client--reaction-pending)

        ;; A cached download does not fetch again.
        (puthash "mxc://hs/cached" "/cache/x" elneo-client--reaction-cache)
        (cl-letf (((symbol-function 'display-graphic-p) (lambda () t)))
          (elneo-room--ensure-reaction-image "mxc://hs/cached")
          (mx-check "ensure: a cache hit does not fetch" mx-fetched nil))
        (remhash "mxc://hs/cached" elneo-client--reaction-cache)
        (remhash "mxc://hs/doge" elneo-client--reaction-cache)))
    (kill-buffer buffer))

  ;; ---- elneo-room--reactions-arrived: whole lines redraw out of
  ;; the table.

  (let ((buffer (get-buffer-create "mx-react-arrive")))
    ;; A buffer-local reactions table: two lines, neither fetched
    ;; yet — they insert as tags and arm their fetches.
    (with-current-buffer buffer
      (mx-reset)
      (setq elneo-room--reactions
            (let ((h (make-hash-table :test 'equal)))
              (puthash "$ev1" '((:key "mxc://hs/doge" :count 1)) h)
              (puthash "$ev2" '((:key "mxc://hs/shrek" :count 2)) h)
              h))
        (mx-with-display-stubs
          (let ((fetched ""))
            (cl-letf (((symbol-function 'elneo-client-fetch-reaction-image)
                       ;; No arrival, no pending; redraws keep asking.
                       (lambda (_profile mxc _cb)
                         (setq fetched (concat fetched mxc)))))
              ;; Neither in the cache yet: both lines are tags, and
              ;; the tags' fetches arm straight away on a graphic
              ;; display.
              (elneo-room--insert-reaction-line
               "$ev1" 1200 '((:key "mxc://hs/doge" :count 1)))
              (elneo-room--insert-reaction-line
               "$ev2" 1300 '((:key "mxc://hs/shrek" :count 2)))
              (mx-check "arrive: missing stickers render as tags"
                        (substring-no-properties (buffer-string))
                        (concat (mx-pad) "‹ [image react]\n"
                                (mx-pad) "‹ [image react] ×2\n"))
              (mx-check "arrive: inserting tags armed both fetches"
                        (with-temp-buffer (insert fetched) (buffer-string))
                        "mxc://hs/dogemxc://hs/shrek")

              ;; Now the first sticker arrives; the second's download
              ;; is still in flight.
              (puthash "mxc://hs/doge" "/cache/doge.png"
                       elneo-client--reaction-cache)
              (elneo-room--reactions-arrived)
              (mx-check "arrive: the arrived line shows the glyph"
                        (substring-no-properties (buffer-string))
                        (concat (mx-pad) "‹  \n"
                                (mx-pad) "‹ [image react] ×2\n"))
              (let ((pos (mx-prop-pos 'elneo-room-reaction-image
                                     "mxc://hs/doge")))
                (mx-check "arrive: the glyph keeps its marker"
                          (not (null pos)) t)
                (mx-check "arrive: the redrawn line keeps its event id"
                          (get-text-property pos 'elneo-room-event-id) "$ev1")
                (mx-check "arrive: the redrawn line keeps its ts"
                          (get-text-property pos 'elneo-room-ts) 1200)
                (mx-check "arrive: the redrawn line keeps its reaction mark"
                          (get-text-property pos 'elneo-room-reaction-line) t))
              ;; The other line's sticker is missing and stays a tag.
              (let ((pos (mx-prop-pos 'elneo-room-reaction-image
                                     "mxc://hs/shrek")))
                (mx-check "arrive: a waiting line keeps its marked tag"
                          (not (null pos)) t)
                (mx-check "arrive: the waiting line stays that event's"
                          (get-text-property pos 'elneo-room-event-id) "$ev2"))

              ;; A settled pass changes nothing.
              (let ((before (buffer-string)))
                (elneo-room--reactions-arrived)
                (mx-check "arrive: a settled pass redraws nothing"
                          (buffer-string) before)))))

          ;; The doge cache entry outlives the check; the reaction
          ;; tables are shared with later buffers.
          (remhash "mxc://hs/doge" elneo-client--reaction-cache)

          ;; A buffer without cells scans harmless.
          (mx-reset)
          (insert "plain text, no reactions")
          (elneo-room--reactions-arrived)
          (mx-check "arrive: a buffer without cells scans harmless"
                    (substring-no-properties (buffer-string))
                    "plain text, no reactions")))

  ;; A stale marker whose event-id has no aggregate (the table was
  ;; re-initialized by a full refresh) redraws to nothing: the tag
  ;; survives the pass and no fetch arms for the dead event.
  (let ((buffer (get-buffer-create "mx-react-gone")))
    (with-current-buffer buffer
      (mx-reset)
      (setq elneo-room--reactions nil)
      (insert (propertize "[image react]"
                          'elneo-room-reaction-image "mxc://hs/x"
                          'elneo-room-event-id "$gone"
                          'elneo-room-reaction-line t))
      (let ((fetched nil))
        (cl-letf (((symbol-function 'elneo-client-fetch-reaction-image)
                   (lambda (_profile mxc _cb) (push mxc fetched))))
          ;; The tag's own marker property makes the pass look at it.
          (mx-with-display-stubs
            (elneo-room--reactions-arrived)
            (mx-check "arrive: a stale marker without a table entry survives"
                      (buffer-string) "[image react]")
            (mx-check "arrive: a stale marker arms no fetch" fetched nil)))))
    (kill-buffer buffer))

  ;; ---- elneo-room--X: the arbitrary-key react prompt sends the
  ;; key verbatim, toggles the ones we own, and drops the empty one.

  (let ((buffer (get-buffer-create "mx-react-x"))
        (sent nil))
    (with-current-buffer buffer
      (setq elneo-room--reactions
            (let ((h (make-hash-table :test 'equal)))
              (puthash "$ev" '((:key "👍" :count 2 :own t)) h)
              h)
            elneo-room--seen (make-hash-table :test 'equal))
      (cl-letf (((symbol-function 'elneo-room--event-id-at-point)
                 (lambda () "$ev"))
                ;; Over history, not the draft area: the defkey wraps
                ;; every prompt body in the in-input gate.
                ((symbol-function 'elneo-room--in-input-p)
                 (lambda () nil))
                ((symbol-function 'elneo-send-reaction)
                 (lambda (&rest args) (push args sent))))
        ;; A key with a bidi override, a tab and a newline: exactly
        ;; what was typed reaches the send, unfiltered.
        (cl-letf (((symbol-function 'read-string)
                   (lambda (&rest _)
                     (concat "shen" (string ?‮) "ani\tk\nline"))))
          (elneo-room--X))
        (let ((call (car sent)))
          (mx-check "X: the typed key is sent verbatim"
                    (nth 3 call)
                    (concat "shen" (string ?‮) "ani\tk\nline"))
          (mx-check "X: an unowned key does not toggle" (nth 5 call) nil)
          ;; The prompt seeded its history with our keys on the
          ;; message — the toggle-off recall.
          (mx-check "X: own keys lead the prompt history"
                    elneo-room--reaction-x-history '("👍")))
        (setq sent nil)
        ;; M-p recall of the own key: exact match toggles it off.
        (cl-letf (((symbol-function 'read-string)
                   (lambda (&rest _) "👍")))
          (elneo-room--X))
        (mx-check "X: re-sending an own key toggles it off"
                  (nth 5 (car sent)) '("👍"))
        (setq sent nil)
        (cl-letf (((symbol-function 'read-string)
                   (lambda (&rest _) "")))
          (elneo-room--X))
        (mx-check "X: an empty key sends nothing" sent nil)))
    (kill-buffer buffer))

  ;; The X prompt's minibuffer setup: C-j exits the minibuffer by
  ;; default, but must insert a newline character there.
  (with-temp-buffer
    (insert "ab")
    (elneo-room--x-minibuffer-setup)
    (mx-check "X prompt: C-j is rebound away from exit"
              (not (eq (lookup-key (current-local-map) "\C-j")
                       #'newline-and-exit))
              t)
    (cl-letf ((last-command-event ?\n))
      (call-interactively (lookup-key (current-local-map) "\C-j")))
    (mx-check "X prompt: the rebound C-j inserts a newline"
              (buffer-string) "ab\n"))

  (message "reaction-display-test: %d passed, %d failed" pass fail)
  (kill-emacs (if (= fail 0) 0 1)))