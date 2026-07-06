# pauli-status

The public status page for [pauli.xyz](https://pauli.xyz), served at
[status.pauli.xyz](https://status.pauli.xyz).

The security page promises a status page "hosted outside our infrastructure,
so it stays reachable when we are not." This repo is that promise kept:

- **Hosting**: GitHub Pages (this repo's `main` branch). Nothing here runs on
  Pauli's production host.
- **External monitoring**: `.github/workflows/monitor.yml` probes the three
  published monitors every 10 minutes from GitHub Actions runners and commits
  each sample to the [`data`](../../tree/data) branch; the commit log is the
  audit trail. On a confirmed transition to down it opens a public issue
  labeled [`auto-incident`](../../issues?q=label%3Aauto-incident); GitHub's
  notification mail is the alert channel that survives the production host
  dying (Alertmanager lives on that host).
- **Live checks**: the page also probes the same monitors from the visitor's
  browser (the API serves GET-only CORS), so the page answers "is it down for
  everyone or just me" without waiting for the next scheduled sample.

## Monitors

Defined in the pauli repo's `docs/phase0-runbook.md` §3:

| monitor | URL | expectation |
| --- | --- | --- |
| website | `https://pauli.xyz/` | HTTP 200 |
| api | `https://pauli.xyz/healthz` | 200 **and** keyword `ok` (degraded still answers 200; the keyword match is load-bearing) |
| devices | `https://pauli.xyz/public/devices` | 200 and parseable JSON |

There is deliberately no "job processing" lamp: nothing public measures it,
and an unmonitored green light is a fabricated reading. Worker incidents are
reported in `data/incidents.json` instead.

## Declaring an incident

Edit `data/incidents.json` on `main` (newest first) and push; Pages
redeploys automatically:

```json
{
  "incidents": [
    {
      "date": "2026-07-05",
      "title": "Elevated job latencies on IonQ routes",
      "status": "resolved",
      "affected": ["api"],
      "body": "What happened, in one or two sentences.",
      "updates": [
        { "t": "2026-07-05 21:40 UTC", "text": "Root cause found; deploying fix." }
      ]
    }
  ]
}
```

`status` is free text (`investigating` / `monitoring` / `resolved`); the
monitor never writes this file.

## Data branch layout

- `current.json`: the latest sample, `{checked_at, monitors: {website|api|devices: {s, ms, code}}}`
- `history.jsonl`: one line per probe cycle, rotated to 90 days
- `days.json`: per-day counters per monitor, recomputed each run

The page reads these via `raw.githubusercontent.com` (which serves CORS), so
data updates need no Pages rebuild.

## Local preview

```sh
python3 -m http.server 4322
```

The API and device-registry live checks work from any origin; the website
check requires the `Access-Control-Allow-Origin` header the production
Caddyfile sets on `/`, so it may read as down under a local preview.
