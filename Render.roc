module [render_table, fmt0, fmt1, fmt2, mins, progress_group_label, progress_section, load_screen, summary_screen]

import Metrics

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
    sep = List.map(widths, |w| Str.repeat("─", w))
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
    t == "v   x\n──  ─\n██  y"

expect
    t = render_table(["a", "bb"], [["x", "y"], ["long", "z"]])
    t == "a     bb\n────  ──\nx     y\nlong  z"


# ── progress command screens ────────────────────────────────────────

# display label for a progress group, from anchor_filter's structured kind
progress_group_label : Str, [Exact, SimilarDistance F64, LoneNoDistance] -> Str
progress_group_label = |name, kind|
    when kind is
        Exact -> name
        SimilarDistance(m) -> "${name} (~${fmt1(m / 1000.0)} km rides)"
        LoneNoDistance -> "${name} (no distance recorded — can't match similar rides)"

# one workout's table + EF trend verdict as a string
progress_section : Str, List Metrics.ProgressRow, Str -> Str
progress_section = |name, rows, asked|
    max_ef = List.walk(rows, 0.0, |acc, r| Num.max(acc, r.ef))
    min_ef = List.walk(rows, max_ef, |acc, r| Num.min(acc, r.ef))
    # bar spans the OBSERVED range (worst session = 1 block, best = 12) so real
    # differences aren't squashed against a zero baseline
    ef_cell = |r|
        n = Metrics.scale_to_blocks(r.ef, min_ef, max_ef, 12)
        mark = if r.date == asked then " ◀ asked" else ""
        "${fmt2(r.ef)} ${Str.repeat("█", n)}${mark}"
    # a `···` row marks a break of >90 days between consecutive sessions
    to_cells = |r| [
        r.date,
        fmt0(r.np_w),
        fmt0(r.avg_hr),
        ef_cell(r),
        fmt0(r.output_kj),
        fmt0(r.tss),
    ]
    gap_row = ["···", "", "", "", "", ""]
    body_rows =
        List.walk(rows, { prev: -1000000i64, cells: [] }, |acc, r|
            days = Result.with_default(Metrics.date_str_to_days(r.date), acc.prev)
            with_gap =
                if acc.prev > -1000000 and days - acc.prev > 90 then
                    List.append(acc.cells, gap_row)
                else
                    acc.cells
            { prev: days, cells: List.append(with_gap, to_cells(r)) })
        |> .cells
    table = render_table(
        ["date", "power (np)", "heart rate (hr)", "efficiency (ef)", "output (kj)", "load (tss)"],
        body_rows,
    )
    t = Metrics.trend_ends(List.map(rows, |r| r.ef))
    pct = Metrics.pct_change(t.early, t.late)
    label =
        if pct > 5.0 then "improving" else if pct < -5.0 then "declining" else "holding steady"
    avg_ef = Metrics.mean(List.map(rows, |r| r.ef))
    verdict = "→ ef early avg ${fmt2(t.early)} → recent avg ${fmt2(t.late)} (overall avg ${fmt2(avg_ef)}) over ${Num.to_str(List.len(rows))} sessions — ${label} (${fmt0(pct)}%)"
    "── ${name} ──\n${table}\n\n${verdict}${last_vs_best(rows)}"

# "last vs best" line: how the most recent session compares to the all-time best EF.
# Empty when they're the same session (you just set your best) or <2 rows.
last_vs_best : List Metrics.ProgressRow -> Str
last_vs_best = |rows|
    when (List.last(rows), List.sort_with(rows, |a, b| Num.compare(b.ef, a.ef)) |> List.first) is
        (Ok(last), Ok(best)) ->
            if last.date == best.date or List.len(rows) < 2 then
                ""
            else
                gap = -Metrics.pct_change(best.ef, last.ef) # % below best (best -> last is negative)
                "\n→ last: ${fmt2(last.ef)} (${last.date}) vs best: ${fmt2(best.ef)} (${best.date}) — ${fmt0(gap)}% below your best"

        _ -> ""

