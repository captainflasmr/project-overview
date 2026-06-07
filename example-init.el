;;; example-init.el --- Starter configuration for project-overview -*- lexical-binding: t; -*-

;; This is a copy-and-adapt starter showing how to load and configure
;; `project-overview'.  It is not loaded automatically; lift the
;; `use-package' form below into your own init file and tweak the values.
;;
;; Every option here has a sensible default, so the minimal setup is just
;; the `use-package' form with a `:load-path' (or `:ensure t' once the
;; package is on an archive).  Everything under `:custom' / `:config' is
;; optional and shown for reference.

;;; Code:

;; --- Minimal: just load it and bind a key -----------------------------

(use-package project-overview
  :ensure nil
  :load-path "~/.emacs.d/offline-packages/local-packages/project-overview"
  :commands (project-overview)
  :bind ("C-c p" . project-overview))

;; --- Full: every customisation, with comments -------------------------
;;
;; The block below is the same package with all the knobs shown.  Use it
;; instead of the minimal form above (don't keep both).

(use-package project-overview
  :ensure nil
  :load-path "~/.emacs.d/offline-packages/local-packages/project-overview"
  :commands (project-overview)
  :bind ("C-c p" . project-overview)

  :custom
  ;; Directories scanned for git projects.  Each root is checked directly
  ;; and one level deep for .git subdirectories.
  (project-overview-search-roots
   (list "~/source/repos" "~/.emacs.d"))
  ;; Also include the projects Emacs already knows about
  ;; (`project-known-project-roots'); non-git projects show blank git
  ;; columns.  Default t.
  (project-overview-include-known-projects t)
  ;; Hide project directories whose name matches this regexp.
  (project-overview-exclude-regexp "\\`\\(?:linux-\\|melpa\\'\\)")
  ;; Name of the dashboard buffer.
  (project-overview-buffer-name "*Projects*")

  ;; -- Views (column layouts) --
  ;; Layout used when the dashboard first opens.  One of the keys in
  ;; `project-overview-views': full, minimal, status, remote.
  (project-overview-default-view 'full)
  ;; Remember the last view chosen with `V' (via savehist) and reuse it
  ;; next session.  Default t.
  (project-overview-remember-view t)
  ;; Show the (wide) Description column on open.  Off by default; toggle
  ;; per buffer with `t'.
  (project-overview-show-description nil)

  ;; -- GitHub integration (needs the "gh" CLI, authenticated) --
  ;; Fetch open issue/PR counts for GitHub repos (async).  Default t.
  (project-overview-show-github t)
  ;; Your GitHub username: its repos' open issue/PR totals are summarised
  ;; in the header line, and the "owned by me" filter (/ o) uses it.
  (project-overview-github-user "your-github-username")
  ;; Function used to open a remote in a browser (w).  Defaults to
  ;; `browse-url' (system default); set to e.g. `browse-url-firefox'.
  (project-overview-browse-url-function #'browse-url)

  ;; -- MELPA column --
  ;; When package.el has no local MELPA archive contents, fall back to
  ;; fetching the package list from melpa.org once per session.  Default t.
  (project-overview-melpa-fallback t)

  ;; -- Cache (MELPA list + GitHub counts persisted between sessions) --
  ;; File the network data is cached in; nil keeps it for the session only.
  (project-overview-cache-file
   (locate-user-emacs-file "project-overview-cache.el"))
  ;; Seconds a cached result stays fresh before a refresh re-fetches it.
  (project-overview-cache-ttl 86400))

;; In the dashboard:
;;   RET/o switch · f find file · m magit · w browse remote · D dired
;;   c/C changelog · R README · b BUGS · i/P GitHub issues/PRs
;;   / filter (incl. "o" owned-by-me, "m" on-MELPA) · V cycle view
;;   t toggle Description · g refresh · r cache/pull · ? all actions
;;   TAB / S-TAB move between columns

(provide 'example-init)
;;; example-init.el ends here
