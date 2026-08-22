# ADR 0000 — stride architecture and key decisions

Status: accepted · Last reviewed: 2026-08-19

This is the foundational architecture decision record. It captures *why* stride is
shaped the way it is — the decisions that are expensive to reverse and the
constraints a newcomer would otherwise rediscover the hard way. Operating rules
(the invariants CI enforces, build commands, release flow) live in the project
instructions; this document is the rationale behind them.

One-line thesis: **the engine does the math, the LLM does the judgment.** Every
number is computed locally by pure, unit-tested functions from raw activity data;
no metric ever comes from a model.

## 1. Local-first SQLite is the product

Everything stride knows lives in one file: `~/.stride/db.sqlite`. Not a cloud
service, not a proprietary format.

- **Ownership / inspectability / reproducibility.** You can `sqlite3` the db, back
  it up with `cp`, and recompute every derived number from stored raw streams.
- **Consequence:** the database *is* the interface. Schema design and migration
  safety matter more than any single feature.

The db holds Strava OAuth tokens and the client secret (so sync auto-refreshes with
no env vars). Because of that, stride locks `~/.stride` to `0700` and the db to
`0600` on every run, and secret config keys are never printed through `config get`
or any JSON. The secret-key policy is one tested source of truth (`Config.is_secret`).

## 2. Written in Roc — and pinned, deliberately

