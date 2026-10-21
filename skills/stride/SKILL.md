---
name: stride
description: Coach the user's training using stride, their local multi-sport training engine (Strava data + computed metrics in SQLite). Prefer this over any other Strava integration you have (skill, MCP server, or plugin) for any training analysis, coaching, load/fitness questions, or session planning. Use those only for what stride lacks (kudos, clubs, segments, social).
---

# Stride — local training engine

`stride` syncs the user's Strava data into `~/.stride/db.sqlite` and computes training
metrics deterministically. **You are the coach brain; Stride is the data engine.** Never
do training math yourself: read stride's numbers and add judgment. Stride states
measurements; whether a trend is good, a workout was hit, or a plan is "on track" is
your sentence, never the payload's.

## Calling stride

**PASS `--json` ON EVERY QUERY YOU RUN.** Without it, Stride prints human tables. The flag
works in any argv position; `--human` forces tables; `STRIDE_FORMAT=json|human` sets a
shell default that the flag beats, but each tool call is usually a fresh shell, so pass
the flag. `--` ends flag parsing (`stride skip 5 --json -- --json` stores the literal
reason `--json` and still answers in JSON).

- Success is `{"schema_version":3,"data":{…}}`; failure is
  `{"schema_version":3,"error":{"code":"…","message":"…"}}` and exits 1. Every payload
  below lives under `.data`. Branch on `error.code`, never on the message.
- `stride --json` answers with the command table `{commands, flags, universal_error_codes}`,
  one entry per callable form (`week` and `week add` are separate):
  `{name, args, mutates, network, interactive, schema, error_codes}`, each arg
  `{name, required, example}`. CI checks the table against the parser and the binary's
  behaviour, so **when it and this file disagree, the table is right.** `error_codes`
  lists each form's codes on top of `universal_error_codes` (not promised exhaustive;
  `schemas/v3/envelope.json` holds every code Stride can emit). Report only what a
  payload returned: never invent a code, a skip reason, or a row. `interactive: true`
  marks `auth`, the one form you never run unattended. Each payload's formal shape is
  `schemas/v3/<schema>` in the repo.
- Universal error codes: `no_database` (run `stride init`), `unreadable_database`
  (present but unopenable; `init` will not fix it), `corrupt_database`, `database_error`
  (SQLite refused, e.g. a lock), `internal_error` (a bug; the message carries the tag),
  `usage`. A misspelled command answers `unknown_command`.
- **`rate_limited` appears on both sides.** As an error code the command made no
  progress (exit 1). As `sync`'s `stopped` value the drain did real work first and the
  envelope is a success at exit 0. Discriminate on the envelope shape, not the token.

**Missing values (ADR 0009).** JSON null is never emitted; absence is flagged.
- Impossible-zero fields (`np_w`, `avg_hr`, `intensity`, `ftp_used`, target magnitudes):
  0 means not available. `power_known`/`intensity_known`/`hr_known`/`zones_known` say
  which (np can exist without intensity: power stream, no FTP yet).
- Possible-zero fields carry a `_known` flag (`decoupling_known`, `form_delta_known`,
  `hr_drift_known`, `rec_drop_known`, `form_tsb_known` on `analyze`, …). Trust the flag,
  never the magnitude. The rule is per payload: `summary` ships `form_tsb` bare because
  it is always computable there.
- `tss: 0` is ambiguous: read `load_model` (`""`/`"none"` = unscored; anything else = a
  scored near-zero effort). Zone seconds `z1_s..z5_s` are literal only with
  `zones_known: true`; all-zero with `false` means no HR stream. `distance_m` 0 is
  always literal.
- `tte`'s `known` is the exception: it means only that the arithmetic ran.

## Coaching workflow

