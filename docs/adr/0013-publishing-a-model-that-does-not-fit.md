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
| effort actually held at ≥265 W | **over 12 minutes** — 720 s at 268.4 W, 3.4 W clear of the cutoff |

The demonstrated effort is **20.8% longer** than the prediction.

Anchored at 720 s deliberately. The mean-max window that ends exactly at 265 W is 756 s by
stride's own resampler, but its margin there is +0.003 W and it flips negative one second
later — a figure that moves on the last decimal of a gap-filling choice has no business
carrying an argument about false precision. 720 s cannot move.

**The first draft of this ADR said 600 s, and that error stays on the record**, because it
is the failure this document describes, committed while describing it. 600 s is the longest
of the three FITTED points at ≥265 W, not the longest effort: the ladder jumps 600 → 1200
with nothing between, so a 12-minute effort is invisible to it. Reading a ladder rung as a
measurement of the athlete is exactly the mistake `contradicts_model` exists to prevent, and
it made the model look 0.7% off instead of 21%.

## `fit_r2` reports the imprecision exactly — and the imprecision is what we do not publish

An earlier draft claimed r² "carries no information about whether the slope is identified".
That is false. With three points and one predictor there is one residual degree of freedom,
so r² and the slope's t-statistic are in exact bijection:

```
t      = sqrt(r2 / (1 - r2)) = 1.6215
SE(W') = W' / t              = 3957 J        ->  W' = 6416 +/- 3957   (+/- 62%)
SE(CP)                       =    8.7 W      ->  CP = 254.2 +/-   8.7 (+/-  3%)
95% CI for W' (df = 1)       = [-44 kJ, +57 kJ]
```

That asymmetry is what the payload does not currently say, which is why the fix is to
publish it — not that imprecision is itself the defect; the next section shows the most
precise fits are the least plausible. Read it as WITHIN-fit precision only:
across windows CP moves 250.34 → 283.07, a 32.7 W spread that dwarfs its own ±8.7, so CP is
the better-determined half of a given fit rather than a stable number. So the missing piece
is not a threshold but a number:
**publish `SE(W')` beside `w_prime`.** It falls out of the same three points, needs no
opinion, and turns `6416` into `6416 ± 3957`.

Implementation note for whoever adds it: `SE` divides by zero at two fitted points, where
r² is 1 by construction and there is no residual degree of freedom. `critical_power` accepts
n ≥ 2 and `cp_fit_as_of!` drops zero-watt rungs, so that case is reachable. Report it
unknown per ADR 0009 — `tte_screen` already special-cases r² there for the same reason.

## Decision: no `fit_r2` refusal threshold

Not because thresholds are opinions — that is #199's argument, and it is sound but not
load-bearing. The reason is that **r² measures precision, not plausibility**, so gating on
it rewards the wrong fits.

The shipped command is its own counterexample. `stride power-curve <days> Ride`, same
athlete, same database, same day — only the window changes:

| window | CP | W′ | 95% CI for W′ | `fit_r2` |
|---|---|---|---|---|
| 30–60 d | 250.34 | 7754 J | [−57 kJ, +73 kJ] | 0.6967 |
| 75–90 d | 254.24 | 6416 J | [−44 kJ, +57 kJ] | 0.7245 |
| 120–1095 d | 283.07 | **3059 J** | [−0.3 kJ, +6.5 kJ] | **0.9924** |

An `r² ≥ 0.90` gate refuses stride's 90-day answer and passes its 120-day answer, whose W′
is half as plausible. No synthetic input is required to break the gate; the command breaks
it unaided.

Every interval in that column spans zero, which is the evidence for the claim in the next
section that this is a property of the ladder rather than of one window. Note also that the
fit the gate prefers has the TIGHTEST interval — tight, and centred on 3059 J, a fifth of
the bottom of the normal band this ADR quotes above.

Refitting confirms the direction. Adding this athlete's own 5 s best:

