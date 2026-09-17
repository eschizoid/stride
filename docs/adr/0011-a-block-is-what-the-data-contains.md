# ADR 0011. A training block is bounded by absence, described by measurement

Date: 2026-08-17. Status: accepted. Issue: #139. Depends on ADR 0005 (period-accurate FTP), ADR 0010 (projection vs prescription), #154 (engine emits measurements, never verdicts).

## Context

Issue #139 asks for a season view holding training blocks, monthly load, polarization per block, and FTP trajectory. Everything in that list is well defined except the first word. "Block" is coaching vocabulary with no agreed formal meaning, and the issue itself says the definition needs deciding before any code is written.

The textbook definition is the tempting one. A block is a build phase of N weeks followed by a recovery week, and the pattern repeats. It is tempting because training literature describes it that way and because an athlete expects to hear it.

The textbook pattern is not present in this data. Measured over the trailing 730 days of the athlete's real history, which covers 96 training weeks, the signature of a planned recovery week is a week whose load drops more than 25% from the prior week and rebounds more than 25% into the next. The signature occurs 8 to 10 times in 96 weeks, and the exact count depends on whether the neighbouring weeks must be calendar-adjacent or merely the adjacent trained weeks. Either reading puts it under ten percent. Weekly load over the trailing six months ranges from 58 to 364 TSS across trained weeks, with four fully blank weeks in that span, and it shows no periodic structure. The longest unbroken run of consecutive training weeks is 39, and the longest block, which tolerates a single blank week, is 71 trained weeks across 77 calendar weeks. An earlier draft called that block a consecutive run, which it is not.

A detector built on build and recover cycles would return a segmentation of noise, and it would return one for every athlete, because any oscillating series contains local minima. Stride would be manufacturing a structure the athlete never trained and then scoring it. The interval detector had the same failure before #170, when distribution gates found "intervals" in steady rides, and the reps screen had it before #185, when it produced eleven manufactured comparisons rather than saying "you have done this once". Both cases teach the same rule. When the honest answer is "this structure is not present", say that, because a fabricated structure is worse than no feature.

## Decision

A block is a maximal run of training weeks bounded by an absence of training. A gap of two or more calendar weeks with zero recorded load closes the current block and opens the next. A single blank week does not close a block, so a block is not a run of consecutive training weeks, and the block spanning 77 calendar weeks contains six blank ones. Nothing else opens or closes a block.

The boundary is observable, reproducible from raw records, and never invents a split where the athlete simply trained through. On the real history it yields 6 blocks over five years. The mean block is 32 trained weeks across 33 calendar weeks, the longest is 71 trained weeks across 77 calendar weeks, and the five gaps that separate the blocks are 2, 4, 4, 16 and 19 weeks.

The numbers are not flattering to the feature, and they are stated here plainly rather than sold. One block covers 77 consecutive calendar weeks, which is 31% of the athlete's entire recorded history. A block that large describes a long stretch of training rather than a single training phase, and the decision accepts that, because the alternative is inventing a boundary inside it. The monthly layer needs no definition at all, and it supplies the finer granularity there.

A block is described and never named. Stride reports, for each block, its span and week count, its total and weekly mean load, the measured load trend across it, its polarization from the stored zone seconds, and the FTP range that applied during it. The load trend is the regression slope of weekly load in TSS per week, reported with its r². The FTP range follows ADR 0005, so each week is scored against its own era's threshold. Stride does not label a block "base", "build", "peak", "taper" or "detraining", because those labels are claims about intent and stride observes load rather than intent. A coach who reads the slope, the polarization and the FTP movement can name the phase, and that naming is judgment that belongs to the coach (#154, ADR 0010).

Long blocks are reported as long rather than subdivided. The block of 77 calendar weeks means the athlete trained in 71 of 77 consecutive weeks. Splitting it to produce a larger number of shorter blocks would fabricate boundaries, which is what this ADR exists to prevent. A coach who wants finer granularity inside a long block gets it from monthly load, which #139 already asks for and which needs no definition at all.

