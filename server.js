import express from 'express';
import dotenv from 'dotenv';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { exec } from 'node:child_process';

dotenv.config();

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const PORT = process.env.PORT || 3000;
const XAI_API_KEY = process.env.XAI_API_KEY;
const XAI_BASE_URL = process.env.XAI_BASE_URL || 'https://api.x.ai/v1';
const XAI_MODEL = process.env.XAI_MODEL || 'grok-3';
const SYSTEM_PROMPT =
  process.env.SYSTEM_PROMPT ||
  'You are Grok, a helpful and witty AI assistant. Answer clearly and concisely.';

// Timestamped console logger so the cmd window shows request progress.
function log(...args) {
  const t = new Date().toLocaleTimeString();
  console.log(`  [${t}]`, ...args);
}

const app = express();
app.use(express.json({ limit: '1mb' }));
app.use(express.static(path.join(__dirname, 'public')));

// Health/config check the frontend can use.
app.get('/api/config', (req, res) => {
  res.json({
    model: XAI_MODEL,
    configured: Boolean(XAI_API_KEY),
  });
});

// Chat endpoint — streams the model response back to the browser via SSE.
app.post('/api/chat', async (req, res) => {
  if (!XAI_API_KEY) {
    log('요청 거부: XAI_API_KEY 미설정 (.env 확인)');
    return res
      .status(500)
      .json({ error: 'XAI_API_KEY is not set. Add it to your .env file.' });
  }

  const { messages } = req.body || {};
  if (!Array.isArray(messages) || messages.length === 0) {
    log('요청 거부: messages 비어있음 (400)');
    return res.status(400).json({ error: 'messages[] is required.' });
  }

  const lastUser = [...messages].reverse().find((m) => m.role === 'user');
  log(
    `채팅 요청 수신: ${messages.length}개 메시지` +
      (lastUser ? ` | "${lastUser.content.slice(0, 40).replace(/\s+/g, ' ')}"` : ''),
  );

  // Prepend the system prompt unless the client already sent one.
  const payloadMessages =
    messages[0]?.role === 'system'
      ? messages
      : [{ role: 'system', content: SYSTEM_PROMPT }, ...messages];

  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders?.();

  const upstream = new AbortController();
  let clientClosed = false;
  // Detect a real client disconnect via the RESPONSE stream. (req's 'close'
  // fires as soon as express.json() finishes reading the body, which would
  // abort the xAI call immediately — that was the "no answer" bug.)
  res.on('close', () => {
    if (!res.writableEnded) {
      clientClosed = true;
      upstream.abort();
    }
  });

  try {
    log(`xAI 호출 중... (model=${XAI_MODEL}, ${XAI_BASE_URL})`);
    const apiRes = await fetch(`${XAI_BASE_URL}/chat/completions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${XAI_API_KEY}`,
      },
      body: JSON.stringify({
        model: XAI_MODEL,
        messages: payloadMessages,
        stream: true,
        // Ask xAI to append a final chunk containing token usage.
        stream_options: { include_usage: true },
      }),
      signal: upstream.signal,
    });

    log(`xAI 응답 상태: ${apiRes.status} ${apiRes.statusText}`);

    if (!apiRes.ok || !apiRes.body) {
      const detail = await apiRes.text().catch(() => '');
      log(`xAI 에러 본문: ${detail.slice(0, 300) || '(없음)'}`);
      res.write(
        `event: error\ndata: ${JSON.stringify({
          error: `xAI API error (${apiRes.status})`,
          detail: detail.slice(0, 500),
        })}\n\n`,
      );
      return res.end();
    }

    // The xAI API is OpenAI-compatible: it sends "data: {json}\n\n" chunks
    // ending with "data: [DONE]". Re-parse and forward only the text deltas.
    const reader = apiRes.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';
    let chars = 0;
    let firstTokenLogged = false;
    let usage = null;

    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });

      const lines = buffer.split('\n');
      buffer = lines.pop() ?? '';

      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed.startsWith('data:')) continue;
        const data = trimmed.slice(5).trim();
        if (data === '[DONE]') continue;
        try {
          const json = JSON.parse(data);
          if (json.usage) usage = json.usage; // final usage chunk
          const delta = json.choices?.[0]?.delta?.content;
          if (delta) {
            if (!firstTokenLogged) {
              log('스트리밍 시작 (첫 토큰 수신)');
              firstTokenLogged = true;
            }
            chars += delta.length;
            res.write(`data: ${JSON.stringify({ delta })}\n\n`);
          }
        } catch {
          // Ignore keep-alive / non-JSON lines.
        }
      }
    }

    if (!firstTokenLogged) log('경고: 본문은 200이나 텍스트 토큰이 없었습니다.');
    log(`응답 완료: ${chars}자 전송`);

    if (usage) {
      const cached = usage.prompt_tokens_details?.cached_tokens ?? 0;
      const reasoning = usage.completion_tokens_details?.reasoning_tokens ?? 0;
      // xAI returns its own computed cost in "USD ticks"; 1 USD = 1e10 ticks.
      // (Verified against grok-4.3 pricing: $1.25/$0.20 cached input, $2.50 output per 1M.)
      const costUsd =
        usage.cost_in_usd_ticks != null ? usage.cost_in_usd_ticks / 1e10 : null;
      log(
        `토큰 사용량: prompt=${usage.prompt_tokens} (cached ${cached}), ` +
          `completion=${usage.completion_tokens} (reasoning ${reasoning}), ` +
          `total=${usage.total_tokens}` +
          (costUsd != null ? ` | 비용=$${costUsd.toFixed(6)}` : ''),
      );
      res.write(
        `event: usage\ndata: ${JSON.stringify({
          prompt: usage.prompt_tokens,
          completion: usage.completion_tokens,
          total: usage.total_tokens,
          cached,
          reasoning,
          costUsd,
        })}\n\n`,
      );
    }

    res.write('event: done\ndata: {}\n\n');
    res.end();
  } catch (err) {
    if (clientClosed || upstream.signal.aborted) {
      log('클라이언트 연결 종료(요청 취소).');
      return;
    }
    log(`오류: ${err.message}`);
    res.write(
      `event: error\ndata: ${JSON.stringify({ error: err.message })}\n\n`,
    );
    res.end();
  }
});

