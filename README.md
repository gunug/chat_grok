# simple chat bot (repo: chat_grok)

Flutter **Android** app — an xAI **Grok** chatbot with Google login, a shared
credit platform, and Google Play in-app purchase top-up. The xAI key never ships
in the app; a Supabase Edge Function proxies xAI and streams responses.

```
Flutter app ──Google JWT──► Supabase Edge Functions ──► xAI Grok / Google Play
   chat:            stream chat + credit gate/deduct
   purchase-verify: verify IAP → grant credits (app_top_up)
```

- **Android package**: `com.onethelab.simplechatbot` · **app name**: "simple chat bot"
- **Backend**: Supabase project `oerrgsanrnelhvgikgkv` (shared credit platform with
  android-planlet; credits split by `service_key = chat_grok`)
- The app embeds only **public** values (Supabase URL/anon key, Google Web client ID)
  in `lib/config.dart`. Secrets stay server-side (Supabase secrets / dashboard).

## Features
- Streaming Grok chat (SSE), multiple conversations, auto titles, delete, export
  (share Markdown/JSON) — stored on-device (`shared_preferences`).
- **Google login** (credits attach to the account).
- **Credits**: integer-credit model with markup at consumption. Shown on every
  screen (💳 badge) and a Credits page (balance / used / charged + ₩ estimate).
- **In-app purchase** top-up: `credit_5000` (5,000원 → 5,000 credits), server-verified.
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
  chat/                xAI proxy + credit gate/deduct (SSE)
  purchase-verify/     verify Play purchase → app_top_up
```

## Backend deploy (functions only — never `supabase config push` on this shared project)
```powershell
supabase functions deploy chat
supabase functions deploy purchase-verify
# Secrets (already set on the shared project): XAI_API_KEY, GOOGLE_PLAY_SA_B64
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
