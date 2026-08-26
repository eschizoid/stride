## A fully-parsed CLI invocation. Count arguments are validated to real numbers
## HERE (the pure layer), so the effectful `main!` never re-parses argv — it just
## dispatches on the tag. Keeping parsing pure makes every arg form unit-testable
## without a database or a process.
import Metrics

Command := [
	Init,
	Auth,
	## `--all` forces a full re-list: the watermark is ignored so every activity is
	## re-listed and old deletions propagate. Mostly a dev-mode start-from-scratch;
	## normal use never needs it, because a plain `sync` converges on its own (#232).
	Sync(Bool),
	Analyze,
	Summary,
	Stats,
	Plan,
	Doctor,
	Zones,
	Version,
	Compare(Str),
	Activities(U64, Str),
	Top(Str, U64, Str),
	Import(Str),
	Rate(Str, Str),
	Progress(Str, [Asc, Desc]),
	## time to exhaustion at a power the CALLER names (#187). ADR 0010: the
	## caller states the input and stride does the arithmetic — choosing a
	## target power for the athlete would be prescription.
	Tte(Str),
	## rep-level comparison: the anchor session's detected blocks against the
	## same-shaped blocks of earlier comparable sessions (#149)
	Reps(Str),
	Activity(Str),
	Load(U64),
	PowerCurve(U64, Str),
	Season,
	WeekView,
	WeekViewAll,
	WeekAdd(Str, Str, Str, Str),
	Complete(Str, Str),
	CompleteRest(Str),
	Skip(Str, Str),
	SkipWith(Str, Str, Str),
	ConfigGet(Str),
	ConfigSet(Str, Str),
	ConfigList,
].{

	## Why parsing failed, mapped by the caller to output:
	##   ShowHelp     -> the full help text (bare invocation — not an error)
	##   UnknownCmd   -> a command name stride does not have (#163: an invocation
	##                   error, so it exits non-zero and, in JSON mode, emits an
	##                   envelope rather than help text a machine cannot parse)
	##   Usage(Str)   -> a targeted one-line hint (right command, wrong arity)
	##   BadCount(Str) -> a count argument that wasn't a number
	ParseErr : [ShowHelp, UnknownCmd(Str), Usage(Str), BadCount(Str)]

	## Output-format flags (#162), pulled out of argv before command parsing:
	## `--json` / `--human` in ANY position, last one wins, and `--` ends flag
	## parsing POSIX-style so an argument whose literal value is `--json` (a skip
	## reason, a session detail) survives as `stride skip 5 -- --json`. Without
	## the terminator the strip would silently eat the value and hand the command
	## one argument too few. Lives HERE, with the rest of argv parsing, so it is
	## unit-tested by the same suite as `parse`.
	FormatMode : [ForceJson, ForceHuman, Auto]

	split_format_args : List(Str) -> { mode : FormatMode, rest : List(Str) }
	split_format_args = |args| {
		walked = List.fold(args, { mode: Auto, rest: [], literal: False }, |acc, a|
			if acc.literal {
				{ ..acc, rest: List.append(acc.rest, a) }
			} else if a == "--" {
				{ ..acc, literal: True }
			} else if a == "--json" {
				{ ..acc, mode: ForceJson }
			} else if a == "--human" {
				{ ..acc, mode: ForceHuman }
			} else {
				{ ..acc, rest: List.append(acc.rest, a) }
			})
		{ mode: walked.mode, rest: walked.rest }
	}

	## argv (including the program name at index 0) -> a typed command. Mirrors the
	## historical `main!` dispatch exactly; behavior-preserving by construction.
	parse : List(Str) -> Try(Command, ParseErr)
	parse = |args|
		match args {
			[_, "init"] => Ok(Init)
			[_, "auth"] => Ok(Auth)
			[_, "sync"] => Ok(Sync(False))
			[_, "sync", "--all"] => Ok(Sync(True))
			## Retired in #232, with a pointer rather than a bare unknown_command. Every
			## README, skill and shell history said `stride backfill` until that commit,
			## and the plan->week rename beside it sets the precedent for redirecting.
			[_, "backfill", ..] => Err(Usage("sync — `backfill` is retired; `stride sync` drains all missing streams, and `stride sync --all` re-lists from scratch"))
			[_, "analyze"] => Ok(Analyze)
			[_, "summary"] => Ok(Summary)
			[_, "stats"] => Ok(Stats)
			[_, "plan"] => Ok(Plan)
			[_, "compare"] => Ok(Compare("week"))
			[_, "compare", period] => Ok(Compare(period))
			[_, "activities"] => Ok(Activities(30, ""))
			[_, "activities", n] => count(n, |c| Activities(c, ""))
			[_, "activities", n, sport] => count(n, |c| Activities(c, sport))
			[_, "top", metric] => Ok(Top(metric, 10, ""))
			[_, "top", metric, n] => count(n, |c| Top(metric, c, ""))
			[_, "top", metric, n, sport] => count(n, |c| Top(metric, c, sport))
			[_, "import", src] => Ok(Import(src))
			[_, "rate", target, rpe_str] => Ok(Rate(target, rpe_str))
			[_, "doctor"] => Ok(Doctor)
			[_, "tte", watts] => Ok(Tte(watts))
			[_, "tte", ..] => Err(Usage("tte <watts> — time to exhaustion at a power you name"))
			[_, "reps"] => Ok(Reps(""))
			[_, "reps", date] =>
				if Metrics.is_canonical_date(date) {
					Ok(Reps(date))
				} else {
					# without this, `reps asc` answered "no detected interval
					# structure on asc" -- a data fact about a date that does
					# not exist
					Err(Usage("reps [YYYY-MM-DD] — '${date}' is not a date"))
				}
			[_, "zones"] => Ok(Zones)
			[_, "pz"] => Ok(Zones)
			# a bare asc/desc is a sort on the latest anchor, not a date named "desc"
			[_, "progress"] => Ok(Progress("", Asc))
			[_, "progress", "asc"] => Ok(Progress("", Asc))
			[_, "progress", "desc"] => Ok(Progress("", Desc))
			# a sort word in the DATE position stays a sort word. Without these, `progress
			# desc asc` fell through to the name+sort arms below and anchored on a workout
			# named "desc" — the opposite of what the comment above promises.
			[_, "progress", "asc", ..] => Err(Usage("progress [date] [asc|desc]"))
			[_, "progress", "desc", ..] => Err(Usage("progress [date] [asc|desc]"))
			# bound as `date`, not `name`: the handler queries it as a date and answers
			# `no_workout_on_date`. Called `name` once, and the command table copied that
			# into its public argument shape, where an agent read it.
			[_, "progress", date] => Ok(Progress(date, Asc))
			[_, "progress", date, "asc"] => Ok(Progress(date, Asc))
			[_, "progress", date, "desc"] => Ok(Progress(date, Desc))
			[_, "progress", ..] => Err(Usage("progress [date] [asc|desc]"))
			[_, "activity", id_str] => Ok(Activity(id_str))
			[_, "load"] => Ok(Load(90))
			[_, "load", n] => count(n, |c| Load(c))
			[_, "season"] => Ok(Season)
			[_, "power-curve"] => Ok(PowerCurve(90, ""))
			[_, "pc"] => Ok(PowerCurve(90, ""))
			[_, "power-curve", n] => count(n, |c| PowerCurve(c, ""))
			[_, "pc", n] => count(n, |c| PowerCurve(c, ""))
			[_, "power-curve", n, sport] => count(n, |c| PowerCurve(c, sport))
			[_, "pc", n, sport] => count(n, |c| PowerCurve(c, sport))
			[_, "week"] => Ok(WeekView)
			[_, "week", "all"] => Ok(WeekViewAll)
			[_, "week", "add", date, session_type, detail, rationale] => Ok(WeekAdd(date, session_type, detail, rationale))
			[_, "complete", session_id, activity_id] => Ok(Complete(session_id, activity_id))
			[_, "complete", session_id] => Ok(CompleteRest(session_id))
			[_, "skip", session_id, reason, activity_id] => Ok(SkipWith(session_id, reason, activity_id))
			[_, "skip", session_id, reason] => Ok(Skip(session_id, reason))
			[_, "config", "get", key] => Ok(ConfigGet(key))
			# bare `config` LISTS the keys that hold a value (secrets redacted). It was a
			# Usage error, which made "which config do I actually have set?" a question the
			# CLI could not answer — `doctor` reports counts, not names. #254 needs it for a
			# second reason: `just schema-check` filled `config get <key>` with a hardcoded
			# `timezone` and skipped on `not_set`, so on any database where that one key was
			# unset the form dropped out silently at exit 0. The filler comes from here now,
			# so it cannot be stale, and the skip is decided by an EMPTY LIST — a fact the
			# recipe checks — instead of by an error code that could mean two things.
			[_, "config"] => Ok(ConfigList)
			[_, "config", "set", key, val] => Ok(ConfigSet(key, val))
			[_, "--version"] => Ok(Version)
			[_, "week", ..] => Err(Usage("week add <YYYY-MM-DD> <type> \"<detail>\" \"<rationale>\" — or bare `week` for this week's sessions, `week all` for the whole log"))
			# `plan` and `week` traded names, so muscle memory sends the old forms here.
			# Point each one at its actual replacement rather than a generic arity moan —
			# `plan all` meant the session log, which is now `week all`, not `week add`.
			[_, "plan", "all", ..] => Err(Usage("week all — `plan` is now the planning bundle; the session log moved to `week`"))
			[_, "plan", "add", ..] => Err(Usage("week add <YYYY-MM-DD> <type> \"<detail>\" \"<rationale>\" — `plan add` moved to `week add`"))
			[_, "plan", ..] => Err(Usage("plan takes no arguments — it bundles summary + open sessions + recent activities"))
			[_, "complete", ..] => Err(Usage("complete <session_id> [activity_id]"))
			[_, "skip", ..] => Err(Usage("skip <session_id> \"<reason>\" [activity_id|none]"))
			[_, "activity", ..] => Err(Usage("activity <activity_id>"))
			[_, "config", ..] => Err(Usage("config get <key>  |  config set <key> <value>"))
			# asking for help — bare, or by any of the conventional spellings —
			# is not a failure and must not become one (#163 broke `--help` by
			# deleting the old catch-all that had silently served it)
			[_] => Err(ShowHelp)
			[] => Err(ShowHelp)
			[_, "--help"] => Err(ShowHelp)
			[_, "-h"] => Err(ShowHelp)
			[_, "help"] => Err(ShowHelp)
			# a leading token stride DOES have, that reached here, is a real
			# command invoked with the wrong arguments — saying "no such command
			# sync" would be false. Only a name stride does not have is unknown.
			[_, name, ..] =>
				if List.contains(command_names, name) {
					Err(Usage("${name} — wrong arguments for this command; run `stride` for every command's form"))
				} else {
					Err(UnknownCmd(name))
				}
		}

	## Every command name the parser answers to, so a wrong-arity invocation of a
	## REAL command reports a usage error instead of claiming the command does not
	## exist. Kept beside `parse` because it is the same fact; every name here has an
	## expect below that fails if it stops parsing to its own form.
	##
	## The VERBS from `specs`, deduped — `week` and `week add` are two callable forms but
	## one token to the unknown-vs-wrong-arguments branch above. Derived rather than kept
	## as a second list, so the two cannot disagree about which names exist.
	command_names : List(Str)
	command_names =
		List.fold(specs, [], |acc, s| {
			v = verb_of(s.name)
			if List.contains(acc, v) acc else List.append(acc, v)
		})

	## One argument. Positional, with one exception: `sync`'s `--all` is a literal flag
	## accepted in an argument position, so it lives here rather than only in `flags`. `name` is the placeholder as it appears in usage text;
	## a value without angle brackets must be passed verbatim.
	##
	## `example` is a value that SATISFIES this argument, and it exists so that the value
	## comes from the same place the argument's existence does (#257). Three checkers kept
	## their own answer to "what fills this placeholder" — the e2e mutation sweep's jq, the
	## e2e schema sweep, and `just schema-check`'s `case` block — and they had already
	## drifted: the sweep proved `config get 1` and `tte 1` do not write while schema-check
	## executed `tte 300`, and for `config get` a key chosen at RUNTIME from `stride config`'s listing — which is not a fixed value and cannot be cited as one. The safety proof and the executed
	## invocation were not the same call.
	##
	## It makes two defects structurally impossible rather than merely loud. #253's HIGH was
	## a derived argument the command REJECTED, which read as a benign "skipped" at exit 0
	## until the allowlist was inverted; with the value coming from the table there is
	## nothing to reject. And #254's schema-check consequence — a hardcoded `<key>` filler
	## whose staleness could only be caught by a rename — disappears with the filler.
	##
	## BOUNDARY, written into the type rather than promised past: this covers arguments with
	## a STATIC valid value. `<activity_id>` has to come from the data, so `example` is empty
	## there — a consumer must treat empty as "I cannot invoke this without looking at the
	## database", not as "".
	##
	## `<export.zip|dir>` is empty for the same reason and it took a measurement to learn it.
	## The derivation gave `export.zip`, which answers `unzip_failed`; a deliberately absent
	## `/nonexistent/1` answers `no_activities_csv`. There is no path that satisfies this
	## argument without a real Strava export on disk, so the honest answer is that it is not
	## statically knowable — the same class as an activity id, reached by a different road.
	Arg : { name : Str, required : Bool, example : Str }

	## What a caller needs to INVOKE a command, not merely to name it (#219).
	##
	## `stride --json` used to answer with bare strings, which lets an agent enumerate
	## and nothing more: it could not learn the argument shape, whether a call writes to
	## the database, whether it needs the network, or which schema the answer follows.
	## ADR 0000 §10 declines an MCP server on the grounds that the CLI plus versioned
	## JSON already IS the agent interface. This is that claim taken seriously.
	##
	## ONE ENTRY PER CALLABLE FORM, not per verb: `week` reads and `week add` writes, so
	## a single `week` entry could not answer `mutates` honestly for either.
	##
	## The table is HAND-WRITTEN and cross-checked, not generated. What is enforced, and
	## what is not, stated plainly because a reader who assumes the whole record is
	## machine-derived will trust the unchecked half:
	##   name (verb)  — compared against the parser's own arms, both directions, with a
	##                  count gate. Adding a command without an entry fails.
	##   name (form)  — both directions: every multi-word name must be one the parser
	##                  reaches, and every two-literal arm the parser has must be
	##                  accounted for, with the leftovers pinned as a value.
	##   schema       — must exist, every file in schemas/v2 must be claimed or pinned, AND
	##                  each form is run and its payload validated against the file it
	##                  names. A wrong-but-existing filename looks exactly like a right one.
	##   mutates      — run against a fixture copy; the database contents must not move.
	##   network      — the declared set is pinned as a value, and `Http.send!` is pinned to
	##                  two functions in one module. NOT a derivation: nothing walks the
	##                  call graph, so a command that newly reaches those functions would
	##                  keep all three checks green while declaring `network: false`.
	##   interactive  — the same three-check shape, against `Stdin`, with the same gap.
	##   args         — enforced in both arity directions AND in order: filling every
	##                  declared argument is never a usage error, one short of the required
	##                  count always is, and required arguments must form a prefix. Literal
	##                  arguments and enum members are matched against the parser's arms.
	##                  What is NOT enforced is the free placeholder TEXT — `<days>` versus
	##                  `<limit>` versus `<n>` — which is exactly where this table's first
	##                  defects were, and the only part a reader should treat as declared.
	Spec : {
		name : Str,
		args : List(Arg),
		## writes to the database. Checked against behaviour rather than trusted: the
		## offline e2e suite runs every `mutates: False` form against a copy of the
		## fixture and fails if the database CONTENTS move. Contents, not file bytes —
		## WAL means a committed write can leave db.sqlite untouched.
		mutates : Bool,
		## talks to Strava. Since #232 that is `auth` and `sync` and nothing else.
		network : Bool,
		## blocks on a human. `auth` opens a browser and waits for a paste, so it is the
		## one form an unattended agent must not call.
		interactive : Bool,
		## the file under schemas/v2 its success payload validates against, "" when the
		## command has no machine payload of its own.
		schema : Str,
		## error codes THIS FORM can return, on top of `universal_error_codes` below.
		## The pair matters: an agent deciding whether a failure is worth retrying needs
		## to tell "this database is unreadable" (universal, retrying will not help) from
		## "no power data in the window" (specific to this form and this data).
		##
		## Two tiers rather than one list per form because most of the codes raised in
		## app.roc are boundary codes that ANY form can hit — nineteen copies of
		## `no_database` would be a drift surface with no information in it, which is the
		## trap #219 named when it left this bullet undone.
		##
		## NOT claimed to be exhaustive, and the schema says so in those words. What IS
		## mechanically true is stated by the two checks in the e2e suite: every code
		## declared here exists in the envelope contract, and every code in the envelope
		## contract is declared by some form or listed as unattributable. The second is the
		## one that matters — it makes adding a code without attributing it fail, which is
		## the direction a hand-maintained list normally rots in.
		error_codes : List(Str),
	}

	## Codes any form can return, so no form declares them. The database ones are raised
	## at app.roc's boundary and reachable from every command that opens the db; `usage` is
	## reachable from every form, including argument-less ones, by passing an extra word.
	##
	## `unknown_command` is deliberately NOT here and NOT on any form: it is what you get
	## when there is no form, so attributing it to one would be false. It is listed as
	## unattributable in the e2e completeness check, with that reason.
	universal_error_codes : List(Str)
	universal_error_codes = ["corrupt_database", "database_error", "internal_error", "no_database", "unreadable_database", "usage"]

	verb_of : Str -> Str
	verb_of = |name| (List.first(Str.split_on(name, " "))).ok_or(name)

	## `req`/`opt` DERIVE the example from the name wherever the name already contains it,
	## so the common case cannot drift: an alternation names its own valid values, a literal
	## is its own example, and a flag is itself. Only the shapes whose valid values are not
	## in the name — a date, a count, a config key — need `req_ex`/`opt_ex`, and those are
	## the ones a reader should have to look at.
	req : Str -> Arg
	req = |name| { name, required: True, example: example_of(name) }

	opt : Str -> Arg
	opt = |name| { name, required: False, example: example_of(name) }

	## ...and the explicit forms, for an argument whose valid values the name does not spell.
	req_ex : Str, Str -> Arg
	req_ex = |name, example| { name, required: True, example }

	opt_ex : Str, Str -> Arg
	opt_ex = |name, example| { name, required: False, example }

	## A value satisfying `name`, when the name says what it is.
	##
	## `<a|b|c>` -> `a`. That is the same reading `just schema-check`'s `case` block already
	## did ("an alternation names its own valid values; take the first"), lifted to where the
	## alternation is declared so the three consumers cannot each re-derive it differently.
	##
	## A bare literal — `all`, `--all` — is its own example. Anything else yields "", which
	## a consumer must read as "not statically knowable", NOT as an empty argument: that is
	## `<activity_id>`, whose value has to come from the data.
	example_of : Str -> Str
	example_of = |name|
		if !(Str.starts_with(name, "<")) {
			name
		} else if Str.contains(name, "|") {
			first = List.first(Str.split_on(Str.replace_each(Str.replace_each(name, "<", ""), ">", ""), "|"))
			match first {
				Ok(v) => if Str.contains(v, "_") "" else v
				Err(_) => ""
			}
		} else {
			""
		}

	## read-only, offline, non-interactive — the shape most commands have, so the table
	## below states only the exceptions and each exception is visible at a glance.
	reads : Str, List(Arg), Str -> Spec
	reads = |name, args, schema| { name, args, mutates: False, network: False, interactive: False, schema, error_codes: [] }

	writes : Str, List(Arg), Str -> Spec
	writes = |name, args, schema| { ..reads(name, args, schema), mutates: True }

	## reads/writes with form-specific error codes. A separate constructor rather than a
	## sixth positional argument, so the forms that have none stay one line.
	errs : Spec, List(Str) -> Spec
	errs = |spec, codes| { ..spec, error_codes: codes }

	specs : List(Spec)
	specs = [
		writes("init", [], "init.json"),
		errs({ ..writes("auth", [], "auth.json"), network: True, interactive: True }, ["missing_client_creds", "network_unreachable", "not_authenticated", "rate_limited", "stdin_closed", "strava_error"]),
		errs({ ..writes("sync", [opt("--all")], "sync.json"), network: True }, ["missing_client_creds", "network_unreachable", "not_authenticated", "rate_limited", "strava_error", "unreadable_config"]),
		errs(writes("analyze", [], "analyze.json"), ["missing_config", "unreadable_activity_date", "unreadable_config"]),
		errs(writes("import", [req_ex("<export.zip|dir>", "")], "import.json"), ["empty_csv", "no_activities_csv", "unzip_failed"]),
		errs(writes("rate", [req("<activity_id|latest>"), req("<1-10>")], "rate.json"), ["activity_not_found", "bad_id", "bad_rpe", "no_activities", "unreadable_activity_date"]),
		errs(writes("week add", [req_ex("<YYYY-MM-DD>", "2099-01-01"), req_ex("<type>", "endurance"), req_ex("<detail>", "example"), req_ex("<rationale>", "example")], "week_add.json"), ["bad_date"]),
		errs(writes("complete", [req("<session_id>"), opt("<activity_id>")], "complete.json"), ["activity_already_linked", "activity_not_found", "activity_required", "bad_id", "session_not_found"]),
		errs(writes("skip", [req("<session_id>"), req("<reason>"), opt("<activity_id|none>")], "skip.json"), ["activity_already_linked", "activity_not_found", "bad_id", "session_done", "session_not_found"]),
		errs(writes("config set", [req_ex("<key>", "timezone"), req_ex("<value>", "UTC")], "config.json"), ["bad_value", "derived_key", "unknown_key"]),
		errs(reads("summary", [], "summary.json"), ["missing_config", "no_data", "unreadable_activity_date", "unreadable_config", "unreadable_daily_load_day"]),
		errs(reads("plan", [], "plan.json"), ["missing_config", "no_data", "unreadable_activity_date", "unreadable_config", "unreadable_daily_load_day"]),
		## `stats` had no declared codes: its totals are a pure listing, until #249 found
		## that `WHERE start_local >= :cutoff` is NULL-false, so an unreadable date leaves
		## an ALL TIME total silently short. It refuses now.
		errs(reads("stats", [], "stats.json"), ["unreadable_activity_date"]),
		reads("doctor", [], "doctor.json"),
		errs(reads("zones", [], "zones.json"), ["no_power_data"]),
		errs(reads("pz", [], "zones.json"), ["no_power_data"]),
		errs(reads("compare", [opt("<week|month>")], "compare.json"), ["bad_period", "no_data", "unreadable_activity_date", "unreadable_daily_load_day"]),
		errs(reads("activities", [opt_ex("<limit>", "5"), opt_ex("<sport>", "Ride")], "activities.json"), ["bad_count"]),
		## `unreadable_activity_date` on the three forms #249 made REFUSE rather than report
		## an empty date. The split is by what the form does with the date: `activities` and
		## `top` list or rank and still report the row, so they gain no code; `activity`,
		## `reps` and `progress` compute from it — a 90-day window, a comparables filter, a
		## trend — and now name the row instead of answering over a value they invented.
		errs(reads("activity", [req("<activity_id>")], "activity.json"), ["activity_not_found", "unreadable_activity_date"]),
		## the metric set is CLOSED, so it is spelled out. A caller reading only this
		## payload cannot guess it, and it is the one required argument here whose
		## wrong value costs a round trip (`bad_metric`).
		errs(reads("top", [req("<hr|tss|power|intensity|distance|time|output>"), opt_ex("<limit>", "5"), opt_ex("<sport>", "Ride")], "top.json"), ["bad_count", "bad_metric"]),
		## DAYS of lookback, not a row count — `power-curve` returns a fixed set of
		## points regardless, so `<n>` beside `activities`' `<n>` left two identical
		## shapes meaning different things.
		## `unreadable_daily_load_day` because #249 made `load` refuse a day it used to
		## render as a 1969 week. It was the ONLY reader of that table not declaring the
		## code, and nothing caught the gap: the e2e union check at tests/e2e.roc passes
		## because summary, plan and compare declare it, so the union was satisfied by
		## three other forms while this one was wrong — a check green for the wrong reason.
		errs(reads("load", [opt_ex("<days>", "30")], "load.json"), ["bad_count", "unreadable_daily_load_day"]),
		errs(reads("power-curve", [opt_ex("<days>", "30"), opt_ex("<sport>", "Ride")], "power_curve.json"), ["bad_count"]),
		errs(reads("pc", [opt_ex("<days>", "30"), opt_ex("<sport>", "Ride")], "power_curve.json"), ["bad_count"]),
		## A DATE, not a workout name. The parse arm BOUND this to a variable called
		## `name` until this commit renamed it, and that binder is where an earlier draft
		## of this table got `<name>` from — the
		## handler queries `substr(a.start_local,1,10) = :date` and answers
		## `no_workout_on_date`. Every other document in the repo says `[date]`; only
		## this table said otherwise, and this table is the one an agent reads.
		errs(reads("progress", [opt("<YYYY-MM-DD>"), opt("<asc|desc>")], "progress.json"), ["no_scorable_workouts", "no_workout_on_date", "unreadable_activity_date", "unscorable"]),
		errs(reads("tte", [req_ex("<watts>", "300")], "tte.json"), ["bad_watts", "no_cp_fit"]),
		errs(reads("reps", [opt("<YYYY-MM-DD>")], "reps.json"), ["irregular_anchor", "no_detected_intervals", "no_intervals_on_date", "unreadable_activity_date"]),
		errs(reads("season", [], "season.json"), ["no_activities", "unreadable_activity_date", "unreadable_daily_load_day"]),
		## `week` had NO declared codes at all, and now has one: #249 made it refuse an
		## unplanned activity whose date it used to sort to the epoch and list first.
		errs(reads("week", [opt("all")], "week.json"), ["unreadable_activity_date"]),
		reads("config", [], "config_list.json"),
		errs(reads("config get", [req_ex("<key>", "timezone")], "config.json"), ["derived_key", "not_set", "unknown_key"]),
		reads("--version", [], "version.json"),
		reads("--help", [], "commands.json"),
		reads("-h", [], "commands.json"),
		reads("help", [], "commands.json"),
	]

	count : Str, (U64 -> Command) -> Try(Command, ParseErr)
	count = |s, f|
		match Metrics.arg_u64(s) {
			Ok(n) => Ok(f(n))
			Err(_) => Err(BadCount(s))
		}
}

