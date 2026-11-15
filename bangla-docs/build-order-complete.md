# Backend — Phase 1 Build ক্রম

এমনভাবে সাজানো যাতে কোনো কিছুর dependency সম্পন্ন হওয়ার আগে সেটি হাতে নেওয়া না হয়। `/ship-feature` পরের item
বেছে নিতে এটি পড়ে। প্রতিটি entry = একটি feature = একটি branch।

> **Foundation শুরু করার আগে `database-schema.md` Part H পড়ুন** — ছয়টি সিদ্ধান্ত যা এখন সস্তা
> এবং data জমে গেলে ব্যয়বহুল (library page-এর ভাষা, scheduled page কে publish করে,
> guest/share-link expiry, guest retention window, support-queue assignment, Redis বনাম Postgres
> rate limiting)। সেই doc-এর Part F নিচের সবকিছুর জন্য সুনির্দিষ্ট migration ক্রম দেয়।

## 1. Foundation (এই সুনির্দিষ্ট ক্রমে build করুন — প্রতিটি আগেরটির ওপর নির্ভরশীল)

**1.0 — CORS-এ admin console origin allow করুন**
`src/core/config/cors.config.ts`-এর hardcoded array-তে `https://console.trytriplyai.com` (এবং এর local dev origin)
যোগ করুন; `credentials: true` রাখুন; একই edit-এ দুটি অচল
`journey.iplookup.xyz` / `journey-api.iplookup.xyz` origin ছেঁটে ফেলুন। **এটি একটি code
change, env var নয়** — `.env.example`-এর `CORS_ORIGIN` কখনোই পড়া হয় না (দেখুন
`infrastructure.md`)।
_নির্ভর করে: কিছুর ওপর নয়। আটকে রাখে: নিচের সবকিছু — এটি ship না হওয়া পর্যন্ত admin console এই API-তে
পৌঁছাতেই পারে না, তাই Foundation-এর কোনো কাজই আসল client থেকে যাচাই করা যায় না।_

**1.1 — Admin session JWT signing fix + httpOnly cookie**
base64 encode/decode session-কে `@nestjs/jwt` sign/verify দিয়ে প্রতিস্থাপন করুন। `ADMIN_JWT_SECRET`
env var যোগ করুন। Client `sessionStorage`-এ রাখে এমন token-এর বদলে session-টি একটি httpOnly/Secure/SameSite=Lax cookie
হিসেবে issue করুন। যাচাই করুন যে বিদ্যমান admin account-গুলো এখনও **console-এর নিজস্ব origin থেকে** log in করতে
পারে — curl সেই cookie/CORS interaction-টি পরীক্ষা করবে না যা এখানে আসলে ভাঙে। নিশ্চিত হওয়ার পরে,
`AdminAuthGuard` থেকে `Authorization: Bearer` path বাদ দিন।
_নির্ভর করে: 1.0। আটকে রাখে: নিচের role-সংক্রান্ত সবকিছু।_

**1.2 — `admin_users` RBAC columns (role + deactivation + revocation)**
একটি migration যা `role`, `is_active`, `token_version`, `role_assigned_by`,
`role_assigned_at` যোগ করে — দেখুন `database-schema.md` D1। Default `role = 'content_admin'`; **একই migration-এর
ভেতরে, CHECK constraint-এর আগে, প্রতিটি বিদ্যমান row-কে `super_admin`-এ backfill করুন**, নইলে
deploy-এর দিন পুরো team lock out হয়ে যাবে।
`is_active` এবং `token_version` ঐচ্ছিক অতিরিক্ত নয়: `library_itineraries.created_by` হলো
`ON DELETE RESTRICT`, তাই যে admin কিছু publish করেছেন তাকে কখনোই delete করা যাবে না — deactivation
হলো offboarding-এর একমাত্র পথ — এবং revocation ছাড়া একটি 24-ঘণ্টার admin JWT মানে বরখাস্ত হওয়া admin
আরও এক দিন কাজ করতে থাকে। `AdminAuthGuard`-কে অবশ্যই প্রতিটি request-এ `is_active` check করতে হবে।
_নির্ভর করে: 1.1 (যাতে এটি ship হওয়ার সময় জাল token-এর role বিশ্বাস করা না হয়)।_

