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
}
