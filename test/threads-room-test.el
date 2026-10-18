;;; threads-room-test.el --- thread marks in the room buffer -*- lexical-binding: t; -*-

;; Synthetic room-buffer test for the threads room half: the glyph
;; and tint a thread reply carries, the tint's face-merge (idempotent,
;; read-dim stays outermost), the `elneo-room-thread-root' property,
;; and `elneo-room-open-thread' resolution.  Receipts-test.el style
;; — no daemon, renders directly.
;;
;; Run: emacs -Q --batch -L lisp -l test/threads-room-test.el

(require 'cl-lib)
(require 'elneo-room)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defun mx-faces-at (pos)
    (let ((f (get-text-property pos 'face)))
      (if (listp f) f (list f))))

  (defun mx-erase ()
    (let ((inhibit-read-only t)) (erase-buffer)))

  (defun mx-header ()
    (elneo-room--header (list :display-name "Thread Test Room"
                               :room-id "!r:mxtest.org")))

  (defun mx-glyph-on-line-p ()
    (save-excursion
      (goto-char (line-beginning-position))
      (let ((p (search-forward elneo-room-thread-glyph
                               (line-end-position) t)))
        (when p
          ;; position of the glyph char itself
          (if (memq 'elneo-room-thread (mx-faces-at (1- p))) p p)))))

  (let ((buf (get-buffer-create " *mx-thread-room*")))
    (with-current-buffer buf
      (elneo-room-mode)
      (setq elneo-room--profile "mxtest"
            elneo-room--room-id "!r:mxtest.org"
            elneo-room--seen (make-hash-table :test 'equal)
            elneo-room--receipts (make-hash-table :test 'equal))
      (puthash (cons "mxtest" "!r:mxtest.org") buf elneo-room--buffers)

      ;; --- 'both (the default): glyph + tint + property ---
      (mx-header)
      (let* ((ts0 (* 1000 (time-to-seconds (time-subtract (current-time) 60))))
             (ts1 (+ ts0 1000)))
        (elneo-room--append-messages
         (list (list :event-id "$both-root" :ts ts0 :sender "@alice:mx.org"
                     :is-own nil :msgtype "m.text" :body "thread root here")
               (list :event-id "$both-reply" :ts ts1 :sender "@me:mx.org"
                     :is-own t :msgtype "m.text" :body "reply in thread"
                     :thread-root "$both-root"))))
      (elneo-room--reset-input-area "")

      ;; --- entry conversion ---
      (mx-check "message-from-entry carries thread-root"
                (plist-get (elneo-room--message-from-entry
                            '((event_id . "$r1") (sender . "@b:x")
                              (body . "hi") (ts . 1)
                              (thread_root . "$both-root")))
                           :thread-root)
                "$both-root")
      (mx-check "entry without thread_root yields nil"
                (plist-get (elneo-room--message-from-entry
                            '((event_id . "$r2") (sender . "@b:x")
                              (body . "hi") (ts . 2)))
                           :thread-root)
                nil)

      ;; --- the renders ---
      (goto-char (point-min))
      (search-forward "reply in thread")
      (let* ((reply-bol (line-beginning-position))
            ;; the event-id span runs from the message line's bol: a
            ;; right-aligned own render lays the block on one line
            (reply-id-line reply-bol))
        (mx-check "thread glyph rendered on the reply line"
                  (progn (goto-char reply-bol)
                         (and (search-forward elneo-room-thread-glyph
                                              (line-end-position) t)
                              t))
                  t)
        (mx-check "glyph carries the thread face"
                  (progn (goto-char reply-bol)
                         (let ((p (search-forward elneo-room-thread-glyph
                                                  (line-end-position) t)))
                           (and (memq 'elneo-room-thread (mx-faces-at (1- p)))
                                t)))
                  t)
        (mx-check "tint covers the reply body"
                  (and (memq 'elneo-room-thread (mx-faces-at (1- (point))))
                       t)
                  t)
        (mx-check "thread-root property on the id line"
                  (get-text-property reply-id-line 'elneo-room-thread-root)
                  "$both-root")
        (mx-check "thread-root property rides the event-id span"
                  (get-text-property reply-id-line 'elneo-room-event-id)
                  "$both-reply")
        ;; the root itself: no glyph, no tint
        (goto-char (point-min))
        (search-forward "thread root here")
        (goto-char (line-beginning-position))
        (mx-check "root message carries no thread glyph"
                  (and (search-forward elneo-room-thread-glyph
                                       (line-end-position) t)
                       t)
                  nil)
        (mx-check "root body untinted"
                  (and (memq 'elneo-room-thread (mx-faces-at (1- (point))))
                       t)
                  nil))

      ;; --- tint helper: idempotent ---
      (goto-char (point-min))
      (search-forward "reply in thread")
      (mx-check "tint idempotent"
                (progn (elneo-room--tint-thread (point-min) (point-max))
                       (let ((f (mx-faces-at (1- (point)))))
                         (cl-count 'elneo-room-thread f)))
                1)

      ;; --- per-thread colors: one stable hue per thread ---
      (cl-letf (((symbol-function 'face-background)
                 (lambda (&rest _) "#202020")))
        (mx-check "same root keeps one glyph hue"
                  (and (equal (elneo-room--thread-face "$root-a")
                              (elneo-room--thread-face "$root-a"))
                       (eq (elneo-room--thread-face "$root-a")
                           (nth (elneo-room--thread-slot "$root-a")
                                elneo-room--thread-glyph-faces))
                       t)
                  t)
        ;; two roots mapping to different slots
        (let* ((slot-a (elneo-room--thread-slot "$root-a"))
               (other (cl-loop for i from 0
                               when (/= (elneo-room--thread-slot
                                         (format "$root-walk-%d" i))
                                        slot-a)
                               return (format "$root-walk-%d" i))))
          (mx-check "different roots carry different glyph hues"
                    (not (eq (elneo-room--thread-face "$root-a")
                             (elneo-room--thread-face other)))
                    t)
          (mx-check "tint faces split the same way"
                    (not (eq (elneo-room--thread-tint-face "$root-a")
                             (elneo-room--thread-tint-face other)))
                    t)
          ;; the tint face colors the block: the colored hue face lands
          ;; on a rendered reply and idempotence holds under the hue
          (let ((elneo-room-thread-marks 'tint)
                (tf (elneo-room--thread-tint-face other)))
            (mx-erase)
            (mx-header)
            (let ((ts0 (* 1000 (time-to-seconds
                                (time-subtract (current-time) 60)))))
              (elneo-room--append-messages
               (list (list :event-id "$hue-r" :ts ts0 :sender "@x:y"
                           :msgtype "m.text" :body "hued reply"
                           :thread-root other))))
            (elneo-room--reset-input-area "")
            (goto-char (point-min))
            (search-forward "hued reply")
            (mx-check "rendered tint carries the thread's hue face"
                      (and (memq tf (mx-faces-at (1- (point)))) t)
                      t)
            (mx-check "tinted-again stays idempotent under the hue"
                      (progn (elneo-room--tint-thread
                              (point-min) (point-max)
                              (elneo-room--thread-tint-face other))
                             (let ((f (mx-faces-at (1- (point)))))
                               (list (cl-count tf f)
                                     (cl-count 'elneo-room-thread f))))
                      (list 1 1))))
        (let ((elneo-room-thread-colors nil))
          (mx-check "colors off: glyph face is the plain thread face"
                    (elneo-room--thread-face "$root-a")
                    'elneo-room-thread)
          (mx-check "colors off: tint face is nil"
                    (elneo-room--thread-tint-face "$root-a")
                    nil))
        ;; re-derive for the next section's default-colors renders
        (setq elneo-room--thread-face-bg nil
              elneo-room--thread-glyph-faces nil
              elneo-room--thread-tint-faces nil))
      (mx-check "after the colors section the buffer is still live"
                (and (buffer-live-p buf)
                     (hash-table-p elneo-room--seen)
                     t)
                t)

      ;; --- settings: tint-only and none ---
      (let ((elneo-room-thread-marks 'tint))
        (mx-erase)
        (mx-header)
        (let ((ts0 (* 1000 (time-to-seconds (time-subtract (current-time) 60)))))
          (elneo-room--append-messages
           (list (list :event-id "$r3" :ts ts0 :sender "@x:y"
                       :msgtype "m.text" :body "tinted only"
                       :thread-root "$root-elsewhere"))))
        (elneo-room--reset-input-area "")
        (goto-char (point-min))
        (search-forward "tinted only")
        (goto-char (line-beginning-position))
        (mx-check "tint setting: no glyph"
                  (and (search-forward elneo-room-thread-glyph
                                       (line-end-position) t)
                       t)
                  nil)
        (goto-char (point-min))
        (search-forward "tinted only")
        (mx-check "tint setting: body tinted"
                  (and (memq 'elneo-room-thread (mx-faces-at (1- (point))))
                       t)
                  t))
      (let ((elneo-room-thread-marks 'none))
        (mx-erase)
        (mx-header)
        (let ((ts0 (* 1000 (time-to-seconds (time-subtract (current-time) 60)))))
          (elneo-room--append-messages
           (list (list :event-id "$r4" :ts ts0 :sender "@x:y"
                       :msgtype "m.text" :body "quiet reply"
                       :thread-root "$root-elsewhere"))))
        (elneo-room--reset-input-area "")
        (goto-char (point-min))
        (search-forward "quiet reply")
        (goto-char (line-beginning-position))
        (mx-check "none setting: no glyph"
                  (and (search-forward elneo-room-thread-glyph
                                       (line-end-position) t)
                       t)
                  nil)
        (goto-char (point-min))
        (search-forward "quiet reply")
        (mx-check "none setting: no tint"
                  (memq 'elneo-room-thread (mx-faces-at (1- (point)))) nil))

      ;; --- open-thread resolution ---
      ;; Stub the not-yet-existing thread buffer entry point; the lazy
      ;; require is stubbed too since elneo-thread.el lands next commit.
      (let ((calls nil)
            (elneo-room-thread-marks 'both))
        (mx-erase)
        (mx-header)
        (let ((ts0 (* 1000 (time-to-seconds (time-subtract (current-time) 60)))))
          (elneo-room--append-messages
           (list (list :event-id "$otr" :ts ts0 :sender "@a:x"
                       :msgtype "m.text" :body "the root")
                 (list :event-id "$orep" :ts (1+ ts0) :sender "@a:x"
                       :msgtype "m.text" :body "a thread reply"
                       :thread-root "$otr"))))
        (elneo-room--reset-input-area "")
        (cl-letf (((symbol-function 'elneo-thread-open)
                   (lambda (_profile _room root _msg)
                     (setq calls root)))
                  ((symbol-function 'require)
                   (lambda (_feature &optional _f _ne) nil)))
          ;; on the reply: the carried root
          (goto-char (point-min))
          (search-forward "a thread reply")
          (goto-char (line-beginning-position))
          (elneo-room-open-thread)
          (mx-check "open-thread on a reply resolves the carried root"
                    calls "$otr")
          ;; on the root: the message's own id
          (goto-char (point-min))
          (search-forward "the root")
          (goto-char (line-beginning-position))
          (elneo-room-open-thread)
          (mx-check "open-thread on a root resolves its own id"
                    calls "$otr")
          ;; no message at point (the draft area: no event id)
          (goto-char (elneo-room--input-beg-pos))
          (setq calls :unset)
          (mx-check "open-thread off any message user-errors"
                    (condition-case e (progn (elneo-room-open-thread) nil)
                      (user-error (cadr e)))
                    "No message at point")
          (mx-check "user-error did not reach elneo-thread-open"
                    calls :unset)
          ;; a ⏱/✗ send is not threadable (round 3.1): same gate as
          ;; r/a/e/d — the daemon would reject the synthetic id
          (mx-erase)
          (mx-header)
          (elneo-room--append-messages
           (list (list :event-id "$pen"
                       :ts (* 1000 (time-to-seconds
                                    (time-subtract (current-time) 60)))
                       :sender "@a:x"
                       :msgtype "m.text" :body "the failed send"
                       :send-failed t)))
          (goto-char (point-min))
          (search-forward "the failed send")
          (goto-char (line-beginning-position))
          (mx-check "t on a failed send user-errors"
                    (condition-case e (progn (elneo-room-open-thread) nil)
                      (user-error (cadr e)))
                    "Cannot open a thread on a message that is not on the server yet")
          (mx-check "the ✗ gate did not reach elneo-thread-open"
                    calls :unset)))

      ;; --- replying to a threaded message sorts into the thread ---
      ;; In the room view (no --thread-root), a reply to a message
      ;; that BELONGS to a thread goes into that thread: the send
      ;; resolves the target's relation from the seen table.  The
      ;; provisional echo renders as the thread reply it will be.
      (let (captured)
        (mx-erase)
        (mx-header)
        (let ((ts0 (* 1000 (time-to-seconds (time-subtract (current-time) 60)))))
          (elneo-room--append-messages
           (list (list :event-id "$troot" :ts ts0 :sender "@a:mx.org"
                       :msgtype "m.text" :body "the thread root")
                 (list :event-id "$trep" :ts (1+ ts0) :sender "@b:mx.org"
                       :msgtype "m.text" :body "a threaded reply"
                       :thread-root "$troot"))))
        (setq elneo-room--backfilled t)
        (elneo-room--reset-input-area "")
        (goto-char (point-min))
        (search-forward "a threaded reply")
        (goto-char (line-beginning-position))
        (call-interactively #'elneo-room--r)
        (cl-letf (((symbol-function 'elneo-send-message)
                   (lambda (_p _r body _cb _f reply-to edit-to
                           _ids _mention thread-root)
                     (setq captured (list body reply-to edit-to
                                          thread-root))
                     42))
                  ((symbol-function 'elneo-room--send-mentions)
                   (lambda (_b) (list :ids nil :room nil)))
                  ((symbol-function 'elneo-room--rich-send-p)
                   (lambda (&optional _room) nil)))
          (elneo-room--send-text "into the thread"))
        (mx-check "room-view reply to a threaded msg carries the root"
                  captured
                  (list "into the thread" "$trep" nil "$troot"))
        (mx-check "reply mode is consumed after the threaded send"
                  (and (null elneo-room--reply-to) t) t)
        (let ((pending (catch 'id
                         (maphash
                          (lambda (id _m)
                            (when (elneo-room--provisional-p id)
                              (throw 'id id)))
                          elneo-room--seen))))
          (mx-check "the echo renders as a thread reply"
                    (and pending
                         (equal (plist-get (gethash pending
                                                    elneo-room--seen)
                                           :thread-root)
                                "$troot")
                         t)
                    t)
          (mx-check "the reply target rides the provisional block"
                    (plist-get (gethash pending elneo-room--seen)
                               :reply-to)
                    "$trep"))
        ;; A reply to an unthreaded message stays an ordinary reply.
        (goto-char (point-min))
        (search-forward "the thread root")
        (goto-char (line-beginning-position))
        (call-interactively #'elneo-room--r)
        (setq captured :unset)
        (cl-letf (((symbol-function 'elneo-send-message)
                   (lambda (_p _r body _cb _f reply-to edit-to
                           _ids _mention thread-root)
                     (setq captured (list body reply-to edit-to
                                          thread-root))
                     42))
                  ((symbol-function 'elneo-room--send-mentions)
                   (lambda (_b) (list :ids nil :room nil)))
                  ((symbol-function 'elneo-room--rich-send-p)
                   (lambda (&optional _room) nil)))
          (elneo-room--send-text "plain channel reply"))
        (mx-check "reply to the root itself stays in the channel"
                  captured
                  (list "plain channel reply" "$troot" nil nil))
        ;; the separator names the thread while reply mode targets one
        (mx-erase)
        (mx-header)
        (setq elneo-room--reply-to "$trep" elneo-room--reply-sender "B")
        (mx-check "the separator marks an in-thread reply"
                  (and (string-search "(in thread)"
                                      (elneo-room--separator-text))
                       t)
                  t)
        (setq elneo-room--reply-to nil elneo-room--reply-sender nil))

      ;; --- read-dim stays outermost over the tint ---
      ;; A seen thread reply advances the room's read marker exactly
      ;; like any other message: pin today's behavior.
      (let ((elneo-room-read-marks 'dim))
        (mx-erase)
        (mx-header)
        (let ((ts0 (* 1000 (time-to-seconds (time-subtract (current-time) 60)))))
          (elneo-room--append-messages
           (list (list :event-id "$rr" :ts ts0 :sender "@me:mx.org"
                       :is-own t :msgtype "m.text" :body "own thread reply"
                       :thread-root "$root-elsewhere")))
          (elneo-room--reset-input-area "")
          (setq elneo-room--backfilled t)
          (mx-check "thread reply is the room's last-event-id"
                    elneo-room--last-event-id "$rr")
          (elneo-room--on-read-receipts
           (list :profile "mxtest" :room-id "!r:mxtest.org"
                 :receipts
                 (list (list :user-id "@a:mx.org" :user-name "A"
                             :event-id "$rr" :ts (1+ ts0) :target-ts ts0))))
          (elneo-room--apply-read-marks)
          (goto-char (point-min))
          (search-forward "own thread reply")
          (let ((faces (mx-faces-at (1- (point)))))
            (mx-check "tinted block shows both faces when read"
                      (and (memq 'elneo-room-thread faces)
                           (memq 'elneo-room-read faces)
                           t)
                      t)
            ;; --dim-faces appends its face last, so the read-dim
            ;; wins; the tint must have been merged before it ran.
            (mx-check "read-dim remains outermost (appended last)"
                      (and (> (or (cl-position 'elneo-room-read faces)
                                  99)
                              (or (cl-position 'elneo-room-thread faces)
                                  -1))
                           t)
                      t))))

      ;; --- the t key opens a thread, y toggles rich bodies ---
      ;; The defkey macro generates history-entry commands: the keymap
      ;; binds t / y to them, and they self-insert over the draft.
      (mx-check "t is bound (via elneo-room--t) to open a thread"
                (key-binding "t" t) #'elneo-room--t)
      (mx-check "y is bound (via elneo-room--y) to toggle-rich"
                (key-binding "y" t) #'elneo-room--y)))

  (message "results: %d passed, %d failed" pass fail)
  (when (> fail 0) (kill-emacs 1)))