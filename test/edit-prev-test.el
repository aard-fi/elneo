;;; edit-prev-test.el --- `e' gates shared with M-p's walk -*- lexical-binding: t; -*-

;; The edit-previous slice: the old inline `e' gates split into
;; `elneo-room--edit-refusal' (one string per refusal, shared
;; verbatim by `e' and M-p) and `elneo-room--begin-edit' (the draft
;; side effects); M-p walks the rendered history backwards past the
;; anchor to the newest own text message that passes.
;;
;; Run: emacs -Q --batch -L lisp -l test/edit-prev-test.el

(require 'elneo-room)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defun mx-edit-setup ()
    (let ((buf (generate-new-buffer " *mx-edit-room*")))
      (with-current-buffer buf
        (elneo-room-mode)
        (setq-local elneo-room--profile "mxtest")
        (setq-local elneo-room--room-id "!room")
        (setq elneo-room--seen (make-hash-table :test 'equal))
        (setq elneo-room--backfilled t)
        (setq-local elneo-room--edit-to nil)
        (setq-local elneo-room--reply-to nil)
        (setq-local elneo-room--reply-sender nil)
        (insert "header\n")
        (goto-char (point-max))
        (elneo-room--append-messages
         `((:event-id "$greet" :sender "@a:hs" :sender-name "Ann"
                      :ts 1700000000000 :msgtype "m.text" :is-own nil
                      :body "hello")
           (:event-id "$old" :sender "@me:hs" :sender-name "Me"
                      :ts 1700000060000 :msgtype "m.text" :is-own t
                      :body "oldest own")
           (:event-id "$flying" :sender "@me:hs" :sender-name "Me"
                      :ts 1700000120000 :msgtype "m.text" :is-own t
                      :pending t :body "still flying")
           (:event-id "$mid" :sender "@me:hs" :sender-name "Me"
                      :ts 1700000180000 :msgtype "m.text" :is-own t
                      :body "middle own")
           (:event-id "$pic" :sender "@me:hs" :sender-name "Me"
                      :ts 1700000240000 :msgtype "m.image" :is-own t
                      :body "[image: photo.png]")))
        (elneo-room--reset-input-area ""))
    buf))

  (defun mx-goto-bodystart (buf text)
    (with-current-buffer buf
      (goto-char (point-min))
      (search-forward text)
      (goto-char (line-beginning-position))))

  ;; --- the refusal matrix (`e' and M-p see the same strings) ---

  (mx-check "refusal: nil entry (id not loaded) refuses"
            (and (stringp (elneo-room--edit-refusal nil))
                 (string-search "own" (elneo-room--edit-refusal nil))
                 t)
            t)
  (mx-check "refusal: someone else's message"
            (elneo-room--edit-refusal
             (list :is-own nil :msgtype "m.text"))
            "Only your own messages can be edited")
  (mx-check "refusal: still pending"
            (elneo-room--edit-refusal
             (list :is-own t :msgtype "m.text" :pending t))
            "Still being sent — wait for the send to finish")
  (mx-check "refusal: send failed names the retry keys"
            (elneo-room--edit-refusal
             (list :is-own t :msgtype "m.text" :send-failed t))
            "Send failed — R retries it, K removes it")
  (mx-check "refusal: redacted"
            (elneo-room--edit-refusal
             (list :is-own t :msgtype "m.text" :redacted t))
            "This message was deleted")
  (mx-check "refusal: media points at `d'"
            (elneo-room--edit-refusal
             (list :is-own t :msgtype "m.image"))
            "Only text messages can be edited")
  (mx-check "refusal: a plain own text message passes"
            (elneo-room--edit-refusal
             (list :is-own t :msgtype "m.text" :body "hi"))
            nil)

  ;; --- begin-edit's draft side effects ---

  (let ((buf (mx-edit-setup)))
    (with-current-buffer buf
      ;; A pending reply shows the mutual-exclusion reset: starting an
      ;; edit clears it.
      (setq-local elneo-room--reply-to "$greet"
                  elneo-room--reply-sender "Ann"
                  elneo-room--edit-to nil)
      (elneo-room--begin-edit "$mid"
                              (list :event-id "$mid" :body "middle own")))
    (with-current-buffer buf
      (mx-check "begin-edit: the edit target is set"
                elneo-room--edit-to "$mid")
      (mx-check "begin-edit: the pending reply cleared"
                elneo-room--reply-to nil)
      (mx-check "begin-edit: body landed in the draft"
                (string-suffix-p "middle own"
                                 (elneo-room--draft-text))
                t)))

  ;; --- M-p's walk over the rendered history ---

  ;; No anchor: the newest own text message goes into the draft.
  ;; The pending one and the image refuse, so the newest PASSER is
  ;; the middle own message.
  (let ((buf (mx-edit-setup)))
    (with-current-buffer buf
      (goto-char (point-max))
      (elneo-room--edit-previous)
      (mx-check "M-p: newest passing own message (skipping ⏱ and media)"
                elneo-room--edit-to
                "$mid")
      ;; Again: strictly past $mid — the next earlier own passer.
      (elneo-room--edit-previous)
      (mx-check "M-p again: one further back"
                elneo-room--edit-to
                "$old")
      (mx-check "M-p again: $old's body in the draft"
                (string-suffix-p "oldest own"
                                 (elneo-room--draft-text))
                t)))

  ;; Pressed with point on a message: the walk starts strictly past
  ;; it — on $mid that is $old; on $old nothing earlier passes →
  ;; honest error.
  (let ((buf (mx-edit-setup)))
    (with-current-buffer buf
      (goto-char (point-min))
      (search-forward "middle own")
      (goto-char (line-beginning-position))
      (let (elneo-room--edit-to)
        (elneo-room--edit-previous)
        (mx-check "M-p at a message: walks strictly past it"
                  elneo-room--edit-to "$old")))
    (with-current-buffer buf
      ;; begin-edit above put point in the draft and its `let' has
      ;; unwound the edit-to it set — pin the anchor $old explicitly.
      (setq elneo-room--edit-to "$old")
      (mx-check "M-p exhausted: names the emptiness"
                (condition-case err
                    (progn (call-interactively #'elneo-room--edit-previous) nil)
                  (user-error (cadr err)))
                "No earlier own text message")))

  (message "%d checks: %d ok, %d FAILED"
           (+ pass fail) pass fail)
  (when (> fail 0) (kill-emacs 1)))