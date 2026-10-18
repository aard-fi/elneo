;;; pin-room-test.el --- the [pinned] rider, echo diff, settings row -*- lexical-binding: t; -*-

;; The room side of pinning (protocol 22): the record's `:pinned'
;; list rides every updateRoom; the room buffer's buffer-local
;; `elneo-room--pinned' keeps the rendered marks in step — the
;; update-hook diffs old and new, re-laying only the blocks whose
;; membership actually changed, and an equal list re-renders nothing
;; (summary bursts re-announce whole rooms).  The [pinned] rider
;; rides after (edited); the settings view lists one row per pinned
;; id with its [jump] button.
;;
;; Run: emacs -Q --batch -L lisp -l test/pin-room-test.el

(require 'elneo-room)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defun mx-occurrences (text needle)
    "How many times NEEDLE occurs in TEXT."
    (let ((n 0) (pos 0))
      (while (and (setq pos (string-search needle text pos))
                  (cl-incf n)
                  (setq pos (+ pos (length needle)))))
      n))

  (defun mx-pin-setup ()
    (let ((buf (generate-new-buffer " *mx-pin-room*")))
      (with-current-buffer buf
        (elneo-room-mode)
        (setq-local elneo-room--profile "mxtest")
        (setq-local elneo-room--room-id "!room")
        (setq elneo-room--seen (make-hash-table :test 'equal))
        (setq elneo-room--backfilled t)
        (setq-local elneo-room--pinned nil)
        (puthash (cons "mxtest" "!room") buf elneo-room--buffers)
        (insert "header\n")
        (goto-char (point-max))
        (elneo-room--append-messages
         `((:event-id "$one" :sender "@a:hs" :sender-name "Ann"
                      :ts 1700000000000 :msgtype "m.text" :is-own nil
                      :body "first")
           (:event-id "$kept" :sender "@a:hs" :sender-name "Ann"
                      :ts 1700000120000 :msgtype "m.text" :is-own nil
                      :body "pinned once")))
        (elneo-room--reset-input-area ""))
    buf))

  ;; --- the record's :pinned parse ---

  (mx-check "record: pinned_events becomes the :pinned list"
            (plist-get (elneo-client--room-record
                        '((room_id . "!room") (pinned_events . ["$x" "$y"])))
                       :pinned)
            '("$x" "$y"))
  (mx-check "record: no pinned-events state, :pinned is nil"
            (plist-get (elneo-client--room-record '((room_id . "!room")))
                       :pinned)
            nil)

  ;; --- the [pinned] rider ---

  (let ((buf (mx-pin-setup)))
    (with-current-buffer buf
      (mx-check "rider: absent when nothing is pinned"
                (string-search "[pinned]" (buffer-string))
                nil)
      ;; Pin the ALREADY-RENDERED block: the mark arrives with the
      ;; diff-hook, not the rider.
      (elneo-room--on-pinned-update
       (list :profile "mxtest" :room-id "!room" :pinned '("$kept")))
      (mx-check "rider: the hook lays the mark on the block"
                (mx-occurrences (buffer-string) " [pinned]") 1)
      (mx-check "hook: the buffer-local followed"
                elneo-room--pinned '("$kept"))
      ;; The rider consults the live buffer-local, so a later page's
      ;; pinned message arrives marked without another hook round.
      (goto-char (point-max))
      (elneo-room--replace-message "$kept"
                                   (list :event-id "$kept"
                                         :sender "@a:hs"
                                         :sender-name "Ann"
                                         :ts 1700000120000
                                         :msgtype "m.text" :edited t
                                         :is-own nil :body "now edited"))
      (mx-check "rider: (edited) then [pinned] in that order"
                (let ((text (buffer-substring
                             (progn (goto-char (point-min))
                                    (search-forward "now edited")
                                    (match-beginning 0))
                             (line-end-position))))
                  (and (string-search "(edited)" text)
                       (string-search "[pinned]" text)
                       (< (string-search "(edited)" text)
                          (string-search "[pinned]" text))))
                t)
      (kill-buffer)))

  ;; Rider-order on a synthetic render: an own edited, pinned message.
  (with-temp-buffer
    (insert "x")
    (goto-char (point-min))
    (let ((inhibit-read-only t)
          (elneo-room--pinned '("$k")))
      (elneo-room--insert-status-marks
       (list :event-id "$k" :edited t :pending nil :send-failed nil)
       (point-min))
      (mx-check "synthetic rider: (edited) then [pinned]"
                (progn
                  (goto-char (point-min))
                  (search-forward "(edited)")
                  (search-forward " [pinned]")
                  t)
                t)))

  ;; --- the update-hook diff ---

  (let ((buf (mx-pin-setup))
        (re-lays 0)
        (real-replace (symbol-function 'elneo-room--replace-message)))
    (with-current-buffer buf
      (cl-letf (((symbol-function 'elneo-room--replace-message)
                 (lambda (&rest args)
                   (cl-incf re-lays)
                   (apply real-replace args))))
        ;; nil → one id: the pinned block re-lays once.
        (elneo-room--on-pinned-update
         (list :profile "mxtest" :room-id "!room" :pinned '("$kept")))
        (mx-check "hook: an id joining re-lays its block" re-lays 1)
        ;; The same list again — summary bursts re-announce whole
        ;; rooms: no twitching re-renders.
        (let ((was re-lays))
          (elneo-room--on-pinned-update
           (list :profile "mxtest" :room-id "!room" :pinned '("$kept")))
          (mx-check "hook: an equal list re-renders nothing"
                    (- re-lays was) 0))
        ;; The changed end only: $one joins ($kept stays).
        (let ((was re-lays))
          (elneo-room--on-pinned-update
           (list :profile "mxtest" :room-id "!room"
                 :pinned '("$one" "$kept")))
          (mx-check "hook: a member swap re-lays only the changed"
                    (- re-lays was) 1))
        ;; An id with no rendered block: no call.
        (let ((was re-lays))
          (elneo-room--on-pinned-update
           (list :profile "mxtest" :room-id "!room"
                 :pinned '("$one" "$kept" "$unloaded")))
          (mx-check "hook: unloaded ids wait for their page"
                    (- re-lays was) 0)))
      (mx-check "hook: the buffer-local is current"
                (with-current-buffer buf elneo-room--pinned)
                '("$one" "$kept" "$unloaded")))
    (kill-buffer buf))

  ;; A removed room has nothing to re-mark.
  (let ((re-lays 0))
    (cl-letf (((symbol-function 'elneo-room--replace-message)
               (lambda (&rest _) (cl-incf re-lays))))
      (elneo-room--on-pinned-update
       (list :profile "mxtest" :room-id "!room" :removed t
             :pinned '("$kept")))
      (mx-check "hook: a removed room does nothing" re-lays 0)))


  ;; --- the settings view's Pinned section ---
  ;; The section's bodies come from a room buffer that holds the
  ;; message (the real --buffer-for through the registry), so keep a
  ;; live one pinned-up for the whole block.

  (let ((pinbuf (mx-pin-setup))
        (room (list :profile "mxtest" :room-id "!room"
                    :display-name "Test" :alias "#testroom:hs"
                    :room-state "joined" :unread 0 :highlights 0
                    :pinned '("$kept" "$unloaded")))
        text)
    (defun mx-settings-of (room2 &optional anon)
      "Render ROOM2's settings page; ANON sets elneo-anon-mode first."
      (with-temp-buffer
        (when anon (setq-local elneo-anon-mode t))
        (let ((standard-output (current-buffer)))
          (elneo-room-settings--render room2))
        (buffer-string)))
    ;; Loaded messages show their bodies.
    (setq text (mx-settings-of room))
    (mx-check "settings: the section lists the loaded body"
              (and (string-search "Pinned:" text)
                   (string-search "pinned once" text)
                   t)
              t)
    (mx-check "settings: unloaded ids show their bare id"
              (and (string-search "$unloaded" text) t)
              t)
    (mx-check "settings: each row has a [jump] button"
              (mx-occurrences text "[jump]") 2)
    ;; Anonymous screenshots keep the bodies out; the bare ids stay.
    (setq text (mx-settings-of room 'anon))
    (mx-check "settings: anon shows the id for a loaded pin"
              (and (string-search "$kept" text)
                   (not (string-search "pinned once" text)))
              t)
    ;; An unpinned room renders no section at all.  copy-sequence:
    ;; plist-put rewrites cells in place and must not unpick ROOM for
    ;; the later blocks.
    (mx-check "settings: no pinned state, no section"
              (string-search "Pinned:"
                             (mx-settings-of
                                      (plist-put (copy-sequence room)
                                                 :pinned nil)))
              nil)
    ;; The [jump] button jumps with (profile room-id event-id).
    (let (jumped)
      (with-temp-buffer
        (let ((standard-output (current-buffer)))
          (cl-letf (((symbol-function 'elneo-room-jump-to-event)
                     (lambda (p r id)
                       (setq jumped (cons (list p r id) jumped))))
                    ((symbol-function 'elneo-room--buffer-for)
                     (lambda (_p _r) 'no-buffer)))
            (elneo-room-settings--render room)
            ;; fire the first [jump] button in the page
            (goto-char (point-min))
            (search-forward "[jump]")
            (funcall (plist-get (text-properties-at (- (point) 6))
                                'action)
                     nil)))
        (mx-check "settings: [jump] jumps with room + event"
                  jumped '(("mxtest" "!room" "$kept")))))
    (kill-buffer pinbuf))

  (message "%d checks: %d ok, %d FAILED" (+ pass fail) pass fail)
  (when (> fail 0) (kill-emacs 1)))
