;;; project-overview.el --- Dashboard of git projects with status and actions -*- lexical-binding: t; -*-

;; Author: James Dyer <captainflasmr@gmail.com>
;; Maintainer: James Dyer <captainflasmr@gmail.com>
;; Keywords: tools, vc, convenience
;; Version: 0.2.0
;; Package-Version: 0.2.0
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
;; opens a `tabulated-list-mode' buffer with one row per project: the git
;; repositories found under `project-overview-search-roots' plus, when
;; `project-overview-include-known-projects' is on, the projects Emacs
;; already knows about (the `project-switch-project' list).  Each row
;; shows:
;;
;;   - the latest CHANGELOG.org version and date,
;;   - the open/total bug count from BUGS.org,
;;   - git branch, dirty flag, and ahead/behind state,
;;   - the remote forge (github, gitlab, …) or blank for local-only,
;;   - a check mark when the project is on Emacs's known-projects list,
;;   - the last commit date, and
;;   - a one-line description taken from the project's README.
;;
;; A header line summarises the whole set: total projects, how many are
;; dirty, how many are out of sync with upstream, and the open bug count.
;; The mode line shows the full path of the project under point.
;;
;; Single keys act on the project under point, reusing project.el where
;; possible.  See `project-overview-mode-map' for the full set:
;;
;; Keys mirroring the `project-switch-project' menu act on the project
;; under point:
;;
;;   RET / o  switch to project        c  preview latest CHANGELOG entry
;;   f        find file                C  open CHANGELOG.org (window right)
;;   G        find regexp              b  open BUGS.org (window right)
;;   d        find directory           B  TODO agenda for this project's bugs
;;   e        eshell                   A  TODO agenda for all projects' bugs
;;   s        search (ripgrep)         /  filter the view (transient)
;;   v        vc-dir                   g  refresh (re-scan)
;;   m        magit-status             ?  transient menu of all actions
;;   D        dired at root
;;   !        shell at root
;;
;; `/' (`project-overview-filter-dispatch') narrows the table to a subset:
;; dirty repos, repos with open bugs, repos out of sync with upstream, or
;; a name regexp.  The active filter and shown/total count appear in the
;; mode line, and survive a refresh until cleared with `/ a'.
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
(declare-function project-known-project-roots "project" ())
(defvar org-agenda-files)
(defvar org-agenda-prefix-format)
(defvar org-agenda-sticky)
(defvar project-current-directory-override)

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

(defcustom project-overview-include-known-projects t
  "When non-nil, also list projects Emacs already knows about.
These are the roots offered by `project-switch-project', as returned by
`project-known-project-roots', merged with the git repositories found
under `project-overview-search-roots'."
  :type 'boolean
  :group 'project-overview)

