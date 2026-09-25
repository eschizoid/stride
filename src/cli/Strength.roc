import strength.Adapter
import strength.Peloton

Strength :: [].{
    # ── the strength-notes adapter pack: the TABLE and its dispatcher ──────
    # The parsers live in the `src/strength` package, one module per app,
    # each keeping the contract stated in `strength.Adapter`. This module
    # holds the ordered table that registers them and the dispatcher that
    # asks each in turn; it knows no grammar of its own. Supporting another
    # athlete's app is one module there, its sample expect, and one row here.

    SetRow : Adapter.SetRow

    # what one description parses to: the rows, and the NAME of the adapter
    # that read them — stored per row (strength_sets.source) so a career of
    # mixed apps stays distinguishable, the load_coverage discipline applied
    # to sets. "" with no rows means no adapter recognized the text.
    Parsed : { source : Str, rows : List(SetRow) }

    # ORDERED, and the order IS the disambiguation rule: adapters are tried
    # top to bottom and the first to yield rows wins, so a narrower grammar
    # goes ABOVE a broader one, and a new adapter's author owns the check
    # that their format does not claim text an existing adapter already
    # reads. `tools/adapter-fixtures.sh` pins this order and holds every row
    # to a module in the package (and every module to a row), so a reorder
    # or an unregistered parser is a deliberate edit to the pin, never a
    # silent one.
    adapters : List({ name : Str, parse : Str -> List(SetRow) })
    adapters = [{ name: "peloton", parse: Peloton.parse }]

    parse : Str -> Parsed
    parse = |text| first_recognized(adapters, text)

    first_recognized : List({ name : Str, parse : Str -> List(SetRow) }), Str -> Parsed
    first_recognized = |ads, text|
        match ads {
            [] => { source: "", rows: [] }
            [a, .. as rest] => {
                # parenthesized on purpose: `a.parse(text)` is method-call
                # syntax for `parse(a, text)` in this compiler
                rows = (a.parse)(text)
                if List.is_empty(rows) first_recognized(rest, text) else { source: a.name, rows }
            }
        }

    tonnage_kg : List(SetRow) -> F64
    tonnage_kg = |rows|
        List.fold(rows, 0.0, |acc, r| acc + (r.sets).to_f64() * (r.reps).to_f64() * r.weight_kg)
}

# tonnage is the product sum: 3×8×27.2155… + 3×16×11.3398… = 1197.48…
expect {
    p = Strength.parse("A\n3 × 8 • 30 lbs/side\nB\n3 × 8 reps/side • 25 lbs/side")
    (Strength.tonnage_kg(p.rows) - 1197.4838568).abs() < 0.01
}

# the dispatcher: the first adapter to yield rows names the provenance, and
# unrecognized text is "" with no rows — the honest-gap contract at the pack
# level, not just per adapter
expect {
    p = Strength.parse("A\n3 × 8 • 30 lbs")
    p.source == "peloton" and List.len(p.rows) == 1
}
expect {
    p = Strength.parse("a ride description no adapter recognizes")
    p.source == "" and List.is_empty(p.rows)
}
