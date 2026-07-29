module [render_table, fmt0, fmt1, fmt2, mins]

# ── pure text-rendering helpers for human CLI output ────────────────

# aligned table: headers + rows -> multiline string
render_table : List Str, List (List Str) -> Str
render_table = |headers, rows|
    widths = List.walk(
        List.prepend(rows, headers),
        List.map(headers, |_| 0),
        |acc, row|
            List.map_with_index(acc, |w, i|
                cell = Result.with_default(List.get(row, i), "")
                Num.max(w, display_width(cell))),
    )
    line = |row|
        cells = List.map_with_index(row, |cell, i|
            w = Result.with_default(List.get(widths, i), 0)
            pad_right(cell, w))
        Str.trim_end(Str.join_with(cells, "  "))
    sep = List.map(widths, |w| Str.repeat("-", w))
    all_lines = List.concat([line(headers), line(sep)], List.map(rows, line))
    Str.join_with(all_lines, "\n")

pad_right : Str, U64 -> Str
pad_right = |s, w|
    n = display_width(s)
    if n >= w then s else Str.concat(s, Str.repeat(" ", w - n))

# terminal columns, not bytes. Each UTF-8 code point has exactly one lead byte
# (< 0x80, or >= 0xC0); continuation bytes (0x80–0xBF) don't count. Astral-plane
# code points (4-byte lead, >= 0xF0) are emoji — Strava activity names have them
# ("Morning Ride 🚴") — and occupy TWO terminal columns, so count them twice.
# (Latin-1/accents like é are 2-byte width-1; our box/bullet glyphs are 3-byte
# width-1 — both stay correct.)
display_width : Str -> U64
display_width = |s|
    List.walk(
        Str.to_utf8(s),
        0,
        |acc, b|
            if b >= 0xF0 then
                acc + 2
            else if b < 0x80 or b >= 0xC0 then
                acc + 1
            else
                acc,
    )

# integer-rounded float, e.g. 71.9 -> "72"
fmt0 : F64 -> Str
fmt0 = |x|
    r : I64
    r = Num.round(x)
    Num.to_str(r)

# one-decimal float, e.g. 12.34 -> "12.3" (for distances). Preserves the sign
# for -1 < x < 0.
fmt1 : F64 -> Str
fmt1 = |x|
    n : I64
    n = Num.round(x * 10.0)
    whole = n // 10
    frac = Num.abs(n % 10)
    sign = if n < 0 and whole == 0 then "-" else ""
    "${sign}${Num.to_str(whole)}.${Num.to_str(frac)}"

# two-decimal float, e.g. 0.979 -> "0.98". Preserves the sign for -1 < x < 0
# (where the integer part rounds to 0 but the value is negative).
fmt2 : F64 -> Str
fmt2 = |x|
    n : I64
    n = Num.round(x * 100.0)
    whole = n // 100
    frac = Num.abs(n % 100)
    frac_str = if frac < 10 then "0${Num.to_str(frac)}" else Num.to_str(frac)
    sign = if n < 0 and whole == 0 then "-" else ""
    "${sign}${Num.to_str(whole)}.${frac_str}"

# seconds -> "62m"
mins : I64 -> Str
mins = |secs|
    Num.to_str(secs // 60) |> Str.concat("m")


# ── tests ───────────────────────────────────────────────────────────



expect fmt1(12.34) == "12.3"
expect fmt1(9.96) == "10.0"
expect fmt1(0.0) == "0.0"
expect fmt2(0.979) == "0.98"
expect fmt2(1.0) == "1.00"
expect fmt2(1.5) == "1.50"
expect fmt2(-0.5) == "-0.50" # sign survives when the integer part is 0
expect fmt2(-1.25) == "-1.25"
expect fmt0(71.9) == "72"
expect mins(3725) == "62m"
expect pad_right("ab", 4) == "ab  "
expect display_width("██") == 2
expect display_width("abc") == 3
expect display_width("café") == 4 # accented Latin stays width 1 per char
expect display_width("🚴") == 2 # 4-byte emoji is two columns
expect display_width("ab🔥") == 4 # a + b + wide emoji
expect pad_right("██", 4) == "██  "

# unicode bars must not skew column alignment
expect
    t = render_table(["v", "x"], [["██", "y"]])
    t == "v   x\n--  -\n██  y"

expect
    t = render_table(["a", "bb"], [["x", "y"], ["long", "z"]])
    t == "a     bb\n----  --\nx     y\nlong  z"
