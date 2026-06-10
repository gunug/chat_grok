# chat_grok — 공유 크레딧 플랫폼 적용 가이드

chat_grok과 Planlet은 **하나의 Supabase 프로젝트(`oerrgsanrnelhvgikgkv`)** 를 공유한다.
크레딧/사용량/등록은 `public.app_*` 테이블에 **`service_key`로 앱별 분리**되어 있다
(설계 전체는 android-planlet의 `docs/platform-architecture.md`). 이 문서는 chat_grok의
`chat` Edge Function과 앱이 그 레이어를 쓰도록 바꾸는 방법이다.

> 전제: `app_*` 테이블 + RPC는 **이미 배포됨**. chat_grok은 `service_key = 'chat_grok'`
> 으로 등록되어 있다. 추가 마이그레이션 불필요 — **함수/앱만 수정**하면 된다.

---

## 0. 현재 상태 / 바꿀 점
- `supabase/functions/chat/index.ts` 는 지금 **사용자 인증이 전혀 없다**(그냥 xAI 프록시).
  크레딧을 받으려면 **① 사용자 식별 ② 잔액 게이트 ③ 사용 후 차감** 을 넣어야 한다.
- 시크릿은 추가 불필요: `XAI_API_KEY`는 이미 있고, `SUPABASE_URL` /
  `SUPABASE_SERVICE_ROLE_KEY` / `SUPABASE_ANON_KEY`는 함수에 자동 주입된다.

## 1. Edge Function 수정 (`chat/index.ts`)

### 1-a. 상단에 상수 + import 추가
```ts
import { createClient } from "jsr:@supabase/supabase-js@2";

const SERVICE_KEY = "chat_grok";
const TRIAL_MICROS = 100_000;       // $0.10 첫 사용 체험 (조정 가능)
const MIN_BALANCE_MICROS = 20_000;  // 호출 전 최소 잔액 버퍼
```

### 1-b. 핸들러에서 xAI 호출 **전에** 인증 + 잔액 게이트
`messages` 파싱 직후, `fetch(... XAI ...)` 전에 삽입:
```ts
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// 사용자 식별 (JWT는 사용자만 식별 — service_key는 위 상수로 고정)
const authHeader = req.headers.get("Authorization") ?? "";
const userClient = createClient(SUPABASE_URL, ANON, {
  global: { headers: { Authorization: authHeader } },
});
const { data: { user } } = await userClient.auth.getUser();
if (!user) return json({ error: "unauthorized" }, 401);

const admin = createClient(SUPABASE_URL, SERVICE_ROLE);

// 첫 사용 시 등록 + 체험크레딧, 그다음 잔액 게이트
await admin.rpc("app_register_service", {
  p_user: user.id, p_service: SERVICE_KEY, p_trial_micros: TRIAL_MICROS,
});
const { data: credit } = await admin
  .from("app_service_credits").select("balance_micros")
  .eq("user_id", user.id).eq("service_key", SERVICE_KEY).maybeSingle();
const balance = credit?.balance_micros ?? 0;
if (balance < MIN_BALANCE_MICROS) {
  return json({ error: "insufficient_credit", balanceMicros: balance }, 402);
}
```

### 1-c. 스트림의 usage 청크에서 **실제 비용 차감**
chat_grok은 이미 xAI의 `cost_in_usd_ticks`(1 USD = 1e10 ticks)를 받는다 — 이게 정확한
원가다. `if (chunk.usage) { ... }` 블록 안에 추가:
```ts
const costUsd = u.cost_in_usd_ticks != null ? u.cost_in_usd_ticks / 1e10 : 0;
const costMicros = Math.ceil(costUsd * 1e6);
// 차감 + 로그 (스트림 내 비동기 호출)
admin.rpc("app_record_usage", {
  p_user: user.id, p_service: SERVICE_KEY, p_provider: "xai", p_model: XAI_MODEL,
  p_action: "chat",
  p_prompt_tokens: u.prompt_tokens ?? 0,
  p_completion_tokens: u.completion_tokens ?? 0,
  p_cost_micros: costMicros,
}).then(({ data }) => {
  // 선택: 남은 잔액을 usage 이벤트에 실어 보내려면 여기서 send(...)
});
```
> `user`/`admin`을 `ReadableStream` 콜백에서 쓰려면 둘 다 핸들러 스코프에 선언되어
> 있으면 된다(위 1-b가 그렇게 함). 클로저로 자연히 잡힌다.

### 1-d. 배포
```powershell
# chat_grok 폴더에서 (이 프로젝트에 link 되어 있음)
supabase functions deploy chat
```

## 2. 앱(Flutter) 수정

### 2-a. 익명 세션 보장 + JWT 전송
크레딧은 사용자 단위라 **세션이 있어야** 한다. 앱 시작 시:
```dart
final auth = Supabase.instance.client.auth;
if (auth.currentSession == null) {
  await auth.signInAnonymously();   // 대시보드에서 Anonymous 이미 ON
}
```
`chat` 함수 호출 시 `Authorization: Bearer <accessToken>` 를 보낸다(현재 `chat_service.dart`
가 `accessToken ?? anonKey`를 쓰는데, **세션이 있으면 accessToken**이 가도록).

### 2-b. 크레딧 페이지 (자기 행은 RLS로 직접 read)
```dart
final c = await Supabase.instance.client
  .from('app_service_credits')
  .select('balance_micros, total_purchased_micros, total_spent_micros')
  .eq('service_key', 'chat_grok')
  .maybeSingle();
final balanceUsd = (c?['balance_micros'] ?? 0) / 1e6;       // 잔액
final spentUsd   = (c?['total_spent_micros'] ?? 0) / 1e6;   // 사용
final paidUsd    = (c?['total_purchased_micros'] ?? 0) / 1e6; // 결제(크레딧)
```
402(`insufficient_credit`) 응답이 오면 충전 화면으로 유도.

## 3. 가격 / 마진 (앱토큰)
- **차감은 항상 원가**(`app_record_usage`의 cost_micros = xAI 실제 비용). Planlet과 동일.
- **마진은 충전 비율에 둔다**: 사용자가 Play Billing으로 X원 결제 → `app_top_up(amount=결제액,
  credit=원가예산)` 에서 `credit = 결제액 / (1+마진)` 으로 크레딧을 적게 준다. 차액이 마진.
  → 사용 차감 로직은 두 앱 공통(원가)이라 단순하고, 마진은 판매 시점에만 산다.

## 4. 결제 (다음 단계)
Play Billing 구매 → 검증 함수가 `app_top_up(user, 'chat_grok', 'play', purchaseToken,
amount, credit)` 호출(멱등). Planlet과 동일 패턴 — 한쪽 만들면 복붙.

## 5. 주의
- **`supabase config push` 절대 금지**(공유 프로젝트 auth 설정 덮어씀). auth 변경은 대시보드.
- service_key는 **함수 상수로만**(클라이언트가 보낸 값 신뢰 금지) → 청구 위조 방지.
- 익명 유저는 기기 단위라, "한 사람이 두 앱"의 의미는 실제 로그인 도입 후 발현.
