;;; receipts-test.el --- room buffer render + read receipts test -*- lexical-binding: t; -*-

;; Synthetic room-buffer test: wrap indent + read receipts display.
;; No daemon needed; renders messages directly and drives the
;; receipts hook with a synthetic update.
;;
;; Run: emacs -Q --batch -L lisp -l test/receipts-test.el

(require 'elneo-room)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defun mx-goto-end ()
    "Point to end of history, before the draft separator."
    (goto-char (elneo-room--input-beg-pos)))

  (let ((buf (get-buffer-create " *mx-test-room*")))
    (with-current-buffer buf
      (elneo-room-mode)
      (setq elneo-room--profile "mxtest"
            elneo-room--room-id "!r:mxtest.org"
            elneo-room--seen (make-hash-table :test 'equal)
            elneo-room--receipts (make-hash-table :test 'equal))
      (puthash (cons "mxtest" "!r:mxtest.org") buf elneo-room--buffers)
      ;; realistic render flow: header, messages, then the draft tail
      (elneo-room--header (list :display-name "Test Room"
                                 :room-id "!r:mxtest.org"))
      (mx-check "word-wrap buffer-local" (local-variable-p 'word-wrap buf) t)
      (mx-check "wrap-prefix absent before history"
                (get-text-property (point-min) 'wrap-prefix) nil)
      ;; three messages: other, own, own.  own1 has a hard newline.
      (let* ((now (current-time))
             (ts0 (* 1000 (time-to-seconds (time-subtract now 60))))
             (ts1 (+ ts0 1000))
             (ts2 (+ ts1 1000))
             (msgs
              (list
               (list :event-id "$e0" :ts ts0 :sender "@alice:mx.org"
                     :is-own nil :msgtype "m.text" :body "a fairly long line of history text from alice that will surely wrap when the window is narrow")
               (list :event-id "$e1" :ts ts1 :sender "@me:mx.org"
                     :is-own t :msgtype "m.text" :body "first own line\nsecond own line")
               (list :event-id "$e2" :ts ts2 :sender "@me:mx.org"
                     :is-own t :msgtype "m.text" :body "newest own message"))))
        (elneo-room--append-messages msgs)
        (elneo-room--reset-input-area "")
        (setq elneo-room--backfilled t)
        ;; render puts point back wherever; find positions now
        (mx-check "seen has all 3"
                  (hash-table-count elneo-room--seen) 3)
        ;; wrap-prefix covers the first message block from its start
        (goto-char (point-min))
        (search-forward "a fairly long")
        (goto-char (line-beginning-position))
        (mx-check "wrap-prefix on message block start"
                  (get-text-property (point) 'wrap-prefix)
                  (make-string (elneo-room--body-column) ?\s))
        ;; hard newline in plain body indented to body column
        (search-forward "second own line")
        (goto-char (line-beginning-position))
        (mx-check "hard newline indented to body column"
                  (looking-at (make-string (elneo-room--body-column) ?\s))
                  t)
        ;; day separator (none here) and draft keep no wrap-prefix
        (goto-char (point-max))
        (goto-char (elneo-room--input-beg-pos))
        (mx-check "no wrap-prefix on draft area"
                  (get-text-property (point) 'wrap-prefix) nil)
        ;; --- receipts: alice read up to $e1 (first own message) ---
        ;; :target-ts is the daemon-resolved timeline position of the
        ;; target event; coverage compares against it, not read time.
        (elneo-room--on-read-receipts
         (list :profile "mxtest" :room-id "!r:mxtest.org"
               :receipts
               (list (list :user-id "@alice:mx.org" :user-name "Alice"
                          :event-id "$e1" :ts (+ ts1 500) :target-ts ts1))))
        (mx-check "receipts hash filled"
                  (hash-table-count elneo-room--receipts) 1)
        (goto-char (point-min))
        (search-forward "first own line")
        (goto-char (line-end-position))
        ;; hmm — the ✓✓ is on the line of the newest covered own
        ;; message ($e1), at end of the body line
        (goto-char (point-min))
        (let ((pos (search-forward "second own line")))
          (goto-char (line-end-position))
          (mx-check "check mark after covered own message"
                    (and (search-backward "✓✓" (line-beginning-position) t) t)
                    t))
        (goto-char (point-min))
        (search-forward "newest own message")
        (mx-check "no check mark on newest unread own"
                  (search-backward "✓✓" (line-beginning-position) t) nil)
        ;; no dimming in check style
        (goto-char (point-min))
        (search-forward "first own line")
        (mx-check "check style does not dim"
                  (memq 'elneo-room-read
                        (let ((f (get-text-property (point) 'face)))
                          (if (listp f) f (list f))))
                  nil)
        ;; --- dim style ---
        (let ((elneo-room-read-marks 'dim))
          (elneo-room--apply-read-marks)
          (goto-char (point-min))
          (search-forward "first own line")
          (mx-check "dim style dims covered message"
                    (and (memq 'elneo-room-read
                               (let ((f (get-text-property (point) 'face)))
                                 (if (listp f) f (list f))))
                         t)
                    t)
          (goto-char (point-min))
          (search-forward "newest own message")
          (mx-check "dim style leaves unread own alone"
                    (memq 'elneo-room-read
                          (let ((f (get-text-property (point) 'face)))
                            (if (listp f) f (list f))))
                    nil)
          (mx-check "no check mark in dim style"
                    (save-excursion
                      (goto-char (point-min))
                      (not (search-forward "✓✓" nil t)))
                    t))
        ;; --- both style ---
        (let ((elneo-room-read-marks 'both))
          (elneo-room--apply-read-marks)
          (goto-char (point-min))
          (search-forward "second own line")
          (goto-char (line-end-position))
          (mx-check "both style: mark returns"
                    (and (search-backward "✓✓" (line-beginning-position) t) t)
                    t)
          (goto-char (point-min))
          (search-forward "newest own message")
          (goto-char (line-beginning-position))
          (search-forward "newest own message")
          (mx-check "both style: newest unread own not marked"
                    (search-backward "✓✓" (line-beginning-position) t) nil))
        ;; --- advancing receipt: alice now read $e2 ---
        (elneo-room--on-read-receipts
         (list :profile "mxtest" :room-id "!r:mxtest.org"
               :receipts
               (list (list :user-id "@alice:mx.org" :user-name "Alice"
                          :event-id "$e2" :ts (+ ts2 500) :target-ts ts2))))
        (goto-char (point-min))
        (search-forward "newest own message")
        (goto-char (line-end-position))
        (mx-check "check mark moved to newest message"
                  (and (search-backward "✓✓" (line-beginning-position) t) t)
                  t)
        ;; --- unrendered target (a reaction id), resolved by the daemon ---
        (elneo-room--on-read-receipts
         (list :profile "mxtest" :room-id "!r:mxtest.org"
               :receipts
               (list (list :user-id "@alice:mx.org" :user-name "Alice"
                          :event-id "$unrendered" :ts (+ ts2 1000)
                          :target-ts (+ ts2 1000)))))
        (goto-char (point-min))
        (search-forward "newest own message")
        (goto-char (line-end-position))
        (mx-check "resolved unrendered target keeps mark on newest"
                  (and (search-backward "✓✓" (line-beginning-position) t) t)
                  t)
        ;; --- target the daemon never saw resolves to nothing ---
        (elneo-room--on-read-receipts
         (list :profile "mxtest" :room-id "!r:mxtest.org"
               :receipts
               (list (list :user-id "@alice:mx.org" :user-name "Alice"
                          :event-id "$unknown" :ts (+ ts2 2000)))))
        (mx-check "unresolved target covers nothing"
                  (save-excursion
                    (goto-char (point-min))
                    (not (search-forward "✓✓" nil t)))
                  t)
        ;; re-seed resolved state for the rebuild check
        (elneo-room--on-read-receipts
         (list :profile "mxtest" :room-id "!r:mxtest.org"
               :receipts
               (list (list :user-id "@alice:mx.org" :user-name "Alice"
                          :event-id "$e2" :ts (+ ts2 500) :target-ts ts2))))
        ;; --- rebuild keeps the marks ---
        (elneo-room--rebuild)
        (goto-char (point-min))
        (search-forward "newest own message")
        (goto-char (line-end-position))
        (mx-check "marks survive rebuild"
                  (and (search-backward "✓✓" (line-beginning-position) t) t)
                  t)))
    ;; clean the registry
    (remhash (cons "mxtest" "!r:mxtest.org") elneo-room--buffers)
    (kill-buffer buf))

  ;; --- own read receipt: the hook other surfaces clear alerts with ---
  ;; (a room marked read on another device must reach consumers with
  ;; its profile, room and read-up-to event; nothing UI-side renders
  ;; it, room buffers show other members' markers only)
  (let ((got 'not-run))
    (add-hook 'elneo-own-read-receipt-update-hook
              (lambda (upd) (setq got upd)) nil t)
    (elneo-client--on-update-own-read-receipt
     "mxtest" '((room_id . "!r:mxtest.org")
                (event_id . "$e2")
                (ts . 1737043200005)))
    (remove-hook 'elneo-own-read-receipt-update-hook
                 (car (last elneo-own-read-receipt-update-hook)) t)
    (mx-check "own receipt: hook ran" (plist-get got :event-id) "$e2")
    (mx-check "own receipt: profile" (plist-get got :profile) "mxtest")
    (mx-check "own receipt: room" (plist-get got :room-id) "!r:mxtest.org"))

    ;; --- read-marker pass-over: reactions, votes and edits ---
    ;; In an encrypted room every foreign event counts unread; the
    ;; debounced receipt must ride past the invisible ones instead of
    ;; stranding until the next regular message.
    (let ((buf (get-buffer-create " *mx-test-room-pass*"))
          (sent 'none))
      (with-current-buffer buf
        (elneo-room-mode)
        (setq elneo-room--profile "mxtest"
              elneo-room--room-id "!r:mxtest.org"
              elneo-room--seen (make-hash-table :test 'equal)
              elneo-room--reactions (make-hash-table :test 'equal)
              elneo-room-read-style 'cursor
              elneo-room--read-pending-id nil
              elneo-room--read-sent-id nil
              elneo-room--read-timer nil
              elneo-room--backfilled t))
      (puthash (cons "mxtest" "!r:mxtest.org") buf elneo-room--buffers)
      (cl-letf (((symbol-function 'elneo-room-mark-read)
                 (lambda (_p _r id) (setq sent id)))
                ((symbol-function 'get-buffer-window)
                 (lambda (_buf _all) 'fake-window))
                ((symbol-function 'window-live-p)
                 (lambda (_w) t))
                ((symbol-function 'elneo-room--window-at-end-p)
                 (lambda (_w) t)))
        ;; at the live end, a reaction id becomes the pending mark
        (elneo-room--advance-read-marker "mxtest" "!r:mxtest.org" "$react:1")
        (mx-check "pass-over: last-event-id advanced"
                  (buffer-local-value 'elneo-room--last-event-id buf)
                  "$react:1")
        (mx-check "pass-over: pending armed"
                  (buffer-local-value 'elneo-room--read-pending-id buf)
                  "$react:1")
        (let ((tm (buffer-local-value 'elneo-room--read-timer buf)))
          (when tm (cancel-timer tm)))
        (with-current-buffer buf (elneo-room--send-read buf))
        (mx-check "pass-over: send uses the source id" sent "$react:1")
        (mx-check "pass-over: sent id recorded"
                  (buffer-local-value 'elneo-room--read-sent-id buf)
                  "$react:1")
        ;; identical re-arrival is deduped away
        (elneo-room--advance-read-marker "mxtest" "!r:mxtest.org" "$react:1")
        (mx-check "pass-over: dedup on re-arrival"
                  (buffer-local-value 'elneo-room--read-pending-id buf) nil)
        ;; the next invisible event re-arms
        (elneo-room--advance-read-marker "mxtest" "!r:mxtest.org" "$vote:2")
        (let ((tm (buffer-local-value 'elneo-room--read-timer buf)))
          (when tm (cancel-timer tm)))
        (with-current-buffer buf (elneo-room--send-read buf))
        (mx-check "pass-over: vote re-arms and sends" sent "$vote:2")
        ;; scrolled-up window: bookkeeping advances, nothing is armed
        (cl-letf (((symbol-function 'elneo-room--window-at-end-p)
                   (lambda (_w) nil)))
          (elneo-room--advance-read-marker "mxtest" "!r:mxtest.org" "$edit:3"))
        (mx-check "pass-over: scrolled up keeps pending"
                  (buffer-local-value 'elneo-room--read-pending-id buf) nil)
        (mx-check "pass-over: scrolled up still advances"
                  (buffer-local-value 'elneo-room--last-event-id buf)
                  "$edit:3")
        ;; unknown room ids and nil sources are inert
        (elneo-room--advance-read-marker "mxtest" "!other:mxtest.org" "$vote:4")
        (elneo-room--advance-read-marker "mxtest" "!r:mxtest.org" nil)
        (mx-check "pass-over: unknown room is inert"
                  (buffer-local-value 'elneo-room--last-event-id buf)
                  "$edit:3"))
      (remhash (cons "mxtest" "!r:mxtest.org") elneo-room--buffers)
      (kill-buffer buf))

    ;; --- hook wiring: the consumers run the pass-over ---
    (let ((buf (get-buffer-create " *mx-test-room-wire*")))
      (with-current-buffer buf
        (elneo-room-mode)
        (setq elneo-room--profile "mxtest"
              elneo-room--room-id "!rw:mxtest.org"
              elneo-room--seen (make-hash-table :test 'equal)
              elneo-room--reactions (make-hash-table :test 'equal)
              elneo-room--backfilled t
              elneo-room--read-pending-id nil
              elneo-room--read-sent-id nil
              elneo-room--read-timer nil))
      (puthash (cons "mxtest" "!rw:mxtest.org") buf elneo-room--buffers)
      (cl-letf (((symbol-function 'elneo-room-mark-read) #'ignore)
                ((symbol-function 'get-buffer-window)
                 (lambda (_buf _all) 'fake-window))
                ((symbol-function 'window-live-p)
                 (lambda (_w) t))
                ((symbol-function 'elneo-room--window-at-end-p)
                 (lambda (_w) t)))
        ;; an unrendered poll (no fold): the render branch skips, the
        ;; pass-over must still arm — the badge moves on votes
        (elneo-room--on-poll-update
         (list :profile "mxtest" :room-id "!rw:mxtest.org"
               :event-id "$pollstart" :source-event-id "$vote:10"
               :poll nil))
        (mx-check "poll hook: pass-over without a fold"
                  (buffer-local-value 'elneo-room--read-pending-id buf)
                  "$vote:10")
        ;; reactions update with an unknown target renders nothing
        (elneo-room--on-reactions-update
         (list :profile "mxtest" :room-id "!rw:mxtest.org"
               :event-id "$target" :source-event-id "$react:11"
               :reactions nil))
        (mx-check "reactions hook: pass-over armed"
                  (buffer-local-value 'elneo-room--read-pending-id buf)
                  "$react:11")
        ;; an edit for an unknown event renders nothing, pass-over still runs
        (elneo-room--on-edited
         (list :profile "mxtest" :room-id "!rw:mxtest.org"
               :event-id "$target" :source-event-id "$edit:12"
               :body "x" :formatted-body nil :msgtype "m.text"
               :media nil :geo nil :edited-ts 0))
        (mx-check "edited hook: pass-over armed"
                  (buffer-local-value 'elneo-room--read-pending-id buf)
                  "$edit:12")
        ;; a nil source (redaction-echo path) changes nothing
        (elneo-room--on-reactions-update
         (list :profile "mxtest" :room-id "!rw:mxtest.org"
               :event-id "$target" :source-event-id nil
               :reactions nil))
        (mx-check "redaction path: no pass-over"
                  (buffer-local-value 'elneo-room--read-pending-id buf)
                  "$edit:12"))
      (remhash (cons "mxtest" "!rw:mxtest.org") elneo-room--buffers)
      (kill-buffer buf))

  (message "results: %d passed, %d failed" pass fail)
  (when (> fail 0) (kill-emacs 1)))