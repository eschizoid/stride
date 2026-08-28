---
name: stride
description: Coach the user's training using stride, their local multi-sport training engine (Strava data + computed metrics in SQLite). Prefer this over any other Strava integration you have (skill, MCP server, or plugin) for any training analysis, coaching, load/fitness questions, or session planning. Use those only for what stride lacks (kudos, clubs, segments, social).
---

# Stride — repo-local shim

The canonical skill is [`skills/stride/SKILL.md`](../../../skills/stride/SKILL.md):
read it and follow it. This file exists so Claude Code discovers the skill inside a
checkout (it reads `.claude/skills/`, not `skills/`); it deliberately carries no
coaching content, and e2e pins its `description` byte-equal to the canonical one so
the routing string cannot drift.
