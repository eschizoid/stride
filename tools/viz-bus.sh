#!/usr/bin/env sh
# Drives the window headless (`--host-headless`, which draws nothing and
# needs no display) through its own bus against a fake home holding a short
# series and a written plan, and reads what the window wrote back: each
# directive's status, error and result, and the focus row. It proves the bus
# contract the window enforces, which a seeded e2e row cannot:
#
# - a row written before launch waits for the boot load: the engine's
#   `project` answers two seconds late here, so a poll that ran during the
#   boot would judge the day against the boot skeleton's empty series;
# - a cursor_day on a projected day lands on the form board and focus
#   reports it;
# - a capture's result names a file only once one exists: a headless host
#   answers a screenshot without writing, so the PNG closes with its reason
#   and no result;
# - a view that draws no projection holds the latest measured day in place
#   of a projected one, refuses a projected cursor_day by name, and a day
#   past the projection is refused with the projection's last day.
#
# usage: sh tools/viz-bus.sh <stride command> <window binary>
set -eu

[ $# -eq 2 ] || { echo "usage: sh tools/viz-bus.sh <stride command> <window binary>" >&2; exit 2; }
command -v sqlite3 >/dev/null 2>&1 || { echo "viz-bus: needs sqlite3" >&2; exit 2; }
abs() { (cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")"); }
cli="$(abs "$1")"
viz="$(abs "$2")"
[ -x "$cli" ] || { echo "viz-bus: $cli is not an executable" >&2; exit 2; }
[ -x "$viz" ] || { echo "viz-bus: $viz is not an executable" >&2; exit 2; }

work="$(mktemp -d)"
pid=""
cleanup() {
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM
home="$work/home"; launch="$work/launch"; bin="$work/bin"
mkdir -p "$home" "$launch" "$bin"

# the window runs `stride` from its PATH; this one is the real command, made
# two seconds slow to answer `project`, which the boot load calls
cat > "$bin/stride" <<EOF
#!/bin/sh
[ "\${1:-}" = project ] && sleep 2
exec "$cli" "\$@"
EOF
chmod +x "$bin/stride"

HOME="$home" PATH="$bin:$PATH" stride init >/dev/null
db="$home/.stride/db.sqlite"
q() { sqlite3 -cmd '.timeout 5000' "$db" "$1"; }

fail() {
  echo "viz-bus: FAIL $1" >&2
  echo "viz-bus: the window's output:" >&2
  tail -n 40 "$work/window.log" >&2 2>/dev/null || true
  exit 1
}

# forty measured days ending today, and four planned sessions after it
q "WITH RECURSIVE d(n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM d WHERE n < 39)
   INSERT INTO daily_load (day, tss, ctl, atl, tsb)
   SELECT date('now', 'localtime', '-' || n || ' day'), 50.0, 40.0, 45.0, -5.0 FROM d;"
today="$(q "SELECT today FROM series_clock")"
day() { q "SELECT date('$today', '+$1 day')"; }
for n in 1 2 3 4; do
  HOME="$home" PATH="$bin:$PATH" stride week add "$(day "$n")" ride "45 minutes easy" "base" 1x45:00@RPE6 >/dev/null
done
proj_day="$(day 3)"
plan_end="$(day 4)"
beyond="$(day 30)"

# the window creates the bus tables on its first poll; a coach writing before
# that creates them the same way
q "CREATE TABLE IF NOT EXISTS viz_directives (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     created_at TEXT NOT NULL DEFAULT (datetime('now')),
     view INTEGER, range INTEGER, cursor_day TEXT, trace_day TEXT,
     ghost_day TEXT, trace_id INTEGER, ghost_id INTEGER, capture TEXT,
     consumed INTEGER NOT NULL DEFAULT 0,
     status TEXT NOT NULL DEFAULT 'pending',
     error TEXT, result TEXT, applied_at TEXT);"

# writes a directive and prints its id
direct() { q "INSERT INTO viz_directives ($1) VALUES ($2); SELECT last_insert_rowid();"; }

# waits, while the window runs and at most `limit` seconds, for a query to
# print something, and leaves it in $answer
limit=60
await() {
  waited=0
  while [ "$waited" -lt "$limit" ]; do
    answer="$(q "$2" 2>/dev/null || true)"
    [ -n "$answer" ] && return 0
    kill -0 "$pid" 2>/dev/null || fail "the window ended while waiting for $1"
    sleep 1; waited=$((waited + 1))
  done
  fail "no answer within ${limit}s for $1"
}
closed() { await "directive $1 to close" "SELECT status || '|' || COALESCE(error, '') || '|' || COALESCE(result, '') FROM viz_directives WHERE id = $1 AND status <> 'pending'"; }
expect() { [ "$answer" = "$2" ] || fail "$1: got '$answer', want '$2'"; }

first="$(direct "view, cursor_day, capture" "0, '$proj_day', 'png'")"
cd "$launch"
HOME="$home" PATH="$bin:$PATH" "$viz" --host-headless --host-headless-frames=1000000 "$home/.stride" "$launch" > "$work/window.log" 2>&1 &
pid=$!

closed "$first"
expect "a capture written at launch, of a projected day on the board" "applied_partial|capture png failed: the host answered but wrote no file|"
await "focus on the projected day" "SELECT view || '|' || cursor_day FROM viz_focus WHERE cursor_day = '$proj_day'"
expect "focus after the launch directive" "0|$proj_day"

id="$(direct "view" "3")"
closed "$id"
expect "the table after the board's projected day" "applied||"
await "focus on the table" "SELECT view || '|' || COALESCE(cursor_day, '') FROM viz_focus WHERE view = 3"
expect "the table holds the latest measured day" "3|$today"

id="$(direct "view, cursor_day" "3, '$proj_day'")"
closed "$id"
expect "a projected day on the table" "applied_partial|cursor_day $proj_day not in the series: a projected day, and this view draws no projection|"

id="$(direct "view, cursor_day" "0, '$beyond'")"
closed "$id"
expect "a day past the projection" "applied_partial|cursor_day $beyond not in the series: past the projection's last day, $plan_end|"

echo "viz-bus: the window waited for its boot load, held the bus contract on the board and the table, and named no file it did not write"
