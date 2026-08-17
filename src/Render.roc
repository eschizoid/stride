import Metrics

Render :: [].{
    # ── pure text-rendering helpers for human CLI output ────────────────

    # aligned table: headers + rows -> multiline string.
    # Keeps the WHOLE table within max_total display-columns so a row never wraps
    # in the terminal — but WITHOUT losing text. Columns take their natural width;
    # if the table would overflow, the single widest column (in practice a free-text
    # `detail` or a long activity name) is squeezed and its text is WORD-WRAPPED
    # across continuation lines within the same row. The full text is always shown;
    # it just spans several physical lines.
    #
    # 100, not 80: the squeezed column is ALWAYS the free-text one, so every column
    # the budget spends elsewhere comes straight out of the workout description —
    # the part actually worth reading. A fixed number rather than $COLUMNS on
    # purpose: env-dependent output would make the e2e layout assertions
    # (bar-never-wraps, marker placement) unreproducible.
    max_total = 100
    min_col = 12

    # widest display-width among a set of already-wrapped lines
    max_line_width : List(Str) -> U64
    max_line_width = |ls| List.fold(ls, 0, |m, l| m.max(display_width(l)))

    # the builtins have no List.reverse on this compiler — same fold+prepend as Csv.reverse
    reverse_list : List(a) -> List(a)
    reverse_list = |xs| List.fold(xs, [], |acc, x| List.prepend(acc, x))

    # [0, 1, .., n-1]
    indices : U64 -> List(U64)
    indices = |n| indices_go(n, [])
    indices_go : U64, List(U64) -> List(U64)
    indices_go = |n, acc| if n == 0 acc else indices_go(n - 1, List.prepend(acc, n - 1))

    # greedy word-wrap: pack space-separated words into lines of at most `cap`
    # display-columns. A lone word wider than cap gets its own line (details are
    # prose — no giant tokens — so this practically never widens the column).
    wrap_cell : Str, U64 -> List(Str)
    wrap_cell = |s, cap|
        if display_width(s) <= cap
            [s]
        else {
            packed = List.fold(
                Str.split_on(s, " "),
                { cur: "", out: [] },
                |st, word| {
                    cand = if Str.is_empty(st.cur) word else "${st.cur} ${word}"
                    if display_width(cand) <= cap
                        { cur: cand, out: st.out }
                    else if Str.is_empty(st.cur)
                        { cur: "", out: List.append(st.out, word) }
                    else
                        { cur: word, out: List.append(st.out, st.cur) }
                },
            )
            final = if Str.is_empty(packed.cur) packed.out else List.append(packed.out, packed.cur)
            if List.is_empty(final) [""] else final
        }

    idx_of_max : List(U64) -> U64
    idx_of_max = |xs| {
        best = List.fold(
            List.map_with_index(xs, |w, i| { i, w }),
            { i: 0, w: 0 },
            |acc, cur| if cur.w > acc.w cur else acc,
        )
        best.i
    }

    # per-column caps that fit sum(widths) + borders into max_total, squeezing only
    # the widest column (the real case is one dominant text column). natural widths
    # in, caps out; unchanged when the table already fits.
    fit_caps : List(U64), U64 -> List(U64)
    fit_caps = |nat, overhead| {
        total = List.fold(nat, 0, |a, w| a + w)
        budget = if max_total > overhead max_total - overhead else 0
        if total <= budget
            nat
        else {
            wi = idx_of_max(nat)
            ww = List.get(nat, wi).ok_or(0)
            excess = total - budget
            shrunk = if ww > excess + min_col ww - excess else min_col
            List.map_with_index(nat, |w, i| if i == wi shrunk else w)
        }
    }

    # A row that renders as a horizontal RULE spanning the whole table — the spreadsheet
    # divider — instead of as cells. It IS a row, so it sits in the rows list alongside
    # the others: `render_table(headers, [row_a, Render.rule, row_b])`.
    #
    # Drawn with the table's own border glyphs so it lines up with the header rule and the
    # top/bottom edges. The previous attempt filled every cell with `···`, which read as
    # data (and collided with `progress`, where `···` means a GAP in time, so a boundary
    # between two CONSECUTIVE days looked like missing days).
    # An EMPTY row, not a string sentinel. A sentinel is ambiguous: in a one-column table
    # a legitimate cell holding that exact text would render as a divider instead of data.
    # A row with no cells cannot collide with anything, because every data row has one
    # cell per column.
    rule : List(Str)
    rule = []

    is_rule : List(Str) -> Bool
    is_rule = |row| List.is_empty(row)

    render_table : List(Str), List(List(Str)) -> Str
    render_table = |headers, rows| {
        ncols = List.len(headers)
        overhead = 3 * ncols + 1
        # rule rows carry no data, so they must not influence column widths or wrapping
        data_rows = List.keep_if(rows, |r| !(is_rule(r)))
        nat = List.fold(
            List.prepend(data_rows, headers),
            List.map(headers, |_| 0),
            |acc, row|
                List.map_with_index(acc, |w, i| w.max(display_width(List.get(row, i).ok_or("")))),
        )
        caps = fit_caps(nat, overhead)
        # each row/header becomes a list of columns, each column a list of wrapped lines
        wrap_row = |row| List.map_with_index(row, |cell, i| wrap_cell(cell, List.get(caps, i).ok_or(display_width(cell))))
        wh = wrap_row(headers)
        # Wrap ONCE, keeping rule positions inline. The earlier shapes each had a cost:
        # re-wrapping in the body did the expensive work twice, and indexing a parallel
        # wrapped list needed a running counter plus a silent `.ok_or([])` fallback whose
        # complexity depends on how List.get is implemented. Tagging each entry sidesteps
        # both — one pass, no index, linear whatever the list representation.
        tagged = List.map(rows, |row| if is_rule(row) Rule else Data(wrap_row(row)))
        wrs = List.keep_oks(tagged, |t| match t {
            Data(w) => Ok(w)
            Rule => Err({})
        })
        widths = List.fold(
            List.prepend(wrs, wh),
            List.map(headers, |_| 0),
            |acc, wrow|
                List.map_with_index(acc, |w, i| w.max(max_line_width(List.get(wrow, i).ok_or([])))),
        )
        # render one logical row (columns-of-wrapped-lines) as N physical lines,
        # continuation lines leaving the other columns blank
        render_wrow = |wrow| {
            height = List.fold(wrow, 1, |h, col_lines| h.max(List.len(col_lines)))
            phys = List.map(indices(height), |k| {
                cells = List.map_with_index(wrow, |col_lines, i| {
                    w = List.get(widths, i).ok_or(0)
                    pad_right(List.get(col_lines, k).ok_or(""), w)
                })
                "│ ${Str.join_with(cells, " │ ")} │"
            })
            Str.join_with(phys, "\n")
        }
        border = |left, mid, right|
            "${left}${Str.join_with(List.map(widths, |w| Str.repeat("─", w + 2)), mid)}${right}"
        # `tagged` already holds every row in order, wrapped once, with rules marked — so
        # emitting the body is a straight map with no counter and no second wrapping pass.
        body = List.map(tagged, |t| match t {
            Rule => border("├", "┼", "┤")
            Data(w) => render_wrow(w)
        })
        all_lines = List.join([
            [border("╭", "┬", "╮"), render_wrow(wh), border("├", "┼", "┤")],
            body,
            [border("╰", "┴", "╯")],
        ])
        Str.join_with(all_lines, "\n")
    }

    pad_right : Str, U64 -> Str
    pad_right = |s, w| {
        n = display_width(s)
        if n >= w s else Str.concat(s, Str.repeat(" ", w - n))
    }

    # A delta that keeps its sign: "+5" reads as a build, "-3" as an unload. Shared by the
    # compare table and the summary ramp line so the two spell a delta the same way.
    #
    # The sign comes from x, NOT from the rounded string. fmt0 rounds -0.4 to "0", so
    # deciding the sign afterwards silently turned every small unload into a flat zero —
    # and left the two directions asymmetric, since +0.4 still printed "+0". A magnitude
    # that rounds away is still a direction that did not.
    signed : F64 -> Str
    signed = |x| {
        mag = fmt0((x).abs())
        if x >= 0.0 "+${mag}" else "-${mag}"
    }

    # How long the band has held, appended to the state (#123).
    #
    # Takes the TAG, not a flattened number: the caller must not decide what Unknown means
    # on the renderer's behalf, and AtLeast must not arrive here already collapsed into an
    # exact-looking integer.
    #
    #   Known(n)   n >= 2  -> ", 12 days in this band"
    #   AtLeast(n) n >= 2  -> ", 31+ days in this band"   the window ran out mid-streak
    #   either,    n <= 1  -> ""                          a one-day streak is noise
    #   Unknown            -> ""                          nothing known about today
    #
    # The `+` is the whole point of AtLeast reaching this far: `summary` reads a 31-day
    # window, so a 45-day streak truncates, and printing a bare "31" would present the
    # window size as a measurement.
    band_days_phrase : [Known(I64), AtLeast(I64), Unknown] -> Str
    band_days_phrase = |band|
        match band {
            Unknown => ""
            Known(n) => if n <= 1 "" else ", ${(n).to_str()} days in this band"
            AtLeast(n) => if n <= 1 "" else ", ${(n).to_str()}+ days in this band"
        }

    # The clause that gives the form verdict a memory (#111). Words, not a signed number,
    # because this sits mid-sentence between the value and the band label.
    #
    # Unknown renders as "" and the caller drops the clause entirely: too little history to
    # compare is NOT "level with a week ago", and saying so would be the same fabrication
    # `form_delta_7d` returns a tag to avoid.
    #
    # Rounding is what decides "level", not the raw value: the line prints whole points, so
    # a 0.4 swing that displays as 0 must not read "up 0 from a week ago".
    form_trend_phrase : [Known(F64), Unknown] -> Str
    form_trend_phrase = |delta|
        match delta {
            Unknown => ""
            Known(d) =>
                if fmt0((d).abs()) == "0" {
                    ", level with a week ago"
                } else if d > 0.0 {
                    ", up ${fmt0(d)} from a week ago"
                } else {
                    ", down ${fmt0((d).abs())} from a week ago"
                }
        }

    pad_left : Str, U64 -> Str
    pad_left = |s, w| {
        n = display_width(s)
        if n >= w s else Str.concat(Str.repeat(" ", w - n), s)
    }

    # A `\r`-redrawn progress bar for the commands slow enough to look hung. Reuses the
    # table's `█` so the glyph vocabulary stays one thing.
    #
    # CONSTANT WIDTH is the whole trick, not cosmetics: `\r` returns the cursor without
    # clearing the line, so a frame shorter than the one before it leaves the tail of the
    # previous frame on screen ("358/723" redrawn as "9/723" would read "9/7233"). The bar
    # is a fixed cell count and `done` is left-padded to the width of `total`, so every
    # frame of a given run is exactly as wide as the last.
    progress_bar_cells : U64
    progress_bar_cells = 10

    progress_bar : Str, U64, U64 -> Str
    progress_bar = |label, done, total|
        if total == 0 {
            # nothing to divide by, and no honest fraction to show. Same spelling as
            # progress_line's, so a total==0 run reads identically in both modes.
            "${label}…"
        } else {
            capped = if done > total total else done
            filled = (capped * progress_bar_cells) // total
            counts = "${pad_left((capped).to_str(), Str.count_utf8_bytes((total).to_str()))}/${(total).to_str()}"
            "${label} [${Str.repeat("█", filled)}${Str.repeat("░", progress_bar_cells - filled)}] ${counts}"
        }

    # machine mode gets the same information with no carriage returns and no padding —
    # a `\r` is garbage in a CI log, and these lines are appended, never redrawn
    progress_line : Str, U64, U64 -> Str
    progress_line = |label, done, total|
        if total == 0 {
            "${label}…"
        } else {
            # clamp exactly as the bar does. The denominator is read once up front and a
            # later pass can re-invalidate rows, so the running count CAN exceed it —
            # without this, machine mode prints an impossible `730/723` while human mode
            # shows a full bar at 723/723.
            capped = if done > total total else done
            "${label} ${(capped).to_str()}/${(total).to_str()}"
        }

    # terminal columns, not bytes. Each UTF-8 code point has exactly one lead byte
    # (< 0x80, or >= 0xC0); continuation bytes (0x80–0xBF) don't count. Astral-plane
    # code points (4-byte lead, >= 0xF0) are emoji — Strava activity names have them
    # ("Morning Ride 🚴") — and occupy TWO terminal columns, so count them twice.
    # (Latin-1/accents like é are 2-byte width-1; our box/bullet glyphs are 3-byte
    # width-1 — both stay correct.)
    display_width : Str -> U64
    display_width = |s|
        List.fold(
            Str.to_utf8(s),
            0,
            |acc, b|
                if b >= 0xF0 {
                    acc + 2
                } else if b < 0x80 or b >= 0xC0 {
                    acc + 1
                } else {
                    acc
                },
        )

    # One line warning that the fitness series has not converged, or "" when it has. CTL
    # seeds at zero and needs ~two 42-day time constants before the absolute form bands mean
    # anything, so until then the number above is real arithmetic on an incomplete series —
    # low, not wrong, but not comparable to the bands either. Empty string renders as a
    # blank line the caller already allows for.
    warming_up_note : Bool, I64 -> Str
    warming_up_note = |warming, days|
        if warming {
            "  ⚠ only ${I64.to_str(days)} days of history — fitness is still converging, so form reads low"
        } else {
            ""
        }

    # integer-rounded float, e.g. 71.9 -> "72"
    fmt0 : F64 -> Str
    fmt0 = |x| {
        r = x.round_to_i64_try().ok_or(0)
        I64.to_str(r)
    }

    # one-decimal float, e.g. 12.34 -> "12.3" (for distances). Preserves the sign
    # for -1 < x < 0.
    fmt1 : F64 -> Str
    fmt1 = |x| {
        n = (x * 10.0).round_to_i64_try().ok_or(0)
        whole = n // 10
        frac = (n % 10).abs()
        sign = if n < 0 and whole == 0 "-" else ""
        "${sign}${I64.to_str(whole)}.${I64.to_str(frac)}"
    }

    # two-decimal float, e.g. 0.979 -> "0.98". Preserves the sign for -1 < x < 0
    # (where the integer part rounds to 0 but the value is negative).
    fmt2 : F64 -> Str
    fmt2 = |x| {
        n = (x * 100.0).round_to_i64_try().ok_or(0)
        whole = n // 100
        frac = (n % 100).abs()
        frac_str = if frac < 10 "0${I64.to_str(frac)}" else I64.to_str(frac)
        sign = if n < 0 and whole == 0 "-" else ""
        "${sign}${I64.to_str(whole)}.${frac_str}"
    }

    # distance+time -> running pace "M:SS" per km (blank if no distance)
    pace_per_km : F64, I64 -> Str
    pace_per_km = |distance_m, moving_time|
        if distance_m <= 0.0 or moving_time <= 0 {
            "-"
        } else {
            total = (moving_time.to_f64() / (distance_m / 1000.0)).round_to_i64_try().ok_or(0)
            m = total // 60
            s = total % 60
            ss = if s < 10 "0${I64.to_str(s)}" else I64.to_str(s)
            "${I64.to_str(m)}:${ss}"
        }

    # seconds -> "62m"
    mins : I64 -> Str
    mins = |secs|
        Str.concat(I64.to_str(secs // 60), "m")

    # m:ss for interval durations — 181 -> "3:01"; whole minutes keep :00 so
    # columns align ("12:00", not "12m")
    mmss : I64 -> Str
    mmss = |secs| {
        m = secs // 60
        sec = secs - m * 60
        pad = if sec < 10 "0" else ""
        "${I64.to_str(m)}:${pad}${I64.to_str(sec)}"
    }

    # h:mm:ss for durations that can exceed an hour. mmss is for intervals and
    # renders 222 days as "320807:09"; tte is the first screen where a query a
    # couple of watts off CP produces that, so it needs the wider format.
    hms : I64 -> Str
    hms = |secs|
        if secs < 3600 {
            mmss(secs)
        } else {
            h = secs // 3600
            rest = secs - h * 3600
            m = rest // 60
            sec = rest - m * 60
            mpad = if m < 10 "0" else ""
            spad = if sec < 10 "0" else ""
            "${I64.to_str(h)}:${mpad}${I64.to_str(m)}:${spad}${I64.to_str(sec)}"
        }

    SegRow : { ordinal : I64, kind : Str, start_s : I64, dur_s : I64, avg_signal : F64, signal : Str, peak_hr : F64, avg_hr : F64, rec_drop : F64, rec_drop_known : Bool }

    seg_unit : Str -> Str
    seg_unit = |signal| if signal == "power" "W" else " m/s"

    seg_value : F64, Str -> Str
    seg_value = |v, signal| if signal == "power" fmt0(v) else fmt2(v)

    # "4×[3:00 @ 251W / 2:00 easy]" — the detected shape in one line. Reps vary in
    # the wild, so durations/levels are MEDIANS of the work reps; recovery is the
    # median of recovery segments lying BETWEEN the first and last work (a
    # mislabeled pre-work block must not become the "easy" half of a summary).
    # No between-works recoveries (blocks back to back, or a single rep) drops
    # the "/ ..." half.
    interval_summary : List(SegRow) -> Str
    interval_summary = |segs| {
        works = List.keep_if(segs, |s| s.kind == "work")
        n = List.len(works)
        if n == 0 {
            ""
        } else {
            first_work = (List.first(works)).map_ok(|w| w.ordinal).ok_or(0)
            last_work = (List.last(works)).map_ok(|w| w.ordinal).ok_or(0)
            recs = List.keep_if(segs, |s| s.kind == "recovery" and s.ordinal > first_work and s.ordinal < last_work)
            med = |xs| {
                sorted = List.sort_with(xs, |a, b| if a < b LT else if a > b GT else EQ)
                (List.get(sorted, List.len(sorted) // 2)).ok_or(0.0)
            }
            sig = (List.first(works)).map_ok(|w| w.signal).ok_or("power")
            dur_med = med(List.map(works, |w| ((w.dur_s)).to_f64()))
            level_med = med(List.map(works, |w| w.avg_signal))
            work_part = "${I64.to_str((n).to_i64_wrap())}×[${mmss((dur_med).round_to_i64_try().ok_or(0))} @ ${seg_value(level_med, sig)}${seg_unit(sig)}"
            if List.is_empty(recs) {
                Str.concat(work_part, "]")
            } else {
                rec_med = med(List.map(recs, |r| ((r.dur_s)).to_f64()))
                "${work_part} / ${mmss((rec_med).round_to_i64_try().ok_or(0))} easy]"
            }
        }
    }

    # per-rep detail lines under the summary — one work rep per line, HR only when
    # measured (honest absence: a rep with no HR simply has no hr clause)
    segments_block : List(SegRow) -> Str
    segments_block = |segs| {
        works = List.keep_if(segs, |s| s.kind == "work")
        lines = List.map_with_index(works, |w, i| {
            base = "rep ${I64.to_str(((i)).to_i64_wrap() + 1)}  ${mmss(w.dur_s)} @ ${seg_value(w.avg_signal, w.signal)}${seg_unit(w.signal)}"
            hr_part = if w.avg_hr > 0.0 " · hr ${fmt0(w.avg_hr)} avg / ${fmt0(w.peak_hr)} peak" else ""
            drop_part = if w.rec_drop_known " · 60s drop ${signed(w.rec_drop)}" else ""
            Str.join_with([base, hr_part, drop_part], "")
        })
        Str.join_with(lines, "\n")
    }

    # HR drift across work reps (fatigue signature): last rep's avg minus first's,
    # only when both were measured. Err(NotEnough) below 2 measured reps.
    seg_hr_drift : List(SegRow) -> Try(F64, [NotEnough])
    seg_hr_drift = |segs| {
        measured = List.keep_if(segs, |s| s.kind == "work" and s.avg_hr > 0.0)
        if List.len(measured) < 2 {
            Err(NotEnough)
        } else {
            first = (List.first(measured)).map_ok(|s| s.avg_hr).ok_or(0.0)
            last = (List.last(measured)).map_ok(|s| s.avg_hr).ok_or(0.0)
            Ok(last - first)
        }
    }

    # display label for a progress group, from anchor_filter's structured kind
    progress_group_label : Str, [Exact, SimilarDistance(F64), LoneNoDistance] -> Str
    progress_group_label = |name, kind|
        match kind {
            Exact => name
            SimilarDistance(m) => "${name} (~${fmt1(m / 1000.0)} km rides)"
            LoneNoDistance => "${name} (no distance recorded — can't match similar rides)"
        }

    # one workout's table + trend verdict, rendered through its sport-aware lens
    # (power->EF, distance->speed/HR, rated->RPE; RPE is lower-is-better)
    progress_section : Str, List(Metrics.ProgressRow), Str, [Ef, SpeedHr, Rpe], [Asc, Desc] -> Str
    progress_section = |name, rows, asked, lens, sort| {
        higher = Metrics.lens_higher_better(lens)
        sc = |row| Metrics.lens_score(lens, row).ok_or(0.0)
        scores = List.map(rows, sc)
        max_s = List.fold(scores, 0.0, |acc, s| acc.max(s))
        min_s = List.fold(scores, max_s, |acc, s| acc.min(s))
        best = if higher max_s else min_s
        worst = if higher min_s else max_s
        pfmt = |v| match lens {
            Rpe => fmt0(v)
            _ => fmt2(v)
        }
        hr_of = |row| if row.avg_hr > 0.0 fmt0(row.avg_hr) else "-"
        prim_of = |row| {
            n = Metrics.scale_to_blocks(sc(row), worst, best, 12)
            "${pfmt(sc(row))} ${Str.repeat("█", n)}"
        }
        # The ◀ marker rides on the DATE cell, and headers stay terse (meaning lives in
        # the legend, per the numbers-in-tables philosophy) — both keep every column
        # under render_table's 80-col budget so the BAR column is never the widest one
        # that gets squeezed and word-wrapped mid-bar.
        date_of = |row| if row.date == asked "${row.date} ◀" else row.date
        # each lens picks its own columns (list of header + per-row cell); the primary
        # (bar) column direction is already handled by best/worst above
        cols =
            match lens {
                Ef => [
                    ("np (W)", |row| fmt0(row.np_w)),
                    ("hr", hr_of),
                    ("ef", prim_of),
                    # aerobic decoupling per session (#135) — "-" when not computable,
                    # never a fabricated 0 (0.0 is a real, perfect result)
                    ("drift", |row| if row.decoupling_known "${signed(row.decoupling_pct)}%" else "-"),
                    ("kJ", |row| fmt0(row.output_kj)),
                    ("load", |row| fmt0(row.tss)),
                ]
                SpeedHr => [
                    ("pace (min/km)", |row| pace_per_km(row.distance_m, row.moving_time)),
                    ("hr", hr_of),
                    ("spd/hr", prim_of),
                    ("drift", |row| if row.decoupling_known "${signed(row.decoupling_pct)}%" else "-"),
                    ("km", |row| fmt1(row.distance_m / 1000.0)),
                    ("load", |row| fmt0(row.tss)),
                ]
                Rpe => [
                    ("duration", |row| mins(row.moving_time)),
                    ("hr", hr_of),
                    ("rpe", prim_of),
                    ("load", |row| fmt0(row.tss)),
                ]
            }
        headers = List.prepend(List.map(cols, |c| c.0), "date")
        to_cells = |row| List.prepend(List.map(cols, |c| (c.1)(row)), date_of(row))
        gap_row = List.map(headers, |_| "···")
        body_rows = {
            folded = List.fold(rows, { prev: -1000000.I64, cells: [] }, |acc, row| {
                days = Metrics.date_str_to_days(row.date).ok_or(acc.prev)
                with_gap =
                    if acc.prev > -1000000 and days - acc.prev > 90 {
                        List.append(acc.cells, gap_row)
                    } else {
                        acc.cells
                    }
                { prev: days, cells: List.append(with_gap, to_cells(row)) }
            })
            # gap markers, scores, and the trend verdict are all computed on the
            # CHRONOLOGICAL rows above; Desc only flips the displayed order. Reversing
            # after the fold keeps each ··· marker between the same two neighbours.
            match sort {
                Asc => folded.cells
                Desc => reverse_list(folded.cells)
            }
        }
        table = render_table(headers, body_rows)
        t = Metrics.trend_ends(scores)
        # no baseline (an unscorable first session) claims neither direction — it falls
        # through to "holding steady" rather than inventing a 0% trend
        trend = Metrics.pct_change(t.early, t.late)
        improved = match trend {
            Ok(p) => if higher (p > 5.0) else (p < -5.0)
            Err(NoBaseline) => False
        }
        declined = match trend {
            Ok(p) => if higher (p < -5.0) else (p > 5.0)
            Err(NoBaseline) => False
        }
        label = if improved "improving" else if declined "declining" else "holding steady"
        avg = Metrics.mean(scores)
        short = match lens {
            Ef => "ef"
            SpeedHr => "aero-eff"
            Rpe => "rpe"
        }
        legend = match lens {
            Ef => "ef = normalized power (np) / avg HR — watts per heartbeat, climbing = fitter · drift = aerobic decoupling, 2nd half vs 1st — LOWER is better, - = not computable · kJ = total work"
            SpeedHr => "spd/hr (aero-eff) = speed per heartbeat — climbing = fitter · drift = aerobic decoupling, 2nd half vs 1st — LOWER is better, - = not computable · pace is min/km"
            Rpe => "rpe = how hard it felt (1-10) — for a fixed workout, dropping = adapting"
        }
        # no baseline -> no percentage. Printing "(0%)" there claimed a measurement we
        # never made, which is the whole reason pct_change stopped returning a bare float.
        pct_str = match trend {
            Ok(p) => " (${fmt0(p)}%)"
            Err(_) => ""
        }
        # One session compares its own score against itself, so trend_ends returns early ==
        # late and pct_change dutifully reports a real 0% — "holding steady" reads as a
        # measured finding when it is the absence of one. State the score and stop.
        verdict =
            if List.len(rows) == 1 {
                # "one comparable session" read as though it were pointing at some OTHER
                # session to compare with. The single row IS this session — there is simply
                # no history behind it yet (#96).
                "→ ${short} ${pfmt(avg)} — first session of this workout, nothing to compare against yet"
            } else {
                "→ ${short} early avg ${pfmt(t.early)} → recent avg ${pfmt(t.late)} (overall avg ${pfmt(avg)}) over ${U64.to_str(List.len(rows))} sessions — ${label}${pct_str}"
            }
        footer = "${legend}\nbar = scaled worst→best · ◀ marks the asked date · ··· = a break over 90 days"
        "── ${name} ──\n${table}\n\n${verdict}${last_vs_best(rows, lens)}\n\n${footer}"
    }

    # "last vs best" line: the most recent session vs the all-time best FOR THIS LENS
    # (highest score, or lowest for RPE). Empty when last IS the best, or <2 rows.
    last_vs_best : List(Metrics.ProgressRow), [Ef, SpeedHr, Rpe] -> Str
    last_vs_best = |rows, lens| {
        higher = Metrics.lens_higher_better(lens)
        sc = |row| Metrics.lens_score(lens, row).ok_or(0.0)
        pfmt = |v| match lens {
            Rpe => fmt0(v)
            _ => fmt2(v)
        }
        desc = List.sort_with(rows, |a, b| {
            x = sc(b)
            y = sc(a)
            if x < y LT else if x > y GT else EQ
        })
        best_row = if higher List.first(desc) else List.last(desc)
        match (List.last(rows), best_row) {
            (Ok(last), Ok(best)) =>
                if last.date == best.date or List.len(rows) < 2 {
                    ""
                } else {
                    # with no baseline there is no gap to state — say nothing rather than
                    # "0% below your best", which reads as "you matched it"
                    match Metrics.pct_change(sc(best), sc(last)) {
                        Err(_) => ""
                        Ok(g) => {
                            word = if higher "below your best" else "above your easiest"
                            "\n→ last: ${pfmt(sc(last))} (${last.date}) vs best: ${pfmt(sc(best))} (${best.date}) — ${fmt0(g.abs())}% ${word}"
                        }
                    }
                }

            _ => ""
        }
    }

    # ── load command screen ─────────────────────────────────────────────

    # daily fitness table for short windows; Mon-aligned weekly rollup beyond 14 days
    load_screen : List({ day : Str, tss : F64, ctl : F64, atl : F64, tsb : F64 }) -> Str
    load_screen = |ordered| {
        verdict =
            match List.last(ordered) {
                Ok(today) => {
                    # the series is right here, so the trend costs nothing extra — no
                    # payload field and no second query, unlike the summary screen
                    anchor = Metrics.date_str_to_days(today.day).ok_or(0)
                    # DROP unparseable days rather than collapsing them to epoch day 0.
                    # Day 0 is a valid day number, so a collapsed row both truncates the
                    # streak early (the walk hits a "missing" day that is really present)
                    # and becomes a spurious candidate for the 7-days-back lookup on a
                    # short window — a fabricated trend where the honest answer is Unknown.
                    tsb_series = List.keep_oks(ordered, |d|
                        match Metrics.date_str_to_days(d.day) {
                            Ok(day) => Ok({ day, tsb: d.tsb })
                            Err(_) => Err({})
                        })
                    trend = form_trend_phrase(Metrics.form_delta_7d(tsb_series, anchor))
                    # the streak can only count as far back as the window `load` was asked
                    # for — and now it SAYS so: a streak filling the window renders "N+"
                    # rather than a bare N that reads as a measurement
                    band = band_days_phrase(Metrics.days_in_band(tsb_series, anchor))
                    "→ today: form ${fmt0(today.tsb)}${trend} — ${Metrics.form_label(today.tsb)}${band}"
                }
                Err(_) => ""
            }
        if List.len(ordered) > 14 {
            # long windows: weekly rollup (Mon-aligned) — trajectory, not noise
            day_loads = List.map(ordered, |d| {
                days: Metrics.date_str_to_days(d.day).ok_or(0),
                tss: d.tss,
                ctl: d.ctl,
                atl: d.atl,
                tsb: d.tsb,
            })
            weeks = Metrics.weekly_rollup(day_loads)
            table = render_table(
                ["week of", "sessions", "load", "fitness end (ctl)", "form end (tsb)"],
                List.map(weeks, |w| [
                    Metrics.days_to_date_str(w.week_start),
                    I64.to_str(w.sessions),
                    fmt0(w.tss),
                    fmt0(w.ctl_end),
                    fmt0(w.tsb_end),
                ]),
            )
            legend =
                \\one row per Mon-Sun week — is fitness (ctl) climbing? is weekly load steady or ramping?
                \\(use `stride load 14` or fewer days for the daily view)
            "${table}\n\n${verdict}\n\n${legend}"
        } else {
            table = render_table(
                ["day", "load", "fitness (ctl)", "fatigue (atl)", "form (tsb)"],
                List.map(ordered, |d| [
                    d.day,
                    (if d.tss >= 1.0 fmt0(d.tss) else "rest"),
                    fmt0(d.ctl),
                    fmt0(d.atl),
                    fmt0(d.tsb),
                ]),
            )
            legend =
                \\load:           training load the day added (power TSS, HR, or sRPE — see doctor)
                \\fitness (ctl):  long-term base, 42d avg — want it climbing slowly
                \\fatigue (atl):  short-term tiredness, 7d avg — spikes after big days, fades with rest
                \\form (tsb):     fitness - fatigue (same day) — negative = fatigued,
                \\                positive = fresh; a hard session drops it the same day
            "${table}\n\n${verdict}\n\n${legend}"
        }
    }

    # ── power-duration curve screen ─────────────────────────────────────
    power_curve_screen : { window_days : U64, sport : Str, points : List({ dur_s : U64, watts : F64 }), cp : F64, w_prime : F64 } -> Str
    power_curve_screen = |pc| {
        dur_label = |s|
            if s < 60 "${U64.to_str(s)}s"
            else if s % 60 == 0 "${U64.to_str(s // 60)}m"
            else "${U64.to_str(s // 60)}m${U64.to_str(s % 60)}s"
        sport_lbl = if pc.sport == "" "all power sports" else pc.sport
        header = "power-duration curve — ${sport_lbl}, last ${U64.to_str(pc.window_days)} days"
        if List.is_empty(pc.points) {
            "${header}\n\nno power data in this window."
        } else {
            table = render_table(
                ["duration", "best power (W)"],
                List.map(pc.points, |p| [dur_label(p.dur_s), fmt0(p.watts)]),
            )
            cp_line =
                # both must be positive: power_curve! already zeroes a non-positive fit, but
                # gate here too so a stray negative W′ can never print as a real fit
                if pc.cp > 0.0 and pc.w_prime > 0.0
                    "→ Critical Power ${fmt0(pc.cp)} W · W′ ${fmt1(pc.w_prime / 1000.0)} kJ"
                else
                    "→ Critical Power: not enough long-duration (≥5 min) data to fit"
            legend =
                \\best mean-max power held for each duration (the peak across the window).
                \\CP ≈ sustainable aerobic ceiling; W′ = the finite above-CP battery (Joules).
            "${header}\n\n${table}\n\n${cp_line}\n\n${legend}"
        }
    }

    # ── summary command screen ──────────────────────────────────────────
    # renders the human report straight from the summary payload — ONE source of
    # numbers for the whole screen. (No type annotation: the payload is the summary
    # record, typed at the app.roc call site; inference keeps this open.)

    summary_screen = |s| {
        z = s.last_28d
        zone_gap =
            if z.hr_streams > 0 and z.z5_s == 0 {
                ["    ⚠ zone gap: no Z5 heart-rate time in 28 days (could be no hard sessions, or power-based / short intervals that didn't drive HR to Z5)"]
            } else {
                []
            }
        ftp_lines =
            if s.ftp.best_20min_w_60d > 0 {
                ftp_calibration_lines(s.ftp)
            } else {
                []
            }
        zone_lines =
            if z.hr_streams > 0
                ["    time in HR zones: Z1 ${I64.to_str(z.z1_s // 60)}m  Z2 ${I64.to_str(z.z2_s // 60)}m  Z3 ${I64.to_str(z.z3_s // 60)}m  Z4 ${I64.to_str(z.z4_s // 60)}m  Z5 ${I64.to_str(z.z5_s // 60)}m"]
            else
                ["    time in HR zones: unavailable (no detailed HR stream in this window)"]
        polarization_lines =
            if z.intensity_streams > 0
                ["    polarization: ${I64.to_str(z.easy_pct)}% easy (Z1-2) / ${I64.to_str(z.moderate_pct)}% moderate (Z3) / ${I64.to_str(z.hard_pct)}% hard (Z4-5)"]
            else
                ["    polarization: unavailable (requires HR, power, or distance streams)"]
        last7_line =
            if s.last_7d.intensity_streams > 0
                "  last 7 days: ${I64.to_str(s.last_7d.sessions)} sessions · ${fmt1(s.last_7d.moving_time.to_f64() / 3600.0)}h · ${fmt1(s.last_7d.distance_m / 1000.0)} km · ${fmt0(s.last_7d.tss)} load — ${I64.to_str(s.last_7d.easy_pct)}% easy / ${I64.to_str(s.last_7d.moderate_pct)}% moderate / ${I64.to_str(s.last_7d.hard_pct)}% hard"
            else
                "  last 7 days: ${I64.to_str(s.last_7d.sessions)} sessions · ${fmt1(s.last_7d.moving_time.to_f64() / 3600.0)}h · ${fmt1(s.last_7d.distance_m / 1000.0)} km · ${fmt0(s.last_7d.tss)} load — intensity unavailable"
        last_hard_str =
            if s.last_hard_session_date != "" s.last_hard_session_date
            else if z.intensity_streams == 0 "unavailable (no detailed streams)"
            else "none on record"
        sport_lines =
            if List.is_empty(s.sports_28d) []
            else List.concat(
                ["", "  sport mix (28d):"],
                List.map(s.sports_28d, |sport| "    ${sport.sport}: ${I64.to_str(sport.sessions)} sessions · ${fmt1(sport.moving_time.to_f64() / 3600.0)}h · ${fmt1(sport.distance_m / 1000.0)} km · ${fmt0(sport.tss)} load"),
            )
        Str.join_with(
            List.join([
                [
                    "",
                    "── stride report (as of ${s.as_of}) ──────────────────",
                    "",
                    "  fitness (CTL): ${fmt0(s.fitness_ctl)}   fatigue (ATL): ${fmt0(s.fatigue_atl)}   form (TSB): ${fmt0(s.form_tsb)}",
                    # the tag is reconstructed from the pair the payload carries, the same way the
                    # trend clause is: JSON needs a number, the renderer needs to know whether
                    # that number is exact or a floor (#123)
                    "  → form ${fmt0(s.form_tsb)}${form_trend_phrase(if s.form_delta_known Known(s.form_delta_7d) else Unknown)} — ${Metrics.form_label(s.form_tsb)}${band_days_phrase(if s.form_band_days <= 0 Unknown else if s.form_band_days_capped AtLeast(s.form_band_days) else Known(s.form_band_days))}",
                    # Numbers, no verdict: the usual sustainable band is the coach's
                    # knowledge, not the engine's. Signed, because a taper reads negative
                    # and clamping that to 0 would hide a deliberate unload.
                    "  ramp: ${signed(s.ramp_7d)}/wk · ${signed(s.ramp_28d_avg)}/wk over 28d",
                    # CTL starts at zero, so a short history reads LOW rather than unknown and the
                    # form verdict above is drawn from absolute bands that do not apply yet. Say so
                    # here, not only in the JSON — a human reading a confident-looking number has no
                    # other way to know it is still converging.
                    warming_up_note(s.ctl_warming_up, s.load_days),
                    "",
                    "  last 28 days:",
                    "    ${I64.to_str(z.sessions)} sessions · ${fmt1(z.moving_time.to_f64() / 3600.0)}h · ${fmt1(z.distance_m / 1000.0)} km",
                    "    training load: ${fmt0(z.tss)} (${I64.to_str(z.measured_pct)}% measured — rest estimated from HR/RPE; see doctor)",
                ],
                # tier line (#157): descriptive provenance for the load number above
                # it — high = measured power, medium = HR/RPE, low = Strava
                # relative-effort. States the mix, prescribes nothing; absent when
                # the window is empty rather than claiming 0/0/0.
                if z.load_coverage.known {
                    ["    confidence: ${I64.to_str(z.load_coverage.high_pct)}% high · ${I64.to_str(z.load_coverage.medium_pct)}% medium · ${I64.to_str(z.load_coverage.low_pct)}% low"]
                } else {
                    []
                },
                zone_lines,
                polarization_lines,
                zone_gap,
                ftp_lines,
                sport_lines,
                [
                    "",
                    last7_line,
                    "  last hard session (5+ min hard, by power or HR): ${last_hard_str}",
                    # stimulus spacing (#159): counts and a median gap — measurements,
                    # not verdicts; the gap renders only when there is one to state
                    "  hard days: ${I64.to_str(s.hard_days.d14)} in 14d · ${I64.to_str(s.hard_days.d28)} in 28d${if s.hard_days.spacing_known " · median gap ${I64.to_str(s.hard_days.spacing_median_days_28d)}d" else ""}",
                    "  open planned sessions: ${I64.to_str(s.pending_sessions)}",
                ],
            ]),
            "\n",
        )
    }

    ftp_calibration_lines = |ftp|
        [
            "",
            "  FTP (60d): ~${fmt0(ftp.estimated_ftp_w)}W — derived from your best 20-min power ${fmt0(ftp.best_20min_w_60d)}W",
        ]

    # time to exhaustion: the number, and what the model thinks of it
    tte_screen = |p| {
        head = "at ${fmt0(p.watts)}W against CP ${fmt0(p.cp)} (${p.sport_family} fit, W' ${fmt1(p.w_prime / 1000.0)} kJ from ${I64.to_str(p.fit_points)} of the 5/10/20-min bests over ${I64.to_str(p.window_days)}d)"
        # The athlete's own record at or above this power, when it is on file.
        # A model that predicts less than what is already recorded is refuted by
        # its own inputs, and the coach should see that on the same screen as
        # the prediction rather than having to go find it.
        record =
            if p.demonstrated_known {
                on = " · on record: ${fmt0(p.demonstrated_w)}W for ${hms((p.demonstrated_s).round_to_i64_try().ok_or(0))} in this window"
                if p.contradicts_model  "${on} — LONGER than the model predicts, so the fit understates this rider"
                else on
            } else {
                ""
            }
        body =
            if p.status == "below_cp" {
                "  at or below CP the model has no limit — it says indefinitely, which is the model's answer and not your body's${record}"
            } else if p.status == "outside_model" {
                "  ~${hms((p.seconds).round_to_i64_try().ok_or(0))} — OUTSIDE the 2-20min band the model holds in, so read it as a direction rather than a number${record}"
            } else {
                "  ~${hms((p.seconds).round_to_i64_try().ok_or(0))}${record}"
            }
        "${head}\n${body}"
    }

    # ── compare command screen ──────────────────────────────────────────
    # this rolling window vs the prior one, metric by metric, with a signed delta
    # The compare verdict as a PURE producer, extracted so the boundary guard can
    # sweep it (#154) — state words only, never advice.
    compare_verdict : F64, F64, F64, Str -> Str
    compare_verdict = |prior_tss, cur_tss, ctl_d, lab| {
        load_word =
            match Metrics.pct_change(prior_tss, cur_tss) {
                Err(NoBaseline) =>
                    if cur_tss > 0.0 {
                        "load resumed (${fmt0(cur_tss)} TSS vs none the prior ${lab})"
                    } else {
                        "no load recorded either ${lab}"
                    }
                Ok(pct) =>
                    if pct > 10.0 {
                        "load ramping (${fmt0(pct)}%)"
                    } else if pct < -10.0 {
                        "load backed off (${fmt0(pct)}%)"
                    } else {
                        "load steady (${fmt0(pct)}%)"
                    }
            }
        fit_word =
            if ctl_d > 0.5 "fitness building"
            else if ctl_d < -0.5 "fitness slipping"
            else "fitness holding"
        "${load_word} · ${fit_word}"
    }

    compare_screen = |p| {
        c = p.current
        pr = p.prior
        lab = p.window_label
        df = |cur, prev| signed(cur - prev)
        di = |cur, prev| signed(cur.to_f64() - prev.to_f64())
        table = render_table(
            ["metric", "prior ${lab}", "last ${lab}", "Δ"],
            [
                ["load", fmt0(pr.tss), fmt0(c.tss), df(c.tss, pr.tss)],
                ["sessions", I64.to_str(pr.sessions), I64.to_str(c.sessions), di(c.sessions, pr.sessions)],
                ["hard (min)", I64.to_str(pr.hard_min), I64.to_str(c.hard_min), di(c.hard_min, pr.hard_min)],
                ["easy %", I64.to_str(pr.easy_pct), I64.to_str(c.easy_pct), di(c.easy_pct, pr.easy_pct)],
                ["fitness (ctl)", fmt0(pr.ctl), fmt0(c.ctl), df(c.ctl, pr.ctl)],
            ],
        )
        # Match on the baseline rather than defaulting it: with no prior load there is no
        # percentage to state, and the two no-baseline cases read differently — training
        # after nothing is "resumed", nothing after nothing is not a change at all. An
        # earlier version defaulted to 0.0 here and reported the second case as
        # "load steady (0%)", which claims a measurement that was never taken.
        "${table}\n\n→ ${compare_verdict(pr.tss, c.tss, c.ctl - pr.ctl, lab)}"
    }
}

# ── tests ───────────────────────────────────────────────────────────

expect Render.fmt1(12.34) == "12.3"
expect Render.fmt1(9.96) == "10.0"
expect Render.fmt1(0.0) == "0.0"
expect Render.fmt2(0.979) == "0.98"
expect Render.fmt2(1.0) == "1.00"
expect Render.fmt2(1.5) == "1.50"
expect Render.fmt2(-0.5) == "-0.50" # sign survives when the integer part is 0
expect Render.fmt2(-1.25) == "-1.25"
expect Render.fmt0(71.9) == "72"
expect Render.mins(3725) == "62m"
expect Render.pad_right("ab", 4) == "ab  "
expect Render.display_width("██") == 2
expect Render.display_width("abc") == 3
expect Render.display_width("café") == 4 # accented Latin stays width 1 per char
expect Render.display_width("🚴") == 2 # 4-byte emoji is two columns
expect Render.display_width("ab🔥") == 4 # a + b + wide emoji
expect Render.pad_right("██", 4) == "██  "
expect Render.pad_left("7", 3) == "  7"
# ── signed: the sign comes from the value, not from the rounded text ──
expect Render.signed(5.0) == "+5"
expect Render.signed(-3.0) == "-3"
expect Render.signed(0.0) == "+0"
# a magnitude that rounds away is still a direction that did not: a slight unload must
# not print the same as no change at all
expect Render.signed(-0.4) == "-0"
expect Render.signed(0.4) == "+0"
# and the two directions stay symmetric either side of zero
expect Render.signed(-0.4) != Render.signed(0.4)
expect Render.pad_left("1234", 3) == "1234" # never truncates

# ── progress bar ──
expect Render.progress_bar("rescoring", 0, 10) == "rescoring [░░░░░░░░░░]  0/10"
expect Render.progress_bar("rescoring", 5, 10) == "rescoring [█████░░░░░]  5/10"
expect Render.progress_bar("rescoring", 10, 10) == "rescoring [██████████] 10/10"
# a zero total has no honest fraction to render, and must not divide
expect Render.progress_bar("syncing", 0, 0) == "syncing…"
# ...spelled exactly as the machine-mode line, so the two modes cannot drift apart
expect Render.progress_bar("syncing", 0, 0) == Render.progress_line("syncing", 0, 0)
# done > total would overfill the bar; clamp rather than emit a wider frame
expect Render.progress_bar("x", 99, 10) == "x [██████████] 10/10"
# EVERY frame of one run is the same width — `\r` does not clear the line, so a
# shorter frame would leave the previous frame's tail behind it on screen
expect {
    frames = List.map([0, 7, 42, 358, 723], |d| Render.display_width(Render.progress_bar("rescoring", d, 723)))
    List.all(frames, |w| w == List.first(frames).ok_or(0))
}
# machine mode: same information, no carriage return and no padding
expect Render.progress_line("rescoring", 5, 10) == "rescoring 5/10"
expect !(Str.contains(Render.progress_line("rescoring", 5, 10), "\r"))
# ...and it clamps like the bar, so neither mode can print an impossible fraction
expect Render.progress_line("rescoring", 730, 723) == "rescoring 723/723"

# ── rule rows: a full-width divider, not cells ──
expect {
    t = Render.render_table(["a", "b"], [["1", "2"], Render.rule, ["3", "4"]])
    lines = Str.split_on(t, "\n")
    # the rule sits between the two data rows and is drawn with border glyphs, so it
    # matches the header rule exactly rather than containing any cell text
    List.get(lines, 4).ok_or("") == List.get(lines, 2).ok_or("")
}
# a rule row carries no data, so it must not widen a column or leave stray text
expect {
    t = Render.render_table(["a"], [["x"], Render.rule])
    !(Str.contains(t, "__RENDER_RULE__")) and !(Str.contains(t, "···"))
}
# the marker cannot collide with data: a one-column table whose cell holds the OLD
# sentinel text renders it as content, because only a cell-less row is a rule
expect {
    t = Render.render_table(["a"], [["__RENDER_RULE__"]])
    Str.contains(t, "__RENDER_RULE__")
}
# ...and a table with no rule row is completely unchanged by the feature
expect Render.render_table(["a", "b"], [["1", "2"]]) == "╭───┬───╮\n│ a │ b │\n├───┼───┤\n│ 1 │ 2 │\n╰───┴───╯"

# unicode bars must not skew column alignment
expect {
    t = Render.render_table(["v", "x"], [["██", "y"]])
    t == "╭────┬───╮\n│ v  │ x │\n├────┼───┤\n│ ██ │ y │\n╰────┴───╯"
}

expect {
    t = Render.render_table(["a", "bb"], [["x", "y"], ["long", "z"]])
    t == "╭──────┬────╮\n│ a    │ bb │\n├──────┼────┤\n│ x    │ y  │\n│ long │ z  │\n╰──────┴────╯"
}

# a long detail is WORD-WRAPPED across continuation lines — full text kept (first
# and last words both present, no ellipsis), and the row spans more physical lines
# than an unwrapped single-row table would (3 borders + header + 1 data = 5)
expect {
    long = "Long EASY ride 90min-2h outdoor Z2 ONLY conversational the whole way no chasing wheels"
    t = Render.render_table(
        ["day", "date", "type", "status", "detail", "id"],
        [["Sat", "2026-08-08", "endurance", "open", long, "18"]],
    )
    Str.contains(t, "Long EASY ride") and Str.contains(t, "chasing wheels") and List.len(Str.split_on(t, "\n")) > 5
}
# the whole table stays within the budget (the top border spans full width). Asserted
# against the constant, not a literal: hard-coding 80 made this fail the moment the budget
# moved, for no reason other than the number being written down twice.
expect {
    long = "Long EASY ride 90min-2h outdoor Z2 ONLY conversational the whole way no chasing wheels keep it truly easy today"
    t = Render.render_table(
        ["day", "date", "type", "status", "detail", "id"],
        [["Sat", "2026-08-08", "endurance", "open", long, "18"]],
    )
    Render.display_width(List.get(Str.split_on(t, "\n"), 0).ok_or("")) <= Render.max_total
}
# a short cell is rendered whole on one line — exact match proves no wrapping
# #123: the phrase distinguishes an exact streak from a truncated one, and stays silent
# where the number carries no information. The n=1/n=2 pair pins the suppression threshold
# — with only n=0 and n=16 tested, `n <= 1` could drift to `n <= 0` and ship ", 1 days".
expect Render.band_days_phrase(Unknown) == ""
expect Render.band_days_phrase(Known(0)) == ""
expect Render.band_days_phrase(Known(1)) == ""
expect Render.band_days_phrase(Known(2)) == ", 2 days in this band"
expect Render.band_days_phrase(Known(16)) == ", 16 days in this band"
# AtLeast prints a FLOOR. A bare "31" would present the window size as a measurement.
expect Render.band_days_phrase(AtLeast(31)) == ", 31+ days in this band"
expect Render.band_days_phrase(AtLeast(1)) == ""

expect {
    t = Render.render_table(["a"], [["short"]])
    t == "╭───────╮\n│ a     │\n├───────┤\n│ short │\n╰───────╯"
}

expect Render.progress_group_label("Morning Ride", SimilarDistance(31400.0)) == "Morning Ride (~31.4 km rides)"

# EF lens: gap row for >90-day breaks, asked marker, last-vs-best all present
expect {
    pr = |date, ef| { name: "X", date, sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: ef * 100.0, avg_hr: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream", decoupling_pct: 0.0, decoupling_known: False }
    s = Render.progress_section("X", [pr("2025-01-01", 1.5), pr("2025-08-01", 1.2)], "2025-08-01", Ef, Asc)
    Str.contains(s, "···") and Str.contains(s, "2025-08-01 ◀") and Str.contains(s, "below your best") and Str.contains(s, "declining")
}

# a single session states its score and stops: comparing a value to itself yields a real
# 0%, and "holding steady" would read as a measured finding rather than an absent one
expect {
    pr = |date, ef| { name: "X", date, sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: ef * 100.0, avg_hr: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream", decoupling_pct: 0.0, decoupling_known: False }
    s = Render.progress_section("X", [pr("2025-01-01", 1.5)], "2025-01-01", Ef, Asc)
    Str.contains(s, "first session of this workout, nothing to compare against yet") and !(Str.contains(s, "holding steady")) and !(Str.contains(s, "(0%)"))
}

# the best row's value + full 12-block bar stay on ONE line: terse headers keep the
# progress table under render_table's 80-col budget, so the bar column is never the
# widest-column victim of squeeze-and-word-wrap (a split bar reads as broken output)
expect {
    pr = |date, ef| { name: "X", date, sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: ef * 100.0, avg_hr: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream", decoupling_pct: 0.0, decoupling_known: False }
    s = Render.progress_section("X", [pr("2025-01-01", 1.2), pr("2025-02-01", 1.66)], "2025-02-01", Ef, Asc)
    Str.contains(s, "1.66 ████████████")
}

# Desc flips only the DISPLAY order — the newest row prints first (everything before
# the 2025-01-01 row already contains 2025-02-01), while the trend verdict is still
# computed chronologically (1.2 → 1.66 reads as improving, not declining)
expect {
    pr = |date, ef| { name: "X", date, sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: ef * 100.0, avg_hr: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream", decoupling_pct: 0.0, decoupling_known: False }
    s = Render.progress_section("X", [pr("2025-01-01", 1.2), pr("2025-02-01", 1.66)], "2025-02-01", Ef, Desc)
    before_old = List.first(Str.split_on(s, "2025-01-01")).ok_or("")
    Str.contains(before_old, "2025-02-01") and Str.contains(s, "improving")
}

# RPE lens is lower-is-better: RPE dropping 8 -> 6 reads as improving, "above your easiest"
expect {
    pr = |date, rpe| { name: "Lift", date, sport: "WeightTraining", distance_m: 0.0, moving_time: 2700, np_w: 0.0, avg_hr: 0.0, rpe, output_kj: 0.0, tss: 0.0, load_model: "session_rpe", decoupling_pct: 0.0, decoupling_known: False }
    s = Render.progress_section("Lift", [pr("2025-01-01", 8.0), pr("2025-02-01", 6.0), pr("2025-03-01", 7.0)], "2025-03-01", Rpe, Asc)
    Str.contains(s, "│ rpe") and Str.contains(s, "improving") and Str.contains(s, "above your easiest")
}

# short window: daily table, rest rows, verdict; long window: weekly rollup
expect {
    d = |day, tss| { day, tss, ctl: 10.0, atl: 5.0, tsb: 5.0 }
    s = Render.load_screen([d("2025-01-01", 50.0), d("2025-01-02", 0.0)])
    # Both rows sit at tsb 5.0 (Fresh) on consecutive days, and the 2-row series is fully
    # consumed by the streak — so this is the AtLeast path, and it must render the floor
    # marker rather than a bare 2. Without asserting the clause at all, `band = ""` in
    # load_screen passes every test in this file.
    Str.contains(s, "load") and Str.contains(s, "rest") and Str.contains(s, "→ today: form 5")
        and Str.contains(s, ", 2+ days in this band")
}

expect {
    d = |day, tss| { day, tss, ctl: 10.0, atl: 5.0, tsb: 5.0 }
    many = Iter.fold(0.I64..<21, [], |acc, i| List.append(acc, d(Metrics.days_to_date_str(20000 + i), 30.0)))
    Str.contains(Render.load_screen(many), "week of")
}

# power-curve: durations labelled, watts tabled, CP line present when cp fit; empty is graceful
expect {
    s = Render.power_curve_screen({
        window_days: 90,
        sport: "Ride",
        points: [{ dur_s: 5, watts: 800.0 }, { dur_s: 60, watts: 400.0 }, { dur_s: 1200, watts: 260.0 }],
        cp: 250.0,
        w_prime: 20000.0,
    })
    Str.contains(s, "5s") and Str.contains(s, "20m") and Str.contains(s, "Critical Power 250") and Str.contains(s, "Ride")
}
expect {
    s = Render.power_curve_screen({ window_days: 30, sport: "", points: [], cp: 0.0, w_prime: 0.0 })
    Str.contains(s, "no power data") and Str.contains(s, "all power sports")
}

# zone-gap warning fires on 0 Z5; empty last-hard reads as none on record
expect {
    s = {
        as_of: "2025-01-01",
        fitness_ctl: 20.0,
        fatigue_atl: 10.0,
        form_tsb: 10.0,
        form_delta_7d: 5.0,
        form_delta_known: True,
        form_band_days: 16,
        form_band_days_capped: False,
        ramp_7d: 4.0,
        ramp_28d_avg: -1.0,
        load_days: 400,
        ctl_warming_up: False,
        last_28d: { tss: 100.0, z1_s: 600.I64, z2_s: 0.I64, z3_s: 0.I64, z4_s: 0.I64, z5_s: 0.I64, easy_pct: 100.I64, moderate_pct: 0.I64, hard_pct: 0.I64, measured_pct: 100.I64, sessions: 4.I64, moving_time: 7200.I64, distance_m: 30000.0, hr_streams: 4.I64, intensity_streams: 4.I64, load_coverage: { high_pct: 100.I64, medium_pct: 0.I64, low_pct: 0.I64, known: True } },
        last_7d: { tss: 50.0, easy_pct: 100.I64, moderate_pct: 0.I64, hard_pct: 0.I64, sessions: 2.I64, moving_time: 3600.I64, distance_m: 15000.0, hr_streams: 2.I64, intensity_streams: 2.I64 },
        ftp: { best_20min_w_60d: 0.0, estimated_ftp_w: 0.0 },
        last_hard_session_date: "",
        hard_days: { d14: 1.I64, d28: 2.I64, spacing_median_days_28d: 3.I64, spacing_known: True, days_since_last: 0.I64, days_since_known: True },
        pending_sessions: 2.I64,
        sports_28d: [{ sport: "Run", sessions: 4.I64, tss: 100.0, moving_time: 7200.I64, distance_m: 30000.0 }],
    }
    out = Render.summary_screen(s)
    Str.contains(out, "stride report") and Str.contains(out, "zone gap") and Str.contains(out, "none on record")
        # a build and an unload each keep their sign in the same line
        and Str.contains(out, "+4/wk")
        and Str.contains(out, "-1/wk")
        # the verdict carries the trend, not just the band (#111)
        and Str.contains(out, "form 10, up 5 from a week ago")
        # the label NAMES the state and no longer prescribes (#123), and the streak says
        # how long it has held — the thing a band label cannot express
        and Str.contains(out, "fresh, 16 days in this band")
        and !(Str.contains(out, "good day for a big effort"))
}

# #111: too little history says nothing about the trend rather than claiming form is level.
# Asserts the ABSENCE of the clause AND the presence of the rest of the line, so it cannot
# pass by the whole verdict having gone missing.
expect {
    s = {
        as_of: "2025-01-01",
        fitness_ctl: 20.0,
        fatigue_atl: 10.0,
        form_tsb: 10.0,
        form_delta_7d: 0.0,
        form_delta_known: False,
        form_band_days: 0,
        form_band_days_capped: False,
        ramp_7d: 4.0,
        ramp_28d_avg: -1.0,
        load_days: 400,
        ctl_warming_up: False,
        last_28d: { tss: 100.0, z1_s: 600.I64, z2_s: 0.I64, z3_s: 0.I64, z4_s: 0.I64, z5_s: 0.I64, easy_pct: 100.I64, moderate_pct: 0.I64, hard_pct: 0.I64, measured_pct: 100.I64, sessions: 4.I64, moving_time: 7200.I64, distance_m: 30000.0, hr_streams: 4.I64, intensity_streams: 4.I64, load_coverage: { high_pct: 100.I64, medium_pct: 0.I64, low_pct: 0.I64, known: True } },
        last_7d: { tss: 50.0, easy_pct: 100.I64, moderate_pct: 0.I64, hard_pct: 0.I64, sessions: 2.I64, moving_time: 3600.I64, distance_m: 15000.0, hr_streams: 2.I64, intensity_streams: 2.I64 },
        ftp: { best_20min_w_60d: 0.0, estimated_ftp_w: 0.0 },
        last_hard_session_date: "",
        hard_days: { d14: 1.I64, d28: 2.I64, spacing_median_days_28d: 3.I64, spacing_known: True, days_since_last: 0.I64, days_since_known: True },
        pending_sessions: 2.I64,
        sports_28d: [{ sport: "Run", sessions: 4.I64, tss: 100.0, moving_time: 7200.I64, distance_m: 30000.0 }],
    }
    out = Render.summary_screen(s)
    Str.contains(out, "form 10 —") and !(Str.contains(out, "week ago"))
}

# Missing detailed data is unavailable, never a false zero or a bogus Z5 warning.
expect {
    s = {
        as_of: "2025-01-01", fitness_ctl: 20.0, fatigue_atl: 10.0, form_tsb: 10.0,
        form_delta_7d: 0.0, form_delta_known: False, form_band_days: 0, form_band_days_capped: False,
        ramp_7d: 0.0, ramp_28d_avg: 0.0,
        load_days: 400, ctl_warming_up: False,
        last_28d: { tss: 100.0, z1_s: 0.I64, z2_s: 0.I64, z3_s: 0.I64, z4_s: 0.I64, z5_s: 0.I64, easy_pct: 0.I64, moderate_pct: 0.I64, hard_pct: 0.I64, measured_pct: 0.I64, sessions: 4.I64, moving_time: 7200.I64, distance_m: 30000.0, hr_streams: 0.I64, intensity_streams: 0.I64, load_coverage: { high_pct: 0.I64, medium_pct: 0.I64, low_pct: 0.I64, known: False } },
        last_7d: { tss: 50.0, easy_pct: 0.I64, moderate_pct: 0.I64, hard_pct: 0.I64, sessions: 2.I64, moving_time: 3600.I64, distance_m: 15000.0, hr_streams: 0.I64, intensity_streams: 0.I64 },
        ftp: { best_20min_w_60d: 0.0, estimated_ftp_w: 0.0 },
        last_hard_session_date: "", hard_days: { d14: 0.I64, d28: 0.I64, spacing_median_days_28d: 0.I64, spacing_known: False, days_since_last: 0.I64, days_since_known: False }, pending_sessions: 0.I64,
        sports_28d: [{ sport: "Run", sessions: 4.I64, tss: 100.0, moving_time: 7200.I64, distance_m: 30000.0 }],
    }
    out = Render.summary_screen(s)
    Str.contains(out, "time in HR zones: unavailable") and Str.contains(out, "intensity unavailable") and !(Str.contains(out, "zone gap"))
}

# pace: 10km in 3000s = 5:00/km; padded seconds; no distance -> "-"
expect Render.pace_per_km(10000.0, 3000) == "5:00" and Render.pace_per_km(10000.0, 3070) == "5:07" and Render.pace_per_km(0.0, 100) == "-"

# compare table + verdict render; ramp shows in the load word
expect {
    w = |tss, sessions, hard, easy, ctl| { tss, sessions, hard_min: hard, easy_pct: easy, ctl }
    s = Render.compare_screen({ period: "week", window_label: "7d", current: w(227.0, 6.I64, 18.I64, 17.I64, 26.0), prior: w(193.0, 5.I64, 12.I64, 37.I64, 24.0) })
    Str.contains(s, "load") and Str.contains(s, "+34") and Str.contains(s, "ramping") and Str.contains(s, "building")
}

# zero prior TSS must NOT read as "steady 0%" — it's a resumption
expect {
    w = |tss, sessions, hard, easy, ctl| { tss, sessions, hard_min: hard, easy_pct: easy, ctl }
    s = Render.compare_screen({ period: "week", window_label: "7d", current: w(200.0, 4.I64, 10.I64, 40.I64, 20.0), prior: w(0.0, 0.I64, 0.I64, 0.I64, 18.0) })
    Str.contains(s, "load resumed") and !(Str.contains(s, "steady"))
}

# ── interval structure rendering ────────────────────────────────────

# summary uses medians and drops the recovery half when there are no recoveries
expect {
    seg = |o, k, d, v| { ordinal: o, kind: k, start_s: 0.I64, dur_s: d, avg_signal: v, signal: "power", peak_hr: 0.0, avg_hr: 0.0, rec_drop: 0.0, rec_drop_known: False }
    full = Render.interval_summary([seg(0.I64, "warmup", 300.I64, 120.0), seg(1.I64, "work", 181.I64, 251.0), seg(2.I64, "recovery", 120.I64, 100.0), seg(3.I64, "work", 179.I64, 249.0), seg(4.I64, "cooldown", 300.I64, 110.0)])
    lone = Render.interval_summary([seg(0.I64, "work", 1200.I64, 258.0)])
    none = Render.interval_summary([seg(0.I64, "recovery", 600.I64, 100.0)])
    # a recovery-shaped block BEFORE the first work must not become the "easy" half
    pre = Render.interval_summary([seg(0.I64, "recovery", 300.I64, 100.0), seg(1.I64, "work", 1200.I64, 258.0)])
    full == "2×[3:01 @ 251W / 2:00 easy]" and lone == "1×[20:00 @ 258W]" and none == "" and pre == "1×[20:00 @ 258W]"
}

# rep lines carry HR only when measured; drift needs two measured reps
expect {
    seg = |hr, drop_known| { ordinal: 0.I64, kind: "work", start_s: 0.I64, dur_s: 180.I64, avg_signal: 250.0, signal: "power", peak_hr: hr + 8.0, avg_hr: hr, rec_drop: 20.0, rec_drop_known: drop_known }
    with_hr = Render.segments_block([seg(150.0, True)])
    no_hr = Render.segments_block([seg(0.0, False)])
    drift = Render.seg_hr_drift([seg(150.0, True), seg(158.0, True)])
    Str.contains(with_hr, "hr 150 avg / 158 peak") and Str.contains(with_hr, "60s drop +20")
    and !(Str.contains(no_hr, "hr"))
    and drift == Ok(8.0)
    # one measured rep is NOT a drift — Ok(0.0) here would print a fabricated
    # flat-drift verdict on every single-rep session
    and Render.seg_hr_drift([seg(150.0, True)]) == Err(NotEnough)
}

# ── the engine/coach boundary across ALL verdict producers (#154) ────
# Every human verdict line stride renders is state, never advice. Each producer
# is exercised at representative inputs and swept with the shared predicate —
# mutation-tested wording ("you should consider a rest day") fails here.
expect {
    compare_verdicts = [
        Render.compare_verdict(958.0, 1181.0, 6.0, "28d"),
        Render.compare_verdict(1181.0, 900.0, -2.0, "28d"),
        Render.compare_verdict(1000.0, 1030.0, 0.0, "28d"),
        Render.compare_verdict(0.0, 500.0, 3.0, "week"),
        Render.compare_verdict(0.0, 0.0, 0.0, "week"),
    ]
    List.all(compare_verdicts, |v| !(Metrics.has_coaching_language(v)))
}

# tte_screen renders the most opinionated prose in stride ("the model's answer
# and not your body's"), and joined the codebase outside this sweep. All three
# statuses plus both demonstrated-effort branches are state, never advice.
expect {
    tte = |status, dem, contra| Render.tte_screen({
        watts: 265.0,
        seconds: 596.0,
        known: True,
        status,
        cp: 254.0,
        w_prime: 6416.0,
        fit_points: 3.I64,
        window_days: 90.I64,
        sport_family: "Ride",
        demonstrated_s: 600.0,
        demonstrated_w: 271.0,
        demonstrated_known: dem,
        contradicts_model: contra,
    })
    tte_phrases = [
        tte("in_model", False, False),
        tte("in_model", True, True),
        tte("outside_model", True, False),
        tte("below_cp", False, False),
    ]
    List.all(tte_phrases, |p| !(Metrics.has_coaching_language(p)))
    # the hour rollover is what keeps a near-CP query from rendering 222 days
    # as "320807:09" — pinned because mmss is the tempting reuse
    and Render.hms(596.I64) == "9:56"
    and Render.hms(3600.I64) == "1:00:00"
    and Render.hms(8405.I64) == "2:20:05"
}

# the HARD boundary invariant for compare (#154): the verdict templates are a
# CLOSED SET, pinned by full-string equality like form_label — a reworded
# template ("time to push harder") fails HERE even if the denylist misses it.
# One pin per load template, cycling the three fitness words.
expect {
    Render.compare_verdict(1000.0, 1200.0, 6.0, "28d") == "load ramping (20%) · fitness building"
    and Render.compare_verdict(1200.0, 900.0, -2.0, "28d") == "load backed off (-25%) · fitness slipping"
    and Render.compare_verdict(1000.0, 1030.0, 0.0, "28d") == "load steady (3%) · fitness holding"
    and Render.compare_verdict(0.0, 500.0, 3.0, "week") == "load resumed (500 TSS vs none the prior week) · fitness building"
    and Render.compare_verdict(0.0, 0.0, 0.0, "week") == "no load recorded either week · fitness holding"
}

expect {
    trend_phrases = [
        Render.form_trend_phrase(Known(4.2)),
        Render.form_trend_phrase(Known(-8.0)),
        Render.form_trend_phrase(Known(0.0)),
        Render.form_trend_phrase(Unknown),
    ]
    band_phrases = [
        Render.band_days_phrase(Known(3)),
        Render.band_days_phrase(AtLeast(31)),
        Render.band_days_phrase(Unknown),
    ]
    List.all(List.concat(trend_phrases, band_phrases), |p| !(Metrics.has_coaching_language(p)))
}

expect !(Metrics.has_coaching_language(Render.warming_up_note(True, 12))) and !(Metrics.has_coaching_language(Render.warming_up_note(False, 90)))
