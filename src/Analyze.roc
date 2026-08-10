import Db
import Output
import Strava
import pf.Sqlite
import pf.Stdout
import pf.Path
import Metrics
import Render
import Streams

Analyze :: [].{

    analyze! : {} => Try({}, _)
    analyze! = |{}| {
        path = Db.open_db!({})?
        match load_zone_config!(path) {
            Err(MissingConfig) => Output.missing_config!({})
            Err(other) => Err(other)
            Ok(zb) => {
                # the denominator is read ONCE up front: this is the number whose absence
                # made a healthy 72s rebuild look hung, and got it killed mid-transaction
                goal = pending_metrics_count!(path, zb)?
                res = converge_metrics!(path, zb, 1000, { computed: 0, stream_errors: 0 }, goal)?
                # close the bar's line before anything else prints, or the next line lands
                # on the same terminal row as the final frame
                _ = if goal > 0 { Output.narrate_done!({})? } else { {} }
                Output.say!("rebuilding daily load…")?
                rebuild_daily_load!(path)?
                form =
                    match Sqlite.query!({
                        path: Path.utf8(path),
                        query: "SELECT tsb AS tsb FROM daily_load ORDER BY day DESC LIMIT 1",
                        bindings: [],
                        row: Sqlite.f64("tsb"),
                    }) {
                        Ok(tsb) => Ok(Some(tsb))
                        # no daily_load yet (nothing computed) is fine — skip the verdict;
                        # a real query error propagates instead of being swallowed
                        Err(NoRowsReturned) => Ok(None)
                        Err(other) => Err(other)
                    }
                tsb_opt = form?
                if Output.json_mode!({}) {
                    form_tsb =
                        match tsb_opt {
                            Some(tsb) => tsb
                            None => 0.0
                        }
                    # `converged` is an ADDITIVE field — existing consumers keep working, so the
                    # envelope version stays. False = fuel ran out; run analyze again to continue.
                    Output.emit_ok!({ computed: res.computed, stream_errors: res.stream_errors, form_tsb, converged: res.converged })
                } else {
                    Stdout.line!("computed metrics for ${U64.to_str(res.computed)} activities")?
                    (if !(res.converged)
                        Stdout.line!("⚠ more activities still pending — run `stride analyze` again to continue")
                    else
                        Ok({}))?
                    (if res.stream_errors > 0
                        Stdout.line!("⚠ ${U64.to_str(res.stream_errors)} had unreadable stream data — computed from summary fields, will retry next sync")
                    else
                        Ok({}))?
                    # one verdict line; the full report lives in `stride summary`
                    match tsb_opt {
                        Some(tsb) => Stdout.line!("→ today: form ${Render.fmt0(tsb)} — ${Metrics.form_label(tsb)}")
                        None => Ok({})

                    }
                }
            }
        }
    }

    # only the HR zones are required config — those are universal across sports. FTP is
    # never configured; it is derived per sport, and for SCORING it is the value in force when
    # the activity happened (ADR 0005). Db.sport_ftp! keeps today's-window semantics for the
    # DISPLAY paths (summary, zones) — the two are deliberately different questions.
    load_zone_config! : Str => Try(Metrics.ZoneBounds, _)
    load_zone_config! = |path| {
        z1 = config_f64!(path, "hr_z1_max")?
        z2 = config_f64!(path, "hr_z2_max")?
        z3 = config_f64!(path, "hr_z3_max")?
        z4 = config_f64!(path, "hr_z4_max")?
        Ok({ z1_max: z1, z2_max: z2, z3_max: z3, z4_max: z4 })
    }
    config_f64! : Str, Str => Try(F64, _)
    config_f64! = |path, key|
        match Db.config_opt!(path, key)? {
            NotFound => Err(MissingConfig)
            Found(s) =>
                match F64.from_str(s) {
                    Ok(v) => Ok(v)
                    Err(_) => Err(MissingConfig)

                }
        }
    ActivityRow : {
        id : I64,
        start : Str,
        mt : I64,
        sport : Str,
        re : [NotNull(F64), Null],
        aw : [NotNull(F64), Null],
        ahr : [NotNull(F64), Null],
        waw : [NotNull(F64), Null],
        rpe : [NotNull(F64), Null],
        raw : [NotNull(Str), Null],
        # the FTP in force WHEN this activity happened (ADR 0005), not today's
        pftp : F64,
        # the same, for pace: the DERIVED threshold speed in force on this activity's date
        # (ADR 0005 as amended). 0 when the sport has no pace history in that window.
        pthr : F64,
        # False = Strava flagged the watts as ESTIMATED (no meter). NULL rows (pre-flag
        # syncs, CSV imports) coalesce to True — unknown is not evidence of estimation.
        dw : Bool,
    }

    # analyze runs compute_missing_metrics! to a FIXED POINT (bounded), not once. A batch can
    # change a sport's DERIVED FTP (its best_20min_w gets populated), which invalidates rows
    # the next pass must rescore; iterate until a pass computes 0 (converged) or fuel runs
    # out. compute_missing_metrics! deliberately selects only 64 rows: account exports can
    # hold millions of samples, so bounded batches avoid retaining the whole history's raw
    # streams in memory. Re-querying also naturally revisits rows whose newly-derived FTP or
    # pace threshold invalidated them.
    # `converged: False` means fuel ran out with work remaining — the caller says so
    # instead of presenting a partial recompute as a finished one.
    converge_metrics! : Str, Metrics.ZoneBounds, U64, { computed : U64, stream_errors : U64 }, U64 => Try({ computed : U64, stream_errors : U64, converged : Bool }, _)
    converge_metrics! = |path, zb, fuel, acc, goal|
        if fuel == 0 {
            Ok({ computed: acc.computed, stream_errors: acc.stream_errors, converged: False })
        } else {
            r = compute_missing_metrics!(path, zb)?
            # accumulate BOTH counters across passes: the final converged pass computes 0
            # rows, so taking only its stream_errors would erase unreadable-stream warnings
            # raised in earlier passes and hide them from the report / JSON.
            total = { computed: acc.computed + r.computed, stream_errors: acc.stream_errors + r.stream_errors }
            # narrate AFTER the batch lands, so the number on screen is work actually done
            # rather than work announced. A run with nothing to score says nothing.
            # ...and a pass that scored NOTHING reports nothing: the final converged pass
            # computes 0 rows, so narrating it would redraw an identical frame (invisible
            # under `\r`, a duplicated line in machine mode). The last frame drawn is
            # already the finished state.
            _ = if goal > 0 and r.computed > 0 { Output.narrate!("rescoring", total.computed, goal)? } else { {} }
            if r.computed == 0 { Ok({ computed: total.computed, stream_errors: total.stream_errors, converged: True }) } else converge_metrics!(path, zb, fuel - 1, total, goal)
        }

    compute_missing_metrics! : Str, Metrics.ZoneBounds => Try({ computed : U64, stream_errors : U64 }, _)
    compute_missing_metrics! = |path, zb| {
        # recompute a row when its stored ftp_used no longer matches the FTP that was in force
        # WHEN IT HAPPENED (ADR 0005 — period_ftp_sql below), or the HR zones / metrics_rev
        # changed. Because the period FTP is anchored to the row's own date, a new personal
        # best no longer invalidates history: only rows whose own 60-day window moved.
        # same story for the DERIVED per-sport threshold pace (speed): recompute a row when
        # its stored threshold_pace_used no longer matches the threshold in force on its own
        # date (period_threshold_sql below) — not against one global current threshold.
        # read config ONCE, then resolve per-sport zones purely (see load_config! note)
        cfg = load_config!(path)?
        zone_sigs = sport_zone_sigs!(path, cfg, zb)?
        zones_case = zones_case_from_sigs(zone_sigs, zb)
        rows = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT a.id AS id, a.start_local AS start, a.moving_time AS mt,
                \\       COALESCE(a.sport_type, '') AS sport,
                \\       CAST(a.relative_effort AS REAL) AS re, CAST(a.avg_watts AS REAL) AS aw, CAST(a.avg_hr AS REAL) AS ahr,
                \\       CAST(a.weighted_avg_watts AS REAL) AS waw, CAST(r.rpe AS REAL) AS rpe, s.raw_json AS raw,
                \\       COALESCE(a.device_watts, 1) AS dw,
                \\       CAST(ROUND(${period_ftp_sql}) AS REAL) AS pftp,
                \\       CAST(ROUND((${period_threshold_sql}) * 1000) AS REAL) / 1000.0 AS pthr
                \\FROM activities a
                \\LEFT JOIN streams s ON s.activity_id = a.id
                \\LEFT JOIN ratings r ON r.activity_id = a.id
                \\LEFT JOIN activity_metrics m ON m.activity_id = a.id
                \\${pending_where(zones_case)}
                \\ORDER BY a.start_local, a.id LIMIT 64
            ,
            bindings: [
                { name: ":rev", value: Integer(metrics_rev) },
            ],
            rows: |cols| |stmt| {
                id = Sqlite.i64("id")(cols)(stmt)?
                start = Sqlite.str("start")(cols)(stmt)?
                mt = Sqlite.i64("mt")(cols)(stmt)?
                sport = Sqlite.str("sport")(cols)(stmt)?
                re = Sqlite.nullable_f64("re")(cols)(stmt)?
                aw = Sqlite.nullable_f64("aw")(cols)(stmt)?
                ahr = Sqlite.nullable_f64("ahr")(cols)(stmt)?
                waw = Sqlite.nullable_f64("waw")(cols)(stmt)?
                rpe = Sqlite.nullable_f64("rpe")(cols)(stmt)?
                raw = Sqlite.nullable_str("raw")(cols)(stmt)?
                pftp = Sqlite.f64("pftp")(cols)(stmt)?
                pthr = Sqlite.f64("pthr")(cols)(stmt)?
                dw = Sqlite.i64("dw")(cols)(stmt)?
                Ok({ id, start, mt, sport, re, aw, ahr, waw, rpe, raw, pftp, pthr, dw: dw != 0 })
            },
        })?
        process_rows!(path, zb, cfg, rows, { computed: 0, stream_errors: 0 })
    }
    process_rows! : Str, Metrics.ZoneBounds, List((Str, Str)), List(ActivityRow), { computed : U64, stream_errors : U64 } => Try({ computed : U64, stream_errors : U64 }, _)
    process_rows! = |path, zb, cfg, rows, acc|
        match rows {
            [] => Ok(acc)
            [row, .. as rest] => {
                failed = compute_one!(path, zb, cfg, row)?
                next = {
                    computed: acc.computed + 1,
                    stream_errors: acc.stream_errors + (if failed 1 else 0),
                }
                process_rows!(path, zb, cfg, rest, next)
            }
        }
    zero_zones : Metrics.ZoneSeconds
    zero_zones = { z1: 0, z2: 0, z3: 0, z4: 0, z5: 0 }

    # a stable signature of the HR zone bounds a metrics row was computed with, so a
    # zone-config change invalidates + recomputes it (the same way ftp_used does for
    # FTP). Bounds are whole bpm, so fmt0 is lossless and deterministic on both the
    # write (compute_one!) and the compare (compute_missing_metrics! query).
    zones_sig : Metrics.ZoneBounds -> Str
    zones_sig = |zb|
        "${Render.fmt0(zb.z1_max)},${Render.fmt0(zb.z2_max)},${Render.fmt0(zb.z3_max)},${Render.fmt0(zb.z4_max)}"
    # The FTP in force WHEN an activity happened (ADR 0005), as a SQL expression correlated
    # to the outer `a`. Same derivation as Db.sport_ftp! — that sport's best 20-min power ×
    # 0.95 — but the 60-day window is anchored to the ACTIVITY's date, not to today.
    #
    # `a2.start_local <= a.start_local` is the load-bearing half: an activity is never scored
    # by fitness the athlete had not yet demonstrated.
    #
    # Cold start: the first 60 days of a sport's history have no trailing window, and scoring
    # them at 0 would silently drop them to the HR rung. The second branch carries the
    # EARLIEST derivable value backwards — approximating unknown early fitness with the
    # earliest fitness actually measured, which is the least-wrong answer available.
    #
    # Used verbatim in BOTH the SELECT (as `pftp`) and the recompute WHERE, so the value a
    # row is scored with is exactly the value the invalidation check compares against.
    #
    # `date(a3.start_local)` on the cold-start branch is load-bearing: start_local is a full
    # ISO timestamp, `date(..., '+60 days')` returns a date-only string, and TEXT comparison
    # is lexical — so "2024-03-10T09:00:00Z" sorts AFTER "2024-03-10" and every activity on
    # the cutoff day would drop out of the window. The trailing branch above is safe without
    # it because its comparison runs the other way (>=), where the longer string still
    # matches. Indexed by idx_activities_sport_start (schema v14).
    period_ftp_sql : Str
    period_ftp_sql =
        \\COALESCE(
        \\  NULLIF((SELECT MAX(m2.best_20min_w) * 0.95
        \\          FROM activity_metrics m2 JOIN activities a2 ON a2.id = m2.activity_id
        \\          WHERE a2.sport_type = a.sport_type
        \\            AND a2.start_local <= a.start_local
        \\            AND a2.start_local >= date(a.start_local, '-60 days')), 0),
        \\  NULLIF((SELECT MAX(m3.best_20min_w) * 0.95
        \\          FROM activity_metrics m3 JOIN activities a3 ON a3.id = m3.activity_id
        \\          WHERE a3.sport_type = a.sport_type
        \\            AND date(a3.start_local) <= date((SELECT MIN(a4.start_local) FROM activities a4
        \\                                              WHERE a4.sport_type = a.sport_type), '+60 days')), 0),
        \\  0)

    # The pace twin of period_ftp_sql (ADR 0005, as amended): the sport's best 20-minute
    # grade-adjusted SPEED over the 60 days ending on THIS activity's date, × 0.95, with the
    # same cold-start forward-fill. It was previously one global number anchored to today,
    # which scored a 2021 run against 2026 fitness and — because the window moved whenever a
    # recent metrics row was deleted — invalidated every activity of that sport at once (#79).
    # Speeds are metres per second, so the ×1000 comparisons downstream are mm/s.
    period_threshold_sql : Str
    period_threshold_sql =
        \\COALESCE(
        \\  NULLIF((SELECT MAX(t2.best_20min_speed) * 0.95
        \\          FROM activity_metrics t2 JOIN activities b2 ON b2.id = t2.activity_id
        \\          WHERE b2.sport_type = a.sport_type
        \\            AND b2.start_local <= a.start_local
        \\            AND b2.start_local >= date(a.start_local, '-60 days')), 0),
        \\  NULLIF((SELECT MAX(t3.best_20min_speed) * 0.95
        \\          FROM activity_metrics t3 JOIN activities b3 ON b3.id = t3.activity_id
        \\          WHERE b3.sport_type = a.sport_type
        \\            AND date(b3.start_local) <= date((SELECT MIN(b4.start_local) FROM activities b4
        \\                                              WHERE b4.sport_type = a.sport_type), '+60 days')), 0),
        \\  0)

    # The "needs rescoring" predicate, shared by the batch SELECT and the COUNT that
    # gives the progress bar its denominator. ONE definition on purpose: two copies of
    # this would drift, and a denominator computed from a different predicate than the
    # work is a bar that lies. Only `a` and `m` are referenced, so a caller needs just
    # those two tables joined.
    pending_where : Str -> Str
    pending_where = |zones_case|
        \\WHERE m.activity_id IS NULL
        \\      OR CAST(COALESCE(m.ftp_used, 0) AS INTEGER) <> CAST(ROUND(${period_ftp_sql}) AS INTEGER)
        \\      OR CAST(ROUND(COALESCE(m.threshold_pace_used, 0) * 1000) AS INTEGER) <> CAST(ROUND((${period_threshold_sql}) * 1000) AS INTEGER)
        \\      OR COALESCE(m.zones_used, '') <> (${zones_case})
        \\      OR COALESCE(m.metrics_rev, 0) <> :rev

    # how many rows the run has left to score. Read ONCE before the passes so the bar has
    # a stable denominator; passes can re-invalidate rows, so the running count may exceed
    # it — Render.progress_bar clamps rather than overfilling.
    pending_metrics_count! : Str, Metrics.ZoneBounds => Try(U64, _)
    pending_metrics_count! = |path, zb| {
        cfg = load_config!(path)?
        zone_sigs = sport_zone_sigs!(path, cfg, zb)?
        zones_case = zones_case_from_sigs(zone_sigs, zb)
        n = Sqlite.query!({
            path: Path.utf8(path),
            query:
                \\SELECT COUNT(*) AS n FROM activities a
                \\LEFT JOIN activity_metrics m ON m.activity_id = a.id
                \\${pending_where(zones_case)}
            ,
            bindings: [{ name: ":rev", value: Integer(metrics_rev) }],
            row: Sqlite.i64("n"),
        })?
        Ok(if n < 0 0 else (n).to_u64_wrap())
    }
    # ── per-sport HR zones ───────────────────────────────────────────────
    # HR zones default to one global set (hr_z*_max) but can be overridden per sport
    # (hr_z*_max_<sport>) — a rowing Z2 ceiling need not equal a running one. The whole
    # config table is read ONCE (query_many cleanly handles 0+ rows) and resolution is
    # then PURE. This deliberately avoids a per-key Sqlite.query! on the many OPTIONAL,
    # usually-ABSENT per-sport keys: that single-row-with-zero-rows path corrupts the heap
    # in this basic-cli/compiler combo when hit repeatedly (deterministic SIGABRT in
    # hosted_sqlite_prepare — see PLAN.md). (The four REQUIRED global hr_z*_max keys are
    # still read via Db.config_opt! in load_zone_config!, but they're normally present, so
    # that zero-row path isn't exercised there.) Each sport's zone SIGNATURE is frozen for
    # the invalidation CASE; per-row scoring re-resolves bounds from the same in-memory
    # config. No circular dependency like FTP has.
    load_config! : Str => Try(List((Str, Str)), _)
    load_config! = |path|
        Sqlite.query_many!({
            path: Path.utf8(path),
            query: "SELECT key AS k, COALESCE(value, '') AS v FROM config",
            bindings: [],
            rows: |cols| |stmt| {
                k = Sqlite.str("k")(cols)(stmt)?
                v = Sqlite.str("v")(cols)(stmt)?
                Ok((k, v))
            },
        })
    # pure: a config value parsed as F64, or the fallback when absent/unparseable.
    # Recursive so it stops at the first match (config also holds tokens/sync markers).
    cfg_f64 : List((Str, Str)), Str, F64 -> F64
    cfg_f64 = |cfg, key, fallback|
        match cfg {
            [] => fallback
            [pair, .. as rest] =>
                if pair.0 == key
                    match F64.from_str(pair.1) {
                        Ok(v) => v
                        Err(_) => fallback
                    }
                else
                    cfg_f64(rest, key, fallback)
        }
    # pure: one sport's zone ceilings (per-sport keys, global fallback). An empty sport
    # (NULL/'' sport_type, selected as COALESCE(...,'')) resolves to the GLOBAL set only:
    # sport_zone_sigs! excludes empty sports from the invalidation CASE (WHERE sport_type
    # <> ''), so an empty-suffix hr_z*_max_ key must NOT change these rows' signature, or
    # they'd differ from the CASE's ELSE (global) and recompute every run.
    resolve_zones_pure : List((Str, Str)), Str, Metrics.ZoneBounds -> Metrics.ZoneBounds
    resolve_zones_pure = |cfg, sport, g|
        if Str.is_empty(sport)
            g
        else
            {
                z1_max: cfg_f64(cfg, Metrics.hr_zone_key(1, sport), g.z1_max),
                z2_max: cfg_f64(cfg, Metrics.hr_zone_key(2, sport), g.z2_max),
                z3_max: cfg_f64(cfg, Metrics.hr_zone_key(3, sport), g.z3_max),
                z4_max: cfg_f64(cfg, Metrics.hr_zone_key(4, sport), g.z4_max),
            }
    # each distinct sport's frozen (sport, zone-signature) pair for the invalidation CASE
    sport_zone_sigs! : Str, List((Str, Str)), Metrics.ZoneBounds => Try(List((Str, Str)), _)
    sport_zone_sigs! = |path, cfg, g| {
        sports = Sqlite.query_many!({
            path: Path.utf8(path),
            query: "SELECT DISTINCT sport_type AS s FROM activities WHERE sport_type IS NOT NULL AND sport_type <> ''",
            bindings: [],
            rows: Sqlite.str("s"),
        })?
        Ok(List.map(sports, |s| (s, zones_sig(resolve_zones_pure(cfg, s, g)))))
    }
    # pure: `CASE a.sport_type WHEN '<sport>' THEN '<sig>' … ELSE '<global_sig>' END`, the
    # zones analog of ftp_case_from_map, built from the frozen (sport, sig) list. Each row's
    # stored zones_used is compared to ITS sport's signature, so a per-sport zone edit
    # invalidates only that sport's rows.
    zones_case_from_sigs : List((Str, Str)), Metrics.ZoneBounds -> Str
    zones_case_from_sigs = |sigs, g| {
        whens = List.fold(sigs, "", |acc, pair| {
            esc = Str.replace_each(pair.0, "'", "''")
            "${acc} WHEN '${esc}' THEN '${pair.1}'"
        })
        "CASE a.sport_type${whens} ELSE '${zones_sig(g)}' END"
    }
    # returns Bool: did the stored stream JSON fail to decode? (surfaced by analyze)
    # (#69 briefly split this into a dispatcher over a wire format; its only producer —
    # the Python export decoder — was reverted in #70, so every stored stream is JSON.)
    compute_one! : Str, Metrics.ZoneBounds, List((Str, Str)), ActivityRow => Try(Bool, _)
    compute_one! = |path, zb, cfg, row| {
        decoded = Streams.decode_streams(row.raw)
        streams = decoded.streams
        # this sport's zone bounds: per-sport override or global, resolved purely from
        # the in-memory config (no per-key DB hit — that path corrupts the heap here)
        row_zb = resolve_zones_pure(cfg, row.sport, zb)

        # sanity-filter HR: some sources (Peloton strength workouts) emit junk
        # near-zero samples — Metrics.valid_hr is the one place the bounds live
        hr_pairs = List.keep_if(
            Streams.stream_pairs(streams.time, streams.heartrate),
            |p| Metrics.valid_hr(p.v),
        )
        # drop non-physiological power samples (sensor glitches) the same way HR is
        # filtered — one 1s spike would inflate NP and the 20-min best behind FTP.
        # Estimated watts (#73): device_watts=False means the whole stream is Strava's
        # model output, not a measurement — it must not feed NP, the 20-min best behind
        # DERIVED FTP, the power curve, or the intensity split. Drop it wholesale.
        watts_pairs =
            if row.dw
                List.keep_if(
                    Streams.stream_pairs(streams.time, streams.watts),
                    |p| Metrics.valid_watts(p.v),
                )
            else
                []
        # held pairs: NP wants values, the bests need real seconds to reject pause-spanning windows
        watts_1s_pairs = Metrics.resample_1s_pairs(watts_pairs, Hold)
        watts_1s = List.map(watts_1s_pairs, |p| p.v)

        zones = if List.is_empty(hr_pairs) zero_zones else Metrics.time_in_zones(hr_pairs, row_zb)

        np_stream = Metrics.normalized_power(watts_1s)
        best20 = Metrics.best_rolling_mean_1s(watts_1s_pairs, 1200)

        # power-duration curve: best mean-max power at each ladder duration (5s..60min minus
        # the 20-min point, which best_20min_w already carries). Stored per activity; the
        # `power-curve` command takes MAX per duration across a window to draw the CP curve.
        # 0 = not available (ride shorter than the window) per the numeric-0 invariant. Derive
        # the stored ladder from the shared constant (drop 1200 — it lives in best_20min_w) so
        # the columns and the curve command never drift.
        curve_durations = List.keep_if(Metrics.power_curve_durations, |d| d != 1200)
        curve = Metrics.mean_max_curve(watts_1s_pairs, curve_durations)
        cw = |i|
            match List.get(curve, i) {
                Ok(c) => Real(c.watts)
                Err(_) => Real(0.0)
            }

        # grade-adjusted pace: align time+dist(+alt) into a triple, resample to 1 Hz, grade-adjust
        # ONCE. The NGP speed scores the pace rung (when the sport has a threshold); the best
        # 20-min speed feeds the DERIVED per-sport threshold (CSS for swim). With an altitude
        # stream (outdoor run/trail) we grade-adjust; WITHOUT one (swim, indoor row/ride) we use a
        # flat triple so raw speed still scores — pace works for any dist sport, not just graded
        # ones. No dist stream at all → empty → pace falls through to HR, like a no-power sport on FTP.
        # try the graded triple first; fall back to the flat time+dist path when it's empty —
        # which covers BOTH no altitude stream AND an altitude stream that's all null sentinels
        # (every graded sample dropped) but whose time+distance are still usable. A partially
        # usable altitude yields a non-empty graded triple and wins.
        graded_triple = Streams.dist_alt_time(streams.time, streams.distance, streams.altitude)
        pace_triple =
            if List.is_empty(graded_triple.time)
                Streams.dist_time(streams.time, streams.distance)
            else
                graded_triple
        gas_1s_pairs = Metrics.graded_speed_1s(pace_triple.time, pace_triple.dist, pace_triple.alt)
        gas_speeds = List.map(gas_1s_pairs, |p| p.v)
        ngp_speed = Metrics.normalized_power(gas_speeds)
        best20_speed = Metrics.best_rolling_mean_1s(gas_1s_pairs, 1200)
        # ADR 0005 as amended: the threshold in force on THIS activity's date, carried on the
        # row by the SELECT — not one global current threshold applied to all of history.
        threshold_speed = row.pthr
        ngp_for_ladder =
            match ngp_speed {
                Ok(v) => Ok(v)
                Err(_) => Err(Missing)
            }

        # intensity split, judged against the sport's own threshold. Stored into pi_* so the
        # weekly polarization and the activities "hard" column read a real split for every scored
        # sport. Power sports use FTP; pace sports (no power, but a threshold speed) use the pace
        # split on the same 1 Hz graded-speed stream — so runs/swims get a hard/easy breakdown too,
        # not just an HR fallback. The FROZEN per-sport FTP/threshold keep it order-independent.
        # ADR 0005: the FTP in force when this activity happened, carried on the row by the
        # SELECT, not looked up from a single current-FTP map.
        pi_ftp = row.pftp
        # power sports use the power split — even mid-derivation, when pi_ftp is still 0 (the split
        # is then all-zero, and corrects once FTP derives on the next pass). ONLY power-LESS
        # activities fall to the pace split. Gate on actual power samples, not pi_ftp, so a power
        # ride on the first analyze pass isn't mislabeled by pace.
        pintensity =
            if !(List.is_empty(watts_pairs))
                Metrics.time_in_power_intensity(watts_pairs, pi_ftp)
            else
                Metrics.time_in_pace_intensity(gas_1s_pairs, threshold_speed)

        # the fallback chain lives in Metrics.tss_ladder (pure, expect-tested)
        nn = |x|
            match x {
                NotNull(v) => Ok(v)
                Null => Err(Missing)

            }
        ladder = Metrics.tss_ladder({
            np_stream,
            weighted_watts: nn(row.waw),
            avg_watts: nn(row.aw),
            avg_hr: nn(row.ahr),
            relative_effort: nn(row.re),
            rpe: nn(row.rpe),
            sport_type: row.sport,
            zones,
            zb: row_zb,
            ftp: pi_ftp, # the SPORT's FTP, not cycling's — so rowing/running load is scaled right
            # pace rung: NGP speed vs the sport's DERIVED threshold speed. Both 0/absent for a
            # sport with no dist+alt streams, so the pace candidate simply doesn't fire and the
            # ladder falls through to HR — same shape as a no-power sport on the power rung.
            ngp: ngp_for_ladder,
            threshold_speed,
            device_watts: row.dw,
            dur_s: (row.mt).to_f64(),
            moving_time: row.mt,
        })
        tss = ladder.tss

        np_binding =
            match ladder.np {
                Ok(npv) => Real(npv)
                Err(_) => Null

            }
        if_binding =
            match ladder.np {
                Ok(npv) => (if pi_ftp > 0.0 Real(npv / pi_ftp) else Null)
                Err(_) => Null

            }
        best20_binding =
            match best20 {
                Ok(b) => Real(b)
                Err(_) => Null

            }
        best20_speed_binding =
            match best20_speed {
                Ok(b) => Real(b)
                Err(_) => Null

            }
        Sqlite.execute!({
            path: Path.utf8(path),
            query:
                \\INSERT OR REPLACE INTO activity_metrics
                \\  (activity_id, tss, normalized_power, intensity_factor, z1_s, z2_s, z3_s, z4_s, z5_s, computed_at, best_20min_w, ftp_used, zones_used, metrics_rev, load_model, pi_easy_s, pi_moderate_s, pi_hard_s, best_5s_w, best_15s_w, best_30s_w, best_60s_w, best_300s_w, best_600s_w, best_3600s_w, best_20min_speed, threshold_pace_used)
                \\VALUES (:id, :tss, :np, :if, :z1, :z2, :z3, :z4, :z5, :at, :b20, :ftpu, :zused, :rev, :model, :pie, :pim, :pih, :bc5, :bc15, :bc30, :bc60, :bc300, :bc600, :bc3600, :b20s, :thru)
            ,
            bindings: [
                { name: ":pie", value: Integer(pintensity.easy_s) },
                { name: ":pim", value: Integer(pintensity.moderate_s) },
                { name: ":pih", value: Integer(pintensity.hard_s) },
                { name: ":ftpu", value: Real(pi_ftp) },
                { name: ":zused", value: String(zones_sig(row_zb)) },
                { name: ":rev", value: Integer(metrics_rev) },
                { name: ":model", value: String(ladder.model) },
                { name: ":id", value: Integer(row.id) },
                { name: ":tss", value: Real(tss) },
                { name: ":np", value: np_binding },
                { name: ":if", value: if_binding },
                { name: ":z1", value: Integer(zones.z1) },
                { name: ":z2", value: Integer(zones.z2) },
                { name: ":z3", value: Integer(zones.z3) },
                { name: ":z4", value: Integer(zones.z4) },
                { name: ":z5", value: Integer(zones.z5) },
                { name: ":at", value: String(Metrics.epoch_to_iso(Db.now_secs!({}))) },
                { name: ":b20", value: best20_binding },
                { name: ":bc5", value: cw(0) },
                { name: ":bc15", value: cw(1) },
                { name: ":bc30", value: cw(2) },
                { name: ":bc60", value: cw(3) },
                { name: ":bc300", value: cw(4) },
                { name: ":bc600", value: cw(5) },
                { name: ":bc3600", value: cw(6) },
                { name: ":b20s", value: best20_speed_binding },
                # store the threshold the row was scored against — the pace twin of ftp_used,
                # so a later threshold change invalidates via the recompute WHERE
                { name: ":thru", value: Real(threshold_speed) },
            ],
        })?
        Ok(decoded.failed)
    }
    # ── daily load (CTL/ATL/TSB) ────────────────────────────────────────

    rebuild_daily_load! : Str => Try({}, _)
    rebuild_daily_load! = |path| {
        day_rows = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT substr(a.start_local, 1, 10) AS day, SUM(m.tss) AS t
                \\FROM activity_metrics m
                \\JOIN activities a ON a.id = m.activity_id
                \\GROUP BY day ORDER BY day
            ,
            bindings: [],
            rows: |cols| |stmt| {
                day = Sqlite.str("day")(cols)(stmt)?
                t = Sqlite.f64("t")(cols)(stmt)?
                Ok({ day, t })
            },
        })?
        # keep only rows whose date parses. Deriving the walk bounds from these VALID
        # days (not blindly from the first/last row) avoids the trap where a single
        # malformed start_local defaulted to epoch-day 0 and walked from 1970.
        by_day = List.fold(
            day_rows,
            Dict.empty(),
            |dict, r|
                match Metrics.date_str_to_days(r.day) {
                    Ok(d) => Dict.insert(dict, d, r.t)
                    Err(_) => dict,
                }
        )
        valid_days = Dict.keys(by_day)
        match List.first(valid_days) {
            Err(_) => Ok({}) # nothing computed yet (or no parseable dates)
            Ok(seed) => {
                bounds = List.fold(valid_days, { lo: seed, hi: seed }, |b, d| { lo: (b.lo).min(d), hi: (b.hi).max(d) })
                # extend through today so rest days decay ATL/CTL and TSB is true as-of-now
                today = Db.local_today_days!(path)
                last_day = (bounds.hi).max(today)
                # atomic rebuild: DELETE + the whole day-walk run in ONE transaction. A crash
                # mid-walk would otherwise leave daily_load truncated (missing the tail day) and
                # the next `summary` would read it as valid → silently stale CTL/ATL/TSB. On any
                # error we ROLLBACK and surface it rather than commit a partial series.
                _ = Sqlite.execute!({ path: Path.utf8(path), query: "BEGIN", bindings: [] })?
                match rebuild_txn!(path, by_day, bounds.lo, last_day) {
                    Ok(_) => Sqlite.execute!({ path: Path.utf8(path), query: "COMMIT", bindings: [] })
                    Err(e) =>
                        # roll back the partial rebuild. If the ROLLBACK itself fails (lock,
                        # corruption) that's the more actionable signal — surface it; otherwise
                        # return the original error that aborted the rebuild.
                        match Sqlite.execute!({ path: Path.utf8(path), query: "ROLLBACK", bindings: [] }) {
                            Ok(_) => Err(e)
                            Err(re) => Err(re)
                        }
                }
            }
        }
    }
    rebuild_txn! : Str, Dict(I64, F64), I64, I64 => Try({}, _)
    rebuild_txn! = |path, by_day, lo, last_day| {
        Sqlite.execute!({ path: Path.utf8(path), query: "DELETE FROM daily_load", bindings: [] })?
        walk_days!(path, by_day, lo, last_day, 0.0, 0.0)
    }
    walk_days! : Str, Dict(I64, F64), I64, I64, F64, F64 => Try({}, _)
    walk_days! = |path, by_day, day, last_day, ctl_prev, atl_prev|
        if day > last_day
            Ok({})
        else {
            tss = (Dict.get(by_day, day)).ok_or(0.0)
            # the CTL/ATL/TSB recurrence lives in Metrics.load_step (pure, expect-tested)
            step = Metrics.load_step({ ctl_prev, atl_prev, tss })
            Sqlite.execute!({
                path: Path.utf8(path),
                query: "INSERT OR REPLACE INTO daily_load (day, tss, ctl, atl, tsb) VALUES (:day, :tss, :ctl, :atl, :tsb)",
                bindings: [
                    { name: ":day", value: String(Metrics.days_to_date_str(day)) },
                    { name: ":tss", value: Real(tss) },
                    { name: ":ctl", value: Real(step.ctl) },
                    { name: ":atl", value: Real(step.atl) },
                    { name: ":tsb", value: Real(step.tsb) },
                ],
            })?
            walk_days!(path, by_day, day + 1, last_day, step.ctl, step.atl)
        }

    # bump when the metric MATH changes (tss ladder, zone attribution, NP windowing,
    # HR validity bounds, ...) so existing rows recompute — config inputs (ftp_used,
    # zones_used) can't catch algorithm changes
    metrics_rev = 23
}
