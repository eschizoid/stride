import core.Series
import rr.Capture
import rr.Draw
import rr.Shader
import rr.Text
import rr.Texture
import Db
import Geo
import Motion
import Tiles

Ui :: [].{
	# one month as the career view draws it: screen position, and whether the
	# month was measured at all - an unmeasured one breaks the curve
	SpinePt : { x : F32, y : F32, ok : Bool }
	YLabel : { p : Text.Prepared, v : F32 }
	# one capture a directive asked for, while its mark waits on the host:
	# the row to mark, what the directive's other fields refused, the absolute
	# file the status will name, the name the host writes under ./captures,
	# and the tick the wait began
	CaptureWait : { id : I64, refused : Str, path : Str, name : Str, since : U64 }
	PendingCapture : [NoCapture, ArmedShot(CaptureWait), AwaitingShot(CaptureWait), AwaitingStart(CaptureWait), AwaitingStop(CaptureWait)]
	EndLabel : { p : Text.Prepared, sel : U8, r : U64 }
	# a left press that began on the map: where the cursor was last, where
	# the press began, and whether the cursor has since strayed past the
	# distance a click allows, which makes the press a drag
	MapPress : [Idle, Held({ x : F32, y : F32, ox : F32, oy : F32, far : Bool })]
	# the map's card: closed, or up for the session whose route was clicked,
	# anchored at the clicked point in map metres. Opening waits on that
	# session's picker row, read for a session the trace picker does not
	# hold; NoTrace says its stream holds nothing the trace can plot.
	MapCard : [Closed, Open({ id : I64, at : Geo.Pt, state : [Ready, Opening, NoTrace] })]
	# a copy the window prepared at load beside the string and size it was
	# prepared from, for text no view can derive again from the model
	Txt : { p : Text.Prepared, s : Str, size : F32 }

	Model : {
		title : Text.Prepared,
		subs : List({ p : Text.Prepared, r : U64, chip : Text.Prepared }),
		leg_fit : Text.Prepared,
		leg_fat : Text.Prepared,
		leg_form : Text.Prepared,
		ylabels : List(YLabel),
		ends : List(EndLabel),
		ev_label : Txt,
		ev_found : Bool,
		ev_idx : U64,
		ev_warn : Txt,
		ev_warn_found : Bool,
		stale : Text.Prepared,
		stale_found : Bool,
		view : U8,
		curve : List(Db.CurvePt),
		# the same rungs over the window immediately BEFORE the visible one -
		# what each power-view row's change is measured from
		curve_prev : List(Db.CurvePt),
		curve_title : Text.Prepared,
		curve_hint : Text.Prepared,
		trace_hint : Text.Prepared,
		table_hint : Text.Prepared,
		table_title : Text.Prepared,
		table_head : List(Text.Prepared),
		kpis : List({ v : Text.Prepared, cap : Text.Prepared, sel : U8 }),
		ev_tile_name : List(Txt),
		ev_tile_proj : List(Txt),
		# the engine's projected series past the plot's last day, empty when
		# nothing is planned ahead, and the board's key for each range,
		# naming the days that range draws
		proj : List(Db.ProjDay),
		proj_keys : List({ r : U64, t : Txt }),
		ev_tile_sub : Txt,
		zero_note : Text.Prepared,
		ridden_found : Bool,
		ridden_note : Txt,
		curve_empty : Text.Prepared,
		trace : List(F32),
		segs : List(Db.Seg),
		trace_dur : F32,
		trace_ids : List({ id : I64, day : Str, name : Str, sport : Str, chan : Str }),
		trace_sel : U64,
		# the identity of the trace fetch that may still land: bumped on every
		# switch, stamped onto the fetch it spawns, and a reply applies only if
		# it carries the current value. A picker index is not an identity - it
		# is reused across switches and reassigned by a picker re-read - so a
		# reply is matched to its request, never to a position.
		trace_gen : U64,
		# raised when a re-read picker no longer holds the SHOWN session, so
		# the next frame fetches the selection it fell to instead of leaving
		# the vanished session's samples under a neighbour's name; the frame
		# that spawns the fetch lowers it
		trace_refetch : Bool,
		# true exactly while a fetch for the CURRENT trace_gen is outstanding: a
		# switch to a session not in the boot cache fetches its samples off the
		# main loop and blanks the plot until they land, and this is what lets
		# the blank read as "loading" rather than as the "no samples" message,
		# which is only true of a session whose stream really is empty. Raised
		# when that fetch spawns; lowered by its reply, or by a later switch
		# that answers from the cache and so has nothing outstanding.
		trace_loading : Bool,
		# a ghost fetch spawned for the current generation has not answered yet
		ghost_loading : Bool,
		trace_day : Str,
		# what the y axis is counting for the SELECTED session, which follows
		# the stream it actually carries rather than its sport alone: watts
		# where a power meter recorded them, pace on a pace family carrying
		# distance and time, heart rate otherwise. Strength work never has
		# watts, and neither does a road ride without a meter.
		trace_unit : Str,
		# the athlete's unit preference, read once at load; every surface
		# converts at the last moment through core.Units, never in SQL
		units : [Metric, Imperial],
		# the SELECTED session's distance splits, present only for the pace
		# channel - the same core.Series rows the CLI prints, segmented at
		# the athlete's split length
		trace_splits : List(Series.Split),
		# the selected strength session's stored sets, empty for any other
		trace_sets : Db.StrengthLog,
		# the picker's sport filter; "" offers every sport. [ and ] step to
		# the next session this filter admits, so the selection index still
		# addresses the full menu and every cache lookup stays valid
		trace_sport : Str,
		ghost : List(F32),
		ghost_dur : F32,
		ghost_sel : I64,
		# the ghost fetch's identity, as trace_gen is the trace's: bumped on
		# every ghost change including a dismissal, so a slow load can neither
		# resurrect a cleared ghost nor overwrite a newer pick
		ghost_gen : U64,
		ghost_day : Str,
		# the trace camera: zoom >= 1 windows [pan, pan + 1/zoom] of the session
		trace_zoom : F32,
		# the first row drawn in the lifts list, in the lifts view's session card
		# and in the plan's week ladder (Scroll)
		lifts_off : U64,
		last_off : U64,
		week_off : U64,
		trace_pan : F32,
		# the sessions whose samples are in memory, by picker index: the load
		# caches the newest and a picker re-read empties it; a switch or ghost
		# to a cached index answers without a fetch
		trace_cache : List({ tr : List(F32), sg : List(Db.Seg), du : F32, un : Str, sp : List(Series.Split), st : Db.StrengthLog }),
		curve_days : I64,
		# the curve the power view draws, a Bus curve key: a family head for
		# that family's power, or pace:<sport_type> for that sport's speed
		curve_family : Str,
		# the curves the athlete has data for: the power families and the pace
		# keys the chips offer
		curve_keys : Db.CurveKeys,
		# the power families whose only watts are Strava's estimate
		est_power : List(Str),
		# what the power tab's top line reads: the window's fit, a marked test
		# in force, and the engine's newest threshold for the curve
		curve_info : Db.CurveInfo,
		data : List(Db.Point),
		days : List(Str),
		day_notes : List({ day : Str, note : Str }),
		# the athlete's own directory, as the launcher declared it; "" when
		# the window was started without one and has no database to read
		stride_dir : Str,
		# the window's working directory as `pwd -P` reports it at load, the
		# root a capture's status row names its file under; the launch
		# directory before that load or when `sh` fails, and "" when the
		# launcher passed none, which leaves a capture's path relative
		cwd : Str,
		tick : U64,
		# the tick of the last activity, the athlete's input or a directive from
		# the coach: the window keeps its full frame rate for a moment after it
		last_active : U64,
		view_anim : U64,
		last_focus : { view : I64, range : I64, cursor_day : Str, trace_day : Str, ghost_day : Str, trace_id : I64, ghost_id : I64, detail_day : Str, sport : Str, family : Str, curve_family : Str, curve_short : I64, map_id : I64 },
		# quitting is raised by the ESC frame, which spawns the focus-row clear;
		# the frame that sees the clear land - or sees quit_tick fall half a
		# second behind, so a stuck database can never trap the athlete in a
		# window - is the one that exits
		quitting : Bool,
		quit_tick : U64,
		focus_cleared : Bool,
		# the row of a capture ESC closed whose mark has not landed yet; -1 when none
		quit_mark_pending : I64,
		status : Txt,
		has_error : Bool,
		# True from launch until the first background load lands: the window
		# opens instantly and renders the splash instead of empty views
		booting : Bool,
		# True while a range-chip (or R) reload is in flight: the power view
		# shows a "loading" note so a chip click that takes a second to fetch
		# reads as working rather than dead. Cleared on EITHER terminal
		# outcome - a fresh model landing or the reload failing - so a failed
		# fetch never strands the note on screen.
		reloading : Bool,
		# the brand mark as the authored PNG, loaded for the splash only;
		# NoLogo leaves the splash its words alone
		logo : [NoLogo, Logo(Texture.Texture)],
		# the streak chip's flame as an authored PNG, loaded with the logo at
		# boot and carried across reloads; NoFlame leaves the chip text-only
		flame : [NoFlame, Flame(Texture.Texture)],
		# the data face (JetBrains Mono) every fresh view text draws in, and the
		# prose face (Quicksand) the prepared titles, legends and hints use
		font : Text.Font,
		prose : Text.Font,
		hint : Text.Prepared,
		empty : Text.Prepared,
		range : U64,
		mouse_x : F32,
		mouse_y : F32,
		win : { w : F32, h : F32 },
		ui_percent : I64,
		ui_scale : F32,
		detail_day : Str,
		detail : List(Db.DayLine),
		plan : List(Db.PlanRow),
		week_tss : { this : I64, last : I64, scored : Bool },
		plan_week : { done : I64, total : I64 },
		bus_note : Db.BusNote,
		plan_title : Text.Prepared,
		plan_hint : Text.Prepared,
		nav : List({ p : Text.Prepared, v : U8 }),
		heat : List(Db.HeatDay),
		strength : Db.StrengthView,
		heat_events : List(Str),
		heat_title : Text.Prepared,
		heat_hint : Text.Prepared,
		zone_weeks : List(Db.ZoneWeek),
		career_spines : List(Db.CareerSpine),
		# months a marked test sets a family's spine from (Db.load_test_months!)
		career_tests : List({ fam : Str, month : Str, kind : Str, signal : Str }),
		career_sports : List(Db.CareerSport),
		# per-family monthly load and session count, so the career view can show
		# what the SELECTED family did in each month rather than only the pooled
		# ground bar. Every family is loaded once, so cycling the spine with F
		# needs no round trip.
		career_fam_months : List(Db.FamMonth),
		# which family's arc the career view is drawing; F cycles it
		spine_idx : U64,
		zones_title : Text.Prepared,
		zones_hint : Text.Prepared,
		ramp_weeks : List(Db.RampWeek),
		ramp_title : Text.Prepared,
		ramp_hint : Text.Prepared,
		# the week picked in the weeks tab, shared by its zones and load modes;
		# empty when none is picked
		week_cursor : Str,
		prs : List(Db.PrRung),
		rec_status : Capture.Status,
		# a capture a directive asked for whose mark waits on the host: a PNG
		# armed until the view has settled and then until the screenshot task
		# answers, a start until the recorder reports it running, a stop until
		# the recording reads Finished or Failed. `since` is the tick the wait
		# began; `path` is absolute, the file the status row will name
		pending_capture : PendingCapture,
		# the file the running (or last) recording writes, absolute
		rec_path : Str,
		# the last directive this window applied, what it refused and the file
		# it produced - a re-delivered id re-reports this outcome instead of
		# re-applying
		last_directive : { id : I64, refused : Str, result : Str },
		# the post-process pipeline: Unbuilt until update! allocates it, sized
		# to the window. Unavailable remembers the size the GPU refused at, so
		# a resize earns one fresh attempt; while it is unavailable the window
		# draws without the glow
		glow : [Unbuilt, Unavailable({ gw : F32, gh : F32 }), Ready({ rt : Draw.RenderTexture, shader : Shader({ res_x : F32, res_y : F32 }), gw : F32, gh : F32 })],
		glow_on : Bool,
		mouse_in : Bool,
		# the day cursor the form board and the data table share: `cursor`
		# counts days back from the latest measured day (-1 off), and
		# `cursor_ahead` the board's projected days past it the cursor has
		# walked on into (0 on a measured day)
		cursor : I64,
		cursor_ahead : U64,
		# the map view: every route
		map : Db.MapData,
		# Unloaded until a load task is spawned, Loading while it runs, and
		# Loaded once its map has landed; a finished reload (R) sets a loaded
		# map back to Unloaded and marks a loading one stale (map_on_reload)
		map_load : [Unloaded, Loading, Loaded],
		# the identity of the newest map load, stamped on the task it spawns
		map_gen : U64,
		# R was pressed while the map was being read, so it is read once more
		# when that read lands
		map_stale : Bool,
		# the camera the athlete moved the map to; until map_moved says they
		# have, the view opens where Geo.opening puts it
		map_cam : Geo.Cam,
		map_moved : Bool,
		# the left button held on a press that began on the map (Map.press_step)
		map_drag : MapPress,
		# the card a click on a route opened (Map.act)
		map_card : MapCard,
		# the map's offscreen picture, sized to the framebuffer's pixels and
		# allocated the first time the view shows, with the shader its names
		# are blended in through (Map.text_frag), NoText when the GPU refused
		# it. Refused remembers the size the GPU refused at, so a resize earns
		# one fresh attempt; without a picture the view draws every line
		# straight to the frame
		map_rt : [NoTarget, Refused({ w : F32, h : F32 }), Target({ rt : Draw.RenderTexture, w : F32, h : F32, text : [NoText, Text(Shader({ gain : F32 }))] })],
		# whether this frame's render repaints the picture, and the camera the
		# picture holds once it has
		map_paint : Bool,
		map_painted : Geo.Cam,
		# the mode the picture was painted for, since each mode paints its own
		map_painted_view : U8,
		# the heat mode's texture of summed passes and the shader that
		# tone-maps it, built the first time heat shows and sized to the
		# window's pixels; Unavailable remembers the size the GPU refused at,
		# and heat mode then draws the routes as routes mode does
		map_heat : [Unbuilt, Unavailable({ w : F32, h : F32 }), Ready({ rt : Draw.RenderTexture, shader : Shader({ top : F32 }), w : F32, h : F32 })],
		# playback's clock in seconds of play, which runs only while the play
		# mode shows and is not paused, and starts over each time it opens
		map_play : { secs : F32, paused : Bool },
		# whether the landed map's routes carry their speed bands yet, the
		# tick of the frame that worked them out (Db.with_bands), and the
		# route seconds the longest route lasts (Map.longest): Unbuilt until
		# playback first shows a landed map, and again whenever a map lands
		map_speed : [Unbuilt, Built({ tick : U64, longest : F32 })],
		# the markers paused playback draws, placed once while the clock
		# stands still (Motion.step_marks)
		map_marks : Motion.Marks,
		# the street map's tiles the window holds, and the state of the
		# TileJSON their addresses are read from (Tiles)
		map_tiles : List(Tiles.Slot),
		map_source : Tiles.Source,
		# the camera and tick the tiles were last planned at, and whether
		# something has changed them since (a tile landed, the source was read,
		# the map was read); main's plan_now says when a frame plans again
		map_planned : { cam : Geo.Cam, tick : U64 },
		map_plan_due : Bool,
		# why the last tile the window fetched could not be kept in the
		# cache, "" once one has been
		map_cache_err : Str,
	}
}
