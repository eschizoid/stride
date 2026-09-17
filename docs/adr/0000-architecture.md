# ADR 0000. stride architecture and key decisions

Status: accepted
Last reviewed: 2026-08-19

ADR 0000 is the foundational architecture decision record. It captures why stride is shaped
the way it is, which means the decisions that are expensive to reverse and the constraints
a newcomer would otherwise rediscover the hard way. Operating rules live in the project
instructions, covering the invariants CI enforces, the build commands and the release flow,
and this document holds the rationale behind them.

The thesis in one line is that the engine does the math and the LLM does the judgment.
Every number is computed locally by pure, unit-tested functions from raw activity data, and
no metric ever comes from a model.

## 1. Local-first SQLite is the product

Everything stride knows lives in one file, which is `~/.stride/db.sqlite`. It is not a
cloud service and not a proprietary format.

- Ownership, inspectability and reproducibility all follow. You can open the db with
  `sqlite3`, back it up with `cp`, and recompute every derived number from the stored raw
  streams.
- The database is therefore the interface, so schema design and migration safety come
  before any single feature.

The db holds the Strava OAuth tokens and the client secret, so sync refreshes itself with
no environment variables. Because of that, stride locks `~/.stride` to `0700` and the db to
`0600` on every run, and secret config keys are never printed through `config get` or
through any JSON. The secret-key policy has one tested source of truth in
`Config.is_secret`.

## 2. Written in Roc, and deliberately pinned

