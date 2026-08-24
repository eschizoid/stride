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

    # ONE limit: the collapse in #232 left a single stop mechanism. A run drains until
    # Strava's 15-minute read window is full, then stops and asks to be re-run. It does
    # NOT sleep to the next window — that made a routine sync block ~30 minutes in the
    # foreground — and it does not carry a separate per-run budget either: `window` is
    # never reset within a run, so a per-run cap of 940 against a window of 95 could
    # never fire. Review proved both arms dead by evaluating `decide` at production
    # limits. The DAILY cap is respected by arithmetic rather than by a counter: ~95
    # reads per window × ~10 windows a day sits just under Strava's 1000.
    Limits : { reads_per_window : I64 }

    # what to do after a successful fetch has been stored. WindowFull, not SleepWindow —
    # nothing sleeps, and a tag named for behaviour the code does not have is how the
    # next reader gets it wrong.
    PostStore : [Continue, WindowFull]

    # Why a DRAIN run ended. A TAG, not a Str, so the COMPILER enforces the set at the
    # producer: drain_streams! cannot invent a fourth reason or typo an existing one.
    # This shape was chosen after the Str version shipped pinned by nothing: Render's
    # expects hand-type their own literals, so they check Render against itself, and
    # renaming a literal in the producer left every test green.
    StopReason : [Complete, BudgetReached, RateLimited]

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
    SyncStop : [FromDrain(StopReason), ListRateLimited]

    Action : [
        Refresh, # 401: refresh the access token, retry the same id (bounded by the caller)
        RateLimited, # 429: stop and report; the caller does not sleep or retry
        Store({ window : I64, after : PostStore }), # success: store, then advance
    ]

    # Counting our own reads BY CHOICE, so pacing never depends on an endpoint sending
    # rate-limit headers. A 429 is a backstop for when our count and Strava's disagree,
    # not the mechanism.
    decide : { status : U16, window : I64 }, Limits -> Action
    decide = |s, lim|
        if s.status == 429 {
            RateLimited
        } else if s.status == 401 {
            Refresh
        } else {
            # any other status is handled by the store step (404 → empty marker,
            # 2xx → body, other → error propagated there); here we just advance counters
            window2 = s.window + 1
            after = if window2 >= lim.reads_per_window WindowFull else Continue
            Store({ window: window2, after })
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
        }

    sync_stopped_label : SyncStop -> Str
    sync_stopped_label = |s|
        match s {
            FromDrain(r) => stopped_label(r)
            ListRateLimited => "list_rate_limited"
        }

    # The inverse, so the CONSUMER's handling is checked by the compiler instead of by a
    # list someone has to remember to extend. `stopped` reaches Render as a Str — the
    # payload is JSON and Output derives it from a record, so a tag field would encode as
    # an object rather than sync.json's flat enum string, and stringifying at the producer
    # is forced. Render therefore cannot match on the tag; it can only match on this.
    #
    # Why it is worth the fifteen lines: review added a fifth arm to SyncStop, and
    # `roc check` stayed clean, 383 Render expects and 14 Drain expects all passed, and
    # the new reason shipped to the user raw — `"... fetched streams for 2 — auth_expired
    # — 9 to go"` — or vanished from the line entirely when the queue was empty. The guard
    # that was supposed to prevent that enumerated its labels by hand, and a hand-written
    # list does not grow when the type does. With `sync_screen` matching on this instead,
    # a fifth arm is a non-exhaustive-match error in Render before it can reach anyone.
    #
    # Unknown is not dead: `stopped` is a string from a JSON payload, so a value produced
    # by a different build is representable. It renders verbatim rather than being guessed
    # into one of the four.
    stop_of_label : Str -> [Known(SyncStop), Unknown(Str)]
    stop_of_label = |s|
        match List.find_first(all_stops, |t| sync_stopped_label(t) == s) {
            Ok(t) => Known(t)
            Err(_) => Unknown(s)
        }

    # THE list. Roc cannot enumerate a tag union, so exactly one hand-written copy of the
    # four inhabitants is unavoidable — this is it, and it sits directly under SyncStop so
    # the thing that changes and the list that must change with it are one line apart.
    #
    # There were three copies before, in two files: this parser's if-chain, and both of
    # Render's sweeps. Two independent reviews found the same failure from opposite ends —
    # adding a fifth arm gave the compile error the design promised, and a maintainer who
    # fixed exactly what the compiler named still shipped the raw wire token to the user,
    # because nothing made them extend the parser. That is the hand-written-list criticism
    # this design was built to answer, relocated rather than removed. Folding the parser
    # over `all_stops` makes it agree with the producer by construction; the Render sweeps
    # now consume this too, so a fifth arm has one place to be added and every guard that
    # depends on the set grows with it.
    #
    # The `expect` below is what makes this list honest — it is the one thing here that a
    # missing entry breaks.
    all_stops : List(SyncStop)
    all_stops = [FromDrain(Complete), FromDrain(BudgetReached), FromDrain(RateLimited), ListRateLimited]

    test_lim : Limits
    test_lim = { reads_per_window: 3 }
}

# ── tests ───────────────────────────────────────────────────────────

# a 429 stops the run outright. It does NOT sleep and retry: that made a routine sync
# block ~30 minutes in the foreground, measured, on a two-activity queue.
expect match Drain.decide({ status: 429, window: 0 }, Drain.test_lim) {
    RateLimited => True
    _ => False
}
expect match Drain.decide({ status: 429, window: 2 }, Drain.test_lim) {
    RateLimited => True
    _ => False
}

# 401 asks for a token refresh; the CALLER bounds how many it will spend
expect match Drain.decide({ status: 401, window: 0 }, Drain.test_lim) {
    Refresh => True
    _ => False
}

# a normal fetch stores and continues, advancing both counters
expect match Drain.decide({ status: 200, window: 0 }, Drain.test_lim) {
    Store({ window: 1, after: Continue }) => True
    _ => False
}

# 404 takes the same store path (the marker write happens in the drain)
expect match Drain.decide({ status: 404, window: 0 }, Drain.test_lim) {
    Store({ window: 1, after: Continue }) => True
    _ => False
}

# filling the window stores, then ends the run. This is the arm production actually
# takes — `window` is never reset inside a run, so it is the only way a drain stops
# short, and the previous model's per-run cap could never fire ahead of it.
expect match Drain.decide({ status: 200, window: 2 }, Drain.test_lim) {
    Store({ window: 3, after: WindowFull }) => True
    _ => False
}

# and it stays WindowFull past the boundary rather than wrapping back to Continue
expect match Drain.decide({ status: 200, window: 9 }, Drain.test_lim) {
    Store({ window: 10, after: WindowFull }) => True
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
