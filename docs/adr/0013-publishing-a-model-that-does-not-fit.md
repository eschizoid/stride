# ADR 0013 — Publishing a model that does not fit

Status: accepted · Decided 2026-08-19 · Closes #199

`tte` and `power-curve` publish a Critical Power fit. On this athlete's data the fit is
arithmetically correct and descriptively wrong, and the question #199 recorded is whether
a sufficiently bad fit should decline to answer at all.

## The measurement that prompted it

Re-derived against the live database on 2026-08-19, not quoted from the issue:

| quantity | value |
|---|---|
| `cp` | 254.24 W |
| `w_prime` | **6416 J** (a trained cyclist is normally 15000–25000) |
| `fit_r2` | 0.724 |
| `fit_points` | 3 |
| `tte 265` prediction | 596 s (9:56) |
| longest recorded effort at ≥265 W | 600 s, at 270.6 W |

So the model predicts 9:56 for a power the athlete has actually held for 10:00, and
`contradicts_model` correctly reports `true`.

## Decision

**No fit-quality refusal threshold is added.** `tte` keeps answering, with its caveats.

**The reason is not the one the issue expected.** #199 framed this as a values question —
refusing is an opinion about "good enough", which ADR 0012 keeps out of the engine. That
argument is sound but it is not the load-bearing one. The load-bearing one is that
**`fit_r2` cannot see this failure**, so gating on it would not work even if we wanted it
to.

The fit runs over exactly three points, hardcoded at 300, 600 and 1200 seconds
(`Report.roc`, `cp_fit_as_of!`). In the `P = CP + W'/t` form those points sit at
`1/t` of 0.00333, 0.00167 and 0.00083 — a lever arm of 0.0025, all of it close to zero.
`CP` is the intercept and is well determined. `W'` is the slope over that tiny arm, so a
few watts of noise in any point swings it enormously. An r² of 0.724 describes scatter
about a line those three points fit perfectly well; it carries no information about
whether the slope is identified. A threshold on it would refuse honest fits and pass this
one.

**And the missing anaerobic data cannot be recovered by widening the band.** The obvious
move is to feed the fit the short-duration bests the power curve already holds — this
athlete has a 5 s best of 424.2 W. It is the wrong move: 424 W is 1.67× CP, where a real
5 s sprint is 3–5× CP. That best is the hardest 5 seconds inside rides that were never
sprints, so admitting it would pull `W'` further DOWN, not correct it. The 300–1200 s band
is right, and the shortage is of maximal efforts, not of samples.

## What follows for a reader

`w_prime` from a 300–1200 s fit is an **extrapolation toward t→0 from data that contains
no anaerobic effort**. It is not a measurement of anaerobic capacity, and no statistic
published beside it says so — `fit_r2` in particular does not. Read a low `w_prime` as
"this athlete has no sprint on record", not as "this athlete has a small battery".

`contradicts_model` is the only empirical check on the prediction, because it compares
against what was actually done rather than against the model's own residuals.

## Known limit, stated rather than fixed

`contradicts_model` draws its evidence from `fit.pts` — the three fitted points — so
`demonstrated_s` can only ever be 300, 600 or 1200 seconds. Every other recorded effort is
invisible to it, including this athlete's 60 s best at 308.6 W.

Widening it to the whole recorded curve is a pure coverage gain with no threshold and no
judgment, and it is the right next change here. It is deliberately NOT made in this ADR,
which decides a policy question; and it is worth knowing that on this athlete's data it
would change nothing, because his short efforts are submaximal and therefore refute
nothing. It pays off for a rider who does sprint.

## Consequences for #188 and #189

`D'` is the pace-domain analog of `W'` and inherits this entire problem: same hyperbolic
model, same dependence on short maximal efforts, same blindness in r². Critical speed work
must publish the same caveats from the start rather than retrofitting them, and must not
adopt an r² gate on the strength of it looking like a quality signal.

This athlete has **one** Run on record, so `CS`/`D'` cannot be fitted on his data at all —
that feature is validated against someone else's history or not at all.
