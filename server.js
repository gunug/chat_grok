import express from 'express';
import dotenv from 'dotenv';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

dotenv.config();

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const PORT = process.env.PORT || 3000;
const XAI_API_KEY = process.env.XAI_API_KEY;
const XAI_BASE_URL = process.env.XAI_BASE_URL || 'https://api.x.ai/v1';
const XAI_MODEL = process.env.XAI_MODEL || 'grok-3';
const SYSTEM_PROMPT =
  process.env.SYSTEM_PROMPT ||
  'You are Grok, a helpful and witty AI assistant. Answer clearly and concisely.';

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
    return res
      .status(500)
      .json({ error: 'XAI_API_KEY is not set. Add it to your .env file.' });
  }

  const { messages } = req.body || {};
  if (!Array.isArray(messages) || messages.length === 0) {
    return res.status(400).json({ error: 'messages[] is required.' });
  }

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
  req.on('close', () => upstream.abort());

  try {
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
      }),
      signal: upstream.signal,
    });

    if (!apiRes.ok || !apiRes.body) {
      const detail = await apiRes.text().catch(() => '');
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
          const delta = json.choices?.[0]?.delta?.content;
          if (delta) {
            res.write(`data: ${JSON.stringify({ delta })}\n\n`);
          }
        } catch {
          // Ignore keep-alive / non-JSON lines.
        }
      }
    }

    res.write('event: done\ndata: {}\n\n');
    res.end();
  } catch (err) {
    if (upstream.signal.aborted) return; // Client navigated away.
    res.write(
      `event: error\ndata: ${JSON.stringify({ error: err.message })}\n\n`,
    );
    res.end();
  }
});

app.listen(PORT, () => {
  console.log(`\n  Chat Grok running:  http://localhost:${PORT}`);
  console.log(`  Model:              ${XAI_MODEL}`);
  console.log(
    `  API key:            ${XAI_API_KEY ? 'loaded' : 'MISSING (set XAI_API_KEY in .env)'}\n`,
  );
});
