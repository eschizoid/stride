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

# every `#NNN` in a source comment is a claim about an issue's state; this checks the
# mechanical half of it against the tracker. Needs `gh` auth, so it is its own recipe
# rather than part of `test` -- a suite that fails without network is worse than no check.
issue-claims:
    bash tools/issue-claims.sh

# every `stride <command>` a doc NAMES is a claim that the binary HAS it, and nothing
# checked it: #219 made the command table machine-readable so claims about the CLI could be
# checked rather than trusted, and the docs were the half with no oracle. Needs a built
# binary to ask, so it is its own recipe rather than part of `test` -- the same reason
# schema-check is, and the same reason issue-claims is (that one needs `gh`). `sh`, not
# `bash`, on purpose: the script is POSIX and running it under bash would let a bashism in
# unnoticed.
command-claims: build
    sh tools/command-claims.sh

# validate this machine's real payloads against the published contract
# (schemas/v2/*.json). e2e runs the same validator against fixtures; this is the
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
    errs=$(STRIDE_FORMAT=json ./stride --help 2>&1 | jq '.data' 2>&1 | jq -r --slurpfile schema schemas/v2/commands.json -f tools/validate.jq 2>&1 || true)
    if [ -n "$errs" ]; then echo "commands:"; echo "$errs"; rc=1; else echo "commands: conforms"; fi
    # DERIVED from the command table, not written out. #219 made that table the
    # authority — every form declares the schemas/v2 file its payload validates against —
    # and the hand-written list this replaces had already drifted away from it: it named
    # 15 forms where the table declares 19 read-only ones, silently never checking `pz`,
    # `pc` or `config get` against a real database. A second copy of a mapping does not
    # stay wrong in an interesting way; it just stops covering things.
    #
    # `activity` is excluded and handled separately below, because its argument is an id
    # that has to come from the data rather than from the table.
    #
    # The `mutates == false` filter is a SAFETY property, not a tidiness one, and it is
    # the reason this recipe is allowed near a real database: the table declares nine
    # schema-bearing commands that write — init, sync, analyze, import, rate, week add,
    # complete, skip, config set — and deriving from it makes invoking one impossible by
    # construction. The hand-written list simply happened not to name them.
    checked=0
    rejected=0
    forms=$(mktemp) || { echo "schema-check: mktemp failed"; exit 4; }
    trap 'rm -f "$forms"' EXIT
    STRIDE_FORMAT=json ./stride --help | jq -r '
        .data.commands[]
        | select(.mutates == false and .network == false and .interactive == false and .schema != "")
        | select(.name != "activity")
        | [.name, .schema, ([.args[] | select(.required) | .name] | join(" "))]
        | @tsv' > "$forms"
    # A derivation that yields nothing looks exactly like a suite with nothing to say, so
    # the count is asserted rather than assumed. The floor is the size of the list this
    # replaced; it is a floor and not an equality because the table is expected to grow.
    nforms=$(wc -l < "$forms" | tr -d ' ')
    # DERIVED expectation, not a literal. A hardcoded floor has slack — 18 forms against a
    # floor of 15 lets three vanish — and it is bump-bait besides: when it trips it cannot
    # say which side moved. Asking the table twice and comparing makes the failure name the
    # direction. It also catches jq truncating mid-stream, which is a live route: a command
    # entry missing `args` makes jq emit the earlier records and exit 5, and `> "$forms"`
    # discards that status under a recipe with no `set -e`.
    want=$(STRIDE_FORMAT=json ./stride --help | jq -r '[.data.commands[] | select(.mutates == false and .network == false and .interactive == false and .schema != "" and .name != "activity")] | length')
    # NUMERIC check first, and `-lt` is why: on this /bin/sh an empty `nforms` makes
    # `[ "" -lt 15 ]` print "integer expression expected" and take the ELSE branch — the
    # guard fails OPEN. Reachable if mktemp ever yields an unwritable path.
    case "$nforms" in ''|*[!0-9]*) echo "schema-check: could not count the derived forms (got '$nforms')"; exit 4 ;; esac
    case "$want" in ''|*[!0-9]*) echo "schema-check: could not read the expected form count from the table (got '$want')"; exit 4 ;; esac
    # TWO guards, two directions, because one of them alone is blind in the other.
    #
    # ABSOLUTE, on the TABLE side. `nforms` and `want` come from the SAME predicate over
    # the same table, so a predicate that collapses moves both together and the equality
    # below reports 0 == 0 and passes — measured, exit 0, nothing validated. Replacing the
    # literal floor with the equality alone was a regression that lost exactly the property
    # the floor was added for. It sits on the TABLE rather than on the derivation now, so
    # its message can name the cause, and on a quantity that only grows.
    if [ "$want" -lt 15 ]; then
        echo "schema-check: the command table declares only $want read-only schema-bearing forms — the selector is broken, not the table"
        exit 4
    fi
    # RELATIVE, on the DERIVATION side. Catches jq truncating mid-stream, which the floor
    # alone would shrug at: deleting `.args` from one entry gives 16 against 18, and a
    # floor of 15 passes.
    if [ "$nforms" -ne "$want" ]; then
        echo "schema-check: derived $nforms forms but the command table declares $want — the derivation is broken, not the payloads"
        exit 4
    fi
    echo "schema-check: $nforms forms derived from the command table"
    # Globbing OFF for the loop only: `$req` and `$inv` are unquoted on purpose (a form
    # name like `config get` has to split into two argv entries), so a future `<file*>`
    # placeholder would expand against the repo root. Restored after the loop, because the
    # schema-lint sweep below needs `schemas/v2/*.json` to glob — turning it off globally
    # broke that, which is how this comment came to exist.
    set -f
    while IFS="$(printf '\t')" read -r c schema req; do
        inv="$c"
        skipform=""
        # TWO reasons a form can produce no argument, and they are opposite verdicts.
        # `skipform` is "this recipe does not know what to pass" — its own bug, so it FAILS.
        # `nodata` is "the database has nothing for this argument to name" — a true fact
        # about the data, so it skips, in the same class as `no_activities`. Separated
        # because folding the second into the first turns a correct fresh install red, and
        # folding the first into the second is how a form silently stops being checked.
        nodata=""
        keyfault=""
        for a in $req; do
            v=""
            case "$a" in
                # an alternation names its own valid values; take the first. This is why
                # `top` needs no entry below — the table already says what it accepts.
                *"|"*) v=$(printf '%s' "$a" | tr -d '<>' | cut -d'|' -f1) ;;
                # everything else needs a value nothing in the table supplies. FAIL rather
                # than skip on an unknown one: a new required argument must break this
                # loudly, not quietly drop its form from the check.
                "<watts>") v=300 ;;
                # ASKED FOR, not hardcoded (#254). This was the literal `timezone`, and the
                # skip on `not_set` below covered for it: on any database where that one key
                # happened to be unset — a real state, measured on a copy of the live db with
                # 736 activities and twelve other config rows — `config get` dropped out and
                # the recipe still exited 0, having never validated config.json against real
                # data. That is the silent-under-check this whole arm exists to prevent, and
                # `unknown_key` does not reach it: the filler was a REAL key, just an empty one.
                #
                # Taking the first key the binary says holds a value makes the filler
                # unfalsifiable-by-staleness — retire `timezone` and this picks something else
                # rather than skipping — and turns the empty case into a fact the recipe
                # CHECKED (no config rows at all) rather than an error code that meant two
                # things. `not_set` is out of the allowlist entirely as a result.
                # CAPTURE ONCE, then classify — do not pipe an error envelope into `// empty`.
                # A first cut did, and `2>/dev/null` plus `// empty` collapsed FOUR different
                # situations into one empty string: no rows, rows that are all `derived` or
                # `unrecognised`, no database, and a corrupt one. The last two then routed
                # around the DATA FAULTS arm below — the arm that exists to say "the database
                # holds a value the engine cannot read" — and got reported as "this database
                # has no config set", which is a statement, and false.
                "<key>")
                    keyout=$(STRIDE_FORMAT=json ./stride config 2>&1)
                    keyerr=$(printf '%s' "$keyout" | jq -r '.error.code // empty' 2>/dev/null)
                    if [ -n "$keyerr" ]; then
                        keyfault="$keyerr"
                        v=""
                    else
                        # `status == "read"` — the listing marks rather than filters, and only
                        # the read rows have a payload for `config get` to return.
                        v=$(printf '%s' "$keyout" | jq -r '[.data.keys[] | select(.status == "settable" or .status == "managed")][0].key // empty')
                        [ -z "$v" ] && nodata="no config key this database has set is one config get returns a payload for"
                    fi ;;
                *) skipform="no value known for required argument $a" ;;
            esac
            inv="$inv $v"
        done
        if [ -n "$skipform" ]; then echo "$c: FAILED ($skipform)"; rc=1; continue; fi
        # a fault reading the LISTING is a fault, not an absence — same wording the data-fault
        # arm below uses, so the two cannot be told apart by the reader either
        if [ -n "$keyfault" ]; then echo "$c: FAILED ($keyfault) — the database holds a value the engine cannot read; no payload was produced"; rc=1; rejected=$((rejected + 1)); continue; fi
        if [ -n "$nodata" ]; then echo "$c: skipped ($nodata)"; checked=$((checked + 1)); continue; fi
        out=$(STRIDE_FORMAT=json ./stride $inv </dev/null 2>&1 || true)
        # THREE outcomes, not two. A command that legitimately has nothing to say (fresh
        # install, no activities) returns an error ENVELOPE and is skipped. A BROKEN
        # install is not "legitimately nothing to say" — no_database and friends must fail
        # (#183 gave them envelopes, which is exactly what made them skippable). And a
        # rejected INVOCATION is this recipe's own bug, which is the third arm.
        code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)

        # ALLOWLIST, not denylist. The old hand-written list's arguments were literals a
        # human had checked; this PR derives them from placeholder TEXT, which
        # Command.roc's own comment names as the one field the table does not enforce. So
        # a wrong derived argument is now possible, and under a denylist it came back as
        # `top metric: skipped (bad_metric)` — indistinguishable from a thin database, with
        # the recipe exiting 0 having validated nothing. Review reproduced exactly that.
        #
        # `usage`, `bad_*` and `unknown_command` mean the INVOCATION was rejected, which is
        # this recipe's own bug, not a fact about the data. Only the codes that genuinely
        # mean "nothing to say on this database" skip. The e2e mutation sweep learned the
        # same lesson and grew a `stalled` check for `usage`; this recipe did not inherit
        # it, and that is the gap.
        case "$code" in
            "") ;;
            # `not_set` WAS here, under protest, and #254 removed it — the acceptance
            # criterion the issue named, not a follow-up. It is in the REJECTED arm below
            # now, because after #254 there is only one way for this recipe to see it: it
            # asked for a key the binary said holds a value and got nothing back, which is
            # a contradiction inside one run, not a fact about the data.
            #
            # The protest was that `not_set` could not tell a wrong filler from a genuinely
            # unset key. Two changes retire it. `unknown_key` splits off the unrecognised
            # case, so retiring `timezone` is a red naming the filler rather than a silent
            # skip. And the filler is no longer the literal `timezone` at all — it comes
            # from `stride config`, so the "genuinely unset" case cannot arise for a key
            # this loop chose. The empty-database case that kept the entry alive is now
            # `nodata` above: a state the recipe CHECKED, reported in its own words, rather
            # than an error code standing in for two different situations.
            #
            # `irregular_anchor` is here because it is the definition of nothing to say —
            # its own message ends "nothing to compare it against as a repeated workout".
            # It was in the rejected arm and that was a LIVE false red, not a latent one:
            # ReportSessions raises it from the unguarded Ok(a) branch, so a bare `reps`
            # hits it whenever the most recent session with work segments has blocks
            # outside 1.6x. Review measured 372 of 389 sessions irregular on the real
            # database — 95.6% — with only the three most recent rides uniform, which is
            # the sole reason this recipe was green. It would have exited 1 on essentially
            # any day between 2026-05-21 and 2026-08-16, and will again after the next
            # unstructured ride. Intermittent is worse than constant here: a red that comes
            # and goes teaches the reader to ignore it.
            #
            # THREE conditional siblings, all here and all for one reason:
            # `no_workout_on_date`, `no_intervals_on_date` and `unscorable` have
            # argument-dependent messages, so each would belong in the rejected arm the day
            # any form takes a REQUIRED date. Both date-taking forms (`reps`, `progress`)
            # take it optionally today, so no wrong date can be derived. Named together
            # because two of them sat in the other arm by accident, and the next person to
            # notice would have resolved the inconsistency in whichever direction they saw
            # first.
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
        errs=$(printf '%s' "$out" | jq '.data' 2>&1 | jq -r --slurpfile schema schemas/v2/$schema -f tools/validate.jq 2>&1 || true)
        checked=$((checked + 1))
        if [ -n "$errs" ]; then echo "$inv:"; echo "$errs"; rc=1; else echo "$inv: conforms"; fi
    done < "$forms"
    # ...and reconcile the two counts. Announcing "18 forms derived" before the loop and
    # never counting executions is how the output can honestly say 18 while validating
    # zero, which is the shape the HIGH above produced.
    set +f
    # rejections counted separately, so this fires only on a genuine drop-out. Lumping
    # them in made one rejected form print two lines, the second of them wrong about why.
    if [ "$((checked + rejected))" -ne "$nforms" ]; then
        echo "schema-check: derived $nforms forms but reached only $((checked + rejected)) — the loop dropped some"
        rc=1
    fi
    # The FIRST row is deliberately the worst one. #249 hoists undateable activities to the
    # top of `activities` so a listing cannot hide the row that needs repair — and `activity
    # <id>` REFUSES on exactly that row, because the screen computes a 90-day window from
    # the date. So on any database with one bad date, `.data[0].id` names a row whose detail
    # view is an error envelope, `jq '.data'` is null, and this printed
    # "activity N: expected object, got null" — a schema violation reported against a
    # database whose only problem is one unreadable date, with the message pointing at the
    # wrong thing. That is the wrong-cause diagnosis #249 exists to remove, one level up in
    # the tooling, and the two halves of that PR caused it between them.
    #
    # A DECLARED refusal is a pass here. schema-check's question is "does the payload match
    # its schema", and a form that correctly refuses has no payload to match — the envelope
    # check below covers the error shape, and the e2e command-schema loop covers which codes
    # a form may raise. Only an UNDECLARED code is a finding, which is why the code is
    # compared against the table rather than merely being non-empty.
    # PER-COMMAND codes only, never the universal set, and that distinction is the whole
    # correctness of this block. `universal_error_codes` contains `internal_error` — it is
    # declared universally precisely BECAUSE it is the catch-all, meaning "can occur
    # anywhere", not "is a correct answer here". Testing membership against the union made
    # this print "refused with declared code internal_error" and exit 0 on a database where
    # `stride activity <id>` answered "unhandled failure: UnexpectedType(Null) — please open
    # an issue". Before that change the same state was rc=1. A contract checker reporting
    # green on the exact failure shape #243 and #249 exist to eliminate, in the branch that
    # closes them. Every other universal member is the same class: something went wrong
    # OUTSIDE the form's own logic. The per-command list is the one that means "this form may
    # legitimately answer this instead of a payload".
    #
    # WALKS the first rows rather than taking only the first, because #249 hoists undateable
    # activities to the top of `activities`. Taking `.data[0]` alone means that on precisely
    # the databases where you most want to know `activity.json` still conforms, the only path
    # ever exercised is the refusal one. Walking keeps both properties without re-implementing
    # the date rule in a third language, which is the trap `guard_activity_dates!` exists to
    # avoid.
    acts=$(STRIDE_FORMAT=json ./stride activities 20 2>&1 || true)
    acode=$(printf '%s' "$acts" | jq -r '.error.code // empty' 2>/dev/null || true)
    ids=$(printf '%s' "$acts" | jq -r '.data[]?.id // empty' 2>/dev/null || true)
    # PARSEABILITY first, and it is a third branch rather than part of either. Both
    # derivations above read the same string through jq with errors suppressed, so
    # unparseable output leaves BOTH empty — `acode` empty skips the envelope branch, and
    # `-z "$ids"` then reports "skipped (no activities yet)" at rc=0 about a database holding
    # 736 activities. That is the same false statement fixed one commit ago, reached through
    # a different door: the envelope branch catches a WELL-FORMED error and nothing caught
    # malformed output. `// empty` cannot tell "jq parsed it and found no rows" from "jq
    # could not parse it".
    #
    # Narrow but live. The recipe sets STRIDE_FORMAT=json itself, so it needs the JSON path
    # to break for THIS command — a format regression scoped to `activities`, or `activities`
    # gaining narration, since `2>&1` merges stderr into the parse and `analyze` already
    # writes there. And it is the checker going quiet about a regression in the exact thing
    # it checks: a JSON-mode break is a contract break, and the contract checker would have
    # said "skipped" and exited 0. The `commands:` check above catches a GLOBAL JSON
    # regression; one scoped to a single command slips past it.
    if ! printf '%s' "$acts" | jq -e . >/dev/null 2>&1; then
        echo "activity: cannot sample — \`activities\` did not return JSON"; rc=1
    elif [ -n "$acode" ]; then
        # NOT "skipped (no activities yet)". `// empty` cannot tell "no rows" from "the
        # listing returned an envelope", and the old branch said the database was empty
        # while it held 737 activities — a diagnostic making a false statement, which is the
        # defect one level up that the rest of this block was fixed for.
        echo "activity: cannot sample — \`activities\` itself refused with $acode"; rc=1
    elif [ -z "$ids" ]; then
        # THIS BRANCH CAN FAIL OPEN, and what stops it is somewhere else in this recipe.
        # `-z "$ids"` cannot distinguish "no rows" from "rows that parsed but carried no
        # usable id" — measured on a real row with its id nulled, deleted, or made a string,
        # all of which land here at rc=0. Every one of those shapes VIOLATES
        # activities.json, and `activities` is one of the derived forms, so the loop above
        # validates it in the same run and the recipe is red anyway. The block's fail-open is
        # never the sole outcome.
        #
        # Which makes the redundancy load-bearing and worth naming: `activity` is excluded
        # from the derived list by an explicit `select(.name != "activity")`, and that line is
        # exactly where the next person needing an exclusion will look. If `activities` ever
        # joins it, this becomes a genuine silent pass and nothing will say so.
        #
        # Not made fatal on `activity_not_found` for an id `activities` just returned, though
        # the two commands disagreeing could not be legitimate: a row deleted by a concurrent
        # sync between the two calls is an unlikely but real race, and trading a hypothetical
        # bug-detection for a real flake is the wrong direction for a local tool.
        echo "activity: skipped (no activities yet)"
    else
        decl=$(STRIDE_FORMAT=json ./stride --json --help | jq -r '[.data.commands[] | select(.name == "activity") | .error_codes // []] | flatten | join(" ")' 2>/dev/null || true)
        # The universal set, read so it can be REFUSED rather than trusted. Excluding it is
        # currently a property of the TABLE — the block is safe only because no form declares
        # a universal code in its own error_codes, which is true today and enforced nowhere.
        # The day someone adds `internal_error` to a form's list, plausibly to make some
        # other check go green, this silently returns to passing on it, and the comment
        # explaining why that must never happen is three files from the change that does it.
        # Held here instead, where it is stated.
        uni=$(STRIDE_FORMAT=json ./stride --json --help | jq -r '(.data.universal_error_codes // []) | join(" ")' 2>/dev/null || true)
        validated=0
        lastcode=""
        for id in $ids; do
            raw=$(STRIDE_FORMAT=json ./stride activity "$id" 2>&1 || true)
            code=$(printf '%s' "$raw" | jq -r '.error.code // empty' 2>/dev/null || true)
            if [ -z "$code" ]; then
                # ONE payload, by design rather than by accident. The walk stops at the first
                # row that yields one, so structural variation — a row with no streams, no
                # segments, no metrics against one with all three — is never sampled. That
                # was equally true before the walk existed; widening it means deciding what
                # "enough shapes" is, which is its own conversation.
                errs=$(printf '%s' "$raw" | jq '.data' 2>&1 | jq -r --slurpfile schema schemas/v2/activity.json -f tools/validate.jq 2>&1 || true)
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
            # rc=1, and provably not a false red: every form that sweeps activity dates has
            # already FAILED in the forms loop above by the time this state is reachable, so
            # this line can only ever agree with a red the recipe already is. Names the last
            # code so the reader does not have to re-derive why.
            echo "activity: every sampled row refused (last: $lastcode), so activity.json was never validated against a payload"; rc=1
        fi
    fi
    # the envelope schema covers BOTH arms, so this one is never skipped
    errs=$(STRIDE_FORMAT=json ./stride summary 2>&1 | jq -r --slurpfile schema schemas/v2/envelope.json -f tools/validate.jq 2>&1 || true)
    if [ -n "$errs" ]; then echo "envelope:"; echo "$errs"; rc=1; else echo "envelope: conforms"; fi
    for f in schemas/v2/*.json; do
        lint=$(jq -r -f tools/schema-lint.jq "$f" 2>&1 || true)
        if [ -n "$lint" ]; then echo "$lint"; rc=1; fi
    done
    exit $rc

# sync integration: ONE binary in two roles — a mock Strava server (E2E_MODE=mock)
# and a sync driver (E2E_MODE=sync) that runs real sync + token-refresh against it.
# Binds a port, so it's separate from `just test`. Runs against the ./stride binary.
# Runs in CI as well as locally: it binds only loopback and needs no credential. It exercises stride's sync path,
# which was ~50% flaky until bug C (#105) was root-caused to a basic-cli host double-free
# and fixed in 0.22.0. It runs SINGLE-SHOT now: the 5x retry that used to absorb that
# flake was deleted with the bug, and a new flake here deserves an investigation rather
# than another crutch.
#
# Do not read a green run here as "sync works". Every string in the mock fixture is short
# enough to live inline in a RocStr, and the corruption only bites heap-allocated decoded
# strings — so this suite is structurally incapable of reproducing the real-data failure
# that shipped once already. Real payloads need a real sync to verify.
# depends on `build` for the same reason `just test` does: this recipe rebuilt ./e2e
# but NOT ./stride, so editing source and re-running silently tested the PREVIOUS
# binary. That cost a reviewer a wrong diagnosis — a failure reported from code that
# was no longer on disk. AGENTS.md already names the stale-binary hazard for a FAILED
# build; a successful build of since-reverted source is the same trap.
e2e-sync: build
    #!/usr/bin/env bash
    set -uo pipefail
    {{roc}} build tests/e2e.roc --output=e2e --opt=dev || exit 1
    E2E_MODE=mock MOCK_PORT={{mock_port}} ./e2e &
    MOCK=$!
    # kill the mock on ANY exit, including Ctrl-C — the old single-line form only killed
    # it on the success path, so an interrupted run left the port bound and every later
    # run failed to bind until someone found the stray process.
    #
    # EXIT alone, deliberately. Adding INT/TERM to a handler that does not itself exit
    # REPLACES the default terminate-on-signal, so Ctrl-C ran the cleanup and then carried
    # on instead of stopping. Measured back when the 5x retry loop below still existed:
    # with `EXIT INT TERM` a SIGTERM'd run completed all five retries and exited 0; with
    # `EXIT` alone it stopped at once (143) and still ran the cleanup. The loop is gone,
    # so that exact measurement is no longer reproducible here, but the signal-handling
    # rule it established is why this trap names only EXIT.
    trap 'kill $MOCK 2>/dev/null' EXIT
    # single shot, no retry. The 5x retry loop that used to live here absorbed bug C's
    # ~50% flake; with the bug fixed (basic-cli 0.22.0, #105) the flake is gone —
    # measured 10/10 clean unretried on 2026-08-14. If this starts failing again it
    # should fail LOUDLY, not be absorbed: a new flake deserves a new investigation.
    E2E_MODE=sync STRIDE_API_BASE=http://127.0.0.1:{{mock_port}} ./e2e || exit 1
    # a SECOND mock, serving stream bodies that are not UTF-8, for the skip path.
    # Separate instance rather than a flag on the first: the 404-marker fixture in the
    # sync scenario has to stay exactly as it is, and one process cannot be both.
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
    # EVERY driver line ends `|| exit 1`. This recipe runs under `set -uo pipefail` with
    # no `-e`, so a bare line's failure is swallowed unless it happens to be the last
    # command — which is how appending this block silently disarmed the 5xx driver above.
    #
    # a 429 on the LISTING, which nothing exercised before #235
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
