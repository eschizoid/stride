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
			[_, "progress", name] => Ok(Progress(name, Asc))
			[_, "progress", name, "asc"] => Ok(Progress(name, Asc))
			[_, "progress", name, "desc"] => Ok(Progress(name, Desc))
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
	## the VERBS, deduped — `week add` and `week` are two callable forms but one token to
	## the unknown-vs-wrong-arguments branch above.
	command_names : List(Str)
	command_names =
		List.fold(specs, [], |acc, s| {
			v = verb_of(s.name)
			if List.contains(acc, v) acc else List.append(acc, v)
		})

	## What a caller needs to invoke a command, not merely to name it (#219).
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
	## `verb` is the first token, which is what the unknown-vs-wrong-arguments branch
	## above compares against. It is DERIVED rather than stored so the two cannot drift —
	## storing both is how a list like this starts lying.
	Arg : { name : Str, required : Bool }
	Spec : {
		name : Str,
		args : List(Arg),
		## writes to the database. Verified against behaviour rather than trusted: the
		## e2e agent-contract driver runs every `mutates: False` form against a snapshot
		## and fails if the database is not byte-identical afterwards.
		mutates : Bool,
		## talks to Strava. Since #232 that is `auth` and `sync` and nothing else, which
		## the sync driver already pins independently.
		network : Bool,
		## blocks on a human. `auth` opens a browser and waits for a paste.
		interactive : Bool,
		## the file under schemas/v2 its success payload validates against, "" when the
		## command has no machine payload of its own. Checked to exist, and every schema
		## in that directory is checked to be claimed by some form.
		schema : Str,
	}

	verb_of : Str -> Str
	verb_of = |name| (List.first(Str.split_on(name, " "))).ok_or(name)

	req : Str -> Arg
	req = |name| { name, required: True }

	opt : Str -> Arg
	opt = |name| { name, required: False }

	## read-only, offline, non-interactive — the shape most commands have, so the table
	## below states only the exceptions and each exception is visible at a glance.
	reads : Str, List(Arg), Str -> Spec
	reads = |name, args, schema| { name, args, mutates: False, network: False, interactive: False, schema }

	writes : Str, List(Arg), Str -> Spec
	writes = |name, args, schema| { ..reads(name, args, schema), mutates: True }

	specs : List(Spec)
	specs = [
		writes("init", [], "init.json"),
		{ ..writes("auth", [], ""), network: True, interactive: True },
		{ ..writes("sync", [opt("--all")], "sync.json"), network: True },
		writes("analyze", [], "analyze.json"),
		writes("import", [req("<export.zip|dir>")], "import.json"),
		writes("rate", [req("<activity_id|latest>"), req("<1-10>")], "rate.json"),
		writes("week add", [req("<YYYY-MM-DD>"), req("<type>"), req("<detail>"), req("<rationale>")], "week_add.json"),
		writes("complete", [req("<session_id>"), opt("<activity_id>")], "complete.json"),
		writes("skip", [req("<session_id>"), req("<reason>"), opt("<activity_id|none>")], "skip.json"),
		writes("config set", [req("<key>"), req("<value>")], "config.json"),
		reads("summary", [], "summary.json"),
		reads("plan", [], "plan.json"),
		reads("stats", [], "stats.json"),
		reads("doctor", [], "doctor.json"),
		reads("zones", [], "zones.json"),
		reads("pz", [], "zones.json"),
		reads("compare", [opt("<week|month>")], "compare.json"),
		reads("activities", [opt("<n>"), opt("<sport>")], "activities.json"),
		reads("activity", [req("<activity_id>")], "activity.json"),
		reads("top", [req("<metric>"), opt("<n>"), opt("<sport>")], "top.json"),
		reads("load", [opt("<n>")], "load.json"),
		reads("power-curve", [opt("<n>"), opt("<sport>")], "power_curve.json"),
		reads("pc", [opt("<n>"), opt("<sport>")], "power_curve.json"),
		reads("progress", [opt("<name>"), opt("<asc|desc>")], "progress.json"),
		reads("tte", [req("<watts>")], "tte.json"),
		reads("reps", [opt("<YYYY-MM-DD>")], "reps.json"),
		reads("season", [], "season.json"),
		reads("week", [opt("all")], "week.json"),
		reads("config get", [req("<key>")], "config.json"),
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
expect
	match Command.parse(["stride", "config"]) {
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
