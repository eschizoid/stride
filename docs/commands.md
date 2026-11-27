# Command reference

One section per command, with the behaviour you need to use it correctly. Closely
related subcommands share a section — `config set` with `config get`, `week` with
`week all` — so the count of sections is smaller than the count of commands.
The [README table](../README.md#commands) is the index; this is the detail.

`STRIDE_FORMAT=json stride --help` is emitted from `Command.specs`, whose verbs e2e
pins against the parser's own list. That is the authoritative set; this file explains what the commands *mean*.

## Setup (once)

### `stride setup [key=value]`

The whole first run in one command, and it resumes wherever a previous run stopped: it creates the database, guides the Strava API app (callback domain `localhost`) and stores its client ID and secret, opens the authorize page and receives the code on a local port (or takes the pasted address), confirms the detected timezone, lists the activities, and proposes the four heart-rate zone bounds from them: the maximum heart rate is the second-highest of the sessions' maxima, so a strap spike in one session is set aside (setup names the value), and the bounds come from it as below. The athlete accepts them, or types a threshold or max HR; with no heart-rate data setup asks for one number. The bounds are 85, 89, 94 and 99 % of threshold HR; a max HR is first turned into an estimated threshold of 90 % of max, so both inputs give one zone system. Then it runs the first sync to its end, waiting for Strava's read windows as `stride sync` does, and shows `doctor`. With `--json` it never prompts or waits: each call reports the next step, whether it needs the athlete at a browser, and the values it takes, and `stride setup <key>=<value>` supplies one (`client_id`, `client_secret`, `code`, `timezone`, `threshold_hr` or `max_hr`). A call with no value runs a step that needs none: the activity list, or one read window of the first sync, answered with the fetches still `owed` and `resume_at`, the time the next call can continue. At the zones step `max_hr_proposed` and `zone_bounds_proposed` carry the proposal, accepted with `stride setup max_hr=<max_hr_proposed>`.

### `stride init`

Creates `~/.stride/db.sqlite` and runs migrations. Idempotent — safe to re-run anytime. `stride setup` does this as its first step; `init` alone is for a database filled from a Strava export with `stride import`, which needs no Strava connection.

### `stride auth`

One-time Strava OAuth: prints an authorize URL, you paste back the whole address the browser landed on (or just its `code=` value). Stores tokens _and_ client credentials in the db — no env vars needed afterward. `stride setup` runs this step on a first run and skips it once tokens are stored, so `auth` on its own is how an athlete authorizes again, for example after revoking the app on Strava.

### `stride config`

Lists the config that is set, with secrets redacted. Bare `config` shows only keys
holding a value, which is what `just schema-check` selects on.

### `stride config set <key> <value>` / `stride config get <key>`

Your numbers: HR zone bounds `hr_z1_max`…`hr_z4_max`, `units` (metric or imperial), `strength_log_weight` (`per_hand`, the default, or `total` when you enter a dumbbell pair's combined weight in Strava's strength log), and either `timezone` (IANA, DST-aware) or `utc_offset_minutes` (fixed) to anchor "today". FTP is **not** configured — each sport derives its own from your power history.

### `stride config unset <key>`

Removes a key outright. Reports `removed: false` when the key held no value, so the
command is safe to re-run and a no-op is visible rather than silent. This is the way
out for a row the engine no longer reads — `config set <key> ""` does NOT remove a key
(#276); an empty value is refused for every key class.


## Data (daily)

### `stride sync`

Lists new and changed activities, then fetches the streams, strength descriptions and GPS routes still missing, and analyzes as they land, so it ends with everything analyzed and prints the form verdict. Re-lists a rolling 30-day window so edits made on Strava self-heal; a first sync lists the whole history first and analyzes it before any stream. Paced to the limits Strava reports in `X-ReadRateLimit-Limit` (documented as 100 a quarter-hour and 1,000 a day; Strava raises them per app on request; a report past ten times those is held to it), less a margin of five percent and never fewer than five reads, with its own count of every read, kept in the database across runs and checked before each read so no run passes them, raised to the usage Strava reports in `X-ReadRateLimit-Usage`: when the 15-minute read window is spent it waits for the next one, which opens at :00, :15, :30 or :45 past the hour, showing the local time the next batch starts; when the day is spent it waits for the daily allowance at midnight UTC the same way, with the hours and minutes left. It waits only while activities it already holds owe streams, descriptions or routes; when nothing but the activity list is owed and the window or the day is spent, it ends at once and names the local time it opens. Ctrl-C stops it, and the next sync resumes where it stopped. A period still spent when its wait ends (another app on the token spending it) ends the run after that one wait, naming the situation and the local time the allowance returns. With `--json` it never waits: it does what the window allows and answers with what is still owed and `resume_at`, the time the next call can continue. A routine sync owes less than a window and takes seconds.

`--all` re-reads the whole Strava history from scratch rather than the last 30 days — rarely needed, and not part of the daily loop.

### `stride rate <activity_id|latest> <1-10>`

_How hard did it feel?_ Session-RPE (Borg): you are the sensor for strength, HIIT, and yoga. `load = hours × RPE × 10`, so an hour at RPE 10 = 100, TSS-comparable. For strength-class sports your rating outranks HR; for endurance, measured power/HR always win.

### `stride test <activity_id> <kind> [--apply-zones]`

_That was a test._ Marks a session the athlete did all-out on purpose, and stores the threshold it yields (ADR 0020). `ftp20` (20 minutes all-out, × 0.95), `ramp` (75% of the best minute) and `cp3-12` (two-point critical power from all-out 3- and 12-minute efforts) set a power threshold for the session's sport family, any family with a measured power stream. `css` (all-out 400 m and 200 m, swim only) and `5k` / `3k` (run only; 94% and 90% of the trial speed) set a threshold speed for the session's sport type. `tt30` (the best 20-minute heart rate of a 30-minute time trial, any sport) measures a lactate-threshold heart rate. A test sets its population's threshold from its own date for 90 days, whenever it is higher than the 60-day derivation; the newest test wins, and past 90 days the derivation alone returns. `--apply-zones` (tt30 only) writes `hr_z1_max..hr_z4_max` for every sport type in the session's family from Friel's percentages of LTHR (85, 89, 94, 99). One test per session: marking it again with another kind replaces it. Run `stride analyze` afterwards; it rescores exactly the sessions the test moves. `summary`, `zones`, `power-curve` and `pace-curve` say when a test, not the derivation, sets the threshold.

### `stride test remove <activity_id>`

Unmarks a threshold test. The next `stride analyze` scores the sessions it covered against the derivation again.

### `stride import <zip|dir>`

Loads a **Strava account export** (the ZIP from Settings → My Account → Download or Delete Your Account) — **no API credentials or subscription needed**. Summary-level data (no streams yet, so zone breakdowns stay honestly absent); re-import is idempotent. English-language exports only.

### `stride strength import <file|->`

Stores a strength workout's sets from the JSON **Strava's MCP connector** returns (`get_strength_workout_details`). Strava's app keeps each exercise, set, weight and rep count as structured data, but its public API does not return them, so `sync` cannot fetch them; a coach with the connector fetches the JSON and hands it over as a file, or on stdin with `-`. The input is a list of workout objects or one on its own, each `{ activity_id, exercise_sets: [...] }`; `activity_id` may be a string of digits or a bare number, and a `null` field reads as absent. Each workout is decoded on its own, stored against its activity exactly as the connector wrote it (a re-import replaces it), and parsed into set rows straight away, so `stride strength` shows it without an `analyze`. Consecutive identical sets fold into one row, weights are stored per hand as entered (pounds converted to kg; under `strength_log_weight total` a pair's weight is halved: an exercise naming a dumbbell or double kettlebell is halved, one naming a barbell, machine, cable or similar one-piece implement or a deadlift, squat, leg press, pulldown or hip thrust is kept whole, and any other name is treated as a dumbbell move and halved), and a set with no weight is kept at 0 kg. A pasted `/side` weight is stored per hand too, so the same dumbbells read the same from either source. A bodyweight exercise (push up, pull up, chin up, dip, plank, sit up, crunch, burpee and similar, matched by name with case, spacing, hyphens and a trailing plural ignored, alone or with `Assisted` or `Negative` at the very front, so `Assisted Chin-Up` is one and `Weighted Pull Up` and `Band Assisted Pull Up` are not) keeps its sets and reps but counts 0 kg toward tonnage, because the connector's log can carry the athlete's own body weight on those moves; each such set that carried a weight is listed in the workout's `zeroed` entries with the weight recorded, and the stored log keeps that weight. In `stride strength` such an exercise progresses in reps rather than kilograms. For an activity that has both a stored log and a pasted description, the log is what gets parsed.

Nothing is left out silently. A set that cannot become a row is listed in its workout's `dropped` entries with its position and reason: `no_exercise_name`, `no_reps` (neither a rep count nor a duration), `bad_reps` (not a positive whole number, such as `8-10` or `0`), `bad_duration` (a duration-only set whose duration is not text, names no unit, such as a bare `60`, does not parse, or is not positive), `unknown_weight_unit` (no kg/lb/lbs, such as `44 stone` or a bare `20`) or `bad_weight` (a number that does not parse, such as `20,5 kg`, or a negative one). A workout that cannot be placed is reported as skipped with its reason, and the rest of the batch still lands: `undecodable_workout` (not a workout object the import can read), `bad_activity_id`, `duplicate_activity` (an earlier workout in the same input was already stored for the same activity; one skipped for another reason claims nothing), `unknown_activity` (sync first), `not_strength` (the activity is not a strength session), `no_sets` (an empty `exercise_sets`), or `no_usable_sets` (every set was dropped, each listed). Only a file that cannot be read (`unreadable_file`) or input that is not a JSON object or list (`bad_json`, naming what it found) fails the command.

### `stride analyze`

Computes metrics for new (or invalidated) activities — load (TSS from power, pace or heart rate, load from your rating of the session, or Strava's relative effort when there is nothing else), time-in-zone, normalized power — to its fixed point, then rebuilds the daily fitness/fatigue/form series through today. Prints what it did plus a one-line form verdict. `stride sync` runs it after every batch, so it is the command for a recompute without a sync, after a zone or rating change.


## Reading your training

Each answers a different question.

### `stride summary`

_Where do I stand today?_ Form (with verdict), 7-day and 28-day zone mix + polarization, your derived FTP and the 20-min best behind it, date of your last hard session, per-sport breakdown. Polarization (the easy/moderate/hard shares here, in `compare`, `season` and the window's zones caps) leaves out weight training, yoga and pilates, and a workout that has recorded sets, because wrist HR during lifting reads as easy time; a workout with no sets, such as a class worked by heart rate, counts. A window of lifting alone reports no shares (`polarization_known: false`) rather than 0%. The zone mix and the hard-session date still include every session; `compare`'s hard minutes sit beside its easy share and cover the same sessions.

### `stride activities [n] [sport]`

_What did each session actually contain?_ Last _n_ sessions (default 30), optionally filtered by sport family (human words widen: `bike` = Ride/VirtualRide/GravelRide/MountainBikeRide, `run` = Run/VirtualRun/TrailRun; e-bikes excluded; other sport_types filter exactly) (`activities 10 rowing`). Per session: load, intensity vs FTP, and minutes actually spent hard — measured against the sport's threshold by _power_ where power exists, else by the _pace_ split where a threshold speed exists, else HR Z4+Z5.

### `stride top <metric> [n] [sport]`

_What were my best sessions?_ Ranks activities (default top 10) by a metric — `hr`, `tss`, `power`, `intensity`, `distance`, `time`, or `output` (kJ) — optionally filtered by sport (`top tss 5 ride`). The leaderboard to `activities`' timeline.

### `stride doctor`

_Can I trust my data?_ Coverage (HR/power/streams/ratings), how each activity was scored and the **measured-vs-estimated confidence split**, config gaps (HR zones), streams and GPS routes still pending, strength sessions of the last 30 days with no sets yet (by id, so they can be imported), the active time anchor, and how close the projection's forecast has been (the check `stride project` reports). Every gap says what, why, and the fix.

### `stride zones` (alias `stride pz`)

_What watts is each power zone for me?_ The 7 Coggan/Peloton power zones as watt ranges derived from your FTP (they shift when FTP changes). The targets you'd set on a Power Zone ride.

### `stride viz`

_How do I steer the window?_ The desktop window's self-published capabilities — protocol, view numbers and names, the directive fields with what each accepts, and the staleness window — served from the database the window wrote them to at its last launch. This is the discovery source for steering (the window's own claim about itself, never a doc's copy); an install where the window has never run answers with the `no_viz_capabilities` code rather than guessing. The bus itself is documented in [viz.md](viz.md).

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

_Is my training working over time?_ Daily fitness/fatigue/form rows for windows ≤14 days; Monday-aligned **weekly rollups** (sessions, load, fitness trend) for longer windows (default 90). Ends with today's form verdict. The rollup is a _rendering_ — `--json` is always the daily series. Each JSON row also carries `families`, fitness per sport family: the same fitness/fatigue recurrence run over one family's own load and its whole history, so the families' fitness sums to the combined figure. A family is listed only when it has load inside the window, and only from its first loaded day, so a missing family is absent rather than a zero series that reads as detraining. Form stays the combined series' alone.

### `stride compare [week|month]`

_Is this period better than the last?_ The last rolling window (7 or 28 days) beside the one before it — load, sessions, hard minutes, easy %, and end-of-window fitness — with signed deltas and a ramp/fitness verdict.

### `stride review [week|YYYY-MM-DD]`

_How did the week go?_ One Monday-to-Sunday week in one call, across every sport: each planned session with how it went on its own target (the fields `complete` reports), the activities no session claims, planned beside actual load per day, the easy/moderate/hard split and the hard days, a row per sport family, strength sessions with and without sets or a rating, and fitness at both ends of the week. A date picks the week holding it. It states measurements only; whether the week went well is the coach's call.

### `stride activity <id>`

_How did one session actually go?_ Deep view of a single activity: load, intensity, zone minutes, hard time, and power bests (1/3/5/20 min) computed from its streams. The session-review tool.

### `stride power-curve [days] [sport]` (alias `stride pc`)

_What's my power at every duration?_ The power-duration curve — best watts held for 5 s through 60 min across a window (default 90 days), across every power sport unless you name one — with a **Critical Power / W′** fit: your sustainable aerobic ceiling and the finite battery above it. Reads the stored per-activity bests; the shape behind FTP. The JSON also carries **durability**: for 300 s and 1200 s, the best any session held after it had already done 500, 1000 or 2000 kJ of work, beside the window's fresh best and their ratio, with `known: false` where no session in the window reached the threshold. Work is counted from the measured power stream, so a pause adds none and a ride on estimated watts never reaches a threshold. With a sport named, the JSON also carries `ftp_w`, that sport family's FTP today in whole watts (the 60-day derivation raised to a marked test in force, the number `stride zones` reports for rides), and `ftp_source`, `test` when the test in force set it and `derived` otherwise; with no sport named they are 0 and `derived`.

### `stride pace-curve [days] [sport]` (alias `stride cs`)

_What's my pace at every duration?_ The pace twin of the power curve — best grade-adjusted speed held for 5, 10 and 20 min across a window (default 90 days), with a **Critical Speed / D′** fit: the sustainable ceiling and the finite DISTANCE spendable above it, where W′ is an energy. Name a sport — a pool swim and a trail run do not share a speed model, so there is no combined curve to draw. Its JSON carries the same **durability** readout as the power curve's, with time in motion for the work: the best 300 s and 1200 s speed held after 30, 60 and 90 moving minutes, beside the fresh best. It also carries `threshold_speed`, the sport family's threshold speed today in m/s (the 60-day derivation raised to a marked pace test in force), and `threshold_source`, `test` or `derived` by the same rule; with no sport named they are 0 and `derived`.

### `stride season`

_What has my training actually looked like, block by block?_ (the whole history, not a calendar year) Training blocks, monthly load, polarization and FTP over time. A block is a run of training weeks closed by two or more weeks off — the only boundary in the data that is not a judgment call — and each one is described by its measured load trend rather than labelled a phase. See ADR 0011.

### `stride strength`

_Am I getting stronger?_ Per-exercise top-set progression — the first and latest day each repeated exercise was lifted, from the sets stored by `strength import` or pasted into strength sessions' descriptions — beside monthly tonnage, each figure with its coverage stated (`3 of 7 sessions` carry sets, and a month under a third coverage claims no tonnage at all). Tonnage is volume, not strength: it falls when pull work gives way to isolation whatever happened to capacity, which is exactly the misreading the per-exercise series exists to prevent. Sessions with nothing to parse are counted out loud, and the report says how to change that. An exercise whose every day moved 0 kg (a bodyweight move, which counts 0 kg toward tonnage whether it came from an imported Strava log or a pasted description) is measured in reps instead: its first and latest days show the most reps in one set, and the JSON marks it `measure: "reps"` with `top_reps` and `total_reps` on each point. A pasted description keeps a bodyweight line only when it names a weight above zero in lb or kg, and then keeps its sets and reps at 0 kg; nothing lists those sets the way `zeroed` lists imported ones. An exercise with any loaded day reads its weights in the `units` config's unit at the precision they were entered at (whole when whole, a half when half, so a 12.5 lb dumbbell reads 12.5 lb), and with `units` unset in the unit most stored weights were entered in (a weight on the half-pound grid and off the half-kilogram one counts for pounds, the reverse for kilograms, one on both or neither counts for neither, and a tie or no evidence reads metric), the rule the window's lifts tab reads; monthly tonnage reads in tonnes or thousands of pounds the same way. The JSON stays in kg. A hold, an isometric set logged with a duration and no reps (an imported set such as `1m 0s` at 9.1 kg, or a pasted `3 × 30 sec • 20 lbs`), is kept with its sets, weight and seconds held, and counts no reps and no tonnage. It is reported as its own entry beside the same exercise's rep sets, marked `measure: "hold"`: its first and latest days show the longest hold and that hold's weight (`60 s @ 9.1 kg`), and each point carries `top_hold_s` and `total_hold_s`. A pasted per-side hold (`30 sec/side`) counts each side's hold as its own set. Each day of a rep exercise also carries an **estimated one-rep max** in the JSON (`e1rm_kg`), by Epley (weight × (1 + reps / 30), a single counting as its own weight), from whichever of the day's sets gives the highest estimate, with `e1rm_reps` naming that set's reps. It rises when reps rise at a fixed weight, where the top set stays flat. A set of more than 10 reps gives no estimate, since rep-max formulas stop tracking maximal strength there, and neither does a set at 0 kg, so a bodyweight day, a high-rep day and a hold carry `e1rm_known: false` rather than a number. Weights are per hand as stored, so a dumbbell estimate is per hand too.

### `stride tte <watts> [sport]`

_How long could I hold this?_ Time to exhaustion at a power you name, from a Critical Power model fitted on one whole sport family's history over the trailing 90 days, from the 5/10/20-minute bests on record. With no sport it is the ride family. A family word (`rowing`, `bike`) and any Strava spelling in the family (`VirtualRow`) both select the whole family, in any case; a sport outside every family (`kayaking`) selects the sessions stored under that sport, also in any case. That differs from `power-curve`, which widens a family word to its family but filters a Strava spelling to that spelling alone, spans every power sport when you name none, and includes today; `tte` always fits a whole family and excludes today. Every answer carries what qualifies it: which band of the model it falls in, and the longest effort at or above that power the family already has on record — when the model predicts less than your own file proves, it says so.

### `stride tte pace <pace> <sport>`

_How long could I hold this pace?_ The critical-speed twin, for pace sports: time to exhaustion at a pace you name, written the way a pace target is (`4:10/km`, `6:45/mi`, `1:40/100m`, `1:55/500m`), from the Critical Speed / D′ fit `stride pace-curve 90 <sport>` prints for that one sport (same window, today included, never pooled across a family). The sport is required for the reason `pace-curve` needs one. The answer carries the same qualifiers as the power form, with critical speed also given as seconds per the unit you used.

### `stride stats`

_What have I done, ever and this year?_ Career and year-to-date totals per sport: sessions, hours, distance.

## Coaching log

The adaptation loop.

### `stride plan`

_What should I do next?_ One call bundling `summary` + every open session + the last 14 days of activities — the complete planning context — plus what is still owed: activities awaiting metrics or streams, and recent strength sessions with no sets yet.

### `stride week` / `stride week all`

_What was planned, and did it happen?_ `week` is the current training week (Mon–Sun). `week all` sections the log — **upcoming**, **this week**, **last week** — and counts anything older rather than hiding it; the JSON payload always carries every row. Status is open / done / skipped, and a session completed on a different day than planned shows that date. A week is Monday to Sunday and holds what was done on its days beside what was planned: `week` lists each activity of the week that no session claims yet, with status `unlinked`, and `week all`'s this-week and last-week sections list theirs the same way, as does the window's week tab; `stride complete` or `stride skip <id> <reason> <activity>` links one to a plan day. In `week`'s JSON that row's `status` is `unplanned` and its `status_shown` is `unlinked`; `week all`'s JSON is the session log alone. A week or section with nothing in it says so and names what fills it. With no activity on record at all, every report on your activities says to run `stride setup`, on its screen and in the message of any error it returns, and with activities that `stride analyze` has not scored yet `summary`, `plan`, `compare`, `season`, `progress` and `load` name `stride analyze`. In the JSON an empty list stays empty, and an error envelope keeps its code and carries the same sentence as its message.

### `stride week add <date> <type> <detail> <rationale> [target]`

Records a planned session. `type` is the intensity intent (vo2max, threshold, endurance, recovery, strength, rest); the sport goes in `detail`. The optional target is a strict `<reps>x<rep>@<signal>` literal on any signal (ADR 0014, ADR 0019), stored beside the prose: power `3x12:00@230W`, a heart-rate band `1x60:00@HR125-147`, an HR zone `1x90:00@Z2`, a session rating `1x45:00@RPE6` (1-10, any sport), or a pace `5x4:00@4:10/km`, `3x10:00@6:45/mi`, `10x100m@1:40/100m`, `6x500m@1:55/500m`. A non-power rep may be `h:mm:ss`, and a pace rep may be a distance. Completing a targeted session then reports the recorded target beside what the activity did on that signal, arithmetic with no verdict. Re-planning a date revises its open session in place rather than stacking a second row; omitting the target on a re-plan clears it. Refuses a bad date (`bad_date`), a malformed target (`bad_target`), or a zone target before the HR zones are set (`missing_config`).

### `stride complete <id> [activity_id]`

Marks a planned session done, linked to the activity that fulfilled it. Only a REST session may be completed bare — anything else raises `activity_required`, because done means evidence. Refuses ids that don't exist. On a targeted session the payload states the execution on the target's own signal: detected power work against target watts; seconds under, inside and over a heart-rate band from the HR stream; seconds below, inside and above an HR zone from the stored zone split; the actual pace per the target's unit, read over the detected work reps' windows from the distance stream (the detector's own signal is grade-adjusted), else as distance over moving time; or the activity's stored session rating. `exec_known` is false, with `exec_reason` naming why, when the activity carries no such signal (a rating included: `stride rate` stores one) or the pace unit belongs to another sport family.

### `stride skip <id> <reason> [activity_id|none]`

Marks a planned session skipped, with the reason — optionally linking the activity done instead (rendered `→ id` in `week`). Adherence history stays honest either way; a bare re-skip keeps an existing link; pass a new id to change it or `none` to release it. A done session refuses skip — re-complete to fix a mis-link.

### `stride event add <date> <name>` / `stride event remove <id>` / `stride events`

Event targets (kept only in your database, removable — a target is not a record of training). `events` projects fitness, fatigue and form onto each event date: the same recurrence `daily_load` runs, folded forward over the open plan — deterministic arithmetic per ADR 0010, never a proposed plan. Every target kind is priced on the rung analyze scores by (ADR 0019): power as TSS against the FTP of the power family trained most (most sessions with a 20-minute power best in 90 days, falling back to the next family with an FTP), pace as rTSS against the 60-day threshold speed of its sport family (pooled over the family; of the families a unit names, run before walk, the first whose threshold puts the target between 0.45 and 1.5 intensity; analyze prices the finished session against its own sport type, so treadmill, trail or virtual sessions can differ), a heart-rate band or zone as hrTSS, a session rating as session-RPE load. Every other day is filled from the athlete's own history and labeled (ADR 0022): a session with no target, or none its inputs can price, is estimated from the median load per hour of the last 90 days' sessions of the same planned type, else of the sport its words name, else of all, times its duration; a day with no session carries the mean daily load of the last 28 days; a `rest` session carries zero; and a day the history cannot estimate carries nothing and says so. Each event's `load_sources` counts its days by source, `unprojected` names the sessions their target could not price with the same reasons `project` gives, and the human screen states the mix in words. Refuses past or malformed dates (`bad_date`), unknown ids (`event_not_found`).

### `stride project <date> [plan]`

_If the plan is executed as written, where is my form on date D?_ CTL/ATL/TSB on any horizon, by the same recurrence `daily_load` runs — over the recorded open plan, or over a hypothetical plan the caller passes (`date=target` pairs) which replaces it in the walk, is taken as written (a day it does not name carries nothing, and nothing in it is estimated), is echoed back (dates verbatim, targets as their kind and canonical literal), and is never stored (ADR 0010). Any target kind may be passed. Each session in the window whose target adds no load of its own is listed in `unprojected` with why: no target, no FTP in any power family, no HR zones, or no threshold pace for its sport (none on record, or an intensity beyond the 1.5 bound analyze enforces). Over the recorded plan those sessions, and the days with no session, are filled from the athlete's history as `events` describes (ADR 0022). The payload's `series` is the same walk day by day (each day's load, where it came from in `load_source`, and its CTL/ATL/TSB) from the day after the baseline through the date, so its row on the date is the projection itself; only a day holding a session with nothing to estimate from says its load is not known (`load_known: false`), its load then counting only the sessions that carried one. `load_sources` counts the days by source, and the human screen states the mix, for example "32 projected days: 12 from targets, 20 estimated from your history". The form board draws this series. `forecast_check` says how close this forecast of the recorded plan has been (ADR 0022): for each of the last 8 weeks stride rebuilds what it knew at the end of that week's Sunday (the recorded days, the sessions, and the plan as it then stood, done and skipped sessions included), projects it the same way, and compares fitness, fatigue and form 7, 14 and 28 days out with what was recorded, as the mean error size, the mean error and the largest error; a distance it cannot check for every week says so and gives no number. The human screen prints the same check, and `stride doctor` prints its two-week line. Compare tapers by calling once per candidate; stride never solves for the plan that reaches a target.

### `stride relabel <id> <type> <detail> [rationale]`

Fixes a session's label — any status, done ones included. Edits only the descriptive fields: status, activity links and metrics never move, and `analyze` after a relabel recomputes nothing. The day-swap fix: a completed session whose label still describes the plan it displaced no longer needs a duplicate row or hand-run SQL. Omitting the rationale keeps the stored one.


