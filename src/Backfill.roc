module [Action, PostStore, Limits, decide]

# ── pure rate-pacing decision for the streams backfill ──────────────
# Given a response status and the current per-run counters, decide the next
# control-flow action. No effects — the effectful drain loop in app.roc dispatches
# on this, so every branch is unit-testable here. (Counting our own reads because
# basic-cli surfaces no rate-limit headers, and Strava's /streams endpoint sends
# none anyway.)

Limits : { reads_per_window : I64, reads_per_run : I64, max_consecutive_429 : I64 }

# what to do after a successful fetch has been stored
PostStore : [Continue, SleepWindow, StopRun]

Action : [
    Refresh, # 401: refresh the access token, retry the same id
    Backoff I64, # 429 under the retry limit: sleep, retry same id, with this new retry count
    GiveUp, # 429 past the retry limit: a 15-min sleep won't clear a daily cap → stop
    Store { done : I64, window : I64, after : PostStore }, # success: store, then advance
]

decide : { status : U16, done : I64, window : I64, retries : I64 }, Limits -> Action
decide = |s, lim|
    if s.status == 429 then
        if s.retries >= lim.max_consecutive_429 then
            GiveUp
        else
            Backoff(s.retries + 1)
    else if s.status == 401 then
        Refresh
    else
        # any other status is handled by the store step (404 → empty marker,
        # 2xx → body, other → error propagated there); here we just advance counters
        done2 = s.done + 1
        window2 = s.window + 1
        after =
            if done2 >= lim.reads_per_run then
                StopRun
            else if window2 >= lim.reads_per_window then
                SleepWindow
            else
                Continue
        Store({ done: done2, window: window2, after })

# ── tests ───────────────────────────────────────────────────────────

test_lim : Limits
test_lim = { reads_per_window: 3, reads_per_run: 5, max_consecutive_429: 2 }

# 429 under the limit backs off with an incremented retry count
expect decide({ status: 429, done: 0, window: 0, retries: 0 }, test_lim) == Backoff(1)
expect decide({ status: 429, done: 1, window: 1, retries: 1 }, test_lim) == Backoff(2)

# 429 at/over the limit gives up (assume daily cap — sleeping won't help)
expect decide({ status: 429, done: 3, window: 1, retries: 2 }, test_lim) == GiveUp

# 401 asks for a token refresh
expect decide({ status: 401, done: 0, window: 0, retries: 0 }, test_lim) == Refresh

# a normal fetch stores and continues, advancing both counters
expect decide({ status: 200, done: 0, window: 0, retries: 0 }, test_lim) == Store({ done: 1, window: 1, after: Continue })

# 404 takes the same store path (the marker write happens in app.roc)
expect decide({ status: 404, done: 0, window: 0, retries: 0 }, test_lim) == Store({ done: 1, window: 1, after: Continue })

# hitting the window cap stores, then sleeps
expect decide({ status: 200, done: 0, window: 2, retries: 0 }, test_lim) == Store({ done: 1, window: 3, after: SleepWindow })

# hitting the run budget stores, then stops (budget takes priority over a window sleep)
expect decide({ status: 200, done: 4, window: 0, retries: 0 }, test_lim) == Store({ done: 5, window: 1, after: StopRun })
expect decide({ status: 200, done: 4, window: 2, retries: 0 }, test_lim) == Store({ done: 5, window: 3, after: StopRun })

# a retry count on a successful fetch is irrelevant to the decision
expect decide({ status: 200, done: 0, window: 0, retries: 1 }, test_lim) == Store({ done: 1, window: 1, after: Continue })
