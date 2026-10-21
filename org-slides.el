;;; org-slides.el --- Minimalist Org presentation mode -*- lexical-binding: t; -*-

;; Copyright (C) 2012 Ric Lister
;; Copyright (C) 2026 James Dyer
;;
;; Author: James Dyer
;; Maintainer: James Dyer
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (org "9.4"))
;; Keywords: outlines, convenience
;; URL: https://github.com/captainflasmr/org-slides
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is derived from org-present.el by Ric Lister:
;; https://github.com/rlister/org-present
;;
;; This file is not part of GNU Emacs.
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `org-slides' turns an Org buffer into a simple presentation: each
;; top-level heading is one slide, and the text before the first heading is
;; the title slide.  Start it with `M-x org-slides-start' (or bind
;; `org-slides-start' in `org-mode-map').
;;
;; The mode is intentionally small, but it bundles the fixes that used to
;; live in the author's config:
;;
;; - `SPC'/`n'/right arrow move forward, `S-SPC'/`p'/left arrow move back,
;;   and `q' quits.  In read-write mode those keys insert their characters
;;   instead, so the buffer remains editable; `C-c C-n'/`C-c C-p' always
;;   navigate.
;; - Hiding a complete `#+' line also hides its newline, so source blocks do
;;   not gain blank lines from their hidden `#+begin_src'/`#+end_src'
;;   delimiters.
;; - Literal `#+' lines inside source/example/quote blocks are not hidden.
;; - The text scale in use before the presentation is restored on quit.
;; - Overlay and cursor state is buffer-local, so multiple presentations do
;;   not clobber each other.
;;
;; The rendered appearance is controlled by the usual Org faces.  In
;; particular, a `fixed-pitch' face with an absolute `:height' does not
;; follow `text-scale-mode'; use a relative height such as 1.0 if code
;; blocks should scale with the slide text.

;;; Code:

(require 'org)
(require 'subr-x)

(defgroup org-slides nil
  "Minimalist presentation mode for Org buffers."
  :group 'org
  :prefix "org-slides-")

(defcustom org-slides-text-scale 5
  "Text scale applied when a presentation starts.
Set `org-slides-scale-on-start' to nil to leave the current scale alone."
  :type 'integer
  :group 'org-slides)

