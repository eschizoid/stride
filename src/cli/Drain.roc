Drain :: [].{
	# ── the stream drain's pure half ────────────────────────────────────
	# Every decision the sync loop makes about Strava's read limits, all pure:
	# whether a read may be made (`may_read`), the pacing after one (`decide`),
	# what the rate-limit headers report (`usage_of`, `limit_of`), the caps a
	# reported limit gives (`caps_for`), the counts each period carries
	# (`roll_reads`, `charge`), when the next window or day opens
	# (`next_read_at`), whether a run waits for it or ends (`after_round`), and
	# the wire vocabulary (`StopReason`, `SyncStop`, `stopped_label`).
	# Strava.drain_queue!, Strava.fetch_pages! and the rounds in
	# Strava.sync_run! are thin effectful skins over these.
	#
	# Strava limits an app's reads in each 15-minute window, which resets at
	# :00, :15, :30 and :45 past the hour, and in each UTC day, and reports both
	# limits and its count of both on every response (`X-ReadRateLimit-Limit`,
	# `X-ReadRateLimit-Usage`, "<15min>,<daily>"). Stride paces to the reported
	# limits less a margin, or to 100 and 1,000 less the margin until a limit
	# has been reported. It counts every read it makes against both periods, in
	# the database, so a count survives the run that made it, raises its counts
	# to what Strava reports (which also sees other apps' reads on the same
	# token), and checks them BEFORE each read, so no run of its own can pass
	# either limit.
	#
	# `reads_per_quarter` and `reads_per_utc_day` are those caps on Strava's
	# own periods, and no seam can loosen them. `reads_per_window` and
	# `reads_per_day` pace the periods a test may shorten (STRIDE_WINDOW_SECONDS,
	# STRIDE_DAY_SECONDS) and lower (STRIDE_READS_PER_WINDOW,
	# STRIDE_READS_PER_DAY); outside a test each pair is the same period.
	Limits : { reads_per_window : I64, reads_per_quarter : I64, reads_per_day : I64, reads_per_utc_day : I64 }

	# The read counts that pace a run, each stamped with the period it belongs
	# to: `today` with the UTC `day` number, `dtoday` with `dmark` (the epoch
	# second the paced day started), `window` with `wmark` (the epoch second the
	# read window started), and `quarter` with `qmark` (the epoch second
	# Strava's own quarter-hour started).
	Reads : { day : I64, today : I64, dmark : I64, dtoday : I64, wmark : I64, window : I64, qmark : I64, quarter : I64 }

	# the lengths in seconds of the paced window and day, which only a test shortens
	Periods : { window : I64, day : I64 }

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
		Store({ reads : Reads, after : PostStore }), # success: store, then advance
	]

	# Before a read: the day first, because a spent day has no window to wait
	# for, then either window.
	may_read : Reads, Limits -> [Go, WindowFull, DayFull]
	may_read = |r, lim|
		if r.dtoday >= lim.reads_per_day or r.today >= lim.reads_per_utc_day {
			DayFull
		} else if r.window >= lim.reads_per_window or r.quarter >= lim.reads_per_quarter {
			WindowFull
		} else {
			Go
		}

	# After a read. A 429 is a backstop for when the counts disagree with
	# Strava's, not the mechanism: may_read refuses the read that would pass a
	# limit, and the Store arm ends a batch on the read that fills one.
	decide : { status : U16, reads : Reads, usage : Usage }, Limits -> Action
	decide = |s, lim|
		if s.status == 429 {
			# WHICH limit refused the read. The day's allowance spent means the
			# daily cap, whose remedy is the next day rather than the next mark.
			if may_read(floor_reads(s.reads, s.usage), { ..lim, reads_per_window: I64.highest, reads_per_quarter: I64.highest }) == DayFull {
				DailyCapReached
			} else {
				RateLimited
			}
		} else if s.status == 401 {
			Refresh
		} else {
			# any other status is handled by the store step (404 → empty marker,
			# 2xx → body, other → error propagated there); here we advance counters
			next = charge(s.reads, s.usage)
			after =
				match may_read(next, lim) {
					DayFull => DayFull
					WindowFull => WindowFull
					Go => Continue
				}
			Store({ reads: next, after })
		}

	# The header sets the pace where Strava sends it, and the engine's own count
	# is the floor: the larger of the two is the usage, so a header that lags
	# the engine never buys extra reads and one that sees other apps' reads
	# stops the run sooner. The header's periods are Strava's quarter-hour and
	# day, and they raise the shortened test periods too, which are never longer.
	floor_reads : Reads, Usage -> Reads
	floor_reads = |r, usage|
		match usage {
			Reported(u) => { ..r, window: (r.window).max(u.window), quarter: (r.quarter).max(u.window), today: (r.today).max(u.day), dtoday: (r.dtoday).max(u.day) }
			Unreported => r
		}

	# one read spent, on every count, raised to what the header reports
	charge : Reads, Usage -> Reads
	charge = |r, usage| floor_reads({ ..r, today: r.today + 1, dtoday: r.dtoday + 1, window: r.window + 1, quarter: r.quarter + 1 }, usage)

	# The usage and the limits from a response's headers, each header given as
	# `Name: value`. The name is matched without regard to case, as HTTP header
	# names are; the value is "<15min>,<daily>", two whole numbers. A count may
	# be zero; a limit of zero is no limit stride can pace to, so it reads as
	# none reported.
	usage_of : List(Str) -> Usage
	usage_of = |lines| header_pair(lines, "x-readratelimit-usage", 0)

	limit_of : List(Str) -> Usage
	limit_of = |lines| header_pair(lines, "x-readratelimit-limit", 1)

	header_pair : List(Str), Str, I64 -> Usage
	header_pair = |lines, name, least|
		List.fold(
			lines,
			Unreported,
			|found, line|
				match found {
					Reported(_) => found
					Unreported =>
						match Str.split_first(line, ":") {
							Ok({ before, after }) if Str.with_ascii_lowercased(Str.trim(before)) == name => pair_value(after, least)
							_ => Unreported
						}
				},
		)

	pair_value : Str, I64 -> Usage
	pair_value = |raw, least|
		match Str.split_on(Str.trim(raw), ",") {
			[w, d] =>
				match (I64.from_str(Str.trim(w)), I64.from_str(Str.trim(d))) {
					(Ok(window), Ok(day)) if window >= least and day >= least => Reported({ window, day })
					_ => Unreported
				}
			_ => Unreported
		}

	# A limit is adopted only from a response that also reports its usage: the
	# usage is what the engine's counts are raised to, so a limit taken alone
	# could raise the cap while the reads other apps spent stayed unseen.
	adopt : Usage, Usage -> Usage
	adopt = |usage, limit|
		match usage {
			Reported(_) => limit
			Unreported => Unreported
		}

	# ── the caps a limit gives ─────────────────────────────────────────
	# A cap is the limit less a margin that absorbs reads another app makes
	# between the engine's own: five percent of the limit, and never fewer than
	# five reads. A limit no larger than its margin still allows one read.
	read_margin : I64 -> I64
	read_margin = |limit| (limit * 5 // 100).max(5)

	cap : I64 -> I64
	cap = |limit| (limit - read_margin(limit)).max(1)

	# Strava's documented limits, assumed until it has reported its own
	limit_default : { window : I64, day : I64 }
	limit_default = { window: 100, day: 1000 }

	# Before Strava has reported a limit: its documented 100 a quarter-hour,
	# less the margin, and its documented 1,000 a day.
	caps_default : { quarter : I64, day : I64 }
	caps_default = { quarter: cap(limit_default.window), day: limit_default.day }

	caps_for : Usage -> { quarter : I64, day : I64 }
	caps_for = |reported|
		match reported {
			Reported(l) => { quarter: cap(l.window), day: cap(l.day) }
			Unreported => caps_default
		}

	# ── when the next window or day opens ──────────────────────────────
	# Strava's read window is the quarter-hour of the clock, not fifteen minutes
	# from the last read: it resets at :00, :15, :30 and :45, and its day at
	# midnight UTC. The paced periods are those, 900 and 86,400 seconds, outside
	# the test seams that can only shorten them.
	window_secs_default : I64
	window_secs_default = 900

	day_secs_default : I64
	day_secs_default = 86400

	# A short margin past the mark absorbs the difference between this machine's
	# clock and Strava's: a ninetieth of the window, ten seconds of a real one.
	window_margin : I64 -> I64
	window_margin = |window_secs| window_secs // 90

	# the epoch second a period of `secs` started, the one `now` is in
	window_mark : I64, I64 -> I64
	window_mark = |now, secs| (now // secs) * secs

	# the epoch second a run that filled the window at `now` can read again
	next_window_at : I64, I64 -> I64
	next_window_at = |now, window_secs| window_mark(now, window_secs) + window_secs + window_margin(window_secs)

	# the epoch second the daily allowance returns: the next midnight UTC, or
	# the next mark of a shortened test day, with the margin a quarter-hour
	# mark gets (none for a test day shorter than a quarter-hour's margin)
	next_day_at : I64, I64 -> I64
	next_day_at = |now, day_secs| window_mark(now, day_secs) + day_secs + window_margin((day_secs).min(window_secs_default))

	# The counts as they stand at `now`: each belongs to the period it is
	# stamped with, so a stamp that is not the current period's means zero
	# spent in this one. That is the reset, and it needs no scheduled job: a
	# drain that outlives UTC midnight or crosses a mark notices. BACKWARDS is
	# treated the same as forwards: a stamp that disagrees with the clock is not
	# a count this run may spend against.
	roll_reads : Reads, I64, Periods -> Reads
	roll_reads = |r, now, p| {
		day = now // 86400
		dmark = window_mark(now, p.day)
		wmark = window_mark(now, p.window)
		qmark = window_mark(now, window_secs_default)
		{
			day,
			today: if (r.day == day) r.today else 0,
			dmark,
			dtoday: if (r.dmark == dmark) r.dtoday else 0,
			wmark,
			window: if (r.wmark == wmark) r.window else 0,
			qmark,
			quarter: if (r.qmark == qmark) r.quarter else 0,
		}
	}

	# ── whether a run waits or ends ────────────────────────────────────
	# `waits` is false for `--json`, which never holds the caller's shell, and a
	# run that owes nothing more has nothing to wait for. A human run waits out
	# a spent window and a spent day alike. A round that read nothing and came
	# straight after a wait means Strava is refusing a fresh period (another app
	# on the token spending it, or a limit lower than stride's): waiting again
	# would loop, so the run ends and names the time.
	Round : [Finish, Wait]

	after_round : { stop : SyncStop, owed : Bool, progressed : Bool, after_wait : Bool, waits : Bool } -> Round
	after_round = |r|
		match r.stop {
			FromDrain(Complete) => Finish
			FromDrain(BudgetReached) | FromDrain(RateLimited) | ListRateLimited | FromDrain(DailyCapReached) | ListDailyCapReached =>
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
	# next sync at any time. `opens` holds when the next read window and the
	# next day begin.
	resume_epoch : SyncStop, Bool, { window : I64, day : I64 } -> I64
	resume_epoch = |stop, owed, opens|
		if !owed {
			0
		} else {
			match stop {
				FromDrain(Complete) => 0
				FromDrain(BudgetReached) | FromDrain(RateLimited) | ListRateLimited => opens.window
				FromDrain(DailyCapReached) | ListDailyCapReached => opens.day
			}
		}

	# When a run whose counts stood at `r` at `now` can read again: the next
	# day when a day is spent, Strava's next quarter-hour mark when the
	# quarter-hour is, else the next mark of the window it paces by. A shortened
	# test day shortens the wait for either day, and the count Strava's day
	# allows still applies when it ends.
	next_read_at : Reads, Limits, I64, Periods -> I64
	next_read_at = |r, lim, now, p|
		match may_read(r, lim) {
			DayFull => next_day_at(now, p.day)
			_ =>
				if r.quarter >= lim.reads_per_quarter {
					next_window_at(now, window_secs_default)
				} else {
					next_window_at(now, p.window)
				}
		}

	# When a spent day's allowance returns, as a caller is told it: Strava's next
	# midnight UTC when its own day is spent, which no shortened test day brings
	# sooner, else the next mark of the paced day
	next_day_for : Reads, Limits, I64, Periods -> I64
	next_day_for = |r, lim, now, p|
		if r.today >= lim.reads_per_utc_day {
			next_day_at(now, day_secs_default)
		} else {
			next_day_at(now, p.day)
		}

	# A period's stored count as it stands now, from its two rows: the count and
	# the mark it was stamped with. A mark that is not the current period's, past
	# or future, means nothing spent in this one; an unreadable mark, or a count
	# that is unreadable, negative or more than twice the period's limit (no run
	# could reach it), is reset the same way, and `repaired` says the rows need
	# writing back, so a damaged row cannot refuse every run while no read is made
	# to rewrite it. The reads made after a reset are raised again to what Strava
	# reports on the first response.
	stamped : [Known(I64), Corrupt], [Known(I64), Corrupt], I64, I64 -> { count : I64, repaired : Bool }
	stamped = |mark, count, mark_now, limit|
		match mark {
			Known(m) if m == mark_now =>
				match count {
					Known(n) if n >= 0 and n <= limit * 2 => { count: n, repaired: Bool.False }
					_ => { count: 0, repaired: Bool.True }
				}
			Known(_) => { count: 0, repaired: Bool.False }
			Corrupt => { count: 0, repaired: Bool.True }
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

	test_lim : Limits
	test_lim = { reads_per_window: 3, reads_per_quarter: 100, reads_per_day: 100, reads_per_utc_day: 100 }

	# counts in the window and day of 2026-11-25T10:14:00Z
	at : { window : I64, quarter : I64, today : I64 } -> Reads
	at = |c| { day: 20782, today: c.today, dmark: 1795564800, dtoday: c.today, wmark: 1795600800, window: c.window, qmark: 1795600800, quarter: c.quarter }

	# the real periods
	real : Periods
	real = { window: 900, day: 86400 }
}

# ── tests ───────────────────────────────────────────────────────────
# before a read: the day first, then either window
expect Drain.may_read(Drain.at({ window: 0, quarter: 0, today: 99 }), Drain.test_lim) == Go
expect Drain.may_read(Drain.at({ window: 0, quarter: 0, today: 100 }), Drain.test_lim) == DayFull
expect Drain.may_read(Drain.at({ window: 3, quarter: 3, today: 100 }), Drain.test_lim) == DayFull
expect Drain.may_read(Drain.at({ window: 3, quarter: 3, today: 3 }), Drain.test_lim) == WindowFull
# the quarter-hour refuses a read whatever the shortened window says, so no seam
# can carry a run past Strava's own window
expect Drain.may_read(Drain.at({ window: 0, quarter: 100, today: 3 }), Drain.test_lim) == WindowFull
expect Drain.may_read(Drain.at({ window: 2, quarter: 99, today: 3 }), Drain.test_lim) == Go

# after a read: the daily arms at their boundaries
expect match Drain.decide({ status: 429, reads: Drain.at({ window: 0, quarter: 0, today: 99 }), usage: Unreported }, Drain.test_lim) {
	RateLimited => True
	_ => False
}
expect match Drain.decide({ status: 429, reads: Drain.at({ window: 0, quarter: 0, today: 100 }), usage: Unreported }, Drain.test_lim) {
	DailyCapReached => True
	_ => False
}
expect match Drain.decide({ status: 200, reads: Drain.at({ window: 0, quarter: 0, today: 98 }), usage: Unreported }, Drain.test_lim) {
	Store({ after: Continue, .. }) => True
	_ => False
}
expect match Drain.decide({ status: 200, reads: Drain.at({ window: 0, quarter: 0, today: 99 }), usage: Unreported }, Drain.test_lim) {
	Store({ after: DayFull, .. }) => True
	_ => False
}
# ...and the DAY wins when both are full: there is no window to wait for
expect match Drain.decide({ status: 200, reads: Drain.at({ window: 2, quarter: 2, today: 99 }), usage: Unreported }, Drain.test_lim) {
	Store({ after: DayFull, .. }) => True
	_ => False
}
expect match Drain.decide({ status: 429, reads: Drain.at({ window: 2, quarter: 2, today: 2 }), usage: Unreported }, Drain.test_lim) {
	RateLimited => True
	_ => False
}
# 401 asks for a token refresh; the CALLER bounds how many it will spend
expect match Drain.decide({ status: 401, reads: Drain.at({ window: 0, quarter: 0, today: 0 }), usage: Unreported }, Drain.test_lim) {
	Refresh => True
	_ => False
}
# a normal fetch stores and continues, advancing every count
expect match Drain.decide({ status: 200, reads: Drain.at({ window: 0, quarter: 0, today: 0 }), usage: Unreported }, Drain.test_lim) {
	Store({ reads, after: Continue }) => reads == Drain.at({ window: 1, quarter: 1, today: 1 })
	_ => False
}
# 404 takes the same store path (the marker write happens in the drain)
expect match Drain.decide({ status: 404, reads: Drain.at({ window: 0, quarter: 0, today: 0 }), usage: Unreported }, Drain.test_lim) {
	Store({ after: Continue, .. }) => True
	_ => False
}
# filling the window stores, then ends the batch, and stays full past the boundary
expect match Drain.decide({ status: 200, reads: Drain.at({ window: 2, quarter: 2, today: 2 }), usage: Unreported }, Drain.test_lim) {
	Store({ after: WindowFull, .. }) => True
	_ => False
}
expect match Drain.decide({ status: 200, reads: Drain.at({ window: 9, quarter: 9, today: 9 }), usage: Unreported }, Drain.test_lim) {
	Store({ after: WindowFull, .. }) => True
	_ => False
}
# ...and filling the quarter-hour ends it too, with the short window still open
expect match Drain.decide({ status: 200, reads: Drain.at({ window: 0, quarter: 99, today: 9 }), usage: Unreported }, Drain.test_lim) {
	Store({ after: WindowFull, .. }) => True
	_ => False
}

# ── the headers set the pace ──
# a header reporting reads the engine never made (another app on the token)
# fills the window on the engine's first read
expect match Drain.decide({ status: 200, reads: Drain.at({ window: 0, quarter: 0, today: 0 }), usage: Reported({ window: 3, day: 3 }) }, Drain.test_lim) {
	Store({ reads, after: WindowFull }) => reads == Drain.at({ window: 3, quarter: 3, today: 3 })
	_ => False
}
# ...and the day the same way, with the day winning
expect match Drain.decide({ status: 200, reads: Drain.at({ window: 0, quarter: 0, today: 0 }), usage: Reported({ window: 1, day: 100 }) }, Drain.test_lim) {
	Store({ after: DayFull, .. }) => True
	_ => False
}
# a header reporting LESS than the engine has spent is floored by the engine's count
expect Drain.charge(Drain.at({ window: 1, quarter: 1, today: 50 }), Reported({ window: 0, day: 2 })) == Drain.at({ window: 2, quarter: 2, today: 51 })
expect Drain.charge(Drain.at({ window: 1, quarter: 1, today: 5 }), Reported({ window: 1, day: 40 })) == Drain.at({ window: 2, quarter: 2, today: 40 })
expect Drain.charge(Drain.at({ window: 1, quarter: 1, today: 5 }), Unreported) == Drain.at({ window: 2, quarter: 2, today: 6 })
# a 429 whose header says the day is spent is the daily cap even when the own count is low
expect match Drain.decide({ status: 429, reads: Drain.at({ window: 0, quarter: 0, today: 5 }), usage: Reported({ window: 0, day: 100 }) }, Drain.test_lim) {
	DailyCapReached => True
	_ => False
}

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
# the daily allowance returns at the next midnight UTC, with a mark's margin
expect Drain.next_day_at(1795601640, 86400) == 1795651200 + 10
expect Drain.next_day_at(1795651200, 86400) == 1795651200 + 86400 + 10
# ...and a shortened test day ends at its own next mark
expect Drain.next_day_at(101, 3) == 102
expect Drain.window_mark(1795601699, 900) + 900 == Drain.window_mark(1795601700, 900)

# the counts at `now`: within the window and day they carry
expect Drain.roll_reads(Drain.at({ window: 60, quarter: 61, today: 995 }), 1795601640, Drain.real) == Drain.at({ window: 60, quarter: 61, today: 995 })
# past the mark both windows start over, and the day keeps its count
expect Drain.roll_reads(Drain.at({ window: 60, quarter: 61, today: 995 }), 1795601700, Drain.real) == { ..Drain.at({ window: 0, quarter: 0, today: 995 }), wmark: 1795601700, qmark: 1795601700 }
# a shortened window starts over at its own marks while the quarter-hour keeps
# counting: the seam shortens the wait, never the count Strava's window allows
expect Drain.roll_reads({ ..Drain.at({ window: 4, quarter: 40, today: 40 }), wmark: 1795601638 }, 1795601640, { ..Drain.real, window: 2 }) == { ..Drain.at({ window: 0, quarter: 40, today: 40 }), wmark: 1795601640 }
# ...and so does a shortened day, while Strava's day keeps counting
expect Drain.roll_reads({ ..Drain.at({ window: 4, quarter: 40, today: 40 }), dmark: 1795601637 }, 1795601640, { ..Drain.real, day: 3 }) == { ..Drain.at({ window: 4, quarter: 40, today: 40 }), dmark: 1795601640, dtoday: 0 }
# past UTC midnight the day starts over, and so does a clock that went back a day
expect (Drain.roll_reads(Drain.at({ window: 1, quarter: 1, today: 995 }), 1795651210, Drain.real)).today == 0
expect (Drain.roll_reads(Drain.at({ window: 1, quarter: 1, today: 995 }), 1795601640 - 86400, Drain.real)).today == 0

# ── whether a run waits ──
expect Drain.after_round({ stop: FromDrain(BudgetReached), owed: True, progressed: True, after_wait: False, waits: True }) == Wait
expect Drain.after_round({ stop: FromDrain(RateLimited), owed: True, progressed: False, after_wait: False, waits: True }) == Wait
expect Drain.after_round({ stop: ListRateLimited, owed: True, progressed: True, after_wait: True, waits: True }) == Wait
# a fresh window refusing its first read ends the run instead of waiting again
expect Drain.after_round({ stop: FromDrain(RateLimited), owed: True, progressed: False, after_wait: True, waits: True }) == Finish
expect Drain.after_round({ stop: ListRateLimited, owed: True, progressed: False, after_wait: True, waits: True }) == Finish
# `--json` never waits, whatever the stop
expect Drain.after_round({ stop: FromDrain(BudgetReached), owed: True, progressed: True, after_wait: False, waits: False }) == Finish
# a spent day is waited out like a window, and a fresh day refusing its first read ends the run
expect Drain.after_round({ stop: FromDrain(DailyCapReached), owed: True, progressed: True, after_wait: False, waits: True }) == Wait
expect Drain.after_round({ stop: FromDrain(DailyCapReached), owed: True, progressed: False, after_wait: False, waits: True }) == Wait
expect Drain.after_round({ stop: FromDrain(DailyCapReached), owed: True, progressed: False, after_wait: True, waits: True }) == Finish
expect Drain.after_round({ stop: FromDrain(DailyCapReached), owed: True, progressed: True, after_wait: False, waits: False }) == Finish
expect Drain.after_round({ stop: ListDailyCapReached, owed: True, progressed: True, after_wait: False, waits: True }) == Wait
# completion ends a run in every mode
expect Drain.after_round({ stop: FromDrain(Complete), owed: True, progressed: True, after_wait: True, waits: True }) == Finish
# a window that fills on the read that empties every queue has nothing to wait for
expect Drain.after_round({ stop: FromDrain(BudgetReached), owed: False, progressed: True, after_wait: False, waits: True }) == Finish

# the time a caller continues: the window's mark, midnight UTC, or none
expect Drain.resume_epoch(FromDrain(BudgetReached), True, { window: 1795601710, day: 1795651210 }) == 1795601710
expect Drain.resume_epoch(ListRateLimited, True, { window: 1795601710, day: 1795651210 }) == 1795601710
expect Drain.resume_epoch(FromDrain(DailyCapReached), True, { window: 1795601710, day: 1795651210 }) == 1795651210
expect Drain.resume_epoch(ListDailyCapReached, True, { window: 1795601710, day: 1795651210 }) == 1795651210
expect Drain.resume_epoch(FromDrain(BudgetReached), False, { window: 1795601710, day: 1795651210 }) == 0
expect Drain.resume_epoch(FromDrain(Complete), True, { window: 1795601710, day: 1795651210 }) == 0

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

# the next read: Strava's own mark when the quarter-hour filled, else the shortened window's
expect Drain.next_read_at(Drain.at({ window: 1, quarter: 100, today: 1 }), Drain.test_lim, 1795601640, { ..Drain.real, window: 2 }) == 1795601710
expect Drain.next_read_at(Drain.at({ window: 3, quarter: 3, today: 3 }), Drain.test_lim, 1795601640, { ..Drain.real, window: 2 }) == 1795601642
# a spent day waits for the next day, or the next mark of a shortened one, whichever
# of the two days is spent: the shortened wait ends where Strava's count still applies
expect Drain.next_read_at(Drain.at({ window: 1, quarter: 1, today: 100 }), Drain.test_lim, 1795601640, Drain.real) == 1795651210
expect Drain.next_read_at(Drain.at({ window: 1, quarter: 1, today: 100 }), Drain.test_lim, 1795601640, { ..Drain.real, day: 3 }) == 1795601643

# ── the limits Strava reports ──
expect Drain.limit_of(["Content-Type: application/json", "X-ReadRateLimit-Limit: 300,3000"]) == Reported({ window: 300, day: 3000 })
expect Drain.limit_of(["x-readratelimit-limit: 600, 30000"]) == Reported({ window: 600, day: 30000 })
# the overall X-RateLimit-Limit is a different allowance and is not read
expect Drain.limit_of(["X-RateLimit-Limit: 200,2000"]) == Unreported
# a zero, negative or malformed limit is none reported, never a cap of zero
expect Drain.limit_of(["X-ReadRateLimit-Limit: 0,1000"]) == Unreported
expect Drain.limit_of(["X-ReadRateLimit-Limit: 100,-1"]) == Unreported
expect Drain.limit_of(["X-ReadRateLimit-Limit: lots"]) == Unreported
expect Drain.limit_of(["X-ReadRateLimit-Limit: 100,1000,5"]) == Unreported
# a usage of zero is a count like any other
expect Drain.usage_of(["X-ReadRateLimit-Usage: 0,0"]) == Reported({ window: 0, day: 0 })
# a limit is taken only with the usage beside it
expect Drain.adopt(Reported({ window: 3, day: 9 }), Reported({ window: 300, day: 3000 })) == Reported({ window: 300, day: 3000 })
expect Drain.adopt(Unreported, Reported({ window: 300, day: 3000 })) == Unreported
# the margin: five percent, never fewer than five reads, and a cap of at least one
expect Drain.cap(100) == 95 and Drain.cap(1000) == 950 and Drain.cap(300) == 285 and Drain.cap(30000) == 28500
expect Drain.cap(20) == 15 and Drain.cap(10) == 5 and Drain.cap(3) == 1
expect Drain.caps_for(Reported({ window: 300, day: 3000 })) == { quarter: 285, day: 2850 }
# before any limit is reported, Strava's documented ones
expect Drain.caps_for(Unreported) == { quarter: 95, day: 1000 }
# Strava's own day refuses a read whatever the shortened test day says
expect Drain.may_read({ ..Drain.at({ window: 0, quarter: 0, today: 100 }), dtoday: 0 }, { ..Drain.test_lim, reads_per_day: 1000 }) == DayFull
expect Drain.may_read({ ..Drain.at({ window: 0, quarter: 0, today: 0 }), dtoday: 100 }, { ..Drain.test_lim, reads_per_utc_day: 1000 }) == DayFull

# the day a caller is told of: Strava's midnight when its own day is spent,
# however short the paced day, and the paced day's mark otherwise
expect Drain.next_day_for(Drain.at({ window: 0, quarter: 0, today: 100 }), Drain.test_lim, 1795601640, { ..Drain.real, day: 3 }) == 1795651210
expect Drain.next_day_for({ ..Drain.at({ window: 0, quarter: 0, today: 4 }), dtoday: 100 }, Drain.test_lim, 1795601640, { ..Drain.real, day: 3 }) == 1795601643

# a period's stored count: kept within its period, nothing outside it, and a
# damaged row reset and flagged for writing back
expect Drain.stamped(Known(900), Known(60), 900, 100) == { count: 60, repaired: Bool.False }
expect Drain.stamped(Known(0), Known(60), 900, 100) == { count: 0, repaired: Bool.False }
expect Drain.stamped(Known(1800), Known(95), 900, 100) == { count: 0, repaired: Bool.False }
expect Drain.stamped(Corrupt, Known(95), 900, 100) == { count: 0, repaired: Bool.True }
expect Drain.stamped(Known(900), Corrupt, 900, 100) == { count: 0, repaired: Bool.True }
expect Drain.stamped(Known(900), Known(201), 900, 100) == { count: 0, repaired: Bool.True }
expect Drain.stamped(Known(900), Known(200), 900, 100) == { count: 200, repaired: Bool.False }
