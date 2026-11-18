import core.Units
import Adapter

Peloton :: [].{
	# ── peloton: the share summary grammar ──────────────────────────────
	#
	#     Block 1
	#     Dumbbell Crush Press
	#     3 × 8 • 30 lbs/side
	#     Dumbbell Snatch Push Press
	#     3 × 8 reps/side • 25 lbs/side
	#
	# An exercise NAME line is followed by a SET line `S × R • W <unit>`, with
	# `reps/side` and `<unit>/side` variants and `Block N` section headers
	# between groups. R may also be written `R/side`, or as a clock `m:ss`
	# for a hold. W may be `0 lbs` or the word `bodyweight` on a move with no
	# load, both read as 0 kg. A set line is read in its normal form
	# (`normal_form`), so spacing a paste loses or gains does not hide it. An
	# empty or absent description parses to no rows — a set-less strength
	# session counts for load and streak but not tonnage, an honest gap
	# rather than a failure.
	#
	# A line that OPENS like a set line (`opens_like_set`: a bullet, and
	# before it a set count `S × ...`) but yields no row is UNREAD: a set
	# line this grammar cannot read, or one with no exercise name above it.
	# `unread` returns those lines so the caller can report them, and such a
	# line never becomes a name. A blank line, a `Block` header or a bare set
	# count is skipped; any other line names the exercise the set lines
	# below it belong to.
	#
	# Weights are stored per hand (Adapter's convention): `W lbs/side` is one
	# implement of W, whether both hands lift at once or alternate, so the
	# same dumbbells read the same here as in a Strava log. Side semantics
	# then decide only the rep count:
	#   reps/side, R/side → single-side work (alternating): R per side, so
	#                       the rep count doubles.
	#   total reps        → the stated count.
	#   no /side weight   → the stated weight (a barbell or machine total).
	# This is a reading of how the app writes its pastes; no published contract
	# backs it. Units: lbs (Peloton's default) converted through Units.lb_kg;
	# kg as-is.
	#
	# A bodyweight exercise (`Adapter.is_bodyweight`) keeps its sets and
	# reps, or its hold, at 0 kg whatever weight its set line names, which
	# can be the athlete's own mass. A set count with no bullet names no
	# weight and yields no row.
	#
	# A TIMED set line (`3 × 30 sec • 20 lbs`, R followed by one of
	# `time_units`, or `3 × 0:20/side • 55 lbs/side`) is a HOLD: S holds of
	# R at the weight, stored as a row with 0 reps and the held seconds in
	# `hold_s`, so it adds no tonnage and its duration is never read as reps.
	# A hold follows the rep rule with the hold standing in for the rep:
	# time/side is each side held in turn, so the set count doubles; the
	# weight is per hand either way.
	#
	# A line that is only a set count (`S × R`, optionally followed by one
	# word from `count_units`, with or without a refused weight) is never an
	# exercise name, so the name above it stays current.
	#
	# Pure, expects below; the effectful skin (storing rows at analyze) lives
	# in Analyze.roc.

	# a verbatim share summary from the app, the fixture every adapter ships
	# with (Adapter's contract): two exercises, both /side variants
	sample : Str
	sample = "Block 1\nDumbbell Crush Press\n3 × 8 • 30 lbs/side\nDumbbell Snatch Push Press\n3 × 8 reps/side • 25 lbs/side"

	parse : Str -> List(Adapter.SetRow)
	parse = |text| read(text).rows

	# the lines that open like a set line (`opens_like_set`) but yielded no
	# row: a set line this grammar cannot read, or one with no exercise name
	# above it. Empty for text that is not a share summary at all.
	unread : Str -> List(Str)
	unread = |text| read(text).unread

	read : Str -> { rows : List(Adapter.SetRow), unread : List(Str) }
	read = |text| {
		lines = List.map(Str.split_on(text, "\n"), |l| Str.trim(l))
		walk = List.fold(
			lines,
			{ exercise: "", rows: [], unread: [] },
			|acc, line| {
				# the set grammar reads the line in its normal form; a name keeps
				# the text as written
				set_line = normal_form(line)
				match parse_set_line(set_line) {
					Ok(s) =>
						if acc.exercise == "" {
							{ ..acc, unread: List.append(acc.unread, line) }
						} else {
							{ ..acc, rows: List.append(acc.rows, { exercise: acc.exercise, sets: s.sets, reps: s.reps, hold_s: s.hold_s, weight_kg: if (Adapter.is_bodyweight(acc.exercise)) 0.0 else s.weight_kg }) }
						}
					Err(_) =>
						if opens_like_set(set_line) {
							# a set line this grammar cannot read is never a name, so the
							# exercise above it stays current
							{ ..acc, unread: List.append(acc.unread, line) }
						} else if line == "" or Str.starts_with(line, "Block ") or is_set_shaped(set_line) {
							# a blank line, a section header or a set count that is not a
							# whole set line ends nothing — the next set line still belongs
							# to the last named exercise, matching how the share format
							# lays out supersets
							acc
						} else {
							{ ..acc, exercise: line }
						}
				}
			},
		)
		{ rows: walk.rows, unread: walk.unread }
	}

	# A line with the spacing a paste or a re-typed line can lose or gain put
	# back the way the app writes it: a no-break space or a tab is a space,
	# the multiplication sign, the bullet, and an ASCII `x` or `X` between two
	# digits stand apart from their neighbours, `·`, `∙` and `●` are the
	# bullet, a spaced ` / ` closes up, and runs of spaces are one.
	normal_form : Str -> Str
	normal_form = |line| {
		swaps = [("\u(00A0)", " "), ("\t", " "), ("·", "•"), ("∙", "•"), ("●", "•"), ("×", " × "), ("•", " • ")]
		spaced = space_digit_x(List.fold(swaps, line, |acc, (from, to)| Str.replace_each(acc, from, to)))
		single = Str.join_with(List.keep_if(Str.split_on(spaced, " "), |t| t != ""), " ")
		Str.replace_each(single, " / ", "/")
	}

	# `3x8` as `3 x 8`: an `x` or `X` with a digit on each side gets a space on
	# each side; one beside a letter or a space (`2x Burpees`) is left alone
	space_digit_x : Str -> Str
	space_digit_x = |s| {
		bytes = Str.to_utf8(s)
		digit_at = |i|
			match List.get(bytes, i) {
				Ok(b) => b >= 48 and b <= 57
				Err(_) => False
			}
		pieces = List.map_with_index(bytes, |b, i| if ((b == 120 or b == 88) and i > 0 and digit_at(i - 1) and digit_at(i + 1)) [32, b, 32] else [b])
		Str.from_utf8(List.join(pieces)).ok_or(s)
	}

	# a line, in its normal form, that carries a bullet and, before it, opens
	# with `S × R`: whole digits, the multiplication sign or an ASCII `x` or
	# `X`, and any figure. A bullet alone does not make a set line (`Circuit
	# • 3 rounds`); a set count before it does, so this is what an unreadable
	# set line is known by.
	opens_like_set : Str -> Bool
	opens_like_set = |line|
		match Str.split_on(line, " • ") {
			[left, _, ..] =>
				match List.keep_if(Str.split_on(Str.trim(left), " "), |t| t != "") {
					[s, mark, _, ..] => all_digits(s) and (mark == "×" or mark == "x" or mark == "X")
					_ => False
				}
			_ => False
		}

	all_digits : Str -> Bool
	all_digits = |s| {
		bytes = Str.to_utf8(s)
		!(List.is_empty(bytes)) and List.all(bytes, |b| b >= 48 and b <= 57)
	}

	# the text before any bullet is exactly `S × R`, or `S × R` and one word
	# that `unit_word` turns into one of `count_units`, however many spaces
	# separate the parts; a name that merely starts that way ("5 x 5 Back
	# Squat") is not
	is_set_shaped : Str -> Bool
	is_set_shaped = |line| {
		left = Str.trim(List.first(Str.split_on(line, " • ")).ok_or(line))
		bare =
			match List.keep_if(Str.split_on(left, " "), |t| t != "") {
				[_, _, _] => True
				[_, _, _, unit] => List.contains(count_units, unit_word(unit))
				_ => False
			}
		match parse_sets_reps(left) {
			Ok(_) => bare
			Err(_) => False
		}
	}

	# the words a bare set count may name after its rep figure
	count_units : List(Str)
	count_units = List.concat(["reps"], time_units)

	# a unit word lowercased and without a trailing `/side`, or a cut-short
	# start of it (`side_cut`), so `Reps/Side`, `sec/side` and `sec/sid` look
	# up as `reps`, `sec` and `sec`
	unit_word : Str -> Str
	unit_word = |w| side_cut(Str.with_ascii_lowercased(w)).base

	# the words that make R a duration rather than a rep count
	time_units : List(Str)
	time_units = ["s", "sec", "secs", "seconds", "min", "mins", "minutes"]

	# one set line in its normal form (`normal_form`), or Err for anything
	# else: a set part, ` • `, and a weight part, each of which must read. A
	# bullet alone does not make a set line (`Circuit • 3 rounds`). A timed
	# line is a hold: 0 reps and the held seconds in `hold_s`.
	parse_set_line : Str -> Try({ sets : I64, reps : I64, hold_s : I64, weight_kg : F64 }, [NotASetLine])
	parse_set_line = |line|
		match Str.split_on(line, " • ") {
			[left, right] => {
				lr = parse_sets_reps(left)?
				w = parse_weight(right)?
				# a /side weight is one implement, stored per hand; per-side reps or
				# holds double the count, never the weight
				weight_kg = w.kg
				if lr.timed {
					hold_s = Adapter.read_seconds("${lr.reps.to_str()} ${lr.unit}").map_err(|_| NotASetLine)?
					sets = if (lr.per_side) lr.sets * 2 else lr.sets
					Ok({ sets, reps: 0, hold_s, weight_kg })
				} else {
					reps = if (lr.per_side) lr.reps * 2 else lr.reps
					Ok({ sets: lr.sets, reps, hold_s: 0, weight_kg })
				}
			}
			_ => Err(NotASetLine)
		}
	# `3 × 8`, `3 × 8 reps`, `3 × 8 reps/side`, `3 × 8/side`, `3 × 30 sec`,
	# `3 × 0:20/side` — an ASCII `x` or `X` tolerated, since a re-typed paste
	# is one keyboard away from the multiplication sign. `per_side` says a
	# token of R's part has one slash, followed by `side` or a cut-short start
	# of it (`side_cut`). `timed` says R is a clock `m:ss`, or the word after
	# it is one of `time_units` (through `unit_word`, so in any case and with
	# or without `/side`), so R counts seconds or minutes, not reps; `unit` is
	# that word without its `/side`, `sec` for a clock, "" on a line that is
	# not timed.
	parse_sets_reps : Str -> Try({ sets : I64, reps : I64, per_side : Bool, timed : Bool, unit : Str }, [NotASetLine])
	parse_sets_reps = |left| {
		parts =
			match List.keep_oks([" × ", " x ", " X "], |mark| split_once(left, mark)) {
				[pair, ..] => Ok(pair)
				[] => Err(NotASetLine)
			}
		(sets_s, reps_part) = parts?
		sets = I64.from_str(Str.trim(sets_s)).map_err(|_| NotASetLine)?
		reps_tokens = List.keep_if(Str.split_on(Str.trim(reps_part), " "), |t| t != "")
		# the figure may carry its own `/side` (`8/side`, `0:20/side`), and the
		# side may sit on the figure or on the word after it, whole or cut short
		reps_tok = unit_word(List.first(reps_tokens).map_err(|_| NotASetLine)?)
		per_side = List.any(reps_tokens, |t| side_cut(Str.with_ascii_lowercased(t)).per_side)
		clock = clock_seconds(reps_tok)
		reps =
			match clock {
				Ok(secs) => secs
				Err(_) => I64.from_str(reps_tok).map_err(|_| NotASetLine)?
			}
		if sets <= 0 or reps <= 0 {
			Err(NotASetLine)
		} else {
			unit =
				match clock {
					Ok(_) => "sec"
					Err(_) =>
						match reps_tokens {
							[_, word, ..] => if (List.contains(time_units, unit_word(word))) unit_word(word) else ""
							_ => ""
						}
				}
			Ok({ sets, reps, per_side, timed: unit != "", unit })
		}
	}

	# the two sides of the one `mark` in `text`; Err when it holds none or
	# several
	split_once : Str, Str -> Try((Str, Str), [NoMark])
	split_once = |text, mark|
		match Str.split_on(text, mark) {
			[a, b] => Ok((a, b))
			_ => Err(NoMark)
		}

	# a clock figure `m:ss` (`0:20`, `1:30`) as seconds: whole minutes, then
	# two-digit seconds under 60; Err for anything else
	clock_seconds : Str -> Try(I64, [NotAClock])
	clock_seconds = |tok|
		match Str.split_on(tok, ":") {
			[m_s, s_s] =>
				if all_digits(m_s) and all_digits(s_s) and List.len(Str.to_utf8(s_s)) == 2 {
					m = I64.from_str(m_s).map_err(|_| NotAClock)?
					s = I64.from_str(s_s).map_err(|_| NotAClock)?
					if (s < 60) Ok(m * 60 + s) else Err(NotAClock)
				} else {
					Err(NotAClock)
				}
			_ => Err(NotAClock)
		}

	# `30 lbs/side`, `25 lbs`, `12.5 kg`, `0 lbs`, `bodyweight`, in any case.
	# The app writes `0 lbs` and `bodyweight` on moves with no load, both
	# read as 0 kg. A `/side` cut short at the end of a pasted note (`/s`,
	# `/si`, `/sid`) reads as `/side`, since nothing else follows a unit. A
	# right side with no recognised unit, or a negative weight, is not a set
	# line.
	parse_weight : Str -> Try({ kg : F64, per_side : Bool }, [NotASetLine])
	parse_weight = |right| {
		tokens = List.keep_if(Str.split_on(Str.trim(right), " "), |t| t != "")
		match tokens {
			[word] => if (Str.with_ascii_lowercased(word) == "bodyweight") Ok({ kg: 0.0, per_side: Bool.False }) else Err(NotASetLine)
			[num_s, unit, ..] => {
				n = F64.from_str(num_s).map_err(|_| NotASetLine)?
				u = side_cut(Str.with_ascii_lowercased(unit))
				kg =
					match u.base {
						"lbs" | "lb" => Ok(n * Units.lb_kg)
						"kg" => Ok(n)
						_ => Err(NotASetLine)
					}?
				if n < 0.0 {
					Err(NotASetLine)
				} else {
					Ok({ kg, per_side: u.per_side })
				}
			}
			_ => Err(NotASetLine)
		}
	}

	# a lowercased unit split at its slash: the unit before it, and whether
	# what follows is `side` or a cut-short start of it. A unit with any
	# other tail keeps the whole word as its base, which no unit matches.
	side_cut : Str -> { base : Str, per_side : Bool }
	side_cut = |unit|
		match Str.split_on(unit, "/") {
			[base, tail] => if (tail != "" and Str.starts_with("side", tail)) { base, per_side: Bool.True } else { base: unit, per_side: Bool.False }
			_ => { base: unit, per_side: Bool.False }
		}
}