**1.3 — Role-enforcement guard + `audit_logs` table**
`RequireRole()` decorator/guard, audit-log-before-commit middleware।
_নির্ভর করে: 1.2।_

**1.4 — Permission-key resolution + `GET /admin/me`**
চারটি role-এর প্রতিটি থেকে permission key-এর একটি set-এ একটি server-side map (`content.publish`,
`content.edit`, `users.suspend`, `models.edit`, `payments.configure`, `audit.view`, এবং module যোগ হওয়ার সাথে সাথে
আরও — সম্পূর্ণ Phase 1 key table-এর জন্য `rbac-and-security.md` দেখুন)। `GET /admin/me`
বর্তমান admin-এর `{ id, email, role, permissions: string[] }` return করে, প্রতিটি call-এ database থেকে resolve
করে — কখনোই token payload থেকে নয়। **console-এর সম্পূর্ণ role-gated nav
(এর Foundation task 1.2) এই endpoint consume করে** — এটি একটি কঠোর cross-repo dependency, কোনো
বাড়তি সুবিধা নয়।
_নির্ভর করে: 1.3। আটকে রাখে: console Foundation 1.2 এবং প্রতিটি role-gated console screen।_

## 2. Signup / guest-access fix

**2.1 — Guest-accessible generation endpoint**
`/itinerary/generate` কোনো auth header ছাড়াই কাজ করে।

⚠️ **একটি guest path ইতিমধ্যেই আছে এবং এর মাধ্যমে free tier ইতিমধ্যেই bypass করা যায়।**
`guest-auth.method.ts` একটি synthetic `<uuid>@guest.com` email দিয়ে একটি আসল `users` row তৈরি করে, এবং
usage গণনা হয় সেই email-এর বিপরীতে `user_itinerary_usage`-এ (যা `UNIQUE (email)` দ্বারা keyed)।
আবার guest হলে একটি নতুন uuid তৈরি হয় এবং **counter reset হয়ে যায়**। তাই এই task "একটি guest
path যোগ করা" নয় — এটি "বিদ্যমানটিকে গণনাযোগ্য করা।" এর মানে guest-দের জন্য rate limiter (2.2)-ই আসল
enforcement সীমা, per-email counter নয়। পূর্ণ বিবরণ:
`database-schema.md` §0.9।
এখানেই abandoned-guest retention window-ও ঠিক করুন (Part H, সিদ্ধান্ত 4) — আজ প্রতিটি guest login
একটি স্থায়ী `users` row লেখে, কোনো cleanup job ছাড়া।

**2.2 — Generation endpoint-এ rate limiter**
নতুন requirement — আজ কোনোটি নেই। Redis-ভিত্তিক নাকি Postgres-ভিত্তিক (`admin_login_attempts`
pattern-এর সাথে মিল রেখে) তা স্পষ্টভাবে ঠিক করুন; BullMQ অন্য কিছুর জন্য ইতিমধ্যে আছে বলে নীরবে
Redis ধরে নেবেন না।
_নির্ভর করে: 2.1।_

**2.3 — Guest itinerary persistence + shareable read-only link**
Persistence ইতিমধ্যেই কাজ করে (guest-রা আসল `users` row)। যা নেই তা হলো share link:
`user_itineraries`-এ **কোনো share-token column নেই** — `share_token`, `share_token_created_at`,
`share_revoked_at` এবং একটি partial unique index যোগ করুন (`database-schema.md` D2a)। Generate করুন
`crypto.randomBytes(24).toString('base64url')` দিয়ে — কখনোই row id নয়, কখনোই sequential নয়। Public
resolver-এর জন্য দরকার `share_token = $1 AND share_revoked_at IS NULL`, কোনো auth ছাড়া।
Share link expire হবে কি না ঠিক করুন (Part H, সিদ্ধান্ত 3) এবং যেকোনো ক্ষেত্রেই উত্তরটি `PROGRESS.md`-এ
লিখে রাখুন।
_নির্ভর করে: 2.1। **আটকে রাখে: frontend 4.3** (shareable read-only itinerary link) — এই task-এর আগে সেই feature-এর
কোনো backend owner ছিল না; frontend অংশটি আগে শুরু হতে দেবেন না।_

