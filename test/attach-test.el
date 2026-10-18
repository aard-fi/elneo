;;; attach-test.el --- file attach tags and the dired picker -*- lexical-binding: t; -*-

;; Files land in a room two ways: C-c C-a / C-c C-d write an
;; [image:]/[file:] tag into the draft (the tag type follows the
;; extension, the tag always lands at the draft's end whatever point
;; was), and the dired picker (elneo-room-attach-dired ->
;; elneo-dired-pick-for-buffer) binds C-c C-a locally in a dired
;; buffer whose marked files then attach to the room that opened it.
;; The room setup mirrors send-lifecycle-test.el; the picker is driven
;; against a real temp dired, with the no-mark / no-target guards
;; stubbed at `dired-get-marked-files'.
;;
;; Run: emacs -Q --batch -L lisp -l test/attach-test.el

(require 'elneo-room)
(require 'elneo-dired)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defun mx-attach-setup ()
    "A backfilled room buffer with a working draft area."
    (let ((buf (generate-new-buffer " *mx-attach-room*")))
      (with-current-buffer buf
        (elneo-room-mode)
        (setq-local elneo-room--profile "mxtest")
        (setq-local elneo-room--room-id "!room")
        (setq elneo-room--seen (make-hash-table :test 'equal))
        (setq elneo-room--backfilled t)
        (insert "header\n")
        (elneo-room--reset-input-area ""))
      buf))

  ;; The C-c prefix and the telega-alignment policy: same feature =
  ;; telega's key (C-c C-a attaches, s saves); telega keys for
  ;; unimplemented features stay free (i, m, C-c C-o).
  (mx-check "keymap: C-c C-a attaches by path (telega's key)"
            (lookup-key elneo-room-mode-map (kbd "C-c C-a"))
            #'elneo-room-attach)
  (mx-check "keymap: C-c C-i still attaches (alias)"
            (lookup-key elneo-room-mode-map (kbd "C-c C-i"))
            #'elneo-room-attach)
  (mx-check "keymap: C-c C-d opens the dired picker"
            (lookup-key elneo-room-mode-map (kbd "C-c C-d"))
            #'elneo-room-attach-dired)
  (mx-check "keymap: s saves media (telega's key)"
            (lookup-key elneo-room-mode-map (kbd "s"))
            #'elneo-room--s)
  (mx-check "keymap: S still saves (alias)"
            (lookup-key elneo-room-mode-map (kbd "S"))
            #'elneo-room--S)
  (mx-check "keymap: i reserved for describe-message"
            (lookup-key elneo-room-mode-map (kbd "i")) nil)
  (mx-check "keymap: retry media moved to I"
            (lookup-key elneo-room-mode-map (kbd "I"))
            #'elneo-room--I)
  (mx-check "keymap: m reserved for mark-message"
            (lookup-key elneo-room-mode-map (kbd "m")) nil)
  (mx-check "keymap: C-c ? is room settings (telega describe-chat)"
            (lookup-key elneo-room-mode-map (kbd "C-c ?"))
            #'elneo-room-settings)
  (mx-check "keymap: M-RET previews the draft as sent"
            (lookup-key elneo-room-mode-map (kbd "M-RET"))
            #'elneo-room-preview-draft)
  (mx-check "keymap: C-c C-o reserved for input options"
            (lookup-key elneo-room-mode-map (kbd "C-c C-o")) nil)
  (mx-check "keymap: C-c C-b opens the bar options"
            (lookup-key elneo-room-mode-map (kbd "C-c C-b"))
            #'elneo-room-bar-options)

  ;; Tag insertion: type by extension, space-separator between the
  ;; draft's content and the tag, and always at the draft's end —
  ;; point in the history must not matter.
  (let ((buf (mx-attach-setup)))
    (unwind-protect
        (with-current-buffer buf
          (elneo-room--insert-attach-tag "/tmp/mx/pic.png")
          (mx-check "tag: image tag on an empty draft"
                    (elneo-room--draft-text) "[image: /tmp/mx/pic.png]")
          (elneo-room--insert-attach-tag "/tmp/mx/doc.pdf")
          (mx-check "tag: file tag, space-separated"
                    (elneo-room--draft-text)
                    "[image: /tmp/mx/pic.png] [file: /tmp/mx/doc.pdf]")
          ;; Point parked on the history: the tag still lands at the
          ;; draft's end, not at point.
          (goto-char (point-min))
          (elneo-room--insert-attach-tag "/tmp/mx/shot.webp")
          (mx-check "tag: history point does not matter"
                    (elneo-room--draft-text)
                    "[image: /tmp/mx/pic.png] [file: /tmp/mx/doc.pdf] [image: /tmp/mx/shot.webp]"))
      (kill-buffer buf)))

  ;; The attach command keeps its point guard: point in the history
  ;; is an error, in the draft it inserts the tag.
  (let ((buf (mx-attach-setup)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (mx-check "C-c C-a: history point refused"
                    (condition-case e
                        (progn (elneo-room-attach "/tmp/mx/pic.png") 'no-error)
                      (user-error e))
                    '(user-error "Move point to the draft area to attach a file"))
          (goto-char (point-max))
          (elneo-room-attach "/tmp/mx/pic.png")
          (mx-check "C-c C-a: draft point attaches"
                    (elneo-room--draft-text) "[image: /tmp/mx/pic.png]"))
      (kill-buffer buf)))

  ;; C-c C-d refuses an unrendered room and hands the buffer and the
  ;; directory to the picker otherwise.
  (let ((buf (mx-attach-setup))
        (picked nil))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq elneo-room--backfilled nil)
            (mx-check "C-c C-d: unrendered room refused"
                      (condition-case e
                          (progn (elneo-room-attach-dired "/tmp/mx") 'no-error)
                        (user-error e))
                      '(user-error "The room is not rendered yet")))
          (cl-letf (((symbol-function 'elneo-dired-pick-for-buffer)
                     (lambda (room dir)
                       (setq picked (list room dir)))))
            (with-current-buffer buf
              (setq elneo-room--backfilled t)
              (elneo-room-attach-dired "/tmp/mx")))
          (mx-check "C-c C-d: room buffer handed to the picker"
                    (and (eq (car picked) buf)
                         (equal (cadr picked) "/tmp/mx"))
                    t))
      (kill-buffer buf)))

  ;; The picker itself, against a real dired on a temp directory.
  (let* ((dir (make-temp-file "mx-pick" t))
         (room (mx-attach-setup))
         (pic (expand-file-name "pic.png" dir))
         (doc (expand-file-name "doc.pdf" dir))
         dired-buffer)
    (unwind-protect
        (progn
          (write-region "" nil pic)
          (write-region "" nil doc)
          ;; Pick for the room: dired opens, the target and the local
          ;; C-c C-a binding live in that buffer only.
          (setq dired-buffer (elneo-dired-pick-for-buffer room dir))
          (mx-check "picker: shows the requested directory"
                    (with-current-buffer dired-buffer
                      (directory-file-name (expand-file-name default-directory)))
                    dir)
          (mx-check "picker: target is the room buffer"
                    (buffer-local-value 'elneo-dired--pick-target
                                        dired-buffer)
                    room)
          (mx-check "picker: C-c C-a bound locally"
                    (with-current-buffer dired-buffer
                      (local-key-binding (kbd "C-c C-a")))
                    #'elneo-dired--attach-marked)
          (with-current-buffer dired-buffer
            (dired-mark-files-regexp ".")
            (elneo-dired--attach-marked))
          ;; dired-get-marked-files yields the listing order: doc.pdf
          ;; sorts before pic.png.
          (mx-check "picker: marked files attached as tags"
                    (with-current-buffer room (elneo-room--draft-text))
                    (format "[file: %s] [image: %s]" doc pic))
          (mx-check "picker: window switched back to the room"
                    (window-buffer (selected-window))
                    room)
          ;; Started via matrix → attaches to its opener's room and
          ;; closes: no second round, no prompt.
          (mx-check "picker: dired closed after attach"
                    (buffer-live-p dired-buffer) nil))

      (ignore-errors (kill-buffer dired-buffer))
      (kill-buffer room)
      (delete-directory dir t)))

  ;; Attachable-file filtering: directories (the ./ line, a marked
  ;; subdir) are skipped with a message and never reach the room or
  ;; the daemon.
  (let* ((dir (make-temp-file "mx-pick-dir" t))
         (room (mx-attach-setup))
         (pic (expand-file-name "pic.png" dir))
         (subdir (expand-file-name "sub" dir))
         dired-buffer)
    (unwind-protect
        (progn
          (write-region "" nil pic)
          (make-directory subdir)
          (setq dired-buffer (elneo-dired-pick-for-buffer room dir))

          ;; Point on the directory line, nothing marked: nothing
          ;; attachable is an error — and the picker stays open for a
          ;; deliberate retry.
          (with-current-buffer dired-buffer
            (goto-char (point-min))     ; the "." line
            (mx-check "picker: directory-only is refused"
                      (condition-case e
                          (progn (elneo-dired--attach-marked) 'no-error)
                        (user-error e))
                      '(user-error "No attachable files (marked or at point)"))
            (mx-check "picker: refused attach keeps dired open"
                      (buffer-live-p dired-buffer) t))

          ;; Mixed marks: the subdir is skipped, the file attaches.
          (with-current-buffer dired-buffer
            (dired-goto-file subdir)
            (dired-mark 1)
            (goto-char (point-min))
            (dired-mark-files-regexp "pic.png$")
            (elneo-dired--attach-marked))
          (mx-check "picker: directory skipped, file tagged"
                    (with-current-buffer room (elneo-room--draft-text))
                    (format "[image: %s]" pic))
          (mx-check "picker: dired closed on the successful attach"
                    (buffer-live-p dired-buffer) nil))
      (ignore-errors (kill-buffer dired-buffer))
      (kill-buffer room)
      (delete-directory dir t)))

  ;; The room choice for the plain-M-x send flow: default off means it
  ;; always asks, even with one room on screen; the setting (t) makes
  ;; the unambiguous case silent, with a registry fallback for a room
  ;; buffer without a record.
  (let ((room (mx-attach-setup))
        (win (selected-window)))
    (unwind-protect
        (progn
          (set-window-buffer win room)
          ;; Visibility is stubbed to this one room: the batch session
          ;; has no real frames, but the target-room logic only needs
          ;; "one visible".
          (cl-letf (((symbol-function 'elneo-buffer-visible-p)
                     (lambda (b) (eq b room)))
                    ((symbol-function 'elneo-completing-read-room)
                     (lambda () 'prompted-room)))
            (let (elneo-dired-auto-target-visible-room)
              (mx-check "target-room: prompt is the default with one room"
                        (elneo-dired--target-room) 'prompted-room))
            (let ((elneo-dired-auto-target-visible-room t))
              ;; Registry miss: rebuilt belt-and-braces from the
              ;; buffer's own profile/room-id.
              (mx-check "target-room: setting picks the visible room"
                        (elneo-dired--target-room)
                        (list :profile "mxtest" :room-id "!room"
                              :display-name (buffer-name room)))
              (puthash (cons "mxtest" "!room") 'registry-record elneo--rooms)
              (mx-check "target-room: setting prefers the registry record"
                        (elneo-dired--target-room) 'registry-record)))
          ;; Two visible rooms: ambiguous, prompt even with the setting.
          (let ((room2 (mx-attach-setup)))
            (cl-letf (((symbol-function 'elneo-buffer-visible-p)
                       (lambda (b) (memq b (list room room2))))
                      ((symbol-function 'elneo-completing-read-room)
                       (lambda () 'prompted-room))
                      (elneo-dired-auto-target-visible-room t))
              (mx-check "target-room: two visible rooms still prompt"
                        (elneo-dired--target-room) 'prompted-room))
            (kill-buffer room2)))
      (set-window-buffer win (get-buffer-create "*scratch*"))
      (kill-buffer room)))

  ;; elneo-dired-send-files guards its files: only directories means
  ;; a clear error BEFORE any room prompt.
  (let ((dir (make-temp-file "mx-send-dir" t))
        (prompted nil))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "sub" dir))
          (cl-letf (((symbol-function 'elneo-dired--target-room)
                     (lambda () (setq prompted t) 'never-room)))
            (mx-check "send-files: directories only refused early"
                      (condition-case e
                          (progn (elneo-dired-send-files
                                  (list dir (expand-file-name "sub" dir)))
                                 'no-error)
                        (user-error e))
                      '(user-error "No attachable files (marked or at point)"))
            (mx-check "send-files: no prompt happened" prompted nil)))
      (delete-directory dir t)))

  ;; A killed target or a plain dired (no pick target) refuses, and no
  ;; marks at all is an error rather than a silent no-op.
  (let ((room (mx-attach-setup))
        (plain (generate-new-buffer " *mx-plain-dired*")))
    (unwind-protect
        (progn
          (with-current-buffer plain
            (setq elneo-dired--pick-target room))
          (kill-buffer room)
          (with-current-buffer plain
            (mx-check "picker: killed target refused"
                      (condition-case e
                          (progn (elneo-dired--attach-marked) 'no-error)
                        (user-error e))
                      '(user-error "This dired buffer is not a Matrix file picker")))
          (with-current-buffer plain
            (setq elneo-dired--pick-target nil)
            (mx-check "picker: plain dired refused"
                      (condition-case e
                          (progn (elneo-dired--attach-marked) 'no-error)
                        (user-error e))
                      '(user-error "This dired buffer is not a Matrix file picker"))
            ;; No files marked: dired-get-marked-files stubbed to nil.
            (setq elneo-dired--pick-target (mx-attach-setup))
            (cl-letf (((symbol-function 'dired-get-marked-files)
                       (lambda (&rest _) nil)))
              (mx-check "picker: no files marked is an error"
                        (condition-case e
                            (progn (elneo-dired--attach-marked) 'no-error)
                          (user-error e))
                        '(user-error "No attachable files (marked or at point)")))
            (kill-buffer elneo-dired--pick-target)))
      (kill-buffer plain)))

  ;; image-dired send: the resolver reads the `original-file-name'
  ;; property of the thumbnail at point, falls back to the nearest
  ;; thumbnail at or before point between thumbnails, and reads the
  ;; display buffer through `buffer-file-name'.  No image at point is
  ;; a user-error BEFORE the room prompt (a nil must never reach
  ;; elneo-dired-send-files — it used to explode as
  ;; "Wrong type argument: stringp, nil" only after the chat was
  ;; selected).
  (require 'image-dired)
  (let* ((dir (make-temp-file "mx-imgd" t))
         (png (expand-file-name "shot.png" dir))
         (jpg (expand-file-name "old.jpg" dir)))
    (unwind-protect
        (let ((thumb (generate-new-buffer " *mx-thumb*")))
          (write-region "" nil png)
          (write-region "" nil jpg)
          (with-current-buffer thumb
            ;; Reproduce a thumbnail buffer's text layout: property
            ;; runs one char each, one blank between, newline last.
            (goto-char (point-min))
            (insert (propertize "X" 'original-file-name png) " "
                    (propertize "Y" 'original-file-name jpg) "\n")
            (image-dired-thumbnail-mode)
            (goto-char (point-min))
            (mx-check "image-dired: file on the thumbnail at point"
                      (elneo-image-dired--original-file) png)
            (goto-char (1+ (point-min)))
            (mx-check "image-dired: blank after a thumb still resolves"
                      (elneo-image-dired--original-file) png)
            (let ((sent nil))
              (cl-letf (((symbol-function 'elneo-dired--target-room)
                         (lambda () 'fake-room))
                        ((symbol-function 'elneo-room-file)
                         (lambda (_p _r file _cb _t _s) (setq sent file))))
                (elneo-image-dired-send-file)
                (mx-check "image-dired: resolved file is sent" sent png)))
            (goto-char (point-max))
            (mx-check "image-dired: newline after thumbs falls back"
                      (elneo-image-dired--original-file) jpg)))
      (let ((stray (generate-new-buffer " *mx-stray*")))
        (with-current-buffer stray
          ;; elneo-image-dired-send-file delegates to
          ;; elneo-send-buffer-file: a non-thumbnail, non-file buffer
          ;; gets the general no-file error.
          (mx-check "image-dired: no image at point is a clear error"
                    (condition-case e
                        (progn (elneo-image-dired-send-file) 'no-error)
                      (user-error e))
                    '(user-error
                      "No file behind this buffer — in dired use ‘elneo-dired-send-files’")))
        (kill-buffer stray)
        (ignore-errors (kill-buffer thumb))
        (delete-directory dir t))))

  ;; elneo-send-buffer-file: a file-visiting buffer sends its file;
  ;; unsaved edits never change what is sent (the daemon reads the
  ;; path); a buffer without a backing file refuses clearly; and from
  ;; a thumbnail buffer it resolves the image at point too.
  (let* ((dir (make-temp-file "mx-buf" t))
         (txt (expand-file-name "notes.txt" dir))
         (png (expand-file-name "shot.png" dir)))
    (unwind-protect
        (let ((sent nil))
          (cl-letf (((symbol-function 'elneo-dired--target-room)
                     (lambda () 'fake-room))
                    ((symbol-function 'elneo-room-file)
                     (lambda (_p _r file _cb _t _s) (setq sent file))))
            (write-region "" nil txt)
            (write-region "" nil png)
            (let ((buf (find-file-noselect txt)))
              (mx-check "send-buffer-file: file-visiting buffer sends"
                        (progn (set-buffer buf)
                               (elneo-send-buffer-file)
                               sent)
                        txt)
              ;; Unsaved edits: still the on-disk version.
              (setq sent nil)
              (with-current-buffer buf
                (insert "unsaved edit\n")
                (elneo-send-buffer-file))
              (mx-check "send-buffer-file: unsaved edit sends the disk file"
                        sent txt))
            ;; No backing file at all.
            (let ((scratch (generate-new-buffer " *mx-nofile*")))
              (with-current-buffer scratch
                (mx-check "send-buffer-file: no backing file refused"
                          (condition-case e
                              (progn (elneo-send-buffer-file) 'no-error)
                            (user-error e))
                          '(user-error
                            "No file behind this buffer — in dired use ‘elneo-dired-send-files’")))
              (kill-buffer scratch))
            ;; Thumbnail buffers resolve through the image-dired
            ;; resolver without visiting anything.
            (write-region "" nil png)
            (let ((thumb (generate-new-buffer " *mx-thumb-b*"))
                  (buf (find-file-noselect png)))
              (with-current-buffer thumb
                (goto-char (point-min))
                (insert (propertize "X" 'original-file-name png) "\n")
                (image-dired-thumbnail-mode))
              (setq sent nil)
              (with-current-buffer thumb
                (elneo-send-buffer-file))
              (mx-check "send-buffer-file: thumbnail resolves its image"
                        sent png)
              (mx-check "send-buffer-file: thumbnail did not visit the image"
                        (buffer-local-value 'buffer-file-name thumb) nil)
              ;; elneo-image-dired-send-file works on a plain
              ;; file-visiting image buffer through the same command.
              (setq sent nil)
              (with-current-buffer buf
                (elneo-image-dired-send-file))
              (mx-check "send-buffer-file: image-dired variant delegates"
                        sent png)
              ;; The pre-29 image-dired display buffer: an unvisited
              ;; buffer holding a (temp) image, the original recorded
              ;; as an `original-file-name' property — mode derived
              ;; from special-mode, so neither earlier branch matched
              ;; and the send stopped with "No file behind this
              ;; buffer".  The mode symbol is setq'd because no local
              ;; display can really enter it.
              (let ((disp (generate-new-buffer " *mx-display-b*")))
                (with-current-buffer disp
                  (goto-char (point-min))
                  (insert (propertize "I" 'original-file-name png))
                  (setq major-mode 'image-dired-display-image-mode))
                (setq sent nil)
                (with-current-buffer disp
                  (elneo-send-buffer-file))
                (mx-check "send-buffer-file: pre-29 display buffer resolves its original"
                          sent png)
                ;; Point moved off the image after display: the
                ;; fallback finds the original at point-min.
                (setq sent nil)
                (with-current-buffer disp
                  (goto-char (point-max))
                  (elneo-send-buffer-file))
                (mx-check "send-buffer-file: pre-29 display buffer falls back to point-min"
                          sent png)
                (mx-check "send-buffer-file: pre-29 display buffer visited nothing"
                          (buffer-file-name disp) nil)
                (kill-buffer disp))
              ;; Emacs 31's display buffer: image-dired-display-image
              ;; copies the file's raw bytes into the unvisited buffer
              ;; — image-mode renders them from :data,
              ;; `buffer-file-name' is nil, no property — and keeps no
              ;; record of the original path.  elneo's post-display
              ;; advice records it into a buffer-local, which the
              ;; resolver reads as the last resort.  Batch cannot
              ;; really enter image-mode, so the shape is simulated
              ;; with setq, as above.
              (let ((disp31 (generate-new-buffer " *mx-display-31*")))
                (with-current-buffer disp31
                  (insert "rawbytes")
                  (setq major-mode 'image-dired-image-mode)
                  (setq elneo-image-dired--displayed-file png))
                (setq sent nil)
                (with-current-buffer disp31
                  (elneo-send-buffer-file))
                (mx-check "send-buffer-file: emacs-31 display buffer sends the recorded original"
                          sent png)
                ;; Without a record — a 31 buffer never displayed
                ;; through the advised path — it must still refuse:
                ;; the branch answers nil, not garbage.
                (kill-buffer disp31)
                (let ((disp31u (generate-new-buffer " *mx-display-31u*")))
                  (with-current-buffer disp31u
                    (insert "rawbytes")
                    (setq major-mode 'image-dired-image-mode)
                    (mx-check "send-buffer-file: emacs-31 display buffer without a record refuses"
                              (condition-case e
                                  (progn (elneo-send-buffer-file) 'no-error)
                                (user-error e))
                              '(user-error
                                "No file behind this buffer — in dired use ‘elneo-dired-send-files’")))
                  (kill-buffer disp31u))
              ;; The recording advice lands in the canonical display
              ;; buffer by name, whatever vintage's body produced it.
              (let ((dbuf (get-buffer-create image-dired-display-image-buffer)))
                (elneo-image-dired--record-displayed-file png)
                (mx-check "image-dired: display record lands in the display buffer"
                          (buffer-local-value
                           'elneo-image-dired--displayed-file dbuf)
                          png)
                (kill-buffer dbuf)))
              (kill-buffer thumb)
              (kill-buffer buf))))
      (delete-directory dir t)))

  ;; Tramp-remote staging: elneo-room-file/-image are the choke point
  ;; of every send flow, so the remote→local copy lives there — the
  ;; daemon reads local paths only, receives a fresh temp copy that
  ;; keeps the basename (name and mime derive from it), and the copy
  ;; is deleted once the send callback has run, success or failure.
  ;; file-remote-p is stubbed to a fake remote over a genuine local
  ;; file: copy-file needs no actual Tramp machinery to prove the
  ;; staging semantics.  The stub answers the `localname'
  ;; identification with the path itself, because file-local-name
  ;; (used for the staged copy's basename) calls it that way.
  (let* ((dir (make-temp-file "mx-tramp" t))
         (txt (expand-file-name "notes.txt" dir))
         (remote-p (lambda (file &optional ident _connected)
                     (if (eq ident 'localname)
                         file
                       "/fake:"))))
    (write-region "hello remote" nil txt)
    (unwind-protect
        (progn
          (mx-check "stage: local path passes through, no cleanup"
                    (elneo--upload-stage txt)
                    (cons (expand-file-name txt) nil))
          (let ((staged (cl-letf (((symbol-function 'file-remote-p)
                                   remote-p))
                          (elneo--upload-stage txt))))
            (mx-check "stage: remote file copied locally, same basename"
                      (and (stringp (car staged))
                           (file-directory-p (file-name-directory (car staged)))
                           (equal (file-name-nondirectory (car staged))
                                  "notes.txt"))
                      t)
            (mx-check "stage: copy holds the original's content"
                      (with-temp-buffer
                        (insert-file-contents-literally (car staged))
                        (buffer-string))
                      "hello remote")
            (mx-check "stage: original still in place"
                      (file-exists-p txt) t)
            (funcall (cdr staged))
            (mx-check "stage: cleanup deletes the staging directory"
                      (file-directory-p (file-name-directory (car staged)))
                      nil))
          ;; End to end through elneo-room-file: the request carries
          ;; the staged path and the staging directory vanishes only
          ;; after the callback has run.
          (let (req callback-ran)
            (cl-letf (((symbol-function 'file-remote-p)
                       remote-p)
                      ((symbol-function 'elneo-server--call)
                       (lambda (_profile request cb)
                         (setq req request)
                         (funcall cb "mxtest" '((@ok . t))))))
              (elneo-room-file "mxtest" "!room" txt
                                (lambda (_p _e) (setq callback-ran
                                                      (file-directory-p
                                                       (file-name-directory
                                                        (alist-get 'path req))))))
              (mx-check "upload: request is sendFile with a local path"
                        (list (alist-get '@type req)
                              (alist-get 'room_id req)
                              (string= (file-name-nondirectory
                                        (alist-get 'path req))
                                       "notes.txt"))
                        (list "sendFile" "!room" t))
              (mx-check "upload: staging dir still there during callback"
                        callback-ran t)
              (mx-check "upload: staging dir gone after the callback"
                        (file-directory-p (file-name-directory
                                           (alist-get 'path req)))
                        nil)))
          ;; End to end with a local file: the daemon sees exactly the
          ;; expanded original path.
          (let (req)
            (cl-letf (((symbol-function 'elneo-server--call)
                       (lambda (_profile request _cb) (setq req request))))
              (elneo-room-image "mxtest" "!room" txt
                                 (lambda (_p _e) nil))
              (mx-check "upload: local file passes through expanded"
                        (alist-get 'path req) (expand-file-name txt))
              (mx-check "upload: image request is sendImage"
                        (alist-get '@type req) "sendImage"))))
      (delete-directory dir t)))

  (message "results: %d passed, %d failed" pass fail)
  (kill-emacs (if (zerop fail) 0 1)))