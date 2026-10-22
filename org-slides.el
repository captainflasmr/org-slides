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
;; - A side demo pane can show a buffer, file, URL, video, shell, command,
;;   or keyboard macro while slides are presented.  A slide selects its
;;   demo with a `DEMO' property or `#+DEMO:' line; `DEMO-MACRO' replays
;;   recorded keys after the demo buffer appears.  See
;;   `org-slides-demo-show' and `org-slides-demo-play-macro'.
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
(require 'kmacro)
(require 'subr-x)
(require 'url-util)

(defvar eww-buffer-name)

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

(defcustom org-slides-incremental-bullets t
  "Whether to show Org list items one at a time.
When non-nil, list items on the current page are displayed with the
`org-slides-bullet-shadow' face.  SPC reveals the next item; S-SPC
puts the previous item back into shadow.  Once every item is revealed,
SPC advances to the next page or slide."
  :type 'boolean
  :group 'org-slides)

(defcustom org-slides-demo-pane t
  "Whether to allow a demonstration pane beside the presentation.
When non-nil, slides can request a demo with a `DEMO' property or a
`#+DEMO:' line.  The demo is shown in a side window and is updated
when the presentation moves to another slide."
  :type 'boolean
  :group 'org-slides)

(defcustom org-slides-demo-width 0.4
  "Width of the demo side window.
An integer is a number of columns and a float is a fraction of the
frame width.  The presentation keeps the remaining space."
  :type 'number
  :group 'org-slides)

(defcustom org-slides-demo-side 'right
  "Side of the frame used for the demo window."
  :type '(choice (const :tag "Right" right)
                 (const :tag "Left" left))
  :group 'org-slides)

(defcustom org-slides-demo-default nil
  "Demo spec used on slides that do not define their own.
The value uses the same syntax as `org-slides-demo-show', for example
\"buffer:*scratch*\" or \"file:~/demo.org\"."
  :type '(choice (const :tag "None" nil)
                 (string :tag "Demo spec"))
  :group 'org-slides)

(defcustom org-slides-demo-keep nil
  "Whether to keep the current demo on a slide without a demo spec.
When nil, moving to a slide with no `DEMO' property, no `#+DEMO:'
line, and no `org-slides-demo-default' hides the demo pane."
  :type 'boolean
  :group 'org-slides)

(defcustom org-slides-demo-video-backend 'auto
  "How `video:' demo specs are played.
`auto' uses an xwidget web view inside Emacs when xwidgets are
available, and falls back to `org-slides-demo-video-player' otherwise.
`xwidget' requires an Emacs built with xwidgets and a graphical frame.
`external' always launches an external player."
  :type '(choice (const :tag "Automatic" auto)
                 (const :tag "xwidget inside Emacs" xwidget)
                 (const :tag "External player" external))
  :group 'org-slides)

(defcustom org-slides-demo-video-player nil
  "Program used to play video demos outside Emacs.
When nil, files are opened with `org-open-file' and URLs with
`browse-url'.  A string is run as a shell command with the file or URL
appended.  A function is called with the file or URL as its only
argument; if it returns a process, that process is stopped when the
presentation quits."
  :type '(choice (const :tag "System default" nil)
                 (string :tag "Shell command")
                 (function :tag "Function"))
  :group 'org-slides)

(defcustom org-slides-demo-video-extensions
  '("avi" "flv" "m4v" "mkv" "mov" "mp4" "mpeg" "mpg" "ogv" "ogg"
    "webm" "wmv")
  "File extensions treated as videos by `file:' demo specs."
  :type '(repeat string)
  :group 'org-slides)

(defcustom org-slides-demo-kill-buffers t
  "Whether to kill temporary buffers created for demos on quit.
Buffers belonging to files, `buffer:' specs, and expressions are not
killed.  Command output, shell, EWW, xwidget, and macro scratch
buffers created for a demo are killed when this is non-nil."
  :type 'boolean
  :group 'org-slides)

(defcustom org-slides-demo-macro-delay 0
  "Seconds to wait before playing a slide's demo macro.
A positive value gives a newly started shell, REPL, or web view time to
settle before the recorded keys arrive.  Zero plays the macro as soon
as the demo buffer is displayed."
  :type 'number
  :group 'org-slides)

(defcustom org-slides-timed-macro-speed 1.0
  "Default playback speed for timed keyboard macros.
1.0 reproduces the recorded delays.  Values below 1.0 are faster and
values above 1.0 are slower."
  :type 'number
  :group 'org-slides)

(defface org-slides-bullet-shadow
  '((t (:inherit shadow)))
  "Face used for Org list items that have not been revealed yet."
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

(defvar-local org-slides--bullet-ranges nil
  "Vector of (START . END) markers for the current page's list items.")

(defvar-local org-slides--bullet-overlays nil
  "Vector of shadow overlays parallel to `org-slides--bullet-ranges'.")

(defvar-local org-slides--bullet-index 0
  "Number of list items revealed on the current page.")

(defvar-local org-slides--bullet-state nil
  "Hash table mapping (SLIDE-START . PAGE) to revealed item counts.")

(defvar-local org-slides--original-window-start nil
  "Marker for the window start before the presentation began.")

(defvar-local org-slides--demo-window nil
  "Side window currently showing the demo.")

(defvar-local org-slides--demo-buffer nil
  "Buffer currently shown in the demo pane.")

(defvar-local org-slides--demo-spec nil
  "Demo spec for the current slide, or the symbol `none'.")

(defvar-local org-slides--demo-macro nil
  "Keyboard macro requested for the current slide's demo.")

(defvar-local org-slides--demo-timed-macro nil
  "Timed keyboard macro requested for the current slide's demo.")

(defvar-local org-slides--demo-macro-timer nil
  "Pending timer for a delayed demo macro.")

(defvar-local org-slides--demo-presentation-buffer nil
  "Presentation buffer associated with this buffer.
It is set in the presentation buffer and in buffers shown in its demo
pane, so demo commands work from either window.")

(defvar-local org-slides--demo-processes nil
  "Processes started for the current presentation's demo.")

(defvar-local org-slides--demo-created-buffers nil
  "Temporary buffers created for the current presentation's demo.")

(defvar-local org-slides--demo-temp-files nil
  "Temporary files created for the current presentation's demo.")

(defvar org-slides-demo-history nil
  "History of demo specs entered with `org-slides-demo-show'.")

(defvar org-slides-demo-macro-history nil
  "History of macro names entered with `org-slides-demo-play-macro'.")

(defvar org-slides-timed-macro-last nil
  "The most recently recorded timed keyboard macro.
Each entry is a cons (TIMESTAMP . KEYS), where TIMESTAMP is seconds
since recording started and KEYS is a string or vector accepted by
`execute-kbd-macro'.")

(defvar org-slides--timed-macro-recording nil
  "Non-nil while a timed keyboard macro is being recorded.")

(defvar org-slides--timed-macro-entries nil
  "Entries recorded for the current timed macro, newest first.")

(defvar org-slides--timed-macro-start-time nil
  "Start time of the current timed macro recording.")

(defvar org-slides--timed-macro-playback nil
  "Active asynchronous timed macro playback state.
A plist with the entries, index, start time, speed, target window,
demo flag, presentation buffer, and return window.")

(defvar org-slides-timed-macro-history nil
  "History of timed macro names.")

(defvar org-slides-demo-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-o") #'org-slides-demo-select)
    (define-key map (kbd "C-c C-d") #'org-slides-demo-toggle)
    (define-key map (kbd "C-c C-m") #'org-slides-demo-play-macro)
    (define-key map (kbd "C-c C-t") #'org-slides-timed-macro-toggle)
    (define-key map (kbd "C-c C-n") #'org-slides-demo-next)
    (define-key map (kbd "C-c C-p") #'org-slides-demo-prev)
    (define-key map (kbd "C-c C-q") #'org-slides-demo-quit)
    map)
  "Keymap for `org-slides-demo-mode'.")

;;;###autoload
(define-minor-mode org-slides-demo-mode
  "Minor mode for buffers displayed in the org-slides demo pane.
It adds keys to return to the presentation, hide the demo, play a
keyboard macro, start or stop timed macro recording, and drive slide
navigation without leaving the demo buffer."
  :init-value nil
  :lighter " Demo"
  :keymap org-slides-demo-mode-map
  :group 'org-slides)

(defvar org-slides-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Forward/backward.  The -or-self-insert commands keep the buffer
    ;; editable when read-only mode is off.
    (define-key map (kbd "n") #'org-slides-next-or-self-insert)
    (define-key map (kbd "SPC") #'org-slides-step-forward-or-self-insert)
    (define-key map (kbd "f") #'org-slides-step-forward-or-self-insert)
    (define-key map (kbd "p") #'org-slides-prev-or-self-insert)
    (define-key map (kbd "S-SPC") #'org-slides-step-backward-or-self-insert)
    ;; Some GUI/terminal setups deliver Shift+Space as plain Space.  Keep
    ;; unambiguous alternatives for stepping backward.
    (define-key map (kbd "b") #'org-slides-step-backward-or-self-insert)
    (define-key map [backtab] #'org-slides-step-backward-or-shifttab)
    (define-key map [backspace] #'org-slides-step-backward-or-delete)
    (define-key map (kbd "C-c C-b") #'org-slides-step-backward)
    (define-key map [right] #'org-slides-next)
    (define-key map [left] #'org-slides-prev)
    (define-key map [next] #'org-slides-next)
    (define-key map [prior] #'org-slides-prev)
    (define-key map (kbd "C-c C-n") #'org-slides-next)
    (define-key map (kbd "C-c C-p") #'org-slides-prev)
    ;; Demonstration pane.
    (define-key map (kbd "d") #'org-slides-demo-toggle-or-self-insert)
    (define-key map (kbd "m") #'org-slides-demo-play-macro-or-self-insert)
    (define-key map (kbd "C-c C-d") #'org-slides-demo-toggle)
    (define-key map (kbd "C-c C-m") #'org-slides-demo-play-macro)
    (define-key map (kbd "C-c C-t") #'org-slides-timed-macro-toggle)
    (define-key map (kbd "C-c C-o") #'org-slides-demo-select)
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
  "Clear scroll-page, split-page, and bullet stepping state."
  (org-slides--clear-page-markers)
  (org-slides--clear-split-pages)
  (org-slides--clear-bullets)
  (setq org-slides--page-index 0)
  (org-slides--restore-page-indicator))

(defun org-slides--show-split-page (index &optional revealed)
  "Show split page INDEX, narrowed to that page only.
When REVEALED is non-nil, start with all list items in the foreground."
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
          (org-slides--setup-bullets revealed)
          (org-slides--update-page-indicator)
          t)))))

(defun org-slides--setup-split-pages (&optional index revealed)
  "Compute split pages for the current slide and show page INDEX.
The mode-line indicator does not affect the text height.  When
REVEALED is non-nil, start with list items in the foreground."
  (org-slides--clear-split-pages)
  (org-slides--restore-page-indicator)
  (org-slides--widen-logical)
  (setq org-slides--split-pages (org-slides--compute-split-pages))
  (let* ((count (length org-slides--split-pages))
         (index (max 0 (min (or index 0) (1- count)))))
    (if (zerop count)
        (progn
          (setq org-slides--page-index 0)
          (org-slides--restore-page-indicator)
          (org-slides--clear-bullets))
      (org-slides--show-split-page index revealed))))

(defun org-slides--next-split-page ()
  "Show the next split page, returning non-nil on success."
  (when (and org-slides-auto-page
             (eq org-slides-page-style 'split)
             (not org-slides--one-big-page)
             (< (1+ org-slides--page-index)
                (length org-slides--split-pages)))
    (org-slides--show-split-page (1+ org-slides--page-index))))

(defun org-slides--prev-split-page ()
  "Show the previous split page with all list items revealed."
  (when (and org-slides-auto-page
             (eq org-slides-page-style 'split)
             (not org-slides--one-big-page)
             (> org-slides--page-index 0))
    (org-slides--show-split-page (1- org-slides--page-index) t)))

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

(defun org-slides--item-own-end (item)
  "Return the end of ITEM's own text, before any nested list."
  (let (child-begin)
    (dolist (child (org-element-contents item))
      (when (and (not child-begin)
                 (eq (org-element-type child) 'plain-list))
        (setq child-begin (org-element-property :begin child))))
    (or child-begin
        (org-element-property :contents-end item)
        (org-element-property :end item))))

(defun org-slides--collect-bullet-ranges ()
  "Return list items in the accessible buffer as (START . END) markers."
  (let (ranges)
    (org-element-map (org-element-parse-buffer) 'item
      (lambda (item)
        (let ((begin (org-element-property :begin item))
              (end (org-slides--item-own-end item)))
          (when (and begin end (< begin end))
            (push (cons (copy-marker begin) (copy-marker end)) ranges)))
        nil))
    (nreverse ranges)))

(defun org-slides--make-bullet-overlay (range)
  "Create a shadow overlay for list-item RANGE."
  (let ((start (and (markerp (car range))
                    (marker-position (car range))))
        (end (and (markerp (cdr range))
                  (marker-position (cdr range)))))
    (when (and start end (< start end))
      (let ((overlay (make-overlay start end)))
        (overlay-put overlay 'face 'org-slides-bullet-shadow)
        (overlay-put overlay 'evaporate t)
        overlay))))

(defun org-slides--clear-bullets ()
  "Remove list-item shadow overlays and release their markers."
  (when (vectorp org-slides--bullet-overlays)
    (dotimes (i (length org-slides--bullet-overlays))
      (let ((overlay (aref org-slides--bullet-overlays i)))
        (when (and (overlayp overlay)
                   (overlay-buffer overlay))
          (delete-overlay overlay)))))
  (when (vectorp org-slides--bullet-ranges)
    (dotimes (i (length org-slides--bullet-ranges))
      (let ((range (aref org-slides--bullet-ranges i)))
        (when (markerp (car range))
          (set-marker (car range) nil))
        (when (markerp (cdr range))
          (set-marker (cdr range) nil)))))
  (setq org-slides--bullet-ranges nil
        org-slides--bullet-overlays nil
        org-slides--bullet-index 0))

(defun org-slides--bullet-state-key ()
  "Return the persistence key for the current slide and page."
  (let ((slide (or (and (markerp org-slides--logical-start)
                        (marker-position org-slides--logical-start))
                   (point-min))))
    (if (eq org-slides-page-style 'split)
        (cons slide org-slides--page-index)
      (cons slide 'scroll))))

(defun org-slides--save-bullet-state ()
  "Store the current number of revealed list items."
  (when (and (hash-table-p org-slides--bullet-state)
             (markerp org-slides--logical-start)
             (marker-position org-slides--logical-start))
    (puthash (org-slides--bullet-state-key)
             org-slides--bullet-index
             org-slides--bullet-state)))

(defun org-slides--setup-bullets (revealed)
  "Set up list-item stepping for the current page.
REVEALED is the default for a page not visited before: non-nil means
all items start in the foreground, nil means they start shadowed.
A previously saved reveal count is always restored."
  (org-slides--clear-bullets)
  (when org-slides-incremental-bullets
    (let* ((ranges (vconcat (org-slides--collect-bullet-ranges)))
           (count (length ranges))
           (key (org-slides--bullet-state-key))
           (saved (and (hash-table-p org-slides--bullet-state)
                       (gethash key org-slides--bullet-state 'missing)))
           (index (if (eq saved 'missing)
                      (if revealed count 0)
                    (max 0 (min saved count))))
           (overlays (make-vector count nil)))
      (setq org-slides--bullet-ranges ranges
            org-slides--bullet-overlays overlays
            org-slides--bullet-index index)
      (when (hash-table-p org-slides--bullet-state)
        (puthash key index org-slides--bullet-state))
      (dotimes (i count)
        (when (>= i index)
          (aset overlays i (org-slides--make-bullet-overlay (aref ranges i)))))
      (force-window-update (current-buffer)))))

(defun org-slides--reveal-next-bullet ()
  "Reveal the next shadowed list item.  Return non-nil on success."
  (when (and org-slides-incremental-bullets
             (vectorp org-slides--bullet-ranges)
             (< org-slides--bullet-index
                (length org-slides--bullet-ranges)))
    (let ((index org-slides--bullet-index)
          (overlay (aref org-slides--bullet-overlays
                         org-slides--bullet-index)))
      (when (and (overlayp overlay)
                 (overlay-buffer overlay))
        (delete-overlay overlay))
      (aset org-slides--bullet-overlays index nil)
      (setq org-slides--bullet-index (1+ index))
      (org-slides--save-bullet-state)
      (force-window-update (current-buffer))
      t)))

(defun org-slides--hide-previous-bullet ()
  "Put the last revealed list item back into shadow.
Return non-nil on success."
  (when (and org-slides-incremental-bullets
             (vectorp org-slides--bullet-ranges)
             (> org-slides--bullet-index 0))
    (let* ((index (1- org-slides--bullet-index))
           (overlay (aref org-slides--bullet-overlays index)))
      (setq org-slides--bullet-index index)
      (unless (and (overlayp overlay)
                   (overlay-buffer overlay))
        (aset org-slides--bullet-overlays index
              (org-slides--make-bullet-overlay
               (aref org-slides--bullet-ranges index))))
      (org-slides--save-bullet-state)
      (force-window-update (current-buffer))
      t)))

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

(defun org-slides--enter-slide (&optional revealed)
  "Run navigation hooks and show the first page of the current slide.
When REVEALED is non-nil, list items start in the foreground."
  (org-slides--clear-pagination)
  (when (and (eq org-slides-page-style 'split)
             org-slides-page-indicator
             (not org-slides--one-big-page))
    (setq org-slides--slide-number (org-slides--compute-slide-number)))
  (org-slides--update-demo)
  (org-slides-run-after-navigate-functions)
  (cond
   (org-slides--one-big-page
    (org-slides--clear-bullets))
   ((and org-slides-auto-page
         (eq org-slides-page-style 'split))
    (org-slides--setup-split-pages 0 revealed))
   (t
    (when org-slides-auto-page
      (org-slides--reset-pages))
    (org-slides--setup-bullets revealed))))

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
           (1- (length org-slides--split-pages)) t))
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
      (let ((new-start (and (markerp org-slides--logical-start)
                            (marker-position org-slides--logical-start))))
        (org-slides--enter-slide
         (and old-start new-start (/= old-start new-start))))
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
          org-slides--slide-number 0
          org-slides--bullet-state (make-hash-table :test 'equal)
          org-slides--demo-presentation-buffer (current-buffer))
    (org-slides--demo-reset)
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
    (org-slides--demo-reset)
    (org-slides--restore-scale)
    (when org-slides--images-displayed
      (org-slides--remove-inline-images)
      (setq org-slides--images-displayed nil))
    (org-slides-show-cursor)
    (org-slides--rm-overlays)
    (setq buffer-read-only org-slides--previous-read-only)
    (setq org-slides--cursor-cache nil
          org-slides--one-big-page nil
          org-slides--slide-number 0
          org-slides--bullet-state nil
          org-slides--demo-presentation-buffer nil)
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

;;; Demo pane

(defun org-slides--demo-url-p (string)
  "Return non-nil when STRING has a URL scheme."
  (and (stringp string)
       (string-match-p "\\`[A-Za-z][A-Za-z0-9+.-]*://" string)))

(defun org-slides--demo-file-url (path)
  "Return a file URL for PATH."
  (concat "file://"
          (url-hexify-string (expand-file-name path)
                             (append url-unreserved-chars '(?/ ?:)))))

(defun org-slides--demo-video-file-p (file)
  "Return non-nil when FILE has a configured video extension."
  (let ((extension (downcase (or (file-name-extension file) ""))))
    (and (not (string-empty-p extension))
         (member extension org-slides-demo-video-extensions))))

(defun org-slides--demo-parse-spec (spec)
  "Return (KIND . VALUE) for demo SPEC.
KIND is one of `buffer', `file', `url', `video', `command', `shell',
`macro', `timed-macro', `elisp', `external', or `none'.  A spec without
a recognized prefix is a file path; a bare URL is a URL."
  (let* ((spec (string-trim (if (symbolp spec) (symbol-name spec) spec)))
         (colon (string-match ":" spec))
         (kind (and colon
                    (intern-soft (downcase (substring spec 0 colon))))))
    (cond
     ((or (eq kind 'none)
          (string-equal (downcase spec) "none"))
      (cons 'none nil))
     ((and kind
           (memq kind '(buffer file url video command shell macro
                               timed-macro elisp external)))
      (cons kind (string-trim (substring spec (1+ colon)))))
     ((org-slides--demo-url-p spec)
      (cons 'url spec))
     (t
      (cons 'file spec)))))

(defun org-slides--demo-none-spec-p (spec)
  "Return non-nil when SPEC disables the demo pane."
  (or (eq spec 'none)
      (and (stringp spec)
           (eq (car (org-slides--demo-parse-spec spec)) 'none))))

(defun org-slides--demo-presentation ()
  "Return the presentation buffer for the current demo context."
  (cond
   ((buffer-live-p org-slides--demo-presentation-buffer)
    org-slides--demo-presentation-buffer)
   (org-slides-mode
    (current-buffer))
   (t nil)))

(defun org-slides--demo-window (&optional presentation)
  "Return the demo window for PRESENTATION, or nil.
PRESENTATION defaults to the active presentation buffer."
  (let ((presentation (or presentation
                          (org-slides--demo-presentation)
                          (current-buffer))))
    (or (and (window-live-p org-slides--demo-window)
             (eq (window-parameter org-slides--demo-window
                                   'org-slides-demo-presentation)
                 presentation)
             org-slides--demo-window)
        (let (found)
          (dolist (window (window-list nil 'nomini))
            (when (and (not found)
                       (window-parameter window 'org-slides-demo)
                       (eq (window-parameter window
                                             'org-slides-demo-presentation)
                           presentation))
              (setq found window)))
          found))))

(defun org-slides--demo-xwidget-available-p ()
  "Return non-nil when xwidget-webkit can be used in this session."
  (and (display-graphic-p)
       (require 'xwidget nil t)
       (featurep 'xwidget-internal)))

(defun org-slides--demo-open-xwidget (url)
  "Open URL in a new xwidget session and return its buffer."
  (let ((before (buffer-list))
        buffer)
    (save-window-excursion
      (xwidget-webkit-browse-url url t))
    (dolist (candidate (buffer-list))
      (unless (or buffer (memq candidate before))
        (with-current-buffer candidate
          (when (eq major-mode 'xwidget-webkit-mode)
            (setq buffer candidate)))))
    (setq buffer
          (or buffer
              (and (boundp 'xwidget-webkit-last-session-buffer)
                   (buffer-live-p xwidget-webkit-last-session-buffer)
                   xwidget-webkit-last-session-buffer)))
    (unless buffer
      (user-error "Could not open an xwidget session"))
    (unless (memq buffer before)
      (push buffer org-slides--demo-created-buffers))
    buffer))

(defun org-slides--demo-video-page (path)
  "Create an HTML page that plays PATH and return its file URL."
  (let* ((source (org-slides--demo-file-url path))
         (html (make-temp-file "org-slides-video-" nil ".html")))
    (with-temp-file html
      (insert
       "<!doctype html>\n<html><head><meta charset=\"utf-8\">\n"
       "<style>html,body{margin:0;height:100%;background:#000;}"
       "video{width:100%;height:100%;object-fit:contain;}</style>\n"
       "</head><body><video controls autoplay playsinline src=\""
       source "\"></video></body></html>\n"))
    (push html org-slides--demo-temp-files)
    (org-slides--demo-file-url html)))

(defun org-slides--demo-play-external (value)
  "Play VALUE with the configured external video player."
  (let ((target (if (org-slides--demo-url-p value)
                    value
                  (expand-file-name value))))
    (cond
     ((functionp org-slides-demo-video-player)
      (let ((result (funcall org-slides-demo-video-player target)))
        (when (processp result)
          (push result org-slides--demo-processes))
        result))
     ((and (stringp org-slides-demo-video-player)
           (not (string-empty-p org-slides-demo-video-player)))
      (let ((process
             (start-process
              "org-slides-video" nil
              (or shell-file-name "/bin/sh")
              (or shell-command-switch "-c")
              (concat org-slides-demo-video-player " "
                      (shell-quote-argument target)))))
        (push process org-slides--demo-processes)
        (message "Org Slides: playing video with %s"
                 org-slides-demo-video-player)))
     ((org-slides--demo-url-p value)
      (browse-url target))
     (t
      (org-open-file target)))))

(defun org-slides--demo-open-video (value)
  "Open VALUE as a video, returning a buffer or nil for an external player."
  (unless (or (org-slides--demo-url-p value)
              (file-exists-p (expand-file-name value)))
    (user-error "Video file does not exist: %s" value))
  (cond
   ((and (memq org-slides-demo-video-backend '(auto xwidget))
         (org-slides--demo-xwidget-available-p))
    (org-slides--demo-open-xwidget
     (if (org-slides--demo-url-p value)
         value
       (org-slides--demo-video-page value))))
   ((eq org-slides-demo-video-backend 'xwidget)
    (user-error "xwidget video playback is not available in this Emacs"))
   (t
    (org-slides--demo-play-external value)
    nil)))

(defun org-slides--demo-open-eww (url)
  "Open URL with EWW and return the EWW buffer."
  (require 'eww)
  (let ((before (buffer-list))
        buffer)
    (save-window-excursion
      (eww url))
    (dolist (candidate (buffer-list))
      (unless (or buffer (memq candidate before))
        (with-current-buffer candidate
          (when (derived-mode-p 'eww-mode)
            (setq buffer candidate)))))
    (setq buffer (or buffer (get-buffer eww-buffer-name)))
    (unless buffer
      (user-error "Could not open URL in EWW"))
    (unless (memq buffer before)
      (push buffer org-slides--demo-created-buffers))
    buffer))

(defun org-slides--demo-open-url (url)
  "Open URL in Emacs and return the buffer showing it."
  (if (org-slides--demo-xwidget-available-p)
      (org-slides--demo-open-xwidget url)
    (org-slides--demo-open-eww url)))

(defun org-slides--demo-open-file (path)
  "Open PATH for a demo and return its buffer.
Video files are played by `org-slides--demo-open-video'."
  (let ((file (expand-file-name path)))
    (cond
     ((file-directory-p file)
      (dired-noselect file))
     ((org-slides--demo-video-file-p file)
      (org-slides--demo-open-video file))
     ((file-exists-p file)
      (find-file-noselect file t))
     (t
      (user-error "Demo file does not exist: %s" file)))))

(defun org-slides--demo-open-shell (name)
  "Start or reuse a shell for a demo and return its buffer.
NAME is the buffer name, or an empty string for `*shell*'."
  (require 'shell)
  (let* ((name (if (string-empty-p name) "*shell*" name))
         (existing (get-buffer name))
         (buffer (save-window-excursion (shell name))))
    (unless (buffer-live-p buffer)
      (setq buffer (get-buffer name)))
    (unless buffer
      (user-error "Could not start a shell"))
    (unless existing
      (push buffer org-slides--demo-created-buffers))
    buffer))

(defun org-slides--demo-command-sentinel (process event)
  "Record the end of demo command PROCESS in its output buffer."
  (let ((buffer (process-buffer process)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert (format "\n[%s]" (string-trim event))))))))

(defun org-slides--demo-open-command (command)
  "Run COMMAND for a demo and return its output buffer."
  (let* ((directory default-directory)
         (name (format "*org-slides-demo: %s*"
                       (substring command 0 (min 40 (length command)))))
         (buffer (generate-new-buffer name)))
    (with-current-buffer buffer
      (setq default-directory directory)
      (insert (format "$ %s\n\n" command)))
    (condition-case err
        (let ((process
               (make-process
                :name (buffer-name buffer)
                :buffer buffer
                :command (list (or shell-file-name "/bin/sh")
                               (or shell-command-switch "-c")
                               command)
                :coding 'utf-8-unix
                :connection-type 'pipe
                :noquery t
                :sentinel #'org-slides--demo-command-sentinel)))
          (push buffer org-slides--demo-created-buffers)
          (push process org-slides--demo-processes)
          buffer)
      (error
       (ignore-errors (kill-buffer buffer))
       (signal (car err) (cdr err))))))

(defun org-slides--demo-open-elisp (form)
  "Evaluate FORM for a demo and return a buffer.
FORM may evaluate to a buffer, a demo spec string, or nil."
  (let ((result (eval (read form) t)))
    (cond
     ((bufferp result) result)
     ((stringp result) (org-slides--demo-resolve result))
     ((null result) nil)
     (t
      (user-error "Demo expression returned %S; expected a buffer, string, or nil"
                  result)))))

(defun org-slides--demo-open-external (value)
  "Open VALUE outside Emacs."
  (if (org-slides--demo-url-p value)
      (browse-url value)
    (org-open-file (expand-file-name value))))

(defun org-slides--demo-macro-buffer ()
  "Return the buffer where a macro demo should run.
Reuse the current demo buffer when one is visible; otherwise create a
scratch buffer for the macro."
  (let ((window (org-slides--demo-window)))
    (if (and (window-live-p window)
             (buffer-live-p (window-buffer window))
             (not (eq (window-buffer window) (current-buffer))))
        (window-buffer window)
      (let ((buffer (generate-new-buffer "*org-slides-demo*")))
        (with-current-buffer buffer
          (fundamental-mode))
        (push buffer org-slides--demo-created-buffers)
        buffer))))

(defun org-slides--demo-resolve (spec)
  "Return a buffer for demo SPEC, or nil when it opens externally."
  (let* ((parsed (org-slides--demo-parse-spec spec))
         (kind (car parsed))
         (value (cdr parsed)))
    (pcase kind
      ('buffer
       (or (get-buffer value)
           (user-error "No buffer named %s" value)))
      ('file (org-slides--demo-open-file value))
      ('url (org-slides--demo-open-url value))
      ('video (org-slides--demo-open-video value))
      ('command (org-slides--demo-open-command value))
      ('shell (org-slides--demo-open-shell value))
      ('macro (org-slides--demo-macro-buffer))
      ('timed-macro (org-slides--demo-macro-buffer))
      ('elisp (org-slides--demo-open-elisp value))
      ('external
       (org-slides--demo-open-external value)
       nil)
      ('none nil)
      (_ (org-slides--demo-open-file spec)))))

(defun org-slides--demo-display (buffer)
  "Display BUFFER in the demo side window."
  (unless (buffer-live-p buffer)
    (user-error "Demo buffer is not live"))
  (when (eq buffer (current-buffer))
    (user-error "The presentation buffer cannot be its own demo"))
  (let* ((presentation (current-buffer))
         (old-window (org-slides--demo-window presentation))
         (old-buffer (and old-window (window-buffer old-window)))
         (alist `((display-buffer-in-side-window)
                  (side . ,org-slides-demo-side)
                  (slot . 0)
                  (window-width . ,org-slides-demo-width)
                  (preserve-size . (t . nil))
                  (window-parameters
                   . ((org-slides-demo . t)
                      (org-slides-demo-presentation . ,presentation)))))
         (window (display-buffer buffer alist)))
    (unless (window-live-p window)
      (user-error "Unable to display the demo buffer"))
    (when (and old-buffer
               (not (eq old-buffer buffer))
               (buffer-live-p old-buffer))
      (with-current-buffer old-buffer
        (when org-slides-demo-mode
          (org-slides-demo-mode -1))
        (setq org-slides--demo-presentation-buffer nil)))
    (set-window-parameter window 'org-slides-demo t)
    (set-window-parameter window 'org-slides-demo-presentation presentation)
    (setq org-slides--demo-window window
          org-slides--demo-buffer buffer)
    (with-current-buffer buffer
      (setq-local org-slides--demo-presentation-buffer presentation)
      (org-slides-demo-mode 1))
    (force-window-update buffer)
    window))

(defun org-slides--demo-call-in-window (buffer function)
  "Call FUNCTION in the demo window, showing BUFFER when it is live.
Temporarily disable `org-slides-demo-mode' so recorded keys reach the
buffer's major mode, then restore demo mode in the buffers shown by
the demo window."
  (let ((window (org-slides--demo-window))
        (presentation (org-slides--demo-presentation)))
    (unless (window-live-p window)
      (user-error "No demo pane is visible"))
    (let ((buffer (or (and (buffer-live-p buffer) buffer)
                      (window-buffer window))))
      (unless (buffer-live-p buffer)
        (user-error "The demo buffer is not live"))
      (unwind-protect
          (progn
            (when (buffer-local-value 'org-slides-demo-mode buffer)
              (with-current-buffer buffer
                (org-slides-demo-mode -1)))
            (with-selected-window window
              (when (and (buffer-live-p buffer)
                         (not (eq (window-buffer window) buffer)))
                (set-window-buffer window buffer))
              (funcall function)))
        (dolist (target (list buffer
                              (and (window-live-p window)
                                   (window-buffer window))))
          (when (and (buffer-live-p target)
                     (not (eq target presentation)))
            (with-current-buffer target
              (setq-local org-slides--demo-presentation-buffer presentation)
              (org-slides-demo-mode 1))))))))

(defun org-slides--demo-macro-definition (macro)
  "Return an object `execute-kbd-macro' can run for MACRO.
MACRO is a named keyboard macro or `register:CHAR'."
  (let ((macro (string-trim (if (symbolp macro) (symbol-name macro) macro))))
    (cond
     ((string-prefix-p "register:" macro)
      (let* ((name (substring macro (length "register:")))
             (register (and (not (string-empty-p name))
                            (string-to-char name))))
        (unless register
          (user-error "A register name is required: %s" macro))
        (let ((value (get-register register)))
          (unless (or (stringp value) (vectorp value))
            (user-error "Register %c does not contain a keyboard macro"
                        register))
          value)))
     ((string-empty-p macro)
      (user-error "A macro name is required"))
     (t
      (let ((symbol (intern macro)))
        (unless (fboundp symbol)
          (user-error "No keyboard macro named %s" macro))
        (let ((definition (symbol-function symbol)))
          (unless (or (stringp definition)
                      (vectorp definition)
                      (kmacro-keyboard-macro-p symbol))
            (user-error "%s is not a keyboard macro" macro)))
        symbol)))))

(defun org-slides--demo-cancel-macro ()
  "Cancel a pending or active demo macro."
  (org-slides--timed-macro-cancel-playback)
  (when (timerp org-slides--demo-macro-timer)
    (cancel-timer org-slides--demo-macro-timer))
  (setq org-slides--demo-macro-timer nil))

(defun org-slides--demo-play-macro (macro &optional buffer)
  "Play keyboard macro MACRO in the demo pane.
BUFFER defaults to the buffer currently shown there.  MACRO is a named
keyboard macro or `register:CHAR'."
  (let ((definition (org-slides--demo-macro-definition macro)))
    (org-slides--demo-call-in-window
     buffer
     (lambda ()
       (if (and (symbolp definition)
                (kmacro-keyboard-macro-p definition)
                (not (let ((function (symbol-function definition)))
                       (or (stringp function) (vectorp function)))))
           (call-interactively definition)
         (execute-kbd-macro definition))))))

;;; Timed keyboard macros

(defun org-slides--timed-macro-p (value)
  "Return non-nil when VALUE looks like a timed keyboard macro."
  (and (consp value)
       (let ((ok t))
         (dolist (entry value ok)
           (unless (and (consp entry)
                        (numberp (car entry))
                        (>= (car entry) 0)
                        (let ((keys (cdr entry)))
                          (or (stringp keys) (vectorp keys))))
             (setq ok nil))))))

(defun org-slides--timed-macro-duration (entries)
  "Return the last recorded timestamp in ENTRIES."
  (if entries
      (car (car (last entries)))
    0.0))

(defun org-slides--timed-macro-resolve (macro)
  "Return the entries for timed macro MACRO.
MACRO may be a list of entries, `last', or the name of a variable
holding the entries."
  (cond
   ((org-slides--timed-macro-p macro) macro)
   ((or (stringp macro) (symbolp macro))
    (let* ((name (string-trim (if (symbolp macro)
                                  (symbol-name macro)
                                macro)))
           (symbol (intern name)))
      (cond
       ((string-equal (downcase name) "last")
        (or org-slides-timed-macro-last
            (user-error "No timed macro has been recorded")))
       ((and (boundp symbol)
             (org-slides--timed-macro-p (symbol-value symbol)))
        (symbol-value symbol))
       (t
        (user-error "No timed macro named %s" name)))))
   (t
    (user-error "Invalid timed macro: %S" macro))))

(defun org-slides--timed-macro-play-entries (entries &optional speed)
  "Play timed macro ENTRIES, scaling timestamps by SPEED.
Each entry's car is seconds since recording started.  Playback waits
until that time relative to its own start, so slow commands do not
shift the rest of the recording."
  (let ((speed (if (numberp speed) (max 0 speed) 1.0))
        (start (float-time)))
    (dolist (entry entries)
      (let ((wait (- (* speed (car entry))
                     (- (float-time) start))))
        (when (> wait 0)
          (sleep-for wait)))
      (execute-kbd-macro (cdr entry)))))

(defun org-slides--timed-macro-finish-playback ()
  "Finish and clean up the active timed macro playback."
  (when org-slides--timed-macro-playback
    (let* ((state org-slides--timed-macro-playback)
           (timer (plist-get state :timer))
           (demo (plist-get state :demo))
           (window (plist-get state :window))
           (presentation (plist-get state :presentation))
           (return (plist-get state :return-window))
           (original (plist-get state :original-buffer)))
      (when (timerp timer)
        (cancel-timer timer))
      (setq org-slides--timed-macro-playback nil)
      (when demo
        (dolist (target (list original
                              (and (window-live-p window)
                                   (window-buffer window))))
          (when (and (buffer-live-p target)
                     (not (eq target presentation)))
            (with-current-buffer target
              (setq-local org-slides--demo-presentation-buffer presentation)
              (org-slides-demo-mode 1)))))
      (when (and (window-live-p return)
                 (not (eq (selected-window) return)))
        (select-window return)))))

(defun org-slides--timed-macro-cancel-playback ()
  "Stop the active timed macro playback."
  (when org-slides--timed-macro-playback
    (org-slides--timed-macro-finish-playback)))

(defun org-slides--timed-macro-playback-step ()
  "Execute the next step of the active timed macro playback."
  (when org-slides--timed-macro-playback
    (let* ((state org-slides--timed-macro-playback)
           (entries (plist-get state :entries))
           (index (plist-get state :index))
           (start (plist-get state :start))
           (speed (plist-get state :speed))
           (window (plist-get state :window)))
      (cond
       ((>= index (length entries))
        (org-slides--timed-macro-finish-playback))
       ((not (window-live-p window))
        (org-slides--timed-macro-finish-playback))
       (t
        (let* ((entry (nth index entries))
               (wait (- (* speed (car entry))
                        (- (float-time) start))))
          (if (> wait 0)
              (plist-put state :timer
                         (run-at-time wait nil
                                      #'org-slides--timed-macro-playback-step))
            (plist-put state :index (1+ index))
            (condition-case err
                (progn
                  (select-window window)
                  (when (plist-get state :demo)
                    (with-current-buffer (window-buffer window)
                      (when org-slides-demo-mode
                        (org-slides-demo-mode -1))))
                  (execute-kbd-macro (cdr entry))
                  (redisplay t))
              ((error quit)
               (message "Org Slides: timed macro stopped: %s"
                        (if (eq (car err) 'quit)
                            "quit"
                          (error-message-string err)))
               (org-slides--timed-macro-finish-playback)))
            (when org-slides--timed-macro-playback
              (plist-put state :timer
                         (run-at-time 0 nil
                                      #'org-slides--timed-macro-playback-step))))))))))

(defun org-slides--timed-macro-start-playback (entries speed window
                                                       demo presentation)
  "Start asynchronous playback of ENTRIES in WINDOW.
SPEED scales the recorded timestamps.  DEMO non-nil means WINDOW is a
demo pane belonging to PRESENTATION."
  (org-slides--timed-macro-cancel-playback)
  (unless (window-live-p window)
    (user-error "The target window is not live"))
  (setq org-slides--timed-macro-playback
        (list :entries entries
              :index 0
              :start (float-time)
              :speed (if (numberp speed) (max 0 speed) 1.0)
              :window window
              :demo demo
              :presentation presentation
              :return-window (selected-window)
              :original-buffer (window-buffer window)
              :timer nil))
  (if (null entries)
      (org-slides--timed-macro-finish-playback)
    (when demo
      (with-current-buffer (window-buffer window)
        (when org-slides-demo-mode
          (org-slides-demo-mode -1))))
    (plist-put org-slides--timed-macro-playback :timer
               (run-at-time 0 nil
                            #'org-slides--timed-macro-playback-step))))

(defun org-slides--timed-macro-record ()
  "Record the command that is about to run into the timed macro."
  (when (and org-slides--timed-macro-recording
             (not org-slides--timed-macro-playback))
    (cond
     ((eq this-command #'keyboard-quit)
      (org-slides--timed-macro-cancel))
     ((memq this-command '(org-slides-timed-macro-stop
                           org-slides-timed-macro-toggle))
      nil)
     (t
      (let ((keys (this-command-keys)))
        (when (and (or (stringp keys) (vectorp keys))
                   (> (length keys) 0))
          (let ((now (float-time)))
            (push (cons (max 0 (- now org-slides--timed-macro-start-time))
                        keys)
                  org-slides--timed-macro-entries))))))))

(defun org-slides--timed-macro-cancel ()
  "Cancel the current timed macro recording."
  (remove-hook 'pre-command-hook #'org-slides--timed-macro-record)
  (setq org-slides--timed-macro-recording nil
        org-slides--timed-macro-entries nil
        org-slides--timed-macro-start-time nil)
  (message "Timed macro recording cancelled"))

;;;###autoload
(defun org-slides-timed-macro-start ()
  "Start recording a timed keyboard macro.
The elapsed time before each command is stored with the keys, including
commands that use the minibuffer.  Keys consumed inside a single
command's own loop, such as `isearch' or `query-replace', are not
captured by this command-level recorder."
  (interactive)
  (when org-slides--timed-macro-recording
    (user-error "Already recording a timed macro"))
  (remove-hook 'pre-command-hook #'org-slides--timed-macro-record)
  (setq org-slides--timed-macro-recording t
        org-slides--timed-macro-entries nil
        org-slides--timed-macro-start-time (float-time))
  (add-hook 'pre-command-hook #'org-slides--timed-macro-record)
  (message "Timed macro recording..."))

;;;###autoload
(defun org-slides-timed-macro-cancel ()
  "Cancel the current timed macro recording and discard it."
  (interactive)
  (if org-slides--timed-macro-recording
      (org-slides--timed-macro-cancel)
    (user-error "No timed macro recording in progress")))

(defun org-slides--timed-macro-finish ()
  "Finish recording the current timed macro and return it."
  (remove-hook 'pre-command-hook #'org-slides--timed-macro-record)
  (setq org-slides--timed-macro-recording nil)
  (setq org-slides-timed-macro-last
        (nreverse org-slides--timed-macro-entries))
  (setq org-slides--timed-macro-entries nil
        org-slides--timed-macro-start-time nil)
  org-slides-timed-macro-last)

;;;###autoload
(defun org-slides-timed-macro-stop ()
  "Stop recording a timed keyboard macro and keep it.
For a clean recording, invoke this from a key binding rather than
`M-x'; otherwise the `M-x' input becomes part of the macro."
  (interactive)
  (unless org-slides--timed-macro-recording
    (user-error "No timed macro recording in progress"))
  (let ((macro (org-slides--timed-macro-finish)))
    (message "Timed macro recorded: %d steps, %.2fs"
             (length macro)
             (org-slides--timed-macro-duration macro))
    macro))

;;;###autoload
(defun org-slides-timed-macro-toggle ()
  "Start or stop recording a timed keyboard macro."
  (interactive)
  (if org-slides--timed-macro-recording
      (org-slides-timed-macro-stop)
    (org-slides-timed-macro-start)))

;;;###autoload
(defun org-slides-timed-macro-save (name)
  "Store the last timed macro as the variable NAME.
After this, `timed-macro:NAME' can play it.  Use
`org-slides-timed-macro-insert' to put a persistent form in a file."
  (interactive (list (intern (read-string "Timed macro name: "))))
  (when (string-empty-p (symbol-name name))
    (user-error "A timed macro name is required"))
  (unless org-slides-timed-macro-last
    (user-error "No timed macro has been recorded"))
  (set name org-slides-timed-macro-last)
  (message "Timed macro saved as %s" name))

;;;###autoload
(defun org-slides-timed-macro-insert (name)
  "Insert a `setq' form for the timed macro stored in NAME."
  (interactive (list (intern (read-string "Timed macro name: "))))
  (unless (and (boundp name)
               (org-slides--timed-macro-p (symbol-value name)))
    (user-error "No timed macro named %s" name))
  (insert (format "(setq %s '%s)\n"
                  name
                  (pp-to-string (symbol-value name)))))

;;;###autoload
(defun org-slides-timed-macro-play (name &optional speed)
  "Play timed macro NAME with optional SPEED multiplier.
NAME is `last' or the name of a variable holding a timed macro.
A prefix argument prompts for the speed."
  (interactive
   (list (read-string "Timed macro: "
                      (if org-slides-timed-macro-last "last" "")
                      'org-slides-timed-macro-history)
         (if current-prefix-arg
             (read-number "Speed: " org-slides-timed-macro-speed)
           org-slides-timed-macro-speed)))
  (let ((entries (org-slides--timed-macro-resolve name)))
    (org-slides--timed-macro-start-playback
     entries speed (selected-window) nil nil)))

;;;###autoload
(defun org-slides-timed-macro-stop-playback ()
  "Stop the timed macro that is currently playing."
  (interactive)
  (if org-slides--timed-macro-playback
      (org-slides--timed-macro-cancel-playback)
    (user-error "No timed macro is playing")))

(defun org-slides--demo-play-timed-macro (macro &optional buffer)
  "Play timed macro MACRO in the demo pane."
  (let ((entries (org-slides--timed-macro-resolve macro))
        (window (org-slides--demo-window)))
    (unless (window-live-p window)
      (user-error "No demo pane is visible"))
    (when (and (buffer-live-p buffer)
               (not (eq (window-buffer window) buffer)))
      (set-window-buffer window buffer))
    (org-slides--timed-macro-start-playback
     entries org-slides-timed-macro-speed window t
     (org-slides--demo-presentation))))

(defun org-slides--demo-run-scheduled-macro (presentation macro buffer kind)
  "Run MACRO in BUFFER if PRESENTATION still has a demo pane.
KIND is `timed-macro' for a timed macro, or nil for a normal one."
  (when (and (buffer-live-p presentation)
             (buffer-local-value 'org-slides--started presentation)
             (org-slides--demo-window presentation))
    (with-current-buffer presentation
      (setq org-slides--demo-macro-timer nil)
      (condition-case err
          (if (eq kind 'timed-macro)
              (org-slides--demo-play-timed-macro macro buffer)
            (org-slides--demo-play-macro macro buffer))
        (error
         (message "Org Slides: demo macro failed: %s"
                  (error-message-string err)))))))

(defun org-slides--demo-schedule-macro (macro &optional buffer kind)
  "Play MACRO in the demo pane after `org-slides-demo-macro-delay'.
KIND is `timed-macro' for a timed macro, or nil for a normal one."
  (org-slides--demo-cancel-macro)
  (let ((delay (or org-slides-demo-macro-delay 0)))
    (if (and (numberp delay) (> delay 0))
        (setq org-slides--demo-macro-timer
              (run-at-time delay nil
                           #'org-slides--demo-run-scheduled-macro
                           (current-buffer) macro buffer kind))
      (org-slides--demo-run-scheduled-macro
       (current-buffer) macro buffer kind))))

(defun org-slides--demo-hide ()
  "Hide the demo side window, if any."
  (org-slides--demo-cancel-macro)
  (let ((window (org-slides--demo-window)))
    (when window
      (let ((buffer (window-buffer window)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when org-slides-demo-mode
              (org-slides-demo-mode -1))
            (setq org-slides--demo-presentation-buffer nil))))
      (ignore-errors (delete-window window))
      (setq org-slides--demo-window nil
            org-slides--demo-buffer nil))))

(defun org-slides--demo-show (spec)
  "Show demo SPEC in the side window, or hide the pane for `none'."
  (unless org-slides-demo-pane
    (user-error "The org-slides demo pane is disabled"))
  (unless (and (stringp spec)
               (not (string-empty-p (string-trim spec))))
    (user-error "A demo spec is required"))
  (let* ((spec (string-trim spec))
         (parsed (org-slides--demo-parse-spec spec))
         (kind (car parsed))
         (value (cdr parsed))
         (buffer (org-slides--demo-resolve spec)))
    (when (and (memq kind '(macro timed-macro)) (string-empty-p value))
      (user-error "A macro name is required"))
    (setq org-slides--demo-spec spec)
    (if (buffer-live-p buffer)
        (progn
          (org-slides--demo-display buffer)
          (when (memq kind '(macro timed-macro))
            (org-slides--demo-schedule-macro value buffer kind)))
      (org-slides--demo-hide))))

(defun org-slides--demo-show-from-anywhere (spec)
  "Show SPEC in the active presentation's demo pane."
  (let ((presentation (or (org-slides--demo-presentation)
                          (user-error "No active org-slides presentation"))))
    (with-current-buffer presentation
      (org-slides--demo-show spec))))

(defun org-slides--demo-default-spec ()
  "Return the spec to use when the demo is toggled on."
  (let ((presentation (org-slides--demo-presentation)))
    (and presentation
         (with-current-buffer presentation
           (or (and (stringp org-slides--demo-spec)
                    (not (org-slides--demo-none-spec-p org-slides--demo-spec))
                    org-slides--demo-spec)
               (org-slides--demo-spec-for-slide))))))

(defun org-slides--demo-slide-region ()
  "Return (START . END) of the current slide."
  (cond
   ((and (markerp org-slides--logical-start)
         (marker-position org-slides--logical-start)
         (markerp org-slides--logical-end)
         (marker-position org-slides--logical-end))
    (cons (marker-position org-slides--logical-start)
          (marker-position org-slides--logical-end)))
   ((org-current-level)
    (save-excursion
      (org-slides-top)
      (cons (point) (org-end-of-subtree t t))))
   (t
    (save-excursion
      (goto-char (point-min))
      (cons (point-min)
            (if (outline-next-heading) (point) (point-max)))))))

(defun org-slides--slide-keyword (key start end)
  "Return the first #+KEY value between START and END, or nil.
Literal #+KEY lines inside blocks are ignored."
  (save-excursion
    (save-restriction
      (widen)
      (narrow-to-region start end)
      (goto-char (point-min))
      (let ((case-fold-search t)
            (regexp (concat "^[ \t]*#\\+"
                            (regexp-quote key)
                            ":[ \t]*\\(.*\\)$"))
            found)
        (while (and (not found)
                    (re-search-forward regexp (point-max) t))
          (let ((value (match-string 1))
                (element (save-match-data
                           (save-excursion
                             (goto-char (match-beginning 0))
                             (org-element-at-point)))))
            (when (and (eq (org-element-type element) 'keyword)
                       (string= (upcase key)
                                (upcase (or (org-element-property :key element)
                                            ""))))
              (setq found (string-trim value)))))
        (and found (not (string-empty-p found)) found)))))

(defun org-slides--demo-keyword-spec (start end)
  "Return the first `#+DEMO:' spec between START and END, or nil."
  (org-slides--slide-keyword "DEMO" start end))

(defun org-slides--demo-spec-for-slide ()
  "Return the demo spec for the current slide, or nil."
  (let* ((property (and (org-current-level)
                        (org-entry-get nil "DEMO")))
         (property (and property (string-trim property)))
         (region (org-slides--demo-slide-region))
         (keyword (and region
                       (org-slides--demo-keyword-spec
                        (car region) (cdr region))))
         (spec (or (and property (not (string-empty-p property)) property)
                   keyword
                   org-slides-demo-default)))
    (and spec
         (not (string-empty-p (string-trim spec)))
         (string-trim spec))))

(defun org-slides--demo-macro-for-slide ()
  "Return the `DEMO-MACRO' setting for the current slide, or nil.
A `DEMO-MACRO' property wins over a `#+DEMO-MACRO:' keyword."
  (let* ((property (and (org-current-level)
                        (org-entry-get nil "DEMO-MACRO")))
         (property (and property (string-trim property)))
         (region (org-slides--demo-slide-region))
         (keyword (and region
                       (org-slides--slide-keyword
                        "DEMO-MACRO" (car region) (cdr region)))))
    (or (and property (not (string-empty-p property)) property)
        keyword)))

(defun org-slides--demo-timed-macro-for-slide ()
  "Return the `DEMO-TIMED-MACRO' setting for the current slide, or nil.
A `DEMO-TIMED-MACRO' property wins over a `#+DEMO-TIMED-MACRO:' keyword."
  (let* ((property (and (org-current-level)
                        (org-entry-get nil "DEMO-TIMED-MACRO")))
         (property (and property (string-trim property)))
         (region (org-slides--demo-slide-region))
         (keyword (and region
                       (org-slides--slide-keyword
                        "DEMO-TIMED-MACRO" (car region) (cdr region)))))
    (or (and property (not (string-empty-p property)) property)
        keyword)))

(defun org-slides--demo-schedule-macros (macro timed)
  "Schedule the current slide's normal MACRO and TIMED macro."
  (when (org-slides--demo-window)
    (when macro
      (org-slides--demo-schedule-macro macro nil nil))
    (when timed
      (org-slides--demo-schedule-macro timed nil 'timed-macro))))

(defun org-slides--update-demo ()
  "Show, hide, or switch the demo pane for the current slide.
Also play the slide's `DEMO-MACRO' or `DEMO-TIMED-MACRO' after the
demo buffer is ready."
  (when (and org-slides-demo-pane org-slides--started)
    (org-slides--demo-cancel-macro)
    (let ((spec (org-slides--demo-spec-for-slide))
          (macro (org-slides--demo-macro-for-slide))
          (timed (org-slides--demo-timed-macro-for-slide)))
      (setq org-slides--demo-macro macro
            org-slides--demo-timed-macro timed)
      (cond
       ((null spec)
        (if org-slides-demo-keep
            (org-slides--demo-schedule-macros macro timed)
          (org-slides--demo-hide)
          (setq org-slides--demo-spec nil)))
       ((org-slides--demo-none-spec-p spec)
        (org-slides--demo-hide)
        (setq org-slides--demo-spec 'none))
       ((not (equal spec org-slides--demo-spec))
        (org-slides--demo-show spec)
        (org-slides--demo-schedule-macros macro timed))
       (t
        (org-slides--demo-schedule-macros macro timed))))))

(defun org-slides--demo-reset ()
  "Close the demo pane and discard resources created for it."
  (org-slides--demo-hide)
  (dolist (process org-slides--demo-processes)
    (when (and (processp process) (process-live-p process))
      (ignore-errors (delete-process process))))
  (when org-slides-demo-kill-buffers
    (dolist (buffer org-slides--demo-created-buffers)
      (when (buffer-live-p buffer)
        (let ((process (get-buffer-process buffer)))
          (when (and (processp process) (process-live-p process))
            (ignore-errors (delete-process process))))
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (ignore-errors (kill-buffer buffer)))))
  (dolist (file org-slides--demo-temp-files)
    (when (file-exists-p file)
      (ignore-errors (delete-file file))))
  (setq org-slides--demo-processes nil
        org-slides--demo-created-buffers nil
        org-slides--demo-temp-files nil
        org-slides--demo-window nil
        org-slides--demo-buffer nil
        org-slides--demo-spec nil
        org-slides--demo-macro nil
        org-slides--demo-timed-macro nil
        org-slides--demo-macro-timer nil))

;;;###autoload
(defun org-slides-demo-show (spec)
  "Show demo SPEC in a side window beside the presentation.
SPEC is one of:

  buffer:NAME     show an existing Emacs buffer
  file:PATH       visit a file (video files are played)
  url:URL         open a page in xwidget-webkit or EWW
  video:PATH-URL  play a video in xwidget-webkit or externally
  command:CMD     run a shell command and show its output
  shell:NAME      start or reuse an interactive shell (NAME optional)
  macro:NAME      play keyboard macro NAME in the demo pane
  timed-macro:NAME play a timed keyboard macro in the demo pane
  elisp:FORM      evaluate FORM; it must yield a buffer or spec
  external:PATH   open a file or URL outside Emacs
  none            hide the demo pane

A bare path is treated as `file:' and a bare URL as `url:'.  MACRO is
a named keyboard macro or `register:CHAR'.  A slide's `DEMO-MACRO' or
`DEMO-TIMED-MACRO' setting plays a macro after its `DEMO' buffer is
shown.  When called interactively, the current slide's spec is offered
as the default."
  (interactive
   (list (read-string "Demo spec: "
                      (org-slides--demo-default-spec)
                      'org-slides-demo-history)))
  (org-slides--demo-show-from-anywhere spec))

;;;###autoload
(defun org-slides-demo-hide ()
  "Hide the demo pane without discarding its spec."
  (interactive)
  (let ((presentation (org-slides--demo-presentation)))
    (when presentation
      (with-current-buffer presentation
        (org-slides--demo-hide)))))

;;;###autoload
(defun org-slides-demo-toggle ()
  "Show or hide the demo pane for the current slide."
  (interactive)
  (let ((presentation (or (org-slides--demo-presentation)
                          (user-error "No active org-slides presentation"))))
    (with-current-buffer presentation
      (if (org-slides--demo-window)
          (org-slides--demo-hide)
        (let ((spec (org-slides--demo-default-spec)))
          (if (and spec (not (org-slides--demo-none-spec-p spec)))
              (org-slides--demo-show spec)
            (call-interactively #'org-slides-demo-show)))))))

(defun org-slides--demo-macro-default ()
  "Return the default macro name for `org-slides-demo-play-macro'."
  (or org-slides--demo-macro
      (let ((parsed (ignore-errors
                      (org-slides--demo-parse-spec org-slides--demo-spec))))
        (and (eq (car parsed) 'macro) (cdr parsed)))
      (and (boundp 'last-kbd-macro)
           (symbolp last-kbd-macro)
           (kmacro-keyboard-macro-p last-kbd-macro)
           (symbol-name last-kbd-macro))))

;;;###autoload
(defun org-slides-demo-play-macro (macro)
  "Play keyboard macro MACRO in the demo pane.
MACRO is a named keyboard macro or `register:CHAR'.  When called
interactively, the current slide's `DEMO-MACRO' or `macro:' spec is
offered as the default.  If the pane is hidden, the slide's demo is
shown first, or a scratch buffer is used when the slide has none."
  (interactive
   (list (read-string "Demo macro: "
                      (org-slides--demo-macro-default)
                      'org-slides-demo-macro-history)))
  (let ((macro (string-trim (if (symbolp macro)
                                (symbol-name macro)
                              macro))))
    (when (string-empty-p macro)
      (user-error "A macro name is required"))
    (let ((presentation (or (org-slides--demo-presentation)
                            (user-error "No active org-slides presentation"))))
      (with-current-buffer presentation
        (setq org-slides--demo-macro macro)
        (org-slides--demo-cancel-macro)
        (if (org-slides--demo-window)
            (org-slides--demo-play-macro macro)
          (let ((spec (or (and (stringp org-slides--demo-spec)
                               (not (org-slides--demo-none-spec-p
                                     org-slides--demo-spec))
                               org-slides--demo-spec)
                          (org-slides--demo-spec-for-slide))))
            (if (and spec (not (org-slides--demo-none-spec-p spec)))
                (progn
                  (org-slides--demo-show spec)
                  (org-slides--demo-cancel-macro)
                  (if (org-slides--demo-window)
                      (org-slides--demo-play-macro macro)
                    (org-slides--demo-show (concat "macro:" macro))))
              (org-slides--demo-show (concat "macro:" macro)))))))))

(defun org-slides--demo-timed-macro-default ()
  "Return the default timed macro name for replay."
  (or org-slides--demo-timed-macro
      (let ((parsed (ignore-errors
                      (org-slides--demo-parse-spec org-slides--demo-spec))))
        (and (eq (car parsed) 'timed-macro) (cdr parsed)))
      (and org-slides-timed-macro-last "last")))

;;;###autoload
(defun org-slides-demo-play-timed-macro (macro)
  "Play timed macro MACRO in the demo pane.
When called interactively, the current slide's timed macro is offered
as the default.  If the pane is hidden, the slide's demo is shown first."
  (interactive
   (list (read-string "Timed demo macro: "
                      (org-slides--demo-timed-macro-default)
                      'org-slides-timed-macro-history)))
  (let ((macro (string-trim (if (symbolp macro)
                                (symbol-name macro)
                              macro))))
    (when (string-empty-p macro)
      (user-error "A timed macro name is required"))
    (let ((presentation (or (org-slides--demo-presentation)
                            (user-error "No active org-slides presentation"))))
      (with-current-buffer presentation
        (setq org-slides--demo-timed-macro macro)
        (org-slides--demo-cancel-macro)
        (if (org-slides--demo-window)
            (org-slides--demo-play-timed-macro macro)
          (let ((spec (or (and (stringp org-slides--demo-spec)
                               (not (org-slides--demo-none-spec-p
                                     org-slides--demo-spec))
                               org-slides--demo-spec)
                          (org-slides--demo-spec-for-slide))))
            (if (and spec (not (org-slides--demo-none-spec-p spec)))
                (progn
                  (org-slides--demo-show spec)
                  (org-slides--demo-cancel-macro)
                  (if (org-slides--demo-window)
                      (org-slides--demo-play-timed-macro macro)
                    (org-slides--demo-show (concat "timed-macro:" macro))))
              (org-slides--demo-show (concat "timed-macro:" macro)))))))))

;;;###autoload
(defun org-slides-demo-select ()
  "Select the demo window, or return to the presentation from it."
  (interactive)
  (let* ((presentation (or (org-slides--demo-presentation)
                           (user-error "No active org-slides presentation")))
         (presentation-window (get-buffer-window presentation t))
         (demo (org-slides--demo-window presentation)))
    (cond
     ((null demo)
      (user-error "No demo pane is visible"))
     ((eq (selected-window) demo)
      (if (window-live-p presentation-window)
          (select-window presentation-window)
        (user-error "The presentation buffer is not displayed")))
     (t
      (select-window demo)))))

(defun org-slides--demo-call-in-presentation (function)
  "Call FUNCTION with the presentation window selected.
Return to the demo window when the caller started there and it still
exists."
  (let* ((presentation (or (org-slides--demo-presentation)
                           (user-error "No active org-slides presentation")))
         (window (get-buffer-window presentation t))
         (selected (selected-window))
         (started-in-demo (eq selected
                              (org-slides--demo-window presentation))))
    (unless (window-live-p window)
      (user-error "The presentation buffer is not displayed"))
    (save-selected-window
      (select-window window)
      (with-current-buffer presentation
        (funcall function)))
    (when started-in-demo
      (let ((new-demo (org-slides--demo-window presentation)))
        (cond
         ((window-live-p new-demo)
          (select-window new-demo))
         ((window-live-p selected)
          (select-window selected)))))))

;;;###autoload
(defun org-slides-demo-next ()
  "Advance the presentation while keeping focus in the demo window."
  (interactive)
  (org-slides--demo-call-in-presentation #'org-slides-next))

;;;###autoload
(defun org-slides-demo-prev ()
  "Go back in the presentation while keeping focus in the demo window."
  (interactive)
  (org-slides--demo-call-in-presentation #'org-slides-prev))

;;;###autoload
(defun org-slides-demo-quit ()
  "Quit the presentation from the demo window."
  (interactive)
  (let* ((presentation (or (org-slides--demo-presentation)
                           (user-error "No active org-slides presentation")))
         (window (get-buffer-window presentation t)))
    (when (window-live-p window)
      (select-window window))
    (with-current-buffer presentation
      (org-slides-quit))))

(defun org-slides-demo-toggle-or-self-insert (&optional arg)
  "Show or hide the demo pane, or insert the typed character.
See `org-slides-next-or-self-insert' for ARG."
  (interactive "p")
  (if buffer-read-only
      (org-slides-demo-toggle)
    (self-insert-command (or arg 1))))

(defun org-slides-demo-play-macro-or-self-insert (&optional arg)
  "Replay the current demo macro, or insert the typed character.
Prompt for a macro when the slide has no default.  See
`org-slides-next-or-self-insert' for ARG."
  (interactive "p")
  (if buffer-read-only
      (let ((macro (org-slides--demo-macro-default)))
        (if macro
            (org-slides-demo-play-macro macro)
          (call-interactively #'org-slides-demo-play-macro)))
    (self-insert-command (or arg 1))))

(defun org-slides-step-forward ()
  "Reveal the next list item, then advance a page or slide."
  (interactive)
  (unless (org-slides--reveal-next-bullet)
    (org-slides-next)))

(defun org-slides-step-backward ()
  "Shadow the previous list item, then go back a page or slide."
  (interactive)
  (unless (org-slides--hide-previous-bullet)
    (org-slides-prev)))

(defun org-slides-step-forward-or-self-insert (&optional arg)
  "Reveal the next list item, or insert the typed character.
With prefix ARG, insert that many characters when the buffer is
writable.  See `org-slides-next-or-self-insert' for the read-only
behavior."
  (interactive "p")
  (if buffer-read-only
      (org-slides-step-forward)
    (self-insert-command (or arg 1))))

(defun org-slides-step-backward-or-self-insert (&optional arg)
  "Shadow the previous list item, or insert the typed character.
See `org-slides-next-or-self-insert' for ARG."
  (interactive "p")
  (if buffer-read-only
      (org-slides-step-backward)
    (self-insert-command (or arg 1))))

(defun org-slides-step-backward-or-shifttab (&optional arg)
  "Shadow the previous list item, or run `org-shifttab' with ARG.
The latter applies when the buffer is writable."
  (interactive "p")
  (if buffer-read-only
      (org-slides-step-backward)
    (org-shifttab (or arg 1))))

(defun org-slides-step-backward-or-delete (&optional arg)
  "Shadow the previous list item, or delete ARG characters backward.
The latter applies when the buffer is writable."
  (interactive "p")
  (if buffer-read-only
      (org-slides-step-backward)
    (delete-char (- (or arg 1)))))

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
