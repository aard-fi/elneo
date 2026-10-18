;;; sync-state-test.el --- daemon connectivity (feature A) -*- lexical-binding: t; -*-

;; elneo-server.el owns the state: `elneo-server--record-sync-state'
;; stores each daemon's last (STATE . ERROR), dedupes repeat reports,
;; and fires `elneo-session-sync-hook' only on transitions; the
;; daemonInfo greeting records "starting"; the sentinel records
;; "offline" while pruning every other per-profile alist.  The
;; client side then drives the auto-restart scheduler from the hook:
;; backoff doubling 5/10/20/30 capped at the max, no timer stacking,
;; suppression by setting / unactivated profile / deliberate stop /
;; give-up cap, a tick that checks liveness first and survives a
;; broken `elneo-server-command'.  The bar renders the daemon
;; status row (● synced / ◐ connecting / ✗ down, offline face), the
;; mode line appends ⚠N, and the room send gate refuses to send
;; while "offline"/"error", draft intact.  All batch, no real
;; processes.
;;
;; Harness note: observers and stubs push through GLOBAL holders —
;; several add-hook closures capturing same-named lexical let vars in
;; one compiled file write a cell the outer let can not see; using
;; named functions + globals sidesteps that entirely.
;;
;; Run: emacs -Q --batch -L lisp -l test/sync-state-test.el

(require 'cl-lib)
(require 'elneo-client)
(require 'elneo-room-bar)
(require 'elneo-room)

(defvar mx-pass 0)
(defvar mx-fail 0)
(defvar mx-fires nil
  "Sync-hook observer log: one (PROFILE STATE ERROR) per hook fire.")

(defun mx-check (label got expected)
  (if (equal got expected)
      (progn (setq mx-pass (1+ mx-pass)) (message "ok: %s" label))
    (setq mx-fail (1+ mx-fail))
    (message "FAIL: %s — got %S, expected %S" label got expected)))

(defun mx-record-fire (profile state error)
  "Observer for `elneo-session-sync-hook' in this suite."
  (push (list profile state error) mx-fires))
(add-hook 'elneo-session-sync-hook #'mx-record-fire)
;; and the production observer back on, for the scheduler drives below
(add-hook 'elneo-session-sync-hook #'elneo-client--on-session-sync-state)

(defun mx-sync-hook-reset ()
  (setq elneo-session-sync-hook nil)
  (add-hook 'elneo-session-sync-hook #'mx-record-fire))

(defun mx-clean-restarts ()
  (dolist (entry elneo-server--restarts)
    (elneo-client--reset-restart-state (car entry)))
  (setq elneo-server--restarts nil))

;; --- recorder: dispatch, dedupe, transitions ---

(setq elneo-session-sync-hook nil
      elneo-server--sync-states nil
      elneo-server--manual-stops nil
      elneo-server--restarts nil
      elneo-server--buffers nil
      elneo-server--callbacks nil
      mx-fires nil)
