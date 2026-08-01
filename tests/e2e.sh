#!/usr/bin/env bash
set -euo pipefail
export STRIDE_FORMAT=json  # test the machine contract; human mode smoke-tested at the end

STRIDE_BIN="${STRIDE_BIN:-$PWD/stride}"
# declare then export separately so a mktemp failure isn't masked by export's
# own exit status under `set -e` (a bare `export X=$(cmd)` always succeeds)
SANDBOX_HOME="$(mktemp -d)"
export HOME="$SANDBOX_HOME"
trap 'rm -rf "$SANDBOX_HOME"' EXIT
DB="$HOME/.stride/db.sqlite"

fail() { echo "FAIL: $1" >&2; exit 1; }
# seed_ride id name date secs meters watts hr  (watts/hr may be NULL)
seed_ride() { sqlite3 "$DB" "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,weighted_avg_watts,avg_watts,avg_hr) VALUES ($1,'$2','Ride','$3',$4,$5,$6,$6,$7);"; }

# ── init + config ────────────────────────────────────────────────
out=$("$STRIDE_BIN" init); grep -q initialized <<<"$out" || fail "init"
# before config exists, json mode must still emit valid JSON (not human prose).
# also locks the P3 envelope: versioned wrapper, error under error.code (not bare).
"$STRIDE_BIN" summary | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["schema_version"] == 1, f"envelope must be versioned: {d}"
assert "data" not in d and d["error"]["code"] == "missing_config", f"error envelope: {d}"
print("missing-config json contract OK (versioned error envelope)")
'
for kv in "ftp 200" "hr_z1_max 123" "hr_z2_max 153" "hr_z3_max 168" "hr_z4_max 183"; do
  "$STRIDE_BIN" config set $kv >/dev/null
done

# ── auth without creds: setup guidance, not a raw MissingEnv crash ──
out=$(env -u STRAVA_CLIENT_ID -u STRAVA_CLIENT_SECRET "$STRIDE_BIN" auth </dev/null)
grep -q missing_client_creds <<<"$out" || fail "credless auth must give setup guidance, not crash"
echo "auth credless-guidance OK"

# ── power zones: watt ranges derived from FTP (200) ──────────────
"$STRIDE_BIN" pz | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
zs = d["zones"]
assert len(zs) == 7, f"expected 7 power zones, got {len(zs)}"
z4 = zs[3]  # threshold, 91-105% of FTP 200 = 182-210W
assert abs(z4["lo_w"] - 182) < 1 and abs(z4["hi_w"] - 210) < 1, f"Z4 range wrong: {z4}"
assert zs[0]["lo_w"] == 0 and zs[6]["hi_w"] == 0, "Z1 opens at 0, Z7 open above"
print("pz OK (7 power zones from FTP)")
'

# ── config set ftp: stores locally + attempts Strava sync, gracefully ────
# (no auth in the sandbox, so the sync warns but the local set must succeed)
out=$("$STRIDE_BIN" config set ftp 195)
grep -q "ftp = 195" <<<"$out" || fail "config set ftp must store + report locally"
grep -q "not synced to Strava" <<<"$out" || fail "unauthed ftp set must warn (not crash) about Strava sync"
got=$(STRIDE_FORMAT=human "$STRIDE_BIN" config get ftp); [ "$got" = "195" ] || fail "ftp must be stored even when Strava sync can't run"
"$STRIDE_BIN" config get ftp | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; assert d["value"] == "195", d; print("config get json OK")'
"$STRIDE_BIN" config get nope | python3 -c 'import json,sys; assert json.load(sys.stdin)["error"]["code"] == "not_set"; print("config get not_set OK")'
# ── credential safety (P4): secrets never surface, db is owner-only ──
sqlite3 "$DB" "INSERT OR REPLACE INTO config (key,value) VALUES ('strava_access_token','SECRETVAL123');"
out=$("$STRIDE_BIN" config get strava_access_token)
grep -q '"redacted":true' <<<"$out" || fail "secret key must report redacted"
grep -q SECRETVAL123 <<<"$out" && fail "secret VALUE must never appear in output"
# GNU stat (-c) first: on Linux `stat -f` means --file-system and prints fs stats
# (exit 0), which would shadow the fallback. macOS BSD stat has no -c, so it falls
# through to -f '%Lp'. This order gives the perm bits on both.
perms=$(stat -c '%a' "$DB" 2>/dev/null || stat -f '%Lp' "$DB" 2>/dev/null)
[ "$perms" = "600" ] || fail "db must be chmod 600 after a command, got '$perms'"
echo "credential safety OK (secret redacted, db 0600)"
"$STRIDE_BIN" config set ftp 200 >/dev/null   # restore for the rest of the suite
echo "ftp Strava-sync OK (local set succeeds, unauthed sync degrades gracefully)"

