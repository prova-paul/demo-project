# Git Workflow

**Branch মডেল (সরলীকৃত — সিদ্ধান্ত 2026-07-31): `feature/* → main`।**
`main` হলো একমাত্র integration branch। এই মডেলে **কোনো `develop` এবং কোনো `staging` নেই**
— পূর্ববর্তী scaffold doc-এ একটি `develop → staging → main` flow বর্ণনা করা হয়েছিল যা কখনোই
আসল repo-র সাথে মেলেনি; যদি `develop`-এর কোনো পুরনো উল্লেখ পান, সেটিকে `main` হিসেবে ধরে নিন।

**Deployment মানুষের দায়িত্বেই থাকবে।** এই repo **`production`** branch থেকে deploy হয় (সেটিই
PM2-এর মাধ্যমে `developer.trytriplyai.com`-এ চলে)। `main → production` promote করা — এবং তার পরের PM2
restart — মানুষ করেন, কখনোই agent নয়।

## এককালীন bootstrap (একটি clone-এ প্রথম session)

Branch layout অনুমান করবেন না — যাচাই করুন:

```bash
git fetch origin && git branch -a
```

- যদি `main` locally না থাকে: `git checkout -b main origin/main` (অথবা বর্তমান
  default branch থেকে এটি তৈরি করুন এবং কোন branch canonical তা মানুষের সাথে নিশ্চিত করুন)।
- যদি কোনো পুরনো `develop` বা `staging` থাকে, **সেটিকে যেমন আছে তেমনই রেখে দিন** — পুরনো branch মানুষ অবসরে পাঠান,
  agent নয়।
- Hook সক্রিয় করুন (নিচে দেখুন) — এটি স্বয়ংক্রিয় নয়।

## প্রতি-feature flow

1. `git checkout main && git pull`
2. `git checkout -b feature/p1-<short-name>` (যেমন `feature/p1-content-library-schema`)
3. Build করুন, locally test করুন (`tsc` + `jest`)
4. `git checkout main && git merge --squash feature/p1-<name> && git commit`
5. `git push origin main`
6. `PROGRESS.md`-এ tick দিন, branch delete করুন

## নিয়মাবলি

- **কখনোই `production`-এ (বা কোনো legacy `staging`-এ) commit/merge/push করবেন না** — এটি
  `.githooks/pre-push` এবং `.githooks/pre-commit` দ্বারা প্রয়োগ করা হয়। Deployment promotion মানুষের দায়িত্বে।
- Bug fix: `main` থেকে `fix/<short-name>`, একই squash-merge flow।
- একটি feature = একটি branch = একটি squash commit। সম্পর্কহীন পরিবর্তন একটি branch-এ একসাথে জড়ো করবেন না।
- যখন কোনো feature একাধিক repo জুড়ে বিস্তৃত (backend + console, backend + frontend), **প্রতিটিতে একই branch
  নাম ব্যবহার করুন** যাতে কোন branch-গুলো একসাথে সম্পর্কিত তা স্পষ্ট থাকে।
- Commit message: সংক্ষিপ্ত imperative সারসংক্ষেপ (`Add SSLCommerz IPN validation`), এর বাইরে কোনো
  কঠোর convention-এর প্রয়োজন নেই।

## Hook সক্রিয় করা

```bash
git config core.hooksPath .githooks
```
প্রতিটি clone-এ এটি একবার চালান — এটি স্বয়ংক্রিয় নয়।
