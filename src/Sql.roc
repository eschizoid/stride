# ── SQL statement construction (pure) ───────────────────────────────
#
# WHY THIS MODULE EXISTS (#105, basic-cli#471): on basic-cli 0.21 + the pinned
# nightly, a HEAP-allocated Str passed inside a `bindings` list is freed twice —
# the host's teardown in hosted_sqlite_bind drops every element, and the generated
# caller drops them again. The second free corrupts whatever allocation has
# recycled the memory, which is bug C: weeks of intermittent aborts blamed on
# HTTP, JSON and SQL shapes in turn. Literal and inline (≤ small-string) Strs are
# immune, which is why the corruption was intermittent and why the e2e mock —
# every fixture string short — could never reproduce it.
#
# The `query:` argument does NOT have this bug (hosted_sqlite_prepare consumes it
# exactly once — proven clean under guard-malloc). So until upstream ships the fix
# (merged as basic-cli#472, unreleased), every statement is built through
# stmt/row/rows below: String bindings are rewritten into the query as escaped
# literals, and the bindings list that reaches the host carries only
# Integer/Real/Null, which hold no heap.
#
# Call sites keep writing ordinary parameterized SQL — `WHERE key = :key` plus a
# bindings list, String values included. The rewrite happens in exactly one place
# (expand), so when a fixed basic-cli release is consumable the whole workaround
# reverts by making expand the identity: `{ query, bindings: binds }`. No call
# site changes then; none should splice text by hand now.
Sql :: [].{

    # No Bytes arm on purpose: a heap List(U8) in a binding hits the same double-free
    # as a heap Str, and nothing in this codebase binds blobs. Deleting the arm makes
    # the first future blob a compile error here — a decision point — instead of a
    # silent re-opening of bug C. (Structurally this 4-arm union still unifies into
    # the platform's 5-arm Value.)
    Bind : { name : Str, value : [Null, Real(F64), Integer(I64), String(Str)] }

    # What actually reaches the host: the heap-free arms only. This being the
    # RETURN type of expand makes "no String reaches the host" compiler-checked,
    # not prose.
    HostBind : { name : Str, value : [Null, Real(F64), Integer(I64)] }

    # Byte-identical to basic-cli's Sqlite.Binding. The new compiler cannot
    # width-unify two rigid annotations, so the heap-free HostBind is widened
    # through to_platform below at the constructor boundary — the one place our
    # proof meets the platform's wider type.
    PlatformBind : { name : Str, value : [Null, Real(F64), Integer(I64), String(Str), Bytes(List(U8))] }

    to_platform : HostBind -> PlatformBind
    to_platform = |hb| {
        name: hb.name,
        value: match hb.value {
            Null => Null
            Real(r) => Real(r)
            Integer(n) => Integer(n)
        },
    }

    # A complete single-quoted SQL string literal, safely escaped.
    #
    #   quote("O'Brien")  == "'O''Brien'"
    #   quote("")         == "''"
    #
    # Single-quote doubling is the ONLY escape SQLite string literals need —
    # backslashes are ordinary characters there. A NUL byte inside the text is not
    # representable in a SQL literal; names arriving from JSON could theoretically
    # carry one, and it would make the statement fail LOUDLY as an SQL error
    # rather than corrupt anything, which is the acceptable direction.
    quote : Str -> Str
    quote = |s|
        "'${Str.replace_each(s, "'", "''")}'"

    # The workaround, contained: each String binding's :name is rewritten into the
    # query as a quoted literal and dropped from the list; Null/Real/Integer pass
    # through as real bindings.
    #
    # This is a single left-to-right scan of the ORIGINAL query, not iterated
    # replace_each — that distinction carries three invariants:
    #   - substituted VALUES are never rescanned, so user text containing another
    #     binding's `:token` cannot be corrupted by a later substitution;
    #   - a placeholder is the maximal `:identifier` run at its position, so `:id`
    #     can never clobber the `:id` prefix inside `:id2`, regardless of the
    #     other binding's type;
    #   - text inside '...' SQL literals is never treated as a placeholder.
    # A String binding whose name never matched a placeholder stays in the list
    # as Null (heap-free): the host then fails loudly with "unknown parameter",
    # exactly the pre-workaround behavior for a typo'd name. Silently dropping it
    # would instead write NULL through the orphaned placeholder.
    expand : Str, List(Bind) -> { query : Str, bindings : List(HostBind) }
    expand = |query, binds| {
        scanned = List.fold(Str.to_utf8(query), { out: [], tok: [], lit: False, cmt: False, dash: False, used: [] }, |acc, b| scan_byte(acc, b, binds))
        done = flush_tok(scanned, binds)
        kept = List.fold(binds, [], |acc, bnd|
            match bnd.value {
                String(_) =>
                    if List.contains(done.used, bnd.name) {
                        acc
                    } else {
                        # unmatched name: send a heap-free Null under the same name so
                        # the host raises "unknown parameter" — the loud pre-#105 error
                        List.append(acc, { name: bnd.name, value: Null })
                    }
                Null => List.append(acc, { name: bnd.name, value: Null })
                Real(r) => List.append(acc, { name: bnd.name, value: Real(r) })
                Integer(n) => List.append(acc, { name: bnd.name, value: Integer(n) })
            })
        out_query = match Str.from_utf8(done.out) {
            Ok(s) => s
            Err(_) => { crash "Sql.expand: unreachable — output assembled from valid UTF-8 pieces" }
        }
        { query: out_query, bindings: kept }
    }

    # a-z A-Z 0-9 _ — the characters that can continue a :placeholder name
    is_ident_byte : U8 -> Bool
    is_ident_byte = |b|
        (b >= 97 and b <= 122) or (b >= 65 and b <= 90) or (b >= 48 and b <= 57) or b == 95

    ScanState : { out : List(U8), tok : List(U8), lit : Bool, cmt : Bool, dash : Bool, used : List(Str) }

    scan_byte : ScanState, U8, List(Bind) -> ScanState
    scan_byte = |acc, b, binds|
        if acc.cmt {
            # inside a `-- ...` SQL line comment: opaque to end of line. Without
            # this, an apostrophe in comment prose (a real query says "a power
            # ride's threshold") flips literal-parity for the rest of the query.
            # /* */ block comments are not handled — none of our SQL uses them.
            { ..acc, out: List.append(acc.out, b), cmt: b != 10 }
        } else if acc.lit {
            # inside a '...' literal: placeholders don't exist here. A '' escape
            # just toggles lit off and back on at the next quote — harmless.
            { ..acc, out: List.append(acc.out, b), lit: b != 39 }
        } else if !(List.is_empty(acc.tok)) {
            if is_ident_byte(b) {
                { ..acc, tok: List.append(acc.tok, b) }
            } else {
                # token ended: resolve it, then reprocess this byte from scratch
                scan_byte(flush_tok(acc, binds), b, binds)
            }
        } else if b == 45 {
            if acc.dash {
                { ..acc, out: List.append(acc.out, b), cmt: True, dash: False }
            } else {
                { ..acc, out: List.append(acc.out, b), dash: True }
            }
        } else if b == 58 {
            { ..acc, tok: [58], dash: False }
        } else if b == 39 {
            { ..acc, out: List.append(acc.out, b), lit: True, dash: False }
        } else {
            { ..acc, out: List.append(acc.out, b), dash: False }
        }

    flush_tok : ScanState, List(Bind) -> ScanState
    flush_tok = |acc, binds|
        if List.is_empty(acc.tok) {
            acc
        } else if List.len(acc.tok) == 1 {
            # a lone ':' is not a placeholder
            { ..acc, out: List.concat(acc.out, acc.tok), tok: [] }
        } else {
            name = match Str.from_utf8(acc.tok) {
                Ok(s) => s
                Err(_) => { crash "Sql.expand: unreachable — placeholder tokens are ASCII" }
            }
            match string_bind_named(binds, name) {
                Found(s) => { ..acc, out: List.concat(acc.out, Str.to_utf8(quote(s))), tok: [], used: List.append(acc.used, name) }
                NotFound => { ..acc, out: List.concat(acc.out, acc.tok), tok: [] }
            }
        }

    string_bind_named : List(Bind), Str -> [Found(Str), NotFound]
    string_bind_named = |binds, name|
        List.fold(binds, NotFound, |acc, bnd|
            match acc {
                Found(s) => Found(s)
                NotFound =>
                    match bnd.value {
                        String(s) => if bnd.name == name Found(s) else NotFound
                        _ => NotFound
                    }
            })

    # Statement constructors — one per Sqlite call shape. `path` and the decoder
    # pass through untouched (type parameters keep this module platform-free).
    #
    #   Sqlite.execute!(Sql.stmt(db, "INSERT ... VALUES (:a, :b)", binds))?
    #   Sqlite.query!(Sql.row(db, "SELECT ... WHERE k = :k", binds, decoder))?
    #   Sqlite.query_many!(Sql.rows(db, "SELECT ...", binds, decoder))?
    stmt : p, Str, List(Bind) -> { path : p, query : Str, bindings : List(PlatformBind) }
    stmt = |path, query, binds| {
        q = expand(query, binds)
        { path, query: q.query, bindings: List.map(q.bindings, to_platform) }
    }

    row : p, Str, List(Bind), d -> { path : p, query : Str, bindings : List(PlatformBind), row : d }
    row = |path, query, binds, decoder| {
        q = expand(query, binds)
        { path, query: q.query, bindings: List.map(q.bindings, to_platform), row: decoder }
    }

    rows : p, Str, List(Bind), d -> { path : p, query : Str, bindings : List(PlatformBind), rows : d }
    rows = |path, query, binds, decoder| {
        q = expand(query, binds)
        { path, query: q.query, bindings: List.map(q.bindings, to_platform), rows: decoder }
    }
}

