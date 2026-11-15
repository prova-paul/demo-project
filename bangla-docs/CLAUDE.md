# TriplyAI Backend — CLAUDE.md

> **এই ফাইলটি সবসময় লোড হওয়া brief।** এটিকে ছোট ও স্থির রাখুন। বিস্তারিত থাকে
> `.claude/docs/*`-এ এবং প্রয়োজন অনুযায়ী পড়া হয় — নিচের pointer index দেখুন। যখন কোনো doc
> এবং এই ফাইলের মধ্যে অমিল হয়, তখন doc-টিই প্রাধান্য পায়।

## এটি কী

TriplyAI-এর NestJS backend, একটি AI itinerary planner। Repo: `Journey-Planner-Backend`
(branch `production`)। এই backend **developer.trytriplyai.com**-এ deploy করা আছে।

**তিনটি repo, তিনটি domain** (admin console-কে frontend repo থেকে আলাদা করা হয়েছে — যদি কোনো doc
এখনও বোঝায় যে admin UI frontend repo-তে আছে, তাহলে সেই doc পুরোনো/stale):

| Repo | Domain | এটি কী |
|---|---|---|
| `Journey-Planner-Backend` | `developer.trytriplyai.com` | এই repo — NestJS API |
| `Journey-Planner-Frontend` | `trytriplyai.com` | পাবলিক সাইট (live) |
| `triply-console` | `console.trytriplyai.com` | Admin console (নতুন, frontend থেকে আলাদা করা) |

প্রতিটি একটি আলাদা Claude Code project, যার নিজস্ব `CLAUDE.md` আছে। **এই backend দুটি
frontend-কেই সার্ভ করে**, এবং তারা একে ভিন্নভাবে কল করে — পাবলিক সাইট নিজের BFF routes-এর মাধ্যমে
server-side-এ proxy করে, আর admin console সরাসরি browser থেকে এই API কল করে। এই পার্থক্যের কারণেই
এখানে CORS এবং cookie attributes গুরুত্বপূর্ণ; দেখুন `.claude/docs/infrastructure.md`।

**⚠️ Branding নোট:** codebase-এ বর্তমানে তিনটি ভিন্ন product নাম আছে —
"Journey Crafter" (repo নাম, কিছু metadata উদাহরণ), "TripTailor" (`.env.example`-এর company
address/socials), এবং "TriplyAI" (live domain, সঠিক বর্তমান নাম)। **সব নতুন code, comment এবং
copy-তে "TriplyAI" ব্যবহার করুন।** পুরোনো occurrence সুযোগ পেলেই ঠিক করবেন না — এটি নিজস্ব একটি Phase 1
item হিসেবে track করা হচ্ছে, যাতে বিচ্ছিন্ন edit-এ নয়, বরং একটি পরিকল্পিত pass-এ এটি হয়।
দেখুন `.claude/docs/branding.md`।

## অলঙ্ঘনীয় নিয়মাবলি

1. **বিদ্যমান module pattern হুবহু অনুসরণ করুন** — প্রতিটি module হলো
   `presentation/http` (controllers) → `application/use-cases` (প্রতিটি action-এর জন্য একটি class) →
   `domain/contracts` + `domain/exceptions` (ports, interfaces, custom exceptions) →
   `infrastructure/*` (Drizzle repos, external providers)। দেখুন `.claude/docs/api-conventions.md`।
2. **সর্বত্র TypeScript strict।** কোনো `any` নয়, কোনো unchecked cast নয়। যে module আগে থেকেই Zod (`zod`)
   ব্যবহার করে সেখানে input validation-এর জন্য Zod; যে module-এ `class-validator` DTO প্রতিষ্ঠিত
   pattern সেখানে সেটিই — আশেপাশের code-এর সাথে মিল রাখুন, একটি module-এর ভেতরে style মেশাবেন
   না।
3. **Code-এ কোনো secret নয়।** সব key environment variables-এর মাধ্যমে (`.env.example` হলো কী কী
   থাকতে হবে তার source of truth)।
4. **শুধুমাত্র Drizzle।** Schema থাকবে `src/infra/db/schema/`-এ, migrations `drizzle-kit`-এর মাধ্যমে
   `drizzle/`-এ। কখনোই হাতে migration ফাইল লিখবেন না — generate করুন।
