# 1.0 execution order

**Why this file exists, given AGENTS.md says not to have one.** The last `.claude/PLAN.md`
rotted because it restated work that lived in issues, so the copies drifted and nothing
read either. This one holds no work — only the ORDER and the reasons for it, which is the
one thing GitHub issues cannot carry. Every item is a pointer. If you find yourself
describing what a ticket contains here, the file has started rotting again; delete it.

Delete this file when the 1.0 phases below are merged. It has no other purpose.

## The two constraints that set the order

1. **#217 must land before anything changes a payload shape.** The envelope docs say
   adding a key is non-breaking; every schema carries `additionalKeys: false`, so a
   consumer validating against one BREAKS on an added key. #221 adds keys; #219 RETYPES
   `commands` from strings to records, which under §9c's own rule is the heavier change of
   the two. Deciding the policy after shipping either is backwards.
2. **File contention.** #216 and #217 both edit `docs/adr/0000-architecture.md`. #218,
   #219 and #138 all touch `src/app.roc`, and #219 and #138 both touch `src/Command.roc`.
   That is why the code phases are sequential rather than parallel PRs.

## Phases

| phase | tickets | state |
|---|---|---|
| 1 — decide the contract (docs) | #216 + #217, ONE PR (same file) | |
| 2 — close the contract holes | #218, then #221 | |
| 3 — the one with real design | #219 | |
| 4 — prove the loop | #220 | |

Feature track, independent of the above and startable any time: **#138**, then **#189**
(which its own issue says shares #138's projection machinery).

## Standing rules for this work

- Every ticket gets `/fleet-merge`: agent review, fix what survives, merge only on
  Mariano's word for that specific PR.
- Copilot has attached to nothing for the whole of this work — `requested_reviewers: 0,
  reviews: 0` on every POST — so the agent round is the review, not a fallback.
- #219 must derive its description from the parser and `schemas/v2/`. A hand-maintained
  table is what #205 spent eight review rounds cleaning up.
- #220 is only worth landing if it is mutation-proved: break one leg, watch it fail while
  the per-command tests stay green.

## Parked — do not re-plan these each session

| | blocked on |
|---|---|
| #188 critical speed / D′ | no mean-max SPEED curve exists — the power path stores `best_5s_w`…`best_3600s_w` at analyze time, the pace equivalent has no columns and no producer. NOT "one Run in the database": that argument is retracted on the issue itself, because a per-athlete measurement cannot rank a feature aimed at the circle |
| #137 wellness inputs | its homework question — does anyone in the circle sleep with a watch? |
| #198 structured prescription | parked by design; reopening is a deliberate argument |
| #27 `roc format` | upstream fmt bug |
