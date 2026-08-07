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
import ActivityHelper

Import :: [].{
    # ── import from a Strava account export (no API credentials needed) ──
    # Summary rows from activities.csv go through the SAME upsert as sync. Each row's
    # Filename member is then decoded (FIT/FIT.GZ/GPX) into the SAME stream model as API
    # sync — still fully offline, idempotent, and with metrics invalidation intact.
    import_archive! : Str => Try({}, _)
    import_archive! = |src| {
        db = Db.open_db!({})?
        text_result =
            if Str.ends_with(Str.with_ascii_lowercased(src), ".zip") {
                # Read only the manifest here. Activity members are streamed one at a time
                # later; the archive is never expanded wholesale into /tmp.
                # `src` is a process argument, never shell-interpolated.
                match Cmd.new(OsStr.from_str("unzip")).args(List.map(["-p", "-q", src, "activities.csv"], OsStr.from_str)).exec_output!() {
                    Ok(out) => Ok(out.stdout_utf8)
                    Err(_) => Err(UnzipFailed)
                }
            }
            else {
                csv_path = "${src}/activities.csv"
                match Path.read_utf8!(Path.utf8(csv_path)) {
                    Ok(text) => Ok(text)
                    Err(_) => Err(NoActivitiesCsv)
                }
            }
        match text_result {
            Err(UnzipFailed) => Output.err_out!("unzip_failed", "couldn't read activities.csv from ${src} — is this a Strava export, and is `unzip` installed? (or extract it yourself and `stride import <dir>`)")
            Err(NoActivitiesCsv) => Output.err_out!("no_activities_csv", "no activities.csv in ${src} — point me at a Strava account export (Settings → My Account → Download or Delete Your Account)")
            Ok(text) =>
                match Csv.records(text) {
                    [header_text, .. as records] =>
                        match Csv.parse(header_text) {
                            [headers] => {
                                source = if Str.ends_with(Str.with_ascii_lowercased(src), ".zip") Archive(src) else Directory(src)
                                counts = import_records!(db, source, headers, records, { imported: 0.U64, skipped: 0.U64, streams_imported: 0.U64, streams_skipped: 0.U64 })?
                                if Output.json_mode!({})
                                    Output.emit_ok!(counts)
                                else
                                    Stdout.line!("imported ${(counts.imported).to_str()} activities + ${(counts.streams_imported).to_str()} stream files (${(counts.skipped).to_str()} rows skipped, ${(counts.streams_skipped).to_str()} stream files unavailable) — run `stride analyze` to compute metrics")
                            }
                            _ => Output.err_out!("empty_csv", "activities.csv has no header")
                        }
                    _ => Output.err_out!("empty_csv", "activities.csv is empty")

                }
            }
    }
    import_records! = |db, source, headers, records, acc|
        match records {
            [] => Ok(acc)
            _ => {
                # Bound effectful recursion: the current Linux compiler does not reliably
                # eliminate this stack while unwinding hundreds of SQLite writes. Real
                # exports completed every INSERT and then segfaulted before reporting the
                # count. Batches cap the inner stack at 64 and the outer stack at ~N/64.
                split = take_records(records, 64, [])
                next = import_record_batch!(db, source, headers, split.batch, acc)?
                import_records!(db, source, headers, split.rest, next)
            }
        }

    import_record_batch! = |db, source, headers, records, acc|
        match records {
            [] => Ok(acc)
            [record, .. as rest] => {
                # The external decoder stores one stream at a time, so this frame retains
                # only the small import counters before the recursive batch step.
                next = import_one!(db, source, headers, record, acc)?
                import_record_batch!(db, source, headers, rest, next)
            }
        }

    import_one! = |db, source, headers, record, acc|
        match Csv.parse(record) {
            [row] =>
                match Report.export_row_to_summary(headers, row) {
                    Ok(summary) => {
                        # stamp 0 → synced_at stays NULL: CSV imports were never on Strava,
                        # so a later sync's prune must never treat them as deletions
                        Strava.upsert_activity!(db, 0, summary)?
                        filename = row_field(headers, row, "Filename")
                        match import_activity_stream!(db, summary.id, source, filename) {
                            Ok(_) => {
                                Ok({ ..acc, imported: acc.imported + 1, streams_imported: acc.streams_imported + 1 })
                            }
                            Err(_) => Ok({ ..acc, imported: acc.imported + 1, streams_skipped: acc.streams_skipped + 1 })
                        }
                    }
                    Err(_) => Ok({ ..acc, skipped: acc.skipped + 1 })
                }
            _ => Ok({ ..acc, skipped: acc.skipped + 1 })
        }

    row_field = |headers, row, name|
        match Csv.column_index(headers, name, 0) {
            Ok(i) => (List.get(row, i)).ok_or("")
            Err(_) => ""
        }

    # The Filename column is untrusted archive content. For ZIPs it is passed as one
    # argv value (never interpolated); for directories this validation also prevents a
    # row from escaping the selected export root.
    safe_activity_member : Str -> Bool
    safe_activity_member = |filename| {
        lower = Str.with_ascii_lowercased(filename)
        Str.starts_with(lower, "activities/")
            and !(Str.contains(filename, ".."))
            and !(Str.contains(filename, "\\"))
            and (Str.ends_with(lower, ".fit") or Str.ends_with(lower, ".fit.gz") or Str.ends_with(lower, ".gpx"))
    }

    import_activity_stream! = |db, activity_id, source, filename| {
        if !safe_activity_member(filename) {
            Err(UnsupportedActivityFile)
        } else {
            decoder = ActivityHelper.decoder_path!({})?
            source_path = match source { Archive(path) => path  Directory(path) => path }
            Cmd.new(OsStr.from_str("python3")).args(List.map([decoder, "--store", db, source_path, filename, I64.to_str(activity_id)], OsStr.from_str)).exec_cmd!().map_err(|_| ActivityReadFailed)
        }
    }

    take_records : List(Str), U64, List(Str) -> { batch : List(Str), rest : List(Str) }
    take_records = |records, left, rev|
        if left == 0
            { batch: List.fold(rev, [], |acc, record| List.prepend(acc, record)), rest: records }
        else
            match records {
                [] => { batch: List.fold(rev, [], |acc, record| List.prepend(acc, record)), rest: [] }
                [record, .. as rest] => take_records(rest, left - 1, List.prepend(rev, record))
            }
}
