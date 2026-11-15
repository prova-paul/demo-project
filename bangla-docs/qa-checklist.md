# Phase 1 QA Gate

Deployment promotion-এর জন্য `main` মানুষের হাতে তুলে দেওয়ার আগে `/qa-gate` দিয়ে চালান।

## 🔴 Launch blocker

- [ ] Admin session token signed (JWT), পুরোনো base64-decode verification path সম্পূর্ণ সরানো হয়েছে
- [ ] Session একটি httpOnly cookie হিসেবে দেওয়া হয়; `sessionStorage` আর এটি রাখে না, এবং
      `AdminAuthGuard` থেকে `Authorization: Bearer` গ্রহণের path সরানো হয়েছে
- [ ] Admin login **একটি আসল browser-এ `console.trytriplyai.com` থেকে** কাজ করে — কেবল curl-এ নয়।
      নিশ্চিত করুন cookie set হয়, পরবর্তী request-এ পাঠানো হয়, এবং CORS `credentials: true` সহ স্পষ্ট
      origin return করে (একটি `*` origin নীরবে credentialed request ভেঙে দেয়)
- [ ] প্রতিটি `/admin/*` route guard-এর মাধ্যমে role enforce করে, কেবল authentication নয়
- [ ] একজন admin-কে deactivate করলে (`is_active = false`) **তার live session সাথে সাথে শেষ হয়** —
      পরবর্তী token expiry-তে নয়। `token_version` bump করুন, তারপর নিশ্চিত করুন তার পরবর্তী request 401 হয়
- [ ] SSLCommerz IPN handler কোনো record update করার আগে Transaction Validation API call করে
- [ ] একটি **replay করা** SSLCommerz IPN (একই `val_id` দুবার) দ্বিতীয় কোনো transaction তৈরি করে না
- [ ] `/itinerary/generate` সম্পূর্ণ unauthenticated request-এর জন্য কাজ করে (guest fix) এবং এতে একটি
      rate limiter আছে (আজ এতে কোনোটি নেই, এবং এটি public হতে চলেছে)
- [ ] **Guest free-tier bypass বন্ধ:** guest হিসেবে limit শেষ করুন, log out করুন, আবার guest হোন —
      limit তখনও প্রযোজ্য থাকতে হবে। এটি আজ ভাঙা (`database-schema.md` §0.9)
- [ ] **Guest → signup একটিই account রাখে:** guest হিসেবে generate করুন, একটি আসল email দিয়ে sign up করুন,
      নিশ্চিত করুন একটি `users` row (দুটি নয়), itinerary-গুলো এখনও resolve হয়, এবং usage counter
      স্থানান্তরিত হয়েছে। এমন একটি email দিয়ে পুনরাবৃত্তি করুন যার ইতিমধ্যে একটি usage row আছে (unique-violation
      merge path)
- [ ] Draft/scheduled/unpublished Content Library item publicly reachable বা index হয় না
- [ ] PDF export Free tier-এ watermarked, Premium-এ watermarked নয় — server-side check,
      কখনোই client flag বিশ্বাস করবেন না

## ইতিমধ্যে তৈরি — যাচাই করুন, পুনরায় তৈরি করবেন না

- [ ] Passport nationality + home currency field — যেকোনো generation
      pipeline পরিবর্তনের পরে এখনও কাজ করছে নিশ্চিত করুন (এগুলো `user_itineraries` এবং OpenAI prompt port-এ গভীরভাবে wired)
- [ ] i18n (6টি ভাষা) — public-site-এর বিষয়, তবে নিশ্চিত করুন কোনো Phase 1 backend response
      user-facing English copy hardcode করে না যা frontend পরে অনুবাদ করতে পারে না (সরাসরি end user-কে
      দেখানো error message সাধারণত দোষী)। Admin-console response
      ব্যতিক্রম — ওই console নকশাগতভাবেই কেবল English।
- [ ] Free-tier monthly limit (`FREE_TIER_MONTHLY_LIMIT`, per-user override) — নিশ্চিত করুন guest
      generation এটিকে নীরবে bypass করে না বা দুবার গণনা করে না, এমন user-এর জন্য যিনি
      session-এর মাঝখানে sign up করেন
- [ ] `custom_trip_requests` status pipeline — নিশ্চিত করুন উপরে RBAC layer তৈরি করার সময় Phase 1-এর কোনো কিছু
      এর বিদ্যমান admin ব্যবহার ভাঙে না

## সাধারণ

- [ ] `tsc` clean, `jest` green, `jest --config test/jest-e2e.json` green
- [ ] কোনো secret commit করা হয়নি (`.env` gitignored কিনা check করুন, কোনো hardcoded key নেই)
- [ ] `PROGRESS.md` বাস্তবতা প্রতিফলিত করে — 3টি এলোমেলো ticked item আসল code-এর সাথে spot-check করুন
