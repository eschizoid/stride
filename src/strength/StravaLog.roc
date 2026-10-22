import core.Units
import Adapter

StravaLog :: [].{
    # ── strava: the structured strength log ─────────────────────────────
    #
    #     { "activity_id": "20590139628",
    #       "exercise_sets": [
    #         { "exercise_name": "Lateral Raise", "muscle_groups": ["Shoulders"],
    #           "weight": { "value": "5.9 kg", "unit": "Volume" },
    #           "reps": { "value": "12", "unit": "Steps" } }, ... ] }
    #
    # Strava's app keeps a strength workout's exercises as structured data, but
    # its public API does not return them; Strava's MCP connector does
    # (`get_strength_workout_details`). stride cannot call the connector, so a
    # coach fetches the JSON and hands it to `stride strength import`, which
    # stores ONE workout object per activity in strength_logs, as the text the
    # connector wrote. This adapter reads that stored object.
    #
    # Each element of exercise_sets is ONE set. `weight`, `reps` and
    # `duration` are each absent when the athlete recorded none, and a JSON
    # null reads the same as absent. The `unit` labels are wrong upstream
    # ("Volume" on a mass, "Steps" on a count), so the unit is read from the
    # value string instead: "13.6 kg", or "lb"/"lbs" converted through
    # Units.lb_kg.
    #
    # A set becomes part of a row, or is LEFT OUT with a reason that `read`
    # returns beside the rows, so a caller can say what it did not store:
    #   no_exercise_name     the set names no exercise;
    #   no_reps              no rep count, timed (duration-only) sets
    #                        included: a row with no rep count has no tonnage
    #                        and no progression point, and inventing a count
    #                        would be a confident wrong number;
    #   bad_reps             a rep count that is not a positive whole number
    #                        ("8-10", "0");
    #   unknown_weight_unit  a weight whose value names no kg/lb/lbs unit
    #                        ("44 stone", a bare "20"): an unknown mass is not
    #                        a zero mass;
    #   bad_weight           a kg/lb weight whose number does not parse
    #                        ("20,5 kg") or is negative.
    # A set with no weight at all moves 0.0 kg: Strava stored no mass, and
    # the honest reading of "nothing recorded" is zero added load.
    #
    # A BODYWEIGHT exercise counts 0 kg, whatever weight the log carries,
    # and keeps its sets and reps. Strava's log can carry a weight on a
    # bodyweight move (the shipped sample's Push Up records 79.4 kg, the
    # athlete's own mass), and counting it would make a set of push-ups
    # outweigh the session's lifts; the mass a rep moves on top of the body
    # is what tonnage counts. A bodyweight exercise is one whose name is on
    # `bodyweight_names`, compared case-, space- and hyphen-blind with a
    # trailing plural ignored, so "Push-Ups" matches "push up" and "Weighted
    # Pull Up" matches nothing. A list rather than a comparison with the
    # athlete's mass, because stride stores no body weight to compare
    # against. The set's weight is never read, so an unreadable one does not
    # drop it. `read` returns each such set that carried a nonzero weight in
    # `zeroed`, so a caller can say what it did not count; the stored log
    # keeps the recorded weight, so changing the list needs no re-import.
    #
    # Consecutive kept sets of the same exercise at the same reps and weight
    # fold into one row whose `sets` is their count, and a change of reps or
    # weight starts a new row, the shape strength_sets stores for every
    # adapter.
    #
    # Every other weight is stored as Strava recorded it. Strava's log holds
    # the weight the athlete entered for the set, and this adapter does not
    # double it for dumbbells: the log does not say whether an entered weight
    # means one dumbbell or both, so the stored number is the entered one.
    #
    # Anything that is not such a workout object yields no rows, which is
    # what lets the description adapters below this one in the table speak.
    #
    # The decoder models only the fields stride reads; every other key,
    # whatever its shape, is ignored, so a surprising value in a field stride
    # does not read cannot fail a workout's decode.

    # a verbatim workout object from the connector, the fixture every adapter
    # ships with (Adapter's contract): three exercises, three identical sets
    # each, so the fold is what the expects below pin
    sample : Str
    sample =
        \\{"activity_id":"20590139628","exercise_sets":[{"exercise_name":"Neutral Grip Dumbbell Bench Press","muscle_groups":["Chest","Triceps","Shoulders"],"weight":{"value":"13.6 kg","unit":"Volume"},"reps":{"value":"8","unit":"Steps"}},{"exercise_name":"Neutral Grip Dumbbell Bench Press","muscle_groups":["Chest","Triceps","Shoulders"],"weight":{"value":"13.6 kg","unit":"Volume"},"reps":{"value":"8","unit":"Steps"}},{"exercise_name":"Neutral Grip Dumbbell Bench Press","muscle_groups":["Chest","Triceps","Shoulders"],"weight":{"value":"13.6 kg","unit":"Volume"},"reps":{"value":"8","unit":"Steps"}},{"exercise_name":"Push Up","muscle_groups":["Chest","Shoulders","Triceps"],"weight":{"value":"79.4 kg","unit":"Volume"},"reps":{"value":"8","unit":"Steps"}},{"exercise_name":"Push Up","muscle_groups":["Chest","Shoulders","Triceps"],"weight":{"value":"79.4 kg","unit":"Volume"},"reps":{"value":"8","unit":"Steps"}},{"exercise_name":"Push Up","muscle_groups":["Chest","Shoulders","Triceps"],"weight":{"value":"79.4 kg","unit":"Volume"},"reps":{"value":"8","unit":"Steps"}},{"exercise_name":"Lateral Raise","muscle_groups":["Shoulders"],"weight":{"value":"5.9 kg","unit":"Volume"},"reps":{"value":"12","unit":"Steps"}},{"exercise_name":"Lateral Raise","muscle_groups":["Shoulders"],"weight":{"value":"5.9 kg","unit":"Volume"},"reps":{"value":"12","unit":"Steps"}},{"exercise_name":"Lateral Raise","muscle_groups":["Shoulders"],"weight":{"value":"5.9 kg","unit":"Volume"},"reps":{"value":"12","unit":"Steps"}}]}

    # a quantity as the connector writes it: the value carries the unit
    Measure : { value : Str }

    LoggedSet : {
        exercise_name : Try(Str, [Missing]),
        weight : Try(Measure, [Missing]),
        reps : Try(Measure, [Missing]),
    }

    Body : { exercise_sets : List(LoggedSet) }

    # the connector writes activity_id as digits in a string; a bare number
    # is accepted too, so the id has two decoders and no other field does
    IdText : { activity_id : Try(Str, [Missing]) }
    IdNumber : { activity_id : Try(I64, [Missing]) }

    # one decoded workout; activity_id is "" when the object carries none
    Workout : { activity_id : Str, exercise_sets : List(LoggedSet) }

    # a set left out of the rows: its 1-based position in exercise_sets, its
    # exercise name ("" when it had none), and the reason
    Dropped : { set : I64, exercise : Str, reason : Str }

    # a bodyweight set kept at 0 kg although the log recorded a weight: its
    # 1-based position, its exercise name, and the weight as written
    Zeroed : { set : I64, exercise : Str, recorded : Str }

    parse : Str -> List(Adapter.SetRow)
    parse = |text|
        match decode_workout(text) {
            Ok(w) => read(w).rows
            Err(_) => []
        }

    decode_workout : Str -> Try(Workout, [Undecodable])
    decode_workout = |text| {
        clean = strip_nulls(Str.trim(text))
        body : Try(Body, _)
        body = Json.parse(clean)
        b = body.map_err(|_| Undecodable)?
        Ok({ activity_id: activity_id_of(text), exercise_sets: b.exercise_sets })
    }

    # the object's activity_id as text, whether written as a string or a
    # bare whole number; "" when absent, null, or neither. Readable even
    # when the rest of the workout does not decode, so a caller can say
    # WHICH workout it could not read.
    activity_id_of : Str -> Str
    activity_id_of = |text| {
        clean = strip_nulls(Str.trim(text))
        as_text : Try(IdText, _)
        as_text = Json.parse(clean)
        match as_text {
            Ok(r) => r.activity_id.ok_or("")
            Err(_) => {
                as_number : Try(IdNumber, _)
                as_number = Json.parse(clean)
                match as_number {
                    Ok(r) =>
                        match r.activity_id {
                            Ok(n) => n.to_str()
                            Err(_) => ""
                        }
                    Err(_) => ""
                }
            }
        }
    }

    # the rows a workout yields, every set it left out with the reason, and
    # every bodyweight set whose recorded weight it did not count
    read : Workout -> { rows : List(Adapter.SetRow), dropped : List(Dropped), zeroed : List(Zeroed) }
    read = |w|
        List.fold_with_index(w.exercise_sets, { rows: [], dropped: [], zeroed: [] }, |acc, s, i| {
                pos = i.to_i64_wrap() + 1
                match read_set(s) {
                    Ok(one) => {
                        recorded = Str.trim((s.weight.map_ok(|m| m.value)).ok_or(""))
                        counted_nothing =
                            match read_mass(recorded) {
                                Ok(kg) => kg <= 0.0
                                Err(_) => recorded == ""
                            }
                        zeroed =
                            if is_bodyweight(one.exercise) and !counted_nothing {
                                List.append(acc.zeroed, { set: pos, exercise: one.exercise, recorded })
                            } else {
                                acc.zeroed
                            }
                        { ..acc, rows: fold_in(acc.rows, one), zeroed }
                    }
                    Err(why) => {
                        entry = { set: pos, exercise: Str.trim(s.exercise_name.ok_or("")), reason: reason_code(why) }
                        { ..acc, dropped: List.append(acc.dropped, entry) }
                    }
                }
            })

    # exercises done against the body's own mass, written as the comparison
    # key `name_key` makes of a name
    bodyweight_names : List(Str)
    bodyweight_names = List.map([
        "push up", "pull up", "chin up", "dip", "plank", "side plank", "sit up",
        "crunch", "bicycle crunch", "burpee", "mountain climber", "jumping jack",
        "air squat", "bodyweight squat", "inverted row", "leg raise",
        "hanging leg raise", "flutter kick", "v up", "dead bug", "bird dog",
        "superman", "wall sit", "bear crawl", "inchworm", "handstand push up",
        "pike push up", "hollow hold",
    ], name_key)

    # a name with case, spaces, hyphens and every other non-alphanumeric
    # removed: "Push-Ups" and "push ups" are one key
    name_key : Str -> Str
    name_key = |name|
        Str.from_utf8(List.keep_if(Str.to_utf8(Str.with_ascii_lowercased(name)), |b| (b >= 97 and b <= 122) or (b >= 48 and b <= 57))).ok_or("")

    # on the list as written, or as a plural of a listed name ("dips",
    # "crunches")
    is_bodyweight : Str -> Bool
    is_bodyweight = |name| {
        k = name_key(name)
        on = |key| key != "" and List.contains(bodyweight_names, key)
        on(k)
            or (Str.ends_with(k, "s") and on(Str.from_utf8(List.drop_last(Str.to_utf8(k), 1)).ok_or("")))
            or (Str.ends_with(k, "es") and on(Str.from_utf8(List.drop_last(Str.to_utf8(k), 2)).ok_or("")))
    }

    reason_code : [NoExerciseName, NoReps, BadReps, UnknownWeightUnit, BadWeight] -> Str
    reason_code = |why|
        match why {
            NoExerciseName => "no_exercise_name"
            NoReps => "no_reps"
            BadReps => "bad_reps"
            UnknownWeightUnit => "unknown_weight_unit"
            BadWeight => "bad_weight"
        }

    # a set extends the last row when it repeats that row's exercise, reps
    # and weight, and opens a new row otherwise
    fold_in : List(Adapter.SetRow), { exercise : Str, reps : I64, weight_kg : F64 } -> List(Adapter.SetRow)
    fold_in = |acc, one| {
        fresh = List.append(acc, { exercise: one.exercise, sets: 1, reps: one.reps, weight_kg: one.weight_kg })
        match List.last(acc) {
            Ok(prev) =>
                if prev.exercise == one.exercise and prev.reps == one.reps and (prev.weight_kg - one.weight_kg).abs() < 0.000001 {
                    List.append(List.drop_last(acc, 1), { ..prev, sets: prev.sets + 1 })
                } else {
                    fresh
                }
            Err(_) => fresh
        }
    }

    read_set : LoggedSet -> Try({ exercise : Str, reps : I64, weight_kg : F64 }, [NoExerciseName, NoReps, BadReps, UnknownWeightUnit, BadWeight])
    read_set = |s| {
        exercise = Str.trim(s.exercise_name.ok_or(""))
        if exercise == "" {
            Err(NoExerciseName)
        } else {
            reps_m = s.reps.map_err(|_| NoReps)?
            reps = I64.from_str(Str.trim(reps_m.value)).map_err(|_| BadReps)?
            if reps <= 0 {
                Err(BadReps)
            } else {
                weight_kg =
                    if is_bodyweight(exercise) {
                        0.0
                    } else {
                        match s.weight {
                            Ok(m) => read_mass(m.value)?
                            Err(_) => 0.0
                        }
                    }
                Ok({ exercise, reps, weight_kg })
            }
        }
    }

    # "13.6 kg", "30 lbs", "30 lb", spacing optional and case ignored. "lbs"
    # is tested before "lb", which is its suffix.
    read_mass : Str -> Try(F64, [UnknownWeightUnit, BadWeight])
    read_mass = |value| {
        v = Str.with_ascii_lowercased(Str.trim(value))
        (unit, per_unit) =
            if Str.ends_with(v, "kg") {
                ("kg", 1.0)
            } else if Str.ends_with(v, "lbs") {
                ("lbs", Units.lb_kg)
            } else if Str.ends_with(v, "lb") {
                ("lb", Units.lb_kg)
            } else {
                ("", 0.0)
            }
        if unit == "" {
            Err(UnknownWeightUnit)
        } else {
            match Str.split_on(v, unit) {
                [num, ""] => {
                    n = F64.from_str(Str.trim(num)).map_err(|_| BadWeight)?
                    if n < 0.0 Err(BadWeight) else Ok(n * per_unit)
                }
                _ => Err(BadWeight)
            }
        }
    }

    # ── the connector's answer, split into one JSON text per workout ──────
    # The answer is a list of workout objects or one object on its own. Each
    # workout is decoded separately, so one malformed workout cannot cost the
    # others: the split reads only JSON's bracket and string structure, and
    # refuses (with what it found) only text that is not a list or an object
    # at all, or whose brackets or strings never close. Each element comes
    # back as the exact text the connector wrote, which is what
    # strength_logs stores.
    split_input : Str -> Try(List(Str), [NotJson(Str)])
    split_input = |text| {
        t = Str.trim(text)
        bytes = Str.to_utf8(t)
        first = List.first(bytes).ok_or(0)
        if List.is_empty(bytes) {
            Err(NotJson("is empty"))
        } else if first != 123 and first != 91 {
            Err(NotJson("starts with neither `{` (one workout) nor `[` (a list of them)"))
        } else {
            s = scan(bytes)
            if !(s.closed) {
                Err(NotJson("ends before its brackets or strings close"))
            } else if s.trailing {
                Err(NotJson("has text after its closing bracket"))
            } else if first == 123 {
                Ok([t])
            } else {
                bounds = List.concat([0], s.cuts)
                ends = List.append(s.cuts, s.end)
                pieces = List.map2(bounds, ends, |from, upto| {
                    Str.trim(Str.from_utf8(List.take_first(List.drop_first(bytes, from + 1), upto - from - 1)).ok_or(""))
                })
                match pieces {
                    [""] => Ok([])
                    _ => if List.any(pieces, |p| p == "") Err(NotJson("has an empty element in its list")) else Ok(pieces)
                }
            }
        }
    }

    # bracket depth outside strings; `cuts` are the commas directly inside
    # the outermost bracket, `end` the index of the bracket that closes it
    scan : List(U8) -> { depth : I64, in_str : Bool, esc : Bool, cuts : List(U64), end : U64, closed : Bool, trailing : Bool }
    scan = |bytes|
        List.fold_with_index(bytes, { depth: 0, in_str: False, esc: False, cuts: [], end: 0, closed: False, trailing: False }, |s, b, i|
            if s.closed {
                if is_ws(b) s else { ..s, trailing: True }
            } else if s.in_str {
                if s.esc {
                    { ..s, esc: False }
                } else if b == 92 {
                    { ..s, esc: True }
                } else if b == 34 {
                    { ..s, in_str: False }
                } else {
                    s
                }
            } else if b == 34 {
                { ..s, in_str: True }
            } else if b == 123 or b == 91 {
                { ..s, depth: s.depth + 1 }
            } else if b == 125 or b == 93 {
                if s.depth <= 1 { ..s, depth: 0, closed: True, end: i } else { ..s, depth: s.depth - 1 }
            } else if b == 44 and s.depth == 1 {
                { ..s, cuts: List.append(s.cuts, i) }
            } else {
                s
            })

    # every JSON null removed along with its key (in an object) or its slot
    # (in a list), so a null field decodes exactly as an absent one. Reads
    # the structure only; text inside strings is never touched.
    strip_nulls : Str -> Str
    strip_nulls = |text| {
        bytes = Str.to_utf8(text)
        done = List.fold_with_index(bytes, { out: [], in_str: False, esc: False, skip: 0, drop_comma: False }, |s, b, i|
            if s.skip > 0 {
                { ..s, skip: s.skip - 1 }
            } else if s.in_str {
                out = List.append(s.out, b)
                if s.esc {
                    { ..s, out, esc: False }
                } else if b == 92 {
                    { ..s, out, esc: True }
                } else if b == 34 {
                    { ..s, out, in_str: False }
                } else {
                    { ..s, out }
                }
            } else if b == 34 {
                { ..s, out: List.append(s.out, b), in_str: True, drop_comma: False }
            } else if b == 110 and is_null_at(bytes, i) {
                cut = drop_member(s.out)
                { ..s, out: cut.out, drop_comma: cut.drop_comma, skip: 3 }
            } else if b == 44 and s.drop_comma {
                { ..s, drop_comma: False }
            } else if is_ws(b) {
                { ..s, out: List.append(s.out, b) }
            } else {
                { ..s, out: List.append(s.out, b), drop_comma: False }
            })
        Str.from_utf8(done.out).ok_or(text)
    }

    is_ws : U8 -> Bool
    is_ws = |b| b == 32 or b == 9 or b == 10 or b == 13

    # `null` as a whole token at i: the four letters, then no letter or digit
    is_null_at : List(U8), U64 -> Bool
    is_null_at = |bytes, i| {
        at = |k| List.get(bytes, i + k).ok_or(0)
        next = at(4)
        word_char = (next >= 97 and next <= 122) or (next >= 65 and next <= 90) or (next >= 48 and next <= 57) or next == 95
        at(1) == 117 and at(2) == 108 and at(3) == 108 and !word_char
    }

    # remove what precedes a null: `"key":` in an object, nothing extra in a
    # list, then the comma before it — or, when it was the first member,
    # flag the comma after it for removal instead
    drop_member : List(U8) -> { out : List(U8), drop_comma : Bool }
    drop_member = |out| {
        trimmed = trim_ws_end(out)
        rest =
            if List.last(trimmed).ok_or(0) == 58 {
                before_colon = trim_ws_end(List.drop_last(trimmed, 1))
                trim_ws_end(List.take_first(before_colon, opening_quote(before_colon, List.len(before_colon) - 1)))
            } else {
                trimmed
            }
        if List.last(rest).ok_or(0) == 44 {
            { out: List.drop_last(rest, 1), drop_comma: False }
        } else {
            { out: rest, drop_comma: True }
        }
    }

    trim_ws_end : List(U8) -> List(U8)
    trim_ws_end = |bs|
        if is_ws(List.last(bs).ok_or(0)) trim_ws_end(List.drop_last(bs, 1)) else bs

    # the index of the quote opening the string whose closing quote is at
    # `close`; a quote preceded by a backslash is inside the string
    opening_quote : List(U8), U64 -> U64
    opening_quote = |bs, close|
        if close == 0 {
            0
        } else {
            j = close - 1
            if List.get(bs, j).ok_or(0) == 34 and (j == 0 or List.get(bs, j - 1).ok_or(0) != 92) {
                j
            } else {
                opening_quote(bs, j)
            }
        }
}

