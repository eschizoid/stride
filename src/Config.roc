## Credential config keys. These live in the db so sync can auto-refresh tokens,
## but they must NEVER be surfaced back through `config get` or any JSON payload —
## reading them through the query interface would defeat storing them at all. This
## list is the single source of truth for that rule (pure + tested here, so a new
## secret can't be added in one place and forgotten in the redaction check).
Config :: [].{

	secret_keys : List(Str)
	secret_keys = ["strava_access_token", "strava_refresh_token", "strava_client_secret"]

	# Fail CLOSED: the explicit list PLUS any key ending in _token / _secret, so a future
	# secret key is redacted even if someone forgets to add it to secret_keys. (Public keys
	# like strava_client_id / strava_expires_at end in _id / _at, so they're never swept in.)
	is_secret : Str -> Bool
	is_secret = |k|
		List.contains(secret_keys, k)
		or Str.ends_with(k, "_token")
		or Str.ends_with(k, "_secret")

	# Keys the engine LOOKS UP A VALUE FOR. Absent from this and `config get`/`set`
	# answer `unknown_key` rather than `not_set`/plain success (#254): `not_set`
	# says the key is fine and merely empty, which invites `config set timezon
	# <value>` — both halves of the round trip agreeing the key is real while
	# nothing ever reads it.
	#
	# The DERIVED family is deliberately NOT here: both verbs test `is_derived`
	# first, so a clause for it would be unreachable — and a rule no test can
	# falsify is not a guard. `known_key("ftp_ride") == False` is load-bearing.
	# `secret_keys` directly, NOT `is_secret`: that suffix rule is fail-OPEN so an
	# unlisted future secret still redacts, and reusing it here inverts that into
	# fail-open RECOGNITION — `config get strava_acess_token` (a typo, #254's own
	# scenario) answered "(not set)" again.
	#
	# The cost of a MISSING entry went up when `config set <key> ""` became a
	# DELETE: a read key absent from this list is now removable with "stride does
	# not read it" — silent and destructive, not annoying and visible. Two
	# documented keys are waiting to enter that state: `threshold_pace_<sport>` and
	# `model_<sport>`. Whoever wires one up MUST add it here in the same commit.
	# The reverse trap is why this derives from READ SITES, not docs: `metrics_rev`
	# sat here for one revision on the strength of an AGENTS.md sentence and has
	# never been read from config.
	# Hoisted out of `known_key` so it can be ENUMERATED: `config unset` writes one
	# sentence per key, and hand-typing this membership from memory shipped a false
	# one three rounds running. `tests/e2e.roc` walks this list and asserts every
	# member reaches a routed branch.
	plain_keys : List(Str)
	plain_keys = [
		"timezone",
		"utc_offset_minutes",
		"last_sync_epoch",
		"strava_client_id",
		"strava_expires_at",
		"strava_reads_today",
		"strava_reads_day",
	]

	known_key : Str -> Bool
	known_key = |k|
		List.contains(secret_keys, k)
		or List.contains(plain_keys, k)
		or is_zone_key(k)

	# Of the keys the engine reads, the ones a PERSON sets. The rest — `last_sync_epoch`,
	# the `strava_*` family — are stride's own bookkeeping, writable so a broken one can be
	# repaired but not things anyone configures.
	#
	# The line already existed in `known_key_summary`'s two groups; this makes it a value
	# the listing can show. Without it, `stride config` marked all twelve `read`, so a user
	# scanning it could not tell which four were theirs — the `unknown_key` refusal drew the
	# distinction and the listing beside it did not.
	user_settable : Str -> Bool
	user_settable = |k| k == "timezone" or k == "utc_offset_minutes" or is_zone_key(k)

	# What the `unknown_key` refusal tells the reader, in one place beside the predicate it
	# describes. The first cut named four keys while `config set` accepted twelve — the
	# same "advice pointing where the answer is not" the message was written to replace,
	# and it contradicted the listing, which shows `last_sync_epoch` and the `strava_*` keys
	# as set config. Two groups, because the distinction is real: the first are yours, the
	# second are stride's bookkeeping and are writable only so a broken one can be repaired.
	#
	# Pinned against `known_key` below: every literal that predicate accepts has an expect
	# asserting it appears here, so the two cannot drift.
	known_key_summary : Str
	known_key_summary = "Settable: timezone, utc_offset_minutes, hr_z1_max..hr_z4_max (optionally per sport, e.g. hr_z2_max_ride). Written by stride and rarely set by hand: last_sync_epoch, strava_client_id, strava_expires_at, strava_reads_today, strava_reads_day, strava_access_token, strava_refresh_token, strava_client_secret. FTP is derived, never set."

	# `hr_z1_max` .. `hr_z4_max`, optionally suffixed with a sport family
	# (`hr_z2_max_ride`) — exactly what `Metrics.hr_zone_key_global` and
	# `Metrics.hr_zone_key` build, and exactly what `ReportHealth` counts with
	# `key GLOB 'hr_z[1-4]_max_?*'`.
	#
	# Written out rather than `starts_with("hr_z") and contains("_max")`, which was the
	# first cut and claimed in its own comment to be the same shape as that GLOB. It was
	# not: it admitted `hr_z9_max`, `hr_zz_max`, `hr_z1_maximum` and `hr_z1_maxx`, none of
	# which any read site can produce, so four ways of mistyping a zone key kept answering
	# "(not set)" — the defect this predicate exists to remove.
	is_zone_key : Str -> Bool
	is_zone_key = |k| zone_shape(Str.to_utf8(k))

	# A CLIENT credential is one the user supplies; a SESSION credential is one stride
	# obtains and refreshes for itself. Both are secrets and both redact, but they differ in
	# the only thing a removal message cares about: what happens next. Deleting a session
	# token means re-authenticate; deleting a client credential means the user has to hand it
	# back before `auth` can even run.
	#
	# An EXPLICIT list, not a suffix rule, for the reason `known_key`'s own comment already
	# gives about `is_secret`: that rule is deliberately fail-OPEN so an unlisted future
	# secret is still redacted, and reusing it to pick a SENTENCE inverts a harmless
	# over-redaction into a false statement. Picking wording is recognition, not redaction.
	is_client_credential : Str -> Bool
	is_client_credential = |k| List.contains(["strava_client_id", "strava_client_secret"], k)

	# ...and the SESSION half: what `auth` writes and `sync` refreshes. Three keys, not the
	# two `is_secret` covers — `strava_expires_at` is read through the same `token_field!`
	# that maps `NotFound` to `NotAuthed`, and `auth` writes all three in one statement, so
	# deleting it produces the same news as deleting the token itself.
	#
	# It is deliberately NOT in `secret_keys`: it is a timestamp, and putting it there to
	# reach this branch would change REDACTION to fix WORDING. Two lists, because the two
	# questions are different.
	is_session_credential : Str -> Bool
	is_session_credential = |k| List.contains(["strava_access_token", "strava_refresh_token", "strava_expires_at"], k)

	# stride's own bookkeeping: the keys it really does recompute or re-fetch. Named
	# EXPLICITLY so the catch-all below stops being where unrouted keys land — that is what
	# let `strava_client_id`, `utc_offset_minutes` and `strava_expires_at` each inherit a
	# false sentence in three consecutive rounds, every time because a hand-typed list of
	# `known_key`'s members was one short.
	is_bookkeeping : Str -> Bool
	is_bookkeeping = |k| List.contains(["last_sync_epoch", "strava_reads_today", "strava_reads_day"], k)


	# bytes: h r _ z <digit> _ m a x, then either end-of-key or `_` and a non-empty suffix
	zone_shape : List(U8) -> Bool
	zone_shape = |b|
		match b {
			[104, 114, 95, 122, d, 95, 109, 97, 120, .. as rest] =>
				d >= 49 and d <= 52 and zone_suffix(rest)

			_ => False
		}

	# the GLOB's `_?*`: an underscore followed by at least one byte. A bare trailing `_`
	# (`hr_z1_max_`) is not a sport and no builder emits it.
	zone_suffix : List(U8) -> Bool
	zone_suffix = |b|
		match b {
			[] => True
			[95, _, ..] => True
			_ => False
		}

	# Keys the engine DERIVES and never reads from config. Accepting one would be worse
	# than refusing it: `config set ftp_ride 250` used to succeed, print a confirmation,
	# and change nothing, because Db.sport_ftp! computes FTP from the athlete's own power
	# history (ADR 0002, ADR 0005) and never consults config. A stored value that is
	# silently ignored is a trap, so setting one is rejected with the reason.
	is_derived : Str -> Bool
	is_derived = |k| k == "ftp" or Str.starts_with(k, "ftp_")

	# Keys whose value the engine parses as a NUMBER. Same reasoning as is_derived, one
	# step further in: a value that parses nowhere is as much a trap as a value that is
	# read nowhere, and it is a worse one, because `config get` echoes it back and looks
	# like proof it took.
	#
	# This exists because #201's narrowing created exactly that trap. Refusing exponent
	# notation at the READ sites meant `config set hr_z1_max 1.18e2` succeeded, echoed
	# `1.18e2`, and then made `summary` report missing_config -- the value WAS set. And
	# `utc_offset_minutes +330` silently became UTC instead of +05:30, because that read
	# path coalesces a parse failure to 0. Validating at the WRITE makes the refusal loud
	# and keeps the read sites honest.
	numeric_key : Str -> [Int, Decimal, Free]
	numeric_key = |k|
		if k == "utc_offset_minutes" or k == "last_sync_epoch" or k == "strava_reads_today" or k == "strava_reads_day" or Str.ends_with(k, "_expires_at")
			Int
		else if Str.starts_with(k, "hr_z")
			Decimal
		else
			Free

	# STRIDE_API_BASE is a test seam that points sync at a local mock. The token
	# exchange/refresh POST carries the client_secret + rotating refresh token, so an
	# unvalidated base would exfiltrate them to an attacker-controlled host. TLS does
	# NOT make that safe — an https attacker endpoint still RECEIVES the secrets — so the
	# allow-list is EXACT hosts (real Strava, or http to loopback for the e2e mock), not
	# "any https". host_ok also blocks the `localhost.attacker.tld` subdomain trick.
	api_base_allowed : Str -> Bool
	api_base_allowed = |b|
		host_ok(b, "https://www.strava.com")
		or host_ok(b, "http://localhost")
		or host_ok(b, "http://127.0.0.1")

	# b is exactly `hp` (scheme+host), or `hp` + a '/path', or `hp:` + a strictly numeric
	# port (then optional '/path'). The numeric-port rule blocks the userinfo bypass
	# `http://localhost:8799@attacker.tld` — it starts with `http://localhost:`, but a URL
	# parser reads `localhost:8799` as credentials and `attacker.tld` as the real host.
	host_ok : Str, Str -> Bool
	host_ok = |b, hp|
		if b == hp
			True
		else if Str.starts_with(b, "${hp}/")
			True
		else if Str.starts_with(b, "${hp}:")
			numeric_port(drop_n(Str.to_utf8(b), List.len(Str.to_utf8(hp)) + 1))
		else
			False

	# drop the first n bytes (recursive — no List.drop_first dependency)
	drop_n : List(U8), U64 -> List(U8)
	drop_n = |xs, n|
		if n == 0
			xs
		else
			match xs {
				[] => []
				[_, .. as rest] => drop_n(rest, n - 1)
			}

	# the bytes after `host:` must be a non-empty run of ASCII digits (48-57) ending at
	# end-of-string or a '/' path. Anything else — '@', a letter, '\' — is rejected, so an
	# authority a URL parser would resolve to a different host can't slip through.
	numeric_port : List(U8) -> Bool
	numeric_port = |bytes|
		match bytes {
			[] => False
			[c, .. as rest] =>
				if c >= 48 and c <= 57
					port_tail(rest)
				else
					False
		}
	port_tail : List(U8) -> Bool
	port_tail = |bytes|
		match bytes {
			[] => True
			[c, .. as rest] =>
				if c == 47
					True
				else if c >= 48 and c <= 57
					port_tail(rest)
				else
					False
		}

}

