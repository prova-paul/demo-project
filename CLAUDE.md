# TriplyAI Backend — CLAUDE.md

> **This file is the always-loaded brief.** Keep it short and stable. Detail lives in
> `.claude/docs/*` and is read on demand — see the pointer index at the bottom. When a doc
> and this file disagree, the doc wins.

## What this is

The NestJS backend for TriplyAI, an AI itinerary planner. Repo: `Journey-Planner-Backend`
(branch `production`). This backend is deployed at **developer.trytriplyai.com**.

**Three repos, three domains** (the admin console was split out of the frontend repo — if a doc
still implies admin UI lives in the frontend repo, that doc is stale):

| Repo | Domain | What it is |
|---|---|---|
| `Journey-Planner-Backend` | `developer.trytriplyai.com` | This repo — NestJS API |
| `Journey-Planner-Frontend` | `trytriplyai.com` | Public site (live) |
| `triply-console` | `console.trytriplyai.com` | Admin console (new, split out of the frontend) |

Each is a separate Claude Code project with its own `CLAUDE.md`. **This backend serves both
frontends**, and they call it differently — the public site proxies server-side through its own
BFF routes, the admin console calls this API directly from the browser. That difference is why
CORS and cookie attributes matter here; see `.claude/docs/infrastructure.md`.

**⚠️ Branding note:** the codebase currently contains three different product names —
"Journey Crafter" (repo name, some metadata examples), "TripTailor" (`.env.example` company
address/socials), and "TriplyAI" (the live domain, correct current name). **Use "TriplyAI"
in all new code, comments, and copy.** Do not fix old occurrences opportunistically — that's
tracked as its own Phase 1 item so it happens in one deliberate pass, not scattered edits.
See `.claude/docs/branding.md`.

## Non-negotiable rules

1. **Follow the existing module pattern exactly** — every module is
   `presentation/http` (controllers) → `application/use-cases` (one class per action) →
   `domain/contracts` + `domain/exceptions` (ports, interfaces, custom exceptions) →
   `infrastructure/*` (Drizzle repos, external providers). See `.claude/docs/api-conventions.md`.
2. **TypeScript strict everywhere.** No `any`, no unchecked casts. Zod (`zod`) for input
   validation where the module already uses it; `class-validator` DTOs where that's the
   established pattern for that module — match the surrounding code, don't mix styles within
   one module.
3. **No secrets in code.** All keys via environment variables (`.env.example` is the source
   of truth for what must exist).
4. **Drizzle only.** Schema in `src/infra/db/schema/`, migrations via `drizzle-kit` into
   `drizzle/`. Never hand-write a migration file — generate it.
5. **Admin session security is a live issue, not a style preference.** The current
   `admin_session` token is base64-encoded JSON with **no signature** — anyone who knows a
   valid admin ID can forge a session. Compounding it, the admin client holds that token in
   `sessionStorage`, readable by any XSS. Both halves are fixed in Phase 1 Foundation, first,
   before any RBAC work builds on top of them. See `.claude/docs/rbac-and-security.md`.
6. **CORS is hardcoded in `src/core/config/cors.config.ts`, not driven by `CORS_ORIGIN`.**
   That env var exists in `.env.example` but is never read. Adding an origin is a code change
   and a redeploy — don't tell anyone "just set the env var." See
   `.claude/docs/infrastructure.md`.
7. **Guests already exist, and the free tier is already bypassable through them.**
   `guest-auth.method.ts` creates a real `users` row with a synthetic `<uuid>@guest.com` email;
   usage counts against that email, so re-guesting resets the counter. Anything touching the
   guest path, usage limits, or signup reads `.claude/docs/database-schema.md` §0.9 first — and
   note that **email is a de facto identity key across five tables** (§0.8), so changing a
   user's email is a transaction, not an `UPDATE users`.
8. **Never invent a new AI-model-routing design.** One already exists at
   `docs/ai-model-assignment-plan.md` in this repo — implement that, don't re-spec it.
