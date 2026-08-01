## Credential config keys. These live in the db so sync can auto-refresh tokens,
## but they must NEVER be surfaced back through `config get` or any JSON payload —
## reading them through the query interface would defeat storing them at all. This
## list is the single source of truth for that rule (pure + tested here, so a new
## secret can't be added in one place and forgotten in the redaction check).
Config :: [].{

	secret_keys : List(Str)
	secret_keys = ["strava_access_token", "strava_refresh_token", "strava_client_secret"]

	is_secret : Str -> Bool
	is_secret = |k| List.contains(secret_keys, k)

	expect is_secret("strava_access_token") == True
	expect is_secret("strava_refresh_token") == True
	expect is_secret("strava_client_secret") == True
	expect is_secret("ftp") == False
	expect is_secret("timezone") == False
	expect is_secret("") == False
}
