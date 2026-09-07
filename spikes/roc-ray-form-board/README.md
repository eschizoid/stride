# Spike: Form Board as a native RocRay window — live from the database

A native window drawing the last 90 days of the engine's PMC series (fitness,
fatigue, form), read at launch directly from `~/.stride/db.sqlite` through
RocRay's own `Sqlite` module. No export step, no baked data: the app is a
second consumer of the database, which is ADR 0015's core claim, demonstrated.
Compiles clean and runs on this hardware (x86_64 macOS).

## What it proved

- RocRay's platform ships `Sqlite`, `Cmd`, `Task`, `Files`, `Http` — everything
  ADR 0015's db-bus needs is expressible on it. `Sqlite.Db.open!` + `query!` +
  `Row.i64` read stride's `daily_load` in `init!`.
- The numeric boundary belongs to SQL. This nightly has no F64-to-F32
  narrowing, so the query CASTs to integer tenths and `I64.to_f32 / 10`
  restores the one-decimal fidelity the board displays anyway. Same instinct
  as the repo's CAST-at-the-projection blob rule.
- Prebuilt platform from a release URL: no zig, no host build, one `roc`
  command to run.

## Why it still cannot merge

RocRay pins `nightly-2026-08-23`; this repo pins `nightly-2026-09-04`, past
the ordering-API rename. One toolchain per repo is ADR 0015 decision 4, so
this waits in `spikes/` — outside every gate — until RocRay crosses the
rename.

## To run (on RocRay's pin, not this repo's)

    git clone https://github.com/lukewilliamboswell/roc-ray.git
    mkdir -p roc-ray/examples/stride_form_board
    cp spikes/roc-ray-form-board/main.roc roc-ray/examples/stride_form_board/
    cd roc-ray
    # install nightly-2026-08-23-fb208ba, then:
    roc examples/stride_form_board/main.roc

ESC quits. A database that will not open is reported on screen, not fatal.

## Distance to the real thing

Remaining work is plumbing, not research: a `Task` polling `viz_directives`
(coach to window) a few times a second, `viz_focus` written back (window to
coach), and the interaction layer. The architecture risk this spike existed
to retire is retired.