# ── seed: one power ride (NP 200 @ FTP 200, 1h -> TSS 100),
#          one HR-only row (avg 150 = Z2, 1h -> hrTSS 55) ─────────
TODAY=$(date -u +%F)
D1=$(date -u -v-3d +%F 2>/dev/null || date -u -d '3 days ago' +%F)
D2=$(date -u -v-1d +%F 2>/dev/null || date -u -d '1 day ago' +%F)
sqlite3 "$DB" "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,elevation,weighted_avg_watts,avg_watts) VALUES (101,'power ride','Ride','${D1}T10:00:00Z',3600,30000,100,200,200);"
sqlite3 "$DB" "INSERT INTO activities (id,name,sport_type,start_local,moving_time,distance,elevation,avg_hr) VALUES (102,'hr row','Rowing','${D2}T10:00:00Z',3600,9000,0,150);"

# ── analyze: TSS ladder + daily_load to today ────────────────────
out=$("$STRIDE_BIN" analyze); grep -q '"computed":2' <<<"$out" || fail "analyze count"
"$STRIDE_BIN" summary | python3 -c '
import json, sys
s = json.load(sys.stdin)["data"]; today = sys.argv[1]
assert s["as_of"] == today, f"as_of {s['"'"'as_of'"'"']} != {today} (daily_load must extend to today)"
assert abs(s["last_28d"]["tss"] - 155) < 1.0, f"expected 100 power + 55 hrTSS, got {s['"'"'last_28d'"'"']['"'"'tss'"'"']}"
# grill #2: fitness carries its own confidence — 100 measured (power) / 155 total = ~65%
mp = s["last_28d"]["measured_pct"]
assert 60 <= mp <= 70, f"measured_pct should be ~65 (100 power / 155 total), got {mp}"
assert s["ftp"]["stale"] == False
assert s["fitness_ctl"] > 0 and s["fatigue_atl"] > 0
print("summary math OK (power TSS 100 + hrTSS 55, as-of-today)")
' "$TODAY"

# ── FTP auto-invalidation: change config -> analyze recomputes ───
"$STRIDE_BIN" config set ftp 100 >/dev/null
out=$("$STRIDE_BIN" analyze); grep -q '"computed":2' <<<"$out" || fail "ftp change must recompute all rows"
"$STRIDE_BIN" summary | python3 -c '
import json, sys
s = json.load(sys.stdin)["data"]
assert abs(s["last_28d"]["tss"] - 455) < 1.0, f"NP200@FTP100 => TSS 400 (+55 hr), got {s['"'"'last_28d'"'"']['"'"'tss'"'"']}"
print("ftp_used auto-invalidation OK (TSS rescaled 100 -> 400)")
'

# ── zone auto-invalidation: change a HR zone bound -> analyze recomputes ──
# (zones are a metric input like FTP; changing one must invalidate, not no-op)
"$STRIDE_BIN" config set hr_z2_max 140 >/dev/null
out=$("$STRIDE_BIN" analyze); grep -q '"computed":2' <<<"$out" || fail "zone change must recompute all rows"
"$STRIDE_BIN" config set hr_z2_max 153 >/dev/null   # restore
out=$("$STRIDE_BIN" analyze); grep -q '"computed":2' <<<"$out" || fail "restoring zone must recompute again"
echo "zones_used auto-invalidation OK (zone change forces recompute)"

# ── metrics_rev invalidation: an algorithm-revision bump recomputes everything ──
# (simulated by zeroing the stored rev — same effect as bumping the constant)
sqlite3 "$DB" "UPDATE activity_metrics SET metrics_rev = 0;"
out=$("$STRIDE_BIN" analyze); grep -q '"computed":2' <<<"$out" || fail "metrics_rev change must recompute all rows"
rev=$(sqlite3 "$DB" "SELECT DISTINCT metrics_rev FROM activity_metrics;")
# one uniform nonzero rev (whatever the binary's current constant is)
case "$rev" in ''|0|*$'\n'*) fail "recomputed rows must carry ONE current metrics_rev, got '$rev'";; esac
echo "metrics_rev invalidation OK (algorithm changes recompute)"

