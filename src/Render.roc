module [render_table, fmt0, fmt1, fmt2, mins, progress_group_label, progress_section, load_screen, summary_screen, compare_screen]

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
        "│ ${Str.join_with(cells, " │ ")} │"
    border = |left, mid, right|
        "${left}${Str.join_with(List.map(widths, |w| Str.repeat("─", w + 2)), mid)}${right}"
    all_lines = List.join([
        [border("╭", "┬", "╮"), line(headers), border("├", "┼", "┤")],
        List.map(rows, line),
        [border("╰", "┴", "╯")],
    ])
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

# distance+time -> running pace "M:SS" per km (blank if no distance)
pace_per_km : F64, I64 -> Str
pace_per_km = |distance_m, moving_time|
    if distance_m <= 0.0 or moving_time <= 0 then
        "-"
    else
        total : I64
        total = Num.round(Num.to_f64(moving_time) / (distance_m / 1000.0))
        m = total // 60
        s = total % 60
        ss = if s < 10 then "0${Num.to_str(s)}" else Num.to_str(s)
        "${Num.to_str(m)}:${ss}"

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
    t == "╭────┬───╮\n│ v  │ x │\n├────┼───┤\n│ ██ │ y │\n╰────┴───╯"

expect
    t = render_table(["a", "bb"], [["x", "y"], ["long", "z"]])
    t == "╭──────┬────╮\n│ a    │ bb │\n├──────┼────┤\n│ x    │ y  │\n│ long │ z  │\n╰──────┴────╯"


# ── progress command screens ────────────────────────────────────────

# display label for a progress group, from anchor_filter's structured kind
progress_group_label : Str, [Exact, SimilarDistance F64, LoneNoDistance] -> Str
progress_group_label = |name, kind|
    when kind is
        Exact -> name
        SimilarDistance(m) -> "${name} (~${fmt1(m / 1000.0)} km rides)"
        LoneNoDistance -> "${name} (no distance recorded — can't match similar rides)"

