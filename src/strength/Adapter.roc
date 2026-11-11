Adapter :: [].{
	# ── the adapter contract: what every strength-set parser must keep ──
	# Strava's public API carries no per-exercise sets. What stride holds for
	# a strength session is TEXT from one of two places: the structured log
	# Strava's MCP connector returns, which a coach hands to `stride strength
	# import` and strength_logs stores as JSON, or the activity DESCRIPTION,
	# where the athlete pastes their strength app's share summary. Different
	# sources write different grammars, so parsing is an ADAPTER PACK: one
	# module per source in this package, each a pure function from that text
	# to set rows, registered in `src/cli/Strength.roc`'s `adapters` table
	# and tried in order; the first to yield rows names the row's
	# provenance. One text comes from ONE source, so first-non-empty is
	# format detection, not a merge.
	#
	# Every adapter keeps this contract: pure `Str -> List(SetRow)`; TOLERANT
	# (junk yields no rows, never an error, since the source is a human paste
	# or an upstream payload stride does not control); SILENT on formats it
	# does not recognize (the empty list is what lets the next adapter
	# speak); and it ships with a real sample of its source's text as a
	# top-level `sample : Str`, pinned by its own expects, which
	# `tools/adapter-fixtures.sh` requires.
	#
	# A SetRow's weight_kg is PER HAND: the weight of one implement, the way
	# an athlete enters it (one dumbbell of a pair, a kettlebell, a barbell's
	# or machine's total). Every source stores that same convention, so one
	# lift at one weight reads the same whichever source logged it. Per-side
	# bookkeeping changes the rep or hold count, never the weight, and
	# tonnage is sets × reps × weight_kg on that per-hand weight: training
	# volume, not the total mass both hands moved.
	#
	# Everything downstream (the notes drain, the strength_sets rebuild, the
	# tonnage view, the career spine) is format-blind: supporting another
	# athlete's app is one module here, its sample expect, and one row in
	# the table, with no sync, schema or viz change.

	# a row is what one exercise line prescribes: `sets` × `reps` at
	# `weight_kg` per rep, so tonnage is their product. A HOLD (an isometric
	# set: a weight held still for a time) is a row with 0 reps and its
	# held seconds in `hold_s`, so it adds no tonnage and a duration never
	# counts as reps; `hold_s` is 0 on every rep row.
	SetRow : { exercise : Str, sets : I64, reps : I64, hold_s : I64, weight_kg : F64 }

	# ── durations: how long a hold was held ─────────────────────────────
	# Numbers, whole or fractional, each followed by a unit, spaces
	# optional: "1m 0s", "45s", "1h 2m", "30 sec", "1.5 min". Units are
	# h/hr/hrs/hour/hours, m/min/mins/minute/minutes and s/sec/secs/second/
	# seconds, in any case. Rounded to whole seconds; a total that is not
	# positive, a number without a unit ("60"), an unknown unit or any
	# other character is Err, because an invented duration would be a
	# confident wrong number.
	read_seconds : Str -> Try(I64, [BadDuration])
	read_seconds = |text| {
		scanned = List.fold(
			Str.to_utf8(Str.with_ascii_lowercased(Str.trim(text))),
			{ runs: [], gap: False, bad: False },
			|s, b| {
				digit = (b >= 48 and b <= 57) or b == 46
				letter = b >= 97 and b <= 122
				if b == 32 or b == 9 {
					{ ..s, gap: True }
				} else if !digit and !letter {
					{ ..s, bad: True }
				} else {
					match List.last(s.runs) {
						Ok(prev) if prev.digits == digit and !(s.gap) => { ..s, runs: List.append(List.drop_last(s.runs, 1), { digits: digit, bytes: List.append(prev.bytes, b) }) }
						_ => { ..s, runs: List.append(s.runs, { digits: digit, bytes: [b] }), gap: False }
					}
				}
			},
		)
		if scanned.bad or List.is_empty(scanned.runs) {
			Err(BadDuration)
		} else {
			total = sum_durations(scanned.runs, 0.0)?
			secs = total.round_to_i64_try().map_err(|_| BadDuration)?
			if (secs <= 0) Err(BadDuration) else Ok(secs)
		}
	}

	# the runs a duration scans to, read as number-unit pairs and summed in
	# seconds
	sum_durations : List({ digits : Bool, bytes : List(U8) }), F64 -> Try(F64, [BadDuration])
	sum_durations = |runs, acc|
		match runs {
			[] => Ok(acc)
			[n, u, .. as rest] if n.digits and !(u.digits) => {
				v = F64.from_str(Str.from_utf8(n.bytes).ok_or("")).map_err(|_| BadDuration)?
				per = unit_seconds(Str.from_utf8(u.bytes).ok_or(""))?
				sum_durations(rest, acc + v * per)
			}
			_ => Err(BadDuration)
		}

	unit_seconds : Str -> Try(F64, [BadDuration])
	unit_seconds = |unit|
		match unit {
			"h" | "hr" | "hrs" | "hour" | "hours" => Ok(3600.0)
			"m" | "min" | "mins" | "minute" | "minutes" => Ok(60.0)
			"s" | "sec" | "secs" | "second" | "seconds" => Ok(1.0)
			_ => Err(BadDuration)
		}

	# ── bodyweight: a move done against the body's own mass adds no load ──
	# Every adapter counts a bodyweight exercise at 0 kg per rep and keeps
	# its sets and reps, whatever weight its source wrote. Strength apps
	# record the athlete's own mass on these moves, and counting it would
	# make a set of chin ups outweigh the session's lifts; tonnage counts the
	# mass a rep moves on top of the body. An exercise is bodyweight when its
	# name, compared by `name_key` with a trailing plural ignored, is on
	# `bodyweight_names`, either alone or after an "assisted" or "negative"
	# qualifier at the very front: an assisted rep lifts less than the body
	# and a negative is the lowering half of one, so neither adds load.
	# Nothing else is matched, so "Weighted Pull Up" keeps its weight, and so
	# do "Band Assisted Pull Up" and "Pull Up (Assisted)". A list rather than
	# a comparison with the athlete's mass, because stride stores no body
	# weight to compare against.
	is_bodyweight : Str -> Bool
	is_bodyweight = |name| {
		k = name_key(name)
		listed(k) or List.any(bodyweight_qualifiers, |q| Str.starts_with(k, q) and listed(drop_bytes(k, q)))
	}

	# exercises done against the body's own mass, written as the comparison
	# key `name_key` makes of a name
	bodyweight_names : List(Str)
	bodyweight_names = List.map(
		[
			"push up",
			"pull up",
			"chin up",
			"dip",
			"plank",
			"side plank",
			"sit up",
			"crunch",
			"bicycle crunch",
			"burpee",
			"mountain climber",
			"jumping jack",
			"air squat",
			"bodyweight squat",
			"inverted row",
			"leg raise",
			"hanging leg raise",
			"flutter kick",
			"v up",
			"dead bug",
			"bird dog",
			"superman",
			"wall sit",
			"bear crawl",
			"inchworm",
			"handstand push up",
			"pike push up",
			"hollow hold",
			"dumbbell push up",
			"single leg v up",
		],
		name_key,
	)

	# the qualifiers that leave a listed move bodyweight, as `name_key`
	# writes them
	bodyweight_qualifiers : List(Str)
	bodyweight_qualifiers = ["assisted", "negative"]

	# a name lowercased with every byte but an ASCII letter or digit
	# removed, non-ASCII letters included: "Push-Ups" and "push ups" are one
	# key
	name_key : Str -> Str
	name_key = |name|
		Str.from_utf8(List.keep_if(Str.to_utf8(Str.with_ascii_lowercased(name)), |b| (b >= 97 and b <= 122) or (b >= 48 and b <= 57))).ok_or("")

	# a key on the list as written, or as a plural of a listed name ("dips",
	# "crunches")
	listed : Str -> Bool
	listed = |k| {
		on = |key| List.contains(bodyweight_names, key)
		on(k)
			or (Str.ends_with(k, "s") and on(Str.from_utf8(List.drop_last(Str.to_utf8(k), 1)).ok_or("")))
			or (Str.ends_with(k, "es") and on(Str.from_utf8(List.drop_last(Str.to_utf8(k), 2)).ok_or("")))
	}

	# `k` without its leading `prefix`; the caller has checked it starts so
	drop_bytes : Str, Str -> Str
	drop_bytes = |k, prefix|
		Str.from_utf8(List.drop_first(Str.to_utf8(k), List.len(Str.to_utf8(prefix)))).ok_or("")
}