(defcustom org-slides-scale-on-start t
  "Whether to enlarge the text when `org-slides-start' runs."
  :type 'boolean
  :group 'org-slides)

(defcustom org-slides-display-inline-images t
  "Whether to display inline images while presenting."
  :type 'boolean
  :group 'org-slides)

(defcustom org-slides-read-only-on-start t
  "Whether to make the buffer read-only when a presentation starts."
  :type 'boolean
  :group 'org-slides)

(defcustom org-slides-hide-cursor-on-start t
  "Whether to hide the cursor when a presentation starts."
  :type 'boolean
  :group 'org-slides)

(defcustom org-slides-hide-stars-in-headings t
  "Whether to hide the leading stars in headings while presenting."
  :type 'boolean
  :group 'org-slides)

(defcustom org-slides-startup-folded nil
  "Whether to fold each slide when navigating to it.
This is analogous to introducing slide items one at a time in other
presentation programs."
  :type 'boolean
  :group 'org-slides)

(defvar org-slides-mode nil
  "Non-nil when `org-slides-mode' is active in the current buffer.")

(defvar org-slides-after-navigate-functions nil
  "Abnormal hook run after `org-slides' changes slides.
Each function is called with the buffer name and current heading.")

(defvar-local org-slides--overlays nil
  "Overlays created by `org-slides--add-overlays' in this buffer.")

(defvar-local org-slides--cursor-cache nil
  "Cached cursor type for the current presentation.")

(defvar-local org-slides--previous-text-scale 0
  "Text scale in use before the current presentation started.")

(defvar-local org-slides--previous-read-only nil
  "Value of `buffer-read-only' before the presentation started.")

(defvar-local org-slides--one-big-page nil
  "Non-nil when all slides are shown in one wide page.")

(defvar-local org-slides--images-displayed nil
  "Non-nil when this presentation displayed inline images.")

(defvar-local org-slides--started nil
  "Non-nil while `org-slides--setup' has completed for this buffer.")

(defvar org-slides-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Forward/backward.  The -or-self-insert commands keep the buffer
    ;; editable when read-only mode is off.
    (define-key map (kbd "n") #'org-slides-next-or-self-insert)
    (define-key map (kbd "SPC") #'org-slides-next-or-self-insert)
    (define-key map (kbd "p") #'org-slides-prev-or-self-insert)
    (define-key map (kbd "S-SPC") #'org-slides-prev-or-self-insert)
    (define-key map [right] #'org-slides-next)
    (define-key map [left] #'org-slides-prev)
    (define-key map [next] #'org-slides-next)
    (define-key map [prior] #'org-slides-prev)
    (define-key map (kbd "C-c C-n") #'org-slides-next)
    (define-key map (kbd "C-c C-p") #'org-slides-prev)
    ;; First/last and quit.
    (define-key map (kbd "g") #'org-slides-beginning-or-self-insert)
    (define-key map (kbd "G") #'org-slides-end-or-self-insert)
    (define-key map (kbd "q") #'org-slides-quit-or-self-insert)
    (define-key map (kbd "C-c C-q") #'org-slides-quit)
    (define-key map (kbd "C-c <") #'org-slides-beginning)
    (define-key map (kbd "C-c >") #'org-slides-end)
    ;; Size, read-only, and the one-page view.
    (define-key map (kbd "C-c C-=") #'org-slides-big)
    (define-key map (kbd "C-c C--") #'org-slides-small)
    (define-key map (kbd "C-c C-r") #'org-slides-read-only)
    (define-key map (kbd "C-c C-w") #'org-slides-read-write)
    (define-key map (kbd "C-c C-1") #'org-slides-toggle-one-big-page)
    map)
  "Keymap used by `org-slides-mode'.")

(defun org-slides-top ()
  "Move to the current top-level heading, safe outside a heading."
  (unless (org-at-heading-p)
    (outline-previous-heading))
  (let ((level (org-current-level)))
    (when (and level (> level 1))
      (outline-up-heading (- level 1) t))))

(defun org-slides-narrow ()
  "Show only the current slide."
  (if (org-current-level)
      (progn
        (org-narrow-to-subtree)
        (outline-show-all))
    ;; Show the title page before the first heading.
    (outline-next-heading)
    (narrow-to-region (point-min) (point))
    (goto-char (point-min))))

(defun org-slides--narrow-or-widen ()
  "Narrow to the current slide unless the one-big-page view is active."
  (if org-slides--one-big-page
      (widen)
    (org-slides-narrow)))

(defun org-slides-run-after-navigate-functions ()
  "Run `org-slides-after-navigate-functions' for the current slide."
  (when org-slides-startup-folded
    (org-cycle))
  (let* ((title (or (thing-at-point 'line) ""))
         (safe-title (replace-regexp-in-string "^[ \t]*\\*+[ \t]*" "" title))
         (heading (string-trim safe-title)))
    (run-hook-with-args 'org-slides-after-navigate-functions
                        (buffer-name) heading)))

(defun org-slides-next ()
  "Move to the next top-level heading."
  (interactive)
  (widen)
  (if (org-current-level)
      (progn
        (org-slides-top)
        (or (org-get-next-sibling)
            (org-slides-top)))
    (outline-next-heading))
  (org-slides--narrow-or-widen)
  (org-slides-run-after-navigate-functions))

(defun org-slides-prev ()
  "Move to the previous top-level heading, or the title slide."
  (interactive)
  (widen)
  (if (org-current-level)
      (progn
        (org-slides-top)
        (unless (org-get-previous-sibling)
          (goto-char (point-min))))
    (goto-char (point-min)))
  (org-slides--narrow-or-widen)
  (org-slides-run-after-navigate-functions))

(defun org-slides-beginning ()
  "Move to the first slide (the title slide, if there is one)."
  (interactive)
  (widen)
  (goto-char (point-min))
  (org-slides--narrow-or-widen)
  (org-slides-run-after-navigate-functions))

(defun org-slides-end ()
  "Move to the last slide."
  (interactive)
  (widen)
  (goto-char (point-max))
  (org-slides-top)
  (org-slides--narrow-or-widen)
  (org-slides-run-after-navigate-functions))

(defun org-slides-toggle-one-big-page ()
  "Toggle between one slide at a time and the whole buffer."
  (interactive)
  (setq org-slides--one-big-page (not org-slides--one-big-page))
  (if org-slides--one-big-page
      (widen)
    (org-slides-narrow))
  (message "Org Slides: %s"
           (if org-slides--one-big-page
               "showing all slides"
             "showing one slide")))

(defun org-slides-big ()
  "Increase the presentation text size by one step."
  (interactive)
  (text-scale-increase 1))

(defun org-slides-small ()
  "Decrease the presentation text size by one step."
  (interactive)
  (text-scale-decrease 1))

(defun org-slides-read-only ()
  "Make the presentation buffer read-only."
  (interactive)
  (setq buffer-read-only t))

(defun org-slides-read-write ()
  "Make the presentation buffer writable."
  (interactive)
  (setq buffer-read-only nil))

(defun org-slides-hide-cursor ()
  "Hide the cursor in the selected window."
  (interactive)
  (unless org-slides--cursor-cache
    (setq org-slides--cursor-cache (or cursor-type t)))
  (setq cursor-type nil)
  (internal-show-cursor (selected-window) nil))

(defun org-slides-show-cursor ()
  "Restore the cursor in the selected window."
  (interactive)
  (when org-slides--cursor-cache
    (setq cursor-type org-slides--cursor-cache))
  (internal-show-cursor (selected-window) t))

(defun org-slides--add-overlay (beginning end)
  "Create an invisible overlay over BEGINNING..END and remember it."
  (let ((overlay (make-overlay beginning end)))
    (push overlay org-slides--overlays)
    (overlay-put overlay 'invisible 'org-slides)))

(defun org-slides--show-option (string)
  "Return non-nil if STRING is an Org exporter option to keep visible.
The option names are matched case-insensitively."
  (save-match-data
    (let ((case-fold-search t))
      (string-match
       (regexp-opt '("title:" "author:" "date:" "email:"))
       string))))

(defun org-slides--block-content-line-p ()
  "Return non-nil when the current line is inside a block's contents.
Block delimiter lines, such as `#+begin_src' and `#+end_src', are not
considered content.  This keeps a literal `#+' line in a source or
example block visible."
  (save-excursion
    (beginning-of-line)
    (let ((element (org-element-at-point)))
      (and (memq (org-element-type element)
                 '(src-block example-block export-block comment-block
                   verse-block quote-block center-block special-block
                   dynamic-block))
           (not (looking-at-p
                 "^[ \t]*#\\+\\(?:begin_\\|end_\\)"))
           (> (line-beginning-position)
              (org-element-property :begin element))
           (< (line-end-position)
              (org-element-property :end element))))))

(defun org-slides--add-overlays ()
  "Add the presentation overlays for this buffer."
  (org-slides--rm-overlays)
  (add-to-invisibility-spec '(org-slides))
  (save-excursion
    ;; Hide Org keyword and block delimiter lines.  Include the newline
    ;; when hiding a complete line, otherwise the invisible text leaves an
    ;; empty line behind (visible around source-block delimiters).
    (goto-char (point-min))
    (while (re-search-forward "^[ \t]*\\(#\\+\\)\\([^[:space:]]+\\).*" nil t)
      (unless (save-match-data (org-slides--block-content-line-p))
        (let* ((show (org-slides--show-option (match-string 2)))
               (end (if show
                        (match-end 2)
                      (min (1+ (match-end 0)) (point-max)))))
          (org-slides--add-overlay (match-beginning 1) end))))
    ;; Hide leading stars in headings.
    (when org-slides-hide-stars-in-headings
      (goto-char (point-min))
      (while (re-search-forward "^\\(\\*+\\)" nil t)
        (org-slides--add-overlay (match-beginning 1) (match-end 1))))
    ;; Hide emphasis and verbatim markers unless Org already does so.
    (unless org-hide-emphasis-markers
      (when (boundp 'org-emph-re)
        (goto-char (point-min))
        (while (re-search-forward org-emph-re nil t)
          (org-slides--add-overlay (match-beginning 2) (1+ (match-beginning 2)))
          (org-slides--add-overlay (1- (match-end 2)) (match-end 2))))
      (when (boundp 'org-verbatim-re)
        (goto-char (point-min))
        (while (re-search-forward org-verbatim-re nil t)
          (org-slides--add-overlay (match-beginning 2) (1+ (match-beginning 2)))
          (org-slides--add-overlay (1- (match-end 2)) (match-end 2)))))))

(defun org-slides--rm-overlays ()
  "Remove all presentation overlays from the current buffer."
  (mapc #'delete-overlay org-slides--overlays)
  (setq org-slides--overlays nil)
  (remove-from-invisibility-spec '(org-slides)))

(defun org-slides--restore-scale ()
  "Restore the text scale saved before the presentation started."
  (text-scale-set (or org-slides--previous-text-scale 0))
  (setq org-slides--previous-text-scale 0))

(defun org-slides--display-inline-images ()
  "Display link previews, using the Org 9.8 API when available."
  (save-restriction
    (widen)
    (if (fboundp 'org-link-preview-region)
        (funcall 'org-link-preview-region nil nil (point-min) (point-max))
      (with-no-warnings
        (org-display-inline-images)))))

(defun org-slides--remove-inline-images ()
  "Remove link previews, using the Org 9.8 API when available."
  (save-restriction
    (widen)
    (if (fboundp 'org-link-preview-clear)
        (funcall 'org-link-preview-clear (point-min) (point-max))
      (with-no-warnings
        (org-remove-inline-images)))))

(defun org-slides--setup ()
  "Set up the current buffer for a presentation."
  (unless (derived-mode-p 'org-mode)
    (setq org-slides-mode nil)
    (user-error "Org Slides requires Org mode"))
  (unless org-slides--started
    (setq org-slides--started t)
    (setq org-slides--previous-text-scale
          (if (bound-and-true-p text-scale-mode)
              (or (bound-and-true-p text-scale-mode-amount) 0)
            0))
    (setq org-slides--previous-read-only buffer-read-only)
    (org-slides--add-overlays)
    (when org-slides-scale-on-start
      (text-scale-set org-slides-text-scale))
    (when org-slides-display-inline-images
      (org-slides--display-inline-images)
      (setq org-slides--images-displayed t))
    (org-slides-narrow)
    (when org-slides-read-only-on-start
      (org-slides-read-only))
    (when org-slides-hide-cursor-on-start
      (org-slides-hide-cursor))))

(defun org-slides--teardown ()
  "Undo the presentation state in the current buffer."
  (when org-slides--started
    (setq org-slides--started nil)
    (org-slides--restore-scale)
    (when org-slides--images-displayed
      (org-slides--remove-inline-images)
      (setq org-slides--images-displayed nil))
    (org-slides-show-cursor)
    (org-slides--rm-overlays)
    (setq buffer-read-only org-slides--previous-read-only)
    (setq org-slides--cursor-cache nil
          org-slides--one-big-page nil)
    (widen)))

;;;###autoload
(define-minor-mode org-slides-mode
  "Minimalist presentation mode for Org buffers.
Each top-level heading is one slide.  Use `org-slides-start' to begin."
  :init-value nil
  :lighter " Slides"
  :keymap org-slides-mode-map
  :group 'org-slides
  (if org-slides-mode
      (org-slides--setup)
    (org-slides--teardown)))

;;;###autoload
(defun org-slides-start ()
  "Start an Org presentation in the current buffer."
  (interactive)
  (org-slides-mode 1)
  (when org-slides-mode
    (org-slides-run-after-navigate-functions)))

;;;###autoload
(defun org-slides-quit ()
  "Quit the current Org presentation."
  (interactive)
  (org-slides-mode -1))

(defun org-slides-next-or-self-insert (&optional arg)
  "Move to the next slide, or insert the typed character.
With prefix ARG, insert that many characters when the buffer is
writable.  When the buffer is read-only this navigates; otherwise it
behaves like `self-insert-command'."
  (interactive "p")
  (if buffer-read-only
      (org-slides-next)
    (self-insert-command (or arg 1))))

(defun org-slides-prev-or-self-insert (&optional arg)
  "Move to the previous slide, or insert the typed character.
See `org-slides-next-or-self-insert' for ARG."
  (interactive "p")
  (if buffer-read-only
      (org-slides-prev)
    (self-insert-command (or arg 1))))

(defun org-slides-quit-or-self-insert (&optional arg)
  "Quit the presentation, or insert the typed character.
See `org-slides-next-or-self-insert' for ARG."
  (interactive "p")
  (if buffer-read-only
      (org-slides-quit)
    (self-insert-command (or arg 1))))

(defun org-slides-beginning-or-self-insert (&optional arg)
  "Move to the first slide, or insert the typed character.
See `org-slides-next-or-self-insert' for ARG."
  (interactive "p")
  (if buffer-read-only
      (org-slides-beginning)
    (self-insert-command (or arg 1))))

(defun org-slides-end-or-self-insert (&optional arg)
  "Move to the last slide, or insert the typed character.
See `org-slides-next-or-self-insert' for ARG."
  (interactive "p")
  (if buffer-read-only
      (org-slides-end)
    (self-insert-command (or arg 1))))

(provide 'org-slides)
;;; org-slides.el ends here
