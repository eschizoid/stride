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
	# second it can continue at (0 for none), analyze's report, and whether the
	# run made any request at all
	SyncResult : { payload : SyncPayload, stop : Drain.SyncStop, resume_epoch : I64, settled : Settled, requested : Bool, again : Bool }

	# what the drains stored and skipped, summed over a run's rounds
	Tally : { streams : I64, streams_skipped : I64, notes : I64, notes_skipped : I64, routes : I64, routes_skipped : I64 }

	no_tally : Tally
	no_tally = { streams: 0, streams_skipped: 0, notes: 0, notes_skipped: 0, routes: 0, routes_skipped: 0 }

	# the activities each queue has already been asked for in this run. A queue
	# keeps an id it re-reads (a description inside the rolling window, every
	# description under `--all`) or one whose body would not decode, and without
	# this every round would ask for those first and the queues after them would
	# never be reached; asked once, an id waits for the next run.
	Seen : { streams : List(I64), notes : List(I64), routes : List(I64) }

	no_seen : Seen
	no_seen = { streams: [], notes: [], routes: [] }

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
		waits = !(Output.json_mode!({}))
		interruptible!(
			waits,
			"stride sync",
			|{}|
				match get_valid_token!(path) {
					Err(NotAuthed) =>
						Output.err_out!("not_authenticated", "not authenticated — run `stride auth` first")

					Err(other) => Err(other)
					Ok(token) => {
						r = sync_run!(path, token, { all, relist: True }, settle!, waits)?
						note = sync_note!(path, r)
						Output.out!(r.payload, |p| Render.sync_screen(p, r.stop, note))
					}
				},
		)
	}

	# A human run waits for Strava's next read window, so Ctrl-C has to stop it
	# cleanly: catching the interrupt makes the sleep and any request in flight
	# return Interrupted (SQLite reports it as its own Interrupt), and every fetch
	# before it is already stored, so `resume` (the command to run again) carries
	# on from there. A caught interrupt keeps every blocking effect returning
	# Interrupted until it is acknowledged, so it is polled before the closing
	# line, and polled again if a second Ctrl-C lands on that write. 130 is the
	# status a shell gives an interrupted command.
	interruptible! : Bool, Str, ({} => Try(a, _)) => Try(a, _)
	interruptible! = |waits, resume, run!| {
		_ = if waits {
			match Signal.catch!([Interrupt]) {
				Ok(_) => {}
				Err(_) => {}
			}
		} else {
			{}
		}
		stopped! = |_| {
			say_stopped!(resume, 3)
			Err(Exit(130))
		}
		match run!({}) {
			Err(Interrupted) => stopped!({})
			Err(SqliteErr(Interrupt, _)) => stopped!({})
			other => other
		}
	}

	say_stopped! : Str, U64 => {}
	say_stopped! = |resume, tries| {
		_ = Signal.poll!()
		_ = Output.narrate_done!({})
		match Output.say!("stopped — every fetch so far is stored, and the next `${resume}` resumes from there") {
			Err(Interrupted) if tries > 1 => say_stopped!(resume, tries - 1)
			_ => {}
		}
	}

	# the screen's note: the local time the run continues, how analyze ended, and
	# whether the run asked Strava for anything, and whether it ended because a
	# period it waited for was still spent
	sync_note! : Str, SyncResult => Render.SyncNote
	sync_note! = |path, r| {
		resume = if (r.resume_epoch == 0) "" else Render.local_time(r.resume_epoch, Db.time_mode_offset(Db.resolve_time_mode!(path)), Db.now_secs!({}))
		{ resume, analysis: r.settled.analysis, verdict: r.settled.verdict, requested: r.requested, again: r.again }
	}

	# One sync, to its end. The list first: every page of the activity list before any
	# stream, so a first sync's summaries are listed and scored in its first window.
	# Then rounds of streams, descriptions and routes, one read window each, with
	# analyze run after each round. A human run (`waits`) waits for the next window
	# between rounds; a `--json` run does one round and names the time the next window
	# opens. `relist: False` skips the list, for setup's sync step, whose own
	# activities step listed them.
	sync_run! : Str, Str, { all : Bool, relist : Bool }, (Str => Try(Settled, _)), Bool => Try(SyncResult, _)
	sync_run! = |path, token, how, settle!, waits| sync_from!(path, token, how, settle!, waits, False)

	# `after_wait` is whether this run just waited for a period to open: a run
	# that waited and still finds it spent ends, naming the situation, rather than
	# waiting again (Drain.after_round)
	sync_from! : Str, Str, { all : Bool, relist : Bool }, (Str => Try(Settled, _)), Bool, Bool => Try(SyncResult, _)
	sync_from! = |path, token, how, settle!, waits, after_wait| {
		listed =
			if how.relist {
				list_phase!(path, token, how.all, waits)?
			} else if day_spent!(path)? {
				DaySpent
			} else {
				Listed({ counts: { relisted: 0, new_n: 0, updated_n: 0 }, pruned: 0 })
			}
		match listed {
			# A run that STARTS with the day's allowance spent has made no request.
			# A human run waits for the day like any spent period; otherwise the run
			# ends resumable regardless of the queue, since it has not looked.
			DaySpent => {
				ended = Db.now_secs!({})
				owed = how.relist or pending_streams!(path)? + pending_notes!(path)? + pending_routes!(path)? > 0
				match Drain.after_round({ stop: FromDrain(DailyCapReached), owed, progressed: False, after_wait, waits }) {
					Wait => {
						wait_for_window!(path, ended)?
						sync_from!(path, token, how, settle!, waits, True)
					}
					Finish => {
						settled = settle!(path)?
						finish!(path, { stop: FromDrain(DailyCapReached), counts: { relisted: 0, new_n: 0, updated_n: 0 }, pruned: 0, tally: no_tally, settled, owed_anyway: True, ended, requested: False, again: after_wait })
					}
				}
			}
			# what is owed after a refused list is the LISTING, so the run is resumable
			# whatever the queue says; a human run gets here only when a period it
			# waited for refused the list again
			Refused(r) => {
				ended = Db.now_secs!({})
				settled = settle!(path)?
				finish!(path, { stop: r.stop, counts: r.counts, pruned: 0, tally: no_tally, settled, owed_anyway: True, ended, requested: r.requested, again: waits })
			}
			Listed(l) => {
				owed = pending_streams!(path)? + pending_notes!(path)? + pending_routes!(path)?
				lim = read_limits!(path)?
				reads = load_reads!(path)?
				left = (lim.reads_per_window - reads.window).min(lim.reads_per_quarter - reads.quarter)
				_ = if Drain.score_first(owed, left) {
					_ = settle!(path)?
					{}
				} else {
					{}
				}
				done = rounds!(path, token, how.all, settle!, waits, { after_wait, tally: no_tally, seen: no_seen })?
				finish!(path, { stop: FromDrain(done.stop), counts: l.counts, pruned: l.pruned, tally: done.tally, settled: done.settled, owed_anyway: False, ended: done.ended, requested: True, again: done.again })
			}
		}
	}

	# The activity list, the first step of every sync and setup's `activities` step:
	# every page, then the prune of what Strava no longer lists and the watermark.
	ListPhase : [DaySpent, Refused({ counts : ListCounts, stop : Drain.SyncStop, requested : Bool }), Listed({ counts : ListCounts, pruned : U64 })]

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
			listed = list_all!(path, token, after_param, started, waits, { relisted: 0, new_n: 0, updated_n: 0, rate_limited: False, page: 1, requested: False }, False)?
			counts = { relisted: listed.relisted, new_n: listed.new_n, updated_n: listed.updated_n }
			match listed.stop {
				# A refused list stops the run HERE, before pruning and before the drain
				# (#235). PRUNE removes what the listing did not re-list, so running it on a
				# partial list would delete activities that exist and were simply not
				# reached; the watermark must not advance past activities the run never
				# saw; and the drain would spend a refused budget. The pages already
				# upserted are kept and reported.
				Refused(stop) => Ok(Refused({ counts, stop, requested: listed.requested }))
				Listed => {
					pruned = prune_deleted!(path, started, window_start)?
					Db.config_set!(path, "last_sync_epoch", I64.to_str(started))?
					Ok(Listed({ counts, pruned }))
				}
			}
		}
	}

	# The payload, with every queue re-measured from the database: a hardcoded 0 is a
	# way to silently zero an absence. `ended` is when the run's last read was made,
	# before the analyze after it, so the time it names to continue is the window
	# that read was in rather than one an analyze ran on into.
	finish! : Str, { stop : Drain.SyncStop, counts : ListCounts, pruned : U64, tally : Tally, settled : Settled, owed_anyway : Bool, ended : I64, requested : Bool, again : Bool } => Try(SyncResult, _)
	finish! = |path, f| {
		ps = pending_streams!(path)?
		pn = pending_notes!(path)?
		pr = pending_routes!(path)?
		resumable : Bool
		resumable = f.owed_anyway or ps > 0 or pn > 0 or pr > 0
		resume_epoch = resume_for!(path, f.stop, resumable, f.ended)?
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
		Ok({ payload, stop: f.stop, resume_epoch, settled: f.settled, requested: f.requested, again: f.again })
	}

	# when a run that ended with `stop` at `ended` can continue, 0 for never
	resume_for! : Str, Drain.SyncStop, Bool, I64 => Try(I64, _)
	resume_for! = |path, stop, owed, ended| {
		p = periods!({})
		at_end = Drain.roll_reads(load_reads!(path)?, ended, p)
		Ok(Drain.resume_epoch(stop, owed, { window: Drain.next_read_at(at_end, read_limits!(path)?, ended, p), day: Drain.next_day_for(at_end, read_limits!(path)?, ended, p) }))
	}

	# One read window's worth of fetches, then analyze, then either the next window
	# (a human run) or the end. Descriptions drain only after a COMPLETE streams
	# drain, and routes after complete descriptions: all three draw on one read
	# window, and a drain that stopped on it would spend its refusal a second time.
	# The run's stop is whichever drain stopped it: a drain that never ran inherits
	# the stop of the one before it. The wait is timed from the round's last read,
	# not from the end of the analyze after it.
	rounds! : Str, Str, Bool, (Str => Try(Settled, _)), Bool, { after_wait : Bool, tally : Tally, seen : Seen } => Try({ stop : Drain.StopReason, tally : Tally, settled : Settled, ended : I64, again : Bool }, _)
	rounds! = |path, token, all, settle!, waits, r| {
		t = r.tally
		pull = drain_missing!(path, token, Streams, all, (t.streams + t.streams_skipped).to_u64_wrap(), r.seen.streams)?
		notes =
			match pull.stopped {
				Complete => drain_missing!(path, token, Notes, all, (t.notes + t.notes_skipped).to_u64_wrap(), r.seen.notes)?
				_ => { stored: 0, skipped: 0, stopped: pull.stopped, asked: [] }
			}
		routes =
			match notes.stopped {
				Complete => drain_missing!(path, token, Routes, all, (t.routes + t.routes_skipped).to_u64_wrap(), r.seen.routes)?
				_ => { stored: 0, skipped: 0, stopped: notes.stopped, asked: [] }
			}
		ended = Db.now_secs!({})
		tally = {
			streams: t.streams + pull.stored,
			streams_skipped: t.streams_skipped + pull.skipped,
			notes: t.notes + notes.stored,
			notes_skipped: t.notes_skipped + notes.skipped,
			routes: t.routes + routes.stored,
			routes_skipped: t.routes_skipped + routes.skipped,
		}
		seen = {
			streams: List.concat(r.seen.streams, pull.asked),
			notes: List.concat(r.seen.notes, notes.asked),
			routes: List.concat(r.seen.routes, routes.asked),
		}
		settled = settle!(path)?
		progressed = pull.stored + pull.skipped + notes.stored + notes.skipped + routes.stored + routes.skipped > 0
		owed = owed_this_run!(path, all, seen)?
		match Drain.after_round({ stop: FromDrain(routes.stopped), owed, progressed, after_wait: r.after_wait, waits }) {
			# `again`: a human run that waited, and found the period it waited for
			# refusing its first read
			Finish => Ok({ stop: routes.stopped, tally, settled, ended, again: waits and r.after_wait and !progressed and routes.stopped != Complete })
			Wait => {
				wait_for_window!(path, ended)?
				rounds!(path, token, all, settle!, waits, { after_wait: True, tally, seen })
			}
		}
	}

	# whether any queue still holds an activity this run has not asked for
	owed_this_run! : Str, Bool, Seen => Try(Bool, _)
	owed_this_run! = |path, all, seen| {
		fresh = |ids, asked| List.any(ids, |id| !(List.contains(asked, id)))
		streams = queue_ids!(path, Streams, all)?
		notes = queue_ids!(path, Notes, all)?
		routes = queue_ids!(path, Routes, all)?
		Ok(fresh(streams, seen.streams) or fresh(notes, seen.notes) or fresh(routes, seen.routes))
	}

	# Wait for the next read window or day: a spinner beside the local time the
	# next batch starts and the time left, redrawn about once a second, replaced by
	# its result when the period opens. `from` is when the period filled; the
	# wait is for whichever period is spent (Drain.next_read_at), and a spent day
	# says so on the line, its wait being hours rather than minutes.
	wait_for_window! : Str, I64 => Try({}, _)
	wait_for_window! = |path, from| {
		p = periods!({})
		lim = read_limits!(path)?
		at_from = Drain.roll_reads(load_reads!(path)?, from, p)
		until = Drain.next_read_at(at_from, lim, from, p)
		daily = Drain.may_read(at_from, lim) == DayFull
		at = Render.local_time(until, Db.time_mode_offset(Db.resolve_time_mode!(path)), Db.now_secs!({}))
		wait_ticks!(daily, until, at, 0)?
		Output.step_done!(if (daily) "daily allowance" else "waiting for Strava", if (daily) "returned ${at}; next batch started" else "next batch started at ${at}")
	}

	wait_ticks! : Bool, I64, Str, U64 => Try({}, _)
	wait_ticks! = |daily, until, at, tick| {
		left_ms = until * 1000 - Db.now_millis!({})
		if left_ms <= 0 {
			Ok({})
		} else {
			Output.wait_frame!({ daily, tick, at, left: (left_ms + 999) // 1000 })?
			Sleep.millis!((left_ms.min(1000)).to_u64_wrap())?
			wait_ticks!(daily, until, at, tick + 1)
		}
	}

	# The whole activity list, behind a spinner that turns once per page. A human
	# run refused by the window waits for the next one and asks for the refused page
	# again; the pages already listed are kept, so nothing is listed twice.
	list_all! : Str, Str, Str, I64, Bool, PageAcc, Bool => Try({ relisted : U64, new_n : U64, updated_n : U64, requested : Bool, stop : [Listed, Refused(Drain.SyncStop)] }, _)
	list_all! = |path, token, after_param, stamp, waits, acc, after_wait| {
		got = fetch_pages!(path, token, after_param, stamp, acc)?
		result = Render.list_result({ checked: got.relisted, new: got.new_n, updated: got.updated_n })
		out = |stop| { relisted: got.relisted, new_n: got.new_n, updated_n: got.updated_n, requested: got.requested, stop }
		if !(got.rate_limited) {
			Output.step_done!("activity list", result)?
			Ok(out(Listed))
		} else {
			# WHICH limit stopped the list: the day's allowance spent means its
			# remedy is midnight UTC, and its own tag says both facts at once
			stop = if (day_spent!(path)?) ListDailyCapReached else ListRateLimited
			Output.step_done!("activity list", "${result} so far, then the read window was spent")?
			match Drain.after_round({ stop, owed: True, progressed: got.relisted > acc.relisted, after_wait, waits }) {
				Finish => Ok(out(Refused(stop)))
				Wait => {
					wait_for_window!(path, Db.now_secs!({}))?
					list_all!(path, token, after_param, stamp, waits, { ..got, rate_limited: False }, True)
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

	# One queue: the activities a kind still owes, in the order they are asked for.
	queue_ids! : Str, DrainKind, Bool => Try(List(I64), _)
	queue_ids! = |path, kind, all|
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
				})
			Notes =>
			# WIDER than pending_notes! on purpose, where the Streams queue
			# mirrors its pending count on a plain sync. A description is written
			# AFTER the activity — the athlete finishes, syncs, and pastes
			# the breakdown that evening — and can be edited any time, so a
			# stored copy inside the rolling window the listing re-checks is
			# re-read once a run and an edit self-heals (#519). Outside the
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
				})
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
				})
		}

	# ONE stream loop for the whole engine (#232). Separate loops drift, and every
	# rate-limit inconsistency lives in that drift. No per-run cap: one drain walks
	# its queue until a read window fills, and sync! decides whether the run waits
	# for the next window or ends there.
	#
	# fetch time/HR/watts/altitude/distance streams for the activities
	# stream_queue_where selects; pacing bounds the run (see read_limits!). altitude
	# + distance are requested EXPLICITLY — they feed grade-adjusted pace / NGP (ADR
	# 0003). To force a re-pull, DELETE FROM streams (mirror tier) and let the next
	# sync refetch.
	#
	# `base` is how many of this kind earlier rounds of the run already retired, so
	# the bar counts the whole run rather than restarting each window; `asked` is
	# the ids earlier rounds already asked for, which this drain leaves out.
	drain_missing! : Str, Str, DrainKind, Bool, U64, List(I64) => Try(DrainOutcome, _)
	drain_missing! = |path, token, kind, all, base, asked| {
		ids = List.keep_if(queue_ids!(path, kind, all)?, |id| !(List.contains(asked, id)))
		total = base + List.len(ids)
		# an immediate frame BEFORE the first request: narrating only after a response
		# returns shows nothing for exactly as long as a stall lasts
		_ = if List.len(ids) > 0 {
			Output.narrate!(drain_label(kind), base, total)?
		} else {
			{}
		}
		# the counts carried in from the database, each stamped with its period
		reads = load_reads!(path)?
		match drain_queue!(path, token, kind, ids, { reads, periods: periods!({}), stored: 0, skipped: 0, asked: [], total, opened: List.len(ids) > 0, refreshes: 0 }) {
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

	# The read counts as they stand now, from the database. Four counts, each in
	# two rows, the count and the period it belongs to: the UTC day
	# (`strava_reads_today`, `strava_reads_day`), the paced day
	# (`strava_reads_daywin`, `strava_reads_daywin_mark`), the read window
	# (`strava_reads_window`, `strava_reads_window_mark`) and Strava's
	# quarter-hour (`strava_reads_quarter`, `strava_reads_quarter_mark`). A stamp
	# that is not the current period's means nothing spent in this one, so the
	# reset is free and nothing has to run at midnight or on the mark. Persisted,
	# because the limits are Strava's across every run: a run that started a
	# second after another one filled the window must not get a fresh one.
	load_reads! : Str => Try(Drain.Reads, _)
	load_reads! = |path| {
		now = Db.now_secs!({})
		p = periods!({})
		day = now // 86400
		dmark = Drain.window_mark(now, p.day)
		wmark = Drain.window_mark(now, p.window)
		qmark = Drain.window_mark(now, Drain.window_secs_default)
		limit =
			match stored_limit!(path)? {
				Reported(l) => l
				Unreported => Drain.limit_default
			}
		today = reads_today!(path, day)?
		dtoday = stamped_count!(path, "strava_reads_daywin", dmark, limit.day)?
		window = stamped_count!(path, "strava_reads_window", wmark, limit.window)?
		quarter = stamped_count!(path, "strava_reads_quarter", qmark, limit.window)?
		reads = { day, today, dmark, dtoday: dtoday.count, wmark, window: window.count, qmark, quarter: quarter.count }
		# a damaged row is written back as it now reads, so it is repaired once
		# rather than read past on every run
		_ = if dtoday.repaired or window.repaired or quarter.repaired {
			save_reads!(path, reads)?
		} else {
			{}
		}
		Ok(reads)
	}

	# a period's count from its two rows, `<key>` and `<key>_mark` (Drain.stamped)
	stamped_count! : Str, Str, I64, I64 => Try({ count : I64, repaired : Bool }, _)
	stamped_count! = |path, key, mark_now, limit| {
		known = |r|
			match r {
				Known(n) => Known(n)
				Corrupt(_) => Corrupt
			}
		mark = known(config_reads!(path, "${key}_mark")?)
		count = known(config_reads!(path, key)?)
		Ok(Drain.stamped(mark, count, mark_now, limit))
	}

	# Write the counts back after EVERY read, not at the end of the run: reads are
	# spent at Strava the moment they happen, so a drain that dies mid-way must not
	# forget the ones it made — losing them drifts the counter UNDER the true total,
	# the direction that overshoots a limit. One transaction for the eight rows.
	#
	# Each count is written against the period it BELONGS to, which is not always
	# the one it is written in: Drain.roll_reads restamps a count when its period
	# turns, so a run in flight at UTC midnight or across a mark does not hand the
	# new period the old one's total.
	save_reads! : Str, Drain.Reads => Try({}, _)
	save_reads! = |path, r| {
		row = |key, n| { key, value: I64.to_str(n) }
		rows = [
			row("strava_reads_day", r.day),
			row("strava_reads_today", r.today),
			row("strava_reads_daywin_mark", r.dmark),
			row("strava_reads_daywin", r.dtoday),
			row("strava_reads_window_mark", r.wmark),
			row("strava_reads_window", r.window),
			row("strava_reads_quarter_mark", r.qmark),
			row("strava_reads_quarter", r.quarter),
		]
		Sql.transaction!(Path.utf8(path), |run!| save_rows!(run!, rows))
	}

	save_rows! = |run!, rows|
		match rows {
			[] => Ok({})
			[r, .. as rest] => {
				_ = run!("INSERT OR REPLACE INTO config (key, value) VALUES (:key, :value)", [{ name: ":key", value: String(r.key) }, { name: ":value", value: String(r.value) }])?
				save_rows!(run!, rest)
			}
		}

	# The limits Strava last reported, in three rows (`strava_limit_window`,
	# `strava_limit_day`, and `strava_limit_app`, the client id they were
	# reported to): Strava sets limits per app and raises them on request, so
	# the last report is the best knowledge before a run's first response, and
	# only for the app it came from, so an athlete who authorizes another app
	# does not inherit the first one's. Absent, unreadable, not positive or
	# another app's, none is reported, and the documented limits apply
	# (Drain.caps_for).
	stored_limit! : Str => Try(Drain.Usage, _)
	stored_limit! = |path| {
		client = (client_cred!(path, "STRAVA_CLIENT_ID", "strava_client_id")) ?? ""
		stored_app =
			match Db.config_opt!(path, "strava_limit_app")? {
				Found(v) => Str.trim(v)
				NotFound => ""
			}
		if stored_app != client {
			Ok(Unreported)
		} else {
			match (config_reads!(path, "strava_limit_window")?, config_reads!(path, "strava_limit_day")?) {
				(Known(w), Known(d)) if w > 0 and d > 0 => Ok(Reported({ window: w, day: d }))
				_ => Ok(Unreported)
			}
		}
	}

	# keep the limit a response reported, when it reported its usage beside it
	# (Drain.adopt), stamped with the app it was reported to
	note_limit! : Str, List(Str), Drain.Usage => Try({}, _)
	note_limit! = |path, headers, usage|
		match Drain.adopt(usage, Drain.limit_of(headers)) {
			Reported(l) => {
				Db.config_set!(path, "strava_limit_app", (client_cred!(path, "STRAVA_CLIENT_ID", "strava_client_id")) ?? "")?
				Db.config_set!(path, "strava_limit_window", I64.to_str(l.window))?
				Db.config_set!(path, "strava_limit_day", I64.to_str(l.day))
			}
			Unreported => Ok({})
		}

	# is the allowance already spent, WITHOUT spending anything to find out? The day
	# is knowable from the database with zero requests, so a run that starts on a
	# spent day makes none.
	day_spent! : Str => Try(Bool, _)
	day_spent! = |path| Ok(Drain.may_read(load_reads!(path)?, read_limits!(path)?) == DayFull)

	# takes the day rather than reading its own clock, so a caller that already has
	# one cannot compare a count against a different day than it saves against.
	reads_today! = |path, day_now| {
		# BOTH rows get the conservative reading: unreadable means today, and today
		# means the count is consulted.
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
					Ok((read_limits!(path)?).reads_per_utc_day)
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

	# The caps a run paces to, from the limit Strava last reported less a margin,
	# or its documented limits before it has reported one (Drain.caps_for). The
	# caps on Strava's own quarter-hour and day no seam lowers or shortens:
	# whatever a test does to the periods it waits for, no run of stride's spends
	# more than these in a real quarter-hour or UTC day. The paced window and day
	# start at the same caps, and STRIDE_READS_PER_WINDOW / STRIDE_READS_PER_DAY
	# can only lower them, so the e2e suite reaches each stop in a fixture.
	read_limits! : Str => Try(Drain.Limits, _)
	read_limits! = |path| {
		caps = Drain.caps_for(stored_limit!(path)?)
		Ok({
			reads_per_window: env_i64!("STRIDE_READS_PER_WINDOW", caps.quarter),
			reads_per_quarter: caps.quarter,
			reads_per_day: env_i64!("STRIDE_READS_PER_DAY", caps.day),
			reads_per_utc_day: caps.day,
		})
	}

	# the length in seconds of the read window a run paces by and waits for;
	# STRIDE_WINDOW_SECONDS can only shorten it, so the e2e drivers can cross
	# several windows in seconds, and reads_per_quarter holds whatever it is
	window_secs! : {} => I64
	window_secs! = |{}| env_i64!("STRIDE_WINDOW_SECONDS", Drain.window_secs_default)

	# the paced window and day; STRIDE_DAY_SECONDS can only shorten the day, so
	# the e2e drivers can wait out a daily reset in seconds, and
	# reads_per_utc_day holds whatever it is
	periods! : {} => Drain.Periods
	periods! = |{}| { window: window_secs!({}), day: env_i64!("STRIDE_DAY_SECONDS", Drain.day_secs_default) }

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
	# Per-drain state. `reads` = the counts that pace the drain (Drain.Reads),
	# loaded from the database when it starts, rolled to the current periods at
	# the top of each iteration (Drain.roll_reads) and written back after every
	# read; `periods` = the lengths of the window and day it paces by. `stored`/`skipped`
	# = what the reads produced, which is not the same as the counts: pacing is
	# about READS (a 404 spends a read and stores a marker) while the payload
	# reports WORK. `asked` = the ids this drain asked for, which later rounds of
	# the run leave out. `total` is the bar's denominator and `opened` whether a
	# bar was drawn, so it is closed exactly once.
	DrainState : { reads : Drain.Reads, periods : Drain.Periods, stored : I64, skipped : I64, asked : List(I64), total : U64, opened : Bool, refreshes : I64 }

	# Walk the queue once — walking a LIST (not re-querying "next missing") means an
	# unstorable body is skipped, not refetched forever. The pacing DECISIONS are
	# pure (Drain.may_read before a read, Drain.decide after it); this is the thin
	# effectful skin. The four ways a drain ends are RETURNED, because "why did it
	# stop?" is not derivable from the counts; a drain CANNOT report a list
	# refusal, which lives on Drain.SyncStop.
	DrainOutcome : { stored : I64, skipped : I64, stopped : Drain.StopReason, asked : List(I64) }

	# what one queue item asks Strava for, and what storing the answer means.
	# ONE loop serves every kind — the pacing, refresh, 429 and skip policies
	# are shared by construction, which is the anti-drift rule the loop's own
	# comment states. Streams fetch the five analysis streams; Notes fetch the
	# activity DETAIL for its description (the strength share text, #478);
	# Routes fetch the GPS coordinates and their times (#700).
	DrainKind : [Streams, Notes, Routes]

	drain_queue! : Str, Str, DrainKind, List(I64), DrainState => Try(DrainOutcome, _)
	drain_queue! = |path, token, kind, ids, st_in| {
		# RE-READ each iteration, not captured once: a drain can outlive UTC midnight
		# or cross a mark, and the counts belong to the periods they were spent in
		st = { ..st_in, reads: Drain.roll_reads(st_in.reads, Db.now_secs!({}), st_in.periods) }
		lim = read_limits!(path)?
		ended! = |stopped, s| {
			bar_done!(s)
			Ok({ stored: s.stored, skipped: s.skipped, stopped, asked: s.asked })
		}
		match ids {
			[] => ended!(Complete, st)
			[id, .. as rest] =>
			# BEFORE the read: a count already at a limit, by this run or an
			# earlier one, refuses it, so no run can pass Strava's limits
				match Drain.may_read(st.reads, lim) {
					DayFull => ended!(DailyCapReached, st)
					WindowFull => ended!(BudgetReached, st)
					Go => {
						uri =
							match kind {
								Streams => "${api_base!({})}/api/v3/activities/${I64.to_str(id)}/streams?keys=time,heartrate,watts,altitude,distance&key_by_type=true"
								Notes => "${api_base!({})}/api/v3/activities/${I64.to_str(id)}"
								Routes => "${api_base!({})}/api/v3/activities/${I64.to_str(id)}/streams?keys=latlng,time&key_by_type=true"
							}
						# CHARGED before the request: a transport failure counts a read
						# Strava never saw, the direction a limit tolerates
						_ = save_reads!(path, Drain.charge(st.reads, Unreported))?
						resp = send_bearer!(uri, token)?
						headers = List.map(Response.headers(resp), |h| h.to_str())
						usage = Drain.usage_of(headers)
						# the limit this response reported paces this read's decision and
						# every read after it
						_ = note_limit!(path, headers, usage)?
						lim_now = read_limits!(path)?
						spent = Drain.charge(st.reads, usage)
						match Drain.decide({ status: Response.status(resp), reads: st.reads, usage }, lim_now) {
							Refresh => {
								# the 401'd read is spent too, and this arm RETRIES the same id,
								# so the retry charges its own read
								_ = save_reads!(path, spent)?
								# Long runs outlive the ~6h access token; refresh and retry the same id.
								# BOUNDED: this arm recurses on the same id, so a persistently 401ing
								# activity (revoked scope, private without activity:read_all) would spin
								# until the counts stopped it. Same token back is a real auth problem.
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
										drain_queue!(path, fresh, kind, ids, { ..st, reads: spent, refreshes: st.refreshes + 1 })
									}
								}
							}
							# A 429 ends this drain, never by sleeping here: the rows already
							# stored are durable, and sync! decides whether the run waits for the
							# next window or ends there. The 429'd read is a REAL read, so it is
							# counted, and the daily allowance is recognised from the 429 as well
							# as from the count — see Drain.decide.
							DailyCapReached => {
								_ = save_reads!(path, spent)?
								ended!(DailyCapReached, st)
							}
							RateLimited => {
								_ = save_reads!(path, spent)?
								ended!(RateLimited, st)
							}
							Store({ reads, after }) => {
								save_reads!(path, reads)?
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
								next = { ..st, reads, stored: counted.stored, skipped: counted.skipped, asked: List.append(st.asked, id) }
								match after {
									# a read window is full: the round ends, and the run waits
									# for the next window or names when it opens
									WindowFull => ended!(BudgetReached, next)
									# the DAILY allowance, which ends the run until midnight UTC
									DayFull => ended!(DailyCapReached, next)
									Continue => drain_queue!(path, token, kind, rest, next)
								}
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
	# `requested` is whether any page was asked for.
	PageAcc : { relisted : U64, new_n : U64, updated_n : U64, rate_limited : Bool, page : U64, requested : Bool }

	# A 429 on the LIST ends the listing the way a 429 on a stream ends a drain
	# (#235), and so does a read window or day already spent before a page is asked
	# for: pages already upserted are kept and reported, `rate_limited` rides the
	# accumulator, and the caller reports a successful partial run. Propagating
	# instead would make one upstream condition behave two ways in one invocation —
	# exit 1 on the list, a success envelope on a stream.
	fetch_pages! : Str, Str, Str, I64, PageAcc => Try(PageAcc, _)
	fetch_pages! = |path, token, after_param, stamp, acc| {
		page = acc.page
		reads = load_reads!(path)?
		match Drain.may_read(reads, read_limits!(path)?) {
			Go => {
				uri = "${api_base!({})}/api/v3/athlete/activities?per_page=${(per_page).to_str()}&page=${(page).to_str()}${after_param}"
				# BEFORE the request, so a stalled request shows a frame rather than nothing
				Output.spin!("activity list", page)?
				# COUNTED, because Strava counts it: the list and the streams draw on the
				# same limits, and charged BEFORE the request like every read
				_ = save_reads!(path, Drain.charge(reads, Unreported))?
				resp = send_bearer!(uri, token)?
				headers = List.map(Response.headers(resp), |h| h.to_str())
				usage = Drain.usage_of(headers)
				_ = save_reads!(path, Drain.charge(reads, usage))?
				_ = note_limit!(path, headers, usage)?
				read = { ..acc, requested: True }
				# Only 429 is a partial run. Every other status propagates, including a 401 —
				# this function has NO refresh arm, and does not need one: get_valid_token!
				# refreshes proactively at run start with a 60-second margin, and the listing
				# takes seconds. A 500 is not something to report as a successful partial run.
				if Response.status(resp) == 429 {
					Ok({ ..read, rate_limited: True })
				} else {
					body = ok_body(resp)?
					text = Str.from_utf8(body).map_err(|_| ActivityDecodeFailed(page))?
					acts = decode_page(text).map_err(|_| ActivityDecodeFailed(page))?
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
			_ => Ok({ ..acc, rate_limited: True })
		}
	}

	# A page of the activity list. `max_heartrate` is the one field setup reads
	# that the rest of the engine does not, and a value the decoder cannot read
	# (null, a string) fails the whole record, so a page that will not decode with
	# it is decoded again without it: every activity on that page is kept, with
	# its maximum heart rate absent.
	decode_page : Str -> Try(List(ActivitySummary), _)
	decode_page = |text| {
		full : Try(List(ActivitySummary), _)
		full = Json.parse(text)
		match full {
			Ok(acts) => Ok(acts)
			Err(_) => {
				bare : Try(List(ActivitySummaryNoMaxHr), _)
				bare = Json.parse(text)
				bare.map_ok(|acts| List.map(acts, |a| with_no_max_hr(a)))
			}
		}
	}

	ActivitySummaryNoMaxHr : {
		id : I64,
		name : Str,
		sport_type : Str,
		start_date_local : Str,
		moving_time : I64,
		distance : F64,
		total_elevation_gain : F64,
		suffer_score : Try(F64, [Missing]),
		average_watts : Try(F64, [Missing]),
		device_watts : Try(Bool, [Missing]),
		average_heartrate : Try(F64, [Missing]),
		weighted_average_watts : Try(F64, [Missing]),
	}

	with_no_max_hr : ActivitySummaryNoMaxHr -> ActivitySummary
	with_no_max_hr = |a| {
		id: a.id,
		name: a.name,
		sport_type: a.sport_type,
		start_date_local: a.start_date_local,
		moving_time: a.moving_time,
		distance: a.distance,
		total_elevation_gain: a.total_elevation_gain,
		suffer_score: a.suffer_score,
		average_watts: a.average_watts,
		device_watts: a.device_watts,
		average_heartrate: a.average_heartrate,
		weighted_average_watts: a.weighted_average_watts,
		max_heartrate: Err(Missing),
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
