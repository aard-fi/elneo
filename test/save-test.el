;;; save-test.el --- media save-as: extraction, keys, save flow -*- lexical-binding: t; -*-

;; `S' on a media message (elneo-room-save-media-at-point): the
;; daemon is stubbed at elneo-download-media, the "save as" flows
;; cover the no-prompt elneo-msg-save-dir path, the prompted path,
;; the failure path, and the media-at-point extraction shared with
;; open-media.  Also pins the mode-map bindings: the avatar toggle
;; `A' shipped without one once already.
;;
;; Run: emacs -Q --batch -L lisp -l test/save-test.el

(require 'elneo-room)

;; A 1x1 PNG stands in for the daemon's cache file.
(defconst mx-save-png "/tmp/mx-save-test.png")
(with-temp-file mx-save-png
  (insert (base64-decode-string
           "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")))

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  ;; The mode map must carry the history keys: A (avatar toggle)
  ;; once shipped defined-but-unbound.
  (mx-check "A bound in the mode map"
            (eq (lookup-key elneo-room-mode-map "A") #'elneo-room--A)
            t)
  (mx-check "S bound in the mode map"
            (eq (lookup-key elneo-room-mode-map "S") #'elneo-room--S)
            t)
  ;; telega saves with `s'; S is the alias.
  (mx-check "s bound in the mode map"
            (eq (lookup-key elneo-room-mode-map "s") #'elneo-room--s)
            t)

  ;; media-at-point extraction, shared by open and save
  (with-temp-buffer
    (insert "prefix "
            (propertize "[file: doc.pdf]"
                        'elneo-room-media-data
                        '((source . "mxc://hs/f") (filename . "doc.pdf"))
                        'elneo-room-media-name "doc.pdf")
            " suffix")
    (goto-char 8)                       ; on the entry
    (mx-check "media at point: on the entry"
              (cdr (elneo-room--media-at-point))
              '((source . "mxc://hs/f") (filename . "doc.pdf")))
    (goto-char 20)                      ; one char past it
    (mx-check "media at point: one past the entry"
              (cdr (elneo-room--media-at-point))
              '((source . "mxc://hs/f") (filename . "doc.pdf")))
    (goto-char 1)                       ; plain text
    (mx-check "media at point: none"
              (elneo-room--media-at-point)
              nil))

  ;; The save flows.  One helper: a room buffer holding one media
  ;; message, point on it.
  (defun mx-save-setup (dir)
    (let ((buf (generate-new-buffer " *mx-save-room*")))
      (with-current-buffer buf
        (elneo-room-mode)
        (setq elneo-room--profile "mxtest"
              elneo-msg-save-dir dir)
        (insert (propertize "[file: doc.pdf]"
                            'elneo-room-media-data
                            '((source . "mxc://hs/f") (filename . "doc.pdf"))
                            'elneo-room-media-name "doc.pdf")
                "\n"))
      buf))

  ;; no media at point: user-error, nothing happens
  (with-temp-buffer
    (elneo-room-mode)
    (setq elneo-room--profile "mxtest")
    (insert "plain text")
    (goto-char 3)
    (mx-check "save without media: user-error"
              (condition-case e
                  (progn (elneo-room-save-media-at-point) 'no-error)
                (user-error e))
              '(user-error "No media at point")))

  ;; elneo-msg-save-dir set: no prompt, file copies under its name
  (let* ((dir (make-temp-file "mx-save-dir" t))
         (buf (mx-save-setup dir))
         (saved-callback nil))
    (unwind-protect
        (with-current-buffer buf
          (goto-char 2)
          (cl-letf (((symbol-function 'elneo-download-media)
                     (lambda (_p _s _f callback &rest _)
                       (setq saved-callback callback))))
            (elneo-room-save-media-at-point)
            (mx-check "dir save: download started" (functionp saved-callback) t)
            ;; the daemon answers with the cache file
            (funcall saved-callback "mxtest"
                     `((@ok . t) (path . ,mx-save-png)))
            (mx-check "dir save: file copied"
                      (with-temp-buffer
                        (insert-file-contents
                         (expand-file-name "doc.pdf" dir))
                        (buffer-string))
                      (with-temp-buffer
                        (insert-file-contents mx-save-png)
                        (buffer-string)))))
      (kill-buffer buf)
      (delete-directory dir t)))

  ;; nil dir: prompted path, prompt stubbed to a chosen target
  (let* ((buf (mx-save-setup nil))
         (saved-callback nil)
         (target "/tmp/mx-save-prompted.bin"))
    (unwind-protect
        (with-current-buffer buf
          (goto-char 2)
          (cl-letf (((symbol-function 'elneo-download-media)
                     (lambda (_p _s _f callback &rest _)
                       (setq saved-callback callback)))
                    ((symbol-function 'read-file-name)
                     (lambda (_prompt _dir _must _init _default)
                       target)))
            (elneo-room-save-media-at-point)
            (funcall saved-callback "mxtest"
                     `((@ok . t) (path . ,mx-save-png)))
            (mx-check "prompt save: file at the chosen path"
                      (and (file-exists-p target) t)
                      t)))
      (kill-buffer buf)
      (when (file-exists-p target) (delete-file target))))

  ;; The prompt can also hand back a `~/'-abbrevation (`read-file-name'
  ;; returns it as typed); the copy must land at the expanded place.
  ;; HOME is rebased to a temp dir so the test never writes there.
  (let* ((home (make-temp-file "mx-save-home" t))
         (buf (mx-save-setup nil))
         (saved-callback nil))
    (unwind-protect
        (let ((process-environment
               (cons (format "HOME=%s" home) process-environment)))
          (with-current-buffer buf
            (goto-char 2)
            (cl-letf (((symbol-function 'elneo-download-media)
                       (lambda (_p _s _f callback &rest _)
                         (setq saved-callback callback)))
                      ((symbol-function 'read-file-name)
                       (lambda (_prompt _dir _must _init _default)
                         "~/dest.bin")))
              (elneo-room-save-media-at-point)
              (funcall saved-callback "mxtest"
                       `((@ok . t) (path . ,mx-save-png)))
              (mx-check "prompt save: a ~ target lands expanded"
                        (with-temp-buffer
                          (insert-file-contents
                           (expand-file-name "dest.bin" home))
                          (buffer-string))
                        (with-temp-buffer
                          (insert-file-contents mx-save-png)
                          (buffer-string))))))
      (kill-buffer buf)
      (delete-directory home t)))

  ;; failed download: nothing is written, no crash
  (let* ((dir (make-temp-file "mx-save-fail" t))
         (buf (mx-save-setup dir))
         (saved-callback nil))
    (unwind-protect
        (with-current-buffer buf
          (goto-char 2)
          (cl-letf (((symbol-function 'elneo-download-media)
                     (lambda (_p _s _f callback &rest _)
                       (setq saved-callback callback))))
            (elneo-room-save-media-at-point)
            (funcall saved-callback "mxtest"
                     '((@ok . nil) (error . "no such media")))
            (mx-check "failed download: nothing written"
                      (directory-files dir nil "\\`[^.]")
                      nil)))
      (kill-buffer buf)
      (delete-directory dir t)))

  ;; the S defkey: over history it saves, in the draft it types S
  (let* ((dir (make-temp-file "mx-save-key" t))
         (buf (mx-save-setup dir))
         (saved-callback nil)
         (room-key (cons "mxtest" "!r:mxsave.org")))
    (unwind-protect
        (with-current-buffer buf
          (setq elneo-room--room-id "!r:mxsave.org"
                elneo-room--seen (make-hash-table :test 'equal)
                elneo-room--backfilled nil)
          ;; no history yet: every S self-inserts (elneo-room--in-input-p)
          (goto-char (point-max))
          (call-interactively #'elneo-room--S)
          (mx-check "S with no history: self-inserted"
                    (buffer-substring (- (point) 1) (point)) "S")
          ;; backfilled with point on the media entry: S saves
          (setq elneo-room--backfilled t)
          (goto-char 2)
          (cl-letf (((symbol-function 'elneo-download-media)
                     (lambda (_p _s _f callback &rest _)
                       (setq saved-callback callback))))
            (call-interactively #'elneo-room--S)
            (mx-check "S over history: download started"
                      (functionp saved-callback) t)
            (funcall saved-callback "mxtest"
                     `((@ok . t) (path . ,mx-save-png)))
            (mx-check "S over history: file saved"
                      (file-exists-p (expand-file-name "doc.pdf" dir))
                      t))
          ;; back in the draft: types, not saves
          (goto-char (point-max))
          (cl-letf (((symbol-function 'elneo-download-media)
                     (lambda (&rest _) (error "must not download"))))
            (call-interactively #'elneo-room--S))
          (mx-check "S in the draft: self-inserted"
                    (buffer-substring (- (point) 1) (point)) "S")
          ;; the s alias rides the same rules: types in the draft,
          ;; saves over history (drop the S pass's file first so the
          ;; callback writes without an overwrite prompt).
          (delete-file (expand-file-name "doc.pdf" dir))
          (goto-char 2)
          (cl-letf (((symbol-function 'elneo-download-media)
                     (lambda (_p _s _f callback &rest _)
                       (setq saved-callback callback))))
            (call-interactively #'elneo-room--s)
            (mx-check "s over history: download started"
                      (functionp saved-callback) t)
            (funcall saved-callback "mxtest"
                     `((@ok . t) (path . ,mx-save-png))))
          (goto-char (point-max))
          (cl-letf (((symbol-function 'elneo-download-media)
                     (lambda (&rest _) (error "must not download"))))
            (call-interactively #'elneo-room--s))
          (mx-check "s in the draft: self-inserted"
                    (buffer-substring (- (point) 1) (point)) "s"))
      (kill-buffer buf)
      (delete-directory dir t)
      (ignore room-key)))

  (message "results: %d passed, %d failed" pass fail)
  (kill-emacs (if (zerop fail) 0 1)))