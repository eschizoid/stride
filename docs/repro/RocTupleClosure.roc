# Minimal repro: closures stored in tuples inside a list break on Roc nightlies
# from 2026-08-05 onward. Passes on nightly-2026-August-04-1cb06bc (our pin).
#   roc test docs/repro/RocTupleClosure.roc
# 08-04: 1 test passes.  08-05..08-08: "hit a runtime error".
# Adding a `match` around the list escalates it to a compiler SIGSEGV — that is what
# takes down `roc test src/Render.roc` via progress_section.
RocTupleClosure :: [].{
    render : { a : F64 } -> Str
    render = |row| {
        cols = [("a", |r| F64.to_str(r.a)), ("b", |r| F64.to_str(r.a))]
        Str.join_with(List.map(cols, |c| (c.1)(row)), ",")
    }
}
expect Str.contains(RocTupleClosure.render({ a: 1.0 }), "1")
