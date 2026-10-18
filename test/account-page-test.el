;;; account-page-test.el --- the account page: render, buttons, wrapper -*- lexical-binding: t; -*-

;; The `elneo-account' page and its plumbing: the `elneo-account-profile'
;; wrapper's payload, the page's render from a `profile' response (both
;; fields set, either unset, the fetch failing outright), the buttons
;; it carries, and the alias answering as `elneo-profile'.
;; The daemon calls are captured/stubbed at `elneo-server--call'.

;; Run: emacs -Q --batch -L lisp -l test/account-page-test.el

(require 'elneo-room)
(require 'elneo-client)
(require 'elneo-account)
;; The avatar buttons' actions load elneo-image lazily; preloading
;; keeps the later stubbing intact (a first require redefines the
;; function right out of the cl-letf).
(require 'elneo-image)

(defvar mx--calls nil)

(defun mx--capture (profile event callback)
  "A elneo-server--call stub: remember EVENT, ack to CALLBACK."
  (push (cons profile event) mx--calls)
  (funcall callback profile '((@ok . t))))

(defmacro mx--with-capture (&rest body)
  `(let ((mx--calls nil))
     (cl-letf (((symbol-function 'elneo-server--call) #'mx--capture))
       ,@body)
     (nreverse mx--calls)))

(defvar mx--page nil)
(defvar mx--caught)

