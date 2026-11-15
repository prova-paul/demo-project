# TriplyAI Backend — Build অগ্রগতি

> আসলে কী build হয়েছে তার একমাত্র source of truth, প্রতিটি feature ship হওয়ার পরে update করা হয়।
> নিচের `[x]` item-গুলো scaffold setup-এর সময় সরাসরি আসল codebase-এর সাথে মিলিয়ে যাচাই করা হয়েছে —
> অনুমান করা নয়। `[ ]` = শুরু হয়নি · `[~]` = চলমান · `[x]` = সম্পন্ন ও যাচাইকৃত।

সর্বশেষ update: scaffold তৈরি — `Journey-Planner-Backend-production`-এর সাথে মিলিয়ে যাচাইকৃত।

---

## ইতিমধ্যেই build হয়েছে (code-এ যাচাইকৃত — আবার build করবেন না)

- [x] NestJS + Fastify + Drizzle + PostgreSQL, clean-architecture module pattern
- [x] সাধারণ user-দের জন্য JWT auth (`@nestjs/jwt`, `passport-jwt`)
- [x] Passport-nationality + home-currency fields — সম্পূর্ণভাবে `user_itineraries` schema-তে এবং
      OpenAI generation port-এ আছে
- [x] Free-tier monthly limit system — `FREE_TIER_MONTHLY_LIMIT` env default,
      `users.freeItineraryMonthlyLimit` per-user override, `user_itinerary_usage` tracking
- [x] `custom_trip_requests` — আসল status pipeline (pending/contacted/quoted/converted/rejected),
      priority, notes, estimated value, follow-up date
- [x] Stripe আংশিকভাবে wired — `payment_transactions`, `subscription_status.stripeCustomerId`
- [x] Admin panel আছে 6টি section সহ (Overview, Users, Itineraries, Leads, Payments,
      Itinerary Limits) — flat, কোনো role নেই
- [x] `docs/ai-model-assignment-plan.md` — AI model routing-এর জন্য পূর্ণ বিদ্যমান blueprint, এখনও
      implement করা হয়নি
- [x] Redis/BullMQ — শুধুমাত্র mail queue + ঐচ্ছিক file-upload queue

## 🚨 জানা live সমস্যা — Foundation-এ, সবার আগে ঠিক করুন

- [ ] Admin session token হলো base64-encoded JSON, যার **কোনো signature নেই** — জাল করা যায়। দেখুন
      `.claude/docs/rbac-and-security.md`। এখনও ঠিক করা হয়নি।
- [ ] Admin client সেই token রাখে `sessionStorage`-এ, যা যেকোনো XSS পড়তে পারে। signing fix-এর সাথে
      একসাথে ঠিক করুন — পাঠযোগ্য জায়গায় রাখা একটি signed token তবুও একটি পাঠযোগ্য token।
- [ ] `.env.example`-এর `CORS_ORIGIN` **কখনোই পড়া হয় না** — allowlist hardcoded আছে
      `src/core/config/cors.config.ts`-এ। Admin console origin যোগ করা একটি code change।
      দুটি অচল `iplookup.xyz` origin এখনও সেখানে allowlisted আছে।
- [ ] **Free tier আজ bypass করা যায়।** `guest-auth.method.ts` একটি synthetic `<uuid>@guest.com` email দিয়ে
      একটি আসল `users` row তৈরি করে; usage সেই email-এর বিপরীতে গণনা হয়
      `user_itinerary_usage`-এ (`UNIQUE (email)` দ্বারা keyed)। আবার guest হলে একটি নতুন uuid তৈরি হয় এবং **counter
      reset হয়ে যায়**। দেখুন `database-schema.md` §0.9 — এটিই QA gate-এর "silently bypass"
      case, এবং এটি live, কাল্পনিক নয়।
- [ ] Guest row চিরকাল জমতে থাকে — প্রতিটি guest login একটি স্থায়ী `users` row লেখে, কোনো
      cleanup job নেই, `is_guest`-এ কোনো index নেই। এগুলো প্রতিটি user-count metric ফুলিয়ে দেয়।
