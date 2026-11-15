# Payments — Phase 1

Direction confirmed: **Stripe (audit + fix) + SSLCommerz (add)**, both wired directly, no
gateway-abstraction layer yet. The multi-gateway adapter/microservice pattern is explicitly
Phase 5, not now — don't build it early even if it seems cleaner.

## Stripe — audit before trusting it

Existing: `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` in `.env.example`; `subscription_status`
table has `stripeCustomerId`; `payment_transactions` tracks `stripePaymentIntentId` /
`stripeSubscriptionId`. Only one payment use-case exists today
(`create-custom-payment.use-case.ts`) — subscription checkout logic likely lives in the
`subscription` module, confirm before assuming it's missing.

**Audit checklist before Phase 1 sign-off:**
- [ ] Webhook endpoint exists, verifies Stripe's signature (`stripe.webhooks.constructEvent`),
      and is reachable from Stripe's dashboard (test in Stripe's webhook test tool, not just
      locally)
- [ ] `subscription_status.isActive` actually flips on `invoice.payment_failed` /
      `customer.subscription.deleted` — not just on successful checkout
- [ ] A failed/expired card doesn't leave a user silently "Premium" past their paid period

## SSLCommerz — new integration

Session-based redirect flow, **not** a simple webhook like Stripe:
1. Server requests a Session ID from SSLCommerz's Session API
2. Redirect the customer to SSLCommerz's hosted payment page
3. SSLCommerz POSTs an **IPN (Instant Payment Notification)** to a configured listener URL on
   completion
4. **That IPN must be independently re-validated against SSLCommerz's Transaction Validation
   API before trusting it** — this is not optional, their flow is designed around a mandatory
   verify-back step, unlike Stripe where signature verification alone is sufficient

```ts
// Sketch — application/use-cases/handle-sslcommerz-ipn.use-case.ts
async execute(ipnPayload: SslcommerzIpnDto) {
  const validation = await this.sslcommerzProvider.validateTransaction(ipnPayload.val_id);
  if (validation.status !== 'VALID' || validation.amount !== expectedAmount) {
    throw new InvalidPaymentValidationException(); // do NOT mark anything paid
  }
  // only now update payment_transactions / subscription_status
}
```

Store `gateway = 'sslcommerz'`, `sslcommerzTransactionId`, `sslcommerzValId` on
`payment_transactions` (see `database-schema.md` — extend the existing table, don't create a
parallel one).

## New admin surface

`GET/PUT /admin/payments/gateways` (`super_admin` only) — enable/disable per gateway, no
currency-conversion logic needed yet since this is a two-gateway, admin-entered-price setup,
not the multi-country dynamic pricing deferred to Phase 5.