// Open the default browser at the URL the server actually bound to.
function openBrowser(url) {
  const cmd =
    process.platform === 'win32'
      ? `start "" "${url}"`
      : process.platform === 'darwin'
        ? `open "${url}"`
        : `xdg-open "${url}"`;
  exec(cmd, () => {});
}

// Try PORT; if it's already in use, fall back to the next port (up to 10 tries).
function startServer(port, attemptsLeft) {
  const server = app.listen(port);

  server.on('listening', () => {
    const url = `http://localhost:${port}`;
    console.log(`\n  Chat Grok running:  ${url}`);
    console.log(`  Model:              ${XAI_MODEL}`);
    console.log(
      `  API key:            ${XAI_API_KEY ? 'loaded' : 'MISSING (set XAI_API_KEY in .env)'}`,
    );
    console.log(`\n  >> 서버 실행 중입니다. 이 창을 닫지 말고 열어두세요.`);
    console.log(`  >> 브라우저에서 ${url} 로 접속하세요 (자동으로 열립니다).`);
    console.log(`  >> 종료하려면 이 창에서 Ctrl+C 를 누르세요.\n`);
    // Only auto-open when launched via start.bat (OPEN_BROWSER=1).
    if (process.env.OPEN_BROWSER === '1') openBrowser(url);
  });

  server.on('error', (err) => {
    if (err.code === 'EADDRINUSE' && attemptsLeft > 0) {
      console.warn(`  [warn] port ${port} is in use - trying ${port + 1} ...`);
      startServer(port + 1, attemptsLeft - 1);
    } else {
      console.error(`  [ERROR] ${err.message}`);
      process.exit(1);
    }
  });
}

startServer(Number(PORT), 10);
