;;; bar-jump-test.el --- bar keys u/@ next-room jumps, r mark read -*- lexical-binding: t; -*-

;; The bar's telega-parity keys: `u' opens the next room with unread
;; messages and `@' the next with highlights, wrapping once around
;; `elneo-room-bar--visible-rooms' and walking strictly past whatever
;; the previous jump picked (the cursor survives re-sorts; a scan
;; finding nothing clears it and says so).  `r' marks the room under
;; point read up to its newest event — invites carry no last event,
;; so they refuse honestly.
;;
;; Run: emacs -Q --batch -L lisp -l test/bar-jump-test.el

(require 'elneo-room-bar)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defun mx-registry ()
    "Populate `elneo--rooms' with four synthetic rooms.
Activity order (newest first): !hl, !loud, !empty, !quiet."
    (setq elneo--rooms (make-hash-table :test 'equal))
    (dolist (room
             '((:profile "a" :room-id "!quiet" :display-name "Quiet"
                         :unread 0 :highlights 0 :last-activity 100
                         :last-event-id nil)
               (:profile "a" :room-id "!loud" :display-name "Loud"
                         :unread 5 :highlights 1 :last-activity 300
                         :last-event-id "$loud")
               (:profile "a" :room-id "!hl" :display-name "Pings"
                         :unread 0 :highlights 3 :last-activity 400
                         :last-event-id "$hl")
               (:profile "a" :room-id "!empty" :display-name "Empty"
                         :unread 2 :highlights 0 :last-activity 200
                         :last-event-id "$e")))
      (puthash (cons (plist-get room :profile)
                     (plist-get room :room-id))
               room
               elneo--rooms)))

  ;; --- u / @ walk and wrap ---

  (mx-registry)
  (setq elneo-room-bar--jump-key nil)
  (let (opened)
    (cl-letf (((symbol-function 'elneo-room-open)
               (lambda (room &optional _stay)
                 (setq opened (cons (plist-get room :room-id) opened))))
              ;; jump tests run nowhere near a bar window: point has
              ;; no row property, so only the cursor can anchor.
              ((symbol-function 'elneo-room-bar--prop-near-point)
               (lambda (_prop) nil)))
      (elneo-room-bar-next-unread)
      (mx-check "u: first unread (after Pings/Quiet skip)"
                (list (car opened) elneo-room-bar--jump-key)
                '("!loud" ("a" . "!loud")))
      (elneo-room-bar-next-unread)
      (mx-check "u: walks past the previous hit"
                (list (car opened) elneo-room-bar--jump-key)
                '("!empty" ("a" . "!empty")))
      (elneo-room-bar-next-unread)
      (mx-check "u: wraps around the list"
                (list (car opened) elneo-room-bar--jump-key)
                '("!loud" ("a" . "!loud")))
      ;; @ starts its own walk from the list's top (no cursor, no
      ;; row under point): the first room with any highlight.
      (setq elneo-room-bar--jump-key nil opened nil)
      (elneo-room-bar-next-highlight)
      (mx-check "@: first highlight room"
                (list (car opened) elneo-room-bar--jump-key)
                '("!hl" ("a" . "!hl")))))

  ;; --- point anchors when the cursor is fresh ---

  (mx-registry)
  (setq elneo-room-bar--jump-key nil)
  (let (opened)
    (cl-letf (((symbol-function 'elneo-room-open)
               (lambda (room &optional _stay)
                 (setq opened (plist-get room :room-id)))))
      (with-temp-buffer
        (insert "header  Loud  quiet\n")
        (put-text-property 9 13 'elneo-room-key (cons "a" "!loud"))
        ;; point's own row is skipped — strictly after it.
        (goto-char 10)
        (elneo-room-bar-next-unread)
        (mx-check "u: point's row anchors, strictly after"
                  opened "!empty"))))

  ;; --- the emptiness errors, and clear the cursor ---

  (mx-registry)
  (setq elneo-room-bar--jump-key nil)
  (cl-letf (((symbol-function 'elneo-room-bar--prop-near-point)
             (lambda (_prop) nil))
            ((symbol-function 'elneo-rooms-all) (lambda () nil)))
    (mx-check "u: no unread rooms names the emptiness"
              (condition-case err (progn (elneo-room-bar-next-unread) nil)
                (user-error (cadr err)))
              "Matrix: no unread rooms")
    (mx-check "@: no highlights likewise"
              (condition-case err (progn (elneo-room-bar-next-highlight) nil)
                (user-error (cadr err)))
              "Matrix: no highlight rooms"))
  (mx-check "a failed scan cleared the cursor"
            elneo-room-bar--jump-key nil)

  ;; --- r marks the room under point read ---

  (mx-registry)
  (let (payload said)
    (cl-letf (((symbol-function 'elneo-server--call)
               (lambda (_profile ev callback)
                 (setq payload ev)
                 (funcall callback "a" '((@ok . t)))))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq said (apply #'format fmt args)))))
      (with-temp-buffer
        (insert "x  Empty\n")
        (put-text-property 4 9 'elneo-room-key (cons "a" "!empty"))
        (goto-char 5)
        (elneo-room-bar-mark-read-at-point)
        (mx-check "r: markRoomRead up to the newest event"
                  (list (alist-get '@type payload)
                        (alist-get 'room_id payload)
                        (alist-get 'event_id payload)
                        said)
                  '("markRoomRead" "!empty" "$e"
                    "Matrix: marked Empty read")))
      ;; An invite has no last event: honest refusal.
      (with-temp-buffer
        (insert "x  Quiet\n")
        (put-text-property 4 9 'elneo-room-key (cons "a" "!quiet"))
        (goto-char 5)
        (mx-check "r: nothing to mark yet"
                  (condition-case err
                      (progn (elneo-room-bar-mark-read-at-point) nil)
                    (user-error (cadr err)))
                  "Nothing to mark yet")))
    ;; Off a row: the same "no room" the open path uses.
    (with-temp-buffer
      (insert "header\n")
      (mx-check "r: no room on this line"
                (condition-case err
                    (progn (elneo-room-bar-mark-read-at-point) nil)
                  (user-error (cadr err)))
                "No room on this line")))

  (message "%d checks: %d ok, %d FAILED" (+ pass fail) pass fail)
  (when (> fail 0) (kill-emacs 1)))