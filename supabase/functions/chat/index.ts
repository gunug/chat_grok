// Supabase Edge Function: "chat"
// Proxies chat requests to the xAI (Grok) API and streams the answer back as
// Server-Sent Events. The xAI API key lives only as a Supabase secret
// (XAI_API_KEY) and never reaches the mobile app.

const XAI_BASE_URL = Deno.env.get("XAI_BASE_URL") ?? "https://api.x.ai/v1";
const XAI_MODEL = Deno.env.get("XAI_MODEL") ?? "grok-3";
const SYSTEM_PROMPT = Deno.env.get("SYSTEM_PROMPT") ??
  "You are Grok, a helpful and witty AI assistant. Answer clearly and concisely.";

const cors: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const XAI_API_KEY = Deno.env.get("XAI_API_KEY");
  if (!XAI_API_KEY) {
    return json(
      { error: "XAI_API_KEY secret is not set (supabase secrets set ...)." },
      500,
    );
  }

  let messages: Array<{ role: string; content: string }> | undefined;
  try {
    ({ messages } = await req.json());
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }
  if (!Array.isArray(messages) || messages.length === 0) {
    return json({ error: "messages[] is required" }, 400);
  }

  // Prepend the system prompt unless the client already sent one.
  const payloadMessages = messages[0]?.role === "system"
    ? messages
    : [{ role: "system", content: SYSTEM_PROMPT }, ...messages];

  const upstream = await fetch(`${XAI_BASE_URL}/chat/completions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${XAI_API_KEY}`,
    },
    body: JSON.stringify({
      model: XAI_MODEL,
      messages: payloadMessages,
      stream: true,
      stream_options: { include_usage: true },
    }),
  });

  if (!upstream.ok || !upstream.body) {
    const detail = await upstream.text().catch(() => "");
    return json(
      { error: `xAI API error (${upstream.status})`, detail: detail.slice(0, 500) },
      502,
    );
  }

  // Re-parse xAI's OpenAI-compatible stream and emit our own SSE events:
  //   data: {delta}        text chunks
  //   event: usage         token usage + cost
  //   event: done          end of stream
  //   event: error         failure mid-stream
  const stream = new ReadableStream({
    async start(controller) {
      const enc = new TextEncoder();
      const dec = new TextDecoder();
      const reader = upstream.body!.getReader();
      let buffer = "";
      const send = (s: string) => controller.enqueue(enc.encode(s));

      try {
        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          buffer += dec.decode(value, { stream: true });

          const lines = buffer.split("\n");
          buffer = lines.pop() ?? "";

          for (const line of lines) {
            const t = line.trim();
            if (!t.startsWith("data:")) continue;
            const data = t.slice(5).trim();
            if (data === "[DONE]") continue;
            try {
              const chunk = JSON.parse(data);
              if (chunk.usage) {
                const u = chunk.usage;
                send(
                  `event: usage\ndata: ${JSON.stringify({
                    prompt: u.prompt_tokens,
                    completion: u.completion_tokens,
                    total: u.total_tokens,
                    cached: u.prompt_tokens_details?.cached_tokens ?? 0,
                    reasoning: u.completion_tokens_details?.reasoning_tokens ?? 0,
                    // xAI returns its own cost; 1 USD = 1e10 ticks.
                    costUsd: u.cost_in_usd_ticks != null
                      ? u.cost_in_usd_ticks / 1e10
                      : null,
                  })}\n\n`,
                );
              }
              const delta = chunk.choices?.[0]?.delta?.content;
              if (delta) send(`data: ${JSON.stringify({ delta })}\n\n`);
            } catch {
              // Ignore keep-alive / non-JSON lines.
            }
          }
        }
        send(`event: done\ndata: {}\n\n`);
      } catch (e) {
        send(`event: error\ndata: ${JSON.stringify({ error: String(e) })}\n\n`);
      } finally {
        controller.close();
      }
    },
  });

  return new Response(stream, {
    headers: {
      ...cors,
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      "Connection": "keep-alive",
    },
  });
});
