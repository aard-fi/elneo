;;; draft-preview-test.el --- M-RET previews the draft as sent -*- lexical-binding: t; -*-

;; The input preview: M-RET shows the current draft rendered with the
;; exact converter chain RET would use — the fontified converter when
;; `elneo-room-yank-fontify' is on, the plain markup converter
;; otherwise; a bridge listed in `elneo-room-plain-bridges' (or the
;; plain toggle) sends unformatted, and the preview says exactly
;; that: "would send as plain text".  The rendered half goes through
;; the real rich pass, so faces and blocks preview as sent.
;;
;; Run: emacs -Q --batch -L lisp -l test/draft-preview-test.el

(require 'elneo-room)

(when (fboundp 'libxml-parse-html-region)

  (let ((pass 0) (fail 0))
    (defun mx-check (label got expected)
      (if (equal got expected)
          (progn (cl-incf pass) (message "ok: %s" label))
        (cl-incf fail)
        (message "FAIL: %s — got %S, expected %S" label got expected)))

    (defun mx-preview-setup (&optional draft)
      "A backfilled room buffer whose draft area holds DRAFT."
      (let ((buf (generate-new-buffer " *mx-preview-room*")))
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
                        :body "hi there")))
          (elneo-room--reset-input-area (or draft "")))
        buf))

    ;; --- the full M-RET path, default converters ---

    (let ((buf (mx-preview-setup "**x**")))
      (with-current-buffer buf
        (goto-char (point-max))
        (elneo-room-preview-draft)
        (with-current-buffer "*Matrix Draft Preview*"
          (let ((text (buffer-string)))
            (mx-check "preview: the draft shown raw + its sent shape"
                      (and (string-search "Draft:\n**x**\n\nAs sent:\n" text)
                           (string-search "As sent:\n" text)
                           t)
                      t)
            ;; The rendered half carries the real rich pass, so the
            ;; `**x**' shows bold.
            (goto-char (point-min))
            (search-forward "As sent:\n")
            (search-forward "x")
            (mx-check "preview: the `**x**` markup rendered bold"
                      (get-char-property (1- (point)) 'face)
                      'bold)
            ;; The preview buffer is a help window, not a room: no
            ;; room block properties leak in.
            (mx-check "preview: no room event-id property on it"
                      (get-char-property (1- (point))
                                         'elneo-room-event-id)
                      nil)
            (kill-buffer)))))

    ;; --- the converter dispatch follows `RET''s chain ---

    ;; yank-fontify off: the plain markup converter runs (the
    ;; fontified one is left alone — same result here, checked via a
    ;; dispatch probe).
    (let ((fontified-called nil))
      (with-current-buffer (mx-preview-setup "**y**")
        (let ((elneo-room-yank-fontify nil))
          (cl-letf (((symbol-function 'elneo-room--fontified-body)
                     (lambda (&rest _) (setq fontified-called t) "x")))
            (goto-char (point-max))
            (elneo-room-preview-draft)))
        (when (get-buffer "*Matrix Draft Preview*")
          (kill-buffer "*Matrix Draft Preview*"))
        (mx-check "preview: fontify off takes the plain converter"
                  fontified-called nil)))

    ;; --- the plain gate ---

    ;; A room whose bridge is listed plain: nothing rich to preview,
    ;; the message says exactly what would go out (and no preview
    ;; buffer gets built).
    (let ((plain-note nil))
      (with-current-buffer (mx-preview-setup "**z**")
        (cl-letf (((symbol-function 'elneo-room--rich-send-p) (lambda (&rest _) nil))
                  ((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (setq plain-note (apply #'format fmt args)))))
          (goto-char (point-max))
          (elneo-room-preview-draft))
        (mx-check "preview: plain bridge says would-send-plain"
                  plain-note "Matrix: would send as plain text")
        (mx-check "preview: the plain path builds no help buffer"
                  (get-buffer "*Matrix Draft Preview*")
                  nil)
        (when (get-buffer "*Matrix Draft Preview*")
          (kill-buffer "*Matrix Draft Preview*"))))

    ;; An empty draft previews nothing.
    (let ((plain-note nil))
      (with-current-buffer (mx-preview-setup "")
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (setq plain-note (apply #'format fmt args)))))
          (goto-char (point-max))
          (elneo-room-preview-draft))
        (mx-check "preview: an empty draft is silent"
                  (list plain-note (get-buffer "*Matrix Draft Preview*"))
                  '(nil nil))))

    (message "%d checks: %d ok, %d FAILED" (+ pass fail) pass fail)
    (when (> fail 0) (kill-emacs 1))))