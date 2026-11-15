# RBAC ও Admin Session Security

## 🚨 যেকোনো role-এর কাজের আগে প্রথমে ঠিক করুন: session token জাল করা যায়

সরাসরি code-এ নিশ্চিত করা হয়েছে (`admin-login.use-case.ts` / `admin-verify-session.use-case.ts`):

```ts
// current — DO NOT keep this pattern
const sessionData = { adminId: adminUser.id, email: adminUser.email, exp: Date.now() + 86400000 };
const sessionToken = Buffer.from(JSON.stringify(sessionData)).toString('base64');
```

Verification কেবল base64 decode করে, `exp` check করে, তারপর `findById(sessionData.adminId)`।
**কোনো signature নেই।** যে কেউ একটি বৈধ `admin_users.id` জানে বা enumerate করে, সে নিজের
`{adminId, email, exp}` JSON বানিয়ে, base64-encode করে, `admin_session` cookie হিসেবে set করে,
সেই admin হিসেবে authenticated হতে পারে — কোনো password লাগে না। এটি আজকের production code-এ একটি live, exploitable
vulnerability, কোনো তাত্ত্বিক উদ্বেগ নয়।

### সমাধান
`@nestjs/jwt` এবং `jsonwebtoken` ইতিমধ্যেই dependency — এগুলো ব্যবহার করুন:
```ts
// AdminLoginUseCase
const sessionToken = this.jwtService.sign(
  { adminId: adminUser.id, email: adminUser.email, role: adminUser.role },
  { expiresIn: '24h' },
);

// AdminVerifySessionUseCase
const payload = this.jwtService.verify(token); // throws on invalid signature or expiry
const adminUser = await this.adminUserRepo.findById(payload.adminId);
```
একটি আলাদা `ADMIN_JWT_SECRET` env var ব্যবহার করুন, যেকোনো user-facing JWT secret থেকে পৃথক, যাতে
একটি rotate করলে অন্যটি কখনো প্রভাবিত না হয়। এটি `role` column migration-এর **আগে** বা **সাথে**
ship করুন — এমন একটি session-এর উপর role-gating logic বানাবেন না যেটি জাল করে
যেকোনো role দাবি করা যায়।

## 🚨 দ্বিতীয়, সম্পর্কিত সমস্যা: client token-টি `sessionStorage`-এ রাখে

`AdminAuthGuard` session গ্রহণ করে **হয়** একটি `Authorization: Bearer` header থেকে **অথবা**
`admin_session` cookie থেকে। Admin frontend header path ব্যবহার করে, token-টি
`sessionStorage`-এ (`admin_session_token`) রেখে। এর মানে admin console-এ যেকোনো XSS সরাসরি
token পড়ে ফেলতে পারে — একটি httpOnly cookie JavaScript দিয়ে একেবারেই পড়া যায় না, আর সেটাই
এই flag-এর মূল উদ্দেশ্য।

একই Foundation pass-এ দুটি অংশই ঠিক করুন, নইলে signed token কেবল
একটি পাঠযোগ্য জায়গায় পড়ে থাকা signed token হয়ে যাবে:
1. Login response দিয়ে set করা একটি **httpOnly, Secure cookie** হিসেবে session issue করুন।
2. Console cookie-তে কাজ করছে নিশ্চিত হলে `AdminAuthGuard` থেকে `Authorization: Bearer` গ্রহণের path
   বাদ দিন — দুটি path খোলা রাখা মানে দুর্বলটি এখনও
   exploitable।

### Console-এর জন্য cookie attribute (`console.trytriplyai.com` → `developer.trytriplyai.com`)

Admin console হলো একটি ভিন্ন subdomain-এর **browser** client যা সরাসরি এই API call করে
(মাঝখানে কোনো BFF proxy নেই — দেখুন `infrastructure.md`)। এর ফলে cookie attribute-গুলো
গুরুত্বপূর্ণ ভূমিকা রাখে:

```ts
reply.setCookie('admin_session', sessionId, {
  httpOnly: true,
  secure: true,
  sameSite: 'lax',   // NOT 'none' — see below
  path: '/',
  maxAge: 60 * 60 * 24,
});
```

