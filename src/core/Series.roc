# stride-core: the 1 Hz stream discipline, shared by both binaries.
#
# Strava streams are (elapsed_second, value) samples with gaps. Everything
# downstream - the engine's power/pace math, the window's trace channels -
# wants an honest 1 Hz series: gaps up to max_fill_gap bridged, longer gaps
# treated as pauses and never filled. One implementation, because two copies
# of a resampler is how one surface stitches across a pause the other refuses.
Series :: [].{
    max_fill_gap : I64
    max_fill_gap = 10

    # Resample to 1 Hz, returning (elapsed_second, value) pairs. ONE implementation for both
    # kinds of stream; the mode picks how a fillable gap is bridged:
    #
    #   Hold        - repeat the previous value. Correct for an INSTANTANEOUS signal
    #                 (watts, HR): you measured 200 W, you know nothing newer.
    #   Interpolate - walk linearly to the next value. Required for a CUMULATIVE signal
    #                 (distance): holding it flat and then differencing turns a 5-second
    #                 recording interval into four 0 m/s samples and one 20 m/s spike.
    #
    # Gaps longer than max_fill_gap are pauses and are never filled. Every pair carries its
    # REAL elapsed second, so a consumer can tell a genuine 1 Hz run from one that jumped -
    # which is what keeps a rolling window from stitching across a pause.
    resample_1s_pairs : List({ t : I64, v : F64 }), [Hold, Interpolate] -> List({ t : I64, v : F64 })
    resample_1s_pairs = |samples, mode|
        # The fold below assumes ascending timestamps: an out-of-order sample dropped
        # WITHOUT advancing the anchor lets one spuriously large timestamp swallow
        # every sample after it until the stream catches up. Ordering is enforced
        # by sorted_by_t, which sorts only when a stream actually needs it.
        List.fold(
            sorted_by_t(samples),
            { out: [], prev_t: 0.I64, prev_v: 0.0.F64, started: False },
            |acc, s| resample_step(acc, s, mode),
        ).out

    # Ascending order is the ONLY thing the resample fold needs, and Strava streams
    # already arrive that way - so check before sorting. Not a micro-optimization: on
    # already-ascending input List.sort_with hits its O(n^2) worst case, the only shape
    # real streams have. One pass carrying the previous timestamp - indexing
    # back per element is the same quadratic shape. Equal timestamps count as
    # ascending: the fold treats them as duplicates.
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

    # ascending already? hand the list back untouched. Otherwise sort - the protection
    # against a stray timestamp is preserved for the streams that genuinely need it.
    sorted_by_t : List({ t : I64, v : F64 }) -> List({ t : I64, v : F64 })
    sorted_by_t = |samples|
        if ascending_by_t(samples) samples else List.sort_with(samples, |a, b| a.t.order_relative_to(b.t))

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
            # pause - resume without filling; the real timestamp is preserved either way
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
        Iter.fold((
            1.U64..<(gap).to_u64_wrap()).iter(),
            out,
            |o, k| List.append(o, { t: prev_t + (k).to_i64_wrap(), v: prev_v + step * (k).to_f64() }),
        )
    }

    # values only, forward-held - the long-standing shape the NP path consumes
    resample_1s : List({ t : I64, v : F64 }) -> List(F64)
    resample_1s = |samples| List.map(resample_1s_pairs(samples, Hold), |p| p.v)

    # Resample a CONTINUOUS stream (distance, altitude) to 1 Hz by LINEAR INTERPOLATION,
    # returning (elapsed_second, value) pairs.
    #
    # `resample_1s` forward-HOLDS, which is correct for an instantaneous signal (watts, HR)
    # and WRONG for a cumulative one. Holding distance flat and then differencing it turns a
    # 5-second recording interval into four 0 m/s samples and one 20 m/s spike - five times
    # the true speed - which normalized_power then raises to the 4th power.
    #
    # Pauses (gap > max_fill_gap) are still not filled, but every pair carries its REAL
    # elapsed second, so a consumer that divides by dt sees the true interval instead of
    # collapsing a 60-second dropout into a single 1-second step.
    resample_1s_linear : List({ t : I64, v : F64 }) -> List({ t : I64, v : F64 })
    resample_1s_linear = |samples| resample_1s_pairs(samples, Interpolate)

    # Per-second SPEED from a cumulative distance stream: adjacent resampled
    # pairs differenced over their real dt. A pair spanning more than
    # max_fill_gap is a pause and emits nothing - the same refusal to invent
    # motion the resampler itself makes - and a negative difference (GPS
    # jitter walking the odometer backwards) clamps to zero rather than
    # asserting the athlete ran in reverse.
    speed_1s : List({ t : I64, v : F64 }) -> List({ t : I64, v : F64 })
    speed_1s = |dist_pairs| {
        d1 = resample_1s_linear(dist_pairs)
        List.keep_oks(List.map2(d1, List.drop_first(d1, 1), |a, b| { a, b }), |x| {
            dt = x.b.t - x.a.t
            if dt >= 1 and dt <= max_fill_gap {
                raw = (x.b.v - x.a.v) / (dt).to_f64()
                Ok({ t: x.b.t, v: if raw < 0.0 (0.0) else raw })
            } else {
                Err(Pause)
            }
        })
    }

    # ── splits ──────────────────────────────────────────────────────────
    # Distance splits from the cumulative-distance stream: one row per
    # split_m metres, plus a partial tail when meaningful. Everything SI -
    # the caller picks the split length (1000 for a metric athlete, the
    # international mile for an imperial one) and the renderer converts at
    # the last moment, per the units contract.
    #
    # elapsed_s is WALL seconds between boundary crossings: a stop inside a
    # split belongs to that split's story, the way a runner reads a slow
    # mile. Boundaries land on the 1 Hz resampled sample that crosses the
    # line - between adjacent samples that overshoots split_m by at most
    # one second of travel. Across an unfillable recording pause (the
    # resampler leaves gaps longer than max_fill_gap unfilled) one sample
    # can land several split lengths past the line; the row then spans
    # them all, because the stream holds no evidence of where inside the
    # dropout each line was crossed, and n advances by the whole split
    # lengths the row covered so later rows keep their distance position.
    # A tail under 2% of split_m is boundary noise and is dropped - its
    # wall seconds then belong to no row, so summing elapsed_s can come up
    # short of the activity's own elapsed time.
    #
    # elev_gain_m sums only positive altitude deltas between samples at
    # most max_fill_gap apart - after interpolation that means adjacent
    # seconds the resampler vouched for, since any longer adjacency is a
    # gap it refused to fill. A rise across an unfilled gap is a sensor
    # dropout or an ascent made while paused, and crediting it would
    # assert a climb the stream disclaims; the engine's zone machinery can
    # afford its looser sample-gap bound because it caps the SECONDS it
    # credits, while gain books the full magnitude, so the gate is the
    # resampler's own.
    # elev_known is false when no altitude stream exists at all, and the
    # zeros then are absence, not flat ground. avg_hr is the plain mean of
    # the valid samples inside the span - readings, not seconds, unlike
    # the dt-weighted zone machinery - and hr_known follows the count, the
    # same ambiguous-zero discipline every other absent measurement gets.
    Split : { n : I64, distance_m : F64, elapsed_s : I64, elev_gain_m : F64, elev_known : Bool, avg_hr : F64, hr_known : Bool }

    # how many whole split lengths fit in d, by exact subtraction - a
    # crossing guarantees d >= s, and the count per crossing stays small
    whole_splits : F64, F64, I64 -> I64
    whole_splits = |d, s, k| if d >= s whole_splits(d - s, s, k + 1) else k

    splits : List({ t : I64, v : F64 }), List({ t : I64, v : F64 }), List({ t : I64, v : F64 }), F64 -> List(Split)
    splits = |dist_pairs, alt_pairs, hr_pairs, split_m| {
        d1 = resample_1s_linear(sorted_by_t(dist_pairs))
        if List.is_empty(d1) or split_m <= 0.0 {
            []
        } else {
            alt_1s = resample_1s_linear(sorted_by_t(alt_pairs))
            has_alt = !(List.is_empty(alt_1s))
            row_for = |n, start_t, start_d, end_t, end_d| {
                gain = List.fold(List.map2(alt_1s, List.drop_first(alt_1s, 1), |a, b| { a, b }), 0.0.F64, |acc, x|
                    if x.b.t > start_t and x.b.t <= end_t and x.b.t - x.a.t <= max_fill_gap and x.b.v > x.a.v (acc + (x.b.v - x.a.v)) else acc)
                in_span = List.keep_if(hr_pairs, |p| p.t > start_t and p.t <= end_t)
                n_hr = List.len(in_span)
                mean_hr = if n_hr == 0 0.0 else List.fold(in_span, 0.0.F64, |acc, p| acc + p.v) / (n_hr).to_f64()
                { n, distance_m: end_d - start_d, elapsed_s: end_t - start_t, elev_gain_m: gain, elev_known: has_alt, avg_hr: mean_hr, hr_known: n_hr > 0 }
            }
            first_t = (List.first(d1)).map_ok(|p| p.t).ok_or(0.I64)
            first_d = (List.first(d1)).map_ok(|p| p.v).ok_or(0.0.F64)
            walked = List.fold(d1, { rows: [], n: 1.I64, start_t: first_t, start_d: first_d }, |acc, p|
                if p.v - acc.start_d >= split_m {
                    { rows: List.append(acc.rows, row_for(acc.n, acc.start_t, acc.start_d, p.t, p.v)), n: acc.n + whole_splits(p.v - acc.start_d, split_m, 0), start_t: p.t, start_d: p.v }
                } else {
                    acc
                })
            last_t = (List.last(d1)).map_ok(|p| p.t).ok_or(0.I64)
            last_d = (List.last(d1)).map_ok(|p| p.v).ok_or(0.0.F64)
            # a tail under 2% of a split is boundary noise, not a partial split
            if last_d - walked.start_d > split_m * 0.02 {
                List.append(walked.rows, row_for(walked.n, walked.start_t, walked.start_d, last_t, last_d))
            } else {
                walked.rows
            }
        }
    }

    expect resample_1s([{ t: 0.I64, v: 100.0 }, { t: 3.I64, v: 130.0 }]) == [100.0, 100.0, 100.0, 130.0]
    expect resample_1s_linear([{ t: 0.I64, v: 0.0 }, { t: 4.I64, v: 8.0 }]) == [{ t: 0.I64, v: 0.0 }, { t: 1.I64, v: 2.0 }, { t: 2.I64, v: 4.0 }, { t: 3.I64, v: 6.0 }, { t: 4.I64, v: 8.0 }]
    # a pause is not filled: the gap stays a gap in the pairs
    expect List.len(resample_1s_linear([{ t: 0.I64, v: 0.0 }, { t: 30.I64, v: 60.0 }])) == 2

    expect speed_1s([{ t: 0.I64, v: 0.0 }, { t: 4.I64, v: 8.0 }]) == [{ t: 1.I64, v: 2.0 }, { t: 2.I64, v: 2.0 }, { t: 3.I64, v: 2.0 }, { t: 4.I64, v: 2.0 }]
    # across a pause no speed is emitted - motion during a 30 s hole is unknowable
    expect speed_1s([{ t: 0.I64, v: 0.0 }, { t: 1.I64, v: 3.0 }, { t: 31.I64, v: 100.0 }]) == [{ t: 1.I64, v: 3.0 }]
    # a backwards odometer clamps to zero, not negative speed
    expect speed_1s([{ t: 0.I64, v: 10.0 }, { t: 1.I64, v: 8.0 }]) == [{ t: 1.I64, v: 0.0 }]
    expect sorted_by_t([{ t: 5.I64, v: 1.0 }, { t: 2.I64, v: 2.0 }]) == [{ t: 2.I64, v: 2.0 }, { t: 5.I64, v: 1.0 }]
    expect ascending_by_t([{ t: 1.I64, v: 0.0 }, { t: 1.I64, v: 0.0 }, { t: 2.I64, v: 0.0 }])
}
