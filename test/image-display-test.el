;;; image-display-test.el --- undisplayable image fallbacks -*- lexical-binding: t; -*-

;; An image this Emacs cannot type used to vanish from the room
;; buffer: `create-image' answers nil (or errors) for a format the
;; build lacks — avif on most Emacsen — and the placeholder was
;; deleted before the nil insertion failed.  Tests cover:
;;
;; - `elneo--convert-argv': the exact decode invocation per backend.
;; - `elneo--image-for-display': the original passes through when
;;   displayable; the built-in `image-convert' answers first, with
;;   elneo's own backends behind it; a successful conversion is
;;   cached per source path, a failed one is not (a retry tries
;;   again); nothing converting answers nil without touching the
;;   source.
;; - `elneo-room--put-image': the placeholder is never deleted
;;   without a replacement — an undisplayable file degrades to a
;;   download-on-demand tag with the media properties intact and no
;;   `elneo-room-media-thumb', so the scanner does not refetch it.
;;   A placeholder's caption (`elneo-room-media-caption', the
;;   message body text) rides through the replacement on every path
;;   — image, degraded tag, video frame, fetch-failure marker — on
;;   its own line under the media, indented to the body column (a
;;   caption flowing right of a thumbnail is unreadable when
;;   narrow), linkified, still carrying the event id.
;; - `elneo-image--insert-file': the viewer names the file and
;;   points at `o' instead of inserting a nil image; either way the
;;   downloaded file stays current for `o'.
;; - `elneo-room--on-media-file': RET/o hand `elneo-open-file-function'
;;   a displayable file for image media (converted when needed),
;;   and the downloaded file untouched for anything else.
;;
;; Every tool call and image creation goes through stubs; no
;; external tool or graphic display is required.
;;
;; Run: emacs -Q --batch -L lisp -l test/image-display-test.el

