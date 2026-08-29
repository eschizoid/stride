# 0014 — structured prescription targets: optional numbers beside the prose, never instead of it

Accepted 2026-08-29 (#198). Amends ADR 0008 Decision 1 by its own escape hatch.

## Context

ADR 0008 rejected matching detected structure against prescriptions with a stated premise:
"prescriptions are free text, so structure-matching means parsing prose, which is
judgment, which belongs to the coach" — and closed with "If structured prescription
targets ever ship, re-argue then." This is that re-argument. #96 (structure-keyed
progress) made detected shape a first-class key on the actual side; the plan side
remained prose, so plan-vs-actual stayed asymmetric: the actual is `{reps, dur, watts}`
and the plan is a sentence.

Issue #198 parked the idea against a real cost: a plan that MUST parse into
`{reps, duration, target}` cannot say "3×12 building to threshold, back off if the legs
aren't there", which is how coaching actually reads.

## Decision

**1. The target is optional, additive, and the prose stays canonical.** `week add`
gains an optional fifth argument — a strict literal `<reps>x<mm:ss>@<watts>W`
(`3x12:00@230W`) — stored in three nullable judgment-tier columns beside `detail`,
never parsed out of it. A session without a target behaves exactly as before, byte for
byte. The park note's cost is thereby zero: flexible prose prescribing is untouched,
and a coach adds numbers only when the session genuinely has them.

**2. Power only, for now.** The detector's pace signal is m/s, and no pace-target
literal is natural in m/s ("4x3:00@2.98m/s" prescribes nothing a human recognizes).
A pace form ships when it has a literal worth typing, not before. The columns are
signal-agnostic in name (`target_reps`, `target_dur_s`, `target_watts` — the last one
names its unit precisely so a pace column can sit beside it later rather than overload
it).

**3. Comparison is arithmetic, and arithmetic is state.** ADR 0008's rejection premise
was that matching means parsing prose. With BOTH sides structured, comparison is
subtraction: `complete` on a targeted session reports the recorded target beside the
detected shape of the linked activity — `reps_delta`, `watts_pct`, each gated by a
`_known` flag per ADR 0009 (a session without power segments compares to nothing, and
says so rather than inventing zeros). The 0012 test passes: every field states what
happened against what was recorded; none says what to do about it. Field names are
measurements — no `hit`, no `missed`, no `success`.

**4. What stays banned, in both directions.** No match CANDIDATES (0008's rejection
stands wherever a side is still prose — suggesting which activity fulfils which
session is judgment). No auto-complete. No target→plan direction (ADR 0010: stride
maps plan → consequences, never target → plan) — stride never proposes a target,
adjusts one, or evaluates one; the coach writes it, stride stores and reports it.
The human render prints the comparison as numbers in the existing table idiom, with
no verdict line — "did they hit it" is the coach's sentence to write.

**5. Surfaces, exhaustively.** `week add` stores and echoes (`target_known` +
impossible-zero magnitudes, ADR 0009); `plan`'s `open_sessions` carry the same four
fields so planning sees standing targets; `complete` (with-activity path) reports the
comparison. Nothing else changes — `adherence_28d` still counts status only, `week`'s
table is untouched, and `relabel` edits labels, not targets (a done session's target
is part of the record; revising an OPEN session's target is `week add` again, which
already revises in place).

## Not doing

- Pace/HR targets, until each has a literal a human would actually type.
- Interval-by-interval comparison (rep 3 was 12 W low) — the detector's medians are
  the honest resolution; per-rep target arithmetic implies a precision the band
  predicate does not have.
- Any adherence-score arithmetic from targets. `completion_pct` counts sessions, not
  watts; blending the two would manufacture a number nobody defined.
- Editing targets on done sessions. The target is what was asked; the record keeps it.
