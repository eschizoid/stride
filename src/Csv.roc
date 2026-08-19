# ── minimal RFC-4180 CSV parsing (pure) ─────────────────────────────
# Handles what Strava's activities.csv actually throws at us: quoted fields,
# escaped quotes ("") inside quotes, commas AND newlines inside quotes
# (activity descriptions), and CRLF line endings.

Csv :: [].{

    # What one byte means given the quoting state. Flat classification so the fold below is
    # an eight-case table instead of a five-deep if/else staircase. RFC 4180: a doubled quote
    # inside a quoted field is one literal quote, which is why leaving quotes remembers
    # prev_quote — the next byte decides whether that quote CLOSED the field or escaped one.
    parse_case : Bool, Bool, U8 -> [QuotedByte, LeaveQuotes, EscapedQuote, EnterQuotes, EndField, EndRow, SkipCr, PlainByte]
    parse_case = |in_quotes, prev_quote, b|
        if in_quotes {
            if b == '"' LeaveQuotes else QuotedByte
        } else if b == '"' {
            if prev_quote EscapedQuote else EnterQuotes
        } else if b == ',' {
            EndField
        } else if b == '\n' {
            EndRow
        } else if b == '\r' {
            SkipCr # CRLF: the \n right after does the work
        } else {
            PlainByte
        }

    # parse CSV text into rows of fields. The final field/row is flushed even
    # without a trailing newline. A trailing newline does NOT produce an empty row.
    parse : Str -> List(List(Str))
    parse = |text| {
        state = List.fold(
            Str.to_utf8(text),
            { rows: [], row: [], field: [], in_quotes: False, prev_quote: False },
            |acc, b|
                match parse_case(acc.in_quotes, acc.prev_quote, b) {
                    QuotedByte => { ..acc, field: List.prepend(acc.field, b) }
                    LeaveQuotes => { ..acc, in_quotes: False, prev_quote: True }
                    EscapedQuote => { ..acc, field: List.prepend(acc.field, b), in_quotes: True, prev_quote: False }
                    EnterQuotes => { ..acc, in_quotes: True }
                    EndField => { ..acc, row: List.prepend(acc.row, field_str(acc.field)), field: [], prev_quote: False }
                    EndRow => { ..acc, rows: List.prepend(acc.rows, close_row(acc)), row: [], field: [], prev_quote: False }
                    SkipCr => acc
                    PlainByte => { ..acc, field: List.prepend(acc.field, b), prev_quote: False }
                },
        )
        if List.is_empty(state.field) and List.is_empty(state.row) {
            reverse(state.rows)
        } else {
            reverse(List.prepend(state.rows, close_row(state)))
        }
    }

    # finish the in-progress row: flush the current field, restore left-to-right order
    close_row = |acc| reverse(List.prepend(acc.row, field_str(acc.field)))

    field_str : List(U8) -> Str
    field_str = |bytes|
        match Str.from_utf8(reverse(bytes)) {
            Ok(s) => s
            Err(_) => ""
        }

    # Accumulating at the front is O(1); reversing once at a field/row boundary keeps
    # parsing linear. The previous append-per-byte implementation became quadratic on
    # real Strava exports and could trigger the pre-2026-08-17 compiler's heap-corruption
    # bug (#32, fixed on the current pin — the linear shape is still the right one).
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


# quoted comma, escaped quote, quoted newline, CRLF endings
expect Csv.parse("name,note\r\n\"Ride, hard\",\"said \"\"go\"\"\"\r\n\"multi\nline\",x") == [["name", "note"], ["Ride, hard", "said \"go\""], ["multi\nline", "x"]]

# empty fields survive
expect Csv.parse("a,,c\n,,\n") == [["a", "", "c"], ["", "", ""]]

# duplicate headers: occurrence 0 vs 1
expect {
    hs = ["Distance", "Moving Time", "Distance"]
    Csv.column_index(hs, "Distance", 0) == Ok(0) and Csv.column_index(hs, "Distance", 1) == Ok(2) and Csv.column_index(hs, "Watts", 0) == Err(NotFound)
}
