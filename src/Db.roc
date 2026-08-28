import pf.Sqlite
import pf.Cmd
import pf.Env
import pf.Utc
import pf.OsStr
import pf.Path
import Schema
import Metrics
import Sports

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
    # owner-only permissions on the credential store. basic-cli has no mode API (checked through 0.22),
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
            # CAST(... AS TEXT), and the reason is a real divergence rather than defensive
            # habit. `value` is declared TEXT, and TEXT affinity converts INTEGER and REAL
            # but NOT blobs — so a blob written by a hand-edit or a partial corruption
            # survives in the column, and a bare `Sqlite.str` decode then answers
            # `UnexpectedType(Bytes)`, which `config get` reports as `internal_error`:
            # "this is a bug, not the data and not the invocation", about a fault that is
            # entirely the data. It also made this path disagree with bare `config`, which
            # asks SQL whether a row holds a value and would list a key `config get` then
            # refused. One rule, decided in one place.
            query: "SELECT COALESCE(CAST(value AS TEXT), '') AS value FROM config WHERE key = :key",
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
    # Remove a config row outright. Used by `config set <unrecognised> ""` (#254), which is
    # the way out for a row the engine no longer reads.
    #
    # DELETE and not `value = ''`, which is worse than doing nothing for the family
    # that most needs this. `Analyze.load_config!` requires every key
    # starting `hr_z` to parse as F64, so one empty zone row kills `analyze` outright — and
    # the misspelled zone keys are exactly the population #254's tightened `zone_shape`
    # created. The write also could not reach them: `numeric_key` classifies `hr_z*` as
    # Decimal, so the empty value was refused with `bad_value` before it got there.
    #
    # It is also the argument this repo already made once, in the e2e comment beside the
    # timezone fixture: delete the row rather than storing '', "because an absent row is
    # the state a fresh install is actually in".
    config_delete! : Str, Str => Try({}, _)
    config_delete! = |path, key|
        Sqlite.execute!({
            path: Path.utf8(path),
            query: "DELETE FROM config WHERE key = :key",
            bindings: [{ name: ":key", value: String(key) }],
        })

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
    # BadOffset carries the STORED TEXT, not a number, because there is no number to
    # carry -- that is the whole point. An unreadable `utc_offset_minutes` used to be
    # coalesced to 0, which is indistinguishable from a real UTC offset, so a typo read
    # as "you are on UTC" and silently shifted every civil-day boundary (#206). It is
    # the offset twin of BadZone: report it, do not guess it.
    TimeMode : [Zone(Str, I64), FixedOffset(I64), BadZone(Str, I64), BadOffset(Str), Utc]

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
        # An unreadable value is NOT NoFixed and NOT zero: those both mean "carry on",
        # and carrying on is what made #206 silent. Keep the raw text so doctor can name it.
        fixed : Try(I64, [NoFixed, Unreadable(Str)])
        fixed =
            match config_get!(path, "utc_offset_minutes") {
                Ok(s) =>
                    match Metrics.arg_i64(s) {
                        Ok(n) => Ok(n)
                        Err(_) => Err(Unreadable(s))
                    }

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
                    # a bad zone falls back to the fixed offset, but only a READABLE one
                    Err(_) => BadZone(name, fixed.ok_or(0))
                }
            Err(_) =>
                match fixed {
                    Ok(off) => FixedOffset(off)
                    Err(Unreadable(raw)) => BadOffset(raw)
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
            # 0 is the only safe arithmetic fallback, but unlike Utc it is REPORTED as a
            # fault (time_ok false) rather than presented as a deliberate UTC setting.
            BadOffset(_) => 0
            Utc => 0

        }
    # minutes east of UTC => "±HH:MM" for display
    fmt_offset : I64 -> Str
    fmt_offset = |m| {
        a = (m).abs()
        pad = |n| if n < 10 "0${(n).to_str()}" else (n).to_str()
        "${if m < 0 "-" else "+"}${pad(a // 60)}:${pad(a % 60)}"
    }
    # UTC day number, for the one thing that is anchored to UTC rather than to the
    # athlete's calendar: Strava's daily read cap. Everything else in stride uses
    # local_today_days! below, because a training day is a local-calendar fact — but the
    # cap resets at UTC midnight regardless of where you live, so counting reads against
    # a local day would reset the counter at the wrong moment by exactly the UTC offset.
    utc_today_days! : {} => I64
    utc_today_days! = |{}| now_secs!({}) // 86400

    local_today_days! : Str => I64
    local_today_days! = |path| {
        mode = resolve_time_mode!(path)
        (now_secs!({}) + time_mode_offset(mode) * 60) // 86400
    }

    # the power threshold (FTP) a sport's power is judged against. DERIVED, never
    # configured: the sport FAMILY's best 20-min power × 0.95 — the standard FTP
    # estimate, over one fitness pool per family (#151: a gravel 20-min effort IS
    # bike fitness). The engine is sport-agnostic and derives it from the data, so
    # there's nothing to set. 0 when the family has no power history, in which case
    # intensity/TSS fall back to HR.
    sport_ftp! : Str, Str => Try(F64, _)
    sport_ftp! = |path, sport| {
        raw = derive_sport_ftp!(path, sport)?
        # whole watts — keeps the stored ftp_used and the invalidation CASE exactly equal
        Ok(((raw).round_to_i64_try().ok_or(0)).to_f64())
    }
    derive_sport_ftp! : Str, Str => Try(F64, _)
    derive_sport_ftp! = |path, sport| {
        # RECENT form: best 20-min power over the last 60 days, not all-time. An old peak
        # shouldn't keep judging today's rides as easy — FTP tracks current fitness.
        cutoff = Metrics.days_to_date_str(local_today_days!(path) - 60)
        best = Sqlite.query!({
            path: Path.utf8(path),
            # family population (#151): compare the STORED sport_family column —
            # the canonical head is computed in Roc and bound, keeping the
            # predicate sargable (same rule period_ftp_sql uses in Analyze)
            query: "SELECT CAST(COALESCE(MAX(m.best_20min_w), 0) AS REAL) AS b FROM activity_metrics m JOIN activities a ON a.id = m.activity_id WHERE a.sport_family = :fam AND a.start_local >= :cutoff",
            bindings: [{ name: ":fam", value: String(Sports.canonical(sport)) }, { name: ":cutoff", value: String(cutoff) }],
            row: Sqlite.f64("b"),
        })?
        Ok(Metrics.ftp_from_best_20min(best))
    }
    # ── migrations ───────────────────────────────────────────────────────

    # bump when the schema changes; ensure_schema! re-runs migrations when the db's
    # PRAGMA user_version is behind this. (The additive ALTERs below are the columns
    # that post-date the original CREATE statements in Schema.roc.)
    schema_version = 25

    run_migrations! : Str => Try({}, _)
    run_migrations! = |path| {
        # v5: prescriptions => planned_sessions ("a coach plans sessions" — the
        # medical word is gone). MUST run before the CREATEs below, or an empty
        # planned_sessions would shadow the old data.
        rename_table_if_exists!(path, "prescriptions", "planned_sessions")?
        Sqlite.execute!({ path: Path.utf8(path), query: Schema.activities, bindings: [] })?
        Sqlite.execute!({ path: Path.utf8(path), query: Schema.metrics, bindings: [] })?
        Sqlite.execute!({ path: Path.utf8(path), query: Schema.segments, bindings: [] })?
        Sqlite.execute!({ path: Path.utf8(path), query: Schema.daily_load, bindings: [] })?
        Sqlite.execute!({ path: Path.utf8(path), query: Schema.planned_sessions, bindings: [] })?
        Sqlite.execute!({ path: Path.utf8(path), query: Schema.config, bindings: [] })?
        Sqlite.execute!({ path: Path.utf8(path), query: Schema.streams, bindings: [] })?
        Sqlite.execute!({ path: Path.utf8(path), query: Schema.ratings, bindings: [] })?
        alter_add_column!(path, "ALTER TABLE activities ADD COLUMN weighted_avg_watts REAL")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN best_20min_w REAL")?
        # v21: which signal produced decoupling_pct — provenance stored at analyze
        # time (like load_model), because re-deriving it at render time from the
        # stream mislabels estimated-watts sessions and re-pull windows (#142 retro)
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN decoupling_signal TEXT")?
        # v22: a skip can name the activity that replaced the plan (#144) —
        # judgment-tier provenance; a substitution is NOT a completion
        alter_add_column!(path, "ALTER TABLE planned_sessions ADD COLUMN substitute_activity_id INTEGER")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN ftp_used REAL")?
        alter_add_column!(path, "ALTER TABLE planned_sessions ADD COLUMN status TEXT")?
        alter_add_column!(path, "ALTER TABLE planned_sessions ADD COLUMN skipped_reason TEXT")?
        # #274: what `complete` erased. Before this, an overwrite was REPORTED — `#258` made
        # the payload name `replaced_activity` and the human line print the command that
        # restores it — but the record lived in one line of stdout, once. `week` and `plan`
        # show the new `completed_activity_id`; the old one was gone from the row, so an
        # athlete who notices a week later has shell scrollback and nothing else. That is
        # the scenario the original report opens with, a typo'd session id.
        #
        # The narrow form deliberately: LAST value only, on the row. An audit table would
        # also cover repeated overwrites and the cross-session `ReleasedFrom` case, at the
        # cost of a table nothing else reads. One column is enough for the typo, and #258's
        # invertibility argument is already scoped to "this session's completion".
        alter_add_column!(path, "ALTER TABLE planned_sessions ADD COLUMN superseded_activity_id INTEGER")?
        # v3: metrics record the HR zone bounds they were computed with, so a zone-
        # config change invalidates + recomputes (like ftp_used does for FTP)
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN zones_used TEXT")?
        # v4: metrics record the algorithm revision they were computed with, so a
        # change to the math itself (metrics_rev bump) invalidates + recomputes
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN metrics_rev INTEGER")?
        # v25 (#311): the in-band MEAN of this session's HR stream; NULL when no usable
        # stream exists. Computed tier — never a correction to `activities.avg_hr`, which a
        # re-sync would silently wipe (the mirror-tier rule in AGENTS.md). The scoring lenses
        # divide by this; display surfaces still publish the stored value.
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN avg_hr_stream REAL")?
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
        # v12: power-duration curve — best mean-max power at each ladder duration (the 20-min
        # point stays in best_20min_w). Feeds `power-curve` (MAX per duration over a window →
        # CP/W' fit). REAL; 0/NULL = no data (ride shorter than the window).
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN best_5s_w REAL")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN best_15s_w REAL")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN best_30s_w REAL")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN best_60s_w REAL")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN best_300s_w REAL")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN best_600s_w REAL")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN best_3600s_w REAL")?
        # v13: pace engine — best_20min_speed is the per-activity best sustained grade-adjusted
        # speed (m/s), the pace analogue of best_20min_w; the derived threshold pace MAXes it
        # over 60d. threshold_pace_used is the threshold (m/s) a row was scored against — the
        # pace twin of ftp_used, compared in the recompute WHERE so a threshold change reanalyzes.
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN best_20min_speed REAL")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN threshold_pace_used REAL")?
        # v16 (#92): HR / power samples dropped by the validity filters vs offered, recorded
        # here because the filtered values are gone before anything downstream sees the
        # metrics. Counts ONLY valid_hr / valid_watts rejections — the wholesale exclusion of
        # an estimated watts stream (#73) is policy, not junk.
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN hr_samples_total INTEGER")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN hr_samples_dropped INTEGER")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN watts_samples_total INTEGER")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN watts_samples_dropped INTEGER")?
        # v17: the activity-input signature a metrics row was computed from, compared on
        # every analyze (same contract as ftp_used) so a changed activity rescores itself.
        # This is what lets `sync` stop deleting metrics — invalidating there wiped a month
        # of metrics per run, since sync cannot tell an edit from a no-op.
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN mt_used INTEGER")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN dist_used INTEGER")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN elev_used INTEGER")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN aw_used INTEGER")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN ahr_used INTEGER")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN waw_used INTEGER")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN re_used INTEGER")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN dw_used INTEGER")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN sport_used TEXT")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN start_used TEXT")?
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN stream_len_used INTEGER")?
        # v19: aerobic decoupling / Pw:HR drift (#94). NULLABLE on purpose — 0.0 is a
        # legitimate PERFECT result (no drift), so a 0 default would make an ideal ride
        # and a session with no power meter indistinguishable. NULL means "not computable
        # for this activity"; a stored 0.0 means "computed, and it was flat".
        alter_add_column!(path, "ALTER TABLE activity_metrics ADD COLUMN decoupling_pct REAL")?
        # v2: index the column every date-range filter and the activities sort use
        # (queries now compare a.start_local directly — sargable — instead of substr)
        Sqlite.execute!({ path: Path.utf8(path), query: "CREATE INDEX IF NOT EXISTS idx_activities_start ON activities(start_local)", bindings: [] })?
        # v14: the period-FTP subquery (ADR 0005) filters on sport_type AND start_local
        # together, once per row being scored. start_local alone leaves a scan over every
        # activity of every OTHER sport on each lookup; the composite makes it a range seek.
        Sqlite.execute!({ path: Path.utf8(path), query: "CREATE INDEX IF NOT EXISTS idx_activities_sport_start ON activities(sport_type, start_local)", bindings: [] })?
        # v15: NULL = Strava never said (pre-flag rows, CSV imports); 1 = real meter; 0 =
        # estimated. Estimated watts must not outrank honest fallbacks (#73).
        alter_add_column!(path, "ALTER TABLE activities ADD COLUMN device_watts INTEGER")?
        # v18: backfill the v17 signature so upgrading does not rescore the entire history.
        # Sound because the code this replaced deleted the metrics row on every upsert: a
        # surviving metrics row belongs to an activity unwritten since it was computed, so
        # its current values ARE the values it was scored from. Touches only NULL rows, so
        # the re-run (a db stuck at 17 pre-backfill) is a safe no-op.
        Sqlite.execute!({
            path: Path.utf8(path),
            query:
                \\UPDATE activity_metrics SET
                \\  mt_used = (SELECT COALESCE(a.moving_time,0) FROM activities a WHERE a.id = activity_metrics.activity_id),
                \\  dist_used = (SELECT CAST(ROUND(COALESCE(a.distance,0)) AS INTEGER) FROM activities a WHERE a.id = activity_metrics.activity_id),
                \\  elev_used = (SELECT CAST(ROUND(COALESCE(a.elevation,0)) AS INTEGER) FROM activities a WHERE a.id = activity_metrics.activity_id),
                \\  aw_used = (SELECT CAST(ROUND(COALESCE(a.avg_watts,0) * 100) AS INTEGER) FROM activities a WHERE a.id = activity_metrics.activity_id),
                \\  ahr_used = (SELECT CAST(ROUND(COALESCE(a.avg_hr,0) * 100) AS INTEGER) FROM activities a WHERE a.id = activity_metrics.activity_id),
                \\  waw_used = (SELECT CAST(ROUND(COALESCE(a.weighted_avg_watts,0) * 100) AS INTEGER) FROM activities a WHERE a.id = activity_metrics.activity_id),
                \\  re_used = (SELECT CAST(ROUND(COALESCE(a.relative_effort,0)) AS INTEGER) FROM activities a WHERE a.id = activity_metrics.activity_id),
                \\  dw_used = (SELECT COALESCE(a.device_watts,-1) FROM activities a WHERE a.id = activity_metrics.activity_id),
                \\  sport_used = (SELECT COALESCE(a.sport_type,'') FROM activities a WHERE a.id = activity_metrics.activity_id),
                \\  start_used = (SELECT COALESCE(a.start_local,'') FROM activities a WHERE a.id = activity_metrics.activity_id),
                \\  -- COALESCE around the SUBQUERY, not inside it: with no streams row the
                \\  -- subquery yields NULL before the CASE is ever evaluated, and a NULL here
                \\  -- reads as stale, rescoring exactly the activities this backfill exists to
                \\  -- spare. An activity with no stream must record 0, the same value the
                \\  -- compute path stores for it via its LEFT JOIN.
                \\  stream_len_used = COALESCE((SELECT LENGTH(s.raw_json) FROM streams s WHERE s.activity_id = activity_metrics.activity_id), 0)
                \\WHERE mt_used IS NULL
                \\  AND EXISTS (SELECT 1 FROM activities a WHERE a.id = activity_metrics.activity_id)
            ,
            bindings: [],
        })?
        # v23 (#151): the FTP population is the sport FAMILY, stored as a column so the
        # period-FTP subqueries stay sargable (the CASE inline measured 8.5x slower). The
        # backfill rewrites ALL rows so a Sports.families edit ships as edit + version bump;
        # triggers keep future writes current — fixtures and CSV imports write activities
        # directly, so sync-side code cannot be the keeper.
        alter_add_column!(path, "ALTER TABLE activities ADD COLUMN sport_family TEXT")?
        Sqlite.execute!({ path: Path.utf8(path), query: "UPDATE activities SET sport_family = ${Sports.sql_canonical_case("sport_type")}", bindings: [] })?
        Sqlite.execute!({ path: Path.utf8(path), query: "CREATE INDEX IF NOT EXISTS idx_activities_family_start ON activities(sport_family, start_local)", bindings: [] })?
        Sqlite.execute!({ path: Path.utf8(path), query: "DROP TRIGGER IF EXISTS activities_family_ai", bindings: [] })?
        Sqlite.execute!({ path: Path.utf8(path), query: "DROP TRIGGER IF EXISTS activities_family_au", bindings: [] })?
        Sqlite.execute!({
            path: Path.utf8(path),
            query: "CREATE TRIGGER activities_family_ai AFTER INSERT ON activities BEGIN UPDATE activities SET sport_family = ${Sports.sql_canonical_case("NEW.sport_type")} WHERE id = NEW.id; END",
            bindings: [],
        })?
        Sqlite.execute!({
            path: Path.utf8(path),
            query: "CREATE TRIGGER activities_family_au AFTER UPDATE OF sport_type ON activities BEGIN UPDATE activities SET sport_family = ${Sports.sql_canonical_case("NEW.sport_type")} WHERE id = NEW.id; END",
            bindings: [],
        })
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
    # Reads back the journal mode actually in force. `PRAGMA journal_mode = WAL` does NOT
    # error when it cannot switch — on a filesystem without WAL's shared-memory primitives
    # it silently returns the mode it kept, and discarding that answer would leave the
    # engine believing it has concurrency it does not (the silent-fallback trap `time_ok`
    # closes for timezones). Reported by doctor, not fatal: stride works without WAL, and
    # busy_timeout still turns most contention into a wait.
    #
    # Why WAL: analyze rebuilds daily_load in one transaction (a partial day-walk would
    # read as a valid truncated series), which under the rollback journal locks the whole
    # db — and busy_timeout defaults to 0, so a concurrent `stride week` aborted a running
    # analyze outright. WAL is a persistent property of the file; readers proceed against
    # the one long writer.
    journal_mode! : Str => Try(Str, _)
    journal_mode! = |path| {
        # Best-effort for real: a `?` here would abort doctor on a Busy or unopenable db,
        # which is precisely when someone runs doctor. The sentinel below is only honest if
        # the failing paths reach it, so the query error becomes "unknown" too.
        modes =
            match Sqlite.query_many!({
                path: Path.utf8(path),
                query: "PRAGMA journal_mode",
                bindings: [],
                rows: Sqlite.str("journal_mode"),
            }) {
                Ok(rows) => rows
                Err(_) => []
            }
        # "unknown", never "": PRAGMA journal_mode always returns a row on a working
        # connection, so no rows means the read itself failed. An empty string would render
        # as a blank cell and read like a mode, hiding that. This stays a sentinel rather
        # than an error because doctor is the command you run WHEN something is wrong — it
        # should report the gap, not refuse to run because of it.
        Ok(Str.with_ascii_lowercased(List.first(modes).ok_or("unknown")))
    }
    configure_concurrency! : Str => Try({}, _)
    configure_concurrency! = |path| {
        # busy_timeout FIRST, and not as a style preference: switching journal mode takes a
        # write lock, so with the default timeout of 0 the very statement meant to enable
        # WAL is itself the one that fails instantly against a busy database — leaving the
        # engine in the exact rollback-journal mode it was trying to escape.
        _ = Sqlite.query_many!({
            path: Path.utf8(path),
            query: "PRAGMA busy_timeout = 5000",
            bindings: [],
            rows: Sqlite.i64("timeout"),
        })?
        # Read before assigning: setting journal_mode wants a write lock, and every command
        # opens through here, so an unconditional assignment would have each short read
        # command reach for a write lock first. After the first open the answer is already
        # "wal" and there is nothing to set.
        if journal_mode!(path)? == "wal" {
            Ok({})
        } else {
            _ = Sqlite.query_many!({
                path: Path.utf8(path),
                query: "PRAGMA journal_mode = WAL",
                bindings: [],
                rows: Sqlite.str("journal_mode"),
            })?
            Ok({})
        }
    }
    # run migrations exactly when the db is behind, then stamp the version. Called on
    # every command entry (via open_db!) so upgrading the binary against an existing db
    # self-migrates instead of failing with an opaque missing-column error.
    ensure_schema! : Str => Try({}, _)
    ensure_schema! = |path| {
        configure_concurrency!(path)?
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
        home = home_dir!({})?
        # Harden BEFORE opening, not only after. Enabling WAL creates db.sqlite-wal and
        # -shm, and the WAL file holds recently written pages — including config rows, which
        # is where the Strava client secret and tokens live. Created under the default umask
        # they can be world-readable for the window before the chmod below. Tightening the
        # DIRECTORY to 0700 first closes that window regardless of umask: nobody else can
        # traverse into it, so a sidecar cannot be read even in the instant before it is
        # chmodded. Best-effort by design (see secure_perms!), so a platform without chmod
        # is no worse off than before.
        secure_perms!("${home}/.stride")?
        ensure_schema!(p)?
        # and again after, to set the modes on files this open just created
        secure_perms!("${home}/.stride")?
        Ok(p)
    }
    # (schema DDL lives in Schema.roc — pure strings, the one kind of SQL that
    #  can move out of the app module without splitting a query from its decoder)
}
