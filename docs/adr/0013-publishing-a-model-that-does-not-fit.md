# ADR 0013. Publishing a model that does not fit

Status: accepted. Decided 2026-08-19. Closes #199

`tte` and `power-curve` publish a Critical Power fit. On this athlete's data the fit is
arithmetically correct and descriptively wrong, and #199 asked whether a sufficiently bad
fit should decline to answer at all.

## What the fit reports on this athlete's data

The figures below were re-derived against the live database on 2026-08-19.

| quantity | value |
|---|---|
| `cp` | 254.24 W |
| `w_prime` | 6416 J (a trained cyclist is normally 15000 to 25000) |
| `fit_r2` | 0.724 |
| `fit_points` | 3 |
| `tte 265` prediction | 596 s (9:56) |
| effort actually held at ≥265 W | over 12 minutes, at 720 s and 268.4 W, 3.4 W clear of the cutoff |

The demonstrated effort is 20.8% longer than the prediction.

The 720 s figure is a deliberate anchor. The mean-max window that ends exactly at 265 W is
756 s by stride's own resampler, but its margin there is +0.003 W and it turns negative one
second later. A figure that moves on the last decimal of a gap-filling choice cannot carry
an argument about false precision, and 720 s does not move.

The first draft of this ADR said 600 s, and the error stays on the record, because it is the
failure this document describes, committed while describing it. 600 s is the longest of the
three fitted points at 265 W or above rather than the longest effort. The ladder jumps from
600 to 1200 with nothing between, so a 12-minute effort is invisible to it. Reading a ladder
rung as a measurement of the athlete is the mistake `contradicts_model` exists to prevent,
and here it made the model look 0.7% off instead of 21%.

## `fit_r2` reports the imprecision exactly, and the payload does not publish it

An earlier draft claimed that r² "carries no information about whether the slope is
identified", and the claim is false. With three points and one predictor there is one
residual degree of freedom, so r² and the slope's t-statistic are in exact bijection, as the
arithmetic below shows.

```
t      = sqrt(r2 / (1 - r2)) = 1.6215
SE(W') = W' / t              = 3957 J        ->  W' = 6416 +/- 3957   (+/- 62%)
SE(CP)                       =    8.7 W      ->  CP = 254.2 +/-   8.7 (+/-  3%)
95% CI for W' (df = 1)       = [-44 kJ, +57 kJ]
```

The payload does not currently state that asymmetry, which is why the fix is to publish it.
Imprecision is not itself the defect, and the next section shows that the most precise fits
are the least plausible. The numbers above describe precision within one fit only. Across
windows CP moves from 250.34 to 283.07, a spread of 32.7 W that is far larger than the ±8.7
of a single fit, so CP is the better determined half of a given fit rather than a stable
number. The missing piece is a number rather than a threshold, so `SE(W')` is published
beside `w_prime`. It falls out of the same three points, needs no opinion, and turns `6416`
into `6416 ± 3957`.

Whoever adds it needs one implementation note. `SE` divides by zero at two fitted points,
where r² is 1 by construction and there is no residual degree of freedom. `critical_power`
accepts n ≥ 2 and `cp_fit_as_of!` drops zero-watt rungs, so the case is reachable. Report it
unknown per ADR 0009, as `tte_screen` already special-cases r² there for the same reason.

## Decision, no refusal threshold on `fit_r2`

The reason is not that thresholds are opinions, which is #199's argument and is sound
without being load-bearing. The reason is that r² measures precision rather than
plausibility, so gating on it rewards the wrong fits.

The shipped command is its own counterexample. The table below runs
`stride power-curve <days> Ride` on the same athlete, the same database and the same day,
changing only the window.

| window | CP | W' | 95% CI for W' | `fit_r2` |
|---|---|---|---|---|
| 30 to 60 d | 250.34 | 7754 J | [-57 kJ, +73 kJ] | 0.6967 |
| 75 to 90 d | 254.24 | 6416 J | [-44 kJ, +57 kJ] | 0.7245 |
| 120 to 1095 d | 283.07 | 3059 J | [-0.3 kJ, +6.5 kJ] | 0.9924 |

An `r² ≥ 0.90` gate refuses stride's 90-day answer and passes its 120-day answer, whose W'
is half as plausible. Breaking the gate needs no synthetic input, because the command breaks
it unaided.

Every interval in that column spans zero, which is the evidence for the claim in the next
section that the behaviour belongs to the ladder rather than to one window. The fit the gate
prefers also has the tightest interval, and it is centred on 3059 J, a fifth of the bottom
of the normal band quoted above.