# numeric_key: every clause pinned, mutation-checked one at a time. A `_max`
# suffix clause was deleted rather than pinned — every key ending `_max` also
# starts `hr_z`, so it was unreachable, and an unreachable clause cannot be
# killed by any mutant. A rule no test can falsify is decoration, not a guard.
expect Config.numeric_key("utc_offset_minutes") == Int
expect Config.numeric_key("last_sync_epoch") == Int
expect Config.numeric_key("strava_expires_at") == Int
expect Config.numeric_key("hr_z1_max") == Decimal
# the per-sport zone keys, which the `_max` suffix does NOT reach -- `hr_z` is the only
# clause that classifies them, and dropping it left the whole suite green
expect Config.numeric_key("hr_z2_max_soccer") == Decimal
expect Config.numeric_key("hr_z4_max_ride") == Decimal
expect Config.numeric_key("timezone") == Free
expect Config.numeric_key("strava_access_token") == Free
expect Config.numeric_key("strava_client_id") == Free

# known_key: the keys the engine looks up a value for. Every clause was mutation-checked
# ALONE — a union of predicates makes it very easy to write an expect that some OTHER
# clause satisfies, so deleting the clause under test leaves the suite green.
expect Config.known_key("timezone") == True
expect Config.known_key("utc_offset_minutes") == True
expect Config.known_key("last_sync_epoch") == True
expect Config.known_key("strava_client_id") == True
expect Config.known_key("strava_expires_at") == True
expect Config.known_key("strava_reads_today") == True
expect Config.known_key("strava_reads_day") == True

