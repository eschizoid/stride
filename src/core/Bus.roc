# stride-core: the viz bus's lifecycle as SQL, stated once.
#
# Two binaries execute this contract - the window, which polls it every
# second, and the CLI, whose `stride viz tick` runs one poll-and-mark cycle
# against a database without a window so the lifecycle can be tested where
# no window can open. Each binary binds its own platform's Sqlite; the
# statements, the constants and the sentinel arithmetic live here so the
# two can never disagree about what a directive's life is. ADR 0017 puts
# cross-surface READ semantics in views; the lifecycle is writes, and a view
# cannot hold an UPDATE, so its one definition is a pure module both import.
Bus :: [].{
	# the freshness window the poll enforces and the number the window
	# publishes both read this, so the published contract cannot drift from
	# the enforced one
	stale_secs : I64
	stale_secs = 600

	# the focus row's liveness window: the window rewrites the row on change
	# and on a heartbeat every focus_beat_secs, so a row older than this was
	# written by a window no longer running. Three missed heartbeats, so one
	# slow frame cannot read as death.
	focus_stale_secs : I64
	focus_stale_secs = 90

	focus_beat_secs : I64
	focus_beat_secs = 30

	# The migration, in order. Every statement is safe to repeat: CREATE and
	# INDEX carry IF NOT EXISTS, and an ALTER on a column that already exists
	# fails and is discarded by the executor, by design. The LAST statement
	# adds result to viz_directives, and the sentinel below counts that column
	# as proof the whole list ran - so a new column joins at the END and the
	# sentinel moves to it, or an existing database never gains it.
	ddl : List(Str)
	ddl = [
		"CREATE TABLE IF NOT EXISTS viz_directives (id INTEGER PRIMARY KEY AUTOINCREMENT, created_at TEXT NOT NULL DEFAULT (datetime('now')), view INTEGER, range INTEGER, cursor_day TEXT, trace_day TEXT, ghost_day TEXT, consumed INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'pending', error TEXT, applied_at TEXT)",
		# the poll runs every second forever: a partial index keeps the
		# pending lookup flat no matter how much consumed history accrues
		"CREATE INDEX IF NOT EXISTS viz_directives_pending ON viz_directives (id) WHERE consumed = 0",
		"ALTER TABLE viz_directives ADD COLUMN ghost_day TEXT",
		"ALTER TABLE viz_directives ADD COLUMN status TEXT NOT NULL DEFAULT 'pending'",
		"ALTER TABLE viz_directives ADD COLUMN error TEXT",
		"ALTER TABLE viz_directives ADD COLUMN applied_at TEXT",
		# a session named by activity id rather than by day: a day can carry
		# two stream-bearing sessions and name only one of them
		"ALTER TABLE viz_directives ADD COLUMN trace_id INTEGER",
		"ALTER TABLE viz_directives ADD COLUMN ghost_id INTEGER",
		# rows consumed before the lifecycle existed default to 'pending',
		# which contradicts consumed = 1 on read-back; their outcome is unknowable
		"UPDATE viz_directives SET status = 'unknown' WHERE consumed = 1 AND status = 'pending'",
		"CREATE TABLE IF NOT EXISTS viz_focus (id INTEGER PRIMARY KEY CHECK (id = 1), updated_at TEXT NOT NULL, view INTEGER NOT NULL, range INTEGER NOT NULL, cursor_day TEXT, trace_day TEXT, ghost_day TEXT)",
		"ALTER TABLE viz_focus ADD COLUMN ghost_day TEXT",
		"ALTER TABLE viz_focus ADD COLUMN trace_id INTEGER",
		"ALTER TABLE viz_focus ADD COLUMN ghost_id INTEGER",
		# a capture asked for through the bus (png, webm_start, webm_stop) and
		# the file the window wrote for it, reported with the terminal status
		"ALTER TABLE viz_directives ADD COLUMN capture TEXT",
		"ALTER TABLE viz_directives ADD COLUMN result TEXT",
	]

	# The every-second fast path: one read of the catalog, no schema lock.
	# Counts the three objects, then the ghost_day and ghost_id COLUMNS of
	# each table as the catalog structures them - not as text in their
	# CREATE statements, which a comment or a renamed column could satisfy
	# without the column existing. Only a database that ran the whole list
	# to its last statement reaches sentinel_present; any older column set
	# re-enters the DDL. A table that does not exist contributes nothing.
	sentinel_sql : Str
	sentinel_sql = "SELECT (SELECT count(*) FROM sqlite_master WHERE name IN ('viz_directives', 'viz_focus', 'viz_directives_pending')) + (SELECT count(*) FROM pragma_table_info('viz_directives') WHERE name IN ('ghost_day', 'ghost_id', 'capture', 'result')) + (SELECT count(*) FROM pragma_table_info('viz_focus') WHERE name IN ('ghost_day', 'ghost_id')) AS c"

	# 3 objects + ghost_day, ghost_id, capture and result on viz_directives (4)
	# + ghost_day and ghost_id on viz_focus (2)
	sentinel_present : I64
	sentinel_present = 9

	# a read gates the writes: a zero-row UPDATE still takes the write lock
	has_pending_sql : Str
	has_pending_sql = "SELECT EXISTS(SELECT 1 FROM viz_directives WHERE consumed = 0) AS e"

	# a directive written while no window was open must not seize the one
	# that eventually launches: anything past the freshness window closes as
	# stale, applied by nobody. winner_sql refuses stale rows independently,
	# so one slipping past this sweep is labelled late but never applied.
	stale_sweep_sql : Str
	stale_sweep_sql = "UPDATE viz_directives SET consumed = 1, status = 'stale', error = 'older than ' || ${stale_secs.to_str()} || ' seconds when read' WHERE consumed = 0 AND created_at < datetime('now', '-${stale_secs.to_str()} seconds')"

	# the newest fresh unconsumed row; -1 and '' stand for NULL (field not set)
	winner_sql : Str
	winner_sql = "SELECT id, COALESCE(view, -1) AS v, COALESCE(range, -1) AS rg, CAST(COALESCE(cursor_day, '') AS TEXT) AS cd, CAST(COALESCE(trace_day, '') AS TEXT) AS td, CAST(COALESCE(ghost_day, '') AS TEXT) AS gd, COALESCE(trace_id, -1) AS ti, COALESCE(ghost_id, -1) AS gi, CAST(COALESCE(capture, '') AS TEXT) AS cp FROM viz_directives WHERE consumed = 0 AND created_at >= datetime('now', '-${stale_secs.to_str()} seconds') ORDER BY id DESC LIMIT 1"

	# older unconsumed rows close as superseded; the winner stays PENDING
	# until the frame that applies it reports back through mark_sql, so a
	# crash between read and apply leaves it retryable within the window
	supersede_sql : Str
	supersede_sql = "UPDATE viz_directives SET consumed = 1, status = 'superseded' WHERE id < :id AND consumed = 0"

	# the terminal outcome, written by whoever applied the directive; :e
	# carries the refused fields, '' when every field was honoured, :r the
	# file a capture produced ('' when none), and the WHERE keeps a row
	# already closed by a later sweep from being reopened
	mark_sql : Str
	mark_sql = "UPDATE viz_directives SET consumed = 1, status = :st, error = NULLIF(:e, ''), result = NULLIF(:r, ''), applied_at = datetime('now') WHERE id = :id AND consumed = 0"

	# the same mark, returning the id it closed: a statement that returns no
	# row matched nothing, which means another executor closed the winner
	# between this one's select and its mark. An executor whose payload
	# reports the outcome reads this form, since a plain execute cannot tell
	# one row changed from none; the window, which reports nothing and polls
	# again, runs the plain form.
	mark_returning_sql : Str
	mark_returning_sql = Str.concat(mark_sql, " RETURNING id")

	mark_status : Str -> Str
	mark_status = |refused| if refused == "" "applied" else "applied_partial"

	# what a directive may ask the window to capture: a PNG of the current
	# view, or the start and the stop of a WebM recording of it; '' asks for
	# nothing
	capture_kinds : List(Str)
	capture_kinds = ["png", "webm_start", "webm_stop"]

	# the refusal a capture value earns before any window judges it: '' and
	# the three kinds pass, anything else is named with the vocabulary
	capture_refusal : Str -> Str
	capture_refusal = |c| if c == "" or List.contains(capture_kinds, c) "" else "capture ${c} not png/webm_start/webm_stop"

	focus_upsert_sql : Str
	focus_upsert_sql = "INSERT INTO viz_focus (id, updated_at, view, range, cursor_day, trace_day, ghost_day, trace_id, ghost_id) VALUES (1, datetime('now'), :v, :rg, NULLIF(:cd, ''), NULLIF(:td, ''), NULLIF(:gd, ''), NULLIF(:ti, -1), NULLIF(:gi, -1)) ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at, view = excluded.view, range = excluded.range, cursor_day = excluded.cursor_day, trace_day = excluded.trace_day, ghost_day = excluded.ghost_day, trace_id = excluded.trace_id, ghost_id = excluded.ghost_id"

	focus_clear_sql : Str
	focus_clear_sql = "DELETE FROM viz_focus WHERE id = 1"
}