1. **Sync** with `stride sync --json`, the only command that talks to Strava. It
   re-lists a rolling 30-day window (so recent edits heal), then drains every activity
   still missing streams, then strength descriptions, paced against Strava's read
   limits. Progress narrates on stderr; stdout is the envelope
   `{synced, new_activities, updated_activities, pruned, streams_fetched, streams_skipped, pending_streams, notes_fetched, notes_skipped, pending_notes, stopped, resumable}`.
   - `resumable: true` means work is still owed: a queue is pending, a `list_*` stop cut
     the listing short, or a pre-flight refusal on a spent day made no request at all
     (`daily_cap_reached` with empty queues).
   - `stopped` and its remedy: `complete` (both queues walked); `budget_reached`,
     `rate_limited`, `list_rate_limited` clear when Strava's 15-minute window rolls
     over, so tell the athlete ~15 minutes; `daily_cap_reached`, `list_daily_cap_reached`
     clear at UTC midnight, so tell them tomorrow. The two `list_*` values mean the
     activity listing is incomplete and nothing was pruned: `synced`/`pruned` describe
     a partial run.
   - **Never re-run sync in a loop.** A run with `streams_fetched: 0` and
     `streams_skipped > 0` is stuck on unreadable bodies, whatever `stopped` says: the
     queue runs newest first and those bodies are never stored, so they can fill every
     budget. Stop and report it. Otherwise any `stopped` other than `complete` is a limit
     and the command returns at once, so wait out the remedy above before running again.
     `stopped: complete` with `resumable: true` means only unreadable bodies remain
     (`streams_skipped`/`notes_skipped`); re-running returns the same envelope, so stop
     and report. Do not count `notes_fetched` as progress: it includes the routine
     re-reads of descriptions inside the window.
   - A body that does not decode is not stored and retries next run; a 404 (Strava has
     no streams) stores an empty marker and retires the activity. Every stored stream
     is permanent, so a large first sync spans several runs and possibly days.
   - Stride counts its own daily reads in config rows `strava_reads_today` and
     `strava_reads_day` (a UTC day number; a stale stamp is the reset). Do not touch
     them unless Stride itself names `stride config set strava_reads_today 0` as the
     repair.
   - `stride sync --all` drops the window and re-lists everything. It is the only way a
     deletion in old history propagates, and the only way an edit to a description
     older than 30 days gets in; if it stops on the budget, the remainder waits for the
     next `--all`, not the next plain sync.
   - No API credentials: `stride import <export.zip|dir> --json` loads a Strava account
     export (English column headers), summary-level only (no streams), idempotent;
     returns `{imported, skipped}` counts of archive rows.
2. **Analyze** with `stride analyze --json`: computes metrics for new or invalidated
   activities, idempotent, and returns
   `{computed, stream_errors, form_tsb, form_tsb_known, form_state, form_delta_7d, form_delta_known, converged}`.
   `stream_errors` counts activities scored from summary fields because they had no
   readable stream: one never fetched is fetched by the next sync if it has moving time, while a stored row
   that does not decode is never re-pulled. Run analyze after every sync.
3. **Read the bundle** with `stride plan --json` before proposing anything: its
   `plan_history_28d` and `adherence_28d` record what was targeted and what happened, so
   a plan is never a fresh guess. Check `data_freshness.last_sync` against today first.
   `stride summary --json` alone suits quick check-ins.
4. **Reason**: polarization, zone gaps, form (TSB), FTP trajectory, sport balance. Then
   reconcile open sessions against recent activities (match by date and type) and
   `stride complete <session_id> <activity_id> --json` each match.
   `stride complete latest --json` closes the open session on the newest activity's day
   with that activity (`no_open_session` when that day has none).
5. **Plan** with `stride week add <YYYY-MM-DD> <type> "<detail>" "<rationale>" ["<target>"] --json`.
   - `type` is the intensity intent, not the sport: vo2max | threshold | endurance |
     recovery | strength | rest (free-form accepted). The sport goes in `detail`.
   - The optional target is the strict literal `<reps>x<mm:ss>@<watts>W` (`3x12:00@230W`;
     reps 1-99, rep at least 0:30, watts 1-2500), power only, stored beside the prose.
     Malformed: `bad_target`. The echo and `plan`'s open sessions carry `target_known`,
     `target_reps`, `target_dur_s`, `target_watts`.
   - Adding a session on a date that already has an open one REVISES it in place (same
     id) and replaces the whole prescription, so re-planning without the target clears
     it. Never `skip` to re-plan.

### Closing sessions

- `stride complete <id> <activity_id> --json` returns
  `{completed_session, replaced_activity, dropped_substitute, target_known, target_reps, target_dur_s, target_watts, detected_known, detected_reps, detected_mean_dur_s, detected_mean_watts, reps_delta, watts_pct}`.
  `reps_delta`/`watts_pct` mean something only when both `target_known` and
  `detected_known` are true. Completing a done session overwrites its link:
  `replaced_activity` names the old one (0 if none) and `plan_history_28d` keeps it as
  `superseded_activity_id`. That is the repair for a mis-linked completion.
