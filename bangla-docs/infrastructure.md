# Infrastructure

## Deployment (বাস্তবে নিশ্চিত, অনুমান নয়)

PM2 (`ecosystem.config.cjs`), app name `trytriplyai-b`, fork mode, single instance, port 30008,
`max_memory_restart: 2G`। `npm run build` (`nest build`) দিয়ে build করুন, `npm run start:prod`-এর মাধ্যমে
`node dist/src/main.js` দিয়ে start করুন। **আজ কোনো Docker নেই, কোনো CI/CD pipeline নেই।**
Deploy সম্ভবত হাতে করা হয় (VPS-এ `git pull` + `pm2 restart`) — এর চেয়ে স্বয়ংক্রিয় কিছু ধরে নেওয়ার আগে
আসল promotion process নিশ্চিত করুন।

## এই backend এখন দুটি frontend client-কে serve করে (পরিবর্তিত — repo split)

| Client | Domain | Repo | কীভাবে এই backend call করে |
|---|---|---|---|
| Public site | `trytriplyai.com` | `Journey-Planner-Frontend` | Server-side, নিজস্ব Next.js BFF route (`app/api/*`)-এর মাধ্যমে |
| Admin console | `console.trytriplyai.com` | `triply-console` | **সরাসরি browser থেকে** — কোনো BFF layer নেই |

এই backend নিজেই `developer.trytriplyai.com`। এর সামনে কোনো gateway বা shared proxy নেই।
দুটি client এতে ভিন্নভাবে পৌঁছায়, যা CORS-এর জন্য গুরুত্বপূর্ণ: public site-এর
call আসে একটি Next.js *server* থেকে (CORS প্রযোজ্য নয়), যেখানে admin console-এর call
আসে একটি ভিন্ন subdomain-এর *browser* থেকে (CORS পুরোপুরি প্রযোজ্য)। নিচে দেখুন।

Frontend চলে port 30002-এ (`next start -p 30002`), আলাদা PM2 process, আলাদা repo। 
Admin console-এর নিজস্ব port-এ নিজস্ব PM2 process লাগবে — পরবর্তী খালি port বেছে নিন এবং বিদ্যমান দুটির পাশাপাশি
`console.trytriplyai.com`-এর জন্য reverse-proxy vhost যোগ করুন।

## 🚨 CORS hardcoded, env-driven নয় — সংশোধিত, এটি ভুলভাবে document করা হয়েছিল

`.env.example`-এ `CORS_ORIGIN` আছে, এবং এই doc-এর একটি আগের সংস্করণে এটিকে live
control হিসেবে বর্ণনা করা হয়েছিল। **`src/`-এর কোথাও এটি কখনো পড়া হয় না** — grep শূন্য reference নিশ্চিত করে। আসল
allowlist হলো `src/core/config/cors.config.ts`-এ একটি literal array:

```ts
origin: [
  "http://127.0.0.1:3000", "http://localhost:3000",
  "http://127.0.0.1:30002", "http://localhost:30002",
  "https://journey.iplookup.xyz", "https://journey-api.iplookup.xyz",  // legacy, dead domains
  "https://trytriplyai.com", "https://developer.trytriplyai.com",
]
```

**ফলাফল: `console.trytriplyai.com` allow করা একটি code change সাথে redeploy, কোনো env
toggle নয়।** এটি `build-order-complete.md`-এ Foundation task 1.0 হিসেবে track করা হচ্ছে — কেউ admin console-এ
আদৌ login করতে পারার আগেই এটি land করতে হবে, তাই এটি পুরো RBAC chain-কে block করে।

ওই file edit করার সময়: দুটি মৃত `iplookup.xyz` origin ছেঁটে ফেলুন (আর ব্যবহার হয় না বলে নিশ্চিত),
এবং console-এর local dev origin-ও যোগ করুন, নইলে local admin development ভেঙে যাবে।
`credentials: true` রাখুন — admin session cookie এর উপর নির্ভর করে।

## Subdomain জুড়ে admin session cookie

Admin console হলো `console.trytriplyai.com`-এর একটি browser client যা
`developer.trytriplyai.com` call করে। Phase 1 Foundation-এ চালু হওয়া httpOnly session cookie
(দেখুন `rbac-and-security.md`) যাতে সেই hop টিকে থাকে:

- **Cookie set হয় API-র নিজস্ব response দিয়ে**, তাই
  `developer.trytriplyai.com`-এ scoped একটি host-only cookie ইতিমধ্যেই যথেষ্ট — browser পরবর্তী প্রতিটি call-এ সেটি একই
  host-এ ফেরত পাঠায়। `Domain=.trytriplyai.com` set করা ঐচ্ছিক; কেবল তখনই করুন যদি
  parent domain-এর অন্য কিছুর সত্যিই cookie পড়া প্রয়োজন হয়, কারণ বিস্তৃত scope মানে
  বিস্তৃত blast radius।
