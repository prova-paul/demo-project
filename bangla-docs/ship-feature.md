---
description: পরবর্তী feature তার নিজস্ব branch-এ তৈরি করুন — plan → approve → branch → implement → verify → main-এ self-merge।
---

# /ship-feature — interactive, একবারে একটি feature

বর্তমান phase থেকে ঠিক **একটি** feature ship করুন, `main` থেকে বানানো তার নিজস্ব branch-এ, এবং কোনো code লেখার আগে
user plan অনুমোদন করবেন। প্রতি run-এ কখনোই একটির বেশি feature তৈরি করবেন না।
কখনোই বর্তমান phase-এর আগে লাফিয়ে যাবেন না। সম্পূর্ণ git নিয়ম → `.claude/docs/git-workflow.md`।

যদি user argument-এ কোনো feature-এর নাম দিয়ে থাকেন, সেটিই তৈরি করুন। অন্যথায় `PROGRESS.md` পড়ুন এবং
`build-order-complete.md`-এর dependency ক্রম মেনে **সর্বনিম্ন অসম্পূর্ণ phase-এর পরবর্তী unchecked আইটেম** বেছে নিন
— এমন কোনো আইটেম বেছে নেবেন না যার dependency এখনো সম্পন্ন হয়নি।

## ধাপসমূহ — ক্রমানুসারে অনুসরণ করুন, কোনোটি বাদ দেবেন না

1. **Plan (gate)।** প্রাসঙ্গিক doc পড়ুন (index `CLAUDE.md`-এ আছে)। যদি এই feature
   `admin_users`, session বা role স্পর্শ করে, তাহলে `rbac-and-security.md` সম্পূর্ণ পড়ুন — session fix
   নীরবে বাদ দেওয়া বা সম্পন্ন হয়েছে বলে ধরে নেওয়া চলবে না। একটি সংক্ষিপ্ত plan উপস্থাপন করুন: কী তৈরি করবেন, কোন
   ফাইল, কোন schema পরিবর্তন, এবং এই feature-এর নির্দিষ্ট test case। **থামুন এবং
   অনুমোদনের জন্য অপেক্ষা করুন।** অনুমোদন না পাওয়া পর্যন্ত কোনো code নয়।

2. **Branch।** `git checkout main && git pull`, তারপর `git checkout -b feature/p1-<name>`।

3. **আগে Schema (প্রয়োজন হলে)।** নতুন table/column → migration লিখুন
   (আপডেট করা schema ফাইলের ভিত্তিতে `npm run db:generate`, তারপর `npm run db:migrate`) → এর উপর build করার আগে নিশ্চিত করুন
   যে এটি পরিষ্কারভাবে apply হয়।

4. **Implement।** `api-conventions.md`-এর layering হুবহু অনুসরণ করুন। TypeScript strict।

5. **Verify।** `npm run test`, `npm run test:e2e`, `npx tsc --noEmit` — সবগুলো অবশ্যই green হতে হবে।
   Admin auth বা payment স্পর্শ করে এমন যেকোনো কিছুর জন্য, আসল flow নিজে হাতে চালিয়ে দেখুন, শুধু
   test-এর উপর নির্ভর করবেন না।

6. **Self-merge।** `git checkout main`, `git merge --squash feature/p1-<name> && git commit`,
   `git push origin main`।

7. **Record।** `PROGRESS.md`-এ tick দিন। যদি scope-এর বাইরের কিছু চোখে পড়ে (branding, কোনো
   সম্পর্কহীন bug), তাহলে এখন ঠিক না করে সেখানে একটি "Noticed" নোটের নিচে যোগ করুন।

8. **পরিষ্কার করুন + ফেরত দিন।** `git branch -d feature/p1-<name>`। কী ship হয়েছে তার সারসংক্ষেপ দিন,
   diff সারসংক্ষেপ দেখান, review চান। **"next"-এর জন্য অপেক্ষা করুন।**

## Guardrails
- **কখনোই `production`-এ (বা কোনো legacy `staging`-এ) commit/merge/push করবেন না।** `main` হলো integration branch যেখানে আপনি merge করেন; deployment promotion মানুষের দায়িত্বে।
- plan-approval gate পার না করে কখনোই admin-session verification logic পরিবর্তন করবেন না
  — এটি security-sensitive code, সাধারণ refactoring নয়।
- যদি কোনো অনুপস্থিত secret, অস্পষ্ট product সিদ্ধান্ত, বা এমন বারবার test failure-এর মুখোমুখি হন যা
  সমাধান করতে পারছেন না, তাহলে **থামুন এবং জিজ্ঞাসা করুন** — অনুমান করবেন না।
