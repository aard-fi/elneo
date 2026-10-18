;;; elneo-thread.el --- thread (MSC3440) views for Matrix rooms -*- lexical-binding: t; -*-

;;; Commentary:

;; A thread view: one thread of a room, root pinned as a quote on
;; top, the replies (which also sit inline in the room view) linear
;; below.  Derived from `elneo-room-mode', not a room of its own:
;; the send path, the reply machinery, the pager and the echo
;; re-keying are the room's, narrowed by `elneo-room--thread-root'.
;; The buffer never enters the room registry
;; (`elneo-room--buffers'): room consumers reach buffers through
;; that registry, so they can never touch a thread view by accident;
;; a thread view has its own consumers on the same hooks.

;;; Code:

(require 'elneo-room)

(declare-function elneo-room--replace-reaction-line "elneo-room" (pos event-id entries))

(defconst elneo-thread-page-size 50
  "Thread entries per page (the room buffer's page size).")

(defvar elneo-thread--buffers (make-hash-table :test 'equal)
  "Thread view buffers keyed (profile room-id root-id), last wins.
Not the room registry: a thread view must never be found by
`elneo-room--buffer-for' — room read-mark pass-overs target the
room buffer only.")

(defvar-local elneo-thread--root-entry nil
  "Buffer-local: the thread root's message plist, or nil until the
daemon's page answer carries it (a buffer opened from a room
buffer's seen table has it at once).  Rendered once per page:
static context, not a live block — the root registers in the seen
table at render time, so reactions, edits and redactions on the
root itself reach this view through the standard consumers too
(and its reactions render in the room buffer regardless).")

(defun elneo-thread--buffer-for (profile room-id root-id)
  "The thread view of PROFILE's ROOM-ID and ROOT-ID, or nil."
  (let ((buffer (gethash (list profile room-id root-id)
                         elneo-thread--buffers)))
    (and (buffer-live-p buffer) buffer)))

(defun elneo-thread--buffers-for (profile room-id)
  "All live thread view buffers of PROFILE's ROOM-ID."
  (let (found)
    (maphash (lambda (key buffer)
               (when (and (equal (nth 0 key) profile)
                          (equal (nth 1 key) room-id)
                          (buffer-live-p buffer))
                 (push buffer found)))
             elneo-thread--buffers)
    found))

(defun elneo-thread--kill ()
  "Remove this thread view from the registry."
  (maphash (lambda (key buffer)
             (when (eq buffer (current-buffer))
               (remhash key elneo-thread--buffers)))
           elneo-thread--buffers))

(define-derived-mode elneo-thread-mode elneo-room-mode "Thread"
  "Major mode for a Matrix thread view (MSC3440).
The root sits pinned at the top (static, styled as a quote), the
thread's replies render linearly below — the same blocks the room
buffer shows inline.  RET sends into the thread (a thread reply);
`r' replies to the message at point (a genuine in-thread reply);
the room's read marking is off here — a thread view never marks
the room read."
  (setq-local elneo-room-thread-marks 'none)
  ;; The room mode's kill hook persists drafts under the ROOM's key;
  ;; draft saving is off for thread views, so drop the hook and take
  ;; the registry cleanup instead.
  (remove-hook 'kill-buffer-hook #'elneo-room--draft-kill-save t)
  (add-hook 'kill-buffer-hook #'elneo-thread--kill nil t))

(defun elneo-thread-open (profile room-id root-id &optional root-msg)
  "Open (or redisplay) the thread view of ROOT-ID in PROFILE's ROOM-ID.
ROOT-MSG, when given, is the root's known message plist (from the
room buffer's seen table): it pins the quote at once, before the
daemon's page arrives.  The buffer is created directly, never
through `elneo-room--buffer' — it must not enter the room
registry (see `elneo-thread--buffers').  A thread view never
marks the room read; per-thread receipts are a later slice.
Returns the buffer."
  (let* ((buffer (elneo-thread--buffer-for profile room-id root-id))
         (existed buffer))
    (unless buffer
      (setq buffer (generate-new-buffer
                    (format "*Matrix: %s: thread %s*"
                            profile
                            (or (ignore-errors
                                  (substring root-id 1 12))
                                root-id))))
      (puthash (list profile room-id root-id) buffer elneo-thread--buffers)
      (with-current-buffer buffer
        (elneo-thread-mode)
        ;; The room buffer-local contract (`elneo-room--seed-locals'
        ;; — the same list `elneo-room--buffer' seeds), minus the room
        ;; registry entry: the thread view is a room's subview, sending
        ;; to the same room.  The draft pair is the empty twin of the
        ;; room's store restore — thread views never save drafts.  The
        ;; root locals are the view's own additions.
        (elneo-room--seed-locals profile room-id)
        (setq-local elneo-room--pending-draft nil)
        (setq-local elneo-room--draft-saved-text "")
        (setq-local elneo-room--thread-root root-id)
        (setq-local elneo-thread--root-entry root-msg)
        (insert (propertize "Loading thread…\n" 'face 'shadow))
        ;; No retry timer here: a thread fetch usually lands after the
        ;; room's first page (the root id comes from it), and a failure
        ;; stays one message away from `t' again.
        (elneo-thread--fetch-first-page)))
    (when (and existed (buffer-live-p buffer)
               (not (buffer-local-value 'elneo-room--backfilled buffer)))
      ;; Re-opening a view whose first page failed or never arrived:
      ;; without this the "Loading thread..." line survives forever — the
      ;; top-of-buffer pager gates on `backfilled' (room's
      ;; `--maybe-load-older'), so it cannot rescue a never-filled view.
      ;; Double delivery is safe: a second on-history first page just
      ;; re-renders.
      (with-current-buffer buffer
        (elneo-thread--fetch-first-page)))
    (pop-to-buffer buffer)
    buffer))

;; The draft is saved via the room's own hook; thread views never
;; save drafts (`elneo-room--draft-maybe-save' gates on the root).
(defun elneo-thread--page-callback (buffer)
  "The callback for thread pages fetched out of BUFFER.
A failed response on the wire is a bare `@req' ack (`@ok' false,
`@error') — it carries no room_id and no thread_root, so a failure
cannot be routed through the registry the way a successful page
can; the closure that issued the fetch delivers it to the
requesting view (`--page-failed').  Successful pages keep the
registry-routed render path.  Arity is the pending-callback wire
contract, `(profile event)': the profile arrives from the
dispatcher and agrees with the buffer's buffer-local one."
  (lambda (profile event)
    (if (alist-get '@ok event nil nil #'equal)
        (elneo-thread--on-history profile event)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (elneo-thread--page-failed event))))))

(defun elneo-thread--fetch-first-page ()
  "Fetch the thread's newest page into this buffer."
  (let ((buf (current-buffer)))
    (elneo-room-thread-messages
     elneo-room--profile elneo-room--room-id elneo-room--thread-root
     elneo-thread-page-size nil (elneo-thread--page-callback buf))))

(defun elneo-thread--load-older ()
  "Fetch the next older thread page (room's `--load-older' dispatch).
The room's pager set up the rate limit and the older-mode state;
this only swaps the command and its callback."
  (let ((buf (current-buffer)))
    (elneo-room-thread-messages
     elneo-room--profile elneo-room--room-id elneo-room--thread-root
     elneo-thread-page-size elneo-room--end-token
     (elneo-thread--page-callback buf))))

(defun elneo-thread--page-failed (event)
  "A failed fetch response arrived in this thread view.
While the view is still unfilled, retry a few times, exactly the
room's history-failure catch (a freshly started daemon may reject
pages until its first sync seeds the rooms); a filled view keeps
its page — its older pages are re-tried by the top-of-buffer pager,
and this only clears the pager's in-flight latch."
  (message "Matrix [%s] thread fetch failed: %s"
           elneo-room--profile (elneo-server--error-string event))
  (setq elneo-room--loading-older nil)
  (when (and (null elneo-room--backfilled)
             (< elneo-room--history-retries 3))
    (setq elneo-room--history-retries (1+ elneo-room--history-retries))
    (let ((buf (current-buffer)))
      (run-with-timer 2.0 nil
                      (lambda ()
                        (when (buffer-live-p buf)
                          (with-current-buffer buf
                            (unless elneo-room--backfilled
                              (elneo-thread--fetch-first-page)))))))))

(defun elneo-thread--on-history (profile event)
  "Render (or prepend) an `updateThreadMessages' page for PROFILE.
First page: pinned root, then the replies; older pages flow through
the room's prepend machinery, anchored like room history.  A failed
first fetch leaves the loading line — re-running `t' re-fetches
(`elneo-thread-open' re-opens the view while `backfilled' is nil),
and the fetch callback (`--page-callback') retries it on a timer.
Once the view is filled, a failed older fetch keeps the page and
the top-of-buffer pager retries.  Failed fetches never arrive here:
they are bare `@req' acks without room_id/thread_root, routed to
the requesting view by `--page-callback'."
  (when (alist-get '@ok event nil nil #'equal)
    (let* ((room-id (alist-get 'room_id event))
           (root-id (alist-get 'thread_root event))
           (buffer (elneo-thread--buffer-for profile room-id root-id)))
      (when (buffer-live-p buffer)
        (let* ((entries (mapcar #'elneo-room--message-from-entry
                                (alist-get 'messages event)))
               ;; The daemon omits `root' entirely when it cannot
               ;; produce an entry (e.g. the root still undecryptable):
               ;; nil then flows to the placeholder, NOT a plist of
               ;; nils that would crash the render on its nil ts.
               (root-entry (when-let* ((root (alist-get 'root event)))
                             (elneo-room--message-from-entry root)))
               (end (alist-get 'end event))
               (window (get-buffer-window buffer t)))
          (with-current-buffer buffer
            (if (not elneo-room--backfilled)
                (elneo-thread--render-first-page root-entry entries end)
              (setq elneo-room--loading-older nil)
              (elneo-room--prepend-older-page entries end window))))))))

(defun elneo-thread--render-first-page (root-entry entries end)
  "Full render: header, pinned root quote, ENTRIES, input area.
The reader's position and draft follow the room render's contract.
A never-loaded root leaves a dim placeholder line — the replies
below still read."
  (let* ((window (get-buffer-window (current-buffer) t))
         (live-draft (elneo-room--draft-text))
         (draft (if (> (length live-draft) 0)
                    live-draft
                  elneo-room--pending-draft))
         (draft-offset (and elneo-room--backfilled
                            (>= (point) (elneo-room--input-beg-pos))
                            (- (point) (elneo-room--input-beg-pos)))))
    (let ((inhibit-read-only t))
      (erase-buffer))
    (setq elneo-room--seen (make-hash-table :test 'equal))
    (when (hash-table-p elneo-room--reactions)
      (clrhash elneo-room--reactions))
    (setq elneo-room--jump-target nil
          elneo-room--jump-pages 0)
    (elneo-room--header (elneo-room-get elneo-room--profile
                                        elneo-room--room-id))
    (goto-char (point-max))
    ;; A fetched root refreshes the static copy (replies above quote
    ;; it in full); a rootless page keeps the one the buffer already
    ;; holds — the root can sit beyond the homeserver backfill horizon
    ;; after a daemon restart.  Preserve alone is not enough: the
    ;; consumers below (the seen registration, the pinned quote) must
    ;; render the MERGED value, or a rootless page still shows the
    ;; placeholder while the root sits uselessly in a variable.
    (setq elneo-thread--root-entry
          (or root-entry elneo-thread--root-entry)
          root-entry elneo-thread--root-entry)
    ;; The pinned root joins the seen table: `r' on the quote starts a
    ;; genuine in-thread reply to the root, and fetched replies naming
    ;; the root quote it in full (not the degraded "older message").
    ;; append-messages never renders the root itself — the root carries
    ;; no thread relation, so it cannot be a page entry — and the
    ;; table's dedup is therefore unaffected.
    (when (and root-entry (plist-get root-entry :event-id))
      (puthash (plist-get root-entry :event-id) root-entry elneo-room--seen))
    (elneo-thread--insert-root root-entry)
    ;; Pagination prepends below the pinned root, not at the top of
    ;; the buffer: the root stays first (`elneo-room--prepend-point',
    ;; insertion-type nil — each page lands before the fresh marker).
    (setq elneo-room--prepend-point (copy-marker (point)))
    (elneo-room--append-messages entries)
    (setq elneo-room--backfilled t
          elneo-room--end-token end
          elneo-room--history-retries 0
          elneo-room--last-event-id
          (and entries (plist-get (car (last entries)) :event-id)))
    (setq elneo-room--pending-draft nil)
    (elneo-room--reset-input-area draft)
    (elneo-room--show-end window)
    (when (and draft-offset window (eq window (selected-window)))
      (goto-char (min (point-max)
                      (+ (elneo-room--input-beg-pos) draft-offset))))))

(defun elneo-thread--insert-root (root)
  "Pin the thread's ROOT (a message plist) as a quote at the view's top.
The block renders with the standard message renderer — reply legs
suppressed (`m.in_reply_to' at the top of a new thread view is
history now, not navigation) — framed by rules and dimmed with the
thread tint; its event id still rides the block's last line, so
`r' on the quote starts a genuine in-thread reply to the root.  The
root registers in the seen table at render time (`render-first-page'
does it, off the append-messages dedup pass): `r' finds it there, and
replies naming the root quote it in full.  It is otherwise static
context, re-rendered with each page.  A nil ROOT leaves a dim
placeholder (never registered: there is no id to reply to)."
  (let ((inhibit-read-only t)
        (id (or (and root (plist-get root :event-id))
                elneo-room--thread-root)))
    (insert (propertize (make-string 42 ?─) 'face 'shadow) "\n")
    (if root
        (let ((msg (copy-sequence root))
              (start (point)))
          (plist-put msg :reply-to nil)
          (plist-put msg :thread-root nil)
          (elneo-room--insert-message msg)
          (elneo-room--tint-thread
           start (point)
           (when elneo-room-thread-colors
             ;; this view IS one thread; tint the pinned quote its hue
             (elneo-room--thread-tint-face elneo-room--thread-root)))
          (save-excursion
            (put-text-property (line-beginning-position 0)
                               (line-end-position 0)
                               'elneo-room-event-id id)))
      (insert (propertize "[thread root unavailable — replies follow]"
                          'face 'shadow) "\n"))
    (insert (propertize (make-string 42 ?─) 'face 'shadow) "\n")))

;;; Live consumers

(defun elneo-thread--re-tint-root ()
  "Re-apply the thread hue over the pinned root's block.
`elneo-room--replace-message' re-renders through the standard
renderer, which knows nothing of the pinned quote's tint — an
edited or redacted root would drop its hue and its background.
Idempotent: `--tint-thread' skips segments that already carry the
face (an edit never tints twice)."
  (when-let* ((bounds (and elneo-room--thread-root
                           (elneo-room--block-bounds
                            elneo-room--thread-root))))
    (elneo-room--tint-thread
     (car bounds) (cdr bounds)
     (when elneo-room-thread-colors
       (elneo-room--thread-tint-face elneo-room--thread-root)))))

(defun elneo-thread--on-new-message (msg)
  "New-message hook (after the room's): feed this room's thread views.
Only a message whose m.thread root names one of this room's open
thread views appends there; the room's own consumer handles the
room buffers (it does not filter)."
  (let* ((thread-root (plist-get msg :thread-root))
         (buffer (and thread-root
                      (elneo-thread--buffer-for (plist-get msg :profile)
                                                (plist-get msg :room-id)
                                                thread-root))))
    (when buffer
      ;; Root echoes route to the room view; only replies narrow here.
      (elneo-room--apply-new-message buffer msg))))

(defun elneo-thread--on-reactions-update (upd)
  "Reactions-update hook: refresh reaction lines inside thread views.
Only a target this thread has rendered is touched; the room's own
consumer handles room buffers, this one never calls it."
  (let* ((profile (plist-get upd :profile))
         (room-id (plist-get upd :room-id))
         (event-id (plist-get upd :event-id))
         (entries (plist-get upd :reactions)))
    (dolist (buffer (elneo-thread--buffers-for profile room-id))
      (with-current-buffer buffer
        (when (and elneo-room--backfilled
                   (hash-table-p elneo-room--reactions)
                   (gethash event-id elneo-room--seen))
          (puthash event-id entries elneo-room--reactions)
          (when-let* ((pos (elneo-room--find-event event-id)))
            (elneo-room--replace-reaction-line pos event-id entries)))))))

(defun elneo-thread--on-edited (upd)
  "Edited-update hook: re-render the edited reply inside thread views."
  (let* ((profile (plist-get upd :profile))
         (room-id (plist-get upd :room-id))
         (event-id (plist-get upd :event-id)))
    (dolist (buffer (elneo-thread--buffers-for profile room-id))
      (with-current-buffer buffer
        (when elneo-room--backfilled
          (let ((msg (gethash event-id elneo-room--seen)))
            (when msg
              (when (hash-table-p elneo-room--edit-history)
                (puthash event-id
                         (cons (cons (or (plist-get msg :edited-ts)
                                         (plist-get msg :ts))
                                     (plist-get msg :body))
                               (gethash event-id elneo-room--edit-history))
                         elneo-room--edit-history))
              (plist-put msg :body (plist-get upd :body))
              (plist-put msg :formatted-body (plist-get upd :formatted-body))
              (plist-put msg :msgtype (plist-get upd :msgtype))
              (plist-put msg :media (plist-get upd :media))
              (plist-put msg :geo (plist-get upd :geo))
              (plist-put msg :edited t)
              (plist-put msg :edited-ts (plist-get upd :edited-ts))
              (elneo-room--replace-message event-id msg)
              (when (equal event-id elneo-room--thread-root)
                (elneo-thread--re-tint-root)))))))))

(defun elneo-thread--on-redaction (upd)
  "Redaction-update hook: mark the deleted reply inside thread views."
  (let* ((profile (plist-get upd :profile))
         (room-id (plist-get upd :room-id))
         (event-id (plist-get upd :event-id)))
    (dolist (buffer (elneo-thread--buffers-for profile room-id))
      (with-current-buffer buffer
        (when elneo-room--backfilled
          (let ((msg (gethash event-id elneo-room--seen)))
            (when msg
              (let ((redacted (list :event-id event-id
                                    :sender (plist-get msg :sender)
                                    :sender-name (plist-get msg :sender-name)
                                    :ts (plist-get msg :ts)
                                    :msgtype "m.text"
                                    :is-own (plist-get msg :is-own)
                                    :reply-to (plist-get msg :reply-to)
                                    :thread-root (plist-get msg :thread-root)
                                    :redacted t
                                    :edited (plist-get msg :edited)
                                    :edited-ts (plist-get msg :edited-ts))))
                (when elneo-room-redaction-history
                  (plist-put redacted :redacted-original
                             (plist-get msg :body)))
                (elneo-room--replace-message event-id redacted)
                (when (equal event-id elneo-room--thread-root)
                  (elneo-thread--re-tint-root))))))))))

(add-hook 'elneo-new-message-hook #'elneo-thread--on-new-message)
(add-hook 'elneo-reactions-update-hook #'elneo-thread--on-reactions-update)
(add-hook 'elneo-edited-update-hook #'elneo-thread--on-edited)
(add-hook 'elneo-redaction-update-hook #'elneo-thread--on-redaction)

(provide 'elneo-thread)
;;; elneo-thread.el ends here
