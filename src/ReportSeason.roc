# ── the long view: blocks and months across a season (ADR 0011) ─────
#
# Split from Report.roc under ADR 0001, whose ~250-line command trigger season!
# had passed. Fully self-contained: it shares no helper with any other read
# command, which is why it went first.
import Db
import Output
import Metrics
import Render
import pf.Sqlite
import pf.Path

ReportSeason :: [].{
    season_gap_weeks : I64
    season_gap_weeks = 2

    # A threshold belongs to a sport family — this athlete's rowing threshold
    # runs 57-156 W against 139-271 W on the bike, so a min/max across families
    # produces a range that describes nobody (the same mistake #190 fixed by
    # fitting CP per family). Each range is reported WITH the family it is for,
    # picked as the family with the most sessions in the period.
    dominant_ftp : List({ fam : Str, n : I64, ftp_lo : F64, ftp_hi : F64, ftp_first : F64, ftp_last : F64 }) -> { ftp_family : Str, ftp_lo : F64, ftp_hi : F64, ftp_start : F64, ftp_end : F64, ftp_family_pct : I64, ftp_known : Bool }
    dominant_ftp = |rows| {
        withftp = List.keep_if(rows, |r| r.ftp_hi > 0.0)
        best = List.fold(withftp, { fam: "", n: 0, ftp_lo: 0.0, ftp_hi: 0.0, ftp_first: 0.0, ftp_last: 0.0 }, |acc, r| if r.n > acc.n r else acc)
        # the winner's SHARE, because 52/48 and 95/5 published identically and
        # one of those is a coin flip standing in for a whole block
        total_n = List.fold(withftp, 0, |a, r| a + r.n)
        pct = if total_n > 0 (((best.n * 100 + total_n // 2) // total_n)).to_i64_wrap() else 0
        {
            ftp_family: best.fam,
            ftp_lo: best.ftp_lo,
            ftp_hi: best.ftp_hi,
            # chronological, so the range stops reading as a direction it does
            # not have: this athlete's current block is lo 234 / hi 271 but ran
            # 234 -> 271 -> 243 -> 239, and `zones` reports 239.
            ftp_start: best.ftp_first,
            ftp_end: best.ftp_last,
            ftp_family_pct: pct,
            ftp_known: best.ftp_hi > 0.0,
        }
    }

    # ONE fold for blocks and months. They diverged the first time months got
    # their own query: it aliased ftp_first/ftp_last to MIN/MAX, so every month
    # was non-decreasing by construction and a falling threshold rendered as a
    # rise. pol_rows arrives ORDER BY date, fam, so folding it in order is what makes
    # first/last chronological.
    FamRow : { fam : Str, n : I64, ftp_lo : F64, ftp_hi : F64, ftp_first : F64, ftp_last : F64 }
    fold_families : List({ days : I64, fam : Str, n : I64, easy_s : F64, mod_s : F64, hard_s : F64, ftp_lo : F64, ftp_hi : F64 }) -> List(FamRow)
    fold_families = |rows|
        List.fold(rows, [], |acc, r|
            match List.find_first_index(acc, |f| f.fam == r.fam) {
                Ok(i) =>
                    match List.get(acc, i) {
                        Ok(f) =>
                            List.set(acc, i, {
                                fam: f.fam,
                                n: f.n + r.n,
                                ftp_lo: if f.ftp_lo == 0.0 or (r.ftp_lo > 0.0 and r.ftp_lo < f.ftp_lo) r.ftp_lo else f.ftp_lo,
                                ftp_hi: if r.ftp_hi > f.ftp_hi r.ftp_hi else f.ftp_hi,
                                ftp_first: if f.ftp_first == 0.0 r.ftp_hi else f.ftp_first,
                                ftp_last: if r.ftp_hi > 0.0 r.ftp_hi else f.ftp_last,
                            }).ok_or(acc)
                        Err(_) => acc
                    }
                Err(_) => List.append(acc, { fam: r.fam, n: r.n, ftp_lo: r.ftp_lo, ftp_hi: r.ftp_hi, ftp_first: r.ftp_hi, ftp_last: r.ftp_hi })
            })
    season! : {} => Try({}, _)
    season! = |_| {
        path = Db.open_db!({})?
        day_rows = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT COALESCE(day, '') AS day, CAST(COALESCE(tss, 0) AS REAL) AS tss,
                \\       CAST(COALESCE(ctl, 0) AS REAL) AS ctl,
                \\       CAST(COALESCE(atl, 0) AS REAL) AS atl,
                \\       CAST(COALESCE(tsb, 0) AS REAL) AS tsb
                \\FROM daily_load ORDER BY day
            ,
            bindings: [],
            rows: |cols| |stmt| {
                d = Sqlite.str("day")(cols)(stmt)?
                tss = Sqlite.f64("tss")(cols)(stmt)?
                ctl = Sqlite.f64("ctl")(cols)(stmt)?
                atl = Sqlite.f64("atl")(cols)(stmt)?
                tsb = Sqlite.f64("tsb")(cols)(stmt)?
                # NOT ok_or(0): an unparseable day became epoch 0 and produced a
                # block with span_weeks -2937 and zero load at exit 0. `summary`
                # refuses the same row loudly, and so should this. Parseable is
                # not enough either -- date_str_to_days accepts "2026-3-05",
                # which sorts after every 2026-1x day and yielded span_weeks -6.
                days = (Metrics.usable_date_days(d)).map_err(|_| BadDailyLoadDay(d))?
                Ok({ days, tss, ctl, atl, tsb })
            },
        })?
        if List.is_empty(day_rows) {
            Output.err_out!("no_activities", "no scored training days yet — `stride sync` then `stride analyze` builds the history a season is read from")
        } else {
            # Per date AND family. Block boundaries come from the weekly series
            # and have no SQL expression, so the bucketing happens in Roc.
            pol_rows = Sqlite.query_many!({
                path: Path.utf8(path),
                query:
                    \\SELECT COALESCE(substr(a.start_local, 1, 10), '') AS date,
                    \\       COALESCE(a.sport_family, a.sport_type) AS fam,
                    \\       COUNT(*) AS n,
                    \\       -- the house fallback (see zone_sum!): the pi_* split when the activity
                    \\       -- has one -- power-derived with watts, pace-derived for a distance
                    \\       -- sport without them -- else the HR zones. Summing the pi_ columns
                    \\       -- raw drops every session without a split -- 50 of 731 here, 46 of which
                    \\       -- DO have zone seconds, and overwhelmingly easy ones, so the raw sum
                    \\       -- understates easy time and disagrees with what `summary` publishes.
                    \\       CAST(COALESCE(SUM(CASE WHEN COALESCE(m.pi_easy_s,0)+COALESCE(m.pi_moderate_s,0)+COALESCE(m.pi_hard_s,0) > 0 THEN m.pi_easy_s ELSE m.z1_s + m.z2_s END), 0) AS REAL) AS easy_s,
                    \\       CAST(COALESCE(SUM(CASE WHEN COALESCE(m.pi_easy_s,0)+COALESCE(m.pi_moderate_s,0)+COALESCE(m.pi_hard_s,0) > 0 THEN m.pi_moderate_s ELSE m.z3_s END), 0) AS REAL) AS mod_s,
                    \\       CAST(COALESCE(SUM(CASE WHEN COALESCE(m.pi_easy_s,0)+COALESCE(m.pi_moderate_s,0)+COALESCE(m.pi_hard_s,0) > 0 THEN m.pi_hard_s ELSE m.z4_s + m.z5_s END), 0) AS REAL) AS hard_s,
                    \\       CAST(COALESCE(MIN(NULLIF(m.ftp_used, 0)), 0) AS REAL) AS ftp_lo,
                    \\       CAST(COALESCE(MAX(m.ftp_used), 0) AS REAL) AS ftp_hi,
                    \\       -- an id from the group, carried ONLY so a refused date can name a row
                    \\       -- the user can act on. The envelope used to carry the date alone, and a
                    \\       -- date is not something you can delete or re-fetch (#243).
                    \\       -- MIN, and `fam` in the ORDER BY, because neither gives alone what it
                    \\       -- looks like it gives. The grouping is (date, fam), NOT date alone: one
                    \\       -- unreadable date shared by a Run and a Ride is TWO groups, so MIN picks
                    \\       -- the lowest id WITHIN the group the walk reaches first — which is not
                    \\       -- the lowest id for that date. Review measured it: 900 (Run) and 901
                    \\       -- (Ride) on one bad date named 901.
                    \\       -- What `fam` in the ORDER BY buys is that "first" is OUR statement and
                    \\       -- not SQLite's. The property is that one database names one row every
                    \\       -- time, so a bug report reproduces; it is NOT that the id is globally
                    \\       -- smallest, and two bad rows still take two repairs.
                    \\       MIN(a.id) AS example_id
                    \\FROM activities a LEFT JOIN activity_metrics m ON m.activity_id = a.id
                    \\GROUP BY date, fam ORDER BY date, fam
                ,
                bindings: [],
                rows: |cols| |stmt| {
                    d = Sqlite.str("date")(cols)(stmt)?
                    fam = Sqlite.str("fam")(cols)(stmt)?
                    n = Sqlite.i64("n")(cols)(stmt)?
                    easy_s = Sqlite.f64("easy_s")(cols)(stmt)?
                    mod_s = Sqlite.f64("mod_s")(cols)(stmt)?
                    hard_s = Sqlite.f64("hard_s")(cols)(stmt)?
                    ftp_lo = Sqlite.f64("ftp_lo")(cols)(stmt)?
                    ftp_hi = Sqlite.f64("ftp_hi")(cols)(stmt)?
                    example_id = Sqlite.i64("example_id")(cols)(stmt)?
                    # Same rule as daily_load.day: absorbing this silently drops
                    # the activity from sessions, polarization AND the threshold
                    # range with no trace at exit 0. And a merely-PARSEABLE date
                    # is not enough: "2026-3-01T" sorts last, so it became
                    # ftp_end for its month and its block and published the
                    # threshold running backwards.
                    #
                    # "2026-3-01T", with the T: `d` is substr(start_local, 1, 10), so
                    # every value named in these comments and in the error message is a
                    # ten-character PREFIX of the column, never the column. Three separate
                    # comments here quoted the pre-substr value, and that slip is what put
                    # a string no row contains into a user-facing "delete this" message.
                    days = (Metrics.usable_date_days(d)).map_err(|_| BadActivityDate(d, example_id))?
                    Ok({ days, fam, n, easy_s, mod_s, hard_s, ftp_lo, ftp_hi })
                },
            })?
            month_load = Sqlite.query_many!({
                path: Path.utf8(path),
                query:
                    \\SELECT substr(day, 1, 7) AS month, CAST(COALESCE(SUM(tss), 0) AS REAL) AS load
                    \\FROM daily_load GROUP BY month ORDER BY month
                ,
                bindings: [],
                rows: |cols| |stmt| {
                    month = Sqlite.str("month")(cols)(stmt)?
                    load = Sqlite.f64("load")(cols)(stmt)?
                    Ok({ month, load })
                },
            })?
            weeks = Metrics.weekly_rollup(day_rows)
            # a week whose Sunday has not passed is still accumulating, so its
            # load is a partial sum and cannot be regressed against full weeks
            today = Db.local_today_days!(path)
            blocks = Metrics.season_blocks(
                List.map(weeks, |w| { week_start: w.week_start, tss: w.tss, sessions: w.sessions, complete: w.week_start + 6 < today }),
                season_gap_weeks,
            )
            nblocks = (List.len(blocks)).to_i64_wrap()
            # the Monday convention weekly_rollup uses, so `closed` is decided
            # on the same axis the blocks were cut on
            this_week = ((today + 3) // 7) * 7 - 3
            built = List.map_with_index(blocks, |b, idx| {
                block_idx = (idx).to_i64_wrap()
                # The block ends on its last TRAINING day, not the Sunday that
                # closes its last training week -- the latter dated the current
                # block up to six days into the future.
                week_end = b.last_week + 6
                trained_days = List.keep_if(day_rows, |r| r.tss > 0.0 and r.days >= b.first_week and r.days <= week_end)
                last_day = List.fold(trained_days, b.first_week, |acc, r| if r.days > acc r.days else acc)
                inside = List.keep_if(pol_rows, |r| r.days >= b.first_week and r.days <= week_end)
                easy = List.fold(inside, 0.0, |a, r| a + r.easy_s)
                moderate = List.fold(inside, 0.0, |a, r| a + r.mod_s)
                hard = List.fold(inside, 0.0, |a, r| a + r.hard_s)
                pcts = Metrics.coverage_pcts(easy, moderate, hard)
                # collapse the per-date rows to one row per family before
                # picking the dominant one
                fams = fold_families(inside)
                ftp = dominant_ftp(fams)
                # `weeks` counts weeks WITH training; `span_weeks` counts the
                # calendar weeks the block covers. They differ wherever a rest
                # week sits inside a block, and dividing the load by the former
                # while printing the latter's dates overstated the mean by 8%
                # on the longest block here.
                span_weeks = (week_end - b.first_week) // 7 + 1
                # A block is CLOSED when an absence ended it. The most recent
                # one usually has not been: records simply stop. This must be
                # asked in the SAME terms the boundary rule uses -- week starts,
                # not days -- or it answers a different question: comparing
                # today to the last training DAY (which sits anywhere inside its
                # week) declared blocks closed up to 7 days before a session
                # today would actually have opened a new one.
                closed : Bool
                closed = block_idx + 1 < nblocks or this_week - b.last_week >= (season_gap_weeks + 1) * 7
                {
                    start_date: Metrics.days_to_date_str(b.first_week),
                    end_date: Metrics.days_to_date_str(last_day),
                    weeks: b.weeks,
                    span_weeks,
                    closed,
                    total_load: b.total_load,
                    mean_weekly_load: if span_weeks > 0 b.total_load / (span_weeks).to_f64() else 0.0,
                    # Activities, not days-with-load: weekly_rollup counts a day
                    # as one session because daily_load carries load and not a
                    # count, which lost 9 of 731. It is NOT required to equal
                    # months[].sessions -- an activity that scored no load
                    # inside an absence belongs to a month and to no block, and
                    # one dated before any daily_load row belongs to neither.
                    sessions: List.fold(inside, 0, |acc, r| acc + r.n),
                    slope_tss_per_week: b.slope,
                    trend_r2: b.r2,
                    trend_known: b.trend_known,
                    # the fitted line's own endpoints: a slope plus a low r2
                    # gets read as "no trend", but r2 is scatter, not whether
                    # the slope differs from zero
                    fitted_start_load: b.fitted_start,
                    fitted_end_load: b.fitted_end,
                    easy_pct: pcts.high_pct,
                    moderate_pct: pcts.medium_pct,
                    hard_pct: pcts.low_pct,
                    polarization_known: easy + moderate + hard > 0.0,
                    ftp_family: ftp.ftp_family,
                    ftp_lo: ftp.ftp_lo,
                    ftp_hi: ftp.ftp_hi,
                    ftp_family_pct: ftp.ftp_family_pct,
                    # chronological, so the range stops reading as a direction
                    # it does not have: this block is lo 234 / hi 271 but ran
                    # 234 -> 271 -> 243 -> 239, and `zones` reports 239
                    ftp_start: ftp.ftp_start,
                    ftp_end: ftp.ftp_end,
                    ftp_known: ftp.ftp_known,
                }
            })
            this_month = Metrics.month_key(today)
            months = List.map(month_load, |m| {
                fams = fold_families(List.keep_if(pol_rows, |r| Metrics.month_key(r.days) == m.month))
                ftp = dominant_ftp(fams)
                sessions = List.fold(fams, 0, |a, f| a + f.n)
                {
                    month: m.month,
                    load: m.load,
                    sessions,
                    # the trailing month is almost always partial, and comparing its load
                    # to a full one reads as a collapse when the DAILY RATE is often
                    # higher. No worked example here on purpose: a partial month grows,
                    # so the totals and the percentage between them go stale on the next
                    # sync -- one edit already turned a correct figure into a wrong one
                    # and left the percentage beside it contradicting the new number.
                    partial: m.month == this_month,
                    ftp_family: ftp.ftp_family,
                    ftp_lo: ftp.ftp_lo,
                    ftp_hi: ftp.ftp_hi,
                    ftp_family_pct: ftp.ftp_family_pct,
                    ftp_start: ftp.ftp_start,
                    ftp_end: ftp.ftp_end,
                    ftp_known: ftp.ftp_known,
                }
            })
            Output.out!(
                { gap_weeks: season_gap_weeks, blocks: built, months },
                Render.season_screen,
            )
        }
    }
    # The athlete's CP/W' fit for ONE SPORT FAMILY as of a DATE, over the same
    # 2-20 minute band power-curve fits (#186/#187 spend this model, so they
    # must not fit a second, differently-shaped one).
    #
    # Strictly BEFORE the date, not on-or-before: a ride inside its own fit
    # window raises the very W' it is then measured against. Review measured
    # the swing on this athlete's breakthrough 3x12 — W' 2490 J excluding the
    # ride, 6416 J including it, a 2.58x change in the denominator that scales
    # every W' number for that ride, and it fires precisely on the rides where
    # the athlete did something new.
    #
    # The family is the CALLER's, never a hardcoded Ride: a rowing session was
    # being scored against a cyclist's CP and flagged known, which is worse than
    # having no number at all.
}
