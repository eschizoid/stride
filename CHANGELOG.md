# Changelog

All notable changes to stride are documented here. The release workflow publishes
the section matching each version tag as that release's notes, so keep the newest
version at the top in the format below (`## [X.Y.Z] - YYYY-MM-DD`).

## [0.2.0](https://github.com/eschizoid/stride/compare/v0.1.0...v0.2.0) (2026-07-30)


### ⚠ BREAKING CHANGES

* consistent JSON contract across commands
* progress is date-anchored; auto-named rides compare similar distances only

### Features

* add output (kJ) metric to top for total work ranking ([b432178](https://github.com/eschizoid/stride/commit/b4321789dba6b7991e69c572fb650c2d0681d02b))
* add progress command to track improvement on a repeated workout ([55974c4](https://github.com/eschizoid/stride/commit/55974c44cdb520687fa802db34bb0d378693a8a6))
* add pz command showing power-zone watt ranges from FTP ([b42123f](https://github.com/eschizoid/stride/commit/b42123fc005b70de990de6442938cb5d80777526))
* add top command to rank activities by a metric ([25b0f9e](https://github.com/eschizoid/stride/commit/25b0f9e9478c723771f77f32846eab32cacc5b1a))
* asked-date marker uses a solid triangle ([df787e1](https://github.com/eschizoid/stride/commit/df787e150bd61b7400d6fca9d2d6159e4d9d63c7))
* auth opens the authorize URL in the browser automatically ([c266b69](https://github.com/eschizoid/stride/commit/c266b694c70ccaa0a2b43f54a239d1a4451e7fa3))
* bare progress defaults to the latest workout; honest message for EF-less days ([9e4d2e2](https://github.com/eschizoid/stride/commit/9e4d2e2abd351f7594ab81771624a482ffc13c27))
* consistent full-name table headers with acronyms across commands ([a8c929e](https://github.com/eschizoid/stride/commit/a8c929e3596db0b32b15c7fb17f73cc79607bf4c))
* consistent JSON contract across commands ([ecd2e38](https://github.com/eschizoid/stride/commit/ecd2e3851d45670993557215d7922b51c5962dde))
* ef bar column in progress (ASCII, scaled to best; &lt; marks asked date) ([b7964c3](https://github.com/eschizoid/stride/commit/b7964c327c949aee6d84844d8193d6e9b2bed92c))
* progress accepts a date, resolving that day's workout(s) ([cf8020d](https://github.com/eschizoid/stride/commit/cf8020da0e317610f7ff034b889a351bf236750d))
* progress bars scale worst-to-best, gap rows for 90-day breaks, explicit asked marker ([0ce1ba7](https://github.com/eschizoid/stride/commit/0ce1ba77f85ebf06f00b9a5a66eea02131a2f641))
* progress is date-anchored; auto-named rides compare similar distances only ([f6ac8b9](https://github.com/eschizoid/stride/commit/f6ac8b9d8d6cc1d5866fe85debc08d189b6afad1))
* progress shows last-vs-best EF gap line ([91ba735](https://github.com/eschizoid/stride/commit/91ba7354a679ac3f9bc40a1beaf492ea70561295))
* push FTP to Strava when set locally, so they stay in sync ([0b10eda](https://github.com/eschizoid/stride/commit/0b10eda305ee7ec0571bbe710525fa5411fe3e53))
* solid block ef bar (constant-height, single-width glyph) ([5a3efe5](https://github.com/eschizoid/stride/commit/5a3efe5714986bf16921346c31e221706363b12e))


### Bug Fixes

* auth also requests profile:read_all so athlete FTP stays readable ([603626e](https://github.com/eschizoid/stride/commit/603626eb8116cfc780aaeb7823710d3053e15e89))
* compute form (TSB) same-day so it reflects current fatigue ([ae97520](https://github.com/eschizoid/stride/commit/ae975203526a3f4e935df1ba2c48989b8fe03636))
* honest degraded messages in best-effort paths ([93ba287](https://github.com/eschizoid/stride/commit/93ba2874a8e3bbadaec252000c4729864feed477))
* metrics recompute when the algorithm changes; single stream-response policy ([4dc45bc](https://github.com/eschizoid/stride/commit/4dc45bcad107edcf640b9d7d1273146695ae6960))
* progress verdict includes the average EF ([668ce91](https://github.com/eschizoid/stride/commit/668ce91597da13c21358b44bc932a0e39fe0d720))
* re-auth reuses stored client credentials instead of requiring env vars ([82451b5](https://github.com/eschizoid/stride/commit/82451b53befdfed1200c7c9f857fa08ec325073d))
* request profile:write scope in auth so FTP sync to Strava works for new tokens ([c79bd47](https://github.com/eschizoid/stride/commit/c79bd47d2896b8f9be238d2bb311fe28d89b92fe))
* show per-activity distances with one decimal ([50986fc](https://github.com/eschizoid/stride/commit/50986fcdcec76a48120e809afd87994e749ad3fb))

## [0.1.0] - 2026-07-28

First release — a local-first, multi-sport training engine written in Roc.

### Added

- **Native Strava sync** — OAuth paste flow; credentials live in your local db
  after `auth`, no env vars afterward. `sync` re-pulls a rolling 30-day window so
  edits on Strava self-heal.
- **`backfill`** — hands-off, resumable, rate-limit-aware full stream import.
  Pulls the whole activity list plus every activity's raw streams, pacing itself
  against Strava's read limits (~1000/day), so a multi-thousand-activity history
  imports cleanly across a few runs.
- **Deterministic metrics**, all pure and unit-tested — no number comes from a
  model: TSS ladder (stream NP → weighted watts → avg watts → hrTSS →
  relative-effort), normalized power, intensity factor, CTL/ATL/TSB (fitness /
  fatigue / form) through today, HR time-in-zone, and FTP calibration.
- **Reading commands** — `summary`, `week`, `activities`, `activity <id>`,
  `load`, `stats`, `prescriptions`: human tables in a terminal, JSON for an LLM
  coach (auto-detected, or `STRIDE_FORMAT=json`).
- **Coaching log** — `prescribe` / `complete` / `skip` for the plan → do →
  reconcile loop, with guards against double-booked dates and unknown ids.
- **Local-first by construction** — one SQLite file you own; self-healing
  recomputation (FTP change, HR-zone change, stream arrival, and Strava edits
  invalidate exactly the affected metrics); the schema self-migrates on any command.
- **Coaching log reads like a calendar** — `prescriptions` shows the day of week
  (Mon–Sun) alongside each session, including explicit rest days.
- **Prebuilt binaries** — Linux x86_64/arm64, macOS Apple Silicon, macOS Intel.
