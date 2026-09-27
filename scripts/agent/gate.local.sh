#!/usr/bin/env bash
# Engine-only gate step: the repository stays org-neutral in its tree and its whole history.
set -euo pipefail
cd "$(dirname "$0")/../.."
node tools/neutrality.mjs
node tools/neutrality.mjs --history