# ── plan lifecycle: dedup, skip, re-plan, done ───────────────────
out=$("$STRIDE_BIN" plan add 2099-01-01 vo2max "d" "r"); grep -q '"id":1' <<<"$out" || fail "plan add"
out=$("$STRIDE_BIN" plan add 2099-01-01 threshold "d" "r"); grep -q date_already_planned <<<"$out" || fail "dedup guard"
out=$("$STRIDE_BIN" skip 1 "sick"); grep -q '"skipped_session"' <<<"$out" || fail "skip"
out=$("$STRIDE_BIN" plan add 2099-01-01 threshold "d2" "r2"); grep -q '"id":2' <<<"$out" || fail "re-plan after skip"
out=$("$STRIDE_BIN" complete 2 101); grep -q '"completed_session"' <<<"$out" || fail "complete"
# `plan` defaults to the current week; the seeded sessions are far-future, so use `plan all`
"$STRIDE_BIN" plan all | python3 -c '
import json, sys
ps = {p["id"]: p for p in json.load(sys.stdin)["data"]}
assert ps[1]["status"] == "skipped" and ps[1]["skipped_reason"] == "sick"
assert ps[2]["status"] == "done" and ps[2]["completed_activity_id"] == 101
print("plan lifecycle OK (open -> skipped / done)")
'
# complete/skip must refuse ids that don't exist (no false success)
out=$("$STRIDE_BIN" complete 999 101); grep -q session_not_found <<<"$out" || fail "complete nonexistent session"
out=$("$STRIDE_BIN" complete 2 88888); grep -q activity_not_found <<<"$out" || fail "complete nonexistent activity"
out=$("$STRIDE_BIN" skip 999 "x"); grep -q session_not_found <<<"$out" || fail "skip nonexistent session"
out=$("$STRIDE_BIN" complete abc 101); grep -q bad_id <<<"$out" || fail "complete non-numeric id"
# rest days close WITHOUT an activity; anything else still demands evidence
out=$("$STRIDE_BIN" plan add 2099-01-02 rest "planned rest" "recovery"); grep -q '"id":3' <<<"$out" || fail "plan rest"
out=$("$STRIDE_BIN" plan add 2099-01-03 vo2max "intervals" "stimulus"); grep -q '"id":4' <<<"$out" || fail "plan vo2max"
out=$("$STRIDE_BIN" complete 4); grep -q activity_required <<<"$out" || fail "non-rest bare complete must refuse"
out=$("$STRIDE_BIN" complete 3); grep -q '"rest":true' <<<"$out" || fail "rest bare complete"
st=$(sqlite3 "$DB" "SELECT status FROM planned_sessions WHERE id=3;"); [ "$st" = "done" ] || fail "rest must be done, got '$st'"
"$STRIDE_BIN" skip 4 "cleanup" >/dev/null
echo "rest-day complete OK (bare complete for rest only)"
"$STRIDE_BIN" summary | python3 -c 'import json,sys; assert json.load(sys.stdin)["data"]["pending_sessions"] == 0; print("pending count OK")'
"$STRIDE_BIN" week | python3 -c 'import json,sys; assert json.load(sys.stdin)["data"]["open_sessions"] == []; print("week payload OK")'

