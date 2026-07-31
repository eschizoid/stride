#!/usr/bin/env bash
set -euo pipefail
# ── Sync integration against a mock Strava API (network-free) ────────────────
# Boots tests/mock_strava.roc, points stride at it via STRIDE_API_BASE, and drives
# the REAL sync path — including a TOKEN REFRESH (seeded expired token) that the
# plain e2e never reaches. Kept out of `just test` because it binds a port; runs
# as its own CI step.
#
# TODO(follow-up): also assert 429 rate-limit backoff. That needs a stateful mock
# that returns 429-then-200; today mock_strava.roc is stateless.

STRIDE_BIN="${STRIDE_BIN:-$PWD/stride}"
MOCK_BIN="${MOCK_BIN:-$PWD/mock_strava}"
PORT="${MOCK_PORT:-8799}"
export ROC_BASIC_WEBSERVER_PORT="$PORT"
BASE="http://127.0.0.1:${PORT}"
export STRIDE_API_BASE="$BASE"
export STRIDE_FORMAT=json

fail() { echo "FAIL: $1" >&2; exit 1; }

SANDBOX="$(mktemp -d)"
export HOME="$SANDBOX"
DB="$HOME/.stride/db.sqlite"

# boot the mock server; always clean it up
"$MOCK_BIN" &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

# wait for readiness (up to ~10s) instead of a fixed sleep
ready=""
for _ in $(seq 1 50); do
  if curl -sf -m 1 -X POST "$BASE/oauth/token" >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.2
done
[ -n "$ready" ] || fail "mock server never came up on $BASE"
echo "mock strava up on $BASE"

# seed config, then an EXPIRED token (expires_at in the past) so sync MUST refresh
"$STRIDE_BIN" init >/dev/null
for kv in "ftp 200" "hr_z1_max 123" "hr_z2_max 153" "hr_z3_max 168" "hr_z4_max 183"; do
  "$STRIDE_BIN" config set $kv >/dev/null 2>&1 || true
done
sqlite3 "$DB" "INSERT OR REPLACE INTO config (key,value) VALUES
  ('strava_client_id','1'),('strava_client_secret','shh'),
  ('strava_access_token','stale-access'),('strava_refresh_token','stale-refresh'),
  ('strava_expires_at','1');"

# sync: must refresh the expired token, then pull activities + streams from the mock
"$STRIDE_BIN" sync >/dev/null 2>&1 || fail "sync failed against mock"

# the expired token was refreshed via /oauth/token (stale-access -> mock-access)
tok=$(sqlite3 "$DB" "SELECT value FROM config WHERE key='strava_access_token';")
[ "$tok" = "mock-access" ] || fail "expired token must refresh via /oauth/token, got '$tok'"
echo "token refresh OK (expired -> mock-access)"

# both mock activities synced (501 power ride + 502 hr row)
"$STRIDE_BIN" analyze >/dev/null
n=$("$STRIDE_BIN" activities | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["data"]))')
[ "$n" = "2" ] || fail "expected 2 mock activities synced, got $n"

# 501 carries real power streams -> it scores a positive load
"$STRIDE_BIN" activity 501 | python3 -c '
import json, sys
a = json.load(sys.stdin)["data"]
assert a["tss"] > 0, f"501 should score from its power streams: {a}"
'
echo "sync integration OK (token refresh + 2 activities + streams)"