- [ ] Guest ব্যবহারের পরে sign up করলে একটি **দ্বিতীয়, সম্পর্কহীন account** তৈরি হয় — guest itinerary-গুলো
      orphan হয়ে যায় এবং usage নতুন করে শুরু হয়। task 2.4 (convert in place) দ্বারা ঠিক করা হবে।
- [ ] `admin_users`-এ **কোনো `is_active` নেই এবং কোনো `token_version` নেই** — একজন admin-কে বন্ধ করার কোনো
      উপায় নেই, এবং একটি 24-ঘণ্টার admin JWT যা revoke করা যায় না।
- [ ] `users`-এ **কোনো suspend column নেই** — console 6.1 (suspend/reinstate)-এর কোনো backend-ই নেই।

## Repo প্রেক্ষাপট (পরিবর্তিত — admin console আলাদা করা হয়েছে)

এই backend এখন একটি নয়, **দুটি** frontend client সার্ভ করে:
`trytriplyai.com` (পাবলিক সাইট, repo `Journey-Planner-Frontend`, নিজের BFF routes-এর মাধ্যমে server-side-এ
এই API কল করে) এবং `console.trytriplyai.com` (admin console, repo `triply-console`, এই API কল করে
**সরাসরি browser থেকে**)। এই বিভাজনে backend module structure প্রভাবিত হয় না — admin endpoints
আগে থেকেই এখানে ছিল। যা পরিবর্তিত হয় তা হলো CORS, cookie attributes, এবং এই বিষয়টি যে
admin API পরিবর্তনের এখন একটি ভিন্ন repo-তে একজন consumer আছে।

---

## Phase 1 — Foundation, Signup Fix, Content Library, RBAC, Payments (0/N)

### Foundation
- [ ] `cors.config.ts`-এ `console.trytriplyai.com` allow করুন (+ অচল origin ছেঁটে ফেলুন) — নিচের সবকিছুর
      console-side verification আটকে রাখে
- [ ] Admin session JWT signing fix (base64 encode/decode প্রতিস্থাপন) + httpOnly cookie হিসেবে issue করা,
      তারপর `AdminAuthGuard` থেকে `Authorization: Bearer` path বাদ দেওয়া
- [ ] `admin_users` RBAC migration: `role` + `is_active` + `token_version` +
      `role_assigned_by`/`role_assigned_at`; বিদ্যমান admin-দের `super_admin`-এ backfill করুন
      CHECK constraint-এর **আগে**
- [ ] `AdminAuthGuard` শুধু login-এ নয়, প্রতিটি request-এ `is_active` এবং `token_version` check করে
- [ ] Role-enforcement guard/decorator, প্রথমে নতুন routes-এ প্রয়োগ, তারপর বিদ্যমান
      admin routes-এ retrofit
- [ ] `audit_logs` table + সব mutating admin routes-এ write-before-commit middleware
- [ ] Permission-key resolution (role → key set, server-side map) + `GET /admin/me` যা
      `{ id, email, role, permissions }` return করে — **console-এর role-gated nav এটি consume করে**; দেখুন
      `.claude/docs/rbac-and-security.md`

### Signup / guest-access fix
- [ ] `/itinerary/generate` unauthenticated request গ্রহণ করে (guest path)
- [ ] `/itinerary/generate`-এ rate limiter (আজ কোনোটি নেই — এবং guest-দের জন্য per-email counter নয়,
      এটিই আসল free-tier সীমা)
- [ ] Email-gated export/save flow
- [ ] `user_itineraries.share_token` + partial unique index + public resolver (অনুমান-অযোগ্য
      token, কোনো auth নেই — frontend-এর share-link feature আটকে রাখে)
- [ ] Guest → registered **conversion in place**, পাঁচটি email-keyed table জুড়ে একটি transaction হিসেবে,
      returning-user unique-violation merge সহ (task 2.4)
- [ ] Abandoned-guest cleanup job + `users.converted_at` + `is_guest` index
- [ ] `users.suspended_at` / `suspended_reason` / `suspended_by` + suspend/reinstate endpoints
      (task 2.5 — **console 6.1 আটকে রাখে**)

