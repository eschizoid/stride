# ADR 0009 — Missing values are flagged, not nulled

Date: 2026-08-16. Status: accepted. Issue: #156. PR: #168.

## Context

Stride's JSON payloads coalesce absent measurements to `0` (`COALESCE(m.normalized_power, 0)`), so a client cannot tell "no power meter" from "zero watts". The LLM-coach execution plan asked for literal JSON `null` plus a `schema_version` bump to 3, which is how most APIs draw this line.

Two probes (one in this PR, one independently rebuilt by its reviewer across 14 shapes) showed that literal `null` is not expressible by the Roc builtin encoder on our pinned nightly: every tag stringifies. `None` encodes as `"None"`, a `[Null, Integer(I64)]` union's `Null` arm as `"Null"`, nested unions the same. No tag shape emits `null`.

One shape does express absence: `Try(F64, [Missing])` — `Err(Missing)` omits the key entirely, `Ok(200.0)` emits the bare number. Key omission is the JSON-idiomatic sibling of null and is testable with `has("np_w")`.

## Decision

Absence is carried by additive companion flags, not by null and not by key omission.

- **Impossible-zero fields** (`np_w`, `avg_hr`, `intensity`, `ftp_used`): 0 means "not available", and the row carries `power_known` / `intensity_known` / `hr_known` booleans. The flags decode the **stored NULLs** (`CASE WHEN … IS NULL` in the same SELECT), never the coalesced magnitudes — the database already holds the distinction losslessly, and magnitudes lie (np can be present while intensity is NULL: power stream, no FTP yet).
- **Ambiguous zeros** get a discriminator, not a flag reading: `tss: 0` is read through `load_model` (`""`/`"none"` = unscored); an all-zero zone vector is read through `zones_known` (`hr_samples_total > 0`), because summary `avg_hr` can exist with no HR stream.
- **Both-possible fields** (a real 0 and absence both occur: `decoupling_pct`, `form_delta_7d`, `hr_drift`, `rec_drop_60s`, and `form_tsb` in `analyze`) carry a `_known` flag — the flag is the null. The rule is PER PAYLOAD, not per field name: `summary` ships `form_tsb` bare because it is always computable there, so read the schema for the command rather than assuming a name carries a flag.
- `schema_version` stays 2: every change is a field addition, and the envelope version tracks wrapper-shape changes, not payload growth.

Key omission via `Try(F64, [Missing])` was considered and rejected: dropping a key is a removal (a real `schema_version` bump, plus `has()`-guards in every consumer jq path), while flags are additive and self-describing. If a wrapper bump ever happens for other reasons, revisit — omission would then be free to adopt.

## Consequences

- Consumers (the coach skill first among them) read flags, never magnitudes. The contract lives as the comment block in `src/Output.roc` and the gotcha in `.claude/skills/stride/SKILL.md`; e2e pins both flag presence and flag discrimination (a power ride vs an HR-only row).
- Surfaces: `activity`, `activities`, `plan.recent_activities_14d` carry all four flags + `load_model`; `top` carries the power/intensity/hr trio. `progress` sessions carry none on purpose — rows exist only because the group lens scored them, so the lens signal is present by construction.
- The issue's original "schema v3 + null" instruction is superseded by this ADR. (It was also recorded in the roadmap's priority ledger, which has since been deleted — the roadmap no longer tracks status.)
