# stride-core: definitions both binaries need.
#
# The engine (basic-cli) and the window (roc-ray) bind different platforms, so
# for most of this project's life they could share nothing but SQL views (ADR
# 0017). Since both build on one compiler they can import one package, and
# this is where a definition goes when BOTH surfaces state it. A definition
# only one binary uses stays in that binary.
Fmt :: [].{
	# seconds as m:ss, zero-padded on the seconds so a column of them aligns.
	# Both surfaces speak this: the CLI renders pace per kilometre and interval
	# durations, the window labels a pace family's threshold. One body, so a
	# rounding or padding change cannot reach one surface and miss the other.
	# Negative input clamps to zero - there is no such thing as a negative
	# duration, and a "-1:-30" would be a worse answer than "0:00".
	mmss : I64 -> Str
	mmss = |secs| {
		t = if (secs < 0) (0) else secs
		m = t // 60
		s = t % 60
		"${I64.to_str(m)}:${if (s < 10) "0" else ""}${I64.to_str(s)}"
	}

	expect mmss(181) == "3:01"
	expect mmss(720) == "12:00"
	expect mmss(0) == "0:00"
	expect mmss(59) == "0:59"
	expect mmss(-5) == "0:00"
	# a pace beyond an hour still reads in minutes rather than rolling over:
	# 75 minutes per kilometre is a walk, not an error, and "75:00" says so
	expect mmss(4500) == "75:00"

	# tenths as a one-decimal string: 419 -> "41.9", -89 -> "-8.9". Three
	# separate bodies wrote this rule out (the engine's fmt1, the window's
	# data-row formatter, the ramp view's signed variant) and agreed only by
	# luck. Between -1 and 0 the whole part rounds to 0, so "-0.5" needs the
	# minus that I64.to_str(0) cannot carry - same edge as hundredths.
	tenths : I64 -> Str
	tenths = |n| {
		whole = n // 10
		frac = I64.abs(n % 10)
		sign = if (n < 0 and whole == 0) "-" else ""
		"${sign}${I64.to_str(whole)}.${I64.to_str(frac)}"
	}

	expect tenths(419) == "41.9"
	expect tenths(-89) == "-8.9"
	expect tenths(-5) == "-0.5"
	expect tenths(0) == "0.0"
	expect tenths(100) == "10.0"

	# the always-signed variant: a ramp or delta reads "+2.5" so gain and
	# loss are distinguishable at a glance, and zero reads "+0.0" because a
	# flat week is the good case, not the missing one.
	tenths_signed : I64 -> Str
	tenths_signed = |n|
		if (n < 0) tenths(n) else "+${tenths(n)}"

	expect tenths_signed(25) == "+2.5"
	expect tenths_signed(-10) == "-1.0"
	expect tenths_signed(0) == "+0.0"
	expect tenths_signed(-5) == "-0.5"

	# hundredths as a two-decimal string: 98 -> "0.98", 105 -> "1.05". The
	# engine reaches it through a float (fmt2 rounds first), the window
	# through an already-scaled integer - a value the SQL rounded - so the
	# shared body takes the hundredths and neither surface repeats the
	# zero-padding rule that makes 5 read as ".05" rather than ".5".
	# The sign lives here too: between -1 and 0 the whole part rounds to 0,
	# so "-0.42" needs the minus that I64.to_str(0) cannot carry.
	hundredths : I64 -> Str
	hundredths = |n| {
		whole = n // 100
		frac = I64.abs(n % 100)
		frac_str = if (frac < 10) "0${I64.to_str(frac)}" else I64.to_str(frac)
		sign = if (n < 0 and whole == 0) "-" else ""
		"${sign}${I64.to_str(whole)}.${frac_str}"
	}

	expect hundredths(98) == "0.98"
	expect hundredths(105) == "1.05"
	expect hundredths(100) == "1.00"
	expect hundredths(-42) == "-0.42"
	expect hundredths(-150) == "-1.50"
	expect hundredths(0) == "0.00"

	# A week's easy, moderate and hard time as whole percents that sum to
	# 100. The easy share is floored: the polarized verdict asks whether
	# easy time REACHED a share, so 79.9% must read 79, never a rounded 80
	# that the verdict would then call short. The points the floor frees go
	# to moderate and hard by largest remainder, moderate on a tie. All three
	# are 0 when there is no time to share.
	shares : I64, I64, I64 -> { easy : I64, moderate : I64, hard : I64 }
	shares = |easy, moderate, hard| {
		tot = easy + moderate + hard
		if tot <= 0 {
			{ easy: 0, moderate: 0, hard: 0 }
		} else {
			e = easy * 100 // tot
			m_floor = moderate * 100 // tot
			h_floor = hard * 100 // tot
			m_rem = moderate * 100 % tot
			h_rem = hard * 100 % tot
			spare = 100 - e - m_floor - h_floor
			m_extra = if (spare >= 2) 1 else if (spare == 1 and m_rem >= h_rem) 1 else 0
			{ easy: e, moderate: m_floor + m_extra, hard: h_floor + spare - m_extra }
		}
	}

	expect shares(8299, 1640, 61) == { easy: 82, moderate: 17, hard: 1 }
	expect shares(7999, 1, 2000) == { easy: 79, moderate: 1, hard: 20 }
	expect shares(8000, 0, 2000) == { easy: 80, moderate: 0, hard: 20 }
	expect shares(1, 1, 1) == { easy: 33, moderate: 34, hard: 33 }
	expect shares(0, 0, 0) == { easy: 0, moderate: 0, hard: 0 }
	expect {
		s = shares(9871, 100, 29)
		s.easy + s.moderate + s.hard == 100 and s.easy == 98
	}

	# seconds as hours to a tenth, rounded to the nearest tenth: 4.79 h
	# reads 4.8, not a floored 4.7
	hours_tenths : I64 -> Str
	hours_tenths = |secs| tenths((secs * 10 + 1800) // 3600)

	expect hours_tenths(17244) == "4.8" and hours_tenths(3600) == "1.0" and hours_tenths(0) == "0.0" and hours_tenths(179) == "0.0" and hours_tenths(180) == "0.1"
}
