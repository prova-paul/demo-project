# RBAC & Admin Session Security

## 🚨 Fix first, before any role work: the session token is forgeable

Confirmed directly in code (`admin-login.use-case.ts` / `admin-verify-session.use-case.ts`):

```ts
// current — DO NOT keep this pattern
const sessionData = { adminId: adminUser.id, email: adminUser.email, exp: Date.now() + 86400000 };
const sessionToken = Buffer.from(JSON.stringify(sessionData)).toString('base64');
```

Verification only decodes the base64, checks `exp`, then `findById(sessionData.adminId)`.
**There is no signature.** Anyone who knows or enumerates a valid `admin_users.id` can build
their own `{adminId, email, exp}` JSON, base64-encode it, set it as the `admin_session` cookie,
and be authenticated as that admin — no password needed. This is a live, exploitable
vulnerability in production code today, not a theoretical concern.

### The fix
`@nestjs/jwt` and `jsonwebtoken` are already dependencies — use them:
```ts
// AdminLoginUseCase
const sessionToken = this.jwtService.sign(
  { adminId: adminUser.id, email: adminUser.email, role: adminUser.role },
  { expiresIn: '24h' },
);

// AdminVerifySessionUseCase
const payload = this.jwtService.verify(token); // throws on invalid signature or expiry
const adminUser = await this.adminUserRepo.findById(payload.adminId);
```
Use a dedicated `ADMIN_JWT_SECRET` env var, separate from any user-facing JWT secret, so
rotating one never affects the other. Ship this **before** or **together with** the `role`
column migration — don't build role-gating logic on top of a session that can be forged to
claim any role.

## 🚨 Second, related problem: the client stores the token in `sessionStorage`

`AdminAuthGuard` accepts the session from **either** an `Authorization: Bearer` header **or**
the `admin_session` cookie. The admin frontend uses the header path, holding the token in
`sessionStorage` (`admin_session_token`). That means any XSS on the admin console can read the
token outright — an httpOnly cookie cannot be read by JavaScript at all, which is the entire
point of the flag.

Fix both halves in the same Foundation pass, or the signed token just becomes a signed token
sitting in a readable place:
1. Issue the session as an **httpOnly, Secure cookie** set by the login response.
2. Drop the `Authorization: Bearer` acceptance path from `AdminAuthGuard` once the console is
   confirmed working on cookies — leaving both paths open means the weaker one is still
   exploitable.

### Cookie attributes for the console (`console.trytriplyai.com` → `developer.trytriplyai.com`)

The admin console is a **browser** client on a different subdomain calling this API directly
(no BFF proxy in between — see `infrastructure.md`). That makes the cookie attributes
load-bearing:

```ts
reply.setCookie('admin_session', sessionId, {
  httpOnly: true,
  secure: true,
  sameSite: 'lax',   // NOT 'none' — see below
  path: '/',
  maxAge: 60 * 60 * 24,
});
```

- **`sameSite: 'lax'` is correct and sufficient.** `console.trytriplyai.com` and
  `developer.trytriplyai.com` share the registrable domain `trytriplyai.com`, so requests
  between them are *same-site* even though they're different origins. Reaching for
  `sameSite: 'none'` would needlessly expose the cookie in true third-party contexts.
- **No `domain` attribute needed.** The cookie is set by this API and sent back to this API;
  a host-only cookie already does that. Only add `domain: '.trytriplyai.com'` if something on
  the parent domain must read it — nothing currently does.
- **CORS must allow the console origin explicitly with `credentials: true`** (a `*` origin is
  rejected by browsers when credentials are enabled). That's the `cors.config.ts` change
  tracked as Foundation task 1.0.
- **The console must call with `credentials: 'include'`.** If it doesn't, the browser silently
  drops the cookie and every request 401s with nothing useful in the logs. This is the most
  common failure mode of this exact setup — check it first when admin login "mysteriously"
  stops working.

## 🚨 Third problem: there is no way to switch an admin off

`admin_users` has **no `is_active` column and no `token_version`** (confirmed against
`admin-user.schema.ts`). That matters more than it sounds:

- `library_itineraries.created_by` is `ON DELETE RESTRICT`, so **an admin who has published
  anything can never be deleted.** Deactivation is the only offboarding path — and without the
  column, there isn't one.
