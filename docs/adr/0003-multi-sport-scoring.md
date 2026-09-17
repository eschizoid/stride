# ADR 0003. Multi-sport by design: score the full Strava sport space

Status: accepted (grilled + fleet-reviewed 2026-08-02)

The decision here generalizes [ADR 0002](0002-power-based-intensity.md), which made
intensity power-based and per-sport, and it also generalizes the mixed load model of
[ADR 0000 §4](0000-architecture.md). ADR 0002 made intensity per-sport for power sports.
The same principle, which is per-sport scoring with the best available model and no sport
rejected, now extends to the whole sport space, including the pace-native and HR-native
sports that ADR 0002's power model does not serve.

The decision also reverses ADR 0000 §10, which listed "a generic every-sport model" as
deliberately out of scope and revisited only when dogfooding demands it. Dogfooding demands
it now, because friends run and swim, so §10 is updated in the same commit. The single-user
and local-first boundary of §1 is untouched, as the scope boundary below records.

## Context

The engine is meant to serve all sports, and the need behind that is concrete. The
athlete's friends train sports the current engine cannot score honestly, because they run
and swim, and because they do "everything Strava captures", including soccer, basketball,
tennis, hiking and climbing. Each friend owns their own data, so this is not a
multi-athlete request, as the scope boundary below records.

What the code did when this ADR was written is recorded below, verified on 2026-08-02.
Every item in the list is now history, and the amendment after the list records what
replaced it.

- The load ladder was `power → HR → session-RPE → relative-effort` in `Metrics.tss_ladder`,
  and there was no pace rung. Running and swimming without a power meter, which is the
  common case, fell straight to hrTSS and were scored by the metric that misreads them,
  because HR lags on intervals and is depressed in water.
- GAP was dead code. `Metrics.grade_adjusted_distance`, `minetti_ratio` (Minetti 2002) and
  `Streams.dist_alt_pairs` were built and expect-tested but had zero call sites.
- HR zones were global. One `ZoneBounds`, holding four `hr_z*_max` keys, covered every
  sport, and there was no per-sport LTHR, which is physiologically wrong across bike, run
  and swim for one athlete.
- Cycling favoritism leaked through the "generic" layer, because `ftp_ride` was hardcoded
  in the zone-config bundle (`Analyze.load_zone_config!`), in the Strava FTP sync
  (`app.roc`) and in a command gate (`Report.roc`).

### Four scoring models cover every sport

"Everything Strava captures" is about 50 sport types, and they collapse into four scoring
models, three of which already exist.

| model | sports | status |
|---|---|---|
| power (NP/IF/TSS vs FTP) | cycling, power-metered rowing | have it, per ADR 0002 |
| pace (rTSS/sTSS) | running, swimming | missing, and the one genuinely new rung |
| HR-zone (hrTSS from time-in-zone) | soccer, basketball, tennis, hike, and the long tail | works, and needs per-sport zones |
| RPE / relative-effort | strength, yoga, skill; final fallback | have it |

The team, racket and miscellaneous sports that dominate the tail are HR-driven sports.
Given HR-only consumer data, hrTSS is the best available model for them rather than a mere
fallback, and it has known biases that must not be oversold. HR lag smears burst and rest
intervals into the mid-zones, and it misses the mechanical and neuromuscular load of
accelerations, jumps and cuts, which is the real cost of team sports. The roughly linear
per-zone coefficients also under-weight the Z4 and Z5 spikes those sports live in.
Session-RPE is arguably a peer of HR for team and racket sports rather than a lower
fallback, so ranking RPE alongside HR there specifically is reasonable. The whole space
still reduces to three pieces of work, which are to add one pace rung, to make HR zones
per-sport, and to route every sport to a sensible rung without ever rejecting an unknown
one.

### Amended 2026-08-17. All four items above have been fixed, and the sequencing shipped

- The pace rung exists. `Metrics.tss_ladder` takes an `ngp` and a `threshold_speed` and
  interposes `pace_or_fallback`, with per-sport exponents in `Sports.pace_tss_exponent`,
  which is 2 for run and 3 for swim. The ladder is now
  `power → pace → HR → session-RPE → relative-effort`.
