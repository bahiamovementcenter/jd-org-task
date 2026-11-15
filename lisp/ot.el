;;; ot.el --- Org tasks from the shell  -*- lexical-binding: t; -*-

;; The core of `ot'. The `ot' script calls `ot-cli' in a small Emacs: a
;; daemon started with -Q, or a one-off `emacs -Q --batch'. Everything here
;; works on one Org file, given on each call, so one daemon serves any file.
;;
;; A task is a heading with a TODO state. Its id is the start of its `ID'
;; property (a UUID that `org-id' gives it), so it survives edits and moves.
;; A parent is named by its CUSTOM_ID or by the number its title starts
;; with: an ID like 11.11, or a work package like W0011 or W0011~11.11.

(require 'org)
(require 'org-id)
(require 'json)
(require 'subr-x)

;; Leave no trace outside the task file: no backups, no global id table.
(setq make-backup-files nil
      auto-save-default nil
      create-lockfiles nil
      org-id-track-globally nil)

(defvar ot-id-length 8
  "How many characters of a task's ID `ot' prints.")

;; States for a file with no #+TODO line of its own. Put the same line in
;; the file (or this setting in your Emacs) so your Emacs agrees:
;;   #+TODO: TODO NEXT WAIT | DONE CANCELLED
(setq org-todo-keywords
      '((sequence "TODO" "NEXT" "WAIT" "|" "DONE" "CANCELLED")))

;;; The file

(defun ot--buffer (file)
  "A buffer visiting FILE in Org mode, in step with the disk.
Another editor may have changed the file since the last call."
  (let ((buf (or (find-buffer-visiting file)
                 (progn
                   (unless (file-exists-p file)
                     (make-directory (file-name-directory file) t)
                     (write-region "" nil file))
                   (find-file-noselect file)))))
    (with-current-buffer buf
      (unless (verify-visited-file-modtime buf)
        (revert-buffer t t t))
      (unless (derived-mode-p 'org-mode) (org-mode)))
    buf))

(defun ot--save ()
  (let ((inhibit-message t)) (save-buffer)))

;;; Finding headings

(defun ot--title ()
  (org-get-heading t t t t))

(defun ot--parse-under (spec)
  "Split SPEC into (NUMBER . ADDRESS): \"W0011~11.11\" is (\"W0011\" . \"11.11\")."
  (if (string-match "\\`\\([^~ ]+\\)[~ ]\\(.+\\)\\'" spec)
      (cons (match-string 1 spec) (match-string 2 spec))
    (cons spec nil)))

(defun ot--goto-under (spec)
  "Move to the heading SPEC names, or signal an error."
  (pcase-let* ((`(,num . ,addr) (ot--parse-under spec))
               (pos (or (org-find-property "CUSTOM_ID" num)
                        (ot--find-title num))))
    (unless pos (user-error "No heading %s in %s" num (buffer-file-name)))
    (goto-char pos)
    (when addr
      (let ((title (ot--title)))
        (unless (string-match-p
                 (concat "\\`" (regexp-quote num) "[~ ]" (regexp-quote addr) "\\b")
                 title)
          (user-error "%s is \"%s\", not under %s" num title addr))))
    (point)))

(defun ot--find-title (num)
  "The position of the first heading whose title starts with NUM."
  (save-excursion
    (goto-char (point-min))
    (catch 'found
      (while (re-search-forward org-heading-regexp nil t)
        (beginning-of-line)
        (when (string-match-p (concat "\\`" (regexp-quote num) "\\([ ~]\\|\\'\\)")
                              (ot--title))
          (throw 'found (point)))
        (end-of-line))
      nil)))

(defun ot--goto-inbox (name)
  "Move to the heading NAME (its CUSTOM_ID, number or title), making a
top-level one at the end if there is none."
  (goto-char (point-min))
  (let ((pos (or (org-find-property "CUSTOM_ID" name)
                 (ot--find-title name)
                 (org-find-exact-headline-in-buffer name nil t))))
    (if pos
        (goto-char pos)
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert "* " name "\n")
      (forward-line -1))
    (point)))

(defun ot--goto-task (id)
  "Move to the task whose ID starts with ID."
  (let (hits)
    (org-map-entries
     (lambda ()
       (let ((full (org-entry-get nil "ID")))
         (when (and full (org-get-todo-state) (string-prefix-p id full))
           (push (point) hits)))))
    (pcase (length hits)
      (0 (user-error "No task %s" id))
      (1 (goto-char (car hits)))
      (_ (user-error "%s matches %d tasks: give more of its id" id (length hits))))))

;;; Tasks as data

(defun ot--parent ()
  "The nearest ancestor's CUSTOM_ID, else the number its title starts
with (11.11, W0012~11.12), else its title."
  (save-excursion
    (when (org-up-heading-safe)
      (or (org-entry-get nil "CUSTOM_ID")
          (let ((title (ot--title)))
            (if (string-match "\\`\\(W?[0-9][^ ]*\\) " title)
                (match-string 1 title)
              title))))))

(defun ot--task ()
  "The task at point, as an alist."
  (let ((id (org-entry-get nil "ID")))
    `((id . ,(if id (substring id 0 (min ot-id-length (length id))) ""))
      (state . ,(org-get-todo-state))
      (title . ,(ot--title))
      (under . ,(ot--parent))
      (deadline . ,(org-entry-get nil "DEADLINE"))
      (scheduled . ,(org-entry-get nil "SCHEDULED"))
      (file . ,(buffer-file-name))
      (line . ,(line-number-at-pos nil t)))))

(defun ot--table (tasks)
  (if (null tasks)
      ""
    (mapconcat
     (lambda (task)
       (let-alist task
         (format "%-8s  %-5s  %-16s  %-10s  %s"
                 .id .state
                 (if (stringp .deadline) .deadline "")
                 (if (stringp .under) .under "")
                 .title)))
     tasks "\n")))

;;; Commands

(defun ot--check-state (state)
  (unless (member state org-todo-keywords-1)
    (user-error "%s isn't a state in this file: %s"
                state (string-join org-todo-keywords-1 " "))))

(defun ot--take (flag args)
  "The value after FLAG in ARGS, and ARGS without them."
  (let ((tail (member flag args)))
    (if (not tail)
        (list nil args)
      (unless (cdr tail) (user-error "%s needs a value" flag))
      (list (cadr tail)
            (append (seq-take args (- (length args) (length tail))) (cddr tail))))))

(defun ot--add (args inbox)
  (pcase-let* ((`(,under ,args) (ot--take "--under" args))
               (`(,due ,args) (ot--take "--due" args))
               (`(,state ,args) (ot--take "--state" args))
               (title (string-join args " ")))
    (when (string-empty-p title) (user-error "ot add needs a title"))
    (ot--check-state (or state "TODO"))
    (if under (ot--goto-under under) (ot--goto-inbox inbox))
    (let ((level (org-current-level)))
      (org-end-of-subtree t t)
      (unless (bolp) (insert "\n"))
      (insert (make-string (1+ level) ?*) " " (or state "TODO") " " title "\n")
      (forward-line -1)
      (org-id-get-create)
      (when due (org-deadline nil (org-read-date nil t due)))
      (ot--save)
      (ot--task))))

(defun ot--ls (args)
  (pcase-let* ((`(,under ,args) (ot--take "--under" args))
               (`(,state ,args) (ot--take "--state" args))
               (all (member "--all" args))
               (tasks '()))
    (save-excursion
      (when under (ot--goto-under under))
      (org-map-entries
       (lambda ()
         (let ((s (org-get-todo-state)))
           (when (and s
                      (or all state (not (member s org-done-keywords)))
                      (or (null state) (string= s state)))
             (push (ot--task) tasks))))
       nil (and under 'tree)))
    (nreverse tasks)))

(defun ot--set (args)
  (pcase args
    (`(,id ,state)
     (ot--goto-task id)
     (ot--check-state state)
     (let ((org-log-done nil)) (org-todo state))
     (ot--save)
     (ot--task))
    (_ (user-error "ot set takes a task id and a state"))))

(defun ot--run (file cmd args inbox)
  "Run CMD on FILE; return (TEXT . JSON-VALUE)."
  (with-current-buffer (ot--buffer (expand-file-name file))
    (save-excursion
      (pcase cmd
        ("add" (ot--add args inbox))
        ("ls" (ot--ls args))
        ("set" (ot--set args))
        ("done" (ot--set (list (car args) (car org-done-keywords))))
        ("where" (ot--goto-task (car args))
         (list (cons 'file (buffer-file-name))
               (cons 'line (line-number-at-pos nil t))))
        (_ (user-error "Unknown command: %s" cmd))))))

(defun ot-cli (file out cmd args &optional inbox json)
  "Run `ot CMD ARGS' on FILE, and write what to print to OUT.
Return the exit status: 0, or 1 with the error message in OUT."
  (condition-case err
      (let* ((result (ot--run file cmd args (or inbox "Inbox")))
             (text (cond
                    (json (json-encode
                           (if (equal cmd "ls") (vconcat result) result)))
                    ((equal cmd "where")
                     (format "%s:%s" (alist-get 'file result) (alist-get 'line result)))
                    ((equal cmd "ls") (ot--table result))
                    (t (ot--table (list result))))))
        (with-temp-file out (insert text (if (string-empty-p text) "" "\n")))
        0)
    (error
     (with-temp-file out (insert "ot: " (error-message-string err) "\n"))
     1)))

(provide 'ot)
;;; ot.el ends here
