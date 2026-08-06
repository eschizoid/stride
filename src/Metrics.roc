Metrics :: [].{
    # ── pure training-science math. no I/O, fully unit-tested. ──────────

    ZoneBounds : { z1_max : F64, z2_max : F64, z3_max : F64, z4_max : F64 }
    ZoneSeconds : { z1 : I64, z2 : I64, z3 : I64, z4 : I64, z5 : I64 }

    # ── resampling ──────────────────────────────────────────────────────
    # Strava streams are (elapsed_second, value) samples with gaps.
    # Resample to 1 Hz by forward-filling gaps up to max_fill_gap seconds;
    # longer gaps are treated as pauses and not filled.

    max_fill_gap : I64
    max_fill_gap = 10

    # Resample to 1 Hz, returning (elapsed_second, value) pairs. ONE implementation for both
    # kinds of stream; the mode picks how a fillable gap is bridged:
    #
    #   Hold        — repeat the previous value. Correct for an INSTANTANEOUS signal
    #                 (watts, HR): you measured 200 W, you know nothing newer.
    #   Interpolate — walk linearly to the next value. Required for a CUMULATIVE signal
    #                 (distance): holding it flat and then differencing turns a 5-second
    #                 recording interval into four 0 m/s samples and one 20 m/s spike.
    #
    # Gaps longer than max_fill_gap are pauses and are never filled. Every pair carries its
    # REAL elapsed second, so a consumer can tell a genuine 1 Hz run from one that jumped —
    # which is what keeps a rolling window from stitching across a pause.
    resample_1s_pairs : List({ t : I64, v : F64 }), [Hold, Interpolate] -> List({ t : I64, v : F64 })
    resample_1s_pairs = |samples, mode|
        # Sort first: the fold assumes ascending timestamps, and a single out-of-order
        # sample used to be dropped WITHOUT advancing the anchor — so one spuriously large
        # timestamp swallowed every sample after it until the stream caught up. Strava
        # streams arrive ordered, but nothing enforced it and nothing tested it.
        List.fold(
            List.sort_with(samples, |a, b| I64.compare(a.t, b.t)),
            { out: [], prev_t: 0.I64, prev_v: 0.0.F64, started: False },
            |acc, s| resample_step(acc, s, mode),
        ).out

    # What to do with the next sample. Pure classification, kept flat and separate so the
    # step below reads as a four-case table instead of a staircase of nested else-ifs.
    resample_case : Bool, I64 -> [First, OutOfOrder, Fill, Pause]
    resample_case = |started, gap|
        if !started { First } else if gap <= 0 { OutOfOrder } else if gap <= max_fill_gap { Fill } else { Pause }

    resample_step = |acc, s, mode| {
        emit = |out| { out: List.append(out, { t: s.t, v: s.v }), prev_t: s.t, prev_v: s.v, started: True }
        gap = s.t - acc.prev_t
        match resample_case(acc.started, gap) {
            # a duplicate or backwards timestamp: ignore it, keep the anchor
            OutOfOrder => acc
            First => emit(acc.out)
            # pause — resume without filling; the real timestamp is preserved either way
            Pause => emit(acc.out)
            Fill => emit(fill_gap(acc.out, acc.prev_t, acc.prev_v, s.v, gap, mode))
        }
    }

    # the (gap - 1) intermediate seconds between two samples
    fill_gap = |out, prev_t, prev_v, next_v, gap, mode| {
        step = match mode {
            Hold => 0.0.F64
            Interpolate => (next_v - prev_v) / (gap).to_f64()
        }
        Iter.fold(
            1.U64..<(gap).to_u64_wrap(),
            out,
            |o, k| List.append(o, { t: prev_t + (k).to_i64_wrap(), v: prev_v + step * (k).to_f64() }),
        )
    }

    # values only, forward-held — the long-standing shape the NP path consumes
    resample_1s : List({ t : I64, v : F64 }) -> List(F64)
    resample_1s = |samples| List.map(resample_1s_pairs(samples, Hold), |p| p.v)

    # Resample a CONTINUOUS stream (distance, altitude) to 1 Hz by LINEAR INTERPOLATION,
    # returning (elapsed_second, value) pairs.
    #
    # `resample_1s` forward-HOLDS, which is correct for an instantaneous signal (watts, HR)
    # and WRONG for a cumulative one. Holding distance flat and then differencing it turns a
    # 5-second recording interval into four 0 m/s samples and one 20 m/s spike — five times
    # the true speed — which normalized_power then raises to the 4th power.
    #
    # Pauses (gap > max_fill_gap) are still not filled, but every pair carries its REAL
    # elapsed second, so a consumer that divides by dt sees the true interval instead of
    # collapsing a 60-second dropout into a single 1-second step.
    resample_1s_linear : List({ t : I64, v : F64 }) -> List({ t : I64, v : F64 })
    resample_1s_linear = |samples| resample_1s_pairs(samples, Interpolate)

    # ── normalized power ────────────────────────────────────────────────
    # 30s rolling average of 1 Hz power, each mean ^4, averaged, ^0.25.

    np_window : U64
    np_window = 30

    normalized_power : List(F64) -> Try(F64, [TooShort])
    normalized_power = |watts_1s| {
        n = List.len(watts_1s)
        if n < np_window {
            Err(TooShort)
        } else {
            prefix = List.fold(watts_1s, [0.0.F64], |acc, w| List.append(acc, last_or_zero(acc) + w))
            window_count = n - np_window + 1
            sum4 = Iter.fold(
                0.U64..<window_count,
                0.0.F64,
                |acc, i| {
                    hi = get_or_zero(prefix, i + np_window)
                    lo = get_or_zero(prefix, i)
                    window_avg = (hi - lo) / np_window.to_f64()
                    acc + (window_avg * window_avg * window_avg * window_avg)
                },
            )
            Ok((sum4 / window_count.to_f64()).pow(0.25))
        }
    }

    last_or_zero : List(F64) -> F64
    last_or_zero = |xs|
        List.last(xs).ok_or(0.0)

    get_or_zero : List(F64), U64 -> F64
    get_or_zero = |xs, i|
        List.get(xs, i).ok_or(0.0)

    # ── best rolling mean (e.g. the 20-min best power the derived FTP comes from) ──

    best_rolling_mean : List(F64), U64 -> Try(F64, [TooShort])
    best_rolling_mean = |xs_1s, window| {
        n = List.len(xs_1s)
        if n < window or window == 0 {
            Err(TooShort)
        } else {
            prefix = List.fold(xs_1s, [0.0.F64], |acc, w| List.append(acc, last_or_zero(acc) + w))
            best = Iter.fold(
                0.U64..<(n - window + 1),
                0.0.F64,
                |acc, i| {
                    window_avg = (get_or_zero(prefix, i + window) - get_or_zero(prefix, i)) / window.to_f64()
                    acc.max(window_avg)
                },
            )
            Ok(best)
        }
    }

    # Best rolling mean over a CONTIGUOUS window of real seconds.
    #
    # `best_rolling_mean` counts SAMPLES, and resampling deletes paused time — so on a
    # ride with a 4-minute stop, ten hard minutes either side land 1200 samples apart and
    # register as a "20-minute best" that was never sustained for 20 continuous minutes.
    # That number becomes MAX(best_20min_w) over 60 days, x0.95, the derived FTP that
    # scores EVERY activity. An inflated 20-minute best rescales the whole load history.
    #
    # Here a window only counts when its real elapsed time matches its sample count, i.e.
    # t[i + w - 1] - t[i] == w - 1. Windows spanning a pause are skipped, not averaged.
    best_rolling_mean_1s : List({ t : I64, v : F64 }), U64 -> Try(F64, [TooShort])
    best_rolling_mean_1s = |pairs, window| {
        n = List.len(pairs)
        if n < window or window == 0 {
            Err(TooShort)
        } else {
            vals = List.map(pairs, |p| p.v)
            prefix = List.fold(vals, [0.0.F64], |acc, w| List.append(acc, last_or_zero(acc) + w))
            best = Iter.fold(0.U64..<(n - window + 1), Err(NoWindow), |acc, i|
                if contiguous(pairs, i, window) {
                    mean = (get_or_zero(prefix, i + window) - get_or_zero(prefix, i)) / window.to_f64()
                    match acc {
                        Err(_) => Ok(mean)
                        Ok(b) => Ok(b.max(mean))
                    }
                } else {
                    acc
                }
            )
            match best {
                Ok(b) => Ok(b)
                # every window spanned a pause — no honest sustained effort of this length
                Err(_) => Err(TooShort)
            }
        }
    }

    # does the window starting at i cover `window` consecutive real seconds?
    contiguous = |pairs, i, window| {
        lo = List.get(pairs, i).map_ok(|p| p.t).ok_or(0.I64)
        hi = List.get(pairs, i + window - 1).map_ok(|p| p.t).ok_or(0.I64)
        hi - lo == (window - 1).to_i64_wrap()
    }

    # ── time in zones (HR-based, universal across sports) ───────────────
    # dt between consecutive samples, capped at 30s (pauses don't count),
    # attributed to the zone of the current sample.

    zone_of : F64, ZoneBounds -> U8
    zone_of = |hr, zb|
        if hr <= zb.z1_max {
            1
        } else if hr <= zb.z2_max {
            2
        } else if hr <= zb.z3_max {
            3
        } else if hr <= zb.z4_max {
            4
        } else {
            5
        }

    time_in_zones : List({ t : I64, v : F64 }), ZoneBounds -> ZoneSeconds
    time_in_zones = |samples, zb| {
        state = List.fold(
            samples,
            { z: { z1: 0.I64, z2: 0.I64, z3: 0.I64, z4: 0.I64, z5: 0.I64 }, prev_t: 0.I64, started: False },
            |acc, s|
                if !(acc.started) {
                    { ..acc, prev_t: s.t, started: True }
                } else {
                    dt = (s.t - acc.prev_t).min(30)
                    if dt <= 0 {
                        { ..acc, prev_t: s.t }
                    } else {
                        z = acc.z
                        updated =
                            match zone_of(s.v, zb) {
                                1 => { ..z, z1: z.z1 + dt }
                                2 => { ..z, z2: z.z2 + dt }
                                3 => { ..z, z3: z.z3 + dt }
                                4 => { ..z, z4: z.z4 + dt }
                                _ => { ..z, z5: z.z5 + dt }
                            }
                        { ..acc, z: updated, prev_t: s.t }
                    }
                },
        )
        state.z
    }

    # Intensity split from POWER, for a sport with a known threshold (FTP). Mirrors the
    # HR easy/moderate/hard split, but off power zones: easy < 76% FTP (Z1-2), moderate
    # 76-90% (Z3), hard >= 91% FTP (Z4+). For a power-equipped ride this is the truer
    # "how hard was it" — an athlete's threshold HR can sit right on a zone boundary, so
    # a genuine threshold effort reads as moderate by HR while the power says threshold.
    # Same 30s gap cap as the HR walk so a paused/dropped stream can't invent time.
    PowerIntensity : { easy_s : I64, moderate_s : I64, hard_s : I64 }

    # Which intensity band a power sample belongs to.
    #
    # Coasting is NOT easy riding. Freewheeling down a descent reads as zero watts, and
    # folding that into "easy" inflates the easy share — a descent-heavy ride came out
    # looking far more polarized than it was, which is exactly the number a coach reads to
    # decide the next week. Zero power is time not pedalling, so it is excluded from the
    # split: the three buckets sum to PEDALLING time, not moving time.
    power_band : F64, F64, F64 -> [Coasting, Easy, Moderate, Hard]
    power_band = |watts, mod_lo, hard_lo|
        if watts <= 0.0 { Coasting } else if watts < mod_lo { Easy } else if watts < hard_lo { Moderate } else { Hard }

    time_in_power_intensity : List({ t : I64, v : F64 }), F64 -> PowerIntensity
    time_in_power_intensity = |samples, ftp|
        if ftp <= 0.0 {
            { easy_s: 0, moderate_s: 0, hard_s: 0 }
        } else {
            mod_lo = ftp * 0.76
            hard_lo = ftp * 0.91
            state = List.fold(
                samples,
                { i: { easy_s: 0.I64, moderate_s: 0.I64, hard_s: 0.I64 }, prev_t: 0.I64, started: False },
                |acc, s|
                    if !(acc.started) {
                        { ..acc, prev_t: s.t, started: True }
                    } else {
                        dt = (s.t - acc.prev_t).min(30)
                        if dt <= 0 {
                            { ..acc, prev_t: s.t }
                        } else {
                            i = acc.i
                            updated =
                                match power_band(s.v, mod_lo, hard_lo) {
                                    Coasting => i
                                    Easy => { ..i, easy_s: i.easy_s + dt }
                                    Moderate => { ..i, moderate_s: i.moderate_s + dt }
                                    Hard => { ..i, hard_s: i.hard_s + dt }
                                }
                            { ..acc, i: updated, prev_t: s.t }
                        }
                    },
            )
            state.i
        }

    # pace analog of time_in_power_intensity, on the 1 Hz grade-adjusted speed stream (each
    # sample is 1 s, so no dt bookkeeping). Bands mirror the power split, faster = harder:
    # easy < 0.76×threshold, moderate 0.76–0.91, hard ≥ 0.91×threshold. Feeds the SAME pi_*
    # columns for pace-scored sports (runs/swims), so weekly polarization and the "hard" column
    # read a real intensity split there too. Zeros when the sport has no threshold speed.
    time_in_pace_intensity : List(F64), F64 -> PowerIntensity
    time_in_pace_intensity = |speeds_1s, threshold|
        if threshold <= 0.0 {
            { easy_s: 0, moderate_s: 0, hard_s: 0 }
        } else {
            mod_lo = threshold * 0.76
            hard_lo = threshold * 0.91
            List.fold(
                speeds_1s,
                { easy_s: 0.I64, moderate_s: 0.I64, hard_s: 0.I64 },
                |i, v|
                    if v < mod_lo {
                        { ..i, easy_s: i.easy_s + 1 }
                    } else if v < hard_lo {
                        { ..i, moderate_s: i.moderate_s + 1 }
                    } else {
                        { ..i, hard_s: i.hard_s + 1 }
                    },
            )
        }

    # The config key holding a sport's HR zone ceiling, per zone n (1..4). Per-sport
    # `hr_z<n>_max_<sport>` (hr_z2_max_soccer, …), resolved with the global
    # `hr_z<n>_max` as fallback: HR zones CAN differ by sport (a rowing Z2 ceiling
    # need not equal a running one), but most athletes share one set, so the global
    # covers the common case and a sport-specific key overrides only where it exists.
    # Built from the sport name, so no hardcoded list of sports can fall out of date.
    hr_zone_key : U64, Str -> Str
    hr_zone_key = |n, sport|
        "hr_z${U64.to_str(n)}_max_${Str.with_ascii_lowercased(sport)}"

    hr_zone_key_global : U64 -> Str
    hr_zone_key_global = |n|
        "hr_z${U64.to_str(n)}_max"

    # The config key holding a sport's threshold PACE, as a SPEED in m/s (the pace engine
    # works in speeds). Per-sport `threshold_pace_<sport>` (threshold_pace_run, ...), same
    # built from the sport name, no hardcoded list. Zero-config derivation from a stored
    # best-sustained-pace column is a later slice.
    threshold_pace_key : Str -> Str
    threshold_pace_key = |sport|
        "threshold_pace_${Str.with_ascii_lowercased(sport)}"

    # The config key selecting a sport's intensity MODEL (power | pace | css | hr | rpe),
    # `model_<sport>`. Orthogonal to sport_class (which sets fallback priority) — this picks
    # which ladder rung a sport routes to. Absent -> the safe default (power if watts, else HR).
    model_key : Str -> Str
    model_key = |sport|
        "model_${Str.with_ascii_lowercased(sport)}"

    # ── training stress ─────────────────────────────────────────────────

    tss_from_power : { np : F64, ftp : F64, dur_s : F64 } -> F64
    tss_from_power = |{ np, ftp, dur_s }|
        if ftp <= 0 {
            0
        } else {
            intensity = np / ftp
            (dur_s * np * intensity) / (ftp * 3600.0) * 100.0
        }

    # hrTSS heuristic: TSS per hour spent in each HR zone.
    # Standard coaching approximations (documented, deliberately simple).
    hr_tss_per_hour : { z1 : F64, z2 : F64, z3 : F64, z4 : F64, z5 : F64 }
    hr_tss_per_hour = { z1: 30.0, z2: 55.0, z3: 70.0, z4: 80.0, z5: 100.0 }

    hr_tss : ZoneSeconds -> F64
    hr_tss = |zs| {
        f = hr_tss_per_hour
        (zs.z1.to_f64() * f.z1 + zs.z2.to_f64() * f.z2 + zs.z3.to_f64() * f.z3 + zs.z4.to_f64() * f.z4 + zs.z5.to_f64() * f.z5) / 3600.0
    }

    # ── the TSS ladder ──────────────────────────────────────────────────
    # Best-available-data fallback chain, one decision in one testable place:
    #   stream NP -> Strava weighted watts -> avg watts -> zone-based hrTSS
    #   -> avg-HR classified into one zone -> relative_effort -> 0 (no data).
    # Returns the tss and the power figure used (Err NoPower if HR/RE path).

    # ── sport classification ────────────────────────────────────────────
    # Strength-class sports: HR-based load systematically underestimates them (the
    # aerobic model doesn't see bar weight), so user session-RPE outranks HR there.
    sport_class : Str -> [Endurance, StrengthLike]
    sport_class = |sport_type| {
        strengthish = ["WeightTraining", "Workout", "Crossfit", "HighIntensityIntervalTraining", "Yoga", "Pilates"]
        if List.contains(strengthish, sport_type) StrengthLike else Endurance
    }

    # ── session-RPE load (Foster) ───────────────────────────────────────
    # hours × RPE × 10, so one hour at RPE 10 = 100 — TSS-commensurate BY
    # CONSTRUCTION. Raw Foster units (minutes × RPE) would be ~6x too large and
    # corrupt CTL/ATL; do not "simplify" this back to minutes.
    srpe_load : { rpe : F64, moving_time : I64 } -> F64
    srpe_load = |{ rpe, moving_time }|
        (moving_time.to_f64() / 3600.0) * rpe * 10.0

    tss_ladder :
        {
            np_stream : Try(F64, [TooShort]),
            weighted_watts : Try(F64, [Missing]),
            avg_watts : Try(F64, [Missing]),
            avg_hr : Try(F64, [Missing]),
            relative_effort : Try(F64, [Missing]),
            rpe : Try(F64, [Missing]),
            sport_type : Str,
            zones : ZoneSeconds,
            zb : ZoneBounds,
            ftp : F64,
            # pace rung (m/s SPEEDS, not s/km): the normalized graded pace speed (Missing
            # for a non-pace sport or one without distance+altitude streams) and the sport's
            # threshold speed (0 when none). See pace_tss / normalized_graded_pace.
            ngp : Try(F64, [Missing]),
            threshold_speed : F64,
            dur_s : F64,
            moving_time : I64,
        }
        -> { tss : F64, np : Try(F64, [NoPower]), model : Str }
    tss_ladder = |input| {
        np_like =
            match input.np_stream {
                Ok(np) => Ok({ w: np, m: "power_stream" })
                Err(_) =>
                    match input.weighted_watts {
                        Ok(w) => Ok({ w, m: "weighted_watts" })
                        Err(_) =>
                            match input.avg_watts {
                                Ok(w) => Ok({ w, m: "avg_watts" })
                                Err(_) => Err(NoPower)
                            }
                    }
            }

        zone_total = input.zones.z1 + input.zones.z2 + input.zones.z3 + input.zones.z4 + input.zones.z5
        # measured HR load, when there is any usable HR at all
        hr_scored =
            if zone_total > 0 {
                Ok({ t: hr_tss(input.zones), m: "hr_zones" })
            } else {
                match input.avg_hr {
                    Ok(hr) => Ok({ t: hr_tss(all_seconds_in_zone(input.moving_time, zone_of(hr, input.zb))), m: "hr_avg" })
                    Err(_) => Err(NoHr)
                }
            }
        rpe_scored =
            match input.rpe {
                Ok(r) => Ok({ t: srpe_load({ rpe: r, moving_time: input.moving_time }), m: "session_rpe" })
                Err(_) => Err(NoRpe)
            }
        re_scored =
            match input.relative_effort {
                Ok(re) => Ok({ t: re, m: "relative_effort" })
                Err(_) => Err(NoRe)
            }

        # endurance: measured beats reported (power > HR > RPE > RE).
        # strength-like: the athlete's rating beats HR (power still wins if present —
        # a strength session with real watts is measured too).
        ordered =
            match sport_class(input.sport_type) {
                Endurance => [hr_scored, rpe_scored, re_scored]
                StrengthLike => [rpe_scored, hr_scored, re_scored]
            }
        # the HR/RPE/RE fallback ladder, used when there is no power OR no usable FTP
        fallback =
            List.fold_until(ordered, { t: 0.0, m: "none" }, |acc, candidate|
                match candidate {
                    Ok(pair) => Break(pair)
                    Err(_) => Continue(acc)
                })
        # pace rung, slotting in as power -> PACE -> HR -> RPE -> RE. Scores when a normalized
        # graded pace SPEED was computed (a pace-routed sport with distance+altitude streams)
        # AND a threshold speed exists; otherwise falls through to HR/RPE/RE. rTSS/sTSS is
        # IF^exp * hours * 100 with IF = ngp_speed / threshold_speed; the exponent is
        # per-sport (running 2, swimming 3 — see pace_tss_exponent).
        pace_or_fallback =
            match input.ngp {
                Ok(ngp_speed) =>
                    if input.threshold_speed > 0.0
                        { t: pace_tss({ ngp_speed, threshold_speed: input.threshold_speed, dur_s: input.dur_s, exponent: pace_tss_exponent(input.sport_type) }), m: "rtss" }
                    else
                        fallback
                Err(_) => fallback
            }
        scored =
            match np_like {
                # power scores ONLY with a usable FTP. Without one (no stream to derive it —
                # CSV imports, pre-backfill syncs), power would compute TSS 0 and, by winning
                # the ladder, BLOCK the rest — silently scoring a real ride 0. So fall through
                # to the pace rung / HR / RPE / RE when ftp <= 0.
                Ok(p) =>
                    if input.ftp > 0.0
                        { t: tss_from_power({ np: p.w, ftp: input.ftp, dur_s: input.dur_s }), m: p.m }
                    else
                        pace_or_fallback
                Err(_) => pace_or_fallback
            }
        { tss: scored.t, np: Try.map_ok(np_like, |p| p.w), model: scored.m }
    }

    all_seconds_in_zone : I64, U8 -> ZoneSeconds
    all_seconds_in_zone = |secs, zone| {
        zero = { z1: 0.I64, z2: 0.I64, z3: 0.I64, z4: 0.I64, z5: 0.I64 }
        match zone {
            1 => { ..zero, z1: secs }
            2 => { ..zero, z2: secs }
            3 => { ..zero, z3: secs }
            4 => { ..zero, z4: secs }
            _ => { ..zero, z5: secs }
        }
    }

    # ── daily load recurrence (CTL/ATL EWMA) ────────────────────────────
    # One day's step of the fitness/fatigue/form model:
    #   CTL (fitness)  = 42-day exponential moving average of daily TSS
    #   ATL (fatigue)  =  7-day exponential moving average of daily TSS
    #   TSB (form)     = TODAY's fitness minus TODAY's fatigue, so the number always
    #                    reconciles (tsb == ctl - atl) and reflects state AFTER today's
    #                    training. This is a deliberate departure from TrainingPeaks,
    #                    which reports yesterday's CTL - ATL so a hard day only shows up
    #                    in the next morning's form. Ours means the verdict printed right
    #                    after `analyze` already carries the session you just uploaded.

    load_step : { ctl_prev : F64, atl_prev : F64, tss : F64 } -> { ctl : F64, atl : F64, tsb : F64 }
    load_step = |{ ctl_prev, atl_prev, tss }| {
        ctl = ctl_prev + (tss - ctl_prev) / 42.0
        atl = atl_prev + (tss - atl_prev) / 7.0
        # same-day form: today's fitness minus today's fatigue, so the number
        # reconciles (tsb = ctl - atl) and reflects state AFTER today's training
        { ctl, atl, tsb: ctl - atl }
    }

    # ── FTP estimate ────────────────────────────────────────────────────
    # There is nothing to "calibrate" against: `Db.sport_ftp!` derives FTP from power
    # history and never reads config, so the estimate and the FTP are the same number by
    # construction and the stale/detraining comparison this section used to describe could
    # never fire. That function was deleted; the header outlived it.
    # (ADR 0002 as amended records the derivation; ADR 0005 anchors its 60-day window to
    # each activity's own date — it deliberately did NOT settle whether a configured value
    # should override, which is tracked separately.)

    # FTP estimate from a 20-min best: the standard 95% factor. One constant, one place —
    # used by the per-sport derive (Db.derive_sport_ftp!) and the summary display.
    ftp_from_best_20min : F64 -> F64
    ftp_from_best_20min = |best_20min| best_20min * 0.95

    # the standard power-duration ladder (seconds): 5s sprint .. 60min endurance
    power_curve_durations : List(U64)
    power_curve_durations = [5, 15, 30, 60, 300, 600, 1200, 3600]

    # best rolling-mean power at each ladder duration, from a 1 Hz watts stream. A duration
    # longer than the ride yields 0 (best_rolling_mean -> TooShort). Feeds the stored
    # best_<dur>_w columns and, aggregated across activities, the power-duration curve.
    mean_max_curve : List({ t : I64, v : F64 }), List(U64) -> List({ dur_s : U64, watts : F64 })
    mean_max_curve = |watts_1s, durations|
        List.map(durations, |d| {
            w =
                match best_rolling_mean_1s(watts_1s, d) {
                    Ok(v) => v
                    Err(_) => 0.0
                }
            { dur_s: d, watts: w }
        })

    # Critical Power model: P(t) = W'/t + CP. Fit by least-squares regression of power (y)
    # against 1/duration (x) — slope = W' (the finite anaerobic work capacity, joules),
    # intercept = CP (the sustainable aerobic ceiling, watts). Pass the mid-range bests
    # (~2-20 min) where the 2-parameter model holds; needs >= 2 points at distinct durations.
    critical_power : List({ dur_s : F64, watts : F64 }) -> Try({ cp : F64, w_prime : F64 }, [TooFew])
    critical_power = |points| {
        pts = List.keep_if(points, |p| p.dur_s > 0.0 and p.watts > 0.0)
        n = List.len(pts)
        if n < 2
            Err(TooFew)
        else {
            nf = n.to_f64()
            mx = List.fold(pts, 0.0, |a, p| a + 1.0 / p.dur_s) / nf
            my = List.fold(pts, 0.0, |a, p| a + p.watts) / nf
            sxx = List.fold(pts, 0.0, |a, p| {
                dx = 1.0 / p.dur_s - mx
                a + dx * dx
            })
            sxy = List.fold(pts, 0.0, |a, p| {
                dx = 1.0 / p.dur_s - mx
                dy = p.watts - my
                a + dx * dy
            })
            # sxx == 0 means every point is at the same duration — can't fit a line
            if sxx < 0.0000001
                Err(TooFew)
            else {
                w_prime = sxy / sxx
                cp = my - w_prime * mx
                # A fit can land on a negative CP or W' (noisy or near-collinear points).
                # Neither is physically meaningful, so refuse rather than hand back a
                # nonsense number the caller has to remember to check.
                if cp <= 0.0 or w_prime <= 0.0 { Err(TooFew) } else { Ok({ cp, w_prime }) }
            }
        }
    }

    # ── power zones (Coggan / Peloton 7-zone model, watt ranges from FTP) ─
    # lo_w = 0 means the zone starts at 0 (Z1); hi_w = 0 means it is open above (Z7).
    power_zones : F64 -> List({ z : Str, name : Str, lo_w : F64, hi_w : F64 })
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
    trend_ends : List(F64) -> { early : F64, late : F64 }
    trend_ends = |xs| {
        n = List.len(xs)
        if n == 0 {
            { early: 0.0, late: 0.0 }
        } else {
            k = (n // 3).max(1)
            { early: mean(List.take_first(xs, k)), late: mean(List.take_last(xs, k)) }
        }
    }

    # mean of a float list; 0.0 on empty
    mean : List(F64) -> F64
    mean = |ys| if List.is_empty(ys) 0.0 else List.sum(ys) / List.len(ys).to_f64()

    # Percent change from -> to. A non-positive `from` means there is NOTHING to measure
    # against, which is a different fact from "measured, and it did not change" — both used
    # to come back as 0.0, so a first-ever week read as "load steady (0%)". The Try makes the
    # caller say which one it means.
    pct_change : F64, F64 -> Try(F64, [NoBaseline])
    pct_change = |from, to| if from > 0.0 { Ok((to - from) / from * 100.0) } else { Err(NoBaseline) }

    # scale a value in [lo, hi] to 1..blocks bar segments (lo -> 1, hi -> blocks);
    # degenerate range -> full bar
    scale_to_blocks : F64, F64, F64, U64 -> U64
    scale_to_blocks = |value, lo, hi, blocks|
        if (hi - lo).abs() < 0.001 {
            blocks
        } else {
            1 + ((value - lo) / (hi - lo) * (blocks - 1).to_f64()).round_to_u64_try().ok_or(0)
        }

    # ── repeated-workout progress (the `progress` command's business rules) ─
    ProgressRow : { name : Str, date : Str, sport : Str, distance_m : F64, moving_time : I64, np_w : F64, avg_hr : F64, rpe : F64, output_kj : F64, tss : F64, load_model : Str }

    # split rows (already sorted by name) into per-workout runs
    group_progress : List(ProgressRow) -> List({ name : Str, rows : List(ProgressRow) })
    group_progress = |rows|
        List.fold(rows, [], |acc, r|
            match List.last(acc) {
                Ok(g) if g.name == r.name =>
                    List.set(acc, List.len(acc) - 1, { name: g.name, rows: List.append(g.rows, r) }).ok_or(acc)

                _ => List.append(acc, { name: r.name, rows: [r] })
            })

    # which comparison a group's anchor (the instance on the asked date) supports:
    # exact-named workouts compare every instance; auto-named rides ("Morning Ride")
    # are different routes under one name, so only rides within ±10% of the anchor's
    # distance compare — and with no distance recorded, only the anchor itself shows.
    # Groups whose anchor isn't on the asked date drop entirely.
    anchor_filter : { name : Str, rows : List(ProgressRow) }, Str -> Try({ name : Str, kind : [Exact, SimilarDistance(F64), LoneNoDistance], rows : List(ProgressRow) }, [NoAnchor])
    anchor_filter = |g, date|
        match List.find_first(g.rows, |r| r.date == date) {
            Err(_) => Err(NoAnchor)
            Ok(anchor) =>
                if !(is_auto_name(g.name)) {
                    Ok({ name: g.name, kind: Exact, rows: g.rows })
                } else if anchor.distance_m <= 0.0 {
                    Ok({ name: g.name, kind: LoneNoDistance, rows: [anchor] })
                } else {
                    kept = List.keep_if(g.rows, |r| (r.distance_m - anchor.distance_m).abs() <= anchor.distance_m * 0.10)
                    Ok({ name: g.name, kind: SimilarDistance(anchor.distance_m), rows: kept })
                }
        }

    # confidence tiers (high = measured power, medium = HR/RPE, low = relative_effort,
    # none = unscored) are derived from load_model at READ time in the doctor query
    # (see the CASE there). Not stored — it's a pure function of a column that already
    # exists, so a column would be redundant denormalization.

    # Parse a POSIX `date +%z` offset ("+HHMM" / "-HHMM", ASCII digits) into signed
    # minutes east of UTC: "-0500" -> -300, "+0530" -> 330. Used to turn a system
    # timezone into the current civil-day offset (DST-correct for today).
    parse_utc_offset : Str -> Try(I64, [BadOffset])
    parse_utc_offset = |raw|
        match Str.trim(raw).to_utf8() {
            [sign, h1, h2, m1, m2] => {
                digit = |b| if b >= 48 and b <= 57 Ok(b.to_i64() - 48) else Err(BadOffset)
                hh = (digit(h1)? * 10) + digit(h2)?
                mm = (digit(m1)? * 10) + digit(m2)?
                mag = (hh * 60) + mm
                if sign == 45 {
                    Ok(-mag)
                } else if sign == 43 {
                    Ok(mag)
                } else {
                    Err(BadOffset)
                }
            }
            _ => Err(BadOffset)
        }

    # ── progress lens: which "am I improving?" metric fits this workout ──
    # Power sports compare Efficiency Factor; distance sports without power compare
    # aerobic efficiency (speed per heartbeat); rated sessions (strength/HIIT/yoga)
    # compare RPE — and for a FIXED workout, a dropping RPE means you adapted, so
    # that lens is lower-is-better. Chosen by what data the group actually carries.
    Lens : [Ef, SpeedHr, Rpe]

    # Which load models put a NORMALIZED power number in the np_w column. Our own
    # power_stream NP and Strava's weighted_avg_watts are the same quantity computed the
    # same way, so they are comparable. Plain avg_watts is NOT — it is a different metric
    # wearing the same column, and trending it against NP invents an improvement.
    np_like : Str -> Bool
    np_like = |load_model| load_model == "power_stream" or load_model == "weighted_watts"

    lens_score : Lens, ProgressRow -> Try(F64, [Unscorable])
    lens_score = |lens, r|
        match lens {
            # EF is NP-per-heartbeat, so it is only comparable when np_w really IS normalized
            # power. The ladder stores whichever power rung won, so a row scored from plain
            # avg_watts would put avg-watts-per-beat on the same trend line as NP-per-beat and
            # invent a fake improvement for anyone whose newer rides have streams.
            Ef =>
                if r.np_w > 0.0 and r.avg_hr > 0.0 and np_like(r.load_model) {
                    Ok(r.np_w / r.avg_hr)
                } else {
                    Err(Unscorable)
                }
            SpeedHr =>
                if r.distance_m > 0.0 and r.avg_hr > 0.0 and r.moving_time > 0 {
                    Ok((r.distance_m / r.moving_time.to_f64() * 60.0) / r.avg_hr)
                } else {
                    Err(Unscorable)
                }

            Rpe => if r.rpe > 0.0 Ok(r.rpe) else Err(Unscorable)
        }

    # RPE is the only lens where a lower number is the better result
    lens_higher_better : Lens -> Bool
    lens_higher_better = |lens|
        match lens {
            Rpe => False
            _ => True
        }

    # pick the richest lens the group can actually compute (power > speed/HR > RPE)
    progress_lens : List(ProgressRow) -> [Ef, SpeedHr, Rpe, Unscorable]
    progress_lens = |rows| {
        scorable = |lens| List.any(rows, |r| lens_score(lens, r).is_ok())
        if scorable(Ef) {
            Ef
        } else if scorable(SpeedHr) {
            SpeedHr
        } else if scorable(Rpe) {
            Rpe
        } else {
            Unscorable
        }
    }

    # ── Strava bulk-export date parsing ─────────────────────────────────
    # activities.csv dates look like "Feb 17, 2022, 12:18:26 PM" (English-language
    # exports only — that's a documented Strava export caveat, not ours).
    export_date_to_iso : Str -> Try(Str, [BadExportDate])
    export_date_to_iso = |raw|
        match Str.split_on(Str.trim(raw), ", ") {
            [month_day, year, clock] =>
                match (Str.split_on(month_day, " "), Str.split_on(clock, " ")) {
                    ([mon, day], [hms, ampm]) => {
                        month = month_num(mon)?
                        day_n = Try.map_err(U64.from_str(day), |_| BadExportDate)?
                        hour24 = hour_24(hms, ampm)?
                        rest =
                            match Str.split_on(hms, ":") {
                                [_, mi, se] => Ok("${mi}:${se}")
                                _ => Err(BadExportDate)
                            }
                        Ok("${year}-${pad2(month.to_i64_wrap())}-${pad2(day_n.to_i64_wrap())}T${pad2(hour24.to_i64_wrap())}:${rest?}Z")
                    }

                    _ => Err(BadExportDate)
                }

            _ => Err(BadExportDate)
        }

    month_num : Str -> Try(U64, [BadExportDate])
    month_num = |m|
        match m {
            "Jan" => Ok(1)
            "Feb" => Ok(2)
            "Mar" => Ok(3)
            "Apr" => Ok(4)
            "May" => Ok(5)
            "Jun" => Ok(6)
            "Jul" => Ok(7)
            "Aug" => Ok(8)
            "Sep" => Ok(9)
            "Oct" => Ok(10)
            "Nov" => Ok(11)
            "Dec" => Ok(12)
            _ => Err(BadExportDate)
        }

    hour_24 : Str, Str -> Try(U64, [BadExportDate])
    hour_24 = |hms, ampm| {
        h =
            match Str.split_on(hms, ":") {
                [hh, _, _] => Try.map_err(U64.from_str(hh), |_| BadExportDate)
                _ => Err(BadExportDate)
            }
        hour = h?
        match ampm {
            "AM" => Ok(if hour == 12 0 else hour)
            "PM" => Ok(if hour == 12 12 else hour + 12)
            _ => Err(BadExportDate)
        }
    }

    # ── Strava auto-names ───────────────────────────────────────────────
    # "Morning Ride", "Lunch Gravel Ride", ... are Strava's time-of-day defaults: the
    # same name covers DIFFERENT routes, so name-matching them compares unlike efforts.
    is_auto_name : Str -> Bool
    is_auto_name = |name|
        match Str.split_first(name, " ") {
            Ok({ before, .. }) => List.contains(["Morning", "Lunch", "Afternoon", "Evening", "Night"], before)
            Err(_) => False
        }

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
        if tsb <= -15.0 {
            "high modeled fatigue — consider recovery"
        } else if tsb <= -5.0 {
            "modeled fatigue building — favor easy work"
        } else if tsb < 5.0 {
            "balanced — good day for intensity if you feel it"
        } else if tsb < 15.0 {
            "fresh — good day for a big effort"
        } else {
            "very fresh — load has been light lately"
        }

    # ── weekly rollup (Monday-aligned, the user's week convention) ──────
    # epoch day 0 = Thursday, so (days + 3) // 7 increments every Monday.

    weekly_rollup : List({ days : I64, tss : F64, ctl : F64, atl : F64, tsb : F64 }) -> List({ week_start : I64, tss : F64, sessions : I64, ctl_end : F64, tsb_end : F64 })
    weekly_rollup = |day_rows|
        List.fold(day_rows, [], |acc, d| {
            ws = ((d.days + 3) // 7) * 7 - 3
            sess : I64
            # any scored day counts. The old >= 1.0 floor silently dropped genuinely short
            # or lightly-scored sessions from the count. (A day that scores EXACTLY 0 — a
            # strength session whose HR strap produced junk — still cannot be counted here:
            # daily_load carries load, not a session count. That needs a stored count, not
            # a smaller threshold, so it is left honest rather than guessed at.)
            sess = if d.tss > 0.0 1 else 0
            match List.last(acc) {
                Ok(w) =>
                    if w.week_start == ws {
                        List.set(acc, List.len(acc) - 1, {
                            week_start: ws,
                            tss: w.tss + d.tss,
                            sessions: w.sessions + sess,
                            ctl_end: d.ctl,
                            tsb_end: d.tsb,
                        }).ok_or(acc)
                    } else {
                        List.append(acc, { week_start: ws, tss: d.tss, sessions: sess, ctl_end: d.ctl, tsb_end: d.tsb })
                    }

                Err(_) => List.append(acc, { week_start: ws, tss: d.tss, sessions: sess, ctl_end: d.ctl, tsb_end: d.tsb })
            }
        })

    # ── civil-date arithmetic (Howard Hinnant's algorithms) ─────────────

    days_from_civil : I64, I64, I64 -> I64
    days_from_civil = |y_in, m, d| {
        y = if m <= 2 (y_in - 1) else y_in
        era = (if y >= 0 y else y - 399) // 400
        yoe = y - era * 400
        mp = (m + 9) % 12
        doy = (153 * mp + 2) // 5 + d - 1
        doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
        era * 146097 + doe - 719468
    }

    civil_from_days : I64 -> { y : I64, m : I64, d : I64 }
    civil_from_days = |z_in| {
        z = z_in + 719468
        era = (if z >= 0 z else z - 146096) // 146097
        doe = z - era * 146097
        yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
        y = yoe + era * 400
        doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
        mp = (5 * doy + 2) // 153
        d = doy - (153 * mp + 2) // 5 + 1
        m = if mp < 10 (mp + 3) else mp - 9
        { y: (if m <= 2 (y + 1) else y), m, d }
    }

    # "2026-07-25T15:30:21Z" (or "2026-07-25") -> epoch day number
    date_str_to_days : Str -> Try(I64, [BadDate])
    date_str_to_days = |s| {
        date_part = List.first(Str.split_on(s, "T")).ok_or(s)
        match Str.split_on(date_part, "-") {
            [ys, ms, ds] =>
                match (I64.from_str(ys), I64.from_str(ms), I64.from_str(ds)) {
                    (Ok(y), Ok(m), Ok(d)) => Ok(days_from_civil(y, m, d))
                    _ => Err(BadDate)
                }

            _ => Err(BadDate)
        }
    }

    days_to_date_str : I64 -> Str
    days_to_date_str = |days| {
        c = civil_from_days(days)
        "${I64.to_str(c.y)}-${pad2(c.m)}-${pad2(c.d)}"
    }

    pad2 : I64 -> Str
    pad2 = |n|
        if n < 10 "0${I64.to_str(n)}" else I64.to_str(n)

    # epoch day number -> "Mon".."Sun". Epoch day 0 (1970-01-01) was a Thursday, so
    # (days + 3) mod 7 makes Monday = 0 (matches the Mon-aligned week convention).
    day_of_week : I64 -> Str
    day_of_week = |days|
        match (days + 3) % 7 {
            0 => "Mon"
            1 => "Tue"
            2 => "Wed"
            3 => "Thu"
            4 => "Fri"
            5 => "Sat"
            _ => "Sun"
        }

    # epoch seconds (UTC) -> "YYYY-MM-DDTHH:MM:SSZ" — so stored timestamps read like
    # the ISO dates elsewhere instead of a raw epoch integer
    epoch_to_iso : I64 -> Str
    epoch_to_iso = |epoch| {
        days = epoch // 86400
        tod = epoch % 86400
        c = civil_from_days(days)
        h = tod // 3600
        m = (tod % 3600) // 60
        s = tod % 60
        "${I64.to_str(c.y)}-${pad2(c.m)}-${pad2(c.d)}T${pad2(h)}:${pad2(m)}:${pad2(s)}Z"
    }

    # ── test helpers (used by the top-level expects) ─────────────────────

    # (Roc floats have no total equality — compare element-wise with tolerance)
    lists_approx_eq : List(F64), List(F64) -> Bool
    lists_approx_eq = |xs, ys|
        if List.len(xs) != List.len(ys) {
            False
        } else {
            List.all(List.map2(xs, ys, |a, b| (a - b).abs() < 0.001), |ok| ok)
        }

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
        ngp: Err(Missing),
        threshold_speed: 0.0,
        dur_s: 3600.0,
        moving_time: 3600,
    }

    # ── grade-adjusted running: Minetti et al. (2002) ────────────────
    # "Energy cost of walking and running at extreme uphill and downhill slopes."
    # Metabolic cost of running as a 5th-order polynomial of gradient i (rise/run):
    #   C(i) = 155.4*i^5 - 30.4*i^4 - 43.3*i^3 + 46.3*i^2 + 19.5*i + 3.6  (J/kg/m)
    # minetti_ratio returns the flat-equivalent factor C(i)/C(0): how many flat metres
    # a metre on this grade costs. Gradient is clamped to Minetti's measured +/-45%
    # range; the factor is floored at 0.4 so a steep descent can't collapse distance.
    minetti_ratio : F64 -> F64
    minetti_ratio = |grade| {
        i = grade.max(-0.45).min(0.45)
        c = (155.4 * i * i * i * i * i) - (30.4 * i * i * i * i) - (43.3 * i * i * i) + (46.3 * i * i) + (19.5 * i) + 3.6
        (c / 3.6).max(0.4)
    }

    # flat-equivalent distance: each segment's delta-distance weighted by its grade
    # factor. dist = cumulative metres, alt = metres, index-aligned (Strava distance +
    # altitude streams). Segments with non-positive delta-distance (GPS jitter / pauses)
    # contribute nothing; fewer than two samples -> 0. Pace reuses Render.pace_per_km.
    grade_adjusted_distance : List(F64), List(F64) -> F64
    grade_adjusted_distance = |dist, alt| {
        samples = List.map2(dist, alt, |d, a| { d, a })
        res = List.fold(samples, { prev: Err(NoPrev), gad: 0.0 }, |acc, s|
            match acc.prev {
                Err(_) => { prev: Ok(s), gad: acc.gad }
                Ok(p) => {
                    dd = s.d - p.d
                    if dd > 0.0 {
                        grade = (s.a - p.a) / dd
                        { prev: Ok(s), gad: acc.gad + (dd * minetti_ratio(grade)) }
                    } else {
                        # backwards/jitter/pause: keep the last VALID point as prev so
                        # this bad sample can't skew the next segment's distance or grade
                        acc
                    }
                }
            })
        res.gad
    }

    # ── pace-based load: rTSS/sTSS reuse the power machinery, in SPEED units ─────
    # Working in m/s (not s/km) keeps IF = ngp_speed / threshold_speed the RIGHT way
    # round (faster = harder), and NGP is normalized_power over a grade-adjusted SPEED
    # stream — not a scalar. rTSS/sTSS are then tss_from_power with speed for watts.

    # s/km -> m/s (0 for a non-positive pace)
    pace_to_speed : F64 -> F64
    pace_to_speed = |pace_s_per_km|
        if pace_s_per_km > 0.0 { 1000.0 / pace_s_per_km } else { 0.0 }

    # per-sample flat-equivalent (grade-adjusted) speed, from time/dist/alt streams that
    # MUST be equal-length and index-aligned (the nested map2 silently truncates to the
    # shortest — the analyze-wiring PR must filter the three as ONE unit): speed = Δd/Δt,
    # grade = Δalt/Δd, ga_speed = speed × minetti_ratio(grade). A non-advancing sample
    # (stop or jitter) re-anchors prev so its time drops out of the next speed (see the
    # branch below) — unlike grade_adjusted_distance. Swim: pass a MATCHING-LENGTH flat
    # altitude list (not []) and it degrades to raw speed (minetti(0)=1).
    # What one (prev -> sample) interval represents. Flat classification, so the step below
    # is a four-case table rather than a nested if/else-if staircase.
    #
    # `Gap` (dt > max_fill_gap) is deliberately NOT a speed sample. The resampler already
    # refuses to fill a gap that long — it is a pause or a dropout, and we do not know what
    # happened inside it. Emitting the interval average would contradict that policy twice
    # over: it invents data for unrecorded time, and it lands as ONE sample carrying a
    # minute of movement, which the 30-SAMPLE NP window then weights as a single second.
    # (This is the pace path — runs and swims — so nothing here is riding.)
    # Skipping it means the stream says "no data here", which is true.
    pace_step_case : F64, F64 -> [Moving, Stopped, NoTime, Gap]
    pace_step_case = |dt, dd|
        if dt <= 0.0 { NoTime } else if dt > (max_fill_gap).to_f64() { Gap } else if dd > 0.0 { Moving } else { Stopped }

    # grade-adjusted speed per interval, each carrying the REAL second it ends on, so a
    # rolling window over the result can tell contiguous seconds from stitched ones.
    grade_adjusted_speed_pairs : List(F64), List(F64), List(F64) -> List({ t : I64, v : F64 })
    grade_adjusted_speed_pairs = |time, dist, alt| {
        td = List.map2(time, dist, |t, d| { t, d })
        samples = List.map2(td, alt, |x, a| { t: x.t, d: x.d, a })
        List.fold(samples, { prev: Err(NoPrev), out: [] }, |acc, s|
            match acc.prev {
                Err(_) => { prev: Ok(s), out: acc.out }
                Ok(p) => grade_step(acc.out, p, s)
            }
        ).out
    }

    grade_step = |out, p, s| {
        dt = s.t - p.t
        dd = s.d - p.d
        match pace_step_case(dt, dd) {
            # Not moving forward (a stop, or backwards GPS jitter) while time elapsed:
            # re-anchor to THIS sample so the non-productive interval is dropped from the
            # next segment's speed denominator — speed divides by Δt, so stopped time must
            # not deflate it. (A sub-threshold "creep" still emits a slow sample.)
            Stopped => { prev: Ok(s), out }
            # no time elapsed (duplicate/backwards timestamp): keep the existing anchor
            NoTime => { prev: Ok(p), out }
            # unrecorded stretch longer than max_fill_gap: re-anchor and emit nothing
            Gap => { prev: Ok(s), out }
            Moving => {
                grade = (s.a - p.a) / dd
                speed = (dd / dt) * minetti_ratio(grade)
                { prev: Ok(s), out: List.append(out, { t: (s.t).round_to_i64_try().ok_or(0), v: speed }) }
            }
        }
    }

    grade_adjusted_speeds : List(F64), List(F64), List(F64) -> List(F64)
    grade_adjusted_speeds = |time, dist, alt|
        List.map(grade_adjusted_speed_pairs(time, dist, alt), |p| p.v)

    # Normalized Graded Pace as a SPEED (m/s): the grade-adjusted speed stream through
    # the same 30-SAMPLE-rolling / 4th-power machinery as NP. That window is 30 s only if
    # samples are ~1 Hz — the power path guarantees it via resample_1s; the analyze-wiring
    # PR should resample time/dist/alt to 1 Hz before calling here, or a variable-rate
    # stream over-smooths NGP toward the mean. (Swim NSS: flat altitude.)
    normalized_graded_pace : List(F64), List(F64), List(F64) -> Try(F64, [TooShort])
    normalized_graded_pace = |time, dist, alt|
        normalized_power(grade_adjusted_speeds(time, dist, alt))

    # 1 Hz grade-adjusted speed stream from an aligned time/dist/alt triple
    # (Streams.dist_alt_time): resample dist & alt onto a 1 Hz base, THEN grade-adjust —
    # NGP's 30-sample window is 30 s only at 1 Hz. Feed the result to normalized_power
    # (= the NGP speed) AND to best_rolling_mean (best sustained speed → derived threshold
    # pace). Computing the stream once and reusing it avoids grade-adjusting twice.
    graded_speed_1s : List(F64), List(F64), List(F64) -> List({ t : I64, v : F64 })
    graded_speed_1s = |time, dist, alt| {
        to_samples = |vals| List.map2(time, vals, |t, v| { t: (t).round_to_i64_try().ok_or(0), v })
        # LINEAR, not held: distance is cumulative, so holding it flat and differencing
        # would emit one spike per recording interval instead of a steady speed.
        dist_1s = resample_1s_linear(to_samples(dist))
        alt_1s = resample_1s_linear(to_samples(alt))
        # REAL elapsed seconds, not list indices: across an unfilled pause the index is off
        # by the whole pause, which would divide the distance covered by dt = 1.
        time_1s = List.map(dist_1s, |p| (p.t).to_f64())
        grade_adjusted_speed_pairs(time_1s, List.map(dist_1s, |p| p.v), List.map(alt_1s, |p| p.v))
    }

    # rTSS / sTSS: the power formula with speed swapped for watts — IF = ngp_speed /
    # threshold_speed (faster = harder), IF^exp × hours × 100. 1 h at threshold = 100 for
    # any exponent. The exponent is per-sport (see pace_tss_exponent immediately below):
    # running is near enough linear in speed so it keeps 2, matching TrainingPeaks rTSS;
    # swimming fights drag, which rises with v³, so it uses 3 like TrainingPeaks sSS. The
    # earlier version squared BOTH and under-scored hard swim sets by ~20%.
    # How metabolic cost scales with the speed ratio, per sport.
    #
    # Running resistance is near enough linear in speed, so rTSS keeps the familiar IF^2
    # (identical to tss_from_power). Swimming fights hydrodynamic DRAG, which rises with the
    # CUBE of speed — TrainingPeaks' sSS cubes the speed ratio for exactly this reason.
    # Squaring it under-scores hard swim sets badly: at IF 1.2, 144 vs 173 per hour.
    pace_tss_exponent : Str -> F64
    pace_tss_exponent = |sport|
        if Str.contains(Str.with_ascii_lowercased(sport), "swim") { 3.0 } else { 2.0 }

    pace_tss : { ngp_speed : F64, threshold_speed : F64, dur_s : F64, exponent : F64 } -> F64
    pace_tss = |{ ngp_speed, threshold_speed, dur_s, exponent }|
        if threshold_speed <= 0.0 {
            0.0
        } else {
            intensity = ngp_speed / threshold_speed
            (dur_s / 3600.0) * intensity.pow(exponent) * 100.0
        }
}

# ── tests ───────────────────────────────────────────────────────────

# lens selection: power ride -> Ef, run with pace+HR -> SpeedHr, rated strength -> Rpe
expect {
    row = |sport, np, dist, mt, rpe| { name: "X", date: "2025-01-01", sport, distance_m: dist, moving_time: mt, np_w: np, avg_hr: 150.0, rpe, output_kj: 0.0, tss: 0.0, load_model: "power_stream" }
    Metrics.progress_lens([row("Ride", 200.0, 0.0, 3600, 0.0)]) == Ef
    and Metrics.progress_lens([row("Run", 0.0, 10000.0, 3000, 0.0)]) == SpeedHr
    and Metrics.progress_lens([row("WeightTraining", 0.0, 0.0, 2700, 7.0)]) == Rpe
    and Metrics.progress_lens([row("Workout", 0.0, 0.0, 2700, 0.0)]) == Unscorable
}

# EF is only comparable between rows whose np_w really is NORMALIZED power. Our stream NP and
# Strava weighted watts qualify; plain avg_watts does not — it is a different metric wearing
# the same column, and trending it against NP invents an improvement. Same watts, same HR:
# provenance alone decides.
expect {
    row = |lm| { name: "X", date: "2025-01-01", sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: 200.0, avg_hr: 150.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: lm }
    Metrics.lens_score(Ef, row("power_stream")).is_ok()
    and Metrics.lens_score(Ef, row("avg_watts")).is_err()
    and Metrics.lens_score(Ef, row("weighted_watts")).is_ok()
}

# swim TSS cubes the speed ratio (drag), running squares it. At IF 1.2 for one hour that is
# 173 vs 144 — the square under-scores hard swim sets by ~20%.
expect {
    swim = Metrics.pace_tss({ ngp_speed: 1.2, threshold_speed: 1.0, dur_s: 3600.0, exponent: Metrics.pace_tss_exponent("Swim") })
    run = Metrics.pace_tss({ ngp_speed: 1.2, threshold_speed: 1.0, dur_s: 3600.0, exponent: Metrics.pace_tss_exponent("Run") })
    (swim - 172.8).abs() < 0.01 and (run - 144.0).abs() < 0.01
}

# at threshold both are 100 regardless of exponent — the curves only diverge off threshold
expect {
    swim = Metrics.pace_tss({ ngp_speed: 1.0, threshold_speed: 1.0, dur_s: 3600.0, exponent: 3.0 })
    (swim - 100.0).abs() < 0.001
}

# coasting is excluded from the intensity split, not counted as easy. 60 s pedalling at
# 100 W (easy vs FTP 250) then 60 s freewheeling at 0 W: easy is 60 s, not 120 s, and the
# buckets sum to pedalling time. Counting the descent as "easy" was what made a
# descent-heavy ride read as far more polarized than it really was.
expect {
    ride = List.map_with_index(List.repeat(0.0, 121), |_, i| {
        t: (i).to_i64_wrap(),
        v: (if i < 60 { 100.0 } else { 0.0 }),
    })
    pi = Metrics.time_in_power_intensity(ride, 250.0)
    pi.easy_s == 59 and pi.moderate_s == 0 and pi.hard_s == 0
}

# a hard effort still lands in hard, and real pedalling either side is not lost
expect {
    ride = List.map_with_index(List.repeat(0.0, 61), |_, i| { t: (i).to_i64_wrap(), v: 240.0.F64 })
    pi = Metrics.time_in_power_intensity(ride, 250.0)
    pi.hard_s == 60 and pi.easy_s == 0
}

# resample_1s_pairs sorts first. One out-of-order sample used to be dropped WITHOUT
# advancing the anchor, so a single large stray timestamp swallowed every sample after it.
# Same samples, shuffled: the result must be identical to the ordered case.
expect {
    ordered = [{ t: 0.I64, v: 0.0.F64 }, { t: 1.I64, v: 4.0.F64 }, { t: 2.I64, v: 8.0.F64 }]
    shuffled = [{ t: 2.I64, v: 8.0.F64 }, { t: 0.I64, v: 0.0.F64 }, { t: 1.I64, v: 4.0.F64 }]
    Metrics.resample_1s_pairs(ordered, Interpolate) == Metrics.resample_1s_pairs(shuffled, Interpolate)
}

# a stray far-future sample no longer eats the rest of the stream
expect {
    stray = [{ t: 0.I64, v: 0.0.F64 }, { t: 999.I64, v: 99.0.F64 }, { t: 1.I64, v: 4.0.F64 }, { t: 2.I64, v: 8.0.F64 }]
    pts = Metrics.resample_1s_pairs(stray, Interpolate)
    # 0,1,2 all survive (the 999 sample is a pause, kept but not filled)
    List.len(pts) == 4
}

# CTL/ATL convergence over MANY days — every other load test walks a single step, which
# cannot catch a wrong time constant. 42 consecutive days at TSS 100 from zero:
#   CTL = 100 * (1 - (1 - 1/42)^42) = 63.66   (one full time constant, ~63% of the way)
#   ATL = 100 * (1 - (1 - 1/7)^42)  = 99.85   (six of its own, essentially converged)
# TSB is deeply negative because fatigue has caught up and fitness has not.
expect {
    final = Iter.fold(0.U64..<42, { ctl: 0.0.F64, atl: 0.0.F64, tsb: 0.0.F64 }, |acc, _|
        Metrics.load_step({ ctl_prev: acc.ctl, atl_prev: acc.atl, tss: 100.0 })
    )
    (final.ctl - 63.66).abs() < 0.1
    and (final.atl - 99.85).abs() < 0.1
    and (final.tsb - (final.ctl - final.atl)).abs() < 0.001
    and final.tsb < -30.0
}

# a rest day decays both: no TSS means CTL and ATL both fall, and ATL falls faster (7 vs 42),
# so form RISES on rest — the whole point of the model
expect {
    trained = Iter.fold(0.U64..<42, { ctl: 0.0.F64, atl: 0.0.F64, tsb: 0.0.F64 }, |acc, _|
        Metrics.load_step({ ctl_prev: acc.ctl, atl_prev: acc.atl, tss: 100.0 })
    )
    rested = Metrics.load_step({ ctl_prev: trained.ctl, atl_prev: trained.atl, tss: 0.0 })
    rested.ctl < trained.ctl and rested.atl < trained.atl and rested.tsb > trained.tsb
}

# hrTSS per-hour weights follow Friel: 30 / 55 / 70 / 80 / 100. Only Z2 was pinned before,
# so Z4 sat at 85 unnoticed. One hour in each zone, one zone at a time.
expect {
    hour = |z| Metrics.hr_tss(z)
    zero = { z1: 0, z2: 0, z3: 0, z4: 0, z5: 0 }
    (hour({ ..zero, z1: 3600 }) - 30.0).abs() < 0.001
    and (hour({ ..zero, z2: 3600 }) - 55.0).abs() < 0.001
    and (hour({ ..zero, z3: 3600 }) - 70.0).abs() < 0.001
    and (hour({ ..zero, z4: 3600 }) - 80.0).abs() < 0.001
    and (hour({ ..zero, z5: 3600 }) - 100.0).abs() < 0.001
}

# critical_power refuses a physically meaningless fit instead of returning a negative CP
expect {
    # power RISING with duration -> negative W', which no athlete has
    match Metrics.critical_power([{ dur_s: 300.0, watts: 200.0 }, { dur_s: 1200.0, watts: 300.0 }]) {
        Err(TooFew) => 1 == 1
        Ok(_) => 1 == 0
    }
}

# EF = NP/HR; RPE is lower-is-better
expect {
    r = { name: "X", date: "d", sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: 300.0, avg_hr: 150.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream" }
    (Metrics.lens_score(Ef, r).ok_or(0.0) - 2.0).abs() < 0.001 and Metrics.lens_higher_better(Ef) and !(Metrics.lens_higher_better(Rpe))
}

# NP of constant power == that power
expect
    match Metrics.normalized_power(List.repeat(200.0, 3600)) {
        Ok(np) => (np - 200.0).abs() < 0.001
        Err(_) => False
    }

# NP requires at least 30 samples
expect Metrics.normalized_power(List.repeat(200.0, 10)).is_err()

# riding exactly at FTP for one hour == 100 TSS
expect {
    tss = Metrics.tss_from_power({ np: 190.0, ftp: 190.0, dur_s: 3600.0 })
    (tss - 100.0).abs() < 0.001
}

# half an hour at FTP == 50 TSS
expect {
    tss = Metrics.tss_from_power({ np: 190.0, ftp: 190.0, dur_s: 1800.0 })
    (tss - 50.0).abs() < 0.001
}

# TSS is quadratic in IF — pin it AWAY from IF == 1, where the `intensity` factor is a
# no-op and a formula missing it entirely would still pass the two tests above.
# 1 h at IF 0.8 -> 0.8^2 * 100 = 64.
expect {
    tss = Metrics.tss_from_power({ np: 152.0, ftp: 190.0, dur_s: 3600.0 })
    (tss - 64.0).abs() < 0.001
}

# 1 h at IF 1.1 -> 1.1^2 * 100 = 121. Above threshold, so it also pins that nothing clamps.
expect {
    tss = Metrics.tss_from_power({ np: 209.0, ftp: 190.0, dur_s: 3600.0 })
    (tss - 121.0).abs() < 0.001
}

# NP must 4th-power the 30-sample ROLLING MEANS, not the raw samples. Constant power
# can't tell those apart (both return the input), so use a step: 30 s @ 100 W then
# 30 s @ 300 W. The 31 rolling means ramp 100 -> 300 linearly, giving NP ~= 222;
# 4th-powering the raw samples instead — the classic NP bug — gives ~253. Only the
# correct implementation lands in this band.
expect {
    step = List.concat(List.repeat(100.0, 30), List.repeat(300.0, 30))
    match Metrics.normalized_power(step) {
        Ok(np) => np > 210.0 and np < 235.0
        Err(_) => False
    }
}

# ...and NP must exceed the plain average (200 W here) for any varying input — the
# whole point of the metric.
expect {
    step = List.concat(List.repeat(100.0, 30), List.repeat(300.0, 30))
    match Metrics.normalized_power(step) {
        Ok(np) => np > 200.0
        Err(_) => False
    }
}

# an hour fully in Z2 == 55 hrTSS
expect {
    tss = Metrics.hr_tss({ z1: 0, z2: 3600, z3: 0, z4: 0, z5: 0 })
    (tss - 55.0).abs() < 0.001
}

# zone classification against Mariano-shaped bounds
expect {
    zb = { z1_max: 123.0, z2_max: 153.0, z3_max: 168.0, z4_max: 183.0 }
    Metrics.zone_of(100.0, zb) == 1 and Metrics.zone_of(140.0, zb) == 2 and Metrics.zone_of(160.0, zb) == 3 and Metrics.zone_of(175.0, zb) == 4 and Metrics.zone_of(190.0, zb) == 5
}

# time_in_zones: 1 Hz samples, 10s in z1 then 10s in z5
expect {
    zb = { z1_max: 123.0, z2_max: 153.0, z3_max: 168.0, z4_max: 183.0 }
    low = Iter.fold(1.U64..=10.U64, [], |acc, i| List.append(acc, { t: i.to_i64_wrap(), v: 100.0 }))
    high = Iter.fold(11.U64..=20.U64, [], |acc, i| List.append(acc, { t: i.to_i64_wrap(), v: 190.0 }))
    zs = Metrics.time_in_zones(List.concat(low, high), zb)
    zs.z1 == 9 and zs.z5 == 10 and zs.z2 == 0
}

# resample fills small gaps with previous value
expect {
    out = Metrics.resample_1s([{ t: 0, v: 100.0 }, { t: 3, v: 130.0 }])
    Metrics.lists_approx_eq(out, [100.0, 100.0, 100.0, 130.0])
}

# resample does not fill across long pauses
expect {
    out = Metrics.resample_1s([{ t: 0, v: 100.0 }, { t: 100, v: 130.0 }])
    Metrics.lists_approx_eq(out, [100.0, 130.0])
}

# best rolling mean of a constant series is that constant
expect
    match Metrics.best_rolling_mean(List.repeat(250.0, 100), 20) {
        Ok(best) => (best - 250.0).abs() < 0.001
        Err(_) => False
    }

# best rolling mean finds the hot stretch
expect {
    xs = List.concat(List.repeat(100.0, 50), List.concat(List.repeat(300.0, 20), List.repeat(100.0, 50)))
    match Metrics.best_rolling_mean(xs, 20) {
        Ok(best) => (best - 300.0).abs() < 0.001
        Err(_) => False
    }
}

# ── tss_ladder tests ────────────────────────────────────────────────

# stream NP wins even when weighted watts disagree
expect {
    r = Metrics.tss_ladder({ ..Metrics.ladder_base, np_stream: Ok(200.0), weighted_watts: Ok(300.0) })
    (r.tss - 100.0).abs() < 0.001
}

# weighted watts is the second rung
expect {
    r = Metrics.tss_ladder({ ..Metrics.ladder_base, weighted_watts: Ok(200.0) })
    (r.tss - 100.0).abs() < 0.001
}

# avg watts is the third rung
expect {
    r = Metrics.tss_ladder({ ..Metrics.ladder_base, avg_watts: Ok(200.0) })
    (r.tss - 100.0).abs() < 0.001
}

# power present but NO usable FTP (streamless import / pre-backfill sync): power must NOT
# win with TSS 0 — it falls through to HR (here avg_hr 150 -> 55 hrTSS, model hr_avg)
expect {
    r = Metrics.tss_ladder({ ..Metrics.ladder_base, weighted_watts: Ok(190.0), avg_hr: Ok(150.0), ftp: 0.0 })
    (r.tss - 55.0).abs() < 0.001 and r.model == "hr_avg"
}

# power present, no FTP, no HR: honest zero (not a fabricated power-0), model "none"
expect {
    r = Metrics.tss_ladder({ ..Metrics.ladder_base, weighted_watts: Ok(190.0), ftp: 0.0 })
    r.tss.abs() < 0.001 and r.model == "none"
}

# pace rung: an NGP speed + a threshold speed, no power -> rTSS (IF^exp * hours * 100)
expect {
    r = Metrics.tss_ladder({ ..Metrics.ladder_base, ngp: Ok(3.0), threshold_speed: 3.0 })
    (r.tss - 100.0).abs() < 0.001 and r.model == "rtss"
}

# power still beats pace (the ladder is power -> pace -> HR -> ...)
expect {
    r = Metrics.tss_ladder({ ..Metrics.ladder_base, weighted_watts: Ok(200.0), ngp: Ok(3.5), threshold_speed: 3.0 })
    r.model == "weighted_watts"
}

# pace beats HR when there is no usable power
expect {
    r = Metrics.tss_ladder({ ..Metrics.ladder_base, ngp: Ok(3.0), threshold_speed: 3.0, zones: { ..Metrics.test_zeroz, z2: 3600 } })
    r.model == "rtss"
}

# an NGP with no threshold speed does NOT fire pace — falls through to HR
expect {
    r = Metrics.tss_ladder({ ..Metrics.ladder_base, ngp: Ok(3.0), threshold_speed: 0.0, zones: { ..Metrics.test_zeroz, z2: 3600 } })
    (r.tss - 55.0).abs() < 0.001 and r.model == "hr_zones"
}

# no power: an hour of Z2 HR time -> 55 hrTSS, np reports NoPower
expect {
    r = Metrics.tss_ladder({ ..Metrics.ladder_base, zones: { ..Metrics.test_zeroz, z2: 3600 } })
    (r.tss - 55.0).abs() < 0.001 and r.np.is_err()
}

# no power, no zone seconds: avg HR classifies the whole session (150 -> Z2)
expect {
    r = Metrics.tss_ladder({ ..Metrics.ladder_base, avg_hr: Ok(150.0) })
    (r.tss - 55.0).abs() < 0.001
}

# last data rung: relative_effort passes through
expect {
    r = Metrics.tss_ladder({ ..Metrics.ladder_base, relative_effort: Ok(42.0) })
    (r.tss - 42.0).abs() < 0.001
}

# nothing at all -> honest zero, model "none"
expect {
    r = Metrics.tss_ladder(Metrics.ladder_base)
    r.tss.abs() < 0.001 and r.np.is_err() and r.model == "none"
}

# provenance: each rung reports which model scored it
expect {
    a = Metrics.tss_ladder({ ..Metrics.ladder_base, np_stream: Ok(200.0) })
    b = Metrics.tss_ladder({ ..Metrics.ladder_base, zones: { ..Metrics.test_zeroz, z2: 3600 } })
    c = Metrics.tss_ladder({ ..Metrics.ladder_base, relative_effort: Ok(42.0) })
    a.model == "power_stream" and b.model == "hr_zones" and c.model == "relative_effort"
}

# sRPE: 45min at RPE 7 -> 52.5 (hours x RPE x 10, TSS-commensurate)
expect (Metrics.srpe_load({ rpe: 7.0, moving_time: 2700 }) - 52.5).abs() < 0.001

# ENDURANCE ride with HR AND rpe: measured HR wins over reported RPE
expect {
    r = Metrics.tss_ladder({ ..Metrics.ladder_base, zones: { ..Metrics.test_zeroz, z2: 3600 }, rpe: Ok(9.0) })
    r.model == "hr_zones" and (r.tss - 55.0).abs() < 0.001
}

# STRENGTH session with junk-free HR AND rpe: the athlete's rating wins
expect {
    r = Metrics.tss_ladder({ ..Metrics.ladder_base, sport_type: "Workout", zones: { ..Metrics.test_zeroz, z2: 3600 }, rpe: Ok(7.0), moving_time: 2700 })
    r.model == "session_rpe" and (r.tss - 52.5).abs() < 0.001
}

# strength WITHOUT a rating still falls back to HR (never zero when data exists)
expect {
    r = Metrics.tss_ladder({ ..Metrics.ladder_base, sport_type: "Workout", zones: { ..Metrics.test_zeroz, z2: 3600 } })
    r.model == "hr_zones"
}

expect Metrics.sport_class("Ride") == Endurance and Metrics.sport_class("WeightTraining") == StrengthLike and Metrics.sport_class("Workout") == StrengthLike

# Sun Jul 26 and Mon Jul 27 2026 land in different Monday-aligned weeks
expect {
    sun = Metrics.days_from_civil(2026, 7, 26)
    mon = Metrics.days_from_civil(2026, 7, 27)
    weeks = Metrics.weekly_rollup([
        { days: sun, tss: 50.0, ctl: 20.0, atl: 25.0, tsb: -5.0 },
        { days: mon, tss: 70.0, ctl: 21.0, atl: 27.0, tsb: -6.0 },
    ])
    List.len(weeks) == 2 and (List.last(weeks).ok_or({ week_start: 0, tss: 0, sessions: 0, ctl_end: 0, tsb_end: 0 })).week_start == mon
}

# same-week days aggregate: tss sums, sessions count trained days, end values stick
expect {
    tue = Metrics.days_from_civil(2026, 7, 21)
    wed = Metrics.days_from_civil(2026, 7, 22)
    weeks = Metrics.weekly_rollup([
        { days: tue, tss: 73.0, ctl: 24.0, atl: 31.0, tsb: -2.0 },
        { days: wed, tss: 0.0, ctl: 23.0, atl: 27.0, tsb: -8.0 },
    ])
    w = List.first(weeks).ok_or({ week_start: 0, tss: 0, sessions: 9, ctl_end: 0, tsb_end: 0 })
    List.len(weeks) == 1 and w.sessions == 1 and (w.tss - 73.0).abs() < 0.001 and (w.tsb_end - (-8.0)).abs() < 0.001 and w.week_start == Metrics.days_from_civil(2026, 7, 20)
}

# load_step: same-day form (tsb = today's ctl - today's atl); a rest day (tss 0)
# decays both, fatigue (7d) faster than fitness (42d)
expect {
    s = Metrics.load_step({ ctl_prev: 50.0, atl_prev: 60.0, tss: 0.0 })
    (s.ctl - (50.0 - 50.0 / 42.0)).abs() < 0.001
    and (s.atl - (60.0 - 60.0 / 7.0)).abs() < 0.001
    and (s.tsb - (s.ctl - s.atl)).abs() < 0.001 # tsb reconciles same-day
    and (60.0 - s.atl) > (50.0 - s.ctl) # fatigue shed more than fitness on a rest day
}

# load_step: a hard day (tss above both) raises fitness and fatigue, and form
# drops negative same-day because fatigue jumps faster than fitness
expect {
    s = Metrics.load_step({ ctl_prev: 20.0, atl_prev: 20.0, tss: 90.0 })
    s.ctl > 20.0 and s.atl > 20.0 and s.atl > s.ctl
    and (s.tsb - (s.ctl - s.atl)).abs() < 0.001 and s.tsb < 0.0
}




expect Metrics.valid_hr(150.0) and !(Metrics.valid_hr(20.0)) and !(Metrics.valid_hr(230.0)) and Metrics.valid_hr(35.0) and Metrics.valid_hr(220.0)
expect Metrics.valid_watts(200.0) and Metrics.valid_watts(0.0) and Metrics.valid_watts(2500.0) and !(Metrics.valid_watts(-5.0)) and !(Metrics.valid_watts(9999.0))

# power intensity split (ftp 243): 100W=41% easy, 200W=82% moderate, 243W=100% hard
expect {
    r = Metrics.time_in_power_intensity([{ t: 0, v: 100.0 }, { t: 1, v: 100.0 }, { t: 2, v: 100.0 }], 243.0)
    r.easy_s == 2 and r.moderate_s == 0 and r.hard_s == 0
}
expect {
    r = Metrics.time_in_power_intensity([{ t: 0, v: 200.0 }, { t: 1, v: 200.0 }, { t: 2, v: 200.0 }], 243.0)
    r.moderate_s == 2 and r.easy_s == 0 and r.hard_s == 0
}
expect {
    r = Metrics.time_in_power_intensity([{ t: 0, v: 243.0 }, { t: 1, v: 243.0 }, { t: 2, v: 243.0 }], 243.0)
    r.hard_s == 2 and r.easy_s == 0 and r.moderate_s == 0
}
expect Metrics.time_in_power_intensity([{ t: 0, v: 243.0 }], 0.0) == { easy_s: 0, moderate_s: 0, hard_s: 0 }

# pace intensity split (threshold 4.0 m/s): each 1 Hz sample = 1 s; easy <3.04, moderate 3.04–3.64, hard ≥3.64
expect Metrics.time_in_pace_intensity([2.0, 2.0, 2.0], 4.0) == { easy_s: 3, moderate_s: 0, hard_s: 0 }
expect Metrics.time_in_pace_intensity([3.3, 3.3, 3.3], 4.0) == { easy_s: 0, moderate_s: 3, hard_s: 0 }
expect Metrics.time_in_pace_intensity([4.0, 4.0, 4.0], 4.0) == { easy_s: 0, moderate_s: 0, hard_s: 3 }
expect Metrics.time_in_pace_intensity([4.0, 4.0], 0.0) == { easy_s: 0, moderate_s: 0, hard_s: 0 }

# generic: every sport maps to its own config key, no hardcoded allowlist. A sport
# without that key set (or with no power meter) resolves to 0 in sport_ftp! and falls
# back to HR — so swimming, soccer, paddleboard all "just work" once configured.
expect (Metrics.ftp_from_best_20min(200.0) - 190.0).abs() < 0.001
expect (Metrics.ftp_from_best_20min(256.0) - 243.2).abs() < 0.001

# Critical Power: two points on P(t) = W'/t + CP (CP 250, W' 20000) recover CP and W'.
# P(300) = 20000/300 + 250 = 316.667; P(1200) = 20000/1200 + 250 = 266.667
expect {
    match Metrics.critical_power([{ dur_s: 300.0, watts: 316.6667 }, { dur_s: 1200.0, watts: 266.6667 }]) {
        Ok(r) => (r.cp - 250.0).abs() < 0.1 and (r.w_prime - 20000.0).abs() < 1.0
        Err(_) => 1 == 0
    }
}
# fewer than two usable points -> TooFew (can't fit a line)
expect {
    match Metrics.critical_power([{ dur_s: 300.0, watts: 300.0 }]) {
        Err(TooFew) => 1 == 1
        Ok(_) => 1 == 0
    }
}

# mean-max curve: best 1s = 300; best 3s window = (200+300+200)/3 = 233.3; 10s > 5 samples -> 0
expect {
    secs = |vals| List.map_with_index(vals, |v, i| { t: (i).to_i64_wrap(), v })
    match Metrics.mean_max_curve(secs([100.0, 200.0, 300.0, 200.0, 100.0]), [1, 3, 10]) {
        [a, b, c] => (a.watts - 300.0).abs() < 0.001 and (b.watts - 233.333).abs() < 0.01 and c.watts.abs() < 0.001
        _ => 1 == 0
    }
}

# A window must cover CONTIGUOUS seconds. Two 3-second efforts either side of a pause sit
# 6 samples apart but 100 seconds apart in reality, so there is no honest 6-second best —
# the old sample-counting version happily stitched them into one. This is the guard on the
# derived FTP: a stitched 20-min best would rescale every activity in the database.
expect {
    pairs = [
        { t: 0.I64, v: 300.0.F64 },
        { t: 1.I64, v: 300.0.F64 },
        { t: 2.I64, v: 300.0.F64 },
        { t: 100.I64, v: 300.0.F64 },
        { t: 101.I64, v: 300.0.F64 },
        { t: 102.I64, v: 300.0.F64 },
    ]
    three_ok = match Metrics.best_rolling_mean_1s(pairs, 3) { Ok(v) => (v - 300.0).abs() < 0.001, Err(_) => 1 == 0 }
    six_rejected = match Metrics.best_rolling_mean_1s(pairs, 6) { Ok(_) => 1 == 0, Err(TooShort) => 1 == 1 }
    three_ok and six_rejected
}

# a genuinely contiguous run is unaffected — 6 consecutive seconds averages normally
expect {
    pairs = List.map_with_index(List.repeat(250.0, 6), |v, i| { t: (i).to_i64_wrap(), v })
    match Metrics.best_rolling_mean_1s(pairs, 6) { Ok(v) => (v - 250.0).abs() < 0.001, Err(_) => 1 == 0 }
}

# per-sport HR zone keys mirror the FTP idiom; the global key is the fallback
expect Metrics.hr_zone_key(2, "Soccer") == "hr_z2_max_soccer"
expect Metrics.hr_zone_key(4, "Ride") == "hr_z4_max_ride"
expect Metrics.hr_zone_key(1, "StandUpPaddling") == "hr_z1_max_standuppaddling"
expect Metrics.hr_zone_key_global(3) == "hr_z3_max"

# per-sport pace-engine config keys (same data-driven shape as the FTP/zone keys)
expect Metrics.threshold_pace_key("Run") == "threshold_pace_run"
expect Metrics.threshold_pace_key("Swim") == "threshold_pace_swim"
expect Metrics.model_key("Run") == "model_run"
expect Metrics.model_key("TrailRun") == "model_trailrun"

expect Metrics.export_date_to_iso("Feb 17, 2022, 12:18:26 PM") == Ok("2022-02-17T12:18:26Z")
expect Metrics.export_date_to_iso("Jul 4, 2026, 6:05:09 AM") == Ok("2026-07-04T06:05:09Z")
expect Metrics.export_date_to_iso("Dec 31, 2025, 12:00:00 AM") == Ok("2025-12-31T00:00:00Z")
expect Metrics.export_date_to_iso("17 Feb 2022") == Err(BadExportDate)


expect Metrics.parse_utc_offset("-0500") == Ok(-300)
expect Metrics.parse_utc_offset("+0530") == Ok(330)
expect Metrics.parse_utc_offset("+0000") == Ok(0)
expect Metrics.parse_utc_offset("INVALID") == Err(BadOffset)
expect Metrics.parse_utc_offset("-05:0") == Err(BadOffset)

expect Metrics.is_auto_name("Morning Ride") and Metrics.is_auto_name("Lunch Gravel Ride") and !(Metrics.is_auto_name("45 min Power Zone Ride with Matt Wilpers"))

# group_progress: adjacent same-name rows fold into one group per workout
expect {
    pr = |name, date, dist| { name, date, sport: "Ride", distance_m: dist, moving_time: 3600, np_w: 100.0, avg_hr: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream" }
    gs = Metrics.group_progress([pr("A", "2025-01-01", 0.0), pr("A", "2025-02-01", 0.0), pr("B", "2025-03-01", 0.0)])
    List.len(gs) == 2 and List.first(gs).map_ok(|g| List.len(g.rows) == 2).ok_or(False)
}

# anchor_filter: exact names pass through; auto-names gate to ±10% of anchor distance;
# distance-less auto-name anchors show alone; off-date anchors drop the group
expect {
    pr = |name, date, dist| { name, date, sport: "Ride", distance_m: dist, moving_time: 3600, np_w: 100.0, avg_hr: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream" }
    exact = Metrics.anchor_filter({ name: "Class X", rows: [pr("Class X", "2025-01-01", 0.0)] }, "2025-01-01")
    gated = Metrics.anchor_filter({ name: "Morning Ride", rows: [pr("Morning Ride", "2025-01-01", 20000.0), pr("Morning Ride", "2025-02-01", 21000.0), pr("Morning Ride", "2025-03-01", 40000.0)] }, "2025-01-01")
    lone = Metrics.anchor_filter({ name: "Morning Ride", rows: [pr("Morning Ride", "2025-01-01", 0.0), pr("Morning Ride", "2025-02-01", 21000.0)] }, "2025-01-01")
    off = Metrics.anchor_filter({ name: "Class X", rows: [pr("Class X", "2025-01-01", 0.0)] }, "2025-09-09")
    ok_exact = match exact {
        Ok({ kind: Exact, rows, .. }) => List.len(rows) == 1
        _ => False
    }
    ok_gated = match gated {
        Ok({ kind: SimilarDistance(d), rows, .. }) => List.len(rows) == 2 and (d - 20000.0).abs() < 0.001
        _ => False
    }
    ok_lone = match lone {
        Ok({ kind: LoneNoDistance, rows, .. }) => List.len(rows) == 1
        _ => False
    }
    ok_off = match off {
        Err(NoAnchor) => True
        _ => False
    }
    ok_exact and ok_gated and ok_lone and ok_off
}

expect (Metrics.mean([1.0, 2.0, 3.0]) - 2.0).abs() < 0.001 and (Metrics.mean([])).abs() < 0.001

# pct_change: a real baseline measures; a zero baseline is NoBaseline, not 0% — those were
# the same answer before, so "first week ever" reported as "load steady (0%)"
expect {
    measured = match Metrics.pct_change(2.0, 3.0) {
        Ok(p) => (p - 50.0).abs() < 0.001
        Err(_) => 1 == 0
    }
    no_baseline = match Metrics.pct_change(0.0, 3.0) {
        Err(NoBaseline) => 1 == 1
        Ok(_) => 1 == 0
    }
    # a negative baseline is equally meaningless, not a huge negative percentage
    negative = match Metrics.pct_change(-5.0, 3.0) {
        Err(NoBaseline) => 1 == 1
        Ok(_) => 1 == 0
    }
    measured and no_baseline and negative
}

# bar scaling: lo -> 1 block, hi -> all blocks, degenerate range -> all blocks
expect Metrics.scale_to_blocks(1.2, 1.2, 1.8, 12) == 1 and Metrics.scale_to_blocks(1.8, 1.2, 1.8, 12) == 12 and Metrics.scale_to_blocks(1.5, 1.5, 1.5, 12) == 12

# trend_ends: first third avg vs last third avg (rising series -> late > early)
expect {
    e = Metrics.trend_ends([1.0, 1.0, 1.0, 2.0, 2.0, 2.0])
    (e.early - 1.0).abs() < 0.001 and (e.late - 2.0).abs() < 0.001
}

# single point: early == late == that point (no trend)
expect {
    e = Metrics.trend_ends([1.5])
    (e.early - 1.5).abs() < 0.001 and (e.late - 1.5).abs() < 0.001
}

# power zones: 7 zones; Z4 (threshold) is 91-105% FTP
expect {
    zs = Metrics.power_zones(200.0)
    z4 = List.get(zs, 3).ok_or({ z: "", name: "", lo_w: 0.0, hi_w: 0.0 })
    List.len(zs) == 7 and (z4.lo_w - 182.0).abs() < 0.001 and (z4.hi_w - 210.0).abs() < 0.001
}

# Z1 opens at 0, Z7 is open above (hi_w = 0 sentinel)
expect {
    zs = Metrics.power_zones(243.0)
    z1 = List.first(zs).ok_or({ z: "", name: "", lo_w: 9.0, hi_w: 0.0 })
    z7 = List.last(zs).ok_or({ z: "", name: "", lo_w: 0.0, hi_w: 9.0 })
    (z1.lo_w).abs() < 0.001 and (z7.hi_w).abs() < 0.001
}

expect Metrics.form_label(-20.0) == "high modeled fatigue — consider recovery"
expect Metrics.form_label(-9.0) == "modeled fatigue building — favor easy work"
expect Metrics.form_label(-1.0) == "balanced — good day for intensity if you feel it"
expect Metrics.form_label(8.0) == "fresh — good day for a big effort"
expect Metrics.form_label(20.0) == "very fresh — load has been light lately"

# epoch day 0 is 1970-01-01, and roundtrips
expect Metrics.days_from_civil(1970, 1, 1) == 0
expect Metrics.days_to_date_str(0) == "1970-01-01"
expect Metrics.date_str_to_days("2026-07-25T15:30:21Z") == Ok(Metrics.days_from_civil(2026, 7, 25))
expect {
    days = Metrics.date_str_to_days("2026-07-25").ok_or(0)
    Metrics.days_to_date_str(days) == "2026-07-25"
}

# leap-year boundary roundtrip
expect Metrics.days_to_date_str(Metrics.days_from_civil(2024, 2, 29)) == "2024-02-29"

# day-of-week: 2026-07-27 is a Monday (the anchor), through the week
expect Metrics.day_of_week(Metrics.days_from_civil(2026, 7, 27)) == "Mon"
expect Metrics.day_of_week(Metrics.days_from_civil(2026, 7, 28)) == "Tue"
expect Metrics.day_of_week(Metrics.days_from_civil(2026, 8, 2)) == "Sun"
expect Metrics.day_of_week(0) == "Thu" # epoch day 0 = 1970-01-01 = Thursday

# epoch -> ISO datetime (UTC)
expect Metrics.epoch_to_iso(0) == "1970-01-01T00:00:00Z"
expect Metrics.epoch_to_iso(1000000000) == "2001-09-09T01:46:40Z"

# grade-adjusted running (Minetti 2002): flat = 1.0x, +10% grade ~1.66x, -10% ~0.60x
expect (Metrics.minetti_ratio(0.0) - 1.0).abs() < 0.001
expect (Metrics.minetti_ratio(0.1) - 1.658).abs() < 0.01
expect (Metrics.minetti_ratio(-0.1) - 0.598).abs() < 0.01
# gradient clamps to +/-45% (a cliff-like reading can't run away)
expect (Metrics.minetti_ratio(2.0) - Metrics.minetti_ratio(0.45)).abs() < 0.001
# flat course: grade-adjusted distance equals raw distance
expect (Metrics.grade_adjusted_distance([0.0, 100.0, 200.0, 300.0], [10.0, 10.0, 10.0, 10.0]) - 300.0).abs() < 0.01
# steady 10% climb inflates distance by ~1.66 per segment (100m*1.658*2)
expect (Metrics.grade_adjusted_distance([0.0, 100.0, 200.0], [0.0, 10.0, 20.0]) - 331.6).abs() < 0.5
# descent discounts it (100m*0.598*2)
expect (Metrics.grade_adjusted_distance([0.0, 100.0, 200.0], [0.0, -10.0, -20.0]) - 119.5).abs() < 0.5
# a pause (no delta-distance) contributes nothing; too few samples -> 0
expect (Metrics.grade_adjusted_distance([0.0, 100.0, 100.0, 200.0], [0.0, 0.0, 0.0, 0.0]) - 200.0).abs() < 0.01
expect (Metrics.grade_adjusted_distance([42.0], [1.0]) - 0.0).abs() < 0.001
# a backwards GPS blip in cumulative distance doesn't inflate the total (jitter ignored)
expect (Metrics.grade_adjusted_distance([0.0, 100.0, 50.0, 200.0], [0.0, 0.0, 0.0, 0.0]) - 200.0).abs() < 0.01

# ── pace engine: rTSS/sTSS in speed units (reuses NP + tss_from_power) ──
# 5:00/km -> 3.333 m/s; non-positive pace -> 0
expect (Metrics.pace_to_speed(300.0) - 3.3333).abs() < 0.001
expect Metrics.pace_to_speed(0.0) == 0.0

# flat run at 3 m/s (1 Hz): grade-adjusted speed == raw speed (minetti(0)=1)
expect {
    s = Metrics.grade_adjusted_speeds([0.0, 1.0, 2.0], [0.0, 3.0, 6.0], [10.0, 10.0, 10.0])
    List.len(s) == 2 and (List.first(s).ok_or(0.0) - 3.0).abs() < 0.001
}

# +10% grade inflates the equivalent speed by minetti(0.1) ~= 1.658
expect {
    s = Metrics.grade_adjusted_speeds([0.0, 1.0], [0.0, 10.0], [0.0, 1.0])
    (List.first(s).ok_or(0.0) - (10.0 * 1.658)).abs() < 0.05
}

# stopped/jitter samples (no time or distance advance) are skipped
expect List.len(Metrics.grade_adjusted_speeds([0.0, 1.0, 1.0, 2.0], [0.0, 3.0, 3.0, 6.0], [0.0, 0.0, 0.0, 0.0])) == 2

# NGP of a constant-speed flat run equals that speed (>=30 steps fills the NP window)
expect
    match Metrics.normalized_graded_pace(
        List.fold(List.repeat(1.0, 40), [0.0], |acc, v| List.append(acc, List.last(acc).ok_or(0.0) + v)),
        List.fold(List.repeat(4.0, 40), [0.0], |acc, v| List.append(acc, List.last(acc).ok_or(0.0) + v)),
        List.repeat(0.0, 41),
    ) {
        Ok(ngp) => (ngp - 4.0).abs() < 0.001
        Err(_) => False
    }

# rTSS commensurability: NGP == threshold => IF 1 => 1 h => 100 TSS
expect (Metrics.pace_tss({ ngp_speed: 3.5, threshold_speed: 3.5, dur_s: 3600.0, exponent: 2.0 }) - 100.0).abs() < 0.001
# faster than threshold scores MORE, not less (the IF-direction bug the fleet caught)
expect Metrics.pace_tss({ ngp_speed: 4.0, threshold_speed: 3.5, dur_s: 3600.0, exponent: 2.0 }) > 100.0
# swim sTSS uses the same function (normalized swim speed vs CSS, no grade term)
expect Metrics.pace_tss({ ngp_speed: 1.4, threshold_speed: 1.25, dur_s: 3600.0, exponent: 3.0 }) > 100.0

# a STOP (distance flat while time advances) must NOT deflate the next speed:
# stationary for 0-2 s then 5 m in the 3rd second => one 5.0 m/s sample, not 1.67
expect {
    s = Metrics.grade_adjusted_speeds([0.0, 1.0, 2.0, 3.0], [0.0, 0.0, 0.0, 5.0], [0.0, 0.0, 0.0, 0.0])
    List.len(s) == 1 and (List.first(s).ok_or(0.0) - 5.0).abs() < 0.001
}

# normalization actually normalizes: a varying run (30 s @ 6 m/s + 30 s @ 2 m/s, mean 4)
# gives NGP ABOVE the mean, since the 4th-power weighting favors the fast segment
expect
    match Metrics.normalized_graded_pace(
        List.fold(List.repeat(1.0, 60), [0.0], |acc, v| List.append(acc, List.last(acc).ok_or(0.0) + v)),
        List.fold(List.concat(List.repeat(6.0, 30), List.repeat(2.0, 30)), [0.0], |acc, v| List.append(acc, List.last(acc).ok_or(0.0) + v)),
        List.repeat(0.0, 61),
    ) {
        Ok(ngp) => ngp > 4.0
        Err(_) => False
    }

# short / empty streams surface TooShort / [] cleanly, no crash
expect Metrics.normalized_graded_pace([0.0, 1.0], [0.0, 3.0], [0.0, 0.0]).is_err()
expect List.len(Metrics.grade_adjusted_speeds([], [], [])) == 0

# graded_speed_1s: a flat course at a constant 4 m/s -> NGP speed ~ 4 (no grade adjustment),
# and the best sustained 30 s speed is ~ 4. Exercises resample -> grade-adjust -> rolling.
expect {
    time = List.map_with_index(List.repeat(0.0, 121), |_, i| (i).to_f64())
    dist = List.map_with_index(List.repeat(0.0, 121), |_, i| (i).to_f64() * 4.0)
    alt = List.repeat(0.0, 121)
    gas = Metrics.graded_speed_1s(time, dist, alt)
    ngp_ok = match Metrics.normalized_power(List.map(gas, |p| p.v)) { Ok(v) => (v - 4.0).abs() < 0.5, Err(_) => 1 == 0 }
    best_ok = match Metrics.best_rolling_mean_1s(gas, 30) { Ok(v) => (v - 4.0).abs() < 0.5, Err(_) => 1 == 0 }
    ngp_ok and best_ok
}

# graded_speed_1s on a COARSE recording (5 s interval, still 4 m/s). Distance is
# cumulative, so forward-HOLDING it and then differencing gave four 0 m/s samples and one
# 20 m/s spike per interval — 5x the truth, raised to the 4th power by NGP. Linear
# interpolation keeps every sample at ~4. The old gapless-1Hz test could not see this.
expect {
    ramp = |n, step| List.map_with_index(List.repeat(0.0, n), |_, i| (i).to_f64() * step)
    gas = Metrics.graded_speed_1s(ramp(25, 5.0), ramp(25, 20.0), List.repeat(0.0, 25))
    all_sane = List.all(gas, |p| p.v > 3.5 and p.v < 4.5)
    ngp_ok = match Metrics.normalized_power(List.map(gas, |p| p.v)) { Ok(v) => (v - 4.0).abs() < 0.5, Err(_) => 1 == 0 }
    all_sane and ngp_ok
}

# graded_speed_1s across a dropout LONGER than max_fill_gap: 60 s at 4 m/s, a 61 s GPS
# dropout while still running, then more. The gap is deliberately not filled, but each
# pair keeps its REAL elapsed second, so dt is 61 and the speed stays ~4. Using the list
# INDEX as time (the old behaviour) divided 244 m by dt = 1 and emitted a 244 m/s sample.
expect {
    ramp = |n, step, base| List.map_with_index(List.repeat(0.0, n), |_, i| base + (i).to_f64() * step)
    time = List.concat(ramp(60, 1.0, 0.0), ramp(60, 1.0, 120.0))
    dist = List.concat(ramp(60, 4.0, 0.0), ramp(60, 4.0, 480.0))
    gas = Metrics.graded_speed_1s(time, dist, List.repeat(0.0, 120))
    # 59 intervals either side of the dropout, and NOTHING for the dropout itself: the
    # 61 s hole is unrecorded time, so the stream reports no data rather than inventing
    # an average that NP would then weight as a single second.
    List.all(gas, |p| p.v > 3.5 and p.v < 4.5) and List.len(gas) == 118
}

# resample_1s_linear interpolates a cumulative stream instead of holding it: two samples
# 5 s apart, 20 m covered, must produce 4 m per second — not four zeros and a 20 m jump.
expect {
    pts = Metrics.resample_1s_linear([{ t: 0.I64, v: 0.0.F64 }, { t: 5.I64, v: 20.0.F64 }])
    List.len(pts) == 6 and List.all(pts, |p| ((p.v) - (p.t).to_f64() * 4.0).abs() < 0.001)
}
