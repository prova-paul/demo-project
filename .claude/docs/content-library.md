# Content Library & Publishing System

**Full architecture ships in Phase 1** — per direction, this is not deferred to Phase 3. Content
Admins publish new free itinerary pages gradually, growing toward a configurable goal count
(not a fixed number — read/write via `app_settings` key `library_goal_count`).

Tables: `library_itineraries`, `affiliate_partners`, `library_itinerary_affiliate_links`,
`library_page_views`, `library_itinerary_slugs`. Full DDL, indexes and rationale →
`database-schema.md` Part C.

## 🚨 The content shape contract — read this before writing the editor

`library_itineraries.content` must match **`user_itineraries.itinerary_content`** — the full
itinerary **root object**.

An earlier version of this doc said "match `user_itineraries.dailyItinerary`." **That was
wrong.** `daily_itinerary` is only the day array; `itinerary_content` is the root object a
rendered page actually consumes — `overview`, `attractions`, `keyPhrases`, `costBreakdown`,
`costBreakdownDetailed`, `visaInfo`, `tripSummary`, and `dailyPlans` among them. A library page
built to the old spec would render with no overview, no attractions and no costs — structurally
*different* from a generated one, which is the exact promise this feature makes.

Full key list and invariants → `database-schema.md` §B1.

**Define the validator once.** One shared Zod schema, imported by both the generation path and
the content-library module. Two hand-maintained copies drift within a sprint.
`library_itineraries.content_schema_version` records which revision a page was authored against,
so a later prompt change can migrate rather than half-render old pages.

Validation must also **reject the child-pricing keys** the generation prompt forbids on
attractions (§B1b) — otherwise hand-authored pages render a pricing block generated pages never
show.

## Workflow

Draft → Scheduled → Published → (Unpublished). Publishing is a database status change, no deploy
required. Content Admins see only their own items (`created_by = current admin`); `super_admin`
sees and can edit/publish/unpublish everything.

`'unpublished'` is a distinct status, not a return to `draft` — `published_at` stays populated as
the historical record.

**Two entry paths into the same editable structure:**

- Generate a first draft via the existing generation pipeline (reuse the
  `generate-custom-itinerary.use-case.ts` / `generate-destination-itinerary.use-case.ts`
  patterns), then hand-edit
- Write fully manually

### ⚠️ Nothing publishes a scheduled page automatically — decide the owner

`status = 'scheduled'` with a `publish_at` in the past does nothing on its own. Two options:

- **A BullMQ repeatable job** polling `library_itineraries_due_idx` (Redis + BullMQ are already
  wired for the mail queue) — **recommended**
- A lazy check inside `GET /library/:slug`, which means a scheduled page stays invisible until
  someone happens to request it

Pick one in task 3.2 and record it in `PROGRESS.md`. This is `database-schema.md` Part H,
decision 2.

## Slugs and SEO

- `UNIQUE (slug, language)` on `library_itineraries`, plus a retired-slug table
  (`library_itinerary_slugs`) checked in the same uniqueness validation.
- **Freeze the slug once a page has ever been published.** The console disables the field; the
  use-case rejects the change. If a slug genuinely must change, write the old one to
  `library_itinerary_slugs` and have `GET /library/:slug` fall back to it with a **301** — a
  silent 404 on an indexed URL is the worst outcome for an SEO-driven feature.
- `meta_title`, `meta_description`, `hero_image_url`, `hero_image_alt` are stored columns. The
  console's publish gate blocks on hero image **and alt**, so both must exist.

### ⚠️ Language is an open decision (Part H, decision 1)

The public site ships six languages (en/bn/ar/ja/zh/fr) and these are public SEO pages.
`library_itineraries.language` defaults to `'en'` and forms half of the natural key, so the door
stays open at zero cost. **Confirm intent before migration 7** — retrofitting a language
dimension after pages are indexed means breaking live URLs.