# the shipped sample parses to exactly what the app's grammar says it should
expect {
	rows = Peloton.parse(Peloton.sample)
	match rows {
		[a, b] =>
			a.exercise == "Dumbbell Crush Press"
				and a.sets == 3
				and a.reps == 8
				# 30 lbs/side, total reps: stored per hand, one 30 lb dumbbell
				and (a.weight_kg - 13.6077711).abs() < 0.001
				and b.exercise == "Dumbbell Snatch Push Press"
				and b.sets == 3
				# 8 reps/side → 16 total, each moving one side's 25 lbs
				and b.reps == 16
				and (b.weight_kg - 11.33980925).abs() < 0.001
		_ => False
	}
}

# kg passes through unconverted; decimal weights parse; ASCII x accepted
expect {
	rows = Peloton.parse("Goblet Squat\n4 x 10 • 22.5 kg")
	match rows {
		[a] => a.sets == 4 and a.reps == 10 and (a.weight_kg - 22.5).abs() < 0.001
		_ => False
	}
}

# plain totals: no /side anywhere means the stated numbers stand
expect {
	rows = Peloton.parse("Barbell Bench Press\n5 × 5 • 135 lbs")
	match rows {
		[a] => a.sets == 5 and a.reps == 5 and (a.weight_kg - 61.23496995).abs() < 0.001
		_ => False
	}
}

