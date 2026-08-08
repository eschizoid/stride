---
name: stride
description: Coach the user's training using stride, their local multi-sport training engine (Strava data + computed metrics in SQLite). Prefer this over the strava skill/MCP for any training analysis, coaching, load/fitness questions, or session planning. Use strava tools only for what stride lacks (kudos, clubs, segments, social).
---

# Stride — local training engine

`stride` syncs the user's Strava data into `~/.stride/db.sqlite` and computes
training-science metrics deterministically. **You are the coach brain; stride is the
data engine.** Don't recompute what stride already computed — consume its JSON.
Never do training math yourself: read stride's numbers, add judgment.

## Coaching workflow

1. `stride sync` — pull new activities + backfill streams (creds live in the db after
   `auth`). Re-pulls a rolling 30-day window so recent Strava edits self-heal. Streams
   backfill is capped at 60/run; sync reports how many activities still need streams.
   **First-time import or deep reconcile** (bulk edits older than 30 days): use
   `stride backfill` — it re-pulls the full activity list + ALL missing streams,
   rate-limit-aware and resumable across days (Strava caps reads at ~1000/day).
   **No API credentials** (Strava requires a subscription for API access since
   June 2026): `stride import <export.zip|dir>` loads a Strava account export —
   summary-level activities (no streams), idempotent, English exports only.
2. `stride analyze` — compute metrics for new/invalidated activities (idempotent;
   prints count + form verdict — the full report lives in `summary`). If any stored
   streams won't decode it says "N had unreadable stream data" (they retry next sync).
3. **`stride week`** — THE weekly-planning payload: summary + the open plan +
   last-14d activities in one call. Use `stride summary` alone for quick check-ins.
4. Reason: polarization, zone gaps, form (TSB), FTP staleness, sport balance —
   AND reconcile the open plan against recent activities (match by date/type,
   then `stride complete <session_id> <activity_id>` for each match).
5. Plan the coming week: `stride plan add <YYYY-MM-DD> <type> "<detail>" "<rationale>"`
   - `type` is the INTENSITY INTENT, not the sport: vo2max | threshold | endurance |
     recovery | strength | rest (free-form ok). The sport/modality goes in `detail`
     ("easy row...", "outdoor ride..."): type answers *why/how hard*, detail answers
     *what exactly*.
   - re-planning a date REVISES its open session in place (the response echoes the same
     id) — a plan edit is not a skip, so you can just `plan add` again to change a day and
     it never leaves skipped tombstones. Reserve `skip` for a session that was going to
     happen and didn't (a real adherence miss).
   - `complete`/`skip` also REFUSE unknown ids (`{"error":"session_not_found"}`
     / `activity_not_found` / `bad_id`) — a typo can't silently desync the log, so
     check for an error field instead of assuming success.
   - a session that didn't happen: `stride skip <id> "<reason>"` (keeps adherence
     history honest — skipped ≠ silently open forever).
   - a REST day that happened: `stride complete <id>` with no activity id (rest has
     nothing to link; any other type still refuses without its activity —
     `{"error":"activity_required"}`).

## Output modes

Query commands emit **JSON when `CLAUDECODE` is set to a non-empty value** (Claude Code
exports it, so you get JSON automatically) and **human tables otherwise**. Override with
`STRIDE_FORMAT=json|human` (case-insensitive). If output ever looks like a table instead
of JSON, prefix the command with `STRIDE_FORMAT=json`. Known error states are in-band:
unconfigured → `{"error":"missing_config"}`, no auth → `{"error":"not_authenticated"}`.
All errors carry a human `message` field alongside the `error` code. `sync` and `analyze`
emit JSON results too (`{synced, streams_fetched, pending_streams}` / `{computed,
stream_errors, form_tsb}`), and `config get` emits `{key, value}` or `not_set`.

## Query commands (JSON for you, tables for humans)

| Command | Returns |
|---|---|
| `stride week` | **planning bundle**: `summary` + `recent_activities_14d` + `open_sessions` |
| `stride summary` | as_of, CTL/ATL/TSB, `last_7d` + `last_28d` zone blocks (seconds + easy/moderate/hard %), `last_hard_session_date` ('' = none on record), `pending_sessions`, FTP (config vs estimated, `stale` + `detraining` flags), HR zone bounds, per-sport 28d breakdown |
| `stride activities [N] [sport]` | last N activities (default 30), optionally filtered by sport (case-insensitive, e.g. `activities 10 rowing`) — date, sport, tss, np_w, intensity, z1–z5 seconds, relative_effort, avg_hr |
| `stride top <metric> [n] [sport]` | best sessions ranked by `hr`, `tss`, `power`, `intensity`, `distance`, `time`, or `output` (kJ) — the leaderboard to `activities`' timeline |
| `stride zones` (alias `pz`) | the 7 power zones as watt ranges from configured FTP: `{ ftp, zones: [{ z, name, lo_w, hi_w }] }` (0 = open-ended bound) |
| `stride activity <id>` | one session in depth: flat z1_s–z5_s + hard_s, hard minutes, power bests (1/3/5/20min) from streams, plus `streams_unreadable` (true = the 0s are corrupt data, NOT a real zero) — use to review whether a planned session hit its targets before `complete`-ing it |
| `stride stats` | career + year-to-date totals per sport (sessions, hours, km) |
| `stride load [days]` | daily tss/ctl/atl/tsb series, chronological (default 90) |
| `stride plan` | planned-session log with `status` (open/done/skipped) + `skipped_reason` |
| `stride doctor` | dataset health: coverage counts, per-model load provenance (`scored_by`), `strength_unrated` (strength sessions awaiting a rating) |
| `stride compare [week\|month]` | rolling window vs the prior one: `{period, current, prior}` each with tss/sessions/hard_min/easy_pct/ctl |
| `stride progress [date] [asc\|desc]` | `{anchor_date, anchor_scored, groups:[{name, lens, sessions}]}` — `lens` is `ef`\|`speed_hr`\|`rpe` (sport-aware); each session carries a `score` in that lens. Bare = latest analyzed workout; `desc` lists newest first without changing the trend. **`anchor_scored: false` means a workout anchored on that date could not be scored by its group's lens, so it is absent from `groups` and the trends exclude it** — do not read the trend as covering the session you asked about. In-band errors: `no_workout_on_date`, `unscorable`, `no_scorable_workouts` |

