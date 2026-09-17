# ADR 0006. Strava is the parser; the ingestion boundary is the filesystem

Status: Accepted
Date: 2026-08-09
Note: Mariano approved the decision, and the FIT track stays retired.

ADR 0006 refines ADR 0000's "Strava is one ingestion layer." It answers the question that
ADR 0000 left open, which is which other ingestion layers stride will grow. The answer is
none that parse device formats.

## Context

The roadmap's ingestion tier originally centered on native FIT import. The plan was to
hand-roll a binary parser so stride could read device files directly, at full resolution,
and without a Strava subscription. Reviewing the plan surfaced three facts.

1. Most activities in stride's actual circle produce no device file. Peloton pushes to
   Strava from server to server, and phone-app recordings yield GPX at best. FIT files
   exist only where a Garmin-class device wrote one, and no current user is known to own
   one.
2. Free and paid Strava serve the same data with full retention. The June 2026
   developer-program change gated holding API credentials behind a subscription, and it did
   not tier the data. The bulk export remains free for every account.
3. A FIT parser is the largest build on the roadmap and sits in the riskiest place. It is a
   binary format with hundreds of message types, in a language with no FIT library, on a
   compiler that was pinned around a miscompilation when this was written
   (roc-lang/roc#10693). The pin moved on 2026-08-17 and the constraint is gone.

Meanwhile every device vendor already syncs to Strava, and Strava normalizes a hundred
formats into the two outputs stride already consumes.

## Decision

Strava is the parser. Stride ingests exactly two Strava outputs, which are the API with
JSON activities and streams, and the bulk export with CSV summaries. Stride never parses a
raw device format such as FIT, TCX or GPX.

The ingestion boundary is the filesystem plus that one API. Where a device uploads its
data, whether to Garmin Connect, Wahoo or Peloton's servers, is between the athlete and
their vendor. Stride reads what is on disk or what the Strava API serves and nothing else,
so there are no vendor-cloud integrations and no further OAuth providers, ever. Strava is
grandfathered in because it already exists and because it is an aggregator rather than a
device vendor.

## Accepted costs

The free path stays at summary level. The bulk export's stream data lives inside original
device files that stride declines to parse, so `stride import` users get CSV summaries.
The summaries carry totals and averages, with no zones, no NP and no interval detection
on that history. Full-resolution stride requires the API path and therefore requires a
Strava subscription after June 2026. Issue #6's stream-import ambition is closed as long as
this ADR stands.

Stride depends on a single supplier. Its stream data flows through one company that has
already tightened terms once. The dependence is accepted knowingly rather than hedged at
the cost of a parser nobody currently needs.

## When to reopen this decision

Reopen this decision only on a real event rather than on speculation. Three events qualify.

1. Strava tightens API terms again, whether on pricing, rate limits or data access.
2. A real user arrives who cannot use Strava at all.
3. A maintained Roc FIT-parsing library appears and collapses the build cost.

## What the decision removes from the roadmap

The decision removes the FIT dedupe ADR, the minimal-decoder spike, and the roadmap's
largest exposure to compiler risk. The roadmap shrank and became more certain, because
every remaining item starts from data stride already holds.

## Update, 2026-09-17

The compiler constraint named in the third context fact has weakened further. Both binaries
now build on `nightly-2026-09-16`, so the engine and the window share one compiler, and ADR
0017 records that measurement. The decision is unaffected, because the case for it never
rested on the compiler alone.
