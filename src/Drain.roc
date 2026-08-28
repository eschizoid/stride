Drain :: [].{
    # ── the stream drain's pure half ────────────────────────────────────
    # Three things, all pure: the rate-pacing DECISION (`decide`), its wire
    # vocabulary (`StopReason` + `stopped_label`), and `SyncStop`, which belongs to
    # `sync!` but lives here so the one wire vocabulary stays in one file. The loop
    # in Strava.drain_streams! is a thin effectful skin, so every branch is
    # unit-testable here. Counting our own reads by choice — pacing never depends
    # on an endpoint sending rate-limit headers.
    #
    # TWO limits, stopping the run for different lengths. A run drains until the
    # 15-minute window fills, then stops and asks to be re-run (sleeping blocked a
    # routine sync ~30 min). No separate per-run budget: `window` never resets
    # inside a run, so a per-run cap could never fire — both arms proved dead.
    # The DAILY cap used to be "respected by arithmetic" (~10 runs/day assumed,
    # nothing enforcing it — least of all stride's own "run again in ~15 minutes",
    # which crosses 1000 reads in ~2.5 hours if followed). Now counted against a
    # persisted per-UTC-day total: an approximation (other users of the token are
    # invisible), but the approximation stride was already making, kept.
    Limits : { reads_per_window : I64, reads_per_day : I64 }

    # what to do after a successful fetch has been stored. WindowFull, not SleepWindow —
    # nothing sleeps, and a tag named for behaviour the code does not have is how the
    # next reader gets it wrong.
    PostStore : [Continue, WindowFull, DayFull]

    # Why a DRAIN run ended. A TAG, not a Str, so the COMPILER enforces the set at the
    # producer: drain_streams! cannot invent a fourth reason or typo an existing one.
    # This shape was chosen after the Str version shipped pinned by nothing: Render's
    # expects hand-type their own literals, so they check Render against itself, and
    # renaming a literal in the producer left every test green.
    StopReason : [Complete, BudgetReached, RateLimited, DailyCapReached]

    # Why a SYNC run ended — the value behind the payload's `stopped` field. Wider
    # than StopReason by one inhabitant: the activity LIST can be refused before the
    # drain runs. WRAPPING rather than a fourth StopReason arm is the point — a
    # fourth arm would be in scope where drain_streams! constructs `stopped`, so the
    # compiler would accept a drain claiming a list refusal. Here drain_streams!
    # cannot name ListRateLimited at all; only sync!, which issues both requests.
    # Reusing RateLimited for both left Render unable to write the right sentence:
    # its only discriminator was `pending_streams > 0`, true on precisely the
    # first-run sync this case exists for.
    #
    # ListDailyCapReached exists because folding it into FromDrain(DailyCapReached)
    # cost the one fact it carries: `FromDrain(_)` renders only when pending > 0, so
    # on the empty queue — the steady state, and the state a capped day reaches —
    # the human line went EMPTY. Two facts must survive: the listing is incomplete
    # (#235) AND the remedy is tomorrow (#246). One tag cannot carry both unless
    # Render guesses, and the point of this type is that it does not.
    SyncStop : [FromDrain(StopReason), ListRateLimited, ListDailyCapReached]

    Action : [
        Refresh, # 401: refresh the access token, retry the same id (bounded by the caller)
        RateLimited, # 429 with allowance left: stop and report; the caller does not sleep
        DailyCapReached, # 429 with the day spent: the same stop, a different remedy
        Store({ window : I64, today : I64, after : PostStore }), # success: store, then advance
    ]

    # Counting our own reads BY CHOICE, so pacing never depends on an endpoint sending
    # rate-limit headers. A 429 is a backstop for when our count and Strava's disagree,
    # not the mechanism.
    decide : { status : U16, window : I64, today : I64 }, Limits -> Action
    decide = |s, lim|
        if s.status == 429 {
            # WHICH limit did we hit? A 429 with the day's allowance spent is the daily cap,
            # and "~15 minutes" there is the instruction that cannot succeed (#246).
            # A BACKSTOP, not the mechanism: since `charge_read!` counts the LIST read too,
            # the Store arm's DayFull branch reaches the cap on the correct path with no 429
            # at all. This arm still earns its place because stride's count can drift UNDER
            # Strava's (anything else on the same token is invisible), and when it does,
            # this tells the 429 apart from a window refusal.
            if s.today >= lim.reads_per_day {
                DailyCapReached
            } else {
                RateLimited
            }
        } else if s.status == 401 {
            Refresh
        } else {
            # any other status is handled by the store step (404 → empty marker,
            # 2xx → body, other → error propagated there); here we just advance counters
            window2 = s.window + 1
            today2 = s.today + 1
            # DAY before WINDOW, because they mean different things to the user and the
            # longer one wins. A run that fills both should say "tomorrow", not "fifteen
            # minutes" — waiting fifteen minutes when the daily cap is spent is an
            # instruction that cannot succeed, which is the whole of #246.
            after =
                if today2 >= lim.reads_per_day {
                    DayFull
                } else if window2 >= lim.reads_per_window {
                    WindowFull
                } else {
                    Continue
                }
            Store({ window: window2, today: today2, after })
        }

    # The tag <-> wire-string vocabulary, in one place. `sync_stopped_label` is the only
    # PRODUCTION entry point — both payload sites in Strava.sync! go through it, and it
    # delegates the three drain reasons to `stopped_label` rather than restating them, so
    # a rename cannot land on one spelling only. `stopped_label` exists for the narrower
    # domain: Render.drain_note handles drain reasons and nothing else, and its expects
    # say so by composing against this rather than against the wider function.
    # These four strings are also the enum in schemas/v2/sync.json; changing one without
    # the other is a contract break.
    stopped_label : StopReason -> Str
    stopped_label = |r|
        match r {
            Complete => "complete"
            BudgetReached => "budget_reached"
            RateLimited => "rate_limited"
            DailyCapReached => "daily_cap_reached"
        }

    sync_stopped_label : SyncStop -> Str
    sync_stopped_label = |s|
        match s {
            FromDrain(r) => stopped_label(r)
            ListRateLimited => "list_rate_limited"
            # Its OWN token, not `daily_cap_reached`. A consumer reading the payload has to
            # be able to tell "the listing is incomplete AND the day is spent" from "the
            # drain stopped on the day", because the first means rows are missing and the
            # second does not. That is the same reason `list_rate_limited` is not
            # `rate_limited`.
            ListDailyCapReached => "list_daily_cap_reached"
        }

    # A drain can outlive UTC midnight, and when it does the allowance REALLY HAS
    # reset — notice, don't carry the old day. Captured-once was wrong both ways:
    # "come back tomorrow" sixty seconds after the reset, and the post-midnight
    # reads stamped to the day before so the new day began already owing them.
    #
    # Pure, so both directions are pinned by expects with no fake clock. The RULE is
    # pinned, the CALL is not: deleting the call site leaves every driver green,
    # because reaching the reset arm needs a clock that moves mid-drain.
    #
    # BACKWARDS is treated the same as forwards, a default rather than a decision:
    # backwards, stride hands out a fresh allowance while Strava still counts the
    # old one, and the 429s read as a window refusal. It needs the clock to move
    # back a whole day (wrong RTC then NTP). The expect pins the permissive answer
    # so it reads as chosen rather than settled.
    roll_day : { day : I64, today : I64 }, I64 -> { day : I64, today : I64 }
    roll_day = |st, now_day| if now_day == st.day st else { day: now_day, today: 0 }

    test_lim : Limits
    test_lim = { reads_per_window: 3, reads_per_day: 100 }
}

