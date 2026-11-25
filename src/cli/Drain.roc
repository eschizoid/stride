Drain :: [].{
	# ── the stream drain's pure half ────────────────────────────────────
	# Every decision the sync loop makes about Strava's read limits, all pure:
	# the per-read pacing (`decide`), what the rate-limit headers report
	# (`usage_of`), when the next read window opens (`next_window_at`,
	# `next_day_at`), whether a run waits for it or ends (`after_round`), and
	# the wire vocabulary (`StopReason`, `SyncStop`, `stopped_label`). The loop
	# in Strava.drain_queue! and the rounds in Strava.sync! are thin effectful
	# skins over these.
	#
	# TWO limits, ending a run for different lengths. Strava's 15-minute read
	# window resets at :00, :15, :30 and :45 past the hour; a run that fills it
	# either waits for the next mark (a human run) or ends and names the mark
	# (a `--json` run). The daily allowance resets at midnight UTC, and a run
	# that spends it always ends and names that time. The day's reads are
	# counted against a persisted per-UTC-day total, raised to what the
	# `X-ReadRateLimit-Usage` header reports when Strava sends it, since the
	# header also counts reads other apps made on the same token.
	Limits : { reads_per_window : I64, reads_per_day : I64 }

	# what to do after a successful fetch has been stored
	PostStore : [Continue, WindowFull, DayFull]

	# Why a DRAIN run ended. A TAG, not a Str, so the COMPILER enforces the set at the
	# producer: drain_queue! cannot invent a fifth reason or typo an existing one.
	StopReason : [Complete, BudgetReached, RateLimited, DailyCapReached]

	# Why a SYNC run ended — the value behind the payload's `stopped` field. Wider
	# than StopReason by two inhabitants: the activity LIST can be refused before the
	# drain runs, for either of its two limits. Wrapping keeps drain_queue! unable to
	# name a list refusal at all; only sync!, which issues both requests, can.
	# ListDailyCapReached carries two facts at once: the listing is incomplete (rows
	# are missing) AND the allowance returns at midnight UTC.
	SyncStop : [FromDrain(StopReason), ListRateLimited, ListDailyCapReached]

	# What the `X-ReadRateLimit-Usage` header said on the last response: reads
	# spent in the current 15-minute window and in the UTC day, both including
	# the request that carried it. Unreported when the header is absent or
	# unreadable, and the engine's own count stands alone.
	Usage : [Reported({ window : I64, day : I64 }), Unreported]

	Action : [
		Refresh, # 401: refresh the access token, retry the same id (bounded by the caller)
		RateLimited, # 429 with allowance left: the window refused this read
		DailyCapReached, # 429 with the day spent: the same refusal, a later remedy
		Store({ window : I64, today : I64, after : PostStore }), # success: store, then advance
	]

	# A 429 is a backstop for when the counts disagree with Strava's, not the
	# mechanism: the Store arm reaches each limit on the read that fills it.
	decide : { status : U16, window : I64, today : I64, usage : Usage }, Limits -> Action
	decide = |s, lim|
		if s.status == 429 {
			# WHICH limit refused the read. The day's allowance spent means the
			# daily cap, whose remedy is midnight UTC rather than the next mark.
			if (floor_counts({ window: s.window, today: s.today }, s.usage)).today >= lim.reads_per_day {
				DailyCapReached
			} else {
				RateLimited
			}
		} else if s.status == 401 {
			Refresh
		} else {
			# any other status is handled by the store step (404 → empty marker,
			# 2xx → body, other → error propagated there); here we advance counters
			next = floor_counts({ window: s.window + 1, today: s.today + 1 }, s.usage)
			# DAY before WINDOW: a run that fills both has nothing to wait for
			# until midnight UTC, so waiting for the next quarter-hour would fail
			after =
				if next.today >= lim.reads_per_day {
					DayFull
				} else if next.window >= lim.reads_per_window {
					WindowFull
				} else {
					Continue
				}
			Store({ window: next.window, today: next.today, after })
		}

	# The header sets the pace where Strava sends it, and the engine's own count
	# is the floor: the larger of the two is the usage, so a header that lags
	# the engine never buys extra reads and one that sees other apps' reads
	# stops the run sooner.
	floor_counts : { window : I64, today : I64 }, Usage -> { window : I64, today : I64 }
	floor_counts = |own, usage|
		match usage {
			Reported(u) => { window: (own.window).max(u.window), today: (own.today).max(u.day) }
			Unreported => own
		}

	# the day's count to persist after a read that was refused or retried: the
	# read itself, raised to the header's day count when it reports more
	charged : I64, Usage -> I64
	charged = |today, usage| (floor_counts({ window: 0, today: today + 1 }, usage)).today

	# The usage from a response's headers, each given as `Name: value`. The name
	# is matched without regard to case, as HTTP header names are; the value is
	# "<window>,<day>", two non-negative whole numbers.
	usage_of : List(Str) -> Usage
	usage_of = |lines|
		List.fold(
			lines,
			Unreported,
			|found, line|
				match found {
					Reported(_) => found
					Unreported =>
						match Str.split_first(line, ":") {
							Ok({ before, after }) if Str.with_ascii_lowercased(Str.trim(before)) == "x-readratelimit-usage" => usage_value(after)
							_ => Unreported
						}
				},
		)

	usage_value : Str -> Usage
	usage_value = |raw|
		match Str.split_on(Str.trim(raw), ",") {
			[w, d] =>
				match (I64.from_str(Str.trim(w)), I64.from_str(Str.trim(d))) {
					(Ok(window), Ok(day)) if window >= 0 and day >= 0 => Reported({ window, day })
					_ => Unreported
				}
			_ => Unreported
		}

	# ── when the next window opens ─────────────────────────────────────
	# Strava's read window is the quarter-hour of the clock, not fifteen minutes
	# from the last read: it resets at :00, :15, :30 and :45. `window_secs` is
	# its length, 900 outside the test seam that can only shorten it.
	window_secs_default : I64
	window_secs_default = 900

	# A short margin past the mark absorbs the difference between this machine's
	# clock and Strava's: a ninetieth of the window, ten seconds of a real one.
	window_margin : I64 -> I64
	window_margin = |window_secs| window_secs // 90

	# the epoch second a run that filled the window at `now` can read again
	next_window_at : I64, I64 -> I64
	next_window_at = |now, window_secs| (now // window_secs + 1) * window_secs + window_margin(window_secs)

	# the epoch second the daily allowance returns: the next midnight UTC
	next_day_at : I64 -> I64
	next_day_at = |now| (now // 86400 + 1) * 86400

	# which window `now` falls in; reads made in an earlier one no longer count
	window_index : I64, I64 -> I64
	window_index = |now, window_secs| now // window_secs

	# A drain that crosses a quarter-hour mark is in a fresh window, so its own
	# count restarts. The header, where Strava sends one, says the same on the
	# next response; without it, this is what keeps the count from stopping a
	# run that has its whole new window ahead of it.
	roll_window : { idx : I64, window : I64 }, I64 -> { idx : I64, window : I64 }
	roll_window = |st, now_idx| if (now_idx == st.idx) st else { idx: now_idx, window: 0 }

	# ── whether a run waits or ends ────────────────────────────────────
	# `waits` is false for `--json`, which never holds the caller's shell, and a
	# run that owes nothing more has nothing to wait for.
	# A round that read nothing and came straight after a wait means Strava is
	# refusing a fresh window (another app on the token, or a limit lower than
	# stride's): waiting again would loop, so the run ends and names the time.
	Round : [Finish, Wait]

	after_round : { stop : SyncStop, owed : Bool, progressed : Bool, after_wait : Bool, waits : Bool } -> Round
	after_round = |r|
		match r.stop {
			FromDrain(Complete) => Finish
			FromDrain(DailyCapReached) => Finish
			ListDailyCapReached => Finish
			FromDrain(BudgetReached) | FromDrain(RateLimited) | ListRateLimited =>
				if !(r.waits) or !(r.owed) {
					Finish
				} else if !(r.progressed) and r.after_wait {
					Finish
				} else {
					Wait
				}
		}

	# The epoch second a caller can continue a run that ended with `stop`, or 0
	# when nothing is owed: a run that owes nothing has no next window to name,
	# and a complete run that still owes only undecodable bodies retries on the
	# next sync at any time.
	resume_epoch : SyncStop, Bool, I64, I64 -> I64
	resume_epoch = |stop, owed, now, window_secs|
		if !owed {
			0
		} else {
			match stop {
				FromDrain(Complete) => 0
				FromDrain(BudgetReached) | FromDrain(RateLimited) | ListRateLimited => next_window_at(now, window_secs)
				FromDrain(DailyCapReached) | ListDailyCapReached => next_day_at(now)
			}
		}

	# A first sync owes more than the window it starts in, so its summaries are
	# scored before the first stream is fetched: load, form and every report
	# work from the first window on. A routine sync owes less and scores once,
	# at the end.
	score_first : I64, I64 -> Bool
	score_first = |owed, window_left| owed > window_left

	# The tag <-> wire-string vocabulary, in one place. `sync_stopped_label` is the
	# PRODUCTION entry point and delegates the four drain reasons to `stopped_label`,
	# so a rename cannot land on one spelling only. These six strings are the enum in
	# schemas/v3/sync.json; changing one without the other is a contract break.
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
			# its own token: "the listing is incomplete AND the day is spent" means
			# rows are missing, which "the drain stopped on the day" does not
			ListDailyCapReached => "list_daily_cap_reached"
		}

	# A drain can outlive UTC midnight, and when it does the allowance has reset —
	# notice, rather than carry the old day. BACKWARDS is treated the same as
	# forwards: the count belongs to the day it is stamped with, and a stamp that
	# disagrees is not a count this run may spend against.
	roll_day : { day : I64, today : I64 }, I64 -> { day : I64, today : I64 }
	roll_day = |st, now_day| if (now_day == st.day) st else { day: now_day, today: 0 }

	test_lim : Limits
	test_lim = { reads_per_window: 3, reads_per_day: 100 }
}

# ── tests ───────────────────────────────────────────────────────────
# the daily arms at their boundaries
expect match Drain.decide({ status: 429, window: 0, today: 99, usage: Unreported }, Drain.test_lim) {
	RateLimited => True
	_ => False
}

expect match Drain.decide({ status: 429, window: 0, today: 100, usage: Unreported }, Drain.test_lim) {
	DailyCapReached => True
	_ => False
}

expect match Drain.decide({ status: 200, window: 0, today: 98, usage: Unreported }, Drain.test_lim) {
	Store({ after: Continue, .. }) => True
	_ => False
}

expect match Drain.decide({ status: 200, window: 0, today: 99, usage: Unreported }, Drain.test_lim) {
	Store({ after: DayFull, .. }) => True
	_ => False
}

# ...and the DAY wins when both are full: there is no window to wait for
expect match Drain.decide({ status: 200, window: 2, today: 99, usage: Unreported }, Drain.test_lim) {
	Store({ after: DayFull, .. }) => True
	_ => False
}

expect match Drain.decide({ status: 429, window: 0, today: 0, usage: Unreported }, Drain.test_lim) {
	RateLimited => True
	_ => False
}
expect match Drain.decide({ status: 429, window: 2, today: 2, usage: Unreported }, Drain.test_lim) {
	RateLimited => True
	_ => False
}

# 401 asks for a token refresh; the CALLER bounds how many it will spend
expect match Drain.decide({ status: 401, window: 0, today: 0, usage: Unreported }, Drain.test_lim) {
	Refresh => True
	_ => False
}

# a normal fetch stores and continues, advancing both counters
expect match Drain.decide({ status: 200, window: 0, today: 0, usage: Unreported }, Drain.test_lim) {
	Store({ window: 1, today: 1, after: Continue }) => True
	_ => False
}

# 404 takes the same store path (the marker write happens in the drain)
expect match Drain.decide({ status: 404, window: 0, today: 0, usage: Unreported }, Drain.test_lim) {
	Store({ window: 1, today: 1, after: Continue }) => True
	_ => False
}

# filling the window stores, then ends the batch
expect match Drain.decide({ status: 200, window: 2, today: 2, usage: Unreported }, Drain.test_lim) {
	Store({ window: 3, today: 3, after: WindowFull }) => True
	_ => False
}

# and it stays WindowFull past the boundary rather than wrapping back to Continue
expect match Drain.decide({ status: 200, window: 9, today: 9, usage: Unreported }, Drain.test_lim) {
	Store({ window: 10, today: 10, after: WindowFull }) => True
	_ => False
}

# ── the headers set the pace ──
# a header reporting reads the engine never made (another app on the token)
# fills the window on the engine's first read
expect match Drain.decide({ status: 200, window: 0, today: 0, usage: Reported({ window: 3, day: 3 }) }, Drain.test_lim) {
	Store({ window: 3, today: 3, after: WindowFull }) => True
	_ => False
}
# ...and the day the same way, with the day winning
expect match Drain.decide({ status: 200, window: 0, today: 0, usage: Reported({ window: 1, day: 100 }) }, Drain.test_lim) {
	Store({ window: 1, today: 100, after: DayFull }) => True
	_ => False
}
# a header reporting LESS than the engine has spent is floored by the engine's count
expect match Drain.decide({ status: 200, window: 1, today: 50, usage: Reported({ window: 0, day: 2 }) }, Drain.test_lim) {
	Store({ window: 2, today: 51, after: Continue }) => True
	_ => False
}
# a 429 whose header says the day is spent is the daily cap even when the own count is low
expect match Drain.decide({ status: 429, window: 0, today: 5, usage: Reported({ window: 0, day: 100 }) }, Drain.test_lim) {
	DailyCapReached => True
	_ => False
}
expect Drain.charged(5, Unreported) == 6
expect Drain.charged(5, Reported({ window: 1, day: 40 })) == 40
expect Drain.charged(50, Reported({ window: 1, day: 40 })) == 51

# the header, found without regard to case, among others
expect Drain.usage_of(["Content-Type: application/json", "x-readratelimit-usage: 27,412"]) == Reported({ window: 27, day: 412 })
expect Drain.usage_of(["X-ReadRateLimit-Usage: 3, 9"]) == Reported({ window: 3, day: 9 })
# the overall X-RateLimit-Usage header is a different count and is not read
expect Drain.usage_of(["X-RateLimit-Usage: 50,500"]) == Unreported
expect Drain.usage_of([]) == Unreported
# an unreadable value is no report at all, never a zero
expect Drain.usage_of(["X-ReadRateLimit-Usage: lots"]) == Unreported
expect Drain.usage_of(["X-ReadRateLimit-Usage: 1,2,3"]) == Unreported
expect Drain.usage_of(["X-ReadRateLimit-Usage: -1,2"]) == Unreported

# ── when the next window opens ──
# 2026-11-25T10:14:00Z is 1795601640: the next mark is 10:15, plus ten seconds
expect Drain.next_window_at(1795601640, 900) == 1795601700 + 10
# exactly ON a mark the window just opened, so the next one is a full window on
expect Drain.next_window_at(1795601700, 900) == 1795602600 + 10
# the margin is a ninetieth of the window, so a shortened test window has none
expect Drain.window_margin(900) == 10 and Drain.window_margin(2) == 0
expect Drain.next_window_at(101, 2) == 102
# the daily allowance returns at the next midnight UTC
expect Drain.next_day_at(1795601640) == 1795651200
expect Drain.next_day_at(1795651200) == 1795651200 + 86400
expect Drain.window_index(1795601699, 900) + 1 == Drain.window_index(1795601700, 900)

# a drain crossing a mark starts its own count over; within one window it carries
expect Drain.roll_window({ idx: 7, window: 60 }, 7) == { idx: 7, window: 60 }
expect Drain.roll_window({ idx: 7, window: 60 }, 8) == { idx: 8, window: 0 }

# ── whether a run waits ──
expect Drain.after_round({ stop: FromDrain(BudgetReached), owed: True, progressed: True, after_wait: False, waits: True }) == Wait
expect Drain.after_round({ stop: FromDrain(RateLimited), owed: True, progressed: False, after_wait: False, waits: True }) == Wait
expect Drain.after_round({ stop: ListRateLimited, owed: True, progressed: True, after_wait: True, waits: True }) == Wait
# a fresh window refusing its first read ends the run instead of waiting again
expect Drain.after_round({ stop: FromDrain(RateLimited), owed: True, progressed: False, after_wait: True, waits: True }) == Finish
expect Drain.after_round({ stop: ListRateLimited, owed: True, progressed: False, after_wait: True, waits: True }) == Finish
# `--json` never waits, whatever the stop
expect Drain.after_round({ stop: FromDrain(BudgetReached), owed: True, progressed: True, after_wait: False, waits: False }) == Finish
# the day and completion end a run in every mode
expect Drain.after_round({ stop: FromDrain(DailyCapReached), owed: True, progressed: True, after_wait: False, waits: True }) == Finish
expect Drain.after_round({ stop: ListDailyCapReached, owed: True, progressed: True, after_wait: False, waits: True }) == Finish
expect Drain.after_round({ stop: FromDrain(Complete), owed: True, progressed: True, after_wait: True, waits: True }) == Finish
# a window that fills on the read that empties every queue has nothing to wait for
expect Drain.after_round({ stop: FromDrain(BudgetReached), owed: False, progressed: True, after_wait: False, waits: True }) == Finish

# the time a caller continues: the window's mark, midnight UTC, or none
expect Drain.resume_epoch(FromDrain(BudgetReached), True, 1795601640, 900) == 1795601710
expect Drain.resume_epoch(ListRateLimited, True, 1795601640, 900) == 1795601710
expect Drain.resume_epoch(FromDrain(DailyCapReached), True, 1795601640, 900) == 1795651200
expect Drain.resume_epoch(ListDailyCapReached, True, 1795601640, 900) == 1795651200
expect Drain.resume_epoch(FromDrain(BudgetReached), False, 1795601640, 900) == 0
expect Drain.resume_epoch(FromDrain(Complete), True, 1795601640, 900) == 0

expect Drain.score_first(412, 94) and !(Drain.score_first(3, 94)) and !(Drain.score_first(94, 94))

# the wire strings, pinned by equality. These must equal the enum in schemas/v3/sync.json.
expect Drain.stopped_label(Complete) == "complete"
expect Drain.stopped_label(BudgetReached) == "budget_reached"
expect Drain.stopped_label(RateLimited) == "rate_limited"
expect Drain.sync_stopped_label(ListRateLimited) == "list_rate_limited"
# the wrapper DELEGATES rather than restating
expect Drain.sync_stopped_label(FromDrain(Complete)) == Drain.stopped_label(Complete)
expect Drain.sync_stopped_label(FromDrain(BudgetReached)) == Drain.stopped_label(BudgetReached)
expect Drain.sync_stopped_label(FromDrain(RateLimited)) == Drain.stopped_label(RateLimited)
expect Drain.sync_stopped_label(ListDailyCapReached) == "list_daily_cap_reached"

# the midnight roll, both directions
expect Drain.roll_day({ day: 20690, today: 995 }, 20690) == { day: 20690, today: 995 }
expect Drain.roll_day({ day: 20690, today: 995 }, 20691) == { day: 20691, today: 0 }
expect Drain.roll_day({ day: 20691, today: 995 }, 20690) == { day: 20690, today: 0 }
