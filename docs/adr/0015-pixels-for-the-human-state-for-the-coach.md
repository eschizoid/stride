# 0015 — pixels for the human, state for the coach: the database is the bus

Proposed 2026-09-05 (#372). One evening of design argument is condensed here so it is
never re-run from zero; the blow-by-blow lives on the issue.

## Context

The engine computes dense series — the PMC curve, streams with detected work blocks —
whose shape a table cannot show. The first proposal was a windowed viz app on
[roc-ray](https://github.com/lukewilliamboswell/roc-ray) with a capture mode pitched as
"the LLM surface": the coach would read rendered PNGs. Grilling killed that claim.
Every value any view would draw derives from JSON the coach already consumes losslessly,
so a rendered frame is a lossy re-encoding of what the coach holds exactly: the taper is
judged from `load`'s series and a detector boundary is audited by querying the samples
around it, both more precisely than reading pixels. The same holds for a TUI driven
through a terminal multiplexer — operable, and still worth nothing over the JSON.

What survived is the human's side of the wish: a window on the desk, and an integration
with the coach that feels like one system rather than a screenshot pipeline. The repo
already holds the answer's shape: engine and coach share state through SQLite. Extend
that, and the window needs no channel of its own.

Also measured, 2026-09-05: roc-ray's own platform modules (`Text.roc`, `Font.roc`) fail
`roc check` with 5 errors on the engine's pin (`nightly-2026-09-04-c125b82`); its
`.roc-version` still names 08-23, the far side of the ordering-API rename. The errors
look like the same numeric-inference class as #371.

## Decision

**1. No UI in this repo is for the coach.** The coach's surface is the engine's JSON,
full stop. The falsified alternatives — capture-as-LLM-surface, a coach-driven TUI —
are recorded above so they are argued against, not rediscovered.

**2. The window is driven through the database.** Two judgment-tier tables carry the
whole integration. `viz_directives` flows coach to window: the coach inserts a row —
view, range, highlight — and the app, polling at a few hertz over a read-mostly WAL
connection, follows it mid-conversation. `viz_focus` flows window to coach: the app
writes what the human is viewing and hovering, so "why was I so tired here?" is
answerable — the coach reads the focused date and queries the engine for it. Pixels for
the human, state for the coach, SQLite as the only channel; neither side ever addresses
the other directly. A directive is a row, which is what makes the protocol testable in
this repo's native way.

**3. The app is a windowed roc-ray entry point, `src/viz.roc`, a second consumer of the
database.** It imports the same modules as the CLI, and nothing graphical enters
`src/app.roc`. A `stride viz` subcommand is the way in — a launcher that spawns the app and exits. <!-- command-claims: quoting -->

**4. One toolchain, never two, with a measured start precondition.** The viz app builds
with the engine's pinned nightly, and work starts when roc-ray's platform checks clean
on that pin — one command to verify, currently failing as described above. A second
compiler in the repo is rejected outright; it would undo #370's single-pin discipline.
Contributing the 5-error migration upstream is a live option, not an obligation.

**5. No capture command in the core.** When the human wants a picture inside the
conversation, the coach renders one on demand from the JSON — the Form Board artifact
is the working precedent. Deterministic capture for post assets may return later as its
own argued decision; it is not load-bearing here.

**6. The viz build stays out of the default gate.** `just viz-check` exists once viz
exists; `just test` and the merge gate never depend on it, so the engine's cadence is
never hostage to a graphics platform's lag. The directive protocol is tested headless
as the state machine it is; the rendering itself is judged by the eyes it exists for,
and that is a deliberate choice, not an omission.

**7. Built on conviction, for one human.** There is no usage-based kill criterion. If
the window stops being opened, parking it is a one-line pin removal and this ADR is the
receipt.

## Consequences

The engine is untouched by this ADR, and nothing builds until the precondition clears.
The coach gains nothing and loses nothing: its surface was always the engine. The human
gains a window that follows the conversation and a mouse that the coach can read. The
price is the third platform pin and the polling tables, both bounded, both owned here.