# tolerance: junk lines skip, a set line before any exercise name skips,
# Block headers and blank lines do not become exercise names
expect {
	rows = Peloton.parse("3 × 8 • 30 lbs\nBlock 2\n\nsome prose that is not a set\nCurl\n2 × 12 • 15 lbs")
	match rows {
		[a] => a.exercise == "Curl" and a.sets == 2 and a.reps == 12
		_ => False
	}
}

# a bodyweight line (no bullet) is not a set line; the exercise keeps its
# name for a later weighted line, matching the share format's superset layout
expect {
	rows = Peloton.parse("Push Up\n3 × 15\nDumbbell Row\n3 × 10 • 40 lbs")
	match rows {
		[a] => a.exercise == "Dumbbell Row" and a.sets == 3 and a.reps == 10
		_ => False
	}
}

# empty and absent parse to nothing — the honest-gap contract
expect List.is_empty(Peloton.parse(""))
expect List.is_empty(Peloton.parse("a ride description with no sets at all"))

# a zero set count and a negative weight are refused, not stored: a row
# claiming either is paste damage, and tonnage built on it would be a
# confident wrong number. A zero WEIGHT is a set line (see below).
expect List.is_empty(Peloton.parse("Curl\n0 × 12 • 15 lbs"))
expect List.is_empty(Peloton.parse("Curl\n3 × 12 • -15 lbs"))

