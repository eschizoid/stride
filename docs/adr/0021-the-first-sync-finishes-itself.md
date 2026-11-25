# 0021. the first sync finishes itself

Accepted 2026-11-25. Amends the stream drain's stop-and-rerun rule (`Drain.roc`, #246)
and the first-run steps of `stride setup`.

## Context

A new athlete's first sync owes one read per activity for its streams and one per GPS
route, against Strava's read limit of 100 requests every 15 minutes and 1,000 a day.
The engine counts its own reads, stops at 95 in a run, and tells the athlete to run
`stride sync` again "in ~15 minutes"; after a daily stop it says "tomorrow". `stride
analyze` has a fixed budget of passes and, on a large history, stops with
`converged: false` and asks to be run again. `stride setup` runs one sync and one
analyze, then leaves the rest to the athlete, and `stride setup --json` tells an agent
to "run `stride sync`, then `stride analyze`".

So a first run is a loop the athlete drives by hand, with two commands that each stop
partway and ask to be repeated. Three facts make it worse than it needs to be:

- Strava's 15-minute limit resets "at natural 15-minute intervals corresponding to 0,
  15, 30 and 45 minutes after the hour", and the daily limit "at midnight UTC"
  (developers.strava.com/docs/rate-limits). A stop at 10:14 can resume at 10:15; "~15
  minutes" overstates the wait, and an athlete who retries sooner finds it works.
- Every response carries `X-ReadRateLimit-Usage` (15-minute usage, daily usage), so the
  true usage is known after each read, including reads other apps made on the same
  token, which stride's own count cannot see.
- The expensive part is the streams. The activity list costs one read per page of
  activities, so a whole history's summaries arrive in a handful of reads; it is the
  per-activity stream and route fetches that span windows and days.

The stop-and-rerun rule was right for a routine sync: sleeping there blocked an
ordinary run for half an hour. It is wrong for a first sync, where waiting is exactly
what the athlete wants and re-running is busywork.

## Decision

1. **The list first, and analyzed at once.** A first sync pages the whole activity list
   before fetching any stream, then analyzes it, so summary-level load, form and every
   report work within the first window. Streams and routes follow and refine what is
   already there.

2. **A human sync waits instead of stopping, narrated as every other command is.** When
   the read window is spent and work is still owed, `stride sync` waits until the next
   quarter-hour mark (plus a short margin) and continues. Its progress goes through the
   narration ADR 0007 set up, on stderr: the fetches draw the same redrawn bar the
   other long steps draw (`Output.narrate!`, `[██████████] 11/11`), and the wait, which
   has no count, draws a spinner on that same line beside the local time the next
   batch starts and the time left. Machine mode gets plain lines, as narration already
   does. Ctrl-C stops it cleanly, and the next run resumes where it stopped, since
   every fetch is already stored as it lands. A routine sync owes less than a window
   and never waits.

3. **The headers set the pace.** Where Strava sends `X-ReadRateLimit-Usage`, it is the
   usage the engine paces by; its own count remains the fallback when the header is
   absent and the floor when the header reports less than the engine has spent. The test
   seams that can only lower a limit keep that property.

4. **The daily limit ends a run with an exact time.** When the day's reads are spent,
   sync stops and names the local time the allowance returns (midnight UTC), never
   "tomorrow" or "~15 minutes".

5. **Sync analyzes as data lands, to the end.** After each window's batch, sync runs
   analyze to its fixed point, so a partial history is always fully analyzed and no
   step asks the athlete to run `stride analyze`. `stride analyze` on its own also runs
   to its fixed point instead of stopping on a pass budget.

6. **Machine callers never block.** `--json` does not wait: each call does what the
   window allows, analyzes, and answers with what is still owed and the timestamp the
   next window opens, so an agent can schedule the next call instead of holding a
   shell for up to 15 minutes. `stride setup --json` reports the sync step the same
   way and no longer instructs a separate analyze.

7. **Setup runs the first sync to the end and proposes zones from the data.** `stride
   setup` runs the waiting sync of decision 2 with its progress line and never tells
   the athlete to run sync or analyze. Heart-rate zones move after the activity list:
   setup proposes a threshold heart rate estimated from the list's heart-rate fields,
   robust to a single session's strap spike, shows the zones it gives, and asks to use
   them or type a threshold or max heart rate instead. With no heart-rate data it asks
   as it does today. The timezone stays detected and confirmed as it is now.

8. **One narration shape for the whole sync.** Every step is one line with its label
   in a fixed-width column: a step with a count draws the bar, a step without one draws
   a single-width ASCII spinner (`|/-\`) that advances with each unit of work and is
   replaced by its result when the step ends. A single long call has no units to
   advance by, so its line holds still rather than pretending to move. Narration
   carries no explanations of rate limits or read budgets; those live in the docs. The
   run ends with one summary line, counts written in the singular or plural they
   need, and the form verdict, because analyze is now part of sync. A routine sync:

   ```terminaloutput
   $ stride sync
   activity list       25 checked, 1 new
   streams             [██████████] 1/1
   descriptions        [██████████] 11/11
   scoring             [██████████] 1/1
   synced 1 new activity, streams for 1, 11 strength descriptions; everything analyzed
   → today: form -1, down 4 from a week ago — balanced
   ```

   A first sync across a window, while it waits. The list's five pages are five reads of
   the first window, so the streams get the other 90; the bar pads its count to the
   width of the total, so a redrawn frame never leaves the tail of a longer one behind;
   and the batch is scored before the wait, as decision 5 has it:

   ```terminaloutput
   $ stride sync
   activity list       412 checked, 412 new
   scoring             [██████████] 412/412
   streams             [██░░░░░░░░]  90/412
   scoring             [██████████] 90/90
   waiting for Strava  / next batch at 10:45, 4:12 left
   ```

## Consequences

- The first-run experience is one command that ends with everything analyzed, or with
  an exact time the daily allowance returns.
- `drain_note` and the setup copy lose their "run again" instructions; the e2e
  `stops` driver's expectations change with them, and the mock server needs to send
  the rate-limit headers for decision 3 to be exercised.
- The wait is a new behaviour that must be testable without waiting: the clock and the
  sleep go behind a seam the e2e drivers can shorten, in the way the read limits already
  can only be lowered.
- Proposing zones needs a heart-rate value from the list. The activity list carries a
  session's maximum heart rate, which the `activities` mirror does not store today; it
  becomes a mirror column, re-pulled like the rest.
- An agent driving `--json` still makes several calls across a long first history, but
  each one says exactly when the next can run.
- Every doc and the coaching skill that tells a user or an agent to run
  `stride sync` and then `stride analyze` changes to `stride sync` alone; `stride
  analyze` stays as a command for a recompute without a sync.