- The admin JWT lives 24 hours with no revocation. A fired or compromised admin keeps working
  for up to a day even after you change their role.

Foundation task 1.2 adds all of it in one migration (`database-schema.md` D1): `role`,
`is_active`, `token_version`, `role_assigned_by`, `role_assigned_at`.

- `AdminAuthGuard` checks **`is_active` on every request**, not just at login.
- `token_version` mirrors the existing `users.token_version` pattern — bump it on deactivate or
  role change and every live session for that admin dies immediately. Put it in the token
  payload, compare against the database row.
- `role_assigned_by` / `role_assigned_at` answer "who made this person a super admin" without
  scanning the whole audit log.

## Roles (net-new — `admin_users` is currently flat, one role for everyone)

| Role | Owns |
|---|---|
| `super_admin` | Everything below, plus: assigns/revokes roles, audit log, payment gateway config, final override |
| `content_admin` | Content Library CRUD + publish, own items only (super_admin sees/edits all) |
| `support_admin` | User management, leads, custom-trip-request queue |
| `model_growth_admin` | AI model catalog/routing (per `ai-model-assignment-plan.md`), analytics |

## Permission keys + `GET /admin/me` (Foundation task 1.4 — the console depends on this)

Roles are the storage model; **permission keys are the API surface** the console gates on. A
server-side map (plain code, not a database table in Phase 1) resolves each role to a key set:

| Key | `super_admin` | `content_admin` | `support_admin` | `model_growth_admin` |
|---|---|---|---|---|
| `content.edit` / `content.publish` | ✅ (all items) | ✅ (own items) | — | — |
| `content.activity.view` | ✅ | — | — | — |
| `affiliates.manage` | ✅ | ✅ | — | — |
| `users.view` / `users.suspend` | ✅ | — | ✅ | — |
| `leads.view` | ✅ | — | ✅ | — |
| `models.edit` | ✅ | — | — | ✅ |
| `limits.edit` | ✅ | — | — | ✅ |
| `payments.configure` | ✅ | — | — | — |
| `roles.assign` / `audit.view` | ✅ | — | — | — |

`GET /admin/me` (behind `AdminAuthGuard`) returns
`{ id, email, role, permissions: string[] }`, with `role`, `is_active` and `token_version` read
from the **database row** on every call, never trusted from the token payload — a revoked role or
a deactivated account must die on the next request, not at the next token expiry. Keys are additive: new modules add keys to the map; the console treats an unknown
key as "not granted," so adding one is never a breaking change. Keep `RequireRole()` for
server-side route guards if that's simpler per-route — the key set exists primarily so the
**console** can gate UI without hardcoding role names.

## Enforcement pattern

Extend `AdminAuthGuard` (`src/modules/admin/infrastructure/guards/admin-auth.guard.ts`) — it
already attaches `request.admin` after verifying the token; add the role check there or in a
new `RequireRole(role)` decorator + guard pair, checked per-route, never trusted from the
client. Every mutating route additionally writes to `audit_logs` (see `database-schema.md`)
**before** committing — if the audit write fails, the whole request fails closed.

## Rollout order (safe, no lockout risk)

0. **Add `console.trytriplyai.com` to `cors.config.ts` and deploy it first.** Without this the
   admin console cannot reach this API at all, so nothing below is testable from the real
   client. See `infrastructure.md`.
1. Add `role` column, default `content_admin`, **backfill all existing admin rows to
   `super_admin` manually** before enforcing anything
2. Ship the JWT session fix + httpOnly cookie (above) — verify existing admins can still log in
   **from the console's own origin**, not just via curl or Postman, since the cookie/CORS
   interaction is exactly what curl won't catch
3. Add role-check middleware/decorator, apply to new routes only first
4. Ship `GET /admin/me` + the role→permission-key map (task 1.4) — the console's role-gated
   nav is blocked until this exists
5. Retrofit existing admin routes (users, itineraries, leads, payments, limits) with role
   requirements based on the table above
6. Manually verify: a `content_admin` test account gets 403 on `/admin/users`, a `super_admin`
   does not
7. Remove the `Authorization: Bearer` acceptance path from `AdminAuthGuard` once step 2 is
   confirmed working end-to-end
