# The Form Board — `src/viz.roc`

A native window over the engine's PMC series, read at launch from
`~/.stride/db.sqlite`. This is ADR 0015 made real: pixels for the human, state
for the coach, the database as the bus. The window is a *second consumer* of
the SQLite — no export step, no baked data, nothing the CLI has to prepare.

## What it shows

- **Fitness** (CTL, blue, filled), **fatigue** (ATL, violet), **form** (TSB,
  teal — the brand accent) over the selected range.
- Daily load (TSS) as a rug along the bottom, on its own scale.
- Y-axis labels, current values at the line ends, and the next planned event:
  a dashed in-plot marker when its date is inside the plotted window, or a
  header countdown (`name  Nd`) when it is beyond it. A genuine future event
  usually takes the second form — the series ends on the last analyzed day, so there is no column
  to draw a marker on.

## Controls

| key / gesture | effect |
|---|---|
| `1` / `2` / `3` | range 30 / 60 / 90 days |
| mouse hover | crosshair + per-day dots on all three series |
| `ESC` | quit |

## Running it

```
just viz          # opens the window
just viz-check    # type-check only, no window
```

The viz pins **its own compiler** — roc-ray's platform needs
`nightly-2026-08-23-fb208ba`, not the engine's pin. The pin lives in the app header of
`src/viz.roc`; point `ROC_VIZ` at a matching nightly if your PATH `roc` is the
engine's. CI checks it in its own job (`viz-check` in `build.yml`) with that
same tag.

## Boundaries this nightly imposes

- No F64→F32 narrowing exists, so the SQL query CASTs to integer tenths and
  the app divides by 10 — the numeric boundary belongs to SQL.
- No Env module on the platform; `HOME` is read by capturing `printenv` output
  through `Cmd`, at `init!` only.
- `has` is a reserved word; uppercase identifiers are types.

## Power-curve view (TAB)

A second screen: the power-duration ladder for the Ride family over the last 90
days, as points, with the CP fit summarised in the header.

The **points** come from the stored per-activity bests (`activity_metrics.best_*_w`),
maxed over the window. `CAST(ROUND(...))` matters — a bare `CAST` truncates and
draws the whole ladder a watt low, which was caught by diffing all seven rungs
against `stride power-curve 90 Ride --json`.

**CP, W′ and r2 come from the engine**, not from a second regression here. The fit
is `Metrics.hyperbolic_fit`'s job and a copy in the viz would drift from it, so the
view shells out to `stride power-curve --json` and extracts each field
independently — key ORDER cannot silently break the parse, and a missing field
shows "CP fit unavailable" rather than a fit of zeros.

Rungs are spaced by INDEX rather than by duration: the ladder is a fixed 5s..20min
set, and a linear time axis piles the six short rungs onto the left edge.

## Session trace view (TAB)

The third screen: the most recent session that has detected work blocks, drawn as
its power trace with the detector's blocks shaded behind it — work in the accent,
recovery and warm-up/cool-down in grey.

This is the view #372 calls "auditable". A table of segments can tell you the
detector found seven work blocks; only the overlay tells you whether a block
started before the power did.

The trace is **downsampled in SQL** to ~800 points. A 45-minute ride carries ~2700
samples against ~830 pixels of plot, so drawing all of them costs three line
segments per pixel and shows nothing more. `json_each` reads the stored stream
directly — SQLite has JSON1, and this platform has no JSON decoder.

Both axes divide by the SAME duration, taken from the stream's last timestamp.
Deriving it from the segments instead would stretch partial detector coverage
across the full width; on the reference activity the two differ by one second in
2700, which is sub-pixel and would have hidden the bug rather than shown it.
