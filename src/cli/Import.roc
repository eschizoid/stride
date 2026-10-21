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
    # Each workout lands in strength_logs (one row per activity, replaced on
    # re-import), and strength_sets is rebuilt once at the end so the rows are
    # there without an analyze. A workout that cannot be placed is a SKIPPED
    # entry with its reason, never an error: one stale id in a batch must not
    # cost the rest of it. Only input that is not such JSON at all, or a file
    # that cannot be read, fails the command.
    StrengthImported : { activity_id : I64, rows : I64, sets : I64 }
    StrengthSkipped : { activity_id : Str, reason : Str }
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
                match StravaLog.decode_import(text) {
                    Err(NotWorkouts) => Output.err_out!("bad_json", "${label} is not a strength workout or a list of them — expected the JSON Strava's connector returns: { activity_id, exercise_sets: [...] }")
                    Ok(workouts) => {
                        stamp = Metrics.epoch_to_iso(Db.now_secs!({}))
                        outcome = import_workouts!(db, stamp, workouts, { imported: [], skipped: [] })?
                        Analyze.rebuild_strength_sets!(db)?
                        Output.out!(outcome, |o| strength_import_screen(o))
                    }
                }
        }
    }

    import_workouts! : Str, Str, List(StravaLog.Workout), StrengthImportOutcome => Try(StrengthImportOutcome, _)
    import_workouts! = |db, stamp, workouts, acc|
        match workouts {
            [] => Ok(acc)
            [w, .. as rest] => {
                raw_id = w.activity_id.ok_or("")
                skip = |reason| { ..acc, skipped: List.append(acc.skipped, { activity_id: raw_id, reason }) }
                next =
                    match Metrics.arg_i64(raw_id) {
                        Err(_) => skip("bad_activity_id")
                        Ok(aid) =>
                            if aid <= 0 {
                                skip("bad_activity_id")
                            } else if !(Report.row_exists!(db, "activities", aid)?) {
                                skip("unknown_activity")
                            } else {
                                rows = StravaLog.rows(w)
                                if List.is_empty(rows) {
                                    skip("no_sets")
                                } else {
                                    Sqlite.execute!({
                                        path: Path.utf8(db),
                                        query: "INSERT OR REPLACE INTO strength_logs (activity_id, payload, imported_at) VALUES (:id, :p, :at)",
                                        bindings: [
                                            { name: ":id", value: Integer(aid) },
                                            { name: ":p", value: String(StravaLog.encode(w)) },
                                            { name: ":at", value: String(stamp) },
                                        ],
                                    })?
                                    sets = List.fold(rows, 0, |n, r| n + r.sets)
                                    { ..acc, imported: List.append(acc.imported, { activity_id: aid, rows: List.len(rows).to_i64_wrap(), sets }) }
                                }
                            }
                    }
                import_workouts!(db, stamp, rest, next)
            }
        }

    strength_import_screen : StrengthImportOutcome -> Str
    strength_import_screen = |o| {
        imported = List.map(o.imported, |i| "imported ${(i.activity_id).to_str()}: ${(i.rows).to_str()} rows, ${(i.sets).to_str()} sets")
        skipped = List.map(o.skipped, |s| {
            id = if s.activity_id == "" "(no activity_id)" else s.activity_id
            "skipped ${id}: ${s.reason}"
        })
        lines = List.concat(imported, skipped)
        if List.is_empty(lines) "nothing to import — the input held no workouts" else Str.join_with(lines, "\n")
    }
}
