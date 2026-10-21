import Db
import Output
import Strava
import Report
import ReportSessions
import Csv
import Metrics
import Analyze
import strength.StravaLog
import pf.Sqlite
import pf.Cmd
import pf.OsStr
import pf.Path
import pf.Stdout
import pf.Stdin

Import :: [].{
    # ── import from a Strava account export (no API credentials needed) ──
    # Phase 1 of the export path (#6): summary-level rows from activities.csv, fed
    # through the SAME upsert as sync — idempotent, metrics-invalidation intact.
    # Streams aren't in the CSV, so zone/NP metrics stay honestly absent; the TSS
    # ladder falls back to watts/HR/relative-effort exactly as with sparse API data.
    import_archive! : Str => Try({}, _)
    import_archive! = |src| {
        db = Db.open_db!({})?
        # A ZIP is read with `unzip -p`, which streams ONE member to stdout — the archive
        # is never expanded onto disk. The old path extracted the whole export into a
        # mktemp dir, leaving private activity data lying in /tmp with no cleanup. `src`
        # is passed as a single argv value, never shell-interpolated. (From mason's #69.)
        text_result =
            if Str.ends_with(Str.with_ascii_lowercased(src), ".zip") {
                match Cmd.new(OsStr.from_str("unzip")).args(List.map(["-p", "-q", src, "activities.csv"], OsStr.from_str)).exec_output!() {
                    Ok(out) => Ok(out.stdout_utf8)
                    Err(_) => Err(UnzipFailed)
                }
            } else {
                Path.read_utf8!(Path.utf8("${src}/activities.csv")).map_err(|_| NoActivitiesCsv)
            }
        match text_result {
            Err(UnzipFailed) => Output.err_out!("unzip_failed", "couldn't read activities.csv from ${src} — is `unzip` installed and is this a Strava account export?")
            Err(NoActivitiesCsv) => Output.err_out!("no_activities_csv", "no activities.csv in ${src} — point me at a Strava account export (Settings → My Account → Download or Delete Your Account)")
            Err(other) => Err(other)
            Ok(text) =>
                match Csv.parse(text) {
                    [headers, .. as rows] => {
                        counts = import_rows!(db, headers, rows, { imported: 0.U64, skipped: 0.U64 })?
                        if Output.json_mode!({})
                            Output.emit_ok!(counts)
                        else
                            Stdout.line!("imported ${(counts.imported).to_str()} activities (${(counts.skipped).to_str()} rows skipped) — run `stride analyze` to compute metrics")
                    }
                    _ => Output.err_out!("empty_csv", "activities.csv is empty")
                }
        }
    }
    import_rows! : Str, List(Str), List(List(Str)), { imported : U64, skipped : U64 } => Try({ imported : U64, skipped : U64 }, _)
    import_rows! = |db, headers, rows, acc|
        match rows {
            [] => Ok(acc)
            [row, .. as rest] =>
                match ReportSessions.export_row_to_summary(headers, row) {
                    Ok(summary) => {
                        # stamp 0 → synced_at stays NULL: CSV imports were never on Strava,
                        # so a later sync's prune must never treat them as deletions
                        Strava.upsert_activity!(db, 0, summary)?
                        import_rows!(db, headers, rest, { ..acc, imported: acc.imported + 1 })
                    }
                    Err(_) =>
                        import_rows!(db, headers, rest, { ..acc, skipped: acc.skipped + 1 })

                }
        }

    # ── a structured strength log from Strava's MCP connector ────────────
    # Strava's public API does not return a strength workout's sets; its MCP
    # connector does, and stride cannot call MCP, so a coach fetches the JSON
    # and hands it over here: a list of workout objects, or one on its own.
    # Each workout is decoded on its own, and each one that lands is stored
    # in strength_logs as the text the connector wrote (one row per activity,
    # replaced on re-import); strength_sets is rebuilt once at the end so the
    # rows are there without an analyze.
    #
    # Nothing is left out silently. A workout that cannot be placed is a
    # SKIPPED entry with its reason, never an error, so one bad workout does
    # not cost the rest of the batch; a set left out of a stored workout is a
    # `dropped` entry on that workout. Only input that is not a JSON object or
    # list at all, or a file that cannot be read, fails the command.
    #
    # A log lands only on a strength-family activity: strength_coverage counts
    # sessions of that family alone, and the tonnage spine joins it, so sets on
    # any other activity would be tonnage no coverage figure accounts for. The
    # family is read from activity_family_month, the view strength_coverage
    # groups on, so the gate and the view cannot disagree.
    #
    # The FIRST workout in the input naming an activity is the one considered;
    # a later one naming it again is skipped as duplicate_activity, so a
    # batch never stores one activity twice and reports both.
    StrengthImported : { activity_id : I64, rows : I64, sets : I64, dropped : List(StravaLog.Dropped), zeroed : List(StravaLog.Zeroed) }
    StrengthSkipped : { activity_id : Str, reason : Str, dropped : List(StravaLog.Dropped) }
    StrengthImportOutcome : { imported : List(StrengthImported), skipped : List(StrengthSkipped) }

    import_strength_log! : Str => Try({}, _)
    import_strength_log! = |src| {
        db = Db.open_db!({})?
        label = if src == "-" "stdin" else src
        text_result =
            if src == "-" {
                match Stdin.read_to_end!() {
                    Ok(bytes) => Str.from_utf8(bytes).map_err(|_| UnreadableInput)
                    Err(_) => Err(UnreadableInput)
                }
            } else {
                Path.read_utf8!(Path.utf8(src)).map_err(|_| UnreadableInput)
            }
        match text_result {
            Err(UnreadableInput) => Output.err_out!("unreadable_file", "couldn't read ${label} — pass a file holding the JSON Strava's connector returned, or `-` to read it from stdin")
            Err(other) => Err(other)
            Ok(text) =>
                match StravaLog.split_input(text) {
                    Err(NotJson(why)) => Output.err_out!("bad_json", "${label} ${why} — expected the JSON Strava's connector returns: a workout { activity_id, exercise_sets: [...] } or a list of them")
                    Ok(pieces) => {
                        stamp = Metrics.epoch_to_iso(Db.now_secs!({}))
                        walked = import_workouts!(db, stamp, pieces, { imported: [], skipped: [], seen: [] })?
                        Analyze.rebuild_strength_sets!(db)?
                        outcome : StrengthImportOutcome
                        outcome = { imported: walked.imported, skipped: walked.skipped }
                        Output.out!(outcome, |o| strength_import_screen(o))
                    }
                }
        }
    }

    import_workouts! : Str, Str, List(Str), { imported : List(StrengthImported), skipped : List(StrengthSkipped), seen : List(I64) } => Try({ imported : List(StrengthImported), skipped : List(StrengthSkipped), seen : List(I64) }, _)
    import_workouts! = |db, stamp, pieces, acc|
        match pieces {
            [] => Ok(acc)
            [piece, .. as rest] => {
                raw_id = StravaLog.activity_id_of(piece)
                skip = |reason, dropped| { ..acc, skipped: List.append(acc.skipped, { activity_id: raw_id, reason, dropped }) }
                next =
                    match StravaLog.decode_workout(piece) {
                        Err(_) => skip("undecodable_workout", [])
                        Ok(w) =>
                            match Metrics.arg_i64(raw_id) {
                                Err(_) => skip("bad_activity_id", [])
                                Ok(aid) =>
                                    if aid <= 0 {
                                        skip("bad_activity_id", [])
                                    } else if List.contains(acc.seen, aid) {
                                        skip("duplicate_activity", [])
                                    } else {
                                        placed = { ..acc, seen: List.append(acc.seen, aid) }
                                        fams = Sqlite.query_many!({
                                            path: Path.utf8(db),
                                            query: "SELECT CAST(fam AS TEXT) AS fam FROM activity_family_month WHERE activity_id = :id",
                                            bindings: [{ name: ":id", value: Integer(aid) }],
                                            rows: Sqlite.str("fam"),
                                        })?
                                        skip_placed = |reason, dropped| { ..placed, skipped: List.append(placed.skipped, { activity_id: raw_id, reason, dropped }) }
                                        match fams {
                                            [] => skip_placed("unknown_activity", [])
                                            [fam, ..] =>
                                                if fam != "WeightTraining" {
                                                    skip_placed("not_strength", [])
                                                } else if List.is_empty(w.exercise_sets) {
                                                    skip_placed("no_sets", [])
                                                } else {
                                                    got = StravaLog.read(w)
                                                    if List.is_empty(got.rows) {
                                                        skip_placed("no_usable_sets", got.dropped)
                                                    } else {
                                                        Sqlite.execute!({
                                                            path: Path.utf8(db),
                                                            query: "INSERT OR REPLACE INTO strength_logs (activity_id, payload, imported_at) VALUES (:id, :p, :at)",
                                                            bindings: [
                                                                { name: ":id", value: Integer(aid) },
                                                                { name: ":p", value: String(piece) },
                                                                { name: ":at", value: String(stamp) },
                                                            ],
                                                        })?
                                                        sets = List.fold(got.rows, 0, |n, r| n + r.sets)
                                                        entry = { activity_id: aid, rows: List.len(got.rows).to_i64_wrap(), sets, dropped: got.dropped, zeroed: got.zeroed }
                                                        { ..placed, imported: List.append(placed.imported, entry) }
                                                    }
                                                }
                                        }
                                    }
                            }
                    }
                import_workouts!(db, stamp, rest, next)
            }
        }

    strength_import_screen : StrengthImportOutcome -> Str
    strength_import_screen = |o| {
        dropped_lines = |ds| List.map(ds, |d| {
            name = if d.exercise == "" "no exercise name" else d.exercise
            "  left out set ${d.set.to_str()} (${name}): ${d.reason}"
        })
        # consecutive zeroed sets of one exercise at one recorded weight read as
        # one line, the way they fold into one row
        zeroed_lines = |zs| {
            runs = List.fold(zs, [], |acc, z|
                match List.last(acc) {
                    Ok(prev) if prev.exercise == z.exercise and prev.recorded == z.recorded => List.append(List.drop_last(acc, 1), { ..prev, n: prev.n + 1 })
                    _ => List.append(acc, { exercise: z.exercise, recorded: z.recorded, n: 1 })
                })
            List.map(runs, |r| "  counted at 0 kg as bodyweight: ${r.exercise}, ${counted(r.n, "set")} (recorded ${r.recorded})")
        }
        imported = List.join(List.map(o.imported, |i| List.join([["imported ${(i.activity_id).to_str()}: ${counted(i.rows, "row")}, ${counted(i.sets, "set")}"], zeroed_lines(i.zeroed), dropped_lines(i.dropped)])))
        skipped = List.join(List.map(o.skipped, |s| {
            id = if s.activity_id == "" "(no activity_id)" else s.activity_id
            List.concat(["skipped ${id}: ${s.reason}"], dropped_lines(s.dropped))
        }))
        lines = List.concat(imported, skipped)
        if List.is_empty(lines) "nothing to import — the input held no workouts" else Str.join_with(lines, "\n")
    }

    counted : I64, Str -> Str
    counted = |n, noun| if n == 1 "1 ${noun}" else "${n.to_str()} ${noun}s"
}
