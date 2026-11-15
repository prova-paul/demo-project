# ডাটাবেস Schema

PostgreSQL, **Drizzle ORM**-এর মাধ্যমে। Schema ফাইলগুলো থাকে `src/infra/db/schema/`-এ, এগুলো re-export করা হয়
`src/infra/db/schema/index.ts` থেকে (drizzle-kit *শুধুমাত্র* ওই index পড়ে — কোনো নতুন schema ফাইল
সেখানে export করা না থাকলে migration generation-এর কাছে সেটি অদৃশ্য থাকে), এবং migration-গুলো generate হয়
`drizzle/`-এ।

**কখনোই হাতে migration লিখবেন না** — `npm run db:generate` চালান, তৈরি হওয়া SQL review করুন, তারপর
`npm run db:migrate`। Migration bookkeeping table হলো `public.migrations` (`drizzle.config.ts`)।

> **Part A**-এর সবকিছু সরাসরি schema ফাইল, repository-গুলো এবং
> প্রয়োগকৃত ১৪টি migration থেকে পড়া হয়েছে। এই doc যেখানে "confirmed" বলে, তার মানে source-এর সাথে মিলিয়ে নিশ্চিত করা হয়েছে।
> **Part H**-এ সেই design সিদ্ধান্তগুলোর তালিকা আছে যেগুলোতে এখনও একজন মানুষের সিদ্ধান্ত দরকার —
> Foundation শুরু করার আগে এটি পড়ুন, কারণ এর তিনটি table-এর আকার (shape) বদলে দেয়।

---

## 0. পুরো codebase জুড়ে প্রচলিত নিয়ম (কোনো DDL লেখার আগে পড়ুন)

### 0.1 Primary-key type সব জায়গায় একরকম নয় — migration-এর #1 ফাঁদ

| Table গ্রুপ | PK type | Table-গুলো |
|---|---|---|
| Users ও auth | `serial` (int4) | `users`, `otps`, `health` |
| Location catalog | `serial` (int4) | `countries`, `states`, `cities` |
| Settings | `serial` (int4) | `app_settings` |
| Admin, itineraries, payments, destinations | `uuid` + `defaultRandom()` | `admin_users`, `admin_login_attempts`, `custom_trip_requests`, `payment_transactions`, `destinations`, `destination_clicks`, `itineraries`, `user_itineraries`, `subscription_status`, `user_itinerary_usage` |
| Async generation queue | `text` (app-generated) | `itinerary_generation_requests` |

- **`users.id` হলো `INTEGER`।** এর প্রতিটি FK হলো `integer('user_id')`, কখনোই `uuid` নয়।
- **`admin_users.id` হলো `UUID`** — `admin-user.schema.ts`-এ *confirmed*
  (`uuid('id').primaryKey().defaultRandom()`)। আগের scaffold draft-গুলো এটিকে
  অযাচাইকৃত হিসেবে চিহ্নিত করেছিল; **এখন এটি যাচাই করা হয়েছে**, এবং নিচের প্রতিটি `REFERENCES admin_users(id)` সঠিকভাবে
  `UUID` type-এ রাখা আছে।

### 0.2 নতুন table-এর PK নিয়ম — entity বনাম event

এটি ইচ্ছাকৃত বিভাজন, অসঙ্গতি নয়। Phase 1 থেকে যোগ হওয়া সবকিছুতে এটি প্রয়োগ করুন:

| Table-এর ধরন | PK | কেন |
|---|---|---|
| **Domain entity** — edit করা হয়, URL দিয়ে reference করা হয়, API-তে expose করা হয় | `UUID DEFAULT gen_random_uuid()` | admin/content domain-এর সাথে মেলে; id-গুলো URL-এ দেখা যায় এবং enumerable হওয়া চলবে না |
| **Append-only event log** — পড়ার চেয়ে অনেক বেশি লেখা হয়, কখনো edit হয় না | `BIGSERIAL` | ক্রমিক insert PK B-tree-কে ঘন রাখে; বেশি-insert-এর table-এ random UUID index-কে fragment করে এবং কোনো লাভ ছাড়াই ~২× ফুলিয়ে দেয়। এই id-গুলো কখনো public হয় না |

তাই: `library_itineraries`, `affiliate_partners`, `library_itinerary_affiliate_links` → `UUID`।
`library_page_views`, `audit_logs`, যেকোনো rate-limit table → `BIGSERIAL`।

`destination_clicks` আজ UUID PK ব্যবহার করে। ওটা পুরোনো pattern; নতুন
high-volume table-গুলোর জন্য এটি কপি করবেন না, আবার এটিকে নতুন করে লিখবেনও না (Part E)।

### 0.3 Timestamp দুই স্টাইলে বিভক্ত — আশেপাশের কোডের সাথে মিলিয়ে চলুন

| স্টাইল | যারা ব্যবহার করে |
|---|---|
| `timestamp with time zone` | সব `admin/*`, `itineraries/*`, `subscriptions/*`, `destinations/*` |
| `timestamp without time zone` | `users/*` (`users`, `otps`), `location/*`, `settings/app_settings` |

**সব নতুন table `TIMESTAMPTZ` ব্যবহার করে।** কখনোই নতুন table-এ খালি `timestamp` যোগ করবেন না। বিদ্যমানগুলো সুযোগ পেলেই
"ঠিক" করবেন না — সেটি একটি data migration (Part E)।

### 0.4 কোনো PostgreSQL enum নয় — `text` + একটি CHECK constraint

`custom_trip_requests.status`, `payment_transactions.status`,
`itinerary_generation_requests.status` হলো সাধারণ `text`, অনুমোদিত value-গুলো একটি `//` comment-এ লেখা। 
`text` ব্যবহার চালিয়ে যান (মিশ্র enum/text পদ্ধতি একটি সামঞ্জস্যপূর্ণ দুর্বল পদ্ধতির চেয়েও খারাপ) কিন্তু নতুন table-এ **একটি
`CHECK` যোগ করুন** যাতে ডাটাবেস typo প্রত্যাখ্যান করে। একটি CHECK `ALTER` করা সস্তা; একটি pg enum
তা নয় — এবং Phase 3 affiliate category-গুলো বাড়ায়, তাই এটি বাস্তবেই গুরুত্বপূর্ণ।

### 0.5 `relations.ts` খালি — কোনো Drizzle relational layer নেই

`src/infra/db/schema/relations.ts` export করে `{}`। কেউই `db.query.*.with(...)` ব্যবহার করে না। প্রতিটি
join একটি repository-তে হাতে লেখা। একটি নতুন module-এর জন্য `relations()` চালু করবেন না।

### 0.6 `updated_at` নিজে নিজে update হয় না

প্রতিটি `updated_at` হলো `.notNull().defaultNow()` — একটি **default**, trigger নয়। `drizzle/`-এর কোথাও কোনো `ON UPDATE`
trigger নেই। **Repository-গুলোকে অবশ্যই প্রতিটি
UPDATE-এ `updatedAt: new Date()` সেট করতে হবে।** Publishing Activity view-এর
"last edited at" কলাম চুপচাপ ভেঙে যাওয়ার সবচেয়ে সম্ভাব্য একক কারণ এটিই।

### 0.7 নামকরণ

Table snake_case বহুবচন; SQL কলাম snake_case। TS property-গুলো camelCase, **তবে ব্যতিক্রম**
`users`, `otps` ও `app_settings`, যেগুলো TS property-তেও snake_case ব্যবহার করে (`email_verified`,
`deleted_at`, `expires_at`) — আপনি যে ফাইল edit করছেন তার সাথে মিলিয়ে চলুন। Drizzle export-গুলো একবচন
camelCase। প্রতিটি schema ফাইল শেষ হয় `export type X = typeof x.$inferSelect;` দিয়ে (+
বেশিরভাগে `$inferInsert`) — এটি চালিয়ে যান, repository-গুলো ওই type-গুলো import করে।

### 0.8 🚨 পাঁচটি table জুড়ে email কার্যত একটি identity key — এটি মাথায় রেখে পরিকল্পনা করুন

বিদ্যমান schema-র এটিই সবচেয়ে গুরুতর কাঠামোগত দুর্বলতা, এবং Phase 1-এর guest
কাজ সরাসরি এর মধ্য দিয়ে যায়।

| Table | Email কলাম | Constraint |
|---|---|---|
| `users` | `email` | `UNIQUE` — বৈধ, এটিই account key |
| `subscription_status` | `email` | **`UNIQUE`** — table-এর আসল key, `user_id` নয় |
| `user_itinerary_usage` | `email` | **`UNIQUE`** — একই |
| `user_itineraries` | `email` | NOT NULL, কোনো constraint নেই — `user_id` null হলে ownership fallback |
| `itinerary_generation_requests` | `email` | NOT NULL |
| `payment_transactions` | `user_email` | NOT NULL — ইচ্ছাকৃতভাবে denormalized যাতে account মুছে ফেলার পরও ledger টিকে থাকে |

`itinerary-usage.repository.ts`-এ confirmed: call site অনুযায়ী lookup চলে **দুটোতেই** — `eq(userItineraryUsage.email, …)`
এবং `eq(userItineraryUsage.userId, …)`।

**বাস্তবে এর অর্থ:**

1. **একজন user-এর email বদলানো একটি multi-table transaction**, শুধু `UPDATE users` নয়। পাঁচটি table
   অবশ্যই একসাথে বদলাতে হবে, নইলে usage limit ও subscription state account থেকে বিচ্ছিন্ন হয়ে যায়।
2. **Guest→registered রূপান্তরও একই transaction** (দেখুন §0.9 ও D2)।
3. `payment_transactions.user_email` হলো সেইটি যেটি **নতুন করে লেখা উচিত নয়** — এটি সেই সময়ে কে পেমেন্ট করেছিল তার
   অপরিবর্তনীয় ledger record। এটি rewrite করলে audit মূল্য নষ্ট হয়ে যায়।

**Phase 1-এ এটিকে শুধু-user-id ভিত্তিক করে refactor করবেন না।** এটি একসাথে subscription module,
admin data repository এবং limits repository-কে ছুঁয়ে যায়। এটি log করুন (Part E) এবং এর বদলে
email-change / conversion path-টি একটি স্পষ্ট, tested transaction হিসেবে লিখুন।

### 0.9 🚨 Guest account ইতিমধ্যেই আসল `users` row হিসেবে আছে — confirmed

`src/modules/authentication/infrastructure/auth-methods/guest-auth.method.ts` ইতিমধ্যেই
guest login implement করে, এবং এটি `users`-এ একটি **আসল row** তৈরি করে:

```ts
const guestCode = Email.create(randomUUID() + "@guest.com");
const passwordHash = await this.users.generatePasswordHash(randomUUID().toString());
// → INSERT INTO users (name='Guest', email='<uuid>@guest.com', is_guest=true,
//                      password=<bcrypt of random>, provider='guest',
//                      provider_id=<uuid>, email_verified=true)
```

তাই build-order 2.1/2.3-এর নতুন কোনো guest identity model **দরকার নেই** — একটি আগে থেকেই আছে। কিন্তু এর
তিনটি আসল ত্রুটি আছে যেগুলো Phase 1-কে অবশ্যই বন্ধ করতে হবে, এবং সেগুলো schema-সংলগ্ন:

