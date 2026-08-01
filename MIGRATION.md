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

SEMANTICS (the deep one)
- Tag unions are **NOMINAL**, and `==` needs an **`is_eq` method on the type** — there
  is no auto-derive. So `Command.parse(x) == Ok(Init)` fails with "Command has no
  is_eq". Two ways to migrate a module's equality-based tests:
  1. Give the type an `is_eq` method (structural compare — big for a 27-variant union).
  2. Rewrite the assert to `match` the result and compare only primitive fields.
  Decide per type; primitives (Str, U64, Bool) already have `is_eq`.

## Module progress (pure first, then platform/app last)

- [x] `Config.roc` — compiles clean (namespace type-module).
- [~] `Command.roc` — compiles clean; `match`/`Try`/`U64.from_str`/type-module done,
      29 expects now RUN. **Remaining: nominal `is_eq`** — the equality-based expects
      need an `is_eq` on `Command`/`ParseErr` OR match-based rewrites.
- [ ] `Csv.roc`, `Schema.roc`, `Backfill.roc`, `Metrics.roc`, `Render.roc` (pure)
- [ ] `Streams.roc` — builtin JSON API (replaces roc-json Decode/Option)
- [ ] `app.roc` — basic-cli 0.20→0.21 (Http/Sqlite/Cmd/File) + builtin JSON. LAST.

Keep `main` on alpha4 until the whole thing is green on the new compiler.
