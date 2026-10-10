#!/usr/bin/env bash
# The terminal half of a take, run inside the demo's Terminal window by
# take.sh. Each command is typed on screen a character at a time and then run
# for real against the demo home; nothing is pasted or replayed. Every prompt
# appends its epoch to $DEMO_DIR/marks, which compose.sh uses to place
# captions and narration: scenes.tsv names a scene by the mark it starts at,
# counting from 0 at the first prompt. After the second focus read (mark 12)
# it writes $DEMO_DIR/cue and waits there for the operator's key press in the
# window, which the third focus read reports.
set -uo pipefail

DEMO_DIR="${DEMO_DIR:?}"
# shellcheck disable=SC1091
. "$DEMO_DIR/facts.env"
export HOME="$DEMO_DIR/home" COLUMNS=99
export PATH="${STRIDE_BIN_DIR:?}:$PATH"

mark() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time' >> "$DEMO_DIR/marks"; }
prompt() { mark; printf '\033[38;5;79m❯\033[0m '; }
typed() {
  local s="$1" i ch
  for ((i = 0; i < ${#s}; i++)); do
    ch="${s:i:1}"; printf '%s' "$ch"
    case "$ch" in ' ') sleep 0.05 ;; *) sleep "0.0$((2 + RANDOM % 3))" ;; esac
  done
  sleep 0.35; printf '\n'
}
run() { typed "$1"; eval "$1"; prompt; }
blank() { clear; prompt; }

until [ -f "$DEMO_DIR/go" ]; do sleep 0.1; done
clear; mark; blank                                        # marks 0 and 1
sleep 8                                                   # title card
run "stride summary"; sleep 12                            # mark 2
blank; run "stride compare week"; sleep 9                # marks 3, 4
blank; run "stride week"; sleep 12                        # marks 5, 6
blank                                                     # mark 7
run "# show the athlete $SKIP_DAY's ride in the trace view"
run "sqlite3 ~/.stride/db.sqlite \"INSERT INTO viz_directives (view, trace_id) VALUES (2, $TRACE);\""
sleep 6                                                   # marks 8, 9
blank                                                     # mark 10
run "stride viz --json | jq -c '.data.history[0] | {id, status, error, trace_id}'"; sleep 1
run "stride viz --json | jq -c '.data.focus | {view, trace_id, trace_day, live}'"          # mark 12
: > "$DEMO_DIR/cue"; sleep 8
run "stride viz --json | jq -c '.data.focus | {view, trace_id, trace_day, live}'"; sleep 6  # mark 13
blank                                                     # mark 14
run "stride week add $NEXT_TUE threshold \"45min Peloton intervals, 3x10min @ 230W\" \"the week's one hard day\" \"3x10:00@230\""
run "sqlite3 ~/.stride/db.sqlite \"INSERT INTO viz_directives (view) VALUES (4);\""        # marks 15, 16
sleep 17                                                  # plan view, then the end card
: > "$DEMO_DIR/done"
