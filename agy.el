;;; agy.el --- Run the Antigravity CLI (agy) inside Emacs  -*- lexical-binding: t; -*-

;; Author: Ilya Finkelstein <ilya@finkelsteinlab.org>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (transient "0.7") (inheritenv "0.2"))
;; Keywords: tools, ai
;; URL: https://github.com/ifinkelstein/agy.el

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; agy.el runs Google's Antigravity CLI (`agy') in an Emacs terminal
;; buffer and lets you drive it from anywhere in Emacs: start sessions
;; per project, send regions, files and errors with their locations,
;; answer prompts, cycle agent modes, and resume past conversations.
;;
;; The design follows claude-code.el by Stephen Molitor.  Terminal
;; backends are ghostel (libghostty) and eat.
;;
;; Entry points: `agy', `agy-transient', and `agy-command-map'.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'transient)
(require 'inheritenv)

;;;; Customization

(defgroup agy nil
  "Antigravity CLI (agy) integration."
  :group 'tools
  :prefix "agy-")

(defcustom agy-program "agy"
  "Executable that starts the Antigravity CLI."
  :type 'string)

(defcustom agy-program-switches nil
  "Command-line switches passed to `agy-program' on every start.
For example \\='(\"--model=gemini-4-argon-high\").  Options chosen in
`agy-transient' are appended to these."
  :type '(repeat string))

(defcustom agy-terminal-backend 'eat
  "Terminal emulator that hosts agy sessions."
  :type '(radio (const :tag "Eat" eat)
                (const :tag "Ghostel (libghostty)" ghostel)))

(defcustom agy-start-hook nil
  "Hook run in a new agy buffer after its terminal has started."
  :type 'hook)

(defcustom agy-process-environment-functions nil
  "Abnormal hook returning extra environment variables for agy.
Each function is called with two arguments, the agy buffer name and the
directory agy starts in, and returns a list of \"VAR=VALUE\" strings.
Every session also gets AGY_BUFFER_NAME, which the hook bridge
\(see `agy-install-hooks') uses to find its buffer."
  :type 'hook)

(defcustom agy-display-window-fn #'agy-display-buffer-below
  "Function that displays a new or toggled agy buffer.
It is called with the buffer and should return the window used."
  :type 'function)

(defcustom agy-toggle-auto-select nil
  "Non-nil means select the agy window whenever it is displayed."
  :type 'boolean)

(defcustom agy-no-delete-other-windows nil
  "Non-nil means `delete-other-windows' leaves agy windows alone."
  :type 'boolean)

(defcustom agy-confirm-kill t
  "Non-nil means ask before killing agy sessions."
  :type 'boolean)

(defcustom agy-large-buffer-threshold 100000
  "Buffer size above which `agy-send-region' asks before sending it all."
  :type 'integer)

(defcustom agy-enable-notifications t
  "Non-nil means notify when an agy session finishes a turn.
Notifications come from the terminal bell, which agy rings when its
`notifications' setting is on, and from the Stop hook installed by
`agy-install-hooks'."
  :type 'boolean)

(defcustom agy-notification-function #'agy-default-notification
  "Function called with TITLE and MESSAGE strings to notify the user."
  :type 'function)

(defcustom agy-data-directory "~/.gemini/antigravity-cli/"
  "Directory where agy keeps its settings and conversation index."
  :type 'directory)

(defcustom agy-hooks-file "~/.gemini/config/hooks.json"
  "Global agy hooks file that `agy-install-hooks' edits."
  :type 'file)

(defcustom agy-sqlite-program "sqlite3"
  "SQLite shell used by `agy-resume' to read the conversation index."
  :type 'string)

(defvar agy-event-functions nil
  "Abnormal hook run when an agy lifecycle hook reaches Emacs.
Each function is called with one plist argument with keys :event (the
agy event name, such as \"Stop\"), :buffer (the agy buffer, or nil) and
:data (the hook payload parsed into a plist).  See `agy-install-hooks'.")

(defvar agy-command-history nil
  "Minibuffer history of prompts sent with `agy-send-command'.")

;;;; Internal state

(defconst agy--root (file-name-directory (or load-file-name buffer-file-name))
  "Directory agy.el was loaded from.")

(defvar-local agy--directory nil
  "Directory this agy session runs in; non-nil marks an agy buffer.")

(defvar-local agy--instance nil
  "Instance name of this agy session, or nil for the first one.")

(defvar-local agy--backend nil
  "Terminal backend this agy buffer was started with.")

(defvar agy--remembered-buffers (make-hash-table :test #'equal)
  "Map from directory to the agy buffer last chosen for it.")

(defvar agy--models-cache nil
  "Alist of (ID . DESCRIPTION) from `agy models', fetched once.")

;;;; Terminal backends

(cl-defgeneric agy--term-make (backend buffer program switches)
  "Run PROGRAM with SWITCHES in BUFFER using terminal BACKEND.")

(cl-defgeneric agy--term-send (backend string)
  "Send STRING as raw input to the current buffer's BACKEND terminal.")

(cl-defgeneric agy--term-paste (backend string)
  "Send STRING to the current buffer's BACKEND terminal as a paste.")

(cl-defgeneric agy--term-configure (backend)
  "Configure the current buffer's BACKEND terminal for agy.")

(cl-defgeneric agy--term-read-only-p (backend)
  "Return non-nil if the current BACKEND terminal is read-only.")

(cl-defgeneric agy--term-set-read-only (backend flag)
  "Make the current BACKEND terminal read-only if FLAG, else interactive.")

(cl-defgeneric agy--term-kill (backend buffer)
  "Stop the BACKEND terminal process in BUFFER and kill BUFFER.")

;;;;; ghostel

(defvar ghostel--process)
(defvar ghostel--input-mode)
(defvar ghostel-buffer-name-function)
(defvar ghostel-kill-buffer-on-exit)
(defvar ghostel-query-before-killing)
(declare-function ghostel-exec "ghostel" (buffer program &optional args identity))
(declare-function ghostel-send-string "ghostel" (string))
(declare-function ghostel-paste-string "ghostel" (string))
(declare-function ghostel-readonly-enter "ghostel" ())
(declare-function ghostel-readonly-exit "ghostel" ())

(cl-defmethod agy--term-make ((_backend (eql ghostel)) buffer program switches)
  "Run PROGRAM with SWITCHES in BUFFER under ghostel."
  (require 'ghostel)
  (inheritenv (ghostel-exec buffer program switches)))

(cl-defmethod agy--term-send ((_backend (eql ghostel)) string)
  "Send STRING to the ghostel terminal."
  (ghostel-send-string string))

(cl-defmethod agy--term-paste ((_backend (eql ghostel)) string)
  "Paste STRING into the ghostel terminal."
  (ghostel-paste-string string))

(cl-defmethod agy--term-configure ((_backend (eql ghostel)))
  "Keep the agy buffer name, kill it on exit, and route the bell."
  (setq-local ghostel-buffer-name-function nil)
  (setq-local ghostel-kill-buffer-on-exit t)
  (setq-local ghostel-query-before-killing nil)
  (let ((buffer (current-buffer)))
    (setq-local ring-bell-function (lambda () (agy--notify buffer)))))

(cl-defmethod agy--term-read-only-p ((_backend (eql ghostel)))
  "Return non-nil in ghostel's copy or Emacs mode."
  (memq ghostel--input-mode '(copy emacs)))

(cl-defmethod agy--term-set-read-only ((_backend (eql ghostel)) flag)
  "Enter ghostel's read-only mode if FLAG, else leave it."
  (if flag (ghostel-readonly-enter) (ghostel-readonly-exit)))

(cl-defmethod agy--term-kill ((_backend (eql ghostel)) buffer)
  "Kill the ghostel process in BUFFER, then BUFFER."
  (with-current-buffer buffer
    (when (process-live-p ghostel--process)
      (delete-process ghostel--process)))
  (when (buffer-live-p buffer)
    (let ((kill-buffer-query-functions nil))
      (kill-buffer buffer))))

;;;;; eat

(defvar eat-terminal)
(defvar eat--semi-char-mode)
(defvar eat-kill-buffer-on-exit)
(defvar eat-enable-directory-tracking)
(defvar eat-enable-shell-prompt-annotation)
(declare-function eat-mode "eat" ())
(declare-function eat-exec "eat" (buffer name command startfile switches))
(declare-function eat-term-send-string "eat" (terminal string))
(declare-function eat-term-send-string-as-yank "eat" (terminal args))
(declare-function eat-term-set-parameter "eat" (terminal parameter value))
(declare-function eat-emacs-mode "eat" ())
(declare-function eat-semi-char-mode "eat" ())
(declare-function eat-kill-process "eat" ())

(cl-defmethod agy--term-make ((_backend (eql eat)) buffer program switches)
  "Run PROGRAM with SWITCHES in BUFFER under eat."
  (require 'eat)
  (with-current-buffer buffer
    (eat-mode))
  (inheritenv
    (eat-exec buffer (buffer-name buffer) program nil switches)))

(cl-defmethod agy--term-send ((_backend (eql eat)) string)
  "Send STRING to the eat terminal."
  (eat-term-send-string eat-terminal string))

(cl-defmethod agy--term-paste ((_backend (eql eat)) string)
  "Paste STRING into the eat terminal."
  (eat-term-send-string-as-yank eat-terminal (list string)))

(cl-defmethod agy--term-configure ((_backend (eql eat)))
  "Kill the eat buffer on exit, drop shell features, and route the bell."
  (setq-local eat-kill-buffer-on-exit t)
  (setq-local eat-enable-directory-tracking nil)
  (setq-local eat-enable-shell-prompt-annotation nil)
  (let ((buffer (current-buffer)))
    (eat-term-set-parameter eat-terminal 'ring-bell-function
                            (lambda (_terminal) (agy--notify buffer)))))

(cl-defmethod agy--term-read-only-p ((_backend (eql eat)))
  "Return non-nil unless eat is in semi-char mode."
  (not eat--semi-char-mode))

(cl-defmethod agy--term-set-read-only ((_backend (eql eat)) flag)
  "Switch eat to Emacs mode if FLAG, else to semi-char mode."
  (if flag (eat-emacs-mode) (eat-semi-char-mode)))

(cl-defmethod agy--term-kill ((_backend (eql eat)) buffer)
  "Kill the eat process in BUFFER, then BUFFER."
  (with-current-buffer buffer
    (eat-kill-process))
  (when (buffer-live-p buffer)
    (let ((kill-buffer-query-functions nil))
      (kill-buffer buffer))))

;;;; Session buffers

(defun agy--directory ()
  "Directory a new agy session should run in.
The current project's root, else the visited file's directory, else
`default-directory'."
  (file-name-as-directory
   (file-truename
    (if-let* ((project (project-current)))
        (project-root project)
      (if buffer-file-name
          (file-name-directory buffer-file-name)
        default-directory)))))

(defun agy--buffers (&optional dir)
  "Live agy buffers, all of them or only those running in DIR."
  (seq-filter (lambda (buf)
                (when-let* ((buf-dir (buffer-local-value 'agy--directory buf)))
                  (or (null dir) (string= buf-dir dir))))
              (buffer-list)))

(defun agy--buffer-name (dir instance)
  "Name of the agy buffer for DIR and INSTANCE (nil for the first)."
  (if instance
      (format "*agy:%s:%s*" (abbreviate-file-name dir) instance)
    (format "*agy:%s*" (abbreviate-file-name dir))))

(defun agy--describe-buffer (buffer)
  "Short label for agy BUFFER: project name, instance, and directory."
  (let ((dir (buffer-local-value 'agy--directory buffer))
        (instance (buffer-local-value 'agy--instance buffer)))
    (format "%s%s (%s)"
            (file-name-nondirectory (directory-file-name dir))
            (if instance (concat ":" instance) "")
            (abbreviate-file-name dir))))

(defun agy--choose-buffer (prompt buffers)
  "Ask with PROMPT which of the agy BUFFERS to use; return it or nil."
  (let ((choices (mapcar (lambda (buf) (cons (agy--describe-buffer buf) buf))
                         buffers)))
    (cdr (assoc (completing-read prompt choices nil t) choices))))

(defun agy--get-buffer ()
  "Agy buffer for the current directory, asking when that is ambiguous.
With several sessions in this directory, ask which.  With none, use the
one chosen for this directory before, else offer every running session
and remember the choice.  Return nil when no session is running."
  (let* ((dir (agy--directory))
         (here (agy--buffers dir)))
    (cond
     ((cdr here)
      (agy--choose-buffer (format "agy session for %s: " (abbreviate-file-name dir))
                          here))
     (here (car here))
     ((buffer-live-p (gethash dir agy--remembered-buffers))
      (gethash dir agy--remembered-buffers))
     ((when-let* ((all (agy--buffers))
                  (buffer (agy--choose-buffer
                           (format "No agy session in %s; use: "
                                   (abbreviate-file-name dir))
                           all)))
        (puthash dir buffer agy--remembered-buffers))))))

(defun agy--require-buffer ()
  "Like `agy--get-buffer', but signal a `user-error' when there is none."
  (or (agy--get-buffer) (user-error "No agy session is running")))

(defmacro agy--with-buffer (&rest body)
  "Run BODY in the current agy session buffer, then display it."
  (declare (indent 0) (debug t))
  (let ((buffer (make-symbol "buffer")))
    `(let ((,buffer (agy--require-buffer)))
       (with-current-buffer ,buffer ,@body)
       (agy--show ,buffer)
       ,buffer)))

(defun agy--read-instance-name (dir existing force)
  "Read a fresh instance name for a session in DIR.
EXISTING are the agy buffers already running there.  Return nil, the
unnamed first instance, when EXISTING is empty and FORCE is nil."
  (when (or existing force)
    (let ((taken (mapcar (lambda (buf)
                           (or (buffer-local-value 'agy--instance buf) "default"))
                         existing))
          name)
      (while (or (null name) (string-empty-p name) (member name taken))
        (setq name (string-trim
                    (read-string
                     (if taken
                         (format "agy instance name for %s (running: %s): "
                                 (abbreviate-file-name dir)
                                 (string-join taken ", "))
                       (format "agy instance name for %s: "
                               (abbreviate-file-name dir)))))))
      name)))

(defun agy-display-buffer-below (buffer)
  "Display agy BUFFER in a window below the selected one."
  (display-buffer buffer '((display-buffer-below-selected))))

(defun agy--show (buffer &optional select)
  "Display agy BUFFER with `agy-display-window-fn'; select it if SELECT."
  (when-let* ((window (funcall agy-display-window-fn buffer)))
    (set-window-parameter window 'no-delete-other-windows
                          agy-no-delete-other-windows)
    (when select
      (select-window window))
    window))

;;;; Starting sessions

(defun agy--transient-switches ()
  "Start options chosen in `agy-transient', when invoked from it."
  (and (eq transient-current-command 'agy-transient)
       (transient-args 'agy-transient)))

(defun agy--start (dir &optional switches force-name select)
  "Start agy in DIR with extra command-line SWITCHES and return the buffer.
FORCE-NAME non-nil asks for an instance name even for the first session.
SELECT non-nil selects the new window."
  (unless (executable-find agy-program)
    (user-error "Cannot find the agy program `%s'" agy-program))
  (let* ((dir (file-name-as-directory (file-truename dir)))
         (default-directory dir)
         (instance (agy--read-instance-name dir (agy--buffers dir) force-name))
         (name (agy--buffer-name dir instance))
         (backend agy-terminal-backend)
         (switches (append agy-program-switches (agy--transient-switches) switches))
         (process-environment
          (append (list (concat "AGY_BUFFER_NAME=" name))
                  (mapcan (lambda (fn) (copy-sequence (funcall fn name dir)))
                          agy-process-environment-functions)
                  process-environment))
         (process-adaptive-read-buffering nil)
         (buffer (generate-new-buffer name)))
    ;; Display first: the terminal takes its size from the window.
    (let ((window (agy--show buffer)))
      (agy--term-make backend buffer agy-program switches)
      (with-current-buffer buffer
        (setq-local agy--directory dir
                    agy--instance instance
                    agy--backend backend)
        (agy--term-configure backend)
        (agy-session-mode 1)
        (face-remap-add-relative 'nobreak-space :underline nil)
        (add-hook 'kill-buffer-hook #'agy--forget-buffer nil t)
        (run-hooks 'agy-start-hook))
      (when (and (or select agy-toggle-auto-select)
                 (window-live-p window))
        (select-window window)))
    buffer))

(defun agy--forget-buffer ()
  "Drop the current buffer from `agy--remembered-buffers'."
  (let ((dying (current-buffer)))
    (maphash (lambda (dir buffer)
               (when (eq buffer dying)
                 (remhash dir agy--remembered-buffers)))
             agy--remembered-buffers)))

;;;###autoload
(defun agy (&optional arg)
  "Start agy for the current project, file directory, or `default-directory'.
With prefix ARG, prompt for the directory.  When a session already
runs there, ask for a name for the new instance."
  (interactive "P")
  (agy--start (if arg (read-directory-name "Start agy in: ") (agy--directory))))

;;;###autoload
(defun agy-start-in-directory ()
  "Prompt for a directory and start agy there."
  (interactive)
  (agy 'prompt))

;;;###autoload
(defun agy-new-instance (&optional arg)
  "Start another, named agy session for the current directory.
With prefix ARG, prompt for the directory."
  (interactive "P")
  (agy--start (if arg (read-directory-name "Start agy in: ") (agy--directory))
              nil t))

;;;###autoload
(defun agy-continue (&optional arg)
  "Start agy and continue its most recent conversation.
With prefix ARG, prompt for the directory."
  (interactive "P")
  (agy--start (if arg (read-directory-name "Continue agy in: ") (agy--directory))
              '("--continue")))

;;;###autoload
(defun agy-sandbox (&optional arg)
  "Start agy with terminal restrictions (`--sandbox').
With prefix ARG, prompt for the directory."
  (interactive "P")
  (agy--start (if arg (read-directory-name "Start sandboxed agy in: ") (agy--directory))
              '("--sandbox")))

;;;;; Resuming conversations

(defconst agy--conversations-query
  "SELECT conversation_id AS id, title, preview, last_modified_time AS time,
          workspace_uris AS workspaces
     FROM conversation_summaries
    WHERE nesting_depth = 0 AND step_count > 0 AND killed = 0
    ORDER BY last_modified_time DESC"
  "SQL listing resumable top-level conversations, newest first.")

(declare-function iso8601-parse "iso8601" (string &optional form))
(declare-function url-unhex-string "url-util" (str &optional allow-newlines))

(defun agy--conversations ()
  "Resumable agy conversations as plists, newest first.
Each has :id, :title, :time (a Lisp timestamp) and :dirs (workspace
directories)."
  (require 'iso8601)
  (require 'url-util)
  (let ((db (expand-file-name "conversation_summaries.db" agy-data-directory)))
    (unless (file-exists-p db)
      (user-error "No agy conversation index at %s" db))
    (unless (executable-find agy-sqlite-program)
      (user-error "`agy-resume' needs the %s program" agy-sqlite-program))
    (with-temp-buffer
      (unless (zerop (call-process agy-sqlite-program nil t nil
                                   "-readonly" "-json" db agy--conversations-query))
        (user-error "Reading %s failed: %s" db (string-trim (buffer-string))))
      (goto-char (point-min))
      (unless (eobp)
        (mapcar
         (lambda (row)
           (let* ((id (or (plist-get row :id) ""))
                  (title (string-trim (or (plist-get row :title) "")))
                  (preview (string-trim (or (plist-get row :preview) "")))
                  (raw-time (plist-get row :time))
                  (raw-ws (plist-get row :workspaces)))
             (list :id id
                   :title (cond ((not (string-empty-p title)) title)
                                ((not (string-empty-p preview)) preview)
                                (t "(untitled)"))
                   :time (or (and (stringp raw-time)
                                  (ignore-errors
                                    (encode-time
                                     (iso8601-parse
                                      (string-replace " " "T" raw-time)))))
                             (encode-time 0 0 0 1 1 1970 t))
                   :dirs (mapcar (lambda (uri)
                                   (file-name-as-directory
                                    (url-unhex-string
                                     (string-remove-prefix "file://" uri))))
                                 (and (stringp raw-ws)
                                      (ignore-errors
                                        (json-parse-string raw-ws
                                                           :array-type 'list
                                                           :null-object nil)))))))
         (json-parse-buffer :object-type 'plist :array-type 'list
                            :null-object nil :false-object nil))))))

(defun agy--read-conversation (conversations)
  "Ask which of CONVERSATIONS to resume and return its plist."
  (let* ((choices
          (mapcar (lambda (conv)
                    (let ((id (or (plist-get conv :id) "")))
                      (cons (format "%s  %s  %s%s"
                                    (format-time-string "%F %R" (plist-get conv :time))
                                    (truncate-string-to-width
                                     (string-replace "\n" " " (plist-get conv :title))
                                     60 nil nil "…")
                                    (propertize (abbreviate-file-name
                                                 (or (car (plist-get conv :dirs)) ""))
                                                'face 'shadow)
                                    (if (string-empty-p id)
                                        ""
                                      (propertize (format "  %s"
                                                          (substring id 0 (min 8 (length id))))
                                                  'face 'shadow)))
                            conv)))
                  conversations))
         (table (lambda (string pred action)
                  (if (eq action 'metadata)
                      '(metadata (display-sort-function . identity))
                    (complete-with-action action choices string pred)))))
    (cdr (assoc (completing-read "Resume agy conversation: " table nil t) choices))))

;;;###autoload
(defun agy-resume (&optional arg)
  "Resume a past agy conversation that ran in the current directory.
With prefix ARG, choose among conversations from every directory.
The session starts in the conversation's own workspace."
  (interactive "P")
  (let* ((dir (agy--directory))
         (all (agy--conversations))
         (conversations
          (if arg all
            (seq-filter (lambda (conv)
                          (seq-some (lambda (d) (file-equal-p d dir))
                                    (plist-get conv :dirs)))
                        all))))
    (unless conversations
      (user-error (if arg "No agy conversations to resume"
                    (substitute-command-keys
                     "No agy conversations in %s; \\[universal-argument] lists all"))
                  (abbreviate-file-name dir)))
    (let* ((conv (agy--read-conversation conversations))
           (conv-dir (car (plist-get conv :dirs))))
      (agy--start (if (and conv-dir (file-directory-p conv-dir)) conv-dir dir)
                  (list (concat "--conversation=" (plist-get conv :id)))))))

;;;;; Models

(defun agy--parse-models (output)
  "Parse `agy models' OUTPUT into an alist of (ID . DESCRIPTION)."
  (cl-loop for raw-line in (split-string output "\n" t)
           for line = (replace-regexp-in-string "\\`.*\r" "" raw-line)
           when (string-match "\\`\\([[:alnum:]][[:alnum:]._-]*\\)\\(?:\t+\\|  +\\)\\([^[:space:]].*\\)\\'"
                              line)
           collect (cons (match-string 1 line) (string-trim-right (match-string 2 line)))))

(defun agy--models ()
  "Models agy offers, as an alist of (ID . DESCRIPTION)."
  (or agy--models-cache
      (setq agy--models-cache
            (with-temp-buffer
              (unless (zerop (call-process agy-program nil '(t nil) nil "models"))
                (user-error "`%s models' failed" agy-program))
              (or (agy--parse-models (buffer-string))
                  (user-error "No models returned by `%s models'" agy-program))))))

(defun agy--read-model (prompt &optional initial-input history)
  "Read an agy model id with PROMPT, INITIAL-INPUT and HISTORY."
  (let* ((models (agy--models))
         (completion-extra-properties
          (list :annotation-function
                (lambda (id) (concat "  " (cdr (assoc id models)))))))
    (completing-read prompt models nil t initial-input history)))

;;;; Sending input

(defun agy--close-mention (text)
  "Return TEXT, with a space appended if it ends in an @-mention.
A trailing @path leaves agy's file-completion menu open, and the menu
would take the RET that submits the prompt."
  (if (string-match-p "@[^[:space:]]+\\'" text) (concat text " ") text))

(defun agy--submit (buffer text &optional select)
  "Paste TEXT at the agy prompt in BUFFER and submit it.
Empty TEXT just sends RET.  BUFFER is displayed afterwards, and
selected if SELECT is non-nil."
  (with-current-buffer buffer
    (unless (string-empty-p text)
      (agy--term-paste agy--backend (agy--close-mention text))
      ;; Wait for agy to process the bracketed paste before sending RET;
      ;; `sleep-for' is used rather than `sit-for' so pending keystrokes
      ;; do not cut the pause short.
      (sleep-for 0.1))
    (agy--term-send agy--backend "\r"))
  (agy--show buffer select)
  buffer)

(defun agy--send-to-session (text &optional select)
  "Submit TEXT to the current agy session; select its window if SELECT."
  (agy--submit (agy--require-buffer) text select))

(defun agy--send-key (string)
  "Send STRING as raw keystrokes to the current agy session."
  (agy--with-buffer (agy--term-send agy--backend string)))

(defun agy--file-name ()
  "Local true name of the file the current buffer visits, or nil."
  (when buffer-file-name
    (file-local-name (file-truename buffer-file-name))))

(defun agy--file-reference (&optional beg end)
  "An @-mention of the visited file with the line or lines around point.
With BEG and END, name the lines of that region.  Return nil when the
buffer visits no file."
  (when-let* ((file (agy--file-name)))
    (let ((first (line-number-at-pos (or beg (point)) t))
          (last (line-number-at-pos (if end (max (or beg end) (1- end)) (point)) t)))
      (if (= first last)
          (format "@%s (line %d)" file first)
        (format "@%s (lines %d-%d)" file first last)))))

;;;###autoload
(defun agy-send-command (&optional arg)
  "Read a prompt in the minibuffer and send it to agy.
With prefix ARG, switch to the agy buffer afterwards."
  (interactive "P")
  (agy--send-to-session (read-string "agy: " nil 'agy-command-history) arg))

;;;###autoload
(defun agy-send-command-with-context (&optional arg)
  "Read a prompt and send it with the file and lines at point or in the region.
With prefix ARG, switch to the agy buffer afterwards."
  (interactive "P")
  (let* ((ref (if (use-region-p)
                  (agy--file-reference (region-beginning) (region-end))
                (agy--file-reference)))
         (prompt (read-string "agy: " nil 'agy-command-history)))
    (agy--send-to-session (if ref (format "%s\n\n%s" prompt ref) prompt) arg)))

;;;###autoload
(defun agy-send-region (&optional arg)
  "Send the region, or the whole buffer, to agy.
Ask before sending a buffer larger than `agy-large-buffer-threshold'.
With one prefix ARG, prompt for instructions to put before the text;
with two, also switch to the agy buffer."
  (interactive "P")
  (let ((text (cond ((use-region-p)
                     (buffer-substring-no-properties (region-beginning) (region-end)))
                    ((or (<= (buffer-size) agy-large-buffer-threshold)
                         (yes-or-no-p "Buffer is large.  Send it anyway? "))
                     (buffer-substring-no-properties (point-min) (point-max))))))
    (when text
      (let ((instructions (and arg (read-string "Instructions for agy: "
                                                nil 'agy-command-history))))
        (agy--send-to-session (if instructions (format "%s\n\n%s" instructions text) text)
                              (equal arg '(16)))))))

;;;###autoload
(defun agy-send-file (file)
  "Send an @-mention of FILE to agy."
  (interactive "fSend file to agy: ")
  (agy--send-to-session (concat "@" (expand-file-name file))))

;;;###autoload
(defun agy-send-buffer-file (&optional arg)
  "Send an @-mention of the file this buffer visits to agy.
With one prefix ARG, prompt for instructions to send with it; with two,
also switch to the agy buffer."
  (interactive "P")
  (let* ((file (or (agy--file-name) (user-error "Buffer is not visiting a file")))
         (instructions (and arg (read-string "Instructions for agy: "
                                             nil 'agy-command-history))))
    (agy--send-to-session (if instructions
                              (format "%s\n\n@%s" instructions file)
                            (concat "@" file))
                          (equal arg '(16)))))

(declare-function flycheck-overlay-errors-at "flycheck" (pos))
(declare-function flycheck-error-filename "flycheck" (err))
(declare-function flycheck-error-line "flycheck" (err))
(declare-function flycheck-error-message "flycheck" (err))
(declare-function flymake-diagnostics "flymake" (&optional beg end))
(declare-function flymake-diagnostic-text "flymake" (diag))

(defun agy--errors-at-point ()
  "Flycheck or Flymake diagnostics at point, as a string or nil."
  (cond
   ((when-let* (((bound-and-true-p flycheck-mode))
                (errors (flycheck-overlay-errors-at (point))))
      (mapconcat (lambda (err)
                   (format "%s:%d: %s"
                           (or (flycheck-error-filename err)
                               (agy--file-name)
                               (buffer-name))
                           (or (flycheck-error-line err)
                               (line-number-at-pos (point) t))
                           (flycheck-error-message err)))
                 errors "\n")))
   ((when-let* (((bound-and-true-p flymake-mode))
                (diags (flymake-diagnostics (point))))
      (mapconcat #'flymake-diagnostic-text diags "\n")))
   ((when-let* ((help (help-at-pt-kbd-string)))
      (substring-no-properties help)))))

;;;###autoload
(defun agy-fix-error-at-point (&optional arg)
  "Ask agy to fix the flycheck or flymake error at point.
With prefix ARG, switch to the agy buffer afterwards."
  (interactive "P")
  (let ((errors (or (agy--errors-at-point) (user-error "No error at point"))))
    (agy--send-to-session
     (format "Fix this error at %s, using only the context given; do not \
run a linter or other program:\n\n%s"
             (or (agy--file-reference) "point") errors)
     arg)))

;;;###autoload
(defun agy-send-return ()
  "Send RET to agy, to confirm a prompt without leaving this buffer."
  (interactive)
  (agy--send-key "\r"))

;;;###autoload
(defun agy-send-escape ()
  "Send ESC to agy, to decline a prompt or interrupt the current turn."
  (interactive)
  (agy--send-key "\e"))

;;;###autoload
(defun agy-cycle-mode ()
  "Cycle agy's agent mode: default, accept-edits, auto, plan."
  (interactive)
  (agy--send-key "\e[Z"))

;;;###autoload
(defun agy-paste-image ()
  "Attach the image on the system clipboard to agy's prompt.
This is agy's own Ctrl+V, so agy reads the clipboard itself."
  (interactive)
  (agy--send-key "\C-v"))

(defun agy-slash-command (command)
  "Send slash COMMAND, such as \"/compact\", to agy."
  (interactive (list (read-string "agy slash command: " "/" 'agy-command-history)))
  (agy--send-to-session command))

(defmacro agy--define-slash (name command &optional prompt)
  "Define a command named agy-slash- plus NAME that sends slash COMMAND.
With PROMPT, the command reads an argument with it and appends it."
  (declare (indent defun))
  `(defun ,(intern (format "agy-slash-%s" name)) ,(if prompt '(arg) '())
     ,(format "Send %s to agy%s." command (if prompt " with ARG" ""))
     (interactive ,@(when prompt `((list (read-string ,prompt)))))
     (agy--send-to-session ,(if prompt `(string-trim (concat ,command " " arg)) command))))

(agy--define-slash help "/help")
(agy--define-slash clear "/clear")
(agy--define-slash compact "/compact" "Compact, then answer (optional): ")
(agy--define-slash context "/context")
(agy--define-slash config "/config")
(agy--define-slash model "/model")
(agy--define-slash effort "/effort")
(agy--define-slash permissions "/permissions")
(agy--define-slash mcp "/mcp")
(agy--define-slash skills "/skills")
(agy--define-slash agents "/agents")
(agy--define-slash hooks "/hooks")
(agy--define-slash tasks "/tasks")
(agy--define-slash diff "/diff")
(agy--define-slash artifact "/artifact")
(agy--define-slash rewind "/rewind")
(agy--define-slash fork "/fork")
(agy--define-slash resume "/resume")
(agy--define-slash usage "/usage")
(agy--define-slash copy "/copy")
(agy--define-slash planning "/planning")
(agy--define-slash btw "/btw" "Side question: ")
(agy--define-slash goal "/goal" "Goal: ")
(agy--define-slash learn "/learn" "Rule to learn (optional): ")
(agy--define-slash rename "/rename" "New session name: ")

(defun agy-slash-add-dir (dir)
  "Add DIR to the agy session's workspace."
  (interactive "DAdd directory to agy workspace: ")
  (agy--send-to-session (concat "/add-dir " (expand-file-name dir))))

;;;; Managing sessions

;;;###autoload
(defun agy-toggle ()
  "Show the agy window for this directory, or hide it if it is shown."
  (interactive)
  (let ((buffer (agy--require-buffer)))
    (if-let* ((window (get-buffer-window buffer)))
        ;; Unlike `delete-window', this also copes with a sole window.
        (quit-window nil window)
      (agy--show buffer agy-toggle-auto-select))))

;;;###autoload
(defun agy-switch-to-buffer (&optional arg)
  "Switch to the agy session for this directory.
With prefix ARG, choose among all running sessions."
  (interactive "P")
  (pop-to-buffer (if arg (agy--choose-any) (agy--require-buffer))))

(defun agy--choose-any ()
  "Pick one of all running agy sessions; signal if there are none."
  (pcase (agy--buffers)
    ('nil (user-error "No agy session is running"))
    (`(,only) only)
    (all (agy--choose-buffer "agy session: " all))))

;;;###autoload
(defun agy-select-buffer ()
  "Switch to any running agy session."
  (interactive)
  (pop-to-buffer (agy--choose-any)))

;;;###autoload
(defun agy-kill ()
  "Stop the agy session for this directory and kill its buffer."
  (interactive)
  (let ((buffer (agy--require-buffer)))
    (when (or (not agy-confirm-kill)
              (yes-or-no-p (format "Kill %s? " (buffer-name buffer))))
      (agy--term-kill (buffer-local-value 'agy--backend buffer) buffer)
      (message "agy session killed"))))

;;;###autoload
(defun agy-kill-all ()
  "Stop every agy session and kill their buffers."
  (interactive)
  (let ((buffers (or (agy--buffers) (user-error "No agy session is running"))))
    (when (or (not agy-confirm-kill)
              (yes-or-no-p (format "Kill %d agy session%s? "
                                   (length buffers) (if (cdr buffers) "s" ""))))
      (dolist (buffer buffers)
        (agy--term-kill (buffer-local-value 'agy--backend buffer) buffer))
      (message "Killed %d agy session%s" (length buffers) (if (cdr buffers) "s" "")))))

;;;###autoload
(defun agy-toggle-read-only-mode ()
  "Toggle the agy terminal between read-only and interactive input.
Read-only mode lets ordinary Emacs commands move, search and copy."
  (interactive)
  (agy--with-buffer
    (agy--term-set-read-only agy--backend
                             (not (agy--term-read-only-p agy--backend)))))

;;;; Keys inside agy buffers

(defun agy-insert-newline ()
  "Insert a line break in agy's prompt without submitting it."
  (interactive)
  (agy--term-send agy--backend "\n"))

(defun agy-escape-or-quit ()
  "Send ESC to agy, or `keyboard-quit' when the terminal is read-only."
  (interactive)
  (if (agy--term-read-only-p agy--backend)
      (keyboard-quit)
    (agy--term-send agy--backend "\e")))

(defvar-keymap agy-session-mode-map
  :doc "Keymap active in agy session buffers."
  "S-<return>" #'agy-insert-newline
  "M-<return>" #'agy-insert-newline
  "C-g"        #'agy-escape-or-quit)

(define-minor-mode agy-session-mode
  "Minor mode in buffers that run an agy session.
\\{agy-session-mode-map}"
  :lighter " agy"
  ;; Terminal emulators bind RET and friends in their own minor modes;
  ;; the overriding alist puts this keymap ahead of theirs.
  (setq-local minor-mode-overriding-map-alist
              (assq-delete-all 'agy-session-mode
                               (copy-alist minor-mode-overriding-map-alist)))
  (when agy-session-mode
    (push (cons 'agy-session-mode agy-session-mode-map)
          minor-mode-overriding-map-alist)))

;;;; Notifications and the hook bridge

(defun agy-default-notification (title message)
  "Show TITLE and MESSAGE in the echo area and flash the mode line."
  (message "%s: %s" title message)
  (invert-face 'mode-line)
  (run-at-time 0.2 nil #'invert-face 'mode-line))

(defun agy--notify (buffer)
  "Tell the user that agy in BUFFER is waiting.
Skipped when `agy-enable-notifications' is nil, or when BUFFER is in
the selected window of a focused frame."
  (when (and agy-enable-notifications
             (buffer-live-p buffer)
             (not (and (eq buffer (window-buffer (selected-window)))
                       (eq (frame-focus-state) t))))
    (funcall agy-notification-function "agy"
             (format "%s is waiting for you" (buffer-name buffer)))))

(declare-function json-pretty-print-buffer "json" (&optional minimize))

(defun agy-handle-hook (event buffer-name &optional json)
  "Handle agy lifecycle hook EVENT from the session in BUFFER-NAME.
JSON is the payload agy passed the hook.  The bridge script
bin/agy-emacs-hook calls this through emacsclient; see
`agy-install-hooks'.  Run `agy-event-functions', then notify on a
\"Stop\" when the session is fully idle and was not cancelled by the user."
  (let ((buffer (get-buffer buffer-name))
        (data (and json
                   (ignore-errors
                     (json-parse-string json :object-type 'plist
                                        :null-object nil :false-object nil)))))
    (run-hook-with-args 'agy-event-functions
                        (list :event event :buffer buffer :data data))
    (when (and buffer
               (equal event "Stop")
               (not (equal (plist-get data :terminationReason) "USER_CANCELED"))
               (or (not (plist-member data :fullyIdle))
                   (plist-get data :fullyIdle)))
      (agy--notify buffer))
    nil))

(defun agy--hook-command (event)
  "Shell command that forwards agy hook EVENT to Emacs."
  (format "%s %s"
          (shell-quote-argument (expand-file-name "bin/agy-emacs-hook" agy--root))
          event))

;;;###autoload
(defun agy-install-hooks ()
  "Add the Emacs bridge to agy's global hooks file, `agy-hooks-file'.
The bridge runs on agy's Stop event and calls `agy-handle-hook' through
emacsclient, so Emacs hears when a turn ends.  It does nothing in agy
sessions started outside Emacs.  Other hooks in the file are kept; the
bridge is the entry named \"agy-el\"."
  (interactive)
  (require 'json)
  (let* ((file (expand-file-name agy-hooks-file))
         (config (with-temp-buffer
                   (when (file-exists-p file)
                     (insert-file-contents file))
                   (goto-char (point-min))
                   (if (looking-at-p "[[:space:]]*\\'")
                       nil
                     (json-parse-buffer :object-type 'alist
                                        :null-object :null :false-object :false)))))
    (setf (alist-get 'Stop (alist-get 'agy-el config))
          `[((type . "command")
             (command . ,(agy--hook-command "Stop"))
             (timeout . 5))])
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert (json-serialize config :null-object :null :false-object :false))
      (json-pretty-print-buffer))
    (message "Installed the agy-el Stop hook in %s" (abbreviate-file-name file))))

;;;; Menus

(transient-define-argument agy--model-option ()
  "Model to start agy with."
  :class 'transient-option
  :argument "--model="
  :reader #'agy--read-model)

(transient-define-argument agy--mode-option ()
  "Agent mode to start agy in."
  :class 'transient-option
  :argument "--mode="
  :choices '("accept-edits" "auto" "plan"))

(transient-define-argument agy--effort-option ()
  "Reasoning effort to start agy with."
  :class 'transient-option
  :argument "--effort="
  :choices '("low" "medium" "high" "xhigh" "max"))

;;;###autoload (autoload 'agy-transient "agy" nil t)
(transient-define-prefix agy-transient ()
  "Antigravity CLI menu.
The start options apply to sessions started from this menu."
  ["Start options"
   ("-m" "Model" agy--model-option)
   ("-o" "Mode" agy--mode-option)
   ("-e" "Effort" agy--effort-option)
   ("-s" "Sandbox" "--sandbox")
   ("-y" "Skip permission prompts" "--dangerously-skip-permissions")]
  [["Start / stop"
    ("a" "Start agy" agy)
    ("d" "Start in directory" agy-start-in-directory)
    ("C" "Continue last conversation" agy-continue)
    ("R" "Resume conversation" agy-resume)
    ("i" "New instance" agy-new-instance)
    ("S" "Start sandboxed" agy-sandbox)
    ("k" "Kill session" agy-kill)
    ("K" "Kill all sessions" agy-kill-all)]
   ["Send"
    ("s" "Prompt" agy-send-command)
    ("x" "Prompt with file context" agy-send-command-with-context)
    ("r" "Region or buffer" agy-send-region)
    ("o" "This buffer's file" agy-send-buffer-file)
    ("f" "File by path" agy-send-file)
    ("e" "Fix error at point" agy-fix-error-at-point)
    ("v" "Paste clipboard image" agy-paste-image)
    ("/" "Slash commands" agy-slash-commands)]
   ["Session"
    ("t" "Toggle window" agy-toggle)
    ("b" "Switch to session" agy-switch-to-buffer)
    ("B" "Pick any session" agy-select-buffer)
    ("z" "Toggle read-only" agy-toggle-read-only-mode)
    ("M" "Cycle agent mode" agy-cycle-mode :transient t)]
   ["Answer"
    ("y" "Send RET" agy-send-return)
    ("n" "Send ESC" agy-send-escape)]])

;;;###autoload (autoload 'agy-slash-commands "agy" nil t)
(transient-define-prefix agy-slash-commands ()
  "Menu of agy slash commands."
  [["Conversation"
    ("c" "Compact" agy-slash-compact)
    ("l" "Clear" agy-slash-clear)
    ("w" "Rewind" agy-slash-rewind)
    ("f" "Fork" agy-slash-fork)
    ("r" "Resume" agy-slash-resume)
    ("n" "Rename" agy-slash-rename)
    ("y" "Copy last answer" agy-slash-copy)]
   ["Work"
    ("b" "Side question (btw)" agy-slash-btw)
    ("g" "Goal" agy-slash-goal)
    ("p" "Planning" agy-slash-planning)
    ("L" "Learn" agy-slash-learn)
    ("d" "Diff" agy-slash-diff)
    ("a" "Artifacts" agy-slash-artifact)
    ("T" "Tasks" agy-slash-tasks)]
   ["Setup"
    ("m" "Model" agy-slash-model)
    ("e" "Effort" agy-slash-effort)
    ("C" "Config" agy-slash-config)
    ("P" "Permissions" agy-slash-permissions)
    ("M" "MCP servers" agy-slash-mcp)
    ("s" "Skills" agy-slash-skills)
    ("A" "Agents" agy-slash-agents)
    ("H" "Hooks" agy-slash-hooks)
    ("+" "Add directory" agy-slash-add-dir)]
   ["Info"
    ("h" "Help" agy-slash-help)
    ("x" "Context usage" agy-slash-context)
    ("u" "Quota usage" agy-slash-usage)
    ("/" "Other…" agy-slash-command)]])

;;;###autoload (autoload 'agy-command-map "agy" nil t 'keymap)
(defvar-keymap agy-command-map
  :doc "Prefix keymap of agy commands; bind it to a key of your choice."
  "a" #'agy
  "d" #'agy-start-in-directory
  "C" #'agy-continue
  "R" #'agy-resume
  "i" #'agy-new-instance
  "S" #'agy-sandbox
  "k" #'agy-kill
  "K" #'agy-kill-all
  "s" #'agy-send-command
  "x" #'agy-send-command-with-context
  "r" #'agy-send-region
  "o" #'agy-send-buffer-file
  "f" #'agy-send-file
  "e" #'agy-fix-error-at-point
  "v" #'agy-paste-image
  "/" #'agy-slash-commands
  "t" #'agy-toggle
  "b" #'agy-switch-to-buffer
  "B" #'agy-select-buffer
  "z" #'agy-toggle-read-only-mode
  "M" #'agy-cycle-mode
  "y" #'agy-send-return
  "n" #'agy-send-escape
  "m" #'agy-transient)

(provide 'agy)
;;; agy.el ends here
