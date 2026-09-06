# Spike: Form Board as a native RocRay window

A throwaway proof that ADR 0015's viz app is buildable, not vapor. It draws 90
days of the engine's PMC series — fitness (CTL), fatigue (ATL), form (TSB) — in
a native window, the same data the coach currently renders to an artifact.

**This is a spike, not a target.** It does not build in this repo's CI and is
not meant to: it depends on the RocRay platform, which currently pins
`nightly-2026-08-23-fb208ba` while this repo pins `nightly-2026-09-04-c125b82`.
That gap is the whole reason ADR 0015 stays Proposed. `spikes/` is outside
`src/` and `tests/` on purpose, so no gate touches it.

## What it proves

- RocRay apps pull a prebuilt platform from a release URL — no local zig, no
  host build. The first line of the app downloads it.
- The app checks parse-clean on RocRay's pin (08-23), and the real 90-day series
  bakes straight in as a Roc literal.
- The draw path is ordinary: `init!`/`update!`/`render!`, `Draw.line!` per
  segment, self-scaling to the data.

## Honest state

Written and parse-clean; ~7 type errors remain, all the `Dec`-vs-`F32` literal
defaulting documented in #371 (bare `0.0` in `F32` arithmetic infers `Dec`).
Finishing them is annotation work, not architecture, and was stopped here
deliberately — the spike had already answered the question it was built to ask.

## To run it (on RocRay's pin, not this repo's)

    git clone https://github.com/lukewilliamboswell/roc-ray.git
    cp spikes/roc-ray-form-board/main.roc roc-ray/examples/form_board.roc
    cd roc-ray
    # install nightly-2026-08-23-fb208ba, then:
    roc examples/form_board.roc

## The real design

Not this. The real app reads the series from the stride SQLite instead of a
baked literal, and is driven through the database — `viz_directives` coach to
window, `viz_focus` window to coach — per ADR 0015. This spike only proves the
window can exist and draw our numbers.