# ── tests ───────────────────────────────────────────────────────────
# a 429 stops the run outright — sleep-and-retry blocked a routine sync ~30
# minutes in the foreground, measured, on a two-activity queue.
# the DAILY arms at their boundaries, as pure expects: the two branches this
# feature added were reachable only through the e2e, the slowest layer, while
# the header called the decision "pure, unit-tested".
expect match Drain.decide({ status: 429, window: 0, today: 99 }, Drain.test_lim) {
    RateLimited => True
    _ => False
}

expect match Drain.decide({ status: 429, window: 0, today: 100 }, Drain.test_lim) {
    DailyCapReached => True
    _ => False
}

expect match Drain.decide({ status: 200, window: 0, today: 98 }, Drain.test_lim) {
    Store({ after: Continue, .. }) => True
    _ => False
}

expect match Drain.decide({ status: 200, window: 0, today: 99 }, Drain.test_lim) {
    Store({ after: DayFull, .. }) => True
    _ => False
}

# ...and the DAY wins when both are full, which is the ordering the remedy depends on:
# a run that fills both should say tomorrow, not fifteen minutes.
expect match Drain.decide({ status: 200, window: 2, today: 99 }, Drain.test_lim) {
    Store({ after: DayFull, .. }) => True
    _ => False
}

