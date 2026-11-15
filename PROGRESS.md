# TriplyAI Backend — Build Progress

> Single source of truth for what's actually built, updated after every feature ships.
> `[x]` items below were verified directly against the real codebase during scaffold setup —
> not assumed. `[ ]` = not started · `[~]` = in progress · `[x]` = done & verified.

Last updated: scaffold creation — verified against `Journey-Planner-Backend-production`.

---

## Already built (verified in code — do not rebuild)

- [x] NestJS + Fastify + Drizzle + PostgreSQL, clean-architecture module pattern
- [x] JWT auth for regular users (`@nestjs/jwt`, `passport-jwt`)
- [x] Passport-nationality + home-currency fields — fully in `user_itineraries` schema and the
      OpenAI generation port
- [x] Free-tier monthly limit system — `FREE_TIER_MONTHLY_LIMIT` env default,
      `users.freeItineraryMonthlyLimit` per-user override, `user_itinerary_usage` tracking
- [x] `custom_trip_requests` — real status pipeline (pending/contacted/quoted/converted/rejected),
      priority, notes, estimated value, follow-up date
- [x] Stripe partially wired — `payment_transactions`, `subscription_status.stripeCustomerId`
- [x] Admin panel exists with 6 sections (Overview, Users, Itineraries, Leads, Payments,
      Itinerary Limits) — flat, no roles
- [x] `docs/ai-model-assignment-plan.md` — full existing blueprint for AI model routing, not yet
      implemented
- [x] Redis/BullMQ — mail queue + optional file-upload queue only

## 🚨 Known live issues — fix in Foundation, first

- [ ] Admin session token is base64-encoded JSON with **no signature** — forgeable. See
      `.claude/docs/rbac-and-security.md`. Not yet fixed.
- [ ] The admin client holds that token in `sessionStorage`, readable by any XSS. Fix together
      with the signing fix — a signed token in a readable place is still a readable token.
- [ ] `CORS_ORIGIN` in `.env.example` is **never read** — the allowlist is hardcoded in
      `src/core/config/cors.config.ts`. Adding the admin console origin is a code change.
      Two dead `iplookup.xyz` origins are still allowlisted there.
- [ ] **The free tier is bypassable today.** `guest-auth.method.ts` creates a real `users` row
      with a synthetic `<uuid>@guest.com` email; usage counts against that email in
      `user_itinerary_usage` (keyed `UNIQUE (email)`). Re-guesting mints a new uuid and **resets
      the counter**. See `database-schema.md` §0.9 — this is the QA gate's "silently bypass"
      case, and it is live, not hypothetical.
- [ ] Guest rows accumulate forever — every guest login writes a permanent `users` row, no
      cleanup job, no index on `is_guest`. They inflate every user-count metric.
- [ ] Signing up after guest use creates a **second, unrelated account** — guest itineraries
      orphan and usage restarts. Fixed by task 2.4 (convert in place).
- [ ] `admin_users` has **no `is_active` and no `token_version`** — no way to switch an admin
      off, and a 24-hour admin JWT that cannot be revoked.
- [ ] `users` has **no suspend column** — console 6.1 (suspend/reinstate) has no backend at all.

## Repo context (changed — admin console split out)

This backend now serves **two** frontend clients, not one:
`trytriplyai.com` (public site, repo `Journey-Planner-Frontend`, calls this API server-side via
its own BFF routes) and `console.trytriplyai.com` (admin console, repo `triply-console`, calls
this API **directly from the browser**). Backend module structure is unaffected by the split —
admin endpoints already lived here. What changes is CORS, cookie attributes, and the fact that
admin API changes now have a consumer in a different repo.

---

## Phase 1 — Foundation, Signup Fix, Content Library, RBAC, Payments (0/N)

### Foundation
- [ ] Allow `console.trytriplyai.com` in `cors.config.ts` (+ prune dead origins) — blocks all
      console-side verification of everything below
- [ ] Admin session JWT signing fix (replace base64 encode/decode) + issue as httpOnly cookie,
      then drop the `Authorization: Bearer` path from `AdminAuthGuard`
- [ ] `admin_users` RBAC migration: `role` + `is_active` + `token_version` +
      `role_assigned_by`/`role_assigned_at`; backfill existing admins to `super_admin`
      **before** the CHECK constraint
