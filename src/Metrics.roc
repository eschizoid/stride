module [
    ZoneBounds,
    ZoneSeconds,
    resample_1s,
    normalized_power,
    time_in_zones,
    time_in_power_intensity,
    power_ftp_key,
    best_rolling_mean,
    tss_ladder,
    sport_class,
    srpe_load,
    load_step,
    ftp_calibration,
    valid_hr,
    valid_watts,
    form_label,
    weekly_rollup,
    civil_from_days,
    date_str_to_days,
    days_to_date_str,
    epoch_to_iso,
    day_of_week,
    power_zones,
    trend_ends,
    mean,
    pct_change,
    scale_to_blocks,
    ProgressRow,
    group_progress,
    anchor_filter,
    progress_lens,
    lens_score,
    lens_higher_better,
    parse_utc_offset,
    export_date_to_iso,
]

# ── pure training-science math. no I/O, fully unit-tested. ──────────

ZoneBounds : { z1_max : F64, z2_max : F64, z3_max : F64, z4_max : F64 }
ZoneSeconds : { z1 : I64, z2 : I64, z3 : I64, z4 : I64, z5 : I64 }

# ── resampling ──────────────────────────────────────────────────────
# Strava streams are (elapsed_second, value) samples with gaps.
# Resample to 1 Hz by forward-filling gaps up to max_fill_gap seconds;
# longer gaps are treated as pauses and not filled.

max_fill_gap : I64
max_fill_gap = 10

resample_1s : List { t : I64, v : F64 } -> List F64
resample_1s = |samples|
    state = List.walk(
        samples,
        { out: [], prev_t: 0i64, prev_v: 0.0f64, started: Bool.false },
        |acc, s|
            if !(acc.started) then
                { out: List.append(acc.out, s.v), prev_t: s.t, prev_v: s.v, started: Bool.true }
            else
                gap = s.t - acc.prev_t
                if gap <= 0 then
                    acc
                else if gap <= max_fill_gap then
                    filled = List.concat(acc.out, List.repeat(acc.prev_v, Num.to_u64(gap - 1)))
                    { acc & out: List.append(filled, s.v), prev_t: s.t, prev_v: s.v }
                else
                    # pause — resume without filling
                    { acc & out: List.append(acc.out, s.v), prev_t: s.t, prev_v: s.v },
    )
    state.out

# ── normalized power ────────────────────────────────────────────────
# 30s rolling average of 1 Hz power, each mean ^4, averaged, ^0.25.

np_window : U64
np_window = 30

normalized_power : List F64 -> Result F64 [TooShort]
normalized_power = |watts_1s|
    n = List.len(watts_1s)
    if n < np_window then
        Err(TooShort)
    else
        prefix = List.walk(watts_1s, [0.0f64], |acc, w| List.append(acc, last_or_zero(acc) + w))
        window_count = n - np_window + 1
        sum4 = List.walk(
            List.range({ start: At(0), end: Before(window_count) }),
            0.0f64,
            |acc, i|
                hi = get_or_zero(prefix, i + np_window)
                lo = get_or_zero(prefix, i)
                window_avg = (hi - lo) / Num.to_f64(np_window)
                acc + (window_avg * window_avg * window_avg * window_avg),
        )
        Ok(Num.pow(sum4 / Num.to_f64(window_count), 0.25))

last_or_zero : List F64 -> F64
last_or_zero = |xs|
    Result.with_default(List.last(xs), 0.0)

get_or_zero : List F64, U64 -> F64
get_or_zero = |xs, i|
    Result.with_default(List.get(xs, i), 0.0)

# ── best rolling mean (e.g. 20-min best power for FTP calibration) ──

best_rolling_mean : List F64, U64 -> Result F64 [TooShort]
best_rolling_mean = |xs_1s, window|
    n = List.len(xs_1s)
    if n < window or window == 0 then
        Err(TooShort)
    else
        prefix = List.walk(xs_1s, [0.0f64], |acc, w| List.append(acc, last_or_zero(acc) + w))
        best = List.walk(
            List.range({ start: At(0), end: Before(n - window + 1) }),
            0.0f64,
            |acc, i|
                window_avg = (get_or_zero(prefix, i + window) - get_or_zero(prefix, i)) / Num.to_f64(window)
                Num.max(acc, window_avg),
        )
        Ok(best)

# ── time in zones (HR-based, universal across sports) ───────────────
# dt between consecutive samples, capped at 30s (pauses don't count),
# attributed to the zone of the current sample.

zone_of : F64, ZoneBounds -> U8
zone_of = |hr, zb|
    if hr <= zb.z1_max then
        1
    else if hr <= zb.z2_max then
        2
    else if hr <= zb.z3_max then
        3
    else if hr <= zb.z4_max then
        4
    else
        5

time_in_zones : List { t : I64, v : F64 }, ZoneBounds -> ZoneSeconds
time_in_zones = |samples, zb|
    state = List.walk(
        samples,
        { z: { z1: 0i64, z2: 0i64, z3: 0i64, z4: 0i64, z5: 0i64 }, prev_t: 0i64, started: Bool.false },
        |acc, s|
            if !(acc.started) then
                { acc & prev_t: s.t, started: Bool.true }
            else
                dt = Num.min(s.t - acc.prev_t, 30)
                if dt <= 0 then
                    { acc & prev_t: s.t }
                else
                    z = acc.z
                    updated =
                        when zone_of(s.v, zb) is
                            1 -> { z & z1: z.z1 + dt }
                            2 -> { z & z2: z.z2 + dt }
                            3 -> { z & z3: z.z3 + dt }
                            4 -> { z & z4: z.z4 + dt }
                            _ -> { z & z5: z.z5 + dt }
                    { acc & z: updated, prev_t: s.t },
    )
    state.z

# Intensity split from POWER, for a sport with a known threshold (FTP). Mirrors the
# HR easy/moderate/hard split, but off power zones: easy < 76% FTP (Z1-2), moderate
# 76-90% (Z3), hard >= 91% FTP (Z4+). For a power-equipped ride this is the truer
# "how hard was it" — an athlete's threshold HR can sit right on a zone boundary, so
# a genuine threshold effort reads as moderate by HR while the power says threshold.
# Same 30s gap cap as the HR walk so a paused/dropped stream can't invent time.
PowerIntensity : { easy_s : I64, moderate_s : I64, hard_s : I64 }

