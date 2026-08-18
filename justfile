# stride — common actions. `just` alone runs the full test suite.

# overridable: ROC=/path/to/roc STRIDE_LINKER="--linker=legacy" just test
# The exact compiler version is pinned in .github/workflows/build.yml (nightly-tag), which
# is what CI installs and what a contributor should match. This resolves whatever `roc` is
# on PATH rather than pinning a path, so set ROC= if you keep several versions around.
roc := env("ROC", "roc")
linker := env("STRIDE_LINKER", "")
# port the e2e-sync mock binds and the driver targets; overridable when 8799 is occupied
mock_port := env("MOCK_PORT", "8799")

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
    {{roc}} test src/Backfill.roc
    {{roc}} test src/Csv.roc
    {{roc}} test src/Command.roc
    {{roc}} test src/Config.roc
    {{roc}} test --main=src/app.roc src/Streams.roc
    just build
    just e2e

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
# LOCAL-ONLY — it binds a port, so no CI job runs it. It exercises stride's sync path,
# which was ~50% flaky until bug C (#105) was root-caused to a basic-cli host double-free
# and fixed in 0.22.0. It runs SINGLE-SHOT now: the 5x retry that used to absorb that
# flake was deleted with the bug, and a new flake here deserves an investigation rather
# than another crutch.
#
# Do not read a green run here as "sync works". Every string in the mock fixture is short
# enough to live inline in a RocStr, and the corruption only bites heap-allocated decoded
# strings — so this suite is structurally incapable of reproducing the real-data failure
# that shipped once already. Real payloads need a real sync to verify.
e2e-sync:
    #!/usr/bin/env bash
    set -uo pipefail
    {{roc}} build tests/e2e.roc --output=e2e --opt=dev || exit 1
    test -x ./stride || { echo "e2e-sync needs a ./stride binary — run \`just build\` first"; exit 1; }
    E2E_MODE=mock MOCK_PORT={{mock_port}} ./e2e &
    MOCK=$!
    # kill the mock on ANY exit, including Ctrl-C — the old single-line form only killed
    # it on the success path, so an interrupted run left the port bound and every later
    # run failed to bind until someone found the stray process.
    #
    # EXIT alone, deliberately. Adding INT/TERM to a handler that does not itself exit
    # REPLACES the default terminate-on-signal, so Ctrl-C ran the cleanup and then carried
    # on through all five retries. Measured: with `EXIT INT TERM` a SIGTERM'd run completed
    # the whole loop and exited 0; with `EXIT` alone it stopped at once (143) and still ran
    # the cleanup, which is the behaviour we want.
    trap 'kill $MOCK 2>/dev/null' EXIT
    # single shot, no retry. The 5x retry loop that used to live here absorbed bug C's
    # ~50% flake; with the bug fixed (basic-cli 0.22.0, #105) the flake is gone —
    # measured 10/10 clean unretried on 2026-08-14. If this starts failing again it
    # should fail LOUDLY, not be absorbed: a new flake deserves a new investigation.
    E2E_MODE=sync STRIDE_API_BASE=http://127.0.0.1:{{mock_port}} ./e2e

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