# one workout's table + trend verdict, rendered through its sport-aware lens
# (power->EF, distance->speed/HR, rated->RPE; RPE is lower-is-better)
progress_section : Str, List Metrics.ProgressRow, Str, [Ef, SpeedHr, Rpe] -> Str
progress_section = |name, rows, asked, lens|
    higher = Metrics.lens_higher_better(lens)
    sc = |row| Result.with_default(Metrics.lens_score(lens, row), 0.0)
    scores = List.map(rows, sc)
    max_s = List.walk(scores, 0.0, |acc, s| Num.max(acc, s))
    min_s = List.walk(scores, max_s, |acc, s| Num.min(acc, s))
    best = if higher then max_s else min_s
    worst = if higher then min_s else max_s
    pfmt = |v| when lens is
        Rpe -> fmt0(v)
        _ -> fmt2(v)
    hr_of = |row| if row.avg_hr > 0.0 then fmt0(row.avg_hr) else "-"
    prim_of = |row|
        n = Metrics.scale_to_blocks(sc(row), worst, best, 12)
        mark = if row.date == asked then " ◀ asked" else ""
        "${pfmt(sc(row))} ${Str.repeat("█", n)}${mark}"
    # each lens picks its own columns (list of header + per-row cell); the primary
    # (bar) column direction is already handled by best/worst above
    cols =
        when lens is
            Ef -> [
                ("power (np)", |row| fmt0(row.np_w)),
                ("heart rate (hr)", hr_of),
                ("efficiency (ef)", prim_of),
                ("output (kj)", |row| fmt0(row.output_kj)),
                ("load (tss)", |row| fmt0(row.tss)),
            ]
            SpeedHr -> [
                ("pace (min/km)", |row| pace_per_km(row.distance_m, row.moving_time)),
                ("heart rate (hr)", hr_of),
                ("aero eff (spd/hr)", prim_of),
                ("distance (km)", |row| fmt1(row.distance_m / 1000.0)),
                ("load (tss)", |row| fmt0(row.tss)),
            ]
            Rpe -> [
                ("duration", |row| mins(row.moving_time)),
                ("heart rate (hr)", hr_of),
                ("effort (rpe)", prim_of),
                ("load (tss)", |row| fmt0(row.tss)),
            ]
    headers = List.prepend(List.map(cols, |c| c.0), "date")
    to_cells = |row| List.prepend(List.map(cols, |c| (c.1)(row)), row.date)
    gap_row = List.map(headers, |_| "···")
    body_rows =
        List.walk(rows, { prev: -1000000i64, cells: [] }, |acc, row|
            days = Result.with_default(Metrics.date_str_to_days(row.date), acc.prev)
            with_gap =
                if acc.prev > -1000000 and days - acc.prev > 90 then
                    List.append(acc.cells, gap_row)
                else
                    acc.cells
            { prev: days, cells: List.append(with_gap, to_cells(row)) })
        |> .cells
    table = render_table(headers, body_rows)
    t = Metrics.trend_ends(scores)
    pct = Metrics.pct_change(t.early, t.late)
    improved = if higher then pct > 5.0 else pct < -5.0
    declined = if higher then pct < -5.0 else pct > 5.0
    label = if improved then "improving" else if declined then "declining" else "holding steady"
    avg = Metrics.mean(scores)
    short = when lens is
        Ef -> "ef"
        SpeedHr -> "aero-eff"
        Rpe -> "rpe"
    legend = when lens is
        Ef -> "ef = normalized power / avg HR (watts per heartbeat) — climbing = fitter"
        SpeedHr -> "aero-eff = speed per heartbeat — climbing = fitter · pace is min/km"
        Rpe -> "rpe = how hard it felt (1-10) — for a fixed workout, dropping = adapting"
    verdict = "→ ${short} early avg ${pfmt(t.early)} → recent avg ${pfmt(t.late)} (overall avg ${pfmt(avg)}) over ${Num.to_str(List.len(rows))} sessions — ${label} (${fmt0(pct)}%)"
    footer = "${legend}\nbar = scaled worst→best · ◀ asked marks the asked date · ··· = a break over 90 days"
    "── ${name} ──\n${table}\n\n${verdict}${last_vs_best(rows, lens)}\n\n${footer}"

# "last vs best" line: the most recent session vs the all-time best FOR THIS LENS
# (highest score, or lowest for RPE). Empty when last IS the best, or <2 rows.
last_vs_best : List Metrics.ProgressRow, [Ef, SpeedHr, Rpe] -> Str
last_vs_best = |rows, lens|
    higher = Metrics.lens_higher_better(lens)
    sc = |row| Result.with_default(Metrics.lens_score(lens, row), 0.0)
    pfmt = |v| when lens is
        Rpe -> fmt0(v)
        _ -> fmt2(v)
    desc = List.sort_with(rows, |a, b| Num.compare(sc(b), sc(a)))
    best_row = if higher then List.first(desc) else List.last(desc)
    when (List.last(rows), best_row) is
        (Ok(last), Ok(best)) ->
            if last.date == best.date or List.len(rows) < 2 then
                ""
            else
                gap = Num.abs(Metrics.pct_change(sc(best), sc(last)))
                word = if higher then "below your best" else "above your easiest"
                "\n→ last: ${pfmt(sc(last))} (${last.date}) vs best: ${pfmt(sc(best))} (${best.date}) — ${fmt0(gap)}% ${word}"

        _ -> ""

expect progress_group_label("Morning Ride", SimilarDistance(31400.0)) == "Morning Ride (~31.4 km rides)"

# EF lens: gap row for >90-day breaks, asked marker, last-vs-best all present
expect
    pr = |date, ef| { name: "X", date, sport: "Ride", distance_m: 0.0, moving_time: 3600, np_w: ef * 100.0, avg_hr: 100.0, rpe: 0.0, output_kj: 0.0, tss: 0.0 }
    s = progress_section("X", [pr("2025-01-01", 1.5), pr("2025-08-01", 1.2)], "2025-08-01", Ef)
    Str.contains(s, "···") and Str.contains(s, "◀ asked") and Str.contains(s, "below your best") and Str.contains(s, "declining")

