# New-compiler migration (branch: new-compiler-migration)

**Why now:** roc-json is NOT a blocker — Luke confirmed on lukewilliamboswell/roc-json#52
that JSON parsing is a **builtin** in the new compiler. So the old "blocked on roc-json"
conclusion (ADR §9) is wrong: we drop roc-json entirely and use builtin JSON.

**Toolchain:**
- New compiler installed side-by-side at `~/.local/roc-new/roc` (nightly
  `release-fast-f5556d8c`, 2026-07-31, x86_64). The alpha4 compiler at
  `~/.local/bin/roc` is UNTOUCHED so `main` keeps building/shipping.
- Target platform: basic-cli `0.21.0-rc4` (`.tar.zst`). JSON: builtin (no roc-json).

## Syntax ruleset (learned empirically + from basic-cli 0.21 source)

| Old (alpha4) | New |
|---|---|
| `module [a, b]` header | **type-module**: `Name :: [].{ … }` wrapping all defs, no header |
| `List Str`, `Result a b` | parens: `List(Str)`, and `Result`→**`Try(ok, err)`** |
| `Bool.true` / `Bool.false` | bare `True` / `False` |
| `Str => Result {} _` | `Str => Try({}, [SomeErr(..), ..])` (open error unions) |
| `import pf.Stdout` | same shape; platform is 0.21 |

`app` header still `app [main!] { pf: platform "…0.21.0-rc4…" }`; `main! = |_args| { … }`.

## Module progress (pure first, then platform/app last)

- [x] `Config.roc` — compiles clean on new compiler (the spike)
- [ ] `Streams.roc`
- [ ] `Csv.roc`
- [ ] `Schema.roc`
- [ ] `Backfill.roc`
- [ ] `Command.roc`
- [ ] `Render.roc`
- [ ] `Metrics.roc`
- [ ] `app.roc` — the big one: basic-cli 0.20→0.21 API changes (Http/Sqlite/Cmd/File)
      + roc-json → builtin JSON. Do LAST, after all pure modules check clean.

## Verify
`~/.local/roc-new/roc check src/<Module>.roc` per module; full build + e2e once app.roc lands.
Keep `main` on alpha4 until the whole thing is green on the new compiler.