5. **Admin session security একটি live সমস্যা, style-এর পছন্দ নয়।** বর্তমান
   `admin_session` token হলো base64-encoded JSON, যার **কোনো signature নেই** — যে কেউ একটি বৈধ
   admin ID জানলেই session জাল করতে পারে। এর সাথে যুক্ত হয়েছে, admin client সেই token রাখে
   `sessionStorage`-এ, যা যেকোনো XSS পড়তে পারে। দুটি অংশই Phase 1 Foundation-এ, সবার আগে ঠিক করা হবে,
   এর ওপর কোনো RBAC কাজ তৈরি হওয়ার আগে। দেখুন `.claude/docs/rbac-and-security.md`।
6. **CORS `src/core/config/cors.config.ts`-এ hardcoded, `CORS_ORIGIN` দ্বারা চালিত নয়।**
   সেই env var `.env.example`-এ আছে কিন্তু কখনোই পড়া হয় না। একটি origin যোগ করা মানে একটি code change
   এবং একটি redeploy — কাউকে বলবেন না "শুধু env var সেট করে দিন।" দেখুন
   `.claude/docs/infrastructure.md`।
7. **Guest ইতিমধ্যেই আছে, এবং তাদের মাধ্যমে free tier ইতিমধ্যেই bypass করা যায়।**
   `guest-auth.method.ts` একটি synthetic `<uuid>@guest.com` email দিয়ে একটি আসল `users` row তৈরি করে;
   usage সেই email-এর বিপরীতে গণনা হয়, তাই আবার guest হলে counter reset হয়ে যায়। Guest path,
   usage limits, বা signup স্পর্শ করে এমন যেকোনো কাজে আগে `.claude/docs/database-schema.md` §0.9 পড়তে হবে — এবং
   মনে রাখুন যে **email পাঁচটি table জুড়ে একটি de facto identity key** (§0.8), তাই একজন
   user-এর email পরিবর্তন করা একটি transaction, একটি `UPDATE users` নয়।
8. **কখনোই নতুন AI-model-routing design উদ্ভাবন করবেন না।** একটি ইতিমধ্যেই এই repo-তে
   `docs/ai-model-assignment-plan.md`-এ আছে — সেটি implement করুন, নতুন করে spec করবেন না।
9. **Mobile-first API design এখানে বিবেচ্য নয়** (backend), কিন্তু **payload অবশ্যই হালকা রাখতে হবে**
   — পাবলিক frontend 375px screen-এ render করে; একটি screen-এর যতটুকু দরকার তার বেশি return করবেন না।

## Build শৃঙ্খলা

- **কঠোরভাবে phase-এর ক্রম অনুযায়ী build করুন। কখনোই সামনে লাফ দেবেন না** পরের কোনো phase-এর feature-এ।
- **প্রতিটি feature-এর পরে test + commit।** Jest ইতিমধ্যেই configured (`npm test`,
  `npm run test:e2e`) — সেটি ব্যবহার করুন, দ্বিতীয় কোনো test runner আনবেন না।
- **`PROGRESS.md` update করুন** যখনই কোনো feature ship হয় — এটি আসলে কী build হয়েছে তার
  source of truth, যা অনুমান নয়, আসল code-এর সাথে মিলিয়ে যাচাই করা।
- একটি work session শুরুতে পরের feature বেছে নেওয়ার আগে `PROGRESS.md` পড়ুন।

**আমরা কীভাবে build করি:** একটি feature = `main` থেকে একটি branch, **`/ship-feature`**-এর মাধ্যমে:
plan → আপনি approve করেন → branch `feature/pN-<name>` → implement → verify (`tsc` + `jest`) →
`main`-এ squash-merge → `PROGRESS.md`-এ টিক → branch delete। Phase gate **`/qa-gate`**-এর মাধ্যমে।
একটি Stop hook প্রতিটি turn-এর পরে `tsc` + `jest` চালায় — একটি red build শেষ করতে বাধা দেয়।

**Git নিয়ম:** কাজ করুন শুধুমাত্র `main` থেকে তৈরি `feature/*` / `fix/*` branch-এ (একমাত্র integration
branch — কোনো `develop`/`staging` নেই)। **কখনোই `production`-এ commit/merge/push করবেন না —
deployment promotion মানুষের দায়িত্বে।** পূর্ণ flow → `.claude/docs/git-workflow.md`।