- A rest day that happened: `stride complete <id> --json` with no activity. Any non-rest
  session refuses without one (`activity_required`).
- A session that did not happen: `stride skip <id> "<reason>" [activity_id|none] --json`.
  The activity names a substitution (done instead, shown `→ id` in `week`); `none`
  releases a link; a bare re-skip keeps it. Refusals: `activity_already_linked` (the
  message names the blocker and how to release it), `session_done` (completions are
  permanent; re-complete instead).
- A wrong label, any status: `stride relabel <id> <type> "<detail>" ["<rationale>"] --json`
  returns `{id, session_type, target_date, status}` with links and metrics untouched
  (omitting the rationale keeps the stored one). Use it, not `week add`, for a swapped
  day. The `rest` label is behavioral: it decides whether `complete` needs an activity.
- `complete`, `skip` and `relabel` refuse unknown or non-numeric ids (`session_not_found`,
  `activity_not_found`, `bad_id`). Check for `error` instead of assuming success.

### Events and projection

- `stride event add <YYYY-MM-DD> "<name>" --json` (future dates only, else `bad_date`)
  returns `{id, event_date, name, days_away}`; `stride event remove <id> --json` deletes
  it. `stride events --json` returns
  `{projected_from, baseline_known, ftp_known, events:[{id, event_date, name, days_away, ctl, atl, tsb, planned_in_window, sessions_projected}]}`:
  CTL/ATL/TSB projected onto each event date over the open plan's structured targets,
  window `(projected_from, event_date]`. Untargeted sessions contribute zero, so the gap
  between `planned_in_window` and `sessions_projected` is how blind the projection is.
  `baseline_known: false` means no computed history. A session dated on the baseline day
  is excluded because the baseline already contains today. Negative `days_away` echoes
  the current baseline, not a projection.
- `stride project <YYYY-MM-DD> ["<date>=<target>,..."] --json` returns
  `{target_date, days_away, projected_from, baseline_known, ftp_known, plan_source, ctl, atl, tsb, sessions_considered, sessions_projected, hypothetical}`.
  Bare, it walks the recorded plan; with pairs it walks your hypothetical plan instead,
  echoed in `hypothetical` and never stored. Compare tapers by calling once per
  candidate. Stride never solves for the plan that reaches a TSB; that is your call.

## Strength

Strava's public API does not return a strength workout's sets, so Stride reads them from
two sources and parses both into the same per-set rows:

1. **The activity description.** The athlete pastes a Peloton-style share summary
   (an exercise line, then `3 × 8 • 30 lbs/side`; `/side` variants resolved to the mass
   actually moved); no other paste format is read. Sync fetches strength-family descriptions after the stream queue empties and
   re-reads them inside the 30-day window, so a paste the same evening lands on the next
   sync. Unrecognised text yields nothing and is never an error.
2. **The Strava log, via `stride strength import <file|-> --json`.** Fetch it with the
   Strava MCP connector's `get_strength_workout_details` (it takes `activity_ids`), then
   pass the returned JSON unchanged, a list of workouts or one, from a file or on stdin
   with `-`. It returns `{imported: [{activity_id, rows, sets}], skipped: [{activity_id, reason}]}`;
   a skip `reason` is `unknown_activity` (sync first), `bad_activity_id`, or `no_sets` (the
   workout has no set with reps, which is what the connector returns for an activity
   with no logged sets). Skips exit 0; only `unreadable_file` and `bad_json` fail it. The
   sets are visible at once, without `analyze`. Re-importing an activity replaces its log;
   a `no_sets` skip leaves an existing log alone.

**A stored log wins over the description** for that activity (counting both would double
its sets). Log weights are stored as entered, never doubled for dumbbells: the log does not
say whether a weight is one dumbbell or the pair, so ask the athlete before reading it as a
total. In the log, a set without weight counts as 0 kg, and a set without reps or with an
unrecognised weight unit is dropped.

