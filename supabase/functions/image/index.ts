// Supabase Edge Function: "image"
// Generates an image of the conversation's FINAL scene with xAI (Grok), in TWO
// client-driven steps so the app can show (and the user can confirm) the exact
// prompt before any image is billed:
//
//   mode:"compose" -> grok-3 turns the chat history into ONE English image
//                     prompt + a Korean translation. Cheap; not charged.
//   mode:"render"  -> the (confirmed) prompt is sent to the image model.
//                     The image fee is charged REGARDLESS of the outcome,
//                     because xAI bills even when its filter blocks the image.
//
// The xAI key never reaches the app. Same auth + credit gate as "chat".

import { createClient } from "jsr:@supabase/supabase-js@2";
import { encodeBase64 } from "jsr:@std/encoding/base64";

const SERVICE_KEY = "chat_grok";
const TRIAL_CREDITS = 0; // 체험 크레딧 비활성(어뷰징 차단). 충전한 계정만 사용 가능
const MIN_BALANCE_CREDITS = 1;

const XAI_BASE_URL = Deno.env.get("XAI_BASE_URL") ?? "https://api.x.ai/v1";
const XAI_MODEL = Deno.env.get("XAI_MODEL") ?? "grok-3"; // compose(텍스트)용
const OPENAI_BASE_URL = Deno.env.get("OPENAI_BASE_URL") ??
  "https://api.openai.com/v1";
// 클라이언트가 이미지 모델을 안 보낼 때의 기본값(cg_image_models.id 여야 함).
const DEFAULT_IMAGE_MODEL = Deno.env.get("XAI_IMAGE_MODEL") ??
  "grok-imagine-image-quality";

// cg_image_models 한 행(이미지 모델 카탈로그 + 1장당 정액 USD).
interface ImageModel {
  id: string;
  provider: string; // 'openai' | 'xai'
  price_usd: number;
  size: string | null;
  quality: string | null;
}

// 요청된(또는 기본) 이미지 모델을 cg_image_models에서 검증·로드. 없거나
// 비활성이면 null. service_role 클라이언트로 호출(RLS 우회).
// deno-lint-ignore no-explicit-any
async function loadImageModel(admin: any, id: string): Promise<ImageModel | null> {
  const wanted = (id || DEFAULT_IMAGE_MODEL).trim();
  const { data } = await admin
    .from("cg_image_models")
    .select("id, provider, price_usd, size, quality, enabled")
    .eq("id", wanted)
    .maybeSingle();
  if (!data || data.enabled === false) return null;
  return {
    id: data.id,
    provider: data.provider,
    price_usd: Number(data.price_usd),
    size: data.size ?? null,
    quality: data.quality ?? null,
  };
}

// cg_models 한 행(프롬프트 생성에 쓰는 텍스트 모델 + 단가). 채팅과 동일 카탈로그.
interface TextModel {
  id: string;
  provider: string; // 'openai' | 'xai'
  input_per_mtok: number | null;
  output_per_mtok: number | null;
  cached_input_per_mtok: number | null;
}

// 요청된 프롬프트 모델을 cg_models에서 검증·로드. 없거나 비활성이면 null
// (호출부에서 기본 xAI 모델로 폴백).
// deno-lint-ignore no-explicit-any
async function loadTextModel(admin: any, id: string): Promise<TextModel | null> {
  const wanted = (id || "").trim();
  if (!wanted) return null;
  const { data } = await admin
    .from("cg_models")
    .select(
      "id, provider, input_per_mtok, output_per_mtok, cached_input_per_mtok, enabled",
    )
    .eq("id", wanted)
    .maybeSingle();
  if (!data || data.enabled === false) return null;
  return {
    id: data.id,
    provider: data.provider,
    input_per_mtok: data.input_per_mtok != null ? Number(data.input_per_mtok) : null,
    output_per_mtok: data.output_per_mtok != null ? Number(data.output_per_mtok) : null,
    cached_input_per_mtok:
      data.cached_input_per_mtok != null ? Number(data.cached_input_per_mtok) : null,
  };
}

// provider별 "실제 보유 모델 id" 캐시(웜 인스턴스 간 재사용). 목록 조회는
// 메타데이터라 토큰 과금 없음. null = 조회 실패(이 경우 fail-open: 숨기지 않음).
const MODELS_CACHE_MS = 30 * 60 * 1000;
let _modelsCache: { at: number; openai: Set<string> | null; xai: Set<string> | null } =
  { at: 0, openai: null, xai: null };

