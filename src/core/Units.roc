# stride-core: the athlete's unit preference, applied at the LAST moment.
#
# Storage and every computation stay SI (metres, m/s); these convert for human
# surfaces only. JSON payloads keep `distance_m` whatever the setting says -
# the envelope is the coaching agent's contract, and a display preference must
# not change what a tool reads (#349). Both binaries render these quantities,
# so the rule lives here: a second copy of a conversion constant is how two
# surfaces drift apart while each looks right alone.
import Fmt

Units :: [].{
    # The config row's value, resolved. Anything but the exact "imperial"
    # reads as Metric: `config set` already refuses other spellings, so an odd
    # value is a row written by something bypassing the CLI, and a display
    # preference must never be the reason a surface fails.
    units_of : Str -> [Metric, Imperial]
    units_of = |v| if v == "imperial" Imperial else Metric

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

    # A MASS for display, in the athlete's units: kilograms for Metric,
    # pounds for Imperial - the unit strength work is prescribed in there.
    # One decimal through Fmt.tenths, so every surface rounds the same way.
    mass_label : [Metric, Imperial], F64 -> Str
    mass_label = |units, kg|
        match units {
            Metric => "${Fmt.tenths((kg * 10.0).round_to_i64_try().ok_or(0))} kg"
            Imperial => "${Fmt.tenths((kg / lb_kg * 10.0).round_to_i64_try().ok_or(0))} lb"
        }

    expect mass_label(Metric, 27.2155422) == "27.2 kg"
    expect mass_label(Imperial, 27.2155422) == "60.0 lb"
    expect mass_label(Metric, 0.0) == "0.0 kg"
}