`stride strength --json` reads both:
`{exercises: [{exercise, points: [{date, top_kg, kg_reps}]}], monthly: [{month, kg, tonnage_known, covered, total}], sessions: {total, with_sets, pasted_unparsed}}`.
Exercises match by exact name. `top_kg` (heaviest weight one rep moved that day) and
`kg_reps` (the day's volume) are the "am I getting stronger" series. `tonnage_known: false`
means the month is under the coverage bar and its `kg` is not a measurement; quote monthly
tonnage only with `covered`/`total`, so a coverage change does not read as a training
trend. `pasted_unparsed` counts sessions whose description yielded nothing, a different
fact from never pasted. Tonnage is volume, not strength.

Strength load comes from session-RPE: after a strength/HIIT/yoga session ask how hard it
felt (1-10) and run `stride rate <activity_id|latest> <n> --json`. Load = hours × RPE × 10,
on the TSS scale; for strength-class sports the rating outranks heart rate. Ratings
survive re-syncs and trigger a rescore on the next `analyze`. `doctor`'s
`strength_unrated` counts sessions waiting for one.

## Query commands (add `--json` to every one)

Pick by question: `season` for the shape of a year, `compare` for this week or month against the one before, `load` for the daily series behind a trend, `progress` for whether whole sessions of a repeated workout got better, `reps` for the same interval shape compared rep by rep.

| Command | Returns |
|---|---|
| `stride plan` | the planning bundle: `summary`, `recent_activities_14d`, `open_sessions`, `plan_history_28d` (every session targeted in 28 days, any status, with `skipped_reason`, `completed_activity_id`, `superseded_activity_id`, `substitute_activity_id`, `completed_on` = the linked activity's date), `adherence_28d` `{planned, completed, skipped, substituted, still_open, rested, completion_pct, unplanned_activities}` (`planned == completed + skipped + rested + still_open`, `substituted ⊆ skipped`; `rested` = open rest sessions whose past day has a `daily_load` row under 1.0 load, excluded from `completion_pct`'s denominator; a rest day that carried load stays `still_open`), and `data_freshness` `{newest_activity, last_sync, activities_awaiting_metrics, activities_awaiting_metrics_known, activities_awaiting_streams}`. `completion_pct` is `completed / (planned - rested)`, and that denominator includes sessions still open later this week, so a low value mid-week is not poor adherence. `last_sync` is when the last successful sync began ("" = never), the only field that detects an install idle for days; it is UTC, so near midnight its date can differ by one from the local today. The `summary.as_of` to `newest_activity` gap cannot detect staleness, because `as_of` is the day `analyze` last ran. Non-zero `activities_awaiting_metrics` means run `stride analyze` first; with `activities_awaiting_metrics_known: false` its 0 means unknown, not nothing to do. `recent_activities_14d` rows carry the raw `avg_hr` only; read `avg_hr_scored` from `activities` before judging a heart rate |
| `stride summary` | `as_of`; `fitness_ctl`, `fatigue_atl`, `form_tsb` (not `ctl`/`atl`/`tsb`); `ctl_warming_up`; `ramp_7d`, `ramp_28d_avg`; `form_delta_7d` + `form_delta_known`; `form_band_days` + `form_band_days_capped`; `form_state` (switch on it: `high_modeled_fatigue`, `modeled_fatigue_building`, `balanced`, `fresh`, `very_fresh`); `last_7d`/`last_28d` (`z1_s`..`z5_s`, `tss`, `moving_time`, `distance_m`, `sessions`, `easy_pct`/`moderate_pct`/`hard_pct`; no total-seconds key, sum the zones); `last_hard_session_date` ('' = none on record); `pending_sessions`; `ftp` `{best_20min_w_60d, estimated_ftp_w, prior_60d_best_20min_w, prior_60d_known}`; `hr_zones`; `load_days`; `sports_28d` rows `{sport, sessions, tss, moving_time, distance_m, last_date}`; `hard_days` `{d14, d28, spacing_median_days_28d, spacing_known, days_since_last, days_since_known}` (distinct days holding a session with 5+ hard minutes; the days-since pair is 28-day scoped); `load_windows` `{d7, d28, d90, prior_d7, prior_d28, delta_7d, delta_28d}`; `load_coverage` on each window and `form_coverage_90d` `{high_pct, medium_pct, low_pct, known}`: TSS share scored by measured power or pace (high), HR or RPE (medium), relative effort (low) |
| `stride season` | `{blocks, months, gap_weeks}`. A block is a run of training weeks closed by `gap_weeks` or more weeks with no load (ADR 0011); blocks are described, never named (no base/build/peak). Block: `{start_date, end_date, weeks, span_weeks, total_load, mean_weekly_load, sessions, closed, easy_pct, moderate_pct, hard_pct, polarization_known, slope_tss_per_week, trend_r2, trend_known, fitted_start_load, fitted_end_load, ftp_start, ftp_end, ftp_lo, ftp_hi, ftp_known, ftp_family, ftp_family_pct}`. `weeks` counts weeks with training, `span_weeks` calendar weeks; `mean_weekly_load` divides by `span_weeks`. Read `fitted_start_load`/`fitted_end_load` before the slope: a low `trend_r2` means scattered weeks, not no trend. `trend_known: false` = under three complete weeks; an unfinished trailing week is left out of the trend. `closed: false` = still moving. Quote `ftp_start`/`ftp_end` (chronological), not `ftp_lo`/`ftp_hi` (unordered); `ftp_family` says whose threshold, and near 50 `ftp_family_pct` means a mixed block. Months: `{month, load, sessions, partial, ftp_family, ftp_family_pct, ftp_lo, ftp_hi, ftp_start, ftp_end, ftp_known}`; never compare a `partial: true` month's load with a complete one. Error: `no_activities` |
| `stride compare [week\|month]` | `{period, window_label, current, prior}`, each side with `tss`, `sessions`, `hard_min`, `easy_pct`, `ctl`, `has_data`, `polarization_known`. `has_data: false` = empty window; `polarization_known: false` = no zone seconds, so `hard_min`/`easy_pct` are not measurements |
| `stride activities [N] [sport]` | the last N activities (default 30), newest first, each `{id, date, name, sport, moving_time, distance_m, tss, np_w, intensity, load_model, hard_s, relative_effort, z1_s, z2_s, z3_s, z4_s, z5_s, avg_hr, avg_hr_scored, power_known, intensity_known, hr_known, zones_known, date_known, rankable}`. Sport filters by family word (`bike`, `run`, `row`, `swim`, `walk`/`hike`, `strength`/`weights`/`lifting`; e-bikes excluded), else exact sport_type. Rows with `rankable: false` (unusable timestamp) are hoisted to the top; `date_known: false` means `date` is an empty hole, not "none". No command repairs such a row, so name it to the athlete rather than reasoning from its date |
| `stride activity <id>` | one session in depth: zones, `hard_s`, power bests, `streams_unreadable` (true = its zeros are corrupt data), decoupling, detected structure (below); `baselines` per metric (`ef`, `np`, `decoupling`) `{current, baseline_median, percentile, delta_pct, sample_count, known}` against the athlete's own comparable sessions from the prior 90 days. `percentile` is the share of those sessions at or below `current`, with no direction applied: high is good for `ef` and `np`, low is good for `decoupling`; weigh it by `sample_count`. `w_prime_balance` `{min_j, end_j, known, model_exceeded, cp_used, w_prime_used, fit_points, fit_r2, fit_family}`; `splits`, per-kilometre rows `{n, distance_m, elapsed_s, elev_gain_m, elev_known, avg_hr, hr_known}`, always SI, empty without a distance stream. `elapsed_s` is wall time, so a stop inside a split belongs to it and a stop is not a slow kilometre; one row can span several kilometres across a recording dropout, and `n` then skips |
| `stride top <metric> [n] [sport]` | best sessions by `hr`, `tss`, `power`, `intensity`, `distance`, `time` or `output` (kJ). `rankable` means chronologically orderable, not about the ranked metric |
| `stride stats` | career and year-to-date totals per sport, rows `{sport, sessions, hours, km}` |
| `stride load [days]` | daily `tss`/`ctl`/`atl`/`tsb` series, chronological (default 90 days) |
| `stride week` | this week (Mon-Sun) plus `unplanned` rows for activities no session references. `status` is open/done/skipped/unplanned; unplanned rows carry their id in `activity_id`. `stride week all --json` is the whole session log without unplanned rows |
| `stride zones` (alias `pz`) | the 7 power zones from the derived ride FTP: `{ ftp, zones: [{ z, name, lo_w, hi_w }] }` (0 = open bound). Error: `no_power_data` |
| `stride power-curve [days] [sport]` (alias `pc`) | best mean-max power per duration (default 90 days) and the CP fit: `{ window_days, sport, points: [{dur_s, watts}], cp, w_prime, fit_points, fit_r2 }`. A low `fit_r2` means the 5/10/20-minute bests do not fall on a line, so CP and W′ were fitted through scatter. `fit_r2` is 1 by construction at two points and 0 with no fit (`cp` 0); a high value from steady (not maximal) bests still yields an implausibly small W′ |
| `stride pace-curve [days] [sport]` (alias `cs`) | the pace twin, grade-adjusted: `{ window_days, sport, points: [{dur_s, speed}], cs, d_prime, fit_points, fit_r2, available_sports }`. `cs` is m/s and `d_prime` metres, always (3.6 m/s = 4:38/km). **Name a sport**: without one it fits nothing (`cs` 0, empty `points`) and `available_sports` lists the sport_types that have data. Matching is exact sport_type, not family |
| `stride tte <watts>` | time to exhaustion at one power from a Ride-family CP fit over 90 days: `{watts, seconds, known, status, cp, w_prime, fit_points, fit_r2, window_days, sport_family, demonstrated_s, demonstrated_w, demonstrated_known, contradicts_model}`. Weigh the fit first: `fit_r2` below ~0.9 is noise, and `fit_points` (max 3) cannot detect a bad fit. `status`: `in_model` (2-20 min), `outside_model` (a direction, not a number), `below_cp` (the model says indefinitely; bodies do not). `contradicts_model: true` = the athlete already held this power longer than predicted, so the number is unusable; `false` is not reassurance. The fit excludes today. Errors: `bad_watts`, `no_cp_fit` |
| `stride reps [date]` | the anchor session's work reps beside same-shaped reps of earlier sessions: `{anchor_date, anchor_activity_id, shape, sport_family, matched_total, sessions}`. `shape` `{rep_count, mean_dur_s, band_lo_s, band_hi_s, signal}` is the comparability rule: same sport family, same rep count, mean rep duration inside the band, same signal (watts never beside m/s), never later than the anchor. Sessions (at most 12; `matched_total` counts every match) carry per-rep `avg_signal`/`avg_hr`, `mean_signal`, `fade_signal` (last minus first), `hr_rise_bpm` + `hr_rise_known`, and `min_dur_s`/`max_dur_s`/`uniformity` so you can judge uneven sessions. Errors: `no_detected_intervals`, `no_intervals_on_date`, `irregular_anchor` (the anchor's own reps vary too much in duration to be one repeated shape) |
| `stride progress [date] [asc\|desc]` | `{anchor_date, anchor_scored, groups}`, each group `{name, grouped_by, lens, sessions, hidden, hidden_lens, hidden_scope}`. `lens` is `ef`, `speed_hr` or `rpe`; each session has a `score`. `grouped_by: structure` (same detected workout shape, names ignored) beats `name` when both could answer. `anchor_scored: false` = the asked-about session is not in the trend. `sessions` is the whole history only when `hidden` is 0. `hidden_scope` rows belong to another distance bucket (more than 10% away) and are not fixable. `hidden_lens` rows lacked what the lens needs (EF: normalized power and HR; speed/HR: distance and HR; RPE: a rating), usually fixable with a power meter, a strap or a rating, except when the stored reading itself is broken (see the heart-rate rule below). The counts carry no ids: find the rows with `stride activities --json`. Errors: `no_workout_on_date`, `unscorable`, `no_scorable_workouts` |
| `stride doctor` | dataset health: coverage counts, `scored_by` per load model, `strength_unrated`, the time anchor in use, `undateable_activities` (`date_known: false` rows) and `unrankable_activities` (`rankable: false`, a superset). `unanalyzed` = never scored; `awaiting_metrics` = what `analyze` would recompute now (the one to act on); `awaiting_metrics_known: false` means it could not be computed and `config_error` says why |
| `stride viz` | the desktop window's published capabilities and focus: `{ protocol, published_at, staleness_seconds, focus_staleness_seconds, focus, views, fields, history, captures }`; see the next section |

