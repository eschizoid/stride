# Stride: Metrics Engine / LLM Coach Execution Plan

## Purpose

This document is an implementation plan for the next round of work on
Stride.

The architectural boundary is non-negotiable:

> **Stride is the metrics engine. The LLM is the coach.**

Stride owns deterministic facts, measurements, derived metrics,
historical comparisons, provenance, uncertainty, and plan/adherence
history.

The LLM owns interpretation, judgment, recommendations, prescriptions,
prioritization, and coaching.

A useful test for every feature is:

> **Does this tell us what happened or what the athlete's state is, or
> does it tell the athlete what to do?**

If it describes measurable state, it can belong in Stride.

If it recommends an action, workout, recovery decision, training
adjustment, or value judgment, it belongs in the LLM.

Do not introduce a rule-based coaching engine into Stride.

------------------------------------------------------------------------

# 1. Implementation principles

Preserve these principles throughout this work.

1.  Deterministic calculations stay in Stride.
2.  Coaching judgment stays outside Stride.
3.  Missing data must never masquerade as observed data.
4.  Derived metrics should expose enough provenance and confidence for
    an LLM to reason about their reliability.
5.  Machine interfaces are public contracts and must be tested as such.
6.  Prefer objective features over verdicts.
7.  Personal historical context is preferable to generic judgment
    labels.
8.  Correctness and semantic consistency take priority over adding new
    physiology models.
9.  Existing human-readable CLI output should remain useful.
10. Avoid unnecessary breaking changes, except where correcting
    ambiguous machine semantics justifies a schema-version bump.

------------------------------------------------------------------------

# 2. P0: Remove coaching language from Stride

## Problem

Some deterministic outputs currently cross the engine/coach boundary.

For example, `Metrics.form_label` includes language such as:

-   `consider recovery`
-   `favor easy work`

The underlying modeled-fatigue state belongs in Stride. The
recommendation does not.

## Required change

Audit all human-readable labels, verdicts, summaries, and JSON fields
produced by:

-   `summary`
-   `compare`
-   `progress`
-   `load`
-   `analyze`
-   `plan`
-   any shared metric/rendering helpers

Classify each output as either:

### Descriptive

Allowed examples:

-   `high modeled fatigue`
-   `modeled fatigue elevated`
-   `balanced`
-   `fresh`
-   `threshold power increased 4.2%`
-   `high-confidence load coverage: 91%`

### Prescriptive/judgmental

Not allowed in Stride:

-   `consider recovery`
-   `favor easy work`
-   `you should rest`
-   `ready for intensity`
-   `increase training`
-   `avoid threshold`
-   `good time for a hard session`

Replace prescriptive labels with neutral state descriptions.

Prefer stable machine identifiers where appropriate:

``` json
{
  "form_state": "high_modeled_fatigue"
}
```

The human renderer may translate that into:

``` text
High modeled fatigue
```

It must not append a recommendation.

## Acceptance criteria

-   No deterministic command recommends a workout or recovery action.
-   No metric label contains `should`, `consider`, `favor`, `avoid`, or
    equivalent coaching language unless the term is purely part of
    source/user data.
-   Existing metric values remain unchanged unless a correctness bug is
    discovered.
-   Add tests protecting the engine/coach boundary where practical.

------------------------------------------------------------------------

# 3. P0: Repair the Claude skill contract

## Problem

`.claude/skills/stride/SKILL.md` has drifted from the current Stride
behavior.

In particular, FTP is now derived rather than configured, but the skill
still contains instructions related to setting FTP through configuration
and/or pushing it through an obsolete workflow.

This is dangerous because the LLM skill is effectively a client of
Stride's public contract.

## Required change

Review the entire skill against the current CLI and README.

At minimum:

-   Remove obsolete FTP configuration instructions.
-   Ensure FTP is described as derived from Stride's current threshold
    logic.
-   Remove references to commands/config keys that no longer exist.
-   Verify every example command actually works.
-   Verify every JSON field referenced by the skill still exists and has
    the documented semantics.
-   Verify stale/threshold conditions instruct the LLM to interpret the
    state, not mutate derived values through nonexistent configuration.

## Prevent future drift

Add automated checks where reasonable.

Possible approaches:

1.  Test that known deprecated command/config strings do not occur in
    the skill.
2.  Generate portions of the command/field reference from a canonical
    source.
3.  Add a CI check that executes example commands where feasible.