1. **Free-tier limit খুব সহজেই এড়িয়ে যাওয়া যায়।** Guest usage গোনা হয়
   `user_itinerary_usage.email = '<uuid>@guest.com'`-এর বিপরীতে। Log out করুন, আবার guest হিসেবে log in করুন → নতুন
   uuid, নতুন email, **counter reset হয়ে যায়**। QA gate যে "silently bypass" কেস নিয়ে প্রশ্ন করে এটিই সেটি,
   এবং এটি আজই চালু আছে, কাল্পনিক নয়।
2. **Guest row চিরকাল জমতে থাকে।** প্রতিটি guest login একটি স্থায়ী `users` row insert করে। কোনো
   cleanup job নেই, কোনো retention policy নেই, এবং `is_guest`-এ কোনো index নেই। এগুলো admin
   Users list ও প্রতিটি user-count metric-কে দূষিত করে।
3. **Guest হিসেবে ব্যবহারের পর sign up করলে একটি দ্বিতীয়, সম্পর্কহীন account তৈরি হয়।** Guest
   row-কে নতুনটির সাথে কিছুই যুক্ত করে না, ফলে guest itinerary-গুলো orphan হয়ে যায় এবং usage counter নতুন করে শুরু হয়।

**প্রস্তাবিত সমাধান — জায়গাতেই রূপান্তর (convert in place) (দেখুন D2b)।** Signup-এর সময়, caller যদি একটি বৈধ
guest session উপস্থাপন করে, তাহলে নতুন একটি insert করার বদলে *বিদ্যমান guest row-টিকে mutate করুন* (আসল `email`/`name`/`password`/`provider` সেট করুন,
`is_guest = false`, `converted_at` stamp করুন)। Itinerary-গুলো
তাদের `user_id` রাখে, usage বহাল থাকে, কিছুই orphan হয় না। এর মূল্য হলো §0.8-এর email cascade —
`user_itineraries.email`, `user_itinerary_usage.email`, `subscription_status.email`,
`itinerary_generation_requests.email` সবগুলো একই transaction-এ update হয়। `payment_transactions.user_email`
update **হয় না** (ledger অপরিবর্তনীয়তা)।

এরপর guest-দের দ্বারা free tier-এর অপব্যবহার সীমাবদ্ধ হয় rate limiter (D5) ও IP দিয়ে, চাহিদামতো
নতুন করে তৈরি হওয়া একটি email দিয়ে নয়।

### 0.10 Index শৃঙ্খলা — বর্তমান অবস্থা খারাপ, আরও খারাপ করবেন না

যে index-গুলো আছে সেগুলো **শুধুমাত্র** এগুলোই (প্রয়োগকৃত ১৪টি migration জুড়ে grep করা):

```
cities:    city_country_code_idx, city_state_code_idx, city_country_state_name_idx
countries: country_iso_code_idx
states:    state_country_code_idx, state_country_iso_unique_idx (unique)
otps:      idx_otp_email, idx_otp_code, idx_otp_email_created
users:     users_phone_unique_not_empty (partial unique)
```

এর সাথে `users.email`, `admin_users.email`,
`countries.iso_code`, `subscription_status.email`, `user_itinerary_usage.email`,
`app_settings.key`-এর `.unique()`-এর পেছনে থাকা implicit unique index-গুলো।

**Admin / itinerary / payment domain-এর একটি foreign key-ও index করা নেই।** নিচের প্রতিটি নতুন table
একই migration-এ তার index-গুলো সহ ship হয়; Part E-তে backfill-গুলোর তালিকা আছে।

---

## 1. Table তালিকা

**আজ ১৮টি table আছে।** Phase 1 ৬–৭টি যোগ করে এবং ৪টি পরিবর্তন (alter) করে।

| # | Table | Domain | PK | অবস্থা |
|---|---|---|---|---|
| 1 | `users` | users | serial | আছে — **altered** |
| 2 | `otps` | users | serial | আছে |
| 3 | `health` | users | serial | আছে (liveness probe) |
| 4 | `admin_users` | admin | uuid | আছে — **altered** |
| 5 | `admin_login_attempts` | admin | uuid | আছে |
| 6 | `custom_trip_requests` | admin | uuid | আছে |
| 7 | `payment_transactions` | admin | uuid | আছে — **altered** |
| 8 | `user_itineraries` | itineraries | uuid | আছে — **altered** |
| 9 | `itinerary_generation_requests` | itineraries | text | আছে |
| 10 | `destinations` | destinations | uuid | আছে |
| 11 | `itineraries` | destinations | uuid | আছে (generation cache) |
| 12 | `destination_clicks` | destinations | uuid | আছে |
| 13 | `subscription_status` | subscriptions | uuid | আছে |
| 14 | `user_itinerary_usage` | subscriptions | uuid | আছে |
| 15–17 | `countries`, `states`, `cities` | location | serial | আছে (seeded) |
| 18 | `app_settings` | settings | serial | আছে |
| 19 | `library_itineraries` | content-library | uuid | **NEW** |
| 20 | `affiliate_partners` | content-library | uuid | **NEW** |
| 21 | `library_itinerary_affiliate_links` | content-library | uuid | **NEW** |
| 22 | `library_page_views` | content-library | bigserial | **NEW** |
| 23 | `library_itinerary_slugs` | content-library | bigserial | **NEW** (SEO redirect) |
| 24 | `audit_logs` | admin | bigserial | **NEW** |
| 25 | `ai_models` | ai | serial | **NEW** (spec: `docs/ai-model-assignment-plan.md`) |
| 26 | `generation_rate_limit_attempts` | itineraries | bigserial | **NEW, শর্তসাপেক্ষ** (শুধু যদি Redis-এর বদলে Postgres বেছে নেওয়া হয়) |

---

# PART A — বিদ্যমান table-গুলো (source-এর সাথে যাচাইকৃত)

## A1. `users` — `src/infra/db/schema/users/user.schema.ts`

| কলাম | Type | Null | Default | নোট |
|---|---|---|---|---|
| `id` | `serial` PK | না | seq | **integer** — এর প্রতিটি FK হলো `integer` |
| `name` | `text` | **NOT NULL** | — | guest-রা পায় `'Guest'` |
| `email` | `text` | **NOT NULL** | — | `UNIQUE`; guest-রা পায় `<uuid>@guest.com` |
| `is_guest` | `boolean` | হ্যাঁ | `false` | nullable — `NULL`-কে `false` হিসেবে ধরুন। **Unindexed** |
| `phone` | `text` | হ্যাঁ | — | partial-unique, নিচে দেখুন |
| `code` | `text` | হ্যাঁ | `''` | ফোনের country code |
| `password` | `text` | **NOT NULL** | — | bcrypt; guest-রা একটি random uuid-এর hash পায় |
| `avatar` / `cover_photo` | `text` | হ্যাঁ | `''` | |
| `trip_memories` | `jsonb` | হ্যাঁ | `[]` | `$type<string[]>` — image URL |
| `profile_display_name` / `profile_bio` | `text` | হ্যাঁ | `''` | |
| `provider` | `text` | **NOT NULL** | — | `local` / `google` / **`guest`** |
| `provider_id` | `text` | হ্যাঁ | `''` | |
| `email_verified` | `boolean` | **NOT NULL** | `false` | guest-দের `true` হিসেবে insert করা হয় |
| `email_verification_token` | `text` | হ্যাঁ | — | |
| `email_verification_expires_at` | `timestamp` | হ্যাঁ | — | *কোনো timezone নেই* |
| `password_reset_token` | `text` | হ্যাঁ | — | |
| `password_reset_expires_at` | `timestamp` | হ্যাঁ | — | *কোনো timezone নেই* |
| `token_version` | `integer` | **NOT NULL** | `0` | issue করা সব JWT অবৈধ করতে এটি বাড়ান — **এই pattern `admin_users`-এ কপি করুন** (D1) |
| `last_login_ip` / `last_login_user_agent` / `last_login_at` | `text`/`text`/`timestamp` | হ্যাঁ | — | |
| `deleted_at` | `timestamp` | হ্যাঁ | — | soft delete |
| `deletion_scheduled_for` | `timestamp` | হ্যাঁ | — | grace-period-এর মেয়াদ শেষ |
| `reactivation_token` / `reactivation_token_expires_at` | `text`/`timestamp` | হ্যাঁ | — | |
| `free_itinerary_monthly_limit` | `integer` | হ্যাঁ | — | **NULL = `FREE_TIER_MONTHLY_LIMIT` ব্যবহার করুন।** প্রমাণিত per-user-override pattern — AI model-এর জন্য হুবহু এটিই অনুসরণ করুন (D4) |
| `created_at` / `updated_at` | `timestamp` | **NOT NULL** | `now()` | auto-update হয় না (§0.6) |

**Index:** `users_phone_unique_not_empty` — `UNIQUE (phone) WHERE phone IS NOT NULL AND phone <> ''`।
একটি *partial* unique index; "উপস্থিত থাকলে unique" ক্ষেত্রে এই pattern পুনরায় ব্যবহার করুন (D2a তা-ই করে)।

**সতর্কতা (Gotchas):** schema স্তরে কোনো `deleted_at` filtering বাধ্যতামূলক নয় — প্রতিটি repository-কে অবশ্যই
এটি filter করতে হবে। **কোনো suspend/status কলামই নেই** — দেখুন D2c, এটি console 6.1-কে আটকে রাখে।

## A2. `otps`

`id serial PK`, `email text NOT NULL` (কোনো FK নেই — OTP signup-এর আগে আসে), `code text NOT NULL`,
`expires_at timestamp NOT NULL` (*কোনো tz নেই*), `used integer NOT NULL DEFAULT 0` (**একটি int, কোনো
boolean নয়** — `0`/`1`), `created_at timestamp NOT NULL DEFAULT now()`।

Index: `idx_otp_email`, `idx_otp_code`, `idx_otp_email_created (email, created_at)`।
Codebase-এর সবচেয়ে ভালোভাবে index করা table — নতুন table দেখতে কেমন হবে তার model হিসেবে এটি ব্যবহার করুন।
Row-গুলো কখনো purge করা হয় না; কোনো TTL job নেই (Part E)।

## A3. `health`

`{ id serial PK, status text NOT NULL }`। Liveness-probe target। এটি বাড়াবেন না।

## A4. `admin_users`

| কলাম | Type | Null | Default | নোট |
|---|---|---|---|---|
| `id` | `uuid` PK | না | `gen_random_uuid()` | **UUID — confirmed** |
| `email` | `text` | **NOT NULL** | — | `UNIQUE` |
| `password_hash` | `text` | **NOT NULL** | — | লক্ষ্য করুন: এখানে `password_hash`, `users`-এ `password` |
| `totp_secret` | `text` | হ্যাঁ | — | 2FA আছে **শুধু schema স্তরে** — 2FA কাজ করে দাবি করার আগে যাচাই করুন কোনো use-case আসলে এটি check করে কি না |
| `totp_enabled` | `boolean` | হ্যাঁ | `false` | |
| `created_at` / `updated_at` | `timestamptz` | **NOT NULL** | `now()` | |
| `last_login` | `timestamptz` | হ্যাঁ | — | লক্ষ্য করুন: `last_login`, `last_login_at` নয় |
| `login_attempts` | `integer` | হ্যাঁ | `0` | lockout counter |
| `locked_until` | `timestamptz` | হ্যাঁ | — | |

**কোনো `role` নেই। কোনো `is_active` নেই। কোনো `token_version` নেই।** তিনটিই D1-এ যোগ করা হয় — এবং RBAC-এর পুরো
ব্যবস্থাটি আসলে টিকে থাকার জন্য তিনটিই দরকার, শুধু role নয়।

## A5. `admin_login_attempts`