- GAP is live rather than dead, because `minetti_ratio` and `grade_adjusted_speeds` feed
  `normalized_graded_pace`. `grade_adjusted_distance` genuinely is still unused outside
  expects, exactly as this ADR predicted.
- HR zones are per-sport, as `hr_z<n>_max_<sport>` through `Metrics.hr_zone_key`, with a
  per-sport `zones_used` signature driving invalidation.
- The cycling favoritism is gone, because `ftp_ride` appears nowhere outside a v10
  migration and the config-refusal policy.

One piece of Decision 5 did not ship. Item 5(a) said the analyze gate becomes "has any
usable threshold/zone for the sports present". `Analyze.load_zone_config!` still
hard-requires all four global `hr_z1..z4_max` keys and returns `Err(MissingConfig)`
otherwise, so an athlete carrying only per-sport zones is still refused `analyze`. The gate
is the one live item left in this ADR.

## Decision

1. Score the full sport space. Every sport gets the best available model through a complete
   ladder, and no sport is rejected or crashes. An unknown or new Strava sport routes to a
   safe default, which is HR first and then RPE or relative-effort, and it is labeled
   honestly rather than silently misrouted into a cycling frame.

2. Add the pace rung. A pace rung joins the ladder for pace-native endurance sports, giving
   `power → pace → HR-zone → session-RPE → relative-effort`. Ordering stays conditional on
   sport class. Power still wins whenever a power stream is present, and StrengthLike still
   ranks session-RPE above HR (ADR 0000 §4, `Metrics.tss_ladder`), while the pace rung slots
   in for endurance sports without a power stream. Pace load is rTSS or sTSS, which is the
   TrainingPeaks model, built by reusing the `IF²·hours·100` machinery. Simply swapping
   watts for pace hides two corrections that would otherwise produce a wrong number.
   - NGP is a normalized speed stream rather than a scalar. Normalized Graded Pace applies
     NP's own 30 s rolling and 4th-power weighting, already written as `normalized_power`
     and generic over `List(F64)`, to a grade-adjusted instantaneous speed stream, which is
     the grade factor per sample × the per-sample speed. The existing
     `grade_adjusted_distance` collapses the whole activity to one flat-equivalent scalar,
     which is the wrong shape for NGP, because dividing it by time yields average graded
     pace and discards exactly the surge and hill variability that normalization exists to
     capture. The real work is therefore to add a producer of grade-adjusted speed streams,
     reusing `minetti_ratio` per sample, and to feed the result through `normalized_power`,
     rather than to call the dead scalar GAP function.
   - IF must not invert. stride carries pace as seconds/km in `Render.pace_per_km`, where a
     faster pace is a smaller number. Pace intensity is therefore
     `IF = threshold_pace / NGP`, or both values converted to speed first, and it is not
     `NGP / threshold_pace`, which is the power form and would score hard efforts as easy.
     `threshold_pace_<sport>` mirrors `ftp_<sport>` and is derived with no config from a
     stored best-sustained-pace column, the pace analog of `best_20min_w`. The protocol is
     per sport, so a run uses roughly the best 30 to 60 min pace and a swim uses CSS from a
     400/200 pair.
   - Swimming uses NSS and CSS, meaning normalized swim speed against critical swim speed,
     with no grade term. One caveat applies, which is that 25 m, 50 m and open-water paces
     are not comparable, so a CSS derived from mixed pool contexts will not transfer. Scope
     CSS per pool context, or flag the mix.

3. Route via config rather than a hardcoded taxonomy. A per-sport `intensity_model` key
   (`model_<sport>` ∈ {power, pace, css, hr, rpe}) selects the rung, ships with a small
   built-in default map, and can be overridden by the user. The defaults are a convenience
   and not a gate, because an unmapped sport still works through the safe default. The
   arrangement keeps ADR 0002's promise that no sport is dropped and that adding a sport
   needs no code.

   Shipped differently, recorded 2026-08-18. There is no `model_<sport>` config key.
   Routing lives in `Sports.roc`, where `families` is a data table and `class` is a list
   literal, while `pace_routed` and `pace_tss_exponent` are name-substring predicates.
   Adding a family means editing one row, and adding a pace-routed sport whose name lacks
   "run" or "swim", such as rowing ergo, skate-ski or kayak, means editing a predicate. An
   unmapped sport still falls through to the safe default exactly as this decision requires.
   What was dropped is the user-overridable half, so an athlete cannot currently force a
   sport onto a different rung. The property the decision was protecting holds, and the
   mechanism named here does not exist, so following the text literally would send someone
   looking for a config key. Per-sport HR zones did ship as config
   (`hr_z<n>_max_<sport>`), which is probably why the decision read as done.