time_in_power_intensity : List { t : I64, v : F64 }, F64 -> PowerIntensity
time_in_power_intensity = |samples, ftp|
    if ftp <= 0.0 then
        { easy_s: 0, moderate_s: 0, hard_s: 0 }
    else
        mod_lo = ftp * 0.76
        hard_lo = ftp * 0.91
        state = List.walk(
            samples,
            { i: { easy_s: 0i64, moderate_s: 0i64, hard_s: 0i64 }, prev_t: 0i64, started: Bool.false },
            |acc, s|
                if !(acc.started) then
                    { acc & prev_t: s.t, started: Bool.true }
                else
                    dt = Num.min(s.t - acc.prev_t, 30)
                    if dt <= 0 then
                        { acc & prev_t: s.t }
                    else
                        i = acc.i
                        updated =
                            if s.v < mod_lo then { i & easy_s: i.easy_s + dt }
                            else if s.v < hard_lo then { i & moderate_s: i.moderate_s + dt }
                            else { i & hard_s: i.hard_s + dt }
                        { acc & i: updated, prev_t: s.t },
        )
        state.i

# The config key holding a sport's power threshold. Fully generic and data-driven:
# `ftp_<sport>` for EVERY sport (ftp_ride, ftp_rowing, ftp_swim, ftp_soccer, …), so a
# sport gets power-based intensity the instant its key is set and falls back to HR
# otherwise. No hardcoded list of sports to fall out of date — power lives on a
# different scale per sport (a 150 W row ≠ a 150 W ride), and WHICH sports the athlete
# has a threshold for is their config, not our code. Cycling's primary key is the
# entrenched `ftp` (see sport_ftp! for that one back-compat tie).
power_ftp_key : Str -> Str
power_ftp_key = |sport|
    "ftp_${Str.with_ascii_lowercased(sport)}"

# ── training stress ─────────────────────────────────────────────────

tss_from_power : { np : F64, ftp : F64, dur_s : F64 } -> F64
tss_from_power = |{ np, ftp, dur_s }|
    if ftp <= 0 then
        0
    else
        intensity = np / ftp
        (dur_s * np * intensity) / (ftp * 3600.0) * 100.0

# hrTSS heuristic: TSS per hour spent in each HR zone.
# Standard coaching approximations (documented, deliberately simple).
hr_tss_per_hour : { z1 : F64, z2 : F64, z3 : F64, z4 : F64, z5 : F64 }
hr_tss_per_hour = { z1: 30.0, z2: 55.0, z3: 70.0, z4: 85.0, z5: 100.0 }

hr_tss : ZoneSeconds -> F64
hr_tss = |zs|
    f = hr_tss_per_hour
    (Num.to_f64(zs.z1) * f.z1 + Num.to_f64(zs.z2) * f.z2 + Num.to_f64(zs.z3) * f.z3 + Num.to_f64(zs.z4) * f.z4 + Num.to_f64(zs.z5) * f.z5) / 3600.0

# ── the TSS ladder ──────────────────────────────────────────────────
# Best-available-data fallback chain, one decision in one testable place:
#   stream NP -> Strava weighted watts -> avg watts -> zone-based hrTSS
#   -> avg-HR classified into one zone -> relative_effort -> 0 (no data).
# Returns the tss and the power figure used (Err NoPower if HR/RE path).

# ── sport classification ────────────────────────────────────────────
# Strength-class sports: HR-based load systematically underestimates them (the
# aerobic model doesn't see bar weight), so user session-RPE outranks HR there.
sport_class : Str -> [Endurance, StrengthLike]
sport_class = |sport_type|
    strengthish = ["WeightTraining", "Workout", "Crossfit", "HighIntensityIntervalTraining", "Yoga", "Pilates"]
    if List.contains(strengthish, sport_type) then StrengthLike else Endurance

# ── session-RPE load (Foster) ───────────────────────────────────────
# hours × RPE × 10, so one hour at RPE 10 = 100 — TSS-commensurate BY
# CONSTRUCTION. Raw Foster units (minutes × RPE) would be ~6x too large and
# corrupt CTL/ATL; do not "simplify" this back to minutes.
srpe_load : { rpe : F64, moving_time : I64 } -> F64
srpe_load = |{ rpe, moving_time }|
    (Num.to_f64(moving_time) / 3600.0) * rpe * 10.0

tss_ladder :
    {
        np_stream : Result F64 [TooShort],
        weighted_watts : Result F64 [Missing],
        avg_watts : Result F64 [Missing],
        avg_hr : Result F64 [Missing],
        relative_effort : Result F64 [Missing],
        rpe : Result F64 [Missing],
        sport_type : Str,
        zones : ZoneSeconds,
        zb : ZoneBounds,
        ftp : F64,
        dur_s : F64,
        moving_time : I64,
    }
    -> { tss : F64, np : Result F64 [NoPower], model : Str }
tss_ladder = |input|
    np_like =
        when input.np_stream is
            Ok(np) -> Ok({ w: np, m: "power_stream" })
            Err(_) ->
                when input.weighted_watts is
                    Ok(w) -> Ok({ w, m: "weighted_watts" })
                    Err(_) ->
                        when input.avg_watts is
                            Ok(w) -> Ok({ w, m: "avg_watts" })
                            Err(_) -> Err(NoPower)

    zone_total = input.zones.z1 + input.zones.z2 + input.zones.z3 + input.zones.z4 + input.zones.z5
    # measured HR load, when there is any usable HR at all
    hr_scored =
        if zone_total > 0 then
            Ok({ t: hr_tss(input.zones), m: "hr_zones" })
        else
            when input.avg_hr is
                Ok(hr) -> Ok({ t: hr_tss(all_seconds_in_zone(input.moving_time, zone_of(hr, input.zb))), m: "hr_avg" })
                Err(_) -> Err(NoHr)
    rpe_scored =
        when input.rpe is
            Ok(r) -> Ok({ t: srpe_load({ rpe: r, moving_time: input.moving_time }), m: "session_rpe" })
            Err(_) -> Err(NoRpe)
    re_scored =
        when input.relative_effort is
            Ok(re) -> Ok({ t: re, m: "relative_effort" })
            Err(_) -> Err(NoRe)

    # endurance: measured beats reported (power > HR > RPE > RE).
    # strength-like: the athlete's rating beats HR (power still wins if present —
    # a strength session with real watts is measured too).
    ordered =
        when sport_class(input.sport_type) is
            Endurance -> [hr_scored, rpe_scored, re_scored]
            StrengthLike -> [rpe_scored, hr_scored, re_scored]
    scored =
        when np_like is
            Ok(p) -> { t: tss_from_power({ np: p.w, ftp: input.ftp, dur_s: input.dur_s }), m: p.m }
            Err(_) ->
                List.walk_until(ordered, { t: 0.0, m: "none" }, |acc, candidate|
                    when candidate is
                        Ok(pair) -> Break(pair)
                        Err(_) -> Continue(acc))
    { tss: scored.t, np: Result.map_ok(np_like, |p| p.w), model: scored.m }

