;;; elneo-account.el --- the account page: profile facts and its edits -*- lexical-binding: t; -*-

;;; Commentary:

;; The account/profile page: what the user greps for — one interactive
;; buffer per profile showing this session's identity (user id,
;; homeserver, device) and the homeserver's global profile (display
;; name, avatar), with the edit buttons that already existed as bare
;; M-x commands and the jump into the session/security view
;; (`elneo-session-status').
;;
;; The profile facts come from the homeserver itself (protocol 16's
;; `getProfile' -> `profile' response): both fields may be unset and
;; the page says so rather than falling back to a room-local echo.

;;; Code:

(require 'cl-lib)
(require 'elneo-client)

(declare-function elneo-session-status "elneo-verify" (profile))
(declare-function elneo-avatar-show "elneo-image" (profile mxc))

(defvar elneo-account-page-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'elneo-account-page-refresh)
    map)
  "Keys of an account page buffer; `q' comes from `special-mode'.")

(define-derived-mode elneo-account-page-mode special-mode "Matrix Account"
  "Major mode for an account's profile page.
\\[elneo-account-page-refresh] refetches the profile, \\[quit-window] buries."
  nil)

(defvar-local elneo-account-page--profile nil
  "Buffer-local: the profile this account page reports on.")

;;;###autoload
(defun elneo-account-page-refresh ()
  "Re-fetch this account page's profile and re-render."
  (interactive)
  (if elneo-account-page--profile
      (elneo-account elneo-account-page--profile)
    (user-error "This buffer does not know its profile")))

(defun elneo-account--rooms-line (profile)
  "The rooms-of-PROFILE line for the account page, as text.
Counts from the client's room cache — no extra round trip; a
profile with no rooms yet says so."
  (let ((joined 0) (direct 0))
    (maphash (lambda (_key room)
               (when (equal (plist-get room :profile) profile)
                 (cl-incf joined)
                 (when (plist-get room :direct) (cl-incf direct))))
             elneo--rooms)
    (if (zerop joined)
        "none yet"
      (if (zerop direct)
          (format "%d" joined)
        (format "%d (%d direct)" joined direct)))))

(defun elneo-account--render (profile resp)
  "Render PROFILE's account page from RESP (the `profile' response).
RESP may be nil (the fetch failed or an outdated daemon answered
without it): the page still lists what it knows locally, the
profile facts as \"unknown\"."
  (let* ((buffer (get-buffer-create
                  (format "*Matrix Account: %s*" profile)))
         (session (alist-get profile elneo-server--sessions nil nil #'equal))
         (account (alist-get profile elneo-accounts nil nil #'equal))
         (user-id (or (plist-get session :user-id)
                      (plist-get account :user-id)))
         (display-name (alist-get 'display_name resp nil nil #'equal))
         (avatar (alist-get 'avatar_url resp nil nil #'equal)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'elneo-account-page-mode)
        (elneo-account-page-mode))
      (setq-local elneo-account-page--profile profile)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Matrix account %s\n\n" profile))
        (insert (format "  Profile:       %s\n" profile))
        (insert (format "  User id:       %s\n" (or user-id "unknown")))
        (when-let* ((homeserver (plist-get account :homeserver)))
          (insert (format "  Homeserver:    %s\n" homeserver)))
        (when-let* ((device-id (plist-get session :device-id)))
          (insert (format "  Device:        %s\n" device-id)))
        (insert (format "  Rooms:         %s\n"
                        (elneo-account--rooms-line profile)))
        (insert "\nProfile on the homeserver:\n")
        ;; The facts carry their edit buttons, the room buffer's
        ;; convention: what the button runs needs no room context.
        (insert (format "  Display name:  %s"
                        (or display-name "(not set)")))
        (insert " ")
        (insert-text-button "[name]" 'action
                            (lambda (_)
                              (elneo-account--edit-name profile)))
        (insert "\n")
        (insert "  Avatar:        ")
        ;; The image itself (same rendering as the bar and the room
        ;; overview) beside the mxc string the line used to print:
        ;; the string stays (it identifies the avatar beyond one
        ;; session), and both the image and the string are buttons
        ;; running the full-size avatar view.  An empty mxc (bridges
        ;; leave it in place of dropping the field) reads "(not set)".
        (let ((mxc avatar)
              (show (lambda (_)
                      (require 'elneo-image)
                      (elneo-avatar-show profile avatar))))
          (when-let* ((img (and mxc
                                (not (string-empty-p mxc))
                                (elneo-client--avatar-image
                                 (elneo-client--avatar-file mxc) 4))))
            (insert-text-button
             (propertize (make-string 4 ?\s) 'display img)
             'action show 'help-echo "Show the avatar full-size")
            (insert " "))
          (if (and mxc (not (string-empty-p mxc)))
              (insert-text-button mxc 'action show
                                  'help-echo "Show the avatar full-size")
            (insert "(not set)")))
        (insert " ")
        (insert-text-button "[avatar]" 'action
                            (lambda (_)
                              (elneo-account--edit-avatar profile)))
        (when (and avatar (not (string-empty-p avatar)))
          (insert " ")
          (insert-text-button "[clear]" 'action
                              (lambda (_)
                                (elneo-account--clear-avatar profile))))
        ;; An uncached avatar fetches now; its arrival re-renders the
        ;; page from the same response (no fresh profile round trip).
        (when (and avatar
                   (not (string-empty-p avatar))
                   (display-graphic-p)
                   (not (gethash avatar elneo-client--avatar-cache))
                   (not (gethash avatar elneo-client--avatar-pending)))
          (elneo-client-fetch-avatar
           profile avatar
           (lambda (_p _event)
             ;; Only a page still on screen re-renders: a buried
             ;; buffer is dead for the user, and re-rendering it (and
             ;; popping it) would resurrect the closed view.
             (when-let* ((page (get-buffer
                                (format "*Matrix Account: %s*" profile)))
                         ((get-buffer-window page t)))
               (elneo-account--render profile resp)))))
        (insert "\n")
        (insert "\nSecurity and devices:\n  ")
        (insert-text-button "[session status]"
                            'help-echo "Trust state, key backup, device list"
                            'action
                            (lambda (_)
                              (elneo-session-status profile)))
        (insert "\n"))
      (goto-char (point-min))
      ;; The page exists only when shown: without this, a render into
      ;; a background buffer looks like the command did nothing.  An
      ;; arrival-triggered re-render (an avatar download landing)
      ;; must not steal the window back, so the pop fires only when
      ;; the page is nowhere on screen.
      (unless (get-buffer-window buffer t)
        (pop-to-buffer buffer)))))

(defun elneo-account--edit-name (profile)
  "Button action behind [name]: PROFILE's display name edit.
The set's ack re-opens the page — refetching right after the send
would race the set (detached dispatch): the ordering only the ack
carries."
  (let ((name (read-string "Display name (empty to clear): ")))
    (elneo-set-display-name
     profile (and (not (string-empty-p name)) name)
     (lambda (p event)
       (if (alist-get '@ok event nil nil #'equal)
           (progn (message "Matrix: display name set") (elneo-account p))
         (message "Matrix: display name failed — %s"
                  (elneo-server--error-string event)))))))

(defun elneo-account--edit-avatar (profile)
  "Button action behind [avatar]: PROFILE's avatar edit.
The ack re-opens the page, as [name]'s does."
  (let ((path (read-file-name "Avatar image: " nil nil t)))
    (elneo-set-avatar
     profile path
     (lambda (p event)
       (if (alist-get '@ok event nil nil #'equal)
           (progn (message "Matrix: avatar set") (elneo-account p))
         (message "Matrix: avatar failed — %s"
                  (elneo-server--error-string event)))))))

(defun elneo-account--clear-avatar (profile)
  "Button action behind [clear]: remove PROFILE's avatar.
The ack re-opens the page, as [name]'s and [avatar]'s do."
  (elneo-set-avatar
   profile nil
   (lambda (p event)
     (if (alist-get '@ok event nil nil #'equal)
         (progn (message "Matrix: avatar cleared") (elneo-account p))
       (message "Matrix: avatar failed — %s"
                (elneo-server--error-string event))))))

;;;###autoload
(defun elneo-account (profile)
  "Show PROFILE's account page: identity facts and the homeserver profile.
The page lists this session's user id, homeserver and device, the
room counts, and the global display name and avatar with their
[edit] buttons — the M-x commands (`elneo-account-set-name',
`elneo-account-set-avatar') made visible and reachable.  From here
[session status] opens PROFILE's security and devices view
(`elneo-session-status').  `g' refetches, `q' buries.
Returns the page buffer: the render's own value is the conditional
display, nil when the page is already on screen, and callers must
be able to program against this command."
  (interactive
   (progn (elneo--accounts-load)
          (unless elneo-accounts
            (user-error "No Matrix profiles registered"))
          (list (let ((names (mapcar #'car elneo-accounts)))
                  (if (= (length names) 1)
                      (car names)
                    (completing-read "Profile: " names nil t))))))
  (unless (elneo-server-live-p profile)
    (user-error "Matrix daemon not running for profile %s" profile))
  ;; The page renders on the response; a failed fetch still renders
  ;; the locally-known facts (the user id and homeserver are not
  ;; behind the daemon's profile route).
  (elneo-account-profile
   profile
   (lambda (_p event)
     (if (alist-get '@ok event nil nil #'equal)
         (elneo-account--render profile event)
       (progn (message "Matrix [%s] profile fetch failed — %s"
                       profile (elneo-server--error-string event))
              (elneo-account--render profile nil)))))
  (get-buffer (format "*Matrix Account: %s*" profile)))

;;;###autoload
(defalias 'elneo-profile #'elneo-account
  "Alias of `elneo-account' — the page answers either name.")

(provide 'elneo-account)
;;; elneo-account.el ends here