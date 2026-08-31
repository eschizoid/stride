# stride — common actions. `just` alone runs the full test suite.

# overridable: ROC=/path/to/roc STRIDE_LINKER="--linker=legacy" just test
# The exact compiler version is pinned in .github/workflows/build.yml (nightly-tag), which
# is what CI installs and what a contributor should match. This resolves whatever `roc` is
# on PATH rather than pinning a path, so set ROC= if you keep several versions around.
roc := env("ROC", "roc")
linker := env("STRIDE_LINKER", "")
# port the e2e-sync mock binds and the driver targets; overridable when 8799 is occupied
mock_port := env("MOCK_PORT", "8799")
# second mock instance, serving undecodable stream bodies (sync's undecodable-stream skip path)
bad_stream_port := env("BAD_STREAM_PORT", "8798")
# third instance, 429ing forever on one id (sync's rate_limited stop reason)
rate_limit_port := env("RATE_LIMIT_PORT", "8797")
# fifth instance, 500ing on one id (the 5xx boundary arm, salvaged from #225)
http500_port := env("HTTP500_PORT", "8795")
# sixth instance, 429ing on the LISTING (the list-429 stop, #235)
list429_port := env("LIST429_PORT", "8794")
# seventh instance, serving a FULL page then 429ing page two (the partial-progress half)
list429p_port := env("LIST429P_PORT", "8793")
# fourth instance, 401ing forever on one id (the token-refresh retry bound, #232)
auth401_port := env("AUTH401_PORT", "8796")

default: test

# type-check without building
check:
    {{roc}} check src/app.roc

# build the binary. --opt=dev on purpose, but for BUILD TIME (~14s against ~2min), not
# correctness: the optimized backend's miscompile (#32) was fixed by the 2026-08-17 pin.
# CI and the release workflow both pin dev, so match them here or `just test` tests a
# binary nobody ships.
build:
    {{roc}} build src/app.roc --output=stride --opt=dev {{linker}}

# full suite: pure expects -> fresh build (must succeed!) -> effectful e2e
test:
    {{roc}} test src/Metrics.roc
    {{roc}} test src/Sports.roc
    {{roc}} test src/Render.roc
    {{roc}} test src/Drain.roc
    {{roc}} test src/Csv.roc
    {{roc}} test src/Command.roc
    {{roc}} test src/Config.roc
    {{roc}} test --main=src/app.roc src/Streams.roc
    just build
    just e2e

# issue-state claims in comments vs the tracker. Needs `gh` auth, so its own recipe —
# a suite that fails without network is worse than no check.
issue-claims:
    sh tools/issue-claims.sh

# commands the docs name vs the binary's own table (#219/#252). Needs a built binary.
# `sh`, not `bash`: the script is POSIX and bash would let a bashism in unnoticed.
command-claims: build
    sh tools/command-claims.sh

# SKILL.md's payload literals against schemas/v3. Deliberately NOT dependent on `build`:
# it reads source and schemas only, never runs the binary, so it cannot touch a database.
skill-shapes:
    sh tools/skill-shapes.sh

# Every TEXT column decoded by `Sqlite.str` or `Sqlite.nullable_str` must be projected
# through CAST(... AS TEXT).
# Reads source only — no binary, no database.
blob-safety:
    sh tools/blob-safety.sh

