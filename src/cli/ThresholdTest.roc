import Db
import Output
import Sql
import Streams
import pf.Path
import Metrics
import Render
import core.Sports

# ── threshold tests (ADR 0020) ───────────────────────────────────────
#
# `stride test <activity_id> <kind>` marks a session as a test the athlete rode,
# ran or swam all-out, and stores the threshold it yields; `stride test remove`
# unmarks it. Analyze reads the stored thresholds through period_ftp_sql and
# period_threshold_sql, so the next analyze rescores exactly the sessions a mark
# or an unmark moves. The threshold is computed here, once, from the session's
# stored streams, and kept as the athlete accepted it.
ThresholdTest :: [].{

	mark! : Str, Str, Bool => Try({}, _)
	mark! = |id_str, kind, apply_zones| {
		path = Db.open_db!({})?
		match (Metrics.arg_i64(id_str), Metrics.test_signal(kind)) {
			(Err(_), _) => Output.err_out!("bad_id", "test needs an activity id: test <activity_id> <${Str.join_with(Metrics.test_kinds, "|")}> [--apply-zones]")
			(_, Err(_)) => Output.err_out!("bad_test_kind", "'${kind}' is not a test kind — one of ${Str.join_with(Metrics.test_kinds, ", ")}")
			(Ok(activity_id), Ok(signal)) =>
				if apply_zones and signal != "hr" {
					Output.err_out!("zones_need_lthr", "--apply-zones sets heart-rate zones from a lactate-threshold heart rate, which only a tt30 test measures; ${kind} sets a ${signal} threshold")
				} else {
					match session!(path, activity_id)? {
						Err(NotFound) => Output.err_out!("activity_not_found", "no activity ${I64.to_str(activity_id)} in the db — `stride sync` first?")
						Ok(s) => mark_session!(path, s, kind, signal, apply_zones)
					}
				}
		}
	}

	remove! : Str => Try({}, _)
	remove! = |id_str| {
		path = Db.open_db!({})?
		match Metrics.arg_i64(id_str) {
			Err(_) => Output.err_out!("bad_id", "test remove needs an activity id: test remove <activity_id>")
			Ok(activity_id) =>
				if !(is_marked!(path, activity_id)?) {
					Output.err_out!("test_not_found", "activity ${I64.to_str(activity_id)} is not marked as a test")
				} else {
					Sql.execute!({
						path: Path.utf8(path),
						query: "DELETE FROM threshold_tests WHERE activity_id = :id",
						bindings: [{ name: ":id", value: Integer(activity_id) }],
					})?
					Output.out!({ activity_id, removed: Bool.True }, |p| "activity ${I64.to_str(p.activity_id)} is no longer a test — run `stride analyze` to rescore")
				}
		}
	}

	is_marked! : Str, I64 => Try(Bool, _)
	is_marked! = |path, activity_id| {
		n = Sql.query!({
			path: Path.utf8(path),
			query: "SELECT COUNT(*) AS n FROM threshold_tests WHERE activity_id = :id",
			bindings: [{ name: ":id", value: Integer(activity_id) }],
			row: Sql.i64("n"),
		})?
		Ok(n > 0)
	}

	Session : { id : I64, sport : Str, day : Str, dw : Bool, raw : Str }

	session! : Str, I64 => Try(Try(Session, [NotFound]), _)
	session! = |path, activity_id| {
		rows = Sql.query_many!({
			path: Path.utf8(path),
			query: \\SELECT a.id AS id, COALESCE(CAST(a.sport_type AS TEXT), '') AS sport,
				\\       COALESCE(substr(CAST(a.start_local AS TEXT), 1, 10), '') AS day,
				\\       COALESCE(a.device_watts, 1) AS dw, COALESCE(CAST(s.raw_json AS TEXT), '') AS raw
				\\FROM activities a LEFT JOIN streams s ON s.activity_id = a.id
				\\WHERE a.id = :id
			,
			bindings: [{ name: ":id", value: Integer(activity_id) }],
			rows: |cols| |stmt| {
				id = Sql.i64("id")(cols)(stmt)?
				sport = Sql.str("sport")(cols)(stmt)?
				day = Sql.str("day")(cols)(stmt)?
				dw = Sql.i64("dw")(cols)(stmt)?
				raw = Sql.str("raw")(cols)(stmt)?
				Ok({ id, sport, day, dw: dw != 0, raw })
			},
		})?
		Ok(List.first(rows).map_err(|_| NotFound))
	}

	mark_session! : Str, Session, Str, Str, Bool => Try({}, _)
	mark_session! = |path, s, kind, signal, apply_zones| {
		family = Sports.canonical(s.sport)
		wanted = Metrics.test_family(kind)
		if wanted != "" and wanted != family {
			Output.err_out!("test_wrong_sport", "a ${kind} test is a ${wanted} protocol; activity ${I64.to_str(s.id)} is ${s.sport}")
		} else {
			streams = if (s.raw == "") Streams.empty_streams else (Streams.decode_streams(NotNull(s.raw))).streams
			# the filters analyze scores with: estimated watts are a model, not a
			# measurement, and out-of-band samples are sensor junk
			watts = if (s.dw) List.keep_if(Streams.stream_pairs(streams.time, streams.watts), |p| Metrics.valid_watts(p.v)) else []
			hr = List.keep_if(Streams.stream_pairs(streams.time, streams.heartrate), |p| Metrics.valid_hr(p.v))
			td = Streams.dist_time(streams.time, streams.distance)
			match Metrics.test_threshold(kind, watts, hr, td.time, td.dist) {
				Err(NeedsPower) => Output.err_out!("test_needs_power", "activity ${I64.to_str(s.id)} has no measured power stream long enough for a ${kind} test")
				Err(NeedsHr) => Output.err_out!("test_needs_hr", "activity ${I64.to_str(s.id)} has no heart-rate stream holding 20 unbroken minutes, which a tt30 test reads")
				Err(NeedsDistance) => Output.err_out!("test_needs_distance", "activity ${I64.to_str(s.id)} has no distance stream covering the ${kind} distance")
				Err(Implausible) => Output.err_out!("test_implausible", "activity ${I64.to_str(s.id)}'s efforts do not fit a ${kind} test: its longer best is not below its shorter one")
				Err(UnknownKind) => Output.err_out!("bad_test_kind", "'${kind}' is not a test kind — one of ${Str.join_with(Metrics.test_kinds, ", ")}")
				Ok(value) => {
					Sql.execute!({
						path: Path.utf8(path),
						query: "INSERT OR REPLACE INTO threshold_tests (activity_id, kind, signal, value, marked_at) VALUES (:id, :kind, :sig, :v, :at)",
						bindings: [
							{ name: ":id", value: Integer(s.id) },
							{ name: ":kind", value: String(kind) },
							{ name: ":sig", value: String(signal) },
							{ name: ":v", value: Real(value) },
							{ name: ":at", value: String(Metrics.epoch_to_iso(Db.now_secs!({}))) },
						],
					})?
					zones = if (apply_zones) Metrics.lthr_zone_bounds(value) else { z1_max: 0.0, z2_max: 0.0, z3_max: 0.0, z4_max: 0.0 }
					zone_sports = if (apply_zones) Sports.members(s.sport) else []
					_ = if apply_zones {
						write_zones!(path, zone_sports, zones)?
					} else {}
					until =
						match Metrics.date_str_to_days(s.day) {
							Ok(d) => Metrics.days_to_date_str(d + Metrics.test_in_force_days)
							Err(_) => s.day
						}
					payload = {
						activity_id: s.id,
						date: s.day,
						sport: s.sport,
						kind,
						signal,
						value,
						unit: unit_of(signal),
						in_force_until: until,
						zones_applied: apply_zones,
						zones,
						zone_sports,
					}
					Output.out!(payload, render)
				}
			}
		}
	}

	# the per-sport zone keys for every sport in the test's family, so an indoor or
	# trail session of that family reads the zones its own test set
	write_zones! : Str, List(Str), { z1_max : F64, z2_max : F64, z3_max : F64, z4_max : F64 } => Try({}, _)
	write_zones! = |path, sports, z| {
		_ = List.map_try!(
			sports,
			|sport| {
				Db.config_set!(path, Metrics.hr_zone_key(1, sport), Render.fmt0(z.z1_max))?
				Db.config_set!(path, Metrics.hr_zone_key(2, sport), Render.fmt0(z.z2_max))?
				Db.config_set!(path, Metrics.hr_zone_key(3, sport), Render.fmt0(z.z3_max))?
				Db.config_set!(path, Metrics.hr_zone_key(4, sport), Render.fmt0(z.z4_max))
			},
		)?
		Ok({})
	}

	unit_of : Str -> Str
	unit_of = |signal| if (signal == "power") "W" else if (signal == "pace") "m/s" else "bpm"

	render = |p| {
		shown = if (p.signal == "power") "${Render.fmt0(p.value)} W" else if (p.signal == "pace") "${Render.fmt2(p.value)} m/s" else "${Render.fmt0(p.value)} bpm"
		head = "activity ${I64.to_str(p.activity_id)} (${p.date}, ${p.sport}) marked as a ${p.kind} test: ${p.signal} threshold ${shown}, in force through ${p.in_force_until}"
		tail = "\nrun `stride analyze` to rescore"
		if (p.zones_applied) Str.concat(head, Str.concat("\n${p.sport} family HR zones set from it: z1 max ${Render.fmt0(p.zones.z1_max)} z2 max ${Render.fmt0(p.zones.z2_max)} z3 max ${Render.fmt0(p.zones.z3_max)} z4 max ${Render.fmt0(p.zones.z4_max)}", tail)) else Str.concat(head, tail)
	}
}