# an unrecognised unit is not a set line: it yields no row, and `unread`
# reports it (below)
expect List.is_empty(Peloton.parse("Curl\n3 × 12 • 15 stone"))

# a bodyweight line that names a weight keeps its sets and reps at 0 kg,
# its assisted form too, while a loaded lift beside it keeps its weight
expect {
	rows = Peloton.parse("Chin Up\n3 × 6 • 175 lbs\nAssisted Pull Up\n3 × 8 • 185 lbs\nDumbbell Row\n3 × 10 • 40 lbs")
	match rows {
		[a, b, c] =>
			a.exercise == "Chin Up" and a.sets == 3 and a.reps == 6 and a.weight_kg == 0.0
				and b.exercise == "Assisted Pull Up" and b.sets == 3 and b.reps == 8 and b.weight_kg == 0.0
				and (c.weight_kg - 18.1436948).abs() < 0.001
		_ => False
	}
}

# a line that opens with `S × R` but is not a whole set line never becomes
# an exercise name: the next set line still belongs to the name above it
expect {
	refused = Peloton.parse("Chin Up\n3 × 6 • 15 stone\n3 × 6 • 175 lbs")
	bare = Peloton.parse("Push Up\n3 × 15\n3 × 10 • 40 lbs")
	match (refused, bare) {
		([a], [b]) => a.exercise == "Chin Up" and a.weight_kg == 0.0 and b.exercise == "Push Up" and b.sets == 3 and b.reps == 10
		_ => False
	}
}