Note the public site's i18n is **client-side** (`LanguageContext`), not route-based, so today a
crawler only ever sees the English render of any page. If multilingual library pages are wanted,
the public site needs localized routes — frontend work with no backend blocker, but raise it
rather than assume it.

## Affiliate linking (Phase 1 baseline categories: hotel, restaurant, tour)

Per section — and optionally per day (`day_number`) — a Content Admin attaches a partner from
`affiliate_partners`. Rendering **always** goes through the click-tracked redirect route
(`GET /library/:slug/affiliate/:linkId`) — never a raw `<a href>` to the partner site, or
click/commission tracking silently breaks. Nothing in the schema can catch that; it's a frontend
review item.

- Increment `click_count` with atomic SQL (`SET click_count = click_count + 1`), never a
  read-modify-write in JS.
- `affiliate_partners.expiry_date` is informational — **expiry never auto-disables a link.** The
  console renders a 30-day warning and a past-due state; the alert is the action item. The list
  endpoint must return the column (console tasks 4.1 and 4.3 are blocked on it).
- Deactivate (`is_active = false`), never hard-delete a partner with click history — the FK is
  `ON DELETE RESTRICT` on purpose.
- **Known asymmetry:** page views get a full event table with time buckets; affiliate clicks get
  a lifetime counter only. So the activity view shows views today/7d/all-time but clicks
  all-time. That's the Phase 1 call — add a click event table later if per-period trends are
  needed, not now.

## Super Admin oversight — Publishing Activity view

`GET /admin/content-library/activity`, `super_admin` only. Per page: author
(`created_by_email`), status, published-at, **last-edited-at + last-edited-by** (`updated_at` /
`updated_by`), page views (today/7d/all-time from `library_page_views`), affiliate clicks (sum of
`click_count`). Sortable/filterable by author, status, date range.

**Two things silently break this view:**

1. **`updated_at` has no database trigger** (`database-schema.md` §0.6). The repository must set
   `updatedAt` *and* `updatedBy` on every write, or "last edited" reports the creation time
   forever.
2. **Bot traffic.** `library_page_views.is_bot` is stamped at write time by user-agent matching
   in the record-view use-case, and the read index excludes bots. Without it, "page views" on a
   public SEO page means "crawler hits" and the numbers are decorative.

Aggregate at query time. Do **not** build a rollup table until this table passes ~5M rows or the
activity query exceeds ~200 ms — then add a daily rollup and 90-day raw retention.

## Goal counter

`published count / app_settings['library_goal_count']`, shown on the main Library admin screen
alongside a short recent-activity feed (last N published, by whom, when). Editable by
`super_admin` only — never hardcode it. `app_settings.value` is `text`, so parse and validate at
the application boundary; the database will store `"abc"` happily.

## Definition of done

- [ ] Content Admin can create/edit/schedule/publish with no deploy
- [ ] `content` validates against the same shared schema as `user_itineraries.itinerary_content`,
      including the forbidden-key rules
- [ ] Something actually flips `scheduled` → `published`, and it's written down
- [ ] Affiliate links attach per section and are click-tracked through the redirect route
- [ ] Published pages resolve at a clean, server-rendered, indexable URL with correct meta tags
- [ ] A slug is frozen after first publish; if changed, the old URL 301s
- [ ] Publishing Activity view is accurate (`updated_by`/`updated_at` actually written, bots
      excluded) and `super_admin`-only
- [ ] Goal counter reads/writes `app_settings`, not a hardcoded number
- [ ] Draft/scheduled/unpublished pages are never publicly routable or indexed

## Explicitly out of scope for Phase 1

Enhanced destination *narrative* pages (history/culture/safety/customs — a different content type
from a specific trip's itinerary) stay in Phase 3. Expanded affiliate categories beyond
hotel/restaurant/tour (flights, insurance, eSIM, gear, transfers, cards) stay in Phase 3 — the
`CHECK` on `category` is written so that's a one-line `ALTER`.
