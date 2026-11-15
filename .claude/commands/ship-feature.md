---
description: Build the next feature on its own branch — plan → approve → branch → implement → verify → self-merge to main.
---

# /ship-feature — interactive, one feature at a time

Ship exactly **one** feature from the current phase, on its own branch off `main`, with the
user approving the plan before any code is written. Never build more than one feature per run.
Never jump ahead of the current phase. Full git rules → `.claude/docs/git-workflow.md`.

If the user named a feature in the arguments, build that one. Otherwise read `PROGRESS.md` and
pick the **next unchecked item in the lowest incomplete phase**, respecting the dependency
order in `build-order-complete.md` — do not pick an item whose dependency isn't done yet.

## Steps — follow in order, do not skip

1. **Plan (gate).** Read the relevant docs (index in `CLAUDE.md`). If this feature touches
   `admin_users`, sessions, or roles, read `rbac-and-security.md` in full — the session fix
   must not be silently skipped or assumed done. Present a short plan: what you'll build, which
   files, which schema changes, and this feature's concrete test cases. **Stop and wait for
   approval.** No code until approved.

2. **Branch.** `git checkout main && git pull`, then `git checkout -b feature/p1-<name>`.

3. **Schema first (if needed).** New tables/columns → write the migration
   (`npm run db:generate` against the updated schema file, then `npm run db:migrate`) → confirm
   it applies cleanly before building on it.

4. **Implement.** Follow `api-conventions.md`'s layering exactly. TypeScript strict.

5. **Verify.** `npm run test`, `npm run test:e2e`, `npx tsc --noEmit` — all must be green.
   For anything touching admin auth or payments, manually exercise the real flow, don't rely on
   tests alone.

6. **Self-merge.** `git checkout main`, `git merge --squash feature/p1-<name> && git commit`,
   `git push origin main`.

7. **Record.** Tick `PROGRESS.md`. If you noticed something out of scope (branding, an
   unrelated bug), add it under a "Noticed" note there instead of fixing it now.

8. **Clean up + hand back.** `git branch -d feature/p1-<name>`. Summarize what shipped, show the
   diff summary, ask for review. **Wait for "next."**

## Guardrails
- **Never commit/merge/push to `production` (or a legacy `staging`).** `main` is the integration branch you merge into; deployment promotion is human-owned.
- Never modify the admin-session verification logic without going through the plan-approval
  gate — this is security-sensitive code, not routine refactoring.
- If you hit a missing secret, an ambiguous product decision, or a repeated test failure you
  can't resolve, **stop and ask** — don't guess.
