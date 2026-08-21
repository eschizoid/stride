# ADR 0012 — The engine describes state; it never prescribes

Date: 2026-08-17. Status: accepted — shipped as #154/PR #167, recorded here retroactively. Constrains every output surface. ADR 0010 (projection vs prescription) and ADR 0011 (a block is described, never named) both depend on this and were written as though it already existed; it did not.

## Context

This is the oldest settled rule in the project and the only one with no ADR. It is enforced in code, it is the reason several features look the way they do, and two later ADRs cite it as established — but a newcomer reading `docs/adr/` finds nothing, so the obvious question ("why can't `summary` just say you're building?") has no recorded answer and gets relitigated.

The division of labour is: stride computes deterministically and shows its work; the LLM coach reads the numbers and adds judgment. That only holds if the numbers are judgment-free. The moment the engine says "take an easy day", the coach is no longer adding judgment — it is relaying the engine's, without the athlete's context, goals, sleep, or life. Worse, it is doing so in prose that reads as a measurement.

The test, inherited from the execution plan that drove this round:

> **Does this tell us what happened or what the athlete's state is, or does it tell the athlete what to do?**

If it describes measurable state, it can belong in stride. If it recommends an action, it belongs to the coach.

## Decision

**Every human-facing string stride renders is a statement of state. No output recommends, ranks, or evaluates an action.**

Concretely: `form_state` is a band id (`high_modeled_fatigue`, `balanced`, `fresh`, …), not "you should rest". `fade` is a signed delta, not "you faded". A block is described by its slope and polarization, never named "base" or "peak" (ADR 0011). A projection maps a stated plan to its consequences, never a target to a plan (ADR 0010).

**Enforcement is two-layered, and the layers are not equally strong.**

1. **The hard guard is closed-set equality.** Where a producer has finitely many outputs — verdict templates, band labels, state ids — every output is pinned by full-string equality in an `expect`. A reworded template fails the build. This is the guard that actually holds, and five producers carry it today: `form_state`/`form_label`, the compare verdict, `band_days_phrase`, `trend_label`, and `backfill_note` (whose producer side is a TAG, so the compiler closes the set and one composed expect ties the tag to the string). `tte_screen`'s phrases carry only the denylist sweep. It is not every finite producer in the codebase, and the ones without it are not guarded whatever the sweep suggests — the first draft of this very sentence credited `tte_screen` with an equality pin it does not have, which is the failure mode in miniature.

   **Equality, and not `Str.contains`.** The distinction is the whole guard. Pinning `trend_label` (#165) was first attempted as `Str.contains(rendered, "holding steady")` and passed a mutation to `"holding steadyZ"` — because the superstring contains the substring. A `contains` check accepts every extension of the string it names, so it cannot pin a closed set; it is a denylist wearing an allowlist's clothes. That is also why `trend_label` exists as a named function at all: an inline `if` inside a render path can only be checked through its rendered output, which is exactly the check that does not work.
2. **`Metrics.has_coaching_language` is defence-in-depth only.** A denylist of ~30 substrings swept over every prose producer. It exists to backstop the branches equality cannot reach, and its own comment records why it can never be primary: round-3 mutation testing proved "take it easier" and "push harder" slipped the round-2 list. A denylist can only catch the phrasings someone thought of.

The distinction matters because it is easy to add a producer, sweep it with the denylist, and believe it is guarded. It is not. New finite producers get closed-set pins.

## Consequences

- Adding a prose output surface means adding it to the boundary sweep in `src/Render.roc` — `compare_verdict`, `form_trend_phrase`, `band_days_phrase`, `warming_up_note`, `trend_label`, `tte_screen` and `backfill_note` are swept today. `season_screen` deliberately renders no verdict line at all, which is the cleanest way to satisfy this rule.
- The gap is real and it recurs: `trend_label` shipped with NEITHER guard and stayed that way until this ADR was written and someone checked its claims against the code. Writing "every finite producer is pinned" did not pin anything. Prefer counting the pins to asserting the invariant.
- The rule constrains field NAMES as well as prose. `fade` names one of its two directions and is a measurement wearing a verdict's name; it survives because it is house vocabulary shared with the athlete, but a new field should prefer the neutral form.
- It also constrains what stride is allowed to be good at. "Which workout should I do Tuesday?" is a question stride will never answer, and that is a product decision, not a limitation to be engineered around.
- The denylist will keep being insufficient. That is expected, not a defect — it is the second layer. When a mutation slips it, the fix is a closed-set pin on the producer that leaked, not a longer word list.

## Not doing

Extending this to the machine payload as a blanket rule. JSON fields are measurements by construction, and a `_known` flag or a `model_exceeded` boolean is a diagnosis of the model, not advice to the athlete. The rule bites on rendered prose and on any field whose NAME asserts a judgment.
