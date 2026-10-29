import pf.Sqlite

# The engine's one door to SQLite. Every call names the database by path and
# runs on a connection of its own, so a statement never depends on state an
# earlier call left on a connection; work that must share one (a transaction)
# goes through `transaction!`.
#
# Parameters are named (`:name`) and bound by name: each one is rewritten to a
# numbered `?N` marker for its position in `bindings`, longest name first so
# `:s` cannot eat the front of `:start`. Rows decode through `|cols| |values|`
# functions built from the leaf readers below, which read a column by name.
# A row holding text that is not UTF-8 (a blob CAST to TEXT) is read again
# through `lossy_rows!`, which decodes such a cell with U+FFFD in place of the
# bad bytes, so one corrupt cell reaches the engine's content guards instead of
# failing the whole query.
# Failures speak the engine's vocabulary: `SqliteErr(code, message)`,
# `NoRowsReturned`, `TooManyRowsReturned`, `RowsReturnedUseQueryInstead`,
# `NoSuchField(name)` and `UnexpectedType(kind)`.
Sql :: [].{
    Binding : { name : Str, value : Sqlite.Value }

    # one statement that returns no rows
    execute! = |{ path, query, bindings }| {
        db = open!(path)?
        on_db!(db, query, bindings)
    }

    # a query that must return exactly one row
    query! = |{ path, query, bindings, row }| {
        db = open!(path)?
        match db.query_one!(to_query(query, bindings), Sqlite.Decoder.row) {
            Ok(r) => row(r.column_names)(r.values)
            Err(BadRow(_)) =>
                match lossy_rows!(db, query, bindings)? {
                    [r] => row(r.column_names)(r.values)
                    [] => Err(NoRowsReturned)
                    _ => Err(TooManyRowsReturned)
                }
            Err(e) => Err(widen(e))
        }
    }

    # a query returning any number of rows, decoded in order
    query_many! = |{ path, query, bindings, rows }| {
        db = open!(path)?
        all = match db.query_all!(to_query(query, bindings), Sqlite.Decoder.row) {
            Ok(rs) => rs
            Err(BadRow(_)) => lossy_rows!(db, query, bindings)?
            Err(e) => return Err(widen(e))
        }
        List.map_try(all, |r| rows(r.column_names)(r.values))
    }

    # run `body!` between BEGIN and COMMIT on one connection; `body!` gets a
    # statement runner bound to that connection. A failed body rolls back and
    # returns its own error, unless the ROLLBACK fails too: that failure (a
    # lock, corruption) is the more actionable one, so it wins
    transaction! = |path, body!| {
        db = open!(path)?
        run! = |query, bindings| on_db!(db, query, bindings)
        run!("BEGIN", [])?
        match body!(run!) {
            Ok(v) => {
                run!("COMMIT", [])?
                Ok(v)
            }
            Err(e) =>
                match run!("ROLLBACK", []) {
                    Ok(_) => Err(e)
                    Err(re) => Err(re)
                }
        }
    }

    # ── leaf readers ─────────────────────────────────────────────────────
    # Each reads one column by name and accepts only the storage class it
    # names: an integer column is not a REAL, and NULL is a value only to the
    # nullable readers, which answer `NotNull(v)` or `Null`.

    str = |name| |cols| |values|
        match lookup(cols, values, name) {
            Ok(String(s)) => Ok(s)
            Ok(other) => unexpected(other)
            Err(e) => Err(e)
        }

    i64 = |name| |cols| |values|
        match lookup(cols, values, name) {
            Ok(Integer(n)) => Ok(n)
            Ok(other) => unexpected(other)
            Err(e) => Err(e)
        }

    f64 = |name| |cols| |values|
        match lookup(cols, values, name) {
            Ok(Real(r)) => Ok(r)
            Ok(other) => unexpected(other)
            Err(e) => Err(e)
        }

    nullable_str = |name| |cols| |values|
        match lookup(cols, values, name) {
            Ok(String(s)) => Ok(NotNull(s))
            Ok(Null) => Ok(Null)
            Ok(other) => unexpected(other)
            Err(e) => Err(e)
        }

    nullable_f64 = |name| |cols| |values|
        match lookup(cols, values, name) {
            Ok(Real(r)) => Ok(NotNull(r))
            Ok(Null) => Ok(Null)
            Ok(other) => unexpected(other)
            Err(e) => Err(e)
        }

    # a lossy row's values: each column arrives as (value, hex) and a text
    # cell is the hex half, decoded with U+FFFD for bytes that are not UTF-8
    from_hex_pairs : List(Sqlite.Value) -> List(Sqlite.Value)
    from_hex_pairs = |pairs| {
        folded = List.fold(pairs, { out: [], pending: Null, odd: False }, |st, v|
            if st.odd {
                cell = match v {
                    String(h) => String(Str.from_utf8_lossy(unhex(h)))
                    _ => st.pending
                }
                { out: List.append(st.out, cell), pending: Null, odd: False }
            } else {
                { ..st, pending: v, odd: True }
            })
        folded.out
    }

    # `:name` parameters as numbered markers, in the order of `bindings`
    numbered : Str, List(Str) -> Str
    numbered = |sql, names| {
        indexed = List.map_with_index(names, |n, i| { n, i })
        longest_first = List.sort_with(indexed, |a, b| Str.count_utf8_bytes(b.n).order_relative_to(Str.count_utf8_bytes(a.n)))
        List.fold(longest_first, sql, |s, p| Str.replace_each(s, p.n, "?${(p.i + 1).to_str()}"))
    }
}

