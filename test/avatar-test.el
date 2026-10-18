;;; avatar-test.el --- avatar cells, cache joining, toggling -*- lexical-binding: t; -*-

;; Avatars (elneo-client.el fetch/cache + elneo-room.el column +
;; elneo-room-bar.el prefix) test: placeholder cells, per-MXC fetch
;; dedup, in-place image replacement, and the per-buffer toggle.
;; Batch mode has no frames, so image display (create-image, font
;; metrics) is stubbed alongside the daemon (elneo-download-media).
;;
;; Run: emacs -Q --batch -L lisp -l test/avatar-test.el

(require 'elneo-room)
(require 'elneo-room-bar)

;; A 1x1 PNG: create-image refuses files that do not exist.
(defconst mx-avatar-png "/tmp/mx-avatar-test.png")
(with-temp-file mx-avatar-png
  (insert (base64-decode-string
           "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")))

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  ;; Batch mode has no fonts; the image cell path still gets covered
  ;; once the display check is satisfied.
  (defmacro mx-with-display (&rest body)
    `(cl-letf (((symbol-function 'display-graphic-p) (lambda () t))
               ((symbol-function 'default-font-height) (lambda () 17))
               ((symbol-function 'default-font-width) (lambda () 8))
               ;; Batch Emacs has no image-type support, so create-image
               ;; returns nil for any file; only a graphic frame decodes
               ;; real pixels (verified interactively).  The cell logic
               ;; under test only needs the display property to hold
               ;; something non-nil.
               ((symbol-function 'create-image)
                (lambda (_file &rest _) 'mx-stub-image)))
       ,@body))

  (let* ((room-key (cons "mxtest" "!r:mxtest.org"))
         (buf (get-buffer-create " *mx-avatar-room*"))
         (ts-base (* 1000 (time-to-seconds
                           (encode-time '(0 0 12 13 10 2026))))))
    (with-current-buffer buf
      (elneo-room-mode)
      (setq elneo-room--profile "mxtest"
            elneo-room--room-id "!r:mxtest.org"
            elneo-room--seen (make-hash-table :test 'equal)
            elneo-room--backfilled t)
      (puthash room-key buf elneo-room--buffers)
      (elneo-room--header (list :display-name "Avatar Room"
                                  :room-id "!r:mxtest.org"))

      ;; 1. body column math: the avatar column shifts everything right
      (let ((elneo-room-avatars t))
        (mx-check "body column with avatars on"
                  (elneo-room--body-column) 24))
      (let ((elneo-room-avatars nil))
        (mx-check "body column with avatars off"
                  (elneo-room--body-column) 21))

      ;; 2. avatar cell: sender without an avatar -> colored initial,
      ;;    no fetch ever
      (let ((fetches 0))
        (cl-letf (((symbol-function 'elneo-download-media)
                   (lambda (&rest _) (cl-incf fetches))))
          (let ((cell (elneo-room--avatar-cell
                       (list :sender "@a:mx.org" :sender-name "Alice"))))
            (mx-check "no avatar: initial cell"
                      (substring cell 0 2) "A ")
            (mx-check "no avatar: no fetch" fetches 0))))

      ;; 3. avatar cell with an MXC but nothing downloaded: initial
      ;;    placeholder carrying the fetch target properties; the
      ;;    fetch is deduped per MXC, and the download landing fills
      ;;    the shared cache
      (let ((fetches 0)
            (saved-callback nil))
        (cl-letf (((symbol-function 'elneo-download-media)
                   (lambda (_profile _source _format callback &rest _)
                     (cl-incf fetches)
                     (setq saved-callback callback))))
          (let ((msg (list :sender "@b:mx.org" :sender-name "Bob"
                           :sender-avatar "mxc://hs/bob")))
            (let ((cell (elneo-room--avatar-cell msg)))
              (mx-check "pending avatar: initial cell"
                        (substring cell 0 2) "B ")
              (mx-check "pending avatar: src property"
                        (get-text-property 0 'elneo-room-avatar-src cell)
                        "mxc://hs/bob"))
            ;; two more renders of the same sender: one fetch total
            (elneo-room--avatar-cell msg)
            (elneo-room--avatar-cell msg)
            (mx-check "fetch deduped per mxc" fetches 1)
            ;; the download lands: the cache stores the path
            (funcall saved-callback "mxtest"
                     `((@ok . t) (path . ,mx-avatar-png)))
            (mx-check "cache holds the path"
                      (gethash "mxc://hs/bob" elneo-client--avatar-cache)
                      mx-avatar-png)
            ;; a later render goes straight to the image, no new fetch
            (mx-with-display
             (let ((cell (elneo-room--avatar-cell msg)))
               (mx-check "cached avatar: image cell"
                         (and (get-text-property 0 'display cell) t)
                         t)
               (mx-check "cached avatar: no new fetch" fetches 1))))))

      ;; 4. render + in-place replacement: a buffer holding placeholder
      ;;    cells swaps the image in when the download lands, width-identical
      (let ((fetches 0))
        (clrhash elneo-client--avatar-cache)
        (clrhash elneo-client--avatar-pending)
        (cl-letf (((symbol-function 'elneo-download-media)
                   (lambda (&rest _) (cl-incf fetches))))
          (elneo-room--append-messages
           (list (list :event-id "$m1" :ts ts-base :sender "@c:mx.org"
                       :sender-name "Carol" :is-own nil
                       :msgtype "m.text" :body "hello"
                       :sender-avatar "mxc://hs/carol")
                 (list :event-id "$m2" :ts (+ ts-base 1000)
                       :sender "@c:mx.org" :sender-name "Carol"
                       :is-own nil :msgtype "m.text" :body "again"
                       :sender-avatar "mxc://hs/carol")))
          (elneo-room--reset-input-area "")
          (mx-check "render fetched the avatar once" fetches 1)
          (goto-char (point-min))
          (search-forward "hello")
          (let ((line-beg (line-beginning-position)))
            (mx-check "placeholder cell in the buffer"
                      (get-text-property line-beg 'elneo-room-avatar-src)
                      "mxc://hs/carol")
            (let ((before (buffer-size)))
              ;; the download lands (another surface fetched it)
              (puthash "mxc://hs/carol" mx-avatar-png
                       elneo-client--avatar-cache)
              (mx-with-display
               (elneo-room--replace-avatar-placeholders))
              (mx-check "replacement is width-identical"
                        (buffer-size) before)
              (mx-check "placeholder became an image"
                        (and (get-text-property
                              line-beg 'elneo-room-avatar-image)
                             t)
                        t)
              ;; idempotent: a second pass does not re-replace
              (mx-with-display
               (elneo-room--replace-avatar-placeholders))
              (mx-check "second pass is a no-op" (buffer-size) before)))))

      ;; 5. toggle: buffer-local override, C-u resets to the global
      (clrhash elneo-client--avatar-cache)
      (cl-letf (((symbol-function 'elneo-download-media)
                 (lambda (&rest _) nil)))
        (setq-local elneo-room-avatars nil)
        (call-interactively #'elneo-room-toggle-avatars)
        (mx-check "toggle: buffer-local on"
                  (and elneo-room-avatars
                       (local-variable-p 'elneo-room-avatars))
                  t)
        (call-interactively #'elneo-room-toggle-avatars)
        (mx-check "toggle: buffer-local off"
                  (and (not elneo-room-avatars)
                       (local-variable-p 'elneo-room-avatars))
                  t)
        (let ((current-prefix-arg '(4)))
          (call-interactively #'elneo-room-toggle-avatars))
        (mx-check "C-u toggle: back to the global"
                  (local-variable-p 'elneo-room-avatars)
                  nil))

      ;; cleanup
      (remhash room-key elneo-room--buffers))
    (kill-buffer buf)

    ;; 6. room bar avatar prefix
    (let ((fetches 0))
      (cl-letf (((symbol-function 'elneo-download-media)
                 (lambda (&rest _) (cl-incf fetches)))
                ((symbol-function 'elneo-room-bar--schedule-full)
                 (lambda () nil)))
        (let ((room (list :profile "mxtest" :room-id "!r:mx.org"
                          :display-name "Room One")))
          (let ((elneo-room-bar-avatars nil))
            (mx-check "bar: avatars off -> empty prefix"
                      (elneo-room-bar--avatar-prefix room) ""))
          (let ((elneo-room-bar-avatars t))
            (mx-check "bar: no avatar -> initial cell"
                      (substring (elneo-room-bar--avatar-prefix room) 0 3)
                      "R  ")))
        ;; room with an avatar: fetch kicked, initial shown meanwhile
        (let ((room (list :profile "mxtest" :room-id "!r:mx.org"
                          :display-name "Room Two"
                          :avatar "mxc://hs/room2"))
              (elneo-room-bar-avatars t))
          (mx-check "bar: pending avatar -> initial"
                    (substring (elneo-room-bar--avatar-prefix room) 0 3)
                    "R  ")
          (mx-check "bar: avatar fetch kicked" fetches 1)
          (puthash "mxc://hs/room2" mx-avatar-png
                   elneo-client--avatar-cache)
          (mx-with-display
           (mx-check "bar: cached avatar -> image cell"
                     (and (get-text-property
                           0 'display
                           (elneo-room-bar--avatar-prefix room))
                          t)
                     t))))))

  (clrhash elneo-client--avatar-cache)
  (clrhash elneo-client--avatar-pending)

  (message "results: %d passed, %d failed" pass fail)
  (kill-emacs (if (zerop fail) 0 1)))