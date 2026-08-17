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

1. `stride sync --json` — pull new activities + backfill streams (creds live in the db after
   `auth`). Re-pulls a rolling 30-day window so recent Strava edits self-heal. Streams
   backfill is capped at 60/run; sync reports how many activities still need streams.
   **First-time import or deep reconcile** (bulk edits older than 30 days): use
   `stride backfill` — it re-pulls the full activity list + ALL missing streams,
   rate-limit-aware and resumable across days (Strava caps reads at ~1000/day).
   **No API credentials** (Strava requires a subscription for API access since
   June 2026): `stride import <export.zip|dir>` loads a Strava account export —
   summary-level activities (no streams), idempotent, English exports only.
2. `stride analyze --json` — compute metrics for new/invalidated activities (idempotent;
   prints count + form verdict — the full report lives in `summary`). If any stored
   streams won't decode it says "N had unreadable stream data" (they retry next sync).
3. **`stride plan --json`** — THE weekly-planning payload: summary + the open sessions +
   last-14d activities in one call. Use `stride summary --json` alone for quick check-ins.
4. Reason: polarization, zone gaps, form (TSB), FTP staleness, sport balance —
   AND reconcile the open plan against recent activities (match by date/type,
   then `stride complete <session_id> <activity_id> --json` for each match).
5. Plan the coming week: `stride week add <YYYY-MM-DD> <type> "<detail>" "<rationale>" --json`
   - `type` is the INTENSITY INTENT, not the sport: vo2max | threshold | endurance |
     recovery | strength | rest (free-form ok). The sport/modality goes in `detail`
     ("easy row...", "outdoor ride..."): type answers *why/how hard*, detail answers
     *what exactly*.
   - re-planning a date REVISES its open session in place (the response echoes the same
     id) — a plan edit is not a skip, so you can just `week add` again to change a day and
     it never leaves skipped tombstones. Reserve `skip` for a session that was going to
     happen and didn't (a real adherence miss).
   - `complete`/`skip` also REFUSE unknown ids (error code `session_not_found`
     / `activity_not_found` / `bad_id`) — a typo can't silently desync the log, so
     check for an error field instead of assuming success.
   - a session that didn't happen: `stride skip <id> "<reason>" [activity_id|none] --json` —
     the optional link names the activity done INSTEAD (a substitution, not a
     completion; rendered `→ id` in week); `none` releases a link; a bare re-skip
     keeps one. Refusals: `activity_already_linked` (that activity already tells
     another session's story — the error names the blocker and the release path)
     and `session_done` (completions are permanent; fix a mis-link by re-completing,
     never by skip). Skipped ≠ silently open forever.
   - a REST day that happened: `stride complete <id>` with no activity id (rest has
     nothing to link; any other type still refuses without its activity —
     error code `activity_required`).

## Reading decoupling and detected structure

- **Aerobic decoupling** (`decoupling_pct` + `decoupling_known` on `activity` and every
  progress session row; `decoupling_signal` = "power", "pace" (grade-adjusted), or
  "speed" (no altitude stream — terrain NOT normalized, read cautiously on hilly
  routes)): second-half vs first-half efficiency drift. LOWER is better; ≤ +5% on a
  steady 1h+ effort = solid durability. Only meaningful on STEADY sessions — on
  intervals it reflects workout shape (check `segments`: work reps present → don't
  read drift as durability). Unknown when: no usable signal, the signal covers less
  than half the session, or |value| > 50% (artifact).
- **Detected structure** (`stride activity <id> --json`): `interval_summary` ("3×[12:00 @
  230W / 4:00 easy]"), `segments` (per-rep kind/duration/avg + HR peak/avg/60s
  recovery drop), `hr_drift` + `hr_drift_known` (rising across reps = fatigue), and
  `detection_attempted` (false = couldn't look — no power/pace signal — which is NOT
  the same as "verified: no structure"). The detector reports; matching structure to
  a prescription stays YOUR judgment.