all_seconds_in_zone : I64, U8 -> ZoneSeconds
all_seconds_in_zone = |secs, zone|
    zero = { z1: 0i64, z2: 0i64, z3: 0i64, z4: 0i64, z5: 0i64 }
    when zone is
        1 -> { zero & z1: secs }
        2 -> { zero & z2: secs }
        3 -> { zero & z3: secs }
        4 -> { zero & z4: secs }
        _ -> { zero & z5: secs }

# ── daily load recurrence (CTL/ATL EWMA) ────────────────────────────
# One day's step of the fitness/fatigue/form model:
#   CTL (fitness)  = 42-day exponential moving average of daily TSS
#   ATL (fatigue)  =  7-day exponential moving average of daily TSS
#   TSB (form)     = yesterday's fitness minus yesterday's fatigue, so a hard
#                    day shows up in the NEXT morning's form (the off-by-one is
#                    the convention, not a bug).

load_step : { ctl_prev : F64, atl_prev : F64, tss : F64 } -> { ctl : F64, atl : F64, tsb : F64 }
load_step = |{ ctl_prev, atl_prev, tss }|
    ctl = ctl_prev + (tss - ctl_prev) / 42.0
    atl = atl_prev + (tss - atl_prev) / 7.0
    # same-day form: today's fitness minus today's fatigue, so the number
    # reconciles (tsb = ctl - atl) and reflects state AFTER today's training
    { ctl, atl, tsb: ctl - atl }

# ── FTP calibration ─────────────────────────────────────────────────
# Estimate FTP from a recent 20-min best (× 0.95, the standard factor) and flag
# whether the configured FTP is stale (est materially higher) or the athlete is
# detraining / not testing (est materially lower). One place, one truth.

ftp_calibration : { best_20min : F64, ftp : F64 } -> { est : F64, stale : Bool, detraining : Bool }
ftp_calibration = |{ best_20min, ftp }|
    est = best_20min * 0.95
    {
        est,
        stale: est > ftp * 1.05,
        detraining: est < ftp * 0.9,
    }

# ── power zones (Coggan / Peloton 7-zone model, watt ranges from FTP) ─
# lo_w = 0 means the zone starts at 0 (Z1); hi_w = 0 means it is open above (Z7).
power_zones : F64 -> List { z : Str, name : Str, lo_w : F64, hi_w : F64 }
power_zones = |ftp|
    [
        { z: "Z1", name: "recovery", lo_w: 0.0, hi_w: ftp * 0.55 },
        { z: "Z2", name: "endurance", lo_w: ftp * 0.56, hi_w: ftp * 0.75 },
        { z: "Z3", name: "tempo", lo_w: ftp * 0.76, hi_w: ftp * 0.90 },
        { z: "Z4", name: "threshold", lo_w: ftp * 0.91, hi_w: ftp * 1.05 },
        { z: "Z5", name: "VO2max", lo_w: ftp * 1.06, hi_w: ftp * 1.20 },
        { z: "Z6", name: "anaerobic", lo_w: ftp * 1.21, hi_w: ftp * 1.50 },
        { z: "Z7", name: "neuromuscular", lo_w: ftp * 1.51, hi_w: 0.0 },
    ]