# validate this machine's real payloads against the published contract
# (schemas/v3/*.json). e2e runs the same validator against fixtures; this is the
# "does MY data conform" pass, for after a schema or payload change. Depends on
# build so it can never report "conforms" because ./stride was missing, and it
# EXITS NON-ZERO on a violation — a checker that always succeeds is decoration.
schema-check: build
    #!/usr/bin/env sh
    # No `set -e`: each capture is allowed to fail so the `if` below can PRINT
    # what went wrong. Under set -e the shell aborted on the failing pipeline
    # and the diagnostic — already captured, thanks to 2>&1 — was never shown.
    rc=0
    # `commands` needs no database, so it is the one payload check that can
    # never be skipped — a real contract test even on a fresh install
    errs=$(STRIDE_FORMAT=json ./stride --help 2>&1 | jq '.data' 2>&1 | jq -r --slurpfile schema schemas/v3/commands.json -f tools/validate.jq 2>&1 || true)
    if [ -n "$errs" ]; then echo "commands:"; echo "$errs"; rc=1; else echo "commands: conforms"; fi
    # DERIVED from the command table, never written out — a hand-written copy drifted.
    # `activity` is excluded and handled below (its argument comes from the data).
    # The `mutates == false` filter is a SAFETY property: it is why this recipe may run
    # against a real database — invoking a writing command is impossible by construction.
    checked=0
    rejected=0
    forms=$(mktemp) || { echo "schema-check: mktemp failed"; exit 4; }
    trap 'rm -f "$forms"' EXIT
    # command<TAB>arg<TAB>example — the satisfying value lives beside the argument in
    # the table (#257), so no second answer can drift.
    ARGEX=$(STRIDE_FORMAT=json ./stride --help | jq -r '.data.commands[] | .name as $n | .args[]? | [$n, .name, .example] | @tsv')
    # FIELD 3, not the whole variable: rows still emit when every example is empty, so a
    # whole-variable guard cannot detect the state its own message names.
    case "$(printf %s "$ARGEX" | cut -f3 | tr -d '\n')" in
      "") echo "schema-check: the help payload declares argument rows but no examples — the TABLE is broken, not the payloads" >&2; exit 4 ;;
    esac
    STRIDE_FORMAT=json ./stride --help | jq -r '
        .data.commands[]
        | select(.mutates == false and .network == false and .interactive == false and .schema != "")
        | select(.name != "activity")
        | [.name, .schema, ([.args[] | select(.required) | .name] | join(" "))]
        | @tsv' > "$forms"
    # A derivation yielding nothing looks like a suite with nothing to say — count it.
    nforms=$(wc -l < "$forms" | tr -d ' ')
    # DERIVED expectation: asking the table twice and comparing names which side moved,
    # and catches jq truncating mid-stream (`> "$forms"` discards jq's status, no set -e).
    want=$(STRIDE_FORMAT=json ./stride --help | jq -r '[.data.commands[] | select(.mutates == false and .network == false and .interactive == false and .schema != "" and .name != "activity")] | length')
    # NUMERIC first: an empty operand makes `[ "" -lt 15 ]` take the ELSE branch —
    # failing OPEN.
    case "$nforms" in ''|*[!0-9]*) echo "schema-check: could not count the derived forms (got '$nforms')"; exit 4 ;; esac
    case "$want" in ''|*[!0-9]*) echo "schema-check: could not read the expected form count from the table (got '$want')"; exit 4 ;; esac
    # TWO guards, two directions. ABSOLUTE on the TABLE side: both counts come from the
    # SAME predicate, so a collapsed predicate moves both together and the equality below
    # passes 0 == 0.
    if [ "$want" -lt 15 ]; then
        echo "schema-check: the command table declares only $want read-only schema-bearing forms — the selector is broken, not the table"
        exit 4
    fi
    # RELATIVE on the DERIVATION side: catches jq truncating mid-stream, which the
    # floor alone shrugs at — deleting `.args` from one entry gives 16 against 18, and a
    # floor of 15 passes.
    if [ "$nforms" -ne "$want" ]; then
        echo "schema-check: derived $nforms forms but the command table declares $want — the derivation is broken, not the payloads"
        exit 4
    fi
    echo "schema-check: $nforms forms derived from the command table"
    # Globbing OFF for the loop only: $req/$inv are unquoted on purpose (form names must
    # word-split), so a placeholder like <file*> would otherwise expand against the repo
    # root. Restored after — the schema-lint sweep below needs its glob.
    set -f
    while IFS="$(printf '\t')" read -r c schema req; do
        inv="$c"
        skipform=""
        # Two opposite verdicts: `skipform` = this recipe cannot supply a value (its own
        # bug, FAILS); `nodata` = the database has nothing to name (a data fact, skips).
        nodata=""
        keyfault=""
        for a in $req; do
            v=""
            case "$a" in
                # Values come FROM THE TABLE (#257) — the same place the argument's
                # existence does, so three drifting copies became none, and a derived
                # argument the command rejects is structurally impossible (#253). An
                # EMPTY example = "not statically knowable" and FAILS rather than skips:
                # a new required argument must break loudly, not quietly drop its form.
                "<key>")
                    keyout=$(STRIDE_FORMAT=json ./stride config 2>&1)
                    keyerr=$(printf '%s' "$keyout" | jq -r '.error.code // empty' 2>/dev/null)
                    if [ -n "$keyerr" ]; then
                        keyfault="$keyerr"
                        v=""
                    else
                        # the listing marks rather than filters; only readable rows
                        # have a payload for `config get`
                        v=$(printf '%s' "$keyout" | jq -r '[.data.keys[] | select(.status == "settable" or .status == "managed")][0].key // empty')
                        [ -z "$v" ] && nodata="no config key this database has set is one config get returns a payload for"
                    fi ;;
                *)
                    v=$(printf %s "$ARGEX" | awk -F"\t" -v c="$c" -v a="$a" '$1 == c && $2 == a { print $3; exit }')
                    [ -z "$v" ] && skipform="no example declared for required argument $a — the command table must supply one"
                    ;;
            esac
            inv="$inv $v"
        done
        if [ -n "$skipform" ]; then echo "$c: FAILED ($skipform)"; rc=1; continue; fi
        # a fault reading the LISTING is a fault, not an absence — same wording the data-fault
        # arm below uses, so the two cannot be told apart by the reader either
        if [ -n "$keyfault" ]; then echo "$c: FAILED ($keyfault) — the database holds a value the engine cannot read; no payload was produced"; rc=1; rejected=$((rejected + 1)); continue; fi
        if [ -n "$nodata" ]; then echo "$c: skipped ($nodata)"; checked=$((checked + 1)); continue; fi
        out=$(STRIDE_FORMAT=json ./stride $inv </dev/null 2>&1 || true)
        # THREE outcomes: legitimately-nothing-to-say skips; a broken install fails
        # (envelopes made those skippable, which is why they are enumerated); a rejected
        # INVOCATION is this recipe's own bug — the third arm.
        code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)

        # ALLOWLIST, not denylist: under a denylist a wrong derived argument read as
        # "skipped (bad_metric)" — indistinguishable from a thin database, exit 0, nothing
        # validated. Only codes that genuinely mean "nothing to say" skip.
        # KNOWN GAP: the e2e mutation sweep grew a `stalled` check for `usage` (it asserts
        # every read-only form reached its handler); this recipe never inherited one.
        case "$code" in
            "") ;;
            # `not_set` moved to the REJECTED arm (#254): after the filler started coming
            # from `stride config`, seeing it means the binary contradicted itself within
            # one run. `irregular_anchor` is the definition of nothing-to-say — one
            # measurement found 372 of 389 real sessions irregular, and in the rejected
            # arm that made an intermittent false red, which teaches the reader to ignore
            # it. The three date-message codes (`no_workout_on_date`,
            # `no_intervals_on_date`, `unscorable`) are argument-dependent, so they are
            # safe here only because the derived date comes from the TABLE's own example
            # and resolves. `project` already takes a REQUIRED date (it is in the derived
            # set), so "no form takes one" is no longer the reason — an example that
            # stopped resolving would be.
            no_activities|no_data|no_power_data|no_cp_fit|missing_config|no_scorable_workouts|no_workout_on_date|no_detected_intervals|no_intervals_on_date|unscorable|irregular_anchor)
                echo "$inv: skipped ($code)"; checked=$((checked + 1)); continue ;;
            # DATA FAULTS — true statements about the DATABASE, not about the invocation,
            # so they must not get the rejection message below, which says the opposite and
            # would send the reader hunting for a bug in this recipe while their database is
            # corrupt. #183's arm plus the unreadable_* family (#206, #247).
            #
            # Not skipped, for a reason worth stating: `season`, `summary`, `plan` and
            # `compare` can ALL raise the #247 date codes, so allowing them to skip would
            # silently drop four of eighteen forms — 22% of coverage — on exactly the
            # databases where payload validation matters most. They are also
            # argument-independent, so failing on them can never be a false accusation
            # caused by this recipe's own derived filler.
            no_database|unreadable_database|corrupt_database|database_error|unreadable_config|unreadable_activity_date|unreadable_daily_load_day)
                echo "$inv: FAILED ($code) — the database holds a value the engine cannot read; no payload was produced"
                rc=1; rejected=$((rejected + 1)); continue ;;
            # the ENGINE broke — a third thing, and neither of the two above. The recipe
            # discards $out, so without echoing it the CLI's own "please open an issue"
            # text never reaches the reader.
            internal_error)
                echo "$inv: FAILED (internal_error) — stride hit an unhandled failure; this is a bug, not the data and not the invocation"
                printf '%s\n' "$out" | jq -r '.error.message' 2>/dev/null
                rc=1; rejected=$((rejected + 1)); continue ;;
            # REJECTED INVOCATIONS, enumerated. This is the recipe's own bug: it derived an
            # argument the command would not take.
            usage|unknown_command|bad_count|bad_metric|bad_period|bad_value|bad_watts|derived_key|unknown_key|not_set)
                echo "$inv: FAILED ($code) — the derived invocation was rejected, not the database"; rc=1; rejected=$((rejected + 1)); continue ;;
            # ...and the TRUE catch-all, which knows nothing and says so. `*)` used to do
            # two jobs — "genuinely a rejected invocation" and "nobody has classified this
            # code" — and only the first deserved that message. Conflating them is how
            # `irregular_anchor` spent this PR telling users their invocation was wrong
            # about a perfectly healthy database.
            *)
                echo "$inv: FAILED ($code) — schema-check has not classified this code; it does not know whether this is the data or the invocation"
                rc=1; rejected=$((rejected + 1)); continue ;;
        esac
        errs=$(printf '%s' "$out" | jq '.data' 2>&1 | jq -r --slurpfile schema schemas/v3/$schema -f tools/validate.jq 2>&1 || true)
        checked=$((checked + 1))
        if [ -n "$errs" ]; then echo "$inv:"; echo "$errs"; rc=1; else echo "$inv: conforms"; fi
    done < "$forms"
    # reconcile the counts — announcing "N derived" without counting executions lets the
    # output say N while validating zero.
    set +f
    # rejections counted separately, so this fires only on a genuine drop-out.
    if [ "$((checked + rejected))" -ne "$nforms" ]; then
        echo "schema-check: derived $nforms forms but reached only $((checked + rejected)) — the loop dropped some"
        rc=1
    fi
    # `activity` sampling. #249 hoists undateable rows to the TOP of `activities` and
    # `activity <id>` refuses exactly those, so the sampler WALKS rows rather than taking
    # .data[0] — otherwise the databases that most need activity.json validated only ever
    # exercise the refusal path. A DECLARED refusal is a pass (a correct refusal has no
    # payload to match; the envelope check covers the error shape); only an UNDECLARED
    # code is a finding. PER-COMMAND codes only, never the universal set:
    # `internal_error` is universal BECAUSE it is the catch-all, and accepting it here
    # once turned a real crash into a green run.
    acts=$(STRIDE_FORMAT=json ./stride activities 20 2>&1 || true)
    acode=$(printf '%s' "$acts" | jq -r '.error.code // empty' 2>/dev/null || true)
    ids=$(printf '%s' "$acts" | jq -r '.data[]?.id // empty' 2>/dev/null || true)
    # PARSEABILITY first, its own branch: both derivations suppress jq errors, so
    # unparseable output leaves both empty and would read as "no activities yet" at rc=0
    # over a full database — `// empty` cannot tell "no rows" from "could not parse".
    if ! printf '%s' "$acts" | jq -e . >/dev/null 2>&1; then
        echo "activity: cannot sample — \`activities\` did not return JSON"; rc=1
    elif [ -n "$acode" ]; then
        echo "activity: cannot sample — \`activities\` itself refused with $acode"; rc=1
    elif [ -z "$ids" ]; then
        # Can fail open (no-id rows land here at rc=0) — but every such shape violates
        # activities.json, which the forms loop validates in the same run, so the recipe
        # is red anyway. That redundancy is load-bearing: if `activities` ever joins the
        # `select(.name != "activity")` exclusion, this becomes a genuine silent pass.
        echo "activity: skipped (no activities yet)"
    else
        decl=$(STRIDE_FORMAT=json ./stride --json --help | jq -r '[.data.commands[] | select(.name == "activity") | .error_codes // []] | flatten | join(" ")' 2>/dev/null || true)
        # The universal set, read so it can be REFUSED rather than trusted. Safe only
        # while no form declares a universal code in its own error_codes — true today,
        # enforced nowhere; adding `internal_error` to a form list would silently return
        # this to passing on it.
        uni=$(STRIDE_FORMAT=json ./stride --json --help | jq -r '(.data.universal_error_codes // []) | join(" ")' 2>/dev/null || true)
        validated=0
        lastcode=""
        for id in $ids; do
            raw=$(STRIDE_FORMAT=json ./stride activity "$id" 2>&1 || true)
            code=$(printf '%s' "$raw" | jq -r '.error.code // empty' 2>/dev/null || true)
            if [ -z "$code" ]; then
                # ONE payload by design — the walk stops at the first row that yields one;
                # widening to structural variation means deciding "enough shapes".
                errs=$(printf '%s' "$raw" | jq '.data' 2>&1 | jq -r --slurpfile schema schemas/v3/activity.json -f tools/validate.jq 2>&1 || true)
                if [ -n "$errs" ]; then echo "activity $id:"; echo "$errs"; rc=1; else echo "activity $id: conforms"; fi
                validated=1; break
            fi
            lastcode="$code"
            case " $uni " in
                *" $code "*) echo "activity $id: refused with UNIVERSAL code $code, which is never a correct answer for a form"; rc=1; validated=1; break ;;
            esac
            case " $decl " in
                *" $code "*) echo "activity $id: refused with declared code $code — sampling the next row" ;;
                *) echo "activity $id: refused with UNDECLARED code $code"; rc=1; validated=1; break ;;
            esac
        done
        if [ "$validated" = "0" ]; then
            # provably not a false red: the date-sweeping forms already failed above by
            # the time this state is reachable.
            echo "activity: every sampled row refused (last: $lastcode), so activity.json was never validated against a payload"; rc=1
        fi
    fi
    # the envelope schema covers BOTH arms, so this one is never skipped
    errs=$(STRIDE_FORMAT=json ./stride summary 2>&1 | jq -r --slurpfile schema schemas/v3/envelope.json -f tools/validate.jq 2>&1 || true)
    if [ -n "$errs" ]; then echo "envelope:"; echo "$errs"; rc=1; else echo "envelope: conforms"; fi
    for f in schemas/v3/*.json; do
        lint=$(jq -r -f tools/schema-lint.jq "$f" 2>&1 || true)
        if [ -n "$lint" ]; then echo "$lint"; rc=1; fi
    done
    exit $rc

# sync integration: one binary as mock server (E2E_MODE=mock) + drivers against it.
# Binds loopback only, needs no credential — runs in CI. SINGLE-SHOT: the 5x retry
# that absorbed bug C's flake died with the bug; a new flake deserves investigation.
# Do NOT read a green run as "sync works": every mock string is short enough to live
# inline in a RocStr, so this suite is structurally blind to heap-string bugs — real
# payloads need a real sync. Depends on `build` or editing source silently tests the
# PREVIOUS ./stride binary.
e2e-sync: build
    #!/usr/bin/env bash
    set -uo pipefail
    {{roc}} build tests/e2e.roc --output=e2e --opt=dev || exit 1
    E2E_MODE=mock MOCK_PORT={{mock_port}} ./e2e &
    MOCK=$!
    # kill the mock on ANY exit, or an interrupted run leaves the port bound. EXIT
    # alone, deliberately: adding INT/TERM to a handler that does not itself exit
    # REPLACES terminate-on-signal, so Ctrl-C would run the cleanup and carry on.
    trap 'kill $MOCK 2>/dev/null' EXIT
    # single shot, no retry — see the recipe header
    E2E_MODE=sync STRIDE_API_BASE=http://127.0.0.1:{{mock_port}} ./e2e || exit 1
    # second mock: non-UTF-8 stream bodies for the skip path (a separate instance —
    # the sync scenario's 404-marker fixture must stay as it is)
    E2E_MODE=mock E2E_BAD_STREAM=1 MOCK_PORT={{bad_stream_port}} ./e2e &
    BADMOCK=$!
    trap 'kill $MOCK $BADMOCK 2>/dev/null' EXIT
    E2E_MODE=skips STRIDE_API_BASE=http://127.0.0.1:{{bad_stream_port}} ./e2e || exit 1
    # budget_reached needs no special mock — just a read budget of 1 against the main one
    E2E_MODE=stops STRIDE_API_BASE=http://127.0.0.1:{{mock_port}} ./e2e || exit 1
    # rate_limited needs a mock that 429s forever on one id
    E2E_MODE=mock E2E_RATE_LIMIT=1 MOCK_PORT={{rate_limit_port}} ./e2e &
    RLMOCK=$!
    trap 'kill $MOCK $BADMOCK $RLMOCK 2>/dev/null' EXIT
    E2E_MODE=stops E2E_EXPECT_RATE_LIMIT=1 STRIDE_API_BASE=http://127.0.0.1:{{rate_limit_port}} ./e2e || exit 1
    # the DAILY cap (#246), against the same mock as the budget arm. It needs no 429 —
    # the stop comes from stride's own count, which is the whole point: the cap is
    # respected by counting rather than by waiting to be refused.
    E2E_MODE=stops E2E_EXPECT_DAILY_CAP=1 STRIDE_API_BASE=http://127.0.0.1:{{mock_port}} ./e2e || exit 1
    # a persistent 401, to prove the token-refresh retry is bounded
    E2E_MODE=mock E2E_STREAM_401=1 E2E_ROTATING_TOKEN=1 MOCK_PORT={{auth401_port}} ./e2e &
    A401MOCK=$!
    trap 'kill $MOCK $BADMOCK $RLMOCK $A401MOCK 2>/dev/null' EXIT
    E2E_MODE=stops E2E_EXPECT_401=1 STRIDE_API_BASE=http://127.0.0.1:{{auth401_port}} ./e2e || exit 1
    # a 5xx mid-drain, with rows already committed
    E2E_MODE=mock E2E_HTTP500=1 MOCK_PORT={{http500_port}} ./e2e &
    P5MOCK=$!
    trap 'kill $MOCK $BADMOCK $RLMOCK $A401MOCK $P5MOCK 2>/dev/null' EXIT
    E2E_MODE=stops E2E_EXPECT_500=1 STRIDE_API_BASE=http://127.0.0.1:{{http500_port}} ./e2e || exit 1
    # EVERY driver line ends `|| exit 1`: no `-e` here, so a bare line's failure is
    # swallowed unless it happens to be last — appending a block once silently disarmed
    # the driver above it.
    # a 429 on the LISTING (#235)
    E2E_MODE=mock E2E_LIST_RATE_LIMIT=1 MOCK_PORT={{list429_port}} ./e2e &
    L429MOCK=$!
    trap 'kill $MOCK $BADMOCK $RLMOCK $A401MOCK $P5MOCK $L429MOCK 2>/dev/null' EXIT
    E2E_MODE=mock E2E_LIST_RATE_LIMIT=2 MOCK_PORT={{list429p_port}} ./e2e &
    L429P=$!
    trap 'kill $MOCK $BADMOCK $RLMOCK $A401MOCK $P5MOCK $L429MOCK $L429P 2>/dev/null' EXIT
    E2E_MODE=stops E2E_EXPECT_LIST_429=1 E2E_LIST_PARTIAL_BASE=http://127.0.0.1:{{list429p_port}} STRIDE_API_BASE=http://127.0.0.1:{{list429_port}} ./e2e || exit 1

# build + refresh the ~/.local/bin symlink
install: build
    ln -sf "$PWD/stride" "$HOME/.local/bin/stride"

# ── daily driving ────────────────────────────────────────────────────
# these depend on `build` so a fresh clone's `just up` works without a
# separate build step (the ./stride binary is gitignored)

# pull new activities + streams from Strava
sync: build
    ./stride sync

# recompute metrics + daily load, print the report
analyze: build
    ./stride analyze

# weekly planning payload (human tables in a terminal)
plan: build
    ./stride plan

# quick form check
summary: build
    ./stride summary

# sync + analyze + summary in one go
up: sync analyze summary

# ── e2e test suite (native Roc: tests/e2e.roc — sandboxed HOME, no network) ──
e2e:
    {{roc}} build tests/e2e.roc --output=e2e --opt=dev
    test -x ./stride || {  echo "e2e needs a ./stride binary — run \`just build\` first"; exit 1; }
    ./e2e