# ── tests (ALL forms — migration preserves coverage, does not trim it) ──
expect
	match Command.parse(["stride", "init"]) {
		Ok(Init) => True
		_ => False
	}
expect
	match Command.parse(["stride", "--version"]) {
		Ok(Version) => True
		_ => False
	}
expect
	match Command.parse(["stride", "compare"]) {
		Ok(Compare("week")) => True
		_ => False
	}
expect
	match Command.parse(["stride", "compare", "month"]) {
		Ok(Compare("month")) => True
		_ => False
	}
expect
	match Command.parse(["stride", "activities"]) {
		Ok(Activities(30, "")) => True
		_ => False
	}
expect
	match Command.parse(["stride", "activities", "10"]) {
		Ok(Activities(10, "")) => True
		_ => False
	}
expect
	match Command.parse(["stride", "activities", "10", "rowing"]) {
		Ok(Activities(10, "rowing")) => True
		_ => False
	}
expect
	match Command.parse(["stride", "activities", "banana"]) {
		Err(BadCount("banana")) => True
		_ => False
	}
expect
	match Command.parse(["stride", "top", "tss"]) {
		Ok(Top("tss", 10, "")) => True
		_ => False
	}
expect
	match Command.parse(["stride", "top", "tss", "5"]) {
		Ok(Top("tss", 5, "")) => True
		_ => False
	}