# the match is blind to case, spacing, hyphens and a plural, and exact
# otherwise: a weighted variant and a lift that merely starts alike keep
# their weight
expect
	List.map(["Push-Ups", "pull up", "DIPS", "Crunches", "Burpees", "Chin Up", "Dumbbell Push-Ups", "Single Leg V-Up"], Adapter.is_bodyweight) == [True, True, True, True, True, True, True, True]
expect
	List.map(["Weighted Pull Up", "Push Press", "Dumbbell Bench Press", "Plankton", "", "Dumbbell Pass Through to Push Up"], Adapter.is_bodyweight) == [False, False, False, False, False, False]

# an assisted or negative form of a listed move is bodyweight, plural
# included; the qualifier alone, a qualifier on an unlisted move, and a
# qualifier anywhere but the very front are not
expect
	List.map(["Assisted Chin-Up", "Assisted Pull Up", "Negative Pull Up", "assisted dips", "Negative Push-Ups", "Assisted Single Leg V-Up"], Adapter.is_bodyweight) == [True, True, True, True, True, True]
expect
	List.map(["Assisted", "Negative", "Assisted Bench Press", "Pull Up Negative", "Band Assisted Pull Up", "Pull Up (Assisted)"], Adapter.is_bodyweight) == [False, False, False, False, False, False]

# a duration reads as number-unit pairs in any spacing and case, summed and
# rounded to whole seconds
expect
	List.map(["1m 0s", "45s", "1h 2m", "30 sec", "1.5 min", "1M 30S", " 90 Seconds "], |t| Adapter.read_seconds(t).ok_or(-1)) == [60, 45, 3720, 30, 90, 90, 90]

# a number without a unit, an unknown unit, a stray character, two numbers
# in a row, a unit alone and a total that is not positive are refused
expect
	List.map(["60", "3 fortnights", "1:00", "1 2s", "min", "", "0s", "-5s", "1m 0"], |t| Adapter.read_seconds(t).is_err()) == [True, True, True, True, True, True, True, True, True]
