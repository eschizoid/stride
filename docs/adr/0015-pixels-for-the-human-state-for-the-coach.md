# 0015. pixels for the human, state for the coach: the database is the bus

Proposed 2026-09-05 (#372). One evening of design argument is condensed here so that it is
never re-run from zero, and the detailed exchange lives on the issue.

## Context

The engine computes dense series whose shape a table cannot show, such as the PMC curve and
streams with detected work blocks. The first proposal was a windowed viz app on
[roc-ray](https://github.com/lukewilliamboswell/roc-ray) with a capture mode pitched as the
LLM surface, so that the coach would read rendered PNGs. Grilling the proposal killed that
claim. Every value any view would draw derives from JSON the coach already consumes
losslessly, so a rendered frame re-encodes with loss what the coach already holds exactly.
A taper is judged from the series behind `load`, a detector boundary is audited by querying
the samples around it, and both readings are more precise than reading pixels. The same
argument applies to a TUI driven through a terminal multiplexer, which is operable and still
adds nothing over the JSON.

What survived is the human's side of the wish, which is a window on the desk and an
integration with the coach that behaves as one system rather than a screenshot pipeline. The
repo already holds the shape of the answer, because the engine and the coach share state
through SQLite. Extending that arrangement gives the window a channel without inventing one.

One more thing was measured on 2026-09-05. roc-ray's own platform modules `Text.roc` and
`Font.roc` fail `roc check` with 5 errors on the engine's pin, which is
`nightly-2026-09-04-c125b82`. Its `.roc-version` still names 08-23, which is the far side of
the ordering API rename, and the errors look like the same numeric inference class as #371.

## Decision

1. No UI in this repo is for the coach. The coach's surface is the engine's JSON and nothing
else. The falsified alternatives, which are capture as the LLM surface and a coach-driven
TUI, are recorded above so that they are argued against rather than rediscovered.

2. The window is driven through the database. Two judgment-tier tables carry the whole
integration. `viz_directives` flows from the coach to the window, so the coach inserts a row
naming the view, the range and the highlight, and the app follows that row mid-conversation
while polling at a few hertz over a read-mostly WAL connection. `viz_focus` flows from the
window to the coach, so the app writes what the human is viewing and hovering, and a
question such as "why was I so tired here?" becomes answerable when the coach reads the
focused date and queries the engine for it. The human gets pixels, the coach gets state, and
SQLite is the only channel, so neither side ever addresses the other directly. A directive
is a row, which is what makes the protocol testable the way everything else in this repo is
tested.

3. The app is a windowed roc-ray entry point at `src/viz/main.roc`, and it is a second
consumer of the database. It began as one file, `src/viz.roc`, and #388 split it into
modules. It imports the same modules as the CLI, and nothing graphical enters `src/app.roc`.
A `stride viz` subcommand is the way in, and it launches the app and exits. <!-- command-claims: quoting -->

4. The repo holds one toolchain and never two, with a measured precondition on when work
starts. The viz app builds with the engine's pinned nightly, and work starts when roc-ray's
platform checks clean on that pin. One command verifies it, and it currently fails as
described above. A second compiler in the repo is rejected outright, because it would undo
#370's single-pin discipline. Contributing the 5-error migration upstream is an option
rather than an obligation.

5. The core carries no capture command. When the human wants a picture inside the
conversation, the coach renders one on demand from the JSON, and the Form Board artifact is
the working precedent. Deterministic capture for post assets may return later as its own
argued decision, and it is not load-bearing here.

6. The viz build stays out of the default gate. `just viz-check` exists once viz exists, and
`just test` and the merge gate never depend on it, so the engine's cadence is never delayed
by a graphics platform's lag. The directive protocol is tested headless as the state machine
it is, and the rendering itself is judged by the human it exists for, which is a deliberate
choice rather than an omission.

7. The window is built on conviction, for one human. There is no usage-based kill criterion.
If the window stops being opened, parking it is a one-line pin removal, and this ADR is the
record of why it was built.

## Consequences

The engine is untouched by this ADR, and nothing builds until the precondition clears. The
coach gains nothing and loses nothing, because its surface was always the engine. The human
gains a window that follows the conversation and a mouse position that the coach can read.
The price is the third platform pin and the polling tables, and both are bounded and owned
here.

## Amendment, 2026-09-07. What shipping the window changed

Four views exist now, from #379, #381, #382 and #383. Building them falsified one decision,
left another unimplemented, and found a use for pixels that this ADR argued against, in a
narrower sense than the one it rejected.

Decision 4 is broken, and knowingly so. The viz app header in `src/viz/main.roc` pins
`nightly-2026-08-23-fb208ba` while the engine pins `nightly-2026-09-04-c125b82`, which is
the second compiler this ADR rejects outright. The precondition the decision set was that
work starts when roc-ray checks clean on the engine's pin, and that precondition was never
met, because `just viz-check` against the engine pin still fails with 8 errors of the same
platform classes recorded above. The work proceeded anyway. Either the decision is amended
to allow a scoped second pin for the viz alone, or the viz waits for the upstream migration,
and what is not tenable is a decision the tree contradicts in silence. The practical cost is
already visible. `just viz-check` fails out of the box for anyone whose `roc` on PATH is the
engine's, and its first error is a version mismatch that produces seven further platform
errors, so it reads like broken code rather than a missing compiler.

Decision 2 is unimplemented. Neither `viz_directives` nor `viz_focus` exists, and every view
answers a fixed question with a hardcoded window, sport and session. #384 proposed a
`~/.stride/viz.json` knobs file, which is wrong by this ADR, and the ADR is right, because a
directive should be a row and a row is what makes the protocol testable the way everything
else here is tested. #384 is being corrected rather than the ADR.

The knobs are load-bearing rather than a convenience. Without them the coach can answer a
question in prose but cannot aim the window at it, so the human reads an argument rather
than seeing it. The difference is between a dashboard the human opens and an explanation the
coach can point at, and it is the reason `viz_directives` flows from the coach to the window
rather than the app offering its own controls. An agent whose reasoning can be made visible
on demand is the goal, and a viz with no inbound channel cannot serve that goal no matter
how many views it grows.

Decision 1 stands, and Decision 6's assumption does not. Pixels remain worthless to the
coach for judging training, because every value derives from JSON it already holds
losslessly, and nothing since has challenged that. Decision 6 assumed the rendering "is
judged by the human it exists for", and in practice the agent needs to see its own output to
review it. Adding a screenshot key surfaced five defects immediately, in code that had
type-checked, had every data path diffed against the engine, and had been called done. The
defects were a legend overprinting two other views' titles, an em dash rendering as `?` for
a missing glyph, colliding axis labels, a count formatted as `3.0 bests`, and a CP asymptote
that a comment described and no code drew. The last of them made the curve view nearly
pointless, because making a bad fit obvious is the entire reason the view exists.

None of the five defects is visible from the JSON, because none of them is about the data.
The claim is narrow and stays narrow, since rendered frames are for reviewing the rendering
rather than for reading the numbers.

Decision 5 needs the same treatment. A screenshot key now exists in the viz rather than in
the core, which is what the decision was about, and it returned without the argued decision
the ADR asked for. The argument is here. Capture earns its place as the agent's only way to
review its own drawing, and it stays out of `src/app.roc`.

## Update, 2026-09-17

Several statements above no longer describe the tree, and the decisions they concern are in
better shape than the 2026-09-07 amendment recorded.

Both binaries build on one compiler, so Decision 4 holds again. #471 moved the window onto
the tag the engine uses, `nightly-2026-09-16-a49a16f`, which is the `setup-roc` action's
default and is mirrored in the app header of `src/viz/main.roc`, and `tools/pin-check.sh`
holds the two copies together. roc-ray still declares an older compiler in its own header,
so a viz build emits one mismatch warning, and `tools/roc-viz.sh` tolerates exactly that
warning and nothing else.

Decision 2 is implemented. `viz_directives` and `viz_focus` both exist, the window creates
and migrates them in `src/viz/Db.roc`, and the window publishes what the bus accepts as data
(#439).

The window carries nine views rather than the four the amendment counted, and they are form,
power, trace, table, plan, heat, zones, ramp and career.

Decision 3 says the app "imports the same modules as the CLI", which is no longer true. The
window imports its own modules under `src/viz/` and the shared `src/core` package, and ADR
0016's layer table together with ADR 0017 records that the window may not import engine
modules.
