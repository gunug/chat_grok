# 과청구 · API 사용료 누수 점검 (chat_grok)

크레딧 차감/고지와 provider 과금 지점을 대조한 감사 결과와 해결 순서.
대상: `supabase/functions/chat`, `supabase/functions/image`, 공유 `cg_models`/크레딧 RPC.

> 전제: 사용자 **잔액은 항상 서버 권위값**(`app_service_credits`)이고 앱은 `refreshCredit()`로
> 정정하므로, "잔액이 몰래 크게 빠지는" 치명적 누락은 없다. 실질 리스크는 아래 항목들.

## 이미 해결된 항목 (2026-06-16)
- **B5(과거)** 이미지 `compose`: grok-3 성공 시 빈 프롬프트여도 먼저 차감 후 502. (누수 제거)
- **C1(과거)** chat: 차감 이후 `cg_pending_chat` done-갱신 실패가 `error`로 번져 재전송→이중과금 되던 경로를 best-effort로 차단.
- **B3(과거)** `cg_models`에 `provider='openai'`면 단가 NOT NULL CHECK 제약. (단가 누락 leak 방지)

---

## A. 과청구 (사용자가 더 내거나 잘못 내는 경우)
| # | 상황 | 심각도 | 비고 |
|---|---|---|---|
| A1 | **이미지 render 멱등키 없음** — 타임아웃/더블탭으로 render 2회 호출 시 매번 $0.05 차감(채팅은 requestId로 차단, 이미지는 미적용) | 중 (이미지 UI 현재 숨김) | render에 requestId 도입 |
| A2 | **compose 차감 후 취소 반복** — 이미지 버튼 누를 때마다 grok-3 compose 과금, 반복 시 누적 | 저 (고지됨, 숨김) | 빈도 제한 고려 |
| A3 | **올림(ceil) 이중 적용** — `cost_micros`도 ceil, `app_usage_credits`도 ceil → 매 호출 1크레딧 미만씩 항상 올림 | 저 (의도된 보수적 과금) | 인지만 |
| A4 | **이미지=2회 과금 인식차** — compose+render 2번 차감을 "1장=1회"로 기대하면 과청구로 느낌 | 저 (다이얼로그 고지) | 투명성으로 완화 |

## B. 누수 (우리가 API 비용을 떠안는 경우)
| # | 상황 | 심각도 | 비고 |
|---|---|---|---|
| B1 | **usage 청크 도착 전 스트림 종료/파싱 실패** → `capturedUsage=null` → 차감 0, provider는 생성분 청구 가능 | 저 (드묾) | 토큰 수 미상이라 정확 청구 불가 |
| B2 | **`app_record_usage` RPC 예외** → catch 로그만, 차감 0 | 저 (DB 장애 한정) | 재시도/알림 미적용 |
| B3 | **`waitUntil` 한도로 finalize 전 종료** → 차감 0(행 streaming 잔존) | 저 (초장문 응답) | 모니터링만 가능 |
| B4 | **xAI가 `cost_in_usd_ticks` 미반환** → grok 모델 cost 0 차감 | 저 | provider 동작 의존 |
| B5 | **trial 크레딧 파밍** — Google 계정마다 300 체험 크레딧 → 다계정 무료 사용 | **중~상** | 제품 레벨 누수 |
| B6 | **음수 잔액 초과사용** — 게이트가 `잔액≥1`이라 잔액 1에서 비싼 호출 1건이 음수로(다음 충전 때 상계, 이탈 시 실손) | 저 | |

## C. 양방향 — 단가표 드리프트 (가장 큰 구조적 리스크)
OpenAI는 응답에 USD를 안 줘서 **`cg_models` 단가표로 환산**한다. 따라서 표 단가 ≠ 실제 OpenAI 청구가이면:
- 표가 높으면 → **사용자 과청구**, 낮으면 → **우리 누수**(마진 잠식),
- 캐시 단가/캐시 토큰 가정이 실제와 다르면 양쪽 어긋남.
- OpenAI가 가격 변경/모델 추가했는데 표를 안 고치면 **모든 OpenAI 호출이 조용히 오청구**. (xAI는 실비 ticks라 무관)

---

## 해결 순서 TODO

### 우선순위 1 — 실질 리스크
- [ ] **B5 trial 파밍 방지** — 체험 크레딧 축소 또는 계정/디바이스 제한(전화 인증, 디바이스당 1회 등) 정책 결정·적용.
- [ ] **C 단가표 드리프트 운영** — `cg_models` 단가 주기 점검 체크리스트화 + 월 1회 OpenAI 실청구(Costs API)와 대조. (담당/주기 명시)

### 우선순위 2 — 이미지 재활성화 전 처리
- [ ] **A1 이미지 render 멱등키** — render 요청에 `requestId` 도입(채팅과 동일 패턴), 중복 호출 시 저장 결과 재생.
- [ ] **A2 compose 빈도 제한** — 동일 대화 짧은 시간 내 compose 재호출 캐시/제한 검토.

### 우선순위 3 — 견고화(저위험)
- [ ] **B2 RPC 실패 보강** — `app_record_usage` 1회 재시도 + 실패를 눈에 띄게(로그/별도 실패 테이블/알림).
- [ ] **B6 게이트 강화** — 음수 잔액 방지(예: 예상 최소비용 이상일 때만 통과) 검토.

### 우선순위 4 — 모니터링(근본 해결 어려움)
- [ ] **B1/B3/B4 탐지** — `usage` 없는 `done` / `streaming` 잔존 행 / cost 0 차감 건을 로그·집계해 누수 가시화.
- [ ] **A3 라운딩 정책 확인** — ceil 이중 적용이 의도와 맞는지 확정(필요 시 `app_usage_credits` 한 곳만 조정 → 전 앱 공통 반영).

---

## 관련
- 공유 단가표 사용법: [shared-model-pricing.md](shared-model-pricing.md)
- 멀티 provider 구조: 메모리 `multi-provider-models`
- 서버-완료-저장: 메모리 `chat-server-complete-store`