9. **Mobile-first API design isn't a concern here** (backend), but **payloads must stay lean**
   — the public frontend renders on 375px screens; don't return more than a screen needs.

## Build discipline

- **Build strictly in phase order. Never jump ahead** to a later phase's features.
- **Test + commit after every feature.** Jest is already configured (`npm test`,
  `npm run test:e2e`) — use it, don't introduce a second test runner.
- **Update `PROGRESS.md`** whenever a feature ships — it's the source of truth for what's
  actually built, cross-checked against real code, not assumptions.
- Read `PROGRESS.md` at the start of a work session before picking the next feature.

**How we build:** one feature = one branch off `main`, via **`/ship-feature`**:
plan → you approve → branch `feature/pN-<name>` → implement → verify (`tsc` + `jest`) →
squash-merge into `main` → tick `PROGRESS.md` → delete branch. Phase gate via **`/qa-gate`**.
A Stop hook runs `tsc` + `jest` after every turn — a red build blocks finishing.

**Git rule:** work only on `feature/*` / `fix/*` branches off `main` (the single integration
branch — there is no `develop`/`staging`). **NEVER commit/merge/push to `production` — the
human owns deployment promotion.** Full flow → `.claude/docs/git-workflow.md`.

## Tech stack (confirmed from the actual codebase, not assumed)

NestJS (Fastify adapter) · Drizzle ORM + PostgreSQL · Redis via BullMQ (**mail + optional
file-upload queues only** — not caching, not rate limiting, not sessions) · JWT (`@nestjs/jwt`,
`passport-jwt`) for user auth · Stripe (subscriptions, partially wired) · OpenAI (`gpt-4o` for
custom itineraries, `gpt-4o-mini` for destination itineraries — both currently hardcoded) ·
Firebase Admin SDK (Google sign-in verification) · Nodemailer/SMTP (+ Resend on the frontend
side for some templates) · Jest + Supertest (configured, in use) · deployed via **PM2**
(`ecosystem.config.cjs`, app `trytriplyai-b`, port 30008) on a VPS — **no Docker, no CI/CD
pipeline exists today.**

## Phase 1 scope (finalized — do not renegotiate scope, only sequencing)

Foundation → Signup fix → Content Library & Publishing System (**full architecture now, not
Phase 3** — admins publish itinerary pages daily toward a configurable goal count) → Admin RBAC
(4 roles) → AI model routing (per the existing plan doc) → Payments (Stripe audit/fix +
SSLCommerz) → PDF watermarking. Full breakdown, sequencing, and dependency map →
`build-order-complete.md`. Live status → `PROGRESS.md`.

**What's already built and must NOT be rebuilt:** passport-nationality + home-currency intake
fields (fully shipped, translated in 6 languages), i18n (en/bn/ar/ja/zh/fr, fully wired via
`LanguageContext`), a free-tier monthly limit system (`FREE_TIER_MONTHLY_LIMIT`, per-user
override), `custom_trip_requests` (already a working status-pipeline table, not just a form).
See `.claude/docs/qa-checklist.md` for the full "already done" list before touching any of
these areas.

---

## Doc index — read on demand

| When you're working on… | Read |
|---|---|
| Any database/schema work | `.claude/docs/database-schema.md` |
| Any new module or endpoint | `.claude/docs/api-conventions.md` |
| Admin roles, permissions, or the session-token fix | `.claude/docs/rbac-and-security.md` |
| The itinerary library / publishing system | `.claude/docs/content-library.md` |
| Stripe or SSLCommerz work | `.claude/docs/payments.md` |
| AI model catalog / routing | `docs/ai-model-assignment-plan.md` (existing, authoritative) |
| Env vars, PM2, deployment | `.claude/docs/infrastructure.md` |
| Branches, per-feature git flow | `.claude/docs/git-workflow.md` |
| Testing approach | `.claude/docs/testing.md` |
| A phase QA gate | `.claude/docs/qa-checklist.md` |
| The old-branding cleanup | `.claude/docs/branding.md` |
| What's built / what's next | `PROGRESS.md` |
| The exact per-feature build steps | `build-order-complete.md` |
