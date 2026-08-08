# Roc new-compiler notes (syntax, stdlib, platform)

Working reference for the new (Zig) compiler + basic-cli 0.21, learned empirically
against the compiler and roc-lang/roc source during the migration (completed
2026-08-02). The migration's progress log is gone — this is the part worth keeping.

## Toolchain pin: do not bump past `nightly-2026-August-04-1cb06bc` yet

Every nightly from **2026-08-05 onwards segfaults the compiler** on this codebase.
Verified on 2026-08-08: the 08-05, 08-06, 08-07, and 08-08 nightlies all crash; 08-04
(the current pin) passes all 179 Render tests. Nightlies live in `roc-lang/nightlies`, not
`roc-lang/roc`; note the tag format changed mid-window (`2026-August-05` → `2026-08-06`).

What breaks, precisely:

- `roc test src/Render.roc` → `Segmentation fault (SIGSEGV) in the Roc compiler`, fault
  address 0x0. Bisected in-repo to the **24th** expect, the one calling
  `Render.progress_section(..., Ef, Asc)`.
- `roc check` is fine on the new nightlies. `roc build` is not — see below; an earlier
  version of this note said it was, because a successful build was mistaken for a working
  binary without ever running it.

Two traps if you re-test this:

- **`roc test` on a copy outside the repo silently runs 0 expects** and exits 0 or 1 —
  it needs the file in its project context under its own module name. A bisect done on
  `/tmp/RenderCut.roc` "passes" every variant and tells you nothing. Bisect in-place
  (copy the original aside, truncate `src/Render.roc`, restore with a shell `trap`), and
  assert on the reported test COUNT, not just the exit code.
- The macOS asset you want is `roc_nightly-macos_x86_64-*`; `uname -m` on this machine
  reports `x86_64`, and the apple_silicon build dies with "bad CPU type in executable".

**Root cause: closures stored in tuples inside a list.** A seven-line module using
`[("a", |r| ...), ("b", |r| ...)]` and calling `c.1` fails with "hit a runtime error"; put
that list behind a `match` on a tag union and it escalates to `Segmentation fault (SIGSEGV)
in the Roc compiler`. The runnable repros live in the upstream issue, not in this repo.

That second shape is exactly `Render.progress_section`, which picks its column list
(header string + cell closure per column) by lens — which is why that one expect takes
the whole test run down.

**It is not confined to `roc test`.** `roc build` is hit too, and worse, a program can
build with zero errors and then crash at runtime. An app whose value comes from argv (so
nothing folds at compile time) builds clean and dies with `[ROC CRASHED]` when run;
building stride itself with 08-08 succeeds and the binary then exits 139 with NO output at
all on `progress <date>`. A green build proves nothing on these nightlies.

