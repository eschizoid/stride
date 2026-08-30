#!/bin/sh
# Every TEXT column decoded by `Sqlite.str` OR `Sqlite.nullable_str` must be
# projected through `CAST(... AS TEXT)`.
#
# TEXT affinity converts INTEGER and REAL but NOT blobs: a blob from a hand-edit or
# bad import survives the column and a bare decode answers `UnexpectedType(Bytes)` ->
# `internal_error` — a data fault reported as a bug (#296, #307). This lint pairs each
# string decode with the projection producing its alias and fails on a bare column.
#
# Known limits, none firing on the tree today: a projection split across two
# source lines reports an empty expression; a comment quoting an old bare form
# above a wrapped projection is reported; `${Interpolated} AS alias` and
# `AS ${alias}` are not understood; two projections for one alias on one line
# keep only the last (grep -o is greedy). Stated rather than fixed — each needs
# a real SQL parse, and a gate whose limits are written down is one a reader can
# trust the rest of.
#
# Exactly two exemptions: `COUNT(` (integer) and `PRAGMA` (SQLite-generated). Every
# wider entry tried (MAX/MIN/group_concat/CASE) was false over a TEXT column — MAX over
# a mixed column PREFERS the blob (SQLite orders BLOB above TEXT).
set -eu
export LC_ALL=C
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

