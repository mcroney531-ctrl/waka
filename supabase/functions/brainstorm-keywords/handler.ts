// Request handling for brainstorm-keywords, kept free of Deno.serve and
// Deno.env so it can be tested with stubbed fetch/env (handler_test.ts).
//
// Order of operations for every POST, cheapest and safest first:
//   1. require a signed-in user's JWT (a publishable/anon key is refused here)
//   2. read and validate the body: bounded size, roles, block types, counts
//   3. ask the database gate (public.arch_brainstorm_gate, db/005) with the
//      caller's own JWT: owner? within the rate limit? The call is recorded.
//   4. only then read the Anthropic key and call the API with a fixed model,
//      fixed tools, fixed system prompt and fixed max_tokens
//   5. return only the assistant turn's role, allowed content blocks and stop_reason
// Any failure before step 4 means no Anthropic request is made.

export const MODEL = "claude-opus-5"; // fixed; never taken from the request
// The project's publishable key (public by design; it is in both pages' source).
// It only identifies the project to the Data API; the caller's JWT decides the
// role. Used instead of SUPABASE_ANON_KEY because this project's legacy anon
// key is disabled. WAKA_PUBLISHABLE_KEY overrides it after a key rotation.
export const PUBLISHABLE_KEY = "sb_publishable_w5izyYtgIXD-pQvjlkn4jg_DtGJq_7j";
export const LIMITS = {
  bodyBytes: 200_000, // raw request body, before parsing
  inputChars: 64_000, // messages + existing terms, as sent upstream (same cap as the DB gate)
  messages: 40,
  blocksPerMessage: 20,
  userTextChars: 8_000, // one user-typed text block / string message
  blockChars: 20_000, // any one assistant/tool block (thinking can be long)
  existingTerms: 1_000,
  termChars: 200,
  maxTokens: 4_000, // output cap per call
  upstreamTimeoutMs: 90_000,
};

const CATEGORIES = ["person", "place", "event", "organization", "alias", "topic"];
const TOOL_NAME = "propose_keywords";

export const CORS = {
  "Access-Control-Allow-Origin": "*", // auth is a bearer token, not cookies, so CORS isn't the guard
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Expose-Headers": "retry-after",
};

function json(body: unknown, status = 200, extra: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json", ...extra },
  });
}

function systemPrompt(existing: string[]): string {
  const have = existing.length
    ? `Terms already in their tracker — do NOT propose these again:\n${existing.map((t) => "- " + t).join("\n")}`
    : "Their tracker has no keywords yet.";
  return `You are a research collaborator helping someone source rare and old geopolitical DOCUMENTARIES. They search WorldCat (a library catalog) with keywords, then track promising titles.

Your role in this conversation is to be a thinking partner for finding good search terms. Talk naturally and stay conversational — ask a clarifying question when it helps, suggest angles, react to what they say, and explain briefly why a term might surface something. Keep replies fairly short, not essay-length.

Whenever you have concrete search terms worth trying, call the propose_keywords tool with them (a sentence of framing alongside the call is fine). Favor non-obvious, specific proper nouns — people, places, events, organizations, alternate or foreign-language names, and adjacent topics — over generic phrases. Every term should be something they could actually type into a library catalog.

${have}`;
}

const TOOL = {
  name: TOOL_NAME,
  description:
    "Show the user a set of candidate WorldCat search terms they can add to their tracker with one click. Call this whenever you have specific terms worth trying. You may include a short text message alongside the call.",
  input_schema: {
    type: "object",
    properties: {
      keywords: {
        type: "array",
        description: "The candidate search terms.",
        items: {
          type: "object",
          properties: {
            term: { type: "string", description: "The term to type into WorldCat." },
            category: { type: "string", enum: CATEGORIES },
            rationale: { type: "string", description: "One short clause on why it might surface a documentary." },
          },
          required: ["term", "category", "rationale"],
        },
      },
    },
    required: ["keywords"],
  },
};

// ---------- validation ----------

type Block = Record<string, unknown>;
type Msg = { role: "user" | "assistant"; content: string | Block[] };

class Invalid extends Error {
  constructor(msg: string, public status = 400) {
    super(msg);
  }
}

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const str = (v: unknown, max: number, what: string): string => {
  if (typeof v !== "string") throw new Invalid(`${what} must be text.`);
  if (v.length > max) throw new Invalid(`${what} is too long.`, 413);
  return v;
};

