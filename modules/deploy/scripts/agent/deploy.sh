#!/usr/bin/env bash
# Deploy command for CI builds: `scripts/agent/deploy.sh [wrangler deploy args]`.
# Deploys with SENTRY_RELEASE = the commit SHA, then uploads source maps to the error tracker only when
# SENTRY_AUTH_TOKEN, SENTRY_ORG and SENTRY_PROJECT are all set (build secrets); otherwise prints a notice.
set -euo pipefail
case "${1:-}" in -h | --help) sed -n '2,4s/^# \{0,1\}//p' "$0"; exit 0 ;; esac
cd "$(dirname "$0")/../.."
release="${WORKERS_CI_COMMIT_SHA:-${GITHUB_SHA:-$(git rev-parse HEAD)}}"
rm -rf dist
npx wrangler deploy --outdir dist --upload-source-maps --var "SENTRY_RELEASE:$release" "$@"
echo "release: $release"

if [ -z "${SENTRY_AUTH_TOKEN:-}" ] || [ -z "${SENTRY_ORG:-}" ] || [ -z "${SENTRY_PROJECT:-}" ]; then
  echo "::notice::source-map upload skipped: SENTRY_AUTH_TOKEN, SENTRY_ORG and SENTRY_PROJECT are not all set"
  exit 0
fi
# The tracker's API base comes from pack.json when the error-tracker module is on.
: "${SENTRY_URL:=$(node -p 'require("./scripts/agent/pack.json").modules?.error_tracker?.api_base ?? ""' 2>/dev/null || true)}"
[ -z "$SENTRY_URL" ] || export SENTRY_URL
cli() { npx --yes @sentry/cli@3.8.0 "$@"; }
cli releases new "$release"
# Links commits so `fixes <SHORT-ID>` resolves the issue; needs the tracker's GitHub integration.
cli releases set-commits "$release" --auto --ignore-missing ||
  echo "::warning::set-commits failed; install the tracker's GitHub integration so 'fixes <SHORT-ID>' resolves issues"
cli sourcemaps upload --release "$release" --strip-prefix 'dist/..' dist
cli releases finalize "$release"