# ── query commands: activities (+ sport filter), load, stats ─────
"$STRIDE_BIN" activities | python3 -c '
import json, sys
rows = {a["id"]: a for a in json.load(sys.stdin)["data"]}
assert len(rows) == 2, f"expected 2 activities, got {len(rows)}"
assert abs(rows[101]["tss"] - 400) < 1.0 and abs(rows[101]["intensity"] - 2.0) < 0.01, "power ride NP200@FTP100"
assert abs(rows[102]["tss"] - 55) < 1.0, "hr row hrTSS"
print("activities OK (tss + intensity math)")
'
"$STRIDE_BIN" activities 10 rowing | python3 -c '
import json, sys
rows = json.load(sys.stdin)["data"]
assert len(rows) == 1 and rows[0]["id"] == 102, "sport filter must be case-insensitive and exact"
print("activities sport filter OK")
'
# ── top: ranked best-sessions view ───────────────────────────────
# 101 is the power ride (highest TSS, no HR); 102 is the HR row (avg_hr 150)
"$STRIDE_BIN" top tss | python3 -c '
import json, sys
rows = json.load(sys.stdin)["data"]
assert rows[0]["id"] == 101, f"top tss must rank the power ride first, got {rows[0]['"'"'id'"'"']}"
print("top tss OK (ranks by load desc)")
'
"$STRIDE_BIN" top hr | python3 -c '
import json, sys
ids = [r["id"] for r in json.load(sys.stdin)["data"]]
assert ids == [102], f"top hr must include only the HR activity (power ride has no HR), got {ids}"
print("top hr OK (excludes metric-less activities)")
'
"$STRIDE_BIN" top tss 5 rowing | python3 -c '
import json, sys
rows = json.load(sys.stdin)["data"]
assert len(rows) == 1 and rows[0]["id"] == 102, "top sport filter must apply"
print("top sport filter OK")
'
"$STRIDE_BIN" top output | python3 -c '
import json, sys
rows = json.load(sys.stdin)["data"]
# 101: avg_watts 200 * 3600s / 1000 = 720 kJ; 102 has no watts (excluded)
assert rows[0]["id"] == 101 and abs(rows[0]["output_kj"] - 720) < 1.0, f"top output kJ, got {rows[0]}"
print("top output OK (kJ = avg_watts * time)")
'
out=$("$STRIDE_BIN" top bogus); grep -q bad_metric <<<"$out" || fail "top must reject unknown metrics"
echo "top OK (metric ranking + filter + bad-metric guard)"
"$STRIDE_BIN" load | python3 -c '
import json, sys, datetime
days = json.load(sys.stdin)["data"]
assert len(days) >= 4, "seeded 3 days ago -> at least 4 daily rows"
assert days[-1]["day"] == datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"), "must extend to today"
assert days[0]["day"] < days[-1]["day"] and days[-1]["ctl"] > 0, "chronological, nonzero fitness"
print("load OK (daily series to today)")
'
"$STRIDE_BIN" stats | python3 -c '
import json, sys
s = json.load(sys.stdin)["data"]
at = {r["sport"]: r for r in s["all_time"]}
assert at["Ride"]["sessions"] == 1 and abs(at["Ride"]["hours"] - 1.0) < 0.01 and abs(at["Ride"]["km"] - 30) < 0.1
assert at["Rowing"]["sessions"] == 1 and abs(at["Rowing"]["km"] - 9) < 0.1
assert isinstance(s["ytd_year"], int) and isinstance(s["ytd"], list)
print("stats OK (all-time totals)")
'
"$STRIDE_BIN" activity 101 | python3 -c '
import json, sys
a = json.load(sys.stdin)["data"]
assert a["id"] == 101 and abs(a["tss"] - 400) < 1.0 and abs(a["intensity"] - 2.0) < 0.01
assert a["power_bests"]["w60"] == 0, "no streams seeded -> bests are honest 0"
print("activity detail OK")
'
out=$("$STRIDE_BIN" activity 999); grep -q activity_not_found <<<"$out" || fail "activity not-found"

# power junk filter: a single 9999 W sensor spike must not inflate the power bests
# (unfiltered, a 60s best over 59×200 + 1×9999 ≈ 363 W; filtered it stays ~200).
SPIKE=$(python3 -c 'import json;n=120;d=[200.0]*n;d[60]=9999.0;print(json.dumps({"time":{"data":list(range(n))},"watts":{"data":d}}))')
sqlite3 "$DB" "INSERT OR REPLACE INTO streams (activity_id, raw_json) VALUES (101, '$SPIKE');"
sqlite3 "$DB" "DELETE FROM activity_metrics WHERE activity_id = 101;"
"$STRIDE_BIN" analyze >/dev/null
"$STRIDE_BIN" activity 101 | python3 -c '
import json, sys
a = json.load(sys.stdin)["data"]
w = a["power_bests"]["w60"]
assert 190 <= w <= 210, f"9999W spike must be filtered from bests, got w60={w}"
# power ride reports intensity from power, not just HR (grill fix)
pi = a["power_intensity"]
assert set(pi) == {"easy_s", "moderate_s", "hard_s"}, pi
assert pi["easy_s"] + pi["moderate_s"] + pi["hard_s"] > 0, "power ride must have power-intensity time"
assert "hard_by_power_s" in a, a
print("power junk filter OK + power-intensity present on a power ride")
'

# corrupt stream data must be flagged, not silently read as honest zeros
sqlite3 "$DB" "INSERT OR REPLACE INTO streams (activity_id, raw_json) VALUES (101, 'not json at all');"
"$STRIDE_BIN" activity 101 | python3 -c '
import json, sys
assert json.load(sys.stdin)["data"]["streams_unreadable"] == True, "corrupt streams must set streams_unreadable"
print("activity unreadable-streams flag OK")
'
# force a recompute (ftp change invalidates via ftp_used) so analyze re-reads
# 101's now-corrupt streams and must report the count instead of hiding it
"$STRIDE_BIN" config set ftp 111 >/dev/null
out=$("$STRIDE_BIN" analyze); grep -qE '"stream_errors":[1-9]' <<<"$out" || fail "analyze must report stream decode errors"

