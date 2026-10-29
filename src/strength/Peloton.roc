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
    # between groups. Any line that is not a well-formed set line is skipped,
    # a set line with no preceding exercise name is skipped, and an empty or
    # absent description parses to no rows — a set-less strength session
    # counts for load and streak but not tonnage, an honest gap rather than
    # a failure.
    #
    # Side semantics decide what a rep MOVES, so tonnage is mass actually
    # lifted rather than a label sum. This is a reading of how the app
    # producing these pastes writes them — no published contract backs it, so
    # a share format that spells single-side work differently falsifies the
    # rule, not the parser:
    #   weight/side + reps/side  → single-side work (alternating): each rep
    #                              moves ONE side's mass, and the rep count
    #                              doubles (R per side).
    #   weight/side alone        → both hands loaded simultaneously: each rep
    #                              moves BOTH sides' mass (2 × W).
    #   neither                  → the stated numbers are already totals.
    # Units: lbs (Peloton's default) converted through Units.lb_kg; kg as-is.
    #
    # A bodyweight exercise (`Adapter.is_bodyweight`) keeps its sets and
    # reps at 0 kg when its set line names a weight, which can be the
    # athlete's own mass. A set line with no weight carries no bullet, so it
    # yields no row. A timed set line (`3 × 30 sec • 20 lbs`) yields no row
    # either: its R is a duration, and a duration times a weight is not
    # tonnage. A line that is only a set count (`S × R`, optionally followed
    # by one word from `count_units`, with or without a refused weight or a
    # timed one) is never an exercise name, so the name above it stays
    # current.
    #
    # Pure, expects below; the effectful skin (storing rows at analyze) lives
    # in Analyze.roc.

    # a verbatim share summary from the app, the fixture every adapter ships
    # with (Adapter's contract): two exercises, both /side variants
    sample : Str
    sample = "Block 1\nDumbbell Crush Press\n3 × 8 • 30 lbs/side\nDumbbell Snatch Push Press\n3 × 8 reps/side • 25 lbs/side"

    parse : Str -> List(Adapter.SetRow)
    parse = |text| {
        lines = List.map(Str.split_on(text, "\n"), |l| Str.trim(l))
        walk = List.fold(lines, { exercise: "", rows: [] }, |acc, line| {
            match parse_set_line(line) {
                Ok(s) =>
                    if acc.exercise == "" {
                        acc
                    } else {
                        { exercise: acc.exercise, rows: List.append(acc.rows, { exercise: acc.exercise, sets: s.sets, reps: s.reps, weight_kg: if Adapter.is_bodyweight(acc.exercise) 0.0 else s.weight_kg }) }
                    }
                Err(_) =>
                    if line == "" or Str.starts_with(line, "Block ") or is_set_shaped(line) {
                        # a blank line, a section header or a set count that is not a
                        # whole set line ends nothing — the next set line still belongs
                        # to the last named exercise, matching how the share format
                        # lays out supersets
                        acc
                    } else {
                        { ..acc, exercise: line }
                    }
            }
        })
        walk.rows
    }

    # the text before any bullet is exactly `S × R`, or `S × R` and one word
    # from `count_units` in any case, however many spaces separate the parts;
    # a name that merely starts that way ("5 x 5 Back Squat") is not
    is_set_shaped : Str -> Bool
    is_set_shaped = |line| {
        left = Str.trim(List.first(Str.split_on(line, " • ")).ok_or(line))
        bare =
            match List.keep_if(Str.split_on(left, " "), |t| t != "") {
                [_, _, _] => True
                [_, _, _, unit] => List.contains(count_units, Str.with_ascii_lowercased(unit))
                _ => False
            }
        match parse_sets_reps(left) {
            Ok(_) => bare
            Err(_) => False
        }
    }

    # the words a bare set count may name after its rep figure
    count_units : List(Str)
    count_units = List.concat(["reps", "reps/side"], time_units)

    # the words that make R a duration rather than a rep count
    time_units : List(Str)
    time_units = ["s", "sec", "secs", "seconds", "min", "mins", "minutes"]

    # one set line, or Err for anything else. The bullet is the discriminator:
    # no prose line in the share format carries ` • `.
    parse_set_line : Str -> Try({ sets : I64, reps : I64, weight_kg : F64 }, [NotASetLine])
    parse_set_line = |line|
        match Str.split_on(line, " • ") {
            [left, right] => {
                lr = parse_sets_reps(left)?
                # a held duration is not reps, and seconds × weight is not tonnage
                if lr.timed {
                    return Err(NotASetLine)
                }
                w = parse_weight(right)?
                # weight/side with per-side reps is single-side work: one side's
                # mass per rep, reps doubled. weight/side with total reps is both
                # hands at once: double the mass. Plain numbers are totals.
                weight_kg =
                    if w.per_side and !(lr.per_side) {
                        w.kg * 2.0
                    } else {
                        w.kg
                    }
                reps = if lr.per_side lr.reps * 2 else lr.reps
                Ok({ sets: lr.sets, reps, weight_kg })
            }
            _ => Err(NotASetLine)
        }

    # `3 × 8`, `3 × 8 reps`, `3 × 8 reps/side`, `3 × 30 sec` — ASCII `x`
    # tolerated, since a re-typed paste is one keyboard away from the
    # multiplication sign. `timed` says the word after R is one of
    # `time_units`, so R counts seconds or minutes, not reps.
    parse_sets_reps : Str -> Try({ sets : I64, reps : I64, per_side : Bool, timed : Bool }, [NotASetLine])
    parse_sets_reps = |left| {
        parts =
            match Str.split_on(left, " × ") {
                [a, b] => Ok((a, b))
                _ =>
                    match Str.split_on(left, " x ") {
                        [a, b] => Ok((a, b))
                        _ => Err(NotASetLine)
                    }
            }
        (sets_s, reps_part) = parts?
        sets = I64.from_str(Str.trim(sets_s)).map_err(|_| NotASetLine)?
        reps_tokens = Str.split_on(Str.trim(reps_part), " ")
        reps_tok = List.first(reps_tokens).map_err(|_| NotASetLine)?
        reps = I64.from_str(reps_tok).map_err(|_| NotASetLine)?
        if sets <= 0 or reps <= 0 {
            Err(NotASetLine)
        } else {
            timed =
                match List.keep_if(reps_tokens, |t| t != "") {
                    [_, unit, ..] => List.contains(time_units, Str.with_ascii_lowercased(unit))
                    _ => False
                }
            Ok({ sets, reps, per_side: Str.contains(reps_part, "/side"), timed })
        }
    }

    # `30 lbs/side`, `25 lbs`, `12.5 kg` — a right side with no recognised
    # unit, or a weight of zero or less, is not a set line
    parse_weight : Str -> Try({ kg : F64, per_side : Bool }, [NotASetLine])
    parse_weight = |right| {
        tokens = Str.split_on(Str.trim(right), " ")
        match tokens {
            [num_s, unit, ..] => {
                n = F64.from_str(num_s).map_err(|_| NotASetLine)?
                base = Str.replace_each(unit, "/side", "")
                kg =
                    match base {
                        "lbs" | "lb" => Ok(n * Units.lb_kg)
                        "kg" => Ok(n)
                        _ => Err(NotASetLine)
                    }?
                if n <= 0.0 {
                    Err(NotASetLine)
                } else {
                    Ok({ kg, per_side: Str.contains(right, "/side") })
                }
            }
            _ => Err(NotASetLine)
        }
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
                # 30 lbs/side, total reps: both hands at once → 60 lbs per rep
                and (a.weight_kg - 27.2155422).abs() < 0.001
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

# zero and negative magnitudes are refused, not stored: a row claiming 0 sets
# or a negative weight is paste damage, and tonnage built on it would be a
# confident wrong number
expect List.is_empty(Peloton.parse("Curl\n0 × 12 • 15 lbs"))
expect List.is_empty(Peloton.parse("Curl\n3 × 12 • -15 lbs"))

# an unrecognised unit is not a set line — prose with a bullet stays prose
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
    zero = Peloton.parse("Chin Up\n3 × 6 • 0 lbs\n3 × 6 • 175 lbs")
    bare = Peloton.parse("Push Up\n3 × 15\n3 × 10 • 40 lbs")
    match (zero, bare) {
        ([a], [b]) => a.exercise == "Chin Up" and a.weight_kg == 0.0 and b.exercise == "Push Up" and b.sets == 3 and b.reps == 10
        _ => False
    }
}

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

# a timed set line with a weight yields no row, in any case of its unit, and
# does not take over the name: the next set line still belongs to the move
# above it, while a rep-counted line beside it keeps its tonnage
expect {
    rows = Peloton.parse("Weighted Plank\n3 × 30 sec • 20 lbs\n3 × 1 Min • 20 lbs\n3 × 6 • 20 lbs\nCurl\n3 × 10 • 20 lbs")
    match rows {
        [a, b] => a.exercise == "Weighted Plank" and a.reps == 6 and b.exercise == "Curl" and b.sets == 3 and b.reps == 10 and (b.weight_kg - 9.0718474).abs() < 0.001
        _ => False
    }
}
