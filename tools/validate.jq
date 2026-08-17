# ── JSON Schema (subset) validator, in jq ────────────────────────────────
#
# Validates one instance against one schema and prints a line per violation;
# prints nothing when the instance conforms. The supported subset is exactly
# what stride's contract uses — "type" (object/array/string/number/integer/
# boolean), "properties", "required", "items", "enum", and "additionalKeys"
# (our own knob: when false, keys outside "properties" are reported, which is
# how a payload that GREW without a schema update gets caught).
#
# Deliberately NOT a general validator: no $ref, allOf/anyOf, patterns, or
# numeric bounds. A schema using them would silently pass those keywords, so
# `just schema-check` also asserts that every schema file sticks to the subset.

def typeof_ok($want): . as $v
  | if $want == "integer" then ($v | type) == "number" and ($v | floor) == $v
    elif $want == "number" then ($v | type) == "number"
    else ($v | type) == $want
    end;

def validate($schema; $path):
  . as $inst
  | [
      # type
      (if ($schema | has("type")) and ($inst | typeof_ok($schema.type) | not)
       then "\($path): expected \($schema.type), got \($inst | type)"
       else empty end),

      # enum
      (if ($schema | has("enum")) and ([$inst] - $schema.enum | length) > 0
       then "\($path): value \($inst | tojson) not in enum \($schema.enum | tojson)"
       else empty end),

      # required keys
      (if ($schema | has("required")) and ($inst | type) == "object"
       then ($schema.required[] as $k | select(($inst | has($k)) | not) | "\($path): missing required key \"\($k)\"")
       else empty end),

      # unexpected keys (contract drift: payload grew, schema did not)
      (if ($schema.additionalKeys? == false) and ($inst | type) == "object"
       then (($schema.properties // {}) as $props | $inst | keys[] as $k
             | select(($props | has($k)) | not)
             | "\($path): key \"\($k)\" is absent from the schema")
       else empty end),

      # recurse into known properties
      (if ($schema | has("properties")) and ($inst | type) == "object"
       then ($schema.properties | keys[]) as $k
            | select($inst | has($k))
            | ($inst[$k] | validate($schema.properties[$k]; "\($path).\($k)"))
       else empty end),

      # recurse into array items
      (if ($schema | has("items")) and ($inst | type) == "array"
       then range(0; $inst | length) as $i
            | ($inst[$i] | validate($schema.items; "\($path)[\($i)]"))
       else empty end)
    ][];

$schema[0] as $s | validate($s; $s.title // "payload")
