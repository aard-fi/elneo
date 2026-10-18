;;; image-viewer-test.el --- image viewer seeding and navigation -*- lexical-binding: t; -*-

;; Image viewer (elneo-image.el) test: seeding from the room
;; buffer's rendered history, list merging, navigation, the
;; older-page walk merge, and the modeline [n/total].  The daemon
;; is stubbed: elneo-download-media never fetches (the viewer
;; shows a placeholder), elneo-room-messages replies from a
;; canned page synchronously.
;;
;; Run: emacs -Q --batch -L lisp -l test/image-viewer-test.el

(require 'elneo-image)

(defconst mx-test-old-page
  `((@ok . t)
    (room_id . "!r:mxtest.org")
    (end . nil)
    (messages
     . [((event_id . "$old")
         (sender . "@a:mx.org")
         (sender_name . "Alice")
         (body . "zero.jpg")
         (ts . 1000000)
         (msgtype . "m.image")
         (is_own . nil)
         (media . ((source (url . "mxc://hs/0")))))]))
  "Canned daemon page: one image older than everything rendered.")

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defun mx-media (mxc)
    "A minimal media alist with plain source MXC."
    `((source (url . ,mxc))))

  (let* ((room-key (cons "mxtest" "!r:mxtest.org"))
         (buf (get-buffer-create " *mx-img-room*"))
         (ts-base (* 1000 (time-to-seconds
                           (encode-time '(0 0 12 13 10 2026))))))
    (with-current-buffer buf
      (elneo-room-mode)
      (setq elneo-room--profile "mxtest"
            elneo-room--room-id "!r:mxtest.org"
            elneo-room--seen (make-hash-table :test 'equal)
            elneo-room--end-token nil)
      (puthash room-key buf elneo-room--buffers)
      ;; Room record so the viewer buffer name gets the display name.
      (puthash room-key
               (list :display-name "Img Room" :profile "mxtest"
                     :room-id "!r:mxtest.org")
               elneo--rooms)
      (elneo-room--header (list :display-name "Img Room"
                                 :room-id "!r:mxtest.org"))
      ;; render: text, img1, img2, text, img2 skipped below, img3 —
      ;; plus a media-less image message that must NOT make the list.
      (elneo-room--append-messages
       (list (list :event-id "$t0" :ts ts-base :sender "@a:mx.org"
                   :is-own nil :msgtype "m.text" :body "hello")
             (list :event-id "$img1" :ts (+ ts-base 1000) :sender "@a:mx.org"
                   :is-own nil :msgtype "m.image" :body "one.jpg"
                   :media (mx-media "mxc://hs/1"))
             (list :event-id "$img2" :ts (+ ts-base 2000) :sender "@b:mx.org"
                   :is-own t :msgtype "m.image" :body "two.jpg"
                   :media (mx-media "mxc://hs/2"))
             (list :event-id "$t1" :ts (+ ts-base 3000) :sender "@b:mx.org"
                   :is-own t :msgtype "m.text" :body "more text")
             (list :event-id "$img-x" :ts (+ ts-base 3500) :sender "@a:mx.org"
                   :is-own nil :msgtype "m.image" :body "broken.jpg"
                   :media nil)
             (list :event-id "$img3" :ts (+ ts-base 4000) :sender "@a:mx.org"
                   :is-own nil :msgtype "m.image" :body "three.jpg"
                   :media (mx-media "mxc://hs/3"))))
      (elneo-room--reset-input-area "")

      ;; 1. seeding: rendered images only, oldest first, media attached
      (let ((imgs (elneo-image--room-images buf)))
        (mx-check "seed: image ids in order"
                  (mapcar (lambda (m) (plist-get m :event-id)) imgs)
                  '("$img1" "$img2" "$img3"))
        (mx-check "seed: media attached"
                  (plist-get (car imgs) :media) (mx-media "mxc://hs/1")))

      ;; 2. merge: dedupe by event id, ordered by ts
      (let* ((a (list (list :event-id "$a" :ts 100)
                      (list :event-id "$b" :ts 200)))
             (b (list (list :event-id "$b" :ts 200)   ; dup
                      (list :event-id "$c" :ts 50))))  ; older than both
        (mx-check "merge: deduped, ts order"
                  (mapcar (lambda (m) (plist-get m :event-id))
                          (elneo-image--merge-images a b))
                  '("$c" "$a" "$b")))

      ;; 3. entry into the viewer from the room buffer, daemon stubbed
      (cl-letf (((symbol-function 'elneo-download-media)
                 (lambda (&rest _) nil))
                ((symbol-function 'elneo-room-messages)
                 ;; canned older page, replied synchronously
                 (lambda (_profile _room _limit _from callback &rest _)
                   (funcall callback "mxtest" mx-test-old-page))))
        ;; room history not exhausted: the walk starts from the room's
        ;; end token and merges the canned older page.
        (setq elneo-room--end-token "tok1")
        (goto-char (point-min))
        (search-forward "two.jpg")
        (goto-char (match-beginning 0))
        (elneo-image-view-at-point)
        (let ((viewer (get-buffer "*Matrix image: Img Room*")))
          (mx-check "viewer buffer exists" (buffer-live-p viewer) t)
          (with-current-buffer viewer
            (mx-check "opened on the image at point"
                      elneo-image--current-id "$img2")
            ;; the canned older page merged in; exhausted (end nil)
            (mx-check "older page merged: 4 images"
                      (length elneo-image--images) 4)
            (mx-check "walk exhausted" elneo-image--exhausted t)
            (mx-check "index math" (elneo-image--current-index) 2)

            ;; 4. navigation
            (elneo-image-next)
            (mx-check "n: newer" elneo-image--current-id "$img3")
            (elneo-image-prev)
            (elneo-image-prev)
            (mx-check "p twice: older" elneo-image--current-id "$img1")
            (elneo-image-prev)
            (mx-check "p: into the walked older page"
                      elneo-image--current-id "$old")
            (elneo-image-prev)
            (mx-check "p at oldest stays" elneo-image--current-id "$old")

            ;; 5. modeline: [position/total], exact (exhausted)
            (mx-check "modeline position"
                      (and (string-match-p "\\[1/4\\]" (elneo-image--mode-line))
                           t)
                      t)

            ;; back to the newest for the live-arrival check
            (elneo-image-next)
            (elneo-image-next)
            (elneo-image-next)
            (mx-check "n back to newest" elneo-image--current-id "$img3")

            ;; 6. live arrival: a new image in the room buffer is
            ;; picked up when n runs past the newest
            (with-current-buffer buf
              ;; like the live append path: insert at the append marker,
              ;; not wherever the room buffer's point happens to sit
              (goto-char elneo-room--append-point)
              (elneo-room--append-messages
               (list (list :event-id "$img4" :ts (+ ts-base 9000)
                           :sender "@a:mx.org" :is-own nil
                           :msgtype "m.image" :body "four.jpg"
                           :media (mx-media "mxc://hs/4")))))
            (elneo-image-next)
            (mx-check "n at newest merges live arrival"
                      elneo-image--current-id "$img4")
            (mx-check "list grew" (length elneo-image--images) 5)

            ;; 7. mid-browse redaction: like `--on-redaction', the
            ;; seen entry becomes a plain marker (m.text, no media) —
            ;; the room-side list drops it, and the viewer's copy must
            ;; drop at the next sync too (the merge alone would keep
            ;; the stale copy browsable).  The rescue lands on the
            ;; ts-nearest survivor.  Dropped plists are put back so the
            ;; later sections keep them.
            (mx-check "last-ts tracks the display"
                      elneo-image--last-ts (+ ts-base 9000))
            (let ((img4-seen (with-current-buffer buf
                               (gethash "$img4" elneo-room--seen))))
              (with-current-buffer buf
                (puthash "$img4"
                         (list :event-id "$img4" :sender "@a:mx.org"
                               :sender-name "Alice" :ts (+ ts-base 9000)
                               :msgtype "m.text" :is-own nil :redacted t)
                         elneo-room--seen))
              ;; boundary branch: n refetches the list the id has
              ;; dropped out of — the pre-prune stale copy would keep
              ;; it in, and a nil index would crash; escape lands
              ;; nearest.
              (elneo-image-next)
              (mx-check "n on a redacted newest rescues, no wrong-type"
                        elneo-image--current-id "$img3")
              (with-current-buffer buf
                (puthash "$img4" img4-seen elneo-room--seen))
              ;; entry branch: current id already out of the list
              (let ((img3-seen (with-current-buffer buf
				 (gethash "$img3" elneo-room--seen))))
		(with-current-buffer buf
                  (puthash "$img3"
                           (list :event-id "$img3" :sender "@a:mx.org"
				 :sender-name "Alice" :ts (+ ts-base 4000)
				 :msgtype "m.text" :is-own nil :redacted t)
                           elneo-room--seen))
		(setq elneo-image--images
                      (with-current-buffer buf
			(elneo-image--room-images buf)))
		(mx-check "viewer list refreshes: id gone"
                          (elneo-image--current-index) nil)
		(elneo-image-prev)
		(mx-check "p on a vanishing current rescues to ts-nearest"
                          elneo-image--current-id "$img2")
		(with-current-buffer buf
                  (puthash "$img3" img3-seen elneo-room--seen))))))

	;; 8. not an image -> user-error
	(goto-char (point-min))
	(search-forward "hello")
	(mx-check "view on a text message errors"
                  (condition-case _err
                      (progn (elneo-image-view-at-point) 'no-error)
                    (user-error 'user-error))
                  'user-error))

      ;; 9. sticker: rides the image path (render, gallery, viewer)
      (cl-letf (((symbol-function 'elneo-download-media) (lambda (&rest _) nil))
		;; The room's end token ("tok1") survives to here, so
		;; the sticker-open's older-page walk needs the canned
		;; page again — empty, exhausted.
		((symbol-function 'elneo-room-messages)
		 (lambda (_profile _room _limit _from callback &rest _)
                   (funcall callback "mxtest"
                            `((@ok . t) (room_id . "!r:mxtest.org")
                              (end . nil) (messages . []))))))
	(with-current-buffer buf
          (goto-char elneo-room--append-point)
          (elneo-room--append-messages
           (list (list :event-id "$st1" :ts (+ ts-base 9500)
                       :sender "@b:mx.org" :is-own nil
                       :msgtype "m.sticker" :body "happy cat"
                       :media (mx-media "mxc://hs/s1"))))
          (goto-char (point-min))
          (mx-check "sticker renders the alt-text placeholder"
                    (and (search-forward "[sticker: happy cat]" nil t) t) t)
          ;; The thumb property marks the span for the fetch scan.
          (mx-check "sticker span carries the thumb marker"
                    (get-text-property (1- (point)) 'elneo-room-media-thumb) t)
          (goto-char (point-min))
          (search-forward "happy cat")
          (goto-char (match-beginning 0))
          (condition-case _err (elneo-image-view-at-point) 'user-error)
          (let ((viewer (get-buffer "*Matrix image: Img Room*")))
            (with-current-buffer viewer
              (mx-check "sticker opens the viewer" elneo-image--current-id "$st1"))))
	(mx-check "sticker joins the gallery list"
                  (mapcar (lambda (m) (plist-get m :event-id))
                          (elneo-image--room-images buf))
                  '("$img1" "$img2" "$img3" "$img4" "$st1")))

      ;; cleanup
      (remhash room-key elneo--rooms)
      (remhash room-key elneo-room--buffers))
    (let ((viewer (get-buffer "*Matrix image: Img Room*")))
      (when viewer (kill-buffer viewer)))
    (kill-buffer buf))

;;; Avatar view (the full-size window the avatar facts' buttons open)

  ;; The view downloads the avatar's FULL file ("file", unlike the
  ;; thumbnails the facts render), names the buffer after it, and
  ;; says so on failure.  Batch cannot display images: the file-only
  ;; render keeps the cache path instead.

  (let* ((dm-called nil))
    (unwind-protect
        (cl-letf (((symbol-function 'elneo-download-media)
                   (lambda (_profile source format cb _filename)
                     (setq dm-called (cons source format))
                     (funcall cb "mxtest" '((@ok . t)
                                            (path . "/cache/media/hs_av_full"))))))
          (elneo-avatar-show "mxtest" "mxc://hs/myav")
          (mx-check "avatar: the download asks for the full file"
                    dm-called '(((url . "mxc://hs/myav")) . "file"))
          (mx-check "avatar: the buffer exists, named for the profile"
                    (buffer-live-p (get-buffer "*Matrix Avatar: mxtest*")) t)
          (let ((text (with-current-buffer "*Matrix Avatar: mxtest*"
                        (buffer-string))))
            (mx-check "avatar: the mxc names the view"
                      (and (string-search "mxc://hs/myav" text) t) t)
            (mx-check "avatar: no images drawn, the cache path is said"
                      (and (string-search
                            (abbreviate-file-name "/cache/media/hs_av_full")
                            text)
                           t)
                      t))
          ;; The graphic twin: the image inserts, fitted, with its
          ;; display property on the cell.
          (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                    ((symbol-function 'create-image)
                     (lambda (_file _type _data &rest _) 'fake-img)))
            (elneo-avatar-show "mxtest" "mxc://hs/myav")
            (with-current-buffer "*Matrix Avatar: mxtest*"
              (goto-char (point-min))
              (let ((pos (next-single-property-change (point-min) 'display
                                                      nil (point-max))))
                (mx-check "avatar: the image inserts with its display property"
                          (get-text-property pos 'display) 'fake-img))
              ;; The mode's keys: `q' is special-mode's bury, `o' the
              ;; external open.
              (mx-check "avatar: q buries"
                        (key-binding (kbd "q")) 'quit-window)
              (mx-check "avatar: o opens the file externally"
                        (key-binding "o") #'elneo-avatar-open-externally))))
      (when (get-buffer "*Matrix Avatar: mxtest*")
        (kill-buffer "*Matrix Avatar: mxtest*"))))

  (cl-letf (((symbol-function 'elneo-download-media)
             (lambda (_profile _source _format cb _filename)
               (funcall cb "mxtest" '((@ok . nil) (error . "x"))))))
    (elneo-avatar-show "mxtest" "mxc://hs/myav")
    (mx-check "avatar: a failed download says so"
              (with-current-buffer "*Matrix Avatar: mxtest*"
                (and (string-search "unavailable" (buffer-string)) t))
              t)
    (kill-buffer "*Matrix Avatar: mxtest*"))

  (mx-check "avatar: an empty mxc has nothing to show"
            (condition-case _ (elneo-avatar-show "mxtest" "")
              (user-error t))
            t)

  ;; The type sniff: the full-file download carries no extension, so
  ;; the magic bytes name the image.
  (let* ((dir (make-temp-file "mx-avtype" t))
         (bytefile (lambda (name bytes)
                     (let ((f (expand-file-name name dir))
                           (coding-system-for-write 'no-conversion))
                       (write-region bytes nil f)
                       f)))
         (png (funcall bytefile "png.bin"
                       (unibyte-string 137 80 78 71 13 10 26 10)))
         (jpeg (funcall bytefile "jpeg.bin" (unibyte-string 255 216 255 224 0 0)))
         (gif (funcall bytefile "gif.bin" "GIF89a"))
         (webp (funcall bytefile "webp.bin"
                        (concat "RIFF" (unibyte-string 0 0 0 0)
                                "WEBP")))
         (junk (funcall bytefile "junk.bin" "hello world")))
    (unwind-protect
        (progn
          (mx-check "avatar: png magic is png" (elneo-avatar--sniff-type png) 'png)
          (mx-check "avatar: jpeg magic is jpeg" (elneo-avatar--sniff-type jpeg) 'jpeg)
          (mx-check "avatar: gif magic is gif" (elneo-avatar--sniff-type gif) 'gif)
          (mx-check "avatar: webp magic is webp" (elneo-avatar--sniff-type webp) 'webp)
          (mx-check "avatar: unknown magic is no type"
                    (elneo-avatar--sniff-type junk) nil))
      (delete-directory dir t)))

  ;;; The stale-walk generation guard (C1): a page of a superseded
  ;;; walk discards instead of clobbering the re-opened viewer

  (let* ((room-key (cons "gentest" "!r:gentest.org"))
         (buf (get-buffer-create " *mx-img-gen-room*"))
         (pending nil))
    (with-current-buffer buf
      (elneo-room-mode)
      (setq elneo-room--profile "gentest"
            elneo-room--room-id "!r:gentest.org"
            elneo-room--seen (make-hash-table :test 'equal)
            elneo-room--end-token "tok-g1")
      (puthash room-key buf elneo-room--buffers)
      (puthash room-key
               (list :display-name "Gen Room" :profile "gentest"
                     :room-id "!r:gentest.org")
               elneo--rooms)
      (elneo-room--append-messages
       (list (list :event-id "$g1" :ts 1000 :sender "@a:hs"
                   :is-own nil :msgtype "m.image" :body "g1.jpg"
                   :media (mx-media "mxc://hs/g1"))))
      (elneo-room--reset-input-area "")
      ;; Both walks go out while their pages stay pending: two
      ;; `--open's reuse the same viewer buffer, and the second one
      ;; must not be answerable to the first one's page.
      (cl-letf (((symbol-function 'elneo-download-media) (lambda (&rest _) nil))
                ((symbol-function 'elneo-room-messages)
                 (lambda (_profile _room _limit _from callback &rest _)
                   (setq pending (cons callback pending)))))
        (goto-char (point-min))
        (search-forward "g1.jpg")
        (goto-char (match-beginning 0))
        (elneo-image-view-at-point)
        (elneo-image-view-at-point)
        (mx-check "stale gen: two opens, two pending pages"
                  (length pending) 2)
        (let ((viewer (get-buffer "*Matrix image: Gen Room*")))
          (with-current-buffer viewer
            ;; the FIRST open's page arrives late: discarded whole
            (funcall (nth 1 pending) "gentest"
                     `((@ok . t) (room_id . "!r:gentest.org")
                       (end . "stale-end") (messages . [])))
            (mx-check "stale gen: the stale END does not clobber"
                      elneo-image--token "tok-g1")
            (mx-check "stale gen: no merge from the stale page"
                      (length elneo-image--images) 1)
            (mx-check "stale gen: the budget is not spent"
                      elneo-image--walk-left elneo-image-walk-cap)
            (mx-check "stale gen: the second walk stays in flight"
                      elneo-image--loading t)
            ;; the CURRENT walk's page arrives and advances
            (funcall (nth 0 pending) "gentest"
                     `((@ok . t) (room_id . "!r:gentest.org")
                       (end . nil)
                       (messages . [((event_id . "$old2")
                                     (sender . "@a:mx.org")
                                     (sender_name . "Alice")
                                     (body . "g0.jpg")
                                     (ts . 500)
                                     (msgtype . "m.image")
                                     (is_own . nil)
                                     (media . ((source (url . "mxc://hs/g0")))))])))
            (mx-check "stale gen: the current page merges"
                      (mapcar (lambda (m) (plist-get m :event-id))
                              elneo-image--images)
                      '("$old2" "$g1"))
            (mx-check "stale gen: the current END lands"
                      elneo-image--token nil))))
      ;; cleanup: the room buffer and its registry seeds
      (remhash room-key elneo--rooms)
      (remhash room-key elneo-room--buffers))
    (when (get-buffer "*Matrix image: Gen Room*")
      (kill-buffer "*Matrix image: Gen Room*"))
    (kill-buffer buf))

  ;;; The avatar guard (C2): a late answer for a SUPERSEDED mxc
  ;;; leaves the re-shown view alone — failure note included

  (let ((cb1 nil) (cb2 nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'elneo-download-media)
                     (lambda (_profile _source _format cb _filename)
                       (if cb1 (setq cb2 cb) (setq cb1 cb)))))
            (elneo-avatar-show "mxtest" "mxc://hs/avX")
            (elneo-avatar-show "mxtest" "mxc://hs/avY")
            (with-current-buffer "*Matrix Avatar: mxtest*"
              ;; X's failure arrives after the re-show to Y: discarded
              (funcall cb1 "mxtest" '((@ok . nil) (error . "late")))
              (mx-check "avatar: a stale failure does not set --failed"
                        elneo-avatar--failed nil)
              (mx-check "avatar: the stale failure does not flash"
                        (and (string-search "downloading" (buffer-string)) t) t)
              ;; Y's success lands and renders
              (funcall cb2 "mxtest" '((@ok . t) (path . "/cache/media/avY")))
              (mx-check "avatar: the current answer renders"
                        (and (string-search
                              (abbreviate-file-name "/cache/media/avY")
                              (buffer-string))
                             t)
                        t)))
          (cl-letf (((symbol-function 'elneo-download-media)
                     (lambda (&rest _) nil)))
            ;; same-mxc re-show: the failure flag resets for a fresh try
            (elneo-avatar-show "mxtest" "mxc://hs/avY")
            (with-current-buffer "*Matrix Avatar: mxtest*"
              (mx-check "avatar: a re-show of a failed view retries"
                        elneo-avatar--failed nil)
              (mx-check "avatar: the retry shows the waiting line"
                        (and (string-search "downloading" (buffer-string)) t) t))))
      (when (get-buffer "*Matrix Avatar: mxtest*")
        (kill-buffer "*Matrix Avatar: mxtest*"))))

  ;;; Quit: the dead room buffer quits plain, and the live one is not
  ;;; doubled when another window already shows it.  Also the ghost
  ;;; machinery's remaining arms: a dead room buffer's --pruned
  ;;; passthrough, and the nothing-left placeholder.

  (let* ((room-key (cons "quitest" "!r:quitest.org"))
         (room (get-buffer-create " *mx-img-quit-room*"))
         (viewer (get-buffer-create "*Matrix image: Q Room*")))
    (with-current-buffer room
      (elneo-room-mode)
      (setq elneo-room--profile "quitest"
            elneo-room--room-id "!r:quitest.org"
            elneo-room--seen (make-hash-table :test 'equal)))
    (puthash room-key room elneo-room--buffers)
    (puthash room-key
             (list :display-name "Q Room" :profile "quitest"
                   :room-id "!r:quitest.org")
             elneo--rooms)
    (with-current-buffer viewer
      (elneo-image-mode)
      (setq elneo-image--room-buffer room
            elneo-image--opened-window nil
            elneo-image--images
            (list (list :event-id "$q1" :ts 1000 :sender "@a:hs"
                        :is-own nil :msgtype "m.image" :body "q1.jpg"
                        :media '((source (url . "mxc://hs/q1"))))))
      ;; a dead room buffer: --pruned passes the entries through
      (kill-buffer room)
      (mx-check "pruned past a dead room buffer keeps the images"
                (mapcar (lambda (m) (plist-get m :event-id))
                        (elneo-image--pruned elneo-image--images room))
                '("$q1"))
      ;; ... and `q' quits plain instead of switching
      (delete-other-windows)
      (elneo-image-quit)
      (mx-check "quit with a dead room buffer works"
                (buffer-live-p viewer) t)
      ;; the nothing-left arm of the ghost escape: empty list, the
      ;; current id gone (redacted away), land on the placeholder
      (setq elneo-image--images nil
            elneo-image--current-id "$q1")
      (delete-other-windows)
      (switch-to-buffer viewer)
      (elneo-image--escape-ghost)
      (mx-check "escape with nothing left shows the placeholder"
                (and (string-search "no longer available" (buffer-string)) t) t))
    (when (buffer-live-p viewer) (kill-buffer viewer))
    ;; the live-room switch: the viewer's own window gets the room back
    (let ((room2 (get-buffer-create " *mx-img-quit-room2*"))
          (viewer2 (get-buffer-create "*Matrix image: Q2 Room*")))
      (with-current-buffer room2
        (elneo-room-mode)
        (setq elneo-room--profile "quitest"
              elneo-room--room-id "!r:quitest.org"
              elneo-room--seen (make-hash-table :test 'equal)))
      (with-current-buffer viewer2
        (elneo-image-mode)
        (setq elneo-image--room-buffer room2))
      (delete-other-windows)
      ;; opened the way `--open' does: in the selected window
      (switch-to-buffer viewer2)
      (with-current-buffer viewer2
        (setq elneo-image--opened-window (selected-window))
        (elneo-image-quit)
        (mx-check "q: the room returns to the viewer's window"
                  (eq (window-buffer (selected-window)) room2) t))
      ;; double-display: the room already on screen is not doubled —
      ;; the room keeps one window, the viewer splits off, and `q'
      ;; must not land the room in both
      (switch-to-buffer room2)
      (let ((room-win (selected-window))
            (viewer-win (split-window nil nil 'below)))
        (set-window-buffer viewer-win viewer2)
        (select-window viewer-win)
        (with-current-buffer viewer2
          (setq elneo-image--opened-window viewer-win)
          (elneo-image-quit)
          (mx-check "q: a room already on screen is not doubled"
                    (and (eq (window-buffer room-win) room2)
                         (not (eq (window-buffer viewer-win) room2)))
                    t)
          (mx-check "q: the viewer left the window"
                    (eq (window-buffer viewer-win) viewer2) nil)))
      (when (buffer-live-p viewer2) (kill-buffer viewer2))
      (when (buffer-live-p room2) (kill-buffer room2))
      (delete-other-windows)))

  (message "results: %d passed, %d failed" pass fail)
  (kill-emacs (if (zerop fail) 0 1)))
