;;; voice-test.el --- voice notes: bars, rendering, play flow -*- lexical-binding: t; -*-

;; Voice messages (MSC3245/3246): the waveform downsampling and text
;; rendering, the message rendering branch (voice note vs generic
;; audio file), RET dispatch (voice plays, plain media opens, no
;; media prompts), and the play flow with the daemon stubbed at
;; elneo-download-media: the file lands with the player, the played
;; state flips, a failed download reports without crashing.
;;
;; Run: emacs -Q --batch -L lisp -l test/voice-test.el

(require 'elneo-room)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  ;; Waveform downsampling: chunk maximum, empty wave → nil
  (mx-check "voice bars: chunk max"
            (elneo-room--voice-bars [0 512 1024 256] 2)
            '(0.5 1.0))
  (mx-check "voice bars: more bars than samples"
            (elneo-room--voice-bars [300 100] 4)
            '(0.29296875 0.0 0.09765625 0.0))
  (mx-check "voice bars: empty wave is nil"
            (elneo-room--voice-bars nil 32)
            nil)
  (mx-check "voice bars: empty wave list is nil"
            (elneo-room--voice-bars '() 32)
            nil)
  (mx-check "voice bars: sample count preserved"
            (length (elneo-room--voice-bars (make-vector 1024 500) 32))
            32)

  ;; Terminal wave rendering
  (mx-check "wave text: ramp"
            (elneo-room--voice-wave-text '(0.0 0.5 1.0))
            "▁▅█")
  (mx-check "wave text: clamps at the top"
            (elneo-room--voice-wave-text '(1.0 0.99))
            "██")

  ;; SVG wave rendering: one rect per bar, in the file
  (let ((svg (elneo-room--voice-wave-svg '(0.0 0.5 1.0) nil)))
    (mx-check "wave svg: well-formed"
              (and (string-prefix-p "<svg " svg)
                   (string-suffix-p "</svg>" svg))
              t)
    (mx-check "wave svg: one rect per bar"
              (cl-count-if (lambda (s) (string-prefix-p "rect" s))
                           (split-string svg "<"))
              3))

  ;; A room buffer holding messages, rendered through the real
  ;; insert path (append-messages → insert-message).
  (defun mx-voice-setup ()
    (let ((buf (generate-new-buffer " *mx-voice-room*")))
      (with-current-buffer buf
        (elneo-room-mode)
        (let ((elneo-room-avatars nil)
              (elneo-room--profile "mxtest"))
          (setq elneo-room--seen (make-hash-table :test 'equal))
          (insert "header\n")
          (goto-char (point-max))
          (elneo-room--append-messages
           ;; copy-tree: the backquote is one shared structure; tests
           ;; mutate their messages (plist-put for the no-duration
           ;; case), which must not leak into later setups.
           (copy-tree
            `((:event-id "$v1" :sender "@a:hs" :sender-name "Ann" :ts 1700000000000
               :msgtype "m.audio" :is-own nil
               :media ((source . "mxc://hs/v") (duration . 72000)
                       (voice . [0 512 1024])))
              (:event-id "$f1" :sender "@a:hs" :sender-name "Ann" :ts 1700000060000
               :msgtype "m.audio" :is-own nil
               :media ((source . "mxc://hs/f") (filename . "song.ogg")))
              (:event-id "$t1" :sender "@a:hs" :sender-name "Ann" :ts 1700000120000
               :msgtype "m.text" :is-own nil :body "hello")))))
      buf)))

  (let ((buf (mx-voice-setup)))
    (unwind-protect
        (with-current-buffer buf
          ;; Batch: the terminal wave path.  A voice note renders bars
          ;; and duration, not the generic [audio: name] tag.
          (goto-char (point-min))
          (mx-check "rendering: voice wave in the buffer"
                    (and (search-forward "[voice] ▁▁▁▁▁▁▁▁▁▁▅▁▁▁▁▁▁▁▁▁▁█▁▁▁▁▁▁▁▁▁▁ (1:12)" nil t)
                         t)
                    t)
          (mx-check "rendering: voice carries media data"
                    (elneo-room--voice-at-point)
                    '((source . "mxc://hs/v") (duration . 72000)
                      (voice . [0 512 1024])))
          ;; A plain audio file keeps the generic rendering
          (search-forward "[audio: song.ogg]" nil t)
          (mx-check "rendering: plain audio is not voice"
                    (elneo-room--voice-at-point)
                    nil)
          ;; The voice block is reachable again (point moved past it)
          (goto-char (point-min))
          (search-forward "[voice]" nil t)
          (goto-char (match-beginning 0))
          (mx-check "voice at point: on the entry"
                    (and (elneo-room--voice-at-point) t)
                    t)
          ;; One past the whole entry (wave + duration suffix) still
          ;; counts, thanks to the media data on the suffix.
          (search-forward "(1:12)" nil t)
          (mx-check "voice at point: one past counts"
                    (and (elneo-room--voice-at-point) t)
                    t))
      (kill-buffer buf)))

  ;; No duration from the sender: the tag stands alone
  (let ((buf (mx-voice-setup)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          ;; duration lives in the media alist; strip it and re-render
          (let ((msg (gethash "$v1" elneo-room--seen)))
            (setq msg (plist-put msg :media
                                (assq-delete-all 'duration (plist-get msg :media))))
            (puthash "$v1" msg elneo-room--seen)
            (elneo-room--replace-message "$v1" msg))
          (goto-char (point-min))
          (mx-check "rendering: wave without a duration suffix"
                    (save-excursion
                      (and (search-forward "[voice] ▁▁▁▁▁▁▁▁▁▁▅▁▁▁▁▁▁▁▁▁▁█▁▁▁▁▁▁▁▁▁▁" nil t)
                           (not (search-forward " (" (line-end-position) t))))
                    t))
      (kill-buffer buf)))

  ;; RET dispatch: voice plays, plain media opens, neither prompts
  (let* ((buf (mx-voice-setup))
         (played nil) (opened nil) (prompted nil))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (search-forward "[voice]" nil t)
          (goto-char (match-beginning 0))
          (cl-letf (((symbol-function 'elneo-room-play-voice-at-point)
                     (lambda () (setq played t)))
                    ((symbol-function 'elneo-room-open-media-at-point)
                     (lambda () (setq opened t)))
                    ((symbol-function 'elneo-room-send)
                     (lambda () (setq prompted t))))
            (setq elneo-room--backfilled t)
            (call-interactively #'elneo-room--ret)
            (mx-check "RET on voice: plays" played t)
            (search-forward "[audio:" nil t)
            (goto-char (match-beginning 0))
            (call-interactively #'elneo-room--ret)
            (mx-check "RET on plain media: opens" opened t)
            (goto-char (point-min))
            (call-interactively #'elneo-room--ret)
            (mx-check "RET on plain text: prompts" prompted t)))
      (kill-buffer buf)))

  ;; The play flow: daemon stubbed, player stubbed
  (let* ((buf (mx-voice-setup))
         (saved-callback nil) (player-arg nil))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (search-forward "[voice]" nil t)
          (goto-char (match-beginning 0))
          (setq elneo-room--backfilled t)
          (cl-letf (((symbol-function 'elneo-download-media)
                     (lambda (_p _s _f callback &rest _)
                       (setq saved-callback callback)))
                    ((symbol-function 'start-process)
                     (lambda (_name _buffer command &rest args)
                       (setq player-arg (cons command args))
                       'fake-proc)))
            (let ((elneo-voice-player-command "mpv"))
              (elneo-room-play-voice-at-point)
              (mx-check "play: download started" (functionp saved-callback) t)
              (funcall saved-callback "mxtest"
                       '((@ok . t) (path . "/tmp/mx-voice.ogg")))
              (mx-check "play: player got the file"
                        player-arg '("mpv" "/tmp/mx-voice.ogg"))
              (mx-check "play: played state recorded"
                        (gethash "$v1" elneo-voice--played)
                        t))
            ;; nil player command: falls back to elneo-open-file-function.
            ;; The first play re-rendered the block, so re-find it.
            (setq player-arg nil)
            (goto-char (point-min))
            (search-forward "[voice]" nil t)
            (goto-char (match-beginning 0))
            (let ((elneo-open-file-function
                   (lambda (path) (setq player-arg path))))
              (elneo-room-play-voice-at-point)
              (funcall saved-callback "mxtest"
                       '((@ok . t) (path . "/tmp/mx-voice2.ogg")))
              (mx-check "play: nil command opens via open-file-function"
                        player-arg "/tmp/mx-voice2.ogg"))))
      (kill-buffer buf)))

  ;; Play on a non-voice entry: user-error; failed download: no crash
  (let ((buf (mx-voice-setup))
        (saved-callback nil))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          (search-forward "hello" nil t)
          (mx-check "play without voice: user-error"
                    (condition-case e
                        (progn (elneo-room-play-voice-at-point) 'no-error)
                      (user-error e))
                    '(user-error "No voice message at point"))
          (cl-letf (((symbol-function 'elneo-download-media)
                     (lambda (_p _s _f callback &rest _)
                       (setq saved-callback callback)))
                    ((symbol-function 'start-process)
                     (lambda (&rest _) (error "must not start"))))
            (goto-char (point-min))
            (search-forward "[voice]" nil t)
            (goto-char (match-beginning 0))
            (remhash "$v1" elneo-voice--played)
            (elneo-room-play-voice-at-point)
            (funcall saved-callback "mxtest"
                     '((@ok . nil) (error . "no such media")))
            (mx-check "failed download: not marked played"
                      (gethash "$v1" elneo-voice--played)
                      nil)))
      (kill-buffer buf)))

  ;; Played state re-renders in the played face
  (let ((buf (mx-voice-setup)))
    (unwind-protect
        (with-current-buffer buf
          (remhash "$v1" elneo-voice--played)
          (goto-char (point-min))
          (search-forward "[voice]" nil t)
          (goto-char (match-beginning 0))
          (mx-check "unplayed wave face"
                    (get-text-property (point) 'face)
                    'elneo-room-voice-wave)
          (puthash "$v1" t elneo-voice--played)
          (elneo-room--replace-message "$v1" (gethash "$v1" elneo-room--seen))
          (goto-char (point-min))
          (search-forward "[voice]" nil t)
          (goto-char (match-beginning 0))
          (mx-check "played wave face"
                    (get-text-property (point) 'face)
                    'elneo-room-voice-wave-played)
          (mx-check "played re-render keeps the duration"
                    (and (save-excursion (search-forward "(1:12)" nil t))
                         t)
                    t))
      (kill-buffer buf)))

  (message "results: %d passed, %d failed" pass fail)
  (kill-emacs (if (zerop fail) 0 1))))