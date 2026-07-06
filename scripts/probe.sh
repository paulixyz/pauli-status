#!/usr/bin/env bash
# External monitor probe for pauli.xyz; runs on GitHub Actions (see
# .github/workflows/monitor.yml) and writes results into the state checkout
# (the `data` branch). Monitor set and expectations follow the pauli repo's
# docs/phase0-runbook.md §3:
#
#   website  GET https://pauli.xyz/                expect HTTP 200
#   api      GET https://pauli.xyz/healthz         expect 200 AND keyword "ok"
#            (a degraded instance still answers 200 {"status":"degraded"};
#            the keyword match is load-bearing)
#   devices  GET https://pauli.xyz/public/devices  expect 200 AND parseable JSON
#
# Files maintained on the data branch:
#   current.json   latest sample (the page and alert.sh read this)
#   history.jsonl  one line per probe cycle, rotated to the last 90 days
#   days.json      per-day counters per monitor, recomputed from history.jsonl
set -euo pipefail

STATE="${1:?usage: probe.sh <state-dir>}"
UA="pauli-status-monitor/1.0 (+https://status.pauli.xyz)"
NOW="$(date -u +%FT%TZ)"
BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT

# Preserve the pre-probe state so alert.sh can detect transitions after we
# overwrite current.json.
if [ -f "$STATE/current.json" ]; then
  cp "$STATE/current.json" /tmp/prev.json
fi

# probe <url> -> "code ms" (code 000 = no HTTP response)
probe() {
  local out
  out="$(curl -sS -o "$BODY" -w '%{http_code} %{time_total}' --max-time 15 \
    -A "$UA" "$1" 2>/dev/null)" || out="000 15.0"
  local code="${out%% *}" secs="${out##* }"
  printf '%s %s\n' "$code" "$(awk -v s="$secs" 'BEGIN { printf "%d", s * 1000 }')"
}

# classify <key> <url> -> JSON fragment {"s":..,"ms":..,"code":..}; one
# confirmation retry before reporting anything other than ok, so a single
# blip does not open an incident issue.
classify() {
  local key="$1" url="$2" code ms s attempt
  for attempt in 1 2; do
    read -r code ms <<<"$(probe "$url")"
    s="down"
    case "$key" in
      api)
        if [ "$code" = "200" ] && grep -q '"status":[[:space:]]*"ok"' "$BODY"; then s="ok"
        elif [ "$code" = "200" ] && grep -q '"degraded"' "$BODY"; then s="degraded"
        fi ;;
      devices)
        if [ "$code" = "200" ] && jq -e . "$BODY" >/dev/null 2>&1; then s="ok"; fi ;;
      *)
        if [ "$code" = "200" ]; then s="ok"; fi ;;
    esac
    [ "$s" = "ok" ] && break
    [ "$attempt" = "1" ] && sleep 10
  done
  jq -cn --arg s "$s" --argjson ms "$ms" --arg code "$code" \
    '{s: $s, ms: $ms, code: ($code | tonumber? // null)}'
}

website="$(classify website "https://pauli.xyz/")"
api="$(classify api "https://pauli.xyz/healthz")"
devices="$(classify devices "https://pauli.xyz/public/devices")"

jq -cn --arg t "$NOW" \
  --argjson website "$website" --argjson api "$api" --argjson devices "$devices" \
  '{t: $t, website: $website, api: $api, devices: $devices}' >> "$STATE/history.jsonl"

# Rotate: ISO-8601 UTC strings compare lexicographically.
CUTOFF="$(date -u -d '90 days ago' +%FT%TZ)"
jq -c --arg cutoff "$CUTOFF" 'select(.t >= $cutoff)' "$STATE/history.jsonl" > "$STATE/history.jsonl.tmp"
mv "$STATE/history.jsonl.tmp" "$STATE/history.jsonl"

jq -cn --arg t "$NOW" \
  --argjson website "$website" --argjson api "$api" --argjson devices "$devices" \
  '{checked_at: $t, monitors: {website: $website, api: $api, devices: $devices}}' \
  > "$STATE/current.json"

# Per-day counters per monitor: {monitor: {"YYYY-MM-DD": {n, ok, deg, down}}}
jq -sc '
  def tally(k): map({day: .t[0:10], s: .[k].s}) | group_by(.day) | map({
    key: .[0].day,
    value: {
      n: length,
      ok: map(select(.s == "ok")) | length,
      deg: map(select(.s == "degraded")) | length,
      down: map(select(.s == "down")) | length
    }
  }) | from_entries;
  {website: tally("website"), api: tally("api"), devices: tally("devices")}
' "$STATE/history.jsonl" > "$STATE/days.json"

echo "probe complete: $(jq -c '.monitors | map_values(.s)' "$STATE/current.json")"
