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

# build the binary. --opt=dev on purpose: the optimized (--opt=speed) LLVM backend is
# the default, but it miscompiles (issue #32's intermittent SIGABRT, and it drops the
# progress pace column) — so CI and the release workflow both pin dev. Match them here,
# or `just test` tests a binary nobody ships.
build:
    {{roc}} build src/app.roc --output=stride --opt=dev {{linker}}

# full suite: pure expects -> fresh build (must succeed!) -> effectful e2e
test:
    {{roc}} test src/Metrics.roc
    {{roc}} test src/Render.roc
    {{roc}} test src/Backfill.roc
    {{roc}} test src/Csv.roc
    {{roc}} test src/Command.roc
    {{roc}} test src/Config.roc
    {{roc}} test --main=src/app.roc src/Streams.roc
    just build
    just e2e

# sync integration: ONE binary in two roles — a mock Strava server (E2E_MODE=mock)
# and a sync driver (E2E_MODE=sync) that runs real sync + token-refresh against it.
# Binds a port, so it's separate from `just test`. Runs against the ./stride binary.
# LOCAL-ONLY — it binds a port, so no CI job runs it. It exercises stride's sync path,
# which is ~50% flaky on the current nightly (issue #105: heap corruption, still
# uncharacterised at the source). Retried 5x because sync is idempotent, so a retry is
# free. Fixing #105 is what would make this dependable enough for CI to adopt.
#
# The retry is a crutch and will equally mask a genuine regression, which is why the
# message it prints stays neutral instead of blaming #105 for every failure.
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