expect
	match Command.parse(["stride", "top", "tss", "x"]) {
		Err(BadCount("x")) => True
		_ => False
	}
expect
	match Command.parse(["stride", "load"]) {
		Ok(Load(90)) => True
		_ => False
	}
expect
	match Command.parse(["stride", "load", "7"]) {
		Ok(Load(7)) => True
		_ => False
	}
expect
	match Command.parse(["stride", "power-curve"]) {
		Ok(PowerCurve(90, "")) => True
		_ => False
	}
expect
	match Command.parse(["stride", "pc", "60"]) {
		Ok(PowerCurve(60, "")) => True
		_ => False
	}
expect
	match Command.parse(["stride", "pc", "60", "Ride"]) {
		Ok(PowerCurve(60, "Ride")) => True
		_ => False
	}
expect
	match Command.parse(["stride", "power-curve", "nope"]) {
		Err(BadCount("nope")) => True
		_ => False
	}
expect
	match Command.parse(["stride", "pz"]) {
		Ok(Zones) => True
		_ => False
	}
expect
	match Command.parse(["stride", "zones"]) {
		Ok(Zones) => True
		_ => False
	}
expect
	match Command.parse(["stride", "progress"]) {
		Ok(Progress("", Asc)) => True
		_ => False
	}
expect
	match Command.parse(["stride", "progress", "2026-01-01"]) {
		Ok(Progress("2026-01-01", Asc)) => True
		_ => False
	}