# ── trend of a chronological series (for "am I improving?" verdicts) ─
# average of the first third vs the last third (k = max(1, n/3) points each end),
# so one outlier day doesn't decide the verdict. Empty -> zeros.
trend_ends : List F64 -> { early : F64, late : F64 }
trend_ends = |xs|
    n = List.len(xs)
    if n == 0 then
        { early: 0.0, late: 0.0 }
    else
        k = Num.max(1, n // 3)
        { early: mean(List.take_first(xs, k)), late: mean(List.take_last(xs, k)) }

# mean of a float list; 0.0 on empty
mean : List F64 -> F64
mean = |ys| if List.is_empty(ys) then 0.0 else List.sum(ys) / Num.to_f64(List.len(ys))

# percent change from -> to; 0.0 when `from` isn't positive (no meaningful baseline)
pct_change : F64, F64 -> F64
pct_change = |from, to| if from > 0.0 then (to - from) / from * 100.0 else 0.0

# scale a value in [lo, hi] to 1..blocks bar segments (lo -> 1, hi -> blocks);
# degenerate range -> full bar
scale_to_blocks : F64, F64, F64, U64 -> U64
scale_to_blocks = |value, lo, hi, blocks|
    if Num.abs(hi - lo) < 0.001 then
        blocks
    else
        1 + Num.round((value - lo) / (hi - lo) * Num.to_f64(blocks - 1))

# ── repeated-workout progress (the `progress` command's business rules) ─
ProgressRow : { name : Str, date : Str, sport : Str, distance_m : F64, moving_time : I64, np_w : F64, avg_hr : F64, rpe : F64, output_kj : F64, tss : F64 }

# split rows (already sorted by name) into per-workout runs
group_progress : List ProgressRow -> List { name : Str, rows : List ProgressRow }
group_progress = |rows|
    List.walk(rows, [], |acc, r|
        when List.last(acc) is
            Ok(g) if g.name == r.name ->
                List.set(acc, List.len(acc) - 1, { name: g.name, rows: List.append(g.rows, r) })

            _ -> List.append(acc, { name: r.name, rows: [r] }))

# which comparison a group's anchor (the instance on the asked date) supports:
# exact-named workouts compare every instance; auto-named rides ("Morning Ride")
# are different routes under one name, so only rides within ±10% of the anchor's
# distance compare — and with no distance recorded, only the anchor itself shows.
# Groups whose anchor isn't on the asked date drop entirely.
anchor_filter : { name : Str, rows : List ProgressRow }, Str -> Result { name : Str, kind : [Exact, SimilarDistance F64, LoneNoDistance], rows : List ProgressRow } [NoAnchor]
anchor_filter = |g, date|
    when List.find_first(g.rows, |r| r.date == date) is
        Err(_) -> Err(NoAnchor)
        Ok(anchor) ->
            if !(is_auto_name(g.name)) then
                Ok({ name: g.name, kind: Exact, rows: g.rows })
            else if anchor.distance_m <= 0.0 then
                Ok({ name: g.name, kind: LoneNoDistance, rows: [anchor] })
            else
                kept = List.keep_if(g.rows, |r| Num.abs(r.distance_m - anchor.distance_m) <= anchor.distance_m * 0.10)
                Ok({ name: g.name, kind: SimilarDistance(anchor.distance_m), rows: kept })

# confidence tiers (high = measured power, medium = HR/RPE, low = relative_effort,
# none = unscored) are derived from load_model at READ time in the doctor query
# (see the CASE there). Not stored — it's a pure function of a column that already
# exists, so a column would be redundant denormalization.

# Parse a POSIX `date +%z` offset ("+HHMM" / "-HHMM", ASCII digits) into signed
# minutes east of UTC: "-0500" -> -300, "+0530" -> 330. Used to turn a system
# timezone into the current civil-day offset (DST-correct for today).
parse_utc_offset : Str -> Result I64 [BadOffset]
parse_utc_offset = |raw|
    when Str.to_utf8(Str.trim(raw)) is
        [sign, h1, h2, m1, m2] ->
            digit = |b| if b >= 48 and b <= 57 then Ok(Num.to_i64(b) - 48) else Err(BadOffset)
            hh = (digit(h1)? * 10) + digit(h2)?
            mm = (digit(m1)? * 10) + digit(m2)?
            mag = (hh * 60) + mm
            if sign == 45 then Ok(-mag)
            else if sign == 43 then Ok(mag)
            else Err(BadOffset)
        _ -> Err(BadOffset)

# ── progress lens: which "am I improving?" metric fits this workout ──
# Power sports compare Efficiency Factor; distance sports without power compare
# aerobic efficiency (speed per heartbeat); rated sessions (strength/HIIT/yoga)
# compare RPE — and for a FIXED workout, a dropping RPE means you adapted, so
# that lens is lower-is-better. Chosen by what data the group actually carries.
Lens : [Ef, SpeedHr, Rpe]

lens_score : Lens, ProgressRow -> Result F64 [Unscorable]
lens_score = |lens, r|
    when lens is
        Ef -> if r.np_w > 0.0 and r.avg_hr > 0.0 then Ok(r.np_w / r.avg_hr) else Err(Unscorable)
        SpeedHr ->
            if r.distance_m > 0.0 and r.avg_hr > 0.0 and r.moving_time > 0 then
                Ok((r.distance_m / Num.to_f64(r.moving_time) * 60.0) / r.avg_hr)
            else
                Err(Unscorable)

        Rpe -> if r.rpe > 0.0 then Ok(r.rpe) else Err(Unscorable)

# RPE is the only lens where a lower number is the better result
lens_higher_better : Lens -> Bool
lens_higher_better = |lens|
    when lens is
        Rpe -> Bool.false
        _ -> Bool.true

# pick the richest lens the group can actually compute (power > speed/HR > RPE)
progress_lens : List ProgressRow -> [Ef, SpeedHr, Rpe, Unscorable]
progress_lens = |rows|
    scorable = |lens| List.any(rows, |r| Result.is_ok(lens_score(lens, r)))
    if scorable(Ef) then Ef
    else if scorable(SpeedHr) then SpeedHr
    else if scorable(Rpe) then Rpe
    else Unscorable

# lens selection: power ride -> Ef, run with pace+HR -> SpeedHr, rated strength -> Rpe
expect
    row = |sport, np, dist, mt, rpe| { name: "X", date: "2025-01-01", sport, distance_m: dist, moving_time: mt, np_w: np, avg_hr: 150.0, rpe, output_kj: 0.0, tss: 0.0 }
    progress_lens([row("Ride", 200.0, 0.0, 3600, 0.0)]) == Ef
    and progress_lens([row("Run", 0.0, 10000.0, 3000, 0.0)]) == SpeedHr
    and progress_lens([row("WeightTraining", 0.0, 0.0, 2700, 7.0)]) == Rpe
    and progress_lens([row("Workout", 0.0, 0.0, 2700, 0.0)]) == Unscorable

# EF = NP/HR; RPE is lower-is-better
expect
    r = { name: "X", date: "d", sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: 300.0, avg_hr: 150.0, rpe: 0.0, output_kj: 0.0, tss: 0.0 }
    Num.abs(Result.with_default(lens_score(Ef, r), 0.0) - 2.0) < 0.001 and lens_higher_better(Ef) and !(lens_higher_better(Rpe))

# ── Strava bulk-export date parsing ─────────────────────────────────
# activities.csv dates look like "Feb 17, 2022, 12:18:26 PM" (English-language
# exports only — that's a documented Strava export caveat, not ours).
export_date_to_iso : Str -> Result Str [BadExportDate]
export_date_to_iso = |raw|
    when Str.split_on(Str.trim(raw), ", ") is
        [month_day, year, clock] ->
            when (Str.split_on(month_day, " "), Str.split_on(clock, " ")) is
                ([mon, day], [hms, ampm]) ->
                    month = month_num(mon)?
                    day_n = Str.to_u64(day) |> Result.map_err(|_| BadExportDate)?
                    hour24 = hour_24(hms, ampm)?
                    rest =
                        when Str.split_on(hms, ":") is
                            [_, mi, se] -> Ok("${mi}:${se}")
                            _ -> Err(BadExportDate)
                    "${year}-${pad2(Num.to_i64(month))}-${pad2(Num.to_i64(day_n))}T${pad2(Num.to_i64(hour24))}:${rest?}Z" |> Ok

                _ -> Err(BadExportDate)

        _ -> Err(BadExportDate)

month_num : Str -> Result U64 [BadExportDate]
month_num = |m|
    when m is
        "Jan" -> Ok(1)
        "Feb" -> Ok(2)
        "Mar" -> Ok(3)
        "Apr" -> Ok(4)
        "May" -> Ok(5)
        "Jun" -> Ok(6)
        "Jul" -> Ok(7)
        "Aug" -> Ok(8)
        "Sep" -> Ok(9)
        "Oct" -> Ok(10)
        "Nov" -> Ok(11)
        "Dec" -> Ok(12)
        _ -> Err(BadExportDate)

hour_24 : Str, Str -> Result U64 [BadExportDate]
hour_24 = |hms, ampm|
    h =
        when Str.split_on(hms, ":") is
            [hh, _, _] -> Str.to_u64(hh) |> Result.map_err(|_| BadExportDate)
            _ -> Err(BadExportDate)
    hour = h?
    when ampm is
        "AM" -> Ok(if hour == 12 then 0 else hour)
        "PM" -> Ok(if hour == 12 then 12 else hour + 12)
        _ -> Err(BadExportDate)

# ── Strava auto-names ───────────────────────────────────────────────
# "Morning Ride", "Lunch Gravel Ride", ... are Strava's time-of-day defaults: the
# same name covers DIFFERENT routes, so name-matching them compares unlike efforts.
is_auto_name : Str -> Bool
is_auto_name = |name|
    when Str.split_first(name, " ") is
        Ok({ before }) -> List.contains(["Morning", "Lunch", "Afternoon", "Evening", "Night"], before)
        Err(_) -> Bool.false

# ── HR sample validity ──────────────────────────────────────────────
# Below 35 or above 220 bpm is not physiology, it's a dropped strap / noise.
valid_hr : F64 -> Bool
valid_hr = |hr|
    hr >= 35.0 and hr <= 220.0

# ── power sample validity ───────────────────────────────────────────
# A negative watt is impossible; a 1-second sample above 2500 W exceeds the
# highest human peak power ever recorded (elite track sprinters top out ~2500 W),
# so it's a misreporting trainer / sensor glitch, not effort. Dropping the sample
# stops one spike from inflating NP and the 20-min best that estimates FTP — and,
# because an FTP change rescales all history, from corrupting the whole series.
# This catches GLITCHES (impossible samples), not plausible-but-suspect *sustained*
# values (e.g. a miscalibrated trainer reading a steady 489 W) — that's a coaching
# judgment the doctor/coach flags, not something a filter should silently discard.
valid_watts : F64 -> Bool
valid_watts = |w|
    w >= 0.0 and w <= 2500.0

# ── form interpretation (standard TSB bands) ────────────────────────

# verdicts describe MODELED load only — the engine can't see sleep, illness,
# soreness, or life stress, so it suggests rather than commands
form_label : F64 -> Str
form_label = |tsb|
    if tsb <= -15.0 then
        "high modeled fatigue — consider recovery"
    else if tsb <= -5.0 then
        "modeled fatigue building — favor easy work"
    else if tsb < 5.0 then
        "balanced — good day for intensity if you feel it"
    else if tsb < 15.0 then
        "fresh — good day for a big effort"
    else
        "very fresh — load has been light lately"

# ── weekly rollup (Monday-aligned, the user's week convention) ──────
# epoch day 0 = Thursday, so (days + 3) // 7 increments every Monday.

weekly_rollup : List { days : I64, tss : F64, ctl : F64, atl : F64, tsb : F64 } -> List { week_start : I64, tss : F64, sessions : I64, ctl_end : F64, tsb_end : F64 }
weekly_rollup = |day_rows|
    List.walk(day_rows, [], |acc, d|
        ws = ((d.days + 3) // 7) * 7 - 3
        sess : I64
        sess = if d.tss >= 1.0 then 1 else 0
        when List.last(acc) is
            Ok(w) ->
                if w.week_start == ws then
                    List.set(acc, List.len(acc) - 1, {
                        week_start: ws,
                        tss: w.tss + d.tss,
                        sessions: w.sessions + sess,
                        ctl_end: d.ctl,
                        tsb_end: d.tsb,
                    })
                else
                    List.append(acc, { week_start: ws, tss: d.tss, sessions: sess, ctl_end: d.ctl, tsb_end: d.tsb })

            Err(_) -> List.append(acc, { week_start: ws, tss: d.tss, sessions: sess, ctl_end: d.ctl, tsb_end: d.tsb }))

# ── civil-date arithmetic (Howard Hinnant's algorithms) ─────────────

days_from_civil : I64, I64, I64 -> I64
days_from_civil = |y_in, m, d|
    y = if m <= 2 then y_in - 1 else y_in
    era = (if y >= 0 then y else y - 399) // 400
    yoe = y - era * 400
    mp = (m + 9) % 12
    doy = (153 * mp + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    era * 146097 + doe - 719468

civil_from_days : I64 -> { y : I64, m : I64, d : I64 }
civil_from_days = |z_in|
    z = z_in + 719468
    era = (if z >= 0 then z else z - 146096) // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    m = if mp < 10 then mp + 3 else mp - 9
    { y: (if m <= 2 then y + 1 else y), m, d }

# "2026-07-25T15:30:21Z" (or "2026-07-25") -> epoch day number
date_str_to_days : Str -> Result I64 [BadDate]
date_str_to_days = |s|
    date_part = Result.with_default(List.first(Str.split_on(s, "T")), s)
    when Str.split_on(date_part, "-") is
        [ys, ms, ds] ->
            when (Str.to_i64(ys), Str.to_i64(ms), Str.to_i64(ds)) is
                (Ok(y), Ok(m), Ok(d)) -> Ok(days_from_civil(y, m, d))
                _ -> Err(BadDate)

        _ -> Err(BadDate)

days_to_date_str : I64 -> Str
days_to_date_str = |days|
    c = civil_from_days(days)
    "${Num.to_str(c.y)}-${pad2(c.m)}-${pad2(c.d)}"

pad2 : I64 -> Str
pad2 = |n|
    if n < 10 then "0${Num.to_str(n)}" else Num.to_str(n)

# epoch day number -> "Mon".."Sun". Epoch day 0 (1970-01-01) was a Thursday, so
# (days + 3) mod 7 makes Monday = 0 (matches the Mon-aligned week convention).
day_of_week : I64 -> Str
day_of_week = |days|
    when Num.rem(days + 3, 7) is
        0 -> "Mon"
        1 -> "Tue"
        2 -> "Wed"
        3 -> "Thu"
        4 -> "Fri"
        5 -> "Sat"
        _ -> "Sun"

# epoch seconds (UTC) -> "YYYY-MM-DDTHH:MM:SSZ" — so stored timestamps read like
# the ISO dates elsewhere instead of a raw epoch integer
epoch_to_iso : I64 -> Str
epoch_to_iso = |epoch|
    days = epoch // 86400
    tod = epoch % 86400
    c = civil_from_days(days)
    h = tod // 3600
    m = (tod % 3600) // 60
    s = tod % 60
    "${Num.to_str(c.y)}-${pad2(c.m)}-${pad2(c.d)}T${pad2(h)}:${pad2(m)}:${pad2(s)}Z"

# ── tests ───────────────────────────────────────────────────────────

# NP of constant power == that power
expect
    when normalized_power(List.repeat(200.0, 3600)) is
        Ok(np) -> Num.abs(np - 200.0) < 0.001
        Err(_) -> Bool.false

# NP requires at least 30 samples
expect Result.is_err(normalized_power(List.repeat(200.0, 10)))

# riding exactly at FTP for one hour == 100 TSS
expect
    tss = tss_from_power({ np: 190.0, ftp: 190.0, dur_s: 3600.0 })
    Num.abs(tss - 100.0) < 0.001

# half an hour at FTP == 50 TSS
expect
    tss = tss_from_power({ np: 190.0, ftp: 190.0, dur_s: 1800.0 })
    Num.abs(tss - 50.0) < 0.001

# an hour fully in Z2 == 55 hrTSS
expect
    tss = hr_tss({ z1: 0, z2: 3600, z3: 0, z4: 0, z5: 0 })
    Num.abs(tss - 55.0) < 0.001

# zone classification against Mariano-shaped bounds
expect
    zb = { z1_max: 123.0, z2_max: 153.0, z3_max: 168.0, z4_max: 183.0 }
    zone_of(100.0, zb) == 1 and zone_of(140.0, zb) == 2 and zone_of(160.0, zb) == 3 and zone_of(175.0, zb) == 4 and zone_of(190.0, zb) == 5

# time_in_zones: 1 Hz samples, 10s in z1 then 10s in z5
expect
    zb = { z1_max: 123.0, z2_max: 153.0, z3_max: 168.0, z4_max: 183.0 }
    low = List.map(List.range({ start: At(1), end: At(10) }), |i| { t: Num.to_i64(i), v: 100.0 })
    high = List.map(List.range({ start: At(11), end: At(20) }), |i| { t: Num.to_i64(i), v: 190.0 })
    zs = time_in_zones(List.concat(low, high), zb)
    zs.z1 == 9 and zs.z5 == 10 and zs.z2 == 0

# (Roc floats have no total equality — compare element-wise with tolerance)
lists_approx_eq : List F64, List F64 -> Bool
lists_approx_eq = |xs, ys|
    if List.len(xs) != List.len(ys) then
        Bool.false
    else
        List.map2(xs, ys, |a, b| Num.abs(a - b) < 0.001) |> List.all(|ok| ok)

# resample fills small gaps with previous value
expect
    out = resample_1s([{ t: 0, v: 100.0 }, { t: 3, v: 130.0 }])
    lists_approx_eq(out, [100.0, 100.0, 100.0, 130.0])

# resample does not fill across long pauses
expect
    out = resample_1s([{ t: 0, v: 100.0 }, { t: 100, v: 130.0 }])
    lists_approx_eq(out, [100.0, 130.0])

# best rolling mean of a constant series is that constant
expect
    when best_rolling_mean(List.repeat(250.0, 100), 20) is
        Ok(best) -> Num.abs(best - 250.0) < 0.001
        Err(_) -> Bool.false

# best rolling mean finds the hot stretch
expect
    xs = List.concat(List.repeat(100.0, 50), List.concat(List.repeat(300.0, 20), List.repeat(100.0, 50)))
    when best_rolling_mean(xs, 20) is
        Ok(best) -> Num.abs(best - 300.0) < 0.001
        Err(_) -> Bool.false

# ── tss_ladder tests ────────────────────────────────────────────────

test_zb : ZoneBounds
test_zb = { z1_max: 123.0, z2_max: 153.0, z3_max: 168.0, z4_max: 183.0 }

test_zeroz : ZoneSeconds
test_zeroz = { z1: 0, z2: 0, z3: 0, z4: 0, z5: 0 }

ladder_base = {
    np_stream: Err(TooShort),
    weighted_watts: Err(Missing),
    avg_watts: Err(Missing),
    avg_hr: Err(Missing),
    relative_effort: Err(Missing),
    rpe: Err(Missing),
    sport_type: "Ride",
    zones: test_zeroz,
    zb: test_zb,
    ftp: 200.0,
    dur_s: 3600.0,
    moving_time: 3600,
}

# stream NP wins even when weighted watts disagree
expect
    r = tss_ladder({ ladder_base & np_stream: Ok(200.0), weighted_watts: Ok(300.0) })
    Num.abs(r.tss - 100.0) < 0.001

# weighted watts is the second rung
expect
    r = tss_ladder({ ladder_base & weighted_watts: Ok(200.0) })
    Num.abs(r.tss - 100.0) < 0.001

# avg watts is the third rung
expect
    r = tss_ladder({ ladder_base & avg_watts: Ok(200.0) })
    Num.abs(r.tss - 100.0) < 0.001

# no power: an hour of Z2 HR time -> 55 hrTSS, np reports NoPower
expect
    r = tss_ladder({ ladder_base & zones: { test_zeroz & z2: 3600 } })
    Num.abs(r.tss - 55.0) < 0.001 and Result.is_err(r.np)

# no power, no zone seconds: avg HR classifies the whole session (150 -> Z2)
expect
    r = tss_ladder({ ladder_base & avg_hr: Ok(150.0) })
    Num.abs(r.tss - 55.0) < 0.001

# last data rung: relative_effort passes through
expect
    r = tss_ladder({ ladder_base & relative_effort: Ok(42.0) })
    Num.abs(r.tss - 42.0) < 0.001

# nothing at all -> honest zero, model "none"
expect
    r = tss_ladder(ladder_base)
    Num.abs(r.tss) < 0.001 and Result.is_err(r.np) and r.model == "none"

# provenance: each rung reports which model scored it
expect
    a = tss_ladder({ ladder_base & np_stream: Ok(200.0) })
    b = tss_ladder({ ladder_base & zones: { test_zeroz & z2: 3600 } })
    c = tss_ladder({ ladder_base & relative_effort: Ok(42.0) })
    a.model == "power_stream" and b.model == "hr_zones" and c.model == "relative_effort"

# sRPE: 45min at RPE 7 -> 52.5 (hours x RPE x 10, TSS-commensurate)
expect Num.abs(srpe_load({ rpe: 7.0, moving_time: 2700 }) - 52.5) < 0.001

# ENDURANCE ride with HR AND rpe: measured HR wins over reported RPE
expect
    r = tss_ladder({ ladder_base & zones: { test_zeroz & z2: 3600 }, rpe: Ok(9.0) })
    r.model == "hr_zones" and Num.abs(r.tss - 55.0) < 0.001

# STRENGTH session with junk-free HR AND rpe: the athlete's rating wins
expect
    r = tss_ladder({ ladder_base & sport_type: "Workout", zones: { test_zeroz & z2: 3600 }, rpe: Ok(7.0), moving_time: 2700 })
    r.model == "session_rpe" and Num.abs(r.tss - 52.5) < 0.001

# strength WITHOUT a rating still falls back to HR (never zero when data exists)
expect
    r = tss_ladder({ ladder_base & sport_type: "Workout", zones: { test_zeroz & z2: 3600 } })
    r.model == "hr_zones"

expect sport_class("Ride") == Endurance and sport_class("WeightTraining") == StrengthLike and sport_class("Workout") == StrengthLike

# Sun Jul 26 and Mon Jul 27 2026 land in different Monday-aligned weeks
expect
    sun = days_from_civil(2026, 7, 26)
    mon = days_from_civil(2026, 7, 27)
    weeks = weekly_rollup([
        { days: sun, tss: 50.0, ctl: 20.0, atl: 25.0, tsb: -5.0 },
        { days: mon, tss: 70.0, ctl: 21.0, atl: 27.0, tsb: -6.0 },
    ])
    List.len(weeks) == 2 and (Result.with_default(List.last(weeks), { week_start: 0, tss: 0, sessions: 0, ctl_end: 0, tsb_end: 0 })).week_start == mon

# same-week days aggregate: tss sums, sessions count trained days, end values stick
expect
    tue = days_from_civil(2026, 7, 21)
    wed = days_from_civil(2026, 7, 22)
    weeks = weekly_rollup([
        { days: tue, tss: 73.0, ctl: 24.0, atl: 31.0, tsb: -2.0 },
        { days: wed, tss: 0.0, ctl: 23.0, atl: 27.0, tsb: -8.0 },
    ])
    w = Result.with_default(List.first(weeks), { week_start: 0, tss: 0, sessions: 9, ctl_end: 0, tsb_end: 0 })
    List.len(weeks) == 1 and w.sessions == 1 and Num.abs(w.tss - 73.0) < 0.001 and Num.abs(w.tsb_end - (-8.0)) < 0.001 and w.week_start == days_from_civil(2026, 7, 20)

# load_step: same-day form (tsb = today's ctl - today's atl); a rest day (tss 0)
# decays both, fatigue (7d) faster than fitness (42d)
expect
    s = load_step({ ctl_prev: 50.0, atl_prev: 60.0, tss: 0.0 })
    Num.abs(s.ctl - (50.0 - 50.0 / 42.0)) < 0.001
    and Num.abs(s.atl - (60.0 - 60.0 / 7.0)) < 0.001
    and Num.abs(s.tsb - (s.ctl - s.atl)) < 0.001 # tsb reconciles same-day
    and (60.0 - s.atl) > (50.0 - s.ctl) # fatigue shed more than fitness on a rest day

# load_step: a hard day (tss above both) raises fitness and fatigue, and form
# drops negative same-day because fatigue jumps faster than fitness
expect
    s = load_step({ ctl_prev: 20.0, atl_prev: 20.0, tss: 90.0 })
    s.ctl > 20.0 and s.atl > 20.0 and s.atl > s.ctl
    and Num.abs(s.tsb - (s.ctl - s.atl)) < 0.001 and s.tsb < 0.0

# ftp_calibration: 20-min best 256 -> est 243.2; against config 190 that's stale
expect
    c = ftp_calibration({ best_20min: 256.0, ftp: 190.0 })
    Num.abs(c.est - 243.2) < 0.001 and c.stale and !(c.detraining)

# ftp_calibration: est well under config flags detraining, not stale
expect
    c = ftp_calibration({ best_20min: 180.0, ftp: 243.0 })
    c.detraining and !(c.stale)

# ftp_calibration: est near config is neither stale nor detraining
expect
    c = ftp_calibration({ best_20min: 250.0, ftp: 243.0 })
    !(c.stale) and !(c.detraining)

expect valid_hr(150.0) and !(valid_hr(20.0)) and !(valid_hr(230.0)) and valid_hr(35.0) and valid_hr(220.0)
expect valid_watts(200.0) and valid_watts(0.0) and valid_watts(2500.0) and !(valid_watts(-5.0)) and !(valid_watts(9999.0))

# power intensity split (ftp 243): 100W=41% easy, 200W=82% moderate, 243W=100% hard
expect
    r = time_in_power_intensity([{ t: 0, v: 100.0 }, { t: 1, v: 100.0 }, { t: 2, v: 100.0 }], 243.0)
    r.easy_s == 2 and r.moderate_s == 0 and r.hard_s == 0
expect
    r = time_in_power_intensity([{ t: 0, v: 200.0 }, { t: 1, v: 200.0 }, { t: 2, v: 200.0 }], 243.0)
    r.moderate_s == 2 and r.easy_s == 0 and r.hard_s == 0
expect
    r = time_in_power_intensity([{ t: 0, v: 243.0 }, { t: 1, v: 243.0 }, { t: 2, v: 243.0 }], 243.0)
    r.hard_s == 2 and r.easy_s == 0 and r.moderate_s == 0
expect time_in_power_intensity([{ t: 0, v: 243.0 }], 0.0) == { easy_s: 0, moderate_s: 0, hard_s: 0 }

# generic: every sport maps to its own config key, no hardcoded allowlist. A sport
# without that key set (or with no power meter) resolves to 0 in sport_ftp! and falls
# back to HR — so swimming, soccer, paddleboard all "just work" once configured.
expect power_ftp_key("Ride") == "ftp_ride"
expect power_ftp_key("Rowing") == "ftp_rowing"
expect power_ftp_key("Swim") == "ftp_swim"
expect power_ftp_key("Soccer") == "ftp_soccer"
expect power_ftp_key("StandUpPaddling") == "ftp_standuppaddling"

expect export_date_to_iso("Feb 17, 2022, 12:18:26 PM") == Ok("2022-02-17T12:18:26Z")
expect export_date_to_iso("Jul 4, 2026, 6:05:09 AM") == Ok("2026-07-04T06:05:09Z")
expect export_date_to_iso("Dec 31, 2025, 12:00:00 AM") == Ok("2025-12-31T00:00:00Z")
expect export_date_to_iso("17 Feb 2022") == Err(BadExportDate)


expect parse_utc_offset("-0500") == Ok(-300)
expect parse_utc_offset("+0530") == Ok(330)
expect parse_utc_offset("+0000") == Ok(0)
expect parse_utc_offset("INVALID") == Err(BadOffset)
expect parse_utc_offset("-05:0") == Err(BadOffset)

expect is_auto_name("Morning Ride") and is_auto_name("Lunch Gravel Ride") and !(is_auto_name("45 min Power Zone Ride with Matt Wilpers"))

# group_progress: adjacent same-name rows fold into one group per workout
expect
    pr = |name, date, dist| { name, date, sport: "Ride", distance_m: dist, moving_time: 3600, np_w: 100.0, avg_hr: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0 }
    gs = group_progress([pr("A", "2025-01-01", 0.0), pr("A", "2025-02-01", 0.0), pr("B", "2025-03-01", 0.0)])
    List.len(gs) == 2 and (List.first(gs) |> Result.map_ok(|g| List.len(g.rows) == 2) |> Result.with_default(Bool.false))

# anchor_filter: exact names pass through; auto-names gate to ±10% of anchor distance;
# distance-less auto-name anchors show alone; off-date anchors drop the group
expect
    pr = |name, date, dist| { name, date, sport: "Ride", distance_m: dist, moving_time: 3600, np_w: 100.0, avg_hr: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0 }
    exact = anchor_filter({ name: "Class X", rows: [pr("Class X", "2025-01-01", 0.0)] }, "2025-01-01")
    gated = anchor_filter({ name: "Morning Ride", rows: [pr("Morning Ride", "2025-01-01", 20000.0), pr("Morning Ride", "2025-02-01", 21000.0), pr("Morning Ride", "2025-03-01", 40000.0)] }, "2025-01-01")
    lone = anchor_filter({ name: "Morning Ride", rows: [pr("Morning Ride", "2025-01-01", 0.0), pr("Morning Ride", "2025-02-01", 21000.0)] }, "2025-01-01")
    off = anchor_filter({ name: "Class X", rows: [pr("Class X", "2025-01-01", 0.0)] }, "2025-09-09")
    ok_exact = when exact is
        Ok({ kind: Exact, rows }) -> List.len(rows) == 1
        _ -> Bool.false
    ok_gated = when gated is
        Ok({ kind: SimilarDistance(d), rows }) -> List.len(rows) == 2 and Num.abs(d - 20000.0) < 0.001
        _ -> Bool.false
    ok_lone = when lone is
        Ok({ kind: LoneNoDistance, rows }) -> List.len(rows) == 1
        _ -> Bool.false
    ok_off = when off is
        Err(NoAnchor) -> Bool.true
        _ -> Bool.false
    ok_exact and ok_gated and ok_lone and ok_off

expect Num.abs(mean([1.0, 2.0, 3.0]) - 2.0) < 0.001 and Num.abs(mean([])) < 0.001

expect Num.abs(pct_change(2.0, 3.0) - 50.0) < 0.001 and Num.abs(pct_change(0.0, 3.0)) < 0.001

# bar scaling: lo -> 1 block, hi -> all blocks, degenerate range -> all blocks
expect scale_to_blocks(1.2, 1.2, 1.8, 12) == 1 and scale_to_blocks(1.8, 1.2, 1.8, 12) == 12 and scale_to_blocks(1.5, 1.5, 1.5, 12) == 12

# trend_ends: first third avg vs last third avg (rising series -> late > early)
expect
    e = trend_ends([1.0, 1.0, 1.0, 2.0, 2.0, 2.0])
    Num.abs(e.early - 1.0) < 0.001 and Num.abs(e.late - 2.0) < 0.001

# single point: early == late == that point (no trend)
expect
    e = trend_ends([1.5])
    Num.abs(e.early - 1.5) < 0.001 and Num.abs(e.late - 1.5) < 0.001

# power zones: 7 zones; Z4 (threshold) is 91-105% FTP
expect
    zs = power_zones(200.0)
    z4 = Result.with_default(List.get(zs, 3), { z: "", name: "", lo_w: 0.0, hi_w: 0.0 })
    List.len(zs) == 7 and Num.abs(z4.lo_w - 182.0) < 0.001 and Num.abs(z4.hi_w - 210.0) < 0.001

# Z1 opens at 0, Z7 is open above (hi_w = 0 sentinel)
expect
    zs = power_zones(243.0)
    z1 = Result.with_default(List.first(zs), { z: "", name: "", lo_w: 9.0, hi_w: 0.0 })
    z7 = Result.with_default(List.last(zs), { z: "", name: "", lo_w: 0.0, hi_w: 9.0 })
    Num.abs(z1.lo_w) < 0.001 and Num.abs(z7.hi_w) < 0.001

expect form_label(-20.0) == "high modeled fatigue — consider recovery"
expect form_label(-9.0) == "modeled fatigue building — favor easy work"
expect form_label(-1.0) == "balanced — good day for intensity if you feel it"
expect form_label(8.0) == "fresh — good day for a big effort"
expect form_label(20.0) == "very fresh — load has been light lately"

# epoch day 0 is 1970-01-01, and roundtrips
expect days_from_civil(1970, 1, 1) == 0
expect days_to_date_str(0) == "1970-01-01"
expect date_str_to_days("2026-07-25T15:30:21Z") == Ok(days_from_civil(2026, 7, 25))
expect
    days = Result.with_default(date_str_to_days("2026-07-25"), 0)
    days_to_date_str(days) == "2026-07-25"

# leap-year boundary roundtrip
expect days_to_date_str(days_from_civil(2024, 2, 29)) == "2024-02-29"

# day-of-week: 2026-07-27 is a Monday (the anchor), through the week
expect day_of_week(days_from_civil(2026, 7, 27)) == "Mon"
expect day_of_week(days_from_civil(2026, 7, 28)) == "Tue"
expect day_of_week(days_from_civil(2026, 8, 2)) == "Sun"
expect day_of_week(0) == "Thu" # epoch day 0 = 1970-01-01 = Thursday

# epoch -> ISO datetime (UTC)
expect epoch_to_iso(0) == "1970-01-01T00:00:00Z"
expect epoch_to_iso(1000000000) == "2001-09-09T01:46:40Z"
