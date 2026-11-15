# Content Library ও Publishing System

**সম্পূর্ণ architecture Phase 1-এই ship হবে** — নির্দেশনা অনুযায়ী, এটি Phase 3 পর্যন্ত পিছিয়ে দেওয়া হচ্ছে না। Content
Admin-রা ধীরে ধীরে নতুন ফ্রি itinerary page publish করেন, একটি configurable goal count-এর দিকে এগিয়ে
(কোনো নির্দিষ্ট সংখ্যা নয় — `app_settings` key `library_goal_count` থেকে read/write করুন)।

Table-গুলো: `library_itineraries`, `affiliate_partners`, `library_itinerary_affiliate_links`,
`library_page_views`, `library_itinerary_slugs`। সম্পূর্ণ DDL, index এবং যুক্তি →
`database-schema.md` Part C।

## 🚨 Content shape contract — editor লেখার আগে এটি পড়ুন

`library_itineraries.content` অবশ্যই **`user_itineraries.itinerary_content`**-এর সাথে মিলতে হবে — সম্পূর্ণ
itinerary-র **root object**।

এই doc-এর একটি আগের সংস্করণে বলা ছিল "`user_itineraries.dailyItinerary`-এর সাথে মিলান।" **সেটা
ভুল ছিল।** `daily_itinerary` কেবল দিনগুলোর array; `itinerary_content` হলো সেই root object যা একটি
rendered page আসলে ব্যবহার করে — এর মধ্যে আছে `overview`, `attractions`, `keyPhrases`, `costBreakdown`,
`costBreakdownDetailed`, `visaInfo`, `tripSummary`, এবং `dailyPlans`। পুরোনো spec অনুযায়ী বানানো একটি library page
কোনো overview, কোনো attractions এবং কোনো cost ছাড়াই render হতো — একটি generated page থেকে কাঠামোগতভাবে
*ভিন্ন*, অথচ এই feature-টি ঠিক এর বিপরীত প্রতিশ্রুতি দেয়।

সম্পূর্ণ key তালিকা ও invariant → `database-schema.md` §B1।

**Validator একবারই define করুন।** একটি shared Zod schema, যা generation path এবং
content-library module দুটোই import করবে। হাতে maintain করা দুটি কপি এক sprint-এর মধ্যেই আলাদা হয়ে যায়।
`library_itineraries.content_schema_version` রেকর্ড করে একটি page কোন revision অনুযায়ী লেখা হয়েছিল,
যাতে পরে prompt পরিবর্তন হলে পুরোনো page আধা-render না হয়ে migrate করা যায়।

Validation-কে অবশ্যই সেই **child-pricing key-গুলোও reject করতে হবে** যেগুলো generation prompt
attractions-এ নিষিদ্ধ করে (§B1b) — নইলে হাতে লেখা page এমন একটি pricing block render করবে যা generated page কখনো
দেখায় না।

## Workflow

Draft → Scheduled → Published → (Unpublished)। Publish করা মানে database-এ status পরিবর্তন, কোনো deploy
লাগে না। Content Admin-রা কেবল নিজেদের item দেখেন (`created_by = current admin`); `super_admin`
সবকিছু দেখতে এবং edit/publish/unpublish করতে পারেন।

`'unpublished'` একটি আলাদা status, `draft`-এ ফিরে যাওয়া নয় — `published_at` ঐতিহাসিক রেকর্ড হিসেবে
পূর্ণ থাকে।

**একই editable কাঠামোতে ঢোকার দুটি পথ:**

- বিদ্যমান generation pipeline দিয়ে প্রথম draft generate করুন (
  `generate-custom-itinerary.use-case.ts` / `generate-destination-itinerary.use-case.ts`
  pattern পুনর্ব্যবহার করুন), তারপর হাতে edit করুন
- সম্পূর্ণ হাতে লিখুন

### ⚠️ কোনো কিছুই একটি scheduled page স্বয়ংক্রিয়ভাবে publish করে না — owner ঠিক করুন

`status = 'scheduled'` সাথে অতীতের একটি `publish_at` থাকলেও নিজে থেকে কিছুই হয় না। দুটি বিকল্প:

