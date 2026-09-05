# 0015 — a viz app is a second consumer of the database, never a mode of the engine

Proposed 2026-09-05 (#372).

## Context

The engine computes dense time series and publishes them as tables and JSON. Two of those
series carry their meaning in their shape, which a table cannot show. The PMC series
(CTL/ATL/TSB, already emitted daily by `stride load`) is read for its curve: ramps, holds,
and the taper's rise are visible in a plot and invisible in three-digit deltas. And the
interval detector's segments (ADR 0008) are currently unauditable: the engine reports
`7×[3:00 @ 282W]`, but nothing shows the power trace with those blocks shaded on it, so
whether the boundaries land where a human would put them is taken on trust.

[roc-ray](https://github.com/lukewilliamboswell/roc-ray) makes a native viz app cheap for
this codebase specifically. It is a Roc platform over raylib — drawing, keyboard and mouse,
windows, deterministic GIF/WebM recording — on macOS Intel and Apple Silicon, Linux x64,
and Windows x64. Being Roc, an app on it imports `Metrics`, `Report`, and the SQLite layer
directly: no schema re-reader, no serialization boundary, one version of every formula.
Its `live_plot` example draws hundreds of thousands of segments, well past any stream here.

The repo already holds two apps on two platforms: `src/app.roc` on basic-cli and
`tests/e2e.roc` on basic-webserver. A third app on a third platform is the established
layout, not a new idea.

## Decision

**1. The viz app is a separate entry point, `src/viz.roc`, on the roc-ray platform.** It
reads the same database and imports the same modules as the CLI. Nothing graphical enters
`src/app.roc`: the CLI's output stays deterministic and pipeable, because the coach reads
it programmatically and ADR 0007 promises observable commands. The viz app may gain
capabilities forever without the CLI's contract moving a byte. A `stride viz` subcommand
is still fine, and is the intended way in: it spawns the viz binary and exits, a launcher
and nothing more, so the one-command UX exists without graphics entering the engine's
process or its output contract.

**2. Windowed, not a TUI.** The value is dense series: a 90-day PMC curve, a full power
stream with segment boundaries. Terminal cells render those as sparklines, which shows a
trend but cannot show whether a boundary sits two samples early — and boundary auditing is
half the point. A TUI also has no Roc platform today, so choosing it means building a
terminal platform before drawing anything. If a terminal need appears later (SSH,
headless), that is a separate decision against this ADR's escape hatch.

**3. Build order is by value against data that already exists.** First the PMC chart with
events overlaid (`daily_load` plus the events table, both shipped). Second the stream
trace with detected work blocks shaded, which turns ADR 0008's detector into something a
human can audit. Third, deterministic recordings for posts, since roc-ray renders WebM/GIF
from code and a regenerated graphic cannot rot the way a hand-authored one does. A
power-duration view with the CP fit and its `fit_r2` drawn comes after those.

**4. The platform pin rides the same discipline as the compiler pin.** roc-ray tracks Roc
nightlies, so it is a third toolchain constraint. Its version is pinned next to the Roc
tag in the one place pins now live (post-#370), and the bump checklist gains one line:
verify the roc-ray release against the target nightly before moving either.

**5. Capture mode is how the coach sees it.** Every view the app can show, it can also
render to a PNG and exit: `stride viz pmc --out pmc.png`. roc-ray's capture support is
deterministic, so the same database state yields the same bytes. This is not an export
convenience; it is the LLM surface. The coach reads images, so a captured frame makes the
PMC curve and the shaded interval boundaries something the coach can look at and judge,
rather than something it must reconstruct from JSON. The windowed mode and the captured
frame draw through the same code path, so what the human sees and what the coach sees
cannot diverge.

## Consequences

The engine's thesis is untouched: local-first, deterministic, the coach reads JSON. The
viz app is optional at build and at runtime; a machine that never runs `just viz` behaves
exactly as today. The cost is the third pin, and the risk is roc-ray lagging the nightly
we want — in which case the viz app waits and the engine bumps without it, which decision 1
makes possible.

If the viz app ever needs data the CLI does not publish, the data is added to the engine's
queries first and consumed second, so the JSON surface and the pixels never diverge.