# the shipped sample folds nine sets into three rows, one per exercise: each
# lift at its entered weight, the Push Up at 0 kg as bodyweight
expect {
    rows = StravaLog.parse(StravaLog.sample)
    match rows {
        [a, b, c] =>
            a.exercise == "Neutral Grip Dumbbell Bench Press"
                and a.sets == 3
                and a.reps == 8
                and (a.weight_kg - 13.6).abs() < 0.0001
                and b.exercise == "Push Up"
                and b.sets == 3
                and b.reps == 8
                and b.weight_kg.abs() < 0.0001
                and c.exercise == "Lateral Raise"
                and c.sets == 3
                and c.reps == 12
                and (c.weight_kg - 5.9).abs() < 0.0001
        _ => False
    }
}

# a change of weight within one exercise starts a new row, and a later
# return to the first weight is a third row, not a merge into the first
expect {
    rows = StravaLog.parse("{\"exercise_sets\":[{\"exercise_name\":\"Curl\",\"weight\":{\"value\":\"10 kg\"},\"reps\":{\"value\":\"10\"}},{\"exercise_name\":\"Curl\",\"weight\":{\"value\":\"12 kg\"},\"reps\":{\"value\":\"10\"}},{\"exercise_name\":\"Curl\",\"weight\":{\"value\":\"10 kg\"},\"reps\":{\"value\":\"10\"}}]}")
    match rows {
        [a, b, c] => a.sets == 1 and b.sets == 1 and c.sets == 1 and (b.weight_kg - 12.0).abs() < 0.0001
        _ => False
    }
}

