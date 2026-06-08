# Chat Grok

Node.js(Express) 웹서버 + 채팅 UI로 xAI **Grok** API를 사용하는 챗봇입니다.
응답은 SSE 스트리밍으로 실시간 표시됩니다.

## 구조

```
chat_grok/
├─ server.js          Express 서버 + /api/chat 스트리밍 프록시
├─ public/
│  ├─ index.html      채팅 화면
│  ├─ style.css       다크 테마 스타일
│  └─ app.js          프론트엔드 로직 (스트리밍 수신)
├─ .env               환경변수 (API 키) — git에 올리지 마세요
└─ package.json
```

## 실행 방법

1. 의존성 설치
   ```bash
   npm install
   ```

2. API 키 설정 — `.env` 파일을 열어 본인의 xAI 키를 입력
   ```
   XAI_API_KEY=xai-xxxxxxxxxxxxxxxx
   ```
   키 발급: https://console.x.ai

3. 서버 실행
   ```bash
   npm start
   ```
   개발 중 자동 재시작이 필요하면 `npm run dev`

4. 브라우저에서 http://localhost:3000 접속

## 환경변수

| 변수            | 기본값                  | 설명                          |
| --------------- | ----------------------- | ----------------------------- |
| `XAI_API_KEY`   | (필수)                  | xAI API 키                    |
| `XAI_MODEL`     | `grok-3`                | 사용할 모델                   |
| `XAI_BASE_URL`  | `https://api.x.ai/v1`   | API 엔드포인트                |
| `PORT`          | `3000`                  | 서버 포트                     |
| `SYSTEM_PROMPT` | (기본 프롬프트)         | 시스템 프롬프트               |

## 참고

- xAI API는 OpenAI 호환 형식입니다 (`/chat/completions`).
- 대화 기록은 브라우저 메모리에만 유지되며, 새로고침 시 초기화됩니다.