4. HR zones become per-sport. Per-sport zone keys (`hr_z*_max_<sport>`, or a per-sport LTHR
   that derives them) sit in front of the current global `hr_z*_max` keys, which stay as the
   fallback. Per-sport zones are what make the HR-native majority of sports, meaning soccer,
   basketball and tennis, accurate, and they let run and swim carry their own LTHR for the
   HR fallback path.

5. Remove the cycling favoritism. Delete the hardcoded `ftp_ride` special cases in
   `Analyze.load_zone_config!`, in the Strava FTP sync in `app.roc` and in the `Report.roc`
   command gate, so that the "generic" layer is actually generic. Two of those sites need
   handling rather than plain deletion. (a) `load_zone_config!` also returns
   `Err(MissingConfig)` when `ftp_ride` is unset, which makes this a behavior change rather
   than code cleanup. A runner with no bike FTP must still be able to `analyze`, so the gate
   becomes "has any usable threshold/zone for the sports present" instead of "has
   `ftp_ride`". (b) Summary's FTP calibration is a fourth consumer of `cfg.ftp` on the
   `Report.roc` summary path, and it must read the per-sport key.

## Scope boundary

Do not let this boundary drift. stride stays single-user and local-first. "Support all my
friends" means the engine scores every friend's sports correctly, and each friend owns
their own db under the "SQLite you own" model, runs their own instance, or has their export
analyzed in a separate db. Multi-athlete or multi-tenant use on one instance is explicitly
out of scope, because it is a different product needing per-athlete isolation, config
namespacing and per-athlete tokens, and it would break ADR 0000's local-first principle. Do
not entangle sport-completeness with tenancy.

## Consequences

- The GAP code gets a caller. `minetti_ratio` becomes the per-sample grade factor feeding
  the new NGP speed stream, while the scalar `grade_adjusted_distance` is not the NGP input,
  as Decision 2 explains, so the dead code becomes a real dependency.
- New config keys and new `activity_metrics` inputs need a schema change and a recompute,
  described in the migration story below. The change is deliberately not a data backfill.
- `intensity_model` and `sport_class` are independent of each other, and they must not be
  folded together. `intensity_model` picks the rung, while `sport_class` sets the fallback
  priority, so StrengthLike ranks RPE above HR while power still wins if it is present.
  Collapsing `sport_class` into `model_<sport>` would regress the property that a rated
  strength session with real watts is still measured. Both stay.
- Intensity must go per-pace as well as load, or ADR 0002 regresses. The easy, moderate and
  hard split and polarization read power-intensity and fall back to HR zones when power is
  absent, so a pace-scored run or swim would fall to HR and re-introduce the exact threshold
  mislabeling that ADR 0002 removed. A pace-intensity set, the `pi_*` analog computed from
  pace zones against threshold pace, is required alongside the pace load columns, and
  per-sport HR zones do not fix it.
- The honesty caveat from ADR 0002 carries over intact. Pace, HR and CSS numbers are only as
  good as the thresholds feeding them, so trust the direction rather than the decimals and
  caveat estimated thresholds.

## Migration story

The three data tiers of ADR 0000 mean that this large capability change touches disk in a
deliberately small way, and only one of the four items below is a real migration. Do not
write a data-transform migration for the metrics.