: > "$tmp/problems"
decodes=0
for f in src/*.roc; do
  # BOTH string decoders, ANY alias — a lowercase-only alias class misses
  # `Sqlite.str("sportType")` without moving the asserted count.
  grep -oE 'Sqlite\.(nullable_)?str\("[^"]*"\)' "$f" 2>/dev/null | sed 's/.*("//;s/")//' | sort -u > "$tmp/aliases" || true
  [ -s "$tmp/aliases" ] || continue
  while IFS= read -r alias; do
    [ -n "$alias" ] || continue
    decodes=$((decodes + 1))
    # The projection that names it: everything on the line BEFORE ` AS <alias>` — the
    # last whitespace token reads `substr(CAST(day AS TEXT), 1, 7) AS month` as `7)`.
    grep -o ".* AS $alias\\b" "$f" 2>/dev/null | sed "s/ AS $alias\$//" | sort -u > "$tmp/exprs" || true
    if [ ! -s "$tmp/exprs" ]; then
      # PRAGMA results are SQLite-generated — no blob can reach them.
      if grep -q "PRAGMA $alias" "$f" 2>/dev/null; then continue; fi
      # Otherwise the alias IS the column, selected bare. Scoped to the selecting LINE
      # and any table prefix: a file-wide grep let a neighbour's CAST vouch for a new
      # bare projection, and a fixed prefix set misreported `s.`/`m.`/`rt.` wraps.
      grep -E "(SELECT|,) *$alias *(,| FROM)" "$f" 2>/dev/null > "$tmp/bareline" || true
      if [ -s "$tmp/bareline" ]; then
        grep -qE "CAST\(([a-z_][a-z_0-9]*\.)?$alias AS TEXT\)" "$tmp/bareline" ||
          printf '%-24s %-22s selected bare on its own line, no CAST(... AS TEXT)\n' \
            "$(basename "$f")" "$alias" >> "$tmp/problems"
      else
        printf '%-24s %-22s no projection found for this decode\n' "$(basename "$f")" "$alias" >> "$tmp/problems"
      fi
      continue
    fi
    while IFS= read -r expr; do
      [ -n "$expr" ] || continue
      # Scope to THIS projection — an earlier projection's CAST must not vouch for this
      # alias. Boundary: the last ` AS <name>` that is not a type cast.
      tail_expr=$(printf '%s' "$expr" | awk '{
        # cut after the LAST `AS <name>` where <name> is an alias, not a TYPE — cutting
        # at any AS lands inside CAST(x AS TEXT) and takes that CAST as this alias\047s.
        n = 0
        for (i = 1; i <= NF; i++)
          if ($i == "AS" && i < NF && $(i+1) !~ /^(TEXT|REAL|INTEGER|BLOB|NUMERIC)([^A-Za-z_0-9]|$)/) n = i + 1
        out = ""
        for (i = n + 1; i <= NF; i++) out = out " " $i
        print (n ? out : $0)
      }')
      # Blank every balanced `CAST(… AS TEXT)` span, THEN look for a column reference
      # left in ARGUMENT position — "contains AS TEXT anywhere" lets one cast arm vouch
      # for every other, and `COALESCE(CAST(x AS TEXT), y, '')` is a live crash shape.
      # Cut at the first SELECT only AFTER blanking, so a wrapped `CAST((SELECT …))`
      # keeps its subquery; any SELECT still standing is top-level.
      bare=$(printf '%s' "$tail_expr" | awk '{
        line = $0; out = ""
        while ((i = index(line, "CAST(")) > 0) {
          out = out substr(line, 1, i - 1)
          rest = substr(line, i + 5); depth = 1; j = 0
          while (j < length(rest) && depth > 0) {
            j++; c = substr(rest, j, 1)
            if (c == "(") depth++; else if (c == ")") depth--
          }
          span = substr(rest, 1, j)
          out = out (span ~ /AS TEXT/ ? "@" : "CAST(" span)
          line = substr(rest, j + 1)
        }
        print out line
      }' | awk '{ i = index($0, "SELECT"); print (i ? substr($0, i + 7) : $0) }' |
        sed -e "s/'[^']*'/@/g" |
        grep -oE '[(,] *[a-z_][a-z_0-9]*(\.[a-z_][a-z_0-9]*)? *[,)]|(ELSE|THEN) +[a-z_][a-z_0-9]*(\.[a-z_][a-z_0-9]*)? *(END|ELSE|WHEN|$)' |
        sed -e 's/^[(,] *//' -e 's/ *[,)]$//' -e 's/^ELSE *//' -e 's/^THEN *//' -e 's/ *END$//' -e 's/ *ELSE$//' -e 's/ *WHEN$//' | head -1)
      case "$tail_expr" in
        *"AS TEXT"*|*"as text"*)
          # a cast is present — but only clean if nothing UNCAST survives beside it
          if [ -n "$bare" ]; then
            printf '%-24s %-22s %s  (uncast: %s)\n' "$(basename "$f")" "$alias" \
              "$(printf '%s' "$tail_expr" | tail -c 46)" "$bare" >> "$tmp/problems"
          fi
          ;;
        # `COUNT(` only — see the header for why the wider exemption list is false.
        *"COUNT("*) ;;
        # No exemption for quotes: `COALESCE(day, '') AS day` is the COMMON shape and
        # unsafe — COALESCE picks the blob (a blob is not NULL), not the fallback.
        *)
          printf '%-24s %-22s %s\n' "$(basename "$f")" "$alias" "$(printf '%s' "$tail_expr" | tail -c 46)" >> "$tmp/problems" ;;
      esac
    done < "$tmp/exprs"
  done < "$tmp/aliases"
done

# Asserted exactly, not as a floor — an enumeration that silently matches nothing
# prints the same clean line a healthy tree prints.
EXPECT_DECODES=57
if [ "$decodes" != "$EXPECT_DECODES" ]; then
  echo "blob-safety: inspected $decodes (file, alias) decode pairs, expected $EXPECT_DECODES."
  echo "blob-safety: if that change is intended, update the number in the same commit;"
  echo "blob-safety: if it is not, the decode scan stopped matching and this gate is blind."
  exit 1
fi

sort -u "$tmp/problems" > "$tmp/problems.u"; mv "$tmp/problems.u" "$tmp/problems"
n=$(wc -l < "$tmp/problems" | tr -d ' ')
if [ "$n" -gt 0 ]; then
  echo "blob-safety: $n TEXT decode(s) read a column that is not CAST to TEXT"
  echo
  sort -u "$tmp/problems"
  echo
  echo "A blob in any of these crashes the reading command with internal_error (#307)."
  echo "Wrap the projection: COALESCE(CAST(<col> AS TEXT), '') AS <alias>"
  exit 1
fi
echo "blob-safety: $decodes (file, alias) decode pairs across 91 call sites, every projection CAST to TEXT"