# non-numeric count args must error, not silently default
out=$("$STRIDE_BIN" activities banana); grep -q bad_count <<<"$out" || fail "activities non-numeric count"
out=$("$STRIDE_BIN" load abc); grep -q bad_count <<<"$out" || fail "load non-numeric count"

# a malformed start_local must NOT explode the daily-load walk (regression:
# unparseable boundary date defaulted to epoch-day 0 -> walked from 1970)
sqlite3 "$DB" "INSERT INTO activities (id,name,sport_type,start_local,moving_time,avg_hr) VALUES (103,'bad date','Ride','0000-0z-01T10:00:00Z',3600,150);"
"$STRIDE_BIN" analyze >/dev/null
rows=$(sqlite3 "$DB" "SELECT COUNT(*) FROM daily_load")
[ "$rows" -lt 400 ] || fail "malformed date must not explode daily_load (got $rows rows)"
echo "count-validation + bad-date resilience OK ($rows daily_load rows)"

# ── progress: repeated-workout trend (EF = NP/HR per instance) ───
seed_ride 201 "Test Class" 2025-01-01T10:00:00Z 3600 20000 180 150
seed_ride 202 "Test Class" 2025-06-01T10:00:00Z 3600 20000 210 150
"$STRIDE_BIN" analyze >/dev/null
"$STRIDE_BIN" progress 2025-06-01 | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
assert d["anchor_date"] == "2025-06-01", "anchor_date must echo the asked date: " + str(d)
g = d["groups"][0]
rows = g["sessions"]
assert len(rows) == 2 and g["name"] == "Test Class", "date must resolve to that day workout: " + str(d)
assert rows[0]["date"] < rows[1]["date"], "must be chronological"
assert g["lens"] == "ef", "power ride must use the EF lens: " + str(g)
scores = [round(r["score"], 3) for r in rows]
assert abs(rows[0]["score"] - 1.20) < 0.01 and abs(rows[1]["score"] - 1.40) < 0.01, "EF wrong: " + str(scores)
print("progress OK (EF lens, date -> workout, chronological)")
'
# JSON callers can distinguish the empty outcomes in-band
"$STRIDE_BIN" progress 1999-01-01 | python3 -c 'import json,sys; assert json.load(sys.stdin)["error"]["code"] == "no_workout_on_date"; print("progress json error OK")'
# auto-named rides ("Morning Ride") are different routes: only similar-distance
# (±10% of the anchor) instances may be compared
seed_ride 211 "Morning Ride" 2025-03-01T08:00:00Z 3600 20000 150 140
seed_ride 212 "Morning Ride" 2025-03-08T08:00:00Z 3600 21000 160 140
seed_ride 213 "Morning Ride" 2025-03-15T08:00:00Z 7200 40000 170 140
"$STRIDE_BIN" analyze >/dev/null
"$STRIDE_BIN" progress 2025-03-01 | python3 -c '
import json, sys
rows = json.load(sys.stdin)["data"]["groups"][0]["sessions"]
dists = sorted(r["distance_m"] for r in rows)
assert dists == [20000.0, 21000.0], "auto-name must gate to ±10% of anchor distance, got " + str(dists)
print("progress auto-name OK (distance-gated, 40km ride excluded)")
'
out=$(STRIDE_FORMAT=human "$STRIDE_BIN" progress 1999-01-01)
grep -q "no workout found" <<<"$out" || fail "progress on an empty date must say so, not crash"
# a power ride with no HR can't be scored by any lens — say so, honestly
out=$(STRIDE_FORMAT=human "$STRIDE_BIN" progress "$D1")
grep -q "can't be compared" <<<"$out" || fail "unscorable workout must explain what a lens needs"
# bare progress anchors on the latest analyzed workout and reports its lens
"$STRIDE_BIN" progress | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
assert d["anchor_date"], "bare progress must resolve an anchor: " + str(d)
g = d["groups"][0]
assert "lens" in g and len(g["sessions"]) >= 1, "bare progress group must carry a lens + sessions: " + str(d)
assert g["lens"] == "speed_hr", "the HR+distance rowing anchor must use the speed/HR lens: " + str(g)
print("progress no-arg OK (latest analyzed; SpeedHr lens for the row)")
'
# SpeedHr lens shows runner-friendly pace (min/km), not raw m/min
out=$(STRIDE_FORMAT=human "$STRIDE_BIN" progress)
grep -q "pace (min/km)" <<<"$out" || fail "SpeedHr lens must show a pace column for runs/rows"
# last-vs-best: a later weaker session (EF 1.0 < best 1.40) must surface the gap line
seed_ride 203 "Test Class" 2025-07-01T10:00:00Z 3600 20000 150 150
"$STRIDE_BIN" analyze >/dev/null
out=$(STRIDE_FORMAT=human "$STRIDE_BIN" progress 2025-07-01)
grep -q "below your best" <<<"$out" || fail "weaker last session must show the last-vs-best gap line"
# seeded EFs are 1.20, 1.40, 1.00 -> overall avg exactly 1.20 (asserts the math, not the template)
grep -q "(overall avg 1.20)" <<<"$out" || fail "verdict must compute the average EF (expected 1.20)"
grep -q "████████████" <<<"$out" || fail "best session must render a full 12-char ef bar"
grep -q "◀ asked" <<<"$out" || fail "asked-date row must carry the marker"
grep -q "···" <<<"$out" || fail "sessions >90 days apart must show a ··· gap row"
echo "progress OK (date anchor + distance gate + last-vs-best + ef bar + empty guard)"