`id uuid PK`, `ip_address inet NOT NULL` (`destination_clicks` ছাড়া schema-তে একমাত্র native `inet`),
`email text`, `success boolean NOT NULL`, `user_agent text`,
`created_at timestamptz NOT NULL DEFAULT now()`।

**Postgres-ভিত্তিক rate limiter-এর বিদ্যমান দৃষ্টান্ত** (build-order 2.2)। নতুনটি এর আদলে তৈরি করুন
— কিন্তু লক্ষ্য করুন **এর কোনো index নেই**, তাই `(ip_address, created_at)` lookup আজ sequential-scan
করে। যেকোনো নতুন rate-limit table একই migration-এ তার index সহ ship হয়।

## A6. `custom_trip_requests`

ইতিমধ্যেই একটি **আসল status pipeline**, কোনো contact-form-এর ডাম্প নয়। Phase 4-এর "Done-for-You queue" হলো
এর ওপরে UI — কোনো নতুন backend table নয়।

`id uuid PK`, `full_name`/`email`/`destination`/`duration`/`budget_range`/`travelers` সবগুলো
`text NOT NULL` (`duration` ও `travelers` free text, সংখ্যা নয়), `additional_details text`,
`status text NOT NULL DEFAULT 'pending'` (`pending|contacted|quoted|converted|rejected`),
`priority text NOT NULL DEFAULT 'normal'` (`low|normal|high|urgent`), `admin_notes text`,
`estimated_value numeric(10,2)` (**node-postgres এটি string হিসেবে return করে**),
`quote_sent_at timestamptz`, `follow_up_date date`, `created_at`/`updated_at timestamptz NOT NULL`।

**কোনো `assigned_admin_id` নেই** — যখন `support_admin` gating আসবে, "my queue"-এর filter করার মতো কিছুই
থাকবে না (Part H, সিদ্ধান্ত 5)।

## A7. `payment_transactions`

⚠️ এটি থাকে `schema/admin/`-এর অধীনে, **কোনো `payments/` ফোল্ডারে নয়**। একটি তৈরি করবেন না।

| কলাম | Type | Null | Default | নোট |
|---|---|---|---|---|
| `id` | `uuid` PK | না | `gen_random_uuid()` | |
| `user_id` | `integer` | হ্যাঁ | — | FK → `users.id` `ON DELETE SET NULL` — মুছে ফেলার পরও ledger টিকে থাকে। **এই soft-reference pattern অনুসরণ করুন** |
| `user_email` | `text` | **NOT NULL** | — | উদ্দেশ্যমূলকভাবে denormalized — **অপরিবর্তনীয়, কখনোই rewrite করবেন না** (§0.8) |
| `type` | `text` | **NOT NULL** | — | `subscription \| one_time` |
| `stripe_payment_intent_id` / `stripe_subscription_id` / `stripe_customer_id` | `text` | হ্যাঁ | — | |
| `amount_cents` | `integer` | **NOT NULL** | — | minor unit |
| `currency` | `text` | হ্যাঁ | `'usd'` | ছোট হাতের ISO-4217 |
| `status` | `text` | **NOT NULL** | — | `pending\|succeeded\|failed\|canceled\|refunded` |
| `description` | `text` | হ্যাঁ | — | |
| `metadata` | `jsonb` | হ্যাঁ | — | gateway-এর raw payload |
| `created_at` / `updated_at` / `processed_at` | `timestamptz` | — | `now()` / — | |

**🐛 Type bug:** `.references(…, { onDelete: 'set null' }).$type<number>()` — `$type<number>`
Drizzle-এর inferred nullability-কে **override করে**, ফলে যে কলাম null হওয়ার জন্যই ডিজাইন করা, সেখানে TS মনে করে `userId` সবসময় একটি number।
`subscription_status.userId` ও `user_itinerary_usage.userId`-এও একই সমস্যা।
সঠিক রূপ হলো `$type<number | null>()`, যেমনটি `user_itineraries` ইতিমধ্যেই করে।

**SSLCommerz:** BDT অবশ্যই **poisha**-তে (×100) `currency = 'bdt'` সহ সংরক্ষণ করতে হবে, নইলে admin
payments view আসল অঙ্কের 100× দেখায়।

## A8. `user_itineraries`

মূল generated-itinerary table এবং **সেই কাঠামোগত চুক্তি (structural contract)** যার সাথে Content Library মেলে।

| কলাম | Type | Null | Default | নোট |
|---|---|---|---|---|
| `id` | `uuid` PK | না | `gen_random_uuid()` | |
| `user_id` | `integer` | হ্যাঁ | — | FK → `users.id` `ON DELETE CASCADE`, `$type<number \| null>` **(এখানে সঠিক)** |
| `email` | `text` | **NOT NULL** | — | ownership fallback; guest-দের ক্ষেত্রে এটি `<uuid>@guest.com` |
| `destination` | `text` | **NOT NULL** | — | |
| `start_date` / `end_date` | `text` | **NOT NULL** | — | **`text`, `date` নয়** — `YYYY-MM-DD` string। SQL-এ তুলনা করার আগে cast করুন |
| `days` | `integer` | **NOT NULL** | — | অবশ্যই `dailyPlans.length`-এর সমান হতে হবে |
| `group_type` / `trip_type` / `budget` | `text` | **NOT NULL** | — | `budget` একটি band label, সংখ্যা নয় |
| `interests` / `dietary_needs` | `text[]` | **NOT NULL** | — | **"Halal" হলো `dietary_needs`-এর একটি value, আলাদা কোনো mode নয়** |
| `country_of_origin` / `passport_nationality` | `text` | **NOT NULL** | — | ship হয়েছে + 6টি ভাষায় অনূদিত — আবার build করবেন না |
| `language_preference` | `text` | **NOT NULL** | `'English'` | |
| `traveler_age_ranges` | `text[]` | **NOT NULL** | `[]` | |
| `travel_pace` | `text` | **NOT NULL** | `'balanced'` | |
| `accommodation_type` | `text` | **NOT NULL** | — | |
| `daily_start_time` | `text` | **NOT NULL** | `'9:00 AM'` | |
| `include_free_time` | `boolean` | **NOT NULL** | `true` | |
| `itinerary_content` | `jsonb` | **NOT NULL** | — | **পূর্ণ itinerary root object** — §B1 |
| `daily_itinerary` | `jsonb` | হ্যাঁ | — | `itinerary_content.dailyPlans`-এর duplicate — §B1 |
| `cost_breakdown` | `jsonb` | হ্যাঁ | — | 7টি string key — §B2 |
| `visa_info` | `jsonb` | হ্যাঁ | — | §B3 |
| `total_cost` | `numeric` | হ্যাঁ | — | **কোনো precision নির্দিষ্ট নেই**; driver string return করে — গাণিতিক হিসাবের আগে parse করুন |
| `home_currency` | `text` | হ্যাঁ | — | grand total-এর সাথে সামঞ্জস্যপূর্ণ ISO-4217 |
| `created_at` / `updated_at` | `timestamptz` | **NOT NULL** | `now()` | |

**কোনো index-ই নেই** — `user_id`-এ নেই, `email`-এ নেই। প্রতিটি "my itineraries" lookup একটি
sequential scan (D2d)।

## A9. `itinerary_generation_requests`

**Async generation queue/status table**। Build order-এ উল্লেখ নেই, কিন্তু guest
path (2.1) ও rate limiter (2.2) দুটোই এই flow-এর মধ্য দিয়ে চলে।

`id text PK` (**app-generated string**), `user_id integer` FK → `users.id` `ON DELETE CASCADE`
type `number | null` (**ইতিমধ্যেই guest-সহনশীল**), `email text NOT NULL`, `destination text NOT NULL`,
`status text NOT NULL` (`pending|processing|completed|failed`), `payload jsonb NOT NULL`,
`itinerary_id text` (**`text`, কোনো FK নেই** — `user_itineraries.id`-কে নির্দেশ করে, যা একটি `uuid`, শুধুমাত্র
প্রথা অনুযায়ী), `error_message text`, `started_at`/`completed_at timestamptz`,
`created_at`/`updated_at timestamptz NOT NULL`।

Phase 1-এ `itinerary_id`-কে uuid FK-তে "ঠিক" করবেন না — live table, আসল row, ওটা একটি data
migration (Part E)।

## A10. `destinations`

Marketing catalog। **Content Library থেকে আলাদা** — সেটি একটি নতুন table (C1), এর কোনো
সম্প্রসারণ নয়।

`id uuid PK`, `name`/`description`/`duration text NOT NULL`, `price_per_day integer NOT NULL`,
`image_url`/`country`/`continent text`, `is_popular boolean DEFAULT false`,
`click_count integer DEFAULT 0`, `created_at`/`updated_at timestamptz NOT NULL`।

`click_count` হলো `destination_clicks` event table-এর পাশাপাশি একটি **denormalized counter** —
C3/C4 কীভাবে affiliate click বনাম page view সামলায় তার বিদ্যমান দৃষ্টান্ত।

## A11. `itineraries`

**Destination-page generation cache** — বিভ্রান্তিকর নাম; সহজেই
`user_itineraries` বা নতুন `library_itineraries` বলে ভুল হতে পারে।

`id uuid PK`, `destination_id uuid NOT NULL` FK → `destinations.id` `ON DELETE CASCADE`
(**unindexed**), `content text NOT NULL` (**`text`-এ একটি JSON string রাখা, `jsonb` নয়** — এটি parse
করুন, এর ভেতরে query করবেন না), `generated_at timestamptz NOT NULL`, `expires_at timestamptz NOT NULL`,
`created_at timestamptz NOT NULL`। কোনো `updated_at` নেই — row-গুলো প্রতিস্থাপিত হয়, edit হয় না।

## A12. `destination_clicks`

`id uuid PK`, `destination_id uuid NOT NULL` FK `ON DELETE CASCADE` (**unindexed**),
`clicked_at timestamptz NOT NULL DEFAULT now()`, `ip_address inet`, `user_agent text`।

**`library_page_views` (C4)-এর আকারের template** — একই event-row field। কলামগুলো কপি করুন;
UUID PK কপি **করবেন না** (§0.2)।

## A13. `subscription_status`

`id uuid PK`, `user_id integer` FK `ON DELETE CASCADE` (`$type<number>` bug),
`email text NOT NULL **UNIQUE**` (**table-এর আসল key**), `subscription_tier text NOT NULL DEFAULT 'free'`,
`is_active boolean NOT NULL DEFAULT false`, `stripe_customer_id text`,
`subscription_end timestamptz`, `created_at`/`updated_at timestamptz NOT NULL`।

প্রতি **email**-এ একটি row, প্রতি user id-তে নয় (§0.8)। **কোনো SSLCommerz customer কলাম নেই** — ইচ্ছাকৃত:
subscription state gateway-নিরপেক্ষ থাকে, gateway id-গুলো থাকে `payment_transactions`-এ।

## A14. `user_itinerary_usage`

`id uuid PK`, `user_id integer` FK `ON DELETE CASCADE` (`$type<number>` bug),
`email text NOT NULL **UNIQUE**`, `itinerary_count integer NOT NULL DEFAULT 0`,
`reset_date date NOT NULL` (একটি `date`, মাসিক rollover সীমা),
`created_at`/`updated_at timestamptz NOT NULL`।

`itinerary-usage.repository.ts` call site অনুযায়ী **দুটো দিয়েই** — `email` ও `user_id` — lookup করে।
**Guest free-tier bypass এই table-এই থাকে** — দেখুন §0.9।

## A15–A17. `countries`, `states`, `cities`

