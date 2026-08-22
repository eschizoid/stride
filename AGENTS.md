# Agent instructions for stride

> **One file, every agent.** `AGENTS.md` is the canonical instruction file — the
> cross-tool convention read by Codex and friends. Claude Code users: point your local
> config at it once with `ln -s ../AGENTS.md .claude/CLAUDE.md` (untracked on purpose;
> this line is the documentation for it). Edit this file, never a symlink.

Local-first, deterministic training analytics engine in **Roc** (Strava is one
ingestion layer). The engine computes metrics deterministically; an LLM coach (you,
via the skill in `.claude/skills/stride/`) consumes the JSON and writes the plan
back. **Never do training math yourself — read stride's numbers, add judgment.**

Settled architecture + rationale live in `docs/adr/0000-architecture.md` (committed) —
read it before proposing architectural changes; don't relitigate what it settles.
Open work lives in GitHub issues, workflow lessons in auto-memory, shipped work in git
history. No scratch plan file DESCRIBES work: `.claude/PLAN.md` was one, every section of
it rotted, and a watch-item it was tracking (ADR 0001's split trigger, #196) fired
unnoticed because nothing read it. A root `PLAN.md` holding only SEQUENCING and the
constraints behind it is allowed — that is the one thing issues cannot carry — but it must
be pointers, it must be scanned by `just issue-claims` like any other doc, and it must
delete itself when the sequence is done. Restating what a ticket contains, beyond the one fact that creates a sequencing constraint, is how the last
one started rotting.

## Build & test

```bash
just test      # THE entry point: pure expects → fresh build → e2e (same as CI)
just build     # the binary, --opt=dev (see below); STRIDE_LINKER= is an escape hatch
just install   # build + symlink to ~/.local/bin/stride
```

- **Always `just test` in one command, read the result, commit in a separate command.**
  Never chain `test && commit` — a mid-chain failure has shipped red commits before.
- A failed build leaves a stale binary that e2e would happily "pass" against; `just
  test` orders steps to prevent this. Don't run `just e2e` after a failed build.
- Toolchain: the new (Zig) compiler (`~/.local/roc-new/roc`, pinned by exact nightly
  tag in `.github/workflows/build.yml`) · basic-cli **0.22** · builtin JSON (roc-json
  dropped). The alpha4 / 0.20 / roc-json 0.13 pin is RETIRED. `~/.local/bin/roc` is now a
  SYMLINK to `~/.local/roc-new/roc` (identical binary), which is why a bare `roc`
  in the justfile works; it is no longer the alpha4 trap this line used to warn
  about, but pin the explicit path in anything that must not depend on that link.
  `check`, `test`, and a full `roc build` all work (roc#10469 was fixed by roc#10531).
- **Build with `--opt=dev`.** This used to be a correctness requirement: `--opt=speed`
  miscompiled the codebase (#32's intermittent SIGABRT, plus a silently dropped progress
  column). Both are FIXED as of the `nightly-2026-08-17` pin — measured 0 SIGABRT in 1400
  runs where the old pin gave 40, and byte-identical output across 11 commands. It stays
  the default because a speed build takes ~2 minutes against ~14 seconds, which is the
  dev loop, not because the binary is wrong. `just build`, CI, and the release workflow
  all pin it.
- **New-compiler flag gotcha: `=`, not a space.** `--output=x`, `--main=x`, `--opt=dev`.
  A space-separated `--output x` fails with a confusing error (it broke a release once).

## Code conventions

- **Effects live in modules, by concern** — the new compiler lifted the alpha4
  monomorphic-module-param wall, so I/O is split out of app.roc: `Db.roc` (SQLite +
  schema/migrations), `Strava.roc` (OAuth + sync HTTP), `Analyze/Plan/Import` and the
  report family — `Report.roc` (summary/load/compare + the helpers the others share),
  `ReportSessions.roc`, `ReportHealth.roc`, `ReportSeason.roc` — each owning its commands;
  `app.roc` is a thin argv → dispatch shell. The report modules depend INWARD on
  `Report.roc` and it imports none of them (#196, ADR 0001). (History: under alpha4
  a decoder wider than 2 columns failed to type-check once effects were injected, so
  everything effectful had to sit in app.roc — that wall is gone.)
  Pure logic goes in `Metrics.roc` / `Sports.roc` (sport vocabulary: the four sport-varying policies — family filters, load-model class, pace routing, the pace-TSS exponent — gathered in one module rather than scattered through others; only the family filter is a table of rows, the class reads a list literal inside its own function, and the last two are name-substring predicates) / `Render.roc` / `Command.roc` (argv → typed
  `Command` union, `parse` is pure + unit-tested; `main!` is thin parse-then-dispatch)
  / `Config.roc` (`is_secret` secret-key policy) / `Csv.roc` / `Streams.roc` /
  `Backfill.roc`, with `expect` tests (`Schema.roc` is pure DDL and carries none). When adding logic: pure
  function + expects first, thin effectful skin. Add new pure modules to the
  `just test` recipe so their expects run.
- **Query-command output goes through `out!`** (payload + render fn): JSON is wrapped
  in the versioned envelope by `emit_ok!`/`emit_err!` (`{schema_version, data}` /
  `{schema_version, error:{code,message}}`), humans get a pure `Render.<cmd>_screen`
  (or inline closure). A payload field you ADD must also be added to
  `schemas/v2/<command>.json` — `additionalKeys: false` means an undeclared key
  fails validation, which is the point. Say CI only where CI validates that
  payload — ADR §9c enumerates which pass covers which command, and it is not all
  of them. Do NOT reach for
  the compiler as a substitute where the validator is absent: the closed record on
  the screen function pins payload↔SCREEN, so widening both ships a green build
  with the schema stale. Different invariant (`just schema-check` runs the same
  validator against your own database; `tools/schema-lint.jq` keeps schemas
  inside the subset `tools/validate.jq` actually reads — `title` included, since the
  validator uses it as the violation path's prefix — plus `description` for humans).
  Platform failures are converted to envelopes at ONE boundary (`run_command!`
  in app.roc) rather than at each call site, so a caller never meets a raw
  runtime banner; a new failure shape means a new arm there, not a new habit.
  Errors are in-band on stdout AND exit 1 (#163: the
  envelope is the payload, the status is the signal; a bare invocation is not a
  failure and exits 0 — humans get the help screen, machines get the command list —
  and an unknown command is an error). New commands are born on this
  pattern; older ones migrate as touched.
- `tests/e2e.roc` is ONE binary in FOUR roles, picked by `E2E_MODE`: the offline suite
  (default, no mode set), a mock Strava server (`mock`), and three drivers that run
  against it — `sync` (real sync + token refresh), `backfill` (the undecodable-body skip
  path), and `stops` (the `budget_reached` / `rate_limited` outcomes). `just e2e-sync`
  starts three mock instances on three ports (`mock_port`, `bad_stream_port`,
  `rate_limit_port`) and runs all three drivers; the mock's behaviour is varied by
  `E2E_BAD_STREAM` / `E2E_RATE_LIMIT`. `STRIDE_API_BASE` points stride at the mock, and
  `STRIDE_READS_PER_RUN` / `STRIDE_WINDOW_SLEEP_MS` / `STRIDE_READS_PER_WINDOW` /
  `STRIDE_MAX_429` shrink the rate-limit pacing so terminal arms that cost 940 reads or
  two 15-minute sleeps are reachable in milliseconds. Same species of seam as
  `STRIDE_API_BASE`; humans never set any of them. They can only LOWER a limit — an
  override able to RAISE one would let a typo or a copied command line hammer Strava and
  get the athlete's own API app suspended, and lowering is all a test needs. This recipe DOES run in CI — it needs
  no network and no credential (loopback mocks, a fake token row in a sandboxed HOME).
  It runs single-shot — the 5× retry that absorbed bug C's ~50% flake was
  deleted when the bug was fixed; a new flake here deserves a new investigation, not
  absorption. Standing caveat that OUTLIVES bug C: every string in the mock fixture is
  short enough to live inline in a RocStr, so this suite is structurally blind to
  heap-string bugs — a change to the sync decode/bind path must be run against real
  Strava data before it is called working. That mistake has shipped once.
- **Effectful `expect`s can't run under the test runner** — so `roc test` covers the pure
  modules only, and the e2e suite is a real Roc app (`tests/e2e.roc`, sandboxed HOME, no
  network) driven by `just e2e`. **Verify features with Roc expects + that harness, not
  throwaway awk/shell.** No python anywhere in this project.
- **SQL queries stay next to their row decoders** in whichever module owns the query
  (`Db.roc`, `Report.roc`, …) — the compiler can't check `SELECT ... AS x` aliases against
  `Sqlite.i64("x")` decoders; adjacency is the guard. Only decoder-free SQL (DDL) lives
  in Schema.roc.
- Table padding is display-width (code points), not bytes — keep emitted glyphs
  monospace-single-width; no varying-height unicode blocks (they render as mush).
- In bash test code: `grep -q` + `pipefail` = SIGPIPE trap; capture output first,
  then grep the variable.
- **Never test against the live `~/.stride/db.sqlite`** — snapshot it first
  (`sqlite3 ~/.stride/db.sqlite ".backup /tmp/x/.stride/db.sqlite"`) and run with an
  explicit `HOME`. A stray `stride init` against the real HOME has happened.
- **e2e id assertions are positional.** Inserting a `planned_sessions` row mid-scenario
  shifts the auto-increment and breaks later fixed-id checks — find them with
  `grep -nE '\["(complete|skip)", "[0-9]' tests/e2e.roc` rather than trusting a count. Add new
  fixtures at the END of a scenario, and delete what you insert.
- **A bare `True`/`False` serializes as the STRING `"True"`** in an encode-only payload.
  Annotate the field `: Bool` — the annotations scattered through `Report.roc` are there
  for this, not for documentation.
- **The compiler pin lives in FOUR workflow files** (`build`, `manual-release`,
  `release-please`, `verify-arm64`) — `grep -rln nightly-tag .github/workflows` before
  calling a bump done. It was documented as three, and that was already wrong.
- **Mermaid diagrams in the README**: `<br>` and commas only; other punctuation breaks
  the render.

## Idiomatic Roc (and the traps that actually bit us)

Language- and toolchain-level, as opposed to the stride-specific conventions above.
Every item here cost a debugging session at least once — they are not style opinions.

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
  for streams, which arrive sorted, so the worst case is the default case. Check first and
  sort only if needed — `Metrics.ascending_by_t` / `sorted_by_t`. This took a full analyze
  from 40.7s per 2700 samples to 0.41s, after the command looked like it had hung.
- **Never accumulate with `List.concat([x], acc)` inside a fold** — it copies the whole
  accumulator every step, so it is quadratic. Fold and prepend instead
  (`Render.reverse_list`). Harmless behind a `LIMIT`, fatal the moment the query is
  unbounded, which is how it shipped and then had to be fixed.

### Compiler behavior that reads like a bug

- **A compile-time-known condition is an ERROR, not a warning.** `if False { … }` fails
  with UNCONDITIONAL CONDITION, so you cannot stub a guard off that way to run a negative
  control. Delete the guard instead — that is the truer pre-fix state anyway.
- **Interpolating a compile-time-constant `""` can crash the backend** in `str_concat`
  (heap-corruption SIGABRT, same class as #32). Bind values rather than splicing optional
  fragments into SQL; a bound `:flag = 0/1` in the WHERE beats a conditional string.
- **`--opt=speed` used to miscompile this codebase** (#32, fixed on the 2026-08-17 pin);
  `--opt=dev` remains the default for build speed. Flags take `=`,
  not a space: `--output=x`, not `--output x`.

### Testing

- **Effectful `expect`s don't run under the test runner** — pure expects cover the pure
  modules; everything effectful goes through the e2e harness.
- **`roc test` caches.** A run can report `(cached)` while your new expects never
  executed. Prove they run by breaking one and watching the count drop.
- **`roc test`'s summary line can lie about the outcome.** When an expect fails to
  COMPILE, it prints `All (N) tests passed` with a silently smaller N and exits **1**. The
  exit code is the truth; the text is not. Read the code, and watch the count.
- **`roc test --main=src/app.roc <module>` runs every expect reachable from the app**, not
  just that module's — so the number it prints is not that file's test count.
- **The e2e harness aborts at the first failing `check!`.** A negative control that
  reverts two fixes at once only ever proves the first one. Revert one at a time.
- **Prove a test before trusting it**: revert the fix, watch it fail, restore. Several
  tests in this repo once passed against reverted code and proved nothing.

### Platform APIs

- **Verify against the docs before writing** (basic-cli 0.22 docs, or package source in
  `~/.cache/roc/packages/`) — alpha APIs drift; this habit has kept nearly every build at
  0-errors-first-try.
- **`Sqlite.query!` on a row that may not exist fails the command.** Use `query_many!`
  and match the empty list — this is how config loading must read any possibly-absent
  key. (Measured on basic-cli 0.21/0.22: it returns `Err(NoRowsReturned)`, so an unhandled `?`
  exits 1 rather than aborting. The SIGABRT this note used to claim was the alpha4 / 0.20
  behaviour; the rule is unchanged, only the failure mode is milder than advertised.)
- **SQLite type affinity bites**: INTEGER columns reject `Sqlite.f64` decoders — `CAST(…
  AS REAL)` in the SELECT when unsure.
- **Bug C (#105) is FIXED — bind values normally, and never splice text into SQL.**
  History, so nobody re-lives it: basic-cli 0.21's host DOUBLE-FREED every heap `Str`
  in a bindings list (basic-cli#471, root-caused 2026-08-14 with a 45-line reproducer
  under guard-malloc; fixed same-day in basic-cli#472, shipped in 0.22.0). For weeks it
  surfaced as unrelated errors far from the SQLite call — corrupt HTTP headers,
  `SqliteErr(TooBig)`, `UnexpectedType(Bytes)`, malloc aborts — because the second free
  corrupted whatever recycled the allocation. Inline/literal strings were immune, which
  made it intermittent and the short-fixture e2e mock structurally blind. For one day
  stride worked around it by splicing quoted literals; 0.22.0 made bindings safe and the
  splice was deleted. If a future platform bug ever forces that again, PR #130/#131 hold
  the complete playbook in both directions.
- **A crash at a host-boundary symbol names where corruption SURFACED, not where it was
  caused.** The backtrace accused `_hosted_http_send_request` for weeks while the cause
  was the bind path. Bisect by removing one ingredient at a time, and reach for
  guard-malloc early (`DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib` under lldb): it
  makes use-after-free deterministic and faults at the culprit instruction instead of the
  next victim. Disproven along the way, don't re-litigate: SQL statement shape (12
  shapes, ~36k statements, clean), `Json.parse` alone (clean from a file), and COPYING
  decoded strings before binding — copies are fresh heap strings, i.e. MORE double-free
  surface, which is why the copy "fix" crashed 12/12 and was reverted.
- **Verify anything touching sync decode/bind against real Strava data**, not `just test`.
  A change validated only on the mock shipped and broke daily sync for every real payload.

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
- HR samples outside 35–220 bpm are junk — filtered at analyze.
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
  `json_schema_version` → Output.roc · release `version` → app.roc.)
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

- **Normal git history — no more squash/force-push on `main`.** Commit normally, push
  fast-forward. (We used to amend one commit and force-push; that era is over. The one
  exception was a single force-push to fix the transition commit's message.)

## Releases (release-please)

Releases are automated by **release-please**, driven by **Conventional Commit** messages
on `main`. You never tag or edit the version by hand.

- **Version lives in `src/app.roc`** (`version = "stride X.Y.Z" # x-release-please-version`)
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
  release, and the build/upload jobs attach the platform binaries. **Windows IS built and
  shipped** (`stride-windows-x86_64`, since v0.3.0) — basic-cli ships an x64win host
  and `OsStr.display` decodes the `WindowsU16s` argv arm. Targets: linux-x86_64,
  macOS arm64 + Intel (macos-15-intel), windows-x86_64, **and linux-arm64** — that last
  one needs the explicit `roc_target: arm64musl` the release workflow passes (left to
  itself it detects arm64v1musl and fails), has a dispatch-only re-check in
  `verify-arm64.yml`, and has shipped continuously since v0.4.0 — it was also in
  v0.1.0, then absent from v0.2.0 and v0.3.0. `fail-fast: false` plus an `always()`
  upload means one bad target still lets the others attach.
- **Never cut a release without Mariano's explicit go-ahead** — landing feats on main is
  fine, but merging the release PR / tagging waits for a clear yes.
- **GOTCHA — never write `feat:`/`fix:` as literal text in a commit _body_.** release-please
  scans the body and invents a phantom feature from it (this caused a bogus 0.2.0 bump once).
  Keep conventional tokens only in the subject line; reword prose (e.g. "conventional commit
  prefixes", not "feat:/fix:").
- release-please needs the repo setting *Actions may create and approve PRs* (enabled via
  `gh api -X PUT repos/eschizoid/stride/actions/permissions/workflow -F can_approve_pull_request_reviews=true`).
- Release notes carry release-please's default commit/compare **URL links** (a known
  tradeoff of the automation vs. the old hand-curated link-free notes).
