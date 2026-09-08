# The Form Board — `src/viz/`

A native window over the engine's PMC series, read at launch from
`~/.stride/db.sqlite`. This is ADR 0015 made real: pixels for the human, state
for the coach, the database as the bus. The window is a *second consumer* of
the SQLite — no export step, no baked data, nothing the CLI has to prepare.

## What it shows

- **Fitness** (CTL, blue, filled), **fatigue** (ATL, violet), **form** (TSB,
  teal — the brand accent) over the selected range.
- Daily load (TSS) as a rug along the bottom, on its own scale.
- Y-axis labels, current values at the line ends, and the next planned event:
  a dashed in-plot marker when its date is inside the plotted window, or the
  event tile's countdown (in the KPI row) when it is beyond it. A future event
  usually takes the tile form — the series ends on the last analyzed day, so
  there is rarely a column to mark.

## What the form board shows

Big-number tiles carry the artifact's reading aids: fitness, fatigue and form
with their one-line meanings, plus an event slot that counts down to the next
event, says "ridden" for up to a week after one, and names the add command
when none is planned. The subtitle always carries the as-of day, and the TSB
zero rule is captioned "fresh above". The fourth TAB view is the artifact's
data table: the last 14 days as numbers.

## Controls

| key / gesture | effect |
|---|---|
| `1` / `2` / `3` | range 30 / 60 / 90 days (form board) |
| `←` / `→` | walk the day cursor (form board; ← older, → newer, past newest turns it off) |
| `R` | reload everything from the database without reopening |
| `TAB` | cycle views: form board / power curve / session trace / data table |
| `1` / `2` / `3` (curve view) | re-window the curve and CP fit to 30/60/90 days |
| `[` / `]` (trace view) | older / newer structured session, last 12 |
| `←` / `→` (table view) | scroll the 14-day window through the whole series |
| `S` | save a PNG of the current view into `./captures` |
| mouse hover | crosshair + per-day dots + a top-right readout (form board) |
| `ESC` | quit |

## Running it

```
just viz          # opens the window
just viz-check    # type-check only, no window
```

The viz pins **its own compiler** — roc-ray's platform needs
`nightly-2026-08-23-fb208ba`, not the engine's pin. The pin lives in the app header of
`src/viz/main.roc`; point `ROC_VIZ` at a matching nightly if your PATH `roc` is the
engine's. CI checks it in its own job (`viz-check` in `build.yml`) with that
same tag.

## Typography

Quicksand (the wordmark's rounded face) carries prose — titles, legends,
captions, hints. JetBrains Mono (the tagline's voice) carries data surfaces —
KPI digits, axis ticks, readouts and the table, mixed words included, so a
data line never switches face mid-string. Both ship in `assets/fonts/` (OFL) and
the app bundle copies them to `~/.stride/fonts`; when neither location
answers, the platform default font appears instead of a crash.

## The coach's seat (ADR 0015's bus)

The window is steerable and observable through two tables it maintains in the
same database — no sockets, no protocol, just SQL:

```sql
-- a coach writing before the window's first launch creates the table too
-- (the window runs the same DDL; IF NOT EXISTS makes the race harmless):
CREATE TABLE IF NOT EXISTS viz_directives (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  view INTEGER, range INTEGER, cursor_day TEXT, trace_day TEXT,
  consumed INTEGER NOT NULL DEFAULT 0);

-- steer: the window polls ~1/s, applies the newest unconsumed row, and
-- consumes everything up to it. NULL fields mean "leave that alone".
INSERT INTO viz_directives (view, range, cursor_day, trace_day)
VALUES (0, 30, '2026-09-02', NULL);
-- view 0..3 (form/curve/trace/table). range 30|60|90 lands on the view the
-- directive lands on: named view if set, else the visible one — on the curve
-- it re-windows the ladder+fit, on every other view it sets the form board's
-- range.
-- cursor_day parks the crosshair, trace_day picks the session

-- the window creates this too; a coach may pre-create it the same way:
CREATE TABLE IF NOT EXISTS viz_focus (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  updated_at TEXT NOT NULL,
  view INTEGER NOT NULL, range INTEGER NOT NULL,
  cursor_day TEXT, trace_day TEXT);

-- observe: one row, upserted when what the human sees changes (throttled ~2/s)
SELECT view, range, cursor_day, trace_day, updated_at FROM viz_focus;
```

A directive is consumed as read — one the window crashes on is dropped, never
replayed against a stale model. Focus writes are throttled (~2/s at most) and
only fire when what the human sees actually changed.

## Boundaries this nightly imposes

- No F64→F32 narrowing exists, so the SQL query CASTs to integer tenths and
  the app divides by 10 — the numeric boundary belongs to SQL.
- No Env module on the platform; `HOME` is read by capturing `printenv` output
  through `Cmd` — on every load, which means at launch and again on each `R`.
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

## Screenshots (S)

`S` writes a PNG of the current view into `./captures`, named for the view.
Reference captures of all three live in `docs/img/`.

These are how the agent reviews its own rendering. Every value drawn derives from
JSON the coach already reads losslessly, so a frame is worthless for judging
TRAINING — but it is the only way to see whether the drawing itself is right.
Adding this key immediately surfaced five defects in code that had type-checked
and had every data path diffed against the engine: a legend overprinting two
other views' titles, an em dash rendering as `?`, colliding axis labels, a count
shown as `3.0 bests`, and a CP asymptote described in a comment and never drawn.

![Form Board](img/form-board.png)

![Power curve](img/power-curve.png)

![Session trace](img/session-trace.png)