# ── import: Strava account export (activities.csv, no API creds) ──
# realistic shape: DUPLICATE Distance/Moving Time headers (2nd = precise),
# quoted name with comma, an unparseable junk row, an HR-only row
EXPORT_DIR=$(mktemp -d)
cat > "$EXPORT_DIR/activities.csv" <<'CSVEOF'
Activity ID,Activity Date,Activity Name,Activity Type,Elapsed Time,Distance,Relative Effort,Moving Time,Distance,Elevation Gain,Average Heart Rate,Average Watts,Weighted Average Power
9001,"Jul 1, 2025, 6:30:00 AM","Morning ride, easy one",Ride,3700,20.10,55,3600,20100.0,150,,180,190
9002,"Jul 2, 2025, 7:00:00 PM",Evening Row,Rowing,1900,5.00,30,1800,5000.0,0,145,,
junk,not a date,Broken Row,Ride,x,y,z,q,w,e,r,t,y
CSVEOF
# strip the heredoc indentation (just recipes indent continuation lines)
sed -i.bak 's/^    //' "$EXPORT_DIR/activities.csv" && rm -f "$EXPORT_DIR/activities.csv.bak"
"$STRIDE_BIN" import "$EXPORT_DIR" | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
assert d["imported"] == 2 and d["skipped"] == 1, f"expected 2 imported / 1 junk skipped, got {d}"
print("import counts OK (2 imported, junk row skipped)")
'
row=$(sqlite3 "$DB" "SELECT name || '|' || sport_type || '|' || start_local || '|' || moving_time || '|' || CAST(distance AS INT) || '|' || weighted_avg_watts FROM activities WHERE id=9001;")
[ "$row" = "Morning ride, easy one|Ride|2025-07-01T06:30:00Z|3600|20100|190.0" ] || fail "imported row 9001 mismatch: $row"
hr=$(sqlite3 "$DB" "SELECT avg_hr FROM activities WHERE id=9002;")
[ "$hr" = "145.0" ] || fail "HR-only row must keep avg_hr, got '$hr'"
# analyze picks the imported rows up through the normal pipeline
out=$("$STRIDE_BIN" analyze); grep -qE '"computed":[0-9]+' <<<"$out" || fail "analyze after import"
tss=$(sqlite3 "$DB" "SELECT ROUND(tss) FROM activity_metrics WHERE activity_id=9001;")
[ -n "$tss" ] && [ "$tss" != "0.0" ] || fail "imported power ride must get TSS from the ladder, got '$tss'"
# idempotent: re-import updates in place, no duplicates
"$STRIDE_BIN" import "$EXPORT_DIR" >/dev/null
n=$(sqlite3 "$DB" "SELECT COUNT(*) FROM activities WHERE id IN (9001, 9002);")
[ "$n" = "2" ] || fail "re-import must be idempotent, got $n rows"
# a zip of the same export imports identically (exercises the unzip path)
if command -v zip >/dev/null; then
  (cd "$EXPORT_DIR" && zip -q export.zip activities.csv)
  "$STRIDE_BIN" import "$EXPORT_DIR/export.zip" | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; assert d["imported"] == 2, d; print("import zip OK")'
fi
rm -rf "$EXPORT_DIR"
out=$(STRIDE_FORMAT=human "$STRIDE_BIN" import /nonexistent-dir-xyz)
grep -q "no activities.csv" <<<"$out" || fail "missing export must explain itself"
echo "import OK (export dir + zip + idempotent + honest errors)"

