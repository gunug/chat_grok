// Supabase Edge Function: "chat"
// Proxies chat requests to the xAI (Grok) API and streams the answer back as
// Server-Sent Events. The xAI API key lives only as a Supabase secret
// (XAI_API_KEY) and never reaches the mobile app.
//
// Server-complete-and-store: the answer is consumed to completion and persisted
// in cg_pending_chat via EdgeRuntime.waitUntil — so it survives the client going
// to background (locked screen). The app re-reads the row on resume. Credits are
// deducted exactly once at finalization, independent of the client connection,
// which also removes the "billed but not charged" gray zone.
//
// Credits: gated on the user's per-app credit balance; the real xAI cost is
// deducted after the answer completes (shared credit platform).

import { createClient } from "jsr:@supabase/supabase-js@2";

// Supabase Edge runtime extends function lifetime past the response with this.
declare const EdgeRuntime:
  | { waitUntil(p: Promise<unknown>): void }
  | undefined;

const SERVICE_KEY = "chat_grok";
const TRIAL_CREDITS = 300; // 첫 사용 체험 크레딧 (1 credit = 1원 by config)
const MIN_BALANCE_CREDITS = 1; // 호출 전 최소 잔액(크레딧)
const PENDING_TTL_MS = 2 * 24 * 60 * 60 * 1000; // 버려진 행 정리 기준(2일)

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