# the sentinel's proof is the migration's last statement: it ADDS result
# to viz_directives. A column appended after it would never be counted, so
# this holds the two together.
expect {
	last = match List.last(Bus.ddl) { Ok(s) => s
		Err(_) => "" }
	Str.starts_with(last, "ALTER TABLE viz_directives ADD COLUMN result")
}

# the sentinel reads the catalog's column structure for both tables, not
# the text of a CREATE statement, and its target is the three objects plus
# the two columns it names on each table
expect Str.contains(Bus.sentinel_sql, "pragma_table_info('viz_directives')") and Str.contains(Bus.sentinel_sql, "pragma_table_info('viz_focus')") and Bus.sentinel_present == 3 + 4 + 2

# the sweep and the winner enforce the one published window
expect Str.contains(Bus.stale_sweep_sql, "-600 seconds") and Str.contains(Bus.winner_sql, "-600 seconds")

# the returning form is the mark and nothing else, so the two executors
# close a row by one statement
expect Bus.mark_returning_sql == Str.concat(Bus.mark_sql, " RETURNING id")

expect Bus.mark_status("") == "applied"
expect Bus.mark_status("trace_day 2026-01-01 not in the picker") == "applied_partial"

# the mark carries the capture's file beside the refusal, and the winner
# reads what was asked for
expect Str.contains(Bus.mark_sql, "result = NULLIF(:r, '')") and Str.contains(Bus.winner_sql, "AS cp FROM")

# the capture vocabulary: nothing asked, the three kinds, and a misspelling
expect Bus.capture_refusal("") == "" and Bus.capture_refusal("png") == "" and Bus.capture_refusal("webm_start") == "" and Bus.capture_refusal("webm_stop") == ""
expect Bus.capture_refusal("gif") == "capture gif not png/webm_start/webm_stop"
