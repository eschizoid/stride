# ADR 0008 — interval detection: a reporting-only detector, segments as computed tier

Status: proposed · 2026-08-09 — design boundaries settled in the roadmap grill;
storage and parameters drafted here for review before implementation

## Context

The engine trusts session *names* and free-text prescriptions; it never reads the
stream to see what actually happened. Whether a VO2 session actually reached its
target range is judged today by a human eyeballing `activity` output. Detection turns
that from a claim into a measurement — and it is the flagship of the roadmap's
foreground track, which makes its boundaries worth fixing in an ADR before any code.

## Decision

**1. The detector reports; it never acts.** Output is structure — `5×[3:01 @ 258W /
3:04 easy]` — surfaced on `activity` (human table + JSON). Matching structure to a
prescription and completing it remains a coach/human act. Auto-completing, and even
emitting match *candidates*, was considered and rejected: prescriptions are free text,
so structure-matching means parsing prose, which is judgment, which belongs to the
coach (ADR 0000). If structured prescription targets ever ship, re-argue then.

**2. Power and pace place edges; HR never does.** One signal-agnostic detector over a
1 Hz series: smooth → find sustained level shifts → drop segments shorter than a
minimum duration → label work/recovery relative to the session's own distribution.
Deterministic; no ML; same input, same output.

- **Power** covers rides AND rows (both carry meters here).
- **Pace** covers runs and swims via the existing 1 Hz grade-adjusted speed stream —
  the same series rTSS already consumes — with more smoothing and longer minimum
  durations, because GPS wobble must not invent efforts.
- **HR-derived edges would be fiction** (HR lags effort by 30+ s) and are permanently
  out. Sensor-less sessions detect nothing; `hard_s`/zones already tell their story.

**3. HR enriches detected segments.** Within edges placed by power/pace, per-rep HR is
computed: peak and average per work rep, drift across reps (the fatigue signature),
and post-rep 60 s recovery drop (a validated fitness marker). Also corroboration: work
reps at target watts that never raise HR past Z3 are visible evidence of a mis-set FTP
or a wrong zone config — reported as numbers, never as a verdict.

**4. Segments are computed-tier data.** A new `activity_segments` table (activity_id,
ordinal, kind work|recovery|warmup|cooldown, start_s, dur_s, avg_signal, signal
power|pace, plus the HR enrichment columns), rebuilt by `analyze`, deletable at will —
exactly like `activity_metrics`. It joins the invalidation story: stream arrival and
Strava edits already delete metrics and will delete segments the same way, and the
detection parameters are versioned by `metrics_rev` so a tuning change recomputes
history honestly.

## Parameters (initial, expect tuning)

Smoothing 15 s rolling mean (power), 30 s (pace) · a level shift counts when the
smoothed mean moves ≥ 20% of the session's interquartile spread and holds ≥ 60 s
(power) / ≥ 90 s (pace) · segments gap-bridged across pauses per the existing
`max_sample_gap_s` rules. These constants live in `Metrics.roc` beside their expects,
and every change to them bumps `metrics_rev`.

## Risk, stated plainly

The clean description above will meet messy reality: traffic stops mid-interval,
Peloton resistance drift, fartlek-shaped noise. The acceptance bar is validation
against sessions where the truth is known — the athlete's own recent VO2/threshold
rides — before the feature ships in any release. A detector that mislabels the
maintainer's own workout erodes exactly the trust it exists to build.

## Not doing

- No match candidates against prescriptions (see Decision 1).
- No HR-only detection, ever.
- No per-sport bespoke detectors — one algorithm, per-signal parameters.
- No natural-language workout summaries in the engine ("great 5×3!") — structure is
  numbers; prose is the coach's.
