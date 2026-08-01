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

Keep `main` on alpha4 until the whole thing is green on the new compiler.
