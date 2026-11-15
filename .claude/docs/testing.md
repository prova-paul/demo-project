# Testing

Jest + Supertest are already configured and in use — don't introduce Vitest or another runner.

```bash
npm test              # unit tests
npm run test:cov       # with coverage
npm run test:e2e       # test/jest-e2e.json config
```

## Convention

Co-locate unit tests next to the use-case they test
(`generate-custom-itinerary.use-case.spec.ts` beside `generate-custom-itinerary.use-case.ts`).
E2E tests for new admin routes go in `test/`, following whatever pattern existing e2e specs use
there — check `test/` before assuming a structure.

## What must be tested for every Phase 1 feature

- **RBAC**: a `content_admin` test token gets 403 on every route scoped to another role;
  `super_admin` gets 200 on all of them.
- **Admin session fix**: a manually-crafted (non-JWT-signed) token is rejected; a legitimately
  issued, expired token is rejected; a valid token succeeds.
- **Admin deactivation**: a valid, unexpired token for an admin whose `is_active` flipped to
  false is rejected on the very next request — not at token expiry.
- **SSLCommerz IPN**: a tampered amount/val_id fails validation and does **not** mark anything
  paid — write this test before wiring the real integration, not after. Also: the **same
  `val_id` posted twice** produces one transaction, not two.
- **Guest free-tier**: exhausting the limit as a guest, then starting a fresh guest session,
  must still be limited. This currently passes trivially in the wrong direction — the counter
  resets (`database-schema.md` §0.9) — so write the failing test first.
- **Guest → registered conversion** (task 2.4), three cases: a clean signup keeps one `users`
  row and carries the counter over; a signup with an email that **already has** a
  `user_itinerary_usage` / `subscription_status` row merges instead of raising a unique
  violation; a failure part-way through rolls back all five tables together.
- **Content Library publish**: a draft is never returned by the public `GET /library/:slug`
  route; a published item is; an `unpublished` item is not.
- **Slug redirects**: a retired slug resolves 301 to the current one, and a new page cannot
  claim a retired slug.
- **Content validation**: content missing root-object keys is rejected; content carrying a
  forbidden child-pricing key on an attraction is rejected; `dailyPlans.length` ≠
  `duration_days` is rejected.
- **Resolution logic** (AI model, per the existing plan doc): NULL override → env default;
  disabled catalog entry → reject; unknown model id → reject.

Run `tsc` + `jest` before every merge — this is enforced by the Stop hook
(`hooks/verify.sh`), not just a suggestion.
