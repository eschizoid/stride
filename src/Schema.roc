Schema :: [].{

    # ── database schema (DDL only — pure strings, no decoders to drift from) ──
    #
    # These are the ORIGINAL CREATE statements. Columns added later live as additive
    # ALTERs in Db.roc `run_migrations!` (weighted_avg_watts, best_20min_w, ftp_used,
    # planned_sessions.status, planned_sessions.skipped_reason) — look there, not here, if a
    # column seems missing. (`relative_effort` is REAL as of schema v2; read sites keep
    # the CAST(... AS REAL) so pre-v2 dbs, where it was INTEGER, still decode.)

    activities =
        \\CREATE TABLE IF NOT EXISTS activities (
        \\  id              INTEGER PRIMARY KEY,
        \\  name            TEXT,
        \\  sport_type      TEXT,
        \\  start_local     TEXT,
        \\  moving_time     INTEGER,
        \\  distance        REAL,
        \\  elevation       REAL,
        \\  relative_effort REAL,
        \\  avg_watts       REAL,
        \\  avg_hr          REAL
        \\)

    metrics =
        \\CREATE TABLE IF NOT EXISTS activity_metrics (
        \\  activity_id      INTEGER PRIMARY KEY REFERENCES activities(id),
        \\  tss              REAL,
        \\  normalized_power REAL,
        \\  intensity_factor REAL,
        \\  z1_s INTEGER, z2_s INTEGER, z3_s INTEGER, z4_s INTEGER, z5_s INTEGER,
        \\  computed_at      TEXT  -- provenance only; written, never read back
        \\)

    # computed tier (ADR 0008): detected interval structure, rebuilt by analyze,
    # deletable at will — exactly like activity_metrics. HR columns are NULL when
    # the session carried no HR (honest absence, never zeros).
    segments =
        \\CREATE TABLE IF NOT EXISTS activity_segments (
        \\  activity_id  INTEGER REFERENCES activities(id),
        \\  ordinal      INTEGER,
        \\  kind         TEXT,     -- work | recovery | warmup | cooldown
        \\  start_s      INTEGER,
        \\  dur_s        INTEGER,
        \\  avg_signal   REAL,
        \\  signal       TEXT,     -- power | pace
        \\  peak_hr      REAL,
        \\  avg_hr       REAL,
        \\  rec_drop_60s REAL,
        \\  PRIMARY KEY (activity_id, ordinal)
        \\)

    daily_load =
        \\CREATE TABLE IF NOT EXISTS daily_load (
        \\  day  TEXT PRIMARY KEY,
        \\  tss  REAL,
        \\  ctl  REAL,
        \\  atl  REAL,
        \\  tsb  REAL
        \\)

    planned_sessions =
        \\CREATE TABLE IF NOT EXISTS planned_sessions (
        \\  id                    INTEGER PRIMARY KEY,
        \\  created_at            TEXT,
        \\  target_date           TEXT,
        \\  session_type          TEXT,
        \\  detail                TEXT,
        \\  rationale             TEXT,
        \\  completed_activity_id INTEGER
        \\)

    # event targets (#138, judgment tier): a date the athlete is training toward.
    # REMOVABLE, unlike planned_sessions — an event is a target, not a record of
    # training done, so deleting one destroys no adherence history.
    events =
        \\CREATE TABLE IF NOT EXISTS events (
        \\  id         INTEGER PRIMARY KEY,
        \\  created_at TEXT,
        \\  event_date TEXT,
        \\  name       TEXT
        \\)

    streams =
        \\CREATE TABLE IF NOT EXISTS streams (
        \\  activity_id INTEGER PRIMARY KEY REFERENCES activities(id),
        \\  raw_json    TEXT
        \\)

    # key-value store: strava tokens + client creds, sync watermark, ftp, zone bounds
    config =
        \\CREATE TABLE IF NOT EXISTS config (
        \\  key   TEXT PRIMARY KEY,
        \\  value TEXT
        \\)

    # the judgment tier: user-entered effort ratings (Borg CR10 session-RPE).
    # NEVER a column on activities — that table is a replace-on-sync mirror,
    # and a re-sync would silently wipe anything a human typed into it.
    ratings =
        \\CREATE TABLE IF NOT EXISTS ratings (
        \\  activity_id  INTEGER PRIMARY KEY,
        \\  rpe          REAL NOT NULL,
        \\  rated_at     TEXT
        \\)

    # ── shared semantics as SQL views (#403's lesson): the CLI and the viz
    # window must read the plan through the SAME rule, and the only channel
    # they share is the database — so the rule lives here, as views. The
    # engine re-creates them on every migration run (DROP + CREATE, so an
    # edited definition always wins); readers just SELECT.

    # exactly ONE row per planned date: the newest non-skipped row wins, and
    # a skipped tombstone speaks only when nothing replaced it
    plan_current_drop =
        \\DROP VIEW IF EXISTS plan_current
    plan_current =
        \\CREATE VIEW plan_current AS
        \\SELECT * FROM planned_sessions
        \\WHERE id = (SELECT p2.id FROM planned_sessions p2
        \\            WHERE p2.target_date = planned_sessions.target_date
        \\            ORDER BY (COALESCE(p2.status, 'open') <> 'skipped') DESC, p2.id DESC
        \\            LIMIT 1)

    # the Monday of the series' current week — the week alignment every
    # weekly number must share (matches Metrics.weekly_rollup)
    week_bounds_drop =
        \\DROP VIEW IF EXISTS week_bounds
    week_bounds =
        \\CREATE VIEW week_bounds AS
        \\SELECT date(COALESCE(MAX(day), date('now', 'localtime')), '-6 days', 'weekday 1') AS mon
        \\FROM daily_load

    # one row per activity: its day, seconds by zone, and seconds by intensity
    # class. easy/moderate/hard prefer the pi_* split (power-derived with
    # watts, pace-derived for a distance sport without) and fall back to HR
    # zones (z1+z2 / z3 / z4+z5) when no split exists -- the same per-activity
    # CASE `stride summary` aggregates, so viz and CLI polarization agree.
    activity_intensity_drop =
        \\DROP VIEW IF EXISTS activity_intensity
    activity_intensity =
        \\CREATE VIEW activity_intensity AS
        \\SELECT a.id AS activity_id,
        \\       substr(a.start_local, 1, 10) AS day,
        \\       COALESCE(m.z1_s, 0) AS z1_s, COALESCE(m.z2_s, 0) AS z2_s,
        \\       COALESCE(m.z3_s, 0) AS z3_s, COALESCE(m.z4_s, 0) AS z4_s,
        \\       COALESCE(m.z5_s, 0) AS z5_s,
        \\       CASE WHEN COALESCE(m.pi_easy_s, 0) + COALESCE(m.pi_moderate_s, 0) + COALESCE(m.pi_hard_s, 0) > 0
        \\            THEN COALESCE(m.pi_easy_s, 0) ELSE COALESCE(m.z1_s, 0) + COALESCE(m.z2_s, 0) END AS easy_s,
        \\       CASE WHEN COALESCE(m.pi_easy_s, 0) + COALESCE(m.pi_moderate_s, 0) + COALESCE(m.pi_hard_s, 0) > 0
        \\            THEN COALESCE(m.pi_moderate_s, 0) ELSE COALESCE(m.z3_s, 0) END AS moderate_s,
        \\       CASE WHEN COALESCE(m.pi_easy_s, 0) + COALESCE(m.pi_moderate_s, 0) + COALESCE(m.pi_hard_s, 0) > 0
        \\            THEN COALESCE(m.pi_hard_s, 0) ELSE COALESCE(m.z4_s, 0) + COALESCE(m.z5_s, 0) END AS hard_s
        \\FROM activities a
        \\LEFT JOIN activity_metrics m ON m.activity_id = a.id

    # one row per activity per recorded ladder rung: WHICH columns are the
    # power ladder and which family words they carry live here and nowhere
    # else. 0 and NULL in a raw best_* column both mean unrecorded, and
    # the view emits no row for either. Windowed bests, all-time PRs and
    # health reports aggregate this differently, but they unpivot identically.
    activity_power_ladder_drop =
        \\DROP VIEW IF EXISTS activity_power_ladder
    activity_power_ladder =
        \\CREATE VIEW activity_power_ladder AS
        \\SELECT a.id AS activity_id, substr(a.start_local, 1, 10) AS day, a.start_local AS start_local, a.sport_type AS sport_type, a.sport_family AS sport_family, '5s' AS rung, 5 AS secs, m.best_5s_w AS watts
        \\FROM activities a JOIN activity_metrics m ON m.activity_id = a.id WHERE COALESCE(m.best_5s_w, 0) > 0
        \\UNION ALL
        \\SELECT a.id AS activity_id, substr(a.start_local, 1, 10) AS day, a.start_local AS start_local, a.sport_type AS sport_type, a.sport_family AS sport_family, '15s' AS rung, 15 AS secs, m.best_15s_w AS watts
        \\FROM activities a JOIN activity_metrics m ON m.activity_id = a.id WHERE COALESCE(m.best_15s_w, 0) > 0
        \\UNION ALL
        \\SELECT a.id AS activity_id, substr(a.start_local, 1, 10) AS day, a.start_local AS start_local, a.sport_type AS sport_type, a.sport_family AS sport_family, '30s' AS rung, 30 AS secs, m.best_30s_w AS watts
        \\FROM activities a JOIN activity_metrics m ON m.activity_id = a.id WHERE COALESCE(m.best_30s_w, 0) > 0
        \\UNION ALL
        \\SELECT a.id AS activity_id, substr(a.start_local, 1, 10) AS day, a.start_local AS start_local, a.sport_type AS sport_type, a.sport_family AS sport_family, '1min' AS rung, 60 AS secs, m.best_60s_w AS watts
        \\FROM activities a JOIN activity_metrics m ON m.activity_id = a.id WHERE COALESCE(m.best_60s_w, 0) > 0
        \\UNION ALL
        \\SELECT a.id AS activity_id, substr(a.start_local, 1, 10) AS day, a.start_local AS start_local, a.sport_type AS sport_type, a.sport_family AS sport_family, '5min' AS rung, 300 AS secs, m.best_300s_w AS watts
        \\FROM activities a JOIN activity_metrics m ON m.activity_id = a.id WHERE COALESCE(m.best_300s_w, 0) > 0
        \\UNION ALL
        \\SELECT a.id AS activity_id, substr(a.start_local, 1, 10) AS day, a.start_local AS start_local, a.sport_type AS sport_type, a.sport_family AS sport_family, '10min' AS rung, 600 AS secs, m.best_600s_w AS watts
        \\FROM activities a JOIN activity_metrics m ON m.activity_id = a.id WHERE COALESCE(m.best_600s_w, 0) > 0
        \\UNION ALL
        \\SELECT a.id AS activity_id, substr(a.start_local, 1, 10) AS day, a.start_local AS start_local, a.sport_type AS sport_type, a.sport_family AS sport_family, '20min' AS rung, 1200 AS secs, m.best_20min_w AS watts
        \\FROM activities a JOIN activity_metrics m ON m.activity_id = a.id WHERE COALESCE(m.best_20min_w, 0) > 0
        \\UNION ALL
        \\SELECT a.id AS activity_id, substr(a.start_local, 1, 10) AS day, a.start_local AS start_local, a.sport_type AS sport_type, a.sport_family AS sport_family, '60min' AS rung, 3600 AS secs, m.best_3600s_w AS watts
        \\FROM activities a JOIN activity_metrics m ON m.activity_id = a.id WHERE COALESCE(m.best_3600s_w, 0) > 0

    # twelve Monday weeks of load and CTL slope: the week's TSS, its
    # end-of-week CTL, and the ramp (CTL change vs the prior week's end).
    # Anchored on week_bounds; empty weeks materialize as zero rows.
    weekly_ramp_drop =
        \\DROP VIEW IF EXISTS weekly_ramp
    weekly_ramp =
        \\CREATE VIEW weekly_ramp AS
        \\WITH mondays(wk) AS (SELECT date(mon, '-77 days') FROM week_bounds UNION ALL SELECT date(wk, '+7 days') FROM mondays WHERE wk < (SELECT mon FROM week_bounds)),
        \\wtss AS (SELECT date(day, '-6 days', 'weekday 1') AS awk, SUM(COALESCE(tss, 0)) AS tss FROM daily_load WHERE day >= (SELECT date(mon, '-77 days') FROM week_bounds) GROUP BY awk),
        \\wctl AS (SELECT date(day, '-6 days', 'weekday 1') AS awk, MAX(day) AS last_day FROM daily_load WHERE day >= (SELECT date(mon, '-84 days') FROM week_bounds) GROUP BY awk)
        \\SELECT m.wk AS wk, COALESCE(t.tss, 0) AS tss, COALESCE(dl.ctl, 0) AS ctl_end,
        \\       COALESCE(dl.ctl, 0) - COALESCE(prev.ctl, COALESCE(dl.ctl, 0)) AS ramp
        \\FROM mondays m
        \\LEFT JOIN wtss t ON t.awk = m.wk
        \\LEFT JOIN wctl wc ON wc.awk = m.wk
        \\LEFT JOIN daily_load dl ON dl.day = wc.last_day
        \\LEFT JOIN wctl pwc ON pwc.awk = date(m.wk, '-7 days')
        \\LEFT JOIN daily_load prev ON prev.day = pwc.last_day

    # the career, per sport: every session ever, its moving seconds and its
    # meters. The one definition `stats`' all-time table and the window's
    # career view both read; `stats`' year-to-date arm keeps its own cutoff
    # query because a view cannot take a parameter.
    career_totals_drop =
        \\DROP VIEW IF EXISTS career_totals
    career_totals =
        \\CREATE VIEW career_totals AS
        \\SELECT COALESCE(CAST(sport_type AS TEXT), '') AS sport, COUNT(*) AS sessions,
        \\       COALESCE(SUM(moving_time), 0) AS secs,
        \\       COALESCE(SUM(distance), 0) AS meters
        \\FROM activities GROUP BY sport_type

    # calendar-month load off daily_load - the month spine `season` sums and
    # the career view draws. Empty months produce no row; a reader that wants
    # a gapless month axis builds its own spine and joins.
    monthly_load_drop =
        \\DROP VIEW IF EXISTS monthly_load
    monthly_load =
        \\CREATE VIEW monthly_load AS
        \\SELECT substr(CAST(day AS TEXT), 1, 7) AS month, CAST(COALESCE(SUM(tss), 0) AS REAL) AS load
        \\FROM daily_load GROUP BY month ORDER BY month

    # the FTP the engine scored each month's LAST power-scored Ride-family
    # activity with. Deliberately NOT season's ftp_end - that is a
    # chronological per-day fold with family weighting and has its one body in
    # ReportSeason - this is a different, simpler quantity with its own name:
    # the threshold in force when the month closed. A correlated subquery with
    # an id tie-break rather than a window function: the window's bundled
    # SQLite must be able to read every shared view, and window functions are
    # the one modern feature this repo does not assume. One database names
    # one row either way.
    monthly_ride_ftp_drop =
        \\DROP VIEW IF EXISTS monthly_ride_ftp
    monthly_ride_ftp =
        \\CREATE VIEW monthly_ride_ftp AS
        \\SELECT substr(CAST(a.start_local AS TEXT), 1, 7) AS month,
        \\       CAST(m.ftp_used AS REAL) AS ftp
        \\FROM activities a JOIN activity_metrics m ON m.activity_id = a.id
        \\WHERE COALESCE(m.ftp_used, 0) > 0 AND a.sport_family = 'Ride'
        \\  AND a.id = (SELECT a2.id FROM activities a2
        \\              JOIN activity_metrics m2 ON m2.activity_id = a2.id
        \\              WHERE COALESCE(m2.ftp_used, 0) > 0 AND a2.sport_family = 'Ride'
        \\                AND substr(CAST(a2.start_local AS TEXT), 1, 7) = substr(CAST(a.start_local AS TEXT), 1, 7)
        \\              ORDER BY a2.start_local DESC, a2.id DESC LIMIT 1)
}
