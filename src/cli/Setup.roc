import Db
import Output
import Strava
import Analyze
import Plan
import ReportHealth
import Config
import pf.Stdin
import pf.Env
import pf.OsStr
import pf.Cmd
import pf.Path
import pf.Tcp
import pf.Duration

# ── `stride setup` (#644): the first run, one step at a time ─────────────
#
# Walks Config.setup_steps and stops at the first one the database does not
# already satisfy, so a rerun resumes and repeats nothing. Two ways to drive it:
#
#   human   bare `stride setup` prompts for each value, receives the Strava
#           code on a loopback listener (falling back to a paste), and runs
#           the first sync and analyze itself.
#   machine `stride setup --json` never reads stdin. Each call answers with
#           the next step and the values it needs; `stride setup key=value`
#           supplies one (client_id, client_secret, code, timezone,
#           threshold_hr or max_hr). One envelope per call, so the sync step
#           is answered with the commands to run rather than run inline.
Setup :: [].{
	SetupInput : [None, Pair(Str, Str)]

	setup! : SetupInput => Try({}, _)
	setup! = |input| {
		home = Db.home_dir!({})?
		db_existed = ((Path.is_file!(Path.utf8("${home}/.stride/db.sqlite"))) ?? False)
		_ = Path.create_dir!(Path.utf8("${home}/.stride"))
		path = Db.open_db!({})?
		# credentials supplied through the environment are stored like `key=`
		# ones, so the next call (with or without them) sees the same app
		stored = store_env_creds!(path)?
		ran0 = List.concat(if (db_existed) [] else ["init"], stored)
		applied =
			match input {
				None => Ok("")
				Pair(key, val) => apply!(path, key, val).map_ok(|_| key)
			}
		match applied {
			Err(BadInput(code, msg)) => Output.err_out!(code, msg)
			Err(other) => Err(other)
			Ok(key) => {
				ran = if (key == "") ran0 else List.append(ran0, key)
				human = !(Output.json_mode!({}))
				when_bare = match input {
					None => True
					Pair(_, _) => False
				}
				if human and when_bare {
					walk!(path)?
					report!(path, ran)
				} else {
					report!(path, ran)
				}
			}
		}
	}

	# ── state ──────────────────────────────────────────────────────────
	state! : Str => Try(Config.SetupState, _)
	state! = |path| {
		has! = |key|
			match Db.config_opt!(path, key)? {
				Found(v) => Ok(Str.trim(v) != "")
				NotFound => Ok(False)
			}
		cred! = |env_name, key|
			match Env.var_str!(OsStr.from_str(env_name)) {
				Ok(v) if Str.trim(v) != "" => Ok(True)
				_ => has!(key)
			}
		client_id = cred!("STRAVA_CLIENT_ID", "strava_client_id")?
		client_secret = cred!("STRAVA_CLIENT_SECRET", "strava_client_secret")?
		token = has!("strava_refresh_token")?
		# done only when the engine resolves it, the same test doctor reports
		timezone = Db.timezone_known!(path)
		z1 = has!("hr_z1_max")?
		z2 = has!("hr_z2_max")?
		z3 = has!("hr_z3_max")?
		z4 = has!("hr_z4_max")?
		synced = has!("last_sync_epoch")?
		Ok({ db: True, client: client_id and client_secret, token, timezone, zones: z1 and z2 and z3 and z4, synced })
	}

	# ── one supplied value ─────────────────────────────────────────────
	apply! : Str, Str, Str => Try({}, _)
	apply! = |path, key, raw| {
		val = Str.trim(raw)
		if val == "" {
			Err(BadInput("bad_value", "${key}= needs a value"))
		} else if key == "client_id" {
			set_cred!(path, "strava_client_id", val)
		} else if key == "client_secret" {
			set_cred!(path, "strava_client_secret", val)
		} else if key == "code" {
			match Config.oauth_code(val) {
				Err(NoCode) => Err(BadInput("bad_value", "code= takes the code, or the whole address the browser landed on; that one carries no code (an error=access_denied address means Authorize was not clicked)"))
				Ok(code) =>
					match (Strava.client_cred!(path, "STRAVA_CLIENT_ID", "strava_client_id"), Strava.client_cred!(path, "STRAVA_CLIENT_SECRET", "strava_client_secret")) {
						(Ok(id), Ok(secret)) => Strava.exchange_code!(path, id, secret, code).map_ok(|_| {})
						(Err(MissingEnv(_)), _) | (_, Err(MissingEnv(_))) => Err(BadInput("missing_client_creds", "supply client_id= and client_secret= before code="))
						(Err(other), _) | (_, Err(other)) => Err(other)
					}
			}
		} else if key == "timezone" {
			if zone_known!(val) {
				Db.config_set!(path, "timezone", val)
			} else {
				Err(BadInput("bad_value", "timezone= takes an IANA zone name such as America/Chicago; '${val}' is not in the system zone database"))
			}
		} else if key == "threshold_hr" or key == "max_hr" {
			match I64.from_str(val) {
				Ok(bpm) if Config.plausible_hr(bpm) => {
					bounds = Config.zone_bounds(if (key == "threshold_hr") Threshold(bpm) else Max(bpm))
					store_zones!(path, bounds)
				}
				_ => Err(BadInput("bad_value", "${key}= takes a heart rate in whole beats per minute between 35 and 220; got '${val}'"))
			}
		} else {
			Err(BadInput("unknown_key", "setup takes client_id=, client_secret=, code=, timezone=, threshold_hr= or max_hr=; got '${key}='"))
		}
	}

	# a changed client id or secret belongs to a different app, so the tokens
	# the old one earned are cleared and authorize runs again
	set_cred! : Str, Str, Str => Try({}, _)
	set_cred! = |path, key, val| {
		before = match Db.config_opt!(path, key)? {
			Found(v) => Str.trim(v)
			NotFound => ""
		}
		Db.config_set!(path, key, val)?
		if before != "" and before != val {
			Db.config_delete!(path, "strava_access_token")?
			Db.config_delete!(path, "strava_refresh_token")?
			Db.config_delete!(path, "strava_expires_at")
		} else {
			Ok({})
		}
	}

	# STRAVA_CLIENT_ID / STRAVA_CLIENT_SECRET in the environment are stored, through
	# set_cred! so a changed credential still clears the old app's tokens; the
	# keys stored are named in the run's `ran` list
	store_env_creds! : Str => Try(List(Str), _)
	store_env_creds! = |path| {
		one! = |env_name, key, label|
			match Env.var_str!(OsStr.from_str(env_name)) {
				Ok(v) if Str.trim(v) != "" => set_cred!(path, key, Str.trim(v)).map_ok(|_| [label])
				_ => Ok([])
			}
		id = one!("STRAVA_CLIENT_ID", "strava_client_id", "client_id")?
		secret = one!("STRAVA_CLIENT_SECRET", "strava_client_secret", "client_secret")?
		Ok(List.concat(id, secret))
	}

	# an empty answer keeps the stored value
	keep_or_set! : Str, Str, Str => Try({}, _)
	keep_or_set! = |path, key, val| if (val == "") Ok({}) else set_cred!(path, key, val)

	store_zones! : Str, List(I64) => Try({}, _)
	store_zones! = |path, bounds|
		List.map_try!(
			List.map_with_index(bounds, |b, i| { b, i }),
			|z| Db.config_set!(path, "hr_z${(z.i + 1).to_str()}_max", b_str(z.b)),
		).map_ok(|_| {})

	b_str : I64 -> Str
	b_str = |b| b.to_str()

	# a zone the system zone database names; with no zoneinfo directory to ask
	# (Windows), any name of the IANA shape passes
	zone_known! : Str => Bool
	zone_known! = |name|
		if name == "UTC" {
			True
		} else if !(Str.contains(name, "/")) or Str.contains(name, "..") {
			False
		} else if (Path.is_file!(Path.utf8("/usr/share/zoneinfo/UTC"))) ?? False {
			(Path.is_file!(Path.utf8("/usr/share/zoneinfo/${name}"))) ?? False
		} else {
			True
		}

	# the system's own zone: TZ, else the /etc/localtime link, else Windows'
	detect_zone! : {} => Str
	detect_zone! = |{}| {
		from_env = match Env.var_str!(OsStr.from_str("TZ")) {
			Ok(v) => Config.tz_from_env(v)
			Err(_) => Err(NoZone)
		}
		from_link! = |_|
			match Path.read_link!(Path.utf8("/etc/localtime")) {
				Ok(target) => Config.tz_from_link(Path.display(target))
				Err(_) => Err(NoZone)
			}
		found = match from_env {
			Ok(z) => Ok(z)
			Err(_) =>
				match from_link!({}) {
					Ok(z) => Ok(z)
					Err(_) =>
						match Cmd.new(OsStr.from_str("tzutil")).arg(OsStr.from_str("/g")).capture!() {
							Ok(out) => Config.tz_from_windows(out)
							Err(_) => Err(NoZone)
						}
				}
		}
		match found {
			Ok(z) if zone_known!(z) => z
			_ => ""
		}
	}

	# ── the machine answer ─────────────────────────────────────────────
	report! : Str, List(Str) => Try({}, _)
	report! = |path, ran| {
		s = state!(path)?
		next = Config.setup_next(s)
		client_id = (Strava.client_cred!(path, "STRAVA_CLIENT_ID", "strava_client_id")) ?? ""
		guide = step_guide(next, client_id)
		detected = if (next == "timezone") detect_zone!({}) else ""
		complete : Bool
		complete = next == "done"
		interactive : Bool
		interactive = next == "strava_app" or next == "authorize"
		Output.out!(
			{
				complete,
				next_step: next,
				interactive,
				needs: guide.needs,
				instruction: guide.instruction,
				authorize_url: guide.url,
				timezone_detected: detected,
				ran,
				steps: List.map(Config.setup_steps, |step| { step, done: Config.setup_done(s, step) }),
			},
			|p| render(p),
		)
	}

	step_guide : Str, Str -> { needs : List(Str), instruction : Str, url : Str }
	step_guide = |next, client_id|
		match next {
			"strava_app" => {
				needs: ["client_id", "client_secret"],
				instruction: "Create a Strava API app at https://www.strava.com/settings/api: any Application Name, Category \"Training\", Website http://localhost, Authorization Callback Domain localhost. Then pass its Client ID with `stride setup client_id=<id>`, and its Client Secret through the environment so it stays out of shell history: `STRAVA_CLIENT_SECRET=<secret> stride setup`.",
				url: "https://www.strava.com/settings/api",
			}
			"authorize" => {
				needs: ["code"],
				instruction: "Open authorize_url and click Authorize. The browser lands on a localhost address that fails to load; pass that whole address, quoted: `stride setup 'code=<address>'`.",
				url: Strava.authorize_url(client_id, "http://localhost"),
			}
			"timezone" => {
				needs: ["timezone"],
				instruction: "Confirm the athlete's timezone as an IANA name (timezone_detected is the system's): `stride setup timezone=<Area/City>`.",
				url: "",
			}
			"zones" => {
				needs: ["threshold_hr", "max_hr"],
				instruction: "Give one heart rate and the four zone bounds are derived from it: threshold HR (the average of an all-out 30 to 60 minute effort) with `stride setup threshold_hr=<bpm>`, or failing that maximum HR with `stride setup max_hr=<bpm>`.",
				url: "",
			}
			"sync" => {
				needs: [],
				instruction: "Run `stride sync`, then `stride analyze`. A long history spans several syncs: Strava limits reads per 15 minutes and per day, and each run says when to come back.",
				url: "",
			}
			_ => { needs: [], instruction: "Setup is complete. `stride doctor` shows the database's health.", url: "" }
		}

	render = |p| {
		marks = List.map(p.steps, |s| "  ${if (s.done) "[x]" else "[ ]"} ${s.step}")
		head = if (p.complete) "setup complete" else "next: ${p.next_step}"
		url = if (p.authorize_url == "") [] else ["", p.authorize_url]
		Str.join_with(List.join([["setup"], marks, ["", head, p.instruction], url]), "\n")
	}

	# ── the human walk ─────────────────────────────────────────────────
	# One prompt reader: stdin is read here and nowhere else in this module.
	ask! : Str => Try(Str, _)
	ask! = |prompt| {
		Output.human_write!(prompt)?
		line = Stdin.line!()?
		Ok(Str.trim(line))
	}

	# a secret read with terminal echo off, restored afterwards; with no
	# terminal to switch, it is read as typed
	ask_secret! : Str => Try(Str, _)
	ask_secret! = |prompt| {
		_ = Cmd.new(OsStr.from_str("sh")).args(List.map(["-c", "stty -echo < /dev/tty", "sh"], OsStr.from_str)).capture!()
		got = ask!(prompt)
		_ = Cmd.new(OsStr.from_str("sh")).args(List.map(["-c", "stty echo < /dev/tty", "sh"], OsStr.from_str)).capture!()
		Output.human_line!("")?
		got
	}

	walk! : Str => Try({}, _)
	walk! = |path| {
		s = state!(path)?
		next = Config.setup_next(s)
		if next == "done" {
			Ok({})
		} else {
			step!(path, next)?
			after = state!(path)?
			# a step that the athlete left unsatisfied ends the walk rather than
			# asking again forever; a rerun resumes there
			if (Config.setup_next(after) == next) Ok({}) else walk!(path)
		}
	}

	step! : Str, Str => Try({}, _)
	step! = |path, next|
		if next == "strava_app" {
			guide = step_guide("strava_app", "")
			Output.human_line!(guide.instruction)?
			id = ask!("Client ID: ")?
			secret = ask_secret!("Client Secret (not shown): ")?
			if id == "" or secret == "" {
				Output.human_line!("Both are needed; run `stride setup` again when you have them.")
			} else {
				set_cred!(path, "strava_client_id", id)?
				set_cred!(path, "strava_client_secret", secret)
			}
		} else if next == "authorize" {
			id = Strava.client_cred!(path, "STRAVA_CLIENT_ID", "strava_client_id")?
			secret = Strava.client_cred!(path, "STRAVA_CLIENT_SECRET", "strava_client_secret")?
			code = if (headless!({})) "" else (listen_code!(id)) ?? ""
			got = if (code != "") code else paste_code!(id)?
			if got == "" {
				Output.human_line!("No code arrived; run `stride setup` again to retry.")
			} else {
				match Strava.exchange_code!(path, id, secret, got) {
					Ok(_) => Output.human_line!("Authorized.")
					Err(e) => {
						Output.human_line!("Strava refused the code. If the Client ID or Secret was mistyped, enter them again; Enter keeps them.")?
						new_id = ask!("Client ID: ")?
						new_secret = ask_secret!("Client Secret (not shown): ")?
						if new_id == "" and new_secret == "" {
							Err(e)
						} else {
							keep_or_set!(path, "strava_client_id", new_id)?
							keep_or_set!(path, "strava_client_secret", new_secret)?
							Output.human_line!("Saved; run `stride setup` again to authorize with them.")
						}
					}
				}
			}
		} else if next == "timezone" {
			found = detect_zone!({})
			prompt = if (found == "") "Timezone (IANA name, e.g. America/Chicago): " else "Timezone [${found}]: "
			typed = ask!(prompt)?
			zone = if (typed == "") found else typed
			if zone_known!(zone) {
				Db.config_set!(path, "timezone", zone)
			} else {
				Output.human_line!("'${zone}' is not a zone this system knows; run `stride setup` again with a name like America/Chicago.")
			}
		} else if next == "zones" {
			thr = ask!("Threshold heart rate (average of an all-out 30-60 min effort), or Enter to give max HR instead: ")?
			typed = if (thr == "") ask!("Maximum heart rate: ")? else thr
			match I64.from_str(typed) {
				Ok(bpm) if Config.plausible_hr(bpm) => {
					bounds = Config.zone_bounds(if (thr == "") Max(bpm) else Threshold(bpm))
					store_zones!(path, bounds)?
					shown = Str.join_with(List.map(bounds, b_str), " / ")
					Output.human_line!("Zone upper bounds (z1..z4): ${shown} bpm; zone 5 is above the last. Adjust any with `stride config set hr_z<N>_max <bpm>`.")
				}
				_ => Output.human_line!("A heart rate is a whole number of beats per minute between 35 and 220; run `stride setup` again.")
			}
		} else if next == "sync" {
			Output.human_line!("First sync. A long history spans several runs: Strava limits reads per 15 minutes and per day, and each run says when to come back.")?
			Strava.sync!(False)?
			Analyze.analyze!(Plan.refresh_all_target_results!)?
			ReportHealth.doctor!({})
		} else {
			Ok({})
		}

	paste_code! : Str => Try(Str, _)
	paste_code! = |client_id| {
		url = Strava.authorize_url(client_id, "http://localhost")
		Output.human_line!("Open this address and click Authorize:")?
		Output.human_line!("   ${url}")?
		Strava.open_browser!(url)
		Output.human_line!("The browser lands on a localhost page that fails to load. Copy that whole address and paste it here.")?
		raw = ask!("address: ")?
		Ok((Config.oauth_code(raw)) ?? "")
	}

	# Receive the code on a loopback port: Strava redirects the browser to
	# http://127.0.0.1:<port>/, which the API app's `localhost` callback domain
	# covers. Waits five minutes for the redirect; any failure to listen or to
	# hear one answers Err, and the caller falls back to the paste.
	listen_code! : Str => Try(Str, _)
	listen_code! = |client_id| {
		state = random_state!({})?
		listener = Tcp.listen!("127.0.0.1", 0, Duration.seconds(5))?
		port = listener.local_port!()?
		url = Strava.authorize_url_state(client_id, "http://127.0.0.1:${port.to_str()}/", state)
		Output.human_line!("Click Authorize in the browser tab that just opened (address below if it did not):")?
		Output.human_line!("   ${url}")?
		Strava.open_browser!(url)
		accept_code!(listener, state, 6)
	}

	# no browser on this machine to receive a loopback redirect: an SSH
	# session, or Linux with no display server
	headless! : {} => Bool
	headless! = |{}| {
		set! = |name|
			match Env.var_str!(OsStr.from_str(name)) {
				Ok(v) => Str.trim(v) != ""
				Err(_) => Bool.False
			}
		linux = ((Path.is_dir!(Path.utf8("/proc"))) ?? Bool.False)
		set!("SSH_CONNECTION") or set!("SSH_TTY") or (linux and !(set!("DISPLAY")) and !(set!("WAYLAND_DISPLAY")))
	}

	# 16 random bytes as hex, the OAuth `state` one listen run expects back
	random_state! : {} => Try(Str, _)
	random_state! = |{}|
		match Cmd.new(OsStr.from_str("sh")).args(List.map(["-c", "od -An -N16 -tx1 /dev/urandom | tr -d ' \\n'", "sh"], OsStr.from_str)).capture!() {
			Ok(out) if Str.count_utf8_bytes(Str.trim(out)) == 32 => Ok(Str.trim(out))
			_ => Err(NoRandom)
		}

	# a browser can open a connection it never writes to, so a silent one is
	# dropped and the next accepted, a few times over
	accept_code! : Tcp.Listener, Str, U64 => Try(Str, _)
	accept_code! = |listener, state, tries|
		if tries == 0 {
			Err(NoCallback)
		} else {
			conn = listener.accept!({ accept_timeout: After(Duration.minutes(5)), io_timeout: Duration.seconds(10) })?
			match conn.read_line!() {
				Ok(line) => {
					target = (List.get(Str.split_on(line, " "), 1)) ?? ""
					state_ok = Config.oauth_param(target, "state") == Ok(state)
					match (if (state_ok) Config.oauth_code(target) else Err(NoCode)) {
						Ok(code) => {
							_ = conn.write_utf8!("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n<html><body style=\"font-family:sans-serif\"><h2>Stride is authorized.</h2><p>You can close this tab and return to the terminal.</p></body></html>")
							Ok(code)
						}
						Err(_) => {
							_ = conn.write_utf8!("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n<html><body style=\"font-family:sans-serif\"><h2>No authorization code arrived.</h2><p>Return to the terminal.</p></body></html>")
							if (Str.starts_with(target, "/favicon") or !(state_ok)) accept_code!(listener, state, tries - 1) else Err(NoCallback)
						}
					}
				}
				Err(_) => accept_code!(listener, state, tries - 1)
			}
		}
}
