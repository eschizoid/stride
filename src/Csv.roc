# ── minimal RFC-4180 CSV parsing (pure) ─────────────────────────────
# Handles what Strava's activities.csv actually throws at us: quoted fields,
# escaped quotes ("") inside quotes, commas AND newlines inside quotes
# (activity descriptions), and CRLF line endings.

Csv :: [].{

    # Split a CSV document into raw logical records without splitting quoted newlines.
    # Import uses this to parse one wide Strava activity row at a time: retaining every
    # field of every row in one nested list triggers a deallocation bug in the current
    # Linux compiler. Quotes are preserved so `parse` still owns field decoding.
    records : Str -> List(Str)
    records = |text| {
        state = List.fold(
            Str.to_utf8(text),
            { records: [], record: [], in_quotes: False },
            |acc, b|
                if b == '"' {
                    { ..acc, record: List.prepend(acc.record, b), in_quotes: !(acc.in_quotes) }
                } else if b == '\n' and !(acc.in_quotes) {
                    if List.is_empty(acc.record)
                        acc
                    else
                        { ..acc, records: List.prepend(acc.records, record_str(acc.record)), record: [] }
                } else {
                    { ..acc, record: List.prepend(acc.record, b) }
                },
        )
        if List.is_empty(state.record)
            reverse(state.records)
        else
            reverse(List.prepend(state.records, record_str(state.record)))
    }

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
                        { ..acc, field: List.prepend(acc.field, b) }
                    }
                } else if b == '"' {
                    if acc.prev_quote {
                        # "" inside a quoted field = one literal quote, still quoted
                        { ..acc, field: List.prepend(acc.field, b), in_quotes: True, prev_quote: False }
                    } else {
                        { ..acc, in_quotes: True }
                    }
                } else if b == ',' {
                    { ..acc, row: List.prepend(acc.row, field_str(acc.field)), field: [], prev_quote: False }
                } else if b == '\n' {
                    done_row = reverse(List.prepend(acc.row, field_str(acc.field)))
                    { ..acc, rows: List.prepend(acc.rows, done_row), row: [], field: [], prev_quote: False }
                } else if b == '\r' {
                    acc # CRLF: the \n right after does the work
                } else {
                    { ..acc, field: List.prepend(acc.field, b), prev_quote: False }
                },
        )
        if List.is_empty(state.field) and List.is_empty(state.row) {
            reverse(state.rows)
        } else {
            reverse(List.prepend(state.rows, reverse(List.prepend(state.row, field_str(state.field)))))
        }
    }

    field_str : List(U8) -> Str
    field_str = |bytes|
        match Str.from_utf8(reverse(bytes)) {
            Ok(s) => s
            Err(_) => ""
        }

    record_str : List(U8) -> Str
    record_str = |rev_bytes|
        match Str.from_utf8(reverse(rev_bytes)) {
            Ok(s) => s
            Err(_) => ""
        }

    # Accumulating at the front is O(1); reversing once at a field/row boundary keeps
    # parsing linear. The previous append-per-byte implementation became quadratic on
    # real Strava exports and could trigger the current compiler's heap-corruption bug.
    reverse : List(a) -> List(a)
    reverse = |xs| List.fold(xs, [], |acc, x| List.prepend(acc, x))

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

# logical records preserve quotes and keep a newline inside a quoted field
expect Csv.records("a,b\n\"multi\nline\",x\n") == ["a,b", "\"multi\nline\",x"]

# quoted comma, escaped quote, quoted newline, CRLF endings
expect Csv.parse("name,note\r\n\"Ride, hard\",\"said \"\"go\"\"\"\r\n\"multi\nline\",x") == [["name", "note"], ["Ride, hard", "said \"go\""], ["multi\nline", "x"]]

# empty fields survive
expect Csv.parse("a,,c\n,,\n") == [["a", "", "c"], ["", "", ""]]

# duplicate headers: occurrence 0 vs 1
expect {
    hs = ["Distance", "Moving Time", "Distance"]
    Csv.column_index(hs, "Distance", 0) == Ok(0) and Csv.column_index(hs, "Distance", 1) == Ok(2) and Csv.column_index(hs, "Watts", 0) == Err(NotFound)
}
