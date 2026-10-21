Adapter :: [].{
    # ── the adapter contract: what every strength-set parser must keep ──
    # Strava's public API carries no per-exercise sets. What stride holds for
    # a strength session is TEXT from one of two places: the structured log
    # Strava's MCP connector returns, which a coach hands to `stride strength
    # import` and strength_logs stores as JSON, or the activity DESCRIPTION,
    # where the athlete pastes their strength app's share summary (#478).
    # Different sources write different grammars, so parsing is an ADAPTER
    # PACK: one module per source in this package, each a pure function from
    # that text to set rows, registered in `src/cli/Strength.roc`'s `adapters`
    # table and tried in order — the first to yield rows names the row's
    # provenance. One text comes from ONE source, so first-non-empty is format
    # detection, not a merge.
    #
    # Every adapter keeps this contract: pure `Str -> List(SetRow)`; TOLERANT
    # (junk yields no rows, never an error — the source is a human paste or
    # an upstream payload stride does not control); SILENT on formats it does
    # not recognize (the empty list is what lets the next adapter speak); and
    # it ships with a real sample of its source's text as a top-level
    # `sample : Str`, pinned by its own expects — `tools/adapter-fixtures.sh`
    # refuses a module without one. A SetRow's weight_kg is the mass one rep
    # MOVES, with any per-side bookkeeping the format states already
    # resolved, so tonnage stays sets × reps × weight_kg whatever the format
    # wrote.
    #
    # Everything downstream (the notes drain, the strength_sets rebuild, the
    # tonnage view, the career spine) is format-blind: supporting another
    # athlete's app is one module here, its sample expect, and one row in
    # the table — no sync, schema, or viz change.

    # a row is what one exercise line prescribes: `sets` × `reps` at
    # `weight_kg` per rep, so tonnage is their product
    SetRow : { exercise : Str, sets : I64, reps : I64, weight_kg : F64 }
}
