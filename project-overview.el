;;; project-overview.el --- Dashboard of git projects with status and actions -*- lexical-binding: t; -*-

;; Author: James Dyer <captainflasmr@gmail.com>
;; Maintainer: James Dyer <captainflasmr@gmail.com>
;; Keywords: tools, vc, convenience
;; Version: 0.3.0
;; Package-Version: 0.3.0
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
;;   - the remote owner/user (e.g. the GitHub username),
;;   - for GitHub repos, the open issue and PR counts (via the gh CLI),
;;   - a check mark when the project is on Emacs's known-projects list,
;;   - a check mark when a package of the same name is available on MELPA,
;;   - the last commit date,
;;   - a one-line description taken from the project's README, and
;;   - the project's root path.
;;
;; A header line summarises the whole set: total projects, how many are
;; dirty, how many are out of sync with upstream, the open bug count,
;; — across the repos owned by `project-overview-github-user' — the total
;; open GitHub issues and pull requests, and the active view.
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
;;   m        magit-status             r  cache / pull (transient)
;;   D        dired at root            ?  transient menu of all actions
;;   !        shell at root            V  cycle column layout
;;                                     t  toggle the Description column
;;                                     i  open GitHub issues (Org buffer)
;;                                     P  open GitHub PRs (Org buffer)
;;
;; `/' (`project-overview-filter-dispatch') narrows the table to a subset:
;; dirty repos, repos with open bugs, repos out of sync with upstream, or
;; a name regexp.  The active filter and shown/total count appear in the
;; mode line, and survive a refresh until cleared with `/ a'.
;;
;; `project-overview-dispatch' (bound to ? in the dashboard) presents the
;; same actions as a transient menu, headed by the project under point.
;;
;; `V' (`project-overview-cycle-view') steps through the named column
;; layouts in `project-overview-views' — `full' (every column),
;; `minimal', `status' (branch/git/bugs), and `remote' (forge/owner) —
;; one per press, wrapping round (a prefix arg cycles backwards); stop on
;; the one you want.  The opening layout is `project-overview-default-view';
;; unless `project-overview-remember-view' is nil, the last view chosen
;; with `V' is remembered via `savehist' and reused as the opening
;; layout in the next session.
;;
;; Network data — the MELPA package list and per-repository GitHub
;; issue/PR counts — is cached on disk in `project-overview-cache-file'
;; with a `project-overview-cache-ttl' lifetime, so it survives restarts
;; and an ordinary refresh (`g') need not hit the network.  `r'
;; (`project-overview-cache-dispatch') force-pulls fresh GitHub counts,
;; the MELPA list, or everything, and can clear the cache.
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
(defvar savehist-additional-variables)
(defvar package-archive-contents)
(declare-function package-desc-archive "package" (cl-x))
(declare-function url-retrieve "url"
                  (url callback &optional cbargs silent inhibit-cookies))

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

(defcustom project-overview-show-github t
  "When non-nil, fetch open issue and PR counts for GitHub repositories.
Counts are retrieved asynchronously with the GitHub CLI (\"gh\", which
must be installed and authenticated) and shown in the GitHub column,
filling in shortly after the dashboard is drawn.  Set to nil to skip
the network calls entirely."
  :type 'boolean
  :group 'project-overview)

(defcustom project-overview-github-user "captainflasmr"
  "GitHub username whose repositories are summarised in the header line.
The total open issues and pull requests across the projects owned by
this user (matched on the remote owner) are shown alongside the other
header-line counts.  Set to nil or the empty string to omit that
summary."
  :type '(choice (const :tag "None" nil) string)
  :group 'project-overview)

(defcustom project-overview-melpa-fallback t
  "When non-nil, fall back to fetching the MELPA package list from melpa.org.
Used only when package.el has no local MELPA archive contents (so the
MELPA column would otherwise be blank).  The list is downloaded once
per session, asynchronously, and the column fills in when it arrives.
Set to nil to keep the MELPA check entirely offline."
  :type 'boolean
  :group 'project-overview)

(defcustom project-overview-cache-file
  (locate-user-emacs-file "project-overview-cache.el")
  "File persisting network-derived data between sessions.
Holds the fetched MELPA package list and per-repository GitHub
issue/PR counts, each stamped with a fetch time so it can expire (see
`project-overview-cache-ttl').  Set to nil to keep this data for the
current session only."
  :type '(choice file (const :tag "Session only" nil))
  :group 'project-overview)

(defcustom project-overview-cache-ttl 86400
  "Seconds a cached network result stays fresh before being re-fetched.
Applies to the MELPA package list and to per-repository GitHub counts.
A normal refresh (\\[project-overview-refresh]) reuses cached data
while it is fresh; the pull commands in `project-overview-cache-dispatch'
force a re-fetch regardless."
  :type 'integer
  :group 'project-overview)

(defcustom project-overview-views
  '((full    . (name version changelog bugs branch git remote owner github known
                     melpa commit description path))
    (minimal . (name version bugs commit path))
    (status  . (name bugs branch git github commit))
    (remote  . (name remote owner github known melpa path)))
  "Named column layouts for the dashboard.
Each entry is (NAME . COLUMNS) where COLUMNS is a list of column ids
drawn from `project-overview--columns'.  `project-overview-set-view'
and the view transient switch between them; `full' lists every column."
  :type '(alist :key-type symbol :value-type (repeat symbol))
  :group 'project-overview)

(defcustom project-overview-default-view 'full
  "Column layout used when the dashboard first opens.
Must be a key of `project-overview-views'.  When
`project-overview-remember-view' is non-nil, a view chosen with
`project-overview-set-view' is remembered in
`project-overview-state-file' and takes precedence over this value."
  :type 'symbol
  :group 'project-overview)

(defcustom project-overview-remember-view t
  "When non-nil, remember the last view chosen with `project-overview-set-view'.
The choice is stored in `project-overview-saved-view', which is
registered with `savehist' so it persists across sessions and becomes
the opening layout next time."
  :type 'boolean
  :group 'project-overview)

;;; Internal state

(defvar project-overview--cache nil
  "Alist of (ROOT . PLIST) holding scanned project data for the dashboard.")

(defvar-local project-overview--filter nil
  "Active dashboard filter, or nil to show every project.
When set, a cons (LABEL . PREDICATE): PREDICATE receives a
\(ROOT . PLIST) cache cell and returns non-nil to keep that project;
LABEL is a short string shown in the mode line.")

(defvar-local project-overview--view nil
  "Symbol naming the active column layout, or nil for the default.
Resolved against `project-overview-views', falling back to
`project-overview-default-view' then `full'.")

;;; Persistent cache

;; A single on-disk store (`project-overview-cache-file') holds the
;; network-derived data that is slow or rate-limited to obtain: the MELPA
;; package list and per-repository GitHub issue/PR counts.  Each entry is
;; time-stamped so it can expire after `project-overview-cache-ttl', and
;; the pull commands can force a refresh.

(defvar project-overview--cache-store 'unset
  "In-memory copy of `project-overview-cache-file'.
The sentinel `unset' means the file has not been read yet; otherwise a
plist with keys :melpa and :github (see the cache accessors).")

(defvar project-overview--melpa-cache nil
  "Hash table of package symbols available from MELPA, or nil.
Populated from the persistent cache or a melpa.org fetch and used as a
fallback when the local `package-archive-contents' lacks MELPA.")

(defvar project-overview--melpa-fetching nil
  "Non-nil while a melpa.org archive fetch is in flight.")

(defun project-overview--cache-load ()
  "Read `project-overview-cache-file' into `project-overview--cache-store'.
Reads at most once; subsequent calls are no-ops until the store is
reset.  A missing or unreadable file yields an empty store."
  (when (eq project-overview--cache-store 'unset)
    (setq project-overview--cache-store
          (or (and project-overview-cache-file
                   (file-readable-p project-overview-cache-file)
                   (ignore-errors
                     (with-temp-buffer
                       (insert-file-contents project-overview-cache-file)
                       (read (current-buffer)))))
              nil)))
  project-overview--cache-store)

(defun project-overview--cache-save ()
  "Write `project-overview--cache-store' to `project-overview-cache-file'."
  (when (and project-overview-cache-file
             (not (eq project-overview--cache-store 'unset)))
    (ignore-errors
      (with-temp-file project-overview-cache-file
        (let ((print-length nil) (print-level nil))
          (prin1 project-overview--cache-store (current-buffer))
          (terpri (current-buffer)))))))

(defun project-overview--cache-get (key)
  "Return the cached value stored under KEY."
  (project-overview--cache-load)
  (plist-get project-overview--cache-store key))

(defun project-overview--cache-put (key value)
  "Store VALUE under KEY in the cache and persist it."
  (project-overview--cache-load)
  (setq project-overview--cache-store
        (plist-put project-overview--cache-store key value))
  (project-overview--cache-save))

(defun project-overview--cache-fresh-p (time)
  "Return non-nil when TIME (a float-time) is within the cache TTL."
  (and (numberp time)
       (< (- (float-time) time) project-overview-cache-ttl)))

(defun project-overview--cache-reset ()
  "Forget the on-disk cache and any in-memory derivations of it."
  (when (and project-overview-cache-file
             (file-exists-p project-overview-cache-file))
    (ignore-errors (delete-file project-overview-cache-file)))
  (setq project-overview--cache-store nil
        project-overview--melpa-cache nil))

(defun project-overview--redraw ()
  "Reprint the live dashboard buffer in place, keeping point."
  (let ((buf (get-buffer project-overview-buffer-name)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (derived-mode-p 'project-overview-mode)
          (tabulated-list-print t))))))

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

(defun project-overview--melpa-local-names ()
  "Return a hash table of package names (symbols) available from MELPA.
Built from `package-archive-contents', so it reflects the archives the
user has configured and refreshed; a package counts when any of its
available versions comes from the \"melpa\" or \"melpa-stable\" archive.
Empty when package.el has no archive contents loaded."
  (let ((h (make-hash-table :test 'eq)))
    (when (and (require 'package nil t)
               (bound-and-true-p package-archive-contents))
      (dolist (entry package-archive-contents)
        (when (seq-find (lambda (desc)
                          (member (package-desc-archive desc)
                                  '("melpa" "melpa-stable")))
                        (cdr entry))
          (puthash (car entry) t h))))
    h))

(defun project-overview--melpa-cache-load ()
  "Populate `project-overview--melpa-cache' from the persistent cache.
Loads the stored melpa.org name list into a hash table when it is
present and still fresh.  Returns the in-memory table (possibly nil)."
  (when (not project-overview--melpa-cache)
    (let ((entry (project-overview--cache-get :melpa)))
      (when (and entry (project-overview--cache-fresh-p (car entry)))
        (let ((h (make-hash-table :test 'eq)))
          (dolist (s (cdr entry)) (puthash s t h))
          (setq project-overview--melpa-cache h)))))
  project-overview--melpa-cache)

(defun project-overview--melpa-names ()
  "Return the MELPA package-name set to use when scanning.
Prefers the local `package-archive-contents'; when that has no MELPA
entries, falls back to the cached melpa.org list (from disk or a
previous fetch), which may be empty until one arrives."
  (let ((local (project-overview--melpa-local-names)))
    (if (> (hash-table-count local) 0)
        local
      (project-overview--melpa-cache-load)
      (or project-overview--melpa-cache local))))

(defun project-overview--melpa-apply (table)
  "Recompute each project's :melpa flag from TABLE and redraw.
Used after a melpa.org fetch to fill the MELPA column."
  (dolist (cell project-overview--cache)
    (let ((name (plist-get (cdr cell) :name)))
      (setcdr cell (plist-put (cdr cell) :melpa
                              (and (gethash (intern name) table) t)))))
  (project-overview--redraw))

(defun project-overview--melpa-fetch-callback (status)
  "Parse the melpa.org archive in the current buffer, cache it, and apply.
STATUS is the `url-retrieve' status plist."
  (unwind-protect
      (unless (plist-get status :error)
        (goto-char (point-min))
        (when (re-search-forward "\n\r?\n" nil t)
          (let ((data (ignore-errors
                        (json-parse-buffer :object-type 'alist
                                           :null-object nil))))
            (when data
              (let ((h (make-hash-table :test 'eq))
                    (names (mapcar #'car data)))
                (dolist (s names) (puthash s t h))
                (setq project-overview--melpa-cache h)
                (project-overview--cache-put :melpa (cons (float-time) names))
                (project-overview--melpa-apply h))))))
    (setq project-overview--melpa-fetching nil)
    (when (buffer-live-p (current-buffer))
      (kill-buffer (current-buffer)))))

(defun project-overview--melpa-maybe-fetch (&optional force)
  "Fetch the melpa.org package list asynchronously if needed.
No-op unless `project-overview-melpa-fallback' is on, no fetch is in
flight, and the local archive contents lack MELPA.  Without FORCE, a
fresh cached list (in memory or on disk) is reused instead of
re-fetching; FORCE ignores the cache and pulls a new copy."
  (when (and project-overview-melpa-fallback
             (not project-overview--melpa-fetching)
             (= 0 (hash-table-count (project-overview--melpa-local-names))))
    (unless force (project-overview--melpa-cache-load))
    (when (or force (not project-overview--melpa-cache))
      (require 'url)
      (setq project-overview--melpa-fetching t)
      (condition-case nil
          (url-retrieve "https://melpa.org/archive.json"
                        #'project-overview--melpa-fetch-callback nil t t)
        (error (setq project-overview--melpa-fetching nil))))))

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

(defun project-overview--remote-owner (url)
  "Return the owner/user segment of git remote URL, or \"\" when unknown.
For e.g. \"git@github.com:alice/repo.git\" or
\"https://github.com/alice/repo.git\" this returns \"alice\"."
  (if (or (null url) (string-empty-p url))
      ""
    (cond
     ;; scp-like form: [user@]host:owner/repo
     ((string-match "\\`\\(?:[^/@]+@\\)?[^/:]+:\\([^/]+\\)/" url)
      (match-string 1 url))
     ;; URL form: scheme://[user@]host[:port]/owner/repo
     ((string-match "://\\(?:[^/@]+@\\)?[^/]+/\\([^/]+\\)/" url)
      (match-string 1 url))
     (t ""))))

(defun project-overview--remote-repo (url)
  "Return the repository name segment of git remote URL, or \"\" when unknown.
For e.g. \"git@github.com:alice/repo.git\" or
\"https://github.com/alice/repo.git\" this returns \"repo\" (the
trailing \".git\" and any slash are stripped)."
  (if (or (null url) (string-empty-p url))
      ""
    (cond
     ;; scp-like form: [user@]host:owner/repo[.git]
     ((string-match "\\`\\(?:[^/@]+@\\)?[^/:]+:[^/]+/\\([^/]+?\\)\\(?:\\.git\\)?/?\\'"
                    url)
      (match-string 1 url))
     ;; URL form: scheme://[user@]host[:port]/owner/repo[.git]
     ((string-match "://\\(?:[^/@]+@\\)?[^/]+/[^/]+/\\([^/]+?\\)\\(?:\\.git\\)?/?\\'"
                    url)
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
  "Return a git status plist for ROOT.
Keys: :branch :dirty :commit :ahead :behind :host :owner :repo."
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
         (url (project-overview--remote-url root))
         (host (project-overview--remote-host url))
         (owner (project-overview--remote-owner url))
         (repo (project-overview--remote-repo url))
         ahead behind)
    (when (and ab (string-match "\\([0-9]+\\)[ \t]+\\([0-9]+\\)" ab))
      (setq ahead (string-to-number (match-string 1 ab))
            behind (string-to-number (match-string 2 ab))))
    (list :branch branch :dirty dirty :commit commit
          :ahead (or ahead 0) :behind (or behind 0)
          :host host :owner owner :repo repo)))

(defun project-overview--scan ()
  "Scan all discovered projects and populate `project-overview--cache'."
  (let ((known (project-overview--known-roots))
        (melpa (project-overview--melpa-names)))
    (setq project-overview--cache
          (mapcar
           (lambda (root)
             (let* ((cl (project-overview--changelog root))
                    (bugs (project-overview--bugs root))
                    (git (project-overview--git-info root))
                    (name (file-name-nondirectory (directory-file-name root))))
               (cons root
                     (list :name name
                           :version (or (car cl) "")
                           :changed (or (cdr cl) "")
                           :open (car bugs)
                           :total (cdr bugs)
                           :desc (project-overview--description root)
                           :known (and (gethash root known) t)
                           :melpa (and (gethash (intern name) melpa) t)
                           :git git))))
           (project-overview--discover)))))

;;; GitHub integration

(defconst project-overview--github-query
  (concat "query($o:String!,$n:String!){"
          "repository(owner:$o,name:$n){"
          "issues(states:OPEN){totalCount} "
          "pullRequests(states:OPEN){totalCount}}}")
  "GraphQL query fetching open issue and PR counts for one repository.")

(defun project-overview--github-cache-get (slug)
  "Return (ISSUES PRS) cached for SLUG when still fresh, else nil."
  (let ((entry (cdr (assoc slug (project-overview--cache-get :github)))))
    (when (and entry (project-overview--cache-fresh-p (nth 0 entry)))
      (list (nth 1 entry) (nth 2 entry)))))

(defun project-overview--github-cache-put (slug issues prs)
  "Store ISSUES and PRS for SLUG in the persistent cache, stamped now."
  (let* ((gh (project-overview--cache-get :github))
         (entry (assoc slug gh))
         (val (list (float-time) issues prs)))
    (if entry
        (setcdr entry val)
      (setq gh (cons (cons slug val) gh)))
    (project-overview--cache-put :github gh)))

(defun project-overview--github-set (root issues prs)
  "Set ROOT's cached :gh counts in the live data without redrawing."
  (let ((cell (assoc root project-overview--cache)))
    (when cell
      (setcdr cell (plist-put (cdr cell) :gh (cons issues prs))))))

(defun project-overview--github-update (root issues prs)
  "Store ISSUES and PRS counts for ROOT and redraw the dashboard."
  (project-overview--github-set root issues prs)
  (project-overview--redraw))

(defun project-overview--github-fetch (root owner repo)
  "Asynchronously fetch open issue/PR counts for OWNER/REPO of ROOT.
Runs \"gh api graphql\" and, on success, caches the counts and calls
`project-overview--github-update'.  Does nothing when gh is missing or
OWNER/REPO are unknown."
  (when (and (executable-find "gh")
             (stringp owner) (not (string-empty-p owner))
             (stringp repo) (not (string-empty-p repo)))
    (let ((buf (generate-new-buffer " *project-overview-gh*"))
          (slug (concat owner "/" repo)))
      (condition-case nil
          (make-process
           :name "project-overview-gh"
           :buffer buf
           :noquery t
           :connection-type 'pipe
           :command (list "gh" "api" "graphql"
                          "-f" (concat "query=" project-overview--github-query)
                          "-f" (concat "o=" owner)
                          "-f" (concat "n=" repo))
           :sentinel
           (lambda (proc _event)
             (when (memq (process-status proc) '(exit signal))
               (unwind-protect
                   (when (and (eq (process-exit-status proc) 0)
                              (buffer-live-p (process-buffer proc)))
                     (with-current-buffer (process-buffer proc)
                       (goto-char (point-min))
                       (ignore-errors
                         (let* ((data (json-parse-buffer :object-type 'alist
                                                         :null-object nil))
                                (r (alist-get 'repository
                                              (alist-get 'data data))))
                           (when r
                             (let ((issues (alist-get 'totalCount
                                                      (alist-get 'issues r)))
                                   (prs (alist-get 'totalCount
                                                   (alist-get 'pullRequests r))))
                               (project-overview--github-cache-put slug issues prs)
                               (project-overview--github-update root issues prs)))))))
                 (when (buffer-live-p (process-buffer proc))
                   (kill-buffer (process-buffer proc)))))))
        (error (when (buffer-live-p buf) (kill-buffer buf)))))))

(defun project-overview--github-fetch-all (&optional force)
  "Populate GitHub issue/PR counts for every GitHub-hosted project.
Fresh cached counts are applied without a network call; the rest are
fetched asynchronously.  With FORCE, the cache is bypassed and every
repository is re-queried.  No-op unless `project-overview-show-github'."
  (when project-overview-show-github
    (let (redrew)
      (dolist (cell project-overview--cache)
        (let ((git (plist-get (cdr cell) :git)))
          (when (equal (plist-get git :host) "github")
            (let ((owner (plist-get git :owner))
                  (repo (plist-get git :repo)))
              (when (and (stringp owner) (not (string-empty-p owner))
                         (stringp repo) (not (string-empty-p repo)))
                (let* ((slug (concat owner "/" repo))
                       (cached (unless force
                                 (project-overview--github-cache-get slug))))
                  (if cached
                      (progn
                        (project-overview--github-set
                         (car cell) (nth 0 cached) (nth 1 cached))
                        (setq redrew t))
                    (project-overview--github-fetch (car cell) owner repo))))))))
      (when redrew (project-overview--redraw)))))

(defun project-overview--github-slug (root)
  "Return \"owner/repo\" for ROOT when it is a GitHub repo, else nil.
Uses the cached git info, falling back to a fresh probe of ROOT."
  (let ((git (or (plist-get (cdr (assoc root project-overview--cache)) :git)
                 (project-overview--git-info root))))
    (when (equal (plist-get git :host) "github")
      (let ((owner (plist-get git :owner))
            (repo (plist-get git :repo)))
        (when (and (stringp owner) (not (string-empty-p owner))
                   (stringp repo) (not (string-empty-p repo)))
          (concat owner "/" repo))))))

(defun project-overview--github-body (body)
  "Convert issue/PR BODY (GitHub Markdown) to a safe Org fragment.
Fenced ```` ``` ```` / ~~~ code blocks become Org source blocks (using
the fence's language when given), so snippets fontify instead of
showing raw fences.  Lines outside code are indented two spaces, which
keeps a leading \"*\" or \"#\" from starting an Org heading or keyword
and so prevents item bodies from breaking the buffer's outline."
  (if (or (null body) (string-empty-p (string-trim body)))
      ""
    (let ((lines (split-string
                  (replace-regexp-in-string "\r" "" (string-trim body)) "\n"))
          (in-code nil)
          out)
      (dolist (line lines)
        (cond
         ;; Opening or closing code fence (``` or ~~~, optionally ```lang).
         ((string-match "\\`[ \t]*\\(?:```+\\|~~~+\\)[ \t]*\\(.*\\)\\'" line)
          (if in-code
              (progn (push "#+end_src" out) (setq in-code nil))
            (let ((lang (string-trim (match-string 1 line))))
              (push (if (string-empty-p lang)
                        "#+begin_src text"
                      (concat "#+begin_src " lang))
                    out)
              (setq in-code t))))
         ;; Verbatim inside a code block, and prose outside it, both kept
         ;; at column 0 here; uniform indentation is applied below.
         (t (push line out))))
      ;; Close an unterminated fence so the block stays well-formed.
      (when in-code (push "#+end_src" out))
      ;; Indent every non-empty line two spaces.  This keeps a leading "*"
      ;; or "#" from starting an Org heading/keyword and aligns the source
      ;; blocks (which Org still recognises when indented) with the prose,
      ;; avoiding the offset between snippets and surrounding text.
      (concat (mapconcat (lambda (l) (if (string-empty-p l) l (concat "  " l)))
                         (nreverse out) "\n")
              "\n"))))

(defun project-overview--github-render (kind slug items)
  "Render ITEMS (issues or PRs) for SLUG into an Org buffer and show it.
KIND is `issue' or `pr'; ITEMS is the parsed JSON list from gh."
  (let* ((label (if (eq kind 'pr) "pull requests" "issues"))
         (buf (get-buffer-create (format "*GitHub %s: %s*" label slug))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "#+title: Open %s — %s\n" label slug))
        (insert (format "# %d open %s, fetched %s\n\n"
                        (length items) label
                        (format-time-string "%Y-%m-%d %H:%M")))
        (if (null items)
            (insert (format "No open %s.\n" label))
          (dolist (it items)
            (let* ((num (alist-get 'number it))
                   (title (alist-get 'title it))
                   (author (alist-get 'login (alist-get 'author it)))
                   (created (alist-get 'createdAt it))
                   (labels (delq nil (mapcar (lambda (l) (alist-get 'name l))
                                             (alist-get 'labels it))))
                   (url (alist-get 'url it))
                   (draft (eq (alist-get 'isDraft it) t))
                   (body (alist-get 'body it)))
              (insert (format "* #%s %s%s\n" num (or title "")
                              (if draft " [DRAFT]" "")))
              (insert ":PROPERTIES:\n")
              (insert (format ":AUTHOR: %s\n" (or author "")))
              (when (and created (>= (length created) 10))
                (insert (format ":CREATED: %s\n" (substring created 0 10))))
              (when labels
                (insert (format ":LABELS: %s\n" (string-join labels ", "))))
              (insert (format ":URL: %s\n" (or url "")))
              (insert ":END:\n")
              (let ((b (project-overview--github-body body)))
                (unless (string-empty-p b) (insert b)))
              (insert "\n"))))
        (goto-char (point-min))
        ;; Activate Org fully (run `org-mode-hook', fontify, etc.) rather
        ;; than `delay-mode-hooks', so headings, folding and the user's Org
        ;; setup all take effect.
        (org-mode)
        (font-lock-ensure)
        (view-mode 1)))
    (select-window
     (display-buffer buf '(display-buffer-in-direction (direction . right))))))

(defun project-overview--github-list (kind)
  "Fetch and display open GitHub issues or PRs for the project under point.
KIND is the symbol `issue' or `pr'.  Runs the gh CLI synchronously."
  (unless (executable-find "gh")
    (user-error "The gh CLI is not installed"))
  (let* ((root (project-overview--root))
         (slug (or (project-overview--github-slug root)
                   (user-error "Not a GitHub repository")))
         (sub (if (eq kind 'pr) "pr" "issue"))
         (fields (if (eq kind 'pr)
                     "number,title,author,createdAt,labels,url,body,isDraft"
                   "number,title,author,createdAt,labels,url,body")))
    (message "Fetching open %s for %s…"
             (if (eq kind 'pr) "pull requests" "issues") slug)
    (with-temp-buffer
      (if (zerop (process-file "gh" nil t nil
                               sub "list" "-R" slug
                               "--state" "open" "--limit" "100"
                               "--json" fields))
          (let ((items (ignore-errors
                         (json-parse-string (buffer-string)
                                            :object-type 'alist
                                            :array-type 'list
                                            :null-object nil))))
            (project-overview--github-render kind slug items)
            (message "Fetching open %s for %s…done"
                     (if (eq kind 'pr) "pull requests" "issues") slug))
        (user-error "gh %s list failed: %s" sub
                    (string-trim (buffer-string)))))))

(defun project-overview-github-issues ()
  "Show the open GitHub issues for the project under point in an Org buffer."
  (interactive)
  (project-overview--github-list 'issue))

(defun project-overview-github-prs ()
  "Show the open GitHub pull requests for the project under point in an Org buffer."
  (interactive)
  (project-overview--github-list 'pr))

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

(defun project-overview--col-bugs (cell)
  "Return the propertized open/total bug count for cache CELL."
  (let* ((p (cdr cell))
         (open (plist-get p :open))
         (total (plist-get p :total))
         (bugs (if (> total 0) (format "%d/%d" open total) "")))
    (if (> open 0) (propertize bugs 'face 'warning) bugs)))

(defun project-overview--col-github (cell)
  "Return open GitHub issue/PR counts for cache CELL, e.g. \"3i 1p\".
Empty until the asynchronous fetch fills in :gh.  Zero counts are
omitted, so a repository with no open issues or PRs shows blank; the
counts that do appear use the `warning' face."
  (let ((gh (plist-get (cdr cell) :gh)))
    (if (not gh)
        ""
      (let* ((issues (or (car gh) 0))
             (prs (or (cdr gh) 0))
             (parts (delq nil
                          (list (when (> issues 0)
                                  (propertize (format "%di" issues) 'face 'warning))
                                (when (> prs 0)
                                  (propertize (format "%dp" prs) 'face 'warning))))))
        (mapconcat #'identity parts " ")))))

(defvar project-overview--columns
  (list
   (list 'name        '("Project" 24 t)
         (lambda (c) (plist-get (cdr c) :name)))
   (list 'version     '("Version" 9 t)
         (lambda (c) (plist-get (cdr c) :version)))
   (list 'changelog   '("ChangeLog" 12 t)
         (lambda (c) (plist-get (cdr c) :changed)))
   (list 'bugs        '("Bugs" 7 t)
         #'project-overview--col-bugs)
   (list 'branch      '("Branch" 14 t)
         (lambda (c) (plist-get (plist-get (cdr c) :git) :branch)))
   (list 'git         '("Git" 6 t)
         (lambda (c) (project-overview--git-flag (plist-get (cdr c) :git))))
   (list 'remote      '("Remote" 10 t)
         (lambda (c) (or (plist-get (plist-get (cdr c) :git) :host) "")))
   (list 'owner       '("Owner" 16 t)
         (lambda (c) (or (plist-get (plist-get (cdr c) :git) :owner) "")))
   (list 'github      '("GitHub" 9 t)
         #'project-overview--col-github)
   (list 'known       '("Known" 6 t)
         (lambda (c) (if (plist-get (cdr c) :known) "✓" "")))
   (list 'melpa       '("MELPA" 6 t)
         (lambda (c) (if (plist-get (cdr c) :melpa) "✓" "")))
   (list 'commit      '("Commit" 17 t)
         (lambda (c) (plist-get (plist-get (cdr c) :git) :commit)))
   (list 'description '("Description" 50 t)
         (lambda (c) (propertize (plist-get (cdr c) :desc) 'face 'shadow)))
   (list 'path        '("Path" 50 t)
         (lambda (c) (propertize (abbreviate-file-name (car c)) 'face 'shadow))))
  "All available dashboard columns.
Each element is (ID HEADER-SPEC EXTRACTOR): HEADER-SPEC is a
`tabulated-list-format' triple and EXTRACTOR maps a (ROOT . PLIST)
cache cell to that column's display string.  `project-overview-views'
selects which ids appear, in which order.")

(defvar project-overview-saved-view nil
  "The last view chosen with `project-overview-set-view', or nil.
Persisted across sessions by `savehist' (see the
`with-eval-after-load' at the end of this file) and used as the
opening layout, taking precedence over `project-overview-default-view'.")

(defun project-overview--save-view (view)
  "Remember VIEW as the persisted opening layout."
  (setq project-overview-saved-view view))

(defun project-overview--effective-default-view ()
  "Return the layout to open with, honouring a remembered choice.
A remembered `project-overview-saved-view' (when
`project-overview-remember-view' is on and it names a known view)
takes precedence over `project-overview-default-view'."
  (or (and project-overview-remember-view
           project-overview-saved-view
           (assq project-overview-saved-view project-overview-views)
           project-overview-saved-view)
      project-overview-default-view))

(defvar-local project-overview--hide-description nil
  "When non-nil, omit the Description column whatever the active view.
Toggled with `project-overview-toggle-description'.")

(defun project-overview--view-columns ()
  "Return the list of column ids for the active view.
Falls back to the effective default view then the `full' layout when
the current view is unset or unknown.  The Description column is
dropped when `project-overview--hide-description' is set."
  (let ((cols (or (cdr (assq (or project-overview--view
                                 (project-overview--effective-default-view))
                             project-overview-views))
                  (cdr (assq 'full project-overview-views))
                  (mapcar #'car project-overview--columns))))
    (if project-overview--hide-description
        (remq 'description cols)
      cols)))

(defun project-overview--format ()
  "Return the `tabulated-list-format' vector for the active view."
  (vconcat
   (mapcar (lambda (id) (nth 1 (assq id project-overview--columns)))
           (project-overview--view-columns))))

(defun project-overview--entry (cell)
  "Build a `tabulated-list-entries' row from cache CELL for the active view."
  (list (car cell)
        (vconcat
         (mapcar (lambda (id)
                   (funcall (nth 2 (assq id project-overview--columns)) cell))
                 (project-overview--view-columns)))))

(defun project-overview--entries ()
  "Build `tabulated-list-entries', honouring the active filter."
  (mapcar #'project-overview--entry
          (if project-overview--filter
              (seq-filter (cdr project-overview--filter)
                          project-overview--cache)
            project-overview--cache)))

(defun project-overview--apply-view ()
  "Install the active view's columns into the current dashboard buffer.
Updates `tabulated-list-format', picks a sort key that the view
actually contains (preferring Commit), and reinitialises the header."
  (setq tabulated-list-format (project-overview--format))
  (let ((headers (mapcar #'car (append tabulated-list-format nil))))
    (setq tabulated-list-sort-key
          (if (member "Commit" headers)
              '("Commit" . t)
            (cons (car headers) nil))))
  (tabulated-list-init-header))

(defun project-overview-set-view (view)
  "Switch the dashboard column layout to VIEW.
VIEW is a key of `project-overview-views'."
  (interactive
   (list (intern
          (completing-read "View: "
                           (mapcar (lambda (v) (symbol-name (car v)))
                                   project-overview-views)
                           nil t))))
  (unless (assq view project-overview-views)
    (user-error "No such view: %s" view))
  (setq project-overview--view view)
  ;; Remember the choice for future sessions in our own state file
  ;; (`custom-file' may be transient, so Customize can't be relied on).
  (when project-overview-remember-view
    (project-overview--save-view view))
  (project-overview--apply-view)
  (tabulated-list-print t)
  (message "View: %s%s" view
           (if project-overview-remember-view " (saved)" "")))

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
  "Re-scan all projects and redraw the dashboard.
Local project data is re-read; network data (GitHub counts, the MELPA
list) is taken from the cache while it is fresh.  Use
`project-overview-cache-dispatch' to force a network refresh."
  (interactive)
  (message "Scanning projects…")
  (project-overview--scan)
  (when (derived-mode-p 'project-overview-mode)
    (tabulated-list-print t))
  (project-overview--github-fetch-all)
  (project-overview--melpa-maybe-fetch)
  (message "Scanning projects…done"))

;;; Cache refresh

(defun project-overview-pull-github ()
  "Re-fetch GitHub issue/PR counts now, bypassing the cache."
  (interactive)
  (unless project-overview-show-github
    (user-error "GitHub integration is disabled \
(`project-overview-show-github')"))
  (message "Pulling GitHub counts…")
  (project-overview--github-fetch-all t))

(defun project-overview-pull-melpa ()
  "Re-fetch the MELPA package list now, bypassing the cache."
  (interactive)
  (setq project-overview--melpa-cache nil)
  (if (> (hash-table-count (project-overview--melpa-local-names)) 0)
      (message "MELPA available locally; melpa.org fetch not needed")
    (message "Pulling MELPA list…")
    (project-overview--melpa-maybe-fetch t)))

(defun project-overview-pull-all ()
  "Re-scan projects and re-fetch all cached network data now."
  (interactive)
  (message "Refreshing and pulling caches…")
  (project-overview--scan)
  (when (derived-mode-p 'project-overview-mode)
    (tabulated-list-print t))
  (setq project-overview--melpa-cache nil)
  (project-overview--github-fetch-all t)
  (project-overview--melpa-maybe-fetch t)
  (message "Refreshing and pulling caches…done"))

(defun project-overview-cache-clear ()
  "Delete the on-disk cache, forget fetched data, and refresh."
  (interactive)
  (project-overview--cache-reset)
  (message "Cache cleared")
  (project-overview-refresh))

;;;###autoload (autoload 'project-overview-cache-dispatch "project-overview" nil t)
(transient-define-prefix project-overview-cache-dispatch ()
  "Refresh or clear the dashboard's cached network data."
  ["Pull (force re-fetch, bypassing the cache)"
   ("p" "GitHub counts" project-overview-pull-github)
   ("m" "MELPA list"    project-overview-pull-melpa)
   ("a" "everything"    project-overview-pull-all)]
  ["Cache"
   ("c" "clear on-disk cache" project-overview-cache-clear)
   ("q" "quit"                transient-quit-one)])

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
    ("A" "bugs agenda (all)" project-overview-bugs-agenda-all)
    ("i" "GitHub issues"     project-overview-github-issues)
    ("P" "GitHub PRs"        project-overview-github-prs)]
   ["VC & search"
    ("v" "vc-dir"            project-overview-vc-dir)
    ("m" "magit-status"      project-overview-magit)
    ("s" "search"            project-overview-search)]
   ["Dashboard"
    ("/" "filter…"        project-overview-filter-dispatch)
    ("V" "cycle view"     project-overview-cycle-view :transient t)
    ("t" "toggle descrip" project-overview-toggle-description :transient t)
    ("g" "refresh"        project-overview-refresh :transient t)
    ("r" "cache / pull…"  project-overview-cache-dispatch)
    ("q" "quit"           transient-quit-one)]])

(defun project-overview-cycle-view (&optional backward)
  "Switch to the next column layout in `project-overview-views', cycling round.
With a prefix argument BACKWARD, cycle to the previous layout instead.
The new view is applied, announced, and (when
`project-overview-remember-view' is on) remembered — so repeatedly
pressing the key steps through the layouts and stops wherever you like."
  (interactive "P")
  (let* ((views (mapcar #'car project-overview-views))
         (n (length views)))
    (when (zerop n) (user-error "No views defined in `project-overview-views'"))
    (let* ((current (or project-overview--view
                        (project-overview--effective-default-view)))
           (idx (or (seq-position views current) 0))
           (next (nth (mod (+ idx (if backward -1 1)) n) views)))
      (project-overview-set-view next))))

(defun project-overview-toggle-description ()
  "Toggle display of the Description column in the dashboard.
The setting applies on top of the active view, so the description can
be hidden or shown without switching layouts."
  (interactive)
  (setq project-overview--hide-description (not project-overview--hide-description))
  (project-overview--apply-view)
  (tabulated-list-print t)
  (message "Description column %s"
           (if project-overview--hide-description "hidden" "shown")))

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

(defun project-overview--owned-github-totals ()
  "Return cons (ISSUES . PRS) summed over `project-overview-github-user' repos.
Only projects whose remote owner matches the configured user and whose
GitHub counts have been fetched contribute.  Returns (0 . 0) when the
user is unset."
  (let ((issues 0) (prs 0)
        (user project-overview-github-user))
    (when (and (stringp user) (not (string-empty-p user)))
      (dolist (c project-overview--cache)
        (let ((gh (plist-get (cdr c) :gh)))
          (when (and gh (equal (plist-get (plist-get (cdr c) :git) :owner) user))
            (setq issues (+ issues (or (car gh) 0))
                  prs (+ prs (or (cdr gh) 0)))))))
    (cons issues prs)))

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
         (open  (apply #'+ (mapcar (lambda (c) (plist-get (cdr c) :open)) cache))))
    (concat
     (propertize (format " %d project%s" total (if (= total 1) "" "s"))
                 'face 'bold)
     (project-overview--header-count dirty "dirty")
     (project-overview--header-count sync "out of sync")
     (project-overview--header-count
      open (format "open bug%s" (if (= open 1) "" "s")))
     (when (and project-overview-show-github
                (stringp project-overview-github-user)
                (not (string-empty-p project-overview-github-user)))
       (let* ((gh (project-overview--owned-github-totals))
              (issues (car gh))
              (prs (cdr gh)))
         (concat
          (project-overview--header-count
           issues (format "open issue%s" (if (= issues 1) "" "s")))
          (project-overview--header-count
           prs (format "open PR%s" (if (= prs 1) "" "s"))))))
     (concat " · view: "
             (propertize (symbol-name (or project-overview--view
                                          (project-overview--effective-default-view)))
                         'face 'bold)
             (if project-overview--hide-description " (no desc)" ""))
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
    (define-key map "i" #'project-overview-github-issues)
    (define-key map "P" #'project-overview-github-prs)
    ;; Dashboard.
    (define-key map "/" #'project-overview-filter-dispatch)
    (define-key map "V" #'project-overview-cycle-view)
    (define-key map "t" #'project-overview-toggle-description)
    (define-key map "r" #'project-overview-cache-dispatch)
    (define-key map "g" #'project-overview-refresh)
    (define-key map "?" #'project-overview-dispatch)
    map)
  "Keymap for `project-overview-mode'.")

(define-derived-mode project-overview-mode tabulated-list-mode "Projects"
  "Major mode for the project dashboard.

\\{project-overview-mode-map}"
  (setq tabulated-list-entries #'project-overview--entries)
  ;; Free the window header line for the aggregate summary by printing the
  ;; (still sortable) column headers at the top of the buffer instead.
  (setq tabulated-list-use-header-line nil)
  ;; Install the columns for the active view (default
  ;; `project-overview-default-view'), which also sets the sort key —
  ;; most recently committed projects first when the Commit column is shown.
  (project-overview--apply-view)
  (setq header-line-format '(:eval (project-overview--header-line)))
  ;; Highlight the current row in this buffer only, regardless of whether
  ;; `global-hl-line-mode' is enabled elsewhere.
  (hl-line-mode 1)
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
  (project-overview--github-fetch-all)
  (project-overview--melpa-maybe-fetch)
  (message "Scanning projects…done"))

;;; Persistence

;; Persist the remembered view across sessions via `savehist'.  This is
;; deliberately not tied to `custom-file', which may be transient.
(with-eval-after-load 'savehist
  (add-to-list 'savehist-additional-variables 'project-overview-saved-view))

(provide 'project-overview)
;;; project-overview.el ends here
