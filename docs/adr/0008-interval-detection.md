# ADR 0008. Interval detection: a reporting-only detector, segments as computed tier

Status: Accepted
Date: 2026-08-09
Note: Mariano approved the decision, and it unblocks #95. The parameters under
"Parameters (initial, expect tuning)" are a starting point rather than settled
numbers, and the validation bar below governs whether they ship.

## Context

The engine trusts session names and free-text prescriptions, and it never reads the stream
to see what actually happened. Whether a VO2 session reached its target range is judged
today by a human reading `activity` output. Detection turns that judgment from a claim into
a measurement. Detection is also the largest item on the roadmap's foreground track, so its
boundaries are fixed in an ADR before any code is written.

## Decision

### Decision 1. The detector reports and never acts

The output is structure, such as `5×[3:01 @ 258W / 3:04 easy]`, surfaced on `activity` in
both the human table and the JSON. Matching structure to a prescription and completing it
remains an act for the coach or the human. Auto-completing was considered and rejected, and
so was emitting match candidates. Prescriptions are free text, so matching structure
against them means parsing prose, which is judgment, and judgment belongs to the coach
under ADR 0000. If structured prescription targets ever ship, re-argue the decision then.

### Decision 2. Power and pace place edges, and HR never does

One signal-agnostic detector runs over a 1 Hz series. First it smooths the series. Second
it finds sustained level shifts. Third it drops segments shorter than a minimum duration.
Fourth it labels work and recovery relative to the session's own distribution. The detector
is deterministic, uses no machine learning, and returns the same output for the same input.

Power covers rides and rows, because both carry meters here.

Pace covers runs and swims through the existing 1 Hz grade-adjusted speed stream, which is
the same series rTSS already consumes. Pace uses more smoothing and longer minimum
durations, because GPS wobble must not invent efforts.

Edges derived from HR would be inaccurate, because HR lags effort by 30 s or more, and they
are permanently out of scope. Sessions recorded without a sensor detect nothing, and
`hard_s` and the zone numbers already describe them.

### Decision 3. HR enriches detected segments

Within edges placed by power or pace, per-rep HR is computed. The computed values are peak
and average HR per work rep, drift across reps, which is the fatigue signature, and the
60 s recovery drop after each rep, which is a validated fitness marker. HR also corroborates
the power reading. Work reps at target watts that never raise HR past Z3 are visible
evidence of a mis-set FTP or a wrong zone configuration, and they are reported as numbers
rather than as a verdict.

### Decision 4. Segments are computed-tier data

A new `activity_segments` table holds activity_id, ordinal,
kind (work|recovery|warmup|cooldown), start_s, dur_s, avg_signal, signal (power|pace), and
the HR enrichment columns. `analyze` rebuilds the table, and it can be deleted at any time,
exactly like
`activity_metrics`. Segments join the existing invalidation story, because stream arrival
and Strava edits already delete metrics and will delete segments the same way. The
detection parameters are versioned by `metrics_rev`, so a tuning change recomputes history
honestly.

## Parameters (initial, expect tuning)

Smoothing uses a 15 s rolling mean for power and a 30 s rolling mean for pace. A level shift
counts when the smoothed mean moves ≥ 20% of the session's interquartile spread and holds
for ≥ 60 s in power or ≥ 90 s in pace. Segments are gap-bridged across pauses under the
existing `max_sample_gap_s` rules. The constants live in `Metrics.roc` beside their expects,
and every change to them bumps `metrics_rev`.

## Risk and the acceptance bar

The description above will meet conditions it does not cover, such as traffic stops
mid-interval, Peloton resistance drift, and irregular fartlek noise. The acceptance bar is
validation against sessions where the truth is known, meaning the athlete's own recent VO2
and threshold rides, before the feature ships in any release. A detector that mislabels the
maintainer's own workout removes the trust it exists to build.

## Not doing

- There are no match candidates against prescriptions, as decision 1 states.
- There is no HR-only detection, ever.
- There are no bespoke per-sport detectors, because there is one algorithm with per-signal
  parameters.
- There are no natural-language workout summaries in the engine, such as "great 5×3!",
  because structure is numbers and prose belongs to the coach.

## Amendment of 2026-08-16, structure gates replace the distribution gate (#170, PR pending)

The v1 `min_spread` IQR gate judged the ride's global value distribution and failed in both
directions on real rides. A textbook 3×12 threshold session, the maintainer's own on
2026-08-16, is about 80% work samples, so its IQR sat inside the work band and the gate
reported zero segments. A progressive endurance ride's ramp inflated IQR past the gate, and
the ride's harder second half was sliced into seven consecutive pseudo-reps. The v1 work and
recovery labeling threshold, which was the quantile midpoint, had the same fault. On the
3×12 it landed above the reps and labeled everything recovery.

Detection is now judged on structure, after segmentation. Five changes make that judgment.

First, the edge threshold keeps its adaptive `shift_frac × IQR` term and gains a
`min_shift` floor of 30 W in power and 0.3 m/s in pace, so steady rides produce no edges.

Second, the work and recovery threshold is a two-cluster Otsu split over segment level
means, gated on cluster-mean separation, and it is never a global quantile.
Largest-adjacent-gap was tried first and failed on real rowing intervals, whose dense levels
sort quasi-continuously.

Third, adjacent work pieces merge into one effort, so a sliced continuous block cannot read
as reps.

Fourth, a contrast gate requires the easy parts to be easy. The gate is
median(non-work)/median(work) ≤ 0.80 for multi-rep structure and ≤ 0.65 for a single
sustained effort, because a weaker structural claim needs stronger separation. The measured
anchors are 0.53 for the 3×12, 0.75 for a real surge ride, and 0.83 for the "recoveries" in
the false-positive reproduction.

Fifth, a work-fraction ceiling requires the work to be a fraction of the ride, at
`work_frac ≤ 0.93`. Rescoring history surfaced dozens of steady rides reporting one
44-minute "rep" covering 0.98 of the session.

The three cases are frozen as pins in Metrics.roc. One is a real ride at 15 s resolution,
whose behavior was verified identical to full resolution, and it is the anchor because no
synthetic reproduced the false negative. The other two are synthetics built at 1 Hz. The
3×12 must detect three reps of about 12 minutes, the progressive ride must report nothing,
and the surge ride must stay detected. `metrics_rev` 31 rescores history under the new
gates.