# pounds convert through the exact avoirdupois factor, "lb" and "lbs" alike
expect {
    rows = StravaLog.parse("{\"exercise_sets\":[{\"exercise_name\":\"Row\",\"weight\":{\"value\":\"30 lbs\",\"unit\":\"Volume\"},\"reps\":{\"value\":\"8\",\"unit\":\"Steps\"}},{\"exercise_name\":\"Press\",\"weight\":{\"value\":\"25 lb\"},\"reps\":{\"value\":\"8\"}}]}")
    match rows {
        [a, b] => (a.weight_kg - 13.6077711).abs() < 0.0001 and (b.weight_kg - 11.33980925).abs() < 0.0001
        _ => False
    }
}

# a set without reps is left out; a set without weight is 0.0 kg
expect {
    rows = StravaLog.parse("{\"exercise_sets\":[{\"exercise_name\":\"Plank\",\"weight\":{\"value\":\"0 kg\"}},{\"exercise_name\":\"Push Up\",\"reps\":{\"value\":\"15\"}}]}")
    match rows {
        [a] => a.exercise == "Push Up" and a.sets == 1 and a.reps == 15 and a.weight_kg.abs() < 0.0001
        _ => False
    }
}

# every left-out set is named with its position and reason, and the kept
# set still becomes a row
expect {
    text = "{\"activity_id\":\"9\",\"exercise_sets\":[{\"exercise_name\":\"Curl\",\"weight\":{\"value\":\"20 kg\"},\"reps\":{\"value\":\"10\"}},{\"exercise_name\":\"Curl\",\"weight\":{\"value\":\"44 stone\"},\"reps\":{\"value\":\"10\"}},{\"exercise_name\":\"Plank\",\"duration\":{\"value\":60,\"unit\":\"Seconds\"}},{\"exercise_name\":\"Curl\",\"reps\":{\"value\":\"8-10\"}},{\"exercise_name\":\"Curl\",\"reps\":{\"value\":\"0\"}},{\"exercise_name\":\" \",\"reps\":{\"value\":\"5\"}},{\"exercise_name\":\"Curl\",\"weight\":{\"value\":\"20,5 kg\"},\"reps\":{\"value\":\"5\"}},{\"exercise_name\":\"Curl\",\"weight\":{\"value\":\"-5 kg\"},\"reps\":{\"value\":\"5\"}},{\"exercise_name\":\"Curl\",\"weight\":{\"value\":\"20\"},\"reps\":{\"value\":\"5\"}}]}"
    match StravaLog.decode_workout(text) {
        Ok(w) => {
            r = StravaLog.read(w)
            got = List.map(r.dropped, |d| "${d.set.to_str()}:${d.exercise}:${d.reason}")
            List.len(r.rows) == 1
                and got == ["2:Curl:unknown_weight_unit", "3:Plank:no_reps", "4:Curl:bad_reps", "5:Curl:bad_reps", "6::no_exercise_name", "7:Curl:bad_weight", "8:Curl:bad_weight", "9:Curl:unknown_weight_unit"]
        }
        Err(_) => False
    }
}

