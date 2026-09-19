#!/bin/bash
# Semreh verifier queue watcher — runs on the Mac mini (cron every 10 min).
# Prints one line: IDLE | BUSY: PR #N | CLAIM: N
# Hermes's scheduler reads the output; on CLAIM it starts a Solo session
# with verifier-runbook.md against that PR.
set -euo pipefail

REPO="${SEMR_REP:-MauriceAK/semreh-ios}"

verifying=$(gh pr list --repo "$REPO" --label verifying --json number \
  --jq '.[].number' 2>/dev/null | head -1 || true)
if [ -n "$verifying" ]; then
  echo "BUSY: PR #$verifying"
  exit 0
fi

next=$(gh pr list --repo "$REPO" --label needs-verify \
  --json number,createdAt \
  --jq 'sort_by(.createdAt) | .[0].number // empty' 2>/dev/null || true)
if [ -n "$next" ]; then
  echo "CLAIM: $next"
else
  echo "IDLE"
fi