**2.4 — Guest → registered conversion (net-new, আগে কারও দায়িত্বে ছিল না)**
আজ, guest ব্যবহারের পরে sign up করলে একটি **দ্বিতীয়, সম্পর্কহীন account** তৈরি হয়: guest-এর
itinerary-গুলো orphan হয়ে যায় এবং usage counter নতুন করে শুরু হয়। নতুন row insert না করে বিদ্যমান guest row-কে
in place convert করে ঠিক করুন (`is_guest = false`, আসল email/name/password, `converted_at` stamp করুন)।
যেহেতু email পাঁচটি table জুড়ে একটি de facto identity key (`database-schema.md` §0.8), এটি
একটি **single transaction** যা `user_itineraries.email`,
`itinerary_generation_requests.email`, `user_itinerary_usage.email` এবং
`subscription_status.email`-ও পুনর্লিখন করে — কিন্তু **কখনোই** `payment_transactions.user_email` নয় (immutable ledger)।
`user_itinerary_usage.email` এবং `subscription_status.email` হলো `UNIQUE`, তাই একজন returning user
একটি unique violation তোলে: counter-গুলো merge করুন (বেশি count, পরের `reset_date`) এবং একই transaction-এর ভেতরে
guest row drop করুন। সুনির্দিষ্ট SQL `database-schema.md` D2b-তে।
_নির্ভর করে: 2.1। **Returning-user collision case test করুন** — production-এ এটিই প্রথম দেখা
দেয়।_

**2.5 — User suspend / reinstate (net-new, console 6.1 আটকে রাখে)**
`users`-এ soft-delete columns আছে কিন্তু **কোনো suspend column একেবারেই নেই** — নিশ্চিত করা হয়েছে। যোগ করুন
`suspended_at`, `suspended_reason`, `suspended_by` (`database-schema.md` D2c)। Suspension soft deletion থেকে
আলাদা: user এখনও বিদ্যমান, authenticate করতে পারে না, এবং reinstate করা যায়।
Auth `deleted_at IS NULL`-এর পাশাপাশি `suspended_at IS NULL` check করে; live session বন্ধ করতে suspend-এর সময়
`users.token_version` বাড়ান। প্রতিটি suspend `action = 'user.suspend'` সহ `audit_logs` লেখে।
_নির্ভর করে: 1.3 (role gating + audit)। **আটকে রাখে: console 6.1**, যার নিজস্ব build order আগেই
সন্দেহ করেছিল যে এই endpoint হয়তো নেই।_

## 3. Content Library & Publishing System

**3.1 — Schema**: `library_itineraries`, `affiliate_partners`,
`library_itinerary_affiliate_links`, `library_page_views`, `library_itinerary_slugs`।
এই ক্রমে তৈরি করুন — links table `affiliate_partners`-কে reference করে। Table-এর নাম
`page_views` থেকে `library_page_views` করা হয়েছে যাতে কেউ destination traffic এতে ঢেলে না দেয়। পূর্ণ DDL,
indexes এবং প্রতিটি column-এর পেছনের কারণ → `database-schema.md` Part C।
_নির্ভর করে: 1.3 (`created_by` → `admin_users` ব্যবহার করে, শুরু থেকেই role-gated)।_

**3.2 — Content-library module, admin CRUD + publish workflow**
দুটি বিষয় অন্তর্ভুক্ত যা সহজেই বাদ পড়ে: **(a)** যা `scheduled` → `published` flip করে তা ঠিক করুন ও build করুন
(কিছুই স্বয়ংক্রিয়ভাবে করে না — `library_itineraries_due_idx` poll করা একটি BullMQ repeatable job হলো
সুপারিশ; দেখুন `content-library.md`), এবং **(b)** প্রতিটি write-এ `updated_by` *এবং* `updated_at` সেট করুন — কোনো
database trigger নেই, তাই অন্যথায় Publishing Activity view-এর "last edited" column নীরবে তৈরির সময় দেখায়।
`content` validate হয় `user_itineraries.itinerary_content`-এর মতো **একই shared schema**-র বিপরীতে
(root object, শুধু day array নয়) — দেখুন `content-library.md`-এর 🚨।
_নির্ভর করে: 3.1।_

