import Db
import Output
import pf.Http
import Sql
import pf.Stdout
import pf.Stdin
import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Sleep
import pf.Signal
import http.Request
import http.Method
import http.Response
import Streams
import core.Route
import Drain
import Metrics
import Config
import Render

Strava :: [].{
	# ── strava oauth ─────────────────────────────────────────────────────

	TokenResp : { access_token : Str, refresh_token : Str, expires_at : I64 }

	# API base override (STRIDE_API_BASE) — lets the e2e point stride at a local
	# mock Strava; humans never set it. The browser authorize URL stays real always.
	api_base! : {} => Str
	api_base! = |{}|
		match Env.var_str!(OsStr.from_str("STRIDE_API_BASE")) {
			# only honor an allowed override (exact hosts only — real Strava, or
			# http to loopback) — a disallowed
			# base can't exfiltrate the client_secret/refresh token; fall back to real Strava
			Ok(b) if !(Str.is_empty(b)) and Config.api_base_allowed(b) => b
			_ => "https://www.strava.com"

		}
	token_url! : {} => Str
	token_url! = |{}| "${api_base!({})}/oauth/token"

	# best-effort browser launch: macOS `open`, then Linux `xdg-open`. Silent on
	# failure — the URL is always printed as the manual fallback. capture! so a
	# failing launcher can't spew stderr into the auth instructions or hand the TTY
	# to a console browser on a headless box.
	# ...and NOT when the token endpoint is a loopback mock: `STRIDE_API_BASE` is
	# the e2e seam, and the authorize URL staying real is what made `just test` open
	# seven strava.com tabs on a dev machine.
	#
	# A PREFIX test is safe HERE ONLY because it reads `api_base!({})`, which has
	# already applied the allow-list (`Config.api_base_allowed` exists precisely
	# because `http://localhost:8799@attacker.tld` starts with `http://localhost:`).
	# Do NOT hoist these calls into a direct `Env.var_str!` as a tidy-up — that is
	# exactly what makes the bypass live.
	open_browser! : Str => {}
	open_browser! = |url|
		if Str.starts_with(api_base!({}), "http://127.0.0.1") or Str.starts_with(api_base!({}), "http://localhost") {
			{}
		} else
			match Cmd.new(OsStr.from_str("open")).arg(OsStr.from_str(url)).capture!() {
				Ok(_) => {}
				Err(_) =>
				# detach xdg-open: exec waits for the child, and xdg-open can resolve to
				# a FOREGROUND handler (console browser) that would block auth forever
					match Cmd.new(OsStr.from_str("sh")).args(List.map(["-c", "xdg-open \"$1\" >/dev/null 2>&1 &", "sh", url], OsStr.from_str)).capture!() {
						Ok(_) => {}
						Err(_) => {}
					}
			}
	# a stored token field: absent => NotAuthed (genuine); db failure propagates
	token_field! : Str, Str => Try(Str, _)
	token_field! = |path, key|
		match Db.config_opt!(path, key)? {
			Found(v) => Ok(v)
			NotFound => Err(NotAuthed)

		}
	# client credentials: env var wins, else stored config (written by `auth`)
	client_cred! : Str, Str, Str => Try(Str, _)
	client_cred! = |path, env_name, key|
		match Env.var_str!(OsStr.from_str(env_name)) {
			Ok(v) => Ok(v)
			Err(_) =>
			# Db.config_opt! so a locked/corrupt db surfaces as a real error, not MissingEnv
				match Db.config_opt!(path, key)? {
					Found(v) => Ok(v)
					NotFound => Err(MissingEnv(env_name))

				}
		}
	auth! : {} => Try({}, _)
	auth! = |{}| {
		path = Db.open_db!({})?
		# env vars for first-time setup; re-auth falls back to the creds stored last time.
		# Genuinely-missing creds get setup guidance, not a raw MissingEnv crash.
		match (client_cred!(path, "STRAVA_CLIENT_ID", "strava_client_id"), client_cred!(path, "STRAVA_CLIENT_SECRET", "strava_client_secret")) {
			(Ok(client_id), Ok(client_secret)) => auth_flow!(path, client_id, client_secret)
			(Err(MissingEnv(name)), _) | (_, Err(MissingEnv(name))) =>
				Output.missing_client_creds!(name)

			(Err(other), _) | (_, Err(other)) => Err(other)

		}
	}
	auth_flow! : Str, Str, Str => Try({}, _)
	auth_flow! = |path, client_id, client_secret| {
		url = authorize_url(client_id, "http://localhost")
		# Output.human_line!, not Stdout.line!: stdout carries the envelope in JSON mode
		# and this prose is not it. The prompt below matters most, since it has no trailing
		# newline and would put the envelope on its line.
		Output.human_line!("1) Click Authorize in the browser tab that just opened (URL below if it didn't):")?
		Output.human_line!("")?
		Output.human_line!("   ${url}")?
		Output.human_line!("")?
		open_browser!(url)
		Output.human_line!("2) You'll land on a localhost page that fails to load — that's expected.")?
		Output.human_line!("   Copy the whole address from the address bar (or just its code=XXXX value) and paste it here.")?
		Output.human_line!("")?
		Output.human_write!("code: ")?
		code_raw = Stdin.line!()?
		# the bare code or the whole redirected URL; a paste with no code is sent
		# as typed, and Strava's refusal names what was wrong with it
		code = (Config.oauth_code(code_raw)).ok_or(Str.trim(code_raw))
		tokens = exchange_code!(path, client_id, client_secret, code)?
		# The success line goes through Output so `--json` stays parseable: auth's
		# command-table entry publishes machine-readable error codes. It reports
		# `expires_at`, the one fact a caller can act on; tokens never appear (the
		# same rule as `config get`).
		Output.out!({ authorized: 1 == 1, expires_at: tokens.expires_at }, |_| "authorized — tokens stored. Run `stride sync` to pull your activities.")
	}
	# the browser page that asks the athlete to authorize this client; Strava
	# sends the code to `redirect`, whose host must be the API app's callback
	# domain (localhost or 127.0.0.1 match one registered as localhost)
	authorize_url : Str, Str -> Str
	authorize_url = |client_id, redirect| "https://www.strava.com/oauth/authorize?client_id=${client_id}&response_type=code&redirect_uri=${redirect}&approval_prompt=auto&scope=read,activity:read_all"

	# the same page with an OAuth `state` that Strava echoes back on the redirect,
	# so a listener can refuse a callback this run did not start
	authorize_url_state : Str, Str, Str -> Str
	authorize_url_state = |client_id, redirect, state| "${authorize_url(client_id, redirect)}&state=${state}"

	# Trade an authorization code for tokens and store them with the client
	# credentials that earned them, so sync never needs the environment again.
	exchange_code! : Str, Str, Str, Str => Try(TokenResp, _)
	exchange_code! = |path, client_id, client_secret, code| {
		form = "client_id=${client_id}&client_secret=${client_secret}&code=${code}&grant_type=authorization_code"
		body = post_form!(token_url!({}), form)?
		tokens = decode_tokens(body)?
		save_tokens!(path, tokens)?
		Db.config_set!(path, "strava_client_id", client_id)?
		Db.config_set!(path, "strava_client_secret", client_secret)?
		Ok(tokens)
	}
	decode_tokens : List(U8) -> Try(TokenResp, _)
	decode_tokens = |body| {
		text = Str.from_utf8(body).map_err(|_| TokenDecodeFailed)?
		decoded : Try(TokenResp, _)
		decoded = Json.parse(text)
		decoded.map_err(|_| TokenDecodeFailed)
	}
	save_tokens! : Str, TokenResp => Try({}, _)
	save_tokens! = |path, tokens|
		# ONE atomic multi-row upsert: Strava rotates the refresh token on every refresh,
		# so three separate writes risked a crash leaving new-access + a DEAD refresh
		# token — auth bricked until a manual re-`auth`.
		# Bind the strings directly: wrapping them in "${...}" to force a copy only turns
		# every binding into a heap Str and fixes nothing.
		Sql.execute!({
			path: Path.utf8(path),
			query: \\INSERT OR REPLACE INTO config (key, value) VALUES
				\\  ('strava_access_token', :at), ('strava_refresh_token', :rt), ('strava_expires_at', :exp)
			,
			bindings: [
				{ name: ":at", value: String(tokens.access_token) },
				{ name: ":rt", value: String(tokens.refresh_token) },
				{ name: ":exp", value: String(I64.to_str(tokens.expires_at)) },
			],
		})
	# returns a valid access token, refreshing if expired; NotAuthed if never
	# authorized (a genuinely absent token — NOT a db read failure, which propagates)
	get_valid_token! = |path| {
		access = token_field!(path, "strava_access_token")?
		refresh = token_field!(path, "strava_refresh_token")?
		expires_str = token_field!(path, "strava_expires_at")?
		# UnreadableConfig, not CorruptToken: that tag was raised here and handled
		# nowhere, so a value the user can set with `config set` surfaced as
		# internal_error -- "please open an issue" for their own typo (#208).
		expires_at = (Metrics.arg_i64(expires_str)).map_err(|_| UnreadableConfig("strava_expires_at", expires_str))?
		now = Db.now_secs!({})
		if (now < (expires_at - 60))
			Ok(access)
		else {
			client_id = client_cred!(path, "STRAVA_CLIENT_ID", "strava_client_id")?
			client_secret = client_cred!(path, "STRAVA_CLIENT_SECRET", "strava_client_secret")?
			form = "client_id=${client_id}&client_secret=${client_secret}&grant_type=refresh_token&refresh_token=${refresh}"
			body = post_form!(token_url!({}), form)?
			tokens = decode_tokens(body)?
			save_tokens!(path, tokens)?
			Ok(tokens.access_token)
		}
	}
	# ── http helpers ─────────────────────────────────────────────────────

	post_form! : Str, Str => Try(List(U8), _)
	post_form! = |uri, form| {
		resp = Http.send!(
			Request.from_method(Method.POST)
				.with_uri(uri)
				.add_header("Content-Type", "application/x-www-form-urlencoded")
				.with_body(form.to_utf8())
				.with_timeout(TimeoutMilliseconds(30000)),
			{},
		)?
		ok_body(resp)
	}

	ok_body : Response -> Try(List(U8), _)
	ok_body = |resp|
		if (Response.status(resp) < 300)
			Ok(Response.body(resp))
		else {
			text = (Str.from_utf8(Response.body(resp))).ok_or("<non-utf8 body>")
			Err(HttpStatus(Response.status(resp), text))
		}
	# ── sync ─────────────────────────────────────────────────────────────

	ActivitySummary : {
		id : I64,
		name : Str,
		sport_type : Str,
		start_date_local : Str,
		moving_time : I64,
		distance : F64,
		total_elevation_gain : F64,
		# optional in Strava JSON — missing on activities without power/HR
		suffer_score : Try(F64, [Missing]),
		average_watts : Try(F64, [Missing]),
		# Strava sets this FALSE when watts are estimated (no meter). Estimated watts are
		# not measurements and must not outrank honest fallbacks (#73).
		device_watts : Try(Bool, [Missing]),
		average_heartrate : Try(F64, [Missing]),
		weighted_average_watts : Try(F64, [Missing]),
		# the session's highest heart rate, from which setup proposes zones
		max_heartrate : Try(F64, [Missing]),
	}

	opt_real : Try(F64, [Missing]) -> [Real(F64), Null]
	opt_real = |o|
		match o {
			Ok(v) => Real(v)
			Err(_) => Null

		}
	# What one sync run did, the `sync` payload. ANNOTATED and closed: the human
	# screen is a pure function over this record, and without the annotation a new
	# key would compile clean and ship undeclared in schemas/v3/sync.json (ADR 0000
	# s9c). `synced` is rows re-listed; `resumable` is whether anything is still
	# owed, re-measured from the database; `resume_at` is when a caller can
	# continue (ISO-8601 UTC, "" when nothing is owed or nothing waits on a time);
	# `analyzed` is whether analyze reached its fixed point after the last batch.
	SyncPayload : { synced : U64, new_activities : U64, updated_activities : U64, pruned : U64, streams_fetched : I64, streams_skipped : I64, pending_streams : I64, notes_fetched : I64, notes_skipped : I64, pending_notes : I64, routes_fetched : I64, routes_skipped : I64, pending_routes : I64, stopped : Str, resumable : Bool, resume_at : Str, analyzed : Bool, computed : U64 }

	# what analyze reported after the last batch, as Analyze.settle! returns it
	Settled : { analysis : [Settled, NoZones, Unsettled], computed : U64, verdict : Str }

	# a run's result: the payload, the tag it was built from (bound once, so the
	# payload's string and the screen's tag describe the same run), the epoch
	# second it can continue at (0 for none), and analyze's report
	SyncResult : { payload : SyncPayload, stop : Drain.SyncStop, resume_epoch : I64, settled : Settled }

	# what the drains stored and skipped, summed over a run's rounds
	Tally : { streams : I64, streams_skipped : I64, notes : I64, notes_skipped : I64, routes : I64, routes_skipped : I64 }

	no_tally : Tally
	no_tally = { streams: 0, streams_skipped: 0, notes: 0, notes_skipped: 0, routes: 0, routes_skipped: 0 }

	ListCounts : { relisted : U64, new_n : U64, updated_n : U64 }

	# `all` forces a full re-list: the watermark is ignored, every activity is re-listed
	# and the prune is unbounded, so a deletion in old history propagates. That is the one
	# thing an incremental run can never see, and the only reason the flag exists — mostly
	# a dev-mode start-from-scratch (#232).
	#
	# `settle!` is analyze as sync runs it (Analyze.settle!), passed in because
	# analyze sits a layer above this module.
	sync! : Bool, (Str => Try(Settled, _)) => Try({}, _)
	sync! = |all, settle!| {
		path = Db.open_db!({})?
		match get_valid_token!(path) {
			Err(NotAuthed) =>
				Output.err_out!("not_authenticated", "not authenticated — run `stride auth` first")

			Err(other) => Err(other)
			Ok(token) => {
				waits = !(Output.json_mode!({}))
				r = interruptible!(waits, |{}| sync_run!(path, token, all, settle!, waits))?
				note = sync_note!(path, r)
				Output.out!(r.payload, |p| Render.sync_screen(p, r.stop, note))
			}
		}
	}

	# A human run waits for Strava's next read window, so Ctrl-C has to stop it
	# cleanly: catching the interrupt makes the sleep and any request in flight
	# return Interrupted, and every fetch before it is already stored, so the
	# next run resumes from there. A caught interrupt keeps every blocking effect
	# returning Interrupted until it is acknowledged, so it is polled before the
	# closing line is written. 130 is the status a shell gives an interrupted
	# command.
	interruptible! : Bool, ({} => Try(a, _)) => Try(a, _)
	interruptible! = |waits, run!| {
		_ = if waits {
			match Signal.catch!([Interrupt]) {
				Ok(_) => {}
				Err(_) => {}
			}
		} else {
			{}
		}
		match run!({}) {
			Err(Interrupted) => {
				_ = Signal.poll!()
				_ = Output.narrate_done!({})
				_ = Output.say!("sync stopped — every fetch so far is stored, and the next `stride sync` resumes from there")
				Err(Exit(130))
			}
			other => other
		}
	}

	# the screen's note: the local time the run continues, and how analyze ended
	sync_note! : Str, SyncResult => Render.SyncNote
	sync_note! = |path, r| {
		resume = if (r.resume_epoch == 0) "" else Render.local_time(r.resume_epoch, Db.time_mode_offset(Db.resolve_time_mode!(path)), Db.now_secs!({}))
		{ resume, analysis: r.settled.analysis, verdict: r.settled.verdict }
	}

	# One sync, to its end. The list first: every page of the activity list before any
	# stream, so a first sync's summaries are listed and scored in its first window.
	# Then rounds of streams, descriptions and routes, one read window each, with
	# analyze run after each round. A human run (`waits`) waits for the next window
	# between rounds; a `--json` run does one round and names the time the next window
	# opens.
	sync_run! : Str, Str, Bool, (Str => Try(Settled, _)), Bool => Try(SyncResult, _)
	sync_run! = |path, token, all, settle!, waits|
		match list_phase!(path, token, all, waits)? {
			# a run that STARTS with the day's allowance spent made no request, so it
			# is resumable regardless of the queue: it has not looked
			DaySpent => {
				settled = settle!(path)?
				finish!(path, { stop: FromDrain(DailyCapReached), counts: { relisted: 0, new_n: 0, updated_n: 0 }, pruned: 0, tally: no_tally, settled, owed_anyway: True })
			}
			# what is owed after a refused list is the LISTING, so the run is resumable
			# whatever the queue says
			Refused(r) => {
				settled = settle!(path)?
				finish!(path, { stop: r.stop, counts: r.counts, pruned: 0, tally: no_tally, settled, owed_anyway: True })
			}
			Listed(l) => {
				owed = pending_streams!(path)? + pending_notes!(path)? + pending_routes!(path)?
				_ = if Drain.score_first(owed, (read_limits!({})).reads_per_window - l.window0) {
					_ = settle!(path)?
					{}
				} else {
					{}
				}
				done = rounds!(path, token, all, settle!, waits, { window: l.window0, after_wait: False, tally: no_tally })?
				finish!(path, { stop: FromDrain(done.stop), counts: l.counts, pruned: l.pruned, tally: done.tally, settled: done.settled, owed_anyway: False })
			}
		}

	# The activity list, the first step of every sync and setup's `activities` step:
	# every page, then the prune of what Strava no longer lists and the watermark.
	# `window0` is the reads the list spent in the window the drain starts in.
	ListPhase : [DaySpent, Refused({ counts : ListCounts, stop : Drain.SyncStop }), Listed({ counts : ListCounts, pruned : U64, window0 : I64 })]

	list_phase! : Str, Str, Bool, Bool => Try(ListPhase, _)
	list_phase! = |path, token, all, waits| {
		started = Db.now_secs!({})
		# Incremental with a rolling 30-day overlap so recent edits on Strava
		# self-heal. `--all` is the full re-pull when one is wanted.
		#
		# THREE outcomes, not two. Absent means never synced and a full pull is
		# right. A db read error propagates rather than silently burning the rate
		# budget. Collapsing Unreadable into the first would make a bad value
		# force a full re-pull every run, conservative and therefore invisible.
		# arg_i64 rather than I64.from_str, so the shape accepted here matches
		# what `config set` enforces.
		after_epoch =
			if all {
				# --all: behave exactly as a never-synced install does, so the full-pull
				# case stays the one exercised on every fresh install
				None
			} else
				match Db.config_opt!(path, "last_sync_epoch")? {
					NotFound => None
					Found(epoch_str) =>
						match Metrics.arg_i64(epoch_str) {
							Ok(e) => Some((e - 2592000).max(0))
							Err(_) => return Err(UnreadableConfig("last_sync_epoch", epoch_str))
						}
				}
		after_param =
			match after_epoch {
				Some(a) => "&after=${I64.to_str(a)}"
				None => ""
			}
		# window_start bounds the prune to rows solidly inside the window Strava
		# re-listed this run: the `after` epoch PLUS a one-day margin, rendered by
		# epoch_to_iso as UTC and compared lexically to activities.start_local
		# (Strava's LOCAL start_date_local). A full day exceeds any timezone offset,
		# so an activity merely just outside Strava's `after` window — still present
		# upstream, only older — is never pruned as a deletion. A deletion in that
		# one-day sliver is caught by the next `sync --all`, which prunes all unseen
		# ("" window_start). NULL synced_at rows (imports) are exempt regardless.
		window_start =
			match after_epoch {
				Some(a) => Metrics.epoch_to_iso(a + 86400)
				None => ""
			}
		# BEFORE the first request: a run that STARTS with the day's allowance spent has
		# nothing it can do and costs nothing to find out
		if day_spent!(path)? {
			Ok(DaySpent)
		} else {
			listed = list_all!(path, token, after_param, started, waits, { relisted: 0, new_n: 0, updated_n: 0, rate_limited: False, page: 1, reads: 0, usage: Unreported }, False)?
			counts = { relisted: listed.relisted, new_n: listed.new_n, updated_n: listed.updated_n }
			match listed.stop {
				# A refused list stops the run HERE, before pruning and before the drain
				# (#235). PRUNE removes what the listing did not re-list, so running it on a
				# partial list would delete activities that exist and were simply not
				# reached; the watermark must not advance past activities the run never
				# saw; and the drain would spend a refused budget. The pages already
				# upserted are kept and reported.
				Refused(stop) => Ok(Refused({ counts, stop }))
				Listed => {
					pruned = prune_deleted!(path, started, window_start)?
					Db.config_set!(path, "last_sync_epoch", I64.to_str(started))?
					Ok(Listed({ counts, pruned, window0: (Drain.floor_counts({ window: listed.reads, today: 0 }, listed.usage)).window }))
				}
			}
		}
	}

	# The payload, with every queue re-measured from the database: a hardcoded 0 is a
	# way to silently zero an absence.
	finish! : Str, { stop : Drain.SyncStop, counts : ListCounts, pruned : U64, tally : Tally, settled : Settled, owed_anyway : Bool } => Try(SyncResult, _)
	finish! = |path, f| {
		ps = pending_streams!(path)?
		pn = pending_notes!(path)?
		pr = pending_routes!(path)?
		resumable : Bool
		resumable = f.owed_anyway or ps > 0 or pn > 0 or pr > 0
		resume_epoch = Drain.resume_epoch(f.stop, resumable, Db.now_secs!({}), window_secs!({}))
		analyzed : Bool
		analyzed = f.settled.analysis == Settled
		payload : SyncPayload
		payload = {
			synced: f.counts.relisted,
			new_activities: f.counts.new_n,
			updated_activities: f.counts.updated_n,
			pruned: f.pruned,
			streams_fetched: f.tally.streams,
			streams_skipped: f.tally.streams_skipped,
			pending_streams: ps,
			notes_fetched: f.tally.notes,
			notes_skipped: f.tally.notes_skipped,
			pending_notes: pn,
			routes_fetched: f.tally.routes,
			routes_skipped: f.tally.routes_skipped,
			pending_routes: pr,
			stopped: Drain.sync_stopped_label(f.stop),
			resumable,
			resume_at: if (resume_epoch == 0) "" else Metrics.epoch_to_iso(resume_epoch),
			analyzed,
			computed: f.settled.computed,
		}
		Ok({ payload, stop: f.stop, resume_epoch, settled: f.settled })
	}

	# One read window's worth of fetches, then analyze, then either the next window
	# (a human run) or the end. Descriptions drain only after a COMPLETE streams
	# drain, and routes after complete descriptions: all three draw on one read
	# window, and a drain that stopped on it would spend its refusal a second time.
	# The run's stop is whichever drain stopped it: a drain that never ran inherits
	# the stop of the one before it.
	rounds! : Str, Str, Bool, (Str => Try(Settled, _)), Bool, { window : I64, after_wait : Bool, tally : Tally } => Try({ stop : Drain.StopReason, tally : Tally, settled : Settled }, _)
	rounds! = |path, token, all, settle!, waits, r| {
		t = r.tally
		pull = drain_missing!(path, token, Streams, all, r.window, (t.streams + t.streams_skipped).to_u64_wrap())?
		notes =
			match pull.stopped {
				Complete => drain_missing!(path, token, Notes, all, pull.window, (t.notes + t.notes_skipped).to_u64_wrap())?
				_ => { stored: 0, skipped: 0, stopped: pull.stopped, window: pull.window }
			}
		routes =
			match notes.stopped {
				Complete => drain_missing!(path, token, Routes, all, notes.window, (t.routes + t.routes_skipped).to_u64_wrap())?
				_ => { stored: 0, skipped: 0, stopped: notes.stopped, window: notes.window }
			}
		tally = {
			streams: t.streams + pull.stored,
			streams_skipped: t.streams_skipped + pull.skipped,
			notes: t.notes + notes.stored,
			notes_skipped: t.notes_skipped + notes.skipped,
			routes: t.routes + routes.stored,
			routes_skipped: t.routes_skipped + routes.skipped,
		}
		settled = settle!(path)?
		progressed = pull.stored + pull.skipped + notes.stored + notes.skipped + routes.stored + routes.skipped > 0
		owed = pending_streams!(path)? + pending_notes!(path)? + pending_routes!(path)? > 0
		match Drain.after_round({ stop: FromDrain(routes.stopped), owed, progressed, after_wait: r.after_wait, waits }) {
			Finish => Ok({ stop: routes.stopped, tally, settled })
			Wait => {
				wait_for_window!(path)?
				rounds!(path, token, all, settle!, waits, { window: 0, after_wait: True, tally })
			}
		}
	}

	# Wait for the next read window: a spinner beside the local time the next batch
	# starts and the time left, redrawn about once a second, replaced by its result
	# when the window opens.
	wait_for_window! : Str => Try({}, _)
	wait_for_window! = |path| {
		now = Db.now_secs!({})
		until = Drain.next_window_at(now, window_secs!({}))
		at = Render.local_time(until, Db.time_mode_offset(Db.resolve_time_mode!(path)), now)
		wait_ticks!(until, at, 0)?
		Output.step_done!("waiting for Strava", "next batch started at ${at}")
	}

	wait_ticks! : I64, Str, U64 => Try({}, _)
	wait_ticks! = |until, at, tick| {
		left_ms = until * 1000 - Db.now_millis!({})
		if left_ms <= 0 {
			Ok({})
		} else {
			Output.wait_frame!({ tick, at, left: (left_ms + 999) // 1000 })?
			Sleep.millis!((left_ms.min(1000)).to_u64_wrap())?
			wait_ticks!(until, at, tick + 1)
		}
	}

	# The whole activity list, behind a spinner that turns once per page. A human
	# run refused by the window waits for the next one and asks for the refused page
	# again; the pages already listed are kept, so nothing is listed twice.
	list_all! : Str, Str, Str, I64, Bool, PageAcc, Bool => Try({ relisted : U64, new_n : U64, updated_n : U64, reads : I64, usage : Drain.Usage, stop : [Listed, Refused(Drain.SyncStop)] }, _)
	list_all! = |path, token, after_param, stamp, waits, acc, after_wait| {
		got = fetch_pages!(path, token, after_param, stamp, acc)?
		result = Render.list_result({ checked: got.relisted, new: got.new_n, updated: got.updated_n })
		out = |stop| { relisted: got.relisted, new_n: got.new_n, updated_n: got.updated_n, reads: got.reads, usage: got.usage, stop }
		if !(got.rate_limited) {
			Output.step_done!("activity list", result)?
			Ok(out(Listed))
		} else {
			# WHICH limit refused the list: the day's allowance spent means its
			# remedy is midnight UTC, and its own tag says both facts at once
			stop = if (day_spent!(path)?) ListDailyCapReached else ListRateLimited
			Output.step_done!("activity list", "${result} so far, refused by Strava")?
			match Drain.after_round({ stop, owed: True, progressed: got.relisted > acc.relisted, after_wait, waits }) {
				Finish => Ok(out(Refused(stop)))
				Wait => {
					wait_for_window!(path)?
					list_all!(path, token, after_param, stamp, waits, { ..got, rate_limited: False, reads: 0, usage: Unreported }, True)
				}
			}
		}
	}

	# close the bar before anything else prints, or the line lands on the bar's row.
	# Swallows its own failure, same policy as the boundary reporter: a failed stderr
	# write must not convert a successful arm into an error envelope.
	bar_done! : DrainState => {}
	bar_done! = |st|
		if st.opened {
			match Output.narrate_done!({}) {
				Ok(_) => {}
				Err(_) => {}
			}
		} else {
			{}
		}

	# ONE stream loop for the whole engine (#232). Separate loops drift, and every
	# rate-limit inconsistency lives in that drift. No per-run cap: one drain walks
	# its queue until the read window fills, and sync! decides whether the run waits
	# for the next window or ends there.
	#
	# fetch time/HR/watts/altitude/distance streams for the activities
	# stream_queue_where selects; pacing bounds the run (see read_limits!). altitude
	# + distance are requested EXPLICITLY — they feed grade-adjusted pace / NGP (ADR
	# 0003). To force a re-pull, DELETE FROM streams (mirror tier) and let the next
	# sync refetch.
	#
	# `base` is how many of this kind earlier rounds of the run already retired, so
	# the bar counts the whole run rather than restarting each window.
	drain_missing! : Str, Str, DrainKind, Bool, I64, U64 => Try(DrainOutcome, _)
	drain_missing! = |path, token, kind, all, window0, base| {
		ids =
			match kind {
				# Fewest failed fetches first, then newest first. The queue is walked
				# in this order and the read budget can end the run anywhere in it, so
				# an id whose body keeps failing to decode sits behind every id that
				# has not failed, and a window's worth of them cannot spend every
				# run's budget. `all` lifts the attempt cap only: a stored stream that
				# decodes is never re-read, because the ride happened once.
				Streams =>
					Sql.query_many!({
						path: Path.utf8(path),
						query: \\SELECT a.id AS id FROM activities a
							\\LEFT JOIN streams s ON s.activity_id = a.id
							\\LEFT JOIN stream_retries r ON r.activity_id = a.id
							\\${stream_queue_where}
							\\ORDER BY COALESCE(r.attempts, 0), ${Metrics.rank_ts_sql("a.start_local", Desc)}
						,
						bindings: [
							{ name: ":all", value: Integer(if (all) 1 else 0) },
							{ name: ":cap", value: Integer(stream_attempt_cap) },
						],
						rows: Sql.i64("id"),
					})?
				Notes =>
				# WIDER than pending_notes! on purpose, where the Streams queue
				# mirrors its pending count on a plain sync. A description is written
				# AFTER the activity — the athlete finishes, syncs, and pastes
				# the breakdown that evening — and can be edited any time, so a
				# stored copy inside the rolling window the listing re-checks is
				# re-read every run and an edit self-heals (#519). Outside the
				# window a stored row is permanent, like a stream; deleting a
				# strength_notes row stays a safe manual refresh, since the
				# authoritative copy is on Strava. `--all` drops the window
				# entirely, so an edit to a description OLDER than the window
				# is reachable from the CLI rather than only by deleting the
				# row by hand. The re-reads are maintenance
				# this run performs, not work the next run is owed, which is
				# why pending_notes! counts only never-asked rows. The extra
				# day on the window absorbs the UTC-vs-local skew in
				# start_local, the same margin the prune takes — and the
				# comparison itself adds a second slack in the same safe
				# direction: start_local's 'T' separator sorts above
				# datetime()'s space, so on the boundary DATE the whole day is
				# admitted regardless of time. Over-including costs a read;
				# "tidying" this to date()-vs-date() would not be inert, it
				# would narrow the window.
				# the scope rides as a BOUND :all flag, the same pattern the
				# week query uses — never a conditionally interpolated SQL
				# fragment, which is the shape the house rule exists to keep
				# out of query strings
					Sql.query_many!({
						path: Path.utf8(path),
						query: \\SELECT a.id AS id FROM activities a
							\\LEFT JOIN strength_notes n ON n.activity_id = a.id
							\\WHERE COALESCE(a.sport_family, a.sport_type) = 'WeightTraining'
							\\  AND (:all = 1 OR n.activity_id IS NULL OR a.start_local >= datetime('now', '-31 days'))
							\\ORDER BY ${Metrics.rank_ts_sql("a.start_local", Desc)}
						,
						bindings: [{ name: ":all", value: Integer(if (all) 1 else 0) }],
						rows: Sql.i64("id"),
					})?
				# fewest failed fetches first, then newest first, the streams
				# order: the recent routes come first in a backfill, and a body
				# that keeps failing waits behind every id not yet tried. `all`
				# lifts the attempt cap only; a stored route is final.
				Routes =>
					Sql.query_many!({
						path: Path.utf8(path),
						query: \\SELECT a.id AS id FROM activities a
							\\LEFT JOIN routes g ON g.activity_id = a.id
							\\${route_queue_where}
							\\ORDER BY COALESCE(g.attempts, 0), ${Metrics.rank_ts_sql("a.start_local", Desc)}
						,
						bindings: [
							{ name: ":all", value: Integer(if (all) 1 else 0) },
							{ name: ":cap", value: Integer(stream_attempt_cap) },
						],
						rows: Sql.i64("id"),
					})?
			}
		total = base + List.len(ids)
		# an immediate frame BEFORE the first request: narrating only after a response
		# returns shows nothing for exactly as long as a stall lasts
		_ = if List.len(ids) > 0 {
			Output.narrate!(drain_label(kind), base, total)?
		} else {
			{}
		}

		# the day's read count, carried in from the database. Stored per UTC day, so a
		# stale stamp means a new day and the count starts over — that is the reset, and
		# it needs no scheduled job.
		day0 = Db.utc_today_days!({})
		today0 = reads_today!(path, day0)?
		wsecs = window_secs!({})
		match drain_queue!(path, token, kind, ids, { window: window0, widx: Drain.window_index(Db.now_secs!({}), wsecs), wsecs, day: day0, today: today0, stored: 0, skipped: 0, total, opened: List.len(ids) > 0, refreshes: 0 }) {
			Ok(o) => Ok(o)
			# an interrupt is not a failure to report: the caller says what it means
			Err(Interrupted) => Err(Interrupted)
			Err(e) => {
				# ONE place covering every propagating `?` in the drain — the token refresh
				# and the narration calls, the refresh being the realistic one on a long
				# drain. Nothing here uses `?`: this runs on the way out of a failure
				# already being reported, so a broken stderr must not replace that error.
				_ = say_partial_stored!(List.len(ids))
				Err(e)
			}
		}
	}

	drain_label : DrainKind -> Str
	drain_label = |kind|
		match kind {
			Streams => "streams"
			Notes => "descriptions"
			Routes => "routes"
		}

	# what a skip line calls the body that would not decode, so a stream and a route
	# skipped for the same activity read as two different fetches
	skip_subject : DrainKind -> Str
	skip_subject = |kind|
		match kind {
			Streams => "stream data"
			Notes => "description"
			Routes => "route data"
		}

	store_response! : Str, DrainKind, I64, Response.Response => Try([Stored, Skipped, SkippedFinal(I64)], _)
	store_response! = |path, kind, id, resp|
		match kind {
			Streams => store_stream_response!(path, id, resp)
			Notes => store_note_response!(path, id, resp)
			Routes => store_route_response!(path, id, resp)
		}

	# THE routes queue: activities that covered ground outside a virtual world
	# with no stored route, while their failed fetches are under :cap, or
	# regardless of it when :all = 1. An indoor session with a distance (a
	# rowing machine, a trainer ride) is asked once and stores the no-GPS
	# marker. Virtual* sports are left out because their coordinates belong to
	# a game map, not a street. Callers join `activities a` and `routes g` and
	# bind :all and :cap.
	route_queue_where : Str
	route_queue_where =
		\\WHERE (g.activity_id IS NULL OR (g.raw_json IS NULL AND (:all = 1 OR g.attempts < :cap)))
		\\  AND a.moving_time > 0 AND a.distance > 0
		\\  AND COALESCE(a.sport_type, '') NOT LIKE 'Virtual%'

	# the routes a plain `sync` still owes: its queue, counted
	pending_routes! : Str => Try(I64, _)
	pending_routes! = |path|
		Sql.query!({
			path: Path.utf8(path),
			query: \\SELECT COUNT(*) AS n FROM activities a
				\\LEFT JOIN routes g ON g.activity_id = a.id
				\\${route_queue_where}
			,
			bindings: [
				{ name: ":all", value: Integer(0) },
				{ name: ":cap", value: Integer(stream_attempt_cap) },
			],
			row: Sql.i64("n"),
		})

	# the capped_streams! twin for routes: activities whose route has failed
	# stream_attempt_cap fetches, which pending_routes! leaves out and only
	# `sync --all` asks for again
	capped_routes! : Str => Try(I64, _)
	capped_routes! = |path|
		Sql.query!({
			path: Path.utf8(path),
			query: \\SELECT COUNT(*) AS n FROM routes g
				\\JOIN activities a ON a.id = g.activity_id
				\\WHERE g.raw_json IS NULL AND g.attempts >= :cap
			,
			bindings: [{ name: ":cap", value: Integer(stream_attempt_cap) }],
			row: Sql.i64("n"),
		})

	# THE route-response policy, the stream policy one key over: 404 and a
	# body with no usable coordinates store the '{}' marker, since no GPS is a
	# durable fact the queue must retire; a body with coordinates is stored as
	# Strava sent it; a non-utf8 or undecodable body stores nothing and counts
	# a failed fetch, so the id is asked again until the attempt cap.
	store_route_response! : Str, I64, Response.Response => Try([Stored, Skipped, SkippedFinal(I64)], _)
	store_route_response! = |path, id, resp|
		if Response.status(resp) == 404 {
			store_route!(path, id, "{}")?
			Ok(Stored)
		} else if Response.status(resp) < 300 {
			match Str.from_utf8(Response.body(resp)) {
				Ok(text) =>
					match Route.decode_route(text) {
						Points(_) => {
							store_route!(path, id, text)?
							Ok(Stored)
						}
						NoGps => {
							store_route!(path, id, "{}")?
							Ok(Stored)
						}
						Unreadable => count_unreadable_route!(path, id)
					}
				Err(_) => count_unreadable_route!(path, id)
			}
		} else {
			text = Str.from_utf8(Response.body(resp)).ok_or("<non-utf8 body>")
			Err(HttpStatus(Response.status(resp), text))
		}

	# A route fetch returned a body stride cannot decode: count it on the
	# route's own row, leaving raw_json NULL, and say whether a plain sync
	# will ask again.
	count_unreadable_route! : Str, I64 => Try([Stored, Skipped, SkippedFinal(I64)], _)
	count_unreadable_route! = |path, id| {
		Sql.execute!({
			path: Path.utf8(path),
			query: "INSERT INTO routes (activity_id, raw_json, attempts) VALUES (:id, NULL, 1) ON CONFLICT(activity_id) DO UPDATE SET attempts = routes.attempts + 1",
			bindings: [{ name: ":id", value: Integer(id) }],
		})?
		n = Sql.query!({
			path: Path.utf8(path),
			query: "SELECT attempts AS n FROM routes WHERE activity_id = :id",
			bindings: [{ name: ":id", value: Integer(id) }],
			row: Sql.i64("n"),
		})?
		if (n < stream_attempt_cap) Ok(Skipped) else Ok(SkippedFinal(n))
	}

	# no invalidation on store: nothing scored reads a route. Storing replaces
	# the row, so a stored body also clears its failed-fetch count.
	store_route! : Str, I64, Str => Try({}, _)
	store_route! = |path, id, raw|
		Sql.execute!({
			path: Path.utf8(path),
			query: "INSERT OR REPLACE INTO routes (activity_id, raw_json) VALUES (:id, :raw)",
			bindings: [
				{ name: ":id", value: Integer(id) },
				{ name: ":raw", value: String(raw) },
			],
		})

	# what the drain durably stored is not knowable from here, so report the queue it was
	# working and point at the command that continues it. The counts live in the payload
	# on every path that returns one.
	say_partial_stored! : U64 => {}
	say_partial_stored! = |total| {
		# guarded like bar_done!, which has the same job: at total 0 no bar was ever
		# opened, so closing one emits a stray blank line and the sentence below would
		# read "partway through 0 activities"
		_ = if total > 0 {
			match Output.narrate_done!({}) {
				Ok(_) => {}
				Err(_) => {}
			}
		} else {
			{}
		}
		match Output.say!("sync stopped on an error partway through ${U64.to_str(total)} activities — everything already stored is saved; run `stride sync` again to continue") {
			Ok(_) => {}
			Err(_) => {}
		}
	}

	# count the streams a plain `sync` still owes: the queue drain_missing! walks
	# without `--all`, through the same predicate, so a run that stopped on the read
	# budget reports the shortfall honestly instead of looking like completion
	pending_streams! : Str => Try(I64, _)
	pending_streams! = |path|
		Sql.query!({
			path: Path.utf8(path),
			query: \\SELECT COUNT(*) AS n FROM activities a
				\\LEFT JOIN streams s ON s.activity_id = a.id
				\\LEFT JOIN stream_retries r ON r.activity_id = a.id
				\\${stream_queue_where}
			,
			bindings: [
				{ name: ":all", value: Integer(0) },
				{ name: ":cap", value: Integer(stream_attempt_cap) },
			],
			row: Sql.i64("n"),
		})

	# How many fetches of one activity's stream may return a body stride cannot
	# decode before a plain `sync` stops asking. Each failed fetch spends a read
	# from the same budget as every other stream, so the cap is what bounds the
	# reads one bad id can cost: nothing but a stored body resets the count, so
	# at most this many until then, plus one per explicit `sync --all`.
	stream_attempt_cap : I64
	stream_attempt_cap = 3

	# THE streams queue: activities with moving time and no stored stream, plus
	# every activity with a stream_retries row (a fetch that would not decode, or
	# a stored body analyze could not decode — whatever its moving time, since
	# analyze has promised that row a fetch), while the failed-fetch count is
	# under :cap, or regardless of it when :all = 1. Callers join
	# `activities a`, `streams s` and `stream_retries r` and bind :all and :cap.
	stream_queue_where : Str
	stream_queue_where =
		\\WHERE ((s.activity_id IS NULL AND a.moving_time > 0) OR r.activity_id IS NOT NULL)
		\\  AND (:all = 1 OR COALESCE(r.attempts, 0) < :cap)

	# A fetch returned a body stride cannot decode: count it, and say whether a
	# plain sync will ask again.
	count_unreadable_fetch! : Str, I64 => Try([Stored, Skipped, SkippedFinal(I64)], _)
	count_unreadable_fetch! = |path, id| {
		Sql.execute!({
			path: Path.utf8(path),
			query: "INSERT INTO stream_retries (activity_id, attempts) VALUES (:id, 1) ON CONFLICT(activity_id) DO UPDATE SET attempts = stream_retries.attempts + 1",
			bindings: [{ name: ":id", value: Integer(id) }],
		})?
		n = Sql.query!({
			path: Path.utf8(path),
			query: "SELECT attempts AS n FROM stream_retries WHERE activity_id = :id",
			bindings: [{ name: ":id", value: Integer(id) }],
			row: Sql.i64("n"),
		})?
		if (n < stream_attempt_cap) Ok(Skipped) else Ok(SkippedFinal(n))
	}

	# Analyze found a STORED stream it cannot decode: give it a retry row at
	# attempts 0 so the next sync fetches it. An existing row is left as it is,
	# so a rescore never re-arms the cap: an id costs at most stream_attempt_cap
	# failed reads in its life, plus one per explicit `sync --all`, and only a
	# fetch that stores a body clears the row.
	flag_stream_refetch! : Str, I64 => Try({}, _)
	flag_stream_refetch! = |path, id|
		Sql.execute!({
			path: Path.utf8(path),
			query: "INSERT OR IGNORE INTO stream_retries (activity_id, attempts) VALUES (:id, 0)",
			bindings: [{ name: ":id", value: Integer(id) }],
		})

	# how many of these activities have failed stream_attempt_cap fetches
	count_capped_among! : Str, List(I64) => Try(U64, _)
	count_capped_among! = |path, ids|
		match ids {
			[] => Ok(0)
			[id, .. as rest] => {
				n = Sql.query!({
					path: Path.utf8(path),
					query: "SELECT COUNT(*) AS n FROM stream_retries WHERE activity_id = :id AND attempts >= :cap",
					bindings: [
						{ name: ":id", value: Integer(id) },
						{ name: ":cap", value: Integer(stream_attempt_cap) },
					],
					row: Sql.i64("n"),
				})?
				more = count_capped_among!(path, rest)?
				Ok(more + (if (n > 0) 1 else 0))
			}
		}

	# count the activities whose stream has failed stream_attempt_cap fetches, so
	# a plain sync no longer asks for it: the ids pending_streams! leaves out on
	# purpose, which only `sync --all` fetches again
	capped_streams! : Str => Try(I64, _)
	capped_streams! = |path|
		Sql.query!({
			path: Path.utf8(path),
			query: \\SELECT COUNT(*) AS n FROM stream_retries r
				\\JOIN activities a ON a.id = r.activity_id
				\\WHERE r.attempts >= :cap
			,
			bindings: [{ name: ":cap", value: Integer(stream_attempt_cap) }],
			row: Sql.i64("n"),
		})

	# the notes twin — but NARROWER than the Notes queue, where the streams
	# pair mirror each other on a plain sync: pending is work the next run is OWED,
	# and only a never-asked activity qualifies. The queue also re-reads
	# stored in-window descriptions (#519); counting those here would make
	# every steady-state sync report itself resumable about maintenance it
	# just performed.
	pending_notes! : Str => Try(I64, _)
	pending_notes! = |path|
		Sql.query!({
			path: Path.utf8(path),
			query: \\SELECT COUNT(*) AS n FROM activities a
				\\LEFT JOIN strength_notes n2 ON n2.activity_id = a.id
				\\WHERE n2.activity_id IS NULL
				\\  AND COALESCE(a.sport_family, a.sport_type) = 'WeightTraining'
			,
			bindings: [],
			row: Sql.i64("n"),
		})

	# THE note-response policy, the stream policy one endpoint over: 404 => ''
	# marker (nothing visible there; don't refetch), 2xx => the detail's
	# description — '' when Strava sends null or omits the field, because
	# fetched-and-empty is a durable fact the queue must retire — and a
	# non-utf8 body => skip WITHOUT storing, so it retries next run.
	store_note_response! = |path, id, resp|
		if Response.status(resp) == 404 {
			store_note!(path, id, "")?
			Ok(Stored)
		} else if Response.status(resp) < 300 {
			match Str.from_utf8(Response.body(resp)) {
				Ok(text) => {
					decoded : Try({ description : Str }, _)
					decoded = Json.parse(text)
					match decoded {
						Ok(d) => {
							store_note!(path, id, d.description)?
							Ok(Stored)
						}
						# The one-field decode fails for exactly three body shapes,
						# and they mean two different things. `"description":null`
						# (Strava's spelling of a blank one) and an ABSENT key are
						# the empty case — store the '' marker, or an in-window
						# blank re-reads forever and a never-pasted session never
						# leaves pending. A PRESENT key the decoder still cannot
						# read is not empty, it is unreadable — and because
						# in-window rows are re-read every sync, storing '' there
						# would overwrite a real stored description on every run,
						# silently. Unreadable skips without storing, so the row
						# keeps whatever it had and the id retries.
						#
						# The substring test is sound only because the Ok arm has
						# already taken every case where description IS a string —
						# a description whose content contains this literal decodes
						# fine and never reaches here. The two spellings are the
						# observed compact and single-space forms; any other
						# (pretty-printed, spaced colon) falls to the skip arm,
						# which never erases but does retry forever — widen the
						# match if a new spelling is ever observed.
						Err(_) =>
							if Str.contains(text, "\"description\":null") or Str.contains(text, "\"description\": null") or !(Str.contains(text, "\"description\"")) {
								store_note!(path, id, "")?
								Ok(Stored)
							} else {
								Ok(Skipped)
							}
					}
				}
				Err(_) => Ok(Skipped)
			}
		} else {
			text = Str.from_utf8(Response.body(resp)).ok_or("<non-utf8 body>")
			Err(HttpStatus(Response.status(resp), text))
		}

	# no invalidation on store: strength_sets rebuilds wholesale on every
	# analyze, so a newly arrived note is picked up by the next run with no
	# per-row bookkeeping — the opposite tradeoff from store_streams!, whose
	# metrics invalidation exists because metrics rows are converged, not
	# rebuilt
	store_note! : Str, I64, Str => Try({}, _)
	store_note! = |path, id, desc|
		Sql.execute!({
			path: Path.utf8(path),
			query: "INSERT OR REPLACE INTO strength_notes (activity_id, description) VALUES (:id, :d)",
			bindings: [
				{ name: ":id", value: Integer(id) },
				{ name: ":d", value: String(desc) },
			],
		})

	store_streams! : Str, I64, Str => Try({}, _)
	store_streams! = |path, id, text| {
		Sql.execute!({
			path: Path.utf8(path),
			query: "INSERT OR REPLACE INTO streams (activity_id, raw_json) VALUES (:id, :raw)",
			bindings: [
				{ name: ":id", value: Integer(id) },
				{ name: ":raw", value: String(text) },
			],
		})?
		# a stored body ends the id's retries
		_ = Sql.execute!({
			path: Path.utf8(path),
			query: "DELETE FROM stream_retries WHERE activity_id = :id",
			bindings: [{ name: ":id", value: Integer(id) }],
		})?
		# streams just arrived — invalidate any metrics computed before them so the
		# next analyze recomputes zones/NP from the real data (they were frozen otherwise)
		invalidate_metrics!(path, id)
	}

	# drop an activity's computed metrics so the next analyze recomputes it. the
	# invalidation story: FTP change (ftp_used check), stream arrival, Strava edit.
	invalidate_metrics! : Str, I64 => Try({}, _)
	invalidate_metrics! = |path, id| {
		# metrics FIRST, segments second, deliberately: if the second delete fails,
		# the missing metrics row makes the next analyze redo the activity, which
		# re-deletes and rebuilds segments — the failure self-heals. The reverse
		# order strands segment-less activities that analyze never revisits.
		_ = Sql.execute!({
			path: Path.utf8(path),
			query: "DELETE FROM activity_metrics WHERE activity_id = :id",
			bindings: [{ name: ":id", value: Integer(id) }],
		})?
		Sql.execute!({
			path: Path.utf8(path),
			query: "DELETE FROM activity_segments WHERE activity_id = :id",
			bindings: [{ name: ":id", value: Integer(id) }],
		})
	}

	# ── read pacing (Strava's limits) ────────────────────────────────────
	# 100 reads per 15-minute window, 1000 per UTC day. The engine counts its own
	# reads and paces by the larger of that count and what Strava's
	# X-ReadRateLimit-Usage header reports (Drain.decide); a 429 is a backstop
	# for when both under-count, not the mechanism.
	# ── test seams, same species as STRIDE_API_BASE ─────────────────────
	# Without these, reaching the budget stops honestly costs a full window (95) —
	# and the daily cap a full day (1000) — of real HTTP reads, and the wait a
	# real quarter-hour, so a transposed counter in a terminal arm cannot be caught.
	# An override may only LOWER a limit or SHORTEN the window, never raise either:
	# a raised cap lets a typo hammer the API and get the athlete's own API app
	# suspended. Lowering is all a test needs, so the useful direction is the safe one.
	env_i64! : Str, I64 => I64
	env_i64! = |name, fallback|
		match Env.var_str!(OsStr.from_str(name)) {
			Ok(v) =>
				match I64.from_str(v) {
					Ok(n) if n > 0 and n < fallback => n
					_ => fallback
				}
			Err(_) => fallback
		}

	# how many token refreshes one run may spend before calling it an auth problem
	max_refreshes = 2

	# reads already made TODAY, in UTC. Two rows: the count and the day it belongs
	# to. Reading them together makes the reset free — a stale `strava_reads_day`
	# means the count is zero, and nothing has to run at midnight. Absent keys are
	# zero (a never-synced database has no count; `Db.config_opt!` maps NoRowsReturned
	# to NotFound).
	#
	# ...and CHARGE one, BEFORE the request: a transport failure counts a read Strava
	# never saw, and that is the deliberate direction — a cap is a ceiling, so
	# UNDER-counting overshoots it and gets every subsequent read refused (#246).
	# The cost of over-counting is bounded but real: the pre-flight refuses on
	# `today >= reads_per_day`, so a heavily over-counted day refuses every run until
	# UTC midnight — it takes ~a thousand transport failures to get there.
	charge_read! : Str => Try({}, _)
	charge_read! = |path| {
		day = Db.utc_today_days!({})
		n = reads_today!(path, day)?
		save_reads_for_day!(path, day, n + 1)
	}

	# is the allowance already spent, WITHOUT spending anything to find out? `decide` is
	# structurally unable to answer this — it is only reachable with a response in hand —
	# so without it a capped run spends a list read and a stream read to report that it
	# has none left. At the cadence stride's own advice implies that is ~190 reads a day
	# burned against an allowance that is already gone, with the counter climbing past the
	# cap all day. The day is knowable from the database with zero requests.
	day_spent! : Str => Try(Bool, _)
	day_spent! = |path| Ok(reads_today!(path, Db.utc_today_days!({}))? >= (read_limits!({})).reads_per_day)

	# takes the day rather than reading its own clock, so a caller that already has
	# one cannot compare a count against a different day than it saves against —
	# that pair disagreeing was this feature's recurring bug. Narrower than
	# "unrepresentable": other sites still read the clock; this one function just
	# cannot be the site of the disagreement.
	reads_today! = |path, day_now| {
		# BOTH rows get the conservative reading. The count's Corrupt arm argues that
		# "cannot tell" must mean "may all be spent" — and the day STAMP went through
		# `config_i64!`, which folds Corrupt to 0: a stamp of 0 never equals today, so
		# the count was skipped and a full fresh allowance handed out silently. One fact
		# in two rows takes one policy: unreadable means today, and today means the
		# count is consulted.
		stored_day =
			match config_reads!(path, "strava_reads_day")? {
				Known(n) => Ok(n)
				Corrupt(v) => {
					_ = Output.say!("cannot read the day stamp on Strava's read counter ('${v}') — treating it as today so the count still applies; `stride config set strava_reads_today 0` clears both")
					# ...and REPAIR it, which is what makes the conservative reading affordable: a
					# corrupt COUNT self-heals when its stamp goes stale, but a corrupt STAMP is read
					# as today FOREVER, refusing every run.
					# Writing a real day keeps this run refused — the count still applies — and makes
					# the stamp genuinely stale tomorrow.
					_ = Db.config_set!(path, "strava_reads_day", I64.to_str(day_now))?
					Ok(day_now)
				}
			}?
		if stored_day != day_now {
			Ok(0)
		} else {
			match config_reads!(path, "strava_reads_today")? {
				Known(n) => Ok(n)
				Corrupt(v) => {
					# NARRATED, because the consequence is a day of refused reads and the
					# athlete would otherwise get no signal at all. This is the one place
					# in the codebase that deliberately breaks the "unreadable config is
					# an error" rule, so it says so out loud rather than quietly.
					_ = Output.say!("cannot read today's Strava read count ('${v}') — assuming the daily allowance is spent; `stride config set strava_reads_today 0` clears it")
					Ok((read_limits!({})).reads_per_day)
				}
			}
		}
	}

	# ABSENT and UNREADABLE are different facts. Absent is 0 because it is TRUE: a
	# database that never synced has spent nothing. Unreadable is the full allowance,
	# because 0 is the most PERMISSIVE value, not the conservative one — "I cannot
	# tell how many reads were spent" conservatively means "they may all be spent".
	# Guessing 0 also ERASES the day's history on the first save and spends a second
	# full allowance inside one UTC day, every read refused by Strava; guessing the
	# cap costs one day, self-heals at midnight, and `config set strava_reads_today
	# 0` is the escape hatch.
	#
	# Clamped at 0: arg_i64 accepts negatives, and a parseable -5000 would buy MORE
	# headroom than an unparseable value, inverting the argument above. Swallowed
	# rather than raised — refusing to sync over a corrupt pacing counter is worse
	# than pacing badly — but no longer silent: see the caller.
	config_reads! = |path, key|
		match Db.config_opt!(path, key)? {
			NotFound => Ok(Known(0))
			Found(v) =>
				match Metrics.arg_i64(v) {
					Ok(n) => Ok(Known((n).max(0)))
					Err(_) => Ok(Corrupt(v))
				}
		}

	config_i64! = |path, key|
		match config_reads!(path, key)? {
			Known(n) => Ok(n)
			Corrupt(_) => Ok(0)
		}

	# ...and write it back after EVERY read, not at the end of the run: reads are
	# spent at Strava the moment they happen, so a drain that dies mid-way must not
	# forget the ones it made — losing them drifts the counter UNDER the true total,
	# the direction that overshoots the cap. Two small UPDATEs against an HTTP round
	# trip is not worth optimising, and batching reintroduces the loss window.
	#
	# It writes against the day the count BELONGS to, which is not always the day it
	# is written on: a run in flight at UTC midnight would otherwise stamp the new day
	# with the old day's total — start at 23:59 with 795 spent, cross midnight, and the
	# athlete gets 205 of tomorrow's 1000. The caller passes the day it is CURRENTLY
	# on, re-read each iteration: captured once, the crossing stamps every read after
	# midnight onto the day before, so day D+1 begins already owing them.
	save_reads_for_day! : Str, I64, I64 => Try({}, _)
	save_reads_for_day! = |path, day, n| {
		Db.config_set!(path, "strava_reads_day", I64.to_str(day))?
		Db.config_set!(path, "strava_reads_today", I64.to_str(n))
	}

	read_limits! : {} => Drain.Limits
	read_limits! = |{}| {
		# stop before Strava's 100-reads-per-15-minutes window fills; the margin
		# absorbs a read or two another app makes between the engine's. The list's
		# reads count into the window the drain starts in. The day gets no margin
		# because every read, the list's included, is counted against it.
		reads_per_window: env_i64!("STRIDE_READS_PER_WINDOW", 95),
		# Strava's documented daily read cap. Overridable for the same reason the window
		# is: the e2e suite drives this arm at a limit small enough to reach in a fixture.
		reads_per_day: env_i64!("STRIDE_READS_PER_DAY", 1000),
	}

	# the read window's length in seconds; STRIDE_WINDOW_SECONDS can only shorten
	# it, which shortens the wait with it, so the e2e drivers can cross several
	# windows in seconds
	window_secs! : {} => I64
	window_secs! = |{}| env_i64!("STRIDE_WINDOW_SECONDS", Drain.window_secs_default)

	send_bearer! = |uri, token|
		Http.send!(
			Request.from_method(Method.GET)
				.with_uri(uri)
				.add_header("Authorization", "Bearer ${token}")
				.with_body([])
				.with_timeout(TimeoutMilliseconds(60000)),
			{},
		)

	# THE stream-response policy. 404 => the "{}" marker (no streams recorded;
	# don't refetch). 2xx with a body that decodes => store it. 2xx with a body
	# that is not UTF-8 or will not decode => store NOTHING and count the failed
	# fetch in stream_retries: a stored body retires the id from the queue, so
	# storing an unreadable one would leave analyze reading it forever, and the
	# count is what stops the id being fetched forever. Anything else => the
	# error propagates. Both stores clear the id's stream_retries row.
	store_stream_response! = |path, id, resp|
		if Response.status(resp) == 404 {
			store_streams!(path, id, "{}")?
			Ok(Stored)
		} else if Response.status(resp) < 300 {
			match Str.from_utf8(Response.body(resp)) {
				Ok(text) if !(Streams.decode_streams(NotNull(text)).failed) => {
					store_streams!(path, id, text)?
					Ok(Stored)
				}
				_ => count_unreadable_fetch!(path, id)
			}
		} else {
			text = Str.from_utf8(Response.body(resp)).ok_or("<non-utf8 body>")
			Err(HttpStatus(Response.status(resp), text))
		}
	# Per-drain state. `window` = reads spent in the current read window, carried
	# from one drain into the next so the streams, notes and routes drains of a
	# round share one window; `widx` is that window's index (Drain.window_index over
	# `wsecs`, the window's length), and a drain that crosses a mark starts its count
	# over (Drain.roll_window). `stored`/`skipped` = what the reads produced, which
	# is not the same as `window`: pacing is about READS (a 404 spends a read and
	# stores a marker) while the payload reports WORK. `total` is the bar's
	# denominator and `opened` whether a bar was drawn, so it is closed exactly once.
	# `day` is the UTC day the count belongs to, RE-READ at the top of each iteration
	# and reset with its count when it changes (Drain.roll_day); `today` is the
	# running count against it.
	DrainState : { window : I64, widx : I64, wsecs : I64, day : I64, today : I64, stored : I64, skipped : I64, total : U64, opened : Bool, refreshes : I64 }

	# Walk the queue once — walking a LIST (not re-querying "next missing") means an
	# unstorable body is skipped, not refetched forever. The pacing DECISION is pure
	# (Drain.decide); this is the thin effectful skin. The four ways a drain ends are
	# RETURNED, because "why did it stop?" is not derivable from the counts; a drain
	# CANNOT report a list refusal, which lives on Drain.SyncStop. `window` is the
	# window's read count on return, and the next drain of the round starts from it.
	DrainOutcome : { stored : I64, skipped : I64, stopped : Drain.StopReason, window : I64 }

	# what one queue item asks Strava for, and what storing the answer means.
	# ONE loop serves every kind — the pacing, refresh, 429 and skip policies
	# are shared by construction, which is the anti-drift rule the loop's own
	# comment states. Streams fetch the five analysis streams; Notes fetch the
	# activity DETAIL for its description (the strength share text, #478);
	# Routes fetch the GPS coordinates and their times (#700).
	DrainKind : [Streams, Notes, Routes]

	drain_queue! : Str, Str, DrainKind, List(I64), DrainState => Try(DrainOutcome, _)
	drain_queue! = |path, token, kind, ids, st_in| {
		# RE-READ each iteration, not captured once: a drain can outlive UTC midnight,
		# and when it does the allowance has genuinely reset, and it can cross a
		# quarter-hour mark, after which its window's own count no longer applies. Both
		# rules are pure (Drain.roll_day, Drain.roll_window) and pinned by expects.
		now = Db.now_secs!({})
		rolled = Drain.roll_day({ day: st_in.day, today: st_in.today }, now // 86400)
		rolled_w = Drain.roll_window({ idx: st_in.widx, window: st_in.window }, Drain.window_index(now, st_in.wsecs))
		st = { ..st_in, day: rolled.day, today: rolled.today, widx: rolled_w.idx, window: rolled_w.window }
		match ids {
			[] => {
				bar_done!(st)
				Ok({ stored: st.stored, skipped: st.skipped, stopped: Complete, window: st.window })
			}
			[id, .. as rest] => {
				uri =
					match kind {
						Streams => "${api_base!({})}/api/v3/activities/${I64.to_str(id)}/streams?keys=time,heartrate,watts,altitude,distance&key_by_type=true"
						Notes => "${api_base!({})}/api/v3/activities/${I64.to_str(id)}"
						Routes => "${api_base!({})}/api/v3/activities/${I64.to_str(id)}/streams?keys=latlng,time&key_by_type=true"
					}
				resp = send_bearer!(uri, token)?
				usage = Drain.usage_of(List.map(Response.headers(resp), |h| h.to_str()))
				match Drain.decide({ status: Response.status(resp), window: st.window, today: st.today, usage }, read_limits!({})) {
					Refresh => {
						# the 401'd read is spent too, and this arm RETRIES the same id —
						# so the read is charged here and the retry charges its own. Two
						# reads at Strava, two on the counter.
						_ = save_reads_for_day!(path, st.day, Drain.charged(st.today, usage))?
						# Long runs outlive the ~6h access token; refresh and retry the same id.
						# BOUNDED, like the 429 retry beside it: this arm recurses on the same id, so a
						# persistently 401ing activity (revoked scope, private without activity:read_all)
						# would spin forever — measured at ~113 requests/second unbounded, 4,500
						# reads against a 1000/day cap in under a minute, which is the shape that
						# gets an API app suspended. `decide` does not charge a 401 against `window`,
						# so the read budget never ends it. Same token back is a real auth problem.
						if st.refreshes >= max_refreshes {
							# no bar_done! here: this propagates, and the boundary reporter
							# closes the bar on the way out. Closing twice leaves a stray
							# blank line on stderr.
							Err(HttpStatus(401, "refreshed the token twice and Strava still returned 401 for this activity — the credential is working, so this is likely a missing activity:read_all scope or a clock skew rather than a dead login"))
						} else {
							fresh = get_valid_token!(path)?
							if fresh == token {
								Err(HttpStatus(401, "token refresh did not help — re-run `stride auth`"))
							} else {
								bar_done!(st)
								Output.say!("  access token expired — refreshed, continuing...")?
								# `today` advances with the charge above. Charging the row
								# and not the running total would leave `decide` comparing
								# a stale count on the retry — the disk and the loop would
								# disagree about how much of the day is left.
								drain_queue!(path, fresh, kind, ids, { ..st, today: Drain.charged(st.today, usage), refreshes: st.refreshes + 1 })
							}
						}
					}
					# A 429 ends this drain, never by sleeping here: the rows already
					# stored are durable, and sync! decides whether the run waits for the
					# next window or ends there. The daily allowance is recognised from
					# the 429 as well as from the count — see Drain.decide.
					DailyCapReached => {
						# the 429'd read is a REAL read. It never reaches the Store arm, so
						# without this the counter sits below the cap while Strava is
						# already refusing — and since #246's whole comparison is
						# `today >= reads_per_day`, an undercount makes it false at exactly
						# the moment it needs to be true.
						_ = save_reads_for_day!(path, st.day, Drain.charged(st.today, usage))?
						bar_done!(st)
						Ok({ stored: st.stored, skipped: st.skipped, stopped: DailyCapReached, window: st.window })
					}
					RateLimited => {
						_ = save_reads_for_day!(path, st.day, Drain.charged(st.today, usage))?
						bar_done!(st)
						Ok({ stored: st.stored, skipped: st.skipped, stopped: RateLimited, window: st.window })
					}
					Store({ window, today, after }) => {
						save_reads_for_day!(path, st.day, today)?
						# 404 => empty marker, 2xx => body, other => error propagated.
						# MATCHED, not discarded: a skip writes no stream row, so it is
						# counted as skipped and never as fetched, or a lossy run would
						# present itself as a clean one. Skipped = the id stays in the
						# queue for the next plain sync; SkippedFinal = it has failed
						# stream_attempt_cap fetches and only `sync --all` asks again.
						counted =
							match store_response!(path, kind, id, resp)? {
								Stored => { stored: st.stored + 1, skipped: st.skipped }
								Skipped => {
									bar_done!(st)
									Output.say!("  activity ${I64.to_str(id)}: ${skip_subject(kind)} would not decode — skipped, retries next run")?
									{ stored: st.stored, skipped: st.skipped + 1 }
								}
								SkippedFinal(n) => {
									bar_done!(st)
									Output.say!("  activity ${I64.to_str(id)}: ${skip_subject(kind)} would not decode — skipped after ${I64.to_str(n)} failed fetches; plain syncs stop asking, `stride sync --all` asks again")?
									{ stored: st.stored, skipped: st.skipped + 1 }
								}
							}
						# narrate on the id just RETIRED, counting attempts: a 404 or an
						# undecodable body is progress through the queue too, so counting
						# only stores would stall the bar on a run full of skips.
						_ = if st.opened {
							Output.narrate!(drain_label(kind), st.total - List.len(rest), st.total)?
						} else {
							{}
						}
						match after {
							# the read window is full: the round ends, and the run waits
							# for the next window or names when it opens
							WindowFull => {
								bar_done!(st)
								Ok({ stored: counted.stored, skipped: counted.skipped, stopped: BudgetReached, window })
							}
							# the DAILY allowance, which ends the run until midnight UTC
							DayFull => {
								bar_done!(st)
								Ok({ stored: counted.stored, skipped: counted.skipped, stopped: DailyCapReached, window })
							}
							Continue =>
								drain_queue!(path, token, kind, rest, { ..st, window, today, stored: counted.stored, skipped: counted.skipped })

						}
					}
				}
			}
		}
	}
	per_page = 100

	# The listing's accumulator. The re-listed total AND the new/updated split (#112):
	# the first is training frequency, the second is what happened this run. `page`
	# is the next page to ask for, and after a refusal the page that was refused;
	# `reads` counts the pages asked for, which the drain's window starts from;
	# `usage` is what the last page's rate-limit header reported.
	PageAcc : { relisted : U64, new_n : U64, updated_n : U64, rate_limited : Bool, page : U64, reads : I64, usage : Drain.Usage }

	# A 429 on the LIST ends the listing the way a 429 on a stream ends a drain
	# (#235): pages already upserted are kept and reported, `rate_limited` rides the
	# accumulator, and the caller reports a successful partial run. Propagating
	# instead would make one upstream condition behave two ways in one invocation —
	# exit 1 on the list, a success envelope on a stream.
	fetch_pages! : Str, Str, Str, I64, PageAcc => Try(PageAcc, _)
	fetch_pages! = |path, token, after_param, stamp, acc| {
		page = acc.page
		uri = "${api_base!({})}/api/v3/athlete/activities?per_page=${(per_page).to_str()}&page=${(page).to_str()}${after_param}"
		# BEFORE the request, so a stalled request shows a frame rather than nothing
		Output.spin!("activity list", page)?
		# COUNTED, because Strava counts it: the list and the streams draw on ONE read
		# limit, and counting only the streams makes stride's number a strict subset
		# of Strava's, so Strava reaches the cap first and the last reads of the day
		# are unspendable.
		_ = charge_read!(path)?
		resp = send_bearer!(uri, token)?
		usage = Drain.usage_of(List.map(Response.headers(resp), |h| h.to_str()))
		_ = floor_day!(path, usage)?
		read = { ..acc, reads: acc.reads + 1, usage }
		# Only 429 is a partial run. Every other status propagates, including a 401 —
		# this function has NO refresh arm, and does not need one: get_valid_token!
		# refreshes proactively at run start with a 60-second margin, and the listing
		# takes seconds. A 500 is not something to report as a successful partial run.
		if Response.status(resp) == 429 {
			Ok({ ..read, rate_limited: True })
		} else {
			body = ok_body(resp)?
			text = Str.from_utf8(body).map_err(|_| ActivityDecodeFailed(page))?
			decoded : Try(List(ActivitySummary), _)
			decoded = Json.parse(text)
			acts = decoded.map_err(|_| ActivityDecodeFailed(page))?
			counts = upsert_all!(path, stamp, acts, { new_n: acc.new_n, updated_n: acc.updated_n })?
			got = List.len(acts)
			next = { ..read, relisted: acc.relisted + got, new_n: counts.new_n, updated_n: counts.updated_n, page: page + 1 }
			# Strava's list is paged and its length unknowable until a short page
			# arrives, which ends it
			if (got < per_page)
				Ok(next)
			else
				fetch_pages!(path, token, after_param, stamp, next)
		}
	}

	# raise the day's stored count to what the rate-limit header reports, when it
	# reports more: the header also counts other apps' reads on the same token
	floor_day! : Str, Drain.Usage => Try({}, _)
	floor_day! = |path, usage| {
		day = Db.utc_today_days!({})
		n = reads_today!(path, day)?
		seen = (Drain.floor_counts({ window: 0, today: n }, usage)).today
		if (seen > n) save_reads_for_day!(path, day, seen) else Ok({})
	}
	# What a sync did to one row. Most rows on most days are Unchanged: sync re-lists a
	# rolling 30-day window every run, so the re-listed count is a function of how often
	# the athlete trains, not of anything this sync did (#112).
	UpsertOutcome : [Inserted, Updated, Unchanged]

	SyncCounts : { new_n : U64, updated_n : U64 }

	# The classify SELECT runs per row, unconditionally. It is skippable only for a
	# caller that re-lists the whole account and never reads the counts — paying a
	# query each would then be a real cost for nothing, the same mistake as running
	# classify inside upsert_activity! where CSV import pays it. The one caller here
	# wants the counts, so there is no flag; if a future caller does not, add one
	# rather than making this function guess.
	upsert_all! : Str, I64, List(ActivitySummary), SyncCounts => Try(SyncCounts, _)
	upsert_all! = |path, stamp, acts, acc|
		match acts {
			[] => Ok(acc)
			[a, .. as rest] => {
				# classify HERE, not inside upsert_activity!. Import.roc calls that
				# directly for CSV loads and discards the outcome, so classifying there
				# made every imported row pay for an extra query it never reads — and that
				# extra per-row query in the import loop made the offline e2e flaky
				# (import checks failing ~1 run in 3). The counts are a sync concern; keep
				# the cost on the sync path, and only when someone will read them.
				outcome = classify_activity!(path, a)?
				_ = upsert_activity!(path, stamp, a)?
				next =
					match outcome {
						Inserted => { new_n: acc.new_n + 1, updated_n: acc.updated_n }
						Updated => { new_n: acc.new_n, updated_n: acc.updated_n + 1 }
						Unchanged => acc
					}
				upsert_all!(path, stamp, rest, next)
			}

		}

	# Classify BEFORE writing, in one read. `changes()` after the write would have been
	# cheaper, but it is per-CONNECTION state and every Sqlite call here takes a path
	# rather than a handle — whether two calls share a connection is a platform detail we
	# would be silently depending on. A rolling window is ~20 rows, so one extra SELECT
	# each is not worth that risk.
	#
	# `IS` rather than `=` throughout: these columns are nullable and `= NULL` is NULL, not
	# false, so every row with a missing avg_watts would look changed on every sync.
	#
	# synced_at is deliberately NOT compared. It is re-stamped every run by design, so
	# including it would mark every row updated — which is precisely the misreporting this
	# exists to remove.
	classify_activity! = |path, a| {
		rows = Sql.query_many!({
			path: Path.utf8(path),
			query: \\SELECT
				\\  (SELECT COUNT(*) FROM activities WHERE id = :id) AS existed,
				\\  (SELECT COUNT(*) FROM activities WHERE id = :id
				\\     AND name IS :name AND sport_type IS :sport AND start_local IS :start
				\\     AND moving_time IS :mt AND distance IS :dist AND elevation IS :elev
				\\     AND relative_effort IS :re AND avg_watts IS :aw AND avg_hr IS :ahr
				\\     AND weighted_avg_watts IS :waw AND device_watts IS :dw AND max_hr IS :mhr) AS same
			,
			bindings: activity_bindings(a),
			rows: |cols| |stmt| {
				existed = Sql.i64("existed")(cols)(stmt)?
				same = Sql.i64("same")(cols)(stmt)?
				Ok((existed, same))
			},
		})?
		match List.first(rows) {
			Ok((0, _)) => Ok(Inserted)
			Ok((_, 0)) => Ok(Updated)
			Ok(_) => Ok(Unchanged)
			# a COUNT always returns a row, so this is unreachable; call it Updated rather
			# than Unchanged so an impossible state over-reports rather than hiding work
			Err(_) => Ok(Updated)
		}
	}

	# The column bindings shared by the classify SELECT and the upsert INSERT, so the two
	# cannot drift into comparing one set of values and writing another. `:synced` is NOT
	# here: it is appended by the writer only, because the comparison must ignore it.
	activity_bindings : ActivitySummary -> List(_)
	activity_bindings = |a| [
		{ name: ":id", value: Integer(a.id) },
		# Binding the decoded Str straight through is correct on this platform. Wrapping it
		# in "${...}" to force a copy only adds heap Strs, and the short-name e2e mock
		# cannot exercise heap-string paths, so check such a change against real data.
		{ name: ":name", value: String(a.name) },
		{ name: ":sport", value: String(a.sport_type) },
		{ name: ":start", value: String(a.start_date_local) },
		{ name: ":mt", value: Integer(a.moving_time) },
		{ name: ":dist", value: Real(a.distance) },
		{ name: ":elev", value: Real(a.total_elevation_gain) },
		{ name: ":re", value: opt_real(a.suffer_score) },
		{ name: ":aw", value: opt_real(a.average_watts) },
		{ name: ":ahr", value: opt_real(a.average_heartrate) },
		{ name: ":waw", value: opt_real(a.weighted_average_watts) },
		{ name: ":mhr", value: opt_real(a.max_heartrate) },
		# NULL = Strava did not say (old data); 1 = real meter; 0 = estimated
		{
			name: ":dw",
			value: match a.device_watts {
				Ok(True) => Integer(1)
				Ok(False) => Integer(0)
				Err(_) => Null
			},
		},
	]
	upsert_activity! : Str, I64, ActivitySummary => Try({}, _)
	upsert_activity! = |path, stamp, a| {
		# stamp 0 = a non-sync writer (CSV import): leave synced_at NULL so the prune
		# never mistakes an imported activity (never on Strava) for a deleted one. Real
		# sync stamps are now_secs epochs, never 0.
		synced_val = if (stamp == 0) Null else Integer(stamp)
		Sql.execute!({
			path: Path.utf8(path),
			query: \\INSERT OR REPLACE INTO activities (id, name, sport_type, start_local, moving_time, distance, elevation, relative_effort, avg_watts, avg_hr, weighted_avg_watts, device_watts, max_hr, synced_at)
				\\VALUES (:id, :name, :sport, :start, :mt, :dist, :elev, :re, :aw, :ahr, :waw, :dw, :mhr, :synced)
			,
			# the SAME values classify_activity! compared against, so the check and the
			# write cannot disagree about what "changed" means. :synced is appended here
			# only — it is re-stamped every run and must stay out of the comparison.
			bindings: List.append(
				activity_bindings(a),
				# stamp this row with the current sync run so prune_deleted! can tell which
				# activities Strava still has (re-stamped) from ones it deleted (stale stamp)
				{ name: ":synced", value: synced_val },
			),
		})?
		# NO metrics invalidation here, deliberately: sync re-lists a rolling 30-day
		# window and cannot tell an edit from a no-op, so deleting here wiped a month of
		# metrics every run. Staleness is detected in `analyze` by comparing the stored
		# activity inputs against the row as it stands (same contract as ftp_used) —
		# stateless, self-correcting, and free since analyze already runs the predicate.
		Ok({})
	}

	# remove activities that vanished from Strava. A row is a victim when this sync run
	# did NOT re-stamp it (synced_at present but stale) AND it sits inside the pulled window
	# (start_local >= window_start; "" = full pull = all rows). Three judgment-tier guards:
	# never prune an activity that carries a rating, completed a planned session, or stands in as a substitute for one —
	# those rows can't be re-derived, so we leave the (now-orphaned) activity as a
	# tombstone rather than destroy the human input. Everything else in the mirror tier is
	# re-pullable, so pruning is safe. Cascades to the computed tables and runs in one
	# transaction so a crash can't half-prune. Returns the number of activities removed.
	prune_deleted! : Str, I64, Str => Try(U64, _)
	prune_deleted! = |path, stamp, window_start| {
		victims = Sql.query_many!({
			path: Path.utf8(path),
			query: \\SELECT id AS id FROM activities
				\\-- only rows a PRIOR sync stamped then this run didn't re-stamp are
				\\-- confirmed Strava deletions. NULL (CSV imports, pre-migration rows)
				\\-- is never a victim — conservative, avoids nuking non-sync data.
				\\WHERE synced_at IS NOT NULL AND synced_at <> :stamp
				\\  AND start_local >= :ws
				\\  AND id NOT IN (SELECT activity_id FROM ratings)
				\\  AND id NOT IN (SELECT completed_activity_id FROM planned_sessions WHERE completed_activity_id IS NOT NULL)
				\\  AND id NOT IN (SELECT substitute_activity_id FROM planned_sessions WHERE substitute_activity_id IS NOT NULL)
			,
			bindings: [
				{ name: ":stamp", value: Integer(stamp) },
				{ name: ":ws", value: String(window_start) },
			],
			rows: Sql.i64("id"),
		})?
		if (List.len(victims) == 0)
			Ok(0)
		else {
			# one connection for the whole prune: BEGIN, the deletes and COMMIT
			# must share it, or each delete autocommits on its own
			Sql.transaction!(Path.utf8(path), |run!| prune_txn!(run!, victims))?
			Ok(List.len(victims))
		}
	}
	prune_txn! = |run!, ids|
		match ids {
			[] => Ok({})
			[id, .. as rest] => {
				b = [{ name: ":id", value: Integer(id) }]
				_ = run!("DELETE FROM activity_metrics WHERE activity_id = :id", b)?
				_ = run!("DELETE FROM activity_segments WHERE activity_id = :id", b)?
				_ = run!("DELETE FROM streams WHERE activity_id = :id", b)?
				_ = run!("DELETE FROM stream_retries WHERE activity_id = :id", b)?
				_ = run!("DELETE FROM routes WHERE activity_id = :id", b)?
				# the strength tables reference activities too, and the database
				# enforces it: a strength session deleted upstream with a stored
				# description or log would otherwise fail the activity's DELETE
				# and the whole prune with it
				_ = run!("DELETE FROM strength_sets WHERE activity_id = :id", b)?
				_ = run!("DELETE FROM strength_logs WHERE activity_id = :id", b)?
				_ = run!("DELETE FROM strength_notes WHERE activity_id = :id", b)?
				_ = run!("DELETE FROM activities WHERE id = :id", b)?
				prune_txn!(run!, rest)
			}
		}
}
