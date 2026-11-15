# TriplyAI Backend — `.claude/` context ফোল্ডার

এই ফোল্ডারটি Claude Code-কে একটি বিশাল ফাইলের বদলে নির্দিষ্ট, প্রয়োজন অনুযায়ী (on-demand) context দেয়।

## কোন জিনিস কোথায় থাকে

| ফাইল | উদ্দেশ্য | কখন পড়া হয় |
|---|---|---|
| `../CLAUDE.md` | সংক্ষিপ্ত brief — নিয়ম, stack, phase scope, doc index। প্রতিটি session-এ **স্বয়ংক্রিয়ভাবে লোড হয়**। | সবসময় |
| `../build-order-complete.md` | ক্রমানুসারে সাজানো Phase 1 build prompt, dependency অনুযায়ী ক্রমে। | পরবর্তী feature বেছে নেওয়ার সময় |
| `../PROGRESS.md` | লাইভ "আসলে কী কী তৈরি হয়েছে" লগ, আসল code-এর সাথে মিলিয়ে যাচাই করা। | প্রতিটি session-এর শুরুতে |
| `docs/database-schema.md` | আসল বর্তমান schema-র সারসংক্ষেপ + Phase 1-এর সংযোজন। | যেকোনো data-সংক্রান্ত কাজ |
| `docs/api-conventions.md` | Module layering pattern, admin module থেকে আসল উদাহরণ। | যেকোনো নতুন module/endpoint |
| `docs/rbac-and-security.md` | ৪-role সিস্টেম + admin-session forgery fix (এটি আগে করুন)। | Admin/auth কাজ |
| `docs/content-library.md` | Itinerary library/publishing সিস্টেম — schema, workflow, endpoint। | Content সিস্টেমের কাজ |
| `docs/payments.md` | Stripe audit checklist + SSLCommerz integration spec। | Payment-এর কাজ |
| `../docs/ai-model-assignment-plan.md` | বিদ্যমান, প্রামাণ্য AI routing spec — এটি duplicate করবেন না। | Model routing-এর কাজ |
| `docs/infrastructure.md` | Env var, PM2 config, deployment-এর বাস্তব অবস্থা (এখনো কোনো CI/CD নেই)। | Setup/deploy কাজ |
| `docs/git-workflow.md` | Branch মডেল, প্রতি-feature flow, promotion। | যেকোনো git কাজ |
| `docs/testing.md` | ইতিমধ্যে ব্যবহৃত Jest/Supertest convention। | যেকোনো test-এর কাজ |
| `docs/qa-checklist.md` | Phase gate checklist + "ইতিমধ্যে তৈরি, আবার তৈরি করবেন না" তালিকা। | যেকোনো phase gate |
| `docs/branding.md` | তিন-নামের সমস্যা এবং এটি ঠিক করার একক cleanup pass। | Branding-সংক্রান্ত কাজ |
| `.githooks/` | pre-commit/pre-push: staging/main ব্লক করে, branch-এর নাম যাচাই করে। | git init-এর সময় সক্রিয় করুন |
| `commands/ship-feature.md` | `/ship-feature` — একটি feature তৈরি করুন, gate-যুক্ত ছন্দে। | আপনি invoke করেন |
| `commands/qa-gate.md` | `/qa-gate` — একটি phase-এর জন্য QA checklist চালান। | আপনি invoke করেন |
| `hooks/verify.sh` | প্রতি turn-এর পরে `tsc` + `jest` gate। | স্বয়ংক্রিয় (Stop hook) |
| `settings.json` | আগে থেকে অনুমোদিত নিরাপদ command + Stop hook wiring। | স্বয়ংক্রিয় |

## আমরা কীভাবে তৈরি করি (interactive mode)

`/ship-feature` দিয়ে একবারে একটি feature: plan → **আপনি অনুমোদন দেন** → implement → verify →
commit → **আপনি review করেন** → পরবর্তী। প্রতিটি feature-এ আপনি loop-এ থাকেন।

## অগ্রাধিকার (Precedence)

যখন কোনো `docs/*.md` ফাইল এবং `CLAUDE.md`-এর মধ্যে অমিল হয়, তখন `docs/` ফাইলটিই প্রাধান্য পাবে। যখন
AI routing নিয়ে `docs/ai-model-assignment-plan.md` এবং অন্য কিছুর মধ্যে অমিল হয়, তখন ওই ফাইলটিই প্রাধান্য পাবে —
এটি আসল code-এর ভিত্তিতে লেখা হয়েছে, কোনো spec খসড়ার ভিত্তিতে নয়।

## Build শৃঙ্খলা

- কঠোরভাবে phase-এর ক্রম অনুযায়ী build করুন। কখনোই আগে লাফিয়ে যাবেন না।
- প্রতিটি feature-এর পরে test + commit করুন।
- কোনো feature ship হলে `PROGRESS.md` আপডেট করুন।
- **"ওখানে আছেন যখন, ঠিক করে ফেলুন" — এমনটি করবেন না।** কোনো feature তৈরি করার সময় যদি branding সমস্যা, সম্পর্কহীন কোনো bug,
  বা refactor-এর সুযোগ চোখে পড়ে, তাহলে `PROGRESS.md`-এ একটি "Noticed"
  section-এর নিচে লিখে রাখুন এবং কাজ চালিয়ে যান — বর্তমান feature-এর scope বাড়াবেন না।
