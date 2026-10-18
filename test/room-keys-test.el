;;; room-keys-test.el --- `c' copies text, `l' copies a permalink -*- lexical-binding: t; -*-

;; Room copy keys (telega's message keys): `c' kills the message at
;; point's stored body, `l' kills its https://matrix.to permalink
;; (the room half prefers the canonical alias, encoded like the
;; spec's own examples).  Nothing else renders — the daemon and the
;; registry only feed the permalink's room half.
;;
;; Run: emacs -Q --batch -L lisp -l test/room-keys-test.el

(require 'elneo-room)

(require 'url-util)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defun mx-keys-setup ()
    (let ((buf (generate-new-buffer " *mx-keys-room*")))
      (with-current-buffer buf
        (elneo-room-mode)
        (setq-local elneo-room--profile "mxtest")
        (setq-local elneo-room--room-id "!room")
        (setq elneo-room--seen (make-hash-table :test 'equal))
        (setq elneo-room--backfilled t)
        (insert "header\n")
        (goto-char (point-max))
        (elneo-room--append-messages
         `((:event-id "$other" :sender "@a:hs" :sender-name "Ann"
                      :ts 1700000000000 :msgtype "m.text" :is-own nil
                      :body "hi there")
           (:event-id "$pending" :sender "@me:hs" :sender-name "Me"
                      :ts 1700000060000 :msgtype "m.text" :is-own t
                      :pending t :body "still flying")))
        (elneo-room--reset-input-area ""))
    buf))

  ;; --- `c' copies the body ---

  (let* ((buf (mx-keys-setup))
         killed)
    (cl-letf (((symbol-function 'kill-new)
               (lambda (s &optional _) (setq killed s))))
      (with-current-buffer buf
        (goto-char (point-min))
        (search-forward "hi there")
        (goto-char (line-beginning-position))
        (elneo-room--c)))
    (mx-check "`c' kills the message at point's body" killed "hi there"))

  ;; A ⏱/✗ id names nothing on the server: `c' refuses like every
  ;; other point command.
  (let ((buf (mx-keys-setup)))
    (with-current-buffer buf
      (goto-char (point-min))
      (search-forward "still flying")
      (goto-char (line-beginning-position))
      (mx-check "`c' refuses a provisional message"
                (condition-case err
                    (progn (call-interactively #'elneo-room--c) nil)
                  (user-error (cadr err)))
                "No message at point")))

  ;; In the draft area `c' self-inserts (defkey discipline).
  (let ((buf (mx-keys-setup)))
    (with-current-buffer buf
      (goto-char (point-max))
      (call-interactively 'elneo-room--c)
      (mx-check "`c' self-inserts in the draft"
                (and (eq (char-before (point-max)) ?c)
                     (equal (elneo-room--draft-text) "c"))
                t)))

  ;; --- `l' copies a matrix.to permalink ---

  (let ((elneo--rooms (make-hash-table :test 'equal)))
    (puthash (cons "mxtest" "!room")
             (list :profile "mxtest" :room-id "!room"
                   :alias "#testroom:hs" :name "Test")
             elneo--rooms)
    (let* ((buf (mx-keys-setup))
           link)
      (cl-letf (((symbol-function 'kill-new)
                 (lambda (s &optional _) (setq link s))))
        (with-current-buffer buf
          (goto-char (point-min))
          (search-forward "hi there")
          (goto-char (line-beginning-position))
          (elneo-room--l)))
      (mx-check "`l' kills the permalink with the canonical alias"
                link
                (concat "https://matrix.to/#/"
                        (url-hexify-string "#testroom:hs") "/"
                        (url-hexify-string "$other")))))

  ;; Without an alias the room id goes out — id-encoded.
  (let ((link (elneo-room--permalink (list :profile "mxtest" :room-id "!a:b")
                                     "$1:2")))
    (mx-check "permalink: room id encodes its `:'"
              link
              (concat "https://matrix.to/#/"
                      (url-hexify-string "!a:b") "/"
                      (url-hexify-string "$1:2")))
    ;; Every id character gets percent-encoded — url-hexify-string
    ;; only lets the unreserved set through (`!' included).
    (mx-check "permalink: `!' and `:' and `$' all encoded"
              (and (string-search "%21a%3Ab" link)
                   (string-search "%241%3A2" link) t)
              t))

  ;; `elneo-room--matrix-to-link' reads the room half back (the
  ;; receive-side parser accepts what the permalink emits; event
  ;; anchors are outside its contract).
  (let* ((link (elneo-room--permalink (list :alias "#r:hs"))))
    (mx-check "permalink round-trips through our own matrix.to parser"
              (elneo-room--matrix-to-link link)
              '("#r:hs")))

  ;; Unsent gate: provisional messages get no permalink.
  (let ((buf (mx-keys-setup)))
    (with-current-buffer buf
      (goto-char (point-min))
      (search-forward "still flying")
      (goto-char (line-beginning-position))
      (mx-check "`l' refuses a provisional message"
                (condition-case err
                    (progn
                      (call-interactively #'elneo-room--l)
                      nil)
                  (user-error (cadr err)))
                "Cannot open a link on a message that is not on the server yet")))

  ;; --- pin dispatch payload (the send side, no render) ---
  ;; `elneo-send-pin' carries unpin only when set, like a reaction's
  ;; remove; the daemon toggles.
  (let (payload)
    (cl-letf (((symbol-function 'elneo-server--call)
               (lambda (_profile ev callback)
                 (setq payload ev)
                 (funcall callback "mxtest" '((@ok . t))))))
      (elneo-send-pin "mxtest" "!room" "$x" nil #'ignore)
      (mx-check "pin payload: pin omits unpin"
                (alist-get 'unpin payload) nil)
      (elneo-send-pin "mxtest" "!room" "$x" t #'ignore)
      (mx-check "pin payload: unpin rides as t"
                (alist-get 'unpin payload) t)
      (mx-check "pin payload: room + event + type"
                (list (alist-get '@type payload)
                      (alist-get 'room_id payload)
                      (alist-get 'event_id payload))
                '("pinMessage" "!room" "$x"))))

  (message "%d checks: %d ok, %d FAILED"
           (+ pass fail) pass fail)
  (when (> fail 0) (kill-emacs 1)))