;;; elneo-room.el --- Matrix room buffers: history, live updates, send -*- lexical-binding: t -*-

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;;; Commentary:

;; Room buffers render one room's message history and append live
;; messages as they arrive from any account's daemon.
;;
;; Every buffer ends in a writable input area: a separator line, then
;; the draft.  Type directly in the buffer — \\[elneo-room--input-send]
;; (RET) sends, C-j adds a newline, \\[elneo-room-attach] attaches an
;; image, \\[elneo-room-send] or RET on the history prompt in the
;; minibuffer instead.  Draft tags of the form [image: PATH] upload the
;; file; the rest of the draft is sent as text.
;;
;; Read-only model: `buffer-read-only' is nil; all history text carries
;; the `read-only' text property, and the separator's last character is
;; `rear-nonsticky' so typing at the start of the draft does not
;; inherit it.  All history edits run under `inhibit-read-only'.
;;
;; Key plumbing differs from telega's (visible behavior is the same):
;; telega binds per-message keys on message buttons via text-property
;; keymaps, while this mode binds them in the mode map and dispatches
;; on the key properties at point — bare keys self-insert in the draft
;; because the commands pass keystrokes through when point sits in the
;; input.
;;
;; Display policy: a room buffer replaces the contents of the largest
;; non-side window in the frame — the window next to the fixed room bar.
;; Side windows (the bar) are never touched, and arbitrary user splits
;; are preserved: the largest non-side window is reused, not replaced.
;;
;; History backfills from the daemon's `getRoomMessages' (newest page
;; first, then older pages).  View restore is event-id anchored, so
;; thumbnails landing or re-renders after room keys arrive do not move
;; the visible content.  Scrolling to the top (mouse wheel up, M-<)
;; loads older pages automatically; \\[elneo-room-older] (PageUp) also
;; scrolls the view up into the fresh page.  Own messages render when
;; the sync echo arrives, so a failed send never leaves a ghost.

;;; Code:

(defvar elneo-thread--buffers) ; hash of thread view buffers (elneo-thread)

(require 'cl-lib)
(require 'subr-x)
(require 'color)
(require 'dnd)                          ; drop-to-attach: dnd-protocol-alist et al
(require 'json)
(require 'elneo-client)
(require 'elneo-anon)

(defgroup elneo-room nil
  "Matrix room buffers."
  :group 'elneo
  :prefix "elneo-room-")

(defface elneo-room-time
  '((t :inherit shadow))
  "Face for message timestamps."
  :group 'elneo-room)

(defface elneo-room-url-face
  '((t :underline t))
  "Face for bare http(s) links recognized in message text."
  :group 'elneo-room)

(defface elneo-room-sender
  '((t :weight bold))
  "Face for message senders."
  :group 'elneo-room)

(defface elneo-room-own-sender
  '((t :weight bold :slant italic))
  "Face for your own message sender."
  :group 'elneo-room)

(defface elneo-room-day-separator
  '((t :inherit shadow :slant italic))
  "Face for day separators."
  :group 'elneo-room)

(defface elneo-room-undecryptable
  '((t :inherit shadow :slant italic))
  "Face for messages whose room key was not available (yet)."
  :group 'elneo-room)

(defface elneo-room-input-separator
  '((t :inherit shadow))
  "Face for the bar separating the history from the input area.
Subdued grey text on the regular buffer background — with the
separator's face no longer sticking to typed text (see
`elneo-room--mark-history-readonly'), a `mode-line' inheritance
would leave the strip as the only grey surface in the room."
  :group 'elneo-room)

(defface elneo-room-input-placeholder
  '((t :inherit shadow))
  "Face for the placeholder shown while the draft is empty."
  :group 'elneo-room)

;; `elneo-room-reply-quote-face', not `elneo-room-reply-quote':
;; that name is the defcustom choosing HOW MUCH of the parent to
;; quote — one symbol cannot sanely be both a face and a variable.
(defface elneo-room-reply-quote-face
  '((t :inherit shadow :slant italic))
  "Face for the quoted parent in a reply's first line."
  :group 'elneo-room)

(defface elneo-room-reaction
  '((t :inherit shadow))
  "Face for the reaction line under a message.
The line's `‹' prefix keeps actual reactions visually distinct
from emoji a sender may have typed into the body."
  :group 'elneo-room)

(defface elneo-room-reaction-own
  '((t :inherit shadow :weight bold))
  "Face for reaction keys you reacted with yourself."
  :group 'elneo-room)

(defface elneo-room-poll
  '((t :inherit shadow))
  "Face for a poll's option lines."
  :group 'elneo-room)

(defface elneo-room-poll-own
  '((t :inherit shadow :weight bold))
  "Face for poll option lines you voted for."
  :group 'elneo-room)

(defface elneo-room-redacted
  '((t :inherit shadow :slant italic))
  "Face for redacted (deleted) message markers."
  :group 'elneo-room)

(defface elneo-room-edited
  '((t :inherit shadow))
  "Face for the subdued (edited) marker on edited messages."
  :group 'elneo-room)

(defface elneo-room-pin
  '((t :inherit warning))
  "Face for the [pinned] marker on messages pinned to the room's
m.room.pinned_events list (protocol 22)."
  :group 'elneo-room)

(defface elneo-room-read
  '((t :inherit shadow))
  "Face for other members' read marks: the ✓✓ on the newest own
message someone has read, the dim of read own messages, and the
settings view's read-by list."
  :group 'elneo-room)

(defface elneo-room-pending
  '((t :inherit shadow))
  "Face for the ⏱ marker on a message that is sent but unacked.
The provisional block renders the moment RET hands the text to the
daemon; the marker disappears when the server answers with the
event id."
  :group 'elneo-room)

(defface elneo-room-trust-verified
  '((t :inherit success))
  "Face for the ✓ mark on messages from verified senders."
  :group 'elneo-room)

(defface elneo-room-trust-unverified
  '((t :inherit warning))
  "Face for the ⚠ mark on messages from unverified senders."
  :group 'elneo-room)

(defface elneo-room-trust-broken
  '((t :inherit error))
  "Face for the ✗ mark on messages from senders with an
identity/device anomaly (verification violation, key mismatch)."
  :group 'elneo-room)

(defconst elneo-room--trust-marks
  '(("verified"   "✓" elneo-room-trust-verified)
    ("unverified" "⚠" elneo-room-trust-unverified)
    ("unsigned"   "⚠" elneo-room-trust-unverified)
    ("violation"  "✗" elneo-room-trust-broken)
    ("mismatch"   "✗" elneo-room-trust-broken))
  "Sender-trust string -> (GLYPH . FACE) pairs, keyed by string.
Values come from the daemon's `sender_trust' field; an unknown
future value renders no mark at all.")

(defface elneo-room-send-failed
  '((t :inherit error))
  "Face for the ✗ marker on a message whose send failed.
`R' retries it, `K' discards it — nothing reached the server."
  :group 'elneo-room)

(defcustom elneo-room-sender-width 14
  "Columns reserved for the sender name before the message body."
  :type 'integer
  :group 'elneo-room)

(defcustom elneo-room-avatars t
  "Show sender avatars in a column at the start of each message.
Non-nil inserts a one-line avatar cell before each message's
timestamp: the sender's member avatar fetched through the thumbnail
path (disk-cached like all media, so it renders instantly after the
first fetch), a colored initial while it downloads or when the
sender has none.  nil renders without the column, as before.
`\\[elneo-room-toggle-avatars]' toggles the current buffer, leaving
this default untouched."
  :type 'boolean
  :group 'elneo-room)

(defcustom elneo-room-sender-colors t
  "Color other people's sender names, one stable color per user.
The color derives from the Matrix user id (display-name changes do
not alter it) and is recomputed against the current theme background
when the theme changes, so names stay readable on light and dark
themes alike.  Your own messages keep `elneo-room-own-sender'.

Toggling this off affects newly rendered messages; already-rendered
buffers pick colors up again on their next re-render."
  :type 'boolean
  :group 'elneo-room)

(defcustom elneo-room-thread-colors t
  "Color each thread its own hue in the room buffer.
The hue derives from the thread root's event id (a stable hash slot,
like `elneo-room-sender-colors' derives from the user id), so all
replies of one thread share a color while different threads differ —
and the same thread keeps its color across restarts.  The glyph
takes the hue as its foreground, the block tint a faint version of
it as its background, both recomputed against the current theme
background together with the sender colors.  nil renders the one
undivided `elneo-room-thread' face for every thread.

Toggling this off affects newly rendered messages; already-rendered
buffers pick colors up again on their next re-render."
  :type 'boolean
  :group 'elneo-room)

(defcustom elneo-open-file-function #'find-file
  "Function to open a downloaded media file.
Called with the cache file's path by `elneo-room-open-media-at-point'.
With `ready-player-mode' active this just works for images, video
and audio alike; a string-playing alternative is a small wrapper
around `start-process' with mpv."
  :type 'function
  :group 'elneo-room)

(defcustom elneo-msg-save-dir nil
  "Directory \\<elneo-room-mode-map>\\[elneo-room--S] saves media into without asking.
When non-nil, saving a media message copies the file there under its
original name, no prompt.  nil prompts for the destination each
time, defaulting to the media's file name."
  :type '(choice directory (const :tag "Always prompt" nil))
  :group 'elneo-room)

(defface elneo-room-voice-wave
  '((t :inherit shadow))
  "Face for voice-note waveform bars not played yet.
See `elneo-room-voice-wave-played' for the played state."
  :group 'elneo-room)

(defface elneo-room-voice-wave-played
  '((t :inherit font-lock-constant-face))
  "Face for voice-note waveform bars after playing.
The flip is whole-note — external players do not report progress
back, so there is no playhead to move."
  :group 'elneo-room)

(defface elneo-room-video-play
  '((t :inherit button :weight bold))
  "Face for the ▶ mark in a video's inline preview.
A video thumbnail must read as playable, not as an ordinary picture:
this bold link-blue mark sits before the image, and the
\"[video: ...]\" tag stays under it after the fetch."
  :group 'elneo-room)

(defcustom elneo-voice-player-command nil
  "How to play voice messages (`\\[elneo-room--ret]' on the waveform).
nil (default) hands the downloaded file to
`elneo-open-file-function' like any media.  Otherwise the command
started via `start-process' with the cache file appended: a string
(\"mpv\") or a list with arguments (\"mpv\" \"--no-video\")."
  :type '(choice (const :tag "Use elneo-open-file-function" nil)
                 (string :tag "Command")
                 (repeat :tag "Command with arguments" string))
  :group 'elneo-room)

(defvar elneo-voice--played (make-hash-table :test #'equal)
  "Event ids of voice notes played this Emacs session.
Keyed globally: played state survives rebuilds and re-visits.")

(defcustom elneo-room-reply-quote 'text
  "How much of a replied-to message to show in a reply's first line.
`text' (default) quotes sender and body text; media messages show
just an [image]/[file] tag.  `full' additionally renders quoted
media as a real thumbnail.  `none' shows only a marker line.
RET on the quote jumps to the referenced message either way."
  :group 'elneo-room
  :type '(choice (const :tag "Sender and text (media as tag)" text)
                 (const :tag "Full quote, media as thumbnail" full)
                 (const :tag "Marker only" none)))

(defcustom elneo-room-reaction-emoji-options '("👍" "❤" "😂" "🎉" "😢" "🚀")
  "Emoji offered first when reacting with `a'.
Free-form input is accepted as the reaction key too."
  :group 'elneo-room
  :type '(repeat string))

(defcustom elneo-room-redaction-history nil
  "When non-nil, keep the original of locally seen redacted messages.
The buffer always shows a [redacted] marker; with this on, the
original stays retrievable — reveal it with
`elneo-room-reveal-redaction', and a copy is appended to
redactions.jsonl in the profile's data directory so reveals keep
working after a restart.

Redaction is the sender asking clients to forget the content: this
setting deliberately keeps it anyway, so it is OFF by default.  The
log is local to this machine; nothing is ever re-sent to the server."
  :group 'elneo-room
  :type 'boolean)

(defcustom elneo-room-block-send-when-offline t
  "While the room's daemon cannot reach its homeserver, refuse RET.
The daemon's send queue retries indefinitely, so sending while
\"offline\"/\"error\" silently accumulates a backlog; with this ON
(the default) a send is refused and the draft kept — try again once
the daemon syncs.  Set to nil for fire-and-forget sending.  A slow
sync (\"syncing\"/\"starting\") never blocks."
  :group 'elneo-room
  :type 'boolean)

(defcustom elneo-room-forward-cross-account t
  "Whether a forward may target another registered account's room.
Forwards are honest new sends: with a cross-account target the
message goes out from that account — text as its own message,
media re-uploaded through that account's daemon — which is the
only thing a forward can be in Matrix, but the sender identity
differs from the one you read it in.  With this nil the pick in
`elneo-room-forward' offers only the forwarding account's rooms."
  :group 'elneo-room
  :type 'boolean)

(defcustom elneo-room-jump-page-limit 5
  "Older history pages fetched at most while jumping to a reply
parent that is not loaded yet."
  :group 'elneo-room
  :type 'integer)

;; Declared separately and assigned with setq: a plain `defvar' with an
;; initial value keeps the OLD keymap object when the file is reloaded,
;; leaving existing buffers without the current bindings.
(defvar elneo-room-mode-map nil
  "Keymap for Matrix room buffers; rebuilt on reload.")

(setq elneo-room-mode-map
      (let ((map (make-sparse-keymap)))
        (define-key map "\r" #'elneo-room--ret)
        (define-key map (kbd "C-j") #'elneo-room--input-newline)
        ;; M-RET previews the draft the way it would be sent (telega's
        ;; input-preview key); <M-return> is the same for GUI key events.
        ;; telega's attach key is C-c C-a; C-c C-i stays as an alias.
        (define-key map (kbd "C-c C-a") #'elneo-room-attach)
        (define-key map (kbd "C-c C-i") #'elneo-room-attach)
        (define-key map (kbd "C-c C-d") #'elneo-room-attach-dired)
        (define-key map (kbd "C-c C-c") #'elneo-room-send)
        (define-key map (kbd "<prior>") #'elneo-room-older)
        (define-key map (kbd "o") #'elneo-room--o)
        (define-key map (kbd "v") #'elneo-room--v)
        (define-key map (kbd "w") #'elneo-room--w)
        ;; telega copies message text with `c'; the permalink sits on `l'.
        (define-key map (kbd "c") #'elneo-room--c)
        (define-key map (kbd "l") #'elneo-room--l)
        ;; M-p walks back to the previous own message and starts editing
        ;; it (telega's edit-prev); a plain key so it works in the draft.
        (define-key map (kbd "M-p") #'elneo-room--edit-previous)
        (define-key map (kbd "M-RET") #'elneo-room-preview-draft)
        (define-key map (kbd "<M-return>") #'elneo-room-preview-draft)
        ;; `i' stays reserved for telega's describe-message; retry media
        ;; lives on I.
        (define-key map (kbd "I") #'elneo-room--I)
        (define-key map (kbd "q") #'elneo-room--q)
        (define-key map (kbd "r") #'elneo-room--r)
        (define-key map (kbd "a") #'elneo-room--a)
        (define-key map (kbd "d") #'elneo-room--d)
        (define-key map (kbd "e") #'elneo-room--e)
        ;; `m' stays reserved for telega's mark-message; room settings
        ;; (telega's describe-chat) live on C-c ?.
        (define-key map (kbd "C-c ?") #'elneo-room-settings)
        (define-key map (kbd "C-c C-r") #'elneo-room-refetch)
        (define-key map (kbd "C-c C-m") #'elneo-room-actions)
        ;; `t' opens the thread (MSC3440); the old rich-body toggle that
        ;; sat on `t' moved to `y'.
        (define-key map (kbd "t") #'elneo-room--t)
        (define-key map (kbd "y") #'elneo-room--y)
        (define-key map (kbd "T") #'elneo-room--T)
        (define-key map (kbd "A") #'elneo-room--A)
        ;; telega saves media with `s'; S stays as an alias.
        (define-key map (kbd "s") #'elneo-room--s)
        (define-key map (kbd "S") #'elneo-room--S)
        (define-key map (kbd "R") #'elneo-room--R)
        (define-key map (kbd "K") #'elneo-room--K)
        ;; Pinning: `^' toggles the message at point on the room's
        ;; m.room.pinned_events list (telega pins with ^); the mark renders
        ;; from the summary echo (protocol 22).
        (define-key map (kbd "^") #'elneo-room--pin)
        ;; telega's forward; the room pick completes across all accounts
        ;; (unless elneo-room-forward-cross-account is nil).
        (define-key map (kbd "f") #'elneo-room--f)
        ;; Polls: `p' votes in the poll at point, `P' creates one, `E'
        ;; ends the one at point (its creator).
        (define-key map (kbd "p") #'elneo-room--p)
        (define-key map (kbd "P") #'elneo-room--P)
        (define-key map (kbd "E") #'elneo-room--E)
        (define-key map (kbd "=") #'elneo-room-show-edit-history)
        (define-key map (kbd "C-c C-k") #'elneo-room-cancel-reply)
        ;; @-mention completion: the picker runs in the draft over the
        ;; `@'-fragment before point; in the history area it does nothing.
        ;; TAB here shadows the draft's normal self-insert — a literal tab
        ;; in a message needs C-q TAB.
        (define-key map (kbd "TAB") #'elneo-room--complete-mention)
        ;; The room bar's options menu (sorting, filters, layout) —
        ;; global state, so it works from a chat buffer too.  C-c C-o is
        ;; reserved for telega's chatbuf input options.
        (define-key map (kbd "C-c C-b") #'elneo-room-bar-options)
        map))

(defvar elneo-room--buffers (make-hash-table :test 'equal)
  "Hash mapping (PROFILE . ROOM-ID) to the room's buffer.")

;;; Window selection

(defun elneo-room--main-window (&optional frame)
  "The largest non-side window on FRAME (the selected frame by default).
Side windows (the room bar, and anything else the user pinned)
are never candidates; user splits in the main area are preserved
because a window is reused, not replaced."
  (let* ((candidates
          (cl-remove-if
           (lambda (w)
             (or (window-parameter w 'window-side)
                 (window-minibuffer-p w)))
           (window-list (or frame (selected-frame)) 'no-minibuf)))
         (best (car (sort candidates
                          (lambda (a b)
                            (> (window-total-size a)
                               (window-total-size b)))))))
    (or best (split-window (frame-root-window (or frame (selected-frame)))))))

;; elneo-room-bar is loaded at runtime to avoid a load cycle: the
;; invite prompt runs only via the bar's `elneo-room-open', so the bar
;; is always present by then.
(declare-function elneo-room-open "elneo-room-bar" (room &optional stay-put))
(declare-function elneo-space-browse "elneo-space" (profile room-id))
(declare-function elneo-room-bar-find-display "elneo-room-bar" ())
(declare-function elneo-room-bar-options "elneo-room-bar" ())
(declare-function elneo-room-actions-dispatch "elneo-transient" ())
(declare-function elneo-dired-pick-for-buffer "elneo-dired"
                  (room-buffer dir))
(declare-function elneo-avatar-show "elneo-image" (profile mxc))
(declare-function eyebrowse--get "eyebrowse" (type &optional frame))
(declare-function eyebrowse-switch-to-window-config "eyebrowse" (slot))



;; Declared before the referent so byte-compile stays quiet; the
;; alias's boolean values are normalized by `elneo-room--frame-policy'.
(define-obsolete-variable-alias 'elneo-room-jump-sidebar
  'elneo-room-open-frame-policy "0.1.0")
(defcustom elneo-room-open-frame-policy 'beside-local-bar
  "How room buffers are placed relative to the room bar and frames.
`beside-local-bar' (the default) opens a room in a main window
next to the bar window of the frame it is opened from; when that
frame shows no bar and `elneo-room-open-show-bar' is non-nil,
the bar is shown here first.  With show-bar off (or without
elneo-room-bar loaded), the room follows a bar displayed
anywhere else — and, with eyebrowse, parked on its workspace —
falling back to the current frame when there is none.
`follow-bar' always jumps to the display showing the bar;
`here' never leaves the current frame or workspace and never
touches the bar.
The obsolete boolean `elneo-room-jump-sidebar' maps through this
variable: t behaves as `follow-bar', nil as `here'.  Only frames
of this Emacs instance are reachable.
Under `beside-local-bar' and `here' a room open never raises a
frame or switches eyebrowse workspaces: a bar parked in another
slot of the current frame counts as \"not here\" and may spawn a
second bar in the current slot.  Only a `jump' (from `follow-bar'
or the `beside-local-bar' fallback) raises the target frame and
switches to the slot that parks the bar.  Note that showing the
bar on a frame may reuse that frame's existing side window on the
chosen side, whatever it displays."
  :type '(choice (const :tag "Beside the current frame's room bar" beside-local-bar)
                 (const :tag "Follow the room bar anywhere" follow-bar)
                 (const :tag "Always the current frame" here))
  :group 'elneo-room)

(defun elneo-room--frame-policy ()
  "The effective frame policy as a symbol.
Normalizes values inherited through the obsolete
`elneo-room-jump-sidebar' alias (t -> `follow-bar', nil ->
`here') and anything unrecognized to the default."
  (let ((v elneo-room-open-frame-policy))
    (cond ((eq v t) 'follow-bar)
          ((eq v nil) 'here)
          ((memq v '(beside-local-bar follow-bar here)) v)
          (t 'beside-local-bar))))



(defcustom elneo-room-open-show-bar t
  "Show the room bar when a room opens on a frame without one.
Under `beside-local-bar', a room opened on a frame showing no bar
creates the bar side window on that frame first, and the room
opens next to it — per frame, without touching the bar's other
homes.  Note this may reuse a same-side side window other than
the bar on that frame."
  :type 'boolean
  :group 'elneo-room)

(defun elneo-room--route-decision (policy stay-put show-bar bar-here-p bar-display)
  "The routing core, pure and frame-free so it is unit-testable.
POLICY is a normalized symbol; STAY-PUT is the prefix-arg
override (\"right where we are\"); SHOW-BAR is
`elneo-room-open-show-bar'; BAR-HERE-P says the current frame
shows a bar window; BAR-DISPLAY is `elneo-room-bar-find-display'
result or nil.  Returns `here', `beside', `show-beside', or
\\(jump FRAME . SLOT)."
  (cond
   (stay-put 'here)
   ((eq policy 'here) 'here)
   ((eq policy 'follow-bar)
    (if bar-display (cons 'jump bar-display) 'here))
   (t                                   ; beside-local-bar
    (cond
     (bar-here-p 'beside)
     (show-bar 'show-beside)
     (bar-display (cons 'jump bar-display)) ; legacy fallback
     (t 'here)))))

(declare-function elneo-room-bar--window-in-frame "elneo-room-bar"
                  (&optional frame))
(declare-function elneo-room-bar-ensure-on-frame "elneo-room-bar"
                  (&optional frame))

(defun elneo-room--route (&optional stay-put)
  "Decide how to display a room, honoring the STAY-PUT prefix override.
Calls `elneo-room-bar-find-display' only when a jump can still
win the decision: the parked-workspace scan must not pay for
opens it can never influence."
  (let ((policy (elneo-room--frame-policy))
        (bar-here (and (fboundp 'elneo-room-bar--window-in-frame)
                       (elneo-room-bar--window-in-frame))))
    (elneo-room--route-decision
     policy stay-put elneo-room-open-show-bar bar-here
     (when (and (not stay-put)
                (not (eq policy 'here))
                (not (and (eq policy 'beside-local-bar)
                          (or bar-here elneo-room-open-show-bar))))
       (and (fboundp 'elneo-room-bar-find-display)
            (elneo-room-bar-find-display))))))

(defun elneo-room--display-room-buffer (buffer &optional stay-put)
  "Show BUFFER per `elneo-room-open-frame-policy'.
With STAY-PUT non-nil (a universal prefix on the calling
command), open right where we are: the current frame, no raise,
no workspace switch, no bar creation.  Under the policy, only a
`jump' decision — the bar lives elsewhere, or `follow-bar'
sends us after the bar — raises a frame and switches to its
eyebrowse workspace; local decisions (`beside', `show-beside',
`here') display BUFFER in the current frame's main window, with
`show-beside' creating the bar side window on this frame first.
Returns the window now displaying BUFFER."
  (pcase (elneo-room--route stay-put)
    (`(jump . ,target)
     (let ((frame (car target)))
       (unless (eq frame (selected-frame))
         (select-frame-set-input-focus frame))
       ;; The bar is behind a workspace switch on the target frame:
       ;; switch back to it before looking for the main window.
       (let ((slot (cdr target)))
         (when (and slot
                    (not (equal slot (eyebrowse--get 'current-slot frame))))
           (eyebrowse-switch-to-window-config slot)))
       (let ((window (elneo-room--main-window frame)))
         (set-window-buffer window buffer)
         (select-window window))))
    (route
     (when (and (eq route 'show-beside)
                (fboundp 'elneo-room-bar-ensure-on-frame))
       (elneo-room-bar-ensure-on-frame))
     (let ((window (elneo-room--main-window)))
       (set-window-buffer window buffer)
       (select-window window)))))

;;; Buffer / mode

(defun elneo-room--buffer-name (room)
  "Buffer name for room record ROOM."
  (format "*Matrix: %s:%s*"
          (plist-get room :profile)
          (or (plist-get room :display-name) (plist-get room :room-id))))

(defun elneo-room--seed-locals (profile room-id)
  "Seed the buffer-locals a fresh message buffer starts from.
The common contract of a room buffer (`elneo-room--buffer') and a
thread view (`elneo-thread-open'); each adds its own locals around
it.  The draft pair STAYS OUT: a room restores its draft from the
disk store, a thread view never saves one and seeds the empty pair."
  (setq-local elneo-room--profile profile)
  (setq-local elneo-room--room-id room-id)
  (setq-local elneo-room--end-token nil)
  (setq-local elneo-room--seen (make-hash-table :test 'equal))
  (setq-local elneo-room--reactions (make-hash-table :test 'equal))
  (setq-local elneo-room--receipts (make-hash-table :test 'equal))
  (setq-local elneo-room--read-check-id nil)
  (setq-local elneo-room--reply-to nil)
  (setq-local elneo-room--reply-sender nil)
  (setq-local elneo-room--edit-to nil)
  (setq-local elneo-room--pinned nil)
  (setq-local elneo-room--edit-history (make-hash-table :test 'equal))
  (setq-local elneo-room--jump-target nil)
  (setq-local elneo-room--jump-pages 0)
  (setq-local elneo-room--pending-jump-event-id nil)
  (setq-local elneo-room--backfilled nil)
  (setq-local elneo-room--media-pending (make-hash-table :test 'equal))
  (setq-local elneo-room--history-retries 0)
  (setq-local elneo-room--older-mode 'anchor))

(defun elneo-room--buffer (room)
  "Return (creating if needed) the buffer for room record ROOM."
  (let* ((key (cons (plist-get room :profile) (plist-get room :room-id)))
         (buffer (gethash key elneo-room--buffers)))
    (or (and (buffer-live-p buffer) buffer)
        (let ((buffer (generate-new-buffer (elneo-room--buffer-name room))))
          (puthash key buffer elneo-room--buffers)
          (with-current-buffer buffer
            (elneo-room-mode)
            (elneo-room--seed-locals (plist-get room :profile)
                                     (plist-get room :room-id))
            ;; Draft restored from disk (if any): the first render moves
            ;; it into the input area.  saved-text starts equal to it so
            ;; an untouched restored draft does not trigger a rewrite.
            (setq-local elneo-room--pending-draft
                        (gethash key (elneo-room--draft-store)))
            (setq-local elneo-room--draft-saved-text
                        elneo-room--pending-draft))
          buffer))))

(defun elneo-room--buffer-for (profile room-id)
  "Live buffer for PROFILE's ROOM-ID, or nil."
  (let ((buffer (gethash (cons profile room-id) elneo-room--buffers)))
    (and (buffer-live-p buffer) buffer)))

(defvar-local elneo-room--profile nil
  "Buffer-local: the profile this room buffer belongs to.")

(defvar-local elneo-room--room-id nil
  "Buffer-local: the room id this buffer renders.")

(defvar-local elneo-room--thread-root nil
  "Buffer-local: the root event id of the thread (MSC3440) this
buffer renders — non-nil only inside a thread view.
A thread view never marks the room read (per-thread receipts are a
later slice): the read-mark passes, the draft store and the edit
command gate on this.")

(defvar-local elneo-room--prepend-point nil
  "Buffer-local: marker where older history pages prepend, or nil
for the very top of the buffer.  A thread view sets it just below
the pinned root: the root stays first while pages of replies flow
past it topward.  Insertion-type nil (copy-marker's default, re-set
per render): each prepend lands at the marker with the marker left
before the fresh page, so the next page inserts beside the root
again and pages stack oldest-on-top.")

(defvar-local elneo-room--end-token nil
  "Buffer-local: token for the next (older) history page, or nil
when history is exhausted.")

(defvar-local elneo-room--seen nil
  "Buffer-local: hash of event ids already rendered here.")

(defvar-local elneo-room--receipts nil
  "Buffer-local: hash of user id -> plist (:user-id :user-name
:event-id :ts :target-ts), the other members' latest public m.read
receipts in this room.  :ts is when they read; :target-ts is the
target event's origin-server timestamp (its timeline position),
resolved by the daemon or nil when it has not seen the event.")

(defvar-local elneo-room--read-check-id nil
  "Buffer-local: event id of the own message currently carrying the
✓✓ read mark, or nil.")

(defvar-local elneo-room--last-event-id nil
  "Buffer-local: event id of the newest event seen here.
Not just rendered messages: reactions, poll votes and edits
advance it too, so a read mark sent here covers everything the
server counts unread — see `elneo-room--advance-read-marker'.")

(defvar-local elneo-room--backfilled nil
  "Buffer-local: non-nil once the first history page has landed.")

(defvar-local elneo-room--loading-older nil
  "Buffer-local: non-nil while an older history page is in flight.")

(defvar-local elneo-room--older-last nil
  "Buffer-local: time of the last older-page request.
Rate-limits the auto-load triggered at the top of the buffer.")

(defvar-local elneo-room--older-mode nil
  "Buffer-local: how the next older page should land.
`anchor' keeps the first visible message stable (auto-load from
wheel-up); `scroll' moves the view up into the fresh page (PageUp,
M-<).  Consumed by `elneo-room--on-history'.")

(defvar-local elneo-room--keys-timer nil
  "Buffer-local: debounce timer for the room-keys re-backfill.")

(defvar-local elneo-room--media-pending nil
  "Buffer-local: hash of event ids with a media fetch in flight.")

(defvar-local elneo-room--reactions nil
  "Buffer-local: hash of event id -> aggregated reaction plists.
(:key KEY :count N :own BOOL) — updated live and on page loads.")

(defvar-local elneo-room--reply-to nil
  "Buffer-local: event id the draft replies to, when in reply mode.")

(defvar-local elneo-room--reply-sender nil
  "Buffer-local: display name of the replied-to sender, for the separator.")

(defvar-local elneo-room--edit-to nil
  "Buffer-local: event id the draft edits, when in edit mode.")

(defvar-local elneo-room--pinned nil
  "Buffer-local: the room's pinned event ids (protocol 22).
Rendered from the record's list (`elneo-room--on-pinned-update'
keeps it current); the rider consults it live, so pins that arrive
with a later history page still get their mark.")

(defvar-local elneo-room--edit-history nil
  "Buffer-local: hash of event id -> ((TS . BODY) ...) of older versions.
Only versions seen as live edits in this buffer are remembered; the
newest version always renders in place.  `=' pops them up.")

(defvar-local elneo-room--jump-target nil
  "Buffer-local: event id a RET-on-quote jump is searching for.")

(defvar-local elneo-room--pending-jump-event-id nil
  "Buffer-local: event id to jump to once the first history page
lands.  Set by `elneo-room-jump-to-event' for a room whose buffer
has not rendered yet; `elneo-room--render-first-page' consumes it.")

(defvar-local elneo-room--jump-pages 0
  "Buffer-local: older pages fetched so far for a pending jump.")

(defvar-local elneo-room--history-retries 0
  "Buffer-local: how many times a failed first page has been retried.")

(defcustom elneo-room-history-retries-max 6
  "How many times a failed first history page retries itself.
A fresh daemon rejects history until its first sync has seeded the
rooms; the retries are spaced out over that startup (doubling from
2s, capped), each a shorter tail than a user waiting for a buffer
to fill."
  :type 'natnum
  :group 'elneo-room)

(defvar-local elneo-room--notice nil
  "Buffer-local: one-line failure notice under the room header.
Set by a first history page or render that failed; cleared when
history lands.  Rendered by `elneo-room--header', and inserted on
the spot into a buffer too empty to render anything of its own,
so a room buffer never just stares back.")

(defvar-local elneo-room--append-point nil
  "Buffer-local: marker before the blank line ending the history.
Live messages are inserted there; it advances past inserted text.")

(defvar-local elneo-room--input-beg nil
  "Buffer-local: marker at the start of the writable draft area.")

(define-derived-mode elneo-room-mode fundamental-mode "Matrix Room"
  "Major mode for a Matrix room buffer.
The buffer ends in a writable input area: RET there sends the
draft, C-j adds a newline, and \\[elneo-room-attach] attaches an
image.  \\[elneo-room-send] (also RET on the history) prompts in
the minibuffer; \\[elneo-room-older] pages up through history.
Scrolling to the top (mouse wheel up, \\[beginning-of-buffer])
loads older pages.  Dropping local files onto the buffer attaches
them the same way (tags into the draft, nothing sent until RET)."

  ;; The history is read-only via text properties so the draft area
  ;; stays writable (this mode derives from `fundamental-mode': the
  ;; `special-mode' parent remaps all self-inserting keys to
  ;; `undefined' and binds h/g/space/digits, which would break typing).
  (setq buffer-read-only nil)
  ;; Word wrap plus the per-block `wrap-prefix' keeps soft-wrapped
  ;; continuation lines indented to the body column, matching the hard
  ;; newlines inside messages (laid by `elneo-room--append-messages').
  (setq-local word-wrap t)
  (add-hook 'post-command-hook #'elneo-room--post-command nil t)
  (add-hook 'kill-buffer-hook #'elneo-room--draft-kill-save nil t)
  ;; Spell-checking other people's messages is noise: opt out of plain
  ;; global-flyspell, and of any global `after-change-major-mode-hook'
  ;; that force-enables it — honour the user's own blacklist if they
  ;; have one (e.g. `aard/enable-flyspell-unless-blacklisted').
  (when (fboundp 'flyspell-mode) (flyspell-mode -1))
  (when (boundp 'aard/flyspell-major-mode-blacklist)
    (cl-pushnew 'elneo-room-mode aard/flyspell-major-mode-blacklist))
  ;; Drops: room buffers accept local files (attached into the draft);
  ;; every other buffer — bar, minibuffer — keeps the default behavior
  ;; (open the file).  `dnd.el' reads this buffer-local alist for the
  ;; drop window's buffer (`dnd-handle-multiple-urls' runs the handler
  ;; `with-selected-window').  The pattern must cover all the file URL
  ;; shapes an OS hands over — `file:///path', `file:/path' (seen from
  ;; macOS promised-file drags, e.g. screenshot thumbnails) and
  ;; `file://localhost/path' — because anything dnd.el cannot assign a
  ;; handler for is *inserted into the buffer as text* (its documented
  ;; fallback), so a narrow pattern literally ships the raw URL into
  ;; the draft.  Unmatched shapes stay in the handler: it decides per
  ;; URL and always answers non-nil for file URLs, which again keeps
  ;; the dnd-insert-text fallback from firing.
  (setq-local dnd-protocol-alist '(("^file:" . elneo-room-dnd-receive))))

(defun elneo-room--invalidate-on-activate (profile)
  "Reset daemon-dependent history state of PROFILE's room buffers.
Buffers keep their `backfilled' flag across a daemon restart, which
used to make the first room entry after a restart show stale
content; invalidate so the next (re-)entry fetches fresh history."
  (maphash (lambda (_key buffer)
             (when (and (buffer-live-p buffer)
                        (equal (buffer-local-value 'elneo-room--profile buffer)
                               profile))
               (with-current-buffer buffer
                 (setq elneo-room--backfilled nil
                       elneo-room--end-token nil
                       elneo-room--history-retries 0
                       elneo-room--jump-target nil
                       elneo-room--jump-pages 0
                       elneo-room--notice nil)
                 (when (hash-table-p elneo-room--reactions)
                   (clrhash elneo-room--reactions))
                 ;; Receipt state is daemon-side too: the seed pass
                 ;; after the next backfill refills it.
                 (when (hash-table-p elneo-room--receipts)
                   (clrhash elneo-room--receipts))
                 (setq elneo-room--read-check-id nil)
                 ;; A room that is being looked at should refresh on its
                 ;; own; the fetch may land before the daemon seeded the
                 ;; rooms, in which case the retry logic catches it.
                 (when (get-buffer-window buffer t)
                   (elneo-room--backfill 50)))))
           elneo-room--buffers)
  ;; Thread views keep the same daemon-dependent history state, and the
  ;; room's fetch covers room buffers only — their re-open otherwise
  ;; rediscovers the stale content the new daemon knows nothing about.
  (require 'elneo-thread)
  (maphash (lambda (_key buffer)
             (when (and (buffer-live-p buffer)
                        (equal (buffer-local-value 'elneo-room--profile buffer)
                               profile))
               (with-current-buffer buffer
                 (setq elneo-room--backfilled nil
                       elneo-room--end-token nil
                       elneo-room--history-retries 0
                       elneo-room--jump-target nil
                       elneo-room--jump-pages 0
                       elneo-room--notice nil)
                 (when (hash-table-p elneo-room--reactions)
                   (clrhash elneo-room--reactions))
                 (setq elneo-room--read-check-id nil)
                 ;; The next first-page fetch re-renders the whole view
                 ;; (elneo-thread--on-history takes the render branch).
                 (when (get-buffer-window buffer t)
                   (elneo-thread--fetch-first-page)))))
           elneo-thread--buffers))
(add-hook 'elneo-session-activated-hook #'elneo-room--invalidate-on-activate)

(defun elneo-room--header (room)
  "Insert the room header (name, alias/topic) for ROOM."
  ;; Anon mode fakes a render copy (name, alias/topic); the registry
  ;; record stays real.
  (let* ((room (if elneo-anon-mode (elneo-anon--room room) room))
         (inhibit-read-only t)
         (name (or (plist-get room :display-name) (plist-get room :room-id)
                   "Room"))
         (sub (or (plist-get room :alias) (plist-get room :topic))))
    (insert (propertize name 'face 'header-line ':weight 'bold) "\n")
    (when (and sub (> (length sub) 0))
      (insert (propertize sub 'face 'shadow) "\n"))
    (when elneo-room--notice
      (insert (propertize elneo-room--notice 'face 'error) "\n"))
    (insert "\n")))

;;; Rendering

(defun elneo-room--format-ts (ts)
  "Format a millisecond timestamp TS as HH:MM."
  (format-time-string "%H:%M" (/ ts 1000)))

(defun elneo-room--day (ts)
  "Local date string for millisecond timestamp TS."
  (format-time-string "%Y-%m-%d" (/ ts 1000)))

(defun elneo-room--insert-day-separator (ts)
  "Insert a day separator for local date of millisecond timestamp TS."
  (let ((inhibit-read-only t))
    ;; Only the date itself carries the face — the blank line before it
    ;; must stay unpropertized so no face attribute ever shows there.
    (insert "\n"
            (propertize (elneo-room--day ts)
                        'face 'elneo-room-day-separator)
            "\n")))

(defun elneo-room--sender-name (msg)
  "Display name for message plist MSG."
  (or (plist-get msg :sender-name)
      (plist-get msg :sender) "?"))

;;; Sender name colors

;; Matrix has no per-user color in the spec; each client derives one
;; locally.  We hash the user id into a fixed set of hue "buckets", each
;; backed by a named face — so a theme change only has to recompute the
;; bucket faces' foregrounds and every already-rendered sender name
;; recolors with them, no buffer re-render needed.

(defconst elneo-room--sender-color-count 12
  "Distinct sender hues.  Two users may share a hue; that is fine.")

(defconst elneo-room--color-contrast 131000
  "Minimum `color-distance' between a sender color and the background.
Emacs' color metric is coarse (it quantizes channels), so readable
pairs sit clearly above this and washed-out pairs near zero.")

(defvar elneo-room--sender-faces nil
  "Bucket faces for colored sender names, created lazily.")

(defvar elneo-room--sender-face-bg nil
  "Background the sender bucket colors were last computed against.")

(defun elneo-room--hex-rgb (color)
  "RGB components (0..1 floats) of a #RGB/#RRGGBB/#RRRRGGGGBBBB string.
Parsing hex directly: `color-name-to-rgb' consults the frame color
map and returns nonsense in batch sessions."
  (when (and (stringp color)
             (string-match
              "^#\\([0-9a-fA-F]\\{3\\}\\|[0-9a-fA-F]\\{6\\}\\|[0-9a-fA-F]\\{12\\}\\)$"
              color))
    (let* ((hex (match-string 1 color))
           (width (/ (length hex) 3))
           (scale (float (1- (expt 16 width))))
           (rgb nil))
      (dotimes (i 3)
        (push (/ (string-to-number
                  (substring hex (* i width) (* (1+ i) width)) 16)
                 scale)
              rgb))
      (nreverse rgb))))

(defun elneo-room--bg-rgb (color)
  "RGB components of background COLOR, or nil when unresolvable."
  (or (elneo-room--hex-rgb color)
      ;; Named colors: reliable on GUI frames, may be nil in batch.
      (ignore-errors (color-name-to-rgb color))))

(defun elneo-room--sender-color (hue bg dark)
  "Readable color string for hue HUE (0..1) against background BG.
DARK says BG is dark.  Lightness starts typical for the background
kind and walks further away until the contrast threshold clears."
  (let ((lightness (if dark 0.70 0.40))
        (step (if dark 0.04 -0.04))
        (limit (if dark 0.90 0.22))
        hex)
    (catch 'done
      (while t
        (setq hex (apply #'color-rgb-to-hex
                         (append (color-hsl-to-rgb
                                  hue (if dark 0.55 0.65) lightness)
                                 '(2))))
        (when (or (>= (color-distance hex bg)
                      elneo-room--color-contrast)
                  ;; <= / >=, not =: lightness walks in 0.04 steps and
                  ;; need not land on the limit exactly — with `=' the
                  ;; loop only ends once contrast happens to clear.
                  (if (>= step 0) (>= lightness limit)
                    (<= lightness limit)))
          (throw 'done hex))
        (setq lightness (+ lightness step))))
    hex))

(defun elneo-room--refresh-sender-colors (&optional bg)
  "(Re)compute the sender bucket faces' foregrounds against BG.
Without BG the current `default' face background is used; nothing
happens when no frame background is resolvable."
  (let* ((bg (or bg (face-background 'default)))
         (rgb (and bg (elneo-room--bg-rgb bg))))
    (when rgb
      (unless elneo-room--sender-faces
        (dotimes (i elneo-room--sender-color-count)
          (let ((face (make-face
                       (intern (format "elneo-room-sender-c%d" i)))))
            (set-face-attribute face nil :inherit 'elneo-room-sender)
            (push face elneo-room--sender-faces)))
        (setq elneo-room--sender-faces (nreverse elneo-room--sender-faces)))
      (let ((dark (color-dark-p rgb)))
        (dotimes (i elneo-room--sender-color-count)
          (set-face-attribute
           (nth i elneo-room--sender-faces) nil :foreground
           (elneo-room--sender-color
            (/ (float i) elneo-room--sender-color-count) bg dark))))
      (setq elneo-room--sender-face-bg bg))))

(defun elneo-room--sender-face (sender)
  "Face for a message SENDER's name.
The bucket face carries a stable color when
`elneo-room-sender-colors' is on; otherwise the plain
`elneo-room-sender'.  Also (re)computes the bucket colors when the
theme background changed since they were last derived."
  (if (or (not elneo-room-sender-colors) (null sender))
      'elneo-room-sender
    (let ((bg (face-background 'default)))
      (if (or (null bg) (null (elneo-room--bg-rgb bg)))
          'elneo-room-sender
        (unless (and elneo-room--sender-faces
                     (equal elneo-room--sender-face-bg bg))
          (elneo-room--refresh-sender-colors bg))
        (nth (elneo-room--sender-bucket sender)
             elneo-room--sender-faces)))))

(defun elneo-room--sender-bucket (sender)
  "Stable color bucket (0..count-1) for SENDER.
Hashes the full user id, so renames keep a user's color."
  (mod (string-to-number (substring (secure-hash 'md5 sender) 0 8) 16)
       elneo-room--sender-color-count))

(defconst elneo-room--thread-color-count 10
  "Slot count for per-thread colors.
Each of a room's live threads takes one hue, so two threads
colliding into the same slot is rare and merely mildly confusing.")

(defvar elneo-room--thread-glyph-faces nil
  "Bucket faces for colored thread glyphs, created lazily.")

(defvar elneo-room--thread-tint-faces nil
  "Bucket faces for colored thread tints, created lazily.")

(defvar elneo-room--thread-face-bg nil
  "Background the thread bucket colors were last computed against.")

(defun elneo-room--thread-slot (root-id)
  "Stable color slot (0..count-1) for the thread rooted at ROOT-ID.
Hashes the root event id, per-thread and restart-stable, like
`elneo-room--sender-bucket' hashes the user id."
  (mod (string-to-number (substring (secure-hash 'md5 root-id) 0 8) 16)
       elneo-room--thread-color-count))

(defun elneo-room--thread-tint-color (hue bg dark)
  "Faint block-tint color for hue HUE (0..1) against background BG.
DARK says BG is dark.  The tint sits one small step away from the
background's own lightness, toward the hue — quiet on both theme
kinds, loud only in distinguishing threads from each other."
  (let* ((hsl (apply #'color-rgb-to-hsl (elneo-room--bg-rgb bg)))
         (bl (nth 2 hsl))
         (lightness (max 0.02
                         (min 0.98
                              (if dark (+ bl 0.07) (- bl 0.05))))))
    (apply #'color-rgb-to-hex
           (append (color-hsl-to-rgb hue 0.45 lightness) '(2)))))

(defun elneo-room--refresh-thread-colors (&optional bg)
  "(Re)compute the thread glyph and tint faces against BG.
Without BG the current `default' face background is used; nothing
happens when no frame background is resolvable.  Same derivation as
`elneo-room--refresh-sender-colors': hue buckets rendered readable
on light and dark themes alike."
  (let* ((bg (or bg (face-background 'default)))
         (rgb (and bg (elneo-room--bg-rgb bg))))
    (when rgb
      (unless elneo-room--thread-glyph-faces
        (dotimes (i elneo-room--thread-color-count)
          (let ((face (make-face
                       (intern (format "elneo-room-thread-c%d" i)))))
            (set-face-attribute face nil :inherit 'elneo-room-thread)
            (push face elneo-room--thread-glyph-faces)))
        (setq elneo-room--thread-glyph-faces
              (nreverse elneo-room--thread-glyph-faces)))
      (unless elneo-room--thread-tint-faces
        (dotimes (i elneo-room--thread-color-count)
          (let ((face (make-face
                       (intern (format "elneo-room-thread-t%d" i)))))
            (set-face-attribute face nil :inherit 'elneo-room-thread)
            (push face elneo-room--thread-tint-faces)))
        (setq elneo-room--thread-tint-faces
              (nreverse elneo-room--thread-tint-faces)))
      (let ((dark (color-dark-p rgb)))
        (dotimes (i elneo-room--thread-color-count)
          (let ((hue (/ (float i) elneo-room--thread-color-count)))
            (set-face-attribute
             (nth i elneo-room--thread-glyph-faces) nil :foreground
             (elneo-room--sender-color hue bg dark))
            (set-face-attribute
             (nth i elneo-room--thread-tint-faces) nil :background
             (elneo-room--thread-tint-color hue bg dark)))))
      (setq elneo-room--thread-face-bg bg))))

(defun elneo-room--thread-face (root-id)
  "Glyph face for the thread rooted at ROOT-ID.
The bucket face carries a stable hue when
`elneo-room-thread-colors' is on; otherwise the plain
`elneo-room-thread'.  Derived against the current theme background
along with the sender colors."
  (if (or (not elneo-room-thread-colors) (null root-id))
      'elneo-room-thread
    (let ((bg (face-background 'default)))
      (if (or (null bg) (null (elneo-room--bg-rgb bg)))
          'elneo-room-thread
        (unless (and elneo-room--thread-glyph-faces
                     (equal elneo-room--thread-face-bg bg))
          (elneo-room--refresh-thread-colors bg))
        (nth (elneo-room--thread-slot root-id)
             elneo-room--thread-glyph-faces)))))

(defun elneo-room--thread-tint-face (root-id)
  "Block-tint face for the thread rooted at ROOT-ID.
The bucket face's background is a faint version of
`elneo-room--thread-face''s hue.  nil when coloring is off or no
frame background is resolvable — the plain `elneo-room-thread'
tint, exactly as before."
  (unless (or (not elneo-room-thread-colors) (null root-id))
    (let ((bg (face-background 'default)))
      (when (and bg (elneo-room--bg-rgb bg))
        (unless (and elneo-room--thread-tint-faces
                     (equal elneo-room--thread-face-bg bg))
          (elneo-room--refresh-thread-colors bg))
        (nth (elneo-room--thread-slot root-id)
             elneo-room--thread-tint-faces)))))

(defun elneo-room--theme-changed (&rest _)
  "Recompute sender and thread colors after a theme change.
Emacs has no theme-change hook; `load-theme'/`enable-theme'/
`disable-theme' are advised here instead."
  (when elneo-room--sender-faces
    (elneo-room--refresh-sender-colors))
  (when elneo-room--thread-glyph-faces
    (elneo-room--refresh-thread-colors)))

(advice-add 'load-theme :after #'elneo-room--theme-changed)
(advice-add 'enable-theme :after #'elneo-room--theme-changed)
(advice-add 'disable-theme :after #'elneo-room--theme-changed)

(defconst elneo-room--ts-width 6
  "Columns of the \"HH:MM \" timestamp prefix on every message line.")

(defconst elneo-room--avatar-width 2
  "Columns of the avatar cell (before its trailing space).")

(defun elneo-room--body-column ()
  "Column where message bodies start (after time and sender).
The avatar column, when `elneo-room-avatars' is on in this buffer,
shifts the whole layout right accordingly — hard newlines, soft-wrap
continuations and reply/image second lines all line up with it."
  (+ (if elneo-room-avatars (1+ elneo-room--avatar-width) 0)
     elneo-room--ts-width elneo-room-sender-width 1))

(defun elneo-room--pad-to-width (text width)
  "TEXT padded with spaces to display WIDTH columns.
Padding by `format %-Ns' counts characters, so CJK senders (wider
per character) would misalign the body column."
  (concat text
          (make-string (max 0 (- width (string-width text))) ?\s)))

(defun elneo-room--indent-newlines (text)
  "TEXT with hard newlines indented to the body column.
Soft-wrapped continuation lines indent via the message block's
`wrap-prefix'; this lines up the hard newlines a sender typed the
same way."
  (replace-regexp-in-string
   "\n" (concat "\n" (make-string (elneo-room--body-column) ?\s))
   text))

(defun elneo-room--indent-region-newlines (beg end)
  "Indent the hard newlines between BEG and END to the body column.
The property-preserving variant for rendered rich bodies; END may
move as text is inserted (markers track it, numbers do not — pass a
marker)."
  (let ((inhibit-read-only t)
        (end (if (markerp end) end (copy-marker end))))
    (save-excursion
      (goto-char beg)
      (while (search-forward "\n" end t)
        (when (< (point) (marker-position end))
          (insert (make-string (elneo-room--body-column) ?\s)))))))

(defun elneo-room--wrap-prefix ()
  "The `wrap-prefix' string for message blocks: body-column spaces.
Soft-wrapped continuation lines render with it; the first line is
never prefixed, and the draft area keeps the full window width."
  (make-string (elneo-room--body-column) ?\s))

;;; Sender avatars

(defun elneo-room--avatar-image-cell (file)
  "Avatar-width image cell for a downloaded avatar FILE, or nil.
nil when this Emacs cannot display images (terminal frame, batch)."
  (when-let* ((image (elneo-client--avatar-image file elneo-room--avatar-width)))
    (propertize (make-string elneo-room--avatar-width ?\s)
                'display image)))

(defun elneo-room--avatar-cell (msg)
  "The avatar prefix cell (with trailing space) for MSG.
An image cell once the sender's avatar has downloaded, a colored
initial until then and when the sender has none.  Only meaningful
with `elneo-room-avatars' on; placeholder cells carry the avatar's
MXC so the arrival pass can swap the image in place."
  (let* ((sender (plist-get msg :sender))
         (mxc (plist-get msg :sender-avatar))
         (img (and mxc (elneo-room--avatar-image-cell
                        (elneo-client--avatar-file mxc))))
         (name (elneo-room--sender-name msg))
         (initial (if (> (length name) 0) (substring name 0 1) "?")))
    (if img
        (concat (propertize img 'elneo-room-avatar-image t) " ")
      (let ((cell (propertize
                   (elneo-room--pad-to-width
                    initial elneo-room--avatar-width)
                   'face (elneo-room--sender-face sender)
                   'elneo-room-avatar-user sender)))
        (when mxc
          ;; Fetch target property, so the arrival pass finds every
          ;; placeholder of this avatar.  The fetch itself is deduped
          ;; per MXC — one sender with fifty rendered messages
          ;; downloads once.
          (setq cell (propertize cell 'elneo-room-avatar-src mxc))
          (elneo-room--ensure-avatar mxc))
        (concat cell " ")))))

(defun elneo-room--ensure-avatar (mxc)
  "Fetch avatar MXC unless it is downloaded or already in flight."
  (unless (or (gethash mxc elneo-client--avatar-cache)
              (gethash mxc elneo-client--avatar-pending))
    (elneo-client-fetch-avatar
     elneo-room--profile mxc
     (lambda (_profile _event)
       (elneo-room--avatars-arrived)))))

(defun elneo-room--avatars-arrived ()
  "Swap downloaded avatar images into every open room buffer."
  (dolist (buffer (hash-table-values elneo-room--buffers))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (elneo-room--replace-avatar-placeholders)))))

(defun elneo-room--replace-avatar-placeholders ()
  "Replace avatar initial placeholders whose image has downloaded.
Cell-for-cell (both cells are `elneo-room--avatar-width' columns),
so neither the window view nor any position after it can shift."
  (let ((inhibit-read-only t)
        (pos (point-min))
        (limit (elneo-room--input-beg-pos)))
    (while (< pos limit)
      (let ((mxc (get-text-property pos 'elneo-room-avatar-src)))
        (if (or (not mxc)
                (get-text-property pos 'elneo-room-avatar-image))
            (setq pos (or (next-single-property-change
                           pos 'elneo-room-avatar-src nil limit)
                          limit))
          (let ((img (elneo-room--avatar-image-cell
                      (elneo-client--avatar-file mxc))))
            (if (null img)
                (setq pos (or (next-single-property-change
                               pos 'elneo-room-avatar-src nil limit)
                              limit))
              ;; The src property covers exactly the placeholder cell;
              ;; replace it with the equally wide image cell and keep
              ;; the property, so a later pass skips it.  delete-region
              ;; leaves point wherever it was — insert back at the
              ;; cell, not at point.
              (delete-region pos (+ pos elneo-room--avatar-width))
              (save-excursion
                (goto-char pos)
                (insert (propertize img 'elneo-room-avatar-image t
                                    'elneo-room-avatar-src mxc
                                    'read-only t)))
              (setq pos (+ pos elneo-room--avatar-width)))))))))

(defun elneo-room--strip-reply-fallback (body)
  "Strip a rich-reply fallback — leading \"> ...\" lines — from BODY.
Callers only do this when reply metadata is present, so a genuine
message that starts with \"> \" loses it only in replies (where the
fallback convention would have produced it anyway)."
  (let ((lines (split-string body "\n")))
    (while (and lines
                (or (string-prefix-p "> " (car lines))
                    (string-equal ">" (car lines))))
      (pop lines))
    (when (and lines (string-empty-p (car lines)))
      (pop lines))
    (string-join lines "\n")))

(defun elneo-room--picture-p (msgtype)
  "Non-nil for the media msgtypes that render an inline thumbnail.
An m.sticker rides the m.image path: the daemon ships it with the
same media entry (it is a picture with alt text), so the thumbnail
pipeline fills the placeholder as it scrolls into view."
  (member msgtype '("m.image" "m.sticker")))

(defun elneo-room--video-media-p (media)
  "Non-nil when the media alist MEDIA carries a video mimetype.
Decides the video-flavored labels the thumbnail pipeline speaks:
\"[video]\" instead of \"[image]\" when a fetch fails or images are
unsupported."
  (let ((mime (alist-get 'mimetype media)))
    (and (stringp mime) (string-prefix-p "video/" mime))))

(defun elneo-room--video-preview-p (msgtype media)
  "Non-nil for an m.video whose media entry ships a sender thumbnail.
This is the gate against expensive previews: with `thumb_source'
present `elneo-room--media-fetch-args' resolves to a sender thumbnail
— the plain small image, or the encrypted one the daemon decrypts —
and never to a homeserver thumbnailing attempt on the video itself
(the thumbnail API is image-only) nor to a whole-video download.  A
video without a sender thumbnail keeps the download-on-demand tag,
rendered below the preview in both cases."
  (and (equal msgtype "m.video")
       (alist-get 'thumb_source media)))

(defun elneo-room--quote-text (parent)
  "Body text for the quote of parent message plist PARENT.
Media messages become a bare type tag; bodies collapse to one line."
  (let ((msgtype (plist-get parent :msgtype)))
    (if (or (elneo-room--picture-p msgtype)
            (member msgtype '("m.file" "m.video" "m.audio")))
        (format "[%s]" (string-remove-prefix "m." msgtype))
      (replace-regexp-in-string "\n" " " (or (plist-get parent :body) "")))))

(defun elneo-room--body-width ()
  "Display columns available for content at the body column.
The window's body width (80 when the buffer is not displayed) minus
the body indent; callers floor it to taste."
  (- (or (window-body-width (get-buffer-window (current-buffer) t))
         80)
     (elneo-room--body-column)))

(defun elneo-room--quote-width ()
  "Columns available for quote text after the indent and marker."
  (max 20 (- (elneo-room--body-width) 3)))

(defvar-local elneo-room--members nil
  "Buffer-local: cached member roster of this room.
One plist per member: user-id, name (nil when the member never set
a display name).  Fetched on room open and refreshed whenever a
membership event arrives; store-backed, so it costs no homeserver
round trip.")

(defun elneo-room--insert-quote (reply-to)
  "Insert the reply quote for a reply to event REPLY-TO, at point.
Point must sit right after the sender name on the message's first
line; the quote is padded to the body column so it lines up with
the reply body on the next line.  The quote carries
`elneo-room-reply-target' so RET can jump to the parent.  In
`full' style a quoted image runs through the normal thumbnail
pipeline under a synthetic \"PARENT#quote\" event id — everything
downstream keys on `elneo-room-event-id', so nothing else
changes.  The quote line carries no event id of its own — a gap in
the buffer's property layout (see
`elneo-room--append-messages')."
  (let* ((parent (gethash reply-to elneo-room--seen))
         ;; Anon mode fakes the quote's render copy; the seen entry
         ;; stays real.
         (parent (if elneo-anon-mode
                     (elneo-anon--message parent elneo-room--room-id
                                          elneo-room--members)
                   parent))
         (inhibit-read-only t)
         (beg (progn
                (insert (make-string
                         (max 0 (- (elneo-room--body-column)
                                   (current-column)))
                         ?\s))
                (point)))
         (name-beg nil)
         (name-end nil)
         (img-beg nil)
         (img-end nil))
    (insert "↳ ")
    (cond
     ((null parent)
      ;; Parent on an unloaded older page.
      (insert "older message"))
     ((plist-get parent :redacted)
      ;; The parent was redacted: its content is gone (or only locally
      ;; revealed), so the quote degrades to the same marker.  This
      ;; branch comes before the style cases so it holds for `text'
      ;; and `full' alike.
      (insert (propertize "[redacted]" 'face 'elneo-room-redacted)))
     ((eq elneo-room-reply-quote 'none)
      (insert "in reply to ")
      (setq name-beg (point))
      (insert (elneo-room--sender-name parent))
      (setq name-end (point)))
     (t
      (setq name-beg (point))
      (insert (elneo-room--sender-name parent))
      (setq name-end (point))
      (insert ": ")
      (let ((text (elneo-room--quote-text parent)))
        (if (and (eq elneo-room-reply-quote 'full)
                 (elneo-room--picture-p (plist-get parent :msgtype))
                 (plist-get parent :media))
            (progn
              (setq img-beg (point))
              (insert (propertize
                       (format "[%s]"
                               (string-remove-prefix
                                "m." (plist-get parent :msgtype)))
                       'face 'shadow
                       'elneo-room-media t
                       'elneo-room-media-thumb t
                       'elneo-room-media-data (plist-get parent :media)
                       'elneo-room-event-id (concat reply-to "#quote"))
                      " ")
              (setq img-end (1- (point))))
          (insert (truncate-string-to-width
                   text (elneo-room--quote-width) nil nil "…"))))))
    (put-text-property beg (point) 'elneo-room-quote t)
    (put-text-property beg (point) 'elneo-room-reply-target reply-to)
    (put-text-property beg (point) 'face 'elneo-room-reply-quote-face)
    ;; Re-apply after the line-wide face laid above clobbered both, so
    ;; the quoted sender renders in the same color as on the message
    ;; line and the image placeholder keeps its shadow face.
    (when name-beg
      (put-text-property name-beg name-end
                         'face (elneo-room--sender-face
                                (plist-get parent :sender))))
    (when img-beg
      (put-text-property img-beg img-end 'face 'shadow))))

(defun elneo-room--insert-reaction-line (event-id ts entries)
  "Insert the aggregated reaction line for EVENT-ID below point.
TS is the target message's timestamp (day separators and read
marking key on it).  The `‹' marker keeps reactions visually
separate from emoji typed into message bodies; own keys render
bold."
  (let ((beg (point))
        (inhibit-read-only t))
    (insert (make-string (elneo-room--body-column) ?\s))
    (insert (propertize "‹ " 'face 'elneo-room-reaction))
    (when entries
      (insert (mapconcat
               (lambda (e)
                 (propertize (if (> (or (plist-get e :count) 1) 1)
                                 (format "%s %d" (plist-get e :key)
                                         (plist-get e :count))
                               (plist-get e :key))
                             'face (if (plist-get e :own)
                                       'elneo-room-reaction-own
                                     'elneo-room-reaction)))
               entries " ")))
    (insert "\n")
    (put-text-property beg (1- (point)) 'elneo-room-event-id event-id)
    ;; The ts covers the trailing newline too — same property layout
    ;; as the message lines (see `elneo-room--append-messages').
    (put-text-property beg (point) 'elneo-room-ts ts)
    (put-text-property beg (1- (point)) 'elneo-room-reaction-line t)))

(defun elneo-room--poll-vote-mark (own)
  "The per-option mark of an own/!own poll selection."
  (if own "☑" "☐"))

(defun elneo-room--insert-poll-block (event-id ts poll)
  "Insert the option lines of the poll POLL (a plist, the
`elneo-client--poll-plist' shape) below point.  TS is the poll
start's timestamp.  Each option line carries `elneo-room-poll-line'
(what the block-bounds walk and the re-renderers key on) and
`elneo-room-poll-option' (the answer id the vote command sends);
counts and the own marks come from the daemon's aggregate — an
undisclosed running poll shows only the own marks.  The block ends
with point after its last newline; a reaction line may follow."
  (let ((inhibit-read-only t)
        (ended (plist-get poll :ended))
        (multi (> (or (plist-get poll :max-selections) 1) 1)))
    (dolist (opt (plist-get poll :options))
      (let* ((text (plist-get opt :text))
             (own (plist-get opt :own))
             (count (plist-get opt :count))
             (beg (point))
             (line (concat (make-string (elneo-room--body-column) ?\s)
                           (elneo-room--poll-vote-mark own) " " text
                           (when (> (or count 0) 0) (format " (%d)" count)))))
        (insert (propertize line 'face (if own 'elneo-room-poll-own 'elneo-room-poll)))
        ;; The vote hint only makes sense on a running poll; the ended
        ;; poll renders the same box, just without an invitation.
        (when (and multi (not ended) (zerop (or count 0)))
          (insert (propertize " +" 'face 'elneo-room-poll)))
        (insert "\n")
        (put-text-property beg (1- (point)) 'elneo-room-poll-line t)
        (put-text-property beg (1- (point)) 'elneo-room-event-id event-id)
        (put-text-property beg (point) 'elneo-room-ts ts)
        (put-text-property beg (line-end-position) 'elneo-room-poll-option
                           (plist-get opt :id))
        ;; A count carries the voter list only when the aggregate
        ;; shipped voters (an undisclosed running poll's own mark
        ;; shows a count but hides the names).
        (when (and (> (or count 0) 0) (plist-get opt :voters))
          (put-text-property beg (line-end-position)
                             'help-echo
                             (mapconcat #'identity (plist-get opt :voters) ", ")))))
    (when ended
      (let ((beg (point)))
        (insert (propertize "· poll ended" 'face 'elneo-room-redacted))
        (insert "\n")
        (put-text-property beg (1- (point)) 'elneo-room-poll-line t)
        (put-text-property beg (1- (point)) 'elneo-room-event-id event-id)
        (put-text-property beg (point) 'elneo-room-ts ts)))))

;;; Rich (HTML) bodies

;; Dynamic bindings shr reads while rendering; declaring them here
;; keeps the let* in `elneo-room--insert-rich-body' dynamic in
;; compiled code (shr itself loads only via autoload, too late).
(defvar shr-width)
(defvar shr-inhibit-images)
(defvar shr-use-fonts)

(defcustom elneo-room-rich-bodies t
  "Render `org.matrix.custom.html' formatted bodies with shr.
Messages from rich-text clients carry an HTML version alongside
the mandatory plain body; non-nil renders it with faces (bold,
italics, fixed-pitch code, indented quotes).  nil renders every
message as plain text.  `\\[elneo-room-toggle-rich-bodies]'
toggles the current buffer, leaving this default untouched."
  :group 'elneo-room
  :type 'boolean)

(defcustom elneo-room-trust-marks nil
  "Show a trust mark after messages from senders in encrypted rooms.
The mark tells whether the sending device is verified: ✓ for
verified, ⚠ for an unverified or signed-but-unverified device and
✗ for an identity/device anomaly (Element's red shields).  The
marks are a snapshot, like Element's: the daemon records the
sender's trust state at decryption time, so a device verified only
after a message arrived keeps its unverified mark for that
message.  Enabling (or verifying someone, which re-renders the
marked buffers) does not re-evaluate history — messages already
kept locally render from the state they arrived with.  Off by
default: most accounts verify everyone they chat with, and the
glyphs cost a column for nothing then.  `T' toggles the current
buffer, leaving this default untouched."
  :group 'elneo-room
  :type 'boolean)

(defcustom elneo-room-load-embedded-images nil
  "Whether images embedded in rich bodies load inline.
Element's custom emoji and stickers arrive as `<img>' tags inside
formatted bodies.  Non-nil fetches them through the daemon's
authenticated media download — `mxc://' sources only, cached on
disk like message thumbnails, never loaded when the placeholder
scrolls into view repeatedly.  nil (the default) renders a dim
[image] marker instead.  http(s) URLs never load in either
setting: they would tell an arbitrary web server who opened the
message and when."
  :group 'elneo-room
  :type 'boolean)

(defun elneo-room--strip-rich-reply-fallback (html)
  "Drop the rich-reply fallback (<mx-reply>...</mx-reply>) from HTML."
  (if (string-match "</mx-reply>" html)
      (string-trim (substring html (match-end 0)))
    html))

(defun elneo-room--rich-img-marker (n)
  "The placeholder text standing in for rich body image number N."
  (format "⟦img %d⟧" n))

(defun elneo-room--rich-node (node srcs)
  "Rebuild one DOM node with <img> elements replaced by markers.
Returns (NODE . SRCS): the rebuilt node and the numbered list of
the replaced elements' src attributes, in order."
  (cond
   ;; An <img>: swap in a marker, remember its src.
   ((and (consp node) (eq (car node) 'img))
    (let ((src (cdr (assq 'src (cadr node)))))
      (cons (elneo-room--rich-img-marker (1+ (length srcs)))
            (append srcs (list src)))))
   ;; A node list (what libxml hands back at top level): walk it as
   ;; the children of one synthetic element.
   ((and (consp node) (consp (car node)))
    (elneo-room--rich-node (cons 'top nil node) srcs))
   ;; An element: rewrite its children.
   ((consp node)
    (let ((children nil)
          (out-srcs srcs))
      (dolist (child (cddr node))
        (let ((res (elneo-room--rich-node child out-srcs)))
          (push (car res) children)
          (setq out-srcs (cdr res))))
      (cons (apply #'list (car node) (cadr node) (nreverse children))
            out-srcs)))
   ;; Text or nil: unchanged.
   (t (cons node srcs))))

(defun elneo-room--insert-rich-body (msg)
  "Insert MSG's formatted body at point, rendered by shr.
Images become placeholders; with
`elneo-room-load-embedded-images' on, `mxc://' ones carry the
media properties the thumbnail pipeline fetches on scroll.  The
whole region carries `elneo-room-rich-block' with the event id,
so `elneo-room--replace-message' can delete a multi-line body
(something only rich bodies produce) as one block."
  (let* ((html (plist-get msg :formatted-body))
         (event-id (plist-get msg :event-id))
         (html (if (plist-get msg :reply-to)
                   (elneo-room--strip-rich-reply-fallback html)
                 html))
         (dom (with-temp-buffer
                (insert html)
                (libxml-parse-html-region (point-min) (point-max))))
         (rewritten (elneo-room--rich-node
                     (if (stringp dom)
                         ;; A formatted body with no markup parses to a
                         ;; bare string; shr-insert-document errors on
                         ;; those, so walk it as one synthetic element.
                         (list 'top nil dom)
                       dom)
                     nil))
         (srcs (cdr rewritten))
         (start (point))
         ;; Block content (pre blocks especially) fills to this width;
         ;; inline markup is unaffected by it.
         (shr-width (max 20 (elneo-room--body-width)))
         (shr-inhibit-images t)
         ;; Columns, not pixels: shr-use-fonts would reinterpret the
         ;; integer shr-width as a multiple of the frame's char width.
         (shr-use-fonts nil)
         finish)
    (shr-insert-document (car rewritten))
    ;; Trim newlines at both edges: shr opens some markup with a
    ;; newline and pads block content at the end, but the body should
    ;; flow directly after the sender prefix, and the caller's line
    ;; terminator must stay the only trailing one.
    (let ((lead (save-excursion
                  (goto-char start)
                  (skip-chars-forward "\n")
                  (point))))
      (when (> lead start)
        (delete-region start lead)))
    (delete-region (save-excursion
                     (skip-chars-backward "\n" start)
                     (point))
                   (point))
    ;; shr starts each block on a fresh line at column 0; indent those
    ;; hard newlines to the body column like plain bodies do, so the
    ;; two renderings line up.
    (elneo-room--indent-region-newlines start (copy-marker (point)))
    ;; Pills ride the sender's anchors; a bare URL in the same rich
    ;; body renders plain — linkify the region it missed (shr links
    ;; only its anchors, and this pass skips exactly those).
    (elneo-room--linkify-rich start (point))
    (put-text-property start (point) 'elneo-room-rich-block event-id)
    (setq finish (copy-marker (point)))
    (save-excursion
      (goto-char start)
      (while (re-search-forward "⟦img +\\([0-9]+\\)⟧" finish t)
        (let* ((n (string-to-number (match-string 1)))
               (src (nth (1- n) srcs))
               (inhibit-read-only t))
          (replace-match
           (if (and src (string-prefix-p "mxc://" src)
                    elneo-room-load-embedded-images)
               ;; Full media placeholder under a synthetic id — like
               ;; the reply quote's "#quote" suffix, so it never
               ;; collides with the block's own id run.  The
               ;; scroll-pass fetcher downloads it like a message
               ;; thumbnail and `elneo-room--on-media' replaces the
               ;; span; several images per message load in sequence.
               (propertize "[image]"
                           'face 'shadow
                           'elneo-room-media t
                           'elneo-room-media-thumb t
                           'elneo-room-media-data `((source (url . ,src)))
                           'elneo-room-media-name
                           (file-name-nondirectory src)
                           'elneo-room-event-id
                           (concat event-id "#img" (number-to-string n)))
             ;; Not loadable (or an http(s) URL: never fetch those):
             ;; a dim marker, nothing more.
             (propertize "[image]" 'face 'shadow))))))
    (set-marker finish nil)))

(defun elneo-room--toggle-display (var label &optional arg)
  "Shared body of the per-buffer display toggles: flip VAR in this room.
With no ARG flip the current buffer's value; with any non-nil ARG
drop the buffer-local override so the buffer follows the global
default again.  LABEL names the feature in the echo.  The buffer
re-renders from the kept message history — draft, view position
and reactions all survive."
  (unless elneo-room--backfilled
    (user-error "Room is still loading"))
  (if arg
      (kill-local-variable var)
    ;; `setq-local' is no use: the variable is the argument.
    (set (make-local-variable var) (not (symbol-value var))))
  (message "%s in this room: %s (%s)" label (symbol-value var)
           (if (local-variable-p var) "buffer-local" "global default"))
  (elneo-room--rebuild))

(defun elneo-room--set-default-and-redraw (var)
  "Flip the global default VAR, re-rendering room buffers.
The global is the default new room buffers follow; buffers with
an explicit per-buffer override of VAR keep theirs."
  (set var (not (symbol-value var)))
  (dolist (buffer (hash-table-values elneo-room--buffers))
    (when (buffer-live-p buffer)
      (unless (local-variable-p var buffer)
        (with-current-buffer buffer
          (when elneo-room--backfilled
            (elneo-room--rebuild)))))))

(defun elneo-room-toggle-rich-bodies (&optional arg)
  "Toggle rich body rendering in this room buffer.
With no ARG flip the current buffer's value; with any non-nil ARG
drop the buffer-local override so the buffer follows the global
`elneo-room-rich-bodies' again."
  (interactive "P")
  (elneo-room--toggle-display 'elneo-room-rich-bodies "Rich bodies" arg))

(defun elneo-room-toggle-avatars (&optional arg)
  "Toggle the sender avatar column in this room buffer.
With no ARG flip the current buffer's value; with any non-nil ARG
drop the buffer-local override so the buffer follows the global
`elneo-room-avatars' again."
  (interactive "P")
  (elneo-room--toggle-display 'elneo-room-avatars "Sender avatars" arg))

(defun elneo-room-toggle-trust-marks (&optional arg)
  "Toggle sender trust marks in this room buffer.
With no ARG flip the current buffer's value; with any non-nil ARG
drop the buffer-local override so the buffer follows the global
`elneo-room-trust-marks' again."
  (interactive "P")
  (elneo-room--toggle-display 'elneo-room-trust-marks "Trust marks" arg))

(defun elneo-room--rebuild-trust-buffers ()
  "Re-render every open room buffer that shows trust marks.
Called when a verification completes: only new arrivals pick the
fresh state up (marks are per-message snapshots — see
`elneo-room-trust-marks'), but the re-render costs nothing and
keeps the toggle's rebuild honest for buffers waiting on it."
  (dolist (buffer (hash-table-values elneo-room--buffers))
    (when (and (buffer-live-p buffer)
               (buffer-local-value 'elneo-room--backfilled buffer)
               (buffer-local-value 'elneo-room-trust-marks buffer))
      (with-current-buffer buffer
        (elneo-room--rebuild)))))

(defun elneo-room--rebuild-all-buffers ()
  "Re-render every open room buffer from its kept history.
`elneo-anon-mode''s toggles render-time-replace everything, so a
re-render re-skins each buffer (and, toggling off, restores the
real text); no trust filter here, every backfilled buffer rebuilds."
  (dolist (buffer (hash-table-values elneo-room--buffers))
    (when (and (buffer-live-p buffer)
               (buffer-local-value 'elneo-room--backfilled buffer))
      (with-current-buffer buffer
        (elneo-room--rebuild)))))

(defun elneo-room--ordered-event-ids ()
  "Event ids of the rendered messages, oldest first.
Walks the buffer rather than the seen table so the order is the
one on screen, including prepended older pages.  Synthetic ids
(reply quotes, rich body images) are skipped: they are not keys in
the seen table."
  (let ((ids nil)
        (pos (point-min))
        (limit (elneo-room--input-beg-pos)))
    (while (< pos limit)
      (let ((id (get-text-property pos 'elneo-room-event-id)))
        (when (and id
                   (gethash id elneo-room--seen)
                   ;; Consecutive runs of the same id collapse to one.
                   (not (equal id (car ids))))
          (push id ids))
        (setq pos (next-single-property-change
                   pos 'elneo-room-event-id nil limit))))
    (nreverse ids)))

(defun elneo-room--rebuild ()
  "Re-render the whole buffer from the kept message history.
The seen table holds the full plist of every rendered message and
stays current through edits, so the buffer can be rebuilt without
a daemon round-trip.  Draft, view anchoring and reactions all
survive — `elneo-room--render-first-page' re-lays them."
  (let* ((window (get-buffer-window (current-buffer) t))
         (entries
          (delq nil
                (mapcar (lambda (id)
                          (let* ((msg (copy-sequence
                                       (gethash id elneo-room--seen)))
                                 (reacts (and (hash-table-p
                                               elneo-room--reactions)
                                              (gethash id
                                                       elneo-room--reactions))))
                            (when reacts
                              (plist-put msg :reactions reacts))
                            msg))
                        (elneo-room--ordered-event-ids)))))
    (elneo-room--render-first-page
     entries elneo-room--end-token window)))

;;; URL recognition

(defvar elneo-room--url-regexp "\\(https?://[^[:space:]\"<>]+\\)"
  "A bare http(s) URL, the same rule for out- and inbound text.
Shared by the outgoing markup converter
(`elneo-room--format-inline') and the receive-side linkifier below;
changing one changes both.")

(defconst elneo-room--url-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'elneo-room--browse-url-at-point)
    (define-key map [mouse-2] #'elneo-room--browse-url-at-point)
    map)
  "Keymap carried on the URL spans of message text.")

(defun elneo-room--trim-url-tail (url)
  "Strip sentence punctuation riding the tail of URL.
Trailing `)' comes off only when the URL text itself closes more
parens than it opens — a balanced `(...)' inside the URL stays."
  (while (and (> (length url) 0)
              (or (memq (aref url (1- (length url))) '(?. ?, ?\; ?:))
                  (and (eq (aref url (1- (length url))) ?\))
                       (< (cl-count ?\( url) (cl-count ?\) url)))))
    (setq url (substring url 0 -1)))
  url)

(defun elneo-room--linkify-string (string)
  "Return a copy of STRING with bare http(s) URLs made clickable.
Each URL span carries `elneo-room-url' (the link text),
`elneo-room-url-face', mouse highlight and the URL keymap.  Runs
on the plain body string before insertion, so every render path —
first page, backfill, live append, edit re-render — inherits it;
stored bodies are never mutated (the copy keeps `:body' pristine)."
  (let ((out (copy-sequence string))
        (pos 0))
    (save-match-data
      (while (string-match elneo-room--url-regexp string pos)
        (setq pos (match-end 1))
        (let* ((start (match-beginning 1))
               (url (elneo-room--trim-url-tail
                     (match-string 1 string))))
          (when (> (length url) 0)
            (add-text-properties start (+ start (length url))
                                 (list 'elneo-room-url url
                                       'face 'elneo-room-url-face
                                       'mouse-face 'highlight
                                       'keymap elneo-room--url-keymap
                                       'help-echo "mouse-1: open in browser, w: copy")
                                 out)))))
    out))

(defun elneo-room--linkify-rich (start end)
  "Linkify the bare URLs a rich body's sender left unlinked.
Rich HTML leans on the sender's anchors — and the same message can
carry two pills (`<a href=\"matrix.to/#/@...\">' each), text and a
trailing URL the sender never wrapped: shr renders that text
propertyless and dead.  The plain-body pass (`elneo-room--linkify-string')
runs before insertion only, so give the rendered region the same
properties here, skipping the spans shr already linked (an anchor's
display text carries `shr-url').  The hrefs never surface as text —
shr renders only text nodes, so \"inside an href\" is not a place
text can live; the only skip check that matters is spans that are
already links."
  (save-excursion
    (save-match-data
      (goto-char start)
      (while (re-search-forward elneo-room--url-regexp end t)
        (let ((s (match-beginning 1))
              (url (elneo-room--trim-url-tail (match-string 1))))
          (when (and (> (length url) 0)
                     (not (get-text-property s 'shr-url))
                     (not (get-text-property s 'elneo-room-url)))
            (add-text-properties
             s (+ s (length url))
             (list 'elneo-room-url url
                   'face 'elneo-room-url-face
                   'mouse-face 'highlight
                   'keymap elneo-room--url-keymap
                   'help-echo "mouse-1: open in browser, w: copy"))))))))

(defun elneo-room--link-prop-near-point (prop)
  "Value of text property PROP at point, or one char back.
Point one char past a span still reads as \"on it\" to a human,
same as `elneo-room--media-at-point'."
  (or (get-text-property (point) prop)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) prop))))

(defun elneo-room--url-at-point ()
  "The link text under point, or nil.
Both the plain-body `elneo-room-url' and shr's `shr-url' (rich
bodies) count."
  (or (elneo-room--link-prop-near-point 'elneo-room-url)
      (elneo-room--link-prop-near-point 'shr-url)))

(defun elneo-room--url-unescape (string)
  "Decode the %XX escapes in STRING.
A self-contained decode, so `url-util' stays out of the loader:
the only place the room link machinery needs it is the matrix.to
room fragment, where ids ride percent-encoded (%23, %21, %3A...).
Each escape's WHOLE `%XX' match — group and leader — becomes its
character; replacing the group alone would leave the `%' behind."
  (let ((out string))
    (save-match-data
      (while (string-match "%\\([0-9A-Fa-f][0-9A-Fa-f]\\)" out)
        (setq out (replace-match
                   (char-to-string
                    (string-to-number (match-string 1 out) 16))
                   t t out 0))))
    out))

(defun elneo-room--matrix-to-link (url)
  "Where URL (a matrix.to link) points, and the via servers it carries.
Returns (TARGET . VIA): the room id or #alias, and the `?via='
servers as a list — the join route a remote room with no resolvable
alias needs, the one a bare-id join otherwise fails with (`404: no
servers that are in the room have been provided').  VIA can be nil:
room links carry it, aliases usually need none.
The shapes everyone ships are `https://matrix.to/#/!id:hs' and
`.../#/%23alias:hs', the alias riding its `#' percent-encoded, the
via tail read after the room part.  User links (@), event anchors
and anything of another shape read as `nil' — they stay browser
links.  The `matrix:' URI scheme is deliberately not parsed:
matrix.to is what the ecosystem shares.
The caller needs a room buffer's profile for anything non-nil to
act on — without it the link belongs to the browser."
  (when (and (stringp url)
             (string-prefix-p "https://matrix.to/#/" url))
    (let* ((fragment (elneo-room--url-unescape
                      (substring url (length "https://matrix.to/#/"))))
           (room (and (string-match "\\([!#][^?]*\\)" fragment)
                      (match-string 1 fragment)))
           (via (and (string-match "\\?\\([^?]+\\)" fragment)
                     (apply #'nconc
                            (mapcar
                             (lambda (entry)
                               (and (string-prefix-p "via=" entry)
                                    (list (substring entry 4))))
                             (split-string (match-string 1 fragment) "&"))))))
      (and room
           (string-search ":" room)
           (cons room via)))))

(defun elneo-room--matrix-to-target (url)
  "The room id or #alias URL (a matrix.to link) points at, or nil.
The target half of `elneo-room--matrix-to-link'; the via servers
ride the link's cdr."
  (car (elneo-room--matrix-to-link url)))

(defun elneo-room--lookup-link-target (profile target)
  "Registry record for PROFILE's TARGET — a room id or #alias.
The registry is keyed by room id; an alias target matches a
record's canonical alias.  nil when the registry knows neither."
  (or (elneo-room-get profile target)
      (let (found)
        (maphash (lambda (_key room)
                   (when (and (not found)
                              (equal (plist-get room :profile) profile)
                              (equal (plist-get room :alias) target))
                     (setq found room)))
                 elneo--rooms)
        found)))

(defun elneo-room--open-matrix-link (profile target &optional via)
  "Open or join PROFILE's room TARGET (a room id or #alias).
VIA is the target's join route (a matrix.to link's `?via=' list, a
space listing's via servers) — the server names a remote room with
no resolvable alias is only joinable through.
A room in the registry opens — `elneo-room-open', or the space
page (`elneo-space-browse') when the record is a space; an unknown
one asks to join, the daemon resolving the alias on the way, and a
joined space opens its discovery page through the record's
`:space'.  Non-nil when the link was handled; nil lets the caller
fall back to the browser (a declined join is the old behavior:
the link opens there)."
  (let ((record (elneo-room--lookup-link-target profile target)))
    (cond
     ((and record (not (plist-get record :removed)))
      (require 'elneo-space)
      (if (plist-get record :space)
          (elneo-space-browse profile (plist-get record :room-id))
        (elneo-room-open record))
      t)
     ((y-or-n-p (format "%s is not open in this client — join it? " target))
      (message "Matrix: joining %s" target)
      (elneo-join-room
       profile target
       (lambda (p event)
         (if (not (alist-get '@ok event nil nil #'equal))
             (message "Matrix: joining %s failed — %s"
                      target (elneo-server--error-string event))
           (let* ((room-id (alist-get 'room_id event nil nil #'equal))
                  (record (and room-id (elneo-room-get p room-id))))
             (if (not record)
                 (message "Matrix: joined %s" target)
               (if (plist-get record :space)
                   (elneo-space-browse p room-id)
                 (elneo-room-open record))))))
       via)
      t))))

(defun elneo-room--browse-url-at-point (&optional event)
  "Open the link under point (or under EVENT's click).
matrix.to room links — room ids and aliases, the shape every
client and space shares — open in this client instead of a
browser: a room the registry knows opens, an unknown one asks to
join.  User links, event anchors and every non-matrix.to URL stay
with `browse-url'."
  (interactive "e")
  (save-excursion
    (when event (mouse-set-point event))
    (let* ((url (elneo-room--url-at-point))
           (link (and url elneo-room--profile
                      (elneo-room--matrix-to-link url)))
           (target (car link)))
      (cond
       ((and target (elneo-room--open-matrix-link elneo-room--profile target
                                                  (cdr link)))
        (message "Matrix: opening %s" url))
       (url
        (browse-url url)
        (message "Matrix: opening %s" url))
       (t (user-error "No link at point"))))))

(defcustom elneo-room-thread-marks 'both
  "How a thread reply mark itself in the room buffer (MSC3440).
Thread replies render inline where they sit — unlike Element, which
hides them from the room view — so each needs a small distinction:
`glyph' puts a \U0001f9f5 before the message's sender column; `tint'
takes the thread face over the whole message block; `both' does
both.  `none' shows nothing.  A dedicated thread buffer (t on a
marked message) forces none locally — everything in it is a thread
reply, the marks would be noise.

With `elneo-room-thread-colors' on, the mark's glyph and tint also
carry the thread's own hue, so different threads read apart."
  :group 'elneo-room
  :type '(choice (const :tag "Glyph before the sender" glyph)
                 (const :tag "Tint the message block" tint)
                 (const :tag "Both glyph and tint" both)
                 (const :tag "None" none)))

(defface elneo-room-thread
  '((t :inherit shadow))
  "Face for a thread reply's glyph and block tint.
Subtle by design: thread membership is context, not emphasis.  The
message's own sender faces stay; this is layered under the read-dim.
With `elneo-room-thread-colors' on, per-thread glyph and tint faces
inherit this — the hue layers over the shadow base."
  :group 'elneo-room)

(defconst elneo-room-thread-glyph "\U0001f9f5"
  "The glyph a thread reply carries before its sender column when
`elneo-room-thread-marks' includes it.")

(defun elneo-room--osm-url (geo)
  "An OpenStreetMap link built from a `geo:' URI, or nil.
GEO comes from the daemon's `geo' field on a message entry
(MSC3489); the coordinates are whatever precedes the `;'/`?'
parameter separator.  Returns nil when GEO is nil or cannot be
parsed — a location message then renders as an inert tag."
  (when (and geo (string-match "\\`geo:\\([^,;?]+\\),\\([^,;?]+\\)" geo))
    (let ((lat (match-string 1 geo)) (lon (match-string 2 geo)))
      (format "https://www.openstreetmap.org/?mlat=%s&mlon=%s#map=17/%s/%s"
              lat lon lat lon))))

(defun elneo-room--insert-video-preview (media event-id body)
  "Insert a thumbnailed video's preview block at point.
Two lines: the picture-shaped placeholder for MEDIA's thumbnail —
the fetch scan keys on `elneo-room-media-thumb' and replaces it with
the sender's frame — then, indented to the body column, the
download-on-demand tag.  The tag keeps the video visibly a video
after the fetch and keeps open/save where they always were; BODY
fills the placeholder like a picture's caption does.  The caller
(the message's second-line machinery) has already positioned point
at the body column."
  (insert (propertize
           (if (> (length body) 0) (format "[video: %s]" body) "[video]")
           'face 'shadow
           'elneo-room-media t
           'elneo-room-media-thumb t
           'elneo-room-media-data media
           'elneo-room-event-id event-id))
  (insert "\n"
          (make-string (elneo-room--body-column) ?\s)
          (propertize
           (format "[video: %s%s]"
                   (or (elneo-room--media-name media) body)
                   (elneo-room--media-size-tag media))
           'face 'shadow
           'elneo-room-media t
           'elneo-room-media-data media
           'elneo-room-media-name (or (elneo-room--media-name media) body)
           'elneo-room-event-id event-id)))

(defun elneo-room--insert-body (msg)
  "Insert the body of message plist MSG at point.
One arm per body shape: a member system line, a redacted marker,
undecryptable, a rich (shr-rendered) body, a picture placeholder, a
thumbnailed video's preview, a voice waveform, a location tag, a
download-on-demand media tag, or the linkified plain body.  The
rich body and the video preview are the shapes that insert
themselves (returning \"\", since the cond result is inserted): the
preview needs a tag line of its own below the image.  The rich body
is the one shape that may span several lines of body text; its
region carries `elneo-room-rich-block' so
`elneo-room--replace-message' deletes it as one block.  The name
line and the per-message markers are the callers'."
  (let* ((reply-to (plist-get msg :reply-to))
         (body (if reply-to (elneo-room--strip-reply-fallback (plist-get msg :body))
                 (plist-get msg :body)))
         (msgtype (plist-get msg :msgtype))
         (event-id (plist-get msg :event-id))
         (formatted-body (plist-get msg :formatted-body))
         (media (plist-get msg :media))
         (member-line (string= msgtype "m.member")))
    (insert (cond
             (member-line
              ;; The whole sentence is the body ("You joined the
              ;; room"); dim, nothing else applies — no linkify (bodies
              ;; name people, not URLs), no reply quote, no media.
              (propertize body 'face 'shadow))
             ((plist-get msg :redacted)
              ;; Redacted away: a marker keeps the message's slot in the
              ;; history.  A revealed original renders in the same face
              ;; with the marker trailing it.
              (propertize (if (plist-get msg :redacted-body)
                              (concat (plist-get msg :redacted-body) " [redacted]")
                            "[redacted]")
                          'face 'elneo-room-redacted))
             ((string= msgtype "m.undecryptable")
              (propertize (elneo-room--indent-newlines body)
                          'face 'elneo-room-undecryptable))
             ((and formatted-body elneo-room-rich-bodies
                   (member msgtype '("m.text" "m.notice" "m.emote"))
                   (fboundp 'libxml-parse-html-region))
              ;; Rich body: shr renders it (faces, quotes, code), which
              ;; may span several lines — the only multi-line body.
              (elneo-room--insert-rich-body msg)
              "")
             ((elneo-room--picture-p msgtype)
              ;; Placeholder for a picture (image or sticker); replaced
              ;; by the thumbnail when it arrives.  Without media data
              ;; (a protocol-2-era daemon, say) it just stays a tag —
              ;; the fetch scan below requires media to fetch.  m.file
              ;; goes through the download-on-demand arm below; a
              ;; thumbnailed m.video goes through the preview arm.
              (let ((kind (string-remove-prefix "m." msgtype)))
                (propertize
                 (if (> (length body) 0) (format "[%s: %s]" kind body)
                   (format "[%s]" kind))
                 'face 'shadow
                 'elneo-room-media t
                 'elneo-room-media-thumb t
                 'elneo-room-media-data media
                 'elneo-room-event-id event-id)))
             ((and (string= msgtype "m.audio") media (alist-get 'voice media))
              ;; Voice note (MSC3245): waveform bars plus duration,
              ;; playable with RET.  Like the rich body, it inserts
              ;; itself.
              (elneo-room--insert-voice msg)
              "")
             ((string= msgtype "m.location")
              ;; MSC3489: a geo: URI plus an optional caption.  The
              ;; tag is a link when the daemon's protocol-3 `geo'
              ;; field is present: `elneo-room-url' carries the OSM
              ;; link, so mouse-1, `o'/`RET' (open) and `w' (copy) all
              ;; work like any other URL span.  A protocol-2 daemon
              ;; ships no geo — the tag then stays inert dim text.
              (let ((osm (elneo-room--osm-url (plist-get msg :geo))))
                (propertize (concat "[location"
                                    (if (= (length body) 0) "" (concat ": " body))
                                    "]")
                            'face (if osm 'elneo-room-url-face 'shadow)
                            'elneo-room-url osm
                            'mouse-face (when osm 'highlight)
                            'keymap (when osm elneo-room--url-keymap)
                            'help-echo (when osm "mouse-1: open map, w: copy link"))))
             ((elneo-room--video-preview-p msgtype media)
              ;; A thumbnailed video previews like a picture: the
              ;; placeholder sits on this line (the caller put it on a
              ;; second line, same as for pictures) and the fetch scan
              ;; replaces it with the sender's thumbnail when it scrolls
              ;; into view.  The download-on-demand tag stays under the
              ;; preview, so the video never stops being a video — and
              ;; like the rich body and the voice note, this arm inserts
              ;; itself and hands the cond a no-op string.
              (elneo-room--insert-video-preview media event-id body)
              "")
             ((and (member msgtype '("m.file" "m.video" "m.audio")) media)
              ;; Openable media: download on demand, then
              ;; `elneo-open-file-function'.  No `elneo-room-media-thumb'
              ;; property: scrolling past must not inline-fetch a whole
              ;; video.  Duration and size come from the event's media
              ;; metadata when the sender set them.  (A video WITH a
              ;; sender thumbnail is the preview arm above; a file tag
              ;; for a thumbnailed video is what that arm's second line
              ;; renders.)
              (propertize
               (format "[%s: %s%s]"
                       (string-remove-prefix "m." msgtype)
                       (or (elneo-room--media-name media) body)
                       (elneo-room--media-size-tag media))
               'face 'shadow
               'elneo-room-media t
               'elneo-room-media-data media
               'elneo-room-media-name (or (elneo-room--media-name media) body)
               'elneo-room-event-id event-id))
             ((and msgtype
                   (not (member msgtype '("m.text" "m.notice" "m.emote"))))
              ;; Media and other non-text content, kept for context.
              (propertize (elneo-room--indent-newlines body) 'face 'shadow))
             (t (elneo-room--indent-newlines
                 (elneo-room--linkify-string body)))))))

(defun elneo-room--insert-status-marks (msg line-beg)
  "Insert message plist MSG's status riders at point.
The block starts at LINE-BEG.  The per-message marks ride after the
body in this order: the trust mark, (edited), [pinned], the ⏱/✗
send lifecycle; then the whole-block property, the thread tint and
the read-dim/✓✓ pass take the block's span.  The trailing newline is
the caller's."
  ;; Trust mark (encrypted rooms only, off by default): rides after
  ;; the body with the other per-message markers — the block span
  ;; and read-dim cover it, and re-renders keep it.
  (when-let* ((marks elneo-room-trust-marks)
              (trust (plist-get msg :sender-trust))
              (mark (assoc trust elneo-room--trust-marks)))
    (insert " " (propertize (nth 1 mark) 'face (nth 2 mark))))
  ;; The subdued marker for an edited message rides after the body —
  ;; including after the [image: ...] tag of an edited media message.
  (when (plist-get msg :edited)
    (insert (propertize " (edited)" 'face 'elneo-room-edited)))
  ;; The [pinned] rider (protocol 22) rides after (edited); it reads
  ;; the live buffer-local, so pins reaching a later page are marked
  ;; the moment that page renders.
  (when (member (plist-get msg :event-id) elneo-room--pinned)
    (insert (propertize " [pinned]" 'face 'elneo-room-pin)))
  ;; Send lifecycle: a provisional block shows ⏱ until the send ack
  ;; arrives, ✗ (with its keys) when the send failed.
  (when (plist-get msg :pending)
    (insert (propertize " ⏱" 'face 'elneo-room-pending)))
  (when (plist-get msg :send-failed)
    (insert (propertize " ✗ (R retry · K remove)"
                        'face 'elneo-room-send-failed)))
  ;; Whole-block marker: event id and ts ride on the block's LAST
  ;; line only, so `elneo-room--replace-message' cannot see where a
  ;; multi-line body (hard newlines in a plain body, a rich body, a
  ;; reply) starts.  This property covers the block from its first
  ;; line and is what the walk up to the block's top keys on.
  (put-text-property line-beg (point) 'elneo-room-msg-block
                     (plist-get msg :event-id))
  ;; Thread reply tint (MSC3440): the whole block takes the thread
  ;; face under its own styling — and, with `elneo-room-thread-colors'
  ;; on, the thread's own faint hue.  This runs BEFORE the read-dim
  ;; pass below, so a read block keeps the dim instead of trading
  ;; it for the tint.
  (when (and (plist-get msg :thread-root)
             (memq elneo-room-thread-marks '(tint both)))
    (elneo-room--tint-thread
     line-beg (point)
     (when elneo-room-thread-colors
       (elneo-room--thread-tint-face (plist-get msg :thread-root)))))
  ;; Other members' read receipts (`elneo-room--apply-read-marks'
  ;; recomputes the flags in the seen plist): `dim'/`both' styles dim
  ;; the whole read block; `check'/`both' put ✓✓ on the newest read
  ;; own message.  Dimming first, so the check itself is only the
  ;; read face, not dimmed on top of itself.
  (when (plist-get msg :read-by)
    (elneo-room--dim-faces line-beg (point)))
  (when (plist-get msg :read-check)
    (insert (propertize " ✓✓" 'face 'elneo-room-read))))

(defun elneo-room--insert-message (msg)
  "Insert message plist MSG at point.
A reply renders as two lines: the sender's time and name, with the
quoted parent continuing on the same line after the name, and the
reply body below it, indented to the body column.  A picture renders
the same way: an inline thumbnail makes its line box as tall as the
image, and Emacs draws line text on the baseline, which strands the
name at the bottom of a tall picture — on its own indented line the
image sits below the name line instead.  A thumbnailed video
(`elneo-room--video-preview-p') gets the same treatment, its preview
being an image; the video tag follows the preview, one line down.
The body renders through `elneo-room--insert-body', the per-message
markers through `elneo-room--insert-status-marks'; only the body
line carries the event id and ts, laid by the caller per the
property layout in `elneo-room--append-messages'."
  (let* ((line-beg (point))
         (ts (plist-get msg :ts))
         (sender (elneo-room--sender-name msg))
         (own (plist-get msg :is-own))
         (reply-to (plist-get msg :reply-to))
         (msgtype (plist-get msg :msgtype))
         ;; Protocol-4 member events render as one subdued system
         ;; line: no sender column, no reply/media machinery.
         (member-line (string= msgtype "m.member"))
         (inhibit-read-only t))
    (when elneo-room-avatars
      (insert (elneo-room--avatar-cell msg)))
    (insert (propertize (format "%s " (elneo-room--format-ts ts))
                        'face 'elneo-room-time))
    ;; Thread reply glyph (MSC3440), between the time and the sender
    ;; column: marks the line's thread membership without nudging the
    ;; column grid (the glyph eats its own width inside the gap).
    (when (and (plist-get msg :thread-root)
               (memq elneo-room-thread-marks '(glyph both)))
      (insert (propertize (concat elneo-room-thread-glyph " ")
                          'face (elneo-room--thread-face
                                 (plist-get msg :thread-root))
                          'elneo-room-thread-root (plist-get msg :thread-root))))
    ;; Own names keep the italic own-sender face but also carry the
    ;; sender color, same as everyone else's.
    (unless member-line
      (let* ((sface (elneo-room--sender-face (plist-get msg :sender)))
             (face (if own (list sface 'elneo-room-own-sender) sface)))
        (insert (propertize
                 (if (string= msgtype "m.emote")
                     (format "* %s " sender)
                   (concat (elneo-room--pad-to-width
                            (truncate-string-to-width
                             sender elneo-room-sender-width nil nil "…")
                            elneo-room-sender-width)
                           " "))
                 'face face))))
    (when (or reply-to
              (elneo-room--picture-p msgtype)
              (elneo-room--video-preview-p msgtype (plist-get msg :media)))
      ;; Replies, pictures and thumbnailed videos render their content
      ;; on a second line,
      ;; indented to the body column (see the docstring).  The first
      ;; line carries `elneo-room-name-line' so
      ;; `elneo-room--replace-message' knows the re-rendered block
      ;; starts there.
      (when reply-to
        ;; The quote continues on this line, right after the name; the
        ;; reply body goes under it, indented to the body column.
        (elneo-room--insert-quote reply-to))
      (put-text-property line-beg (point) 'elneo-room-name-line t)
      (insert "\n")
      (insert (make-string (elneo-room--body-column) ?\s)))
    (elneo-room--insert-body msg)
    (elneo-room--insert-status-marks msg line-beg)
    (insert "\n")))

(defun elneo-room--dim-faces (beg end)
  "Add `elneo-room-read' to every face between BEG and END.
Segments keep their own face (sender colors, time, markers) with the
read face dimming on top; regions with no face at all — plain
bodies — gain it alone.  Idempotent per segment."
  (let ((pos beg))
    (while (< pos end)
      (let* ((face (get-text-property pos 'face))
             (faces (if (listp face) face (list face)))
             (next (or (next-single-property-change pos 'face nil end)
                       end)))
        (unless (or (and face (memq 'elneo-room-read faces)))
          (put-text-property pos next
                             'face (if face
                                       (append faces '(elneo-room-read))
                                     'elneo-room-read)))
        (setq pos next)))))

(defun elneo-room--tint-thread (beg end &optional extra)
  "Add the thread tint to every face between BEG and END.
The tint pass for a thread reply's block — the `dim-faces' pattern
with the thread face: segments keep their own face (sender colors,
time, markers) with the thread face layered on top; regions with no
face gain it alone.  EXTRA, when non-nil, layers the thread's own
faint background on top (`elneo-room--thread-tint-face'), so each
thread shades its own hue.  Idempotent per segment, and callers run
it before the read-dim pass, so the read face stays outermost.
Block text is read-only (`elneo-room-mode' enforces it), hence the
inhibit binding."
  (let ((inhibit-read-only t)
        (pos beg))
    (while (< pos end)
      (let* ((face (get-text-property pos 'face))
             (faces (if (listp face) face (list face)))
             (next (or (next-single-property-change pos 'face nil end)
                       end)))
        (unless (and (memq 'elneo-room-thread faces)
                     (or (not extra) (member extra faces)))
          (put-text-property
           pos next 'face
           (cond ((memq 'elneo-room-thread faces)
                  ;; base in place: the hue layers on top of it
                  (append faces (list extra)))
                 (face
                  (append faces (list 'elneo-room-thread extra)))
                 (t
                  (delq nil (list 'elneo-room-thread extra))))))
        (setq pos next)))))

(defun elneo-room--stamp-message-block (event-id ts msg reactions block-beg)
  "Stamp the just-inserted message block with its layout properties.
Point must sit exactly where `elneo-room--insert-message' left it
— after the block's trailing newline — so the stamps and the poll
and reaction lines land on the body line and under it.  EVENT-ID
and TS key the block for the property walkers; MSG contributes
:thread-root and :poll; REACTIONS is the resolved reaction value
to lay out, or nil (the line is then skipped — append reads it
from the wire entry, replace from the seen hash).  BLOCK-BEG is
the start of the re-inserted block, for the wrap-prefix.  The
property layout itself is the contract documented in
`elneo-room--append-messages'; this hoist is what keeps the
append and replace sites in lock-step."
  ;; The buffer's text-property layout — the authoritative comment
  ;; lives in `elneo-room--append-messages'.  A block's last line
  ;; (for a reply, the indented body line) carries the event id over
  ;; the line and the ts over the line plus its trailing newline.
  (put-text-property (line-beginning-position 0) (line-end-position 0)
                     'elneo-room-event-id event-id)
  ;; A thread reply's membership rides the same span —
  ;; `elneo-room-open-thread' reads it straight off the property
  ;; when the seen table has no entry (a loaded older page, say).
  (when (plist-get msg :thread-root)
    (put-text-property (line-beginning-position 0)
                       (line-end-position 0)
                       'elneo-room-thread-root
                       (plist-get msg :thread-root)))
  (put-text-property (line-beginning-position 0)
                     (min (point-max) (1+ (line-end-position 0)))
                     'elneo-room-ts ts)
  ;; The reaction line goes below the message line and must be
  ;; inserted only after the props above are laid: an insert before
  ;; would shift point and the line would carry (or steal) the
  ;; whole-line properties.  The poll block sits between the two —
  ;; under the body, above the reaction line.
  (when (plist-get msg :poll)
    (elneo-room--insert-poll-block event-id ts (plist-get msg :poll)))
  (when reactions
    (elneo-room--insert-reaction-line event-id ts reactions))
  ;; Soft-wrapped continuation lines indent to the body column —
  ;; same column as the hard newlines and the reaction line.  Covers
  ;; the whole block from its first line, but not the day separator
  ;; above (dates stay at column 0) nor the draft area below
  ;; (full-width input strip).
  (put-text-property block-beg (point)
                     'wrap-prefix (elneo-room--wrap-prefix)))

(defun elneo-room--append-messages (messages)
  "Insert the message plists MESSAGES (oldest->newest) at point.
The caller positions point first."
  (let ((inhibit-read-only t))
    (dolist (msg messages)
      (let ((event-id (plist-get msg :event-id))
            (ts (plist-get msg :ts)))
        (unless (or (null event-id) (gethash event-id elneo-room--seen))
          ;; The seen table stores the full plist: `r' (reply) looks the
          ;; message up by event id, and the reply quote line pulls the
          ;; parent's body and sender from it.
          (puthash event-id msg elneo-room--seen)
          (when (and (plist-get msg :reactions)
                     (hash-table-p elneo-room--reactions))
            (puthash event-id (plist-get msg :reactions) elneo-room--reactions))
          ;; Anon mode fakes a render copy; the tables above keep the
          ;; real data (toggle-off re-renders from them).
          (when elneo-anon-mode
            (setq msg (elneo-anon--message msg elneo-room--room-id
                                           elneo-room--members)))
          (setq elneo-room--last-event-id event-id)
          ;; Day separator between messages from different local days.
          ;; Comparing raw timestamps is wrong: consecutive messages
          ;; on the same day differ in time-of-day.  The position
          ;; guard matters when prepending history at point-min:
          ;; position 0 is out of range, and there is nothing above
          ;; the oldest message anyway.
          (let ((prev (and (> (point) (point-min))
                           (get-text-property (1- (point))
                                              'elneo-room-ts))))
            (when (and prev
                       (not (equal (elneo-room--day prev)
                                   (elneo-room--day ts))))
              (elneo-room--insert-day-separator ts)))
          (let ((block-beg (point)))
            (elneo-room--insert-message msg)
            ;; The buffer's text-property layout — the authoritative
            ;; comment; the other sites that mention gaps or the
            ;; trailing newline point here.  A block's last line
            ;; (for a reply, the indented body line) carries the
            ;; event id over the line and the ts over the line plus
            ;; its trailing newline (the next block's day-separator
            ;; check reads the ts exactly there).  Everything above
            ;; it — for a reply the time/name/quote line — carries
            ;; neither and reads as a gap to the property walkers
            ;; (read-marking, unread boundary, view restore), so a
            ;; cursor there belongs to no message.  The event id is
            ;; what those walkers and media replacement key on.
            ;; Stampers laid through the shared hoist above — the
            ;; property-layout comment here is authoritative.
            (elneo-room--stamp-message-block
             event-id ts msg
             (and (hash-table-p elneo-room--reactions)
                  (plist-get msg :reactions))
             block-beg)))))))

(defun elneo-room--mark-history-readonly ()
  "Give all text before the draft area the `read-only' property.
The separator's last character also gets `rear-nonsticky', so
insertions at the start of the draft do not inherit `read-only' —
nor the separator's `face', which inherits `mode-line' and would
otherwise grey every character typed first in the draft (each later
one then inherits from it)."
  (let ((end (min (elneo-room--input-beg-pos) (point-max))))
    (when (> end (point-min))
      (let ((inhibit-read-only t))
        (put-text-property (point-min) end 'read-only t)
        (put-text-property (1- end) end 'rear-nonsticky
                           '(read-only face))))))

;;; Input area

(defun elneo-room--input-beg-pos ()
  "Position where the writable draft area starts.
`point-max' while no input area exists yet."
  (let ((marker elneo-room--input-beg))
    (if (and (markerp marker) (marker-buffer marker) (marker-position marker))
        (marker-position marker)
      (point-max))))

(defun elneo-room--draft-text ()
  "The current draft, or \"\"."
  (let ((beg (elneo-room--input-beg-pos)))
    (if (< beg (point-max))
        (buffer-substring-no-properties beg (point-max))
      "")))

(defvar-local elneo-room--draft-placeholder nil
  "Buffer-local: overlay showing the placeholder in an empty draft.")

(defun elneo-room--update-draft-placeholder ()
  "Show a placeholder while the draft area is empty.
The placeholder lives in an overlay only — it is never part of the
buffer text, so an untouched draft still counts as empty on send."
  (when (and elneo-room--backfilled
             (markerp elneo-room--input-beg)
             (buffer-live-p (marker-buffer elneo-room--input-beg)))
    (let ((ov elneo-room--draft-placeholder))
      (if (< (elneo-room--input-beg-pos) (point-max))
          ;; Real draft text is present: the placeholder must go.
          (when (overlayp ov) (delete-overlay ov))
        (unless (and (overlayp ov)
                     (eq (overlay-buffer ov) (current-buffer)))
          ;; advance flags keep the first typed character inside the
          ;; overlay, so it cannot inherit the placeholder display.
          (setq ov (make-overlay (point-max) (point-max) nil t t)
                elneo-room--draft-placeholder ov))
        (move-overlay ov (point-max) (point-max))
        (unless (overlay-get ov 'before-string)
          (overlay-put
           ov 'before-string
           ;; The overlay sits at point-max, so the caret — drawn at
           ;; point — would render behind the placeholder text, at its
           ;; end.  The `cursor' property instead puts it inside the
           ;; string, on its first character: the caret sits at the
           ;; start of the hint, and the first typed character takes
           ;; the standard position.
           (propertize " Type a message here, RET to send"
                       'face 'elneo-room-input-placeholder
                       'cursor t)))))))

(defun elneo-room--separator-text ()
  "Current separator line text (without the trailing newline)."
  (cond
   (elneo-room--reply-to
    (format "── reply to %s%s: RET sends · C-j newline · C-c C-k cancels ──"
            ;; Anon mode fakes the name; the reply target's event id
            ;; resolves the mxid (the fake keyed on it matches the
            ;; message line), falling back to the name itself.
            (if elneo-anon-mode
                (let ((parent (gethash elneo-room--reply-to
                                       elneo-room--seen)))
                  (elneo-anon--person (and parent (plist-get parent :sender))
                                      elneo-room--reply-sender))
              elneo-room--reply-sender)
            ;; The send sorts into the target's thread when it names
            ;; one (the separator is the only place the room view
            ;; shows it ahead of the send).
            (let ((parent (gethash elneo-room--reply-to
                                   elneo-room--seen)))
              (if (and parent (plist-get parent :thread-root))
                  " (in thread)" ""))))
   (elneo-room--edit-to
    "── editing message: RET sends · C-j newline · C-c C-k cancels ──")
   (t "── draft: RET sends · C-j newline · C-c C-a attach · C-c C-d dired ──")))

(defun elneo-room--update-separator ()
  "Rewrite the separator line to match the current reply state."
  (when (and elneo-room--backfilled
             (markerp elneo-room--input-beg)
             (marker-buffer elneo-room--input-beg)
             (> (elneo-room--input-beg-pos) (point-min)))
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (elneo-room--input-beg-pos))
        (goto-char (line-beginning-position 0))
        ;; Replace the line's content, keeping its newline: inserting at
        ;; the input-beg marker position itself would muddle the marker.
        (delete-region (point) (line-end-position))
        (insert (propertize (elneo-room--separator-text)
                            'face 'elneo-room-input-separator
                            'read-only t)))
      (elneo-room--mark-history-readonly))))

(defun elneo-room--reset-input-area (draft)
  "Append the blank line, separator line and writable DRAFT tail.
(Re)creates the `elneo-room--append-point' and
`elneo-room--input-beg' markers after a full re-render."
  (let* ((inhibit-read-only t)
         (sep (concat (elneo-room--separator-text) "\n")))
    (goto-char (point-max))
    (insert "\n" (propertize sep 'face 'elneo-room-input-separator))
    (setq elneo-room--input-beg (copy-marker (point) nil))
    ;; Position right before the blank line that separates the history
    ;; from the separator (type t: advances past live appends).
    (setq elneo-room--append-point
          (copy-marker (- (point) 1 (length sep)) nil))
    (set-marker-insertion-type elneo-room--append-point t)
    (when (> (length draft) 0)
      (insert draft))
    (elneo-room--mark-history-readonly)
    (elneo-room--update-draft-placeholder)))

(defun elneo-room--in-input-p ()
  "Non-nil when point is in the writable draft area (or no history yet)."
  (or (not elneo-room--backfilled)
      (>= (point) (elneo-room--input-beg-pos))))

(defmacro elneo-room--defkey (name char docstring &rest body)
  "Define NAME, the history-area binding for the bare key CHAR.
The draft shares the room's keymap, so a bare history key must not
shadow typing: in the draft area (or before the first page renders,
when there is no history yet) the key self-inserts CHAR.  BODY runs
only over history."
  (declare (indent 2))
  `(defun ,name ()
     ,(concat docstring
              (format "\nIn the draft area, insert a %c instead." char))
     (interactive)
     (if (elneo-room--in-input-p)
         (self-insert-command 1 ,char)
       ,@body)))

(elneo-room--defkey elneo-room--o ?o
  "Open the media at point."
  (elneo-room-open-media-at-point))

(elneo-room--defkey elneo-room--w ?w
  "Copy the URL at point to the kill ring.
Rich (shr-rendered) links count too."
  (let ((url (elneo-room--url-at-point)))
    (if url
        (progn
          (kill-new url)
          (message "Matrix: copied %s" url))
      (message "Matrix: no link at point"))))

(declare-function elneo-image-view-at-point "elneo-image")

(defun elneo-room--permalink (room &optional event-id)
  "The shareable https://matrix.to link for ROOM's EVENT-ID, or ROOM.
The ids ride fully percent-encoded (`url-hexify-string': `:' and
`$' included — matrix.to readers unescape any encoding the same
way), the room half preferring the canonical alias, which survives
an upgrade.  This is the one other Matrix clients open; the org
link (`org-store-link') stays local."
  (require 'url-util)
  (concat "https://matrix.to/#/"
          (url-hexify-string
           (or (plist-get room :alias)
               (plist-get room :room-id)))
          (if event-id
              (concat "/" (url-hexify-string event-id))
            "")))

(defun elneo-room--matrix-to-copier (link prefix)
  (kill-new link)
  (message "Matrix: copied %s %s" prefix link))

(elneo-room--defkey elneo-room--c ?c
  "Copy the message at point's plain text to the kill ring.
The body as stored (:body) — no display decorations; the URL at
point copies with `w' when one link is all you need."
  (let* ((id (elneo-room--event-id-at (point)))
         (msg (and id (gethash id elneo-room--seen))))
    (if (and msg (not (elneo-room--unsent-p msg)))
        (elneo-room--matrix-to-copier (plist-get msg :body) "text")
      (user-error "No message at point"))))

(elneo-room--defkey elneo-room--l ?l
  "Copy the message at point's permalink to the kill ring.
A https://matrix.to URL (canonical alias or room id + event id)
other Matrix clients open.  Redacted messages keep a usable link —
the target event id is on the server either way."
  (let* ((id (elneo-room--event-id-at (point)))
         (msg (and id (gethash id elneo-room--seen))))
    (cond
     ((null id) (user-error "No message at point"))
     ((elneo-room--unsent-p msg)
      (user-error "Cannot open a link on a message that is not on the server yet"))
     (t (elneo-room--matrix-to-copier
         (elneo-room--permalink
          (elneo-room-get elneo-room--profile elneo-room--room-id) id)
         "link")))))

(elneo-room--defkey elneo-room--v ?v
  "View the image at point full-size in the image viewer."
  ;; Lazy require: elneo-image needs this file's buffer-local
  ;; defvars, so requiring it from the top level would be circular.
  ;; The viewer is not needed until a key is pressed.
  (require 'elneo-image)
  (elneo-image-view-at-point))

(defun elneo-room-open-thread ()
  "Open the thread the message at point belongs to.
On a thread reply, that is the thread the message line carries
(`:thread-root' in its seen entry); on a thread root or an
unthreaded message, the reply thread rooted at the message itself.
A thread with no known replies still opens: its buffer pins the
root and fetches what the server has.  Lazy require, like the
image viewer: elneo-thread needs this file's buffer-locals."
  (interactive)
  (let ((id (elneo-room--event-id-at (point))))
    (unless id (user-error "No message at point"))
    (let ((msg (gethash id elneo-room--seen)))
      ;; Same gate as r/a/e/d: a ⏱/✗ id names nothing on the server —
      ;; the thread fetch would only bounce (and hit the stuck-view
      ;; finding above).
      (when (and msg (elneo-room--unsent-p msg))
        (user-error "Cannot open a thread on a message that is not on the server yet"))
      (let ((root (or (and msg (plist-get msg :thread-root)) id)))
        (require 'elneo-thread)
        (elneo-thread-open elneo-room--profile elneo-room--room-id root msg)))))

(elneo-room--defkey elneo-room--t ?t
  "Open the thread the message at point belongs to."
  (call-interactively #'elneo-room-open-thread))

(elneo-room--defkey elneo-room--y ?y
  "Toggle rich body rendering."
  (call-interactively #'elneo-room-toggle-rich-bodies))

(elneo-room--defkey elneo-room--A ?A
  "Toggle the sender avatar column."
  (call-interactively #'elneo-room-toggle-avatars))

(elneo-room--defkey elneo-room--T ?T
  "Toggle sender trust marks."
  (call-interactively #'elneo-room-toggle-trust-marks))

;; telega's save key; S remains as an alias.
(elneo-room--defkey elneo-room--s ?s
  "Save the media at point to a file."
  (call-interactively #'elneo-room-save-media-at-point))

(elneo-room--defkey elneo-room--S ?S
  "Save the media at point to a file (alias for `elneo-room--s')."
  (call-interactively #'elneo-room-save-media-at-point))

(elneo-room--defkey elneo-room--q ?q
  "Bury the room buffer."
  (bury-buffer))

;; `i' is reserved for telega's describe-message.
(elneo-room--defkey elneo-room--I ?I
  "Retry media display in view."
  ;; interactive "P" in the target reads the prefix from the
  ;; call-interactively below.
  (call-interactively #'elneo-room-retry-media))

(elneo-room--defkey elneo-room--r ?r
  "Reply to the message at point.
The next draft send carries the reply relation (first text segment
of the draft); C-c C-k cancels.  A reply to a message that lives
in a thread sends INTO that thread (like Element)."
  (let* ((id (elneo-room--event-id-at (point)))
         (msg (and id (gethash id elneo-room--seen))))
    (cond
     ((null msg) (user-error "No message at point"))
     ;; A provisional id names nothing on the server; the send would
     ;; only bounce.  Reply to the real echo once the ack lands.
     ((elneo-room--unsent-p msg)
      (user-error "Cannot reply to a message that is not on the server yet"))
     (t
      ;; Reply and edit mode are mutually exclusive: the Matrix
      ;; relation slot carries only one of them.
      (setq elneo-room--reply-to id
            elneo-room--reply-sender (elneo-room--sender-name msg)
            elneo-room--edit-to nil)
      (elneo-room--update-separator)
      (goto-char (point-max))
      (message "Replying to %s — RET sends, C-c C-k cancels"
               elneo-room--reply-sender)))))

(defun elneo-room-cancel-reply ()
  "Cancel the pending reply or edit attached to the draft."
  (interactive)
  (when (or elneo-room--reply-to elneo-room--edit-to)
    (setq elneo-room--reply-to nil
          elneo-room--reply-sender nil
          elneo-room--edit-to nil)
    (elneo-room--update-separator)
    (message "Matrix: cancelled")))

(elneo-room--defkey elneo-room--a ?a
  "React to the message at point.
Offers the keys of `elneo-room-reaction-emoji-options' plus the
reactions already on the message, with free-form input accepted.
Reacting with a key you already used toggles it off."
  (let* ((id (elneo-room--event-id-at (point)))
         (entries (and id (hash-table-p elneo-room--reactions)
                       (gethash id elneo-room--reactions)))
         ;; All keys on the message, and the ones we used (toggling off).
         (own-keys (mapcar (lambda (e) (plist-get e :key))
                           (cl-remove-if-not
                            (lambda (e) (plist-get e :own)) entries)))
         (collection (delete-dups
                      (append own-keys
                              (mapcar (lambda (e) (plist-get e :key)) entries)
                              elneo-room-reaction-emoji-options))))
    (if (null id)
        (user-error "No message at point")
      (let ((msg (gethash id elneo-room--seen)))
        (cond
         ;; Reacting to a provisional id would bounce off the server.
         ((elneo-room--unsent-p msg)
          (user-error "Cannot react to a message that is not on the server yet"))
         (t
          (let ((key (completing-read "Reaction: " collection nil nil)))
            (when (> (length key) 0)
              (elneo-send-reaction
               elneo-room--profile elneo-room--room-id id key
               (lambda (profile event)
                 (unless (alist-get '@ok event nil nil #'equal)
                   (message "Matrix [%s] reaction failed: %s" profile
                            (elneo-server--error-string event))))
               (member key own-keys))))))))))

(elneo-room--defkey elneo-room--d ?d
  "Delete (redact) your own message at point.
Asks for confirmation.  The display update arrives via the daemon's
redaction announcement, like any remote redaction."
  (let* ((id (elneo-room--event-id-at (point)))
         (msg (and id (gethash id elneo-room--seen))))
    (cond
     ((null msg) (user-error "No message at point"))
     ((not (plist-get msg :is-own)) (user-error "Only your own messages can be deleted"))
     ((plist-get msg :pending) (user-error "Still being sent — wait for the send to finish"))
     ((plist-get msg :send-failed)
      (user-error "It never reached the server — K removes it"))
     ((plist-get msg :redacted) (user-error "This message is already deleted"))
     (t
      (when (y-or-n-p "Delete this message? ")
        (elneo-redact-message elneo-room--profile elneo-room--room-id id
                              #'elneo-room--on-send-result))))))

(elneo-room--defkey elneo-room--pin ?^
  "Toggle the message at point on the room's pinned-messages list.
The daemon carries `m.room.pinned_events' behind the room's
pinning power level (protocol 22); the [pinned] mark renders when
the state echo re-announces the summary — nothing flips before the
server agrees.  Redacted messages cannot be pinned."
  (let* ((id (elneo-room--event-id-at (point)))
         (msg (and id (gethash id elneo-room--seen))))
    (if (and msg (not (elneo-room--unsent-p msg)))
        (elneo-send-pin
         elneo-room--profile elneo-room--room-id id
         (member id elneo-room--pinned)
         (lambda (profile event)
           (unless (alist-get '@ok event nil nil #'equal)
             (message "Matrix [%s] pin failed: %s" profile
                      (elneo-server--error-string event)))))
      (user-error "No message at point"))))

(elneo-room--defkey elneo-room--e ?e
  "Edit your own text message at point.
The current body lands in the draft area; RET sends the edit
(m.replace), C-c C-k cancels.  Only text messages can be edited —
media is deleted with `d' and re-sent instead.  Starting an edit
cancels a pending reply, and vice versa."
  (let* ((id (elneo-room--event-id-at (point)))
         (msg (and id (gethash id elneo-room--seen))))
    (cond
     ((null msg) (user-error "No message at point"))
     (elneo-room--thread-root
      (user-error "Editing thread replies is not supported yet"))
     (t
      (let ((refusal (elneo-room--edit-refusal msg)))
        (if refusal
            (user-error "%s" refusal)
          (elneo-room--begin-edit id msg)))))))

(defun elneo-room--edit-refusal (msg)
  "Why message plist MSG cannot be edited, nil when it can.
Every refusal says what is wrong and, where one exists, what to do
instead; shared verbatim by `e' and M-p (`elneo-room--edit-previous')."
  (cond
   ((not (plist-get msg :is-own)) "Only your own messages can be edited")
   ((plist-get msg :pending) "Still being sent — wait for the send to finish")
   ((plist-get msg :send-failed)
    "Send failed — R retries it, K removes it")
   ((plist-get msg :redacted) "This message was deleted")
   ((not (member (plist-get msg :msgtype)
                 '("m.text" "m.notice" "m.emote")))
    "Only text messages can be edited")))

(defun elneo-room--begin-edit (id msg)
  "Open event ID (message plist MSG) in the draft for editing."
  (setq elneo-room--edit-to id
        elneo-room--reply-to nil
        elneo-room--reply-sender nil)
  (elneo-room--update-separator)
  (goto-char (point-max))
  ;; Keep any draft already typed: the body goes on the next line.
  (when (> (length (elneo-room--draft-text)) 0)
    (insert "\n"))
  (insert (plist-get msg :body))
  (message "Editing message — RET sends, C-c C-k cancels"))

(defun elneo-room--edit-previous ()
  "Edit the previous own message, newest that passes `e''s gates.
The walk starts past the message already being edited
(`elneo-room--edit-to'), or past the message at point; with neither,
at the newest editable own message in the loaded history.  M-p must
work with point in the draft area, so it is a plain key, not a
defkey command."
  (interactive)
  (if elneo-room--thread-root
      (user-error "Editing thread replies is not supported yet")
    (let ((newest-first
           (reverse (elneo-room--ordered-event-ids))))
      ;; The walk starts strictly past the anchor, so M-p on the
      ;; message at point still moves to an earlier one; with no
      ;; anchor (draft area or nothing at point) everything counts.
      (when-let* ((anchor (or elneo-room--edit-to
                              (elneo-room--event-id-at (point)))))
        (setq newest-first
              (cdr (or (member anchor newest-first)
                       newest-first))))
      (let ((target (cl-find-if
                     (lambda (id)
                       ;; A nil entry refuses (no :is-own) — quotes and
                       ;; other synthetic ids never pass.
                       (not (elneo-room--edit-refusal
                             (gethash id elneo-room--seen))))
                     newest-first)))
        (if (null target)
            (user-error "No earlier own text message")
          ;; On the message: the walk names it, even when editing from
          ;; the draft.  Unloaded ids are not on the walk's list
          ;; (`--ordered-event-ids' walks rendered blocks only).
          (when-let* ((pos (elneo-room--find-event target)))
            (goto-char pos))
          (elneo-room--begin-edit target (gethash target elneo-room--seen)))))))

;;; Polls

(declare-function elneo-poll-create "elneo-client")
(declare-function elneo-poll-vote "elneo-client")
(declare-function elneo-poll-end "elneo-client")

(defun elneo-room--poll-at-point ()
  "The plist (:event-id :poll) of the poll at point, or nil."
  (let* ((id (elneo-room--event-id-at (point)))
         (msg (and id (gethash id elneo-room--seen))))
    (when (and msg (plist-get msg :poll))
      (cons id msg))))

(defun elneo-room--poll-display (option)
  "A poll option's completing-read display: its text, with the
result count the render shows."
  (let ((count (plist-get option :count)))
    (concat (plist-get option :text)
            (when (> (or count 0) 0) (format " (%d)" count)))))

(defun elneo-room--poll-cast (event-id poll)
  "Run the vote flow for the poll at point."
  (let* ((options (plist-get poll :options))
         (max (max 1 (or (plist-get poll :max-selections) 1)))
         (choices (mapcar #'elneo-room--poll-display options))
         (pick (lambda (choice)
                 (plist-get (nth (cl-position choice choices :test #'equal) options)
                            :id)))
         (send (lambda (selections)
                 (elneo-poll-vote
                  elneo-room--profile elneo-room--room-id event-id selections
                  (lambda (profile event)
                    (unless (alist-get '@ok event nil nil #'equal)
                      (message "Matrix [%s] poll vote failed: %s" profile
                               (elneo-server--error-string event))))))))
    (if (= max 1)
        (let ((choice (completing-read "Vote (empty clears your vote): " choices nil nil)))
          (funcall send (if (string-empty-p choice) nil (list (funcall pick choice)))))
      ;; Multi-pick: ask until max picks or empty input casts what is
      ;; picked so far (duplicates are ignored, not asked again).
      (let ((picked nil) choice done)
        (while (and (not done) (< (length picked) max))
          (setq choice
                (completing-read
                 (format "Vote (%d of max %d picked, empty to cast): "
                         (length picked) max)
                 choices nil nil))
          (cond
           ((string-empty-p choice) (setq done t))
           ((not (member choice picked)) (push choice picked))))
        (funcall send (mapcar pick picked))))))

(elneo-room--defkey elneo-room--p ?p
  "Vote in the poll at point.
Single-choice polls offer the options with completing-read; empty
input clears your vote.  Multi-choice polls ask for picks until
empty input.  The refreshed aggregate re-renders the block when the
daemon confirms it."
  (let ((at (elneo-room--poll-at-point)))
    (cond
     ((null at) (user-error "No poll at point"))
     ((plist-get (plist-get (cdr at) :poll) :ended)
      (user-error "This poll has ended — results are final"))
     (t (elneo-room--poll-cast (car at) (plist-get (cdr at) :poll))))))

(defun elneo-room-poll-create ()
  "Create a poll in this room.
Reads the question, the answer options (finish with empty input),
whether results show while the poll runs, and the answers-per-vote
cap when multiple picks are allowed."
  (interactive)
  (let ((question (read-string "Poll question: ")))
    (while (string-empty-p question)
      (setq question (read-string "Poll question (must not be empty): ")))
    (let ((options nil))
      (while (let ((opt (read-string
                         (format "Answer %d (empty to finish): "
                                 (1+ (length options))))))
               (when (> (length opt) 0)
                 (push opt options)
                 t))
        t)
      (unless (<= 2 (length options) 20)
        (user-error "A poll takes 2 to 20 options"))
      (let* ((disclosed (y-or-n-p "Show results while the poll is running? "))
             (multi (and (> (length options) 2)
                         (y-or-n-p "May a voter pick more than one answer? ")))
             (max-selections
              (if multi
                  (let ((n 0))
                    (while (not (and (>= n 1) (< n (length options))))
                      (setq n (read-number
                               (format "Answers per vote (1-%d): "
                                       (1- (length options))))))
                    n)
                1)))
        (elneo-poll-create
         elneo-room--profile elneo-room--room-id question (nreverse options)
         (lambda (profile event)
           (unless (alist-get '@ok event nil nil #'equal)
             (message "Matrix [%s] poll create failed: %s" profile
                      (elneo-server--error-string event))))
         disclosed (if multi max-selections 1))))))

(elneo-room--defkey elneo-room--P ?P
  "Create a poll in this room."
  (call-interactively #'elneo-room-poll-create))

(elneo-room--defkey elneo-room--E ?E
  "End the poll at point.
The homeserver lets the poll's creator (or a power level that
allows it) end their poll; the daemon relays a rejection."
  (let ((at (elneo-room--poll-at-point)))
    (cond
     ((null at) (user-error "No poll at point"))
     ((plist-get (plist-get (cdr at) :poll) :ended)
      (user-error "This poll has already ended"))
     ((not (plist-get (cdr at) :is-own))
      (user-error "Only the poll's creator can end it"))
     (t
      (when (y-or-n-p "End this poll? ")
        (elneo-poll-end
         elneo-room--profile elneo-room--room-id (car at)
         (lambda (profile event)
           (unless (alist-get '@ok event nil nil #'equal)
             (message "Matrix [%s] poll end failed: %s" profile
                      (elneo-server--error-string event))))))))))

(defun elneo-room--ret ()
  "RET: jump from a reply quote, play a voice note, open media, send
the draft, else prompt."
  (interactive)
  (if (not elneo-room--backfilled)
      (elneo-room-send)
    (if (< (point) (elneo-room--input-beg-pos))
        (let ((reply-target (get-text-property (point) 'elneo-room-reply-target)))
          (cond
           (reply-target (elneo-room--jump-to-reply reply-target))
           ;; Voice notes get their own player; plain media opens.
           ((elneo-room--voice-at-point) (elneo-room-play-voice-at-point))
           ((get-text-property (point) 'elneo-room-media)
            (elneo-room-open-media-at-point))
           ((elneo-room--url-at-point)
            (elneo-room--browse-url-at-point))
           (t (elneo-room-send))))
      (elneo-room--input-send))))

(defun elneo-room--input-newline ()
  "Insert a newline into the draft; elsewhere, prompt to send."
  (interactive)
  (if (and elneo-room--backfilled (>= (point) (elneo-room--input-beg-pos)))
      (insert "\n")
    (elneo-room-send)))

(defcustom elneo-room-yank-fontify t
  "Send text yanked into the draft with its fontification.
Non-nil converts faces on draft text — code yanked from a source
buffer, say — into HTML color spans on send, so colored text arrives
colored in Matrix clients.  nil sends drafts as plain text with the
usual markup conversion only.  Faces ride along to native and
unlisted rooms; `elneo-room-plain-bridges' gates the rest.  Drafts
persist as plain text, so yanked colors survive only until the next
Emacs restart."
  :type 'boolean
  :group 'elneo-room)

(defun elneo-room--input-send (&optional scale)
  "Send the draft and clear the input area.
With a SCALE spec (from the RET prefix argument), it applies to
every image upload the draft dispatches.  Empty (whitespace-only)
drafts are ignored.  The text leaves the buffer only after every
segment was handed to the daemon — a signal from a dead daemon
(`elneo-server--send') must not eat the draft, so sending happens
before the deletion.  A partial failure (one segment sent, a later
one signals) leaves the whole draft in place; the user edits out
what already went."
  (let ((text (elneo-room--draft-text)))
    (when (> (length (string-trim text)) 0)
      (elneo-room--gate-offline)
      ;; Faces ride along when `elneo-room-yank-fontify' is on: the
      ;; dispatch regex slices with `substring', which preserves text
      ;; properties, so yanked fontification survives to the send,
      ;; where it converts to HTML spans.  The no-properties read
      ;; above stays for the emptiness check, and draft persistence
      ;; keeps saving plain text (faces never survive a restart).
      (let ((body (if elneo-room-yank-fontify
                      (buffer-substring (elneo-room--input-beg-pos)
                                        (point-max))
                    text)))
        (when (and current-prefix-arg (null scale))
          (setq scale (elneo-room--scale-answer body)))
        (elneo-room--dispatch-input body scale))
      (let ((inhibit-read-only t))
        (delete-region (elneo-room--input-beg-pos) (point-max)))
      ;; The sent text is gone; drop the persisted draft too.
      (elneo-room--draft-maybe-save))))

(defun elneo-room-preview-draft ()
  "Show the current draft rendered the way it would go out.
The draft text plus the same rich converters `RET' would use
(`elneo-room-yank-fontify', the `elneo-room-plain-bridges' gate),
rendered in a read-only preview buffer — the rich mark-up pass is
identical to the room's own rich bodies, so yanked fontification,
markup and code blocks preview exactly as sent.  Mention pills get
their @-text only (the pills are a send-time decoration).  A draft
that a bridge or the plain toggle would send unformatted is
previewed as plain: exactly \"would send as plain text\"."
  (interactive)
  (let ((draft (buffer-substring (elneo-room--input-beg-pos) (point-max))))
    (when (> (length (string-trim draft)) 0)
      (let ((formatted (and (elneo-room--rich-send-p)
                            (if elneo-room-yank-fontify
                                (elneo-room--fontified-body draft)
                              (elneo-room--formatted-body
                               (substring-no-properties draft))))))
        (if (not formatted)
            (message "Matrix: would send as plain text")
          (with-help-window "*Matrix Draft Preview*"
            (elneo-room--draft-preview--render draft formatted)))))))

(defun elneo-room--draft-preview--render (draft html)
  "Fill the help buffer with DRAFT, then its sent shape HTML.
Everything inserts into `standard-output' — `with-help-window' has
point in the help window proper, and `elneo-room--insert-rich-body'
inserts into the current buffer (the settings-view convention)."
  (with-current-buffer standard-output
    (princ (concat "Draft:\n" draft "\n\n" "As sent:\n"))
    ;; The rendered pass inserts (not princs): faces die on the
    ;; printer.  A synthetic event-id keeps the block properties out
    ;; of the room's tables, so the re-render machinery never meets
    ;; the preview.
    (elneo-room--insert-rich-body
     (list :event-id "draft-preview" :formatted-body html))))

(defun elneo-room--gate-offline ()
  "While the room's daemon is down, refuse to send: raise
`user-error' with the recorded state when
`elneo-room-block-send-when-offline' is on.  Only
\"offline\"/\"error\" block — a slow sync never stops sending.
Before the draft deletion: the composition survives the failed RET."
  (when elneo-room-block-send-when-offline
    (let ((state (car (elneo-server-sync-state elneo-room--profile))))
      (when (member state '("offline" "error"))
        (user-error "Matrix daemon cannot reach homeserver (%s) — \
message not sent, draft kept"
                    state)))))

(defun elneo-room--scale-answer (text)
  "The scale spec the uploads in TEXT get, or nil.
Walks the same tag regex the dispatch uses and prompts once — and
only when a tag's path is an image by extension: a C-u over a
text-only draft, or over a `[file:` of something else, sends
unchanged.  An invalid answer is a `user-error': the prefix asked
for scaling, a typo must not quietly send originals."
  (let ((pos 0) hit)
    (while (and (not hit)
                (string-match "\\[\\(?:image\\|file\\): \\([^]\n]+\\)]" text pos))
      (when (elneo--image-file-p
             (string-trim (substring-no-properties (match-string 1 text))))
        (setq hit t))
      (setq pos (match-end 0)))
    (when hit (elneo--scale-read))))

(defun elneo-room--dispatch-input (text &optional scale)
  "Send TEXT: [image: PATH] and [file: PATH] tags as uploads, text
as text.  SCALE applies to image-tag uploads (a `[file:` of an
image scales too, same as the dired flow)."
  (let ((pos 0))
    (while (string-match "\\[\\(?:image\\|file\\): \\([^]\n]+\\)]" text pos)
      (let ((before (substring text pos (match-beginning 0)))
            (tag (match-string 0 text))
            (path (string-trim
                   (substring-no-properties (match-string 1 text)))))
        (setq pos (match-end 0))
        (elneo-room--send-text before)
        (if (string-prefix-p "[image" tag)
            (elneo-room--send-image path scale)
          (elneo-room--send-file path scale))))
    (elneo-room--send-text (substring text pos))))

;;; Mentions (@-completion)

(defcustom elneo-room-mention-auto-complete t
  "Non-nil: typing an `@' in the room draft opens member completion.
TAB (`elneo-room--complete-mention') always offers the picker,
whatever this says."
  :type 'boolean
  :group 'elneo-room)

(defvar-local elneo-room--draft-mentions nil
  "Buffer-local: mentions completed in the current draft.
Cons display-text onto user id.  No longer sent when the member's
display text does not occur in the body at send time — a mention
edited away retracts itself; nothing to clean up.

Entries live beyond a send: they cannot fire without their display
text in the body, and a retry after a failed send then carries its
mentions without extra bookkeeping.")

(defun elneo-room--fetch-members ()
  "Fetch this room's member roster into `elneo-room--members'.
Fire-and-forget: completion works from what is cached, and falls
back to typed user ids, while the fetch runs."
  (let ((buf (current-buffer)))
    (elneo-room-members
     elneo-room--profile elneo-room--room-id
     (lambda (profile event)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (if (not (alist-get '@ok event nil nil #'equal))
               (elneo--debug-log "Matrix [%s] members: %s" profile
                                 (elneo-server--error-string event))
             (setq elneo-room--members
                   (mapcar (lambda (m)
                             (list :user-id (alist-get 'user_id m)
                                   :name (alist-get 'display_name m)))
                           (alist-get 'members event nil nil #'equal))))))))))

;;; Room permissions
;; The `roomPermissions' snapshot (protocol >= 15): this session's
;; power level with the per-action can-X gates.  The edit commands
;; check the snapshot before running, so "cannot rename" is answered
;; before the round-trip, and the `C-c ?' view prints what is and is
;; not ours to change.

(defvar elneo-room--permissions-cache (make-hash-table :test 'equal)
  "(PROFILE . ROOM-ID) -> permissions plist from the latest
`roomPermissions' snapshot for the room.  Room buffers read it for
their edit gates (buffer-local mirror below); the `C-c ?' view
prints it.  Refreshed on every room open and by the settings view.")

(defvar-local elneo-room--permissions nil
  "This room buffer's latest permissions plist, or nil.
Mirror of the `elneo-room--permissions-cache' entry, filled with
the room buffer's own identity; nil (never fetched, or the fetch
failed) means the gates stay quiet and the homeserver rejects —
an unknown snapshot never hides an action.")

(defvar elneo-room--permission-gates
  '((:can-name "name") (:can-topic "topic") (:can-avatar "avatar")
    (:can-invite "invite") (:can-kick "kick") (:can-ban "ban")
    (:can-power "power levels"))
  "The gate keywords with the label each prints as, in display
order.  The list the fetch stores, the `C-c ?' view prints and
the gates consult; a new wire field lands here once.")

(defun elneo-room--wire-key (gate)
  "The wire field behind permissions GATE: :can-name -> `can_name'.
The response event's keys are the wire's snake_case symbols."
  (intern (string-replace "-" "_" (substring (symbol-name gate) 1))))

(defun elneo-room--fetch-permissions ()
  "Fetch this room's permissions snapshot into the shared cache.
Fire-and-forget like `elneo-room--fetch-members': a failed fetch
leaves the previous snapshot (possibly none — the gates stay
quiet, and the homeserver rejects over the ack)."
  (let ((buf (current-buffer)))
    (elneo-room-permissions
     elneo-room--profile elneo-room--room-id
     (lambda (profile event)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (if (not (alist-get '@ok event nil nil #'equal))
               (elneo--debug-log "Matrix [%s] permissions: %s" profile
                                 (elneo-server--error-string event))
             (let ((perms
                    (mapcan
                     (lambda (entry)
                       (let ((gate (car entry)))
                         (list gate
                               ;; A missing gate field (an outdated
                               ;; daemon) reads as not-allowed, the
                               ;; honest side of hiding an action.
                               (eq (alist-get (elneo-room--wire-key gate)
                                              event)
                                   t))))
                     elneo-room--permission-gates)))
               (plist-put perms :level (alist-get 'level event))
               (plist-put perms :creator (eq (alist-get 'creator event) t))
               (plist-put perms :fetched t)
               (setq elneo-room--permissions perms)
               (puthash (cons elneo-room--profile elneo-room--room-id)
                        perms
                        elneo-room--permissions-cache)
               ;; A `C-c ?' view waiting on this snapshot re-renders
               ;; itself (the refresh no-ops without a view open).
               (when (elneo-room-get elneo-room--profile
                                     elneo-room--room-id)
                 (elneo-room--settings-refresh
                  (elneo-room-get elneo-room--profile
                                  elneo-room--room-id)))))))))))

(defun elneo-room--cached-permissions ()
  "The current buffer room's permissions plist, from its own mirror."
  (and (derived-mode-p 'elneo-room-mode) elneo-room--permissions))

(defun elneo-room--ensure-permission (gate action)
  "Signal when the permissions snapshot withholds GATE for ACTION.
GATE is a keyword (`:can-name', `:can-invite', ...); ACTION the
verb for the error message.  A missing or stale snapshot — the
gate nil only when known — lets the command through: the
homeserver has the last word, and the ack reports a refusal as any
other failure.  LEVEL rides :level."
  (let ((perms (elneo-room--cached-permissions)))
    (when (and perms (plist-get perms :fetched)
               (not (plist-get perms gate)))
      (user-error "Not allowed to %s here (power level %s)"
                  action (elneo-room--permissions-level perms)))))

(defun elneo-room--permissions-level (perms)
  "The PERMS power level as text: \"creator\" or the integer."
  (if (eq (plist-get perms :creator) t)
      "creator"
    (format "%s" (plist-get perms :level))))

(defun elneo-room--gate (buf gate)
  "Non-nil when room BUF's permissions snapshot allows GATE.
An unknown snapshot (never fetched, or an outdated daemon without
the gates) allows: the snapshot only hides actions, the
homeserver has the last word either way.  A dead BUF allows too —
the view's [buttons] stay put when there is no room buffer."
  (let ((perms (and (buffer-live-p buf)
                    (buffer-local-value 'elneo-room--permissions buf))))
    (or (not perms)
        (not (plist-get perms :fetched))
        (plist-get perms gate))))

(defun elneo-room--roster-entries (&optional keep-own)
  "Roster completion entries as (LABEL USER-ID DISPLAY), one per member.
LABEL is what the minibuffer offers — the display name with the
user id in parens, or the bare user id when the member never set
a name (or set it to the id) — DISPLAY is what a pick lands in
the draft or the link (the display name, or the user id).  The
room's own user is left out unless KEEP-OWN — the mention and
invite pickers want that, the link store does not."
  (let ((own (elneo-server--user-id elneo-room--profile)))
    (delq nil
          (mapcar (lambda (m)
                    (let ((id (plist-get m :user-id))
                          (name (plist-get m :name)))
                      (when (and id (or keep-own (not (equal id own))))
                        (if (and name (not (equal name id)))
                            (list (format "%s (%s)" name id) id name)
                          (list id id id)))))
                  elneo-room--members))))

(defun elneo-room--mention-candidates ()
  "Completion candidates for @-mentions, as an alist.
Each entry is (LABEL USER-ID . DISPLAY) over
`elneo-room--roster-entries'.  The room's own user is left out.
The room-wide `@room' mention leads the list: `@room' is no user
id, the send-time scan turns the plain token into the
everyone-flag."
  (cons '("@room (everyone)" "@room" . "@room")
        (mapcar (lambda (entry)
                  (cons (car entry) (cons (cadr entry) (caddr entry))))
                (elneo-room--roster-entries))))

(defun elneo-room--mention-fragment ()
  "The @-mention fragment before point, as (START . TEXT).
START is the position of the opening `@', TEXT the mention-name
characters between it and point (\"\" behind a freshly typed @).
Nil when point is not right behind a `@'-opened fragment of the
draft area."
  (when (elneo-room--in-input-p)
    ;; The skip moves point back to the run's start and returns a
    ;; negative count — measure both ends inside the excursion and
    ;; leave point where the caller had it.
    (let ((limit (elneo-room--input-beg-pos))
          end start)
      (save-excursion
        (setq end (point))
        (skip-chars-backward "[[:alnum:]_.:=/\\-]" limit)
        (setq start (point))
        (when (and (> start limit)
                   (equal (char-after (1- start)) ?@))
          (cons (1- start)
                (buffer-substring-no-properties start end)))))))

(defun elneo-room--add-draft-mention (display user-id)
  "Note DISPLAY as USER-ID in `elneo-room--draft-mentions'.
Duplicates by user id collapse: one member never appears twice.
\"@room\" is not a user id — the entry simply doesn't happen; the
send-time scan turns the plain token into the everyone-flag."
  (unless (or (equal user-id "@room")
              (cl-member user-id elneo-room--draft-mentions
                         :test #'equal :key #'cdr))
    (push (cons display user-id) elneo-room--draft-mentions)))

(defun elneo-room--insert-mention (display user-id)
  "Replace the @-fragment before point with DISPLAY.
USER-ID rides along in `elneo-room--draft-mentions' (DISPLAY,
USER-ID), so the send tags the body with an `m.mentions' block."
  (let ((frag (elneo-room--mention-fragment)))
    (let ((inhibit-read-only t))
      (when frag
        (delete-region (car frag) (point)))
      (insert display))
    (elneo-room--add-draft-mention display user-id)))

(defun elneo-room--complete-mention ()
  "Complete the @-mention fragment before point from the roster.
A member picked in the minibuffer replaces the fragment with their
display name (or user id, nameless members); the send then tags
the body with an `m.mentions' block.  Free entry of a full user
id (`@user:server') is accepted as-is when the roster misses it;
anything else leaves the fragment untouched.  In the history area
this does nothing."
  (interactive)
  (let ((frag (elneo-room--mention-fragment)))
    (when frag
      (let* ((candidates (elneo-room--mention-candidates))
             ;; A C-g aborts with `minibuffer-quit'; inside the pick it
             ;; must not escape through here — this runs from
             ;; `post-command-hook', where an escape just logs "Error
             ;; in post-command-hook".  A quiet abort leaves the
             ;; fragment (and its typed `@') in the draft.
             (picked (condition-case nil
                         (completing-read "Mention: "
                                          (mapcar #'car candidates)
                                          nil nil (cdr frag))
                       ((quit minibuffer-quit) nil)))
             ;; assoc-string: it returns the whole alist CELL
             ;; (LABEL USER-ID . DISPLAY); `alist-get' would strip
             ;; the label and hand back just the tail.
             (pair (and picked (assoc-string picked candidates))))
        (cond
         ;; A roster hit goes into the draft as the display name;
         ;; the entry is a dotted (LABEL USER-ID . DISPLAY).
         (pair (elneo-room--insert-mention (cddr pair) (cadr pair)))
         ;; A typed user id counts as a mention of itself.
         ((and picked
               (string-match-p "@[[:alnum:]_.:=/-]+\\'" picked))
          (elneo-room--insert-mention picked picked)))))))

(defun elneo-room--mention-text-occurs-p (needle body)
  "Non-nil when NEEDLE occurs in BODY on word boundaries.
The send-time mention filter — the block and the pills take the
same set, so a mention never fires where it does not read as one
(\"Bob\" inside a typed \"Bobby\" mentions nobody).  Boundaries are
non-alphanumeric characters or the string edges."
  (and (> (length needle) 0)
       (string-match-p
        (format "\\(?:\\`\\|[^[:alnum:]]\\)%s\\(?:[^[:alnum:]]\\|\\'\\)"
                (regexp-quote needle))
        body)))

(defun elneo-room--send-mentions (body)
  "The mentions in segment BODY, as a plist (:ids IDS :room ROOM
:pairs PAIRS).
IDS comes from `elneo-room--draft-mentions'; an entry counts only
while its display text occurs in the body
(`elneo-room--mention-text-occurs-p') — the mention behind
deleted text retracts itself.  PAIRS is the same surviving set,
(DISPLAY . USER-ID) conses, kept aside for the pill render.  ROOM
is non-nil when the body carries a standalone \"@room\" token
(Element's textual convention; \"x@room\" keeps it out).  A plist
of nils sends no block."
  (let ((pairs (cl-remove-if-not
                (lambda (pair)
                  (elneo-room--mention-text-occurs-p (car pair) body))
                elneo-room--draft-mentions))
        (room (and
               (string-match-p
                "\\(?:\\`\\|[^[:alnum:]]\\)@room\\(?:[^[:alnum:]]\\|\\'\\)" body)
               t)))
    (list :ids (mapcar #'cdr pairs) :room room :pairs pairs)))

(defun elneo-room--mention-pill-html (html pairs room)
  "Pillify the surviving mentions in the formatted body HTML.
PAIRS carries the (DISPLAY . USER-ID) conses
`elneo-room--send-mentions' filtered out of the draft; ROOM
pillifies the standalone \"@room\" token.  The pills are what other
clients render as the mention — the `m.mentions' block only alerts
— so without the HTML anchors a mention still looks like plain text
there (the room observation that started this: an Element-family
receiver saw the name, unhighlighted).

The alternatives match each display's HTML-escaped form with a
non-alphanumeric boundary on every side, longest first, in one
scanning pass — the scan resumes at the display's end, so the
consumed boundary character stays available to the next mention's
opener and no anchor text is ever re-matched.  `<code>' regions —
inline and fenced — keep their literal text: code never grows links."
  (if (not (or pairs room))
      html
    (let* ((entries (nconc (sort (copy-sequence pairs)
                                 (lambda (a b)
                                   (> (length (car a)) (length (car b)))))
                           (when room '(("@room" . "@room")))))
           (regex (string-join
                   (cl-loop for entry in entries collect
                            (format "\\(?:\\`\\|[^[:alnum:]]\\)\\(%s\\)\\(?:[^[:alnum:]]\\|\\'\\)"
                                    (regexp-quote
                                     (elneo-room--html-escape (car entry)))))
                   "\\|")))
      ;; Pillify everything outside `<code>' regions (inline and
      ;; fenced): each region rides the output verbatim, from its
      ;; opening tag through its closing one.
      (let ((pos 0)
            (out nil))
        (while (< pos (length html))
          (let ((open (string-search "<code>" html pos)))
            (if open
                (let ((close (string-search "</code>" html open)))
                  (push (elneo-room--mention-pill-region
                         (substring html pos open) entries regex) out)
                  (if close
                      (progn
                        (push (substring html open (+ close 7)) out)
                        (setq pos (+ close 7)))
                    (push (substring html open) out)
                    (setq pos (length html))))
              (push (elneo-room--mention-pill-region
                     (substring html pos) entries regex) out)
              (setq pos (length html)))))
        (apply #'concat (nreverse out))))))

(defun elneo-room--mention-pill-region (text entries regex)
  "Pillify one code-free HTML region TEXT against ENTRIES.
REGEX matches every entry's escaped display text with a captured
group per alternative.  Scan-match, replace the display text with
the matrix.to anchor, keep exactly one boundary character each
side (none at the string edge); the scan moves to the display's
end, not the match's."
  (let ((pos 0)
        (out nil))
    (while (< pos (length text))
      (if (string-match regex text pos)
          (let ((mb (match-beginning 0))
                (me (match-end 0)))
            (if-let* ((found (cl-loop for i from 1
                                      for entry in entries
                                      if (match-beginning i)
                                      return (cons entry i))))
                (let* ((entry (car found))
                       (i (cdr found))
                       (gstart (match-beginning i))
                       (gend (match-end i)))
                  (push (substring text pos mb) out)
                  (push (concat
                         ;; The boundary character rides the match;
                         ;; give it back — but none when \` matched
                         ;; empty at the edge.  The trailing boundary
                         ;; is not reinserted: the scan resumes with
                         ;; it in place, as the next match's opener.
                         (when (> gstart mb)
                           (substring text mb (1+ mb)))
                         (format "<a href=\"https://matrix.to/#/%s\">%s</a>"
                                 (cdr entry)
                                 (substring text gstart gend)))
                        out)
                  (setq pos gend))
              ;; No group answered (not by construction) — ride on.
              (push (substring text pos me) out)
              (setq pos me)))
        (push (substring text pos) out)
        (setq pos (length text))))
    (apply #'concat (nreverse out))))

(defun elneo-room--maybe-autocomplete-mention ()
  "Open the mention picker when the last typed character was a fresh `@'.
Fresh = opening the draft or riding right behind whitespace; an
`@' glued onto text stays inert — foo@bar.com is an email, not a
mention.  Keyed on this command having self-inserted the `@'
before point, so a completion aborted with C-g never re-fires:
that `@' is no longer the freshest insertion."
  (when (and elneo-room-mention-auto-complete
             (eq this-command 'self-insert-command)
             (equal (char-before) ?@)
             (or ;; the `@' opens the draft input.
              (eq (1- (point)) (elneo-room--input-beg-pos))
              ;; the `@' opens a fragment: what precedes it must be
              ;; whitespace, not the word it is glued onto.
              (memq (char-after (- (point) 2)) '(?  ?\t ?\n))))
    (elneo-room--complete-mention)))

;;; Outgoing formatted bodies

(defcustom elneo-room-plain-bridges '("telegram")
  "Bridge protocols whose rooms send plain text only.
Formatting that renders nicely in Matrix does not necessarily survive
a relay — Telegram strips HTML styling, for example — so a room
bridged into one of these protocols sends exactly what was typed: no
formatted body at all, markup characters stay literal, yanked faces
are dropped.  The protocol names come from the room's bridge state
event — the \"Bridged into\" line in the room settings (\\[elneo-room-settings])
names them — and match case-insensitively.  Native and unlisted
rooms keep sending rich text."
  :type '(repeat (string :tag "Bridge protocol"))
  :group 'elneo-room)


(defun elneo-room--rich-send-p (&optional room)
  "Whether ROOM accepts a formatted body on send.
nil when the room is bridged into a protocol listed in
`elneo-room-plain-bridges' — those relays mangle HTML, so the send
goes plain-only.  ROOM defaults to the current room buffer's record."
  (let* ((room (or room (elneo-room-get elneo-room--profile
                                        elneo-room--room-id)))
         (bridge (and room (plist-get room :bridge))))
    (or (null bridge)
        (not (cl-member bridge elneo-room-plain-bridges
                        :test #'string-equal-ignore-case)))))

(defun elneo-room--html-escape (s)
  "Escape &, < and > in S for embedding in HTML.
& goes first — escaping it last would re-escape the ampersands
the &lt;/&gt; substitutions just introduced."
  (replace-regexp-in-string
   "<" "&lt;"
   (replace-regexp-in-string
    ">" "&gt;"
    (replace-regexp-in-string "&" "&amp;" s))))

(defun elneo-room--format-inline (text)
  "Apply inline markup to HTML-escaped TEXT.
Links first (so their URLs are never mangled by the later
transforms), then `code', **bold** and /italic/."
  (setq text (replace-regexp-in-string elneo-room--url-regexp
                                       "<a href=\"\\1\">\\1</a>" text))
  (setq text (replace-regexp-in-string
              "`\\([^`\n]+\\)`"
              "<code>\\1</code>" text))
  (setq text (replace-regexp-in-string
              "\\*\\*\\([^*\n]+\\)\\*\\*"
              "<strong>\\1</strong>" text))
  ;; The boundary characters ride along in the match and are
  ;; reinserted, so /this/ only marks up with a space (or string
  ;; edge) before it and punctuation or space after — "a/b/c" paths
  ;; never italicize.
  (setq text (replace-regexp-in-string
              "\\([[:space:]]\\|\\`\\)/\\([^/\n]+\\)/\\([[:space:][:punct:]]\\|\\'\\)"
              "\\1<em>\\2</em>\\3" text))
  text)

(defun elneo-room--formatted-body (text)
  "Convert draft TEXT to an `org.matrix.custom.html' formatted body.
The markup subset: ``` fenced blocks, `code' spans, **bold**,
/italic/ and bare http(s) links.  nil when TEXT carries none of it
— the plain body is the whole message then, byte for byte as
before this existed."
  (let* ((escaped (elneo-room--html-escape text))
         (parts (split-string escaped "```"))
         (code-p nil)
         (markedp nil)
         (out nil))
    (dolist (part parts)
      (if code-p
          (progn
            (when (> (length part) 0) (setq markedp t))
            (push (format "<pre><code>%s</code></pre>" part) out))
        (let ((inline (elneo-room--format-inline part)))
          (unless (string-equal inline part) (setq markedp t))
          (push inline out)))
      (setq code-p (not code-p)))
    (and markedp (apply #'concat (nreverse out)))))

(defun elneo-room--face-attr (face attr)
  "Resolve face attribute ATTR (a keyword) from a `face' value.
FACE is a `face' text property value: nil, a face symbol, a list of
faces or specs, or a spec plist like (:foreground \"#ff0000\") — what
fontified yanks actually carry.  nil when nothing sensible resolves;
a spec plist without ATTR resolves to nil, not `unspecified'."
  (cond
   ((or (null face) (eq face 'default)) nil)
   ;; A spec plist starts with a keyword; `car-safe' guards the
   ;; symbol-face case.
   ((keywordp (car-safe face)) (plist-get face attr))
   ((symbolp face)
    (let ((value (face-attribute face attr nil t)))
      (unless (eq value 'unspecified) value)))
   ;; A list of faces: the first to define ATTR wins.
   ((listp face)
    (catch 'found
      (dolist (member face)
        (when-let* ((value (elneo-room--face-attr member attr)))
          (throw 'found value)))
      nil))
   (t nil)))

(defun elneo-room--color-css (color)
  "Normalize COLOR (a color name or #rrggbb) to a CSS #rrggbb string.
nil when COLOR does not resolve."
  (if (and (stringp color)
           (string-match-p "\\`#[0-9a-fA-F]\\{6\\}\\'" color))
      (downcase color)
    (when-let* ((rgb (ignore-errors (color-values color))))
      (format "#%02x%02x%02x"
              (/ (nth 0 rgb) 257) (/ (nth 1 rgb) 257) (/ (nth 2 rgb) 257)))))

(defun elneo-room--face-css (face)
  "CSS declarations for FACE, a `face' property value.
nil when FACE resolves to no foreground, bold or italic — the text
run then passes through unwrapped."
  (let* ((fg (elneo-room--face-attr face :foreground))
         (weight (elneo-room--face-attr face :weight))
         (slant (elneo-room--face-attr face :slant))
         (decls (nconc
                 (when-let* ((hex (and fg (elneo-room--color-css fg))))
                   (list (format "color:%s" hex)))
                 (when (memq weight '(bold semi-bold extra-bold ultra-bold))
                   (list "font-weight:bold"))
                 ;; Oblique is italic enough for CSS.
                 (when (and slant (not (memq slant '(normal upright))))
                   (list "font-style:italic")))))
    (and decls (string-join decls ";"))))

(defun elneo-room--face-runs (text)
  "Split TEXT into a list of (FACE . CHUNK) runs of equal `face'."
  (let ((runs nil)
        (start 0)
        (len (length text))
        (face (get-text-property 0 'face text)))
    (let ((i 1))
      (while (<= i len)
        (when (or (= i len)
                  (not (equal (get-text-property i 'face text) face)))
          (push (cons face (substring text start i)) runs)
          (setq start i
                face (get-text-property i 'face text)))
        (cl-incf i)))
    (nreverse runs)))

(defun elneo-room--face-runs-html (text &optional no-markup)
  "Render TEXT's face runs as HTML: escape and mark up each run, wrap
it in a <span> when its face resolves to any CSS.  NO-MARKUP skips
the inline markup pass — code regions stay fully literal."
  (let ((out nil))
    (dolist (run (elneo-room--face-runs text))
      (let ((html (elneo-room--html-escape (cdr run))))
        (unless no-markup
          (setq html (elneo-room--format-inline html)))
        (when-let* ((css (and (car run) (elneo-room--face-css (car run)))))
          (setq html (format "<span style=\"%s\">%s</span>" css html)))
        (push html out)))
    (substring-no-properties (apply #'concat (nreverse out)))))

(defun elneo-room--fontified-p (text)
  "Non-nil when TEXT carries a face run with resolvable CSS.
A stray :background-only face (hl-line, say) does not count."
  (let ((i 0)
        (len (length text)))
    (catch 'found
      (while (< i len)
        (when-let* ((face (get-text-property i 'face text)))
          (when (elneo-room--face-css face)
            (throw 'found t)))
        (cl-incf i))
      nil)))

(defun elneo-room--fontified-body (text)
  "Convert propertized draft TEXT to `org.matrix.custom.html'.
With resolvable faces on it, each run renders as a styled <span>
(see `elneo-room-yank-fontify'); unpropertized drafts take the
plain markup path (`elneo-room--formatted-body') unchanged.
```-fenced blocks keep their existing shape — escaped as-is, faces
ignored inside.  Non-nil whenever TEXT is fontified (the faces are
the markup then); otherwise whatever the plain path returns."
  (if (not (elneo-room--fontified-p text))
      (elneo-room--formatted-body text)
    (let ((parts (split-string text "```"))
          (code-p nil)
          (out nil))
      (dolist (part parts)
        (push (if code-p
                  (format "<pre><code>%s</code></pre>"
                          (elneo-room--html-escape
                           (substring-no-properties part)))
                (elneo-room--face-runs-html part))
              out)
        (setq code-p (not code-p)))
      (substring-no-properties (apply #'concat (nreverse out))))))

(defun elneo-room--send-text (body &optional mentions)
  "Send trimmed BODY as a text message, ignoring empty segments.
MENTIONS optionally carries the mentions plist
`elneo-room--send-mentions' builds (:ids IDS :room ROOM) — the IDS
tag an `m.mentions' block, ROOM the @room everyone-flag.
In reply mode the reply rides this (first) text segment and is
consumed here; in edit mode the segment replaces the edited message
instead of sending a new one.  Attachment tags in a reply draft send
as plain, non-reply attachments.

A new message renders as a provisional block immediately (the
optimistic echo; see `elneo-room--insert-provisional'); an edit
renders nothing — the `updateEdited' echo re-renders the target,
and a failed ack restores the text to the draft."
  (setq body (string-trim body))
  (when (> (length body) 0)
    ;; Callers without a mention plist (the dispatch from the draft)
    ;; get the same body-presence filter, so both send paths mention
    ;; alike; a caller that computed it already keeps it.
    (let* ((m (or mentions (elneo-room--send-mentions body)))
           (reply-to elneo-room--reply-to)
           (edit-to elneo-room--edit-to)
           ;; In a thread view, every send is a thread reply under
           ;; this view's root; reply mode still names the in-thread
           ;; target (a genuine m.in_reply_to for Element).  In the
           ;; room view, replying to a message that BELONGS to a
           ;; thread sorts the reply into that thread the same way —
           ;; the target's relation names the root, the send carries
           ;; it, and the daemon's thread-aware sendMessage keeps the
           ;; reply there (the real m.in_reply_to stays on the wire
           ;; for Element).
           (thread-root (or elneo-room--thread-root
                            (and reply-to
                                 (plist-get (gethash reply-to
                                                     elneo-room--seen)
                                            :thread-root))))
           ;; The rich gate first: a plain-listed bridge sends the draft
           ;; exactly as typed (no formatted body at all), and
           ;; `elneo-room-yank-fontify' decides whether yanked faces
           ;; convert to HTML spans or only the plain markup applies.
           (formatted (and (elneo-room--rich-send-p)
                           (if elneo-room-yank-fontify
                               (elneo-room--fontified-body body)
                             (elneo-room--formatted-body
                              (substring-no-properties body))))))
      ;; The wire body and the optimistic echo carry plain text only —
      ;; the faces live on in FORMATTED, never in the fallback.
      (setq body (substring-no-properties body))
      ;; The mention pills ride the formatted body: the matrix.to
      ;; anchors are what other clients render as the mention; the
      ;; `m.mentions' block only alerts.  The plain-fallback path
      ;; stays plain — no formatted body, no pill.
      (when formatted
        (setq formatted (elneo-room--mention-pill-html
                         formatted (plist-get m :pairs) (plist-get m :room))))
      ;; The send first: it may signal from a dead daemon
      ;; (`elneo-server--send') and must then leave the reply/edit
      ;; markers (and their separator line) intact and the draft
      ;; un-echoed — a retry is the same RET again.
      (let ((req (elneo-send-message
                  elneo-room--profile elneo-room--room-id body
                  (elneo-room--send-ack-callback edit-to body)
                  ;; Rich markup rides along when the draft carries
                  ;; any; plain BODY is the fallback either way.
                  formatted
                  reply-to
                  ;; The relation slot carries only one: an edit never
                  ;; also replies (the daemon picks `replaces' when
                  ;; both arrive, which cannot happen — r clears edit
                  ;; state and vice versa).
                  edit-to
                  (plist-get m :ids)
                  (plist-get m :room)
                  thread-root)))
        (unless edit-to
          (elneo-room--insert-provisional
           (elneo-room--pending-id req) body formatted reply-to
           thread-root))
        (when (or reply-to edit-to)
          (setq elneo-room--reply-to nil
                elneo-room--reply-sender nil
                elneo-room--edit-to nil)
          (elneo-room--update-separator))))))

(defun elneo-room--send-media (path sender &optional scale)
  "Upload the file at PATH to this room via SENDER.
SENDER is `elneo-room-image' for images, `elneo-room-file' for
anything else; both take (profile room-id path callback
&optional thread-root scale).  A send from a thread view threads
the attachment into that thread; SCALE sizes image uploads."
  (let ((file (expand-file-name path)))
    (if (file-exists-p file)
        ;; elneo-room--thread-root is nil in room buffers, the view's
        ;; thread in a thread view.
        (funcall sender elneo-room--profile elneo-room--room-id file
                 #'elneo-room--on-send-result
                 elneo-room--thread-root scale)
      (message "Matrix: no such file: %s" file))))

(defun elneo-room--send-image (path &optional scale)
  "Upload the image file at PATH to this room, scaled by SCALE."
  (elneo-room--send-media path #'elneo-room-image scale))

(defun elneo-room--send-file (path &optional scale)
  "Upload the file at PATH to this room, scaled by SCALE."
  (elneo-room--send-media path #'elneo-room-file scale))

(defun elneo-room--on-send-result (profile event)
  "Report a failed send for PROFILE; success stays silent.
Used by the sends that render no provisional block — media
uploads, redactions.  Text messages run the full local-echo
lifecycle through `elneo-room--send-ack-callback' instead."
  (unless (alist-get '@ok event nil nil #'equal)
    (message "Matrix [%s] send failed: %s" profile
             (elneo-server--error-string event))))

;;; Send a region as code

(defconst elneo-code-language-alist
  '((lisp-interaction-mode . "lisp")
    (emacs-lisp-mode . "lisp")
    (lisp-mode . "lisp")
    (scheme-mode . "scheme")
    (clojure-mode . "clojure")
    (python-mode . "python")
    (python-ts-mode . "python")
    (rust-mode . "rust")
    (rustic-mode . "rust")
    (c-mode . "c")
    (c-ts-mode . "c")
    (c++-mode . "cpp")
    (c++-ts-mode . "cpp")
    (java-mode . "java")
    (julia-mode . "julia")
    (ruby-mode . "ruby")
    (perl-mode . "perl")
    (sh-mode . "bash")
    (shell-mode . "bash")
    (go-mode . "go")
    (go-ts-mode . "go")
    (rust-ts-mode . "rust")
    (js-mode . "javascript")
    (js2-mode . "javascript")
    (js-ts-mode . "javascript")
    (typescript-mode . "typescript")
    (typescript-ts-mode . "typescript")
    (haskell-mode . "haskell")
    (ocaml-mode . "ocaml")
    (lua-mode . "lua")
    (nix-mode . "nix")
    (elixir-mode . "elixir")
    (sql-mode . "sql")
    (yaml-mode . "yaml")
    (yaml-ts-mode . "yaml")
    (json-mode . "json")
    (json-ts-mode . "json")
    (toml-mode . "toml")
    (markdown-mode . "markdown")
    (org-mode . "org"))
  "Major modes carrying a code-block language tag, exact names first.")

(defun elneo--major-mode-language ()
  "Language tag for the current buffer's major mode, or nil.
`elneo-code-language-alist' carries the exact names; anything else
falls back to the symbol name before `-mode' (\"go-mode\" -> \"go\"
the alist has it anyway)."
  (or (cdr (assq major-mode elneo-code-language-alist))
      (when-let* ((name (symbol-name major-mode))
                  (base (string-remove-suffix "-mode" name)))
        base)))

(defun elneo-room--code-target-room ()
  "Return the room record to send a region to.
One visible room buffer is used as-is; anything else prompts.
Mirrors `elneo-dired--target-room' locally — the dired require
backs into this file, so referencing it would be a require cycle."
  (let ((visible
         (cl-remove-if-not
          (lambda (buffer)
            (and (elneo-buffer-visible-p buffer)
                 (eq (buffer-local-value 'major-mode buffer)
                     'elneo-room-mode)))
          (buffer-list))))
    (if (= (length visible) 1)
        (with-current-buffer (car visible)
          (elneo-room-get elneo-room--profile elneo-room--room-id))
      (elneo-completing-read-room))))

;;;###autoload
(defun elneo-send-region-as-code (begin end &optional arg)
  "Send the region between BEGIN and END to a Matrix room as code.
Like `elneo-dired-send-files' — no draft stop, the block leaves
this buffer right away — but as a code block: the plain body keeps
the ``` fence (fallback for clients without formatted bodies), and
a <pre><code> formatted body always rides along — Telegram and
other relays render that fine.  The region's fontification as color
spans, by contrast, only goes where
`elneo-room--rich-send-p' allows it; bridged rooms get the code
block without the colors.  The language tag comes from the source
buffer's major mode (\\[universal-argument] prompts for it, with
the detected one as the default;
`elneo-code-language-alist' carries the known modes, other modes
fall back to their symbol name before \"-mode\").

The target: the single visible room buffer when there is exactly
one, else `elneo-completing-read-room'."
  (interactive "r\nP")
  (let* ((room (elneo-room--code-target-room))
         (room-name (or (plist-get room :display-name) (plist-get room :room-id)))
         (detected (elneo--major-mode-language))
         (lang (if arg
                   (string-trim
                    (read-string (format "Code block language (default %s): "
                                         (or detected "none"))
                                 nil nil (or detected "")))
                 detected))
         (lang (and (not (string-empty-p lang)) lang))
         (text (buffer-substring-no-properties begin end))
         ;; The colored code: face runs over a props-carrying read of
         ;; the region; the markup pass is skipped — the selection is
         ;; already code, its characters stay literal.  Plain-listed
         ;; bridges (and fontify off) drop the spans, not the block:
         ;; pre/code itself survives every relay.
         (code (if (and elneo-room-yank-fontify (elneo-room--rich-send-p room))
                   (elneo-room--face-runs-html (buffer-substring begin end) t)
                 (elneo-room--html-escape text)))
         (formatted (format "<pre><code%s>%s</code></pre>"
                            (if lang
                                (format " class=\"language-%s\"" lang)
                              "")
                            code))
         (body (format "```%s\n%s\n```" (or lang "")
                       (string-trim-right text))))
    (message "Matrix: sending code to %s" room-name)
    (elneo-send-message (plist-get room :profile) (plist-get room :room-id)
                        body (lambda (profile event)
                               (elneo-room--on-send-result profile event))
                        formatted)))

;;; Send lifecycle: local echo

;; RET inserts a provisional block immediately (⏱, keyed by the send
;; request id); the `updateSendResult' ack swaps it to the server's
;; event id, and the later sync echo no-ops against the seen table.
;; A failed ack flips the block to ✗ with `R'/`K' keys on it; an edit
;; — which renders no provisional block — puts its text back into the
;; draft with the edit marker restored.

(defconst elneo-room--pending-id-prefix "$~pending-"
  "Prefix of the synthetic event ids keying provisional messages.
Real Matrix event ids start with `$' too, but never contain `~'
this early — and the guards on `r'/`e'/`d' keep these ids from
reaching the server anyway.")

(defun elneo-room--pending-id (req)
  "Synthetic event id for the provisional echo of send request REQ."
  (format "%s%d" elneo-room--pending-id-prefix req))

(defun elneo-room--provisional-p (id)
  "Non-nil when ID keys a provisional (locally echoed) message."
  (and (stringp id)
       (string-prefix-p elneo-room--pending-id-prefix id)))

(defun elneo-room--unsent-p (msg)
  "Non-nil when MSG is a provisional message the server does not have.
Pending (⏱, still in flight) or failed (✗): reply, edit, react and
redact all need a real event id the server knows, so the point
commands refuse these."
  (and msg (or (plist-get msg :pending)
               (plist-get msg :send-failed))))

(defun elneo-room--own-sender ()
  "Cons (USER-ID . NAME) of this buffer's account, for local echoes.
The name mirrors what the daemon echoes for own messages: the most
recent rendered own message's sender name when there is one, else
the user id's local part — so the provisional block and the real
echo it turns into agree on the name."
  (let* ((uid (plist-get (alist-get elneo-room--profile elneo-accounts
                                    nil nil #'equal)
                         :user-id))
         (name (catch 'name
                 (dolist (id (reverse (elneo-room--ordered-event-ids)))
                   (let ((msg (gethash id elneo-room--seen)))
                     (when (and msg (plist-get msg :is-own)
                                (plist-get msg :sender-name))
                       (throw 'name (plist-get msg :sender-name))))))))
    (cons (or uid "me")
          (or name
              (and uid
                   (if (string-match "\\`@\\([^:]*\\):" uid)
                       (match-string 1 uid)
                     uid))
              "you"))))

(defun elneo-room--insert-provisional (pending-id body formatted-body reply-to &optional thread-root)
  "Insert the optimistic echo of a message just handed to the daemon.
The provisional block renders like any own message (a reply quotes
its parent, whose seen entry is already there) with the ⏱ marker;
`elneo-room--on-send-ack' re-keys it to the real event id.  A
thread send carries THREAD-ROOT (the view's pinned root), so the
block renders as the thread reply it will be.  No-op when no
history page is rendered yet — the sync echo will place the
message."
  (when (and elneo-room--backfilled
             (markerp elneo-room--append-point)
             (marker-buffer elneo-room--append-point))
    (let ((last elneo-room--last-event-id))
      (save-excursion
        (goto-char (marker-position elneo-room--append-point))
        (let* ((own (elneo-room--own-sender))
               (msg (list :event-id pending-id
                          :sender (car own)
                          :sender-name (cdr own)
                          :ts (floor (* (float-time) 1000))
                          :msgtype "m.text"
                          :body body
                          :formatted-body formatted-body
                          :is-own t
                          :pending t)))
          (when reply-to
            (plist-put msg :reply-to reply-to))
          (when thread-root
            (plist-put msg :thread-root thread-root))
          ;; `elneo-room--append-messages' claims the event id as the
          ;; buffer's newest — true for real messages, wrong here:
          ;; read receipts must only ever name server events.  Restore
          ;; the last real id; the ack swap sets the real one.
          (elneo-room--append-messages (list msg))
          (setq elneo-room--last-event-id last))))
    ;; The user just typed this; the view follows it to the end like a
    ;; live echo does.
    (let ((window (get-buffer-window (current-buffer) t)))
      (when window
        (elneo-room--show-end window 'keep-point)))))

(defun elneo-room--send-ack-callback (edit-to body)
  "Return the `updateSendResult' callback for a text send.
The response echoes `@req', which keys the provisional message
(`elneo-room--pending-id'), so the callback needs nothing from
the call site.  It closes over this buffer: the daemon process
filter runs it from wherever, so the buffer may be dead (then the
whole ack no-ops — the sync echo covers the rendering) or rebuilt
(seen table reset; a failure then falls back to restoring the
draft).  EDIT-TO names the edited event when the send was an edit,
BODY the text; both are kept for the failure path.  A failed new
message keeps its reply on the provisional block itself, so `R'
re-sends it as the reply it was."
  (let ((buffer (current-buffer)))
    (lambda (_profile event)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (elneo-room--on-send-ack
           event (elneo-room--pending-id (alist-get '@req event))
           edit-to body))))))

(defun elneo-room--on-send-ack (event pending-id edit-to body)
  "Handle the send ack EVENT for provisional PENDING-ID.
Success re-keys the provisional block to the server's event id — or
drops it when the sync echo won the race and rendered the real
message first, whichever arrived first wins.  A failure flips the
block to the failed state (`R' retries, `K' removes); an edit,
which renders no provisional block, gets its text and edit marker
restored to the draft (see `elneo-room--send-failed')."
  (if (not (alist-get '@ok event nil nil #'equal))
      (elneo-room--send-failed event pending-id edit-to body)
    (let ((event-id (alist-get 'event_id event)))
      (when (and event-id (gethash pending-id elneo-room--seen))
        (let ((msg (gethash pending-id elneo-room--seen)))
          (if (gethash event-id elneo-room--seen)
              ;; The sync echo won the race: the real message is
              ;; rendered, the provisional is a duplicate now.
              (elneo-room--remove-message pending-id)
            (plist-put msg :pending nil)
            (elneo-room--replace-message pending-id msg event-id)
            ;; `elneo-room--last-event-id' must name a real event —
            ;; read receipts go to the server with it, and a
            ;; provisional id would be rejected.  The echo, which
            ;; normally sets it here, no-ops against the re-keyed
            ;; seen entry.
            (setq elneo-room--last-event-id event-id)))))))

(defun elneo-room--send-failed (event pending-id edit-to body)
  "Report a failed send and keep its text recoverable.
An edit puts BODY and the edit marker back into the draft (the
draft was consumed on send; nothing else holds the text).  A new
message keeps its provisional block, flipping ⏱ to ✗ with the `R'
(retry) and `K' (remove) keys on it.  When the buffer was rebuilt
since the send (seen table reset, block gone), the draft restores
the text — a failed reply loses its relation in that case, rare as
it is; the draft is worth more than the quote."
  (let ((reason (elneo-server--error-string event)))
    (if (or edit-to (null (gethash pending-id elneo-room--seen)))
        (progn
          (when edit-to
            (setq elneo-room--edit-to edit-to)
            (elneo-room--update-separator))
          (elneo-room--restore-draft body)
          (message "Matrix [%s] send failed: %s — text restored to the draft"
                   elneo-room--profile reason))
      (let ((msg (gethash pending-id elneo-room--seen)))
        (plist-put msg :pending nil)
        (plist-put msg :send-failed t)
        (elneo-room--replace-message pending-id msg)
        (message "Matrix [%s] send failed: %s — R retries, K removes"
                 elneo-room--profile reason)))))

(defun elneo-room--restore-draft (body)
  "Put failed-send text BODY back into the draft area.
Text typed since the send stays, below the restored body."
  (let ((had-text (> (length (string-trim (elneo-room--draft-text))) 0)))
    (save-excursion
      (goto-char (elneo-room--input-beg-pos))
      (let ((inhibit-read-only t))
        (insert body)
        (when had-text
          (insert "\n"))))))

(defun elneo-room--remove-message (event-id)
  "Delete the rendered block of EVENT-ID and its seen-table entry.
The removal counterpart of `elneo-room--replace-message'; the
send lifecycle uses it when a failed provisional message is
dismissed (`K') and when the sync echo already rendered the real
message a provisional was standing in for.  A day separator drawn
for a removed message goes too, unless a rendered message of the
same day remains below it."
  (let ((bounds (elneo-room--block-bounds event-id)))
    (when bounds
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (car bounds))
          (let* ((ts (get-text-property (elneo-room--find-event event-id)
                                        'elneo-room-ts))
                 (below-ts (save-excursion
                             (goto-char (cdr bounds))
                             (or (get-text-property (point) 'elneo-room-ts)
                                 (get-text-property
                                  (next-single-property-change
                                   (point) 'elneo-room-ts nil (point-max))
                                  'elneo-room-ts)))))
            (delete-region (car bounds) (cdr bounds))
            ;; The separator above the block was drawn for its day;
            ;; keep it only while a message of that day remains below.
            (when (and ts below-ts
                       (not (equal (elneo-room--day ts)
                                   (elneo-room--day below-ts))))
              (save-excursion
                (goto-char (car bounds))
                (when (eq (get-text-property (line-beginning-position 0)
                                             'face)
                          'elneo-room-day-separator)
                  (delete-region (line-beginning-position 0)
                                 (progn (forward-line 1) (point))))))))))
    (remhash event-id elneo-room--seen)))

(elneo-room--defkey elneo-room--R ?R
  "Retry the failed send at point.
The body — and the reply relation, when it was a reply — go out
again as a fresh send with its own provisional echo.  Nothing is
edited or queued: the previous attempt is over, this is a new
message to the server."
  (let* ((id (elneo-room--event-id-at (point)))
         (msg (and id (gethash id elneo-room--seen))))
    (cond
     ((null msg) (user-error "No message at point"))
     ((not (plist-get msg :send-failed))
      (user-error "No failed send at point — R retries a ✗ message"))
     (t
      (let* ((reply-to (plist-get msg :reply-to))
             (body (plist-get msg :body))
             (m (elneo-room--send-mentions body))
             (req (elneo-send-message
                   elneo-room--profile elneo-room--room-id body
                   ;; The send may signal (dead daemon); nothing below
                   ;; runs then and the block stays in its failed state.
                   (elneo-room--send-ack-callback nil body)
                   (plist-get msg :formatted-body)
                   reply-to
                   ;; A retry is a fresh send, never an edit (failed
                   ;; edits restore the draft instead): nil replaces,
                   ;; and the slots below mirror --send-text's order —
                   ;; R re-sends with its mentions and, in a thread
                   ;; view, its thread relation.
                   nil
                   (plist-get m :ids)
                   (plist-get m :room)
                   (plist-get msg :thread-root))))
        (plist-put msg :send-failed nil)
        (plist-put msg :pending t)
        (elneo-room--replace-message
         id msg (elneo-room--pending-id req)))))))

(elneo-room--defkey elneo-room--K ?K
  "Discard the failed or still-pending local message at point.
Removes the block from the buffer; nothing ever reached the
server.  Discarding a pending message does not stop the send — the
sync echo renders it again when the server has it."
  (let* ((id (elneo-room--event-id-at (point)))
         (msg (and id (gethash id elneo-room--seen))))
    (cond
     ((null msg) (user-error "No message at point"))
     ((not (or (plist-get msg :send-failed) (plist-get msg :pending)))
      (user-error "Only unsent local messages can be discarded — K needs ⏱ or ✗"))
     (t
      (elneo-room--remove-message id)
      (message "Matrix: discarded")))))

;;; Draft persistence

;; Matrix has no server-side drafts (unlike telega's TDLib drafts), so
;; local persistence is the whole parity story.  Nothing here ever
;; leaves the machine: drafts are stored per (profile . room-id) in
;; one local file and never sent anywhere.

(defcustom elneo-room-drafts-file
  (expand-file-name "drafts.el" (elneo--data-dir-base))
  "File keeping room drafts across sessions and restarts.
One entry per (profile . room-id).  Written with 0600 permissions;
never leaves the local machine.  The default keeps it out of
`user-emacs-directory': drafts are Matrix client data, so they live
in the shared data directory next to the daemon's per-profile
state (see `elneo--data-dir-base')."
  :type 'file
  :group 'elneo-room)

(defvar elneo-room--drafts-legacy-file
  (expand-file-name "elneo-drafts.el" user-emacs-directory)
  "The pre-2026-10 drafts location, checked once for migration.
Only read, never written; delete it once the new file exists.")

(defcustom elneo-room-draft-save-delay 1.0
  "Idle seconds before a changed draft is written to disk.
The in-memory store updates immediately; only the disk write waits."
  :type 'number
  :group 'elneo-room)

(defvar elneo-room--draft-store nil
  "Drafts table: (profile . room-id) -> text.  Nil until first load.")

(defvar elneo-room--draft-save-timer nil
  "Idle timer for the pending drafts disk write.")

(defvar elneo-room--drafts-dirty nil
  "Non-nil when the drafts table changed since the last disk write.")

(defvar-local elneo-room--draft-saved-text nil
  "Buffer-local: this draft as last recorded in the store.")

(defvar-local elneo-room--pending-draft nil
  "Buffer-local: draft restored from disk for a fresh buffer.
`elneo-room--render-first-page' moves it into the input area once
the first history page lands.")

(defun elneo-room--draft-read-entries (file)
  "Load the alist of drafts from FILE into the store.
Signals on a malformed file; the caller decides how loud to be."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (dolist (entry (read (current-buffer)))
      (puthash (car entry) (cdr entry) elneo-room--draft-store))))

(defun elneo-room--draft-store ()
  "The drafts table, loading `elneo-room-drafts-file' on first use.
When that file does not exist yet but the legacy
`elneo-room--drafts-legacy-file' does, its entries are adopted and
the next save writes them to the new location (the legacy file is
only ever read)."
  (or elneo-room--draft-store
      (progn
        (setq elneo-room--draft-store (make-hash-table :test 'equal))
        (if (file-readable-p elneo-room-drafts-file)
            (condition-case err
                (elneo-room--draft-read-entries elneo-room-drafts-file)
              (error
               (message "Matrix: ignoring unreadable drafts file: %s"
                        (error-message-string err))))
          ;; First run after the location change: adopt old drafts once.
          (when (file-readable-p elneo-room--drafts-legacy-file)
            (condition-case err
                (progn
                  (elneo-room--draft-read-entries
                   elneo-room--drafts-legacy-file)
                  (setq elneo-room--drafts-dirty t))
              (error
               (message "Matrix: ignoring unreadable drafts file: %s"
                        (error-message-string err))))))
        elneo-room--draft-store)))

(defun elneo-room--drafts-save ()
  "Write the drafts table to `elneo-room-drafts-file'.
Empty drafts are dropped; room buffers write sequentially, so no
locking is needed.  A failed write keeps the table dirty and re-arms
the timer — an error from an idle timer would otherwise surface as a
raw timer error and never retry."
  (setq elneo-room--draft-save-timer nil)
  (condition-case err
      (let ((entries nil))
        (maphash (lambda (key text)
                   (when (> (length text) 0)
                     (push (cons key text) entries)))
                 (elneo-room--draft-store))
        (let ((coding-system-for-write 'utf-8)
              (create-lockfiles nil))
          ;; The data dir belongs to the daemon's layout and may not exist
          ;; yet on a fresh client (seen on the Linux box): create it rather
          ;; than fail the save.
          (make-directory (file-name-directory elneo-room-drafts-file) 'parents)
          (with-temp-file elneo-room-drafts-file
            (insert ";; elneo.el room drafts -- local only, never sent\n")
            (pp entries (current-buffer)))
          (ignore-errors (set-file-modes elneo-room-drafts-file #o600)))
        (setq elneo-room--drafts-dirty nil))
    (error
     (message "Matrix: drafts save failed (%s); will retry"
              (error-message-string err))
     (when elneo-room--drafts-dirty
       (setq elneo-room--draft-save-timer
             (run-with-idle-timer elneo-room-draft-save-delay nil
                                  #'elneo-room--drafts-save))))))

(defun elneo-room--draft-maybe-save ()
  "Record this room's draft when it changed; schedule a disk write.
The store updates synchronously, so re-opening the room in this
session sees the new text at once — only the disk write is
debounced.  Before the first render there is no draft area; the
restored draft stays untouched until then.  A thread view never
saves a draft: its buffer is keyed by thread, not room — a thread
draft landing in the room's store would overwrite the room draft."
  (when (and elneo-room--backfilled
             (not elneo-room--thread-root))
    (let ((text (elneo-room--draft-text)))
      (unless (equal text elneo-room--draft-saved-text)
        (setq elneo-room--draft-saved-text text)
        (puthash (cons elneo-room--profile elneo-room--room-id)
                 text (elneo-room--draft-store))
        (setq elneo-room--drafts-dirty t)
        (when elneo-room--draft-save-timer
          (cancel-timer elneo-room--draft-save-timer))
        (setq elneo-room--draft-save-timer
              (run-with-idle-timer elneo-room-draft-save-delay nil
                                   #'elneo-room--drafts-save))))))

(defun elneo-room--draft-kill-save ()
  "Save this room's draft when its buffer is killed.
`kill-emacs-hook' flushes a still-dirty table on exit the same way."
  (elneo-room--draft-maybe-save)
  (when elneo-room--drafts-dirty
    (elneo-room--drafts-save)))

(add-hook 'kill-emacs-hook
          (lambda ()
            (when elneo-room--drafts-dirty
              (elneo-room--drafts-save))))

;;; Opening

(defun elneo-room--ensure-input-area ()
  "Rebuild the draft tail when this buffer lacks one.
The realistic trigger is `elneo-reload' keeping live buffers across
a code reload: an old version's buffer predates the current draft
layout (and may use `buffer-read-only' instead of text properties),
so rebuild the tail rather than demand a full re-fetch."
  (unless (and (markerp elneo-room--input-beg)
               (buffer-live-p (marker-buffer elneo-room--input-beg)))
    (setq buffer-read-only nil)
    (goto-char (point-max))
    (elneo-room--reset-input-area "")))

(defun elneo-room-diagnose ()
  "Report why this room buffer's draft (typing) area may be missing.
Run this from the room buffer that misbehaves; the report covers
which source file is loaded, the buffer's input-area state and the
window geometry, so a stale or shadowed load and a scroll-position
bug are distinguishable."
  (interactive)
  (let* ((sep (save-excursion
                (goto-char (point-min))
                (search-forward "── draft:" nil t)))
         (marker-ok (and (markerp elneo-room--input-beg)
                         (buffer-live-p (marker-buffer elneo-room--input-beg))))
         (win (get-buffer-window (current-buffer)))
         (elneo-buffers
          (delq nil (mapcar (lambda (b)
                              (and (string-match-p "\\*Matrix" (buffer-name b))
                                   (buffer-name b)))
                            (buffer-list))))
         (report
          (concat
           "elneo-room diagnose\n"
           "--------------------\n"
           (format "diagnosed buffer: %s\n" (buffer-name))
           (format "selected window shows: %s\n"
                   (buffer-name (window-buffer (selected-window))))
           (format "mode: %s  RET: %S  C-j: %S  C-c C-a: %S  C-c C-c: %S\n"
                   major-mode
                   (key-binding (kbd "RET")) (key-binding (kbd "C-j"))
                   (key-binding (kbd "C-c C-a")) (key-binding (kbd "C-c C-c")))
           (format "elneo buffers live: %s\n" elneo-buffers)
           (format "loaded elneo-room from: %s\n"
                   (locate-library "elneo-room"))
           (format "loaded elneo-client from: %s\n"
                   (locate-library "elneo-client"))
           (format "mode: %s  major-mode-map-live: %s\n"
                   major-mode
                   (and (boundp 'elneo-room-mode-map)
                        (keymapp elneo-room-mode-map)))
           (format "backfilled: %S\n" elneo-room--backfilled)
           (format "separator \"── draft:\" found: %S at pos %S\n"
                   (and sep t) sep)
           (format "input-beg marker live: %S pos: %S\n"
                   marker-ok
                   (when marker-ok (marker-position elneo-room--input-beg)))
           (format "point-max: %S  point: %S  read-only: %S\n"
                   (point-max) (point) buffer-read-only)
           (format "window: %S  window-start: %S  window-point: %S\n"
                   win (when win (window-start win))
                   (when win (window-point win)))
           (format "window-body-height: %S  end-start: %S  draft visible: %S\n"
                   (when win (window-body-height win))
                   (when win (elneo-room--end-start win))
                   (when (and win sep)
                     (pos-visible-in-window-p sep win)))
           (format "daemon: protocol %s, release %s\n"
                   (or (elneo-server--daemon-protocol elneo-room--profile)
                       "unknown")
                   (or (plist-get (elneo-server--daemon-info-for elneo-room--profile)
                                  :release)
                       "unknown"))
           (format "server process coding: %s\n"
                   (let ((proc (ignore-errors
                                 (elneo-server--get-process
                                  elneo-room--profile))))
                     (when (process-live-p proc)
                       (let ((cs (process-coding-system proc)))
                         (format "%s (decode) / %s (encode)"
                                 (car cs) (cdr cs))))))))
         (buf (get-buffer-create "*elneo diagnose*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert report))
      (goto-char (point-min)))
    (pop-to-buffer buf)))

(defcustom elneo-room-upgrade-leave nil
  "Also leave the old room after accepting a successor's invite.
A room upgrade leaves the old room dangling — its tombstone names
the replacement — and an invite to the successor then usually
means \"move along\".  Non-nil makes the invite prompt's `[j]oin'
do that move (it accepts, then leaves the predecessor; leaving
never forgets the room, the history stays reachable).  Off by
default — Element just leaves; here the choice is explicit, the
prompt's own `[L]' works either way."
  :type 'boolean
  :group 'elneo-room)

(defun elneo-room--invite-upgrade-predecessor (room)
  "The still-joined room ROOM's invite continues, or nil.
A successor invite only offers the post-accept leave when the room
its `:upgraded-from' names is one this client tracks as joined: a
registry record without `:removed' and with room-state \"joined\".
A record the session never knew (joined long ago on another
client, or before this daemon's first sync) offers no choice —
there is nothing to leave here honestly.  Old daemons send no
link at all."
  (let* ((old (plist-get room :upgraded-from))
         (old-room (and old (elneo-room-get (plist-get room :profile) old))))
    (and old-room
         (not (plist-get old-room :removed))
         (equal (plist-get old-room :room-state) "joined")
         old)))

(defun elneo-room--invite-prompt-string (name upgrade)
  "The invite prompt's key menu for NAME.
UPGRADE non-nil — the invite names a still-joined predecessor —
adds the explicit \"leave old too\" choice."
  (if upgrade
      (format "Invite to %s — [j]oin, [L]eave old too, [d]ecline, [i]gnore? " name)
    (format "Invite to %s — [j]oin, [d]ecline, [i]gnore? " name)))

(defun elneo-room-invite-prompt (room)
  "Offer the pending invite ROOM: join, decline or ignore.
The choice is read in the echo area (j/d/i; anything else
ignores).  Joining opens the room right away — the seed of its
history arrives with the updateRoom event which runs ahead of the
ack, so accepting from the bar lands you in a populated buffer.
Declining removes the bar row via updateRoomGone.

When the invite is a room upgrade's successor invite
(`elneo-room--invite-upgrade-predecessor' names a still-joined
older room), an explicit `[L]' accepts and then also leaves that
older room — the leave after the accept ack, an updateRoomGone
removing its row.  Never silently: even a non-nil
`elneo-room-upgrade-leave' turns plain `[j]' into that move, it
does not skip the asking — the prompt is the ask."
  (let* ((profile (plist-get room :profile))
         (room-id (plist-get room :room-id))
         (name (or (plist-get room :display-name) room-id))
         (old (elneo-room--invite-upgrade-predecessor room))
         (accept
          (lambda (also-leave-old)
            (elneo-accept-invite
             profile room-id
             (lambda (_profile event)
               (if (not (alist-get '@ok event nil nil #'equal))
                   (message "Matrix [room]: join failed — %s"
                            (elneo-server--error-string event))
                 (let ((fresh (elneo-room-get profile room-id)))
                   (if fresh (elneo-room-open fresh)
                     (message "Matrix [room]: joined %s" name)))
                 (when also-leave-old
                   (elneo-leave-room
                    profile old
                    (lambda (_p ack)
                      (unless (alist-get '@ok ack nil nil #'equal)
                        (message
                         "Matrix [room]: leaving %s failed — %s"
                         old (elneo-server--error-string ack))))))))))))
    (pcase
        (downcase
         (read-char (elneo-room--invite-prompt-string name old)))
      (?j (funcall accept elneo-room-upgrade-leave))
      (?l (funcall accept t))
      (?d
       (elneo-decline-invite
        profile room-id
        (lambda (_profile event)
          (if (alist-get '@ok event nil nil #'equal)
              (message "Matrix [room]: declined the invite to %s" name)
            (message "Matrix [room]: decline failed — %s"
                     (elneo-server--error-string event))))))
      (_ (message "Matrix [room]: invite to %s ignored" name)))))

(defun elneo-room--open (room &optional stay-put)
  "Open room record ROOM in the main window area.
With STAY-PUT non-nil (a universal prefix on the calling
command), display right where we are per
`elneo-room--display-room-buffer'."
  (let ((buffer (elneo-room--buffer room)))
    ;; Not the registry of buffers (elneo-room--buffer owns that);
    ;; the room record itself remembers its buffer, and the room-gone
    ;; handler carries it through the :removed announcement.
    (setf (plist-get room :buffer) buffer)
    (with-current-buffer buffer
      (if elneo-room--backfilled
          (elneo-room--ensure-input-area)
        (elneo-room--backfill 50))
      ;; The member roster for @-mention completion: one store-backed
      ;; read per open, refreshed by membership events afterwards.
      (elneo-room--fetch-members)
      ;; The permissions snapshot the edit gates and the `C-c ?' view
      ;; read; refreshed by the settings view on each opening.
      (elneo-room--fetch-permissions))
    (elneo-room--display-room-buffer buffer stay-put)
    (with-current-buffer buffer
      (goto-char (point-max)))))

(defun elneo-room--history-callback (buffer)
  "The callback for room-history pages fetched out of BUFFER.
A failed response on the wire is a bare `@req' ack (`@ok' false,
`@error') — it carries no room_id, so a failure cannot be routed
through `--on-history''s registry lookup; the closure that issued
the fetch delivers it to the requesting view
(`--history-failed').  Successful pages take the registry-routed
path.  Arity is the pending-callback wire contract, `(profile
event)': the profile arrives from the dispatcher and agrees with
the buffer's buffer-local one."
  (lambda (profile event)
    (if (alist-get '@ok event nil nil #'equal)
        (elneo-room--on-history profile event)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (elneo-room--history-failed event))))))

(defun elneo-room--backfill (limit)
  "Fetch the newest LIMIT messages for this room and insert them."
  (let ((buf (current-buffer)))
    (elneo-room-messages elneo-room--profile elneo-room--room-id limit nil
                         (elneo-room--history-callback buf))))

;;; View restore (event-id anchored)

(defun elneo-room--first-visible-event-id (window)
  "Event id of the first message at or after WINDOW's start, or nil."
  (when window
    (let ((limit (point-max)) pos)
      (catch 'found
        (setq pos (window-start window))
        (while (and pos (< pos limit))
          (let ((id (get-text-property pos 'elneo-room-event-id)))
            (if id
                (throw 'found id)
              (setq pos (next-single-property-change
                         pos 'elneo-room-event-id nil limit)))))
        nil))))

(defun elneo-room--end-start (window)
  "Window-start position that puts the buffer end on screen.
One line is kept in reserve: `point-max' sits on the draft line
after the separator, and a full `window-body-height' of lines would
scroll that last (writable) line out of the window again."
  (save-excursion
    (goto-char (point-max))
    (forward-line (- (1- (window-body-height window))))
    (max (point-min) (point))))

(defun elneo-room--window-at-end-p (window)
  "Non-nil when WINDOW shows the end of this buffer (the draft area)."
  (with-selected-window window
    (pos-visible-in-window-p (point-max))))

(defun elneo-room--show-end (&optional window keep-point)
  "Scroll WINDOW (default: this buffer's window) to the end.
Point goes to the end of the draft unless KEEP-POINT is non-nil
and the point already sits in the draft area.  The in-draft test
must run BEFORE any repositioning: for the selected window the
window's point is the buffer's point, so testing after a
`goto-char' would always pass and the cursor would jump to the
end on every live append."
  (let ((window (or window (get-buffer-window (current-buffer) t))))
    ;; Decide from the point's current position, then move.
    (unless (and keep-point (>= (point) (elneo-room--input-beg-pos)))
      (goto-char (point-max)))
    (when window
      ;; A non-selected window has its own point; keep that one too
      ;; when it is already in the draft area.
      (unless (and keep-point
                   (>= (window-point window) (elneo-room--input-beg-pos)))
        (set-window-point window (point-max)))
      (let ((start (elneo-room--end-start window)))
        (set-window-start window start)
        ;; Wrapped history lines make the logical-line count in
        ;; `elneo-room--end-start' underestimate the real (visual)
        ;; window height: walk the start forward until the buffer end
        ;; — the draft — is actually on screen.
        (save-excursion
          (while (and (< start (point-max))
                      (not (pos-visible-in-window-p (point-max) window)))
            (goto-char start)
            (forward-line 1)
            (if (<= (point) start)
                ;; Cannot advance (last line): bail out rather than spin.
                (setq start (point-max))
              (setq start (point))
              (set-window-start window start))))))))

(defun elneo-room--restore-anchor (event-id window)
  "Reposition WINDOW so the message EVENT-ID sits at the top.
Falls back to the end of the buffer when EVENT-ID is gone."
  (let ((pos (elneo-room--find-event event-id)))
    (if (and window pos)
        (progn
          (set-window-start window pos)
          (set-window-point window pos))
      (elneo-room--show-end window))))

;;; History responses

(defun elneo-room--history-failed (event)
  "A failed history response, delivered by the requesting view's
closure (`--history-callback').  A failed response on the wire is a
bare `@req' ack (`@ok' false, `@error') — no room_id — so the
registry lookup in `--on-history' could never find this buffer.
A freshly (re)started daemon may reject history until its first
sync has seeded the rooms; retry a few times while the buffer is
still unfilled, so opening a room right after
`elneo-server-start' still loads it.  An unfilled buffer shows the
failure as a notice instead of just staying empty."
  (elneo--debug-log "Matrix [%s] history: %s" elneo-room--profile
                    (elneo-server--error-string event))
  (setq elneo-room--loading-older nil)
  (if elneo-room--backfilled
      ;; The page in flight was an older page; live content is on
      ;; display, so only the echo area mentions the failure.
      (message "Matrix [%s] history page failed: %s" elneo-room--profile
               (elneo-server--error-string event))
    (elneo-room--set-notice
     (format "History failed: %s — C-c C-r refetches"
             (elneo-server--error-string event)))
    (when (< elneo-room--history-retries elneo-room-history-retries-max)
      (setq elneo-room--history-retries (1+ elneo-room--history-retries))
      ;; Spaced to outlast a daemon's start-up: doubling from 2s,
      ;; capped at 30s, and dropped on the floor once history has
      ;; landed (the guard in the closure).
      (let* ((buf (current-buffer))
             (delay (min 30 (* 2 elneo-room--history-retries)))
             (profile elneo-room--profile))
        (run-with-timer
         delay nil
         (lambda ()
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (when (and (not elneo-room--backfilled)
                          (< elneo-room--history-retries
                             elneo-room-history-retries-max)
                          (elneo-server-live-p profile))
                 (elneo-room--backfill 50))))))))))

(defun elneo-room--set-notice (text)
  "Show the failure notice TEXT in this room buffer.
A buffer not yet backfilled is blank — it renders header plus
notice on the spot; a filled one carries the notice to the next
render (and the next successful page clears it).  nil clears."
  (setq elneo-room--notice text)
  (unless elneo-room--backfilled
    (let ((inhibit-read-only t))
      (erase-buffer)
      (elneo-room--header (elneo-room-get elneo-room--profile elneo-room--room-id)))))

(defun elneo-room-refetch ()
  "Refetch the first page of history in this room.
The escape hatch for a fetch or render that failed: it clears the
notice and repeats the backfill from a fresh state.  The failure
notices (`--history-failed', the render error path) point here."
  (interactive)
  (when elneo-room--thread-root
    (user-error "A thread view refetches with its room buffer"))
  (unless (and elneo-room--profile (elneo-server-live-p elneo-room--profile))
    (user-error "Matrix server not running for profile: %s" elneo-room--profile))
  (setq elneo-room--notice nil
        elneo-room--backfilled nil
        elneo-room--end-token nil
        elneo-room--history-retries 0
        elneo-room--loading-older nil)
  (let ((inhibit-read-only t))
    (erase-buffer))
  (elneo-room--backfill 50))

(defun elneo-room--on-history (profile event)
  "Handle a successful updateRoomMessages page for PROFILE.
Failed fetches never arrive here: they are bare `@req' acks
without room_id, routed to the requesting view by
`--history-callback'."
  (let* ((room-id (alist-get 'room_id event))
         (buffer (elneo-room--buffer-for profile room-id)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (setq elneo-room--loading-older nil
                                        elneo-room--notice nil))
      (let* ((entries (mapcar #'elneo-room--message-from-entry
                              (alist-get 'messages event)))
             (end (alist-get 'end event))
             (first-page (not (buffer-local-value 'elneo-room--backfilled buffer)))
             ;; All frames: with a multi-display or eyebrowse setup the
             ;; room's window often lives on a frame that is not the
             ;; selected one when the response arrives.  A
             ;; selected-frame-only lookup returns nil there, and the
             ;; fresh render leaves the window's point at the top of
             ;; the buffer instead of the end (the entry cursor bug).
             (window (get-buffer-window buffer t)))
        (with-current-buffer buffer
          (if first-page
              (elneo-room--render-first-page entries end window)
            (progn
              (elneo-room--prepend-older-page entries end window)
              ;; A jump-in-progress re-checks after every older page.
              (when elneo-room--jump-target
                (elneo-room--jump-drive)))))))))

(defun elneo-room--render-first-page (entries end window)
  "Full re-render: header, ENTRIES, then the input area.
The reader's position is kept via event-id anchoring; the draft
survives the re-render (used by the room-keys backfill too).  A
cursor inside the draft is kept as well: spontaneous re-renders
\(room keys arriving — common right after a fresh session's key
imports) must not yank it out of mid-draft typing."
  (let* ((at-end (or (null window) (elneo-room--window-at-end-p window)))
         (anchor-id (unless at-end (elneo-room--first-visible-event-id window)))
         (live-draft (elneo-room--draft-text))
         (draft (if (> (length live-draft) 0)
                    live-draft
                  elneo-room--pending-draft))
         (draft-offset (and elneo-room--backfilled
                            (>= (point) (elneo-room--input-beg-pos))
                            (- (point) (elneo-room--input-beg-pos)))))
    (when elneo-room--keys-timer
      (cancel-timer elneo-room--keys-timer)
      (setq elneo-room--keys-timer nil))
    (setq elneo-room--media-pending (make-hash-table :test 'equal))
    ;; A render error mid-way (an entry shape the formatter mishandles)
    ;; must not leave the buffer half-erased: the previous content —
    ;; with the per-view state it was rendered from — is put back, the
    ;; error shows as a notice, and the next backfill redoes the render.
    (let ((prev (when elneo-room--backfilled (buffer-string)))
          (prev-backfilled elneo-room--backfilled)
          (prev-end-token elneo-room--end-token)
          (prev-last-event-id elneo-room--last-event-id)
          (prev-history-retries elneo-room--history-retries))
      (condition-case err
          (progn
            (let ((inhibit-read-only t))
              (erase-buffer))
            (setq elneo-room--seen (make-hash-table :test 'equal))
            (when (hash-table-p elneo-room--reactions)
              (clrhash elneo-room--reactions))
            (setq elneo-room--jump-target nil
                  elneo-room--jump-pages 0)
            (elneo-room--header (elneo-room-get elneo-room--profile elneo-room--room-id))
            (goto-char (point-max))
            (elneo-room--append-messages entries)
            (setq elneo-room--backfilled t
                  elneo-room--end-token end
                  elneo-room--history-retries 0
                  elneo-room--notice nil
                  elneo-room--last-event-id
                  (and entries (plist-get (car (last entries)) :event-id)))
            (setq elneo-room--pending-draft nil)
            (elneo-room--reset-input-area draft)
            (if (or at-end (null anchor-id))
                (elneo-room--show-end window)
              (elneo-room--restore-anchor anchor-id window)))
        (error
         (let ((inhibit-read-only t))
           (erase-buffer)
           (insert (or prev ""))
           (setq elneo-room--backfilled prev-backfilled
                 elneo-room--end-token prev-end-token
                 elneo-room--last-event-id prev-last-event-id
                 elneo-room--history-retries prev-history-retries
                 elneo-room--pending-draft nil)
           (elneo-room--set-notice
            (format "History render failed: %s — C-c C-r refetches" err))
           (elneo-room--reset-input-area draft))
         (message "Matrix [%s] history render failed: %s" elneo-room--profile err))))
    ;; Return the cursor to where it was inside the draft.  Only for
    ;; the selected window — there the window's point is the buffer's,
    ;; and only a typing cursor is worth preserving.  A pending jump
    ;; still wins; it runs after this.
    (when (and draft-offset (eq window (selected-window)))
      (goto-char (min (point-max)
                      (+ (elneo-room--input-beg-pos) draft-offset))))
    ;; An alert-initiated jump into a fresh buffer: the first page and
    ;; end-token exist now, so run the pending jump — it paginates
    ;; further back through `elneo-room--jump-drive' when the target
    ;; is older than this page.
    (when elneo-room--pending-jump-event-id
      (let ((id elneo-room--pending-jump-event-id))
        (setq elneo-room--pending-jump-event-id nil)
        (elneo-room--jump-to-reply id)))
    (elneo-room--maybe-mark-read)
    (elneo-room--fetch-media-in-window window)
    ;; Seed other members' read receipts for the read-marks display;
    ;; the async response re-applies the marks via
    ;; `elneo-room--on-receipts-seeded'.  The seed is cosmetic — a
    ;; daemon that just died mid-render must not abort it, and the
    ;; next backfill seeds again.
    (ignore-errors
      (elneo-room-receipts elneo-room--profile elneo-room--room-id
                           #'elneo-room--on-receipts-seeded))))

(defun elneo-room--prepend-older-page (entries end window)
  "Prepend an older history page at the top of the buffer.
How the view lands depends on `elneo-room--older-mode': `anchor'
keeps the first visible message stable (auto-load), `scroll'
moves the view up a screen into the fresh page (PageUp, M-<)."
  (let* ((page-mode (or elneo-room--older-mode 'anchor))
         (at-end (and window (elneo-room--window-at-end-p window)))
         (anchor-id (unless (or at-end (eq page-mode 'scroll))
                      (elneo-room--first-visible-event-id window)))
         ;; Landmark of the first visible line, for `scroll' mode.
         (scroll-marker
          (when (and window (eq page-mode 'scroll))
            (let ((marker (copy-marker (window-start window) nil)))
              (set-marker-insertion-type marker t)
              marker))))
    (let ((inhibit-read-only t))
      (save-excursion
        ;; The room's history begins at the very top; a thread view's
        ;; begins below the pinned root (`elneo-room--prepend-point',
        ;; a marker so re-renders and erases keep it honest).
        (goto-char (or (and (markerp elneo-room--prepend-point)
                            (marker-buffer elneo-room--prepend-point)
                            (marker-position elneo-room--prepend-point))
                       (point-min)))
        ;; Per-message separators: each prepended message compares its
        ;; day with the message above it — the previous prepended
        ;; message, or nothing for the very first (point-min).
        (dolist (msg entries)
          (elneo-room--append-messages (list msg)))
        ;; The seam below the prepended page: the last prepended
        ;; message is inserted ABOVE the old first line, so no
        ;; per-message check ever compares those two — a day flip
        ;; exactly at the seam (older page ends 23:59, rendered page
        ;; starts 00:05) rendered no separator at all.  The ts
        ;; ABOVE point is the last prepended message (its trailing
        ;; newline carries it); the ts BELOW is the first
        ;; already-rendered message's, skipping any separator or
        ;; reply quote-line gap in between.
        (when entries
          (let ((above (get-text-property (1- (point)) 'elneo-room-ts))
                (below (or (get-text-property (point) 'elneo-room-ts)
                           (get-text-property
                            (next-single-property-change
                             (point) 'elneo-room-ts nil (point-max))
                            'elneo-room-ts))))
            (when (and above below
                       (not (equal (elneo-room--day above)
                                   (elneo-room--day below))))
              (elneo-room--insert-day-separator below))))))
    (setq elneo-room--end-token end)
    (cond
     ;; PageUp / M-<: put the old top line near the bottom of the
     ;; window, so the fresh older page fills the screen above it.
     (scroll-marker
      (let ((target (save-excursion
                      (goto-char (marker-position scroll-marker))
                      (forward-line (- (window-body-height window)))
                      (max (point-min) (point)))))
        (set-window-start window target)
        (set-window-point window target)))
     (at-end (elneo-room--show-end window))
     (anchor-id (elneo-room--restore-anchor anchor-id window)))
    (when scroll-marker
      (set-marker scroll-marker nil))
    ;; The older page may contain own messages already covered by a
    ;; known receipt: re-run the read-marks pass over the grown history.
    (elneo-room--apply-read-marks)
    (elneo-room--fetch-media-in-window window)))

(defun elneo-room--message-from-entry (entry)
  "Convert a daemon MessageEntry alist to a message plist."
  (list :event-id (alist-get 'event_id entry)
        :sender (alist-get 'sender entry)
        :sender-name (alist-get 'sender_name entry)
        :sender-avatar (alist-get 'sender_avatar entry)
        :body (alist-get 'body entry)
        :formatted-body (alist-get 'formatted_body entry)
        :ts (alist-get 'ts entry)
        :msgtype (or (alist-get 'msgtype entry) "m.text")
        :media (alist-get 'media entry)
        :is-own (eq (alist-get 'is_own entry) t)
        :reply-to (alist-get 'reply_to entry)
        :thread-root (alist-get 'thread_root entry)
        :sender-trust (alist-get 'sender_trust entry)
        :edited (and (alist-get 'edited entry) t)
        :edited-ts (alist-get 'edited entry)
        :redacted (eq (alist-get 'redacted entry) t)
        :reactions (elneo-client--reaction-plists (alist-get 'reactions entry))
        :geo (alist-get 'geo entry)
        :poll (elneo-client--poll-plist (alist-get 'poll entry))
        :mentions (elneo-client--mentions-plist (alist-get 'mentions entry))))

;;; Live updates

(defconst elneo-room--echo-fill-keys '(:sender-avatar :sender-trust)
  "Message fields a late daemon echo may fill in.
The optimistic echo of a send renders without them — the local
side cannot know the sender's avatar mxc or the decryption-time
trust snapshot — and the ack's re-key keeps it that way.  When the
daemon's real echo then finds the event already rendered, these
are the fields it fills; anything the local echo already knows
(:ts, body, sender name) is never overwritten.")

(defun elneo-room--fill-echo-fields (event-id stored echo)
  "Fill STORED's unknown avatar/trust fields from the daemon ECHO.
STORED is the seen-table entry EVENT-ID already renders — a
re-keyed provisional block.  plist-put cannot be relied on to
mutate when a key is absent, so a filled copy goes back into the
seen table.  Returns t when anything changed (the caller
re-renders; the avatar cell then also kicks the deduped fetch)."
  (let ((updated stored) (changed nil))
    (dolist (key elneo-room--echo-fill-keys)
      (let ((echo (plist-get echo key)))
        (when (and echo (not (plist-get stored key)))
          (setq updated (plist-put updated key echo)
                changed t))))
    (when (and changed (not (eq updated stored)))
      (puthash event-id updated elneo-room--seen))
    changed))

(defun elneo-room--apply-new-message (buffer msg)
  "Append the daemon echo MSG to the history of BUFFER.
A message already rendered — the send ack re-keyed the provisional
block before this daemon echo arrived — does not append again: the
echo then only fills in what the local echo could not know (see
`elneo-room--fill-echo-fields') and re-renders the block.  Shared
with the thread consumers: a thread buffer's own new-message
handler narrows to its root first, then lands here."
  (when (and (buffer-live-p buffer)
             (buffer-local-value 'elneo-room--backfilled buffer))
    (let* ((event-id (plist-get msg :event-id))
           ;; All frames: the buffer may be displayed on another frame
           ;; (bar-following jumps); it should still scroll to the
           ;; end on live appends when it shows the end.
           (window (get-buffer-window buffer t))
           (was-at-end (and window (elneo-room--window-at-end-p window))))
      (if (gethash event-id (buffer-local-value 'elneo-room--seen buffer))
          ;; A rendered message whose echo carries more than the
          ;; provisional block knew (own sends, mostly): fill in and
          ;; re-render in place.  No scroll or read marking — the
          ;; block was already the newest thing on screen.
          (with-current-buffer buffer
            (when (elneo-room--fill-echo-fields
                   event-id (gethash event-id elneo-room--seen) msg)
              (elneo-room--replace-message
               event-id (gethash event-id elneo-room--seen))))
        (with-current-buffer buffer
          (setq elneo-room--last-event-id event-id)
          (when (and (markerp elneo-room--append-point)
                     (marker-buffer elneo-room--append-point))
            (save-excursion
              (goto-char elneo-room--append-point)
              (elneo-room--append-messages (list msg))))
          (when was-at-end
            (elneo-room--show-end window 'keep-point)
            (elneo-room--maybe-mark-read window)
            (elneo-room--fetch-media-in-window window)))))))

(defun elneo-room--on-new-message (msg)
  "New-message hook: append MSG to this room's buffer if open.
Thread replies render inline where they sit (this handler does not
filter on :thread-root); a thread view has its own consumer."
  (let* ((profile (plist-get msg :profile))
         (room-id (plist-get msg :room-id))
         (buffer (elneo-room--buffer-for profile room-id)))
    (when (and (buffer-live-p buffer)
               (buffer-local-value 'elneo-room--backfilled buffer))
      (elneo-room--apply-new-message buffer msg)
      ;; Membership changes re-shape @-mention completion; a fresh
      ;; roster read is the whole refresh (store-backed, cheap).
      (when (equal (plist-get msg :msgtype) "m.member")
        (with-current-buffer buffer
          (elneo-room--fetch-members))))))

(declare-function elneo-thread--load-older "elneo-thread")
(declare-function elneo-thread-open "elneo-thread" (profile room-id root-id &optional root-msg))
(declare-function elneo-thread--buffers-for "elneo-thread" (profile room-id))
(declare-function elneo-thread--fetch-first-page "elneo-thread" ())

;;; Live reaction updates

(defun elneo-room--replace-reaction-line (pos event-id entries)
  "At POS (the message line), swap the reaction line in place.
Deletes the reaction line directly following the message line, if
any, then reinserts the full refreshed list — nil ENTRIES leave no
line behind (the daemon sends the complete list; empty means the
line goes away)."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char pos)
      (let ((msg-end (line-end-position))
            (ts (get-text-property (point) 'elneo-room-ts)))
        (when (get-text-property (min (point-max) (1+ msg-end))
                                 'elneo-room-reaction-line)
          (goto-char (1+ msg-end))
          (delete-region (point)
                         (min (point-max) (1+ (line-end-position)))))
        (when entries
          (goto-char (1+ msg-end))
          (elneo-room--insert-reaction-line event-id ts entries))))))

(defun elneo-room--on-reactions-update (upd)
  "Reactions-update hook: rewrite the target's reaction line in place.
The daemon always sends the full refreshed list; an empty list
means the line goes away."
  (let* ((profile (plist-get upd :profile))
         (room-id (plist-get upd :room-id))
         (event-id (plist-get upd :event-id))
         (entries (plist-get upd :reactions))
         (buffer (elneo-room--buffer-for profile room-id)))
    (when (and (buffer-live-p buffer)
               (buffer-local-value 'elneo-room--backfilled buffer)
               (hash-table-p (buffer-local-value 'elneo-room--reactions buffer)))
      (with-current-buffer buffer
        (puthash event-id entries elneo-room--reactions)
        (when-let* ((pos (elneo-room--find-event event-id)))
          (elneo-room--replace-reaction-line pos event-id entries))))
    ;; Pass-over: the reaction's own id advances the read marker
    ;; when a window follows the live end, whether or not this
    ;; session renders the target at all.
    (elneo-room--advance-read-marker
     profile room-id (plist-get upd :source-event-id))))

(defun elneo-room--on-pinned-update (room)
  "Room-update hook: refresh a room's [pinned] marks when the list changed.
The record's `:pinned' is the single source of truth (the state
echo re-announces it); an equal list does nothing, so summary
bursts re-announce whole rooms without twitching re-renders.  Only
rendered blocks are re-laid — a pin naming a message no older page
showed yet picks its mark up whenever that page loads, because the
rider consults the live buffer-local."
  ;; A room gone (`:removed t') has nothing to re-mark.
  (unless (plist-get room :removed)
    (let* ((profile (plist-get room :profile))
           (room-id (plist-get room :room-id))
           (buffer (elneo-room--buffer-for profile room-id))
           (pinned (plist-get room :pinned)))
      (when (and (buffer-live-p buffer) (listp pinned))
        (with-current-buffer buffer
          (unless (equal pinned elneo-room--pinned)
            ;; Symmetric difference: the ids whose [pinned] mark
            ;; membership changes.
            (let* ((old elneo-room--pinned)
                   (changed (append (cl-set-difference old pinned :test #'equal)
                                    (cl-set-difference pinned old :test #'equal))))
              (setq-local elneo-room--pinned pinned)
              (dolist (id changed)
                (when-let* ((msg (gethash id elneo-room--seen)))
                  (elneo-room--replace-message id msg))))))))))

;;; Live poll updates

(defun elneo-room--on-poll-update (upd)
  "Poll-update hook: re-render the poll block of the start event.
The poll plists ride the seen-table entry (`:poll'), so
`elneo-room--replace-message' re-renders the whole block — body
line, options, reaction line — with the refreshed aggregate.  A nil
:poll arrives for polls this session holds no fold for: those are
not rendered here, so nothing to do."
  (let* ((profile (plist-get upd :profile))
         (room-id (plist-get upd :room-id))
         (event-id (plist-get upd :event-id))
         (poll (plist-get upd :poll))
         (buffer (elneo-room--buffer-for profile room-id)))
    (when (and (buffer-live-p buffer)
               poll
               (hash-table-p (buffer-local-value 'elneo-room--seen buffer)))
      (with-current-buffer buffer
        (let ((msg (gethash event-id elneo-room--seen)))
          (when msg
            (elneo-room--replace-message
             event-id (plist-put msg :poll poll))))))
    ;; Pass-over: a vote or the poll end advances the read marker
    ;; even for polls this session has no fold for.
    (elneo-room--advance-read-marker
     profile room-id (plist-get upd :source-event-id))))

;;; Incoming read receipts

(defcustom elneo-room-read-marks 'check
  "How other members' read receipts mark your own messages.
Matrix receipts are per-user and name the event each member has read
up to; for your own messages the room buffer can render that:
`check' (default, least invasive) puts ✓✓ on the newest of your
messages someone has read; `dim' dims every own message someone has
read; `both' does both; `none' shows nothing.  Which member read it
is in the settings view (`m'), regardless of this setting.

Only members whose clients send public m.read receipts are visible:
Element Web/Desktop does, Element X sends private receipts only and
never appears."
  :group 'elneo-room
  :type '(choice (const :tag "✓✓ on newest read own message" check)
                 (const :tag "Dim read own messages" dim)
                 (const :tag "Both check and dim" both)
                 (const :tag "None" none)))

(defun elneo-room--on-read-receipts (upd)
  "Read-receipts-update hook: refresh the buffer's receipt state.
The daemon always sends the full refreshed list of other members'
public m.read receipts; live ones arrive while the buffer is open,
the initial seed through `elneo-room--on-receipts-seeded'."
  (let* ((profile (plist-get upd :profile))
         (room-id (plist-get upd :room-id))
         (buffer (elneo-room--buffer-for profile room-id)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (hash-table-p elneo-room--receipts)
          (clrhash elneo-room--receipts)
          (dolist (r (plist-get upd :receipts))
            (puthash (plist-get r :user-id) r elneo-room--receipts)))
        (elneo-room--apply-read-marks)))))

(defun elneo-room--on-receipts-seeded (profile event)
  "getRoomReceipts response: seed the room buffer's receipt state.
The response carries the same shape as an `updateReadReceipts'
event; routing it through the client handler keeps a single owner
of the wire->plist conversion."
  (when (alist-get '@ok event nil nil #'equal)
    (elneo-client--on-update-read-receipts profile event)))

(defun elneo-room--apply-read-marks ()
  "Recompute the own-messages-read display from the current receipts.
An own message is covered when a receipt's target sits at or after
it in the room timeline: the daemon resolves each target's
origin-server timestamp (`:target-ts', its true timeline position,
independent of when the user read), and every own message that old
or older has been read.  A target the daemon has not seen resolves
to nothing and covers nothing, so a mark never lies — at worst a
message waits for the next receipt.  Receipts move forward only, so
this is an idempotent pass: changed messages alone re-render, and
the ✓✓ of `check'/`both' style advances to the newest covered
message."
  (when (and elneo-room--backfilled
             (not elneo-room--thread-root)
             (hash-table-p elneo-room--receipts))
    (let ((max-read-ts 0)
          (changed nil))
      ;; Newest timeline position any receipt names; 0 means no
      ;; receipt resolved, covering nothing.
      (maphash (lambda (_user r)
                 (setq max-read-ts (max max-read-ts
                                        (or (plist-get r :target-ts) 0))))
               elneo-room--receipts)
      (let ((new-check nil))
        (dolist (id (elneo-room--ordered-event-ids))
          (let* ((msg (gethash id elneo-room--seen))
                 (covered (and msg
                               (> max-read-ts 0)
                               (plist-get msg :is-own)
                               (not (plist-get msg :redacted))
                               (<= (or (plist-get msg :ts) 0) max-read-ts))))
            (when covered (setq new-check id))
            ;; `dim'/`both': every newly covered own message dims;
            ;; a style change away from `dim' un-dims via the same diff.
            (when msg
              (let ((want (and covered
                               (memq elneo-room-read-marks '(dim both))))
                    (have (plist-get msg :read-by)))
                (cond ((and want (not have))
                       (puthash id (plist-put msg :read-by t)
                                elneo-room--seen)
                       (push id changed))
                      ((and have (not want))
                       (cl-remf msg :read-by)
                       (puthash id msg elneo-room--seen)
                       (push id changed)))))))
        ;; `check'/`both': ✓✓ sits on the newest covered own message
        ;; and moves forward as receipts advance.
        (let ((want (and (memq elneo-room-read-marks '(check both))
                         new-check)))
          (unless (equal want elneo-room--read-check-id)
            (when elneo-room--read-check-id
              (let ((old (gethash elneo-room--read-check-id
                                  elneo-room--seen)))
                (when old
                  (cl-remf old :read-check)
                  (puthash elneo-room--read-check-id old
                           elneo-room--seen)
                  (push elneo-room--read-check-id changed))))
            (when want
              (let ((msg (gethash want elneo-room--seen)))
                (plist-put msg :read-check t)
                (puthash want msg elneo-room--seen)
                (push want changed)))
            (setq elneo-room--read-check-id want))))
      (dolist (id (delete-dups changed))
        (elneo-room--replace-message id
                                     (gethash id elneo-room--seen))))))

;;; In-place re-render for edits and redactions

(defun elneo-room--block-bounds (event-id)
  "Cons (BEG . END) of EVENT-ID's rendered block, or nil.
The block is the message's last line (the indented body line for a
reply or picture), the name line above it when there is one, and
the reaction line below it when there is one — exactly the region
`elneo-room--replace-message' re-renders and the send lifecycle
deletes (`elneo-room--remove-message').  nil when the event is
not rendered here."
  (let ((pos (elneo-room--find-event event-id)))
    (when pos
      (save-excursion
        (goto-char pos)
        (let* ((line-beg (line-beginning-position))
               (msg-end (line-end-position))
               ;; A reply's or picture's block starts one line up:
               ;; the reply's line above always ends inside the quote
               ;; span, the picture's carries `elneo-room-name-line',
               ;; and nothing else in the buffer has either.  A rich
               ;; body may span many lines — they all carry
               ;; `elneo-room-rich-block' with the event id — so
               ;; walk up over those first.  For a single-line
               ;; message the (- 2) probe falls on ordinary text (or
               ;; the header), never a match.
               (block-beg (save-excursion
                            (goto-char line-beg)
                            (while (and (> (point) (point-min))
                                        (or (equal (get-text-property
                                                    (- (point) 2)
                                                    'elneo-room-rich-block)
                                                   event-id)
                                            (equal (get-text-property
                                                    (- (point) 2)
                                                    'elneo-room-msg-block)
                                                   event-id)))
                              (goto-char (line-beginning-position 0)))
                            (if (or (get-text-property
                                     (max (point-min) (- (point) 2))
                                     'elneo-room-quote)
                                    (get-text-property
                                     (max (point-min) (- (point) 2))
                                     'elneo-room-name-line))
                                (save-excursion
                                  (goto-char (1- (point)))
                                  (line-beginning-position))
                              (point))))
               (block-end (save-excursion
                            (goto-char (min (point-max) (1+ msg-end)))
                            ;; The poll block's option lines (a poll's
                            ;; extra lines, the reaction line possibly
                            ;; after them) extend the block downward.
                            ;; After the walk point sits on the first
                            ;; char of the next content — the block
                            ;; ends exactly there (the last extra
                            ;; line's newline is one back, and already
                            ;; deleted).
                            (while (and (< (point) (point-max))
                                        (or (get-text-property (point)
                                                               'elneo-room-poll-line)
                                            (get-text-property (point)
                                                               'elneo-room-reaction-line)))
                              (goto-char (min (point-max) (1+ (line-end-position)))))
                            (point))))
          (cons block-beg block-end))))))

(defun elneo-room--replace-message (event-id msg &optional new-id)
  "Re-render the message block of EVENT-ID with the content MSG in place.
The block is the message's last line (the indented body line for a
reply or picture), the name line above it when there is one, and
the reaction line below it when there is one.  MSG becomes the
seen-table entry; properties are re-laid exactly where
`elneo-room--append-messages' lays them, so the read-marker walker
and day-separator logic keep working unchanged.

With NEW-ID the block, the seen entry and MSG's `:event-id'
re-key to it — the send lifecycle swaps a provisional id for the
server's event id (`elneo-room--on-send-ack') and a retried send
re-keys to a fresh provisional id.  An event not rendered here
(older page not loaded, other buffer) is a no-op."
  (let ((bounds (elneo-room--block-bounds event-id)))
    (when bounds
      (let* ((id (or new-id event-id))
             (inhibit-read-only t))
        (save-excursion
          (goto-char (car bounds))
          (let* ((block-beg (car bounds))
                 (block-end (cdr bounds))
                 (ts (or (plist-get msg :ts)
                         (get-text-property
                          (elneo-room--find-event event-id)
                          'elneo-room-ts))))
            ;; A stale in-flight fetch would block a re-rendered media
            ;; placeholder; the quote's and rich body images' synthetic
            ;; ids likewise.  Any pending key prefixed with the OLD
            ;; event id belongs to this block.
            (when (hash-table-p elneo-room--media-pending)
              (maphash (lambda (key _v)
                         (when (and (stringp key)
                                    (string-prefix-p event-id key))
                           (remhash key elneo-room--media-pending)))
                       elneo-room--media-pending))
            (delete-region block-beg block-end)
            (setq msg (plist-put msg :event-id id))
            (puthash id msg elneo-room--seen)
            (unless (equal id event-id)
              ;; A re-key must not leave the old entry behind: reply,
              ;; edit and jump lookups would find a stale block.
              (remhash event-id elneo-room--seen))
            ;; Anon mode fakes a render copy; the puthash above keeps
            ;; the real content (toggle-off re-renders from it).
            (when elneo-anon-mode
              (setq msg (elneo-anon--message msg elneo-room--room-id
                                             elneo-room--members)))
            (goto-char block-beg)
            (elneo-room--insert-message msg)
            ;; Props in the same order and places as
            ;; `elneo-room--append-messages' — the layout comment
            ;; there is authoritative; the shared block hoist keeps
            ;; the two sites in lock-step.
            (elneo-room--stamp-message-block
             id ts msg
             (and (hash-table-p elneo-room--reactions)
                  (gethash id elneo-room--reactions))
             block-beg)
            ;; A re-rendered media message re-inserted its placeholder;
            ;; a displayed buffer fetches the thumbnail now instead of
            ;; waiting for the next scroll pass.
            (when (get-buffer-window (current-buffer) t)
              (elneo-room--fetch-media-in-window))))))))

;;; Live redactions

(defun elneo-room--log-redaction (msg event-id)
  "Append MSG's original content to the on-disk redaction log.
One JSON object per line under the profile's data directory, so
`elneo-room-reveal-redaction' can still find it after a restart.
Written only while `elneo-room-redaction-history' is on."
  (let ((dir (elneo--daemon-data-dir elneo-room--profile)))
    (make-directory dir 'parents)
    (let ((record `((room_id . ,elneo-room--room-id)
                    (event_id . ,event-id)
                    (sender . ,(plist-get msg :sender))
                    (ts . ,(plist-get msg :ts))
                    (msgtype . ,(plist-get msg :msgtype))
                    (body . ,(plist-get msg :body))
                    (redacted_at . ,(floor (float-time))))))
      (with-temp-buffer
        (insert (json-encode record) "\n")
        (write-region (point-min) (point-max)
                      (file-name-concat dir "redactions.jsonl")
                      'append 'silent)))))

(defun elneo-room--redacted-body-from-log (event-id)
  "The logged original body for EVENT-ID, or nil.
Scans redactions.jsonl in the profile's data directory — this is the
only source that survives a restart."
  (let ((file (file-name-concat (elneo--daemon-data-dir elneo-room--profile)
                                "redactions.jsonl"))
        (body nil))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (catch 'found
          (while (not (eobp))
            (let ((record (ignore-errors
                            (json-read-from-string
                             (buffer-substring (line-beginning-position)
                                               (line-end-position))))))
              (when (and record (equal (alist-get 'event_id record) event-id))
                (setq body (alist-get 'body record))
                (throw 'found nil)))
            (forward-line 1)))))
    body))

(defun elneo-room--on-redaction (upd)
  "Redaction-update hook: replace the message with a [redacted] marker.
With `elneo-room-redaction-history' on, the original body rides
along hidden (and goes to the on-disk log) so it can be revealed;
otherwise the locally held content is dropped, honouring the delete."
  (let* ((profile (plist-get upd :profile))
         (room-id (plist-get upd :room-id))
         (event-id (plist-get upd :event-id))
         (buffer (elneo-room--buffer-for profile room-id)))
    (when (and (buffer-live-p buffer)
               (buffer-local-value 'elneo-room--backfilled buffer))
      (with-current-buffer buffer
        (let ((msg (gethash event-id elneo-room--seen)))
          (when msg
            (let ((redacted (list :event-id event-id
                                  :sender (plist-get msg :sender)
                                  :sender-name (plist-get msg :sender-name)
                                  :ts (plist-get msg :ts)
                                  :msgtype "m.text"
                                  :is-own (plist-get msg :is-own)
                                  :reply-to (plist-get msg :reply-to)
                                  :redacted t
                                  :edited (plist-get msg :edited)
                                  :edited-ts (plist-get msg :edited-ts))))
              (when elneo-room-redaction-history
                ;; Hidden until revealed: the marker renders from the
                ;; :redacted flag alone, :redacted-body is only ever
                ;; set by `elneo-room-reveal-redaction'.
                (plist-put redacted :redacted-original (plist-get msg :body))
                ;; Best-effort: a disk error must not abort the handler
                ;; before the replacement is rendered — the deleted
                ;; message would keep rendering in full.
                (ignore-errors (elneo-room--log-redaction msg event-id)))
              (elneo-room--replace-message event-id redacted)
              ;; The redacted message may carry the ✓✓: it is no
              ;; longer eligible, so re-run the read-marks pass to move
              ;; the check to the next-newest covered own message.
              (elneo-room--apply-read-marks))))))))

(defun elneo-room-reveal-redaction ()
  "Show the original text of the redacted message at point.
Works for any redacted message (yours or others'): the original is
taken from this buffer's seen table, or — after a restart — from the
on-disk redaction log, which only exists while
`elneo-room-redaction-history' is on.  Revealing is strictly local;
nothing is re-sent to the server."
  (interactive)
  (let* ((id (elneo-room--event-id-at (point)))
         (msg (and id (gethash id elneo-room--seen))))
    (cond
     ((null msg) (user-error "No message at point"))
     ((not (plist-get msg :redacted)) (user-error "This message is not redacted"))
     (t
      (plist-put msg :redacted-body
                 (or (plist-get msg :redacted-body)
                     (plist-get msg :redacted-original)
                     (elneo-room--redacted-body-from-log id)))
      (elneo-room--replace-message id msg)
      (if (plist-get msg :redacted-body)
          (message "Revealed — display only; the server keeps the redaction")
        (message "No original kept: elneo-room-redaction-history was off"))))))

;;; Live edits

(defun elneo-room--on-edited (upd)
  "Edited-update hook: keep the old version, re-render the new one."
  (let* ((profile (plist-get upd :profile))
         (room-id (plist-get upd :room-id))
         (event-id (plist-get upd :event-id))
         (buffer (elneo-room--buffer-for profile room-id)))
    (when (and (buffer-live-p buffer)
               (buffer-local-value 'elneo-room--backfilled buffer))
      (with-current-buffer buffer
        (let ((msg (gethash event-id elneo-room--seen)))
          (when msg
            ;; Remember the outgoing version; a message never edited
            ;; before stores its original here.  New versions push to
            ;; the front; `elneo-room-show-edit-history' reverses.
            (when (hash-table-p elneo-room--edit-history)
              (puthash event-id
                       (cons (cons (or (plist-get msg :edited-ts)
                                       (plist-get msg :ts))
                                   (plist-get msg :body))
                             (gethash event-id elneo-room--edit-history))
                       elneo-room--edit-history))
            (plist-put msg :body (plist-get upd :body))
            (plist-put msg :formatted-body (plist-get upd :formatted-body))
            (plist-put msg :msgtype (plist-get upd :msgtype))
            (plist-put msg :media (plist-get upd :media))
            (plist-put msg :geo (plist-get upd :geo))
            (plist-put msg :edited t)
            (plist-put msg :edited-ts (plist-get upd :edited-ts))
            (elneo-room--replace-message event-id msg))))
      ;; Pass-over: the edit's own event id advances the read marker.
      (elneo-room--advance-read-marker
       profile room-id (plist-get upd :source-event-id)))))

(elneo-room--defkey elneo-room-show-edit-history ?=
  "Pop up the known versions of the message at point, oldest first.
Only versions that arrived as live edits in this buffer are
remembered (plus the currently rendered one)."
  (let* ((id (elneo-room--event-id-at (point)))
         (msg (and id (gethash id elneo-room--seen))))
    (cond
     ((null msg) (user-error "No message at point"))
     ((and (not (plist-get msg :edited))
           (not (and (hash-table-p elneo-room--edit-history)
                     (gethash id elneo-room--edit-history))))
      (message "This message was not edited"))
     (t
      (let ((versions (reverse
                       (append (gethash id elneo-room--edit-history) nil)))
            (new-ts (or (plist-get msg :edited-ts) (plist-get msg :ts)))
            (new-body (plist-get msg :body)))
        (with-current-buffer (get-buffer-create "*Matrix edit history*")
          (let ((inhibit-read-only t))
            (erase-buffer)
            (dolist (v versions)
              (insert (propertize (elneo-room--format-ts (car v))
                                  'face 'elneo-room-time))
              (insert " " (cdr v) "\n"))
            (insert (propertize (elneo-room--format-ts new-ts)
                                'face 'elneo-room-time))
            (insert " " new-body "\n")
            (goto-char (point-min)))
          (display-buffer (current-buffer))))))))

;;; Room settings

(defvar-local elneo-room-settings--room nil
  "The (PROFILE . ROOM-ID) this settings view belongs to.
Set as the view renders; the live refresh (an
`elneo-room-update-hook' consumer) finds open settings views this
way.  The record makes a plain `updateRoom' re-render the view in
place — a snapshot otherwise, stale until closed — and a removed
room closes its view.")

(defvar elneo-room--spaces (make-hash-table :test 'equal)
  "Room id -> parent space rows (the roomSpaces response).
The overview's Spaces line: fetched on demand when a room's
overview opens — the declarations live in the room's own
`m.space.parent' state, so joined rooms only — and kept for the
session.  Shared across profiles by room id, like the avatars by
mxc.")

(defvar elneo-room--spaces-pending (make-hash-table :test 'equal)
  "Room id -> t while its roomSpaces fetch is in flight.")

(defun elneo-room--fetch-spaces ()
  "Fetch this room's parent spaces into the shared cache.
For the overview's Spaces line.  Fire-and-forget like
`elneo-room--fetch-permissions': a failed fetch leaves nothing
cached (the next opening retries) and the line absent; the
daemon's protocol number guards it, an older one never answering
and so never having the line at all."
  (when (and (elneo-server--daemon-protocol elneo-room--profile)
             (>= (elneo-server--daemon-protocol elneo-room--profile) 18)
             (not (gethash elneo-room--room-id elneo-room--spaces))
             (not (gethash elneo-room--room-id elneo-room--spaces-pending)))
    (puthash elneo-room--room-id t elneo-room--spaces-pending)
    (let ((buf (current-buffer)))
      (elneo-room-spaces
       elneo-room--profile elneo-room--room-id
       (lambda (profile event)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (remhash elneo-room--room-id elneo-room--spaces-pending)
             (if (not (alist-get '@ok event nil nil #'equal))
                 (elneo--debug-log "Matrix [%s] spaces: %s" profile
                                   (elneo-server--error-string event))
               (puthash elneo-room--room-id
                        ;; The wire's JSON arrays arrive as vectors;
                        ;; the overview's render loops want a list.
                        (append (alist-get 'spaces event nil nil #'equal)
                                nil)
                        elneo-room--spaces)
               ;; The open overviews of THIS room re-render; the
               ;; cache hit renders the line, no button — no pop
               ;; of any window (the record the hook passes has
               ;; not changed).
               (elneo-room--settings-refresh
                (elneo-room-get elneo-room--profile elneo-room--room-id))))))))))

(defun elneo-room--settings-refresh (room)
  "Re-render the open settings views of the room the hook's ROOM touches.
A removed room closes its view instead.  Runs on
`elneo-room-update-hook'; cheap for sessions without an open
settings view (a buffer-list scan that matches no buffer-local
record)."
  (let ((key (cons (plist-get room :profile) (plist-get room :room-id))))
    (dolist (buf (buffer-list))
      (when (equal (buffer-local-value 'elneo-room-settings--room buf) key)
        (if (plist-get room :removed)
            (when (buffer-live-p buf) (kill-buffer buf))
          (with-current-buffer buf
            (let ((live-name (format "*Matrix Room: %s*"
                                     (or (plist-get room :display-name)
                                         (plist-get room :room-id)))))
              (unless (equal (buffer-name buf) live-name)
                (rename-buffer live-name t)))
            (let ((inhibit-read-only t)
                  (standard-output buf))
              (erase-buffer)
              (elneo-room-settings--render room)
              (goto-char (point-min)))))))))

;;;###autoload
(defun elneo-room-settings (room)
  "Show ROOM's settings and notification status, with action buttons.
Everything renders from the room record the daemon maintains — no
extra round-trip.  The Name and Topic facts carry their edit
buttons ([rename], [topic]); the actions row at the bottom keeps
the actions with no fact to anchor on: invite/kick/ban, leave
(joined rooms), decline (invited) and forget (left), via the
commands of the \"Room management\" section.
The view stays live: each room `updateRoom' re-renders it in place
(a rename re-titles the buffer too), a removed room closes it."
  (interactive
   (list (if (derived-mode-p 'elneo-room-mode)
             (elneo-room-get elneo-room--profile elneo-room--room-id)
           (user-error "Not in a Matrix room buffer"))))
  (unless room (user-error "No room record for this buffer"))
  (add-hook 'elneo-room-update-hook #'elneo-room--settings-refresh)
  ;; A fresh permissions snapshot rides each opening: the view
  ;; re-renders when the fetch lands (a Permissions line at "(the
  ;; permissions snapshot has not landed yet)" resolves itself).
  (let ((buf (elneo-room--buffer-for (plist-get room :profile)
                                     (plist-get room :room-id))))
    (when (and (buffer-live-p buf)
               (equal (plist-get room :room-state) "joined"))
      (with-current-buffer buf
        (elneo-room--fetch-permissions)
        (elneo-room--fetch-spaces))))
  (with-help-window
      (format "*Matrix Room: %s*"
              (or (plist-get room :display-name) (plist-get room :room-id)))
    (elneo-room-settings--render room)))

;; The section renderers: each lays one concern into the help buffer
;; (the main render resolves the room buffer once and calls them in
;; order).  They princ like the render itself — run inside its
;; with-help-window context.

(defun elneo-room--settings-facts (room buf joined)
  "The facts block: profile, nick, room identity, name and topic.
The nick and the Name/Topic edits key on BUF — the commands run
with it current — and the edit buttons on JOINED."
  (princ (format "  Profile:       %s\n" (plist-get room :profile)))
  ;; The nick: the account's display name as THIS room sees it (the
  ;; m.room.member displayname, which may differ from the profile).
  ;; Only resolvable with the live buffer's roster cache; the
  ;; button, joined-only, like the room edits above it.
  (when (buffer-live-p buf)
    (let ((own (cl-find (elneo-server--user-id (plist-get room :profile))
                        (buffer-local-value 'elneo-room--members buf)
                        :key (lambda (member) (plist-get member :user-id))
                        :test #'equal)))
      (princ (format "  Nick:          %s"
                     (or (plist-get own :name) "(the profile name)")))
      (when joined
        (elneo-room--settings-button "[nick]" "Set the nick this room sees for you"
                                     (elneo-room--settings-in-room
                                      buf #'elneo-room-set-nick)))
      (princ "\n")))
  (princ (format "  Room id:       %s\n" (plist-get room :room-id)))
  (when (plist-get room :alias)
    (princ (format "  Alias:         %s\n" (plist-get room :alias))))
  ;; The name and the topic anchor their own edit buttons right
  ;; here — the actions row below keeps only the actions with no
  ;; text in this overview to sit next to.  The Name line shows the
  ;; current nick even when the room carries none of its own (the
  ;; display name came from elsewhere; e.g. an alias), so the fact
  ;; and the button are always one line together.
  (princ (format "  Name:          %s"
                 (or (plist-get room :name)
                     (plist-get room :display-name)
                     (plist-get room :room-id) "?")))
  (when joined
    (when (elneo-room--gate buf :can-name)
      (elneo-room--settings-button "[rename]" "Set the room's name"
                                   (elneo-room--settings-in-room
                                    buf #'elneo-room-set-name))))
  (princ "\n")
  (let ((topic (and (plist-get room :topic)
                    (split-string (plist-get room :topic) "\n"))))
    (princ "  Topic:         ")
    (princ (or (car topic) ""))
    (when joined
      (when (elneo-room--gate buf :can-topic)
        (elneo-room--settings-button "[topic]" "Set the room's topic"
                                     (elneo-room--settings-in-room
                                      buf #'elneo-room-set-topic))))
    (princ "\n")
    (dolist (line (cdr topic))
      (princ (format "    %s\n" line)))))

(defun elneo-room--settings-avatar (room buf joined)
  "The avatar fact with its show/set/clear buttons.
The image itself once downloaded (the mxc string says nothing to
a human), the mxc until then and after a failed download — and
beside the image too: it identifies the avatar beyond one Emacs."
  (princ "  Avatar:        ")
  (let* ((profile (plist-get room :profile))
         (mxc (plist-get room :avatar))
         (img (and mxc
                   (not elneo-anon-mode)
                   (elneo-room--avatar-image-cell
                    (elneo-client--avatar-file mxc))))
         ;; The view, not princ: princ drops text properties (the
         ;; printer inserts without inheriting), so the image's
         ;; display property would render the cell as bare spaces.
         ;; The image is a button like the mxc string beside it —
         ;; the mxc identifies the avatar beyond one session, and
         ;; both open it full-size.  Anon mode keeps the plain
         ;; string: the picture is the room's identity, exactly
         ;; what anon hides.
         (show (lambda (_)
                 (require 'elneo-image)
                 (elneo-avatar-show profile mxc)))
         (mxc-button
          (lambda ()
            (with-current-buffer standard-output
              (insert-text-button mxc 'action show
                                  'help-echo "Show the avatar full-size")))))
    (when img
      (with-current-buffer standard-output
        (insert-text-button img 'action show
                            'help-echo "Show the avatar full-size"))
      (princ " "))
    (cond
     ((or (null mxc) (string-empty-p mxc)) (princ "(none)"))
     ;; Not cached yet (and this Emacs can show it): fetch, and the
     ;; arrival re-renders this room's open overviews.  The failed
     ;; mark keeps a dead entry from re-fetching forever.
     ((and (display-graphic-p)
           (not elneo-anon-mode)
           (not (gethash mxc elneo-client--avatar-cache))
           (not (gethash mxc elneo-client--avatar-pending)))
      (elneo-client-fetch-avatar
       (plist-get room :profile) mxc
       (lambda (_profile event)
         (when (alist-get '@ok event nil nil #'equal)
           (when-let* ((fresh (elneo-room-get (plist-get room :profile)
                                              (plist-get room :room-id))))
             (elneo-room--settings-refresh fresh)))))
      (funcall mxc-button))
     (elneo-anon-mode (princ mxc))
     (t (funcall mxc-button))))
  (when (and joined (elneo-room--gate buf :can-avatar))
    (elneo-room--settings-button "[set]" "Set the room's avatar image"
                                 (elneo-room--settings-in-room
                                  buf #'elneo-room-set-avatar))
    (when (plist-get room :avatar)
      (elneo-room--settings-button "[clear]" "Remove the room's avatar"
                                   (lambda (_button)
                                     (with-current-buffer buf
                                       (elneo-room--avatar-change nil))))))
  (princ "\n"))

(defun elneo-room--settings-memberships (room)
  "The room-type and membership facts: encryption, spaces, upgrades, bridge."
  (let ((yes-no (lambda (v) (if v "yes" "no"))))
    (princ (format "  Encrypted:     %s\n" (funcall yes-no (plist-get room :encrypted))))
    (princ (format "  Direct:        %s\n" (funcall yes-no (plist-get room :direct))))
    ;; "Is a space" — the room ITSELF is typed as a space and so opens
    ;; as one from the bar's `b'; "Spaces:" below is the other
    ;; direction: the spaces THIS room is a member of.  The two are
    ;; easy to conflate, hence the wordier label.  On a space row the
    ;; fact carries the [rooms] browse: the discovery page of the room
    ;; itself (its parents come from the response's canonical-first
    ;; answer, the rooms it houses from the hierarchy).
    (let ((id (plist-get room :room-id))
          (profile (plist-get room :profile)))
      (princ (format "  Is a space:    %s" (funcall yes-no (plist-get room :space))))
      (when (and (plist-get room :space) (not elneo-anon-mode))
        (princ "  ")
        (elneo-room--settings-button
         "[rooms]"
         "List the rooms this space offers"
         (lambda (_button)
           (require 'elneo-space)
           (elneo-space-browse profile id))))
      (princ "\n")))
  ;; The upgrade links (protocol 19), both directions: the room this
  ;; one was upgraded to, and the older room this one continues.
  ;; `[open]' hands the target to the matrix.to handler — its
  ;; registry pick opens, an unknown target offers to join.
  (unless elneo-anon-mode
    (pcase-dolist (`(,label . ,key)
                   (list (cons "  Upgraded to:   " :upgraded-to)
                         (cons "  Continues:     " :upgraded-from)))
      (let ((target (plist-get room key)))
        (when target
          (princ (format "%s%s" label target))
          (elneo-room--settings-button
           "[open]"
           "Open that room (it may still need joining)"
           (lambda (_button)
             (elneo-room--open-matrix-link
              (plist-get room :profile) target)))
          (princ "\n")))))
  ;; The parent spaces the room declares (roomSpaces): a button per
  ;; parent, each opening that space's discovery page.  Anonymous
  ;; screenshots hide room names in every other surface, and these
  ;; are other rooms' names, so anon loses the line rather than
  ;; faking them.  The fetch runs with the opening view (see
  ;; `elneo-room-settings'); a landed, empty snapshot simply has
  ;; nothing to show here.
  (unless elneo-anon-mode
    (let ((spaces (gethash (plist-get room :room-id) elneo-room--spaces)))
      (when spaces
        (princ "  Spaces:        ")
        (dolist (parent spaces)
          ;; Own binding per parent: the button's closure carries
          ;; the row it was rendered with, never the loop variable.
          (let* ((id (alist-get 'room_id parent nil nil #'equal))
                 (label (or (alist-get 'name parent nil nil #'equal) id)))
            (elneo-room--settings-button
             (format "%s" label)
             (format "List the rooms %s offers" label)
             (lambda (_button)
               (elneo-space-browse (plist-get room :profile) id)))))
        (princ "\n"))))
  (when (plist-get room :bridge)
    (princ (format "  Bridged into:  %s\n" (plist-get room :bridge)))))

(defun elneo-room--settings-pinned (room buf)
  "The pinned-messages rows (protocol 22) with their [jump] buttons.
One row per pinned event — its text when the room's BUF has the
message already, the bare event id otherwise.  Anonymous
screenshots keep the bodies out (the ids are fine: they carry
no room content)."
  (let ((pinned (plist-get room :pinned)))
    (when (and (listp pinned) (> (length pinned) 0))
      (princ "  Pinned:\n")
      (dolist (id pinned)
        (let* ((msg (and (buffer-live-p buf)
                         (buffer-local-value 'elneo-room--seen buf)
                         (gethash id (buffer-local-value 'elneo-room--seen buf))))
               (body (and msg (not elneo-anon-mode) (plist-get msg :body)))
               (preview
                (or (and body
                         (string-replace "\n" " "
                                         (string-trim body)))
                    id))
               (preview (if (and body (> (length preview) 44))
                            (concat (substring preview 0 44) "…")
                          preview)))
          (princ (format "                 %s" preview))
          (elneo-room--settings-button
           "[jump]"
           "Put point on that message (loading older history when needed)"
           (lambda (_button)
             (elneo-room-jump-to-event
              (plist-get room :profile)
              (plist-get room :room-id) id)))
          (princ "\n"))))))

(defun elneo-room--settings-notifications (room)
  "The activity facts and the notifications section's mode row."
  (let ((mode (plist-get room :notification-mode))
        (user-defined (plist-get room :notification-mode-user-defined))
        (unread (plist-get room :unread))
        (highlights (plist-get room :highlights)))
    ;; The user-defined mode is reported separately so "muted,
    ;; user-set" is distinguishable from a room-type default.
    (let ((mode-label (pcase mode
                        ("all_messages" "all messages")
                        ("mentions_and_keywords" "mentions and keywords only")
                        ("mute" "muted")
                        (_ "unknown")))
          (mode-source (cond
                        ((and mode user-defined) " (user-set)")
                        (mode " (default for room type)")
                        (t ""))))
      (princ (format "  Unread:        %d%s\n" unread
                     (if (> highlights 0) (format " (%d highlight)" highlights) "")))
      (when (plist-get room :last-activity)
        (princ (format "  Last activity: %s\n"
                       (format-time-string "%Y-%m-%d %H:%M"
                                           (/ (plist-get room :last-activity) 1000)))))
      (princ "\nNotifications:\n")
      (princ (format "  Mode:          %s%s\n" mode-label mode-source)))))

(defun elneo-room--settings-permissions (perms)
  "The permission-gates block from the room buffer's snapshot PERMS.
Joined rooms only (the caller guards): an invited or left room
has nothing of ours to gate.  The gates are the same the buttons
above consult, stated in full."
  (princ "\nPermissions:\n")
  (if perms
      (let ((can (string-join
                  (delq nil (mapcar
                             (lambda (entry)
                               (and (plist-get perms (car entry))
                                    (cadr entry)))
                             elneo-room--permission-gates))
                  ", "))
            (cannot (string-join
                     (delq nil (mapcar
                                (lambda (entry)
                                  (and (not (plist-get perms (car entry)))
                                       (cadr entry)))
                                elneo-room--permission-gates))
                     ", ")))
        (princ (format "  Level:         %s\n"
                       (elneo-room--permissions-level perms)))
        (princ (format "  Can change:    %s\n" (or can "nothing")))
        (princ (format "  Not allowed:   %s\n" (or cannot "nothing"))))
    (princ "  (the permissions snapshot has not landed yet)\n")))

(defun elneo-room--settings-receipts (buf)
  "The read-by block: the receipt state of the open room buffer BUF.
At the very end: occasionally interesting, mostly in the way —
a long read-list between the facts and the settings is
a scroll past data nobody asked to see."
  (let ((receipts
         (and (buffer-live-p buf)
              (hash-table-p (buffer-local-value 'elneo-room--receipts
                                                buf))
              (let ((all nil))
                (maphash (lambda (_user r) (push r all))
                         (buffer-local-value 'elneo-room--receipts
                                             buf))
                (sort all
                      (lambda (a b)
                        (string-lessp
                         (or (plist-get a :user-name) (plist-get a :user-id))
                         (or (plist-get b :user-name) (plist-get b :user-id))))))))
        (seen (and (buffer-live-p buf)
                   (buffer-local-value 'elneo-room--seen buf))))
    (when receipts
      (princ "\nRead by:\n")
      (dolist (r receipts)
        (let* ((target (gethash (plist-get r :event-id) seen)))
          (princ (format "  %-15s up to %s (read at %s)\n"
                         (or (plist-get r :user-name)
                             (plist-get r :user-id))
                         (if target
                             (format "the %s message from %s"
                                     (elneo-room--format-ts
                                      (plist-get target :ts))
                                     (elneo-room--sender-name target))
                           (plist-get r :event-id))
                         (if (plist-get r :ts)
                             (format-time-string
                              "%H:%M" (/ (plist-get r :ts) 1000))
                           "?"))))))))

(defun elneo-room-settings--render (room)
  "Render ROOM's settings overview into the current help buffer."
  ;; Anon mode fakes the display-name, name, alias and topic; the
  ;; room id, profile, bridging and receipts stay real (the user's
  ;; own identity is not what screenshots must hide).
  (let* ((room (if elneo-anon-mode (elneo-anon--room room) room))
         ;; The Name/Topic buttons need the live buffer (the commands
         ;; run with it current) and the joined state.  One resolution
         ;; for the whole view: every section below keys on the same
         ;; room buffer.
         (buf (elneo-room--buffer-for (plist-get room :profile)
                                      (plist-get room :room-id)))
         (joined (and buf (equal (plist-get room :room-state) "joined")))
         ;; The permissions snapshot the room buffer fetched (on open,
         ;; re-fetched on each opening of this view): the gates below
         ;; and the Permissions section read it.  Unknown (never
         ;; landed) lets every button show and the homeserver reject.
         (perms (and (buffer-live-p buf)
                     (buffer-local-value 'elneo-room--permissions buf)
                     (plist-get (buffer-local-value 'elneo-room--permissions buf)
                                :fetched)
                     (buffer-local-value 'elneo-room--permissions buf))))
    (princ (format "%s %s\n\n"
                   (if (plist-get room :space) "Matrix space" "Matrix room")
                   (or (plist-get room :display-name)
                       (plist-get room :room-id) "?")))
    (elneo-room--settings-facts room buf joined)
    (elneo-room--settings-avatar room buf joined)
    (elneo-room--settings-memberships room)
    (elneo-room--settings-pinned room buf)
    (elneo-room--settings-notifications room)
    (elneo-room--settings-buttons room buf)
    ;; The room's power levels as this session sees them: the level
    ;; with what is still ours to change — the same gates the buttons
    ;; above consult, stated in full.  Joined rooms only; an invited
    ;; or left room has nothing of ours to gate.
    (when joined
      (elneo-room--settings-permissions perms))
    (elneo-room--settings-receipts buf)
    ;; The view remembers its room: the live refresh
    ;; (`elneo-room--settings-refresh') finds open settings views this
    ;; way and re-renders them on the room's updateRoom events.
    (with-current-buffer standard-output
      (setq-local elneo-room-settings--room
                  (cons (plist-get room :profile)
                        (plist-get room :room-id))))))

;;; Room management
;; The transport wrappers live in elneo-client.el (elneo-invite-user,
;; elneo-set-room-name, ...); this is the interactive layer: completing
;; over the room's member roster where one exists, a confirmation where
;; the action is hard to undo.  Reachable from the `C-c ?' settings
;; view's [action] buttons on any room, and as a whole from the
;; transient menu (`C-c C-m' in a room buffer, `elneo-room-actions'
;; elsewhere).

;;;###autoload
(defun elneo-room-actions ()
  "Open the transient menu of the room management actions.
The whole section in one place, mirroring the [action] row of the
`C-c ?' settings view; the menu also offers join/create/direct
message, which work outside a room buffer.  Needs the `transient'
package (the one behind magit's popups)."
  (interactive)
  (if (require 'transient nil t)
      (progn (require 'elneo-transient)
             (call-interactively #'elneo-room-actions-dispatch))
    (message "Matrix: the actions menu needs the transient package")))

(defun elneo-room--ident ()
  "The (PROFILE . ROOM-ID) of the current Matrix room buffer."
  (unless (derived-mode-p 'elneo-room-mode)
    (user-error "Not in a Matrix room buffer"))
  (unless (and elneo-room--profile elneo-room--room-id)
    (user-error "No Matrix profile and room behind this buffer"))
  (cons elneo-room--profile elneo-room--room-id))

(defun elneo-room--ack-message (event sent why)
  "Report a room-management ack: SENT when EVENT has @ok, WHY's text otherwise.
The shared failure wording of this section's commands — the action
name in SENT (e.g. \"invited bob:example.org\"), the reason in WHY
(e.g. \"invite failed\").  Also returns non-nil on success, so a
callback can follow the ack with cleanup."
  (if (alist-get '@ok event nil nil #'equal)
      (progn (message "Matrix: %s" sent) t)
    (message "Matrix: %s — %s" why (elneo-server--error-string event))
    nil))

(defun elneo-room--known-people-entries ()
  "People beyond the current room's roster, as roster entries.
Swept from this profile's OTHER open room buffers' member rosters —
a DM the user opened contributes its partner there like any other
room (the daemon's room summary carries no peer user id, so opened
rooms are the only source that can name one).  A person the roster
already answers for, and the room's own user, stay out — the roster
read wins, a duplicate label would shadow its pick."
  (let* ((own (elneo-server--user-id elneo-room--profile))
         (roster (elneo-room--roster-entries))
         (taken (mapcar #'cadr roster))
         (known nil))
    (dolist (buffer (hash-table-values elneo-room--buffers))
      (when (and (buffer-live-p buffer)
                 (equal (buffer-local-value 'elneo-room--profile buffer)
                        elneo-room--profile)
                 (not (eq buffer (current-buffer))))
        (dolist (member (buffer-local-value 'elneo-room--members buffer))
          (let ((id (plist-get member :user-id))
                (name (plist-get member :name)))
            (when (and id (not (equal id own))
                       (not (member id taken))
                       (not (cl-member id known :test #'equal :key #'cadr)))
              (push (if (and name (not (equal name id)))
                        (list (format "%s (%s)" name id) id name)
                      (list id id id))
                    known))))))
    (append roster (nreverse known))))

(defun elneo-room--read-user-id (prompt &optional default known)
  "Read a room member's user id with PROMPT, completing over the roster.
With KNOWN non-nil the roster is extended with people from the
profile's other open room buffers first — the invite picker wants
to offer the DM partners even before they are (visibly) in this
room.  The roster answers only for room buffers, so this works
inside `elneo-room-mode' commands; a typed id not in the roster is
accepted as-is (an invite to a member not yet in the room falls
back to typing the id)."
  (let* ((candidates (mapcar (lambda (entry)
                               (cons (car entry) (cadr entry)))
                             (if known
                                 (elneo-room--known-people-entries)
                               (elneo-room--roster-entries))))
         (picked (completing-read prompt candidates nil nil nil nil default)))
    ;; completing-read returns the label; map it back to the id.
    (or (alist-get picked candidates nil nil #'equal) picked)))

(defun elneo-room--room-display-name ()
  "The current room buffer's display name or room id."
  (let ((room (elneo-room-get elneo-room--profile elneo-room--room-id)))
    (or (plist-get room :display-name) elneo-room--room-id)))

(defun elneo-room-invite (user-id)
  "Invite USER-ID to the current room.
Completes over the room's member roster extended by the people
this profile shares other open rooms with — its opened DM
partners lead there — and accepts typed ids for people who are
not (visibly) in it yet."
  (interactive
   (progn (elneo-room--ident)
          (elneo-room--ensure-permission :can-invite "invite")
          (list (elneo-room--read-user-id "Invite who: " nil 'known))))
  (pcase-let* ((`(,profile . ,room-id) (elneo-room--ident))
               ;; The ack callback runs in the daemon's process
               ;; buffer — the room's buffer-locals are gone by then,
               ;; so the room name must be captured at send time.
               (room-name (elneo-room--room-display-name)))
    (elneo-invite-user profile room-id user-id
                       (lambda (_profile event)
                         (elneo-room--ack-message
                          event
                          (format "invited %s to %s" user-id room-name)
                          "invite failed")))))

(defun elneo-room-kick (user-id reason)
  "Kick USER-ID from the current room; REASON may be empty.
A kick is re-invitable — for a room you cannot get back into
someone, use `elneo-room-ban'."
  (interactive
   (progn (elneo-room--ident)
          (elneo-room--ensure-permission :can-kick "kick")
          (list (elneo-room--read-user-id "Kick who: ")
                (read-string "Kick reason (optional): "))))
  (pcase-let* ((`(,profile . ,room-id) (elneo-room--ident))
               (room-name (elneo-room--room-display-name)))
    (elneo-kick-user profile room-id user-id
                     (and (not (equal reason "")) reason)
                     (lambda (_profile event)
                       (elneo-room--ack-message
                        event
                        (format "kicked %s from %s" user-id room-name)
                        "kick failed")))))

(defun elneo-room-ban (user-id reason)
  "Ban USER-ID from the current room; REASON may be empty.
Bans outlast the session — the user cannot rejoin until unbanned,
and the client does not yet have a banned-members roster to offer
`elneo-unban-user' interactively."
  (interactive
   (progn (elneo-room--ident)
          (elneo-room--ensure-permission :can-ban "ban")
          (let ((user (elneo-room--read-user-id "Ban who: ")))
            (list user (read-string
                        (format "Ban %s — reason (optional): " user))))))
  (unless (y-or-n-p
           (format "Ban %s from %s?  They cannot rejoin"
                   user-id (elneo-room--room-display-name)))
    (user-error "Canceled"))
  (pcase-let* ((`(,profile . ,room-id) (elneo-room--ident))
               (room-name (elneo-room--room-display-name)))
    (elneo-ban-user profile room-id user-id
                    (and (not (equal reason "")) reason)
                    (lambda (_profile event)
                      (elneo-room--ack-message
                       event
                       (format "banned %s from %s" user-id room-name)
                       "ban failed")))))

(defun elneo-room-set-name (name)
  "Rename the current room to NAME (empty clears it).
The new name lands everywhere the room's name shows — bar row,
buffer name, `C-c ?' view — via the `updateRoom' event."
  (interactive
   (progn (elneo-room--ident)
          (elneo-room--ensure-permission :can-name "rename")
          (let ((room (elneo-room-get elneo-room--profile
                                      elneo-room--room-id)))
            (list (read-string "Room name (empty to clear): "
                               nil nil
                               (or (plist-get room :name) ""))))))
  (pcase-let* ((`(,profile . ,room-id) (elneo-room--ident))
               (room-name (elneo-room--room-display-name)))
    (elneo-set-room-name profile room-id name
                         (lambda (_profile event)
                           (elneo-room--ack-message
                            event
                            (format "named %s %S" room-name name)
                            "rename failed")))))

(defun elneo-room-set-topic (topic)
  "Set the current room's TOPIC (empty clears it).
Non-plain markup goes out as typed — a `*room.el*' body is not
rendered here, only in clients that format topics."
  (interactive
   (progn (elneo-room--ident)
          (elneo-room--ensure-permission :can-topic "change the topic")
          (let ((room (elneo-room-get elneo-room--profile
                                      elneo-room--room-id)))
            (list (read-string "Topic (empty to clear): "
                               nil nil
                               (or (plist-get room :topic) ""))))))
  (pcase-let* ((`(,profile . ,room-id) (elneo-room--ident))
               (room-name (elneo-room--room-display-name)))
    (elneo-set-room-topic profile room-id topic
                          (lambda (_profile event)
                            (elneo-room--ack-message
                             event
                             (format "set the topic of %s" room-name)
                             "topic change failed")))))

(defun elneo-room--avatar-change (path)
  "Send PATH as the current room's new avatar; nil removes it.
The transport behind `elneo-room-set-avatar' and the `C-c ?' view's
[set]/[clear] buttons — the permission gate reads this room's
snapshot, so the helper runs inside the room buffer."
  (let ((path (and path (not (equal path "")) (expand-file-name path))))
    (when (and path (not (file-exists-p path)))
      (user-error "No such file: %s" path))
    (pcase-let* ((cleared (not path))
                 (`(,profile . ,room-id) (elneo-room--ident))
                 (room-name (elneo-room--room-display-name)))
      (elneo-set-room-avatar profile room-id path
                             (lambda (_profile event)
                               (elneo-room--ack-message
                                event
                                (if cleared
                                    (format "cleared the avatar of %s" room-name)
                                  (format "set the avatar of %s" room-name))
                                "avatar change failed"))))))

(defun elneo-room-set-avatar (path)
  "Set the current room's avatar image to PATH, or clear the avatar.
PATH is a file name (the mime type is the daemon's to guess); with
a prefix argument the call clears the current one instead.  The
avatar shows in the room bar and updates via the room's
`updateRoom' event; a room without one falls back to the tile the
bar renders from the room's initials."
  (interactive
   (progn (elneo-room--ident)
          (elneo-room--ensure-permission :can-avatar "change the avatar")
          (list (if current-prefix-arg
                    ""
                  (read-file-name "Avatar image: " nil nil t)))))
  (elneo-room--avatar-change path))

;; Room-scoped nick (the `m.room.member' displayname) — the C-c ?
;; view lists it under the room facts, with a [nick] button.

(defun elneo-room--own-nick ()
  "The display name the current room sees for this account, or nil.
Nil means the room carries no room-local displayname — the
rendering falls to the profile display name."
  (plist-get (cl-find (elneo-server--user-id elneo-room--profile)
                      elneo-room--members
                      :key (lambda (member) (plist-get member :user-id))
                      :test #'equal)
             :name))

(defun elneo-room-set-nick (name)
  "Set this account's nick in the current room to NAME (empty clears it).
One room's `m.room.member' displayname — every other room keeps the
profile display name untouched.  The change flows back with the
member events, which refresh the roster."
  (interactive
   (progn (elneo-room--ident)
          (list (let ((input (read-string
                              "Nick in this room (empty to clear): "
                              nil nil (or (elneo-room--own-nick) ""))))
                  (and (> (length input) 0) input)))))
  (pcase-let* ((`(,profile . ,room-id) (elneo-room--ident))
               (room-name (elneo-room--room-display-name)))
    (elneo-set-own-room-display-name profile room-id name
                                     (lambda (_profile event)
                                       (elneo-room--ack-message
                                        event
                                        (format "nick in %s: %s"
                                                room-name
                                                (or name "(the profile name)"))
                                        "nick not changed")))))

(defun elneo-room--leave-confirmed (profile room-id &optional buf)
  "Ask a leave confirmation and leave PROFILE's ROOM-ID.
The ack report goes to the echo area either way; BUF, when still
live at that point, closes with a successful leave (the room
buffer's view of the room).  BUF nil closes nothing here but the
room's open buffer, if one is registered.
An invited room declines instead (that is what leaving one is)."
  (let* ((room (elneo-room-get profile room-id))
         (invited (equal (plist-get room :room-state) "invited"))
         (name (or (plist-get room :display-name) room-id)))
    (when (y-or-n-p
           (if invited
               (format "Decline the invite to %s? " name)
             (if (plist-get room :direct)
                 (format "Leave DM %s?  It returns when the peer writes again" name)
               (format "Leave %s?  Rejoining needs someone to re-invite you" name))))
      (elneo-leave-room profile room-id
                        (lambda (_profile event)
                          (when (elneo-room--ack-message
                                 event (format "left %s" name) "leave failed")
                            ;; BUF nil (the bar path): the room's registered buffer,
                            ;; if any, is the view of the room that closes with it.
                            (let ((close (or buf (gethash (cons profile room-id)
                                                          elneo-room--buffers))))
                              (when (buffer-live-p close)
                                (kill-buffer close)))))))))

(defun elneo-room-leave ()
  "Leave the current room, after a confirmation.
An invited room declines instead (that is what leaving one is).
The room's row leaves the bar via `updateRoomGone'; the buffer
closes with the ack.  Rejoining later works while an invite lasts;
otherwise someone must re-invite."
  (interactive)
  (pcase-let* ((`(,profile . ,room-id) (elneo-room--ident)))
    (elneo-room--leave-confirmed profile room-id (current-buffer))))

(defun elneo-room-forget ()
  "Forget the current left room: remove it from the room bar.
Only the server's own gate on this (\"can only be called for rooms
the user has left\") keeps a joined room out; we check the state
first for a readable error."
  (interactive)
  (pcase-let* ((`(,profile . ,room-id) (elneo-room--ident))
               (room (elneo-room-get profile room-id)))
    (unless (equal (plist-get room :room-state) "left")
      (user-error "Only left rooms can be forgotten — leave it first"))
    (elneo-forget-room profile room-id
                       (lambda (_profile event)
                         (elneo-room--ack-message
                          event
                          ;; The bar row leaves via updateRoomGone, ahead of this ack.
                          (format "forgot %s"
                                  (or (plist-get room :display-name) room-id))
                          "forget failed")))))

(defun elneo-room--read-profile ()
  "The profile to act on: this room buffer's, one completing over accounts.
Outside a room buffer the registered accounts are offered
(`elneo--accounts-load' answers, so this works on a fresh
session); with none registered it errors with the honest story."
  (if (derived-mode-p 'elneo-room-mode)
      (or elneo-room--profile
          (user-error "No Matrix profile behind this buffer"))
    (elneo--accounts-load)
    (unless elneo-accounts
      (user-error "No Matrix profiles registered"))
    (completing-read "Profile: " (mapcar #'car elneo-accounts) nil t)))

(defun elneo-room--read-profile-anywhere ()
  "A profile, asked about even inside a room buffer.
Unlike `elneo-room--read-profile' (which takes a room buffer's own
account silently), this completing-read always runs — with the
current room's profile as the default, the registered accounts as
the choices (`elneo--accounts-load' answers, so it works on a
fresh session too), and with no accounts registered it errors with
the honest story."
  (elneo--accounts-load)
  (unless elneo-accounts
    (user-error "No Matrix profiles registered"))
  (let ((default (and (derived-mode-p 'elneo-room-mode)
                      elneo-room--profile)))
    (completing-read
     (format "Profile%s: "
             (if default (format " (default %s)" default) ""))
     (mapcar #'car elneo-accounts) nil t nil nil (or default))))

;;;###autoload
(defun elneo-room-join (profile room-id-or-alias)
  "Join PROFILE's room ROOM-ID-OR-ALIAS (a room id or #alias) and open it.
Works across accounts and from anywhere, not only room buffers —
an alias join needs the homeserver to resolve it, and an invited
room joins without one.  The profile is always asked (the current
room buffer's as the default, see
`elneo-room--read-profile-anywhere') — a join is where accounts
differ most.  On success the room's buffer opens in the main area,
seeded summary arriving ahead of the ack (`updateRoom'), the room
id in `roomJoined'.  A room the seeded summary types as a space
opens as its space page instead — joining a space has always been
this command; only the handling differs (`elneo-join-matrix-to'
wraps both in a matrix.to-URL prompt)."
  (interactive
   (list (elneo-room--read-profile-anywhere)
         (read-string "Join room (#alias or id): ")))
  (elneo-join-room profile room-id-or-alias
                   (lambda (profile event)
                     (if (not (alist-get '@ok event nil nil #'equal))
                         (message "Matrix: join failed — %s"
                                  (elneo-server--error-string event))
                       (let ((room (elneo-room-get profile (alist-get 'room_id event))))
                         (cond
                          ((and room (plist-get room :space))
                           (require 'elneo-space)
                           (elneo-space-browse profile (plist-get room :room-id)))
                          (room (elneo-room--open room))
                          ((message "Matrix: joined %s" room-id-or-alias))))))))

(defun elneo-join-matrix-to--link (input)
  "The join target INPUT names, with its via servers: (TARGET . VIA).
A matrix.to URL parses through `elneo-room--matrix-to-link' (its
`?via=' tail comes along); a bare `!id:hs' or `#alias:hs' passes
through with no via; anything else — that includes matrix.to URLs
of other shapes (users, event anchors) — reads nil, for which the
caller refuses honestly."
  (setq input (string-trim input))
  (or (elneo-room--matrix-to-link input)
      (and (string-prefix-p "!" input) (string-search ":" input)
           (cons input nil))
      (and (string-prefix-p "#" input) (cons input nil))))

;;;###autoload
(defun elneo-join-matrix-to (profile url)
  "Open or join the room PROFILE's URL points at.
URL is usually what a friend shared — `https://matrix.to/#/...'
(aliases ride their percent-encoded `#') — but a bare room id
(`!x:hs') or alias (`#x:hs') works the same, handy from a pasted
message.  A room the profile knows opens (a space as its
discovery page, like every matrix.to link); an unknown one asks
to join, the homeserver resolving an alias on the way and the
link's via servers riding along (the route a remote room without
an alias is only reachable through).  The profile is always
asked, like the join it wraps (see `elneo-room-join' — this is
its reading half)."
  (interactive
   (list (elneo-room--read-profile-anywhere)
         (read-string "Matrix room (matrix.to link, #alias or id): ")))
  (if-let* ((link (elneo-join-matrix-to--link url)))
      (elneo-room--open-matrix-link profile (car link) (cdr link))
    (user-error
     "Not a room link — a matrix.to room URL, a room id (!x:hs) or an alias (#x:hs)")))

;;;###autoload
(defun elneo-room-create (profile name alias public topic encrypted)
  "Create a new room on PROFILE and open it.
NAME is the display name, ALIAS the optional alias local part
(\"ops\" means #ops:SERVER — a typed # is stripped), PUBLIC lists
the room in the directory (else private-only), TOPIC optional
plain text.  ENCRYPTED adds the initial m.room.encryption state —
asked at creation because encryption cannot be practically added
to a room once it exists.  Invites at creation ride
`elneo-create-room' with its `:invites'/`:is-direct' props; a
start-DM command hangs off that."
  (interactive
   (let ((profile (elneo-room--read-profile)))
     (list profile
           (read-string "Room name: ")
           (string-trim-left (read-string "Alias local part (empty for none): ") "#")
           (y-or-n-p "Public (listed in the directory)? ")
           (read-string "Topic (empty for none): ")
           (y-or-n-p "Encrypt the room (cannot be added later)? "))))
  (let ((props (append
                (unless (string-empty-p name) (list :name name))
                (unless (string-empty-p alias) (list :alias alias))
                (when public (list :public t))
                (unless (string-empty-p topic) (list :topic topic))
                (when encrypted (list :encrypted t)))))
    (elneo-create-room
     profile props
     (lambda (profile event)
       (if (alist-get '@ok event nil nil #'equal)
           (let ((room (elneo-room-get profile (alist-get 'room_id event))))
             (if room
                 (elneo-room--open room)
               (message "Matrix: created %s"
                        (alist-get 'room_id event))))
         (message "Matrix: create failed — %s"
                  (elneo-server--error-string event)))))))

;;;###autoload
(defun elneo-start-dm (profile user-id)
  "Start a direct-message room with USER-ID on PROFILE, from anywhere.
The id-only entry point: PROFILE is asked
(`elneo-room--read-profile-anywhere'), USER-ID is typed
(@user:server) — no room roster assumed behind the pick.  The rest
of the flow is `elneo-room-start-dm's."
  (interactive
   (list (elneo-room--read-profile-anywhere)
         (read-string "Direct message user id (@user:server): ")))
  (elneo-room-start-dm profile user-id))

;;;###autoload
(defun elneo-room-start-dm (profile user-id)
  "Start a direct-message room with USER-ID on PROFILE and open it.
The room is private and encrypted; the daemon files it under
m.direct at creation, so the DM badge and the bar's DM filter see
it from the first summary that follows the account-data sync (the
same book-keeping happens when this account accepts a
direct-flagged invite — it marks the room on its side and the
invitee's client is expected to do likewise).  Reusing an
existing DM with the same person is not checked yet: start-DM
always creates a fresh room.

Inside a room buffer the user pick completes over that room's
roster; elsewhere type the id (@user:server)."
  (interactive
   (list (elneo-room--read-profile)
         (if (derived-mode-p 'elneo-room-mode)
             (elneo-room--read-user-id "Direct message: ")
           (read-string "Direct message user id (@user:server): "))))
  (elneo-create-room
   profile (list :invites (list user-id) :is-direct t :encrypted t)
   (lambda (profile event)
     (if (alist-get '@ok event nil nil #'equal)
         (let ((room (elneo-room-get profile (alist-get 'room_id event))))
           (if room
               (elneo-room--open room)
             (message "Matrix: direct message to %s ready" user-id)))
       (message "Matrix: start DM failed — %s"
                (elneo-server--error-string event))))))

;;;###autoload
(defun elneo-account-set-name (profile name)
  "Set PROFILE's display NAME to the given account.
Empty clears the name.  The change flows back through the room
member events — the buffer does not need to reload for it.
In a room buffer the account is that buffer's; elsewhere it
completes over the registered accounts."
  (interactive (list (elneo-room--read-profile)
                     (read-string "Display name (empty to clear): ")))
  (let ((name (and (not (string-empty-p name)) name)))
    (elneo-set-display-name profile name
                            (lambda (_profile event)
                              (if (alist-get '@ok event nil nil #'equal)
                                  (message "Matrix: display name set")
                                (message "Matrix: display name failed — %s"
                                         (elneo-server--error-string event)))))))

;;;###autoload
(defun elneo-account-set-avatar (profile path)
  "Set PROFILE's avatar image from PATH; C-u clears instead.
The daemon reads and uploads the file, mime type guessed from
the path."
  (interactive
   (list (elneo-room--read-profile)
         (if current-prefix-arg
             nil
           (read-file-name "Avatar image (C-u to clear): "))))
  (elneo-set-avatar profile path
                    (lambda (_profile event)
                      (if (alist-get '@ok event nil nil #'equal)
                          (message "Matrix: avatar %s" (if path "set" "cleared"))
                        (message "Matrix: avatar failed — %s"
                                 (elneo-server--error-string event))))))

;; with-help-window has point in the help window proper; buttons must
;; insert into `standard-output' (elneo-verify.el's precedent).

(defun elneo-room--settings-button (label help fn)
  "Insert one settings-view button, LABEL with HELP-echo HELP, running FN.
A space separates the button from whatever text precedes it — the
facts anchor their buttons on the tail of their line.  The space is
not part of the button, whatever fontification its face carries
(the room-bar convention, `elneo-room-bar--control-button'): a
separator inside the button text has the underline/box begin one
character before the label."
  (with-current-buffer standard-output
    (insert " ")
    (insert-text-button label 'action fn 'help-echo help)
    (insert "  ")))

(defun elneo-room--settings-in-room (buf cmd)
  "An action function running interactive CMD with BUF current.
The room's own buffer is current, so the completing-reads pull
that room's member roster; the minibuffer asks afterwards."
  (lambda (_button)
    (with-current-buffer buf
      (call-interactively cmd))))

(defun elneo-room--settings-buttons (room buf)
  "Insert the settings view's room-management action row.
The set follows the room's state: invited rooms decline instead of
leaving, left rooms forget.  Only the actions with no text in the
overview to anchor them sit here — the name and the topic run from
their own buttons on the Name and Topic facts.  BUF is the room
buffer the render resolved once for all sections."
  (let* ((state (plist-get room :room-state))
         (name (or (plist-get room :display-name)
                   (plist-get room :room-id)))
         (button #'elneo-room--settings-button)
         (in-room (lambda (cmd)
                    (elneo-room--settings-in-room buf cmd))))
    (when (or (equal state "left") buf)
      ;; One action row for both the forget case (left rooms, live
      ;; buffer or not) and the leave case (joined/invited rooms).
      (princ "Actions:\n  ")
      (when (equal state "left")
        (funcall button "[forget]"
                 (format "Forget %s — its row leaves the room bar" name)
                 (lambda (_button)
                   (when (y-or-n-p (format "Forget %s? " name))
                     (elneo-forget-room
                      (plist-get room :profile) (plist-get room :room-id)
                      (lambda (_p event)
                        (elneo-room--ack-message
                         event (format "forgot %s" name)
                         "forget failed")))))))
      (when (and buf (not (equal state "left")))
        (when (equal state "joined")
          ;; The permission-gated actions stay quiet when the room
          ;; buffer's snapshot withholds them ([leave] below is the
          ;; one action own membership always carries).
          (when (elneo-room--gate buf :can-invite)
            (funcall button "[invite]" "Invite a user to this room"
                     (funcall in-room #'elneo-room-invite)))
          (when (elneo-room--gate buf :can-kick)
            (funcall button "[kick]" "Kick a user (they can be re-invited)"
                     (funcall in-room #'elneo-room-kick)))
          (when (elneo-room--gate buf :can-ban)
            (funcall button "[ban]" "Ban a user (they cannot rejoin)"
                     (funcall in-room #'elneo-room-ban))))
        (funcall button "[leave]"
                 (if (equal state "invited")
                     (format "Decline the invite to %s" name)
                   (format "Leave %s" name))
                 (funcall in-room #'elneo-room-leave)))
      (princ "\n"))))

;;; Jump to a reply's parent

(defun elneo-room--jump-land (pos)
  "Land a jump at POS: mark the old spot, move point and view there."
  (push-mark pos)
  (if-let* ((win (get-buffer-window (current-buffer) t)))
      (with-selected-window win
        (goto-char pos)
        (recenter))
    (goto-char pos))
  (message "Jumped to referenced message"))

(defun elneo-room--jump-to-reply (target-id)
  "Jump to event TARGET-ID, loading older pages first if needed.
Already-rendered targets jump directly; otherwise bounded
auto-pagination runs until it lands or history is exhausted."
  (let ((pos (elneo-room--find-event target-id)))
    (cond
     (pos (elneo-room--jump-land pos))
     ((null elneo-room--end-token)
      (message "Matrix: referenced message not in loaded history"))
     (t
      (setq elneo-room--jump-target target-id
            elneo-room--jump-pages 0)
      (message "Matrix: searching older history for the referenced message...")
      (elneo-room--jump-next-page)))))

(defun elneo-room--jump-next-page ()
  "Fetch one more older page for a pending jump.
Same request as `elneo-room--load-older' but bypassing its rate
limit: the jump driver should run at full speed; the page counter
bounds it."
  (elneo-room--load-older 'anchor 'no-rate-limit))

(defun elneo-room--jump-drive ()
  "Continue a pending jump after an older page landed."
  (let ((pos (and elneo-room--jump-target
                  (elneo-room--find-event elneo-room--jump-target))))
    (cond
     (pos
      (setq elneo-room--jump-target nil
            elneo-room--jump-pages 0)
      (elneo-room--jump-land pos))
     ((or (null elneo-room--end-token)
          (>= elneo-room--jump-pages elneo-room-jump-page-limit))
      (setq elneo-room--jump-target nil
            elneo-room--jump-pages 0)
      (message "Matrix: could not find the referenced message in nearby history"))
     (t
      (setq elneo-room--jump-pages (1+ elneo-room--jump-pages))
      (elneo-room--jump-next-page)))))

(defun elneo-room-jump-to-event (profile room-id event-id &optional stay-put)
  "Open PROFILE's ROOM-ID and put point on EVENT-ID.
The alert inbox uses this for RET-jump-to-message.  With STAY-PUT
non-nil, the open ignores `elneo-room-open-frame-policy' and
displays right where we are.  A rendered room jumps directly; a
room whose buffer does not exist yet opens first and the jump
runs when the first history page lands; targets above the loaded
history paginate back through the reply-jump driver."
  (let* ((room (elneo-room-get profile room-id))
         (buffer (elneo-room--buffer-for profile room-id)))
    (unless room (user-error "Matrix: no room record for %s" room-id))
    (if (and buffer (buffer-local-value 'elneo-room--backfilled buffer))
        (progn
          (elneo-room--display-room-buffer buffer stay-put)
          (with-current-buffer buffer
            (elneo-room--jump-to-reply event-id)))
      ;; Opening also (re)triggers the backfill; the response arrives
      ;; asynchronously, so stashing the pending jump afterwards is
      ;; race-free — render-first-page consumes it.
      (elneo-room--open room stay-put)
      (with-current-buffer (elneo-room--buffer-for profile room-id)
        (setq elneo-room--pending-jump-event-id event-id)))))

;;; Read markers

(defcustom elneo-room-read-style 'cursor
  "How the room buffer marks events read.
`cursor' marks everything the cursor has moved past — and, while a
window shows the buffer's end, everything that scrolls past.  The
daemon command is debounced, so a burst of movement sends one read
mark.  `manual' never marks read on its own; use M-x
elneo-room-mark-buffer-read.

Read marks are always private (m.read.private plus the fully-read
marker): they move this account's unread counters without telling
other room members anything.  The public m.read receipt is a
separate opt-in, `elneo-send-public-read-receipts', off by
default."
  :group 'elneo-room
  :type '(choice (const :tag "Mark read as the cursor moves past" cursor)
                 (const :tag "Only mark read on request" manual)))

(defvar-local elneo-room--read-pending-id nil
  "Event id the cursor has moved past, awaiting the debounce timer.")
(defvar-local elneo-room--read-sent-id nil
  "Event id last sent to the daemon as this buffer's read position.")
(defvar-local elneo-room--read-timer nil
  "Idle timer carrying the pending read mark to the daemon.")

(defun elneo-room--event-id-at (pos)
  "Event id at POS, or nil inside a reply's quote.
Quotes carry a synthetic \"#quote\" id for the media pipeline and
the parent's id as `elneo-room-reply-target' — the read-marker
walker and point commands must never mistake either for the event
under the cursor."
  (unless (get-text-property pos 'elneo-room-quote)
    (get-text-property pos 'elneo-room-event-id)))

(defun elneo-room--event-before-point ()
  "Event id of the newest event entirely above point, or nil.
An event the cursor still sits inside does not count as read."
  (let ((pos (point)) id)
    ;; The character before point is the test, not point itself: at
    ;; point-max Emacs reports the last character's rear-sticky
    ;; property, which would wrongly treat the end of the buffer as
    ;; "inside" the last event.
    (when (and (> pos (point-min))
               (elneo-room--event-id-at (1- pos)))
      ;; Cursor inside an event's line: that event is not read, and
      ;; the boundary moves to the start of its run.
      (setq pos (previous-single-property-change
                 pos 'elneo-room-event-id nil (point-min))))
    ;; POS now sits in a gap, or at the start of an unread event's
    ;; line (cursor on the line's first character, or the move
    ;; above).  In the latter case skip that whole run first.
    (when (elneo-room--event-id-at pos)
      (setq pos (previous-single-property-change
                 pos 'elneo-room-event-id nil (point-min))))
    ;; A `previous-single-property-change' hop lands either on the
    ;; END boundary of the previous event's run (id before POS) or
    ;; on its START (id at POS); either way the run lies entirely
    ;; below the boundary and is read.  Quote lines read as gaps
    ;; (`elneo-room--event-id-at' is nil there — the layout comment
    ;; in `elneo-room--append-messages') — with a synthetic
    ;; media id in `full' style, the walk must land on the parent
    ;; message's line, never on the quote.
    (while (and (> pos (point-min))
                (not (setq id (or (elneo-room--event-id-at (1- pos))
                                  (elneo-room--event-id-at pos)))))
      (setq pos (previous-single-property-change
                 pos 'elneo-room-event-id nil (point-min))))
    id))

(defun elneo-room--maybe-mark-read (&optional window)
  "Record the read position, and send it once debounced.
With `elneo-room-read-style' set to `cursor' the read position is
the newest event the cursor has moved past; when WINDOW shows the
buffer's end, the newest event overall, so messages scrolled past
count as read too.  \"Newest event\" includes reactions, votes and
edits (`elneo-room--advance-read-marker' advances
`elneo-room--last-event-id' for them): the server counts unread
on every event, not only on rendered messages."
  (when (and elneo-room--backfilled
             (not elneo-room--thread-root)
             (eq elneo-room-read-style 'cursor)
             elneo-room--last-event-id)
    (let ((event-id
           (if (and window (elneo-room--window-at-end-p window))
               elneo-room--last-event-id
             (elneo-room--event-before-point))))
      (when (and event-id (not (equal event-id elneo-room--read-sent-id)))
        (setq elneo-room--read-pending-id event-id)
        (when elneo-room--read-timer
          (cancel-timer elneo-room--read-timer))
        (setq elneo-room--read-timer
              (run-with-idle-timer 1.0 nil #'elneo-room--send-read
                                   (current-buffer)))))))

(defun elneo-room--send-read (buffer)
  "Send BUFFER's pending read mark to the daemon."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq elneo-room--read-timer nil)
      ;; A thread view never marks the room read: a receipt under a
      ;; thread root would strand the room's timeline receipt behind
      ;; the room view's own idea of read.
      (unless elneo-room--thread-root
        (when elneo-room--read-pending-id
          (setq elneo-room--read-sent-id elneo-room--read-pending-id
                elneo-room--read-pending-id nil)
          (elneo-room-mark-read elneo-room--profile elneo-room--room-id
                                elneo-room--read-sent-id))))))

(defun elneo-room--advance-read-marker (profile room-id source-event-id)
  "Read-marker pass-over for events no message line ever carries.
Reactions, poll votes and edits stand after the newest rendered
message yet still count unread on the server (in an encrypted room
every event a foreign member sends matches `.m.rule.encrypted').
Let SOURCE-EVENT-ID advance this buffer's read position, and
follow with the debounced receipt right away when a window follows
the live end — otherwise the receipt strands behind the invisible
event, the badge sits at a stale count, and only the next regular
message clears it all at once."
  (let ((buffer (elneo-room--buffer-for profile room-id)))
    (when (and (stringp source-event-id) (buffer-live-p buffer))
      (with-current-buffer buffer
        ;; Bookkeeping regardless: even with no window the next
        ;; at-end cursor pass must not strand behind the new event.
        (setq elneo-room--last-event-id source-event-id))
      (let ((window (get-buffer-window buffer t)))
        (when (and (window-live-p window)
                   (with-current-buffer buffer
                     (elneo-room--window-at-end-p window)))
          (with-current-buffer buffer
            (elneo-room--maybe-mark-read window)))))))

(defun elneo-room-mark-buffer-read (&optional arg)
  "Mark this room read now, whatever `elneo-room-read-style' says.
Up to the cursor's position, or with ARG the newest event."
  (interactive "P")
  (elneo-room-mark-read-now
   (if arg elneo-room--last-event-id (elneo-room--event-before-point))))

(defun elneo-room-mark-read-now (event-id)
  "Mark this room read up to EVENT-ID, bypassing the debounce."
  (when event-id
    (when elneo-room--read-timer
      (cancel-timer elneo-room--read-timer)
      (setq elneo-room--read-timer nil))
    (setq elneo-room--read-pending-id nil
          elneo-room--read-sent-id event-id)
    (elneo-room-mark-read elneo-room--profile elneo-room--room-id event-id)))

;;; Pagination

(defun elneo-room--maybe-load-older ()
  "Load the next older page when the view reaches the top of the buffer.
Covers point at `point-min' (M-<) and `window-start' at `point-min'
(mouse wheel up, which never moves point)."
  (when (and elneo-room--backfilled
             elneo-room--end-token
             (not elneo-room--loading-older))
    (let ((window (selected-window)))
      (cond
       ((= (point) (point-min))
        (elneo-room--load-older 'scroll))
       ((= (window-start window) (point-min))
        (elneo-room--load-older 'anchor))))))

(defun elneo-room--post-command ()
  "Post-command maintenance: placeholder, pages, media, read marks."
  (elneo-room--maybe-autocomplete-mention)
  (elneo-room--update-draft-placeholder)
  (elneo-room--draft-maybe-save)
  (elneo-room--maybe-load-older)
  (elneo-room--maybe-mark-read (selected-window))
  (elneo-room--fetch-media-in-window (selected-window)))

(defun elneo-room--load-older (mode &optional no-rate-limit)
  "Request one older history page, to land with MODE's view semantics.
NO-RATE-LIMIT skips the throttle — the reply-jump driver uses that;
it is bounded by its page counter instead."
  (cond
   ((not elneo-room--end-token)
    (message "No older history available"))
   (elneo-room--loading-older)
   ;; Rate-limit (also throttles the post-command-hook auto-load, so
   ;; sitting at the top does not fetch the whole history in one burst).
   ((and (not no-rate-limit)
         elneo-room--older-last
         (< (float-time (time-since elneo-room--older-last)) 1.0)))
   (t
    (setq elneo-room--loading-older t
          elneo-room--older-last (current-time)
          elneo-room--older-mode mode)
    (if elneo-room--thread-root
        ;; A thread buffer pages up through its m.thread relation
        ;; pages; the callback lives in elneo-thread (lazy require —
        ;; it derives from this file's mode).
        (progn (require 'elneo-thread)
               (elneo-thread--load-older))
      (let ((buf (current-buffer)))
        (elneo-room-messages elneo-room--profile elneo-room--room-id 50
                             elneo-room--end-token
                             (elneo-room--history-callback buf)))))))

(defun elneo-room-older ()
  "Load one older page of history, scrolling the view up into it."
  (interactive)
  (elneo-room--load-older 'scroll))

;;; Room keys

(defun elneo-room--refetch-debounced (buffer refill)
  "Arm BUFFER's keys-refetch debounce timer to run REFILL once.
Armed only when BUFFER is live, already backfilled, and not
already waiting on a previous keys burst.  The idle callback
clears the pending flags before calling REFILL, so the next keys
burst can arm again.  Returns the timer when a new one was armed,
nil otherwise."
  (when (and (buffer-live-p buffer)
             (buffer-local-value 'elneo-room--backfilled buffer)
             (null (buffer-local-value 'elneo-room--keys-timer buffer)))
    (with-current-buffer buffer
      (setq elneo-room--keys-timer
            (run-with-idle-timer 1.0 nil
                                 (lambda (buf)
                                   (when (buffer-live-p buf)
                                     (with-current-buffer buf
                                       (setq elneo-room--keys-timer nil
                                             elneo-room--backfilled nil)
                                       (funcall refill))))
                                 buffer)))))

(defun elneo-room--on-keys-updated (profile room-id)
  "Room keys for PROFILE's ROOM-ID arrived: re-render its open buffer.
Re-fetching the newest page replaces \"[unable to decrypt]\"
placeholders with the now-decryptable messages.  Debounced per
buffer so a burst of imports triggers one re-fetch.  Thread views
of the room join the debounce walk — their first page renders the
same placeholders.  Returns the last debounce timer armed, if any."
  ;; Thread views share the debounce shape but re-render their own
  ;; first page: the room's `--backfill' would render the room view
  ;; into the thread buffer.
  (require 'elneo-thread)
  (let ((armed (elneo-room--refetch-debounced
                (elneo-room--buffer-for profile room-id)
                (lambda () (elneo-room--backfill 50)))))
    (dolist (buffer (elneo-thread--buffers-for profile room-id))
      (setq armed (or (elneo-room--refetch-debounced
                       buffer
                       (lambda () (elneo-thread--fetch-first-page)))
                      armed)))
    armed))

;;; Media

(defun elneo-room--media-fetch-args (media)
  "Choose (SOURCE . FORMAT) to fetch for a message's media alist MEDIA."
  (let* ((thumb (alist-get 'thumb_source media))
         (source (alist-get 'source media)))
    (cond
     ;; Sender-provided plain thumbnail: cheap and small.
     ((and thumb (not (assq 'file thumb))) (cons thumb "thumb"))
     ;; Plain content: ask the homeserver for a downscaled thumbnail.
     ((and source (not (assq 'file source))) (cons source "thumb"))
     ;; Encrypted thumbnail: fetch it; the daemon decrypts.  Smaller than
     ;; the full image.
     ((and thumb (assq 'file thumb)) (cons thumb "file"))
     ;; Encrypted content without a thumbnail: fetch the whole file.
     (t (cons source "file")))))

(defun elneo-room--fetch-media-in-window (&optional window)
  "Fetch thumbnails for image placeholders near WINDOW's visible area.
With WINDOW nil (buffer not displayed), fetch all pending ones.
The `post-command-hook' re-runs this as the view moves, so images
materialize when they scroll into view."
  (when (hash-table-p elneo-room--media-pending)
    (let* ((window (or window (get-buffer-window (current-buffer) t)))
           (start (if window (window-start window) (point-min)))
           (stop (if window (window-end window) (point-max)))
           (span (max (- stop start) 1))
           (lo (max (point-min) (- start span)))
           (hi (min (point-max) (+ stop span))))
      (elneo-room--fetch-media-range lo hi))))

(defun elneo-room-retry-media (&optional all)
  "Re-attempt the media placeholders in view; with ALL, in the whole buffer.
A placeholder whose fetch response was lost (daemon restart, a
command that failed mid-session) stays in the pending table and no
scroll pass ever retries it.  This clears the table first and re-runs
the scan: anything already in the on-disk cache comes back
immediately, in-flight downloads are simply joined server-side."
  (interactive "P")
  (when (hash-table-p elneo-room--media-pending)
    (clrhash elneo-room--media-pending))
  (if all
      (elneo-room--fetch-media-range (point-min) (elneo-room--input-beg-pos))
    (elneo-room--fetch-media-in-window)))

(defun elneo-room--fetch-media-range (lo hi)
  "Fetch thumbnails for image placeholders between LO and HI.
Thumbnails go through the daemon's download manager: they land in
the on-disk media cache (media/thumb/ for plain, media/file/ for
encrypted thumbs fetched as files) and the buffer is filled from
the file — so images survive daemon restarts and are browsable
with `elneo-media-cache-dired'.  No FILENAME is passed for
thumbs: the homeserver generates the actual format, and an
extensionless cache file makes image.el detect the type from the
file's magic bytes."
  (let ((pos lo))
    ;; The end bounds are re-read from the live buffer each pass: a
    ;; callback that runs synchronously (a stubbed daemon in tests, a
    ;; future cache-answered fetch) replaces placeholders DURING the
    ;; walk, and stale positions would run off the shrunk buffer.
    (while (and pos (< pos hi) (<= pos (point-max)))
      (if (get-text-property pos 'elneo-room-media-thumb)
          (let* ((event-id (get-text-property pos 'elneo-room-event-id))
                 (media (get-text-property pos 'elneo-room-media-data))
                 (end (next-single-property-change
                       pos 'elneo-room-media-thumb nil (point-max))))
            (setq pos (min (or end hi) hi))
            (when (and event-id media (not (gethash event-id elneo-room--media-pending)))
              (let ((buffer (current-buffer))
                    (args (elneo-room--media-fetch-args media)))
                ;; The pending mark goes on only after the call succeeds:
                ;; marking before would wedge the placeholder forever if
                ;; the call itself errors (an unbuilt command, a dead
                ;; process), since no scroll pass would ever retry it.
                ;; Nothing can race the mark: the callback only runs from
                ;; the process filter, never reentrantly here.
                (elneo-download-media
                 elneo-room--profile (car args) (cdr args)
                 (lambda (_profile event)
                   (elneo-room--on-media buffer event-id event)))
                (puthash event-id t elneo-room--media-pending))))
        (setq pos (next-single-property-change
                   pos 'elneo-room-media-thumb nil hi))))))

(defun elneo-room--find-event (id)
  "Position of the first text run whose `elneo-room-event-id' equals ID.
Unlike `text-property-any' this compares with `equal', which is
what string event ids need."
  (save-excursion
    (goto-char (point-min))
    (catch 'found
      (when (equal (get-text-property (point) 'elneo-room-event-id) id)
        (throw 'found (point)))
      (let ((limit (point-max)) pos)
        (while (< (point) limit)
          (setq pos (next-single-property-change
                     (point) 'elneo-room-event-id nil limit))
          (when (>= pos limit)
            (throw 'found nil))
          (when (equal (get-text-property pos 'elneo-room-event-id) id)
            (throw 'found pos))
          (goto-char pos))
        nil))))

(defun elneo-room--on-media (buffer event-id event)
  "Replace the placeholder for EVENT-ID in BUFFER with fetched media."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (hash-table-p elneo-room--media-pending)
        (remhash event-id elneo-room--media-pending))
      (let* ((run-beg (elneo-room--find-event event-id))
             (run-end (and run-beg
                           (next-single-property-change
                            run-beg 'elneo-room-event-id nil (point-max))))
             ;; Only an unfetched placeholder is replaceable: put-image
             ;; keeps `elneo-room-media' on displayed images but drops
             ;; `elneo-room-media-thumb', so keying on the thumb
             ;; property skips them — and a message with several
             ;; embedded images loads them one fetch at a time.
             (beg (and run-beg
                       (text-property-any
                        run-beg (or run-end (point-max))
                        'elneo-room-media-thumb t)))
             (end (and beg
                       (next-single-property-change
                        beg 'elneo-room-media-thumb nil (point-max)))))
        (when beg
          (if (and (alist-get '@ok event nil nil #'equal)
                   (alist-get 'path event))
              (condition-case err
                  (elneo-room--put-image
                   beg end (alist-get 'path event) event-id)
                (error (message "Matrix image render failed: %s" (cdr err))))
            (let ((inhibit-read-only t)
                  ;; Read before the delete: the char at BEG after it is
                  ;; the following text, not the placeholder.
                  (video (elneo-room--video-media-p
                          (get-text-property beg 'elneo-room-media-data))))
              (save-excursion
                (goto-char beg)
                (delete-region beg end)
                ;; A video's failed thumb still reads as one.
                (insert (propertize
                         (if video "[video unavailable]" "[image unavailable]")
                         'face 'shadow 'read-only t))))))))))

(defun elneo-room--put-image (beg end file event-id)
  "Replace BEG..END with the image stored at FILE.
The alt text keeps EVENT-ID so the region stays findable, and the
media properties of the replaced placeholder — otherwise `o' and
RET on a displayed image lose track of the source and can no
longer open the full file.  `elneo-room-media-thumb' is
deliberately not kept: the inline-thumbnail scanner keys on it and
would re-fetch every image on each scroll pass.  A video's
thumbnail gains the ▶ mark before the image (and a \"[video]\"
alt, shown where images cannot render) — the user must still see
it is a playable video, not an ordinary picture."
  (let ((inhibit-read-only t)
        (media (get-text-property beg 'elneo-room-media-data))
        (name (get-text-property beg 'elneo-room-media-name))
        (video (elneo-room--video-media-p
                (get-text-property beg 'elneo-room-media-data)))
        ;; FILE has no reliable extension (thumbs are cached
        ;; extensionless), so let image.el sniff the type from content.
        (img (create-image file nil nil :ascent 100
                           :max-width 320 :max-height 240)))
    (save-excursion
      (delete-region beg end)
      (goto-char beg)
      (when video
        (insert (propertize "▶ " 'face 'elneo-room-video-play
                            'read-only t)))
      (insert-image img (propertize (if video "[video]" "[image]")
                                    'elneo-room-event-id event-id
                                    'elneo-room-media (when media t)
                                    'elneo-room-media-data media
                                    'elneo-room-media-name name
                                    'read-only t))
      (insert " "))))

;;; Downloaded files

(defun elneo-room--media-name (media)
  "Original file name of a media alist MEDIA, when the sender set one."
  (alist-get 'filename media))

(defun elneo-room--media-size-tag (media)
  "Human-readable \" (size, duration)\" suffix for MEDIA, or \"\"."
  (let* ((size (alist-get 'size media))
         (duration (alist-get 'duration media))
         (parts (append
                 (when size (list (elneo-room--size-string size)))
                 (when duration (list (elneo-room--duration-string duration))))))
    (if parts (format " (%s)" (string-join parts ", ")) "")))

(defun elneo-room--size-string (bytes)
  "BYTES as a human-readable size."
  (cond
   ((>= bytes 1073741824) (format "%.1f GiB" (/ bytes 1073741824.0)))
   ((>= bytes 1048576) (format "%.1f MiB" (/ bytes 1048576.0)))
   ((>= bytes 1024) (format "%.1f KiB" (/ bytes 1024.0)))
   (t (format "%d B" bytes))))

(defun elneo-room--duration-string (ms)
  "MS (milliseconds) as M:SS."
  (let ((secs (/ ms 1000)))
    (format "%d:%02d" (/ secs 60) (% secs 60))))

(defun elneo-room--media-at-point ()
  "Cons (POSITION . MEDIA-ALIST) for the media at point, or nil.
Point one char past the media entry still reads as \"on it\" to a
human, so that position counts too."
  (let ((pos (or (and (get-text-property (point) 'elneo-room-media-data)
                      (point))
                 (and (> (point) (point-min))
                      (get-text-property (1- (point)) 'elneo-room-media-data)
                      (1- (point))))))
    (when pos
      (cons pos (get-text-property pos 'elneo-room-media-data)))))

(defun elneo-room-forward (room)
  "Forward the message at point into ROOM (any account's room).
Text forwards as an honest new send: edits are already folded
away, so the buffer's version is what goes, and the formatted
body rides along when the sender had one.  Replies, reactions and
thread context stay behind — they are this room's story, and
Matrix carries no forwarded-from marker to preserve.  Media
re-sends through sendFile: the file lands in the daemon cache
first when needed, then a staged copy under its original name (a
nameless image goes out as \"forwarded\"), and the command carries
the source's mimetype and info, so the recipient's msgtype and
layout data match the original event knew.
Voice arrives as plain audio, since the waveform is a send-time
addition.  Pick ROOM with
`elneo-completing-read-room'; with
`elneo-room-forward-cross-account' nil the pick is limited to
this buffer's account, otherwise it covers every account — a
cross-account pick means the forward goes out from that account."
  (interactive
   (list (if elneo-room-forward-cross-account
             (elneo-completing-read-room)
           (elneo-completing-read-room elneo-room--profile))))
  (let* ((id (elneo-room--event-id-at (point)))
         (msg (and id (gethash id elneo-room--seen))))
    (if (null msg)
        (user-error "No message at point")
      (if (not (plist-get msg :media))
          (let ((tprofile (plist-get room :profile))
                (troom-id (plist-get room :room-id)))
            (elneo-send-message
             tprofile troom-id (plist-get msg :body)
             (lambda (_profile event)
               (if (alist-get '@ok event nil nil #'equal)
                   (message "Matrix: forwarded")
                 (message "Matrix: forward failed — %s"
                          (elneo-server--error-string event))))
             (plist-get msg :formatted-body)))
        (let* ((media (plist-get msg :media))
               (name (or (alist-get 'filename media) "forwarded"))
               (buffer (current-buffer)))
          (message "Matrix: downloading %s for forward..." name)
          (elneo-download-media
           elneo-room--profile (alist-get 'source media) "file"
           (lambda (_profile event)
             (elneo-room--on-forward-file buffer room media event))
           name))))))

;; The forward re-sends the source event's content type and info:
;; without them a nameless image (image events carry no filename
;; field) staged with a bare "forwarded" name and sendFile's mime
;; guess resulted in forwarded images with wrong mimetype - no
;; preview, and pretty much only emacs was able to open them
(defun elneo-room--forward-params (media)
  "The sendFile `mime'/`info' values for forwarded media.
The source event's mimetype and info (width/height in pixels,
duration in ms, size in bytes) already ride the media alist —
the forward keeps them instead of guessing the mime by name and
leaving every other client without the original's layout data."
  (list (alist-get 'mimetype media)
        (delq nil (mapcar (lambda (key)
                            (when (alist-get key media)
                              (cons key (alist-get key media))))
                          '(width height duration size)))))

(defun elneo-room--on-forward-file (buffer room media event)
  "Send the downloaded EVENT file into ROOM, metadata from MEDIA.
BUFFER only guards the forward message against a dead room
buffer; the send does not depend on it."
  (when (and (buffer-live-p buffer)
             (alist-get '@ok event nil nil #'equal)
             (alist-get 'path event))
    (let* ((path (alist-get 'path event))
           (name (or (alist-get 'filename media) "forwarded"))
           (params (elneo-room--forward-params media))
           (tprofile (plist-get room :profile))
           (troom-id (plist-get room :room-id))
           (dir (make-temp-file "elneo-forward-" t))
           ;; The cache file is extensionless; the staged copy keeps
           ;; the original name, which the daemon uses as the
           ;; event's body.
           (tmp (expand-file-name name dir)))
      (copy-file path tmp t)
      (elneo-room-file
       tprofile troom-id tmp
       (lambda (_profile event)
         (unwind-protect
             (if (alist-get '@ok event nil nil #'equal)
                 (message "Matrix: forwarded")
               (message "Matrix: forward failed — %s"
                        (elneo-server--error-string event)))
           ;; The staged copy's work is done once the daemon has it.
           (delete-directory dir t)))
       nil nil (car params) (cadr params)))))

;; `f` shares the room's keymap with the draft, so it must self-insert
;; in the draft area like every other bare key (the direct bind broke
;; typing f there).
(elneo-room--defkey elneo-room--f ?f
  "Forward the message at point into a picked room."
  (call-interactively #'elneo-room-forward))

(defun elneo-room--voice-bars (wave n)
  "Downsample WAVE amplitudes (0..=1024) to N bar heights, floats 0..=1.
Each bar is its chunk's maximum, telega-style.  An empty wave (a
voice marker without data) yields nil."
  (let* ((len (length wave)))
    (when (> len 0)
      (let* ((vec (vconcat wave))
             (step (/ (float len) n))
             (out (make-vector n 0)))
        (dotimes (j len)
          (let ((i (min (1- n) (floor (/ j step)))))
            (when (> (aref vec j) (aref out i))
              (aset out i (aref vec j)))))
        (mapcar (lambda (a) (/ a 1024.0)) out)))))

(defun elneo-room--face-hex (face)
  "Foreground of FACE as #rrggbb, resolved through inheritance.
A neutral grey when the face has no resolvable color (batch, bare
frames)."
  (let* ((attr (face-attribute face :foreground nil t))
         (rgb (and (stringp attr) (color-name-to-rgb attr))))
    (if rgb
        (format "#%02x%02x%02x"
                (round (* 255 (nth 0 rgb)))
                (round (* 255 (nth 1 rgb)))
                (round (* 255 (nth 2 rgb))))
      "#707070")))

(defun elneo-room--voice-wave-svg (bars played-p)
  "SVG string for BARS (heights 0..=1), played or not (PLAYED-P)."
  (let* ((bar-w 3) (gap 1) (height 20)
         (width (* (length bars) (+ bar-w gap)))
         (color (elneo-room--face-hex
                 (if played-p
                     'elneo-room-voice-wave-played
                   'elneo-room-voice-wave))))
    (concat
     (format
      "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\">"
      width height)
     (cl-loop for a in bars
              for i from 0
              for h = (max 2 (round (* a height)))
              concat (format "<rect x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\" fill=\"%s\"/>"
                             (* i (+ bar-w gap)) (- height h) bar-w h color))
     "</svg>")))

(defun elneo-room--voice-wave-text (bars)
  "BARS (heights 0..=1) as bar characters, for terminal display."
  (let ((chars "▁▂▃▄▅▆▇█"))
    (cl-loop for a in bars
             for i = (min 7 (floor (* a 8)))
             concat (substring chars i (1+ i)))))

(defun elneo-room--insert-voice (msg)
  "Insert the voice note MSG: waveform bars plus duration.
Graphical displays render an SVG bar image (telega-style); terminals
get bar characters.  A note played this session re-renders in the
played face.  RET on it plays — see
`elneo-room-play-voice-at-point'."
  (let* ((media (plist-get msg :media))
         (event-id (plist-get msg :event-id))
         (wave (alist-get 'voice media))
         (duration (alist-get 'duration media))
         (played (gethash event-id elneo-voice--played))
         (bars (elneo-room--voice-bars wave 32))
         (props `(elneo-room-media t
                                   elneo-room-media-data ,media
                                   elneo-room-media-name "voice"
                                   elneo-room-event-id ,event-id
                                   elneo-room-voice t
                                   read-only t)))
    (cond
     ((and (display-graphic-p) (image-type-available-p 'svg) bars)
      (insert-image
       (create-image (elneo-room--voice-wave-svg bars played) 'svg t
                     :ascent 90)
       (apply #'propertize "[voice]" props)))
     (t
      ;; No image support, or a marker without waveform data: bars
      ;; when there is a wave to draw, the plain tag otherwise.
      (insert (apply #'propertize
                     (if bars
                         (concat "[voice] " (elneo-room--voice-wave-text bars))
                       "[voice]")
                     'face (if played
                               'elneo-room-voice-wave-played
                             'elneo-room-voice-wave)
                     props))))
    (when duration
      ;; The suffix carries the media data too, so point one past
      ;; the entry still reads as "on it" for the play/open keys.
      (insert (apply #'propertize
                     (format " (%s)" (elneo-room--duration-string duration))
                     'face 'shadow
                     'elneo-room-event-id event-id
                     'elneo-room-voice t
                     'elneo-room-media t
                     'elneo-room-media-data media
                     'elneo-room-media-name "voice"
                     nil)))))

(defun elneo-room--voice-at-point ()
  "Media alist when point is on a voice message, else nil.
Follows `elneo-room--media-at-point', one-past included."
  (let* ((hit (elneo-room--media-at-point))
         (media (cdr hit)))
    (when (and media (alist-get 'voice media))
      media)))

(defun elneo-room-play-voice-at-point ()
  "Play the voice message at point.
The file downloads through the daemon's media cache (cached files
start immediately), then plays via `elneo-voice-player-command'
(nil means `elneo-open-file-function').  The waveform recolors to
the played face."
  (interactive)
  (let* ((hit (elneo-room--media-at-point))
         (media (cdr hit)))
    (if (not (and media (alist-get 'voice media)))
        (user-error "No voice message at point")
      (let* ((pos (car hit))
             (event-id (get-text-property pos 'elneo-room-event-id))
             (buffer (current-buffer)))
        (message "Matrix: downloading voice note...")
        (elneo-download-media
         elneo-room--profile (alist-get 'source media) "file"
         (lambda (_profile event)
           (elneo-room--on-voice-file buffer event-id event))
         "voice")))))

(defun elneo-room--on-voice-file (buffer event-id event)
  "Play the `updateMediaFile' response EVENT for voice note EVENT-ID.
ROOM BUFFER's message block re-renders in the played face first, so
the recolor happens even when the player fails to start."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((path (alist-get 'path event)))
        (if (and (alist-get '@ok event nil nil #'equal) path)
            (progn
              (puthash event-id t elneo-voice--played)
              (let ((msg (gethash event-id elneo-room--seen)))
                (when msg
                  (elneo-room--replace-message event-id msg)))
              (let ((player elneo-voice-player-command))
                (if player
                    (apply #'start-process "elneo-voice" nil
                           (append (if (stringp player) (list player) player)
                                   (list path)))
                  (funcall elneo-open-file-function path))))
          (message "Matrix: could not download voice note: %s"
                   (elneo-server--error-string event)))))))

(defun elneo-room-open-media-at-point ()
  "Download and open the media message at point.
The file lands in the daemon's on-disk media cache (already-cached
files open immediately) and is handed to
`elneo-open-file-function'.  On an image placeholder this opens
the full-size image, not just the inline thumbnail."
  (interactive)
  (let* ((hit (elneo-room--media-at-point))
         (media (cdr hit)))
    (if (not media)
        (user-error "No media at point")
      (let* ((name (or (get-text-property (car hit) 'elneo-room-media-name)
                       "media"))
             (buffer (current-buffer)))
        (message "Matrix: downloading %s..." name)
        (elneo-download-media
         elneo-room--profile (alist-get 'source media) "file"
         (lambda (_profile event)
           (elneo-room--on-media-file buffer name event))
         name)))))

(defun elneo-room-save-media-at-point ()
  "Save the media message at point to a file (save-as).
The media downloads into the daemon's on-disk cache first
(already-cached files copy immediately), then copies to the
destination: `elneo-msg-save-dir' when set, else a prompted path
defaulting to the media's file name."
  (interactive)
  (let* ((hit (elneo-room--media-at-point))
         (media (cdr hit)))
    (if (not media)
        (user-error "No media at point")
      (let* ((name (or (get-text-property (car hit) 'elneo-room-media-name)
                       "media"))
             ;; The prompt can hand back a `~/'-abbrevation or a
             ;; relative name exactly as typed; the copy below must
             ;; see it expanded (the save-dir branch expands through
             ;; `expand-file-name's directory argument).
             (target (if elneo-msg-save-dir
                         (expand-file-name name elneo-msg-save-dir)
                       (expand-file-name
                        (read-file-name "Save media to: " nil nil nil name))))
             (buffer (current-buffer)))
        ;; Overwrite is a prompt-time decision, not a callback-time one:
        ;; a large download must not land a y-or-n-p minutes later.
        (when (and (file-exists-p target)
                   (not (y-or-n-p (format "Overwrite %s? " target))))
          (user-error "Not overwritten"))
        (message "Matrix: downloading %s..." name)
        (elneo-download-media
         elneo-room--profile (alist-get 'source media) "file"
         (lambda (_profile event)
           (elneo-room--on-media-saved buffer name target event))
         name)))))

(defun elneo-room--on-media-saved (buffer name target event)
  "Copy the `updateMediaFile' response EVENT's file to TARGET.
NAME is the media's display name for the report in room BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((path (alist-get 'path event)))
        (if (and (alist-get '@ok event nil nil #'equal) path)
            (progn
              ;; Only possible when elneo-msg-save-dir was created
              ;; behind our back since the prompt-less path was chosen.
              (make-directory (file-name-directory target) t)
              (copy-file path target t)
              (message "Matrix: saved %s to %s" name target))
          (message "Matrix: could not download %s: %s"
                   name (elneo-server--error-string event)))))))

(defun elneo-room--on-media-file (buffer name event)
  "Open the `updateMediaFile' response EVENT for NAME in room BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((path (alist-get 'path event)))
        (if (and (alist-get '@ok event nil nil #'equal) path)
            (progn
              (message "Matrix: opening %s" name)
              (funcall elneo-open-file-function path))
          (message "Matrix: could not download %s: %s"
                   name (elneo-server--error-string event)))))))

(defun elneo-room--on-download-update (dl)
  "Echo daemon download state changes, so long downloads stay visible.
The download itself opens the file from its terminal response; this
only tracks the daemon's `updateDownload' lifecycle events.
Thumbnail downloads (inline images) are silent: they are numerous,
short-lived, and failures surface as `[image unavailable]' on the
placeholder itself."
  (unless (string= (plist-get dl :format) "thumb")
    (pcase (plist-get dl :state)
      ("downloading"
       (message "Matrix: downloading media..."))
      ("error"
       (message "Matrix: download failed: %s"
                (or (plist-get dl :error) "unknown error"))))))

;;; Sending

(defun elneo-room-send (&optional body)
  "Send a message to this room, prompting in the minibuffer.
For inline input use the draft area at the end of the buffer.
In reply mode the prompt send carries the pending reply."
  (interactive)
  (let ((body (or body (read-string "Message: "))))
    (when (> (length body) 0)
      (elneo-room--send-text body))))

(defun elneo-room-attach (path)
  "Insert an [image: PATH] or [file: PATH] tag for PATH into the draft area.
Images get the [image: ...] tag; everything else [file: ...]."
  (interactive (list (read-file-name "File to send: " nil nil t)))
  (if (and elneo-room--backfilled
           (>= (point) (elneo-room--input-beg-pos)))
      (elneo-room--insert-attach-tag path)
    ;; Point in history or before the first page: silently doing
    ;; nothing made C-c C-i look broken.  Point must sit in the draft
    ;; (the tag lands at the end of it), and the room must be rendered.
    (user-error "Move point to the draft area to attach a file")))

(defun elneo-room--insert-attach-tag (path)
  "Insert the attach tag for PATH at the end of the draft.
No point guard: the tag always lands after whatever the draft
holds, so it is safe with point anywhere in the buffer."
  (goto-char (point-max))
  (when (> (length (string-trim (elneo-room--draft-text))) 0)
    (insert " "))
  (insert (format "[%s: %s]"
                  (if (elneo-room--image-file-p path) "image" "file")
                  (expand-file-name path))))

;; `dnd-handle-multiple-urls' passes a handler that has this property
;; every matched URL in one call (the Emacs 30 dnd contract — see the
;; `dnd-protocol-alist' setup in the room mode for the per-shape
;; matcher reasoning; on older elisp dnd calls it one URL per call
;; instead, which is why 30 is the documented baseline).
(put 'elneo-room-dnd-receive 'dnd-multiple-handler t)

(defun elneo-room-dnd-receive (urls _action)
  "Handle file URLs dragged into the room buffer: attach, don't send.
One call for all dropped URLs (`dnd-multiple-handler').  Each URL
is decoded through `dnd-get-local-file-name', which takes both the
`file:///path' and bare-`file:/path' shapes; `file://localhost/path'
is rewritten to the former first, else the decode branch yields the
nonsense path `//localhost/path'.  The decoded path must exist and
not be a directory; otherwise the URL is skipped with a message.
Tags — the same [image:]/[file:] forms `elneo-room-attach'
writes — are inserted at the end of the draft; nothing goes out
until RET.  Returns `private' whenever file URLs arrived, even
when none attached: a nil would make dnd.el's backend insert the
raw URL strings into the buffer as text (its unhandled-URL
fallback), which is exactly how a dropped attachment ends up sent
as a `file:/...' text message.  Drops while the room is not
rendered yet are refused with a message."
  (if (not elneo-room--backfilled)
      (progn
        (message "Matrix: room not rendered yet — drop again once it is")
        'private)                              ; swallow the urls either way
    (let ((paths nil))
      (dolist (url urls)
        (let* ((url (replace-regexp-in-string
                     "\\`file://localhost/" "file:///" url))
               (path (ignore-errors
                       (dnd-get-local-file-name url 'must-exist))))
          (cond
           ((null path)
            (message "Matrix: dropping %s: not a local file" url))
           ((file-directory-p path)
            (message "Matrix: not attaching directory %s" path))
           (t (push path paths)))))
      (let ((paths (nreverse paths)))                ; drops accumulate last-first
        (when paths
          (dolist (path paths)
            (elneo-room--insert-attach-tag path)))
        ;; Consumed the urls either way: never let dnd.el type the raw
        ;; file URLs into the buffer.
        'private))))

(defun elneo-room-attach-dired (&optional dir)
  "Open a dired buffer to pick files to attach to this room.
Mark files in it (\\[dired-mark]) and press
\\[elneo-dired--attach-marked] there: their tags land in this
room's draft — the same [image:]/[file:] tags `elneo-room-attach'
writes — and the window switches back to the room.  The dired
buffer keeps its binding until killed, so you can attach from it
more than once."
  (interactive (list (read-directory-name "Pick files in: " nil nil t)))
  (unless elneo-room--backfilled
    (user-error "The room is not rendered yet"))
  ;; Lazy require: elneo-dired requires this file right back, so a
  ;; top-level require would be a cycle; the picker is optional.
  (require 'elneo-dired)
  (elneo-dired-pick-for-buffer (current-buffer) dir))

;; The image-by-extension classifier moved to elneo-client for the
;; image scaler, which runs at the upload choke point on the client
;; layer (this file requires elneo-client, never the other way); the
;; old name stays as the same function.
(defalias 'elneo-room--image-file-p #'elneo--image-file-p)

;;; Hook wiring

(add-hook 'elneo-new-message-hook #'elneo-room--on-new-message)
(add-hook 'elneo-reactions-update-hook #'elneo-room--on-reactions-update)
(add-hook 'elneo-poll-update-hook #'elneo-room--on-poll-update)
(add-hook 'elneo-read-receipts-update-hook #'elneo-room--on-read-receipts)
(add-hook 'elneo-edited-update-hook #'elneo-room--on-edited)
(add-hook 'elneo-redaction-update-hook #'elneo-room--on-redaction)
(add-hook 'elneo-room-keys-updated-hook #'elneo-room--on-keys-updated)
(add-hook 'elneo-download-update-hook #'elneo-room--on-download-update)
(add-hook 'elneo-room-update-hook #'elneo-room--on-pinned-update)

(provide 'elneo-room)
;;; elneo-room.el ends here