# a JSON null reads as absent: a null weight is 0.0 kg, a null reps leaves
# the set out, and a null inside a list or as a first member is dropped too
expect {
    rows = StravaLog.parse("{\"activity_id\":null,\"exercise_sets\":[{\"weight\":null,\"exercise_name\":\"Push Up\",\"reps\":{\"value\":\"12\"},\"muscle_groups\":[null,\"Chest\",null]},{\"exercise_name\":\"Plank\",\"reps\":null,\"duration\":null}]}")
    match rows {
        [a] => a.exercise == "Push Up" and a.reps == 12 and a.weight_kg.abs() < 0.0001
        _ => False
    }
}
expect StravaLog.strip_nulls("{\"a\" : null , \"b\":\"null\",\"c\":[1,null],\"d\":null}") == "{  \"b\":\"null\",\"c\":[1]}"

# the activity id reads as a string or a bare number, and as "" when absent
# or null; unreadable sets do not hide it
expect StravaLog.activity_id_of("{\"activity_id\":\"20590139628\",\"exercise_sets\":[]}") == "20590139628"
expect StravaLog.activity_id_of("{\"activity_id\":20590139628,\"exercise_sets\":[]}") == "20590139628"
expect StravaLog.activity_id_of("{\"activity_id\":null,\"exercise_sets\":[]}") == ""
expect StravaLog.activity_id_of("{\"activity_id\":\"7\",\"exercise_sets\":\"oops\"}") == "7"
expect
    match StravaLog.decode_workout("{\"activity_id\":7,\"exercise_sets\":[{\"exercise_name\":\"Curl\",\"reps\":{\"value\":\"3\"}}]}") {
        Ok(w) => w.activity_id == "7" and List.len(StravaLog.read(w).rows) == 1
        Err(_) => False
    }

