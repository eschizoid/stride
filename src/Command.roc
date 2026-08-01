module [Command, ParseErr, parse]

## A fully-parsed CLI invocation. Count arguments are validated to real numbers
## HERE (the pure layer), so the effectful `main!` never re-parses argv — it just
## dispatches on the tag. Keeping parsing pure makes every arg form unit-testable
## without a database or a process.
Command : [
    Init,
    Auth,
    Sync,
    Backfill,
    Analyze,
    Summary,
    Stats,
    Week,
    Doctor,
    Zones,
    Version,
    Compare Str, # period ("week" | "month")
    Activities U64 Str, # count, sport-filter ("" = all)
    Top Str U64 Str, # metric, count, sport-filter
    Import Str, # source path
    Rate Str Str, # target, rpe (parsed downstream)
    Progress Str, # workout name/date ("" = latest)
    Activity Str, # activity id
    Load U64, # days
    PlanView, # current training week (Mon-Sun)
    PlanViewAll, # the full log
    PlanAdd Str Str Str Str, # date, type, detail, rationale
    Complete Str Str, # session id, activity id
    CompleteRest Str, # session id (rest days need no activity)
    Skip Str Str, # session id, reason
    ConfigGet Str, # key
    ConfigSet Str Str, # key, value
]

## Why parsing failed, mapped by the caller to output:
##   ShowHelp    -> the full help text (unknown / empty command)
##   Usage Str   -> a targeted one-line hint (right command, wrong arity)
##   BadCount Str -> a count argument that wasn't a number
ParseErr : [ShowHelp, Usage Str, BadCount Str]

## argv (including the program name at index 0) -> a typed command. Mirrors the
## historical `main!` dispatch exactly; behavior-preserving by construction.
parse : List Str -> Result Command ParseErr
parse = |args|
    when args is
        [_, "init"] -> Ok(Init)
        [_, "auth"] -> Ok(Auth)
        [_, "sync"] -> Ok(Sync)
        [_, "backfill"] -> Ok(Backfill)
        [_, "analyze"] -> Ok(Analyze)
        [_, "summary"] -> Ok(Summary)
        [_, "stats"] -> Ok(Stats)
        [_, "week"] -> Ok(Week)
        [_, "compare"] -> Ok(Compare("week"))
        [_, "compare", period] -> Ok(Compare(period))
        [_, "activities"] -> Ok(Activities(30, ""))
        [_, "activities", n] -> count(n, |c| Activities(c, ""))
        [_, "activities", n, sport] -> count(n, |c| Activities(c, sport))
        [_, "top", metric] -> Ok(Top(metric, 10, ""))
        [_, "top", metric, n] -> count(n, |c| Top(metric, c, ""))
        [_, "top", metric, n, sport] -> count(n, |c| Top(metric, c, sport))
        [_, "import", src] -> Ok(Import(src))
        [_, "rate", target, rpe_str] -> Ok(Rate(target, rpe_str))
        [_, "doctor"] -> Ok(Doctor)
        [_, "zones"] -> Ok(Zones)
        [_, "pz"] -> Ok(Zones)
        [_, "progress"] -> Ok(Progress(""))
        [_, "progress", name] -> Ok(Progress(name))
        [_, "activity", id_str] -> Ok(Activity(id_str))
        [_, "load"] -> Ok(Load(90))
        [_, "load", n] -> count(n, |c| Load(c))
        [_, "plan"] -> Ok(PlanView)
        [_, "plan", "all"] -> Ok(PlanViewAll)
        [_, "plan", "add", date, session_type, detail, rationale] -> Ok(PlanAdd(date, session_type, detail, rationale))
        [_, "complete", session_id, activity_id] -> Ok(Complete(session_id, activity_id))
        [_, "complete", session_id] -> Ok(CompleteRest(session_id))
        [_, "skip", session_id, reason] -> Ok(Skip(session_id, reason))
        [_, "config", "get", key] -> Ok(ConfigGet(key))
        [_, "config", "set", key, val] -> Ok(ConfigSet(key, val))
        [_, "--version"] -> Ok(Version)
        # wrong arity on a recognized multi-arg command: a targeted hint, not the
        # whole help wall.
        [_, "plan", ..] -> Err(Usage("plan add <YYYY-MM-DD> <type> \"<detail>\" \"<rationale>\" — or bare `plan` to view the log"))
        [_, "complete", ..] -> Err(Usage("complete <session_id> [activity_id]"))
        [_, "skip", ..] -> Err(Usage("skip <session_id> \"<reason>\""))
        [_, "activity", ..] -> Err(Usage("activity <activity_id>"))
        [_, "config", ..] -> Err(Usage("config get <key>  |  config set <key> <value>"))
        _ -> Err(ShowHelp)

count : Str, (U64 -> Command) -> Result Command ParseErr
count = |s, f|
    when Str.to_u64(s) is
        Ok(n) -> Ok(f(n))
        Err(_) -> Err(BadCount(s))

# ── tests ────────────────────────────────────────────────────────────
expect parse(["stride", "init"]) == Ok(Init)
expect parse(["stride", "--version"]) == Ok(Version)
expect parse(["stride", "compare"]) == Ok(Compare("week"))
expect parse(["stride", "compare", "month"]) == Ok(Compare("month"))
expect parse(["stride", "activities"]) == Ok(Activities(30, ""))
expect parse(["stride", "activities", "10"]) == Ok(Activities(10, ""))
expect parse(["stride", "activities", "10", "rowing"]) == Ok(Activities(10, "rowing"))
expect parse(["stride", "activities", "banana"]) == Err(BadCount("banana"))
expect parse(["stride", "top", "tss"]) == Ok(Top("tss", 10, ""))
expect parse(["stride", "top", "tss", "5"]) == Ok(Top("tss", 5, ""))
expect parse(["stride", "top", "tss", "x"]) == Err(BadCount("x"))
expect parse(["stride", "load"]) == Ok(Load(90))
expect parse(["stride", "load", "7"]) == Ok(Load(7))
expect parse(["stride", "pz"]) == Ok(Zones)
expect parse(["stride", "zones"]) == Ok(Zones)
expect parse(["stride", "progress"]) == Ok(Progress(""))
expect parse(["stride", "progress", "2026-01-01"]) == Ok(Progress("2026-01-01"))
expect parse(["stride", "plan"]) == Ok(PlanView)
expect parse(["stride", "plan", "all"]) == Ok(PlanViewAll)
expect parse(["stride", "plan", "add", "2026-01-01", "vo2max", "d", "r"]) == Ok(PlanAdd("2026-01-01", "vo2max", "d", "r"))
expect parse(["stride", "complete", "3", "101"]) == Ok(Complete("3", "101"))
expect parse(["stride", "complete", "3"]) == Ok(CompleteRest("3"))
expect parse(["stride", "skip", "3", "sick"]) == Ok(Skip("3", "sick"))
expect parse(["stride", "config", "get", "ftp"]) == Ok(ConfigGet("ftp"))
expect parse(["stride", "config", "set", "ftp", "250"]) == Ok(ConfigSet("ftp", "250"))
# wrong arity -> targeted usage, not help
expect parse(["stride", "plan", "add"]) == Err(Usage("plan add <YYYY-MM-DD> <type> \"<detail>\" \"<rationale>\" — or bare `plan` to view the log"))
expect parse(["stride", "config"]) == Err(Usage("config get <key>  |  config set <key> <value>"))
# unknown / empty -> help
expect parse(["stride", "wat"]) == Err(ShowHelp)
expect parse(["stride"]) == Err(ShowHelp)
