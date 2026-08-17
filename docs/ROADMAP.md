# Roadmap — what stride is for, and what it will never be

Directional, not a promise; re-argue freely. Settled architecture stays in `docs/adr/` —
nothing here overrides an ADR.

**This file deliberately tracks no status.** It held a priority ledger once and could not
keep it: three refreshes in four days, each obsolete within seventy-two hours, until its
most prominent section was thirteen closed issues presented as "P0, before anything else".
That is a job the issue tracker does automatically. What lives here is only the part
nothing else owns — why the project exists, where its boundaries are, and what is still
being argued.

## The thesis

Stride's edge is already decided: **deterministic, local-first, honest about provenance,
judgment kept out of the engine**. TrainingPeaks hides its math. intervals.icu is
cloud-locked. Golden Cheetah deserves the fairest comparison — it is open source and does
show its work — but it is a dense desktop GUI built for a human to click through, not an
engine a coach (human or LLM) can script against.

The position nobody owns is **the engine that shows its work *to a machine***: every
number traceable to its inputs, recomputable from raw streams, and emitted as versioned
JSON a tool can consume.

Every feature does one of two things: widens what the engine can honestly measure, or
widens who can feed it data. None adds judgment to the engine — reasoning about the
numbers stays with the coach (ADR 0012).

That rule has teeth, and it has caught shipped code. The `form` verdict line once ended in
advice ("favor easy work") derived from a single scalar. It repeated for 17 straight days,
and it was **wrong** — it told an athlete to go easy through a fortnight that was 81% easy
with no hard session in nine days, because TSB alone cannot see intensity distribution
(#123, fixed in #127). Worth re-reading this section against anything that emits words
rather than numbers.

## The ingestion boundary is the filesystem

Where a device uploads its data — Garmin Connect, Wahoo, Peloton's servers — is between
the athlete and their vendor, not stride's business. Stride reads files the athlete puts on
disk: bulk export, USB (Garmin devices mount as a disk), email, anything. Strava stays as
the one grandfathered API because it exists and is an aggregator; no other vendor-cloud
integration ships, ever.

This is one sentence that deletes an entire category of scope.

## Explicitly not doing

- **Multi-athlete / coach views** — breaks the single-user local db that keeps everything
  else simple. An athlete's coach reads their JSON instead. (Friends each running their own
  copy, owning their own data, is a different thing and is in scope — it is why pace-domain
  work exists at all, since the friends run.)
- **Graphs** — that experiment ran and failed; tables, legends, verdict lines and the LLM
  coach are the visualization layer.
- **ML predictions** — the engine's identity is deterministic and explainable. Nothing
  ships that cannot be recomputed by hand from the stored inputs.
- **Social features** — Strava exists.
- **Vendor-cloud integrations** (Garmin Connect, Wahoo, Peloton APIs, …) — see the
  ingestion boundary above.
- **Raw device-format parsing** (FIT/TCX/GPX) — Strava is the parser; stride ingests its
  two outputs (ADR 0006).

ADR 0000 §10 carries a second, overlapping list (TUI, MCP server, cloud sync, medical
claims, replacing SQLite, moving math into the LLM). Neither is a superset of the other.
Merging them into one home is worth doing; until then, read both.

## Open arguments

Recorded so they get fought on purpose rather than settled by default:

1. **Wellness homework.** Does anyone in the circle wear a watch overnight? This gates
   resting-HR/HRV ingestion (#137) entirely, and it is a question about people, not code.
2. **Structured prescription targets.** Parked, not planned. Would make
   detection-to-prescription matching honest arithmetic, at the cost of rigid prescribing.
   Re-argue only if free-text reconciliation actually starts failing in practice.
3. **How much model to publish when the model does not fit.** The CP work (#190) surfaced
   this: the maintainer's fitted W′ is physiologically implausible because he never does
   short maximal efforts, so the model is arithmetically correct and descriptively wrong.
   Stride now ships the refutation beside the number (`fit_r2`, `contradicts_model`).
   Whether that is enough, or whether a sufficiently bad fit should decline to answer, is
   unsettled.

*(Settled and removed: world-class vs world-scale — both, interleaved, world-class
foreground. FIT dedupe semantics — moot, the FIT track was retired.)*

## Where the truth lives

This file is none of these things and should not grow into them:

| Question | Answer lives in |
|---|---|
| What shipped? | `CHANGELOG.md` and `stride --help` |
| What is next? | GitHub issues |
| Why is it built that way? | `docs/adr/` |
| How do I build and test it? | `AGENTS.md` |
| What is the machine contract? | `schemas/v2/*.json` |
| What does the compiler need? | the `nightly-tag` pins in `.github/workflows/`, and `docs/roc-new-compiler-notes.md` |
