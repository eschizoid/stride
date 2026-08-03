import pf.Sqlite
import pf.Cmd
import pf.Env
import pf.Utc
import pf.OsStr
import pf.Path
import Schema
import Metrics

Db :: [].{
    # ── paths ────────────────────────────────────────────────────────────

    # home directory, cross-platform: HOME on unix, USERPROFILE on Windows (where HOME
    # is usually unset). Without this every command would fail on Windows before opening
    # the db, even though we now target it.
    home_dir! : {} => Try(Str, _)
    home_dir! = |{}|
        match Env.var_str!(OsStr.from_str("HOME")) {
            Ok(h) if !(Str.is_empty(h)) => Ok(h)
            _ => Env.var_str!(OsStr.from_str("USERPROFILE"))
        }

    db_path! : {} => Try(Str, _)
    db_path! = |{}| {
        home = home_dir!({})?
        Ok("${home}/.stride/db.sqlite")
    }
    # owner-only permissions on the credential store. basic-cli 0.20 has no mode API,
    # so shell out; best-effort (never fails the command — a platform without chmod
    # just doesn't get hardened, and we don't claim it did). Sidecars may not exist.
    secure_perms! : Str => Try({}, _)
    secure_perms! = |dir| {
        # dir is the sh -c positional $1 (double-quoted), never interpolated, so a path
        # with a quote or shell metachar can't break out — same pattern as zone_offset_now!.
        cmd = "chmod 700 \"$1\" 2>/dev/null; chmod 600 \"$1/db.sqlite\" \"$1/db.sqlite-wal\" \"$1/db.sqlite-shm\" \"$1/db.sqlite-journal\" 2>/dev/null; true"
        _ = Cmd.new(OsStr.from_str("sh")).args(List.map(["-c", cmd, "sh", dir], OsStr.from_str)).exec_output!()
        Ok({})
    }
    # ── config key-value helpers ─────────────────────────────────────────

    config_get! : Str, Str => Try(Str, _)
    config_get! = |path, key|
        Sqlite.query!({
            path: Path.utf8(path),
            query: "SELECT value FROM config WHERE key = :key",
            bindings: [{ name: ":key", value: String(key) }],
            row: Sqlite.str("value"),
        })

    # read a config key, distinguishing "genuinely absent" from "the db read failed"
    # — so a locked/corrupt db surfaces as a real error instead of masquerading as
    # "not set" / "not authenticated" / "set your FTP".
    config_opt! : Str, Str => Try([Found(Str), NotFound], _)
    config_opt! = |path, key|
        match config_get!(path, key) {
            Ok(v) => Ok(Found(v))
            Err(NoRowsReturned) => Ok(NotFound)
            Err(other) => Err(other)

        }
    config_set! : Str, Str, Str => Try({}, _)
    config_set! = |path, key, value|
        Sqlite.execute!({
            path: Path.utf8(path),
            query: "INSERT OR REPLACE INTO config (key, value) VALUES (:key, :value)",
            bindings: [
                { name: ":key", value: String(key) },
                { name: ":value", value: String(value) },
            ],
        })

    now_secs! : {} => I64
    now_secs! = |{}| {
        millis = Utc.to_millis_since_epoch(Utc.now!())
        (millis // 1000).to_i64_wrap()
    }
    # How "today"'s civil-day boundary is anchored. The platform clock (Utc.now!) is
    # UTC-only, but every activity date is Strava's local civil date — so for any user
    # west of UTC, the UTC day rolls over hours before their local day, inserting a
    # phantom "tomorrow" into the load series each evening.
    #   Zone       — config `timezone` (IANA, e.g. America/Chicago): DST-correct for
    #                the CURRENT date via the system tz database. Preferred.
    #   FixedOffset — config `utc_offset_minutes`: a fixed offset; set it seasonally
    #                if you observe DST (e.g. -300 CDT / -360 CST).
    #   BadZone    — `timezone` is set but the name isn't in the system tz database;
    #                we fall back to the fixed offset (NEVER silently to UTC) and warn.
    #   Utc        — neither configured.
    TimeMode : [Zone(Str, I64), FixedOffset(I64), BadZone(Str, I64), Utc]

    # Read the current DST-correct offset (minutes east of UTC) for an IANA zone by
    # validating it against the system tz database, then reading `date +%z`. An
    # unknown name yields Err — we never let a typo silently become +0000 (UTC).
    zone_offset_now! : Str => Try(I64, [BadTz])
    zone_offset_now! = |tz| {
        # tz is passed as the positional $1 (never interpolated) so a crafted timezone
        # string can't break out of the quoting or inject shell syntax.
        cmd = "if [ -f \"/usr/share/zoneinfo/$1\" ]; then TZ=\"$1\" date +%z; else echo INVALID; fi"
        match Cmd.new(OsStr.from_str("sh")).args(List.map(["-c", cmd, "sh", tz], OsStr.from_str)).exec_output!() {
            Ok(out) => Metrics.parse_utc_offset(out.stdout_utf8).map_err(|_| BadTz)
            Err(_) => Err(BadTz)

        }
    }
    resolve_time_mode! : Str => TimeMode
    resolve_time_mode! = |path| {
        fixed : Try(I64, [NoFixed])
        fixed =
            match config_get!(path, "utc_offset_minutes") {
                Ok(s) => Ok(I64.from_str(s).ok_or(0))
                Err(_) => Err(NoFixed)
            }
        tz =
            match config_get!(path, "timezone") {
                Ok(t) if t != "" => Ok(t)
                _ => Err(NoTz)
            }
        match tz {
            Ok(name) =>
                match zone_offset_now!(name) {
                    Ok(off) => Zone(name, off)
                    Err(_) => BadZone(name, fixed.ok_or(0))
                }
            Err(_) =>
                match fixed {
                    Ok(off) => FixedOffset(off)
                    Err(_) => Utc
                }
        }
    }
    time_mode_offset : TimeMode -> I64
    time_mode_offset = |mode|
        match mode {
            Zone(_, off) => off
            FixedOffset(off) => off
            BadZone(_, off) => off
            Utc => 0

        }
    # minutes east of UTC => "±HH:MM" for display
    fmt_offset : I64 -> Str
    fmt_offset = |m| {
        a = (m).abs()
        pad = |n| if n < 10 "0${(n).to_str()}" else (n).to_str()
        "${if m < 0 "-" else "+"}${pad(a // 60)}:${pad(a % 60)}"
    }
    local_today_days! : Str => I64
    local_today_days! = |path| {
        mode = resolve_time_mode!(path)
        (now_secs!({}) + time_mode_offset(mode) * 60) // 86400
    }

    # the power threshold (FTP) a sport's power is judged against. DERIVED, never
    # configured: it's that sport's own best 20-min power × 0.95 — the standard FTP
    # estimate. The engine is sport-agnostic and figures FTP out per sport from the data,
    # so there's nothing to set. 0 when the sport has no power history, in which case
    # intensity/TSS fall back to HR.
    sport_ftp! : Str, Str => Try(F64, _)
    sport_ftp! = |path, sport| {
        raw = derive_sport_ftp!(path, sport)?
        # whole watts — keeps the stored ftp_used and the invalidation CASE exactly equal
        Ok(((raw).round_to_i64_try().ok_or(0)).to_f64())
    }
    derive_sport_ftp! : Str, Str => Try(F64, _)
    derive_sport_ftp! = |path, sport| {
        best = Sqlite.query!({
            path: Path.utf8(path),
            query: "SELECT CAST(COALESCE(MAX(m.best_20min_w), 0) AS REAL) AS b FROM activity_metrics m JOIN activities a ON a.id = m.activity_id WHERE a.sport_type = :sport",
            bindings: [{ name: ":sport", value: String(sport) }],
            row: Sqlite.f64("b"),
        })?
        Ok(best * 0.95)
    }
    # ── migrations ───────────────────────────────────────────────────────

    # bump when the schema changes; ensure_schema! re-runs migrations when the db's
    # PRAGMA user_version is behind this. (The additive ALTERs below are the columns
    # that post-date the original CREATE statements in Schema.roc.)
    schema_version = 11

    run_migrations! : Str => Try({}, _)
    run_migrations! = |path| {
        # v5: prescriptions => planned_sessions ("a coach plans sessions" — the
        # medical word is gone). MUST run before the CREATEs below, or an empty
        # planned_sessions would shadow the old data.
        rename_table_if_exists!(path, "prescriptions", "planned_sessions")?
        Sqlite.execute!({ path: Path.utf8(path), query: Schema.activities, bindings: [] })?
        Sqlite.execute!({ path: Path.utf8(path), query: Schema.metrics, bindings: [] })?
        Sqlite.execute!({ path: Path.utf8(path), query: Schema.daily_load, bindings: [] })?
        Sqlite.execute!({ path: Path.utf8(path), query: Schema.planned_sessions, bindings: [] })?
        Sqlite.execute!({ path: Path.utf8(path), query: Schema.config, bindings: [] })?
        Sqlite.execute!({ path: Path.utf8(path), query: Schema.streams, bindings: [] })?
        Sqlite.execute!({ path: Path.utf8(path), query: Schema.ratings, bindings: [] })?
        alter_add_column!(path, "ALTER TABLE activities ADD COLUMN weighted_avg_watts REAL")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN best_20min_w REAL")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN ftp_used REAL")?
        alter_add_column!(path, "ALTER TABLE planned_sessions ADD COLUMN status TEXT")?
        alter_add_column!(path, "ALTER TABLE planned_sessions ADD COLUMN skipped_reason TEXT")?
        # v3: metrics record the HR zone bounds they were computed with, so a zone-
        # config change invalidates + recomputes (like ftp_used does for FTP)
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN zones_used TEXT")?
        # v4: metrics record the algorithm revision they were computed with, so a
        # change to the math itself (metrics_rev bump) invalidates + recomputes
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN metrics_rev INTEGER")?
        # v6: metrics record WHICH ladder rung scored them (load provenance)
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN load_model TEXT")?
        # v8: drop load_confidence — it was a pure function of load_model (v7), so storing
        # it was redundant denormalization. Confidence is now derived from load_model at
        # read time (doctor). The drop cleans up dbs that got the v7 column.
        drop_column_if_exists!(path, "ALTER TABLE activity_metrics DROP COLUMN load_confidence")?
        # v9: time-in-intensity from POWER (easy/moderate/hard seconds), judged against the
        # sport's own FTP — the truer "how hard" for power sports than HR zones
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN pi_easy_s INTEGER")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN pi_moderate_s INTEGER")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN pi_hard_s INTEGER")?
        # v10: FTP is now per-sport under `ftp_<sport>` (uniform, no special cycling key).
        # Move the old cycling `ftp` value to `ftp_ride` if it hasn't been set already.
        Sqlite.execute!({ path: Path.utf8(path), query: "UPDATE config SET key = 'ftp_ride' WHERE key = 'ftp' AND (SELECT COUNT(*) FROM config WHERE key = 'ftp_ride') = 0", bindings: [] })?
        # v11: synced_at stamps each activity with the sync run that last saw it, so a
        # sync can prune activities deleted on Strava — any row in the pulled window not
        # re-stamped this run is gone upstream. Mirror tier (activities) is re-pullable.
        alter_add_column!(path, "ALTER TABLE activities ADD COLUMN synced_at INTEGER")?
        # v2: index the column every date-range filter and the activities sort use
        # (queries now compare a.start_local directly — sargable — instead of substr)
        Sqlite.execute!({ path: Path.utf8(path), query: "CREATE INDEX IF NOT EXISTS idx_activities_start ON activities(start_local)", bindings: [] })
    }

    # rename old => new when old exists and new doesn't (idempotent, data-preserving)
    rename_table_if_exists! : Str, Str, Str => Try({}, _)
    rename_table_if_exists! = |path, old, new| {
        count = Sqlite.query!({
            path: Path.utf8(path),
            query: "SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name = :old",
            bindings: [{ name: ":old", value: String(old) }],
            row: Sqlite.i64("n"),
        })?
        if count > 0
            Sqlite.execute!({ path: Path.utf8(path), query: "ALTER TABLE ${old} RENAME TO ${new}", bindings: [] })
        else
            Ok({})
    }
    # an additive ADD COLUMN. Swallows ONLY "duplicate column" (the expected re-run
    # case); a locked db, disk error, etc. propagate instead of failing silently.
    alter_add_column! : Str, Str => Try({}, _)
    alter_add_column! = |path, q|
        match Sqlite.execute!({ path: Path.utf8(path), query: q, bindings: [] }) {
            Ok({}) => Ok({})
            Err(SqliteErr(Error, msg)) =>
                if Str.contains(msg, "duplicate column") Ok({}) else Err(SqliteErr(Error, msg))
            Err(other) => Err(other)

        }
    # idempotent column drop: a db that never had the column (fresh, or already dropped)
    # reports "no such column" — that's the converged state, not a failure.
    drop_column_if_exists! : Str, Str => Try({}, _)
    drop_column_if_exists! = |path, q|
        match Sqlite.execute!({ path: Path.utf8(path), query: q, bindings: [] }) {
            Ok({}) => Ok({})
            Err(SqliteErr(Error, msg)) =>
                if Str.contains(msg, "no such column") Ok({}) else Err(SqliteErr(Error, msg))
            Err(other) => Err(other)

        }
    # run migrations exactly when the db is behind, then stamp the version. Called
    # on every command entry (via open_db!) so upgrading the binary against an
    # existing db self-migrates instead of failing with an opaque missing-column error.
    ensure_schema! : Str => Try({}, _)
    ensure_schema! = |path| {
        v = (Sqlite.query!({
                path: Path.utf8(path),
                query: "SELECT user_version AS v FROM pragma_user_version()",
                bindings: [],
                row: Sqlite.i64("v"),
            })).ok_or(0)
        if v >= schema_version {
            Ok({})
        } else {
            run_migrations!(path)?
            Sqlite.execute!({ path: Path.utf8(path), query: "PRAGMA user_version = ${(schema_version).to_str()}", bindings: [] })
        }
    }
    # db path + guaranteed-current schema. Every command opens through this.
    open_db! : {} => Try(Str, _)
    open_db! = |{}| {
        p = db_path!({})?
        ensure_schema!(p)?
        # harden on every open so existing world-readable installs get fixed too
        home = home_dir!({})?
        secure_perms!("${home}/.stride")?
        Ok(p)
    }
    # (schema DDL lives in Schema.roc — pure strings, the one kind of SQL that
    #  can move out of the app module without splitting a query from its decoder)
}
