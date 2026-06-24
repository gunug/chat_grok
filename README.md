# simple chat bot (repo: chat_grok)

Flutter **Android** app — an xAI **Grok** chatbot with Google login, a shared
credit platform, and Google Play in-app purchase top-up. The xAI key never ships
in the app; a Supabase Edge Function proxies xAI and streams responses.

```
Flutter app ──Google JWT──► Supabase Edge Functions ──► xAI / OpenAI / Google Play
   chat:            stream chat + credit gate/deduct
   image:           image generation (compose prompt + render) + credit gate/deduct
   purchase-verify: verify IAP → grant credits (app_top_up)
```

> **Status: HELD as of 2026-06-24.** Feature-complete for internal testing and
> deployed (versionCode 25, `1.3.13+25`). See **[Held status & resume guide](#held-status--resume-guide)**
> at the bottom before continuing work.

- **Android package**: `com.onethelab.simplechatbot` · **app name**: "simple chat bot"
- **Backend**: Supabase project `oerrgsanrnelhvgikgkv` (shared credit platform with
  android-planlet; credits split by `service_key = chat_grok`)
- The app embeds only **public** values (Supabase URL/anon key, Google Web client ID)
  in `lib/config.dart`. Secrets stay server-side (Supabase secrets / dashboard).

## Features
- Streaming chat (SSE), multiple conversations, auto titles, delete, export
  (share Markdown/JSON) — stored on-device (`shared_preferences`).
- **Multi-provider models**: selectable xAI + OpenAI chat models (`cg_models`),
  validated against the account's live model list; unavailable models auto-disable.
- **Image generation**: prompt/chat image sessions, gallery, multi-provider image
  models (`cg_image_models`); compose (build prompt) + render steps, both billed.
- Server-complete-and-store: an answer finishes server-side even if the app is
  backgrounded; credits are deducted once, server-side.
- **Google login** (credits attach to the account).
- **Credits**: integer-credit model with markup at consumption. Shown on every
  screen (💳 badge) and a Credits page (balance / used / charged + ₩ estimate).
- **In-app purchase** top-up: `credit_5000` (5,000원 → 5,000 credits), server-verified.
- **Billing safety** (see resume guide): output token cap + pre-authorization gate
  on chat, fixed-cost pre-authorization on images, conservative deficit protection.
- In-app **debug log** (view + copy) for diagnosing release/Play builds.

## Project layout
```
lib/
  main.dart            app + AuthGate (login gate) + chat screen
  supa.dart            Supabase init + Google sign-in/out
  login_screen.dart    Google login screen
  chat_service.dart    SSE streaming from the chat function
  models.dart storage.dart   conversations (shared_preferences)
  credits.dart         global credit balance + CreditBadge (all screens)
  credits_screen.dart  balance + "크레딧 충전하기" (IAP)
  purchase_service.dart in_app_purchase flow (server-verified)
  config.dart          public Supabase + Google Web client ID
  settings_screen.dart optional Supabase override
  debug_log.dart       in-app log (logD + DebugLogScreen)
supabase/functions/
  chat/                xAI/OpenAI proxy + credit gate/deduct (SSE)
  image/               image compose + render + credit gate/deduct
  purchase-verify/     verify Play purchase → app_top_up
```
> DB migrations live in **`android-planlet/supabase/migrations`** (shared platform),
> not in this repo. Push them from there.

## Backend deploy (functions only — never `supabase config push` on this shared project)
```powershell
supabase functions deploy chat
supabase functions deploy image
supabase functions deploy purchase-verify
# Secrets (already set on the shared project): XAI_API_KEY, OPENAI_API_KEY, GOOGLE_PLAY_SA_B64
```

## Build & release to Play internal testing
Signing uses an upload keystore via `android/key.properties` (gitignored).
```powershell
# bump pubspec `version: x.y.z+N` (Play rejects a duplicate versionCode)
flutter analyze
flutter build appbundle --release
python <android-planlet>/tools/play_upload.py \
  --key <SA json> --aab build/app/outputs/bundle/release/app-release.aab \
  --package com.onethelab.simplechatbot --track internal --status completed --notes "..."
```
Full runbook: `android-planlet/docs/play-release.md`. Architecture + platform
schema: `android-planlet/docs/platform-architecture.md`.

## Notes for testers / setup
- Install via the **Play internal-testing opt-in link** with a license-tester
  Google account — IAP does **not** work on sideloaded builds.
- For Google login on a Play build, the **Play App Signing SHA-1** must be added to
  the Google OAuth Android client (`com.onethelab.simplechatbot`).
- A newly created in-app product can take **24–48h** to become available to the
  Billing API (`product not found` until then).

See [CLAUDE.md](CLAUDE.md) for the full developer brief (identifiers, secrets,
SHA-1s, gotchas).

---

## Held status & resume guide
**Held 2026-06-24.** Live on Play internal testing at **versionCode 25 (`1.3.13+25`)**.
The chat/image edge functions and the trial migration are deployed to the shared
Supabase project. Pick up here.

### Done in the last work block (billing-abuse hardening)
The credit gate only checked `balance ≥ 1 credit` with no per-request cost ceiling,
so a single oversized request (or a fixed-cost image) could overshoot the balance —
one free over-spend per funding cycle / per free trial account. Mitigations shipped:

1. **Trial credits 300 → 100 → 0.** Const `TRIAL_CREDITS` in `chat` + `image`
   functions *and* `app_pricing.trial_credits` (migrations: `20260624010000` set 100,
   `20260624030000_chat_grok_trial_0` set 0). Both must agree — whichever seed path
   (`app_register_service` const vs `app_ensure_registered` column) creates the
   credits row first wins the value. Trial is **now 0**: new accounts get no free
   credits, so a bare JWT (even mass Google accounts) costs nothing — the credit gate
   402s before any provider call. Only topped-up accounts can use the app. This is
   **per-service**: planlet keeps its own trial (separate `service_key` row + const;
   planlet team set theirs to 100 in `20260624020000_planlet_trial_100`). Existing
   chat_grok users keep whatever balance they already had (no claw-back).
   Note: the client never calls `app_ensure_registered`; trial is seeded server-side
   on the first chat/image call, once per account via `on conflict do nothing`.
2. **Chat output cap.** `MAX_OUTPUT_TOKENS = 4096` → `max_completion_tokens` (OpenAI)
   / `max_tokens` (xAI). Bounds per-request output cost.
3. **Chat pre-authorization gate.** Before calling the provider, estimate input
   tokens conservatively (`chars / 2`, Korean-dense) + `MAX_OUTPUT_TOKENS`, convert
   to credits via `app_usage_credits`, and 402 if `balance <` that. Estimate is
   **gate-only**; actual deduction still uses real post-call usage.
4. **Image pre-authorization gate.** Image cost is fixed (`price_usd` known upfront),
   so the gate requires `balance ≥` the image's credit cost before calling — closes
   the 1-credit free-image hole.
5. **User-facing messages.** 402 (both chat + image) →
   "토큰 잔여량이 AI기능을 수행하기에 부족합니다." Provider-out-of-funds (upstream
   429/402/403) → a Korean "service temporarily unavailable, operator must top up"
   message instead of a raw English error.

### Known gaps / where to resume
- **Trial abuse: closed for now** by setting trial = 0 (no free credits). If you want
  a trial back, the abuse vector returns — a JWT is obtainable by anyone via Supabase's
  hosted Google OAuth (uses the server-side client secret), and "Allow new signups" is
  a **project-global** toggle so it can't be disabled for chat_grok without breaking
  the shared planlet. Real per-service fix would be **Play Integrity attestation** in
  the edge functions (accept only requests from the genuine app), not yet built.
- **Backend is a public endpoint.** The edge functions answer any authenticated caller;
  the app is not required (curl works). Only credits limit cost. To fully neutralize
  while held: undeploy (`supabase functions delete chat image`) or cap/rotate the xAI
  key. xAI key stays server-side, so nobody can bill it directly — only through the
  credit-gated function.
- **Pre-auth input estimate is a heuristic** (`chars / 2`), not a real tokenizer.
  Conservative (over-counts), so it errs toward rejecting near-empty balances — fine
  for a safety gate. If precision is wanted later, ship `gpt-tokenizer`/tiktoken
  (costs bundle weight + cold start).
- **Refunds don't claw back credits.** A Play IAP refund leaves granted credits in
  place (`app_top_up` is grant-only, idempotent). No reconciliation job exists.
- **`app_record_usage` failure = free response.** If the post-stream deduction RPC
  throws it's only logged; the user already got the answer. No retry/queue.
- **Pricing knobs to watch** (in `app_pricing`, shared DB): `usd_to_krw` (default
  1400, stale FX undercharges), `sell_multiple_pct` (300 = 3× markup),
  `krw_per_credit` (1). All live in `android-planlet` migrations/DB.

### To continue
1. Edit functions under `supabase/functions/{chat,image}`; redeploy with
   `supabase functions deploy <name>` (Docker not required for deploy).
2. DB changes → add a migration in `android-planlet/supabase/migrations`, check
   `supabase migration list` for collisions, then `supabase db push` from there.
3. App changes → bump `pubspec version +N`, `flutter analyze`,
   `flutter build appbundle --release`, upload via `play_upload.py` (see above).
4. Server-only changes (gates, caps, pricing) take effect immediately; **user-facing
   strings need an app rebuild + Play upload** to reach testers.
