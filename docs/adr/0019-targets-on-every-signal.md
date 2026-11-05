# 0019. targets on every signal: heart rate, zone and pace beside power

Accepted 2026-11-05 (#636). Amends ADR 0014 §2 and its first "Not doing" line.

## Context

ADR 0014 shipped structured targets for power only. It deferred pace and heart-rate
targets "until each has a literal a human would actually type", because the detector's
pace signal is m/s and nobody prescribes in m/s. Most prescriptions are not power: a
Z2 day is capped by heart rate, a tempo run is a pace, a swim set is a pace per 100 m
and a row a split per 500 m. Those sessions carried their intent in prose alone, so
`complete` could say nothing about them, for every sport but the power-metered ones.

Each of those forms has a literal athletes already write: `HR125-147`, `Z2`,
`4:10/km`, `6:45/mi`, `1:40/100m`, `1:55/500m`.

## Decision

1. **One literal, four signals.** The target stays `<reps>x<rep>@<signal>`. The signal
   is `<watts>W`, `HR<lo>-<hi>`, `Z<n>` or `<m:ss>/<unit>` with unit `km`, `mi`, `100m`
   or `500m`. Power keeps ADR 0014's grammar exactly. A non-power rep may run past an
   hour (`h:mm:ss`), and only a pace rep may be a distance (`<n>m`, `<n>km`). Parsing is
   strict, as before, and a zone target needs the athlete's zones configured, as
   analyze does.

2. **The literal is the record.** The row stores the canonical literal in one column.
   The three power columns keep a power target's numbers and stay NULL for every other
   kind, so the readers that mean power (the projection, the window's power curve and
   plan view) need no kind test. A row written before this ADR has no literal and
   reads back as the power target its columns describe.

3. **Each kind is compared on its own signal.** `complete` keeps ADR 0014's power fields
   and adds a signal-neutral block, `exec_known` with `exec_reason`, plus each kind's
   measurements:
   - **hr:** seconds under, inside and over the band, and the mean of the stream's
     valid (35-220 bpm) samples, from the stored HR stream.
   - **zone:** seconds below, inside and above the zone, from the zone split analyze
     stored under the zones in force for that sport.
   - **pace:** always the actual pace, in seconds per the target's unit. When the
     detector found pace work reps it is the distance the stream covered inside their
     windows over their time (`pace_basis: detected`). The detector finds reps on
     grade-adjusted speed, and that average describes the effort, not the pace that
     was run, so it is never reported as one. Otherwise it is distance over moving
     time (`whole`).

   The pace unit names the sport family it is read for: /km and /mi for run, walk and
   hike, /100m for swim, /500m for rowing. Completing a pace target with an activity
   from another family compares nothing and says so (`pace_unit_mismatch`). It is not
   refused, because a completion is evidence and the athlete may have swapped the
   sport on the day.

4. **ADR 0014 §4 still holds.** Every field is a measurement. Stride never proposes,
   adjusts or evaluates a target, and the human line states numbers without a verdict.

## Not doing

- **Load estimates from non-power targets:** `project`, `events` and the form board still
  count power targets only. A follow-up gives every kind a load estimate.
- **RPE targets.**
- **Per-rep comparison:** it stays out for the reason ADR 0014 gives. The pace
  comparison reads the detected work reps together, as the power one does.