// Rebuild each block from known fields only, so nothing the browser adds
// (images, documents, cache_control, server tools, ...) reaches the API.
function cleanBlock(b: unknown, role: Msg["role"]): Block {
  if (!isObj(b)) throw new Invalid("Malformed message block.");
  const t = b.type;
  if (role === "user") {
    if (t === "text") return { type: "text", text: str(b.text, LIMITS.userTextChars, "A message") };
    if (t === "tool_result") {
      const out: Block = { type: "tool_result", tool_use_id: str(b.tool_use_id, 200, "tool_use_id") };
      if (b.content !== undefined) out.content = str(b.content, 2_000, "A tool result");
      return out;
    }
  } else {
    if (t === "text") return { type: "text", text: str(b.text, LIMITS.blockChars, "A reply") };
    if (t === "thinking") {
      return { type: "thinking", thinking: str(b.thinking, LIMITS.blockChars, "A reply"), signature: str(b.signature, LIMITS.blockChars, "A signature") };
    }
    if (t === "redacted_thinking") return { type: "redacted_thinking", data: str(b.data, LIMITS.blockChars, "A reply") };
    if (t === "tool_use") {
      if (b.name !== TOOL_NAME) throw new Invalid("Unknown tool in conversation.");
      if (!isObj(b.input)) throw new Invalid("Malformed tool call.");
      if (JSON.stringify(b.input).length > LIMITS.blockChars) throw new Invalid("A reply is too long.", 413);
      return { type: "tool_use", id: str(b.id, 200, "tool id"), name: TOOL_NAME, input: b.input };
    }
  }
  throw new Invalid(`Unsupported content in a ${role} message.`);
}

export function validate(body: unknown): { messages: Msg[]; existing: string[]; inputChars: number } {
  if (!isObj(body)) throw new Invalid("No conversation to respond to.");
  const raw = body.messages;
  if (!Array.isArray(raw) || raw.length === 0) throw new Invalid("No conversation to respond to.");
  if (raw.length > LIMITS.messages) {
    throw new Invalid(`This brainstorm is too long (over ${LIMITS.messages} messages). Start a new one.`, 413);
  }

  const messages: Msg[] = raw.map((m) => {
    if (!isObj(m) || (m.role !== "user" && m.role !== "assistant")) throw new Invalid("Malformed message.");
    const role = m.role;
    if (typeof m.content === "string") {
      return { role, content: str(m.content, role === "user" ? LIMITS.userTextChars : LIMITS.blockChars, "A message") };
    }
    if (!Array.isArray(m.content) || m.content.length === 0 || m.content.length > LIMITS.blocksPerMessage) {
      throw new Invalid("Malformed message.");
    }
    return { role, content: m.content.map((b) => cleanBlock(b, role)) };
  });
  if (messages[0].role !== "user" || messages[messages.length - 1].role !== "user") {
    throw new Invalid("The conversation must start and end with your message.");
  }

  // Existing tracker terms: strings only, trimmed, deduplicated, bounded.
  // Over the cap, the most recent are kept (the browser sends oldest first).
  const ex = Array.isArray(body.existing) ? body.existing : [];
  const seen = new Set<string>();
  for (const v of ex) {
    if (typeof v !== "string") continue;
    const t = v.trim().slice(0, LIMITS.termChars);
    if (t) seen.add(t);
  }
  const existing = Array.from(seen).slice(-LIMITS.existingTerms);

  const inputChars = JSON.stringify(messages).length + existing.reduce((n, t) => n + t.length + 3, 0);
  if (inputChars > LIMITS.inputChars) {
    throw new Invalid("This brainstorm is too long to continue. Start a new one.", 413);
  }
  return { messages, existing, inputChars };
}

// ---------- handler ----------

export type Deps = {
  fetch: typeof fetch;
  env: (name: string) => string | undefined;
  log: (msg: string) => void;
};

type Gate = { allowed?: boolean; reason?: string; retry_after?: number };