# ── session-RPE: the athlete scores what sensors can't ──────────
sqlite3 "$DB" "INSERT INTO activities (id,name,sport_type,start_local,moving_time) VALUES (301,'Heavy Lift','WeightTraining','2025-05-05T18:00:00Z',2700);"
"$STRIDE_BIN" analyze >/dev/null
model=$(sqlite3 "$DB" "SELECT load_model FROM activity_metrics WHERE activity_id=301;")
[ "$model" = "none" ] || fail "sensorless strength must score none, got '$model'"
out=$("$STRIDE_BIN" rate 301 11); grep -q bad_rpe <<<"$out" || fail "rpe over 10 must be refused"
out=$("$STRIDE_BIN" rate 301 7); grep -q '"rated":301' <<<"$out" || fail "rate must confirm"
"$STRIDE_BIN" analyze >/dev/null
row=$(sqlite3 "$DB" "SELECT load_model || '|' || ROUND(tss, 1) FROM activity_metrics WHERE activity_id=301;")
[ "$row" = "session_rpe|52.5" ] || fail "45min @ RPE 7 must score 52.5 via session_rpe, got '$row'"
# re-rating invalidates + rescores (the judgment tier joins the invalidation story)
"$STRIDE_BIN" rate 301 5 >/dev/null
"$STRIDE_BIN" analyze >/dev/null
tss=$(sqlite3 "$DB" "SELECT ROUND(tss, 1) FROM activity_metrics WHERE activity_id=301;")
[ "$tss" = "37.5" ] || fail "re-rate to 5 must rescore to 37.5, got '$tss'"
# ratings survive a re-sync of the activities mirror (separate-table design)
sqlite3 "$DB" "INSERT OR REPLACE INTO activities (id,name,sport_type,start_local,moving_time) VALUES (301,'Heavy Lift','WeightTraining','2025-05-05T18:00:00Z',2700);"
n=$(sqlite3 "$DB" "SELECT COUNT(*) FROM ratings WHERE activity_id=301;")
[ "$n" = "1" ] || fail "rating must survive mirror replace"
"$STRIDE_BIN" analyze >/dev/null
# sport-aware progress: a rated strength session scores through the RPE lens
"$STRIDE_BIN" progress 2025-05-05 | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
g = d["groups"][0]
assert g["lens"] == "rpe", "rated strength must use the RPE lens: " + str(g)
assert abs(g["sessions"][0]["score"] - 5.0) < 0.01, "RPE score must be the rating: " + str(g)
print("progress RPE-lens OK (strength scored by rating)")
'
echo "rate OK (sRPE scores strength, re-rate rescores, rating survives re-sync, progress via RPE)"

# ── compare: this window vs the prior one ───────────────────────
"$STRIDE_BIN" compare week | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
assert d["period"] == "week" and d["window_label"] == "7d", d
for k in ("current", "prior"):
    for f in ("tss", "sessions", "hard_min", "easy_pct", "ctl"):
        assert f in d[k], f"{k} missing {f}"
# seeded recent rides land in the current window, not the prior one
assert d["current"]["sessions"] >= 1, d
print("compare OK (current vs prior blocks, all metrics present)")
'
out=$("$STRIDE_BIN" compare year); grep -q bad_period <<<"$out" || fail "compare must reject unknown periods"
echo "compare OK (week/month + bad-period guard)"

# ── doctor: coverage + provenance + honest gaps ──────────────────
"$STRIDE_BIN" doctor | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
assert d["activities"] > 0 and d["rated"] == 1, d
assert d["strength_unrated"] == 0, f"the one strength session is rated: {d}"
models = {m["model"]: m["n"] for m in d["scored_by"]}
assert models.get("session_rpe") == 1, models
# confidence distribution + config completeness (P8)
assert d["conf_high"] >= 1 and d["conf_medium"] >= 1, f"confidence must be populated: {d}"
# grill #1: confidence is derived from load_model at read time, not stored. Pin the
# SQL CASE to the provenance counts so the two mappings cannot drift apart.
power = models.get("power_stream", 0) + models.get("weighted_watts", 0) + models.get("avg_watts", 0)
assert d["conf_high"] == power, f"conf_high must equal power-rung provenance: {d['conf_high']} vs {power}"
assert d["ftp_set"] is True and d["zones_set"] is True, f"config completeness: {d}"
assert "pending_streams" in d, d
print("doctor OK (coverage, provenance, confidence, config)")
'

# time mode (P2): a valid IANA zone is DST-aware; a bad name never silently
# becomes UTC — it warns and falls back to the fixed offset.
"$STRIDE_BIN" config set timezone America/Chicago >/dev/null
"$STRIDE_BIN" doctor | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
assert d["time_ok"] is True, d
assert "America/Chicago" in d["time"] and "DST-aware" in d["time"], d
'
"$STRIDE_BIN" config set timezone Not/ARealZone >/dev/null
"$STRIDE_BIN" doctor | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
assert d["time_ok"] is False, f"bad zone must not report ok: {d}"
assert "UNKNOWN" in d["time"], d
'
"$STRIDE_BIN" config set timezone "" >/dev/null
echo "doctor time-mode OK (tz precedence + bad-zone fallback)"