# the app's own block of moves with no load, verbatim: `0 lbs` is a set
# line at 0 kg, on a listed bodyweight move and an unlisted one alike, and
# the circuit's header is prose
expect {
	text = "Block 3\nCircuit • 3 rounds\nAssisted Tuck Ups\n3 × 8 • 0 lbs\nAssisted Pull Up\n3 × 6 • 0 lbs\nDumbbell Iso Wide Grip Row\n3 × 12 reps/side • 30 lbs/side"
	match Peloton.parse(text) {
		[a, b, c] =>
			a.exercise == "Assisted Tuck Ups" and a.sets == 3 and a.reps == 8 and a.weight_kg == 0.0
				and b.exercise == "Assisted Pull Up" and b.sets == 3 and b.reps == 6 and b.weight_kg == 0.0
				and c.exercise == "Dumbbell Iso Wide Grip Row" and c.reps == 24 and (c.weight_kg - 13.6077711).abs() < 0.001
				and List.is_empty(Peloton.unread(text))
		_ => False
	}
}

# per-side reps written `R/side` double like `R reps/side`
expect {
	match Peloton.parse("Renegade Row\n3 × 8/side • 25 lb/side") {
		[a] => a.sets == 3 and a.reps == 16 and (a.weight_kg - 11.3398093).abs() < 0.001
		_ => False
	}
}