# not this adapter's input: non-JSON, a Peloton share summary, a workout with
# no sets, and a LIST of workouts (the import form, not a stored payload)
expect List.is_empty(StravaLog.parse("not json at all"))
expect List.is_empty(StravaLog.parse("Block 1\nDumbbell Crush Press\n3 × 8 • 30 lbs/side"))
expect List.is_empty(StravaLog.parse("{\"activity_id\":\"20575593919\",\"exercise_sets\":[]}"))
expect List.is_empty(StravaLog.parse("[${StravaLog.sample}]"))

# the split hands back each workout's own text, untouched, whatever is
# wrong inside one of them
expect
    match StravaLog.split_input(" [ ${StravaLog.sample} , 42, {\"activity_id\":\"2\",\"exercise_sets\":[\"a,b]\"]} ] \n") {
        Ok([a, b, c]) => a == StravaLog.sample and b == "42" and c == "{\"activity_id\":\"2\",\"exercise_sets\":[\"a,b]\"]}"
        _ => False
    }
expect
    match StravaLog.split_input(StravaLog.sample) {
        Ok([a]) => a == StravaLog.sample
        _ => False
    }
expect
    match StravaLog.split_input("[ ]") {
        Ok([]) => True
        _ => False
    }

# ...and refuses, saying what it found, only text that is not a list or an
# object, or whose structure never closes
expect
    match StravaLog.split_input("Curl\n3 × 12 • 15 lbs") {
        Err(NotJson(why)) => Str.contains(why, "starts with neither")
        _ => False
    }
