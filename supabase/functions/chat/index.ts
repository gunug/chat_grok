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
const OPENAI_BASE_URL = Deno.env.get("OPENAI_BASE_URL") ??
  "https://api.openai.com/v1";
// 클라이언트가 model을 안 보낼 때(구버전)의 기본 모델. cg_models에 있어야 함.
const DEFAULT_MODEL = Deno.env.get("DEFAULT_MODEL") ?? "gpt-4.1-mini";
const SYSTEM_PROMPT = Deno.env.get("SYSTEM_PROMPT") ??
  "You are a helpful and witty AI assistant. Answer clearly and concisely.";

// cg_models 한 행(모델 카탈로그 + 단가).
interface ModelRow {
  id: string;
  provider: string; // 'openai' | 'xai'
  input_per_mtok: number | null;
  output_per_mtok: number | null;
  cached_input_per_mtok: number | null;
}

// provider별 "실제 보유 모델 id" 캐시(웜 인스턴스 간 재사용). 목록 조회는
// 메타데이터라 토큰 과금 없음. null = 조회 실패(fail-open: 숨기지 않음).
const MODELS_CACHE_MS = 30 * 60 * 1000;
let _modelsCache: { at: number; openai: Set<string> | null; xai: Set<string> | null } =
  { at: 0, openai: null, xai: null };

async function fetchAvailableChatModelIds() {
  const now = Date.now();
  if (
    now - _modelsCache.at < MODELS_CACHE_MS &&
    (_modelsCache.openai || _modelsCache.xai)
  ) {
    return _modelsCache;
  }
  let openai: Set<string> | null = null;
  try {
    const key = Deno.env.get("OPENAI_API_KEY");
    if (key) {
      const r = await fetch(`${OPENAI_BASE_URL}/models`, {
        headers: { Authorization: `Bearer ${key}` },
      });
      // deno-lint-ignore no-explicit-any
      if (r.ok) { const j = await r.json(); openai = new Set((j.data ?? []).map((m: any) => String(m.id))); }
    }
  } catch (_) { /* fail-open */ }
  let xai: Set<string> | null = null;
  try {
    const key = Deno.env.get("XAI_API_KEY");
    if (key) {
      // 텍스트 모델 목록(id + aliases). 예: grok-3/grok-4 → grok-4.3 alias.
      const r = await fetch(`${XAI_BASE_URL}/language-models`, {
        headers: { Authorization: `Bearer ${key}` },
      });
      if (r.ok) {
        const j = await r.json();
        const s = new Set<string>();
        // deno-lint-ignore no-explicit-any
        for (const m of (j.models ?? []) as any[]) {
          if (m.id) s.add(String(m.id));
          for (const a of (m.aliases ?? [])) s.add(String(a));
        }
        xai = s;
      }
    }
  } catch (_) { /* fail-open */ }
  _modelsCache = { at: now, openai, xai };
  return _modelsCache;
}

