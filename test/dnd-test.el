;;; dnd-test.el --- drag-and-drop into the room buffer (feature B) -*- lexical-binding: t; -*-

;; Dropping into a room buffer inserts [image:]/[file:] tags into the
;; draft — the same tags C-c C-a writes — and never sends anything.
;; `elneo-room-dnd-receive' is registered with the
;; `dnd-multiple-handler' property, so dnd.el hands it ONE call with
;; all the dropped file:// URLs, accumulated newest-first (dnd.el
;; prepends while iterating) — the handler nreverse back to drop
;; order, and the test pins that order through the real
;; `dnd-handle-multiple-urls' path.  Only local, existing, non-
;; directory files attach; a room that has not been rendered yet
;; refuses.  The handler answers `private' for every file: URL it
;; receives — even ones it rejects — because dnd.el inserts unassigned
;; URLs into the buffer as raw text, so a rejected drop must never
;; degenerate into a `file:/...' text message.  The matcher therefore
;; covers every file URL shape macOS hands over (`file:///', `file:/',
;; `file://localhost/').  URL drops take the second handler:
;; images fetch to a temp file and attach; anything else — a page, a
;; failed fetch — lands in the draft as the link itself.  Every case
;; here stubs the send path and pins its counter at zero: a drop must
;; not produce an outgoing message.
;;
;; The drafts file is pointed at a temp path — the draft-store
;; readback case dirties the table, and the kill-emacs-hook flush in
;; elneo-room.el would otherwise write test drafts into the real
;; data directory.
;;
;; Run: emacs -Q --batch -L lisp -l test/dnd-test.el

(require 'cl-lib)
(require 'url-util)                     ; url-hexify-string
(require 'elneo-room)

(let ((pass 0) (fail 0) (sends 0) (room-drafts-file-tmp nil))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defun mx-attach-setup ()
    "A backfilled room buffer with a working draft area."
    (let ((buf (generate-new-buffer " *mx-dnd-room*")))
      (with-current-buffer buf
        (elneo-room-mode)
        (setq-local elneo-room--profile "mxtest")
        (setq-local elneo-room--room-id "!room")
        (setq elneo-room--seen (make-hash-table :test 'equal))
        (setq elneo-room--backfilled t)
        (insert "header\n")
        (elneo-room--reset-input-area ""))
      buf))

  ;; A drop that ends up sending is a bug by definition; the send
  ;; path is stubbed to a counting failure so any accidental send is
  ;; both counted and loud.
  (defalias 'elneo-room--send-text
    (lambda (&rest _args)
      (cl-incf sends)
      (error "dnd-test: send path fired")))

  ;; Real temp files: the handler checks existence, so the drops are
  ;; genuine file:// URLs over files that exist.
  (setq room-drafts-file-tmp (make-temp-file "mx-dnd-drafts" t)
        elneo-room--draft-store nil
        elneo-room--drafts-dirty nil)
  (let* ((dir (make-temp-file "mx-dnd" t))
         (pic (expand-file-name "pic.png" dir))
         (doc (expand-file-name "doc.pdf" dir))
         (spaced (expand-file-name "my pic.png" dir))
         (subdir (expand-file-name "subdir" dir))
         (file-url           (lambda (p) (concat "file://" p)))
         (file-url-escaped   (lambda (p) (concat "file://"
                                                 (replace-regexp-in-string " " "%20" p))))
         ;; Single-slash shape: `file:' + the /absolute path — macOS
         ;; promised-file drags have been reported to hand this over.
         (file-url-slash     (lambda (p) (concat "file:" p)))
         (room (mx-attach-setup)))
    (unwind-protect
        (progn
          (write-region "" nil pic)
          (write-region "" nil doc)
          (write-region "" nil spaced)
          (make-directory subdir)
          ;; The kill-emacs flush would need a writable, harmless drafts
          ;; file — and none of this must ever touch the real one.
          (setq elneo-room-drafts-file (expand-file-name "drafts.el"
                                                          room-drafts-file-tmp)
                elneo-room--drafts-legacy-file
                (expand-file-name "legacy.el" room-drafts-file-tmp))

          ;; Registration: room buffers accept every file: URL shape
          ;; (see elneo-room-dnd-receive), everything else keeps the
          ;; stock dnd behavior.
          (mx-check "register: room buffer's dnd-protocol-alist"
                    (with-current-buffer room dnd-protocol-alist)
                    '(("^file:" . elneo-room-dnd-receive)
                      ("^https?:" . elneo-room-dnd-receive-url)))
          (mx-check "register: dnd-multiple-handler property"
                    (get 'elneo-room-dnd-receive 'dnd-multiple-handler) t)
          (mx-check "register: url handler is a multiple handler too"
                    (get 'elneo-room-dnd-receive-url 'dnd-multiple-handler) t)
          (mx-check "register: non-room buffer keeps default alist"
                    (default-value 'dnd-protocol-alist)
                    (copy-sequence (default-value 'dnd-protocol-alist)))

          ;; Single drop.
          (with-current-buffer room
            (mx-check "drop: one image → one tag, returns private"
                      (elneo-room-dnd-receive
                       (list (funcall file-url pic)) 'private)
                      'private)
            (mx-check "drop: draft holds the image tag"
                      (elneo-room--draft-text) (format "[image: %s]" pic))
            ;; Nothing has gone out through the send path.
            (mx-check "drop: send-path untouched" sends 0))

          ;; Two files in one drop: order preserved (mixed image/doc).
          (with-current-buffer room
            (mx-check "drop: mixed doc+image order kept"
                      (elneo-room-dnd-receive
                       (list (funcall file-url doc)
                             (funcall file-url pic))
                       'private)
                      'private)
            (mx-check "drop: draft accumulated in drop order"
                      (elneo-room--draft-text)
                      (format "[image: %s] [file: %s] [image: %s]"
                              pic doc pic))
            (mx-check "drop: still nothing sent" sends 0))

          ;; The real dnd.el path: multiple URLs accumulate newest-first,
          ;; the handler must nreverse back to the drop order.  This case
          ;; would catch a missing nreverse directly.
          (let ((win (selected-window)))
            (set-window-buffer win room)
            (set-buffer room)
            (elneo-room--reset-input-area "")
            (with-current-buffer room
              (mx-check "dnd.el path: real multiple-url handler"
                        (dnd-handle-multiple-urls
                         win (list (funcall file-url pic)
                                   (funcall file-url doc))
                         'private)
                        'private)
              (mx-check "dnd.el path: drop order not reversed"
                        (elneo-room--draft-text)
                        (format "[image: %s] [file: %s]" pic doc))))

          ;; %20 URI escaping decodes to the real path with the space.
          (with-current-buffer room
            (elneo-room--reset-input-area "")
            (mx-check "drop: %20 decodes"
                      (elneo-room-dnd-receive
                       (list (funcall file-url-escaped spaced)) 'private)
                      'private)
            (mx-check "drop: spaced file tagged"
                      (elneo-room--draft-text) (format "[image: %s]" spaced)))

          ;; Not a file:// URI: the FILE handler leaves it alone —
          ;; https URLs belong to the URL handler, which the alist
          ;; routes them to.  The private answer still holds: the
          ;; no-raw-URL-insertion contract.
          (with-current-buffer room
            (elneo-room--reset-input-area "")
            (mx-check "drop: file handler leaves https URLs alone"
                      (elneo-room-dnd-receive '("https://example/x.pdf") 'private)
                      'private)
            (mx-check "drop: draft unchanged for non-file URI"
                      (elneo-room--draft-text) ""))

          ;; A nonexistent file is skipped by the exists check — and
          ;; still answered with `private', so dnd's insert-as-text
          ;; fallback can never fire.
          (with-current-buffer room
            (elneo-room--reset-input-area "")
            (mx-check "drop: nonexistent file skipped"
                      (elneo-room-dnd-receive
                       (list (concat "file://" dir "/nope.png")) 'private)
                      'private)
            (mx-check "drop: draft unchanged for nonexistent file"
                      (elneo-room--draft-text) ""))

          ;; URL shapes other than file:///: the exact regression for
          ;; the macOS bug where the raw URL was sent as a text
          ;; message.  file:/ (promised-file drags) and
          ;; file://localhost/ both must resolve to the same tag.
          (with-current-buffer room
            (elneo-room--reset-input-area "")
            (mx-check "drop: single-slash file:/ resolves"
                      (elneo-room-dnd-receive
                       (list (funcall file-url-slash pic)) 'private)
                      'private)
            (mx-check "drop: single-slash shape tagged"
                      (elneo-room--draft-text) (format "[image: %s]" pic)))

          (with-current-buffer room
            (elneo-room--reset-input-area "")
            (mx-check "drop: file://localhost/ resolves"
                      (elneo-room-dnd-receive
                       (list (concat "file://localhost" doc)) 'private)
                      'private)
            (mx-check "drop: localhost shape tagged"
                      (elneo-room--draft-text) (format "[file: %s]" doc)))

          ;; Through the real dnd.el path: under the narrow
          ;; `^file:///' matcher, a `file:/...' URL was not assigned any
          ;; handler and dnd.el fell back to typing the raw URL into
          ;; the buffer (dnd-insert-text) — the bug.  The broader
          ;; matcher assigns it here and no raw text may land.
          (let ((win (selected-window)))
            (set-window-buffer win room)
            (set-buffer room)
            (elneo-room--reset-input-area "")
            (with-current-buffer room
              (mx-check "dnd.el path: file:/ shape assigned to the handler"
                        (dnd-handle-multiple-urls
                         win (list (funcall file-url-slash spaced)) 'private)
                        'private)
              (mx-check "dnd.el path: tagged, not the raw URL"
                        (elneo-room--draft-text)
                        (format "[image: %s]" spaced))
              (mx-check "dnd.el path: no raw URL text anywhere"
                        (string-search "file:/" (buffer-string)) nil)
              (mx-check "dnd.el path: still nothing sent" sends 0)))

          ;; A directory is skipped, but same-drop siblings survive.
          (with-current-buffer room
            (elneo-room--reset-input-area "")
            (mx-check "drop: directory skipped, siblings kept"
                      (elneo-room-dnd-receive
                       (list (concat "file://" subdir)
                             (funcall file-url pic)
                             (funcall file-url doc))
                       'private)
                      'private)
            (mx-check "drop: only the files were tagged"
                      (elneo-room--draft-text)
                      (format "[image: %s] [file: %s]" pic doc)))

          ;; Two drops accumulate with the separator space, draft order
          ;; kept across drops.
          (with-current-buffer room
            (elneo-room--reset-input-area "")
            (elneo-room-dnd-receive (list (funcall file-url pic)) 'private)
            (elneo-room-dnd-receive (list (funcall file-url doc)) 'private)
            (mx-check "drop: two drops accumulate"
                      (elneo-room--draft-text)
                      (format "[image: %s] [file: %s]" pic doc)))

          ;; URL drops: an image URL fetches to a temp file and
          ;; attaches; anything else — a page, a failed fetch — lands
          ;; in the draft as the link itself, so RET sends it.  The
          ;; fetch is stubbed to answer synchronously with a scripted
          ;; body, so the draft checks are exact.  One real PNG (1x1,
          ;; base64) rides through byte-for-byte.
          (let* ((png (base64-decode-string
                       "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
                 (mx-body "") (mx-status nil) (fetches 0))
            (cl-letf (((symbol-function 'url-retrieve)
                       (lambda (_url cb &rest _)
                         (cl-incf fetches)
                         (with-current-buffer (generate-new-buffer " *mx-url*")
                           (insert "HTTP/1.1 200 OK\r\n\r\n" mx-body)
                           (funcall cb mx-status)))))
              ;; Image: temp file under the URL's basename, bytes intact.
              (setq mx-body png)
              (with-current-buffer room
                (elneo-room--reset-input-area "")
                (mx-check "url drop: image attaches, returns private"
                          (elneo-room-dnd-receive-url
                           '("https://x.example/cat.png") 'private)
                          'private)
                (let ((paths (elneo-room--tag-paths (elneo-room--draft-text))))
                  (mx-check "url drop: one temp file, cat-named, image-tagged"
                            (and (= (length paths) 1)
                                 (string-match-p "/elneo-drop-cat" (car paths))
                                 (string= (file-name-extension (car paths)) "png")
                                 (file-exists-p (car paths)))
                            t)
                  (mx-check "url drop: the bytes arrived intact"
                            (with-temp-buffer
                              (set-buffer-multibyte nil)
                              (insert-file-contents-literally (car paths))
                              (and (= (buffer-size) (length png))
                                   (string-equal (buffer-string) png)))
                            t)
                  (delete-file (car paths))))
              ;; jpeg sniffs to type 'jpeg; the temp file must say jpg.
              (with-current-buffer room
                (elneo-room--reset-input-area "")
                (elneo-room--attach-image-data
                 "junk" 'jpeg "https://x.example/pic.JPG" room)
                (let ((paths (elneo-room--tag-paths (elneo-room--draft-text))))
                  (mx-check "url drop: jpeg type maps to a .jpg temp file"
                            (and (string-match-p "/elneo-drop-pic" (car paths))
                                 (string= (file-name-extension (car paths)) "jpg"))
                            t)
                  (delete-file (car paths))))
              ;; A page instead of an image: the URL lands in the draft.
              (setq mx-body "<html>not an image</html>")
              (with-current-buffer room
                (elneo-room--reset-input-area "")
                (elneo-room-dnd-receive-url '("https://x.example/page") 'private)
                (mx-check "url drop: a page drops in as the link"
                          (elneo-room--draft-text) "https://x.example/page"))
              ;; A failed fetch (dead host): the URL still lands in the
              ;; draft — the link may be worth sending even when the
              ;; fetch could not see an image.
              (setq mx-body "" mx-status '(:error (error "connection refused")))
              (with-current-buffer room
                (elneo-room--reset-input-area "")
                (elneo-room-dnd-receive-url '("https://x.example/dead") 'private)
                (mx-check "url drop: a failed fetch drops in as the link"
                          (elneo-room--draft-text) "https://x.example/dead"))
              ;; The real dnd.el path assigns https URLs to the handler.
              (let ((win (selected-window)))
                (setq mx-body png mx-status nil)
                (set-window-buffer win room)
                (set-buffer room)
                (elneo-room--reset-input-area "")
                (with-current-buffer room
                  (mx-check "dnd.el path: https drop routes to the url handler"
                            (dnd-handle-multiple-urls
                             win '("https://x.example/dog.png") 'private)
                            'private)
                  (let ((paths (elneo-room--tag-paths (elneo-room--draft-text))))
                    (mx-check "dnd.el path: fetched image tagged"
                              (and (= (length paths) 1)
                                   (file-exists-p (car paths))
                                   (string= (file-name-extension (car paths))
                                            "png"))
                              t)
                    (delete-file (car paths)))))
              ;; An unrendered room refuses without fetching at all.
              (with-current-buffer room
                (setq elneo-room--backfilled nil)
                (elneo-room--reset-input-area "")
                (let ((before fetches))
                  (mx-check "url drop: unrendered room refuses, no fetch"
                            (list (elneo-room-dnd-receive-url
                                   '("https://x.example/a.png") 'private)
                                  (- fetches before))
                            '(private 0)))
                (setq elneo-room--backfilled t))))

          ;; A room that has not been rendered yet refuses — with
          ;; `private', so the URL is swallowed and not inserted as
          ;; text even here.
          (with-current-buffer room
            (elneo-room--reset-input-area "")
            (setq elneo-room--backfilled nil)
            (mx-check "drop: unrendered room refuses"
                      (elneo-room-dnd-receive
                       (list (funcall file-url pic)) 'private)
                      'private)
            (mx-check "drop: unrendered room inserts nothing"
                      (elneo-room--draft-text) "")
            (setq elneo-room--backfilled t))

          ;; Send counter must still be zero — the whole suite never
          ;; sent a thing.
          (mx-check "drop: send-path untouched across the suite" sends 0)

          ;; The drop is picked up by draft persistence.
          (with-current-buffer room
            (elneo-room--reset-input-area "")
            (elneo-room-dnd-receive (list (funcall file-url pic)) 'private)
            (elneo-room--draft-maybe-save)
            (mx-check "drop: draft-store readback"
                      (gethash (cons "mxtest" "!room") elneo-room--draft-store)
                      (format "[image: %s]" pic)))
          (setq elneo-room--drafts-dirty nil))
      ;; Cleanup: no dirty test drafts may reach any real file.
      (setq elneo-room--drafts-dirty nil
            elneo-room--draft-save-timer nil
            elneo-room-drafts-file nil)
      (ignore-errors (kill-buffer room))
      (ignore-errors (delete-directory dir t))
      (ignore-errors (delete-directory room-drafts-file-tmp t))))

      (message "results: %d passed, %d failed" pass fail)
      (kill-emacs (if (zerop fail) 0 1))))