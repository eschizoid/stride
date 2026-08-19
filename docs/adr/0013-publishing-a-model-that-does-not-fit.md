# ADR 0013 — Publishing a model that does not fit

Status: accepted · Decided 2026-08-19 · Closes #199

`tte` and `power-curve` publish a Critical Power fit. On this athlete's data the fit is
arithmetically correct and descriptively wrong, and #199 asked whether a sufficiently bad
fit should decline to answer at all.

## What actually happened

Re-derived against the live database on 2026-08-19:

| quantity | value |
|---|---|
| `cp` | 254.24 W |
| `w_prime` | 6416 J (a trained cyclist is normally 15000–25000) |
| `fit_r2` | 0.724 |
| `fit_points` | 3 |
| `tte 265` prediction | 596 s (9:56) |
| longest effort actually held at ≥265 W | **755 s (12:35)**, 2026-08-16 |

The model is **27% short**, not marginally off.

**The first draft of this ADR said 600 s, and that error is worth keeping on the record**
because it is the failure this document describes, committed while describing it. 600 s is
the longest of the three FITTED points at ≥265 W, not the longest effort: the stored
ladder jumps 600 → 1200 with nothing between, so anything the athlete held for 12:35 is
invisible to it. Reading a ladder rung as a measurement of the athlete is exactly the
mistake `contradicts_model` exists to prevent, and it made the model look 0.7% off instead
of 27%.

## Does `fit_r2` report the problem? Yes — exactly, and we do not publish it

An earlier draft claimed r² "carries no information about whether the slope is
identified". That is false. With three points and one predictor there is one degree of
freedom, and r² and the slope's t-statistic are in exact bijection:

```
t  = sqrt(r2 / (1 - r2)) = sqrt(0.724454 / 0.275546) = 1.6215
SE(W') = W' / t          = 6416 / 1.6215 = 3957 J
95% CI (df = 1)          = [-43861, +56694]
```

The confidence interval spans zero. r² is *precisely* the statistic that says so — it is
the only thing it says. So the honest missing piece is not a threshold but a number:
**publish `SE(W')` beside `w_prime`.** It comes from the same three points, requires no
opinion, and turns `6416` into `6416 ± 3957`, which a coach can read without knowing
anything about hyperbolic fits.

## Decision: no `fit_r2` refusal threshold

Not because thresholds are opinions — that is #199's argument and it is sound but not
load-bearing. The reason is that **r² measures precision, not plausibility**, and gating on
it would reward the wrong fits.

Refitting this athlete's own bests, same regression, only the input set changed:

| points fitted | CP | W′ | r² |
|---|---|---|---|
| 300 / 600 / 1200 (shipped) | 254.24 | 6416 J | 0.7245 |
| + the 5 s best | 265.13 | **796 J** | **0.9918** |
| + 5 / 15 / 30 / 60 s bests | 282.21 | 772 J | 0.8744 |

Adding the 5 s best raises r² from 0.72 to **0.99** while collapsing W′ to a twelfth of an
already-implausible value. Any r² gate prefers the second row to the first. It would admit
a fit that is far more wrong and refuse the one that is merely imprecise.

That second row is also why the obvious repair — feed the fit the short bests the power
curve already holds — is wrong. The 5 s best is 424.2 W against a CP of 254.2, i.e. 1.67×.
It is the hardest five seconds inside rides that were never sprints, so it drags the line
down; with it, CP rises to 265.13 and `tte 265` answers `below_cp`. The 300–1200 s band is
right. The shortage is of maximal efforts, not of samples.

## What follows for a reader

A low `w_prime` here means **this athlete's 5-, 10- and 20-minute bests are ride segments
rather than maximal efforts**. It is not a measurement of anaerobic capacity, and it is not
evidence of a small one.

`contradicts_model` remains the only empirical check, because it compares the prediction
against what was actually done rather than against the model's own residuals.

## Known limit, stated rather than fixed

`contradicts_model` draws its evidence from `fit.pts` — the three fitted points — so
`demonstrated_s` can only ever be 300, 600 or 1200 seconds. That is what produced the 600 s
error above.

Widening it to the stored ladder is a coverage gain with no threshold and no judgment, and
it is the right next change. Two things to know before making it: the *contradiction band*
barely moves (5.7 W of the answerable range, because this athlete's short efforts are
submaximal and refute nothing), but `demonstrated_s`/`demonstrated_w` become populated
across roughly 150 W where they currently report `demonstrated_known: false`. Widening
further, to the athlete's true mean-max curve rather than the stored rungs, is what would
have caught the 12:35 effort.

## Consequences for #188

`D'` is the pace-domain analog of `W'` and inherits all of this: same model, same
dependence on maximal efforts the athlete may never perform, same precision-not-plausibility
property in r². Critical speed should publish `SE(D')` from the start, and must not adopt
an r² gate on the strength of it looking like a quality signal.

This athlete has **one** Run on record, so `CS`/`D'` cannot be fitted on his data at all —
that feature is validated against someone else's history or not at all.
