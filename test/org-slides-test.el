;;; org-slides-test.el --- Tests for org-slides -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -L . -l test/org-slides-test.el

;;; Code:

(require 'ert)
(require 'org)
(require 'kmacro)
(require 'org-slides)

(defconst org-slides-test--document
  "#+TITLE: Demo

* One

Text one.

* Two

Text two.
")

(defun org-slides-test--shadow-count ()
  "Return the number of active list-item shadow overlays."
  (let ((count 0))
    (dotimes (i (length org-slides--bullet-overlays) count)
      (when (overlayp (aref org-slides--bullet-overlays i))
        (setq count (1+ count))))))

(defun org-slides-test--wait-for-timed-playback ()
  "Wait for asynchronous timed macro playback to finish."
  (let ((deadline (+ (float-time) 5)))
    (while (and org-slides--timed-macro-playback
                (< (float-time) deadline))
      (sit-for 0.01))))

(defun org-slides-test--overlay-covering (position)
  "Return the org-slides invisible overlay covering POSITION, or nil."
  (seq-find (lambda (overlay)
              (and (eq (overlay-get overlay 'invisible) 'org-slides)
                   (<= (overlay-start overlay) position)
                   (< position (overlay-end overlay))))
            (overlays-in (point-min) (point-max))))

(ert-deftest org-slides-test-auto-page-default ()
  "Automatic pagination and the slide.page indicator are on by default."
  (should org-slides-auto-page)
  (should (eq org-slides-page-indicator 'always)))

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

(ert-deftest org-slides-test-split-pages ()
  "Split-page mode narrows to individual pages and updates the indicator."
  (let ((org-slides-page-style 'split))
    (with-temp-buffer
      (org-mode)
      (insert "* Long Slide\n\n")
      (dotimes (i 200)
        (insert (format "Line %03d: some text for the page splitter.\n" i)))
      (goto-char (point-min))
      (org-slides-start)
      (unwind-protect
          (progn
            (should (> (length org-slides--split-pages) 1))
            (should (buffer-narrowed-p))
            (should (= org-slides--page-index 0))
            (should (string-match-p "1\\.1"
                                    (format "%S" mode-line-process)))
            (org-slides-next)
            (should (= org-slides--page-index 1))
            (should (string-match-p "1\\.2"
                                    (format "%S" mode-line-process)))
            (org-slides-prev)
            (should (= org-slides--page-index 0)))
        (org-slides-quit)))))

(ert-deftest org-slides-test-single-page-indicator ()
  "The slide number is shown even when a slide has only one page."
  (let ((org-slides-page-style 'split))
    (with-temp-buffer
      (org-mode)
      (insert "* One\n\nShort one.\n\n* Two\n\nShort two.\n")
      (goto-char (point-min))
      (org-slides-start)
      (unwind-protect
          (progn
            (should (= org-slides--slide-number 1))
            (should (string-match-p "1\\.1 / 2\\.1"
                                    (format "%S" mode-line-process)))
            (org-slides-next)
            (should (= org-slides--slide-number 2))
            (should (string-match-p "2\\.1 / 2\\.1"
                                    (format "%S" mode-line-process))))
        (org-slides-quit)))))

(ert-deftest org-slides-test-slide-page-number ()
  "The indicator uses <slide>.<page>, with the title slide as 0."
  (let ((org-slides-page-style 'split)
        (org-slides-page-indicator 'always))
    (with-temp-buffer
      (org-mode)
      (insert "#+TITLE: Title\n\n* First Slide\n\n")
      (dotimes (i 200)
        (insert (format "Line %03d: text for the page splitter.\n" i)))
      (insert "\n* Second Slide\n\nShort.\n")
      (goto-char (point-min))
      (org-slides-start)
      (unwind-protect
          (progn
            (should (= org-slides--slide-number 0))
            (should (string-match-p "0\\.1 / 2\\.1"
                                    (format "%S" mode-line-process)))
            (org-slides-next)
            (should (= org-slides--slide-number 1))
            (should (string-match-p
                     (format "1\\.1 / 2\\.%d"
                             (length org-slides--split-pages))
                     (format "%S" mode-line-process)))
            (org-slides-next)
            (should (string-match-p
                     (format "1\\.2 / 2\\.%d"
                             (length org-slides--split-pages))
                     (format "%S" mode-line-process)))
            (dotimes (_ 50)
              (unless (= org-slides--slide-number 2)
                (org-slides-next)))
            (should (= org-slides--slide-number 2))
            (should (string-match-p "2\\.1 / 2\\.1"
                                    (format "%S" mode-line-process))))
        (org-slides-quit)))))

(ert-deftest org-slides-test-end-of-presentation ()
  "N on the last page of the last slide stays there."
  (let ((org-slides-page-style 'split))
    (with-temp-buffer
      (org-mode)
      (insert "* First\n\nShort.\n\n* Last\n\n")
      (dotimes (i 200)
        (insert (format "Line %03d: final slide content.\n" i)))
      (goto-char (point-min))
      (org-slides-start)
      (unwind-protect
          (progn
            (org-slides-end)
            (let ((count (length org-slides--split-pages)))
              (should (> count 1))
              (dotimes (_ (1- count))
                (org-slides-next))
              (let ((page org-slides--page-index)
                    (slide org-slides--slide-number))
                (should (= page (1- count)))
                (org-slides-next)
                (should (= org-slides--slide-number slide))
                (should (= org-slides--page-index page)))))
        (org-slides-quit)))))

(ert-deftest org-slides-test-prev-enters-last-subpage ()
  "Previous slide lands on that slide's last page, then pages backward."
  (let ((org-slides-page-style 'split))
    (with-temp-buffer
      (org-mode)
      (insert "* First\n\n")
      (dotimes (i 200)
        (insert (format "First %03d: page content.\n" i)))
      (insert "\n* Second\n\n")
      (dotimes (i 200)
        (insert (format "Second %03d: page content.\n" i)))
      (goto-char (point-min))
      (org-slides-start)
      (unwind-protect
          (progn
            ;; Go to the second slide's first page.
            (org-slides-end)
            (should (= org-slides--slide-number 2))
            (should (= org-slides--page-index 0))
            ;; Previous slide should land on the last page of slide 1.
            (org-slides-prev)
            (should (= org-slides--slide-number 1))
            (should (= org-slides--page-index
                       (1- (length org-slides--split-pages))))
            ;; Walking back within slide 1 should stay on its pages.
            (org-slides-prev)
            (should (= org-slides--slide-number 1))
            (should (= org-slides--page-index
                       (- (length org-slides--split-pages) 2)))
            ;; At the first page there is no previous slide; stay there.
            (let ((count (length org-slides--split-pages)))
              (dotimes (_ (1- count))
                (org-slides-prev))
              (should (= org-slides--slide-number 1))
              (should (= org-slides--page-index 0))
              (org-slides-prev)
              (should (= org-slides--slide-number 1))
              (should (= org-slides--page-index 0))))
        (org-slides-quit)))))

(ert-deftest org-slides-test-incremental-bullets ()
  "SPC reveals list items and S-SPC shadows them again."
  (let ((org-slides-page-style 'split)
        (org-slides-incremental-bullets t))
    (with-temp-buffer
      (org-mode)
      (insert "* Slide\n\n- One\n- Two\n  - Child\n- Three\n")
      (goto-char (point-min))
      (org-slides-start)
      (unwind-protect
          (progn
            (should (= (length org-slides--bullet-ranges) 4))
            (should (= org-slides--bullet-index 0))
            (should (= (org-slides-test--shadow-count) 4))
            (org-slides-step-forward)
            (should (= org-slides--bullet-index 1))
            (should (= (org-slides-test--shadow-count) 3))
            (org-slides-step-backward)
            (should (= org-slides--bullet-index 0))
            (should (= (org-slides-test--shadow-count) 4))
            (dotimes (_ 4)
              (org-slides-step-forward))
            (should (= org-slides--bullet-index 4))
            (should (= (org-slides-test--shadow-count) 0)))
        (org-slides-quit)))))

(ert-deftest org-slides-test-step-advances-after-items ()
  "SPC advances to the next slide after all items are revealed."
  (let ((org-slides-page-style 'split)
        (org-slides-incremental-bullets t))
    (with-temp-buffer
      (org-mode)
      (insert "* One\n\n- A\n\n* Two\n\n- B\n")
      (goto-char (point-min))
      (org-slides-start)
      (unwind-protect
          (progn
            (should (= org-slides--slide-number 1))
            (should (= org-slides--bullet-index 0))
            (org-slides-step-forward)
            (should (= org-slides--slide-number 1))
            (should (= org-slides--bullet-index 1))
            (org-slides-step-forward)
            (should (= org-slides--slide-number 2))
            (should (= org-slides--bullet-index 0))
            (should (= (org-slides-test--shadow-count) 1)))
        (org-slides-quit)))))

(ert-deftest org-slides-test-bullet-persistence ()
  "Revealed items stay revealed when navigating away and back."
  (let ((org-slides-page-style 'split)
        (org-slides-incremental-bullets t))
    (with-temp-buffer
      (org-mode)
      (insert "* One\n\n- A\n- B\n\n* Two\n\n- C\n")
      (goto-char (point-min))
      (org-slides-start)
      (unwind-protect
          (progn
            ;; Reveal all items on slide 1.
            (dotimes (_ 2)
              (org-slides-step-forward))
            (should (= org-slides--bullet-index 2))
            (org-slides-next)
            (should (= org-slides--slide-number 2))
            (should (= org-slides--bullet-index 0))
            (org-slides-prev)
            (should (= org-slides--slide-number 1))
            (should (= org-slides--bullet-index 2))
            (should (= (org-slides-test--shadow-count) 0))
            ;; Hide one, navigate away and back, partial state persists.
            (org-slides-step-backward)
            (should (= org-slides--bullet-index 1))
            (org-slides-next)
            (org-slides-prev)
            (should (= org-slides--slide-number 1))
            (should (= org-slides--bullet-index 1))
            (should (= (org-slides-test--shadow-count) 1)))
        (org-slides-quit)))))

(ert-deftest org-slides-test-bullet-persistence-subpage ()
  "Reveals persist when moving between sub-pages."
  (let ((org-slides-page-style 'split)
        (org-slides-incremental-bullets t))
    (with-temp-buffer
      (org-mode)
      (insert "* Slide\n\n")
      (dotimes (i 100)
        (insert (format "- Item %03d with some text.\n" i)))
      (goto-char (point-min))
      (org-slides-start)
      (unwind-protect
          (progn
            (should (> (length org-slides--split-pages) 1))
            (let ((count (length org-slides--bullet-ranges)))
              (should (> count 0))
              (dotimes (_ count)
                (org-slides-step-forward))
              (should (= org-slides--bullet-index count))
              ;; Reveal all, then step to the next page.
              (org-slides-step-forward)
              (should (= org-slides--page-index 1))
              (should (= org-slides--bullet-index 0))
              ;; Back to page 0: the fully revealed state returns.
              (org-slides-prev)
              (should (= org-slides--page-index 0))
              (should (= org-slides--bullet-index count))
              (should (= (org-slides-test--shadow-count) 0))))
        (org-slides-quit)))))

(ert-deftest org-slides-test-default-keybindings ()
  "The navigation keys are bound by default."
  (should (eq (lookup-key org-slides-mode-map (kbd "n"))
              #'org-slides-next-or-self-insert))
  (should (eq (lookup-key org-slides-mode-map (kbd "SPC"))
              #'org-slides-step-forward-or-self-insert))
  (should (eq (lookup-key org-slides-mode-map (kbd "p"))
              #'org-slides-prev-or-self-insert))
  (should (eq (lookup-key org-slides-mode-map (kbd "S-SPC"))
              #'org-slides-step-backward-or-self-insert))
  (should (eq (lookup-key org-slides-mode-map (kbd "f"))
              #'org-slides-step-forward-or-self-insert))
  (should (eq (lookup-key org-slides-mode-map (kbd "b"))
              #'org-slides-step-backward-or-self-insert))
  (should (eq (lookup-key org-slides-mode-map [backtab])
              #'org-slides-step-backward-or-shifttab))
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

(ert-deftest org-slides-test-demo-spec-parsing ()
  "Demo specs are parsed into a kind and a value."
  (should (equal (org-slides--demo-parse-spec "buffer:*scratch*")
                 '(buffer . "*scratch*")))
  (should (equal (org-slides--demo-parse-spec "file:~/demo.org")
                 '(file . "~/demo.org")))
  (should (equal (org-slides--demo-parse-spec "/tmp/demo.org")
                 '(file . "/tmp/demo.org")))
  (should (equal (org-slides--demo-parse-spec "https://example.com")
                 '(url . "https://example.com")))
  (should (equal (org-slides--demo-parse-spec "video:/tmp/a.mp4")
                 '(video . "/tmp/a.mp4")))
  (should (equal (org-slides--demo-parse-spec "shell:*demo*")
                 '(shell . "*demo*")))
  (should (eq (car (org-slides--demo-parse-spec "none")) 'none))
  (should (org-slides--demo-video-file-p "clip.MP4"))
  (should-not (org-slides--demo-video-file-p "notes.org")))

(ert-deftest org-slides-test-demo-spec-from-slide ()
  "Properties and #+DEMO lines select the demo for a slide."
  (with-temp-buffer
    (org-mode)
    (insert "* One\n:PROPERTIES:\n:DEMO: buffer:one\n:END:\n\n"
            "* Two\n\n#+DEMO: buffer:two\n\n"
            "* Three\n\n#+begin_src org\n#+DEMO: buffer:literal\n#+end_src\n\n"
            "#+DEMO: buffer:three\n")
    (goto-char (point-min))
    (org-slides-narrow)
    (should (equal (org-slides--demo-spec-for-slide) "buffer:one"))
    (widen)
    (goto-char (point-min))
    (search-forward "* Two")
    (goto-char (line-beginning-position))
    (org-slides-narrow)
    (should (equal (org-slides--demo-spec-for-slide) "buffer:two"))
    (widen)
    (goto-char (point-min))
    (search-forward "* Three")
    (goto-char (line-beginning-position))
    (org-slides-narrow)
    (should (equal (org-slides--demo-spec-for-slide) "buffer:three"))))

(ert-deftest org-slides-test-demo-spec-on-split-page ()
  "A demo spec is still found after narrowing to a split page."
  (let ((org-slides-page-style 'split)
        (org-slides-demo-pane nil))
    (with-temp-buffer
      (org-mode)
      (insert "* One\n\n#+DEMO: buffer:demo\n\n")
      (dotimes (i 100)
        (insert (format "Line %03d for the page splitter.\n" i)))
      (goto-char (point-min))
      (org-slides-start)
      (unwind-protect
          (progn
            (should (> (length org-slides--split-pages) 1))
            (org-slides-next)
            (should (buffer-narrowed-p))
            (should (equal (org-slides--demo-spec-for-slide) "buffer:demo")))
        (org-slides-quit)))))

(ert-deftest org-slides-test-demo-show-hide ()
  "The demo pane shows a buffer in a side window and hides cleanly."
  (let ((demo (get-buffer-create "org-slides-test-demo")))
    (unwind-protect
        (with-temp-buffer
          (org-mode)
          (insert "* One\n\n")
          (goto-char (point-min))
          (org-slides-start)
          (unwind-protect
              (progn
                (org-slides-demo-show "buffer:org-slides-test-demo")
                (let ((window (org-slides--demo-window)))
                  (should (window-live-p window))
                  (should (eq (window-buffer window) demo))
                  (should (eq (window-parameter window 'window-side) 'right))
                  (should (buffer-local-value 'org-slides-demo-mode demo)))
                (org-slides-demo-hide)
                (should-not (org-slides--demo-window))
                (should-not (buffer-local-value 'org-slides-demo-mode demo))
                (should (equal org-slides--demo-spec
                               "buffer:org-slides-test-demo")))
            (org-slides-quit)))
      (kill-buffer demo))))

(ert-deftest org-slides-test-demo-follows-slides ()
  "The demo pane follows per-slide specs and hides when absent."
  (let ((demo (get-buffer-create "org-slides-test-demo")))
    (unwind-protect
        (with-temp-buffer
          (org-mode)
          (insert "* One\n\n#+DEMO: buffer:org-slides-test-demo\n\n"
                  "* Two\n\nNo demo here.\n")
          (goto-char (point-min))
          (org-slides-start)
          (unwind-protect
              (progn
                (should (org-slides--demo-window))
                (should (equal org-slides--demo-spec
                               "buffer:org-slides-test-demo"))
                (org-slides-next)
                (should-not (org-slides--demo-window))
                (should-not org-slides--demo-spec)
                (org-slides-prev)
                (should (org-slides--demo-window))
                (should (equal org-slides--demo-spec
                               "buffer:org-slides-test-demo")))
            (org-slides-quit)))
      (kill-buffer demo))))

(ert-deftest org-slides-test-demo-adopt-window-and-step ()
  "A manually split window can become the demo and drive bullet steps."
  (let ((demo (get-buffer-create "org-slides-test-demo")))
    (with-current-buffer demo
      (erase-buffer)
      (fundamental-mode)
      (insert "demo"))
    (unwind-protect
        (with-temp-buffer
          (switch-to-buffer (current-buffer))
          (org-mode)
          (insert "* One\n\n- A\n- B\n\n* Two\n\n- C\n")
          (goto-char (point-min))
          (org-slides-start)
          (let ((presentation (current-buffer))
                adopted-window)
            (unwind-protect
                (progn
                  (select-window (split-window-right))
                  (switch-to-buffer demo)
                  (org-slides-demo-use-window)
                  (setq adopted-window (selected-window))
                  (should (eq (org-slides--demo-window) adopted-window))
                  (should (buffer-local-value 'org-slides-demo-mode demo))
                  (org-slides-demo-step-forward)
                  (should (= (buffer-local-value 'org-slides--bullet-index
                                                 presentation)
                             1))
                  (should (eq (selected-window) adopted-window))
                  (org-slides-demo-step-forward)
                  (should (= (buffer-local-value 'org-slides--bullet-index
                                                 presentation)
                             2))
                  ;; Moving to a slide without a DEMO spec must keep the
                  ;; adopted window and its demo-mode keys.
                  (org-slides-demo-next)
                  (should (eq (org-slides--demo-window) adopted-window))
                  (should (buffer-local-value 'org-slides-demo-mode demo))
                  (should (eq (selected-window) adopted-window))
                  (org-slides-demo-step-forward)
                  (should (= (buffer-local-value 'org-slides--bullet-index
                                                 presentation)
                             1))
                  (org-slides-demo-hide)
                  (should (window-live-p adopted-window))
                  (should-not (window-parameter adopted-window
                                                'org-slides-demo)))
              (with-current-buffer presentation
                (org-slides-quit))
              (when (window-live-p adopted-window)
                (delete-window adopted-window)))))
      (kill-buffer demo)
      (delete-other-windows))))

(ert-deftest org-slides-test-demo-keybindings ()
  "The demo commands have presentation and demo-buffer bindings."
  (should (eq (lookup-key org-slides-mode-map (kbd "d"))
              #'org-slides-demo-toggle-or-self-insert))
  (should (eq (lookup-key org-slides-mode-map (kbd "C-c C-d"))
              #'org-slides-demo-toggle))
  (should (eq (lookup-key org-slides-mode-map (kbd "C-c C-o"))
              #'org-slides-demo-select))
  (should (eq (lookup-key org-slides-mode-map (kbd "m"))
              #'org-slides-demo-play-macro-or-self-insert))
  (should (eq (lookup-key org-slides-mode-map (kbd "C-c C-m"))
              #'org-slides-demo-play-macro))
  (should (eq (lookup-key org-slides-mode-map (kbd "C-c C-t"))
              #'org-slides-timed-macro-toggle))
  (should (eq (lookup-key org-slides-demo-mode-map (kbd "C-c C-m"))
              #'org-slides-demo-play-macro))
  (should (eq (lookup-key org-slides-demo-mode-map (kbd "C-c C-t"))
              #'org-slides-timed-macro-toggle))
  (should (eq (lookup-key org-slides-demo-mode-map (kbd "C-c C-f"))
              #'org-slides-demo-step-forward))
  (should (eq (lookup-key org-slides-demo-mode-map (kbd "C-c C-b"))
              #'org-slides-demo-step-backward))
  (should (eq (lookup-key org-slides-demo-mode-map (kbd "C-c C-n"))
              #'org-slides-demo-next))
  (should (eq (lookup-key org-slides-demo-mode-map (kbd "C-c C-p"))
              #'org-slides-demo-prev))
  (should (eq (lookup-key org-slides-demo-mode-map (kbd "C-c C-q"))
              #'org-slides-demo-quit)))

(ert-deftest org-slides-test-demo-file ()
  "A file demo visits the file in a buffer."
  (let ((file (make-temp-file "org-slides-demo-" nil ".txt")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "demo"))
          (let ((buffer (org-slides--demo-open-file file)))
            (unwind-protect
                (progn
                  (should (equal (buffer-file-name buffer) file))
                  (with-current-buffer buffer
                    (should (equal (buffer-string) "demo"))))
              (kill-buffer buffer))))
      (delete-file file))))

(ert-deftest org-slides-test-demo-video-page ()
  "Video demos are wrapped in a local HTML page."
  (let ((video (make-temp-file "org-slides-demo-" nil ".mp4")))
    (unwind-protect
        (progn
          (with-temp-file video (insert "not really a video"))
          (let ((url (org-slides--demo-video-page video))
                (page (car org-slides--demo-temp-files)))
            (should (string-prefix-p "file://" url))
            (should (file-exists-p page))
            (with-temp-buffer
              (insert-file-contents page)
              (should (string-match-p "<video" (buffer-string)))
              (should (string-match-p "file://" (buffer-string))))))
      (dolist (page org-slides--demo-temp-files)
        (when (file-exists-p page)
          (delete-file page)))
      (setq org-slides--demo-temp-files nil)
      (delete-file video))))

(ert-deftest org-slides-test-demo-macro-spec ()
  "A macro: demo plays a named keyboard macro in the side pane."
  (let ((last-kbd-macro (string-to-vector "hello"))
        (org-slides-demo-macro-delay 0))
    (kmacro-name-last-macro 'org-slides-test-macro)
    (unwind-protect
        (with-temp-buffer
          (org-mode)
          (insert "* One\n\n#+DEMO: macro:org-slides-test-macro\n\n")
          (goto-char (point-min))
          (org-slides-start)
          (unwind-protect
              (let ((buffer (window-buffer (org-slides--demo-window))))
                (with-current-buffer buffer
                  (should (equal (buffer-string) "hello"))))
            (org-slides-quit)))
      (fmakunbound 'org-slides-test-macro))))

(ert-deftest org-slides-test-demo-macro-follows-buffer ()
  "DEMO-MACRO plays after the slide's demo buffer is shown."
  (let ((last-kbd-macro (string-to-vector "typed"))
        (org-slides-demo-macro-delay 0)
        (demo (get-buffer-create "org-slides-test-demo")))
    (kmacro-name-last-macro 'org-slides-test-macro)
    (with-current-buffer demo
      (erase-buffer)
      (fundamental-mode))
    (unwind-protect
        (with-temp-buffer
          (org-mode)
          (insert "* One\n\n#+DEMO: buffer:org-slides-test-demo\n"
                  "#+DEMO-MACRO: org-slides-test-macro\n\n")
          (goto-char (point-min))
          (org-slides-start)
          (unwind-protect
              (progn
                (should (equal (with-current-buffer demo (buffer-string))
                               "typed"))
                (should (equal org-slides--demo-macro
                               "org-slides-test-macro")))
            (org-slides-quit)))
      (kill-buffer demo)
      (fmakunbound 'org-slides-test-macro))))

(ert-deftest org-slides-test-demo-macro-register ()
  "A demo can play a keyboard macro stored in a register."
  (set-register ?z (string-to-vector "reg"))
  (unwind-protect
      (with-temp-buffer
        (org-mode)
        (insert "* One\n\n#+DEMO: macro:register:z\n\n")
        (goto-char (point-min))
        (org-slides-start)
        (unwind-protect
            (let ((buffer (window-buffer (org-slides--demo-window))))
              (with-current-buffer buffer
                (should (equal (buffer-string) "reg"))))
          (org-slides-quit)))
    (set-register ?z nil)))

(ert-deftest org-slides-test-timed-macro-p ()
  "Timed macro entries are validated."
  (should (org-slides--timed-macro-p '((0.1 . "a") (0.2 . [98]))))
  (should-not (org-slides--timed-macro-p '((a . "x"))))
  (should-not (org-slides--timed-macro-p '((0.1 . nil))))
  (should-not (org-slides--timed-macro-p nil)))

(ert-deftest org-slides-test-timed-macro-recording ()
  "Recording stores keys with their inter-command delays."
  (let ((org-slides-timed-macro-last nil))
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (unwind-protect
          (progn
            (org-slides-timed-macro-start)
            (execute-kbd-macro (string-to-vector "ab"))
            (org-slides-timed-macro-stop)
            (should (equal (buffer-string) "ab"))
            (should (equal (mapcar #'cdr org-slides-timed-macro-last)
                           '("a" "b")))
            (should (= (length org-slides-timed-macro-last) 2)))
        (when org-slides--timed-macro-recording
          (org-slides--timed-macro-cancel))))))

(ert-deftest org-slides-test-timed-macro-demo ()
  "A timed-macro: demo replays recorded steps in the side pane."
  (setq org-slides-test-timed '((0.01 . "a") (0.01 . "b")))
  (unwind-protect
      (let ((org-slides-timed-macro-speed 0))
        (with-temp-buffer
          (org-mode)
          (insert "* One\n\n#+DEMO: timed-macro:org-slides-test-timed\n\n")
          (goto-char (point-min))
          (org-slides-start)
          (org-slides-test--wait-for-timed-playback)
          (unwind-protect
              (let ((buffer (window-buffer (org-slides--demo-window))))
                (with-current-buffer buffer
                  (should (equal (buffer-string) "ab"))))
            (org-slides-quit))))
    (makunbound 'org-slides-test-timed)))

(ert-deftest org-slides-test-timed-macro-follows-buffer ()
  "DEMO-TIMED-MACRO replays after the slide's demo buffer appears."
  (setq org-slides-test-timed '((0.01 . "t") (0.01 . "d")))
  (let ((org-slides-timed-macro-speed 0)
        (demo (get-buffer-create "org-slides-test-demo")))
    (with-current-buffer demo
      (erase-buffer)
      (fundamental-mode))
    (unwind-protect
        (with-temp-buffer
          (org-mode)
          (insert "* One\n\n#+DEMO: buffer:org-slides-test-demo\n"
                  "#+DEMO-TIMED-MACRO: org-slides-test-timed\n\n")
          (goto-char (point-min))
          (org-slides-start)
          (org-slides-test--wait-for-timed-playback)
          (unwind-protect
              (progn
                (should (equal (with-current-buffer demo (buffer-string))
                               "td"))
                (should (equal org-slides--demo-timed-macro
                               "org-slides-test-timed")))
            (org-slides-quit)))
      (kill-buffer demo)
      (makunbound 'org-slides-test-timed))))

(ert-deftest org-slides-test-timed-macro-resolve ()
  "Timed macros resolve from variables and the last recording."
  (setq org-slides-test-timed '((0.1 . "a")))
  (unwind-protect
      (progn
        (should (equal (org-slides--timed-macro-resolve
                        "org-slides-test-timed")
                       '((0.1 . "a"))))
        (should-error (org-slides--timed-macro-resolve "missing")))
    (makunbound 'org-slides-test-timed)))

(ert-deftest org-slides-test-timed-macro-from-block ()
  "A named Emacs Lisp block can define a timed macro."
  (let ((org-slides-timed-macro-speed 0))
    (with-temp-buffer
      (org-mode)
      (insert "#+NAME: org-slides-test-block-timed\n"
              "#+BEGIN_SRC emacs-lisp :exports none :results silent\n"
              "(list (cons 0.01 \"a\") (cons 0.02 \"b\"))\n"
              "#+END_SRC\n\n"
              "* One\n\n#+DEMO: timed-macro:org-slides-test-block-timed\n\n")
      (goto-char (point-min))
      (org-slides-start)
      (org-slides-end)
      (org-slides-test--wait-for-timed-playback)
      (unwind-protect
          (let ((buffer (window-buffer (org-slides--demo-window))))
            (with-current-buffer buffer
              (should (equal (buffer-string) "ab"))))
        (org-slides-quit)))))

(ert-deftest org-slides-test-demo-macro-from-block ()
  "A named block can define a standard keyboard macro."
  (unwind-protect
      (with-temp-buffer
        (org-mode)
        (insert "#+NAME: org-slides-test-block-macro\n"
                "#+BEGIN_SRC emacs-lisp :exports none :results silent\n"
                "(defalias 'org-slides-test-block-macro (kmacro \"h i\"))\n"
                "#+END_SRC\n\n"
                "* One\n\n#+DEMO: macro:org-slides-test-block-macro\n\n")
        (goto-char (point-min))
        (org-slides-start)
        (org-slides-end)
        (unwind-protect
            (let ((buffer (window-buffer (org-slides--demo-window))))
              (with-current-buffer buffer
                (should (equal (buffer-string) "hi"))))
          (org-slides-quit)))
    (fmakunbound 'org-slides-test-block-macro)))

(ert-deftest org-slides-test-timed-macro-insert-block ()
  "The last timed macro can be inserted as an Org source block."
  (let ((org-slides-timed-macro-last '((0.1 . [22]) (0.5 . "a"))))
    (with-temp-buffer
      (org-mode)
      (org-slides-timed-macro-insert-block "my-timed")
      (should (string-match-p "^#\\+NAME: my-timed$" (buffer-string)))
      (should (string-match-p ":exports none" (buffer-string)))
      (should (string-match-p "(cons 0.1 \\[22\\])" (buffer-string)))
      (should (string-match-p "(cons 0.5 \"a\")" (buffer-string))))))

(ert-deftest org-slides-test-keyboard-macro-insert-block ()
  "A named keyboard macro can be inserted as an Org source block."
  (let ((last-kbd-macro (string-to-vector "hi")))
    (kmacro-name-last-macro 'org-slides-test-block-macro)
    (unwind-protect
        (with-temp-buffer
          (org-mode)
          (org-slides-keyboard-macro-insert-block
           "org-slides-test-block-macro")
          (should (string-match-p
                   "^#\\+NAME: org-slides-test-block-macro$"
                   (buffer-string)))
          (should (string-match-p "defalias" (buffer-string)))
          (should (string-match-p ":exports none" (buffer-string))))
      (fmakunbound 'org-slides-test-block-macro))))

(ert-deftest org-slides-test-hide-noexport-src ()
  "Source blocks marked :exports none are hidden in the presentation."
  (with-temp-buffer
    (org-mode)
    (insert "#+BEGIN_SRC emacs-lisp :exports none\n(hidden)\n#+END_SRC\n\n"
            "#+BEGIN_SRC emacs-lisp\n(visible)\n#+END_SRC\n")
    (org-slides--add-overlays)
    (unwind-protect
        (progn
          (goto-char (point-min))
          (search-forward "(hidden)")
          (should (org-slides-test--overlay-covering
                   (line-beginning-position)))
          (goto-char (point-min))
          (search-forward "(visible)")
          (should-not (org-slides-test--overlay-covering
                       (line-beginning-position))))
      (org-slides--rm-overlays))))

(ert-deftest org-slides-test-demo-command-output ()
  "A command demo runs asynchronously and collects its output."
  (let* ((buffer (org-slides--demo-open-command "printf demo-output"))
         (process (car org-slides--demo-processes))
         (deadline (+ (float-time) 5)))
    (unwind-protect
        (progn
          (while (and (process-live-p process)
                      (< (float-time) deadline))
            (accept-process-output process 0.1))
          (with-current-buffer buffer
            (should (string-match-p "demo-output" (buffer-string)))))
      (when (process-live-p process)
        (delete-process process))
      (kill-buffer buffer))))

(provide 'org-slides-test)
;;; org-slides-test.el ends here
