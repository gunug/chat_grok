# Chat Grok (Android · Flutter)

xAI **Grok** 챗봇 안드로이드 앱입니다. xAI API 키는 앱에 들어가지 않고,
**Supabase Edge Function**이 대신 호출합니다.

```
Flutter 앱(Android)  ──►  Supabase Edge Function "chat"  ──►  xAI API
        │                    (XAI_API_KEY 시크릿 보관)
        └ 앱에는 Supabase URL + anon key만 저장(공개돼도 안전)
```

- 키는 기기/소스/GitHub 어디에도 노출되지 않음 (Supabase 시크릿에만 존재)
- 스트리밍 응답, 여러 대화 저장, 자동 제목, 삭제, **토큰·USD 비용 표시**, 내보내기(공유)

## 구조

```
chat_grok/
├─ lib/
│  ├─ main.dart            앱·채팅 화면(드로어/말풍선/입력)
│  ├─ models.dart          Conversation / Message / usage 모델
│  ├─ storage.dart         shared_preferences 저장(대화 + 설정)
│  ├─ chat_service.dart    Supabase 함수로 SSE 스트리밍 호출
│  └─ settings_screen.dart Supabase URL / anon key 입력
├─ supabase/
│  ├─ config.toml          functions.chat 설정
│  └─ functions/chat/index.ts   xAI 프록시 + 스트리밍(Deno/TS)
└─ android/                안드로이드 설정(INTERNET 권한, 앱 이름)
```

---

## 1) Supabase 백엔드 배포 (최초 1회)

> xAI 키 발급: https://console.x.ai · Supabase 가입: https://supabase.com

```powershell
# 0. CLI 로그인 (브라우저 인증)
supabase login

# 1. 프로젝트 연결 (대시보드 URL의 project ref)
supabase link --project-ref <YOUR_PROJECT_REF>

# 2. xAI 키를 시크릿으로 등록 (앱에는 안 들어감)
supabase secrets set XAI_API_KEY=xai-xxxxxxxx
#   선택: 모델 변경
#   supabase secrets set XAI_MODEL=grok-3

# 3. 함수 배포
supabase functions deploy chat
```

배포 후 함수 주소는 `https://<project-ref>.supabase.co/functions/v1/chat` 입니다.

## 2) 앱 빌드 & 설치

```powershell
flutter pub get

# 연결된 기기/에뮬레이터에서 실행
flutter run

# 또는 설치용 APK 빌드
flutter build apk --release
#  → build\app\outputs\flutter-apk\app-release.apk
#  기기에 설치:
flutter install        # USB 연결 시
#  또는 위 .apk 파일을 폰으로 전송해서 설치
```

## 3) 앱에서 연결 설정 (최초 1회)

앱 실행 → 우상단 ⋮ → **설정**에서 입력:
- **Project URL**: `https://<project-ref>.supabase.co`
- **anon public key**: Supabase 대시보드 → Project Settings → API → `anon public`

저장하면 바로 채팅할 수 있습니다.

---

## 환경변수(Supabase 시크릿)

| 시크릿          | 기본값                | 설명             |
| --------------- | --------------------- | ---------------- |
| `XAI_API_KEY`   | (필수)                | xAI API 키       |
| `XAI_MODEL`     | `grok-3`              | 사용할 모델      |
| `XAI_BASE_URL`  | `https://api.x.ai/v1` | API 엔드포인트   |
| `SYSTEM_PROMPT` | (기본 프롬프트)       | 시스템 프롬프트  |

## 참고

- 대화 기록은 **기기 내부(shared_preferences)** 에 저장됩니다. 앱 삭제 시 사라집니다.
- 비용(`cost_in_usd_ticks`)은 xAI가 직접 계산한 값(1 USD = 1e10 ticks)으로, grok-4.3 가격으로 검증됨.
- 웹(Node) 버전은 git 이력에서 확인할 수 있습니다.
