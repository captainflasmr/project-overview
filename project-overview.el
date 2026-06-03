;;; project-overview.el --- Dashboard of git projects with status and actions -*- lexical-binding: t; -*-

;; Author: James Dyer <captainflasmr@gmail.com>
;; Maintainer: James Dyer <captainflasmr@gmail.com>
;; Keywords: tools, vc, convenience
;; Version: 0.1.0
;; Package-Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (transient "0.3.0"))
;; URL: https://github.com/captainflasmr/project-overview
;;
;; This file is not part of GNU Emacs.
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or (at
;; your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;; A central, sortable table of your git projects.  `project-overview'
;; opens a `tabulated-list-mode' buffer with one row per auto-discovered
;; git repository under `project-overview-search-roots', showing:
;;
;;   - the latest CHANGELOG.org version and date,
;;   - the open/total bug count from BUGS.org,
;;   - git branch, dirty flag, and ahead/behind state, and
;;   - the last commit date.
;;
;; Single keys act on the project under point, reusing project.el where
;; possible.  See `project-overview-mode-map' for the full set:
;;
;;   RET / o  switch to project        c  open CHANGELOG.org
;;   f        find file in project     v  preview latest CHANGELOG entry
;;   m        magit-status             b  open BUGS.org
;;   s        search project           B  TODO agenda for this project's bugs
;;   d        dired at root            g  refresh (re-scan)
;;   !        shell at root            ?  transient menu of all actions
;;
;; `project-overview-dispatch' (bound to ? in the dashboard) presents the
;; same actions as a transient menu, headed by the project under point.
;;
;; Both CHANGELOG.org and BUGS.org parsing assume the common org layout:
;;
;;   #+todo: TODO DOING | DONE
;;   * Versions
;;   ** <2026-05-19 Tue> *7.5.3*
;;
;; but degrade gracefully when a file is missing or differently shaped.

;;; Code:

(require 'tabulated-list)
(require 'seq)
(require 'subr-x)
(require 'project)
(require 'transient)

(declare-function magit-status "ext:magit" (&optional directory cache))
(declare-function consult-ripgrep "ext:consult" (&optional dir initial))
(declare-function org-todo-list "org-agenda" (&optional arg))
(declare-function org-mode "org" ())
(defvar org-agenda-files)

;;; Customization

(defgroup project-overview nil
  "Dashboard of git projects with status and actions."
  :group 'tools
  :prefix "project-overview-")

(defcustom project-overview-search-roots
  (list (expand-file-name "~/source/repos"))
  "Root directories scanned for git projects.
Each root is checked directly and one level deep for .git subdirs."
  :type '(repeat directory)
  :group 'project-overview)

(defcustom project-overview-exclude-regexp "\\`linux-"
  "Projects whose directory name matches this regexp are hidden."
  :type 'regexp
  :group 'project-overview)

(defcustom project-overview-buffer-name "*Projects*"
  "Name of the dashboard buffer."
  :type 'string
  :group 'project-overview)

;;; Internal state

(defvar project-overview--cache nil
  "Alist of (ROOT . PLIST) holding scanned project data for the dashboard.")

;;; Scanning

(defun project-overview--git (root &rest args)
  "Run git in ROOT with ARGS, returning trimmed output or nil on failure."
  (when (file-directory-p (expand-file-name ".git" root))
    (with-temp-buffer
      (when (zerop (apply #'process-file "git" nil t nil
                          (append (list "-C" (expand-file-name root)) args)))
        (string-trim (buffer-string))))))

(defun project-overview--discover ()
  "Return a sorted list of git project roots under `project-overview-search-roots'."
  (let (roots)
    (dolist (root project-overview-search-roots)
      (setq root (expand-file-name root))
      (when (file-directory-p root)
        (when (file-directory-p (expand-file-name ".git" root))
          (push root roots))
        (dolist (sub (directory-files root t "^[^.]"))
          (when (and (file-directory-p sub)
                     (file-directory-p (expand-file-name ".git" sub)))
            (push sub roots)))))
    (sort (seq-remove
           (lambda (r)
             (string-match-p project-overview-exclude-regexp
                             (file-name-nondirectory (directory-file-name r))))
           (delete-dups roots))
          #'string<)))

(defun project-overview--changelog (root)
  "Return cons (VERSION . DATE) from the latest CHANGELOG.org entry in ROOT.
Parses the first \"** <date> *version*\" heading.  Returns nil if absent."
  (let ((file (expand-file-name "CHANGELOG.org" root)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file nil 0 8000)
        (goto-char (point-min))
        (when (re-search-forward "^\\*\\* +.*$" nil t)
          (let* ((line (match-string 0))
                 (date (when (string-match
                              "<\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)" line)
                         (match-string 1 line)))
                 (ver (cond
                       ((string-match "\\*\\([0-9][0-9A-Za-z.+-]*\\)\\*" line)
                        (match-string 1 line))
                       ((string-match "\\b\\([0-9]+\\.[0-9]+\\(?:\\.[0-9]+\\)?\\)\\b"
                                      line)
                        (match-string 1 line)))))
            (cons (or ver "") (or date ""))))))))

(defun project-overview--bugs (root)
  "Return cons (OPEN . TOTAL) of TODO/DOING/DONE headings in ROOT's BUGS.org."
  (let ((file (expand-file-name "BUGS.org" root))
        (open 0) (total 0))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward "^\\*+ +\\(TODO\\|DOING\\|DONE\\)\\b" nil t)
          (setq total (1+ total))
          (unless (string= (match-string 1) "DONE")
            (setq open (1+ open))))))
    (cons open total)))

