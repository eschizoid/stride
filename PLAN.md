# 1.0 execution order

Sequencing only. Every item is a pointer; the tickets hold the work, and GitHub keeps
their state true for free. If you find yourself describing what a ticket contains here,
the file has started rotting — that is what happened to the last one, and it is why
AGENTS.md permits this one only under those terms.

**Delete this file when the order below is merged.** It has no other purpose, and that is
not left to good intentions: this file remains open until #220 lands. `just issue-claims`
reads that as a state claim, so the day #220 closes, CI goes red naming this file. The
last plan file survived because deleting it was a request nobody was holding.

## The two constraints that set the order

1. **#217 must land before anything changes a payload shape.** The envelope rule says
   adding a key is non-breaking; every schema carries `additionalKeys: false`, so a
   consumer validating against one breaks on an added key. #221 adds keys and #219
   retypes `commands`. Deciding the policy after shipping either is backwards.
2. **File contention.** #216 and #217 both edit `docs/adr/0000-architecture.md`. #218,
   #219 and #138 all touch `src/app.roc`, and #219 and #138 both touch `src/Command.roc`.
   That is why the code steps are sequential rather than parallel PRs.

## Order

1. #216 + #217 — one PR, same file
2. #218, then #221
3. #219
4. #220

Independent of all four, startable any time: **#138**, then **#189**.