# RPE lens is lower-is-better: RPE dropping 8 -> 6 reads as improving, "above your easiest"
expect
    pr = |date, rpe| { name: "Lift", date, sport: "WeightTraining", distance_m: 0.0, moving_time: 2700, np_w: 0.0, avg_hr: 0.0, rpe, output_kj: 0.0, tss: 0.0 }
    s = progress_section("Lift", [pr("2025-01-01", 8.0), pr("2025-02-01", 6.0), pr("2025-03-01", 7.0)], "2025-03-01", Rpe)
    Str.contains(s, "effort (rpe)") and Str.contains(s, "improving") and Str.contains(s, "above your easiest")


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


# ── compare command screen ──────────────────────────────────────────
# this rolling window vs the prior one, metric by metric, with a signed delta
compare_screen = |p|
    c = p.current
    pr = p.prior
    lab = p.window_label
    signed = |x| if x >= 0.0 then "+${fmt0(x)}" else fmt0(x)
    df = |cur, prev| signed(cur - prev)
    di = |cur, prev| signed(Num.to_f64(cur) - Num.to_f64(prev))
    table = render_table(
        ["metric", "prior ${lab}", "last ${lab}", "Δ"],
        [
            ["load (tss)", fmt0(pr.tss), fmt0(c.tss), df(c.tss, pr.tss)],
            ["sessions", Num.to_str(pr.sessions), Num.to_str(c.sessions), di(c.sessions, pr.sessions)],
            ["hard (min)", Num.to_str(pr.hard_min), Num.to_str(c.hard_min), di(c.hard_min, pr.hard_min)],
            ["easy %", Num.to_str(pr.easy_pct), Num.to_str(c.easy_pct), di(c.easy_pct, pr.easy_pct)],
            ["fitness (ctl)", fmt0(pr.ctl), fmt0(c.ctl), df(c.ctl, pr.ctl)],
        ],
    )
    load_pct = Metrics.pct_change(pr.tss, c.tss)
    load_word =
        if pr.tss <= 0.0 and c.tss > 0.0 then "load resumed (${fmt0(c.tss)} TSS vs none the prior ${lab})"
        else if load_pct > 10.0 then "load ramping (${fmt0(load_pct)}%)"
        else if load_pct < -10.0 then "load backed off (${fmt0(load_pct)}%)"
        else "load steady (${fmt0(load_pct)}%)"
    ctl_d = c.ctl - pr.ctl
    fit_word =
        if ctl_d > 0.5 then "fitness building"
        else if ctl_d < -0.5 then "fitness slipping"
        else "fitness holding"
    "${table}\n\n→ ${load_word} · ${fit_word}"

# pace: 10km in 3000s = 5:00/km; padded seconds; no distance -> "-"
expect pace_per_km(10000.0, 3000) == "5:00" and pace_per_km(10000.0, 3070) == "5:07" and pace_per_km(0.0, 100) == "-"

# compare table + verdict render; ramp shows in the load word
expect
    w = |tss, sessions, hard, easy, ctl| { tss, sessions, hard_min: hard, easy_pct: easy, ctl }
    s = compare_screen({ period: "week", window_label: "7d", current: w(227.0, 6i64, 18i64, 17i64, 26.0), prior: w(193.0, 5i64, 12i64, 37i64, 24.0) })
    Str.contains(s, "load (tss)") and Str.contains(s, "+34") and Str.contains(s, "ramping") and Str.contains(s, "building")

# zero prior TSS must NOT read as "steady 0%" — it's a resumption
expect
    w = |tss, sessions, hard, easy, ctl| { tss, sessions, hard_min: hard, easy_pct: easy, ctl }
    s = compare_screen({ period: "week", window_label: "7d", current: w(200.0, 4i64, 10i64, 40i64, 20.0), prior: w(0.0, 0i64, 0i64, 0i64, 18.0) })
    Str.contains(s, "load resumed") and !(Str.contains(s, "steady"))
