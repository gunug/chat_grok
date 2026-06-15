# CLAUDE.md — simple chat bot (repo: chat_grok)

Flutter **Android** app: a Grok (xAI) chatbot with a shared credit platform,
Google login, and Google Play in-app purchase top-up. Internal-testing on Play.

> History: started as a Node/web app, converted to Flutter. The Node version is
> in git history only. Repo + Dart package + Supabase `service_key` stay
> **`chat_grok`**; only the Android identity is "simple chat bot".

## Identity / facts
| | |
|---|---|
| Android applicationId / namespace | `com.onethelab.simplechatbot` |
| App display name | **simple chat bot** |
| Dart package / repo / Supabase service_key | `chat_grok` (do NOT rename) |
| Version (pubspec) | `1.0.1+2` — bump `+N` every Play upload (Play rejects dup versionCode) |
| GitHub | https://github.com/gunug/chat_grok |
| Supabase project (SHARED with android-planlet) | `oerrgsanrnelhvgikgkv` |
| Provider | xAI Grok, model `grok-3` (aliases to grok-4.x), streaming |

## Architecture
```
Flutter app ──JWT──► Supabase Edge Functions ──► xAI / Google Play
  chat:            supabase/functions/chat            (stream + credit gate/deduct)
  purchase-verify: supabase/functions/purchase-verify (verify IAP → app_top_up)
```
- **Provider keys never ship in the app.** `XAI_API_KEY` is a Supabase secret.
- App ships only the **public** Supabase URL + anon key + Google **Web** client ID
  (all in `lib/config.dart`). The Google client **secret** lives ONLY in the
  Supabase dashboard (Auth → Providers → Google).

## Shared credit platform (owned by android-planlet)
Single Supabase project; credits/usage split by `(user_id, service_key)`.
Authoritative schema/docs are in **`g:\00_project\android-planlet`**:
`docs/platform-architecture.md`, `docs/play-release.md`, `docs/backend-supabase.md`,
`supabase/migrations/*`, `supabase/functions/{ai-plan,purchase-verify}`,
`lib/data/purchase_service.dart`. **When the platform layer is unclear, read those
— the guide files can lag the actual DB.**

- Credits are **integer credits** (not micro-USD): `app_service_credits` columns
  `balance_credits / total_purchased_credits / total_spent_credits`.
- Markup is applied **at consumption**: `app_record_usage(... p_cost_micros ...)`
  converts raw cost → credits via `app_pricing` (sell_multiple_pct, krw_per_credit,
  usd_to_krw) and deducts. Top-up is simple: `app_top_up` grants floor(krw/krw_per_credit).
- RPCs are **service-role only** (functions call them); the app only **reads its own
  row** via RLS and may call display RPCs `app_usage_credits` / `app_credits_to_krw`.
- `service_key` is a **server constant** in each function ("chat_grok") — never trust
  the client → no billing spoofing.

## Edge functions (deploy: `supabase functions deploy <name>` — NOT config push)
- `chat`: auth (getUser) → `app_register_service`(trial 300 credits) → gate on
  `balance_credits` (MIN 1, else 402) → stream xAI → after stream
  `app_record_usage` → SSE `event: usage {tokens, costUsd, creditsCharged, balanceCredits}`.
- `purchase-verify`: verify `{productId, purchaseToken}` with the Play Developer API
  (`GOOGLE_PLAY_SA_B64` secret, shared) → `app_top_up('play', token, krw)` (idempotent).
  CATALOG `{ credit_5000: 5000 }`. Package const `com.onethelab.simplechatbot`.

## App (lib/)
`main.dart` AuthGate (Google login gate) · `supa.dart` Supabase init + Google
sign-in/out · `login_screen.dart` · `chat_service.dart` SSE stream · `models.dart`
+ `storage.dart` (shared_preferences conversations) · `credits.dart` global
`creditBalance` + `CreditBadge` (shown on all screens) · `credits_screen.dart`
(balance + **크레딧 충전하기** IAP button) · `purchase_service.dart` (in_app_purchase,
product `credit_5000`, server-verified) · `debug_log.dart` in-app log (`logD()` +
DebugLogScreen; reachable from login screen "로그 보기" and chat menu "로그").
- Auth is **Google only** (anonymous removed). Credits attach to the Google account.

## Secrets (all gitignored — never commit/print)
- `.env` — xAI key (local only; mirrored to Supabase secret `XAI_API_KEY`).
- `android/key.properties` + `android/app/upload-keystore.jks` — **release signing**
  (alias `upload`; password is in key.properties). Back these up.
- Supabase secrets (shared project): `XAI_API_KEY`, `GOOGLE_PLAY_SA_B64`.
- SA JSON for Play publish: `g:\00_project\android-planlet\keys\android-ai-apis-1a2367ba7888.json`.

## Release to Play internal testing (runbook: android-planlet/docs/play-release.md)
```powershell
# 1) bump pubspec version +N
flutter analyze
flutter build appbundle --release        # signs with upload key (key.properties)
python g:\00_project\android-planlet\tools\play_upload.py `
  --key  g:\00_project\android-planlet\keys\android-ai-apis-1a2367ba7888.json `
  --aab  g:\00_project\chat_grok\build\app\outputs\bundle\release\app-release.aab `
  --package com.onethelab.simplechatbot --track internal --status completed --notes "..."
```
First-ever release must be `--status draft` then released once in console; after
that `completed` works. Currently versionCode 2 is live on internal.

## SHA-1s for Google OAuth (Android client, package com.onethelab.simplechatbot)
Native Google sign-in checks (package + signing SHA-1). Register the one matching
how the app is installed:
- debug (`flutter run`): `94:75:47:A4:48:B0:7A:78:0E:38:AE:F1:34:56:F2:5E:97:E4:DD:70`
- upload key (`flutter install --release`): `01:FA:B6:03:44:2D:D5:15:90:BD:9C:0C:F2:33:5D:48:D1:1B:25:CA`
- **Play build (internal testing): Play App Signing SHA-1** (Play Console → 앱 무결성).

## Gotchas
- **Never `supabase config push`** — shared project; it overwrites auth config.
  Change auth in the dashboard. (An earlier push may have altered Planlet's auth —
  see auto-memory.)
- **IAP only works on Play-installed builds** (Play App Signing), not sideloads.
- **New app/product IAP propagation takes ~24–48h** — `product not found` right
  after creating a product is usually just propagation, not a bug.
- `flutter test` and a build at the same time → sqlite3.dll conflict; run serially.
- PowerShell here-strings for `git commit -m` are flaky; commit via `-F <file>` or
  the Bash tool heredoc.

## Verify status quickly
`supabase functions list` · device: install from Play internal-testing link,
log in with a license-tester Google account, send a chat (credits deduct), open
크레딧 → 충전 (IAP). Use the in-app **로그** to debug release builds.
