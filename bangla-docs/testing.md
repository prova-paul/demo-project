# Testing

Jest + Supertest ইতিমধ্যে configure করা এবং ব্যবহৃত হচ্ছে — Vitest বা অন্য কোনো runner আনবেন না।

```bash
npm test              # unit tests
npm run test:cov       # with coverage
npm run test:e2e       # test/jest-e2e.json config
```

## Convention

Unit test যে use-case test করে তার ঠিক পাশেই রাখুন
(`generate-custom-itinerary.use-case.ts`-এর পাশে `generate-custom-itinerary.use-case.spec.ts`)।
নতুন admin route-এর E2E test `test/`-এ যাবে, সেখানে বিদ্যমান e2e spec যে pattern ব্যবহার করে সেটি অনুসরণ করে
— কোনো গঠন ধরে নেওয়ার আগে `test/` যাচাই করুন।

## প্রতিটি Phase 1 feature-এর জন্য যা অবশ্যই test করতে হবে

- **RBAC**: একটি `content_admin` test token অন্য role-এর জন্য নির্ধারিত প্রতিটি route-এ 403 পায়;
  `super_admin` সবগুলোতে 200 পায়।
- **Admin session fix**: হাতে তৈরি করা (JWT-signed নয় এমন) token প্রত্যাখ্যাত হয়; বৈধভাবে
  issue করা কিন্তু মেয়াদোত্তীর্ণ token প্রত্যাখ্যাত হয়; একটি বৈধ token সফল হয়।
- **Admin deactivation**: যে admin-এর `is_active` false-এ পরিবর্তিত হয়েছে তার একটি বৈধ, মেয়াদ-না-পেরোনো token
  ঠিক পরের request-এই প্রত্যাখ্যাত হয় — token-এর মেয়াদ শেষ হওয়ার সময়ে নয়।
- **SSLCommerz IPN**: পরিবর্তিত (tampered) amount/val_id validation-এ fail করে এবং কোনো কিছুকেই paid হিসেবে
  চিহ্নিত **করে না** — আসল integration wire করার আগে এই test লিখুন, পরে নয়। এছাড়াও: **একই
  `val_id` দুবার post করলে** একটি transaction তৈরি হয়, দুটি নয়।
- **Guest free-tier**: guest হিসেবে limit শেষ করার পর, নতুন একটি guest session শুরু করলেও,
  অবশ্যই limit বহাল থাকতে হবে। এটি বর্তমানে ভুল দিকে অনায়াসে pass করে — counter
  reset হয়ে যায় (`database-schema.md` §0.9) — তাই আগে failing test লিখুন।
- **Guest → registered conversion** (task 2.4), তিনটি case: একটি পরিষ্কার signup একটি `users`
  row রাখে এবং counter সাথে নিয়ে যায়; এমন email দিয়ে signup যার **ইতিমধ্যে একটি**
  `user_itinerary_usage` / `subscription_status` row আছে, সেটি unique violation তোলার বদলে merge করে;
  মাঝপথে কোনো failure হলে পাঁচটি table-ই একসাথে roll back হয়।
- **Content Library publish**: একটি draft কখনোই public `GET /library/:slug`
  route দ্বারা return হয় না; একটি published আইটেম হয়; একটি `unpublished` আইটেম হয় না।
- **Slug redirects**: একটি retired slug বর্তমান slug-এ 301 দিয়ে resolve হয়, এবং কোনো নতুন page
  একটি retired slug দাবি করতে পারে না।
- **Content validation**: root-object key অনুপস্থিত এমন content প্রত্যাখ্যাত হয়; কোনো attraction-এ নিষিদ্ধ
  child-pricing key বহনকারী content প্রত্যাখ্যাত হয়; `dailyPlans.length` ≠
  `duration_days` হলে প্রত্যাখ্যাত হয়।
- **Resolution logic** (AI model, বিদ্যমান plan doc অনুযায়ী): NULL override → env default;
  disabled catalog entry → reject; অজানা model id → reject।

প্রতিটি merge-এর আগে `tsc` + `jest` চালান — এটি Stop hook
(`hooks/verify.sh`) দ্বারা প্রয়োগ করা হয়, শুধু একটি পরামর্শ নয়।