export function createHandler(deps: Deps) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
    if (req.method !== "POST") return json({ error: "POST only" }, 405);

    // 1. A user session is required. The publishable key is not a JWT and an
    //    anon-role JWT is refused by the gate, so neither gets further than this.
    const authz = req.headers.get("authorization") ?? "";
    const token = /^Bearer\s+(\S+)$/i.exec(authz)?.[1] ?? "";
    if (token.split(".").length !== 3) return json({ error: "Sign in to use the brainstorm." }, 401);

    // 2. Bounded body.
    const declared = Number(req.headers.get("content-length") ?? "0");
    if (declared > LIMITS.bodyBytes) return json({ error: "Request too large." }, 413);
    let parsed: ReturnType<typeof validate>;
    try {
      const text = await req.text();
      if (new TextEncoder().encode(text).length > LIMITS.bodyBytes) return json({ error: "Request too large." }, 413);
      let body: unknown;
      try {
        body = JSON.parse(text);
      } catch {
        throw new Invalid("No conversation to respond to.");
      }
      parsed = validate(body);
    } catch (e) {
      if (e instanceof Invalid) return json({ error: e.message }, e.status);
      return json({ error: "Could not read the request." }, 400);
    }

    // 3. Owner check + rate limit, as the caller.
    const url = deps.env("SUPABASE_URL");
    const apikey = deps.env("WAKA_PUBLISHABLE_KEY") || PUBLISHABLE_KEY;
    if (!url) {
      deps.log("gate misconfigured: SUPABASE_URL missing");
      return json({ error: "Brainstorm is unavailable right now." }, 503);
    }
    let gate: Gate;
    try {
      const r = await deps.fetch(`${url}/rest/v1/rpc/arch_brainstorm_gate`, {
        method: "POST",
        headers: { apikey, authorization: `Bearer ${token}`, "content-type": "application/json" },
        body: JSON.stringify({ p_input_chars: parsed.inputChars }),
        signal: AbortSignal.timeout(10_000),
      });
      if (r.status === 401 || r.status === 403) {
        await r.body?.cancel();
        return json({ error: "Sign in again to use the brainstorm." }, 401);
      }
      if (!r.ok) {
        deps.log(`gate http ${r.status}`);
        await r.body?.cancel();
        return json({ error: "Brainstorm is unavailable right now." }, 503);
      }
      gate = await r.json();
    } catch (e) {
      deps.log(`gate unreachable: ${e instanceof Error ? e.name : "error"}`);
      return json({ error: "Brainstorm is unavailable right now." }, 503);
    }
    if (gate?.allowed !== true) {
      if (gate?.reason === "rate_limited") {
        const wait = Math.max(1, Math.ceil(Number(gate.retry_after) || 60));
        const mins = Math.ceil(wait / 60);
        return json(
          { error: `Brainstorm limit reached. Try again in ${mins >= 60 ? `${Math.ceil(mins / 60)} h` : `${mins} min`}.` },
          429,
          { "Retry-After": String(wait) },
        );
      }
      if (gate?.reason === "bad_input") return json({ error: "This brainstorm is too long to continue. Start a new one." }, 413);
      return json({ error: "This account isn't allowed to use the brainstorm." }, 403); // not_owner, or anything unexpected
    }

    // 4. Only now touch the paid API.
    const apiKey = (deps.env("ANTHROPIC_API_KEY") ?? "").trim().replace(/^["']|["']$/g, "").trim();
    if (!apiKey) {
      deps.log("ANTHROPIC_API_KEY not set");
      return json({ error: "Brainstorm is not configured." }, 503);
    }

    let upstream: Response;
    try {
      upstream = await deps.fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "content-type": "application/json", "x-api-key": apiKey, "anthropic-version": "2023-06-01" },
        body: JSON.stringify({
          model: MODEL,
          max_tokens: LIMITS.maxTokens,
          // Adaptive thinking left on (Opus 5 default): with tools present,
          // disabling thinking risks the model emitting a tool call as plain
          // text. Low effort keeps it snappy.
          output_config: { effort: "low" },
          system: systemPrompt(parsed.existing),
          tools: [TOOL],
          messages: parsed.messages,
        }),
        signal: AbortSignal.timeout(LIMITS.upstreamTimeoutMs),
      });
    } catch (e) {
      deps.log(`anthropic unreachable: ${e instanceof Error ? e.name : "error"}`);
      return json({ error: "Could not reach the AI service. Try again." }, 502);
    }

    if (!upstream.ok) {
      let errType = "";
      try {
        errType = (await upstream.json())?.error?.type ?? "";
      } catch { /* non-JSON body */ }
      // Status and error type only: never the key, any part of it, or its length.
      deps.log(`anthropic ${upstream.status} type=${errType}`);
      return json({ error: `AI service error (${upstream.status}). Try again later.` }, 502);
    }

    // 5. Bounded output: only the fields and block types the page uses.
    const data = await upstream.json();
    const content = (Array.isArray(data?.content) ? data.content : []).filter(
      (b: unknown) =>
        isObj(b) &&
        (b.type === "text" || b.type === "thinking" || b.type === "redacted_thinking" ||
          (b.type === "tool_use" && b.name === TOOL_NAME)),
    );
    return json({ role: "assistant", content, stop_reason: data?.stop_reason ?? null });
  };
}