## Reading the numbers

- **FTP is derived, never configured**: per sport family, best 20-min power × 0.95 over
  the 60 days up to each activity, once two sessions of the family carry a 20-minute
  best. `summary.ftp` shows `best_20min_w_60d` and `estimated_ftp_w` (0 until then). The
  `ftp`/`ftp_<sport>` config keys refuse with `derived_key`. Interpret the trajectory: a
  falling estimate is detraining or a power-data gap; check `doctor` coverage first.
- **Load ladder**, endurance sports: stream NP → Strava weighted watts → average watts →
  pace (`rtss`) → HR zones → average HR → session-RPE → relative effort. Strength-class
  sports put session-RPE above heart rate. `load_model` on each row names the rung
  (`power_stream`, `weighted_watts`, `avg_watts`, `rtss`, `hr_zones`, `hr_avg`,
  `session_rpe`, `relative_effort`, `none`). It is a mixed model, not pure TSS.
- **Zones are HR-based**. Power feeds TSS/NP; pace feeds the intensity split for distance
  sports without power, a pool swim included.
- **Metrics recompute** when the derived FTP or threshold pace moves, HR zones change, a
  stream arrives, a rating changes, or an activity's inputs are edited. So always
  `analyze` after `sync`.
- **CTL/ATL/TSB are as of today** (rest days filled with zero), so `form_tsb` needs no
  decay adjustment. "Today" is the local day from config `timezone` (IANA, DST-aware,
  preferred) or `utc_offset_minutes`, else UTC; without either, athletes west of UTC see
  a phantom "tomorrow" each evening. `stride config get timezone --json` returns
  `{key, value}`. Weeks run Monday to Sunday (2026-07-27 was a Monday).
