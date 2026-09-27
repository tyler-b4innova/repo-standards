---
name: std-evidence
description: Capture visual proof for a PR - before/after screenshots of a changed page, component, layout, .docx or .pptx at phone and desktop widths, video for motion. Use when a UI path changed or gate says evidence is missing.
---

# Evidence

1. Capture before (default branch: production, preview or a worktree) and after (your branch) for each changed surface:
   - Web: `node scripts/agent/evidence.mjs --url <url> --path /page --name before|after` writes full-page PNGs at 400 and 1280px. Motion: `--video` (`--gif`/`--mp4` via ffmpeg). Interactions: `--script steps.mjs`.
   - Documents: `node scripts/agent/evidence.mjs --doc <file.docx|pptx> --name after` renders pages to PNG.
2. Open every capture and look at it: both widths, overflow, contrast, the exact thing the issue asked for. Fix and capture again. Never post an image you have not viewed.
3. Show the final images in chat.
4. `scripts/agent/pr.sh evidence <pr> <files...>` as the PR author (or with an app token). It commits the set to `.evidence/`, posts one comment with SHA-pinned links, then removes `.evidence/` from the tip. Re-running updates the same comment.
5. Link that comment under Evidence in the PR body.

Seeded test data only: no secrets, client data or personal information. Real iOS Safari is not Playwright WebKit; say so when it matters.
