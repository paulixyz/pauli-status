#!/usr/bin/env bash
# Issue-based alerting for the external monitor: on a transition into "down",
# open (or comment on) a public issue labeled auto-incident; on recovery,
# comment and close it. GitHub's own notification mail is the delivery
# channel. It works precisely when the production host (and its
# Alertmanager) may be dead, which is the failure this page exists for.
# Degraded states are visible on the page but do not page anyone.
set -euo pipefail

STATE="${1:?usage: alert.sh <state-dir>}"
PREV="/tmp/prev.json"
REPO="${GITHUB_REPOSITORY:-paulixyz/pauli-status}"

state_of() { # <file> <monitor>
  jq -r ".monitors.$2.s // \"ok\"" "$1" 2>/dev/null || echo ok
}

for m in website api devices; do
  new="$(state_of "$STATE/current.json" "$m")"
  old="ok"
  [ -f "$PREV" ] && old="$(state_of "$PREV" "$m")"
  [ "$new" = "$old" ] && continue

  title="[monitor] $m is down"
  existing="$(gh issue list --repo "$REPO" --label auto-incident --state open \
    --search "in:title \"$title\"" --json number --jq '.[0].number // empty')"

  if [ "$new" = "down" ]; then
    code="$(jq -r ".monitors.$m.code // \"none\"" "$STATE/current.json")"
    body="External probe transition: \`$old\` → \`down\` at $(date -u +%FT%TZ) (HTTP $code, confirmed by retry). Current state: https://status.pauli.xyz"
    if [ -n "$existing" ]; then
      gh issue comment "$existing" --repo "$REPO" --body "$body"
    else
      gh issue create --repo "$REPO" --title "$title" --label auto-incident --body "$body"
    fi
  elif [ "$old" = "down" ] && [ -n "$existing" ]; then
    gh issue comment "$existing" --repo "$REPO" \
      --body "Recovered: \`down\` → \`$new\` at $(date -u +%FT%TZ)."
    gh issue close "$existing" --repo "$REPO"
  fi
done