Refitting confirms the direction, as the table below shows when this athlete's own 5 s best
is added.

| points fitted | CP | W' | `fit_r2` |
|---|---|---|---|
| 300 / 600 / 1200 (shipped) | 254.24 | 6416 ± 3957 J | 0.7245 |
| + the 5 s best | 265.13 | 796 ± 51 J | 0.9918 |
| + 5 / 15 / 30 / 60 s bests | 282.21 | 772 J | 0.8744 |

r² rises to 0.99 while W' falls to an eighth of an already implausible value, and the fit an
r² gate would prefer reports `796 ± 51`. The interval is tight and the value is absurd, and
this ADR asks for both to be stated in exactly those units.

The same row is why the obvious repair fails. The 5 s best is 424.2 W against a CP of 254.2,
which is 1.67 times CP. It is the hardest five seconds inside rides that were never sprints,
so it pulls the fitted line down at the short end. With it CP rises to 265.13 and `tte 265`
answers `below_cp`. The 300 to 1200 s band is the right one, and the shortage is of maximal
efforts rather than of samples.

## Why the decision differs from `no_cp_fit` and `trend_known: false`

#199 named both as precedents for declining rather than qualifying, and they are the
strongest case for refusing, so they deserve an answer rather than silence.

Both are structural refusals, because they fire when the inputs are absent or degenerate.
The triggers are too few bests, or under three weeks of data where r² would be 1 by
construction. Neither is a quality threshold, so "r² measures precision, not plausibility"
does not dispose of them.

The structural version of the same idea would refuse whenever the interval for W' spans
zero. Every row of the sweep above spans zero, because `fit_points` is at most 3, since the
ladder offers only 300, 600 and 1200 in the band. The degrees of freedom are therefore at
most 1, which is a property of the design rather than of this athlete. The refusal would be
unconditional, and it would also be inverted, because at two fitted points there is no
interval at all and the degrees of freedom are zero, as the implementation note above says.
It would refuse every three-point fit and admit the two-point ones, which are the least
supported case in this document, and it would silence `tte` for everyone who has enough data
to be refused, on a ladder ADR 0004 shipped deliberately.

A published `± 3957` gives the same diagnosis without the silence, and ADR 0012's "Not
doing" section allows it, because *a `_known` flag or a `model_exceeded` boolean is a
diagnosis of the model, not advice to the athlete.* The screen already carries r² and the
refutation, quoted verbatim below from `tte 265` on this database.

```
at 265W against CP 254 (Ride fit, W' 6.4 kJ from 3 of the 5/10/20-min bests over 90d, r2 0.72)
  ~9:56 · on record: 271W for 10:00 in this window — LONGER than the model predicts, so the fit understates this rider
```

The screen tells a coach strictly more than `no_cp_fit` would. It does not report the
12-minute effort, because the 10:00 it names is the 600 s fitted point, for the reason
recorded below.

## How to read a low `w_prime`

A low `w_prime` here means the athlete's 5, 10 and 20 minute bests are ride segments rather
than maximal efforts. It is neither a measurement of anaerobic capacity nor evidence of a
small one.

`contradicts_model` remains the only empirical check, because it compares the prediction
against what was actually done rather than against the model's own residuals.

## Known limit, stated rather than fixed

`contradicts_model` draws its evidence from `fit.pts`, which holds the three fitted points,
so `demonstrated_s` can only ever be 300, 600 or 1200 seconds. The limit produced the 600 s
error above, and it is why a 12-minute effort went unreported.

Widening it to the stored ladder is a coverage gain with no threshold and no judgment. The
contradiction band barely moves, by 5.7 W, because this athlete's short efforts are
submaximal and refute nothing. `demonstrated_s` and `demonstrated_w` do become populated
across 150 W, where they currently report `demonstrated_known: false`.
Widening further, to the athlete's true mean-max curve rather than the stored rungs, is what
would have caught the 12-minute effort.

## Consequences for #188

`D'` is the pace-domain analog of `W'` and inherits everything above. It uses the same
model, it depends the same way on maximal efforts the athlete may never perform, and its r²
measures precision rather than plausibility. Critical speed should publish `SE(D')` from the
start, and it must not adopt an r² gate on the strength of r² looking like a quality signal.

The athlete has one Run on record, so `CS` and `D'` cannot be fitted on his data at all, and
the feature is validated against someone else's history or not at all.