# a bare sort word is a sort, not a date anchor
expect
	match Command.parse(["stride", "progress", "desc"]) {
		Ok(Progress("", Desc)) => True
		_ => False
	}
expect
	match Command.parse(["stride", "progress", "2026-01-01", "desc"]) {
		Ok(Progress("2026-01-01", Desc)) => True
		_ => False
	}
# a third arg that isn't asc/desc gets the targeted usage hint
# reps takes a DATE or nothing. `reps asc` used to reach the database and come
# back "no detected interval structure on asc" -- a data fact about a date that
# does not exist. This validation had no test at all until it moved here.
expect
	match Command.parse(["stride", "reps", "asc"]) {
		Err(Usage(u)) => Str.contains(u, "not a date")
		_ => False
	}
expect
	match Command.parse(["stride", "reps", "notadate"]) {
		Err(Usage(u)) => Str.contains(u, "not a date")
		_ => False
	}
# a well-formed date and the bare form still parse (Command is opaque, so the
# assertion has to match rather than compare)
expect
	match Command.parse(["stride", "reps", "2026-08-16"]) {
		Ok(Reps(d)) => d == "2026-08-16"
		_ => False
	}
expect
	match Command.parse(["stride", "reps"]) {
		Ok(Reps(d)) => d == ""
		_ => False
	}