Seed করা reference data (`src/infra/db/seeders/`, ~22 MB `cities.json`)। App-এ শুধু-পড়ার জন্য।

- **`countries`** — `id serial PK`, `iso_code varchar(2) NOT NULL UNIQUE`, `name varchar(255) NOT NULL`,
  `phonecode varchar(255)`, `flag varchar(10)`, `currency varchar(3)`, `latitude numeric(10,8)`,
  `longitude numeric(11,8)`, `timezones jsonb`, খালি timestamp। Index: `country_iso_code_idx`।
- **`states`** — `iso_code varchar(10) NOT NULL`, `country_code varchar(2) NOT NULL` →
  **`countries.iso_code`-এ FK, `countries.id`-এ নয়**, lat/lng। Index: `state_country_code_idx`,
  `state_country_iso_unique_idx UNIQUE (country_code, iso_code)`।
- **`cities`** — `country_code varchar(2) NOT NULL` → `countries.iso_code`-এ FK;
  `state_code varchar(10)` (**কোনো FK নেই**, সাধারণ string); lat/lng। Index: `city_country_code_idx`,
  `city_state_code_idx`, `city_country_state_name_idx (country_code, state_code, name)`।

**Build-order 3.7-এর জন্য:** এগুলোতে ইতিমধ্যেই `numeric(10,8)` / `numeric(11,8)` coordinate আছে।
**সেই precision মিলিয়ে রাখুন** যাতে `cities` থেকে কপি করা একটি coordinate truncation ছাড়াই round-trip করে।
`numeric` ফেরত আসে **string** হিসেবে — map library-তে দেওয়ার আগে `parseFloat` করুন।
`countries.currency varchar(3)` হলো `home_currency` ও BDT কাজের জন্য স্বাভাবিক validation উৎস।

## A18. `app_settings`

`id serial PK`, `key text NOT NULL UNIQUE`, `value text NOT NULL` (**সবসময় `text`** — number
ও boolean string হিসেবে রাখা হয়), `updated_at timestamp NOT NULL DEFAULT now()` (খালি; **কোনো
`created_at` নেই**)। শুধু `$inferSelect` export করা আছে — প্রথমবার write করার সময় `$inferInsert` যোগ করুন।

**বৈশ্বিক ও ছোট যেকোনো কিছুর জন্য এটি সরাসরি ব্যবহার করুন।** Phase 1-এর key-গুলো:

| Key | Value format | কে লেখে |
|---|---|---|
| `library_goal_count` | string হিসেবে integer, যেমন `"250"` | `super_admin` |
| `payment_gateway_stripe_enabled` | `"true"` / `"false"` | `super_admin` |
| `payment_gateway_sslcommerz_enabled` | `"true"` / `"false"` | `super_admin` |

**Goal counter বা gateway config-এর জন্য কোনো নতুন table নয়।** Application
boundary-তে parse ও validate করুন — ডাটাবেস খুশিমনেই `"abc"` সংরক্ষণ করবে। এখানে প্রতিটি admin write
অন্য যেকোনো mutation-এর মতোই `audit_logs`-এর মধ্য দিয়ে যায়।

---

# PART B — JSONB payload-এর আকার (আসল চুক্তি)

Postgres দ্বারা বাধ্যতামূলক নয়। বাধ্যতামূলক করা হয় OpenAI prompt দিয়ে
(`src/modules/itinerary/infrastructure/providers/generate-custom-itinerary-prompt.ts`) এবং
use-case validation দিয়ে। **Content Library-কে অবশ্যই একই আকারের বিপরীতে validate করতে হবে** — এটিই
একটি published library page-কে generated page থেকে অভিন্ন করে তোলে।

## B0. একটি shared schema সংজ্ঞা, versioned

`user_itineraries.itinerary_content` ও `library_itineraries.content` অবশ্যই আকারে হুবহু এক থাকতে হবে।
**Validator একবারই সংজ্ঞায়িত করুন** — একটি shared জায়গায় একটি একক Zod schema (যেমন
`src/modules/itinerary/domain/contracts/itinerary-content.schema.ts`) যা
generation path ও content-library module দুটোই import করে। হাতে রক্ষণাবেক্ষণ করা দুটি কপি
এক sprint-এর মধ্যেই আলাদা হয়ে যাবে।

যেহেতু AI prompt বদলাতে থাকে, `library_itineraries.content_schema_version` (C1) রেকর্ড করে যে সংরক্ষিত page-টি কোন
revision অনুযায়ী লেখা হয়েছিল, যাতে ভবিষ্যতের কোনো prompt পরিবর্তন চুপচাপ অর্ধেক page render করার বদলে
পুরোনো library page-গুলোকে migrate করতে পারে বা সুন্দরভাবে degrade করতে পারে।

## B1. `user_itineraries.itinerary_content` (jsonb, NOT NULL) — root object

**🚨 আগের scaffold লেখার সংশোধন:** আগের draft-গুলোতে বলা হয়েছিল library content-কে "মিলতে হবে
`user_itineraries.dailyItinerary`-এর সাথে।" **এটি যথেষ্ট নয়।** `daily_itinerary` শুধুমাত্র
দিনের array। একটি rendered itinerary page যা ব্যবহার করে তা হলো `itinerary_content`, **root object**,
যার একটি key হলো `dailyPlans`। পুরোনো spec অনুযায়ী তৈরি একটি library page render হবে কোনো
overview, কোনো attraction, কোনো cost breakdown, কোনো key phrase ছাড়াই — কাঠামোগতভাবে *ভিন্ন*, যা
ঠিক সেটাই যা না হওয়ার প্রতিশ্রুতি Phase 1 দেয়। **`library_itineraries.content` মেলে
`itinerary_content`-এর সাথে।**

Root key-গুলো (generation prompt template থেকে confirmed):

```jsonc
{
  "title": "string",
  "overview": "string",
  "itinerary": "string",            // markdown teaser ONLY — never the day rows
  "days": 5, "totalDays": 5, "duration": "5 days",
  "startDate": "YYYY-MM-DD", "endDate": "YYYY-MM-DD",
  "budget": "string", "tripType": "string", "groupType": "string",
  "interests": ["string"],
  "highlights": ["string"],
  "tripSummary": ["string","string","string"],      // exactly 3, ≤160 chars each
  "alerts": [{ "body": "string", "alertType": "visa_warning" }],
  "visaRequired": true,
  "visaInfo": [ /* B3 */ ],
  "visaRequirements": [ … ],
  "visaApplication": { "steps": ["…","…","…"] },     // 3–4 strings, never []
  "visaCoverLetter": null,
  "dailyPlans": [ /* B1a — exactly `days` entries */ ],
  "dailyItinerary": [ /* structural duplicate of dailyPlans */ ],
  "attractions": [ /* ≤10 — B1b */ ],
  "keyPhrases": [{ "phrase": "…", "translation": "…", "pronunciation": "…" }],  // 5–8
  "recommendedApps": ["string"],
  "costBreakdown": { /* B2 — 7 string keys, object never array */ },
  "costBreakdownDetailed": { /* line-item rows + grand totals */ },
  "detailedCosts": [ /* optional, ≤10 rows */ ],
  "totalCost": 0
}
```

**Library validator-কে অবশ্যই যে invariant-গুলো বাধ্যতামূলক করতে হবে:**

- `dailyPlans.length === dailyItinerary.length === days === library_itineraries.duration_days`
- `dailyItinerary` হলো `dailyPlans`-এর duplicate, একই ক্রমে, একই object
- `costBreakdown` হলো **ঠিক 7টি string key সহ একটি object**, কখনোই array নয়
- `totalCost === costBreakdownDetailed.grandTotalHomeCurrency` (±1 rounding)
- day object-গুলোতে **কোনো** `activities`, `meals`, বা `transportation` array থাকবে না
- `itinerary` হলো markdown teaser string — দিনের row কখনোই ওই key-এর অধীনে থাকে না

### B1a. Day object (`dailyPlans[i]` / `dailyItinerary[i]`)

```jsonc
{
  "day": 1,
  "date": "YYYY-MM-DD",
  "city": "Primary city — never blank; 'City A → City B' on travel days",
  "location": "Neighbourhood / wider area (optional)",
  "theme": "Short day theme",
  "nightStay": "Non-empty: hotel area + city, or hotel name",
  "hotelName": "Optional specific property",
  "activityPlan": "string",
  "activityLines": ["09:00 AM ✈️ …", "…"],          // 5–7, each starts "HH:MM AM/PM "
  "activityPreBookRequired": [false, false, true],   // same length as activityLines
  "activityAttractionNumbers": [null, 1, 2],         // same length; int 1…N or null
  "activityLineBadges": [[], [], ["✅ Halal lunch"]]  // same length; 0–2 short strings each
}
```

`activityAttractionNumbers` অবশ্যই **পুরো trip জুড়ে কঠোরভাবে ক্রমবর্ধমান** হতে হবে এবং
`attractions[].number`-এর সাথে সামঞ্জস্যপূর্ণ হতে হবে।

**⚠️ আজ কোনো `lat`/`lng` field নেই — confirmed।** Build-order 3.7 এগুলো এখানে যোগ করে; এটিই
সেই নির্দিষ্ট object যা দুই অংশকেই বদলাতে হবে (D2e)।

### B1b. Attraction object (`attractions[i]`, ≤10)

আবশ্যক: `number` (int 1…N, `activityAttractionNumbers`-এর সাথে মিলিয়ে), `name`, `city`,
`advanceBookingRequired`। জোরালোভাবে প্রত্যাশিত: `icon`, `categoriesLine`,
`tags[{type: "warning"|"info"|"neutral", text}]` (0–4), `feeAdultLocalDisplay`,
`feeAdultHomeDisplay`, `durationText`, `timingNote`, `visitorNote`। ঐচ্ছিক: `citySectionIcon`,
`preBookingNote`, `bookingPlatform`, `inItinerary`, nested `adultPricing {local, home}`,
`duration {time, bestTime}`।

**Prompt-এর কঠোর নিয়ম: attraction-এ কোনো child pricing নয়।** `childPricingLabel`,
`feeChildLocalDisplay`, `feeChildHomeDisplay`, `childFeeLocalCurrency`, `childFeeHomeCurrency`,
`childPricing` / `child_pricing`, এবং `adultPricing`-এর অধীনে nested যেকোনো child fee অবশ্যই অনুপস্থিত থাকতে হবে।
**Library validation-কেও এই key-গুলো অবশ্যই প্রত্যাখ্যান করতে হবে**, নইলে হাতে লেখা page-গুলো এমন একটি pricing block render করবে
যা generated page কখনো দেখায় না।

## B2. `cost_breakdown` (jsonb, nullable)

**ঠিক 7টি key সহ একটি object, সবগুলো string value**: `accommodation`, `transportation`, `food`,
`activities`, `miscellaneous`, `total`, `dailyAverage`। কখনোই array নয়। আরও সমৃদ্ধ line-item
কাঠামোটি থাকে `itinerary_content.costBreakdownDetailed`-এ।

## B3. `visa_info` (jsonb, nullable)

1–2টি row-এর array:
`{ country, visaRequired: boolean, entryRequirements: string (≤200 chars), validity?: string }`।
Row-স্তরের `visaRequired` অবশ্যই root `visaRequired`-এর সাথে মিলতে হবে।

## B4. `users.trip_memories` (jsonb, default `[]`)

Image URL-এর `string[]`, `$type<string[]>()`।

---

# PART C — নতুন table (Phase 1)