- **একটি BullMQ repeatable job** যা `library_itineraries_due_idx` poll করবে (Redis + BullMQ ইতিমধ্যেই
  mail queue-এর জন্য wired আছে) — **প্রস্তাবিত**
- `GET /library/:slug`-এর ভেতরে একটি lazy check, যার মানে একটি scheduled page ততক্ষণ অদৃশ্য থাকবে যতক্ষণ না
  কেউ ঘটনাক্রমে সেটি request করে

Task 3.2-এ একটি বেছে নিন এবং `PROGRESS.md`-এ রেকর্ড করুন। এটি `database-schema.md` Part H,
decision 2।

## Slug ও SEO

- `library_itineraries`-এ `UNIQUE (slug, language)`, সাথে একটি retired-slug table
  (`library_itinerary_slugs`) যা একই uniqueness validation-এ check করা হয়।
- **একটি page একবারও publish হলে slug freeze করুন।** Console field-টি disable করে; 
  use-case পরিবর্তনটি reject করে। যদি সত্যিই slug পরিবর্তন করতে হয়, পুরোনোটি
  `library_itinerary_slugs`-এ লিখুন এবং `GET /library/:slug`-কে একটি **301** দিয়ে সেখানে fallback করতে দিন — একটি
  index হওয়া URL-এ নীরব 404 একটি SEO-নির্ভর feature-এর জন্য সবচেয়ে খারাপ পরিণতি।
- `meta_title`, `meta_description`, `hero_image_url`, `hero_image_alt` হলো stored column। 
  Console-এর publish gate hero image **এবং alt** না থাকলে block করে, তাই দুটিই থাকতে হবে।

### ⚠️ Language একটি অমীমাংসিত সিদ্ধান্ত (Part H, decision 1)

Public site ছয়টি ভাষায় ship হয় (en/bn/ar/ja/zh/fr) এবং এগুলো public SEO page।
`library_itineraries.language`-এর default `'en'` এবং এটি natural key-এর অর্ধেক গঠন করে, তাই দরজাটি
শূন্য খরচে খোলা থাকে। **Migration 7-এর আগে উদ্দেশ্য নিশ্চিত করুন** — page index হয়ে যাওয়ার পরে
language dimension যোগ করা মানে live URL ভেঙে ফেলা।

লক্ষ্য করুন public site-এর i18n **client-side** (`LanguageContext`), route-based নয়, তাই আজ একটি
crawler যেকোনো page-এর কেবল English render-টাই দেখে। যদি multilingual library page চাওয়া হয়,
public site-এর localized route লাগবে — এটি frontend-এর কাজ যাতে কোনো backend বাধা নেই, তবে ধরে না নিয়ে
বিষয়টি উত্থাপন করুন।

## Affiliate linking (Phase 1 baseline category: hotel, restaurant, tour)

প্রতিটি section-এ — এবং ঐচ্ছিকভাবে প্রতিটি দিনে (`day_number`) — একজন Content Admin
`affiliate_partners` থেকে একটি partner যুক্ত করেন। Rendering **সবসময়** click-tracked redirect route দিয়ে যায়
(`GET /library/:slug/affiliate/:linkId`) — partner site-এ কখনোই সরাসরি raw `<a href>` নয়, নইলে
click/commission tracking নীরবে ভেঙে যায়। Schema-র কোনো কিছুই এটি ধরতে পারে না; এটি একটি frontend
review item।

- `click_count` atomic SQL দিয়ে বাড়ান (`SET click_count = click_count + 1`), JS-এ কখনোই
  read-modify-write নয়।
- `affiliate_partners.expiry_date` কেবল তথ্যমূলক — **expiry কখনোই স্বয়ংক্রিয়ভাবে link disable করে না।**
  Console একটি 30-দিনের সতর্কতা এবং একটি past-due অবস্থা দেখায়; alert-টাই করণীয়। List
  endpoint-কে অবশ্যই column-টি return করতে হবে (console task 4.1 ও 4.3 এর উপর blocked)।
- Click history আছে এমন partner-কে deactivate করুন (`is_active = false`), কখনোই hard-delete নয় — FK
  ইচ্ছাকৃতভাবেই `ON DELETE RESTRICT`।