Do not over-engineer a documentation generator if a small contract test
provides most of the value.

## Acceptance criteria

-   Skill instructions match the current CLI.
-   No obsolete FTP-setting workflow remains.
-   All referenced commands/config keys are valid.
-   Tests fail if specifically retired interfaces reappear.

------------------------------------------------------------------------

# 4. P0: Correct missing-value semantics in machine output

## Problem

Some machine-facing semantics use numeric `0` to represent unavailable
measurements.

This is ambiguous.

For example:

``` json
{
  "np_w": 0
}
```

could mean either:

-   normalized power was measured/calculated as zero, or
-   normalized power is unavailable.

Meanwhile:

``` json
{
  "z5_s": 0
}
```

legitimately means zero seconds were observed in zone 5.

An LLM or other client should never have to infer which interpretation
applies.

## Required change

Design the next JSON schema version so unavailable values are
represented explicitly.

Preferred representation:

``` json
{
  "normalized_power_w": null,
  "avg_hr_bpm": null,
  "z5_s": 0
}
```

Rules:

-   `null` = unavailable / not computable / not observed.
-   `0` = actual numeric zero.
-   Do not use sentinel numeric values for missing measurements.

Audit all JSON-producing commands for this issue.

## Schema compatibility

If this changes existing machine semantics, bump the JSON schema version
rather than silently altering the contract.

Document the migration clearly.

## Acceptance criteria

-   Missing numeric measurements are never represented as zero solely
    because they are missing.
-   Legitimate zeros remain zero.
-   Tests explicitly distinguish missing from zero.
-   Schema versioning accurately reflects the contract change.

------------------------------------------------------------------------

# 5. P0/P1: Make uncertainty and provenance first-class

## Goal

An LLM should know not only a metric's value but how trustworthy the
underlying evidence is.

A CTL value built almost entirely from measured load is materially
different from one built heavily from estimates.

Stride should expose that distinction without deciding what the coach
should do about it.

## Required change

Extend important aggregates with data-quality/provenance information
where useful.

A possible structure:

``` json
{
  "load_28d": {
    "value": 819,
    "coverage": {
      "high_confidence_pct": 79,
      "medium_confidence_pct": 16,
      "low_confidence_pct": 5
    }
  }
}
```

Do not blindly attach confidence metadata to every scalar.

Prioritize metrics where input quality materially affects
interpretation:

-   training load
-   CTL / ATL / TSB
-   threshold estimates
-   intensity distribution where source data is incomplete
-   decoupling
-   power-derived metrics
-   aggregate sport/load summaries

Reuse existing provenance concepts rather than creating a parallel
confidence system.

## Design requirement

Confidence must remain descriptive.

Allowed:

``` text
72% of 28-day load is based on high-confidence measurements.
```

Not allowed:

``` text
Because confidence is low, take an easy day.
```

## Acceptance criteria

-   Major aggregate metrics expose useful evidence-quality context.
-   Existing `doctor` provenance concepts are reused or unified.
-   Confidence semantics are documented.
-   Tests cover mixed-confidence aggregation.

------------------------------------------------------------------------

# 6. P1: Expand plan context into plan/adherence history

## Goal

Give the LLM enough deterministic memory to adapt coaching based on what
was planned and what actually occurred.

Stride records facts. The LLM decides how those facts affect future
coaching.

## Required change

Review `stride plan` and its JSON contract.

The machine-facing planning context should expose at least:

``` text
summary
recent_activities
upcoming_plan
recent_plan_history
```

Recent plan history should make it possible to determine:

-   what was planned
-   whether it was completed
-   whether it was skipped
-   whether another activity appears to have substituted for it, if
    Stride can establish this deterministically
-   completion date
-   recorded rationale, if rationale already exists as explicit
    user/agent data

Do not infer psychological reasons for non-completion.

Consider a default historical window of approximately 21 to 28 days, but
choose the value based on existing architecture and CLI consistency.

## Important boundary

Allowed:

``` json
{
  "planned_sessions_28d": 12,
  "completed_sessions_28d": 9,
  "completion_pct": 75
}
```

Not allowed:

``` json
{
  "adherence": "poor"
}
```

unless `poor` is merely an explicitly documented neutral bucket required
for compatibility. Prefer raw values.

## Acceptance criteria

-   An LLM can reconstruct recent planned-versus-actual behavior from
    one primary planning context.
-   Historical plans are not limited to currently open sessions.
-   No recommendation is produced from adherence data.