## Output modes

**PASS `--json` ON EVERY QUERY YOU RUN.** Stride prints human tables by default and
machine JSON only when asked — nothing infers the mode from your environment, so a
command without the flag gives you a table no matter what your harness exports. The
flag works in any argv position and the last one wins; `--human` forces tables even for you. `STRIDE_FORMAT=json|human`
(case-insensitive) sets a session default and the flag beats it. `--` ends flag
parsing, so `stride skip 5 -- --json` stores the literal string as the reason and
still honors the requested format. If output ever looks like a table when you
wanted data, you left `--json` off. EVERY machine response is a
versioned envelope — including usage errors (`{"error":{"code":"usage",…}}`) and a
bare `stride --json`, which answers with `{"data":{"commands":[…]}}` rather than the
human help screen (#180): success → `{"schema_version":2,"data":{…}}`, error →
`{"schema_version":2,"error":{"code":"…","message":"…"}}`. The payloads described in
the table below all live under `.data`; `error` is an OBJECT whose `code` carries the
in-band error names used throughout this file (`unknown_command`, `missing_config`, `not_authenticated`,
`derived_key`, …), with the human text nested in `error.message`. An error
envelope is ALSO an exit status: stride exits 1 whenever it emits one (0 on
success; a bare `stride` prints help and exits 0) — read either channel, they
never disagree. `sync` and `analyze`
emit JSON results too (`{synced, new_activities, updated_activities, streams_fetched,
pending_streams}` / `{computed, stream_errors, form_tsb, form_tsb_known, form_state,
form_delta_7d, form_delta_known, converged}`), and `config get` emits `{key, value}` or `not_set`.

## Query commands (add `--json` to every one of these)

| Command | Returns |
|---|---|
| `stride plan` | **planning bundle**: `summary` + `recent_activities_14d` + `open_sessions` + `plan_history_28d` (EVERY session targeted in the trailing 28d, any status, with `skipped_reason`, `completed_activity_id`/`substitute_activity_id` links and `completed_on` = the linked activity's date) + `adherence_28d` `{planned, completed, skipped, substituted, still_open, completion_pct, unplanned_activities}` — raw counts, `planned == completed + skipped + still_open`, `substituted ⊆ skipped`; `completion_pct`'s denominator includes `still_open` (an in-window session not yet done counts against it); planned-vs-actual reconstructs from this ONE call |
| `stride summary` | as_of, CTL/ATL/TSB (+`ctl_warming_up`, `ramp_7d`/`ramp_28d_avg`, `form_delta_7d` + `form_delta_known` (spelled exactly so — no _7d_ in the flag), `form_band_days`+`_capped`, `form_state` — the stable band id to switch on: `high_modeled_fatigue`|`modeled_fatigue_building`|`balanced`|`fresh`|`very_fresh`), `last_7d` + `last_28d` zone blocks (seconds + easy/moderate/hard %), `last_hard_session_date` ('' = none on record), `pending_sessions`, `ftp: {best_20min_w_60d, estimated_ftp_w}` (DERIVED — see gotchas), `hr_zones`, `load_days`, per-sport 28d breakdown (rows carry `last_date`), `hard_days` `{d14, d28, spacing_median_days_28d, spacing_known, days_since_last, days_since_known}` (DISTINCT hard days — two hard sessions in one day count once; power-aware 5+ min hard predicate, same as week's hard column; the days_since pair is 28d-scoped, so it can read known: false while the all-time `last_hard_session_date` still carries a date), `load_windows` `{d7, d28, d90, prior_d7, prior_d28, delta_7d, delta_28d}` (adjacent same-width prior windows, raw deltas), `ftp.prior_60d_best_20min_w + prior_60d_known` (threshold trajectory); `last_7d`/`last_28d` carry `load_coverage` `{high_pct, medium_pct, low_pct, known}` (TSS-weighted confidence tiers: high = measured power, medium = HR/RPE, low = relative-effort; they sum to exactly 100, `known: false` = empty window) and `form_coverage_90d` is the same shape over ~two CTL time constants — the provenance of CTL/ATL/TSB. Descriptive only: stride states the mix, you decide if it matters |
| `stride activities [N] [sport]` | last N activities (default 30), optionally filtered by sport (sport FAMILY words, case-insensitive: `bike`/`run`/`row`/`swim` widen to their Strava spellings, e-bikes excluded from `bike`; non-family sport_types filter exactly) — date, sport, tss, np_w, intensity, z1–z5 seconds, relative_effort, avg_hr |
| `stride top <metric> [n] [sport]` | best sessions ranked by `hr`, `tss`, `power`, `intensity`, `distance`, `time`, or `output` (kJ) — the leaderboard to `activities`' timeline |
| `stride zones` (alias `pz`) | the 7 power zones as watt ranges from the DERIVED ride FTP: `{ ftp, zones: [{ z, name, lo_w, hi_w }] }` (0 = open-ended bound) |
| `stride power-curve [days] [sport]` (alias `pc`) | best mean-max power per ladder duration over the window (default 90 days): `{ window_days, sport, points: [{dur_s, watts}], cp, w_prime }` — the CP curve behind FTP |
| `stride activity <id>` | one session in depth: flat z1_s–z5_s + hard_s, hard minutes, power bests (1/3/5/20min) from streams, plus `streams_unreadable` (true = the 0s are corrupt data, NOT a real zero) — use to review whether a planned session hit its targets before `complete`-ing it; `baselines` — this ride vs the athlete's OWN prior comparables (90d before the activity, same sport family + duration band via ONE shared rule): per metric (`ef`, `np`, `decoupling`) `{current, baseline_median, percentile, delta_pct, sample_count, known}`; `percentile` is direction-free rank (higher is better for ef/np, lower for decoupling), weigh it by `sample_count` |
| `stride stats` | career + year-to-date totals per sport (sessions, hours, km) |
| `stride load [days]` | daily tss/ctl/atl/tsb series, chronological (default 90) |
| `stride week` | this week (Mon-Sun) PLUS `unplanned` rows for activities no session references — statuses open/done/skipped/unplanned; rows carry `substitute_activity_id` ("did this instead" links, rendered `→ id`); unplanned rows carry their id in `activity_id`, NOT `completed_activity_id` — discriminate on `status`. `stride week all` = full session log, no unplanned rows. |
| `stride doctor` | dataset health: coverage counts, per-model load provenance (`scored_by`), `strength_unrated` (strength sessions awaiting a rating) |
| `stride compare [week\|month]` | rolling window vs the prior one: `{period, window_label, current, prior}`, each side with tss/sessions/hard_min/easy_pct/ctl + `has_data` — `has_data: false` is the discriminator for an empty window (do not read its 0s as training) |
| `stride progress [date] [asc\|desc]` | `{anchor_date, anchor_scored, groups:[{name, lens, sessions}]}` — `lens` is `ef`\|`speed_hr`\|`rpe` (sport-aware); each session carries a `score` in that lens. Bare = latest analyzed workout; `desc` lists newest first without changing the trend. **`anchor_scored: false` means a workout anchored on that date could not be scored by its group's lens, so it is absent from `groups` and the trends exclude it** — do not read the trend as covering the session you asked about. In-band errors: `no_workout_on_date`, `unscorable`, `no_scorable_workouts` |

## Conventions & gotchas

- **Training weeks run Monday–Sunday by default.** Plan and present weeks Mon-first;
  when computing day-of-week from dates, verify against a known anchor
  (2026-07-27 was a Monday).
- **Missing-value contract (ADR 0009):** JSON null is not expressible (encoder
  stringifies tags), so absence is flagged, not nulled. Impossible-zero fields
  (`np_w`, `avg_hr`, `intensity`, `ftp_used`): 0 = not available. `activity`,
  `activities`, and `plan.recent_activities_14d` rows carry
  `power_known`/`intensity_known`/`hr_known`/`zones_known` + `load_model`; `top`
  rows carry the first three (they are separate flags because np can exist while
  intensity does not — power stream, no FTP yet). `tss: 0` is AMBIGUOUS — read
  `load_model`: `""`/`"none"` = unscored, anything else = a scored near-zero
  effort. Zone seconds `z1_s..z5_s` mean their 0 literally ONLY when
  `zones_known: true`; all-zero with `zones_known: false` = no HR stream (summary
  `avg_hr` can exist without one — `hr_known` does not cover zones). `distance_m`
  0 is always literal. Fields that are BOTH possible-zero and possibly-absent
  always carry a `_known` flag (`decoupling_known`, `form_delta_known`,
  `form_tsb_known`, `hr_drift_known`, `rec_drop_known`) — trust the flag, never
  the magnitude. `progress` sessions carry no flags on purpose: rows exist only
  because the group lens scored them.
- Zone seconds are **HR-based** (universal across sports). Power feeds TSS/NP only.
- TSS ladder: stream-NP → Strava weighted watts → avg watts → hrTSS (zone-weighted) → relative_effort.
- **FTP is DERIVED, never configured.** Per sport, per activity era: best 20-min power
  × 0.95 over the 60 days up to each activity (`summary.ftp` = `{best_20min_w_60d,
  estimated_ftp_w}` for rides). the `ftp` / `ftp_<sport>` config keys are REFUSED with
  error code `derived_key` — there is nothing to fix when FTP moves; INTERPRET the
  trajectory instead (a rising `estimated_ftp_w` is fitness, a falling one is
  detraining or a power-data gap — check `doctor` coverage before concluding).
- **Metric recompute triggers (the invalidation story):** derived-FTP change (metrics
  store `ftp_used`), HR-zone change, **stream arrival**, **rating change**, and
  activity-input edits (analyze compares each row's stored inputs — sync itself never
  deletes metrics). So after a sync, always `analyze` to pick up recomputes.
- CTL/ATL/TSB are **as of today** (daily_load extends through today with 0-TSS rest
  days), so `form_tsb` is current — no mental decay adjustments needed. "Today" is the
  LOCAL day, anchored by config **`timezone`** (IANA, e.g. `America/Chicago` — DST-correct
  automatically; preferred) or a fixed **`utc_offset_minutes`** fallback (e.g. -300);
  precedence is timezone > offset > UTC. Without either, users west of UTC get a phantom
  "tomorrow" row each evening — `doctor` shows which anchor is active.
- **Session-RPE**: after a strength/HIIT/yoga session, ask the user how hard it felt
  (1-10) and run `stride rate <activity_id|latest> <n>` — load = hours × RPE × 10
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
paste flow) → `stride config set hr_z1_max..hr_z4_max` (+ `timezone`, IANA) → `stride sync` →
`stride analyze`. The db self-migrates on any command, so upgrading the binary against
an existing db is safe.

## Development

`just test` is the single entry point (pure expects → fresh build → `just e2e`, the
sandbox-HOME suite embedded in the justfile — same pipeline CI runs). The ordering
matters: a failed build leaves a stale binary that the e2e suite would happily "pass"
against, which is why `just test` builds in between.

Toolchain: Roc's new (Zig) compiler (nightly, pinned by exact tag in
`.github/workflows/build.yml`) + basic-cli 0.22 + builtin JSON (roc-json dropped). The
full `just test` — expects, build, and e2e — runs green; the roc#10469 perf gate is
fixed. Build flags take `=` (`--output=`, `--main=`) and always `--opt=dev`, since the
optimized backend miscompiles (issue #32). Roc gotcha that keeps recurring: floats have
no Eq — never `x == 0.0` in an expect; use `Num.abs(x) < 0.001`. Compiler syntax/stdlib
reference: `docs/roc-new-compiler-notes.md`.