- **`SameSite=Lax` যথেষ্ট — `SameSite=None` ব্যবহার করবেন না।** `console.trytriplyai.com`
  এবং `developer.trytriplyai.com` একই registrable domain `trytriplyai.com` শেয়ার করে, তাই এগুলো
  ভিন্ন origin হওয়া সত্ত্বেও *same-site* request। `SameSite=None` অকারণে cookie-কে
  প্রকৃত third-party context-এ উন্মুক্ত করবে।
- **CORS-কে অবশ্যই একটি স্পষ্ট origin পাঠাতে হবে, কখনোই `*` নয়।** একটি wildcard origin
  `credentials: true`-এর সাথে অসামঞ্জস্যপূর্ণ — browser এই সমন্বয় সরাসরি reject করে।
- **Console-এর fetch call-গুলোকে অবশ্যই `credentials: 'include'` set করতে হবে**, নইলে browser নীরবে
  cookie বাদ দেয় এবং প্রতিটি admin request কোনো স্পষ্ট কারণ ছাড়াই 401 হয়। বাস্তবে এই setup ব্যর্থ হওয়ার
  এটাই একক সবচেয়ে সাধারণ উপায়।

## Environment variable (`.env.example` থেকে — Phase 1 নতুন যোগ করার সাথে সাথে sync রাখুন)

ইতিমধ্যে আছে: `DATABASE_URL`, `JWT_SECRET` (+ access/refresh expiry), `PORT`, `CORS_ORIGIN`
(**আছে কিন্তু মৃত — উপরে দেখুন, এটি কিছুই নিয়ন্ত্রণ করে না**), Firebase Admin config
(`FIREBASE_SERVICE_ACCOUNT_PATH` বা `FIREBASE_SERVICE_ACCOUNT_JSON`), `STRIPE_SECRET_KEY` /
`STRIPE_WEBHOOK_SECRET`, `FREE_TIER_MONTHLY_LIMIT`, `FRONTEND_URL`, SMTP config,
`GOOGLE_CLIENT_ID`/`SECRET`।

**Phase 1-এর সংযোজন:**
```bash
ADMIN_JWT_SECRET=                      # separate from JWT_SECRET — see rbac-and-security.md
ADMIN_CONSOLE_URL=https://console.trytriplyai.com   # for redirects/links back to the console
SSLCOMMERZ_STORE_ID=
SSLCOMMERZ_STORE_PASSWORD=
SSLCOMMERZ_IS_SANDBOX=true             # false in production
SSLCOMMERZ_IPN_LISTENER_URL=
```

লক্ষ্য করুন `FRONTEND_URL` এখন দ্ব্যর্থক — এটি split-এর আগের এবং এর মানে public site। Console link-এর জন্য
এটি পুনর্ব্যবহার করবেন না; সেজন্যই `ADMIN_CONSOLE_URL` আছে।

## Redis — আসলে এটি কীসের জন্য

কেবল BullMQ backend, দুটি queue: `backendv2-mail-queue` (async email), `backendv2-file-upload-queue`
(ঐচ্ছিক background upload)। **কোথাও ধরে নেবেন না যে Redis caching, session, বা rate
limiting সামলায় — এটি করে না।** যদি Phase 1-এ এখন-public
`/itinerary/generate` endpoint-এ একটি rate limiter লাগে (signup fix ship হলে guest-রা কোনো auth ছাড়াই এটি hit করতে পারবে),
সেটি যোগ করার মতো নতুন infrastructure, বিদ্যমান Redis ব্যবহারে অন্তর্নিহিতভাবে wire করার মতো কিছু নয়
— স্পষ্টভাবে সিদ্ধান্ত নিন এটি Redis (নতুন ব্যবহার) ব্যবহার করবে নাকি বিদ্যমান
`admin_login_attempts` pattern-এর সাথে মিল রেখে একটি Postgres-based পদ্ধতি।

## কোনো CI/CD নেই — `/ship-feature`-এর জন্য এর অর্থ কী

যেহেতু কোনো pipeline নেই, local-এ চলা `tsc` + `jest` (Stop hook-এর মাধ্যমে, দেখুন
`hooks/verify.sh`) হলো `main`-এ merge-এর আগে একমাত্র স্বয়ংক্রিয় gate। এটিকে
বাধ্যতামূলক হিসেবে গণ্য করুন — একটি red local build-ই এই মুহূর্তে বিদ্যমান একমাত্র safety net।

## Repo-র অপ্রয়োজনীয় জিনিস (split audit-এর সময় লক্ষ্য করা, কোনো পদক্ষেপ নেওয়া হয়নি)

Repo root-এ `triply-template/` এবং `truffleE/` দুটোই সত্যিই খালি directory — কোনো
file নেই, কোনো hidden content নেই, কোনো build config এদের reference করে না। যখন কেউ ইতিমধ্যে repo-root
housekeeping করছেন তখন delete করা নিরাপদ; এর জন্য আলাদা commit-এর প্রয়োজন নেই।
