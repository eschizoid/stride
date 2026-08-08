# The same defect with a `match` around the list — this one takes the COMPILER down
# with SIGSEGV (fault address 0x0) rather than failing the expect.
#   roc test docs/repro/RocTupleClosureSegv.roc
# 08-04: 1 test passes.  08-05..08-08: Segmentation fault in the Roc compiler.
RocTupleClosureSegv :: [].{
    Row : { a : F64, b : F64 }

    render : Row, [Ef, Rpe] -> Str
    render = |row, lens| {
        cols =
            match lens {
                Ef => [
                    ("a", |r| F64.to_str(r.a)),
                    ("b", |r| F64.to_str(r.b)),
                ]
                Rpe => [
                    ("b", |r| F64.to_str(r.b)),
                ]
            }
        headers = List.map(cols, |c| c.0)
        cells = List.map(cols, |c| (c.1)(row))
        Str.join_with(List.concat(headers, cells), ",")
    }
}

expect Str.contains(RocTupleClosureSegv.render({ a: 1.0, b: 2.0 }, Ef), "a")
