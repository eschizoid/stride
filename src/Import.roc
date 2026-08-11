import Db
import Output
import Strava
import Report
import Csv
import pf.Sqlite
import pf.Cmd
import pf.OsStr
import pf.Path
import pf.Stdout

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
                match Report.export_row_to_summary(headers, row) {
                    Ok(summary) => {
                        # stamp 0 → synced_at stays NULL: CSV imports were never on Strava,
                        # so a later sync's prune must never treat them as deletions
                        # import counts its own rows; the insert/update/unchanged split
                        # only means something for a sync against Strava
                        _ = Strava.upsert_activity!(db, 0, summary)?
                        import_rows!(db, headers, rest, { ..acc, imported: acc.imported + 1 })
                    }
                    Err(_) =>
                        import_rows!(db, headers, rest, { ..acc, skipped: acc.skipped + 1 })

                }
        }
}