# The query's rows copied into a temporary table, then read back with every
# text cell as hex, which is always valid text, and decoded here lossily.
# Row order is the copy's insertion order, which is the query's own.
lossy_rows! : Sqlite.Db, Str, List(Sql.Binding) => Try(List(Sqlite.Row), _)
lossy_rows! = |db, query, bindings| {
    copy = "temp.stride_lossy"
    _ = db.execute_script!("DROP TABLE IF EXISTS ${copy}")
    db.execute!(Sqlite.Query.new("CREATE TEMP TABLE stride_lossy AS ${Sql.numbered(query, List.map(bindings, |b| b.name))}", List.map(bindings, |b| b.value))).map_err(widen)?
    names = db.query_all!("PRAGMA temp.table_info(stride_lossy)", Sqlite.Decoder.str("name")).map_err(widen)?
    cells = Str.join_with(
        List.map(names, |n| {
            q = "\"${Str.replace_each(n, "\"", "\"\"")}\""
            "CASE WHEN typeof(${q}) = 'text' THEN NULL ELSE ${q} END, CASE WHEN typeof(${q}) = 'text' THEN hex(${q}) END"
        }),
        ", ",
    )
    read = db.query_all!(Sqlite.Query.new("SELECT ${cells} FROM ${copy} ORDER BY rowid", []), Sqlite.Decoder.row).map_err(widen)
    _ = db.execute_script!("DROP TABLE IF EXISTS ${copy}")
    Ok(List.map(read?, |r| { column_names: names, values: Sql.from_hex_pairs(r.values) }))
}

open! = |path|
    match Sqlite.open!(path, {}) {
        Ok(db) => Ok(db)
        Err(e) => Err(widen(e))
    }

on_db! = |db, query, bindings|
    match db.execute!(to_query(query, bindings)) {
        Ok({}) => Ok({})
        Err(e) => Err(widen(e))
    }

to_query = |sql, bindings|
    Sqlite.Query.new(Sql.numbered(sql, List.map(bindings, |b| b.name)), List.map(bindings, |b| b.value))

lookup = |cols, values, name|
    match List.find_first_index(cols, |c| c == name) {
        Ok(i) =>
            match List.get(values, i) {
                Ok(v) => Ok(v)
                Err(_) => Err(NoSuchField(name))
            }
        Err(_) => Err(NoSuchField(name))
    }

unexpected = |value| {
    kind = match value {
        Integer(_) => Integer
        Real(_) => Real
        String(_) => String
        Bytes(_) => Bytes
        Null => Null
    }
    Err(UnexpectedType(kind))
}

# the platform's failures in the engine's shapes
widen = |err|
    match err {
        SqliteErr(Failed({ code, message, .. })) => SqliteErr(old_code(code), message)
        SqliteErr(ColumnNotFound(Name(name))) => NoSuchField(name)
        SqliteErr(ReturnsRows) => RowsReturnedUseQueryInstead
        SqliteErr(other) => SqliteErr(Error, Sqlite.Err.to_str(other))
        Interrupted => SqliteErr(Interrupt, "interrupted")
        Closed => SqliteErr(Misuse, "the connection is closed")
        BadRow(_) => SqliteErr(Mismatch, "a row did not decode")
        NoRows => NoRowsReturned
        TooManyRows => TooManyRowsReturned
    }

old_code = |code|
    match code {
        Error => Error
        Internal => Internal
        Perm => Perm
        Abort => Abort
        Busy => Busy
        Locked => Locked
        NoMem => NoMem
        ReadOnly => ReadOnly
        Interrupt => Interrupt
        Corrupt => Corrupt
        NotFound => NotFound
        Full => Full
        CanNotOpen => CanNotOpen
        Protocol => Protocol
        Empty => Empty
        Schema => Schema
        TooBig => TooBig
        Mismatch => Mismatch
        Misuse => Misuse
        NoLFS => NoLFS
        AuthDenied => AuthDenied
        Format => Format
        OutOfRange => OutOfRange
        NotADatabase => NotADatabase
        Io => IOErr
        Constraint(_) => Constraint
        Unknown(n) => Unknown(n)
    }

unhex : Str -> List(U8)
unhex = |h| {
    nibble = |c| if c >= 48 and c <= 57 (c - 48) else if c >= 65 and c <= 70 (c - 55) else if c >= 97 and c <= 102 (c - 87) else 0
    folded = List.fold(Str.to_utf8(h), { out: [], hi: 0, odd: False }, |st, c|
        if st.odd {
            { out: List.append(st.out, st.hi * 16 + nibble(c)), hi: 0, odd: False }
        } else {
            { ..st, hi: nibble(c), odd: True }
        })
    folded.out
}

expect Sql.from_hex_pairs([Integer(7), Null, Null, String("6869"), Null, String("fffe")]) == [Integer(7), String("hi"), String(Str.from_utf8_lossy([255, 254]))]
expect Sql.numbered("SELECT * FROM t WHERE a = :s AND b >= :start", [":s", ":start"]) == "SELECT * FROM t WHERE a = ?1 AND b >= ?2"
expect Sql.numbered("UPDATE t SET x = :id WHERE y = :id", [":id"]) == "UPDATE t SET x = ?1 WHERE y = ?1"
expect Sql.numbered("SELECT 1", []) == "SELECT 1"
