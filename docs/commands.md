# Command reference

One section per command, with the behaviour you need to use it correctly.
The [README table](../README.md#commands) is the index; this is the detail.

`STRIDE_FORMAT=json stride --help` is emitted from `Command.specs`, whose verbs e2e
pins against the parser's own list. That is the authoritative set; this file explains what the commands *mean*.

## Setup (once)

### `stride init`

Creates `~/.stride/db.sqlite` and runs migrations. Idempotent — safe to re-run anytime.

### `stride auth`

One-time Strava OAuth: prints an authorize URL, you paste back the `code=` param. Stores tokens _and_ client credentials in the db — no env vars needed afterward.

### `stride config`

Lists the config that is set, with secrets redacted. Bare `config` shows only keys
holding a value, which is what `just schema-check` selects on.

### `stride config set <key> <val>` / `stride config get <key>`

Your numbers: HR zone bounds `hr_z1_max`…`hr_z4_max`, `units` (metric or imperial), and either `timezone` (IANA, DST-aware) or `utc_offset_minutes` (fixed) to anchor "today". FTP is **not** configured — each sport derives its own from your power history.

### `stride config unset <key>`

Removes a key outright. Reports `removed: false` when the key held no value, so the
command is safe to re-run and a no-op is visible rather than silent. This is the way
out for a row the engine no longer reads — `config set <key> ""` does NOT remove a key
(#276); an empty value is refused for every key class.


## Data (daily)

### `stride sync`

Pulls new activities + the next batch of HR/power streams. Re-pulls a rolling 30-day window so edits made on Strava self-heal. The fast daily command.

`--all` forces a full re-list from scratch rather than the rolling window — a dev escape hatch, not part of the daily loop.

### `stride rate <activity_id|latest> <1-10>`

_How hard did it feel?_ Session-RPE (Borg): you are the sensor for strength, HIIT, and yoga. `load = hours × RPE × 10`, so an hour at RPE 10 = 100, TSS-comparable. For strength-class sports your rating outranks HR; for endurance, measured power/HR always win.

### `stride import <zip|dir>`

Loads a **Strava account export** (the ZIP from Settings → My Account → Download or Delete Your Account) — **no API credentials or subscription needed**. Summary-level data (no streams yet, so zone breakdowns stay honestly absent); re-import is idempotent. English-language exports only.

### `stride analyze`

Computes metrics for new (or invalidated) activities — TSS, time-in-zone, normalized power — then rebuilds the daily fitness/fatigue/form series through today. Prints what it did plus a one-line form verdict.


## Reading your training

Each answers a different question.

### `stride summary`

_Where do I stand today?_ Form (with verdict), 7-day and 28-day zone mix + polarization, your derived FTP and the 20-min best behind it, date of your last hard session, per-sport breakdown.

### `stride activities [n] [sport]`

_What did each session actually contain?_ Last _n_ sessions (default 30), optionally filtered by sport family (human words widen: `bike` = Ride/VirtualRide/GravelRide/MountainBikeRide, `run` = Run/VirtualRun/TrailRun; e-bikes excluded; other sport_types filter exactly) (`activities 10 rowing`). Per session: load, intensity vs FTP, and minutes actually spent hard — measured against the sport's threshold by _power_ where power exists, else by the _pace_ split where a threshold speed exists, else HR Z4+Z5.

### `stride top <metric> [n] [sport]`

_What were my best sessions?_ Ranks activities (default top 10) by a metric — `hr`, `tss`, `power`, `intensity`, `distance`, `time`, or `output` (kJ) — optionally filtered by sport (`top tss 5 ride`). The leaderboard to `activities`' timeline.

### `stride doctor`

_Can I trust my data?_ Coverage (HR/power/streams/ratings), how each activity was scored and the **measured-vs-estimated confidence split**, config gaps (HR zones), streams still pending, and the active time anchor. Every gap says what, why, and the fix.

### `stride zones` (alias `stride pz`)

_What watts is each power zone for me?_ The 7 Coggan/Peloton power zones as watt ranges derived from your FTP (they shift when FTP changes). The targets you'd set on a Power Zone ride.

### `stride reps [date]`

_Am I riding the same workout harder?_ One level below `progress`: the anchor session's detected interval blocks beside the same-shaped blocks of earlier sessions — per-rep watts, the within-session fade, and the first-to-last HR rise. Comparability is stated in the payload rather than assumed: same sport family, same rep count, same rep-duration band, same signal, never later than the anchor. Each row also reports its OWN rep spread, because whether an uneven session counts as "the same workout" is a judgment stride leaves to you. A session whose blocks vary too much to be one repeated shape is refused as an anchor rather than compared against.

### `stride progress [date] [asc|desc]`

_Am I improving on this workout?_ Every past instance of a workout, compared with a
**sport-aware lens** — Efficiency Factor (NP ÷ HR) for power rides, speed ÷ HR for
distance sports, RPE for rated strength/HIIT — with a trend verdict and last-vs-best.

A session with detected interval structure is grouped by SHAPE — reps' mate predicate
plus its anchor uniformity gate — so the trend finds the workout under any class name
and excludes different workouts sharing one. Sessions without structure, or too
irregular to be one repeated shape, group by name instead.

Name-side matching: exact-named workouts compare every instance. Auto-named sessions
(Morning/Lunch/Afternoon/Evening/Night, any sport) compare only within ±10% of the
anchor distance, and an auto-named anchor with no distance recorded shows alone.

Bare `progress` uses your latest session. Sessions list oldest-first (`asc`, the
default) so the trend reads left to right; `desc` puts the newest first when you only
want the last few. The verdict is computed chronologically either way.

### `stride load [days]`

_Is my training working over time?_ Daily fitness/fatigue/form rows for windows ≤14 days; Monday-aligned **weekly rollups** (sessions, load, fitness trend) for longer windows (default 90). Ends with today's form verdict. The rollup is a _rendering_ — `--json` is always the daily series.

### `stride compare [week|month]`

_Is this period better than the last?_ The last rolling window (7 or 28 days) beside the one before it — load, sessions, hard minutes, easy %, and end-of-window fitness — with signed deltas and a ramp/fitness verdict.

### `stride activity <id>`

_How did one session actually go?_ Deep view of a single activity: load, intensity, zone minutes, hard time, and power bests (1/3/5/20 min) computed from its streams. The session-review tool.

### `stride power-curve [days] [sport]` (alias `stride pc`)

_What's my power at every duration?_ The power-duration curve — best watts held for 5 s through 60 min across a window (default 90 days), across every power sport unless you name one — with a **Critical Power / W′** fit: your sustainable aerobic ceiling and the finite battery above it. Reads the stored per-activity bests; the shape behind FTP.

### `stride pace-curve [days] [sport]` (alias `stride cs`)

_What's my pace at every duration?_ The pace twin of the power curve — best grade-adjusted speed held for 5, 10 and 20 min across a window (default 90 days), with a **Critical Speed / D′** fit: the sustainable ceiling and the finite DISTANCE spendable above it, where W′ is an energy. Name a sport — a pool swim and a trail run do not share a speed model, so there is no combined curve to draw.

### `stride season`

_What has my training actually looked like, block by block?_ (the whole history, not a calendar year) Training blocks, monthly load, polarization and FTP over time. A block is a run of training weeks closed by two or more weeks off — the only boundary in the data that is not a judgment call — and each one is described by its measured load trend rather than labelled a phase. See ADR 0011.

### `stride tte <watts>`

_How long could I hold this?_ Time to exhaustion at a power you name, from a Critical Power model fitted on your **ride** history over the trailing 90 days, from the 5/10/20-minute bests on record. (Not identical to `power-curve`'s fit: that one spans every power sport and includes today; this one is rides-only and excludes today. `tte` takes no sport argument.) Every answer carries what qualifies it: which band of the model it falls in, and the longest effort at or above that power you already have on record — when the model predicts less than your own file proves, it says so.

### `stride stats`

_What have I done, ever and this year?_ Career and year-to-date totals per sport: sessions, hours, distance.

## Coaching log

The adaptation loop.

### `stride plan`

_What should I do next?_ One call bundling `summary` + every open session + the last 14 days of activities — the complete planning context.

### `stride week` / `stride week all`

_What was planned, and did it happen?_ `week` is the current training week (Mon–Sun). `week all` sections the log — **upcoming**, **this week**, **last week** — and counts anything older rather than hiding it; the JSON payload always carries every row. Status is open / done / skipped, and a session completed on a different day than planned shows that date.

### `stride week add <date> <type> <detail> <rationale> [target]`

Records a planned session. `type` is the intensity intent (vo2max, threshold, endurance, recovery, strength, rest); the sport goes in `detail`. The optional target is a strict `<reps>x<mm:ss>@<watts>W` literal (`3x12:00@230W`, ADR 0014) stored beside the prose — completing a targeted session then reports the recorded numbers beside the detected shape, arithmetic with no verdict. Re-planning a date revises its open session in place rather than stacking a second row; omitting the target on a re-plan clears it. Refuses a bad date (`bad_date`) or a malformed target (`bad_target`).

### `stride complete <id> [activity_id]`

Marks a planned session done, linked to the activity that fulfilled it. Only a REST session may be completed bare — anything else raises `activity_required`, because done means evidence. Refuses ids that don't exist.

### `stride skip <id> <reason> [activity_id|none]`

Marks a planned session skipped, with the reason — optionally linking the activity done instead (rendered `→ id` in `week`). Adherence history stays honest either way; a bare re-skip keeps an existing link; pass a new id to change it or `none` to release it. A done session refuses skip — re-complete to fix a mis-link.

### `stride event add <date> <name>` / `stride event remove <id>` / `stride events`

Event targets (judgment tier, removable — a target is not a record of training). `events` projects CTL/ATL/TSB onto each event date: the same recurrence `daily_load` runs, folded forward over the open plan's structured targets — deterministic arithmetic per ADR 0010, never a proposed plan. Untargeted sessions contribute zero and are counted, so the projection's blindness is stated. Refuses past or malformed dates (`bad_date`), unknown ids (`event_not_found`).

### `stride project <date> [plan]`

_If the plan is executed as written, where is my form on date D?_ CTL/ATL/TSB on any horizon, by the same recurrence `daily_load` runs — over the recorded open plan, or over a hypothetical plan the caller passes (`date=target` pairs) which replaces it in the walk, is echoed back (dates verbatim, targets as their parsed canonical fields), and is never stored (ADR 0010). Compare tapers by calling once per candidate; stride never solves for the plan that reaches a target.

### `stride relabel <id> <type> <detail> [rationale]`

Fixes a session's label — any status, done ones included. Edits only the descriptive fields: status, activity links and metrics never move, and `analyze` after a relabel recomputes nothing. The day-swap fix: a completed session whose label still describes the plan it displaced no longer needs a duplicate row or hand-run SQL. Omitting the rationale keeps the stored one.


