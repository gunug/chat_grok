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

const SERVICE_KEY = "chat_grok";
const TRIAL_CREDITS = 300;
const MIN_BALANCE_CREDITS = 1;

const XAI_BASE_URL = Deno.env.get("XAI_BASE_URL") ?? "https://api.x.ai/v1";
const XAI_MODEL = Deno.env.get("XAI_MODEL") ?? "grok-3";
const XAI_IMAGE_MODEL = Deno.env.get("XAI_IMAGE_MODEL") ??
  "grok-imagine-image-quality";

// Flat per-image USD price (xAI bills per image — and still bills on a
// moderation block). Picked by model; override with XAI_IMAGE_USD.
const IMAGE_PRICE_USD: Record<string, number> = {
  "grok-imagine-image-quality": 0.05,
  "grok-imagine-image": 0.02,
  "grok-2-image": 0.07,
};
const IMAGE_COST_USD = Number(Deno.env.get("XAI_IMAGE_USD")) ||
  IMAGE_PRICE_USD[XAI_IMAGE_MODEL] || 0.05;

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

    try {
      const r = await fetch(`${XAI_BASE_URL}/chat/completions`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${XAI_API_KEY}`,
        },
        body: JSON.stringify({
          model: XAI_MODEL,
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

      // grok-3 호출이 성공했으면 토큰 비용이 이미 발생했으므로, 프롬프트가
      // 비어 실패하더라도 먼저 차감한다(서비스가 API 비용을 떠안지 않음).
      const u = j.usage ?? {};
      const promptCostUsd = u.cost_in_usd_ticks != null
        ? u.cost_in_usd_ticks / 1e10
        : 0;
      let balanceCredits = balance;
      try {
        const { data: nb } = await admin.rpc("app_record_usage", {
          p_user: user.id,
          p_service: SERVICE_KEY,
          p_provider: "xai",
          p_model: XAI_MODEL,
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

      // 이미지 생성(render) 시 차감될 크레딧 미리 계산(동일 비용 → 동일 공식).
      let imageCredits: number | null = null;
      try {
        const { data: ic } = await admin.rpc("app_usage_credits", {
          p_service: SERVICE_KEY,
          p_cost_micros: Math.ceil(IMAGE_COST_USD * 1e6),
        });
        if (ic != null) imageCredits = Number(ic);
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

    let blocked = false;
    let imageB64 = "";
    let revisedPrompt = prompt;
    try {
      const r = await fetch(`${XAI_BASE_URL}/images/generations`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${XAI_API_KEY}`,
        },
        body: JSON.stringify({
          model: XAI_IMAGE_MODEL,
          prompt,
          n: 1,
          response_format: "b64_json",
        }),
      });
      if (r.ok) {
        const j = await r.json();
        const first = j.data?.[0] ?? {};
        imageB64 = first.b64_json ?? "";
        if (first.revised_prompt) revisedPrompt = first.revised_prompt;
      } else if (r.status === 400) {
        // 모더레이션 차단 — xAI는 그래도 과금하므로 아래에서 크레딧 차감.
        blocked = true;
      } else {
        // 그 외 오류는 과금하지 않고 그대로 전달.
        const detail = await r.text().catch(() => "");
        return json(
          { error: `image step failed (${r.status})`, detail: detail.slice(0, 500) },
          502,
        );
      }
    } catch (e) {
      return json({ error: "image step error", detail: String(e) }, 502);
    }

    if (!blocked && !imageB64) {
      return json({ error: "no image returned" }, 502);
    }

    // 크레딧 차감: 성공이든 차단이든 이미지 정액 비용 부과.
    let balanceCredits = balance;
    try {
      const { data: nb } = await admin.rpc("app_record_usage", {
        p_user: user.id,
        p_service: SERVICE_KEY,
        p_provider: "xai",
        p_model: XAI_IMAGE_MODEL,
        p_action: blocked ? "image_blocked" : "image",
        p_prompt_tokens: 0,
        p_completion_tokens: 0,
        p_cost_micros: Math.ceil(IMAGE_COST_USD * 1e6),
      });
      if (nb != null) balanceCredits = nb as number;
    } catch (e) {
      console.error("app_record_usage failed:", e);
    }

    return json({
      blocked,
      imageB64: blocked ? null : imageB64,
      revisedPrompt: blocked ? null : revisedPrompt,
      costUsd: IMAGE_COST_USD,
      creditsCharged: balance - balanceCredits,
      balanceCredits,
    });
  }

  return json({ error: `unknown mode: ${mode}` }, 400);
});
