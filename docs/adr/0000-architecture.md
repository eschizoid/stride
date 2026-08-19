# ADR 0000 — stride architecture and key decisions

Status: accepted · Last reviewed: 2026-07-31

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
earlier alpha4 / basic-cli 0.20 / roc-json 0.13 pin is retired; §9 records the
migration and why the original "blocked on roc-json" conclusion was wrong. CI
type-checks (`roc check`) and runs the pure tests (`roc test`) on this compiler across
linux/macOS/Windows, then builds the real binary and runs the e2e suite on macOS. The
`roc build` perf gate is gone (roc#10469, fixed by #10531); builds pin `--opt=dev` for
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
policy), `Csv/Streams/Backfill/Schema`. `Output.roc` owns the envelope and is effectful.

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
then exits (basic-cli's exec host drops child exit codes under the suite's ~350
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
config completeness, pending stream backfill, and the active time anchor — every
gap stated as what / why / fix.

## 5. Metric invalidation is explicit

Computed metrics must never go stale silently. Each `activity_metrics` row records
the inputs it was computed under, and recomputation is triggered by:

- **FTP change** — compared via `ftp_used`.
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

**CORRECTION kept for the record (2026-08-01):** the earlier "hard-blocked on
roc-json" conclusion was wrong — it assumed all JSON had to go through a roc-json
port, but JSON parsing is a builtin in the new compiler
(lukewilliamboswell/roc-json#52), so roc-json was dropped, not ported. Lesson worth
keeping: "blocked" was an untested assumption stated as fact — verify with the source
before writing a constraint into the record.

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

(The query-repository split used to sit here as "blocked by the compiler"; that wall is
gone and the split IS the current layout — see §2 and ADR 0001. What remains open is the
further per-command subdivision of `Report.roc`, governed by ADR 0001's measured trigger,
which has now fired: #196.)

These are revisited only when dogfooding demands them.

**Promoted into scope:** a generic every-sport model. This list previously called it out
of scope; dogfooding demanded it (friends who run and swim can't be scored honestly by
the power+HR ladder), which is exactly the "revisited when dogfooding demands" trigger.
It is now [ADR 0003](0003-multi-sport-scoring.md). Single-user local-first (§1) is
unchanged — sport-completeness is not multi-tenancy.

---

Open work lives in GitHub issues; there is deliberately no scratch plan file (see AGENTS.md — a watch-item tracked in one went unnoticed for weeks, #196).
Enforced invariants and build/release mechanics live in the project instructions.
When a decision here changes, update this ADR in the same commit as the code.


## Amended 2026-08-17 — errors exit non-zero (#163, PR #178)

§7 above said errors stay exit 0 and callers should read the JSON rather than `$?`. That was written when environment detection was the only machine interface and every caller was an LLM parsing stdout. #162 made the machine interface explicitly tool-neutral (`--json` for shell scripts, MCP clients, other agents), and for those callers an always-zero exit lies to `set -e`, `&&` chains, CI steps, and process supervisors.

The envelope is unchanged — this adds information to a channel that previously carried none. Every error envelope exits 1 — but not every exit 1 carries an envelope: an uncaught platform error prints to stderr with empty stdout (#183). Usage errors DID print a plain line; #180 gave them an envelope for machines, so the human line survives only in human mode. success exits 0; asking for help (bare `stride`, `--help`, `-h`, `help`) exits 0 because it is not a failure; an unknown command is an invocation error that emits an `unknown_command` envelope to machines and the help text to humans, exiting 1 either way. Warnings inside a successful command (analyze's pending/stream-error notes, a stream that would not decode) stay at exit 0 — they are reported in the payload, and the command did what it was asked.