1. A schema migration is needed, and it covers more than columns. The new
   `activity_metrics` columns are `ngp` and `threshold_pace_used`, which are the pace
   analogs of NP and `ftp_used`, a pace-intensity `pi_*` set, which is the analog of the
   power-intensity split described in the consequences above, and a best-sustained-pace
   column, which is the analog of `best_20min_w` and lets `threshold_pace_<sport>` derive
   itself with no config. Bump `schema_version` and append to `run_migrations!`. Two of
   these apparently additive decisions need the same scalar to per-sport CASE plumbing that
   FTP already needed, rather than only columns.
   - Per-sport HR zones, from Decision 4. `compute_missing_metrics!` threads one global
     `ZoneBounds` and compares a scalar `zones_sig(zb)` in its invalidation WHERE clause.
     Making zones per-sport needs a `zones_sig_case!` SQL CASE, like `sport_ftp_case!`, and
     per-row `zb` resolution, because otherwise rows either never invalidate or recompute on
     every run.
   - Pace provenance, from Decision 2. The new `load_model` strings (`ngp`/`rtss`/`css`)
     must join every `load_model IN(...)` list, meaning the measured set, the `doctor`
     confidence tiers and the catch-all `non` bucket, and they must be declared high
     (measured) like power. Miss one and distance-measured pace silently reports as
     unmeasured. Since #196 those lists live in `Report.roc` as the
     `high/medium/low_models_sql` constants and every reader interpolates them, doctor's
     tiers in `ReportHealth.roc` included, so it is a one-line edit there. Grep the tree
     before believing that, because this line said "in `Report.roc`" until the split moved
     half of what it pointed at. `doctor`'s config-completeness check, which is the exact
     `hr_z1..z4_max` list, would need the new pace keys. It already counts per-sport HR
     overrides through `GLOB 'hr_z[1-4]_max_?*'`, and it reads derived FTP from
     `activity_metrics.ftp_used > 0` rather than from any `ftp_` config key. There is no
     `model_<sport>` key to learn, as the amendment on Decision 3 records.

2. Computed data is recomputed rather than transformed. `activity_metrics` and `daily_load`
   are the disposable computed tier, so bumping the `metrics_rev` constant makes the next
   `analyze` rebuild every row under the new ladder and model. There is no backfill script
   and no data transform, because the recompute-invalidation story does the work already.
   That story compares `ftp_used`, `zones_used`, `metrics_rev` and the new pace and
   threshold inputs in `compute_missing_metrics!`. Any new metric input must be added to
   that WHERE-clause comparison, or it will not invalidate.

3. Mirror data is re-pulled if a field is missing. `activities` and `streams` are
   re-pullable. GAP needs the distance and altitude streams, which are already stored and
   backfilled, so only a sport that lacks a needed stream field calls for a `sync full`
   re-pull.

4. Config data changes minimally and non-destructively. New keys (`threshold_pace_<sport>`,
   `model_<sport>`, per-sport HR zones) are born empty, so they fall back to defaults or to
   zero-config derivation. The global `hr_z*_max` keys stay as the fallback, and nothing is
   moved destructively. The only real key rename in this space is the existing `ftp` to
   `ftp_ride` rename in schema v10, which is the template if any key ever has to move.
   Removing the `ftp_ride` hardcoding from the code (Decision 5) changes code rather than
   config data.

## Sequencing

The slices below are tracer bullets, and they ship in this order.

> The build is unblocked (roc-lang/roc#10469, fixed upstream by roc-lang/roc#10531). The ADR
> carries the durable sequencing, while the live, disposable working checklist of in-flight
> PRs and watch-items lives in GitHub issues rather than here. The scratch file quoted
> earlier has since been retired. Slice 1, which is per-sport HR zones, resolves the zone
> half of Decision 4 and the `ftp_ride` removal of Decision 5.

1. Add per-sport HR zones and remove the `ftp_ride` hardcoding. It comes first because it
   makes the whole HR-native majority, meaning the long tail of Strava sports, score
   correctly straight away, and because it is smaller than the pace rung.
2. Add run rTSS. Wire GAP into NGP, add `threshold_pace_run` with its zero-config
   derivation, and route `model_run = pace`.
3. Add swim sTSS and CSS. `threshold_pace_swim` holds CSS, there is no grade term, and swim
   HR is deprioritized because wrist HR in water is unreliable.

Each slice is independently shippable and independently useful.

## Update, 2026-09-17

`Sports.roc` no longer lives in the engine. It moved into a shared Roc package at
`src/core/`, which also holds `Fmt`, and both binaries import that package. The routing
data and predicates named above are unchanged, so only the path a reader follows to find
them has moved. ADR 0016 records the layer table that governs the imports, and ADR 0017
records what may live in the package.