(defun project-overview--git-info (root)
  "Return a plist :branch :dirty :commit :ahead :behind describing ROOT's git."
  (let* ((branch (or (project-overview--git root "symbolic-ref" "--short" "HEAD")
                     (project-overview--git root "rev-parse" "--short" "HEAD")
                     ""))
         (status (project-overview--git root "status" "--porcelain"))
         (dirty (and status (> (length status) 0)))
         (commit (or (project-overview--git root "log" "-1" "--format=%cd"
                                            "--date=short")
                     ""))
         (ab (project-overview--git root "rev-list" "--left-right" "--count"
                                    "HEAD...@{u}"))
         ahead behind)
    (when (and ab (string-match "\\([0-9]+\\)[ \t]+\\([0-9]+\\)" ab))
      (setq ahead (string-to-number (match-string 1 ab))
            behind (string-to-number (match-string 2 ab))))
    (list :branch branch :dirty dirty :commit commit
          :ahead (or ahead 0) :behind (or behind 0))))

(defun project-overview--scan ()
  "Scan all discovered projects and populate `project-overview--cache'."
  (setq project-overview--cache
        (mapcar
         (lambda (root)
           (let ((cl (project-overview--changelog root))
                 (bugs (project-overview--bugs root))
                 (git (project-overview--git-info root)))
             (cons root
                   (list :name (file-name-nondirectory (directory-file-name root))
                         :version (or (car cl) "")
                         :changed (or (cdr cl) "")
                         :open (car bugs)
                         :total (cdr bugs)
                         :git git))))
         (project-overview--discover))))

;;; Rendering

(defun project-overview--git-flag (git)
  "Return a short propertized status string for the GIT plist."
  (let ((s ""))
    (when (plist-get git :dirty) (setq s (concat s "*")))
    (when (> (plist-get git :ahead) 0)
      (setq s (concat s (format "↑%d" (plist-get git :ahead)))))
    (when (> (plist-get git :behind) 0)
      (setq s (concat s (format "↓%d" (plist-get git :behind)))))
    (if (string-empty-p s) "" (propertize s 'face 'warning))))

(defun project-overview--entries ()
  "Build `tabulated-list-entries' from `project-overview--cache'."
  (mapcar
   (lambda (cell)
     (let* ((root (car cell))
            (p (cdr cell))
            (git (plist-get p :git))
            (open (plist-get p :open))
            (total (plist-get p :total))
            (bugs (if (> total 0) (format "%d/%d" open total) "")))
       (when (> open 0) (setq bugs (propertize bugs 'face 'warning)))
       (list root
             (vector (plist-get p :name)
                     (plist-get p :version)
                     (plist-get p :changed)
                     bugs
                     (plist-get git :branch)
                     (project-overview--git-flag git)
                     (plist-get git :commit)))))
   project-overview--cache))

;;; Actions

(defun project-overview--root ()
  "Return the project root for the current dashboard line."
  (or (tabulated-list-get-id) (user-error "No project on this line")))

(defun project-overview-open ()
  "Switch to the project under point via `project-switch-project'."
  (interactive)
  (project-switch-project (project-overview--root)))

(defun project-overview-find-file ()
  "Run `project-find-file' in the project under point."
  (interactive)
  (let ((default-directory (project-overview--root)))
    (project-find-file)))