Filed upstream as [roc-lang/roc#10693](https://github.com/roc-lang/roc/issues/10693).
When it closes, re-run the repros from that issue before touching the pin in `build.yml`.

## CLI flags: `=`, never a space

`--output=stride`, `--main=src/app.roc`, `--opt=dev`, `--target=x64musl`. A
space-separated `--output stride` fails with a confusing error — it broke a release
build once and a `roc test --main` invocation another time.

**Always build with `--opt=dev`.** The default is `--opt=speed`, whose LLVM backend
miscompiles this codebase (issue #32's intermittent SIGABRT; it also silently drops the
`progress` pace column, which e2e catches).

## Syntax

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
  (Zig-style). Keep the CONTENTS byte-identical (SQL text/alignment/comments
  unchanged) — only the Roc delimiter changes.
- **Integer division is `//`.** Bare `/` produces a Frac and won't type-check where an
  integer is expected.

## Stdlib renames

- `List.walk` → `List.fold`; `List.walk_until` → `List.fold_until`; `List.walk_with_index`
  → `List.fold_with_index` (closure `|acc, elem, index|`).
- `List.range(...)` + walk → **`Iter.fold(a..<b, init, fn)`** (or `a..=b` inclusive).
  The **`|>` pipe operator is REMOVED**. `List.range`/`At`/`Before` gone.
- `List.set(l,i,v)` now returns `Try(List, [OutOfBounds])` → chain `.ok_or(acc)`.
- `Str.to_u64` → `U64.from_str`; `Str.to_i64` → `I64.from_str` (err tag `BadNumStr`).
- `Num.to_str(x)` → `<Type>.to_str(x)` e.g. `I64.to_str`. `Num.to_f64(x)` → `x.to_f64()`;
  `Num.to_u64`(I64→U64) → `x.to_u64_wrap()`; `Num.to_i64`(U64→I64) → `x.to_i64_wrap()`.
- **Narrowing needs the `_wrap` form** — `.to_u8()` on a value that may exceed the range
  fails; use `.to_u8_wrap()`.
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
- **Floats have no `Eq`** — never `x == 0.0` in an expect; use `Num.abs(x) < 0.001`.
- Unchanged: `List.sum/all/any/is_empty/len/append/concat/repeat/first/last/get/map/map2/
  contains/find_first/keep_if/take_first/take_last`, `Str.trim/split_on/with_ascii_lowercased`,
  `${}` interpolation.

## Platform (basic-cli 0.21)

- Header: `app [main!] { pf: platform "…/0.21.0/….tar.zst" }`. HTTP data types
  (Method/Request/Response) come from the `http` package, not `pf`.
- **argv — decode with `OsStr.display`, never hand-match the tags.**
  `main!` receives `List([Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))])`,
  which IS the platform's `OsStr` type. Use:

  ```roc
  args = List.map(raw_args, |a| OsStr.display(a))
  ```

  `OsStr.display` decodes all three arms (including Windows UTF-16) best-effort,
  invalid text → U+FFFD. Roc has no `Str.from_utf16` builtin, but the platform owns
  the decoding, so macOS + Linux + Windows all just work.

  > Matching the tags by hand and stubbing `WindowsU16s(_) => ""` is how stride
  > shipped a Windows binary that ignored every argument (fixed in #46). Don't.
- **Sqlite API is ~UNCHANGED**: `Sqlite.query!({path, query, bindings, row})`,
  `query_many!`, `execute!`; decoders `Sqlite.i64/str/f64/u64/nullable_*`;
  `decode_record`; `Binding {name, value}`; `Value [Null, Real, Integer, String, Bytes]`
  all identical. ONE change: `path` is `Path.Path`, not `Str` — wrap via `Path.from_str`
  (import pf.Path).
- **Never `Sqlite.query!` a maybe-absent key** — a missing row is a deterministic
  SIGABRT (heap crash), not an `Err`. Load optional config with `query_many!` and
  treat the empty list as absent.

### Sqlite row decoders

The alpha4 record-builder form is GONE. New form is an explicit two-stage decoder:

```roc
row: |cols| |stmt| {
    id = Sqlite.i64("id")(cols)(stmt)?
    name = Sqlite.str("name")(cols)(stmt)?
    Ok({ id, name })
}
```

i.e. each `field: Sqlite.TYPE("col")` → `field = Sqlite.TYPE("col")(cols)(stmt)?`,
wrapped in `|cols| |stmt| { … Ok({ … }) }`. Single-column stays `row: Sqlite.str("x")`.
Also: `?` can map errors (`… ? |err| Tag(err)`); `for x in list { }` loops exist.

## Builtin JSON (roc-json is dropped)

- **Decode**: annotate the target type, then `Json.parse(str)`. Type-directed, no manual
  decoders. Returns `Try(T, [InvalidJson(Str), MissingRequiredField(Str), ..])`.
  `Json.parse_trailing_commas(str)` for lenient. Optional field: `Try(T, [Missing])`.
  So `Decode.from_bytes(Str.to_utf8(text), Json.utf8)` → `Json.parse(text)`.
- **Encode**: `Json.to_str(value) -> Str`. So `Encode.to_bytes(v, Json.utf8)` →
  `Json.to_str(v)`.
- **`null` inside a typed `List(F64)` is REJECTED** (the whole decode Errs). Fix:
  Str-replace `null` → `-1` in the raw JSON before parsing; stream values are never
  negative, so downstream `valid_hr`/`valid_watts` drop the `-1`s, preserving the
  index-aligned drop-nulls behaviour.
- A bare tag serializes as a STRING (`True` → `"True"`). Give JSON payload fields real
  `Bool` types, not bare tags.