- **`sameSite: 'lax'` সঠিক এবং যথেষ্ট।** `console.trytriplyai.com` এবং
  `developer.trytriplyai.com` একই registrable domain `trytriplyai.com` শেয়ার করে, তাই এদের মধ্যকার request
  ভিন্ন origin হলেও *same-site*। `sameSite: 'none'` ব্যবহার করলে প্রকৃত third-party context-এ
  cookie অকারণে উন্মুক্ত হবে।
- **কোনো `domain` attribute লাগবে না।** Cookie এই API set করে এবং এই API-তেই ফেরত পাঠানো হয়;
  একটি host-only cookie ইতিমধ্যেই তা করে। কেবল তখনই `domain: '.trytriplyai.com'` যোগ করুন যদি parent domain-এর
  কোনো কিছুকে এটি পড়তে হয় — বর্তমানে কিছুই পড়ে না।
- **CORS-কে অবশ্যই `credentials: true` সহ console origin স্পষ্টভাবে allow করতে হবে** (credentials enabled থাকলে
  browser একটি `*` origin reject করে)। এটাই Foundation task 1.0 হিসেবে track করা
  `cors.config.ts` পরিবর্তন।
- **Console-কে অবশ্যই `credentials: 'include'` দিয়ে call করতে হবে।** না করলে browser নীরবে
  cookie বাদ দেয় এবং প্রতিটি request 401 হয়, log-এ কোনো কাজের তথ্য ছাড়াই। এই নির্দিষ্ট setup-এর এটাই সবচেয়ে
  সাধারণ ব্যর্থতার ধরন — admin login "রহস্যজনকভাবে" কাজ করা বন্ধ করলে প্রথমে
  এটাই check করুন।

## 🚨 তৃতীয় সমস্যা: একজন admin-কে বন্ধ করার কোনো উপায় নেই

`admin_users`-এ **কোনো `is_active` column নেই এবং কোনো `token_version` নেই** (
`admin-user.schema.ts`-এর বিপরীতে নিশ্চিত করা হয়েছে)। এটি যতটা শোনায় তার চেয়ে বেশি গুরুত্বপূর্ণ:

- `library_itineraries.created_by` হলো `ON DELETE RESTRICT`, তাই **যে admin কিছু publish করেছেন
  তাকে কখনোই delete করা যাবে না।** Deactivation-ই একমাত্র offboarding পথ — আর column ছাড়া
  সেটিও নেই।
- Admin JWT 24 ঘণ্টা বেঁচে থাকে, কোনো revocation ছাড়া। একজন বরখাস্ত বা compromised admin তার role পরিবর্তন করার পরেও
  এক দিন পর্যন্ত কাজ চালিয়ে যেতে পারেন।

Foundation task 1.2 এর সবকিছু একটি migration-এ যোগ করে (`database-schema.md` D1): `role`,
`is_active`, `token_version`, `role_assigned_by`, `role_assigned_at`।

- `AdminAuthGuard` **প্রতিটি request-এ `is_active` check করে**, কেবল login-এর সময় নয়।
- `token_version` বিদ্যমান `users.token_version` pattern-এর অনুরূপ — deactivate বা
  role change-এ এটি bump করুন এবং সেই admin-এর প্রতিটি live session সাথে সাথে শেষ হয়ে যাবে। এটি token
  payload-এ রাখুন, database row-এর সাথে তুলনা করুন।
- `role_assigned_by` / `role_assigned_at` পুরো audit log scan না করেই "কে এই ব্যক্তিকে super admin বানিয়েছে"
  প্রশ্নের উত্তর দেয়।

## Role (সম্পূর্ণ নতুন — `admin_users` বর্তমানে flat, সবার জন্য একটিই role)

| Role | যার মালিক |
|---|---|
| `super_admin` | নিচের সবকিছু, সাথে: role assign/revoke, audit log, payment gateway config, চূড়ান্ত override |
| `content_admin` | Content Library CRUD + publish, কেবল নিজের item (super_admin সব দেখেন/edit করেন) |
| `support_admin` | User management, leads, custom-trip-request queue |
| `model_growth_admin` | AI model catalog/routing (`ai-model-assignment-plan.md` অনুযায়ী), analytics |

## Permission key + `GET /admin/me` (Foundation task 1.4 — console এর উপর নির্ভর করে)