(defun project-overview-magit ()
  "Open `magit-status' for the project under point."
  (interactive)
  (if (fboundp 'magit-status)
      (magit-status (project-overview--root))
    (user-error "Magit is not available")))

(defun project-overview-search ()
  "Search the project under point (consult-ripgrep if available)."
  (interactive)
  (let ((default-directory (project-overview--root)))
    (call-interactively
     (if (fboundp 'consult-ripgrep) #'consult-ripgrep #'project-find-regexp))))

(defun project-overview-dired ()
  "Open Dired at the root of the project under point."
  (interactive)
  (dired (project-overview--root)))

(defun project-overview-shell ()
  "Open a shell rooted at the project under point."
  (interactive)
  (let ((default-directory (project-overview--root)))
    (if (fboundp 'project-shell) (project-shell) (shell))))

(defun project-overview-changelog ()
  "Visit CHANGELOG.org of the project under point."
  (interactive)
  (let ((f (expand-file-name "CHANGELOG.org" (project-overview--root))))
    (if (file-exists-p f) (find-file f)
      (user-error "No CHANGELOG.org in this project"))))

(defun project-overview-bugs-file ()
  "Visit BUGS.org of the project under point."
  (interactive)
  (let ((f (expand-file-name "BUGS.org" (project-overview--root))))
    (if (file-exists-p f) (find-file f)
      (user-error "No BUGS.org in this project"))))

(defun project-overview-bugs-agenda ()
  "Show a TODO agenda scoped to the BUGS.org of the project under point."
  (interactive)
  (let ((f (expand-file-name "BUGS.org" (project-overview--root))))
    (unless (file-exists-p f) (user-error "No BUGS.org in this project"))
    (let ((org-agenda-files (list f)))
      (org-todo-list))))

(defun project-overview-changelog-preview ()
  "Preview the latest CHANGELOG.org entry for the project under point.
The entry is shown read-only in a right-hand side window."
  (interactive)
  (let ((f (expand-file-name "CHANGELOG.org" (project-overview--root)))
        text)
    (unless (file-readable-p f) (user-error "No CHANGELOG.org in this project"))
    (with-temp-buffer
      (insert-file-contents f)
      (goto-char (point-min))
      (when (re-search-forward "^\\*\\* " nil t)
        (beginning-of-line)
        (let ((start (point)))
          (forward-line 1)
          (if (re-search-forward "^\\*\\* " nil t)
              (beginning-of-line)
            (goto-char (point-max)))
          (setq text (buffer-substring start (point))))))
    (let ((buf (get-buffer-create "*Project CHANGELOG*")))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (or text "No entries"))
          (goto-char (point-min))
          (delay-mode-hooks (org-mode))
          (view-mode 1)))
      (display-buffer buf '(display-buffer-in-side-window
                            (side . right) (window-width . 0.4))))))

(defun project-overview-refresh ()
  "Re-scan all projects and redraw the dashboard."
  (interactive)
  (message "Scanning projects…")
  (project-overview--scan)
  (when (derived-mode-p 'project-overview-mode)
    (tabulated-list-print t))
  (message "Scanning projects…done"))

;;; Transient

(defun project-overview--menu-name ()
  "Return the name of the project under point, or nil."
  (when (tabulated-list-get-id)
    (file-name-nondirectory (directory-file-name (tabulated-list-get-id)))))

;;;###autoload (autoload 'project-overview-dispatch "project-overview" nil t)
(transient-define-prefix project-overview-dispatch ()
  "Act on the project under point in the `project-overview' dashboard."
  [:description
   (lambda () (concat "Project: " (or (project-overview--menu-name) "(none)")))
   ["Open"
    ("o" "switch to project" project-overview-open)
    ("f" "find file"         project-overview-find-file)
    ("d" "dired"             project-overview-dired)
    ("!" "shell"             project-overview-shell)]
   ["Inspect"
    ("c" "CHANGELOG.org"     project-overview-changelog)
    ("v" "preview changelog" project-overview-changelog-preview)
    ("b" "BUGS.org"          project-overview-bugs-file)
    ("B" "bugs agenda"       project-overview-bugs-agenda)]
   ["VC & search"
    ("m" "magit-status"      project-overview-magit)
    ("s" "search"            project-overview-search)]]
  ["Dashboard"
   ("g" "refresh" project-overview-refresh :transient t)
   ("q" "quit"    transient-quit-one)])

;;; Mode

(defvar project-overview-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'project-overview-open)
    (define-key map "o" #'project-overview-open)
    (define-key map "f" #'project-overview-find-file)
    (define-key map "m" #'project-overview-magit)
    (define-key map "s" #'project-overview-search)
    (define-key map "d" #'project-overview-dired)
    (define-key map "!" #'project-overview-shell)
    (define-key map "c" #'project-overview-changelog)
    (define-key map "v" #'project-overview-changelog-preview)
    (define-key map "b" #'project-overview-bugs-file)
    (define-key map "B" #'project-overview-bugs-agenda)
    (define-key map "g" #'project-overview-refresh)
    (define-key map "?" #'project-overview-dispatch)
    map)
  "Keymap for `project-overview-mode'.")

(define-derived-mode project-overview-mode tabulated-list-mode "Projects"
  "Major mode for the project dashboard.

\\{project-overview-mode-map}"
  (setq tabulated-list-format
        [("Project" 24 t)
         ("Version" 9 t)
         ("Changed" 12 t)
         ("Bugs" 7 t)
         ("Branch" 14 t)
         ("Git" 6 t)
         ("Commit" 12 t)])
  (setq tabulated-list-sort-key '("Project" . nil))
  (setq tabulated-list-entries #'project-overview--entries)
  (tabulated-list-init-header))

;;;###autoload
(defun project-overview ()
  "Open the project dashboard: a table of git projects with status and actions."
  (interactive)
  (message "Scanning projects…")
  (project-overview--scan)
  (let ((buf (get-buffer-create project-overview-buffer-name)))
    (with-current-buffer buf
      (project-overview-mode)
      (tabulated-list-print))
    (pop-to-buffer-same-window buf))
  (message "Scanning projects…done"))

(provide 'project-overview)
;;; project-overview.el ends here
