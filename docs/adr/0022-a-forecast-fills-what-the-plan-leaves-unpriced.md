# 0022. a forecast fills what the plan leaves unpriced, from the athlete's own history

Accepted 2026-11-26. Amends ADR 0009 and ADR 0010 for projected days only, and the
"never invents a load" sentence of ADR 0019's 2026-11-05 amendment. Recorded days are
untouched.

## Context

A projection walks fitness and fatigue forward over the open plan. Until now a day
added load only when a session on it carried a target its inputs could price. A
session written as prose alone, and every day the plan left empty, added nothing.

Coaches often write plans in prose. One athlete's coach wrote 32 daily sessions with
no target at all. The projection read that month as 32 days of rest: fitness fell from
36.8 to 17.2, fatigue fell to 0.3 and form rose to +16.9, for an athlete who planned
to train every day. Each number followed from its inputs, and the picture was still
false. Leaving a day out of the walk does not leave its load unknown: the walk reads
the day as zero. That zero is itself an invented value, and the board drew it as the
most likely future.

## Decision

1. **Every projected day has a load and says where the load came from.** A projected
   day is a day after the baseline, the last computed day. The day's `load_source` is
   one of these:
   - `target`: an open session whose target its inputs price, exactly as ADR 0019
     prices it.
   - `rest`: an open session typed `rest` with no target that prices. The day adds
     zero, because zero is what a rest day is.
   - `estimate`: an open session that has no target, or has one its inputs cannot
     price (no FTP, no zones, no threshold pace). The load comes from the athlete's
     own history, by the rule in 2.
   - `habit`: a day with no open session. The load is the athlete's recent daily
     average, by the rule in 3.
   - `none`: the history the rule needs is missing. The day adds zero and its
     `load_known` is false. This is the only source that is not a load.

   The engine allows one open session per date, so a day has at most one session in
   a recorded plan. A hypothetical plan can name a date twice. That day takes the
   least certain of its sessions' sources, in the order none, estimate, target, rest.

2. **The estimate is the athlete's median load per hour, times the session's
   duration.** The engine reads the scored sessions that started in the 90 days
   ending on the baseline day. Each one gives a load per hour, which is its load
   over its moving time. Three groups are tried in order, and the first group that
   holds at least three sessions is used:
   - the sessions that completed a planned session of the same type, compared
     without case;
   - the sessions of the first sport named by a word of the session's type, then
     of its detail;
   - every session.

   The duration is the target's own work time when the session has a target with
   one. Otherwise it is the median moving time of the chosen group. When no group
   holds three sessions, the day is `none`. No generic default stands in.

3. **The habit is the mean daily load of the 28 days ending on the baseline day.**
   A rest day in that span counts as zero, as it does in the fitness numbers. With
   no computed day in the span, the day is `none`.

4. **The labels are data.** Each series row carries its `load_source`. The payload
   counts the days of each source in `load_sources`, and `events` gives each event
   the same counts. The human screens and the window state the mix in words, for
   example "12 from targets, 20 estimated from your history". A projection that
   mixes sources always says so. No existing field changes meaning: `unprojected`
   still lists every session its target could not price, and `sessions_projected`
   still counts the ones it could.

5. **A hypothetical plan is projected as written.** The caller states the whole plan
   (ADR 0010), so a day the plan does not name is a `rest` day of that plan. A target
   its inputs cannot price is `none`. Nothing in a hypothetical plan is estimated,
   so a caller comparing two tapers compares only what the caller wrote.

6. **The board projects to the plan's last day, or to the next event when that is
   no more than 42 days away.** Habit days carry the projection past the plan's
   end to an event in that span. A later event is reached by `stride events`,
   which walks to the event day by the same rule. A plot that ran months past the
   measured days would leave no room for the measured days.

## Consequences

ADR 0009 says the engine never invents a value. A measured day still never gets an
estimate. A projected day's load is a forecast by definition. It comes from a stated
rule over the athlete's own records and is labeled with that rule's name, so it
follows ADR 0009 the way a `_known` flag does: the reader can always tell the
estimate from the measurement.

ADR 0010 allows arithmetic over a stated plan and its named inputs. The athlete's
history is now one of those inputs. The engine still never chooses, ranks or adjusts
a plan, and the estimate does not depend on the athlete's goal. A coach who wants a
day to count as rest writes a `rest` session for it, because an empty day is read as
an ordinary recent day.

A target still gives the most exact forecast. The skill tells coaches to give each
session at least a session rating target.

A plan written mostly in prose now draws the athlete's usual training rather than a
decline to zero. Its numbers are only as good as the history behind them, and the
mix shown beside them says how much of the plan that is.
