;;; code-send-test.el --- rich-send policy, fontified yanks, code sends -*- lexical-binding: t; -*-

;; Outgoing rich text: `elneo-room--rich-send-p' gates formatted
;; bodies per bridge protocol (rooms bridged into
;; `elneo-room-plain-bridges' send exactly what was typed), faces on
;; draft text convert to HTML spans through
;; `elneo-room--fontified-body', and the dispatch regex slices
;; preserve text properties so fontification survives from the draft
;; to the send.  The daemon is stubbed at `elneo-send-message'.
;;
;; Run: emacs -Q --batch -L lisp -l test/code-send-test.el

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
                (nth 0 args) (nth 1 args) (nth 2 args) (nth 3 args))
          mx-sent)
    (cl-incf mx-req)
    mx-req)

  (defun mx-send-setup ()
    "A backfilled room buffer registered for on-new-message.
The draft area and its markers exist as after a first-page render."
    (let ((buf (generate-new-buffer " *mx-code-room*")))
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
          (elneo-room--append-messages
           (copy-tree
            `((:event-id "$mine" :sender "@me:hs" :sender-name "Me"
               :ts 1700000060000 :msgtype "m.text" :is-own t
               :body "my own old message"))))
          (elneo-room--reset-input-area "")
          (puthash (cons "mxtest" "!room") buf elneo-room--buffers)))
      buf))

  ;; A fontified chunk: what a yank from a source buffer carries.
  (defun mx-red (text)
    (propertize text 'face '(:foreground "#ff0000")))

  ;; The rich gate: bridge protocol against the plain list.
  (let ((elneo-room-plain-bridges '("telegram")))
    (mx-check "rich: no bridge sends rich"
              (elneo-room--rich-send-p '(:room-id "!n")) t)
    (mx-check "rich: unlisted bridge sends rich"
              (elneo-room--rich-send-p '(:room-id "!s" :bridge "slack")) t)
    (mx-check "rich: listed bridge sends plain"
              (elneo-room--rich-send-p '(:room-id "!t" :bridge "telegram")) nil)
    (mx-check "rich: the match ignores case"
              (elneo-room--rich-send-p '(:room-id "!t" :bridge "Telegram")) nil))

  ;; Face → CSS resolution, on the shapes yanks actually carry.
  (mx-check "css: plist foreground"
            (elneo-room--face-css '(:foreground "#ff0000")) "color:#ff0000")
  (mx-check "css: weight and slant join"
            (elneo-room--face-css '(:weight bold :slant italic))
            "font-weight:bold;font-style:italic")
  (mx-check "css: default and nil faces stay plain"
            (and (elneo-room--face-css nil) (elneo-room--face-css 'default))
            nil)
  (mx-check "css: background-only faces are not fontification"
            (elneo-room--face-css '(:background "#eeeeee")) nil)
  ;; A list starts with the face when a spec follows it — a list whose
  ;; car is a keyword is a spec plist instead.
  (mx-check "css: face lists merge, first definition wins"
            (elneo-room--face-css '(bold (:foreground "#00ff00")))
            "color:#00ff00;font-weight:bold")
  (mx-check "css: named colors normalize to #rrggbb"
            (elneo-room--color-css "red") "#ff0000")
  (mx-check "css: unresolvable colors drop out"
            (elneo-room--color-css "not-a-color") nil)

  ;; The fontified body converter.
  (mx-check "fontified: colored runs become spans"
            (elneo-room--fontified-body
             (concat "code(" (mx-red "warn") ")"))
            "code(<span style=\"color:#ff0000\">warn</span>)")
  (mx-check "fontified: markup applies inside a run"
            (elneo-room--fontified-body
             (concat "a " (mx-red "**bold**") " b"))
            "a <span style=\"color:#ff0000\"><strong>bold</strong></span> b")
  (mx-check "fontified: faces without css still mark up"
            (elneo-room--fontified-body
             (concat "plain and " (propertize "italic" 'face '(:slant italic))))
            "plain and <span style=\"font-style:italic\">italic</span>")
  (mx-check "fontified: fenced blocks ignore faces, keep their shape"
            (elneo-room--fontified-body
             (concat "x\n" (mx-red "```el\n(+ 1 2)\n```")))
            "x\n<pre><code>el\n(+ 1 2)\n</code></pre>")
  (mx-check "fontified: unfontified text keeps the old path"
            (elneo-room--fontified-body "a `code` b") "a <code>code</code> b")
  (mx-check "fontified: plain text still sends nil"
            (elneo-room--fontified-body "hello") nil)

  ;; The wire gate: what leaves for native vs bridged rooms.
  (let ((buf (mx-send-setup)))
    (unwind-protect
        (with-current-buffer buf
          ;; The room record the buffer's profile/room-id resolve to.
          (puthash (cons "mxtest" "!room")
                   '(:profile "mxtest" :room-id "!room" :display-name "R"
                     :bridge "Telegram")
                   elneo--rooms)
          (setq mx-req 0 mx-sent nil)
          (let ((elneo-accounts '(("mxtest" :user-id "@me:hs"))))
            (cl-letf (((symbol-function 'elneo-send-message) #'mx-send-stub))
              ;; Bridged into a listed protocol: plain text only —
              ;; no formatted body, markup characters stay literal.
              (elneo-room--send-text "**bold** stays")
              (mx-check "wire: plain bridge sends no formatted body"
                        (caddr (car mx-sent)) nil)
              (mx-check "wire: plain bridge keeps markup literal"
                        (car (car mx-sent)) "**bold** stays")
              ;; Faces on the yank do not sneak through either.
              (elneo-room--send-text (mx-red "colored"))
              (mx-check "wire: plain bridge strips yanked faces"
                        (get-text-property 1 'face (car (car mx-sent)))
                        nil)
              ;; The room record going native flips the gate.
              (puthash (cons "mxtest" "!room")
                       '(:profile "mxtest" :room-id "!room" :display-name "R")
                       elneo--rooms)
              (elneo-room--send-text (mx-red "colored"))
              (mx-check "wire: native room sends the span"
                        (caddr (car mx-sent))
                        "<span style=\"color:#ff0000\">colored</span>")
              (mx-check "wire: native wire body is plain text"
                        (get-text-property 0 'face (car (car mx-sent)))
                        nil)
              ;; Fontify off: faces ignored, plain markup still works.
              (let ((elneo-room-yank-fontify nil))
                (elneo-room--send-text
                 (concat (mx-red "**bold**") " here"))
                (mx-check "wire: fontify off falls back to markup"
                          (caddr (car mx-sent)) "<strong>bold</strong> here")))))
      (kill-buffer buf)))

  ;; Dispatch keeps faces on text segments and strips them from
  ;; attachment paths; the tag routing itself is unchanged.
  (let ((text-segments nil) (paths nil))
    (cl-letf (((symbol-function 'elneo-room--send-text)
               (lambda (body) (push body text-segments)))
              ((symbol-function 'elneo-room--send-image)
               (lambda (path &optional _) (push path paths)))
              ((symbol-function 'elneo-room--send-file)
               (lambda (path &optional _) (push path paths))))
      (elneo-room--dispatch-input
       (concat "before " (mx-red "mid") " and [image: /tmp/pic.png] "
               "[file: /tmp/a.txt] after"))
      (setq text-segments (nreverse text-segments)
            paths (nreverse paths))
      (mx-check "dispatch: text segments keep their faces"
                ;; [image: …] and [file: …] split the draft: two
                ;; between-tag segments (each empty here) and one
                ;; face-carrying prologue.
                (and (= (length text-segments) 3)
                     (string-equal (car text-segments)
                                   "before mid and ")
                     (get-text-property 7 'face (car text-segments)))
                '(:foreground "#ff0000"))
      (mx-check "dispatch: attachment paths are plain"
                (and (string-equal (nth 0 paths) "/tmp/pic.png")
                     (string-equal (nth 1 paths) "/tmp/a.txt")
                     (not (get-text-property 1 'face (nth 0 paths)))
                     t)
                t)))

  ;; Region sends: language detection, the fence body, the rich
  ;; <pre><code> with a language class and colored spans, and the
  ;; plain-bridge degradation.  Source buffer is a temp buffer; the
  ;; target picker and the daemon are stubbed.
  (let ((room '(:profile "mxtest" :room-id "!room" :display-name "Dev")))
    (cl-letf (((symbol-function 'elneo-send-message) #'mx-send-stub)
              ((symbol-function 'elneo-room--code-target-room)
               (lambda () room)))
      (setq mx-req 0 mx-sent nil)
      ;; A source buffer, fontified like a real code buffer.
      (let ((src (generate-new-buffer " *mx-src*")))
        (unwind-protect
            (with-current-buffer src
              (emacs-lisp-mode)
              (insert "(+ 1 2)")
              (put-text-property 4 5 'face '(:foreground "#00ff00"))
              ;; Auto language from the major mode; body keeps the
              ;; fence, the rich body gets the tag and the color.
              (elneo-send-region-as-code (point-min) (point-max))
              (mx-check "region: fence body with the detected language"
                        (car (car mx-sent)) "```lisp\n(+ 1 2)\n```")
              (mx-check "region: rich body has the language class"
                        (and (string-match-p
                              "class=\"language-lisp\"" (caddr (car mx-sent)))
                             t)
                        t)
              (mx-check "region: rich body keeps the color span"
                        (and (string-match-p
                              "<span style=\"color:#00ff00\">1</span>"
                              (caddr (car mx-sent)))
                             t)
                        t)
              ;; No text properties on either wire string.
              (mx-check "region: wire body is plain text"
                        (get-text-property 0 'face (car (car mx-sent))) nil)
              (mx-check "region: rich body is plain text"
                        (get-text-property 0 'face (caddr (car mx-sent))) nil)
              ;; C-u prompts (stubbed to return the detection default).
              (let ((mx-sent nil))
                (cl-letf (((symbol-function 'read-string)
                           (lambda (_prompt _init _hist default) default)))
                  (elneo-send-region-as-code (point-min) (point-max) '(4))
                  (mx-check "region: prompt defaults to the detection"
                            (car (car mx-sent)) "```lisp\n(+ 1 2)\n```")))
              ;; Empty prompt → no language tag anywhere.
              (let ((mx-sent nil))
                (cl-letf (((symbol-function 'read-string)
                           (lambda (_prompt _init _hist _default) "")))
                  (elneo-send-region-as-code (point-min) (point-max) '(4))
                  (mx-check "region: empty prompt drops the tag"
                            (car (car mx-sent)) "```\n(+ 1 2)\n```")))
              ;; HTML in the code is escaped, not marked up.
              (let ((mx-sent nil))
                (erase-buffer)
                (insert "a <b> &")
                (elneo-send-region-as-code (point-min) (point-max))
                (mx-check "region: code escapes, never marks up"
                          (and (string-search "a &lt;b&gt; &amp;</code></pre>"
                                              (caddr (car mx-sent)))
                               t)
                          t)))
          (kill-buffer src))))
    ;; A plain-listed bridge gets the code block, but not the color
    ;; spans: pre/code itself survives the relay, font colors do not.
    (let ((bridged '(:profile "mxtest" :room-id "!room" :bridge "telegram"))
          (src (generate-new-buffer " *mx-src-bridge*")))
      (unwind-protect
          ;; The source buffer and its faces exist, but the bridge
          ;; policy strips the spans only.
          (with-current-buffer src
            (emacs-lisp-mode)
            (insert "(+ 1 2)")
            (put-text-property 4 5 'face '(:foreground "#ff0000"))
            (let ((mx-sent nil))
              (cl-letf (((symbol-function 'elneo-send-message) #'mx-send-stub)
                        ((symbol-function 'elneo-room--code-target-room)
                         (lambda () bridged)))
                (elneo-send-region-as-code (point-min) (point-max))
                (mx-check "region: plain bridge keeps the code block"
                          (caddr (car mx-sent))
                          "<pre><code class=\"language-lisp\">(+ 1 2)</code></pre>")
                (mx-check "region: plain bridge drops the color spans"
                          (and (not (string-search "span" (caddr (car mx-sent))))
                               t)
                          t))))
        (kill-buffer src))))

  ;; Language detection: the alist and the -mode fallback.
  (with-temp-buffer
    (emacs-lisp-mode)
    (mx-check "lang: emacs-lisp mode via alist"
              (elneo--major-mode-language) "lisp"))
  (with-temp-buffer
    (let ((major-mode 'weird-thing-ts-mode))
      (mx-check "lang: unknown mode falls back to -mode stripping"
                (elneo--major-mode-language) "weird-thing-ts")))

  ;; The target picker: exactly one visible room buffer wins, more
  ;; than one goes to completing-read.
  (let ((room '(:profile "mxtest" :room-id "!room" :display-name "Dev"))
        (picked nil)
        (buf (generate-new-buffer " *mx-visible-room*")))
    (unwind-protect
        (with-current-buffer buf
          (elneo-room-mode)
          (setq-local elneo-room--profile "mxtest")
          (setq-local elneo-room--room-id "!room")
          (puthash (cons "mxtest" "!room") room elneo--rooms)
          ;; elneo-buffer-visible-p: the stub answers for our buffer.
          (cl-letf (((symbol-function 'elneo-buffer-visible-p)
                     (lambda (b) (eq b buf))))
            (mx-check "picker: single visible room, no prompt"
                      (plist-get (elneo-room--code-target-room)
                                 :display-name)
                      "Dev")
            (let ((extra (generate-new-buffer " *mx-second-room*")))
              (with-current-buffer extra
                (elneo-room-mode))
              (unwind-protect
                  (cl-letf (((symbol-function 'elneo-buffer-visible-p)
                             (lambda (b) (or (eq b buf) (eq b extra))))
                            ((symbol-function 'elneo-completing-read-room)
                             (lambda () (setq picked t) room)))
                    (elneo-room--code-target-room)
                    (mx-check "picker: ambiguous rooms prompt" picked t))
                (kill-buffer extra)))))
      (kill-buffer buf)))

  (message "results: %d passed, %d failed" pass fail)
  (kill-emacs (if (zerop fail) 0 1)))