Part F-এ দেওয়া ক্রমে তৈরি করুন। `library_itinerary_affiliate_links`-এর আগে `affiliate_partners`
অবশ্যই থাকতে হবে; `library_itineraries`-এর আগে `admin_users.role` (D1) অবশ্যই থাকতে হবে,
কারণ `created_by` প্রথম দিন থেকেই role-gated।

নতুন schema file যাবে `src/infra/db/schema/content-library/`-এ (এটির নিজস্ব domain, `admin/` নয়)।
**প্রতিটি `schema/index.ts` থেকে export করুন, নইলে drizzle-kit সেটি দেখতে পাবে না।**

## C1. `library_itineraries`

```sql
CREATE TABLE library_itineraries (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug                   TEXT NOT NULL,
  language               TEXT NOT NULL DEFAULT 'en',
  title                  TEXT NOT NULL,
  destination_city       TEXT NOT NULL,
  destination_country    TEXT NOT NULL,
  duration_days          INTEGER NOT NULL CHECK (duration_days > 0),
  theme_tags             TEXT[] NOT NULL DEFAULT '{}',

  status                 TEXT NOT NULL DEFAULT 'draft'
                           CHECK (status IN ('draft','scheduled','published','unpublished')),
  publish_at             TIMESTAMPTZ,
  published_at           TIMESTAMPTZ,

  content                JSONB NOT NULL,   -- matches user_itineraries.itinerary_content (§B1)
  content_schema_version INTEGER NOT NULL DEFAULT 1,

  meta_title             TEXT,
  meta_description       TEXT,
  hero_image_url         TEXT,
  hero_image_alt         TEXT,

  created_by             UUID NOT NULL REFERENCES admin_users(id) ON DELETE RESTRICT,
  created_by_email       TEXT NOT NULL,
  updated_by             UUID REFERENCES admin_users(id) ON DELETE SET NULL,

  created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT library_itineraries_slug_lang_unique UNIQUE (slug, language),
  CONSTRAINT library_itineraries_scheduled_needs_publish_at
    CHECK (status <> 'scheduled' OR publish_at IS NOT NULL),
  CONSTRAINT library_itineraries_published_needs_published_at
    CHECK (status <> 'published' OR published_at IS NOT NULL)
);

CREATE INDEX library_itineraries_status_idx     ON library_itineraries (status);
CREATE INDEX library_itineraries_created_by_idx ON library_itineraries (created_by);
CREATE INDEX library_itineraries_published_idx
  ON library_itineraries (published_at DESC) WHERE status = 'published';
CREATE INDEX library_itineraries_due_idx
  ON library_itineraries (publish_at) WHERE status = 'scheduled';
CREATE INDEX library_itineraries_browse_idx
  ON library_itineraries (destination_country, destination_city, duration_days)
  WHERE status = 'published';
CREATE INDEX library_itineraries_tags_idx ON library_itineraries USING GIN (theme_tags);
```

**প্রতিটি অস্পষ্ট column কেন আছে:**

- **`language`** — public site **ছয়টি** ভাষায় (en/bn/ar/ja/zh/fr) i18n সহ চলে, এবং এগুলো
  public SEO page। ছয়-ভাষার site-এ শুধু ইংরেজিতে publish করা একটি product decision, যার একটি
  schema-গত পরিণতি আছে: page index হয়ে যাওয়ার পরে language dimension যোগ করা মানে URL ভেঙে
  ফেলা। `DEFAULT 'en'` এখন কোনো খরচ নেয় না এবং `UNIQUE (slug, language)`-কে natural key বানায়।
  **উদ্দেশ্যটি নিশ্চিত করুন** — Part H, decision 1।
- **`title`** — `content`-এর root-ও একটি title বহন করে; এই column হলো admin-list এবং
  activity-view-এর sort key, যাতে ওই screen-গুলোকে কখনো JSONB খুলতে না হয়।
- **`content_schema_version`** — §B0 দেখুন। নইলে একটি required field যোগ করা prompt revision
  আগে publish হওয়া প্রতিটি page-কে নিঃশব্দে অর্ধেক render করবে।
- **`created_by_email`** denormalized, `payment_transactions.user_email`-এর মতো: Publishing
  Activity view প্রতিটি row-এর জন্য চিরকাল একজন author দেখায়। `created_by` `ON DELETE RESTRICT`
  ব্যবহার করে যাতে published content থাকা কোনো admin-কে hard-delete করা না যায় — এর বদলে deactivate করুন (D1)।
- **`updated_by` + `updated_at`** হলো যা console-এর "last edited at / by" column পড়ে।
  কোনো `ON UPDATE` trigger না থাকায় (§0.6), repository-কে প্রতিটি write-এ দুটোই **অবশ্যই** set করতে হবে।
- **চতুর্থ status হিসেবে `'unpublished'`** — `rbac-and-security.md` `super_admin`-কে unpublish
  করার অধিকার দেয়; আলাদা একটি value ছাড়া unpublished page-কে draft থেকে আলাদা করা যায় না এবং
  `published_at` মুছে যায়। Unpublish করার সময় `published_at` populated রাখুন।
- **`hero_image_alt`** — console-এর publish gate (এর 2.6) hero image *এবং alt*-এর উপর block করে।
  এই column ছাড়া gate-এর check করার কিছু থাকে না।
- **`theme_tags`-এ GIN** — console tag দিয়ে filter করে; একটি btree array-তে `&&` serve করতে পারে না।
- **`library_itineraries_browse_idx`** — public library browse/filter surface
  (country → city → duration) হলো এই page-গুলোর উপর প্রথম যা তৈরি হবে।
- **`(publish_at) WHERE status='scheduled'`-এর partial index** হলো scheduled→published
  transition যা poll করে। **কোনো কিছুই এটি স্বয়ংক্রিয়ভাবে বদলায় না — owner ঠিক করুন** (Part H, decision 2)।

**Slug-এর নিয়ম:** প্রতি ভাষায় unique। Publish করলে slug স্থির হয়ে যায় (C5 দেখুন)। Draft/scheduled row
কখনোই public-ভাবে return করা হয় না — application logic, public use-case-এ filter করা, `testing.md`-এ
তালিকাভুক্ত e2e test সহ।

## C2. `affiliate_partners`

**C3-এর আগে তৈরি করুন।**

```sql
CREATE TABLE affiliate_partners (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name            TEXT NOT NULL,
  category        TEXT NOT NULL CHECK (category IN ('hotel','restaurant','tour')),
  commission_note TEXT,
  base_url        TEXT NOT NULL,
  is_active       BOOLEAN NOT NULL DEFAULT true,
  expiry_date     DATE,
  created_by      UUID REFERENCES admin_users(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX affiliate_partners_category_idx ON affiliate_partners (category) WHERE is_active;
CREATE INDEX affiliate_partners_expiry_idx   ON affiliate_partners (expiry_date)
  WHERE expiry_date IS NOT NULL AND is_active;
```

- `category` **Phase 1-এর baseline তিনটিতে** CHECK-constrained। Phase 3 যোগ করবে flights /
  insurance / eSIM / gear / transfers / cards — একটি `ALTER … DROP CONSTRAINT … ADD CONSTRAINT`,
  আর ঠিক এই কারণেই এটি একটি CHECK, pg enum নয়।
- `commission_note` হলো **free text, calculated field নয়।** Phase 1-এ commission manually track
  করা হয়। "যেহেতু ওখানে আছেন" ভেবে `commission_rate NUMERIC` যোগ করবেন না — এটি এমন একটি হিসাবের
  ইঙ্গিত দেয় যা কিছুই করে না।
- `expiry_date` হলো `DATE` (`custom_trip_requests.follow_up_date`-এর সাথে মিল রেখে)। **Expiry কখনোই
  স্বয়ংক্রিয়ভাবে কিছু disable করে না** — console একটি 30-দিনের warning এবং একটি past-due state দেখায়; alert-টিই
  action item। List endpoint-কে অবশ্যই এটি return করতে হবে (console 4.1/4.3 এর উপর blocked)।
- `is_active = false` হলো deactivate-এর পথ। C3-এ row থাকা কোনো partner-কে **কখনোই hard-delete করবেন না** —
  ওই click history হলো revenue-এর প্রমাণ।

## C3. `library_itinerary_affiliate_links`

```sql
CREATE TABLE library_itinerary_affiliate_links (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  library_itinerary_id  UUID NOT NULL REFERENCES library_itineraries(id) ON DELETE CASCADE,
  affiliate_partner_id  UUID NOT NULL REFERENCES affiliate_partners(id) ON DELETE RESTRICT,
  section_type          TEXT NOT NULL CHECK (section_type IN ('hotel','restaurant','tour')),
  day_number            INTEGER,          -- NULL = page-level, not tied to one day
  display_label         TEXT NOT NULL,
  target_url            TEXT NOT NULL,
  click_count           INTEGER NOT NULL DEFAULT 0,
  sort_order            INTEGER NOT NULL DEFAULT 0,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX library_affiliate_links_itinerary_idx
  ON library_itinerary_affiliate_links (library_itinerary_id);
CREATE INDEX library_affiliate_links_partner_idx
  ON library_itinerary_affiliate_links (affiliate_partner_id);
```

- Partner FK-তে `ON DELETE RESTRICT` ইচ্ছাকৃত: deactivation হলো supported operation;
  একটি published page-এ live থাকা partner delete করা অবশ্যই জোরালোভাবে fail করবে।
- `day_number` console-কে শুধু page-এর বদলে একটি নির্দিষ্ট দিনের সাথে partner যুক্ত করতে দেয়।
  `NULL` = page-level। কোনো FK সম্ভব নয় (দিনগুলো JSONB-এর ভেতরে থাকে) — **use-case-এ
  `day_number <= library_itineraries.duration_days` validate করুন।**
- `click_count` হলো একটি **denormalized counter**, `destinations.click_count`-এর পূর্বদৃষ্টান্ত অনুসরণ করে।
  Redirect route-এ atomic SQL দিয়ে increment করুন (`SET click_count = click_count + 1`), JS-এ কখনোই
  read-modify-write নয়।
- **জ্ঞাত asymmetry, গৃহীত:** page view পায় time bucket সহ একটি পূর্ণ event table; affiliate
  click পায় শুধু একটি lifetime counter। Activity view আজ/7d/all-time view দেখাতে পারে কিন্তু click শুধু
  all-time। পরে যদি per-period click trend দরকার হয়, তখন একটি `library_affiliate_clicks`
  event table যোগ করুন — এখন এটি তৈরি করবেন না।
- **Rendering সবসময় tracked redirect route দিয়ে যায়।** একটি raw `<a href>` নিঃশব্দে
  tracking ভেঙে দেয় এবং schema-র কোনো কিছুই তা ধরতে পারে না — এটি একটি frontend review item।

## C4. `library_page_views`

নাম `library_page_views`, `page_views` **নয়** — যে codebase-এ আগে থেকেই
`destination_clicks` আছে, সেখানে একটি সাধারণ নাম কাউকে destination traffic-ও এখানে ঢুকিয়ে দিতে প্ররোচিত করে।

```sql
CREATE TABLE library_page_views (
  id                    BIGSERIAL PRIMARY KEY,        -- event table → bigserial (§0.2)
  library_itinerary_id  UUID NOT NULL REFERENCES library_itineraries(id) ON DELETE CASCADE,
  viewed_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  ip_address            INET,
  user_agent            TEXT,
  referrer              TEXT,
  is_bot                BOOLEAN NOT NULL DEFAULT false
);

CREATE INDEX library_page_views_itinerary_time_idx
  ON library_page_views (library_itinerary_id, viewed_at DESC) WHERE NOT is_bot;
```

