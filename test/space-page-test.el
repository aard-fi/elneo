;;; space-page-test.el --- space discovery: wrappers, page, overview, links -*- lexical-binding: t; -*-

;; The space-discovery slice (protocol 18): the two transport wrappers
;; in elneo-client.el, the space page (`elneo-space-browse': header
;; facts from the space's own row, listing rows with join-rule hints
;; and [Join]/[Open]/[Browse] buttons, [more] pagination, an empty
;; listing apart from a failed one, the honest denial text), the room
;; bar's `b' entry, the room overview's Spaces line (the
;; `elneo-room--fetch-spaces' cache) and the matrix.to link
;; interception in `elneo-room--browse-url-at-point'.  The daemon
;; calls are stubbed at `elneo-server--call'.
;;
;; Run: emacs -Q --batch -L lisp -l test/space-page-test.el

(require 'elneo-room)
(require 'elneo-client)
;; The avatar/initial cells come from the room bar; loading it keeps
;; the render machinery behind the stubs below real.
(require 'elneo-room-bar)
(require 'elneo-space)
;; The avatar buttons' actions load elneo-image lazily; preloading
;; keeps the later stubbing intact (a first require redefines the
;; function right out of the cl-letf).  (Same reason as account-page.)
(require 'elneo-image)

(defvar mx--calls nil)
(defvar mx--response nil)
(defvar mx--page nil)
(defvar mx--popped nil)

(defun mx--capture (profile event callback)
  "A elneo-server--call stub: remember EVENT, answer `mx--response'."
  (push (cons profile event) mx--calls)
  (funcall callback profile mx--response))

(defmacro mx--with-capture (&rest body)
  "Run BODY capturing every elneo-server--call payload, newest last."
  `(let ((mx--calls nil) (mx--response '((@ok . t))))
     (cl-letf (((symbol-function 'elneo-server--call) #'mx--capture))
       ,@body)
     (nreverse mx--calls)))

(defun mx--row (id name &rest more)
  "A hierarchy-room alist: ROOM-ID, NAME, then MORE fields."
  (append (list (cons 'room_id id) (cons 'name name)) more))

(defvar mx--rows
  (list
   (mx--row "!s1" "Ops Space"
            '(canonical_alias . "#ops:example.org")
            '(topic . "Ops home")
            '(num_joined_members . 9)
            '(join_rule . "public")
            '(room_type . "m.space")
            '(joined . t))
   (mx--row "!c1" "Channel One"
            '(num_joined_members . 2) '(join_rule . "public") '(joined . t))
   (mx--row "!c2" "Inner Circle"
            '(num_joined_members . 4) '(join_rule . "invite") '(joined . nil))
   (mx--row "!c3" "BridgeNet"
            '(num_joined_members . 30) '(join_rule . "restricted")
            '(via . ["a.example" "b.example"])
            '(topic . "bridged chit-chat") '(joined . nil))
   (mx--row "!c4" "SubSpace"
            '(num_joined_members . 1) '(join_rule . "public")
            '(room_type . "m.space") '(joined . nil))
   (mx--row "!c5" "Knockers"
            '(num_joined_members . 3) '(join_rule . "knock") '(joined . nil))))

(defun mx--hierarchy-event (rows &optional next-batch)
  "The roomHierarchy response event for \"!s1\" with ROWS."
  (append '((@ok . t))
          (list (cons '@type "roomHierarchy") (cons 'room_id "!s1"))
          (list (cons 'rooms rows))
          (when next-batch (list (cons 'next_batch next-batch)))))

(defun mx--hierarchy-vec-event (rows &optional next-batch)
  "Like `mx--hierarchy-event', with `rooms' as the wire's vector.
`json-read-from-string' hands JSON arrays to the code as vectors;
the page normalizes them itself."
  (append '((@ok . t))
          (list (cons '@type "roomHierarchy") (cons 'room_id "!s1"))
          (list (cons 'rooms (apply #'vector rows)))
          (when next-batch (list (cons 'next_batch next-batch)))))

(defun mx--page-text (page)
  "The rendered text of the PAGE buffer."
  (with-current-buffer page (buffer-string)))

(defun mx--click-near (page marker label)
  "In PAGE, jump past MARKER and invoke the next LABEL button after it.
A row's own button, not another row's same-label one."
  (with-current-buffer page
    (goto-char (point-min))
    (when (search-forward marker nil t)
      (when (search-forward label nil t)
        (funcall (plist-get (text-properties-at (- (point) (length label)))
                            'action)
                 nil)))))

(defun mx--open-page (response)
  "Open the fixture page, the stub answering RESPONSE.
The ambient `elneo--rooms' and avatar caches hold the fixtures; the
display is stubbed batch-safe.  The page buffer lands in `mx--page'."
  (setq mx--popped nil)
  (let ((mx--response response))
    (cl-letf (((symbol-function 'elneo-server--call) #'mx--capture)
              ((symbol-function 'elneo-server-live-p) (lambda (_p) t))
              ((symbol-function 'elneo-server--daemon-protocol) (lambda (_p) 18))
              ((symbol-function 'pop-to-buffer)
               (lambda (b &optional _a) (setq mx--popped b))))
      (setq mx--page (elneo-space-browse "mxtest" "!s1")))))

(defun mx--close-page ()
  "Kill the fixture page."
  (when (buffer-live-p mx--page)
    (kill-buffer mx--page))
  (setq mx--page nil))

(defmacro mx--for-old-daemon (version &rest body)
  "Run BODY with a \"live\" daemon speaking VERSION's protocol."
  `(cl-letf (((symbol-function 'elneo-server-live-p) (lambda (_p) t))
             ((symbol-function 'elneo-server--daemon-protocol)
              (lambda (_p) ,version)))
     ,@body))

(defun mx--overview (room &optional anon)
  "ROOM's settings overview rendered into a string.
The same binding shape the C-c ? help window gives the render.
ANON turns anonymous on for the render's buffer — the mode's value
is buffer-local, so only the render's own buffer setting counts."
  (with-temp-buffer
    (when anon (setq-local elneo-anon-mode t))
    (let ((standard-output (current-buffer)))
      (cl-letf (((symbol-function 'elneo-room--buffer-for)
                 (lambda (_p _r) 'no-buffer)))
        (elneo-room-settings--render room)))
    (buffer-string)))

(defvar mx--overview-room
  (list :profile "mxtest" :room-id "!room" :display-name "Ops"
        :room-state "joined" :topic "ops" :alias "#ops:example.org"
        :encrypted nil :direct nil :space nil :unread 0 :highlights 0
        :notification-mode "all_messages"))

(let ((pass 0) (fail 0))
  (defun mx-check (label got expected)
    (if (equal got expected)
        (progn (cl-incf pass) (message "ok: %s" label))
      (cl-incf fail)
      (message "FAIL: %s — got %S, expected %S" label got expected)))

  ;; --- the wrappers: the wire payloads

  (mx-check "wrapper: getRoomHierarchy payload"
            (cdar (mx--with-capture
                   (elneo-space-hierarchy "p" "!s1" nil #'ignore)))
            '((@type . "getRoomHierarchy") (room_id . "!s1")))

  (mx-check "wrapper: getRoomHierarchy carries from"
            (cdar (mx--with-capture
                   (elneo-space-hierarchy "p" "!s1" "tok:hs" #'ignore)))
            '((@type . "getRoomHierarchy") (room_id . "!s1")
              (from . "tok:hs")))

  (mx-check "wrapper: getRoomSpaces payload"
            (cdar (mx--with-capture (elneo-room-spaces "p" "!r1" #'ignore)))
            '((@type . "getRoomSpaces") (room_id . "!r1")))

  ;; --- the old-daemon guard

  (mx-check "old daemon: browsing refuses (17)"
            (and (eq (condition-case err
                         (mx--for-old-daemon 17
                           (elneo-space-browse "mxtest" "!s1"))
                       (user-error 'old-daemon))
                     'old-daemon)
                 t)
            t)

  (mx-check "old daemon: browsing refuses an unknown protocol"
            (and (eq (condition-case err
                         (mx--for-old-daemon nil
                           (elneo-space-browse "mxtest" "!s1"))
                       (user-error 'old-daemon))
                     'old-daemon)
                 t)
            t)

  ;; --- the page: the full listing and its buttons.
  ;; One registry survives the whole section — the buttons re-render
  ;; from it, the fixture records land there.

  (let ((elneo--rooms (make-hash-table :test 'equal))
        (elneo-client--avatar-cache (make-hash-table :test 'equal))
        (elneo-client--avatar-pending (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          ;; Channel One's registry record precedes the render: the
          ;; [Open] button carries the record it was rendered with.
          (puthash (cons "mxtest" "!c1")
                   (list :profile "mxtest" :room-id "!c1"
                         :room-state "joined" :display-name "Channel One")
                   elneo--rooms)
          (mx--open-page (mx--hierarchy-event mx--rows))

          (mx-check "page: the command displays the page"
                    mx--popped mx--page)
          (mx-check "page: renamed to the space's name"
                    (buffer-name mx--page) "*Matrix Space: Ops Space*")

          (let ((text (mx--page-text mx--page)))
            (mx-check "page: the header names the space"
                      (and (string-search "Matrix space Ops Space" text) t) t)
            (mx-check "page: the room id fact"
                      (and (string-search "Room id:       !s1" text) t) t)
            (mx-check "page: the alias fact"
                      (and (string-search "Alias:         #ops:example.org" text) t) t)
            (mx-check "page: the topic fact"
                      (and (string-search "Topic:         Ops home" text) t) t)
            (mx-check "page: the member count fact"
                      (and (string-search "Members:       9" text) t) t)
            (mx-check "page: the space's own row is the header, not a row"
                      (string-search "Ops Space (9" text) nil)
            (mx-check "page: a joined room row reads its member count"
                      (and (string-search "Channel One (2 members)" text) t) t)
            (mx-check "page: invite-only says so, no button follows"
                      (and (string-search "Inner Circle (4 members) (invite-only)\n"
                                          text)
                           t) t)
            (mx-check "page: restricted carries the hint and [Join]"
                      (and (string-search "BridgeNet (30 members) (restricted) [Join]" text)
                           t) t)
            (mx-check "page: a child space carries [Browse]"
                      (and (string-search "SubSpace (1 member) [Browse]" text) t) t)
            (mx-check "page: a knock rule is the hint, no button"
                      (and (string-search "Knockers (3 members) (knock)\n" text) t) t)
            (mx-check "page: a joined room offers [Open]"
                      (and (string-search "Channel One (2 members) [Open]" text) t) t)
            (mx-check "page: one page, no [more]"
                      (string-search "[more]" text) nil)
            (mx-check "page: the topic line rides under its row"
                      (and (string-search "\n      " text) t) t))

          ;; A failed join: echo area, listing unchanged.
          (let ((before (mx--page-text mx--page)))
            (cl-letf (((symbol-function 'elneo-join-room)
                       (lambda (_p _id cb &optional _via)
                         (funcall cb "mxtest" '((@ok . nil) (@error . "not allowed")))))
                      ((symbol-function 'message) (lambda (&rest _) nil))
                      ((symbol-function 'pop-to-buffer)
                       (lambda (b &optional _a) (setq mx--popped b))))
              (mx--click-near mx--page "BridgeNet" "[Join]"))
            (mx-check "page: a failed join leaves the listing"
                      (equal before (mx--page-text mx--page)) t))

          ;; [Join] on a joinable row: the ok re-renders it [Open] off
          ;; the record the seeded updateRoom left in the registry.
          (let ((join-args nil))
            (cl-letf (((symbol-function 'elneo-join-room)
                       (lambda (p id cb &optional via)
                         (setq join-args (cons p (cons id via)))
                         (puthash (cons p "!c3")
                                  (list :profile p :room-id "!c3"
                                        :room-state "joined"
                                        :display-name "BridgeNet")
                                  elneo--rooms)
                         (funcall cb p '((@ok . t) (room_id . "!c3")))))
                      ((symbol-function 'pop-to-buffer)
                       (lambda (b &optional _a) (setq mx--popped b))))
              (mx--click-near mx--page "BridgeNet" "[Join]"))
            (mx-check "page: [Join] joins through elneo-join-room with the row's via"
                      join-args '("mxtest" "!c3" "a.example" "b.example"))
            (mx-check "page: the joined row re-rendered [Open]"
                      (and (string-search "BridgeNet (30 members) (restricted) [Open]"
                                          (mx--page-text mx--page))
                           t) t))

          ;; [Open] on a joined row, wired to the registry record.
          (let ((opened nil))
            (cl-letf (((symbol-function 'elneo-room-open)
                       (lambda (room &optional _stay) (setq opened room))))
              (mx--click-near mx--page "Channel One" "[Open]"))
            (mx-check "page: [Open] opens the record"
                      (plist-get opened :room-id) "!c1"))

          ;; [Browse] on a child space row, the space page's own entry.
          (let ((browsed nil))
            (cl-letf (((symbol-function 'elneo-space-browse)
                       (lambda (p room-id) (setq browsed (cons p room-id)))))
              (mx--click-near mx--page "SubSpace" "[Browse]"))
            (mx-check "page: [Browse] browses the child space"
                      browsed '("mxtest" . "!c4"))))
      (mx--close-page)))

  ;; The avatar cell: the picture when the mxc is cached, the colored
  ;; initial for a room without one, the fetch for an uncached one.

  (let ((elneo-client--avatar-cache (make-hash-table :test 'equal))
        (elneo-client--avatar-pending (make-hash-table :test 'equal))
        (elneo--rooms (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          ;; The cached avatar on a graphic session: the picture cell.
          (puthash "mxc://hs/space-av" "/cache/av.png"
                   elneo-client--avatar-cache)
          (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                    ((symbol-function 'default-font-height) (lambda () 17))
                    ((symbol-function 'default-font-width) (lambda () 8))
                    ((symbol-function 'create-image)
                     (lambda (_f _t _d &rest _args) (list 'image 'fake)))
                    ((symbol-function 'elneo-client-fetch-avatar)
                     (lambda (&rest _) (error "a cached avatar must not fetch"))))
            (mx--open-page
             (mx--hierarchy-event
              (list (mx--row "!c6" "With Avatar"
                             '(avatar_url . "mxc://hs/space-av")
                             '(join_rule . "public") '(joined . nil))
                    (mx--row "!c7" "Initialed" '(join_rule . "public")
                             '(joined . nil)))))
            (with-current-buffer mx--page
              (goto-char (point-max))
              (search-backward "With Avatar")
              (backward-char 3)  ; the two image cells and the separator
              (mx-check "page: the picture cell renders"
                        (get-text-property (point) 'display)
                        (list 'image 'fake))))
          (mx--close-page)
          ;; The uncached avatar: the cell renders the initial and the
          ;; fetch fires (batch: the page is buried, so no re-render
          ;; races the read).
          (let ((fetched nil))
            (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                      ((symbol-function 'elneo-client-fetch-avatar)
                       (lambda (_p _m cb)
                         (setq fetched t)
                         (funcall cb "mxtest" '((@ok . t))))))
              (mx--open-page
               (mx--hierarchy-event
                (list (mx--row "!c8" "Avatar Room"
                               '(avatar_url . "mxc://hs/room-av")
                               '(join_rule . "public") '(joined . nil)))))
              (mx-check "page: an uncached avatar fetches"
                        (and fetched t) t)
              (mx-check "page: the fetch did not hold back the listing render"
                        (and (string-search "Avatar Room"
                                            (mx--page-text mx--page))
                             t) t))
            (mx--close-page)))
      (mx--close-page)))

  ;; --- pagination, an empty listing, a failed fetch

  (let ((second-payload nil))
    (mx--open-page (mx--hierarchy-event (list (mx--row "!a" "Alpha")) "tok2"))
    (mx-check "page: [more] rides a next_batch"
              (and (string-search "[more]" (mx--page-text mx--page)) t) t)
    (cl-letf (((symbol-function 'elneo-server--call)
               (lambda (p cmd cb)
                 (setq second-payload cmd)
                 (funcall cb p (mx--hierarchy-event (list (mx--row "!b" "Beta"))))))
              ((symbol-function 'pop-to-buffer)
               (lambda (b &optional _a) (setq mx--popped b))))
      (mx--click-near mx--page "Alpha" "[more]"))
    (let ((text (mx--page-text mx--page)))
      (mx-check "page: the second page appends"
                (and (string-search "Beta" text)
                     (string-search "Alpha" text) t) t)
      (mx-check "page: a complete listing has no [more]"
                (string-search "[more]" text) nil))
    (mx-check "page: the next fetch carries the stored next_batch"
              (cdr (assoc 'from second-payload)) "tok2")
    (mx--close-page))

  ;; The wire shape: JSON arrays arrive as elisp vectors, and the
  ;; render loops (cl-remove-if, dolist) crash on them.  The page
  ;; normalizes every arrival.
  (mx--open-page (mx--hierarchy-vec-event mx--rows))
  (let ((text (mx--page-text mx--page)))
    (mx-check "page: vector wire rooms render"
              (and (string-search "Channel One" text)
                   (string-search "Knockers" text) t) t)
    (mx-check "page: vector wire rooms store as a list"
              (listp (buffer-local-value 'elneo-space-page--rooms
                                         mx--page))
              t)
    (mx-check "page: vector wire rooms still split off the space row"
              (and (string-search "Ops Space" text) t)
              t))
  (mx--close-page)

  (let ((second-payload nil))
    (mx--open-page (mx--hierarchy-vec-event (list (mx--row "!a" "Alpha")) "tokV"))
    (cl-letf (((symbol-function 'elneo-server--call)
               (lambda (p cmd cb)
                 (setq second-payload cmd)
                 (funcall cb p (mx--hierarchy-vec-event (list (mx--row "!b" "Beta"))))))
              ((symbol-function 'pop-to-buffer)
               (lambda (b &optional _a) (setq mx--popped b))))
      (mx--click-near mx--page "Alpha" "[more]"))
    (mx-check "page: a second vector page appends as lists"
              (and (string-search "Beta" (mx--page-text mx--page))
                   (string-search "Alpha" (mx--page-text mx--page))
                   (listp (buffer-local-value 'elneo-space-page--rooms
                                              mx--page))
                   (> (length (buffer-local-value
                               'elneo-space-page--rooms mx--page)) 1))
              t)
    (mx--close-page))

  (mx--open-page (mx--hierarchy-event nil))
  (mx-check "page: an empty listing is said"
            (and (string-search "The space offers no rooms."
                                (mx--page-text mx--page))
                 t) t)
  (mx--close-page)

  (mx--open-page '((@ok . nil) (@error . "M_FORBIDDEN")))
  (mx-check "page: a failed fetch shows the denial"
            (and (string-search "The space's rooms are not available: M_FORBIDDEN"
                                (mx--page-text mx--page))
                 t) t)
  (mx-check "page: a failed fetch lists nothing"
            (string-search "[Join]" (mx--page-text mx--page)) nil)

  ;; `g' stands the failure down and refetches from the top.
  (with-current-buffer mx--page
    (let ((fetches 0))
      (cl-letf (((symbol-function 'elneo-server--call)
                 (lambda (p cmd cb)
                   (setq fetches (1+ fetches))
                   (funcall cb p (mx--hierarchy-event mx--rows))))
                ((symbol-function 'pop-to-buffer)
                 (lambda (_b &optional _a) nil)))
        (elneo-space-page-refresh))
      (mx-check "page: g refetched once" fetches 1))
    (mx-check "page: g clears the failure"
              (and (string-search "Channel One" (mx--page-text mx--page)) t) t))
  (mx--close-page)

  ;; --- the room bar's entry: b on a row

  (let ((elneo--rooms (make-hash-table :test 'equal)) browsed)
    (puthash (cons "a" "!s1")
             (list :profile "a" :room-id "!s1" :space t :room-state "joined"
                   :display-name "Ops Space")
             elneo--rooms)
    (puthash (cons "a" "!c1")
             (list :profile "a" :room-id "!c1" :display-name "Plain")
             elneo--rooms)
    (let ((buf (generate-new-buffer " *mx-bar-space*")))
      (with-current-buffer buf
        (elneo-room-bar-mode)
        (let ((inhibit-read-only t))
          (dolist (record (list (elneo-room-get "a" "!s1")
                                (elneo-room-get "a" "!c1")))
          (insert "  ")
          (let ((start (point)))
            (insert (or (plist-get record :display-name)
                        (plist-get record :room-id))
                    "\n")
            (add-text-properties
             start (1- (point))
             (list 'elneo-room-key
                   (cons (plist-get record :profile)
                         (plist-get record :room-id)))))))
      (unwind-protect
          (progn
            (mx-check "bar: b is bound"
                      (with-current-buffer buf (key-binding (kbd "b")))
                      #'elneo-room-bar-browse-space-at-point)
            (with-current-buffer buf
              (goto-char (point-min))
              (search-forward "Ops Space")
              (cl-letf (((symbol-function 'elneo-space-browse)
                         (lambda (p room-id) (setq browsed (cons p room-id)))))
                (call-interactively #'elneo-room-bar-browse-space-at-point)))
            (mx-check "bar: b on a space row browses it"
                      browsed '("a" . "!s1"))
            (with-current-buffer buf
              (goto-char (point-min))
              (search-forward "Plain")
              (mx-check "bar: b on a plain row refuses"
                        (and (eq (condition-case err
                                   (call-interactively
                                    #'elneo-room-bar-browse-space-at-point)
                                 (user-error 'not-a-space))
                                 'not-a-space)
                             t)
                        t)))
        (kill-buffer buf))))

  ;; --- the room overview's Spaces line

  (let ((parents
         (list (list '(room_id . "!sp2") '(name . "Other Space")
                     '(room_type . "m.space") '(join_rule . "unknown")
                     '(joined . t))
               (list '(room_id . "!sp3") '(room_type . "m.space")
                     '(join_rule . "unknown") '(joined . nil))))
        (room mx--overview-room))
    (let ((elneo-room--spaces (make-hash-table :test 'equal)))
      (puthash "!room" parents elneo-room--spaces)
      (let ((text (mx--overview room)))
        (mx-check "overview: the Spaces line lists the parents"
                  (and (string-search "Spaces:         " text)
                       (string-search "Other Space" text) t)
                  t)
        (mx-check "overview: an unnamed parent renders by id"
                  (and (string-search "!sp3" text) t) t))
      (let ((browsed nil))
        (with-temp-buffer
          (let ((standard-output (current-buffer)))
            (cl-letf (((symbol-function 'elneo-room--buffer-for)
                       (lambda (_p _r) 'no-buffer)))
              (elneo-room-settings--render room))
            (goto-char (point-min))
            (search-forward "Other Space")
            (cl-letf (((symbol-function 'elneo-space-browse)
                       (lambda (p room-id) (setq browsed (cons p room-id)))))
              (funcall (plist-get (text-properties-at (- (point) 11))
                                  'action)
                       nil))))
        (mx-check "overview: the Spaces button opens the page"
                  browsed '("mxtest" . "!sp2")))
      ;; The parents are other rooms' names: anon loses the line.
      (let ((text (mx--overview room 'anon)))
        (mx-check "overview: anon hides the Spaces line"
                  (string-search "  Spaces:" text) nil)))
    (let ((elneo-room--spaces (make-hash-table :test 'equal)))
      (mx-check "overview: no parents, no Spaces line"
                (string-search "  Spaces:" (mx--overview room)) nil)))

  ;; --- the space fact: title and label
  ;; "Matrix room" vs "Matrix space" by the record's :space; the
  ;; wordier "Is a space:" label (the two directions are easy to
  ;; conflate with the Spaces line).

  (mx-check "overview: a room headlines Matrix room"
            (and (string-search "Matrix room Ops\n" (mx--overview mx--overview-room)) t)
            t)
  (mx-check "overview: a space headlines Matrix space"
            (and (string-search "Matrix space Ops\n"
                                (mx--overview
                                 (plist-put (copy-sequence mx--overview-room) :space t)))
                 t)
            t)
  (mx-check "overview: the Is a space fact line"
            (and (string-search "  Is a space:    no\n"
                                (mx--overview mx--overview-room))
                 t)
            t)

  ;; A space row's fact carries the [rooms] browse into its own
  ;; discovery page; a room row (and anon) get none.
  (let ((browsed nil))
    (with-temp-buffer
      (let ((standard-output (current-buffer)))
        (cl-letf (((symbol-function 'elneo-room--buffer-for)
                   (lambda (_p _r) 'no-buffer))
                  ((symbol-function 'elneo-space-browse)
                   (lambda (p r) (setq browsed (cons p r)))))
          (elneo-room-settings--render
           (plist-put (copy-sequence mx--overview-room) :space t))
          (goto-char (point-min))
          (search-forward "[rooms]")
          (funcall (plist-get (text-properties-at (- (point) 7))
                              'action)
                   nil)))
      (mx-check "overview: the space fact's [rooms] opens the page"
                browsed '("mxtest" . "!room")))
    (mx-check "overview: a room row has no [rooms]"
              (string-search "[rooms]" (mx--overview mx--overview-room)) nil)
    (mx-check "overview: anon hides the [rooms] button"
              (string-search "[rooms]"
                             (mx--overview
                              (plist-put (copy-sequence mx--overview-room) :space t)
                              'anon))
              nil))

  ;; --- the upgrade links: "Upgraded to" / "Continues" fact lines
  ;; (protocol 19).  Each `[open]' hands its target to the matrix.to
  ;; handler — the registry's record opens, an unknown room offers to
  ;; join; anon hides both lines (other rooms' ids).

  (let ((room (plist-put (copy-sequence mx--overview-room)
                         :upgraded-to "!new:hs")))
    (mx-check "overview: the Upgraded to fact line"
              (and (string-search "  Upgraded to:   !new:hs" (mx--overview room)) t)
              t)
    (let ((opened nil))
      (with-temp-buffer
        (let ((standard-output (current-buffer)))
          (cl-letf (((symbol-function 'elneo-room--buffer-for)
                     (lambda (_p _r) 'no-buffer))
                    ((symbol-function 'elneo-room--open-matrix-link)
                     (lambda (p target) (setq opened (cons p target)))))
            (elneo-room-settings--render room)
            (goto-char (point-min))
            (search-forward "[open]")
            (funcall (plist-get (text-properties-at (- (point) 6))
                                'action)
                     nil))))
      (mx-check "overview: the Upgraded to button opens the successor"
                opened '("mxtest" . "!new:hs"))))

  (let ((room (plist-put (copy-sequence mx--overview-room)
                         :upgraded-from "!old:hs")))
    (mx-check "overview: the Continues fact line"
              (and (string-search "  Continues:     !old:hs" (mx--overview room)) t)
              t)
    (mx-check "overview: Continues also carries an [open]"
              (and (string-search "[open]" (mx--overview room)) t)
              t))

  (mx-check "overview: no upgrade links, no fact lines"
            (and (string-search "Upgraded to" (mx--overview mx--overview-room))
                 nil)
            nil)
  (let* ((room (append mx--overview-room
                       '(:upgraded-to "!new:hs" :upgraded-from "!old:hs")))
         (text (mx--overview room 'anon)))
    (mx-check "overview: anon hides the upgrade lines"
              (string-search "Upgraded to" text)
              nil))

  ;; --- the Spaces cache fetch

  (let ((elneo-room--spaces (make-hash-table :test 'equal))
        (elneo-room--spaces-pending (make-hash-table :test 'equal))
        (payloads nil)
        (parents
         (list (list '(room_id . "!sp2") '(name . "Other Space")
                     '(room_type . "m.space") '(join_rule . "unknown")
                     '(joined . t))))
        (buf (generate-new-buffer " *mx-spaces-room*")))
    (with-current-buffer buf
      (elneo-room-mode)
      (setq-local elneo-room--profile "mxtest")
      (setq-local elneo-room--room-id "!room"))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (cl-letf (((symbol-function 'elneo-server--daemon-protocol)
                       (lambda (_p) 18))
                      ((symbol-function 'elneo-room-spaces)
                       (lambda (p room-id cb)
                         (push (cons p room-id) payloads)
                         (funcall cb p (list '(@ok . t)
                                             '(room_id . "!room")
                                             (cons 'spaces parents))))))
              (elneo-room--fetch-spaces)))
          (mx-check "overview: the fetch asks for this room"
                    payloads '(("mxtest" . "!room")))
          (with-current-buffer buf
            (mx-check "overview: the parents land in the cache"
                      (gethash "!room" elneo-room--spaces) parents))
          (mx-check "overview: the fetch is no longer pending"
                    (gethash "!room" elneo-room--spaces-pending) nil)

          ;; A failed fetch leaves nothing cached (the next opening
          ;; retries through the freed pending path); an earlier
          ;; success's rows survive it.  The failure watched in
          ;; isolation: no prior rows.
          (remhash "!room" elneo-room--spaces)
          (with-current-buffer buf
            (cl-letf (((symbol-function 'elneo-server--daemon-protocol)
                       (lambda (_p) 18))
                      ((symbol-function 'elneo-room-spaces)
                       (lambda (_p _r cb)
                         (funcall cb "mxtest" '((@ok . nil) (@error . "x"))))))
              (elneo-room--fetch-spaces)))
          (with-current-buffer buf
            (mx-check "overview: a failed fetch keeps nothing"
                      (gethash "!room" elneo-room--spaces) nil))

          ;; An older daemon: no fetch at all.
          (with-current-buffer buf
            (cl-letf (((symbol-function 'elneo-server--daemon-protocol)
                       (lambda (_p) 17))
                      ((symbol-function 'elneo-room-spaces)
                       (lambda (&rest _) (error "must not run"))))
              (elneo-room--fetch-spaces)))
          (with-current-buffer buf
            (mx-check "overview: an old daemon fetches nothing"
                      payloads '(("mxtest" . "!room")))))
      (kill-buffer buf)))

  ;; The wire shape there too: the roomSpaces event's `spaces' arrives
  ;; as a vector; the render's dolist needs a proper list.
  (let ((elneo-room--spaces (make-hash-table :test 'equal))
        (elneo-room--spaces-pending (make-hash-table :test 'equal))
        (buf (generate-new-buffer " *mx-spaces-room*")))
    (with-current-buffer buf
      (elneo-room-mode)
      (setq-local elneo-room--profile "mxtest")
      (setq-local elneo-room--room-id "!room"))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (cl-letf (((symbol-function 'elneo-server--daemon-protocol)
                       (lambda (_p) 18))
                      ((symbol-function 'elneo-room-spaces)
                       (lambda (p _room-id cb)
                         (funcall cb p (list '(@ok . t)
                                             '(room_id . "!room")
                                             (cons 'spaces
                                                   (vector
                                                    (list '(room_id . "!sp2")
                                                          '(name . "Vec Space")
                                                          '(room_type . "m.space")
                                                          '(join_rule . "unknown")
                                                          '(joined . t)))))))))
              (elneo-room--fetch-spaces)))
          (mx-check "overview: vector wire spaces store as a list"
                    (listp (gethash "!room" elneo-room--spaces)) t)
          (mx-check "overview: the vector parents render"
                    (and (string-search "Vec Space"
                                        (mx--overview mx--overview-room))
                         t) t))
      (kill-buffer buf)))

  ;; --- matrix.to: the fragments and the interception

  (mx-check "link: a room id target, via tail stripped"
            (elneo-room--matrix-to-target
             "https://matrix.to/#/!id:example.org?via=other.example")
            "!id:example.org")
  (mx-check "link: the link form carries the via servers"
            (elneo-room--matrix-to-link
             "https://matrix.to/#/!id:example.org?via=other.example")
            '("!id:example.org" . ("other.example")))
  (mx-check "link: two via entries come in order"
            (elneo-room--matrix-to-link
             "https://matrix.to/#/!id:example.org?via=a&via=b")
            '("!id:example.org" . ("a" "b")))
  (mx-check "link: mixed query params keep only via="
            (elneo-room--matrix-to-link
             "https://matrix.to/#/!id:example.org?via=a&sharer=@u:hs&via=b")
            '("!id:example.org" . ("a" "b")))
  (mx-check "link: no tail reads an empty via"
            (elneo-room--matrix-to-link "https://matrix.to/#/!id:example.org")
            '("!id:example.org"))
  (mx-check "link: the percent-encoded alias target"
            (elneo-room--matrix-to-target
             "https://matrix.to/#/%23ops:example.org")
            "#ops:example.org")
  (mx-check "link: an unencoded alias target"
            (elneo-room--matrix-to-target "https://matrix.to/#/#ops:example.org")
            "#ops:example.org")
  (mx-check "link: event anchors stay browser links"
            (elneo-room--matrix-to-target "https://matrix.to/#/$evt:example.org")
            nil)
  (mx-check "link: user links stay browser links"
            (elneo-room--matrix-to-target "https://matrix.to/#/@bob:example.org")
            nil)
  (mx-check "link: a non-matrix.to URL is nobody's room"
            (elneo-room--matrix-to-target "https://example.com/dir") nil)

  (let ((elneo--rooms (make-hash-table :test 'equal)))
    (puthash (cons "mxtest" "!r1")
             (list :profile "mxtest" :room-id "!r1"
                   :alias "#ops:example.org" :display-name "Ops")
             elneo--rooms)
    (mx-check "lookup: a room id answers"
              (plist-get (elneo-room--lookup-link-target "mxtest" "!r1")
                         :room-id)
              "!r1")
    (mx-check "lookup: the canonical alias answers"
              (plist-get (elneo-room--lookup-link-target "mxtest" "#ops:example.org")
                         :room-id)
              "!r1")
    (mx-check "lookup: an unknown room id has no record"
              (elneo-room--lookup-link-target "mxtest" "!zzz") nil))

  ;; The interception: a known room opens, an unknown one joins on
  ;; consent, a known space opens its page, a declined join falls
  ;; through to the browser, a failed join still handled the link.
  (let ((elneo--rooms (make-hash-table :test 'equal)) opened browsed)
    (puthash (cons "mxtest" "!r1")
             (list :profile "mxtest" :room-id "!r1" :display-name "Ops")
             elneo--rooms)
    (puthash (cons "mxtest" "!r2")
             (list :profile "mxtest" :room-id "!r2" :space t
                   :room-state "joined")
             elneo--rooms)
    (cl-letf (((symbol-function 'elneo-room-open)
               (lambda (r &optional _s) (setq opened r)))
              ((symbol-function 'elneo-space-browse)
               (lambda (p r) (setq browsed (cons p r)))))
      (mx-check "link: a known room handles the link"
                (elneo-room--open-matrix-link "mxtest" "!r1") t)
      (mx-check "link: the opened record is the room's"
                (plist-get opened :room-id) "!r1")
      (mx-check "link: a known space handles the link"
                (elneo-room--open-matrix-link "mxtest" "!r2") t)
      (mx-check "link: the known space's page opened"
                browsed '("mxtest" . "!r2")))

    (let ((join-args nil))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_q) t))
                ((symbol-function 'elneo-join-room)
                 (lambda (p id cb &optional via)
                   (setq join-args (list p id via))
                   (puthash (cons p "!new")
                            (list :profile p :room-id "!new"
                                  :room-state "joined")
                            elneo--rooms)
                   (funcall cb p '((@ok . t) (room_id . "!new")))))
                ((symbol-function 'elneo-room-open)
                 (lambda (r &optional _s) (setq opened r))))
        (let ((handled (elneo-room--open-matrix-link
                        "mxtest" "!new" '("alt.example"))))
          (mx-check "link: an unknown room joins" handled t)
          (mx-check "link: the join went to the daemon with the via"
                    join-args '("mxtest" "!new" ("alt.example")))
          (mx-check "link: the joined room opened"
                    (plist-get opened :room-id) "!new"))))

    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_q) t))
              ((symbol-function 'elneo-join-room)
               (lambda (p id cb &optional _via)
                 (puthash (cons p "!newsp")
                          (list :profile p :room-id "!newsp"
                                :room-state "joined" :space t)
                          elneo--rooms)
                 (funcall cb p '((@ok . t) (room_id . "!newsp")))))
              ((symbol-function 'elneo-space-browse)
               (lambda (p room-id) (setq browsed (cons p room-id)))))
      (mx-check "link: an unknown space joins"
                (elneo-room--open-matrix-link "mxtest" "!newsp") t)
      (mx-check "link: the joined space's page opened"
                browsed '("mxtest" . "!newsp")))

    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_q) nil)))
      (mx-check "link: a declined join falls through"
                (elneo-room--open-matrix-link "mxtest" "!zz") nil))))

  ;; --- joining from a pasted link (the anywhere command)

  ;; The target reading: matrix.to URLs parse through the room
  ;; fragment machinery (their via servers come along), bare room ids
  ;; and aliases pass through, and everything else — user links,
  ;; event anchors, non-links — refuses.
  (mx-check "join-link: a matrix.to URL reads room id and via"
            (elneo-join-matrix-to--link " https://matrix.to/#/!id:hs?via=q ")
            '("!id:hs" . ("q")))
  (mx-check "join-link: an encoded alias URL reads the alias, no via"
            (elneo-join-matrix-to--link
             "https://matrix.to/#/%23ops:example.org")
            '("#ops:example.org"))
  (mx-check "join-link: a bare id passes through"
            (elneo-join-matrix-to--link "!id:hs") '("!id:hs"))
  (mx-check "join-link: a bare alias passes through"
            (elneo-join-matrix-to--link "#ops:hs") '("#ops:hs"))
  (mx-check "join-link: an event anchor is nobody's join"
            (elneo-join-matrix-to--link "https://matrix.to/#/$e:hs") nil)

  ;; The command wraps `elneo-room--open-matrix-link' (with the link's
  ;; via list); the interactive form reads the profile and the link,
  ;; junk input is refused.
  (let ((handled nil))
    (cl-letf (((symbol-function 'elneo-room--open-matrix-link)
               (lambda (p target &optional via) (setq handled (list p target via)))))
      (cl-letf (((symbol-function 'elneo-room--read-profile-anywhere)
                 (lambda () "mxtest"))
                ((symbol-function 'read-string)
                 (lambda (_p) " https://matrix.to/#/!id2:hs?via=q ")))
        (call-interactively #'elneo-join-matrix-to))
      (mx-check "join-link: interactive reads profile, link, via"
                handled '("mxtest" "!id2:hs" ("q")))
      (setq handled nil)
      (elneo-join-matrix-to "mxtest" "#ops:hs")
      (mx-check "join-link: a bare alias links the same, via-less"
                handled '("mxtest" "#ops:hs" nil)))
    (mx-check "join-link: a user link is refused"
              (condition-case _e
                  (progn (elneo-join-matrix-to
                          "mxtest" "https://matrix.to/#/@no:hs")
                         nil)
                (user-error t))
              t))

  ;; The plain join notices a space too: its seeded record opens the
  ;; space discovery page, never the room buffer.
  (let ((elneo--rooms (make-hash-table :test 'equal)) browsed opened)
    (puthash (cons "mxtest" "!s9")
             (list :profile "mxtest" :room-id "!s9" :room-state "joined"
                   :space t)
             elneo--rooms)
    (puthash (cons "mxtest" "!t9")
             (list :profile "mxtest" :room-id "!t9" :room-state "joined")
             elneo--rooms)
    (cl-letf (((symbol-function 'elneo-join-room)
               (lambda (p id cb)
                 (funcall cb p
                          (list '(@ok . t)
                                (cons 'room_id
                                      (pcase id
                                        ("#sp:example.org" "!s9")
                                        (_ "!t9")))))))
              ((symbol-function 'elneo-room--open)
               (lambda (&rest _) (setq opened (cons t opened))))
              ((symbol-function 'elneo-space-browse)
               (lambda (p r) (setq browsed (list p r)))))
      (elneo-room-join "mxtest" "#sp:example.org")
      (mx-check "join: a joined space opens its page"
                browsed '("mxtest" "!s9"))
      (mx-check "join: a joined space opens no room buf" opened nil)
      (elneo-room-join "mxtest" "#rooms:example.org")
      (mx-check "join: an ordinary room still opens its buffer"
                (car opened) t))
    (setq browsed nil opened nil)
    (cl-letf (((symbol-function 'elneo-join-room)
               (lambda (p _id cb)
                 (funcall cb p '((@ok . nil) (@error . "refused")))))
              ((symbol-function 'elneo-room--open)
               (lambda (&rest _) (setq opened (cons t opened))))
              ((symbol-function 'elneo-space-browse)
               (lambda (_p _r) (setq browsed t))))
      (elneo-room-join "mxtest" "#fail:example.org")
      (mx-check "join: a failed join opens neither"
                (list browsed (length opened)) '(nil 0))))

  ;; The click through the room buffer: matrix.to intercepts, plain
  ;; URLs stay with browse-url.
  (let ((buf (generate-new-buffer " *mx-link-click*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (insert (elneo-room--linkify-string
                 (concat "room link https://matrix.to/#/!s1:example.org and web "
                         "link https://example.com/page here")))
        (elneo-room-mode))
      (setq-local elneo-room--profile "mxtest")
      (setq-local elneo-room--room-id "!r0")
      (unwind-protect
          (with-current-buffer buf
            ;; A known space: the client opens it, the browser sits
            ;; out.
            (goto-char (1+ (string-match "matrix.to" (buffer-string))))
            (let ((elneo--rooms (make-hash-table :test 'equal))
                  browsed)
              (puthash (cons "mxtest" "!s1:example.org")
                       (list :profile "mxtest" :room-id "!s1:example.org"
                             :display-name "Ops Space" :space t)
                       elneo--rooms)
              (cl-letf (((symbol-function 'elneo-space-browse)
                         (lambda (p r) (setq browsed (cons p r))))
                        ((symbol-function 'browse-url)
                         (lambda (&rest _) (error "browser must not run"))))
                (elneo-room--browse-url-at-point))
              (mx-check "click: a room link opens in the client"
                        browsed '("mxtest" . "!s1:example.org")))
            ;; A plain URL: the browser takes it, the client sits out.
            (goto-char (1+ (string-match "example.com/page" (buffer-string))))
            (let ((web nil))
              (cl-letf (((symbol-function 'elneo-space-browse)
                         (lambda (&rest _) (error "must not run")))
                        ((symbol-function 'browse-url)
                         (lambda (u &optional _a) (setq web u))))
                (elneo-room--browse-url-at-point))
              (mx-check "click: a plain URL stays with the browser"
                        web "https://example.com/page")))
        (kill-buffer buf))))

  ;; Outside a room buffer there is no profile: every link browses.
  (with-temp-buffer
    (insert (elneo-room--linkify-string
             "a https://matrix.to/#/!s1:example.org anywhere"))
    (goto-char (1+ (string-match "matrix.to" (buffer-string))))
    (let ((web nil))
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (u &optional _a) (setq web u))))
        (elneo-room--browse-url-at-point)
        (mx-check "click: outside a room buffer the link browses"
                  web "https://matrix.to/#/!s1:example.org"))))

  (message "space: %d ok, %d failed" pass fail)
  (when (> fail 0) (kill-emacs 1)))

;;; space-page-test.el ends here