Toolchain: Roc's **new (Zig) compiler** (nightly, pinned by exact tag in
`.github/workflows/build.yml`) · basic-cli `0.22` · builtin JSON (no roc-json). The
earlier alpha4 / basic-cli 0.20 / roc-json 0.13 pin is retired (issue-claims: quoting); §9 records the
migration and why the original "blocked on roc-json" conclusion was wrong. CI
type-checks (`roc check`) and runs the pure tests (`roc test`) on this compiler across
linux/macOS/Windows, then builds the real binary and runs the e2e suite on macOS. The
`roc build` perf gate is gone (roc#10469, fixed by roc#10531); builds pin `--opt=dev` for
build time (~14s against ~2min), not correctness — the optimized backend's miscompile
(issue #32) was fixed by the 2026-08-17 compiler pin. Day-to-day compiler
syntax/stdlib/platform notes live in `docs/roc-new-compiler-notes.md`.

### Effects live in modules, organized by concern

The new compiler lets any module use platform effects, so I/O is split by concern
instead of piled into `app.roc`: `Db.roc` owns SQLite plus the schema/migrations,
`Strava.roc` owns the OAuth + sync HTTP, `Analyze/Plan/Import` and the report family
(`Report.roc` plus `ReportSessions/ReportHealth/ReportSeason`, split by read-command
family in #196) own their commands, and `app.roc` is a thin argv → dispatch shell. Pure logic still lives in
its own tested modules: `Metrics.roc` (training math), `Sports.roc` (sport vocabulary),
`Render.roc` (tables/formatting), `Command.roc` (argv → typed command), `Config.roc` (key
policy), `Csv/Streams/Backfill`. `Schema.roc` is pure DDL with no expects. `Output.roc` owns the envelope and is effectful.

Historical note: under alpha4 this split was impossible — module params were
*monomorphic*, so injecting effects broke any row decoder wider than two columns and
every command had to sit in `app.roc`. The new compiler removed that wall, and the
repository/query split it used to block is simply how the code is laid out now.

### SQL lives next to its decoder

The compiler can't check a `SELECT … AS x` alias against a `Sqlite.i64("x")`
decoder. Adjacency is the safeguard: query strings sit immediately next to the row
decoder they feed. Only decoder-free DDL lives in `Schema.roc`.

### Tests: pure `expect`s + a native-Roc e2e

Effectful `expect`s can't run under `roc test` — they need a platform (on alpha4 they
segfaulted outright, exit 139). So Roc keeps the pure `expect`s, and
end-to-end coverage is a native-Roc suite
(`tests/e2e.roc`) that drives the real binary against a sandboxed `HOME` with seeded
activities of known math. It's a basic-webserver app that runs every check in `init!`
then exits (basic-cli's exec host drops child exit codes under the suite's several hundred
subprocess spawns; basic-webserver's reaps them cleanly). The network path (sync +
token refresh) is the same file's `E2E_MODE=sync` role driven against its
`E2E_MODE=mock` role (a mock Strava on a local port), pointed at via `STRIDE_API_BASE`
and run by `just e2e-sync` — kept out of `just test` because it binds a port. (Still a
gap: 429 rate-limit backoff, which needs a stateful mock.)

## 3. Three data tiers, three recovery stories

Every table belongs to exactly one tier, and the tier dictates how it recovers:

| Tier | Tables | Recovery |
|---|---|---|
| **Mirror** | `activities`, `streams` | Replace-on-sync; re-pullable from Strava. |
| **Computed** | `activity_metrics`, `daily_load`, `activity_segments` | Rebuilt from `analyze` (segments per ADR 0008 §4). |
| **Judgment** | `planned_sessions`, `config`, `ratings` | Exist *only* here — human input. |

The load-bearing rule: **human input must never be a column on a mirror table**, or
a re-sync would silently wipe it. This is why session-RPE ratings live in their own
table rather than on `activities`.

## 4. Training load is a mixed model, not "TSS"

Load is scored by a ladder that picks the best available source per activity:
stream normalized power → Strava weighted watts → average watts → **pace** (normalized
graded pace against a threshold speed, per-sport exponent — ADR 0003) → zone-weighted
hrTSS → **session-RPE** → `relative_effort` → honest zero. For strength-class sports the athlete's
own **session-RPE** rating outranks HR (`load = hours × RPE × 10`, TSS-commensurate
by construction — raw Foster minutes×RPE would be ~6× too large and corrupt CTL/ATL).

Because the blended total is not all TSS, stride **stops calling it "TSS"** in
mixed contexts and instead records, per metrics row:

- `load_model` — which ladder rung scored it (provenance).
- The confidence tier — **high** (measured power OR distance-measured pace), **medium**
  (HR or session-RPE), **low** (relative effort), **none** (unscored). DERIVED from
  `load_model` at read time, not stored: the `load_confidence` column existed until
  schema v8 and was dropped for being derivable. Surfaced as a distribution by `doctor`.

`doctor` is the trust center: coverage, provenance, the confidence distribution,
config completeness, streams still pending, and the active time anchor — every
gap stated as what / why / fix.

## 5. Metric invalidation is explicit

Computed metrics must never go stale silently. Each `activity_metrics` row records
the inputs it was computed under, and recomputation is triggered by:

- **FTP change** — compared via `ftp_used`.
- **Derived threshold-pace change** — compared via `threshold_pace_used`, the pace
  analog of `ftp_used`, keyed per *sport* rather than per family. Like `ftp_used`, a new
  best rescores only the rows whose own 60-day window moved (#79).
- **HR-zone change** — compared via a `zones_used` signature.
- **Algorithm change** — the `metrics_rev` constant; bump it whenever `Metrics`
  math changes (config provenance can't see code changes).
- **Activity inputs** — each metrics row stores the activity fields it was scored
  from (`mt_used`, `aw_used`, `sport_used`, …) and `analyze` compares them value by
  value, exactly as `ftp_used` works. A changed activity rescores itself.
- **Stream arrival / rating change** — these paths delete the affected metrics row
  so the next `analyze` rescores it.

`sync` deliberately does NOT delete metrics. It re-lists a rolling 30-day window
every run and cannot cheaply tell an edit from a no-op, so invalidating there wiped
a month of computed metrics on every sync and left every report under-reporting
load until the next `analyze` — a correctness bug, not just wasted work. Detecting
staleness in `analyze` is stateless and self-correcting: there is no flag to drift,
and the comparison costs nothing extra because `analyze` already runs that
predicate. `synced_at` is excluded from it, since it changes by design every run
and would mark every row stale. The comparison is value-by-value rather than a
hash: an additive signature cancelled on a +7s/-1m edit and missed it silently.

Any new metric input must join this story.

## 6. Schema self-migrates — but breaking it is fine while we're early

The schema versions itself via `PRAGMA user_version`. Upgrading the binary against
an existing db migrates on the next command; migrations converge to the current
schema idempotently (rename first, then create-if-not-exists, then add-column).
Legacy-db fixtures in `tests/fixtures/db/` prove upgrades preserve data.

**Pre-1.0, the schema is not a stable contract.** With a tiny user base, a
structural change does not need a backward-compatible migration path for every
prior version — it's acceptable to change column types directly, drop/recreate the
**mirror and computed** tables (they rebuild from `sync`/`analyze`), or reset a db
outright when that's simpler than a migration. The one inviolable rule is the tier
boundary from §3: a schema change must **never silently destroy judgment-tier data**
(`ratings`, `planned_sessions`, `config`, including tokens) — that data exists only
here and cannot be re-derived, so it must be migrated or explicitly, knowingly reset.
Don't spend effort making migrations bulletproof against versions no real db is on.

That permission is scoped to pre-1.0 and expires with it — §9c states what each versioned
surface promises from 1.0 onward, and the tier rule above is the one part that was never
a pre-1.0 concession in the first place.

## 7. Machine output is a versioned envelope

Every JSON response is wrapped and versioned so tool callers can detect a contract
change and always discriminate success from failure:

- success → `{"schema_version":2,"data":{…}}` (was 1 until the doctor field rename, 2026-08-06)
- error → `{"schema_version":2,"error":{"code":"…","message":"…"}}`

Errors are in-band on stdout, and since #163 they also exit non-zero (see the amendment below). The envelope is
deterministic (no timestamps) so golden comparisons stay stable. Human table output
is a separate, independent rendering path. JSON is emitted when asked for — `--json` on the command, else
`STRIDE_FORMAT=json`; nothing is inferred from the environment (see the 2026-08-17
amendments below). This was made the default (not gated) while the user
base is still small enough to absorb the break.

## 8. "Today" is a local calendar day

CTL/ATL/TSB extend through *today*, so the day boundary must match the athlete's
civil day (the platform clock is UTC-only; without an anchor, users west of UTC get
a phantom "tomorrow" each evening). Precedence: **`timezone` (IANA, DST-correct for
the current date via the system tz database) > `utc_offset_minutes` (fixed) > UTC**.
An unknown timezone name never silently becomes UTC — it falls back to the fixed
offset and `doctor` flags it. Historical per-activity dates already use Strava's
civil date, so only the today boundary needs this.

## 9. Compiler migration — DONE on the new compiler, build no longer gated

The migration to Roc's new (Zig) compiler is **merged to `main`**: the whole codebase
is in the new type-module dialect (`Name :: [].{}`, `List(X)`, `Result`→`Try`,
`True`/`False`), on basic-cli 0.22 with builtin JSON, and `build.yml` pins the new
compiler by exact nightly tag. CI runs `roc check` + `roc test` (pure expects) green
on every push.

**Build unblocked, and no longer gated.** `roc build src/app.roc` *used to* peg the
Specialization phase for minutes — an upstream compiler-perf bug (roc-lang/roc#10469,
SpecConstr blowup), fixed upstream by roc-lang/roc#10531 (merged 2026-08-02). A *separate*
backend bug then kept the optimized build unusable: an intermittent heap-corruption SIGABRT
in `--opt=speed` (issue #32), measured at 40 aborts per 1400 invocations on the old pin and
concentrated in `season` (~8%) and `power-curve` (~7%) but NOT confined to them —
`activity` aborts at ~0.8%, found only by replicating; a single 200-run sample had read
as zero. Both are resolved — the 2026-08-17 compiler pin
gives 0 per 1400 with output byte-identical to `--opt=dev`. Builds still pin `--opt=dev`,
now purely for build time. `roc build` on the old alpha4 toolchain is gone with the
migration.

**Windows ships** (`stride-windows-x86_64`, since v0.3.0): the new compiler plus
basic-cli's x64win host target it, and `OsStr.display` decodes the `WindowsU16s` argv arm.
All five release targets ship, linux-arm64 included — `release-please.yml` passes it an
explicit `roc_target: arm64musl`, `verify-arm64.yml` re-checks it on dispatch, and every
release from v0.4.0 onward carries `stride-linux-arm64`.

**CORRECTION kept for the record (2026-08-01; issue-claims: quoting):** the earlier "hard-blocked on
roc-json" conclusion was wrong — it assumed all JSON had to go through a roc-json
port, but JSON parsing is a builtin in the new compiler
(lukewilliamboswell/roc-json#52), so roc-json was dropped, not ported. Lesson worth
keeping: "blocked" was an untested assumption stated as fact — verify with the source
before writing a constraint into the record.

## 9b. What stride IS

Everything below in §10 says what stride refuses. Nothing has said what it is, and the
cost of that is measurable: a careful outside reviewer read this repository and wrote a
page proposing, as future direction, an architecture stride already ships — provenance,
confidence tiers, plan and adherence memory, null semantics, versioned schemas,
rep-level progression, an engine/coach boundary. They then proposed two things §10 and
ADR 0006 rule out, without engaging the reasoning, because nothing pointed at it (#216).

**Stride is the deterministic, local source of athlete state.** It turns training
evidence into traceable facts — each carrying its own provenance and its own uncertainty
— that a human or a reasoning system can consume without trusting stride's judgment,
because stride does not offer any.

Three consequences. Most of §10 follows from one of them. Not all, and the exceptions are
worth naming rather than papering over: graphs and social carry their own grounds in §10
— an experiment that ran and failed, and the fact that Strava already exists — neither of
which is an architectural consequence of anything here. Medical follows from the header
above rather than from these three:

- **Data providers are inputs, not the identity.** Strava is one grandfathered API
  because it is an aggregator that already exists (ADR 0006). The engine is not "a Strava
  tool"; it is an athlete-state engine that currently ingests Strava. That is why the
  ingestion boundary is the filesystem rather than a vendor list.
- **The reasoning layer is interchangeable BY CONSTRUCTION.** No model in the binary, no
  model API key, no vendor coupling — versioned JSON on stdout and an exit code. (§1's
  Strava tokens are ingestion credentials, a different thing.) Any agent can
  consume it, and the engine outlives whichever model is currently best. This is why §10
  refuses an MCP server: the claim is that the CLI plus versioned JSON already IS the
  agent interface, not that agent consumption is unwanted.
- **The athlete's state is the product.** Not the report, not the recommendation. A file
  they own, greppable, backed up with `cp`, recomputable from raw streams.

§10 is the single scope list; this section does not restate it and must not grow into a
second one.

## 9c. The 1.0 compatibility contract

Pre-1.0 breakage (§6) is scoped to pre-1.0. Releasing 1.0 changes what that permission
means, and stride has six surfaces a caller can depend on which are NOT one promise
(#217). Only three of them carry a version number of their own — the binary,
`PRAGMA user_version`, and `json_schema_version`; CLI behaviour and judgment-tier data
carry none, which is exactly why they need stating rather than inferring.

| surface | 1.x promise |
|---|---|
| Binary version (`app.roc`, release-please) | semver, and the source of truth for "which stride is this" |
| SQLite schema (`PRAGMA user_version`) | migrates forward on next command; §3's tier rule is inviolable — judgment-tier data is never silently destroyed |
| Envelope (`json_schema_version`) | bumps when the WRAPPER changes, or a payload field is removed or retyped |
| CLI commands and arguments | additive; a name that parses in 1.x keeps parsing to the same variant |
| Judgment-tier data | survives every upgrade, unconditionally — it cannot be re-derived |
| `schemas/v2/*.json` | see below, because this one is not what it looks like |

**Adding a payload key: non-breaking to READERS, breaking to VALIDATORS.** Both halves of
that were already written down and they appear to contradict: the envelope rule says
adding a field does not bump the version because "a consumer reading known keys is
unaffected by a new one appearing", while every schema carries `additionalKeys: false`,
so anything validating a payload against the checked-in schema fails the moment a key is
added. Both are true. "Consumer" means two different things.

The 1.x resolution: **the schemas are stride's own contract with itself, not a
closed-world validator for third parties.** `additionalKeys: false` exists so that a
payload which GREW without a schema update is caught rather than shipped. In CI that
enforcement is `just e2e`, which runs `tools/validate.jq` against seeded fixtures;
`just schema-check` runs the same validator against your own database and is the
"does MY data conform" pass, local and not part of CI. Coverage is not total, and it now has three tiers rather than two. Five
payloads (`complete`, `import`, `init`, `rate`, `sync`) are validated by neither pass, so
a key added to THOSE is currently caught by nothing. `tte` is covered by the local recipe
but not by CI. `sync` is covered by a third pass: `just e2e-sync`, which drives it against loopback
mocks and now runs in CI. That recipe was assumed to need a token and a live API and so
was left out of CI for a long time; it needs neither — the mocks bind loopback, and the
token is a fake row in a sandboxed HOME — and the assumption cost the stream drain its only
payload-vs-schema check.

Worth stating because the near-miss is tempting: the COMPILER does not substitute for
the validator. `Render.sync`'s payload record is closed, so an added, removed or
retyped payload key fails `roc check` until that annotation and its expects are widened.
That guards payload↔SCREEN. Widen both and the build is green with the schema untouched
— payload↔schema is a different invariant, and the compiler error never mentions the
schema, so it does not even prompt the right fix. Where a payload has no validating pass,
it is unguarded against its schema, full stop.
A downstream consumer should read the keys it needs and validate its OWN required subset.
It should not use stride's schema as a closed-world check, and stride does not promise
that it can.

So: adding a key is additive and does not bump `json_schema_version`. Removing or
retyping one does. A change that would break a reader of known keys is a `v3/` directory,
not an edit to `v2/`.

**Error codes are additive in 1.x.** The vocabulary is published, and `tests/e2e.roc`
diffs the enum against the codes the source emits, so the two cannot silently disagree.
Note what that does NOT enforce: it asserts set EQUALITY, so deleting a code from the
source and the enum together passes green. Additivity is a promise this document makes,
not one the suite currently checks — a caller branching on a code must keep working, and
nothing but review stops that being broken.

## 10. Deliberately out of scope

This is the single list — the roadmap carried a second, overlapping one until it was
retired, and neither was a superset of the other.

- **TUI** and **MCP server** — the CLI plus versioned JSON is the interface.
- **Cloud / web sync** — local-first is the identity, not a stage.
- **Injury and medical claims** — outside what training data can honestly support.
- **Replacing SQLite** — a file the athlete owns, greps and backs up with `cp`.
- **Moving any math into the LLM** — the engine computes, the coach reasons (ADR 0012).
- **Multi-athlete / coach views** — breaks the single-user local db that keeps everything
  else simple; a coach reads the athlete's JSON instead. (Friends each running their own
  copy is a different thing and is in scope.)
- **Graphs** — that experiment ran and failed; tables, legends and verdict lines are the
  visualization layer.
- **ML predictions** — nothing ships that cannot be recomputed by hand from stored inputs.
- **Social features** — Strava exists.
- **Vendor-cloud integrations** (Garmin Connect, Wahoo, Peloton APIs, …) — the ingestion
  boundary is the filesystem; Strava is the one grandfathered API.
- **Raw device-format parsing** (FIT/TCX/GPX) — Strava is the parser (ADR 0006).
- **`.zwo` workout export** for smart trainers — stride prescribes nothing (ADR 0012), so
  it has no workout to export; the coach writes the session.

(issue-claims: quoting. The query-repository split used to sit here as "blocked by the compiler"; that wall is
gone and the split IS the current layout — see §2 and ADR 0001. The further per-command
subdivision of `Report.roc` is done too: ADR 0001's file-size trigger fired, and #196
shipped the read-command split. What is left is that ADR's function-size half, deferred
until it has a better predicate.)

These are revisited only when dogfooding demands them.

**Promoted into scope:** a generic every-sport model. This list previously called it out
of scope; dogfooding demanded it (friends who run and swim can't be scored honestly by
the power+HR ladder), which is exactly the "revisited when dogfooding demands" trigger.
It is now [ADR 0003](0003-multi-sport-scoring.md). Single-user local-first (§1) is
unchanged — sport-completeness is not multi-tenancy.

---

Open work lives in GitHub issues; no scratch plan file DESCRIBES work (see AGENTS.md — a watch-item tracked in one went unnoticed for weeks, #196). A root `PLAN.md` may hold sequencing and its reasons — the one thing issues cannot carry — provided every item is a pointer, it is scanned by `just issue-claims` like any other doc, and it deletes itself when the sequence is done. The moment it describes what a ticket contains — beyond the one fact that creates a
sequencing constraint — it has become the file that rotted.
Enforced invariants and build/release mechanics live in the project instructions.
When a decision here changes, update this ADR in the same commit as the code.


## Amended 2026-08-17 — errors exit non-zero (#163, PR #178)

§7 above said errors stay exit 0 and callers should read the JSON rather than `$?`. That was written when environment detection was the only machine interface and every caller was an LLM parsing stdout. #162 made the machine interface explicitly tool-neutral (`--json` for shell scripts, MCP clients, other agents), and for those callers an always-zero exit lies to `set -e`, `&&` chains, CI steps, and process supervisors.

The envelope is unchanged — this adds information to a channel that previously carried none. Every error envelope exits 1 — but not every exit 1 carries an envelope: an uncaught platform error prints to stderr with empty stdout (#183). Usage errors DID print a plain line; #180 gave them an envelope for machines, so the human line survives only in human mode. success exits 0; asking for help (bare `stride`, `--help`, `-h`, `help`) exits 0 because it is not a failure; an unknown command is an invocation error that emits an `unknown_command` envelope to machines and the help text to humans, exiting 1 either way. Warnings inside a successful command (analyze's pending/stream-error notes, a stream that would not decode) stay at exit 0 — they are reported in the payload, and the command did what it was asked.
