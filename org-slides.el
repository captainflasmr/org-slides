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
;; - Slides taller than the window are paged one screenful at a time in the
;;   same window.  `n'/`p' walk the pages before moving to another slide.
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
(require 'org-element)
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

(defcustom org-slides-auto-page t
  "Whether to page through slides that are taller than the window.
When non-nil, next/previous navigation first moves within the current
slide; when the end of the slide is reached, navigation moves to the
next slide.  `org-slides-page-style' selects how pages are shown."
  :type 'boolean
  :group 'org-slides)

(defcustom org-slides-page-style 'scroll
  "How to show a slide that is taller than the window.
`scroll' pages by scrolling the whole slide one screenful at a time.
`split' narrows to each computed page and shows only that page.  The
`split' style is experimental; it breaks pages at line boundaries and
prefers to start a page at a nested heading."
  :type '(choice (const :tag "Scroll one screenful" scroll)
                 (const :tag "Split into narrowed pages" split))
  :group 'org-slides)

(defcustom org-slides-page-indicator 'always
  "When to show the SLIDE.PAGE indicator in the header line.
The title page before the first heading is slide 0; top-level
headings are numbered 1, 2, 3, ... in document order.

`always' shows the indicator on every slide, including single-page
slides.  `split' shows it only when the current slide has more than
one page.  nil disables it.  For compatibility, any other non-nil
value is treated as `always'."
  :type '(choice (const :tag "Always" always)
                 (const :tag "Only split slides" split)
                 (const :tag "Never" nil))
  :group 'org-slides)

(defcustom org-slides-page-indicator-format "%d.%d / %d.%d"
  "Format for the mode-line slide/page indicator.
Four integers are substituted: current slide, current page, total
slides (top-level headings), and total pages in the current slide.
For example, the default `%d.%d / %d.%d' renders slide 2, page 3, with
5 slides and 4 pages as `2.3 / 5.4'."
  :type 'string
  :group 'org-slides)

(defcustom org-slides-page-break-at-headings t
  "Whether split pages prefer to start at a nested heading.
When non-nil, a page break is moved backward to the last nested
heading that still leaves the preceding page at least half full."
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

(defvar-local org-slides--page-starts nil
  "Markers at the start of each page shown in the current slide.")

(defvar-local org-slides--page-index 0
  "Index of the current page in the active pagination style.")

(defvar-local org-slides--slide-number 0
  "Ordinal of the current top-level heading, or 0 for the title page.")

(defvar-local org-slides--slide-numbers nil
  "Alist of (BEGIN-MARKER . NUMBER) for every top-level heading.")

(defvar-local org-slides--split-pages nil
  "List of (START . END) markers for the current slide's split pages.")

(defvar-local org-slides--logical-start nil
  "Marker for the start of the current logical slide.")

(defvar-local org-slides--logical-end nil
  "Marker for the end of the current logical slide.")

(defvar-local org-slides--original-mode-line-process nil
  "Value of `mode-line-process' before the presentation began.")

(defvar-local org-slides--original-window-start nil
  "Marker for the window start before the presentation began.")

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

(defun org-slides--clear-logical-bounds ()
  "Release the markers for the current logical slide."
  (dolist (marker (list org-slides--logical-start
                        org-slides--logical-end))
    (when (markerp marker)
      (set-marker marker nil)))
  (setq org-slides--logical-start nil
        org-slides--logical-end nil))

(defun org-slides--set-logical-bounds ()
  "Record the start and end of the current narrowed slide."
  (org-slides--clear-logical-bounds)
  (setq org-slides--logical-start (copy-marker (point-min))
        org-slides--logical-end (copy-marker (point-max))))

(defun org-slides--widen-logical ()
  "Restore the restriction to the current logical slide."
  (let ((start (and (markerp org-slides--logical-start)
                    (marker-position org-slides--logical-start)))
        (end (and (markerp org-slides--logical-end)
                  (marker-position org-slides--logical-end))))
    (if (and start end (<= start end))
        (narrow-to-region start end)
      (widen))))

(defun org-slides-narrow ()
  "Show only the current slide."
  (if (org-current-level)
      (progn
        (org-narrow-to-subtree)
        (outline-show-all))
    ;; Show the title page before the first heading.
    (outline-next-heading)
    (narrow-to-region (point-min) (point))
    (goto-char (point-min)))
  (org-slides--set-logical-bounds))

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

(defun org-slides--presentation-window ()
  "Return the window displaying the current buffer, or nil."
  (let ((selected (selected-window)))
    (if (eq (window-buffer selected) (current-buffer))
        selected
      (let ((window (get-buffer-window (current-buffer) t)))
        (and (window-live-p window) window)))))

(defun org-slides--clear-page-markers ()
  "Release the markers recorded for the current slide's pages."
  (mapc (lambda (marker)
          (when (markerp marker)
            (set-marker marker nil)))
        org-slides--page-starts)
  (setq org-slides--page-starts nil
        org-slides--page-index 0))

(defun org-slides--reset-pages ()
  "Start pagination at the beginning of the current slide."
  (org-slides--clear-page-markers)
  (setq org-slides--page-starts (list (copy-marker (point-min)))
        org-slides--page-index 0)
  (when-let* ((window (org-slides--presentation-window)))
    (set-window-start window (point-min))
    (with-selected-window window
      (goto-char (point-min)))))

(defun org-slides--more-pages-p ()
  "Return non-nil when the end of the current slide is not visible."
  (when-let* ((window (org-slides--presentation-window)))
    (not (pos-visible-in-window-p (point-max) window))))

(defun org-slides--next-page-start (window)
  "Return the buffer position where the next page in WINDOW starts.
The position is at the end of the visible text, moved back to a word
boundary when the window ends in the middle of a wrapped line."
  (let* ((limit (point-max))
         (start (window-start window))
         (end (min (or (window-end window t) limit) limit)))
    (cond
     ((<= end start)
      ;; No measurable progress; advance at least one line.
      (save-excursion
        (goto-char start)
        (forward-line 1)
        (min (point) limit)))
     (t
      (save-excursion
        (goto-char end)
        (when (and (> (point) start)
                   (not (memq (char-before) '(?\s ?\t ?\n))))
          (skip-chars-backward "^ \t\n")
          (when (<= (point) start)
            (goto-char end)))
        (point))))))

(defun org-slides--next-page ()
  "Show the next screenful of the current slide.
Return non-nil when a new page was shown."
  (when (and org-slides-auto-page
             (not org-slides--one-big-page)
             (org-slides--more-pages-p))
    (when-let* ((window (org-slides--presentation-window))
                (start (window-start window))
                (next (org-slides--next-page-start window)))
      (when (and (> next start)
                 (< next (point-max)))
        (set-window-start window next)
        (with-selected-window window
          (goto-char next))
        (setq org-slides--page-starts
              (append org-slides--page-starts (list (copy-marker next)))
              org-slides--page-index (1+ org-slides--page-index))
        t))))

(defun org-slides--prev-page ()
  "Show the previous screenful of the current slide.
Return non-nil when a new page was shown."
  (when (and org-slides-auto-page
             (not org-slides--one-big-page)
             (> org-slides--page-index 0)
             (< (1- org-slides--page-index)
                (length org-slides--page-starts)))
    (when-let* ((window (org-slides--presentation-window))
                (marker (nth (1- org-slides--page-index)
                             org-slides--page-starts))
                (start (and (markerp marker) (marker-position marker))))
      (setq org-slides--page-index (1- org-slides--page-index))
      (set-window-start window start)
      (with-selected-window window
        (goto-char start))
      t)))

(defun org-slides--line-fits-p (window start end body)
  "Return non-nil when START..END fits in WINDOW's BODY pixel height."
  (let ((window (or window (selected-window))))
    (if (and body (display-graphic-p (window-frame window)))
        (let ((height (ignore-errors
                        (cdr (window-text-pixel-size
                              window start end nil nil nil)))))
          (if (numberp height)
              (<= height body)
            (<= (count-lines start end) (window-body-height window))))
      (<= (count-lines start end) (window-body-height window)))))

(defun org-slides--prefer-heading-break (start end)
  "Return a nested heading position before END, or END.
A heading is only used when the preceding page remains at least half
full.  START is the beginning of the page."
  (if (not org-slides-page-break-at-headings)
      end
    (let ((min-fill (max 1 (/ (count-lines start end) 2)))
          (break end)
          (continue t))
      (save-excursion
        (goto-char end)
        (while (and continue (> (point) start))
          (forward-line -1)
          (when (and (> (point) start)
                     (org-at-heading-p)
                     (>= (count-lines start (point)) min-fill))
            (setq break (point)
                  continue nil))))
      break)))

(defun org-slides--split-page-end (start limit window body)
  "Return the end of the split page beginning at START.
LIMIT is the end of the logical slide.  WINDOW and BODY are used to
measure the rendered height."
  (save-excursion
    (goto-char start)
    (let ((last start)
          (continue t))
      (while (and continue (< (point) limit))
        (forward-line 1)
        (let ((candidate (min (point) limit)))
          (if (org-slides--line-fits-p window start candidate body)
              (setq last candidate)
            (setq continue nil))))
      (if (= last start)
          ;; A single line taller than the window still gets its own page.
          (save-excursion
            (goto-char start)
            (forward-line 1)
            (min (point) limit))
        (org-slides--prefer-heading-break start last)))))

(defun org-slides--trim-page-start (start end)
  "Move START forward over blank lines before END.
Indentation on a non-blank line is preserved."
  (save-excursion
    (goto-char start)
    (while (and (< (point) end)
                (looking-at "^[ \t]*$"))
      (forward-line 1))
    (point)))

(defun org-slides--compute-split-pages ()
  "Compute the split-page ranges for the current logical slide."
  (let* ((window (org-slides--presentation-window))
         (body (and window
                    (display-graphic-p (window-frame window))
                    (window-body-height window t)))
         (start (point-min))
         (limit (point-max))
         pages)
    (while (< start limit)
      (let* ((end (org-slides--split-page-end start limit window body))
             (end (max end (min limit (1+ start))))
             (page-start (org-slides--trim-page-start start end)))
        (when (< page-start end)
          (push (cons (copy-marker page-start) (copy-marker end)) pages))
        (setq start end)))
    (or (nreverse pages)
        (list (cons (copy-marker (point-min))
                    (copy-marker (point-max)))))))

(defun org-slides--release-pages (pages)
  "Release the markers in PAGES."
  (dolist (page pages)
    (when (markerp (car page))
      (set-marker (car page) nil))
    (when (markerp (cdr page))
      (set-marker (cdr page) nil))))

(defun org-slides--clear-split-pages ()
  "Release the markers for the current slide's split pages."
  (org-slides--release-pages org-slides--split-pages)
  (setq org-slides--split-pages nil))

(defun org-slides--restore-page-indicator ()
  "Restore the mode-line process string saved at presentation start."
  (setq-local mode-line-process org-slides--original-mode-line-process))

(defun org-slides--indicator-wanted-p (page-count)
  "Return non-nil when the slide.page indicator should be shown.
PAGE-COUNT is the number of pages in the current slide."
  (cond
   ((eq org-slides-page-indicator 'split) (> page-count 1))
   (org-slides-page-indicator t)
   (t nil)))

(defun org-slides--update-page-indicator ()
  "Show SLIDE.PAGE and the slide/page totals in the mode line."
  (if (and (org-slides--indicator-wanted-p
            (length org-slides--split-pages))
           (integerp org-slides--slide-number))
      (setq-local mode-line-process
                  (format " %s "
                          (format org-slides-page-indicator-format
                                  org-slides--slide-number
                                  (1+ org-slides--page-index)
                                  (length org-slides--slide-numbers)
                                  (length org-slides--split-pages))))
    (org-slides--restore-page-indicator)))

(defun org-slides--clear-pagination ()
  "Clear both scroll-page and split-page state."
  (org-slides--clear-page-markers)
  (org-slides--clear-split-pages)
  (setq org-slides--page-index 0)
  (org-slides--restore-page-indicator))

(defun org-slides--show-split-page (index)
  "Show split page INDEX, narrowed to that page only."
  (let ((page (nth index org-slides--split-pages)))
    (when page
      (let ((start (and (markerp (car page))
                        (marker-position (car page))))
            (end (and (markerp (cdr page))
                      (marker-position (cdr page)))))
        (when (and start end (<= start end))
          (org-slides--widen-logical)
          (narrow-to-region start end)
          (goto-char start)
          (setq org-slides--page-index index)
          (when-let* ((window (org-slides--presentation-window)))
            (set-window-start window start))
          (org-slides--update-page-indicator)
          t)))))

(defun org-slides--setup-split-pages (&optional index)
  "Compute split pages for the current slide and show page INDEX.
The mode-line indicator does not affect the text height."
  (org-slides--clear-split-pages)
  (org-slides--restore-page-indicator)
  (org-slides--widen-logical)
  (setq org-slides--split-pages (org-slides--compute-split-pages))
  (let* ((count (length org-slides--split-pages))
         (index (max 0 (min (or index 0) (1- count)))))
    (if (zerop count)
        (progn
          (setq org-slides--page-index 0)
          (org-slides--restore-page-indicator))
      (org-slides--show-split-page index))))

(defun org-slides--next-split-page ()
  "Show the next split page, returning non-nil on success."
  (when (and org-slides-auto-page
             (eq org-slides-page-style 'split)
             (not org-slides--one-big-page)
             (< (1+ org-slides--page-index)
                (length org-slides--split-pages)))
    (org-slides--show-split-page (1+ org-slides--page-index))))

(defun org-slides--prev-split-page ()
  "Show the previous split page, returning non-nil on success."
  (when (and org-slides-auto-page
             (eq org-slides-page-style 'split)
             (not org-slides--one-big-page)
             (> org-slides--page-index 0))
    (org-slides--show-split-page (1- org-slides--page-index))))

(defun org-slides--refresh-split-pages (&optional _frame)
  "Recompute split pages after the window size or a face change."
  (when (and org-slides-mode
             org-slides-auto-page
             (eq org-slides-page-style 'split)
             (not org-slides--one-big-page)
             org-slides--started
             (org-slides--presentation-window)
             (markerp org-slides--logical-start)
             (marker-position org-slides--logical-start))
    (org-slides--setup-split-pages org-slides--page-index)))

(defun org-slides--refresh-all-split-pages (&optional frame)
  "Refresh split pages in all presentation buffers on FRAME changes."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (org-slides--refresh-split-pages frame))))

(defun org-slides--clear-slide-numbers ()
  "Release the cached top-level heading positions."
  (dolist (entry org-slides--slide-numbers)
    (when (markerp (car entry))
      (set-marker (car entry) nil)))
  (setq org-slides--slide-numbers nil))

(defun org-slides--build-slide-numbers ()
  "Build (BEGIN-MARKER . NUMBER) for every top-level heading."
  (let ((numbers nil)
        (number 0))
    (save-restriction
      (widen)
      (org-element-map (org-element-parse-buffer) 'headline
        (lambda (headline)
          (when (= (org-element-property :level headline) 1)
            (setq number (1+ number))
            (push (cons (copy-marker (org-element-property :begin headline))
                        number)
                  numbers))
          nil)))
    (nreverse numbers)))

(defun org-slides--compute-slide-number ()
  "Return the ordinal of the current top-level heading.
The title page before the first heading is slide 0."
  (unless org-slides--slide-numbers
    (setq org-slides--slide-numbers (org-slides--build-slide-numbers)))
  (let ((target (or (and (markerp org-slides--logical-start)
                         (marker-position org-slides--logical-start))
                    (point-min)))
        (number 0))
    (catch 'done
      (dolist (entry org-slides--slide-numbers number)
        (let ((position (marker-position (car entry))))
          (if (and position (<= position target))
              (setq number (cdr entry))
            (throw 'done number)))))))

(defun org-slides--enter-slide ()
  "Run navigation hooks and show the first page of the current slide."
  (org-slides--clear-pagination)
  (when (and (eq org-slides-page-style 'split)
             org-slides-page-indicator
             (not org-slides--one-big-page))
    (setq org-slides--slide-number (org-slides--compute-slide-number)))
  (org-slides-run-after-navigate-functions)
  (when (and org-slides-auto-page
             (not org-slides--one-big-page))
    (if (eq org-slides-page-style 'split)
        (org-slides--setup-split-pages 0)
      (org-slides--reset-pages))))

(defun org-slides-next ()
  "Move to the next page, or the next top-level heading.
At the end of the last slide this does nothing, so the final page is
not replaced by the first page of the same slide."
  (interactive)
  (unless (if (eq org-slides-page-style 'split)
              (org-slides--next-split-page)
            (org-slides--next-page))
    (let ((next-slide
           (save-excursion
             (save-restriction
               (widen)
               (if (org-current-level)
                   (progn
                     (org-slides-top)
                     (org-get-next-sibling))
                 (outline-next-heading))))))
      (if next-slide
          (progn
            (widen)
            (goto-char next-slide)
            (org-slides--narrow-or-widen)
            (org-slides--enter-slide))
        (message "Org Slides: end of presentation")))))

(defun org-slides--show-last-scroll-page ()
  "Page forward to the last screenful of the current slide."
  (while (org-slides--next-page)))

(defun org-slides--show-last-page-if-changed (old-start)
  "Show the last page of the current slide when OLD-START differs.
OLD-START is the logical start of the slide we came from.  If it is
the same as the current slide, there was no previous slide to enter."
  (when (and old-start
             (markerp org-slides--logical-start)
             (marker-position org-slides--logical-start)
             (/= old-start (marker-position org-slides--logical-start)))
    (if (eq org-slides-page-style 'split)
        (when org-slides--split-pages
          (org-slides--show-split-page
           (1- (length org-slides--split-pages))))
      (when (and org-slides-auto-page
                 (not org-slides--one-big-page))
        (org-slides--show-last-scroll-page)))))

(defun org-slides-prev ()
  "Move to the previous page, or the previous top-level heading."
  (interactive)
  (unless (if (eq org-slides-page-style 'split)
              (org-slides--prev-split-page)
            (org-slides--prev-page))
    (let ((old-start (and (markerp org-slides--logical-start)
                          (marker-position org-slides--logical-start))))
      (widen)
      (if (org-current-level)
          (progn
            (org-slides-top)
            (unless (org-get-previous-sibling)
              (goto-char (point-min))))
        (goto-char (point-min)))
      (org-slides--narrow-or-widen)
      (org-slides--enter-slide)
      (org-slides--show-last-page-if-changed old-start))))

(defun org-slides-beginning ()
  "Move to the first slide (the title slide, if there is one)."
  (interactive)
  (widen)
  (goto-char (point-min))
  (org-slides--narrow-or-widen)
  (org-slides--enter-slide))

(defun org-slides-end ()
  "Move to the last slide."
  (interactive)
  (widen)
  (goto-char (point-max))
  (org-slides-top)
  (org-slides--narrow-or-widen)
  (org-slides--enter-slide))

(defun org-slides-toggle-one-big-page ()
  "Toggle between one slide at a time and the whole buffer."
  (interactive)
  (setq org-slides--one-big-page (not org-slides--one-big-page))
  (if org-slides--one-big-page
      (progn
        (widen)
        (org-slides--clear-pagination)
        (org-slides--clear-logical-bounds))
    (org-slides-narrow)
    (org-slides--enter-slide))
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
    (setq org-slides--started t
          org-slides--one-big-page nil
          org-slides--slide-number 0)
    (org-slides--clear-slide-numbers)
    (setq org-slides--original-mode-line-process mode-line-process)
    (org-slides--clear-pagination)
    (org-slides--clear-logical-bounds)
    (when-let* ((window (org-slides--presentation-window)))
      (setq org-slides--original-window-start
            (copy-marker (window-start window))))
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
    (add-hook 'text-scale-mode-hook
              #'org-slides--refresh-split-pages nil t)
    (add-hook 'buffer-face-mode-hook
              #'org-slides--refresh-split-pages nil t)
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
          org-slides--one-big-page nil
          org-slides--slide-number 0)
    (remove-hook 'text-scale-mode-hook
                 #'org-slides--refresh-split-pages t)
    (remove-hook 'buffer-face-mode-hook
                 #'org-slides--refresh-split-pages t)
    (org-slides--clear-pagination)
    (org-slides--clear-logical-bounds)
    (org-slides--clear-slide-numbers)
    (widen)
    (when (markerp org-slides--original-window-start)
      (let ((window (org-slides--presentation-window))
            (start (marker-position org-slides--original-window-start)))
        (when (and window start)
          (set-window-start window start)))
      (set-marker org-slides--original-window-start nil))
    (setq org-slides--original-window-start nil
          org-slides--original-mode-line-process nil)))

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
    (org-slides--enter-slide)))

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

(add-hook 'window-size-change-functions
          #'org-slides--refresh-all-split-pages)

(provide 'org-slides)
;;; org-slides.el ends here
