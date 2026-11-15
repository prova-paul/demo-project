# API Conventions

বিদ্যমান `admin` module থেকে নিশ্চিত করা pattern — প্রতিটি নতুন module বা
endpoint-এর জন্য এটি হুবহু অনুসরণ করুন। অন্য কোনো layering style আনবেন না, এমনকি যদি সেটি আরও পরিষ্কার মনে হয়।

## Layer-এর দায়িত্ব (আসল উদাহরণ: `src/modules/admin/`)

```
src/modules/<module>/
├── presentation/http/
│   ├── <module>.controller.ts       # @Controller, route handlers, DTO validation, calls use-cases
│   └── http-dto/                    # request/response DTOs
├── application/
│   ├── use-cases/                   # one class per action, e.g. AdminLoginUseCase
│   ├── dto/                         # input/output DTOs between controller and use-case
│   └── utils/
├── domain/
│   ├── contracts/                   # repository ports (interfaces) + injection tokens
│   └── exceptions/                  # custom exceptions (e.g. AdminUnauthorizedException)
└── infrastructure/
    ├── repositories/                # Drizzle implementations of the domain ports
    ├── guards/                      # NestJS guards (e.g. AdminAuthGuard)
    └── providers/                   # external service adapters (e.g. OpenAIService, Stripe)
```

- Controller use-case-এর উপর নির্ভর করে, কখনোই সরাসরি repository-র উপর নয়।
- Use-case domain port-এর উপর নির্ভর করে (`@Inject(SOME_REPO)`), কখনোই সরাসরি Drizzle-এর উপর নয়।
- Repository implementation থাকে `infrastructure/repositories/`-এ, inject করা হয়
  `domain/contracts/*.port.ts`-এ সংজ্ঞায়িত token-এর মাধ্যমে।
- Guard থাকে `infrastructure/guards/`-এ — pattern-এর জন্য `AdminAuthGuard` দেখুন (এটি
  `Authorization: Bearer` বা cookie পড়ে, একটি `Verify*SessionUseCase`-এর কাছে দায়িত্ব দেয়, এবং
  ফলাফল `request.admin`-এ যুক্ত করে)।

## Response-এর গঠন

প্রতিটি response বিদ্যমান `BaseMaper` গঠনে wrap করা হয়:
```ts
{ title: string; message: string; error: boolean; statusCode: number; data: T | null }
```
সমস্ত নতুন endpoint-এ এর সাথে মিল রাখুন — raw object return করবেন না।

## Phase 1-এর নতুন module: Content Library

হুবহু একই চার-layer pattern অনুসরণ করুন:
```
src/modules/content-library/
├── presentation/http/content-library.controller.ts   (admin + public routes, split by guard)
├── application/use-cases/
│   ├── create-library-itinerary.use-case.ts
│   ├── update-library-itinerary.use-case.ts
│   ├── publish-library-itinerary.use-case.ts
│   ├── list-library-itineraries.use-case.ts          (admin — filterable by author/status)
│   ├── get-published-itinerary-by-slug.use-case.ts    (public)
│   ├── record-page-view.use-case.ts
│   └── get-publishing-activity.use-case.ts            (super_admin only — traffic + author view)
├── domain/contracts/library-itinerary-repository.port.ts
└── infrastructure/repositories/library-itinerary.repository.ts
```

## Route map — Phase 1-এর সংযোজন

**Public:**
```
POST /itinerary/generate                 -> already exists, extend to allow guest (no auth) calls
GET  /library/:slug                      -> published page by slug; falls back to
                                            library_itinerary_slugs and answers 301 for a
                                            retired slug (never a silent 404)
POST /library/:slug/view                 -> record-page-view use-case; stamps is_bot by UA
GET  /library/:slug/affiliate/:linkId    -> redirect + click_count increment (never raw href)
GET  /itinerary/shared/:shareToken       -> guest/user share link, no auth; requires
                                            share_revoked_at IS NULL (task 2.3)
```

Affiliate redirect এবং share link-এ আঘাত হয় **browser navigation** দ্বারা, `fetch` দ্বারা নয় — CORS
এ দুটির কোনোটিতেই প্রযোজ্য নয়, তাই এগুলোকে CORS সমস্যা হিসেবে debug করবেন না।

**Admin (`AdminAuthGuard` দ্বারা সুরক্ষিত, ভেতরে `rbac-and-security.md` অনুযায়ী role যাচাই করা হয়):**
```
GET    /admin/content-library                 -> content_admin: own only; super_admin: all
POST   /admin/content-library
PUT    /admin/content-library/:id
POST   /admin/content-library/:id/publish
GET    /admin/content-library/goal             -> reads app_settings key
PUT    /admin/content-library/goal             -> super_admin only
POST   /admin/content-library/:id/unpublish    -> super_admin only; status -> 'unpublished',
                                                  published_at is KEPT as the historical record
GET    /admin/content-library/slug-available   -> ?slug=&language= ; checks BOTH
                                                  library_itineraries and library_itinerary_slugs
GET    /admin/content-library/activity         -> super_admin only — the Publishing Activity view
GET    /admin/affiliate-partners
POST   /admin/affiliate-partners
PUT    /admin/affiliate-partners/:id
GET    /admin/roles                            -> super_admin only
PUT    /admin/users/:id/role                    -> super_admin only, writes audit_logs
PUT    /admin/admin-users/:id/active            -> super_admin only; deactivate/reactivate an
                                                  admin (delete is impossible once they've
                                                  published — see rbac-and-security.md), bumps
                                                  token_version, writes audit_logs
POST   /admin/users/:id/suspend                 -> support_admin/super_admin; sets suspended_at,
                                                  bumps users.token_version, writes audit_logs
POST   /admin/users/:id/reinstate                -> same gating, clears suspended_at
GET    /admin/audit-logs                        -> super_admin only
GET    /admin/payments/gateways                 -> super_admin only
PUT    /admin/payments/gateways/:gateway
```

উপরের প্রতিটি নতুন list endpoint-এর জন্য `GET /admin/users/itinerary-limits` (ইতিমধ্যে admin module-এ আছে)
থেকে বিদ্যমান pagination/search pattern অনুসরণ করুন — নতুন কোনো
pagination গঠন উদ্ভাবন করবেন না।

## Validation

আপনি যে module বাড়াচ্ছেন সেটি ইতিমধ্যে যা ব্যবহার করে তার সাথে মিল রাখুন। `admin` module
`class-validator` সহ DTO ব্যবহার করে; itinerary module-এর OpenAI port inline TypeScript interface ব্যবহার করে।
নতুন module (content-library, affiliate-partners): `class-validator` DTO ব্যবহার করুন, `admin`-এর সাথে সামঞ্জস্য রেখে,
কারণ এগুলো admin-surface-নির্ভর module।