expect match Drain.decide({ status: 429, window: 0, today: 0 }, Drain.test_lim) {
    RateLimited => True
    _ => False
}
expect match Drain.decide({ status: 429, window: 2, today: 2 }, Drain.test_lim) {
    RateLimited => True
    _ => False
}

# 401 asks for a token refresh; the CALLER bounds how many it will spend
expect match Drain.decide({ status: 401, window: 0, today: 0 }, Drain.test_lim) {
    Refresh => True
    _ => False
}

# a normal fetch stores and continues, advancing both counters
expect match Drain.decide({ status: 200, window: 0, today: 0 }, Drain.test_lim) {
    Store({ window: 1, today: 1, after: Continue }) => True
    _ => False
}

# 404 takes the same store path (the marker write happens in the drain)
expect match Drain.decide({ status: 404, window: 0, today: 0 }, Drain.test_lim) {
    Store({ window: 1, today: 1, after: Continue }) => True
    _ => False
}

# filling the window stores, then ends the run. This is the arm production actually
# takes — `window` is never reset inside a run, so it is the only way a drain stops
# short, and the previous model's per-run cap could never fire ahead of it.
expect match Drain.decide({ status: 200, window: 2, today: 2 }, Drain.test_lim) {
    Store({ window: 3, today: 3, after: WindowFull }) => True
    _ => False
}

# and it stays WindowFull past the boundary rather than wrapping back to Continue
expect match Drain.decide({ status: 200, window: 9, today: 9 }, Drain.test_lim) {
    Store({ window: 10, today: 10, after: WindowFull }) => True
    _ => False
}

# the wire strings, pinned by equality. These must equal the enum in
# schemas/v2/sync.json; Render.drain_note matches on the same three, and a
# composed expect there ties producer to consumer so a rename cannot pass either side.
expect Drain.stopped_label(Complete) == "complete"
expect Drain.stopped_label(BudgetReached) == "budget_reached"
expect Drain.stopped_label(RateLimited) == "rate_limited"

# the fourth string has no StopReason to come from — it is reachable only through
# SyncStop, which is the type-level statement that a drain cannot produce it.
expect Drain.sync_stopped_label(ListRateLimited) == "list_rate_limited"

# and the wrapper DELEGATES rather than restating: these fail if sync_stopped_label
# ever grows its own copy of the three drain strings and the two spellings drift.
expect Drain.sync_stopped_label(FromDrain(Complete)) == Drain.stopped_label(Complete)
expect Drain.sync_stopped_label(FromDrain(BudgetReached)) == Drain.stopped_label(BudgetReached)
expect Drain.sync_stopped_label(FromDrain(RateLimited)) == Drain.stopped_label(RateLimited)

# ...and the fifth, for the same reason one layer along: only sync! can name a LIST refusal
# that also spent the day, so this string cannot come from a drain either.
expect Drain.sync_stopped_label(ListDailyCapReached) == "list_daily_cap_reached"

# the midnight roll, both directions. The reset one is the arm that matters — a drain in
# flight when the allowance resets must notice, or it advises "come back tomorrow" on a day
# that has already started and stamps the new day with reads it did not spend.
expect Drain.roll_day({ day: 20690, today: 995 }, 20690) == { day: 20690, today: 995 }
expect Drain.roll_day({ day: 20690, today: 995 }, 20691) == { day: 20691, today: 0 }
# ...and it never runs BACKWARDS into a count. A clock that jumps back a day resets too:
# the count belongs to the day it is stamped with, and a stamp that disagrees is not a
# count this run may spend against.
expect Drain.roll_day({ day: 20691, today: 995 }, 20690) == { day: 20690, today: 0 }
