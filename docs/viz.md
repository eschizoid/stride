# The Form Board — `src/viz.roc`

A native window over the engine's PMC series, read live from
`~/.stride/db.sqlite`. This is ADR 0015 made real: pixels for the human, state
for the coach, the database as the bus. The window is a *second consumer* of
the SQLite — no export step, no baked data, nothing the CLI has to prepare.

## What it shows

- **Fitness** (CTL, blue, filled), **fatigue** (ATL, violet), **form** (TSB,
  teal — the brand accent) over the selected range.
- Daily load (TSS) as a rug along the bottom, on its own scale.
- Y-axis labels, current values at the line ends, the next planned event as a
  dashed marker.

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
`nightly-2026-08-23`, not the engine's pin. The pin lives in the app header of
`src/viz.roc`; point `ROC_VIZ` at a matching nightly if your PATH `roc` is the
engine's. CI checks it in its own job (`viz-check` in `build.yml`) with that
same tag.

## Boundaries this nightly imposes

- No F64→F32 narrowing exists, so the SQL query CASTs to integer tenths and
  the app divides by 10 — the numeric boundary belongs to SQL.
- No Env module on the platform; `HOME` is read by capturing `printenv` output
  through `Cmd`, at `init!` only.
- `has` is a reserved word; uppercase identifiers are types.