# the three real secrets, via `secret_keys` — the read path redacts them and can only
# redact a key it admits exists. Deleting that clause leaves every literal above still
# True, so these are the only lines that kill it.
expect Config.known_key("strava_access_token") == True
expect Config.known_key("strava_refresh_token") == True
expect Config.known_key("strava_client_secret") == True

# ...but NOT through `is_secret`'s fail-open suffix rule, which is the mutant that shipped
# in the first cut. `is_secret` returns True for anything ending `_token` / `_secret` on
# purpose, so a future secret is redacted even if unlisted; borrowing it here turned that
# into fail-open RECOGNITION and let typos of the credential keys keep answering
# "(not set)" — issue #254's own scenario, in the family where it matters most.
expect Config.is_secret("strava_acess_token") == True
expect Config.known_key("strava_acess_token") == False
expect Config.known_key("stava_access_token") == False
expect Config.known_key("some_api_token") == False
expect Config.known_key("random_secret") == False

# the DERIVED family is deliberately absent: `config get`/`config set` refuse it by name
# before this predicate runs, so a clause here would be unreachable from every caller.
expect Config.known_key("ftp") == False
expect Config.known_key("ftp_ride") == False

# the zone family, exactly as `Metrics.hr_zone_key_global` and `hr_zone_key` build it. The
# per-sport suffix is the case a literal list cannot cover: `hr_z2_max_ride` appears
# nowhere in the source.
expect Config.known_key("hr_z1_max") == True
expect Config.known_key("hr_z4_max") == True
expect Config.known_key("hr_z2_max_ride") == True
expect Config.known_key("hr_z3_max_soccer") == True
expect Config.known_key("hr_z1_max_standuppaddling") == True