The toolchain is Roc's new Zig compiler, taken from a nightly and pinned by exact tag in
`.github/workflows/build.yml`, together with basic-cli `0.22` and builtin JSON rather than
roc-json. The earlier pin of alpha4, basic-cli 0.20 and roc-json 0.13 is retired
(issue-claims: quoting), and §9 records the migration and why the original "blocked on
roc-json" conclusion was wrong. CI type-checks with `roc check` and runs the pure tests
with `roc test` on this compiler across linux, macOS and Windows, then builds the real
binary and runs the e2e suite on macOS. The `roc build` perf gate is gone (roc#10469,
fixed by roc#10531). Builds pin `--opt=dev` for build time, about 14s against about 2min,
rather than for correctness, because the optimized backend's miscompile (issue #32) was
fixed by the 2026-08-17 compiler pin. Day-to-day notes on compiler syntax, the stdlib and
the platform live in `docs/roc-new-compiler-notes.md`.

### Effects live in modules, organized by concern

The new compiler lets any module use platform effects, so I/O is split by concern instead
of piled into `app.roc`. `Db.roc` owns SQLite plus the schema and migrations, and
`Strava.roc` owns the OAuth and sync HTTP. `Analyze`, `Plan` and `Import`, together with
the report family (`Report.roc` plus `ReportSessions/ReportHealth/ReportSeason`, split by
read-command family in #196), own their commands, and `app.roc` is a thin argv → dispatch
shell. Pure logic still lives in its own tested modules, which are `Metrics.roc` for
training math, `Sports.roc` for the sport vocabulary, `Render.roc` for tables and
formatting, `Command.roc` for turning argv into a typed command, `Config.roc` for key
policy, and `Csv/Streams/Drain`. `Schema.roc` is pure DDL with no expects. `Output.roc`
owns the envelope and is effectful.

As a historical note, the split was impossible under alpha4, because module params were
monomorphic, so injecting effects broke any row decoder wider than two columns and every
command had to sit in `app.roc`. The new compiler removed that restriction, and the
repository and query split it used to block is simply how the code is laid out now.

### SQL lives next to its decoder

The compiler cannot check a `SELECT … AS x` alias against a `Sqlite.i64("x")` decoder, so
adjacency is the safeguard. Query strings sit immediately next to the row decoder they
feed, and only decoder-free DDL lives in `Schema.roc`.

### Tests are pure expects plus a native-Roc e2e

Effectful `expect`s cannot run under `roc test`, because they need a platform, and on
alpha4 they segfaulted outright with exit 139. Roc therefore keeps the pure `expect`s, and
end-to-end coverage is a native-Roc suite in `tests/e2e.roc` that drives the real binary
against a sandboxed `HOME` with seeded activities of known math. The suite is a
basic-webserver app that runs every check in `init!` and then exits, because basic-cli's
exec host drops child exit codes under the suite's several hundred subprocess spawns while
basic-webserver's host reaps them cleanly. The network path, meaning sync and token
refresh, is the same file's `E2E_MODE=sync` role driven against its `E2E_MODE=mock` role,
which is a mock Strava on a local port, pointed at through `STRIDE_API_BASE` and run by
`just e2e-sync`. The recipe is kept out of `just test` because it binds a port. One gap
remains, which is 429 rate-limit backoff, and closing it needs a stateful mock.

## 3. Three data tiers, three recovery stories

Every table belongs to exactly one tier, and the tier dictates how it recovers.

| Tier | Tables | Recovery |
|---|---|---|
| **Mirror** | `activities`, `streams` | Replace-on-sync; re-pullable from Strava. |
| **Computed** | `activity_metrics`, `daily_load`, `activity_segments` | Rebuilt from `analyze` (segments per ADR 0008 §4). |
| **Judgment** | `planned_sessions`, `config`, `ratings` | Exist *only* here. Human input. |

One rule holds the design together. Human input must never be a column on a mirror table,
or a re-sync would silently wipe it. Session-RPE ratings therefore live in their own table
rather than on `activities`.

## 4. Training load is a mixed model, not "TSS"

Load is scored by a ladder that picks the best available source per activity, running
stream normalized power → Strava weighted watts → average watts → pace → zone-weighted
hrTSS → session-RPE → `relative_effort` → honest zero. The pace rung is normalized graded
pace against a threshold speed, with a per-sport exponent, per ADR 0003. For strength-class
sports the athlete's own session-RPE rating outranks HR, where `load = hours × RPE × 10`,
which is TSS-commensurate by construction, because raw Foster minutes × RPE would be about
6× too large and would corrupt CTL and ATL.

Because the blended total is not all TSS, stride stops calling it "TSS" in mixed contexts
and instead records two things per metrics row.

- `load_model` names which ladder rung scored the row, which is its provenance.
- The confidence tier is high for measured power or distance-measured pace, medium for HR
  or session-RPE, low for relative effort, and none when the row is unscored. The tier is
  derived from `load_model` at read time rather than stored, because the `load_confidence`
  column existed until schema v8 and was dropped for being derivable. `doctor` surfaces the
  tiers as a distribution.

`doctor` is where trust is checked, and it reports coverage, provenance, the confidence
distribution, config completeness, streams still pending and the active time anchor. Every
gap is stated as what it is, why it happened and how to fix it.

## 5. Metric invalidation is explicit

Computed metrics must never go stale silently. Each `activity_metrics` row records the
inputs it was computed under, and recomputation is triggered by the following changes.

- An FTP change, compared through `ftp_used`.
- A derived threshold-pace change, compared through `threshold_pace_used`, which is the
  pace analog of `ftp_used` and is keyed per sport rather than per family. As with
  `ftp_used`, a new best rescores only the rows whose own 60-day window moved (#79).
- An HR-zone change, compared through a `zones_used` signature.
- An algorithm change, tracked by the `metrics_rev` constant. Bump it whenever the
  `Metrics` math changes, because config provenance cannot see code changes.
- A change to the activity inputs. Each metrics row stores the activity fields it was
  scored from (`mt_used`, `aw_used`, `sport_used`, …) and `analyze` compares them value by
  value, exactly as `ftp_used` works, so a changed activity rescores itself.
- Stream arrival or a rating change. Both paths delete the affected metrics row so that the
  next `analyze` rescores it.

`sync` deliberately does not delete metrics. It re-lists a rolling 30-day window every run
and cannot cheaply tell an edit from a no-op, so invalidating there wiped a month of
computed metrics on every sync and left every report under-reporting load until the next
`analyze`, which is a correctness bug rather than wasted work. Detecting staleness in
`analyze` is stateless and self-correcting, because there is no flag to drift and the
comparison costs nothing extra, since `analyze` already runs that predicate. `synced_at` is
excluded from the comparison, because it changes by design on every run and would mark
every row stale. The comparison is value-by-value rather than a hash, because an additive
signature cancelled on a +7s/-1m edit and missed it silently.

Any new metric input must join the same story.

## 6. Schema self-migrates, and breaking it is fine while we are early

The schema versions itself through `PRAGMA user_version`. Upgrading the binary against an
existing db migrates on the next command, and migrations converge to the current schema
idempotently, renaming first, then creating if not exists, then adding columns. Legacy-db
fixtures in `tests/fixtures/db/` prove that upgrades preserve data.

Pre-1.0, the schema is not a stable contract. With a tiny user base, a structural change
does not need a backward-compatible migration path for every prior version. It is
acceptable to change column types directly, to drop and recreate the mirror and computed
tables, which rebuild from `sync` and `analyze`, or to reset a db outright when that is
simpler than a migration. The one inviolable rule is the tier boundary from §3, which is
that a schema change must never silently destroy judgment-tier data, meaning `ratings`,
`planned_sessions` and `config`, including tokens. Judgment-tier data exists only here and
cannot be re-derived, so it must be migrated, or else explicitly and knowingly reset. Do
not spend effort making migrations survive versions no real db is on.

The permission is scoped to pre-1.0 and expires with it. §9c states what each versioned
surface promises from 1.0 onward, and the tier rule above is the one part that was never a
pre-1.0 concession in the first place.

## 7. Machine output is a versioned envelope

Every JSON response is wrapped and versioned so that tool callers can detect a contract
change and can always tell success from failure.

- success → `{"schema_version":3,"data":{…}}`. The version was 1 until the doctor field
  rename on 2026-08-06, and 2 until the substitute_activity_id spelling break on
  2026-08-30.
- error → `{"schema_version":3,"error":{"code":"…","message":"…"}}`

Errors are in-band on stdout, and since #163 they also exit non-zero, as the amendment
below records. The envelope is deterministic and carries no timestamps, so golden
comparisons stay stable. Human table output is a separate, independent rendering path. JSON
is emitted when it is asked for, through `--json` on the command or otherwise through
`STRIDE_FORMAT=json`, and nothing is inferred from the environment, as the 2026-08-17
amendments below record. The behavior was made the default rather than gated while the user
base is still small enough to absorb the break.

## 8. "Today" is a local calendar day

CTL, ATL and TSB extend through today, so the day boundary must match the athlete's civil
day. The platform clock is UTC-only, and without an anchor a user west of UTC gets a
phantom "tomorrow" each evening. The precedence is `timezone` first, which is an IANA name
and is DST-correct for the current date through the system tz database, then
`utc_offset_minutes`, which is a fixed offset, then UTC. An unknown timezone name never
silently becomes UTC, because it falls back to the fixed offset and `doctor` flags it.
Historical per-activity dates already use Strava's civil date, so only the today boundary
needs the anchor.

## 9. Compiler migration is done, and the build is no longer gated

The migration to Roc's new Zig compiler is merged to `main`. The whole codebase is in the
new type-module dialect (`Name :: [].{}`, `List(X)`, `Result`→`Try`, `True`/`False`), it
runs on basic-cli 0.22 with builtin JSON, and `build.yml` pins the new compiler by exact
nightly tag. CI runs `roc check` and `roc test`, meaning the pure expects, green on every
push.

The build is unblocked and no longer gated. `roc build src/app.roc` used to peg the
Specialization phase for minutes, which was an upstream compiler-perf bug (roc-lang/roc#10469,
a SpecConstr blowup) fixed upstream by roc-lang/roc#10531 and merged 2026-08-02. A separate
backend bug then kept the optimized build unusable, which was an intermittent
heap-corruption SIGABRT in `--opt=speed` (issue #32). It was measured at 40 aborts per 1400
invocations on the old pin, concentrated in `season` at about 8% and `power-curve` at about
7% but not confined to them, since `activity` aborts at about 0.8% and was found only by
replicating, after a single 200-run sample had read as zero. Both bugs are resolved,
because the 2026-08-17 compiler pin gives 0 aborts per 1400 invocations with output
byte-identical to `--opt=dev`. Builds still pin `--opt=dev`, now purely for build time.
`roc build` on the old alpha4 toolchain is gone with the migration.

Windows ships as `stride-cli-windows-x86_64` and has done since v0.3.0, because the new
compiler and basic-cli's x64win host target it, and `OsStr.display` decodes the
`WindowsU16s` argv arm. All five release targets ship, linux-arm64 included.
`release-please.yml` passes that target an explicit `roc_target: arm64musl`,
`verify-arm64.yml` re-checks it on dispatch, and every release from v0.4.0 onward carries
the linux-arm64 CLI, named `stride-cli-linux-arm64` and named `stride-linux-arm64` before
v0.13.0.

A correction is kept for the record, dated 2026-08-01 (issue-claims: quoting). The earlier
"hard-blocked on roc-json" conclusion was wrong, because it assumed all JSON had to go
through a roc-json port, while JSON parsing is a builtin in the new compiler
(lukewilliamboswell/roc-json#52), so roc-json was dropped rather than ported. The lesson
to keep is that "blocked" was an untested assumption stated as fact, so verify with the
source before writing a constraint into the record.

## 9b. What stride is

Everything in §10 below says what stride refuses, and nothing has said what it is. The cost
of the omission is measurable. A careful outside reviewer read this repository and wrote a
page proposing, as future direction, an architecture stride already ships, including
provenance, confidence tiers, plan and adherence memory, null semantics, versioned schemas,
rep-level progression and an engine and coach boundary. They then proposed two things that
§10 and ADR 0006 rule out, without engaging the reasoning, because nothing pointed at it
(#216).

Stride is the deterministic, local source of athlete state. It turns training evidence into
traceable facts, each carrying its own provenance and its own uncertainty, that a human or
a reasoning system can consume without trusting stride's judgment, because stride does not
offer any.

Three consequences follow, and most of §10 follows from one of them. The exceptions are
named here rather than papered over. Graphs and social carry their own grounds in §10,
which are an experiment that ran and failed and the fact that Strava already exists, and
neither ground is an architectural consequence of anything here. Medical follows from the
description above rather than from the three consequences.

- Data providers are inputs rather than the identity. Strava is one grandfathered API
  because it is an aggregator that already exists (ADR 0006). The engine is an
  athlete-state engine that currently ingests Strava, and it is not "a Strava tool". The
  ingestion boundary is therefore the filesystem rather than a vendor list.
- The reasoning layer is interchangeable by construction. There is no model in the binary,
  no model API key and no vendor coupling, only versioned JSON on stdout and an exit code.
  The Strava tokens in §1 are ingestion credentials, which are a different thing. Any agent
  can consume the output, and the engine outlives whichever model is currently best. §10
  refuses an MCP server for that reason, because the CLI plus versioned JSON already is the
  agent interface, and not because agent consumption is unwanted.
- The athlete's state is the product, rather than the report or the recommendation. The
  state is a file the athlete owns, which they can grep, back up with `cp` and recompute
  from raw streams.

§10 is the single scope list. Section 9b does not restate it and must not grow into a
second one.

## 9c. The 1.0 compatibility contract

Pre-1.0 breakage (§6) is scoped to pre-1.0. Releasing 1.0 changes what the permission
means, and stride has six surfaces a caller can depend on which are not one single promise
(#217). Only three of them carry a version number of their own, which are the binary,
`PRAGMA user_version` and `json_schema_version`. CLI behaviour and judgment-tier data carry
none, which is exactly why they need stating rather than inferring.

| surface | 1.x promise |
|---|---|
| Binary version (`app.roc`, release-please) | semver, and the source of truth for "which stride is this" |
| SQLite schema (`PRAGMA user_version`) | migrates forward on next command, and §3's tier rule is inviolable, so judgment-tier data is never silently destroyed |
| Envelope (`json_schema_version`) | bumps when the WRAPPER changes, or a payload field is removed or retyped |
| CLI commands and arguments | additive; a name that parses in 1.x keeps parsing to the same variant |
| Judgment-tier data | survives every upgrade, unconditionally, because it cannot be re-derived |
| `schemas/v3/*.json` | see below, because these schemas are not a third-party contract |

Adding a payload key is non-breaking to readers and breaking to validators. Both halves of
that were already written down and they appear to contradict each other. The envelope rule
says adding a field does not bump the version, because "a consumer reading known keys is
unaffected by a new one appearing", while every schema carries `additionalKeys: false`, so
anything validating a payload against the checked-in schema fails the moment a key is
added. Both statements are true, because "consumer" means two different things.

The 1.x resolution is that the schemas are stride's own contract with itself rather than a
closed-world validator for third parties. `additionalKeys: false` exists so that a payload
which grew without a schema update is caught rather than shipped. In CI that enforcement is
`just e2e`, which runs `tools/validate.jq` against seeded fixtures. `just schema-check`
runs the same validator against your own database and answers whether your own data
conforms, and it is local rather than part of CI. Coverage is not total, and it now has
three tiers rather than two.

Five payloads (`init`, `rate`, `relabel`, `event add`, `event remove`) are validated by
neither pass, so a key added to one of those is currently caught by nothing. The list is
pinned, because e2e asserts that each named form has zero validate arms in the suite's own
source, so giving one an arm, which you should do, fails a check until the sentence here
and the pin move together. As hand-counted prose the list rotted twice. It said four and
named `import` among them until #259 re-derived it, and `import` has had an arm at the
import scenario in `tests/e2e.roc` for some time, while the stale number survived because
it was read rather than counted.

What the remaining five share is not that they mutate, since `analyze`, `config set`,
`week add`, `skip` and `import` all mutate and are all validated. They share instead that
`just schema-check` derives its form list from the command table filtered on
`mutates == false and network == false and interactive == false`, so any command outside
that filter gets no automatic coverage and has to be given an explicit `e2e` arm by hand.
Nine of the fourteen schema-bearing mutating commands have one, and those five do not. #259
gave `auth` a payload and an `e2e-sync` arm in the same commit for that reason. The arm
validates auth's payload against its schema and asserts that the tokens it reports storing
are in the database, which is narrower than `sync`'s coverage in the same recipe. `sync`'s
payload is validated in eight places across three drivers, and, as the next paragraph
explains, `sync` carries closed record annotations that make a key change a build error,
while `auth`'s payload literal is unannotated with a `|_|` renderer and has no such guard.
`tte` is covered by the local recipe but not by CI. `sync` is covered by a third pass,
`just e2e-sync`, which drives it against loopback mocks and now runs in CI. The recipe was
assumed to need a token and a live API and so was left out of CI for a long time, and it
needs neither, because the mocks bind loopback and the token is a fake row in a sandboxed
HOME. The assumption cost the stream drain its only check of payload against schema.

The next point is stated plainly because the near-miss is tempting. The compiler does not
substitute for the validator. Where a payload carries a closed record annotation, as
`sync`'s does at the `payload :` binding in `Strava.roc`, an added, removed or retyped key
fails `roc check`. The annotation guards the payload against diverging from its own
declared shape, and nothing more. A command whose renderer is an unannotated inline closure
has no such guard at all, because the compiler infers an open record and a new key compiles
clean. Even where the annotation exists, widening it leaves the build green with the schema
untouched, since payload↔schema is a different invariant, and the compiler error never
mentions the schema, so it does not even prompt the right fix. Where a payload has no
validating pass, it is unguarded against its schema, full stop. A downstream consumer
should read the keys it needs and validate its own required subset. It should not use
stride's schema as a closed-world check, and stride does not promise that it can.

Adding a key is therefore additive and does not bump `json_schema_version`, while removing
or retyping one does. A change that would break a reader of known keys becomes a new `vN/`
directory rather than an edit to the current one, and v3, which carried the
substitute_activity_id break, is the worked example. The old directory lives in git history
rather than at head, because pre-1.0 there was no published consumer for a parallel copy to
serve, and the 1.x promise is the new directory plus the bump rather than an archive at
head.

Error codes are additive in 1.x. The vocabulary is published, and `tests/e2e.roc` diffs the
enum against the codes the source emits, so the two cannot silently disagree. Note what the
diff does not enforce. It asserts set equality, so deleting a code from the source and the
enum together passes green. Additivity was a promise this document made with nothing
checking it, since a coordinated deletion of the source and the enum together passed the
equality diff green, and the same gap existed unstated for CLI command names. Both gaps are
mechanical now, because `tools/error-codes-1.0.pins` and `tools/commands-1.0.pins` freeze
what 1.0 ships and e2e asserts that the live sets are supersets, so additions pass
untouched while a removed 1.0 code or command name fails by name.

## 10. Deliberately out of scope

The list below is the single scope list. The roadmap carried a second, overlapping one
until it was retired, and neither was a superset of the other.

- A TUI and an MCP server, because the CLI plus versioned JSON is the interface.
- Cloud or web sync, because local-first is the identity rather than a stage.
- Injury and medical claims, because they are outside what training data can honestly
  support.
- Replacing SQLite, because the athlete owns that file, greps it and backs it up with `cp`.
- Moving any math into the LLM, because the engine computes and the coach reasons
  (ADR 0012).
- Multi-athlete and coach views, because they break the single-user local db that keeps
  everything else simple, and a coach reads the athlete's JSON instead. Friends each
  running their own copy is a different thing and is in scope.
- Graphs, because that experiment ran and failed, so tables, legends and verdict lines are
  the visualization layer.
- ML predictions, because nothing ships that cannot be recomputed by hand from stored
  inputs.
- Social features, because Strava exists.
- Vendor-cloud integrations such as the Garmin Connect, Wahoo and Peloton APIs, because the
  ingestion boundary is the filesystem and Strava is the one grandfathered API.
- Raw device-format parsing of FIT, TCX and GPX, because Strava is the parser (ADR 0006).
- `.zwo` workout export for smart trainers, because stride prescribes nothing (ADR 0012),
  so it has no workout to export and the coach writes the session.

(issue-claims: quoting. The query and repository split used to sit here as "blocked by the
compiler". The restriction is gone and the split is the current layout, as §2 and ADR 0001
record. The further per-command subdivision of `Report.roc` is done too, because ADR
0001's file-size trigger fired and #196 shipped the read-command split. What is left is
that ADR's function-size half, deferred until it has a better predicate.)

The items above are revisited only when dogfooding demands them.

One item was promoted into scope, which is a generic every-sport model. The list previously
called it out of scope, and dogfooding demanded it, because friends who run and swim cannot
be scored honestly by the power and HR ladder, which is exactly the trigger for revisiting.
It is now [ADR 0003](0003-multi-sport-scoring.md). Single-user local-first (§1) is
unchanged, because sport-completeness is not multi-tenancy.

---

Open work lives in GitHub issues, and no scratch plan file describes work. AGENTS.md
records why, because a watch-item tracked in one went unnoticed for weeks (#196). A root
`PLAN.md` may hold sequencing and its reasons, which is the one thing issues cannot carry,
provided that every item is a pointer, that `just issue-claims` scans it like any other
doc, and that it deletes itself when the sequence is done. The moment it describes what a
ticket contains, beyond the one fact that creates a sequencing constraint, it has become
the file that rotted. Enforced invariants and the build and release mechanics live in the
project instructions. When a decision here changes, update this ADR in the same commit as
the code.

## Amended 2026-08-17. Errors exit non-zero (#163, PR #178)

§7 above said errors stay exit 0 and that callers should read the JSON rather than `$?`.
The rule was written when environment detection was the only machine interface and every
caller was an LLM parsing stdout. #162 made the machine interface explicitly tool-neutral,
with `--json` for shell scripts, MCP clients and other agents, and for those callers an
always-zero exit misreports failure to `set -e`, to `&&` chains, to CI steps and to
process supervisors.

The envelope is unchanged, and the exit code adds information to a channel that previously
carried none. Every error envelope exits 1, and not every exit 1 carries an envelope,
because an uncaught platform error prints to stderr with empty stdout (#183). Usage errors
did print a plain line, and #180 gave them an envelope for machines, so the human line
survives only in human mode. Success exits 0. Asking for help, whether through bare
`stride`, `--help`, `-h` or `help`, exits 0 because it is not a failure. An unknown
command is an invocation error that emits an `unknown_command` envelope to machines and
the help text to humans, exiting 1 either way. Warnings inside a successful command, such
as analyze's pending and stream-error notes or a stream that would not decode, stay at
exit 0, because they are reported in the payload and the command did what it was asked.

## Update, 2026-09-17

Four facts above no longer describe the tree, and the decisions survive all four.

The engine's entry point is `src/main.roc` rather than `app.roc`, renamed in #394 on
2026-09-07, so §2's dispatch shell and §9's `roc build src/app.roc` both name a path that
has moved. The split by concern is unchanged.

`Sports` is no longer an engine module. It moved into a shared Roc package at `src/core/`
that also holds `Fmt`, and both binaries import that package, so §2's list of pure engine
modules names one module that now lives outside the engine. ADR 0016 records the layer
table that governs these imports, and ADR 0017 records what may live in the package.

Both binaries now build on one compiler, the nightly pinned at nightly-2026-09-16, so §2's
pin covers the window app as well as the CLI.

§10's refusal of graphs no longer describes the tree. ADR 0015 decided to ship a windowed
app that draws the dense series a table cannot show, and the window now carries nine views,
the ninth being career. The boundary the bullet was protecting is unchanged, because the
window reads the same database and the coach still reads JSON rather than pixels.
