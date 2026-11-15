# Phase 1 QA Gate

Run via `/qa-gate` before handing `main` to the human for deployment promotion.

## 🔴 Launch blockers

- [ ] Admin session token is signed (JWT), old base64-decode verification path fully removed
- [ ] Session is delivered as an httpOnly cookie; `sessionStorage` no longer holds it, and the
      `Authorization: Bearer` acceptance path is gone from `AdminAuthGuard`
- [ ] Admin login works **from `console.trytriplyai.com` in a real browser** — not just curl.
      Confirm the cookie is set, sent on the next request, and that CORS returns the explicit
      origin with `credentials: true` (a `*` origin silently breaks credentialed requests)
- [ ] Every `/admin/*` route enforces role via the guard, not just authentication
- [ ] Deactivating an admin (`is_active = false`) **kills their live session immediately** —
      not at the next token expiry. Bump `token_version`, then confirm their next request 401s
- [ ] SSLCommerz IPN handler calls the Transaction Validation API before updating any record
- [ ] A **replayed** SSLCommerz IPN (same `val_id` twice) does not create a second transaction
- [ ] `/itinerary/generate` works for a fully unauthenticated request (guest fix) AND has a
      rate limiter (it has none today, and it's about to become public)
- [ ] **Guest free-tier bypass is closed:** exhaust the limit as a guest, log out, guest again —
      the limit must still apply. This is broken today (`database-schema.md` §0.9)
- [ ] **Guest → signup keeps one account:** generate as a guest, sign up with a real email,
      confirm one `users` row (not two), the itineraries still resolve, and the usage counter
      carried over. Repeat with an email that already has a usage row (the unique-violation
      merge path)
- [ ] Draft/scheduled/unpublished Content Library items are not publicly reachable or indexed
- [ ] PDF export is watermarked on Free tier, not watermarked on Premium — server-side check,
      never trust a client flag

## Already built — verify, don't rebuild

- [ ] Passport nationality + home currency fields — confirm still working after any generation
      pipeline changes (they're deeply wired into `user_itineraries` and the OpenAI prompt port)
- [ ] i18n (6 languages) — a public-site concern, but confirm no Phase 1 backend response
      hardcodes user-facing English copy that the frontend then can't translate (error messages
      surfaced directly to end users are the usual offender). Admin-console responses are
      exempt — that console is English-only by design.
- [ ] Free-tier monthly limit (`FREE_TIER_MONTHLY_LIMIT`, per-user override) — confirm guest
      generation doesn't silently bypass or double-count against this for a user who signs up
      mid-session
- [ ] `custom_trip_requests` status pipeline — confirm nothing in Phase 1 breaks its existing
      admin usage while building the RBAC layer on top

## General

- [ ] `tsc` clean, `jest` green, `jest --config test/jest-e2e.json` green
- [ ] No secret committed (check `.env` is gitignored, no hardcoded keys)
- [ ] `PROGRESS.md` reflects reality — spot-check 3 random ticked items against actual code