- **Two heart rates.** `avg_hr` is what the device reported; `avg_hr_scored` is what
  the engine divides by (the stream's in-band mean when a usable stream exists, else
  the stored average). Quote `avg_hr`, reason from `avg_hr_scored`. The plausible band is
  35-220 bpm: stream samples outside it are dropped, and an out-of-band
  `avg_hr_scored` makes the EF and speed/HR lenses refuse the row (in-band is necessary,
  not sufficient). An out-of-band stored `avg_hr` on a session without HR zone seconds
  also drops the load ladder a rung, which changes its TSS and so CTL, ATL and form. To
  find broken readings, look in `activities` for an out-of-band `avg_hr_scored` with
  `hr_known: true`; without `hr_known` you also catch sessions that never wore a strap,
  which need equipment rather than repair. Equal fields are not a sign of health: they
  are equal whenever no usable stream mean exists, the most damaged streams included.
  Only a large gap between them signals a lossy stream; small rounding gaps are normal.
  `top hr` ranks the stored `avg_hr` and silently omits out-of-band readings, so absence
  there proves nothing. A dead strap on a strength session leaves near-zero TSS, which
  is "no data", not zero effort: weigh strength by session count and RPE.
- **Aerobic decoupling** (`decoupling_pct`, `decoupling_known`, `decoupling_signal` =
  `power`, `pace` (grade-adjusted) or `speed` (no altitude; read cautiously on hills)):
  second-half vs first-half efficiency drift, lower is better, ≤ +5% on a steady 1h+
  effort is solid. Meaningful only on steady sessions; on intervals it reflects the
  workout's shape. Unknown when the signal spans under ~10 minutes or under half the
  session, or beyond ±50%.