# ── human output mode ────────────────────────────────────────────
out=$(STRIDE_FORMAT=human "$STRIDE_BIN" plan all); grep -Eq "date.+type.+status" <<<"$out" || fail "human table header"
# `plan` (no arg) is week-scoped: the far-future seeded sessions must NOT appear
out=$("$STRIDE_BIN" plan); python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; assert all(p["target_date"] < "2099" for p in d), "plan must be current-week only"' <<<"$out" || fail "plan week scope"
out=$(STRIDE_FORMAT=human "$STRIDE_BIN" activities); grep -Eq "date.+sport.+name" <<<"$out" || fail "activities header"
out=$(STRIDE_FORMAT=human "$STRIDE_BIN" load 7); grep -q "→ today: form" <<<"$out" || fail "load verdict line"
out=$(STRIDE_FORMAT=human "$STRIDE_BIN" stats); grep -q "ALL TIME" <<<"$out" || fail "stats human"
out=$(STRIDE_FORMAT=human "$STRIDE_BIN" activity 101); grep -Eq "^zones +Z1" <<<"$out" || fail "activity human zones row"
out=$(STRIDE_FORMAT=human "$STRIDE_BIN" summary); grep -q "stride report" <<<"$out" || fail "human summary"
out=$(STRIDE_FORMAT=human "$STRIDE_BIN" week); grep -q "OPEN PLAN" <<<"$out" || fail "human week bundle"
# STRIDE_FORMAT is case/space-insensitive: uppercase still selects JSON
STRIDE_FORMAT=JSON "$STRIDE_BIN" summary | python3 -c 'import json,sys; json.load(sys.stdin)["data"]; print("uppercase STRIDE_FORMAT OK")'
echo "human mode OK"

# ── schema migration: a legacy db upgrades to current with data intact (P6) ──
MIG_HOME=$(mktemp -d); mkdir -p "$MIG_HOME/.stride"
MIG_DB="$MIG_HOME/.stride/db.sqlite"
sqlite3 "$MIG_DB" < tests/fixtures/db/v1-legacy.sql
[ "$(sqlite3 "$MIG_DB" 'PRAGMA user_version;')" = "1" ] || fail "fixture must start at user_version 1"
# any command opens the db -> ensure_schema! runs migrations
HOME="$MIG_HOME" "$STRIDE_BIN" config get ftp >/dev/null
MIG_V=$(sqlite3 "$MIG_DB" 'PRAGMA user_version;')
[ "$MIG_V" -gt 1 ] || fail "migration must advance the schema version (got $MIG_V)"
# the prescriptions -> planned_sessions RENAME preserved the row (the risky one)
[ "$(sqlite3 "$MIG_DB" 'SELECT session_type FROM planned_sessions WHERE id=1;')" = "vo2max" ] || fail "rename must preserve the planned session row"
# new table + additive columns exist; old data survives
sqlite3 "$MIG_DB" "SELECT 1 FROM ratings LIMIT 0;" >/dev/null || fail "ratings table must be created"
sqlite3 "$MIG_DB" "SELECT load_model, metrics_rev, zones_used FROM activity_metrics LIMIT 0;" >/dev/null || fail "metric provenance columns must be added"
sqlite3 "$MIG_DB" "SELECT weighted_avg_watts FROM activities LIMIT 0;" >/dev/null || fail "weighted_avg_watts must be added"
[ "$(sqlite3 "$MIG_DB" 'SELECT COUNT(*) FROM activities;')" = "2" ] || fail "activities must survive migration"
# recompute works on the migrated db
HOME="$MIG_HOME" "$STRIDE_BIN" analyze >/dev/null || fail "analyze must run on a migrated db"
# idempotent: re-run stays at the current version with data intact
HOME="$MIG_HOME" "$STRIDE_BIN" config get ftp >/dev/null
[ "$(sqlite3 "$MIG_DB" 'PRAGMA user_version;')" = "$MIG_V" ] || fail "re-run must be idempotent (version changed)"
[ "$(sqlite3 "$MIG_DB" 'SELECT COUNT(*) FROM activities;')" = "2" ] || fail "re-run must not lose data"
rm -rf "$MIG_HOME"
echo "migration OK (legacy v1 db -> v$MIG_V, rename + data preserved, idempotent)"

echo "ALL CLI TESTS PASS"