| points fitted | CP | W′ | `fit_r2` |
|---|---|---|---|
| 300 / 600 / 1200 (shipped) | 254.24 | 6416 ± 3957 J | 0.7245 |
| + the 5 s best | 265.13 | **796 ± 51 J** | **0.9918** |
| + 5 / 15 / 30 / 60 s bests | 282.21 | 772 J | 0.8744 |

r² rises to 0.99 while W′ collapses to an eighth of an already-implausible value — and the
fit an r² gate would prefer reports `796 ± 51`: tight, confident, absurd, stated in the very
units this ADR asks for.

That row is also why the obvious repair fails. The 5 s best is 424.2 W against a CP of
254.2, i.e. 1.67×. It is the hardest five seconds inside rides that were never sprints, so
it drags the line down; with it CP rises to 265.13 and `tte 265` answers `below_cp`. The
300–1200 s band is right. The shortage is of maximal efforts, not of samples.

## Why this is not `no_cp_fit` or `trend_known: false`

#199 named both as precedents for declining rather than qualifying, and they are the
strongest case for refusing, so they deserve an answer rather than silence.

Both are **structural** refusals: they fire when the inputs are absent or degenerate —
too few bests, or under three weeks where r² would be 1 by construction. Neither is a
quality threshold, so "r² measures precision, not plausibility" does not dispose of them.

The structural analogue here would be to refuse whenever W′'s interval spans zero. Every
row of the sweep above does, because `fit_points` is **at most 3** — the ladder offers only
300/600/1200 in the band — so df is at most 1, a property of the design rather than of this
athlete. That refusal is unconditional, and worse than unconditional: at two fitted points
there is no interval at all — df is zero, as the implementation note above says — so it
would refuse every three-point fit and wave through the two-point ones, which are the least
supported case in this document. It would silence `tte` for everyone who has enough data to
be refused, on a ladder ADR 0004 shipped deliberately.

A published `± 3957` is the same diagnosis without the silence, and ADR 0012's "Not doing"
section explicitly allows it: *a `_known` flag or a `model_exceeded` boolean is a diagnosis
of the model, not advice to the athlete.* The screen already carries r² and the refutation —
verbatim from `tte 265` on this database:

```
at 265W against CP 254 (Ride fit, W' 6.4 kJ from 3 of the 5/10/20-min bests over 90d, r2 0.72)
  ~9:56 · on record: 271W for 10:00 in this window — LONGER than the model predicts, so the fit understates this rider
```

That tells a coach strictly more than `no_cp_fit` would. Note what it does NOT say: the
10:00 is the 600 s fitted point, not the 12-minute effort, for the reason recorded below.

## What follows for a reader

A low `w_prime` here means **this athlete's 5-, 10- and 20-minute bests are ride segments
rather than maximal efforts**. It is not a measurement of anaerobic capacity and not
evidence of a small one.

`contradicts_model` remains the only empirical check, because it compares the prediction
against what was actually done rather than against the model's own residuals.

## Known limit, stated rather than fixed

`contradicts_model` draws its evidence from `fit.pts` — the three fitted points — so
`demonstrated_s` can only ever be 300, 600 or 1200 seconds. That is what produced the 600 s
error above, and it is why a 12-minute effort went unreported.

Widening it to the stored ladder is a coverage gain with no threshold and no judgment.
Two things to know first: the *contradiction band* barely moves (5.7 W, because this
athlete's short efforts are submaximal and refute nothing), but `demonstrated_s`/
`demonstrated_w` become populated across 150 W where they currently report
`demonstrated_known: false`. Widening further, to the athlete's true mean-max curve rather
than the stored rungs, is what would have caught the 12-minute effort.

## Consequences for #188

`D'` is the pace-domain analog of `W'` and inherits all of this: same model, same dependence
on maximal efforts the athlete may never perform, same precision-not-plausibility property
in r². Critical speed should publish `SE(D')` from the start, and must not adopt an r² gate
on the strength of it looking like a quality signal.

This athlete has **one** Run on record, so `CS`/`D'` cannot be fitted on his data at all —
that feature is validated against someone else's history or not at all.