expect
    match StravaLog.split_input("[{\"activity_id\":\"1\"") {
        Err(NotJson(why)) => Str.contains(why, "ends before")
        _ => False
    }
expect
    match StravaLog.split_input("[1] x") {
        Err(NotJson(why)) => Str.contains(why, "after its closing")
        _ => False
    }
expect
    match StravaLog.split_input("   ") {
        Err(NotJson(why)) => why == "is empty"
        _ => False
    }

# bodyweight: the sample's three Push Up sets keep their sets and reps at
# 0 kg, and each is reported with the weight the log recorded
expect
    match StravaLog.decode_workout(StravaLog.sample) {
        Ok(w) => {
            r = StravaLog.read(w)
            List.map(r.zeroed, |z| "${z.set.to_str()}:${z.exercise}:${z.recorded}") == ["4:Push Up:79.4 kg", "5:Push Up:79.4 kg", "6:Push Up:79.4 kg"]
                and List.is_empty(r.dropped)
        }
        Err(_) => False
    }

# the match is blind to case, spacing, hyphens and a plural, and exact
# otherwise: a weighted variant and a lift that merely starts alike keep
# their weight
expect
    List.map(["Push-Ups", "pull up", "DIPS", "Crunches", "Burpees", "Chin Up"], StravaLog.is_bodyweight) == [True, True, True, True, True, True]
