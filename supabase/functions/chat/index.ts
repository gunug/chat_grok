// Supabase Edge Function: "chat"
// Proxies chat requests to the xAI (Grok) API and streams the answer back as
// Server-Sent Events. The xAI API key lives only as a Supabase secret
// (XAI_API_KEY) and never reaches the mobile app.
//
// Credits: each call is gated on the user's per-app credit balance and the
// real xAI cost is deducted after the answer streams (shared credit platform —
// see PLATFORM_CREDITS_GUIDE.md).

import { createClient } from "jsr:@supabase/supabase-js@2";

const SERVICE_KEY = "chat_grok";
const TRIAL_CREDITS = 300; // 첫 사용 체험 크레딧 (1 credit = 1원 by config)
const MIN_BALANCE_CREDITS = 1; // 호출 전 최소 잔액(크레딧)

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

  // --- 사용자 식별 + 크레딧 잔액 게이트 ------------------------------------
  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
  const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  // JWT는 '사용자'만 식별한다. service_key는 위 상수로 고정(클라이언트 신뢰 안 함).
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(SUPABASE_URL, ANON, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "unauthorized" }, 401);

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE);

  // 첫 사용 시 등록 + 체험 크레딧(멱등), 그다음 잔액 게이트.
  await admin.rpc("app_register_service", {
    p_user: user.id,
    p_service: SERVICE_KEY,
    p_trial_credits: TRIAL_CREDITS,
  });
  const { data: credit } = await admin
    .from("app_service_credits")
    .select("balance_credits")
    .eq("user_id", user.id)
    .eq("service_key", SERVICE_KEY)
    .maybeSingle();
  const balance = (credit?.balance_credits as number | undefined) ?? 0;
  if (balance < MIN_BALANCE_CREDITS) {
    return json({ error: "insufficient_credit", balanceCredits: balance }, 402);
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
      // deno-lint-ignore no-explicit-any
      let capturedUsage: any = null;
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
              if (chunk.usage) capturedUsage = chunk.usage;
              const delta = chunk.choices?.[0]?.delta?.content;
              if (delta) send(`data: ${JSON.stringify({ delta })}\n\n`);
            } catch {
              // Ignore keep-alive / non-JSON lines.
            }
          }
        }

        // 사용 기록: xAI 실제 원가(micro-USD)를 넘기면 RPC가 배율을 적용해 크레딧을
        // 차감하고 새 잔액(크레딧)을 돌려준다. 그 뒤 usage 이벤트로 함께 보낸다.
        if (capturedUsage) {
          const u = capturedUsage;
          const costUsd = u.cost_in_usd_ticks != null
            ? u.cost_in_usd_ticks / 1e10
            : 0;
          let balanceCredits = balance;
          try {
            const { data: nb } = await admin.rpc("app_record_usage", {
              p_user: user.id,
              p_service: SERVICE_KEY,
              p_provider: "xai",
              p_model: XAI_MODEL,
              p_action: "chat",
              p_prompt_tokens: u.prompt_tokens ?? 0,
              p_completion_tokens: u.completion_tokens ?? 0,
              p_cost_micros: Math.ceil(costUsd * 1e6),
            });
            if (nb != null) balanceCredits = nb as number;
          } catch (e) {
            console.error("app_record_usage failed:", e);
          }
          send(
            `event: usage\ndata: ${JSON.stringify({
              prompt: u.prompt_tokens,
              completion: u.completion_tokens,
              total: u.total_tokens,
              cached: u.prompt_tokens_details?.cached_tokens ?? 0,
              reasoning: u.completion_tokens_details?.reasoning_tokens ?? 0,
              costUsd: costUsd || null,
              creditsCharged: balance - balanceCredits,
              balanceCredits,
            })}\n\n`,
          );
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
