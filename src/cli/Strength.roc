import strength.Adapter
import strength.Peloton
import strength.StravaLog

Strength :: [].{
	# ── the strength-set adapter pack: the TABLE and its dispatcher ────────
	# The parsers live in the `src/strength` package, one module per source,
	# each keeping the contract stated in `strength.Adapter`. This module
	# holds the ordered table that registers them and the dispatcher that
	# asks each in turn; it knows no grammar of its own. Supporting another
	# athlete's app is one module there, its sample expect, and one row here.

	SetRow : Adapter.SetRow

	# what one text parses to: the rows, and the NAME of the adapter that
	# read them — stored per row (strength_sets.source) so a career of mixed
	# sources stays distinguishable, the load_coverage discipline applied to
	# sets. "" with no rows means no adapter recognized the text.
	Parsed : { source : Str, rows : List(SetRow) }

	# ORDERED, and the order IS the disambiguation rule: adapters are tried
	# top to bottom and the first to yield rows wins, so a narrower grammar
	# goes ABOVE a broader one, and a new adapter's author owns the check
	# that their format does not claim text an existing adapter already
	# reads. A Strava workout object is JSON, the narrower grammar, so it
	# sits above the Peloton share summary. `tools/adapter-fixtures.sh` pins
	# this order and holds every row to a module in the package (and every
	# module to a row), so a reorder or an unregistered parser is a
	# deliberate edit to the pin, never a silent one.
	adapters : List({ name : Str, parse : Str -> List(SetRow) })
	adapters = [{ name: "strava", parse: StravaLog.parse }, { name: "peloton", parse: Peloton.parse }]

	parse : Str -> Parsed
	parse = |text| first_recognized(adapters, text)

	first_recognized : List({ name : Str, parse : Str -> List(SetRow) }), Str -> Parsed
	first_recognized = |ads, text|
		match ads {
			[] => { source: "", rows: [] }
			[a, .. as rest] => {
				# parenthesized: `a.parse(text)` is method-call syntax for `parse(a, text)`
				# in this compiler
				rows = (a.parse)(text)
				if (List.is_empty(rows)) first_recognized(rest, text) else { source: a.name, rows }
			}
		}

	# ── one weight convention across sources ──────────────────────────
	# Rows are stored per hand (Adapter's convention). A Strava log holds
	# what the athlete typed, which is per hand unless they say otherwise
	# with config `strength_log_weight` (Config.log_weight_values): `per_hand`
	# (the default, and any unset or unrecognised value) stores logged
	# weights as entered. `total` means they typed a pair's combined weight,
	# and a logged row is halved unless it is a one-piece lift:
	#   - a name saying a pair (`pair_words`: dumbbell, double kettlebell)
	#     is halved;
	#   - otherwise a name saying a one-piece implement (`whole_implements`)
	#     or a lift done with one (`whole_lifts`: deadlift, squat, leg press,
	#     pulldown, hip thrust) is kept whole;
	#   - any other name (Curl, Lateral Raise) is a pair move and is halved.
	# Only the `strava` source is touched: a description paste says /side itself.
	pair_words : List(Str)
	pair_words = ["dumbbell", "double kettlebell"]

	whole_implements : List(Str)
	whole_implements = ["barbell", "machine", "cable", "smith", "ez bar", "ez-bar", "trap bar", "landmine", "sled", "plate", "kettlebell"]

	whole_lifts : List(Str)
	whole_lifts = ["deadlift", "squat", "leg press", "pulldown", "pull down", "hip thrust"]

	per_hand : Str, Str, List(SetRow) -> List(SetRow)
	per_hand = |convention, source, rows|
		if convention != "total" or source != "strava" {
			rows
		} else {
			List.map(rows, |r| if (logged_whole(r.exercise)) r else { ..r, weight_kg: r.weight_kg / 2.0 })
		}

	# a logged exercise whose entered weight is the one implement it moves
	logged_whole : Str -> Bool
	logged_whole = |exercise| {
		name = Str.with_ascii_lowercased(exercise)
		names = |words| List.any(words, |w| Str.contains(name, w))
		if (names(pair_words)) Bool.False else names(whole_implements) or names(whole_lifts)
	}

	tonnage_kg : List(SetRow) -> F64
	tonnage_kg = |rows|
		List.fold(rows, 0.0, |acc, r| acc + (r.sets).to_f64() * (r.reps).to_f64() * r.weight_kg)
}

# tonnage is the product sum on per-hand weights: 3×8×13.6077… + 3×16×11.3398… = 870.90…
expect {
	p = Strength.parse("A\n3 × 8 • 30 lbs/side\nB\n3 × 8 reps/side • 25 lbs/side")
	(Strength.tonnage_kg(p.rows) - 870.8973504).abs() < 0.01
}

# one convention across sources: 25 lb dumbbells read 11.34 kg from a /side
# paste and from a per-hand log alike
expect {
	paste = Strength.parse("Dumbbell Hammer Curl\n3 × 10 • 25 lbs/side")
	match paste.rows {
		[r] => (r.weight_kg - 11.33980925).abs() < 0.001
		_ => False
	}
}

# `total` halves a logged dumbbell weight, leaves whole implements and
# per_hand alone, and never touches a paste
expect {
	rows = [{ exercise: "Curl", sets: 3, reps: 10, hold_s: 0, weight_kg: 22.68 }, { exercise: "Incline Barbell Bench Press", sets: 3, reps: 8, hold_s: 0, weight_kg: 54.4 }]
	halved = Strength.per_hand("total", "strava", rows)
	match halved {
		[a, b] => (a.weight_kg - 11.34).abs() < 0.001 and (b.weight_kg - 54.4).abs() < 0.001
		_ => False
	}
		and Strength.per_hand("per_hand", "strava", rows) == rows
		and Strength.per_hand("total", "peloton", rows) == rows
		and Strength.per_hand("", "strava", rows) == rows
}
# under `total`, a one-piece lift keeps its weight whatever its name leaves
# out, and a pair is halved even on a kettlebell
expect Strength.logged_whole("Deadlift") and Strength.logged_whole("Back Squat") and Strength.logged_whole("Leg Press") and Strength.logged_whole("Lat Pulldown") and Strength.logged_whole("Hip Thrust")
expect !(Strength.logged_whole("Double Kettlebell Front Squat")) and !(Strength.logged_whole("Dumbbell Bench Press")) and !(Strength.logged_whole("Lateral Raise"))

# a hold adds no tonnage: its seconds are never read as reps
expect {
	p = Strength.parse("Weighted Plank\n3 × 60 sec • 20 lbs\nCurl\n3 × 10 • 10 kg")
	List.len(p.rows) == 2 and (Strength.tonnage_kg(p.rows) - 300.0).abs() < 0.001
}

# the dispatcher: the first adapter to yield rows names the provenance, and
# unrecognized text is "" with no rows — the honest-gap contract at the pack
# level, not just per adapter. A share summary falls past the strava adapter
# to peloton; a workout object stops at strava.
expect {
	p = Strength.parse("A\n3 × 8 • 30 lbs")
	p.source == "peloton" and List.len(p.rows) == 1
}
expect {
	p = Strength.parse(StravaLog.sample)
	p.source == "strava" and List.len(p.rows) == 3
}
expect {
	p = Strength.parse("a ride description no adapter recognizes")
	p.source == "" and List.is_empty(p.rows)
}
