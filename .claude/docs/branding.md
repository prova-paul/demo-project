# Branding Cleanup

Three product names currently exist across the codebase(s):
- **"Journey Crafter"** — repo name (`Journey-Planner-*`), example metadata in the frontend's
  `ARCHITECTURE.md` (`title: 'Home', description: 'Welcome to Journey Crafter...'`), and the
  canonical/OG tags found on the live site pointing at a `journeycrafter.com` domain
- **"TripTailor"** — `COMPANY_ADDRESS`, `SOCIAL_INSTAGRAM_URL`, etc. in `.env.example`
- **"TriplyAI"** — the actual live domain (`trytriplyai.com`) and the current, correct name

## Rule for Phase 1 work

**Use "TriplyAI" in all new code.** Do not fix old occurrences opportunistically while working
on something else — that produces scattered, hard-to-review diffs. This is tracked as its own
single-pass cleanup item in `build-order-complete.md`, done once, deliberately, covering:
canonical tags, OG/meta tags, `.env.example` company fields, any hardcoded strings in email
templates or metadata examples.

Before that cleanup pass starts, confirm with the founder whether "TriplyAI" is genuinely
final, or whether another rename is likely — fixing this twice would be worse than leaving it
inconsistent a little longer.
