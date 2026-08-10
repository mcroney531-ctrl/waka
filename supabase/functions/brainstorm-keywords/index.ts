// Supabase Edge Function: brainstorm-keywords
//
// Conversational keyword brainstorming. The browser sends the full message
// history each turn; this function calls the Anthropic Messages API SERVER-SIDE
// (the API key never touches the browser) and returns the assistant turn.
//
// Claude replies in natural prose and calls the `propose_keywords` tool when it
// has concrete search terms — the browser renders those as one-click chips.
//
// Setup: set ANTHROPIC_API_KEY as a project secret (Project Settings -> Edge
// Functions -> Secrets, or `supabase secrets set`).
// Auth: verify_jwt is ON — callers present the project's anon key, which
// supabase-js `functions.invoke` sends automatically.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const MODEL = "claude-opus-5";
const CATEGORIES = ["person", "place", "event", "organization", "alias", "topic"];

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
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
  name: "propose_keywords",
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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) {
    return json({
      error:
        "ANTHROPIC_API_KEY is not set on this project. Add it under Project Settings -> Edge Functions -> Secrets.",
    }, 500);
  }

  let messages: unknown = [];
  let existing: string[] = [];
  try {
    const body = await req.json();
    messages = body?.messages;
    existing = Array.isArray(body?.existing) ? body.existing.map(String) : [];
  } catch {
    // handled by the validation below
  }
  if (!Array.isArray(messages) || messages.length === 0) {
    return json({ error: "No conversation to respond to." }, 400);
  }

  let anthropicResp: Response;
  try {
    anthropicResp = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 4000,
        // Adaptive thinking left on (Opus 5 default): with tools present,
        // disabling thinking risks the model emitting a tool call as plain
        // text. Low effort keeps it snappy.
        output_config: { effort: "low" },
        system: systemPrompt(existing),
        tools: [TOOL],
        messages,
      }),
    });
  } catch (e) {
    return json({ error: `Could not reach the Anthropic API: ${String(e)}` }, 502);
  }

  if (!anthropicResp.ok) {
    const detail = await anthropicResp.text();
    return json({ error: `Anthropic API error (${anthropicResp.status})`, detail }, 502);
  }

  const data = await anthropicResp.json();
  // Return the full assistant turn verbatim — including any thinking blocks —
  // so the browser can store it and replay it unchanged on the next turn.
  return json({
    role: data.role ?? "assistant",
    content: data.content ?? [],
    stop_reason: data.stop_reason ?? null,
  });
});
