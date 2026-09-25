# ADR 0012. The engine describes state; it never prescribes

Date: 2026-08-17. Status: accepted, shipped as #154/PR #167, recorded here retroactively. Constrains every output surface. ADR 0010 (projection vs prescription) and ADR 0011 (a block is described, never named) both depend on this rule and were written as though it already existed, which it did not.

## Context

The rule recorded here is the oldest settled rule in the project and the only one that had no ADR. It is enforced in code, it explains why several features look the way they do, and two later ADRs cite it as established. A newcomer reading `docs/adr/` found nothing, so the obvious question, "why can't `summary` just say you're building?", had no recorded answer and kept being argued again.

The division of labour runs as follows. First, stride computes deterministically and shows its work. Second, the LLM coach reads the numbers and adds judgment. The split only holds if the numbers are free of judgment. When the engine says "take an easy day", the coach relays the engine's judgment rather than adding its own, and it does so without the athlete's context, goals, sleep or life. It also does so in prose that reads as a measurement.

The test comes from the execution plan that drove this round, and it is quoted here in full.

> Does this tell us what happened or what the athlete's state is, or does it tell the athlete what to do?

An output that describes measurable state can belong in stride, and an output that recommends an action belongs to the coach.

## Decision

Every human-facing string stride renders is a statement of state, and no output recommends, ranks or evaluates an action.

The rule has concrete consequences in the shipped surfaces. `form_state` is a band id such as `high_modeled_fatigue`, `balanced` or `fresh` rather than the sentence "you should rest", and `fade` is a signed delta rather than the sentence "you faded". A block is described by its slope and polarization rather than named "base" or "peak" (ADR 0011), and a projection maps a stated plan to its consequences rather than a target to a plan (ADR 0010).

Enforcement has two layers, and the layers are not equally strong.

The first layer, and the hard guard, is closed-set equality. Where a producer has finitely many outputs, such as verdict templates, band labels and state ids, every output is pinned by full-string equality in an `expect`, so a reworded template fails the build. Equality is the guard that actually holds, and five producers carry it today, namely `form_state`/`form_label`, the compare verdict, `band_days_phrase`, `trend_label` and `drain_note`. The producer side of `drain_note` is a tag, so the compiler closes the set, and three composed expects plus a `List.all` over the produced labels tie tag to string, one by equality and two by prefix. The phrases of `tte_screen` carry only the denylist sweep. Equality does not cover every finite producer in the codebase, and the ones without it are not guarded whatever the sweep suggests, since the first draft of this very sentence credited `tte_screen` with an equality pin it does not have, which is the failure mode in miniature.

The guard is equality and not `Str.contains`, and the distinction is the whole guard. Pinning `trend_label` (#165) was first attempted as `Str.contains(rendered, "holding steady")`, and it passed a mutation to `"holding steadyZ"`, because the superstring contains the substring. A `contains` check accepts every extension of the string it names, so it cannot pin a closed set, and it gives the partial protection of a denylist while looking like an allowlist. The same point is why `trend_label` exists as a named function at all, because an inline `if` inside a render path can only be checked through its rendered output, which is exactly the check that does not work.

The second layer, `Metrics.has_coaching_language`, is defence in depth only. It is a denylist of about 30 substrings swept over every prose producer, and it exists to backstop the branches equality cannot reach. Its own comment records why it can never be primary, because round-3 mutation testing proved that "take it easier" and "push harder" slipped the round-2 list. A denylist can only catch the phrasings someone thought of.

The distinction between the two layers is easy to lose, because a new producer can be added, swept with the denylist, and believed to be guarded when it is not. New finite producers get closed-set pins.

## Consequences

Adding a prose output surface means adding it to the boundary sweep in `src/cli/Render.roc`, and the producers swept today are `compare_verdict`, `form_trend_phrase`, `band_days_phrase`, `warming_up_note`, `trend_label`, `tte_screen` and `drain_note`. `season_screen` deliberately renders no verdict line at all, which is the cleanest way to satisfy this rule.

The gap between the two layers is real and it recurs. `trend_label` shipped with neither guard and stayed that way until this ADR was written and someone checked its claims against the code. Writing "every finite producer is pinned" did not pin anything, so counting the pins is better than asserting the invariant.

The rule constrains field names as well as prose. `fade` names one of its two directions and is a measurement whose name states a verdict. It survives because it is house vocabulary shared with the athlete, and a new field should prefer the neutral form.

The rule also constrains what stride is allowed to be good at. "Which workout should I do Tuesday?" is a question stride will never answer, and that is a product decision rather than a limitation to be engineered around.

The denylist will keep being insufficient, which is expected of a second layer rather than a defect in it. When a mutation slips past it, the fix is a closed-set pin on the producer that leaked rather than a longer word list.

## Not doing

The rule is not extended to the machine payload as a blanket rule. JSON fields are measurements by construction, and a `_known` flag or a `model_exceeded` boolean diagnoses the model rather than advising the athlete. The rule applies to rendered prose and to any field whose name asserts a judgment.
