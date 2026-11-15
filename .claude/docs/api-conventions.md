# API Conventions

Pattern confirmed from the existing `admin` module — follow it exactly for every new module or
endpoint. Do not introduce a different layering style even if it seems cleaner.

## Layer responsibilities (real example: `src/modules/admin/`)

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

- Controllers depend on use-cases, never on repositories directly.
- Use-cases depend on domain ports (`@Inject(SOME_REPO)`), never on Drizzle directly.
- Repository implementations live in `infrastructure/repositories/`, injected via the token
  defined in `domain/contracts/*.port.ts`.
- Guards go in `infrastructure/guards/` — see `AdminAuthGuard` for the pattern (reads
  `Authorization: Bearer` or cookie, delegates to a `Verify*SessionUseCase`, attaches the
  result to `request.admin`).

## Response shape

Every response wraps in the existing `BaseMaper` shape:
```ts
{ title: string; message: string; error: boolean; statusCode: number; data: T | null }
```
Match this for all new endpoints — don't return raw objects.

## New module for Phase 1: Content Library

Follow the exact same four-layer pattern:
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

## Route map — Phase 1 additions

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

The affiliate redirect and the share link are hit by **browser navigation**, not `fetch` — CORS
does not apply to either, so don't debug them as CORS problems.

**Admin (guarded by `AdminAuthGuard`, role-checked inside per `rbac-and-security.md`):**
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

Mirror the existing pagination/search pattern from `GET /admin/users/itinerary-limits`
(already in the admin module) for every new list endpoint above — don't invent a new
pagination shape.

## Validation

Match whatever the module you're extending already uses. `admin` module uses DTOs with
`class-validator`; the itinerary module's OpenAI port uses inline TypeScript interfaces.
New modules (content-library, affiliate-partners): use `class-validator` DTOs, consistent with
`admin` since these are admin-surface-heavy modules.
