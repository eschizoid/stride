# stride — common actions. `just` alone runs the full test suite.

# overridable for CI: ROC=roc STRIDE_LINKER="--linker=legacy" just test
roc := env("ROC", env("HOME") / ".local/bin/roc")
linker := env("STRIDE_LINKER", "")
# new (Zig) compiler — builds the native-Roc test harness (tests/e2e.roc)
roc_new := env("ROC_NEW", env("HOME") / ".local/roc-new/roc")
# port the e2e-sync mock binds and the driver targets; overridable when 8799 is occupied
mock_port := env("MOCK_PORT", "8799")

default: test

# type-check without building
check:
    {{roc}} check src/app.roc

# build the release binary
build:
    {{roc}} build src/app.roc --output stride {{linker}}

# full suite: pure expects -> fresh build (must succeed!) -> effectful e2e
test:
    {{roc}} test src/Metrics.roc
    {{roc}} test src/Render.roc
    {{roc}} test src/Backfill.roc
    {{roc}} test src/Csv.roc
    {{roc}} test src/Command.roc
    {{roc}} test src/Config.roc
    {{roc}} test --main src/app.roc src/Streams.roc
    just build
    just e2e

# sync integration: ONE binary in two roles — a mock Strava server (E2E_MODE=mock)
# and a sync driver (E2E_MODE=sync) that runs real sync + token-refresh against it.
# Binds a port, so it's separate from `just test`. Runs against the ./stride binary.
e2e-sync:
    {{roc_new}} build tests/e2e.roc --output=e2e
    test -x ./stride || {  echo "e2e-sync needs a ./stride binary — native app.roc build is blocked by roc#10469; provide a prebuilt stride"; exit 1; }
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
week: build
    ./stride week

# quick form check
summary: build
    ./stride summary

# sync + analyze + summary in one go
up: sync analyze summary

# ── e2e test suite (native Roc: tests/e2e.roc — sandboxed HOME, no network) ──
e2e:
    {{roc_new}} build tests/e2e.roc --output=e2e
    test -x ./stride || {  echo "e2e needs a ./stride binary — native app.roc build is blocked by roc#10469; provide a prebuilt stride"; exit 1; }
    ./e2e