# a date-SHAPED string that is not a real day is still refused
expect
	match Command.parse(["stride", "reps", "2026-13-45"]) {
		Err(Usage(u)) => Str.contains(u, "not a date")
		_ => False
	}

expect
	match Command.parse(["stride", "progress", "2026-01-01", "sideways"]) {
		Err(Usage(u)) => Str.contains(u, "asc|desc")
		_ => False
	}
# a sort word in the DATE position is never a date: `progress desc asc` used to anchor on
# a workout named "desc" instead of refusing
expect
	match Command.parse(["stride", "progress", "desc", "asc"]) {
		Err(Usage(u)) => Str.contains(u, "asc|desc")
		_ => False
	}
expect
	match Command.parse(["stride", "progress", "asc", "desc"]) {
		Err(Usage(u)) => Str.contains(u, "asc|desc")
		_ => False
	}
expect
	match Command.parse(["stride", "week"]) {
		Ok(WeekView) => True
		_ => False
	}
expect
	match Command.parse(["stride", "week", "all"]) {
		Ok(WeekViewAll) => True
		_ => False
	}
expect
	match Command.parse(["stride", "week", "add", "2026-01-01", "vo2max", "d", "r"]) {
		Ok(WeekAdd("2026-01-01", "vo2max", "d", "r")) => True
		_ => False
	}
