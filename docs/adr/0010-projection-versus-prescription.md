# ADR 0010. Projection is arithmetic, prescription is coaching

Date: 2026-08-17. Status: accepted. Issue: #161. PR: #176. Prerequisite for #138 (event targeting) and #139 (season view); constrains #140 (taper projection, since split out as #189).

## Exercised on 2026-08-18

Issue #139 shipped under this rule, and ADR 0011 records the result. `season` describes
blocks by slope, polarization and FTP range, and it refuses to name them as base, build or
peak. `season_screen` renders no verdict line at all. The constraint held on the first
feature to meet it, which is the evidence an ADR of this kind otherwise lacks. Issues
#138, #140 and #189 remain open and still inherit the rule.

## Context

The event and taper tier asks stride to answer questions about the future, such as "what
will my form be on race day?". The future is where the boundary between engine and coach,
recorded in #123, #154 and ADR 0000, is easiest to violate by accident. A projection that
picks its own inputs is a recommendation rather than a calculation. The boundary has so far
been enforced per surface, through the form_state enum, closed-set verdict pins, and
measurement-only judgment features. Before any forward-looking feature lands, the rule for
the future needs to be settled by decision rather than negotiated per PR.

## Decision

Stride may project the mathematical consequences of an explicit plan, and it must not
choose, rank or adjust plans.

What is allowed is deterministic arithmetic over stated inputs. One example is "if the
currently recorded plan is executed as written, projected CTL/ATL/TSB on date D are X/Y/Z".
The same holds for a hypothetical plan the caller passes in, described as these sessions,
these dates and these loads. Sensitivity is allowed in its raw form, as in "with session S
removed, TSB on D is Z+4", when the caller names the variation. Every projection names its
inputs, meaning which plan, which assumed loads and which model constants, so that the
arithmetic is reproducible. Every projection also carries the model's known limits as data,
such as the convergence caveat on the CTL warming-up flag, which is the same provenance
discipline as ADR 0009 and #157.

The engine never produces target values such as "aim for TSB +5 on race day", and it never
produces plan edits such as "reduce Thursday's workout", "start tapering now" or "add a rest
day". It also never generates a plan, as in "here is a taper that lands you fresh", and it
never ranks hypotheticals, as in "plan A is better". Choosing among futures is judgment
about the athlete's goals, constraints and body, and that judgment belongs to the coach,
which is the LLM. The coach can call the projection arithmetic as many times as it wants
with plans of its own choosing, and it owns the comparison.

The boundary test is stated once here. If the output would change because the athlete's goal
changed, the output is prescription and does not belong in stride. Arithmetic over a stated
plan does not depend on the goal, and a taper recommendation does. Direction is part of the
rule, because stride maps a plan to its consequences and never maps a target to a plan.
Solving for the inputs that achieve a stated target, as in "minimum rest days to reach
TSB ≥ 0 by date D", is choosing a plan and is therefore prescription even when the caller
stated the target. The coach produces such answers itself by projecting candidate plans of
its own devising.

## Consequences

The taper projection in #140 is in scope only as plan-conditional arithmetic, meaning
projection of a recorded or hypothetical taper, and never as taper construction. The event
features in #138 may report projected form on the event date under the recorded plan, and
the gap to any hypothetical the caller states, and nothing more.

Projection surfaces inherit the existing enforcement machinery, which is closed-set output
shapes where the set is finite, has_coaching_language sweeps over any prose,
measurements-only payload fields from #154, and `_known` flags for absent inputs from ADR
0009.

A hypothetical plan is caller input and is echoed back in the payload verbatim. Stride never
stores it, so the recorded plan stays the single source of adherence truth, as #158
requires.

Two questions are deliberately not decided here and are deferred to #138 and #140. The first
is which command surface projections live on. The second is the input format for
hypothetical plans. Projection prose fields, if there are any, must be closed-set shapes.
The has_coaching_language denylist alone would not catch phrasing such as "you are on
track", so the hard guard is equality over finite outputs, as it has been everywhere else
since #154.