function sseHeaders(): Record<string, string> {
  return {
    ...cors,
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    "Connection": "keep-alive",
  };
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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
  let requestId: string | undefined;
  try {
    const body = await req.json();
    messages = body.messages;
    // 클라이언트가 보낸 멱등 키. 없거나 형식이 틀리면 서버가 생성(구버전 호환).
    requestId = (typeof body.requestId === "string" && UUID_RE.test(body.requestId))
      ? body.requestId
      : crypto.randomUUID();
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

  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(SUPABASE_URL, ANON, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "unauthorized" }, 401);

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE);

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

  // --- 인플라이트 행 확보(멱등) + 오래된 행 정리 ----------------------------
  // 버려진 자기 행 정리(best-effort).
  admin.from("cg_pending_chat").delete()
    .eq("user_id", user.id)
    .lt("updated_at", new Date(Date.now() - PENDING_TTL_MS).toISOString())
    .then(() => {}, () => {});

  let persist = true;
  let duplicate = false;
  try {
    const { data: ins } = await admin
      .from("cg_pending_chat")
      .upsert(
        {
          request_id: requestId,
          user_id: user.id,
          service_key: SERVICE_KEY,
          status: "streaming",
          content: "",
          updated_at: new Date().toISOString(),
        },
        { onConflict: "request_id", ignoreDuplicates: true },
      )
      .select("request_id");
    if (!ins || ins.length === 0) duplicate = true; // 이미 존재 → 중복/재요청
  } catch (e) {
    persist = false; // 저장 불가 시 스트리밍만(그레이스풀 디그레이드)
    console.error("cg_pending_chat insert failed:", e);
  }

  // 중복 요청: 저장된 상태를 재생(클라는 테이블 폴링으로 보충). 새 xAI 호출/과금 없음.
  if (duplicate) {
    const { data: row } = await admin
      .from("cg_pending_chat")
      .select("status, content, usage")
      .eq("request_id", requestId)
      .maybeSingle();
    const enc = new TextEncoder();
    const replay = new ReadableStream({
      start(controller) {
        const s = (x: string) => controller.enqueue(enc.encode(x));
        const content = (row?.content as string) ?? "";
        if (content) s(`data: ${JSON.stringify({ delta: content })}\n\n`);
        if (row?.usage) {
          s(`event: usage\ndata: ${JSON.stringify(row.usage)}\n\n`);
        }
        s(`event: done\ndata: ${JSON.stringify({ duplicate: true })}\n\n`);
        controller.close();
      },
    });
    return new Response(replay, { headers: sseHeaders() });
  }

  // --- xAI 호출 ------------------------------------------------------------
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
    // 토큰 생성 전 실패 → 과금 없음. 행은 error로 표시(있으면).
    if (persist) {
      await admin.from("cg_pending_chat").update({
        status: "error",
        error: `xAI ${upstream.status}`,
        updated_at: new Date().toISOString(),
      }).eq("request_id", requestId);
    }
    return json(
      { error: `xAI API error (${upstream.status})`, detail: detail.slice(0, 500) },
      502,
    );
  }

  // --- 스트림 + 백그라운드 완료/저장 ---------------------------------------
  // 읽기 루프와 영속화를 waitUntil로 응답 스트림과 분리한다. 클라이언트가
  // 끊겨도(cancel) 루프는 계속 돌아 답변/usage를 저장하고 크레딧을 1회 차감한다.
  const body = upstream.body;
  const stream = new ReadableStream({
    start(controller) {
      const enc = new TextEncoder();
      const dec = new TextDecoder();
      let clientGone = false;
      const send = (s: string) => {
        if (clientGone) return;
        try {
          controller.enqueue(enc.encode(s));
        } catch {
          clientGone = true;
        }
      };
      const closeClient = () => {
        if (clientGone) return;
        try {
          controller.close();
        } catch { /* already closed */ }
      };

      const task = (async () => {
        const reader = body.getReader();
        let buffer = "";
        let content = "";
        // deno-lint-ignore no-explicit-any
        let capturedUsage: any = null;

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
                if (delta) {
                  content += delta;
                  send(`data: ${JSON.stringify({ delta })}\n\n`);
                }
              } catch {
                // keep-alive / non-JSON 무시
              }
            }
          }

          // 완료: 원가 → 크레딧 1회 차감 후 새 잔액 산출.
          let balanceCredits = balance;
          if (capturedUsage) {
            const u = capturedUsage;
            const costUsd = u.cost_in_usd_ticks != null
              ? u.cost_in_usd_ticks / 1e10
              : 0;
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
            const usageObj = {
              prompt: u.prompt_tokens,
              completion: u.completion_tokens,
              total: u.total_tokens,
              cached: u.prompt_tokens_details?.cached_tokens ?? 0,
              reasoning: u.completion_tokens_details?.reasoning_tokens ?? 0,
              costUsd: costUsd || null,
              creditsCharged: balance - balanceCredits,
              balanceCredits,
            };
            // 저장(완료) — 백그라운드 클라가 복귀 후 읽음.
            if (persist) {
              await admin.from("cg_pending_chat").update({
                status: "done",
                content,
                usage: usageObj,
                updated_at: new Date().toISOString(),
              }).eq("request_id", requestId);
            }
            send(`event: usage\ndata: ${JSON.stringify(usageObj)}\n\n`);
          } else if (persist) {
            // usage 없이 끝난 경우(드묾): 내용만 저장.
            await admin.from("cg_pending_chat").update({
              status: "done",
              content,
              updated_at: new Date().toISOString(),
            }).eq("request_id", requestId);
          }

          send(`event: done\ndata: {}\n\n`);
          closeClient();
        } catch (e) {
          // 스트림 자체 오류. 토큰을 일부 받았을 수 있으나 usage 미확정이면
          // 과금하지 않는다(행을 error로). 클라엔 error 이벤트.
          if (persist) {
            await admin.from("cg_pending_chat").update({
              status: "error",
              error: String(e).slice(0, 500),
              content,
              updated_at: new Date().toISOString(),
            }).eq("request_id", requestId).then(() => {}, () => {});
          }
          send(`event: error\ndata: ${JSON.stringify({ error: String(e) })}\n\n`);
          closeClient();
        }
      })();

      // 응답이 닫혀도(클라 백그라운드) task가 끝까지 실행되도록 유지.
      try {
        (globalThis as { EdgeRuntime?: typeof EdgeRuntime }).EdgeRuntime
          ?.waitUntil(task);
      } catch { /* 로컬 등 미지원 환경 */ }
    },
    cancel() {
      // 클라이언트가 끊김 — task는 계속 진행(waitUntil). 표시만.
    },
  });

  return new Response(stream, { headers: sseHeaders() });
});