expect
	match Command.parse(["stride", "complete", "3", "101"]) {
		Ok(Complete("3", "101")) => True
		_ => False
	}
expect
	match Command.parse(["stride", "complete", "3"]) {
		Ok(CompleteRest("3")) => True
		_ => False
	}
expect
	match Command.parse(["stride", "skip", "3", "sick"]) {
		Ok(Skip("3", "sick")) => True
		_ => False
	}
expect
	match Command.parse(["stride", "skip", "3", "rode outdoors instead", "19755802565"]) {
		Ok(SkipWith("3", "rode outdoors instead", "19755802565")) => True
		_ => False
	}
expect
	match Command.parse(["stride", "config", "get", "ftp"]) {
		Ok(ConfigGet("ftp")) => True
		_ => False
	}
expect
	match Command.parse(["stride", "config", "set", "ftp", "250"]) {
		Ok(ConfigSet("ftp", "250")) => True
		_ => False
	}
expect
	match Command.parse(["stride", "week", "add"]) {
		Err(Usage("week add <YYYY-MM-DD> <type> \"<detail>\" \"<rationale>\" — or bare `week` for this week's sessions, `week all` for the whole log")) => True
		_ => False
	}
# the old spellings must land on their REPLACEMENT, not on generic help — `plan all`
# meant the session log, so it points at `week all`, not at `week add`
expect
	match Command.parse(["stride", "plan", "all"]) {
		Err(Usage(u)) => Str.contains(u, "week all")
		_ => False
	}
