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
            Err(e) => Err(widen(e))
        }
    }

    # a query returning any number of rows, decoded in order
    query_many! = |{ path, query, bindings, rows }| {
        db = open!(path)?
        match db.query_all!(to_query(query, bindings), Sqlite.Decoder.row) {
            Ok(all) => List.map_try(all, |r| rows(r.column_names)(r.values))
            Err(e) => Err(widen(e))
        }
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

    # `:name` parameters as numbered markers, in the order of `bindings`
    numbered : Str, List(Str) -> Str
    numbered = |sql, names| {
        indexed = List.map_with_index(names, |n, i| { n, i })
        longest_first = List.sort_with(indexed, |a, b| Str.count_utf8_bytes(b.n).order_relative_to(Str.count_utf8_bytes(a.n)))
        List.fold(longest_first, sql, |s, p| Str.replace_each(s, p.n, "?${(p.i + 1).to_str()}"))
    }
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

expect Sql.numbered("SELECT * FROM t WHERE a = :s AND b >= :start", [":s", ":start"]) == "SELECT * FROM t WHERE a = ?1 AND b >= ?2"
expect Sql.numbered("UPDATE t SET x = :id WHERE y = :id", [":id"]) == "UPDATE t SET x = ?1 WHERE y = ?1"
expect Sql.numbered("SELECT 1", []) == "SELECT 1"