expect progress_group_label("Morning Ride", SimilarDistance(31400.0)) == "Morning Ride (~31.4 km rides)"

# section: gap row for >90-day breaks, asked marker, last-vs-best line all present
expect
    pr = |date, ef| { name: "X", date, distance_m: 0.0, np_w: ef * 100.0, avg_hr: 100.0, ef, output_kj: 0.0, tss: 0.0 }
    s = progress_section("X", [pr("2025-01-01", 1.5), pr("2025-08-01", 1.2)], "2025-08-01")
    Str.contains(s, "···") and Str.contains(s, "◀ asked") and Str.contains(s, "below your best")


# ── load command screen ─────────────────────────────────────────────

# daily fitness table for short windows; Mon-aligned weekly rollup beyond 14 days
load_screen : List { day : Str, tss : F64, ctl : F64, atl : F64, tsb : F64 } -> Str
load_screen = |ordered|
    verdict =
        when List.last(ordered) is
            Ok(today) -> "→ today: form ${fmt0(today.tsb)} — ${Metrics.form_label(today.tsb)}"
            Err(_) -> ""
    if List.len(ordered) > 14 then
        # long windows: weekly rollup (Mon-aligned) — trajectory, not noise
        day_loads = List.map(ordered, |d| {
            days: Result.with_default(Metrics.date_str_to_days(d.day), 0),
            tss: d.tss,
            ctl: d.ctl,
            atl: d.atl,
            tsb: d.tsb,
        })
        weeks = Metrics.weekly_rollup(day_loads)
        table = render_table(
            ["week of", "sessions", "load (tss)", "fitness end (ctl)", "form end (tsb)"],
            List.map(weeks, |w| [
                Metrics.days_to_date_str(w.week_start),
                Num.to_str(w.sessions),
                fmt0(w.tss),
                fmt0(w.ctl_end),
                fmt0(w.tsb_end),
            ]),
        )
        legend =
            """
            one row per Mon-Sun week — is fitness (ctl) climbing? is weekly load steady or ramping?
            (use `stride load 14` or fewer days for the daily view)
            """
        "${table}\n\n${verdict}\n\n${legend}"
    else
        table = render_table(
            ["day", "trained (tss)", "fitness (ctl)", "fatigue (atl)", "form (tsb)"],
            List.map(ordered, |d| [
                d.day,
                (if d.tss >= 1.0 then "${fmt0(d.tss)} TSS" else "rest"),
                fmt0(d.ctl),
                fmt0(d.atl),
                fmt0(d.tsb),
            ]),
        )
        legend =
            """
            trained (tss):  training stress score — how much load the day added
            fitness (ctl):  long-term base, 42d avg — want it climbing slowly
            fatigue (atl):  short-term tiredness, 7d avg — spikes after big days, fades with rest
            form (tsb):     fitness - fatigue (same day) — negative = fatigued,
                            positive = fresh; a hard session drops it the same day
            """
        "${table}\n\n${verdict}\n\n${legend}"

# short window: daily table, rest rows, verdict; long window: weekly rollup
expect
    d = |day, tss| { day, tss, ctl: 10.0, atl: 5.0, tsb: 5.0 }
    s = load_screen([d("2025-01-01", 50.0), d("2025-01-02", 0.0)])
    Str.contains(s, "trained (tss)") and Str.contains(s, "rest") and Str.contains(s, "→ today: form 5")

expect
    d = |day, tss| { day, tss, ctl: 10.0, atl: 5.0, tsb: 5.0 }
    many = List.map(List.range({ start: At(0), end: Before(21) }), |i| d(Metrics.days_to_date_str(20000 + i), 30.0))
    Str.contains(load_screen(many), "week of")