Role হলো storage model; **permission key হলো API surface** যার ভিত্তিতে console gate করে। একটি
server-side map (সাধারণ code, Phase 1-এ কোনো database table নয়) প্রতিটি role-কে একটি key set-এ resolve করে:

| Key | `super_admin` | `content_admin` | `support_admin` | `model_growth_admin` |
|---|---|---|---|---|
| `content.edit` / `content.publish` | ✅ (সব item) | ✅ (নিজের item) | — | — |
| `content.activity.view` | ✅ | — | — | — |
| `affiliates.manage` | ✅ | ✅ | — | — |
| `users.view` / `users.suspend` | ✅ | — | ✅ | — |
| `leads.view` | ✅ | — | ✅ | — |
| `models.edit` | ✅ | — | — | ✅ |
| `limits.edit` | ✅ | — | — | ✅ |
| `payments.configure` | ✅ | — | — | — |
| `roles.assign` / `audit.view` | ✅ | — | — | — |

`GET /admin/me` (`AdminAuthGuard`-এর পেছনে) return করে
`{ id, email, role, permissions: string[] }`, যেখানে `role`, `is_active` এবং `token_version` প্রতিটি call-এ
**database row** থেকে পড়া হয়, কখনোই token payload থেকে বিশ্বাস করা হয় না — একটি revoke করা role বা
একটি deactivated account পরবর্তী request-এই শেষ হতে হবে, পরবর্তী token expiry-তে নয়। Key-গুলো additive: নতুন module map-এ key যোগ করে; console একটি অজানা
key-কে "not granted" হিসেবে গণ্য করে, তাই একটি যোগ করা কখনোই breaking change নয়। যদি প্রতি-route-এ সহজ হয় তবে
server-side route guard-এর জন্য `RequireRole()` রাখুন — key set মূলত এজন্য আছে যাতে
**console** role name hardcode না করে UI gate করতে পারে।

## Enforcement pattern

`AdminAuthGuard` (`src/modules/admin/infrastructure/guards/admin-auth.guard.ts`) extend করুন — এটি
token verify করার পরে ইতিমধ্যেই `request.admin` attach করে; role check সেখানে যোগ করুন অথবা একটি
নতুন `RequireRole(role)` decorator + guard জোড়ায়, প্রতি route-এ check করা, কখনোই
client থেকে বিশ্বাস করা নয়। প্রতিটি mutating route অতিরিক্তভাবে commit করার **আগে** `audit_logs`-এ লেখে (দেখুন `database-schema.md`)
— audit write ব্যর্থ হলে পুরো request fail closed হয়।

## Rollout ক্রম (নিরাপদ, lockout-এর ঝুঁকি নেই)

0. **`cors.config.ts`-এ `console.trytriplyai.com` যোগ করুন এবং প্রথমে সেটি deploy করুন।** এটি ছাড়া
   admin console এই API-তে একেবারেই পৌঁছাতে পারে না, তাই নিচের কোনো কিছুই আসল client থেকে test করা যায় না।
   দেখুন `infrastructure.md`।
1. `role` column যোগ করুন, default `content_admin`, কোনো কিছু enforce করার আগে **বিদ্যমান সব admin row
   হাতে `super_admin`-এ backfill করুন**
2. JWT session fix + httpOnly cookie (উপরে) ship করুন — যাচাই করুন বিদ্যমান admin-রা এখনও login করতে পারেন
   **console-এর নিজস্ব origin থেকে**, কেবল curl বা Postman দিয়ে নয়, কারণ cookie/CORS
   interaction ঠিক সেটাই যা curl ধরতে পারবে না
3. Role-check middleware/decorator যোগ করুন, প্রথমে কেবল নতুন route-এ প্রয়োগ করুন
4. `GET /admin/me` + role→permission-key map ship করুন (task 1.4) — এটি না থাকা পর্যন্ত console-এর role-gated
   nav blocked
5. বিদ্যমান admin route-গুলো (users, itineraries, leads, payments, limits) উপরের table অনুযায়ী role
   requirement দিয়ে retrofit করুন
6. হাতে যাচাই করুন: একটি `content_admin` test account `/admin/users`-এ 403 পায়, একটি `super_admin`
   পায় না
7. Step 2 end-to-end কাজ করছে নিশ্চিত হলে `AdminAuthGuard` থেকে `Authorization: Bearer` গ্রহণের path
   সরিয়ে ফেলুন
