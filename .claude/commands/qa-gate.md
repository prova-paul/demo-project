---
description: Run the Phase 1 QA checklist before handing main to the human for deployment promotion.
---

# /qa-gate

Work through `.claude/docs/qa-checklist.md` top to bottom. For each item: check it directly
against real code (grep/read, don't assume from memory of what was built), report pass/fail,
and for any fail, stop and report it rather than silently fixing it — QA gates surface
problems, they don't quietly patch them.

Finish with a summary: what passed, what failed, and whether `main` is ready to hand to the
human for deployment promotion. Promotion itself is never done by the agent.
