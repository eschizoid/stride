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
    # stores ONE workout object per activity in strength_logs. This adapter
    # reads that stored object.
    #
    # Each element of exercise_sets is ONE set. `weight` and `reps` are each
    # absent when the athlete recorded none. The `unit` labels are wrong
    # upstream ("Volume" on a mass, "Steps" on a count), so the unit is read
    # from the value string instead: "13.6 kg", or "lb"/"lbs" converted
    # through Units.lb_kg.
    #
    # Rules, each a property a row keeps:
    #   - a set without reps is skipped: a row with no rep count has no
    #     tonnage and no progression point, and inventing a count would be a
    #     confident wrong number;
    #   - a set without weight moves 0.0 kg: Strava stored no mass, and the
    #     honest reading of "nothing recorded" is zero added load;
    #   - a weight whose value names no recognised unit, or a negative one,
    #     skips the set, because an unknown mass is not a zero mass;
    #   - consecutive sets of the same exercise at the same reps and weight
    #     fold into one row whose `sets` is their count, and a change of reps
    #     or weight starts a new row, the shape strength_sets stores for every
    #     adapter.
    #
    # The weight is stored as Strava recorded it. Strava's log holds the
    # weight the athlete entered for the set, and this adapter does not
    # double it for dumbbells: the log does not say whether an entered weight
    # means one dumbbell or both, so the stored number is the entered one.
    #
    # Anything that is not such a workout object yields no rows, which is
    # what lets the description adapters below this one in the table speak.
    #
    # The decoder models the fields stride reads, plus muscle_groups, whose
    # shape the connector sample shows. Other keys (duration among them) are
    # ignored on decode and absent from a re-encoded payload: modelling a key
    # whose shape no sample shows would let one surprising value fail the
    # whole workout's decode.

    # a verbatim workout object from the connector, the fixture every adapter
    # ships with (Adapter's contract): three exercises, three identical sets
    # each, so the fold is what the expects below pin
    sample : Str
    sample =
        \\{"activity_id":"20590139628","exercise_sets":[{"exercise_name":"Neutral Grip Dumbbell Bench Press","muscle_groups":["Chest","Triceps","Shoulders"],"weight":{"value":"13.6 kg","unit":"Volume"},"reps":{"value":"8","unit":"Steps"}},{"exercise_name":"Neutral Grip Dumbbell Bench Press","muscle_groups":["Chest","Triceps","Shoulders"],"weight":{"value":"13.6 kg","unit":"Volume"},"reps":{"value":"8","unit":"Steps"}},{"exercise_name":"Neutral Grip Dumbbell Bench Press","muscle_groups":["Chest","Triceps","Shoulders"],"weight":{"value":"13.6 kg","unit":"Volume"},"reps":{"value":"8","unit":"Steps"}},{"exercise_name":"Push Up","muscle_groups":["Chest","Shoulders","Triceps"],"weight":{"value":"79.4 kg","unit":"Volume"},"reps":{"value":"8","unit":"Steps"}},{"exercise_name":"Push Up","muscle_groups":["Chest","Shoulders","Triceps"],"weight":{"value":"79.4 kg","unit":"Volume"},"reps":{"value":"8","unit":"Steps"}},{"exercise_name":"Push Up","muscle_groups":["Chest","Shoulders","Triceps"],"weight":{"value":"79.4 kg","unit":"Volume"},"reps":{"value":"8","unit":"Steps"}},{"exercise_name":"Lateral Raise","muscle_groups":["Shoulders"],"weight":{"value":"5.9 kg","unit":"Volume"},"reps":{"value":"12","unit":"Steps"}},{"exercise_name":"Lateral Raise","muscle_groups":["Shoulders"],"weight":{"value":"5.9 kg","unit":"Volume"},"reps":{"value":"12","unit":"Steps"}},{"exercise_name":"Lateral Raise","muscle_groups":["Shoulders"],"weight":{"value":"5.9 kg","unit":"Volume"},"reps":{"value":"12","unit":"Steps"}}]}

    # a quantity as the connector writes it: the value carries the unit, and
    # `unit` is the mislabelled upstream field, kept only so a re-encoded
    # payload says what the connector said
    Measure : { value : Str, unit : Try(Str, [Missing]) }

    LoggedSet : {
        exercise_name : Try(Str, [Missing]),
        muscle_groups : Try(List(Str), [Missing]),
        weight : Try(Measure, [Missing]),
        reps : Try(Measure, [Missing]),
    }

    # one workout object. `activity_id` is digits in a string upstream; the
    # adapter ignores it (the row's activity is the strength_logs key), and
    # `stride strength import` reads it to route the workout.
    Workout : { activity_id : Try(Str, [Missing]), exercise_sets : List(LoggedSet) }

    parse : Str -> List(Adapter.SetRow)
    parse = |text|
        match decode_workout(text) {
            Ok(w) => rows(w)
            Err(_) => []
        }

    decode_workout : Str -> Try(Workout, [NotAWorkout])
    decode_workout = |text| {
        decoded : Try(Workout, _)
        decoded = Json.parse(Str.trim(text))
        decoded.map_err(|_| NotAWorkout)
    }

    # what the connector hands over: a list of workout objects, or one
    # workout object on its own
    decode_import : Str -> Try(List(Workout), [NotWorkouts])
    decode_import = |text| {
        listed : Try(List(Workout), _)
        listed = Json.parse(Str.trim(text))
        match listed {
            Ok(ws) => Ok(ws)
            Err(_) =>
                match decode_workout(text) {
                    Ok(w) => Ok([w])
                    Err(_) => Err(NotWorkouts)
                }
        }
    }

    # one workout back to JSON text, the form strength_logs stores
    encode : Workout -> Str
    encode = |w| Json.to_str(w)

    rows : Workout -> List(Adapter.SetRow)
    rows = |w|
        List.fold(w.exercise_sets, [], |acc, s|
            match read_set(s) {
                Ok(one) => fold_in(acc, one)
                Err(_) => acc
            })

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

    read_set : LoggedSet -> Try({ exercise : Str, reps : I64, weight_kg : F64 }, [Unreadable])
    read_set = |s| {
        exercise = Str.trim(s.exercise_name.map_err(|_| Unreadable)?)
        reps_m = s.reps.map_err(|_| Unreadable)?
        reps = I64.from_str(Str.trim(reps_m.value)).map_err(|_| Unreadable)?
        weight_kg =
            match s.weight {
                Ok(m) => read_mass(m.value)?
                Err(_) => 0.0
            }
        if exercise == "" or reps <= 0 {
            Err(Unreadable)
        } else {
            Ok({ exercise, reps, weight_kg })
        }
    }

    # "13.6 kg", "30 lbs", "30 lb", spacing optional and case ignored. "lbs"
    # is tested before "lb", which is its suffix.
    read_mass : Str -> Try(F64, [Unreadable])
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
            Err(Unreadable)
        } else {
            match Str.split_on(v, unit) {
                [num, ""] => {
                    n = F64.from_str(Str.trim(num)).map_err(|_| Unreadable)?
                    if n < 0.0 Err(Unreadable) else Ok(n * per_unit)
                }
                _ => Err(Unreadable)
            }
        }
    }
}

