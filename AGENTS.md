# Agent instructions for stride

> **One file, every agent.** `AGENTS.md` is the canonical instruction file — the
> cross-tool convention Codex and friends read from the repo root with no setup. Claude
> Code reads `CLAUDE.md`, not `AGENTS.md`, so the repo tracks a one-line
> `.claude/CLAUDE.md` whose entire content is the import `` `@../AGENTS.md` ``
> (backticked HERE so this sentence is not itself an import — Claude Code expands that
> syntax recursively, and import paths resolve relative to the importing file). A fresh
> clone therefore works for every agent with zero setup. Edit this file; the shim never
> carries content. Do not also create a root `CLAUDE.md` — both locations load and concatenate,
> so a second import would put this whole file in context twice.
>
> The COACHING skill's one canonical copy is `skills/stride/SKILL.md`, and it is the
> ONLY copy: e2e pins that no repo-local shim exists to drift. Claude Code consumes it
> as a plugin (`.claude-plugin/plugin.json` + `marketplace.json`; install via
> `/plugin marketplace add eschizoid/stride`), Codex via `.codex-plugin/plugin.json` —
> both manifests resolve the same `skills/` directory, both versions are written by
> release-please and pinned to the release manifest by e2e, and the three manifest
> descriptions are pinned equal. Any other agent installs the canonical directory into
> whatever skills path it reads.

Local-first, deterministic training analytics engine in **Roc** (Strava is one
ingestion layer). The engine computes metrics deterministically; an LLM coach (you,
via the skill in `skills/stride/`) consumes the JSON and writes the plan
back. **Never do training math yourself — read stride's numbers, add judgment.**

Settled architecture + rationale live in `docs/adr/0000-architecture.md` (committed) —
read it before proposing architectural changes; don't relitigate what it settles.
Open work lives in GitHub issues, shipped work in git history. Workflow lessons go in
whatever memory your agent has — but anything a DIFFERENT agent would need belongs here or
in the issue, not in a store only one tool can read. No scratch plan file DESCRIBES
work: nothing reads such a file, so its sections rot and the watch-items inside fire
unnoticed. A root `PLAN.md` holding only SEQUENCING and the constraints behind it is
allowed — that is the one thing issues cannot carry — but it must be pointers, it must
be scanned by `just issue-claims` like any other doc, and it must delete itself when
the sequence is done. Restating what a ticket contains, beyond the one fact that
creates a sequencing constraint, is where rot begins.

## Build & test

```bash
just test      # THE entry point: pure expects → fresh build → offline e2e. NOT all of CI.
just build     # the binary, --opt=dev (see below); STRIDE_LINKER= is an escape hatch
just install   # build + symlink to ~/.local/bin/stride
```

CI runs more than `just test`, and a green `just test` is not a green build. These are the
rest of it, all runnable locally — run them before pushing. Every one is network-free
except `issue-claims`, which reads the tracker:

```bash
roc check src/main.roc      # CI runs this on three OSes before anything else
just e2e-sync              # mock-backed sync/skips/stops drivers; no network
sh tools/skill-shapes.sh   # the coach skill's payload keys vs schemas/v3
sh tools/blob-safety.sh    # every TEXT decode is projected through CAST(... AS TEXT)
sh tools/command-claims.sh # commands the docs name vs the binary's own table (needs ./stride)
just issue-claims          # issue-state claims in comments (needs `gh` auth)
```

Prerequisites for everything above: `just`, `jq`, `sqlite3`, `gh`, and the Roc
nightlies: the ENGINE pin is the default in `.github/actions/setup-roc/action.yml`
(one place); the VIZ pin lives in `src/viz/main.roc`'s app header and
`tools/pin-check.sh` holds every workflow site to it.

- **Always `just test` in one command, read the result, commit in a separate command.**
  Never chain `test && commit` — a mid-chain failure commits red.
- A failed build leaves a stale binary that e2e would happily "pass" against; `just
  test` orders steps to prevent this. Don't run `just e2e` after a failed build.
