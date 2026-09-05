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

**4. One toolchain, never two.** The viz app builds with the engine's pinned nightly, and
the roc-ray version is pinned beside the Roc tag in the one place pins now live
(post-#370). Measured 2026-09-05 with the pinned `nightly-2026-09-04-c125b82`: roc-ray's
own platform modules (`Text.roc`, `Font.roc`) fail `roc check` with 5 errors — field
defaults in structural records plus numeric type mismatches, the same inference class as
#371 — while roc-ray's `.roc-version` still names `nightly-2026-08-23-fb208ba`. So the
precondition for starting is empirical and checkable in one command: roc-ray's platform
checks clean on the engine's pin. Until then this ADR stays Proposed and no viz code
exists to rot. A second compiler in the repo to bridge the gap is rejected outright; it
would undo #370's single-pin discipline the week it landed.

**5. Capture is an export for humans, and no UI in this repo is for the coach.** Every
view the app can show, it can also render to a PNG and exit — `stride viz pmc --out
pmc.png` — deterministic for a given database state. That earns its keep three ways:
post assets that regenerate instead of rotting, sharing a view without a screen present,
and letting the coach verify a rendering before it ships, the one look at pixels JSON
cannot replace because the defect may be in the drawing.

What capture is not is a coaching surface. Every value the app draws derives from JSON
the coach already consumes losslessly, so a rendered frame is a lossy re-encoding of what
the coach holds exactly: the taper is judged from `load`'s series and a detector boundary
is audited by querying the samples around it, both more precisely than reading pixels.
The same holds one level up for a TUI, which the coach could drive through a terminal
multiplexer and still gain nothing over the JSON. The coach's surface is the engine; this
app is for the human, and its design owes the coach nothing beyond capture.

**6. The viz build stays out of the default gate.** `just viz-check` exists once viz
exists; `just test` and the merge gate never depend on it. The engine's release cadence
answers to the engine's own suite, not to whether a single-maintainer graphics platform
has caught up with this week's nightly — that is decision 1's boundary applied to CI.

**7. Rendering is tested by golden capture.** Deterministic capture makes UI testing fit
this repo's ethos: a fixture database renders each view to a PNG and the bytes are
compared against a committed golden. A drawing regression fails a diff instead of waiting
for a human to squint. This is the load-bearing use of decision 5's determinism.

## Consequences

There is deliberately no usage-based kill criterion. The app is built on conviction, for
one human, and it answers to whether he opens it, not to a metric. If it stops being
opened, parking it is a one-line pin removal and this ADR's record is the receipt.

The engine's thesis is untouched: local-first, deterministic, the coach reads JSON. The
viz app is optional at build and at runtime; a machine that never runs `just viz` behaves
exactly as today. The cost is the third pin, and the risk is roc-ray lagging the nightly
we want — in which case the viz app waits and the engine bumps without it, which decision 1
makes possible.

If the viz app ever needs data the CLI does not publish, the data is added to the engine's
queries first and consumed second, so the JSON surface and the pixels never diverge.
