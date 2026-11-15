# TriplyAI Backend — `.claude/` context folder

This folder gives Claude Code focused, on-demand context instead of one giant file.

## What lives where

| File | Purpose | When it's read |
|---|---|---|
| `../CLAUDE.md` | Lean brief — rules, stack, phase scope, doc index. **Auto-loaded** every session. | Always |
| `../build-order-complete.md` | Sequenced Phase 1 build prompts, in dependency order. | Picking the next feature |
| `../PROGRESS.md` | Live "what's actually built" log, cross-checked against real code. | Start of each session |
| `docs/database-schema.md` | Real current schema summary + Phase 1 additions. | Any data work |
| `docs/api-conventions.md` | Module layering pattern, real examples from the admin module. | Any new module/endpoint |
| `docs/rbac-and-security.md` | The 4-role system + the admin-session forgery fix (do this first). | Admin/auth work |
| `docs/content-library.md` | Itinerary library/publishing system — schema, workflow, endpoints. | Content system work |
| `docs/payments.md` | Stripe audit checklist + SSLCommerz integration spec. | Payment work |
| `../docs/ai-model-assignment-plan.md` | Existing, authoritative AI routing spec — don't duplicate it. | Model routing work |
| `docs/infrastructure.md` | Env vars, PM2 config, deployment reality (no CI/CD yet). | Setup/deploy work |
| `docs/git-workflow.md` | Branch model, per-feature flow, promotion. | Any git work |
| `docs/testing.md` | Jest/Supertest conventions already in use. | Any test work |
| `docs/qa-checklist.md` | Phase gate checklist + the "already built, don't rebuild" list. | Any phase gate |
| `docs/branding.md` | The three-name problem and the single cleanup pass to fix it. | Branding-touching work |
| `.githooks/` | pre-commit/pre-push: block staging/main, check branch names. | Activate at git init |
| `commands/ship-feature.md` | `/ship-feature` — build one feature, gated rhythm. | You invoke it |
| `commands/qa-gate.md` | `/qa-gate` — run the QA checklist for a phase. | You invoke it |
| `hooks/verify.sh` | Post-turn `tsc` + `jest` gate. | Automatic (Stop hook) |
| `settings.json` | Pre-approved safe commands + Stop hook wiring. | Automatic |

## How we build (interactive mode)

One feature at a time with `/ship-feature`: plan → **you approve** → implement → verify →
commit → **you review** → next. You're in the loop on every feature.

## Precedence

When a `docs/*.md` file and `CLAUDE.md` disagree, the `docs/` file wins. When
`docs/ai-model-assignment-plan.md` and anything else disagree on AI routing, that file wins —
it was written against the real code, not a spec draft.

## Build discipline

- Build strictly in phase order. Never jump ahead.
- Test + commit after every feature.
- Update `PROGRESS.md` when a feature ships.
- **Do not "fix while you're in there."** If you notice the branding issue, an unrelated bug,
  or a refactor opportunity while building a feature, note it in `PROGRESS.md` under a "Noticed"
  section and keep going — don't scope-creep the current feature.
