Drain :: [].{
    # ── the stream drain's pure half ────────────────────────────────────
    # Three things, all pure. Two belong to the drain loop in Strava.drain_streams!:
    # the rate-pacing DECISION (`decide`), and the vocabulary its outcome ships in
    # (`StopReason` + `stopped_label`). The third, `SyncStop`, does NOT belong to the
    # drain — it belongs to `sync!`, which is the whole point of it being a separate
    # type, and it lives here so the one wire vocabulary stays in one file. The loop is
    # a thin effectful skin dispatching on the first two, so every branch is
    # unit-testable here.
    #
    # `decide` takes a response status and the per-run counters and returns the next
    # control-flow action. (Counting our own reads by choice, so pacing does not depend
    # on any endpoint sending rate-limit headers.)

    # TWO limits, and they stop the run for different lengths of time. A run drains until
    # Strava's 15-minute read window is full, then stops and asks to be re-run — it does
    # NOT sleep to the next window, because that made a routine sync block ~30 minutes in
    # the foreground. It carries no separate per-RUN budget: `window` is never reset
    # inside a run, so a per-run cap of 940 against a window of 95 could never fire, and
    # review proved both arms dead by evaluating `decide` at production limits.
    #
    # The DAILY cap used to be "respected by arithmetic": ~95 reads per window × ~10
    # windows a day sits just under Strava's 1000. There are 96 fifteen-minute windows in
    # a day, not 10 — that sentence assumed the athlete runs sync about ten times, and
    # nothing enforced it. Least of all stride's own output, which after every stop said
    # "run `stride sync` again in ~15 minutes". Follow that and you do four runs an hour
    # at ~95 reads: 1000 is crossed in about two and a half hours, and every read for the
    # rest of the day is refused while stride keeps advising fifteen minutes. The one
    # case where the answer is TOMORROW was the one case it could not say.
    #
    # So it is counted now, against a persisted per-UTC-day total. Counting our own reads
    # rather than reading rate-limit headers is the same choice `decide` already makes for
    # the window, for the same reason: pacing does not depend on any endpoint sending
    # them. It is an approximation — anything else using the same token is invisible to
    # us — but it is the approximation stride was already making, with the count kept
    # instead of thrown away.
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

    # Why a SYNC run ended — the value behind the payload's `stopped` field, which itself
    # carries the Str this maps to; the tag never crosses that boundary. Wider than
    # StopReason by one inhabitant, because one thing stops a sync without being a drain
    # reason: the activity LIST was refused, which happens before the drain runs at all.
    #
    # WRAPPING rather than adding a fourth arm to StopReason is the whole point. A fourth
    # arm would also be in scope at the three sites where drain_streams! constructs a
    # `stopped` value, so the compiler would accept a drain claiming a list refusal —
    # losing the exact guarantee the tag was introduced for. Here drain_streams! still
    # returns a StopReason and cannot name ListRateLimited at all; only sync!, which
    # issues both requests, does.
    #
    # The alternative to a distinct arm was reusing RateLimited for both. That left the
    # payload unable to say WHICH request was refused, and Render physically unable to
    # write the right sentence, because the only distinction available to it was
    # `pending_streams > 0` — which is true on precisely the first-run sync this case
    # exists for. A drain that 429s on its first id and a list that 429s on page one are
    # otherwise identical in the envelope.
    # ListDailyCapReached is the LIST refused with the day already spent, and it exists
    # because folding it into FromDrain(DailyCapReached) cost the one fact this arm carries.
    # An earlier version did exactly that and argued the cost was acceptable. It is not:
    # `FromDrain(_)` renders only when `pending_streams > 0`, so on the empty queue — which
    # is the steady state, and the state a capped day reaches — the human line went EMPTY.
    # Measured: the same fixture, same 429ing list, only the counter differing, printed the
    # full "the list is incomplete, run again in ~15 minutes" sentence at 0 reads and
    # nothing at all at 9. That is a strict regression of #235 caused by #246, and it is the
    # second time this exact position has been wrong — the comment on sync_screen's tail
    # already records the first.
    #
    # Two facts, so two of them have to survive: the listing is incomplete (#235) and the
    # remedy is tomorrow rather than fifteen minutes (#246). One tag cannot carry both
    # unless Render is allowed to guess, and the whole point of this type is that it is not.
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
            # WHICH limit did we hit? A 429 with the day's allowance already spent is the
            # daily cap, and saying "try again in ~15 minutes" there is the instruction
            # that cannot succeed — the whole of #246, printed in the exact state #246
            # exists to describe.
            #
            # This arm is a BACKSTOP, not the mechanism, and this comment used to claim the
            # opposite — "what makes the feature reachable at all", on the reasoning that
            # stride's count is always at or below Strava's so Strava refuses first. That
            # was true while only stream reads were counted. Once `charge_read!` began
            # counting the LIST read too, the Store arm's DayFull branch reaches the cap on
            # the correct path, with no 429 at all, which is the path the feature is for.
            # The sentence survived the change that falsified it by one commit.
            #
            # It still earns its place: stride's count can drift under Strava's — anything
            # else using the same token is invisible here — and when it does, this is what
            # tells the 429 apart from a window refusal so the remedy is tomorrow rather
            # than fifteen minutes.
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

    # A drain can outlive UTC midnight, and when it does the allowance REALLY HAS reset —
    # so the honest model is to notice, not to carry the old day to the end of the run.
    #
    # Captured-once was the first version and it was wrong in both directions at once.
    # Start at 23:58 with 990 of 1000 spent, cross midnight at read 5, hit the cap at read
    # 10: the athlete is told "run `stride sync` again tomorrow" at 00:01, sixty seconds
    # after the allowance reset, and the next run works immediately. That is #246's own
    # defect — advice that cannot succeed — reintroduced by #246's own fix. And the ten
    # reads spent after midnight were stamped to the day before, so the new day began
    # already owing them and would overshoot its cap by that many.
    #
    # Pure, and here rather than inline in the drain loop, so both directions are pinned by
    # expects instead of by a fixture that would need a fake clock to build. Note what that
    # does and does not cover: the RULE is pinned, the CALL is not — deleting the call site
    # in Strava.drain_streams! leaves every driver green, because reaching the reset arm
    # needs a clock that moves mid-drain and the repo has no seam for one.
    #
    # BACKWARDS is treated the same as forwards, and that is a default rather than a
    # decision. Forwards the allowance genuinely reset, so zeroing is free. Backwards it did
    # not: stride hands out a fresh allowance while Strava still counts the old one, and the
    # 429s that follow are then read as a WINDOW refusal — "~15 minutes", the wrong remedy,
    # which is #246. It needs a clock to move back a whole day (a wrong RTC at boot that
    # then NTP-syncs is the realistic shape), and the conservative alternative is one token:
    # take the new day, keep the count. Left permissive because the reset path is the one
    # that matters and a stale stamp already resets on any mismatch — but the expect below
    # pins the permissive answer, so it should read as chosen rather than as settled.
    roll_day : { day : I64, today : I64 }, I64 -> { day : I64, today : I64 }
    roll_day = |st, now_day| if now_day == st.day st else { day: now_day, today: 0 }

    test_lim : Limits
    test_lim = { reads_per_window: 3, reads_per_day: 100 }
}

# ── tests ───────────────────────────────────────────────────────────

# a 429 stops the run outright. It does NOT sleep and retry: that made a routine sync
# block ~30 minutes in the foreground, measured, on a two-activity queue.
# the DAILY arms, at their boundaries. Neither existed as a pure expect until review
# pointed out that this function's own header calls the pacing decision "pure, unit-tested"
# while the two branches this feature added were reachable only through the e2e — the
# slowest and most environment-dependent layer, and the one where the 429 pair took three
# attempts to get right. Boundary pairs, mirroring the window's own 2 -> Continue /
# 3 -> WindowFull shape.
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