# ── quote ────────────────────────────────────────────────────────────

# the apostrophe case — the whole reason escaping exists
expect Sql.quote("O'Brien") == "'O''Brien'"

# already-doubled quotes must not collapse: each ' doubles independently
expect Sql.quote("it''s") == "'it''''s'"

# empty is a valid literal, not an error
expect Sql.quote("") == "''"

# nothing else is touched — backslashes, unicode, %, : are all plain text in a
# SQLite literal, and "escaping" them would corrupt the stored value
expect Sql.quote("a\\b%c:d — ünïcode") == "'a\\b%c:d — ünïcode'"

# a value that LOOKS like SQL stays inert data once quoted
expect Sql.quote("x'; DROP TABLE activities; --") == "'x''; DROP TABLE activities; --'"

# ── expand ───────────────────────────────────────────────────────────

# String bindings move into the query as quoted literals; numeric ones stay bindings
expect {
r = Sql.expand("INSERT INTO t VALUES (:name, :tss)", [
    { name: ":name", value: String("O'Brien") },
    { name: ":tss", value: Real(42.5) },
])
r.query == "INSERT INTO t VALUES ('O''Brien', :tss)" and List.map(r.bindings, |b| b.name) == [":tss"]
}

# a text-free statement passes through untouched, bindings and all
expect {
r = Sql.expand("SELECT * FROM t WHERE id = :id", [{ name: ":id", value: Integer(7) }])
r.query == "SELECT * FROM t WHERE id = :id" and List.len(r.bindings) == 1
}

