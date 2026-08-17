# ADR 0011 — A training block is bounded by absence, described by measurement

Date: 2026-08-17. Status: proposed. Issue: #139. Depends on ADR 0005 (period-accurate FTP), ADR 0010 (projection vs prescription), #154 (engine emits measurements, never verdicts).

## Context

#139 asks for a season view: training blocks, monthly load, polarization per block, FTP trajectory. Everything there is well-defined except the first word. "Block" is coaching vocabulary with no agreed formal meaning, and the issue itself says the definition wants deciding before code.

The tempting definition is the textbook one: a block is a build phase of N weeks followed by a recovery week, repeating. It is tempting because it is what training literature describes and what an athlete expects to hear.

It is also not in this data. Measured over the trailing 730 days of the athlete's real history (96 training weeks): a week whose load drops more than 25% from the prior week and rebounds more than 25% into the next — the signature of a planned recovery week — occurs **9 times in 96 weeks**. Nine percent. Weekly load over the last six months ranges 133–364 TSS with no periodic structure; the longest run of consecutive training weeks is 47.

A detector built on build/recover cycles would therefore return a segmentation of noise, and it would return one for every athlete, because any oscillating series contains local minima. Stride would be manufacturing a structure the athlete never trained, then scoring it. That is the same failure the interval detector had before #170 (distribution gates finding "intervals" in steady rides) and the same one the reps screen had before #185 (eleven manufactured comparisons rather than saying "you have done this once"). The house lesson from both: when the honest answer is "this structure is not present", say that, because a fabricated structure is worse than no feature.

## Decision

**A block is a maximal run of consecutive training weeks bounded by an absence of training.** A gap of two or more calendar weeks with zero recorded load closes the current block and opens the next. Nothing else opens or closes a block.

This is the only boundary in the data that is not a judgment call. It is observable, it is reproducible from raw records, it requires no threshold tuning beyond the gap length, and it never invents a boundary where the athlete simply trained through. On the real history it yields 12 blocks over five years (mean 16 weeks, longest 47, five gaps of 2/4/4/16/19 weeks).

**A block is DESCRIBED, never named.** Stride reports, per block: its span and week count, total and weekly-mean load, the measured load trend across it (the regression slope of weekly load, in TSS per week, with its R²), polarization from the stored zone seconds, the FTP range that applied during it (ADR 0005 — each week scored against its own era's threshold), and the count of weeks in it. It does not label a block "base", "build", "peak", "taper", or "detraining". Those are claims about intent, and stride cannot observe intent — only load. A coach reading slope, polarization and FTP movement can name the phase; that naming is judgment and belongs to the coach (#154, ADR 0010).

**Long blocks are reported as long, not subdivided.** A 47-week block means the athlete trained continuously for 47 weeks. Splitting it to produce more block-shaped blocks would be fabricating boundaries, which is the thing this ADR exists to prevent. If a coach wants finer granularity inside a long block, monthly load — which #139 already asks for and which needs no definition at all — provides it.

**The two-week gap threshold is a stated constant, not a tuned one.** It is chosen because one week off is a normal part of training (illness, travel, a deliberate rest week) while two consecutive weeks of nothing is a discontinuity in fitness, not a variation within a phase. It is published in the payload so a consumer never has to guess what produced the segmentation, and it is the only knob.

## Consequences

- `stride season` becomes describable without any new judgment surface: blocks bounded by measurement, each carrying measurements, plus monthly load, polarization and FTP trajectory. Every field is a number or a stored value; no prose verdict producer is added, so the #154 closed-set guard has nothing new to sweep.
- A block's load trend is a regression slope, which is arithmetic over stated inputs and therefore inside ADR 0010. It is not "you were building" — it is TSS/week with an R², and a low R² means the block had no trend, which is itself the honest answer.
- An athlete who has never taken two weeks off has exactly one block covering their whole history. That is correct and should render as such rather than being split to look more useful.
- Blocks are derived at query time from `daily_load`, not stored. They are a view over the computed tier (ADR 0000 §3), so they rebuild from `analyze` like everything else and need no schema change, no migration, and no invalidation story.
- Deliberately NOT decided here: whether the season view also exposes per-block interval/session-type composition, and whether a block boundary should additionally be opened by a sport-family switch (an athlete who stops cycling and starts running without a gap). Both are additive and can be settled when the command surface is built.
- Rejected alternatives, recorded so they are not relitigated: **build/recover cycle detection** (9 of 96 weeks fit the shape — a detector would segment noise); **CTL-trajectory changepoints** (requires a changepoint algorithm whose sensitivity parameter chooses the answer, and the same 47-week stretch splits differently under any two settings); **fixed calendar quarters** (needs no data and tells the athlete nothing they could not compute themselves); **naming phases from load and polarization** (a claim about intent from evidence that only constrains volume — the definition of a verdict under #154).
