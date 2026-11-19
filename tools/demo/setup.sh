#!/usr/bin/env bash
# The demo's athlete home: a copy of the database in a scratch directory, so
# the recording never touches ~/.stride and runs offline. The Strava login
# (access and refresh tokens, client id and secret) is deleted from the copy:
# nothing in the demo needs it, and with it gone no command on screen can
# print it. The frozen snapshot in ~/.stride-demo/snapshot.sqlite is preferred
# when present, so a retake shows the same facts as the first take.
set -euo pipefail

DEMO_DIR="${DEMO_DIR:-/tmp/stride-demo}"
home="$DEMO_DIR/home"
snap="$HOME/.stride-demo/snapshot.sqlite"
src="${STRIDE_DEMO_DB:-$([ -f "$snap" ] && echo "$snap" || echo "$HOME/.stride/db.sqlite")}"

/bin/rm -rf "$home"
mkdir -p "$home/.stride"
sqlite3 "$src" ".backup '$home/.stride/db.sqlite'"
for d in fonts img; do
  [ -d "$HOME/.stride/$d" ] && /bin/cp -Rf "$HOME/.stride/$d" "$home/.stride/"
done
sqlite3 "$home/.stride/db.sqlite" <<'SQL'
DELETE FROM config WHERE key IN ('strava_access_token', 'strava_refresh_token', 'strava_client_id', 'strava_client_secret');
DROP TABLE IF EXISTS viz_directives;
DROP TABLE IF EXISTS viz_focus;
SQL
left=$(sqlite3 "$home/.stride/db.sqlite" "SELECT COUNT(*) FROM config WHERE key LIKE 'strava_%token' OR key LIKE 'strava_client_%';")
[ "$left" = "0" ] || { echo "setup: the Strava login is still in the demo copy" >&2; exit 1; }
echo "$home"
