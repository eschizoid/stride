---
name: stride
description: Coach the user's training using stride, their local multi-sport training engine (Strava data + computed metrics in SQLite). Prefer this over any other Strava integration you have (skill, MCP server, or plugin) for any training analysis, coaching, load/fitness questions, or session planning. Use those only for what stride lacks (kudos, clubs, segments, social).
---

# Stride — local training engine

`stride` syncs the user's Strava data into `~/.stride/db.sqlite` and computes
training-science metrics deterministically. **You are the coach brain; stride is the
data engine.** Don't recompute what stride already computed — consume its JSON.
Never do training math yourself: read stride's numbers, add judgment.

## Coaching workflow

1. `stride sync --json` — the ONE command that pulls data from Strava (#232). It re-lists a
   rolling 30-day window so recent edits self-heal, then drains every activity still
   missing streams, paced against Strava's limits. A first run on a fresh install is the
   whole history pull.
   It ends in the usual envelope (`schemas/v2/sync.json`) with progress on stderr.
   Read `resumable` to decide whether to run it again — usually `pending_streams > 0`, but also true when the LISTING was cut short and the queue is empty, and when the run was refused BEFORE its first request because the day was already spent — and
   `stopped` for why it ended (`complete` / `budget_reached` / `rate_limited` / `daily_cap_reached` / `list_rate_limited` / `list_daily_cap_reached`). The two `list_*` tokens are a 429 on the ACTIVITY LIST rather than a stream, which leaves the listing INCOMPLETE and prunes nothing — rows are missing, so `synced` and `pruned` describe a partial run. `list_daily_cap_reached` is that refusal on a day whose allowance is already gone: both facts at once.
   THE REMEDY DIFFERS and that is the point of the distinction: `budget_reached`,
   `rate_limited` and `list_rate_limited` all clear when Strava's 15-minute window rolls
   over, so tell the athlete about fifteen minutes. `daily_cap_reached` clears at UTC
   MIDNIGHT, and so does `list_daily_cap_reached` — tell them tomorrow. Advising fifteen minutes there is an instruction that
   cannot succeed, and this file used to say exactly that ("all non-complete reasons stop
   on the 15-MINUTE window ... NOT tomorrow") for every stop including that one.
   A first sync on a large history takes one run per 15-minute window, bounded by
   Strava's daily read allowance rather than by a fixed number of runs — stride counts
   its own reads against it now, so a few thousand activities spans a day or two and the
   run that exhausts the day says so. Each says how far it got and every stored stream is
   permanent, so re-running is never wasted.
   The count lives in two config rows, `strava_reads_today` and `strava_reads_day` (a UTC
   day number — a stamp that is not today IS the reset, so nothing runs at midnight).
   Engine-maintained; the only reason to touch them is the escape hatch stride names if
   the count is unreadable: `stride config set strava_reads_today 0`.
   `complete` can still leave work: a stream body that does not
   decode is skipped WITHOUT storing, so it retries next run and shows up in
   `streams_skipped`. An activity Strava has no streams for is NOT that case — a
   404 stores an empty marker and retires it permanently (#218).
   **Do not loop on `resumable` alone. The rule is `streams_fetched == 0` with
   `resumable: true` — stop and report.** That one condition covers both ways a
   run can do nothing and still ask for another: unreadable bodies
   (`streams_skipped > 0`, which will keep returning the identical envelope), and
   a rate limit (`stopped: "rate_limited"`, where the wait is ~15 minutes and the
   command returns immediately rather than blocking). The earlier rule keyed on
   `streams_skipped > 0` alone and did NOT fire on the rate-limited shape, where
   a loop can issue dozens of Strava requests per second.
   `stride sync --all` forces a full re-list from scratch — a dev-mode escape hatch
   and the only way a deletion in OLD history propagates; normal use never needs it.
   **No API credentials** (Strava requires a subscription for API access since
   June 2026): `stride import <export.zip|dir> --json` loads a Strava account export —
   summary-level activities (no streams), idempotent, English exports only.
2. `stride analyze --json` — compute metrics for new/invalidated activities (idempotent;
   prints count + form verdict — the full report lives in `summary`). If any stored
   streams won't decode it says "N had unreadable stream data" (they retry next sync).
3. **`stride plan --json`** — THE weekly-planning payload: summary + the open sessions +
   last-14d activities + `plan_history_28d` + `adherence_28d` + `data_freshness`, in one
   call. `plan_history_28d` and `adherence_28d` are what make the loop closed rather than a
   fresh guess each week — what was targeted and what actually happened — so read them
   before proposing anything. `data_freshness` reports how current the rest of the payload
   is, as four measurements; you decide what counts as too stale to plan from. Use
   `stride summary --json` alone for quick check-ins.
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
   - a REST day that happened: `stride complete <id> --json` with no activity id (rest has
     nothing to link; any other type still refuses without its activity —
     error code `activity_required`).
   - a WRONG LABEL on any session, done ones included: `stride relabel <id> <type>
     "<detail>" ["<rationale>"] --json` edits only the descriptive fields and returns
     `{id, session_type, target_date, status}` — the same id echoed, status untouched as
     proof the edit was cosmetic (links and metrics never move; omitting the rationale
     keeps the stored one). The day-swap case: an activity completed against Saturday's
     session whose label still says Sunday's plan — do NOT `week add` the same date to
     fix a label, that inserts a duplicate row you then have to skip. Refuses unknown
     ids (`session_not_found`) and non-numeric ids (`bad_id`), like complete/skip. One
     label IS behavioral, on any status: `rest` decides whether a bare `complete` needs
     an activity id — that path checks the label, not the status — so relabeling to or
     from `rest` changes what a completion (or re-completion) will demand.

## Reading decoupling and detected structure

- **Aerobic decoupling** (`decoupling_pct` + `decoupling_known` on `activity` and every
  progress session row; `decoupling_signal` = "power", "pace" (grade-adjusted), or
  "speed" (no altitude stream — terrain NOT normalized, read cautiously on hilly
  routes)): second-half vs first-half efficiency drift. LOWER is better; ≤ +5% on a
  steady 1h+ effort = solid durability. Only meaningful on STEADY sessions — on
  intervals it reflects workout shape (check `segments`: work reps present → don't
  read drift as durability). Unknown when: no usable signal, the signal covers less
  than half the session, or |value| > 50% (artifact).
- **W′ balance** (`activity.w_prime_balance`): `min_j` is the lowest the anaerobic
  tank got during the ride and `end_j` where it finished, against the CP fit for that
  session's OWN sport family (`fit_family`) from the 90 days STRICTLY BEFORE it, so a
  session is never inside its own fit (`cp_used`/`w_prime_used`/`fit_points`).
  `min_j: 0` means it emptied exactly. **A NEGATIVE `min_j` is the model failing, not
  depth achieved** — it means more above-CP work was done than the fitted tank holds,
  so the CP/W′ is stale or degenerate; `model_exceeded: true` flags exactly that, and
  `|min_j| / w_prime_used` is how badly. Report it as evidence the fit needs
  refreshing, NEVER as "how deep they went". Normalize by `w_prime_used` before
  comparing sessions — it moves between dates, so raw joules are not comparable.
  When `model_exceeded` is true, ONLY `min_j` means anything: the
  recovery term drives on the deficit against the CURRENT balance, so one far below zero
  refills faster than the model's own ceiling allows and `end_j` is arithmetic
  on a broken premise. `fit_r2` grades the fit itself. CP jumps at the window
  edges as rides enter and leave the 90 days, so these are WITHIN-session
  measures, not a comparable series. `known: false` means there was no fit or
  no power stream — never read it as "the tank stayed full".
- **Rep-level progression** (`stride reps --json`): whether the SAME workout shape is
  being ridden harder than it used to be — per-rep watts across sessions and the
  within-session fade. Use it when a structured session repeats; `progress` when
  comparing whole sessions.
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
(case-insensitive) sets a shell-session default and the flag beats it — but note each
shell command you run is typically a FRESH shell, so exporting it does not reliably carry
between calls: `--json` is the one route that always works. `--` ends flag
parsing, so `stride skip 5 --json -- --json` stores the literal string as the
reason and still returns JSON — note the flag is present BEFORE the terminator,
because `--` stops flag parsing for everything after it. If output ever looks like a table when you
wanted data, you left `--json` off. Every machine response you will
consume is a versioned envelope — including usage errors (`{"error":{"code":"usage",…}}`) and a
bare `stride --json`, which answers with the command table rather than the
human help screen (#180). That table DESCRIBES rather than names (#219): one entry per
callable form — `week` and `week add` are separate, because one reads and one writes —
each carrying `{name, args:[{name,required,example}], mutates, network, interactive, schema}`. So
you can determine argument shape, whether a call writes, whether it needs Strava, and
which file under `schemas/v2` the answer validates against, without reading this document.
`interactive: true` marks the one form you must never call unattended (`auth`). Prefer
that table over anything written here if the two ever disagree — it is cross-checked
against the parser in CI, this file is not. It is hand-written, not generated: the verb
set, the schema names, `mutates`, `network` and `interactive` are each checked against
the source or against behaviour, while the free placeholder TEXT — `<days>` versus `<limit>` — is declared. Literal
argument names, both arity bounds and the required-arguments-first ordering are all
checked against the parser. One thing is NOT enveloped: `stride auth`, an interactive browser
flow you run by hand. `stride sync` narrates progress on stderr while it runs — its stdout is
the envelope, so you can read it (#218, #232). Platform failures ARE enveloped now (#183): `no_database` (absent — run `init`),
`unreadable_database` (present but unopenable — permissions or a directory in its
place, which `init` will NOT fix), `corrupt_database`, `database_error` (SQLite
refused the operation, e.g. a lock), `network_unreachable` (Strava never
answered), `strava_error` / `rate_limited` (it answered with a status),
`stdin_closed`, and `internal_error` for anything unforeseen, carrying the
clipped tag in its message — so a failure without a code is a bug, not a shrug.
An expired token still arrives as `not_authenticated`, from the boundary as well
as from sync. Success →
`{"schema_version":2,"data":{…}}`, error →
`{"schema_version":2,"error":{"code":"…","message":"…"}}`. The payloads described in
the table below all live under `.data`; every payload here — the
every query, every action you branch on, the command list and the envelope itself (one
file per published payload in `schemas/v2/`, so the directory listing is the inventory) —
is described formally in `schemas/v2/*.json` in the repo (required keys, types,
enums, and the error-code vocabulary, which is diffed against the source in CI so
a code stride can emit cannot be missing from the contract).
`error` is an OBJECT whose `code` carries the
in-band error names used throughout this file (`unknown_command`, `missing_config`, `not_authenticated`,
`derived_key`, …), with the human text nested in `error.message`. An error
envelope is ALSO an exit status: stride exits 1 whenever it emits one (0 on
success; a bare `stride` prints help and exits 0) — read either channel, they
never disagree. **`rate_limited` is the one code that appears on both sides (#227):** as
an ERROR code it means the command made no progress and exits 1; as `sync`'s `stopped`
value it means the drain did real work before Strava capped it, so it is a success
envelope at exit 0 with `resumable` telling you whether anything is still missing.
Discriminate on the envelope shape, never on the token. `sync` and `analyze`
emit JSON results too (`{synced, new_activities, updated_activities, pruned, streams_fetched,
streams_skipped, pending_streams, stopped, resumable}` / `{computed, stream_errors, form_tsb, form_tsb_known, form_state,
form_delta_7d, form_delta_known, converged}`), and `stride config get <key> --json` emits `{key, value}` (or the `not_set`
error envelope) — that is how you read `timezone` back, which governs what "today"
means for every date below. `stride config unset <key> --json` REMOVES a stored key, emitting `{key, removed}` — `removed: false` means it was already absent, which is not an error. Use it rather than `config set <key> ""`: an empty value is refused for every key class now, because it used to mean three different things depending on the key and two of them left no way to remove a row at all (a per-sport zone override could not be dropped, and an empty write to a token left a row reading as SET).

## Query commands (add `--json` to every one of these)

| Command | Returns |
|---|---|
| `stride plan --json` | **planning bundle**: `summary` + `recent_activities_14d` + `open_sessions` + `plan_history_28d` (EVERY session targeted in the trailing 28d, any status, with `skipped_reason`, `completed_activity_id` (plus `superseded_activity_id`: the completion a re-`complete` erased, 0 if none — the only durable record of an overwrite)/`substitute_activity_id` links and `completed_on` = the linked activity's date) + `adherence_28d` `{planned, completed, skipped, substituted, still_open, completion_pct, unplanned_activities}` — raw counts, `planned == completed + skipped + still_open`, `substituted ⊆ skipped`; `completion_pct`'s denominator includes `still_open` (an in-window session not yet done counts against it) + `data_freshness` `{newest_activity, last_sync, activities_awaiting_metrics, activities_awaiting_metrics_known, activities_awaiting_streams}` — measurements, not a verdict. Read `last_sync` first, against today — it is the only field that detects an install where nothing has run in days (note it is UTC, so near midnight it can differ by a day from the local `today` the `timezone` setting governs). The `summary.as_of` / `newest_activity` gap will NOT tell you that: `as_of` is pinned to the day `analyze` last ran, so the gap equals days since the last ride only when analyze ran TODAY, and otherwise just stops growing. A gap of 3 is equally consistent with "rode 3 days ago, analyzed today" and "analyzed a week ago". Treat a non-zero `activities_awaiting_metrics` as "run `stride analyze` before trusting the numbers" — it counts rows never scored plus rows whose FTP, threshold pace, zones, metrics_rev or underlying inputs (a newly arrived stream being the commonest) changed since scoring, so it is never fewer than doctor's `unanalyzed` and equal to it in the ordinary case. `activities_awaiting_metrics_known: false` means the count could not be computed at all — a 0 beside it is not "nothing to do"; run `stride analyze` to see why. Planned-vs-actual reconstructs from this ONE call |
| `stride summary --json` | as_of, CTL/ATL/TSB (+`ctl_warming_up`, `ramp_7d`/`ramp_28d_avg`, `form_delta_7d` + `form_delta_known` (spelled exactly so — no _7d_ in the flag), `form_band_days`+`_capped`, `form_state` — the stable band id to switch on: `high_modeled_fatigue`|`modeled_fatigue_building`|`balanced`|`fresh`|`very_fresh`), `last_7d` + `last_28d` zone blocks (seconds + easy/moderate/hard %), `last_hard_session_date` ('' = none on record), `pending_sessions`, `ftp: {best_20min_w_60d, estimated_ftp_w}` (DERIVED — see gotchas), `hr_zones`, `load_days`, per-sport 28d breakdown (rows carry `last_date`), `hard_days` `{d14, d28, spacing_median_days_28d, spacing_known, days_since_last, days_since_known}` (DISTINCT hard days — two hard sessions in one day count once; pi_*-aware (power or pace) 5+ min hard predicate, same as week's hard column; the days_since pair is 28d-scoped, so it can read known: false while the all-time `last_hard_session_date` still carries a date), `load_windows` `{d7, d28, d90, prior_d7, prior_d28, delta_7d, delta_28d}` (adjacent same-width prior windows, raw deltas), `ftp.prior_60d_best_20min_w + prior_60d_known` (threshold trajectory); `last_7d`/`last_28d` carry `load_coverage` `{high_pct, medium_pct, low_pct, known}` (TSS-weighted confidence tiers: high = measured power or distance-measured pace, medium = HR/RPE, low = relative-effort; they sum to exactly 100, `known: false` = empty window) and `form_coverage_90d` is the same shape over ~two CTL time constants — the provenance of CTL/ATL/TSB. Descriptive only: stride states the mix, you decide if it matters |
| `stride season --json` | the season at block and month scale: `blocks` + `months` + `gap_weeks`. A BLOCK is a maximal run of training weeks (not necessarily consecutive — it may contain blank weeks) closed by `gap_weeks`+ calendar weeks with NO load (ADR 0011) — bounded by absence because that is the only boundary in the data that is not a judgment call. **Blocks are described, never named** — there is no base/build/peak field and you should not invent one: load observes volume, not intent. Each block carries `start_date`/`end_date` (the first Monday of its first training week, through the last day WITH training — not symmetric), `weeks` (weeks WITH training) and `span_weeks` (calendar weeks covered; they differ because a block may contain up to `gap_weeks`-1 blank weeks per interruption), `total_load`, `mean_weekly_load` (divides by `span_weeks`, NOT `weeks`), `sessions` (activities inside the block's window — this does NOT always equal the `months[]` total, because an activity that scored no load inside an absence belongs to a month and to no block), `closed`, `easy_pct`/`moderate_pct`/`hard_pct` + `polarization_known`, and the trend and threshold fields below. **Read `fitted_start_load`/`fitted_end_load` before `slope_tss_per_week` or `trend_r2`.** A low `trend_r2` means the weeks were SCATTERED around the line, NOT that the block had no trend — on this athlete a block at r2 0.10 still fell from 315 to 214 TSS/week over 71 weeks, and saying it "had no trend" is the most likely false statement this payload can produce. Weigh the slope against `weeks`. `trend_known: false` means under three complete weeks. **`closed: false` means no absence has ended the block** — records simply stop, so its numbers are still moving; a trailing week that has not finished yet is excluded from the trend (leaving it in halved the slope on a single session) while still counting in `weeks`, `sessions` and `total_load` — but a block is often open with its last week already complete, in which case nothing is excluded. `ftp_start`/`ftp_end` are CHRONOLOGICAL and are what to quote — on blocks AND on months; `ftp_lo`/`ftp_hi` are an unordered min/max that reads as a direction it does not have. `ftp_family` names WHOSE threshold it is (a rowing threshold and a cycling FTP are different quantities) and `ftp_family_pct` its share — near 50 the block is genuinely mixed and the other family's threshold is NOT published, so do not describe such a block by one sport. `months[]` carries `{month, load, sessions, partial, ftp_family, ftp_family_pct, ftp_lo, ftp_hi, ftp_start, ftp_end, ftp_known}`; **`partial: true` marks a month still in progress — never compare its load to a complete month** (a partial month's total against a complete one reads as a collapse even when its daily rate is higher). Reach for `season` for the shape of a year; `compare` for one window against the one before it, `load` for the weekly series behind a slope, `progress` for whether individual sessions got better. In-band errors: `no_activities` |
| `stride activities [N] [sport] --json` | last N activities (default 30), optionally filtered by sport (sport FAMILY words, case-insensitive: the `words` lists in `Sports.families` widen to their Strava spellings — `bike`, `run`, `row`, `swim`, `walk`/`hike`, `strength`/`weights`/`lifting`, e-bikes excluded from `bike`; non-family sport_types filter exactly) — date, sport, tss, np_w, `id`, `date`, `name`, `sport`, `moving_time`, `distance_m`, `tss`, `np_w`, `intensity`, `load_model`, `hard_s`, `relative_effort`, `z1_s`, `z2_s`, `z3_s`, `z4_s`, `z5_s`, `avg_hr`, `avg_hr_scored`, and the companions `power_known`, `intensity_known`, `hr_known`, `zones_known`, `date_known`, `rankable`. TWO heart-rate numbers, and picking the wrong one is the mistake this row exists to prevent: `avg_hr` is what the device reported, `avg_hr_scored` is what the engine divides by (#311, #319). Score anything from `avg_hr_scored` and quote `avg_hr` back to the athlete. Reading the pair: they are EQUAL whenever no usable stream mean exists — which includes the most damaged streams, since one lossy enough to corrupt Strava's summary also fails the coverage gate and falls back, so the three worst on record publish 0.2/0.2, 31.3/31.3 and 18/18. They differ when a stream did pass the gate and its mean differs, which happens on 669 of 738 rows — 658 of them by a rounded decimal and only 11 by a real correction over 15 bpm. And an out-of-band `avg_hr_scored` means the EF and speed/HR lenses refused the row, but NOT the converse — they also need a normalized-power `load_model` or distance and moving time, so 45 in-band sessions are refused anyway. `hr_known` still answers only whether a reading was recorded at all. Rows carry `date_known`: false means the stored start_local is unreadable and `date` is an EMPTY STRING — a hole, not a value. Do not read that as "none on record", which is what '' means for `last_hard_session_date`; these rows are hoisted to the TOP of the listing so a limit cannot hide them, and each is repaired by deleting it by id and re-syncing. Rows also carry `rankable`: false means the engine will not give the row a ranking position, which is a WIDER condition than `date_known` — `2026-08-23T37:00:00Z` has a perfectly readable date and an impossible clock, so it publishes `date_known: true` with `rankable: false`. `rankable` is what the hoist keys on, so it is the field that says why row one is row one. It is NOT a `_known` flag and licenses no magnitude. |
| `stride top <metric> [n] [sport] --json` | best sessions ranked by `hr`, `tss`, `power`, `intensity`, `distance`, `time`, or `output` (kJ) — the leaderboard to `activities`' timeline — rows carry `date_known` and `rankable` on the same rules as `activities`. Note `rankable` means CHRONOLOGICALLY orderable and says nothing about the metric you ranked by — a row can be unrankable and still lead this leaderboard, carrying the same needs-repair meaning. In particular `rankable` is not about `time`: `moving_time` on these rows is as trustworthy as on any other. |
| `stride zones --json` (alias `pz`) | the 7 power zones as watt ranges from the DERIVED ride FTP: `{ ftp, zones: [{ z, name, lo_w, hi_w }] }` (0 = open-ended bound) |
| `stride power-curve [days] [sport] --json` (alias `pc`) | best mean-max power per ladder duration over the window (default 90 days): `{ window_days, sport, points: [{dur_s, watts}], cp, w_prime, fit_points, fit_r2 }`. **Weigh the fit with `fit_r2`** — the regression is power against 1/duration, so a LOW value means the 5/10/20-min bests do not fall on a line and CP/W' are drawn through scatter. A HIGH value says the line fits, not that the model fits the athlete: bests taken from steady rather than maximal efforts sit on a near-flat line that scores well and yields an implausibly small W'. It is 1 by construction at two points and 0 when there is no fit (`cp` 0) — the CP curve behind FTP |
| `stride activity <id> --json` | one session in depth: flat z1_s–z5_s + hard_s, hard minutes, power bests (1/3/5/20min) from streams, plus `streams_unreadable` (true = the 0s are corrupt data, NOT a real zero) — use to review whether a planned session hit its targets before `complete`-ing it; `baselines` — this ride vs the athlete's OWN prior comparables (90d before the activity, same sport family + duration band via ONE shared rule): per metric (`ef`, `np`, `decoupling`) `{current, baseline_median, percentile, delta_pct, sample_count, known}`; `percentile` is direction-free rank (higher is better for ef/np, lower for decoupling), weigh it by `sample_count`; `w_prime_balance` `{min_j, end_j, known, model_exceeded, cp_used, w_prime_used, fit_points, fit_r2, fit_family}` — see the W′ balance note above, a negative `min_j` diagnoses the FIT, not the athlete |
| `stride stats --json` | career + year-to-date totals per sport (sessions, hours, km) |
| `stride load [days] --json` | daily tss/ctl/atl/tsb series, chronological (default 90) |
| `stride week --json` | this week (Mon-Sun) PLUS `unplanned` rows for activities no session references — statuses open/done/skipped/unplanned; rows carry `substitute_activity_id` ("did this instead" links, rendered `→ id`); unplanned rows carry their id in `activity_id`, NOT `completed_activity_id` — discriminate on `status`. `stride week all --json` = full session log, no unplanned rows. |
| `stride doctor --json` | dataset health: coverage counts, per-model load provenance (`scored_by`), `strength_unrated` (strength sessions awaiting a rating), and two nested date-health counts: `undateable_activities` (rows with `date_known: false`) and `unrankable_activities` (rows with `rankable: false`, a SUPERSET — it also counts readable dates with unusable clocks). Each corresponds to one row flag, so both can be cross-checked against `stride activities`. Two counts about metrics, and they answer different questions: `unanalyzed` is rows NEVER scored, a coverage number; `awaiting_metrics` is what `analyze` would recompute right now, the same figure `plan` reports, and it is the one to act on — a changed FTP or a new stream leaves `unanalyzed` at 0 while `awaiting_metrics` is the whole history. `awaiting_metrics_known: false` means it could not be computed at all, and `config_error` says why (a zone key that will not parse); the 0 beside it is not "nothing to do" |
| `stride compare [week\|month] --json` | rolling window vs the prior one: `{period, window_label, current, prior}`, each side with tss/sessions/hard_min/easy_pct/ctl + `has_data` — `has_data: false` is the discriminator for an empty window (do not read its 0s as training) |
| `stride tte <watts> --json` | time to exhaustion at a power YOU name, from a CP model fitted on the Ride family over a hard 90 days — `{watts, seconds, known, status, cp, w_prime, fit_points, fit_r2, window_days, sport_family, demonstrated_s, demonstrated_w, demonstrated_known, contradicts_model}`. Reach for it when the athlete names a target power and asks how long; `power-curve` gives the whole curve, `zones` gives prescriptive bands, `tte` answers ONE point and says nothing about pacing. **Weigh the FIT before the number.** `fit_r2` is how well the line fits its own points and is the only quality signal that does not depend on what you asked (below ~0.9 the model is describing noise; it is 1 by construction when `fit_points` is 2, where the count is the signal instead). `demonstrated_*` is the longest effort at or above `watts` the athlete already has on record in the same window the fit came from, so `contradicts_model: true` means the model predicts less than its own inputs prove — the fit understates this rider and the number is not usable. **`contradicts_model: false` is NOT reassurance** — it only fires where a recorded effort happens to overlap the queried power, which on real data is a few watts of a fifty-watt band. `status` qualifies the rest: `in_model` (2-20min, where the two-parameter model holds), `outside_model` (real arithmetic, but the model overshoots — a direction, not a number), `below_cp` (the model says indefinitely; bodies do not). **`known` here is the ONE `_known` flag in stride that does NOT license trusting the magnitude** — it only means the arithmetic ran; `status` and `contradicts_model` are what qualify the number. `fit_points` counts how many of the 5/10/20-min bests existed (max 3) and is 3 for a perfect fit AND a degenerate one, so it cannot detect a bad fit alone. Note the fit EXCLUDES its own anchor date and `tte` anchors on today — a ride synced today is NOT in the fit that answers today's question. `activity.w_prime_balance` applies the same rule anchored on each session's date, so the two differ by anchor and family, not by whether today counts. In-band errors: `bad_watts`, `no_cp_fit` |
| `stride reps [date] --json` | rep-level comparison: the anchor session's detected work blocks beside the same-shaped blocks of earlier sessions — `{anchor_date, anchor_activity_id, shape, sport_family, sessions}`. `shape` `{rep_count, mean_dur_s, band_lo_s, band_hi_s, signal}` IS the comparability rule (same sport family, same rep count, same rep-duration band, same signal — so watts never sit beside m/s — and never later than the anchor). `matched_total` is how many sessions matched BEFORE the 12-row window, so you can see what you are not seeing. Sessions carry per-rep `avg_signal`/`avg_hr`, `mean_signal` (unweighted mean of the reps), `fade_signal` (last rep minus first, signed), `hr_rise_bpm`+`_known` (known only when BOTH end reps carry HR), and `min_dur_s`/`max_dur_s`/`uniformity` — that last trio is each row's own spread, because whether an uneven session is "the same workout" is YOUR judgment, not the engine's. In-band errors: `no_detected_intervals`, `no_intervals_on_date`, `irregular_anchor` (the anchor's own blocks vary too much to be one repeated shape) |
| `stride progress [date] [asc\|desc] --json` | `{anchor_date, anchor_scored, groups:[{name, lens, sessions, hidden, hidden_lens, hidden_scope}]}` — `lens` is `ef`\|`speed_hr`\|`rpe` (sport-aware); each session carries a `score` in that lens. Bare = latest analyzed workout; `desc` lists newest first without changing the trend. **`anchor_scored: false` means a workout anchored on that date could not be scored by its group's lens, so it is absent from that group's `sessions[]` and the trends exclude it** — do not read the trend as covering the session you asked about. In-band errors: `no_workout_on_date`, `unscorable`, `no_scorable_workouts` `hidden` is how many sessions of that workout are NOT in `sessions`, withheld either by the group's distance SCOPE (auto-named groups match by distance) or by its LENS (EF needs power+HR, speed/HR needs distance+HR, RPE needs a rating). Read `sessions` as the whole history ONLY when `hidden` is 0 — a group holding one session with `hidden: 10` is a workout done eleven times, not once. `hidden_lens` and `hidden_scope` split it by cause and sum to it. The LENS half is USUALLY the fixable one — the session is in this workout's history and the lens cannot score it, so supplying what it needs (a power stream, a heart-rate strap, a rating) normally brings the row into the table. The exception is a session that already carries the field but records an impossible value: an average heart rate outside 35–220 bpm is refused by the EF and speed/HR lenses, and no amount of wearing the strap changes that, because the strap was worn — the reading is broken. Before telling the athlete to go fix their kit, read `avg_hr_scored` on the `progress` sessions — that is the number the lens divided by, and from #311 it is the in-band mean of the session's HR stream whenever one spans at least half the longer of its own extent and the session's moving time. A stored `avg_hr` outside 35–220 is therefore NOT sufficient to conclude the row was refused: if the stream is good the row scores anyway, and the two fields will disagree. It is when `avg_hr_scored` itself is out of band that the lens refused — which happens when there was no usable stream to fall back from. For rows missing from `sessions[]` entirely, `stride activities --json` gives you ids to work from and now carries `avg_hr_scored` too (#319), so one call narrows it: an `avg_hr_scored` outside 35–220 means those lenses refused the row. NOT the converse — they also need a normalized-power `load_model` (EF) or distance and moving time (speed/HR), so 45 sessions sit inside the bound and are refused anyway. An in-band reading is necessary, not sufficient. A LARGE gap between the two HR fields says Strava's summary came off a lossy stream; any gap does not, since 669 of 738 rows differ by a stored decimal and only 11 by more than 15 bpm. `progress` gives a count and no ids. If `avg_hr` is already present and implausible, the remedy is repairing or deleting that activity, not equipment. `stride activity <id>`'s `baselines.ef` refuses such a row — `known: false` with `current: 0` — so an absent EF there is corroboration that the reading is broken rather than a verdict about fitness (#305). Corroboration about `avg_hr_scored`, not about `avg_hr`: a session with an impossible stored reading and a healthy stream publishes a normal EF, and that is correct. Note it does NOT tell you which: `hr_known` and `power_known` both still read true on that payload, so an impossible heart rate and a genuinely missing signal look the same. Check `avg_hr` yourself. The SCOPE half is not fixable and is not about the same training: those sessions belong to a different distance bucket of the same auto-named workout. Branch on the split, not on the total. |

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
  carry a `_known` flag (`decoupling_known`, `form_delta_known`, `hr_drift_known`,
  `rec_drop_known`, and `form_tsb_known` in `analyze`) — trust the flag, never the
  magnitude. The rule is PER PAYLOAD, not per field name: `summary` ships `form_tsb`
  bare because it is always computable there. Read the schema for the command.
  `progress` sessions carry only `decoupling_known` and no other flag on purpose: rows exist only
  because the group lens scored them.
- Zone seconds are **HR-based** (universal across sports). Power feeds TSS/NP, and
  pace feeds the intensity split for any DISTANCE sport without power (a pool swim
  qualifies -- only a distance stream is needed, not GPS or altitude).
- Load ladder for ENDURANCE sports: stream-NP → Strava weighted watts → avg watts →
  **pace (rtss)** → hrTSS (zone-weighted) → avg-HR → **session-RPE** → relative_effort.
  Strength-class sports rank session-RPE ABOVE heart rate (`Sports.class`, ADR 0003) —
  the athlete is the better sensor there. It is a mixed model, not "TSS"; `load_model`
  on each row records which rung scored it.
- **FTP is DERIVED, never configured.** Per sport, per activity era: best 20-min power
  × 0.95 over the 60 days up to each activity (`summary.ftp` = `{best_20min_w_60d,
  estimated_ftp_w}` for rides). the `ftp` / `ftp_<sport>` config keys are REFUSED with
  error code `derived_key` — there is nothing to fix when FTP moves; INTERPRET the
  trajectory instead (a rising `estimated_ftp_w` is fitness, a falling one is
  detraining or a power-data gap — check `doctor` coverage before concluding).
- **Metric recompute triggers (the invalidation story):** derived-FTP change (metrics
  store `ftp_used`), derived threshold-pace change (`threshold_pace_used`, the pace
  analog, keyed per sport),
  HR-zone change, **stream arrival**, **rating change**, and
  activity-input edits (analyze compares each row's stored inputs — sync itself never
  deletes metrics). So after a sync, always `analyze` to pick up recomputes.
- CTL/ATL/TSB are **as of today** (daily_load extends through today with 0-TSS rest
  days), so `form_tsb` is current — no mental decay adjustments needed. "Today" is the
  LOCAL day, anchored by config **`timezone`** (IANA, e.g. `America/Chicago` — DST-correct
  automatically; preferred) or a fixed **`utc_offset_minutes`** fallback (e.g. -300);
  precedence is timezone > offset > UTC. Without either, users west of UTC get a phantom
  "tomorrow" row each evening — `doctor` shows which anchor is active.
- **Session-RPE**: after a strength/HIIT/yoga session, ask the user how hard it felt
  (1-10) and run `stride rate <activity_id|latest> <n> --json` — load = hours × RPE × 10
  (TSS-commensurate). For strength-class sports the rating outranks HR in the load
  ladder; for endurance, measured power/HR outrank it. Rating an activity
  invalidates its metrics (re-`analyze` rescores). Ratings live in their own table
  and survive re-syncs.
- Junk HR (outside 35–220 bpm) is filtered at analyze time for stream SAMPLES, so sessions with bad straps
  (common on Peloton strength workouts) get near-0 TSS — that's honest "no data", not
  zero effort. Weigh strength by session count, not TSS. `avg_hr` in `activities` output
  is raw (unfiltered).
- The same 35–220 bound is applied again at REPORT time by four consumers, each with a different consequence. TWO of them apply it to `avg_hr_scored` — the mean of the session's in-band HR stream when the surviving samples span at least half the LONGER of the stream's own extent and the session's moving time, the stored average otherwise (#311). Those two are `progress`'s lenses and `activity`'s `baselines.ef`. The other two read the STORED `avg_hr`: `top hr` bounds that column by design (#315), and the load ladder's `hr_avg` rung reads it — a rung reachable only when the stream yields no zone seconds, which FORCES `avg_hr_stream` to be NULL as well — one way, not both: a stream can yield zone seconds and still be too short to produce a mean — so the ladder can never divide by a number that differs from `avg_hr_scored`. So a session whose stored reading is impossible can still be scored, from its stream, and one whose stream is a dead strap's first few minutes is refused even though its stored reading looks fine. `progress`, `activity` and `activities` all publish `avg_hr_scored` beside `avg_hr` (#319), so the divisor behind any EF verdict is readable rather than inferred. `progress` counts the refused session in `hidden_lens` and omits it from `sessions[]`, while the HUMAN table still shows the row with its lens cells blank and the columns that never needed a heart rate filled (#286) — so the agent reads `hidden_lens` and the athlete sees the ride. `activity` publishes `ef.known: false` with `ef.current: 0`. The load ladder falls to its next rung and names it in `load_model`, so this one DOES change TSS — it is the consumer that propagates, into CTL, ATL and every form verdict. `top hr` does not rank the reading at all: it is absent from that list — but its absence is NO LONGER corroboration that a reading is broken, because it bounds the stored value while the lenses score the corrected one, so a session the engine RESCUED (EF published, load scored from its stream) is missing from `top hr` too. Check `avg_hr_scored` rather than reading absence there. A refused reading's id is not recoverable from the JSON, and if every reading is out of band the list comes back EMPTY — `{"data":[]}` reads as "never recorded a heart rate" for an athlete who has 672 of them. To find the broken sessions themselves use `stride activities --json` and look for an **`avg_hr_scored`** under 35 or over 220 AND `hr_known: true` — that is the field the lenses divide by, and testing `avg_hr` instead stopped identifying refused rows the moment the engine began scoring from streams (a session can store 18 bpm and score fine). The `hr_known` half is what separates a broken reading from a session that simply never wore a strap: on the reference database 69 rows are out of band and only 3 of them recorded anything, so without it you report 23 times too many and tell the athlete to repair activities that need equipment instead. A LARGE gap between the two fields is a further signal — Strava computing its summary from a lossy stream — but any gap is not: 669 of 738 rows differ, almost all by a rounded decimal, while only 11 differ by more than 15 bpm. `plan` echoes the raw `avg_hr` only, and `activity` publishes it beside `hr_known: true`.
- `created_at` in planned sessions is an ISO datetime string (UTC, e.g. `2026-07-27T18:04:22Z`).
- Streams are drained by `sync` until the read budget stops it; older activities gain zone data over
  repeated syncs. `sqlite3 ~/.stride/db.sqlite "SELECT COUNT(*) FROM streams"` shows progress.

## Setup & credentials

Day-to-day: none — `stride auth` stores the Strava client id/secret and tokens in the
db, and sync auto-refreshes. `STRAVA_CLIENT_ID`/`STRAVA_CLIENT_SECRET` env vars act as
overrides if set. A locked/corrupt db surfaces as a real error, not a false
"not authenticated".

First-time on a new machine: create a Strava API app (strava.com/settings/api), then
`stride init --json` → `STRAVA_CLIENT_ID=... STRAVA_CLIENT_SECRET=... stride auth`
(browser paste flow, interactive — the one command you run WITHOUT `--json`) →
`stride config set hr_z1_max..hr_z4_max --json` (+ `timezone`, IANA) →
`stride sync --json` → `stride analyze --json`. Each step's failure is an envelope
you can branch on (`not_authenticated`, `missing_config`), which is the point of
flagging a setup chain. The db self-migrates on any command, so upgrading the binary against
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
optimized backend was miscompiling (issue #32, fixed on the 2026-08-17 pin; dev is now
kept for build time). Roc gotcha that keeps recurring: floats have
no Eq — never `x == 0.0` in an expect; use `(x).abs() < 0.001` (`Num.abs` does not exist). Compiler syntax/stdlib
reference: `docs/roc-new-compiler-notes.md`.
