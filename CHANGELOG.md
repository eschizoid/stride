# Changelog

All notable changes to stride are documented here. The release workflow publishes
the section matching each version tag as that release's notes, so keep the newest
version at the top in the format below (`## [X.Y.Z] - YYYY-MM-DD`).

## [0.2.0](https://github.com/eschizoid/stride/compare/v0.1.0...v0.2.0) (2026-07-29)


### Features

* /fix:/... commit messages drive automated version bumps. ([c00180e](https://github.com/eschizoid/stride/commit/c00180ec10dcc062e52b831be55734ff37dc63d5))

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
  recomputation (FTP change, stream arrival, and Strava edits invalidate exactly
  the affected metrics); the schema self-migrates on any command.
- **Prebuilt binaries** — Linux x86_64/arm64, macOS Apple Silicon, macOS Intel.
