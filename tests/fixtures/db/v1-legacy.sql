-- Legacy stride database (~v1 era): old `prescriptions` table name, no ratings
-- table, no metric-provenance columns, no weighted_avg_watts, relative_effort as
-- INTEGER (pre-v2). Booting the current binary must migrate this to v6 with all
-- seeded data intact. Regenerate only if the ORIGINAL schema shape changes.

CREATE TABLE activities (
  id INTEGER PRIMARY KEY, name TEXT, sport_type TEXT, start_local TEXT,
  moving_time INTEGER, distance REAL, elevation REAL,
  relative_effort INTEGER,           -- INTEGER on purpose (pre-v2)
  avg_watts REAL, avg_hr REAL
);
CREATE TABLE activity_metrics (
  activity_id INTEGER PRIMARY KEY, tss REAL, normalized_power REAL,
  intensity_factor REAL, z1_s INTEGER, z2_s INTEGER, z3_s INTEGER, z4_s INTEGER,
  z5_s INTEGER, computed_at TEXT
);
CREATE TABLE daily_load (day TEXT PRIMARY KEY, tss REAL, ctl REAL, atl REAL, tsb REAL);
CREATE TABLE prescriptions (           -- OLD name; migration renames to planned_sessions
  id INTEGER PRIMARY KEY, created_at TEXT, target_date TEXT, session_type TEXT,
  detail TEXT, rationale TEXT, completed_activity_id INTEGER
);
CREATE TABLE config (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE streams (activity_id INTEGER PRIMARY KEY, raw_json TEXT);

INSERT INTO activities VALUES (1,'Legacy Ride','Ride','2025-01-01T10:00:00Z',3600,20000,100,42,200,150);
INSERT INTO activities VALUES (2,'Legacy Row','Rowing','2025-01-02T10:00:00Z',1800,5000,0,20,0,145);
INSERT INTO activity_metrics VALUES (1,80.0,180.0,0.9,0,600,0,0,0,'2025-01-01T11:00:00Z');
INSERT INTO prescriptions VALUES (1,'2025-01-01T00:00:00Z','2025-01-05','vo2max','5x3min','stimulus',NULL);
INSERT INTO config VALUES ('ftp','200'),('hr_z1_max','123'),('hr_z2_max','153'),('hr_z3_max','168'),('hr_z4_max','183');
INSERT INTO streams VALUES (1,'{}');

PRAGMA user_version = 1;