# ── summary command screen ──────────────────────────────────────────
# renders the human report straight from the summary payload — ONE source of
# numbers for the whole screen. (No type annotation: the payload is the summary
# record, typed at the app.roc call site; inference keeps this open.)

summary_screen = |s|
    z = s.last_28d
    zone_gap =
        if z.z5_s == 0 then
            ["    ⚠ zone gap: 0 minutes in Z5 — no VO2max stimulus in 28 days"]
        else
            []
    ftp_lines =
        if s.ftp.best_20min_w_60d > 0 then
            ftp_calibration_lines(s.ftp)
        else
            []
    last_hard_str = if s.last_hard_session_date == "" then "none on record" else s.last_hard_session_date
    Str.join_with(
        List.join([
            [
                "",
                "── stride report (as of ${s.as_of}) ──────────────────",
                "",
                "  fitness (CTL): ${fmt0(s.fitness_ctl)}   fatigue (ATL): ${fmt0(s.fatigue_atl)}   form (TSB): ${fmt0(s.form_tsb)}",
                "  → ${Metrics.form_label(s.form_tsb)}",
                "",
                "  last 28 days:",
                "    training load: ${fmt0(z.tss)} TSS",
                "    time in HR zones: Z1 ${Num.to_str(z.z1_s // 60)}m  Z2 ${Num.to_str(z.z2_s // 60)}m  Z3 ${Num.to_str(z.z3_s // 60)}m  Z4 ${Num.to_str(z.z4_s // 60)}m  Z5 ${Num.to_str(z.z5_s // 60)}m",
                "    polarization: ${Num.to_str(z.easy_pct)}% easy (Z1-2) / ${Num.to_str(z.moderate_pct)}% moderate (Z3) / ${Num.to_str(z.hard_pct)}% hard (Z4-5)",
            ],
            zone_gap,
            ftp_lines,
            [
                "",
                "  last 7 days: ${fmt0(s.last_7d.tss)} TSS — ${Num.to_str(s.last_7d.easy_pct)}% easy / ${Num.to_str(s.last_7d.moderate_pct)}% moderate / ${Num.to_str(s.last_7d.hard_pct)}% hard",
                "  last hard session (5+ min Z4/Z5): ${last_hard_str}",
                "  open planned sessions: ${Num.to_str(s.pending_sessions)}",
            ],
        ]),
        "\n",
    )

ftp_calibration_lines = |ftp|
    base = [
        "",
        "  FTP calibration (60d): best 20-min power ${fmt0(ftp.best_20min_w_60d)}W -> estimated FTP ${fmt0(ftp.estimated_ftp_w)}W (config: ${fmt0(ftp.config_w)}W)",
    ]
    if ftp.stale then
        List.append(base, "    ⚠ config FTP looks stale — consider: stride config set ftp ${fmt0(ftp.estimated_ftp_w)}")
    else if ftp.detraining then
        List.append(base, "    note: recent best power is well below config FTP (detraining or no hard efforts recorded)")
    else
        base

# zone-gap warning fires on 0 Z5; empty last-hard reads as none on record
expect
    s = {
        as_of: "2025-01-01",
        fitness_ctl: 20.0,
        fatigue_atl: 10.0,
        form_tsb: 10.0,
        last_28d: { tss: 100.0, z1_s: 600i64, z2_s: 0i64, z3_s: 0i64, z4_s: 0i64, z5_s: 0i64, easy_pct: 100i64, moderate_pct: 0i64, hard_pct: 0i64 },
        last_7d: { tss: 50.0, easy_pct: 100i64, moderate_pct: 0i64, hard_pct: 0i64 },
        ftp: { best_20min_w_60d: 0.0, estimated_ftp_w: 0.0, config_w: 200.0, stale: Bool.false, detraining: Bool.false },
        last_hard_session_date: "",
        pending_sessions: 2i64,
    }
    out = summary_screen(s)
    Str.contains(out, "stride report") and Str.contains(out, "zone gap") and Str.contains(out, "none on record")
