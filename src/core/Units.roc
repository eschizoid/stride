# stride-core: the athlete's unit preference, applied at the LAST moment.
#
# Storage and every computation stay SI (metres, m/s); these convert for human
# surfaces only. JSON payloads keep `distance_m` whatever the setting says -
# the envelope is the coaching agent's contract, and a display preference must
# not change what a tool reads (#349). Both binaries render these quantities,
# so the rule lives here: a second copy of a conversion constant is how two
# surfaces drift apart while each looks right alone.
import Fmt
import Sports

Units :: [].{
	# The config row's value, resolved. Anything but the exact "imperial"
	# reads as Metric: `config set` already refuses other spellings, so an odd
	# value is a row written by something bypassing the CLI, and a display
	# preference must never be the reason a surface fails.
	units_of : Str -> [Metric, Imperial]
	units_of = |v| if (v == "imperial") Imperial else Metric

	expect units_of("imperial") == Imperial
	expect units_of("metric") == Metric
	expect units_of("") == Metric
	expect units_of("nonsense") == Metric

	# The distance one split covers: the kilometre, or the international
	# mile (1609.344 m, exact by definition) - the length a splits table
	# segments at, in the athlete's own culture.
	split_len : [Metric, Imperial] -> F64
	split_len = |units|
		match units {
			Metric => 1000.0
			Imperial => 1609.344
		}

	expect split_len(Metric) == 1000.0
	expect split_len(Imperial) == 1609.344

	# 1609.344 is the international mile in metres, exact by definition.
	dist_value : [Metric, Imperial], F64 -> F64
	dist_value = |units, m|
		match units {
			Metric => m / 1000.0
			Imperial => m / 1609.344
		}

	expect dist_value(Metric, 1609.344) == 1.609344
	expect dist_value(Imperial, 1609.344) == 1.0

	dist_unit : [Metric, Imperial] -> Str
	dist_unit = |units|
		match units {
			Metric => "km"
			Imperial => "mi"
		}

	pace_unit : [Metric, Imperial] -> Str
	pace_unit = |units|
		match units {
			Metric => "min/km"
			Imperial => "min/mi"
		}

	expect dist_unit(Imperial) == "mi" and pace_unit(Imperial) == "min/mi"
	expect dist_unit(Metric) == "km" and pace_unit(Metric) == "min/km"

	# 0.3048 is the international foot in metres, exact by definition.
	elev_value : [Metric, Imperial], F64 -> F64
	elev_value = |units, m|
		match units {
			Metric => m
			Imperial => m / 0.3048
		}

	elev_unit : [Metric, Imperial] -> Str
	elev_unit = |units|
		match units {
			Metric => "m"
			Imperial => "ft"
		}

	expect (elev_value(Imperial, 30.48) - 100.0).abs() < 0.001
	expect (elev_value(Metric, 30.48) - 30.48).abs() < 0.001
	expect elev_unit(Imperial) == "ft" and elev_unit(Metric) == "m"

	# m:ss per km or per mile from a distance and a duration. "-" when either
	# is missing: a pace computed from nothing would assert a speed nobody ran.
	pace_per_dist : [Metric, Imperial], F64, I64 -> Str
	pace_per_dist = |units, distance_m, moving_time|
		if distance_m <= 0.0 or moving_time <= 0 {
			"-"
		} else {
			total = (moving_time.to_f64() / dist_value(units, distance_m)).round_to_i64_try().ok_or(0)
			Fmt.mmss(total)
		}

	expect pace_per_dist(Metric, 1000.0, 300) == "5:00"
	expect pace_per_dist(Imperial, 1609.344, 480) == "8:00"
	expect pace_per_dist(Metric, 0.0, 300) == "-"
	expect pace_per_dist(Metric, 1000.0, 0) == "-"

	# A speed in m/s (SI, like every other distance in the engine), rendered as
	# time-per-distance, which is what a runner reads. #351: `m/s` was a raw
	# engine value leaking into a human screen - the defect was the QUANTITY,
	# not the unit, so converting it to mph would have preserved the wrong
	# presentation in a new unit.
	pace_from_speed : [Metric, Imperial], F64 -> Str
	pace_from_speed = |units, mps|
		if mps <= 0.0 {
			"-"
		} else {
			per = match units {
				Metric => 1000.0
				Imperial => 1609.344
			}
			Fmt.mmss((per / mps).round_to_i64_try().ok_or(0))
		}

	expect pace_from_speed(Metric, 2.5) == "6:40"
	expect pace_from_speed(Imperial, 2.2352) == "12:00"
	expect pace_from_speed(Metric, 0.0) == "-"

	# 0.45359237 is the international avoirdupois pound in kilograms, exact
	# by definition. Storage stays kg (strength_sets.weight_kg); this is the
	# display conversion, like every neighbour above.
	lb_kg : F64
	lb_kg = 0.45359237

	# Whether a value sits on the half-unit grid plates and dumbbells come
	# in (12.5, 20, 22.5). Weights logged in pounds are stored as their exact
	# kilogram conversion, so the grid holds to well within a hundredth.
	on_half : F64 -> Bool
	on_half = |v| {
		d = v * 2.0
		(d - (d.round_to_i64_try().ok_or(0)).to_f64()).abs() < 0.02
	}

	expect on_half(12.5) and on_half(30.0) and !(on_half(11.02)) and !(on_half(13.6))

	# The unit a lifting weight reads in. A set `units` config decides it.
	# Unset, the stored weights decide: a weight on the half-pound grid and
	# off the half-kilogram one was entered in pounds (25 lb is 11.34 kg),
	# and the reverse in kilograms. A weight on both grids, or on neither,
	# says nothing. The unit with more weights wins; a tie, or no evidence,
	# reads metric, the setting's own default. The config value arrives raw,
	# "" when the row is absent, so "unset" and "metric" stay two states.
	mass_units : Str, List(F64) -> [Metric, Imperial]
	mass_units = |config, kgs|
		if config != "" {
			units_of(config)
		} else {
			in_lb = |k| on_half(k / lb_kg) and !(on_half(k))
			in_kg = |k| on_half(k) and !(on_half(k / lb_kg))
			lb_n = List.len(List.keep_if(kgs, |k| k > 0.0 and in_lb(k)))
			kg_n = List.len(List.keep_if(kgs, |k| k > 0.0 and in_kg(k)))
			if (lb_n > kg_n) Imperial else Metric
		}

	expect mass_units("metric", [11.34, 22.68]) == Metric and mass_units("imperial", [10.0, 20.0]) == Imperial
	# a kilogram lifter on 5 and 10 kg: each is near a whole pound (11.02,
	# 22.05) but on the half-pound grid only by tolerance, never exactly
	expect mass_units("", [5.0, 10.0, 10.0, 5.0]) == Metric
	# a pound lifter on 25 and 45 lb plates, and 12.5 lb dumbbells
	expect mass_units("", [11.33980925, 20.41165665, 5.669904625]) == Imperial
	# mixed: the larger group wins, and a tie reads metric
	expect mass_units("", [11.33980925, 13.6077711, 10.0]) == Imperial and mass_units("", [11.33980925, 10.0]) == Metric
	# no evidence: no weights, or weights on neither grid
	expect mass_units("", []) == Metric and mass_units("", [13.3, 7.7]) == Metric

	# A lifting weight for display, with the precision it was entered at:
	# whole when whole and a half when half, so a 12.5 lb dumbbell reads
	# 12.5 lb and a 20 kg plate 20 kg; a weight off the unit's half grid
	# (one entered in the other unit) reads to one decimal.
	mass_label : [Metric, Imperial], F64 -> Str
	mass_label = |units, kg| {
		v = match units {
			Metric => kg
			Imperial => kg / lb_kg
		}
		unit = match units {
			Metric => "kg"
			Imperial => "lb"
		}
		halves = (v * 2.0).round_to_i64_try().ok_or(0)
		shown = if (!(on_half(v))) Fmt.tenths((v * 10.0).round_to_i64_try().ok_or(0)) else if (halves % 2 == 0) (halves // 2).to_str() else "${(halves // 2).to_str()}.5"
		"${shown} ${unit}"
	}

	expect mass_label(Imperial, 5.669904625) == "12.5 lb" and mass_label(Imperial, 13.6077711) == "30 lb"
	expect mass_label(Metric, 2.5) == "2.5 kg" and mass_label(Metric, 22.5) == "22.5 kg" and mass_label(Metric, 20.0) == "20 kg"
	expect mass_label(Metric, 27.2155422) == "27.2 kg" and mass_label(Imperial, 27.2155422) == "60 lb"
	expect mass_label(Metric, 13.6077711) == "13.6 kg" and mass_label(Imperial, 10.0) == "22.0 lb"

	# A month's lifted volume: kilograms under a tonne and tonnes to one
	# decimal above it, or pounds under a thousand and thousands of pounds
	# to one decimal above.
	tonnage_label : [Metric, Imperial], F64 -> Str
	tonnage_label = |units, kg| {
		v = match units {
			Metric => kg
			Imperial => kg / lb_kg
		}
		big = match units {
			Metric => " t"
			Imperial => "k lb"
		}
		small = match units {
			Metric => " kg"
			Imperial => " lb"
		}
		whole = v.round_to_i64_try().ok_or(0)
		if (whole < 1000) "${whole.to_str()}${small}" else "${Fmt.tenths((v / 100.0).round_to_i64_try().ok_or(0))}${big}"
	}

	expect tonnage_label(Metric, 18400.0) == "18.4 t" and tonnage_label(Imperial, 8346.0) == "18.4k lb"
	expect tonnage_label(Metric, 950.4) == "950 kg" and tonnage_label(Imperial, 300.0) == "661 lb"

	# Speed in km/h or mph from a distance and a duration, to one decimal;
	# "-" when either is missing.
	speed_per_hour : [Metric, Imperial], F64, I64 -> Str
	speed_per_hour = |units, distance_m, secs|
		if distance_m <= 0.0 or secs <= 0 {
			"-"
		} else {
			Fmt.tenths((dist_value(units, distance_m) * 36000.0 / secs.to_f64()).round_to_i64_try().ok_or(0))
		}

	speed_unit : [Metric, Imperial] -> Str
	speed_unit = |units|
		match units {
			Metric => "km/h"
			Imperial => "mph"
		}

	expect speed_per_hour(Metric, 1000.0, 162) == "22.2" and speed_per_hour(Imperial, 1609.344, 180) == "20.0"
	expect speed_per_hour(Metric, 0.0, 100) == "-" and speed_unit(Imperial) == "mph"

	# A split's rate as the sport reads it: a ride's speed, since cycling
	# speed follows the terrain and a rider never speaks of minutes per
	# kilometre, and every other sport's pace per kilometre or mile. The
	# column head names which one it is.
	split_rate : [Metric, Imperial], Str, F64, I64 -> Str
	split_rate = |units, sport, distance_m, secs|
		if (Sports.reads_speed(sport)) speed_per_hour(units, distance_m, secs) else pace_per_dist(units, distance_m, secs)

	split_rate_head : [Metric, Imperial], Str -> Str
	split_rate_head = |units, sport|
		if (Sports.reads_speed(sport)) "speed (${speed_unit(units)})" else "pace (${pace_unit(units)})"

	expect split_rate(Metric, "GravelRide", 1000.0, 162) == "22.2" and split_rate_head(Metric, "Ride") == "speed (km/h)"
	expect split_rate(Metric, "Run", 1000.0, 300) == "5:00" and split_rate_head(Imperial, "Run") == "pace (min/mi)"
	expect split_rate(Metric, "EBikeRide", 1000.0, 162) == "22.2" and split_rate_head(Metric, "EBikeRide") == "speed (km/h)"

	# Power zones, Coggan's 7-zone model, as watt ranges from an FTP. lo_w 0
	# opens Z1 at 0 W and hi_w 0 leaves Z7 open above. `stride zones` reads
	# this table through Metrics.power_zones.
	power_zones : F64 -> List({ z : Str, name : Str, lo_w : F64, hi_w : F64 })
	power_zones = |ftp|
		[
			{ z: "Z1", name: "recovery", lo_w: 0.0, hi_w: ftp * 0.55 },
			{ z: "Z2", name: "endurance", lo_w: ftp * 0.56, hi_w: ftp * 0.75 },
			{ z: "Z3", name: "tempo", lo_w: ftp * 0.76, hi_w: ftp * 0.90 },
			{ z: "Z4", name: "threshold", lo_w: ftp * 0.91, hi_w: ftp * 1.05 },
			{ z: "Z5", name: "VO2max", lo_w: ftp * 1.06, hi_w: ftp * 1.20 },
			{ z: "Z6", name: "anaerobic", lo_w: ftp * 1.21, hi_w: ftp * 1.50 },
			{ z: "Z7", name: "neuromuscular", lo_w: ftp * 1.51, hi_w: 0.0 },
		]

	expect List.len(power_zones(200.0)) == 7
}
