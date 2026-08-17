# ADR 0010 — Projection is arithmetic, prescription is coaching

Date: 2026-08-17. Status: accepted. Issue: #161. PR: #176. Prerequisite for #138 (event targeting) and #139 (season view); constrains #140 (taper projection).

## Context

The event/taper tier asks stride to answer questions about the FUTURE ("what will my form be on race day?"), and the future is where the engine/coach boundary (#123, #154, ADR 0000) is easiest to violate by accident: a projection that picks its own inputs is a recommendation wearing a calculator's clothes. The boundary has so far been enforced per-surface (form_state enum, closed-set verdict pins, measurement-only judgment features); before any forward-looking feature lands, the rule for the future needs to be settled by decision rather than negotiated per-PR.

## Decision

Stride may project the mathematical consequences of an EXPLICIT plan; it must not choose, rank, or adjust plans.

Allowed — deterministic arithmetic over stated inputs: "if the currently recorded plan is executed as written, projected CTL/ATL/TSB on date D are X/Y/Z"; the same for a hypothetical plan the caller passes in ("these sessions, these dates, these loads"); sensitivity in its raw form ("with session S removed, TSB on D is Z+4") when the caller names the variation. Every projection names its inputs (which plan, which assumed loads, which model constants) so the arithmetic is reproducible, and carries the model's known limits as data (e.g. the CTL warming-up flag's convergence caveat) — the same provenance discipline as ADR 0009 and #157.

Not allowed, ever, from the engine: target values ("aim for TSB +5 on race day"), plan edits ("reduce Thursday's workout", "start tapering now", "add a rest day"), plan generation ("here is a taper that lands you fresh"), or ranking hypotheticals ("plan A is better"). Choosing among futures is judgment about the athlete's goals, constraints, and body — that belongs to the coach (the LLM), which can call the projection arithmetic as many times as it wants with plans of ITS choosing and own the comparison.

The boundary test, stated once: if the output would change because the athlete's GOAL changed, it is prescription and does not belong in stride. Arithmetic over a stated plan is goal-blind; a taper recommendation is not. Direction is part of the rule: stride maps plan → consequences, never target → plan. Solving for the inputs that achieve a stated target ("minimum rest days to reach TSB ≥ 0 by date D") is choosing a plan and is prescription EVEN when the target is caller-stated — the coach brackets such answers itself by projecting candidate plans of its own devising.

## Consequences

- #140's "taper projection" is in scope ONLY as plan-conditional arithmetic (project this recorded/hypothetical taper), never as taper construction; #138's event features may report projected form on the event date under the recorded plan and the gap to any caller-stated hypothetical, nothing more.
- Projection surfaces inherit the existing enforcement machinery: closed-set output shapes where finite, has_coaching_language sweeps over any prose, measurements-only payload fields (#154), and _known flags for absent inputs (ADR 0009).
- A hypothetical plan is caller input, echoed back in the payload verbatim — stride never stores it, so the recorded plan stays the single source of adherence truth (#158).
- Deliberately NOT decided here, deferred to #138/#140: which command surface projections live on, and the input format for hypothetical plans. Projection prose fields, if any, must be closed-set shapes (the has_coaching_language denylist alone would not catch "you are on track" phrasing — the hard guard is equality over finite outputs, as everywhere else since #154).