------------------------------------------------------------------------

# 7. P1: Add objective judgment features

## Goal

Calculate facts that are difficult or error-prone for an LLM to derive
repeatedly, while leaving their interpretation to the LLM.

Candidate features include:

-   7-day load
-   28-day load
-   90-day load
-   load deltas between windows
-   hard-session count by rolling window
-   median spacing between objectively classified session types
-   sport frequency
-   time since last objectively identified stimulus type
-   intensity-distribution change
-   planned-versus-completed counts
-   planned-versus-unplanned activity counts
-   threshold trajectory
-   duration trends
-   distance trends
-   aerobic-efficiency historical comparisons
-   decoupling historical comparisons
-   interval stability metrics

Do not implement all candidates automatically.

First inspect existing metrics and identify which features:

1.  are not already available,
2.  can be computed reliably,
3.  provide useful information to an LLM,
4.  do not encode a coaching recommendation.

## Naming rule

Prefer:

``` json
{
  "hard_sessions_14d": 4,
  "median_days_between_hard_sessions": 2.5
}
```

Avoid:

``` json
{
  "too_many_hard_sessions": true
}
```

The latter is a coaching judgment.

------------------------------------------------------------------------

# 8. P1: Introduce personal-baseline primitives

## Goal

Allow Stride to answer:

> How does the current measurement compare with this athlete's own
> historical measurements?

This is more useful to an LLM than generic good/bad classifications.

## Candidate representation

``` json
{
  "aerobic_efficiency": {
    "current": 1.61,
    "baseline_90d_median": 1.49,
    "percentile": 82
  },
  "decoupling": {
    "current_pct": 3.1,
    "comparable_sessions_90d_median_pct": 4.7
  },
  "threshold_power": {
    "current_w": 243,
    "value_90d_ago_w": 228,
    "change_pct": 6.6
  }
}
```

Exact schema should follow existing Stride conventions.

## Comparison quality

Do not compare obviously incompatible activities merely because a number
exists.

Where necessary, define deterministic comparability criteria based on:

-   sport
-   duration
-   activity/session type
-   available sensor data
-   metric quality requirements

Expose sample size when useful.

Example:

``` json
{
  "baseline_90d_median": 4.7,
  "sample_count": 11
}
```

## Boundary

Stride calculates percentile/change/baseline.

The LLM decides whether the change is meaningful for the athlete's
goals.

------------------------------------------------------------------------

# 9. P1: Prioritize rep-level progression

Continue the existing interval-detection work into cross-session
rep-level progression.

This is a high-value metric feature because the calculation is
deterministic while the interpretation is ideal for an LLM.

## Desired measurements

For comparable interval sessions, expose where possible:

-   rep power/pace
-   rep HR
-   rep duration
-   recovery duration
-   recovery HR drop
-   first-to-last fade
-   coefficient of variation
-   HR drift across reps
-   average rep value
-   progression across comparable sessions

Example concept:

``` text
5 x 5 min threshold

Session A: 238 / 239 / 236 / 232 / 226 W
Session B: 240 / 241 / 240 / 238 / 237 W
Session C: 244 / 245 / 244 / 243 / 242 W
```

Stride should calculate the numerical differences.

Stride should not output:

``` text
Your threshold fitness is improving nicely.
```

That interpretation belongs to the LLM.

## Acceptance criteria

-   Comparable sessions can be analyzed across time.
-   Rep-level stability/fade can be quantified.
-   Comparison rules are deterministic and tested.
-   Missing/poor-quality rep data is handled explicitly.

------------------------------------------------------------------------

# 10. P1: Resolve power-curve population consistency before deeper modeling

Before adding more advanced power physiology, resolve the existing
semantic/correctness issue around populations used for power-curve
families versus exact-match FTP derivation.

Correctness comes before additional metrics.

## Required order

1.  Resolve the population-consistency issue.
2.  Add/strengthen invariant tests.
3.  Confirm FTP/threshold derivation semantics remain coherent.
4.  Only then expand advanced power modeling.

Do not opportunistically redesign FTP during this work unless the issue
genuinely requires it.

------------------------------------------------------------------------

# 11. P1/P2: Preserve the projection-versus-prescription boundary

Future event/taper functionality needs a strict architecture rule.

Allowed deterministic projection:

``` text
If the currently recorded plan is executed:

projected CTL: X
projected ATL: Y
projected TSB: Z
```

