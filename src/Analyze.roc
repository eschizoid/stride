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
            Ok(cfg) => {
                res = converge_metrics!(path, cfg.zb, 5, { computed: 0, stream_errors: 0 })?
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
                    Output.emit_ok!({ computed: res.computed, stream_errors: res.stream_errors, form_tsb })
                } else {
                    Stdout.line!("computed metrics for ${U64.to_str(res.computed)} activities")?
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
    load_zone_config! : Str => Try({ ftp : F64, zb : Metrics.ZoneBounds }, _)
    load_zone_config! = |path| {
        ftp = config_f64!(path, "ftp_ride")?
        z1 = config_f64!(path, "hr_z1_max")?
        z2 = config_f64!(path, "hr_z2_max")?
        z3 = config_f64!(path, "hr_z3_max")?
        z4 = config_f64!(path, "hr_z4_max")?
        Ok({ ftp, zb: { z1_max: z1, z2_max: z2, z3_max: z3, z4_max: z4 } })
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
    }

    # analyze runs compute_missing_metrics! to a FIXED POINT (bounded), not once. A pass can
    # change a sport's DERIVED FTP (its best_20min_w gets populated), which invalidates rows
    # the next pass must rescore; iterate until a pass computes 0 (converged) or fuel runs
    # out. Configured-FTP dbs converge in one real pass (pass 2 finds nothing), so the count
    # still matches "activities analyzed"; a fresh derived-FTP db converges in ~2.
    converge_metrics! : Str, Metrics.ZoneBounds, U64, { computed : U64, stream_errors : U64 } => Try({ computed : U64, stream_errors : U64 }, _)
    converge_metrics! = |path, zb, fuel, acc|
        if fuel == 0 {
            Ok(acc)
        } else {
            r = compute_missing_metrics!(path, zb)?
            # accumulate BOTH counters across passes: the final converged pass computes 0
            # rows, so taking only its stream_errors would erase unreadable-stream warnings
            # raised in earlier passes and hide them from the report / JSON.
            total = { computed: acc.computed + r.computed, stream_errors: acc.stream_errors + r.stream_errors }
            if r.computed == 0 { Ok(total) } else converge_metrics!(path, zb, fuel - 1, total)
        }

    compute_missing_metrics! : Str, Metrics.ZoneBounds => Try({ computed : U64, stream_errors : U64 }, _)
    compute_missing_metrics! = |path, zb| {
        # recompute a row when its stored ftp_used no longer matches ITS sport's current
        # FTP (per-sport, via the CASE), or the HR zones / metrics_rev changed.
        ftp_map = sport_ftp_map!(path)?
        ftp_case = ftp_case_from_map(ftp_map)
        rows = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT a.id AS id, a.start_local AS start, a.moving_time AS mt,
                \\       COALESCE(a.sport_type, '') AS sport,
                \\       CAST(a.relative_effort AS REAL) AS re, CAST(a.avg_watts AS REAL) AS aw, CAST(a.avg_hr AS REAL) AS ahr,
                \\       CAST(a.weighted_avg_watts AS REAL) AS waw, CAST(r.rpe AS REAL) AS rpe, s.raw_json AS raw
                \\FROM activities a
                \\LEFT JOIN streams s ON s.activity_id = a.id
                \\LEFT JOIN ratings r ON r.activity_id = a.id
                \\LEFT JOIN activity_metrics m ON m.activity_id = a.id
                \\WHERE m.activity_id IS NULL
                \\      OR CAST(COALESCE(m.ftp_used, 0) AS INTEGER) <> CAST((${ftp_case}) AS INTEGER)
                \\      OR COALESCE(m.zones_used, '') <> :zones
                \\      OR COALESCE(m.metrics_rev, 0) <> :rev
            ,
            bindings: [
                { name: ":zones", value: String(zones_sig(zb)) },
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
                Ok({ id, start, mt, sport, re, aw, ahr, waw, rpe, raw })
            },
        })?
        process_rows!(path, zb, ftp_map, rows, { computed: 0, stream_errors: 0 })
    }
    process_rows! : Str, Metrics.ZoneBounds, List((Str, F64)), List(ActivityRow), { computed : U64, stream_errors : U64 } => Try({ computed : U64, stream_errors : U64 }, _)
    process_rows! = |path, zb, ftp_map, rows, acc|
        match rows {
            [] => Ok(acc)
            [row, .. as rest] => {
                failed = compute_one!(path, zb, ftp_map, row)?
                next = {
                    computed: acc.computed + 1,
                    stream_errors: acc.stream_errors + (if failed 1 else 0),
                }
                process_rows!(path, zb, ftp_map, rest, next)
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
    # a SQL `CASE a.sport_type WHEN … THEN <ftp> … ELSE 0 END` mapping each sport to its
    # resolved FTP, so the analyze recompute-check compares each row's stored ftp_used to
    # ITS sport's current FTP (not one global number). Without this, per-sport ftp_used
    # would never equal the single cycling ftp and rowing/running rows would recompute
    # every run. Sport names come from Strava (no quotes in practice; local single-user).
    # each sport's resolved FTP, materialized ONCE per compute pass. Freezing it fixes the
    # derived-FTP circular dependency: Db.sport_ftp! derives from MAX(best_20min_w), which
    # compute_one! itself WRITES — so re-reading it per row made scoring order-dependent and
    # made a fresh db score all power as zero. Now the recompute WHERE and the per-row
    # scoring both read this ONE frozen map; the analyze! fixed-point loop re-derives it each
    # pass so a fresh db's first-pass zeros converge once best_20min_w is populated.
    sport_ftp_map! : Str => Try(List((Str, F64)), _)
    sport_ftp_map! = |path| {
        sports = Sqlite.query_many!({
            path: Path.utf8(path),
            query: "SELECT DISTINCT sport_type AS s FROM activities WHERE sport_type IS NOT NULL AND sport_type <> ''",
            bindings: [],
            rows: Sqlite.str("s"),
        })?
        build_ftp_map!(path, sports, [])
    }
    build_ftp_map! : Str, List(Str), List((Str, F64)) => Try(List((Str, F64)), _)
    build_ftp_map! = |path, sports, acc|
        match sports {
            [] => Ok(acc)
            [s, .. as rest] => {
                f = Db.sport_ftp!(path, s)?
                build_ftp_map!(path, rest, List.append(acc, (s, f)))
            }
        }
    # pure: this sport's frozen FTP (0 if absent — a no-power sport, which falls back to HR)
    lookup_ftp : List((Str, F64)), Str -> F64
    lookup_ftp = |m, sport|
        List.fold(m, 0.0, |acc, pair| if pair.0 == sport pair.1 else acc)
    # pure: the `CASE a.sport_type WHEN '<sport>' THEN <ftp> … ELSE 0 END` for the recompute
    # WHERE, built from the SAME frozen map. Single quotes in a sport name are SQL-escaped so
    # a name like "d'Or" can't break the CASE or inject SQL.
    ftp_case_from_map : List((Str, F64)) -> Str
    ftp_case_from_map = |m| {
        whens = List.fold(m, "", |acc, pair| {
            esc = Str.replace_each(pair.0, "'", "''")
            "${acc} WHEN '${esc}' THEN ${(pair.1).to_str()}"
        })
        "CASE a.sport_type${whens} ELSE 0 END"
    }
    # returns Bool: did the stored stream JSON fail to decode? (surfaced by analyze)
    compute_one! : Str, Metrics.ZoneBounds, List((Str, F64)), ActivityRow => Try(Bool, _)
    compute_one! = |path, zb, ftp_map, row| {
        decoded = Streams.decode_streams(row.raw)
        streams = decoded.streams

        # sanity-filter HR: some sources (Peloton strength workouts) emit junk
        # near-zero samples — Metrics.valid_hr is the one place the bounds live
        hr_pairs = List.keep_if(
            Streams.stream_pairs(streams.time, streams.heartrate),
            |p| Metrics.valid_hr(p.v),
        )
        # drop non-physiological power samples (sensor glitches) the same way HR is
        # filtered — one 1s spike would inflate NP and the 20-min best behind FTP.
        watts_pairs = List.keep_if(
            Streams.stream_pairs(streams.time, streams.watts),
            |p| Metrics.valid_watts(p.v),
        )
        watts_1s = Metrics.resample_1s(List.map(watts_pairs, |p| { t: p.t, v: p.v }))

        zones = if List.is_empty(hr_pairs) zero_zones else Metrics.time_in_zones(hr_pairs, zb)

        np_stream = Metrics.normalized_power(watts_1s)
        best20 = Metrics.best_rolling_mean(watts_1s, 1200)

        # intensity from power, judged against the sport's own FTP (0 for no-power sports
        # → all-zero, and the display falls back to HR). Stored so the weekly polarization
        # and the activities "hard" column read power where it exists, HR where it doesn't.
        # the sport's FROZEN FTP (from the up-front map) — never re-derived per row, so
        # scoring is order-independent and consistent with the recompute WHERE (see sport_ftp_map!)
        pi_ftp = lookup_ftp(ftp_map, row.sport)
        pintensity = Metrics.time_in_power_intensity(watts_pairs, pi_ftp)

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
            zb,
            ftp: pi_ftp, # the SPORT's FTP, not cycling's — so rowing/running load is scaled right
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
        Sqlite.execute!({
            path: Path.utf8(path),
            query:
                \\INSERT OR REPLACE INTO activity_metrics
                \\  (activity_id, tss, normalized_power, intensity_factor, z1_s, z2_s, z3_s, z4_s, z5_s, computed_at, best_20min_w, ftp_used, zones_used, metrics_rev, load_model, pi_easy_s, pi_moderate_s, pi_hard_s)
                \\VALUES (:id, :tss, :np, :if, :z1, :z2, :z3, :z4, :z5, :at, :b20, :ftpu, :zused, :rev, :model, :pie, :pim, :pih)
            ,
            bindings: [
                { name: ":pie", value: Integer(pintensity.easy_s) },
                { name: ":pim", value: Integer(pintensity.moderate_s) },
                { name: ":pih", value: Integer(pintensity.hard_s) },
                { name: ":ftpu", value: Real(pi_ftp) },
                { name: ":zused", value: String(zones_sig(zb)) },
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
                Sqlite.execute!({ path: Path.utf8(path), query: "DELETE FROM daily_load", bindings: [] })?
                walk_days!(path, by_day, bounds.lo, last_day, 0.0, 0.0)
            }
        }
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
    metrics_rev = 6
}
