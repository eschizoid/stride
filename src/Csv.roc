# ── minimal RFC-4180 CSV parsing (pure) ─────────────────────────────
# Handles what Strava's activities.csv actually throws at us: quoted fields,
# escaped quotes ("") inside quotes, commas AND newlines inside quotes
# (activity descriptions), and CRLF line endings.

Csv :: [].{

    # parse CSV text into rows of fields. The final field/row is flushed even
    # without a trailing newline. A trailing newline does NOT produce an empty row.
    parse : Str -> List(List(Str))
    parse = |text| {
        state = List.fold(
            Str.to_utf8(text),
            { rows: [], row: [], field: [], in_quotes: False, prev_quote: False },
            |acc, b|
                if acc.in_quotes {
                    if b == '"' {
                        { ..acc, in_quotes: False, prev_quote: True }
                    } else {
                        { ..acc, field: List.append(acc.field, b) }
                    }
                } else if b == '"' {
                    if acc.prev_quote {
                        # "" inside a quoted field = one literal quote, still quoted
                        { ..acc, field: List.append(acc.field, b), in_quotes: True, prev_quote: False }
                    } else {
                        { ..acc, in_quotes: True }
                    }
                } else if b == ',' {
                    { ..acc, row: List.append(acc.row, field_str(acc.field)), field: [], prev_quote: False }
                } else if b == '\n' {
                    done_row = List.append(acc.row, field_str(acc.field))
                    { ..acc, rows: List.append(acc.rows, done_row), row: [], field: [], prev_quote: False }
                } else if b == '\r' {
                    acc # CRLF: the \n right after does the work
                } else {
                    { ..acc, field: List.append(acc.field, b), prev_quote: False }
                },
        )
        if List.is_empty(state.field) and List.is_empty(state.row) {
            state.rows
        } else {
            List.append(state.rows, List.append(state.row, field_str(state.field)))
        }
    }

    field_str : List(U8) -> Str
    field_str = |bytes|
        match Str.from_utf8(bytes) {
            Ok(s) => s
            Err(_) => ""
        }

    # index of the nth occurrence (0-based) of a header name — Strava's export has
    # DUPLICATE headers ("Distance" twice: km then meters) so occurrence matters.
    column_index : List(Str), Str, U64 -> Try(U64, [NotFound])
    column_index = |headers, name, occurrence| {
        found = List.fold_with_index(headers, { seen: 0.U64, idx: Err(NotFound) }, |acc, h, i|
            match acc.idx {
                Ok(_) => acc
                Err(_) =>
                    if h == name {
                        if acc.seen == occurrence {
                            { ..acc, idx: Ok(i) }
                        } else {
                            { ..acc, seen: acc.seen + 1 }
                        }
                    } else {
                        acc
                    }
            })
        found.idx
    }
}

# plain fields, trailing newline ignored
expect Csv.parse("a,b\n1,2\n") == [["a", "b"], ["1", "2"]]

# quoted comma, escaped quote, quoted newline, CRLF endings
expect Csv.parse("name,note\r\n\"Ride, hard\",\"said \"\"go\"\"\"\r\n\"multi\nline\",x") == [["name", "note"], ["Ride, hard", "said \"go\""], ["multi\nline", "x"]]

# empty fields survive
expect Csv.parse("a,,c\n,,\n") == [["a", "", "c"], ["", "", ""]]

# duplicate headers: occurrence 0 vs 1
expect {
    hs = ["Distance", "Moving Time", "Distance"]
    Csv.column_index(hs, "Distance", 0) == Ok(0) and Csv.column_index(hs, "Distance", 1) == Ok(2) and Csv.column_index(hs, "Watts", 0) == Err(NotFound)
}
