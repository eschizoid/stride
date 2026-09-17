# 0014. structured prescription targets: optional numbers beside the prose, never instead of it

Accepted 2026-08-29 (#198). Amends ADR 0008 Decision 1 by its own escape hatch.

## Context

ADR 0008 rejected matching detected structure against prescriptions, and it stated its
premise plainly. The premise was that "prescriptions are free text, so structure-matching
means parsing prose, which is judgment, which belongs to the coach", and the ADR closed with
"If structured prescription targets ever ship, re-argue then." The present document is that
re-argument. Issue #96 made detected shape a first-class key on the actual side through
structure-keyed progress, while the plan side remained prose. Plan against actual therefore
stayed asymmetric, because the actual is `{reps, dur, watts}` and the plan is a sentence.

Issue #198 parked the idea against a real cost. A plan that must parse into
`{reps, duration, target}` cannot say "3×12 building to threshold, back off if the legs
aren't there", which is how coaching actually reads.

## Decision

1. The target is optional and additive, and the prose stays canonical. `week add` gains an
optional fifth argument, which is a strict literal of the form `<reps>x<mm:ss>@<watts>W`
such as `3x12:00@230W`. The literal is stored in three nullable judgment-tier columns
beside `detail` and is never parsed out of `detail`. A session without a target behaves
exactly as before, byte for byte, so the cost the park note named is zero. Flexible prose
prescribing is untouched, and a coach adds numbers only when the session genuinely has them.

2. Targets carry power only, for now. The detector's pace signal is m/s, and no pace target
literal is natural in m/s, because "4x3:00@2.98m/s" prescribes nothing a human recognizes.
A pace form ships when it has a literal a human would type, and not before. The column names are
signal-agnostic, namely `target_reps`, `target_dur_s` and `target_watts`, and the last of
them names its unit precisely so that a pace column can sit beside it later rather than
overload it.

3. Comparison is arithmetic, and arithmetic is state. ADR 0008's rejection premise was that
matching means parsing prose. With both sides structured, comparison is subtraction, so
`complete` on a targeted session reports the recorded target beside the detected shape of
the linked activity. The reported fields are `reps_delta` and `watts_pct`, each gated by a
`_known` flag per ADR 0009, because a session without power segments compares to nothing and
says so rather than inventing zeros. The comparison passes the ADR 0012 test, since every
field states what happened against what was recorded and none says what to do about it.
Field names stay measurements, so there is no `hit`, no `missed` and no `success`.

4. Some behaviour stays banned in both directions. Stride offers no match candidates,
because ADR 0008's rejection stands wherever a side is still prose, and suggesting which
activity fulfils which session is judgment. Stride has no auto-complete. Stride never runs
the target to plan direction, because ADR 0010 maps a plan to its consequences and never a
target to a plan, so stride never proposes a target, adjusts one or evaluates one. The coach
writes the target, and stride stores and reports it. The human render prints the comparison
as numbers in the existing table idiom with no verdict line, because "did they hit it" is
the coach's sentence to write.

5. The affected surfaces are listed here exhaustively. `week add` stores the target and
echoes it back, using `target_known` and impossible-zero magnitudes per ADR 0009. The
`open_sessions` block of `plan` carries the same four fields, so planning sees standing
targets, and the with-activity path of `complete` reports the comparison. Nothing else
changes, because `adherence_28d` still counts status only, `week`'s table is untouched, and
`relabel` edits labels rather than targets. A done session's target is part of the record,
and revising an open session's target means running `week add` again, which already revises
in place.

## Not doing

- Pace and HR targets wait until each has a literal a human would actually type.
- Interval by interval comparison, such as reporting that rep 3 was 12 W low, stays out,
  because the detector's medians are the honest resolution and per-rep target arithmetic
  implies a precision the band predicate does not have.
- Adherence score arithmetic from targets stays out. `completion_pct` counts sessions rather
  than watts, and combining the two would manufacture a number nobody defined.
- Editing targets on done sessions stays out. The target is what was asked, and the record
  keeps it.