- Column-এর গঠন `destination_clicks` থেকে কপি করা; PK হলো `BIGSERIAL` কারণ এটি হবে
  database-এর সবচেয়ে বেশি insert হওয়া table (§0.2)।
- **`is_bot` write-এর সময়েই set করা হয়**, record-view use-case-এ user-agent matching দিয়ে, এবং
  index bot-দের বাদ দেয়। এটি ছাড়া, public SEO page-এ "page views" মানে "crawler hits" এবং
  Publishing Activity-র সংখ্যাগুলো শুধু সাজসজ্জা। এর বদলে read-এর সময় filter করা মানে চিরকাল
  bot row-গুলো scan করা।
- **আজ / 7d / all-time query-র সময় aggregate করুন।** এখনই কোনো rollup table তৈরি **করবেন না**।
  নির্দিষ্ট tripwire: যখন এই table ~5M row পার হবে *অথবা* activity view ~200 ms ছাড়াবে, তখন একটি
  `library_page_view_daily (library_itinerary_id, day DATE, views INTEGER)` rollup যোগ করুন এবং raw
  row 90 দিন রাখুন। এই threshold আবার খুঁজে বের করার বদলে `PROGRESS.md`-এ লিখে রাখুন।
- **`ON DELETE CASCADE`** মানে একটি library page delete করলে এর traffic history ধ্বংস হয়ে যায়।
  `unpublished` status-এর সাথে মিলিয়ে, উদ্দিষ্ট lifecycle হলো *unpublish*, কখনোই delete নয়।

## C5. `library_itinerary_slugs` — SEO redirect history

যে content system-এর slug বদলাতে পারে, সেটি নিঃশব্দে নিজের index হওয়া URL-গুলোকে 404 করে দেয়।
দুটি সুরক্ষা, দুটোই সস্তা:

```sql
CREATE TABLE library_itinerary_slugs (
  id                    BIGSERIAL PRIMARY KEY,
  library_itinerary_id  UUID NOT NULL REFERENCES library_itineraries(id) ON DELETE CASCADE,
  slug                  TEXT NOT NULL,
  language              TEXT NOT NULL DEFAULT 'en',
  retired_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT library_itinerary_slugs_unique UNIQUE (slug, language)
);
```

1. **`status` একবারও `published` হয়ে থাকলে slug স্থির করে দিন** (application rule — console
   field-টি disable করে, use-case পরিবর্তন reject করে)।
2. যদি slug *অবশ্যই* বদলাতে হয়, পুরোনোটি এখানে লিখুন এবং `GET /library/:slug`-কে এই table-এ
   fall back করে বর্তমান slug-এ **301** দিয়ে উত্তর দিতে দিন।

নতুন slug validate করার সময় এখানকার `UNIQUE (slug, language)` অবশ্যই `library_itineraries`-এর নিজস্ব unique
constraint-এর সাথে একত্রে check করতে হবে, নইলে একটি নতুন page একটি retired URL চুরি করে নিতে পারে।

## C6. `audit_logs`

```sql
CREATE TABLE audit_logs (
  id              BIGSERIAL PRIMARY KEY,              -- event table (§0.2)
  actor_admin_id  UUID REFERENCES admin_users(id) ON DELETE SET NULL,
  actor_email     TEXT NOT NULL,
  action          TEXT NOT NULL,        -- 'role.change' | 'model.override' | 'user.suspend' | …
  target_type     TEXT NOT NULL,        -- 'admin_user' | 'user' | 'library_itinerary' | …
  target_id       TEXT NOT NULL,        -- TEXT: targets span uuid and integer PKs
  changed_fields  TEXT[] NOT NULL DEFAULT '{}',
  before          JSONB,
  after           JSONB,
  ip_address      INET,
  user_agent      TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX audit_logs_actor_time_idx  ON audit_logs (actor_admin_id, created_at DESC);
CREATE INDEX audit_logs_target_idx      ON audit_logs (target_type, target_id, created_at DESC);
CREATE INDEX audit_logs_action_time_idx ON audit_logs (action, created_at DESC);
```

**আগের scaffold draft থেকে ইচ্ছাকৃত বিচ্যুতি — প্রতিটি একটি correctness fix:**

- **`actor_admin_id` nullable, `ON DELETE SET NULL` সহ।** আগের `NOT NULL REFERENCES`
  version-এ কিছু করেছে এমন কোনো admin-কে কখনো delete করা অসম্ভব ছিল, এবং trail-এর টিকে থাকাকে
  actor-এর টিকে থাকার সাথে বেঁধে দিয়েছিল। যে audit log তার actor-কে delete করে delete করা যায়, তা audit log নয়।
  `actor_email` (NOT NULL, denormalized) প্রতিটি row-কে চিরকাল attributable রাখে।
- **`target_id` হলো `TEXT`, `UUID` নয়।** Target-এর মধ্যে আছে `users.id` (**integer**),
  `admin_users.id` (uuid) এবং `library_itineraries.id` (uuid)। একটি uuid column user
  id রাখতে পারে না — আগের design প্রথম `user.suspend` write-এই fail করত।
- **`changed_fields` + একটি payload size rule।** `before`/`after`-এ **কখনোই**
  `library_itineraries.content` থাকবে না — একটি itinerary edit প্রতি audit row-এ ~100 KB JSON লিখবে
  এবং এই table itinerary-গুলোর চেয়েও বড় হয়ে যাবে। পরিবর্তিত field-এর *নাম* রাখুন
  `changed_fields`-এ, এবং `before`/`after`-এ শুধু scalar/ছোট value রাখুন। Content edit-এর জন্য,
  `changed_fields = {'content'}` এবং দুটো payload-ই `NULL` — এটাই সঠিক ও যথেষ্ট।
- **`ip_address` / `user_agent`** — audit viewer-এর সবচেয়ে সাধারণ বাস্তব প্রশ্ন হলো "কোথা থেকে",
  এবং `admin_login_attempts` আগেই দুটোই ধরে রাখে, তাই console-এর একটি সামঞ্জস্যপূর্ণ গল্প থাকে।
- **`audit_logs_target_idx`** "এই user-এর সাথে যা কিছু কখনো ঘটেছে" চালায়, যেটার জন্যই
  viewer আসলে ব্যবহৃত হয়।

**Write-before-commit:** প্রতিটি mutating admin route পরিবর্তন commit করার **আগে**, একই
transaction-এ, তার audit row লেখে। Audit write fail করলে request fail closed হয়।

## C7. `ai_models` — spec আছে `docs/ai-model-assignment-plan.md`-এ

Build-order 4.1 বলে ওই plan **হুবহু যেমন লেখা আছে তেমনই** implement করতে। এই section আছে যাতে table-টি
schema doc থেকে অদৃশ্য না থাকে।

```sql
CREATE TABLE ai_models (
  id                    SERIAL PRIMARY KEY,          -- serial, per the plan doc
  provider              TEXT NOT NULL DEFAULT 'openai',
  model_id              TEXT NOT NULL UNIQUE,        -- 'gpt-4o', 'gpt-4o-mini', …
  display_name          TEXT NOT NULL,
  is_enabled            BOOLEAN NOT NULL DEFAULT true,
  max_completion_tokens INTEGER,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

`gpt-4o` (বর্তমান custom default) এবং `gpt-4o-mini` (বর্তমান destination default) seed করুন। শুধু
`response_format: json_object` support করে এমন model catalog-এ রাখুন। জোড়া user column D4-এ। Plan
অনুযায়ী, hard FK-এর বদলে এই catalog-এর বিপরীতে **app-level validation** পছন্দ করুন যাতে catalog row
soft-delete করা যায় — বিদ্যমান nullable-override style-এর সাথে সামঞ্জস্যপূর্ণ।

**PK বিচ্যুতি লক্ষ্য করা হয়েছে:** plan doc `SERIAL` নির্দিষ্ট করে, অন্যান্য নতুন table-এর মতো নয়। `model_id`
যেভাবেই হোক natural key। Plan doc অনুসরণ করুন — এই feature-এর জন্য এটিই authoritative।

---

# PART D — বিদ্যমান table-এ পরিবর্তন

## D1. `admin_users` — role, deactivation, forced logout (Foundation 1.2)

শুধু role column RBAC-কে কাজ করায় না। তিনটি column একসাথে ship হয়:

```sql
ALTER TABLE admin_users
  ADD COLUMN role             TEXT NOT NULL DEFAULT 'content_admin',
  ADD COLUMN is_active        BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN token_version    INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN role_assigned_by UUID REFERENCES admin_users(id) ON DELETE SET NULL,
  ADD COLUMN role_assigned_at TIMESTAMPTZ;

-- BACKFILL BEFORE ENFORCING ANYTHING:
UPDATE admin_users SET role = 'super_admin';

ALTER TABLE admin_users
  ADD CONSTRAINT admin_users_role_check
  CHECK (role IN ('super_admin','content_admin','support_admin','model_growth_admin'));

CREATE INDEX admin_users_role_idx ON admin_users (role) WHERE is_active;
```

- **Backfill column add-এর একই migration-এ, CHECK-এর আগে চালান।** আজ প্রত্যেক বিদ্যমান
  admin কার্যত super admin; তাদের `content_admin` default করে enforcement ship করলে deploy-এর দিন
  পুরো team `/admin/users` থেকে lock out হয়ে যাবে। Default থাকে
  `content_admin` যাতে *নতুন তৈরি* admin-রা least-privileged হয়।
- **`is_active` আবশ্যক, ঐচ্ছিক নয়।** `library_itineraries.created_by` হলো
  `ON DELETE RESTRICT`, তাই যে admin কিছু publish করেছে তাকে **delete করা যায় না**।
  তাই deactivation-ই একমাত্র offboarding পথ, এবং এই column ছাড়া সেটি নেই।
  `AdminAuthGuard`-কে অবশ্যই প্রতিটি request-এ role-এর পাশাপাশি `is_active` check করতে হবে।
- **`token_version` `users.token_version`-এর প্রতিফলন** — বিদ্যমান forced-logout pattern। Revocation
  ছাড়া 24-ঘণ্টার admin JWT মানে একজন deactivated admin এক দিন পর্যন্ত কাজ চালিয়ে যেতে পারে।
  Deactivate/role-change-এ এটি বাড়ালে তাদের session সঙ্গে সঙ্গে invalid হয়ে যায়। এটি
  token payload-এ রাখুন এবং `GET /admin/me`-এ DB row-এর সাথে তুলনা করুন।
- **`role_assigned_by` / `role_assigned_at`** পুরো table-এর audit-log scan ছাড়াই "কে এই ব্যক্তিকে
  super admin বানিয়েছে" প্রশ্নের উত্তর দেয়।

**Role কখনোই token থেকে বিশ্বাস করা হয় না।** `GET /admin/me` প্রতিটি call-এ row থেকে `role`, `is_active` এবং
`token_version` আবার পড়ে, তাই revoke করা role পরের request-এই শেষ হয়ে যায়।

## D2. `users` এবং `user_itineraries` — guest flow, suspend, coordinates

### D2a. Guest itinerary sharing — **এর কোথাও কোনো schema ছিল না**

Build-order 2.3 এবং frontend 4.3 দুটোই চায় "একটি অনুমান-অযোগ্য token, যা কোনো auth ছাড়াই resolve করা যায়।"
কিছুই এটি support করত না।

```sql
ALTER TABLE user_itineraries
  ADD COLUMN share_token            TEXT,
  ADD COLUMN share_token_created_at TIMESTAMPTZ,
  ADD COLUMN share_revoked_at       TIMESTAMPTZ;

