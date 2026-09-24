Strength :: [].{
    # ── the strength-notes parser: Peloton share text → set rows ────────
    # Strava's public API carries no per-exercise sets; what exists for these
    # sessions is the activity DESCRIPTION, where the athlete pastes the
    # Peloton share summary (#478). Its grammar is regular:
    #
    #     Block 1
    #     Dumbbell Crush Press
    #     3 × 8 • 30 lbs/side
    #     Dumbbell Snatch Push Press
    #     3 × 8 reps/side • 25 lbs/side
    #
    # An exercise NAME line is followed by a SET line `S × R • W <unit>`, with
    # `reps/side` and `<unit>/side` variants and `Block N` section headers
    # between groups. The source is a human paste, so the contract is
    # tolerance: any line that is not a well-formed set line is skipped, a set
    # line with no preceding exercise name is skipped, and an empty or absent
    # description parses to no rows — a set-less strength session counts for
    # load and streak but not tonnage, an honest gap rather than a failure.
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
    # Units: lbs (Peloton's default) converted at 0.45359237 kg/lb; kg as-is.
    #
    # A row is what one exercise line prescribes: `sets` × `reps` at
    # `weight_kg` per rep, so tonnage is their product. Pure, expects below;
    # the effectful skin (storing rows at analyze) lives in Analyze.roc.

    SetRow : { exercise : Str, sets : I64, reps : I64, weight_kg : F64 }

    lb_kg : F64
    lb_kg = 0.45359237

    parse : Str -> List(SetRow)
    parse = |text| {
        lines = List.map(Str.split_on(text, "\n"), |l| Str.trim(l))
        walk = List.fold(lines, { exercise: "", rows: [] }, |acc, line| {
            match parse_set_line(line) {
                Ok(s) =>
                    if acc.exercise == "" {
                        acc
                    } else {
                        { exercise: acc.exercise, rows: List.append(acc.rows, { exercise: acc.exercise, sets: s.sets, reps: s.reps, weight_kg: s.weight_kg }) }
                    }
                Err(_) =>
                    if line == "" or Str.starts_with(line, "Block ") {
                        # a blank line or section header ends nothing — the next set
                        # line still belongs to the last named exercise, matching how
                        # the share format lays out supersets
                        acc
                    } else {
                        { ..acc, exercise: line }
                    }
            }
        })
        walk.rows
    }

    # one set line, or Err for anything else. The bullet is the discriminator:
    # no prose line in the share format carries ` • `.
    parse_set_line : Str -> Try({ sets : I64, reps : I64, weight_kg : F64 }, [NotASetLine])
    parse_set_line = |line|
        match Str.split_on(line, " • ") {
            [left, right] => {
                lr = parse_sets_reps(left)?
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

    # `3 × 8`, `3 × 8 reps`, `3 × 8 reps/side` — ASCII `x` tolerated, since a
    # re-typed paste is one keyboard away from the multiplication sign
    parse_sets_reps : Str -> Try({ sets : I64, reps : I64, per_side : Bool }, [NotASetLine])
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
            Ok({ sets, reps, per_side: Str.contains(reps_part, "/side") })
        }
    }

    # `30 lbs/side`, `25 lbs`, `12.5 kg` — a right side with no recognised
    # unit is not a set line (bodyweight rows carry no bullet at all in the
    # share format, so this arm mostly guards against prose with a bullet)
    parse_weight : Str -> Try({ kg : F64, per_side : Bool }, [NotASetLine])
    parse_weight = |right| {
        tokens = Str.split_on(Str.trim(right), " ")
        match tokens {
            [num_s, unit, ..] => {
                n = F64.from_str(num_s).map_err(|_| NotASetLine)?
                base = Str.replace_each(unit, "/side", "")
                kg =
                    match base {
                        "lbs" | "lb" => Ok(n * lb_kg)
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

    tonnage_kg : List(SetRow) -> F64
    tonnage_kg = |rows|
        List.fold(rows, 0.0, |acc, r| acc + (r.sets).to_f64() * (r.reps).to_f64() * r.weight_kg)
}

# the issue's verbatim sample: two exercises, both /side variants
expect {
    rows = Strength.parse("Block 1\nDumbbell Crush Press\n3 × 8 • 30 lbs/side\nDumbbell Snatch Push Press\n3 × 8 reps/side • 25 lbs/side")
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

# tonnage is the product sum: 3×8×27.2155… + 3×16×11.3398… = 1197.48…
expect {
    rows = Strength.parse("A\n3 × 8 • 30 lbs/side\nB\n3 × 8 reps/side • 25 lbs/side")
    (Strength.tonnage_kg(rows) - 1197.4838568).abs() < 0.01
}

# kg passes through unconverted; decimal weights parse; ASCII x accepted
expect {
    rows = Strength.parse("Goblet Squat\n4 x 10 • 22.5 kg")
    match rows {
        [a] => a.sets == 4 and a.reps == 10 and (a.weight_kg - 22.5).abs() < 0.001
        _ => False
    }
}

# plain totals: no /side anywhere means the stated numbers stand
expect {
    rows = Strength.parse("Barbell Bench Press\n5 × 5 • 135 lbs")
    match rows {
        [a] => a.sets == 5 and a.reps == 5 and (a.weight_kg - 61.23496995).abs() < 0.001
        _ => False
    }
}

# tolerance: junk lines skip, a set line before any exercise name skips,
# Block headers and blank lines do not become exercise names
expect {
    rows = Strength.parse("3 × 8 • 30 lbs\nBlock 2\n\nsome prose that is not a set\nCurl\n2 × 12 • 15 lbs")
    match rows {
        [a] => a.exercise == "Curl" and a.sets == 2 and a.reps == 12
        _ => False
    }
}

# a bodyweight line (no bullet) is not a set line; the exercise keeps its
# name for a later weighted line, matching the share format's superset layout
expect {
    rows = Strength.parse("Push Up\n3 × 15\nDumbbell Row\n3 × 10 • 40 lbs")
    match rows {
        [a] => a.exercise == "Dumbbell Row" and a.sets == 3 and a.reps == 10
        _ => False
    }
}

# empty and absent parse to nothing — the honest-gap contract
expect List.is_empty(Strength.parse(""))
expect List.is_empty(Strength.parse("a ride description with no sets at all"))

# zero and negative magnitudes are refused, not stored: a row claiming 0 sets
# or a negative weight is paste damage, and tonnage built on it would be a
# confident wrong number
expect List.is_empty(Strength.parse("Curl\n0 × 12 • 15 lbs"))
expect List.is_empty(Strength.parse("Curl\n3 × 12 • -15 lbs"))

# an unrecognised unit is not a set line — prose with a bullet stays prose
expect List.is_empty(Strength.parse("Curl\n3 × 12 • 15 stone"))
