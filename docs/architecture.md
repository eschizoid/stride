# How stride is shaped, in one page

Two programs share one athlete: the **engine** (`src/main.roc`, basic-cli, the
`stride` CLI the coach drives) and the **window** (`src/viz/main.roc`,
roc-ray, the board the human watches). They compile on different platforms,
against different compiler pins, and never import each other's code.

Everything they share goes through **one SQLite file** — three kinds of
sharing, decided one at a time:

1. **Data** rides the database. The engine writes activities, metrics, plans,
   daily load; the window only ever reads. Decided in
   [ADR 0015](adr/0015-pixels-for-the-human-state-for-the-coach.md) — "pixels
   for the human, state for the coach, the database as the bus" — which also
   gives the coach a steering wheel (`viz_directives`) and a rearview mirror
   (`viz_focus`).
2. **Meaning** rides the database too. A rule both sides need — which planned
   row counts, where a week starts — is written once as a SQL view in
   `Schema.roc`, and both sides SELECT from it. Decided in
   [ADR 0017](adr/0017-shared-semantics-as-sql-views.md).
3. **Inside the engine**, modules keep to layers — core, io, analytics, app —
   enforced by `tools/layer-check.sh` on every CI run, with folders deferred
   until the compiler can follow them. Decided in
   [ADR 0016](adr/0016-layers-before-folders.md). The same gate holds the
   window to its side of the bus: viz modules import only viz modules.

The consequence that makes this more than tidiness: because the window's
whole interface is shared state, an agent can drive it and read it **without
seeing a pixel** — insert a directive, read the focus row back. Every view
ships with that blind test.
