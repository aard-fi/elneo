;;; elneo-dired.el --- send files to Matrix rooms from dired -*- lexical-binding: t; -*-

;;; Commentary:

;; The telega dired workflow, ported.  `elneo-dired-send-files' sends
;; the marked files (otherwise the file at point; directories are
;; skipped) to a Matrix room: picked with completing-read across all
;; accounts by default — the one-visible-room auto-target exists but
;; is a setting, `elneo-dired-auto-target-visible-room', defaulting
;; to off; the room choice is never guessed at without it.
;; `elneo-image-dired-send-file' sends the image at point in
;; image-dired through the same room choice.
;;
;; The other direction is the picker, `elneo-dired-pick-for-buffer':
;; a room buffer opens a dired with `elneo-room-attach-dired', marks
;; land in that room's draft as attach tags via C-c C-a there — the
;; gnus-dired-attach flow.  That picker never prompts (its target is
;; the room that opened it), and it kills its dired buffer once the
;; files are attached.  The binding lives only in that one buffer.
;;
;; Bind the send commands yourself; telega's contrib telega-dired-dwim.el
;; goes further and advises `dired-do-copy' to attach marked files to a
;; visible chat buffer — that pattern is deliberately not installed by
;; default here.

;;; Code:

(require 'dired)
(require 'elneo-room)

(defvar-local elneo-dired--pick-target nil
  "Room buffer whose draft this dired buffer attaches to, or nil.")

(defcustom elneo-dired-auto-target-visible-room nil
  "Non-nil: send straight to the one visible room buffer when unambiguous.
Applies to `elneo-dired-send-files' and
`elneo-image-dired-send-file' when dired has exactly one room
buffer visible on screen: that room is the target without
prompting.  Off by default — the room is asked for (completion
over all accounts) whatever is on screen; the picker flow
\(\\[elneo-room-attach-dired] and `C-c C-a' in it) never prompts
and never needs this: it keeps its own target buffer."
  :type 'boolean
  :group 'elneo)

(defun elneo-dired--attachable-files (files)
  "FILES filtered down to attachable ones.
Directories are skipped with a message (the daemon cannot upload
them); anything not a plain string path goes too."
  (let (ok)
    (dolist (file files)
      (cond
       ((not (stringp file))
        (message "Matrix: not attaching %S" file))
       ((file-directory-p file)
        (message "Matrix: not attaching directory %s" file))
       (t (push file ok))))
    (nreverse ok)))

(defun elneo-dired--target-room ()
  "Return the room record to send to.
With `elneo-dired-auto-target-visible-room' set and exactly one
room buffer visible, that room; otherwise prompt over all
accounts' rooms."
  (let ((visible '()))
    (dolist (buffer (buffer-list))
      (when (and (elneo-buffer-visible-p buffer)
                 (eq (buffer-local-value 'major-mode buffer) 'elneo-room-mode))
        (push buffer visible)))
    (if (and elneo-dired-auto-target-visible-room (= (length visible) 1))
        (with-current-buffer (car visible)
          (or (elneo-room-get elneo-room--profile elneo-room--room-id)
              ;; A live rendered room is always in the registry; the
              ;; rebuilt-from-locals record is belt and braces.
              (list :profile elneo-room--profile
                    :room-id elneo-room--room-id
                    :display-name (buffer-name))))
      (elneo-completing-read-room))))

(defun elneo-dired-pick-for-buffer (room-buffer dir)
  "Open dired on DIR as a file picker for ROOM-BUFFER.
Mark files (\\[dired-mark]) and press
\\[elneo-dired--attach-marked] to insert their attach tags into
that room's draft.  The binding is local to the dired buffer: no
global dired key changes, and the picker dies with the buffer."
  (let ((dired-buffer (dired-noselect dir)))
    (with-current-buffer dired-buffer
      (setq elneo-dired--pick-target room-buffer)
      (local-set-key (kbd "C-c C-a") #'elneo-dired--attach-marked))
    (switch-to-buffer dired-buffer)
    (message "Matrix: mark files, C-c C-a to attach to %s"
             (buffer-name room-buffer))
    dired-buffer))

(defun elneo-dired--attach-marked ()
  "Attach the marked files to the picker room's draft and close dired.
The tags land at the end of the draft; this dired buffer — opened by
the room via `elneo-dired-pick-for-buffer' — is killed once its
job is done, and the window switches back to the room.  Point-off
directory lines are skipped with a message; if nothing attachable
remains, nothing is attached and dired stays open."
  (interactive)
  (unless (buffer-live-p elneo-dired--pick-target)
    (user-error "This dired buffer is not a Matrix file picker"))
  (let ((target elneo-dired--pick-target)
        (dired-buffer (current-buffer))
        (files (elneo-dired--attachable-files (dired-get-marked-files))))
    (if (null files)
        (user-error "No attachable files (marked or at point)")
      (with-current-buffer target
        (dolist (file files)
          (elneo-room--insert-attach-tag file))))
    (switch-to-buffer target)
    (message "Matrix: attached %d file%s to %s; dired closed"
             (length files) (if (= (length files) 1) "" "s")
             (buffer-name target))
    (kill-buffer dired-buffer)))

(defun elneo-dired--report (profile event)
  "Report a failed send from dired for PROFILE."
  (unless (alist-get '@ok event nil nil #'equal)
    (message "Matrix [%s] send failed: %s"
             profile (elneo-server--error-string event))))

;;;###autoload
(defun elneo-dired-send-files (files &optional room scale)
  "Send FILES (paths) to a Matrix ROOM record.
Interactively, use the marked files (or the file at point when
nothing is marked — `dired-get-marked-files'), skipping
directories, and pick the room with `elneo-dired--target-room'.
A prefix argument asks once for an image scale (a longest-edge
size like 1920 or a percentage like 50%) applied to every image
in the batch; empty input at the prompt sends the originals.
Without one, an image over `elneo-image-oversize-limit' is asked
about first.  Non-interactively, FILES is the list, ROOM
the room record and SCALE the spec (or nil — see
`elneo-room-image')."
  (interactive
   (let ((files (elneo-dired--attachable-files (dired-get-marked-files))))
     (list files nil
           ;; The scale prompt deliberately fires before the room
           ;; pick: the size decision comes first, whatever the
           ;; batch ends up.
           (and current-prefix-arg (elneo--scale-when-images files)))))
  (setq files (elneo-dired--attachable-files files))
  (unless files
    (user-error "No attachable files (marked or at point)"))
  ;; The size gate before the room pick, same rationale as the C-u
  ;; prompt above; a C-u that emptied it already said "originals".
  (unless (or scale current-prefix-arg)
    (setq scale (elneo--scale-oversize-answer files)))
  (let* ((room (or room (elneo-dired--target-room)))
         (profile (plist-get room :profile))
         (room-id (plist-get room :room-id))
         (name (or (plist-get room :display-name) room-id)))
    (dolist (file files)
      (unless (stringp file)
        (user-error "Not a file path: %S" file))
      (message "Matrix: sending %s to %s" (file-name-nondirectory file) name)
      (elneo-room-file profile room-id
                       (expand-file-name file)
                       (lambda (_profile event)
                         (elneo-dired--report profile event))
                       nil scale))))

(defvar image-dired-display-image-buffer) ; image-dired's name; no require here

(defvar-local elneo-image-dired--displayed-file nil
  "Original file behind the image in an image-dired display buffer.
Stock image-dired visited the displayed file up to Emacs 30, so
`buffer-file-name' knew it; Emacs 31 instead erases the display
buffer and inserts the file's raw bytes (`image-mode' renders
them from `:data') and keeps no record of the path whatever — the
advice below writes it here.")

(defun elneo-image-dired--record-displayed-file (file &optional _ignored)
  "Remember FILE as the original behind the image-dired display buffer.
Emacs 31's `image-dired-display-image' copies the file's bytes
into the unvisited display buffer and drops the path entirely;
recording it here gives the resolver what `buffer-file-name' used
to hold.  On older Emacsen the buffer is file-backed anyway, so
the record is redundant but harmless."
  (when-let* ((buf (get-buffer image-dired-display-image-buffer)))
    (with-current-buffer buf
      (setq elneo-image-dired--displayed-file file))))

(with-eval-after-load 'image-dired
  (advice-add 'image-dired-display-image :after
              #'elneo-image-dired--record-displayed-file))

(defun elneo-image-dired--original-file ()
  "The original image file at point in an image-dired buffer, or nil.
The thumbnail buffer answers via its `original-file-name' text
property; point between thumbnails (the space after one) falls
back to the nearest thumbnail at or before point by walking the
property-run boundaries backward.  A file-visiting image buffer
answers through `buffer-file-name': up to Emacs 30, the display
buffer is precisely that — `image-dired-display-image' visits the
file and renames the buffer.  The pre-29 display buffer instead
holds a resized temp copy, unvisited, and records the real
original as an `original-file-name' property on the image it
inserted; the mode symbol only exists on those Emacsen, so
`derived-mode-p' simply never matches it elsewhere.  Emacs 31's
display buffer holds the file's raw bytes in an unvisited buffer
with no record of the path at all — only the display-recording
advice knows it, via `elneo-image-dired--displayed-file'."
  (cond
   ;; Emacs 29–30 display buffers are file-visiting (image-mode-
   ;; derived; `image-dired-display-image-mode' is even a function
   ;; alias of `image-dired-image-mode' there).  A nil
   ;; `buffer-file-name' falls through: only a file-backed image
   ;; buffer answers here.
   ((and (derived-mode-p 'image-mode) buffer-file-name) buffer-file-name)
   ((derived-mode-p 'image-dired-thumbnail-mode)
    (let ((pos (point)) got)
      (while (and pos (not (setq got (get-text-property
                                      pos 'original-file-name))))
        (setq pos (if (<= pos 1) nil
                    (let ((prev (previous-single-property-change
                                 pos 'original-file-name)))
                      ;; The boundary at POS itself counts as
                      ;; \"previous\"; step off it so the walk
                      ;; advances.
                      (if (and prev (< prev pos)) prev (1- pos))))))
      got))
   ;; The pre-29 display buffer: unvisited (`buffer-file-name' is
   ;; nil), one image per buffer, original in the property.
   ((derived-mode-p 'image-dired-display-image-mode)
    (or (get-text-property (point) 'original-file-name)
        ;; Point moved off the image after display: it sits at
        ;; point-min, where image-dired left it.
        (get-text-property (point-min) 'original-file-name)))
   ;; Emacs 31's display buffer: unvisited raw file bytes, mode
   ;; image-dired-image-mode, no property — the advice's record is
   ;; the only place the original survives.  It is buffer-local to
   ;; the display buffer and set on every display.
   (elneo-image-dired--displayed-file)))

;;;###autoload
(defun elneo-send-buffer-file ()
  "Send the file behind the current buffer to a Matrix room.
Works on any file-visiting buffer and on image-dired buffers: the
thumbnail at point resolves like `elneo-image-dired-send-file',
and the image display buffer resolves through its original file --
visited on Emacsen 29–30, an `original-file-name' property on the
displayed image by earlier image-dired, and on Emacs 31 a path
recorded by elneo's post-display advice (its display buffer holds
the raw bytes, unvisited).  The room
is picked exactly like `elneo-dired-send-files'
\(completing-read, or the one visible room under
`elneo-dired-auto-target-visible-room'), and the file goes out
immediately, no draft involved.  A prefix argument asks once for
an image scale, exactly like `elneo-dired-send-files'.

A buffer with unsaved edits sends the version on disk — the daemon
reads the path, not the Emacs buffer's state; you are reminded."
  (interactive)
  ;; No image-dired require: the resolver uses text properties, not
  ;; image-dired's API, and a thumbnail buffer only exists while it is
  ;; loaded.
  (let ((file (or buffer-file-name (elneo-image-dired--original-file))))
    (unless file
      (if (derived-mode-p 'image-dired-thumbnail-mode)
          (user-error "No image at point — put point on a thumbnail")
        (user-error "No file behind this buffer — in dired use `elneo-dired-send-files'")))
    (when (and buffer-file-name (buffer-modified-p))
      (message "Matrix: buffer has unsaved edits — the version on disk is sent"))
    ;; A prefix argument scales images (a file-visiting buffer or an
    ;; image-dired resolution can name one; a non-image path just
    ;; sends unscaled, no prompt).
    (elneo-dired-send-files (list file) nil
                            (and current-prefix-arg
                                 (elneo--scale-when-images (list file))))))

;;;###autoload
(defun elneo-image-dired-send-file ()
  "Send the image at point in an image-dired buffer to a Matrix room.
A specialization of `elneo-send-buffer-file', which also takes
file-visiting buffers and the image display buffer."
  (interactive)
  (elneo-send-buffer-file))

;;;###autoload
(defun elneo-media-cache-dired (profile)
  "Open PROFILE's daemon media cache in dired.
Downloaded media live there as plain files, keyed by media id —
dired's browse/mark/delete/open (with ready-player) all work."
  ;; Load the account list in the spec — completing-read with
  ;; REQUIRE-MATCH and an empty collection is a prompt with no exit.
  (interactive
   (progn (elneo--accounts-load)
          (unless elneo-accounts
            (user-error "No Matrix profiles registered"))
          (list (completing-read "Profile: "
                                 (mapcar #'car elneo-accounts) nil t))))
  (let ((dir (file-name-concat (elneo--daemon-data-dir profile) "media")))
    (if (file-directory-p dir)
        (dired dir)
      (user-error "No media downloaded yet for profile %s" profile))))

(provide 'elneo-dired)
;;; elneo-dired.el ends here