# EVERY digit outside 1..4, not just the two bracketing the range: widening the
# bound by ONE (`d <= 53`) made `config set hr_z5_max 200` write a row nothing
# reads, suite green — and hr_z5_max is the likeliest wrong edit, since README
# calls z5 "everything above hr_z4_max". `hr_zone_key` is called only with 1..4.
# user_settable: the split that lets the listing say which rows are YOURS. Every
# clause pinned, because the mutant dropping the zone clause marked the four
# lines README tells a new user to type as "stride's own bookkeeping".
expect Config.user_settable("timezone") == True
expect Config.user_settable("utc_offset_minutes") == True
expect Config.user_settable("hr_z1_max") == True
expect Config.user_settable("hr_z4_max") == True
expect Config.user_settable("hr_z2_max_ride") == True
# ...and stride's own bookkeeping is NOT yours, which is the whole point of the split
expect Config.user_settable("last_sync_epoch") == False
expect Config.user_settable("strava_access_token") == False
expect Config.user_settable("strava_client_id") == False
expect Config.user_settable("strava_reads_day") == False
# ...nor is a derived key, nor a typo — both have their own status
expect Config.user_settable("ftp_ride") == False
expect Config.user_settable("timezon") == False
expect Config.user_settable("hr_z5_max") == False
expect Config.user_settable("") == False

expect Config.known_key("hr_z5_max") == False
expect Config.known_key("hr_z6_max") == False
expect Config.known_key("hr_z7_max") == False
expect Config.known_key("hr_z8_max") == False
expect Config.known_key("hr_z5_max_ride") == False

# the refusal message and the predicate cannot drift: every literal `known_key` accepts is
# named in the summary the message prints. Without this the two are two lists, and the
# first cut proved what that costs — a message naming four keys for a predicate accepting
# twelve, contradicting the listing shipped beside it.
expect Str.contains(Config.known_key_summary, "timezone")
expect Str.contains(Config.known_key_summary, "utc_offset_minutes")
expect Str.contains(Config.known_key_summary, "last_sync_epoch")
expect Str.contains(Config.known_key_summary, "strava_client_id")
expect Str.contains(Config.known_key_summary, "strava_expires_at")
expect Str.contains(Config.known_key_summary, "strava_reads_today")
expect Str.contains(Config.known_key_summary, "strava_reads_day")
expect Str.contains(Config.known_key_summary, "strava_access_token")
expect Str.contains(Config.known_key_summary, "strava_refresh_token")
expect Str.contains(Config.known_key_summary, "strava_client_secret")
expect Str.contains(Config.known_key_summary, "hr_z1_max")
expect Str.contains(Config.known_key_summary, "hr_z4_max")
expect Str.contains(Config.known_key_summary, "hr_z2_max_ride")

