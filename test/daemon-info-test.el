;;; daemon-info-test.el --- daemon protocol versioning -*- lexical-binding: t; -*-

;; `elneo-server--on-daemon-info' records the greeting (last-wins);
;; `elneo-server--protocol-verdict' classifies a daemon version against
;; the client's and the supported minimum; `elneo-client--protocol-gate'
;; turns the verdict into block / override / warn-and-continue.  The
;; sentinel must drop the snapshot when the daemon dies.  All batch, no
;; real processes.
;;
;; Run: emacs -Q --batch -L lisp -l test/daemon-info-test.el

(require 'elneo-client)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  ;; --- verdict matrix ---

  (mx-check "equal protocol is ok"
            (elneo-server--protocol-verdict 1 1 1) :ok)
  (mx-check "client newer than daemon, at minimum, is ok"
            (elneo-server--protocol-verdict 3 2 2) :ok)
  (mx-check "daemon newer than client"
            (elneo-server--protocol-verdict 1 1 2) :too-new)
  (mx-check "daemon below minimum"
            (elneo-server--protocol-verdict 5 2 1) :too-old)
  (mx-check "missing greeting is unknown"
            (elneo-server--protocol-verdict 1 1 nil) :unknown)
  (mx-check "non-numeric greeting is unknown"
            (elneo-server--protocol-verdict 1 1 "x") :unknown)
  (let ((elneo-daemon-protocol-minimum 2))
    (mx-check "artificial minimum 2 rejects protocol 1"
              (elneo-server--protocol-verdict 2 2 1) :too-old))

  ;; --- greeting handler: registration, storage, last-wins ---

  (setq elneo-server--callbacks nil elneo-server--daemon-info nil)
  (let ((table (elneo-server--get-callbacks "t")))
    (mx-check "transport registers the daemonInfo handler"
              (gethash "daemonInfo" table) #'elneo-server--on-daemon-info))
  (mx-check "no greeting yet → unknown protocol" (elneo-server--daemon-protocol "t") nil)
  (elneo-server--dispatch-event
   "t" '((@type . "daemonInfo") (protocol . 1) (release . "0.1.0")))
  (mx-check "greeting protocol stored" (elneo-server--daemon-protocol "t") 1)
  (mx-check "greeting release stored"
            (plist-get (elneo-server--daemon-info-for "t") :release) "0.1.0")
  (elneo-server--dispatch-event
   "t" '((@type . "daemonInfo") (protocol . 2) (release . "0.2.0")))
  (mx-check "second greeting last-wins (protocol)"
            (elneo-server--daemon-protocol "t") 2)
  (mx-check "second greeting last-wins (release)"
            (plist-get (elneo-server--daemon-info-for "t") :release) "0.2.0")

  ;; --- sentinel prunes the greeting like every other daemon state ---

  (cl-letf (((symbol-function 'process-live-p) (lambda (_proc) nil)))
    (elneo-server--sentinel "t" 'fake-proc "exited abnormally with code 1\n"))
  (mx-check "sentinel prunes the greeting"
            (elneo-server--daemon-info-for "t") nil)

  ;; --- the activation gate ---

  (setq elneo-server--daemon-info nil)
  ;; (The gate's stale-daemon offer would prompt below; in batch the
  ;; answer is always no, which marks the profile — later blocked
  ;; gate evaluations in this file therefore ask nothing anymore.)

  (setq elneo-client--update-offered nil)
  (let ((elneo-daemon-protocol 1)
        (elneo-daemon-protocol-minimum 1)
        (elneo-daemon-protocol-allow-outdated nil))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
      (mx-check "gate blocks a pre-versioning daemon"
                (elneo-client--protocol-gate "g") nil)
      (elneo-server--dispatch-event
       "g" '((@type . "daemonInfo") (protocol . 0) (release . "old")))
      (mx-check "gate blocks below minimum"
                (elneo-client--protocol-gate "g") nil)
      (let ((elneo-daemon-protocol-allow-outdated t))
        (mx-check "override lets an outdated daemon through"
                  (elneo-client--protocol-gate "g") t))
      (elneo-server--dispatch-event
       "g" '((@type . "daemonInfo") (protocol . 1)))
      (mx-check "gate passes equal protocol"
                (elneo-client--protocol-gate "g") t)
      (elneo-server--dispatch-event
       "g" '((@type . "daemonInfo") (protocol . 9)))
      (mx-check "gate passes a newer daemon (warn only)"
                (elneo-client--protocol-gate "g") t)))

  ;; --- the gate quenches an inherited sync loop when it blocks ---
  ;; stopSync exists from protocol 2 on; the blocked branch sends it
  ;; only to daemons that understand it.

  (elneo-server--dispatch-event
   "g" '((@type . "daemonInfo") (protocol . 2) (release . "q")))
  (let ((sent nil))
    (cl-letf (((symbol-function 'elneo-server--call)
               (lambda (_p cmd _cb) (setq sent (cdr (assq '@type cmd))))))
      (let ((elneo-daemon-protocol-minimum 3))
        (mx-check "protocol-2 daemon below minimum is blocked"
                  (elneo-client--protocol-gate "g") nil)
        (mx-check "blocked gate sends stopSync to it" sent "stopSync")))
    ;; A passing gate never queues a quench.
    (setq sent nil)
    (let ((elneo-daemon-protocol-minimum 1))
      (mx-check "gate passes a protocol-2 daemon"
                (elneo-client--protocol-gate "g") t))
    (mx-check "gate passes: no stopSync sent" sent nil)
    ;; Overriding the gate skips the quench along with the block.
    (let ((elneo-daemon-protocol-minimum 3)
          (elneo-daemon-protocol-allow-outdated t)
          (sent nil))
      (mx-check "override lets a too-old daemon through"
                (elneo-client--protocol-gate "g") t)
      (mx-check "override sends no stopSync" sent nil)
      (setq sent 'unset)
      (elneo-server--dispatch-event
       "g" '((@type . "daemonInfo") (protocol . 1)))
      ;; Protocol-1 daemons cannot be quenched at all.
      (let ((elneo-daemon-protocol-minimum 3)
            (elneo-daemon-protocol-allow-outdated nil))
        (mx-check "protocol-1 below minimum is blocked"
                  (elneo-client--protocol-gate "g") nil)
        (mx-check "protocol-1 daemon: no stopSync sent" sent 'unset)
        ;; Pre-versioning daemons likewise.
        (setq elneo-server--daemon-info nil)
        (setq sent 'unset)
        (mx-check "missing greeting: blocked"
                  (elneo-client--protocol-gate "g") nil)
        (mx-check "missing greeting: no stopSync sent" sent 'unset))))

  ;; --- the stale-daemon release offer ---
  ;; A below-minimum daemon gets one offer per offline streak: yes
  ;; downloads (verified) and hands the daemon over to the
  ;; auto-restarter; no or failure changes nothing, and the streak's
  ;; later gate evaluations stay silent.

  (setq elneo-client--update-offered nil)
  (elneo-server--dispatch-event
   "g" '((@type . "daemonInfo") (protocol . 2) (release . "old")))
  (let ((sent nil) (asked 0) (downloaded nil))
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_prompt) (cl-incf asked) nil))
              ((symbol-function 'elneo-release-download)
               (lambda (&optional _b) (setq downloaded t) "/nowhere"))
              ((symbol-function 'elneo-server--call)
               (lambda (_p cmd _cb) (setq sent (cdr (assq '@type cmd))))))
      (let ((elneo-daemon-protocol-minimum 3))
        (mx-check "declined offer: gate still blocks"
                  (elneo-client--protocol-gate "g") nil)
        (mx-check "declined offer: stopSync still sent" sent "stopSync")
        (mx-check "declined offer: asked exactly once" asked 1)
        (elneo-client--protocol-gate "g")
        (mx-check "the streak's second evaluation asks nothing" asked 1)
        (mx-check "second evaluation still quenches" sent "stopSync")))
    (mx-check "declined offer: nothing downloaded" downloaded nil)
    (mx-check "decline marks the profile for the streak"
              (assoc "g" elneo-client--update-offered) '("g" . t))
    (elneo-client--on-session-sync-state "g" "synced" nil)
    (mx-check "synced clears the streak's decline"
              (assoc "g" elneo-client--update-offered) nil))

  ;; Accepted: the download installs, the stale process is stopped
  ;; without leaving the deliberate-stop suppression behind, and the
  ;; restarter respawns (and re-activates) on the new binary.

  (elneo-server--dispatch-event
   "g" '((@type . "daemonInfo") (protocol . 2) (release . "old")))
  (setq elneo-client--update-offered nil)
  (let ((bin nil) (stopped nil) (rearmed nil))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) t))
              ((symbol-function 'elneo-release-download)
               (lambda (&optional _b)
                 (setq bin "/fresh/bin/elneo-server-linux-x86_64") bin))
              ((symbol-function 'elneo-server-live-p) (lambda (_p) t))
              ((symbol-function 'elneo-server-stop)
               (lambda (_p) (setq stopped t)))
              ((symbol-function 'elneo-client--maybe-schedule-restart)
               (lambda (_p) (setq rearmed t)))
              ((symbol-function 'elneo-server--call)
               (lambda (_p _cmd _cb) t)))
      (let ((elneo-daemon-protocol-minimum 3))
        (mx-check "accepted offer: activation still blocked this cycle"
                  (elneo-client--protocol-gate "g") nil)
        (mx-check "accepted offer: the stale process is stopped" stopped t)
        (mx-check "accepted offer: no deliberate-stop suppression left"
                  (assoc "g" elneo-server--manual-stops) nil)
        (mx-check "accepted offer: the restarter is re-armed" rearmed t))
      (mx-check "accepted offer: the installed path rode along" bin
                "/fresh/bin/elneo-server-linux-x86_64")))

  ;; --- handlers register only past a passing gate ---

  (let (saw)
    (cl-letf (((symbol-function 'elneo-server-live-p) (lambda (_p) t))
              ((symbol-function 'elneo-server--call)
               (lambda (_p cmd cb)
                 (setq saw (cons (cdr (assq '@type cmd)) saw))
                 ;; Model the daemon's ordering from the outside world:
                 ;; the frame-1 greeting is always dispatched before the
                 ;; getSession response reaches its callback.
                 (when cb
                   (elneo-server--dispatch-event
                    "g" '((@type . "daemonInfo") (protocol . 2)
                          (release . "new")))
                   (funcall cb "g" '((@ok . t)))))))
      (let ((elneo-daemon-protocol-minimum 1))
        ;; Simulate the stale session a hot reload may land in: a
        ;; transport table with no greeting handler at all.  The
        ;; activation itself must repair it, since the gate depends on
        ;; the greeting being processed.
        (setq elneo-server--callbacks
              (assoc-delete-all "g" elneo-server--callbacks))
        (setf (alist-get "g" elneo-server--callbacks nil nil #'equal)
              (make-hash-table :test 'equal))
        (elneo-client--activate "g")
        (mx-check "activation re-asserts the greeting on a stale table"
                  (gethash "daemonInfo" (elneo-server--get-callbacks "g"))
                  #'elneo-server--on-daemon-info)
        (mx-check "passing activation registers client handlers"
                  (and (gethash "updateRoom"
                                (elneo-server--get-callbacks "g"))
                       t)
                  t)
        (mx-check "passing activation then syncs: getRooms and startSync"
                  (and (member "getRooms" saw) (member "startSync" saw) t) t)
        (mx-check "passing activation sends no stopSync"
                  (member "stopSync" saw) nil)
        ;; Blocked gate: the session stays inert — no client handlers,
        ;; no sync commands, only the quench.
        (setq elneo-server--callbacks
              (assoc-delete-all "g" elneo-server--callbacks))
        (setq saw nil)
        (let ((elneo-daemon-protocol-minimum 3))
          (elneo-client--activate "g")
          (mx-check "blocked activation registers no client handlers"
                    (gethash "updateRoom" (elneo-server--get-callbacks "g")) nil)
          (mx-check "blocked activation runs no sync commands"
                    (and (member "getRooms" saw) t) nil)
          (mx-check "blocked activation still sends the stopSync quench"
                    (car saw) "stopSync")))))

  ;; --- elneo-reload keeps the protocol constants tracking source ---

  ;; The constants are defconst (not defcustom): they name what the
  ;; code implements, so any reload must overwrite a stale binding —
  ;; with defvar semantics a session running older code would keep its
  ;; own value and the gate would misgrade every greeting forever.
  (let ((elneo-daemon-protocol-allow-outdated :saved))
    (setq elneo-daemon-protocol 99)
    (setq elneo-daemon-protocol-minimum 99)
    (elneo-reload)
    (mx-check "reload refreshes elneo-daemon-protocol"
              elneo-daemon-protocol 23)
    (mx-check "reload refreshes elneo-daemon-protocol-minimum"
              elneo-daemon-protocol-minimum 1)
    (mx-check "reload leaves elneo-daemon-protocol-allow-outdated alone"
              elneo-daemon-protocol-allow-outdated :saved))

  (message "results: %d passed, %d failed" pass fail)
  (when (> fail 0) (kill-emacs 1)))