# `bodyweight` in the weight's place is a set line at 0 kg
expect {
	match Peloton.parse("Negative Pull Up\n3 × 6 • bodyweight") {
		[a] => a.exercise == "Negative Pull Up" and a.sets == 3 and a.reps == 6 and a.weight_kg == 0.0
		_ => False
	}
}

# a clock hold per side: three holds of 20 s on each side, at the weight
# per hand, with no reps
expect {
	match Peloton.parse("Dumbbell Farmer Carry\n3 × 0:20/side • 55 lbs/side") {
		[a] => a.sets == 6 and a.reps == 0 and a.hold_s == 20 and (a.weight_kg - 24.9475804).abs() < 0.001
		_ => False
	}
}

# a `/side` cut short at the end of the note still reads as per side
expect {
	match Peloton.parse("Dumbbell Skull Crusher\n3 × 12 • 12.5 lbs/sid") {
		[a] => a.sets == 3 and a.reps == 12 and (a.weight_kg - 5.6699046).abs() < 0.001
		_ => False
	}
}

# a clock with seconds of 60 or more, or not two digits, is not a figure
expect List.is_empty(Peloton.parse("Plank\n3 × 0:75 • 10 lbs")) and List.is_empty(Peloton.parse("Plank\n3 × 1:5 • 10 lbs"))

# unread: a line that opens like a set line but yields no row is returned,
# whether the grammar refused it or no exercise name stood above it; the
# exercise around it still parses
expect {
	text = "3 × 8 • 30 lbs\nCurl\n3 × 12 • 15 stone\nRow\n3 × 10 • 40 lbs"
	Peloton.unread(text) == ["3 × 8 • 30 lbs", "3 × 12 • 15 stone"] and List.len(Peloton.parse(text)) == 1
}

# prose with a bullet, a name that starts like a count, the shipped sample
# and text that is no share summary at all leave nothing unread
expect List.is_empty(Peloton.unread("Circuit • 3 rounds\n5 x 5 Back Squat\n5 × 5 • 225 lbs")) and List.is_empty(Peloton.unread(Peloton.sample)) and List.is_empty(Peloton.unread("a ride description with no sets at all"))

# a name that merely starts like a set count is still a name: its sets are
# its own, loaded, and not filed under the bodyweight move above it
expect {
	rows = Peloton.parse("Chin Up\n3 × 6 • 175 lbs\n5 x 5 Back Squat\n5 × 5 • 225 lbs\n3 x 3 Ladder\n3 × 3 • 50 lbs")
	match rows {
		[a, b, c] =>
			a.exercise == "Chin Up" and a.weight_kg == 0.0
				and b.exercise == "5 x 5 Back Squat" and b.sets == 5 and (b.weight_kg - 102.0582833).abs() < 0.001
				and c.exercise == "3 x 3 Ladder" and (c.weight_kg - 22.6796185).abs() < 0.001
		_ => False
	}
}

# a bare set count is skipped however it is spaced, with `reps/side` and a
# refused unit, and with a time unit: each time the next set line belongs to
# the name above it
expect {
	spaced = Peloton.parse("Push Up\n3  ×  15\n3 × 10 • 40 lbs")
	side = Peloton.parse("Chin Up\n3 × 8 reps/side • 25 kgs/side\n3 × 6 • 175 lbs")
	timed = Peloton.parse("Plank\n3 × 30 Sec\n3 × 6 • 20 lbs")
	match (spaced, side, timed) {
		([a], [b], [c]) => a.exercise == "Push Up" and b.exercise == "Chin Up" and c.exercise == "Plank" and c.weight_kg == 0.0
		_ => False
	}
}

# a timed set line with a weight is a hold, in any case of its unit: its
# sets and weight at 0 reps with the held seconds, so it adds no tonnage and
# keeps the name for the rep line after it
expect {
	rows = Peloton.parse("Weighted Plank\n3 × 30 sec • 20 lbs\n3 × 1 Min • 20 lbs\n3 × 6 • 20 lbs\nCurl\n3 × 10 • 20 lbs")
	match rows {
		[a, b, c, d] =>
			a.exercise == "Weighted Plank" and a.sets == 3 and a.reps == 0 and a.hold_s == 30 and (a.weight_kg - 9.0718474).abs() < 0.001
				and b.exercise == "Weighted Plank" and b.sets == 3 and b.reps == 0 and b.hold_s == 60
				and c.exercise == "Weighted Plank" and c.reps == 6 and c.hold_s == 0
				and d.exercise == "Curl" and d.sets == 3 and d.reps == 10 and d.hold_s == 0 and (d.weight_kg - 9.0718474).abs() < 0.001
		_ => False
	}
}

