;;; elneo-image.el --- full-size image viewer over room history -*- lexical-binding: t; -*-

;;; Commentary:

;; Port of telega-image-mode (telega-modes.el) to elneo.el: open any
;; image message full-size and walk the room's photo messages with
;; n / p, with a modeline [n/total].  The image list is seeded from
;; the room buffer's rendered history (instant) and extended older
;; through filtered history pagination (getRoomMessages :filter
;; "image" — the counterpart of telega's searchMessagesFilterPhoto).
;; Telega asks TDLib's getChatMessageCount for an exact total; Matrix
;; has no equivalent, so the total is what the walk has seen so far
;; and a "+" suffix marks it approximate until the walk reaches the
;; start of history.

;;; Code:

(require 'cl-lib)
(require 'elneo-client)
(require 'elneo-room)

(defgroup elneo-image nil
  "Full-size image viewer over a room's photo history."
  :group 'elneo)

(defcustom elneo-image-page-limit 100
  "Events requested per older page in the photo walk.
The page narrows to pictures server-side (the daemon keeps the
m.image and m.sticker entries); this bounds how much history one
request scans."
  :group 'elneo-image
  :type 'natnum)

(defcustom elneo-image-walk-cap 30
  "Chained requests one background photo walk may make.
The cap keeps `v' from hammering a huge room's history the moment
the viewer opens.  When the cap stops the walk, the pagination
token is kept and `p' at the oldest image resumes from there.
0 disables the background walk altogether."
  :group 'elneo-image
  :type 'natnum)

(defvar-local elneo-image--room-buffer nil
  "Room buffer this viewer was opened from.")

(defvar-local elneo-image--profile nil
  "Profile of the walked room.
Kept independent of the room buffer so the walk survives the room
buffer being killed.")

(defvar-local elneo-image--room-id nil
  "Room id of the walked room.")

(defvar-local elneo-image--images nil
  "The room's image message plists, oldest first.
Seeded from the room buffer's rendered history, extended by the
filtered older-page walk.")

(defvar-local elneo-image--current-id nil
  "Event id of the displayed image message.")

(defvar-local elneo-image--token nil
  "Backward pagination token of the filtered photo walk.
One token space as the room buffer's unfiltered walk paginates: a
token is a homeserver stream position, so `--open' seeds this walk
from the room buffer's `elneo-room--end-token' — no gap, no
overlap with the seed.  The rule is directional (see
`elneo-room-messages'): the filtered walk's END token continues
this walk and must never feed the room buffer's normal pagination,
whose insert-at-top contiguity a page of skipped messages breaks.")

(defvar-local elneo-image--generation 0
  "Bumped by every `elneo-image--open'.
Walk pages carry the generation they went out under; a page of a
superseded walk discards — the same late-arrival class the
display path guards with `elneo-image--current-id'.")
;; A mode re-entry (the viewer buffer is reused) would reset the
;; counter to its default and make every walk generation equal
;; again; `--open' needs the superseded walks' value to differ.
(put 'elneo-image--generation 'permanent-local t)

(defvar-local elneo-image--exhausted nil
  "t when the photo walk reached the start of history.")

(defvar-local elneo-image--walk-left 0
  "Requests left in the current background walk.
Counts down from `elneo-image-walk-cap'; 0 with a live token
means the cap stopped the walk (a walk failure also stops it).")

(defvar-local elneo-image--loading nil
  "t while an older-page request is in flight.")

(defvar-local elneo-image--opened-window nil
  "Window the viewer was opened in; `elneo-image-quit' returns the
room there.")

(defvar-local elneo-image--zoom 1.0
  "Display scale factor; 1.0 fits the window.")

(defvar-local elneo-image--file nil
  "Cache path of the downloaded full-size file on display.")

(defvar-local elneo-image--downloading nil
  "t while the full-size file of the current image is downloading.")

(defvar-local elneo-image--last-ts nil
  "Timestamp of the image `--show' last rendered successfully.
Kept when the image vanishes (redacted mid-browse), so the rescue
lands on its ts-nearest survivor.")

;;; Mode

(defvar elneo-image-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map "n" #'elneo-image-next)
    (define-key map "p" #'elneo-image-prev)
    (define-key map "o" #'elneo-image-open-externally)
    (define-key map "+" #'elneo-image-zoom-in)
    (define-key map "-" #'elneo-image-zoom-out)
    (define-key map "0" #'elneo-image-fit)
    (define-key map "q" #'elneo-image-quit)
    map)
  "Keymap of `elneo-image-mode'.  Scrolling keys (SPC, DEL, mouse
wheel) come from `special-mode-map'.")

;;;###autoload
(define-derived-mode elneo-image-mode special-mode "Matrix image"
  "Full-size image viewer over a room's photo history.
\\{elneo-image-mode-map}
`n' / `p' step through the room's image messages (newer / older),
loading older photos through filtered history pagination when the
rendered history runs out.  The modeline shows [position/total]
with a `+' while older images may still exist."
  (setq buffer-read-only t))

;;; Entry from the room buffer

;;;###autoload
(defun elneo-image-view-at-point ()
  "Open the image message at point full-size in the image viewer.
Only real photo messages open here (`m.image` from the room
history); rich-body embedded images and non-image media stay with
`o', which hands the file to `elneo-open-file-function'."
  (interactive)
  (let* ((pos (or (and (get-text-property (point) 'elneo-room-media-data)
                       (point))
                  ;; Point one char past the image glyph still reads as
                  ;; "on the picture" to a human.
                  (and (> (point) (point-min))
                       (get-text-property (1- (point)) 'elneo-room-media-data)
                       (1- (point)))))
         (event-id (and pos (elneo-room--event-id-at pos)))
         (msg (and event-id (gethash event-id elneo-room--seen))))
    (cond ((null msg) (user-error "No image at point"))
          ((not (elneo-room--picture-p (plist-get msg :msgtype)))
           (user-error "Not an image message (o opens media externally)"))
          (t (elneo-image--open (current-buffer) event-id)))))

(defun elneo-image--room-label (room-buffer)
  "Human label for ROOM-BUFFER: room display name, buffer name fallback."
  (let* ((profile (buffer-local-value 'elneo-room--profile room-buffer))
         (room-id (buffer-local-value 'elneo-room--room-id room-buffer))
         (record (elneo-room-get profile room-id))
         (name (plist-get record :display-name)))
    (or (and name (not (equal name "")) name)
        (buffer-name room-buffer))))

(defun elneo-image--buffer (room-buffer)
  "Live viewer buffer for ROOM-BUFFER, created if needed."
  (let* ((name (format "*Matrix image: %s*"
                       (elneo-image--room-label room-buffer)))
         (buffer (get-buffer name)))
    (if (buffer-live-p buffer) buffer (generate-new-buffer name))))

(defun elneo-image--open (room-buffer event-id)
  "Open EVENT-ID of ROOM-BUFFER in the viewer, seeding the photo list."
  (let* ((buffer (elneo-image--buffer room-buffer))
         (profile (buffer-local-value 'elneo-room--profile room-buffer))
         (room-id (buffer-local-value 'elneo-room--room-id room-buffer))
         ;; The room buffer's end token is the raw-walk position at the
         ;; oldest rendered message — the correct starting point for the
         ;; filtered walk (no gap, no overlap with the seed).
         ;; No token at all: history is exhausted, the seed is complete.
         (token (buffer-local-value 'elneo-room--end-token room-buffer)))
    (with-current-buffer buffer
      (elneo-image-mode)
      (setq elneo-image--room-buffer room-buffer
            elneo-image--profile profile
            elneo-image--room-id room-id
            elneo-image--images (elneo-image--room-images room-buffer)
            elneo-image--current-id event-id
            elneo-image--token token
            elneo-image--exhausted (null token)
            elneo-image--walk-left elneo-image-walk-cap
            elneo-image--loading nil
            elneo-image--zoom 1.0
            elneo-image--file nil
            elneo-image--downloading nil
            elneo-image--generation (1+ elneo-image--generation)
            mode-line-format '(:eval (elneo-image--mode-line)))
      (switch-to-buffer buffer)
      ;; The window this switch landed in: `elneo-image-quit' returns
      ;; the room there instead of hijacking whatever shows the room.
      (setq elneo-image--opened-window (selected-window))
      (elneo-image--show)
      (unless elneo-image--exhausted
        (elneo-image--walk-older)))))

;;; Image list plumbing

(defun elneo-image--image-p (msg)
  "Non-nil when message plist MSG renders a picture with media.
Stickers count: they are pictures carrying the same media entry."
  (and (elneo-room--picture-p (plist-get msg :msgtype))
       (plist-get msg :media)
       msg))

(defun elneo-image--room-images (room-buffer)
  "Image messages of ROOM-BUFFER's rendered history, oldest first.
Walks the buffer (screen order, including prepended older pages)
and keeps the seen-table plists; the seed is instant and needs no
daemon round-trip."
  (with-current-buffer room-buffer
    (delq nil
          (mapcar (lambda (id)
                    (let ((msg (gethash id elneo-room--seen)))
                      (and msg (elneo-image--image-p msg))))
                  (elneo-room--ordered-event-ids)))))

(defun elneo-image--merge-images (old new)
  "Merge image lists OLD and NEW, deduped by event id, oldest first."
  (let ((by-id (make-hash-table :test 'equal)))
    (dolist (img (append old new))
      (puthash (plist-get img :event-id) img by-id))
    (sort (hash-table-values by-id)
          (lambda (a b) (< (or (plist-get a :ts) 0)
                           (or (plist-get b :ts) 0))))))

(defun elneo-image--current-index ()
  "Index of the displayed image in `elneo-image--images', or nil."
  (cl-position elneo-image--current-id elneo-image--images
               :key (lambda (m) (plist-get m :event-id)) :test #'equal))

(defun elneo-image--current-msg ()
  "Message plist of the displayed image, or nil (redacted away)."
  (cl-find elneo-image--current-id elneo-image--images
           :key (lambda (m) (plist-get m :event-id)) :test #'equal))

(defun elneo-image--goto (index)
  "Display `elneo-image--images' element at INDEX."
  (setq elneo-image--current-id
        (plist-get (nth index elneo-image--images) :event-id))
  (elneo-image--show))

(defun elneo-image--nearest-index (ts)
  "Index of the image with timestamp nearest TS, or nil when empty."
  (when elneo-image--images
    (let ((best 0) (best-d most-positive-fixnum) (i 0))
      (dolist (m elneo-image--images)
        (let ((d (abs (- (or (plist-get m :ts) 0) (or ts 0)))))
          (when (< d best-d) (setq best-d d best i)))
        (setq i (1+ i)))
      best)))

(defun elneo-image--escape-ghost ()
  "Escape a vanished displayed image (redacted while browsing).
The id is no longer in the collection and a nil index would stick
on the \"no longer available\" placeholder for every n and p; land
on the ts-nearest survivor — the position is lost, so `--last-ts'
is the recovery key.  Nothing left: the placeholder view."
  (elneo-image--sync-newer)
  (if elneo-image--images
      (elneo-image--goto
       (elneo-image--nearest-index elneo-image--last-ts))
    (elneo-image--show)))

(defun elneo-image--pruned (images room-buffer)
  "Without the IMAGES entries ROOM-BUFFER's seen table has redacted.
Redactions replace the seen entry with a plain marker
(`--on-redaction'), so a picture whose seen entry is no longer a
picture is gone; entries absent from the seen table (walked pages,
older history the room buffer does not mirror) are kept."
  (if (not (buffer-live-p room-buffer))
      images
    (with-current-buffer room-buffer
      (let (kept)
        (dolist (img images)
          (let ((seen (gethash (plist-get img :event-id)
                               elneo-room--seen)))
            (when (or (not seen) (elneo-image--image-p seen))
              (push img kept))))
        (reverse kept)))))

(defun elneo-image--sync-newer ()
  "Merge images newer than the walk has seen from the room buffer.
The room buffer keeps growing through live sync; the viewer checks
when `n' runs past its newest.  A redaction the room has applied
drops the image here too — the merge alone would keep the stale
copy browsable for as long as the viewer stays open."
  (when (buffer-live-p elneo-image--room-buffer)
    (setq elneo-image--images
          (elneo-image--merge-images
           (elneo-image--pruned elneo-image--images
                                elneo-image--room-buffer)
           (elneo-image--room-images elneo-image--room-buffer)))))

;;; Older pages (filtered pagination)

(defun elneo-image--walk-older ()
  "Request the next older photo page, when the walk may continue."
  (when (and elneo-image--token
             (not elneo-image--exhausted)
             (not elneo-image--loading)
             (> elneo-image--walk-left 0))
    (setq elneo-image--loading t)
    (let ((buffer (current-buffer))
          (generation elneo-image--generation))
      (elneo-room-messages
       elneo-image--profile elneo-image--room-id
       elneo-image-page-limit elneo-image--token
       (lambda (_profile event)
         (when (and (buffer-live-p buffer)
                    ;; A re-open since this page went out reset all
                    ;; walk state for a new walk — a stale page of
                    ;; the old one discards (its END token would
                    ;; clobber the new walk's, on a room with the
                    ;; same viewer buffer even for another room).
                    (eql (buffer-local-value
                          'elneo-image--generation buffer)
                         generation))
           (with-current-buffer buffer (elneo-image--on-page event))))
       "image"))))

(defun elneo-image--on-page (event)
  "Handle one filtered history page EVENT in the viewer."
  (setq elneo-image--loading nil)
  (if (not (alist-get '@ok event nil nil #'equal))
      ;; Keep the token: `p' at the oldest image retries.  The budget
      ;; is not spent on failures, only on real pages.
      (message "Matrix image walk failed: %s"
               (elneo-server--error-string event))
    (let* ((entries (mapcar #'elneo-room--message-from-entry
                            (alist-get 'messages event)))
           (images (delq nil (mapcar #'elneo-image--image-p entries)))
           (end (alist-get 'end event)))
      (setq elneo-image--images
            (elneo-image--merge-images elneo-image--images images)
            elneo-image--token end
            elneo-image--exhausted (null end)
            elneo-image--walk-left (1- elneo-image--walk-left))
      ;; Chain within the cap: a page of text messages must not pause
      ;; the photo walk until the user presses p again.
      (elneo-image--walk-older))))

;;; Display

(defun elneo-image--fit-size ()
  "Pixel (width . height) the current image is scaled to fit into.
The viewer's window text area at 1.0 zoom; with the viewer in no
window, the selected window's (`--insert-file' runs from the
download callback's process filter, with whatever the user looks
at selected)."
  (let ((win (get-buffer-window (current-buffer) t)))
    (cons (max 16 (round (* (window-width win t) elneo-image--zoom)))
          (max 16 (round (* (window-height win t) elneo-image--zoom))))))

(defun elneo-image--file-name (msg)
  "Display file name of image message MSG (filename field or body)."
  (or (alist-get 'filename (plist-get msg :media))
      (plist-get msg :body)
      "image"))

(defun elneo-image--show ()
  "Render the current image message into the viewer."
  (let* ((msg (elneo-image--current-msg))
         (inhibit-read-only t))
    (erase-buffer)
    (setq elneo-image--file nil
          elneo-image--downloading nil)
    (when msg
      (setq elneo-image--last-ts (plist-get msg :ts)))
    (cond
     ((null msg)
      (insert "[image no longer available]"))
     (t
      (setq elneo-image--downloading t)
      (insert (propertize "downloading image…" 'face 'shadow))
      (let* ((media (plist-get msg :media))
             (name (elneo-image--file-name msg))
             (buffer (current-buffer))
             (want elneo-image--current-id))
        (elneo-download-media
         elneo-image--profile (alist-get 'source media) "file"
         (lambda (_profile event)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               ;; A late response of an image we already navigated past
               ;; would clobber the new display.
               (when (equal elneo-image--current-id want)
                 (setq elneo-image--downloading nil)
                 (if (and (alist-get '@ok event nil nil #'equal)
                          (alist-get 'path event))
                     (elneo-image--insert-file (alist-get 'path event))
                   (let ((inhibit-read-only t))
                     (erase-buffer)
                     (insert (propertize "[image unavailable]"
                                         'face 'shadow))))))))
         name))))
    (elneo-image--update-modeline)))

(defun elneo-image--insert-file (file)
  "Insert the full-size image FILE, fitted to the window."
  (let* ((fit (elneo-image--fit-size))
         (inhibit-read-only t)
         (img (create-image file nil nil :ascent 100
                            :max-width (car fit)
                            :max-height (cdr fit))))
    (setq elneo-image--file file)
    (erase-buffer)
    (insert-image img (or (elneo-image--file-name
                           (elneo-image--current-msg))
                          "image"))
    (insert "\n")
    (elneo-image--update-modeline)))

(defun elneo-image--refresh ()
  "Redisplay the downloaded file at the current zoom."
  (when elneo-image--file
    (elneo-image--insert-file elneo-image--file)))

(defun elneo-image--mode-line ()
  "Modeline: [position/total(+)] sender date filename."
  (let* ((index (elneo-image--current-index))
         (msg (elneo-image--current-msg))
         (total (length elneo-image--images))
         (pos (if index (format "%d/%d" (1+ index) total)
                (format "?/%d" total)))
         (more (and (not elneo-image--exhausted) "+")))
    (string-join
     (delq nil
           (list (format "[%s%s]" pos (or more ""))
                 (and msg (elneo-room--sender-name msg))
                 (and msg (format-time-string "%Y-%m-%d %H:%M"
                                              (/ (plist-get msg :ts) 1000)))
                 (and msg (elneo-image--file-name msg))
                 (and elneo-image--downloading "downloading...")))
     "  ")))

(defun elneo-image--update-modeline ()
  "Force a modeline redisplay of the viewer."
  (force-mode-line-update t))

;;; Commands

(defun elneo-image-next ()
  "Show the next (newer) image in the room."
  (interactive)
  (let ((index (elneo-image--current-index)))
    (cond
     ((null index) (elneo-image--escape-ghost))
     ;; Newest known image: the room buffer may hold newer ones that
     ;; arrived through live sync since the viewer opened.
     ((= index (1- (length elneo-image--images)))
      (elneo-image--sync-newer)
      (let ((index (elneo-image--current-index)))
        (cond
         ((null index) (elneo-image--escape-ghost))
         ((= index (1- (length elneo-image--images)))
          (message "No newer image"))
         (t (elneo-image--goto (1+ index))))))
     (t (elneo-image--goto (1+ index))))))

(defun elneo-image-prev ()
  "Show the previous (older) image in the room.
At the oldest image the walk continues (resumed when its request
cap stopped it) and new photos appear as they arrive."
  (interactive)
  (let ((index (elneo-image--current-index)))
    (cond
     ((null index) (elneo-image--escape-ghost))
     ((> index 0) (elneo-image--goto (1- index)))
     (elneo-image--loading (message "Fetching older images..."))
     (elneo-image--exhausted (message "No older image"))
     ;; Cap-stopped or failed walk: the token is still there, resume.
     (t (if (> elneo-image-walk-cap 0)
            (progn (setq elneo-image--walk-left elneo-image-walk-cap)
                   (elneo-image--walk-older)
                   (message "Fetching older images..."))
          ;; Cap 0 disables the walk; say so, don't pretend to fetch.
          (message "No older image (the photo walk is disabled)"))))))

(defun elneo-image-open-externally ()
  "Open the displayed image with `elneo-open-file-function'."
  (interactive)
  (if elneo-image--file
      (funcall elneo-open-file-function elneo-image--file)
    (message "Matrix: image not downloaded yet")))

(defun elneo-image-zoom-in ()
  "Scale the displayed image up by 1.5x (0 resets)."
  (interactive)
  (setq elneo-image--zoom (* elneo-image--zoom 1.5))
  (elneo-image--refresh))

(defun elneo-image-zoom-out ()
  "Scale the displayed image down by 1.5x (0 resets)."
  (interactive)
  (setq elneo-image--zoom (/ elneo-image--zoom 1.5))
  (elneo-image--refresh))

(defun elneo-image-fit ()
  "Reset the display to fit the window."
  (interactive)
  (setq elneo-image--zoom 1.0)
  (elneo-image--refresh))

(defun elneo-image-quit ()
  "Quit the viewer, returning to its room buffer.
The room goes back into the window the viewer was opened in, when
that window still shows the viewer; other windows are left alone.
A room already on screen in one of them is not doubled — the
viewer's window takes the next-most-recent buffer instead."
  (interactive)
  (let ((room elneo-image--room-buffer)
        (opened elneo-image--opened-window))
    (cond
     ;; The opening window is gone or repurposed: quit like any
     ;; special-mode viewer from wherever we are.
     ((and (buffer-live-p room)
           (window-live-p opened)
           (eq (window-buffer opened) (current-buffer)))
      ;; The room already on screen elsewhere is not doubled: the
      ;; bury could land right back on it, so the next-most-recent
      ;; buffer takes this window (room is visible, `other-buffer'
      ;; skips it).
      (if (get-buffer-window room t)
          (switch-to-buffer (or (other-buffer (current-buffer)) room))
        (switch-to-buffer room)))
     (t (quit-window)))))

;;; Avatar viewing

;; The avatar facts (room overview, account page) render thumbnails;
;; their buttons open the same picture here, full-size.  The full
;; file is a different media-cache entry than the avatar thumbnails:
;; `elneo-download-media' with format "file" fetches the original,
;; and since an avatar's mxc carries no file name the download lands
;; without an extension — the image type comes from the file's magic
;; bytes, not from its name.

(defvar-local elneo-avatar--profile nil
  "Buffer-local: the profile the viewed avatar belongs to.")

(defvar-local elneo-avatar--mxc nil
  "Buffer-local: the mxc of the avatar this buffer shows.")

(defvar-local elneo-avatar--file nil
  "Buffer-local: the downloaded full-size cache file, or nil while
the download is pending.")

(defvar-local elneo-avatar--failed nil
  "Buffer-local: the download failed; the placeholder becomes the
failure note and nothing re-fetches (the next opening of the view
tries again).")

(defvar elneo-avatar-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map "o" #'elneo-avatar-open-externally)
    map)
  "Keys of an avatar view; `q' comes from `special-mode'.")

(define-derived-mode elneo-avatar-mode special-mode "Matrix Avatar"
  "Major mode for a full-size avatar view.
The view's buttons live in the avatar facts (room overview,
account page): both the image and the mxc string open it.  \\[q]
buries, \\[elneo-avatar-open-externally] opens the file outside
Emacs.")

(defun elneo-avatar--fit-size ()
  "Pixel (width . height) the avatar is scaled to fit into.
The window's text area, like the image viewer's fit — but the
avatar is never enlarged beyond its natural size (`:max-width'
only shrinks), so a small picture shows as itself."
  (let ((win (get-buffer-window (current-buffer) t)))
    (cons (max 16 (window-width win t))
          (max 16 (window-height win t)))))

(defun elneo-avatar--sniff-type (file)
  "Image type symbol of FILE by its magic bytes, or nil.
The full-file download has no extension for `create-image' to go
by (the type argument accepts `png', `jpeg', `gif', `webp').  An
unreadable file sniffs as nil — `create-image' still gets a spec
and says the real problem at display time."
  (let ((bytes (ignore-errors
                 (with-temp-buffer
                   (set-buffer-multibyte nil)
                   (insert-file-contents-literally file nil 0 12)
                   (buffer-string)))))
    (cond
     ((string-prefix-p (unibyte-string 137 80 78 71) bytes) 'png)
     ((string-prefix-p (unibyte-string 255 216 255) bytes) 'jpeg)
     ((string-prefix-p "GIF8" bytes) 'gif)
     ((and (string-prefix-p "RIFF" bytes) (>= (length bytes) 12)
           (equal (substring bytes 8 12) "WEBP"))
      'webp))))

(defun elneo-avatar--render (file)
  "Render the avatar view for `elneo-avatar--mxc'.
FILE is the downloaded full-size cache file, displayed fitted to
the window; nil renders the waiting line, or the failure note once
a download ran and failed.  A frame that cannot display images
keeps the cache file's path instead — the picture is still
downloaded, only not drawn."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (format "Matrix avatar %s\n\n" elneo-avatar--mxc))
    (cond
     ((and file (display-graphic-p))
      (let ((fit (elneo-avatar--fit-size)))
        (insert (propertize
                 "    "
                 'display (create-image file (elneo-avatar--sniff-type file)
                                        nil :max-width (car fit)
                                        :max-height (cdr fit))))))
     (file
      (insert (propertize
               "This Emacs does not display images; the file is in the media cache:"
               'face 'shadow))
      (insert "\n  " (abbreviate-file-name file) "\n"))
     (elneo-avatar--failed
      (insert (propertize "[avatar unavailable — download failed]"
                          'face 'shadow)))
     (t (insert (propertize "downloading…" 'face 'shadow))))
    (insert "\n")))

(defun elneo-avatar-open-externally ()
  "Open the displayed avatar with `elneo-open-file-function'."
  (interactive)
  (if elneo-avatar--file
      (funcall elneo-open-file-function elneo-avatar--file)
    (message "Matrix: avatar not downloaded yet")))

(defun elneo-avatar-show (profile mxc)
  "Display PROFILE's avatar MXC full-size in its own buffer.
The view opens through the avatar facts' buttons (both the image
and the mxc string run it) or from M-x.  `q' buries, `o' opens the
downloaded file outside Emacs.  A missing or empty mxc has nothing
to show; a dead daemon fails the view's download (the view stays,
saying so)."
  (interactive
   (progn (elneo--accounts-load)
          (unless elneo-accounts
            (user-error "No Matrix profiles registered"))
          (list (completing-read "Profile: "
                                 (mapcar #'car elneo-accounts) nil t)
                (read-string "Avatar mxc: "))))
  (unless (and mxc (not (string-empty-p mxc)))
    (user-error "No avatar to show"))
  (let ((buffer (get-buffer-create (format "*Matrix Avatar: %s*" profile))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'elneo-avatar-mode)
        (elneo-avatar-mode))
      (setq elneo-avatar--profile profile
            elneo-avatar--mxc mxc
            elneo-avatar--failed nil
            elneo-avatar--file nil)
      ;; The placeholder first: the download's callback (which fires
      ;; synchronously for an already-cached file) must find the view
      ;; in shape, not clobber it with the waiting render.
      (elneo-avatar--render nil))
    (elneo-download-media profile `((url . ,mxc)) "file"
                          (lambda (_p event)
                            ;; A late arrival into a dead buffer is nothing; a dead
                            ;; daemon answers as a failed download.  The view may have
                            ;; been re-shown for another avatar since (one buffer per
                            ;; profile): the mxc the answer is for is the identity — an
                            ;; old download's answer discards, its failure note must not
                            ;; flash for the newer request either.
                            (when (and (buffer-live-p buffer)
                                       (equal (buffer-local-value 'elneo-avatar--mxc buffer)
                                              mxc))
                              (with-current-buffer buffer
                                (let ((path (and (alist-get '@ok event nil nil #'equal)
                                                 (alist-get 'path event nil nil #'equal))))
                                  (if (and (stringp path) (not (string-empty-p path)))
                                      (progn
                                        (setq elneo-avatar--file path)
                                        (elneo-avatar--render path))
                                    (setq elneo-avatar--failed t)
                                    (elneo-avatar--render nil))))))
                          nil)
    ;; Display belongs to the command: but only when the view is
    ;; nowhere on screen — a show of an avatar the user is already
    ;; looking at never jumps the windows around.
    (unless (get-buffer-window buffer t)
      (pop-to-buffer buffer))
    ;; A cached file landed while the view had no window to fit
    ;; into; re-rendering now fits the window it is shown in.
    (with-current-buffer buffer
      (when elneo-avatar--file
        (elneo-avatar--render elneo-avatar--file)))))

(provide 'elneo-image)
;;; elneo-image.el ends here
