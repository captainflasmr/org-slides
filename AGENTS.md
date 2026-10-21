# AGENTS.md

## Repo shape
- This is a single-file Emacs Lisp package, not a multi-package app.
- The implementation lives in `org-slides.el`; the regression suite lives in `test/org-slides-test.el`.
- `org-slides.el` declares `Package-Requires: ((emacs "27.1") (org "9.4"))` and requires Org at runtime.
- The package is a GPLv3 fork of `org-present.el` by Ric Lister. Keep the original copyright and license notices in the file header and `README.org`.

## Verification command
- Run the ERT suite:
  - `emacs -Q --batch -L . -l test/org-slides-test.el -f ert-run-tests-batch-and-exit`
- The suite exits nonzero if any test fails; the current pass condition is `0 unexpected`.

## Architecture and workflow
- `org-slides-mode` is the minor mode. Enabling it runs `org-slides--setup`; disabling it runs `org-slides--teardown`.
- `org-slides-start` is the user entry point. It enables the mode and runs `org-slides-after-navigate-functions` for the initial slide.
- Navigation commands narrow to the current top-level subtree unless the one-big-page view is active.
- Tall slides are paged by scrolling one screenful at a time in the same window.  `org-slides--next-page`/`--prev-page` use window start/end positions; page starts are stored as markers.  A page break must never skip unseen text: use the window end directly, moving back only to a word boundary when it lands mid-word.
- At the end of the last slide, `org-slides-next` must stay on the final page and report the end of the presentation.  Do not fall back to `org-slides-top`, which resets the slide to page 0 and creates a back-and-forth loop.
- `org-slides-prev` at page 0 of a slide enters the previous slide at its last page (`org-slides--show-last-page-if-changed`), not page 0.  This makes backward navigation traverse every sub-page in reverse.  If the destination logical start is unchanged (title page or first slide with no previous slide), stay on page 0.
- Incremental list-item reveal: `org-slides--setup-bullets` collects Org `item` elements in the current page, shadows each item's own text (excluding nested items) with `org-slides-bullet-shadow`, and tracks `org-slides--bullet-index`.  `org-slides-step-forward` reveals the next item then advances; `org-slides-step-backward` shadows the previous item then goes back.  Forward page/slide entry starts shadowed; backward entry starts fully revealed on a first visit.  `--clear-pagination` must clear bullet overlays and markers.
- Reveal state is stored in `org-slides--bullet-state`, a hash keyed by `(slide-start . page-index)` for split mode (or `(slide-start . scroll)` for scroll mode).  `org-slides--setup-bullets` restores the saved count and only uses the forward/backward default on a first visit; `org-slides--save-bullet-state` runs after every reveal/hide.  Do not clear this hash on page navigation; only reset it on presentation setup/teardown.
- Shift+Space is not reliably distinguishable from Space on every GUI/terminal input path.  Keep `S-SPC` bound for environments that report it, but also bind `b`, `S-TAB`, `Backspace`, and `C-c C-b` as backward-step alternatives; `f` is the forward-step alias for SPC.  The editing wrappers must preserve their normal behavior in read-write buffers.
- The experimental `org-slides-page-style` `split` computes page ranges while the logical slide is narrowed.  Pages break at buffer line boundaries (so narrowing does not reflow them), prefer nested headings when the preceding page stays at least half full, and are recomputed after window-size/text-scale changes.  `org-slides--show-split-page` narrows to exactly one range; `org-slides--logical-start/end` markers restore the full slide for recomputation.
- Slide numbers count top-level headings in document order (title page = 0).  Page indicators use `SLIDE.PAGE`, live in `mode-line-process`, and are shown on every slide by default (`org-slides-page-indicator` = `always`).  The indicator also includes total slides and total pages via `org-slides-page-indicator-format`.  The mode line does not affect text height, so it is not part of page fitting.  Save and restore the user's original `mode-line-process` in setup/teardown.
- `org-slides--add-overlays` hides `#+` keyword/block delimiter lines, heading stars, and emphasis markers. Complete-line overlays must include the trailing newline; otherwise they leave blank lines around source blocks.
- Do not hide `#+` lines that are literal content inside source/example/quote blocks.
- The text scale is saved on setup and restored on teardown. Overlay and cursor state is buffer-local.

## When changing code
- If you change navigation, overlay, or scale behavior, update `test/org-slides-test.el`.
- Keep the package self-contained; integrations such as `org-table-fit` belong in the user's config via `org-slides-after-navigate-functions`.
- Preserve the default backward navigation keys: `p`, `S-SPC`, and the left arrow.
