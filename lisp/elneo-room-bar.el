;;; elneo-room-bar.el --- Fixed side-window bar of all Matrix rooms -*- lexical-binding: t -*-

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;;; Commentary:

;; The fixed room bar: one buffer pinned as a frame side window, spanning
;; the frame height, listing rooms from all online accounts.
;;
;; The side-window machinery makes the bar survive everything users do in
;; the rest of the frame: `delete-other-windows', arbitrary splits, and
;; other window layouts never remove or displace it (see the plan:
;; the `window-side' window parameter is what protects it).
;;
;; Controls row on top: account filter buttons, sort selector, search,
;; DM filter; direct-message rows carry the `elneo-room-bar-dm-glyph'.
;; Rooms render mixed by default (account tag prefix) or grouped by
;; account.  Per-room lines update incrementally in place; a full
;; re-render happens when sorting/grouping/filtering changes, and on
;; room updates when `elneo-room-bar-live-sort' is on.
;;
;; Two shapes, one shared buffer: the wide bar above, and a compact
;; rail (avatar initial plus unread badge, one row per room) for
;; narrow frames and touch — `w', the « and » handles toggle between
;; them (`elneo-room-bar-resting-state' picks where a fresh bar
;; starts).  Controls and section headers are wide-bar only; rows
;; and tap-to-open work identically in both.

;;; Code:

(require 'cl-lib)
(require 'elneo-client)
(require 'elneo-anon)

(declare-function elneo-transient-dispatch "elneo-transient" ())
;; elneo-session-status turns the third controls row into the status
;; view; elneo-verify loads only when the session is in question.
(declare-function elneo-session-status "elneo-verify" (profile))

(defgroup elneo-ui nil
  "Matrix client UI."
  :group 'elneo
  :prefix "elneo-room-bar-")

(defcustom elneo-room-bar-side 'left
  "Which side of the frame the room bar occupies."
  :type '(choice (const :tag "Left" left)
                 (const :tag "Right" right)
                 (const :tag "Top" top)
                 (const :tag "Bottom" bottom))
  :group 'elneo-ui)

(defcustom elneo-room-bar-width 36
  "Width (columns) of the room bar when on the left or right."
  :type 'integer
  :group 'elneo-ui)

(defcustom elneo-room-bar-height 12
  "Height (lines) of the room bar when on the top or bottom."
  :type 'integer
  :group 'elneo-ui)

(defcustom elneo-room-bar-rail-width 4
  "Width (columns) of the room bar in its collapsed rail state.
The rail shows one row per room — avatar initial plus unread badge
— with no names, previews or controls; `w' in the bar (or the «
handle) toggles between it and the full bar."
  :type 'integer
  :group 'elneo-ui)

(defcustom elneo-room-bar-resting-state 'auto
  "The shape a freshly created room bar starts in.
`auto' derives it from the frame: the rail while the wide bar
would take half the frame's columns or more (a phone-sized
frame), the wide bar when there is room to spare.  `rail' and
`wide' pin it — the rail on a desktop pairs well with a generous
`elneo-room-bar-width'.  Toggling (`w' in the bar) overrides this
for the session; the bar buffer, not the setting, holds the
current state."
  :type '(choice (const :tag "Rail on narrow frames, wide otherwise" auto)
                 (const :tag "Always start wide" wide)
                 (const :tag "Always start as the rail" rail))
  :group 'elneo-ui)

(defvar elneo-room-bar-sort 'activity
  "Current sort: `activity' (newest first), `alpha', or `unread'.")

(defvar elneo-room-bar-grouped nil
  "Non-nil means group rooms into per-account sections.")

(defvar elneo-room-bar-account-filter nil
  "Account (profile name) the bar is filtered to, or nil for all.")

(defvar elneo-room-bar-dm-filter nil
  "Direct-message filter of the room bar: nil shows everything,
`dm' only the direct-message rooms, `rooms' only the rest (`d'
cycles).  Composes with the account and search filters.")

(defcustom elneo-room-bar-dm-glyph "👤"
  "Marker shown on a room row when the room is a direct message.
An empty string hides the badge.  DMs are usually recognizable by
their avatar (the person's picture) alone; the badge covers the
case of avatars off, or a person with no avatar set."
  :type 'string
  :group 'elneo-ui)

(defvar elneo-room-bar-search ""
  "Case-insensitive substring the room list is filtered by, or \"\".")

(defvar elneo-room-bar-preview-style 'below
  "How a room's last-message preview renders.
`below' puts it on a second line in `elneo-room-bar-preview'
style, `inline' on the room's row, `none' hides it.")

(defcustom elneo-room-bar-avatars t
  "Non-nil means each room row starts with an avatar column.
The room's avatar image, fetched through the thumbnail path and
disk-cached; rooms without an avatar (and freshly seen rooms while
theirs downloads) fall back to the room's initial in a per-room
color.  `v' in the bar toggles this for the session."
  :type 'boolean
  :group 'elneo-ui)

(defcustom elneo-room-bar-live-sort t
  "Non-nil means room updates re-sort the bar as activity arrives.
The activity sort otherwise goes stale: a room with fresh messages
keeps its old place until something re-renders the bar.  Live
re-sorting rides the coalesced idle re-render (a burst of updates
collapses into one) and the re-render keeps the visible view
anchored to the rows it shows, so heavy traffic does not flicker
the list — but if you prefer a fully stable order on busy days,
set this to nil: the order then holds until you act on the bar
(`S', `g', a filter, the options menu).  `l' in the bar and in the
options menu toggles this for the session."
  :type 'boolean
  :group 'elneo-ui)

(defcustom elneo-room-bar-click-action 'open
  "What a mouse-1 click on a room row in the bar does.
`open' opens the room in the main window (like RET), `double'
opens on a double click while a single click only moves point,
`point' never opens — clicks just move point, open with RET.
A click always moves point to the row it landed on.  The controls
rows carry no room, so a click there only ever moves point (their
buttons answer to mouse-2 as before)."
  :type '(choice (const :tag "Click opens the room" open)
                 (const :tag "Double-click opens the room" double)
                 (const :tag "Click only moves point" point))
  :group 'elneo-ui)

(defcustom elneo-room-bar-muted-glyph "🔕"
  "Marker glyph for rooms muted via notification settings.
Set to \"\" to hide the marker."
  :type 'string
  :group 'elneo-ui)

(defcustom elneo-room-bar-mentions-glyph "🔔"
  "Marker glyph for rooms set to mentions-and-keywords-only — a dim
bell: the room still pings on mentions.  Set to \"\" to hide."
  :type 'string
  :group 'elneo-ui)

(defcustom elneo-room-invite-display 'section
  "How a pending invite shows in the room bar.
An invite has no timeline yet: its row is dimmed and clicking it
prompts join / decline / ignore rather than opening a room.
`section' lists the invites under an \"Invites\" header at the top
of the bar, above the ordinary rooms; `inline' keeps each invite
in its display-order spot, dimmed, with
`elneo-room-bar-invite-glyph' in front of the name; `hide'
leaves them out of the bar (invites remain accept-declined only
via a re-fetch or a restart — and the Emacs-side completion for
room names still finds them)."
  :type '(choice (const :tag "Own Invites section" section)
                 (const :tag "Inline in the list, dimmed, with a glyph" inline)
                 (const :tag "Do not display" hide))
  :group 'elneo-ui)

(defcustom elneo-room-bar-invite-glyph "✉ "
  "Marker glyph in front of an invited room's name (in `inline'
mode; under the Invites section header the rows are already
unambiguously invites).  Set to \"\" to hide it."
  :type 'string
  :group 'elneo-ui)

(defface elneo-room-bar-invite
  '((t :inherit shadow :slant italic))
  "Face for pending-invite rows in the room bar."
  :group 'elneo-ui)

(defface elneo-room-bar-space
  '((t :inherit shadow))
  "Style for the space glyph on a room row (see
`elneo-room-bar-space-glyph')."
  :group 'elneo-ui)

(defcustom elneo-room-bar-space-glyph "❒ "
  "Marker in front of a space's room row.  A space is a room —
it has its own timeline (the bar previews it like any other
room) — and without a marker nothing distinguishes it.  Set to
\"\" to hide it."
  :type 'string
  :group 'elneo-ui)

(defface elneo-room-bar-upgrade
  '((t :inherit shadow))
  "Style for the upgrade glyph on a room row (see
`elneo-room-bar-upgrade-glyph')."
  :group 'elneo-ui)

(defcustom elneo-room-bar-upgrade-glyph "⬆ "
  "Marker in front of a room row that was upgraded away: the room
is dead — its tombstone names a replacement — and the overview's
\"Upgraded to\" line carries the `[open]' to the successor.  Nothing
follows the glyph by itself (see the comment on
`elneo-room--upgrade-prefix').  Set to \"\" to hide it."
  :type 'string
  :group 'elneo-ui)

(defface elneo-room-bar-header
  '((t :inherit mode-line :weight bold))
  "Face for the room bar's control row."
  :group 'elneo-ui)

(defface elneo-room-bar-section
  '((t :weight bold :inherit shadow))
  "Face for per-account section headers in grouped view.
Folds open with ▾, folded sections carry ▸ plus a room/unread summary."
  :group 'elneo-ui)

(defface elneo-room-bar-room
  '((t))
  "Face for room rows in the room bar."
  :group 'elneo-ui)

(defface elneo-room-bar-unread
  '((t :weight bold))
  "Face for rooms with unread messages."
  :group 'elneo-ui)

(defface elneo-room-bar-highlight
  '((t :weight bold :foreground "red"))
  "Face for rooms with unread highlights (mentions)."
  :group 'elneo-ui)

(defface elneo-room-bar-preview
  '((t :inherit shadow :slant italic :height 0.9))
  "Face for the second-line message preview."
  :group 'elneo-ui)

(defface elneo-room-bar-avatar
  '((t :weight bold))
  "Base face for the avatar placeholder glyph; the per-room color
face is combined with it at render time."
  :group 'elneo-ui)

(defface elneo-room-bar-muted
  '((t :inherit shadow :weight bold))
  "Face for the muted-room marker glyph."
  :group 'elneo-ui)

(defface elneo-room-bar-mentions
  '((t :inherit shadow))
  "Face for the mentions-only-room marker glyph."
  :group 'elneo-ui)

(defface elneo-room-bar-dm
  '((t :inherit shadow))
  "Face for the direct-message marker glyph on a room row."
  :group 'elneo-ui)

(defface elneo-room-bar-unverified
  '((t :inherit error))
  "Face for a session's verify row in the bar's third controls row.
The row appears only when the account has cross-signing enabled
but this session does not yet trust it — the one case where a
verification workflow should be nagged into."
  :group 'elneo-ui)

(defface elneo-room-bar-offline
  '((t :inherit error))
  "Face for a daemon that cannot reach its homeserver: the ✗ daemon
status glyph, the offline/error chips and the mode line's ⚠N suffix.
Both meanings the user chose to surface as broken: the daemon
process is gone (``offline''), or it is alive but cannot sync
(``error'')."
  :group 'elneo-ui)

(defvar elneo-room-bar--markers nil
  "Hash table mapping (PROFILE . ROOM-ID) to a line-start marker.")

(defvar elneo-room-bar--buffer nil
  "The room bar buffer, if it exists.")

(defvar elneo-room-bar--full-pending nil
  "Non-nil while a full re-render is scheduled on an idle timer.")

(defvar elneo-room-bar--full-timer nil
  "Timer coalescing bursts of full re-renders (e.g. at startup seed).")

;; Buffer-local: the bar buffer is shared by every frame's bar
;; window, so the shape is shared too — toggling re-displays all of
;; them at the new width.  nil (a bar predating this variable) is the
;; wide bar.
(defvar-local elneo-room-bar--state nil
  "Current bar shape on the bar buffer: `rail' or `wide' (nil: wide).")

;; Assigned with setq (defvar declared above the block): a plain
;; `defvar' with an initial value keeps the OLD keymap object when the
;; file is reloaded, leaving existing bar buffers with stale bindings.
(defvar elneo-room-bar-mode-map nil
  "Keymap for the room bar; rebuilt on reload.")

(setq elneo-room-bar-mode-map
      (let ((map (make-sparse-keymap)))
        (define-key map "\r" #'elneo-room-bar-open-at-point)
        (define-key map (kbd "S") #'elneo-room-bar-cycle-sort)
        (define-key map (kbd "a") #'elneo-room-bar-cycle-account)
        (define-key map (kbd "d") #'elneo-room-bar-cycle-dm)
        (define-key map (kbd "s") #'elneo-room-bar-set-search)
        (define-key map (kbd "g") #'elneo-room-bar-refresh-full)
        (define-key map (kbd "G") #'elneo-room-bar-toggle-grouped)
        (define-key map (kbd "p") #'elneo-room-bar-cycle-preview)
        (define-key map (kbd "v") #'elneo-room-bar-toggle-avatars)
        (define-key map (kbd "l") #'elneo-room-bar-toggle-live-sort)
        (define-key map (kbd "w") #'elneo-room-bar-toggle-state)
        (define-key map (kbd "k") #'elneo-room-bar-cycle-click-action)
        (define-key map (kbd "i") #'elneo-room-bar-settings-at-point)
        (define-key map (kbd "b") #'elneo-room-bar-browse-space-at-point)
        (define-key map (kbd "m") #'elneo-room-bar-options)
        (define-key map (kbd "u") #'elneo-room-bar-next-unread)
        (define-key map (kbd "@") #'elneo-room-bar-next-highlight)
        (define-key map (kbd "r") #'elneo-room-bar-mark-read-at-point)
        ;; telega's rootbuf keys: J/N/+ join and create rooms (both
        ;; commands prompt for profile and target themselves, so they run
        ;; unchanged from the bar); R marks read (the room buffer's `r');
        ;; \ is telega's sort prefix, aliased to our sort cycle.
        (define-key map (kbd "J") #'elneo-join-matrix-to)
        (define-key map (kbd "N") #'elneo-room-create)
        (define-key map (kbd "+") #'elneo-room-create)
        (define-key map (kbd "K") #'elneo-room-bar-leave-at-point)
        (define-key map (kbd "R") #'elneo-room-bar-mark-read-at-point)
        (define-key map (kbd "\\") #'elneo-room-bar-cycle-sort)
        ;; `/` stays reserved for telega's filter prefix (unimplemented;
        ;; ROADMAP re-scoped that to bar narrowing); `F` stays reserved for
        ;; folders (spaces eventually).
        (define-key map (kbd "<mouse-1>") #'elneo-room-bar--mouse-1)
        (define-key map (kbd "q") #'bury-buffer)
        map))

(define-derived-mode elneo-room-bar-mode special-mode "Matrix Rooms"
  "Major mode for the fixed room bar.
The buffer is a live view of all rooms across all accounts; it
updates itself from daemon events.  \\[elneo-room-bar-open-at-point] opens
the room at point."
  (setq-local truncate-lines t)
  (setq-local cursor-in-non-selected-windows nil)
  ;; Keep spell-checking out of the room overview: opt out of plain
  ;; global-flyspell, and of any global `after-change-major-mode-hook'
  ;; that force-enables it — honour the user's own blacklist if they
  ;; have one (e.g. `aard/enable-flyspell-unless-blacklisted').
  (when (fboundp 'flyspell-mode) (flyspell-mode -1))
  (when (boundp 'aard/flyspell-major-mode-blacklist)
    (cl-pushnew 'elneo-room-bar-mode aard/flyspell-major-mode-blacklist))
  (setq buffer-read-only t))

;;; Display

(defun elneo-room-bar--window-in-frame (&optional frame)
  "The room bar window on FRAME (the selected frame by default), or nil.
Live windows of FRAME only: a bar parked in another eyebrowse
workspace is not found here."
  (and (buffer-live-p elneo-room-bar--buffer)
       (cl-find-if (lambda (w) (eq (window-buffer w) elneo-room-bar--buffer))
                   (window-list (or frame (selected-frame)) 'no-minibuf))))

(defun elneo-room-bar--width ()
  "Columns for a newly displayed bar window, per the bar buffer's state.
The rail is deliberately narrow; everything else is the full
`elneo-room-bar-width' (nil state — a bar without one yet — is the
wide bar)."
  (if (and (buffer-live-p elneo-room-bar--buffer)
           (with-current-buffer elneo-room-bar--buffer
             (eq elneo-room-bar--state 'rail)))
      elneo-room-bar-rail-width
    elneo-room-bar-width))

(defun elneo-room-bar--resting-state ()
  "The shape a freshly created bar starts in (see
`elneo-room-bar-resting-state').  `auto' looks at the frame: the
rail while the wide bar would claim half its columns or more."
  (pcase elneo-room-bar-resting-state
    ('rail 'rail)
    ('wide 'wide)
    (_ (if (< (frame-width) (* 2 elneo-room-bar-width)) 'rail 'wide))))

(defun elneo-room-bar--display-buffer (&optional frame)
  "Display the room bar as a side window of FRAME (the selected by default).
The `window-side' parameter plus a dedicated window and
`no-delete-other-windows' make the bar permanent: user splits and
`delete-other-windows' in the main area never touch it.  Each
frame that calls this gets its own bar window; the displayed
buffer is shared.  Note that when FRAME already has a side window
on the chosen side (for example a user-pinned non-bar one),
`display-buffer-in-side-window' reuses that window."
  (let* ((buffer elneo-room-bar--buffer)
         (specs `((side . ,elneo-room-bar-side)
                  (window-parameters . ((no-delete-other-windows . t)))))
         (size-spec (if (memq elneo-room-bar-side '(top bottom))
                        `(window-height . ,elneo-room-bar-height)
                      `(window-width . ,(elneo-room-bar--width))))
         (frame (if (frame-live-p frame) frame (selected-frame))))
    (or (elneo-room-bar--window-in-frame frame)
        (let ((window (if (eq frame (selected-frame))
                          (display-buffer-in-side-window
                           buffer (cons size-spec specs))
                        (with-selected-frame frame
                          (display-buffer-in-side-window
                           buffer (cons size-spec specs))))))
          (set-window-dedicated-p window t)
          (set-window-prev-buffers window nil)
          window))))

(defun elneo-room-bar-visible-p ()
  "Non-nil when the room bar window is displayed on screen.
Only live windows count: with a window-configuration switcher
\(eyebrowse and friends) a bar parked in another perspective is
not visible here."
  (and (buffer-live-p elneo-room-bar--buffer)
       (get-buffer-window elneo-room-bar--buffer 'visible)))

(defun elneo-room-bar--window-state-shows-bar-p (state)
  "Non-nil when a saved window STATE (an eyebrowse config) shows the bar.
Scans the `window-state-get' tree for a leaf displaying the bar
buffer; eyebrowse stores whole frames this way, one entry per
workspace.  Recurses over cars and cdrs — the state is full of
dotted pairs (`min-height . 4`), which list-walkers like `cl-some'
trip over."
  (when (buffer-live-p elneo-room-bar--buffer)
    (let ((name (buffer-name elneo-room-bar--buffer)))
      (cl-labels ((scan (node)
                    (and (consp node)
                         (if (eq (car node) 'buffer)
                             (equal (cadr node) name)
                           (or (scan (car node)) (scan (cdr node)))))))
        (scan state)))))

(defun elneo-room-bar-find-display ()
  "Return (FRAME . SLOT) of the display showing the room bar.
FRAME's current window configuration shows the bar and SLOT is nil,
or FRAME's eyebrowse workspace SLOT has one parked (a bar hidden
behind a workspace switch is not otherwise findable).  Visible
frames are searched first, the selected frame winning ties; nil
when no live frame or workspace shows the bar.  Without eyebrowse
\(or with the bar nowhere at all) only the first kind is found."
  (when (buffer-live-p elneo-room-bar--buffer)
    (let ((window (get-buffer-window elneo-room-bar--buffer 'visible)))
      (or (and window (cons (window-frame window) nil))
          ;; Parked behind a workspace switch: scan eyebrowse's saved
          ;; window states, visible frames, the selected one first.
          (and (fboundp 'eyebrowse--get)
               (let ((frames (cons (selected-frame)
                                   (remq (selected-frame)
                                         (visible-frame-list)))))
                 (cl-loop for frame in frames
                          when (frame-live-p frame)
                          for configs = (eyebrowse--get 'window-configs frame)
                          for slot = (cl-loop for entry in configs
                                              when (elneo-room-bar--window-state-shows-bar-p
                                                    (nth 1 entry))
                                              return (car entry))
                          when slot return (cons frame slot))))))))


;;;###autoload
(defun elneo-room-bar-show ()
  "Show (or raise) the fixed room bar."
  (interactive)
  (elneo-room-bar--ensure)
  (elneo-room-bar--display-buffer))

(defun elneo-room-bar-toggle-visibility ()
  "Hide the room bar when it is on screen, show it otherwise.
Hiding only deletes the side window: the bar buffer keeps its rooms
and stays up to date, so showing it again is instant."
  (interactive)
  (elneo-room-bar--ensure)
  (let ((window (elneo-room-bar--window-in-frame)))
    (if window
        (progn
          (delete-window window)
          (message "Matrix: room bar hidden"))
      (elneo-room-bar--display-buffer)
      (message "Matrix: room bar shown"))))

(defun elneo-room-bar-toggle-state (&optional state)
  "Toggle the room bar between the wide bar and the compact rail.
With STATE (`rail' or `wide'), switch to that shape instead of
toggling.  The shape lives on the shared bar buffer, so every
frame showing the bar is re-displayed at the new width — the width
sits on the window, so a plain resize would not do.  A bar parked
in a non-visible window configuration (eyebrowse) keeps its old
window; the next `elneo-room-bar-show' on its frame fixes it."
  (interactive)
  (elneo-room-bar--ensure)
  (with-current-buffer elneo-room-bar--buffer
    (setq elneo-room-bar--state
          (or state (if (eq elneo-room-bar--state 'rail) 'wide 'rail))))
  (dolist (frame (visible-frame-list))
    (let ((window (elneo-room-bar--window-in-frame frame)))
      (when window
        (delete-window window)
        (elneo-room-bar--display-buffer frame))))
  (elneo-room-bar-refresh-full)
  (message "Matrix: room bar %s"
           (if (with-current-buffer elneo-room-bar--buffer
                 (eq elneo-room-bar--state 'rail))
               "folded to the rail" "expanded")))

(defun elneo-room-bar--ensure ()
  "Create the bar buffer, hooks and state if needed."
  (unless (buffer-live-p elneo-room-bar--buffer)
    (setq elneo-room-bar--buffer (get-buffer-create "*Matrix Rooms*"))
    (with-current-buffer elneo-room-bar--buffer
      (elneo-room-bar-mode)
      ;; The shape a fresh bar starts in — the resting state, once,
      ;; at creation (later toggles are session state on this buffer).
      (setq elneo-room-bar--state (elneo-room-bar--resting-state))
      ;; Buffer-local, and on the bar buffer: a bare add-hook would
      ;; stamp the kill hook on whichever buffer --ensure ran with.
      (add-hook 'kill-buffer-hook #'elneo-room-bar--on-kill nil t))
    (setq elneo-room-bar--markers (make-hash-table :test 'equal))
    (add-hook 'elneo-room-update-hook #'elneo-room-bar--on-room-update)
    (add-hook 'elneo-session-trust-hook #'elneo-room-bar--on-session-state)
    (add-hook 'elneo-session-sync-hook #'elneo-room-bar--on-session-state)
    (elneo-room-bar-refresh-full)))

(defun elneo-room-bar-ensure-on-frame (&optional frame)
  "Ensure the bar buffer and hooks exist, then show on FRAME.
The router's one-stop entry: unlike `elneo-room-bar-show' this
initializes the bar state if it was never set up this session."
  (elneo-room-bar--ensure)
  (elneo-room-bar--display-buffer frame))

(defun elneo-room-bar--on-kill ()
  "Reset module state when the bar buffer is killed.
A pending coalesced full render dies with it: its idle callback
would otherwise run `elneo-room-bar--flush-full' -> `refresh-full'
-> `--ensure' and resurrect the buffer with no user action.  The
global hooks stay registered on purpose — the bar comes back on
the next real room or session event, which is the persistence
design doing its job; the leftover timer is not."
  (when elneo-room-bar--full-timer
    (cancel-timer elneo-room-bar--full-timer))
  (setq elneo-room-bar--buffer nil
        elneo-room-bar--markers nil
        elneo-room-bar--full-timer nil
        elneo-room-bar--full-pending nil))

;;; Room filtering / sorting

(defun elneo-room-bar--invite-p (room)
  "Non-nil when ROOM's record says this side is merely invited.
The daemon labels every summary \"joined\" or \"invited\" (room
state); old records without the field are ordinary rooms."
  (equal (plist-get room :room-state) "invited"))

(defun elneo-room-bar--filtered-rooms ()
  "All room records the bar's filters admit, in display order.
The account, DM (`elneo-room-bar-dm-filter') and search filters
apply; invites are kept (the invite-display policy filters them
where it splits the list)."
  (let ((rooms
         (cl-remove-if
          (lambda (room)
            (or (plist-get room :removed)
                (and elneo-room-bar-account-filter
                     (not (equal (plist-get room :profile)
                                 elneo-room-bar-account-filter)))
                (and elneo-room-bar-dm-filter
                     (not (eq (if (plist-get room :direct) 'dm 'rooms)
                              elneo-room-bar-dm-filter)))
                (and (> (length elneo-room-bar-search) 0)
                     (not (string-match-p
                           (regexp-quote elneo-room-bar-search)
                           (concat (plist-get room :display-name) " "
                                   (or (plist-get room :alias) "") " "
                                   (or (plist-get room :topic) "")))))))
          (elneo-rooms-all))))
    (cond
     ((eq elneo-room-bar-sort 'alpha)
      (sort rooms
            (lambda (a b)
              (string-lessp (plist-get a :display-name)
                            (plist-get b :display-name)))))
     ((eq elneo-room-bar-sort 'unread)
      (sort rooms
            (lambda (a b)
              (> (plist-get a :unread) (plist-get b :unread)))))
     (t
      (sort rooms
            (lambda (a b)
              (> (or (plist-get a :last-activity) 0)
                 (or (plist-get b :last-activity) 0))))))))

(defun elneo-room-bar--visible-rooms ()
  "Room records the bar currently shows, in display order.
Pending invites render under their own section (`section' mode)
or not at all (`hide'), so they stay out of this list — `inline'
mode keeps them in their sorted spot."
  (cl-remove-if
   (lambda (room)
     (and (elneo-room-bar--invite-p room)
          (not (eq elneo-room-invite-display 'inline))))
   (elneo-room-bar--filtered-rooms)))

(defun elneo-room-bar--invites ()
  "Pending invite records the bar's Invites section shows, in
display order (nil unless `elneo-room-invite-display' is
`section')."
  (and (eq elneo-room-invite-display 'section)
       (cl-remove-if-not #'elneo-room-bar--invite-p
                         (elneo-room-bar--filtered-rooms))))

(defun elneo-room-bar--account-list ()
  "Profiles with at least one known room, in registry order."
  (delete-dups
   (mapcar (lambda (room) (plist-get room :profile))
           (elneo-rooms-all))))

;;; Row rendering

(defcustom elneo-room-bar-account-display 'dot
  "How room rows show their account: `dot' (colored dot, one color
per account), `tag' (text prefix), or `none'."
  :type '(choice (const :tag "Colored dot" dot)
                 (const :tag "Account tag" tag)
                 (const :tag "Nothing" none))
  :group 'elneo-ui)

(defcustom elneo-room-bar-account-colors
  '("#e06c75" "#98c379" "#61afef" "#c678dd" "#e5c07b" "#56b6c2" "#d19a66" "#4dbfaf")
  "Colors used for the per-account dots.
Accounts are mapped to colors stably by name hash; two accounts may
rarely share a color."
  :type '(repeat color)
  :group 'elneo-ui)

(defcustom elneo-room-bar-name-width 22
  "Maximum characters of a room name shown on a row."
  :type 'integer
  :group 'elneo-ui)

(defcustom elneo-room-bar-preview-length 30
  "Maximum characters of a room's last message shown on a row."
  :type 'integer
  :group 'elneo-ui)

(defvar elneo-room-bar--dot-faces nil
  "Faces for account dots, one per entry of `elneo-room-bar-account-colors'.")
(defvar elneo-room-bar--dot-faces-colors nil
  "The colors `elneo-room-bar--dot-faces' was built from.
Differing from the current value triggers a rebuild.")

(defun elneo-room-bar--dot-face (profile)
  "Face whose color represents PROFILE."
  (let ((n (length elneo-room-bar-account-colors)))
    (when (= n 0)
      (error "elneo-room-bar-account-colors is empty"))
    ;; Rebuild when the colors changed (e.g. customized mid-session):
    ;; a stale cache would keep rendering the old colors indefinitely.
    (unless (equal elneo-room-bar--dot-faces-colors
                   elneo-room-bar-account-colors)
      (setq elneo-room-bar--dot-faces
            (mapcar
             (lambda (color)
               ;; make-face is a no-op on an existing name; the
               ;; attribute re-set is the point of the rebuild.
               (let ((face (make-face
                            (intern (format "elneo-room-bar-dot-%s" color)))))
                 (set-face-attribute face nil :foreground color :weight 'bold)
                 face))
             elneo-room-bar-account-colors)
            elneo-room-bar--dot-faces-colors elneo-room-bar-account-colors))
    (nth (mod (sxhash profile) n) elneo-room-bar--dot-faces)))

(defun elneo-room-bar--account-prefix (room)
  "The account marker for ROOM's row, honoring `elneo-room-bar-account-display'."
  (let ((profile (plist-get room :profile)))
    (pcase elneo-room-bar-account-display
      ('tag (unless elneo-room-bar-grouped
              (concat (elneo-room-bar--tag profile) " ")))
      ('dot (if elneo-room-bar-grouped ""
              (concat (propertize "●" 'face (elneo-room-bar--dot-face profile)) " ")))
      (_ ""))))

(defconst elneo-room-bar--avatar-width 2
  "Columns of the bar's avatar cell (before its trailing space).")

(defun elneo-room-bar--avatar-image (file)
  "Avatar-width image cell for a downloaded room avatar FILE, or nil.
nil when this Emacs cannot display images (terminal frame, batch)."
  (when-let* ((image (elneo-client--avatar-image
                      file elneo-room-bar--avatar-width)))
    (propertize (make-string elneo-room-bar--avatar-width ?\s)
                'display image)))

(defun elneo-room-bar--avatar-initial (room)
  "The initial-letter fallback avatar for ROOM, in a per-room color."
  (let* ((name (or (plist-get room :display-name) "?"))
         ;; Skip leading non-letter chars ("#", "@", "...") when picking
         ;; the initial.
         (initial (string-trim-left name "[^[:alpha:]]"))
         (initial (if (> (length initial) 0)
                      (substring initial 0 1)
                    "?"))
         (color-face (elneo-room-bar--dot-face
                      (concat (plist-get room :profile)
                              (plist-get room :room-id)))))
    ;; Pad to the cell width here rather than borrowing
    ;; `elneo-room--pad-to-width': the bar stays loadable without
    ;; elneo-room.
    (propertize
     (concat initial
             (make-string
              (max 0 (- elneo-room-bar--avatar-width (string-width initial)))
              ?\s))
     'face (list 'elneo-room-bar-avatar color-face))))

(defun elneo-room-bar--avatar-prefix (room)
  "The avatar cell (with trailing space) for ROOM's row.
The room's avatar image once downloaded, the colored initial until
then and for rooms without an avatar.  \"\" when avatars are off."
  (if (not elneo-room-bar-avatars)
      ""
    (let* ((mxc (plist-get room :avatar))
           (file (and mxc (elneo-client--avatar-file mxc)))
           (img (and file (elneo-room-bar--avatar-image file))))
      (cond
       (img (concat img " "))
       ;; Fetch target cell: once the download lands, the bar's
       ;; re-render picks the image up.
       (mxc (elneo-room-bar--ensure-avatar room mxc)
            (concat (elneo-room-bar--avatar-initial room) " "))
       (t (concat (elneo-room-bar--avatar-initial room) " "))))))

(defun elneo-room-bar--ensure-avatar (room mxc)
  "Fetch ROOM's avatar MXC unless downloaded or already in flight."
  (unless (or (gethash mxc elneo-client--avatar-cache)
              (gethash mxc elneo-client--avatar-pending))
    (elneo-client-fetch-avatar
     (plist-get room :profile) mxc
     (lambda (_profile _event)
       ;; A full re-render re-runs every row's avatar cell; already
       ;; downloaded ones render from the cache instantly.
       (elneo-room-bar--schedule-full)))))

(defun elneo-room-bar--muted-prefix (room)
  "Notification-mode marker glyph for ROOM, with trailing space.
Muted rooms carry `elneo-room-bar-muted-glyph', mentions-only
rooms the dimmer `elneo-room-bar-mentions-glyph'; anything else
(and rooms from a daemon without the data) renders nothing."
  (pcase (plist-get room :notification-mode)
    ("mute" (concat (propertize elneo-room-bar-muted-glyph
                                'face 'elneo-room-bar-muted)
                    " "))
    ("mentions_and_keywords"
     (concat (propertize elneo-room-bar-mentions-glyph
                         'face 'elneo-room-bar-mentions)
             " "))
    (_ "")))

(defun elneo-room-bar--dm-prefix (room)
  "The direct-message marker for ROOM, with trailing space.
Nothing for ordinary rooms — only DMs carry it, in
`elneo-room-bar-dm' style; an empty `elneo-room-bar-dm-glyph'
renders nothing."
  (if (and (plist-get room :direct)
           (> (length elneo-room-bar-dm-glyph) 0))
      (concat (propertize elneo-room-bar-dm-glyph 'face 'elneo-room-bar-dm) " ")
    ""))

(defun elneo-room-bar--space-prefix (room)
  "The space marker for ROOM, with trailing space.
A space's row is an ordinary room row (it has its own timeline);
only the glyph says what `b' on it opens."
  (if (and (plist-get room :space)
           (> (length elneo-room-bar-space-glyph) 0))
      (concat (propertize elneo-room-bar-space-glyph 'face 'elneo-room-bar-space) " ")
    ""))

(defun elneo-room-bar--upgrade-prefix (room)
  "The upgraded-away marker for ROOM, with trailing space.
The glyph marks the dead old room, the one that actually bites:
its tombstone names the replacement, and the overview's
\"Upgraded to\" fact carries the `[open]' to it.  Clicking the row
still opens the old room's history — nothing auto-follows the
link, the marker only says where to look.  An empty
`elneo-room-bar-upgrade-glyph' renders nothing."
  (if (and (plist-get room :upgraded-to)
           (> (length elneo-room-bar-upgrade-glyph) 0))
      (concat (propertize elneo-room-bar-upgrade-glyph
                          'face 'elneo-room-bar-upgrade) " ")
    ""))

(defun elneo-room-bar--row-lines ()
  "Number of text lines each room row occupies."
  (if (and (not (eq elneo-room-bar--state 'rail))
           (eq elneo-room-bar-preview-style 'below))
      2 1))

(defun elneo-room-bar--flatten-newlines (s)
  "Replace newlines in S with spaces, so a message body (the
preview) keeps a room row on its fixed number of lines instead of
spilling lines that leave residue between rows.  Names and
previews come from remote data — anything can be in them."
  (and (stringp s)
       (replace-regexp-in-string "[\n\r]+" " " s)))

(defun elneo-room-bar--row-text (room)
  "The bar text for ROOM (no trailing newline), honoring the
`elneo-room-bar-preview-style' and `elneo-room-bar-avatars'."
  (if (eq elneo-room-bar--state 'rail)
      (elneo-room-bar--rail-text room)
    (let* (;Anon mode fakes a render copy (name, preview); the registry
           ;; record and the row properties stay raw.
           (room (if elneo-anon-mode (elneo-anon--room room) room))
           (unread (plist-get room :unread))
           (highlights (plist-get room :highlights))
           (name (truncate-string-to-width
                  (or (elneo-room-bar--flatten-newlines
                       (plist-get room :display-name))
                      "?")
                  elneo-room-bar-name-width nil nil "…"))
           (preview (elneo-room-bar--flatten-newlines
                     (plist-get room :preview)))
           (prefix
            (concat
             (elneo-room-bar--avatar-prefix room)
             (elneo-room-bar--account-prefix room)
             (elneo-room-bar--dm-prefix room)
             (elneo-room-bar--space-prefix room)
             (elneo-room-bar--upgrade-prefix room)
             (elneo-room-bar--muted-prefix room)
             ;; The invite glyph shows only in `inline' mode — under the
             ;; Invites section header the row is already unambiguous.
             (when (and (elneo-room-bar--invite-p room)
                        (eq elneo-room-invite-display 'inline))
               elneo-room-bar-invite-glyph)
             (cond
              ((> highlights 0) (format "!%d " highlights))
              ((> unread 0) (format "%d " unread))
              (t ""))))
           (name-line (format "%s%s" prefix name))
           (preview-text
            (lambda (p)
              (truncate-string-to-width
               p
               (if (eq elneo-room-bar-preview-style 'below)
                   ;; The second line has the whole bar width to itself.
                   (max 10 (- elneo-room-bar-width 4))
                 elneo-room-bar-preview-length)
               nil nil "…"))))
      (pcase elneo-room-bar-preview-style
        ('none name-line)
        ('below
         ;; Always exactly two lines: `elneo-room-bar--put-row' and
         ;; `elneo-room-bar--remove-room' delete `elneo-room-bar--row-lines'
         ;; lines to rewrite or drop a row, so a preview-less row must still
         ;; carry an (empty) second line — a one-line row here would make the
         ;; next in-place update eat the following room's name line, stomp its
         ;; marker and make rows vanish from the bar.
         (format "%s\n%s" name-line
                 (if (and preview (> (length preview) 0))
                     (propertize (concat "  " (funcall preview-text preview))
                                 'face 'elneo-room-bar-preview)
                   "")))
        (_ (if (and preview (> (length preview) 0))
               (format "%s %s" name-line (funcall preview-text preview))
             name-line))))))

(defun elneo-room-bar--rail-text (room)
  "The rail row for ROOM: the avatar initial, then the unread badge.
No names, previews or markers — everything about the room is a
wide-bar expand away (`elneo-room-bar-toggle-state').  The unread
face from `elneo-room-bar--put-row' still covers the whole row,
so unread rooms stay spottable at rail width."
  (let* ((room (if elneo-anon-mode (elneo-anon--room room) room))
         (unread (or (plist-get room :unread) 0))
         (highlights (or (plist-get room :highlights) 0)))
    (concat (elneo-room-bar--avatar-initial room)
            (cond
             ((> highlights 0) (format "!%d" highlights))
             ((> unread 0) (format "%d" unread))
             (t "")))))

(defun elneo-room-bar--tag (profile &optional full)
  "Account tag for PROFILE; with FULL, the label in full.
Anon mode fakes the tag: the display call sites show it, while
the actions key on the real profile.  The compact tag fits
buttons and rows; the full form (account headers) prints the
real profile whole, or the anon tag in its place."
  (cond ((not elneo-anon-mode)
         (if full profile
           (substring profile 0 (min (length profile) 12))))
        (t (elneo-anon--tag profile))))

(defun elneo-room-bar--row-end (marker)
  "Buffer position one past the row group starting at MARKER:
the nearest marker after it in `elneo-room-bar--markers'
(section headers included), or `point-max'.  Rows are rewritten
and deleted up to this bound rather than counting a fixed number
of lines, so a row that ever rendered wider than one group
(e.g. before newline flattening) cannot leave residue behind —
the rewrite itself cleans it."
  (with-current-buffer elneo-room-bar--buffer
    (let ((pos (min (marker-position marker) (point-max)))
          next)
      (maphash (lambda (_k m)
                 (let ((mp (and (markerp m) (marker-buffer m)
                                (marker-position m))))
                   (when (and mp (> mp pos) (or (null next) (< mp next)))
                     (setq next mp))))
               elneo-room-bar--markers)
      (or next (point-max)))))

(defun elneo-room-bar--put-row (room &optional position)
  "Insert ROOM's row (or replace it) at POSITION, or append.
POSITION is a marker or integer; the room's marker is refreshed.
The row's first text property and marker must land on the row's
own first line, or in-place updates would rewrite the following
row.  An in-place replace clears everything from the row's marker
up to the next row's marker (`elneo-room-bar--row-end'), so the
old row's exact line count does not matter."
  (with-current-buffer elneo-room-bar--buffer
    (save-excursion
      (let* ((key (cons (plist-get room :profile) (plist-get room :room-id)))
             (text (elneo-room-bar--row-text room))
             (lines (elneo-room-bar--row-lines))
             (inhibit-read-only t)
             marker beg end)
        (cond
         ((and position (markerp position))
          (setq marker position)
          (goto-char position)
          (setq beg (point)
                end (min (elneo-room-bar--row-end marker) (point-max)))
          ;; Markers sitting exactly on the end boundary (the next row's
          ;; marker) are dragged to the row start by the deletion; note
          ;; them and move them back onto the following row's new start
          ;; after the rewrite, or that room's next in-place update would
          ;; rewrite THIS row.
          (let (boundary)
            (maphash (lambda (_k m)
                       (when (and (markerp m) (marker-buffer m)
                                  (= (marker-position m) end))
                         (push m boundary)))
                     elneo-room-bar--markers)
            ;; Replace everything up to the next row; the inserted text
            ;; brings its own terminating newline.
            (delete-region beg end)
            (insert text "\n")
            (setq end (1- (point)))
            (dolist (m boundary)
              (set-marker m (point)))))
         (position
          (goto-char position)
          (setq beg (point))
          (insert text "\n")
          (setq end (1- (point))
                marker (copy-marker beg)))
         (t
          (goto-char (point-max))
          (setq beg (point))
          (insert text "\n")
          (setq end (1- (point))
                marker (copy-marker beg))))
        (put-text-property beg end 'elneo-room-key key)
        (puthash key marker elneo-room-bar--markers)
        ;; Unread/highlight emphasis: for a one-line row, the whole line;
        ;; for a two-line row, only the name line, so the preview keeps its
        ;; own styling.
        (let ((face-end (if (> lines 1)
                            (progn (goto-char beg) (line-end-position))
                          end)))
          (if (elneo-room-bar--invite-p room)
              ;; An unacted invite: the whole row goes dim — an invite is
              ;; not yet a conversation.
              (put-text-property beg end 'face 'elneo-room-bar-invite)
            (when (> (plist-get room :unread) 0)
              (put-text-property beg face-end 'face 'elneo-room-bar-unread))
            (when (> (plist-get room :highlights) 0)
              (put-text-property beg face-end 'face 'elneo-room-bar-highlight))))))))

(defvar elneo-room-bar--folded-accounts (make-hash-table :test 'equal)
  "Accounts folded away in the bar's grouped view (profile name -> t.")

;;; Full render

(defun elneo-room-bar--insert-section (key label &rest props)
  "Insert a section header LABEL keyed KEY, with extra properties PROPS.
Appends at point-max: `elneo-room-bar--put-row' appends there
too, and a header landing at a stale caller point would sit in
the middle of previous rows and orphan every room row that
follows it.  The header gets the section face and a
`elneo-room-key' marker under KEY, for the view restore (and
row group tracking) to hold on to across re-renders."
  (goto-char (point-max))
  (let ((beg (point)))
    (insert (apply #'propertize label 'face 'elneo-room-bar-section
                   'elneo-room-key key props)
            "\n")
    (puthash key (copy-marker beg) elneo-room-bar--markers)))

(defun elneo-room-bar-refresh-full ()
  "Re-render the whole room bar."
  (interactive)
  (elneo-room-bar--ensure)
  ;; Remember where the bar window's view sits (by room row), so the
  ;; re-render does not yank the visible part of the list around.
  (let* ((window (get-buffer-window elneo-room-bar--buffer (selected-frame)))
         (view (and window
                    (with-current-buffer elneo-room-bar--buffer
                      (list (get-text-property (window-point window) 'elneo-room-key)
                            (get-text-property (window-start window) 'elneo-room-key))))))
    (with-current-buffer elneo-room-bar--buffer
      (let ((inhibit-read-only t)
            (rooms (elneo-room-bar--visible-rooms)))
        (erase-buffer)
        (clrhash elneo-room-bar--markers)
        (if (eq elneo-room-bar--state 'rail)
            ;; Rail: the expand handle, then flat rows — controls,
            ;; section headers and daemon chips cannot fit a rail
            ;; and are wide-bar only; every setting they expose stays
            ;; reachable from the transient menu (`m').
            (progn
              (insert-text-button
               (propertize "»" 'face 'elneo-room-bar-header)
               'help-echo "w: expand the room bar"
               'action (lambda (_) (elneo-room-bar-toggle-state)))
              (insert "\n")
              (dolist (room (append (elneo-room-bar--invites) rooms))
                (elneo-room-bar--put-row room)))
          (elneo-room-bar--insert-controls)
          (insert "\n")
          ;; The Invites section rides on top of either view when invites
          ;; are configured to show together (see
          ;; `elneo-room-invite-display'): a pseudo-key header like the
          ;; grouped-view account headers, then one dimmed row per invite.
          (when-let* ((invites (elneo-room-bar--invites)))
            (elneo-room-bar--insert-section (cons :invites :section)
                                            (format "Invites (%d)" (length invites)))
            (dolist (invite invites)
              (elneo-room-bar--put-row invite)))
          (if elneo-room-bar-grouped
              (dolist (profile (elneo-room-bar--account-list))
                (let ((section (cl-remove-if-not
                                (lambda (room)
                                  (equal (plist-get room :profile) profile))
                                rooms)))
                  (when section
                    (let* ((folded (gethash profile
                                            elneo-room-bar--folded-accounts))
                           (unread (apply #'+
                                          (mapcar
                                           (lambda (room)
                                             (or (plist-get room :unread) 0))
                                           section)))
                           (label
                            (concat (if folded "▸ " "▾ ")
                                    (elneo-room-bar--tag profile t)
                                    (when folded
                                      (format " (%d room%s%s)"
                                              (length section)
                                              (if (= 1 (length section)) "" "s")
                                              (if (> unread 0)
                                                  (format ", %d unread" unread)
                                                ""))))))
                      (elneo-room-bar--insert-section (cons profile :section)
                                                      label
                                                      'elneo-room-bar-account profile)
                      (unless folded
                        (dolist (room section)
                          (elneo-room-bar--put-row room))))))))
          (unless elneo-room-bar-grouped
            (dolist (room rooms)
              (elneo-room-bar--put-row room))))
        ;; Restore the view: point back on the room it was on, window top
        ;; back on its old top row (both fall back to the list start).
        (when window
          (let ((point-marker (and (nth 0 view)
                                   (gethash (nth 0 view) elneo-room-bar--markers)))
                (start-marker (and (nth 1 view)
                                   (gethash (nth 1 view) elneo-room-bar--markers))))
            (set-window-start window (or (and start-marker (marker-position start-marker))
                                         (point-min)))
            (set-window-point window (or (and point-marker (marker-position point-marker))
                                         (point-min)))))
        (set-buffer-modified-p nil)))))

(defun elneo-room-bar--on-session-state (_profile &optional _enabled _trusted)
  "Session hook (trust and sync-state): re-render when a PROFILE changes.
No --ensure (no spawn, no unhide, no daemon call) and no direct
refresh-full — a trust or sync-state update may ride a burst of
events, and the coalesced renderer sorts that out.  Anything that
wants a row earlier can just call `elneo-room-bar-refresh-full'."
  (when (buffer-live-p elneo-room-bar--buffer)
    (elneo-room-bar--schedule-full)))

(defun elneo-room-bar--schedule-full ()
  "Schedule a full re-render, coalescing bursts into one."
  (setq elneo-room-bar--full-pending t)
  (unless elneo-room-bar--full-timer
    (setq elneo-room-bar--full-timer
          (run-with-idle-timer 0.2 nil #'elneo-room-bar--flush-full))))

(defun elneo-room-bar--flush-full ()
  "Run a pending full re-render (idle timer callback)."
  (setq elneo-room-bar--full-timer nil)
  (when elneo-room-bar--full-pending
    (setq elneo-room-bar--full-pending nil)
    (elneo-room-bar-refresh-full)))

(defun elneo-room-bar--daemon-chips ()
  "Per-daemon chips for the status row (rendered in
`--insert-controls'): one element (PROFILE STATE GLYPH FACE ERROR)
per daemon that has a recorded sync state or a live process.  A
dead daemon's state entry is kept by the recorder on purpose — that
is why a chip can exist with no live process — unless the stop was
deliberate (`elneo-server--manual-stops'): a stopped daemon is a
decision, not a fault, and gets no chip."
  (let ((profiles (delete-dups
                   (append
                    (and (boundp 'elneo-server--sync-states)
                         (mapcar #'car elneo-server--sync-states))
                    (and (boundp 'elneo-server--buffers)
                         (mapcar #'car elneo-server--buffers)))))
        (manual (and (boundp 'elneo-server--manual-stops)
                     elneo-server--manual-stops))
        (states (and (boundp 'elneo-server--sync-states)
                     elneo-server--sync-states))
        chips)
    ;; Transport not loaded yet: no chips, the row is blank until it
    ;; is.  (The mode line calls this before any daemon may exist.)
    (dolist (profile (when (fboundp 'elneo-server-live-p) profiles))
      (let* ((entry (and states (alist-get profile states nil nil #'equal)))
             (state (or (car entry) "starting"))
             (glyph (pcase state
                      ("synced" "●")
                      ((or "error" "offline") "✗")
                      (_ "◐")))
             (face (pcase state
                     ("synced" 'success)
                     ((or "error" "offline") 'elneo-room-bar-offline)
                     (_ nil))))
        (cond
         ((elneo-server-live-p profile)
          (push (list profile state glyph face (cdr entry)) chips))
         ;; A dead daemon keeps its entry ("offline" or a homeserver
         ;; "error"): show it until the daemon is back — that is the
         ;; whole point of the row.  Manual stops are hidden.
         ((and (member state '("error" "offline"))
               (not (assoc profile manual)))
          (push (list profile state glyph face (cdr entry)) chips))
         (t nil))))
    (nreverse chips)))

(defun elneo-room-bar--control-button (label action &rest props)
  "Insert one controls-row button: LABEL running ACTION (the
`insert-text-button' convention — the button as its ignored
argument), PROPS as further text properties (face, help-echo)."
  (apply #'insert-text-button label 'action action props))

(defun elneo-room-bar--insert-controls ()
  "Insert the controls rows: account buttons, then sorting/layout.
Two rows, because a side window never fits one line of buttons:
row one is the instance filter (plus the search state), row two the
sorting and display modes.  Everything here is also reachable from
the `elneo-transient' menu (`m' in the bar)."
  (let ((inhibit-read-only t))
    ;; Row one starts with the fold handle: a stable corner tap target
    ;; (top-left), mirrored by the expand » at the top of the rail —
    ;; both sides of the toggle are always one tap away.
    (insert-text-button "[«]"
                        'help-echo "w: fold the bar to the rail"
                        'action (lambda (_) (elneo-room-bar-toggle-state)))
    (insert " ")
    ;; Row one: instance filter buttons, then the search state.
    ;; The active filter carries the header face; the other controls
    ;; render as the ordinary blue button link type — an explicit
    ;; `button' face, identical to the category face an unfaced
    ;; button inherits (passing nil or an empty face would paint the
    ;; default foreground instead).
    (insert-text-button "[All]"
                        'face (if elneo-room-bar-account-filter
                                  'button
                                'elneo-room-bar-header)
                        'action (lambda (_) (elneo-room-bar-set-account nil)))
    (dolist (profile (elneo-room-bar--account-list))
      (insert " ")
      (insert-text-button (format "[%s]" (elneo-room-bar--tag profile))
                          'face (if (equal elneo-room-bar-account-filter profile)
                                    'elneo-room-bar-header
                                  'button)
                          'action (lambda (_) (elneo-room-bar-set-account profile))))
    (insert " ")
    (insert-text-button "[Srch]"
                        'action (lambda (_) (call-interactively
                                             #'elneo-room-bar-set-search)))
    (when (> (length elneo-room-bar-search) 0)
      (insert " “" elneo-room-bar-search "”"))
    (insert "\n")
    ;; Row two: sorting and display modes.
    (insert-text-button (format "[Sort:%s]"
                                (elneo-room-bar-sort-label
                                 elneo-room-bar-sort t))
                        'action (lambda (_) (elneo-room-bar-cycle-sort)))
    (insert " ")
    (insert-text-button (if elneo-room-bar-grouped "[Grp]" "[Mix]")
                        'action (lambda (_) (elneo-room-bar-toggle-grouped)))
    (insert " ")
    (insert-text-button (pcase elneo-room-bar-dm-filter
                          ('dm "[DMs]")
                          ('rooms "[NoDMs]")
                          (_ "[DM+]"))
                        'face (if elneo-room-bar-dm-filter
                                  'elneo-room-bar-header
                                'button)
                        'help-echo "d: cycle the direct-message filter"
                        'action (lambda (_) (elneo-room-bar-cycle-dm)))
    (insert " ")
    (insert-text-button (format "[Prev:%s]"
                                (pcase elneo-room-bar-preview-style
                                  ('inline "inl") ('below "2nd") (_ "off")))
                        'action (lambda (_) (elneo-room-bar-cycle-preview)))
    (insert " ")
    (insert-text-button (if elneo-room-bar-avatars "[Av:on]" "[Av:off]")
                        'action (lambda (_) (elneo-room-bar-toggle-avatars)))
    ;; Third row — only when one of the accounts has cross-signing
    ;; enabled but this session does not yet trust it.  An account
    ;; that never bootstrapped (its only device) shows nothing: there
    ;; is no session worth nagging into a setup flow.  The button is
    ;; the shortcut into `elneo-session-status', which carries the
    ;; actual verify/remove UI.
    (when-let* ((untrusted (cl-remove-if-not
                            (lambda (row) (and (eq (car (cdr row)) t)
                                               (not (cdr (cdr row)))))
                            (when (boundp 'elneo-server--trust)
                              elneo-server--trust))))
      (insert "\n")
      ;; From the trust alist itself: an untrusted account with no
      ;; rooms still needs its row, and row one ignores the filter too.
      (dolist (row untrusted)
        (insert " ")
        (elneo-room-bar--control-button
         (format "[Verify: %s]" (elneo-room-bar--tag (car row)))
         (lambda (_) (elneo-session-status (car row)))
         'face 'elneo-room-bar-unverified)))
    ;; Daemon status row, folded with the degraded-state chips: one
    ;; glyph per daemon — ● synced (success face), ◐ connecting,
    ;; ✗ down — whole chip in `elneo-room-bar-offline' when down.
    ;; Click restarts the daemon, dead or merely wedged.  Chips stay
    ;; on one row: two accounts is the realistic maximum.
    (let ((chips (elneo-room-bar--daemon-chips)))
      (when chips
        (insert "\n")
        (dolist (chip chips)
          (insert " ")
          (insert-text-button
           (format "[%s %s]" (nth 2 chip) (elneo-room-bar--tag (car chip)))
           'face (nth 3 chip)
           'help-echo (format "%s daemon: %s%s — click to restart"
                              (car chip)
                              (nth 1 chip)
                              (if (nth 4 chip) (concat ": " (nth 4 chip)) ""))
           'action (lambda (_) (elneo-restart-server (car chip)))))))))

(defconst elneo-room-bar--sort-table
  '((activity "activity" "Act")
    (alpha "alphabetical" "Alp")
    (unread "unread" "Unr"))
  "One row per sort order: symbol, long label, bar abbreviation.
The long label is what the transient options menu shows; the
abbreviation fits the bar's controls row.")

(defun elneo-room-bar-sort-label (sort &optional short)
  "Human label for SORT — the bar abbreviation when SHORT is non-nil."
  (let ((row (assq sort elneo-room-bar--sort-table)))
    (if row
        (if short (nth 2 row) (nth 1 row))
      (symbol-name sort))))

;;; Incremental update

(defun elneo-room-bar--on-room-update (room)
  "Room update hook: update one row, or drop a removed room."
  (when (buffer-live-p elneo-room-bar--buffer)
    (if (plist-get room :removed)
        (elneo-room-bar--remove-room room)
      ;; If the room is new (no marker), a full re-render is scheduled
      ;; (coalescing bursts); otherwise update just its line in place.
      (let ((marker (gethash (cons (plist-get room :profile)
                                   (plist-get room :room-id))
                             elneo-room-bar--markers)))
        (if (and marker (marker-buffer marker))
            (progn
              (with-current-buffer elneo-room-bar--buffer
                (elneo-room-bar--put-row room marker))
              ;; Live re-sort: the update may change the display order
              ;; (fresh activity bumps the room up), so schedule the
              ;; coalesced full re-render.  Without it the row keeps
              ;; its place and the order holds until a user action.
              (when elneo-room-bar-live-sort
                (elneo-room-bar--schedule-full)))
          (elneo-room-bar--schedule-full))))))

(defun elneo-room-bar--remove-room (room)
  "Remove ROOM's row from the bar."
  (let ((key (cons (plist-get room :profile) (plist-get room :room-id)))
        (inhibit-read-only t))
    (when (buffer-live-p elneo-room-bar--buffer)
      (with-current-buffer elneo-room-bar--buffer
        (let ((marker (gethash key elneo-room-bar--markers)))
          (when (and marker (marker-buffer marker))
            ;; Delete up to the next row's marker, not a fixed line
            ;; count — as in `elneo-room-bar--put-row', so a row wider
            ;; than its line allotment cannot leave residue.
            (delete-region marker
                           (min (elneo-room-bar--row-end marker)
                                (point-max)))
            (remhash key elneo-room-bar--markers)))))))

;;; Commands

(defun elneo-room-bar--prop-near-point (prop)
  "Property PROP at point, or one character back at end of line.
A row carries its key over its own text only; the terminating
newline stays unpropertized, so point sitting directly after a
room finds nothing at (point) — the row was still hit."
  (or (get-text-property (point) prop)
      (and (eolp) (not (bolp))
           (get-text-property (1- (point)) prop))))

(defun elneo-room-bar--room-at-point ()
  "Room record at point, or nil."
  (let ((key (elneo-room-bar--prop-near-point 'elneo-room-key)))
    (when key
      (elneo-room-get (car key) (cdr key)))))

(defun elneo-room-bar-open-at-point (&optional arg)
  "Open the room under point in the main window area.
With ARG (a universal prefix), open right where we are instead of
following `elneo-room-open-frame-policy'.  On a grouped-view
account header, fold or unfold that section instead (ARG unused)."
  (interactive "P")
  (let ((room (elneo-room-bar--room-at-point)))
    (cond (room
           (elneo-room-open room arg))
          ((elneo-room-bar--prop-near-point 'elneo-room-bar-account)
           (elneo-room-bar-toggle-fold
            (elneo-room-bar--prop-near-point
             'elneo-room-bar-account)))
          (t
           (user-error "No room on this line")))))

(defvar elneo-room-bar--jump-key nil
  "The (profile . room-id) the last u/@ jump landed on, or nil.
The next press walks strictly past it — even after the bar
re-sorted under us or point moved away — instead of reopening the
same room; a scan that finds nothing clears it.")

(defun elneo-room-bar--jump-next (pred label)
  "Open the next room after the anchor whose PRED holds; LABEL
names the emptiness when none does.
The anchor is the previous jump's row (`elneo-room-bar--jump-key')
while it still shows, else point's row, else the bar's top; the
scan wraps once around `elneo-room-bar--visible-rooms'."
  (let* ((rooms (elneo-room-bar--visible-rooms))
         (n (length rooms))
         ;; Rows carry (profile . room-id); a record turns back into
         ;; its row key only through the projection — comparing the
         ;; key against the raw record would never match.
         (key-of (lambda (room)
                   (cons (plist-get room :profile) (plist-get room :room-id))))
         (start
          (or (cl-position elneo-room-bar--jump-key rooms
                           :test (lambda (key room)
                                   (equal key (funcall key-of room))))
              (cl-position
               (elneo-room-bar--prop-near-point 'elneo-room-key)
               rooms
               :test (lambda (key room)
                       (equal key (funcall key-of room))))
              -1))
         (hit
          (when (> n 0)
            (cl-loop for i from 1 to n
                     for room = (nth (% (+ start i) n) rooms)
                     when (funcall pred room)
                     return room))))
    (if hit
        (progn
          (setq elneo-room-bar--jump-key
                (cons (plist-get hit :profile) (plist-get hit :room-id)))
          (elneo-room-open hit)
          (message "Matrix: opened %s"
                   (or (plist-get hit :display-name)
                       (plist-get hit :name)
                       (plist-get hit :room-id))))
      (setq elneo-room-bar--jump-key nil)
      (user-error "Matrix: no %s rooms" label))))

(defun elneo-room-bar-next-unread ()
  "Open the next room with unread messages after the current anchor."
  (interactive)
  (elneo-room-bar--jump-next
   (lambda (room) (> (or (plist-get room :unread) 0) 0))
   "unread"))

(defun elneo-room-bar-next-highlight ()
  "Open the next room with unread highlights after the current anchor."
  (interactive)
  (elneo-room-bar--jump-next
   (lambda (room) (> (or (plist-get room :highlights) 0) 0))
   "highlight"))

(defun elneo-room-bar-mark-read-at-point ()
  "Mark the room under point read up to its newest event.
The counters drop when the daemon's updateRoom echoes the receipt;
invites ride room summaries without a last event, so they have
nothing to mark yet."
  (interactive)
  (let ((room (elneo-room-bar--room-at-point)))
    (cond ((and room (plist-get room :last-event-id))
           (elneo-room-mark-read (plist-get room :profile)
                                 (plist-get room :room-id)
                                 (plist-get room :last-event-id))
           (message "Matrix: marked %s read"
                    (or (plist-get room :display-name)
                        (plist-get room :name)
                        (plist-get room :room-id))))
          (room (user-error "Nothing to mark yet"))
          (t (user-error "No room on this line")))))

(defun elneo-room-bar-cycle-sort ()
  "Cycle the bar's sort order."
  (interactive)
  (setq elneo-room-bar-sort
        (pcase elneo-room-bar-sort
          ('activity 'unread)
          ('unread 'alpha)
          (_ 'activity)))
  (elneo-room-bar-refresh-full))

(defun elneo-room-bar-cycle-account ()
  "Cycle the account filter (all -> each account in turn)."
  (interactive)
  (let* ((accounts (elneo-room-bar--account-list))
         (current-index (cl-position elneo-room-bar-account-filter
                                     accounts :test #'equal)))
    (setq elneo-room-bar-account-filter
          (cond
           ((null current-index) (car accounts))
           ((= (1+ current-index) (length accounts)) nil)
           (t (nth (1+ current-index) accounts))))
    (elneo-room-bar-refresh-full)))

(defun elneo-room-bar-cycle-dm ()
  "Cycle the DM filter (everything -> DMs only -> rooms only)."
  (interactive)
  (setq elneo-room-bar-dm-filter
        (pcase elneo-room-bar-dm-filter
          ('dm 'rooms)
          ('rooms nil)
          (_ 'dm)))
  (message "Matrix: room bar shows %s"
           (pcase elneo-room-bar-dm-filter
             ('dm "direct messages only")
             ('rooms "group rooms only")
             (_ "everything")))
  (elneo-room-bar-refresh-full))

(defun elneo-room-bar-set-account (profile)
  "Filter the bar to PROFILE's rooms only (nil = all accounts)."
  (setq elneo-room-bar-account-filter profile)
  (elneo-room-bar-refresh-full))

(defun elneo-room-bar-set-search (search)
  "Set a case-insensitive substring SEARCH filter for the room list."
  (interactive (list (read-string "Search rooms: " elneo-room-bar-search)))
  (setq elneo-room-bar-search search)
  (elneo-room-bar-refresh-full))

(defun elneo-room-bar-cycle-preview ()
  "Cycle the message-preview style (inline -> below -> off)."
  (interactive)
  (setq elneo-room-bar-preview-style
        (pcase elneo-room-bar-preview-style
          ('inline 'below)
          ('below 'none)
          (_ 'inline)))
  (elneo-room-bar-refresh-full))

(defun elneo-room-bar-toggle-avatars ()
  "Toggle the avatar placeholder column."
  (interactive)
  (setq elneo-room-bar-avatars (not elneo-room-bar-avatars))
  (elneo-room-bar-refresh-full))

(defun elneo-room-bar-toggle-grouped ()
  "Toggle between the mixed view and per-account sections."
  (interactive)
  (setq elneo-room-bar-grouped (not elneo-room-bar-grouped))
  (elneo-room-bar-refresh-full))

(defun elneo-room-bar-toggle-fold (profile)
  "Fold or unfold PROFILE's section in the grouped room bar.
Folding hides the section's rooms; the header keeps their count and
unread total.  Outside grouped view nothing visible changes, but the
state persists for the next time grouped view comes on."
  (interactive
   (list (or (get-text-property (point) 'elneo-room-bar-account)
             (user-error "No account section header at point"))))
  (if (gethash profile elneo-room-bar--folded-accounts)
      (remhash profile elneo-room-bar--folded-accounts)
    (puthash profile t elneo-room-bar--folded-accounts))
  (elneo-room-bar-refresh-full))

(defun elneo-room-bar-toggle-live-sort ()
  "Toggle live re-sorting of the bar as room activity arrives."
  (interactive)
  (setq elneo-room-bar-live-sort (not elneo-room-bar-live-sort))
  (elneo-room-bar-refresh-full))

(defun elneo-room-bar-cycle-click-action ()
  "Cycle what a mouse click on a room row does (open -> double -> point)."
  (interactive)
  (setq elneo-room-bar-click-action
        (pcase elneo-room-bar-click-action
          ('open 'double)
          ('double 'point)
          (_ 'open)))
  (message "Matrix: room bar clicks %s"
           (pcase elneo-room-bar-click-action
             ('open "open the room")
             ('double "open on a double click")
             (_ "only move point"))))

(defun elneo-room-bar--mouse-1 (event)
  "Act on a mouse-1 click EVENT per `elneo-room-bar-click-action'.
The click always moves point to the row it landed on.  A button —
the controls rows, the « and » handles — activates right away: a
touch tap lands as mouse-1, and touch cannot use the mouse-2 the
button machinery answers to.  When the row is a room and the
setting allows it, the room opens and carries the prefix pressed
before the click — a universal prefix means: right where we are.
A click on a grouped-view account header folds or unfolds that
section."
  (interactive "e")
  (let* ((posn (event-start event))
         (window (posn-window posn))
         (pt (posn-point posn)))
    (when (and (windowp window) pt
               (eq (window-buffer window) elneo-room-bar--buffer))
      (select-window window)
      (goto-char pt)
      (let ((room (elneo-room-bar--room-at-point)))
        (cond
         ;; A button (controls, handles): activate on mouse-1.  Room
         ;; rows carry no buttons, so this never shadows a room open.
         ((button-at pt) (push-button (button-at pt)))
         ;; A room row: open it per the click-action setting.
         (room
          (when (or (eq elneo-room-bar-click-action 'open)
                    (and (eq elneo-room-bar-click-action 'double)
                         (>= (event-click-count event) 2)))
            ;; The prefix pressed before the click, if any, means
            ;; "right where we are".
            (elneo-room-open room current-prefix-arg)))
         ;; An account header folds like the other header buttons,
         ;; whatever the click-action setting says about room rows.
         ((elneo-room-bar--prop-near-point 'elneo-room-bar-account)
          (elneo-room-bar-toggle-fold
           (elneo-room-bar--prop-near-point
            'elneo-room-bar-account))))))))

;;;###autoload
(defun elneo-room-bar-options ()
  "Open the transient menu exposing every bar option.
The header buttons cover the frequent toggles; this menu shows all
of them with their current values: sort order, live re-sorting,
grouped view, preview style, avatar column, account filter,
DM filter, search.  Every setting is global, so the menu works from
any
buffer — `m' in the bar, `C-c C-b' in a room buffer, or bind it
globally yourself.
Needs the `transient' package (the one behind magit's popups)."
  (interactive)
  (if (require 'transient nil t)
      (progn
        (require 'elneo-transient)
        (call-interactively #'elneo-transient-dispatch))
    (message "Matrix: the options menu needs the transient package")))

(defun elneo-room-open (room &optional stay-put)
  "Open the room record ROOM in the main window area.
With STAY-PUT non-nil (a universal prefix on the calling
command), ignore `elneo-room-open-frame-policy' and open the
buffer right where we are.  A pending invite cannot open: its row
prompts join / decline / ignore instead (nothing is openable yet)."
  (if (elneo-room-bar--invite-p room)
      (elneo-room-invite-prompt room)
    (require 'elneo-room)
    (elneo-room--open room stay-put)))

;;;###autoload
(defun elneo-open-room (&optional arg)
  "Pick any room by name (all accounts) and open it in the main area.
With ARG (a universal prefix), open it right where we are — no
frame or workspace following the room bar, no bar creation."
  (interactive "P")
  (elneo-room-open (elneo-completing-read-room) arg))

;;; Mode line

(defvar elneo-mode-line-string nil
  "The `elneo-mode-line-mode' segment, or nil to show nothing.

The string is a mode-line construct placed in `global-mode-string';
nil hides the segment entirely.")

;; The variable holds propertized text (`error' face on the mention
;; suffix); the mode line only renders text properties of risky
;; variables.
(put 'elneo-mode-line-string 'risky-local-variable t)

(defun elneo-mode-line--update (&rest _)
  "Recompute `elneo-mode-line-string' from the room registry.
Shows MX[TOTAL/ROOMS] — total unread messages over rooms with
unread — plus an `!N' highlight count in the error face when there
are unread mentions, and a `⚠N' count (same face) of daemons that
are down: dead, or alive but reporting a sync error.  Zero everywhere
hides the segment."
  (let* ((rooms (cl-remove-if
                 (lambda (room) (plist-get room :removed))
                 (elneo-rooms-all)))
         (unread (apply #'+ (mapcar (lambda (r) (or (plist-get r :unread) 0))
                                    rooms)))
         (unread-rooms (cl-count-if (lambda (r) (> (or (plist-get r :unread) 0) 0))
                                    rooms))
         (highlights (apply #'+ (mapcar (lambda (r) (or (plist-get r :highlights) 0))
                                        rooms)))
         (down (cl-count-if
                (lambda (chip)
                  (member (nth 1 chip) '("offline" "error")))
                (elneo-room-bar--daemon-chips))))
    (setq elneo-mode-line-string
          (when (or (> unread 0) (> highlights 0) (> down 0))
            (concat (format "MX[%d/%d]" unread unread-rooms)
                    (if (> highlights 0)
                        (propertize (format " !%d" highlights) 'face 'error)
                      "")
                    (if (> down 0)
                        (propertize (format " ⚠%d" down) 'face 'error)
                      ""))))
    (force-mode-line-update t)))

;;;###autoload
(define-minor-mode elneo-mode-line-mode
  "Toggle the Matrix unread count in the mode line.
With a prefix argument ARG, enable the mode if ARG is positive.
The segment mirrors telega's `telega-mode-line-mode': total unread
messages over rooms-with-unread, e.g. `MX[17/3]', plus an `!N'
suffix (error face) while mentions are unread, and a `⚠N' suffix
while any daemon is down (unread/mention-count zero or not — the
segment stays visible while the client cannot talk to a homeserver).
Nothing shows when there is nothing wrong."
  :global t
  (if elneo-mode-line-mode
      (progn
        ;; The bare symbol, not a list: a list whose car is a non-keyword
        ;; symbol parses as the (SYMBOL THEN ELSE) mode-line conditional.
        (add-to-list 'global-mode-string 'elneo-mode-line-string 'append)
        (add-hook 'elneo-room-update-hook #'elneo-mode-line--update)
        (add-hook 'elneo-session-sync-hook #'elneo-mode-line--update)
        (elneo-mode-line--update))
    (setq elneo-mode-line-string nil)
    (remove-hook 'elneo-room-update-hook #'elneo-mode-line--update)
    (remove-hook 'elneo-session-sync-hook #'elneo-mode-line--update)
    (setq global-mode-string
          (remove 'elneo-mode-line-string global-mode-string))
    (force-mode-line-update t)))

(defun elneo-room-bar-browse-space-at-point ()
  "Open the space page of the room row at point.
Applies to a row whose room IS a space (`is_space' — the bar row
is one way into the discovery page, next to a room overview's
Spaces line and shared matrix.to links).  A row of a room that
merely belongs to spaces reads its parents from the room
overview (i), where the daemon fills the Spaces line on demand."
  (interactive)
  (let ((room (elneo-room-bar--room-at-point)))
    (if (not room)
        (user-error "No room on this line")
      (if (not (plist-get room :space))
          (user-error "%s is not a space — the spaces it belongs to show in its overview (i)"
                      (or (plist-get room :display-name)
                          (plist-get room :room-id)))
        (require 'elneo-space)
        (elneo-space-browse (plist-get room :profile)
                            (plist-get room :room-id))))))

(defun elneo-room-bar-settings-at-point ()
  "Show the settings of the room at point."
  (interactive)
  (let ((room (elneo-room-bar--room-at-point)))
    (if room
        (progn
          (require 'elneo-room)
          (elneo-room-settings room))
      (user-error "No room on this line"))))

(defun elneo-room-bar-leave-at-point ()
  "Leave the room at point, after a confirmation.
An invited room declines instead (that is what leaving one is).
The bar row leaves via `updateRoomGone'; the room's open buffer,
if any, closes with the ack."
  (interactive)
  (let ((room (elneo-room-bar--room-at-point)))
    (if room
        (progn
          (require 'elneo-room)
          (elneo-room--leave-confirmed (plist-get room :profile)
                                       (plist-get room :room-id)))
      (user-error "No room on this line"))))

;; elneo-room.el is loaded at runtime to avoid a load cycle.
(declare-function elneo-room--open "elneo-room" (room &optional stay-put))
(declare-function elneo-room-settings "elneo-room" (room))
(declare-function elneo-room-invite-prompt "elneo-room" (room))
(declare-function elneo-join-matrix-to "elneo-room" (profile url))
(declare-function elneo-room-create "elneo-room" (profile name alias public topic encrypted))
(declare-function elneo-room--leave-confirmed "elneo-room" (profile room-id &optional buf))
(declare-function elneo-space-browse "elneo-space" (profile room-id))

(provide 'elneo-room-bar)
;;; elneo-room-bar.el ends here