# the shipped sample folds nine sets into three rows, one per exercise, each
# weight stored as entered
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
                and (b.weight_kg - 79.4).abs() < 0.0001
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

# a set without reps is skipped; a set without weight is 0.0 kg
expect {
    rows = StravaLog.parse("{\"exercise_sets\":[{\"exercise_name\":\"Plank\",\"weight\":{\"value\":\"0 kg\"}},{\"exercise_name\":\"Push Up\",\"reps\":{\"value\":\"15\"}}]}")
    match rows {
        [a] => a.exercise == "Push Up" and a.sets == 1 and a.reps == 15 and a.weight_kg.abs() < 0.0001
        _ => False
    }
}

# a weight with no recognised unit skips its set rather than storing a guess
expect List.is_empty(StravaLog.parse("{\"exercise_sets\":[{\"exercise_name\":\"Curl\",\"weight\":{\"value\":\"15 stone\"},\"reps\":{\"value\":\"12\"}}]}"))

# activity_id is ignored by the parse, present or not
expect List.len(StravaLog.parse("{\"activity_id\":\"1\",\"exercise_sets\":[{\"exercise_name\":\"Curl\",\"reps\":{\"value\":\"12\"}}]}")) == 1

# not this adapter's input: non-JSON, a Peloton share summary, a workout with
# no sets, and a LIST of workouts (the import form, not a stored payload)
expect List.is_empty(StravaLog.parse("not json at all"))
expect List.is_empty(StravaLog.parse("Block 1\nDumbbell Crush Press\n3 × 8 • 30 lbs/side"))
expect List.is_empty(StravaLog.parse("{\"activity_id\":\"20575593919\",\"exercise_sets\":[]}"))
expect List.is_empty(StravaLog.parse("[${StravaLog.sample}]"))

# the import form accepts a list and a lone workout, and refuses anything else
expect
    match StravaLog.decode_import("[${StravaLog.sample}, {\"activity_id\":\"2\",\"exercise_sets\":[]}]") {
        Ok([a, b]) => a.activity_id.ok_or("") == "20590139628" and List.len(a.exercise_sets) == 9 and List.is_empty(b.exercise_sets)
        _ => False
    }
expect
    match StravaLog.decode_import(StravaLog.sample) {
        Ok([a]) => List.len(a.exercise_sets) == 9
        _ => False
    }
expect
    match StravaLog.decode_import("Curl\n3 × 12 • 15 lbs") {
        Err(NotWorkouts) => True
        _ => False
    }

# a re-encoded workout parses back to the same rows, activity_id included
expect
    match StravaLog.decode_workout(StravaLog.sample) {
        Ok(w) => {
            again = StravaLog.encode(w)
            List.len(StravaLog.parse(again)) == 3
                and Str.contains(again, "\"activity_id\":\"20590139628\"")
                and Str.contains(again, "\"muscle_groups\":[\"Chest\",\"Triceps\",\"Shoulders\"]")
        }
        Err(_) => False
    }

# ...and an absent field stays absent rather than encoding a placeholder the
# decoder would then refuse
expect
    match StravaLog.decode_workout("{\"activity_id\":\"7\",\"exercise_sets\":[{\"exercise_name\":\"Push Up\",\"reps\":{\"value\":\"15\"}}]}") {
        Ok(w) => {
            again = StravaLog.encode(w)
            List.len(StravaLog.parse(again)) == 1 and !(Str.contains(again, "weight")) and !(Str.contains(again, "muscle_groups"))
        }
        Err(_) => False
    }
