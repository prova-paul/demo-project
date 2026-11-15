# Branding Cleanup

বর্তমানে codebase(গুলো) জুড়ে তিনটি product নাম রয়েছে:
- **"Journey Crafter"** — repo-র নাম (`Journey-Planner-*`), frontend-এর
  `ARCHITECTURE.md`-এ উদাহরণ metadata (`title: 'Home', description: 'Welcome to Journey Crafter...'`), এবং
  লাইভ সাইটে পাওয়া canonical/OG tag যা একটি `journeycrafter.com` domain-এর দিকে নির্দেশ করে
- **"TripTailor"** — `.env.example`-এ `COMPANY_ADDRESS`, `SOCIAL_INSTAGRAM_URL` ইত্যাদি
- **"TriplyAI"** — আসল লাইভ domain (`trytriplyai.com`) এবং বর্তমান, সঠিক নাম

## Phase 1 কাজের নিয়ম

**সমস্ত নতুন code-এ "TriplyAI" ব্যবহার করুন।** অন্য কোনো কাজ করার সময় সুযোগ পেয়ে পুরনো occurrence ঠিক করবেন না
— এতে ছড়ানো-ছিটানো, review করা কঠিন diff তৈরি হয়। এটি `build-order-complete.md`-এ নিজস্ব
একক-pass cleanup আইটেম হিসেবে track করা হচ্ছে, যা একবার, সুচিন্তিতভাবে করা হবে, এবং এর আওতায় থাকবে:
canonical tag, OG/meta tag, `.env.example`-এর company field, email
template বা metadata উদাহরণে থাকা যেকোনো hardcoded string।

সেই cleanup pass শুরু করার আগে, founder-এর সাথে নিশ্চিত হয়ে নিন যে "TriplyAI" সত্যিই
চূড়ান্ত কিনা, নাকি আরেকটি rename হওয়ার সম্ভাবনা আছে — এটি দুবার ঠিক করা, আরও কিছুদিন
অসামঞ্জস্যপূর্ণ রেখে দেওয়ার চেয়েও খারাপ হবে।