# :id must not clobber the :id prefix inside :id2 — placeholders are maximal
# :identifier runs, so :id2 can never be read as :id + "2"
expect {
r = Sql.expand("SELECT * FROM t WHERE a = :id AND b = :id2", [
    { name: ":id", value: String("x") },
    { name: ":id2", value: String("y") },
])
r.query == "SELECT * FROM t WHERE a = 'x' AND b = 'y'" and r.bindings == []
}

# same protection when the longer-named binding is NUMERIC: :id2 must survive as a
# real placeholder, not get corrupted into 'x'2 (iterated replace_each did exactly that)
expect {
r = Sql.expand("SELECT * FROM t WHERE a = :id AND b = :id2", [
    { name: ":id", value: String("x") },
    { name: ":id2", value: Integer(7) },
])
r.query == "SELECT * FROM t WHERE a = 'x' AND b = :id2" and List.map(r.bindings, |b| b.name) == [":id2"]
}

# a substituted VALUE containing another binding's :token is data, never re-scanned —
# "easy :at first" as a prescription detail must survive byte-for-byte
expect {
r = Sql.expand("INSERT INTO t VALUES (:detail, :at)", [
    { name: ":detail", value: String("easy :at first") },
    { name: ":at", value: String("2026-08-14") },
])
r.query == "INSERT INTO t VALUES ('easy :at first', '2026-08-14')"
}

# a :token inside a '...' literal already in the query is SQL text, not a placeholder
expect {
r = Sql.expand("SELECT ':a' AS lit, :a AS v FROM t", [{ name: ":a", value: String("X") }])
r.query == "SELECT ':a' AS lit, 'X' AS v FROM t"
}

# no bindings, no changes
expect {
r = Sql.expand("SELECT 1", [])
r.query == "SELECT 1" and r.bindings == []
}

# a placeholder used twice in one query is substituted at both occurrences
expect {
r = Sql.expand("SELECT * FROM t WHERE (:s = '' OR sport = :s)", [{ name: ":s", value: String("Ride") }])
r.query == "SELECT * FROM t WHERE ('Ride' = '' OR sport = 'Ride')"
}

# Null rides the bindings list — only String moves into the query
expect {
r = Sql.expand("UPDATE t SET a = :a, b = :b", [
    { name: ":a", value: Null },
    { name: ":b", value: String("") },
])
r.query == "UPDATE t SET a = :a, b = ''" and List.map(r.bindings, |b| b.name) == [":a"]
}


# an apostrophe inside a SQL `--` comment is prose, not a literal opener — the
# placeholder after it must still substitute (a real query's comment says "ride's")
expect {
r = Sql.expand("SELECT a, -- the ride's threshold\n       :v AS v FROM t", [{ name: ":v", value: String("x") }])
r.query == "SELECT a, -- the ride's threshold\n       'x' AS v FROM t"
}

# a String binding whose name matches no placeholder is NOT silently dropped: it
# rides along as a heap-free Null so the host fails loudly with unknown parameter
expect {
r = Sql.expand("SELECT :a AS a FROM t", [
    { name: ":a", value: String("x") },
    { name: ":nmae", value: String("typo") },
])
r.query == "SELECT 'x' AS a FROM t" and r.bindings == [{ name: ":nmae", value: Null }]
}