## Tech stack (আসল codebase থেকে নিশ্চিত করা, অনুমান নয়)

NestJS (Fastify adapter) · Drizzle ORM + PostgreSQL · BullMQ-এর মাধ্যমে Redis (**শুধুমাত্র mail + ঐচ্ছিক
file-upload queue** — caching নয়, rate limiting নয়, sessions নয়) · user auth-এর জন্য JWT (`@nestjs/jwt`,
`passport-jwt`) · Stripe (subscriptions, আংশিকভাবে wired) · OpenAI (custom itinerary-র জন্য `gpt-4o`,
destination itinerary-র জন্য `gpt-4o-mini` — দুটিই বর্তমানে hardcoded) ·
Firebase Admin SDK (Google sign-in verification) · Nodemailer/SMTP (+ কিছু template-এর জন্য frontend
দিকে Resend) · Jest + Supertest (configured, ব্যবহৃত হচ্ছে) · **PM2**-এর মাধ্যমে deploy করা
(`ecosystem.config.cjs`, app `trytriplyai-b`, port 30008) একটি VPS-এ — **আজ পর্যন্ত কোনো Docker নেই, কোনো CI/CD
pipeline নেই।**

## Phase 1 scope (চূড়ান্ত — scope নিয়ে পুনরায় আলোচনা করবেন না, শুধু ক্রম নিয়ে)

Foundation → Signup fix → Content Library & Publishing System (**পূর্ণ architecture এখনই, Phase 3-এ
নয়** — admin-রা একটি configurable goal count-এর দিকে প্রতিদিন itinerary page publish করেন) → Admin RBAC
(4টি role) → AI model routing (বিদ্যমান plan doc অনুযায়ী) → Payments (Stripe audit/fix +
SSLCommerz) → PDF watermarking। পূর্ণ বিভাজন, ক্রম, এবং dependency map →
`build-order-complete.md`। Live status → `PROGRESS.md`।

**যা ইতিমধ্যেই build হয়েছে এবং অবশ্যই আবার build করা যাবে না:** passport-nationality + home-currency intake
fields (সম্পূর্ণ ship হয়েছে, 6টি ভাষায় অনূদিত), i18n (en/bn/ar/ja/zh/fr, `LanguageContext`-এর মাধ্যমে
সম্পূর্ণ wired), একটি free-tier monthly limit system (`FREE_TIER_MONTHLY_LIMIT`, per-user
override), `custom_trip_requests` (ইতিমধ্যেই একটি কার্যকর status-pipeline table, শুধু একটি form নয়)।
এই এলাকাগুলোর কোনোটি স্পর্শ করার আগে সম্পূর্ণ "ইতিমধ্যে সম্পন্ন" তালিকার জন্য `.claude/docs/qa-checklist.md` দেখুন।


---

## Doc index — প্রয়োজন অনুযায়ী পড়ুন

| যখন আপনি কাজ করছেন… | পড়ুন |
|---|---|
| যেকোনো database/schema কাজ | `.claude/docs/database-schema.md` |
| যেকোনো নতুন module বা endpoint | `.claude/docs/api-conventions.md` |
| Admin roles, permissions, বা session-token fix | `.claude/docs/rbac-and-security.md` |
| Itinerary library / publishing system | `.claude/docs/content-library.md` |
| Stripe বা SSLCommerz কাজ | `.claude/docs/payments.md` |
| AI model catalog / routing | `docs/ai-model-assignment-plan.md` (বিদ্যমান, authoritative) |
| Env vars, PM2, deployment | `.claude/docs/infrastructure.md` |
| Branches, প্রতি-feature git flow | `.claude/docs/git-workflow.md` |
| Testing পদ্ধতি | `.claude/docs/testing.md` |
| একটি phase QA gate | `.claude/docs/qa-checklist.md` |
| পুরোনো branding cleanup | `.claude/docs/branding.md` |
| কী build হয়েছে / এরপর কী | `PROGRESS.md` |
| প্রতি-feature-এর সুনির্দিষ্ট build ধাপ | `build-order-complete.md` |
