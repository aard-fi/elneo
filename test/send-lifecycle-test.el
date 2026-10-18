;;; send-lifecycle-test.el --- local echo, ack swap, retry/remove -*- lexical-binding: t; -*-

;; The send lifecycle: RET inserts a provisional block (⏱) keyed by
;; the send request, the updateSendResult ack re-keys it to the
;; server's event id (the later sync echo then no-ops), a failure
;; flips it to ✗ with R (retry) and K (remove), and a failed edit
;; puts its text back into the draft with the edit marker restored.
;; The daemon is stubbed at `elneo-send-message'; the ack arrives
;; by invoking the captured callback with a synthetic response.
;;
;; Run: emacs -Q --batch -L lisp -l test/send-lifecycle-test.el

(require 'elneo-room)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defvar mx-req 0)
  (defvar mx-sent nil)
  (defun mx-send-stub (_profile _room body callback &rest args)
    "Stub `elneo-send-message': record the call, return a fresh req."
    (push (list body callback
                (nth 0 args) (nth 1 args) (nth 2 args) (nth 3 args)
                (nth 4 args) (nth 5 args))
          mx-sent)
    (cl-incf mx-req)
    mx-req)
  (defun mx-ack (entry event)
    "Invoke the recorded send ENTRY's callback with EVENT."
    (funcall (cadr entry) "mxtest" event))

  (defun mx-send-setup ()
    "A backfilled room buffer registered for on-new-message.
Messages render through the real append path; the draft area and
its markers exist as after a first-page render."
    (let ((buf (generate-new-buffer " *mx-send-room*")))
      (with-current-buffer buf
        (elneo-room-mode)
        (let ((elneo-room-avatars nil)
              (elneo-accounts '(("mxtest" :user-id "@me:hs"))))
          (setq-local elneo-room--profile "mxtest")
          (setq-local elneo-room--room-id "!room")
          (setq elneo-room--seen (make-hash-table :test 'equal))
          (setq elneo-room--backfilled t)
          (insert "header\n")
          (goto-char (point-max))
          ;; copy-tree: the backquote is one shared structure; tests
          ;; mutate their messages, which must not leak into later
          ;; setups.
          (elneo-room--append-messages
           (copy-tree
            `((:event-id "$other" :sender "@a:hs" :sender-name "Ann" :ts 1700000000000
               :msgtype "m.text" :is-own nil :body "hi there")
              (:event-id "$mine" :sender "@me:hs" :sender-name "Me" :ts 1700000060000
               :msgtype "m.text" :is-own t :body "my own old message"))))
          (elneo-room--reset-input-area "")
          (puthash (cons "mxtest" "!room") buf elneo-room--buffers)))
      buf))

  (defun mx-find-line (text)
    "Point at the start of the line containing TEXT."
    (goto-char (point-min))
    (and (search-forward text nil t)
         (goto-char (line-beginning-position))
         (point)))

  (defun mx-occurrences (text)
    "Number of lines containing TEXT in the buffer."
    (goto-char (point-min))
    (let ((n 0))
      (while (search-forward text nil t)
        (cl-incf n))
      n))

  (defvar mx-accounts '(("mxtest" :user-id "@me:hs")))

  ;; Id helpers
  (mx-check "pending id: format" (elneo-room--pending-id 7)
            "$~pending-7")
  (mx-check "pending id: recognized"
            (and (elneo-room--provisional-p "$~pending-7") t) t)
  (mx-check "pending id: real ids are not provisional"
            (elneo-room--provisional-p "$real:abc") nil)

  ;; Send → provisional block; the draft area is untouched
  (let ((buf (mx-send-setup)))
    (unwind-protect
        (with-current-buffer buf
          (setq mx-req 0 mx-sent nil)
          (let ((elneo-accounts mx-accounts))
            (cl-letf (((symbol-function 'elneo-send-message) #'mx-send-stub))
              (elneo-room--send-text "hello world")
              (mx-check "send: one send issued" (length mx-sent) 1)
              (mx-check "send: provisional rendered"
                        (and (mx-find-line "hello world ⏱") t) t)
              (mx-check "send: pending face on the marker"
                        (progn (mx-find-line "hello world ⏱")
                               (search-forward "⏱" (line-end-position))
                               (get-text-property (1- (point)) 'face))
                        'elneo-room-pending)
              (mx-check "send: own message"
                        (plist-get (gethash "$~pending-1" elneo-room--seen) :is-own)
                        t)
              (mx-check "send: own user id from the account"
                        (plist-get (gethash "$~pending-1" elneo-room--seen) :sender)
                        "@me:hs")
              (mx-check "send: own name from the last own message"
                        (plist-get (gethash "$~pending-1" elneo-room--seen) :sender-name)
                        "Me")
              (mx-check "send: last-event-id stays a real event"
                        elneo-room--last-event-id "$mine")
              ;; The ack re-keys the block to the server's event id.
              (mx-ack (car mx-sent)
                      '((@req . 1) (@ok . t) (event_id . "$real:1")))
              (mx-check "ack: block re-keyed in the seen table"
                        (plist-get (gethash "$real:1" elneo-room--seen) :body)
                        "hello world")
              (mx-check "ack: pending entry gone"
                        (gethash "$~pending-1" elneo-room--seen) nil)
              (mx-check "ack: ⏱ gone"
                        (mx-occurrences "⏱") 0)
              (mx-check "ack: buffer keyed by the real id"
                        (get-text-property (mx-find-line "hello world")
                                           'elneo-room-event-id)
                        "$real:1")
              (mx-check "ack: last-event-id now the real id"
                        elneo-room--last-event-id "$real:1")
              ;; The sync echo no-ops against the re-keyed entry.
              (elneo-room--on-new-message
               '(:profile "mxtest" :room-id "!room" :event-id "$real:1"
                 :sender "@me:hs" :sender-name "Me" :ts 1700000100000
                 :msgtype "m.text" :is-own t :body "hello world"))
              (mx-check "echo after ack: no duplicate"
                        (mx-occurrences "hello world") 1))))
      (kill-buffer buf)))

  ;; The late echo fills in what the provisional block could not
  ;; know — the sender's avatar mxc (which kicks the deduped fetch)
  ;; and the trust snapshot — and re-renders the block in place.
  ;; Without this, own messages keep the avatar-less block the ack's
  ;; re-key preserved.
  (let ((buf (mx-send-setup)) (fetches 0))
    (unwind-protect
        (with-current-buffer buf
          (setq mx-req 0 mx-sent nil)
          (setq-local elneo-room-avatars t)
          (setq-local elneo-room-trust-marks t)
          ;; Fresh caches: this test's fetches and dedup state must
          ;; not see other suites' (or real) avatar entries.
          (let ((elneo-accounts mx-accounts)
                (elneo-client--avatar-cache (make-hash-table :test 'equal))
                (elneo-client--avatar-pending (make-hash-table :test 'equal)))
            (cl-letf (((symbol-function 'elneo-send-message) #'mx-send-stub)
                      ((symbol-function 'elneo-client-fetch-avatar)
                       (lambda (_p _mxc _cb) (cl-incf fetches))))
              (elneo-room--send-text "avatar me")
              (mx-check "fill: provisional without a fetch target"
                        (progn (goto-char (mx-find-line "avatar me ⏱"))
                               (catch 'src
                                 (while (not (eolp))
                                   (when (get-text-property
                                          (point) 'elneo-room-avatar-src)
                                     (throw 'src :found))
                                   (forward-char 1))
                                 nil))
                        nil)
              (mx-ack (car mx-sent)
                      '((@req . 1) (@ok . t) (event_id . "$real:av")))
              ;; The daemon echo resolves what the local side could
              ;; not: mxc and trust.  Its body differs from the one we
              ;; stored — only the fill keys may change anything.
              (elneo-room--on-new-message
               '(:profile "mxtest" :room-id "!room" :event-id "$real:av"
                 :sender "@me:hs" :sender-name "Me" :ts 1700000200000
                 :msgtype "m.text" :is-own t :body "avatar me SERVER"
                 :sender-avatar "mxc://hs/me" :sender-trust "verified"))
              (mx-check "fill: still one copy of the message"
                        (mx-occurrences "avatar me") 1)
              (mx-check "fill: echo body NOT taken over"
                        (mx-occurrences "avatar me SERVER") 0)
              (mx-check "fill: mxc and trust in the seen entry"
                        (list (plist-get (gethash "$real:av" elneo-room--seen)
                                         :sender-avatar)
                              (plist-get (gethash "$real:av" elneo-room--seen)
                                         :sender-trust))
                        '("mxc://hs/me" "verified"))
              (mx-check "fill: echo ts NOT taken over"
                        (equal (plist-get (gethash "$real:av" elneo-room--seen)
                                          :ts)
                               1700000200000)
                        nil)
              ;; The re-render: the placeholder now carries the mxc and
              ;; one (deduped) fetch went out.
              (mx-check "fill: fetch kicked exactly once" fetches 1)
              (mx-check "fill: placeholder carries the mxc"
                        (progn (goto-char (mx-find-line "avatar me"))
                               (catch 'src
                                 (while (not (eolp))
                                   (let ((src (get-text-property
                                               (point) 'elneo-room-avatar-src)))
                                     (when src
                                       (throw 'src (list src (and (get-text-property
                                                                   (point) 'face) t))))
                                     (forward-char 1)))
                                 nil))
                        '("mxc://hs/me" t))
              (mx-check "fill: trust glyph on the re-rendered line"
                        (and (mx-find-line "avatar me ✓") t)
                        t)
              ;; A second identical echo: nothing left to fill, the
              ;; fetch is deduped by the pending table.
              (elneo-room--on-new-message
               '(:profile "mxtest" :room-id "!room" :event-id "$real:av"
                 :sender "@me:hs" :sender-name "Me" :ts 1700000200000
                 :msgtype "m.text" :is-own t :body "avatar me SERVER"
                 :sender-avatar "mxc://hs/me" :sender-trust "verified"))
              (mx-check "fill: second echo no-ops" fetches 1)
              (mx-check "fill: second echo no duplicate"
                        (mx-occurrences "avatar me") 1)
              ;; An echo without the fill keys on an event that wants
              ;; them changes nothing.
              (puthash "$real:av"
                       (list :body "avatar me" :ts 1700000190000)
                       elneo-room--seen)
              (mx-check "fill: nothing to fill returns nil"
                        (elneo-room--fill-echo-fields
                         "$real:av" (gethash "$real:av" elneo-room--seen)
                         '(:body "avatar me SERVER" :ts 1700000200000))
                        nil)))
        (kill-buffer buf))))

  ;; Echo-before-ack: the sync echo renders the real message, the ack
  ;; then drops the provisional duplicate.
  (let ((buf (mx-send-setup)))
    (unwind-protect
        (with-current-buffer buf
          (setq mx-req 0 mx-sent nil)
          (let ((elneo-accounts mx-accounts))
            (cl-letf (((symbol-function 'elneo-send-message) #'mx-send-stub))
              (elneo-room--send-text "race test")
              (elneo-room--on-new-message
               '(:profile "mxtest" :room-id "!room" :event-id "$real:2"
                 :sender "@me:hs" :sender-name "Me" :ts 1700000120000
                 :msgtype "m.text" :is-own t :body "race test"))
              (mx-check "race: duplicate while pending"
                        (mx-occurrences "race test") 2)
              (mx-ack (car mx-sent)
                      '((@req . 1) (@ok . t) (event_id . "$real:2")))
              (mx-check "race: provisional dropped, one copy left"
                        (mx-occurrences "race test") 1)
              (mx-check "race: seen keyed by the real id"
                        (and (gethash "$real:2" elneo-room--seen) t)
                        t)
              (mx-check "race: provisional gone from seen"
                        (gethash "$~pending-1" elneo-room--seen)
                        nil))))
      (kill-buffer buf)))

  ;; Failure → ✗ with the keys on it; R retries; K removes
  (let ((buf (mx-send-setup)))
    (unwind-protect
        (with-current-buffer buf
          (setq mx-req 0 mx-sent nil)
          (let ((elneo-accounts mx-accounts))
            (cl-letf (((symbol-function 'elneo-send-message) #'mx-send-stub))
              (elneo-room--send-text "doomed")
              (mx-ack (car mx-sent)
                      '((@req . 1) (@ok . nil) (error . "daemon broke")))
              (mx-check "failure: ✗ marker with keys"
                        (and (mx-find-line "doomed ✗ (R retry · K remove)") t)
                        t)
              (mx-check "failure: send-failed face"
                        (progn (mx-find-line "doomed ✗ (R retry · K remove)")
                               (search-forward "✗" (line-end-position))
                               (get-text-property (1- (point)) 'face))
                        'elneo-room-send-failed)
              (mx-check "failure: state in seen"
                        (plist-get (gethash "$~pending-1" elneo-room--seen)
                                   :send-failed)
                        t)
              ;; Retry: fresh send, block back to ⏱ under a new id.
              (goto-char (mx-find-line "doomed ✗"))
              (elneo-room--R)
              (mx-check "retry: fresh send issued" (length mx-sent) 2)
              (mx-check "retry: body re-sent"
                        (car (car mx-sent)) "doomed")
              (mx-check "retry: block is pending again"
                        (plist-get (gethash "$~pending-2" elneo-room--seen)
                                   :pending)
                        t)
              (mx-check "retry: old pending id gone"
                        (gethash "$~pending-1" elneo-room--seen)
                        nil)
              (mx-check "retry: ⏱ back on the line"
                        (and (mx-find-line "doomed ⏱") t)
                        t)
              ;; Ack the retry, fail it again, then remove with K.
              (mx-ack (car mx-sent)
                      '((@req . 2) (@ok . nil) (error . "still broken")))
              (goto-char (mx-find-line "doomed ✗"))
              (elneo-room--K)
              (mx-check "remove: block gone"
                        (mx-occurrences "doomed") 0)
              (mx-check "remove: seen entry gone"
                        (gethash "$~pending-2" elneo-room--seen)
                        nil)
              (mx-check "remove: earlier messages intact"
                        (and (save-excursion (mx-find-line "hi there")) t)
                        t)
              ;; K refuses anything not pending or failed.
              (goto-char (mx-find-line "hi there"))
              (mx-check "remove: refuses sent messages"
                        (condition-case e
                            (progn (elneo-room--K) 'no-error)
                          (user-error e))
                        '(user-error "Only unsent local messages can be discarded — K needs ⏱ or ✗")))))
      (kill-buffer buf)))

  ;; Replies: the provisional renders the quote; the reply context
  ;; clears on send and rides the retry.
  (let ((buf (mx-send-setup)))
    (unwind-protect
        (with-current-buffer buf
          (setq mx-req 0 mx-sent nil)
          (let ((elneo-accounts mx-accounts))
            (cl-letf (((symbol-function 'elneo-send-message) #'mx-send-stub))
              (setq elneo-room--reply-to "$other"
                    elneo-room--reply-sender "Ann")
              (elneo-room--update-separator)
              (elneo-room--send-text "a reply")
              (mx-check "reply: context consumed"
                        (and elneo-room--reply-to elneo-room--reply-sender)
                        nil)
              (mx-check "reply: relation on the wire"
                        (cadddr (car mx-sent))
                        "$other")
              (mx-check "reply: provisional renders the quote"
                        (and (mx-find-line "↳") t)
                        t)
              (mx-check "reply: relation kept on the block"
                        (plist-get (gethash "$~pending-1" elneo-room--seen)
                                   :reply-to)
                        "$other")
              (mx-ack (car mx-sent)
                      '((@req . 1) (@ok . nil) (error . "nope")))
              (goto-char (mx-find-line "a reply ✗"))
              (elneo-room--R)
              (mx-check "retry: reply relation re-sent"
                        (cadddr (car mx-sent))
                        "$other"))))
      (kill-buffer buf)))

  ;; A failed THREAD reply retries with its thread relation intact —
  ;; and, like every retry, fills the slots it does not use with nil
  ;; (the old call site shifted args, landing (:ids) in `replaces').
  (let ((buf (mx-send-setup)))
    (unwind-protect
        (with-current-buffer buf
          (setq mx-req 0 mx-sent nil)
          (let ((elneo-accounts mx-accounts)
                ;; thread-view local: every send is a thread reply
                (elneo-room--thread-root "$troot"))
            (cl-letf (((symbol-function 'elneo-send-message) #'mx-send-stub))
              (elneo-room--send-text "thread retry")
              (mx-check "thread send: relation on the wire"
                        (nth 6 (cdr (car mx-sent)))
                        "$troot")
              (mx-ack (car mx-sent)
                      '((@req . 1) (@ok . nil) (error . "broken")))
              (goto-char (mx-find-line "thread retry ✗"))
              (elneo-room--R)
              (let ((entry (car mx-sent)))
                (mx-check "retry: thread relation re-sent"
                          (nth 6 (cdr entry))
                          "$troot")
                (mx-check "retry: replaces stays nil"
                          (nth 4 (cdr entry))
                          nil))
              (mx-check "retry: ⏱ back on the failed block"
                        (and (mx-find-line "thread retry ⏱") t)
                        t))))
      (kill-buffer buf)))

  ;; Failed edit: no provisional block; text and edit marker back
  (let ((buf (mx-send-setup)))
    (unwind-protect
        (with-current-buffer buf
          (setq mx-req 0 mx-sent nil)
          (let ((elneo-accounts mx-accounts))
            (cl-letf (((symbol-function 'elneo-send-message) #'mx-send-stub))
              (setq elneo-room--edit-to "$mine")
              (elneo-room--update-separator)
              (elneo-room--send-text "revised body")
              (mx-check "edit: no provisional block"
                        (mx-occurrences "⏱") 0)
              (mx-check "edit: consumed the marker"
                        elneo-room--edit-to nil)
              (mx-check "edit: replaces on the wire"
                        (car (cddddr (car mx-sent)))
                        "$mine")
              (mx-ack (car mx-sent)
                      '((@req . 1) (@ok . nil) (error . "nope")))
              (mx-check "edit failure: body back in the draft"
                        (elneo-room--draft-text)
                        "revised body")
              (mx-check "edit failure: marker restored"
                        elneo-room--edit-to "$mine")
              (mx-check "edit failure: separator says editing"
                        (and (string-match-p
                              "editing"
                              (elneo-room--separator-text))
                             t)
                        t)
              ;; An acked edit renders nothing: the updateEdited echo
              ;; re-renders the target; the ack itself must not.
              (mx-ack (car mx-sent)
                      '((@req . 1) (@ok . t) (event_id . "$edit:9")))
              (mx-check "edit ack: original block untouched"
                        (and (save-excursion (mx-find-line "my own old message")) t)
                        t))))
      (kill-buffer buf)))

  ;; Guards: provisional blocks refuse reply, edit, redact
  (let ((buf (mx-send-setup)))
    (unwind-protect
        (with-current-buffer buf
          (setq mx-req 0 mx-sent nil)
          (let ((elneo-accounts mx-accounts))
            (cl-letf (((symbol-function 'elneo-send-message) #'mx-send-stub))
              (elneo-room--send-text "guard me")
              (goto-char (mx-find-line "guard me ⏱"))
              (mx-check "guards: e refuses a pending message"
                        (condition-case e
                            (progn (elneo-room--e) 'no-error)
                          (user-error e))
                        '(user-error "Still being sent — wait for the send to finish"))
              (mx-check "guards: r refuses a pending message"
                        (condition-case e
                            (progn (elneo-room--r) 'no-error)
                          (user-error e))
                        '(user-error "Cannot reply to a message that is not on the server yet"))
              (mx-check "guards: a refuses a pending message"
                        (condition-case e
                            (progn (elneo-room--a) 'no-error)
                          (user-error e))
                        '(user-error "Cannot react to a message that is not on the server yet"))
              (mx-check "guards: d refuses a pending message"
                        (condition-case e
                            (progn (elneo-room--d) 'no-error)
                          (user-error e))
                        '(user-error "Still being sent — wait for the send to finish"))
              (mx-ack (car mx-sent)
                      '((@req . 1) (@ok . nil) (error . "nope")))
              (goto-char (mx-find-line "guard me ✗"))
              (mx-check "guards: e refuses a failed message"
                        (condition-case e
                            (progn (elneo-room--e) 'no-error)
                          (user-error e))
                        '(user-error "Send failed — R retries it, K removes it"))
              (mx-check "guards: d refuses a failed message"
                        (condition-case e
                            (progn (elneo-room--d) 'no-error)
                          (user-error e))
                        '(user-error "It never reached the server — K removes it")))))
      (kill-buffer buf)))

  ;; K on a pending block (cancel before the ack): the send still
  ;; completes server-side and the sync echo renders the real message.
  (let ((buf (mx-send-setup)))
    (unwind-protect
        (with-current-buffer buf
          (setq mx-req 0 mx-sent nil)
          (let ((elneo-accounts mx-accounts))
            (cl-letf (((symbol-function 'elneo-send-message) #'mx-send-stub))
              (elneo-room--send-text "changed my mind")
              (goto-char (mx-find-line "changed my mind ⏱"))
              (elneo-room--K)
              (mx-check "cancel: block removed"
                        (mx-occurrences "changed my mind") 0)
              (elneo-room--on-new-message
               '(:profile "mxtest" :room-id "!room" :event-id "$real:3"
                 :sender "@me:hs" :sender-name "Me" :ts 1700000180000
                 :msgtype "m.text" :is-own t :body "changed my mind"))
              (mx-check "cancel: echo renders the real message"
                        (and (mx-find-line "changed my mind") t)
                        t))))
      (kill-buffer buf)))

  ;; Empty-draft placeholder: the hint is an overlay before-string at
  ;; point-max, so its `cursor' property has to keep the caret at the
  ;; hint's START rather than behind its text — and the overlay goes
  ;; away the moment real draft text exists.
  (let ((buf (mx-send-setup)))
    (unwind-protect
        (with-current-buffer buf
          (mx-check "placeholder: hint carries the cursor property"
                    (get-text-property
                     0 'cursor
                     (overlay-get elneo-room--draft-placeholder 'before-string))
                    t)
          (goto-char (point-max))
          (insert "x")
          (elneo-room--update-draft-placeholder)
          (mx-check "placeholder: gone when the draft is non-empty"
                    ;; Deleted overlays keep `overlayp' t — detached
                    ;; is what matters, i.e. no buffer back.
                    (overlay-buffer elneo-room--draft-placeholder)
                    nil)
          ;; Typing: the first character in the draft must not inherit
          ;; the separator's face — it inherits `mode-line' (grey
          ;; background), and each later character inherits from it.
          ;; So the separator drops `face' together with `read-only'.
          (mx-check "typing: separator is rear-nonsticky for face"
                    (get-text-property
                     (1- (elneo-room--input-beg-pos)) 'rear-nonsticky)
                    '(read-only face))
          (mx-check "typing: draft text carries no face"
                    (progn (goto-char (point-max)) (insert "x hello")
                           (get-text-property (1- (point-max)) 'face))
                    nil))
      (kill-buffer buf)))

  ;; --- the separator hints: reply and edit name C-j too, so the
  ;; newline key is discoverable in every draft mode, not only in the
  ;; plain one.

  (let ((buf (mx-send-setup)))
    (unwind-protect
        (with-current-buffer buf
          (mx-check "separator: the plain draft hints C-j"
                    (and (string-search "C-j newline"
                                        (elneo-room--separator-text)) t)
                    t)
          (let ((elneo-room--reply-to "$other")
                (elneo-room--reply-sender "Ann")
                (elneo-room--edit-to nil))
            (mx-check "separator: a reply hints C-j"
                      (and (string-search "C-j newline"
                                          (elneo-room--separator-text)) t)
                      t))
          (let ((elneo-room--reply-to nil)
                (elneo-room--edit-to "$mine"))
            (mx-check "separator: an edit hints C-j"
                      (and (string-search "C-j newline"
                                          (elneo-room--separator-text)) t)
                      t)))
      (kill-buffer buf)))

  (message "results: %d passed, %d failed" pass fail)
  (kill-emacs (if (zerop fail) 0 1)))