**3.3 — Public routes**: `GET /library/:slug`, affiliate click-tracked redirect,
`POST /library/:slug/view`। Slug resolver `library_itinerary_slugs`-এ fall back করে এবং একটি retired slug-এর জন্য
**301** উত্তর দেয়, তাই slug edit করলে কখনোই কোনো indexed URL 404 হয় না। User-agent দেখে লেখার সময়
`library_page_views.is_bot` stamp করুন — নইলে একটি public SEO page-এ "page views" মানে হবে "crawler hits।"
_নির্ভর করে: 3.2।_

**3.4 — Publishing Activity view** (শুধুমাত্র `super_admin`): author, timestamps, traffic, clicks।
_নির্ভর করে: 3.3 (`library_page_views` data প্রবাহিত হওয়া দরকার)।_

**3.5 — Goal counter** `app_settings`-এর মাধ্যমে।
_নির্ভর করে: 3.2। 3.3/3.4-এর সাথে সমান্তরালে build করা যায়।_

**3.6 — Affiliate partner catalog CRUD endpoints (`expiry_date` সহ)**
`affiliate_partners`-এর জন্য admin CRUD — list/create/update/deactivate, gated
`content_admin`/`super_admin`। Schema-তে `expiry_date` আছে (দেখুন `database-schema.md`) —
console এর ওপর 30-দিনের-সতর্কতা এবং past-due alert states তৈরি করে, তাই এটি অবশ্যই থাকতে হবে এবং
list endpoint থেকে return হতে হবে। Expiry কখনোই কোনো link স্বয়ংক্রিয়ভাবে disable করে না — এটি শুধু তথ্যমূলক।
_নির্ভর করে: 3.1। **আটকে রাখে: console 4.1 এবং 4.3** (আগে phantom task "4a"/"4d" হিসেবে উল্লেখ করা হয়েছিল)।_

**3.7 — দুটি content path-এই প্রতি-stop coordinates**
Day-by-day content shape-এ প্রতি-stop `lat`/`lng` যোগ করুন **একই feature-এ দুটি জায়গায়**:
(a) AI generation output (`itinerary_content.dailyPlans[]` **এবং** `dailyItinerary[]` — একটি
`generate-custom-itinerary-prompt.ts`-এ prompt/schema change), এবং (b) library content
validation, যেহেতু `library_itineraries.content`-কে সেই একই shape-এর সাথে মিলতে হবে। এটি একটি
index-aligned parallel array হিসেবে যোগ করুন (`activityCoordinates`, `activityLines`-এর সমান দৈর্ঘ্য, flight/generic
সন্ধ্যার জন্য `null`), বিদ্যমান `activityAttractionNumbers` convention-এর সাথে মিল রেখে,
`cities`-এর সাথে মিলিয়ে `numeric(10,8)`/`numeric(11,8)` precision-এ। `content_schema_version` বাড়িয়ে 2 করুন।
সুনির্দিষ্ট shape → `database-schema.md` D2e। Frontend map layer এবং console editor-এর coordinates field দুটিই
এটি consume করে; দুটি consumer repo-ই একে "সহজেই অর্ধেক build করে ফেলা যায়" বলে flag করেছে — **একটি path
অন্যটি ছাড়া করলে এই task-এর definition of done ব্যর্থ হয়।**
_নির্ভর করে: library অংশের জন্য 3.2; generation অংশ যেকোনো সময় শুরু করা যায়। **আটকে রাখে:
frontend 4.1 (map layer) এবং console 2.3 (coordinates field)।**_

## 4. AI Model Routing

**4.1 — `docs/ai-model-assignment-plan.md` হুবহু যেমন লেখা আছে তেমনভাবে implement করুন।**
`ai_models` catalog + `users.ai_model_custom` / `ai_model_destination` overrides +
`AiModelResolutionService` + admin endpoints সরবরাহ করে। Schema সারাংশ → `database-schema.md` C7/D4।
_নির্ভর করে: 1.3 (plan-এর নিজস্ব "optional superadmin gate" আর ঐচ্ছিক নয় — এই পর্যায়ে role
enforcement ইতিমধ্যেই আছে, তাই পরবর্তী follow-up হিসেবে নয়, শুরু থেকেই এটি wire করুন)।_

**⚠️ Console তিনটি জিনিস চায় যা এই plan cover করে না — এর 5.x-এর আগে এগুলোর scope ঠিক করুন**