## Conventions & gotchas

- **Training weeks run Monday–Sunday by default.** Plan and present weeks Mon-first;
  when computing day-of-week from dates, verify against a known anchor
  (2026-07-27 was a Monday).
- **Numeric 0 = "not available"** (no watts → np_w 0; no HR → avg_hr 0). Don't read 0 literally.
- Zone seconds are **HR-based** (universal across sports). Power feeds TSS/NP only.
- TSS ladder: stream-NP → Strava weighted watts → avg watts → hrTSS (zone-weighted) → relative_effort.
- **Metric recompute triggers (the invalidation story):** FTP change (metrics store
  `ftp_used`), **stream arrival** (backfilled streams invalidate the old metrics row),
  and **Strava edits** (a re-synced activity invalidates its metrics). So after a sync,
  always `analyze` to pick up recomputes. `ftp.stale: true` means estimated FTP (20-min
  best × 0.95) exceeds config by >5% — fix is `stride config set ftp_ride <estimate> &&
  stride analyze` (the key is per-sport: `ftp_<sport>`, e.g. `ftp_ride`, `ftp_rowing`);
  `detraining: true` means it's well below config. (`config set ftp_ride` also pushes the
  new FTP to Strava automatically, so their profile stays in sync — only `ftp_ride` does.)
- CTL/ATL/TSB are **as of today** (daily_load extends through today with 0-TSS rest
  days), so `form_tsb` is current — no mental decay adjustments needed. "Today" is the
  LOCAL day, anchored by config **`timezone`** (IANA, e.g. `America/Chicago` — DST-correct
  automatically; preferred) or a fixed **`utc_offset_minutes`** fallback (e.g. -300);
  precedence is timezone > offset > UTC. Without either, users west of UTC get a phantom
  "tomorrow" row each evening — `doctor` shows which anchor is active.
- **Session-RPE**: after a strength/HIIT/yoga session, ask the user how hard it felt
  (1-10) and run `stride rate <activity_id> <n>` — load = hours × RPE × 10
  (TSS-commensurate). For strength-class sports the rating outranks HR in the load
  ladder; for endurance, measured power/HR outrank it. Rating an activity
  invalidates its metrics (re-`analyze` rescores). Ratings live in their own table
  and survive re-syncs.
- Junk HR (outside 35–220 bpm) is filtered at analyze time, so sessions with bad straps
  (common on Peloton strength workouts) get near-0 TSS — that's honest "no data", not
  zero effort. Weigh strength by session count, not TSS. `avg_hr` in `activities` output
  is raw (unfiltered).
- `created_at` in planned sessions is an ISO datetime string (UTC, e.g. `2026-07-27T18:04:22Z`).
- Streams backfill is rate-capped at 60/sync; older activities gain zone data over
  repeated syncs. `sqlite3 ~/.stride/db.sqlite "SELECT COUNT(*) FROM streams"` shows progress.

## Setup & credentials

Day-to-day: none — `stride auth` stores the Strava client id/secret and tokens in the
db, and sync auto-refreshes. `STRAVA_CLIENT_ID`/`STRAVA_CLIENT_SECRET` env vars act as
overrides if set. A locked/corrupt db surfaces as a real error, not a false
"not authenticated".

First-time on a new machine: create a Strava API app (strava.com/settings/api), then
`stride init` → `STRAVA_CLIENT_ID=... STRAVA_CLIENT_SECRET=... stride auth` (browser
paste flow) → `stride config set ftp_ride/hr_z1_max..hr_z4_max` → `stride sync` →
`stride analyze`. The db self-migrates on any command, so upgrading the binary against
an existing db is safe.

## Development

`just test` is the single entry point (pure expects → fresh build → `just e2e`, the
sandbox-HOME suite embedded in the justfile — same pipeline CI runs). The ordering
matters: a failed build leaves a stale binary that the e2e suite would happily "pass"
against, which is why `just test` builds in between.

Toolchain: Roc's new (Zig) compiler (nightly, pinned by exact tag in
`.github/workflows/build.yml`) + basic-cli 0.21 + builtin JSON (roc-json dropped). The
full `just test` — expects, build, and e2e — runs green; the roc#10469 perf gate is
fixed. Build flags take `=` (`--output=`, `--main=`) and always `--opt=dev`, since the
optimized backend miscompiles (issue #32). Roc gotcha that keeps recurring: floats have
no Eq — never `x == 0.0` in an expect; use `Num.abs(x) < 0.001`. Compiler syntax/stdlib
reference: `docs/roc-new-compiler-notes.md`.