expect
    List.map(["Weighted Pull Up", "Push Press", "Dumbbell Bench Press", "Plankton", ""], StravaLog.is_bodyweight) == [False, False, False, False, False]

# a bodyweight set's weight is never read: an unreadable one does not drop
# the set, a recorded zero or no weight is not reported as zeroed, and a
# weighted variant keeps its load
expect {
    text = "{\"exercise_sets\":[{\"exercise_name\":\"Pull Up\",\"weight\":{\"value\":\"44 stone\"},\"reps\":{\"value\":\"6\"}},{\"exercise_name\":\"Dips\",\"weight\":{\"value\":\"0 kg\"},\"reps\":{\"value\":\"10\"}},{\"exercise_name\":\"Plank\",\"reps\":{\"value\":\"1\"}},{\"exercise_name\":\"Weighted Pull Up\",\"weight\":{\"value\":\"10 kg\"},\"reps\":{\"value\":\"5\"}}]}"
    match StravaLog.decode_workout(text) {
        Ok(w) => {
            r = StravaLog.read(w)
            got = List.map(r.rows, |row| "${row.exercise}:${row.reps.to_str()}:${(row.weight_kg * 10.0).round_to_i64_try().ok_or(-1).to_str()}")
            got == ["Pull Up:6:0", "Dips:10:0", "Plank:1:0", "Weighted Pull Up:5:100"]
                and List.map(r.zeroed, |z| z.recorded) == ["44 stone"]
                and List.is_empty(r.dropped)
        }
        Err(_) => False
    }
}