CREATE UNIQUE INDEX user_itineraries_share_token_idx
  ON user_itineraries (share_token) WHERE share_token IS NOT NULL;
```

- **Nullable + partial unique index** — `users_phone_unique_not_empty`-এর মতো একই "থাকলে unique"
  pattern। শুধু shared itinerary-ই token পায়।
- `crypto.randomBytes(24).toString('base64url')` দিয়ে generate করুন — **কখনোই** row-এর `id` নয়, কখনোই
  sequential নয়। অনুমান-অযোগ্যতাই পুরো requirement।
- `share_revoked_at` itinerary ধ্বংস না করেই একটি revoke পথ দেয়। Public resolver-এর
  প্রয়োজন `share_token = $1 AND share_revoked_at IS NULL`।
- **Expiry একটি খোলা সিদ্ধান্ত** — Part H, decision 3।

### D2b. Guest → registered conversion (§0.9)

```sql
ALTER TABLE users
  ADD COLUMN converted_at TIMESTAMPTZ;

CREATE INDEX users_is_guest_idx ON users (is_guest, created_at) WHERE is_guest;
```

- `converted_at` এমন একটি row চিহ্নিত করে যা guest হিসেবে শুরু হয়ে আসল account হয়েছে — console-এর
  dashboard aggregate যে signup-conversion metric চায় তার জন্য, এবং পরবর্তীতে free-tier counter
  নিয়ে বিচার করার জন্য এটি দরকার।
- `users_is_guest_idx` abandoned-guest cleanup job এবং admin list filtering দুটোকেই support করে।
  এটি ছাড়া, দুটোই পুরো users table sequential-scan করে।

**Conversion নিজেই একটি single transaction, এবং এটিকে অবশ্যই একটি হিসেবেই লিখতে ও test করতে হবে:**

```
BEGIN;
  UPDATE users SET email=$real, name=$real, password=$hash, provider=$p,
                   is_guest=false, email_verified=false, converted_at=now(), updated_at=now()
    WHERE id=$guestId AND is_guest = true;
  UPDATE user_itineraries            SET email=$real, updated_at=now() WHERE user_id=$guestId;
  UPDATE itinerary_generation_requests SET email=$real, updated_at=now() WHERE user_id=$guestId;
  UPDATE user_itinerary_usage        SET email=$real, updated_at=now() WHERE user_id=$guestId;
  UPDATE subscription_status         SET email=$real, updated_at=now() WHERE user_id=$guestId;
  -- payment_transactions.user_email is NOT rewritten (immutable ledger, §0.8)
COMMIT;
```

**`user_itinerary_usage.email` এবং `subscription_status.email` দুটোই `UNIQUE`** — যদি আসল email-এর জন্য
আগে থেকেই একটি row থাকে (returning user), update একটি unique violation তুলবে।
এটি স্পষ্টভাবে handle করুন: counter-গুলো merge করুন (বেশি count এবং পরের `reset_date` নিন) এবং
guest row delete করুন, একই transaction-এর ভেতরে। **এই case-টি test করুন**; production-এ সবার আগে
এটিই দেখা দেবে।

**Abandoned guest-দের একটি retention policy দরকার।** কোনো itinerary ও কোনো activity ছাড়া
N দিন থাকা guest row একটি scheduled job দিয়ে delete করা উচিত। N ঠিক করুন (Part H, decision 4) — এটি ছাড়া এই
table চিরকাল junk row দিয়ে বাড়তে থাকবে, যা dashboard-এর প্রতিটি user-count metric-ও ফুলিয়ে দেয়।

### D2c. User suspend/reinstate — **কোনো schema নেই (console 6.1-কে block করে)**

`users`-এ soft-delete column আছে কিন্তু **কোনো suspend/status column নেই**। Console-এর নিজস্ব build order
আগেই সতর্ক করে যে এর suspend/reinstate screen-এর কোনো backend নাও থাকতে পারে; নিশ্চিত — এর কোনো column-ও
নেই।

```sql
ALTER TABLE users
  ADD COLUMN suspended_at     TIMESTAMP,
  ADD COLUMN suspended_reason TEXT,
  ADD COLUMN suspended_by     UUID REFERENCES admin_users(id) ON DELETE SET NULL;
```

এখানে bare `timestamp` `users`-এর বাকি অংশের সাথে মেলে (§0.3 — আশেপাশের সাথে মিল রাখুন)। Suspension
soft deletion থেকে আলাদা: suspended user-রা এখনও থাকে, authenticate করতে পারে না, এবং তাদের
reinstate করা যায়। Auth-কে অবশ্যই `deleted_at IS NULL`-এর পাশাপাশি `suspended_at IS NULL` check করতে হবে, এবং
suspend-এ `users.token_version` বাড়ালে live session সঙ্গে সঙ্গে শেষ হয়ে যায়। প্রতিটি suspend
`action = 'user.suspend'` সহ `audit_logs` লেখে।

### D2d. `user_itineraries`-এ অনুপস্থিত index

```sql
CREATE INDEX user_itineraries_user_id_idx    ON user_itineraries (user_id);
CREATE INDEX user_itineraries_email_idx      ON user_itineraries (email);
CREATE INDEX user_itineraries_created_at_idx ON user_itineraries (created_at DESC);
```

Phase 1-এর যে feature প্রথমে table-টি স্পর্শ করে তার সাথে ship করুন — admin itineraries list এবং "my
itineraries" দুটোই আজ sequential-scan করে, এবং উপরের guest-conversion transaction
`user_id` দিয়ে update করে।

### D2e. Per-stop coordinates — দুটো path, একটি feature (3.7)

**কোনো column পরিবর্তন নেই** — coordinates বিদ্যমান JSONB-এর ভেতরে থাকে। পরিবর্তন হলো গঠনে
(§B1a), এবং এটিকে অবশ্যই **একটি feature-এ দুই জায়গায়** আসতে হবে:

1. **Generation path** — `generate-custom-itinerary-prompt.ts`-এর prompt/schema, যাতে
   `itinerary_content.dailyPlans[]` / `dailyItinerary[]` coordinates বহন করে।
2. **Library path** — `library_itineraries.content` validation, যাতে হাতে লেখা page-গুলো
   একই field বহন করে।

একটি index-aligned parallel array হিসেবে যোগ করুন, day object যেভাবে আগে থেকেই ঐচ্ছিক per-line data
handle করে তার সাথে সামঞ্জস্য রেখে:

```jsonc
"activityCoordinates": [
  null,
  { "lat": 3.15785000, "lng": 101.71145000 },
  { "lat": 3.15200000, "lng": 101.70300000 },
  null, null
]
```

`activityLines`-এর সমান দৈর্ঘ্য; কোনো physical stop নেই এমন line-এর জন্য `null` (flight, সাধারণ
সন্ধ্যা) — `activityAttractionNumbers` আগে থেকেই যে convention ব্যবহার করে। মিল রাখুন
`cities.latitude`/`longitude`-এর precision-এর সাথে (`numeric(10,8)` / `numeric(11,8)`)। এটি ship হলে
`content_schema_version` বাড়িয়ে `2` করুন।

**একটি path করে অন্যটি না করলে task-এর definition of done fail করে** — frontend 4.1 (map) এবং
console 2.3 (coordinates field) প্রতিটি ভিন্ন অর্ধেক ব্যবহার করে।

## D3. `payment_transactions` — extend করুন, replace নয় (5.2)

```sql
ALTER TABLE payment_transactions
  ADD COLUMN gateway                   TEXT NOT NULL DEFAULT 'stripe',
  ADD COLUMN sslcommerz_transaction_id TEXT,
  ADD COLUMN sslcommerz_val_id         TEXT,
  ADD COLUMN sslcommerz_bank_tran_id   TEXT;

ALTER TABLE payment_transactions
  ADD CONSTRAINT payment_transactions_gateway_check
  CHECK (gateway IN ('stripe','sslcommerz'));

CREATE UNIQUE INDEX payment_transactions_sslcommerz_val_id_idx
  ON payment_transactions (sslcommerz_val_id) WHERE sslcommerz_val_id IS NOT NULL;

CREATE INDEX payment_transactions_user_id_idx ON payment_transactions (user_id);
CREATE INDEX payment_transactions_gateway_status_idx
  ON payment_transactions (gateway, status, created_at DESC);
```

- **একটি ledger, একটি admin view।** কোনো parallel SSLCommerz table নয়।
- `DEFAULT 'stripe'` প্রতিটি বিদ্যমান row সঠিকভাবে backfill করে।
- **`sslcommerz_val_id`-এর partial unique index হলো IPN replay guard।** SSLCommerz একই IPN একাধিকবার
  POST করতে পারে; database-এর duplicate `val_id` প্রত্যাখ্যান করা application-level "আমি কি এটা দেখেছি"-এর চেয়ে
  শক্তিশালী। এটি বাধ্যতামূলক Transaction Validation API call-কে replace **করে না** — আগে validate করুন,
  তারপর insert করুন (`payments.md`)।
- Reconciliation-এর সময় তাদের support যা চায় তা হলো `sslcommerz_bank_tran_id`। এখন সস্তা,
  পরে backfill করা কষ্টকর।
- BDT **poisha**-তে রাখুন `currency = 'bdt'` সহ (A7)।

## D4. `users` — AI model override (4.1)

```sql
ALTER TABLE users
  ADD COLUMN ai_model_custom      TEXT,
  ADD COLUMN ai_model_destination TEXT;