# per-side holds: time/side doubles the hold count; the weight is per hand
# under weight/side and as stated under a plain weight, whether the sides
# are held in turn or at once. A bare per-side count is skipped.
expect {
	rows = Peloton.parse("Suitcase Hold\n3 × 30 sec/side • 20 lbs\n3 × 30 Sec/Side\n3 × 45 sec/side • 20 lbs/side\nFarmer Hold\n2 × 1 min • 20 lbs/side\n3 × 8 reps/side • 20 lbs/side")
	match rows {
		[a, b, c, d] =>
			a.exercise == "Suitcase Hold" and a.sets == 6 and a.reps == 0 and a.hold_s == 30 and (a.weight_kg - 9.0718474).abs() < 0.001
				and b.sets == 6 and b.hold_s == 45 and (b.weight_kg - 9.0718474).abs() < 0.001
				and c.exercise == "Farmer Hold" and c.sets == 2 and c.hold_s == 60 and (c.weight_kg - 9.0718474).abs() < 0.001
				and d.reps == 16 and d.hold_s == 0
		_ => False
	}
}

# a bodyweight hold that names a weight keeps its hold at 0 kg
expect {
	rows = Peloton.parse("Plank\n3 × 60 sec • 175 lbs")
	match rows {
		[a] => a.exercise == "Plank" and a.sets == 3 and a.hold_s == 60 and a.weight_kg == 0.0
		_ => False
	}
}

# `/side` and the weight unit read in any case: capitalised per-side work
# doubles its reps, and every /side weight stays per hand, as lowercase does
expect {
	rows = Peloton.parse("Curl\n3 × 8 Reps/Side • 20 LBS/Side\nRow\n3 × 8 • 20 LBS/Side")
	match rows {
		[a, b] => a.reps == 16 and (a.weight_kg - 9.0718474).abs() < 0.001 and b.reps == 8 and (b.weight_kg - 9.0718474).abs() < 0.001
		_ => False
	}
}

# spacing a paste loses or gains does not hide a set line: a no-break
# space, a closed-up `3×8`, `3x8` or `•30`, a tab, another bullet glyph and an
# upper-case `X` all read as the line the app writes
expect {
	nb = "\u(00A0)"
	text = "Curl\n3${nb}×${nb}8 • 30 lbs\n3×8 •30 lbs\n3 × 8\t• 30 lbs\n3 × 8 · 30 lbs\n3 X 8 • 30 lbs\n3x8 • 30 lbs"
	rows = Peloton.parse(text)
	List.len(rows) == 6 and List.all(rows, |r| r.exercise == "Curl" and r.sets == 3 and r.reps == 8 and (r.weight_kg - 13.6077711).abs() < 0.001) and List.is_empty(Peloton.unread(text))
}

# a set line with a figure the grammar cannot read is unread, never a name:
# the set line after it still belongs to the move above, bodyweight rule
# included
expect {
	text = "Pull Up\n3 × AMRAP • bodyweight\n3 × 8 • 20 lbs"
	match Peloton.parse(text) {
		[a] => a.exercise == "Pull Up" and a.reps == 8 and a.weight_kg == 0.0 and Peloton.unread(text) == ["3 × AMRAP • bodyweight"]
		_ => False
	}
}

# a `/side` cut short on a hold's unit, and a spaced `reps / side`, read
# per side like their whole forms
expect {
	match (Peloton.parse("Plank\n3 × 30 sec/sid • 10 lbs"), Peloton.parse("Curl\n3 × 8 reps / side • 30 lbs")) {
		([h], [c]) => h.sets == 6 and h.reps == 0 and h.hold_s == 30 and c.reps == 16
		_ => False
	}
}

# a name keeps the text as written, though its set lines are read in
# their normal form
expect {
	match Peloton.parse("3×3 Ladder\n3 × 3 • 50 lbs") {
		[a] => a.exercise == "3×3 Ladder" and a.sets == 3 and a.reps == 3
		_ => False
	}
}
