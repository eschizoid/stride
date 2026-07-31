# Stride second-pass execution plan (triaged 2026-07-31)

Source: `~/Downloads/stride-second-pass-execution-plan.md` (10 priorities).
This file is MY triage + sequencing, grounded in verification, not a rubber-stamp.
Rule: verify before asserting; don't fight settled constraints; don't over-promise.

## Verified findings (before any work)
- **P4 is a LIVE leak**: `config get strava_access_token` prints the token; db is
  `-rw-r--r--` in a world-readable dir. Not hardening — an active bug.
- P9: "no VO2max stimulus in 28 days" still in Render.roc:337 (absolutist).
- app.roc = 2367 lines. load_model persisted; load_confidence NOT. Cmd imported (chmod ok).

## LANDMINES — where the doc collides with reality (flag before executing)
1. **P1 query-modules (ActivityStore/TrainingStore/…)** fight TWO settled findings:
   monomorphic module params (decoders >2 cols can't move to modules with injected
   effects — TESTED, in CLAUDE.md) AND the SQL-next-to-decoder adjacency guard.
   → Command.roc (pure parsing) = SAFE and good. Query-modules = mostly BLOCKED; do
   NOT attempt the repository split. At most: group free-standing pure row-transforms.
2. **P2 IANA timezone**: basic-cli 0.20 has no tz database. Full IANA is likely not
   achievable on our pin. Realistic deliverable = honest fallback: keep offset, rename
   as fallback, add doctor warning, DON'T claim DST-safe. Investigate `Cmd` shelling to
   system `date`/`zdump` before promising more. Do NOT hand-roll a DST engine.
3. **P3 `generated_at` in the JSON envelope** breaks determinism — and the SAME doc
   wants golden fixtures. Contradiction. → Omit `generated_at` (or normalize it out of
   golden comparisons). The envelope itself is fine; the timestamp is the trap.
4. **P3 is a CONTRACT BREAK** to JSON we just stabilized + the shipped Claude skill.
   Gate behind `STRIDE_JSON_SCHEMA=1` first, flip default in a deliberate minor, update
   the skill in the same change. Don't run an indefinite dual contract.
5. **P5 schema change** must join the invalidation story (metrics_rev bump) and confidence
   rules must be deterministic + documented. SQLite can't rename columns cleanly on our
   setup — ADD new columns, migrate values, keep old until a later cut.

## TIER 0 — ✅ DONE (8251626): live security bug P4
Small, concrete, high-value, low-risk. One focused PR.
- `config get` / any JSON: refuse or redact secret keys (strava_access_token,
  strava_refresh_token, strava_client_secret). Non-secret keys unchanged.
- chmod `~/.stride` → 0700, `db.sqlite` (+ -wal/-shm/-journal) → 0600 on init/open,
  via Cmd (only where the platform can; don't claim enforcement it can't guarantee).
- Audit every error/HTTP-diagnostic path: never print tokens, secrets, Authorization
  headers, or full token request bodies. (sync_ftp/token-refresh/auth paths.)
- doctor: warn on world-readable db.
- e2e: assert `config get <secret>` is redacted; assert no token in a forced error.
- README: state plainly the db holds Strava credentials.

## PHASE 1 — safety + contracts (P7✅4cfe3f4, P6✅48a2ba9; P3 remaining)
- **P6 migration fixtures** (db is the product): `tests/fixtures/db/vN.sql` for each
  released schema; e2e boots each with the current binary, asserts migrate + data
  preserved + recompute + idempotent re-run. Highest structural-safety ROI.
- **P7 e2e → tests/e2e.sh** (already parked): extract the ~400-line harness to
  tests/e2e.sh + helpers.sh; justfile calls it; shellcheck. Mechanical, behavior-identical.
- **P3 versioned JSON** (with landmines 3+4): envelope `{schema_version, command, data,
  warnings}` / `{..., error:{code,message}}`, NO generated_at. Behind STRIDE_JSON_SCHEMA=1,
  skill updated, golden fixtures per command + error. Human output untouched.

## PHASE 2 — correctness + terminology
- ✅ (3a6cd62) P9 wording: "no VO2max stimulus" → "no Z5 heart-rate time in the window"
  (honest: absent HR / power-based VO2 / short intervals). Do this early, it's tiny.
- **P5 training_load vs power_tss**: ADD training_load + load_confidence(+version)
  columns (schema v7, metrics_rev bump), migrate tss→training_load, stop labelling
  mixed-model values "TSS". Confidence: high=power+valid FTP, medium=HR-coverage or
  sRPE, low=relative_effort, none=unscored — deterministic + documented. Sweep displays.
- **P2 timezone**: INVESTIGATE first (Cmd→system tz?). Deliver the honest fallback if
  full IANA isn't reachable on alpha4. Precedence: timezone > utc_offset_minutes > UTC.
- **P8 doctor expansion**: fold in tz-awareness, perms (from Tier 0), confidence
  distribution (needs P5), config freshness, PRAGMA integrity_check. Every warning =
  what/why/fix. This is the aggregation point — do AFTER P2/P4/P5 land.

## PHASE 3 — structure
- **P1 Command.roc**: typed `Command` union + `parse : List Str -> Result Command Usage`,
  pure, unit-tested for every form + malformed arity. main! becomes a thin dispatch.
  Real maintainability win; safe (pure). DO.
- **P1 Config.roc**: typed ConfigKey enum (pairs with Tier 0 secret-key handling). Small.
- **P1 query modules**: SKIP per landmine 1 — don't fight monomorphism/adjacency.
- **P10 README sweep**: last — reflect training_load, provenance/confidence, tz,
  credential disclosure, versioned JSON. Keep "engine does the math, LLM does judgment".

## Sequencing (risk-first)
Tier 0 (P4) → P9 (tiny) → P7 → P6 → P3 → P5 → P2(investigate) → P8 → P1(Command+Config) → P10.
Each step its own reviewable, behavior-preserving commit + green suite. No big-bang rewrite.

## Explicitly NOT doing (doc's non-goals + ours)
TUI, MCP, cloud/web, generic-every-sport, injury/medical claims, replacing SQLite,
moving math into the LLM. Query-repository split (blocked). Compiler migration (blocked
on roc-json — separate PLAN.md note).