# ...and everything the loose first cut (`starts_with("hr_z") and contains("_max")`) let
# through while claiming to be the same shape as ReportHealth's `hr_z[1-4]_max_?*`. Each
# of these answered "(not set)" on a shipped binary; none is producible by any read site.
expect Config.known_key("hr_z9_max") == False
expect Config.known_key("hr_z0_max") == False
expect Config.known_key("hr_zz_max") == False
expect Config.known_key("hr_z1_maximum") == False
expect Config.known_key("hr_z1_maxx") == False
expect Config.known_key("hr_z1_max_") == False
expect Config.known_key("xhr_z1_max") == False
expect Config.known_key("hr_z") == False
expect Config.known_key("hr_z1") == False
expect Config.known_key("power_max") == False

# ...and the point of the whole thing: a typo of a real key is not recognised. Each of
# these is one edit away from a key that is.
expect Config.known_key("timezon") == False
expect Config.known_key("time_zone") == False
expect Config.known_key("utc_offset") == False
expect Config.known_key("") == False
expect Config.known_key("nope") == False
# not a prefix match: a real key with anything appended is a different key
expect Config.known_key("timezone_x") == False

expect Config.is_secret("strava_access_token") == True
expect Config.is_secret("strava_refresh_token") == True
expect Config.is_secret("strava_client_secret") == True
expect Config.is_secret("ftp") == False
expect Config.is_secret("timezone") == False
expect Config.is_secret("") == False

# fail-closed suffix rule: a future secret key is caught even if not in the list
expect Config.is_secret("strava_webhook_secret") == True

# derived keys: every ftp_<sport> is refused, including sports that do not exist yet —
# the engine derives per sport from data, so there is no list to keep current
expect Config.is_derived("ftp_ride") == True
expect Config.is_derived("ftp_rowing") == True
expect Config.is_derived("ftp_kitesurfing") == True
expect Config.is_derived("ftp") == True

# ...and nothing else is. HR zones, the time anchor and the credentials stay configurable
expect Config.is_derived("hr_z1_max") == False
expect Config.is_derived("timezone") == False
expect Config.is_derived("utc_offset_minutes") == False
expect Config.is_derived("strava_client_id") == False
expect Config.is_derived("") == False
expect Config.is_secret("some_api_token") == True
# ...but public / neutral keys are NOT swept in
expect Config.is_secret("strava_client_id") == False
expect Config.is_secret("strava_expires_at") == False
expect Config.is_secret("ftp_ride") == False

# api-base allow-list: EXACT hosts only — real Strava (https) or loopback (http, e2e mock)
expect Config.api_base_allowed("https://www.strava.com") == True
expect Config.api_base_allowed("http://127.0.0.1:8799") == True
expect Config.api_base_allowed("http://localhost:8799") == True
expect Config.api_base_allowed("http://localhost/mock") == True
# cleartext to a non-loopback host is the exfil vector — rejected
expect Config.api_base_allowed("http://attacker.tld") == False
expect Config.api_base_allowed("ftp://x") == False
expect Config.api_base_allowed("") == False
# the subdomain trick: a host that merely STARTS WITH an allowed host is rejected
expect Config.api_base_allowed("http://localhost.attacker.tld") == False
expect Config.api_base_allowed("http://127.0.0.1.attacker.tld") == False
expect Config.api_base_allowed("https://www.strava.com.attacker.tld") == False
# TLS to an arbitrary host no longer passes — secrets would still reach the endpoint
expect Config.api_base_allowed("https://evil.example") == False
# the userinfo bypass: `host:port@realhost` — a URL parser resolves the host to realhost
expect Config.api_base_allowed("http://localhost:8799@attacker.tld") == False
expect Config.api_base_allowed("http://127.0.0.1:8799@attacker.tld") == False
# a non-numeric or empty "port" is rejected (only a real numeric port is a port)
expect Config.api_base_allowed("http://localhost:@attacker.tld") == False
expect Config.api_base_allowed("http://localhost:8x") == False
# a numeric port, optionally with a path, is still allowed
expect Config.api_base_allowed("http://localhost:8799/mock/v3") == True
expect Config.api_base_allowed("https://www.strava.com:443") == True
