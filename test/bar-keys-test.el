;;; bar-keys-test.el --- bar telega-rootbuf keys, K leave at point -*- lexical-binding: t; -*-

;; Room buffer compat keys: J joins by link, N/+ create a room (both
;; mark-read like telega's rootbuf read-state key, \ aliases the sort
;; cycle (telega's sort prefix), and K leaves the room at point after
;; the same confirmation the room buffer's leave asks — an invited
;; room declines instead.  `/` and `F` stay reserved, unbound.
;;
;; Run: emacs -Q --batch -L lisp -l test/bar-keys-test.el

(require 'elneo-room-bar)
(require 'elneo-room)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  (defun mx-registry ()
    "Populate `elneo--rooms' with two synthetic rooms."
    (setq elneo--rooms (make-hash-table :test 'equal))
    (dolist (room
             '((:profile "a" :room-id "!room" :display-name "Ops"
                         :room-state "joined" :last-event-id "$e")
               (:profile "a" :room-id "!invited" :display-name "Inv"
                         :room-state "invited")))
      (puthash (cons (plist-get room :profile)
                     (plist-get room :room-id))
               room
               elneo--rooms)))

  ;; --- keymap: the compat keys and the reservations ---

  (mx-check "keymap: J joins by link (telega's key)"
            (lookup-key elneo-room-bar-mode-map (kbd "J"))
            #'elneo-join-matrix-to)
  (mx-check "keymap: N creates a room"
            (lookup-key elneo-room-bar-mode-map (kbd "N"))
            #'elneo-room-create)
  (mx-check "keymap: + creates a room"
            (lookup-key elneo-room-bar-mode-map (kbd "+"))
            #'elneo-room-create)
  (mx-check "keymap: K leaves the room at point"
            (lookup-key elneo-room-bar-mode-map (kbd "K"))
            #'elneo-room-bar-leave-at-point)
  (mx-check "keymap: R marks read (telega's rootbuf key)"
            (lookup-key elneo-room-bar-mode-map (kbd "R"))
            #'elneo-room-bar-mark-read-at-point)
  (mx-check "keymap: \\ is the sort-cycle alias"
            (lookup-key elneo-room-bar-mode-map (kbd "\\"))
            #'elneo-room-bar-cycle-sort)
  (mx-check "keymap: / reserved for telega's filter prefix"
            (lookup-key elneo-room-bar-mode-map (kbd "/")) nil)
  (mx-check "keymap: F reserved for folders (spaces eventually)"
            (lookup-key elneo-room-bar-mode-map (kbd "F")) nil)

  ;; --- K leaves the row's room, closing its buffer with the ack ---

  (mx-registry)
  (let (payload said buf)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'elneo-server--call)
               (lambda (_profile ev callback)
                 (setq payload ev)
                 (funcall callback "a" '((@ok . t)))))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq said (apply #'format fmt args)))))
      (with-temp-buffer
        (insert "x  Ops\n")
        (put-text-property 4 8 'elneo-room-key (cons "a" "!room"))
        (goto-char 5)
        ;; the room's open buffer: registered, not a room buffer —
        ;; the ack closes whatever the bar left behind
        (setq buf (generate-new-buffer " mx-bar-keys-open"))
        (puthash (cons "a" "!room") buf elneo-room--buffers)
        (elneo-room-bar-leave-at-point)
        (mx-check "K: leaveRoom on the wire after confirmation"
                  (list (alist-get '@type payload)
                        (alist-get 'room_id payload)
                        said)
                  '("leaveRoom" "!room" "Matrix: left Ops"))
        (mx-check "K: the registered buffer closes with the ack"
                  (buffer-live-p buf) nil)))
    (remhash (cons "a" "!room") elneo-room--buffers))

  ;; --- decline: nothing on the wire ---

  (mx-registry)
  (let (payload)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
              ((symbol-function 'elneo-server--call)
               (lambda (&rest _) (setq payload 'went-out))))
      (with-temp-buffer
        (insert "x  Inv\n")
        (put-text-property 4 8 'elneo-room-key (cons "a" "!invited"))
        (goto-char 5)
        (elneo-room-bar-leave-at-point)
        (mx-check "K: a decline sends nothing" payload nil))))

  ;; --- an invite asks about declining, in those words ---

  (mx-registry)
  (let (prompt)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (p) (setq prompt p) nil)))
      (with-temp-buffer
        (insert "x  Inv\n")
        (put-text-property 4 8 'elneo-room-key (cons "a" "!invited"))
        (goto-char 5)
        (elneo-room-bar-leave-at-point)
        (mx-check "K: an invited room asks about declining"
                  prompt "Decline the invite to Inv? "))))

  ;; --- an ack failure is reported, the buffer stays ---

  (mx-registry)
  (let (said buf gone-payload)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'elneo-server--call)
               (lambda (_profile ev callback)
                 (setq gone-payload ev)
                 (funcall callback "a" '((@error . "boom")))))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq said (apply #'format fmt args)))))
      (with-temp-buffer
        (insert "x  Ops\n")
        (put-text-property 4 8 'elneo-room-key (cons "a" "!room"))
        (goto-char 5)
        (setq buf (generate-new-buffer " mx-bar-keys-stay"))
        (puthash (cons "a" "!room") buf elneo-room--buffers)
        (elneo-room-bar-leave-at-point)
        (mx-check "K: a leave failure names the reason"
                  said "Matrix: leave failed — boom")
        (mx-check "K: a failed leave closes nothing"
                  (buffer-live-p buf) t)))
    (remhash (cons "a" "!room") elneo-room--buffers))

  ;; --- off a row: the same refusal the other at-point keys use ---

  (with-temp-buffer
    (insert "header\n")
    (mx-check "K: no room on this line"
              (condition-case err
                  (progn (elneo-room-bar-leave-at-point) nil)
                (user-error (cadr err)))
              "No room on this line"))

  (message "%d checks: %d ok, %d FAILED" (+ pass fail) pass fail)
  (when (> fail 0) (kill-emacs 1)))