expect
	match Command.parse(["stride", "plan", "add", "2026-01-01", "vo2max", "d", "r"]) {
		Err(Usage(u)) => Str.contains(u, "week add")
		_ => False
	}
# bare `plan` is the bundle and takes no arguments
expect
	match Command.parse(["stride", "plan"]) {
		Ok(Plan) => True
		_ => False
	}
# bare `config` LISTS what is set — it was a Usage error until #254, on the same reasoning
# as bare `plan` and bare `week` above: the shortest spelling of a command should answer
# the question the reader has, not scold them for not asking it precisely enough.
expect
	match Command.parse(["stride", "config"]) {
		Ok(ConfigList) => True
		_ => False
	}
# ...while a WRONG config form is still a Usage error, so the arm above did not eat them
expect
	match Command.parse(["stride", "config", "get"]) {
		Err(Usage("config get <key>  |  config set <key> <value>")) => True
		_ => False
	}
expect
	match Command.parse(["stride", "config", "set", "timezone"]) {
		Err(Usage("config get <key>  |  config set <key> <value>")) => True
		_ => False
	}
expect
	match Command.parse(["stride", "wat"]) {
		Err(UnknownCmd("wat")) => True
		_ => False
	}
expect
	match Command.parse(["stride"]) {
		Err(ShowHelp) => True
		_ => False
	}


# asking for help is never an error, however it is spelled (#163)
expect {
    help_forms = [["stride"], ["stride", "--help"], ["stride", "-h"], ["stride", "help"]]
    List.all(help_forms, |f|
        match Command.parse(f) {
            Err(ShowHelp) => True
            _ => False
        })
}

# a REAL command with wrong arguments is a usage error naming itself, never
# "no such command" — the message must not assert something false
expect {
    match Command.parse(["stride", "sync", "extra"]) {
        Err(Usage(u)) => Str.contains(u, "sync")
        _ => False
    }
}
expect {
    match Command.parse(["stride", "top"]) {
        Err(Usage(_)) => True
        _ => False
    }
}
# ...and a name stride genuinely lacks is still unknown
expect {
    match Command.parse(["stride", "wat"]) {
        Err(UnknownCmd("wat")) => True
        _ => False
    }
}
# One expect per name in `command_names`, each in its minimal valid form. Asserting
# each maps to its OWN variant is the real drift guard: an earlier version of this
# checked only that names in `command_names` avoid UnknownCmd, which is TRUE BY
# CONSTRUCTION (membership is what routes them elsewhere) and so could not fail —
# deleting `[_, "stats"] => Ok(Stats)` left it green. Review caught it with four
# mutations. It then pinned only ten of the thirty-two names while the comment beside
# `command_names` claimed the whole list, so deleting the `season` arm also left it
# green; review caught THAT one too. The aliases share a variant with
# their long form on purpose — deleting either arm still fails here, because the
# name then falls through to the wrong-arguments usage error rather than its command.
# example_of: the derivation from a placeholder's own text. Mutation-proved one clause at a
# time, because the SITES that consume these values cannot tell a good example from a
# merely-parseable one — `rate activity_id 5` parses fine and answers activity_not_found,
# so every sweep stays green on a value no database can satisfy.
expect Command.example_of("all") == "all"
expect Command.example_of("--all") == "--all"
# an alternation names its own valid values; take the FIRST. Taking the last is a different
# but still-valid metric for `top`, which is exactly why no invocation-based check catches it.
expect Command.example_of("<hr|tss|power|intensity|distance|time|output>") == "hr"
expect Command.example_of("<week|month>") == "week"
expect Command.example_of("<asc|desc>") == "asc"
# ...unless the first alternative is a METAVARIABLE, in which case the alternation does not
# name a usable value and the answer is "not statically knowable". `rate activity_id 5` is
# the failure this clause prevents: it parses, so nothing downstream refuses it.
expect Command.example_of("<activity_id|latest>") == ""
expect Command.example_of("<activity_id|none>") == ""
# ...and a bare placeholder never names its value
expect Command.example_of("<key>") == ""
expect Command.example_of("<YYYY-MM-DD>") == ""
expect Command.example_of("<activity_id>") == ""

