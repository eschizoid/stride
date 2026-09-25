import Db
import Output
import Render
import core.Units
import pf.Sqlite
import pf.Path

ReportStrength :: [].{
    # ── the strength report: per-exercise progression + tonnage with its
    # coverage (#522) ────────────────────────────────────────────────────
    #
    # Tonnage is volume, not strength: a month's total falls when pull work
    # gives way to isolation whatever happened to the athlete's capacity, so
    # the figure that answers "am I getting stronger" is each repeated
    # exercise's working weight over time. This command publishes both, and
    # never a verdict — whether a trend is good is the coach's sentence to
    # write (ADR 0012).
    #
    # Every figure rides with the fact that qualifies it. Monthly tonnage
    # carries covered/total (strength_coverage — tracked sessions carry a
    # pasted breakdown, instructor-led classes never can, so a bare total
    # reads a coverage shift as a training trend), and a month the spine
    # view refuses still appears here with tonnage_known false: the report
    # lists what the chart withholds, because a table can qualify a number
    # where a curve cannot. The session counts make the gaps themselves
    # visible: a pasted session that parsed to nothing is a different fact
    # from a session never pasted, and both are different from covered.
    strength! : {} => Try({}, _)
    strength! = |{}| {
        path = Db.open_db!({})?
        units = Db.units!(path)?
        # per (exercise, day): the heaviest weight one rep moved, and the
        # day's summed kg·reps for that exercise. Two aggregates rather than
        # "the top set", because when the weight drops and the reps rise the
        # product is the only number that says whether work went up.
        points = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT CAST(s.exercise AS TEXT) AS ex,
                \\       substr(CAST(a.start_local AS TEXT), 1, 10) AS day,
                \\       CAST(MAX(s.weight_kg) AS REAL) AS top_kg,
                \\       CAST(SUM(s.sets * s.reps * s.weight_kg) AS REAL) AS kg_reps
                \\FROM strength_sets s JOIN activities a ON a.id = s.activity_id
                \\GROUP BY CAST(s.exercise AS TEXT), substr(CAST(a.start_local AS TEXT), 1, 10)
                \\ORDER BY CAST(s.exercise AS TEXT), substr(CAST(a.start_local AS TEXT), 1, 10)
            ,
            bindings: [],
            rows: |cols| |stmt| {
                ex = Sqlite.str("ex")(cols)(stmt)?
                day = Sqlite.str("day")(cols)(stmt)?
                top_kg = Sqlite.f64("top_kg")(cols)(stmt)?
                kg_reps = Sqlite.f64("kg_reps")(cols)(stmt)?
                Ok({ ex, day, top_kg, kg_reps })
            },
        })?
        # rows arrive sorted by (exercise, day); fold adjacent runs into one
        # entry per exercise. Prepend + reverse, never concat-in-fold.
        grouped = List.fold(points, [], |acc, p|
            match acc {
                [head, .. as rest] if head.exercise == p.ex =>
                    List.prepend(rest, { exercise: head.exercise, points: List.append(head.points, { date: p.day, top_kg: p.top_kg, kg_reps: p.kg_reps }) })
                _ =>
                    List.prepend(acc, { exercise: p.ex, points: [{ date: p.day, top_kg: p.top_kg, kg_reps: p.kg_reps }] })
            })
        exercises = Render.reverse_list(grouped)
        # every strength month, from the COVERAGE view — not the spine view,
        # which refuses thin months. The LEFT JOIN's NULL is the refusal,
        # published as tonnage_known false (a both-possible field, ADR 0009).
        monthly = Sqlite.query_many!({
            path: Path.utf8(path),
            query:
                \\SELECT CAST(c.month AS TEXT) AS month,
                \\       CAST(COALESCE(t.value, 0) AS REAL) AS kg,
                \\       CASE WHEN t.value IS NULL THEN 0 ELSE 1 END AS known,
                \\       c.covered AS covered,
                \\       c.total AS total
                \\FROM strength_coverage c
                \\LEFT JOIN monthly_threshold t ON t.month = c.month AND t.fam = c.fam AND t.kind = 'tonnage'
                \\ORDER BY c.month
            ,
            bindings: [],
            rows: |cols| |stmt| {
                month = Sqlite.str("month")(cols)(stmt)?
                kg = Sqlite.f64("kg")(cols)(stmt)?
                known = Sqlite.i64("known")(cols)(stmt)?
                covered = Sqlite.i64("covered")(cols)(stmt)?
                total = Sqlite.i64("total")(cols)(stmt)?
                # Bool at the boundary, like every _known in the payload family —
                # a bare tag would serialize as the STRING "True"
                Ok({ month, kg, tonnage_known: known != 0, covered, total })
            },
        })?
        counts = Sqlite.query!({
            path: Path.utf8(path),
            query:
                \\SELECT COUNT(*) AS total,
                \\       COALESCE(SUM(CASE WHEN EXISTS (SELECT 1 FROM strength_sets s WHERE s.activity_id = a.id) THEN 1 ELSE 0 END), 0) AS with_sets,
                \\       COALESCE(SUM(CASE WHEN COALESCE(CAST(n.description AS TEXT), '') <> '' AND NOT EXISTS (SELECT 1 FROM strength_sets s WHERE s.activity_id = a.id) THEN 1 ELSE 0 END), 0) AS pasted_unparsed
                \\FROM activities a LEFT JOIN strength_notes n ON n.activity_id = a.id
                \\WHERE COALESCE(a.sport_family, a.sport_type) = 'WeightTraining'
            ,
            bindings: [],
            row: |cols| |stmt| {
                total = Sqlite.i64("total")(cols)(stmt)?
                with_sets = Sqlite.i64("with_sets")(cols)(stmt)?
                pasted_unparsed = Sqlite.i64("pasted_unparsed")(cols)(stmt)?
                Ok({ total, with_sets, pasted_unparsed })
            },
        })?
        # ANNOTATED and closed: the renderer below infers an open record, and
        # a new key would otherwise ship undeclared in schemas/v3 (ADR §9c)
        payload : { exercises : List({ exercise : Str, points : List({ date : Str, top_kg : F64, kg_reps : F64 }) }), monthly : List({ month : Str, kg : F64, tonnage_known : Bool, covered : I64, total : I64 }), sessions : { total : I64, with_sets : I64, pasted_unparsed : I64 } }
        payload = { exercises, monthly, sessions: counts }
        Output.out!(payload, |p| screen(units, p))
    }

    # numbers in tables, meaning in legends — and no verdict line at all:
    # progression is exactly the number a coach must not have pre-judged
    screen : [Metric, Imperial], { exercises : List({ exercise : Str, points : List({ date : Str, top_kg : F64, kg_reps : F64 }) }), monthly : List({ month : Str, kg : F64, tonnage_known : Bool, covered : I64, total : I64 }), sessions : { total : I64, with_sets : I64, pasted_unparsed : I64 } } -> Str
    screen = |units, p| {
        if p.sessions.total == 0 {
            "no strength sessions yet — they arrive with `stride sync` like every other activity"
        } else {
            # repeated exercises only: a first-and-latest pair needs two days.
            # The once-seen rest are counted, not hidden — the JSON has them.
            repeated = List.keep_if(p.exercises, |e| List.len(e.points) >= 2)
            once = List.len(p.exercises) - List.len(repeated)
            prog_rows = List.map(repeated, |e| {
                first = List.first(e.points).ok_or({ date: "", top_kg: 0.0, kg_reps: 0.0 })
                last = List.last(e.points).ok_or({ date: "", top_kg: 0.0, kg_reps: 0.0 })
                [
                    e.exercise,
                    (List.len(e.points)).to_str(),
                    "${first.date}  ${Units.mass_label(units, first.top_kg)}",
                    "${last.date}  ${Units.mass_label(units, last.top_kg)}",
                ]
            })
            # "more" needs an antecedent: with no table above it, the once-seen
            # count is the WHOLE story and says so on one line
            prog =
                if List.is_empty(repeated) {
                    if once > 0 {
                        "no exercise seen on two days yet — progression needs a repeat (${(once).to_str()} seen on one day each, in the JSON)"
                    } else {
                        "no exercise seen on two days yet — progression needs a repeat"
                    }
                } else {
                    Render.render_table(["exercise", "days", "first (top set)", "latest (top set)"], prog_rows)
                }
            once_note = if once > 0 and !(List.is_empty(repeated)) "\n(${(once).to_str()} more seen on one day — in the JSON)" else ""
            month_rows = List.map(p.monthly, |m| [
                m.month,
                if m.tonnage_known Units.mass_label(units, m.kg) else "-",
                "${(m.covered).to_str()}/${(m.total).to_str()}",
            ])
            months = Render.render_table(["month", "tonnage", "sessions with sets"], month_rows)
            # the legend the '-' needs, shown only when a '-' is on screen —
            # a legend for an absent symbol explains nothing
            legend =
                if List.any(p.monthly, |m| !(m.tonnage_known)) {
                    "\n(- = under a third of the month's sessions carry sets, so no tonnage is claimed)"
                } else {
                    ""
                }
            # "no readable set lines" rather than "a format stride does not
            # read": the class includes a caption-only description, which is
            # prose working as intended, not a format gap
            unparsed_note =
                if p.sessions.pasted_unparsed > 0 {
                    "\n${(p.sessions.pasted_unparsed).to_str()} pasted ${if p.sessions.pasted_unparsed == 1 "session" else "sessions"} carried no readable set lines"
                } else {
                    ""
                }
            # the capability, stated at the moment its absence is visible: an
            # athlete who never pastes cannot otherwise learn pasting exists
            gap = p.sessions.total - p.sessions.with_sets - p.sessions.pasted_unparsed
            # the noun agrees with the total, the verb with the gap: "1 of 5
            # strength sessions has", "1 of 1 strength session has"
            nudge =
                if gap > 0 {
                    noun = if p.sessions.total == 1 "session" else "sessions"
                    verb = if gap == 1 "has" else "have"
                    "\n${(gap).to_str()} of ${(p.sessions.total).to_str()} strength ${noun} ${verb} no recorded sets — paste the set breakdown into the activity description to track tonnage"
                } else {
                    ""
                }
            "${prog}${once_note}\n\n${months}${legend}${unparsed_note}${nudge}"
        }
    }
}
