# stride — common actions. `just` alone runs the full test suite.

# overridable for CI: ROC=roc STRIDE_LINKER="--linker=legacy" just test
roc := env("ROC", env("HOME") / ".local/bin/roc")
linker := env("STRIDE_LINKER", "")

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
    {{roc}} test --main src/app.roc src/Streams.roc
    just build
    just e2e

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

# ── e2e test suite (implementation: tests/e2e.sh — sandboxed HOME, no network) ──
e2e:
    tests/e2e.sh