- **জানা অসামঞ্জস্য:** page view-এর জন্য time bucket সহ পূর্ণ event table আছে; affiliate click-এর জন্য
  কেবল একটি lifetime counter। তাই activity view-তে view দেখায় today/7d/all-time কিন্তু click
  কেবল all-time। এটাই Phase 1-এর সিদ্ধান্ত — per-period trend দরকার হলে পরে একটি click event table যোগ করুন,
  এখন নয়।

## Super Admin তত্ত্বাবধান — Publishing Activity view

`GET /admin/content-library/activity`, কেবল `super_admin`। প্রতিটি page-এর জন্য: author
(`created_by_email`), status, published-at, **last-edited-at + last-edited-by** (`updated_at` /
`updated_by`), page view (`library_page_views` থেকে today/7d/all-time), affiliate click (
`click_count`-এর যোগফল)। Author, status, date range অনুযায়ী sort/filter করা যায়।

**দুটি জিনিস এই view-কে নীরবে ভেঙে দেয়:**

1. **`updated_at`-এর কোনো database trigger নেই** (`database-schema.md` §0.6)। Repository-কে অবশ্যই
   প্রতিটি write-এ `updatedAt` *এবং* `updatedBy` set করতে হবে, নইলে "last edited" চিরকাল creation time
   দেখাবে।
2. **Bot traffic।** `library_page_views.is_bot` write time-এ record-view use-case-এর ভেতরে
   user-agent matching দিয়ে stamp করা হয়, এবং read index bot বাদ দেয়। এটি ছাড়া, একটি
   public SEO page-এ "page views" মানে "crawler hits" এবং সংখ্যাগুলো কেবল সাজসজ্জা।

Query time-এ aggregate করুন। এই table ~5M row পার না হওয়া পর্যন্ত বা activity query ~200 ms ছাড়িয়ে না যাওয়া পর্যন্ত
কোনো rollup table **বানাবেন না** — তখন একটি daily rollup এবং 90-দিনের raw retention যোগ করুন।

## Goal counter

`published count / app_settings['library_goal_count']`, মূল Library admin screen-এ দেখানো হয়,
সাথে একটি সংক্ষিপ্ত recent-activity feed (শেষ N টি published, কে করেছেন, কখন)। কেবল
`super_admin` edit করতে পারেন — কখনোই hardcode করবেন না। `app_settings.value` হলো `text`, তাই
application boundary-তে parse ও validate করুন; database আনন্দের সাথেই `"abc"` store করবে।

## Definition of done

- [ ] Content Admin কোনো deploy ছাড়াই create/edit/schedule/publish করতে পারেন
- [ ] `content` validate হয় `user_itineraries.itinerary_content`-এর মতো একই shared schema-র বিপরীতে,
      নিষিদ্ধ-key নিয়মসহ
- [ ] কোনো কিছু সত্যিই `scheduled` → `published` পরিবর্তন করে, এবং সেটি লিখে রাখা আছে
- [ ] Affiliate link প্রতি section-এ যুক্ত হয় এবং redirect route দিয়ে click-tracked হয়
- [ ] Published page একটি clean, server-rendered, indexable URL-এ সঠিক meta tag সহ resolve হয়
- [ ] প্রথম publish-এর পরে slug freeze থাকে; পরিবর্তন হলে পুরোনো URL 301 করে
- [ ] Publishing Activity view সঠিক (`updated_by`/`updated_at` সত্যিই লেখা হয়, bot
      বাদ দেওয়া হয়) এবং কেবল `super_admin`-এর জন্য
- [ ] Goal counter `app_settings` থেকে read/write করে, hardcoded সংখ্যা নয়
- [ ] Draft/scheduled/unpublished page কখনোই publicly routable বা index হয় না

## Phase 1-এর স্পষ্টভাবে scope-এর বাইরে

উন্নত destination *narrative* page (history/culture/safety/customs — একটি নির্দিষ্ট trip-এর itinerary থেকে
ভিন্ন একটি content type) Phase 3-এ থাকবে। hotel/restaurant/tour-এর বাইরে বর্ধিত affiliate category
(flights, insurance, eSIM, gear, transfers, cards) Phase 3-এ থাকবে — `category`-এর উপর
`CHECK` এমনভাবে লেখা যাতে সেটি এক লাইনের `ALTER` হয়।