### Content Library & Publishing System (পূর্ণ architecture, Phase 1)
- [ ] `library_itineraries`, `affiliate_partners`, `library_itinerary_affiliate_links`,
      `library_page_views`, `library_itinerary_slugs` tables + migrations (এই ক্রমে)
- [ ] Content-library module (presentation/application/domain/infrastructure layers)
- [ ] `content` validate করা হয় **shared** itinerary-root-object schema-র বিপরীতে (শুধু day
      array নয়), নিষিদ্ধ child-pricing keys সহ
- [ ] Draft → Scheduled → Published → Unpublished workflow
- [ ] কিছু একটা আসলে `scheduled` → `published` flip করে (job বা lazy check) — সিদ্ধান্ত নেওয়া + লিপিবদ্ধ
- [ ] প্রতিটি edit-এ `updated_by` + `updated_at` লেখা হয় (কোনো DB trigger নেই)
- [ ] Public `GET /library/:slug` + click-tracked affiliate redirect route
- [ ] Retired-slug 301 fallback; প্রথম publish-এর পরে slug স্থির (frozen)
- [ ] `library_page_views.is_bot` লেখার সময় stamp করা হয়
- [ ] Publishing Activity view (শুধুমাত্র `super_admin`) — author, timestamps, traffic, affiliate
      clicks
- [ ] `app_settings['library_goal_count']`-এর মাধ্যমে goal counter
- [ ] Affiliate partner catalog CRUD endpoints, `expiry_date` সহ (console alert states
      এর ওপর নির্ভর করে)
- [ ] দুটি content path-এই প্রতি-stop lat/lng — generation output এবং library content উভয়ে (map
      layer + console editor দুটিই এটি consume করে; একটি path ছাড়া অন্যটি = সম্পন্ন নয়)

### AI Model Routing
- [ ] `docs/ai-model-assignment-plan.md` যেমন লেখা আছে তেমনভাবে implement করুন (catalog, per-user override,
      resolution service, admin endpoints)
- [ ] **Scope সিদ্ধান্ত:** console-এর 5.x চায় একটি cost-per-request estimate, plan-tier
      defaults, এবং একটি versioned trip-mode prompt-template editor। **তিনটির কোনোটিই plan doc-এ বা
      কোনো table-এ নেই।** console 5.x শুরু করার আগে in/out of scope নিশ্চিত করুন —
      দেখুন `build-order-complete.md` §4।

### Payments
- [ ] Stripe audit (webhook signature যাচাইকৃত, failure-এ subscription status আসলেই flip হয়)
- [ ] SSLCommerz integration — session request, redirect, IPN handler, কোনো কিছু paid হিসেবে চিহ্নিত
      করার আগে বাধ্যতামূলক Transaction Validation API call সহ
- [ ] `payment_transactions` `gateway` + SSLCommerz columns দিয়ে বর্ধিত
- [ ] Admin payment-gateway config endpoint (শুধুমাত্র `super_admin`)

### PDF Watermarking
- [ ] Free-tier PDF export-এ server-side watermark, আসল plan tier-এর ভিত্তিতে, কখনোই client
      flag-এর ভিত্তিতে নয়

### Branding cleanup (একটি পরিকল্পিত pass, বিচ্ছিন্ন নয়)
- [ ] Canonical/OG/meta tags, `.env.example` company fields, metadata উদাহরণ — সব
      "TriplyAI"-তে

- [ ] **Phase 1 QA gate পাস হয়েছে** (`.claude/docs/qa-checklist.md`) ✅

---

## লক্ষ্য করা হয়েছে (বর্তমান scope-এর বাইরে — লগ করা, ব্যবস্থা নেওয়া হয়নি)

_`/ship-feature` চলাকালীন যা চোখে পড়েছে কিন্তু ঠিক করা হয়নি তা লগ করতে এই section ব্যবহার করুন,
`CLAUDE.md`-এর "don't fix while you're in there" নিয়ম অনুযায়ী।_