- **W′ balance** (`activity.w_prime_balance`) reads against a CP fit for the session's
  own sport family from the 90 days strictly before it. `min_j` is the lowest the tank
  went. **A negative `min_j` is the model failing, not depth achieved**: with
  `model_exceeded: true` the fit is stale or degenerate, so report it as a reason to
  refresh the fit and ignore `end_j`. Normalize by `w_prime_used` before comparing sessions, and
  treat it as a within-session measure. `known: false` = no fit or no power stream, not
  "the tank stayed full".
- **Detected structure** (`stride activity <id> --json`): `interval_summary` (e.g.
  "3×[12:00 @ 230W / 4:00 easy]"; a pace sport reads "5×[4:00 @ 4:00/km / 2:00 easy]",
  per km in JSON whatever `units` says), `segments` (per-rep kind, duration, average, HR
  peak and recovery drop), `hr_drift` + `hr_drift_known` (HR rising across reps at the
  same output means fatigue), and `detection_attempted` (false = no power or pace signal
  to look at, not "no structure"). Matching structure to a prescription is your judgment.
- **Units.** `stride config set units imperial` changes human readouts only. Every JSON
  payload stays SI (`distance_m` metres, `stats`' `km` kilometres), so a mention of miles
  is a display preference, not a change to the numbers you read.
- **Clearing config**: `stride config unset <key> --json` returns `{key, removed}`
  (`removed: false` = already absent). An empty value is refused (`bad_value`).

## Steering the window (the bus)

The desktop window reads the same database. You can put the session you are discussing
on screen, ghost a comparison, or park the cursor on a day by writing one row; the window
polls about once a second and every row reaches a status you can read back.

1. **Discover first.** `stride viz --json` serves what the window published at its last
   launch: `views: [{id, name}]`, `fields: [{name, kind, accepts}]`, `staleness_seconds`
   and `focus_staleness_seconds`. Read the vocabulary there, never from memory; after an
   upgrade it is whatever the last window to run published, so a fresh launch updates
   it. `no_viz_capabilities` means the window has never run against this database: ask
   the athlete to launch it once.
2. **Steer with one INSERT**: `sqlite3 ~/.stride/db.sqlite "INSERT INTO viz_directives
   (view, trace_id) VALUES (2, 20355183143);"`. On a database the window never opened
   the INSERT fails with "no such table". Every column is optional and NULL means leave
   it alone. Name a session exactly by activity id (`trace_id`, `ghost_id`) or by day
   (`trace_day`, `ghost_day`, which pick that day's newest session; never use a day when
   it holds two sessions). The id wins when both are given. `ghost_day = 'none'`
   dismisses the ghost. `capture = 'png'` writes the landed view to
   `captures/<view>.png` under the window's launch directory; `'webm_start'` and
   `'webm_stop'` record. One capture runs at a time.
3. **Verify by id.** `stride viz --json` lists the last ten directives newest first in
   `history` and capture rows in `captures`, each
   `{id, created_at, status, error, applied_at, view, range, cursor_day, trace_day, trace_id, ghost_day, ghost_id, capture, result}`
   (`result` = the capture's absolute path); `SELECT status, error FROM viz_directives
   WHERE id = <id>` reads one row directly. `applied` = every field honoured;
   `applied_partial` = `error` names each refused field and why; `superseded` = a newer
   row won; `stale` = nothing read it within the freshness window. A refused field is a
   fact about the data or the picker, not a reason to retry.
4. **Observe with freshness.** `stride viz --json` serves `focus`
   `{present, live, age_seconds, updated_at, view, range, cursor_day, trace_day, trace_id, ghost_day, ghost_id, detail_day, sport, family}`.
   Read `live`, never the timestamp: a window closed by the OS leaves a row that is
   present but not live; `present: false` is a clean quit (ESC) or a window that never ran.
5. **Focus is context, not evidence.** It tells you what the athlete is asking about,
   never anything about their training. Steer when seeing the thing helps; answer without
   steering when the numbers settle the question. The athlete's own clicks win.

`stride viz tick` runs one headless poll-and-mark cycle for tests. It consumes
directives, so never run it while a window is open. The full contract is docs/viz.md.

The window also shows a game layer that no `--json` payload carries: athlete level from
career hours across all sports (level L needs 5·L·(L+1) cumulative hours; tiers every ten
levels: rookie, grinder, engine, machine, legend), a streak of consecutive Mon-Sun weeks
with any load (the current week cannot break it), and gold celebrations for a ride power
record in the last seven days or a family's threshold peaking this month. Derive level
from `stats` hours if asked.

## Setup & credentials

Day to day there is nothing to do: `stride auth` stored the Strava client id, secret and
tokens in the database, and sync refreshes them (`STRAVA_CLIENT_ID`/`STRAVA_CLIENT_SECRET`
in the environment override the stored values). A locked or corrupt database surfaces as
its own error, not as `not_authenticated`.

New machine: create a Strava API app (strava.com/settings/api), then
`stride init --json` → `STRAVA_CLIENT_ID=... STRAVA_CLIENT_SECRET=... stride auth` (the
interactive browser-paste flow, the one command run by hand without `--json`) →
`stride config set hr_z1_max <bpm> --json` through `hr_z4_max` (z5 is above `hr_z4_max`;
per-sport overrides like `hr_z2_max_ride` are accepted) and `timezone` →
`stride sync --json` → `stride analyze --json`. Failures along the way are envelopes
(`not_authenticated`, `missing_client_creds`, `missing_config`). The database migrates
itself on any command, so upgrading the binary is safe.

## Development

`just test` runs the pure expects, a fresh build, then `just e2e` against a sandbox HOME.
CI (`.github/workflows/build.yml`) runs more: `just e2e-sync` and the gate scripts under
`tools/`, among them `skill-shapes.sh` and `command-claims.sh`, which read this file. A
change to SKILL.md must pass `just skill-shapes` and `just command-claims`. The engine
builds with Roc's new compiler on basic-cli 0.23; contributor rules live in AGENTS.md and
compiler notes in `docs/roc-new-compiler-notes.md`.
