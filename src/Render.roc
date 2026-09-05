import Metrics
import Drain

Render :: [].{
    # ── pure text-rendering helpers for human CLI output ────────────────
    # aligned table: headers + rows -> multiline string. Keeps a table within max_total
    # display-columns WITHOUT losing text: columns take natural width; on overflow the
    # single widest column (in practice free text) is squeezed and word-wrapped across
    # continuation lines, character-broken when it has no space to break at.
    #
    # NOT a guarantee: fit_caps squeezes ONE column floored at min_col, so a table
    # whose excess exceeds what that column can surrender still overruns — nothing
    # silently truncates either way. A table needing two columns squeezed needs a
    # narrower design, not a wider budget.
    #
    # 100, not 80: the squeezed column is always the free-text one, so budget spent
    # elsewhere comes out of the workout description. Fixed rather than $COLUMNS:
    # env-dependent output would make the e2e layout assertions unreproducible.
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
    # display-columns. A lone word wider than cap is CHARACTER-BROKEN by hard_break —
    # free text and generated spans (`2021-12-13..2022-02-10`) both produce giant
    # tokens (#194).
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
            # The packer above can only break BETWEEN words, so a space-free token comes out
            # whole and ignores the cap — which made fit_caps' squeeze a no-op for precisely
            # the columns that needed it (#194: a season block is `2021-12-13..2022-02-10`,
            # one token). Breaking every produced line covers the arm that carries an
            # over-long word forward as `cur` too.
            capped = List.join(List.map(final, |line| hard_break(line, cap)))
            if List.is_empty(capped) [""] else capped
        }

    # Split a token that has no break opportunity into cap-wide pieces. Cuts land on
    # CHARACTER boundaries: a UTF-8 continuation byte contributes 0 display width, so it
    # can never trigger a cut and never starts a piece — the same byte classification
    # `display_width` uses, kept in step with it deliberately.
    hard_break : Str, U64 -> List(Str)
    hard_break = |s, cap|
        if cap == 0 or display_width(s) <= cap {
            [s]
        } else {
            st = List.fold(
                Str.to_utf8(s),
                { cur: [], w: 0, out: [] },
                |acc, b| {
                    bw = if b >= 0xF0 2 else if b < 0x80 or b >= 0xC0 1 else 0
                    if bw > 0 and acc.w + bw > cap and !(List.is_empty(acc.cur))
                        { cur: [b], w: bw, out: List.append(acc.out, acc.cur) }
                    else
                        { cur: List.append(acc.cur, b), w: acc.w + bw, out: acc.out }
                },
            )
            pieces = if List.is_empty(st.cur) st.out else List.append(st.out, st.cur)
            List.map(pieces, |bs| Str.from_utf8(bs).ok_or(""))
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

    # A row that renders as a horizontal RULE spanning the whole table — the
    # spreadsheet divider — instead of as cells. It IS a row, so it sits in the rows
    # list: `render_table(headers, [row_a, Render.rule, row_b])`. Drawn with the
    # table's own border glyphs (cell text like `···` reads as data, and collides with
    # `progress`, where `···` means a gap in time). An EMPTY row, not a string
    # sentinel: a sentinel cell in a one-column table would render data as a divider,
    # while a row with no cells cannot collide with anything.
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
        # Wrap ONCE, keeping rule positions inline: one pass, no index bookkeeping, linear
        # whatever the list representation.
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

    # signed(), at the precision the signal is displayed in. A pace delta of
    # -0.04 m/s is the difference between 4:00/km and 4:03/km; through fmt0 it
    # renders as "0" and the column reports no change at all.
    # The session's change from first rep to last, signed so NEGATIVE always means WORSE —
    # weaker watts, or slower pace. Sport-consistent by decision (#351): a cyclist and a
    # runner read the same sign for the same event. The cost is that for pace this is the
    # inverse of raw last-minus-first, since pace counts UP as you slow down, so the legend
    # states what the number is rather than how it was subtracted.
    #
    # Takes both ENDPOINTS, not the delta: pace cannot be derived from a speed difference,
    # because k/v_last - k/v_first is not a function of (v_last - v_first).
    fade_value : [Metric, Imperial], F64, F64, Str -> Str
    fade_value = |units, first, last, signal|
        if signal == "pace" {
            if first <= 0.0 or last <= 0.0 {
                "-"
            } else {
                per = match units {
                    Metric => 1000.0
                    Imperial => 1609.344
                }
                # seconds per unit at each end; slowing means MORE seconds, so first-minus-last
                # is negative exactly when the athlete faded
                d = ((per / first) - (per / last)).round_to_i64_try().ok_or(0)
                if d >= 0 "+${mmss(d)}" else "-${mmss((d).abs())}"
            }
        } else {
            d = last - first
            mag = seg_value(units, (d).abs(), signal)
            if d >= 0.0 "+${mag}" else "-${mag}"
        }

    # The progress trend verdict: a closed set of three, pinned by equality below
    # (ADR 0012). Named rather than inline for exactly that reason — see the pin.
    trend_label : Bool, Bool -> Str
    trend_label = |improved, declined|
        if improved "improving" else if declined "declining" else "holding steady"


    # How long the band has held, appended to the state (#123). Takes the TAG, not a
    # flattened number: the caller must not decide what Unknown means on the renderer's
    # behalf, and AtLeast must not arrive collapsed into an exact-looking integer.
    #
    #   Known(n)   n >= 2  -> ", 12 days in this band"
    #   AtLeast(n) n >= 2  -> ", 31+ days in this band"   the window ran out mid-streak
    #   either,    n <= 1  -> ""                          a one-day streak is noise
    #   Unknown            -> ""                          nothing known about today
    #
    # The `+` is the point of AtLeast reaching this far: `summary` reads a 31-day
    # window, so a 45-day streak truncates, and a bare "31" would present the window
    # size as a measurement.
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

    # ── Units ───────────────────────────────────────────────────────────────────────
    # Storage and every computation stay SI (metres, m/s); these convert at the LAST
    # moment, for human tables only. JSON payloads keep `distance_m` whatever the setting
    # says — the envelope is the coaching agent's contract, and a display preference must
    # not change what a tool reads (#349).
    #
    # 1609.344 is the international mile, exact by definition.
    dist_value : [Metric, Imperial], F64 -> F64
    dist_value = |units, m|
        match units {
            Metric => m / 1000.0
            Imperial => m / 1609.344
        }

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

    # m:ss per km or per mile. Was `pace_per_km`, renamed when it stopped always being
    # per km: a name asserting a unit while returning the other is exactly the drift this
    # codebase keeps paying for.
    pace_per_dist : [Metric, Imperial], F64, I64 -> Str
    pace_per_dist = |units, distance_m, moving_time|
        if distance_m <= 0.0 or moving_time <= 0 {
            "-"
        } else {
            total = (moving_time.to_f64() / dist_value(units, distance_m)).round_to_i64_try().ok_or(0)
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

    # A rep's rate, in the reader's units. Power stays watts; a PACE signal is stored as
    # m/s (SI, like every other distance in the engine) and rendered as time-per-distance,
    # which is what a runner reads. #351: `m/s` was a raw engine value leaking into a human
    # screen — the defect was the QUANTITY, not the unit, so converting it to mph would
    # have preserved the wrong presentation in a new unit.
    #
    # An empty signal keeps fmt2: it means "no signal identified", and inventing a pace for
    # it would assert something the detector did not find.
    pace_from_speed : [Metric, Imperial], F64 -> Str
    pace_from_speed = |units, mps|
        if mps <= 0.0 {
            "-"
        } else {
            per = match units {
                Metric => 1000.0
                Imperial => 1609.344
            }
            mmss((per / mps).round_to_i64_try().ok_or(0))
        }

    seg_unit : [Metric, Imperial], Str -> Str
    seg_unit = |units, signal|
        if signal == "power" {
            "W"
        } else if signal == "pace" {
            match units {
                Metric => "/km"
                Imperial => "/mi"
            }
        } else {
            " m/s"
        }

    # The legend names the unit in prose, where the inline suffix's "/km" would read as
    # "reps ... in /km". Same information, different position, so it gets its own spelling
    # rather than the legend trimming a suffix meant to butt against a number.
    seg_legend_unit : [Metric, Imperial], Str -> Str
    seg_legend_unit = |units, signal|
        if signal == "power" {
            "W"
        } else if signal == "pace" {
            pace_unit(units)
        } else {
            "m/s"
        }

    seg_value : [Metric, Imperial], F64, Str -> Str
    seg_value = |units, v, signal|
        if signal == "power" fmt0(v) else if signal == "pace" pace_from_speed(units, v) else fmt2(v)

    # "4×[3:00 @ 251W / 2:00 easy]" — the detected shape in one line. Reps vary in
    # the wild, so durations/levels are MEDIANS of the work reps; recovery is the
    # median of recovery segments lying BETWEEN the first and last work (a
    # mislabeled pre-work block must not become the "easy" half of a summary).
    # No between-works recoveries (blocks back to back, or a single rep) drops
    # the "/ ..." half.
    interval_summary : [Metric, Imperial], List(SegRow) -> Str
    interval_summary = |units, segs| {
        works = List.keep_if(segs, |s| s.kind == "work")
        n = List.len(works)
        if n == 0 {
            ""
        } else {
            first_work = (List.first(works)).map_ok(|w| w.ordinal).ok_or(0)
            last_work = (List.last(works)).map_ok(|w| w.ordinal).ok_or(0)
            recs = List.keep_if(segs, |s| s.kind == "recovery" and s.ordinal > first_work and s.ordinal < last_work)
            med = |xs| {
                sorted = List.sort_with(xs, |a, b| if a < b Before else if a > b After else Same)
                (List.get(sorted, List.len(sorted) // 2)).ok_or(0.0)
            }
            sig = (List.first(works)).map_ok(|w| w.signal).ok_or("power")
            dur_med = med(List.map(works, |w| ((w.dur_s)).to_f64()))
            level_med = med(List.map(works, |w| w.avg_signal))
            work_part = "${I64.to_str((n).to_i64_wrap())}×[${mmss((dur_med).round_to_i64_try().ok_or(0))} @ ${seg_value(units, level_med, sig)}${seg_unit(units, sig)}"
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
    segments_block : [Metric, Imperial], List(SegRow) -> Str
    segments_block = |units, segs| {
        works = List.keep_if(segs, |s| s.kind == "work")
        lines = List.map_with_index(works, |w, i| {
            base = "rep ${I64.to_str(((i)).to_i64_wrap() + 1)}  ${mmss(w.dur_s)} @ ${seg_value(units, w.avg_signal, w.signal)}${seg_unit(units, w.signal)}"
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

    ## the group label when progress keys on detected structure rather than name: the
    ## shape first, then one anchor-day class name so the reader recognizes the session.
    ## "~" because mates match by duration BAND, not exact duration — the label must not
    ## promise a precision the predicate does not have.
    structure_group_label : I64, I64, Str, Str -> Str
    structure_group_label = |reps, mean_dur, sig, example|
        "${(reps).to_str()}×[~${mmss(mean_dur)}] ${sig} intervals (${example})"

    ## the week-add echo's target clause (#198, ADR 0014) — numbers only. Lives in
    ## Render, not Plan, so the 0012 sweep expect below this module can actually run
    ## over it (Plan.roc is not in the pure-test list).
    target_note : [NoT, T({ reps : I64, dur_s : I64, watts : F64 })] -> Str
    target_note = |pt|
        match pt {
            T(t) => " (target ${(t.reps).to_str()}×${mmss(t.dur_s)} @ ${(t.watts.to_i64_wrap()).to_str()}W)"
            NoT => ""
        }

    ## complete's target-vs-detected clause — numbers on both sides, no verdict:
    ## "did they hit it" is the coach's sentence (ADR 0012, ADR 0014 §4)
    target_match_note : { target_known : Bool, target_reps : I64, target_dur_s : I64, target_watts : F64, detected_known : Bool, detected_reps : I64, detected_mean_dur_s : I64, detected_mean_watts : F64, reps_delta : I64, watts_pct : F64 } -> Str
    target_match_note = |tm|
        if !(tm.target_known) ""
        else if tm.detected_known " (target ${(tm.target_reps).to_str()}×${mmss(tm.target_dur_s)} @ ${(tm.target_watts.to_i64_wrap()).to_str()}W; detected ${(tm.detected_reps).to_str()}×~${mmss(tm.detected_mean_dur_s)} @ ${(tm.detected_mean_watts.to_i64_wrap()).to_str()}W)"
        else " (target ${(tm.target_reps).to_str()}×${mmss(tm.target_dur_s)} @ ${(tm.target_watts.to_i64_wrap()).to_str()}W; no detected power intervals to compare)"

    # display label for a progress group, from anchor_filter's structured kind
    progress_group_label : [Metric, Imperial], Str, [Exact, SimilarDistance(F64), LoneNoDistance] -> Str
    progress_group_label = |units, name, kind|
        match kind {
            Exact => name
            SimilarDistance(m) => "${name} (~${fmt1(dist_value(units, m))} ${dist_unit(units)} rides)"
            LoneNoDistance => "${name} (no distance recorded — can't match similar rides)"
        }

    # ONE number for the operator and for the sentence describing it. `··· = a break
    # over 90 days` is a user-facing claim, and nothing pinned it: the legend could
    # say "over 60 days" with the comparison still at `> 90` and the whole suite
    # stayed green. Deriving both from this constant makes the drift impossible rather
    # than merely detectable. The inclusivity — `>`, so exactly 90 is NOT a break — is
    # pinned in `tests/e2e.roc`, because a constant cannot express it. Comments across
    # the repo quote the literal 90 as history; only the operator and the legend
    # follow this constant, so moving the number means reading those too.
    gap_days : I64
    gap_days = 90

    # one workout's table + trend verdict, rendered through its sport-aware lens
    # (power->EF, distance->speed/HR, rated->RPE; RPE is lower-is-better). The last two
    # parameters are `scope_dropped`/`scope_why`: the caller passes only the SCOPE half
    # of the old `hidden` pair (#286).
    progress_section : [Metric, Imperial], Str, List(Metrics.ProgressRow), Str, [Ef, SpeedHr, Rpe], [Asc, Desc], List(I64), U64, Str -> Str
    progress_section = |units, name, rows, asked, lens, sort, all_days, scope_dropped, scope_why| {
        higher = Metrics.lens_higher_better(lens)
        sc = |row| Metrics.lens_score(lens, row).ok_or(0.0)
        # `rows` arrives BEFORE the lens gate, so the table can show a session the lens
        # cannot score rather than deleting it (#286). Everything that reasons about VALUE
        # — scale, trend, verdict count, last-vs-best — reads `scored_rows`, because
        # `ok_or(0.0)` would fold a 0 into the mean and squash the bars against a floor no
        # session reached.
        scored_rows = List.keep_if(rows, |r| Metrics.lens_score(lens, r).is_ok())
        unscored_n = List.len(rows) - List.len(scored_rows)
        scores = List.map(scored_rows, sc)
        max_s = List.fold(scores, 0.0, |acc, s| acc.max(s))
        min_s = List.fold(scores, max_s, |acc, s| acc.min(s))
        best = if higher max_s else min_s
        worst = if higher min_s else max_s
        pfmt = |v| match lens {
            Rpe => fmt0(v)
            _ => fmt2(v)
        }
        # the SCORED heart rate, not the stored one (#311). This column sits beside
        # `ef`/`spd_hr`, whose legend reads "per heartbeat" — showing 86 next to a score
        # computed from 147.7 makes the legend false with the divisor nowhere on screen.
        # The stored value is still published raw by `activities --json` and `activity`.
        hr_of = |row| if row.avg_hr_scored > 0.0 fmt0(row.avg_hr_scored) else "-"
        prim_of = |row|
            # "-", never `0.00` with an empty bar. A fabricated zero in the lens column is
            # the same class of lie as the fabricated gap this issue opened with: it reads
            # as a measured worst-ever session rather than as an absent measurement, and it
            # would sit in the same column the bars are scaled against.
            if Metrics.lens_score(lens, row).is_err() {
                "-"
            } else {
                n = Metrics.scale_to_blocks(sc(row), worst, best, 12)
                "${pfmt(sc(row))} ${Str.repeat("█", n)}"
            }
        # The ◀ marker rides on the DATE cell, and headers stay terse (meaning lives in
        # the legend, per the numbers-in-tables philosophy) — both keep every column
        # under render_table's column budget so the BAR column is never the widest one
        # that gets squeezed and word-wrapped mid-bar.
        date_of = |row| if row.date == asked "${row.date} ◀" else row.date
        # each lens picks its own columns (list of header + per-row cell); the primary
        # (bar) column direction is already handled by best/worst above
        cols =
            match lens {
                Ef => [
                    # "-" at zero, not `0`: a zero here is UNREACHABLE on a scored row (the EF lens
                    # requires `np_w > 0`), so it can only mean absent, and it only appears on the rows
                    # #286 made render. `kJ` and `load` keep their bare 0 — the file's convention, and
                    # a real value there.
                    ("np (W)", |row| if row.np_w > 0.0 fmt0(row.np_w) else "-"),
                    ("hr", hr_of),
                    ("ef", prim_of),
                    # aerobic decoupling per session (#135) — "-" when not computable,
                    # never a fabricated 0 (0.0 is a real, perfect result)
                    ("drift", |row| if row.decoupling_known "${signed(row.decoupling_pct)}%" else "-"),
                    ("kJ", |row| fmt0(row.output_kj)),
                    ("load", |row| fmt0(row.tss)),
                ]
                SpeedHr => [
                    ("pace (${pace_unit(units)})", |row| pace_per_dist(units, row.distance_m, row.moving_time)),
                    ("hr", hr_of),
                    ("spd/hr", prim_of),
                    ("drift", |row| if row.decoupling_known "${signed(row.decoupling_pct)}%" else "-"),
                    # same rule: the speed/HR lens requires `distance_m > 0`, so 0.0 km on
                    # a row it refused is an absence rather than a measurement
                    (dist_unit(units), |row| if row.distance_m > 0.0 fmt1(dist_value(units, row.distance_m)) else "-"),
                    ("load", |row| fmt0(row.tss)),
                ]
                Rpe => [
                    # "-" at zero here too, but NOT for the neighbours' reason: `lens_score(Rpe, r)`
                    # requires only `rpe > 0`, so a fully SCORED row can carry duration 0 and render a
                    # full bar beside this cell. `0m` was never a measurement either way; the blank is
                    # right, the justification is different.
                    ("duration", |row| if row.moving_time > 0 mins(row.moving_time) else "-"),
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
                # ...against the UNFILTERED series, not the rows that survived the lens. Folding
                # the gap over the filtered list merges the intervals either side of a dropped ride
                # and announces a break that did not happen — and the legend prints "a break over N
                # days", a claim about TRAINING, so the artifact is a false statement rather than
                # an ambiguous glyph. In production `rows` and `all_days` describe the same set
                # (#286 made unscorable rows render; a scope drop removes the row from both), so
                # the fold is an identity there — it stays because it already handles the moment
                # the two lists diverge. N is `gap_days`, shared with the comparison below (#302),
                # so the printed threshold cannot drift from the tested one.
                with_gap =
                    if acc.prev > -1000000 and Metrics.max_real_gap(all_days, acc.prev, days) > gap_days {
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
        label = trend_label(improved, declined)
        # Sessions absent from the table are absent from every figure on this line too, and
        # saying so is the difference between a filtered view and a wrong one.
        #
        # TWO clauses, because after #286 the two causes have different OUTCOMES: a scope
        # drop is still HIDDEN (a different distance, not in this table), while a lens drop
        # is SHOWN with its lens cells blank — calling it hidden while the reader looks at
        # the row would be the contradiction this issue opened with. The SCOPE reason
        # arrives from the caller (only the anchor filter can tell its two truncation kinds
        # apart); the LENS reason derives here, where the count it must agree with is
        # counted. The counts match the payload's `hidden_scope`/`hidden_lens` exactly;
        # only the verb differs — the agent reading `sessions[]` genuinely cannot see those
        # rows, and the athlete can.
        scope_clause =
            if scope_dropped == 0 {
                ""
            } else {
                "${U64.to_str(scope_dropped)} hidden: ${scope_why}"
            }
        unscored_clause =
            if unscored_n == 0 {
                ""
            } else {
                "${U64.to_str(unscored_n)} shown unscored: ${Metrics.lens_needs(lens, unscored_n != 1)}"
            }
        # ONE parenthetical holding both clauses, not two side by side. Two adjacent parens
        # read as two afterthoughts about unrelated things, and these are the two halves of
        # one fact: what happened to the sessions that are not in the trend.
        hidden_note =
            if Str.is_empty(scope_clause) and Str.is_empty(unscored_clause) {
                ""
            } else if Str.is_empty(unscored_clause) {
                " (${scope_clause})"
            } else if Str.is_empty(scope_clause) {
                " (${unscored_clause})"
            } else {
                " (${scope_clause}; ${unscored_clause})"
            }
        avg = Metrics.mean(scores)
        short = match lens {
            Ef => "ef"
            SpeedHr => "aero-eff"
            Rpe => "rpe"
        }
        legend = match lens {
            Ef => "ef = normalized power (np) / avg HR — watts per heartbeat, climbing = fitter · drift = aerobic decoupling, 2nd half vs 1st — LOWER is better, - = not computable · kJ = total work"
            SpeedHr => "spd/hr (aero-eff) = speed per heartbeat — climbing = fitter · drift = aerobic decoupling, 2nd half vs 1st — LOWER is better, - = not computable · pace is ${pace_unit(units)}"
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
            if List.len(scored_rows) == 1 and scope_dropped == 0 and unscored_n == 0 {
                # "one comparable session" read as though it were pointing at some OTHER
                # session to compare with. The single row IS this session — there is simply
                # no history behind it yet (#96).
                "→ ${short} ${pfmt(avg)} — first session of this workout, nothing to compare against yet"
            } else if List.len(scored_rows) == 1 {
                # ...but only when there IS no history. `hidden_note` once reached the multi-row
                # arm alone, so a workout whose lens could score exactly one session claimed
                # "first session, nothing to compare against yet" over ELEVEN sessions, ten
                # unrated (#291) — asserting the absence is worse than the silence it replaced.
                "→ ${short} ${pfmt(avg)} — the only session shown${hidden_note}; the rest are in your log"
            } else {
                "→ ${short} early avg ${pfmt(t.early)} → recent avg ${pfmt(t.late)} (overall avg ${pfmt(avg)}) over ${U64.to_str(List.len(scored_rows))} sessions${hidden_note} — ${label}${pct_str}"
            }
        footer = "${legend}\nbar = scaled worst→best · ◀ marks the asked date · ··· = a break over ${I64.to_str(gap_days)} days"
        "── ${name} ──\n${table}\n\n${verdict}${last_vs_best(scored_rows, lens)}\n\n${footer}"
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
            if x < y Before else if x > y After else Same
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

    # ── stream-drain note, used by sync's human line ─────────────────────
    # Takes the TAG, not the payload's string. Matching three literals with a catch-all
    # stated the handled set in a different file from the set that exists: add a stop
    # reason, satisfy every compile error, and the user still got the raw wire token.
    # With a StopReason argument a new reason is a non-exhaustive match HERE, and the
    # branch you are forced to write is the branch that runs.
    drain_note : Drain.StopReason, I64 -> Str
    drain_note = |stopped, pending|
        # `pending` is tested first for MOST reasons, and the exception is the point.
        # For Complete, BudgetReached and RateLimited an empty queue means nothing is left
        # to do regardless of why the run ended (a budget stop that empties the queue is
        # reachable). DailyCapReached is NOT one of those: its refusal arrives having made
        # no request, so an empty queue says nothing about whether work remains.
        #
        # Each arm states its OWN empty-queue behaviour rather than sharing one test above
        # the match — the shared test was wrong for one of four reasons, and a `_` to carve
        # that one out gives back exactly the exhaustiveness this type exists to buy.
        match stopped {
            # The ONLY way to drain the queue and still be pending: a stream body
            # that would not decode is skipped WITHOUT storing, so it retries next
            # run. A 404 is NOT this case — it stores a `{}` marker and leaves the
            # pending set at once, which is why "Strava has no streams for these" is
            # the wrong sentence here however plausible it sounds.
            Complete => if pending == 0 "" else "${I64.to_str(pending)} had unreadable stream data — they retry next sync"
            BudgetReached => if pending == 0 "" else "filled Strava's 15-minute read window — ${I64.to_str(pending)} to go, run `stride sync` again in ~15 minutes"
            RateLimited => if pending == 0 "" else "Strava rate-limited this run — ${I64.to_str(pending)} to go, try again in ~15 minutes"
            # the ONE stop whose remedy is not fifteen minutes: Strava's daily read cap resets
            # at UTC midnight, so re-running sooner spends nothing and gets nothing (#246).
            #
            # And the ONE stop that speaks on an EMPTY queue: the pre-flight refusal arrives
            # having made no request, so "all streams present" would be a claim about state
            # the run never looked at — and silence let `stride sync` print a quiet
            # successful-looking line and exit 0 on a day where nothing more would happen.
            DailyCapReached =>
                if pending == 0 {
                    "used up today's Strava read allowance — nothing was fetched, and nothing will be until it resets; run `stride sync` again tomorrow"
                } else {
                    "used up today's Strava read allowance — ${I64.to_str(pending)} to go, run `stride sync` again tomorrow"
                }
        }

    # `plan`'s data-freshness line (#221). "" when there is nothing to say, on the same
    # reasoning as sync_screen's tail below: for a human the absence of the line IS the
    # clean signal, and printing two zeros before every planning session trains the eye to
    # skip the row that matters on the day it is not zero.
    #
    # Deliberately NOT triggered by newest_activity lagging as_of. That is true most
    # mornings — the day's ride has not happened yet — so it would fire almost daily and
    # become the noise this guards against. The machine payload carries both dates and a
    # coach can compare them; a human already knows whether they rode today.
    #
    # Each clause names the command that clears it. A count with no next action is the
    # thing the reader has to go look up, which is where a freshness signal stops being
    # used at all.
    freshness_note : { activities_awaiting_metrics : U64, activities_awaiting_metrics_known : Bool, activities_awaiting_streams : I64 } -> Str
    freshness_note = |f| {
        # An unknowable count is NOT silence: the count is 0 in that case, and staying
        # quiet renders as "nothing to do" — the ambiguous zero `*_known` exists to avoid.
        # `analyze` is named because it is the command that fails with the underlying
        # reason. "count", not "queue": what could not be read is the zone config, and
        # "metrics queue unreadable" sends a reader hunting for database damage.
        metrics_note =
            if !(f.activities_awaiting_metrics_known) {
                ["awaiting-metrics count unreadable (stride analyze says why)"]
            } else if f.activities_awaiting_metrics > 0 {
                ["${U64.to_str(f.activities_awaiting_metrics)} awaiting metrics (stride analyze)"]
            } else {
                []
            }
        streams_note =
            if f.activities_awaiting_streams > 0 {
                ["${I64.to_str(f.activities_awaiting_streams)} awaiting streams (stride sync)"]
            } else {
                []
            }
        parts = List.concat(metrics_note, streams_note)
        if List.is_empty(parts) "" else "DATA: ${Str.join_with(parts, " · ")}"
    }

    # sync's human line. Extracted from an inline closure in Strava.roc so pure expects
    # can reach it (#232). Takes the payload AND the tag it was built from: `p.stopped`
    # is the WIRE string (sync.json is a flat enum) and nothing here reads it —
    # recovering the tag from it was a lookup a maintainer can leave stale, shipping
    # the raw token. Passed alongside, a new reason is a non-exhaustive match here and
    # in drain_note, and the branch you are made to write is the branch that runs.
    #
    # DO NOT, not CANNOT: the signature takes payload and tag independently, so a
    # caller CAN pass a mismatched pair. Both producer sites bind the tag once and
    # derive `stopped:` from that binding — that is discipline, not enforcement, and a
    # third caller has to keep it.
    sync_screen : { synced : U64, new_activities : U64, updated_activities : U64, pruned : U64, streams_fetched : I64, streams_skipped : I64, pending_streams : I64, stopped : Str, resumable : Bool }, Drain.SyncStop, Bool -> Str
    sync_screen = |p, stop, all| {
        prune_note = if p.pruned > 0 " (pruned ${U64.to_str(p.pruned)} removed on Strava)" else ""
        # Said plainly rather than folded into the pending count: unreadable is not
        # not-yet-fetched, and only the first is worth chasing. Suppressed on a complete
        # run because drain_note's Complete arm is only reachable with pending > 0 —
        # precisely the skip case — so both clauses would state one fact twice.
        #
        # `skip_for_reason`, not `stop != FromDrain(Complete)`: the question is "does this
        # reason's own note already state the skip count", a property of the REASON. An
        # inequality against a literal tag was the last reason-shaped test outside an
        # exhaustive match — a new reason took the print branch by default and the clause
        # printed twice in two wordings. The match returns the CLAUSE, not a boolean, so a
        # new reason must answer.
        skip_clause = " (${I64.to_str(p.streams_skipped)} had unreadable stream data)"
        skip_for_reason : Drain.StopReason -> Str
        skip_for_reason = |r|
            match r {
                # Complete's own note names the skipped count, so repeating it here is the
                # duplication these lines exist to prevent.
                Complete => ""
                BudgetReached => skip_clause
                RateLimited => skip_clause
                DailyCapReached => skip_clause
            }
        skip_note =
            if p.streams_skipped > 0 {
                match stop {
                    FromDrain(r) => skip_for_reason(r)
                    ListRateLimited => skip_clause
                    ListDailyCapReached => skip_clause
                }
            } else {
                ""
            }
        # WHY it stopped, not merely that work remains. A refused LIST is tested FIRST and
        # unconditionally: a first-run sync lists a full page of stream-less activities and
        # is refused on the next page, so pending is at its MAXIMUM there — guarding this
        # behind `pending_streams > 0` let drain_note win and describe a stream drain that
        # never started. The queue is only empty in the steady state.
        tail =
            match stop {
                ListRateLimited => {
                    # read from `pruned`, not from `stopped`. Prune is unreachable on this
                    # path today — sync! returns before it — but that is a fact about
                    # Strava.sync!, and this function can only see what it is handed.
                    # Asserting it from here would be Render vouching for a caller it
                    # never observes, and the sentence would go quietly false the day the
                    # early return moves.
                    prune_claim = if p.pruned == 0 "; nothing was pruned" else ""
                    " — Strava rate-limited the activity list, so it is incomplete${prune_claim}. Run `stride sync` again in ~15 minutes"
                }
                # A MATCH on the TAG, no catch-all — that IS the enforcement: add an arm to
                # SyncStop and this stops compiling; add one to StopReason and drain_note does.
                # What matters is that the branch the compiler makes you write is the branch that
                # RUNS. The earlier shapes failed exactly that: `==` against a literal, and a
                # Str->tag lookup which compiled after a new arm yet still shipped the raw
                # `auth_expired` token, because the lookup table had no entry. Deleting the lookup
                # is what closes it.
                ListDailyCapReached =>
                    # UNCONDITIONAL, like its sibling above and for one more reason: this stop is
                    # reachable with an empty queue by construction — a capped day is exactly the day
                    # nothing is left to drain. `prune_claim` READ, not assumed (see the sibling);
                    # computed here rather than hoisted, because the two arms are the only users and
                    # hoisting would put a binding in scope for the FromDrain arm that must never
                    # read it.
                    {
                        cap_prune_claim = if p.pruned == 0 "; nothing was pruned" else ""
                        " — Strava rate-limited the activity list, so it is incomplete${cap_prune_claim}; and today's read allowance is used up. Run `stride sync` again tomorrow"
                    }
                FromDrain(r) =>
                    # UNCONDITIONAL. Whether a reason has anything to say on an empty queue is a
                    # property of the REASON, so `drain_note` answers it per arm, exhaustively, and
                    # this site only formats. Answering it here went wrong twice: a
                    # `pending_streams > 0` guard made a capped day print a quiet successful-looking
                    # sync (no request made, none possible), and the fix's `match` needed a `_` — under
                    # which a fifth StopReason produced compile errors at two OTHER sites and none
                    # here, so a new reason printed no remedy at all, compiler silent, suite green.
                    {
                        note = drain_note(r, p.pending_streams)
                        if Str.is_empty(note) "" else " — ${note}"
                    }
            }
        # `--all` re-listed the ENTIRE account, so naming the rolling window there would
        # describe a bound the run did not have.
        window_note = if all "" else " in the 30-day window"
        # New and updated FIRST, re-checked in parentheses behind them: the old line led
        # with the re-listed count, which is a function of how often you train rather than
        # of this sync, and reading "synced 22 activities" as 22 NEW ones is the question
        # it kept provoking (#112).
        "synced ${U64.to_str(p.new_activities)} new, ${U64.to_str(p.updated_activities)} updated (${U64.to_str(p.synced)} re-checked${window_note})${prune_note}, fetched streams for ${I64.to_str(p.streams_fetched)}${skip_note}${tail}"
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
    power_curve_screen : { window_days : U64, sport : Str, points : List({ dur_s : U64, watts : F64 }), cp : F64, w_prime : F64, fit_r2 : F64, fit_points : I64 } -> Str
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
            # the fit's own quality, on the command that PUBLISHES the fit --
            # without it a 0.72 fit and a perfect one read identically, while
            # the skill tells the coach to weigh the fit first. At exactly two
            # points a line is exact, so r2 is 1 by construction and would be
            # false reassurance; below that there is no fit and it is 0.
            quality =
                if pc.fit_points >= 3.I64 {
                    " · fit r2 ${fmt2(pc.fit_r2)} from ${I64.to_str(pc.fit_points)} bests"
                } else {
                    " · from ${I64.to_str(pc.fit_points)} bests (r2 needs 3)"
                }
            cp_line =
                # both must be positive: power_curve! already zeroes a non-positive fit, but
                # gate here too so a stray negative W′ can never print as a real fit
                if pc.cp > 0.0 and pc.w_prime > 0.0
                    "→ Critical Power ${fmt0(pc.cp)} W · W′ ${fmt1(pc.w_prime / 1000.0)} kJ${quality}"
                else
                    "→ Critical Power: not enough long-duration (≥5 min) data to fit"
            legend =
                \\best mean-max power held for each duration (the peak across the window).
                \\CP ≈ sustainable aerobic ceiling; W′ = the finite above-CP battery (Joules).
            "${header}\n\n${table}\n\n${cp_line}\n\n${legend}"
        }
    }


    # Critical speed's screen (#188). Takes units as a PARAMETER rather than reading a
    # field off the payload: the payload is SI end-to-end (cs in m/s, d_prime in metres)
    # and must not move with the setting, so pace_curve! passes units through a closure
    # and only this function converts.
    #
    # CS prints as a PACE, not as a converted speed. It is a running number and runners
    # read 4:00/km, not 4.17 m/s or 9.3 mph — rendering it as a speed would repeat the
    # defect #351 fixed on the segment screens.
    pace_curve_screen : [Metric, Imperial], { window_days : U64, sport : Str, points : List({ dur_s : U64, speed : F64 }), cs : F64, d_prime : F64, fit_r2 : F64, fit_points : I64, available_sports : List(Str) } -> Str
    pace_curve_screen = |units, pc| {
        dur_label = |s|
            if s < 60 "${U64.to_str(s)}s"
            else if s % 60 == 0 "${U64.to_str(s // 60)}m"
            else "${U64.to_str(s // 60)}m${U64.to_str(s % 60)}s"
        sport_lbl = pc.sport
        header = "speed-duration curve — ${sport_lbl}, last ${U64.to_str(pc.window_days)} days"
        # No sport named means no fit, deliberately. Pooling every sport that stores a speed
        # would fit ONE curve through unrelated populations — and because analyze writes the
        # speed ladder for anything with a distance stream, that population is mostly RIDES,
        # so the pooled answer came back at bike speed while the screen called it "all pace
        # sports" and SKILL.md told the reading agent to render it as a running pace. The
        # ADR 0002 amendment this command already follows for its WHERE clause says the same
        # thing: a pool swim, an open-water swim and a trail run do not share a speed model.
        # So name the sports that actually hold data rather than inventing a cross-sport one.
        if Str.is_empty(pc.sport) {
            listed = if List.is_empty(pc.available_sports) "none in this window" else Str.join_with(pc.available_sports, ", ")
            "speed-duration curve — last ${U64.to_str(pc.window_days)} days\n\ncritical speed is per-sport: a pool swim, an open-water swim and a trail run\ndo not share a speed model, so there is no combined curve to draw.\n\nname one — sports with speed data in this window: ${listed}\n\n  stride pace-curve ${U64.to_str(pc.window_days)} <sport>"
        } else if List.is_empty(pc.points) {
            "${header}\n\nno pace data in this window."
        } else {
            table = render_table(
                ["duration", "best pace (${pace_unit(units)})"],
                List.map(pc.points, |p| [dur_label(p.dur_s), pace_from_speed(units, p.speed)]),
            )
            # suppressed below 3 points, for the reason power_curve_screen gives.
            quality =
                if pc.fit_points >= 3.I64 {
                    " · fit r2 ${fmt2(pc.fit_r2)} from ${I64.to_str(pc.fit_points)} bests"
                } else {
                    " · from ${I64.to_str(pc.fit_points)} bests (r2 needs 3)"
                }
            # D' is a DISTANCE, so it converts to yards rather than to miles: the value is
            # a couple of hundred metres and "0.12 mi" would be unreadable at that size.
            dprime =
                match units {
                    Metric => "${fmt0(pc.d_prime)} m"
                    Imperial => "${fmt0(pc.d_prime * 1.0936133)} yd"
                }
            cs_line =
                # both must be positive: pace_curve! already zeroes a non-positive fit, but
                # gate here too so a stray negative D′ can never print as a real fit
                if pc.cs > 0.0 and pc.d_prime > 0.0
                    "→ Critical Speed ${pace_from_speed(units, pc.cs)} ${pace_unit(units)} · D′ ${dprime}${quality}"
                else
                {
                        # THREE causes, and they are not interchangeable. Too few rungs is a DATA
                        # gap. Rungs that hold or rise with duration are a curve no athlete
                        # produces, so the model declines rather than fudges. And a curve that
                        # descends so steeply the fitted ceiling lands below zero is refused for a
                        # third reason entirely — the bests are real and ordered, they just cannot
                        # come from one athlete's 2-parameter model.
                        #
                        # The payload cannot tell these apart: `cs` and `d_prime` are 0 in all
                        # three. The points can, and the screen has them — so the shape of the
                        # ladder decides which sentence is true, rather than one sentence covering
                        # cases it does not describe. A reader seeing three descending durations
                        # above "these bests do not descend" learns to distrust the line.
                        # Strictly decreasing speed as duration grows. Seeded above any real
                        # speed so the first rung always passes; a human sprints nowhere near
                        # 1000 m/s.
                        descending =
                            (List.fold(
                                pc.points,
                                { ok: True, prev: 1000.0 },
                                |a, p| { ok: a.ok and p.speed < a.prev, prev: p.speed },
                            )).ok
                        if pc.fit_points < 2.I64
                            "→ Critical Speed: needs two ladder durations with data, at different lengths"
                        else if !(descending)
                            "→ Critical Speed: these bests hold or rise with duration, so no fit is possible"
                        else
                            "→ Critical Speed: these bests fall too steeply to fit one athlete's curve"
                }
            legend =
                \\best mean-max grade-adjusted pace held for each duration (the peak across the window).
                \\CS ≈ sustainable ceiling; D′ = the finite above-CS distance battery.
            "${header}\n\n${table}\n\n${cs_line}\n\n${legend}"
        }
    }
    # ── summary command screen ──────────────────────────────────────────
    # renders the human report straight from the summary payload — ONE source of
    # numbers for the whole screen. (No type annotation: the payload is the summary
    # record, typed at the app.roc call site; inference keeps this open.)

    summary_screen = |units, s| {
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
                "  last 7 days: ${I64.to_str(s.last_7d.sessions)} sessions · ${fmt1(s.last_7d.moving_time.to_f64() / 3600.0)}h · ${fmt1(dist_value(units, s.last_7d.distance_m))} ${dist_unit(units)} · ${fmt0(s.last_7d.tss)} load — ${I64.to_str(s.last_7d.easy_pct)}% easy / ${I64.to_str(s.last_7d.moderate_pct)}% moderate / ${I64.to_str(s.last_7d.hard_pct)}% hard"
            else
                "  last 7 days: ${I64.to_str(s.last_7d.sessions)} sessions · ${fmt1(s.last_7d.moving_time.to_f64() / 3600.0)}h · ${fmt1(dist_value(units, s.last_7d.distance_m))} ${dist_unit(units)} · ${fmt0(s.last_7d.tss)} load — intensity unavailable"
        last_hard_str =
            if s.last_hard_session_date != "" s.last_hard_session_date
            else if z.intensity_streams == 0 "unavailable (no detailed streams)"
            else "none on record"
        sport_lines =
            if List.is_empty(s.sports_28d) []
            else List.concat(
                ["", "  sport mix (28d):"],
                List.map(s.sports_28d, |sport| "    ${sport.sport}: ${I64.to_str(sport.sessions)} sessions · ${fmt1(sport.moving_time.to_f64() / 3600.0)}h · ${fmt1(dist_value(units, sport.distance_m))} ${dist_unit(units)} · ${fmt0(sport.tss)} load"),
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
                    "    ${I64.to_str(z.sessions)} sessions · ${fmt1(z.moving_time.to_f64() / 3600.0)}h · ${fmt1(dist_value(units, z.distance_m))} ${dist_unit(units)}",
                    "    training load: ${fmt0(z.tss)} (${I64.to_str(z.measured_pct)}% measured by power or pace — rest estimated from HR/RPE; see doctor)",
                ],
                # tier line (#157): descriptive provenance for the load number above
                # it — high = measured power OR distance-measured pace, medium = HR/RPE,
                # low = Strava relative-effort. States the mix, prescribes nothing; absent when
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
    # ── season screen (#139, ADR 0011) ──────────────────────────────────
    # Blocks bounded by absence, described by measurement. No phase names; the trend is
    # a fitted line reported by its ENDPOINTS, because a slope plus a low r2 gets read
    # as "no trend" and r2 is scatter, not evidence the slope is zero.
    #
    # Held under the 100-column budget (it shipped at 126, the CLI's only violator).
    # The block TOTAL and SLOPE moved to the payload; the total is recoverable from the
    # row (/wk x span) but the SLOPE is NOT — its divisor is the ordinal distance
    # between fitted endpoints, which equals span_weeks - 1 only while the last week is
    # complete, so dividing visible cells is off by 6-17%.
    season_screen = |p| {
        block_rows = List.map(p.blocks, |b| {
            trend = if b.trend_known "${fmt0(b.fitted_start_load)}→${fmt0(b.fitted_end_load)}" else "-"
            r2c = if b.trend_known fmt2(b.trend_r2) else "-"
            pol = if b.polarization_known "${I64.to_str(b.easy_pct)}/${I64.to_str(b.moderate_pct)}/${I64.to_str(b.hard_pct)}" else "-"
            # the share is named when the "dominant" family is close to a coin
            # flip, because 52% and 95% published identically
            share = if b.ftp_known and b.ftp_family_pct < 65.I64 " ${I64.to_str(b.ftp_family_pct)}%" else ""
            ftp = if b.ftp_known "${b.ftp_family}${share} ${ftp_path(b.ftp_start, b.ftp_end, b.ftp_lo, b.ftp_hi)}" else "-"
            # the * marks the WEEK COUNT, not the end date -- glued to the date
            # it read as "approximately 08-16", not "this block is still open"
            # (issue-claims: quoting -- that phrase is rendered output, not an issue state)
            wks = "${I64.to_str(b.weeks)}/${I64.to_str(b.span_weeks)}"
            wk = if b.closed wks else "${wks}*"
            ["${b.start_date}..${b.end_date}", wk, I64.to_str(b.sessions), fmt0(b.mean_weekly_load), trend, r2c, pol, ftp]
        })
        block_body =
            if List.is_empty(p.blocks) {
                # an empty table frame plus a legend explaining what a block is,
                # on a screen with no blocks, is what this replaces
                "no training blocks yet — there are scored days on record but none carry load; `stride analyze` rebuilds them"
            } else {
                render_table(["block", "wk", "sess", "/wk", "trend", "r2", "e/m/h", "ftp"], block_rows)
            }
        # 13, not 12: twelve is the one count that hides the same month a year
        # ago, which is the obvious question to ask of a month table
        recent = if List.len(p.months) > 13 List.drop_first(p.months, List.len(p.months) - 13) else p.months
        month_hdr =
            if List.len(p.months) > List.len(recent) {
                "── by month · last ${I64.to_str((List.len(recent)).to_i64_wrap())} of ${I64.to_str((List.len(p.months)).to_i64_wrap())} ──"
            } else {
                "── by month ──"
            }
        month_rows = List.map(recent, |m| {
            mshare = if m.ftp_known and m.ftp_family_pct < 65.I64 " ${I64.to_str(m.ftp_family_pct)}%" else ""
            [
                if m.partial "${m.month}*" else m.month,
                fmt0(m.load),
                I64.to_str(m.sessions),
                if m.ftp_known "${m.ftp_family}${mshare} ${ftp_path(m.ftp_start, m.ftp_end, m.ftp_lo, m.ftp_hi)}" else "-",
            ]
        })
        month_tbl = render_table(["month", "load", "sessions", "ftp"], month_rows)
        # Topic lines, not one 690-character paragraph: at that length the definitions a
        # reader needs are exactly the ones they skip.
        legend = Str.join_with(
            [
                "a block is a run of training weeks closed by ${I64.to_str(p.gap_weeks)}+ weeks with no load — described by measurement, never named as a phase",
                "wk = weeks trained / calendar weeks spanned · sess = activities · /wk = load over the span",
                "trend = where the fitted line starts and ends · r2 = how much of the week-to-week scatter it explains",
                "a LOW r2 means the weeks were SCATTERED, not that there was no trend · e/m/h = easy/moderate/hard time %",
                "ftp = the period's FIRST and LAST recorded threshold, with its peak or trough between them when it went outside both",
                "the ftp cell names the sport it belongs to · NN% = that sport's share when it is close to a coin flip",
                "* = still open: no absence has closed this block, or the month is still running · - = not available",
            ],
            "\n",
        )
        Str.join_with(["── blocks ──", "", block_body, "", month_hdr, "", month_tbl, "", legend], "\n")
    }

    # start→end, with the peak or trough spliced in when the path went outside
    # its own endpoints. "Ride 234→239" read as a flat block that actually ran
    # 234→271→239; three of six real blocks were misread that way.
    ftp_path : F64, F64, F64, F64 -> Str
    ftp_path = |start, end, lo, hi| {
        top = if start > end start else end
        bot = if start < end start else end
        if hi > top + 0.5 {
            "${fmt0(start)}→${fmt0(hi)}→${fmt0(end)}"
        } else if lo > 0.0 and lo < bot - 0.5 {
            "${fmt0(start)}→${fmt0(lo)}→${fmt0(end)}"
        } else {
            "${fmt0(start)}→${fmt0(end)}"
        }
    }

    ## taper projection (#189): one horizon, its numbers, and which plan produced
    ## them — no verdict, same rule as events_screen (ADR 0010/0012)
    project_screen : { target_date : Str, days_away : I64, projected_from : Str, baseline_known : Bool, ftp_known : Bool, plan_source : Str, ctl : F64, atl : F64, tsb : F64, sessions_considered : U64, sessions_projected : U64, hypothetical : List({ date : Str, reps : I64, dur_s : I64, watts : F64 }) } -> Str
    project_screen = |p| {
        # a PAST horizon states the current baseline, not a projection — same arm
        # events_screen carries, same wording convention (review caught this exact
        # wart returning one PR after events fixed it)
        head =
            if p.days_away < 0
                "${p.target_date} was ${I64.to_str(-p.days_away)}d ago — baseline shown, `stride load` holds the day's reading"
            else
                "projected to ${p.target_date} (in ${I64.to_str(p.days_away)}d) from ${p.projected_from}, over the ${p.plan_source} plan"
        nums = "  ctl ${fmt1(p.ctl)}  atl ${fmt1(p.atl)}  tsb ${fmt1(p.tsb)}  (${(p.sessions_projected).to_str()} of ${(p.sessions_considered).to_str()} sessions in the window carry a projectable load)"
        hyp =
            if List.is_empty(p.hypothetical) ""
            else Str.join_with(List.map(p.hypothetical, |h| "\n  hypothetical: ${h.date} ${I64.to_str(h.reps)}×${mmss(h.dur_s)} @ ${(h.watts.to_i64_wrap()).to_str()}W"), "")
        note =
            if !(p.baseline_known) "\nno computed history to project from — the numbers are decay over zero; `stride analyze` first"
            else if !(p.ftp_known) "\nno 60d best-20min power on file, so no session could contribute load — the projection is decay plus nothing"
            else ""
        "${head}\n${nums}${hyp}${note}"
    }

    ## event targets (#138): the projection as numbers in a table, its inputs in the
    ## legend, and NO verdict line — "are you on track" is the coach's sentence, and
    ## ADR 0010 notes the denylist would not even catch it, so nothing here says it.
    events_screen : { projected_from : Str, baseline_known : Bool, ftp_known : Bool, events : List({ id : I64, event_date : Str, name : Str, days_away : I64, ctl : F64, atl : F64, tsb : F64, planned_in_window : U64, sessions_projected : U64 }) } -> Str
    events_screen = |p|
        if List.is_empty(p.events) {
            "no event targets on file — `stride event add <YYYY-MM-DD> \"<name>\"` records one"
        } else {
            rows = List.map(p.events, |e|
                # a PAST event's row states the current baseline, not the event-day
                # reading (daily_load holds that) — say so instead of printing "in -3d"
                if e.days_away < 0
                    "  #${I64.to_str(e.id)}  ${e.event_date}  ${I64.to_str(-e.days_away)}d ago — baseline shown, `stride load` holds the event-day reading  ${e.name}"
                else
                    "  #${I64.to_str(e.id)}  ${e.event_date}  in ${I64.to_str(e.days_away)}d  ctl ${fmt1(e.ctl)}  atl ${fmt1(e.atl)}  tsb ${fmt1(e.tsb)}  (${(e.sessions_projected).to_str()} of ${(e.planned_in_window).to_str()} planned sessions carry a projectable load)  ${e.name}")
            base_note =
                if !(p.baseline_known) "\nno computed history to project from — every number above is decay over zero; `stride analyze` first"
                else if !(p.ftp_known) "\nno 60d best-20min power on file, so targeted sessions could not contribute load — the projection is decay plus nothing"
                else ""
            body = Str.join_with(
                List.concat(["projected CTL/ATL/TSB from ${p.projected_from} over the open plan's structured targets"], rows),
                "\n",
            )
            "${body}${base_note}"
        }

    # time to exhaustion: the number, and what the model thinks of it
    tte_screen = |p| {
        # suppressed below 3 points, for the reason power_curve_screen gives — there the
        # COUNT is the signal.
        quality = if p.fit_points >= 3.I64 ", r2 ${fmt2(p.fit_r2)}" else ""
        head = "at ${fmt0(p.watts)}W against CP ${fmt0(p.cp)} (${p.sport_family} fit, W' ${fmt1(p.w_prime / 1000.0)} kJ from ${I64.to_str(p.fit_points)} of the 5/10/20-min bests over ${I64.to_str(p.window_days)}d${quality})"
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

    # ── rep-level comparison screen (#149) ──────────────────────────────
    # One row per session, newest first, with the per-rep watts spelled out so
    # the shape of a session is visible at a glance rather than summarized away.
    # Numbers only — a fade is reported, never judged (#154).
    reps_screen = |units, p| {
        shown = (List.len(p.sessions)).to_i64_wrap()
        # seg_unit carries a leading space for " m/s" so it can suffix a
        # number directly; the legend needs it bare.
        unit = seg_legend_unit(units, p.signal)
        # Rows are RANKED by uniformity and then capped, so saying only "12 of
        # 21" invites the reading that the other 9 are older, when they are in
        # fact the least regular. On this athlete the dropped rows included
        # five sessions from the current year, under a newest-first table.
        more = if p.matched_total > shown " · showing the ${I64.to_str(shown)} most uniform of ${I64.to_str(p.matched_total)}" else ""
        # How much of the evidence is itself the shape named in the header.
        # Because the rows are ranked by uniformity, a conforming session can
        # never rank below a non-conforming one: so when this count is under
        # the number shown, it is exact over the WHOLE matched set, not just
        # the visible rows. When every visible row conforms there may be more
        # below the cap, hence the "≥".
        conforming = (List.len(List.keep_if(p.sessions, |s| Metrics.is_uniform_reps(s.min_dur_s, s.max_dur_s)))).to_i64_wrap()
        atleast = if conforming == shown and p.matched_total > shown "≥" else ""
        # the NOUN follows how many were matched, the VERB how many conform:
        # "1 of 8 matched sessions is itself" -- pluralizing both produced
        # "1 of 8 matched session is itself" on 7 of 15 real anchors
        noun = if p.matched_total == 1.I64 "matched session" else "matched sessions"
        verb = if conforming == 1.I64 "is itself" else "are themselves"
        # The trailing clause described rows that may not exist: on a first
        # structured session it read "1 of 1 ... the rest are listed", naming a
        # rest of zero. It also implied the un-annotated rows were the
        # conforming ones, but the annotation fires at a spread of 1.15 and the
        # census counts at 1.6, so on real data that mapping gives 1 where the
        # census says 3.
        rest = p.matched_total - conforming
        # When the window caps and every visible row conforms, `conforming` is a
        # LOWER bound (hidden rows rank worse but may still conform), so the
        # remainder is an UPPER bound. Naming it exactly said "at least 12 of 35"
        # and "the other 23 are not like-for-like" in one breath, while two of
        # those 23 were identical in shape to the anchor.
        tail =
            if rest <= 0 {
                ""
            } else if atleast != "" and rest == 1.I64 {
                " — up to one other matches its rep count and duration band without being this shape"
            } else if atleast != "" {
                " — up to ${I64.to_str(rest)} others match its rep count and duration band without being this shape"
            } else if rest == 1.I64 {
                " — the other one matches its rep count and duration band without being this shape"
            } else {
                " — the other ${I64.to_str(rest)} match its rep count and duration band without being this shape"
            }
        # A caveat that fires on 11 of 12 rows has stopped being a caveat, so
        # the count of like-for-like evidence leads instead of hiding in a
        # per-row parenthetical.
        census = "${atleast}${I64.to_str(conforming)} of ${I64.to_str(p.matched_total)} ${noun} ${verb} this repeated shape${tail}"
        # "anchor" is load-bearing: the shape describes the anchor session, and
        # each row states its own spread — claiming it for the whole table would
        # contradict the rows beneath it.
        header = "── anchor ${I64.to_str(p.shape_reps)}×${mmss(p.shape_dur)} · ${p.anchor_date}${more} ──"
        rows = List.map(p.sessions, |s| {
            # seg_value/seg_unit, not fmt0: on a run avg_signal is metres per
            # second, and fmt0 rendered every rep of a 4:00/km and a 4:13/km
            # session as an identical "4".
            vals = Str.join_with(List.map(s.reps, |r| seg_value(units, r.avg_signal, p.signal)), " · ")
            # signed(), not a hardcoded "+": a HR DROP across reps is a real
            # signal and rendered as "hr +-8" three times on real data.
            hr = if s.hr_rise_known " · hr ${signed(s.hr_rise_bpm)}" else ""
            spread = if s.uniformity >= 1.15 " · reps ${mmss(s.min_dur_s)}-${mmss(s.max_dur_s)}" else ""
            "${s.date}  ${vals}  (mean ${seg_value(units, s.mean_signal, p.signal)}, fade ${fade_value(units, (List.first(s.reps)).map_ok(|r| r.avg_signal).ok_or(0.0), (List.last(s.reps)).map_ok(|r| r.avg_signal).ok_or(0.0), p.signal)}${hr}${spread})"
        })
        legend = "reps left to right within each session, in ${unit} · fade = change across the session, NEGATIVE means faded (weaker watts, slower pace) · hr = first-to-last change across reps"
        Str.join_with(List.join([[header, "", census, ""], rows, ["", legend]]), "\n")
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
        # after nothing is "resumed", nothing after nothing is not a change at all.
        # Defaulting to 0.0 here reports the second case as "load steady (0%)", which
        # claims a measurement that was never taken.
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
# ...and the budget still holds when the widest cell has NO break opportunity. The expect
# above wraps a spaced sentence, so it only ever exercised the word packer; a space-free
# token took the other arm of wrap_cell, which emitted it whole and overran the budget in
# silence (#194 — a season block is `2021-12-13..2022-02-10`, one token). Checks EVERY
# line, not just the top border: the border is built from the caps, so it can be legal
# while a data row it is supposed to bound is not.
expect {
    span = "2021-12-13..2022-02-10-and-a-tail-long-enough-that-it-cannot-possibly-fit"
    t = Render.render_table(
        ["block", "wk", "sessions", "load/wk", "trend", "r2", "polarization", "ftp"],
        [[span, "71", "128", "315", "falling", "0.10", "54/15/31", "239-271"]],
    )
    List.all(Str.split_on(t, "\n"), |l| Render.display_width(l) <= Render.max_total)
}
# hard_break cuts at the cap and loses nothing
expect Render.hard_break("abcdefghij", 4) == ["abcd", "efgh", "ij"]
# ...and cuts on CHARACTER boundaries, not byte offsets. A 4-byte glyph is display-width
# 2, so a cap of 3 fits one glyph plus one ASCII column and never splits the glyph — the
# failure that would print a broken code point into the middle of a table.
expect Render.hard_break("🚴ab🚴", 3) == ["🚴a", "b🚴"]
# a token that already fits is returned untouched, so wrap_cell's fast path is unaffected
expect Render.hard_break("short", 12) == ["short"]
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

expect Render.progress_group_label(Metric, "Morning Ride", SimilarDistance(31400.0)) == "Morning Ride (~31.4 km rides)"
# The same distance under the other system — 31400 m is 19.5 mi. Both are asserted
# because a converter tested on one system only proves the identity path.
expect Render.progress_group_label(Imperial, "Morning Ride", SimilarDistance(31400.0)) == "Morning Ride (~19.5 mi rides)"

# EF lens: gap row for >90-day breaks, asked marker, last-vs-best all present.
# The gap half COUNTS markers: the legend ends with `··· = a break over 90 days`,
# so `Str.contains(s, "···")` is true in every rendering and could never fail.
# `all_days` is populated so this exercises the real fold, not the degenerate
# `d - p` path.
expect {
    pr = |date, ef| { name: "X", date, sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: ef * 100.0, avg_hr: 100.0, avg_hr_scored: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream", decoupling_pct: 0.0, decoupling_known: False, id: 0 }
    dayof = |x| Metrics.date_str_to_days(x).ok_or(0)
    s = Render.progress_section(Metric, "X", [pr("2025-01-01", 1.5), pr("2025-08-01", 1.2)], "2025-08-01", Ef, Asc, [dayof("2025-01-01"), dayof("2025-08-01")], 0, "a different distance for this workout")
    marks = List.len(Str.split_on(s, "···")) - 1
    marks == 8 and Str.contains(s, "2025-08-01 ◀") and Str.contains(s, "below your best") and Str.contains(s, "declining")
}

# a single session states its score and stops: comparing a value to itself yields a real
# 0%, and "holding steady" would read as a measured finding rather than an absent one
expect {
    pr = |date, ef| { name: "X", date, sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: ef * 100.0, avg_hr: 100.0, avg_hr_scored: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream", decoupling_pct: 0.0, decoupling_known: False, id: 0 }
    s = Render.progress_section(Metric, "X", [pr("2025-01-01", 1.5)], "2025-01-01", Ef, Asc, [], 0, "a different distance for this workout")
    Str.contains(s, "first session of this workout, nothing to compare against yet") and !(Str.contains(s, "holding steady")) and !(Str.contains(s, "(0%)"))
}

# The gap marker is folded over the UNFILTERED series. Both halves asserted —
# asserting only the suppression passes on a build that never draws a marker.
# The measured shape: a no-HR ride on 2025-12-06 between two scorable ones, so the
# real legs are 62 and 41 days (no break) while the rendered rows sit 103 apart.
# `all_days` is DERIVED with the fold's own function — hardcoded day numbers landed
# on a different epoch and both cases drew a marker.
expect {
    pr = |date, ef| { name: "X", date, sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: ef * 100.0, avg_hr: 100.0, avg_hr_scored: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream", decoupling_pct: 0.0, decoupling_known: False, id: 0 }
    rendered = [pr("2025-10-05", 1.5), pr("2026-01-16", 1.6)]
    # the dropped 2025-12-06 ride is present in all_days and absent from the rows
    dayof = |x| Metrics.date_str_to_days(x).ok_or(0)
    with_dropped = Render.progress_section(Metric, "X", rendered, "2026-01-16", Ef, Asc, [dayof("2025-10-05"), dayof("2025-12-06"), dayof("2026-01-16")], 1, "a different distance for this workout")
    # ...and with nothing dropped, the same two rows ARE 103 days apart and DO get a marker
    without = Render.progress_section(Metric, "X", rendered, "2026-01-16", Ef, Asc, [dayof("2025-10-05"), dayof("2026-01-16")], 0, "a different distance for this workout")
    # COUNTED, not `Str.contains`: the legend line ends with "··· = a break over 90 days",
    # so a plain substring test is true of every rendering and the suppression half of this
    # expect passed for the wrong reason. Counting separates the table's marker row from the
    # legend's one mention.
    marks = |x| List.len(Str.split_on(x, "···")) - 1
    marks(with_dropped) == 1 and marks(without) == 8
}

# ...and the footer says what it withheld rather than presenting a filtered count as a
# total. Named by lens, since WHY a session is unscorable is what the athlete can act on.
expect {
    pr = |date, ef| { name: "X", date, sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: ef * 100.0, avg_hr: 100.0, avg_hr_scored: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream", decoupling_pct: 0.0, decoupling_known: False, id: 0 }
    rows = [pr("2025-10-05", 1.5), pr("2026-01-16", 1.6)]
    dayof = |x| Metrics.date_str_to_days(x).ok_or(0)
    hid = Render.progress_section(Metric, "X", rows, "2026-01-16", Ef, Asc, [dayof("2025-10-05"), dayof("2025-12-06"), dayof("2026-01-16")], 1, "a different distance for this workout")
    none = Render.progress_section(Metric, "X", rows, "2026-01-16", Ef, Asc, [dayof("2025-10-05"), dayof("2026-01-16")], 0, "a different distance for this workout")
    Str.contains(hid, "2 sessions (1 hidden: a different distance for this workout)") and Str.contains(none, "2 sessions —")
}

# A lone row means "first session, nothing to compare against" ONLY when nothing
# was hidden. Both arms asserted, and the hidden arm also asserts the ABSENCE of
# the first-session wording — the defect was that the false sentence printed, so a
# check looking only for the new text passes on a build that prints both. Pinned
# HERE because an expect can hold both arms against ONE input; the e2e reaches each
# arm from different data.
expect {
    pr = |date, ef| { name: "X", date, sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: ef * 100.0, avg_hr: 100.0, avg_hr_scored: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream", decoupling_pct: 0.0, decoupling_known: False, id: 0 }
    lone = [pr("2025-01-01", 1.5)]
    genuine = Render.progress_section(Metric, "X", lone, "2025-01-01", Ef, Asc, [], 0, "a different distance for this workout")
    withheld = Render.progress_section(Metric, "X", lone, "2025-01-01", Ef, Asc, [], 10, "a different distance for this workout")
    Str.contains(genuine, "first session of this workout")
    and !(Str.contains(genuine, "the only session this lens can score"))
    and Str.contains(withheld, "the only session shown (10 hidden: a different distance for this workout)")
    and !(Str.contains(withheld, "first session of this workout"))
}

# the best row's value + full 12-block bar stay on ONE line: terse headers keep the
# progress table under render_table's column budget, so the bar column is never the
# widest-column victim of squeeze-and-word-wrap (a split bar reads as broken output)
expect {
    pr = |date, ef| { name: "X", date, sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: ef * 100.0, avg_hr: 100.0, avg_hr_scored: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream", decoupling_pct: 0.0, decoupling_known: False, id: 0 }
    s = Render.progress_section(Metric, "X", [pr("2025-01-01", 1.2), pr("2025-02-01", 1.66)], "2025-02-01", Ef, Asc, [], 0, "a different distance for this workout")
    Str.contains(s, "1.66 ████████████")
}

# Desc flips only the DISPLAY order — the newest row prints first (everything before
# the 2025-01-01 row already contains 2025-02-01), while the trend verdict is still
# computed chronologically (1.2 → 1.66 reads as improving, not declining)
expect {
    pr = |date, ef| { name: "X", date, sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: ef * 100.0, avg_hr: 100.0, avg_hr_scored: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0, load_model: "power_stream", decoupling_pct: 0.0, decoupling_known: False, id: 0 }
    s = Render.progress_section(Metric, "X", [pr("2025-01-01", 1.2), pr("2025-02-01", 1.66)], "2025-02-01", Ef, Desc, [], 0, "a different distance for this workout")
    before_old = List.first(Str.split_on(s, "2025-01-01")).ok_or("")
    Str.contains(before_old, "2025-02-01") and Str.contains(s, "improving")
}

# ADR 0012's hard guard applied to the progress verdict: a closed set of three,
# pinned by full-string EQUALITY. A named function rather than an inline `if` so
# the pin can BE equality — Str.contains accepts every superstring ("holding
# steadyZ" contains "holding steady"), so a substring check cannot pin a closed set.
expect Render.trend_label(True, False) == "improving"
expect Render.trend_label(False, True) == "declining"
expect Render.trend_label(False, False) == "holding steady"
expect List.all(
    [Render.trend_label(True, False), Render.trend_label(False, True), Render.trend_label(False, False)],
    |v| !(Metrics.has_coaching_language(v)),
)

# RPE lens is lower-is-better: RPE dropping 8 -> 6 reads as improving, "above your easiest"
expect {
    pr = |date, rpe| { name: "Lift", date, sport: "WeightTraining", distance_m: 0.0, moving_time: 2700, np_w: 0.0, avg_hr: 0.0, avg_hr_scored: 0.0, rpe, output_kj: 0.0, tss: 0.0, load_model: "session_rpe", decoupling_pct: 0.0, decoupling_known: False, id: 0 }
    s = Render.progress_section(Metric, "Lift", [pr("2025-01-01", 8.0), pr("2025-02-01", 6.0), pr("2025-03-01", 7.0)], "2025-03-01", Rpe, Asc, [], 0, "a different distance for this workout")
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
    many = Iter.fold((0.I64..<21).iter(), [], |acc, i| List.append(acc, d(Metrics.days_to_date_str(20000 + i), 30.0)))
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
        fit_r2: 0.72,
        fit_points: 3.I64,
    })
    # a degenerate fit and a perfect one rendered identically here, on the
    # command that PUBLISHES the fit -- so the quality travels with it
    thin = Render.power_curve_screen({
        window_days: 90,
        sport: "Ride",
        points: [{ dur_s: 5, watts: 800.0 }],
        cp: 250.0,
        w_prime: 20000.0,
        fit_r2: 1.0,
        fit_points: 2.I64,
    })
    Str.contains(s, "5s") and Str.contains(s, "20m") and Str.contains(s, "Critical Power 250") and Str.contains(s, "Ride")
    and Str.contains(s, "fit r2 0.72")
    # ...and is suppressed at two points, where it would be false reassurance —
    # power_curve_screen states why.
    and !(Str.contains(thin, "r2 1.00")) and Str.contains(thin, "r2 needs 3")
}
expect {
    s = Render.power_curve_screen({ window_days: 30, sport: "", points: [], cp: 0.0, w_prime: 0.0, fit_r2: 0.0, fit_points: 0.I64 })
    Str.contains(s, "no power data") and Str.contains(s, "all power sports")
}

# the pace twin (#188). CS renders as a PACE and D' as a DISTANCE, and both follow the
# reader's units while the underlying payload stays SI — the same session, two readings.
expect {
    pts = [{ dur_s: 300, speed: 4.6667 }, { dur_s: 600, speed: 4.3 }, { dur_s: 1200, speed: 4.1667 }]
    m = Render.pace_curve_screen(Metric, { available_sports: ["Run"],  window_days: 90, sport: "Run", points: pts, cs: 4.0, d_prime: 200.0, fit_r2: 0.91, fit_points: 3.I64 })
    i = Render.pace_curve_screen(Imperial, { available_sports: ["Run"],  window_days: 90, sport: "Run", points: pts, cs: 4.0, d_prime: 200.0, fit_r2: 0.91, fit_points: 3.I64 })
    # 1000/4.0 = 250 s -> 4:10/km; 1609.344/4.0 = 402.3 s -> 6:42/mi; 200 m -> 219 yd
    Str.contains(m, "Critical Speed 4:10 min/km") and Str.contains(m, "D′ 200 m")
    and Str.contains(i, "Critical Speed 6:42 min/mi") and Str.contains(i, "D′ 219 yd")
    and Str.contains(m, "fit r2 0.91") and Str.contains(m, "Run")
}
# a fit refused (cs 0) must not print as a real fit, and two points is not a quality signal
expect {
    none = Render.pace_curve_screen(Metric, { available_sports: ["Run"],  window_days: 90, sport: "Run", points: [{ dur_s: 1200, speed: 4.1667 }], cs: 0.0, d_prime: 0.0, fit_r2: 0.0, fit_points: 1.I64 })
    thin = Render.pace_curve_screen(Metric, { available_sports: ["Run"],  window_days: 90, sport: "Run", points: [{ dur_s: 300, speed: 4.6667 }, { dur_s: 1200, speed: 4.1667 }], cs: 4.0, d_prime: 200.0, fit_r2: 1.0, fit_points: 2.I64 })
    empty = Render.pace_curve_screen(Metric, { available_sports: ["Run"],  window_days: 30, sport: "Run", points: [], cs: 0.0, d_prime: 0.0, fit_r2: 0.0, fit_points: 0.I64 })
    # no sport named: refuse a pooled fit and name what the athlete CAN ask for, rather than
    # fitting one curve through rides and runs together and labelling it "all pace sports"
    nosport = Render.pace_curve_screen(Metric, { available_sports: ["Run", "Rowing"],  window_days: 30, sport: "", points: [], cs: 0.0, d_prime: 0.0, fit_r2: 0.0, fit_points: 0.I64 })
    bare = Render.pace_curve_screen(Metric, { available_sports: [],  window_days: 30, sport: "", points: [], cs: 0.0, d_prime: 0.0, fit_r2: 0.0, fit_points: 0.I64 })
    Str.contains(none, "needs two ladder durations") and !(Str.contains(none, "Critical Speed 0"))
    # three rungs DESCENDING but too steeply for the model — the fitted ceiling lands below
    # zero, so the fit is refused for a reason that is neither a data gap nor a flat curve.
    # 10.0/3.0/2.0 m/s renders 1:40, 5:33, 8:20 per km: visibly descending, and the old
    # single message told the reader they were not.
    and Str.contains(
        Render.pace_curve_screen(Metric, { available_sports: ["Run"],  window_days: 90, sport: "Run", points: [{ dur_s: 300, speed: 10.0 }, { dur_s: 600, speed: 3.0 }, { dur_s: 1200, speed: 2.0 }], cs: 0.0, d_prime: 0.0, fit_r2: 0.0, fit_points: 3.I64 }),
        "fall too steeply",
    )
    and !(Str.contains(thin, "r2 1.00")) and Str.contains(thin, "r2 needs 3")
    and Str.contains(empty, "no pace data")
    and Str.contains(nosport, "per-sport") and Str.contains(nosport, "Run, Rowing") and !(Str.contains(nosport, "Critical Speed"))
    and Str.contains(bare, "none in this window")
    # three rungs at the SAME speed: enough data, but a flat curve the model must decline.
    # The data-gap message would be false here — the table above it shows three durations.
    and Str.contains(
        Render.pace_curve_screen(Metric, { available_sports: ["Run"],  window_days: 90, sport: "Run", points: [{ dur_s: 300, speed: 4.0 }, { dur_s: 600, speed: 4.0 }, { dur_s: 1200, speed: 4.0 }], cs: 0.0, d_prime: 0.0, fit_r2: 0.0, fit_points: 3.I64 }),
        "hold or rise with duration",
    )
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
    out = Render.summary_screen(Metric, s)
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
    out = Render.summary_screen(Metric, s)
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
    out = Render.summary_screen(Metric, s)
    Str.contains(out, "time in HR zones: unavailable") and Str.contains(out, "intensity unavailable") and !(Str.contains(out, "zone gap"))
}

# pace: 10km in 3000s = 5:00/km; padded seconds; no distance -> "-"
expect Render.pace_per_dist(Metric, 10000.0, 3000) == "5:00" and Render.pace_per_dist(Metric, 10000.0, 3070) == "5:07" and Render.pace_per_dist(Metric, 0.0, 100) == "-"
# 10 km in 50:00 is 5:00/km and 8:03/mi. The imperial arm is asserted separately because
# the metric one divides by 1000.0 and would pass against a converter that ignored its
# units argument entirely.
expect Render.pace_per_dist(Imperial, 10000.0, 3000) == "8:03" and Render.pace_per_dist(Imperial, 0.0, 100) == "-"
# The conversion itself, both directions, so a wrong constant fails here rather than
# only inside a formatted sentence.
expect Render.dist_unit(Metric) == "km" and Render.dist_unit(Imperial) == "mi"
expect Render.pace_unit(Metric) == "min/km" and Render.pace_unit(Imperial) == "min/mi"
expect Render.dist_value(Metric, 1609.344) == 1.609344
expect Render.dist_value(Imperial, 1609.344) == 1.0

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
    full = Render.interval_summary(Metric, [seg(0.I64, "warmup", 300.I64, 120.0), seg(1.I64, "work", 181.I64, 251.0), seg(2.I64, "recovery", 120.I64, 100.0), seg(3.I64, "work", 179.I64, 249.0), seg(4.I64, "cooldown", 300.I64, 110.0)])
    lone = Render.interval_summary(Metric, [seg(0.I64, "work", 1200.I64, 258.0)])
    none = Render.interval_summary(Metric, [seg(0.I64, "recovery", 600.I64, 100.0)])
    # a recovery-shaped block BEFORE the first work must not become the "easy" half
    pre = Render.interval_summary(Metric, [seg(0.I64, "recovery", 300.I64, 100.0), seg(1.I64, "work", 1200.I64, 258.0)])
    full == "2×[3:01 @ 251W / 2:00 easy]" and lone == "1×[20:00 @ 258W]" and none == "" and pre == "1×[20:00 @ 258W]"
}

# The same shape for a PACE-routed session, which #355 introduced and nothing pinned —
# the power arm above has been exact since it was written, the pace arm had no expect at
# all. This is the documented format in SKILL.md, so it is asserted rather than described.
expect {
    pseg = |o, k, d, v| { ordinal: o, kind: k, start_s: 0.I64, dur_s: d, avg_signal: v, signal: "pace", peak_hr: 0.0, avg_hr: 0.0, rec_drop: 0.0, rec_drop_known: False }
    reps = [pseg(0.I64, "work", 240.I64, 4.1667), pseg(1.I64, "recovery", 120.I64, 2.0), pseg(2.I64, "work", 240.I64, 4.1667)]
    Render.interval_summary(Metric, reps) == "2×[4:00 @ 4:00/km / 2:00 easy]"
    # and the unit follows the reader, while the VALUE is the same session
    and Render.interval_summary(Imperial, reps) == "2×[4:00 @ 6:26/mi / 2:00 easy]"
    # and the NO-RECOVERY form, which is what the e2e fixture (activity 9003) actually
    # emits — two work reps and no recovery row. Without this the shipped string is the
    # one string nothing pins: the arms above cover only the with-recovery shape, and the
    # e2e regex accepts either, so the exact form the payload really carries went unasserted.
    and Render.interval_summary(Metric, [pseg(0.I64, "work", 240.I64, 4.1667), pseg(1.I64, "work", 240.I64, 4.13)]) == "2×[4:00 @ 4:00/km]"
}

# rep lines carry HR only when measured; drift needs two measured reps
expect {
    seg = |hr, drop_known| { ordinal: 0.I64, kind: "work", start_s: 0.I64, dur_s: 180.I64, avg_signal: 250.0, signal: "power", peak_hr: hr + 8.0, avg_hr: hr, rec_drop: 20.0, rec_drop_known: drop_known }
    with_hr = Render.segments_block(Metric, [seg(150.0, True)])
    no_hr = Render.segments_block(Metric, [seg(0.0, False)])
    drift = Render.seg_hr_drift([seg(150.0, True), seg(158.0, True)])
    Str.contains(with_hr, "hr 150 avg / 158 peak") and Str.contains(with_hr, "60s drop +20")
    and !(Str.contains(no_hr, "hr"))
    and drift == Ok(8.0)
    # one measured rep is NOT a drift — Ok(0.0) here would print a fabricated
    # flat-drift verdict on every single-rep session
    and Render.seg_hr_drift([seg(150.0, True)]) == Err(NotEnough)
}

# reps_screen: units, sign, caption and census. Every assertion here failed on
# real data before this round.
expect {
    rep = |v| { avg_signal: v, ordinal: 0.I64, dur_s: 240.I64 }
    sess = |date, unif, hr_rise, mean, fade, vals| {
        date,
        uniformity: unif,
        min_dur_s: 240.I64,
        max_dur_s: 241.I64,
        mean_signal: mean,
        fade_signal: fade,
        hr_rise_bpm: hr_rise,
        hr_rise_known: True,
        reps: List.map(vals, rep),
    }
    power = Render.reps_screen(Metric, {
        anchor_date: "2026-08-16",
        shape_reps: 3.I64,
        shape_dur: 718.I64,
        matched_total: 21.I64,
        signal: "power",
        sessions: [sess("2026-08-16", 1.01, 11.0, 262.0, -16.0, [268.0, 265.0, 252.0])],
    })
    pace = Render.reps_screen(Metric, {
        anchor_date: "2026-08-10",
        shape_reps: 5.I64,
        shape_dur: 241.I64,
        matched_total: 2.I64,
        signal: "pace",
        sessions: [
            sess("2026-08-10", 1.01, 12.0, 4.15, -0.04, [4.1667, 4.13]),
            sess("2026-05-10", 1.01, 12.0, 3.94, -0.03, [3.9526, 3.92]),
        ],
    })
    # some shown rows do NOT conform, so the count is exact and the remainder
    # is named rather than hedged -- and "the other one" agrees in number
    mixed = Render.reps_screen(Metric, {
        anchor_date: "2026-08-16",
        shape_reps: 3.I64,
        shape_dur: 718.I64,
        matched_total: 3.I64,
        signal: "power",
        sessions: [
            sess("2026-08-16", 1.01, 11.0, 262.0, -16.0, [268.0, 252.0]),
            { date: "2025-10-15", uniformity: 4.3, min_dur_s: 264.I64, max_dur_s: 1144.I64, mean_signal: 236.0, fade_signal: -5.0, hr_rise_bpm: 13.0, hr_rise_known: True, reps: List.map([231.0, 227.0], rep) },
        ],
    })
    dropped = Render.reps_screen(Metric, {
        anchor_date: "2023-02-11",
        shape_reps: 7.I64,
        shape_dur: 63.I64,
        matched_total: 16.I64,
        signal: "power",
        sessions: [sess("2023-02-11", 1.02, -8.0, 248.0, -11.0, [248.0, 236.0])],
    })
    # pace renders as time-per-distance, not the stored m/s (#351): 4.1667 m/s is 4:00/km
    # both rendered every rep as "4", making the whole screen useless for runs
    Str.contains(pace, "4:00") and Str.contains(pace, "in min/km")
    # and the fade is signed so NEGATIVE means slower, matching how watts read
    and Str.contains(pace, "fade -0:02")
    # a HR DROP across reps rendered as "hr +-8" -- the + was hardcoded
    and Str.contains(dropped, "hr -8") and !(Str.contains(dropped, "+-"))
    # rows are ranked by uniformity then capped, so "showing 12 of 21" read as
    # "the other 9 are older" when they were the least regular
    and Str.contains(power, "most uniform of 21")
    # and the count of like-for-like evidence leads, rather than hiding in a
    # per-row caveat that fired on 11 of 12 rows
    # `Str.contains(power, "1 of 21 …")` matched whether or not the ≥ was
    # there, so deleting the branch left the suite green. Pin the ≥ itself,
    # and pin a case where it must be ABSENT.
    # capped AND every shown row conforms: the count is a LOWER bound, so the
    # remainder must be hedged rather than named exactly -- asserting "≥1 of 21"
    # and "the other 20" together is a contradiction the old test enshrined
    and Str.contains(power, "≥1 of 21 matched sessions is itself")
    and Str.contains(power, "up to 20 others")
    # ...and the HEDGED branch needs the singular too. Fixing number agreement
    # on the exact branch and not this one left "up to 1 others match", which
    # is the very defect the round was opened to close.
    and Str.contains(Render.reps_screen(Metric, {
        anchor_date: "2026-08-16",
        shape_reps: 3.I64,
        shape_dur: 718.I64,
        matched_total: 2.I64,
        signal: "power",
        sessions: [sess("2026-08-16", 1.01, 11.0, 262.0, -16.0, [268.0, 252.0])],
    }), "up to one other matches")
    and !(Str.contains(power, "the other 20"))
    # the NOUN stays plural even when one row conforms
    and !(Str.contains(power, "matched session is"))
    # nothing capped and everything conforms: no ≥, and no clause naming a
    # remainder of zero (it read "1 of 1 ... the rest are listed")
    and Str.contains(pace, "2 of 2 matched sessions are themselves")
    and !(Str.contains(pace, "≥"))
    and !(Str.contains(pace, "the other"))
    and !(Str.contains(pace, "up to"))
    and Str.contains(mixed, "1 of 3 matched sessions is itself")
    and Str.contains(mixed, "the other 2 match its rep count")
    and !(Str.contains(mixed, "≥")) and !(Str.contains(mixed, "up to"))
    and Str.contains(power, "W ·") and !(Str.contains(power, "m/s"))
}

# fade_value inherits the rounds-away-but-still-a-direction contract pinned above, which
# is why a pace fade keeps its sign instead of collapsing to a bare zero. It takes
# ENDPOINTS, not a delta, because a pace change cannot be derived from a speed change.
# Sign is flipped for pace so NEGATIVE means worse in both sports (#351):
# 4.1667 m/s -> 4.13 m/s is a slowdown of 2.13 s/km, so it reads -0:02, not +0:02.
expect Render.fade_value(Metric, 4.1667, 4.13, "pace") == "-0:02"
expect Render.fade_value(Imperial, 4.1667, 4.13, "pace") == "-0:03"
# speeding up reads positive, the same direction a power gain does
expect Render.fade_value(Metric, 4.13, 4.1667, "pace") == "+0:02"
expect Render.fade_value(Metric, 250.0, 240.0, "power") == "-10"
expect Render.fade_value(Metric, 240.0, 250.0, "power") == "+10"
# a missing endpoint is not a fade of zero
expect Render.fade_value(Metric, 0.0, 4.13, "pace") == "-"

# ftp_path splices the peak or trough in when the threshold left its own
# endpoints. "Ride 234→239" read as a flat block that actually ran 234→271→239,
# and three of six real blocks were misread that way.
expect {
    # rose then fell: the peak is above both ends
    peaked = Render.ftp_path(234.0, 239.0, 234.0, 271.0)
    # fell then rose: the trough is below both ends
    dipped = Render.ftp_path(300.0, 310.0, 250.0, 310.0)
    # monotone: nothing to splice, either direction
    up = Render.ftp_path(165.0, 212.0, 165.0, 212.0)
    down = Render.ftp_path(271.0, 243.0, 243.0, 271.0)
    # a lo of 0 is "no lower value recorded", not a trough at zero
    nolo = Render.ftp_path(200.0, 220.0, 0.0, 220.0)
    peaked == "234→271→239"
    and dipped == "300→250→310"
    and up == "165→212"
    and down == "271→243"
    and nolo == "200→220"
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
        fit_r2: 0.72,
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
    # the query-independent fit-quality number reaches the human screen -- a
    # coach reading only the terminal must see what the payload sees
    and Str.contains(tte("in_model", False, False), "r2 0.72")
    # ...and is SUPPRESSED at two points. Only the presence direction was asserted, so
    # mutating the gate to always-show left the suite green.
    and !(Str.contains(Render.tte_screen({
        watts: 265.0, seconds: 596.0, known: True, status: "in_model",
        cp: 254.0, w_prime: 6416.0, fit_points: 2.I64, fit_r2: 1.0,
        window_days: 90.I64, sport_family: "Ride", demonstrated_s: 0.0,
        demonstrated_w: 0.0, demonstrated_known: False, contradicts_model: False,
    }), "r2"))
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

# ── the stream-drain note (#218, #232) ───────────────────────────────
# Every arm pinned by full-string equality, and the SCREEN pinned on both inputs it
# forwards — substring or empty-case-only expects pass with every number deleted
# from the format string.
expect Render.drain_note(Complete, 0) == ""

# `pending` outranks the reason: a budget stop that empties the queue is done (the
# window fills on the read just stored), and keying the note on `stopped` printed
# "0 to go, run `stride sync` again tomorrow" beside `resumable: false`. The human
# and machine surfaces must not contradict each other about the same run.
expect Render.drain_note(BudgetReached, 0) == ""
expect Render.drain_note(RateLimited, 0) == ""
expect Render.drain_note(Complete, 5) == "5 had unreadable stream data — they retry next sync"
expect Render.drain_note(BudgetReached, 40) == "filled Strava's 15-minute read window — 40 to go, run `stride sync` again in ~15 minutes"
expect Render.drain_note(RateLimited, 40) == "Strava rate-limited this run — 40 to go, try again in ~15 minutes"
# the ONE arm whose remedy is not fifteen minutes. Full-string, and separately asserted
# NOT to carry the other arms' wording, because the whole of #246 is that these two stops
# were indistinguishable to a reader.
expect Render.drain_note(DailyCapReached, 40) == "used up today's Strava read allowance — 40 to go, run `stride sync` again tomorrow"
expect !(Str.contains(Render.drain_note(DailyCapReached, 40), "15 minutes"))

# The wire strings still have to match the producer — drain_note takes a StopReason,
# so the compiler already guarantees every reason has a branch; what no type can
# guarantee is that `stopped_label`'s spellings match schemas/v3/sync.json, a
# document. Hand-typed on purpose: these pin tag -> Roc literal, and the e2e schema
# check pins emitted literal -> schema enum. Neither alone catches a rename on the
# far side.
expect Drain.stopped_label(Complete) == "complete"
expect Drain.stopped_label(BudgetReached) == "budget_reached"
expect Drain.stopped_label(RateLimited) == "rate_limited"
expect Drain.stopped_label(DailyCapReached) == "daily_cap_reached"
expect Drain.sync_stopped_label(ListRateLimited) == "list_rate_limited"

# No label may appear RAW in the human line. Enumerated by hand, and that is a COST:
# a new SyncStop arm forces sync_screen and sync_stopped_label, a new StopReason arm
# forces stopped_label and drain_note — two DIFFERENT types, so neither compiler
# error reaches this list, and a compiler-forced branch is a branch, not a correct
# one. When you add an arm to either type, add it here too. Both `pending` shapes,
# because the tail dispatches on pending_streams too.
expect {
    stops = [FromDrain(Complete), FromDrain(BudgetReached), FromDrain(RateLimited), FromDrain(DailyCapReached), ListRateLimited, ListDailyCapReached]
    List.all(
        stops,
        |t| {
            lbl = Drain.sync_stopped_label(t)
            row = |pending| { synced: 3, new_activities: 1, updated_activities: 0, pruned: 0, streams_fetched: 2, streams_skipped: 0, pending_streams: pending, stopped: lbl, resumable: pending > 0 }
            !(Str.contains(Render.sync_screen(row(9), t, False), lbl))
            and !(Str.contains(Render.sync_screen(row(0), t, False), lbl))
        },
    )
}

# ADR 0012's boundary rule: a new prose surface joins the denylist sweep. These are
# tool instructions ("run `stride sync` again tomorrow"), not training advice, but
# the rule is about surfaces rather than intent — and a sweep that skips a surface
# because someone judged it exempt is how the gap recurs.
expect {
    notes = [
        Render.drain_note(Complete, 0),
        Render.drain_note(Complete, 5),
        Render.drain_note(BudgetReached, 40),
        Render.drain_note(RateLimited, 40),
        # the daily cap, BOTH pending shapes. Its empty-queue arm is the one that says
        # something where the other three say nothing, so it is prose the others are not.
        Render.drain_note(DailyCapReached, 0),
        Render.drain_note(DailyCapReached, 40),
        # the list-refusal sentence is a prose surface of its own — it does not come
        # through drain_note, so a sweep over drain_note's arms alone would miss it.
        Render.sync_screen({ synced: 0, new_activities: 0, updated_activities: 0, pruned: 0, streams_fetched: 0, streams_skipped: 0, pending_streams: 0, stopped: Drain.sync_stopped_label(ListRateLimited), resumable: True }, ListRateLimited, False),
        Render.sync_screen({ synced: 100, new_activities: 100, updated_activities: 0, pruned: 0, streams_fetched: 0, streams_skipped: 0, pending_streams: 100, stopped: Drain.sync_stopped_label(ListRateLimited), resumable: True }, ListRateLimited, False),
        # ...and the list-plus-spent-day sentence, which is a fourth prose surface this
        # branch added and which joined neither sweep until review counted them.
        Render.sync_screen({ synced: 0, new_activities: 0, updated_activities: 0, pruned: 0, streams_fetched: 0, streams_skipped: 0, pending_streams: 0, stopped: Drain.sync_stopped_label(ListDailyCapReached), resumable: True }, ListDailyCapReached, False),
        # freshness_note is a prose surface too, and ADR 0012's own consequences say the
        # sweep is where a new one joins. Every arm, including the empty one: an arm that
        # is only exercised on a broken config is exactly the one nobody would think to
        # add later.
        Render.freshness_note({ activities_awaiting_metrics: 0, activities_awaiting_metrics_known: True, activities_awaiting_streams: 0 }),
        Render.freshness_note({ activities_awaiting_metrics: 12, activities_awaiting_metrics_known: True, activities_awaiting_streams: 0 }),
        Render.freshness_note({ activities_awaiting_metrics: 0, activities_awaiting_metrics_known: True, activities_awaiting_streams: 40 }),
        Render.freshness_note({ activities_awaiting_metrics: 12, activities_awaiting_metrics_known: True, activities_awaiting_streams: 40 }),
        Render.freshness_note({ activities_awaiting_metrics: 0, activities_awaiting_metrics_known: False, activities_awaiting_streams: 4 }),
        # the target clauses (#198) join on arrival — targeted/untargeted on the echo,
        # and all three match arms: both known, target-only, and the silent untargeted
        Render.target_note(T({ reps: 3, dur_s: 720, watts: 230.0 })),
        Render.target_note(NoT),
        Render.target_match_note({ target_known: True, target_reps: 3, target_dur_s: 720, target_watts: 230.0, detected_known: True, detected_reps: 3, detected_mean_dur_s: 720, detected_mean_watts: 233.0, reps_delta: 0, watts_pct: 101.3 }),
        Render.target_match_note({ target_known: True, target_reps: 3, target_dur_s: 720, target_watts: 230.0, detected_known: False, detected_reps: 0, detected_mean_dur_s: 0, detected_mean_watts: 0.0, reps_delta: 0, watts_pct: 0.0 }),
        Render.target_match_note({ target_known: False, target_reps: 0, target_dur_s: 0, target_watts: 0.0, detected_known: False, detected_reps: 0, detected_mean_dur_s: 0, detected_mean_watts: 0.0, reps_delta: 0, watts_pct: 0.0 }),
        # events_screen (#138) joins on arrival: the empty state, a populated row, and
        # both degraded-baseline notes — ADR 0010 warns "you are on track" would slip
        # the denylist, which is why the screen carries no verdict line AT ALL, and the
        # sweep is backstop rather than proof
        Render.events_screen({ projected_from: "2026-08-30", baseline_known: True, ftp_known: True, events: [] }),
        Render.events_screen({ projected_from: "2026-08-30", baseline_known: True, ftp_known: True, events: [{ id: 1, event_date: "2026-10-15", name: "Fall Century", days_away: 46, ctl: 38.2, atl: 22.1, tsb: 16.1, planned_in_window: 4, sessions_projected: 2 }] }),
        Render.events_screen({ projected_from: "2026-08-30", baseline_known: False, ftp_known: False, events: [{ id: 1, event_date: "2026-10-15", name: "Fall Century", days_away: 46, ctl: 0.0, atl: 0.0, tsb: 0.0, planned_in_window: 0, sessions_projected: 0 }] }),
        Render.events_screen({ projected_from: "2026-08-30", baseline_known: True, ftp_known: False, events: [{ id: 1, event_date: "2026-10-15", name: "Fall Century", days_away: 46, ctl: 12.0, atl: 3.0, tsb: 9.0, planned_in_window: 2, sessions_projected: 0 }] }),
        Render.events_screen({ projected_from: "2026-08-30", baseline_known: True, ftp_known: True, events: [{ id: 2, event_date: "2026-08-01", name: "Past Race", days_away: -29, ctl: 40.0, atl: 50.0, tsb: -10.0, planned_in_window: 0, sessions_projected: 0 }] }),
        # project_screen (#189) joins on arrival: recorded, hypothetical, and both notes
        Render.project_screen({ target_date: "2026-10-15", days_away: 46, projected_from: "2026-08-30", baseline_known: True, ftp_known: True, plan_source: "recorded", ctl: 30.0, atl: 20.0, tsb: 10.0, sessions_considered: 3, sessions_projected: 2, hypothetical: [] }),
        Render.project_screen({ target_date: "2026-10-15", days_away: 46, projected_from: "2026-08-30", baseline_known: True, ftp_known: True, plan_source: "hypothetical", ctl: 30.0, atl: 20.0, tsb: 10.0, sessions_considered: 1, sessions_projected: 1, hypothetical: [{ date: "2026-09-15", reps: 3, dur_s: 720, watts: 230.0 }] }),
        Render.project_screen({ target_date: "2026-10-15", days_away: 46, projected_from: "2026-08-30", baseline_known: False, ftp_known: False, plan_source: "recorded", ctl: 0.0, atl: 0.0, tsb: 0.0, sessions_considered: 0, sessions_projected: 0, hypothetical: [] }),
        Render.project_screen({ target_date: "2026-10-15", days_away: 46, projected_from: "2026-08-30", baseline_known: True, ftp_known: False, plan_source: "recorded", ctl: 12.0, atl: 3.0, tsb: 9.0, sessions_considered: 2, sessions_projected: 0, hypothetical: [] }),
        Render.project_screen({ target_date: "2020-01-01", days_away: -2433, projected_from: "2026-08-30", baseline_known: True, ftp_known: True, plan_source: "recorded", ctl: 40.9, atl: 50.0, tsb: -9.1, sessions_considered: 0, sessions_projected: 0, hypothetical: [] }),
    ]
    List.all(notes, |p| !(Metrics.has_coaching_language(p)))
}

# ── plan's data-freshness line (#221) ────────────────────────────────
# Full-string equality throughout, for the reason the sync_screen block below records:
# an expect that only asserts a substring, or only asserts the "" case, passes with every
# number deleted from the format string.
#
# Silence when there is nothing to report. Asserted FIRST and separately from the rest,
# because this is the arm that runs on almost every real invocation — if it were the only
# case covered, the whole line could be dead and the suite would still be green.
expect Render.freshness_note({ activities_awaiting_metrics: 0, activities_awaiting_metrics_known: True, activities_awaiting_streams: 0 }) == ""

expect
    Render.freshness_note({ activities_awaiting_metrics: 12, activities_awaiting_metrics_known: True, activities_awaiting_streams: 0 })
    == "DATA: 12 awaiting metrics (stride analyze)"

expect
    Render.freshness_note({ activities_awaiting_metrics: 0, activities_awaiting_metrics_known: True, activities_awaiting_streams: 40 })
    == "DATA: 40 awaiting streams (stride sync)"

# Both arms at once: pins the separator AND the order, neither of which any single-arm
# case above can see.
expect
    Render.freshness_note({ activities_awaiting_metrics: 12, activities_awaiting_metrics_known: True, activities_awaiting_streams: 40 })
    == "DATA: 12 awaiting metrics (stride analyze) · 40 awaiting streams (stride sync)"

# The counts are forwarded, not hardcoded — distinct values, distinct from the case above.
expect
    Render.freshness_note({ activities_awaiting_metrics: 1, activities_awaiting_metrics_known: True, activities_awaiting_streams: 7 })
    == "DATA: 1 awaiting metrics (stride analyze) · 7 awaiting streams (stride sync)"

# An unknowable count SPEAKS, where a zero stays silent. The count is 0 in both, so this is
# the pair that proves the line keys on `known` and not on the number beside it.
expect
    Render.freshness_note({ activities_awaiting_metrics: 0, activities_awaiting_metrics_known: False, activities_awaiting_streams: 0 })
    == "DATA: awaiting-metrics count unreadable (stride analyze says why)"

# ...and it still composes with the streams arm rather than replacing the whole line.
expect
    Render.freshness_note({ activities_awaiting_metrics: 0, activities_awaiting_metrics_known: False, activities_awaiting_streams: 4 })
    == "DATA: awaiting-metrics count unreadable (stride analyze says why) · 4 awaiting streams (stride sync)"

# ── sync's human line (#232) ─────────────────────────────────────────
# Full-string equality, because the e2e check on this line asserts two unconditional
# literals: review deleted EVERY number from the format string and it still passed.
# These pin each forwarded value, so a hardcoded or dropped field fails here.
expect
    Render.sync_screen({ synced: 22, new_activities: 2, updated_activities: 1, pruned: 0, streams_fetched: 5, streams_skipped: 0, pending_streams: 0, stopped: "complete", resumable: False }, FromDrain(Complete), False)
    == "synced 2 new, 1 updated (22 re-checked in the 30-day window), fetched streams for 5"

# A refused LIST says so, and says it about the LIST. Full-string, because a `contains`
# on "rate" passes on drain_note's wording too — exactly how an arm can look
# correct while never running. `stopped` is built by the PRODUCER rather
# than hand-typed: these are the only expects covering the new arm, so typing the literal
# here would have checked Render against itself and passed straight through a rename.
expect
    Render.sync_screen({ synced: 0, new_activities: 0, updated_activities: 0, pruned: 0, streams_fetched: 0, streams_skipped: 0, pending_streams: 0, stopped: Drain.sync_stopped_label(ListRateLimited), resumable: True }, ListRateLimited, False)
    == "synced 0 new, 0 updated (0 re-checked in the 30-day window), fetched streams for 0 — Strava rate-limited the activity list, so it is incomplete; nothing was pruned. Run `stride sync` again in ~15 minutes"

# ...and it still says it with a FULL queue, which is the first-run shape the earlier
# version got wrong: pending at its maximum, drain_note winning, and the sentence blaming
# the drain for a list refusal.
expect
    Render.sync_screen({ synced: 100, new_activities: 100, updated_activities: 0, pruned: 0, streams_fetched: 0, streams_skipped: 0, pending_streams: 100, stopped: Drain.sync_stopped_label(ListRateLimited), resumable: True }, ListRateLimited, False)
    == "synced 100 new, 0 updated (100 re-checked in the 30-day window), fetched streams for 0 — Strava rate-limited the activity list, so it is incomplete; nothing was pruned. Run `stride sync` again in ~15 minutes"

# the prune claim comes from `pruned`, not from `stopped`. Strava.sync! returns before
# prune on this path, so production never builds this payload — which is precisely why
# the claim must be derived rather than asserted: Render cannot see that early return,
# and the sentence would go silently false the day it moves. Hardcoding "nothing was
# pruned" fails here; reading the field passes on both shapes.
expect
    Render.sync_screen({ synced: 4, new_activities: 0, updated_activities: 0, pruned: 2, streams_fetched: 0, streams_skipped: 0, pending_streams: 0, stopped: Drain.sync_stopped_label(ListRateLimited), resumable: True }, ListRateLimited, False)
    == "synced 0 new, 0 updated (4 re-checked in the 30-day window) (pruned 2 removed on Strava), fetched streams for 0 — Strava rate-limited the activity list, so it is incomplete. Run `stride sync` again in ~15 minutes"

# ...while a DRAIN rate limit still gets drain_note's wording, so the new arm did not
# swallow the case it sits in front of.
expect
    Render.sync_screen({ synced: 3, new_activities: 0, updated_activities: 0, pruned: 0, streams_fetched: 5, streams_skipped: 0, pending_streams: 7, stopped: "rate_limited", resumable: True }, FromDrain(RateLimited), False)
    == "synced 0 new, 0 updated (3 re-checked in the 30-day window), fetched streams for 5 — Strava rate-limited this run — 7 to go, try again in ~15 minutes"

# ...and a COMPLETE run with nothing pending still says nothing, which is the arm the
# clause above must not have swallowed.
expect
    Render.sync_screen({ synced: 3, new_activities: 1, updated_activities: 0, pruned: 0, streams_fetched: 2, streams_skipped: 0, pending_streams: 0, stopped: "complete", resumable: False }, FromDrain(Complete), False)
    == "synced 1 new, 0 updated (3 re-checked in the 30-day window), fetched streams for 2"

# `--all` re-listed everything, so the window clause must be absent
expect
    Render.sync_screen({ synced: 22, new_activities: 2, updated_activities: 1, pruned: 0, streams_fetched: 5, streams_skipped: 0, pending_streams: 0, stopped: "complete", resumable: False }, FromDrain(Complete), True)
    == "synced 2 new, 1 updated (22 re-checked), fetched streams for 5"

expect
    Render.sync_screen({ synced: 3, new_activities: 0, updated_activities: 0, pruned: 2, streams_fetched: 0, streams_skipped: 0, pending_streams: 0, stopped: "complete", resumable: False }, FromDrain(Complete), False)
    == "synced 0 new, 0 updated (3 re-checked in the 30-day window) (pruned 2 removed on Strava), fetched streams for 0"

# a budget stop states the reason AND supplements it with the skip count
expect
    Render.sync_screen({ synced: 9, new_activities: 0, updated_activities: 0, pruned: 0, streams_fetched: 12, streams_skipped: 1, pending_streams: 40, stopped: "budget_reached", resumable: True }, FromDrain(BudgetReached), False)
    == "synced 0 new, 0 updated (9 re-checked in the 30-day window), fetched streams for 12 (1 had unreadable stream data) — filled Strava's 15-minute read window — 40 to go, run `stride sync` again in ~15 minutes"

# a COMPLETE run with skips states the fact ONCE — drain_note owns it there;
# stating it twice in two wordings is the duplication this suppresses
expect
    Render.sync_screen({ synced: 2, new_activities: 0, updated_activities: 0, pruned: 0, streams_fetched: 1, streams_skipped: 1, pending_streams: 1, stopped: "complete", resumable: True }, FromDrain(Complete), False)
    == "synced 0 new, 0 updated (2 re-checked in the 30-day window), fetched streams for 1 — 1 had unreadable stream data — they retry next sync"


# the events empty state is a CLOSED output — full-string equality per ADR 0012's hard
# guard, so no verdict can ever ride into it unpinned
expect Render.events_screen({ projected_from: "2026-08-30", baseline_known: True, ftp_known: True, events: [] }) == "no event targets on file — `stride event add <YYYY-MM-DD> \"<name>\"` records one"
