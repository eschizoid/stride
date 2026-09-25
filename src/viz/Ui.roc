import core.Series
import rr.Capture
import rr.Draw
import rr.Text
import rr.Texture
import Db

Ui :: [].{
	# one month as the career view draws it: screen position, and whether the
	# month was measured at all - an unmeasured one breaks the curve
	SpinePt : { x : F32, y : F32, ok : Bool }
	YLabel : { p : Text.Prepared, v : F32 }
	EndLabel : { p : Text.Prepared, sel : U8 }

	Model : {
		title : Text.Prepared,
		subs : List({ p : Text.Prepared, r : U64, chip : Text.Prepared }),
		leg_fit : Text.Prepared,
		leg_fat : Text.Prepared,
		leg_form : Text.Prepared,
		ylabels : List(YLabel),
		ends : List(EndLabel),
		ev_label : Text.Prepared,
		ev_found : Bool,
		ev_idx : U64,
		ev_warn : Text.Prepared,
		ev_warn_found : Bool,
		stale : Text.Prepared,
		stale_found : Bool,
		view : U8,
		curve : List(Db.CurvePt),
		# the same rungs over the window immediately BEFORE the visible one -
		# what the curve view's deltas argue against
		curve_prev : List(Db.CurvePt),
		curve_lbls : List({ p : Text.Prepared, d : I64 }),
		fit_lbl : Text.Prepared,
		curve_title : Text.Prepared,
		curve_hint : Text.Prepared,
		trace_hint : Text.Prepared,
		table_hint : Text.Prepared,
		table_title : Text.Prepared,
		table_head : List(Text.Prepared),
		kpis : List({ v : Text.Prepared, cap : Text.Prepared, sel : U8 }),
		ev_tile_top : Text.Prepared,
		ev_tile_sub : Text.Prepared,
		zero_note : Text.Prepared,
		ridden_found : Bool,
		ridden_note : Text.Prepared,
		curve_empty : Text.Prepared,
		trace : List(F32),
		segs : List(Db.Seg),
		trace_dur : F32,
		trace_ids : List({ id : I64, day : Str, name : Str, sport : Str, chan : Str }),
		trace_sel : U64,
		trace_day : Str,
		# what the y axis is counting for the SELECTED session, which follows
		# the stream it actually carries rather than its sport: watts where a
		# power meter recorded them, heart rate otherwise. Strength work never
		# has watts, and neither does a road ride without a meter.
		trace_unit : Str,
		# the athlete's unit preference, read once at load; every surface
		# converts at the last moment through core.Units, never in SQL
		units : [Metric, Imperial],
		# the SELECTED session's distance splits, present only for the pace
		# channel - the same core.Series rows the CLI prints, segmented at
		# the athlete's split length
		trace_splits : List(Series.Split),
		# the picker's sport filter; "" offers every sport. [ and ] step to
		# the next session this filter admits, so the selection index still
		# addresses the full menu and every cache lookup stays valid
		trace_sport : Str,
		ghost : List(F32),
		ghost_dur : F32,
		ghost_sel : I64,
		ghost_day : Str,
		# the trace camera: zoom >= 1 windows [pan, pan + 1/zoom] of the session
		trace_zoom : F32,
		trace_pan : F32,
		# every pickable session, loaded once - switching and ghosts read this
		# instead of a task round-trip per keypress
		trace_cache : List({ tr : List(F32), sg : List(Db.Seg), du : F32, un : Str, sp : List(Series.Split) }),
		curve_days : I64,
		fit_cp : F32,
		# the fit's own quality, carried so the CP line can dim when the fit
		# is too weak to deserve a confident stroke
		fit_r2 : F32,
		cp_lbl : Text.Prepared,
		data : List(Db.Point),
		days : List(Str),
		day_notes : List({ day : Str, note : Str }),
		home : Str,
		tick : U64,
		view_anim : U64,
		last_focus : { view : I64, range : I64, cursor_day : Str, trace_day : Str, ghost_day : Str },
		status : Text.Prepared,
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
		# the brand mark as the authored PNG, loaded for the splash only -
		# hand-drawn approximations of the logo kept drifting from the real
		# artwork, so the splash renders the artwork itself
		logo : [NoLogo, Logo(Texture.Texture)],
		font : Text.Font,
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
		week_tss : { this : I64, last : I64 },
		plan_week : { done : I64, total : I64 },
		bus_note : Str,
		plan_title : Text.Prepared,
		plan_hint : Text.Prepared,
		nav : List({ p : Text.Prepared, v : U8 }),
		heat : List(Db.HeatDay),
		heat_events : List(Str),
		heat_title : Text.Prepared,
		heat_hint : Text.Prepared,
		zone_weeks : List(Db.ZoneWeek),
		career_spines : List(Db.CareerSpine),
		career_sports : List(Db.CareerSport),
		# which family's arc the career view is drawing; F cycles it
		spine_idx : U64,
		zones_title : Text.Prepared,
		zones_hint : Text.Prepared,
		ramp_weeks : List(Db.RampWeek),
		ramp_title : Text.Prepared,
		ramp_hint : Text.Prepared,
		prs : List(Db.PrRung),
		rec_status : Capture.Status,
		# the last directive this window applied, and what it refused - a
		# re-delivered id re-reports this outcome instead of re-applying
		last_directive : { id : I64, refused : Str },
		# the post-process pipeline: Unbuilt until update! allocates it, sized
		# to the window. Unavailable remembers the size the GPU refused at, so
		# a resize earns one fresh attempt; between refusals the app renders
		# exactly as before the feature existed
		glow : [Unbuilt, Unavailable({ gw : F32, gh : F32 }), Ready({ rt : Draw.RenderTexture, shader : Draw.Shader, rx : Draw.F32Uniform, ry : Draw.F32Uniform, gw : F32, gh : F32 })],
		glow_on : Bool,
		mouse_in : Bool,
		cursor : I64,
	}
}
