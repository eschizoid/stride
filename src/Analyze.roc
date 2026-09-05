import Db
import Output
import Strava
import pf.Sqlite
import pf.Stdout
import pf.Path
import Metrics
import Sports
import Render
import Streams

Analyze :: [].{

    analyze! : {} => Try({}, _)
    analyze! = |{}| {
        path = Db.open_db!({})?
        match load_zone_config!(path) {
            Err(MissingConfig) => Output.missing_config!({})
            Err(UnreadableConfig(key, raw)) => Output.unreadable_config!(key, raw)
            Err(other) => Err(other)
            Ok(zb) => {
                # ...and this line comes BEFORE the count, because the count is itself a
                # slow query: it runs the period-FTP and period-threshold correlated
                # subqueries over every activity. Narrating only after it returns leaves
                # the very first moment of the command silent, which is where "it looks
                # hung" starts.
                Output.say!("checking what needs scoring…")?
                # the denominator is read ONCE up front: this is the number whose absence
                # made a healthy 72s rebuild look hung, and got it killed mid-transaction
                goal = pending_metrics_count!(path, zb)?
                # Close the bar's line before anything else prints, or the next line lands
                # on the same terminal row as the final frame. The result is CAPTURED and
                # the close runs before it is unwrapped, so an error propagating out of the
                # passes closes the line too — otherwise the error message itself would be
                # the thing printed on top of a half-drawn frame.
                # same reasoning as the stream backfill: the FIRST batch is the slowest
                # (cold streams, 64 rows) and narrating only on its completion leaves the
                # command silent through the longest single wait of the run
                _ = if goal > 0 { Output.narrate!("rescoring", 0, goal)? } else { {} }
                passes = converge_metrics!(path, zb, 1000, { computed: 0, stream_errors: 0 }, goal)
                _ = if goal > 0 { Output.narrate_done!({})? } else { {} }
                res = passes?
                Output.say!("rebuilding daily load…")?
                rebuild_daily_load!(path)?
                # The last 10 days, not just today: the verdict now carries the weekly
                # delta (#111), which needs the value 7 days back. query_many rather than
                # query! because an empty daily_load is a normal state (nothing analyzed
                # yet), and the empty list says so without an error to translate.
                form_rows = Sqlite.query_many!({
                    path: Path.utf8(path),
                    query: "SELECT COALESCE(CAST(day AS TEXT), '') AS day, CAST(tsb AS REAL) AS tsb FROM daily_load ORDER BY day DESC LIMIT 10",
                    bindings: [],
                    rows: |cols| |stmt| {
                        day = Sqlite.str("day")(cols)(stmt)?
                        tsb = Sqlite.f64("tsb")(cols)(stmt)?
                        Ok({ day, tsb })
                    },
                })?
                # ORDER BY day DESC, so the head is today
                tsb_opt =
                    match List.first(form_rows) {
                        Ok(latest) => Some(latest)
                        Err(_) => None
                    }
                # DROP rows whose day will not parse rather than mapping them to epoch day
                # 0. Day 0 is a perfectly valid day number, so a collapsed row becomes a
                # legitimate-looking candidate for the 7-days-back lookup: on a young
                # database that turns "no history to compare" into a confident
                # `up 34 from a week ago`, certified by form_delta_known: true. Dropping
                # leaves a genuine gap, and a gap is what form_delta_7d reports honestly.
                dated_form_rows = List.keep_oks(form_rows, |r|
                    match Metrics.date_str_to_days(r.day) {
                        Ok(day) => Ok({ day, tsb: r.tsb })
                        Err(_) => Err({})
                    })
                form_delta =
                    match tsb_opt {
                        None => Unknown
                        Some(latest) =>
                            match Metrics.date_str_to_days(latest.day) {
                                # an unparseable anchor is not an anchor — no comparison is
                                # possible, and Unknown is the honest report
                                Err(_) => Unknown
                                Ok(anchor) => Metrics.form_delta_7d(dated_form_rows, anchor)
                            }
                    }
                # ANNOTATED Bool, not a bare `True`/`False` tag. The builtin JSON serializes
                # an unconstrained tag as the STRING "True", and nothing here constrains it:
                # this payload is ENCODE-ONLY. summary's identical expression is fine only
                # because its payload is also RENDERED, and `Render.summary_screen` consumes
                # the field as an `if` condition, which flows Bool back through the
                # un-annotated renderer. Neighbouring Bool fields are irrelevant — record
                # fields do not constrain each other, and `converged: Bool` sits two lines
                # below this one while the bug shipped anyway.
                delta_known : Bool
                delta_known = match form_delta { Known(_) => True  Unknown => False }
                # form_tsb needs the same treatment as form_delta_7d: 0.0 TSB is a real and
                # common value meaning "balanced", so an empty daily_load flattening to 0.0
                # tells a machine consumer that form is balanced when the truth is that
                # there is no form yet. The human branch already gets this right by printing
                # nothing; this makes the JSON agree with it.
                tsb_known : Bool
                tsb_known = match tsb_opt { Some(_) => True  None => False }
                if Output.json_mode!({}) {
                    form_tsb =
                        match tsb_opt {
                            Some(latest) => latest.tsb
                            None => 0.0
                        }
                    # `converged` is an ADDITIVE field — existing consumers keep working, so the
                    # envelope version stays. False = fuel ran out; run analyze again to continue.
                    # form_delta_7d/known and form_tsb_known are additive on the same grounds;
                    # each flag exists because its number has a legitimate value (0.0) that
                    # collides with "not available".
                    Output.emit_ok!({
                        computed: res.computed,
                        stream_errors: res.stream_errors,
                        form_tsb,
                        # stable band id (#154); "" when TSB itself is unknown — an id
                        # derived from a placeholder 0.0 would claim a band nobody measured
                        form_state: if tsb_known Metrics.form_state(form_tsb) else "",
                        form_delta_7d: match form_delta { Known(d) => d  Unknown => 0.0 },
                        form_delta_known: delta_known,
                        form_tsb_known: tsb_known,
                        converged: res.converged,
                    })
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
                        Some(latest) =>
                            Stdout.line!("→ today: form ${Render.fmt0(latest.tsb)}${Render.form_trend_phrase(form_delta)} — ${Metrics.form_label(latest.tsb)}")

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
    # ABSENT and UNREADABLE are different faults and get different errors. Reporting an
    # unreadable value as MissingConfig told the athlete to set a key that `config get`
    # was already echoing back at them -- the trap Config.is_derived's comment names,
    # arrived at from the other side (#206).
    config_f64! : Str, Str => Try(F64, _)
    config_f64! = |path, key|
        match Db.config_opt!(path, key)? {
            NotFound => Err(MissingConfig)
            Found(s) =>
                match Metrics.arg_f64(s) {
                    Ok(v) => Ok(v)
                    Err(_) => Err(UnreadableConfig(key, s))

                }
        }
    # canonical AND parseable. Both halves, for the reason spelled out at the fold above:
    # the parse alone accepts "2026-3-05T", and this module WRITES the result.


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
        # the activity inputs this row was selected with, stored on the metrics row so the
        # next analyze can tell value-by-value whether any of them has since changed
        s_mt : I64,
        s_dist : I64,
        s_elev : I64,
        s_aw : I64,
        s_ahr : I64,
        s_waw : I64,
        s_re : I64,
        s_dw : I64,
        s_slen : I64,
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
                \\-- COALESCE and NOT a guard, which is the opposite of what this file does
                \\-- everywhere else, so it needs its reason stated. A NULL start_local
                \\-- crashed the decode here with UnexpectedType(Null) — `internal_error`,
                \\-- on the command every other error message names as the remedy (#249).
                \\--
                \\-- The obvious fix, a date sweep refusing before any scoring, was written
                \\-- and reverted: it refuses UPSTREAM of rebuild_daily_load!, which is where
                \\-- the deliberate policy lives — walk and write every day that CAN be read,
                \\-- then refuse naming the row, so a readable series is not thrown away over
                \\-- one bad date. e2e pins both halves of that, and the sweep silently
                \\-- turned the partial write off. A poisoned date has always flowed this way;
                \\-- a NULL now flows the same way rather than getting its own policy.
                \\--
                \\-- So the row IS scored, and `start_used` records the empty string it was
                \\-- scored from. rebuild_daily_load! then meets it through the metrics join
                \\-- it just wrote, drops it from the walk, and refuses naming it — which is
                \\-- also what stops an unscored NULL-dated row slipping past both guards.
                \\SELECT a.id AS id, COALESCE(CAST(a.start_local AS TEXT), '') AS start, a.moving_time AS mt,
                \\       COALESCE(CAST(a.sport_type AS TEXT), '') AS sport,
                \\       CAST(a.relative_effort AS REAL) AS re, CAST(a.avg_watts AS REAL) AS aw, CAST(a.avg_hr AS REAL) AS ahr,
                \\       CAST(a.weighted_avg_watts AS REAL) AS waw, CAST(r.rpe AS REAL) AS rpe, COALESCE(CAST(s.raw_json AS TEXT), '') AS raw,
                \\       COALESCE(a.device_watts, 1) AS dw,
                \\       CAST(ROUND(${period_ftp_sql}) AS REAL) AS pftp,
                \\       CAST(ROUND((${period_threshold_sql}) * 1000) AS REAL) / 1000.0 AS pthr,
                \\       ${inputs_select_sql}
                \\FROM activities a
                \\LEFT JOIN streams s ON s.activity_id = a.id
                \\LEFT JOIN ratings r ON r.activity_id = a.id
                \\LEFT JOIN activity_metrics m ON m.activity_id = a.id
                \\${pending_where(zones_case)}
                \\ORDER BY ${Metrics.rank_ts_sql("a.start_local", Asc)}, a.id LIMIT 64
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
                s_mt = Sqlite.i64("s_mt")(cols)(stmt)?
                s_dist = Sqlite.i64("s_dist")(cols)(stmt)?
                s_elev = Sqlite.i64("s_elev")(cols)(stmt)?
                s_aw = Sqlite.i64("s_aw")(cols)(stmt)?
                s_ahr = Sqlite.i64("s_ahr")(cols)(stmt)?
                s_waw = Sqlite.i64("s_waw")(cols)(stmt)?
                s_re = Sqlite.i64("s_re")(cols)(stmt)?
                s_dw = Sqlite.i64("s_dw")(cols)(stmt)?
                s_slen = Sqlite.i64("s_slen")(cols)(stmt)?
                Ok({ id, start, mt, sport, re, aw, ahr, waw, rpe, raw, pftp, pthr, dw: dw != 0, s_mt, s_dist, s_elev, s_aw, s_ahr, s_waw, s_re, s_dw, s_slen })
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
    # to the outer `a`. Same derivation as Db.sport_ftp! — the sport FAMILY's best 20-min
    # power × 0.95 (#151, ADR 0002 as amended) — but the 60-day window is anchored to the
    # ACTIVITY's date, not to today.
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
    # matches. Population is the sport FAMILY (#151) via the stored sport_family
    # column, indexed by idx_activities_family_start (schema v23) — the column, not
    # a CASE over sport_type, so the range seek survives.
    period_ftp_sql : Str
    period_ftp_sql =
        \\COALESCE(
        \\  NULLIF((SELECT MAX(m2.best_20min_w) * 0.95
        \\          FROM activity_metrics m2 JOIN activities a2 ON a2.id = m2.activity_id
        \\          WHERE a2.sport_family = a.sport_family
        \\            AND a2.start_local <= a.start_local
        \\            AND a2.start_local >= date(a.start_local, '-60 days')), 0),
        \\  NULLIF((SELECT MAX(m3.best_20min_w) * 0.95
        \\          FROM activity_metrics m3 JOIN activities a3 ON a3.id = m3.activity_id
        \\          WHERE a3.sport_family = a.sport_family
        \\            AND date(a3.start_local) <= date((SELECT MIN(a4.start_local) FROM activities a4
        \\                                              WHERE a4.sport_family = a.sport_family), '+60 days')), 0),
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

    # Each activity input that feeds scoring, expressed ONCE as a SQL expression. The
    # SELECT that stores the value (inputs_select_sql) and the predicate that compares it
    # (inputs_changed_sql) both interpolate these, so the write and the check cannot drift
    # apart into rescoring forever or never. Compile-time constants, never user data.
    # The design rationale lives on inputs_changed_sql below.
    e_mt = "COALESCE(a.moving_time,0)"
    e_dist = "CAST(ROUND(COALESCE(a.distance,0)) AS INTEGER)"
    e_elev = "CAST(ROUND(COALESCE(a.elevation,0)) AS INTEGER)"
    e_aw = "CAST(ROUND(COALESCE(a.avg_watts,0) * 100) AS INTEGER)"
    e_ahr = "CAST(ROUND(COALESCE(a.avg_hr,0) * 100) AS INTEGER)"
    e_waw = "CAST(ROUND(COALESCE(a.weighted_avg_watts,0) * 100) AS INTEGER)"
    e_re = "CAST(ROUND(COALESCE(a.relative_effort,0)) AS INTEGER)"
    e_dw = "COALESCE(a.device_watts,-1)"
    e_sport = "COALESCE(a.sport_type,'')"
    e_start = "COALESCE(a.start_local,'')"
    e_slen = "(CASE WHEN s.raw_json IS NULL THEN 0 ELSE LENGTH(s.raw_json) END)"

    # The columns the SELECT adds so a scored row can record what it was scored from.
    inputs_select_sql =
        \\${e_mt} AS s_mt, ${e_dist} AS s_dist, ${e_elev} AS s_elev,
        \\${e_aw} AS s_aw, ${e_ahr} AS s_ahr, ${e_waw} AS s_waw,
        \\${e_re} AS s_re, ${e_dw} AS s_dw, ${e_slen} AS s_slen

    # The activity inputs a metrics row was computed from, compared VALUE BY VALUE —
    # the same contract as `ftp_used`. A changed input rescores the row; this is why
    # `sync` does NOT delete metrics (invalidating there wiped a month per run, since
    # sync cannot tell an edit from a no-op).
    #
    # A hash was tried and rejected: with additive coefficients a +7s duration and a
    # -1m distance cancel exactly, so a real edit produced an identical signature and
    # never rescored — silently. Values cannot collide, and a human debugging a stale
    # row can read them. `synced_at` is deliberately absent: it changes every sync by
    # design, so including it would mark every row stale.
    inputs_changed_sql =
        \\   COALESCE(m.mt_used,-1) <> ${e_mt}
        \\OR COALESCE(m.dist_used,-1) <> ${e_dist}
        \\OR COALESCE(m.elev_used,-1) <> ${e_elev}
        \\OR COALESCE(m.aw_used,-1) <> ${e_aw}
        \\OR COALESCE(m.ahr_used,-1) <> ${e_ahr}
        \\OR COALESCE(m.waw_used,-1) <> ${e_waw}
        \\OR COALESCE(m.re_used,-1) <> ${e_re}
        \\OR COALESCE(m.dw_used,-2) <> ${e_dw}
        \\OR COALESCE(m.sport_used,'~') <> ${e_sport}
        \\OR COALESCE(m.start_used,'~') <> ${e_start}
        \\OR COALESCE(m.stream_len_used,-1) <> ${e_slen}

    # The "needs rescoring" predicate, shared by the batch SELECT and the COUNT that
    # gives the progress bar its denominator. ONE definition on purpose: two copies of
    # this would drift, and a denominator computed from a different predicate than the
    # work is a bar that lies.
    #
    # CALLERS MUST JOIN `activities a`, `activity_metrics m` AND `streams s` — the input
    # comparison reads `s.raw_json` to notice a stream arriving, so omitting that join is
    # a SQL error rather than a silently weaker check.
    pending_where : Str -> Str
    pending_where = |zones_case|
        \\WHERE m.activity_id IS NULL
        \\      OR CAST(COALESCE(m.ftp_used, 0) AS INTEGER) <> CAST(ROUND(${period_ftp_sql}) AS INTEGER)
        \\      OR CAST(ROUND(COALESCE(m.threshold_pace_used, 0) * 1000) AS INTEGER) <> CAST(ROUND((${period_threshold_sql}) * 1000) AS INTEGER)
        \\      OR COALESCE(m.zones_used, '') <> (${zones_case})
        \\      OR COALESCE(m.metrics_rev, 0) <> :rev
        \\      OR (${inputs_changed_sql})

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
                \\LEFT JOIN streams s ON s.activity_id = a.id
                \\LEFT JOIN activity_metrics m ON m.activity_id = a.id
                \\${pending_where(zones_case)}
            ,
            bindings: [{ name: ":rev", value: Integer(metrics_rev) }],
            row: Sqlite.i64("n"),
        })?
        Ok(if n < 0 0 else (n).to_u64_wrap())
    }
    # ── per-sport HR zones ───────────────────────────────────────────────
    # HR zones default to one global set (hr_z*_max) with per-sport overrides
    # (hr_z*_max_<sport>). The whole config table is read ONCE and resolution is then
    # PURE — a per-key Sqlite.query! on the many usually-absent per-sport keys returns
    # Err(NoRowsReturned) and would fail the command on the first missing override.
    # Each sport's zone SIGNATURE is frozen for the invalidation CASE; per-row scoring
    # re-resolves bounds from the same in-memory config.
    #
    # Validated at the LOAD boundary rather than at each read: `cfg_f64` is pure and
    # total (an ABSENT per-sport key must fall back to the global ceiling), but an
    # UNREADABLE one must not take that path — silently using the global value ignores
    # the athlete's per-sport zones with nothing to see, the #206 trap. Checking here
    # keeps the fallback total and still refuses the bad value.
    load_config! : Str => Try(List((Str, Str)), _)
    load_config! = |path| {
        pairs = load_config_raw!(path)?
        bad = List.keep_if(pairs, |pair|
            Str.starts_with(pair.0, "hr_z") and Metrics.arg_f64(pair.1).is_err())
        match List.first(bad) {
            Ok(pair) => Err(UnreadableConfig(pair.0, pair.1))
            Err(_) => Ok(pairs)
        }
    }
    load_config_raw! : Str => Try(List((Str, Str)), _)
    load_config_raw! = |path|
        Sqlite.query_many!({
            path: Path.utf8(path),
            query: "SELECT COALESCE(CAST(key AS TEXT), '') AS k, COALESCE(CAST(value AS TEXT), '') AS v FROM config",
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
                    match Metrics.arg_f64(pair.1) {
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
            query: "SELECT DISTINCT COALESCE(CAST(sport_type AS TEXT), '') AS s FROM activities WHERE sport_type IS NOT NULL AND sport_type <> ''",
            bindings: [],
            rows: Sqlite.str("s"),
        })?
        Ok(List.map(sports, |s| (s, zones_sig(resolve_zones_pure(cfg, s, g)))))
    }
    # pure: `CASE a.sport_type WHEN '<sport>' THEN '<sig>' … ELSE '<global_sig>' END`, the
    # zones analog of `period_ftp_sql`, built from the frozen (sport, sig) list. Each row's
    # stored zones_used is compared to ITS sport's signature, so a per-sport zone edit
    # invalidates only that sport's rows.
    zones_case_from_sigs : List((Str, Str)), Metrics.ZoneBounds -> Str
    zones_case_from_sigs = |sigs, g| {
        whens = List.fold(sigs, "", |acc, pair| {
            esc = Str.replace_each(pair.0, "'", "''")
            "${acc} WHEN '${esc}' THEN '${pair.1}'"
        })
        # zero sports (fresh db, analyze before first sync): "CASE x ELSE y END"
        # with no WHEN arms is a SQL syntax error, so emit the ELSE literal bare —
        # found by the #154 e2e ""-arm check; analyze used to crash right here
        if Str.is_empty(whens) {
            "'${zones_sig(g)}'"
        } else {
            "CASE a.sport_type${whens} ELSE '${zones_sig(g)}' END"
        }
    }
    # returns Bool: did the stored stream JSON fail to decode? (surfaced by analyze)
    # (#69 briefly split this into a dispatcher over a wire format; its only producer —
    # the Python export decoder — was reverted in #70, so every stored stream is JSON.)
    compute_one! : Str, Metrics.ZoneBounds, List((Str, Str)), ActivityRow => Try(Bool, _)
    compute_one! = |path, zb, cfg, row| {
        decoded = Streams.decode_streams(row.raw)
        streams = decoded.streams
        # this sport's zone bounds: per-sport override or global, resolved purely from
        # the in-memory config. No per-key DB hit, for the reason given where the config is
        # loaded — an absent override is a missing row, not a missing value.
        row_zb = resolve_zones_pure(cfg, row.sport, zb)

        # sanity-filter HR: some sources (Peloton strength workouts) emit junk
        # near-zero samples — Metrics.valid_hr is the one place the bounds live
        hr_raw = Streams.stream_pairs(streams.time, streams.heartrate)
        hr_pairs = List.keep_if(hr_raw, |p| Metrics.valid_hr(p.v))
        # drop non-physiological power samples (sensor glitches) the same way HR is
        # filtered — one 1s spike would inflate NP and the 20-min best behind FTP.
        # Estimated watts (#73): device_watts=False means the whole stream is Strava's
        # model output, not a measurement — it must not feed NP, the 20-min best behind
        # DERIVED FTP, the power curve, or the intensity split. Drop it wholesale.
        watts_raw = if row.dw Streams.stream_pairs(streams.time, streams.watts) else []
        watts_pairs = List.keep_if(watts_raw, |p| Metrics.valid_watts(p.v))

        # The in-band mean of this session's HR stream — the number the SCORING lenses
        # divide by when it exists (#311). `hr_pairs` is already `valid_hr`-filtered, so
        # dropout and dead-sensor stretches are gone rather than averaged in (the failure
        # this addresses: a session storing 86.4 whose own stream means 147.7).
        #
        # NULL, never 0.0, when there is nothing to average: 0.0 is what `COALESCE(...,0)`
        # produces at every read site, so a stored 0 would collide with "no stream".
        # An UNWEIGHTED mean — `time_in_zones` gap-weights the same list; measured across
        # all 672 streams the two differ by at most 2.58 bpm. The LOAD LADDER never sees
        # this value: `tss_ladder` reads `input.avg_hr`, filled from the STORED summary
        # (verified behaviourally — daily_load byte-identical across a full re-analyze).
        #
        # ...and NULL unless the surviving samples SPAN at least half the session — a mean
        # over unrepresentative samples is the same bug this column fixes, moved one table
        # over. The worst dropout keeps a contiguous PREFIX (the warm-up before the strap
        # died): one session kept samples spanning t=14..576 of 2700 s whose mean, 84.8,
        # is plausible enough that no bound would question it. SPAN, not sample COUNT —
        # a 5-second cadence keeps a fifth of the samples with a healthy strap, and 15 of
        # the 17 rows a count ratio refuses are exactly that. The threshold sits in a
        # measured gap: broken straps span 0.003-0.24, rescued sessions 0.58 up.
        # The denominator is the LONGER of moving time and the stream's own extent:
        # moving_time excludes stops while stream timestamps are elapsed, so a stop-heavy
        # session would inflate the ratio (a minority of streams run longer than moving time,
        # up to 1.198x).
        hr_extent =
            match (List.first(hr_raw), List.last(hr_raw)) {
                (Ok(f), Ok(l)) => l.t - f.t
                _ => 0
            }
        hr_denom = if hr_extent > row.mt hr_extent else row.mt
        hr_span_ok =
            match (List.first(hr_pairs), List.last(hr_pairs)) {
                (Ok(f), Ok(l)) if hr_denom > 0 =>
                    # `hr_pairs` comes from `stream_pairs`, which preserves the stream's own
                    # order, and Strava's time series is ascending — so first and last are the
                    # extremes. Guarded anyway: a non-ascending stream yields a negative span,
                    # which fails the comparison rather than passing it by accident.
                    (l.t - f.t).to_f64() >= 0.5 * (hr_denom).to_f64()

                _ => False
            }
        avg_hr_stream_binding =
            if List.is_empty(hr_pairs) or !(hr_span_ok) {
                Null
            } else {
                Real(List.fold(hr_pairs, 0.0, |acc, p| acc + p.v) / (List.len(hr_pairs)).to_f64())
            }
        # #92 sample-validity counters. Counted against `*_raw`, which for watts is ALREADY
        # empty when the stream is estimated — so the wholesale #73 exclusion contributes
        # 0 dropped of 0 total rather than reading as 100% junk. Only samples a validity
        # filter rejected are counted as dropped.
        hr_total = List.len(hr_raw)
        hr_dropped = hr_total - List.len(hr_pairs)
        watts_total = List.len(watts_raw)
        watts_dropped = watts_total - List.len(watts_pairs)
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
        # aerobic decoupling (#94/#134) — computed HERE, below the graded-speed
        # derivation, precisely so the pace variant can reuse it instead of
        # duplicating it (the reorder the old "POWER ONLY" comment was waiting for).
        # Power wins when real watts exist; pace-routed sports (runs/swims) fall to
        # graded speed vs HR — same drift arithmetic, same Known/Unknown honesty.
        # Everything else (meter-less rides, rows without watts) stays Unknown:
        # terrain speed over HR is not an efficiency measurement.
        # Signal provenance is three-valued and stored honestly: "power" (real
        # watts), "pace" (grade-adjusted speed — a graded triple existed, or a swim
        # where water is flat and grading is meaningless), or "speed" (raw speed —
        # no altitude stream, so terrain effects are NOT normalized out; real runs
        # without a barometer land here and deserve the number WITH the disclosure,
        # not an amputated feature). Rides never reach the pace/speed arms at all.
        decoupling =
            if !(List.is_empty(watts_pairs))
                Metrics.decoupling_pct(watts_pairs, hr_pairs, row.s_mt)
            else if Sports.pace_routed(row.sport)
                Metrics.decoupling_pct(gas_1s_pairs, hr_pairs, row.s_mt)
            else
                Unknown
        graded = !(List.is_empty(graded_triple.time)) or Str.contains(Str.with_ascii_lowercased(row.sport), "swim")
        decoupling_signal_val =
            match decoupling {
                Unknown => Null
                Known(_) =>
                    if !(List.is_empty(watts_pairs))
                        String("power")
                    else if graded
                        String("pace")
                    else
                        String("speed")
            }
        gas_speeds = List.map(gas_1s_pairs, |p| p.v)
        ngp_speed = Metrics.normalized_power(gas_speeds)
        best20_speed = Metrics.best_rolling_mean_1s(gas_1s_pairs, 1200)
        # the 300 s and 600 s rungs of the same grade-adjusted ladder (#188). Same source
        # stream as best20_speed, so a hilly rep is comparable with a flat one; together
        # the three points are what critical speed fits S(t) = D'/t + CS against.
        best300_speed = Metrics.best_rolling_mean_1s(gas_1s_pairs, 300)
        best600_speed = Metrics.best_rolling_mean_1s(gas_1s_pairs, 600)
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
        best300_speed_binding =
            match best300_speed {
                Ok(b) => Real(b)
                Err(_) => Null

            }
        best600_speed_binding =
            match best600_speed {
                Ok(b) => Real(b)
                Err(_) => Null

            }
        # ADR 0008: detected interval structure — same lifecycle as the metrics row
        # (invalidate paths DELETE it; it recomputes here whenever the row recomputes).
        # Segments are written BEFORE the metrics row on purpose: the metrics row is
        # the commit marker for this activity, so a failure mid-segment-write leaves
        # the row absent and the next analyze redoes the whole activity — no frozen
        # partial rep set can survive. Power detects when real watts exist; pace only
        # for pace-routed sports (runs/swims) — a meter-less RIDE must not get
        # run-tuned pace detection of its terrain speed.
        _ = Sqlite.execute!({ path: Path.utf8(path), query: "DELETE FROM activity_segments WHERE activity_id = :id", bindings: [{ name: ":id", value: Integer(row.id) }] })?
        hr_1s_pairs = Metrics.resample_1s_pairs(hr_pairs, Hold)
        _ =
            if !(List.is_empty(watts_1s_pairs)) {
                insert_segments!(path, row.id, "power", Metrics.detect_segments(watts_1s_pairs, Metrics.detect_power_params), hr_1s_pairs)?
            } else if Sports.pace_routed(row.sport) and !(List.is_empty(gas_1s_pairs)) {
                insert_segments!(path, row.id, "pace", Metrics.detect_segments(gas_1s_pairs, Metrics.detect_pace_params), hr_1s_pairs)?
            } else {
                {}
            }
        Sqlite.execute!({
            path: Path.utf8(path),
            query:
                \\INSERT OR REPLACE INTO activity_metrics
                \\  (activity_id, tss, normalized_power, intensity_factor, z1_s, z2_s, z3_s, z4_s, z5_s, computed_at, best_20min_w, ftp_used, zones_used, metrics_rev, load_model, pi_easy_s, pi_moderate_s, pi_hard_s, best_5s_w, best_15s_w, best_30s_w, best_60s_w, best_300s_w, best_600s_w, best_3600s_w, best_20min_speed, best_300s_speed, best_600s_speed, threshold_pace_used, hr_samples_total, hr_samples_dropped, watts_samples_total, watts_samples_dropped, mt_used, dist_used, elev_used, aw_used, ahr_used, waw_used, re_used, dw_used, sport_used, start_used, stream_len_used, decoupling_pct, decoupling_signal, avg_hr_stream)
                \\VALUES (:id, :tss, :np, :if, :z1, :z2, :z3, :z4, :z5, :at, :b20, :ftpu, :zused, :rev, :model, :pie, :pim, :pih, :bc5, :bc15, :bc30, :bc60, :bc300, :bc600, :bc3600, :b20s, :b300s, :b600s, :thru, :hrt, :hrd, :wt, :wd, :umt, :udist, :uelev, :uaw, :uahr, :uwaw, :ure, :udw, :usport, :ustart, :uslen, :decoup, :dsig, :ahrs)
            ,
            bindings: [
                { name: ":umt", value: Integer(row.s_mt) },
                { name: ":udist", value: Integer(row.s_dist) },
                { name: ":uelev", value: Integer(row.s_elev) },
                { name: ":uaw", value: Integer(row.s_aw) },
                { name: ":uahr", value: Integer(row.s_ahr) },
                { name: ":uwaw", value: Integer(row.s_waw) },
                { name: ":ure", value: Integer(row.s_re) },
                { name: ":udw", value: Integer(row.s_dw) },
                { name: ":usport", value: String(row.sport) },
                { name: ":ustart", value: String(row.start) },
                { name: ":uslen", value: Integer(row.s_slen) },
                # NULL, not 0, when there is nothing to measure — 0.0 is a real result
                # here (a perfectly steady session) and the two must stay distinguishable
                { name: ":decoup", value: match decoupling { Known(d) => Real(d)  Unknown => Null } },
                { name: ":dsig", value: decoupling_signal_val },
                { name: ":ahrs", value: avg_hr_stream_binding },
                { name: ":hrt", value: Integer((hr_total).to_i64_wrap()) },
                { name: ":hrd", value: Integer((hr_dropped).to_i64_wrap()) },
                { name: ":wt", value: Integer((watts_total).to_i64_wrap()) },
                { name: ":wd", value: Integer((watts_dropped).to_i64_wrap()) },
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
                { name: ":b300s", value: best300_speed_binding },
                { name: ":b600s", value: best600_speed_binding },
                # store the threshold the row was scored against — the pace twin of ftp_used,
                # so a later threshold change invalidates via the recompute WHERE
                { name: ":thru", value: Real(threshold_speed) },
            ],
        })?
        Ok(decoded.failed)
    }

    # write detected segments with per-WORK-rep HR enrichment; NULL HR columns are
    # honest absence (no HR samples inside the rep), never zeros
    insert_segments! : Str, I64, Str, List(Metrics.Segment), List({ t : I64, v : F64 }) => Try({}, _)
    insert_segments! = |path, id, signal_name, segs, hr_pairs|
        walk_segments!(path, id, signal_name, segs, hr_pairs, 0)

    # first WORK segment strictly after index ix — the rec-drop window guard needs it
    next_work_after : List(Metrics.Segment), U64 -> [NextWorkAt(I64), NoNextWork]
    next_work_after = |segs, ix|
        List.fold(List.drop_first(segs, ix + 1), NoNextWork, |acc, s2|
            match acc {
                NextWorkAt(t) => NextWorkAt(t)
                NoNextWork => if s2.kind == Work NextWorkAt(s2.start_s) else NoNextWork
            })

    walk_segments! : Str, I64, Str, List(Metrics.Segment), List({ t : I64, v : F64 }), U64 => Try({}, _)
    walk_segments! = |path, id, signal_name, segs, hr_pairs, ix|
        match List.get(segs, ix) {
            Err(_) => Ok({})
            Ok(seg) => {
                kind_str = match seg.kind {
                    Work => "work"
                    Recovery => "recovery"
                    Warmup => "warmup"
                    Cooldown => "cooldown"
                }
                hr = if seg.kind == Work Metrics.segment_hr(seg, next_work_after(segs, ix), hr_pairs) else NoHr
                hr_bind = |get| match hr {
                    Hr(r) => Real(get(r))
                    NoHr => Null
                }
                drop_bind = match hr {
                    Hr(r) =>
                        match r.rec_drop_60s {
                            Known(d) => Real(d)
                            Unknown => Null
                        }
                    NoHr => Null
                }
                Sqlite.execute!({
                    path: Path.utf8(path),
                    query:
                        \\INSERT OR REPLACE INTO activity_segments
                        \\  (activity_id, ordinal, kind, start_s, dur_s, avg_signal, signal, peak_hr, avg_hr, rec_drop_60s)
                        \\VALUES (:id, :ord, :kind, :ss, :ds, :avg, :sig, :phr, :ahr, :drop)
                    ,
                    bindings: [
                        { name: ":id", value: Integer(id) },
                        { name: ":ord", value: Integer((ix).to_i64_wrap()) },
                        { name: ":kind", value: String(kind_str) },
                        { name: ":ss", value: Integer(seg.start_s) },
                        { name: ":ds", value: Integer(seg.dur_s) },
                        { name: ":avg", value: Real(seg.avg_signal) },
                        { name: ":sig", value: String(signal_name) },
                        { name: ":phr", value: hr_bind(|r| r.peak_hr) },
                        { name: ":ahr", value: hr_bind(|r| r.avg_hr) },
                        { name: ":drop", value: drop_bind },
                    ],
                })?
                walk_segments!(path, id, signal_name, segs, hr_pairs, ix + 1)
            }
        }
    # ── daily load (CTL/ATL/TSB) ────────────────────────────────────────

    rebuild_daily_load! : Str => Try({}, _)
    rebuild_daily_load! = |path| {
        day_rows = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT COALESCE(substr(CAST(a.start_local AS TEXT), 1, 10), '') AS day, SUM(m.tss) AS t,
                \\       -- carried ONLY so an unreadable day can name a row the user can
                \\       -- act on (#243): a date is not something you can delete or re-fetch,
                \\       -- an id is. example_id cannot tie-break here — GROUP BY day already
                \\       -- makes day unique — so it is belt-and-braces, unlike ReportSeason
                \\       -- where `fam` decides which group is met first.
                \\       MIN(m.activity_id) AS example_id
                \\FROM activity_metrics m
                \\JOIN activities a ON a.id = m.activity_id
                \\GROUP BY day ORDER BY day, example_id
            ,
            bindings: [],
            rows: |cols| |stmt| {
                day = Sqlite.str("day")(cols)(stmt)?
                t = Sqlite.f64("t")(cols)(stmt)?
                example_id = Sqlite.i64("example_id")(cols)(stmt)?
                Ok({ day, t, example_id })
            },
        })?
        # keep only rows whose date is CANONICAL and parses; walk bounds derive from the
        # VALID days, so one malformed start_local cannot walk the series from 1970.
        #
        # is_canonical_date as well as the parse, because this site WRITES:
        # `date_str_to_days` alone accepts '2026-3-05T…', and the day is written back
        # through days_to_date_str, landing in daily_load laundered into a perfectly
        # canonical-looking date no downstream guard can catch. The guard has to be here,
        # upstream of the write.
        by_day = List.fold(
            day_rows,
            Dict.empty(),
            # calls usable_date_days rather than restating it: a day excluded here but not counted
            # `unusable` is dropped silently (the #243 bug itself), and one accepted here but
            # counted `unusable` makes the run refuse over data it did use.
            |dict, r|
                match Metrics.usable_date_days(r.day) {
                    Ok(d) => Dict.insert(dict, d, r.t)
                    Err(_) => dict,
                }
        )
        # Every row the fold could NOT use, kept rather than discarded — one bad date
        # among many is the LIKELY shape. The walk still writes what it could read (a
        # correct partial series beats no series), then the run refuses NAMING the row, so
        # the incompleteness is stated rather than left for `season` to discover.
        unusable = List.keep_if(day_rows, |r| !(Metrics.is_usable_date(r.day)))
        valid_days = Dict.keys(by_day)
        walked = match List.first(valid_days) {
            # Nothing to walk — but TWO different facts arrive here. `day_rows` EMPTY means
            # nothing scored yet: clear and succeed (daily_load is a pure function of what was
            # scored, and a stale series left behind is what let a poisoned row survive
            # `analyze` while every reader refused on it, a loop at exit 0). `day_rows`
            # NON-EMPTY with no parseable day is different: the engine holds scored
            # activities, and answering `converged: true` would tell the athlete "no scored
            # training days yet" while `stats` reports their sessions in the same breath — so
            # it names the row instead.
            Err(_) => Sqlite.execute!({ path: Path.utf8(path), query: "DELETE FROM daily_load", bindings: [] })
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
        walked?
        # ...and only now, after the table holds everything that WAS readable, refuse if
        # anything was not. Order matters: refusing first would leave daily_load stale, and
        # every reader would keep answering confidently from a series whose inputs the
        # engine cannot read — the silent wrong answer this whole change removes.
        match List.first(unusable) {
            Ok(r) => Err(BadActivityDate(r.day, r.example_id))
            Err(_) => Ok({})
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
    # zones_used) can't catch algorithm changes.
    #
    # Bump for a new stored metric COLUMN too. A column added without a bump stays NULL
    # on every row already in the db, so the feature reading it is inert for exactly the
    # history that would make it useful — the whole activity archive. 33 adds the #188
    # speed ladder (best_300s_speed / best_600s_speed).
    metrics_rev = 33
}
