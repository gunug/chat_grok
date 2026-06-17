# 공유 모델 단가표(`cg_models`) — 다른 앱에서 사용하기

같은 Supabase 프로젝트(`oerrgsanrnelhvgikgkv`)를 공유하는 다른 앱이 chat_grok이 만든
**OpenAI/xAI 모델 카탈로그 + 단가표**를 그대로 재사용하는 방법.

- 소유: chat_grok (`cg_` 접두사). 위치: `public.cg_models`.
- 정의 마이그레이션: `android-planlet/supabase/migrations/20260616010000_cg_models.sql`
- 단가 단위: **1,000,000 토큰당 USD**. 마크업은 들어있지 않은 **원가**.

## 테이블 스키마
| 컬럼 | 의미 |
|---|---|
| `id` | provider에 보낼 모델 id (PK). 예: `gpt-4.1-mini`, `grok-4` |
| `provider` | `openai` \| `xai` |
| `label` | 표시용 이름 |
| `input_per_mtok` | 입력 1M 토큰당 USD. **NULL이면 provider가 응답에 원가를 줌**(xAI ticks) |
| `output_per_mtok` | 출력 1M 토큰당 USD |
| `cached_input_per_mtok` | 캐시 입력 1M 토큰당 USD (NULL이면 입력 단가와 동일) |
| `enabled` | 노출/사용 가능 여부 |
| `sort` | 정렬 순서 |

## 접근 권한 (이미 공유됨)
`public` 스키마 테이블이라 같은 프로젝트의 어떤 앱이든 접근할 수 있다.

| 호출 주체 | 접근 범위 | 비고 |
|---|---|---|
| 다른 앱의 **Edge Function** (service_role 키) | **전체 행** | RLS 우회 — 서버 측 사용은 이걸로 |
| 다른 앱의 **클라이언트** (로그인 사용자 JWT) | `enabled = true` 행만 | RLS 정책 `to authenticated` |
| 비로그인(anon) | 차단 | grant는 있으나 정책 없음 → 0행 |

### 읽기 예시
```js
// 서버(Edge Function) — service_role: 전체 행
const { data: m } = await admin
  .from("cg_models")
  .select("provider, input_per_mtok, output_per_mtok, cached_input_per_mtok")
  .eq("id", model).maybeSingle();
```
```js
// 클라이언트(supabase-js) — 로그인 사용자: enabled 행
const { data } = await supabase
  .from("cg_models").select("id, provider, label").order("sort");
```
```
# REST
GET /rest/v1/cg_models?id=eq.gpt-4.1-mini&select=*
Authorization: Bearer <user JWT>
apikey: <anon key>
```

## 비용 계산
> **중요:** 순정 OpenAI 응답에는 USD가 없고 **토큰만** 온다(xAI의 `cost_in_usd_ticks`는 xAI 전용 확장).
> 따라서 OpenAI는 토큰 × 단가로 환산해야 한다.

공식(캐시 입력은 할인 단가 적용):
```
cost_usd =  max(prompt_tokens - cached_tokens, 0)/1e6 * input_per_mtok
          + cached_tokens/1e6                        * (cached_input_per_mtok ?? input_per_mtok)
          + completion_tokens/1e6                     * output_per_mtok
```
- xAI 모델은 `input_per_mtok`이 NULL → 위 공식을 쓰지 말고 응답의 `usage.cost_in_usd_ticks / 1e10`을 원가로 사용.

### 방법 A — 각 앱이 직접 계산
단가만 읽어 위 공식을 자기 함수에서 계산. 간단하지만 공식이 앱마다 복붙되어
드리프트(캐시 할인 누락, xAI 분기 실수 등) 위험이 있다.

### 방법 B — 공유 RPC로 계산까지 공통화 (권장)
플랫폼이 `app_usage_credits(원가→크레딧)`를 공유하듯, **`토큰→원가(micro-USD)`도
공유 SQL 함수**로 두면 어떤 앱이든 한 줄로 끝난다. (아직 미적용 — 도입 시 아래 마이그레이션)

```sql
create or replace function public.app_model_cost_micros(
  p_model text, p_prompt_tokens int, p_cached_tokens int, p_completion_tokens int
) returns bigint language sql stable security definer set search_path = public as $$
  select ceil(1e6 * (
      greatest(p_prompt_tokens - coalesce(p_cached_tokens,0),0)/1e6 * input_per_mtok
    + coalesce(p_cached_tokens,0)/1e6 * coalesce(cached_input_per_mtok, input_per_mtok)
    + p_completion_tokens/1e6 * output_per_mtok
  ))::bigint
  from public.cg_models
  where id = p_model and input_per_mtok is not null;  -- xAI(단가 NULL) → null 반환 → ticks 사용
$$;
grant execute on function public.app_model_cost_micros(text,int,int,int)
  to authenticated, service_role;
```
사용:
```js
const { data: micros } = await admin.rpc("app_model_cost_micros", {
  p_model: model,
  p_prompt_tokens: u.prompt_tokens,
  p_cached_tokens: u.prompt_tokens_details?.cached_tokens ?? 0,
  p_completion_tokens: u.completion_tokens,
});
// micros == null 이면 xAI → costUsd = u.cost_in_usd_ticks / 1e10 로 대체
await admin.rpc("app_record_usage", { /* ... */, p_cost_micros: micros ?? Math.ceil(costUsd*1e6) });
```

## 마크업은 자동
원가(micro-USD)만 `app_record_usage`에 넘기면, 플랫폼이 `app_usage_credits`로
판매배율(`app_pricing.sell_multiple_pct`)을 적용해 크레딧을 차감한다.
→ **다른 앱도 원가만 넘기면 동일 과금 정책**을 그대로 따른다(자체 단가 로직 불필요).

## 모델 추가/수정
`cg_models` 행을 바꾸면 함수·앱이 즉시 반영(재배포 불필요).
```sql
insert into public.cg_models (id, provider, label, input_per_mtok, output_per_mtok, cached_input_per_mtok, sort)
values ('gpt-4o', 'openai', 'GPT-4o', 2.50, 10.0, 1.25, 50)
on conflict (id) do update set
  input_per_mtok = excluded.input_per_mtok,
  output_per_mtok = excluded.output_per_mtok,
  cached_input_per_mtok = excluded.cached_input_per_mtok;
```
단가 출처(2026-06): OpenAI <https://www.aipricing.guru/openai-pricing/> · xAI <https://www.aipricing.guru/xai-pricing/>

## 네이밍/소유권
- `cg_` = chat_grok 소유. 여러 앱의 **공식 공용 단가표**로 승격하려면
  `app_model_pricing`(플랫폼/android-planlet 소유)으로 옮기고 `cg_models`는 호환 뷰로
  별칭 처리하는 방법도 있다. 당장은 그대로 두고 "공유 단가표"로 사용해도 무방.

## 관련 문서/메모리
- chat 멀티 provider 구조: 메모리 `multi-provider-models`
- 서버-완료-저장(백그라운드): 메모리 `chat-server-complete-store`
- 플랫폼 크레딧/단가: `android-planlet/docs/backend-supabase.md`, `supabase/migrations/*`
