# stride-core: the fitness/fatigue recurrence, shared by both binaries.
#
# The engine steps it once per day to build daily_load; the window reads the
# weekly hold level off it. One definition, because a second copy of a time
# constant is how two surfaces disagree about what a week of training did.
Load :: [].{
	# One day's step of the fitness/fatigue/form model:
	#   CTL (fitness) = 42-day EWMA of daily load; ATL (fatigue) = 7-day EWMA.
	#   TSB (form)    = TODAY's fitness minus TODAY's fatigue, so tsb == ctl - atl
	#                   and a verdict printed right after `analyze` already
	#                   carries the session just uploaded.
	#
	# The discrete factor for time constant tau is a = 1 - e^(-1/tau), not 1/tau:
	# 1/tau delivers effective constants of 41.7 and 6.5 days and runs transients
	# fast while the steady state is identical. The values are literals because
	# F64 has no `.exp()` on this compiler; the engine's Metrics expects pin each
	# against its computed exponential.
	#   ctl_alpha = 1 - e^(-1/42)
	#   atl_alpha = 1 - e^(-1/7)
	ctl_alpha : F64
	ctl_alpha = 0.0235283133
	atl_alpha : F64
	atl_alpha = 0.1331221

	step : { ctl_prev : F64, atl_prev : F64, tss : F64 } -> { ctl : F64, atl : F64, tsb : F64 }
	step = |{ ctl_prev, atl_prev, tss }| {
		ctl = ctl_prev + (tss - ctl_prev) * ctl_alpha
		atl = atl_prev + (tss - atl_prev) * atl_alpha
		# same-day form: today's fitness minus today's fatigue, so the number
		# reconciles (tsb = ctl - atl) and reflects state AFTER today's training
		{ ctl, atl, tsb: ctl - atl }
	}

	# The load over `days` days that leaves CTL where it started. A day whose
	# load equals CTL is the step's fixed point (ctl + (ctl - ctl) * a = ctl),
	# so the constant daily load that holds CTL is CTL itself, and the hold
	# over a span is CTL at its start times the days it counts. A week still
	# running counts only its elapsed days, so it is held to a partial level.
	#
	# The step weighs a late day above an early one and the hold weighs every
	# day alike, so the hold can miss either way. With a = ctl_alpha and
	# r = 1 - a, a week's change in CTL is a times its loads weighted r^6 for
	# the first day down to 1 for the last, less (1 - r^7) of its start. A
	# week whose whole load lands on its first day can top its hold and still
	# lose up to (1 - r^7) - 7a*r^6 of its starting CTL (1.07%); one whose
	# whole load lands on its last day can fall short and still gain up to
	# 7a - (1 - r^7) (1.12%). Every other placement misses by less, and so
	# does a shorter span. The last expect below pins both bounds.
	hold : F64, I64 -> F64
	hold = |ctl_start, days| if (days <= 0) 0.0 else ctl_start * days.to_f64()

	# walks a span of daily loads from a starting CTL with the step above
	walk : F64, List(F64) -> F64
	walk = |ctl_start, loads| List.fold(loads, ctl_start, |c, t| (step({ ctl_prev: c, atl_prev: 0.0, tss: t })).ctl)

	# The step run forward from a known day: one row per day after `from_day`
	# through `to_day`, in order, each carrying the summed load of the
	# entries dated on it and the state the step leaves. A day no entry
	# names steps with zero load, and an entry outside the span adds
	# nothing. A span that does not run forward is empty.
	Day : { d : I64, load : F64, ctl : F64, atl : F64, tsb : F64 }

	days_from : { ctl : F64, atl : F64 }, I64, I64, List({ d : I64, tss : F64 }) -> List(Day)
	days_from = |start, from_day, to_day, loads|
		if (to_day <= from_day)
			[]
		else {
			span = (to_day - from_day).to_u64_wrap()
			Iter.fold(
				(0.U64..<span).iter(),
				{ ctl: start.ctl, atl: start.atl, out: List.with_capacity(span) },
				|acc, i| {
					d = from_day + 1 + i.to_i64_wrap()
					load = List.fold(loads, 0.0, |t, o| if (o.d == d) t + o.tss else t)
					s = step({ ctl_prev: acc.ctl, atl_prev: acc.atl, tss: load })
					{ ctl: s.ctl, atl: s.atl, out: List.append(acc.out, { d, load, ctl: s.ctl, atl: s.atl, tsb: s.tsb }) }
				},
			).out
		}

	# twelve Monday weeks of a real athlete's daily load, oldest first, the
	# newest three days into its week, and the CTL the series held on the
	# Sunday before the first
	real_ctl_start : F64
	real_ctl_start = 42.2724

	real_days : List(F64)
	real_days = [0.0, 46.8, 86.8, 37.7, 64.9, 97.6, 0.0, 72.2, 39.0, 85.0, 37.8, 70.8, 75.4, 0.0, 73.4, 38.6, 80.1, 56.6, 41.3, 123.5, 63.2, 47.6, 75.2, 30.0, 94.5, 43.4, 66.1, 48.9, 0.0, 62.0, 60.5, 59.1, 55.5, 70.1, 0.0, 164.2, 38.9, 35.1, 73.3, 20.9, 0.0, 0.0, 82.6, 37.6, 78.2, 58.0, 38.6, 61.3, 76.7, 0.0, 95.9, 33.9, 67.9, 32.3, 0.0, 37.1, 82.1, 61.8, 46.6, 0.0, 64.8, 46.5, 91.6, 0.0, 192.2, 54.2, 59.2, 49.4, 88.8, 87.5, 0.0, 39.0, 81.5, 66.5, 38.3, 52.9, 0.0, 65.2, 209.8, 0.0]

	# the series cut into Monday weeks, each with the CTL it started and
	# ended on, its total load and the days it covers
	real_weeks : List({ ctl_start : F64, ctl_end : F64, total : F64, days : I64 })
	real_weeks =
		List.fold(
			List.map_with_index(real_days, |t, i| { t, i }),
			{ weeks: [], ctl: real_ctl_start },
			|acc, d| {
				c = walk(acc.ctl, [d.t])
				if d.i % 7 == 0 {
					{ weeks: List.append(acc.weeks, { ctl_start: acc.ctl, ctl_end: c, total: d.t, days: 1 }), ctl: c }
				} else {
					last = (List.last(acc.weeks)) ?? { ctl_start: acc.ctl, ctl_end: c, total: 0.0, days: 0 }
					{ weeks: List.append(List.drop_last(acc.weeks, 1), { ..last, ctl_end: c, total: last.total + d.t, days: last.days + 1 }), ctl: c }
				}
			},
		).weeks

	# the forward walk: a row per day of the span and none outside it, each
	# one step from the row before it, loads summed by day, an entry outside
	# the span ignored
	expect {
		rows = days_from({ ctl: 40.0, atl: 50.0 }, 10, 13, [{ d: 12, tss: 30.0 }, { d: 12, tss: 20.0 }, { d: 10, tss: 500.0 }, { d: 14, tss: 500.0 }])
		s1 = step({ ctl_prev: 40.0, atl_prev: 50.0, tss: 0.0 })
		s2 = step({ ctl_prev: s1.ctl, atl_prev: s1.atl, tss: 50.0 })
		s3 = step({ ctl_prev: s2.ctl, atl_prev: s2.atl, tss: 0.0 })
		near = |r, d, l, s| r.d == d and (r.load - l).abs() < 0.000001 and (r.ctl - s.ctl).abs() < 0.000001 and (r.atl - s.atl).abs() < 0.000001 and (r.tsb - s.tsb).abs() < 0.000001
		match rows {
			[a, b, c] => near(a, 11, 0.0, s1) and near(b, 12, 50.0, s2) and near(c, 13, 0.0, s3)
			_ => Bool.False
		}
	}

	# a span that does not run forward has no rows
	expect List.is_empty(days_from({ ctl: 40.0, atl: 50.0 }, 10, 10, [{ d: 10, tss: 50.0 }])) and List.is_empty(days_from({ ctl: 40.0, atl: 50.0 }, 10, 9, []))

	# a day at CTL holds CTL, and a span at the hold's daily rate ends where
	# it started, whatever its length
	expect {
		held = |c, n| (walk(c, List.repeat(hold(c, n) / n.to_f64(), n.to_u64_wrap())) - c).abs() < 0.000001
		(step({ ctl_prev: 51.6, atl_prev: 0.0, tss: 51.6 }).ctl - 51.6).abs() < 0.000001
			and held(51.6, 7)
			and held(51.6, 3)
			and held(12.0, 1)
	}

	# the running week is held to its elapsed days: three days of a week at
	# CTL 50 hold 150, not the full week's 350
	expect (hold(50.0, 3) - 150.0).abs() < 0.000001 and (hold(50.0, 7) - 350.0).abs() < 0.000001 and hold(50.0, 0) == 0.0

	# the fixture is the athlete's series: the step walks it onto the CTL each
	# week ended on, and the newest week is three days old
	expect {
		ends = List.map(real_weeks, |w| w.ctl_end)
		stored = [43.14, 44.77, 48.40, 49.87, 48.95, 48.42, 50.48, 48.55, 49.73, 53.78, 51.61, 54.33]
		List.len(ends) == 12
			and List.all(List.map2(ends, stored, |a, b| (a - b).abs() < 0.01), |ok| ok)
			and (List.last(real_weeks) ?? { ctl_start: 0.0, ctl_end: 0.0, total: 0.0, days: 0 }).days == 3
	}

	# over every week of that series, the running one included, a week whose
	# load tops its hold gained CTL and one under it lost CTL
	expect List.all(real_weeks, |w| (w.ctl_end > w.ctl_start) == (w.total > hold(w.ctl_start, w.days)))

	# the hold's miss, both ways, at its exact bound: a week's whole load on
	# its first day, a hair over its hold, loses close to (1 - r^7) - 7a*r^6
	# of its starting CTL and no more; on its last day, a hair under, it gains
	# close to 7a - (1 - r^7) and no more; and a week's load on any one day,
	# exactly at its hold, lands between the two
	expect {
		a = ctl_alpha
		r = 1.0 - a
		r6 = r * r * r * r * r * r
		lose_bound = (1.0 - r6 * r) - 7.0 * a * r6
		gain_bound = 7.0 * a - (1.0 - r6 * r)
		c = 50.0
		e = 0.000001
		days7 = [0.U64, 1, 2, 3, 4, 5, 6]
		on_day = |i, total| List.map(days7, |d| if (d == i) total else 0.0)
		lost = (c - walk(c, on_day(0, hold(c, 7) * (1.0 + e)))) / c
		gained = (walk(c, on_day(6, hold(c, 7) * (1.0 - e))) - c) / c
		(lose_bound - 0.010745).abs() < 0.000005
			and (gain_bound - 0.011180).abs() < 0.000005
			and lost > 0.0 and lost <= lose_bound and lost > lose_bound - 0.00001
			and gained > 0.0 and gained <= gain_bound and gained > gain_bound - 0.00001
			and List.all(days7, |i| (walk(c, on_day(i, hold(c, 7))) - c) / c >= 0.0 - lose_bound - 0.000000001 and (walk(c, on_day(i, hold(c, 7))) - c) / c <= gain_bound + 0.000000001)
	}
}
