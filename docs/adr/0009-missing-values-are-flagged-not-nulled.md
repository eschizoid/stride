# ADR 0009. Missing values are flagged, not nulled

Date: 2026-08-16. Status: accepted. Issue: #156. PR: #168.

## Context

Stride's JSON payloads coalesce absent measurements to `0`, as in
`COALESCE(m.normalized_power, 0)`, so a client cannot tell "no power meter" from "zero
watts". The LLM-coach execution plan asked for literal JSON `null` plus a `schema_version`
bump to 3, which is how most APIs express absence.

Two probes showed that literal `null` is not expressible by the Roc builtin encoder on the
pinned nightly, because every tag stringifies. One probe ran in this PR, and the other was
independently rebuilt by its reviewer across 14 shapes. `None` encodes as `"None"`, the
`Null` arm of a `[Null, Integer(I64)]` union encodes as `"Null"`, and nested unions behave
the same way. No tag shape emits `null`.

One shape does express absence, which is `Try(F64, [Missing])`. `Err(Missing)` omits the key
entirely, and `Ok(200.0)` emits the bare number. Key omission is the other idiomatic JSON
way of expressing absence, and it is testable with `has("np_w")`.

## Decision

Absence is carried by additive companion flags, not by null and not by key omission.

The impossible-zero fields are `np_w`, `avg_hr` and `intensity`. For those fields 0 means
"not available", and the row carries `power_known`, `intensity_known` and `hr_known`
booleans. `ftp_used` is impossible-zero too but deliberately ships no flag, because analyze
always binds it. `ftp_used` is never NULL, and it is 0 whenever the sport has no derivable
FTP, which covers strength sports and unstreamed activities. A flag decoded from stored
NULLs would therefore be all-true and carry no information, which is not the same thing as
the value always being present. Readers discriminate on `ftp_used > 0`, as `doctor` does
for `derived_ftp_sports` and as the ladder does when it falls through to pace, HR and RPE.
Four fields and three flags is not an oversight, and listing them together as though there
were four flags for four fields is how someone adds a phantom `ftp_used_known`. The flags
decode the stored NULLs with `CASE WHEN … IS NULL` in the same SELECT, and never the
coalesced magnitudes. The database already holds the distinction losslessly, and magnitudes
are unreliable, because np can be present while intensity is NULL when there is a power
stream but no FTP yet.

Ambiguous zeros get a discriminator rather than a flag reading. `tss: 0` is read through
`load_model`, where `""` and `"none"` mean unscored. An all-zero zone vector is read through
`zones_known`, which is `hr_samples_total > 0`, because a summary `avg_hr` can exist with no
HR stream.

Both-possible fields carry a `_known` flag, and the flag stands in for the null. A
both-possible field is one where a real 0 and absence both occur, and the fields are
`decoupling_pct`, `form_delta_7d`, `hr_drift`, `rec_drop`, and `form_tsb` in `analyze`. The
rule applies per payload rather than per field name. `summary` ships `form_tsb` with no flag
because it is always computable there, so read the schema for the command rather than
assuming that a name carries a flag.

`schema_version` stays 2, because every change is a field addition, and the envelope version
tracks wrapper-shape changes rather than payload growth.

Key omission through `Try(F64, [Missing])` was considered and rejected. Dropping a key is a
removal, which needs a real `schema_version` bump plus `has()` guards in every consumer jq
path, while flags are additive and self-describing. If a wrapper bump ever happens for other
reasons, revisit the question, because omission would then be free to adopt.

## Consequences

Consumers read flags and never magnitudes, and the coach skill is the first of them. The
contract is recorded as the comment block in `src/Output.roc` and as the warning in
`skills/stride/SKILL.md`. The e2e suite pins both flag presence and flag discrimination,
comparing a power ride against an HR-only row.

The surfaces carry different sets of flags. `activity`, `activities` and
`plan.recent_activities_14d` carry all four flags plus `load_model`, and `top` carries the
power, intensity and hr trio. `progress` sessions carry only `decoupling_known`, which
`progress.json` requires, and no other flag on purpose. Rows exist there only because the
group lens scored them, so the lens signal is present by construction.

The issue's original instruction to use schema v3 plus null is superseded by this ADR. The
instruction was also recorded in the roadmap's priority ledger, which has since been
deleted, because the roadmap that used to track status is retired.

## Update, 2026-09-17

The encoder finding in the context above was measured on the nightly pinned at the time.
Both binaries now build on `nightly-2026-09-16`, and the probe has not been re-run against
it, so the claim that no tag shape emits `null` is unverified on the current compiler. The
decision stands either way, because flags were chosen for being additive and
self-describing rather than for the encoder's limits alone.
