# New-compiler migration (branch: new-compiler-migration)

**Why now:** roc-json is NOT a blocker — Luke confirmed on lukewilliamboswell/roc-json#52
that JSON parsing is a **builtin** in the new compiler. So the old "blocked on roc-json"
conclusion was wrong: we drop roc-json entirely and use builtin JSON.

**Toolchain:**
- New compiler side-by-side at `~/.local/roc-new/roc` (nightly `release-fast-f5556d8c`,
  x86_64). alpha4 at `~/.local/bin/roc` is UNTOUCHED so `main` keeps building/shipping.
- Target: basic-cli `0.21.0-rc4` (`.tar.zst`), builtin JSON (no roc-json).
- Verify per module: `~/.local/roc-new/roc check src/<M>.roc` and
  `~/.local/roc-new/roc test src/<M>.roc`.

## Ruleset (learned empirically against the compiler + roc-lang/roc source)

SYNTAX
- Module = **type-module**, no `module [...]` header. A namespace module:
  `Name :: [].{ <defs> }`. A tag-union module: `Name :: [Tag, Tag(Str), …].{ <defs> }`.
  A record-backed nominal type uses `:=`: `Name := { field : T }.{ <methods> }`.
- **Type application needs parens**: `List(Str)`, `Try(ok, err)`, `Dict(K, V)`.
- **`Result` → `Try(ok, err)`**; constructors stay `Ok`/`Err`.
- **`when … is` → `match … { Pattern => expr … }`** (braces, `=>` arms, no `is`).
- **`Bool.true`/`Bool.false` → `True`/`False`** (bare tags; `Bool.False` also works).
- Number parse/format live on the number type: **`U64.from_str(s)`**, `U64.to_str(n)`
  (NOT `Str.to_u64`/`Num.to_str`).
- **`expect`s go at file top level, OUTSIDE the `.{}` block, and reference members
  QUALIFIED** (`Command.parse(...)`). Inside the block they compile but `roc test`
  runs 0 of them — silent test loss, watch for it.
- **Filename MUST match the module type name** (`Csv.roc` → `Csv :: …`).
- **`if cond then a else b` → `if cond a else b`** (no `then`), or block form
  `if cond { … } else { … }`. Record branches work inline: `if c { ..r, x: 1 } else …`.
- **Record update `{ acc & f: v }` → spread `{ ..acc, f: v }`.**
- **Blocks with local bindings need `{ }`** — a `parse = |x| { y = …; z }` body, a
  match/if branch that binds, and an `expect { h = …; bool }` all need braces.
- **Number suffix `0u64` → `0.U64`.**
- **Multiline strings: `"""…"""` is GONE** → line-prefixed, each line starts with `\\`
  (Zig-style). Convert every triple-quoted SQL block to `\\`-prefixed lines with the
  CONTENTS byte-identical (SQL text/alignment/comments unchanged) — only the Roc
  delimiter changes. Critical for app.roc's many `"""` query blocks.

## STDLIB RENAME TABLE (from the Metrics migration — use for app.roc)
- `List.walk` → `List.fold`; `List.walk_until` → `List.fold_until`; `List.walk_with_index`
  → `List.fold_with_index` (closure `|acc, elem, index|`).
- `List.range(...)` + walk → **`Iter.fold(a..<b, init, fn)`** (or `a..=b` inclusive).
  The **`|>` pipe operator is REMOVED**. `List.range`/`At`/`Before` gone.
- `List.set(l,i,v)` now returns `Try(List, [OutOfBounds])` → chain `.ok_or(acc)`.
- `Str.to_u64` → `U64.from_str`; `Str.to_i64` → `I64.from_str` (err tag `BadNumStr`).
- `Num.to_str(x)` → `<Type>.to_str(x)` e.g. `I64.to_str`. `Num.to_f64(x)` → `x.to_f64()`;
  `Num.to_u64`(I64→U64) → `x.to_u64_wrap()`; `Num.to_i64`(U64→I64) → `x.to_i64_wrap()`.
- `Num.pow(x,y)` → `x.pow(y)`; `Num.max/min` → `x.max(y)/x.min(y)`; `Num.abs(x)` → `x.abs()`;
  `Num.rem(a,b)` → `a % b`; `Num.round(x)` → `x.round_to_u64_try().ok_or(0)` (or `_i64_`).
- **`Result` module is GONE → `Try` + methods**: `Result.with_default(r,d)` → `r.ok_or(d)`;
  `Result.map_ok` → `.map_ok`; `Result.map_err` → `.map_err`; `Result.is_ok/is_err` →
  `.is_ok()/.is_err()`.
