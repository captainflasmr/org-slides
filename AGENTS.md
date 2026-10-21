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
- `org-slides--add-overlays` hides `#+` keyword/block delimiter lines, heading stars, and emphasis markers. Complete-line overlays must include the trailing newline; otherwise they leave blank lines around source blocks.
- Do not hide `#+` lines that are literal content inside source/example/quote blocks.
- The text scale is saved on setup and restored on teardown. Overlay and cursor state is buffer-local.

## When changing code
- If you change navigation, overlay, or scale behavior, update `test/org-slides-test.el`.
- Keep the package self-contained; integrations such as `org-table-fit` belong in the user's config via `org-slides-after-navigate-functions`.
- Preserve the default backward navigation keys: `p`, `S-SPC`, and the left arrow.