async function fetchAvailableModelIds() {
  const now = Date.now();
  if (
    now - _modelsCache.at < MODELS_CACHE_MS &&
    (_modelsCache.openai || _modelsCache.xai)
  ) {
    return _modelsCache;
  }
  // OpenAI: /v1/models (전체 모델). 이미지 여부와 무관하게 id 집합으로 사용.
  let openai: Set<string> | null = null;
  try {
    const key = Deno.env.get("OPENAI_API_KEY");
    if (key) {
      const r = await fetch(`${OPENAI_BASE_URL}/models`, {
        headers: { Authorization: `Bearer ${key}` },
      });
      if (r.ok) {
        const j = await r.json();
        // deno-lint-ignore no-explicit-any
        openai = new Set((j.data ?? []).map((m: any) => String(m.id)));
      }
    }
  } catch (_) { /* fail-open */ }
  // xAI: /v1/image-generation-models (이미지 모델만). id + aliases 포함.
  let xai: Set<string> | null = null;
  try {
    const r = await fetch(`${XAI_BASE_URL}/image-generation-models`, {
      headers: { Authorization: `Bearer ${Deno.env.get("XAI_API_KEY")}` },
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
  } catch (_) { /* fail-open */ }
  _modelsCache = { at: now, openai, xai };
  return _modelsCache;
}

// cg_image_models(enabled) ∩ provider 실시간 보유 목록을 반환.
// deno-lint-ignore no-explicit-any
async function listAvailableImageModels(admin: any): Promise<Response> {
  const { data: rows } = await admin
    .from("cg_image_models")
    .select("id, provider, label, price_usd, sort")
    .eq("enabled", true)
    .order("sort");
  const candidates = (rows ?? []);
  const cache = await fetchAvailableModelIds();
  const rank = (p: string) => (p === "openai" ? 0 : p === "xai" ? 1 : 2);
  const models = candidates
    // deno-lint-ignore no-explicit-any
    .filter((c: any) => {
      const set = c.provider === "openai" ? cache.openai : cache.xai;
      if (set == null) return true; // 목록 조회 실패 → 숨기지 않음
      return set.has(c.id);
    })
    // 정렬: provider(OpenAI→xAI) → 가격 내림차순(비싼 것 위로).
    // deno-lint-ignore no-explicit-any
    .sort((a: any, b: any) =>
      rank(a.provider) - rank(b.provider) ||
      Number(b.price_usd) - Number(a.price_usd))
    // deno-lint-ignore no-explicit-any
    .map((c: any) => ({
      id: c.id,
      provider: c.provider,
      label: c.label,
      price_usd: Number(c.price_usd),
    }));
  return json({ models });
}

// The scene stays faithful; only the WORDING is kept moderation-safe. xAI's
// image filter rejects on its Acceptable Use Policy (sexual/intimate real
// people, minors) AND — per widespread user reports — on individual "charged"
// words even in innocent contexts (blood, weapon, dead, naked, explosion…). A
// single flagged word can block an otherwise fine scene, so we steer grok-3
// toward neutral, aesthetic visual language and word substitutions.
const PROMPT_SYSTEM = Deno.env.get("IMAGE_PROMPT_SYSTEM") ??
  `You turn the conversation into ONE image-generation prompt depicting its FINAL scene as vividly and faithfully as possible.
Return ONLY a JSON object with two string fields:
  "prompt"     — the image prompt, in English (under 1000 characters)
  "prompt_ko"  — a natural Korean translation of that prompt
The English "prompt" should describe: subject(s), setting, composition, camera angle, lighting, color palette, mood, and art style.

Stay faithful to the SCENE, but phrase it so an automated image-safety filter will not reject it. The filter flags individual words even in harmless contexts, so:
- Use neutral, aesthetic visual language (lighting, composition, material, texture, mood) instead of emotionally charged or graphic words.
- Substitute flagged words while keeping the same look. Examples: "blood-splattered" -> "battle-worn / crimson-streaked"; "brutal / violent" -> "steely / intense / formidable"; "explosion" -> "dramatic burst of light"; "dead forest" -> "barren, leafless forest"; "weapon / gun" -> "stylized blade / sci-fi device" or omit; "naked / nude" -> "draped in flowing fabric / silhouetted"; "wound / gore" -> omit or "battle-worn".
- Do NOT name or depict real, identifiable people, celebrities, or public figures — render generic original characters instead. Do NOT include brand names, logos, or trademarked/copyrighted characters.
- Every person depicted MUST be an unambiguous adult. State an explicit adult age or range for each person (e.g., "a woman in her early 30s", "an adult man around 40"). NEVER use "young", "teen", "teenage", "girl", "boy", "kid", "child", "youthful", "schoolgirl/schoolboy", or any word that could read as under 18 — use "woman", "man", or "adult" instead.
- If the scene implies anything non-consensual, forced, coerced, or unwilling, reframe it as a clearly consensual, willing, and mutual interaction between adults.
- Avoid sexual, pornographic, or intimate framing; avoid body-focused/lingerie/suggestive-pose descriptions.
Convey the scene's meaning through mood and composition, not graphic or explicit terms.`;

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
    return json({ error: "XAI_API_KEY secret is not set." }, 500);
  }

  let body: {
    mode?: string;
    messages?: Array<{ role: string; content: string }>;
    prompt?: string;
    model?: string; // cg_image_models.id (render 대상 이미지 모델)
    promptModel?: string; // cg_models.id (compose 프롬프트 생성 텍스트 모델)
  };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }
  const mode = body.mode ?? "compose";

  // --- 사용자 식별 + 크레딧 잔액 게이트 (chat 함수와 동일) -----------------
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

  // mode: models — 사용 가능한 이미지 모델 목록(크레딧 게이트 불필요).
  // cg_image_models(enabled) ∩ provider 실시간 보유 목록. 토큰 과금 없음.
  if (mode === "models") return await listAvailableImageModels(admin);

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

  // ========================================================================
  // mode: compose — 대화 → 마지막 장면 프롬프트(영어) + 한글 번역.
  // grok-3 호출 비용을 차감한다(서비스 제공자가 API 비용을 떠안지 않음).
  // ========================================================================
  if (mode === "compose") {
    const messages = body.messages;
    if (!Array.isArray(messages) || messages.length === 0) {
      return json({ error: "messages[] is required" }, 400);
    }
    // 최근 메시지 위주(토큰 절약 + 마지막 장면 집중).
    const recent = messages.slice(-12).map((m) => ({
      role: m.role === "assistant" ? "assistant" : "user",
      content: String(m.content ?? "").slice(0, 4000),
    }));

    // 프롬프트 생성 모델: 요청값(cg_models) 검증 후 provider 라우팅. 못 찾으면
    // 기본 xAI 모델로 폴백(과금 스푸핑 방지 — 단가는 항상 카탈로그/응답 기준).
    const tm = await loadTextModel(admin, body.promptModel ?? "");
    const textProvider = tm?.provider ?? "xai";
    const textModelId = tm?.id ?? XAI_MODEL;
    const isOpenaiText = textProvider === "openai";
    const TEXT_BASE_URL = isOpenaiText ? OPENAI_BASE_URL : XAI_BASE_URL;
    const TEXT_API_KEY = isOpenaiText
      ? Deno.env.get("OPENAI_API_KEY")
      : XAI_API_KEY;
    if (!TEXT_API_KEY) {
      return json(
        { error: `${isOpenaiText ? "OPENAI_API_KEY" : "XAI_API_KEY"} secret is not set.` },
        500,
      );
    }

    try {
      const r = await fetch(`${TEXT_BASE_URL}/chat/completions`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${TEXT_API_KEY}`,
        },
        body: JSON.stringify({
          model: textModelId,
          messages: [
            { role: "system", content: PROMPT_SYSTEM },
            ...recent,
            {
              role: "user",
              content:
                "Produce the JSON for the final scene above. JSON only.",
            },
          ],
          response_format: { type: "json_object" },
          stream: false,
        }),
      });
      if (!r.ok) {
        const detail = await r.text().catch(() => "");
        return json(
          { error: `prompt step failed (${r.status})`, detail: detail.slice(0, 500) },
          502,
        );
      }
      const j = await r.json();

      // 호출이 성공했으면 토큰 비용이 이미 발생했으므로, 프롬프트가 비어
      // 실패하더라도 먼저 차감한다(서비스가 API 비용을 떠안지 않음).
      //  • xAI: 응답의 cost_in_usd_ticks 사용.
      //  • OpenAI: cg_models 토큰 단가로 계산(채팅 함수와 동일 공식).
      const u = j.usage ?? {};
      let promptCostUsd = 0;
      if (u.cost_in_usd_ticks != null) {
        promptCostUsd = u.cost_in_usd_ticks / 1e10;
      } else if (tm && tm.input_per_mtok != null) {
        const promptTok = u.prompt_tokens ?? 0;
        const cachedTok = u.prompt_tokens_details?.cached_tokens ?? 0;
        const nonCached = Math.max(0, promptTok - cachedTok);
        const cachedRate = tm.cached_input_per_mtok ?? tm.input_per_mtok;
        const outRate = tm.output_per_mtok ?? 0;
        promptCostUsd = nonCached / 1e6 * tm.input_per_mtok +
          cachedTok / 1e6 * cachedRate +
          (u.completion_tokens ?? 0) / 1e6 * outRate;
      }
      let balanceCredits = balance;
      try {
        const { data: nb } = await admin.rpc("app_record_usage", {
          p_user: user.id,
          p_service: SERVICE_KEY,
          p_provider: textProvider,
          p_model: textModelId,
          p_action: "image_prompt",
          p_prompt_tokens: u.prompt_tokens ?? 0,
          p_completion_tokens: u.completion_tokens ?? 0,
          p_cost_micros: Math.ceil(promptCostUsd * 1e6),
        });
        if (nb != null) balanceCredits = nb as number;
      } catch (e) {
        console.error("app_record_usage (compose) failed:", e);
      }

      const raw = (j.choices?.[0]?.message?.content ?? "").toString();
      let prompt = "";
      let promptKo = "";
      try {
        const parsed = JSON.parse(raw);
        prompt = String(parsed.prompt ?? "").trim();
        promptKo = String(parsed.prompt_ko ?? "").trim();
      } catch {
        prompt = raw.trim(); // JSON 파싱 실패 시 원문을 프롬프트로 사용.
      }
      if (!prompt) {
        // 비용은 이미 차감됨 → 갱신된 잔액을 함께 알려 클라가 반영하도록.
        return json({
          error: "could not build an image prompt",
          creditsCharged: balance - balanceCredits,
          balanceCredits,
        }, 502);
      }

      // 이미지 생성(render) 시 차감될 크레딧 미리 계산 — 선택한 이미지 모델의
      // 1장당 가격으로 환산(없으면 기본 모델). 모델을 못 찾으면 null.
      let imageCredits: number | null = null;
      try {
        const im = await loadImageModel(admin, body.model ?? "");
        if (im) {
          const { data: ic } = await admin.rpc("app_usage_credits", {
            p_service: SERVICE_KEY,
            p_cost_micros: Math.ceil(im.price_usd * 1e6),
          });
          if (ic != null) imageCredits = Number(ic);
        }
      } catch (e) {
        console.error("app_usage_credits preview failed:", e);
      }

      return json({
        prompt,
        promptKo,
        costUsd: promptCostUsd,
        creditsCharged: balance - balanceCredits,
        balanceCredits,
        imageCredits, // render 시 차감 예정 크레딧(미리 고지용)
      });
    } catch (e) {
      return json({ error: "prompt step error", detail: String(e) }, 502);
    }
  }

  // ========================================================================
  // mode: render — 확인된 프롬프트로 이미지 생성. 성공/차단 무관하게 과금.
  // ========================================================================
  if (mode === "render") {
    const prompt = (body.prompt ?? "").toString().trim();
    if (!prompt) return json({ error: "prompt is required" }, 400);

    // 모델 검증 + provider 라우팅(허용목록 cg_image_models). 임의 모델/과금 스푸핑 차단.
    const im = await loadImageModel(admin, body.model ?? "");
    if (!im) return json({ error: "unknown or disabled image model" }, 400);

    // 선승인(고정비): 이미지는 호출 전에 가격을 알 수 있으므로, 1크레딧 게이트가
    // 아니라 "이 이미지의 실제 차감 크레딧"만큼 잔액이 있는지부터 막는다.
    // (잔액 1로 비싼 1장을 공짜로 받는 어뷰징 차단. 채팅과 달리 비용이 고정.)
    const { data: costC } = await admin.rpc("app_usage_credits", {
      p_service: SERVICE_KEY,
      p_cost_micros: Math.ceil(im.price_usd * 1e6),
    });
    const imageCostCredits = Math.max(1, Number(costC ?? 0));
    if (balance < imageCostCredits) {
      return json({
        error: "insufficient_credit",
        balanceCredits: balance,
        requiredCredits: imageCostCredits,
      }, 402);
    }

    const isOpenai = im.provider === "openai";
    const API_KEY = isOpenai
      ? Deno.env.get("OPENAI_API_KEY")
      : XAI_API_KEY;
    if (!API_KEY) {
      return json(
        { error: `${isOpenai ? "OPENAI_API_KEY" : "XAI_API_KEY"} secret is not set.` },
        500,
      );
    }
    const BASE_URL = isOpenai ? OPENAI_BASE_URL : XAI_BASE_URL;

    let blocked = false;
    let blockReason = "";
    let imageB64 = "";
    let revisedPrompt = prompt;
    try {
      // 요청 본문(OpenAI/xAI 모두 OpenAI 호환 /images/generations).
      // deno-lint-ignore no-explicit-any
      const reqBody: Record<string, any> = { model: im.id, prompt, n: 1 };
      if (isOpenai) {
        // OpenAI 이미지 API는 response_format 인자를 받지 않는다(gpt-image-1은
        // 항상 b64_json, dall-e-3은 기본 url). 응답 파싱에서 둘 다 처리한다.
        if (im.size) reqBody.size = im.size;
        if (im.quality) reqBody.quality = im.quality;
      } else {
        // xAI는 OpenAI 호환이며 b64_json을 지원한다.
        reqBody.response_format = "b64_json";
      }
      const r = await fetch(`${BASE_URL}/images/generations`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${API_KEY}`,
        },
        body: JSON.stringify(reqBody),
      });
      if (r.ok) {
        const j = await r.json();
        const first = j.data?.[0] ?? {};
        if (first.b64_json) {
          imageB64 = first.b64_json;
        } else if (first.url) {
          // dall-e-3 기본 응답은 URL → 바이트를 받아 base64로 변환.
          const ir = await fetch(first.url);
          if (ir.ok) {
            imageB64 = encodeBase64(new Uint8Array(await ir.arrayBuffer()));
          }
        }
        if (first.revised_prompt) revisedPrompt = first.revised_prompt;
      } else {
        // 오류 본문에서 실제 코드/메시지를 추출(가능하면).
        const rawErr = await r.text().catch(() => "");
        let code = "";
        let message = rawErr;
        try {
          const pe = JSON.parse(rawErr);
          // deno-lint-ignore no-explicit-any
          const eo: any = pe.error ?? pe;
          code = (eo?.code ?? "").toString();
          message = (eo?.message ?? eo?.error ?? rawErr).toString();
        } catch { /* JSON 아님 → rawErr 사용 */ }

        // 콘텐츠/모더레이션 차단인지 판정.
        //  • xAI: 400을 모더레이션 차단으로 간주(차단돼도 과금됨).
        //  • OpenAI: code/메시지가 콘텐츠 정책일 때만 차단. 403(조직 미인증)·
        //    404(미보유)·기타 400(잘못된 요청)은 차단이 아니라 실제 에러로 전달.
        const isModeration = !isOpenai
          ? r.status === 400
          : (r.status === 400 &&
            (code === "moderation_blocked" ||
              code === "content_policy_violation" ||
              /content[_ ]?policy|moderation|safety|flagged|violat|sensitive/i
                .test(message)));

        if (isModeration) {
          blocked = true;
          blockReason = message.slice(0, 300);
        } else {
          // 모델 미보유("does not exist"/404)면 카탈로그에서 자동 비활성화 →
          // 다음부터 picker에 안 보인다(best-effort, 과금 없음).
          const notFound = r.status === 404 ||
            /does not exist|model_not_found|not[_ ]?found/i.test(message);
          if (notFound) {
            admin.from("cg_image_models").update({ enabled: false })
              .eq("id", im.id).then(() => {}, () => {});
          }
          // 과금 없이 실제 원인(조직 인증/접근 권한/요청 오류 등)을 그대로 전달.
          return json(
            {
              error: `image step failed (${r.status})`,
              detail: message.slice(0, 500),
              code,
            },
            r.status === 402 ? 502 : r.status, // 402는 크레딧 게이트 전용이라 회피
          );
        }
      }
    } catch (e) {
      return json({ error: "image step error", detail: String(e) }, 502);
    }

    if (!blocked && !imageB64) {
      return json({ error: "no image returned" }, 502);
    }

    // 과금 정책: xAI는 차단되어도 과금(실제 청구됨), OpenAI는 차단 시 과금 안 함.
    const shouldCharge = !blocked || !isOpenai;
    let balanceCredits = balance;
    if (shouldCharge) {
      try {
        const { data: nb } = await admin.rpc("app_record_usage", {
          p_user: user.id,
          p_service: SERVICE_KEY,
          p_provider: im.provider,
          p_model: im.id,
          p_action: blocked ? "image_blocked" : "image",
          p_prompt_tokens: 0,
          p_completion_tokens: 0,
          p_cost_micros: Math.ceil(im.price_usd * 1e6),
        });
        if (nb != null) balanceCredits = nb as number;
      } catch (e) {
        console.error("app_record_usage failed:", e);
      }
    }

    return json({
      blocked,
      reason: blocked && blockReason ? blockReason : null,
      imageB64: blocked ? null : imageB64,
      revisedPrompt: blocked ? null : revisedPrompt,
      costUsd: shouldCharge ? im.price_usd : 0,
      creditsCharged: balance - balanceCredits,
      balanceCredits,
    });
  }

  return json({ error: `unknown mode: ${mode}` }, 400);
});
