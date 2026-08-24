# stride — common actions. `just` alone runs the full test suite.

# overridable: ROC=/path/to/roc STRIDE_LINKER="--linker=legacy" just test
# The exact compiler version is pinned in .github/workflows/build.yml (nightly-tag), which
# is what CI installs and what a contributor should match. This resolves whatever `roc` is
# on PATH rather than pinning a path, so set ROC= if you keep several versions around.
roc := env("ROC", "roc")
linker := env("STRIDE_LINKER", "")
# port the e2e-sync mock binds and the driver targets; overridable when 8799 is occupied
mock_port := env("MOCK_PORT", "8799")
# second mock instance, serving undecodable stream bodies (sync's undecodable-stream skip path)
bad_stream_port := env("BAD_STREAM_PORT", "8798")
# third instance, 429ing forever on one id (sync's rate_limited stop reason)
rate_limit_port := env("RATE_LIMIT_PORT", "8797")
# fifth instance, 500ing on one id (the 5xx boundary arm, salvaged from #225)
http500_port := env("HTTP500_PORT", "8795")
# sixth instance, 429ing on the LISTING (the list-429 stop, #235)
list429_port := env("LIST429_PORT", "8794")
# seventh instance, serving a FULL page then 429ing page two (the partial-progress half)
list429p_port := env("LIST429P_PORT", "8793")
# fourth instance, 401ing forever on one id (the token-refresh retry bound, #232)
auth401_port := env("AUTH401_PORT", "8796")

default: test

# type-check without building
check:
    {{roc}} check src/app.roc

# build the binary. --opt=dev on purpose, but for BUILD TIME (~14s against ~2min), not
# correctness: the optimized backend's miscompile (#32) was fixed by the 2026-08-17 pin.
# CI and the release workflow both pin dev, so match them here or `just test` tests a
# binary nobody ships.
build:
    {{roc}} build src/app.roc --output=stride --opt=dev {{linker}}

# full suite: pure expects -> fresh build (must succeed!) -> effectful e2e
test:
    {{roc}} test src/Metrics.roc
    {{roc}} test src/Sports.roc
    {{roc}} test src/Render.roc
    {{roc}} test src/Drain.roc
    {{roc}} test src/Csv.roc
    {{roc}} test src/Command.roc
    {{roc}} test src/Config.roc
    {{roc}} test --main=src/app.roc src/Streams.roc
    just build
    just e2e

# every `#NNN` in a source comment is a claim about an issue's state; this checks the
# mechanical half of it against the tracker. Needs `gh` auth, so it is its own recipe
# rather than part of `test` -- a suite that fails without network is worse than no check.
issue-claims:
    bash tools/issue-claims.sh

