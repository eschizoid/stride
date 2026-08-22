Backfill :: [].{
    # ── the stream drain's pure half ────────────────────────────────────
    # Two things, both pure and both belonging to the drain loop in Strava.drain_streams!:
    # the rate-pacing DECISION (`decide`), and the vocabulary its outcome ships in
    # (`StopReason` + `stopped_label`). The loop is a thin effectful skin dispatching on
    # both, so every branch is unit-testable here.
    #
    # `decide` takes a response status and the per-run counters and returns the next
    # control-flow action. (Counting our own reads by choice, so pacing does not depend
    # on any endpoint sending rate-limit headers.)

    Limits : { reads_per_window : I64, reads_per_run : I64, max_consecutive_429 : I64 }

    # what to do after a successful fetch has been stored
    PostStore : [Continue, SleepWindow, StopRun]

    # Why a drain run ended — the value that ships as the payload's `stopped`.
    # A TAG, not a Str, so the COMPILER enforces the set at the producer: drain_streams!
    # cannot invent a fourth reason or typo an existing one. `stopped_label` below is the
    # single place it becomes a string, and its three arms are pinned by equality expects.
    # This shape was chosen after the Str version shipped pinned by nothing: Render's
    # expects hand-type their own literals, so they check Render against itself, and
    # renaming a literal in the producer left every test green.
    StopReason : [Complete, BudgetReached, RateLimited]

    Action : [
        Refresh, # 401: refresh the access token, retry the same id
        Backoff(I64), # 429 under the retry limit: sleep, retry same id, with this new retry count
        GiveUp, # 429 past the retry limit: a 15-min sleep won't clear a daily cap → stop
        Store({ done : I64, window : I64, after : PostStore }), # success: store, then advance
    ]

    decide : { status : U16, done : I64, window : I64, retries : I64 }, Limits -> Action
    decide = |s, lim|
        if s.status == 429 {
            if s.retries >= lim.max_consecutive_429 {
                GiveUp
            } else {
                Backoff(s.retries + 1)
            }
        } else if s.status == 401 {
            Refresh
        } else {
            # any other status is handled by the store step (404 → empty marker,
            # 2xx → body, other → error propagated there); here we just advance counters
            done2 = s.done + 1
            window2 = s.window + 1
            after =
                if done2 >= lim.reads_per_run {
                    StopRun
                } else if window2 >= lim.reads_per_window {
                    SleepWindow
                } else {
                    Continue
                }
            Store({ done: done2, window: window2, after })
        }

    # the ONE tag -> wire-string conversion. These three strings are also the enum in
    # schemas/v2/sync.json; changing one without the other is a contract break.
    stopped_label : StopReason -> Str
    stopped_label = |r|
        match r {
            Complete => "complete"
            BudgetReached => "budget_reached"
            RateLimited => "rate_limited"
        }

    test_lim : Limits
    test_lim = { reads_per_window: 3, reads_per_run: 5, max_consecutive_429: 2 }
}

# ── tests ───────────────────────────────────────────────────────────

# 429 under the limit backs off with an incremented retry count
expect match Backfill.decide({ status: 429, done: 0, window: 0, retries: 0 }, Backfill.test_lim) {
    Backoff(1) => True
    _ => False
}
expect match Backfill.decide({ status: 429, done: 1, window: 1, retries: 1 }, Backfill.test_lim) {
    Backoff(2) => True
    _ => False
}

# 429 at/over the limit gives up (assume daily cap — sleeping won't help)
expect match Backfill.decide({ status: 429, done: 3, window: 1, retries: 2 }, Backfill.test_lim) {
    GiveUp => True
    _ => False
}

# 401 asks for a token refresh
expect match Backfill.decide({ status: 401, done: 0, window: 0, retries: 0 }, Backfill.test_lim) {
    Refresh => True
    _ => False
}

# a normal fetch stores and continues, advancing both counters
expect match Backfill.decide({ status: 200, done: 0, window: 0, retries: 0 }, Backfill.test_lim) {
    Store({ done: 1, window: 1, after: Continue }) => True
    _ => False
}

# 404 takes the same store path (the marker write happens in app.roc)
expect match Backfill.decide({ status: 404, done: 0, window: 0, retries: 0 }, Backfill.test_lim) {
    Store({ done: 1, window: 1, after: Continue }) => True
    _ => False
}

# hitting the window cap stores, then sleeps
expect match Backfill.decide({ status: 200, done: 0, window: 2, retries: 0 }, Backfill.test_lim) {
    Store({ done: 1, window: 3, after: SleepWindow }) => True
    _ => False
}

# hitting the run budget stores, then stops (budget takes priority over a window sleep)
expect match Backfill.decide({ status: 200, done: 4, window: 0, retries: 0 }, Backfill.test_lim) {
    Store({ done: 5, window: 1, after: StopRun }) => True
    _ => False
}
expect match Backfill.decide({ status: 200, done: 4, window: 2, retries: 0 }, Backfill.test_lim) {
    Store({ done: 5, window: 3, after: StopRun }) => True
    _ => False
}

# a retry count on a successful fetch is irrelevant to the decision
expect match Backfill.decide({ status: 200, done: 0, window: 0, retries: 1 }, Backfill.test_lim) {
    Store({ done: 1, window: 1, after: Continue }) => True
    _ => False
}

# the wire strings, pinned by equality. These must equal the enum in
# schemas/v2/sync.json; Render.drain_note matches on the same three, and a
# composed expect there ties producer to consumer so a rename cannot pass either side.
expect Backfill.stopped_label(Complete) == "complete"
expect Backfill.stopped_label(BudgetReached) == "budget_reached"
expect Backfill.stopped_label(RateLimited) == "rate_limited"
