;;; video-preview-test.el --- inline video thumbnails (the thumb-source gate) -*- lexical-binding: t; -*-

;; A thumbnailed video previews like a picture: `elneo-room--insert-body'
;; renders a placeholder the fetch scan fills from the sender's
;; thumbnail, with the download-on-demand tag kept under it so the
;; message still reads as a video and open/save stay put.  The gate is
;; `thumb_source' on the media entry — the chooser then resolves to a
;; small image and never to a thumbnailing attempt on the video mxc
;; itself nor to a whole-video download.  Daemon stubbed at
;; `elneo-download-media'; `create-image' stubbed so the replacement is
;; observable in batch.
;;
;; Run: emacs -Q --batch -L lisp -l test/video-preview-test.el

(require 'elneo-room)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defun mx-video-media ()
    "An m.video media alist: sender thumbnail + full metadata."
    '((source (url . "mxc://hs/vid"))
      (thumb_source (url . "mxc://hs/vidthumb"))
      (mimetype . "video/mp4")
      (filename . "clip.mp4")
      (size . 1234567)
      (duration . 65000)))

  (defun mx-video-room ()
    (let ((buf (get-buffer-create " *mx-video-room*")))
      (with-current-buffer buf
        (elneo-room-mode)
        (setq elneo-room--profile "mxtest"
              elneo-room--room-id "!r:mxtest.org"
              elneo-room--seen (make-hash-table :test 'equal)
              elneo-room--media-pending (make-hash-table :test 'equal)
              elneo-room--end-token nil)
        (elneo-room--header (list :display-name "Video Room"
                                  :room-id "!r:mxtest.org")))
      buf))

  (defun mx-append-video (media)
    "Append one video message at the buffer's newest end."
    (goto-char (point-max))
    (elneo-room--append-messages
     (list (list :event-id "$v1"
                 :ts (* 1000 (time-to-seconds
                              (encode-time '(0 0 12 13 10 2026))))
                 :sender "@a:mx.org" :is-own nil
                 :msgtype "m.video" :body "holiday clip"
                 :media media)))
    (elneo-room--reset-input-area ""))

  ;; 1. the gate predicate and what falls either side of it
  (mx-check "gate: a sender thumbnail previews"
            (and (elneo-room--video-preview-p
                  "m.video" '((source (url . "mxc://hs/v"))
                              (thumb_source (url . "mxc://hs/vt")))) t)
            t)
  (mx-check "gate: no thumbnail keeps the plain tag"
            (elneo-room--video-preview-p "m.video" '((source (url . "mxc://hs/v"))))
            nil)
  (mx-check "gate: pictures are not video previews"
            (elneo-room--video-preview-p
             "m.image" '((thumb_source (url . "mxc://hs/t"))))
            nil)
  (mx-check "gate: files are not video previews"
            (elneo-room--video-preview-p
             "m.file" '((thumb_source (url . "mxc://hs/t"))))
            nil)
  (mx-check "mimetype: video recognized"
            (elneo-room--video-media-p '((mimetype . "video/webm"))) t)
  (mx-check "mimetype: images keep the image label"
            (elneo-room--video-media-p '((mimetype . "image/jpeg"))) nil)

  ;; 2. the chooser never asks for the video itself when a thumb rides
  ;; along: plain thumb → thumb format; plain thumb inside an
  ;; encrypted room (encrypted source) → still the plain thumb;
  ;; encrypted thumb → "file" (the daemon decrypts it).
  (mx-check "chooser: plain thumb wins"
            (elneo-room--media-fetch-args (mx-video-media))
            '(((url . "mxc://hs/vidthumb")) . "thumb"))
  (mx-check "chooser: plain thumb beats the encrypted video"
            (elneo-room--media-fetch-args
             '((source (file . ((url . "mxc://hs/v") (iv . "ab"))))
               (thumb_source (url . "mxc://hs/vt"))))
            '(((url . "mxc://hs/vt")) . "thumb"))
  (mx-check "chooser: the encrypted thumb decrypts"
            (elneo-room--media-fetch-args
             '((source (file . ((url . "mxc://hs/v") (iv . "ab"))))
               (thumb_source (file . ((url . "mxc://hs/vt") (iv . "cd"))))))
            '(((file . ((url . "mxc://hs/vt") (iv . "cd")))) . "file"))

  ;; 3. render shape: the name line, the placeholder line, the tag line
  (let ((buf (mx-video-room)))
    (unwind-protect
        (with-current-buffer buf
          (mx-append-video (mx-video-media))
          (goto-char (point-min))
          (let ((placeholder
                 (and (search-forward "[video: holiday clip]" nil t)
                      (match-beginning 0)))
                (tag-pos
                 (progn (goto-char (point-min))
                        (and (search-forward
                              "[video: clip.mp4 (1.2 MiB, 1:05)]" nil t)
                             (match-beginning 0)))))
            (mx-check "render: the tag line follows the preview"
                      (and placeholder tag-pos (< placeholder tag-pos)) t)
            (mx-check "render: the placeholder fetches"
                      (get-text-property placeholder 'elneo-room-media-thumb) t)
            (mx-check "render: the placeholder's media is video media"
                      (get-text-property placeholder 'elneo-room-media-data)
                      (mx-video-media))
            (mx-check "render: the placeholder tracks the event"
                      (get-text-property placeholder 'elneo-room-event-id) "$v1")
            (mx-check "render: the tag does not re-fetch"
                      (get-text-property tag-pos 'elneo-room-media-thumb) nil)
            (mx-check "render: the tag opens the full video"
                      (alist-get 'filename
                                 (get-text-property tag-pos 'elneo-room-media-data))
                      "clip.mp4")
            (mx-check "render: the name line is marked"
                      (save-excursion
                        (goto-char placeholder)
                        (get-text-property (line-beginning-position 0)
                                           'elneo-room-name-line))
                      t)))
      (kill-buffer buf)))

  ;; 3b. an unnamed video previews the same way: the placeholder
  ;; carries the caption (the body), the tag line stays bare — the
  ;; caption belongs after the fetched frame, not in the tag.
  (let ((buf (mx-video-room)))
    (unwind-protect
        (with-current-buffer buf
          (mx-append-video
           '((source (url . "mxc://hs/vid"))
             (thumb_source (url . "mxc://hs/vidthumb"))
             (mimetype . "video/mp4")))
          (goto-char (point-min))
          (mx-check "unnamed: the caption rides the placeholder"
                    (and (search-forward "[video: holiday clip]" nil t) t) t)
          (goto-char (point-min))
          (mx-check "unnamed: the tag line carries no caption"
                    (and (search-forward "[video]" nil t) t) t)
          (goto-char (point-min))
          (mx-check "unnamed: the caption is not the media name"
                    (get-text-property
                     (progn (search-forward "[video: holiday clip]")
                            (match-beginning 0))
                     'elneo-room-media-name)
                    nil)
          (mx-check "unnamed: the caption rides as a caption"
                    (get-text-property
                     (progn (goto-char (point-min))
                            (search-forward "[video: holiday clip]")
                            (match-beginning 0))
                     'elneo-room-media-caption)
                    "holiday clip"))
      (kill-buffer buf)))

  ;; 4. the negative gate renders: no thumb → the same single tag as
  ;; today, and no fetchable span anywhere.
  (let ((buf (mx-video-room)))
    (unwind-protect
        (with-current-buffer buf
          (mx-append-video
           '((source (url . "mxc://hs/raw"))
             (mimetype . "video/webm")
             (filename . "raw.mp4")))
          (goto-char (point-min))
          (mx-check "no thumb: the tag is the only video line"
                    (and (search-forward "[video: raw.mp4]" nil t) t) t)
          (mx-check "no thumb: nothing fetches"
                    (text-property-any
                     (point-min) (point-max) 'elneo-room-media-thumb t)
                    nil))
      (kill-buffer buf)))

  ;; 5. the fetch: the scan asks the daemon for exactly the thumbnail —
  ;; thumb source arm plus "thumb" format — and replaces the placeholder
  ;; only, with the play mark before the image cell.
  (let ((buf (mx-video-room))
        (called nil)
        (tag-text "[video: clip.mp4 (1.2 MiB, 1:05)]"))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'elneo-download-media)
                     (lambda (_p source format callback &rest _)
                       (setq called (cons source format))
                       (funcall callback "mxtest"
                                '((@ok . t) (path . "/cache/media/vidthumb")))))
                    ((symbol-function 'create-image)
                     (lambda (_file _type _data &rest _) (list 'image 'fake))))
            (mx-append-video (mx-video-media))
            (elneo-room--fetch-media-range (point-min) (point-max))
            (mx-check "fetch: the thumb mxc, thumb format"
                      called '(((url . "mxc://hs/vidthumb")) . "thumb"))
            ;; In flight (the sync stub's callback ran inside the scan,
            ;; so the mark the scan set after the call survives here).
            (mx-check "fetch: the event is pending"
                      (gethash "$v1" elneo-room--media-pending) t)
            ;; The real (async) callback clears that mark on arrival —
            ;; pinned with a hand-fired on-media, which does nothing
            ;; else here since the region no longer carries the thumb
            ;; marker.
            (elneo-room--on-media (current-buffer) "$v1"
                                  '((@ok . t) (path . "/x")))
            (mx-check "on-media: the pending mark clears"
                      (gethash "$v1" elneo-room--media-pending) nil)
            (goto-char (point-min))
            (let ((play-pos (search-forward "▶" nil t)))
              (mx-check "fetch: the play mark is there" (and play-pos t) t)
              (mx-check "fetch: the mark is the play face"
                        (get-text-property (1- play-pos) 'face)
                        'elneo-room-video-play)
              ;; In batch the alt string is plain buffer text: insert-image
              ;; puts "[video]" under the display property, right before
              ;; the tag.
              (let ((cell (next-single-property-change
                           (point-min) 'display nil (point-max))))
                (mx-check "fetch: the image cell landed"
                          (get-text-property cell 'display) '(image fake))
                (mx-check "fetch: the alt labels a video"
                          (buffer-substring cell (+ cell 7)) "[video]")
                (mx-check "fetch: the cell still opens the video"
                          (alist-get 'filename
                                     (get-text-property cell 'elneo-room-media-data))
                          "clip.mp4"))
              (mx-check "fetch: the tag survives the fetch"
                        (and (search-forward tag-text nil t) t) t)
              (mx-check "fetch: nothing re-fetches on a next pass"
                        (text-property-any
                         (point-min) (point-max) 'elneo-room-media-thumb t)
                        nil))
            ;; The fetched caption line belongs to the block: a
            ;; re-render (an edit, say) must delete it with the block
            ;; instead of orphaning a stale caption line — and a
            ;; stale tag line, same story — under the fresh render.
            (elneo-room--replace-message
             "$v1" (list :event-id "$v1"
                         :ts (* 1000 (time-to-seconds
                                      (encode-time '(0 0 12 13 10 2026))))
                         :sender "@a:mx.org" :is-own nil
                         :msgtype "m.video" :body "holiday clip"
                         :media (mx-video-media)))
            (mx-check "fetch: a re-render leaves no orphan caption"
                      (how-many "holiday clip") 1)
            (mx-check "fetch: a re-render leaves no orphan tag"
                      (how-many (regexp-quote "[video: clip.mp4")) 1)))
      (kill-buffer buf)))

  ;; 6. the failed fetch says so, as a video; an image keeps the old one
  (let ((buf (mx-video-room)))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'elneo-download-media)
                     (lambda (_p _s _f callback &rest _)
                       (funcall callback "mxtest"
                                '((@ok . nil) (error . "thumbnail gone"))))))
            (mx-append-video (mx-video-media))
            (elneo-room--fetch-media-range (point-min) (point-max))
            (goto-char (point-min))
            (mx-check "fail: the video placeholder says unavailable"
                      (and (search-forward "[video unavailable]" nil t) t) t)
            (mx-check "fail: the tag line is still there"
                      (and (search-forward "[video: clip.mp4" nil t) t) t)
            ;; an image message's failed thumb keeps the old label
            (goto-char (point-max))
            (elneo-room--append-messages
             (list (list :event-id "$i1" :ts 1001 :sender "@a:mx.org"
                         :is-own nil :msgtype "m.image" :body "pic.png"
                         :media '((source (url . "mxc://hs/pic"))
                                  (mimetype . "image/png")))))
            (elneo-room--fetch-media-range (point-min) (point-max))
            (goto-char (point-min))
            (mx-check "fail: an image keeps the image label"
                      (and (search-forward "[image unavailable]" nil t) t) t)))
      (kill-buffer buf)))

  ;; 7. a successful image replacement keeps the plain [image] alt —
  ;; the video-flavored path must not leak into the picture arm
  (let ((buf (mx-video-room)))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'elneo-download-media)
                     (lambda (_p _s _f callback &rest _)
                       (funcall callback "mxtest"
                                '((@ok . t) (path . "/cache/media/pic")))))
                    ((symbol-function 'create-image)
                     (lambda (_file _type _data &rest _) (list 'image 'fake))))
            (goto-char (point-max))
            (elneo-room--append-messages
             (list (list :event-id "$i1" :ts 1001 :sender "@a:mx.org"
                         :is-own nil :msgtype "m.image" :body "pic.png"
                         :media '((source (url . "mxc://hs/pic"))
                                  (mimetype . "image/png")))))
            (elneo-room--fetch-media-range (point-min) (point-max))
            (goto-char (point-min))
            (mx-check "image: no play mark in an image message"
                      (search-forward "▶" nil t) nil)
            (goto-char (point-min))
            (let ((cell (next-single-property-change
                         (point-min) 'display nil (point-max))))
              (mx-check "image: the image cell landed"
                        (get-text-property cell 'display) '(image fake))
              (mx-check "image: the alt reads as an image"
                        (buffer-substring cell (+ cell 7)) "[image]"))))
      (kill-buffer buf)))

  (message "video-preview: %d passed, %d failed" pass fail)
  (kill-emacs (if (zerop fail) 0 1)))