Console task 5.1–5.3 এমন backend surface ধরে নেয় যা এই build order বা plan doc কোনোটিতেই
নেই। মাঝপথে build করতে গিয়ে আবিষ্কার না করে founder-এর সাথে scope নিশ্চিত করুন:

- **Cost-per-request estimate** (console 5.1) — `ai_models`-এ কোনো cost column নেই। হয়
  `cost_per_1k_input` / `cost_per_1k_output` numeric columns যোগ করুন, নয়তো UI থেকে estimate বাদ দিন।
- **Plan-tier defaults** (console 5.2) — plan doc resolve করে *env default → per-user override*।
  কোনো per-tier layer নেই। একটি যোগ করা মানে একটি নতুন resolution step এবং এটি রাখার একটি জায়গা
  (`app_settings` keys, অথবা একটি `subscription_tier → model` table)।
- **Trip-mode prompt template editor, versioned** (console 5.3) — **কোনো table নেই এবং কোনোটির
  পরিকল্পনাও নেই।** Prompt-গুলো code হিসেবে `generate-custom-itinerary-prompt.ts`-এ থাকে। একটি versioned,
  admin-editable prompt store একটি আসল feature (`prompt_templates` একটি version column সহ,
  কখনোই in place overwrite করা হয় না), বিদ্যমান কিছুর ওপর একটি UI নয়।

_এগুলোর কোনোটি scope-এ থাকলে, সেগুলো প্রথমে এখানে নম্বরযুক্ত backend task হয় — যেভাবেই হোক console-এর
5.x এগুলোর ওপর আটকে আছে।_

## 5. Payments

**5.1 — Stripe audit** (webhook signature check, subscription-status-flip verification)।
_নির্ভর করে: কিছুর ওপর নয় — যেকোনো সময় শুরু করা যায়, Foundation-এর সাথে সমান্তরালেও।_

**5.2 — SSLCommerz integration**: session request, redirect, IPN handler + বাধ্যতামূলক
Transaction Validation API call।
_নির্ভর করে: কাঠামোগতভাবে কিছুর ওপর নয়, তবে 5.1-এর পরে রাখুন যাতে দুটি gateway একসাথে review হয়,
পুরোনোটির আসল অবস্থা অজানা থাকা অবস্থায় নতুনটি build করা না হয়।_

**5.3 — Admin payment-gateway config endpoint।**
_নির্ভর করে: 1.3 (শুধুমাত্র super_admin), 5.1, 5.2।_

## 6. PDF Watermarking

**6.1 — Free-tier export-এ server-side watermark।**
_নির্ভর করে: কাঠামোগতভাবে কিছুর ওপর নয় — উপরের বেশিরভাগের সাথে সমান্তরালে চলতে পারে। শুধু শেষে রাখা হয়েছে
কারণ এটি কম ঝুঁকিপূর্ণ এবং অন্য কিছুকে আটকে রাখা উচিত নয়।_

## 7. Branding cleanup

**7.1 — একটি pass**: canonical/OG tags, `.env.example`, metadata উদাহরণ → "TriplyAI"।
_নির্ভর করে: প্রযুক্তিগতভাবে কিছুর ওপর নয়, তবে founder নাম চূড়ান্ত বলে নিশ্চিত না করা পর্যন্ত অপেক্ষা করুন (দেখুন
`branding.md`) — এটি সবশেষে করুন যাতে আবার করতে না হয়।_

---

## সমান্তরালকরণ নোট

- Foundation (1.1→1.3) হলো critical path — এটি Content Library (3.x) আটকে রাখে এবং
  AI Model Routing-এর (4.1) scope আরও স্পষ্ট করে। একে প্রথমে অগ্রাধিকার দিন।
- Signup fix (2.1→2.4) এবং Payments (5.x)-এর Foundation-এর ওপর কোনো dependency নেই এবং এগুলো একটি
  দ্বিতীয় workstream-এ সমান্তরালে চলতে পারে। **2.5 (user suspend) ব্যতিক্রম** — role gating এবং audit-এর জন্য
  এর 1.3 দরকার, তাই 2-এর অধীনে নম্বরযুক্ত হলেও এটি Foundation-এর workstream-এর সাথে থাকে।
- PDF Watermarking (6.1) এবং Branding (7.1) যেকোনো জায়গায় বসানো নিরাপদ — কম ঝুঁকি, কোনো
  blocking সম্পর্ক নেই।
