;;; release-support-test.el --- release download/offer support -*- lexical-binding: t; -*-

;; Platform mapping, asset names and URLs, and the download+verify
;; machinery: batch only, every URL fetch stubbed against fixture
;; files — no release is ever touched.  Also the resolver behind
;; `elneo-server-start', which decides between an explicit command,
;; `exec-path', a previously downloaded binary and the download offer.
;;
;; Run: emacs -Q --batch -L lisp -l test/release-support-test.el

(require 'elneo-client)

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  ;; --- platform mapping ---

  (mx-check "linux x86_64"
            (let ((system-type 'gnu/linux)
                  (system-configuration "x86_64-pc-linux-gnu"))
              (elneo-release--platform))
            '("linux" . "x86_64"))
  (mx-check "linux aarch64"
            (let ((system-type 'gnu/linux)
                  (system-configuration "aarch64-unknown-linux-gnu"))
              (elneo-release--platform))
            '("linux" . "arm64"))
  (mx-check "macos arm"
            (let ((system-type 'darwin)
                  (system-configuration "aarch64-apple-darwin"))
              (elneo-release--platform))
            '("macos" . "arm64"))
  (mx-check "macos x86_64 maps too (the asset simply 404s)"
            (let ((system-type 'darwin)
                  (system-configuration "x86_64-apple-darwin"))
              (elneo-release--platform))
            '("macos" . "x86_64"))
  (mx-check "windows x86_64"
            (let ((system-type 'windows-nt)
                  (system-configuration "x86_64-w64-mingw32"))
              (elneo-release--platform))
            '("windows" . "x86_64"))
  (mx-check "unbuilt architecture gets no platform"
            (let ((system-type 'gnu/linux)
                  (system-configuration "riscv64-unknown-linux-gnu"))
              (elneo-release--platform))
            nil)

  ;; --- asset name & url shapes ---

  (let ((elneo-release-repo "aard-fi/elneo"))
    (mx-check "windows asset keeps .exe"
              (let ((system-type 'windows-nt)
                    (system-configuration "x86_64-w64-mingw32"))
                (elneo-release--asset-name))
              "elneo-server-windows-x86_64.exe")
    (mx-check "linux asset name"
              (let ((system-type 'gnu/linux)
                    (system-configuration "x86_64-pc-linux-gnu"))
                (elneo-release--asset-name))
              "elneo-server-linux-x86_64")
    (mx-check "no platform, no asset name"
              (let ((system-type 'gnu/linux)
                    (system-configuration "riscv64-unknown-linux-gnu"))
                (elneo-release--asset-name))
              nil)
    (mx-check "url shape (stable redirect, no API)"
              (let ((system-type 'darwin)
                    (system-configuration "aarch64-apple-darwin"))
                (elneo-release--url "SHA256SUMS"))
              "https://github.com/aard-fi/elneo/releases/latest/download/SHA256SUMS"))

  ;; --- download + verification ---

  (let* ((basedir (make-temp-file "elneo-release-test-" t))
         (system-type 'gnu/linux)
         (system-configuration "x86_64-pc-linux-gnu")
         (asset (elneo-release--asset-name))
         (bin (elneo-release--bin-dir basedir))
         (sums (format "%s  %s\n%s  elneo-server-other-x86_64\n"
                       (secure-hash 'sha256 "fake-binary-bytes")
                       asset
                       "0123456789abcdef0123456789abcdef0123456789\
abcdef0123456789abcdef"))
         (asset-fixture (make-temp-file "fixture-elneo-server-"))
         ;; a url-copy-file stub whose fetches come from SUMS-SOURCE
         ;; and ASSET-SOURCE — the same shape the real one has.
         (fetch (lambda (sums-source asset-source thunk)
                  (cl-letf (((symbol-function 'url-copy-file)
                             (lambda (url file &optional _ok _time)
                               (copy-file
                                (if (string-suffix-p "SHA256SUMS" url)
                                    sums-source asset-source)
                                file t))))
                    (funcall thunk)))))
    (with-temp-file asset-fixture (insert "fake-binary-bytes"))
    ;; matching checksums: installed mode 0755 under bin/
    (let ((sums-file (make-temp-file "sums-")))
      (with-temp-file sums-file (insert sums))
      (let ((got (funcall fetch sums-file asset-fixture
                          (lambda () (elneo-release-download basedir)))))
        (mx-check "verified download installs the asset"
                  (and got
                       (equal (file-name-nondirectory got) asset)
                       (equal (file-name-directory got)
                              (file-name-as-directory bin)))
                  t)
        (when got
          (mx-check "installed mode is 0755"
                    (logand #o777 (file-modes got))
                    #o755))))
    ;; corrupt download: checksum mismatch rejected, nothing changed
    (let ((bad-asset (make-temp-file "bad-asset-"))
          (sums-file (make-temp-file "sums-")))
      (with-temp-file bad-asset (insert "tampered-bytes"))
      (with-temp-file sums-file (insert sums))
      (mx-check "checksum mismatch returns nil"
                (funcall fetch sums-file bad-asset
                         (lambda () (elneo-release-download basedir)))
                nil)
      (mx-check "mismatch leaves only the earlier install in bin/"
                (directory-files bin nil "elneo-server")
                (list asset)))
    ;; asset missing from SHA256SUMS: also rejected
    (let ((sums-file (make-temp-file "sums-")))
      (with-temp-file sums-file
        (insert (format "%s  elneo-server-other-x86_64\n"
                        (secure-hash 'sha256 "whatever"))))
      (mx-check "missing checksum entry rejected"
                (funcall fetch sums-file asset-fixture
                         (lambda () (elneo-release-download basedir)))
                nil))
    ;; unreachable release: clean nil, reason messaged, no crash
    (cl-letf (((symbol-function 'url-copy-file)
               (lambda (&rest _) (error "HTTP 404"))))
      (mx-check "failed fetch returns nil"
                (elneo-release-download basedir)
                nil))
    ;; no matching platform: nothing fetched at all
    (let ((system-type 'gnu/linux)
          (system-configuration "riscv64-unknown-linux-gnu"))
      (cl-letf (((symbol-function 'url-copy-file)
                 (lambda (&rest _) (error "must not fetch"))))
        (mx-check "no platform: download declines to run"
                  (elneo-release-download basedir)
                  nil)))
    ;; temp files never linger in bin/ (the fixture install aside)
    (mx-check "temp files cleaned up"
              (directory-files bin nil "elneo-asset")
              nil))

  ;; --- command resolution ---

  (let ((home (make-temp-file "elneo-resolve-test-" t)))
    (setq elneo-server--download-offered nil)
    ;; explicit full path: wins, nothing asked
    (let ((elneo-server-command "/explicit/elneo-server"))
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (error "an explicit path must never offer"))))
        (mx-check "explicit full path wins untouched"
                  (elneo-server--command-to-run "p")
                  "/explicit/elneo-server")))
    ;; bare name on exec-path: resolves there
    (let ((elneo-server-command "elneo-server"))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (cmd &optional _remote) (concat "/usr/bin/" cmd)))
                ((symbol-function 'elneo-release--installed-path)
                 (lambda () (error "exec-path beats the download dir"))))
        (mx-check "bare name resolves on exec-path"
                  (elneo-server--command-to-run "p")
                  "/usr/bin/elneo-server")))
    ;; bare name off exec-path, downloaded copy present: silent takeover
    (let ((elneo-server-command "elneo-server")
          (system-type 'gnu/linux)
          (system-configuration "x86_64-pc-linux-gnu")
          (installed (expand-file-name "elneo-server-linux-x86_64"
                                       (elneo-release--bin-dir home))))
      (make-directory (file-name-directory installed) t)
      (copy-file (make-temp-file "seed-") installed t)
      (cl-letf (((symbol-function 'executable-find) (lambda (_c) nil))
                ((symbol-function 'elneo-release--installed-path)
                 (lambda () installed))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (error "a downloaded copy must never offer"))))
        (mx-check "downloaded copy silently takes over"
                  (elneo-server--command-to-run "p")
                  installed))
      (delete-file installed))
    ;; nothing anywhere: the offer decides
    (let ((elneo-server-command "elneo-server")
          (system-type 'gnu/linux)
          (system-configuration "x86_64-pc-linux-gnu"))
      (cl-letf (((symbol-function 'executable-find) (lambda (_c) nil))
                ((symbol-function 'elneo-release--installed-path)
                 (lambda () nil)))
        ;; declined: today's behavior — the command itself, and the
        ;; profile is marked so auto-restart ticks do not re-ask
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
                  ((symbol-function 'elneo-release-download)
                   (lambda (&optional _b) (error "there is nothing to decline"))))
          (mx-check "declined offer falls back to the command"
                    (elneo-server--command-to-run "p")
                    elneo-server-command))
        (mx-check "a decline marks the profile"
                  (assoc "p" elneo-server--download-offered) '("p" . t))
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (&rest _) (error "a marked profile must not re-ask"))))
          (mx-check "marked profile: no second offer, still the fallback"
                    (elneo-server--command-to-run "p")
                    elneo-server-command))
        ;; accepted: whatever the download installed — the resolver
        ;; finds it on disk, not through the download's return value
        (setq elneo-server--download-offered nil)
        (let ((fresh "/fresh/bin/elneo-server-linux-x86_64"))
          (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                    ((symbol-function 'elneo-release-download)
                     (lambda (&optional _b) fresh))
                    ((symbol-function 'elneo-release--installed-path)
                     (lambda () fresh)))
            (mx-check "accepted offer returns the fresh path"
                      (elneo-server--command-to-run "p")
                      fresh)))
        ;; no matching platform: no offer at all
        (setq elneo-server--download-offered nil)
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (&rest _) (error "no platform, no offer")))
                  ((symbol-function 'elneo-release-download)
                   (lambda (&optional _b) (error "no platform, no offer"))))
          (let ((system-type 'gnu/linux)
                (system-configuration "riscv64-unknown-linux-gnu"))
            (mx-check "platformless machine falls back to the command"
                      (elneo-server--command-to-run "p")
                      elneo-server-command)))))

  ;; --- the extracted offer and the onboarding preflight ---

  (let ((elneo-server-command "elneo-server"))
    (setq elneo-server--download-offered nil)
    ;; a platformless machine is never asked and never marked
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (&rest _) (error "a platformless machine gets no offer"))))
      (let ((system-type 'gnu/linux)
            (system-configuration "riscv64-unknown-linux-gnu"))
        (mx-check "platformless: no offer, no mark"
                  (progn (elneo-server--offer-release-download "q")
                         (assoc "q" elneo-server--download-offered))
                  nil)))
    ;; nothing found at all, and no binary anywhere
    (cl-letf (((symbol-function 'executable-find) (lambda (_c) nil))
              ((symbol-function 'elneo-release--installed-path)
               (lambda () nil)))
      ;; decline: asked, marked, nothing fetched, download not called
      (let ((asked 0))
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (&rest _) (cl-incf asked) nil))
                  ((symbol-function 'elneo-release-download)
                   (lambda (&optional _b) (error "decline never downloads"))))
          (mx-check "declined offer returns nil"
                    (elneo-server--offer-release-download "q") nil))
        (mx-check "decline asked once"
                  asked 1)
        (mx-check "declined offer marks its profile"
                  (assoc "q" elneo-server--download-offered) '("q" . t))
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (&rest _) (error "a marked profile must not re-ask"))))
          (mx-check "marked profile stays silent for start-time offers"
                    (elneo-server--offer-release-download "q") nil)))
      ;; force re-asks a marked profile (the decline's mark above stays
      ;; until the next successful start, by design)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                ((symbol-function 'elneo-release-download)
                 (lambda (&optional _b)
                   "/fresh/bin/elneo-server-linux-x86_64")))
        (mx-check "force re-asks a marked profile"
                  (elneo-server--offer-release-download "q" t)
                  "/fresh/bin/elneo-server-linux-x86_64")))
    ;; a yes followed by a failed download marks too
    (setq elneo-server--download-offered nil)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
              ((symbol-function 'elneo-release-download)
               (lambda (&optional _b) nil)))
      (mx-check "failed download despite a yes also marks"
                (progn (elneo-server--offer-release-download "q")
                       (assoc "q" elneo-server--download-offered))
                '("q" . t)))
    ;; the preflight is the same chain, asked with force
    (setq elneo-server--download-offered nil)
    (let ((elneo-server-command "/explicit/elneo-server"))
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (error "an explicit path must not offer"))))
        (mx-check "preflight accepts an explicit command"
                  (elneo-server--preflight-binary "q") t)))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_c) "/usr/bin/elneo-server"))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) (error "exec-path must not offer"))))
      (mx-check "preflight accepts a PATH resolution"
                (elneo-server--preflight-binary "q")
                "/usr/bin/elneo-server"))
    (cl-letf (((symbol-function 'executable-find) (lambda (_c) nil))
              ((symbol-function 'elneo-release--installed-path)
               (lambda () "/data/bin/elneo-server-linux-x86_64"))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) (error "a downloaded copy must not offer"))))
      (mx-check "preflight accepts a downloaded release"
                (elneo-server--preflight-binary "q")
                "/data/bin/elneo-server-linux-x86_64"))
    (cl-letf (((symbol-function 'executable-find) (lambda (_c) nil))
              ((symbol-function 'elneo-release--installed-path)
               (lambda () nil))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
      (setq elneo-server--download-offered nil)
      (mx-check "preflight decline means stop onboarding"
                (elneo-server--preflight-binary "q") nil)
      (mx-check "preflight decline still protects the restart ticks"
                (assoc "q" elneo-server--download-offered) '("q" . t)))

    ;; --- onboarding wiring: the offer comes before the credentials ---

    (let ((system-type 'gnu/linux)
          (system-configuration "x86_64-pc-linux-gnu")
          (elneo-accounts nil)
          (order nil)
          ;; the user-error's quotes render with the ambient style
          ;; unless pinned; grave matches the source text exactly
          (text-quoting-style 'grave))
      (setq elneo-server--download-offered nil)
      (cl-letf (((symbol-function 'executable-find) (lambda (_c) nil))
                ((symbol-function 'elneo-release--installed-path)
                 (lambda () nil))
                ;; no account state is touched for real
                ((symbol-function 'elneo--accounts-load) (lambda ()))
                ((symbol-function 'elneo--accounts-save) (lambda ()))
                ((symbol-function 'elneo--session-exists-p)
                 (lambda (_p) (push 'session-check order) nil))
                ((symbol-function 'read-string)
                 (lambda (prompt &optional _i _h _d _ih)
                   (push
                    (pcase prompt
                      ("Profile name: " 'profile-prompt)
                      ("Homeserver: " 'homeserver-prompt)
                      (_ 'username-prompt))
                    order)
                   (pcase prompt
                     ("Profile name: " "mxonboard")
                     ("Homeserver: " "https://mx.test")
                     (_ "tester"))))
                ((symbol-function 'read-passwd)
                 (lambda (&rest _) (push 'password-prompt order) "secret"))
                ((symbol-function 'elneo-server-live-p) (lambda (_p) nil))
                ((symbol-function 'elneo-server-start)
                 (lambda (_p) (push 'server-start order)))
                ((symbol-function 'elneo-server--call)
                 (lambda (_p _e _cb) (push 'login-call order)))
                ((symbol-function 'elneo-client--register-handlers)
                 (lambda (_p) (push 'register-handlers order))))
        ;; a decline stops onboarding after exactly the profile prompt
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (&rest _) (push 'release-offer order) nil))
                  ((symbol-function 'elneo-release-download)
                   (lambda (&optional _b) (error "decline never downloads"))))
          (mx-check
           "declined preflight stops onboarding, nothing stranded"
           (condition-case e
               (progn (call-interactively #'elneo-add-account) nil)
             (user-error (cadr e)))
           "Matrix [mxonboard]: no elneo-server binary found — set \
`elneo-server-command', put one on PATH, or re-run and accept the \
download offer")
          (mx-check "decline asks nothing but the profile prompt"
                    (nreverse order) '(profile-prompt release-offer))
          (mx-check "decline registers nothing"
                    elneo-accounts nil))
        ;; accepted: the same offer before any credential prompt, then
        ;; the ordinary fresh-login flow
        (setq order nil elneo-server--download-offered nil)
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (&rest _) (push 'release-offer order) t))
                  ((symbol-function 'elneo-release-download)
                   (lambda (&optional _b)
                     "/fresh/bin/elneo-server-linux-x86_64")))
          (call-interactively #'elneo-add-account)
          (mx-check "one offer, before the credentials, then the login"
                    (nreverse order)
                    '(profile-prompt release-offer session-check
                                     homeserver-prompt username-prompt
                                     password-prompt server-start
                                     register-handlers login-call))
          (mx-check "the accepted offer registered mxonboard"
                    (alist-get "mxonboard" elneo-accounts nil nil #'equal)
                    '(:homeserver "https://mx.test")))))
    (setq elneo-server--download-offered nil)))

  ;; --- elneo-upgrade-server ---

  (setq elneo-server-command "elneo-server")

  ;; No asset for this machine: the gate fires before anything else.
  (cl-letf (((symbol-function 'elneo--accounts-load) (lambda ()))
            ((symbol-function 'elneo-release--asset-name)
             (lambda () nil))
            ((symbol-function 'elneo-release-download)
             (lambda (&optional _b) (error "no-asset upgrade must not download"))))
    (mx-check "no asset stops the upgrade"
              (condition-case e
                  (progn (elneo-upgrade-server) 'no-error)
                (user-error (cadr e)))
              (format "No elneo-server release for this machine (%s)"
                      system-configuration)))

  ;; Upgrade runs with every prompt stubbed: ANSWERS is one t/nil
  ;; per y-or-n-p ask, in order.  The stubs are repeated per scenario
  ;; because each cl-letf owns its own bindings.
  (let ((installed "/r/data/bin/elneo-server-macos-arm64")
        downloaded restarted answers)
    ;; Bare `elneo-server-command', nothing on PATH: a restart
    ;; resolves to the downloaded binary, so no pointing ask runs.
    (setq elneo-accounts '(("alpha" . t) ("beta" . t) ("idle" . t)))
    (cl-letf (((symbol-function 'elneo--accounts-load) (lambda ()))
              ((symbol-function 'elneo-release--asset-name)
               (lambda () "elneo-server-macos-arm64"))
              ((symbol-function 'elneo--data-dir-base)
               (lambda () "/r/data"))
              ((symbol-function 'elneo-release-download)
               (lambda (&optional _b) (push 'download downloaded) installed))
              ((symbol-function 'elneo-release--installed-path)
               (lambda () installed))
              ((symbol-function 'elneo-restart-server)
               (lambda (&optional _p) (push 'restart restarted)))
              ((symbol-function 'y-or-n-p)
               (lambda (_prompt) (pop answers)))
              ((symbol-function 'executable-find)
               (lambda (_c) nil))
              ((symbol-function 'elneo-server-live-p)
               (lambda (p) (member p '("alpha" "beta")))))
      ;; A decline downloads and restarts nothing.
      (setq answers '(nil) downloaded nil restarted nil)
      (elneo-upgrade-server)
      (mx-check "decline: no download" downloaded nil)
      (mx-check "decline: no restart" restarted nil)
      ;; Accepted, resolution falls through to the installed path:
      ;; no pointing ask is asked, both live daemons restart once.
      (setq answers '(t) downloaded nil restarted nil)
      (elneo-upgrade-server)
      (mx-check "accept: exactly one download" downloaded '(download))
      (mx-check "accept: bare name falls through, both daemons restart"
                (nreverse restarted) '(restart)))
    ;; A PATH install shadows the download in the start resolution —
    ;; the pointing ask is the only way the upgrade takes effect.
    (cl-letf (((symbol-function 'elneo--accounts-load) (lambda ()))
              ((symbol-function 'elneo-release--asset-name)
               (lambda () "elneo-server-macos-arm64"))
              ((symbol-function 'elneo--data-dir-base)
               (lambda () "/r/data"))
              ((symbol-function 'elneo-release-download)
               (lambda (&optional _b) (push 'download downloaded) installed))
              ((symbol-function 'elneo-release--installed-path)
               (lambda () installed))
              ((symbol-function 'elneo-restart-server)
               (lambda (&optional _p) (push 'restart restarted)))
              ((symbol-function 'y-or-n-p)
               (lambda (_prompt) (pop answers)))
              ((symbol-function 'elneo-server-live-p)
               (lambda (p) (member p '("alpha" "beta"))))
              ;; A PATH install outranks the download in the start
              ;; resolution.
              ((symbol-function 'executable-find)
               (lambda (_c) "/usr/local/bin/elneo-server")))
      ;; Accepted download, declined pointer: restart with the old
      ;; command resolution, variable untouched.
      (setq answers '(t nil) downloaded nil restarted nil)
      (elneo-upgrade-server)
      (mx-check "PATH shadow, declined pointer: no setq"
                elneo-server-command "elneo-server")
      (mx-check "PATH shadow, declined pointer: restarted anyway"
                (nreverse restarted) '(restart))
      ;; Accepted pointer: the variable takes the fresh binary.
      (setq answers '(t t) downloaded nil restarted nil)
      (elneo-upgrade-server)
      (mx-check "PATH shadow, accepted pointer: variable set"
                elneo-server-command installed)
      (mx-check "PATH shadow, accepted pointer: restarted"
                (nreverse restarted) '(restart))))
  (setq elneo-accounts nil
        elneo-server-command "elneo-server")

  (message "results: %d passed, %d failed" pass fail)
  (when (> fail 0) (kill-emacs 1)))