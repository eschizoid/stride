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

Toolchain (pinned): roc `alpha4-rolling` nightly (2025-09-09) · basic-cli `0.20.0`
· roc-json `0.13.0`.

**Do not bump the platform.** basic-cli 0.21+ and roc-json's would-be successor
target Roc's *new* (Zig) compiler, which is a different syntax dialect on a pre-0.1,
weekly-churning target. The migration is not an effort question — it is **blocked on
a dependency**: stride decodes all JSON via roc-json, and roc-json has no
new-compiler release (its repo has been dormant since 2025-04). See §9.

### Effects only in `app.roc`

In Roc, only the application module may use platform effects. So all I/O (SQLite,
HTTP, Cmd, File, stdout) lives in `src/app.roc`; pure logic lives in tested modules:
`Metrics.roc` (training math), `Render.roc` (tables/formatting), `Command.roc`
(argv → typed command), `Config.roc` (key policy), `Csv/Streams/Backfill/Schema`.

**The commands cannot be split into per-file modules.** This was tested, not
assumed: module params are *monomorphic*, and the record-builder `{ rec <- … }`
desugars into nested decode calls at different intermediate types, so any row
decoder wider than two columns fails to type-check once effects are injected into a
module. A repository/query split is therefore off the table until polymorphic module
params exist. Commands stay in `app.roc`; the pure, effect-free parts (parsing,
math, rendering) are what gets extracted. Re-test this after any compiler change.

### SQL lives next to its decoder

The compiler can't check a `SELECT … AS x` alias against a `Sqlite.i64("x")`
decoder. Adjacency is the safeguard: query strings sit immediately next to the row
decoder they feed. Only decoder-free DDL lives in `Schema.roc`.

### Tests: pure `expect`s + a bash/python e2e

Effectful `expect`s segfault `roc test` on alpha4 (verified: `Cmd.exec_output!`
inside an `expect` exits 139 before running anything). So Roc keeps the pure
`expect`s (~220 of them), and end-to-end coverage is a bash+python suite
(`tests/e2e.sh`) that drives the real binary against a sandboxed `HOME` with seeded
activities of known math. Bash orchestrates; python asserts on JSON only.

## 3. Three data tiers, three recovery stories

Every table belongs to exactly one tier, and the tier dictates how it recovers:

| Tier | Tables | Recovery |
|---|---|---|
| **Mirror** | `activities`, `streams` | Replace-on-sync; re-pullable from Strava. |
| **Computed** | `activity_metrics`, `daily_load` | Rebuilt from `analyze`. |
| **Judgment** | `planned_sessions`, `config`, `ratings` | Exist *only* here — human input. |

The load-bearing rule: **human input must never be a column on a mirror table**, or
a re-sync would silently wipe it. This is why session-RPE ratings live in their own
table rather than on `activities`.

## 4. Training load is a mixed model, not "TSS"

Load is scored by a ladder that picks the best available source per activity:
stream normalized power → Strava weighted watts → average watts → zone-weighted
hrTSS → `relative_effort` → honest zero. For strength-class sports the athlete's
own **session-RPE** rating outranks HR (`load = hours × RPE × 10`, TSS-commensurate
by construction — raw Foster minutes×RPE would be ~6× too large and corrupt CTL/ATL).

Because the blended total is not all TSS, stride **stops calling it "TSS"** in
mixed contexts and instead records, per metrics row:

- `load_model` — which ladder rung scored it (provenance).
- `load_confidence` — a tier: **high** (measured power), **medium** (HR or
  session-RPE), **low** (relative effort), **none** (unscored). Deterministic,
  documented, and surfaced as a distribution by `doctor`.

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
- **Stream arrival / Strava edit / rating change** — these paths delete the
  affected metrics row so the next `analyze` rescores it.

Any new metric input must join this story.

## 6. Schema self-migrates

The schema versions itself via `PRAGMA user_version`. Upgrading the binary against
an existing db migrates on the next command; migrations converge to the current
schema idempotently (rename first, then create-if-not-exists, then add-column).
Legacy-db fixtures in `tests/fixtures/db/` prove upgrades preserve data.

## 7. Machine output is a versioned envelope

Every JSON response is wrapped and versioned so tool callers can detect a contract
change and always discriminate success from failure:

- success → `{"schema_version":1,"data":{…}}`
- error → `{"schema_version":1,"error":{"code":"…","message":"…"}}`

Errors are in-band (exit code stays 0 — read the JSON, not `$?`). The envelope is
deterministic (no timestamps) so golden comparisons stay stable. Human table output
is a separate, independent rendering path. JSON is emitted when `STRIDE_FORMAT=json`
or an agent env var is set. This was made the default (not gated) while the user
base is still small enough to absorb the break.

## 8. "Today" is a local calendar day

CTL/ATL/TSB extend through *today*, so the day boundary must match the athlete's
civil day (the platform clock is UTC-only; without an anchor, users west of UTC get
a phantom "tomorrow" each evening). Precedence: **`timezone` (IANA, DST-correct for
the current date via the system tz database) > `utc_offset_minutes` (fixed) > UTC**.
An unknown timezone name never silently becomes UTC — it falls back to the fixed
offset and `doctor` flags it. Historical per-activity dates already use Strava's
civil date, so only the today boundary needs this.

## 9. Compiler migration and Windows — blocked, not chosen

stride ships Linux (x64/arm64) and macOS (arm64/Intel) binaries. There is **no
Windows build**, and that is *not* a Roc limitation: the Roc compiler targets
Windows and newer basic-cli ships an x64win host. stride can't build for Windows
only because it is pinned to basic-cli 0.20.0 (which predates that host), and it is
pinned there because 0.21+ needs the new compiler.

The new compiler is obtainable and the platform is ready, but the migration is
hard-blocked on **roc-json**: all JSON decode/encode goes through it, and it has no
new-compiler port (dormant repo). A port is a bounded but pioneering syntax
migration on a pre-0.1, still-crashy compiler. **Decision: do not migrate now.**
Windows users are served by WSL + the Linux binary. Revisit when a new-compiler
roc-json release (or a stdlib JSON replacement) appears — that same migration also
unlocks Windows and native effectful-expect e2e.

## 10. Deliberately out of scope

TUI, MCP server, cloud/web sync, a generic every-sport model, injury/medical
claims, replacing SQLite, and moving any math into the LLM. The query-repository
split is blocked (§2). These are revisited only when dogfooding demands them.

---

Working notes and current watch-items live in `.claude/PLAN.md` (local, disposable).
Enforced invariants and build/release mechanics live in the project instructions.
When a decision here changes, update this ADR in the same commit as the code.
