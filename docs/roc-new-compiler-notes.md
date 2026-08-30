# Roc new-compiler notes (syntax, stdlib, platform)

Working reference for the new (Zig) compiler + basic-cli 0.22, learned empirically
against the compiler and roc-lang/roc source during the migration (completed
2026-08-02). The migration's progress log is gone — this is the part worth keeping.

## Toolchain pin: `nightly-2026-08-27-8fa1a34` (the hold below is LIFTED)

**Bumped 2026-08-30**, from `nightly-2026-08-23-fb208ba`. No source change. Verified on
x86_64 macOS before bumping: `just test` → `1068 == 1068` and ALL E2E CHECKS PASS, every
arm of `just e2e-sync` green. **08-28 and 08-29 are MISCOMPILED — do not bump past 08-27
without re-measuring**: both crash ~20 pure `Metrics` expects at runtime ("Roc
application crashed: runtime error" in list-heavy code — resample/sort paths), measured
on this machine with each nightly's own binary. The regression entered between 08-27 and
08-28; whoever bumps next should check it healed.

**Bumped 2026-08-24**, from `nightly-2026-08-17-b9ca140`. No migration cost this time —
no source change of any kind. Verified on x86_64 macOS before bumping: `roc check` clean,
`just build` clean, `just test` → `653 == 653` and ALL E2E CHECKS PASS, and every arm of
`just e2e-sync` green (41, 18, 12, 10, 8, 7). The arm64 job is CI's to prove; it was not
run locally, because this machine is x86_64 and the apple_silicon nightly will not
execute on it ("bad CPU type in executable").

**Resolved 2026-08-17.** The segfault described in this section is fixed upstream, and
the pin moved from `nightly-2026-August-04-1cb06bc` to `nightly-2026-08-17-b9ca140`.
Verified on the new pin: all eight modules green under `roc test`, `just e2e` → ALL E2E
CHECKS PASS. It was still broken on
2026-08-10 (`roc test` SIGSEGV on both `Render` and `Streams`), so the fix landed between
08-10 and 08-17.

Bumping cost one migration: `Range` no longer coerces to `Iter`, so every
`Iter.fold(0..<n, …)` needs `Iter.fold((0..<n).iter(), …)` — 41 call sites. The 16
`.abs()`-on-an-unresolved-type-variable errors that appeared alongside were downstream of
the range typing and vanished with it.

The history below is kept because the traps in it are real and will apply to the next bump.

### What the hold was about (historical)

Every nightly from **2026-08-05 onward segfaulted the compiler** on this codebase.
Verified on 2026-08-08: the 2026-08-05, 2026-08-06, 2026-08-07 and 2026-08-08 nightlies
all crash; 2026-08-04
(the pin at the time) passes: `roc test src/Render.roc`. Nightlies live in `roc-lang/nightlies`, not
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

**Root cause: closures stored in tuples inside a list.** The heart of it, excerpted from
the seven-line repro module:

```roc
cols = [("a", |r| F64.to_str(r.a)), ("b", |r| F64.to_str(r.a))]
Str.join_with(List.map(cols, |c| (c.1)(row)), ",")
```

(Both closures read `r.a` on purpose — that is the filed repro verbatim, and the second
field is irrelevant to the crash.)

That module fails with `hit a runtime error`. Put the same list behind a `match` on a tag
union and it escalates to `Segmentation fault (SIGSEGV) in the Roc compiler`. The runnable
repros live in the upstream issue, not in this repo.

That second shape is exactly `Render.progress_section`, which picks its column list
(header string + cell closure per column) by lens — which is why that one expect takes
the whole test run down.

**It is not confined to `roc test`.** `roc build` is hit too, and worse, a program can
build with zero errors and then crash at runtime. An app whose value comes from argv (so
nothing folds at compile time) builds clean and dies with `[ROC CRASHED]` when run;
building stride itself with the 2026-08-08 nightly succeeds and the binary then exits 139
with NO output at all on `progress <date>`. A green build proves nothing on these nightlies.

Filed upstream as [roc-lang/roc#10693](https://github.com/roc-lang/roc/issues/10693),
which is **still open** — the 2026-08-17 nightly no longer reproduces it, but nobody has
closed it, so "fixed upstream" is an observation and not a provenance.

**Checklist for the next bump** (this part is live, not history): the tag is pinned
**NINE times across FOUR files** — `build.yml` ×4, `manual-release.yml` ×2,
`release-please.yml` ×2, `verify-arm64.yml` ×1. An earlier version of this line said
three files and omitted `verify-arm64.yml` entirely, which would have shipped a stale pin
in the arm64 verification job. Always `grep -rln nightly-tag .github/workflows` and count,
rather than trusting this sentence.

## Behaviour that changed silently across a bump

`I64.from_str` / `U64.from_str` accept **exponent notation** on the 2026-08-17 pin and did
not on 2026-08-04: `"1e3"` was an error and is now 1000. Nothing in the suite could see it,
because no test passed an exponent as an argument — found only by differential-probing the
two compilers over a battery of parse inputs.

It reaches judgment-tier MUTATING commands: `skip 1e1 "<reason>"` was "skip needs a numeric
id" and now skips planned session 10. Dates typed on the CLI are unaffected — `is_canonical_date`
round-trips through `days_to_date_str`, so `week add 1e3-08-17 …` still refuses.

**Narrowed deliberately (#201), not pinned.** #197 pinned the accepting behaviour so a
bump could not move it silently; #201 then decided the surface on purpose. User-supplied
numbers go through `Metrics.arg_i64` / `arg_u64` (optional minus, then digits) and
`arg_f64` (the same, plus at most one dot), so the SHAPE stride accepts is defined by
those functions rather than inherited from whatever `from_str` does this month. The shape,
not the whole set — overflow stays the stdlib's call.

"User-supplied" turned out to mean more than argv, and each round of review found another
tier of it: the ids AND the other arguments of the same commands (`rate latest 1e1` wrote
a 10/10 rating while `rate 1e1 5` was correctly refused), the values behind `config set`,
and the ids AND DATES in an imported CSV — where `7e2` became id 700 and the upsert would
have overwritten a real activity, and "Jul 1e2" stored a non-canonical `start_local` that
string-windowing and day arithmetic disagree about. Config values are validated at the WRITE now, not just
narrowed at the read: refusing them only at the read made `config set hr_z1_max 1.18e2`
succeed, echo back, and then report missing_config. The e2e check was INVERTED rather than deleted: it
asserts the refusal, on a count argument and on a judgment-tier write, each mutation-proved
separately because the harness stops at the first failing check.

Do not "simplify" `arg_i64` back to a bare `from_str` — the narrowing is the fix. The lesson generalises:
a green suite proves the behaviour you TESTED is unchanged, and a compiler bump can move
behaviour you never thought to test. Differential-probe the primitives (float formatting,
integer parsing and wrapping, sort stability, division and modulo on negatives) against the
old compiler before trusting a bump.

## CLI flags: `=`, never a space

`--output=stride`, `--main=src/app.roc`, `--opt=dev`, `--target=x64musl`. A
space-separated `--output stride` fails with a confusing error — it broke a release
build once and a `roc test --main` invocation another time.

**Build with `--opt=dev`** — for build time (~14s against ~2min), not correctness: the
miscompile below was fixed by the 2026-08-17 pin. Historically the default `--opt=speed`
MISCOMPILED this codebase (issue #32's intermittent SIGABRT; it also silently dropped the
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
- **Floats have no `Eq`** — never `x == 0.0` in an expect; use `(x).abs() < 0.001`.
  (NOT `Num.abs` — see the method-style line above; it fails the build with DOES NOT EXIST.)
- Unchanged: `List.sum/all/any/is_empty/len/append/concat/repeat/first/last/get/map/map2/
  contains/find_first/keep_if/take_first/take_last`, `Str.trim/split_on/with_ascii_lowercased`,
  `${}` interpolation.

## Platform (basic-cli 0.22)

- Header: `app [main!] { pf: platform "…/0.22.0/….tar.zst" }`. HTTP data types
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
  all identical. ONE change: `path` is `Path.Path`, not `Str` — wrap via `Path.utf8`
  (import pf.Path). There is no `Path.from_str`; reaching for it fails the build with
  DOES NOT EXIST.
- **Never `Sqlite.query!` a maybe-absent key.** Load optional config with `query_many!`
  and treat the empty list as absent. (On basic-cli 0.21/0.22 a missing row returns
  `Err(NoRowsReturned)`, so an unhandled `?` exits 1. The deterministic SIGABRT this
  note used to claim was the alpha4 / 0.20 behaviour — the rule is unchanged, the
  failure mode is milder than advertised.)

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