(require 'cl-lib)
(require 'elneo-room)
(require 'elneo-image)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defun mx-err (label form)
    (condition-case data
        (progn (eval form t)
               (cl-incf fail)
               (message "FAIL: %s — no error" label))
      (error (cl-incf pass) (message "ok: %s (%s)" label data))))

  ;; ---- elneo--convert-argv: the exact decode invocations.
  (mx-check "argv: magick decodes in to out"
            (elneo--convert-argv 'magick "/d/in" "/t/out.png")
            '("magick" "/d/in" "/t/out.png"))
  (mx-check "argv: convert decodes in to out"
            (elneo--convert-argv 'convert "/d/in" "/t/out.png")
            '("convert" "/d/in" "/t/out.png"))
  (mx-check "argv: gm decodes in to out"
            (elneo--convert-argv 'gm "/d/in" "/t/out.png")
            '("gm" "convert" "/d/in" "/t/out.png"))
  (mx-check "argv: sips pins the output format"
            (elneo--convert-argv 'sips "/d/in" "/t/out.png")
            '("sips" "-s" "format" "png" "/d/in" "--out" "/t/out.png"))

  ;; ---- elneo--image-for-display.

  ;; A displayable original passes through untouched: no probe of
  ;; the backends, no tool run.
  (clrhash elneo--image-conversions)
  (cl-letf (((symbol-function 'create-image)
             (lambda (file &rest _)
               (when (equal file "/d/pic.png") '(fake-image))))
            ((symbol-function 'executable-find)
             (lambda (&rest _) (error "backend probe must not run"))))
    (mx-check "display: displayable original passes through"
              (elneo--image-for-display "/d/pic.png") "/d/pic.png"))

  ;; An undisplayable file nothing can convert answers nil.
  (clrhash elneo--image-conversions)
  (cl-letf (((symbol-function 'create-image) (lambda (&rest _) nil))
            ((symbol-function 'image-convert)
             (lambda (&rest _) (error "no converter")))
            ((symbol-function 'executable-find) (lambda (&rest _) nil))
            ((symbol-function 'make-temp-file)
             (lambda (&rest _) "/t/conv.png")))
    (mx-check "display: no converter anywhere, nil"
              (elneo--image-for-display "/d/x") nil)
    (mx-check "display: nil is not cached — the table stays empty"
              (hash-table-count elneo--image-conversions) 0))

  ;; The built-in `image-convert' answers first: its PNG data lands
  ;; in the temp file, and the conversion is cached like any other.
  (clrhash elneo--image-conversions)
  (let ((runs 0)
        (out (expand-file-name "elneo-mxconv.png" temporary-file-directory)))
    (cl-letf (((symbol-function 'create-image)
               ;; nil for the avif original, non-nil for the PNG copy
               (lambda (file &rest _)
                 (not (equal file "/d/x"))))
              ((symbol-function 'image-convert)
               (lambda (&rest _)
                 (setq runs (1+ runs))
                 "fake-png-data"))
              ((symbol-function 'make-temp-file)
               (lambda (&rest _) out)))
      (let ((got (elneo--image-for-display "/d/x")))
        (mx-check "display: built-in conversion returns the PNG copy"
                  got out)
        (mx-check "display: the built-in data landed in the copy"
                  (with-temp-buffer
                    (insert-file-contents-literally out)
                    (buffer-string))
                  "fake-png-data")
        (mx-check "display: the built-in ran once" runs 1)
        (mx-check "display: the built-in conversion is cached"
                  (elneo--image-for-display "/d/x") out)
        (mx-check "display: the cache does not re-run the tool" runs 1)
        (delete-file out))))

  ;; A built-in that yields nothing falls through to elneo's own
  ;; backends, which cover sips and ImageMagick 7 — and the rescue
  ;; is cached: the second call runs no tool at all.
  (clrhash elneo--image-conversions)
  (let ((runs 0) (n 0))
    (cl-letf (((symbol-function 'create-image)
               ;; nil for the avif original, non-nil for the PNG copy
               (lambda (file &rest _)
                 (not (equal file "/d/x"))))
              ((symbol-function 'image-convert)
               (lambda (&rest _) (error "builtin cannot")))
              ((symbol-function 'elneo--scale-backend) (lambda () 'sips))
              ((symbol-function 'make-temp-file)
               (lambda (&rest _) (format "/t/conv-%d.png" (cl-incf n))))
              ((symbol-function 'elneo--scale-run)
               (lambda (_argv) (setq runs (1+ runs)) t)))
      (let ((got (elneo--image-for-display "/d/x")))
        (mx-check "display: backend rescue returns the converted copy"
                  got "/t/conv-1.png")
        (mx-check "display: the rescue ran the tool once" runs 1)
        (mx-check "display: the rescue is cached"
                  (elneo--image-for-display "/d/x") "/t/conv-1.png")
        (mx-check "display: the cache does not re-run the tool" runs 1))))

  ;; A failed conversion answers nil and is not cached — the retry
  ;; runs the tool again (a backend installed mid-session gets its
  ;; shot).
  (clrhash elneo--image-conversions)
  (let ((runs 0))
    (cl-letf (((symbol-function 'create-image) (lambda (&rest _) nil))
              ((symbol-function 'image-convert)
               (lambda (&rest _) (error "builtin cannot")))
              ((symbol-function 'elneo--scale-backend) (lambda () 'gm))
              ((symbol-function 'make-temp-file)
               (lambda (&rest _) "/t/conv.png"))
              ((symbol-function 'elneo--scale-run)
               (lambda (_argv) (setq runs (1+ runs)) nil))
              ((symbol-function 'file-exists-p) (lambda (&rest _) nil)))
      (mx-check "display: failed conversion answers nil"
                (elneo--image-for-display "/d/x") nil)
      (mx-check "display: failure is not cached — the retry runs again"
                (progn (elneo--image-for-display "/d/x") runs) 2)))

  ;; A create-image error on the original counts as undisplayable,
  ;; not a signal.
  (clrhash elneo--image-conversions)
  (cl-letf (((symbol-function 'create-image)
             (lambda (file &rest _)
               (if (equal file "/d/x")
                   (signal 'file-error '("gone"))
                 '(fake-image))))
            ((symbol-function 'image-convert)
             (lambda (&rest _) (error "builtin cannot")))
            ((symbol-function 'executable-find) (lambda (&rest _) nil))
            ((symbol-function 'make-temp-file)
             (lambda (&rest _) "/t/conv.png")))
    (mx-check "display: a probing error is undisplayable, not a signal"
              (elneo--image-for-display "/d/x") nil))

  ;; ---- elneo-room--put-image: a placeholder is never deleted
  ;; without a replacement.
  (defvar mx-beg)
  (defvar mx-end)
  (defun mx-placeholder (media-data name &optional caption)
    "Insert a placeholder at point and record its bounds."
    (insert "before ")
    (setq mx-beg (point))
    (insert (propertize (format "[image: %s]" name)
                        'elneo-room-media-thumb t
                        'elneo-room-media-data media-data
                        'elneo-room-media-name name
                        'elneo-room-media-caption caption
                        'elneo-room-event-id "$ev"))
    (setq mx-end (point))
    (insert " after"))

  (defun mx-reset ()
    "Clear the scratch buffer for the next placeholder round.
A video's play prefix is deliberately read-only, so plain
`erase-buffer' would signal between rounds."
    (let ((inhibit-read-only t))
      (erase-buffer)))

  (let ((buffer (get-buffer-create "mx-put")))
    (with-current-buffer buffer
      (mx-reset)
      (mx-placeholder '((mimetype . "image/webp")) "1000005232.webp")
      (cl-letf (((symbol-function 'elneo--image-for-display)
                 (lambda (_path) nil)))
        (elneo-room--put-image mx-beg mx-end "/cache/avif" "$ev"))
      (mx-check "put-image: undisplayable degrades to a tag"
                (buffer-string) "before [image: 1000005232.webp] after")
      (let ((pos (text-property-any (point-min) (point-max)
                                    'elneo-room-media t)))
        (mx-check "put-image: the tag keeps media properties"
                  (not (null pos)) t)
        (mx-check "put-image: the tag carries the event id"
                  (get-text-property pos 'elneo-room-event-id) "$ev")
        (mx-check "put-image: the tag keeps the media data"
                  (get-text-property pos 'elneo-room-media-data)
                  '((mimetype . "image/webp")))
        (mx-check "put-image: the tag keeps the media name"
                  (get-text-property pos 'elneo-room-media-name)
                  "1000005232.webp"))
      (mx-check "put-image: no thumb property — no refetch loop"
                (text-property-any (point-min) (point-max)
                                   'elneo-room-media-thumb t)
                nil))

    ;; Same shape for video media.
    (with-current-buffer buffer
      (mx-reset)
      (mx-placeholder '((mimetype . "video/mp4")) "clip.mp4")
      (cl-letf (((symbol-function 'elneo--image-for-display)
                 (lambda (_path) nil)))
        (elneo-room--put-image mx-beg mx-end "/cache/thumb" "$ev"))
      (mx-check "put-image: undisplayable video names its kind"
                (buffer-string) "before [video: clip.mp4] after"))

    ;; No media data at all — the bare tag.
    (with-current-buffer buffer
      (mx-reset)
      (insert "before ")
      (setq mx-beg (point))
      (insert (propertize "[image]" 'elneo-room-media-thumb t))
      (setq mx-end (point))
      (insert " after")
      (cl-letf (((symbol-function 'elneo--image-for-display)
                 (lambda (_path) nil)))
        (elneo-room--put-image mx-beg mx-end "/cache/x" "$ev"))
      (mx-check "put-image: no media data degrades to the bare tag"
                (buffer-string) "before [image] after"))

    ;; A file the helper rescues but create-image still chokes on
    ;; (corrupt copy) degrades too — the caller's error handler
    ;; never faces a deleted placeholder.  The stub signals a plain
    ;; error: `image-error' is not an Emacs condition, and a signal
    ;; with an undefined symbol escapes every handler on Emacs 30.
    (with-current-buffer buffer
      (mx-reset)
      (mx-placeholder '((mimetype . "image/webp")) "x.png")
      (cl-letf (((symbol-function 'elneo--image-for-display)
                 (lambda (_path) "/cache/png"))
                ((symbol-function 'create-image)
                 (lambda (&rest _) (signal 'error '("corrupt")))))
        (elneo-room--put-image mx-beg mx-end "/cache/png" "$ev"))
      (mx-check "put-image: a corrupt rescue degrades to the tag"
                (buffer-string) "before [image: x.png] after"))

    ;; The success path still replaces the placeholder with the
    ;; image alt text and a trailing space.
    (with-current-buffer buffer
      (mx-reset)
      (mx-placeholder '((mimetype . "image/webp")) "x.png")
      (cl-letf (((symbol-function 'elneo--image-for-display)
                 (lambda (_path) "/cache/png"))
                ((symbol-function 'create-image)
                 (lambda (&rest _args) '(fake-image)))
                ((symbol-function 'insert-image)
                 (lambda (_img string &rest _props)
                   (insert string))))
        (elneo-room--put-image mx-beg mx-end "/cache/png" "$ev"))
      (mx-check "put-image: a displayable image replaces the placeholder"
                (buffer-string) "before [image]  after"))

    ;; Video success keeps the play prefix.
    (with-current-buffer buffer
      (mx-reset)
      (mx-placeholder '((mimetype . "video/mp4")) "clip.mp4")
      (cl-letf (((symbol-function 'elneo--image-for-display)
                 (lambda (_path) "/cache/png"))
                ((symbol-function 'create-image)
                 (lambda (&rest _args) '(fake-image)))
                ((symbol-function 'insert-image)
                 (lambda (_img string &rest _props)
                   (insert string))))
        (elneo-room--put-image mx-beg mx-end "/cache/png" "$ev"))
      (mx-check "put-image: a displayable video keeps the play prefix"
                (buffer-string) "before ▶ [video]  after"))

    ;; A caption (the message's body text) rides through the
    ;; replacement — the placeholder text dies in the delete, the
    ;; caption must not die with it.
    (with-current-buffer buffer
      (mx-reset)
      (mx-placeholder '((mimetype . "image/webp")) "x.png"
                       "look at this https://example.com/cat")
      (cl-letf (((symbol-function 'elneo--image-for-display)
                 (lambda (_path) "/cache/png"))
                ((symbol-function 'create-image)
                 (lambda (&rest _args) '(fake-image)))
                ((symbol-function 'insert-image)
                 (lambda (_img string &rest _props) (insert string))))
        (elneo-room--put-image mx-beg mx-end "/cache/png" "$ev"))
      (mx-check "put-image: the caption survives the replacement"
                (buffer-string)
                (concat "before [image] \n"
                        (make-string (elneo-room--body-column) ?\s)
                        "look at this https://example.com/cat after"))
      ;; text-property-any compares with eq, and the URL property's
      ;; value is a string — locate the URL's buffer position by text
      ;; and read the properties there.
      (let ((pos (save-excursion
                   (goto-char (point-min))
                   (and (search-forward "https://example.com/cat"
                                        (point-max) t)
                        (- (point) (length "https://example.com/cat"))))))
        (mx-check "put-image: the caption linkifies"
                  (and pos
                       (equal (get-text-property pos 'elneo-room-url)
                              "https://example.com/cat"))
                  t)
        (mx-check "put-image: the caption carries the event id"
                  (and pos (get-text-property pos 'elneo-room-event-id))
                  "$ev")
        ;; The caption line belongs to the message block: block-bounds
        ;; must reach past it, or a re-render orphans the line under
        ;; the fresh render.
        (mx-check "put-image: the caption line belongs to the block"
                  (let ((bounds (elneo-room--block-bounds "$ev")))
                    (and bounds
                         (>= (cdr bounds)
                             (save-excursion
                               (goto-char (point-min))
                               (search-forward "https://example.com/cat")
                               (point)))))
                  t)))

    ;; The degraded tag keeps the caption too — the tag names the
    ;; file, the caption follows it.
    (with-current-buffer buffer
      (mx-reset)
      (mx-placeholder '((mimetype . "image/webp")) "x.png" "a caption")
      (cl-letf (((symbol-function 'elneo--image-for-display)
                 (lambda (_path) nil)))
        (elneo-room--put-image mx-beg mx-end "/cache/avif" "$ev"))
      (mx-check "put-image: the caption survives the undisplayable tag"
                (buffer-string)
                (concat "before [image: x.png]\n"
                        (make-string (elneo-room--body-column) ?\s)
                        "a caption after")))

    ;; A video's caption follows the fetched frame.
    (with-current-buffer buffer
      (mx-reset)
      (mx-placeholder '((mimetype . "video/mp4")) "clip.mp4" "a caption")
      (cl-letf (((symbol-function 'elneo--image-for-display)
                 (lambda (_path) "/cache/png"))
                ((symbol-function 'create-image)
                 (lambda (&rest _args) '(fake-image)))
                ((symbol-function 'insert-image)
                 (lambda (_img string &rest _props) (insert string))))
        (elneo-room--put-image mx-beg mx-end "/cache/png" "$ev"))
      (mx-check "put-image: a video's caption follows the frame"
                (buffer-string)
                (concat "before ▶ [video] \n"
                        (make-string (elneo-room--body-column) ?\s)
                        "a caption after")))

    ;; The fetch-failure marker keeps the caption as well.
    (with-current-buffer buffer
      (mx-reset)
      (mx-placeholder '((mimetype . "image/webp")) "x.png" "a caption")
      (elneo-room--on-media buffer "$ev" '((error . "404")))
      (mx-check "on-media: a failed fetch keeps the caption"
                (buffer-string)
                (concat "before [image unavailable]\n"
                        (make-string (elneo-room--body-column) ?\s)
                        "a caption after"))
      ;; The failure marker carries the event id, so the block (marker
      ;; plus caption line) stays findable for a re-render.
      (mx-check "on-media: a failed marker keeps the block findable"
                (let ((bounds (elneo-room--block-bounds "$ev")))
                  (and bounds
                       (>= (cdr bounds)
                           (save-excursion
                             (goto-char (point-min))
                             (search-forward "a caption")
                             (point)))))
                t))
    (kill-buffer buffer))

  ;; ---- elneo-image--insert-file: the viewer names the file and
  ;; points at `o' instead of inserting a nil image; either way the
  ;; downloaded file stays current for `o'.
  (let ((buffer (get-buffer-create "mx-viewer")))
    (with-current-buffer buffer
      (cl-letf (((symbol-function 'elneo--image-for-display)
                 (lambda (_path) nil))
                ((symbol-function 'elneo-image--current-msg) (lambda () nil))
                ((symbol-function 'elneo-image--update-modeline)
                 (lambda () nil)))
        (elneo-image--insert-file "/cache/avif")
        (mx-check "viewer: names the file and points at o"
                  (buffer-string)
                  "[this Emacs cannot display image — o opens it externally]")
        (mx-check "viewer: the undisplayable download stays current for o"
                  elneo-image--file "/cache/avif")))

    ;; A rescue converts for display but keeps the original current
    ;; — `o' opens the file as received, not the conversion.
    (with-current-buffer buffer
      (cl-letf (((symbol-function 'elneo--image-for-display)
                 (lambda (_path) "/t/conv.png"))
                ((symbol-function 'create-image)
                 (lambda (&rest _args) '(fake-image)))
                ((symbol-function 'insert-image)
                 (lambda (_img string &rest _props) (insert string)))
                ((symbol-function 'elneo-image--current-msg) (lambda () nil))
                ((symbol-function 'elneo-image--update-modeline)
                 (lambda () nil)))
        (elneo-image--insert-file "/cache/avif")
        (mx-check "viewer: a rescue displays the converted copy"
                  (buffer-string) "image\n")
        (mx-check "viewer: o still opens the original file"
                  elneo-image--file "/cache/avif")))
    (kill-buffer buffer))

  ;; ---- elneo-room--on-media-file: RET/o open a picture as a file
  ;; this Emacs can display.  Without the conversion the daemon's
  ;; .webp cache file (avif bytes inside) would land in
  ;; `image-mode' as raw text.
  (let ((opened nil)
        (buffer (get-buffer-create "mx-open")))
    (cl-letf ((elneo-open-file-function
               (lambda (path) (push path opened))))
      (let ((event '((@ok . t) (path . "/cache/1000005232.webp"))))
        ;; An image mimetype routes through the rescue.
        (cl-letf (((symbol-function 'elneo--image-for-display)
                   (lambda (path)
                     (if (equal path "/cache/1000005232.webp")
                         "/t/conv.png" path))))
          (elneo-room--on-media-file buffer "1000005232.webp" event
                                     '((mimetype . "image/webp")))
          (mx-check "open: an image opens the displayable copy"
                    (car opened) "/t/conv.png"))
        ;; A file nothing rescues keeps the original path — an
        ;; externally configured open function may still show it.
        (cl-letf (((symbol-function 'elneo--image-for-display)
                   (lambda (_path) nil)))
          (elneo-room--on-media-file buffer "1000005232.webp" event
                                     '((mimetype . "image/webp")))
          (mx-check "open: an unrescued image keeps the original file"
                    (car opened) "/cache/1000005232.webp"))
        ;; A non-image passes the downloaded file through untouched —
        ;; no probe, no conversion attempt on a video or document.
        (cl-letf (((symbol-function 'elneo--image-for-display)
                   (lambda (_path) (error "probe must not run"))))
          (elneo-room--on-media-file buffer "clip.mp4" event
                                     '((mimetype . "video/mp4")))
          (mx-check "open: a video opens as downloaded"
                    (car opened) "/cache/1000005232.webp"))
        ;; A failed download reports and opens nothing.
        (elneo-room--on-media-file buffer "gone.png" '((@ok . nil))
                                    '((mimetype . "image/png")))
        (mx-check "open: a failed download opens nothing"
                  (length opened) 3)))
    (kill-buffer buffer))

  (message "image-display-test: %d passed, %d failed" pass fail)
  (kill-emacs (if (= fail 0) 0 1)))