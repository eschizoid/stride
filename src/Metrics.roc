import Sports
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
        # The fold below assumes ascending timestamps: a single out-of-order sample used to
        # be dropped WITHOUT advancing the anchor, so one spuriously large timestamp
        # swallowed every sample after it until the stream caught up. Ordering is enforced
        # by sorted_by_t, which sorts only when a stream actually needs it.
        List.fold(
            sorted_by_t(samples),
            { out: [], prev_t: 0.I64, prev_v: 0.0.F64, started: False },
            |acc, s| resample_step(acc, s, mode),
        ).out

    # Ascending order is the ONLY thing the resample fold needs, and Strava streams already
    # arrive that way — so check before sorting. This is not a micro-optimization: on
    # already-ascending input List.sort_with hits its O(n^2) worst case, and that is the
    # only input shape real streams ever have. Measured on 2700 samples (one 45-min ride):
    # 40.7s to sort sorted input, 0.97s to sort the same data shuffled, 0.41s for this
    # linear check with the sort skipped. Three streams per activity (watts, distance,
    # altitude) made a full re-analyze of a few hundred activities take hours.
    # One pass, carrying the previous timestamp — deliberately NOT indexing back into the
    # list per element. Indexing would read the same as the append-in-a-fold that turned CSV
    # parsing quadratic (see Csv.roc), and a check that exists to avoid a quadratic sort must
    # not itself invite that doubt. Equal timestamps count as ascending: the resample fold
    # treats them as duplicates, and sorting would only shuffle equal keys.
    ascending_by_t : List({ t : I64, v : F64 }) -> Bool
    ascending_by_t = |samples|
        List.fold(samples, { ok: True, prev: 0.I64, started: False }, |acc, s|
            if !acc.ok {
                acc
            } else if !acc.started {
                { ok: True, prev: s.t, started: True }
            } else {
                { ok: s.t >= acc.prev, prev: s.t, started: True }
            }).ok

    # ascending already? hand the list back untouched. Otherwise sort — the protection
    # against a stray timestamp is preserved for the streams that genuinely need it.
    sorted_by_t : List({ t : I64, v : F64 }) -> List({ t : I64, v : F64 })
    sorted_by_t = |samples|
        if ascending_by_t(samples) samples else List.sort_with(samples, |a, b| I64.compare(a.t, b.t))

    # What to do with the next sample. Pure classification, kept flat and separate so the
    # step below reads as a four-case table instead of a staircase of nested else-ifs.
    resample_case : Bool, I64 -> [First, OutOfOrder, Fill, Pause]
    resample_case = |started, gap|
        if !started First else if gap <= 0 OutOfOrder else if gap <= max_fill_gap Fill else Pause

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

    # ── best rolling mean (e.g. the 20-min best power used to derive FTP) ──

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

    # The longest gap between two samples that still counts as elapsed training time.
    # Anything longer is a pause or a dropout: crediting it to whichever band or zone the
    # NEXT sample lands in would invent intensity that was never ridden. The cost is that a
    # stream genuinely sampled slower than this loses the excess — accepted deliberately,
    # because the alternative manufactures time. Shared by time_in_zones and time_in_bands
    # so the two can never drift apart.
    max_sample_gap_s : I64
    max_sample_gap_s = 30.I64

    # ── time in zones (HR-based, universal across sports) ───────────────
    # dt between consecutive samples, capped at max_sample_gap_s — a pause contributes AT
    # MOST that, never its full length (a 100 s stop credits 30 s, not 100). Attributed to
    # the zone of the current sample.

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
                    dt = (s.t - acc.prev_t).min(max_sample_gap_s)
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
    # Same max_sample_gap_s cap as the HR walk: a paused or dropped stream contributes at
    # most that per gap, so it cannot bank the whole stop.
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
        if watts <= 0.0 Coasting else if watts < mod_lo Easy else if watts < hard_lo Moderate else Hard

    # Sum REAL elapsed seconds into three intensity bands, given a per-sample classifier.
    #
    # ONE implementation for power and pace. They used to disagree about what a "second"
    # meant: the power path summed actual `dt` between samples, while the pace path counted
    # one second per surviving sample — and `grade_adjusted_speeds` drops every stopped or
    # gap interval, so its totals ran below moving time by an unknown amount. Weekly
    # polarization sums pi_* across sports, so a ride and a run were being added on
    # different units.
    #
    # dt is capped at max_sample_gap_s: a longer gap is a pause or a dropout, and crediting it to
    # whichever band the next sample happens to land in would invent intensity that was
    # never ridden. The cost is that a stream genuinely sampled slower than that loses the
    # excess — acceptable, because the alternative silently manufactures time.
    time_in_bands : List({ t : I64, v : F64 }), (F64 -> [Skip, Easy, Moderate, Hard]) -> PowerIntensity
    time_in_bands = |samples, classify| {
        state = List.fold(
            samples,
            { i: { easy_s: 0.I64, moderate_s: 0.I64, hard_s: 0.I64 }, prev_t: 0.I64, started: False },
            # the first sample only anchors prev_t — there is no interval before it, and
            # computing dt against the 0 sentinel would be arithmetic on a non-time
            |acc, s| if !(acc.started) { { ..acc, prev_t: s.t, started: True } } else band_step(acc, s, classify),
        )
        state.i
    }

    # one interval: credit its capped duration to whichever band the sample lands in
    band_step = |acc, s, classify| {
        dt = (s.t - acc.prev_t).min(max_sample_gap_s)
        i = acc.i
        updated =
            if dt <= 0 {
                i # duplicate or backwards timestamp — no interval to credit
            } else {
                match classify(s.v) {
                    Skip => i
                    Easy => { ..i, easy_s: i.easy_s + dt }
                    Moderate => { ..i, moderate_s: i.moderate_s + dt }
                    Hard => { ..i, hard_s: i.hard_s + dt }
                }
            }
        { ..acc, i: updated, prev_t: s.t }
    }

    time_in_power_intensity : List({ t : I64, v : F64 }), F64 -> PowerIntensity
    time_in_power_intensity = |samples, ftp|
        if ftp <= 0.0 {
            { easy_s: 0, moderate_s: 0, hard_s: 0 }
        } else {
            mod_lo = ftp * 0.76
            hard_lo = ftp * 0.91
            time_in_bands(samples, |w|
                match power_band(w, mod_lo, hard_lo) {
                    Coasting => Skip
                    Easy => Easy
                    Moderate => Moderate
                    Hard => Hard
                }
            )
        }

    # pace analog of time_in_power_intensity, on the grade-adjusted speed stream. Sums real
    # dt between timestamped samples via time_in_bands — the old "each sample is 1 s"
    # assumption is exactly the bug this PR removes. Bands mirror the power split, faster = harder:
    # easy < 0.76×threshold, moderate 0.76–0.91, hard ≥ 0.91×threshold. Feeds the SAME pi_*
    # columns for pace-scored sports (runs/swims), so weekly polarization and the "hard" column
    # read a real intensity split there too. Zeros when the sport has no threshold speed.
    # Pace twin of time_in_power_intensity, on the grade-adjusted speed stream. Takes the
    # (second, speed) PAIRS — not bare speeds — so it sums the same real elapsed time the
    # power path does. There is no Skip band here: grade_adjusted_speeds emits a sample only
    # for an interval where the athlete moved forward, so there is no coasting equivalent.
    # Gaps are still bounded rather than excluded — an interval spanning one contributes up
    # to max_sample_gap_s, exactly as on the power path.
    time_in_pace_intensity : List({ t : I64, v : F64 }), F64 -> PowerIntensity
    time_in_pace_intensity = |speed_pairs, threshold|
        if threshold <= 0.0 {
            { easy_s: 0, moderate_s: 0, hard_s: 0 }
        } else {
            mod_lo = threshold * 0.76
            hard_lo = threshold * 0.91
            time_in_bands(speed_pairs, |v|
                if v < mod_lo Easy else if v < hard_lo Moderate else Hard
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
    # `model_<sport>`. Orthogonal to Sports.class (which sets fallback priority) — this picks
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
    # ── ramp rate (#93): weekly CTL delta, as a number ───────────────────
    #
    # CTL on the most recent day at or before `target`. Missing is NOT zero: a series that
    # does not reach back that far has no answer, and treating absence as a CTL of 0 would
    # report the whole of today's fitness as this week's gain — a spectacular fake ramp on
    # exactly the short histories that can least afford one.
    ctl_as_of : List({ day : I64, ctl : F64 }), I64 -> [Found(F64), Missing]
    ctl_as_of = |series, target| {
        # ONE pass, carrying the best candidate rather than re-scanning the list to ask
        # whether a later qualifying day exists — that inner scan made this quadratic,
        # which is the fold trap this codebase has already been bitten by twice.
        # The caller may pass any order, so the walk cannot assume sortedness.
        # DISTINCT tags for the accumulator: it carries a whole {day, ctl} row while the
        # return carries a bare ctl, and reusing Found for both reads like a type error
        # even though the compiler accepts it.
        best = List.fold(series, NoCandidate, |acc, e|
            if e.day > target {
                acc
            } else {
                match acc {
                    NoCandidate => Candidate(e)
                    Candidate(b) => if e.day > b.day Candidate(e) else acc
                }
            })
        match best {
            NoCandidate => Missing
            Candidate(b) => Found(b.ctl)
        }
    }

    # ramp_7d is the standard weekly delta. ramp_28d_avg is the mean of the last four
    # weekly deltas, which telescopes to (now - 28d ago) / 4 — the intermediate weeks
    # cancel. The PAIR is what carries information: four steady weeks put the two numbers
    # together, while one spike week pushes ramp_7d far above the average. Neither number
    # alone distinguishes those shapes, and neither carries a verdict — bands are the
    # coach's business.
    ramp_rates : List({ day : I64, ctl : F64 }), I64 -> { ramp_7d : F64, ramp_28d_avg : F64 }
    ramp_rates = |series, today|
        match ctl_as_of(series, today) {
            Missing => { ramp_7d: 0.0, ramp_28d_avg: 0.0 }
            Found(now) => {
                r7 =
                    match ctl_as_of(series, today - 7) {
                        Found(then) => now - then
                        Missing => 0.0
                    }
                r28 =
                    match ctl_as_of(series, today - 28) {
                        Found(then) => (now - then) / 4.0
                        Missing => 0.0
                    }
                { ramp_7d: r7, ramp_28d_avg: r28 }
            }
        }

    # ── form trend (#111): the weekly TSB delta ──────────────────────────
    #
    # A band label has no memory. TSB spent a full month inside the -15..-5 band while
    # moving 9 points, so the verdict line read identically for weeks — and a conclusion
    # that never changes is indistinguishable from no conclusion. The band is right; it
    # just cannot say whether you are digging deeper or climbing out. This is that.
    #
    # Same lookback as ramp_rates, over tsb instead of ctl.
    tsb_as_of : List({ day : I64, tsb : F64 }), I64 -> [Found(F64), Missing]
    tsb_as_of = |series, target|
        # delegate rather than re-implement: ctl_as_of already carries the one-pass
        # "latest day at or before target" logic, including the quadratic trap it was
        # written to avoid. Two copies of that walk would drift.
        ctl_as_of(List.map(series, |e| { day: e.day, ctl: e.tsb }), target)

    # Known vs Unknown, NOT a bare 0.0. Both "form is exactly where it was" and "there is
    # no history to compare against" would collapse to zero, and the renderer must not
    # tell the reader form is level when it simply does not know. The JSON layer flattens
    # Unknown to 0.0, which is the house meaning of a numeric 0 (#111 acceptance).
    form_delta_7d : List({ day : I64, tsb : F64 }), I64 -> [Known(F64), Unknown]
    form_delta_7d = |series, today|
        match (tsb_as_of(series, today), tsb_as_of(series, today - 7)) {
            (Found(now), Found(before)) => Known(now - before)
            _ => Unknown
        }

    # How many of the most recent ENDURANCE sessions in a row recorded no usable HR.
    # `rows` must be newest-first; the walk stops at the first session that did record it.
    #
    # Strength-like sports are FILTERED OUT rather than treated as breaks in the streak.
    # They routinely run without a strap, so counting them would inflate the number and
    # letting them stop the walk would hide the thing worth seeing: two strapless rides in
    # a row went unnoticed for two days, and a lifting session in between must not reset
    # that. This reports a count and nothing else — what it means is the coach's call.
    hr_missing_streak : List({ sport : Str, has_hr : Bool }) -> U64
    hr_missing_streak = |rows|
        List.fold(
            List.keep_if(rows, |r| Sports.class(r.sport) == Endurance),
            { n: 0, stopped: False },
            |acc, r|
                if acc.stopped {
                    acc
                } else if r.has_hr {
                    { n: acc.n, stopped: True }
                } else {
                    { n: acc.n + 1, stopped: False }
                },
        ).n

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
            # False = Strava marked these watts ESTIMATED (no power meter). An estimate is
            # a guess dressed as a measurement — it must not outrank the honest fallback
            # rungs (pace/HR/RPE/RE), so all three power candidates are skipped (#73).
            device_watts : Bool,
        }
        -> { tss : F64, np : Try(F64, [NoPower]), model : Str }
    tss_ladder = |input| {
        np_like =
            if !input.device_watts
                Err(NoPower)
            else
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
            match Sports.class(input.sport_type) {
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
        # per-sport (running 2, swimming 3 — see Sports.pace_tss_exponent).
        pace_or_fallback =
            match input.ngp {
                Ok(ngp_speed) =>
                    if input.threshold_speed > 0.0
                        { t: pace_tss({ ngp_speed, threshold_speed: input.threshold_speed, dur_s: input.dur_s, exponent: Sports.pace_tss_exponent(input.sport_type) }), m: "rtss" }
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

    # Smoothing factors for the 42- and 7-day exponential moving averages.
    #
    # The discrete factor for a continuous time constant τ is α = 1 − e^(−1/τ), NOT 1/τ.
    # Using 1/τ — as this did — gives effective constants of 41.5 and 6.9 days, so the code
    # did not deliver the 42 and 7 it claimed, and transients ran 1–7% fast against
    # TrainingPeaks. Steady state is identical either way, which is why it went unnoticed.
    #
    # Written as literals because there is no `.exp()` on this compiler — the method does
    # not exist on F64 at all. (An earlier note here said it "returns NaN"; probing the
    # current pin showed the call is a MISSING METHOD error, so there was never a value
    # to be wrong.) They stay literals rather than becoming `exp_neg` calls because these
    # are compile-time constants and recomputing them per row buys nothing — but the
    # comment below is no longer the only thing tying them to the formula: an expect
    # checks each against `exp_neg`, so the two cannot drift apart silently.
    #   ctl_alpha = 1 − e^(−1/42) = 0.0235283133
    #   atl_alpha = 1 − e^(−1/7)  = 0.1331221000
    ctl_alpha : F64
    ctl_alpha = 0.0235283133
    atl_alpha : F64
    atl_alpha = 0.1331221

    load_step : { ctl_prev : F64, atl_prev : F64, tss : F64 } -> { ctl : F64, atl : F64, tsb : F64 }
    load_step = |{ ctl_prev, atl_prev, tss }| {
        ctl = ctl_prev + (tss - ctl_prev) * ctl_alpha
        atl = atl_prev + (tss - atl_prev) * atl_alpha
        # same-day form: today's fitness minus today's fatigue, so the number
        # reconciles (tsb = ctl - atl) and reflects state AFTER today's training
        { ctl, atl, tsb: ctl - atl }
    }

    # ── derived FTP ─────────────────────────────────────────────────────
    # Invariant: FTP is derived from power history, never configured. This section once held
    # `ftp_calibration`, which compared an estimate against a configured FTP and raised
    # stale/detraining flags; under the invariant those are the same number by construction,
    # so neither flag could ever fire and the function was deleted. Only the derivation
    # remains.

    # the derived FTP from a 20-min best: the standard 95% factor. One constant, one place —
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
    critical_power : List({ dur_s : F64, watts : F64 }) -> Try({ cp : F64, w_prime : F64, r2 : F64 }, [TooFew])
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
            syy = List.fold(pts, 0.0, |a, p| {
                dy = p.watts - my
                a + dy * dy
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
                # How well the line actually fits, so a caller has ONE number
                # that does not depend on what it is later asked to predict.
                # Without it the only quality signal is the point COUNT, which
                # is 3 for a good fit and 3 for a degenerate one. Note r2 is 1
                # by construction at two points -- there the count is the
                # signal and this carries no information.
                r2 = if syy < 0.0000001 0.0 else (sxy * sxy) / (sxx * syy)
                if cp <= 0.0 or w_prime <= 0.0 Err(TooFew) else Ok({ cp, w_prime, r2 })
            }
        }
    }

    # e^(-x) for x >= 0. There is no `.exp()` on this compiler — the method
    # does not exist on F64 at all, so the CTL/ATL constants above are literals
    # — but `.pow()` does exist and is correct to full double precision, which
    # is what W' balance needs (tau varies with how far below CP each sample
    # sits, so no lookup table covers the range). This replaced a hand-rolled
    # range-reduction-plus-Taylor series that was ~0.6% off by x = 700 and
    # returned +INFINITY past x ~ 11000, the exact inverse of its meaning.
    # Negative input would be e^(+x); callers pass magnitudes, and the guard
    # keeps a sign slip from silently returning a plausible number.
    exp_neg : F64 -> F64
    exp_neg = |x|
        if x < 0.0 1.0 else e_const.pow(0.0 - x)

    e_const : F64
    e_const = 2.718281828459045

    # ── spending the CP model (#186, #187) ──────────────────────────────
    #
    # Time to exhaustion at a power ABOVE CP: the model says the finite capacity
    # W' drains at (P - CP) watts, so it lasts W'/(P - CP) seconds. Two honest
    # refusals rather than a number:
    #   - at or below CP the model divides by zero or goes negative, which reads
    #     as "forever". The model believes that; bodies do not. BelowCp says so.
    #   - the 2-parameter model is only meaningful over roughly 2-20 minutes.
    #     Outside that it overshoots badly (anaerobic capacity dominates below,
    #     unmodelled fatigue above), so a result outside the window is returned
    #     as OutsideModel WITH the number, letting a caller show it labelled
    #     rather than silently trusting it.
    time_to_exhaustion : { cp : F64, w_prime : F64 }, F64 -> [Seconds(F64), OutsideModel(F64), BelowCp]
    time_to_exhaustion = |fit, watts| {
        over = watts - fit.cp
        if over <= 0.0 {
            BelowCp
        } else {
            t = fit.w_prime / over
            if t < 120.0 or t > 1200.0 OutsideModel(t) else Seconds(t)
        }
    }

    # W' balance through a ride: what is left of the anaerobic capacity at each
    # moment. Above CP it drains at (P - CP); below CP it reconstitutes toward
    # full, exponentially, with a time constant that depends on HOW far below CP
    # the athlete is — recovery at 100 W under CP is much faster than at 10 W
    # under it. This is the Skiba 2012 INTEGRAL form, evaluated as an
    # exponential recurrence. It is NOT the Froncioni/Skiba differential form,
    # which carries no tau and reconstitutes nothing at exactly CP — the two
    # land 41% of W' apart on a real session here, so the name is load-bearing.
    # Tau follows Skiba's fit, 546*e^(-0.01*DCP) + 316, computed from the
    # INSTANTANEOUS sub-CP deficit per sample rather than Skiba's ride-mean;
    # that is a deliberate variant worth ~3% of W' on real data.
    #
    # Returns the balance AFTER each sample, so the minimum over the list is the
    # deepest the athlete went. Pauses are bridged at max_sample_gap_s like
    # everywhere else — an unrecorded hour is not an hour of recovery.
    w_prime_balance : List({ t : I64, v : F64 }), { cp : F64, w_prime : F64 } -> List(F64)
    w_prime_balance = |pairs, fit|
        (List.fold(pairs, { bal: fit.w_prime, prev_t: Err({}), out: [] }, |acc, p| {
            dt =
                match acc.prev_t {
                    Ok(pt) => {
                        raw = p.t - pt
                        if raw > max_sample_gap_s max_sample_gap_s else if raw < 0 0 else raw
                    }
                    Err(_) => 0
                }
            dtf = (dt).to_f64()
            over = p.v - fit.cp
            next =
                if over > 0.0 {
                    # NOT floored at zero. A balance that goes negative is the
                    # model telling you it does not fit this rider — clamping
                    # converts "the CP fit is wrong" into the entirely plausible
                    # "you emptied the tank and got some back", and because
                    # clamping resets the deficit, everything AFTER the first
                    # clamp is wrong too, not just the minimum. Review measured
                    # -8074 J on a real ride (126% of the fitted tank) reported
                    # as 0. GoldenCheetah and the Skiba/Froncioni literature
                    # both let it go negative for exactly this reason.
                    acc.bal - over * dtf
                } else {
                    # DCP is how far below CP this sample sits; deeper recovery
                    # refills faster, which is what the exponent encodes
                    dcp = fit.cp - p.v
                    tau = 546.0 * exp_neg(0.01 * dcp) + 316.0
                    deficit = fit.w_prime - acc.bal
                    acc.bal + deficit * (1.0 - exp_neg(dtf / tau))
                }
            # The clock never runs backwards. A stamp EARLIER than the last
            # one charges dt = 0 above, but advancing prev_t to it would then
            # re-charge the span up to the next stamp — t = 0,10,5,20 billed
            # 25s of drain across a 20s window. Callers resample sorted, so
            # this is the function's own guard, not a live bug.
            latest = match acc.prev_t { Ok(pt) => if p.t > pt p.t else pt  Err(_) => p.t }
            { bal: next, prev_t: Ok(latest), out: List.append(acc.out, next) }
        })).out

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
    pct_change = |from, to| if from > 0.0 Ok((to - from) / from * 100.0) else Err(NoBaseline)

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
    ProgressRow : { name : Str, date : Str, sport : Str, distance_m : F64, moving_time : I64, np_w : F64, avg_hr : F64, rpe : F64, output_kj : F64, tss : F64, load_model : Str, decoupling_pct : F64, decoupling_known : Bool }

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

    # ── aerobic decoupling / Pw:HR drift (#94) ──────────────────────────
    #
    # Split the session in half BY TIME, compute efficiency (signal per heartbeat) in each
    # half, and report how much it fell. Positive = the second half cost more heartbeats
    # for the same output, the classic sign the effort exceeded what the aerobic system
    # could sustain.
    #
    # By time, not by sample COUNT: a stream with dropouts has uneven sample density, so
    # halving the list would put more elapsed time in one half than the other and compare
    # unlike windows.
    #
    # The two signals are averaged over the same window rather than joined sample-by-sample.
    # A join would drop every second where one sensor blinked, silently shrinking the window
    # and biasing whichever half dropped more.
    #
    # KNOWN ASYMMETRY for the pace signal (#134): grade_step emits nothing for stopped
    # time, but the HR samples from those same seconds stay in the half mean — so a half
    # with many stops mixes standing HR against moving-only speeds and biases the number.
    # Owned rather than hidden: the honest fix (excluding HR over non-emitting stretches)
    # needs the emitter to publish its gaps, tracked for a future pass. Power is immune —
    # coasting emits a real 0 W sample, which is exactly why the zeros-stay rule below
    # only fully holds for power.
    #
    # Known/Unknown, never a bare 0.0 — the same trap as form_delta_7d, and worse here:
    # 0.0 is a legitimate PERFECT result (no drift at all), so a 0-sentinel would render an
    # ideal ride and a session with no power meter identically.
    decoupling_pct : List({ t : I64, v : F64 }), List({ t : I64, v : F64 }), I64 -> [Known(F64), Unknown]
    decoupling_pct = |signal, hr, session_s| {
        clean_hr = List.keep_if(hr, |p| valid_hr(p.v))
        # a signal sample of 0 is a real reading (coasting, standing still) and must stay:
        # dropping it would flatter the half that contained more of it
        if List.is_empty(signal) or List.is_empty(clean_hr) {
            Unknown
        } else {
            t_lo = List.fold(signal, (List.first(signal)).map_ok(|p| p.t).ok_or(0), |m, p| if p.t < m p.t else m)
            t_hi = List.fold(signal, t_lo, |m, p| if p.t > m p.t else m)
            mid = t_lo + (t_hi - t_lo) // 2
            # halves are [lo, mid) and [mid, hi] — mid belongs to exactly one of them, so a
            # sample can never be counted twice or dropped
            eff1 = half_efficiency(signal, clean_hr, t_lo, mid, First)
            eff2 = half_efficiency(signal, clean_hr, mid, t_hi, Second)
            # Coverage gate, relative to the SESSION: the signal must span at least
            # ~10 minutes AND at least half the session's moving time, or the
            # "session drift" is computed from a fragment — a foot pod that died at
            # minute 10 of a 60-minute run must not have its fragment sold as the
            # session. (t_lo/t_hi come from the signal, so a dead sensor shrinks
            # the span; session_s is the activity's moving time.)
            span_ok = (t_hi - t_lo) >= 570 and (t_hi - t_lo) >= session_s // 2
            match (eff1, eff2) {
                (Known(e1), Known(e2)) if e1 > 0.0 and span_ok => {
                    pct = (e1 - e2) / e1 * 100.0
                    # Magnitude gate: physiological decoupling lives within tens of
                    # percent. Beyond ±50 the number is a measurement artifact —
                    # GPS creep while standing produces near-zero first-half
                    # efficiency and a four-digit "drift" — and an artifact stored
                    # as Known poisons every table it reaches. Unknown is honest.
                    if (pct).abs() <= 50.0 Known(pct) else Unknown
                }
                _ => Unknown
            }
        }
    }

    # mean signal / mean HR over one time window. Unknown when either side has no samples
    # in the window or the HR mean is not positive — dividing by it would be meaningless
    # rather than merely imprecise.
    half_efficiency : List({ t : I64, v : F64 }), List({ t : I64, v : F64 }), I64, I64, [First, Second] -> [Known(F64), Unknown]
    half_efficiency = |signal, hr, lo, hi, which| {
        in_window = |p|
            match which {
                First => p.t >= lo and p.t < hi
                Second => p.t >= lo and p.t <= hi
            }
        s = List.keep_if(signal, in_window)
        h = List.keep_if(hr, in_window)
        if List.is_empty(s) or List.is_empty(h) {
            Unknown
        } else {
            mean_s = List.fold(s, 0.0, |a, p| a + p.v) / (List.len(s)).to_f64()
            mean_h = List.fold(h, 0.0, |a, p| a + p.v) / (List.len(h)).to_f64()
            if mean_h > 0.0 Known(mean_s / mean_h) else Unknown
        }
    }

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

    # NAMES the modeled state. It does not prescribe (#123).
    #
    # These verdicts describe MODELED load only — the engine cannot see sleep, illness,
    # soreness or life stress. That was once the reason they were phrased as suggestions;
    # it is now the reason they say nothing about what to do at all.
    #
    # FOUR of the five used to end in advice ("favor easy work", "good day for a big
    # effort"); `very fresh` always carried an observation rather than an instruction,
    # which is why it alone keeps a trailing clause. Two problems with the advice, both
    # seen in real use:
    #
    #   - It repeated. One athlete read the identical line every day for over two weeks,
    #     because TSB drifted inside the -15..-5 band without ever leaving it.
    #   - It was WRONG. That same stretch was overwhelmingly easy with no hard session in
    #     over a week, so the honest reading was "go hard" — and a model that sees only
    #     TSB, with no view of intensity distribution, advised the opposite.
    #
    # Prescribing training from a single scalar is more than one number can support.
    # State here; prescriptions come from the coach, who can see distribution, travel,
    # equipment and intent — the engine/LLM split ADR 0000 settles ("the engine does the
    # math, the LLM does the judgment").
    # The band as an IDENTITY, separate from how it is worded. `days_in_band` asks "is this
    # the same band as that one", which is a question about the band, not about the prose —
    # comparing rendered strings meant a future wording change that made two labels read the
    # same would silently merge them into one streak, with no error and a count that just
    # grows. #123 is a PR that rewrote four of these strings, so that coupling was being
    # exercised while unnamed.
    #
    # Still an if/else chain rather than a match: these are FLOAT RANGE tests, and no
    # pattern-matching form expresses `-15.0 < tsb <= -5.0` more directly than the
    # comparison itself. The tag is what buys safety here, not the branching syntax.
    FormBand : [HighFatigue, FatigueBuilding, Balanced, Fresh, VeryFresh]

    form_band : F64 -> FormBand
    form_band = |tsb|
        if tsb <= -15.0 {
            HighFatigue
        } else if tsb <= -5.0 {
            FatigueBuilding
        } else if tsb < 5.0 {
            Balanced
        } else if tsb < 15.0 {
            Fresh
        } else {
            VeryFresh
        }

    # Rendering, and ONLY rendering. Two labels reading alike would now be a cosmetic bug
    # rather than a correctness one.
    # Stable machine identifier for the form band — the JSON face of form_label.
    # snake_case, enum-stable: clients switch on these, so renaming one is a
    # contract change. The human label may evolve; these must not drift casually.
    # ONE vocabulary, shared by every boundary guard (Metrics + Render expects) —
    # a tripwire for coaching language reappearing in any label producer. The
    # closed-set equality expects on form_label/form_state are the hard invariant
    # for those two; this predicate is what lets every OTHER verdict producer be
    # guarded without triplicating the list.
    has_coaching_language : Str -> Bool
    has_coaching_language = |s| {
        low = Str.with_ascii_lowercased(s)
        # a denylist can only be defense-in-depth (round-3 mutations proved
        # "take it easier"/"push harder" slipped the round-2 list) — the HARD
        # guard for every finite producer is closed-set equality on its full
        # output; this predicate backstops the branches equality can't reach
        words = ["should", "consider", "favor", "avoid", "good day", "good time", "ready for", "take it eas", "recommend", "go hard", "back off", "rest day", "easy day", "ease off", "dial back", "hold back", "need to", "must ", "prioritize", "taper", "take a rest", "train hard", "train easy", "easier", "harder", "push", "time to", "focus on", "aim for", "try to"]
        List.any(words, |w| Str.contains(low, w))
    }

    # median gap in days between consecutive stimulus dates (#159) — Unknown
    # below two dates, because one session has no spacing to measure. Input is
    # day numbers in ANY order; dedup + sort happen here so callers stay dumb.
    median_gap_days : List(I64) -> [Known(I64), Unknown]
    median_gap_days = |days| {
        distinct = List.fold(days, [], |acc, d| if List.contains(acc, d) acc else List.append(acc, d))
        sorted = List.sort_with(distinct, |a, b| if a < b LT else if a > b GT else EQ)
        if List.len(sorted) < 2 {
            Unknown
        } else {
            gaps = (List.fold(sorted, { prev: Err({}), out: [] }, |acc, d| {
                out = match acc.prev {
                    Ok(p) => List.append(acc.out, d - p)
                    Err(_) => acc.out
                }
                { prev: Ok(d), out }
            })).out
            gs = List.sort_with(gaps, |a, b| if a < b LT else if a > b GT else EQ)
            Known(List.get(gs, List.len(gs) // 2) ?? 0)
        }
    }

    # three-way percentage split that ALWAYS sums to exactly 100 (largest-
    # remainder rounding) — the #157 coverage invariant. All-zero inputs return
    # zeros; callers carry a _known flag for that case per ADR 0009.
    coverage_pcts : F64, F64, F64 -> { high_pct : I64, medium_pct : I64, low_pct : I64 }
    coverage_pcts = |hi, med, lo| {
        total = hi + med + lo
        if total <= 0.0 {
            { high_pct: 0, medium_pct: 0, low_pct: 0 }
        } else {
            exact = [hi / total * 100.0, med / total * 100.0, lo / total * 100.0]
            # F64 has no floor method on this nightly, and round(x - 0.5) mis-floors
            # exact integers under half-to-even — correct the rounded value instead,
            # which is exact floor under ANY rounding mode
            floors = List.map(exact, |x| {
                r = (x).round_to_i64_try().ok_or(0)
                if (r).to_f64() > x r - 1 else r
            })
            floor_sum = List.fold(floors, 0.I64, |acc, f| acc + f)
            remainder = 100 - floor_sum
            rema = List.map2(exact, floors, |x, f| x - (f).to_f64())
            # hand the leftover points to the largest fractional parts, ties by
            # position (high before medium before low) — deterministic
            order = List.sort_with([0.U64, 1, 2], |a, b| {
                ra = List.get(rema, a) ?? 0.0
                rb = List.get(rema, b) ?? 0.0
                if ra > rb LT else if ra < rb GT else if a < b LT else GT
            })
            bump = List.take_first(order, (remainder).to_u64_wrap())
            out = List.map_with_index(floors, |f, i| f + (if List.contains(bump, i) 1 else 0))
            {
                high_pct: List.get(out, 0) ?? 0,
                medium_pct: List.get(out, 1) ?? 0,
                low_pct: List.get(out, 2) ?? 0,
            }
        }
    }

    # ── personal-baseline primitives (#160) ─────────────────────────────
    # THE comparability rule, in one place: two activities compare iff same
    # sport family AND same duration band AND the metric exists on both sides.
    # Bands are FIXED edges, not ±% of the current ride — fixed edges make
    # comparability symmetric and deterministic (a is comparable to b exactly
    # when b is comparable to a), which ±% is not. #149's rep-level progression
    # must consume THIS function rather than grow a second definition.
    duration_band : I64 -> { lo : I64, hi : I64 }
    duration_band = |moving_time|
        if moving_time < 1200 { lo: 0, hi: 1200 }
        else if moving_time < 2700 { lo: 1200, hi: 2700 }
        else if moving_time < 4500 { lo: 2700, hi: 4500 }
        else if moving_time < 7200 { lo: 4500, hi: 7200 }
        # the catch-all is OPEN ABOVE (the SQL band filter is `< hi`, so a finite
        # ceiling would orphan ultra-length activities from ever being comparable)
        else { lo: 7200, hi: 8640000 }

    # The rep-scale twin of duration_band (#149). Session band EDGES sit at
    # 20/45/75/120 minutes, which at rep scale is useless: a 3x2min VO2 set and a 3x17min
    # tempo block both land in "under 20 minutes" and would be compared as the
    # same workout. These edges follow how intervals are actually prescribed —
    # sprints, short VO2, classic 3-6min VO2, 6-10min, threshold 10-15, sweet
    # spot 15-30, and long. Fixed edges for the same reason duration_band uses
    # them: comparability must be symmetric, which a +/-% window is not.
    # The one judgment in the reps comparison: how far rep durations may spread
    # and still be "the same repeated shape". It lives here because THREE things
    # depend on them agreeing — the anchor gate, the census count on the screen,
    # and the refusal message — and they sat in two files in two forms (a float
    # and an integer ratio) with nothing tying them together. This gate already
    # moved once (1.4 -> 1.6); the next move must move all three at once.
    anchor_uniformity_max : F64
    anchor_uniformity_max = 1.6

    # the same bound as an exact integer ratio, for I64 durations and SQL
    anchor_uniformity_num : I64
    anchor_uniformity_num = 16

    anchor_uniformity_den : I64
    anchor_uniformity_den = 10

    # a session is the repeated shape when its longest rep is within the gate
    # of its shortest. A zero shortest is not uniform, it is unmeasured.
    is_uniform_reps : I64, I64 -> Bool
    is_uniform_reps = |min_dur, max_dur|
        min_dur > 0 and max_dur * anchor_uniformity_den <= min_dur * anchor_uniformity_num

    rep_duration_band : I64 -> { lo : I64, hi : I64 }
    rep_duration_band = |dur_s|
        if dur_s < 60 { lo: 0, hi: 60 }
        else if dur_s < 180 { lo: 60, hi: 180 }
        else if dur_s < 360 { lo: 180, hi: 360 }
        else if dur_s < 600 { lo: 360, hi: 600 }
        else if dur_s < 900 { lo: 600, hi: 900 }
        else if dur_s < 1800 { lo: 900, hi: 1800 }
        else { lo: 1800, hi: 86400 }

    # percentile of `current` within `samples`: the share of samples <= current,
    # 0-100. DIRECTION-FREE — for EF/NP higher is better, for decoupling lower
    # is better; stride reports the rank, the coach applies the direction.
    # Requires a non-empty sample list (callers gate on sample_count).
    percentile_of : List(F64), F64 -> I64
    percentile_of = |samples, current| {
        n = List.len(samples)
        if n == 0 {
            0
        } else {
            at_or_below = List.len(List.keep_if(samples, |s| s <= current))
            (((at_or_below).to_f64() / (n).to_f64()) * 100.0).round_to_i64_try().ok_or(0)
        }
    }

    form_state : F64 -> Str
    form_state = |tsb|
        match form_band(tsb) {
            HighFatigue => "high_modeled_fatigue"
            FatigueBuilding => "modeled_fatigue_building"
            Balanced => "balanced"
            Fresh => "fresh"
            VeryFresh => "very_fresh"
        }

    form_label : F64 -> Str
    form_label = |tsb|
        match form_band(tsb) {
            HighFatigue => "high modeled fatigue"
            FatigueBuilding => "modeled fatigue building"
            Balanced => "balanced"
            Fresh => "fresh"
            VeryFresh => "very fresh — load has been light lately"
        }

    # How many consecutive days, counting back from `today`, the series has stayed in the
    # same form band. THE thing a band label structurally cannot express: 16 days at -11 and
    # one day at -11 render identically, yet mean different things.
    #
    # Known/Unknown, same shape as form_delta_7d but a NARROWER meaning of Unknown: it
    # says only that the series has no value at or before `today`, so there is no band to
    # be in. Once today is known the answer is always Known(n >= 1) — including Known(1)
    # when the day before is missing or in a different band. 1 is a truthful "today, and
    # nothing established before it"; the renderer suppresses it because a one-day streak
    # carries no information, not because it is wrong.
    # THREE outcomes, not two. `AtLeast` exists because the walk can stop for a reason that
    # is not an answer: running out of series. Callers hand this a WINDOW (summary passes 31
    # days sized for the #93 ramp, `load` passes whatever window it was asked for), so a
    # streak longer than the window is truncated — and a truncated 31 is indistinguishable
    # from a real 31 unless the type says so. Reporting the cap as an exact count is the
    # same class of lie as a 0 that means "no data": the number looks like a measurement.
    days_in_band : List({ day : I64, tsb : F64 }), I64 -> [Known(I64), AtLeast(I64), Unknown]
    days_in_band = |series, today|
        # EXACT lookup for the anchor, not at-or-before. With at-or-before, a `today` the
        # series has no row for would borrow an older day's value and then count today as
        # day 1 of a streak the series cannot vouch for — precisely what tsb_as_of_exact
        # exists to prevent one function below. Unknown now means exactly what the contract
        # says: nothing is known about the anchor day itself.
        match tsb_as_of_exact(series, today) {
            Missing => Unknown
            Found(now) => {
                band_now = form_band(now)
                # walk back a day at a time while the band holds. A gap ends the streak
                # rather than being silently skipped — an unknown day is not evidence the
                # band held. Re-tagged rather than returned directly so streak_back keeps
                # its precise two-outcome type — it can never produce Unknown.
                match streak_back(series, today, band_now, 1) {
                    Known(n) => Known(n)
                    AtLeast(n) => AtLeast(n)
                }
            }
        }

    streak_back : List({ day : I64, tsb : F64 }), I64, FormBand, I64 -> [Known(I64), AtLeast(I64)]
    streak_back = |series, today, band_now, acc|
        # Hitting the series length is NOT a terminating answer — it means the window ran
        # out while the band was still holding, so the true streak is at least this long.
        # (It is a genuine bound, not a hang guard: `today - acc` decreases every step over
        # a finite series, so the walk terminates regardless.)
        if acc >= (List.len(series)).to_i64_wrap() {
            AtLeast(acc)
        } else {
            match tsb_as_of_exact(series, today - acc) {
                Missing => Known(acc)
                Found(v) => if form_band(v) == band_now streak_back(series, today, band_now, acc + 1) else Known(acc)
            }
        }

    # tsb on EXACTLY this day, not the latest at-or-before it. The streak walk must not
    # reuse an older day's value to fill a gap — that would report a run of days the series
    # has no rows for.
    tsb_as_of_exact : List({ day : I64, tsb : F64 }), I64 -> [Found(F64), Missing]
    tsb_as_of_exact = |series, target|
        match List.keep_if(series, |e| e.day == target) {
            [e, ..] => Found(e.tsb)
            [] => Missing
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

    # "does it parse" is NOT enough for a date the engine stores: target_date is TEXT
    # and every week filter compares it as a STRING (a lexicographic BETWEEN), so the
    # spelling has to be canonical YYYY-MM-DD, not merely numeric. Round-tripping
    # through the day number tests both facts at once — days_from_civil silently
    # NORMALIZES an out-of-range field (2026-02-30 becomes March 2, and the caller
    # never learns their date moved), while an unpadded 2026-8-5 sorts after every
    # 2026-1x-xx date and lands in the wrong week. The year bound holds the string at
    # ten characters, since a 3-digit year would sort after every 2xxx one.
    is_canonical_date : Str -> Bool
    is_canonical_date = |s|
        match date_str_to_days(s) {
            Ok(d) => {
                c = civil_from_days(d)
                days_to_date_str(d) == s and c.y >= 1000 and c.y <= 9999
            }

            Err(_) => False
        }

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
        device_watts: True,
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
        if pace_s_per_km > 0.0 1000.0 / pace_s_per_km else 0.0

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
        if dt <= 0.0 NoTime else if dt > (max_fill_gap).to_f64() Gap else if dd > 0.0 Moving else Stopped

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
    # any exponent. The exponent is per-sport (see Sports.pace_tss_exponent):
    # running is near enough linear in speed so it keeps 2, matching TrainingPeaks rTSS;
    # swimming fights drag, which rises with v³, so it uses 3 like TrainingPeaks sSS. The
    # earlier version squared BOTH and under-scored hard swim sets by ~20%.
    # How metabolic cost scales with the speed ratio, per sport.
    #
    # Running resistance is near enough linear in speed, so rTSS keeps the familiar IF^2
    # (identical to tss_from_power). Swimming fights hydrodynamic DRAG, which rises with the
    # CUBE of speed — TrainingPeaks' sSS cubes the speed ratio for exactly this reason.
    # Squaring it under-scores hard swim sets badly: at IF 1.2, 144 vs 173 per hour.
    pace_tss : { ngp_speed : F64, threshold_speed : F64, dur_s : F64, exponent : F64 } -> F64
    pace_tss = |{ ngp_speed, threshold_speed, dur_s, exponent }|
        if threshold_speed <= 0.0 {
            0.0
        } else {
            intensity = ngp_speed / threshold_speed
            (dur_s / 3600.0) * intensity.pow(exponent) * 100.0
        }

    # ── interval detection (ADR 0008) — reporting only, power/pace edges ──
    #
    # One signal-agnostic pipeline: smooth (trailing mean) → two-window level-shift
    # edges (a shift counts when the H-second forward mean moves ≥ shift_frac of the
    # session IQR away from the H-second backward mean) → segments between edges →
    # merge neighbors closer than the shift threshold → label work/recovery by the
    # Otsu split of the segment LEVEL MEANS (#170 — never the session's global
    # distribution), merge adjacent work, then gate on contrast and work fraction.
    # HR never places edges (it lags effort by 30+ s);
    # it only enriches segments already found (enrich_hr below).
    #
    # These constants are the ADR 0008 starting point, validated against the
    # maintainer's own VO2/threshold sessions — every change bumps metrics_rev
    # (Analyze), because a tuning change recomputes history.
    #
    # min_shift is the no-invented-intervals FLOOR on the edge threshold: an edge
    # requires at least this much level change, so steady rides and GPS wobble
    # produce no edges at all. It replaced the v1 min_spread IQR *gate* (#170),
    # which judged the GLOBAL value distribution and failed both ways on real
    # rides: a genuine 3x12 with short recoveries is ~80% work samples, so its
    # IQR sat inside the work band and the gate declared "no structure" (false
    # negative on the maintainer's cleanest session), while a progressive ride's
    # ramp inflated IQR past the gate and got sliced into pseudo-reps (false
    # positive). Structure is now judged AFTER segmentation — see the level-gap
    # threshold, adjacent-work merge, and contrast gate in detect_segments.
    DetectParams : { smooth_w : U64, hold : U64, shift_frac : F64, min_shift : F64 }

    detect_power_params : DetectParams
    detect_power_params = { smooth_w: 15, hold: 60, shift_frac: 0.20, min_shift: 30.0 }

    detect_pace_params : DetectParams
    detect_pace_params = { smooth_w: 30, hold: 90, shift_frac: 0.20, min_shift: 0.3 }

    SegmentKind : [Work, Recovery, Warmup, Cooldown]

    # start_s/end_s are REAL stream timestamps (first/last recorded sample of the
    # segment); dur_s is pause-capped elapsed time — per-sample dt clipped at
    # max_sample_gap_s, the same rule time_in_zones lives by — so a traffic stop
    # inside a rep is bridged but never SOLD as sustained effort.
    Segment : { kind : SegmentKind, start_s : I64, end_s : I64, dur_s : I64, avg_signal : F64 }

    # inclusive-prefix sums with a leading 0, so mean over [i, j) is O(1)
    prefix_sums : List(F64) -> List(F64)
    prefix_sums = |xs|
        List.fold(xs, [0.0.F64], |acc, x| List.append(acc, last_or_zero(acc) + x))

    range_mean : List(F64), U64, U64 -> F64
    range_mean = |prefix, i, j|
        if j <= i {
            0.0
        } else {
            hi = List.get(prefix, j) ?? 0.0
            lo = List.get(prefix, i) ?? 0.0
            (hi - lo) / ((j - i)).to_f64()
        }

    # trailing rolling mean: out[i] = mean(xs[max(0, i+1-w) .. i])
    smooth_trailing : List(F64), U64 -> List(F64)
    smooth_trailing = |xs, w| {
        prefix = prefix_sums(xs)
        List.map_with_index(xs, |_, i| {
            lo = if i + 1 >= w i + 1 - w else 0
            range_mean(prefix, lo, i + 1)
        })
    }

    # List.sort_with degrades to O(n^2) on already-sorted input (see the AGENTS
    # performance note) and a smoothed ramp test is EXACTLY that — check first
    ascending_f64 : List(F64) -> Bool
    ascending_f64 = |xs|
        (List.fold(xs, { ok: True, prev: 0.0.F64, started: False }, |acc, x|
            if !acc.ok {
                acc
            } else if !acc.started {
                { ok: True, prev: x, started: True }
            } else {
                { ok: x >= acc.prev, prev: x, started: True }
            })).ok

    # upper median of an unsorted list (0.0 when empty) — used only for the
    # contrast gate, where nearest-rank precision is plenty
    median_f64 : List(F64) -> F64
    median_f64 = |xs| {
        sorted = List.sort_with(xs, |a, b| if a < b LT else if a > b GT else EQ)
        List.get(sorted, List.len(sorted) // 2) ?? 0.0
    }

    # value at the given fraction of a SORTED list (nearest-rank)
    sorted_quantile : List(F64), F64 -> F64
    sorted_quantile = |sorted, frac| {
        n = List.len(sorted)
        if n == 0 {
            0.0
        } else {
            idx_f = frac * ((n - 1)).to_f64()
            List.get(sorted, (idx_f + 0.5).to_u64_wrap()) ?? 0.0
        }
    }

    # edge indices: positions where the forward H-mean sits ≥ delta from the backward
    # H-mean. Contiguous qualifying runs collapse to the single strongest position, so
    # one physical transition yields one edge.
    shift_edges : List(F64), U64, F64 -> List(U64)
    shift_edges = |sm, h, delta| {
        n = List.len(sm)
        if n <= 2 * h {
            []
        } else {
            prefix = prefix_sums(sm)
            walk = Iter.fold(
                h..<(n - h),
                { edges: [], run_best: 0.0.F64, run_at: 0, in_run: False },
                |acc, i| {
                    d = (range_mean(prefix, i, i + h) - range_mean(prefix, i - h, i)).abs()
                    if d >= delta {
                        if !(acc.in_run) or d > acc.run_best {
                            { ..acc, run_best: d, run_at: i, in_run: True }
                        } else {
                            acc
                        }
                    } else if acc.in_run {
                        { edges: List.append(acc.edges, acc.run_at), run_best: 0.0, run_at: 0, in_run: False }
                    } else {
                        acc
                    }
                },
            )
            if walk.in_run List.append(walk.edges, walk.run_at) else walk.edges
        }
    }

    # merge boundary list into segments, folding neighbors whose raw means are
    # within delta of each other back together (one physical rep, one segment)
    segments_between : List(F64), List(U64), F64 -> List({ lo : U64, hi : U64, mean : F64 })
    segments_between = |xs, edges, delta| {
        prefix = prefix_sums(xs)
        n = List.len(xs)
        bounds = List.concat(List.concat([0], edges), [n])
        raw = List.map_with_index(edges, |_, k| {
            lo = List.get(bounds, k) ?? 0
            hi = List.get(bounds, k + 1) ?? n
            { lo, hi, mean: range_mean(prefix, lo, hi) }
        })
        last_piece = {
            lo = List.get(bounds, List.len(edges)) ?? 0
            { lo, hi: n, mean: range_mean(prefix, lo, n) }
        }
        List.fold(List.append(raw, last_piece), [], |acc, seg|
            match List.last(acc) {
                Ok(prev) =>
                    if (prev.mean - seg.mean).abs() < delta {
                        merged = { lo: prev.lo, hi: seg.hi, mean: range_mean(prefix, prev.lo, seg.hi) }
                        List.append(drop_last(acc), merged)
                    } else {
                        List.append(acc, seg)
                    }
                Err(_) => List.append(acc, seg)
            })
    }

    drop_last : List(a) -> List(a)
    drop_last = |xs| List.take_first(xs, if List.is_empty(xs) 0 else List.len(xs) - 1)

    # the detector. `pairs` is a 1 Hz series with REAL trailing timestamps (the
    # resampler's output) — pauses appear as t-jumps and are bridged: a traffic
    # stop inside a rep does not split it, and unrecorded time is never averaged in.
    detect_segments : List({ t : I64, v : F64 }), DetectParams -> List(Segment)
    detect_segments = |pairs, p| {
        n = List.len(pairs)
        if n < 4 * p.hold {
            []
        } else {
            xs = List.map(pairs, |x| x.v)
            sm = smooth_trailing(xs, p.smooth_w)
            sorted = if ascending_f64(sm) sm else List.sort_with(sm, |a, b| if a < b LT else if a > b GT else EQ)
            q25 = sorted_quantile(sorted, 0.25)
            q75 = sorted_quantile(sorted, 0.75)
            iqr = q75 - q25
            {
                # floored, not gated: shift_frac*iqr adapts to noisy signals, and the
                # min_shift floor is what keeps steady rides edge-free — detection no
                # longer depends on how much of the ride the work occupies (#170)
                adaptive = p.shift_frac * iqr
                delta = if adaptive > p.min_shift adaptive else p.min_shift
                # the trailing smoother lags the signal by (w-1)/2 samples, so raw edge
                # positions land that late — shift them back or every work rep starts
                # late and averages in recovery samples (measured: 250 W reps read ~242)
                lag = (p.smooth_w - 1) // 2
                raw_edges = shift_edges(sm, p.hold, delta)
                edges = List.fold(raw_edges, [], |acc, e| {
                    shifted = if e > lag e - lag else 1
                    keep = match List.last(acc) {
                        Ok(prev) => shifted > prev
                        Err(_) => True
                    }
                    if keep List.append(acc, shifted) else acc
                })
                segs = segments_between(xs, edges, delta)
                # a piece shorter than the hold window is not a segment of its own —
                # fold it into its predecessor (or successor when it leads) so the
                # timeline stays gapless instead of leaving unclassified holes
                prefix = prefix_sums(xs)
                absorbed = List.fold(segs, [], |acc, seg|
                    match List.last(acc) {
                        Ok(prev) =>
                            if seg.hi - seg.lo < p.hold or prev.hi - prev.lo < p.hold {
                                List.append(drop_last(acc), { lo: prev.lo, hi: seg.hi, mean: range_mean(prefix, prev.lo, seg.hi) })
                            } else {
                                List.append(acc, seg)
                            }
                        Err(_) => List.append(acc, seg)
                    })
                kept = List.keep_if(absorbed, |s| s.hi - s.lo >= p.hold)
                # one level is a steady ride, not structure — and the work/recovery
                # threshold comes from the LEVELS THEMSELVES (the two-cluster split
                # below), never from the global distribution: v1's
                # quantile-midpoint threshold sat ABOVE the reps on a work-dominated
                # ride and labeled 3x12 all-recovery (#170)
                if List.len(kept) < 2 {
                    []
                } else {
                    sorted_means = List.sort_with(List.map(kept, |s| s.mean), |a, b| if a < b LT else if a > b GT else EQ)
                    # two-cluster split maximizing between-class variance (Otsu in 1D),
                    # gated on CLUSTER-MEAN separation. Largest-adjacent-gap was tried
                    # first and failed on real rowing intervals: ten work and ten
                    # recovery levels make the sorted means quasi-continuous (max gap
                    # 10 W) while the clusters sit 46 W apart.
                    m_prefix = prefix_sums(sorted_means)
                    nm = List.len(sorted_means)
                    split = Iter.fold(1..<nm, { score: 0.0.F64, gap: 0.0.F64, thr: 0.0.F64 }, |acc, i| {
                        lo_mean = range_mean(m_prefix, 0, i)
                        hi_mean = range_mean(m_prefix, i, nm)
                        w0 = (i).to_f64()
                        w1 = ((nm - i)).to_f64()
                        score = w0 * w1 * (hi_mean - lo_mean) * (hi_mean - lo_mean)
                        if score > acc.score {
                            lo_edge = List.get(sorted_means, i - 1) ?? 0.0
                            hi_edge = List.get(sorted_means, i) ?? 0.0
                            { score, gap: hi_mean - lo_mean, thr: (lo_edge + hi_edge) / 2.0 }
                        } else {
                            acc
                        }
                    })
                    labeled0 = List.map(kept, |s| { work: s.mean >= split.thr, lo: s.lo, hi: s.hi, mean: s.mean })
                    # adjacent work pieces are ONE effort: a sliced continuous block
                    # must not read as reps (the #170 false-positive repro was seven
                    # back-to-back "reps" carved out of a 25-minute steady push)
                    merged = List.fold(labeled0, [], |acc, s|
                        match List.last(acc) {
                            Ok(prev) =>
                                if prev.work and s.work {
                                    List.append(drop_last(acc), { work: True, lo: prev.lo, hi: s.hi, mean: range_mean(prefix, prev.lo, s.hi) })
                                } else {
                                    List.append(acc, s)
                                }
                            Err(_) => List.append(acc, s)
                        })
                    work_means = List.map(List.keep_if(merged, |s| s.work), |s| s.mean)
                    rest_means = List.map(List.keep_if(merged, |s| !(s.work)), |s| s.mean)
                    work_med = median_f64(work_means)
                    rest_med = median_f64(rest_means)
                    # the contrast gate: intervals require the easy parts to be EASY.
                    # A progressive ride splits into levels whose "recoveries" sit near
                    # the work (measured 0.83 on the false-positive repro) while real
                    # structure separates hard (3x12: 0.53, surge ride: 0.75, so the
                    # multi-rep limit is 0.80). A SINGLE sustained effort (20-min test,
                    # a 40/20 block read as one) is a weaker structural claim and needs
                    # the stronger 0.65 separation.
                    contrast_ok =
                        if List.is_empty(work_means) or List.is_empty(rest_means) or work_med <= 0.0 {
                            False
                        } else {
                            limit = if List.len(work_means) >= 2 0.80 else 0.65
                            rest_med / work_med <= limit
                        }
                    # work filling nearly the whole timeline is a continuous ride with a
                    # warmup, not intervals: rescoring history surfaced dozens of
                    # steady rides reporting one 44-minute "rep" (0.98 of the ride).
                    # Real dense structure stays well under: 3x12 = 0.80, a 5x8min
                    # with short recoveries = 0.89 — the ceiling is 0.93.
                    work_samples = List.fold(List.keep_if(merged, |s| s.work), 0.U64, |acc, s| acc + (s.hi - s.lo))
                    total_samples = List.fold(merged, 0.U64, |acc, s| acc + (s.hi - s.lo))
                    work_frac_ok = total_samples > 0 and (work_samples).to_f64() / (total_samples).to_f64() <= 0.93
                    if split.gap < p.min_shift or !contrast_ok or !work_frac_ok {
                        # levels not meaningfully apart, or the "easy" is not easy —
                        # continuous effort, honestly reported as no structure
                        []
                    } else {
                        labeled = List.map(merged, |s| {
                            # in-range by construction (bounds within [0, n), hi > lo) — the
                            # fallback can't fire; it exists so an editing mistake fails a
                            # duration expect instead of crashing
                            start_t = (List.get(pairs, s.lo)).map_ok(|x| x.t).ok_or(0)
                            end_t = (List.get(pairs, s.hi - 1)).map_ok(|x| x.t).ok_or(0)
                            capped = Iter.fold((s.lo + 1)..<s.hi, 1.I64, |acc, i| {
                                prev_t = (List.get(pairs, i - 1)).map_ok(|x| x.t).ok_or(0)
                                cur_t = (List.get(pairs, i)).map_ok(|x| x.t).ok_or(0)
                                dt = cur_t - prev_t
                                acc + (if dt > max_sample_gap_s max_sample_gap_s else dt)
                            })
                            kind : SegmentKind
                            kind = if s.work Work else Recovery
                            { kind, start_s: start_t, end_s: end_t, dur_s: capped, avg_signal: s.mean }
                        })
                        with_warm = match List.first(labeled) {
                            Ok(f) => if f.kind == Recovery (List.set(labeled, 0, { ..f, kind: Warmup })).ok_or(labeled) else labeled
                            Err(_) => labeled
                        }
                        match List.last(with_warm) {
                            Ok(l) => if l.kind == Recovery (List.set(with_warm, List.len(with_warm) - 1, { ..l, kind: Cooldown })).ok_or(with_warm) else with_warm
                            Err(_) => with_warm
                        }
                    }
                }
            }
        }
    }

    # ── HR enrichment of detected segments (never places edges) ───────

    RepHr : { peak_hr : F64, avg_hr : F64, rec_drop_60s : [Known(F64), Unknown] }

    # HR for ONE work rep, from the 1 Hz HR series (pass the RESAMPLED stream —
    # raw smart-recording samples arrive 4-10 s apart and would leave the short
    # windows below empty on real activities). NoHr when the rep's span holds no
    # samples — honest absence, never zeros posing as measurements.
    #
    # The 60 s recovery drop is only a fitness marker if those 60 s are actually
    # recovery: when the NEXT work rep starts inside the measurement window the
    # drop is Unknown, not a number measured half-way into the following effort.
    segment_hr : Segment, [NextWorkAt(I64), NoNextWork], List({ t : I64, v : F64 }) -> [Hr(RepHr), NoHr]
    segment_hr = |seg, next_work, hr_pairs| {
        inside = List.keep_if(hr_pairs, |h| h.t >= seg.start_s and h.t <= seg.end_s)
        if List.is_empty(inside) {
            NoHr
        } else {
            peak = List.fold(inside, 0.0.F64, |m, h| if h.v > m h.v else m)
            avg = List.fold(inside, 0.0.F64, |sum, h| sum + h.v) / ((List.len(inside))).to_f64()
            end_t = seg.end_s + 1
            window_clear = match next_work {
                NextWorkAt(nw) => nw >= end_t + 65
                NoNextWork => True
            }
            drop = if !window_clear {
                Unknown
            } else {
                end_win = List.keep_if(hr_pairs, |h| h.t >= end_t - 5 and h.t < end_t)
                after_win = List.keep_if(hr_pairs, |h| h.t >= end_t + 55 and h.t < end_t + 65)
                if List.is_empty(end_win) or List.is_empty(after_win) {
                    Unknown
                } else {
                    end_m = List.fold(end_win, 0.0.F64, |sm2, h| sm2 + h.v) / ((List.len(end_win))).to_f64()
                    aft_m = List.fold(after_win, 0.0.F64, |sm2, h| sm2 + h.v) / ((List.len(after_win))).to_f64()
                    Known(end_m - aft_m)
                }
            }
            Hr({ peak_hr: peak, avg_hr: avg, rec_drop_60s: drop })
        }
    }

}

# ── tests ───────────────────────────────────────────────────────────

# lens selection: power ride -> Ef, run with pace+HR -> SpeedHr, rated strength -> Rpe
expect {
    row = |sport, np, dist, mt, rpe| { name: "X", date: "2025-01-01", sport, distance_m: dist, moving_time: mt, np_w: np, avg_hr: 150.0, rpe, output_kj: 0.0, tss: 0.0, load_model: "power_stream", decoupling_pct: 0.0, decoupling_known: False }
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
    row = |lm| { name: "X", date: "2025-01-01", sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: 200.0, avg_hr: 150.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: lm, decoupling_pct: 0.0, decoupling_known: False }
    Metrics.lens_score(Ef, row("power_stream")).is_ok()
    and Metrics.lens_score(Ef, row("avg_watts")).is_err()
    and Metrics.lens_score(Ef, row("weighted_watts")).is_ok()
}

# swim TSS cubes the speed ratio (drag), running squares it. At IF 1.2 for one hour that is
# 173 vs 144 — the square under-scores hard swim sets by ~20%.
expect {
    swim = Metrics.pace_tss({ ngp_speed: 1.2, threshold_speed: 1.0, dur_s: 3600.0, exponent: Sports.pace_tss_exponent("Swim") })
    run = Metrics.pace_tss({ ngp_speed: 1.2, threshold_speed: 1.0, dur_s: 3600.0, exponent: Sports.pace_tss_exponent("Run") })
    (swim - 172.8).abs() < 0.01 and (run - 144.0).abs() < 0.01
}

# at threshold both are 100 regardless of exponent — the curves only diverge off threshold
expect {
    swim = Metrics.pace_tss({ ngp_speed: 1.0, threshold_speed: 1.0, dur_s: 3600.0, exponent: 3.0 })
    (swim - 100.0).abs() < 0.001
}

# THE gap-cap guarantee, which nothing tested until now: a gap longer than
# max_sample_gap_s must contribute AT MOST max_sample_gap_s, never its full length. Two
# samples 100 s apart, both hard, credit 30 s of hard work — not 100. Without this cap a
# paused ride would bank the whole stop as whatever intensity resumed after it.
expect {
    far_apart = [{ t: 0.I64, v: 300.0.F64 }, { t: 100.I64, v: 300.0.F64 }]
    r = Metrics.time_in_power_intensity(far_apart, 250.0)
    r.hard_s == 30 and r.easy_s == 0 and r.moderate_s == 0
}

# the same cap on the pace path — one implementation, so one guarantee
expect {
    far_apart = [{ t: 0.I64, v: 5.0.F64 }, { t: 100.I64, v: 5.0.F64 }]
    r = Metrics.time_in_pace_intensity(far_apart, 4.0)
    r.hard_s == 30
}

# a gap exactly AT the cap is fully credited — the boundary is inclusive
expect {
    at_cap = [{ t: 0.I64, v: 300.0.F64 }, { t: 30.I64, v: 300.0.F64 }]
    Metrics.time_in_power_intensity(at_cap, 250.0).hard_s == 30
}

# coasting is excluded from the intensity split, not counted as easy. 60 s pedalling at
# 100 W (easy vs FTP 250) then 60 s freewheeling at 0 W: easy is 60 s, not 120 s, and the
# buckets sum to pedalling time. Counting the descent as "easy" was what made a
# descent-heavy ride read as far more polarized than it really was.
expect {
    ride = List.map_with_index(List.repeat(0.0, 121), |_, i| {
        t: (i).to_i64_wrap(),
        v: (if i < 60 100.0 else 0.0),
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

# resample_1s_pairs orders its input first — sorting the streams that need it, skipping the
# sort for the ones already ascending. One out-of-order sample used to be dropped WITHOUT
# advancing the anchor, so a single large stray timestamp swallowed every sample after it.
# Same samples, shuffled: the result must be identical to the ordered case, which is exactly
# the guarantee the skip must not break.
expect {
    ordered = [{ t: 0.I64, v: 0.0.F64 }, { t: 1.I64, v: 4.0.F64 }, { t: 2.I64, v: 8.0.F64 }]
    shuffled = [{ t: 2.I64, v: 8.0.F64 }, { t: 0.I64, v: 0.0.F64 }, { t: 1.I64, v: 4.0.F64 }]
    Metrics.resample_1s_pairs(ordered, Interpolate) == Metrics.resample_1s_pairs(shuffled, Interpolate)
}

# the ascending check that decides whether sorting is needed at all
expect {
    up = [{ t: 0.I64, v: 1.0.F64 }, { t: 1.I64, v: 2.0.F64 }, { t: 5.I64, v: 3.0.F64 }]
    down = [{ t: 5.I64, v: 1.0.F64 }, { t: 1.I64, v: 2.0.F64 }]
    dup = [{ t: 3.I64, v: 1.0.F64 }, { t: 3.I64, v: 2.0.F64 }]
    # equal timestamps are still ascending — the resample fold treats them as duplicates,
    # and sorting them would only shuffle equal keys
    Metrics.ascending_by_t(up) and !Metrics.ascending_by_t(down) and Metrics.ascending_by_t(dup) and Metrics.ascending_by_t([])
}

# sorted_by_t returns an ordered list either way — the skip must never change the result
expect {
    up = [{ t: 0.I64, v: 1.0.F64 }, { t: 1.I64, v: 2.0.F64 }, { t: 2.I64, v: 3.0.F64 }]
    down = [{ t: 2.I64, v: 3.0.F64 }, { t: 0.I64, v: 1.0.F64 }, { t: 1.I64, v: 2.0.F64 }]
    Metrics.sorted_by_t(up) == up and Metrics.sorted_by_t(down) == up
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
#   CTL = 100 * (1 - e^-1) = 63.21   (one full time constant — the textbook 63.2%)
#   ATL = 100 * (1 - e^-6) = 99.75   (six of its own, essentially converged)
# With the correct alpha these ARE the closed-form values; the old 1/tau factor gave 63.66
# and 99.85, which is how the wrong constant hid — close enough to look right.
# TSB is deeply negative because fatigue has caught up and fitness has not.
expect {
    final = Iter.fold(0.U64..<42, { ctl: 0.0.F64, atl: 0.0.F64, tsb: 0.0.F64 }, |acc, _|
        Metrics.load_step({ ctl_prev: acc.ctl, atl_prev: acc.atl, tss: 100.0 })
    )
    (final.ctl - 63.21).abs() < 0.05
    and (final.atl - 99.75).abs() < 0.05
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
    r = { name: "X", date: "d", sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: 300.0, avg_hr: 150.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream", decoupling_pct: 0.0, decoupling_known: False }
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

# estimated watts (#73): device_watts=False skips ALL power rungs — a 120-min meterless
# ride with estimated avg 85 W must not score IF 0.35 / TSS 24 when honest rungs exist.
# Here avg_hr 150 scores instead (55 hrTSS), exactly as if no watts were reported.
expect {
    r = Metrics.tss_ladder({ ..Metrics.ladder_base, device_watts: False, np_stream: Ok(85.0), weighted_watts: Ok(85.0), avg_watts: Ok(85.0), avg_hr: Ok(150.0) })
    (r.tss - 55.0).abs() < 0.001 and r.model == "hr_avg"
}

# estimated watts with NO fallback data at all: honest zero, never a fabricated power score
expect {
    r = Metrics.tss_ladder({ ..Metrics.ladder_base, device_watts: False, avg_watts: Ok(85.0) })
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

expect Sports.class("Ride") == Endurance and Sports.class("WeightTraining") == StrengthLike and Sports.class("Workout") == StrengthLike

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
    # decay by the true EWMA factor via the module constants — one source of truth
    (s.ctl - 50.0 * (1.0 - Metrics.ctl_alpha)).abs() < 0.001
    and (s.atl - 60.0 * (1.0 - Metrics.atl_alpha)).abs() < 0.001
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




# ── aerobic decoupling (#94) ─────────────────────────────────────────
# Flat 200W for 20 minutes; HR rises 100 -> 110 exactly at the half boundary (mid =
# t_lo + span//2 = 599, which belongs to the SECOND half). Efficiency goes 200/100 = 2.0 to 200/110 = 1.818,
# so the drift is (2.0 - 1.818) / 2.0 = 9.09% — the same output costing more heartbeats.
# 20 minutes, not 20 samples: each half must clear the 5-minute coverage gate.
expect {
    power = Iter.fold(0.I64..<1200, [], |acc, t| List.append(acc, { t, v: 200.0 }))
    hr = Iter.fold(0.I64..<1200, [], |acc, t| List.append(acc, { t, v: if t < 599 100.0 else 110.0 }))
    match Metrics.decoupling_pct(power, hr, 1200) {
        Known(d) => (d - 9.0909).abs() < 0.01
        Unknown => False
    }
}

# a perfectly steady session drifts 0 — and that 0 is a REAL answer, which is exactly why
# the Known/Unknown pair exists instead of a 0-sentinel
expect {
    power = Iter.fold(0.I64..<1200, [], |acc, t| List.append(acc, { t, v: 200.0 }))
    hr = Iter.fold(0.I64..<1200, [], |acc, t| List.append(acc, { t, v: 100.0 }))
    match Metrics.decoupling_pct(power, hr, 1200) {
        Known(d) => (d).abs() < 0.001
        Unknown => False
    }
}

# no power at all is Unknown, not 0 — a session without a meter must not render as a
# flawless one
expect {
    match Metrics.decoupling_pct([], [{ t: 0, v: 100.0 }], 1200) {
        Known(_) => False
        Unknown => True
    }
}

# a signal that only spans a FRAGMENT of the session (foot pod died at minute 10 of 60)
# must not have that fragment sold as the session's drift — under 5 min per half is Unknown
expect {
    power = Iter.fold(0.I64..<400, [], |acc, t| List.append(acc, { t, v: 200.0 }))
    hr = Iter.fold(0.I64..<400, [], |acc, t| List.append(acc, { t, v: 120.0 }))
    match Metrics.decoupling_pct(power, hr, 1200) {
        Known(_) => False
        Unknown => True
    }
}

# GPS creep: standing 10 min (jitter speeds ~0.05 m/s) then running 10 min computes a
# four-digit "drift" — an artifact, not physiology. Beyond ±50% is Unknown, never Known
expect {
    speed = Iter.fold(0.I64..<1200, [], |acc, t| List.append(acc, { t, v: if t < 600 0.05 else 3.0 }))
    hr = Iter.fold(0.I64..<1200, [], |acc, t| List.append(acc, { t, v: if t < 600 80.0 else 150.0 }))
    match Metrics.decoupling_pct(speed, hr, 1200) {
        Known(_) => False
        Unknown => True
    }
}

# HR that is all junk (a dropped strap reading 20 bpm) leaves nothing to divide by
expect {
    power = [{ t: 0, v: 200.0 }, { t: 10, v: 200.0 }]
    match Metrics.decoupling_pct(power, [{ t: 0, v: 20.0 }, { t: 10, v: 20.0 }], 1200) {
        Known(_) => False
        Unknown => True
    }
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

# pace intensity split (threshold 4.0 m/s): easy <3.04, moderate 3.04–3.64, hard >=3.64.
# Takes (second, speed) PAIRS and sums real elapsed dt, exactly like the power path — 4
# samples one second apart are 3 intervals, not 4 "samples".
expect {
    at_1hz = |vals| List.map_with_index(vals, |v, i| { t: (i).to_i64_wrap(), v })
    easy = Metrics.time_in_pace_intensity(at_1hz([2.0, 2.0, 2.0, 2.0]), 4.0) == { easy_s: 3, moderate_s: 0, hard_s: 0 }
    mod = Metrics.time_in_pace_intensity(at_1hz([3.3, 3.3, 3.3, 3.3]), 4.0) == { easy_s: 0, moderate_s: 3, hard_s: 0 }
    hard = Metrics.time_in_pace_intensity(at_1hz([4.0, 4.0, 4.0, 4.0]), 4.0) == { easy_s: 0, moderate_s: 0, hard_s: 3 }
    no_threshold = Metrics.time_in_pace_intensity(at_1hz([4.0, 4.0]), 0.0) == { easy_s: 0, moderate_s: 0, hard_s: 0 }
    easy and mod and hard and no_threshold
}

# a 5-second recording interval is 5 seconds of work, not 1 "sample" — this is the whole
# point of taking pairs: the pace path now agrees with the power path on what a second is
expect {
    coarse = [{ t: 0.I64, v: 4.0.F64 }, { t: 5.I64, v: 4.0.F64 }, { t: 10.I64, v: 4.0.F64 }]
    Metrics.time_in_pace_intensity(coarse, 4.0) == { easy_s: 0, moderate_s: 0, hard_s: 10 }
}

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
    pr = |name, date, dist| { name, date, sport: "Ride", distance_m: dist, moving_time: 3600, np_w: 100.0, avg_hr: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream", decoupling_pct: 0.0, decoupling_known: False }
    gs = Metrics.group_progress([pr("A", "2025-01-01", 0.0), pr("A", "2025-02-01", 0.0), pr("B", "2025-03-01", 0.0)])
    List.len(gs) == 2 and List.first(gs).map_ok(|g| List.len(g.rows) == 2).ok_or(False)
}

# anchor_filter: exact names pass through; auto-names gate to ±10% of anchor distance;
# distance-less auto-name anchors show alone; off-date anchors drop the group
expect {
    pr = |name, date, dist| { name, date, sport: "Ride", distance_m: dist, moving_time: 3600, np_w: 100.0, avg_hr: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream", decoupling_pct: 0.0, decoupling_known: False }
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

# ── form trend (#111) ────────────────────────────────────────────────
# Mariano's real shape: a month inside one band, so the label never moved while form
# actually swung 7 points. The delta is the thing that carries the information.
expect {
    series = [
        { day: 100, tsb: -13.0 },
        { day: 103, tsb: -11.0 },
        { day: 107, tsb: -6.0 },
    ]
    match Metrics.form_delta_7d(series, 107) {
        Known(d) => (d - 7.0).abs() < 0.001
        Unknown => False
    }
}

# the anchor is the latest day AT OR BEFORE the target, so a gap in the series still
# answers — 105 has no row, 103 is the standing value
expect {
    series = [{ day: 98, tsb: -4.0 }, { day: 103, tsb: -10.0 }]
    match Metrics.form_delta_7d(series, 105) {
        Known(d) => (d - (-6.0)).abs() < 0.001
        Unknown => False
    }
}

# Short history is Unknown, NOT a fabricated swing. Nothing reaches back to day 93, and
# reporting -6 - 0 = -6 here would invent a week-long plunge out of an empty series.
expect {
    series = [{ day: 100, tsb: -6.0 }]
    match Metrics.form_delta_7d(series, 100) {
        Known(_) => False
        Unknown => True
    }
}

# genuinely level is Known(0), and must stay distinguishable from Unknown above
expect {
    series = [{ day: 93, tsb: -8.0 }, { day: 100, tsb: -8.0 }]
    match Metrics.form_delta_7d(series, 100) {
        Known(d) => (d).abs() < 0.001
        Unknown => False
    }
}

# ── form band duration (#123) ────────────────────────────────────────
# The case that prompted the issue: 16 days inside -15..-5 without ever leaving. The
# values DRIFT (-12.5 up to -5.1) rather than repeating, because that is what real TSB
# does and because a constant fixture cannot tell band identity from value equality — an
# implementation comparing `v == now` instead of `form_label(v) == label_now` would pass a
# constant fixture and then return 1 every day in production, silently emitting nothing.
expect {
    series = [
        # day 99 sits in a DIFFERENT band, so the streak has a real left edge and the walk
        # stops because the band changed rather than because the series ran out. Without
        # it the answer is AtLeast(16) — correct, but it would not exercise Known at all.
        { day: 99, tsb: -20.0 },
        { day: 100, tsb: -12.5 },
        { day: 101, tsb: -12.1 },
        { day: 102, tsb: -11.4 },
        { day: 103, tsb: -10.8 },
        { day: 104, tsb: -10.2 },
        { day: 105, tsb: -9.6 },
        { day: 106, tsb: -9.1 },
        { day: 107, tsb: -8.5 },
        { day: 108, tsb: -8.0 },
        { day: 109, tsb: -7.4 },
        { day: 110, tsb: -6.9 },
        { day: 111, tsb: -6.3 },
        { day: 112, tsb: -5.8 },
        { day: 113, tsb: -5.4 },
        { day: 114, tsb: -5.2 },
        { day: 115, tsb: -5.1 },
    ]
    match Metrics.days_in_band(series, 115) {
        Known(n) => n == 16
        AtLeast(_) => False
        Unknown => False
    }
}

# -5.1 and -4.9 are numerically adjacent and in DIFFERENT bands (the boundary is -5.0).
# This is the sharpest test of band-vs-value: any implementation comparing magnitudes
# rather than labels calls these the same and returns 2.
expect {
    series = [{ day: 100, tsb: -5.1 }, { day: 101, tsb: -4.9 }]
    match Metrics.days_in_band(series, 101) {
        Known(n) => n == 1
        AtLeast(_) => False
        Unknown => False
    }
}

# a day that LEFT the band ends the streak there — 2, not the whole series
expect {
    series = [
        { day: 111, tsb: -11.0 },
        { day: 112, tsb: -1.0 },
        { day: 113, tsb: -11.0 },
        { day: 114, tsb: -11.4 },
    ]
    match Metrics.days_in_band(series, 114) {
        Known(n) => n == 2
        AtLeast(_) => False
        Unknown => False
    }
}

# a GAP ends the streak rather than being stepped over: nothing is known about day 113
expect {
    series = [{ day: 112, tsb: -11.0 }, { day: 114, tsb: -11.4 }]
    match Metrics.days_in_band(series, 114) {
        Known(n) => n == 1
        AtLeast(_) => False
        Unknown => False
    }
}

# A streak that fills the whole window reports AtLeast, never Known — the caller passes a
# WINDOW, so "the walk ran out of series" is not the same answer as "the band changed".
# Reporting the cap as an exact count is how `summary` claimed 31 for a 45-day streak.
expect {
    series = [{ day: 100, tsb: -11.0 }, { day: 101, tsb: -11.2 }, { day: 102, tsb: -11.4 }]
    match Metrics.days_in_band(series, 102) {
        AtLeast(n) => n == 3
        Known(_) => False
        Unknown => False
    }
}

# no series reaching the anchor at all is Unknown, not a streak of 0 or 1
expect {
    match Metrics.days_in_band([], 114) {
        Known(_) => False
        AtLeast(_) => False
        Unknown => True
    }
}

# The anchor day itself must be present. A series ending BEFORE the anchor is Unknown —
# not Known(1) borrowed from an older day, which is what an at-or-before anchor produced.
expect {
    match Metrics.days_in_band([{ day: 100, tsb: -11.0 }], 114) {
        Known(_) => False
        AtLeast(_) => False
        Unknown => True
    }
}

# the labels NAME the state and no longer prescribe (#123)
# Band BOUNDARIES, pinned exactly. Every comparator here (<= vs <) used to survive any
# mutation, because the five samples sat far from the edges. It matters more now than it
# did for prose: days_in_band derives identity from form_band, so a boundary that shifts by
# one comparator silently changes streak COUNTS rather than one word of text.
expect Metrics.form_band(-15.0) == HighFatigue      # <= -15 is high fatigue
expect Metrics.form_band(-14.9) == FatigueBuilding
expect Metrics.form_band(-5.0) == FatigueBuilding   # <= -5 is still building
expect Metrics.form_band(-4.9) == Balanced
expect Metrics.form_band(4.9) == Balanced
expect Metrics.form_band(5.0) == Fresh              # < 5 is balanced, so 5.0 is fresh
expect Metrics.form_band(14.9) == Fresh
expect Metrics.form_band(15.0) == VeryFresh

expect Metrics.form_label(-20.0) == "high modeled fatigue"
expect Metrics.form_label(-9.0) == "modeled fatigue building"
expect Metrics.form_label(-1.0) == "balanced"
expect Metrics.form_label(8.0) == "fresh"
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

# ── ramp rates: weekly CTL delta, honest 0 on short history ──
# a steady +5/wk build: 28 days back is 20 lower, so both numbers agree at 5
expect {
    series = [{ day: 100, ctl: 50.0 }, { day: 93, ctl: 45.0 }, { day: 86, ctl: 40.0 }, { day: 79, ctl: 35.0 }, { day: 72, ctl: 30.0 }]
    r = Metrics.ramp_rates(series, 100)
    (r.ramp_7d - 5.0).abs() < 0.001 and (r.ramp_28d_avg - 5.0).abs() < 0.001
}
# one spike week on a flat month: the WEEK is 20, the 4-week average only 5 — the pair
# is what separates a spike from a sustained build; neither number does it alone
expect {
    series = [{ day: 100, ctl: 50.0 }, { day: 93, ctl: 30.0 }, { day: 86, ctl: 30.0 }, { day: 79, ctl: 30.0 }, { day: 72, ctl: 30.0 }]
    r = Metrics.ramp_rates(series, 100)
    (r.ramp_7d - 20.0).abs() < 0.001 and (r.ramp_28d_avg - 5.0).abs() < 0.001
}
# short history: nothing 7 days back, so the honest answer is 0 — NOT today's whole CTL
expect {
    series = [{ day: 100, ctl: 42.0 }, { day: 99, ctl: 40.0 }]
    r = Metrics.ramp_rates(series, 100)
    (r.ramp_7d).abs() < 0.001 and (r.ramp_28d_avg).abs() < 0.001
}
# no history at all
expect {
    r = Metrics.ramp_rates([], 100)
    (r.ramp_7d).abs() < 0.001 and (r.ramp_28d_avg).abs() < 0.001
}
# a detraining block reads negative rather than clamping to 0
expect {
    series = [{ day: 100, ctl: 30.0 }, { day: 93, ctl: 40.0 }]
    r = Metrics.ramp_rates(series, 100)
    (r.ramp_7d + 10.0).abs() < 0.001
}
# a gap in the series resolves to the most recent day AT OR BEFORE the target, matching
# the SQL the caller uses, rather than skipping to a later row
expect {
    series = [{ day: 100, ctl: 50.0 }, { day: 90, ctl: 20.0 }]
    r = Metrics.ramp_rates(series, 100)
    (r.ramp_7d - 30.0).abs() < 0.001
}

# ── hr_missing_streak: newest-first walk, endurance only ──
expect Metrics.hr_missing_streak([]) == 0
# the motivating incident: two strapless rides in a row
expect Metrics.hr_missing_streak([{ sport: "Ride", has_hr: False }, { sport: "Ride", has_hr: False }, { sport: "Ride", has_hr: True }]) == 2
# the most recent session recorded HR, so there is no streak at all
expect Metrics.hr_missing_streak([{ sport: "Ride", has_hr: True }, { sport: "Ride", has_hr: False }]) == 0
# a strength session between two strapless rides neither counts nor resets: lifting
# without a strap is normal, and letting it stop the walk would hide the real gap
expect Metrics.hr_missing_streak([{ sport: "Ride", has_hr: False }, { sport: "WeightTraining", has_hr: False }, { sport: "Ride", has_hr: False }, { sport: "Ride", has_hr: True }]) == 2
# ...and a strength session WITH hr still does not stop it, for the same reason
expect Metrics.hr_missing_streak([{ sport: "Ride", has_hr: False }, { sport: "Yoga", has_hr: True }, { sport: "Ride", has_hr: False }]) == 2
# nothing but strength sessions: no endurance history to judge, so no streak
expect Metrics.hr_missing_streak([{ sport: "WeightTraining", has_hr: False }, { sport: "Yoga", has_hr: False }]) == 0

# a storable date must be canonical, not merely parseable
expect Metrics.is_canonical_date("2026-08-09")
expect Metrics.is_canonical_date("2024-02-29") # real leap day
expect !(Metrics.is_canonical_date("tomorrow"))
expect !(Metrics.is_canonical_date(""))
expect !(Metrics.is_canonical_date("2026-08"))
# each of these PARSES and would be silently normalized to a different day
expect !(Metrics.is_canonical_date("2026-13-45"))
expect !(Metrics.is_canonical_date("2026-02-30"))
expect !(Metrics.is_canonical_date("2026-02-29")) # 2026 is not a leap year
# parses to the right day but sorts wrong as text, which is how it is compared
expect !(Metrics.is_canonical_date("2026-8-5"))
expect !(Metrics.is_canonical_date("999-01-01"))
# a timestamp is not a plan date — date_str_to_days accepts the T suffix, this must not
expect !(Metrics.is_canonical_date("2026-08-09T10:00:00Z"))

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

# ── interval detection fixtures (ADR 0008) ──────────────────────────

# clean steps: warmup 300s@120, 4×(180s@250 / 120s@100), cooldown 300s@110.
# Expect exactly 4 work segments at ~250W, first segment Warmup, last Cooldown.
expect {
    mk = |dur, w, t0| Iter.fold(0.I64..<dur, [], |acc, i| List.append(acc, { t: t0 + i, v: w }))
    rep = |k| {
        base : I64
        base = 300 + k * 300
        List.concat(mk(180.I64, 250.0, base), mk(120.I64, 100.0, base + 180))
    }
    fixture = List.concat(
        List.concat(mk(300.I64, 120.0, 0.I64), List.join([rep(0.I64), rep(1.I64), rep(2.I64), rep(3.I64)])),
        mk(300.I64, 110.0, 1500.I64),
    )
    segs = Metrics.detect_segments(fixture, Metrics.detect_power_params)
    works = List.keep_if(segs, |s| s.kind == Work)
    first_warm = (List.first(segs)).map_ok(|s| s.kind == Warmup).ok_or(False)
    last_cool = (List.last(segs)).map_ok(|s| s.kind == Cooldown).ok_or(False)
    first_work_start = (List.first(works)).map_ok(|w| w.start_s).ok_or(-1)
    List.len(works) == 4
    and first_warm
    and last_cool
    # tight on purpose: the lag-compensated edges must land within 2 s / 2 W of
    # truth — the wide tolerances that hid the smoothing bias are not coming back
    and List.all(works, |s| (s.avg_signal - 250.0).abs() < 2.0)
    and List.all(works, |s| s.dur_s >= 176 and s.dur_s <= 184)
    and first_work_start >= 298 and first_work_start <= 302
    # tiling: 4 works + 3 recoveries + warmup + cooldown, interiors all Recovery
    and List.len(segs) == 9
    and List.all(List.drop_first(List.take_first(segs, 8), 1), |s| s.kind == Work or s.kind == Recovery)
}

# negative control on the same fixture: an impossible spread gate detects nothing —
# proves the gate is live and the expect above cannot pass vacuously
expect {
    mk = |dur, w, t0| Iter.fold(0.I64..<dur, [], |acc, i| List.append(acc, { t: t0 + i, v: w }))
    rep = |k| {
        base : I64
        base = 300 + k * 300
        List.concat(mk(180.I64, 250.0, base), mk(120.I64, 100.0, base + 180))
    }
    fixture = List.concat(
        List.concat(mk(300.I64, 120.0, 0.I64), List.join([rep(0.I64), rep(1.I64), rep(2.I64), rep(3.I64)])),
        mk(300.I64, 110.0, 1500.I64),
    )
    gated = Metrics.detect_segments(fixture, { ..Metrics.detect_power_params, min_shift: 1000.0 })
    long_hold = Metrics.detect_segments(fixture, { ..Metrics.detect_power_params, hold: 200 })
    List.is_empty(gated) and List.is_empty(List.keep_if(long_hold, |s| s.kind == Work and s.dur_s < 200))
}

# noisy steps: same structure under deterministic ±10W noise — count must hold at 4
expect {
    noise = |i| (((i * 7919) % 21)).to_f64() - 10.0
    mk = |dur, w, t0| Iter.fold(0.I64..<dur, [], |acc, i| List.append(acc, { t: t0 + i, v: w + noise(t0 + i) }))
    rep = |k| {
        base : I64
        base = 300 + k * 300
        List.concat(mk(180.I64, 250.0, base), mk(120.I64, 100.0, base + 180))
    }
    fixture = List.concat(
        List.concat(mk(300.I64, 120.0, 0.I64), List.join([rep(0.I64), rep(1.I64), rep(2.I64), rep(3.I64)])),
        mk(300.I64, 110.0, 1500.I64),
    )
    works = List.keep_if(Metrics.detect_segments(fixture, Metrics.detect_power_params), |s| s.kind == Work)
    List.len(works) == 4 and List.all(works, |s| (s.avg_signal - 250.0).abs() < 15.0)
}

# smooth endurance ride: an hour at ~140W with slow drift has NO structure —
# the detector must return nothing, not dress noise up as reps
expect {
    fixture = Iter.fold(0.I64..<3600, [], |acc, i| List.append(acc, { t: i, v: 140.0 + ((i).to_f64()) / 360.0 }))
    List.is_empty(Metrics.detect_segments(fixture, Metrics.detect_power_params))
}

# GPS-wobble steady run: 40 min at ~3.3 m/s with deterministic wobble — zero work
# segments under PACE parameters (wobble must not invent efforts)
expect {
    wobble = |i| ((((i * 31) % 7)).to_f64() - 3.0) * 0.1
    fixture = Iter.fold(0.I64..<2400, [], |acc, i| List.append(acc, { t: i, v: 3.3 + wobble(i) }))
    List.is_empty(Metrics.detect_segments(fixture, Metrics.detect_pace_params))
}

# traffic stop mid-rep: a 60 s recording pause inside the first work rep must be
# BRIDGED — still exactly 2 work segments, and the paused rep's span covers the gap
expect {
    mk = |dur, w, t0| Iter.fold(0.I64..<dur, [], |acc, i| List.append(acc, { t: t0 + i, v: w }))
    fixture = List.join([
        mk(300.I64, 120.0, 0.I64),           # warmup
        mk(90.I64, 250.0, 300.I64),          # rep 1 first half...
        mk(90.I64, 250.0, 450.I64),          # ...pause 390..450, then second half
        mk(120.I64, 100.0, 540.I64),         # recovery
        mk(180.I64, 250.0, 660.I64),         # rep 2
        mk(300.I64, 110.0, 840.I64),         # cooldown
    ])
    segs = Metrics.detect_segments(fixture, Metrics.detect_power_params)
    works = List.keep_if(segs, |s| s.kind == Work)
    # bridged but pause-capped: 180 recorded seconds + a 60 s stop credited at most
    # max_sample_gap_s (30) = 210, never 240 — a stop is not sustained effort
    first_dur = (List.first(works)).map_ok(|s| s.dur_s).ok_or(0)
    List.len(works) == 2 and first_dur >= 206 and first_dur <= 212
}

# per-rep HR: peak/avg, the 60 s recovery drop, honest absence without HR, and the
# window guard — a drop is Unknown both when the stream ends at the rep and when the
# next work rep starts inside the measurement window
expect {
    seg = |s2, e| { kind: Work, start_s: s2, end_s: e, dur_s: e - s2 + 1, avg_signal: 250.0 }
    hr_to = |n| Iter.fold(0.I64..<n, [], |acc, t| {
        v = if t >= 300 and t < 480 150.0 else if t >= 600 and t < 780 160.0 else 110.0
        List.append(acc, { t, v })
    })
    rep1 = seg(300.I64, 479.I64)
    full = hr_to(1080)
    r1 = Metrics.segment_hr(rep1, NextWorkAt(600.I64), full)
    r1_ok = match r1 {
        Hr(h) => (h.avg_hr - 150.0).abs() < 0.001 and (h.peak_hr - 150.0).abs() < 0.001 and h.rec_drop_60s == Known(40.0)
        NoHr => False
    }
    # next work at 520 < end+65: the "recovery" window would measure the next effort
    guarded = match Metrics.segment_hr(rep1, NextWorkAt(520.I64), full) {
        Hr(h) => h.rec_drop_60s == Unknown
        NoHr => False
    }
    # stream truncated right at the rep's end: no after-window, drop must be Unknown —
    # a 0.0 here would be a fabricated flat-recovery fitness marker
    truncated = match Metrics.segment_hr(rep1, NoNextWork, hr_to(485)) {
        Hr(h) => h.rec_drop_60s == Unknown
        NoHr => False
    }
    no_hr = Metrics.segment_hr(rep1, NoNextWork, []) == NoHr
    r1_ok and guarded and truncated and no_hr
}


# POSITIVE pace fixture — the pace path must be able to detect something, or a
# params swap / units regression silently kills detection for every run and swim
# while all the negative pace tests stay green. 4×(180 s @ 4.5 m/s / 120 s @ 2.0).
expect {
    mk = |dur, v, t0| Iter.fold(0.I64..<dur, [], |acc, i| List.append(acc, { t: t0 + i, v }))
    rep = |k| {
        base : I64
        base = 300 + k * 300
        List.concat(mk(180.I64, 4.5, base), mk(120.I64, 2.0, base + 180))
    }
    fixture = List.concat(
        List.concat(mk(300.I64, 2.5, 0.I64), List.join([rep(0.I64), rep(1.I64), rep(2.I64), rep(3.I64)])),
        mk(300.I64, 2.3, 1500.I64),
    )
    works = List.keep_if(Metrics.detect_segments(fixture, Metrics.detect_pace_params), |s| s.kind == Work)
    List.len(works) == 4 and List.all(works, |s| (s.avg_signal - 4.5).abs() < 0.1)
}

# reps AT the hold boundary: 60 s on / 60 s off is a real VO2 format sitting
# exactly on the parameter — 6 reps must all survive
expect {
    mk = |dur, v, t0| Iter.fold(0.I64..<dur, [], |acc, i| List.append(acc, { t: t0 + i, v }))
    rep = |k| {
        base : I64
        base = 300 + k * 120
        List.concat(mk(60.I64, 300.0, base), mk(60.I64, 100.0, base + 60))
    }
    fixture = List.concat(
        List.concat(mk(300.I64, 120.0, 0.I64), List.join([rep(0.I64), rep(1.I64), rep(2.I64), rep(3.I64), rep(4.I64), rep(5.I64)])),
        mk(300.I64, 110.0, 1020.I64),
    )
    works = List.keep_if(Metrics.detect_segments(fixture, Metrics.detect_power_params), |s| s.kind == Work)
    List.len(works) == 6
}

# sub-hold efforts (40/20s HIIT) cannot become individual reps BY DESIGN — the
# whole rep block reads as ONE sustained work segment at its blended level, which
# is the honest v1 semantic (a 40/20 block IS ~continuous sweet-spot effort).
# Tuning hold downward must consciously break this expect, not slip through.
expect {
    mk = |dur, v, t0| Iter.fold(0.I64..<dur, [], |acc, i| List.append(acc, { t: t0 + i, v }))
    rep = |k| {
        base : I64
        base = 300 + k * 60
        List.concat(mk(40.I64, 320.0, base), mk(20.I64, 90.0, base + 40))
    }
    fixture = List.concat(
        List.concat(mk(300.I64, 120.0, 0.I64), List.join([rep(0.I64), rep(1.I64), rep(2.I64), rep(3.I64), rep(4.I64), rep(5.I64), rep(6.I64), rep(7.I64)])),
        mk(300.I64, 110.0, 780.I64),
    )
    works = List.keep_if(Metrics.detect_segments(fixture, Metrics.detect_power_params), |s| s.kind == Work)
    one_block = (List.first(works)).map_ok(|s| s.dur_s >= 400).ok_or(False)
    List.len(works) == 1 and one_block
}

# third knob's negative control: an absurd shift_frac finds no edges at all
expect {
    mk = |dur, v, t0| Iter.fold(0.I64..<dur, [], |acc, i| List.append(acc, { t: t0 + i, v }))
    rep = |k| {
        base : I64
        base = 300 + k * 300
        List.concat(mk(180.I64, 250.0, base), mk(120.I64, 100.0, base + 180))
    }
    fixture = List.concat(
        List.concat(mk(300.I64, 120.0, 0.I64), List.join([rep(0.I64), rep(1.I64), rep(2.I64), rep(3.I64)])),
        mk(300.I64, 110.0, 1500.I64),
    )
    List.is_empty(Metrics.detect_segments(fixture, { ..Metrics.detect_power_params, shift_frac: 5.0 }))
}

# the contrast gate's tripwire (#170): near-flat alternation is NOT structure —
# this and the floor expect below are what make future gate tuning a conscious act
expect {
    mk = |dur, v, t0| Iter.fold(0.I64..<dur, [], |acc, i| List.append(acc, { t: t0 + i, v }))
    rep = |k| {
        base : I64
        base = 300 + k * 300
        List.concat(mk(180.I64, 205.0, base), mk(120.I64, 165.0, base + 180))
    }
    fixture = List.concat(
        List.concat(mk(300.I64, 170.0, 0.I64), List.join([rep(0.I64), rep(1.I64), rep(2.I64), rep(3.I64)])),
        mk(300.I64, 168.0, 1500.I64),
    )
    # 205 W "reps" over 165 W "recovery" is near-flat riding, not intervals: the
    # easy parts sit at 0.82 of the work — above the multi-rep contrast limit —
    # so the detector reports no structure even though the 40 W steps clear the
    # min_shift floor. This is the #170 false-positive class, pinned.
    near_flat = Metrics.detect_segments(fixture, { ..Metrics.detect_power_params, min_shift: 30.0 })
    List.is_empty(near_flat)
}

# min_shift is a FLOOR on the edge threshold: steps below it produce no edges at
# all. Real 250/100 structure detects with the floor under the step size and
# vanishes when the floor is raised above it.
expect {
    mk = |dur, v, t0| Iter.fold(0.I64..<dur, [], |acc, i| List.append(acc, { t: t0 + i, v }))
    rep = |k| {
        base : I64
        base = 300 + k * 300
        List.concat(mk(180.I64, 250.0, base), mk(120.I64, 100.0, base + 180))
    }
    fixture = List.concat(
        List.concat(mk(300.I64, 120.0, 0.I64), List.join([rep(0.I64), rep(1.I64), rep(2.I64), rep(3.I64)])),
        mk(300.I64, 110.0, 1500.I64),
    )
    above = Metrics.detect_segments(fixture, { ..Metrics.detect_power_params, min_shift: 30.0 })
    below = Metrics.detect_segments(fixture, { ..Metrics.detect_power_params, min_shift: 200.0 })
    List.len(List.keep_if(above, |s| s.kind == Work)) == 4 and List.is_empty(below)
}

# ── the #170 pins ───────────────────────────────────────────────────
# One REAL ride and two synthetics. The real one is the bug itself: no synthetic
# reproduced the false negative until the mechanism was understood, so the actual
# stream stays as the regression anchor. The other two failure modes reduce to
# clean synthetic shapes (plus the near-flat and floor expects above).

# Mariano's 2026-08-16 "45 min Metallica Ride with Kendall Toole" (activity
# 19773062126): a textbook 3x12 min @ ~250-268 W with 3 min recoveries — the
# prescribed threshold session, ~80% work samples. v1's distribution gates
# reported ZERO segments on it. Mean watts per 15 s bucket, from the stored
# stream; regenerate only from the activity, never by hand.
expect {
    profile : List(I64)
    profile = [
        111, 197, 185, 206, 206, 204, 204, 192, 197, 194, 198, 201, 248, 254, 255, 258, 261, 255, 259, 266,
        263, 266, 264, 268, 262, 269, 267, 271, 264, 263, 267, 264, 269, 269, 270, 275, 269, 268, 272, 273,
        273, 273, 272, 277, 281, 277, 274, 274, 265, 270, 274, 270, 268, 269, 268, 282, 273, 273, 279, 280,
        111, 148, 158, 171, 171, 164, 157, 153, 148, 157, 154, 148, 263, 266, 270, 275, 268, 263, 267, 264,
        267, 274, 274, 272, 266, 266, 264, 267, 272, 268, 261, 266, 269, 267, 266, 265, 269, 269, 263, 260,
        257, 266, 264, 263, 262, 255, 266, 265, 271, 271, 267, 267, 262, 265, 268, 262, 259, 256, 256, 241,
        116, 124, 122, 118, 139, 138, 125, 131, 134, 137, 133, 131, 249, 258, 257, 251, 249, 249, 254, 247,
        244, 249, 253, 251, 248, 254, 251, 250, 250, 247, 254, 253, 255, 246, 249, 251, 249, 253, 256, 257,
        266, 271, 267, 259, 251, 279, 261, 248, 248, 252, 245, 257, 246, 247, 252, 245, 245, 251, 242, 244,
        95,
    ]
    fixture = Iter.fold(0..<(List.len(profile) * 15), [], |acc, i| {
        w = List.get(profile, i // 15) ?? 0
        List.append(acc, { t: (i).to_i64_wrap(), v: (w).to_f64() })
    })
    works = List.keep_if(Metrics.detect_segments(fixture, Metrics.detect_power_params), |s| s.kind == Work)
    List.len(works) == 3 and List.all(works, |s| s.dur_s >= 650 and s.dur_s <= 800 and s.avg_signal >= 240.0 and s.avg_signal <= 280.0)
}

# the false-positive shape (#170): a progressive ride — levels stepping up
# back-to-back with no recoveries between — is ONE continuous effort, not reps.
# (The gentle steps stay under the edge delta, so this rejects via the
# single-effort contrast limit against its warm "easy" parts; the merge has its
# own fixture below.)
expect {
    mk = |dur, v, t0| Iter.fold(0.I64..<dur, [], |acc, i| List.append(acc, { t: t0 + i, v }))
    fixture = List.join([
        mk(420.I64, 185.0, 0.I64),
        mk(400.I64, 215.0, 420.I64),
        mk(400.I64, 235.0, 820.I64),
        mk(500.I64, 250.0, 1220.I64),
        mk(500.I64, 262.0, 1720.I64),
        mk(300.I64, 240.0, 2220.I64),
        mk(180.I64, 170.0, 2520.I64),
    ])
    List.is_empty(Metrics.detect_segments(fixture, Metrics.detect_power_params))
}

# the adjacent-work merge, pinned directly: three back-to-back blocks at 200/
# 245/290 W step hard enough to segment separately, and MUST come out as ONE
# work effort at the blended mean — a sliced continuous push is not reps.
expect {
    mk = |dur, v, t0| Iter.fold(0.I64..<dur, [], |acc, i| List.append(acc, { t: t0 + i, v }))
    fixture = List.join([
        mk(420.I64, 130.0, 0.I64),
        mk(400.I64, 200.0, 420.I64),
        mk(400.I64, 245.0, 820.I64),
        mk(400.I64, 290.0, 1220.I64),
        mk(600.I64, 125.0, 1620.I64),
    ])
    works = List.keep_if(Metrics.detect_segments(fixture, Metrics.detect_power_params), |s| s.kind == Work)
    List.len(works) == 1 and List.all(works, |s| s.dur_s >= 1150 and s.dur_s <= 1250 and (s.avg_signal - 245.0).abs() < 8.0)
}

# true surge structure with IRREGULAR rep lengths (a music ride, not a workout
# card) survives: what separates it from the ramp above is real recoveries
# between the pushes, not uniform durations.
expect {
    mk = |dur, v, t0| Iter.fold(0.I64..<dur, [], |acc, i| List.append(acc, { t: t0 + i, v }))
    fixture = List.join([
        mk(300.I64, 150.0, 0.I64),
        mk(120.I64, 245.0, 300.I64),
        mk(200.I64, 175.0, 420.I64),
        mk(400.I64, 240.0, 620.I64),
        mk(90.I64, 160.0, 1020.I64),
        mk(70.I64, 250.0, 1110.I64),
        mk(240.I64, 170.0, 1180.I64),
        mk(300.I64, 235.0, 1420.I64),
        mk(280.I64, 155.0, 1720.I64),
    ])
    works = List.keep_if(Metrics.detect_segments(fixture, Metrics.detect_power_params), |s| s.kind == Work)
    List.len(works) >= 3 and List.all(works, |s| s.avg_signal >= 230.0 and s.avg_signal <= 255.0)
}


# ── stimulus spacing (#159): dedup, sort, upper median; honest Unknown below
# two distinct dates
expect {
    Metrics.median_gap_days([100, 103, 107, 110]) == Known(3)
    and Metrics.median_gap_days([110, 100, 103, 107]) == Known(3)
    and Metrics.median_gap_days([100, 100, 104]) == Known(4)
    and Metrics.median_gap_days([100]) == Unknown
    and Metrics.median_gap_days([]) == Unknown
    and Metrics.median_gap_days([100, 101]) == Known(1)
}

# ── coverage split (#157): sums to exactly 100 under every rounding shape —
# thirds, halves, tiny slivers, single-tier, and the all-zero honest case
expect {
    sum_of = |c| c.high_pct + c.medium_pct + c.low_pct
    thirds = Metrics.coverage_pcts(1.0, 1.0, 1.0)
    halves = Metrics.coverage_pcts(50.0, 50.0, 0.0)
    sliver = Metrics.coverage_pcts(99.9, 0.05, 0.05)
    lone = Metrics.coverage_pcts(0.0, 0.0, 42.0)
    zero = Metrics.coverage_pcts(0.0, 0.0, 0.0)
    sum_of(thirds) == 100 and sum_of(halves) == 100 and sum_of(sliver) == 100
    and thirds.high_pct == 34 and thirds.medium_pct == 33 and thirds.low_pct == 33
    and halves.high_pct == 50 and halves.medium_pct == 50
    and lone.low_pct == 100 and sum_of(lone) == 100
    and sum_of(zero) == 0
}

# ── baseline primitives (#160): fixed band edges are symmetric and total;
# percentile is direction-free rank, exact at the edges
expect {
    Metrics.duration_band(2699) == { lo: 1200, hi: 2700 }
    and Metrics.duration_band(2700) == { lo: 2700, hi: 4500 }
    and Metrics.duration_band(0) == { lo: 0, hi: 1200 }
    and Metrics.duration_band(90000) == { lo: 7200, hi: 8640000 }
    and Metrics.duration_band(90000) == Metrics.duration_band(2000000)
    and Metrics.duration_band(2650) == Metrics.duration_band(1250)
}

expect {
    Metrics.percentile_of([1.0, 2.0, 3.0, 4.0], 4.0) == 100
    and Metrics.percentile_of([1.0, 2.0, 3.0, 4.0], 1.0) == 25
    and Metrics.percentile_of([1.0, 2.0, 3.0, 4.0], 0.5) == 0
    and Metrics.percentile_of([1.0, 2.0, 3.0, 4.0], 2.5) == 50
    and Metrics.percentile_of([5.0], 5.0) == 100
    and Metrics.percentile_of([], 1.0) == 0
}

# exp_neg against known values — there is no `.exp()` method on F64 at all on
# this compiler, so this is the only exponential in the codebase that is
# computed rather than tabulated
expect {
    near = |a, b| (a - b).abs() < 0.000001
    near(Metrics.exp_neg(0.0), 1.0)
    and near(Metrics.exp_neg(1.0), 0.3678794412)
    and near(Metrics.exp_neg(0.5), 0.6065306597)
    and near(Metrics.exp_neg(3.0), 0.0497870684)
    and near(Metrics.exp_neg(0.001), 0.9990004998)
    # a sign slip must not read as a plausible decay
    and near(Metrics.exp_neg(-1.0), 1.0)
}

# TTE: the model's own arithmetic, and its two honest refusals
expect {
    fit = { cp: 250.0, w_prime: 20000.0 }
    # 300W is 50 over CP: 20000/50 = 400s, inside the 2-20min window
    at300 = match Metrics.time_to_exhaustion(fit, 300.0) { Seconds(t) => (t - 400.0).abs() < 0.001  _ => False }
    # at CP the model says forever; below it, worse than forever
    at_cp = Metrics.time_to_exhaustion(fit, 250.0) == BelowCp
    below = Metrics.time_to_exhaustion(fit, 200.0) == BelowCp
    # 600W is 350 over: 57s — real, but far outside where the model holds
    sprint = match Metrics.time_to_exhaustion(fit, 600.0) { OutsideModel(t) => (t - 57.142857).abs() < 0.001  _ => False }
    # 265W is 15 over: 1333s, past twenty minutes
    long = match Metrics.time_to_exhaustion(fit, 265.0) { OutsideModel(_) => True  _ => False }
    at300 and at_cp and below and sprint and long
}

# W' balance: drains above CP, reconstitutes below it, is ALLOWED to go
# negative, and a recording gap is bridged rather than credited as recovery
expect {
    fit = { cp: 250.0, w_prime: 20000.0 }
    hard = Iter.fold(0.I64..<100, [], |acc, i| List.append(acc, { t: i, v: 350.0 }))
    bal = Metrics.w_prime_balance(hard, fit)
    # 100 samples at 100W over CP = 10 kJ spent, half the tank
    spent = match List.last(bal) { Ok(b) => (b - 10000.0).abs() < 200.0  Err(_) => False }
    # then easy riding puts some back
    rest = List.concat(hard, Iter.fold(0.I64..<300, [], |acc, i| List.append(acc, { t: 100 + i, v: 150.0 })))
    recovered = match List.last(Metrics.w_prime_balance(rest, fit)) { Ok(b) => b > 10000.0 and b <= 20000.0  Err(_) => False }
    # An effort past the tank's capacity goes NEGATIVE, and must: clamping at
    # zero would reset the accumulated deficit, so every sample after the first
    # clamp is scored against a tank that silently refilled. The negative is
    # also the only signal that the FIT does not describe this rider, which is
    # information the caller needs (Report flags it as `model_exceeded`).
    epic = Iter.fold(0.I64..<1000, [], |acc, i| List.append(acc, { t: i, v: 400.0 }))
    epic_bal = Metrics.w_prime_balance(epic, fit)
    # 1000s at 150W over CP = 150 kJ against a 20 kJ tank: 130 kJ past empty.
    # A floor here reports 0 and hides a 7.5x model failure as "emptied".
    overdrawn = match List.last(epic_bal) { Ok(b) => (b + 130000.0).abs() < 500.0  Err(_) => False }
    # monotone down throughout, since the power never drops back below CP
    never_refills = match (List.first(epic_bal), List.last(epic_bal)) {
        (Ok(f), Ok(l)) => l < f
        _ => False
    }
    spent and recovered and overdrawn and never_refills
}

# the clock never runs backwards: a stamp EARLIER than the last charges no
# time AND does not let the next stamp re-bill the span it already covered
expect {
    fit = { cp: 250.0, w_prime: 20000.0 }
    p = |t, v| { t, v }
    # 0,10,5,20 spans 20s at 100W over CP = 2000 J spent, not 2500
    jumbled = Metrics.w_prime_balance([p(0, 350.0), p(10, 350.0), p(5, 350.0), p(20, 350.0)], fit)
    correct = match List.last(jumbled) { Ok(b) => (b - 18000.0).abs() < 0.001  Err(_) => False }
    # and sorted input is completely unaffected -- the guard is defensive, and
    # a guard that changed the normal path would be a regression
    sorted = Metrics.w_prime_balance([p(0, 350.0), p(5, 350.0), p(10, 350.0), p(20, 350.0)], fit)
    unchanged = match List.last(sorted) { Ok(b) => (b - 18000.0).abs() < 0.001  Err(_) => False }
    correct and unchanged
}

# rep bands separate workouts that session bands would merge (#149): a 3x2min
# VO2 set and a 3x12min threshold block are not the same session shape
expect {
    Metrics.rep_duration_band(120) != Metrics.rep_duration_band(720)
    and Metrics.rep_duration_band(720) == { lo: 600, hi: 900 }
    and Metrics.rep_duration_band(180) == { lo: 180, hi: 360 }
    and Metrics.rep_duration_band(59) == { lo: 0, hi: 60 }
    and Metrics.rep_duration_band(3600) == { lo: 1800, hi: 86400 }
    # symmetric: two durations in one band agree about each other
    and Metrics.rep_duration_band(610) == Metrics.rep_duration_band(890)
    # and the session-scale rule really would have merged them
    and Metrics.duration_band(120) == Metrics.duration_band(720)
}

# the float gate and the integer gate are the SAME gate. Mutating either alone
# fails here, which is what the census's exactness claim rests on.
expect {
    num = Metrics.anchor_uniformity_num
    den = Metrics.anchor_uniformity_den
    ratio = (num).to_f64() / (den).to_f64()
    same = (ratio - Metrics.anchor_uniformity_max).abs() < 0.0001
    # exercised at the boundary in both directions
    inside = Metrics.is_uniform_reps(100, 160)
    outside = !(Metrics.is_uniform_reps(100, 161))
    # A zero shortest rep is UNMEASURED, not perfectly uniform. The (0, 600)
    # case is already False from the arithmetic alone, so it does NOT exercise
    # the guard -- (0, 0) is the one that does, and asserting only the former
    # let a mutation of the guard survive.
    zero_not_uniform = !(Metrics.is_uniform_reps(0, 600)) and !(Metrics.is_uniform_reps(0, 0))
    same and inside and outside and zero_not_uniform
}

# The EWMA constants are hardcoded, and this is what keeps the hardcoding honest
# (#191). They were written as literals when no exponential was available; one now
# is, so the formula in the comment beside them is checkable by machine instead of
# by eye. The tolerance is 1e-9, which is what the literals' own truncation allows:
# it catches a mistyped digit or a reversion to the 1/tau form that this comment
# block exists about, but NOT shaving one more digit off the last place. Tightening
# it further would require extending the literals, which changes the math for a
# difference no output can express.
expect {
    ctl_true = 1.0 - Metrics.exp_neg(1.0 / 42.0)
    atl_true = 1.0 - Metrics.exp_neg(1.0 / 7.0)
    # the literals are the true values truncated at ~1e-10, which is far below
    # anything CTL can express (it renders as a whole number), so they stay as
    # they are -- deriving them live would change no output and cost a
    # metrics_rev bump for a difference nobody can observe
    (Metrics.ctl_alpha - ctl_true).abs() < 0.000000001
    and (Metrics.atl_alpha - atl_true).abs() < 0.000000001
    # and the tolerance is tight enough to catch a real slip: 1/42 rather than
    # 1 - e^(-1/42) is the mistake this whole comment block exists about
    and (Metrics.ctl_alpha - 1.0 / 42.0).abs() > 0.000000001
}

# ── the engine/coach boundary, pinned (#154) ────────────────────────
# Stride describes state; it never prescribes. These expects iterate every
# band's label and state id and fail if coaching vocabulary ever reappears —
# the reform that #123/#127 performed, held as an invariant.
expect {
    tsbs = [-25.0, -12.0, -2.0, 8.0, 20.0]
    labels = List.concat(List.map(tsbs, Metrics.form_label), List.map(tsbs, Metrics.form_state))
    List.all(labels, |l| !(Metrics.has_coaching_language(l)))
}

# the predicate itself catches ordinary prescriptive phrasing (mutation-tested
# wording from the review) and passes descriptive state
expect {
    Metrics.has_coaching_language("balanced — ease off today and take a rest day")
    and Metrics.has_coaching_language("you should consider recovery")
    and Metrics.has_coaching_language("fitness building — avoid hard work")
    and !(Metrics.has_coaching_language("high modeled fatigue"))
    and !(Metrics.has_coaching_language("load ramping (23%)"))
    and !(Metrics.has_coaching_language("fitness building"))
}

# form_state is a stable enum: exactly these five ids, snake_case, one per band
expect {
    ids = List.map([-25.0, -12.0, -2.0, 8.0, 20.0], Metrics.form_state)
    ids == ["high_modeled_fatigue", "modeled_fatigue_building", "balanced", "fresh", "very_fresh"]
}
