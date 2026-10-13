---
name: std-evidence
description: Capture visual proof for a PR - before/after screenshots of a changed page, component or layout at phone and desktop widths, page images of a changed .docx or .pptx, video for motion. Use when a UI path changed or the review rule says evidence is missing.
---

# Evidence

1. Capture before (default branch: production, preview or a worktree) and after (your branch) for each changed surface:
   - Web: `node scripts/agent/evidence.mjs --url <url> --path /page --name before|after` writes full-page PNGs at 400 and 1280px. Playwright not at the root (monorepo): run it from the package that has it, as `node "$(git rev-parse --show-toplevel)/scripts/agent/evidence.mjs" ...`. Motion: `--video` (`--gif`/`--mp4` via ffmpeg). Interactions: `--script steps.mjs`.
   - Documents: `soffice --headless --convert-to pdf <file>`, then `pdftoppm -png -r 80 <file>.pdf before` (and `after`) for the changed pages. Documents need before-N and after-N pages instead of the two widths; a PR that also changes web UI needs both.
2. Open every capture and look at it (both widths or every page, overflow, contrast, what the issue asked for). Fix and recapture. Never post an image you have not viewed.
3. Show the final images in chat.
4. `scripts/agent/pr.sh evidence <pr> <files...>` as the PR author, with a person's token and gh 2.99 or later. It uploads the files to GitHub as attachments (never committed, no commit, no push) and posts one comment marked with the PR head SHA, each image embedded by file name. Re-running replaces that comment. Videos (MP4, MOV, WebM) are attached the same way and appear as players. Limits: images 10 MB, video 100 MB on paid plans. Captures must be from the pushed head.
5. Link that comment under Evidence in the PR body.

Seeded data only: no secrets, client or personal data.
