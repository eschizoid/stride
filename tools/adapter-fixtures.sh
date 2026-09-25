#!/bin/sh
# adapter-fixtures — ADR 0018's enforcement: every strength-notes adapter ships
# with a real sample of its app's share text, and the ordered table in
# src/cli/Strength.roc and the modules in src/strength agree exactly.
#
# Three checks, each a property the adapter pack states in prose and nothing
# else holds:
#   1. the table's ORDER is pinned — it is the disambiguation rule (the first
#      adapter to yield rows wins), so a reorder is a deliberate edit here;
#   2. every table row names a module in the package and every parser module
#      is a table row — a row with no module fails to compile, but a module
#      with no row compiles fine and reads as coverage it never gives;
#   3. every parser module carries a top-level `sample : Str` and an expect
#      that parses it — the fixture the contract requires, so the grammar is
#      pinned to text the app actually wrote rather than to the author's
#      memory of it.
#
# Reads source only: no binary, no database. The order is asserted EXACTLY,
# not as a floor — under a floor a deleted row stops matching while the gate
# prints the same clean line a healthy tree prints. An extractor that matches
# nothing is a failure, not a pass: silence is never a measurement.
set -eu
cd "$(dirname "$0")/.."

EXPECT_ORDER="${EXPECT_ORDER:-peloton}"

table=src/cli/Strength.roc
pkg=src/strength

# the rows in table order: `{ name: "peloton", parse: Peloton.parse }`
rows=$(grep -oE '\{ name: "[a-z0-9_]+", parse: [A-Z][A-Za-z0-9]*\.parse \}' "$table") || true
if [ -z "$rows" ]; then
  echo "adapter-fixtures: no adapter rows found in $table — the extractor matched nothing, refusing to pass blind" >&2
  exit 1
fi
order=$(printf '%s\n' "$rows" | sed -E 's/.*name: "([^"]+)".*/\1/' | paste -s -d ' ' -)
row_mods=$(printf '%s\n' "$rows" | sed -E 's/.*parse: ([A-Za-z0-9]+)\.parse.*/\1/' | sort)

# the parser modules: every .roc in the package except its header and the contract
pkg_mods=$(ls "$pkg"/*.roc | xargs -n1 basename | sed 's/\.roc$//' | grep -vE '^(package|Adapter)$' | sort)

fail=0
if [ "$order" != "$EXPECT_ORDER" ]; then
  echo "adapter-fixtures: table order is '$order', pinned '$EXPECT_ORDER' — a reorder changes which adapter wins; update EXPECT_ORDER on purpose" >&2
  fail=1
fi
if [ "$row_mods" != "$pkg_mods" ]; then
  echo "adapter-fixtures: the table's rows and the package's modules disagree" >&2
  echo "  rows name:   $(printf '%s\n' "$row_mods" | paste -s -d ' ' -)" >&2
  echo "  package has: $(printf '%s\n' "$pkg_mods" | paste -s -d ' ' -)" >&2
  fail=1
fi
for m in $pkg_mods; do
  f="$pkg/$m.roc"
  if ! grep -qE '^    sample : Str$' "$f"; then
    echo "adapter-fixtures: $f has no top-level \`sample : Str\` — an adapter ships a real sample of its app's share text" >&2
    fail=1
  fi
  if ! grep -qE "$m\\.parse\\($m\\.sample\\)" "$f"; then
    echo "adapter-fixtures: $f has no expect parsing its own sample (\`$m.parse($m.sample)\`)" >&2
    fail=1
  fi
done

[ "$fail" = 0 ] || exit 1
echo "adapter-fixtures: $(printf '%s\n' "$pkg_mods" | wc -l | tr -d ' ') adapter(s) in pinned order, each registered and shipping its sample"
