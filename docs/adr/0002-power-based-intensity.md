# ADR 0002 — Intensity is power-based and per-sport

Status: accepted · 2026-08-01

Companion to [ADR 0000 §4](0000-architecture.md) (the mixed-model *load*). This one is
about *intensity* — the easy/moderate/hard split, polarization, and "hard minutes" — and
why it must come from power, not heart rate, for sports that have power.

## Context — the failure that forced this

For most of the project, intensity was derived **purely from HR zones**: "hard" = time in
HR Z4+Z5, and polarization from HR-zone seconds. For an athlete whose training is
power-based, this **systematically mislabels hard efforts as moderate**. Observed, not
theorized (2026-07-31):

- A 45-min ride the athlete rode *hard* showed **1 minute hard by HR** but **38 minutes
  at/above threshold by power** (NP 239W ≈ FTP, IF ~0.99). The coach called it "moderate"
  off the HR label; the athlete insisted it was hard. The athlete was right.
- 28-day polarization read **8% hard** by HR vs **~30%+ hard** by power.

Three compounding reasons HR-only fails here:
1. **Threshold HR sits on a zone boundary** — a genuine threshold effort hovers at the
   Z3/Z4 line and logs mostly as Z3 ("moderate").
2. **Power-zone rides are ridden at threshold power** but the athlete's HR doesn't always
   climb (fatigue, individual response, dropped straps).
3. **HR data has artifacts** — e.g. a cluster of phantom 200-209 bpm samples with a gap at
   190-199 (physiologically impossible → optical/strap noise). Never trust a raw max-HR
   reading; when power and HR conflict and power is near-FTP, trust power.

## Decision

- **Intensity comes from POWER for any sport that has a power stream**, judged against
  **that sport's own FTP**. `Metrics.time_in_power_intensity` splits stream time into
  easy (<76% FTP), moderate (76-90%), hard (≥91%). Summary polarization, the activities/
  week "hard" column, and the activity detail all read power-intensity when present and
  fall back to HR zones only when there's no power. TSS/IF are likewise judged against the
  sport's own FTP (so a rowing effort isn't scored against a cycling number).
- **Per-sport FTP is generic and data-driven — NO hardcoded sport list** (explicitly
  rejected during design; it silently drops swimming/soccer/paddleboard). The threshold key
  is per sport, never global (a rowing watt is not a cycling watt).

  > **Amended 2026-08-06.** This originally described `ftp_<sport>` as a config key that is
  > "auto-derived when unset", which left the door open to configuring it. That door is now
  > closed: FTP is **always** derived from that sport's own best-20-min power × 0.95 and
  > never read from config — `stride config set ftp_ride` is refused outright rather than
  > stored and ignored. ADR 0005 additionally anchors the derivation window to each
  > activity's own date. A no-power sport derives 0 and falls back to HR/RPE, unchanged.

## The honesty caveat (load-bearing — do not drop it)

These numbers are only as good as the FTPs feeding them, and the FTPs are **estimated from
non-maximal efforts** (the athlete rides controlled Power-Zone sessions and rarely tests
all-out). So a too-low FTP **inflates** "hard %" and load. Therefore:

- **Trust the direction, not the decimals.** "You're doing too much hard work" holds even
  if the true figure is 25% not 33% — but don't present a percentage as precise.
- Real FTP tests (per sport) tighten the absolutes; until then the coach reasons on
  direction and defers specific power-zone prescriptions.

This is the corrective to the original sin of the whole episode: the coach stated soft,
derived numbers as fact. The engine may compute; the coach must caveat.

## Consequences

- **Never regress to HR-only intensity** — it re-introduces the mislabeling. HR zones stay
  only as the fallback for no-power sports (strength, no-strap) and as a cross-sport lens.
- Adding a sport needs **no code and no config** — its FTP derives from its own power
  history the moment that history exists.
- Confidence tiers (ADR 0000 §4) annotate how much of the load is measured (power) vs
  estimated (HR/RPE), surfaced by `doctor` and as `measured_pct` on the fitness number.
- Recompute invalidation is per-sport: a change in one sport's derived FTP recomputes only that
  sport's rows (a generated `CASE` maps each sport to its FTP in the analyze filter).