The two-week gap threshold is a knob, and pretending otherwise would repeat the error this ADR rejects elsewhere. Measured on the real history, a threshold of one week gives 13 blocks with a longest run of 39 weeks, a threshold of two weeks gives 6 blocks with a longest of 71, and a threshold of three weeks gives 5 blocks with a longest of 110. The answer roughly halves between the first two settings. An earlier draft of this ADR claimed the threshold was "a stated constant, not a tuned one" and "the only knob", and the same draft rejected CTL changepoint detection for having a sensitivity parameter that chooses the answer, in language that describes `gap_weeks` verbatim.

The claim the decision makes instead is narrower. Two weeks is chosen because one week off is a normal part of training, whether from illness, travel or a deliberate rest week, while two consecutive weeks of nothing is a discontinuity in fitness rather than a variation within a phase. The choice of two weeks is a judgment, and it is the only judgment in the definition, because everything downstream of it is arithmetic. The threshold travels in the payload as `gap_weeks`, so the segmentation is always reproducible and inspectable, and a consumer who disagrees can see exactly what produced it. The claim is weaker than "no tuning problem", and it is the one the data supports.

## Consequences

`stride season` becomes describable without adding a judgment surface. It reports blocks bounded by measurement, each block carrying its own measurements, plus monthly load, polarization and FTP trajectory. Every field is a number or a stored value, and no prose verdict producer is added, so the #154 closed-set guard has nothing new to sweep.

A block's load trend is a regression slope, which is arithmetic over stated inputs and therefore inside ADR 0010. The report gives a fitted line by its endpoints, with the slope and r² beside them, and it never says "you were building". A low r² means scatter rather than the absence of a trend, as the paragraph on r² below explains.

An athlete who has never taken two weeks off has exactly one block covering their whole history. The single block is the correct answer, and it renders as one block rather than being split to look more useful.

Blocks are derived at query time from `daily_load` rather than stored. They are a view over the computed tier (ADR 0000 §3), so they rebuild from `analyze` like everything else, and they need no schema change, no migration and no invalidation story.

A low r² does not mean the block had no trend, and an earlier draft of this ADR said it did. r² measures scatter around the line rather than whether the slope differs from zero. The 71-week block sits at r² 0.10, and its fitted line still runs 315 → 214 TSS per week, a 32% decline with a t of about -2.8. The 46-week block at r² 0.33 runs 291 → 154, a 47% decline, and only the 9-week block, at r² 0.004, is genuinely trendless. Telling an athlete those blocks "had no trend" is the most likely false statement this feature could produce, so the payload publishes `fitted_start_load` and `fitted_end_load`, and the screen leads with them, because "315→214" cannot be mis-told the way "-1.3/wk, r² 0.10" can.

One regression per block is still a structural claim, and on a 77-week block it is a weak one. Four of the six blocks explain under 35% of the week-to-week scatter. The fitted endpoints make the movement legible, and a rolling N-week slope series inside long blocks would describe the shape rather than averaging it away. Such a series is arithmetic over stated inputs, fabricates no boundary, and stays inside ADR 0010, which makes it the most likely next revision. Fitting one line to 77 weeks is the weakest part of this design.

The deferred sport-family question already has a visible cost. The 77-week block is 52% Rowing and 48% Ride, and the single threshold range published for it is a rowing threshold, standing in for a block that also contains 132 bike sessions at a completely different power. Naming the family, which this decision requires, keeps the report honest rather than silently averaging two different quantities, and it does not make the block homogeneous. Whether a family switch without a gap should open a boundary is genuinely open, and answering it would not be a purely additive change.

One further question is left open here. Whether the season view exposes the interval and session type composition of each block is undecided, and adding it later would be a purely additive change.

The alternatives below were rejected, and they are recorded here so that they are not argued again.

- Build and recover cycle detection. Only 8 to 10 of the 96 weeks fit the shape, depending on how adjacency is read, so a detector would segment noise.
- CTL trajectory changepoints. The method requires a changepoint algorithm whose sensitivity parameter chooses the answer, and the same stretch of 46 trained weeks across 47 calendar weeks splits differently under any two settings.
- Fixed calendar quarters. They need no data and tell the athlete nothing they could not compute themselves.
- Naming phases from load and polarization. Naming a phase is a claim about intent drawn from evidence that only constrains volume, which is the definition of a verdict under #154.