# validate this machine's real payloads against the published contract
# (schemas/v2/*.json). e2e runs the same validator against fixtures; this is the
# "does MY data conform" pass, for after a schema or payload change. Depends on
# build so it can never report "conforms" because ./stride was missing, and it
# EXITS NON-ZERO on a violation — a checker that always succeeds is decoration.
schema-check: build
    #!/usr/bin/env sh
    # No `set -e`: each capture is allowed to fail so the `if` below can PRINT
    # what went wrong. Under set -e the shell aborted on the failing pipeline
    # and the diagnostic — already captured, thanks to 2>&1 — was never shown.
    rc=0
    # `commands` needs no database, so it is the one payload check that can
    # never be skipped — a real contract test even on a fresh install
    errs=$(STRIDE_FORMAT=json ./stride --help 2>&1 | jq '.data' 2>&1 | jq -r --slurpfile schema schemas/v2/commands.json -f tools/validate.jq 2>&1 || true)
    if [ -n "$errs" ]; then echo "commands:"; echo "$errs"; rc=1; else echo "commands: conforms"; fi
    # schema name : invocation — they differ where a command needs an argument
    # (top) or where the file name cannot carry a dash (power_curve)
    for pair in summary:summary plan:plan activities:activities top:"top tss" load:load \
                stats:stats doctor:doctor zones:zones compare:compare progress:progress \
                week:week power_curve:power-curve tte:"tte 300" reps:reps season:season; do
        c="${pair%%:*}"
        inv=$(printf '%s' "${pair#*:}" | tr -d '"')
        out=$(STRIDE_FORMAT=json ./stride $inv 2>&1 || true)
        # a command that legitimately has nothing to say (fresh install, no
        # activities) returns an error ENVELOPE; that is the database being
        # empty, not the contract being violated, so skip rather than accuse
        # a BROKEN install is not "legitimately nothing to say" — no_database
        # and friends must fail the check rather than read as a skip (#183 gave
        # them envelopes, which is exactly what made them skippable)
        code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)
        case "$code" in
            no_database|unreadable_database|corrupt_database|database_error)
                echo "$inv: FAILED ($code)"; rc=1; continue ;;
        esac
        if printf '%s' "$out" | jq -e 'has("error")' >/dev/null 2>&1; then
            echo "$inv: skipped ($(printf '%s' "$out" | jq -r '.error.code'))"
            continue
        fi
        errs=$(printf '%s' "$out" | jq '.data' 2>&1 | jq -r --slurpfile schema schemas/v2/$c.json -f tools/validate.jq 2>&1 || true)
        if [ -n "$errs" ]; then echo "$inv:"; echo "$errs"; rc=1; else echo "$inv: conforms"; fi
    done
    act=$(STRIDE_FORMAT=json ./stride activities 1 2>&1 | jq -r '.data[0].id // empty' 2>&1 || true)
    if [ -n "$act" ]; then
        errs=$(STRIDE_FORMAT=json ./stride activity "$act" 2>&1 | jq '.data' 2>&1 | jq -r --slurpfile schema schemas/v2/activity.json -f tools/validate.jq 2>&1 || true)
        if [ -n "$errs" ]; then echo "activity $act:"; echo "$errs"; rc=1; else echo "activity $act: conforms"; fi
    else
        echo "activity: skipped (no activities yet)"
    fi
    # the envelope schema covers BOTH arms, so this one is never skipped
    errs=$(STRIDE_FORMAT=json ./stride summary 2>&1 | jq -r --slurpfile schema schemas/v2/envelope.json -f tools/validate.jq 2>&1 || true)
    if [ -n "$errs" ]; then echo "envelope:"; echo "$errs"; rc=1; else echo "envelope: conforms"; fi
    for f in schemas/v2/*.json; do
        lint=$(jq -r -f tools/schema-lint.jq "$f" 2>&1 || true)
        if [ -n "$lint" ]; then echo "$lint"; rc=1; fi
    done
    exit $rc

# sync integration: ONE binary in two roles — a mock Strava server (E2E_MODE=mock)
# and a sync driver (E2E_MODE=sync) that runs real sync + token-refresh against it.
# Binds a port, so it's separate from `just test`. Runs against the ./stride binary.
# Runs in CI as well as locally: it binds only loopback and needs no credential. It exercises stride's sync path,
# which was ~50% flaky until bug C (#105) was root-caused to a basic-cli host double-free
# and fixed in 0.22.0. It runs SINGLE-SHOT now: the 5x retry that used to absorb that
# flake was deleted with the bug, and a new flake here deserves an investigation rather
# than another crutch.
#
# Do not read a green run here as "sync works". Every string in the mock fixture is short
# enough to live inline in a RocStr, and the corruption only bites heap-allocated decoded
# strings — so this suite is structurally incapable of reproducing the real-data failure
# that shipped once already. Real payloads need a real sync to verify.
# depends on `build` for the same reason `just test` does: this recipe rebuilt ./e2e
# but NOT ./stride, so editing source and re-running silently tested the PREVIOUS
# binary. That cost a reviewer a wrong diagnosis — a failure reported from code that
# was no longer on disk. AGENTS.md already names the stale-binary hazard for a FAILED
# build; a successful build of since-reverted source is the same trap.
e2e-sync: build
    #!/usr/bin/env bash
    set -uo pipefail
    {{roc}} build tests/e2e.roc --output=e2e --opt=dev || exit 1
    E2E_MODE=mock MOCK_PORT={{mock_port}} ./e2e &
    MOCK=$!
    # kill the mock on ANY exit, including Ctrl-C — the old single-line form only killed
    # it on the success path, so an interrupted run left the port bound and every later
    # run failed to bind until someone found the stray process.
    #
    # EXIT alone, deliberately. Adding INT/TERM to a handler that does not itself exit
    # REPLACES the default terminate-on-signal, so Ctrl-C ran the cleanup and then carried
    # on instead of stopping. Measured back when the 5x retry loop below still existed:
    # with `EXIT INT TERM` a SIGTERM'd run completed all five retries and exited 0; with
    # `EXIT` alone it stopped at once (143) and still ran the cleanup. The loop is gone,
    # so that exact measurement is no longer reproducible here, but the signal-handling
    # rule it established is why this trap names only EXIT.
    trap 'kill $MOCK 2>/dev/null' EXIT
    # single shot, no retry. The 5x retry loop that used to live here absorbed bug C's
    # ~50% flake; with the bug fixed (basic-cli 0.22.0, #105) the flake is gone —
    # measured 10/10 clean unretried on 2026-08-14. If this starts failing again it
    # should fail LOUDLY, not be absorbed: a new flake deserves a new investigation.
    E2E_MODE=sync STRIDE_API_BASE=http://127.0.0.1:{{mock_port}} ./e2e || exit 1
    # a SECOND mock, serving stream bodies that are not UTF-8, for the skip path.
    # Separate instance rather than a flag on the first: the 404-marker fixture in the
    # sync scenario has to stay exactly as it is, and one process cannot be both.
    E2E_MODE=mock E2E_BAD_STREAM=1 MOCK_PORT={{bad_stream_port}} ./e2e &
    BADMOCK=$!
    trap 'kill $MOCK $BADMOCK 2>/dev/null' EXIT
    E2E_MODE=skips STRIDE_API_BASE=http://127.0.0.1:{{bad_stream_port}} ./e2e || exit 1
    # budget_reached needs no special mock — just a read budget of 1 against the main one
    E2E_MODE=stops STRIDE_API_BASE=http://127.0.0.1:{{mock_port}} ./e2e || exit 1
    # rate_limited needs a mock that 429s forever on one id
    E2E_MODE=mock E2E_RATE_LIMIT=1 MOCK_PORT={{rate_limit_port}} ./e2e &
    RLMOCK=$!
    trap 'kill $MOCK $BADMOCK $RLMOCK 2>/dev/null' EXIT
    E2E_MODE=stops E2E_EXPECT_RATE_LIMIT=1 STRIDE_API_BASE=http://127.0.0.1:{{rate_limit_port}} ./e2e || exit 1
    # a persistent 401, to prove the token-refresh retry is bounded
    E2E_MODE=mock E2E_STREAM_401=1 E2E_ROTATING_TOKEN=1 MOCK_PORT={{auth401_port}} ./e2e &
    A401MOCK=$!
    trap 'kill $MOCK $BADMOCK $RLMOCK $A401MOCK 2>/dev/null' EXIT
    E2E_MODE=stops E2E_EXPECT_401=1 STRIDE_API_BASE=http://127.0.0.1:{{auth401_port}} ./e2e || exit 1
    # a 5xx mid-drain, with rows already committed
    E2E_MODE=mock E2E_HTTP500=1 MOCK_PORT={{http500_port}} ./e2e &
    P5MOCK=$!
    trap 'kill $MOCK $BADMOCK $RLMOCK $A401MOCK $P5MOCK 2>/dev/null' EXIT
    E2E_MODE=stops E2E_EXPECT_500=1 STRIDE_API_BASE=http://127.0.0.1:{{http500_port}} ./e2e || exit 1
    # EVERY driver line ends `|| exit 1`. This recipe runs under `set -uo pipefail` with
    # no `-e`, so a bare line's failure is swallowed unless it happens to be the last
    # command — which is how appending this block silently disarmed the 5xx driver above.
    #
    # a 429 on the LISTING, which nothing exercised before #235
    E2E_MODE=mock E2E_LIST_RATE_LIMIT=1 MOCK_PORT={{list429_port}} ./e2e &
    L429MOCK=$!
    trap 'kill $MOCK $BADMOCK $RLMOCK $A401MOCK $P5MOCK $L429MOCK 2>/dev/null' EXIT
    E2E_MODE=mock E2E_LIST_RATE_LIMIT=2 MOCK_PORT={{list429p_port}} ./e2e &
    L429P=$!
    trap 'kill $MOCK $BADMOCK $RLMOCK $A401MOCK $P5MOCK $L429MOCK $L429P 2>/dev/null' EXIT
    E2E_MODE=stops E2E_EXPECT_LIST_429=1 E2E_LIST_PARTIAL_BASE=http://127.0.0.1:{{list429p_port}} STRIDE_API_BASE=http://127.0.0.1:{{list429_port}} ./e2e || exit 1

# build + refresh the ~/.local/bin symlink
install: build
    ln -sf "$PWD/stride" "$HOME/.local/bin/stride"

# ── daily driving ────────────────────────────────────────────────────
# these depend on `build` so a fresh clone's `just up` works without a
# separate build step (the ./stride binary is gitignored)

# pull new activities + streams from Strava
sync: build
    ./stride sync

# recompute metrics + daily load, print the report
analyze: build
    ./stride analyze

# weekly planning payload (human tables in a terminal)
plan: build
    ./stride plan

# quick form check
summary: build
    ./stride summary

# sync + analyze + summary in one go
up: sync analyze summary

# ── e2e test suite (native Roc: tests/e2e.roc — sandboxed HOME, no network) ──
e2e:
    {{roc}} build tests/e2e.roc --output=e2e --opt=dev
    test -x ./stride || {  echo "e2e needs a ./stride binary — run \`just build\` first"; exit 1; }
    ./e2e
