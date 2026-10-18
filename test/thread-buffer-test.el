;;; thread-buffer-test.el --- thread views (MSC3440) -*- lexical-binding: t; -*-

;; Synthetic test for the thread view: the registry, the pinned root,
;; pagination through the room's prepend machinery, the thread
;; consumers, the thread-root send, the send-ack re-key, and the
;; read-mark suppression.  Receipts-test.el style — no daemon.
;;
;; Run: emacs -Q --batch -L lisp -l test/thread-buffer-test.el

(require 'cl-lib)
(require 'elneo-room)
(require 'elneo-thread)

(let ((pass 0) (fail 0)
      (root-entry (list :event-id "$root" :ts 1 :sender "@a:mx.org"
                        :is-own nil :msgtype "m.text" :body "the root"))
      (entries (list (list :event-id "$r1" :ts 2 :sender "@b:mx.org"
                           :is-own nil :msgtype "m.text"
                           :body "first reply" :thread-root "$root")))
      buf)

  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defun mx-count-text (needle)
    (with-current-buffer buf
      (let ((n 0))
        (save-excursion
          (goto-char (point-min))
          (while (search-forward needle nil t)
            (cl-incf n)))
        n)))

  (defun mx-faces-at (pos)
    (let ((f (get-text-property pos 'face)))
      (if (listp f) f (list f))))

  ;; A wire entry alist, the shape `elneo-room--message-from-entry'
  ;; reads off the daemon's pages.
  (defun mx-entry (id sender body ts &optional thread-root)
    (append (list (cons 'event_id id) (cons 'sender sender)
                  (cons 'body body) (cons 'ts ts)
                  (cons 'msgtype "m.text"))
            (when thread-root (list (cons 'thread_root thread-root)))))

  ;; An `updateThreadMessages' event: optional root entry, optional
  ;; next page, optional end token.
  (defun mx-page (&optional root-alist msgs end page-root)
    (append (list (cons '@ok t) (cons 'room_id "!r:mxtest.org")
                  (cons 'thread_root (or page-root "$root")))
            (when root-alist (list (cons 'root root-alist)))
            (list (cons 'messages (vconcat msgs)))
            (when end (list (cons 'end end)))))

  (defun mx-open (&optional root-msg)
    (cl-letf (((symbol-function 'elneo-room-thread-messages)
               (lambda (_p _room room-root limit from _cb)
                 (mx-check "the first page fetch goes to the daemon"
                           (list room-root limit from)
                           (list "$root" elneo-thread-page-size nil))))
              ((symbol-function 'pop-to-buffer) #'ignore))
      (elneo-thread-open "mxtest" "!r:mxtest.org" "$root" root-msg)))

  (unwind-protect
      (progn
        ;; --- the registry (never the room registry) ---
        (setq buf (mx-open root-entry))
        (with-current-buffer buf
          (mx-check "open is a thread view of the root"
                    (list (and elneo-room--thread-root t)
                          elneo-room--room-id)
                    (list t "!r:mxtest.org")))
        (let ((b2 (mx-open root-entry)))
          (mx-check "open reuses the buffer (registry key)"
                    (eq b2 buf) t)
          (mx-check "the thread registry holds it"
                    (eq (gethash (list "mxtest" "!r:mxtest.org" "$root")
                                 elneo-thread--buffers)
                        buf)
                    t)
          (mx-check "the room registry does not know this buffer"
                    (and (not (member buf (hash-table-values
                                           elneo-room--buffers)))
                         t)
                    t)
          (kill-buffer buf)
          (mx-check "kill-buffer unregisters the view"
                    (hash-table-count elneo-thread--buffers) 0))

        ;; --- first page: pinned root, replies, bookkeeping ---
        ;; A root page with no room buffer behind it (the open path
        ;; that knows only the root id).
        (setq buf (progn (clrhash elneo-thread--buffers) (mx-open nil)))
        (with-current-buffer buf
          (mx-check "the unseeded root entry is nil"
                    elneo-thread--root-entry nil)
          (elneo-thread--on-history
           "mxtest"
           (mx-page (list (cons 'event_id "$root")
                          (cons 'sender "@a:mx.org")
                          (cons 'body "the root") (cons 'ts 1))
                    (list (mx-entry "$r1" "@b:mx.org" "first reply" 2
                                    "$root"))
                    "tok1"))
          (mx-check "the page's root became the pinned quote"
                    (plist-get elneo-thread--root-entry :event-id) "$root")
          (mx-check "root renders above the replies"
                    (< (progn (goto-char (point-min))
                              (search-forward "the root") (point))
                       (progn (search-forward "first reply") (point)))
                    t)
          (mx-check "the root block carries its event id"
                    (get-text-property
                     (progn (goto-char (point-min))
                            (search-forward "the root")
                            (line-beginning-position))
                     'elneo-room-event-id)
                    "$root")
          (goto-char (point-min))
          (search-forward "the root")
          (mx-check "the root block is tinted"
                    (and (memq 'elneo-room-thread (mx-faces-at (1- (point))))
                         t)
                    t)
          (goto-char (point-min))
          (mx-check "thread views force 'none' marks (no glyph noise)"
                    (and (not (search-forward elneo-room-thread-glyph
                                              nil t))
                         t)
                    t)
          (mx-check "the first page's end-token feeds the pager"
                    elneo-room--end-token "tok1")
          (mx-check "the newest reply advances the last-event-id"
                    elneo-room--last-event-id "$r1")

          ;; --- pagination: an older page prepends below the root ---
          (setq elneo-room--loading-older t)
          (elneo-thread--on-history
           "mxtest"
           (mx-page nil (list (mx-entry "$r0" "@b:mx.org"
                                        "older reply" 1 "$root"))
                    "tok2"))
          (let ((root-pos (progn (goto-char (point-min))
                                 (search-forward "the root")
                                 (line-beginning-position)))
                (older-pos (save-excursion
                             (goto-char (point-min))
                             (search-forward "older reply")
                             (line-beginning-position)))
                (reply-pos (progn (goto-char (point-min))
                                  (search-forward "first reply")
                                  (line-beginning-position))))
            (mx-check "older reply lands below the root"
                      (< root-pos older-pos) t)
            (mx-check "older reply lands above the first page"
                      (< older-pos reply-pos) t))
          (mx-check "the page's end-token updated"
                    elneo-room--end-token "tok2")

          ;; --- the live consumers ---
          (let ((reply (list :profile "mxtest" :room-id "!r:mxtest.org"
                             :event-id "$live1" :ts 3
                             :sender "@b:mx.org" :is-own t
                             :msgtype "m.text" :body "live reply"
                             :thread-root "$root")))
            (elneo-thread--on-new-message reply)
            (mx-check "a live thread reply appends to the view"
                      (mx-count-text "live reply") 1)
            (mx-check "the reply joined the view's seen table"
                      (and (gethash "$live1" elneo-room--seen) t) t)
            (elneo-thread--on-new-message reply)
            (mx-check "a duplicate echo does not double-render"
                      (mx-count-text "live reply") 1)
            (elneo-thread--on-new-message
             (list :profile "mxtest" :room-id "!r:mxtest.org"
                   :event-id "$other" :ts 3
                   :sender "@b:mx.org" :is-own nil
                   :msgtype "m.text" :body "other thread"
                   :thread-root "$other-root"))
            (mx-check "another thread's reply does not land here"
                      (mx-count-text "other thread") 0))

          ;; reactions reach the view's own rendered messages
          (elneo-thread--on-reactions-update
           (list :profile "mxtest" :room-id "!r:mxtest.org"
                 :event-id "$live1"
                 :reactions
                 (list (list :key "👍" :count 1 :own nil
                             :user-id "@b:mx.org"))))
          (goto-char (point-min))
          (mx-check "a reaction line renders in the view"
                    (and (search-forward "👍" nil t) t) t)
          ;; edits re-render inside the view
          (elneo-thread--on-edited
           (list :profile "mxtest" :room-id "!r:mxtest.org"
                 :event-id "$live1" :body "edited reply"
                 :msgtype "m.text"))
          (mx-check "an edit re-renders inside the view"
                    (list (mx-count-text "edited reply")
                          (mx-count-text "live reply"))
                    (list 1 0))
          ;; redactions mark the view's message, keeping the reply a
          ;; thread reply
          (elneo-thread--on-redaction
           (list :profile "mxtest" :room-id "!r:mxtest.org"
                 :event-id "$live1"))
          (mx-check "a redaction marks the view's message"
                    (plist-get (gethash "$live1" elneo-room--seen)
                               :redacted)
                    t)
          (mx-check "the redacted reply stays a thread reply"
                    (plist-get (gethash "$live1" elneo-room--seen)
                               :thread-root)
                    "$root")

          ;; --- the send path: thread-root on the wire, ack re-keys ---
          (let (captured sent)
            (goto-char (point-min))
            (search-forward "first reply")
            (goto-char (line-beginning-position))
            (call-interactively #'elneo-room--r)
            (cl-letf (((symbol-function 'elneo-send-message)
                       (lambda (_p _r body cb _f reply-to edit-to
                               _ids _mention thread-root)
                         (setq captured (list body reply-to
                                              edit-to thread-root)
                               sent cb)
                         42))
                      ((symbol-function 'elneo-room--send-mentions)
                       (lambda (_b) (list :ids nil :room nil)))
                      ((symbol-function 'elneo-room--rich-send-p)
                       (lambda (&optional _room) nil))
                      ((symbol-function 'elneo-room--update-separator)
                       (lambda () nil)))
              (elneo-room--send-text "thread send"))
            ;; Reply mode on a thread reply names the in-thread target
            ;; AND the root: the genuine m.in_reply_to of an
            ;; Element-readable thread reply.
            (mx-check "the send carries reply-to and the root"
                      captured
                      (list "thread send" "$r1" nil "$root"))
            ;; The optimistic echo re-keys when the ack lands.
            (let ((pending (catch 'id
                             (maphash
                              (lambda (id _m)
                                (when (elneo-room--provisional-p id)
                                  (throw 'id id)))
                              elneo-room--seen))))
              (mx-check "the echo rendered as a pending thread reply"
                        (and pending
                             (equal (plist-get
                                     (gethash pending elneo-room--seen)
                                     :thread-root)
                                    "$root"))
                        t)
              (funcall sent "mxtest"
                       (list (cons '@ok t) (cons '@req 42)
                             (cons 'event_id "$own1")))
              (mx-check "the ack re-keys to the server's event id"
                        (list (and (gethash "$own1" elneo-room--seen) t)
                              (gethash pending elneo-room--seen)
                              elneo-room--last-event-id)
                        (list t nil "$own1"))
              (goto-char (point-min))
              (mx-check "the echo block survives the re-key"
                        (and (search-forward "thread send" nil t) t)
                        t)))

          ;; --- read marks: suppressed here, real in the room buffer ---
          (setq elneo-room--backfilled t
                elneo-room--last-event-id "$own1"
                elneo-room--read-pending-id nil)
          (let ((marked nil))
            (cl-letf (((symbol-function 'elneo-room-mark-read)
                       (lambda (&rest _) (setq marked t))))
              (elneo-room--maybe-mark-read)
              (mx-check "a thread view schedules no read mark"
                        elneo-room--read-pending-id nil)
              (mx-check "a thread view armed no timer"
                        elneo-room--read-timer nil)
              ;; the direct gate: send-read would still refuse
              (setq elneo-room--read-pending-id "$own1")
              (elneo-room--send-read (current-buffer))
              (mx-check "a thread view sends no receipt"
                        marked nil)
              (mx-check "the thread view kept the pending id"
                        elneo-room--read-sent-id nil)))

          ;; --- the room half still marks ---
          ;; The same machinery with no thread-root: send-read goes out.
          (let ((roombuf (get-buffer-create " *mx-thread-room-half*"))
                (marked nil))
            (with-current-buffer roombuf
              (elneo-room-mode)
              (setq elneo-room--profile "mxtest"
                    elneo-room--room-id "!r:mxtest.org"
                    elneo-room--backfilled t
                    elneo-room--read-pending-id "$own2")
              (unwind-protect
                  (progn
                    (cl-letf (((symbol-function 'elneo-room-mark-read)
                               (lambda (&rest _) (setq marked t))))
                      (mx-check "the room buffer has no thread root"
                                elneo-room--thread-root nil)
                      (elneo-room--send-read (current-buffer))
                      (mx-check "the room buffer sends the receipt"
                                marked t)
                      (mx-check "the receipt names the pending id"
                                elneo-room--read-sent-id "$own2")))
                ;; cancel a timer the room half may have armed
                (when elneo-room--read-timer
                  (cancel-timer elneo-room--read-timer)))))

          ;; --- edits are not supported in a thread view yet ---
          (goto-char (point-min))
          ;; a real seen message here: the root quote is static, so
          ;; put point on the own echo's block instead
          (search-forward "thread send")
          (goto-char (line-beginning-position))
          (mx-check "e in a thread view user-errors"
                    (condition-case err
                        (progn (call-interactively #'elneo-room--e) nil)
                      (user-error (cadr err)))
                    "Editing thread replies is not supported yet"))

        ;; --- the daemon omits `root' when it cannot produce an
        ;; entry: the old unguarded message-from-entry built a plist
        ;; of nils there and the render crashed on the nil ts ---
        (setq buf (progn (clrhash elneo-thread--buffers) (mx-open nil)))
        (with-current-buffer buf
          (elneo-thread--on-history
           "mxtest"
           (mx-page nil (list (mx-entry "$r9" "@b:mx.org"
                                        "orphan reply" 9 "$root"))
                    "tok9"))
          (mx-check "a rootless page renders the placeholder"
                    (mx-count-text "[thread root unavailable") 1)
          (mx-check "a rootless page's replies still render"
                    (mx-count-text "orphan reply") 1)
          (mx-check "a rootless page still completes the view"
                    elneo-room--backfilled t)
          (mx-check "a rootless page still hands the pager the token"
                    elneo-room--end-token "tok9")
          (mx-check "no phantom root entry without a `root'"
                    (and (not (gethash "$root" elneo-room--seen)) t)
                    t)
          (mx-check "the rootless view keeps the root slot nil"
                    elneo-thread--root-entry nil))
        (kill-buffer buf)

        ;; --- the pinned root joins the seen table (one render-time
        ;; decision serving both documented consumers: `r' on the
        ;; quote, and fetched replies answering the root) ---
        (setq buf (progn (clrhash elneo-thread--buffers) (mx-open nil)))
        (with-current-buffer buf
          (elneo-thread--on-history
           "mxtest"
           (mx-page (list (cons 'event_id "$root")
                          (cons 'sender "@a:mx.org")
                          (cons 'body "the root") (cons 'ts 1))
                    (list (append (mx-entry "$r4" "@b:mx.org"
                                           "answering reply" 2 "$root")
                                  (list (cons 'reply_to "$root"))))
                    "tok1"))
          (mx-check "the pinned root registered in the seen table"
                    (plist-get (gethash "$root" elneo-room--seen) :body)
                    "the root")
          (goto-char (point-min))
          (mx-check "a reply naming the root quotes it in full"
                    (and (search-forward "↳ @a:mx.org: the root" nil t) t)
                    t)
          (mx-check "no degraded 'older message' quote for the root"
                    (mx-count-text "older message") 0)
          (goto-char (point-min))
          (search-forward "the root")
          (goto-char (line-beginning-position))
          (call-interactively #'elneo-room--r)
          (mx-check "r on the pinned root starts a reply to it"
                    elneo-room--reply-to "$root")
          (mx-check "the pending reply carries the root's sender"
                    elneo-room--reply-sender "@a:mx.org")
          (elneo-room-cancel-reply))
        (kill-buffer buf)

        ;; --- media sends from a thread view thread the attachment ---
        ;; (room.el --send-media passes the view's thread root;
        ;; room buffers pass nil)
        (setq buf (progn (clrhash elneo-thread--buffers) (mx-open nil)))
        (with-current-buffer buf
          (let* ((dir (make-temp-file "mx-sndimg" t))
                 (png (expand-file-name "shot.png" dir))
                 (captured :unset))
            (unwind-protect
                (progn (write-region "" nil png)
                       (cl-letf (((symbol-function 'elneo-room-image)
                                  (lambda (_p _r _file _cb thread-root _s)
                                    (setq captured thread-root)))
                                 ((symbol-function 'elneo-room--on-send-result)
                                  #'ignore))
                         (elneo-room--send-image png)
                         (mx-check "a media send from the view threads it"
                                   captured "$root")
                         (setq-local elneo-room--thread-root nil)
                         (setq captured :unset)
                         (elneo-room--send-image png)
                         (mx-check "a room-buffer media send stays unthreaded"
                                   captured nil)
                         (setq-local elneo-room--thread-root "$root"))
                  (delete-directory dir t))))))

        ;; --- a failed first page re-fetches on re-open (round 3.1) ---
        ;; A fetch that never lands (daemon answer fails or is missing)
        ;; leaves `backfilled' nil; re-running `t' must drive the
        ;; first-page fetch again — the top-of-buffer pager cannot (it
        ;; gates on `backfilled').
        (progn
          (clrhash elneo-thread--buffers)
          (setq buf nil)
          (let ((calls 0))
            (cl-letf (((symbol-function 'elneo-room-thread-messages)
                       (lambda (&rest _) (setq calls (1+ calls))))
                      ((symbol-function 'pop-to-buffer) #'ignore))
              (setq buf (elneo-thread-open "mxtest" "!r:mxtest.org" "$fail"))
              (with-current-buffer buf
                (mx-check "a failed first page leaves the view unfilled"
                          (list elneo-room--backfilled
                                (mx-count-text "Loading thread"))
                          (list nil 1))
                (elneo-thread-open "mxtest" "!r:mxtest.org" "$fail")
                (mx-check "re-opening an unfilled view re-fetches" calls 2)
                (elneo-thread--on-history
                 "mxtest" (mx-page nil (list (mx-entry "$lf" "@b:mx.org" "late reply" 2 "$fail")) "tokF" "$fail"))
                (mx-check "a late first page fills the view" elneo-room--backfilled t)
                (mx-check "the filled view's replies render" (mx-count-text "late reply") 1)
                (elneo-thread-open "mxtest" "!r:mxtest.org" "$fail")
                (mx-check "a filled view does not re-fetch on re-open" calls 2)))))

        ;; --- keys/restart invalidation reaches thread views (round 3.1) ---
        (progn
          (let ((fetched 0))
            (clrhash elneo-thread--buffers)
            (setq buf nil)
            (cl-letf (((symbol-function 'elneo-room-thread-messages)
                       (lambda (&rest _) (setq fetched (1+ fetched))))
                      ((symbol-function 'pop-to-buffer) #'ignore)
                      ((symbol-function 'run-with-idle-timer)
                       ;; capture the idle callback; the test fires it
                       (lambda (_secs _fn callback &rest args)
                         (lambda () (apply callback args)))))
              (setq buf (elneo-thread-open "mxtest" "!r:mxtest.org" "$fail"))
              (with-current-buffer buf
                (elneo-thread--on-history
                 "mxtest" (mx-page nil (list (mx-entry "$k1" "@b:mx.org" "keyed reply" 2 "$fail")) "tokK" "$fail"))
                (mx-check "the view is filled before the keys arrive" elneo-room--backfilled t)
                ;; keys arrive for the room: the thread view re-fetches
                ;; debounced (the room is not open here, so the room
                ;; walk finds nothing)
                (let ((fire (elneo-room--on-keys-updated "mxtest" "!r:mxtest.org")))
                  (mx-check "the keys walk armed the view's timer"
                            (and elneo-room--keys-timer t) t)
                  (funcall fire)
                  (mx-check "the keys re-render re-fetched the thread" fetched 2)
                  (mx-check "the refill cleared the debouncer"
                            (and (not elneo-room--keys-timer) t) t)
                  ;; refill (the stubbed fetch never delivers), then a
                  ;; burst: only one timer stands, the armed one wins
                  (elneo-thread--on-history
                   "mxtest" (mx-page nil (list (mx-entry "$k1" "@b:mx.org" "keyed reply" 2 "$fail")) "tokK" "$fail"))
                  (let ((armed (elneo-room--on-keys-updated "mxtest" "!r:mxtest.org")))
                    (mx-check "a fresh keys event arms one timer"
                              (and armed t) t)
                    (elneo-room--on-keys-updated "mxtest" "!r:mxtest.org")
                    (mx-check "the burst does not re-arm the debouncer"
                              (eq elneo-room--keys-timer armed) t)
                    (mx-check "no extra fetch while it waits" fetched 2)
                    (funcall armed)
                    (mx-check "the armed timer still re-fetches" fetched 3))))))

        ;; --- restart invalidation resets thread history state ---
        (progn
          (clrhash elneo-thread--buffers)
          (setq buf nil)
          (let ((fetched 0))
            (cl-letf (((symbol-function 'elneo-room-thread-messages)
                       (lambda (&rest _) (setq fetched (1+ fetched))))
                      ((symbol-function 'pop-to-buffer) #'ignore))
              (setq buf (elneo-thread-open "mxtest" "!r:mxtest.org" "$fail"))
              (with-current-buffer buf
                (elneo-thread--on-history
                 "mxtest" (mx-page nil (list (mx-entry "$k2" "@b:mx.org" "restart reply" 2 "$fail")) "tokR" "$fail"))
                ;; restart invalidation: the state resets, and the next
                ;; re-open re-fetches (no window in batch — nothing
                ;; refetches here directly)
                (elneo-room--invalidate-on-activate "mxtest")
                (mx-check "restart resets the view's filled flag" elneo-room--backfilled nil)
                (mx-check "restart drops the pager token" elneo-room--end-token nil)
                (mx-check "restart clears the pending media table"
                          (and (hash-table-p elneo-room--media-pending) t) t)
                (mx-check "restart re-fetches on the next open"
                          (progn (elneo-thread-open "mxtest" "!r:mxtest.org" "$fail") fetched)
                          2))))))

        ;; --- a rootless page renders the root the view already holds
        ;; ---
        ;; Preserving the variable alone would be fiction: the view's
        ;; consumers (the seen registration, the pinned quote) must
        ;; receive the MERGED value.  Window: the root fell beyond the
        ;; homeserver's backfill horizon after a daemon restart, so the
        ;; page arrives without a `root'.
        (progn
          (clrhash elneo-thread--buffers)
          (setq buf (mx-open root-entry))
          (with-current-buffer buf
            (elneo-thread--on-history
             "mxtest"
             (mx-page nil (list (mx-entry "$rH" "@b:mx.org"
                                         "held-root reply" 2 "$root"))
                      "tokH"))
            (mx-check "a rootless page keeps the held root"
                      elneo-thread--root-entry root-entry)
            (mx-check "the held root renders instead of the placeholder"
                      (list (mx-count-text "the root")
                            (mx-count-text "thread root unavailable"))
                      (list 1 0))
            (mx-check "the held root registered in the seen table"
                      (plist-get (gethash "$root" elneo-room--seen) :body)
                      "the root")))
        (kill-buffer buf)

        ;; An edit or redaction OF the pinned root re-renders through
        ;; the standard replace path — the view re-applies its hue
        ;; over the block afterwards.
        (progn
          (clrhash elneo-thread--buffers)
          (setq buf (mx-open root-entry))
          (with-current-buffer buf
            (elneo-thread--on-history
             "mxtest"
             (mx-page (list (cons 'event_id "$root")
                            (cons 'sender "@a:mx.org")
                            (cons 'body "the root") (cons 'ts 1))
                      nil "tokT"))
            (elneo-thread--on-edited
             (list :profile "mxtest" :room-id "!r:mxtest.org"
                   :event-id "$root" :body "edited root"
                   :msgtype "m.text"))
            (mx-check "an edit of the root re-renders its body"
                      (mx-count-text "edited root") 1)
            (goto-char (point-min))
            (search-forward "edited root")
            (mx-check "an edit of the root keeps its tint"
                      (and (memq 'elneo-room-thread
                                 (mx-faces-at (1- (point))))
                           t)
                      t)
            (elneo-thread--on-redaction
             (list :profile "mxtest" :room-id "!r:mxtest.org"
                   :event-id "$root"))
            (goto-char (point-min))
            (search-forward "[redacted]")
            (mx-check "a redaction of the root keeps its tint"
                      (and (memq 'elneo-room-thread
                                 (mx-faces-at (1- (point))))
                           t)
                      t)))
        (kill-buffer buf)

        ;; A bounced first page (keys/restart refetch) no longer
        ;; strands the view: the failure branch retries the fetch a
        ;; few times while the view stays unfilled, mirroring the
        ;; room's history-failure loop.  Delivery is via the captured
        ;; CALLBACK the fetch was issued with, and the failure event
        ;; is the wire's real shape — a bare `@req' ack with no
        ;; room_id and no thread_root (protocol.rs's golden), which is
        ;; exactly why the routing lives in the callback.
        (progn
          (clrhash elneo-thread--buffers)
          (setq buf (mx-open root-entry))
          (with-current-buffer buf
            (let ((fetches 0) callback fired
                  (ack (list (cons '@req 1) (cons '@ok nil)
                             (cons '@error "boom"))))
              (cl-letf (((symbol-function 'elneo-room-thread-messages)
                         (lambda (_p _room _root _limit _from cb)
                           (setq fetches (1+ fetches)
                                 callback cb)))
                        ((symbol-function 'run-with-timer)
                         (lambda (_secs _rep fn &rest _)
                           (setq fired fn) :timer)))
                (elneo-thread--fetch-first-page)
                (mx-check "the fetch was issued with a page callback"
                          (functionp callback) t)
                (funcall callback "mxtest" ack)
                (mx-check "a bare-ack failure arms exactly one retry timer"
                          (and fired t) t)
                (mx-check "the failure bumped the retry counter"
                          elneo-room--history-retries 1)
                (mx-check "a failed first page leaves the view unfilled"
                          elneo-room--backfilled nil)
                (mx-check "nothing fetched during the failure itself"
                          fetches 1)
                (funcall fired)
                (mx-check "the armed timer re-runs the first-page fetch"
                          fetches 2)
                ;; until the cap: two more failures are allowed
                (funcall callback "mxtest" ack)
                (funcall callback "mxtest" ack)
                (mx-check "retries are capped at three"
                          elneo-room--history-retries 3)
                ;; the fourth failure schedules nothing
                (setq fired nil)
                (funcall callback "mxtest" ack)
                (mx-check "the cap arms no further timer" fired nil)
                ;; the success page routes through the same callback
                ;; into the view: the render path is unchanged.
                (funcall callback "mxtest"
                         (mx-page nil (list (mx-entry "$rC" "@b:mx.org"
                                                     "callback reply" 3
                                                     "$root"))
                                  "tokC"))
                (mx-check "a successful page routed via the callback fills"
                          elneo-room--backfilled t)
                (mx-check "the callback-routed page renders"
                          (list (mx-count-text "callback reply")
                                (mx-count-text "the root"))
                          (list 1 1))))))
        (kill-buffer buf)

    ;; cleanup: every created buffer and registry leftover
    (let ((inhibit-quit t))
      (dolist (b (buffer-list))
        (when (string-prefix-p " *mx-thread" (buffer-name b))
          (kill-buffer b)))
      (clrhash elneo-thread--buffers)
      (clrhash elneo-room--buffers)
      (setq buf nil)))

  (message "results: %d passed, %d failed" pass fail)
  (when (> fail 0) (kill-emacs 1)))