# 0020. threshold tests anchor a family's threshold

Accepted 2026-11-11 (#639). Amends ADR 0005 (thresholds in force when an activity happened) and ADR 0002 (derived FTP).

## Context

Every threshold the engine scores by is derived from a rolling window: a sport family's
best 20-minute power × 0.95 over 60 days, and a sport type's best 20-minute speed
× 0.95 over the same span. The derivation only sees whatever efforts happened. An
athlete whose training is steady class work never produces a maximal 20 minutes, so the
estimate sits below their real threshold, and the window's critical-power fit has no
maximal points to fit through. A deliberate test is the best evidence an athlete can
produce, and nothing in the engine could tell it apart from any other session.

## Decision

1. **A test is a judgment-tier row.** `stride test <activity_id> <kind>` stores the
   session, the kind and the threshold it yields in `threshold_tests`. The value is
   computed once, when the test is marked, from the session's stored streams with the
   filters analyze scores by, so a later stream re-pull cannot move a number the athlete
   accepted. `stride test remove` deletes the row.

2. **Kinds per signal, for every sport.** `ftp20`, `ramp` and `cp3-12` read a measured
   power stream and set a power threshold for the session's sport family, whatever the
   family. `css` is a swim protocol and `5k` / `3k` run protocols; they read the
   distance stream and set a threshold speed for the session's sport type, the same
   population the derived threshold pace uses. `tt30` reads the heart-rate stream and
   yields a lactate-threshold heart rate. A kind on a sport its protocol does not
   belong to, or on a session missing the stream it reads, is refused by name.

3. **Higher of the two, for 90 days.** For an activity on or after a test's date and
   inside 90 days of it, the threshold in force is the higher of the derivation and the
   newest test of the activity's population. A later test replaces an earlier one, even
   when it is lower. A higher derivation still wins, since it is newer evidence of
   fitness. Past 90 days the derivation alone returns, so an old test cannot hold a
   detrained athlete's threshold up. analyze applies this through the same SQL in its
   SELECT and its recompute WHERE, so marking or removing a test rescores exactly the
   sessions it moves.

4. **Heart rate changes zones only on request.** A `tt30` threshold changes no scoring
   by itself. `--apply-zones` writes the per-sport zone ceilings for every sport type in
   the session's family from Friel's percentages of LTHR (85, 89, 94, 99), and the zone
   signature analyze already compares rescores the family.

5. **The surfaces say which number they show.** `summary.ftp` and `zones` carry
   `source` (`test` or `derived`) and the test's kind and date; `power-curve` and
   `pace-curve` carry the test in force for the named sport's family. The window's
   power and pace curves draw a test's threshold when the window's own fit is not
   usable, and the career spine marks the months tests set.

## Consequences

- The tested threshold scores every session of its population for 90 days, so a test
  done badly holds a low threshold that long, unless a higher derivation overrides it
  or the athlete removes the test.
- A test row whose activity is later deleted from Strava drops out with it: every read
  joins `activities`.
- The 90-day span is a constant, `Metrics.test_in_force_days`, spliced into analyze's
  SQL, so changing it rescores every affected activity on the next analyze.

## Not doing

- Fitting CP or CS through a test's own efforts. The window draws the test's threshold
  instead of an unusable fit; refitting is a separate change.
- Pace tests on walk or row families. `5k` and `3k` are running protocols, and `css` a
  swimming one; a protocol for another family needs its own kind.
