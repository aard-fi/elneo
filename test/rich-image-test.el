;;; rich-image-test.el --- rich-body inline images (the emote path) -*- lexical-binding: t; -*-

;; Custom emotes and stickers arrive as `<img>' tags inside a
;; formatted body.  The gate is `elneo-room-load-embedded-images'
;; (default nil, `Y' toggles it per room); with it on, the
;; placeholder carries the pipeline properties and the tag's
;; height attribute, and the fetched image does not render inline
;; but on its own line under the message: the caption-line block
;; rule below the last body line, whole-block properties only when
;; it lands mid-block (an event id there would hijack
;; `find-event').  Sibling images keep sentence order despite
;; out-of-order fetches.
;;
;; Every image creation goes through stubs; the DOM checks run
;; only when batch Emacs has libxml.
;;
;; Run: emacs -Q --batch -L lisp -l test/rich-image-test.el

(require 'cl-lib)
(require 'elneo-room)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defmacro mx-with-display-stubs (&rest body)
    "Run BODY with a displayable pipeline and a 24px font."
    `(cl-letf (((symbol-function 'elneo--image-for-display)
                (lambda (path) path))
               ((symbol-function 'create-image)
                (lambda (&rest _) '(fake-image)))
               ((symbol-function 'insert-image)
                (lambda (_img string &rest _props) (insert string)))
               ((symbol-function 'default-font-height) (lambda () 24))
               ((symbol-function 'default-font-width) (lambda () 10)))
       ,@body))

  (defmacro mx-with-dom (&rest body)
    "Run BODY only when this Emacs can parse HTML."
    `(when (fboundp 'libxml-parse-html-region)
       ,@body))

  (defun mx-dom (html)
    "The parsed-and-rewritten DOM of HTML: (NODE . SRCS)."
    (let ((dom (with-temp-buffer
                 (insert html)
                 (libxml-parse-html-region (point-min) (point-max)))))
      (elneo-room--rich-node
       (if (stringp dom) (list 'top nil dom) dom) nil)))

  ;; ---- the size policy: the tag's height, capped.
  (mx-with-display-stubs
   (mx-check "height: no attribute, two text lines"
             (elneo-room--rich-image-height nil) 48)
   (mx-check "height: a declared height is honored"
             (elneo-room--rich-image-height 32) 32)
   (mx-check "height: the cap is four text lines"
             (elneo-room--rich-image-height 100) 96))

  ;; ---- the DOM rewrite keeps src and height.
  (mx-with-dom
   (mx-check "dom: an img keeps src and height"
             (cdr (mx-dom "x <img src=\"mxc://hs/a\" height=\"32\"> y"))
             '(((src . "mxc://hs/a") (height . 32))))
   (mx-check "dom: a missing height answers nil"
             (cdr (mx-dom "x <img src=\"mxc://hs/a\"> y"))
             '(((src . "mxc://hs/a") (height . nil))))
   (mx-check "dom: a zero height answers nil"
             (cdr (mx-dom "x <img src=\"mxc://hs/a\" height=\"0\"> y"))
             '(((src . "mxc://hs/a") (height . nil)))))

  ;; ---- the placeholder: the pipeline properties and the gate.
  (defvar mx-img-pos)
  (mx-with-dom
   (let ((buf (get-buffer-create "mx-rich")))
     (unwind-protect
         (with-current-buffer buf
           (mx-with-display-stubs
            (erase-buffer)
            (let ((elneo-room-load-embedded-images t))
              (elneo-room--insert-rich-body
               (list :event-id "$r1"
                     :formatted-body
                     "haha <img data-mx-emoticon=\"\" src=\"mxc://hs/e\" alt=\"haha\" height=\"32\">")))
            (goto-char (point-min))
            (search-forward "[image]")
            (setq mx-img-pos (match-beginning 0))
            (mx-check "placeholder: fetches on scroll"
                      (get-text-property mx-img-pos 'elneo-room-media-thumb) t)
            (mx-check "placeholder: routes to the rich path"
                      (get-text-property mx-img-pos 'elneo-room-media-rich) t)
            (mx-check "placeholder: knows the base id"
                      (get-text-property mx-img-pos 'elneo-room-media-base-id)
                      "$r1")
            (mx-check "placeholder: knows its sentence index"
                      (get-text-property mx-img-pos 'elneo-room-media-index) 1)
            (mx-check "placeholder: the height is the tag's, capped"
                      (get-text-property mx-img-pos 'elneo-room-media-height) 32)
            (mx-check "placeholder: synthetic id keys the fetch"
                      (get-text-property mx-img-pos 'elneo-room-event-id)
                      "$r1#img1")
            (mx-check "placeholder: the mxc is the media source"
                      (get-text-property mx-img-pos 'elneo-room-media-data)
                      '((source (url . "mxc://hs/e"))))
            ;; The gate off, or an http source: a dim marker, never
            ;; fetched.
            (erase-buffer)
            (let ((elneo-room-load-embedded-images nil))
              (elneo-room--insert-rich-body
               (list :event-id "$r2" :formatted-body
                     "no <img src=\"mxc://hs/e\"> fetch")))
            (mx-check "gate: off renders a bare marker"
                      (text-property-any (point-min) (point-max)
                                         'elneo-room-media-thumb t)
                      nil)
            (erase-buffer)
            (let ((elneo-room-load-embedded-images t))
              (elneo-room--insert-rich-body
               (list :event-id "$r3" :formatted-body
                     "no <img src=\"https://web/e.png\"> fetch")))
            (mx-check "gate: an http source is never fetched"
                      (text-property-any (point-min) (point-max)
                                         'elneo-room-media-thumb t)
                      nil)))
       (kill-buffer buf))))

  ;; ---- the rendered image: under the line, in the block.

  ;; A full placeholder for the rounds below: the span in a
  ;; finished-paragraph line.
  (defun mx-rich-span (line-prefix line-suffix event-id index)
    "Insert LINE-PREFIX, a rich placeholder, LINE-SUFFIX on one line.
The text carries the event id and block marks of a rendered body
line; the span records its bounds in `mx-beg'/`mx-end'."
    (insert (propertize line-prefix
                        'elneo-room-event-id event-id
                        'elneo-room-msg-block event-id))
    (setq mx-beg (point))
    (insert (propertize "[image]"
                        'elneo-room-media-thumb t
                        'elneo-room-media-rich t
                        'elneo-room-media-data '((source (url . "mxc://hs/e")))
                        'elneo-room-media-name "e1ec965.png"
                        'elneo-room-media-base-id event-id
                        'elneo-room-media-index index
                        'elneo-room-media-height 32
                        'elneo-room-event-id
                        (concat event-id "#img" (number-to-string index))))
    (setq mx-end (point))
    (insert (propertize (concat line-suffix "\n")
                        'elneo-room-event-id event-id
                        'elneo-room-msg-block event-id)))

  (defvar mx-beg)
  (defvar mx-end)
  (defvar mx-beg2)
  (defvar mx-end2)

  ;; Below-block: the placeholder sat on the message's last line,
  ;; the image line lands under it with the base id.
  (let ((buf (get-buffer-create "mx-rich-put")))
    (unwind-protect
        (with-current-buffer buf
          (mx-with-display-stubs
           (erase-buffer)
           (mx-rich-span "head " "tail" "$r1" 1)
           (elneo-room--put-rich-image mx-beg mx-end "/cache/emote.png")
           (mx-check "put: the sentence closes up, the image goes under it"
                     (buffer-substring-no-properties (point-min) (point-max))
                     (concat "head tail\n"
                             (make-string (elneo-room--body-column) ?\s)
                             "[image]\n"))
           (goto-char (point-min))
           (search-forward "[image]")
           (mx-check "put: the image line joins the id run"
                     (get-text-property (match-beginning 0)
                                        'elneo-room-event-id)
                     "$r1")
           (mx-check "put: the image line is whole-block"
                     (get-text-property (match-beginning 0)
                                        'elneo-room-msg-block)
                     "$r1")
           (mx-check "put: the image line is marked as one"
                     (get-text-property (match-beginning 0)
                                        'elneo-room-rich-image)
                     t)
           (mx-check "put: the media stays openable"
                     (get-text-property (match-beginning 0)
                                        'elneo-room-media-index)
                     1)
           (mx-check "put: no thumb — no refetch loop"
                     (text-property-any (point-min) (point-max)
                                       'elneo-room-media-thumb t)
                     nil)
           (mx-check "put: find-event still lands on the body line"
                     (elneo-room--find-event "$r1") 1)
           (mx-check "put: block-bounds covers the image line"
                     (let ((bounds (elneo-room--block-bounds "$r1")))
                       (and bounds
                            (>= (cdr bounds)
                                (save-excursion
                                  (goto-char (point-min))
                                  (search-forward "[image]")
                                  (point)))))
                     t)))
      (kill-buffer buf)))

  ;; Mid-block: the placeholder sat on an earlier line of a
  ;; wrapped rich body — no event id on the image line, or
  ;; find-event would stop one line short.
  (let ((buf (get-buffer-create "mx-rich-mid")))
    (unwind-protect
        (with-current-buffer buf
          (mx-with-display-stubs
           (erase-buffer)
           (insert (propertize "alpha " 'elneo-room-msg-block "$r1"
                               'elneo-room-rich-block "$r1"))
           (setq mx-beg (point))
           (insert (propertize "[image]"
                               'elneo-room-media-thumb t
                               'elneo-room-media-rich t
                               'elneo-room-media-base-id "$r1"
                               'elneo-room-media-index 1
                               'elneo-room-media-height 32
                               'elneo-room-event-id "$r1#img1"))
           (setq mx-end (point))
           (insert (propertize "beta\n" 'elneo-room-msg-block "$r1"
                               'elneo-room-rich-block "$r1"))
           (insert (propertize "gamma\n" 'elneo-room-msg-block "$r1"
                               'elneo-room-rich-block "$r1"
                               'elneo-room-event-id "$r1"))
           (elneo-room--put-rich-image mx-beg mx-end "/cache/emote.png")
           (goto-char (point-min))
           (search-forward "[image]")
           (mx-check "mid: no event id — find-event stays honest"
                     (get-text-property (match-beginning 0)
                                        'elneo-room-event-id)
                     nil)
           (mx-check "mid: the image line is whole-block"
                     (get-text-property (match-beginning 0)
                                        'elneo-room-msg-block)
                     "$r1")
           (mx-check "mid: find-event lands on the last body line"
                     (elneo-room--find-event "$r1")
                     (save-excursion
                       (goto-char (point-min))
                       (search-forward "gamma")
                       (match-beginning 0)))
           (let ((bounds (elneo-room--block-bounds "$r1")))
             (mx-check "mid: the block spans the whole body"
                       (and bounds (= (car bounds) (point-min))
                            (= (cdr bounds) (point-max)))
                       t)
             (let ((inhibit-read-only t))
               (delete-region (car bounds) (cdr bounds)))
             (mx-check "mid: a re-render deletes the image line with the block"
                       (buffer-string) ""))))
      (kill-buffer buf)))

  ;; Siblings: two emotes, the second fetch lands first — the
  ;; lines still read in sentence order.
  (let ((buf (get-buffer-create "mx-rich-sib")))
    (unwind-protect
        (with-current-buffer buf
          (mx-with-display-stubs
           (erase-buffer)
           (mx-rich-span "head " " mid " "$r1" 1)
           (setq mx-end2 mx-end)
           (setq mx-beg2 mx-beg)
           (mx-rich-span "" "tail" "$r1" 2)
           ;; The second image lands first.
           (elneo-room--put-rich-image mx-beg mx-end "/cache/emote2.png")
           (elneo-room--put-rich-image mx-beg2 mx-end2 "/cache/emote1.png")
           (goto-char (point-min))
           (search-forward "[image]")
           (mx-check "siblings: the first image line is sentence-first"
                     (get-text-property (match-beginning 0)
                                        'elneo-room-media-index)
                     1)
           (search-forward "[image]")
           (mx-check "siblings: the second image line follows"
                     (get-text-property (match-beginning 0)
                                        'elneo-room-media-index)
                     2)))
      (kill-buffer buf)))

  ;; Siblings on an earlier line of a wrapped body, out of order:
  ;; the img that follows in the sentence probes past its sibling's
  ;; already-landed line for the block — its line must not steal
  ;; the block id find-event keys on.
  (let ((buf (get-buffer-create "mx-rich-sib-mid")))
    (unwind-protect
        (with-current-buffer buf
          (mx-with-display-stubs
           (erase-buffer)
           (insert (propertize "head " 'elneo-room-msg-block "$r1"
                               'elneo-room-rich-block "$r1"))
           (setq mx-beg (point))
           (insert (propertize "[image]"
                               'elneo-room-media-thumb t
                               'elneo-room-media-rich t
                               'elneo-room-media-base-id "$r1"
                               'elneo-room-media-index 1
                               'elneo-room-media-height 32
                               'elneo-room-event-id "$r1#img1"))
           (setq mx-end (point))
           (setq mx-beg2 mx-end)
           (insert (propertize "[image]"
                               'elneo-room-media-thumb t
                               'elneo-room-media-rich t
                               'elneo-room-media-base-id "$r1"
                               'elneo-room-media-index 2
                               'elneo-room-media-height 32
                               'elneo-room-event-id "$r1#img2"))
           (setq mx-end2 (point))
           (insert (propertize " tail\n" 'elneo-room-msg-block "$r1"
                               'elneo-room-rich-block "$r1"))
           (insert (propertize "gamma\n" 'elneo-room-msg-block "$r1"
                               'elneo-room-rich-block "$r1"
                               'elneo-room-event-id "$r1"))
           ;; The second image lands first.
           (elneo-room--put-rich-image mx-beg2 mx-end2 "/cache/emote2.png")
           (elneo-room--put-rich-image mx-beg mx-end "/cache/emote1.png")
           (goto-char (point-min))
           (search-forward "[image]")
           (mx-check "wrapped siblings: the lines read in sentence order"
                     (get-text-property (match-beginning 0)
                                        'elneo-room-media-index)
                     1)
           (mx-check "wrapped siblings: no event id on a sibling line"
                     (get-text-property (match-beginning 0)
                                        'elneo-room-event-id)
                     nil)
           (search-forward "[image]")
           (mx-check "wrapped siblings: none on the second line either"
                     (get-text-property (match-beginning 0)
                                        'elneo-room-event-id)
                     nil)
           (mx-check "wrapped siblings: find-event lands on the body line"
                     (elneo-room--find-event "$r1")
                     (save-excursion
                       (goto-char (point-min))
                       (search-forward "gamma")
                       (match-beginning 0)))
           (let ((bounds (elneo-room--block-bounds "$r1")))
             (mx-check "wrapped siblings: the block spans every line"
                       (and bounds (= (car bounds) (point-min))
                            (= (cdr bounds) (point-max)))
                       t)
             (let ((inhibit-read-only t))
               (delete-region (car bounds) (cdr bounds)))
             (mx-check "wrapped siblings: a re-render deletes it all"
                       (buffer-string) ""))))
      (kill-buffer buf)))

  ;; Degrade: nothing displays the file — a dim tag keeps the
  ;; media findable on the image line.
  (let ((buf (get-buffer-create "mx-rich-degrade")))
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer)
          (mx-rich-span "head " "tail" "$r1" 1)
          (cl-letf (((symbol-function 'elneo--image-for-display)
                     (lambda (_path) nil))
                    ((symbol-function 'default-font-height) (lambda () 24)))
            (elneo-room--put-rich-image mx-beg mx-end "/cache/emote.png"))
          (goto-char (point-min))
          (search-forward "[image]")
          (mx-check "degrade: a dim tag on the image line"
                    (get-text-property (match-beginning 0) 'face) 'shadow)
          (mx-check "degrade: the media stays findable"
                    (get-text-property (match-beginning 0)
                                       'elneo-room-media-name)
                    "e1ec965.png")
          (mx-check "degrade: the line joins the block"
                    (get-text-property (match-beginning 0)
                                       'elneo-room-event-id)
                    "$r1"))
      (kill-buffer buf)))

  ;; ---- on-media routes a rich placeholder to the rich path.

  ;; A failed fetch keeps the existing behavior: an inline marker.
  (let ((buf (get-buffer-create "mx-rich-fail")))
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer)
          (mx-rich-span "head " "tail" "$r1" 1)
          (elneo-room--on-media buf "$r1#img1" '((error . "404")))
          (goto-char (point-min))
          (search-forward "[image unavailable]")
          (mx-check "fail: the marker stays inline"
                    (buffer-substring-no-properties (point-min) (point-max))
                    "head [image unavailable]tail\n")
          (mx-check "fail: the marker keeps the synthetic id"
                    (get-text-property (match-beginning 0)
                                       'elneo-room-event-id)
                    "$r1#img1"))
      (kill-buffer buf)))

  (message "rich-image: %d passed, %d failed" pass fail)
  (kill-emacs (if (zerop fail) 0 1)))