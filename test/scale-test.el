;;; scale-test.el --- image scaling at the upload choke point -*- lexical-binding: t; -*-

;; C-u on a send prompts once for a scale spec; the spec is applied
;; per image at elneo-room--send-upload, before staging, through
;; external tools probed in order (magick, convert, gm convert, sips)
;; and is an optimization: every degenerate case — no tool, unknown
;; size, vector svg, animated gif under sips, any failure — falls back
;; to the untouched original with a message, never loses the send.
;; No test requires an external tool to exist: every tool call goes
;; through stubs, and the temp-file mechanics run for real.
;;
;; Run: emacs -Q --batch -L lisp -l test/scale-test.el

(require 'cl-lib)
(require 'elneo-room)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defun mx-err (fun)
    "What FUN signals as (error-symbol . data), or \"no-error\"."
    (condition-case e (progn (funcall fun) 'no-error)
      (error e)))

  ;; ---- elneo--scale-parse: the accepted forms and the refusals.
  (mx-check "parse: empty sends the original"
            (elneo--scale-parse "") nil)
  (mx-check "parse: blank is like empty"
            (elneo--scale-parse "  ") nil)
  (mx-check "parse: 1920 is a longest-edge pixel limit"
            (elneo--scale-parse "1920") '(px . 1920))
  (mx-check "parse: px suffix accepted"
            (elneo--scale-parse "1920px") '(px . 1920))
  (mx-check "parse: px suffix is case-insensitive"
            (elneo--scale-parse "640PX") '(px . 640))
  (mx-check "parse: percent, trimmed"
            (elneo--scale-parse " 50% ") '(percent . 50))
  (mx-check "parse: zero pixels refused"
            (mx-err (lambda () (elneo--scale-parse "0")))
            '(user-error "Matrix: bad image scale \"0\" (use e.g. 1920, 1920px or 50%)"))
  (mx-check "parse: zero percent refused"
            (mx-err (lambda () (elneo--scale-parse "0%")))
            '(user-error "Matrix: bad image scale \"0%\" (use e.g. 1920, 1920px or 50%)"))
  (mx-check "parse: garbage refused"
            (mx-err (lambda () (elneo--scale-parse "bigger")))
            '(user-error "Matrix: bad image scale \"bigger\" (use e.g. 1920, 1920px or 50%)"))
  (mx-check "parse: mixed digits and text refused"
            (mx-err (lambda () (elneo--scale-parse "50abc")))
            '(user-error "Matrix: bad image scale \"50abc\" (use e.g. 1920, 1920px or 50%)"))

  ;; ---- elneo--scale-read: pre-fill is the last answer, every
  ;; answer (the empty one included) lands in the history.
  (let ((calls 0) captures)
    (cl-letf (((symbol-function 'read-string)
               (lambda (_prompt initial history &optional _default _inherit)
                 (setq calls (1+ calls))
                 (push (list initial history) captures)
                 "50%")))
      (setq elneo--scale-last nil)
      (mx-check "read: first answer parses"
                (elneo--scale-read) '(percent . 50))
      (mx-check "read: empty-input prefill on the first prompt"
                captures '(("" elneo--scale-history)))
      (mx-check "read: one prompt so far" calls 1)
      (mx-check "read: last answer stored" elneo--scale-last "50%")
      (mx-check "read: second answer parses again"
                (elneo--scale-read) '(percent . 50))
      (mx-check "read: second prompt prefills the last answer"
                (car captures) '("50%" elneo--scale-history))
      (setq elneo--scale-last nil))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _args) "")))
      (mx-check "read: emptied prefill means the original"
                (elneo--scale-read) nil)))

  ;; ---- elneo--scale-when-images: one prompt per call, and only for
  ;; a batch that actually contains an image by extension.
  (let ((prompts 0))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _args) (setq prompts (1+ prompts)) "50%")))
      (mx-check "when-images: mixed batch prompts once"
                (list (elneo--scale-when-images '("/d/a.txt" "/d/b.png"))
                      prompts)
                (list '(percent . 50) 1))
      (mx-check "when-images: imageless batch stays silent"
                (list (elneo--scale-when-images '("/d/a.txt" "/d/c.pdf"))
                      prompts)
                (list nil 1))
      (mx-check "when-images: empty batch stays silent"
                (list (elneo--scale-when-images '())
                      prompts)
                (list nil 1))))

  ;; ---- elneo--scale-backend: the probe order, uncached.
  (cl-letf (((symbol-function 'executable-find)
             (lambda (n &optional _r) (equal n "sips"))))
    (mx-check "backend: sips when it is all there is"
              (elneo--scale-backend) 'sips))
  (cl-letf (((symbol-function 'executable-find)
             (lambda (n &optional _r) (member n '("convert" "sips")))))
    (mx-check "backend: convert beats sips"
              (elneo--scale-backend) 'convert))
  (cl-letf (((symbol-function 'executable-find)
             (lambda (n &optional _r) (member n '("gm" "magick")))))
    (mx-check "backend: magick beats gm"
              (elneo--scale-backend) 'magick))
  (cl-letf (((symbol-function 'executable-find)
             (lambda (n &optional _r) (equal n "gm"))))
    (mx-check "backend: gm alone answers gm"
              (elneo--scale-backend) 'gm))
  (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
    (mx-check "backend: nothing installed answers nil"
              (elneo--scale-backend) nil))

  ;; ---- elneo--scale-argv: the exact invocations.
  (mx-check "argv: magick px is auto-orient, shrink-only"
            (elneo--scale-argv 'magick "/d/in.png" "/t/in.png" '(px . 1920))
            '("magick" "/d/in.png" "-auto-orient" "-resize"
              "1920x1920>" "/t/in.png"))
  (mx-check "argv: magick percent keeps the ratio"
            (elneo--scale-argv 'magick "/d/in.png" "/t/in.png" '(percent . 50))
            '("magick" "/d/in.png" "-auto-orient" "-resize"
              "50%" "/t/in.png"))
  (mx-check "argv: convert mirrors magick"
            (elneo--scale-argv 'convert "/d/in.png" "/t/in.png" '(px . 640))
            '("convert" "/d/in.png" "-auto-orient" "-resize"
              "640x640>" "/t/in.png"))
  (mx-check "argv: gm has its own shape, no auto-orient"
            (elneo--scale-argv 'gm "/d/in.png" "/t/in.png" '(percent . 75))
            '("gm" "convert" "/d/in.png" "-resize" "75%" "/t/in.png"))
  (mx-check "argv: sips only ever gets a pixel target"
            (elneo--scale-argv 'sips "/d/in.png" "/t/in.png" '(px . 1920))
            '("sips" "--resampleHeightWidthMax" "1920"
              "/d/in.png" "--out" "/t/in.png"))

  ;; ---- elneo--scale-target: the shrink-only rule and the percent
  ;; math.
  (mx-check "target: oversized long edge scales to the limit"
            (elneo--scale-target '(px . 1920) '(800 . 2000)) 1920)
  (mx-check "target: image within the limit is a no-op"
            (elneo--scale-target '(px . 1920) '(1600 . 900)) nil)
  (mx-check "target: exactly at the limit is a no-op"
            (elneo--scale-target '(px . 1920) '(1920 . 1080)) nil)
  (mx-check "target: percent of the longest edge"
            (elneo--scale-target '(percent . 50) '(1000 . 2000)) 1000)
  (mx-check "target: percent goes up, too"
            (elneo--scale-target '(percent . 150) '(1000 . 2000)) 3000)

  ;; ---- elneo--scale-run: zero exit is success; an unrunnable
  ;; program is a failure like a bad exit is.
  (cl-letf (((symbol-function 'call-process)
             (lambda (_p &rest _ignore) 0)))
    (mx-check "run: exit zero succeeds"
              (elneo--scale-run '("magick" "in" "out")) t))
  (cl-letf (((symbol-function 'call-process)
             (lambda (_p &rest _ignore) 1)))
    (mx-check "run: nonzero exit fails"
              (elneo--scale-run '("magick" "in" "out")) nil))
  (cl-letf (((symbol-function 'call-process)
             (lambda (_p &rest _ignore) (signal 'file-error '("no such file")))))
    (mx-check "run: missing program fails with a message, no signal"
              (elneo--scale-run '("magick" "in" "out")) nil))

  ;; ---- elneo--scale-size: both output shapes parse, exit 1 and an
  ;; unrunnable tool answer nil.
  (cl-letf (((symbol-function 'call-process)
             (lambda (_p &optional _i dest _d &rest _args)
               (with-current-buffer (if (bufferp dest) dest (current-buffer))
                 (insert "/d/p.png\n  pixelWidth: 30\n  pixelHeight: 40\n"))
               0)))
    (mx-check "size: sips output shape parses"
              (elneo--scale-size 'sips "/d/p.png") '(30 . 40)))
  (cl-letf (((symbol-function 'call-process)
             (lambda (_p &optional _i dest _d &rest _args)
               (with-current-buffer (if (bufferp dest) dest (current-buffer))
                 (insert "30 40\n"))
               0)))
    (mx-check "size: identify output shape parses"
              (elneo--scale-size 'magick "/d/p.png") '(30 . 40)))
  (cl-letf (((symbol-function 'call-process)
             (lambda (_p &optional _i dest _d &rest _args)
               (with-current-buffer (if (bufferp dest) dest (current-buffer))
                 (erase-buffer))
               1)))
    ;; A probed-but-empty buffer must not answer a half size.
    (mx-check "size: failed probe answers nil"
              (elneo--scale-size 'magick "/d/p.png") nil))
  (cl-letf (((symbol-function 'call-process)
             (lambda (_p &rest _ignore) (signal 'file-error '("no such file")))))
    (mx-check "size: missing tool answers nil"
              (elneo--scale-size 'sips "/d/p.png") nil))

  ;; ---- elneo--scale-image, degenerate branches: every one answers
  ;; the untouched original, no cleanup, with a saying.
  (let* ((dir (make-temp-file "mx-scale" t))
         (png (expand-file-name "photo.png" dir))
         (svg (expand-file-name "pic.svg" dir))
         (gif (expand-file-name "anim.gif" dir))
         (txt (expand-file-name "doc.txt" dir))
         (_ (dolist (f (list png svg gif txt)) (write-region "x" nil f))))
    (unwind-protect
        (progn
          (mx-check "scale-image: no spec, no scaling"
                    (elneo--scale-image png nil)
                    (cons (expand-file-name png) nil))
          (mx-check "scale-image: nonexistent file answers the original"
                    (elneo--scale-image
                     (expand-file-name "nope.png" dir) '(percent . 50))
                    (cons (expand-file-name "nope.png" dir) nil))
          (mx-check "scale-image: non-image extension is untouched"
                    (elneo--scale-image txt '(percent . 50))
                    (cons (expand-file-name txt) nil))
          (cl-letf (((symbol-function 'executable-find)
                     (lambda (n &optional _r) (equal n "magick"))))
            (mx-check "scale-image: svg is vector, sent as-is"
                      (elneo--scale-image svg '(percent . 50))
                      (cons (expand-file-name svg) nil))
            ;; No probed size anywhere: the ImageMagick family still
            ;; runs its `>' geometry (stubbed here to fail), while
            ;; sips has no pixel target at all and answers the
            ;; original untouched.
            (cl-letf (((symbol-function 'elneo--scale-size)
                       (lambda (_b _p) nil))
                      ((symbol-function 'elneo--scale-run)
                       (lambda (_argv) nil)))
              (mx-check "scale-image: magick without a size probe still attempts the tool"
                        (elneo--scale-image png '(percent . 50))
                        (cons (expand-file-name png) nil))))
          (cl-letf (((symbol-function 'executable-find)
                     (lambda (n &optional _r) (equal n "sips")))
                    ((symbol-function 'elneo--scale-size) (lambda (_b _p) nil)))
            (mx-check "scale-image: sips without the size sends unscaled"
                      (elneo--scale-image png '(percent . 50))
                      (cons (expand-file-name png) nil))
            (mx-check "scale-image: sips would flatten the gif"
                      (elneo--scale-image gif '(percent . 50))
                      (cons (expand-file-name gif) nil)))
          (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
            (mx-check "scale-image: no backend means the original"
                      (elneo--scale-image png '(percent . 50))
                      (cons (expand-file-name png) nil))))
      (delete-directory dir t)))

  ;; ---- elneo--scale-image, happy paths: the shrink-only no-op
  ;; never runs the tool, the oversized image lands as the original
  ;; basename in a scale directory the cleanup deletes.
  (let* ((dir (make-temp-file "mx-scale" t))
         (png (expand-file-name "photo.png" dir)))
    (write-region "pixels" nil png)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'executable-find)
                     (lambda (n &optional _r) (equal n "magick")))
                    ((symbol-function 'elneo--scale-size)
                     (lambda (_b _p) '(1600 . 900)))
                    (runs 0)
                    ((symbol-function 'elneo--scale-run)
                     (lambda (_argv) (setq runs (1+ runs)) t)))
            (mx-check "scale-image: within the px limit never calls the tool"
                      (list (elneo--scale-image png '(px . 1920)) runs)
                      (list (cons (expand-file-name png) nil) 0)))
          (cl-letf (((symbol-function 'executable-find)
                     (lambda (n &optional _r) (equal n "magick")))
                    ((symbol-function 'elneo--scale-size)
                     (lambda (_b _p) '(4000 . 3000)))
                    ((symbol-function 'elneo--scale-run)
                     (lambda (argv)
                       (write-region "scaled" nil (car (last argv))) t)))
            (let ((scaled (elneo--scale-image png '(px . 1920))))
              (mx-check "scale-image: scaled copy keeps the basename"
                        (file-name-nondirectory (car scaled)) "photo.png")
              (mx-check "scale-image: scaled copy is new content"
                        (with-temp-buffer
                          (insert-file-contents-literally (car scaled))
                          (buffer-string))
                        "scaled")
              (mx-check "scale-image: scale directory holds the copy"
                        (file-directory-p (file-name-directory (car scaled))) t)
              (funcall (cdr scaled))
              (mx-check "scale-image: cleanup deletes the scale directory"
                        (file-directory-p (file-name-directory (car scaled))) nil)))
          (cl-letf (((symbol-function 'executable-find)
                     (lambda (n &optional _r) (equal n "magick")))
                    ((symbol-function 'elneo--scale-size)
                     (lambda (_b _p) '(4000 . 3000)))
                    ((symbol-function 'elneo--scale-run) (lambda (_argv) nil)))
            (mx-check "scale-image: tool failure answers the original, no cleanup"
                      (elneo--scale-image png '(percent . 50))
                      (cons (expand-file-name png) nil))))
      (delete-directory dir t)))

  ;; ---- The choke point: a scale copy and a staged copy both live
  ;; until the callback has settled, and the request carries the
  ;; scaled copy's path under the original basename (the daemon's
  ;; mime guess rides the extension).  elneo--scale-image is stubbed
  ;; to a faithful-but-fast copy so the chaining, not the scaler, is
  ;; what is proven here.
  (let* ((dir (make-temp-file "mx-scale" t))
         (png (expand-file-name "photo.png" dir))
         req callback-ran)
    (write-region "pixels" nil png)
    (unwind-protect
        (cl-letf (((symbol-function 'elneo--scale-image)
                   (lambda (path spec)
                     (let* ((d (make-temp-file "elneo-scale-" t))
                            (copy (expand-file-name
                                   (file-name-nondirectory path) d)))
                       (if (null spec)
                           (cons (expand-file-name path) nil)
                         (copy-file path copy t)
                         (cons copy (lambda () (delete-directory d t))))))))
          ;; No scale spec at all: today's behavior, byte for byte.
          (cl-letf (((symbol-function 'elneo-server--call)
                     (lambda (_profile request cb)
                       (setq req request)
                       (funcall cb "mxtest" '((@ok . t))))))
            (setq req nil)
            (elneo-room-file "mxtest" "!room:hs" png
                             (lambda (_p _e) t))
            (mx-check "chain: 4-arg room-file sends the original"
                      (alist-get 'path req) (expand-file-name png)))
          ;; With a spec: the request path is the scale copy, and both
          ;; the scale directory and any staging directory are gone
          ;; after the callback.
          (cl-letf (((symbol-function 'elneo-server--call)
                     (lambda (_profile request cb)
                       (setq req request)
                       (funcall cb "mxtest" '((@ok . t))))))
            (setq req nil callback-ran nil)
            (elneo-room-file "mxtest" "!room:hs" png
                             (lambda (_p _e) (setq callback-ran t))
                             nil '(percent . 50))
            (let ((path (alist-get 'path req)))
              (mx-check "chain: request carries the scaled copy"
                        (and (not (string= path (expand-file-name png)))
                             (equal (file-name-nondirectory path)
                                    "photo.png"))
                        t)
              (mx-check "chain: callback ran"
                        callback-ran t)
              (mx-check "chain: scale directory deleted after the callback"
                        (file-directory-p (file-name-directory path)) nil)))
          ;; A signaling callback must not leave the copies behind.
          (cl-letf (((symbol-function 'elneo-server--call)
                     (lambda (_profile _request cb)
                       (condition-case nil
                           (funcall cb "mxtest" '((@ok . t)))
                         (error nil)))))
            (setq req nil)
            (elneo-room-file "mxtest" "!room:hs" png
                             (lambda (_p _e) (signal 'wrong-type-argument '("boom")))
                             nil '(percent . 50))
            (mx-check "chain: signaling callback deletes the scale copy"
                      (and (alist-get 'path req)
                           (file-directory-p
                            (file-name-directory (alist-get 'path req))))
                      nil)))
      (delete-directory dir t)))

  ;; ---- Entry points: the C-u plumbing.  In a real room buffer, a
  ;; C-u RET over a draft with an image tag prompts exactly once and
  ;; the answer rides to `elneo-room-image'; a draft whose only tag
  ;; is a non-image file never prompts; plain text under C-u goes
  ;; out unchanged.  read-string is stubbed (it must never be called
  ;; in the no-prompt cases), the senders capture their arguments.
  (require 'elneo-dired)
  (let* ((dir (make-temp-file "mx-scale" t))
         (png (expand-file-name "photo.png" dir))
         (txt (expand-file-name "doc.txt" dir))
         buf prompts
         texts images)
    (write-region "pixels" nil png)
    (write-region "x" nil txt)
    (unwind-protect
        (progn
          (setq buf (generate-new-buffer " *scale-draft*")
                prompts 0)
          (with-current-buffer buf
            (elneo-room-mode)
            (setq-local elneo-room--profile "mxtest")
            (setq-local elneo-room--room-id "!room:hs")
            (setq elneo-room--backfilled t))
          (cl-letf (((symbol-function 'read-string)
                     (lambda (&rest _)
                       (setq prompts (1+ prompts)) "1920"))
                    ((symbol-function 'elneo-room--send-text)
                     (lambda (body) (push body texts)))
                    ((symbol-function 'elneo-room-image)
                     (lambda (_p _r path _cb _thread scale)
                       (push (cons path scale) images))))
            ;; C-u over "text + image tag": one prompt, both pieces
            ;; go, the image carries the spec.
            (with-current-buffer buf
              (elneo-room--reset-input-area
               (concat "hello [image: " png "]"))
              (let ((current-prefix-arg '(4)))
                (elneo-room--input-send))
              (mx-check "wire: C-u image tag prompts once" prompts 1)
              (mx-check "wire: the tag's image carries the spec"
                        (nreverse images)
                        (list (cons (expand-file-name png) '(px . 1920))))
              (mx-check "wire: the text still went out"
                        (equal (nreverse texts)
                               (list "hello " "")) t)
              (mx-check "wire: draft cleared after the C-u send"
                        (elneo-room--draft-text) "")
              (setq texts nil images nil))
            ;; C-u over a file-only tag of a non-image: no prompt,
            ;; the file goes unscaled (`elneo-room-file' would ignore
            ;; a spec anyway — the scaler filters by extension).
            (with-current-buffer buf
              (elneo-room--reset-input-area
               (concat "[file: " txt "]"))
              (setq prompts 0)
              (let ((current-prefix-arg '(4)))
                ;; `elneo-room-file' would ignore a spec anyway — the
                ;; scaler filters by extension at the choke point.
                (cl-letf (((symbol-function 'elneo-room-file)
                           (lambda (_p _r path _cb _thread scale)
                             (push (cons path scale) images))))
                  (elneo-room--input-send)))
              (mx-check "wire: C-u over a plain file never prompts"
                        prompts 0)
              (mx-check "wire: the plain file goes unscaled"
                        (equal (nreverse images)
                               (list (cons txt nil))) t)
              (setq images nil texts nil))
            ;; C-u over plain text: no prompt, nothing changed.
            (with-current-buffer buf
              (elneo-room--reset-input-area "just words")
              (setq prompts 0)
              (let ((current-prefix-arg '(4)))
                (elneo-room--input-send))
              (mx-check "wire: C-u plain text never prompts" prompts 0)
              (mx-check "wire: C-u plain text sends the draft"
                        (equal (nreverse texts) '("just words")) t))))
      (and buf (buffer-live-p buf) (kill-buffer buf))
      (delete-directory dir t)))

  ;; ---- The dired entry point: the room-file call carries SCALE
  ;; whatever the batch mix is (the scaler filters by extension at
  ;; the choke point), and nil without a spec.
  (let ((sent nil))
    (cl-letf (((symbol-function 'elneo-room-file)
               (lambda (_p _r path _cb _t scale)
                 (push (cons path scale) sent))))
      (elneo-dired-send-files
       (list "/d/a.txt" "/d/b.png") '(:profile "mxtest" :room-id "!room"
                                     :display-name "R")
       '(px . 640))
      (mx-check "dired: scale rides on every batch file"
                (equal (nreverse sent)
                       (list (cons "/d/a.txt" '(px . 640))
                             (cons "/d/b.png" '(px . 640)))) t)
      (setq sent nil)
      (elneo-dired-send-files
       (list "/d/a.txt") '(:profile "mxtest" :room-id "!room"
                                    :display-name "R")
       nil)
      (mx-check "dired: no spec means no spec"
                (equal (nreverse sent) (list (cons "/d/a.txt" nil))) t)))

  (message "scale-test: %d passed, %d failed" pass fail)
  (kill-emacs (if (= fail 0) 0 1)))