- [ ] `AdminAuthGuard` checks `is_active` and `token_version` on every request, not just login
- [ ] Role-enforcement guard/decorator, applied to new routes first, then retrofitted to
      existing admin routes
- [ ] `audit_logs` table + write-before-commit middleware on all mutating admin routes
- [ ] Permission-key resolution (role → key set, server-side map) + `GET /admin/me` returning
      `{ id, email, role, permissions }` — **the console's role-gated nav consumes this**; see
      `.claude/docs/rbac-and-security.md`

### Signup / guest-access fix
- [ ] `/itinerary/generate` accepts unauthenticated requests (guest path)
- [ ] Rate limiter on `/itinerary/generate` (none exists today — and it, not the per-email
      counter, is the real free-tier boundary for guests)
- [ ] Email-gated export/save flow
- [ ] `user_itineraries.share_token` + partial unique index + public resolver (unguessable
      token, no auth — blocks the frontend's share-link feature)
- [ ] Guest → registered **conversion in place**, as one transaction across the five
      email-keyed tables, incl. the returning-user unique-violation merge (task 2.4)
- [ ] Abandoned-guest cleanup job + `users.converted_at` + `is_guest` index
- [ ] `users.suspended_at` / `suspended_reason` / `suspended_by` + suspend/reinstate endpoints
      (task 2.5 — **blocks console 6.1**)

### Content Library & Publishing System (full architecture, Phase 1)
- [ ] `library_itineraries`, `affiliate_partners`, `library_itinerary_affiliate_links`,
      `library_page_views`, `library_itinerary_slugs` tables + migrations (in that order)
- [ ] Content-library module (presentation/application/domain/infrastructure layers)
- [ ] `content` validated against the **shared** itinerary-root-object schema (not just the day
      array), including the forbidden child-pricing keys
- [ ] Draft → Scheduled → Published → Unpublished workflow
- [ ] Something actually flips `scheduled` → `published` (job or lazy check) — decided + recorded
- [ ] `updated_by` + `updated_at` written on every edit (no DB trigger exists)
- [ ] Public `GET /library/:slug` + click-tracked affiliate redirect route
- [ ] Retired-slug 301 fallback; slug frozen after first publish
- [ ] `library_page_views.is_bot` stamped at write time
- [ ] Publishing Activity view (`super_admin` only) — author, timestamps, traffic, affiliate
      clicks
- [ ] Goal counter via `app_settings['library_goal_count']`
- [ ] Affiliate partner catalog CRUD endpoints, incl. `expiry_date` (console alert states
      depend on it)
- [ ] Per-stop lat/lng on BOTH content paths — generation output AND library content (map
      layer + console editor both consume this; one path without the other = not done)

### AI Model Routing
- [ ] Implement `docs/ai-model-assignment-plan.md` as written (catalog, per-user override,
      resolution service, admin endpoints)
- [ ] **Scope decision:** the console's 5.x asks for a cost-per-request estimate, plan-tier
      defaults, and a versioned trip-mode prompt-template editor. **None of the three exist in
      the plan doc or in any table.** Confirm in/out of scope before the console starts 5.x —
      see `build-order-complete.md` §4.

### Payments
- [ ] Stripe audit (webhook signature verified, subscription status actually flips on failure)
- [ ] SSLCommerz integration — session request, redirect, IPN handler with mandatory
      Transaction Validation API call before marking anything paid
- [ ] `payment_transactions` extended with `gateway` + SSLCommerz columns
- [ ] Admin payment-gateway config endpoint (`super_admin` only)

### PDF Watermarking
- [ ] Server-side watermark on Free-tier PDF export, keyed to actual plan tier, never a client
      flag

### Branding cleanup (single deliberate pass, not scattered)
- [ ] Canonical/OG/meta tags, `.env.example` company fields, metadata examples — all to
      "TriplyAI"

- [ ] **Phase 1 QA gate passed** (`.claude/docs/qa-checklist.md`) ✅

---

## Noticed (out of current scope — logged, not acted on)

_Use this section during `/ship-feature` runs to log anything spotted but not fixed, per
`CLAUDE.md`'s "don't fix while you're in there" rule._
