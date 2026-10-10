#!/usr/bin/env bash
# The facts the take shows and the narration speaks, read from the demo home
# by stride itself, never typed by hand: the summary's fitness, fatigue, form
# and measured share; the week-over-week load and hard minutes; this week's
# skipped threshold session and the ride that replaced it, with its length and
# its minutes in Z4 and above; and the
# next Tuesday, which must already carry a planned threshold session for the
# take to give it a structured target. Written as KEY=value
# lines to $DEMO_DIR/facts.env; a fact stride cannot supply stops the take.
set -euo pipefail

DEMO_DIR="${DEMO_DIR:-/tmp/stride-demo}"
export HOME="$DEMO_DIR/home"
S="${STRIDE_BIN:-stride}"
out="$DEMO_DIR/facts.env"

sum=$($S summary --json)
cmp=$($S compare week --json)
wk=$($S week --json)
acts=$($S activities --json)

need() { [ -n "$2" ] && [ "$2" != "null" ] || { echo "facts: $1 is missing" >&2; exit 1; }; }

ctl=$(jq -r '.data.fitness_ctl | round' <<<"$sum");        need CTL "$ctl"
atl=$(jq -r '.data.fatigue_atl | round' <<<"$sum");        need ATL "$atl"
tsb=$(jq -r '.data.form_tsb | round' <<<"$sum");           need TSB "$tsb"
measured=$(jq -r '.data.last_28d.measured_pct' <<<"$sum");   need MEASURED "$measured"
load_pct=$(jq -r '(.data.current.tss - .data.prior.tss) / .data.prior.tss * 100 | round' <<<"$cmp"); need LOAD_PCT "$load_pct"
hard_prior=$(jq -r '.data.prior.hard_min' <<<"$cmp");  need HARD_PRIOR "$hard_prior"
hard_last=$(jq -r '.data.current.hard_min' <<<"$cmp");  need HARD_LAST "$hard_last"

row=$(jq -c '[.data[] | select(.status == "skipped" and .session_type == "threshold" and (.substitute_activity_id // 0) > 0)][0] // empty' <<<"$wk")
need "a skipped threshold session with a substitute this week" "$row"
skip_date=$(jq -r '.target_date // .date' <<<"$row")
trace=$(jq -r '.substitute_activity_id' <<<"$row")
sub=$(jq -c --argjson id "$trace" '[.data[] | select(.id == $id)][0] // empty' <<<"$acts"); need "the substitute ride $trace" "$sub"
sub_min=$(jq -r '.moving_time / 60 | round' <<<"$sub")
sub_hard=$(jq -r '(.z4_s + .z5_s) / 60 | round' <<<"$sub")
skip_day=$(date -j -f %Y-%m-%d "$skip_date" +%A)
next_tue=$(d=$(date +%Y-%m-%d); for i in 1 2 3 4 5 6 7; do n=$(date -j -v+${i}d -f %Y-%m-%d "$d" +%Y-%m-%d); [ "$(date -j -f %Y-%m-%d "$n" +%u)" = 2 ] && { echo "$n"; break; }; done)

tue_thr=$(sqlite3 "$HOME/.stride/db.sqlite" "SELECT COUNT(*) FROM planned_sessions WHERE target_date = '$next_tue' AND session_type = 'threshold' AND status = 'open';")
[ "$tue_thr" -ge 1 ] || { echo "facts: no open threshold session is planned on $next_tue" >&2; exit 1; }

{
  echo "CTL=$ctl"; echo "ATL=$atl"; echo "TSB=$tsb"
  echo "MEASURED=${measured}"; echo "LOAD_PCT=${load_pct#-}"
  echo "HARD_PRIOR=${hard_prior}"; echo "HARD_LAST=${hard_last}"
  echo "SKIP_DATE=$skip_date"; echo "SKIP_DAY=$skip_day"
  echo "TRACE=$trace"; echo "SUB_MIN=$sub_min"; echo "SUB_HARD=$sub_hard"; echo "NEXT_TUE=$next_tue"
} > "$out"
cat "$out"
