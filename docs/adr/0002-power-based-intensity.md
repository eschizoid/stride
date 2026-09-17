# ADR 0002. Intensity is power-based and per-sport

Status: accepted
Date: 2026-08-01

The decision here is a companion to [ADR 0000 §4](0000-architecture.md), which covers the
mixed-model load. ADR 0002 covers intensity instead, meaning the easy, moderate and hard
split, polarization, and "hard minutes", and it records why intensity must come from power
rather than from heart rate for sports that have power.

## Context

For most of the project, intensity was derived purely from HR zones. Hard meant time in HR
Z4 plus Z5, and polarization came from HR-zone seconds. For an athlete whose training is
power-based, that method systematically mislabels hard efforts as moderate. The failure was
observed rather than theorized, on 2026-07-31.

A 45-min ride the athlete rode hard showed 1 minute hard by HR and 38 minutes at or above
threshold by power, with NP 239W ≈ FTP and IF around 0.99. The coach called the ride
moderate because of the HR label, the athlete insisted it was hard, and the athlete was
right. Over 28 days, polarization read 8% hard by HR against roughly 30% or more hard by
power.

HR-only intensity fails here for three reasons that compound. First, threshold HR sits on a
zone boundary, so a genuine threshold effort hovers at the Z3/Z4 line and logs mostly as
Z3, which reads as moderate. Second, power-zone rides are ridden at threshold power while
the athlete's HR does not always climb to match, because of fatigue, individual response or
a dropped strap. Third, HR data has artifacts, and one example is a cluster of phantom
200-209 bpm samples with a gap at 190-199, which is physiologically impossible and so
points to optical or strap noise. Never trust a raw max-HR reading, and when power and HR
conflict while power is near FTP, trust power.

## Decision

Intensity comes from power for any sport that has a power stream, judged against that
sport's own FTP. `Metrics.time_in_power_intensity` splits stream time into easy (<76% FTP),
moderate (76-90%) and hard (≥91%). Summary polarization, the "hard" column in activities
and week, and the activity detail all read power-intensity when it is present. They fall
back to the pace split for any distance sport without watts, and to HR zones only when
there is neither. TSS and IF are likewise judged against the sport's own FTP, so a rowing
effort is not scored against a cycling number.

Per-sport FTP is generic and data-driven, with no hardcoded sport list. A hardcoded list
was explicitly rejected during design, because it silently drops swimming, soccer and
paddleboard. The threshold key is per sport and never global, because a rowing watt is not
a cycling watt.

> Amended 2026-08-06. The text here originally described `ftp_<sport>` as a config key that
> is "auto-derived when unset", which left the door open to configuring it. The door is now
> closed. FTP is always derived from that sport's own best-20-min power × 0.95 and is never
> read from config, and `stride config set ftp_ride` is refused outright rather than stored
> and ignored. ADR 0005 additionally anchors the derivation window to each activity's own
> date. A no-power sport derives 0 and falls back to HR or RPE, which is unchanged.

## The honesty caveat

Do not drop this section, because the rest of the intensity story rests on it. The numbers
are only as good as the FTPs feeding them, and the FTPs are estimated from non-maximal
efforts, since the athlete rides controlled Power-Zone sessions and rarely tests all-out.
An FTP that is too low inflates both the hard percentage and the load.

Trust the direction rather than the decimals. A statement like "You're doing too much hard
work" holds even if the true figure is 25% and not 33%, but a percentage should not be
presented as precise. Real FTP tests, one per sport, tighten the absolute numbers, and
until those tests exist the coach reasons on direction and defers specific power-zone
prescriptions.

The caveat corrects the mistake that started the whole episode, which was the coach stating
soft, derived numbers as fact. The engine may compute, and the coach must caveat.

## Consequences

- Never regress to HR-only intensity, because it re-introduces the mislabeling. HR zones
  stay only as the fallback for no-power sports such as strength work or a ride with no
  strap, and as a way to compare across sports.
- Adding a sport needs no code and no config. Its FTP derives from its own power history
  the moment that history exists.
- Confidence tiers (ADR 0000 §4) annotate how much of the load is measured, from power or
  distance-measured pace, against how much is estimated from HR or RPE. `doctor` surfaces
  the split, and `measured_pct` carries it on the fitness number.
- Recompute invalidation is per-sport. A change in one sport's derived FTP recomputes only
  that sport's rows, because a generated `CASE` maps each sport to its FTP in the analyze
  filter.

## Amended 2026-08-16. The power population is the sport family (#151, PR #169)

Three statements above are superseded. FTP is no longer derived from that sport's own best
20-min power, because the derivation population is now the sport family. `Sports.families`
pools Ride, VirtualRide, GravelRide and MountainBikeRide together, and pools the other
families the same way, because within a family the meter and the muscles are the same. A
GravelRide judged against gravel-only history scored itself against a near-empty window,
and on the real database eleven gravel rides carried `ftp_used` 0 while the athlete's ride
FTP was in the 240s. "Intensity judged against that sport's own FTP" therefore now reads
"against its family's FTP", and "recompute invalidation is per-sport" now operates per
family member through the same `*_used` value comparison, so an edit to the family table
self-detects on the next analyze.

Pace thresholds deliberately stay exact-match per sport_type. Surface changes what a speed
means, as trail differs from road and a pool differs from open water, so collapsing pace
thresholds into families would manufacture a comparability that power has and pace does
not.

Mechanically the family lives as a stored, trigger-maintained `activities.sport_family`
column (schema v23) with its own `(sport_family, start_local)` index. A query-time CASE over
`sport_type` was measured 8.5× slower per analyze, because it defeats every sport index.
ADR 0005's "not doing: changing the derivation itself" is amended by exactly this much and
no further, so the window math, the anchoring and the cold-start forward-fill are all
untouched.