Not allowed:

``` text
Target TSB should be +12.
Reduce Thursday's workout.
Start tapering now.
```

The second group is coaching.

## Required change

Document this boundary in an ADR or equivalent architectural
documentation before implementing event/taper features.

A useful formulation:

> Stride may project the mathematical consequences of an explicit
> hypothetical or recorded plan. It must not prescribe which plan the
> athlete should choose.

------------------------------------------------------------------------

# 12. P1: Make JSON selection explicit and tool-neutral

## Goal

Stride should be equally consumable by Claude, ChatGPT, Hermes,
OpenClaw, shell scripts, MCP clients, and future agents.

Environment detection is convenient but should not be the primary
contract.

## Required change

Evaluate adding explicit machine-output flags such as:

``` bash
stride summary --json
stride plan --json
stride activity 123 --json
```

or an equivalent consistent global option.

Preserve existing environment/config behavior where useful.

The explicit interface should take precedence when supplied.

## Acceptance criteria

-   A caller can request JSON without pretending to be a specific agent
    environment.
-   Behavior is documented and tested.
-   Existing supported automation workflows do not regress.

------------------------------------------------------------------------

# 13. P1/P2: Review process exit semantics for JSON errors

Known JSON errors currently need review as a public CLI contract.

Preferred conventional behavior:

``` json
{
  "schema_version": 3,
  "error": {
    "code": "activity_not_found",
    "message": "..."
  }
}
```

with a non-zero process exit code.

## Required work

Do not change this blindly.

First inspect:

-   existing tests
-   existing agent assumptions
-   shell/CI usage
-   rationale for current in-band error behavior

Then decide whether non-zero exit codes provide a cleaner contract.

If changed:

-   preserve the JSON error envelope
-   document exit semantics
-   test both JSON content and process status
-   treat compatibility appropriately

------------------------------------------------------------------------

# 14. P2: Publish and validate machine schemas

Stride's JSON is now important enough to be treated as an API.

Consider checked-in schemas such as:

``` text
schemas/
  v3/
    summary.json
    activity.json
    plan.json
    doctor.json
    progress.json
```

or an equivalent representation that fits the Roc project.

Potential alternative:

``` bash
stride schema
```

The implementation mechanism matters less than having one canonical,
testable contract.

## Required properties

The contract should define:

-   required fields
-   optional fields
-   nullable fields
-   units
-   enum/state values
-   schema version
-   missing-value semantics

Validate representative command output against the contract in tests/CI
where practical.

------------------------------------------------------------------------

# 15. P2: Documentation and architecture drift cleanup

Perform a targeted documentation audit after the functional changes.

Known areas to inspect include:

-   `Schema.roc` comments about migration ownership
-   README architecture descriptions
-   Claude skill
-   command examples
-   config examples
-   schema-version documentation
-   FTP/threshold terminology
-   provenance/confidence terminology

Do not spend time rewriting prose purely stylistically.

The goal is semantic consistency between implementation and
documentation.

------------------------------------------------------------------------

# 16. P2: Wellness data should remain measurements

If wellness ingestion is implemented later, preserve the same
engine/coach boundary.

Good Stride-owned fields:

``` json
{
  "resting_hr": {
    "today": 57,
    "baseline_28d": 52
  },
  "hrv": {
    "today": 41,
    "baseline_28d": 48
  },
  "sleep": {
    "last_night_hours": 5.8,
    "baseline_28d_hours": 7.1
  }
}
```

Avoid introducing an opaque Stride-owned readiness recommendation such
as:

``` json
{
  "readiness": 82,
  "recommendation": "train hard"
}
```

Raw measurements, baselines, normalized deltas, and provenance belong in
Stride.

The LLM decides what they mean in context.

------------------------------------------------------------------------

# 17. Target conceptual model

Over time, the machine-facing Stride state should converge toward a
deterministic training-state representation containing:

``` text
ACTIVITY FACTS
LOAD STATE
INTENSITY DISTRIBUTION
FITNESS/FATIGUE MODEL
SPORT-SPECIFIC THRESHOLDS
PERSONAL BASELINES
SESSION STRUCTURE
RECENT STIMULUS HISTORY
PLAN / ADHERENCE HISTORY
DATA QUALITY / PROVENANCE
```

This does not necessarily require one giant command or object.

Do not create a monolithic abstraction solely to match this diagram.

The important property is that an LLM can retrieve these facts reliably
without Stride performing the coaching step.