- Toolchain: the new (Zig) compiler, pinned by exact nightly tag (engine and viz
  pins: see *Compiler pins* under Code conventions) · basic-cli **0.22** · builtin
  JSON. `~/.local/bin/roc` is a SYMLINK to the engine nightly; a bare `roc` in the
  justfile rides it — pin the explicit path in anything that must not depend on that
  link.
- **Build with `--opt=dev`** — build time (seconds vs minutes), not correctness:
  `--opt=speed` is sound on the current pin (#32 is fixed) but too slow for the
  loop. `just build`, CI, and the release workflow all pin dev.
- **New-compiler flag gotcha: `=`, not a space.** `--output=x`, `--main=x`, `--opt=dev`.
  A space-separated `--output x` fails with a confusing error.

## Code conventions

- **Guards are code here; prose only states properties.** A comment states a
  property of the WORLD, never an event in this project's history: SQLite takes a
  write lock when switching journal mode; `?` is a function-level early return
  that lands on the catch-all; Strava's CSV has duplicate `Distance` headers —
  those stay true. What a review round caught, how many attempts a fix took, what
  a previous draft of the comment said, how many times a defect recurred: events,
  and noise the moment the change merges. Keep the fact the incident taught; drop
  the incident. Two corollaries: a number no assertion enforces will drift, so
  assert it or delete it; and prose written at an imagined critic ("do NOT 'fix'
  this") argues with nobody. **Rewrite a comment block whole rather than patching
  a line** — a partial edit leaves the old text spliced to the new, which
  compiles, passes every gate, and describes something the code does not do.
  The converse matters as much: several things that LOOK decorative are the
  guard, and tidying them breaks something. A `: Bool` annotation stops a field
  serializing as the string `"True"`; a row decoder sitting beside its query is
  the only check on `SELECT ... AS x` aliases; the `CAST(... AS TEXT)` around a
  TEXT projection is what survives a BLOB in that column. Each is enforced below
  or by a gate — none is documentation.

- **Effects live in modules, by concern** — the new compiler lifted the alpha4
  monomorphic-module-param wall, so I/O is split out of main.roc: `Db.roc` (SQLite +
  schema/migrations), `Strava.roc` (OAuth + sync HTTP), `Analyze/Plan/Import` and the
  report family — `Report.roc` (summary/load/compare + the helpers the others share),
  `ReportSessions.roc`, `ReportHealth.roc`, `ReportSeason.roc` — each owning its commands;
  `Output.roc` (the envelope boundary — `emit_ok!`/`emit_err!`, `json_schema_version`);
  `main.roc` is a thin argv → dispatch shell. The report modules depend INWARD on
  `Report.roc` and it imports none of them (#196, ADR 0001).
  Pure logic goes in `Metrics.roc` / `Sports.roc` (sport vocabulary: the four sport-varying policies — family filters, load-model class, pace routing, the pace-TSS exponent — gathered in one module rather than scattered through others; only the family filter is a table of rows, the class reads a list literal inside its own function, and the last two are name-substring predicates) / `Render.roc` / `Command.roc` (argv → typed
  `Command` union, `parse` is pure + unit-tested; `main!` is thin parse-then-dispatch)
  / `Config.roc` (`is_secret` secret-key policy) / `Csv.roc` / `Streams.roc` /
  `Drain.roc`, with `expect` tests (`Schema.roc` is pure DDL and carries none). When adding logic: pure
  function + expects first, thin effectful skin. Add new pure modules to the
  `just test` recipe so their expects run.
- **Query-command output goes through `out!`** (payload + render fn): JSON is wrapped
  in the versioned envelope by `emit_ok!`/`emit_err!` (`{schema_version, data}` /
  `{schema_version, error:{code,message}}`), humans get a pure `Render.<cmd>_screen`
  (or inline closure). A payload field you ADD must also be added to
  `schemas/v3/<command>.json` — `additionalKeys: false` means an undeclared key
  fails validation, which is the point. Say CI only where CI validates that
  payload — ADR §9c enumerates which pass covers which command, and it is not all
  of them. Do NOT reach for
  the compiler as a substitute where the validator is absent: the closed record on
  the screen function pins payload↔SCREEN, so widening both ships a green build
  with the schema stale. Different invariant (`just schema-check` runs the same
  validator against your own database — note that means the REAL `~/.stride` with your
  real `HOME`, so a bumped DATABASE `schema_version` (`Db.roc`'s constant behind
  `PRAGMA user_version`, not the payload envelope's `schema_version` this paragraph is
  otherwise about) migrates it; snapshot first if that matters; `tools/schema-lint.jq` keeps schemas
  inside the subset `tools/validate.jq` actually reads — `title` included, since the
  validator uses it as the violation path's prefix — plus `description` for humans).
  Platform failures are converted to envelopes at ONE boundary (`run_command!`
  in main.roc) rather than at each call site, so a caller never meets a raw
  runtime banner; a new failure shape means a new arm there, not a new habit.
  Errors are in-band on stdout AND exit 1 (#163: the
  envelope is the payload, the status is the signal; a bare invocation is not a
  failure and exits 0 — humans get the help screen, machines get the command list —
  and an unknown command is an error). New commands are born on this
  pattern; older ones migrate as touched.
- `tests/e2e.roc` is ONE binary in FIVE roles, picked by `E2E_MODE`: the offline suite
  (default, no mode set), a mock Strava server (`mock`), and three drivers that run
  against it — `sync` (real sync + token refresh), `skips` (the undecodable-body skip
  path), and `stops` (the `budget_reached` / `rate_limited` / `daily_cap_reached` / `list_rate_limited` outcomes). `just e2e-sync`
  starts several mock instances, each on its own port — one serves the happy path and the
  budget/daily-cap arms, the rest each stand for a failure shape — and runs every driver
  arm; behaviour is varied by `E2E_*` flags, some shapes taking more than one. Read the
  recipe for the current set rather than trusting a count here — enumerations in
  prose rot. `STRIDE_API_BASE` points stride at the mock, and
  `STRIDE_READS_PER_WINDOW / STRIDE_READS_PER_DAY` shrinks the rate-limit pacing so a terminal arm that would
  otherwise cost a full 95-read window is reachable in milliseconds. Same species of seam as
  `STRIDE_API_BASE`; humans never set any of them. They can only LOWER a limit — an
  override able to RAISE one would let a typo or a copied command line hammer Strava and
  get the athlete's own API app suspended, and lowering is all a test needs. This recipe DOES run in CI — it needs
  no network and no credential (loopback mocks, a fake token row in a sandboxed HOME).
  It runs single-shot, no retries — a flake here deserves an
  investigation, not absorption. Standing caveat: every string in the mock fixture is
  short enough to live inline in a RocStr, so this suite is structurally blind to
  heap-string bugs — a change to the sync decode/bind path must be run against real
  Strava data before it is called working.
- **Effectful `expect`s can't run under the test runner** — so `roc test` covers the pure
  modules only, and the e2e suite is a real Roc app (`tests/e2e.roc`, sandboxed HOME, no
  network) driven by `just e2e`. **Verify features with Roc expects + that harness, not
  throwaway awk/shell.** No python anywhere in this project.
- **SQL queries stay next to their row decoders** in whichever module owns the
  query (`Db.roc`, `Report.roc`, …). Only decoder-free SQL (DDL) lives in
  Schema.roc.
- **Every TEXT column read by `Sqlite.str` / `Sqlite.nullable_str` is projected through
  `CAST(... AS TEXT)`** — SQLite's dynamic typing lets a BLOB or a number sit in a TEXT
  column, and the decoder meets whatever is actually stored. `sh tools/blob-safety.sh`
  gates this on three OSes in CI and names the (file, alias) pair it cannot prove.
- Table padding is display-width (code points), not bytes — keep emitted glyphs
  monospace-single-width; no varying-height unicode blocks (they render as mush).
- In bash test code: `grep -q` + `pipefail` = SIGPIPE trap; capture output first,
  then grep the variable.
- **Never test against the live `~/.stride/db.sqlite`** — snapshot it first
  (`mkdir -p /tmp/x/.stride && sqlite3 ~/.stride/db.sqlite ".backup /tmp/x/.stride/db.sqlite"`
  — `.backup` does not create the directory, and improvising past that error
  is one step from the accident this rule prevents) and run with an explicit `HOME`.
- **e2e id assertions are positional.** Inserting a `planned_sessions` row mid-scenario
  shifts the auto-increment and breaks later fixed-id checks — find them with
  `grep -nE '\["(complete|skip)", "[0-9]' tests/e2e.roc` rather than trusting a count. Add new
  fixtures at the END of a scenario, and delete what you insert.
- **A bare `True`/`False` serializes as the STRING `"True"`** in an encode-only
  payload. Annotate the field `: Bool`; that is why `Report.roc` carries the
  annotations it does.
- **Compiler pins have one definition each, and a gate holds the copies.** The engine
  pin is the `setup-roc` action's default; the viz pin is the app header, and
  `tools/pin-check.sh` (in CI) fails naming any workflow `nightly-tag:` site that
  disagrees — a prose count of the sites is exactly what the gate exists to replace.
- **Mermaid diagrams in the README**: `<br>` and commas only; other punctuation breaks
  the render.

## The window (src/viz)

A second Roc app shares the database: the roc-ray window (`src/viz/main.roc`;
`just viz` opens it). It pins ITS OWN compiler in its app header —
`tools/pin-check.sh` holds every workflow `nightly-tag:` site to that pin; set
`ROC_VIZ` to a matching nightly locally. No Roc module can be imported by both
binaries (two platforms, two pins — #458 tracks convergence), so every
cross-surface definition lives in a SQL view (`activity_intensity`,
`weekly_ramp`, `activity_power_ladder`, `plan_current`, `week_bounds` — ADR
0017): change semantics in the view, never by copying its SQL into a query.

The window is steered and observed through bus tables in the same database —
`viz_directives` (write), `viz_focus` (read) — and it self-publishes its
capabilities at every launch; `stride viz --json` serves them and is the
discovery source for steering (view numbers, directive fields, staleness),
never a doc's copy. `docs/viz.md` is the reference for all of it.

The e2e suite cannot run the window (it is a GUI): its viz passes play the
window's part by seeding exactly what the window would write, and CI proves
the app still links per-OS. A window-side behavior change needs a live
`just viz` run before it is called working.

## Idiomatic Roc (and the traps that actually bit us)

Language- and toolchain-level, as opposed to the stride-specific conventions above.
These are measured toolchain behaviors, not style opinions.

### Shaping data

- **Records are immutable and `&` only UPDATES fields — it cannot ADD one.** To widen a
  record, construct it explicitly field by field (see the `enriched` build in `Plan.roc`).
- **`Str` has no ordering operator.** Compare numbers, not strings: parse to a day number
  with `Metrics.date_str_to_days` and compare `I64`. Note SQL does NOT share this
  restriction — SQLite happily compares `target_date` as text, which is exactly why a
  stored date must be canonical `YYYY-MM-DD` (`Metrics.is_canonical_date`).
- **Floats have no `Eq`** — never `x == 0.0` in an expect; use `(x).abs() < 0.001`.
  Method-style: there is no `Num.abs` in this compiler, and reaching for it fails the
  build with DOES NOT EXIST.

### Performance

- **`List.sort_with` degrades to O(n²) on already-sorted input.** That is the common case
  for streams, which arrive sorted, so the worst case is the default case — bad enough
  to read as a hang. Check first and sort only if needed — `Metrics.ascending_by_t` /
  `sorted_by_t`.
- **Never accumulate with `List.concat([x], acc)` inside a fold** — it copies the whole
  accumulator every step, so it is quadratic. Fold and prepend instead
  (`Render.reverse_list`). Harmless behind a `LIMIT`, fatal the moment the query is
  unbounded.

### Compiler behavior that reads like a bug

- **A compile-time-known condition is an ERROR, not a warning.** `if False { … }` fails
  with UNCONDITIONAL CONDITION, so you cannot stub a guard off that way to run a negative
  control. Delete the guard instead — that is the truer pre-fix state anyway.
- **Interpolating a compile-time-constant `""` can crash the backend** in `str_concat`
  (heap-corruption SIGABRT, same class as #32). Bind values rather than splicing optional
  fragments into SQL; a bound `:flag = 0/1` in the WHERE beats a conditional string.

### Testing

- **Effectful `expect`s don't run under the test runner** — pure expects cover the pure
  modules; everything effectful goes through the e2e harness.
- **`roc test` caches.** A run can report `(cached)` while your new expects never
  executed. Prove they run by breaking one and watching the count drop.
- **`roc test`'s summary line can lie about the outcome.** When an expect fails to
  COMPILE, it prints `All (N) tests passed` with a silently smaller N and exits **1**. The
  exit code is the truth; the text is not. Read the code, and watch the count.
- **`roc test --main=src/main.roc <module>` runs every expect reachable from the app**, not
  just that module's — so the number it prints is not that file's test count.
- **The e2e harness aborts at the first failing `check!`.** A negative control that
  reverts two fixes at once only ever proves the first one. Revert one at a time.
- **Prove a test before trusting it**: revert the fix, watch it fail, restore — a
  test that passes against reverted code guards nothing.

### Platform APIs

- **Verify against the docs before writing** (basic-cli 0.22 docs, or package source in
  `~/.cache/roc/packages/`) — alpha APIs drift.
- **`Sqlite.query!` on a row that may not exist fails the command.** Use `query_many!`
  and match the empty list — this is how config loading must read any possibly-absent
  key (a zero-row `query!` returns `Err(NoRowsReturned)`, so an unhandled `?` exits 1).
- **SQLite type affinity bites**: INTEGER columns reject `Sqlite.f64` decoders — `CAST(…
  AS REAL)` in the SELECT when unsure.
- **Bind values; never splice text into SQL.** (The platform double-free that once
  forced a splice workaround is fixed in basic-cli ≥ 0.22; #105/#130/#131 hold the
  full forensics if a heap bug ever recurs.)
- **A crash at a host-boundary symbol names where corruption SURFACED, not where it
  was caused** — a backtrace can accuse the HTTP layer while the cause is the bind
  path. Bisect by removing one ingredient at a time, and reach for guard-malloc early
  (`DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib` under lldb): it makes
  use-after-free deterministic and faults at the culprit instruction instead of the
  next victim.
- **Verify anything touching sync decode/bind against real Strava data**, not `just
  test` alone — the mock's inline-RocStr fixtures cannot exercise heap-string paths,
  so a mock-only validation proves nothing about real payloads.

### Style

- **If/else brace style** (`roc fmt` is blocked by #27, so hold this by hand):
  braceless when both branches are single short expressions
  (`if stamp == 0 Null else Integer(stamp)`); braces the moment a branch has a
  local binding, spans lines, or nests another if/match. Matches what fmt emits
  where it works, so the eventual repo-wide fmt commit stays small. Normalize
  existing code only as touched — no style-only sweeps while fmt is broken.

## Product invariants (enforced by code and/or e2e — keep them true)

- Machine JSON: **absence is FLAGGED or DISCRIMINATED, never silently zeroed** (ADR 0009,
  whose three classes this summarises — `src/Output.roc`'s comment block is the contract of
  record). *Impossible-zero* fields keep 0 as the magnitude and ship a `_known`
  companion decoded from the STORED NULL (`CASE WHEN … IS NULL`) — `np_w`/`power_known`,
  `avg_hr`/`hr_known`. (`ftp_used` is impossible-zero but ships NO flag: analyze always
  BINDS it — never NULL, and 0 when the sport has no derivable FTP — so a NULL-decoded
  flag would be all-true. Readers discriminate on `ftp_used > 0`, as `doctor` does.) The zone vector is the
  exception that proves the rule: `zones_known` is `COALESCE(hr_samples_total,0) > 0`, a
  count test rather than a NULL test, because an all-zero zone vector is ambiguous —
  which makes it an *ambiguous-zero* discriminator, not an impossible-zero flag.
  *Both-possible* fields always carry `_known`, and there the flag IS the null —
  `decoupling_pct`, `form_delta_7d`, `hr_drift`, `rec_drop`, and `form_tsb` **in
  `analyze`** (summary ships `form_tsb` bare — it is always computable there). *Ambiguous zeros* get a discriminator rather than a flag: `tss: 0` is read through
  `load_model`, and the zone vector through `zones_known` (described above). The engine never invents a value; human
  tables still render `-`.
- Machine JSON is a **versioned envelope** — success `{schema_version, data}`, error
  `{schema_version, error:{code, message}}`. Bump `json_schema_version` when the WRAPPER
  changes, or when a payload field is REMOVED or retyped. **Adding** a field does not bump
  it: the version describes the envelope, not the keys inside `data`, and a consumer
  reading known keys is unaffected by a new one appearing (precedent: `converged`, 9c67470).
  That is true of a READER and false of a VALIDATOR — `additionalKeys: false` makes an
  added key fail — and ADR §9c resolves which one 1.x promises.
  Deterministic (no timestamps) so golden fixtures stay stable.
- **Load is a mixed model, not "TSS"** — power/HR score in TSS, rated strength/HIIT in
  session-RPE. Don't relabel the blended total "TSS"; each metrics row carries
  `load_model` (provenance). Confidence is DERIVED from it at read time, not stored —
  the `load_confidence` column existed until v8 and was dropped for being derivable —
  and the mapping is high = measured power OR distance-measured pace (`rtss`), medium =
  HR/RPE, low = relative-effort, none = unscored. `doctor` reports the distribution.
- One **open** planned session per date; lifecycle open → done/skipped (never
  delete). Rest days complete WITHOUT an activity id; every other type requires
  one — done means evidence.
- **Three data tiers, three recovery stories**: mirror tables (`activities`,
  `streams`) are replace-on-sync and re-pullable — design freely; computed tables
  (`activity_metrics`, `activity_segments`, `daily_load`) rebuild from `analyze`; judgment tables
  (`planned_sessions`, `config`, `ratings`) exist ONLY here — human input must
  NEVER be a column on a mirror table (a re-sync would silently wipe it).
- **Session-RPE load is `hours × RPE × 10`** (1h @ RPE 10 = 100, TSS-commensurate
  by construction). Never "simplify" to Foster's raw minutes — ~6× too large,
  corrupts CTL/ATL. Strength-class sports rank the athlete's rating above HR;
  endurance ranks measured power/HR first (`Sports.class`).
- HR samples outside 35–220 bpm are junk — filtered at analyze. The same bound is applied
  again at report time (`Metrics.valid_hr`), which is what keeps an 18 bpm average from being
  scored as the GROUP's best EF. From #311 it is applied to `avg_hr_scored`, not to the stored
  `avg_hr`: when the surviving in-band samples span at least half the LONGER of the stream's own extent and the session's moving time, the engine scores from the
  MEAN of that stream's in-band samples, because a stored average computed from a lossy stream
  can be plausible and still wrong — the plausible-but-wrong average is the common
  failure, not the impossible one. A stored value is still what the bound sees when no usable stream exists, and still
  what the display surfaces publish beside it — `progress`, `activity` and `activities` carry both fields, `plan` and `top hr` only the stored one.
- `activity_metrics.ftp_used` drives auto-recompute on FTP change — any new metric
  input must join that invalidation story.
- CTL/ATL/TSB extend through **today** (rest days decay fatigue in the engine).
  "Today" is the **local** calendar day; the platform clock is UTC-only, so without
  a local anchor, users west of UTC get a phantom "tomorrow" row each evening. The
  anchor is resolved by `resolve_time_mode!` with precedence **timezone >
  utc_offset_minutes > UTC**: config `timezone` (IANA, e.g. America/Chicago) reads
  the DST-correct offset for *today* from the system tz db (`/usr/share/zoneinfo`
  gate + `date +%z`); config `utc_offset_minutes` is a fixed fallback. An unknown
  timezone name never silently becomes UTC — it falls back to the fixed offset and
  `doctor` reports `time_ok:false`. (Historical per-activity dates already use
  Strava's civil date, so only the today boundary needs this.)
- Metric invalidation (recompute triggers): **derived-threshold change** — `ftp_used`
  for power and `threshold_pace_used` for pace, both period-anchored and compared the
  same way (the pace one keys on exact `sport_type`, not family) — **HR zone
  change** (`zones_used` signature), **stream arrival** (store_streams! deletes
  metrics), **activity-input change** (each metrics row stores the inputs it was scored from — `mt_used`, `aw_used`, `sport_used`, … — and analyze compares them value by value, like `ftp_used`. `sync` does NOT delete metrics: it re-lists a rolling 30-day window every run and cannot tell an edit from a no-op, so invalidating there wiped a month of metrics per sync), **rating change** (rate! deletes metrics). Any new metric
  input must join this story — `ftp_used`/`threshold_pace_used`/`zones_used`/`metrics_rev`/the `*_used`
  input columns are all compared in `compute_missing_metrics!`'s WHERE; only the
  stream-arrival and rating paths DELETE the row. An activity edit does NOT delete:
  `sync` cannot tell an edit from a no-op, so analyze detects it by comparison.
  **Bump the `metrics_rev` constant whenever Metrics math changes** — config
  provenance can't see algorithm changes. Every metrics row also records WHICH
  ladder rung scored it (`load_model`).
- Schema changes: bump `schema_version` (in `Db.roc`, alongside `run_migrations!`) and
  add the migration there; `ensure_schema!` (via open_db!) applies it on next command.
  (Constant locations: `schema_version` → Db.roc · `metrics_rev` → Analyze.roc ·
  `json_schema_version` → Output.roc · release `version` → main.roc.)
  **Pre-1.0 the schema is NOT a stable contract** — break it freely (retype columns,
  DROP+recreate the mirror/computed tables, or reset the db) when that's simpler than
  a careful migration. Don't harden migrations against versions no real db is on. The
  ONLY hard rule: never silently destroy judgment-tier data (`ratings`,
  `planned_sessions`, `config`/tokens) — it can't be re-derived. See ADR §6.
- Training weeks are **Monday–Sunday**.
- Human output philosophy: numbers in tables, meaning in legends, conclusion in a
  verdict line. No graphs — that experiment ran and failed; don't reintroduce.

## Repo & CI

`github.com/eschizoid/stride` (**public**). Remote is SSH — the gh OAuth token lacks
workflow scope for pushing workflow files. Four workflows: `build.yml` (check + pure
tests on linux/macOS/Windows, then build + e2e on macOS), `release-please.yml`
(automated releases, below), `manual-release.yml` (dispatch-only re-cut), and
`verify-arm64.yml` (dispatch-only linux-arm64 re-check).

- **Normal git history on `main`** — commit normally, push fast-forward; never amend
  or force-push a shared branch.
- **`just command-claims` holds the docs to the command table.**
  - Every `stride <cmd>` a doc NAMES is a claim that the binary HAS it; the oracle is
    `stride --json --help`, the same machine-readable table `just schema-check` uses.
    One direction only — a doc naming a nonexistent command fails; a command no doc
    mentions is a coverage question and is deliberately not checked.
  - A doc may legitimately name a command the binary lacks — "`stride backfill` was retired" is TRUE, and stripping its backticks to satisfy the linter would degrade the doc to serve the tool; this line opts out that way. <!-- command-claims: quoting -->
    The opt-out is an HTML-comment marker (spelled `command-claims:
    quoting`); the marker count is pinned in the script, so adding one is
    deliberate — and this bullet's own marker keeps the opt-out exercised rather
    than sitting untested behind a pin of zero.
- **`just skill-shapes` holds SKILL.md's payload shapes to the schemas.**
  `command-claims` resolves command NAMES; this resolves payload KEYS — the failure
  it guards is silent in the direction that matters: an agent given an undocumented
  field does not error, it simply never uses it.
  - Membership lives in `tools/skill-shapes.pins`, checked in — NEVER measured from
    the document, because a measured denominator turns the check off under exactly
    the drift it should catch. Refreshing the pin (`sh tools/skill-shapes.sh
    --refresh`) is the moment someone decides whether a new field belongs in
    SKILL.md.
  - Two directions, prose included. Schema→doc checks each required field of a
    `doc`-pinned object against every line documenting that command, with the
    invocation cell stripped so an argument placeholder like `[date]` cannot satisfy
    a payload field. Doc→schema checks every `{...}` literal's key set for being a
    SUBSET of some single schema object — attribution-free on purpose, since
    attributing a literal to whichever command its line mentions mis-files prose,
    and reading table rows only goes blind to every literal in prose (`config
    unset`'s `{key, removed}` has no table row at all).
  - Known gap: `analyze`'s literal spans a paragraph break, so the line-scoped
    extractor never runs its doc side — the object stays pinned, so a schema change
    still fails the gate.
  - Both counts (`EXPECT_PINNED`, `EXPECT_LITERALS`) are asserted exactly, not as
    floors: under a floor, a reworded row or deleted schema stops matching while the
    gate prints the same clean line a healthy tree prints.

## Releases (release-please)

Releases are automated by **release-please**, driven by **Conventional Commit** messages
on `main`. You never tag or edit the version by hand.

- **Version lives in `src/main.roc`** (`version = "stride X.Y.Z" # x-release-please-version`)
  and `.release-please-manifest.json`. release-please bumps both — **do not hand-edit the
  version for a release.**
- **Commit types → version bump** (config sets `bump-minor-pre-major` only — the
  bump-patch-for-minor-pre-major flag was deliberately REMOVED so features bump
  the minor pre-1.0):
  - `feat: …` → **minor** (0.1.0 → 0.2.0)
  - `fix: …` → **patch** (0.1.0 → 0.1.1)
  - `feat!: …` / `BREAKING CHANGE:` footer → **minor while on 0.x** (breaking does NOT
    auto-jump to 1.0.0 — that's deliberate). After 1.0.0 it bumps major.
  - `chore:` / `docs:` / `ci:` / `refactor:` / `test:` / `style:` → **no release**
  - Force an exact version (e.g. deliberately cutting 1.0.0) with a `Release-As: 1.0.0`
    footer in any commit body.
- **Commit subjects become the release notes** — write them as user-facing changelog
  lines, not internal shorthand. Notes are generated from commits, not from CHANGELOG prose.
- **The flow:** commit conventionally → release-please keeps an open "release PR" with the
  pending version + notes → **merge that PR** → it tags `vX.Y.Z`, creates the GitHub
  release, and the build/upload jobs attach the platform binaries. CLI targets: linux-x86_64,
  linux-arm64 (needs the explicit `roc_target: arm64musl` the workflow passes — left
  to itself the build detects arm64v1musl and fails; dispatch-only re-check in
  `verify-arm64.yml`), macOS arm64 + Intel, and windows-x86_64 (basic-cli ships an
  x64win host; `OsStr.display` decodes the `WindowsU16s` argv arm). Desktop APP
  artifacts ship beside them: macOS `.app` zips (both arches), a linux tarball and a
  windows zip, each carrying the viz binary, brand fonts and a launcher that seeds
  `~/.stride/fonts`. `fail-fast: false` plus an `always()` upload means one bad
  target still lets the others attach.
- **Never cut a release without Mariano's explicit go-ahead** — landing feats on main is
  fine, but merging the release PR / tagging waits for a clear yes.
- **GOTCHA — never write `feat:`/`fix:` as literal text in a commit _body_.** release-please
  scans the body and invents a phantom feature from it.
  Keep conventional tokens only in the subject line; reword prose (e.g. "conventional commit
  prefixes", not "feat:/fix:").
- release-please needs the repo setting *Actions may create and approve PRs* (enabled via
  `gh api -X PUT repos/eschizoid/stride/actions/permissions/workflow -F can_approve_pull_request_reviews=true`).
- Release notes carry release-please's default commit/compare **URL links** (a known
  tradeoff of the automation vs. the old hand-curated link-free notes).