```

Nullable, **NULL = env default** (`OPENAI_MODEL_CUSTOM` / `OPENAI_MODEL_DESTINATION`) — মূল ভাবনায়
`free_itinerary_monthly_limit`-এর সাথে হুবহু এক। `ai_models`-এর বিপরীতে application
layer-এ validate করুন, FK দিয়ে নয়, যাতে catalog row soft-delete করা যায়। Set করা-কিন্তু-disabled বা অজানা model
অবশ্যই **400 দিয়ে reject** করবে, কখনোই নিঃশব্দে fall back করবে না — এটি `testing.md`-এর required case-গুলোর মধ্যে আছে।

## D5. Rate limiting storage (2.2)

`/itinerary/generate`-এর **কোনো rate limiter নেই** এবং এটি শীঘ্রই publicly callable হতে যাচ্ছে। Redis
আছে কিন্তু **শুধু একটি BullMQ backend হিসেবে** — caching, session, বা limiting নয়।

লক্ষ্য করুন যে guest থাকায়, **rate limiter-ই free-tier enforcement-এর mechanism** — §0.9
দেখায় যে per-email counter আবার guest হয়ে bypass করা যায়, তাই IP/token-based limiting-ই
আসলে অপব্যবহার সীমিত করে।

- **যদি Redis হয়:** কোনো schema পরিবর্তন নেই। `PROGRESS.md`-এ লিখে রাখুন যে Redis-এর এখন একটি দ্বিতীয়,
  non-BullMQ দায়িত্ব আছে, যাতে পরে কেউ ধরে না নেয় "Redis = শুধু queue"।
- **যদি Postgres হয়:** `admin_login_attempts`-এর আদলে তৈরি করুন — **ওই table-এ যে index নেই তা সহ**:

```sql
CREATE TABLE generation_rate_limit_attempts (
  id          BIGSERIAL PRIMARY KEY,
  ip_address  INET NOT NULL,
  email       TEXT,
  user_id     INTEGER REFERENCES users(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX generation_rate_limit_ip_time_idx
  ON generation_rate_limit_attempts (ip_address, created_at DESC);
```

যেভাবেই হোক, এর একটি cleanup ব্যবস্থা দরকার (Redis TTL, বা একটি delete-older-than job)। **Task 2.2-এ
স্পষ্টভাবে বেছে নিন** — Redis আছে বলেই সেদিকে ভেসে যাবেন না।

---

# PART E — জ্ঞাত schema ত্রুটি (লগ করা, Phase 1 scope নয়)

এখানে দৃশ্যমান রাখা হয়েছে যাতে কেউ `CLAUDE.md`-এর "ভেতরে থাকাকালীন ঠিক করবেন না" নিয়মের বিরুদ্ধে
feature-এর মাঝখানে কোনোটি "ঠিক" না করে ফেলে। ইচ্ছাকৃতভাবে আসল task-এ উন্নীত করুন।

1. **admin/itinerary/payment domain-এ কোনো FK index নেই** — `destination_clicks.destination_id`,
   `itineraries.destination_id`, `admin_login_attempts.ip_address` Phase 1-এর পরেও unindexed থাকে
   (Phase 1 যেগুলো স্পর্শ করে সেগুলো D2d এবং D3 ঠিক করে)।
2. **Nullable FK column-এ `$type<number>()`** — `payment_transactions.userId`,
   `subscription_status.userId`, `user_itinerary_usage.userId`। প্রতিটি এক লাইনের fix, কিন্তু এটি
   call site-গুলোতে আসল null check সামনে আনে, তাই এর নিজস্ব change প্রাপ্য।
3. **পাঁচটি table জুড়ে email-কে identity key হিসেবে ব্যবহার** (§0.8)। সঠিক fix হলো user-id-keyed
   subscription/usage, যেখানে email একটি সাধারণ attribute। তিনটি module স্পর্শ করে — Phase 1 নয়।
4. **`itinerary_generation_requests.itinerary_id` হলো `text`, `user_itineraries.id` (`uuid`)-এর প্রতি
   কোনো FK নেই।** Referential integrity শুধু convention-নির্ভর। এটি data migration, schema tweak নয়।
5. **Timestamp অসামঞ্জস্য** — `users`, `otps`, location table এবং `app_settings` bare
   `timestamp` ব্যবহার করে। Convert করার সাথে একটি timezone-interpretation সিদ্ধান্ত জড়িত।
6. **`otps` row কখনোই purge হয় না।** কোনো TTL নেই, কোনো cleanup job নেই।
7. **`app_settings`-এ কোনো `created_at` নেই** এবং কোনো `$inferInsert` export নেই।
8. **`relations.ts` একটি খালি object** — প্রতিটি join হাতে লেখা (§0.5)।
9. **`admin_users.totp_secret` / `totp_enabled` আছে**, কিন্তু কোনো code path TOTP verify করে কিনা তার
   কোনো নিশ্চয়তা নেই। কেউ 2FA live দাবি করার আগে verify করুন।
10. **`custom_trip_requests`-এ কোনো `assigned_admin_id` নেই** — per-admin queue সম্ভব নয়।
11. **Itinerary-র নামে তিনটি table** — `itineraries` (destination cache),
    `user_itineraries`, `library_itineraries`। `itineraries` → `destination_itinerary_cache`
    rename করলে বিভ্রান্তির একটি স্থায়ী উৎস দূর হবে; এটি একটি rename এবং সাথে
    প্রতিটি reference, তাই এর নিজস্ব change দরকার।
12. **`destination_clicks`-এর একটি append-only event table-এ UUID PK আছে** (§0.2)। যেমন আছে রেখে দেওয়া হয়েছে;
    pattern-টি কপি করবেন না।

---

# PART F — Phase 1 migration-এর ক্রম

প্রতিটি নম্বরযুক্ত item একটি generated migration। এই chain `build-order-complete.md`-এর সাথে মেলে;
এটি ভঙ্গ করলে এমন migration তৈরি হয় যা অনুপস্থিত table-এর কারণে fail করে।

| # | Migration | যোগ করে | নির্ভর করে |
|---|---|---|---|
| 1 | `admin_users_rbac` | D1: `role` + `is_active` + `token_version` + `role_assigned_*`, backfill, CHECK, index | — |
| 2 | `audit_logs` | C6 | 1 |
| 3 | `payment_transactions_multi_gateway` | D3 | — (parallel) |
| 4 | `users_guest_conversion_and_suspend` | D2b + D2c | 1 (`suspended_by` FK-এর জন্য) |
| 5 | `user_itineraries_share_token` | D2a + D2d index | — |
| 6 | `affiliate_partners` | C2 | 2 |
| 7 | `library_itineraries` | C1 | 2, 6 |
| 8 | `library_links_views_slugs` | C3 + C4 + C5 | 6, 7 |
| 9 | `ai_models_and_user_overrides` | C7 + D4 | 2 |
| 10 | `generation_rate_limit` *(শুধু Postgres হলে)* | D5 | — |

D2e (per-stop coordinates)-এর **কোনো migration নেই** — এটি একটি JSONB shape + validation পরিবর্তন, সাথে
`content_schema_version` বাড়িয়ে 2 করা।

**প্রতিটি migration:** `npm run db:generate` → emit হওয়া SQL পড়ুন → নিশ্চিত করুন FK column type
§0.1-এর সাথে মেলে → `npm run db:migrate`। **যদি generated SQL-এ `users.id`-এর দিকে নির্দেশ করা একটি `uuid` FK থাকে,
থামুন** — কিছু একটা ভুল আছে।

---

# PART G — Phase 1-এর জন্য প্রয়োজনীয় seed data

| Table | Row | কখন |
|---|---|---|
| `admin_users.role` | সব বিদ্যমান row backfill → `super_admin` | migration 1, CHECK-এর আগে |
| `app_settings` | `library_goal_count` (যেমন `"250"`) | goal counter ship হওয়ার আগে (3.5) |
| `app_settings` | `payment_gateway_stripe_enabled` = `"true"`, `payment_gateway_sslcommerz_enabled` = `"false"` | 5.3-এর আগে |
| `ai_models` | `gpt-4o` (custom default), `gpt-4o-mini` (destination default) | migration 9 — এগুলো ছাড়া resolution fail closed হয় |
| `affiliate_partners` | কিছু নয় | admin-রা console দিয়ে তৈরি করেন |

Seeder থাকে `src/infra/db/seeders/`-এ, `seeders/index.ts`-এ registered — migration-এ `INSERT` embed
করার বদলে বিদ্যমান pattern (`seed-countries.ts`, `seed-destination-itineraries.ts`) অনুসরণ করুন,
**ব্যতিক্রম** `admin_users.role` backfill, যা অবশ্যই তার
migration-এর সাথে atomic হতে হবে।

---

# PART H — খোলা সিদ্ধান্ত যা table-এর গঠন বদলায়

এগুলোর প্রতিটি এখন সস্তা এবং data থাকার পরে ব্যয়বহুল। তালিকাভুক্ত migration-এর আগে সমাধান করুন।

1. **Library page কি বহুভাষিক?** Public site ছয়টি ভাষায় চলে এবং এগুলো public
   SEO page। `language` + `UNIQUE (slug, language)` C1-এ একটি default-`'en'` column হিসেবে আছে, যা
   কোনো খরচ নেয় না এবং দরজা খোলা রাখে। যদি উত্তর দৃঢ়ভাবে "শুধু ইংরেজি, চিরকাল" হয়,
   migration 7-এর আগে column-টি সরিয়ে দিন — কিন্তু page index হওয়ার পরে এটি যোগ করা মানে
   live URL ভেঙে ফেলা। **সুপারিশ: এটি রাখুন।** *সিদ্ধান্ত নিন এর আগে: migration 7।*

2. **কে `scheduled` → `published` বদলায়?** কিছুই স্বয়ংক্রিয়ভাবে করে না। একটি BullMQ repeatable job
   (Redis + BullMQ আগে থেকেই mail-এর জন্য wired) `library_itineraries_due_idx` poll করে; বিকল্প
   হলো `GET /library/:slug`-এর ভেতরে একটি lazy check, যার মানে কেউ ঘটনাচক্রে request না করা পর্যন্ত একটি page
   অদৃশ্য থাকে। **সুপারিশ: repeatable job।** *সিদ্ধান্ত নিন: task 3.2-এ।*

3. **Guest itinerary এবং share link কি expire হয়?** D2a যেকোনোটিই support করে। যদি হ্যাঁ, `share_token`-এর
   পাশে একটি `expires_at` যোগ করুন। যদি না, `PROGRESS.md`-এ "no expiry, deliberate" লিখে রাখুন
   যাতে এটি bug হিসেবে আবার আবিষ্কৃত না হয়। *সিদ্ধান্ত নিন: task 2.3-এ।*

4. **Abandoned-guest retention window কত?** প্রতিটি guest login একটি স্থায়ী
   `users` row তৈরি করে (§0.9)। Cleanup job ছাড়া table সীমাহীনভাবে বাড়ে এবং dashboard-এর প্রতিটি
   user-count ভুল হয়। **সুপারিশ: কোনো itinerary নেই এমন guest row 30 দিন পরে delete করুন;
   যে guest কিছু generate করেছে তাদের share link expire হওয়া পর্যন্ত রাখুন।** *সিদ্ধান্ত নিন: task 2.1-এ।*

5. **`custom_trip_requests`-এর কি `assigned_admin_id` দরকার?** এটি ছাড়া, `support_admin` role
   gating প্রতিটি support admin-কে একই অবিভক্ত queue দেয়। ছোট team-এর জন্য ঠিক আছে;
   একাধিক হলে column যোগ করুন। *সিদ্ধান্ত নিন এর আগে: Phase 4।*

6. **Rate limiting-এর জন্য Redis নাকি Postgres** (D5) — এবং লক্ষ্য করুন যে এটিই guest-দের জন্য আসল free-tier
   enforcement। *সিদ্ধান্ত নিন: task 2.2-এ।*

---

# PART I — বৃদ্ধি এবং retention

| Table | বৃদ্ধির কারণ | Policy |
|---|---|---|
| `library_page_views` | প্রতিটি public page view | raw row রাখা হয়; ~5M row বা >200 ms activity query হলে daily rollup + 90-দিনের raw retention যোগ করুন |
| `audit_logs` | প্রতিটি mutating admin action | কম volume; `before`/`after`-এ **কখনোই** `content` blob রাখবেন না (C6) |
| `users` (guests) | প্রতিটি guest login | Part H decision 4 অনুযায়ী cleanup job |
| `otps` | প্রতিটি verification email | আজ কোনো purge নেই (Part E) |
| `generation_rate_limit_attempts` | প্রতিটি generation attempt | delete-older-than job, অথবা Redis TTL ব্যবহার করুন |
| `itineraries` (destination cache) | প্রতিটি cache miss | `expires_at` আছে; নিশ্চিত করুন যে কিছু একটা আসলেই expired row delete করে |
| `admin_login_attempts` | প্রতিটি admin login | কম volume, কোনো purge নেই — গ্রহণযোগ্য |

যে দুটি table আসলেই বড় হবে তা হলো `library_page_views` এবং, limiting-এর জন্য Postgres বেছে নিলে,
`generation_rate_limit_attempts`। দুটোই design অনুযায়ী `BIGSERIAL` append-only (§0.2), এবং
দুটোরই সমস্যা হয়ে ওঠার পরে নয়, আগেই একটি retention job দরকার।
