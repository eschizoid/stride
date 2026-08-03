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

	# b is exactly `hp` (scheme+host), or `hp` followed by a ':' port or '/' path —
	# never `hp` as a prefix of a longer hostname, so localhost.evil.tld is rejected.
	host_ok : Str, Str -> Bool
	host_ok = |b, hp|
		b == hp
		or Str.starts_with(b, "${hp}:")
		or Str.starts_with(b, "${hp}/")

}

expect Config.is_secret("strava_access_token") == True
expect Config.is_secret("strava_refresh_token") == True
expect Config.is_secret("strava_client_secret") == True
expect Config.is_secret("ftp") == False
expect Config.is_secret("timezone") == False
expect Config.is_secret("") == False

# fail-closed suffix rule: a future secret key is caught even if not in the list
expect Config.is_secret("strava_webhook_secret") == True
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