expect match Command.parse(["stride", "init"]) { Ok(Init) => True  _ => False }
expect match Command.parse(["stride", "auth"]) { Ok(Auth) => True  _ => False }
expect match Command.parse(["stride", "sync"]) { Ok(Sync(False)) => True  _ => False }
expect match Command.parse(["stride", "sync", "--all"]) { Ok(Sync(True)) => True  _ => False }
expect match Command.parse(["stride", "analyze"]) { Ok(Analyze) => True  _ => False }
expect match Command.parse(["stride", "summary"]) { Ok(Summary) => True  _ => False }
expect match Command.parse(["stride", "stats"]) { Ok(Stats) => True  _ => False }
expect match Command.parse(["stride", "doctor"]) { Ok(Doctor) => True  _ => False }
expect match Command.parse(["stride", "import", "x.zip"]) { Ok(Import("x.zip")) => True  _ => False }
expect match Command.parse(["stride", "rate", "1", "5"]) { Ok(Rate("1", "5")) => True  _ => False }
expect match Command.parse(["stride", "activity", "7"]) { Ok(Activity("7")) => True  _ => False }
expect match Command.parse(["stride", "zones"]) { Ok(Zones) => True  _ => False }
expect match Command.parse(["stride", "pz"]) { Ok(Zones) => True  _ => False }
expect match Command.parse(["stride", "compare"]) { Ok(Compare("week")) => True  _ => False }
expect match Command.parse(["stride", "activities"]) { Ok(Activities(30, "")) => True  _ => False }
expect match Command.parse(["stride", "top", "np"]) { Ok(Top("np", 10, "")) => True  _ => False }
expect match Command.parse(["stride", "load"]) { Ok(Load(90)) => True  _ => False }
expect match Command.parse(["stride", "power-curve"]) { Ok(PowerCurve(90, "")) => True  _ => False }
expect match Command.parse(["stride", "pc"]) { Ok(PowerCurve(90, "")) => True  _ => False }
expect match Command.parse(["stride", "progress"]) { Ok(Progress("", Asc)) => True  _ => False }
expect match Command.parse(["stride", "week"]) { Ok(WeekView) => True  _ => False }
expect match Command.parse(["stride", "plan"]) { Ok(Plan) => True  _ => False }
expect match Command.parse(["stride", "complete", "3", "9"]) { Ok(Complete("3", "9")) => True  _ => False }
expect match Command.parse(["stride", "skip", "3", "sick"]) { Ok(Skip("3", "sick")) => True  _ => False }
expect match Command.parse(["stride", "config", "get", "ftp"]) { Ok(ConfigGet("ftp")) => True  _ => False }
expect match Command.parse(["stride", "tte", "250"]) { Ok(Tte("250")) => True  _ => False }
expect match Command.parse(["stride", "reps"]) { Ok(Reps("")) => True  _ => False }
expect match Command.parse(["stride", "season"]) { Ok(Season) => True  _ => False }
expect match Command.parse(["stride", "--version"]) { Ok(Version) => True  _ => False }
expect match Command.parse(["stride", "--help"]) { Err(ShowHelp) => True  _ => False }
expect match Command.parse(["stride", "-h"]) { Err(ShowHelp) => True  _ => False }
expect match Command.parse(["stride", "help"]) { Err(ShowHelp) => True  _ => False }

# a help spelling with junk after it is still a help spelling, not an unknown
# command — the falsehood item 2 removed, surviving in a corner
expect {
    match Command.parse(["stride", "--help", "extra"]) {
        Err(Usage(u)) => Str.contains(u, "--help")
        _ => False
    }
}

# format flags (#162): stripped from any position, last wins, args preserved
expect {
    r = Command.split_format_args(["stride", "summary", "--json"])
    r.mode == ForceJson and r.rest == ["stride", "summary"]
}
expect {
    r = Command.split_format_args(["stride", "--json", "activities", "5"])
    r.mode == ForceJson and r.rest == ["stride", "activities", "5"]
}
expect {
    r = Command.split_format_args(["stride", "--human", "--json", "summary"])
    r.mode == ForceJson and r.rest == ["stride", "summary"]
}
expect {
    r = Command.split_format_args(["stride", "--json", "--human", "summary"])
    r.mode == ForceHuman and r.rest == ["stride", "summary"]
}
expect {
    r = Command.split_format_args(["stride", "summary"])
    r.mode == Auto and r.rest == ["stride", "summary"]
}
# `--` ends flag parsing: a literal "--json" argument survives intact, and the
# terminator itself never reaches the command parser
expect {
    r = Command.split_format_args(["stride", "skip", "5", "--", "--json"])
    r.mode == Auto and r.rest == ["stride", "skip", "5", "--json"]
}
expect {
    r = Command.split_format_args(["stride", "--json", "skip", "5", "--", "--human"])
    r.mode == ForceJson and r.rest == ["stride", "skip", "5", "--human"]
}
