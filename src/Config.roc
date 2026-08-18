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
		if k == "utc_offset_minutes" or k == "last_sync_epoch" or Str.ends_with(k, "_expires_at")
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

# numeric_key: every clause pinned, and mutation-checked one at a time. A `_max` suffix
# clause used to sit beside `hr_z` and was deleted rather than pinned: every key that ends
# `_max` also starts `hr_z` (Metrics.hr_zone_key / hr_zone_key_global), so it was
# unreachable, and an unreachable clause cannot be killed by any mutant. A rule no test
# can falsify is not a guard, it is decoration. Three of the five survived mutation when this rule
# shipped with only e2e coverage -- and the commit message claimed the e2e checks pinned
# it, which is the over-claim this file's own convention (pure rules, pure expects)
# exists to prevent.
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
