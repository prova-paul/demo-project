# Backend — Phase 1 Build Order

Sequenced so nothing is picked up before its dependency is done. `/ship-feature` reads this to
pick the next item. Each entry = one feature = one branch.

> **Before starting Foundation, read `database-schema.md` Part H** — six decisions that are cheap
> now and expensive once data exists (library page language, who publishes scheduled pages,
> guest/share-link expiry, guest retention window, support-queue assignment, Redis vs Postgres
> rate limiting). Part F of that doc gives the exact migration order for everything below.

## 1. Foundation (build in this exact order — each depends on the previous)

**1.0 — Allow the admin console origin in CORS**
Add `https://console.trytriplyai.com` (and its local dev origin) to the hardcoded array in
`src/core/config/cors.config.ts`; keep `credentials: true`; prune the two dead
`journey.iplookup.xyz` / `journey-api.iplookup.xyz` origins in the same edit. **This is a code
change, not an env var** — `CORS_ORIGIN` in `.env.example` is never read (see
`infrastructure.md`).
_Depends on: nothing. Blocks: everything below — until this ships, the admin console can't
reach this API at all, so none of the Foundation work is verifiable from the real client._

**1.1 — Admin session JWT signing fix + httpOnly cookie**
Replace the base64 encode/decode session with `@nestjs/jwt` sign/verify. Add `ADMIN_JWT_SECRET`
env var. Issue the session as an httpOnly/Secure/SameSite=Lax cookie rather than a token the
client stores in `sessionStorage`. Verify existing admin accounts can still log in **from the
console's own origin** — curl won't exercise the cookie/CORS interaction that actually breaks
here. Once confirmed, drop the `Authorization: Bearer` path from `AdminAuthGuard`.
_Depends on: 1.0. Blocks: everything role-related below._

