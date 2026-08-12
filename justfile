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
# LOCAL-ONLY (not in CI): it binds a port. It used to retry 5x because bug C made the
# sync path ~50% flaky; that retry is gone, because the retry is what would hide the
# next regression. Bug C is fixed at the source (a Str decoded from an HTTP body,
# bound into SQLite, aliased freed host memory — see save_tokens! in Strava.roc), so
# a failure here now means something is actually broken. One run, one verdict.
e2e-sync:
    {{roc}} build tests/e2e.roc --output=e2e --opt=dev
    test -x ./stride || {  echo "e2e-sync needs a ./stride binary — run \`just build\` first"; exit 1; }
    E2E_MODE=mock MOCK_PORT={{mock_port}} ./e2e & MOCK=$!; E2E_MODE=sync STRIDE_API_BASE=http://127.0.0.1:{{mock_port}} ./e2e; R=$?; kill $MOCK 2>/dev/null; exit $R

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
