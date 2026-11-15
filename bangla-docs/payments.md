# Payments — Phase 1

দিকনির্দেশনা নিশ্চিত: **Stripe (audit + fix) + SSLCommerz (যোগ করা)**, দুটিই সরাসরি wire করা, এখনো কোনো
gateway-abstraction layer নয়। Multi-gateway adapter/microservice pattern সুস্পষ্টভাবে
Phase 5-এর, এখন নয় — আগেভাগে তৈরি করবেন না, এমনকি যদি সেটি আরও পরিষ্কার মনে হয়।

## Stripe — বিশ্বাস করার আগে audit করুন

বিদ্যমান: `.env.example`-এ `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`; `subscription_status`
table-এ `stripeCustomerId` আছে; `payment_transactions` `stripePaymentIntentId` /
`stripeSubscriptionId` track করে। আজ শুধুমাত্র একটি payment use-case আছে
(`create-custom-payment.use-case.ts`) — subscription checkout logic সম্ভবত
`subscription` module-এ আছে, এটি অনুপস্থিত বলে ধরে নেওয়ার আগে নিশ্চিত হোন।

**Phase 1 sign-off-এর আগে audit checklist:**
- [ ] Webhook endpoint আছে, Stripe-এর signature যাচাই করে (`stripe.webhooks.constructEvent`),
      এবং Stripe-এর dashboard থেকে পৌঁছানো যায় (Stripe-এর webhook test tool-এ test করুন, শুধু
      locally নয়)
- [ ] `subscription_status.isActive` আসলেই `invoice.payment_failed` /
      `customer.subscription.deleted`-এ পরিবর্তিত হয় — শুধু সফল checkout-এ নয়
- [ ] একটি failed/মেয়াদোত্তীর্ণ card কোনো user-কে তার পরিশোধিত মেয়াদের পরে নীরবে "Premium" অবস্থায় রেখে দেয় না

## SSLCommerz — নতুন integration

Session-ভিত্তিক redirect flow, Stripe-এর মতো সাধারণ webhook **নয়**:
1. Server SSLCommerz-এর Session API থেকে একটি Session ID request করে
2. Customer-কে SSLCommerz-এর hosted payment page-এ redirect করুন
3. সম্পন্ন হলে SSLCommerz একটি configure করা listener URL-এ একটি **IPN (Instant Payment Notification)**
   POST করে
4. **সেই IPN বিশ্বাস করার আগে অবশ্যই SSLCommerz-এর Transaction Validation
   API-এর বিপরীতে স্বাধীনভাবে পুনরায় validate করতে হবে** — এটি ঐচ্ছিক নয়, তাদের flow একটি বাধ্যতামূলক
   verify-back ধাপকে ঘিরে ডিজাইন করা, Stripe-এর মতো নয় যেখানে শুধু signature verification-ই যথেষ্ট

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

`payment_transactions`-এ `gateway = 'sslcommerz'`, `sslcommerzTransactionId`, `sslcommerzValId`
store করুন (`database-schema.md` দেখুন — বিদ্যমান table বাড়ান, সমান্তরাল
আরেকটি তৈরি করবেন না)।

## নতুন admin surface

`GET/PUT /admin/payments/gateways` (শুধুমাত্র `super_admin`) — প্রতিটি gateway enable/disable, এখনো কোনো
currency-conversion logic-এর প্রয়োজন নেই কারণ এটি একটি দুই-gateway, admin-এর দেওয়া মূল্যের setup,
Phase 5-এ পিছিয়ে দেওয়া multi-country dynamic pricing নয়।
