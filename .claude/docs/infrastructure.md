# Infrastructure

## Deployment (confirmed real, not assumed)

PM2 (`ecosystem.config.cjs`), app name `trytriplyai-b`, fork mode, single instance, port 30008,
`max_memory_restart: 2G`. Build with `npm run build` (`nest build`), start with
`node dist/src/main.js` via `npm run start:prod`. **No Docker, no CI/CD pipeline exists today.**
Deploys are presumably manual (`git pull` + `pm2 restart` on the VPS) — confirm the actual
promotion process before assuming anything more automated.

## This backend now serves TWO frontend clients (changed — repo split)

| Client | Domain | Repo | How it calls this backend |
|---|---|---|---|
| Public site | `trytriplyai.com` | `Journey-Planner-Frontend` | Server-side, through its own Next.js BFF routes (`app/api/*`) |
| Admin console | `console.trytriplyai.com` | `triply-console` | **Directly from the browser** — no BFF layer |

This backend itself is `developer.trytriplyai.com`. There is no gateway or shared proxy in
front of it. The two clients reach it differently, which matters for CORS: the public site's
calls originate from a Next.js *server* (CORS does not apply), while the admin console's calls
originate from a *browser* on a different subdomain (CORS very much applies). See below.

Frontend runs on port 30002 (`next start -p 30002`), separate PM2 process, separate repo. The
admin console will need its own PM2 process on its own port — pick the next free one and add
the reverse-proxy vhost for `console.trytriplyai.com` alongside the existing two.

## 🚨 CORS is hardcoded, NOT env-driven — corrected, this was documented wrong

`.env.example` lists `CORS_ORIGIN`, and an earlier version of this doc described it as the live
control. **It is never read anywhere in `src/`** — grep confirms zero references. The real
allowlist is a literal array in `src/core/config/cors.config.ts`:

```ts
origin: [
  "http://127.0.0.1:3000", "http://localhost:3000",
  "http://127.0.0.1:30002", "http://localhost:30002",
  "https://journey.iplookup.xyz", "https://journey-api.iplookup.xyz",  // legacy, dead domains
  "https://trytriplyai.com", "https://developer.trytriplyai.com",
]
```

**Consequence: allowing `console.trytriplyai.com` is a code change plus redeploy, not an env
toggle.** This is tracked as Foundation task 1.0 in `build-order-complete.md` — it must land
before anyone can log into the admin console at all, so it blocks the entire RBAC chain.

While editing that file: prune the two dead `iplookup.xyz` origins (confirmed no longer in
use), and add the console's local dev origin too, or local admin development breaks. Keep
`credentials: true` — the admin session cookie depends on it.

## Admin session cookie across subdomains

The admin console is a browser client on `console.trytriplyai.com` calling
`developer.trytriplyai.com`. For the httpOnly session cookie introduced in Phase 1 Foundation
(see `rbac-and-security.md`) to survive that hop:

- **The cookie is set by the API's own response**, so a host-only cookie scoped to
  `developer.trytriplyai.com` is already sufficient — the browser sends it back to that same
  host on every subsequent call. Setting `Domain=.trytriplyai.com` is optional; only do it if
  something else on the parent domain genuinely needs to read the cookie, since a wider scope
  is a wider blast radius.
- **`SameSite=Lax` is sufficient — do not reach for `SameSite=None`.** `console.trytriplyai.com`
  and `developer.trytriplyai.com` share the registrable domain `trytriplyai.com`, so these are
  *same-site* requests despite being different origins. `SameSite=None` would unnecessarily
  expose the cookie to genuine third-party contexts.
- **CORS must send an explicit origin, never `*`.** A wildcard origin is incompatible with
  `credentials: true` — browsers reject the combination outright.
- **The console's fetch calls must set `credentials: 'include'`**, or the browser silently omits
  the cookie and every admin request 401s with no obvious cause. This is the single most common
  way this setup fails in practice.

## Environment variables (from `.env.example` — keep in sync as Phase 1 adds new ones)

Already present: `DATABASE_URL`, `JWT_SECRET` (+ access/refresh expiry), `PORT`, `CORS_ORIGIN`
(**present but dead — see above, it controls nothing**), Firebase Admin config
(`FIREBASE_SERVICE_ACCOUNT_PATH` or `FIREBASE_SERVICE_ACCOUNT_JSON`), `STRIPE_SECRET_KEY` /
`STRIPE_WEBHOOK_SECRET`, `FREE_TIER_MONTHLY_LIMIT`, `FRONTEND_URL`, SMTP config,
`GOOGLE_CLIENT_ID`/`SECRET`.

**Phase 1 additions:**
```bash
ADMIN_JWT_SECRET=                      # separate from JWT_SECRET — see rbac-and-security.md
ADMIN_CONSOLE_URL=https://console.trytriplyai.com   # for redirects/links back to the console
SSLCOMMERZ_STORE_ID=
SSLCOMMERZ_STORE_PASSWORD=
SSLCOMMERZ_IS_SANDBOX=true             # false in production
SSLCOMMERZ_IPN_LISTENER_URL=
```

Note `FRONTEND_URL` is now ambiguous — it predates the split and means the public site. Don't
reuse it for console links; that's what `ADMIN_CONSOLE_URL` is for.

## Redis — what it's actually for

BullMQ backend only, two queues: `backendv2-mail-queue` (async email), `backendv2-file-upload-queue`
(optional background uploads). **Do not assume Redis handles caching, sessions, or rate
limiting anywhere — it doesn't.** If Phase 1 needs a rate limiter on the now-public
`/itinerary/generate` endpoint (guests can hit it with no auth once the signup fix ships),
that's new infrastructure to add, not something to wire into the existing Redis usage
implicitly — decide explicitly whether it uses Redis (new use) or a Postgres-based approach
matching the existing `admin_login_attempts` pattern.

## No CI/CD — what that means for `/ship-feature`

Since there's no pipeline, `tsc` + `jest` running locally (via the Stop hook, see
`hooks/verify.sh`) is the only automated gate before merge to `main`. Treat it as
non-optional — a red local build is the only safety net that exists right now.

## Repo cruft (noticed during the split audit, not acted on)

`triply-template/` and `truffleE/` at the repo root are both genuinely empty directories — no
files, no hidden contents, not referenced by any build config. Safe to delete whenever someone
is already touching repo-root housekeeping; not worth a dedicated commit.
