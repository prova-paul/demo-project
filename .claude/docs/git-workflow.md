# Git Workflow

**Branch model (simplified — decided 2026-07-31): `feature/* → main`.**
`main` is the single integration branch. There is **no `develop` and no `staging`** in this
model — earlier scaffold docs described a `develop → staging → main` flow that never matched
the real repos; if you find a stale reference to `develop`, treat it as meaning `main`.

**Deployment stays human-owned.** This repo deploys from the **`production`** branch (that's
what runs at `developer.trytriplyai.com` via PM2). Promoting `main → production` — and the PM2
restart that follows — is done by the human, never by the agent.

## One-time bootstrap (first session in a clone)

Don't assume the branch layout — check it:

```bash
git fetch origin && git branch -a
```

- If `main` doesn't exist locally: `git checkout -b main origin/main` (or create it from the
  current default branch and confirm with the human which branch is canonical).
- If a stale `develop` or `staging` exists, **leave it alone** — the human retires old
  branches, not the agent.
- Activate hooks (see bottom) — it's not automatic.

## Per-feature flow

1. `git checkout main && git pull`
2. `git checkout -b feature/p1-<short-name>` (e.g. `feature/p1-content-library-schema`)
3. Build, test locally (`tsc` + `jest`)
4. `git checkout main && git merge --squash feature/p1-<name> && git commit`
5. `git push origin main`
6. Tick `PROGRESS.md`, delete the branch

## Rules

- **Never commit/merge/push to `production` (or a legacy `staging`)** — enforced by
  `.githooks/pre-push` and `.githooks/pre-commit`. Deployment promotion is human-owned.
- Bug fixes: `fix/<short-name>` off `main`, same squash-merge flow.
- One feature = one branch = one squash commit. Don't batch unrelated changes into one branch.
- When a feature spans repos (backend + console, backend + frontend), **use the same branch
  name in each** so it's obvious which branches belong together.
- Commit messages: short imperative summary (`Add SSLCommerz IPN validation`), no need for a
  strict convention beyond that.

## Activating hooks

```bash
git config core.hooksPath .githooks
```
Run this once per clone — it's not automatic.