// cg_models(enabled) ∩ provider 실보유 목록. 정렬: provider(OpenAI→xAI) →
// 가격(출력단가) 내림차순. 토큰 과금 없음.
// deno-lint-ignore no-explicit-any
async function listAvailableChatModels(admin: any): Promise<Response> {
  const { data: rows } = await admin
    .from("cg_models")
    .select("id, provider, label, input_per_mtok, output_per_mtok")
    .eq("enabled", true);
  const candidates = (rows ?? []);
  const cache = await fetchAvailableChatModelIds();
  const rank = (p: string) => (p === "openai" ? 0 : p === "xai" ? 1 : 2);
  // deno-lint-ignore no-explicit-any
  const price = (m: any) => Number(m.output_per_mtok ?? m.input_per_mtok ?? 0);
  const models = candidates
    // deno-lint-ignore no-explicit-any
    .filter((c: any) => {
      const set = c.provider === "openai" ? cache.openai : cache.xai;
      if (set == null) return true;
      return set.has(c.id);
    })
    // deno-lint-ignore no-explicit-any
    .sort((a: any, b: any) => rank(a.provider) - rank(b.provider) || price(b) - price(a))
    // deno-lint-ignore no-explicit-any
    .map((c: any) => ({
      id: c.id,
      provider: c.provider,
      label: c.label,
      input_per_mtok: c.input_per_mtok,
      output_per_mtok: c.output_per_mtok,
    }));
  return json({ models });
}

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

  let messages: Array<{ role: string; content: string }> | undefined;
  let requestId: string | undefined;
  let model: string = DEFAULT_MODEL;
  let mode = "chat";
  try {
    const body = await req.json();
    messages = body.messages;
    if (typeof body.mode === "string" && body.mode) mode = body.mode;
    // 클라이언트가 보낸 멱등 키. 없거나 형식이 틀리면 서버가 생성(구버전 호환).
    requestId = (typeof body.requestId === "string" && UUID_RE.test(body.requestId))
      ? body.requestId
      : crypto.randomUUID();
    if (typeof body.model === "string" && body.model) model = body.model;
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }
  if (mode !== "models" && (!Array.isArray(messages) || messages.length === 0)) {
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

  // mode: models — 사용 가능한 채팅 모델 목록(크레딧 게이트 불필요, 과금 없음).
  if (mode === "models") return await listAvailableChatModels(admin);

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

  // --- 모델 검증 + provider 라우팅 -----------------------------------------
  // 허용목록(cg_models)에 있는 활성 모델만 허용 → 임의 모델/과금 스푸핑 차단.
  const { data: mrow } = await admin
    .from("cg_models")
    .select("id, provider, input_per_mtok, output_per_mtok, cached_input_per_mtok")
    .eq("id", model)
    .eq("enabled", true)
    .maybeSingle();
  if (!mrow) return json({ error: `unknown model: ${model}` }, 400);
  const modelRow = mrow as ModelRow;
  const isOpenai = modelRow.provider === "openai";
  const BASE_URL = isOpenai ? OPENAI_BASE_URL : XAI_BASE_URL;
  const API_KEY = Deno.env.get(isOpenai ? "OPENAI_API_KEY" : "XAI_API_KEY");
  if (!API_KEY) {
    return json(
      { error: `${isOpenai ? "OPENAI_API_KEY" : "XAI_API_KEY"} secret is not set.` },
      500,
    );
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

  // --- provider 호출 (OpenAI/xAI 모두 OpenAI 호환 포맷) ----------------------
  const payloadMessages = messages[0]?.role === "system"
    ? messages
    : [{ role: "system", content: SYSTEM_PROMPT }, ...messages];

  const upstream = await fetch(`${BASE_URL}/chat/completions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${API_KEY}`,
    },
    body: JSON.stringify({
      model: modelRow.id,
      messages: payloadMessages,
      stream: true,
      stream_options: { include_usage: true },
    }),
  });

  if (!upstream.ok || !upstream.body) {
    const detail = await upstream.text().catch(() => "");
    // 모델 미보유("does not exist"/404)면 카탈로그에서 자동 비활성화(best-effort).
    if (upstream.status === 404 ||
        /does not exist|model_not_found|not[_ ]?found/i.test(detail)) {
      admin.from("cg_models").update({ enabled: false })
        .eq("id", modelRow.id).then(() => {}, () => {});
    }
    // 토큰 생성 전 실패 → 과금 없음. 행은 error로 표시(있으면).
    if (persist) {
      await admin.from("cg_pending_chat").update({
        status: "error",
        error: `${modelRow.provider} ${upstream.status}`,
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
            // 비용(USD): provider가 cost를 주면(xAI ticks) 그것을, 아니면
            // (OpenAI) cg_models 단가로 토큰×단가 계산. 캐시 입력은 할인 단가.
            let costUsd = 0;
            if (u.cost_in_usd_ticks != null) {
              costUsd = u.cost_in_usd_ticks / 1e10;
            } else if (modelRow.input_per_mtok != null) {
              const promptTok = u.prompt_tokens ?? 0;
              const cachedTok = u.prompt_tokens_details?.cached_tokens ?? 0;
              const nonCached = Math.max(0, promptTok - cachedTok);
              const cachedRate = modelRow.cached_input_per_mtok ??
                modelRow.input_per_mtok;
              const outRate = modelRow.output_per_mtok ?? 0;
              costUsd = nonCached / 1e6 * modelRow.input_per_mtok +
                cachedTok / 1e6 * cachedRate +
                (u.completion_tokens ?? 0) / 1e6 * outRate;
            }
            try {
              const { data: nb } = await admin.rpc("app_record_usage", {
                p_user: user.id,
                p_service: SERVICE_KEY,
                p_provider: modelRow.provider,
                p_model: modelRow.id,
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
            // 이미 차감(app_record_usage)이 끝났으므로, 행 갱신 실패가 바깥
            // catch로 번져 status='error'가 되면 안 된다(재전송→이중과금).
            // 따라서 best-effort로 삼키고 done/usage는 그대로 전송한다.
            if (persist) {
              try {
                await admin.from("cg_pending_chat").update({
                  status: "done",
                  content,
                  usage: usageObj,
                  updated_at: new Date().toISOString(),
                }).eq("request_id", requestId);
              } catch (e) {
                console.error("pending done-update failed (charge already done):", e);
              }
            }
            send(`event: usage\ndata: ${JSON.stringify(usageObj)}\n\n`);
          } else if (persist) {
            // usage 없이 끝난 경우(드묾): 내용만 저장(과금 없음).
            try {
              await admin.from("cg_pending_chat").update({
                status: "done",
                content,
                updated_at: new Date().toISOString(),
              }).eq("request_id", requestId);
            } catch (e) {
              console.error("pending done-update (no usage) failed:", e);
            }
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
