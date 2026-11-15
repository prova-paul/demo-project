# Database Schema

PostgreSQL via **Drizzle ORM**. Schema files live in `src/infra/db/schema/`, are re-exported
from `src/infra/db/schema/index.ts` (drizzle-kit reads *only* that index — a new schema file
that isn't exported there is invisible to migration generation), and migrations are generated
into `drizzle/`.

**Never hand-write a migration** — run `npm run db:generate`, review the emitted SQL, then
`npm run db:migrate`. Migration bookkeeping table is `public.migrations` (`drizzle.config.ts`).

> Everything in **Part A** was read directly out of the schema files, the repositories, and the
> 14 applied migrations. Where this doc says "confirmed", it means confirmed against source.
> **Part H** lists the design decisions that still need a human call — read it before starting
> Foundation, because three of them change table shapes.

---

## 0. Codebase-wide conventions (read before writing any DDL)

### 0.1 Primary-key types are NOT uniform — the #1 migration trap

| Table group | PK type | Tables |
|---|---|---|
| Users & auth | `serial` (int4) | `users`, `otps`, `health` |
| Location catalog | `serial` (int4) | `countries`, `states`, `cities` |
| Settings | `serial` (int4) | `app_settings` |
| Admin, itineraries, payments, destinations | `uuid` + `defaultRandom()` | `admin_users`, `admin_login_attempts`, `custom_trip_requests`, `payment_transactions`, `destinations`, `destination_clicks`, `itineraries`, `user_itineraries`, `subscription_status`, `user_itinerary_usage` |
| Async generation queue | `text` (app-generated) | `itinerary_generation_requests` |

- **`users.id` is `INTEGER`.** Every FK to it is `integer('user_id')`, never `uuid`.
- **`admin_users.id` is `UUID`** — *confirmed* in `admin-user.schema.ts`
  (`uuid('id').primaryKey().defaultRandom()`). Earlier scaffold drafts flagged this as
  unverified; **it is now verified**, and every `REFERENCES admin_users(id)` below is correctly
  typed `UUID`.

### 0.2 PK rule for NEW tables — entities vs. events

This is a deliberate split, not an inconsistency. Apply it to everything added from Phase 1 on:

| Kind of table | PK | Why |
|---|---|---|
| **Domain entity** — edited, referenced by URL, exposed in an API | `UUID DEFAULT gen_random_uuid()` | matches the admin/content domain; ids appear in URLs and must not be enumerable |
| **Append-only event log** — written far more than read, never edited | `BIGSERIAL` | sequential inserts keep the PK B-tree dense; random UUIDs on a high-insert table fragment the index and inflate it ~2× for no benefit. These ids are never public |

So: `library_itineraries`, `affiliate_partners`, `library_itinerary_affiliate_links` → `UUID`.
`library_page_views`, `audit_logs`, any rate-limit table → `BIGSERIAL`.

`destination_clicks` uses a UUID PK today. That's the older pattern; don't copy it for the new
high-volume tables, and don't rewrite it either (Part E).

### 0.3 Timestamps are split between two styles — match the neighbourhood

| Style | Used by |
|---|---|
| `timestamp with time zone` | all `admin/*`, `itineraries/*`, `subscriptions/*`, `destinations/*` |
| `timestamp without time zone` | `users/*` (`users`, `otps`), `location/*`, `settings/app_settings` |

**All new tables use `TIMESTAMPTZ`.** Never add a bare `timestamp` to a new table. Don't "fix"
existing ones opportunistically — that's a data migration (Part E).

### 0.4 No PostgreSQL enums — `text` + a CHECK constraint

`custom_trip_requests.status`, `payment_transactions.status`,
`itinerary_generation_requests.status` are plain `text` with allowed values in a `//` comment.
Keep using `text` (a mixed enum/text approach is worse than a consistent weak one) but **add a
`CHECK`** on new tables so the database rejects typos. A CHECK is cheap to `ALTER`; a pg enum
is not — and Phase 3 expands the affiliate categories, so that matters concretely.

### 0.5 `relations.ts` is empty — there is no Drizzle relational layer

`src/infra/db/schema/relations.ts` exports `{}`. Nothing uses `db.query.*.with(...)`. Every
join is hand-written in a repository. Don't introduce `relations()` for one new module.

### 0.6 `updated_at` does not update itself

Every `updated_at` is `.notNull().defaultNow()` — a **default**, not a trigger. No `ON UPDATE`
trigger exists anywhere in `drizzle/`. **Repositories must set `updatedAt: new Date()` on every
UPDATE.** This is the single most likely thing to silently break the Publishing Activity view's
"last edited at" column.

### 0.7 Naming

Tables snake_case plural; SQL columns snake_case. TS properties are camelCase **except** in
`users`, `otps` and `app_settings`, which use snake_case TS properties too (`email_verified`,
`deleted_at`, `expires_at`) — match the file you're editing. Drizzle exports are singular
camelCase. Every schema file ends with `export type X = typeof x.$inferSelect;` (+
`$inferInsert` on most) — keep doing this, the repositories import those types.

### 0.8 🚨 Email is a de facto identity key across five tables — plan around it

This is the most consequential structural weakness in the existing schema, and Phase 1's guest
work runs straight through it.

| Table | Email column | Constraint |
|---|---|---|
| `users` | `email` | `UNIQUE` — legitimate, it's the account key |
| `subscription_status` | `email` | **`UNIQUE`** — the real key of the table, not `user_id` |
| `user_itinerary_usage` | `email` | **`UNIQUE`** — same |
| `user_itineraries` | `email` | NOT NULL, no constraint — ownership fallback when `user_id` is null |
| `itinerary_generation_requests` | `email` | NOT NULL |
| `payment_transactions` | `user_email` | NOT NULL — deliberately denormalized so the ledger survives account deletion |

Confirmed in `itinerary-usage.repository.ts`: lookups run on **both** `eq(userItineraryUsage.email, …)`
and `eq(userItineraryUsage.userId, …)` depending on the call site.

**What this means in practice:**

1. **Changing a user's email is a multi-table transaction**, not an `UPDATE users`. Five tables
   must move together or usage limits and subscription state detach from the account.
2. **Guest→registered conversion is the same transaction** (see §0.9 and D2).
3. `payment_transactions.user_email` is the one that should **not** be rewritten — it's an
   immutable ledger record of who paid at the time. Rewriting it destroys the audit value.

**Do not refactor this to user-id-only in Phase 1.** It touches the subscription module, the
admin data repository, and the limits repository at once. Log it (Part E) and write the
email-change / conversion path as an explicit, tested transaction instead.

### 0.9 🚨 Guest accounts already exist as real `users` rows — confirmed

`src/modules/authentication/infrastructure/auth-methods/guest-auth.method.ts` already
implements guest login, and it creates a **real row in `users`**:

```ts
const guestCode = Email.create(randomUUID() + "@guest.com");
const passwordHash = await this.users.generatePasswordHash(randomUUID().toString());
// → INSERT INTO users (name='Guest', email='<uuid>@guest.com', is_guest=true,
//                      password=<bcrypt of random>, provider='guest',
//                      provider_id=<uuid>, email_verified=true)
```

So build-order 2.1/2.3 does **not** need a new guest identity model — one exists. But it has
three real defects that Phase 1 must close, and they are schema-adjacent:

1. **The free-tier limit is trivially bypassable.** Guest usage is counted against
   `user_itinerary_usage.email = '<uuid>@guest.com'`. Log out, log in as a guest again → new
   uuid, new email, **counter resets**. This is the "silently bypass" case the QA gate asks
   about, and it is live today, not hypothetical.
2. **Guest rows accumulate forever.** Every guest login inserts a permanent `users` row. There
   is no cleanup job, no retention policy, and no index on `is_guest`. They pollute the admin
   Users list and every user-count metric.
3. **Signing up after guest use creates a second, unrelated account.** Nothing links the guest
   row to the new one, so guest itineraries orphan and the usage counter starts fresh.

**Recommended fix — convert in place (see D2b).** On signup, if the caller presents a valid
guest session, *mutate the existing guest row* (set real `email`/`name`/`password`/`provider`,
`is_guest = false`, stamp `converted_at`) instead of inserting a new one. Itineraries keep
their `user_id`, usage carries over, nothing orphans. The cost is the §0.8 email cascade —
`user_itineraries.email`, `user_itinerary_usage.email`, `subscription_status.email`,
`itinerary_generation_requests.email` all update in the same transaction. `payment_transactions.user_email`
does **not** (ledger immutability).

Guest abuse of the free tier is then bounded by the rate limiter (D5) and by IP, not by an
email that regenerates on demand.

### 0.10 Index discipline — current state is poor, don't make it worse

The **only** indexes that exist (grepped across all 14 applied migrations):

```
cities:    city_country_code_idx, city_state_code_idx, city_country_state_name_idx
countries: country_iso_code_idx
states:    state_country_code_idx, state_country_iso_unique_idx (unique)
otps:      idx_otp_email, idx_otp_code, idx_otp_email_created
users:     users_phone_unique_not_empty (partial unique)
```

Plus implicit unique indexes behind `.unique()` on `users.email`, `admin_users.email`,
`countries.iso_code`, `subscription_status.email`, `user_itinerary_usage.email`,
`app_settings.key`.

**Not one foreign key in the admin / itinerary / payment domain is indexed.** Every new table
below ships its indexes in the same migration; Part E lists the backfills.

---

## 1. Table inventory

**18 tables exist today.** Phase 1 adds 6–7 and alters 4.

| # | Table | Domain | PK | Status |
|---|---|---|---|---|
| 1 | `users` | users | serial | exists — **altered** |
| 2 | `otps` | users | serial | exists |
| 3 | `health` | users | serial | exists (liveness probe) |
| 4 | `admin_users` | admin | uuid | exists — **altered** |
| 5 | `admin_login_attempts` | admin | uuid | exists |
| 6 | `custom_trip_requests` | admin | uuid | exists |
| 7 | `payment_transactions` | admin | uuid | exists — **altered** |
| 8 | `user_itineraries` | itineraries | uuid | exists — **altered** |
| 9 | `itinerary_generation_requests` | itineraries | text | exists |
| 10 | `destinations` | destinations | uuid | exists |
| 11 | `itineraries` | destinations | uuid | exists (generation cache) |
| 12 | `destination_clicks` | destinations | uuid | exists |
| 13 | `subscription_status` | subscriptions | uuid | exists |
| 14 | `user_itinerary_usage` | subscriptions | uuid | exists |
| 15–17 | `countries`, `states`, `cities` | location | serial | exists (seeded) |
| 18 | `app_settings` | settings | serial | exists |
| 19 | `library_itineraries` | content-library | uuid | **NEW** |
| 20 | `affiliate_partners` | content-library | uuid | **NEW** |
| 21 | `library_itinerary_affiliate_links` | content-library | uuid | **NEW** |
| 22 | `library_page_views` | content-library | bigserial | **NEW** |
| 23 | `library_itinerary_slugs` | content-library | bigserial | **NEW** (SEO redirects) |
| 24 | `audit_logs` | admin | bigserial | **NEW** |
| 25 | `ai_models` | ai | serial | **NEW** (spec: `docs/ai-model-assignment-plan.md`) |
| 26 | `generation_rate_limit_attempts` | itineraries | bigserial | **NEW, conditional** (only if Postgres chosen over Redis) |

---

# PART A — Existing tables (verified against source)

## A1. `users` — `src/infra/db/schema/users/user.schema.ts`

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `id` | `serial` PK | no | seq | **integer** — every FK to this is `integer` |
| `name` | `text` | **NOT NULL** | — | guests get `'Guest'` |
| `email` | `text` | **NOT NULL** | — | `UNIQUE`; guests get `<uuid>@guest.com` |
| `is_guest` | `boolean` | yes | `false` | nullable — treat `NULL` as `false`. **Unindexed** |
| `phone` | `text` | yes | — | partial-unique, see below |
| `code` | `text` | yes | `''` | phone country code |
| `password` | `text` | **NOT NULL** | — | bcrypt; guests get a hash of a random uuid |
| `avatar` / `cover_photo` | `text` | yes | `''` | |
| `trip_memories` | `jsonb` | yes | `[]` | `$type<string[]>` — image URLs |
| `profile_display_name` / `profile_bio` | `text` | yes | `''` | |
| `provider` | `text` | **NOT NULL** | — | `local` / `google` / **`guest`** |
| `provider_id` | `text` | yes | `''` | |
| `email_verified` | `boolean` | **NOT NULL** | `false` | guests are inserted as `true` |
| `email_verification_token` | `text` | yes | — | |
| `email_verification_expires_at` | `timestamp` | yes | — | *no timezone* |
| `password_reset_token` | `text` | yes | — | |
| `password_reset_expires_at` | `timestamp` | yes | — | *no timezone* |
| `token_version` | `integer` | **NOT NULL** | `0` | bump to invalidate all issued JWTs — **copy this pattern to `admin_users`** (D1) |
| `last_login_ip` / `last_login_user_agent` / `last_login_at` | `text`/`text`/`timestamp` | yes | — | |
| `deleted_at` | `timestamp` | yes | — | soft delete |
| `deletion_scheduled_for` | `timestamp` | yes | — | grace-period expiry |
| `reactivation_token` / `reactivation_token_expires_at` | `text`/`timestamp` | yes | — | |
| `free_itinerary_monthly_limit` | `integer` | yes | — | **NULL = use `FREE_TIER_MONTHLY_LIMIT`.** The proven per-user-override pattern — mirror it exactly for AI models (D4) |
| `created_at` / `updated_at` | `timestamp` | **NOT NULL** | `now()` | not auto-updated (§0.6) |

**Index:** `users_phone_unique_not_empty` — `UNIQUE (phone) WHERE phone IS NOT NULL AND phone <> ''`.
A *partial* unique index; reuse this pattern for "unique when present" (D2a does).

**Gotchas:** no `deleted_at` filtering is enforced at the schema level — every repository must
filter it. There is **no suspend/status column at all** — see D2c, this blocks console 6.1.

## A2. `otps`

`id serial PK`, `email text NOT NULL` (no FK — OTPs precede signup), `code text NOT NULL`,
`expires_at timestamp NOT NULL` (*no tz*), `used integer NOT NULL DEFAULT 0` (**an int, not a
boolean** — `0`/`1`), `created_at timestamp NOT NULL DEFAULT now()`.

Indexes: `idx_otp_email`, `idx_otp_code`, `idx_otp_email_created (email, created_at)`.
Best-indexed table in the codebase — use it as the model for what new tables look like.
Rows are never purged; no TTL job exists (Part E).

## A3. `health`

`{ id serial PK, status text NOT NULL }`. Liveness-probe target. Do not extend.

## A4. `admin_users`

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `id` | `uuid` PK | no | `gen_random_uuid()` | **UUID — confirmed** |
| `email` | `text` | **NOT NULL** | — | `UNIQUE` |
| `password_hash` | `text` | **NOT NULL** | — | note: `password_hash` here, `password` on `users` |
| `totp_secret` | `text` | yes | — | 2FA exists **at schema level only** — verify a use-case actually checks it before claiming 2FA works |
| `totp_enabled` | `boolean` | yes | `false` | |
| `created_at` / `updated_at` | `timestamptz` | **NOT NULL** | `now()` | |
| `last_login` | `timestamptz` | yes | — | note: `last_login`, not `last_login_at` |
| `login_attempts` | `integer` | yes | `0` | lockout counter |
| `locked_until` | `timestamptz` | yes | — | |

**No `role`. No `is_active`. No `token_version`.** All three are added in D1 — and all three are
needed for the RBAC story to actually hold together, not just the role.

## A5. `admin_login_attempts`

`id uuid PK`, `ip_address inet NOT NULL` (the only native `inet` in the schema besides
`destination_clicks`), `email text`, `success boolean NOT NULL`, `user_agent text`,
`created_at timestamptz NOT NULL DEFAULT now()`.

**The existing precedent for a Postgres-backed rate limiter** (build-order 2.2). Model the new
one on it — but note **it has no index**, so `(ip_address, created_at)` lookups sequential-scan
today. Any new rate-limit table ships its index in the same migration.

## A6. `custom_trip_requests`

Already a **real status pipeline**, not a contact-form dump. Phase 4's "Done-for-You queue" is
UI on top of this — no new backend table.

`id uuid PK`, `full_name`/`email`/`destination`/`duration`/`budget_range`/`travelers` all
`text NOT NULL` (`duration` and `travelers` are free text, not numbers), `additional_details text`,
`status text NOT NULL DEFAULT 'pending'` (`pending|contacted|quoted|converted|rejected`),
`priority text NOT NULL DEFAULT 'normal'` (`low|normal|high|urgent`), `admin_notes text`,
`estimated_value numeric(10,2)` (**returned as a string by node-postgres**),
`quote_sent_at timestamptz`, `follow_up_date date`, `created_at`/`updated_at timestamptz NOT NULL`.

**No `assigned_admin_id`** — when `support_admin` gating lands, "my queue" has nothing to filter
on (Part H, decision 5).

## A7. `payment_transactions`

⚠️ Lives under `schema/admin/`, **not** a `payments/` folder. Don't create one.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `id` | `uuid` PK | no | `gen_random_uuid()` | |
| `user_id` | `integer` | yes | — | FK → `users.id` `ON DELETE SET NULL` — ledger survives deletion. **Mirror this soft-reference pattern** |
| `user_email` | `text` | **NOT NULL** | — | denormalized on purpose — **immutable, never rewrite it** (§0.8) |
| `type` | `text` | **NOT NULL** | — | `subscription \| one_time` |
| `stripe_payment_intent_id` / `stripe_subscription_id` / `stripe_customer_id` | `text` | yes | — | |
| `amount_cents` | `integer` | **NOT NULL** | — | minor units |
| `currency` | `text` | yes | `'usd'` | lowercase ISO-4217 |
| `status` | `text` | **NOT NULL** | — | `pending\|succeeded\|failed\|canceled\|refunded` |
| `description` | `text` | yes | — | |
| `metadata` | `jsonb` | yes | — | gateway raw payload |
| `created_at` / `updated_at` / `processed_at` | `timestamptz` | — | `now()` / — | |

**🐛 Type bug:** `.references(…, { onDelete: 'set null' }).$type<number>()` — `$type<number>`
**overrides** Drizzle's inferred nullability, so TS believes `userId` is always a number on a
column designed to go null. Same on `subscription_status.userId` and `user_itinerary_usage.userId`.
Correct form is `$type<number | null>()`, as `user_itineraries` already does.

**SSLCommerz:** BDT must be stored in **poisha** (×100) with `currency = 'bdt'`, or the admin
payments view shows 100× the real figure.

## A8. `user_itineraries`

The core generated-itinerary table and **the structural contract** the Content Library matches.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `id` | `uuid` PK | no | `gen_random_uuid()` | |
| `user_id` | `integer` | yes | — | FK → `users.id` `ON DELETE CASCADE`, `$type<number \| null>` **(correct here)** |
| `email` | `text` | **NOT NULL** | — | ownership fallback; for guests this is `<uuid>@guest.com` |
| `destination` | `text` | **NOT NULL** | — | |
| `start_date` / `end_date` | `text` | **NOT NULL** | — | **`text`, not `date`** — `YYYY-MM-DD` strings. Cast before comparing in SQL |
| `days` | `integer` | **NOT NULL** | — | must equal `dailyPlans.length` |
| `group_type` / `trip_type` / `budget` | `text` | **NOT NULL** | — | `budget` is a band label, not a number |
| `interests` / `dietary_needs` | `text[]` | **NOT NULL** | — | **"Halal" is a value in `dietary_needs`, not a separate mode** |
| `country_of_origin` / `passport_nationality` | `text` | **NOT NULL** | — | shipped + translated in 6 languages — do not rebuild |
| `language_preference` | `text` | **NOT NULL** | `'English'` | |
| `traveler_age_ranges` | `text[]` | **NOT NULL** | `[]` | |
| `travel_pace` | `text` | **NOT NULL** | `'balanced'` | |
| `accommodation_type` | `text` | **NOT NULL** | — | |
| `daily_start_time` | `text` | **NOT NULL** | `'9:00 AM'` | |
| `include_free_time` | `boolean` | **NOT NULL** | `true` | |
| `itinerary_content` | `jsonb` | **NOT NULL** | — | **the full itinerary root object** — §B1 |
| `daily_itinerary` | `jsonb` | yes | — | duplicate of `itinerary_content.dailyPlans` — §B1 |
| `cost_breakdown` | `jsonb` | yes | — | 7 string keys — §B2 |
| `visa_info` | `jsonb` | yes | — | §B3 |
| `total_cost` | `numeric` | yes | — | **no precision specified**; driver returns a string — parse before arithmetic |
| `home_currency` | `text` | yes | — | ISO-4217 aligned with the grand total |
| `created_at` / `updated_at` | `timestamptz` | **NOT NULL** | `now()` | |

**No indexes at all** — not on `user_id`, not on `email`. Every "my itineraries" lookup is a
sequential scan (D2d).

## A9. `itinerary_generation_requests`

The **async generation queue/status table**. Not mentioned in the build order, but the guest
path (2.1) and rate limiter (2.2) both run through this flow.

`id text PK` (**app-generated string**), `user_id integer` FK → `users.id` `ON DELETE CASCADE`
typed `number | null` (**already guest-tolerant**), `email text NOT NULL`, `destination text NOT NULL`,
`status text NOT NULL` (`pending|processing|completed|failed`), `payload jsonb NOT NULL`,
`itinerary_id text` (**`text`, no FK** — points at `user_itineraries.id`, a `uuid`, by
convention only), `error_message text`, `started_at`/`completed_at timestamptz`,
`created_at`/`updated_at timestamptz NOT NULL`.

Don't "fix" `itinerary_id` to a uuid FK in Phase 1 — live table, real rows, that's a data
migration (Part E).

## A10. `destinations`

Marketing catalog. **Distinct from the Content Library** — that's a new table (C1), not an
extension of this one.

`id uuid PK`, `name`/`description`/`duration text NOT NULL`, `price_per_day integer NOT NULL`,
`image_url`/`country`/`continent text`, `is_popular boolean DEFAULT false`,
`click_count integer DEFAULT 0`, `created_at`/`updated_at timestamptz NOT NULL`.

`click_count` is a **denormalized counter** alongside the `destination_clicks` event table —
the existing precedent for how C3/C4 handle affiliate clicks vs. page views.

## A11. `itineraries`

The **destination-page generation cache** — confusingly named; easy to mistake for
`user_itineraries` or the new `library_itineraries`.

`id uuid PK`, `destination_id uuid NOT NULL` FK → `destinations.id` `ON DELETE CASCADE`
(**unindexed**), `content text NOT NULL` (**`text` holding a JSON string, not `jsonb`** — parse
it, don't query into it), `generated_at timestamptz NOT NULL`, `expires_at timestamptz NOT NULL`,
`created_at timestamptz NOT NULL`. No `updated_at` — rows are replaced, not edited.

## A12. `destination_clicks`

`id uuid PK`, `destination_id uuid NOT NULL` FK `ON DELETE CASCADE` (**unindexed**),
`clicked_at timestamptz NOT NULL DEFAULT now()`, `ip_address inet`, `user_agent text`.

**The shape template for `library_page_views` (C4)** — same event-row fields. Copy the columns;
do **not** copy the UUID PK (§0.2).

## A13. `subscription_status`

`id uuid PK`, `user_id integer` FK `ON DELETE CASCADE` (`$type<number>` bug),
`email text NOT NULL **UNIQUE**` (**the real key of the table**), `subscription_tier text NOT NULL DEFAULT 'free'`,
`is_active boolean NOT NULL DEFAULT false`, `stripe_customer_id text`,
`subscription_end timestamptz`, `created_at`/`updated_at timestamptz NOT NULL`.

One row per **email**, not per user id (§0.8). **No SSLCommerz customer column** — deliberate:
subscription state stays gateway-agnostic, gateway ids live on `payment_transactions`.

## A14. `user_itinerary_usage`

`id uuid PK`, `user_id integer` FK `ON DELETE CASCADE` (`$type<number>` bug),
`email text NOT NULL **UNIQUE**`, `itinerary_count integer NOT NULL DEFAULT 0`,
`reset_date date NOT NULL` (a `date`, monthly rollover boundary),
`created_at`/`updated_at timestamptz NOT NULL`.

`itinerary-usage.repository.ts` looks up by **both** `email` and `user_id` depending on call
site. **This table is where the guest free-tier bypass lives** — see §0.9.

## A15–A17. `countries`, `states`, `cities`

Seeded reference data (`src/infra/db/seeders/`, ~22 MB `cities.json`). Read-only in the app.

- **`countries`** — `id serial PK`, `iso_code varchar(2) NOT NULL UNIQUE`, `name varchar(255) NOT NULL`,
  `phonecode varchar(255)`, `flag varchar(10)`, `currency varchar(3)`, `latitude numeric(10,8)`,
  `longitude numeric(11,8)`, `timezones jsonb`, bare timestamps. Index: `country_iso_code_idx`.
- **`states`** — `iso_code varchar(10) NOT NULL`, `country_code varchar(2) NOT NULL` →
  **FK to `countries.iso_code`, not `countries.id`**, lat/lng. Indexes: `state_country_code_idx`,
  `state_country_iso_unique_idx UNIQUE (country_code, iso_code)`.
- **`cities`** — `country_code varchar(2) NOT NULL` → FK to `countries.iso_code`;
  `state_code varchar(10)` (**no FK**, plain string); lat/lng. Indexes: `city_country_code_idx`,
  `city_state_code_idx`, `city_country_state_name_idx (country_code, state_code, name)`.

**For build-order 3.7:** these already carry `numeric(10,8)` / `numeric(11,8)` coordinates.
**Match that precision** so a coordinate copied from `cities` round-trips without truncation.
`numeric` comes back as a **string** — `parseFloat` before handing it to a map library.
`countries.currency varchar(3)` is the natural validation source for `home_currency` and BDT work.

## A18. `app_settings`

`id serial PK`, `key text NOT NULL UNIQUE`, `value text NOT NULL` (**always `text`** — numbers
and booleans are stringly typed), `updated_at timestamp NOT NULL DEFAULT now()` (bare; **there
is no `created_at`**). Only `$inferSelect` is exported — add `$inferInsert` when you first write.

**Use this directly for anything global and small.** Phase 1 keys:

| Key | Value format | Written by |
|---|---|---|
| `library_goal_count` | integer as string, e.g. `"250"` | `super_admin` |
| `payment_gateway_stripe_enabled` | `"true"` / `"false"` | `super_admin` |
| `payment_gateway_sslcommerz_enabled` | `"true"` / `"false"` | `super_admin` |

**No new table for the goal counter or gateway config.** Parse and validate at the application
boundary — the database will happily store `"abc"`. Every admin write here goes through
`audit_logs` like any other mutation.

---

# PART B — JSONB payload shapes (the real contract)

Not enforced by Postgres. Enforced by the OpenAI prompt
(`src/modules/itinerary/infrastructure/providers/generate-custom-itinerary-prompt.ts`) and by
use-case validation. **The Content Library must validate against the same shapes** — that's what
makes a published library page indistinguishable from a generated one.

## B0. One shared schema definition, versioned

`user_itineraries.itinerary_content` and `library_itineraries.content` must stay identical in
shape. **Define the validator once** — a single Zod schema in a shared location (e.g.
`src/modules/itinerary/domain/contracts/itinerary-content.schema.ts`) imported by both the
generation path and the content-library module. Two hand-maintained copies will drift within
one sprint.

Because the AI prompt evolves, `library_itineraries.content_schema_version` (C1) records which
revision a stored page was authored against, so a future prompt change can migrate or
gracefully degrade old library pages instead of silently rendering half a page.

## B1. `user_itineraries.itinerary_content` (jsonb, NOT NULL) — the root object

**🚨 Correction to earlier scaffold text:** previous drafts said library content should "match
`user_itineraries.dailyItinerary`." **That is not sufficient.** `daily_itinerary` is only the
day array. What a rendered itinerary page consumes is `itinerary_content`, the **root object**,
of which `dailyPlans` is one key. A library page built to the old spec would render with no
overview, no attractions, no cost breakdown, no key phrases — structurally *different*, which is
exactly what Phase 1 promises it won't be. **`library_itineraries.content` matches
`itinerary_content`.**

Root keys (confirmed from the generation prompt template):

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

**Invariants the library validator must enforce:**

- `dailyPlans.length === dailyItinerary.length === days === library_itineraries.duration_days`
- `dailyItinerary` duplicates `dailyPlans`, same order, same objects
- `costBreakdown` is an **object with exactly 7 string keys**, never an array
- `totalCost === costBreakdownDetailed.grandTotalHomeCurrency` (±1 rounding)
- day objects contain **no** `activities`, `meals`, or `transportation` arrays
- `itinerary` is the markdown teaser string — day rows never live under that key

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

`activityAttractionNumbers` must be **strictly increasing across the whole trip** and align with
`attractions[].number`.

**⚠️ There are no `lat`/`lng` fields today — confirmed.** Build-order 3.7 adds them here; this
is the exact object both halves must change (D2e).

### B1b. Attraction object (`attractions[i]`, ≤10)

Required: `number` (int 1…N, matching `activityAttractionNumbers`), `name`, `city`,
`advanceBookingRequired`. Strongly expected: `icon`, `categoriesLine`,
`tags[{type: "warning"|"info"|"neutral", text}]` (0–4), `feeAdultLocalDisplay`,
`feeAdultHomeDisplay`, `durationText`, `timingNote`, `visitorNote`. Optional: `citySectionIcon`,
`preBookingNote`, `bookingPlatform`, `inItinerary`, nested `adultPricing {local, home}`,
`duration {time, bestTime}`.

**Hard rule from the prompt: no child pricing on attractions.** `childPricingLabel`,
`feeChildLocalDisplay`, `feeChildHomeDisplay`, `childFeeLocalCurrency`, `childFeeHomeCurrency`,
`childPricing` / `child_pricing`, and any child fee nested under `adultPricing` must be absent.
**Library validation must reject these keys too**, or hand-authored pages render a pricing block
generated pages never show.

## B2. `cost_breakdown` (jsonb, nullable)

Object with **exactly 7 keys, all string values**: `accommodation`, `transportation`, `food`,
`activities`, `miscellaneous`, `total`, `dailyAverage`. Never an array. The richer line-item
structure lives in `itinerary_content.costBreakdownDetailed`.

## B3. `visa_info` (jsonb, nullable)

Array of 1–2 rows:
`{ country, visaRequired: boolean, entryRequirements: string (≤200 chars), validity?: string }`.
Row-level `visaRequired` must agree with root `visaRequired`.

## B4. `users.trip_memories` (jsonb, default `[]`)

`string[]` of image URLs, `$type<string[]>()`.

---

# PART C — New tables (Phase 1)

Create in the order in Part F. `affiliate_partners` must exist before
`library_itinerary_affiliate_links`; `admin_users.role` (D1) must exist before
`library_itineraries` since `created_by` is role-gated from day one.

New schema files go in `src/infra/db/schema/content-library/` (its own domain, not `admin/`).
**Export every one from `schema/index.ts` or drizzle-kit won't see it.**

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

**Why each non-obvious column exists:**

- **`language`** — the public site ships i18n in **six** languages (en/bn/ar/ja/zh/fr), and these
  are public SEO pages. Publishing English-only onto a six-language site is a product decision
  with a schema consequence: retrofitting a language dimension after pages are indexed means
  breaking URLs. `DEFAULT 'en'` costs nothing now and makes `UNIQUE (slug, language)` the
  natural key. **Confirm the intent** — Part H, decision 1.
- **`title`** — the root of `content` also carries a title; this column is the admin-list and
  activity-view sort key, so those screens never open the JSONB.
- **`content_schema_version`** — see §B0. A prompt revision that adds a required field otherwise
  silently half-renders every previously published page.
- **`created_by_email`** denormalized, matching `payment_transactions.user_email`: the Publishing
  Activity view shows an author for every row forever. `created_by` uses `ON DELETE RESTRICT` so
  an admin with published content can't be hard-deleted — deactivate instead (D1).
- **`updated_by` + `updated_at`** are what the console's "last edited at / by" column reads.
  With no `ON UPDATE` trigger (§0.6), the repository **must** set both on every write.
- **`'unpublished'` as a fourth status** — `rbac-and-security.md` gives `super_admin` unpublish
  rights; without a distinct value an unpublished page is indistinguishable from a draft and
  `published_at` gets clobbered. Keep `published_at` populated when unpublishing.
- **`hero_image_alt`** — the console's publish gate (its 2.6) blocks on hero image *and alt*.
  Without the column the gate has nothing to check.
- **GIN on `theme_tags`** — the console filters by tag; a btree can't serve `&&` on an array.
- **`library_itineraries_browse_idx`** — the public library browse/filter surface
  (country → city → duration) is the first thing built on top of these pages.
- **The partial index on `(publish_at) WHERE status='scheduled'`** is what the scheduled→published
  transition polls. **Nothing flips it automatically — decide the owner** (Part H, decision 2).

**Slug rules:** unique per language. Publishing freezes the slug (see C5). Draft/scheduled rows
are never returned publicly — application logic, filtered in the public use-case, with the e2e
test listed in `testing.md`.

## C2. `affiliate_partners`

**Create before C3.**

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

- `category` CHECK-constrained to the **Phase 1 baseline three**. Phase 3 adds flights /
  insurance / eSIM / gear / transfers / cards — an `ALTER … DROP CONSTRAINT … ADD CONSTRAINT`,
  which is exactly why this is a CHECK and not a pg enum.
- `commission_note` is **free text, not a calculated field.** Commissions are tracked manually in
  Phase 1. Don't add `commission_rate NUMERIC` "while you're there" — it implies a calculation
  nothing performs.
- `expiry_date` is `DATE` (matching `custom_trip_requests.follow_up_date`). **Expiry never
  auto-disables anything** — the console renders a 30-day warning and a past-due state; the alert
  is the action item. The list endpoint must return it (console 4.1/4.3 are blocked on it).
- `is_active = false` is the deactivate path. **Never hard-delete a partner** with rows in C3 —
  that click history is revenue evidence.

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

- `ON DELETE RESTRICT` on the partner FK is deliberate: deactivation is the supported operation;
  deleting a partner live on a published page must fail loudly.
- `day_number` lets the console attach a partner to a specific day rather than only the page.
  `NULL` = page-level. No FK is possible (days live inside JSONB) — **validate
  `day_number <= library_itineraries.duration_days` in the use-case.**
- `click_count` is a **denormalized counter**, following the `destinations.click_count` precedent.
  Increment in the redirect route with atomic SQL (`SET click_count = click_count + 1`), never a
  read-modify-write in JS.
- **Known asymmetry, accepted:** page views get a full event table with time buckets; affiliate
  clicks get only a lifetime counter. The activity view can show views today/7d/all-time but only
  clicks all-time. If per-period click trends are needed later, add a `library_affiliate_clicks`
  event table then — don't build it now.
- **Rendering always goes through the tracked redirect route.** A raw `<a href>` silently breaks
  tracking and nothing in the schema can catch it — it's a frontend review item.

## C4. `library_page_views`

Named `library_page_views`, **not** `page_views` — a bare name in a codebase that already has
`destination_clicks` invites someone to shove destination traffic in here too.

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

- Column shape copied from `destination_clicks`; PK is `BIGSERIAL` because this will be the
  highest-insert table in the database (§0.2).
- **`is_bot` is stamped at write time**, by user-agent matching in the record-view use-case, and
  the index excludes bots. Without it, "page views" on a public SEO page means "crawler hits" and
  the Publishing Activity numbers are decorative. Filtering at read time instead means scanning
  the bot rows forever.
- **Aggregate today / 7d / all-time at query time.** Do **not** build a rollup table yet. The
  concrete tripwire: when this table passes ~5M rows *or* the activity view exceeds ~200 ms, add
  a `library_page_view_daily (library_itinerary_id, day DATE, views INTEGER)` rollup and keep raw
  rows for 90 days. Write that threshold into `PROGRESS.md` rather than rediscovering it.
- **`ON DELETE CASCADE`** means deleting a library page destroys its traffic history. Combined
  with the `unpublished` status, the intended lifecycle is *unpublish*, never delete.

## C5. `library_itinerary_slugs` — SEO redirect history

A content system whose slugs can change silently 404s its own indexed URLs. Two protections,
both cheap:

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

1. **Freeze the slug once `status` has ever been `published`** (application rule — the console
   disables the field, the use-case rejects the change).
2. If a slug *must* change, write the old one here and have `GET /library/:slug` fall back to
   this table and answer **301** to the current slug.

The `UNIQUE (slug, language)` here must be checked alongside `library_itineraries`' own unique
constraint when validating a new slug, or a new page can steal a retired URL.

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

**Deliberate departures from the earlier scaffold draft — each is a correctness fix:**

- **`actor_admin_id` is nullable with `ON DELETE SET NULL`.** The earlier `NOT NULL REFERENCES`
  version made it impossible to ever delete an admin who had done anything, and tied the trail's
  survival to the actor's. An audit log deletable by deleting its actor is not an audit log.
  `actor_email` (NOT NULL, denormalized) keeps every row attributable forever.
- **`target_id` is `TEXT`, not `UUID`.** Targets include `users.id` (**integer**),
  `admin_users.id` (uuid) and `library_itineraries.id` (uuid). A uuid column cannot hold a user
  id — the earlier design would have failed on the first `user.suspend` write.
- **`changed_fields` + a payload size rule.** `before`/`after` must **never** contain
  `library_itineraries.content` — one itinerary edit would write ~100 KB of JSON per audit row
  and this table would outgrow the itineraries themselves. Store the changed field *names* in
  `changed_fields`, and put only scalar/small values in `before`/`after`. For content edits,
  `changed_fields = {'content'}` and both payloads `NULL` is correct and sufficient.
- **`ip_address` / `user_agent`** — the audit viewer's most common real question is "from where",
  and `admin_login_attempts` already captures both, so the console has one consistent story.
- **`audit_logs_target_idx`** powers "everything that ever happened to this user", which is what
  the viewer is actually used for.

**Write-before-commit:** every mutating admin route writes its audit row **before** committing
the change, in the same transaction. If the audit write fails, the request fails closed.

## C7. `ai_models` — spec in `docs/ai-model-assignment-plan.md`

Build-order 4.1 says implement that plan **exactly as written**. This section exists so the table
isn't invisible from the schema doc.

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

Seed `gpt-4o` (current custom default) and `gpt-4o-mini` (current destination default). Only
catalog models supporting `response_format: json_object`. Paired user columns in D4. Per the
plan, prefer **app-level validation** against this catalog over a hard FK so catalog rows can be
soft-deleted — consistent with the existing nullable-override style.

**PK deviation noted:** the plan doc specifies `SERIAL`, unlike the other new tables. `model_id`
is the natural key anyway. Follow the plan doc — it's authoritative for this feature.

---

# PART D — Alterations to existing tables

## D1. `admin_users` — role, deactivation, forced logout (Foundation 1.2)

The role column alone does not make RBAC work. Three columns ship together:

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

- **Run the backfill in the same migration as the column add, before the CHECK.** Every existing
  admin is effectively a super admin today; defaulting them to `content_admin` and shipping
  enforcement locks the whole team out of `/admin/users` on deploy day. The default stays
  `content_admin` so *newly created* admins are least-privileged.
- **`is_active` is required, not optional.** `library_itineraries.created_by` is
  `ON DELETE RESTRICT`, so an admin who has published anything **cannot be deleted**.
  Deactivation is therefore the only offboarding path, and without this column there isn't one.
  `AdminAuthGuard` must check `is_active` on every request, alongside the role.
- **`token_version` mirrors `users.token_version`** — the existing forced-logout pattern. A
  24-hour admin JWT with no revocation means a deactivated admin keeps working for up to a day.
  Bumping this on deactivate/role-change invalidates their session immediately. Include it in the
  token payload and compare against the DB row in `GET /admin/me`.
- **`role_assigned_by` / `role_assigned_at`** answer "who made this person a super admin" without
  a full-table audit-log scan.

**The role is never trusted from the token.** `GET /admin/me` re-reads `role`, `is_active` and
`token_version` from the row on every call, so a revoked role dies on the next request.

## D2. `users` and `user_itineraries` — guest flow, suspend, coordinates

### D2a. Guest itinerary sharing — **this had no schema anywhere**

Build-order 2.3 and frontend 4.3 both require "an unguessable token, resolvable with no auth."
Nothing supported it.

```sql
ALTER TABLE user_itineraries
  ADD COLUMN share_token            TEXT,
  ADD COLUMN share_token_created_at TIMESTAMPTZ,
  ADD COLUMN share_revoked_at       TIMESTAMPTZ;

CREATE UNIQUE INDEX user_itineraries_share_token_idx
  ON user_itineraries (share_token) WHERE share_token IS NOT NULL;
```

- **Nullable + partial unique index** — the same "unique when present" pattern as
  `users_phone_unique_not_empty`. Only shared itineraries get a token.
- Generate with `crypto.randomBytes(24).toString('base64url')` — **never** the row's `id`, never
  sequential. Unguessability is the entire requirement.
- `share_revoked_at` gives a revoke path without destroying the itinerary. The public resolver
  requires `share_token = $1 AND share_revoked_at IS NULL`.
- **Expiry is an open decision** — Part H, decision 3.

### D2b. Guest → registered conversion (§0.9)

```sql
ALTER TABLE users
  ADD COLUMN converted_at TIMESTAMPTZ;

CREATE INDEX users_is_guest_idx ON users (is_guest, created_at) WHERE is_guest;
```

- `converted_at` marks a row that started as a guest and became a real account — needed for the
  signup-conversion metric the console's dashboard aggregates want, and for reasoning about the
  free-tier counter afterwards.
- `users_is_guest_idx` supports both the abandoned-guest cleanup job and admin list filtering.
  Without it, both sequential-scan the whole users table.

**The conversion itself is a single transaction, and it must be written and tested as one:**

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

**Both `user_itinerary_usage.email` and `subscription_status.email` are `UNIQUE`** — if a row
already exists for the real email (returning user), the update raises a unique violation.
Handle it explicitly: merge the counters (take the higher count and the later `reset_date`) and
delete the guest row, inside the same transaction. **Test this case**; it's the one that will
appear in production first.

**Abandoned guests need a retention policy.** A guest row with no itineraries and no activity for
N days should be deleted by a scheduled job. Decide N (Part H, decision 4) — without it this
table grows forever with junk rows that also inflate every user-count metric on the dashboard.

### D2c. User suspend/reinstate — **no schema exists (blocks console 6.1)**

`users` has soft-delete columns but **no suspend/status column**. The console's own build order
already warns its suspend/reinstate screen may have no backend; confirmed — it has no column
either.

```sql
ALTER TABLE users
  ADD COLUMN suspended_at     TIMESTAMP,
  ADD COLUMN suspended_reason TEXT,
  ADD COLUMN suspended_by     UUID REFERENCES admin_users(id) ON DELETE SET NULL;
```

Bare `timestamp` here matches the rest of `users` (§0.3 — match the neighbourhood). Suspension is
distinct from soft deletion: suspended users still exist, can't authenticate, and can be
reinstated. Auth must check `suspended_at IS NULL` alongside `deleted_at IS NULL`, and bumping
`users.token_version` on suspend kills live sessions immediately. Every suspend writes
`audit_logs` with `action = 'user.suspend'`.

### D2d. Missing indexes on `user_itineraries`

```sql
CREATE INDEX user_itineraries_user_id_idx    ON user_itineraries (user_id);
CREATE INDEX user_itineraries_email_idx      ON user_itineraries (email);
CREATE INDEX user_itineraries_created_at_idx ON user_itineraries (created_at DESC);
```

Ship with whichever Phase 1 feature touches the table first — the admin itineraries list and "my
itineraries" both sequential-scan today, and the guest-conversion transaction above updates by
`user_id`.

### D2e. Per-stop coordinates — both paths, one feature (3.7)

**No column change** — coordinates live inside the existing JSONB. The change is to the shape
(§B1a), and it must land in **two places in one feature**:

1. **Generation path** — the prompt/schema in `generate-custom-itinerary-prompt.ts`, so
   `itinerary_content.dailyPlans[]` / `dailyItinerary[]` carry coordinates.
2. **Library path** — `library_itineraries.content` validation, so hand-authored pages carry the
   same fields.

Add as an index-aligned parallel array, consistent with how the day object already handles
optional per-line data:

```jsonc
"activityCoordinates": [
  null,
  { "lat": 3.15785000, "lng": 101.71145000 },
  { "lat": 3.15200000, "lng": 101.70300000 },
  null, null
]
```

Same length as `activityLines`; `null` for lines with no physical stop (flights, generic
evenings) — the same convention `activityAttractionNumbers` already uses. Match
`cities.latitude`/`longitude` precision (`numeric(10,8)` / `numeric(11,8)`). Bump
`content_schema_version` to `2` when this ships.

**Doing one path without the other fails the task's definition of done** — frontend 4.1 (map) and
console 2.3 (coordinates field) each consume a different half.

## D3. `payment_transactions` — extend, don't replace (5.2)

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

- **One ledger, one admin view.** No parallel SSLCommerz table.
- `DEFAULT 'stripe'` correctly backfills every existing row.
- **The partial unique index on `sslcommerz_val_id` is the IPN replay guard.** SSLCommerz can
  POST the same IPN more than once; the database refusing a duplicate `val_id` is stronger than
  an application-level "have I seen this". It does **not** replace the mandatory Transaction
  Validation API call — validate first, then insert (`payments.md`).
- `sslcommerz_bank_tran_id` is what their support asks for during reconciliation. Cheap now,
  painful to backfill.
- Store BDT in **poisha** with `currency = 'bdt'` (A7).

## D4. `users` — AI model overrides (4.1)

```sql
ALTER TABLE users
  ADD COLUMN ai_model_custom      TEXT,
  ADD COLUMN ai_model_destination TEXT;
```

Nullable, **NULL = env default** (`OPENAI_MODEL_CUSTOM` / `OPENAI_MODEL_DESTINATION`) — identical
in spirit to `free_itinerary_monthly_limit`. Validate against `ai_models` at the application
layer, not with an FK, so catalog rows can be soft-deleted. A set-but-disabled or unknown model
must **reject with 400**, never silently fall back — that's in `testing.md`'s required cases.

## D5. Rate limiting storage (2.2)

`/itinerary/generate` has **no rate limiter** and is about to become publicly callable. Redis
exists but **only as a BullMQ backend** — not caching, sessions, or limiting.

Note that with guests, **the rate limiter is also the free-tier enforcement mechanism** — §0.9
shows the per-email counter is bypassable by re-guesting, so IP/token-based limiting is what
actually bounds abuse.

- **If Redis:** no schema change. Record in `PROGRESS.md` that Redis now has a second,
  non-BullMQ responsibility, so nobody later assumes "Redis = queues only".
- **If Postgres:** model on `admin_login_attempts` — **with the index that table lacks**:

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

Either way it needs a cleanup story (Redis TTL, or a delete-older-than job). **Choose explicitly
in task 2.2** — don't drift into Redis just because it's there.

---

# PART E — Known schema defects (logged, not Phase 1 scope)

Visible here so nobody "fixes" one mid-feature against `CLAUDE.md`'s don't-fix-while-you're-in-there
rule. Promote to real tasks deliberately.

1. **No FK indexes in the admin/itinerary/payment domain** — `destination_clicks.destination_id`,
   `itineraries.destination_id`, `admin_login_attempts.ip_address` remain unindexed after Phase 1
   (D2d and D3 fix the ones Phase 1 touches).
2. **`$type<number>()` on nullable FK columns** — `payment_transactions.userId`,
   `subscription_status.userId`, `user_itinerary_usage.userId`. One-line fix each, but it surfaces
   real null checks at call sites, so it deserves its own change.
3. **Email as identity key across five tables** (§0.8). The proper fix is user-id-keyed
   subscription/usage with email as a plain attribute. Touches three modules — not Phase 1.
4. **`itinerary_generation_requests.itinerary_id` is `text` with no FK** to `user_itineraries.id`
   (`uuid`). Referential integrity is convention-only. Data migration, not a schema tweak.
5. **Timestamp inconsistency** — `users`, `otps`, location tables and `app_settings` use bare
   `timestamp`. Converting carries a timezone-interpretation decision.
6. **`otps` rows are never purged.** No TTL, no cleanup job.
7. **`app_settings` has no `created_at`** and no `$inferInsert` export.
8. **`relations.ts` is an empty object** — every join is hand-written (§0.5).
9. **`admin_users.totp_secret` / `totp_enabled` exist** with no confirmation any code path
   verifies TOTP. Verify before anyone claims 2FA is live.
10. **`custom_trip_requests` has no `assigned_admin_id`** — no per-admin queue possible.
11. **Three tables named after itineraries** — `itineraries` (destination cache),
    `user_itineraries`, `library_itineraries`. Renaming `itineraries` →
    `destination_itinerary_cache` would remove a permanent source of confusion; it's a rename plus
    every reference, so it needs its own change.
12. **`destination_clicks` has a UUID PK on an append-only event table** (§0.2). Left alone; don't
    copy the pattern.

---

# PART F — Phase 1 migration order

Each numbered item is one generated migration. The chain matches `build-order-complete.md`;
violating it produces a migration that fails on a missing table.

| # | Migration | Adds | Depends on |
|---|---|---|---|
| 1 | `admin_users_rbac` | D1: `role` + `is_active` + `token_version` + `role_assigned_*`, backfill, CHECK, index | — |
| 2 | `audit_logs` | C6 | 1 |
| 3 | `payment_transactions_multi_gateway` | D3 | — (parallel) |
| 4 | `users_guest_conversion_and_suspend` | D2b + D2c | 1 (for `suspended_by` FK) |
| 5 | `user_itineraries_share_token` | D2a + D2d indexes | — |
| 6 | `affiliate_partners` | C2 | 2 |
| 7 | `library_itineraries` | C1 | 2, 6 |
| 8 | `library_links_views_slugs` | C3 + C4 + C5 | 6, 7 |
| 9 | `ai_models_and_user_overrides` | C7 + D4 | 2 |
| 10 | `generation_rate_limit` *(only if Postgres)* | D5 | — |

D2e (per-stop coordinates) has **no migration** — it's a JSONB shape + validation change, plus
bumping `content_schema_version` to 2.

**Every migration:** `npm run db:generate` → read the emitted SQL → confirm FK column types match
§0.1 → `npm run db:migrate`. **If the generated SQL contains a `uuid` FK pointing at `users.id`,
stop** — something is wrong.

---

# PART G — Seed data required for Phase 1

| Table | Rows | When |
|---|---|---|
| `admin_users.role` | backfill all existing rows → `super_admin` | migration 1, before the CHECK |
| `app_settings` | `library_goal_count` (e.g. `"250"`) | before the goal counter ships (3.5) |
| `app_settings` | `payment_gateway_stripe_enabled` = `"true"`, `payment_gateway_sslcommerz_enabled` = `"false"` | before 5.3 |
| `ai_models` | `gpt-4o` (custom default), `gpt-4o-mini` (destination default) | migration 9 — resolution fails closed without them |
| `affiliate_partners` | none | admins create via the console |

Seeders live in `src/infra/db/seeders/`, registered in `seeders/index.ts` — follow the existing
pattern (`seed-countries.ts`, `seed-destination-itineraries.ts`) rather than embedding `INSERT`s
in a migration, **except** the `admin_users.role` backfill, which must be atomic with its
migration.

---

# PART H — Open decisions that change table shapes

Each of these is cheap now and expensive after data exists. Resolve before the listed migration.

1. **Are library pages multilingual?** The public site ships six languages and these are public
   SEO pages. `language` + `UNIQUE (slug, language)` is in C1 as a default-`'en'` column, which
   costs nothing and leaves the door open. If the answer is a firm "English only, forever",
   remove the column before migration 7 — but retrofitting it after pages are indexed means
   breaking live URLs. **Recommendation: keep it.** *Decide before: migration 7.*

2. **Who flips `scheduled` → `published`?** Nothing does automatically. A BullMQ repeatable job
   (Redis + BullMQ are already wired for mail) polls `library_itineraries_due_idx`; the
   alternative is a lazy check inside `GET /library/:slug`, which means a page stays invisible
   until someone happens to request it. **Recommendation: repeatable job.** *Decide in: task 3.2.*

3. **Do guest itineraries and share links expire?** D2a supports either. If yes, add an
   `expires_at` alongside `share_token`. If no, write "no expiry, deliberate" into `PROGRESS.md`
   so it isn't rediscovered as a bug. *Decide in: task 2.3.*

4. **What is the abandoned-guest retention window?** Every guest login creates a permanent
   `users` row (§0.9). Without a cleanup job the table grows unbounded and every dashboard
   user-count is wrong. **Recommendation: delete guest rows with no itineraries after 30 days;
   keep guests who generated something until their share link expires.** *Decide in: task 2.1.*

5. **Does `custom_trip_requests` need `assigned_admin_id`?** Without it, `support_admin` role
   gating gives every support admin the same undifferentiated queue. Fine for a small team;
   add the column when there's more than one. *Decide before: Phase 4.*

6. **Redis or Postgres for rate limiting** (D5) — and note that this is also the real free-tier
   enforcement for guests. *Decide in: task 2.2.*

---

# PART I — Growth and retention

| Table | Growth driver | Policy |
|---|---|---|
| `library_page_views` | every public page view | raw rows kept; add daily rollup + 90-day raw retention at ~5M rows or >200 ms activity queries |
| `audit_logs` | every mutating admin action | low volume; **never** store `content` blobs in `before`/`after` (C6) |
| `users` (guests) | every guest login | cleanup job per Part H decision 4 |
| `otps` | every verification email | no purge today (Part E) |
| `generation_rate_limit_attempts` | every generation attempt | delete-older-than job, or use Redis TTL |
| `itineraries` (destination cache) | every cache miss | has `expires_at`; confirm something actually deletes expired rows |
| `admin_login_attempts` | every admin login | low volume, no purge — acceptable |

The two tables that will actually get big are `library_page_views` and, if Postgres is chosen for
limiting, `generation_rate_limit_attempts`. Both are `BIGSERIAL` append-only by design (§0.2), and
both need a retention job before they become a problem rather than after.