(defun mx--profile-page (response)
  "Render the page for profile \"mxtest\" with RESPONSE (or nil).
The page's session and accounts records are set up beforehand by
`mx--with-page'."
  (cl-letf (((symbol-function 'elneo-server--call)
             (lambda (_p _cmd cb)
               (funcall cb "mxtest" response)))
            ((symbol-function 'elneo-session-status)
             (lambda (profile) (setq mx--caught (cons 'security profile))))
            ((symbol-function 'elneo-server-live-p) (lambda (_p) t)))
    (elneo-account "mxtest")))

(defmacro mx--with-page (&rest body)
  "Run BODY with one live daemon session and the page's fixture state."
  `(let ((elneo-server--sessions (list (cons "mxtest" '(:user-id "@me:example.org"
                                                        :device-id "ABC"))))
         (elneo-accounts '(("mxtest" . (:homeserver "https://hs.example"))))
         (elneo--rooms (make-hash-table :test 'equal)))
     (puthash (cons "mxtest" "!r1")
              (list :profile "mxtest" :room-id "!r1" :display-name "Ops")
              elneo--rooms)
     (puthash (cons "mxtest" "!r2")
              (list :profile "mxtest" :room-id "!r2" :direct t)
              elneo--rooms)
     (puthash (cons "other" "!r3")
              (list :profile "other" :room-id "!r3")
              elneo--rooms)
     ,@body))

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  ;; --- the wrapper

  (mx-check "wrapper: getProfile payload"
            (cdar (mx--with-capture (elneo-account-profile "p" #'ignore)))
            '((@type . "getProfile")))

  ;; --- the page, full profile response

  (setq mx--page (mx--with-page (mx--profile-page
                                 '((@ok . t)
                                   (user_id . "@me:example.org")
                                   (display_name . "Bernd")
                                   (avatar_url . "mxc://hs/av1")))))
  (let ((text (with-current-buffer mx--page (buffer-string))))
    (mx-check "page: buffer named for the profile" mx--page
              (get-buffer "*Matrix Account: mxtest*"))
    (mx-check "page: the identity facts"
              (and (string-search "Matrix account mxtest" text) t) t)
    (mx-check "page: user id from the session"
              (and (string-search "User id:       @me:example.org" text) t) t)
    (mx-check "page: homeserver from the account record"
              (and (string-search "Homeserver:    https://hs.example" text) t) t)
    (mx-check "page: device from the greeting"
              (and (string-search "Device:        ABC" text) t) t)
    (mx-check "page: room counts (direct separated)"
              (and (string-search "Rooms:         2 (1 direct)" text) t) t)
    (mx-check "page: the display name fact and button"
              (and (string-search "Display name:  Bernd [name]" text) t) t)
    (mx-check "page: the avatar fact, [avatar] with a [clear]"
              (and (string-search "Avatar:        mxc://hs/av1 [avatar] [clear]"
                                  text)
                   t)
              t))

  ;; --- a sparse profile: fields stay off the wire, the page says so

  (setq mx--page (mx--with-page (mx--profile-page
                                 '((@ok . t) (user_id . "@me:example.org")))))
  (let ((text (with-current-buffer mx--page (buffer-string))))
    (mx-check "page: an unset profile is said, not echoed"
              (and (string-search "Display name:  (not set)" text) t) t)
    (mx-check "page: an unset avatar has no [clear]"
              (string-search "[clear]" text) nil))

  ;; --- a failed fetch still renders the local facts

  (setq mx--page (mx--with-page (mx--profile-page '((@ok . nil) (error . "x")))))
  (let ((text (with-current-buffer mx--page (buffer-string))))
    (mx-check "page: a failed fetch keeps the local facts"
              (and (string-search "User id:       @me:example.org" text) t) t)
    (mx-check "page: a failed fetch shows nothing profile-side"
              (and (string-search "Profile on the homeserver:" text) t) t))

  ;; --- the page exists only when shown ---

  ;; Live finding #1: a render into a background buffer reads as "the
  ;; command did nothing"; the display is part of the command.  The
  ;; page buffer is killed first — an earlier section may have left it
  ;; (shown, and thus legitimately not re-popped) in this batch's
  ;; single window.
  (let (shown)
    (when (get-buffer "*Matrix Account: mxtest*")
      (kill-buffer "*Matrix Account: mxtest*"))
    (setq mx--page
          (mx--with-page
           (cl-letf (((symbol-function 'pop-to-buffer)
                      (lambda (b &optional _action) (setq shown b))))
             (mx--profile-page '((@ok . t) (user_id . "@me:example.org"))))))
    (mx-check "page: the render displays the page (finding #1)"
              shown mx--page))

  ;; --- the avatar picture and its arrival ---

  ;; The avatar line shows the image cell beside the mxc string when
  ;; this Emacs displays images; the picture renders in the buffer's
  ;; text (insert, properties kept), never through princ.
  (let ((img-shown nil) (fetched nil) (re-rendered nil)
        (av-cache (make-hash-table :test 'equal))
        (av-pending (make-hash-table :test 'equal)))
    (puthash "mxc://hs/av1" "/cache/av1.png" av-cache)
    (let ((elneo-client--avatar-cache av-cache)
          (elneo-client--avatar-pending av-pending))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                ((symbol-function 'default-font-height) (lambda () 17))
                ((symbol-function 'default-font-width) (lambda () 8))
                ((symbol-function 'create-image)
                 (lambda (_file _t _d &rest _) 'fake-img)))
        (setq mx--page (mx--with-page
                        (mx--profile-page
                         '((@ok . t) (user_id . "@me:example.org")
                           (avatar_url . "mxc://hs/av1")))))
        (with-temp-buffer
          (insert (with-current-buffer mx--page (buffer-string)))
          (goto-char (point-max))
          (search-backward "mxc://hs/av1")
          (backward-char 5)  ; the separator space + the 4-col cell
          (setq img-shown (get-text-property (point) 'display))))
      (mx-check "page: the avatar renders as an image (finding #4, account)"
                img-shown 'fake-img)
      ;; An uncached avatar fetches, and its arrival re-renders the
      ;; page in place.
      (let* ((arrived nil)
             ;; The fetch's arrival callback fires while the page's
             ;; original render is still on the stack (`g' and the
             ;; buttons re-render too): the callback must not pop the
             ;; page over the user's current view, so when the page is
             ;; displayed the render skips the pop.  A window-less
             ;; batch would always report "not displayed"; give the
             ;; render a pretend display and catch the pop attempt
             ;; before it happens.
             (pop-attempted nil))
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                  ((symbol-function 'default-font-height) (lambda () 17))
                  ((symbol-function 'default-font-width) (lambda () 8))
                  (elneo-client--avatar-cache (make-hash-table :test 'equal))
                  ((symbol-function 'get-buffer-window) (lambda (&optional _b _f) t))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (_b &optional _a) (setq pop-attempted t)))
                  ((symbol-function 'elneo-client-fetch-avatar)
                   (lambda (_p _m cb)
                     (setq fetched t)
                     (puthash "mxc://hs/mine" "/cache/mine.png"
                              elneo-client--avatar-cache)
                     (funcall cb "mxtest" '((@ok . t) (path . "/cache/mine.png")))))
                  ((symbol-function 'create-image)
                   (lambda (_file _t _d &rest _) (setq arrived t) 'fake-img)))
          (setq mx--page (mx--with-page
                          (mx--profile-page
                           '((@ok . t) (user_id . "@me:example.org")
                             (avatar_url . "mxc://hs/mine"))))))
        (mx-check "page: an uncached avatar fetches" fetched t)
        (mx-check "page: the arrival re-render shows the image" arrived t)
        (mx-check "page: the arrival re-render does not steal the window"
                  pop-attempted nil)
        (mx-check "page: the arrival re-render leaves the page intact"
                  (buffer-live-p mx--page) t)))
    ;; Batch (this run's plain Emacs): the image cell is absent, the
    ;; mxc string and the buttons carry the line.
    (setq mx--page (mx--with-page (mx--profile-page
                                   '((@ok . t) (user_id . "@me:example.org")
                                     (avatar_url . "mxc://hs/av1")))))
    (mx-check "page: a non-displaying Emacs keeps the mxc string"
              (with-current-buffer mx--page
                (and (string-search "Avatar:        mxc://hs/av1"
                                    (buffer-string))
                     t))
              t))

  ;; The avatar mxc string is a button into the full-size avatar
  ;; view: pushed the way a click pushes it, with the view stubbed.
  (setq mx--caught nil)
  (mx--with-page
   (cl-letf (((symbol-function 'elneo-server--call)
              (lambda (_p _cmd cb)
                (funcall cb "mxtest" '((@ok . t) (user_id . "@me:example.org")
                                       (avatar_url . "mxc://hs/av1")))))
             ((symbol-function 'elneo-avatar-show)
              (lambda (profile mxc)
                (setq mx--caught (cons 'avatar (cons profile mxc)))))
             ((symbol-function 'elneo-server-live-p) (lambda (_p) t)))
     (with-current-buffer (elneo-account "mxtest")
       (goto-char (point-min))
       (when (re-search-forward "mxc://hs/av1" nil t)
         (funcall (plist-get (text-properties-at (match-beginning 0))
                             'action)
                  nil)))))
  (mx-check "page: the avatar mxc opens the full-size view"
            mx--caught '(avatar "mxtest" . "mxc://hs/av1"))

  ;; --- the security jump

  ;; The button is pushed the way a click pushes it: its action runs
  ;; inside the same letf the render happened in (the stub survives
  ;; the click only there).
  (setq mx--caught nil)
  (mx--with-page
   (cl-letf (((symbol-function 'elneo-server--call)
              (lambda (_p _cmd cb)
                (funcall cb "mxtest" '((@ok . t) (user_id . "@me:example.org")))))
             ((symbol-function 'elneo-session-status)
              (lambda (profile) (setq mx--caught (cons 'security profile))))
             ((symbol-function 'elneo-server-live-p) (lambda (_p) t)))
     (with-current-buffer (elneo-account "mxtest")
       (goto-char (point-min))
       (when (re-search-forward "\\[session status\\]" nil t)
         (funcall (plist-get (text-properties-at (match-beginning 0))
                             'action)
                  nil)))))
  (mx-check "page: [session status] opens the security view"
            mx--caught '(security . "mxtest"))

  ;; --- the alias answers, as another name for the same command

  (mx-check "page: elneo-profile is elneo-account"
            (eq (indirect-function 'elneo-profile) (indirect-function 'elneo-account))
            t)

  ;; --- the mode's keys

  (with-current-buffer mx--page
    (unwind-protect
        (let (refetched)
          (cl-letf (((symbol-function 'elneo-server--call)
                     (lambda (_p _cmd cb)
                       (funcall cb "mxtest" '((@ok . t) (user_id . "@me:example.org")))))
                    ((symbol-function 'elneo-session-status)
                     (lambda (_profile) (setq refetched t))))
            (mx-check "page: g is the refresh binding"
                      (eq (key-binding (kbd "g")) #'elneo-account-page-refresh)
                      t)
            (mx-check "page: q reaches special-mode bury"
                      (key-binding (kbd "q"))
                      'quit-window)))
      (kill-buffer mx--page)
      (setq mx--page nil)))

  (message "%d ok, %d failed" pass fail)
  (when (> fail 0) (kill-emacs 1)))

;;; account-page-test.el ends here