**1.2 — `admin_users` RBAC columns (role + deactivation + revocation)**
One migration adding `role`, `is_active`, `token_version`, `role_assigned_by`,
`role_assigned_at` — see `database-schema.md` D1. Default `role = 'content_admin'`; **backfill
every existing row to `super_admin` inside the same migration, before the CHECK constraint**, or
the whole team is locked out on deploy day.
`is_active` and `token_version` are not optional extras: `library_itineraries.created_by` is
`ON DELETE RESTRICT`, so an admin who has published anything can never be deleted — deactivation
is the only offboarding path — and a 24-hour admin JWT with no revocation means a fired admin
keeps working for a day. `AdminAuthGuard` must check `is_active` on every request.
_Depends on: 1.1 (so the role in a forged token can't be trusted while this ships)._

**1.3 — Role-enforcement guard + `audit_logs` table**
`RequireRole()` decorator/guard, audit-log-before-commit middleware.
_Depends on: 1.2._

**1.4 — Permission-key resolution + `GET /admin/me`**
A server-side map from each of the four roles to a set of permission keys (`content.publish`,
`content.edit`, `users.suspend`, `models.edit`, `payments.configure`, `audit.view`, and more as
modules land — see `rbac-and-security.md` for the full Phase 1 key table). `GET /admin/me`
returns the current admin's `{ id, email, role, permissions: string[] }`, resolved from the
database on every call — never from the token payload. **The console's entire role-gated nav
(its Foundation task 1.2) consumes this endpoint** — it is a hard cross-repo dependency, not a
nice-to-have.
_Depends on: 1.3. Blocks: console Foundation 1.2 and every role-gated console screen._

## 2. Signup / guest-access fix

**2.1 — Guest-accessible generation endpoint**
`/itinerary/generate` works with no auth header.

⚠️ **A guest path already exists and the free tier is already bypassable through it.**
`guest-auth.method.ts` creates a real `users` row with a synthetic `<uuid>@guest.com` email, and
usage is counted against that email in `user_itinerary_usage` (which is keyed `UNIQUE (email)`).
Re-guesting produces a new uuid and **resets the counter**. So this task is not "add a guest
path" — it's "make the existing one countable." That means the rate limiter (2.2) is the real
enforcement boundary for guests, not the per-email counter. Full detail:
`database-schema.md` §0.9.
Also decide the abandoned-guest retention window here (Part H, decision 4) — every guest login
writes a permanent `users` row today, with no cleanup job.

**2.2 — Rate limiter on the generation endpoint**
New requirement — none exists today. Decide Redis-based or Postgres-based (matching the
`admin_login_attempts` pattern) explicitly; don't assume Redis silently because BullMQ is
already there for something else.
_Depends on: 2.1._

**2.3 — Guest itinerary persistence + shareable read-only link**
Persistence already works (guests are real `users` rows). What's missing is the share link:
`user_itineraries` has **no share-token column** — add `share_token`, `share_token_created_at`,
`share_revoked_at` plus a partial unique index (`database-schema.md` D2a). Generate with
`crypto.randomBytes(24).toString('base64url')` — never the row id, never sequential. The public
resolver requires `share_token = $1 AND share_revoked_at IS NULL`, with no auth.
Decide whether share links expire (Part H, decision 3) and write the answer into `PROGRESS.md`
either way.
_Depends on: 2.1. **Blocks: frontend 4.3** (shareable read-only itinerary link) — that feature
had no backend owner until this task; don't let the frontend half start first._

**2.4 — Guest → registered conversion (net-new, previously unowned)**
Today, signing up after guest use creates a **second, unrelated account**: the guest's
itineraries orphan and the usage counter starts fresh. Fix by converting the existing guest row
in place (`is_guest = false`, real email/name/password, stamp `converted_at`) rather than
inserting a new one.
Because email is a de facto identity key across five tables (`database-schema.md` §0.8), this is
a **single transaction** that also rewrites `user_itineraries.email`,
`itinerary_generation_requests.email`, `user_itinerary_usage.email` and
`subscription_status.email` — but **never** `payment_transactions.user_email` (immutable ledger).
`user_itinerary_usage.email` and `subscription_status.email` are `UNIQUE`, so a returning user
raises a unique violation: merge the counters (higher count, later `reset_date`) and drop the
guest row inside the same transaction. Exact SQL in `database-schema.md` D2b.
_Depends on: 2.1. **Test the returning-user collision case** — it's the one that appears in
production first._

**2.5 — User suspend / reinstate (net-new, blocks console 6.1)**
`users` has soft-delete columns but **no suspend column at all** — confirmed. Add
`suspended_at`, `suspended_reason`, `suspended_by` (`database-schema.md` D2c). Suspension is
distinct from soft deletion: the user still exists, cannot authenticate, and can be reinstated.
Auth checks `suspended_at IS NULL` alongside `deleted_at IS NULL`; bump `users.token_version` on
suspend to kill live sessions. Every suspend writes `audit_logs` with `action = 'user.suspend'`.
_Depends on: 1.3 (role gating + audit). **Blocks: console 6.1**, whose own build order already
suspected this endpoint might not exist._

## 3. Content Library & Publishing System

**3.1 — Schema**: `library_itineraries`, `affiliate_partners`,
`library_itinerary_affiliate_links`, `library_page_views`, `library_itinerary_slugs`.
Create in that order — the links table references `affiliate_partners`. Table renamed from
`page_views` to `library_page_views` so nobody funnels destination traffic into it. Full DDL,
indexes and the reasons behind each column → `database-schema.md` Part C.
_Depends on: 1.3 (uses `created_by` → `admin_users`, role-gated from the start)._

**3.2 — Content-library module, admin CRUD + publish workflow**
Includes two things easy to miss: **(a)** decide and build whatever flips `scheduled` →
`published` (nothing does automatically — a BullMQ repeatable job polling
`library_itineraries_due_idx` is the recommendation; see `content-library.md`), and **(b)** set
`updated_by` *and* `updated_at` on every write — there is no database trigger, so the Publishing
Activity view's "last edited" column silently reports creation time otherwise.
`content` validates against the **same shared schema** as `user_itineraries.itinerary_content`
(the root object, not just the day array) — see 🚨 in `content-library.md`.
_Depends on: 3.1._

**3.3 — Public routes**: `GET /library/:slug`, affiliate click-tracked redirect,
`POST /library/:slug/view`. The slug resolver falls back to `library_itinerary_slugs` and answers
**301** for a retired slug, so editing a slug never 404s an indexed URL. Stamp
`library_page_views.is_bot` at write time by user-agent — otherwise "page views" on a public SEO
page means "crawler hits."
_Depends on: 3.2._

**3.4 — Publishing Activity view** (`super_admin` only): author, timestamps, traffic, clicks.
_Depends on: 3.3 (needs `library_page_views` data flowing)._

**3.5 — Goal counter** via `app_settings`.
_Depends on: 3.2. Can build in parallel with 3.3/3.4._

**3.6 — Affiliate partner catalog CRUD endpoints (incl. `expiry_date`)**
Admin CRUD for `affiliate_partners` — list/create/update/deactivate, gated
`content_admin`/`super_admin`. The schema includes `expiry_date` (see `database-schema.md`) —
the console builds 30-day-warning and past-due alert states on it, so it must exist and be
returned by the list endpoint. Expiry never auto-disables a link — it's informational.
_Depends on: 3.1. **Blocks: console 4.1 and 4.3** (previously cited as phantom tasks "4a"/"4d")._

**3.7 — Per-stop coordinates on BOTH content paths**
Add per-stop `lat`/`lng` to the day-by-day content shape in **two places in the same feature**:
(a) the AI generation output (`itinerary_content.dailyPlans[]` **and** `dailyItinerary[]` — a
prompt/schema change in `generate-custom-itinerary-prompt.ts`), and (b) library content
validation, since `library_itineraries.content` must match that same shape. Add it as an
index-aligned parallel array (`activityCoordinates`, same length as `activityLines`, `null` for
flights/generic evenings) matching the existing `activityAttractionNumbers` convention, at
`numeric(10,8)`/`numeric(11,8)` precision to match `cities`. Bump `content_schema_version` to 2.
Exact shape → `database-schema.md` D2e. The frontend map layer and the console editor's coordinates field both
consume this; it was flagged by both consumer repos as "easy to build only halfway" — **doing
one path without the other fails this task's definition of done.**
_Depends on: 3.2 for the library half; the generation half can start anytime. **Blocks:
frontend 4.1 (map layer) and console 2.3 (coordinates field).**_

## 4. AI Model Routing

**4.1 — Implement `docs/ai-model-assignment-plan.md` exactly as written.**
Delivers the `ai_models` catalog + `users.ai_model_custom` / `ai_model_destination` overrides +
`AiModelResolutionService` + admin endpoints. Schema summary → `database-schema.md` C7/D4.
_Depends on: 1.3 (the plan's own "optional superadmin gate" is no longer optional — role
enforcement already exists by this point, so wire it in from the start rather than as a
follow-up)._

**⚠️ The console asks for three things this plan does NOT cover — scope them before its 5.x**

Console tasks 5.1–5.3 assume backend surfaces that neither this build order nor the plan doc
contains. Confirm scope with the founder rather than discovering it mid-build:

- **Cost-per-request estimate** (console 5.1) — `ai_models` has no cost column. Either add
  `cost_per_1k_input` / `cost_per_1k_output` numeric columns, or drop the estimate from the UI.
- **Plan-tier defaults** (console 5.2) — the plan doc resolves *env default → per-user override*.
  There is no per-tier layer. Adding one means a new resolution step and somewhere to store it
  (`app_settings` keys, or a `subscription_tier → model` table).
- **Trip-mode prompt template editor, versioned** (console 5.3) — **no table exists and none is
  planned.** Prompts live in `generate-custom-itinerary-prompt.ts` as code. A versioned,
  admin-editable prompt store is a real feature (`prompt_templates` with a version column,
  never overwritten in place), not a UI on top of something that exists.

_If any of these are in scope, they become numbered backend tasks here first — the console's
5.x is blocked on them either way._

## 5. Payments

**5.1 — Stripe audit** (webhook signature check, subscription-status-flip verification).
_Depends on: nothing — can start anytime, including in parallel with Foundation._

**5.2 — SSLCommerz integration**: session request, redirect, IPN handler + mandatory
Transaction Validation API call.
_Depends on: nothing structurally, but sequence after 5.1 so both gateways are reviewed
together, not the new one built while the old one's real state is still unknown._

**5.3 — Admin payment-gateway config endpoint.**
_Depends on: 1.3 (super_admin only), 5.1, 5.2._

## 6. PDF Watermarking

**6.1 — Server-side watermark on Free-tier export.**
_Depends on: nothing structurally — can run in parallel with most of the above. Sequence last
only because it's low-risk and shouldn't block anything else._

## 7. Branding cleanup

**7.1 — Single pass**: canonical/OG tags, `.env.example`, metadata examples → "TriplyAI".
_Depends on: nothing technically, but hold until founder confirms the name is final (see
`branding.md`) — do this last so it isn't redone._

---

## Parallelization notes

- Foundation (1.1→1.3) is the critical path — it blocks Content Library (3.x) and sharpens
  AI Model Routing's (4.1) scope. Prioritize it first.
- Signup fix (2.1→2.4) and Payments (5.x) have no dependency on Foundation and can run on a
  second workstream in parallel. **2.5 (user suspend) is the exception** — it needs 1.3 for role
  gating and audit, so it sits with Foundation's workstream even though it's numbered under 2.
- PDF Watermarking (6.1) and Branding (7.1) are safe to slot in anywhere — low risk, no
  blocking relationships.
