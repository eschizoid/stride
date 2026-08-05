# ADR 0005 — FTP is period-accurate, not retroactive

Status: accepted · 2026-08-05 — recompute cost explicitly accepted by the athlete

Supersedes the scoring half of the derived-FTP decision recorded in
[ADR 0002](0002-power-based-intensity.md). Derivation itself is unchanged — FTP is still
computed from the athlete's own power history, never configured. What changes is *which*
derived value scores a given activity.

## Context

`Db.sport_ftp!` derives a sport's FTP as its best 20-minute power over the **last 60 days**
× 0.95. That single number then scores every activity of that sport, however old:

```
Ride    ftp_used = 243   2021-12-15 → 2026-08-03   (467 activities)
Rowing  ftp_used = 139   2024-01-28 → 2026-08-01   (200 activities)
```

Two consequences follow, and both are live in the production database today.

**Historical load is understated.** A December 2021 ride at NP 170 W scores IF 0.70 and
TSS 36.5 against FTP 243. Scored against the FTP actually in force then — nearer the 190
that was configured before the July recalibration — it was IF ≈ 0.89 and TSS ≈ 59. Old
seasons read roughly 40% easier than they were.

That is not a rounding problem, it is a definitional one. CTL, ATL and TSB model *training
stress relative to the fitness the athlete had at the time*. Dividing a 2021 effort by 2026
fitness produces a number that does not mean what the model says it means.

**History is not stable.** Because the window slides, a new 20-minute best changes the
derived FTP, which changes `ftp_used`, which invalidates and rescores **every** activity.
Last March's CTL moves because of what happened in August. A training log whose past
changes when the present does is not a log.

### The tradeoff we assumed, and do not actually have

One yardstick was assumed to buy cross-time comparability: the same standard for a 2021
ride and a 2026 ride. Inspection of `Metrics.lens_score` shows the comparison commands do
not use FTP at all:

| Lens | Score | Uses FTP? |
|---|---|---|
| `Ef` | `np_w / avg_hr` | no |
| `SpeedHr` | `(distance / time) / avg_hr` | no |
| `Rpe` | `rpe` | no |

`progress` is FTP-free. `power-curve` is raw watts. The only reader that would change
character is `top intensity`, which becomes "hardest relative to the fitness you had" —
arguably the more useful ranking. So the cost side of the ledger is close to empty.

## Decision

**`activity_metrics.ftp_used` stores the FTP in force when the activity happened.**

- Resolution: the sport's best 20-minute power over the 60 days **ending on that activity's
  date**, × 0.95 — the same derivation, a different window anchor.
- **Cold start:** activities older than the first 60 days of history have no prior window.
  Rather than score them at FTP 0 (which silently drops them to the HR rung), the earliest
  derivable FTP is carried backwards. Unknown early fitness is approximated by the earliest
  fitness actually measured, which is the least-wrong available answer and is honest about
  being an approximation.
- Recomputation compares `ftp_used` against the value for **that row's date**, not against
  one global current FTP.

The column name already implied this. It now means it.

## Consequences

- **CTL/ATL/TSB become physiologically meaningful across the whole history**, not just the
  recent window.
- **Past numbers stop moving.** A new PR changes future scoring only. This is the main win.
- **A change in current FTP no longer rescores old rows** — only rows whose own 60-day
  window is affected. That simplifies the invalidation story from ADR 0000 §5, but it *is*
  a change to a documented invariant, which is why this ADR exists.
- **The invalidation `WHERE` becomes a correlated per-row subquery** rather than a flat
  `CASE`. On a database of this size (hundreds to low thousands of rows) that is not a
  practical concern; it stays O(n).
- **Numbers will move on the first run after this lands** — older seasons rise, sometimes
  substantially. Current form barely shifts, because recent activities were already being
  scored against a recent window. Delivered via a `metrics_rev` bump, so the backfill is
  the ordinary recompute path with no migration.
- No schema change: `ftp_used` already exists and already carries per-row provenance.

## Alternatives considered

**Keep retroactive scoring, and document it.** Cheap and honest: `doctor` states that
historical load is scored at current FTP. Rejected as the primary answer because it leaves
the headline number in `summary` and `week` — the one both the athlete and the coach read
first — resting on a foundation that moves. Worth doing anyway if this ADR is not
implemented.

**Dual values: snapshot for load, current for display.** Rejected. Two FTPs per activity
means every reader has to know which one it is holding, and the audit already found one
column (`normalized_power`) quietly carrying two different quantities. Not repeating that.

**Freeze `ftp_used` at first computation.** Rejected: it makes the score depend on *when
you happened to run `analyze`*, which is worse than either option — non-deterministic
across users with identical data, and it breaks the "recompute from raw streams"
reproducibility promise in ADR 0000 §1.

## Not doing

- **Configured FTP override.** Letting `config set ftp_ride` win over derivation is a
  separate question (it would restore the lab-tested-FTP path and make the existing help
  text true). Independent of this decision; tracked separately.
- **Changing the derivation itself** — the 0.95 factor and the 60-day window stay as they
  are. This ADR moves the *anchor* of the window, nothing else.
- **Backfilling a "true" historical FTP from outside sources** (old Strava profile values,
  test results). The engine derives from data it holds; imported claims are not data.