(add-hook 'elneo-session-sync-hook #'mx-record-fire)
(elneo-server--dispatch-event
 "t" '((@type . "updateSyncState") (state . "syncing") (error . nil)))
(mx-check "dispatcher recorded syncing"
          (elneo-server-sync-state "t") '("syncing" . nil))
(elneo-server--dispatch-event
 "t" '((@type . "updateSyncState") (state . "syncing") (error . nil)))
(mx-check "repeat report deduped (hook silent)"
          mx-fires '(("t" "syncing" nil)))
(elneo-server--dispatch-event
 "t" '((@type . "updateSyncState") (state . "synced") (error . nil)))
(mx-check "transition to synced fires the hook"
          mx-fires '(("t" "synced" nil) ("t" "syncing" nil)))
;; An event without a usable state is ignored entirely.
(setq mx-fires nil)
(elneo-server--dispatch-event "t" '((@type . "updateSyncState")))
(mx-check "missing state ignored" mx-fires nil)
(mx-check "missing state left the record"
          (car (elneo-server-sync-state "t")) "synced")

;; --- the sentinel records offline exactly once, prunes the rest ---

(mx-sync-hook-reset)
(setq mx-fires nil)
(let ((fake (get-buffer-create " *sync-t1*")))
  (setq elneo-server--buffers    (list (cons "t" fake))
        elneo-server--sessions   (list (cons "t" '(:user-id "@x")))
        elneo-server--pending    (list (cons "t" (make-hash-table)))
        elneo-server--trust      (list (cons "t" '(t . nil)))
        elneo-server--daemon-info(list (cons "t" '(:protocol 1)))
        elneo-server--sync-states(list (cons "t" '("synced" . nil))))
  (cl-letf (((symbol-function 'process-live-p) (lambda (_proc) nil)))
    (elneo-server--sentinel "t" 'fake-proc
                             "exited abnormally with code 137\n"))
  (kill-buffer fake)
  (mx-check "sentinel: other per-profile alists pruned"
            (list elneo-server--buffers elneo-server--sessions
                  elneo-server--pending elneo-server--trust
                  elneo-server--daemon-info)
            '(nil nil nil nil nil))
  (mx-check "sentinel: offline + exit status recorded"
            (elneo-server-sync-state "t")
            '("offline" . "exited abnormally with code 137"))
  (mx-check "sentinel: hook fired the death transition"
            mx-fires '(("t" "offline" "exited abnormally with code 137"))))

;; --- the sentinel fails the profile's in-flight requests ---
;;
;; Dropped callbacks stranding their views is what made room buffers
;; stay empty after a daemon death: the flush delivers every waited
;; response as the wire's failure shape instead.

(let ((got nil))
  (setq elneo-server--pending
        (list (cons "t" (let ((table (make-hash-table :test 'eql)))
                          (puthash 7 (lambda (_p event)
                                       (push event got))
                                     table)
                          table))))
  (cl-letf (((symbol-function 'process-live-p) (lambda (_proc) nil)))
    (elneo-server--sentinel "t" 'fake-proc "exited abnormally with code 137\n"))
  (mx-check "sentinel: a dropped request's callback hears about it"
            (list (length got)
                  (alist-get '@error (car got))
                  (alist-get '@ok (car got) nil nil #'equal))
            '(1 "exited abnormally with code 137" nil))
  (mx-check "sentinel: flushed pending leaves no table"
            (assoc "t" elneo-server--pending)
            nil)
  (setq got nil))

;; --- daemonInfo greeting records "starting" ---

(mx-sync-hook-reset)
(setq mx-fires nil elneo-server--sync-states nil
      elneo-server--callbacks nil)
(elneo-server--dispatch-event
 "t" '((@type . "daemonInfo") (protocol . 1) (release . "0.1.0")))
(mx-check "greeting: recorded starting"
          (elneo-server-sync-state "t") '("starting" . nil))
(mx-check "greeting: hook fired" mx-fires '(("t" "starting" nil)))

;; --- scheduler: backoff, stacking, resets, suppression ---

;; The recorder hooks are off now: `mx-schedule' drives the scheduler
;; directly, and the production observer is the only listener (it
;; reacts to "offline" we feed by hand; timers it arms are cleaned).
(mx-sync-hook-reset)
(setq mx-fires nil
      elneo-accounts (list (cons "p" (list :access-token "tok"))))

(defun mx-schedule (profile)
  "Run the scheduler for PROFILE with `run-at-time' capturing
delays; returns the captured delays."
  (let (captured)
    (cl-letf* ((real (symbol-function 'run-at-time))
               ((symbol-function 'run-at-time)
                (lambda (secs rep fn &rest args)
                  (push secs captured)
                  ;; a REAL timer: `--restart-timer-p' must see it armed
                  (apply real secs rep fn args))))
      (elneo-client--maybe-schedule-restart profile))
    (nreverse captured)))

;; Delay doubles from attempts 0..2 and stays capped at 30.
(mx-check "backoff: attempt 0 → 5s" (mx-schedule "p") '(5))
(mx-check "arming incremented attempts once"
          (plist-get (cdr (car elneo-server--restarts)) :attempts) 1)
(mx-clean-restarts)
(setcdr (elneo-client--restart-cell "p") (list :attempts 1 :timer nil))
(mx-check "backoff: attempt 1 → 10s" (mx-schedule "p") '(10))
(mx-clean-restarts)
(setcdr (elneo-client--restart-cell "p") (list :attempts 2 :timer nil))
(mx-check "backoff: attempt 2 → 20s" (mx-schedule "p") '(20))
(mx-clean-restarts)
(setcdr (elneo-client--restart-cell "p") (list :attempts 3 :timer nil))
(mx-check "backoff: attempt 3 → capped 30s" (mx-schedule "p") '(30))
(mx-clean-restarts)
(setcdr (elneo-client--restart-cell "p") (list :attempts 4 :timer nil))
(mx-check "backoff: attempt 4 still capped 30s" (mx-schedule "p") '(30))
(mx-clean-restarts)

;; No stacking: a second offline while armed does not add a timer.
(mx-schedule "p")
(progn
  (setq mx-timer-one (plist-get (cdr (car elneo-server--restarts)) :timer))
  (mx-schedule "p")
  (mx-check "second report did not re-arm"
            (plist-get (cdr (car elneo-server--restarts)) :timer)
            mx-timer-one)
  (mx-clean-restarts))

;; "synced" resets attempts and removes the entry, timer canceled.
(setcdr (elneo-client--restart-cell "p")
        (list :attempts 2 :timer (run-at-time 100 nil #'ignore)))
(setq mx-timer-two (plist-get (cdr (car elneo-server--restarts)) :timer))
(elneo-client--reset-restart-state "p")
(mx-check "synced reset removes the entry" elneo-server--restarts nil)
(mx-check "synced reset canceled the armed timer"
          (memq mx-timer-two timer-list) nil)
(mx-clean-restarts)
;; A mid-sync state keeps :attempts but drops any timer.
(setcdr (elneo-client--restart-cell "p")
        (list :attempts 2 :timer (run-at-time 100 nil #'ignore)))
(elneo-client--clear-restart-timer "p")
(mx-check "non-final state: attempts kept, timer dropped"
          (list (plist-get (cdr (car elneo-server--restarts)) :attempts)
                (plist-get (cdr (car elneo-server--restarts)) :timer))
          (list 2 nil))
(mx-clean-restarts)

;; Suppression paths: setting off, unactivated profile, deliberate
;; stop, give-up cap.
(let ((elneo-server-auto-restart nil))
  (mx-check "auto-restart off: nothing scheduled" (mx-schedule "p") nil)
  (mx-check "no entry created while off" elneo-server--restarts nil))
(mx-check "unactivated profile: nothing scheduled"
          (mx-schedule "never-seen") nil)
(mx-check "no entry for unactivated profile" elneo-server--restarts nil)
(setq elneo-server--manual-stops (list (cons "p" t)))
(mx-check "deliberate stop: nothing scheduled" (mx-schedule "p") nil)
(setq elneo-server--manual-stops nil)
(let ((elneo-server-auto-restart-max-attempts 2))
  (setcdr (elneo-client--restart-cell "p") (list :attempts 2 :timer nil))
  (mx-check "give-up cap reached: nothing scheduled" (mx-schedule "p") nil)
  (mx-check "give-up cap kept attempts, no timer"
            (list (plist-get (cdr (car elneo-server--restarts)) :attempts)
                  (plist-get (cdr (car elneo-server--restarts)) :timer))
            (list 2 nil))
  (mx-clean-restarts))

;; The tick: live daemon → no activate; dead → activate; broken
;; command → error caught by the tick itself (the caught message is
;; its only return), attempts survive for the next backoff.
(let (activated)
  (cl-letf (((symbol-function 'elneo-server-live-p) (lambda (_p) t))
            ((symbol-function 'elneo-client--activate)
             (lambda (_p) (push :activated activated))))
    (setcdr (elneo-client--restart-cell "p") (list :attempts 0 :timer nil))
    (elneo-client--restart-tick "p")
    (mx-check "tick: live daemon left alone" activated nil)
    (mx-clean-restarts)))
(let (activated)
  (cl-letf (((symbol-function 'elneo-server-live-p) (lambda (_p) nil))
            ((symbol-function 'elneo-client--activate)
             (lambda (_p) (push :activated activated))))
    (setcdr (elneo-client--restart-cell "p") (list :attempts 1 :timer nil))
    (elneo-client--restart-tick "p")
    (mx-check "tick: dead daemon activated" activated '(:activated))
    (mx-check "tick: fired timer cleared from the cell"
              (plist-get (cdr (car elneo-server--restarts)) :timer) nil)
    (mx-clean-restarts)))
(cl-letf (((symbol-function 'elneo-server-live-p) (lambda (_p) nil))
          ((symbol-function 'elneo-client--activate)
           (lambda (_p) (error "elneo-server-command not found"))))
  (setcdr (elneo-client--restart-cell "p") (list :attempts 2 :timer nil))
  (mx-check "tick: broken command caught, no crash"
            (let ((result (elneo-client--restart-tick "p")))
              (and (stringp result)
                   (string-prefix-p "Matrix [p] auto-restart failed" result) t))
            t)
  (mx-check "tick error keeps attempts for the next backoff"
            (plist-get (cdr (car elneo-server--restarts)) :attempts) 2)
  (mx-clean-restarts))
(setq elneo-accounts nil)

;; --- bar: daemon chips per state, manual stop hidden ---

(setq elneo-server--buffers (list (cons "t" (get-buffer-create " *sync-t2*"))))
(cl-letf (((symbol-function 'elneo-server-live-p) (lambda (_p) t)))
  (setq elneo-server--sync-states (list (cons "t" '("synced" . nil))))
  (let ((chip (car (elneo-room-bar--daemon-chips))))
    (mx-check "chip: live synced → ● with success face"
              (list (nth 1 chip) (nth 2 chip) (nth 3 chip))
              '("synced" "●" success))))
(cl-letf (((symbol-function 'elneo-server-live-p) (lambda (_p) t)))
  (setq elneo-server--sync-states (list (cons "t" '("error" . "boom"))))
  (let ((chip (car (elneo-room-bar--daemon-chips))))
    (mx-check "chip: live error → ✗ offline face"
              (list (nth 1 chip) (nth 2 chip) (nth 3 chip))
              '("error" "✗" elneo-room-bar-offline))))
(cl-letf (((symbol-function 'elneo-server-live-p) (lambda (_p) t)))
  (setq elneo-server--sync-states nil)
  (let ((chip (car (elneo-room-bar--daemon-chips))))
    (mx-check "chip: live without greeting → starting ◐"
              (list (nth 1 chip) (nth 2 chip))
              '("starting" "◐"))))
(setq elneo-server--sync-states (list (cons "t" '("offline" . "137"))))
(cl-letf (((symbol-function 'elneo-server-live-p) (lambda (_p) nil)))
  (let ((chip (car (elneo-room-bar--daemon-chips))))
    (mx-check "chip: dead daemon still shown"
              (list (nth 1 chip) (nth 2 chip) (nth 3 chip))
              '("offline" "✗" elneo-room-bar-offline)))
  (setq elneo-server--manual-stops (list (cons "t" t)))
  (mx-check "chip: deliberate stop hidden"
            (elneo-room-bar--daemon-chips) nil)
  (setq elneo-server--manual-stops nil)
  (setq elneo-server--sync-states (list (cons "t" '("synced" . nil))))
  (mx-check "chip: dead-but-synced never shown"
            (elneo-room-bar--daemon-chips) nil))
(setq elneo-server--buffers nil elneo-server--sync-states nil)

;; --- bar: the status row renders chips as buttons ---

(setq elneo-server--buffers (list (cons "t" (get-buffer-create " *sync-t3*")))
      elneo-server--sync-states (list (cons "t" '("offline" . "137"))))
(let (buttons restart-called)
  (cl-letf (((symbol-function 'elneo-server-live-p) (lambda (_p) nil))
            ((symbol-function 'elneo-rooms-all) (lambda () nil))
            ((symbol-function 'insert-text-button)
             (lambda (label &rest props)
               (push (cons label props) buttons)
               nil))
            ((symbol-function 'elneo-restart-server)
             (lambda (profile) (push profile restart-called))))
    (with-temp-buffer (elneo-room-bar--insert-controls))
    (let ((daemons (cl-remove-if-not
                    (lambda (btn) (string-match "[●◐✗]" (car btn)))
                    buttons)))
      (mx-check "status row: exactly one daemon chip"
                (length daemons) 1)
      (funcall (plist-get (cdr (car daemons)) 'action) nil)
      (mx-check "status row: chip action restarts the daemon"
                restart-called '("t"))))
  ;; the face render check, against the real renderer
  (cl-letf (((symbol-function 'elneo-rooms-all) (lambda () nil))
            ((symbol-function 'elneo-server-live-p) (lambda (_p) nil)))
    (with-temp-buffer
      (elneo-room-bar--insert-controls)
      (goto-char (point-min))
      (let ((found (search-forward "✗ t" nil t)))
        (mx-check "status row: dead chip rendered with its face"
                  (and found (get-text-property (match-beginning 0) 'face))
                  'elneo-room-bar-offline)))))
(setq elneo-server--buffers nil elneo-server--sync-states nil)

;; --- mode line: ⚠N while a daemon is down, segment stays visible ---

(let ((rooms-stub (lambda () nil)))
  (cl-letf (((symbol-function 'elneo-rooms-all) rooms-stub)
            ((symbol-function 'elneo-server-live-p) (lambda (_p) nil)))
    (setq elneo-mode-line-string nil
          elneo-server--buffers (list (cons "t" (get-buffer-create " *sync-t4*")))
          elneo-server--sync-states (list (cons "t" '("offline" . "137"))))
    (elneo-mode-line--update)
    (mx-check "mode line: only the down daemon, ⚠1 shown"
              elneo-mode-line-string
              (concat "MX[0/0]" "" (propertize " ⚠1" 'face 'error)))
    ;; The daemon being alive changes nothing while its sync state is
    ;; still "offline" (alive, homeserver unreachable) — that case is
    ;; exactly what A6's send gate covers.
    (cl-letf (((symbol-function 'elneo-server-live-p) (lambda (_p) t)))
      (elneo-mode-line--update)
      (mx-check "mode line: live but homeserver-unreachable still warns"
                elneo-mode-line-string
                (concat "MX[0/0]" "" (propertize " ⚠1" 'face 'error))))
    (setq elneo-server--buffers nil elneo-server--sync-states nil)
    (elneo-mode-line--update)
    (mx-check "mode line: healthy everything, no segment" elneo-mode-line-string nil)))

;; --- send gate: refuse while down, pass otherwise, draft intact ---

(let ((buf (generate-new-buffer " *sync-room*"))
      (sends 0)
      (gate elneo-room-block-send-when-offline))
  (unwind-protect
      (progn
        (with-current-buffer buf
          (elneo-room-mode)
          (setq-local elneo-room--profile "t")
          (setq-local elneo-room--room-id "!room")
          (setq elneo-room--backfilled t)
          (insert "header\n")
          (elneo-room--reset-input-area "draft text"))
        (cl-letf (((symbol-function 'elneo-server-sync-state)
                   (lambda (profile)
                     (when (equal profile "t") '("offline" . "exit"))))
                  ((symbol-function 'elneo-room--dispatch-input)
                   (lambda (_text &optional _) (setq sends (1+ sends)))))
          (with-current-buffer buf
            (mx-check "gate: offline sends refused"
                      (condition-case nil
                          (progn (elneo-room--input-send) 'no-error)
                        (user-error 'user-error) (error 'error))
                      'user-error)
            (mx-check "gate: draft kept on refusal"
                      (elneo-room--draft-text) "draft text")
            (mx-check "gate: nothing dispatched while down" sends 0)
            ;; "syncing" passes immediately.
            (let ((elneo-room-block-send-when-offline t))
              (cl-letf (((symbol-function 'elneo-server-sync-state)
                         (lambda (_p) '("syncing" . nil))))
                (elneo-room--input-send)
                (mx-check "gate: syncing never blocks"
                          (elneo-room--draft-text) "")))
            (mx-check "gate: syncing sent" sends 1)
            ;; nil defcustom: fire-and-forget even while down.
            (elneo-room--reset-input-area "again")
            (cl-letf (((symbol-function 'elneo-server-sync-state)
                       (lambda (_p) '("offline" . "exit"))))
              (let ((elneo-room-block-send-when-offline nil))
                (elneo-room--input-send)
                (mx-check "gate: setting nil sends anyway"
                          (elneo-room--draft-text) "")))
            (mx-check "gate: fire-and-forget really sent" sends 2)
            (setq elneo-room-block-send-when-offline gate)))))
  (kill-buffer buf))

;; --- history-refetch retry: a bounced backfill routes off the
;; requesting buffer ---

;; A failed history response on the wire is a BARE `@req' ack (@ok
;; false, `@error' only, no room_id -- protocol.rs's golden shape),
;; so the routing cannot go through `--on-history''s registry
;; lookup; the closure that issued the fetch
;; (`elneo-room--history-callback') delivers it to its own buffer,
;; and the retry loop lives there.
(defvar mx--retry-fetches nil)
(defvar mx--retry-callbacks nil)
(defvar mx--retry-timer-fn nil)

(defun mx--history-messages (_profile room limit from cb)
  (push cb mx--retry-callbacks)
  (push (list room limit from) mx--retry-fetches))

(let ((buf (generate-new-buffer " *history-room*")))
  (unwind-protect
      (progn
        (setq mx--retry-fetches nil
              mx--retry-callbacks nil
              mx--retry-timer-fn nil)
        (with-current-buffer buf
          (elneo-room-mode)
          (setq elneo-room--profile "t"
                elneo-room--room-id "!room"
                elneo-room--backfilled nil
                elneo-room--loading-older nil
                elneo-room--history-retries 0
                elneo-room--seen (make-hash-table :test 'equal)
                elneo-room--reactions (make-hash-table :test 'equal)
                elneo-room--receipts (make-hash-table :test 'equal)
                elneo-room--members nil)
          (puthash (cons "t" "!room") buf elneo-room--buffers))
        (with-current-buffer buf
          (cl-letf (((symbol-function 'elneo-room-messages)
                     #'mx--history-messages)
                    ((symbol-function 'elneo-server-live-p)
                     (lambda (_p) t))
                    ((symbol-function 'run-with-timer)
                     (lambda (_secs _rep fn &rest _)
                       (setq mx--retry-timer-fn fn) :timer)))
            (elneo-room--backfill 50)
            (mx-check "retry: the backfill page fetches from the daemon"
                      (reverse mx--retry-fetches)
                      (list (list "!room" 50 nil)))
            ;; the bare ack: no room_id for `--on-history' to route by
            (funcall (car mx--retry-callbacks) "t"
                     (list (cons '@req 1) (cons '@ok nil)
                           (cons '@error "boom")))
            (mx-check "retry: a bare-ack failure arms exactly one timer"
                      (and mx--retry-timer-fn t) t)
            (mx-check "retry: the failure bumped the counter"
                      elneo-room--history-retries 1)
            (mx-check "retry: the latch is not stuck"
                      elneo-room--loading-older nil)
            (mx-check "retry: the view stays unfilled"
                      elneo-room--backfilled nil)
            (funcall mx--retry-timer-fn)
            (mx-check "retry: the timer re-runs the backfill"
                      (length mx--retry-fetches) 2)
            ;; the stack holds the newest callback each time
            (funcall (car mx--retry-callbacks) "t"
                     (list (cons '@req 2) (cons '@ok nil)
                           (cons '@error "boom")))
            (funcall (car mx--retry-callbacks) "t"
                     (list (cons '@req 3) (cons '@ok nil)
                           (cons '@error "boom")))
            (mx-check "retry: the counter keeps climbing"
                      elneo-room--history-retries 3)
            ;; Failures continue until the configured cap...
            (while (< elneo-room--history-retries
                      elneo-room-history-retries-max)
              (funcall (car mx--retry-callbacks) "t"
                       (list (cons '@req 4) (cons '@ok nil)
                             (cons '@error "boom"))))
            (mx-check "retry: capped at the configured max"
                      elneo-room--history-retries
                      elneo-room-history-retries-max)
            (setq mx--retry-timer-fn nil)
            (funcall (car mx--retry-callbacks) "t"
                     (list (cons '@req 4) (cons '@ok nil)
                           (cons '@error "boom")))
            (mx-check "retry: the cap arms nothing further"
                      mx--retry-timer-fn nil)
            ;; A filled view does not retry a refetch failure.
            (setq elneo-room--backfilled t
                  elneo-room--history-retries 0)
            (funcall (car mx--retry-callbacks) "t"
                     (list (cons '@req 5) (cons '@ok nil)
                           (cons '@error "boom")))
            (mx-check "retry: a filled view arms no retry timer"
                      mx--retry-timer-fn nil)
            ;; Success pages take the registry-routed path through
            ;; the same callback: the fresh render completes.
            (setq elneo-room--backfilled nil)
            (cl-letf (((symbol-function 'elneo-room-get)
                       (lambda (_p _r)
                         (list :display-name "Retry" :room-id "!room")))
                      ((symbol-function 'elneo-room-receipts) #'ignore))
              (funcall (car mx--retry-callbacks) "t"
                       (list (cons '@ok t) (cons 'room_id "!room")
                             (cons 'messages []) (cons 'end "tokR"))))
            (mx-check "retry: a successful page fills via the callback"
                      elneo-room--backfilled t)
            (mx-check "retry: the success reset the counter"
                      elneo-room--history-retries 0)
            (mx-check "retry: the success stored the end token"
                      elneo-room--end-token "tokR"))))
    (kill-buffer buf)
    (remhash (cons "t" "!room") elneo-room--buffers)))

;; --- the failure notice: an unfilled buffer shows what went wrong ---

(let ((buf (generate-new-buffer " *history-notice*")))
  (unwind-protect
      (with-current-buffer buf
        (elneo-room-mode)
        (setq elneo-room--profile "t"
              elneo-room--room-id "!room"
              elneo-room--backfilled nil
              elneo-room--history-retries 0
              elneo-room--seen (make-hash-table :test 'equal)
              elneo-room--reactions (make-hash-table :test 'equal))
        (puthash (cons "t" "!room") buf elneo-room--buffers)
        (cl-letf (((symbol-function 'elneo-room-get)
                   (lambda (_p _r) (list :display-name "N" :room-id "!room")))
                  ((symbol-function 'elneo-server-live-p) (lambda (_p) t))
                  ((symbol-function 'run-with-timer)
                   (lambda (_secs _rep fn &rest _)
                     (setq mx--retry-timer-fn fn) :timer))
                  ((symbol-function 'elneo-room-messages)
                   (lambda (_p _r _l _f cb)
                     (push cb mx--retry-callbacks))))
          (elneo-room--backfill 50)
          (mx-check "notice: the buffer starts empty"
                    (buffer-string) "")
          (funcall (car mx--retry-callbacks) "t"
                   (list (cons '@req 11) (cons '@ok nil)
                         (cons '@error "boom2")))
          (mx-check "notice: a failed first page is named in the buffer"
                    (and (string-search
                          "History failed: boom2" (buffer-string)) t) t)
          (mx-check "notice: the retry hint is part of it"
                    (and (string-search "C-c C-r" (buffer-string)) t) t)
          ;; A success clears it.
          (setq mx--retry-callbacks nil)
          (elneo-room--backfill 50)
          (cl-letf (((symbol-function 'elneo-room-get)
                     (lambda (_p _r) (list :display-name "N" :room-id "!room")))
                    ((symbol-function 'elneo-room-receipts) #'ignore))
            (funcall (car mx--retry-callbacks) "t"
                     (list (cons '@ok t) (cons 'room_id "!room")
                           (cons 'messages []) (cons 'end "tokN"))))
          (mx-check "notice: a landing page clears it"
                    elneo-room--notice nil)
          (mx-check "notice: the landing page renders as usual"
                    (and (> (buffer-size) 0) t) t)
          ;; refetch (C-c C-r): from a filled view it resets the state
          ;; and issues a fresh first-page fetch.
          (let (mxd)
            (cl-letf (((symbol-function 'elneo-room-messages)
                       (lambda (_p _r _l _f _cb)
                         (setq mxd t))))
              (elneo-room-refetch)
              (mx-check "notice: refetch resets the backfill latch"
                        elneo-room--backfilled nil)
              (mx-check "notice: refetch issues the fetch" mxd t))))
        )
    (kill-buffer buf)
    (remhash (cons "t" "!room") elneo-room--buffers)))

;; --- a render error mid-page cannot leave an erased buffer ---

(let ((buf (generate-new-buffer " *history-renderr*")))
  (unwind-protect
      (with-current-buffer buf
        (elneo-room-mode)
        (setq elneo-room--profile "t"
              elneo-room--room-id "!room"
              elneo-room--backfilled t
              elneo-room--history-retries 0
              elneo-room--seen (make-hash-table :test 'equal)
              elneo-room--reactions (make-hash-table :test 'equal))
        (puthash (cons "t" "!room") buf elneo-room--buffers)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "older content kept\n"))
        (cl-letf (((symbol-function 'elneo-room-get)
                   (lambda (_p _r) (list :display-name "N" :room-id "!room")))
                  ((symbol-function 'elneo-room-receipts) #'ignore)
                  ((symbol-function 'elneo-room--append-messages)
                   (lambda (_entries) (error "kaboom"))))
          (elneo-room--render-first-page [] "tokX" nil)
          (mx-check "render-restore: the old content is back"
                    (and (string-search "older content kept"
                                        (buffer-string)) t) t)
          (mx-check "render-restore: the view is kept filled or unfilled"
                    elneo-room--backfilled t)
          (mx-check "render-restore: the failure is recorded as the notice"
                    (and (string-search "History render failed"
                                        elneo-room--notice) t) t))
        ;; Recovering from the restored state: the next good page
        ;; renders over the restored content normally.
        (cl-letf (((symbol-function 'elneo-room--append-messages)
                   (lambda (entries) (insert "fresh\n")))
                  ((symbol-function 'elneo-room-get)
                   (lambda (_p _r) (list :display-name "N" :room-id "!room")))
                  ((symbol-function 'elneo-room-receipts) #'ignore))
          (elneo-room--render-first-page (list (cons "x" 1)) "tokX" nil)
          (mx-check "render-restore: the next good page fills"
                    elneo-room--backfilled t)
          (mx-check "render-restore: ...without restoring the error form"
                    (and elneo-room--notice nil) nil)))
    (kill-buffer buf)
    (remhash (cons "t" "!room") elneo-room--buffers)))

;; --- clean up: no armed restart timers may outlive the suite ---

(mx-clean-restarts)
(message "sync-state-test: %d passed, %d failed" mx-pass mx-fail)
(kill-emacs (if (zerop mx-fail) 0 1))