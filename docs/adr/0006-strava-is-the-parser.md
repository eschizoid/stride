# ADR 0006 — Strava is the parser; the ingestion boundary is the filesystem

Status: proposed · 2026-08-09 — decision made by Mariano during the roadmap grill;
written up for his review, not yet blessed as accepted

Refines ADR 0000's "Strava is one ingestion layer." It answers the question that ADR
left open: which *other* ingestion layers stride will grow — and the answer is none
that parse device formats.

## Context

The roadmap's ingestion tier originally centered on native FIT import: hand-rolling a
binary parser so stride could read device files directly, at full resolution, without a
Strava subscription. Grilling it surfaced three facts:

1. **Most activities in stride's actual circle are fileless.** Peloton pushes to Strava
   server-to-server; phone-app recordings yield GPX at best. FIT files exist only where
   a Garmin-class device wrote one, and no current user is known to own one.
2. **Free and paid Strava serve the same data with full retention.** The June-2026
   developer-program change gated *holding API credentials* behind a subscription; it
   did not tier the data. The bulk export remains free for every account.
3. **A FIT parser is the largest build on the roadmap in the riskiest place** — a
   binary format with hundreds of message types, in a language with no FIT library and
   a compiler currently pinned around a miscompilation (roc-lang/roc#10693).

Meanwhile every device vendor already syncs to Strava, which normalizes a hundred
formats into the two outputs stride already consumes.

## Decision

**Strava is the parser.** Stride ingests exactly two Strava outputs — the API (JSON
activities + streams) and the bulk export (CSV summaries) — and never parses a raw
device format (FIT, TCX, GPX).

**The ingestion boundary is the filesystem plus that one API.** Where a device uploads
its data — Garmin Connect, Wahoo, Peloton's servers — is between the athlete and their
vendor. Stride reads what is on disk or what the Strava API serves, and nothing else:
no vendor-cloud integrations, no OAuth zoo, ever. Strava is grandfathered because it
already exists and is an aggregator, not a device vendor.

## Prices, paid knowingly

- **The free path stays summary-level.** The bulk export's stream data lives inside
  original device files stride declines to parse, so `stride import` users get CSV
  summaries: totals and averages, no zones, no NP, no interval detection on that
  history. Full-resolution stride requires the API path and therefore (post June 2026)
  a Strava subscription. This closes issue #6's stream-import ambition as long as this
  ADR stands.
- **Single-artery dependence.** Stride's stream data flows through one company that has
  already tightened terms once. Accepted with open eyes rather than hedged at the cost
  of a parser nobody currently needs.

## Re-argue clauses

Reopen this decision only on a real event, not on speculation:

1. Strava squeezes API terms again (pricing, rate limits, data access), or
2. a real user arrives who cannot use Strava at all, or
3. a maintained Roc FIT-parsing library appears, collapsing the build cost.

## What this kills

The FIT dedupe ADR, the minimal-decoder spike, and the roadmap's largest compiler-risk
exposure. The roadmap shrank and got more certain — every remaining item starts from
data stride already holds.
