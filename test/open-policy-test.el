;;; open-policy-test.el --- frame policy normalization and routing core -*- lexical-binding: t; -*-

;; `elneo-room--frame-policy' turns the obsolete boolean
;; `elneo-room-jump-sidebar' values (t/nil) and junk into legitimate
;; policy symbols; `elneo-room--route-decision' decides between
;; staying here, opening beside the local bar, force-showing a bar
;; first, and jumping to the frame that shows or parks one.  The
;; batch frame count check needs the side-window plumbing to work in
;; batch ("terminal") Emacs too.
;;
;; Run: emacs -Q --batch -L lisp -l test/open-policy-test.el

(require 'elneo-room)
(require 'elneo-room-bar)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  ;; --- policy normalization (let-bound, no user settings disturbed) ---

  (let ((elneo-room-open-frame-policy t))
    (mx-check "obsolete jump-sidebar t → follow-bar"
              (elneo-room--frame-policy) 'follow-bar))
  (let ((elneo-room-open-frame-policy nil))
    (mx-check "obsolete jump-sidebar nil → here"
              (elneo-room--frame-policy) 'here))
  (dolist (p '(beside-local-bar follow-bar here))
    (let ((elneo-room-open-frame-policy p))
      (mx-check (format "policy %s passes through" p)
                (elneo-room--frame-policy) p)))
  (let ((elneo-room-open-frame-policy 'bogus))
    (mx-check "unknown policy falls back to default"
              (elneo-room--frame-policy) 'beside-local-bar))

  ;; --- routing core, full branch matrix ---
  ;; (policy stay-put show-bar bar-here bar-display)

  ;; Stay-put wins over everything, whatever the policy knows.
  (mx-check "stay-put beats an available jump target"
            (elneo-room--route-decision 'follow-bar 'stay 'show nil '(myframe . nil))
            'here)
  (mx-check "stay-put beats the local bar"
            (elneo-room--route-decision 'beside-local-bar 'stay t t nil)
            'here)

  ;; `here' policy: inert, no bar probing needed.
  (mx-check "here policy never jumps"
            (elneo-room--route-decision 'here nil t nil '(myframe . 2))
            'here)

  ;; `follow-bar' = today's jump-sidebar behavior.
  (mx-check "follow-bar jumps with a bar somewhere"
            (elneo-room--route-decision 'follow-bar nil nil nil '(f . 2))
            '(jump f . 2))
  (mx-check "follow-bar stays when the bar is nowhere"
            (elneo-room--route-decision 'follow-bar nil nil nil nil)
            'here)

  ;; beside-local-bar precedence: local bar → show-bar → jump → here.
  (mx-check "local bar wins over show-bar"
            (elneo-room--route-decision 'beside-local-bar nil t t nil)
            'beside)
  (mx-check "local bar wins over an away jump"
            (elneo-room--route-decision 'beside-local-bar nil nil t '(f . nil))
            'beside)
  (mx-check "show-bar wins over the away jump"
            (elneo-room--route-decision 'beside-local-bar nil t nil '(f . nil))
            'show-beside)
  (mx-check "show-bar off falls back to the legacy jump"
            (elneo-room--route-decision 'beside-local-bar nil nil nil '(f . nil))
            '(jump f . nil))
  (mx-check "show-bar off, bar nowhere: stay"
            (elneo-room--route-decision 'beside-local-bar nil nil nil nil)
            'here)

  ;; --- per-frame bar window find, on the batch frame ---
  (setq elneo-room-bar--buffer nil)
  (mx-check "no bar buffer → no bar window"
            (elneo-room-bar--window-in-frame) nil)
  (elneo-room-bar--ensure)
  (let ((bar elneo-room-bar--buffer))
    (mx-check "existing bar, not displayed → nil"
              (elneo-room-bar--window-in-frame) nil)
    (let ((found (progn
                   (set-window-buffer (split-window (selected-window)) bar)
                   (elneo-room-bar--window-in-frame))))
      (mx-check "bar displayed via split → found"
                (and (windowp found) (eq (window-buffer found) bar)) t)
      (when found (delete-window found)))
    ;; Explicit frame arg works the same on this frame.
    (set-window-buffer (split-window nil nil t) bar)
    (mx-check "explicit frame arg finds it too"
              (and (elneo-room-bar--window-in-frame (selected-frame)) t) t)
    (let ((w (elneo-room-bar--window-in-frame (selected-frame))))
      (when w (delete-window w)))
    ;; Killed bar buffer → nil
    (kill-buffer bar)
    (setq elneo-room-bar--buffer nil)
    (mx-check "bar buffer killed → nil"
              (elneo-room-bar--window-in-frame) nil))

  ;; --- display-buffer / ensure-on-frame ---
  ;; --ensure renders the bar, which needs the room registry; stub the
  ;; full render — the display plumbing is what's under test.
  (cl-letf (((symbol-function 'elneo-room-bar-refresh-full) #'ignore))
    (setq elneo-room-bar--buffer nil)
    (elneo-room-bar--ensure)
    (let ((w1 (elneo-room-bar--display-buffer)))
      (mx-check "display-buffer creates a side window"
                (and (windowp w1) (eq (window-buffer w1) elneo-room-bar--buffer)) t)
      (mx-check "it is the bar window on the selected frame"
                (eq (elneo-room-bar--window-in-frame) w1) t)
      (mx-check "second call reuses the same window"
                (window-valid-p (elneo-room-bar--display-buffer)) t)
      (mx-check "reuse returns the identical window"
                (eq (elneo-room-bar--display-buffer) w1) t)
      (mx-check "non-live frame arg falls back cleanly"
                (eq (elneo-room-bar--display-buffer "not-a-frame") w1) t)
      (delete-window w1))
    (mx-check "after delete there is no bar window"
              (elneo-room-bar--window-in-frame) nil))

  (message "results: %d passed, %d failed" pass fail)
  (when (> fail 0) (kill-emacs 1)))