(defcustom project-overview-buffer-name "*Projects*"
  "Name of the dashboard buffer."
  :type 'string
  :group 'project-overview)

;;; Internal state

(defvar project-overview--cache nil
  "Alist of (ROOT . PLIST) holding scanned project data for the dashboard.")

(defvar-local project-overview--filter nil
  "Active dashboard filter, or nil to show every project.
When set, a cons (LABEL . PREDICATE): PREDICATE receives a
\(ROOT . PLIST) cache cell and returns non-nil to keep that project;
LABEL is a short string shown in the mode line.")

;;; Scanning

(defun project-overview--git (root &rest args)
  "Run git in ROOT with ARGS, returning trimmed output or nil on failure."
  (when (file-directory-p (expand-file-name ".git" root))
    (with-temp-buffer
      (when (zerop (apply #'process-file "git" nil t nil
                          (append (list "-C" (expand-file-name root)) args)))
        (string-trim (buffer-string))))))

(defun project-overview--discover ()
  "Return the sorted list of project roots to display.
Combines git repositories found under `project-overview-search-roots'
\(each root and one level of subdirectories) with the projects Emacs
already knows about — `project-known-project-roots', the same list
`project-switch-project' offers — when
`project-overview-include-known-projects' is non-nil.  Roots are
normalised and de-duplicated; missing directories and names matching
`project-overview-exclude-regexp' are dropped."
  (let (roots)
    ;; Git repositories under the configured search roots.
    (dolist (root project-overview-search-roots)
      (setq root (expand-file-name root))
      (when (file-directory-p root)
        (when (file-directory-p (expand-file-name ".git" root))
          (push root roots))
        (dolist (sub (directory-files root t "^[^.]"))
          (when (and (file-directory-p sub)
                     (file-directory-p (expand-file-name ".git" sub)))
            (push sub roots)))))
    ;; Projects Emacs already knows about (the `project-switch-project' list).
    (when (and project-overview-include-known-projects
               (fboundp 'project-known-project-roots))
      (setq roots (nconc (project-known-project-roots) roots)))
    ;; Normalise, drop missing/excluded, de-duplicate, and sort.
    (let ((seen (make-hash-table :test 'equal))
          result)
      (dolist (r roots)
        (let ((dir (directory-file-name (expand-file-name r))))
          (when (and (not (gethash dir seen))
                     (file-directory-p dir)
                     (not (string-match-p
                           project-overview-exclude-regexp
                           (file-name-nondirectory dir))))
            (puthash dir t seen)
            (push dir result))))
      (sort result #'string<))))

(defun project-overview--known-roots ()
  "Return a hash table of normalised `project-known-project-roots'.
Keys match the normalised roots produced by `project-overview--discover',
so membership can be tested with `gethash'."
  (let ((h (make-hash-table :test 'equal)))
    (when (fboundp 'project-known-project-roots)
      (dolist (r (project-known-project-roots))
        (puthash (directory-file-name (expand-file-name r)) t h)))
    h))

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

(defun project-overview--prose-line-p (line)
  "Non-nil if LINE looks like README prose rather than markup."
  (not (or (string-empty-p line)
           (string-prefix-p "#" line)    ; org keyword / md heading
           (string-prefix-p "*" line)    ; org heading
           (string-prefix-p "|" line)    ; table
           (string-prefix-p ">" line)    ; block quote
           (string-prefix-p "-" line)    ; list item / horizontal rule
           (string-prefix-p ":" line)))) ; org drawer / property

(defun project-overview--clean-text (s)
  "Strip light org/markdown inline markup from S and collapse whitespace."
  (string-trim
   (replace-regexp-in-string
    "[ \t\n]+" " " (replace-regexp-in-string "[=~*/`_]" "" s))))

(defun project-overview--description (root)
  "Return a one-line description for ROOT taken from its README.
Reads the first prose paragraph of README.org or README.md, collapses
it to a single line, and trims it to the first sentence.  Returns an
empty string when no README or prose is found."
  (let ((readme (seq-find #'file-readable-p
                          (list (expand-file-name "README.org" root)
                                (expand-file-name "README.md" root)
                                (expand-file-name "readme.org" root)))))
    (if (not readme)
        ""
      (with-temp-buffer
        (insert-file-contents readme nil 0 4000)
        (goto-char (point-min))
        (let (para)
          (catch 'done
            (while (not (eobp))
              (let ((line (string-trim
                           (buffer-substring (line-beginning-position)
                                             (line-end-position)))))
                (cond
                 ((project-overview--prose-line-p line) (push line para))
                 (para (throw 'done nil))))
              (forward-line 1)))
          (let ((text (project-overview--clean-text
                       (mapconcat #'identity (nreverse para) " "))))
            (if (string-match "\\`\\(.+?[.!?]\\)\\(?:[ \t]\\|\\'\\)" text)
                (match-string 1 text)
              text)))))))

(defun project-overview--remote-host (url)
  "Return a short forge label for git remote URL, or \"\" when unknown.
Recognises common forges by name and otherwise falls back to the bare
host extracted from the URL (handles https://, ssh:// and scp-like
\"git@host:path\" forms)."
  (if (or (null url) (string-empty-p url))
      ""
    (cond
     ((string-match-p "github\\.com" url)    "github")
     ((string-match-p "gitlab\\.com" url)    "gitlab")
     ((string-match-p "codeberg\\.org" url)  "codeberg")
     ((string-match-p "bitbucket\\.org" url) "bitbucket")
     ((string-match-p "\\(?:sr\\.ht\\|sourcehut\\)" url) "sourcehut")
     ((string-match "\\(?:://\\(?:[^@/]+@\\)?\\|@\\)\\([^/:]+\\)" url)
      (match-string 1 url))
     (t ""))))

(defun project-overview--remote-url (root)
  "Return the URL of ROOT's origin remote, or the first remote, else nil."
  (or (project-overview--git root "config" "--get" "remote.origin.url")
      (let ((remotes (project-overview--git root "remote")))
        (when (and remotes (not (string-empty-p remotes)))
          (project-overview--git root "config" "--get"
                                 (format "remote.%s.url"
                                         (car (split-string remotes "\n"))))))))

(defun project-overview--git-info (root)
  "Return a plist :branch :dirty :commit :ahead :behind :host for ROOT."
  (let* ((branch (or (project-overview--git root "symbolic-ref" "--short" "HEAD")
                     (project-overview--git root "rev-parse" "--short" "HEAD")
                     ""))
         (status (project-overview--git root "status" "--porcelain"))
         (dirty (and status (> (length status) 0)))
         (commit (or (project-overview--git root "log" "-1" "--format=%cd"
                                            "--date=format:%Y-%m-%d %H:%M")
                     ""))
         (ab (project-overview--git root "rev-list" "--left-right" "--count"
                                    "HEAD...@{u}"))
         (host (project-overview--remote-host
                (project-overview--remote-url root)))
         ahead behind)
    (when (and ab (string-match "\\([0-9]+\\)[ \t]+\\([0-9]+\\)" ab))
      (setq ahead (string-to-number (match-string 1 ab))
            behind (string-to-number (match-string 2 ab))))
    (list :branch branch :dirty dirty :commit commit
          :ahead (or ahead 0) :behind (or behind 0) :host host)))

(defun project-overview--scan ()
  "Scan all discovered projects and populate `project-overview--cache'."
  (let ((known (project-overview--known-roots)))
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
                           :desc (project-overview--description root)
                           :known (and (gethash root known) t)
                           :git git))))
           (project-overview--discover)))))

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

(defun project-overview--entry (cell)
  "Build a `tabulated-list-entries' row from cache CELL."
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
                  (or (plist-get git :host) "")
                  (if (plist-get p :known) "✓" "")
                  (plist-get git :commit)
                  (propertize (plist-get p :desc) 'face 'shadow)))))

(defun project-overview--entries ()
  "Build `tabulated-list-entries', honouring the active filter."
  (mapcar #'project-overview--entry
          (if project-overview--filter
              (seq-filter (cdr project-overview--filter)
                          project-overview--cache)
            project-overview--cache)))

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

;; The following commands mirror the entries on the `project-switch-project'
;; menu, applied to the project under point.  Each runs the standard
;; project.el command with the project context bound to that root.

(defun project-overview--run-project-command (command)
  "Call COMMAND with the project context set to the project under point."
  (let* ((root (project-overview--root))
         (default-directory root)
         (project-current-directory-override root))
    (call-interactively command)))

(defun project-overview-find-regexp ()
  "Run `project-find-regexp' in the project under point."
  (interactive)
  (project-overview--run-project-command #'project-find-regexp))

(defun project-overview-find-dir ()
  "Run `project-find-dir' in the project under point."
  (interactive)
  (project-overview--run-project-command #'project-find-dir))

(defun project-overview-vc-dir ()
  "Run `project-vc-dir' in the project under point."
  (interactive)
  (project-overview--run-project-command #'project-vc-dir))

(defun project-overview-eshell ()
  "Run `project-eshell' in the project under point."
  (interactive)
  (project-overview--run-project-command #'project-eshell))

(defun project-overview-changelog ()
  "Visit CHANGELOG.org of the project under point in a window to the right."
  (interactive)
  (let ((f (expand-file-name "CHANGELOG.org" (project-overview--root))))
    (unless (file-exists-p f) (user-error "No CHANGELOG.org in this project"))
    (select-window
     (display-buffer (find-file-noselect f)
                     '(display-buffer-in-direction (direction . right))))))

(defun project-overview-bugs-file ()
  "Visit BUGS.org of the project under point in a window to the right."
  (interactive)
  (let ((f (expand-file-name "BUGS.org" (project-overview--root))))
    (unless (file-exists-p f) (user-error "No BUGS.org in this project"))
    (select-window
     (display-buffer (find-file-noselect f)
                     '(display-buffer-in-direction (direction . right))))))

;;; Bugs agenda (single project and all projects)

(defun project-overview--bugs-files ()
  "Return the BUGS.org files of every discovered project, sorted."
  (let (files)
    (dolist (root (project-overview--discover))
      (let ((f (expand-file-name "BUGS.org" root)))
        (when (file-exists-p f)
          (push f files))))
    (sort files #'string<)))

(defun project-overview--bugs-category (orig-fun &optional pos force-refresh)
  "Advise `org-get-category' (ORIG-FUN) for BUGS.org files.
Use the parent directory name as the category instead of the default
\"BUGS\" so every entry shows its project.
POS and FORCE-REFRESH are passed through unchanged."
  (let ((cat (funcall orig-fun pos force-refresh)))
    (if (and (equal cat "BUGS")
             (buffer-file-name)
             (string-suffix-p "/BUGS.org" (buffer-file-name)))
        (file-name-nondirectory
         (directory-file-name
          (file-name-directory (buffer-file-name))))
      cat)))

(advice-add 'org-get-category :around #'project-overview--bugs-category)

(defvar project-overview--bugs-agenda-files nil
  "BUGS.org files backing the most recent bugs agenda.
Set by `project-overview--bugs-agenda' so that `org-agenda-redo'
re-runs against the same files instead of the global
`org-agenda-files'.")

(defvar project-overview--bugs-agenda-prefix-format nil
  "Prefix format for the most recent bugs agenda.
Set by `project-overview--bugs-agenda' so that redo preserves the
column alignment between project, tags, and TODO headline.")

(defun project-overview--around-org-agenda-redo (orig-fun &rest args)
  "Wrap `org-agenda-redo' (ORIG-FUN) to keep the bugs agenda scope.
Without this advice, re-running the TODO agenda after a
`project-overview' bugs command would fall back to the global
`org-agenda-files' and default prefix, losing the BUGS.org scope and
column alignment.  ARGS are forwarded to ORIG-FUN."
  (if project-overview--bugs-agenda-files
      (let ((org-agenda-files project-overview--bugs-agenda-files)
            (org-agenda-prefix-format project-overview--bugs-agenda-prefix-format))
        (apply orig-fun args))
    (apply orig-fun args)))

(advice-add 'org-agenda-redo :around #'project-overview--around-org-agenda-redo)

(defun project-overview--bugs-agenda-exit ()
  "Clear the saved bugs agenda state on agenda exit."
  (setq project-overview--bugs-agenda-files nil
        project-overview--bugs-agenda-prefix-format nil))

(add-hook 'org-agenda-exit-hook #'project-overview--bugs-agenda-exit)

(defun project-overview--bugs-agenda (files)
  "Show a TODO agenda over FILES, categorised by project.
Records FILES and the column-aligned prefix format so that redo
commands (such as \"g\") keep the same scope rather than reverting to
the global `org-agenda-files'."
  (let* ((fmt (if (listp org-agenda-prefix-format)
                  org-agenda-prefix-format
                (default-value 'org-agenda-prefix-format)))
         (bugs-prefix
          (mapcar (lambda (item)
                    (if (eq (car item) 'todo)
                        (cons 'todo " %i %-20:c %-10t %s")
                      item))
                  fmt)))
    (setq project-overview--bugs-agenda-files files
          project-overview--bugs-agenda-prefix-format bugs-prefix)
    (let ((org-agenda-files files)
          (org-agenda-prefix-format bugs-prefix)
          ;; Force regeneration: with `org-agenda-sticky' enabled, both
          ;; commands map to the same TODO agenda buffer and the second
          ;; call would reuse the first call's contents instead of
          ;; rescanning the new file set.
          (org-agenda-sticky nil))
      (org-todo-list))))

(defun project-overview-bugs-agenda ()
  "Show a TODO agenda scoped to the BUGS.org of the project under point."
  (interactive)
  (let ((f (expand-file-name "BUGS.org" (project-overview--root))))
    (unless (file-exists-p f) (user-error "No BUGS.org in this project"))
    (project-overview--bugs-agenda (list f))))

;;;###autoload
(defun project-overview-bugs-agenda-all ()
  "Show a single TODO agenda for the BUGS.org of every discovered project.
Each entry is prefixed with its project directory name, and redo
commands (such as \"g\") keep the same BUGS.org scope and alignment."
  (interactive)
  (let ((files (project-overview--bugs-files)))
    (unless files (user-error "No BUGS.org files found in any project"))
    (project-overview--bugs-agenda files)))

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
          (visual-line-mode 1)
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

;;; Filtering

(defun project-overview--filter-dirty (cell)
  "Keep CELL when its worktree has uncommitted changes."
  (plist-get (plist-get (cdr cell) :git) :dirty))

(defun project-overview--filter-bugs (cell)
  "Keep CELL when it has open (non-DONE) BUGS.org entries."
  (> (plist-get (cdr cell) :open) 0))

(defun project-overview--filter-out-of-sync (cell)
  "Keep CELL when it is ahead of or behind its upstream."
  (let ((git (plist-get (cdr cell) :git)))
    (or (> (plist-get git :ahead) 0)
        (> (plist-get git :behind) 0))))

(defun project-overview--apply-filter (label predicate)
  "Filter the dashboard to projects matching PREDICATE, described by LABEL.
A nil PREDICATE clears the filter.  Updates the mode line with the
shown/total counts and redraws."
  (setq project-overview--filter (and predicate (cons label predicate)))
  (let* ((total (length project-overview--cache))
         (shown (if predicate
                    (seq-count predicate project-overview--cache)
                  total)))
    (setq-local mode-line-process
                (and predicate (format " [%s %d/%d]" label shown total)))
    (force-mode-line-update)
    (when (derived-mode-p 'project-overview-mode)
      (tabulated-list-print t))
    (message "Filter: %s — %d/%d project%s"
             label shown total (if (= shown 1) "" "s"))))

(defun project-overview-filter-dirty ()
  "Show only projects with uncommitted changes."
  (interactive)
  (project-overview--apply-filter "dirty" #'project-overview--filter-dirty))

(defun project-overview-filter-bugs ()
  "Show only projects with open BUGS.org entries."
  (interactive)
  (project-overview--apply-filter "open bugs" #'project-overview--filter-bugs))

(defun project-overview-filter-out-of-sync ()
  "Show only projects ahead of or behind their upstream."
  (interactive)
  (project-overview--apply-filter "out of sync"
                                  #'project-overview--filter-out-of-sync))

(defun project-overview-filter-name (regexp)
  "Show only projects whose name matches REGEXP."
  (interactive (list (read-regexp "Filter projects by name (regexp): ")))
  (project-overview--apply-filter
   (format "name~%s" regexp)
   (lambda (cell)
     (string-match-p regexp (plist-get (cdr cell) :name)))))

(defun project-overview-filter-clear ()
  "Clear any active filter and show every project."
  (interactive)
  (project-overview--apply-filter "all" nil))

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
   ["Find"
    ("o" "switch to project" project-overview-open)
    ("f" "find file"         project-overview-find-file)
    ("G" "find regexp"       project-overview-find-regexp)
    ("d" "find directory"    project-overview-find-dir)
    ("e" "eshell"            project-overview-eshell)
    ("D" "dired"             project-overview-dired)
    ("!" "shell"             project-overview-shell)]
   ["Inspect"
    ("c" "preview changelog" project-overview-changelog-preview)
    ("C" "CHANGELOG.org"     project-overview-changelog)
    ("b" "BUGS.org"          project-overview-bugs-file)
    ("B" "bugs agenda"       project-overview-bugs-agenda)
    ("A" "bugs agenda (all)" project-overview-bugs-agenda-all)]
   ["VC & search"
    ("v" "vc-dir"            project-overview-vc-dir)
    ("m" "magit-status"      project-overview-magit)
    ("s" "search"            project-overview-search)]]
  ["Dashboard"
   ("/" "filter…" project-overview-filter-dispatch)
   ("g" "refresh" project-overview-refresh :transient t)
   ("q" "quit"    transient-quit-one)])

;;;###autoload (autoload 'project-overview-filter-dispatch "project-overview" nil t)
(transient-define-prefix project-overview-filter-dispatch ()
  "Filter the `project-overview' dashboard to a subset of projects."
  ["Show only projects that are…"
   ("d" "dirty (uncommitted changes)" project-overview-filter-dirty)
   ("b" "with open bugs"              project-overview-filter-bugs)
   ("u" "out of sync (ahead/behind)"  project-overview-filter-out-of-sync)
   ("n" "matching a name regexp…"     project-overview-filter-name)]
  ["Filter"
   ("a" "all (clear filter)"          project-overview-filter-clear)
   ("q" "quit"                        transient-quit-one)])

;;; Header line

(defun project-overview--header-count (n label)
  "Return header-line segment \" · N LABEL\", bold when N is positive.
Bold only sets the weight, so the colour stays that of the surrounding
`header-line' face."
  (let ((s (format " · %d %s" n label)))
    (if (> n 0) (propertize s 'face 'bold) s)))

(defun project-overview--header-line ()
  "Return the aggregate status header-line for the dashboard.
The leading counts are taken from the full project set; when a filter
is active it is appended, with the number of projects it shows.  Only
weight (bold) is used for emphasis, so the whole line keeps the theme's
`header-line' colour and stays readable."
  (let* ((cache project-overview--cache)
         (total (length cache))
         (dirty (seq-count #'project-overview--filter-dirty cache))
         (sync  (seq-count #'project-overview--filter-out-of-sync cache))
         (buggy (seq-count #'project-overview--filter-bugs cache))
         (open  (apply #'+ (mapcar (lambda (c) (plist-get (cdr c) :open)) cache))))
    (concat
     (propertize (format " %d project%s" total (if (= total 1) "" "s"))
                 'face 'bold)
     (project-overview--header-count dirty "dirty")
     (project-overview--header-count sync "out of sync")
     (project-overview--header-count
      open (format "open bug%s%s"
                   (if (= open 1) "" "s")
                   (if (> buggy 0) (format " in %d" buggy) "")))
     (when project-overview--filter
       (let ((shown (seq-count (cdr project-overview--filter) cache)))
         (propertize (format "    ⦅ filter: %s — %d shown ⦆"
                             (car project-overview--filter) shown)
                     'face 'bold))))))

(defun project-overview--path-mode-line ()
  "Return the abbreviated path of the project under point for the mode line."
  (let ((root (and (derived-mode-p 'project-overview-mode)
                   (tabulated-list-get-id))))
    (if root
        (concat "  " (abbreviate-file-name (directory-file-name root)))
      "")))

;;; Mode

(defvar project-overview-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'project-overview-open)
    (define-key map "o" #'project-overview-open)
    ;; Project actions mirroring the `project-switch-project' menu.
    (define-key map "f" #'project-overview-find-file)
    (define-key map "G" #'project-overview-find-regexp)
    (define-key map "d" #'project-overview-find-dir)
    (define-key map "v" #'project-overview-vc-dir)
    (define-key map "e" #'project-overview-eshell)
    (define-key map "s" #'project-overview-search)
    (define-key map "m" #'project-overview-magit)
    (define-key map "D" #'project-overview-dired)
    (define-key map "!" #'project-overview-shell)
    ;; Inspect.
    (define-key map "c" #'project-overview-changelog-preview)
    (define-key map "C" #'project-overview-changelog)
    (define-key map "b" #'project-overview-bugs-file)
    (define-key map "B" #'project-overview-bugs-agenda)
    (define-key map "A" #'project-overview-bugs-agenda-all)
    ;; Dashboard.
    (define-key map "/" #'project-overview-filter-dispatch)
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
         ("ChangeLog" 12 t)
         ("Bugs" 7 t)
         ("Branch" 14 t)
         ("Git" 6 t)
         ("Remote" 10 t)
         ("Known" 6 t)
         ("Commit" 17 t)
         ("Description" 50 t)])
  ;; Most recently committed projects first.
  (setq tabulated-list-sort-key '("Commit" . t))
  (setq tabulated-list-entries #'project-overview--entries)
  ;; Free the window header line for the aggregate summary by printing the
  ;; (still sortable) column headers at the top of the buffer instead.
  (setq tabulated-list-use-header-line nil)
  (tabulated-list-init-header)
  (setq header-line-format '(:eval (project-overview--header-line)))
  ;; Show the full path of the project under point at the end of the mode line.
  (setq-local mode-line-format
              (append mode-line-format
                      '((:eval (project-overview--path-mode-line))))))

;;;###autoload
(defun project-overview ()
  "Open the project dashboard: a table of git projects with status and actions."
  (interactive)
  (message "Scanning projects…")
  (project-overview--scan)
  (let ((buf (get-buffer-create project-overview-buffer-name)))
    (with-current-buffer buf
      (project-overview-mode)
      (tabulated-list-print)
      ;; Start point on the first project row, past the in-buffer header.
      (goto-char (point-min))
      (while (and (not (eobp)) (not (tabulated-list-get-id)))
        (forward-line 1)))
    (pop-to-buffer-same-window buf))
  (message "Scanning projects…done"))

(provide 'project-overview)
;;; project-overview.el ends here
