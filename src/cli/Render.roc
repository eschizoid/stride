import core.Fmt
import core.Units
import core.Sports
import core.Load
import Metrics
import Drain

Render :: [].{
	# ── pure text-rendering helpers for human CLI output ────────────────
	# aligned table: headers + rows -> multiline string. Keeps a table within max_total
	# display-columns WITHOUT losing text: columns take natural width; on overflow the
	# single widest column (in practice free text) is squeezed and word-wrapped across
	# continuation lines, character-broken when it has no space to break at.
	#
	# NOT a guarantee: fit_caps squeezes ONE column floored at min_col, so a table
	# whose excess exceeds what that column can surrender still overruns — nothing
	# silently truncates either way. A table needing two columns squeezed needs a
	# narrower design, not a wider budget.
	#
	# 100, not 80: the squeezed column is always the free-text one, so budget spent
	# elsewhere comes out of the workout description. Fixed rather than $COLUMNS:
	# env-dependent output would make the e2e layout assertions unreproducible.
	max_total = 100
	min_col = 12

	# widest display-width among a set of already-wrapped lines
	max_line_width : List(Str) -> U64
	max_line_width = |ls| List.fold(ls, 0, |m, l| m.max(display_width(l)))

	# the builtins have no List.reverse on this compiler — same fold+prepend as Csv.reverse
	reverse_list : List(a) -> List(a)
	reverse_list = |xs| List.fold(xs, [], |acc, x| List.prepend(acc, x))

	# [0, 1, .., n-1]
	indices : U64 -> List(U64)
	indices = |n| indices_go(n, [])
	indices_go : U64, List(U64) -> List(U64)
	indices_go = |n, acc| if (n == 0) acc else indices_go(n - 1, List.prepend(acc, n - 1))

	# greedy word-wrap: pack space-separated words into lines of at most `cap`
	# display-columns. A lone word wider than cap is CHARACTER-BROKEN by hard_break —
	# free text and generated spans (`2021-12-13..2022-02-10`) both produce giant
	# tokens.
	wrap_cell : Str, U64 -> List(Str)
	wrap_cell = |s, cap|
		if (display_width(s) <= cap)
			[s]
		else {
			packed = List.fold(
				Str.split_on(s, " "),
				{ cur: "", out: [] },
				|st, word| {
					cand = if (Str.is_empty(st.cur)) word else "${st.cur} ${word}"
					if (display_width(cand) <= cap)
						{ cur: cand, out: st.out }
					else if (Str.is_empty(st.cur))
						{ cur: "", out: List.append(st.out, word) }
					else
						{ cur: word, out: List.append(st.out, st.cur) }
				},
			)
			final = if (Str.is_empty(packed.cur)) packed.out else List.append(packed.out, packed.cur)
			# The packer above can only break BETWEEN words, so a space-free token comes out
			# whole and ignores the cap — which made fit_caps' squeeze a no-op for precisely
			# the columns that needed it (a season block is `2021-12-13..2022-02-10`,
			# one token). Breaking every produced line covers the arm that carries an
			# over-long word forward as `cur` too.
			capped = List.join(List.map(final, |line| hard_break(line, cap)))
			if (List.is_empty(capped)) [""] else capped
		}

	# Split a token that has no break opportunity into cap-wide pieces. Cuts land on
	# CHARACTER boundaries: a UTF-8 continuation byte contributes 0 display width, so it
	# can never trigger a cut and never starts a piece — the same byte classification
	# `display_width` uses, kept in step with it deliberately.
	hard_break : Str, U64 -> List(Str)
	hard_break = |s, cap|
		if cap == 0 or display_width(s) <= cap {
			[s]
		} else {
			st = List.fold(
				Str.to_utf8(s),
				{ cur: [], w: 0, out: [] },
				|acc, b| {
					bw = if (b >= 0xF0) 2 else if (b < 0x80 or b >= 0xC0) 1 else 0
					if (bw > 0 and acc.w + bw > cap and !(List.is_empty(acc.cur)))
						{ cur: [b], w: bw, out: List.append(acc.out, acc.cur) }
					else
						{ cur: List.append(acc.cur, b), w: acc.w + bw, out: acc.out }
				},
			)
			pieces = if (List.is_empty(st.cur)) st.out else List.append(st.out, st.cur)
			List.map(pieces, |bs| Str.from_utf8(bs).ok_or(""))
		}

	idx_of_max : List(U64) -> U64
	idx_of_max = |xs| {
		best = List.fold(
			List.map_with_index(xs, |w, i| { i, w }),
			{ i: 0, w: 0 },
			|acc, cur| if (cur.w > acc.w) cur else acc,
		)
		best.i
	}

	# per-column caps that fit sum(widths) + borders into max_total, squeezing only
	# the widest column (the real case is one dominant text column). natural widths
	# in, caps out; unchanged when the table already fits.
	fit_caps : List(U64), U64 -> List(U64)
	fit_caps = |nat, overhead| {
		total = List.fold(nat, 0, |a, w| a + w)
		budget = if (max_total > overhead) max_total - overhead else 0
		if (total <= budget)
			nat
		else {
			wi = idx_of_max(nat)
			ww = List.get(nat, wi).ok_or(0)
			excess = total - budget
			shrunk = if (ww > excess + min_col) ww - excess else min_col
			List.map_with_index(nat, |w, i| if (i == wi) shrunk else w)
		}
	}

	# A row that renders as a horizontal RULE spanning the whole table — the
	# spreadsheet divider — instead of as cells. It IS a row, so it sits in the rows
	# list: `render_table(headers, [row_a, Render.rule, row_b])`. Drawn with the
	# table's own border glyphs (cell text like `···` reads as data, and collides with
	# `progress`, where `···` means a gap in time). An EMPTY row, not a string
	# sentinel: a sentinel cell in a one-column table would render data as a divider,
	# while a row with no cells cannot collide with anything.
	rule : List(Str)
	rule = []

	is_rule : List(Str) -> Bool
	is_rule = |row| List.is_empty(row)

	render_table : List(Str), List(List(Str)) -> Str
	render_table = |headers, rows| {
		ncols = List.len(headers)
		overhead = 3 * ncols + 1
		# rule rows carry no data, so they must not influence column widths or wrapping
		data_rows = List.keep_if(rows, |r| !(is_rule(r)))
		nat = List.fold(
			List.prepend(data_rows, headers),
			List.map(headers, |_| 0),
			|acc, row|
				List.map_with_index(acc, |w, i| w.max(display_width(List.get(row, i).ok_or("")))),
		)
		caps = fit_caps(nat, overhead)
		# each row/header becomes a list of columns, each column a list of wrapped lines
		wrap_row = |row| List.map_with_index(row, |cell, i| wrap_cell(cell, List.get(caps, i).ok_or(display_width(cell))))
		wh = wrap_row(headers)
		# Wrap ONCE, keeping rule positions inline: one pass, no index bookkeeping, linear
		# whatever the list representation.
		tagged = List.map(rows, |row| if (is_rule(row)) Rule else Data(wrap_row(row)))
		wrs = List.keep_oks(
			tagged,
			|t| match t {
				Data(w) => Ok(w)
				Rule => Err({})
			},
		)
		widths = List.fold(
			List.prepend(wrs, wh),
			List.map(headers, |_| 0),
			|acc, wrow|
				List.map_with_index(acc, |w, i| w.max(max_line_width(List.get(wrow, i).ok_or([])))),
		)
		# render one logical row (columns-of-wrapped-lines) as N physical lines,
		# continuation lines leaving the other columns blank
		render_wrow = |wrow| {
			height = List.fold(wrow, 1, |h, col_lines| h.max(List.len(col_lines)))
			phys = List.map(
				indices(height),
				|k| {
					cells = List.map_with_index(
						wrow,
						|col_lines, i| {
							w = List.get(widths, i).ok_or(0)
							pad_right(List.get(col_lines, k).ok_or(""), w)
						},
					)
					"│ ${Str.join_with(cells, " │ ")} │"
				},
			)
			Str.join_with(phys, "\n")
		}
		border = |left, mid, right|
			"${left}${Str.join_with(List.map(widths, |w| Str.repeat("─", w + 2)), mid)}${right}"
		# `tagged` already holds every row in order, wrapped once, with rules marked — so
		# emitting the body is a straight map with no counter and no second wrapping pass.
		body = List.map(
			tagged,
			|t| match t {
				Rule => border("├", "┼", "┤")
				Data(w) => render_wrow(w)
			},
		)
		all_lines = List.join([
			[border("╭", "┬", "╮"), render_wrow(wh), border("├", "┼", "┤")],
			body,
			[border("╰", "┴", "╯")],
		])
		Str.join_with(all_lines, "\n")
	}

	pad_right : Str, U64 -> Str
	pad_right = |s, w| {
		n = display_width(s)
		if (n >= w) s else Str.concat(s, Str.repeat(" ", w - n))
	}

	# A delta that keeps its sign: "+5" reads as a build, "-3" as an unload.
	#
	# The sign comes from x, NOT from the rounded string. fmt0 rounds -0.4 to "0", so
	# deciding the sign afterwards silently turned every small unload into a flat zero —
	# and left the two directions asymmetric, since +0.4 still printed "+0". A magnitude
	# that rounds away is still a direction that did not.
	#
	# The companion rule: sign-from-value is for a delta standing ALONE. When a delta
	# prints beside its own operands, the caller computes it from the operands as
	# DISPLAYED (compare_screen's rounded-difference deltas), because three individually
	# correct roundings can contradict each other and a table must agree with itself.
	signed : F64 -> Str
	signed = |x| {
		mag = fmt0((x).abs())
		if (x >= 0.0) "+${mag}" else "-${mag}"
	}

	# signed(), at the precision the signal is displayed in. A pace delta of
	# -0.04 m/s is the difference between 4:00/km and 4:03/km; through fmt0 it
	# renders as "0" and the column reports no change at all.
	# The session's change from first rep to last, signed so NEGATIVE always means WORSE —
	# weaker watts, or slower pace. Sport-consistent by decision: a cyclist and a
	# runner read the same sign for the same event. The cost is that for pace this is the
	# inverse of raw last-minus-first, since pace counts UP as you slow down, so the legend
	# states what the number is rather than how it was subtracted.
	#
	# Takes both ENDPOINTS, not the delta: pace cannot be derived from a speed difference,
	# because k/v_last - k/v_first is not a function of (v_last - v_first).
	fade_value : [Metric, Imperial], F64, F64, Str -> Str
	fade_value = |units, first, last, signal|
		if signal == "pace" {
			if first <= 0.0 or last <= 0.0 {
				"-"
			} else {
				per = match units {
					Metric => 1000.0
					Imperial => 1609.344
				}
				# seconds per unit at each end; slowing means MORE seconds, so first-minus-last
				# is negative exactly when the athlete faded
				d = ((per / first) - (per / last)).round_to_i64_try().ok_or(0)
				if (d >= 0) "+${mmss(d)}" else "-${mmss((d).abs())}"
			}
		} else {
			d = last - first
			mag = seg_value(units, (d).abs(), signal)
			if (d >= 0.0) "+${mag}" else "-${mag}"
		}

	# The progress trend verdict: a closed set of three, pinned by equality below
	# (ADR 0012). Named rather than inline for exactly that reason — see the pin.
	trend_label : Bool, Bool -> Str
	trend_label = |improved, declined|
		if (improved) "improving" else if (declined) "declining" else "holding steady"

	# How long the band has held, appended to the state. Takes the TAG, not a
	# flattened number: the caller must not decide what Unknown means on the renderer's
	# behalf, and AtLeast must not arrive collapsed into an exact-looking integer.
	#
	#   Known(n)   n >= 2  -> ", 12 days in this band"
	#   AtLeast(n) n >= 2  -> ", 31+ days in this band"   the window ran out mid-streak
	#   either,    n <= 1  -> ""                          a one-day streak is noise
	#   Unknown            -> ""                          nothing known about today
	#
	# The `+` is the point of AtLeast reaching this far: `summary` reads a 31-day
	# window, so a 45-day streak truncates, and a bare "31" would present the window
	# size as a measurement.
	band_days_phrase : [Known(I64), AtLeast(I64), Unknown] -> Str
	band_days_phrase = |band|
		match band {
			Unknown => ""
			Known(n) => if (n <= 1) "" else ", ${(n).to_str()} days in this band"
			AtLeast(n) => if (n <= 1) "" else ", ${(n).to_str()}+ days in this band"
		}

	# The clause that gives the form verdict a memory. Words, not a signed number,
	# because this sits mid-sentence between the value and the band label.
	#
	# Unknown renders as "" and the caller drops the clause entirely: too little history to
	# compare is NOT "level with a week ago", and saying so would be the same fabrication
	# `form_delta_7d` returns a tag to avoid.
	#
	# Rounding is what decides "level", not the raw value: the line prints whole points, so
	# a 0.4 swing that displays as 0 must not read "up 0 from a week ago".
	form_trend_phrase : [Known(F64), Unknown] -> Str
	form_trend_phrase = |delta|
		match delta {
			Unknown => ""
			Known(d) =>
				if fmt0((d).abs()) == "0" {
					", level with a week ago"
				} else if d > 0.0 {
					", up ${fmt0(d)} from a week ago"
				} else {
					", down ${fmt0((d).abs())} from a week ago"
				}
		}

	pad_left : Str, U64 -> Str
	pad_left = |s, w| {
		n = display_width(s)
		if (n >= w) s else Str.concat(Str.repeat(" ", w - n), s)
	}

	# ── narration (ADR 0007, shaped by ADR 0021) ─────────────────────────
	# Every long step is one line on stderr with its label in a fixed column. A
	# step with a count draws the bar; a step without one draws a spinner that
	# advances per unit of work and is replaced by its result when the step
	# ends. Every glyph here is one terminal column wide.
	step_column : U64
	step_column = 20

	# the label padded to the column, keeping one space after a label as long
	# as the column so the content never touches it
	step_label : Str -> Str
	step_label = |label| if (display_width(label) + 1 >= step_column) "${label} " else pad_right(label, step_column)

	# a finished step: its label, then what it did
	step_line : Str, Str -> Str
	step_line = |label, text| "${step_label(label)}${text}"

	# a finished step as a human sees it, redrawn over whatever frame its line
	# held: padded to the widest frame drawn there, the wait's, so no tail of a
	# longer frame is left behind it
	step_result : Str, Str -> Str
	step_result = |label, text| pad_right(step_line(label, text), wait_frame_width)

	# A `\r`-redrawn progress bar for the steps slow enough to look hung. Reuses the
	# table's `█` so the glyph vocabulary stays one thing.
	#
	# CONSTANT WIDTH is the whole trick, not cosmetics: `\r` returns the cursor without
	# clearing the line, so a frame shorter than the one before it leaves the tail of the
	# previous frame on screen ("358/723" redrawn as "9/723" would read "9/7233"). The bar
	# is a fixed cell count and `done` is left-padded to the width of `total`, so every
	# frame of a given run is exactly as wide as the last.
	progress_bar_cells : U64
	progress_bar_cells = 10

	progress_bar : Str, U64, U64 -> Str
	progress_bar = |label, done, total|
		if total == 0 {
			# nothing to divide by, and no honest fraction to show. Same spelling as
			# progress_line's, so a total==0 run reads identically in both modes.
			"${label}…"
		} else {
			capped = if (done > total) total else done
			filled = (capped * progress_bar_cells) // total
			counts = "${pad_left((capped).to_str(), Str.count_utf8_bytes((total).to_str()))}/${(total).to_str()}"
			step_line(label, "[${Str.repeat("█", filled)}${Str.repeat("░", progress_bar_cells - filled)}] ${counts}")
		}

	# machine mode gets the same information with no carriage returns and no padding
	# of the count — a `\r` is garbage in a CI log, and these lines are appended,
	# never redrawn
	progress_line : Str, U64, U64 -> Str
	progress_line = |label, done, total|
		if total == 0 {
			"${label}…"
		} else {
			# clamp exactly as the bar does. The denominator is read once up front and a
			# later pass can re-invalidate rows, so the running count CAN exceed it —
			# without this, machine mode prints an impossible `730/723` while human mode
			# shows a full bar at 723/723.
			capped = if (done > total) total else done
			step_line(label, "${(capped).to_str()}/${(total).to_str()}")
		}

	# the spinner of a step with no count, one frame per unit of work
	spinner : U64 -> Str
	spinner = |tick|
		match tick % 4 {
			0 => "|"
			1 => "/"
			2 => "-"
			_ => "\\"
		}

	spin_frame : Str, U64 -> Str
	spin_frame = |label, tick| step_line(label, spinner(tick))

	# the activity list's result: what it re-listed, and of those what was new
	# or changed. Updated is said only when something was.
	list_result : { checked : U64, new : U64, updated : U64 } -> Str
	list_result = |c| {
		updated = if (c.updated > 0) ", ${(c.updated).to_str()} updated" else ""
		"${(c.checked).to_str()} checked, ${(c.new).to_str()} new${updated}"
	}

	# the time left: m:ss under an hour, hours and minutes past one
	clock_left : I64 -> Str
	clock_left = |secs| {
		s = (secs).max(0)
		if s >= 3600 {
			"${(s // 3600).to_str()} h ${((s % 3600) // 60).to_str()} min"
		} else {
			ss = s % 60
			"${(s // 60).to_str()}:${if (ss < 10) "0" else ""}${(ss).to_str()}"
		}
	}

	# The wait's frame, padded to one width: the time left counts down, and
	# "10:00 left" redrawn as "9:59 left" would otherwise leave a character of
	# the previous frame behind it.
	wait_frame_width : U64
	wait_frame_width = 72

	wait_frame : { daily : Bool, tick : U64, at : Str, left : I64 } -> Str
	wait_frame = |w|
		if w.daily {
			pad_right(step_line("daily allowance", "${spinner(w.tick)} returns ${w.at}, ${clock_left(w.left)} left"), wait_frame_width)
		} else {
			pad_right(step_line("waiting for Strava", "${spinner(w.tick)} next batch at ${w.at}, ${clock_left(w.left)} left"), wait_frame_width)
		}

	# An epoch second as the athlete's clock reads it, given the zone's offset
	# in minutes east of UTC: "HH:MM", with the date after it when that local
	# day is not the one `now` falls in.
	local_time : I64, I64, I64 -> Str
	local_time = |at, offset_min, now| {
		at_local = Metrics.epoch_to_iso(at + offset_min * 60)
		now_local = Metrics.epoch_to_iso(now + offset_min * 60)
		hhmm = Str.from_utf8(List.sublist(Str.to_utf8(at_local), { start: 11, len: 5 })).ok_or("")
		day = Str.from_utf8(List.sublist(Str.to_utf8(at_local), { start: 0, len: 10 })).ok_or("")
		now_day = Str.from_utf8(List.sublist(Str.to_utf8(now_local), { start: 0, len: 10 })).ok_or("")
		if (day == now_day) hhmm else "${hhmm} on ${day}"
	}

	# a count with the noun it needs: "1 activity", "2 activities"
	count_noun : I64, Str, Str -> Str
	count_noun = |n, one, many| "${(n).to_str()} ${if (n == 1) one else many}"

	# terminal columns, not bytes. Each UTF-8 code point has exactly one lead byte
	# (< 0x80, or >= 0xC0); continuation bytes (0x80–0xBF) don't count. Astral-plane
	# code points (4-byte lead, >= 0xF0) are emoji — Strava activity names have them
	# ("Morning Ride 🚴") — and occupy TWO terminal columns, so count them twice.
	# (Latin-1/accents like é are 2-byte width-1; our box/bullet glyphs are 3-byte
	# width-1 — both stay correct.)
	display_width : Str -> U64
	display_width = |s|
		List.fold(
			Str.to_utf8(s),
			0,
			|acc, b|
				if b >= 0xF0 {
					acc + 2
				} else if b < 0x80 or b >= 0xC0 {
					acc + 1
				} else {
					acc
				},
		)

	# One line warning that the fitness series has not converged, or "" when it has. CTL
	# seeds at zero and needs ~two 42-day time constants before the absolute form bands mean
	# anything, so until then the number above is real arithmetic on an incomplete series —
	# low, not wrong, but not comparable to the bands either. Empty string renders as a
	# blank line the caller already allows for.
	warming_up_note : Bool, I64 -> Str
	warming_up_note = |warming, days|
		if warming {
			"  ⚠ only ${I64.to_str(days)} days of history — fitness is still converging, so form reads low"
		} else {
			""
		}

	# integer-rounded float, e.g. 71.9 -> "72"
	fmt0 : F64 -> Str
	fmt0 = |x| {
		r = x.round_to_i64_try().ok_or(0)
		I64.to_str(r)
	}

	# one-decimal float, e.g. 12.34 -> "12.3" (for distances). Preserves the sign
	# for -1 < x < 0.
	fmt1 : F64 -> Str
	fmt1 = |x| {
		n = (x * 10.0).round_to_i64_try().ok_or(0)
		Fmt.tenths(n)
	}

	# Rows keyed by a Strava sport, folded under each sport's plain name
	# (core.Sports.plain_name, the name the window's views use): Workout and
	# WeightTraining are one "strength" row, every ride spelling one
	# "cycling" row. A name keeps the place of its first row; `merge` adds a
	# later row into it.
	by_plain_name : List(a), (a -> Str), (a, a -> a) -> List({ name : Str, row : a })
	by_plain_name = |rows, sport_of, merge|
		List.fold(
			rows,
			[],
			|acc, r| {
				n = Sports.plain_name(sport_of(r))
				match List.find_first_index(acc, |e| e.name == n) {
					Ok(i) =>
						match List.get(acc, i) {
							Ok(e) => (List.set(acc, i, { name: n, row: merge(e.row, r) })).ok_or(acc)
							Err(_) => acc
						}

					Err(_) => List.append(acc, { name: n, row: r })
				}
			},
		)

	# two-decimal float, e.g. 0.979 -> "0.98". Preserves the sign for -1 < x < 0
	# (where the integer part rounds to 0 but the value is negative).
	fmt2 : F64 -> Str
	fmt2 = |x| {
		n = (x * 100.0).round_to_i64_try().ok_or(0)
		Fmt.hundredths(n)
	}

	# ── Units ───────────────────────────────────────────────────────────────────────
	# The conversion rule lives in core.Units, one implementation for BOTH binaries:
	# the window renders the same quantities, and a second copy of a conversion
	# constant is how two surfaces drift apart while each looks right alone. These
	# bindings keep the Render.* spelling every CLI call site and unit expect uses —
	# the e2e unit source-sweep greps those spellings, so delegation must not
	# rename them. `pace_per_dist` was `pace_per_km`, renamed when it stopped
	# always being per km: a name asserting a unit while returning the other is
	# exactly the drift this codebase keeps paying for.
	dist_value : [Metric, Imperial], F64 -> F64
	dist_value = Units.dist_value

	dist_unit : [Metric, Imperial] -> Str
	dist_unit = Units.dist_unit

	pace_unit : [Metric, Imperial] -> Str
	pace_unit = Units.pace_unit

	elev_value : [Metric, Imperial], F64 -> F64
	elev_value = Units.elev_value

	elev_unit : [Metric, Imperial] -> Str
	elev_unit = Units.elev_unit

	pace_per_dist : [Metric, Imperial], F64, I64 -> Str
	pace_per_dist = Units.pace_per_dist

	# seconds -> "62m", rounded to the nearest minute by core Fmt.minutes,
	# the rule the window's minutes share
	mins : I64 -> Str
	mins = |secs|
		Str.concat(I64.to_str(Fmt.minutes(secs)), "m")

	# m:ss for interval durations — 181 -> "3:01"; whole minutes keep :00 so
	# columns align ("12:00", not "12m")
	mmss : I64 -> Str
	mmss = |secs| {
		m = secs // 60
		sec = secs - m * 60
		pad = if (sec < 10) "0" else ""
		"${I64.to_str(m)}:${pad}${I64.to_str(sec)}"
	}

	# h:mm:ss for durations that can exceed an hour. mmss is for intervals and
	# renders 222 days as "320807:09"; tte is the first screen where a query a
	# couple of watts off CP produces that, so it needs the wider format.
	hms : I64 -> Str
	hms = |secs|
		if secs < 3600 {
			mmss(secs)
		} else {
			h = secs // 3600
			rest = secs - h * 3600
			m = rest // 60
			sec = rest - m * 60
			mpad = if (m < 10) "0" else ""
			spad = if (sec < 10) "0" else ""
			"${I64.to_str(h)}:${mpad}${I64.to_str(m)}:${spad}${I64.to_str(sec)}"
		}

	SegRow : { ordinal : I64, kind : Str, start_s : I64, dur_s : I64, avg_signal : F64, signal : Str, peak_hr : F64, avg_hr : F64, rec_drop : F64, rec_drop_known : Bool }

	# A speed in m/s rendered as time-per-distance, which is what a runner reads
	# (the rule and its rationale live with the body in core.Units).
	pace_from_speed : [Metric, Imperial], F64 -> Str
	pace_from_speed = Units.pace_from_speed

	seg_unit : [Metric, Imperial], Str -> Str
	seg_unit = |units, signal|
		if signal == "power" {
			"W"
		} else if signal == "pace" {
			match units {
				Metric => "/km"
				Imperial => "/mi"
			}
		} else {
			" m/s"
		}

	# The legend names the unit in prose, where the inline suffix's "/km" would read as
	# "reps ... in /km". Same information, different position, so it gets its own spelling
	# rather than the legend trimming a suffix meant to butt against a number.
	seg_legend_unit : [Metric, Imperial], Str -> Str
	seg_legend_unit = |units, signal|
		if signal == "power" {
			"W"
		} else if signal == "pace" {
			pace_unit(units)
		} else {
			"m/s"
		}

	# A rep's rate, in the reader's units. Power stays watts; a PACE signal goes through
	# pace_from_speed. An empty signal keeps fmt2: it means "no signal identified", and
	# inventing a pace for it would assert something the detector did not find.
	seg_value : [Metric, Imperial], F64, Str -> Str
	seg_value = |units, v, signal|
		if (signal == "power") fmt0(v) else if (signal == "pace") pace_from_speed(units, v) else fmt2(v)

	# "4×[3:00 @ 251W / 2:00 easy]" — the detected shape in one line. Reps vary in
	# the wild, so durations/levels are MEDIANS of the work reps; recovery is the
	# median of recovery segments lying BETWEEN the first and last work (a
	# mislabeled pre-work block must not become the "easy" half of a summary).
	# No between-works recoveries (blocks back to back, or a single rep) drops
	# the "/ ..." half.
	interval_summary : [Metric, Imperial], List(SegRow) -> Str
	interval_summary = |units, segs| {
		works = List.keep_if(segs, |s| s.kind == "work")
		n = List.len(works)
		if n == 0 {
			""
		} else {
			first_work = (List.first(works)).map_ok(|w| w.ordinal).ok_or(0)
			last_work = (List.last(works)).map_ok(|w| w.ordinal).ok_or(0)
			recs = List.keep_if(segs, |s| s.kind == "recovery" and s.ordinal > first_work and s.ordinal < last_work)
			med = |xs| {
				sorted = List.sort_with(xs, |a, b| if (a < b) Before else if (a > b) After else Same)
				(List.get(sorted, List.len(sorted) // 2)).ok_or(0.0)
			}
			sig = (List.first(works)).map_ok(|w| w.signal).ok_or("power")
			dur_med = med(List.map(works, |w| ((w.dur_s)).to_f64()))
			level_med = med(List.map(works, |w| w.avg_signal))
			work_part = "${I64.to_str((n).to_i64_wrap())}×[${mmss((dur_med).round_to_i64_try().ok_or(0))} @ ${seg_value(units, level_med, sig)}${seg_unit(units, sig)}"
			if List.is_empty(recs) {
				Str.concat(work_part, "]")
			} else {
				rec_med = med(List.map(recs, |r| ((r.dur_s)).to_f64()))
				"${work_part} / ${mmss((rec_med).round_to_i64_try().ok_or(0))} easy]"
			}
		}
	}

	# per-rep detail lines under the summary — one work rep per line, HR only when
	# measured (honest absence: a rep with no HR simply has no hr clause)
	segments_block : [Metric, Imperial], List(SegRow) -> Str
	segments_block = |units, segs| {
		works = List.keep_if(segs, |s| s.kind == "work")
		lines = List.map_with_index(
			works,
			|w, i| {
				base = "rep ${I64.to_str(((i)).to_i64_wrap() + 1)}  ${mmss(w.dur_s)} @ ${seg_value(units, w.avg_signal, w.signal)}${seg_unit(units, w.signal)}"
				hr_part = if (w.avg_hr > 0.0) " · hr ${fmt0(w.avg_hr)} avg / ${fmt0(w.peak_hr)} peak" else ""
				drop_part = if (w.rec_drop_known) " · 60s drop ${signed(w.rec_drop)}" else ""
				Str.join_with([base, hr_part, drop_part], "")
			},
		)
		Str.join_with(lines, "\n")
	}

	# HR drift across work reps (fatigue signature): last rep's avg minus first's,
	# only when both were measured. Err(NotEnough) below 2 measured reps.
	seg_hr_drift : List(SegRow) -> Try(F64, [NotEnough])
	seg_hr_drift = |segs| {
		measured = List.keep_if(segs, |s| s.kind == "work" and s.avg_hr > 0.0)
		if List.len(measured) < 2 {
			Err(NotEnough)
		} else {
			first = (List.first(measured)).map_ok(|s| s.avg_hr).ok_or(0.0)
			last = (List.last(measured)).map_ok(|s| s.avg_hr).ok_or(0.0)
			Ok(last - first)
		}
	}

	## the group label when progress keys on detected structure rather than name: the
	## shape first, then one anchor-day class name so the reader recognizes the session.
	## "~" because mates match by duration BAND, not exact duration — the label must not
	## promise a precision the predicate does not have.
	structure_group_label : I64, I64, Str, Str -> Str
	structure_group_label = |reps, mean_dur, sig, example|
		"${(reps).to_str()}×[~${mmss(mean_dur)}] ${sig} intervals (${example})"

	## the week-add echo's target clause (ADR 0014) — the canonical literal,
	## numbers only. Lives in Render, not Plan, so the 0012 sweep expect below this
	## module can actually run over it (Plan.roc is not in the pure-test list).
	target_note : [NoT, T(Metrics.Target)] -> Str
	target_note = |pt|
		match pt {
			T(t) => " (target ${Metrics.target_literal(t)})"
			NoT => ""
		}

	## complete's target-vs-execution clause — numbers on both sides, no verdict:
	## "did they hit it" is the coach's sentence (ADR 0012, ADR 0014 §4). Each kind
	## states its own signal; an execution with no comparable signal names why.
	target_match_note : { target_kind : Str, target_literal : Str, target_pace_unit : Str, target_rpe : I64, detected_known : Bool, detected_reps : I64, detected_mean_dur_s : I64, detected_mean_watts : F64, exec_known : Bool, exec_reason : Str, hr_under_s : I64, hr_in_s : I64, hr_over_s : I64, hr_mean : F64, zone_below_s : I64, zone_in_s : I64, zone_above_s : I64, pace_basis : Str, pace_actual_s : F64, pace_reps : I64, rpe_actual : F64 } -> Str
	target_match_note = |tm| if (tm.target_kind == "") "" else " (target ${tm.target_literal}; ${target_result_text(tm)})"

	## The execution half of that clause alone, "" for a session with no target. It
	## is the text `complete` and `rate` store on the planned session, so the
	## window's plan view states the same result the CLI printed.
	target_result_text : { target_kind : Str, target_literal : Str, target_pace_unit : Str, target_rpe : I64, detected_known : Bool, detected_reps : I64, detected_mean_dur_s : I64, detected_mean_watts : F64, exec_known : Bool, exec_reason : Str, hr_under_s : I64, hr_in_s : I64, hr_over_s : I64, hr_mean : F64, zone_below_s : I64, zone_in_s : I64, zone_above_s : I64, pace_basis : Str, pace_actual_s : F64, pace_reps : I64, rpe_actual : F64 } -> Str
	target_result_text = |tm| {
		d = Metrics.rep_dur_str
		pace = |s| "${Metrics.rep_dur_str(s.round_to_i64_try().ok_or(0))}${tm.target_pace_unit}"
		what =
			if tm.target_kind == "power" {
				if (tm.detected_known) "detected ${(tm.detected_reps).to_str()}×~${mmss(tm.detected_mean_dur_s)} @ ${(tm.detected_mean_watts.to_i64_wrap()).to_str()}W" else "no detected power intervals to compare"
			} else if !(tm.exec_known) {
				reason =
					if (tm.exec_reason == "no_hr_stream") "no heart-rate stream"
					else if (tm.exec_reason == "no_hr_zones") "no heart-rate zone split"
					else if (tm.exec_reason == "pace_unit_mismatch") "this sport is not paced ${tm.target_pace_unit}"
					else if (tm.exec_reason == "no_distance") "no distance recorded"
					else if (tm.exec_reason == "no_rating") "no rating recorded (stride rate)"
					else tm.exec_reason
				"nothing to compare: ${reason}"
			} else if tm.target_kind == "hr" {
				"HR in band ${d(tm.hr_in_s)}, over ${d(tm.hr_over_s)}, under ${d(tm.hr_under_s)}, mean ${(tm.hr_mean.round_to_i64_try().ok_or(0)).to_str()} bpm"
			} else if tm.target_kind == "zone" {
				"in zone ${d(tm.zone_in_s)}, above ${d(tm.zone_above_s)}, below ${d(tm.zone_below_s)}"
			} else if tm.target_kind == "rpe" {
				"rated ${fmt1(tm.rpe_actual)}"
			} else if tm.pace_basis == "detected" {
				"detected ${(tm.pace_reps).to_str()} reps at ${pace(tm.pace_actual_s)}"
			} else {
				"whole session at ${pace(tm.pace_actual_s)}"
			}
		if (tm.target_kind == "") "" else what
	}

	# display label for a progress group, from anchor_filter's structured kind
	progress_group_label : [Metric, Imperial], Str, [Exact, SimilarDistance(F64), LoneNoDistance] -> Str
	progress_group_label = |units, name, kind|
		match kind {
			Exact => name
			SimilarDistance(m) => "${name} (~${fmt1(dist_value(units, m))} ${dist_unit(units)} rides)"
			LoneNoDistance => "${name} (no distance recorded — can't match similar rides)"
		}

	# ONE number for the operator and for the sentence describing it. `··· = a break
	# over 90 days` is a user-facing claim, and nothing pinned it: the legend could
	# say "over 60 days" with the comparison still at `> 90` and the whole suite
	# stayed green. Deriving both from this constant makes the drift impossible rather
	# than merely detectable. The inclusivity — `>`, so exactly 90 is NOT a break — is
	# pinned in `tests/e2e.roc`, because a constant cannot express it. Comments across
	# the repo quote the literal 90 as history; only the operator and the legend
	# follow this constant, so moving the number means reading those too.
	gap_days : I64
	gap_days = 90

	# one workout's table + trend verdict, rendered through its sport-aware lens
	# (power->EF, distance->speed/HR, rated->RPE; RPE is lower-is-better). The last two
	# parameters are `scope_dropped`/`scope_why`: the caller passes only the rows the
	# anchor's scope dropped; the lens drops are counted here.
	progress_section : [Metric, Imperial], Str, List(Metrics.ProgressRow), Str, [Ef, SpeedHr, Rpe], [Asc, Desc], List(I64), U64, Str -> Str
	progress_section = |units, name, rows, asked, lens, sort, all_days, scope_dropped, scope_why| {
		higher = Metrics.lens_higher_better(lens)
		sc = |row| Metrics.lens_score(lens, row).ok_or(0.0)
		# `rows` arrives BEFORE the lens gate, so the table can show a session the lens
		# cannot score rather than deleting it. Everything that reasons about VALUE
		# — scale, trend, verdict count, last-vs-best — reads `scored_rows`, because
		# `ok_or(0.0)` would fold a 0 into the mean and squash the bars against a floor no
		# session reached.
		scored_rows = List.keep_if(rows, |r| Metrics.lens_score(lens, r).is_ok())
		unscored_n = List.len(rows) - List.len(scored_rows)
		scores = List.map(scored_rows, sc)
		max_s = List.fold(scores, 0.0, |acc, s| acc.max(s))
		min_s = List.fold(scores, max_s, |acc, s| acc.min(s))
		best = if (higher) max_s else min_s
		worst = if (higher) min_s else max_s
		pfmt = |v| match lens {
			Rpe => fmt0(v)
			_ => fmt2(v)
		}
		# the SCORED heart rate, not the stored one. This column sits beside
		# `ef`/`spd_hr`, whose legend reads "per heartbeat" — showing 86 next to a score
		# computed from 147.7 makes the legend false with the divisor nowhere on screen.
		# The stored value is still published raw by `activities --json` and `activity`.
		hr_of = |row| if (row.avg_hr_scored > 0.0) fmt0(row.avg_hr_scored) else "-"
		prim_of = |row|
			# "-", never `0.00` with an empty bar. A fabricated zero in the lens column is
			# the same class of lie as a fabricated gap: it reads as a measured worst-ever
			# session rather than as an absent measurement, and it would sit in the same
			# column the bars are scaled against.
			if Metrics.lens_score(lens, row).is_err() {
				"-"
			} else {
				n = Metrics.scale_to_blocks(sc(row), worst, best, 12)
				"${pfmt(sc(row))} ${Str.repeat("█", n)}"
			}
		# The ◀ marker rides on the DATE cell, and headers stay terse (meaning lives in
		# the legend, per the numbers-in-tables philosophy) — both keep every column
		# under render_table's column budget so the BAR column is never the widest one
		# that gets squeezed and word-wrapped mid-bar.
		date_of = |row| if (row.date == asked) "${row.date} ◀" else row.date
		# each lens picks its own columns (list of header + per-row cell); the primary
		# (bar) column direction is already handled by best/worst above
		cols =
			match lens {
				Ef => [
					# "-" at zero, not `0`: a zero here is UNREACHABLE on a scored row (the EF lens
					# requires `np_w > 0`), so it can only mean absent, and it only appears on rows
					# the lens cannot score. `kJ` and `load` keep their bare 0 — the file's convention,
					# and a real value there.
					("np (W)", |row| if (row.np_w > 0.0) fmt0(row.np_w) else "-"),
					("hr", hr_of),
					("W/beat", prim_of),
					# aerobic decoupling per session — "-" when not computable,
					# never a fabricated 0 (0.0 is a real, perfect result)
					("drift", |row| if (row.decoupling_known) "${signed(row.decoupling_pct)}%" else "-"),
					("kJ", |row| fmt0(row.output_kj)),
					("load", |row| fmt0(row.tss)),
				]
				SpeedHr => [
					(Units.split_rate_head(units, (List.first(rows)).map_ok(|r| r.sport).ok_or("")), |row| Units.split_rate(units, row.sport, row.distance_m, row.moving_time)),
					("hr", hr_of),
					("speed/beat", prim_of),
					("drift", |row| if (row.decoupling_known) "${signed(row.decoupling_pct)}%" else "-"),
					# same rule: the speed/HR lens requires `distance_m > 0`, so 0.0 km on
					# a row it refused is an absence rather than a measurement
					(dist_unit(units), |row| if (row.distance_m > 0.0) fmt1(dist_value(units, row.distance_m)) else "-"),
					("load", |row| fmt0(row.tss)),
				]
				Rpe => [
					# "-" at zero here too, but NOT for the neighbours' reason: `lens_score(Rpe, r)`
					# requires only `rpe > 0`, so a fully SCORED row can carry duration 0 and render a
					# full bar beside this cell. `0m` was never a measurement either way; the blank is
					# right, the justification is different.
					("duration", |row| if (row.moving_time > 0) mins(row.moving_time) else "-"),
					("hr", hr_of),
					("rpe", prim_of),
					("load", |row| fmt0(row.tss)),
				]
			}
		headers = List.prepend(List.map(cols, |c| c.0), "date")
		to_cells = |row| List.prepend(List.map(cols, |c| (c.1)(row)), date_of(row))
		gap_row = List.map(headers, |_| "···")
		body_rows = {
			folded = List.fold(
				rows,
				{ prev: -1000000.I64, cells: [] },
				|acc, row| {
					days = Metrics.date_str_to_days(row.date).ok_or(acc.prev)
					# ...against the UNFILTERED series, not the rows that survived the lens. Folding
					# the gap over the filtered list merges the intervals either side of a dropped ride
					# and announces a break that did not happen — and the legend prints "a break over N
					# days", a claim about TRAINING, so the artifact is a false statement rather than
					# an ambiguous glyph. In production `rows` and `all_days` describe the same set
					# (unscorable rows render; a scope drop removes the row from both), so the fold
					# is an identity there — it stays because it handles the case where the two
					# lists diverge. N is `gap_days`, shared with the comparison below,
					# so the printed threshold cannot drift from the tested one.
					with_gap =
						if acc.prev > -1000000 and Metrics.max_real_gap(all_days, acc.prev, days) > gap_days {
							List.append(acc.cells, gap_row)
						} else {
							acc.cells
						}
					{ prev: days, cells: List.append(with_gap, to_cells(row)) }
				},
			)
			# gap markers, scores, and the trend verdict are all computed on the
			# CHRONOLOGICAL rows above; Desc only flips the displayed order. Reversing
			# after the fold keeps each ··· marker between the same two neighbours.
			match sort {
				Asc => folded.cells
				Desc => reverse_list(folded.cells)
			}
		}
		table = render_table(headers, body_rows)
		t = Metrics.trend_ends(scores)
		# no baseline (an unscorable first session) claims neither direction — it falls
		# through to "holding steady" rather than inventing a 0% trend
		trend = Metrics.pct_change(t.early, t.late)
		improved = match trend {
			Ok(p) => if (higher) (p > 5.0) else (p < -5.0)
			Err(NoBaseline) => False
		}
		declined = match trend {
			Ok(p) => if (higher) (p < -5.0) else (p > 5.0)
			Err(NoBaseline) => False
		}
		label = trend_label(improved, declined)
		# Sessions absent from the table are absent from every figure on this line too, and
		# saying so is the difference between a filtered view and a wrong one.
		#
		# TWO clauses, because the two causes have different OUTCOMES: a scope drop is
		# HIDDEN (a different distance, not in this table), while a lens drop is SHOWN
		# with its lens cells blank — calling it hidden while the reader looks at the row
		# would contradict the table. The SCOPE reason
		# arrives from the caller (only the anchor filter can tell its two truncation kinds
		# apart); the LENS reason derives here, where the count it must agree with is
		# counted. The counts match the payload's `hidden_scope`/`hidden_lens` exactly;
		# only the verb differs — the agent reading `sessions[]` genuinely cannot see those
		# rows, and the athlete can.
		scope_clause =
			if scope_dropped == 0 {
				""
			} else {
				"${U64.to_str(scope_dropped)} hidden: ${scope_why}"
			}
		unscored_clause =
			if unscored_n == 0 {
				""
			} else {
				"${U64.to_str(unscored_n)} shown unscored: ${Metrics.lens_needs(lens, unscored_n != 1)}"
			}
		# ONE parenthetical holding both clauses, not two side by side. Two adjacent parens
		# read as two afterthoughts about unrelated things, and these are the two halves of
		# one fact: what happened to the sessions that are not in the trend.
		hidden_note =
			if Str.is_empty(scope_clause) and Str.is_empty(unscored_clause) {
				""
			} else if Str.is_empty(unscored_clause) {
				" (${scope_clause})"
			} else if Str.is_empty(scope_clause) {
				" (${unscored_clause})"
			} else {
				" (${scope_clause}; ${unscored_clause})"
			}
		avg = Metrics.mean(scores)
		short = match lens {
			Ef => "watts per heartbeat"
			SpeedHr => "speed per heartbeat"
			Rpe => "rpe"
		}
		legend = match lens {
			Ef => "W/beat = normalized power (np) / avg HR — watts per heartbeat, climbing = fitter · drift = aerobic decoupling, 2nd half vs 1st — LOWER is better, - = not computable · kJ = total work"
			SpeedHr => "speed/beat = speed per heartbeat — climbing = fitter · drift = aerobic decoupling, 2nd half vs 1st — LOWER is better, - = not computable · ${Units.split_rate_head(units, (List.first(rows)).map_ok(|r| r.sport).ok_or(""))}"
			Rpe => "rpe = how hard it felt (1-10) — for a fixed workout, dropping = adapting"
		}
		# no baseline -> no percentage. Printing "(0%)" there claimed a measurement we
		# never made, which is the whole reason pct_change stopped returning a bare float.
		pct_str = match trend {
			Ok(p) => " (${fmt0(p)}%)"
			Err(_) => ""
		}
		# One session compares its own score against itself, so trend_ends returns early ==
		# late and pct_change dutifully reports a real 0% — "holding steady" reads as a
		# measured finding when it is the absence of one. State the score and stop.
		verdict =
			if List.len(scored_rows) == 1 and scope_dropped == 0 and unscored_n == 0 {
				# "one comparable session" read as though it were pointing at some OTHER
				# session to compare with. The single row IS this session — there is simply
				# no history behind it yet.
				"→ ${short} ${pfmt(avg)} — first session of this workout, nothing to compare against yet"
			} else if List.len(scored_rows) == 1 {
				# ...but only when there IS no history. `hidden_note` once reached the multi-row
				# arm alone, so a workout whose lens could score exactly one session claimed
				# "first session, nothing to compare against yet" over ELEVEN sessions, ten
				# unrated — asserting the absence is worse than the silence it replaced.
				"→ ${short} ${pfmt(avg)} — the only session shown${hidden_note}; the rest are in your log"
			} else {
				"→ ${short} early avg ${pfmt(t.early)} → recent avg ${pfmt(t.late)} (overall avg ${pfmt(avg)}) over ${U64.to_str(List.len(scored_rows))} sessions${hidden_note} — ${label}${pct_str}"
			}
		footer = "${legend}\nbar = scaled worst→best · ◀ marks the asked date · ··· = a break over ${I64.to_str(gap_days)} days"
		"── ${name} ──\n${table}\n\n${verdict}${last_vs_best(scored_rows, lens)}\n\n${footer}"
	}

	# "last vs best" line: the most recent session vs the all-time best FOR THIS LENS
	# (highest score, or lowest for RPE). Empty when last IS the best, or <2 rows.
	last_vs_best : List(Metrics.ProgressRow), [Ef, SpeedHr, Rpe] -> Str
	last_vs_best = |rows, lens| {
		higher = Metrics.lens_higher_better(lens)
		sc = |row| Metrics.lens_score(lens, row).ok_or(0.0)
		pfmt = |v| match lens {
			Rpe => fmt0(v)
			_ => fmt2(v)
		}
		desc = List.sort_with(
			rows,
			|a, b| {
				x = sc(b)
				y = sc(a)
				if (x < y) Before else if (x > y) After else Same
			},
		)
		best_row = if (higher) List.first(desc) else List.last(desc)
		match (List.last(rows), best_row) {
			(Ok(last), Ok(best)) =>
				if last.date == best.date or List.len(rows) < 2 {
					""
				} else {
					# with no baseline there is no gap to state — say nothing rather than
					# "0% below your best", which reads as "you matched it"
					match Metrics.pct_change(sc(best), sc(last)) {
						Err(_) => ""
						Ok(g) => {
							word = if (higher) "below your best" else "above your easiest"
							"\n→ last: ${pfmt(sc(last))} (${last.date}) vs best: ${pfmt(sc(best))} (${best.date}) — ${fmt0(g.abs())}% ${word}"
						}
					}
				}

			_ => ""
		}
	}

	# ── drain note, used by sync's human line ────────────────────────────
	# Takes the TAG, not the payload's string, so a new stop reason is a
	# non-exhaustive match HERE and the branch the compiler forces is the branch
	# that runs.
	#
	# Two counts, because a run's stop and its leftovers are different facts. `owed`
	# is everything the run still owes across the streams, notes and routes queues;
	# `streams` is the streams queue alone, which is what a complete run can leave
	# behind as unreadable stream data. `resume` is the local time the run can
	# continue, as Render.local_time writes it.
	drain_note : Drain.StopReason, { streams : I64, owed : I64, resume : Str, again : Bool } -> Str
	drain_note = |stopped, counts| {
		owed = count_noun(counts.owed, "fetch", "fetches")
		# `again`: the run waited for this period and found it spent on arrival,
		# which stride's own reads cannot explain
		match stopped {
			# A stream body that would not decode is skipped WITHOUT storing, and the
			# id stays queued until it has failed Strava.stream_attempt_cap fetches,
			# so a complete run can still owe those. A 404 is NOT this case: it
			# stores a `{}` marker and leaves the queue at once.
			Complete => if (counts.streams == 0) "" else "${I64.to_str(counts.streams)} had unreadable stream data and retry on the next sync"
			BudgetReached =>
				if counts.owed == 0 {
					""
				} else if counts.again {
					"the read window was still full after the wait, so another app on this token may be using it; ${owed} still owed, and the next window opens at ${counts.resume}"
				} else {
					"filled Strava's read window with ${owed} still owed; the next window opens at ${counts.resume}"
				}
			RateLimited =>
				if counts.owed == 0 {
					""
				} else if counts.again {
					"Strava refused reads in a fresh window with ${owed} still owed; the next window opens at ${counts.resume}"
				} else {
					"Strava refused a read with ${owed} still owed; the next window opens at ${counts.resume}"
				}
			# the one stop that speaks on an EMPTY queue: the pre-flight refusal makes
			# no request, so an empty queue says nothing about whether work remains
			DailyCapReached =>
				if counts.again {
					"today's Strava read allowance was still spent after its reset, so another app on this token may be using it; ${owed} still owed, and it returns at ${counts.resume}, midnight UTC"
				} else if counts.owed == 0 {
					"today's Strava read allowance is used up, so nothing was fetched; it returns at ${counts.resume}, midnight UTC"
				} else {
					"today's Strava read allowance is used up with ${owed} still owed; it returns at ${counts.resume}, midnight UTC"
				}
		}
	}

	# `plan`'s data-freshness line. "" when there is nothing to say, on the same
	# reasoning as sync_screen's tail below: for a human the absence of the line IS the
	# clean signal, and printing two zeros before every planning session trains the eye to
	# skip the row that matters on the day it is not zero.
	#
	# Deliberately NOT triggered by newest_activity lagging as_of. That is true most
	# mornings — the day's ride has not happened yet — so it would fire almost daily and
	# become the noise this guards against. The machine payload carries both dates and a
	# coach can compare them; a human already knows whether they rode today.
	#
	# Each clause names the command that clears it. A count with no next action is the
	# thing the reader has to go look up, which is where a freshness signal stops being
	# used at all.
	freshness_note : { activities_awaiting_metrics : U64, activities_awaiting_metrics_known : Bool, activities_awaiting_streams : I64 } -> Str
	freshness_note = |f| {
		# An unknowable count is NOT silence: the count is 0 in that case, and staying
		# quiet renders as "nothing to do" — the ambiguous zero `*_known` exists to avoid.
		# `analyze` is named because it is the command that fails with the underlying
		# reason. "count", not "queue": what could not be read is the zone config, and
		# "metrics queue unreadable" sends a reader hunting for database damage.
		metrics_note =
			if !(f.activities_awaiting_metrics_known) {
				["awaiting-metrics count unreadable (stride analyze says why)"]
			} else if f.activities_awaiting_metrics > 0 {
				["${U64.to_str(f.activities_awaiting_metrics)} awaiting metrics (stride analyze)"]
			} else {
				[]
			}
		streams_note =
			if f.activities_awaiting_streams > 0 {
				["${I64.to_str(f.activities_awaiting_streams)} awaiting streams (stride sync)"]
			} else {
				[]
			}
		parts = List.concat(metrics_note, streams_note)
		if (List.is_empty(parts)) "" else "DATA: ${Str.join_with(parts, " · ")}"
	}

	# sync's human screen: one summary line, then the form verdict, since sync
	# runs analyze to its fixed point. Takes the payload AND the tag it was built
	# from: `p.stopped` is the WIRE string and nothing here reads it, so a new
	# reason is a non-exhaustive match here and in drain_note. `note` carries
	# what the payload does not: the local time the run can continue, how the
	# analysis ended, the verdict line ("" when there is no form yet), and
	# whether the run asked Strava for anything at all.
	#
	# DO NOT, not CANNOT: the signature takes payload and tag independently, so a
	# caller CAN pass a mismatched pair. The producer binds the tag once and
	# derives `stopped:` from that binding.
	SyncNote : { resume : Str, analysis : [Settled, NoZones, Unsettled], verdict : Str, requested : Bool, again : Bool }

	sync_screen : { synced : U64, new_activities : U64, updated_activities : U64, pruned : U64, streams_fetched : I64, streams_skipped : I64, pending_streams : I64, notes_fetched : I64, notes_skipped : I64, pending_notes : I64, routes_fetched : I64, routes_skipped : I64, pending_routes : I64, stopped : Str, resumable : Bool, resume_at : Str, analyzed : Bool, computed : U64 }, Drain.SyncStop, SyncNote -> Str
	sync_screen = |p, stop, note| {
		n64 = |n| (n).to_i64_wrap()
		# what landed, in the singular or plural each count needs. New and updated
		# lead: the re-listed count is a function of how often the athlete trains,
		# and the activity list's own narration line already reports it.
		landed = List.join([
			if (p.new_activities > 0) [count_noun(n64(p.new_activities), "new activity", "new activities")] else [],
			if (p.updated_activities > 0) ["${U64.to_str(p.updated_activities)} updated"] else [],
			if (p.pruned > 0) ["${U64.to_str(p.pruned)} removed on Strava"] else [],
			if (p.streams_fetched > 0) ["streams for ${I64.to_str(p.streams_fetched)}"] else [],
			if (p.notes_fetched > 0) [count_noun(p.notes_fetched, "strength description", "strength descriptions")] else [],
			if (p.routes_fetched > 0) ["routes for ${I64.to_str(p.routes_fetched)}"] else [],
		])
		# unreadable is not not-yet-fetched, so each says so on its own. A complete
		# run's streams skip is said once, by drain_note's Complete arm.
		unreadable = List.join([
			if (p.streams_skipped > 0 and stop != FromDrain(Complete)) [Str.concat(count_noun(p.streams_skipped, "stream", "streams"), " would not decode")] else [],
			if (p.routes_skipped > 0) [Str.concat(count_noun(p.routes_skipped, "route", "routes"), " would not decode")] else [],
		])
		# a run that asked Strava for nothing says so rather than "nothing new",
		# which would claim it looked
		head =
			if !(note.requested) {
				"nothing synced: this run made no request"
			} else if List.is_empty(landed) {
				"synced, nothing new"
			} else {
				"synced ${Str.join_with(landed, ", ")}"
			}
		skips = if (List.is_empty(unreadable)) "" else " (${Str.join_with(unreadable, ", ")})"
		analysis =
			match note.analysis {
				Settled => "; everything analyzed"
				NoZones => "; nothing analyzed until heart-rate zones are set (`stride setup` sets them)"
				Unsettled => "; scoring did not settle, a stride bug that `stride analyze` describes"
			}
		owed = p.pending_streams + p.pending_notes + p.pending_routes
		# WHY it stopped. A refused LIST is matched first and unconditionally: a
		# first sync is refused with the stream queue at its maximum, and the
		# listing, not the drain, is what is incomplete.
		tail =
			match stop {
				# read from `pruned`, not assumed: the early return before the prune is
				# a fact about Strava.sync!, which this function never observes
				ListRateLimited => {
					prune_claim = if (p.pruned == 0) "; nothing was pruned" else ""
					" — the read window was spent before the activity list ended, so it is incomplete${prune_claim}; the next window opens at ${note.resume}"
				}
				ListDailyCapReached => {
					prune_claim = if (p.pruned == 0) "; nothing was pruned" else ""
					" — Strava refused the activity list with today's read allowance used up, so it is incomplete${prune_claim}; it returns at ${note.resume}, midnight UTC"
				}
				FromDrain(r) => {
					said = drain_note(r, { streams: p.pending_streams, owed, resume: note.resume, again: note.again })
					if (Str.is_empty(said)) "" else " — ${said}"
				}
			}
		verdict = if (Str.is_empty(note.verdict)) "" else "\n${note.verdict}"
		"${head}${skips}${analysis}${tail}${verdict}"
	}

	# analyze's and sync's one verdict line, "" while there is no form yet; the
	# full report lives in `stride summary`
	today_verdict : [Some(F64), None], [Known(F64), Unknown] -> Str
	today_verdict = |tsb, delta|
		match tsb {
			Some(t) => "→ today: form ${fmt0(t)}${form_trend_phrase(delta)} — ${Metrics.form_label(t)}"
			None => ""
		}

	# the line an analyze run prints when its guard stopped a rescore that would
	# not settle
	unsettled_note : U64 -> Str
	unsettled_note = |computed| "scoring stopped after ${U64.to_str(computed)} scores without settling: rows kept invalidating each other, which is a stride bug; please report it with `stride doctor --json` at github.com/eschizoid/stride/issues"

	# a sync payload of a complete run that did nothing, and the note of one that
	# analyzed everything with no verdict; the expects widen them field by field
	sync_fixture : { synced : U64, new_activities : U64, updated_activities : U64, pruned : U64, streams_fetched : I64, streams_skipped : I64, pending_streams : I64, notes_fetched : I64, notes_skipped : I64, pending_notes : I64, routes_fetched : I64, routes_skipped : I64, pending_routes : I64, stopped : Str, resumable : Bool, resume_at : Str, analyzed : Bool, computed : U64 }
	sync_fixture = { synced: 0, new_activities: 0, updated_activities: 0, pruned: 0, streams_fetched: 0, streams_skipped: 0, pending_streams: 0, notes_fetched: 0, notes_skipped: 0, pending_notes: 0, routes_fetched: 0, routes_skipped: 0, pending_routes: 0, stopped: "complete", resumable: False, resume_at: "", analyzed: True, computed: 0 }

	sync_note_fixture : SyncNote
	sync_note_fixture = { resume: "10:45", analysis: Settled, verdict: "", requested: True, again: False }

	# ── load command screen ─────────────────────────────────────────────

	# daily fitness table for short windows; Mon-aligned weekly rollup beyond 14 days
	load_screen : List({ day : Str, tss : F64, ctl : F64, atl : F64, tsb : F64 }) -> Str
	load_screen = |ordered| {
		verdict =
			match List.last(ordered) {
				Ok(today) => {
					# the series is right here, so the trend costs nothing extra — no
					# payload field and no second query, unlike the summary screen
					anchor = Metrics.date_str_to_days(today.day).ok_or(0)
					# DROP unparseable days rather than collapsing them to epoch day 0.
					# Day 0 is a valid day number, so a collapsed row both truncates the
					# streak early (the walk hits a "missing" day that is really present)
					# and becomes a spurious candidate for the 7-days-back lookup on a
					# short window — a fabricated trend where the honest answer is Unknown.
					tsb_series = List.keep_oks(
						ordered,
						|d|
							match Metrics.date_str_to_days(d.day) {
								Ok(day) => Ok({ day, tsb: d.tsb })
								Err(_) => Err({})
							},
					)
					trend = form_trend_phrase(Metrics.form_delta_7d(tsb_series, anchor))
					# the streak can only count as far back as the window `load` was asked
					# for — and now it SAYS so: a streak filling the window renders "N+"
					# rather than a bare N that reads as a measurement
					band = band_days_phrase(Metrics.days_in_band(tsb_series, anchor))
					"→ today: form ${fmt0(today.tsb)}${trend} — ${Metrics.form_label(today.tsb)}${band}"
				}
				Err(_) => ""
			}
		if List.len(ordered) > 14 {
			# long windows: weekly rollup (Mon-aligned) — trajectory, not noise
			day_loads = List.map(
				ordered,
				|d| {
					days: Metrics.date_str_to_days(d.day).ok_or(0),
					tss: d.tss,
					ctl: d.ctl,
					atl: d.atl,
					tsb: d.tsb,
				},
			)
			weeks = Metrics.weekly_rollup(day_loads)
			table = render_table(
				["week of", "sessions", "load", "fitness at end", "form at end"],
				List.map(
					weeks,
					|w| [
						Metrics.days_to_date_str(w.week_start),
						I64.to_str(w.sessions),
						fmt0(w.tss),
						fmt0(w.ctl_end),
						fmt0(w.tsb_end),
					],
				),
			)
			legend =
				\\one row per Mon-Sun week — is fitness (ctl) climbing? is weekly load steady or ramping?
				\\(use `stride load 14` or fewer days for the daily view)
			"${table}\n\n${verdict}\n\n${legend}"
		} else {
			table = render_table(
				["day", "load", "fitness (ctl)", "fatigue (atl)", "form (tsb)"],
				List.map(
					ordered,
					|d| [
						d.day,
						(if (d.tss >= 1.0) fmt0(d.tss) else "rest"),
						fmt0(d.ctl),
						fmt0(d.atl),
						fmt0(d.tsb),
					],
				),
			)
			legend =
				\\load:           training load the day added (power TSS, HR, or sRPE — see doctor)
				\\fitness (ctl):  long-term base, 42d avg — want it climbing slowly
				\\fatigue (atl):  short-term tiredness, 7d avg — spikes after big days, fades with rest
				\\form (tsb):     fitness - fatigue (same day) — negative = fatigued,
				\\                positive = fresh; a hard session drops it the same day
			"${table}\n\n${verdict}\n\n${legend}"
		}
	}

	# ── power-duration curve screen ─────────────────────────────────────
	power_curve_screen : { window_days : U64, sport : Str, points : List({ dur_s : U64, watts : F64 }), cp : F64, w_prime : F64, fit_r2 : F64, fit_points : I64, estimated_sessions : I64 } -> Str
	power_curve_screen = |pc| {
		dur_label = |s|
			if (s < 60) "${U64.to_str(s)}s"
			else if (s % 60 == 0) "${U64.to_str(s // 60)}m"
			else "${U64.to_str(s // 60)}m${U64.to_str(s % 60)}s"
		sport_lbl = if (pc.sport == "") "all power sports" else pc.sport
		header = "power-duration curve — ${sport_lbl}, last ${U64.to_str(pc.window_days)} days"
		if List.is_empty(pc.points) {
			(if (pc.estimated_sessions > 0) "${header}\n\n${Sports.estimated_power_only} in this window: ${pc.estimated_sessions.to_str()} ${if (pc.estimated_sessions == 1) "session carries" else "sessions carry"} only Strava's estimated watts." else "${header}\n\nno power data in this window.")
		} else {
			table = render_table(
				["duration", "best power (W)"],
				List.map(pc.points, |p| [dur_label(p.dur_s), fmt0(p.watts)]),
			)
			# the fit's own quality, on the command that PUBLISHES the fit --
			# without it a 0.72 fit and a perfect one read identically, while
			# the skill tells the coach to weigh the fit first. At exactly two
			# points a line is exact, so r2 is 1 by construction and would be
			# false reassurance; below that there is no fit and it is 0.
			quality =
				if pc.fit_points >= 3.I64 {
					" · fit quality ${fmt2(pc.fit_r2)} of 1, from ${I64.to_str(pc.fit_points)} bests"
				} else {
					" · from ${I64.to_str(pc.fit_points)} bests (a fit quality needs 3)"
				}
			cp_line =
				# both must be positive: power_curve! already zeroes a non-positive fit, but
				# gate here too so a stray negative W′ can never print as a real fit
				if (pc.cp > 0.0 and pc.w_prime > 0.0)
					"→ Critical Power ${fmt0(pc.cp)} W · W′ ${fmt1(pc.w_prime / 1000.0)} kJ${quality}"
				else
					"→ Critical Power: not enough long-duration (≥5 min) data to fit"
			legend =
				\\best mean-max power held for each duration (the peak across the window).
				\\CP ≈ sustainable aerobic ceiling; W′ = the finite above-CP battery (Joules).
			"${header}\n\n${table}\n\n${cp_line}\n\n${legend}"
		}
	}

	# Critical speed's screen. Takes units as a PARAMETER rather than reading a
	# field off the payload: the payload is SI end-to-end (cs in m/s, d_prime in metres)
	# and must not move with the setting, so pace_curve! passes units through a closure
	# and only this function converts.
	#
	# CS prints as a PACE, not as a converted speed. It is a running number and runners
	# read 4:00/km, not 4.17 m/s or 9.3 mph, the same rule the segment screens follow.
	pace_curve_screen : [Metric, Imperial], { window_days : U64, sport : Str, points : List({ dur_s : U64, speed : F64 }), cs : F64, d_prime : F64, fit_r2 : F64, fit_points : I64, available_sports : List(Str) } -> Str
	pace_curve_screen = |units, pc| {
		dur_label = |s|
			if (s < 60) "${U64.to_str(s)}s"
			else if (s % 60 == 0) "${U64.to_str(s // 60)}m"
			else "${U64.to_str(s // 60)}m${U64.to_str(s % 60)}s"
		sport_lbl = pc.sport
		header = "speed-duration curve — ${sport_lbl}, last ${U64.to_str(pc.window_days)} days"
		# No sport named means no fit, deliberately. Pooling every sport that stores a speed
		# would fit ONE curve through unrelated populations — and because analyze writes the
		# speed ladder for anything with a distance stream, that population is mostly RIDES,
		# so the pooled answer came back at bike speed while the screen called it "all pace
		# sports" and SKILL.md told the reading agent to render it as a running pace. The
		# ADR 0002 amendment this command already follows for its WHERE clause says the same
		# thing: a pool swim, an open-water swim and a trail run do not share a speed model.
		# So name the sports that actually hold data rather than inventing a cross-sport one.
		if Str.is_empty(pc.sport) {
			listed = if (List.is_empty(pc.available_sports)) "none in this window" else Str.join_with(pc.available_sports, ", ")
			"speed-duration curve — last ${U64.to_str(pc.window_days)} days\n\ncritical speed is per-sport: a pool swim, an open-water swim and a trail run\ndo not share a speed model, so there is no combined curve to draw.\n\nname one — sports with speed data in this window: ${listed}\n\n  stride pace-curve ${U64.to_str(pc.window_days)} <sport>"
		} else if List.is_empty(pc.points) {
			"${header}\n\nno pace data in this window."
		} else {
			table = render_table(
				["duration", "best pace (${pace_unit(units)})"],
				List.map(pc.points, |p| [dur_label(p.dur_s), pace_from_speed(units, p.speed)]),
			)
			# suppressed below 3 points, for the reason power_curve_screen gives.
			quality =
				if pc.fit_points >= 3.I64 {
					" · fit quality ${fmt2(pc.fit_r2)} of 1, from ${I64.to_str(pc.fit_points)} bests"
				} else {
					" · from ${I64.to_str(pc.fit_points)} bests (a fit quality needs 3)"
				}
			# D' is a DISTANCE, so it converts to yards rather than to miles: the value is
			# a couple of hundred metres and "0.12 mi" would be unreadable at that size.
			dprime =
				match units {
					Metric => "${fmt0(pc.d_prime)} m"
					Imperial => "${fmt0(pc.d_prime * 1.0936133)} yd"
				}
			cs_line =
				# both must be positive: pace_curve! already zeroes a non-positive fit, but
				# gate here too so a stray negative D′ can never print as a real fit
				if (pc.cs > 0.0 and pc.d_prime > 0.0)
					"→ Critical Speed ${pace_from_speed(units, pc.cs)} ${pace_unit(units)} · D′ ${dprime}${quality}"
				else
					{
						# THREE causes, and they are not interchangeable. Too few rungs is a DATA
						# gap. Rungs that hold or rise with duration are a curve no athlete
						# produces, so the model declines rather than fudges. And a curve that
						# descends so steeply the fitted ceiling lands below zero is refused for a
						# third reason entirely — the bests are real and ordered, they just cannot
						# come from one athlete's 2-parameter model.
						#
						# The payload cannot tell these apart: `cs` and `d_prime` are 0 in all
						# three. The points can, and the screen has them — so the shape of the
						# ladder decides which sentence is true, rather than one sentence covering
						# cases it does not describe. A reader seeing three descending durations
						# above "these bests do not descend" learns to distrust the line.
						# Strictly decreasing speed as duration grows. Seeded above any real
						# speed so the first rung always passes; a human sprints nowhere near
						# 1000 m/s.
						descending =
							(
								List.fold(
									pc.points,
									{ ok: True, prev: 1000.0 },
									|a, p| { ok: a.ok and p.speed < a.prev, prev: p.speed },
								)
							).ok
						if (pc.fit_points < 2.I64)
							"→ Critical Speed: needs bests at two different durations"
						else if (!(descending))
							"→ Critical Speed: these bests hold or rise with duration, so no fit is possible"
						else
							"→ Critical Speed: these bests fall too steeply to fit one athlete's curve"
					}
			legend =
				\\best mean-max grade-adjusted pace held for each duration (the peak across the window).
				\\CS ≈ sustainable ceiling; D′ = the finite above-CS distance battery.
			"${header}\n\n${table}\n\n${cs_line}\n\n${legend}"
		}
	}
	# ── summary command screen ──────────────────────────────────────────
	# renders the human report straight from the summary payload — ONE source of
	# numbers for the whole screen. (No type annotation: the payload is the summary
	# record, typed at its call sites in Report and Plan; inference keeps this open.)

	summary_screen = |units, s| {
		z = s.last_28d
		zone_gap =
			if z.hr_streams > 0 and z.z5_s == 0 {
				["    ⚠ zone gap: no Z5 heart-rate time in 28 days (could be no hard sessions, or power-based / short intervals that didn't drive HR to Z5)"]
			} else {
				[]
			}
		ftp_lines =
			if s.ftp.best_20min_w_60d > 0 {
				ftp_calibration_lines(s.ftp)
			} else {
				[]
			}
		zone_lines =
			if (z.hr_streams > 0)
				["    time in HR zones: Z1 ${mins(z.z1_s)}  Z2 ${mins(z.z2_s)}  Z3 ${mins(z.z3_s)}  Z4 ${mins(z.z4_s)}  Z5 ${mins(z.z5_s)}"]
			else
				["    time in HR zones: unavailable (no detailed HR stream in this window)"]
		polarization_lines =
			if (z.intensity_streams > 0 and !(z.polarization_known))
				["    polarization: unavailable (no endurance time; lifting is left out)"]
			else if (z.intensity_streams > 0)
				["    polarization: ${I64.to_str(z.easy_pct)}% easy (Z1-2) / ${I64.to_str(z.moderate_pct)}% moderate (Z3) / ${I64.to_str(z.hard_pct)}% hard (Z4-5)"]
			else
				["    polarization: unavailable (requires HR, power, or distance streams)"]
		last7_line =
			if (s.last_7d.intensity_streams > 0 and s.last_7d.polarization_known)
				"  last 7 days: ${I64.to_str(s.last_7d.sessions)} sessions · ${Fmt.hours_tenths(s.last_7d.moving_time)}h · ${fmt1(dist_value(units, s.last_7d.distance_m))} ${dist_unit(units)} · ${fmt0(s.last_7d.tss)} load — ${I64.to_str(s.last_7d.easy_pct)}% easy / ${I64.to_str(s.last_7d.moderate_pct)}% moderate / ${I64.to_str(s.last_7d.hard_pct)}% hard"
			else
				"  last 7 days: ${I64.to_str(s.last_7d.sessions)} sessions · ${Fmt.hours_tenths(s.last_7d.moving_time)}h · ${fmt1(dist_value(units, s.last_7d.distance_m))} ${dist_unit(units)} · ${fmt0(s.last_7d.tss)} load — intensity unavailable"
		last_hard_str =
			if (s.last_hard_session_date != "") s.last_hard_session_date
			else if (z.intensity_streams == 0) "unavailable (no detailed streams)"
			else "none on record"
		sport_lines =
			if (List.is_empty(s.sports_28d)) []
			else List.concat(
				["", "  sport mix (28d):"],
				List.map(by_plain_name(s.sports_28d, |sp| sp.sport, |a, b| { ..a, sessions: a.sessions + b.sessions, moving_time: a.moving_time + b.moving_time, distance_m: a.distance_m + b.distance_m, tss: a.tss + b.tss }), |e| "    ${e.name}: ${I64.to_str(e.row.sessions)} sessions · ${Fmt.hours_tenths(e.row.moving_time)}h · ${fmt1(dist_value(units, e.row.distance_m))} ${dist_unit(units)} · ${fmt0(e.row.tss)} load"),
			)
		Str.join_with(
			List.join([
				[
					"",
					"── stride report (as of ${s.as_of}) ──────────────────",
					"",
					"  fitness (CTL): ${fmt0(s.fitness_ctl)}   fatigue (ATL): ${fmt0(s.fatigue_atl)}   form (TSB): ${fmt0(s.form_tsb)}",
					# the tag is reconstructed from the pair the payload carries, the same way the
					# trend clause is: JSON needs a number, the renderer needs to know whether
					# that number is exact or a floor
					"  → form ${fmt0(s.form_tsb)}${form_trend_phrase(if (s.form_delta_known) Known(s.form_delta_7d) else Unknown)} — ${Metrics.form_label(s.form_tsb)}${band_days_phrase(if (s.form_band_days <= 0) Unknown else if (s.form_band_days_capped) AtLeast(s.form_band_days) else Known(s.form_band_days))}",
					# Numbers, no verdict: the usual sustainable band is the coach's
					# knowledge, not the engine's. Signed, because a taper reads negative
					# and clamping that to 0 would hide a deliberate unload. Each number
					# names its span (core Load.last_days): a rolling week is not the
					# calendar week the window's ramp card reads, and both read to a tenth.
					"  fitness ramp: ${Fmt.tenths_signed((s.ramp_7d * 10.0).round_to_i64_try().ok_or(0))} ${Load.last_days(7)} · ${Fmt.tenths_signed((s.ramp_28d_avg * 10.0).round_to_i64_try().ok_or(0))} a week averaged ${Load.last_days(28)}",
					# CTL starts at zero, so a short history reads LOW rather than unknown and the
					# form verdict above is drawn from absolute bands that do not apply yet. Say so
					# here, not only in the JSON — a human reading a confident-looking number has no
					# other way to know it is still converging.
					warming_up_note(s.ctl_warming_up, s.load_days),
					"",
					"  last 28 days:",
					"    ${I64.to_str(z.sessions)} sessions · ${Fmt.hours_tenths(z.moving_time)}h · ${fmt1(dist_value(units, z.distance_m))} ${dist_unit(units)}",
					"    training load: ${fmt0(z.tss)} (${I64.to_str(z.measured_pct)}% measured by power or pace — rest estimated from HR/RPE; see doctor)",
				],
				# tier line: descriptive provenance for the load number above
				# it — high = measured power OR distance-measured pace, medium = HR/RPE,
				# low = Strava relative-effort. States the mix, prescribes nothing; absent when
				# the window is empty rather than claiming 0/0/0.
				if z.load_coverage.known {
					["    confidence: ${I64.to_str(z.load_coverage.high_pct)}% high · ${I64.to_str(z.load_coverage.medium_pct)}% medium · ${I64.to_str(z.load_coverage.low_pct)}% low"]
				} else {
					[]
				},
				zone_lines,
				polarization_lines,
				zone_gap,
				ftp_lines,
				sport_lines,
				[
					"",
					last7_line,
					"  last hard session (5+ min hard, by power or HR): ${last_hard_str}",
					# stimulus spacing: counts and a median gap — measurements,
					# not verdicts; the gap renders only when there is one to state
					"  hard days: ${I64.to_str(s.hard_days.d14)} in 14d · ${I64.to_str(s.hard_days.d28)} in 28d${if (s.hard_days.spacing_known) " · median gap ${I64.to_str(s.hard_days.spacing_median_days_28d)}d" else ""}",
					"  open planned sessions: ${I64.to_str(s.pending_sessions)}",
				],
			]),
			"\n",
		)
	}

	# the estimate follows the two-session rule while the best is a raw
	# measurement, so a lone session has a best and no FTP: say so rather than
	# print a 0 W figure derived from a real number. The derived line names the
	# best the estimate stands on, which is the estimate over 0.95 exactly (the
	# derivation is best × 0.95); the raw best beside it reads the inclusive
	# 59-day display window, one day narrower than the estimate's, so the two
	# can differ at the window's edge
	ftp_calibration_lines = |ftp|
		if ftp.source == "test" {
			[
				"",
				"  FTP: ~${fmt0(ftp.estimated_ftp_w)}W — from your ${ftp.test_kind} test on ${ftp.test_date}, above the 60-day estimate of ${fmt0(ftp.derived_ftp_w)}W",
			]
		} else if ftp.estimated_ftp_w > 0 {
			[
				"",
				"  FTP (60d): ~${fmt0(ftp.estimated_ftp_w)}W — derived from your best 20-min power ${fmt0(ftp.estimated_ftp_w / 0.95)}W",
			]
		} else {
			[
				"",
				"  FTP (60d): none yet — one session carries a 20-min best (${fmt0(ftp.best_20min_w_60d)}W); an FTP needs two in the window",
			]
		}
	# ── season screen (ADR 0011) ──────────────────────────────────
	# Blocks bounded by absence, described by measurement. No phase names; the trend is
	# a fitted line reported by its ENDPOINTS, because a slope plus a low r2 gets read
	# as "no trend" and r2 is scatter, not evidence the slope is zero.
	#
	# Held under the 100-column budget.
	# The block TOTAL and SLOPE moved to the payload; the total is recoverable from the
	# row (/wk x span) but the SLOPE is NOT — its divisor is the ordinal distance
	# between fitted endpoints, which equals span_weeks - 1 only while the last week is
	# complete, so dividing visible cells is off by 6-17%.
	season_screen = |p| {
		block_rows = List.map(
			p.blocks,
			|b| {
				trend = if (b.trend_known) "${fmt0(b.fitted_start_load)}→${fmt0(b.fitted_end_load)}" else "-"
				r2c = if (b.trend_known) fmt2(b.trend_r2) else "-"
				pol = if (b.polarization_known) "${I64.to_str(b.easy_pct)}/${I64.to_str(b.moderate_pct)}/${I64.to_str(b.hard_pct)}" else "-"
				# the share is named when the "dominant" family is close to a coin
				# flip, because 52% and 95% published identically
				share = if (b.ftp_known and b.ftp_family_pct < 65.I64) " ${I64.to_str(b.ftp_family_pct)}%" else ""
				ftp = if (b.ftp_known) "${b.ftp_family}${share} ${ftp_path(b.ftp_start, b.ftp_end, b.ftp_lo, b.ftp_hi)}" else "-"
				# the * marks the WEEK COUNT, not the end date -- glued to the date
				# it read as "approximately 08-16", not "this block is still open"
				# (issue-claims: quoting -- that phrase is rendered output, not an issue state)
				wks = "${I64.to_str(b.weeks)}/${I64.to_str(b.span_weeks)}"
				wk = if (b.closed) wks else "${wks}*"
				["${b.start_date}..${b.end_date}", wk, I64.to_str(b.sessions), fmt0(b.mean_weekly_load), trend, r2c, pol, ftp]
			},
		)
		block_body =
			if List.is_empty(p.blocks) {
				# an empty table frame plus a legend explaining what a block is,
				# on a screen with no blocks, is what this replaces
				"no training blocks yet — there are scored days on record but none carry load; `stride analyze` rebuilds them"
			} else {
				render_table(["block", "wk", "sess", "/wk", "trend", "fit", "intensity", "ftp"], block_rows)
			}
		# 13, not 12: twelve is the one count that hides the same month a year
		# ago, which is the obvious question to ask of a month table
		recent = if (List.len(p.months) > 13) List.drop_first(p.months, List.len(p.months) - 13) else p.months
		month_hdr =
			if List.len(p.months) > List.len(recent) {
				"── by month · last ${I64.to_str((List.len(recent)).to_i64_wrap())} of ${I64.to_str((List.len(p.months)).to_i64_wrap())} ──"
			} else {
				"── by month ──"
			}
		month_rows = List.map(
			recent,
			|m| {
				mshare = if (m.ftp_known and m.ftp_family_pct < 65.I64) " ${I64.to_str(m.ftp_family_pct)}%" else ""
				[
					if (m.partial) "${m.month}*" else m.month,
					fmt0(m.load),
					I64.to_str(m.sessions),
					if (m.ftp_known) "${m.ftp_family}${mshare} ${ftp_path(m.ftp_start, m.ftp_end, m.ftp_lo, m.ftp_hi)}" else "-",
				]
			},
		)
		month_tbl = render_table(["month", "load", "sessions", "ftp"], month_rows)
		# Topic lines, not one 690-character paragraph: at that length the definitions a
		# reader needs are exactly the ones they skip.
		legend = Str.join_with(
			[
				"a block is a run of training weeks closed by ${I64.to_str(p.gap_weeks)}+ weeks with no load — described by measurement, never named as a phase",
				"wk = weeks trained / calendar weeks spanned · sess = activities · /wk = load over the span",
				"trend = where the fitted line starts and ends · fit = how much of the week-to-week scatter that line explains, from 0 to 1",
				"a LOW fit means the weeks were SCATTERED, not that there was no trend · intensity = easy/moderate/hard time %",
				"ftp = the period's FIRST and LAST recorded threshold, with its peak or trough between them when it went outside both",
				"the ftp cell names the sport it belongs to · NN% = that sport's share when it is close to a coin flip",
				"* = still open: no absence has closed this block, or the month is still running · - = not available",
			],
			"\n",
		)
		Str.join_with(["── blocks ──", "", block_body, "", month_hdr, "", month_tbl, "", legend], "\n")
	}

	# start→end, with the peak or trough spliced in when the path went outside
	# its own endpoints. "Ride 234→239" read as a flat block that actually ran
	# 234→271→239; three of six real blocks were misread that way.
	ftp_path : F64, F64, F64, F64 -> Str
	ftp_path = |start, end, lo, hi| {
		top = if (start > end) start else end
		bot = if (start < end) start else end
		if hi > top + 0.5 {
			"${fmt0(start)}→${fmt0(hi)}→${fmt0(end)}"
		} else if lo > 0.0 and lo < bot - 0.5 {
			"${fmt0(start)}→${fmt0(lo)}→${fmt0(end)}"
		} else {
			"${fmt0(start)}→${fmt0(end)}"
		}
	}

	## taper projection: one horizon, its numbers, and which plan produced
	## them — no verdict, same rule as events_screen (ADR 0010/0012)
	project_screen : { target_date : Str, days_away : I64, projected_from : Str, baseline_known : Bool, ftp_known : Bool, plan_source : Str, ctl : F64, atl : F64, tsb : F64, sessions_considered : U64, sessions_projected : U64, unprojected : List({ date : Str, target_literal : Str, reason : Str }), hypothetical : List({ date : Str, target_kind : Str, target_literal : Str, reps : I64, dur_s : I64, watts : F64 }) } -> Str
	project_screen = |p| {
		# a PAST horizon states the current baseline, not a projection — same arm
		# events_screen carries, same wording convention
		head =
			if (p.days_away < 0)
				"${p.target_date} was ${I64.to_str(-p.days_away)}d ago — baseline shown, `stride load` holds the day's reading"
			else
				"projected to ${p.target_date} (in ${I64.to_str(p.days_away)}d) from ${p.projected_from}, over the ${p.plan_source} plan"
		# the projected state in the text `stride events` and the window's event
		# card print for the same date (core Load.projected_on); a past horizon
		# shows the baseline, so it names the baseline's own day
		nums = "  ${Load.projected_on(if (p.days_away < 0) p.projected_from else p.target_date, p.ctl, p.tsb)} (fatigue ${fmt1(p.atl)}) — ${(p.sessions_projected).to_str()} of ${(p.sessions_considered).to_str()} sessions in the window have an estimated load"
		hyp =
			if (List.is_empty(p.hypothetical)) ""
			else Str.join_with(List.map(p.hypothetical, |h| "\n  hypothetical: ${h.date} ${h.target_literal}"), "")
		unpriced =
			Str.join_with(List.map(p.unprojected, |u| "\n  not estimated: ${u.date} ${unprojected_reason(u.target_literal, u.reason)}"), "")
		note =
			if (!(p.baseline_known)) "\nno computed history to project from — the numbers are decay over zero; with activities on record `stride analyze` builds it, and with none `stride setup` syncs your history"
			else ""
		"${head}\n${nums}${hyp}${unpriced}${note}"
	}

	# why a planned session adds no load to a projection, with its target when it has one
	unprojected_reason : Str, Str -> Str
	unprojected_reason = |lit, reason| {
		why =
			if (reason == "no_target") "no target"
			else if (reason == "no_ftp") "no FTP from the last 60 days"
			else if (reason == "no_hr_zones") "no heart-rate zones set"
			else if (reason == "no_threshold_pace") "no threshold pace for its sport from the last 60 days"
			else reason
		if (lit == "") why else "${lit}: ${why}"
	}

	# why an event's unpriced sessions add no load, counted per reason in a fixed
	# order: an event window can span months of untargeted rest days, so a count
	# reads where a list of every session would not
	unprojected_tally : List({ date : Str, target_literal : Str, reason : Str }) -> Str
	unprojected_tally = |ups| {
		parts = List.keep_oks(
			["no_target", "no_ftp", "no_hr_zones", "no_threshold_pace"],
			|r| {
				n = List.count_if(ups, |u| u.reason == r)
				if (n == 0) Err(None) else Ok("${n.to_str()} with ${unprojected_reason("", r)}")
			},
		)
		if (List.is_empty(parts)) "" else "\n      not estimated: ${Str.join_with(parts, ", ")}"
	}

	## event targets: the projection as numbers in plain indented rows, its inputs
	## in the lead line and the degraded-baseline note, and NO verdict line — "are you on
	## track" is the coach's sentence, and ADR 0010 notes the denylist would not even
	## catch it, so nothing here says it. Each projected state names the date it is
	## for (core Load.projected_on, the text the window's event card reads): the event
	## day, and the plan's last day when the written plan stops short of the event,
	## since past that day the event-day numbers are decay alone.
	events_screen : { projected_from : Str, baseline_known : Bool, ftp_known : Bool, events : List({ id : I64, event_date : Str, name : Str, days_away : I64, ctl : F64, atl : F64, tsb : F64, planned_in_window : U64, sessions_projected : U64, unprojected : List({ date : Str, target_literal : Str, reason : Str }), plan_end : { known : Bool, date : Str, ctl : F64, atl : F64, tsb : F64 } }) } -> Str
	events_screen = |p|
		if List.is_empty(p.events) {
			"no event targets on file — `stride event add <YYYY-MM-DD> \"<name>\"` records one"
		} else {
			rows = List.map(
				p.events,
				|e|
					# a PAST event's row states the current baseline, not the event-day
					# reading (daily_load holds that) — say so instead of printing "in -3d"
					if (e.days_away < 0)
						"  #${I64.to_str(e.id)}  ${e.event_date}  ${I64.to_str(-e.days_away)}d ago — baseline shown, `stride load` holds the event-day reading  ${e.name}"
					else {
						plan_end = if (e.plan_end.known) "\n      plan's last day ${Load.projected_on(e.plan_end.date, e.plan_end.ctl, e.plan_end.tsb)} (fatigue ${fmt1(e.plan_end.atl)}); nothing is planned after it" else ""
						"  #${I64.to_str(e.id)}  ${e.event_date}  in ${I64.to_str(e.days_away)}d  ${e.name}\n      event day ${Load.projected_on(e.event_date, e.ctl, e.tsb)} (fatigue ${fmt1(e.atl)}) — ${(e.sessions_projected).to_str()} of ${(e.planned_in_window).to_str()} planned sessions have an estimated load${plan_end}${unprojected_tally(e.unprojected)}"
					},
			)
			base_note =
				if (!(p.baseline_known)) "\nno computed history to project from — every number above is decay over zero; with activities on record `stride analyze` builds it, and with none `stride setup` syncs your history"
				else ""
			body = Str.join_with(
				List.concat(["projected fitness, fatigue and form from ${p.projected_from} over the open plan's targets"], rows),
				"\n",
			)
			"${body}${base_note}"
		}

	# time to exhaustion: the number, and what the model thinks of it
	tte_screen = |p| {
		# suppressed below 3 points, for the reason power_curve_screen gives — there the
		# COUNT is the signal.
		quality = if (p.fit_points >= 3.I64) ", fit quality ${fmt2(p.fit_r2)} of 1" else ""
		head = "at ${fmt0(p.watts)}W against your critical power (CP) ${fmt0(p.cp)}W (${p.sport_family} fit, W' ${fmt1(p.w_prime / 1000.0)} kJ from ${I64.to_str(p.fit_points)} of the 5/10/20-min bests over ${I64.to_str(p.window_days)}d${quality})"
		# The athlete's own record at or above this power, when it is on file.
		# A model that predicts less than what is already recorded is refuted by
		# its own inputs, and the coach should see that on the same screen as
		# the prediction rather than having to go find it.
		record =
			if p.demonstrated_known {
				on = " · on record: ${fmt0(p.demonstrated_w)}W for ${hms((p.demonstrated_s).round_to_i64_try().ok_or(0))} in this window"
				if (p.contradicts_model) "${on} — LONGER than the model predicts, so the fit understates this athlete"
				else on
			} else {
				""
			}
		body =
			if p.status == "below_cp" {
				"  at or below CP the model has no limit — it says indefinitely, which is the model's answer and not your body's${record}"
			} else if p.status == "outside_model" {
				"  ~${hms((p.seconds).round_to_i64_try().ok_or(0))} — OUTSIDE the 2-20min band the model holds in, so read it as a direction rather than a number${record}"
			} else {
				"  ~${hms((p.seconds).round_to_i64_try().ok_or(0))}${record}"
			}
		"${head}\n${body}"
	}

	# the pace twin: the same three statuses and the same on-record line, every
	# pace in the unit the caller wrote theirs in
	tte_pace_screen = |p| {
		pace = |s| "${mmss((s).round_to_i64_try().ok_or(0))}${p.pace_unit}"
		quality = if (p.fit_points >= 3.I64) ", fit quality ${fmt2(p.fit_r2)} of 1" else ""
		head = "at ${pace(p.pace_s)} against your critical speed (CS) ${pace(p.cs_pace_s)} (${p.sport} fit, D′ ${fmt0(p.d_prime)} m from ${I64.to_str(p.fit_points)} of the 5/10/20-min speed bests over ${I64.to_str(p.window_days)}d${quality})"
		record =
			if p.demonstrated_known {
				on = " · on record: ${pace(Metrics.pace_s_per_unit(p.demonstrated_speed, p.pace_unit))} for ${hms((p.demonstrated_s).round_to_i64_try().ok_or(0))} in this window"
				if (p.contradicts_model) "${on} — LONGER than the model predicts, so the fit understates this athlete"
				else on
			} else {
				""
			}
		body =
			if p.status == "below_cs" {
				"  at or slower than CS the model has no limit — it says indefinitely, which is the model's answer and not your body's${record}"
			} else if p.status == "outside_model" {
				"  ~${hms((p.seconds).round_to_i64_try().ok_or(0))} — OUTSIDE the 2-20min band the model holds in, so read it as a direction rather than a number${record}"
			} else {
				"  ~${hms((p.seconds).round_to_i64_try().ok_or(0))}${record}"
			}
		"${head}\n${body}"
	}

	# ── rep-level comparison screen ──────────────────────────────
	# One row per session, newest first, with the per-rep watts spelled out so
	# the shape of a session is visible at a glance rather than summarized away.
	# Numbers only — a fade is reported, never judged.
	reps_screen = |units, p| {
		shown = (List.len(p.sessions)).to_i64_wrap()
		# seg_unit carries a leading space for " m/s" so it can suffix a
		# number directly; the legend needs it bare.
		unit = seg_legend_unit(units, p.signal)
		# Rows are RANKED by uniformity and then capped, so saying only "12 of
		# 21" invites the reading that the other 9 are older, when they are in
		# fact the least regular. On this athlete the dropped rows included
		# five sessions from the current year, under a newest-first table.
		more = if (p.matched_total > shown) " · showing the ${I64.to_str(shown)} most uniform of ${I64.to_str(p.matched_total)}" else ""
		# How much of the evidence is itself the shape named in the header.
		# Because the rows are ranked by uniformity, a conforming session can
		# never rank below a non-conforming one: so when this count is under
		# the number shown, it is exact over the WHOLE matched set, not just
		# the visible rows. When every visible row conforms there may be more
		# below the cap, hence the "≥".
		conforming = (List.len(List.keep_if(p.sessions, |s| Metrics.is_uniform_reps(s.min_dur_s, s.max_dur_s)))).to_i64_wrap()
		atleast = if (conforming == shown and p.matched_total > shown) "≥" else ""
		# the NOUN follows how many were matched, the VERB how many conform:
		# "1 of 8 matched sessions is itself" -- pluralizing both gives
		# "1 of 8 matched session is itself"
		noun = if (p.matched_total == 1.I64) "matched session" else "matched sessions"
		verb = if (conforming == 1.I64) "is itself" else "are themselves"
		# A trailing clause would describe rows that may not exist: on a first
		# structured session "1 of 1 ... the rest are listed" names a
		# rest of zero. It would also imply the un-annotated rows are the
		# conforming ones, but the annotation fires at a spread of 1.15 and the
		# census counts at 1.6, so on real data that mapping gives 1 where the
		# census says 3.
		rest = p.matched_total - conforming
		# When the window caps and every visible row conforms, `conforming` is a
		# LOWER bound (hidden rows rank worse but may still conform), so the
		# remainder is an UPPER bound. Naming it exactly said "at least 12 of 35"
		# and "the other 23 are not like-for-like" in one breath, while two of
		# those 23 were identical in shape to the anchor.
		tail =
			if rest <= 0 {
				""
			} else if atleast != "" and rest == 1.I64 {
				" — up to one other matches its rep count and duration band without being this shape"
			} else if atleast != "" {
				" — up to ${I64.to_str(rest)} others match its rep count and duration band without being this shape"
			} else if rest == 1.I64 {
				" — the other one matches its rep count and duration band without being this shape"
			} else {
				" — the other ${I64.to_str(rest)} match its rep count and duration band without being this shape"
			}
		# A caveat that fires on 11 of 12 rows has stopped being a caveat, so
		# the count of like-for-like evidence leads instead of hiding in a
		# per-row parenthetical.
		census = "${atleast}${I64.to_str(conforming)} of ${I64.to_str(p.matched_total)} ${noun} ${verb} this repeated shape${tail}"
		# "anchor" is load-bearing: the shape describes the anchor session, and
		# each row states its own spread — claiming it for the whole table would
		# contradict the rows beneath it.
		header = "── anchor ${I64.to_str(p.shape_reps)}×${mmss(p.shape_dur)} · ${p.anchor_date}${more} ──"
		rows = List.map(
			p.sessions,
			|s| {
				# seg_value/seg_unit, not fmt0: on a run avg_signal is metres per
				# second, and fmt0 rendered every rep of a 4:00/km and a 4:13/km
				# session as an identical "4".
				vals = Str.join_with(List.map(s.reps, |r| seg_value(units, r.avg_signal, p.signal)), " · ")
				# signed(), not a hardcoded "+": a HR DROP across reps is a real
				# signal, and a fixed "+" would print it as "hr +-8".
				hr = if (s.hr_rise_known) " · hr ${signed(s.hr_rise_bpm)}" else ""
				spread = if (s.uniformity >= 1.15) " · reps ${mmss(s.min_dur_s)}-${mmss(s.max_dur_s)}" else ""
				"${s.date}  ${vals}  (mean ${seg_value(units, s.mean_signal, p.signal)}, fade ${fade_value(units, (List.first(s.reps)).map_ok(|r| r.avg_signal).ok_or(0.0), (List.last(s.reps)).map_ok(|r| r.avg_signal).ok_or(0.0), p.signal)}${hr}${spread})"
			},
		)
		legend = "reps left to right within each session, in ${unit} · fade = change across the session, NEGATIVE means faded (weaker watts, slower pace) · hr = first-to-last change across reps"
		Str.join_with(List.join([[header, "", census, ""], rows, ["", legend]]), "\n")
	}

	# a session a window request or the window's focus names, by its day and
	# its activity id, each part only when it is set: an id below zero and an
	# empty day both mean the row did not name one
	session_ref : Str, Str, I64 -> Str
	session_ref = |label, day, id| {
		id_part = if (id < 0) "" else "id ${id.to_str()}"
		if (day == "" and id_part == "") ""
		else if (day == "") " ${label} ${id_part}"
		else if (id_part == "") " ${label} ${day}"
		else " ${label} ${day} (${id_part})"
	}

	# `stride viz`'s first two lines: what the window published, and what it
	# shows now
	viz_head : { protocol : I64, published : Str, staleness : I64, fstale : I64 } -> Str
	viz_head = |s| "window protocol ${s.protocol.to_str()}, published ${s.published}; a request expires after ${s.staleness.to_str()}s, the focus after ${s.fstale.to_str()}s"

	viz_focus_line : { present : Bool, live : Bool, view : I64, trace_day : Str, trace_id : I64, age_seconds : I64 } -> Str
	viz_focus_line = |f|
		if (!f.present) "focus: none - the window is not open"
		else {
			trace = Str.trim_start(session_ref("trace", f.trace_day, f.trace_id))
			parts = List.keep_if(["view ${f.view.to_str()}", trace, "${f.age_seconds.to_str()}s ago"], |p| p != "")
			"focus: ${if (f.live) "live" else "stale"} - ${Str.join_with(parts, ", ")}"
		}

	# the config keys this database has set, never their values: each key a
	# person sets stands unmarked, every other names who owns it, a secret
	# says so, and the last line names the command that reads a value
	config_screen : List({ key : Str, status : Str, redacted : Bool }) -> Str
	config_screen = |keys|
		if List.is_empty(keys) {
			"no config set — `stride config set <key> <value>`"
		} else {
			lines = List.map(
				keys,
				|e| {
					owner =
						if (e.status == "settable") ""
						else if (e.status == "managed") "set by stride"
						else if (e.status == "derived") "derived from your power history"
						else "unrecognised, stride does not read it"
					marks = List.keep_if([if (e.redacted) "secret" else "", owner], |m| m != "")
					if (List.is_empty(marks)) e.key else "${e.key}  (${Str.join_with(marks, "; ")})"
				},
			)
			Str.join_with(List.append(lines, "values are not listed — `stride config get <key>` reads one"), "\n")
		}

	# what one headless tick did with the request it took
	tick_line : { id : I64, status : Str, view : I64, range : I64, trace_day : Str, trace_id : I64, ghost_day : Str, ghost_id : I64 } -> Str
	tick_line = |t| {
		parts = List.keep_if(
			[
				if (t.view < 0) "" else "view ${t.view.to_str()}",
				if (t.range < 0) "" else "range ${t.range.to_str()}",
				Str.trim_start(session_ref("trace", t.trace_day, t.trace_id)),
				Str.trim_start(session_ref("ghost", t.ghost_day, t.ghost_id)),
			],
			|p| p != "",
		)
		"tick: request ${t.id.to_str()} ${t.status}${if (List.is_empty(parts)) "" else " (${Str.join_with(parts, ", ")})"}"
	}

	# the scoring step a load came from, in the words a person reads; the
	# payload keeps the stored name, and a name this list lacks reads as stored
	load_model_name : Str -> Str
	load_model_name = |m|
		if (m == "power_stream") "power, second by second"
		else if (m == "weighted_watts") "Strava's weighted power"
		else if (m == "avg_watts") "average power"
		else if (m == "rtss") "pace"
		else if (m == "hr_zones") "time in heart-rate zones"
		else if (m == "hr_avg") "average heart rate"
		else if (m == "session_rpe") "your rating (session-RPE)"
		else if (m == "relative_effort") "Strava's relative effort"
		else if (m == "none") "not scored"
		else if (Str.starts_with(m, "unknown")) "unknown"
		else m

	# one session's load, named by the rung that scored it: power, pace and
	# heart rate score in TSS, while a session rating or relative effort does
	# not, so those read as load. A load under 1 means no usable data.
	session_load_text : F64, Str -> Str
	session_load_text = |load, load_model| {
		if load < 1.0 {
			"no usable data"
		} else if List.contains(Metrics.tss_load_models, load_model) {
			"${fmt0(load)} TSS"
		} else {
			"${fmt0(load)} load"
		}
	}

	# ── compare command screen ──────────────────────────────────────────
	# this rolling window vs the prior one, metric by metric, with a signed delta
	# The compare verdict as a PURE producer, extracted so the boundary guard can
	# sweep it — state words only, never advice.
	compare_verdict : F64, F64, F64, Str -> Str
	compare_verdict = |prior_tss, cur_tss, ctl_d, lab| {
		load_word =
			match Metrics.pct_change(prior_tss, cur_tss) {
				Err(NoBaseline) =>
					if cur_tss > 0.0 {
						"load resumed (${fmt0(cur_tss)} load vs none the prior ${lab})"
					} else {
						"no load recorded either ${lab}"
					}
				Ok(pct) =>
					if pct > 10.0 {
						"load ramping (${fmt0(pct)}%)"
					} else if pct < -10.0 {
						"load backed off (${fmt0(pct)}%)"
					} else {
						"load steady (${fmt0(pct)}%)"
					}
			}
		fit_word =
			if (ctl_d > 0.5) "fitness building"
			else if (ctl_d < -0.5) "fitness slipping"
			else "fitness holding"
		"${load_word} · ${fit_word}"
	}

	compare_screen = |p| {
		c = p.current
		pr = p.prior
		lab = p.window_label
		# The delta is computed from the values AS DISPLAYED, not from the raw
		# F64s: each cell rounds independently, so three individually-correct
		# roundings can contradict each other (276.4 and 232.8 print 276, 233
		# and a raw delta of -44 - every reader subtracts the columns, gets
		# 43, and concludes the arithmetic is wrong). A table must agree with
		# itself; signed() on the raw value remains right for a delta with no
		# columns beside it. The agreement rests
		# on rf sharing fmt0's exact body, ok_or(0) fallback included - change
		# how fmt0 rounds and this rounding must move with it, or the deltas
		# quietly stop describing the cells beside them.
		rf = |x| x.round_to_i64_try().ok_or(0)
		df = |cur, prev| signed((rf(cur) - rf(prev)).to_f64())
		di = |cur, prev| signed(cur.to_f64() - prev.to_f64())
		# hard (min) and easy % are measurements only when the window holds
		# zone data at all: an athlete with no HR zones would otherwise read
		# "easy % 0" as zero easy training, when no measurement exists - the
		# season block table renders the same absence as "-", and ADR 0009's
		# rule is that absence is flagged or discriminated, never zeroed.
		zc = |known, v| if (known) v else "-"
		zd = |v| if (c.polarization_known and pr.polarization_known) v else "-"
		table = render_table(
			["metric", "prior ${lab}", "last ${lab}", "Δ"],
			[
				["load", fmt0(pr.tss), fmt0(c.tss), df(c.tss, pr.tss)],
				["sessions", I64.to_str(pr.sessions), I64.to_str(c.sessions), di(c.sessions, pr.sessions)],
				["hard (min)", zc(pr.polarization_known, I64.to_str(pr.hard_min)), zc(c.polarization_known, I64.to_str(c.hard_min)), zd(di(c.hard_min, pr.hard_min))],
				["easy %", zc(pr.polarization_known, I64.to_str(pr.easy_pct)), zc(c.polarization_known, I64.to_str(c.easy_pct)), zd(di(c.easy_pct, pr.easy_pct))],
				["fitness (ctl)", fmt0(pr.ctl), fmt0(c.ctl), df(c.ctl, pr.ctl)],
			],
		)
		# Match on the baseline rather than defaulting it: with no prior load there is no
		# percentage to state, and the two no-baseline cases read differently — training
		# after nothing is "resumed", nothing after nothing is not a change at all.
		# Defaulting to 0.0 here reports the second case as "load steady (0%)", which
		# claims a measurement that was never taken.
		# The verdict reads DISPLAYED values on both halves, the same rule as
		# the table's deltas. The ctl half: a raw 23.6 -> 24.4 rounds both
		# cells to 24 and the row's delta to +0, and "fitness building" one
		# line below that row is the self-contradiction the rounded deltas
		# removed, moved down a row. The load half: a prior in (0, 0.5)
		# displays as 0, and a percentage computed against it bypasses the
		# NoBaseline branch whose whole job is to speak when the table shows
		# none - rounding first sends that case to "vs none", agreeing with
		# the column. compare_verdict itself still takes raw F64s; THIS, its
		# only caller, rounds first, so its ±0.5 thresholds see integer-valued
		# deltas here and mean "any nonzero displayed change" - a second
		# caller passing raw deltas would reopen the contradiction this line
		# closes.
		"${table}\n\n→ ${compare_verdict(rf(pr.tss).to_f64(), rf(c.tss).to_f64(), (rf(c.ctl) - rf(pr.ctl)).to_f64(), lab)}"
	}
}

# ── tests ───────────────────────────────────────────────────────────

expect Render.fmt1(12.34) == "12.3"
expect Render.fmt1(9.96) == "10.0"
expect Render.fmt1(0.0) == "0.0"
expect Render.fmt2(0.979) == "0.98"
expect Render.fmt2(1.0) == "1.00"
expect Render.fmt2(1.5) == "1.50"
expect Render.fmt2(-0.5) == "-0.50" # sign survives when the integer part is 0
expect Render.fmt2(-1.25) == "-1.25"
expect Render.fmt0(71.9) == "72"
expect Render.mins(3725) == "62m"
expect List.map([16470, 16499, 16500, 59, 0], Render.mins) == ["275m", "275m", "275m", "1m", "0m"]
expect Render.pad_right("ab", 4) == "ab  "
expect Render.display_width("██") == 2
expect Render.display_width("abc") == 3
expect Render.display_width("café") == 4 # accented Latin stays width 1 per char
expect Render.display_width("🚴") == 2 # 4-byte emoji is two columns
expect Render.display_width("ab🔥") == 4 # a + b + wide emoji
expect Render.pad_right("██", 4) == "██  "
expect Render.pad_left("7", 3) == "  7"
# ── signed: the sign comes from the value, not from the rounded text ──
expect Render.signed(5.0) == "+5"
expect Render.signed(-3.0) == "-3"
expect Render.signed(0.0) == "+0"
# a magnitude that rounds away is still a direction that did not: a slight unload must
# not print the same as no change at all
expect Render.signed(-0.4) == "-0"
expect Render.signed(0.4) == "+0"
# and the two directions stay symmetric either side of zero
expect Render.signed(-0.4) != Render.signed(0.4)
expect Render.pad_left("1234", 3) == "1234" # never truncates

# ── narration: one shape for every step ──
# the label column is fixed, so the ADR's transcripts line up
expect Render.progress_bar("scoring", 0, 10) == "scoring             [░░░░░░░░░░]  0/10"
expect Render.progress_bar("scoring", 5, 10) == "scoring             [█████░░░░░]  5/10"
expect Render.progress_bar("descriptions", 11, 11) == "descriptions        [██████████] 11/11"
expect Render.progress_bar("streams", 1, 1) == "streams             [██████████] 1/1"
# a zero total has no honest fraction to render, and must not divide
expect Render.progress_bar("syncing", 0, 0) == "syncing…"
# ...spelled exactly as the machine-mode line, so the two modes cannot drift apart
expect Render.progress_bar("syncing", 0, 0) == Render.progress_line("syncing", 0, 0)
# done > total would overfill the bar; clamp rather than emit a wider frame
expect Render.progress_bar("x", 99, 10) == "x                   [██████████] 10/10"
# EVERY frame of one run is the same width — `\r` does not clear the line, so a
# shorter frame would leave the previous frame's tail behind it on screen
expect {
	frames = List.map([0, 7, 42, 358, 723], |d| Render.display_width(Render.progress_bar("scoring", d, 723)))
	List.all(frames, |w| w == List.first(frames).ok_or(0))
}
# machine mode: same information, no carriage return and no padding of the count
expect Render.progress_line("scoring", 5, 10) == "scoring             5/10"
expect !(Str.contains(Render.progress_line("scoring", 5, 10), "\r"))
# ...and it clamps like the bar, so neither mode can print an impossible fraction
expect Render.progress_line("scoring", 730, 723) == "scoring             723/723"
# a label as long as the column keeps a space before its content
expect Render.step_line("a label of twenty ch", "x") == "a label of twenty ch x"
expect Render.display_width(Render.step_label("activity list")) == Render.step_column
# the spinner walks four single-width ASCII frames and comes back round
expect List.map([0, 1, 2, 3, 4], Render.spinner) == ["|", "/", "-", "\\", "|"]
expect Render.spin_frame("activity list", 1) == "activity list       /"
# the list's result, as the routine transcript writes it; updated only when some were
expect Render.step_line("activity list", Render.list_result({ checked: 25, new: 1, updated: 0 })) == "activity list       25 checked, 1 new"
expect Render.list_result({ checked: 25, new: 0, updated: 2 }) == "25 checked, 0 new, 2 updated"
# the wait, as the waiting transcript writes it, padded to one width as it counts down
expect Str.trim_end(Render.wait_frame({ daily: False, tick: 1, at: "10:45", left: 252 })) == "waiting for Strava  / next batch at 10:45, 4:12 left"
expect {
	widths = List.map([900, 600, 599, 61, 9, 0], |left| Render.display_width(Render.wait_frame({ daily: False, tick: 0, at: "10:45", left })))
	List.all(widths, |w| w == Render.wait_frame_width)
}
expect Render.clock_left(0) == "0:00" and Render.clock_left(-5) == "0:00" and Render.clock_left(910) == "15:10"
# the local clock: a zone west of UTC reads midnight UTC as the evening before
expect Render.local_time(1795651200, -360, 1795601640) == "18:00"
# ...and one east of it as the next day, which is then named
expect Render.local_time(1795651200, 60, 1795601640) == "01:00 on 2026-11-26"
expect Render.local_time(1795602610, 0, 1795601640) == "10:30"
expect Render.count_noun(1, "new activity", "new activities") == "1 new activity" and Render.count_noun(2, "fetch", "fetches") == "2 fetches" and Render.count_noun(0, "fetch", "fetches") == "0 fetches"

# ── rule rows: a full-width divider, not cells ──
expect {
	t = Render.render_table(["a", "b"], [["1", "2"], Render.rule, ["3", "4"]])
	lines = Str.split_on(t, "\n")
	# the rule sits between the two data rows and is drawn with border glyphs, so it
	# matches the header rule exactly rather than containing any cell text
	List.get(lines, 4).ok_or("") == List.get(lines, 2).ok_or("")
}
# a rule row carries no data, so it must not widen a column or leave stray text
expect {
	t = Render.render_table(["a"], [["x"], Render.rule])
	!(Str.contains(t, "__RENDER_RULE__")) and !(Str.contains(t, "···"))
}
# the marker cannot collide with data: a one-column table whose cell holds the OLD
# sentinel text renders it as content, because only a cell-less row is a rule
expect {
	t = Render.render_table(["a"], [["__RENDER_RULE__"]])
	Str.contains(t, "__RENDER_RULE__")
}
# ...and a table with no rule row is completely unchanged by the feature
expect Render.render_table(["a", "b"], [["1", "2"]]) == "╭───┬───╮\n│ a │ b │\n├───┼───┤\n│ 1 │ 2 │\n╰───┴───╯"

# unicode bars must not skew column alignment
expect {
	t = Render.render_table(["v", "x"], [["██", "y"]])
	t == "╭────┬───╮\n│ v  │ x │\n├────┼───┤\n│ ██ │ y │\n╰────┴───╯"
}

expect {
	t = Render.render_table(["a", "bb"], [["x", "y"], ["long", "z"]])
	t == "╭──────┬────╮\n│ a    │ bb │\n├──────┼────┤\n│ x    │ y  │\n│ long │ z  │\n╰──────┴────╯"
}

# a long detail is WORD-WRAPPED across continuation lines — full text kept (first
# and last words both present, no ellipsis), and the row spans more physical lines
# than an unwrapped single-row table would (3 borders + header + 1 data = 5)
expect {
	long = "Long EASY ride 90min-2h outdoor Z2 ONLY conversational the whole way no chasing wheels"
	t = Render.render_table(
		["day", "date", "type", "status", "detail", "id"],
		[["Sat", "2026-08-08", "endurance", "open", long, "18"]],
	)
	Str.contains(t, "Long EASY ride") and Str.contains(t, "chasing wheels") and List.len(Str.split_on(t, "\n")) > 5
}
# the whole table stays within the budget (the top border spans full width). Asserted
# against the constant, not a literal: hard-coding 80 made this fail the moment the budget
# moved, for no reason other than the number being written down twice.
expect {
	long = "Long EASY ride 90min-2h outdoor Z2 ONLY conversational the whole way no chasing wheels keep it truly easy today"
	t = Render.render_table(
		["day", "date", "type", "status", "detail", "id"],
		[["Sat", "2026-08-08", "endurance", "open", long, "18"]],
	)
	Render.display_width(List.get(Str.split_on(t, "\n"), 0).ok_or("")) <= Render.max_total
}
# ...and the budget still holds when the widest cell has NO break opportunity. The expect
# above wraps a spaced sentence, so it only ever exercised the word packer; a space-free
# token took the other arm of wrap_cell, which emitted it whole and overran the budget in
# silence (a season block is `2021-12-13..2022-02-10`, one token). Checks EVERY
# line, not just the top border: the border is built from the caps, so it can be legal
# while a data row it is supposed to bound is not.
expect {
	span = "2021-12-13..2022-02-10-and-a-tail-long-enough-that-it-cannot-possibly-fit"
	t = Render.render_table(
		["block", "wk", "sessions", "load/wk", "trend", "fit", "intensity", "ftp"],
		[[span, "71", "128", "315", "falling", "0.10", "54/15/31", "239-271"]],
	)
	List.all(Str.split_on(t, "\n"), |l| Render.display_width(l) <= Render.max_total)
}
# hard_break cuts at the cap and loses nothing
expect Render.hard_break("abcdefghij", 4) == ["abcd", "efgh", "ij"]
# ...and cuts on CHARACTER boundaries, not byte offsets. A 4-byte glyph is display-width
# 2, so a cap of 3 fits one glyph plus one ASCII column and never splits the glyph — the
# failure that would print a broken code point into the middle of a table.
expect Render.hard_break("🚴ab🚴", 3) == ["🚴a", "b🚴"]
# a token that already fits is returned untouched, so wrap_cell's fast path is unaffected
expect Render.hard_break("short", 12) == ["short"]
# the phrase distinguishes an exact streak from a truncated one, and stays silent
# where the number carries no information. The n=1/n=2 pair pins the suppression threshold
# — with only n=0 and n=16 tested, `n <= 1` could drift to `n <= 0` and ship ", 1 days".
expect Render.band_days_phrase(Unknown) == ""
expect Render.band_days_phrase(Known(0)) == ""
expect Render.band_days_phrase(Known(1)) == ""
expect Render.band_days_phrase(Known(2)) == ", 2 days in this band"
expect Render.band_days_phrase(Known(16)) == ", 16 days in this band"
# AtLeast prints a FLOOR. A bare "31" would present the window size as a measurement.
expect Render.band_days_phrase(AtLeast(31)) == ", 31+ days in this band"
expect Render.band_days_phrase(AtLeast(1)) == ""

# a short cell is rendered whole on one line — exact match proves no wrapping
expect {
	t = Render.render_table(["a"], [["short"]])
	t == "╭───────╮\n│ a     │\n├───────┤\n│ short │\n╰───────╯"
}

expect Render.progress_group_label(Metric, "Morning Ride", SimilarDistance(31400.0)) == "Morning Ride (~31.4 km rides)"
# The same distance under the other system — 31400 m is 19.5 mi. Both are asserted
# because a converter tested on one system only proves the identity path.
expect Render.progress_group_label(Imperial, "Morning Ride", SimilarDistance(31400.0)) == "Morning Ride (~19.5 mi rides)"

# EF lens: gap row for >90-day breaks, asked marker, last-vs-best all present.
# The gap half COUNTS markers: the legend ends with `··· = a break over 90 days`,
# so `Str.contains(s, "···")` is true in every rendering and could never fail.
# `all_days` is populated so this exercises the real fold, not the degenerate
# `d - p` path.
expect {
	pr = |date, ef| { name: "X", date, sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: ef * 100.0, avg_hr: 100.0, avg_hr_scored: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream", decoupling_pct: 0.0, decoupling_known: False, id: 0 }
	dayof = |x| Metrics.date_str_to_days(x).ok_or(0)
	s = Render.progress_section(Metric, "X", [pr("2025-01-01", 1.5), pr("2025-08-01", 1.2)], "2025-08-01", Ef, Asc, [dayof("2025-01-01"), dayof("2025-08-01")], 0, "a different distance for this workout")
	marks = List.len(Str.split_on(s, "···")) - 1
	marks == 8 and Str.contains(s, "2025-08-01 ◀") and Str.contains(s, "below your best") and Str.contains(s, "declining")
}

# a single session states its score and stops: comparing a value to itself yields a real
# 0%, and "holding steady" would read as a measured finding rather than an absent one
expect {
	pr = |date, ef| { name: "X", date, sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: ef * 100.0, avg_hr: 100.0, avg_hr_scored: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream", decoupling_pct: 0.0, decoupling_known: False, id: 0 }
	s = Render.progress_section(Metric, "X", [pr("2025-01-01", 1.5)], "2025-01-01", Ef, Asc, [], 0, "a different distance for this workout")
	Str.contains(s, "first session of this workout, nothing to compare against yet") and !(Str.contains(s, "holding steady")) and !(Str.contains(s, "(0%)"))
}

# The gap marker is folded over the UNFILTERED series. Both halves asserted —
# asserting only the suppression passes on a build that never draws a marker.
# The measured shape: a no-HR ride on 2025-12-06 between two scorable ones, so the
# real legs are 62 and 41 days (no break) while the rendered rows sit 103 apart.
# `all_days` is DERIVED with the fold's own function — hardcoded day numbers landed
# on a different epoch and both cases drew a marker.
expect {
	pr = |date, ef| { name: "X", date, sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: ef * 100.0, avg_hr: 100.0, avg_hr_scored: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream", decoupling_pct: 0.0, decoupling_known: False, id: 0 }
	rendered = [pr("2025-10-05", 1.5), pr("2026-01-16", 1.6)]
	# the dropped 2025-12-06 ride is present in all_days and absent from the rows
	dayof = |x| Metrics.date_str_to_days(x).ok_or(0)
	with_dropped = Render.progress_section(Metric, "X", rendered, "2026-01-16", Ef, Asc, [dayof("2025-10-05"), dayof("2025-12-06"), dayof("2026-01-16")], 1, "a different distance for this workout")
	# ...and with nothing dropped, the same two rows ARE 103 days apart and DO get a marker
	without = Render.progress_section(Metric, "X", rendered, "2026-01-16", Ef, Asc, [dayof("2025-10-05"), dayof("2026-01-16")], 0, "a different distance for this workout")
	# COUNTED, not `Str.contains`: the legend line ends with "··· = a break over 90 days",
	# so a plain substring test is true of every rendering and the suppression half of this
	# expect passed for the wrong reason. Counting separates the table's marker row from the
	# legend's one mention.
	marks = |x| List.len(Str.split_on(x, "···")) - 1
	marks(with_dropped) == 1 and marks(without) == 8
}

# ...and the footer says what it withheld rather than presenting a filtered count as a
# total. Named by lens, since WHY a session is unscorable is what the athlete can act on.
expect {
	pr = |date, ef| { name: "X", date, sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: ef * 100.0, avg_hr: 100.0, avg_hr_scored: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream", decoupling_pct: 0.0, decoupling_known: False, id: 0 }
	rows = [pr("2025-10-05", 1.5), pr("2026-01-16", 1.6)]
	dayof = |x| Metrics.date_str_to_days(x).ok_or(0)
	hid = Render.progress_section(Metric, "X", rows, "2026-01-16", Ef, Asc, [dayof("2025-10-05"), dayof("2025-12-06"), dayof("2026-01-16")], 1, "a different distance for this workout")
	none = Render.progress_section(Metric, "X", rows, "2026-01-16", Ef, Asc, [dayof("2025-10-05"), dayof("2026-01-16")], 0, "a different distance for this workout")
	Str.contains(hid, "2 sessions (1 hidden: a different distance for this workout)") and Str.contains(none, "2 sessions —")
}

# A lone row means "first session, nothing to compare against" ONLY when nothing
# was hidden. Both arms asserted, and the hidden arm also asserts the ABSENCE of
# the first-session wording — the defect was that the false sentence printed, so a
# check looking only for the new text passes on a build that prints both. Pinned
# HERE because an expect can hold both arms against ONE input; the e2e reaches each
# arm from different data.
expect {
	pr = |date, ef| { name: "X", date, sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: ef * 100.0, avg_hr: 100.0, avg_hr_scored: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream", decoupling_pct: 0.0, decoupling_known: False, id: 0 }
	lone = [pr("2025-01-01", 1.5)]
	genuine = Render.progress_section(Metric, "X", lone, "2025-01-01", Ef, Asc, [], 0, "a different distance for this workout")
	withheld = Render.progress_section(Metric, "X", lone, "2025-01-01", Ef, Asc, [], 10, "a different distance for this workout")
	Str.contains(genuine, "first session of this workout")
		and !(Str.contains(genuine, "the only session this lens can score"))
		and Str.contains(withheld, "the only session shown (10 hidden: a different distance for this workout)")
		and !(Str.contains(withheld, "first session of this workout"))
}

# the best row's value + full 12-block bar stay on ONE line: terse headers keep the
# progress table under render_table's column budget, so the bar column is never the
# widest-column victim of squeeze-and-word-wrap (a split bar reads as broken output)
expect {
	pr = |date, ef| { name: "X", date, sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: ef * 100.0, avg_hr: 100.0, avg_hr_scored: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream", decoupling_pct: 0.0, decoupling_known: False, id: 0 }
	s = Render.progress_section(Metric, "X", [pr("2025-01-01", 1.2), pr("2025-02-01", 1.66)], "2025-02-01", Ef, Asc, [], 0, "a different distance for this workout")
	Str.contains(s, "1.66 ████████████")
}

# Desc flips only the DISPLAY order — the newest row prints first (everything before
# the 2025-01-01 row already contains 2025-02-01), while the trend verdict is still
# computed chronologically (1.2 → 1.66 reads as improving, not declining)
expect {
	pr = |date, ef| { name: "X", date, sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: ef * 100.0, avg_hr: 100.0, avg_hr_scored: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream", decoupling_pct: 0.0, decoupling_known: False, id: 0 }
	s = Render.progress_section(Metric, "X", [pr("2025-01-01", 1.2), pr("2025-02-01", 1.66)], "2025-02-01", Ef, Desc, [], 0, "a different distance for this workout")
	before_old = List.first(Str.split_on(s, "2025-01-01")).ok_or("")
	Str.contains(before_old, "2025-02-01") and Str.contains(s, "improving")
}

# ADR 0012's hard guard applied to the progress verdict: a closed set of three,
# pinned by full-string EQUALITY. A named function rather than an inline `if` so
# the pin can BE equality — Str.contains accepts every superstring ("holding
# steadyZ" contains "holding steady"), so a substring check cannot pin a closed set.
expect Render.trend_label(True, False) == "improving"
expect Render.trend_label(False, True) == "declining"
expect Render.trend_label(False, False) == "holding steady"
expect List.all(
	[Render.trend_label(True, False), Render.trend_label(False, True), Render.trend_label(False, False)],
	|v| !(Metrics.has_coaching_language(v)),
)

# RPE lens is lower-is-better: RPE dropping 8 -> 6 reads as improving, "above your easiest"
expect {
	pr = |date, rpe| { name: "Lift", date, sport: "WeightTraining", distance_m: 0.0, moving_time: 2700, np_w: 0.0, avg_hr: 0.0, avg_hr_scored: 0.0, rpe, output_kj: 0.0, tss: 0.0, load_model: "session_rpe", decoupling_pct: 0.0, decoupling_known: False, id: 0 }
	s = Render.progress_section(Metric, "Lift", [pr("2025-01-01", 8.0), pr("2025-02-01", 6.0), pr("2025-03-01", 7.0)], "2025-03-01", Rpe, Asc, [], 0, "a different distance for this workout")
	Str.contains(s, "│ rpe") and Str.contains(s, "improving") and Str.contains(s, "above your easiest")
}

# short window: daily table, rest rows, verdict; long window: weekly rollup
expect {
	d = |day, tss| { day, tss, ctl: 10.0, atl: 5.0, tsb: 5.0 }
	s = Render.load_screen([d("2025-01-01", 50.0), d("2025-01-02", 0.0)])
	# Both rows sit at tsb 5.0 (Fresh) on consecutive days, and the 2-row series is fully
	# consumed by the streak — so this is the AtLeast path, and it must render the floor
	# marker rather than a bare 2. Without asserting the clause at all, `band = ""` in
	# load_screen passes every test in this file.
	Str.contains(s, "load") and Str.contains(s, "rest") and Str.contains(s, "→ today: form 5")
		and Str.contains(s, ", 2+ days in this band")
}

expect {
	d = |day, tss| { day, tss, ctl: 10.0, atl: 5.0, tsb: 5.0 }
	many = Iter.fold((0.I64..<21).iter(), [], |acc, i| List.append(acc, d(Metrics.days_to_date_str(20000 + i), 30.0)))
	Str.contains(Render.load_screen(many), "week of")
}

# power-curve: durations labelled, watts tabled, CP line present when cp fit; empty is graceful
expect {
	s = Render.power_curve_screen({
		window_days: 90,
		sport: "Ride",
		points: [{ dur_s: 5, watts: 800.0 }, { dur_s: 60, watts: 400.0 }, { dur_s: 1200, watts: 260.0 }],
		cp: 250.0,
		w_prime: 20000.0,
		fit_r2: 0.72,
		fit_points: 3.I64,
		estimated_sessions: 0.I64,
	})
	# a degenerate fit and a perfect one rendered identically here, on the
	# command that PUBLISHES the fit -- so the quality travels with it
	thin = Render.power_curve_screen({
		window_days: 90,
		sport: "Ride",
		points: [{ dur_s: 5, watts: 800.0 }],
		cp: 250.0,
		w_prime: 20000.0,
		fit_r2: 1.0,
		fit_points: 2.I64,
		estimated_sessions: 0.I64,
	})
	Str.contains(s, "5s") and Str.contains(s, "20m") and Str.contains(s, "Critical Power 250") and Str.contains(s, "Ride")
		and Str.contains(s, "fit quality 0.72 of 1")
		# ...and is suppressed at two points, where it would be false reassurance —
		# power_curve_screen states why.
		and !(Str.contains(thin, "fit quality 1.00")) and Str.contains(thin, "a fit quality needs 3")
}
expect {
	s = Render.power_curve_screen({ window_days: 30, sport: "", points: [], cp: 0.0, w_prime: 0.0, fit_r2: 0.0, fit_points: 0.I64, estimated_sessions: 0 })
	est = Render.power_curve_screen({ window_days: 30, sport: "Ride", points: [], cp: 0.0, w_prime: 0.0, fit_r2: 0.0, fit_points: 0.I64, estimated_sessions: 1 })
	Str.contains(s, "no power data") and Str.contains(s, "all power sports")
		# a window holding only estimated watts says so, in the words doctor and
		# the window use for the same session
		and Str.contains(est, "estimated power only (no power meter) in this window") and !(Str.contains(est, "no power data"))
}

# the pace twin. CS renders as a PACE and D' as a DISTANCE, and both follow the
# reader's units while the underlying payload stays SI — the same session, two readings.
expect {
	pts = [{ dur_s: 300, speed: 4.6667 }, { dur_s: 600, speed: 4.3 }, { dur_s: 1200, speed: 4.1667 }]
	m = Render.pace_curve_screen(Metric, { available_sports: ["Run"], window_days: 90, sport: "Run", points: pts, cs: 4.0, d_prime: 200.0, fit_r2: 0.91, fit_points: 3.I64 })
	i = Render.pace_curve_screen(Imperial, { available_sports: ["Run"], window_days: 90, sport: "Run", points: pts, cs: 4.0, d_prime: 200.0, fit_r2: 0.91, fit_points: 3.I64 })
	# 1000/4.0 = 250 s -> 4:10/km; 1609.344/4.0 = 402.3 s -> 6:42/mi; 200 m -> 219 yd
	Str.contains(m, "Critical Speed 4:10 min/km") and Str.contains(m, "D′ 200 m")
		and Str.contains(i, "Critical Speed 6:42 min/mi") and Str.contains(i, "D′ 219 yd")
		and Str.contains(m, "fit quality 0.91 of 1") and Str.contains(m, "Run")
}
# a fit refused (cs 0) must not print as a real fit, and two points is not a quality signal
expect {
	none = Render.pace_curve_screen(Metric, { available_sports: ["Run"], window_days: 90, sport: "Run", points: [{ dur_s: 1200, speed: 4.1667 }], cs: 0.0, d_prime: 0.0, fit_r2: 0.0, fit_points: 1.I64 })
	thin = Render.pace_curve_screen(Metric, { available_sports: ["Run"], window_days: 90, sport: "Run", points: [{ dur_s: 300, speed: 4.6667 }, { dur_s: 1200, speed: 4.1667 }], cs: 4.0, d_prime: 200.0, fit_r2: 1.0, fit_points: 2.I64 })
	empty = Render.pace_curve_screen(Metric, { available_sports: ["Run"], window_days: 30, sport: "Run", points: [], cs: 0.0, d_prime: 0.0, fit_r2: 0.0, fit_points: 0.I64 })
	# no sport named: refuse a pooled fit and name what the athlete CAN ask for, rather than
	# fitting one curve through rides and runs together and labelling it "all pace sports"
	nosport = Render.pace_curve_screen(Metric, { available_sports: ["Run", "Rowing"], window_days: 30, sport: "", points: [], cs: 0.0, d_prime: 0.0, fit_r2: 0.0, fit_points: 0.I64 })
	bare = Render.pace_curve_screen(Metric, { available_sports: [], window_days: 30, sport: "", points: [], cs: 0.0, d_prime: 0.0, fit_r2: 0.0, fit_points: 0.I64 })
	Str.contains(none, "needs bests at two different durations") and !(Str.contains(none, "Critical Speed 0"))
		# three rungs DESCENDING but too steeply for the model — the fitted ceiling lands below
		# zero, so the fit is refused for a reason that is neither a data gap nor a flat curve.
		# 10.0/3.0/2.0 m/s renders 1:40, 5:33, 8:20 per km: visibly descending, and the old
		# single message told the reader they were not.
		and Str.contains(
			Render.pace_curve_screen(Metric, { available_sports: ["Run"], window_days: 90, sport: "Run", points: [{ dur_s: 300, speed: 10.0 }, { dur_s: 600, speed: 3.0 }, { dur_s: 1200, speed: 2.0 }], cs: 0.0, d_prime: 0.0, fit_r2: 0.0, fit_points: 3.I64 }),
			"fall too steeply",
		)
		and !(Str.contains(thin, "fit quality 1.00")) and Str.contains(thin, "a fit quality needs 3")
		and Str.contains(empty, "no pace data")
		and Str.contains(nosport, "per-sport") and Str.contains(nosport, "Run, Rowing") and !(Str.contains(nosport, "Critical Speed"))
		and Str.contains(bare, "none in this window")
		# three rungs at the SAME speed: enough data, but a flat curve the model must decline.
		# The data-gap message would be false here — the table above it shows three durations.
		and Str.contains(
			Render.pace_curve_screen(Metric, { available_sports: ["Run"], window_days: 90, sport: "Run", points: [{ dur_s: 300, speed: 4.0 }, { dur_s: 600, speed: 4.0 }, { dur_s: 1200, speed: 4.0 }], cs: 0.0, d_prime: 0.0, fit_r2: 0.0, fit_points: 3.I64 }),
			"hold or rise with duration",
		)
}

# zone-gap warning fires on 0 Z5; empty last-hard reads as none on record
expect {
	s = {
		as_of: "2025-01-01",
		fitness_ctl: 20.0,
		fatigue_atl: 10.0,
		form_tsb: 10.0,
		form_delta_7d: 5.0,
		form_delta_known: True,
		form_band_days: 16,
		form_band_days_capped: False,
		ramp_7d: 4.0,
		ramp_28d_avg: -1.0,
		load_days: 400,
		ctl_warming_up: False,
		last_28d: { polarization_known: Bool.True, tss: 100.0, z1_s: 600.I64, z2_s: 0.I64, z3_s: 0.I64, z4_s: 0.I64, z5_s: 0.I64, easy_pct: 100.I64, moderate_pct: 0.I64, hard_pct: 0.I64, measured_pct: 100.I64, sessions: 4.I64, moving_time: 7200.I64, distance_m: 30000.0, hr_streams: 4.I64, intensity_streams: 4.I64, load_coverage: { high_pct: 100.I64, medium_pct: 0.I64, low_pct: 0.I64, known: True } },
		last_7d: { polarization_known: Bool.True, tss: 50.0, easy_pct: 100.I64, moderate_pct: 0.I64, hard_pct: 0.I64, sessions: 2.I64, moving_time: 3600.I64, distance_m: 15000.0, hr_streams: 2.I64, intensity_streams: 2.I64 },
		ftp: { best_20min_w_60d: 0.0, estimated_ftp_w: 0.0, derived_ftp_w: 0.0, source: "derived", test_kind: "none", test_date: "none" },
		last_hard_session_date: "",
		hard_days: { d14: 1.I64, d28: 2.I64, spacing_median_days_28d: 3.I64, spacing_known: True, days_since_last: 0.I64, days_since_known: True },
		pending_sessions: 2.I64,
		sports_28d: [{ sport: "Run", sessions: 4.I64, tss: 100.0, moving_time: 7200.I64, distance_m: 30000.0 }],
	}
	out = Render.summary_screen(Metric, s)
	Str.contains(out, "stride report") and Str.contains(out, "zone gap") and Str.contains(out, "none on record")
		# a build and an unload each keep their sign in the same line
		and Str.contains(out, "fitness ramp: +4.0 in the last 7 days")
		and Str.contains(out, "-1.0 a week averaged in the last 28 days")
		# the verdict carries the trend, not just the band
		and Str.contains(out, "form 10, up 5 from a week ago")
		# the label NAMES the state and no longer prescribes, and the streak says
		# how long it has held — the thing a band label cannot express
		and Str.contains(out, "fresh, 16 days in this band")
		and !(Str.contains(out, "good day for a big effort"))
}

# too little history says nothing about the trend rather than claiming form is level.
# Asserts the ABSENCE of the clause AND the presence of the rest of the line, so it cannot
# pass by the whole verdict having gone missing.
expect {
	s = {
		as_of: "2025-01-01",
		fitness_ctl: 20.0,
		fatigue_atl: 10.0,
		form_tsb: 10.0,
		form_delta_7d: 0.0,
		form_delta_known: False,
		form_band_days: 0,
		form_band_days_capped: False,
		ramp_7d: 4.0,
		ramp_28d_avg: -1.0,
		load_days: 400,
		ctl_warming_up: False,
		last_28d: { polarization_known: Bool.True, tss: 100.0, z1_s: 600.I64, z2_s: 0.I64, z3_s: 0.I64, z4_s: 0.I64, z5_s: 0.I64, easy_pct: 100.I64, moderate_pct: 0.I64, hard_pct: 0.I64, measured_pct: 100.I64, sessions: 4.I64, moving_time: 7200.I64, distance_m: 30000.0, hr_streams: 4.I64, intensity_streams: 4.I64, load_coverage: { high_pct: 100.I64, medium_pct: 0.I64, low_pct: 0.I64, known: True } },
		last_7d: { polarization_known: Bool.True, tss: 50.0, easy_pct: 100.I64, moderate_pct: 0.I64, hard_pct: 0.I64, sessions: 2.I64, moving_time: 3600.I64, distance_m: 15000.0, hr_streams: 2.I64, intensity_streams: 2.I64 },
		ftp: { best_20min_w_60d: 0.0, estimated_ftp_w: 0.0, derived_ftp_w: 0.0, source: "derived", test_kind: "none", test_date: "none" },
		last_hard_session_date: "",
		hard_days: { d14: 1.I64, d28: 2.I64, spacing_median_days_28d: 3.I64, spacing_known: True, days_since_last: 0.I64, days_since_known: True },
		pending_sessions: 2.I64,
		sports_28d: [{ sport: "Run", sessions: 4.I64, tss: 100.0, moving_time: 7200.I64, distance_m: 30000.0 }],
	}
	out = Render.summary_screen(Metric, s)
	Str.contains(out, "form 10 —") and !(Str.contains(out, "week ago"))
}

# Missing detailed data is unavailable, never a false zero or a bogus Z5 warning.
expect {
	s = {
		as_of: "2025-01-01",
		fitness_ctl: 20.0,
		fatigue_atl: 10.0,
		form_tsb: 10.0,
		form_delta_7d: 0.0,
		form_delta_known: False,
		form_band_days: 0,
		form_band_days_capped: False,
		ramp_7d: 0.0,
		ramp_28d_avg: 0.0,
		load_days: 400,
		ctl_warming_up: False,
		last_28d: { polarization_known: Bool.False, tss: 100.0, z1_s: 0.I64, z2_s: 0.I64, z3_s: 0.I64, z4_s: 0.I64, z5_s: 0.I64, easy_pct: 0.I64, moderate_pct: 0.I64, hard_pct: 0.I64, measured_pct: 0.I64, sessions: 4.I64, moving_time: 7200.I64, distance_m: 30000.0, hr_streams: 0.I64, intensity_streams: 0.I64, load_coverage: { high_pct: 0.I64, medium_pct: 0.I64, low_pct: 0.I64, known: False } },
		last_7d: { polarization_known: Bool.False, tss: 50.0, easy_pct: 0.I64, moderate_pct: 0.I64, hard_pct: 0.I64, sessions: 2.I64, moving_time: 3600.I64, distance_m: 15000.0, hr_streams: 0.I64, intensity_streams: 0.I64 },
		ftp: { best_20min_w_60d: 0.0, estimated_ftp_w: 0.0, derived_ftp_w: 0.0, source: "derived", test_kind: "none", test_date: "none" },
		last_hard_session_date: "",
		hard_days: { d14: 0.I64, d28: 0.I64, spacing_median_days_28d: 0.I64, spacing_known: False, days_since_last: 0.I64, days_since_known: False },
		pending_sessions: 0.I64,
		sports_28d: [{ sport: "Run", sessions: 4.I64, tss: 100.0, moving_time: 7200.I64, distance_m: 30000.0 }],
	}
	out = Render.summary_screen(Metric, s)
	Str.contains(out, "time in HR zones: unavailable") and Str.contains(out, "intensity unavailable") and !(Str.contains(out, "zone gap"))
}

# a window of lifting alone has intensity streams but no polarized time: its
# shares are absent, never printed as 0%
expect {
	s = {
		as_of: "2025-01-01",
		fitness_ctl: 20.0,
		fatigue_atl: 10.0,
		form_tsb: 10.0,
		form_delta_7d: 0.0,
		form_delta_known: False,
		form_band_days: 0,
		form_band_days_capped: False,
		ramp_7d: 0.0,
		ramp_28d_avg: 0.0,
		load_days: 400,
		ctl_warming_up: False,
		last_28d: { polarization_known: Bool.False, tss: 100.0, z1_s: 0.I64, z2_s: 0.I64, z3_s: 0.I64, z4_s: 0.I64, z5_s: 0.I64, easy_pct: 0.I64, moderate_pct: 0.I64, hard_pct: 0.I64, measured_pct: 0.I64, sessions: 4.I64, moving_time: 7200.I64, distance_m: 30000.0, hr_streams: 0.I64, intensity_streams: 2.I64, load_coverage: { high_pct: 0.I64, medium_pct: 0.I64, low_pct: 0.I64, known: False } },
		last_7d: { polarization_known: Bool.False, tss: 50.0, easy_pct: 0.I64, moderate_pct: 0.I64, hard_pct: 0.I64, sessions: 2.I64, moving_time: 3600.I64, distance_m: 15000.0, hr_streams: 0.I64, intensity_streams: 2.I64 },
		ftp: { best_20min_w_60d: 0.0, estimated_ftp_w: 0.0, derived_ftp_w: 0.0, source: "derived", test_kind: "none", test_date: "none" },
		last_hard_session_date: "",
		hard_days: { d14: 0.I64, d28: 0.I64, spacing_median_days_28d: 0.I64, spacing_known: False, days_since_last: 0.I64, days_since_known: False },
		pending_sessions: 0.I64,
		sports_28d: [{ sport: "Run", sessions: 4.I64, tss: 100.0, moving_time: 7200.I64, distance_m: 30000.0 }],
	}
	out = Render.summary_screen(Metric, s)
	Str.contains(out, "polarization: unavailable (no endurance time; lifting is left out)") and Str.contains(out, "intensity unavailable") and !(Str.contains(out, "0% easy"))
}

# pace: 10km in 3000s = 5:00/km; padded seconds; no distance -> "-"
expect Render.pace_per_dist(Metric, 10000.0, 3000) == "5:00" and Render.pace_per_dist(Metric, 10000.0, 3070) == "5:07" and Render.pace_per_dist(Metric, 0.0, 100) == "-"
# 10 km in 50:00 is 5:00/km and 8:03/mi. The imperial arm is asserted separately because
# the metric one divides by 1000.0 and would pass against a converter that ignored its
# units argument entirely.
expect Render.pace_per_dist(Imperial, 10000.0, 3000) == "8:03" and Render.pace_per_dist(Imperial, 0.0, 100) == "-"
# The conversion itself, both directions, so a wrong constant fails here rather than
# only inside a formatted sentence.
expect Render.dist_unit(Metric) == "km" and Render.dist_unit(Imperial) == "mi"
expect Render.pace_unit(Metric) == "min/km" and Render.pace_unit(Imperial) == "min/mi"
expect Render.dist_value(Metric, 1609.344) == 1.609344
expect Render.dist_value(Imperial, 1609.344) == 1.0
expect (Render.elev_value(Imperial, 30.48) - 100.0).abs() < 0.001
expect (Render.elev_value(Metric, 30.48) - 30.48).abs() < 0.001
expect Render.elev_unit(Imperial) == "ft" and Render.elev_unit(Metric) == "m"

# compare table + verdict render; ramp shows in the load word
expect {
	w = |tss, sessions, hard, easy, ctl| { tss, sessions, hard_min: hard, easy_pct: easy, ctl, polarization_known: Bool.True }
	s = Render.compare_screen({ period: "week", window_label: "7d", current: w(227.0, 6.I64, 18.I64, 17.I64, 26.0), prior: w(193.0, 5.I64, 12.I64, 37.I64, 24.0) })
	Str.contains(s, "load") and Str.contains(s, "+34") and Str.contains(s, "ramping") and Str.contains(s, "building")
}

# a session scored in TSS says TSS; a rated or relative-effort session says
# load; nothing scored says so
expect Render.session_load_text(110.4, "power_stream") == "110 TSS"
expect Render.session_load_text(98.0, "weighted_watts") == "98 TSS"
expect Render.session_load_text(80.0, "avg_watts") == "80 TSS"
expect Render.session_load_text(72.0, "rtss") == "72 TSS"
expect Render.session_load_text(55.0, "hr_zones") == "55 TSS"
expect Render.session_load_text(48.0, "hr_avg") == "48 TSS"
expect Render.session_load_text(52.5, "session_rpe") == "53 load"
expect Render.session_load_text(30.0, "relative_effort") == "30 load"
expect Render.session_load_text(0.0, "none") == "no usable data"

# zero prior load must NOT read as "steady 0%" — it's a resumption. The
# window total blends TSS with session-RPE load, so the screen names it load.
expect {
	w = |tss, sessions, hard, easy, ctl| { tss, sessions, hard_min: hard, easy_pct: easy, ctl, polarization_known: Bool.True }
	s = Render.compare_screen({ period: "week", window_label: "7d", current: w(200.0, 4.I64, 10.I64, 40.I64, 20.0), prior: w(0.0, 0.I64, 0.I64, 0.I64, 18.0) })
	Str.contains(s, "load resumed (200 load vs none the prior 7d)") and !(Str.contains(s, "steady")) and !(Str.contains(s, "TSS"))
}

# the delta agrees with the columns it sits beside: 276.4 and 232.8 display as
# 276 and 233, and the delta is computed from THOSE, so it reads -43 — the raw
# delta -43.6 rounds to -44, which contradicts the subtraction every reader
# performs on the printed cells
expect {
	w = |tss, sessions, hard, easy, ctl| { tss, sessions, hard_min: hard, easy_pct: easy, ctl, polarization_known: Bool.True }
	s = Render.compare_screen({ period: "week", window_label: "7d", current: w(232.8, 5.I64, 10.I64, 40.I64, 24.0), prior: w(276.4, 6.I64, 12.I64, 38.I64, 24.0) })
	Str.contains(s, "276") and Str.contains(s, "233") and Str.contains(s, "-43") and !(Str.contains(s, "-44"))
}

# a window with no zone data renders hard (min) and easy % as "-", never as a
# number that claims a measurement — and only the zoneless SIDE goes dark: a
# real week beside a zoneless week keeps its own numbers, while the delta,
# which needs both sides, goes dark with the darker one. The sentinels 88 and
# 99 exist nowhere else in the fixture, so their absence is the gating and
# nothing else — and the DELTA cells must go dark too, because +76 and +62
# beside a suppressed cell hand the reader the suppressed values back by
# subtraction (12 + 76 and 37 + 62 recover exactly what the "-" hid).
expect {
	w = |tss, sessions, hard, easy, ctl, zk| { tss, sessions, hard_min: hard, easy_pct: easy, ctl, polarization_known: zk }
	s = Render.compare_screen({ period: "week", window_label: "7d", current: w(200.0, 4.I64, 88.I64, 99.I64, 20.0, Bool.False), prior: w(193.0, 5.I64, 12.I64, 37.I64, 24.0, Bool.True) })
	Str.contains(s, "-") and Str.contains(s, "37") and Str.contains(s, "12") and !(Str.contains(s, "88")) and !(Str.contains(s, "99")) and !(Str.contains(s, "+76")) and !(Str.contains(s, "+62"))
}

# the verdict agrees with the row above it: 23.6 -> 24.4 prints both ctl cells
# as 24 and the delta as +0, so the verdict must say holding — the raw delta
# 0.8 crosses the ±0.5 threshold and would say building under a +0
expect {
	w = |tss, sessions, hard, easy, ctl| { tss, sessions, hard_min: hard, easy_pct: easy, ctl, polarization_known: Bool.True }
	s = Render.compare_screen({ period: "week", window_label: "7d", current: w(200.0, 5.I64, 10.I64, 40.I64, 24.4), prior: w(195.0, 5.I64, 10.I64, 40.I64, 23.6) })
	Str.contains(s, "+0") and Str.contains(s, "fitness holding") and !(Str.contains(s, "building"))
}

# ...and the LOAD half follows the same rule: a prior of 0.4 TSS displays as
# 0, so the verdict must say "vs none" — a percentage against a baseline the
# table prints as none (250% here) would contradict the column it sits under
expect {
	w = |tss, sessions, hard, easy, ctl| { tss, sessions, hard_min: hard, easy_pct: easy, ctl, polarization_known: Bool.True }
	s = Render.compare_screen({ period: "week", window_label: "7d", current: w(1.4, 1.I64, 0.I64, 50.I64, 5.0), prior: w(0.4, 1.I64, 0.I64, 50.I64, 5.0) })
	Str.contains(s, "vs none") and !(Str.contains(s, "250"))
}

# ── interval structure rendering ────────────────────────────────────

# summary uses medians and drops the recovery half when there are no recoveries
expect {
	seg = |o, k, d, v| { ordinal: o, kind: k, start_s: 0.I64, dur_s: d, avg_signal: v, signal: "power", peak_hr: 0.0, avg_hr: 0.0, rec_drop: 0.0, rec_drop_known: False }
	full = Render.interval_summary(Metric, [seg(0.I64, "warmup", 300.I64, 120.0), seg(1.I64, "work", 181.I64, 251.0), seg(2.I64, "recovery", 120.I64, 100.0), seg(3.I64, "work", 179.I64, 249.0), seg(4.I64, "cooldown", 300.I64, 110.0)])
	lone = Render.interval_summary(Metric, [seg(0.I64, "work", 1200.I64, 258.0)])
	none = Render.interval_summary(Metric, [seg(0.I64, "recovery", 600.I64, 100.0)])
	# a recovery-shaped block BEFORE the first work must not become the "easy" half
	pre = Render.interval_summary(Metric, [seg(0.I64, "recovery", 300.I64, 100.0), seg(1.I64, "work", 1200.I64, 258.0)])
	full == "2×[3:01 @ 251W / 2:00 easy]" and lone == "1×[20:00 @ 258W]" and none == "" and pre == "1×[20:00 @ 258W]"
}

# The same shape for a PACE-routed session. This is the documented format in SKILL.md,
# so it is asserted rather than described.
expect {
	pseg = |o, k, d, v| { ordinal: o, kind: k, start_s: 0.I64, dur_s: d, avg_signal: v, signal: "pace", peak_hr: 0.0, avg_hr: 0.0, rec_drop: 0.0, rec_drop_known: False }
	reps = [pseg(0.I64, "work", 240.I64, 4.1667), pseg(1.I64, "recovery", 120.I64, 2.0), pseg(2.I64, "work", 240.I64, 4.1667)]
	Render.interval_summary(Metric, reps) == "2×[4:00 @ 4:00/km / 2:00 easy]"
		# and the unit follows the reader, while the VALUE is the same session
		and Render.interval_summary(Imperial, reps) == "2×[4:00 @ 6:26/mi / 2:00 easy]"
		# and the NO-RECOVERY form, which is what the e2e fixture (activity 9003) actually
		# emits — two work reps and no recovery row. Without this the shipped string is the
		# one string nothing pins: the arms above cover only the with-recovery shape, and the
		# e2e regex accepts either, so the exact form the payload really carries went unasserted.
		and Render.interval_summary(Metric, [pseg(0.I64, "work", 240.I64, 4.1667), pseg(1.I64, "work", 240.I64, 4.13)]) == "2×[4:00 @ 4:00/km]"
}

# rep lines carry HR only when measured; drift needs two measured reps
expect {
	seg = |hr, drop_known| { ordinal: 0.I64, kind: "work", start_s: 0.I64, dur_s: 180.I64, avg_signal: 250.0, signal: "power", peak_hr: hr + 8.0, avg_hr: hr, rec_drop: 20.0, rec_drop_known: drop_known }
	with_hr = Render.segments_block(Metric, [seg(150.0, True)])
	no_hr = Render.segments_block(Metric, [seg(0.0, False)])
	drift = Render.seg_hr_drift([seg(150.0, True), seg(158.0, True)])
	Str.contains(with_hr, "hr 150 avg / 158 peak") and Str.contains(with_hr, "60s drop +20")
		and !(Str.contains(no_hr, "hr"))
		and drift == Ok(8.0)
		# one measured rep is NOT a drift — Ok(0.0) here would print a fabricated
		# flat-drift verdict on every single-rep session
		and Render.seg_hr_drift([seg(150.0, True)]) == Err(NotEnough)
}

# reps_screen: units, sign, caption and census, each pinned against a shape real
# data produces.
expect {
	rep = |v| { avg_signal: v, ordinal: 0.I64, dur_s: 240.I64 }
	sess = |date, unif, hr_rise, mean, fade, vals| {
		date,
		uniformity: unif,
		min_dur_s: 240.I64,
		max_dur_s: 241.I64,
		mean_signal: mean,
		fade_signal: fade,
		hr_rise_bpm: hr_rise,
		hr_rise_known: True,
		reps: List.map(vals, rep),
	}
	power = Render.reps_screen(
		Metric,
		{
			anchor_date: "2026-08-16",
			shape_reps: 3.I64,
			shape_dur: 718.I64,
			matched_total: 21.I64,
			signal: "power",
			sessions: [sess("2026-08-16", 1.01, 11.0, 262.0, -16.0, [268.0, 265.0, 252.0])],
		},
	)
	pace = Render.reps_screen(
		Metric,
		{
			anchor_date: "2026-08-10",
			shape_reps: 5.I64,
			shape_dur: 241.I64,
			matched_total: 2.I64,
			signal: "pace",
			sessions: [
				sess("2026-08-10", 1.01, 12.0, 4.15, -0.04, [4.1667, 4.13]),
				sess("2026-05-10", 1.01, 12.0, 3.94, -0.03, [3.9526, 3.92]),
			],
		},
	)
	# some shown rows do NOT conform, so the count is exact and the remainder
	# is named rather than hedged
	mixed = Render.reps_screen(
		Metric,
		{
			anchor_date: "2026-08-16",
			shape_reps: 3.I64,
			shape_dur: 718.I64,
			matched_total: 3.I64,
			signal: "power",
			sessions: [
				sess("2026-08-16", 1.01, 11.0, 262.0, -16.0, [268.0, 252.0]),
				{ date: "2025-10-15", uniformity: 4.3, min_dur_s: 264.I64, max_dur_s: 1144.I64, mean_signal: 236.0, fade_signal: -5.0, hr_rise_bpm: 13.0, hr_rise_known: True, reps: List.map([231.0, 227.0], rep) },
			],
		},
	)
	dropped = Render.reps_screen(
		Metric,
		{
			anchor_date: "2023-02-11",
			shape_reps: 7.I64,
			shape_dur: 63.I64,
			matched_total: 16.I64,
			signal: "power",
			sessions: [sess("2023-02-11", 1.02, -8.0, 248.0, -11.0, [248.0, 236.0])],
		},
	)
	# pace renders as time-per-distance, not the stored m/s: 4.1667 m/s is 4:00/km
	# both rendered every rep as "4", making the whole screen useless for runs
	Str.contains(pace, "4:00") and Str.contains(pace, "in min/km")
		# and the fade is signed so NEGATIVE means slower, matching how watts read
		and Str.contains(pace, "fade -0:02")
		# a HR DROP across reps rendered as "hr +-8" -- the + was hardcoded
		and Str.contains(dropped, "hr -8") and !(Str.contains(dropped, "+-"))
		# rows are ranked by uniformity then capped, so "showing 12 of 21" reads as
		# "the other 9 are older" when they are the least regular
		and Str.contains(power, "most uniform of 21")
		# and the count of like-for-like evidence leads, rather than hiding in a
		# per-row caveat that fired on 11 of 12 rows
		# a contains-check on "1 of 21" passes with or without the ≥, so the ≥
		# itself is pinned, along with a case where it must be ABSENT.
		# capped AND every shown row conforms: the count is a LOWER bound, so the
		# remainder is hedged rather than named exactly -- "≥1 of 21" and "the
		# other 20" together would contradict each other
		and Str.contains(power, "≥1 of 21 matched sessions is itself")
		and Str.contains(power, "up to 20 others")
		# ...and the HEDGED branch needs the singular too, or it reads "up to 1
		# others match".
		and Str.contains(
			Render.reps_screen(
				Metric,
				{
					anchor_date: "2026-08-16",
					shape_reps: 3.I64,
					shape_dur: 718.I64,
					matched_total: 2.I64,
					signal: "power",
					sessions: [sess("2026-08-16", 1.01, 11.0, 262.0, -16.0, [268.0, 252.0])],
				},
			),
			"up to one other matches",
		)
		and !(Str.contains(power, "the other 20"))
		# the NOUN stays plural even when one row conforms
		and !(Str.contains(power, "matched session is"))
		# nothing capped and everything conforms: no ≥, and no clause naming a
		# remainder of zero (it read "1 of 1 ... the rest are listed")
		and Str.contains(pace, "2 of 2 matched sessions are themselves")
		and !(Str.contains(pace, "≥"))
		and !(Str.contains(pace, "the other"))
		and !(Str.contains(pace, "up to"))
		and Str.contains(mixed, "1 of 3 matched sessions is itself")
		and Str.contains(mixed, "the other 2 match its rep count")
		and !(Str.contains(mixed, "≥")) and !(Str.contains(mixed, "up to"))
		and Str.contains(power, "W ·") and !(Str.contains(power, "m/s"))
}

# fade_value inherits the rounds-away-but-still-a-direction contract pinned above, which
# is why a pace fade keeps its sign instead of collapsing to a bare zero. It takes
# ENDPOINTS, not a delta, because a pace change cannot be derived from a speed change.
# Sign is flipped for pace so NEGATIVE means worse in both sports:
# 4.1667 m/s -> 4.13 m/s is a slowdown of 2.13 s/km, so it reads -0:02, not +0:02.
expect Render.fade_value(Metric, 4.1667, 4.13, "pace") == "-0:02"
expect Render.fade_value(Imperial, 4.1667, 4.13, "pace") == "-0:03"
# speeding up reads positive, the same direction a power gain does
expect Render.fade_value(Metric, 4.13, 4.1667, "pace") == "+0:02"
expect Render.fade_value(Metric, 250.0, 240.0, "power") == "-10"
expect Render.fade_value(Metric, 240.0, 250.0, "power") == "+10"
# a missing endpoint is not a fade of zero
expect Render.fade_value(Metric, 0.0, 4.13, "pace") == "-"

# ftp_path splices the peak or trough in when the threshold left its own
# endpoints. "Ride 234→239" read as a flat block that actually ran 234→271→239,
# and three of six real blocks were misread that way.
expect {
	# rose then fell: the peak is above both ends
	peaked = Render.ftp_path(234.0, 239.0, 234.0, 271.0)
	# fell then rose: the trough is below both ends
	dipped = Render.ftp_path(300.0, 310.0, 250.0, 310.0)
	# monotone: nothing to splice, either direction
	up = Render.ftp_path(165.0, 212.0, 165.0, 212.0)
	down = Render.ftp_path(271.0, 243.0, 243.0, 271.0)
	# a lo of 0 is "no lower value recorded", not a trough at zero
	nolo = Render.ftp_path(200.0, 220.0, 0.0, 220.0)
	peaked == "234→271→239"
		and dipped == "300→250→310"
		and up == "165→212"
		and down == "271→243"
		and nolo == "200→220"
}

# ── the engine/coach boundary across ALL verdict producers ────
# Every human verdict line stride renders is state, never advice. Each producer
# is exercised at representative inputs and swept with the shared predicate —
# mutation-tested wording ("you should consider a rest day") fails here.
expect {
	compare_verdicts = [
		Render.compare_verdict(958.0, 1181.0, 6.0, "28d"),
		Render.compare_verdict(1181.0, 900.0, -2.0, "28d"),
		Render.compare_verdict(1000.0, 1030.0, 0.0, "28d"),
		Render.compare_verdict(0.0, 500.0, 3.0, "week"),
		Render.compare_verdict(0.0, 0.0, 0.0, "week"),
	]
	List.all(compare_verdicts, |v| !(Metrics.has_coaching_language(v)))
}

# tte_screen renders the most opinionated prose in stride ("the model's answer
# and not your body's"), and joined the codebase outside this sweep. All three
# statuses plus both demonstrated-effort branches are state, never advice.
expect {
	tte = |status, dem, contra| Render.tte_screen({
		watts: 265.0,
		seconds: 596.0,
		known: True,
		status,
		cp: 254.0,
		w_prime: 6416.0,
		fit_points: 3.I64,
		estimated_sessions: 0.I64,
		fit_r2: 0.72,
		window_days: 90.I64,
		sport_family: "Ride",
		demonstrated_s: 600.0,
		demonstrated_w: 271.0,
		demonstrated_known: dem,
		contradicts_model: contra,
	})
	tte_phrases = [
		tte("in_model", False, False),
		tte("in_model", True, True),
		tte("outside_model", True, False),
		tte("below_cp", False, False),
	]
	List.all(tte_phrases, |p| !(Metrics.has_coaching_language(p)))
		# the query-independent fit-quality number reaches the human screen -- a
		# coach reading only the terminal must see what the payload sees
		and Str.contains(tte("in_model", False, False), "fit quality 0.72 of 1")
		# ...and is SUPPRESSED at two points. Only the presence direction was asserted, so
		# mutating the gate to always-show left the suite green.
		and !(
			Str.contains(
				Render.tte_screen({
					watts: 265.0,
					seconds: 596.0,
					known: True,
					status: "in_model",
					cp: 254.0,
					w_prime: 6416.0,
					fit_points: 2.I64,
					fit_r2: 1.0,
					window_days: 90.I64,
					sport_family: "Ride",
					demonstrated_s: 0.0,
					demonstrated_w: 0.0,
					demonstrated_known: False,
					contradicts_model: False,
				}),
				"fit quality",
			)
		)
		# the hour rollover is what keeps a near-CP query from rendering 222 days
		# as "320807:09" — pinned because mmss is the tempting reuse
		and Render.hms(596.I64) == "9:56"
		and Render.hms(3600.I64) == "1:00:00"
		and Render.hms(8405.I64) == "2:20:05"
}

# tte_pace_screen: state, never advice, on every status; every pace in the
# caller's own unit, the on-record speed included; r2 only from three points
expect {
	tp = |status, dem, contra, n| Render.tte_pace_screen({
		pace_s: 225.0,
		pace_unit: "/km",
		speed: 1000.0 / 225.0,
		seconds: 540.0,
		known: True,
		status,
		cs: 4.0,
		d_prime: 240.0,
		cs_pace_s: 250.0,
		fit_points: n,
		fit_r2: 0.97,
		window_days: 90.I64,
		sport: "Run",
		demonstrated_s: 300.0,
		demonstrated_speed: 4.8,
		demonstrated_known: dem,
		contradicts_model: contra,
	})
	phrases = [tp("in_model", False, False, 3.I64), tp("in_model", True, True, 3.I64), tp("outside_model", True, False, 3.I64), tp("below_cs", False, False, 3.I64)]
	List.all(phrases, |p| !(Metrics.has_coaching_language(p)))
		and Str.contains(tp("in_model", True, False, 3.I64), "at 3:45/km against your critical speed (CS) 4:10/km (Run fit, D′ 240 m")
		and Str.contains(tp("in_model", True, False, 3.I64), "~9:00 · on record: 3:28/km for 5:00")
		and Str.contains(tp("in_model", False, False, 3.I64), "fit quality 0.97 of 1")
		and !(Str.contains(tp("in_model", False, False, 2.I64), "fit quality"))
		and Str.contains(tp("below_cs", False, False, 3.I64), "no limit")
		and Str.contains(tp("outside_model", False, False, 3.I64), "OUTSIDE")
		and Str.contains(tp("in_model", True, True, 3.I64), "LONGER than the model predicts")
}

# the HARD boundary invariant for compare: the verdict templates are a
# CLOSED SET, pinned by full-string equality like form_label — a reworded
# template ("time to push harder") fails HERE even if the denylist misses it.
# One pin per load template, cycling the three fitness words.
expect {
	Render.compare_verdict(1000.0, 1200.0, 6.0, "28d") == "load ramping (20%) · fitness building"
		and Render.compare_verdict(1200.0, 900.0, -2.0, "28d") == "load backed off (-25%) · fitness slipping"
		and Render.compare_verdict(1000.0, 1030.0, 0.0, "28d") == "load steady (3%) · fitness holding"
		and Render.compare_verdict(0.0, 500.0, 3.0, "week") == "load resumed (500 load vs none the prior week) · fitness building"
		and Render.compare_verdict(0.0, 0.0, 0.0, "week") == "no load recorded either week · fitness holding"
}

expect {
	trend_phrases = [
		Render.form_trend_phrase(Known(4.2)),
		Render.form_trend_phrase(Known(-8.0)),
		Render.form_trend_phrase(Known(0.0)),
		Render.form_trend_phrase(Unknown),
	]
	band_phrases = [
		Render.band_days_phrase(Known(3)),
		Render.band_days_phrase(AtLeast(31)),
		Render.band_days_phrase(Unknown),
	]
	List.all(List.concat(trend_phrases, band_phrases), |p| !(Metrics.has_coaching_language(p)))
}

expect !(Metrics.has_coaching_language(Render.warming_up_note(True, 12))) and !(Metrics.has_coaching_language(Render.warming_up_note(False, 90)))

# ── the stream-drain note ───────────────────────────────
# Every arm pinned by full-string equality, and the SCREEN pinned on both inputs it
# forwards — substring or empty-case-only expects pass with every number deleted
# from the format string.
expect Render.drain_note(Complete, { streams: 0, owed: 0, resume: "", again: False }) == ""
# the count outranks the reason: a budget stop that empties every queue is done, as
# `resumable: false` says
expect Render.drain_note(BudgetReached, { streams: 0, owed: 0, resume: "10:45", again: False }) == ""
expect Render.drain_note(RateLimited, { streams: 0, owed: 0, resume: "10:45", again: True }) == ""
# a complete run names only its unreadable streams, and a stop names everything owed
expect Render.drain_note(Complete, { streams: 2, owed: 9, resume: "", again: False }) == "2 had unreadable stream data and retry on the next sync"
expect Render.drain_note(BudgetReached, { streams: 0, owed: 9, resume: "10:45", again: False }) == "filled Strava's read window with 9 fetches still owed; the next window opens at 10:45"
expect Render.drain_note(BudgetReached, { streams: 1, owed: 1, resume: "10:45", again: False }) == "filled Strava's read window with 1 fetch still owed; the next window opens at 10:45"
expect Render.drain_note(RateLimited, { streams: 40, owed: 40, resume: "10:45", again: True }) == "Strava refused reads in a fresh window with 40 fetches still owed; the next window opens at 10:45"
# the day's stop names the local time midnight UTC falls at, on both queue shapes
expect Render.drain_note(DailyCapReached, { streams: 40, owed: 40, resume: "18:00", again: False }) == "today's Strava read allowance is used up with 40 fetches still owed; it returns at 18:00, midnight UTC"
expect Render.drain_note(DailyCapReached, { streams: 0, owed: 0, resume: "18:00", again: False }) == "today's Strava read allowance is used up, so nothing was fetched; it returns at 18:00, midnight UTC"
# no stop sends the athlete away for a vague while: every one names its time
expect {
	notes = [
		Render.drain_note(BudgetReached, { streams: 4, owed: 4, resume: "10:45", again: False }),
		Render.drain_note(RateLimited, { streams: 4, owed: 4, resume: "10:45", again: True }),
		Render.drain_note(DailyCapReached, { streams: 4, owed: 4, resume: "18:00", again: False }),
		Render.drain_note(DailyCapReached, { streams: 0, owed: 0, resume: "18:00", again: False }),
	]
	List.all(notes, |n| !(Str.contains(n, "15 minutes")) and !(Str.contains(n, "tomorrow")) and !(Str.contains(n, "again")))
}

# The wire strings still have to match the producer — drain_note takes a StopReason,
# so the compiler already guarantees every reason has a branch; what no type can
# guarantee is that `stopped_label`'s spellings match schemas/v3/sync.json, a
# document. Hand-typed on purpose: these pin tag -> Roc literal, and the e2e schema
# check pins emitted literal -> schema enum.
expect Drain.stopped_label(Complete) == "complete"
expect Drain.stopped_label(BudgetReached) == "budget_reached"
expect Drain.stopped_label(RateLimited) == "rate_limited"
expect Drain.stopped_label(DailyCapReached) == "daily_cap_reached"
expect Drain.sync_stopped_label(ListRateLimited) == "list_rate_limited"

# No label may appear RAW in the human line. Enumerated by hand: a new SyncStop arm
# forces sync_screen and sync_stopped_label, a new StopReason arm forces
# stopped_label and drain_note, and neither compiler error reaches this list. When
# you add an arm to either type, add it here too. Both `pending` shapes, because the
# tail dispatches on what is owed.
expect {
	stops = [FromDrain(Complete), FromDrain(BudgetReached), FromDrain(RateLimited), FromDrain(DailyCapReached), ListRateLimited, ListDailyCapReached]
	List.all(
		stops,
		|t| {
			lbl = Drain.sync_stopped_label(t)
			row = |pending| { ..Render.sync_fixture, streams_fetched: 2, pending_streams: pending, stopped: lbl, resumable: pending > 0 }
			!(Str.contains(Render.sync_screen(row(9), t, Render.sync_note_fixture), lbl))
				and !(Str.contains(Render.sync_screen(row(0), t, Render.sync_note_fixture), lbl))
		},
	)
}

# ADR 0012's boundary rule: a new prose surface joins the denylist sweep. These are
# tool instructions (when the next read window opens), not training advice, but
# the rule is about surfaces rather than intent — and a sweep that skips a surface
# because someone judged it exempt is how the gap recurs.
expect {
	no_end = { known: Bool.False, date: "", ctl: 0.0, atl: 0.0, tsb: 0.0 }
	# the complete clause's input with nothing known: each target row below overrides
	# only what its kind carries
	tm_base = { target_kind: "", target_literal: "", target_pace_unit: "", target_rpe: 0, detected_known: Bool.False, detected_reps: 0, detected_mean_dur_s: 0, detected_mean_watts: 0.0, exec_known: Bool.False, exec_reason: "", hr_under_s: 0, hr_in_s: 0, hr_over_s: 0, hr_mean: 0.0, zone_below_s: 0, zone_in_s: 0, zone_above_s: 0, pace_basis: "", pace_actual_s: 0.0, pace_reps: 0, rpe_actual: 0.0 }
	notes = [
		Render.drain_note(Complete, { streams: 0, owed: 0, resume: "", again: False }),
		Render.drain_note(Complete, { streams: 5, owed: 5, resume: "", again: False }),
		Render.drain_note(BudgetReached, { streams: 40, owed: 40, resume: "10:45", again: False }),
		Render.drain_note(RateLimited, { streams: 40, owed: 40, resume: "10:45", again: True }),
		# the daily cap, BOTH pending shapes. Its empty-queue arm is the one that says
		# something where the other three say nothing, so it is prose the others are not.
		Render.drain_note(DailyCapReached, { streams: 0, owed: 0, resume: "18:00", again: False }),
		Render.drain_note(DailyCapReached, { streams: 40, owed: 40, resume: "18:00", again: False }),
		# the list-refusal sentences and the analysis clauses are prose surfaces of
		# their own — they do not come through drain_note
		Render.sync_screen({ ..Render.sync_fixture, stopped: Drain.sync_stopped_label(ListRateLimited), resumable: True }, ListRateLimited, Render.sync_note_fixture),
		Render.sync_screen({ ..Render.sync_fixture, new_activities: 100, pending_streams: 100, stopped: Drain.sync_stopped_label(ListRateLimited), resumable: True }, ListRateLimited, Render.sync_note_fixture),
		Render.sync_screen({ ..Render.sync_fixture, stopped: Drain.sync_stopped_label(ListDailyCapReached), resumable: True }, ListDailyCapReached, Render.sync_note_fixture),
		Render.sync_screen(Render.sync_fixture, FromDrain(Complete), { ..Render.sync_note_fixture, analysis: NoZones }),
		Render.sync_screen(Render.sync_fixture, FromDrain(Complete), { ..Render.sync_note_fixture, analysis: Unsettled }),
		Render.wait_frame({ daily: False, tick: 0, at: "10:45", left: 252 }),
		# freshness_note is a prose surface too, and ADR 0012's own consequences say the
		# sweep is where a new one joins. Every arm, including the empty one: an arm that
		# is only exercised on a broken config is exactly the one nobody would think to
		# add later.
		Render.freshness_note({ activities_awaiting_metrics: 0, activities_awaiting_metrics_known: True, activities_awaiting_streams: 0 }),
		Render.freshness_note({ activities_awaiting_metrics: 12, activities_awaiting_metrics_known: True, activities_awaiting_streams: 0 }),
		Render.freshness_note({ activities_awaiting_metrics: 0, activities_awaiting_metrics_known: True, activities_awaiting_streams: 40 }),
		Render.freshness_note({ activities_awaiting_metrics: 12, activities_awaiting_metrics_known: True, activities_awaiting_streams: 40 }),
		Render.freshness_note({ activities_awaiting_metrics: 0, activities_awaiting_metrics_known: False, activities_awaiting_streams: 4 }),
		# the target clauses join on arrival — targeted/untargeted on the echo,
		# and all three match arms: both known, target-only, and the silent untargeted
		Render.target_note(T(Metrics.power_target({ reps: 3, dur_s: 720, watts: 230.0 }))),
		Render.target_note(T({ ..Metrics.no_target, kind: "hr", reps: 1, dur_s: 3600, hr_lo: 125, hr_hi: 147 })),
		Render.target_note(NoT),
		Render.target_match_note({ ..tm_base, target_kind: "power", target_literal: "3x12:00@230W", detected_known: True, detected_reps: 3, detected_mean_dur_s: 720, detected_mean_watts: 233.0, exec_known: True }),
		Render.target_match_note({ ..tm_base, target_kind: "power", target_literal: "3x12:00@230W", exec_reason: "no_power_intervals" }),
		Render.target_match_note({ ..tm_base, target_kind: "hr", target_literal: "1x1:00:00@HR125-147", exec_known: True, hr_in_s: 3130, hr_over_s: 185, hr_under_s: 285, hr_mean: 138.2 }),
		Render.target_match_note({ ..tm_base, target_kind: "hr", target_literal: "1x1:00:00@HR125-147", exec_reason: "no_hr_stream" }),
		Render.target_match_note({ ..tm_base, target_kind: "zone", target_literal: "1x1:30:00@Z2", exec_known: True, zone_in_s: 4200, zone_above_s: 300, zone_below_s: 900 }),
		Render.target_match_note({ ..tm_base, target_kind: "zone", target_literal: "1x1:30:00@Z2", exec_reason: "no_hr_zones" }),
		Render.target_match_note({ ..tm_base, target_kind: "pace", target_literal: "5x4:00@4:10/km", target_pace_unit: "/km", exec_known: True, pace_basis: "detected", pace_actual_s: 245.0, pace_reps: 5 }),
		Render.target_match_note({ ..tm_base, target_kind: "pace", target_literal: "10x100m@1:40/100m", target_pace_unit: "/100m", exec_known: True, pace_basis: "whole", pace_actual_s: 104.0 }),
		Render.target_match_note({ ..tm_base, target_kind: "pace", target_literal: "6x500m@1:55/500m", target_pace_unit: "/500m", exec_reason: "pace_unit_mismatch" }),
		Render.target_match_note({ ..tm_base, target_kind: "pace", target_literal: "5x4:00@4:10/km", target_pace_unit: "/km", exec_reason: "no_distance" }),
		Render.target_match_note({ ..tm_base, target_kind: "rpe", target_literal: "1x45:00@RPE6", target_rpe: 6, exec_known: True, rpe_actual: 7.0 }),
		Render.target_match_note({ ..tm_base, target_kind: "rpe", target_literal: "1x45:00@RPE6", target_rpe: 6, exec_reason: "no_rating" }),
		Render.target_match_note(tm_base),
		# events_screen joins on arrival: the empty state, a populated row, and
		# both degraded-baseline notes — ADR 0010 warns "you are on track" would slip
		# the denylist, which is why the screen carries no verdict line AT ALL, and the
		# sweep is backstop rather than proof
		Render.events_screen({ projected_from: "2026-08-30", baseline_known: True, ftp_known: True, events: [] }),
		Render.events_screen({ projected_from: "2026-08-30", baseline_known: True, ftp_known: True, events: [{ id: 1, event_date: "2026-10-15", name: "Fall Century", days_away: 46, ctl: 38.2, atl: 22.1, tsb: 16.1, planned_in_window: 4, sessions_projected: 2, unprojected: [{ date: "2026-09-02", target_literal: "", reason: "no_target" }, { date: "2026-09-03", target_literal: "1x1:00:00@4:10/km", reason: "no_threshold_pace" }], plan_end: no_end }] }),
		Render.events_screen({ projected_from: "2026-08-30", baseline_known: False, ftp_known: False, events: [{ id: 1, event_date: "2026-10-15", name: "Fall Century", days_away: 46, ctl: 0.0, atl: 0.0, tsb: 0.0, planned_in_window: 0, sessions_projected: 0, unprojected: [], plan_end: no_end }] }),
		Render.events_screen({ projected_from: "2026-08-30", baseline_known: True, ftp_known: False, events: [{ id: 1, event_date: "2026-10-15", name: "Fall Century", days_away: 46, ctl: 12.0, atl: 3.0, tsb: 9.0, planned_in_window: 2, sessions_projected: 0, unprojected: [{ date: "2026-09-02", target_literal: "3x12:00@230W", reason: "no_ftp" }, { date: "2026-09-04", target_literal: "3x12:00@230W", reason: "no_ftp" }], plan_end: no_end }] }),
		Render.events_screen({ projected_from: "2026-08-30", baseline_known: True, ftp_known: True, events: [{ id: 2, event_date: "2026-08-01", name: "Past Race", days_away: -29, ctl: 40.0, atl: 50.0, tsb: -10.0, planned_in_window: 0, sessions_projected: 0, unprojected: [], plan_end: no_end }] }),
		# project_screen joins on arrival: recorded, hypothetical, and both notes
		Render.project_screen({ target_date: "2026-10-15", days_away: 46, projected_from: "2026-08-30", baseline_known: True, ftp_known: True, plan_source: "recorded", ctl: 30.0, atl: 20.0, tsb: 10.0, sessions_considered: 3, sessions_projected: 2, unprojected: [], hypothetical: [] }),
		Render.project_screen({ target_date: "2026-10-15", days_away: 46, projected_from: "2026-08-30", baseline_known: True, ftp_known: True, plan_source: "hypothetical", ctl: 30.0, atl: 20.0, tsb: 10.0, sessions_considered: 1, sessions_projected: 1, unprojected: [{ date: "2026-09-20", target_literal: "1x1:00:00@HR125-147", reason: "no_hr_zones" }, { date: "2026-09-21", target_literal: "", reason: "no_target" }], hypothetical: [{ date: "2026-09-15", target_kind: "power", target_literal: "3x12:00@230W", reps: 3, dur_s: 720, watts: 230.0 }] }),
		Render.project_screen({ target_date: "2026-10-15", days_away: 46, projected_from: "2026-08-30", baseline_known: False, ftp_known: False, plan_source: "recorded", ctl: 0.0, atl: 0.0, tsb: 0.0, sessions_considered: 0, sessions_projected: 0, unprojected: [], hypothetical: [] }),
		Render.project_screen({ target_date: "2026-10-15", days_away: 46, projected_from: "2026-08-30", baseline_known: True, ftp_known: False, plan_source: "recorded", ctl: 12.0, atl: 3.0, tsb: 9.0, sessions_considered: 2, sessions_projected: 0, unprojected: [], hypothetical: [] }),
		Render.project_screen({ target_date: "2020-01-01", days_away: -2433, projected_from: "2026-08-30", baseline_known: True, ftp_known: True, plan_source: "recorded", ctl: 40.9, atl: 50.0, tsb: -9.1, sessions_considered: 0, sessions_projected: 0, unprojected: [], hypothetical: [] }),
	]
	List.all(notes, |p| !(Metrics.has_coaching_language(p)))
}

# ── plan's data-freshness line ────────────────────────────────
# Full-string equality throughout, for the reason the sync_screen block below records:
# an expect that only asserts a substring, or only asserts the "" case, passes with every
# number deleted from the format string.
#
# Silence when there is nothing to report. Asserted FIRST and separately from the rest,
# because this is the arm that runs on almost every real invocation — if it were the only
# case covered, the whole line could be dead and the suite would still be green.
expect Render.freshness_note({ activities_awaiting_metrics: 0, activities_awaiting_metrics_known: True, activities_awaiting_streams: 0 }) == ""

expect
	Render.freshness_note({ activities_awaiting_metrics: 12, activities_awaiting_metrics_known: True, activities_awaiting_streams: 0 })
		== "DATA: 12 awaiting metrics (stride analyze)"

expect
	Render.freshness_note({ activities_awaiting_metrics: 0, activities_awaiting_metrics_known: True, activities_awaiting_streams: 40 })
		== "DATA: 40 awaiting streams (stride sync)"

# Both arms at once: pins the separator AND the order, neither of which any single-arm
# case above can see.
expect
	Render.freshness_note({ activities_awaiting_metrics: 12, activities_awaiting_metrics_known: True, activities_awaiting_streams: 40 })
		== "DATA: 12 awaiting metrics (stride analyze) · 40 awaiting streams (stride sync)"

# The counts are forwarded, not hardcoded — distinct values, distinct from the case above.
expect
	Render.freshness_note({ activities_awaiting_metrics: 1, activities_awaiting_metrics_known: True, activities_awaiting_streams: 7 })
		== "DATA: 1 awaiting metrics (stride analyze) · 7 awaiting streams (stride sync)"

# An unknowable count SPEAKS, where a zero stays silent. The count is 0 in both, so this is
# the pair that proves the line keys on `known` and not on the number beside it.
expect
	Render.freshness_note({ activities_awaiting_metrics: 0, activities_awaiting_metrics_known: False, activities_awaiting_streams: 0 })
		== "DATA: awaiting-metrics count unreadable (stride analyze says why)"

# ...and it still composes with the streams arm rather than replacing the whole line.
expect
	Render.freshness_note({ activities_awaiting_metrics: 0, activities_awaiting_metrics_known: False, activities_awaiting_streams: 4 })
		== "DATA: awaiting-metrics count unreadable (stride analyze says why) · 4 awaiting streams (stride sync)"

# ── sync's human screen ─────────────────────────────────────────
# Full-string equality: an e2e `contains` on this line would pass with a number
# deleted from the format string, and these pin each forwarded value.
# the routine transcript of ADR 0021, singular where the count is one
expect
	Render.sync_screen({ ..Render.sync_fixture, synced: 25, new_activities: 1, streams_fetched: 1, notes_fetched: 11 }, FromDrain(Complete), { ..Render.sync_note_fixture, verdict: "→ today: form -1, down 4 from a week ago — balanced" })
		== "synced 1 new activity, streams for 1, 11 strength descriptions; everything analyzed\n→ today: form -1, down 4 from a week ago — balanced"
expect
	Render.sync_screen({ ..Render.sync_fixture, synced: 22, new_activities: 2, updated_activities: 1, streams_fetched: 5, notes_fetched: 1, routes_fetched: 3 }, FromDrain(Complete), Render.sync_note_fixture)
		== "synced 2 new activities, 1 updated, streams for 5, 1 strength description, routes for 3; everything analyzed"
# a sync that brought nothing says so, and still says the history is analyzed
expect Render.sync_screen({ ..Render.sync_fixture, synced: 3 }, FromDrain(Complete), Render.sync_note_fixture) == "synced, nothing new; everything analyzed"
expect Render.sync_screen({ ..Render.sync_fixture, pruned: 2 }, FromDrain(Complete), Render.sync_note_fixture) == "synced 2 removed on Strava; everything analyzed"
# no zones, nothing analyzed, and the command that sets them named
expect Render.sync_screen({ ..Render.sync_fixture, new_activities: 2 }, FromDrain(Complete), { ..Render.sync_note_fixture, analysis: NoZones }) == "synced 2 new activities; nothing analyzed until heart-rate zones are set (`stride setup` sets them)"
expect Render.sync_screen(Render.sync_fixture, FromDrain(Complete), { ..Render.sync_note_fixture, analysis: Unsettled }) == "synced, nothing new; scoring did not settle, a stride bug that `stride analyze` describes"

# A refused LIST says so, about the LIST, with the window's time. `stopped` is built by
# the PRODUCER rather than hand-typed, so a rename on either side fails here.
expect
	Render.sync_screen({ ..Render.sync_fixture, stopped: Drain.sync_stopped_label(ListRateLimited), resumable: True }, ListRateLimited, Render.sync_note_fixture)
		== "synced, nothing new; everything analyzed — the read window was spent before the activity list ended, so it is incomplete; nothing was pruned; the next window opens at 10:45"
# ...and with a FULL queue, the first-run shape, still blaming the list and not the drain
expect
	Render.sync_screen({ ..Render.sync_fixture, synced: 100, new_activities: 100, pending_streams: 100, stopped: Drain.sync_stopped_label(ListRateLimited), resumable: True }, ListRateLimited, Render.sync_note_fixture)
		== "synced 100 new activities; everything analyzed — the read window was spent before the activity list ended, so it is incomplete; nothing was pruned; the next window opens at 10:45"
# the prune claim comes from `pruned`, not from `stopped`
expect
	Render.sync_screen({ ..Render.sync_fixture, pruned: 2, stopped: Drain.sync_stopped_label(ListRateLimited), resumable: True }, ListRateLimited, Render.sync_note_fixture)
		== "synced 2 removed on Strava; everything analyzed — the read window was spent before the activity list ended, so it is incomplete; the next window opens at 10:45"
expect
	Render.sync_screen({ ..Render.sync_fixture, stopped: Drain.sync_stopped_label(ListDailyCapReached), resumable: True }, ListDailyCapReached, { ..Render.sync_note_fixture, resume: "18:00" })
		== "synced, nothing new; everything analyzed — Strava refused the activity list with today's read allowance used up, so it is incomplete; nothing was pruned; it returns at 18:00, midnight UTC"
# a DRAIN refusal gets drain_note's wording, owing every queue
expect
	Render.sync_screen({ ..Render.sync_fixture, synced: 3, streams_fetched: 2, pending_streams: 5, pending_routes: 7, stopped: "rate_limited", resumable: True }, FromDrain(RateLimited), { ..Render.sync_note_fixture, again: True })
		== "synced streams for 2; everything analyzed — Strava refused reads in a fresh window with 12 fetches still owed; the next window opens at 10:45"
# a budget stop states the reason AND the streams that would not decode
expect
	Render.sync_screen({ ..Render.sync_fixture, synced: 9, streams_fetched: 12, streams_skipped: 1, pending_streams: 40, stopped: "budget_reached", resumable: True }, FromDrain(BudgetReached), Render.sync_note_fixture)
		== "synced streams for 12 (1 stream would not decode); everything analyzed — filled Strava's read window with 40 fetches still owed; the next window opens at 10:45"
# a COMPLETE run with skips states the fact once: drain_note owns it there
expect
	Render.sync_screen({ ..Render.sync_fixture, synced: 2, streams_fetched: 1, streams_skipped: 1, pending_streams: 1, resumable: True }, FromDrain(Complete), Render.sync_note_fixture)
		== "synced streams for 1; everything analyzed — 1 had unreadable stream data and retry on the next sync"
# the daily cap reached in the routes drain owes the queued routes, never "nothing was
# fetched" beside the routes it did fetch
expect
	Render.sync_screen({ ..Render.sync_fixture, synced: 3, routes_fetched: 40, pending_routes: 300, stopped: "daily_cap_reached", resumable: True }, FromDrain(DailyCapReached), { ..Render.sync_note_fixture, resume: "18:00" })
		== "synced routes for 40; everything analyzed — today's Strava read allowance is used up with 300 fetches still owed; it returns at 18:00, midnight UTC"
# routes that would not decode are named apart from the routes fetched
expect
	Render.sync_screen({ ..Render.sync_fixture, synced: 3, routes_fetched: 3, routes_skipped: 2, pending_routes: 2, resumable: True }, FromDrain(Complete), Render.sync_note_fixture)
		== "synced routes for 3 (2 routes would not decode); everything analyzed"

# the events empty state is a CLOSED output — full-string equality per ADR 0012's hard
# guard, so no verdict can ever ride into it unpinned
expect Render.events_screen({ projected_from: "2026-08-30", baseline_known: True, ftp_known: True, events: [] }) == "no event targets on file — `stride event add <YYYY-MM-DD> \"<name>\"` records one"
# an event whose window holds unpriced sessions names why, counted per reason in a
# fixed order; a window with none adds no line
expect Render.unprojected_tally([{ date: "2026-09-04", target_literal: "3x12:00@230W", reason: "no_ftp" }, { date: "2026-09-02", target_literal: "", reason: "no_target" }, { date: "2026-09-05", target_literal: "3x12:00@230W", reason: "no_ftp" }]) == "\n      not estimated: 1 with no target, 2 with no FTP from the last 60 days"
expect Render.unprojected_tally([]) == ""

# the verdict line analyze and sync both print, and none before there is form
expect Render.today_verdict(Some(-1.2), Known(-4.0)) == "→ today: form -1, down 4 from a week ago — balanced"
expect Render.today_verdict(None, Known(-4.0)) == ""
expect Str.contains(Render.unsettled_note(8064), "8064 scores without settling")

# the waiting transcript of ADR 0021, line by line
expect Render.step_line("activity list", Render.list_result({ checked: 412, new: 412, updated: 0 })) == "activity list       412 checked, 412 new"
expect Render.progress_bar("scoring", 412, 412) == "scoring             [██████████] 412/412"
expect Render.progress_bar("streams", 90, 412) == "streams             [██░░░░░░░░]  90/412"
expect Render.progress_bar("scoring", 90, 90) == "scoring             [██████████] 90/90"

# a finished step redrawn over the wait's frame covers all of it, so the
# frame's "4:12 left" cannot show past the shorter result
expect {
	result = Render.step_result("waiting for Strava", "next batch started at 12:06")
	Render.display_width(result) >= Render.display_width(Render.wait_frame({ daily: False, tick: 0, at: "12:06", left: 899 }))
		and Str.trim_end(result) == "waiting for Strava  next batch started at 12:06"
}
# a run that asked Strava for nothing says so instead of "nothing new"
expect
	Render.sync_screen({ ..Render.sync_fixture, pending_streams: 11, stopped: "daily_cap_reached", resumable: True }, FromDrain(DailyCapReached), { ..Render.sync_note_fixture, resume: "18:00", requested: False })
		== "nothing synced: this run made no request; everything analyzed — today's Strava read allowance is used up with 11 fetches still owed; it returns at 18:00, midnight UTC"

# the wait for the daily allowance names it, with the hours and minutes left
expect Str.trim_end(Render.wait_frame({ daily: True, tick: 2, at: "18:00", left: 27720 })) == "daily allowance     - returns 18:00, 7 h 42 min left"
expect Render.clock_left(3600) == "1 h 0 min" and Render.clock_left(3599) == "59:59"
expect Render.display_width(Render.wait_frame({ daily: True, tick: 0, at: "01:00 on 2026-11-26", left: 86399 })) == Render.wait_frame_width

# a refusal right after a wait names the situation rather than the limit alone
expect Render.drain_note(RateLimited, { streams: 4, owed: 4, resume: "10:45", again: False }) == "Strava refused a read with 4 fetches still owed; the next window opens at 10:45"
expect Render.drain_note(DailyCapReached, { streams: 4, owed: 4, resume: "18:00", again: True }) == "today's Strava read allowance was still spent after its reset, so another app on this token may be using it; 4 fetches still owed, and it returns at 18:00, midnight UTC"
expect Render.drain_note(BudgetReached, { streams: 4, owed: 4, resume: "10:45", again: True }) == "the read window was still full after the wait, so another app on this token may be using it; 4 fetches still owed, and the next window opens at 10:45"

# the daily transcript of ADR 0021, line by line
expect Str.trim_end(Render.wait_frame({ daily: True, tick: 3, at: "18:00", left: 27720 })) == "daily allowance     \\ returns 18:00, 7 h 42 min left"
expect Render.progress_bar("streams", 939, 1412) == "streams             [██████░░░░]  939/1412"
expect Render.progress_bar("scoring", 85, 85) == "scoring             [██████████] 85/85"

# an event the written plan stops short of names both dates its numbers are
# for, each through Load.projected_on, the text the window's event card reads
# for the same date and numbers (Board.proj_lines, in the window's expects)
expect {
	s = Render.events_screen({ projected_from: "2026-11-25", baseline_known: True, ftp_known: True, events: [{ id: 2, event_date: "2027-06-26", name: "Tour de Chi", days_away: 212, ctl: 0.6, atl: 0.0, tsb: 0.6, planned_in_window: 20, sessions_projected: 16, unprojected: [], plan_end: { known: Bool.True, date: "2026-12-15", ctl: 54.94, atl: 53.6, tsb: 1.26 } }] })
	Str.contains(s, "event day 2027-06-26: fitness 0.6, form 0.6 (fatigue 0.0)")
		and Str.contains(s, "plan's last day 2026-12-15: fitness 54.9, form 1.3 (fatigue 53.6); nothing is planned after it")
		and !(Str.contains(s, "ctl 0.6"))
}

# the config listing names who owns each key and never shows a value, a
# secret included, and says which command reads one
expect {
	s = Render.config_screen([{ key: "ftp_ride", status: "derived", redacted: Bool.False }, { key: "strava_access_token", status: "managed", redacted: Bool.True }, { key: "timezone", status: "settable", redacted: Bool.False }, { key: "timezon", status: "unrecognised", redacted: Bool.False }])
	s == "ftp_ride  (derived from your power history)\nstrava_access_token  (secret; set by stride)\ntimezone\ntimezon  (unrecognised, stride does not read it)\nvalues are not listed — `stride config get <key>` reads one"
}
expect Render.config_screen([]) == "no config set — `stride config set <key> <value>`"

# doctor names each scoring step in words; a name the list lacks reads as stored
expect List.map(["power_stream", "rtss", "hr_zones", "session_rpe", "relative_effort", "none", "unknown (pre-provenance)", "later_model"], Render.load_model_name) == ["power, second by second", "pace", "time in heart-rate zones", "your rating (session-RPE)", "Strava's relative effort", "not scored", "unknown", "later_model"]

# the window's lines name a session only by what the row set, never by a
# sentinel id
expect Render.viz_focus_line({ present: Bool.True, live: Bool.True, view: 0, trace_day: "", trace_id: -1, age_seconds: 24 }) == "focus: live - view 0, 24s ago"
expect Render.viz_focus_line({ present: Bool.True, live: Bool.False, view: 2, trace_day: "2026-11-25", trace_id: 211, age_seconds: 95 }) == "focus: stale - view 2, trace 2026-11-25 (id 211), 95s ago"
expect Render.viz_focus_line({ present: Bool.False, live: Bool.False, view: -1, trace_day: "", trace_id: -1, age_seconds: -1 }) == "focus: none - the window is not open"
expect Render.tick_line({ id: 7, status: "applied", view: 2, range: -1, trace_day: "2026-11-25", trace_id: -1, ghost_day: "", ghost_id: -1 }) == "tick: request 7 applied (view 2, trace 2026-11-25)"
expect Render.tick_line({ id: 8, status: "superseded", view: -1, range: -1, trace_day: "", trace_id: -1, ghost_day: "", ghost_id: -1 }) == "tick: request 8 superseded"
expect Render.viz_head({ protocol: 1, published: "2026-11-26 19:45:05", staleness: 600, fstale: 90 }) == "window protocol 1, published 2026-11-26 19:45:05; a request expires after 600s, the focus after 90s"