- `Str.to_utf8(s)` → `s.to_utf8()` (method). `Str.split_first` err is now `NotFound`.
- **Record patterns are CLOSED by default** → partial destructure needs `{ field, .. }`.
- Number literals carry a typed suffix: `0.I64`, `0.0.F64`, `0.U64`, `3.5.F64`.
- Tag-union + `Try` equality IS auto-derived here, so `== Ok(x)` / `== SomeTag` often
  compiles — keep `==` when it does; fall back to match-based only when it errors.
- Unchanged: `List.sum/all/any/is_empty/len/append/concat/repeat/first/last/get/map/map2/
  contains/find_first/keep_if/take_first/take_last`, `Str.trim/split_on/with_ascii_lowercased`,
  `${}` interpolation.

SEMANTICS + STDLIB (the deep layers — the real grind)
- Tag unions are **NOMINAL**, and `==` needs an **`is_eq` method on the type** — no
  auto-derive. Migrate equality-based tests to **match-based** asserts
  (`match parse(x) { Ok(Init) => True; _ => False }`) — PROVEN on Command (29/29 pass).
  Primitives (Str, U64, Bool) and `List`/records-of-them already compare with `==`.
- **The stdlib is extensively renamed AND method-style (UFCS).** Confirmed so far:
  `List.walk` → `List.fold` / `list.fold(init, |acc, e| …)`. Expect many more per
  module (`walk_with_index`, `keep_oks`, `map2`, `with_default`, `Result.*` → `Try.*`,
  `Str.*` variants). This is the bulk of the per-module work — fix them by iterating
  `roc check`, which names each missing method precisely, and cross-check against
  roc-lang/roc `test/` + `src/glue` .roc files for the new name.

## Module progress (pure first, then platform/app last)

- [x] `Config.roc` — compiles clean (namespace type-module).
- [~] `Command.roc` — compiles clean; `match`/`Try`/`U64.from_str`/type-module done,
      29 expects now RUN. **Remaining: nominal `is_eq`** — the equality-based expects
      need an `is_eq` on `Command`/`ParseErr` OR match-based rewrites.
- [ ] `Csv.roc`, `Schema.roc`, `Backfill.roc`, `Metrics.roc`, `Render.roc` (pure)
- [ ] `Streams.roc` — builtin JSON API (replaces roc-json Decode/Option)
- [ ] `app.roc` — basic-cli 0.20→0.21 (Http/Sqlite/Cmd/File) + builtin JSON. LAST.

## Builtin JSON (roc-json is DROPPED — this is the replacement)
- **Decode**: annotate the target type, then `Json.parse(str)`. Type-directed, no manual
  decoders. Returns `Try(T, [InvalidJson(Str), MissingRequiredField(Str), ..])`.
  `Json.parse_trailing_commas(str)` for lenient. Optional field: `Try(T, [Missing])`.
  So `Decode.from_bytes(Str.to_utf8(text), Json.utf8)` → `Json.parse(text)`.
- **Encode**: `Json.to_str(value) -> Str`. So `Encode.to_bytes(v, Json.utf8)` → `Json.to_str(v)`.
- Streams: `StreamsResp`/`Option F64` decoders → a plain record type + `Json.parse`;
  JSON `null` → optional `Try(F64, [Missing])`. Drop `import json.*` entirely.

## app.roc — basic-cli 0.21 platform notes (researched, not yet applied)
- Header: `app [main!] { pf: platform "…/0.21.0-rc4/…tar.zst" }`.
- `main! : List([Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]) => Try({}, [Exit(I32), ..])`.
  Args are TAGGED now (no `Arg.display`): `List.map(raw, |a| match a { Utf8(s) => s, _ => "" })`.
- **Sqlite API is ~UNCHANGED**: `Sqlite.query!({path, query, bindings, row})`,
  `query_many!`, `execute!`; decoders `Sqlite.i64/str/f64/u64/nullable_*`;
  `decode_record`; `Binding {name, value}`; `Value [Null, Real, Integer, String, Bytes]`
  all identical. ONE change: `path` is `Path.Path`, not `Str` — wrap the db path via
  `Path.from_str` (import pf.Path). So open_db! returns/uses a Path.
- Modules exposed: Cmd, Env, File, Http, Sqlite, Stdin, Stdout, Stderr, Path, Utc, …
  HTTP data types (Method/Request/Response) now come from the `http` package, not pf.
- JSON: drop `Encode.to_bytes(v, Json.utf8)` → `Json.to_str(v)`; `Decode.from_bytes` →
  `Json.parse`. See Streams.roc for the working pattern.

Keep `main` on alpha4 until the whole thing is green on the new compiler.

- Streams null-in-array: builtin Json.parse REJECTS null in a typed List(F64)
  (whole decode Errs). Fix: Str-replace `null`->`-1` in the raw JSON before parse;
  stream values are never negative, so downstream valid_hr/valid_watts drop the -1s,
  preserving the old index-aligned drop-nulls behavior.