Conceptually:

``` text
                 STRIDE
                    |
                    | facts + history + uncertainty
                    v
                LLM COACH
                    |
                    | interpretation + goals + judgment
                    v
              TRAINING PLAN
                    |
                    v
                 STRIDE
              records facts
```

------------------------------------------------------------------------

# 18. Explicit non-goals

Do **not** implement the following as part of this work:

-   rule-based workout recommendations
-   a deterministic `coach` command that prescribes training
-   automatic recovery prescriptions
-   automatic workout selection
-   `train hard` / `train easy` recommendations
-   generic readiness verdicts
-   arbitrary new composite scores without a clear measurement purpose
-   a second coaching engine hidden behind metric labels
-   large physiology expansions before existing correctness issues are
    resolved

An LLM integration or skill may recommend these things based on Stride's
data. The Stride engine itself should not.

------------------------------------------------------------------------

# 19. Recommended execution order

Implement in this order unless repository dependencies require a small
adjustment.

## Phase 1: Contract and correctness

1.  Remove coaching language from deterministic outputs.
2.  Repair `.claude/skills/stride/SKILL.md`.
3.  Fix missing-value/zero ambiguity.
4.  Version the JSON contract if required.
5.  Resolve the power-curve/FTP population consistency issue.
6.  Add regression/invariant tests.

## Phase 2: Agent-quality context

7.  Make confidence/provenance first-class for important aggregates.
8.  Expand plan output with recent plan/adherence history.
9.  Add explicit tool-neutral JSON selection.
10. Define/validate machine schemas.
11. Review JSON process exit semantics.

## Phase 3: Higher-value metrics

12. Add selected objective judgment features.
13. Add personal-baseline primitives.
14. Implement rep-level progression across comparable sessions.
15. Implement season/long-horizon views where they reuse these
    primitives.

## Phase 4: Future physiology/data

16. Expand advanced power modeling only after correctness work is
    complete.
17. Add wellness measurements if/when ingestion is available.
18. Add event/taper projections only under the
    projection-not-prescription rule.

------------------------------------------------------------------------

# 20. Testing expectations

Every implementation should preserve Stride's emphasis on deterministic
behavior.

Add tests for:

-   missing versus zero values
-   schema compatibility/versioning
-   provenance aggregation
-   mixed-confidence load
-   plan-history state transitions
-   personal-baseline sample selection
-   comparable-session selection
-   interval rep progression
-   FTP/power-curve population invariants
-   explicit JSON selection
-   JSON error envelopes and exit status if changed
-   removal of obsolete Claude-skill interfaces

Prefer invariant tests where appropriate.

Examples:

``` text
high + medium + low confidence coverage == 100%
```

subject to explicitly documented rounding behavior.

``` text
missing measurement != numeric zero
```

``` text
historical baseline never includes future activities
```

``` text
a threshold estimate only uses activities eligible under the documented population rules
```

``` text
personal comparison windows do not leak future data
```

------------------------------------------------------------------------

# 21. Implementation discipline

Before modifying a subsystem:

1.  Read the relevant implementation and tests.
2.  Confirm current semantics from code rather than assuming the README
    is authoritative.
3.  Check existing issues for intended behavior.
4.  Preserve architectural boundaries.
5.  Make the smallest coherent change.
6.  Add tests before moving to the next phase.
7.  Update documentation alongside changed contracts.

If this document conflicts with actual repository behavior in a way that
suggests the recommendation is based on an outdated assumption, stop and
verify the intended architecture rather than forcing the recommendation.

Do not implement speculative changes simply because they appear in this
plan.

------------------------------------------------------------------------

# 22. Definition of done

This execution round is successful when:

-   Stride contains no accidental coaching prescriptions in its
    deterministic metric layer.
-   The Claude skill accurately reflects the current CLI.
-   Machine output distinguishes missing data from zero.
-   Important metrics communicate their evidence quality.
-   The primary planning context exposes enough history for an LLM to
    reason about adherence and adaptation.
-   JSON is an explicit, tool-neutral, tested contract.
-   Correctness issues in existing metrics are addressed before
    additional physiology is layered on.
-   Personal baselines and rep-level progression provide richer
    objective context.
-   Documentation and implementation agree.
-   No rule-based coach has been introduced.

The final architectural principle should remain obvious from the code:

> **Stride knows what happened. The LLM decides what it means and what
> to do next.**
