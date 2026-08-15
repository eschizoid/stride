## A fully-parsed CLI invocation. Count arguments are validated to real numbers
## HERE (the pure layer), so the effectful `main!` never re-parses argv — it just
## dispatches on the tag. Keeping parsing pure makes every arg form unit-testable
## without a database or a process.
Command := [
	Init,
	Auth,
	Sync,
	Backfill,
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
	Activity(Str),
	Load(U64),
	PowerCurve(U64, Str),
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
	##   ShowHelp     -> the full help text (unknown / empty command)
	##   Usage(Str)   -> a targeted one-line hint (right command, wrong arity)
	##   BadCount(Str) -> a count argument that wasn't a number
	ParseErr : [ShowHelp, Usage(Str), BadCount(Str)]

	## argv (including the program name at index 0) -> a typed command. Mirrors the
	## historical `main!` dispatch exactly; behavior-preserving by construction.
	parse : List(Str) -> Try(Command, ParseErr)
	parse = |args|
		match args {
			[_, "init"] => Ok(Init)
			[_, "auth"] => Ok(Auth)
			[_, "sync"] => Ok(Sync)
			[_, "backfill"] => Ok(Backfill)
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
			[_, "skip", ..] => Err(Usage("skip <session_id> \"<reason>\" [activity_id]"))
			[_, "activity", ..] => Err(Usage("activity <activity_id>"))
			[_, "config", ..] => Err(Usage("config get <key>  |  config set <key> <value>"))
			_ => Err(ShowHelp)
		}

	count : Str, (U64 -> Command) -> Try(Command, ParseErr)
	count = |s, f|
		match U64.from_str(s) {
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
		Err(ShowHelp) => True
		_ => False
	}
expect
	match Command.parse(["stride"]) {
		Err(ShowHelp) => True
		_ => False
	}

