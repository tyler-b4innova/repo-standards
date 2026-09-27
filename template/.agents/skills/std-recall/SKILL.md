---
name: std-recall
description: Recall past decisions, gotchas and prior work from issues and PRs - why something is the way it is, known traps, prior art. Use before re-deciding or repeating a mistake.
---

# Recall

`scripts/agent/recall "<words>" [--label decision|gotcha] [--repo owner/name] [--limit 20]`

One line per hit: `#n kind/state repo title [labels] url`. Scope follows the repo profile (org or this repo only). It uses REST, so it works without `gh`.

1. Start broad, then narrow with `--label decision` (why it is this way) or `--label gotcha` (known traps).
2. Read the hits that matter in full before relying on them. The newest closed decision wins.
3. Cite the issue URL in your plan or PR when it shaped the change.
4. A new trap that cost real time becomes an issue labelled `gotcha` (symptom, cause, fix). Anything that must outlive a PR is an issue, never a file in the repo.
