;;; org-slides-test.el --- Tests for org-slides -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -L . -l test/org-slides-test.el

;;; Code:

(require 'ert)
(require 'org)
(require 'org-slides)

(defconst org-slides-test--document
  "#+TITLE: Demo

* One

Text one.

* Two

Text two.
")

(defun org-slides-test--overlay-covering (position)
  "Return the org-slides invisible overlay covering POSITION, or nil."
  (seq-find (lambda (overlay)
              (and (eq (overlay-get overlay 'invisible) 'org-slides)
                   (<= (overlay-start overlay) position)
                   (< position (overlay-end overlay))))
            (overlays-in (point-min) (point-max))))

(ert-deftest org-slides-test-auto-page-default ()
  "Automatic pagination is enabled by default."
  (should org-slides-auto-page))

(ert-deftest org-slides-test-page-markers ()
  "Page state is reset and cleared cleanly."
  (with-temp-buffer
    (insert "Some text")
    (org-slides--reset-pages)
    (should (= org-slides--page-index 0))
    (should (= (length org-slides--page-starts) 1))
    (should (markerp (car org-slides--page-starts)))
    (org-slides--clear-page-markers)
    (should-not org-slides--page-starts)
    (should (= org-slides--page-index 0))))

(ert-deftest org-slides-test-default-keybindings ()
  "The navigation keys are bound by default."
  (should (eq (lookup-key org-slides-mode-map (kbd "n"))
              #'org-slides-next-or-self-insert))
  (should (eq (lookup-key org-slides-mode-map (kbd "SPC"))
              #'org-slides-next-or-self-insert))
  (should (eq (lookup-key org-slides-mode-map (kbd "p"))
              #'org-slides-prev-or-self-insert))
  (should (eq (lookup-key org-slides-mode-map (kbd "S-SPC"))
              #'org-slides-prev-or-self-insert))
  (should (eq (lookup-key org-slides-mode-map (kbd "q"))
              #'org-slides-quit-or-self-insert)))

(ert-deftest org-slides-test-overlays ()
  "Full #+ lines include their newline, block content stays visible."
  (with-temp-buffer
    (org-mode)
    (insert "#+TITLE: Demo\n\n* Slide\n\n"
            "#+begin_src shell\n"
            "#+ this is literal content\n"
            "echo hi\n"
            "#+end_src\n")
    (goto-char (point-min))
    (org-slides--add-overlays)
    (unwind-protect
        (progn
          ;; The title overlay hides only "#+TITLE:" so the value remains.
          (let ((overlay (org-slides-test--overlay-covering (point-min))))
            (should overlay)
            (should (equal (buffer-substring-no-properties
                            (overlay-start overlay) (overlay-end overlay))
                           "#+TITLE:")))
          ;; A hidden delimiter line includes its newline.
          (goto-char (point-min))
          (search-forward "#+begin_src")
          (let ((overlay (org-slides-test--overlay-covering
                          (line-beginning-position))))
            (should overlay)
            (should (eq (char-before (overlay-end overlay)) ?\n)))
          ;; Literal #+ content inside the block is not hidden.
          (goto-char (point-min))
          (search-forward "#+ this is literal content")
          (should-not (org-slides-test--overlay-covering
                       (line-beginning-position))))
      (org-slides--rm-overlays))))

(ert-deftest org-slides-test-navigation-and-title ()
  "Starting, moving forward/back, and quitting restore the buffer."
  (with-temp-buffer
    (org-mode)
    (insert org-slides-test--document)
    (goto-char (point-min))
    (org-slides-start)
    (unwind-protect
        (progn
          (should org-slides-mode)
          (should buffer-read-only)
          (should (buffer-narrowed-p))
          (should-not (save-excursion
                        (goto-char (point-min))
                        (search-forward "* One" nil t)))
          (org-slides-next)
          (should (equal (org-slides-test--current-heading) "One"))
          (org-slides-next)
          (should (equal (org-slides-test--current-heading) "Two"))
          (org-slides-prev)
          (should (equal (org-slides-test--current-heading) "One"))
          ;; Going back from the first slide reaches the title slide.
          (org-slides-prev)
          (should-not (save-excursion
                        (goto-char (point-min))
                        (search-forward "* One" nil t))))
      (org-slides-quit))
    (should-not org-slides-mode)
    (should-not buffer-read-only)
    (should-not (buffer-narrowed-p))))

(defun org-slides-test--current-heading ()
  "Return the text of the current heading, or nil on the title slide."
  (save-excursion
    (when (org-current-level)
      (org-slides-top)
      (string-trim (replace-regexp-in-string "^\\*+[ \t]*" ""
                                             (thing-at-point 'line))))))

(ert-deftest org-slides-test-one-big-page ()
  "The one-page view is not undone by navigation."
  (with-temp-buffer
    (org-mode)
    (insert org-slides-test--document)
    (goto-char (point-min))
    (org-slides-start)
    (unwind-protect
        (progn
          (org-slides-toggle-one-big-page)
          (should-not (buffer-narrowed-p))
          (org-slides-next)
          (should-not (buffer-narrowed-p))
          (should (equal (org-slides-test--current-heading) "One"))
          (org-slides-next)
          (should (equal (org-slides-test--current-heading) "Two"))
          (org-slides-toggle-one-big-page)
          (should (buffer-narrowed-p)))
      (org-slides-quit))))

(ert-deftest org-slides-test-scale-restore ()
  "The text scale in use before the presentation is restored."
  (with-temp-buffer
    (org-mode)
    (insert org-slides-test--document)
    (text-scale-set 2)
    (should (= text-scale-mode-amount 2))
    (goto-char (point-min))
    (org-slides-start)
    (unwind-protect
        (should (= text-scale-mode-amount org-slides-text-scale))
      (org-slides-quit))
    (should (= text-scale-mode-amount 2))))

(ert-deftest org-slides-test-read-only-and-cursor ()
  "The original read-only and cursor state is restored."
  (with-temp-buffer
    (org-mode)
    (insert org-slides-test--document)
    (setq-local cursor-type 'bar)
    (goto-char (point-min))
    (org-slides-start)
    (unwind-protect
        (progn
          (should buffer-read-only)
          (should-not cursor-type)
          (should (eq org-slides--cursor-cache 'bar)))
      (org-slides-quit))
    (should-not buffer-read-only)
    (should (eq cursor-type 'bar))))

(ert-deftest org-slides-test-buffer-local-overlays ()
  "Removing overlays in one buffer does not affect another buffer."
  (let ((one (generate-new-buffer " *org-slides-one*"))
        (two (generate-new-buffer " *org-slides-two*")))
    (unwind-protect
        (progn
          (dolist (buffer (list one two))
            (with-current-buffer buffer
              (org-mode)
              (insert "#+begin_src emacs-lisp\n(message \"hi\")\n#+end_src\n")
              (org-slides--add-overlays)))
          (should (> (with-current-buffer one (length org-slides--overlays)) 0))
          (should (> (with-current-buffer two (length org-slides--overlays)) 0))
          (with-current-buffer one (org-slides--rm-overlays))
          (should (= (with-current-buffer one (length org-slides--overlays)) 0))
          (should (> (with-current-buffer two (length org-slides--overlays)) 0)))
      (kill-buffer one)
      (kill-buffer two))))

(ert-deftest org-slides-test-after-navigate-hook ()
  "The after-navigate hook receives the buffer and heading."
  (let (seen)
    (with-temp-buffer
      (org-mode)
      (insert org-slides-test--document)
      (let ((org-slides-after-navigate-functions
             (list (lambda (buffer heading)
                     (push (cons buffer heading) seen)))))
        (goto-char (point-min))
        (org-slides-start)
        (org-slides-next)
        (unwind-protect
            (should (equal (cdr (car seen)) "One"))
          (org-slides-quit))))
    (should seen)))

(provide 'org-slides-test)
;;; org-slides-test.el ends here
