# ── schema linter: keep schemas inside the validator's subset ────────────
#
# tools/validate.jq implements a SUBSET of JSON Schema. Any keyword outside it
# is silently ignored — which is the dangerous failure: `additionalProperties:
# false` is what a JSON-Schema-literate contributor writes instead of the house
# `additionalKeys: false`, it looks correct, and it would turn drift detection
# off for that object without a word. A denylist of known keywords cannot cover
# that (nor a typo'd `additionalkeys`), so this is a WHITELIST: every key in a
# schema POSITION must be one the validator actually reads — plus `description`,
# which is documentation for humans and is deliberately allowed through. (`title`
# IS read by validate.jq, as the violation path's prefix, so it is not an exception.)
#
# Schema positions are the root, each value of `properties`, and `items` —
# the same three places validate.jq recurses into. Keys INSIDE `properties`
# are field names and are not linted.

def allowed: ["title", "description", "type", "properties", "required", "items", "enum", "additionalKeys"];

def lint($path):
  . as $s
  | [
      (if ($s | type) == "object"
       then (($s | keys) - allowed) as $bad
            | select(($bad | length) > 0)
            | "\($path): unsupported schema keyword(s) \($bad | tojson) — validate.jq would ignore them"
       else empty end),
      (if ($s | has("properties"))
       then ($s.properties | keys[]) as $k | ($s.properties[$k] | lint("\($path).\($k)"))
       else empty end),
      (if ($s | has("items")) then ($s.items | lint("\($path)[]")) else empty end)
    ][];

lint(input_filename // "schema")
