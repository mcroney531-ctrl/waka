// Supabase Edge Function: brainstorm-keywords
//
// Generates candidate WorldCat search keywords for a seed topic by calling the
// Anthropic Messages API SERVER-SIDE. The Anthropic API key never touches the
// browser — it lives only as the ANTHROPIC_API_KEY project secret (set it under
// Project Settings -> Edge Functions -> Secrets, or `supabase secrets set`).
//
// Auth: verify_jwt is ON, so callers must present the project's anon key. The
// browser app sends it automatically via supabase-js `functions.invoke`.
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

  let seed = "";
  let existing: string[] = [];
  try {
    const body = await req.json();
    seed = String(body?.seed ?? "").trim();
    existing = Array.isArray(body?.existing) ? body.existing.map(String) : [];
  } catch {
    // fall through to the empty-seed check
  }
  if (!seed) return json({ error: "Provide a seed topic or term." }, 400);

  const existingNote = existing.length
    ? `\n\nThe user has ALREADY logged these terms, so do NOT repeat them:\n${
      existing.map((t) => `- ${t}`).join("\n")
    }`
    : "";

  const prompt =
    `You are helping someone source rare and old geopolitical DOCUMENTARIES by generating keywords to search in WorldCat (a library catalog).

Seed topic: "${seed}"

Generate 18-25 search terms that could surface documentaries related to this topic, favoring the non-obvious ones a casual searcher would miss. Draw from across these categories:
- person: key figures, filmmakers, leaders, witnesses
- place: cities, regions, countries, specific sites
- event: specific incidents, operations, campaigns, dated episodes
- organization: movements, agencies, armed groups, tribunals
- alias: alternate spellings, foreign-language terms, historical or contemporaneous names
- topic: adjacent themes and framings worth a separate search

Prefer specific proper nouns over generic phrases. Every term should be something you would actually type into a library catalog search. Keep each rationale to one short clause.${existingNote}`;

  const schema = {
    type: "object",
    properties: {
      keywords: {
        type: "array",
        items: {
          type: "object",
          properties: {
            term: { type: "string" },
            category: { type: "string", enum: CATEGORIES },
            rationale: { type: "string" },
          },
          required: ["term", "category", "rationale"],
          additionalProperties: false,
        },
      },
    },
    required: ["keywords"],
    additionalProperties: false,
  };

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
        thinking: { type: "disabled" },
        output_config: { format: { type: "json_schema", schema } },
        messages: [{ role: "user", content: prompt }],
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
  const textBlock = (data.content ?? []).find((b: { type: string }) => b.type === "text");
  if (!textBlock?.text) return json({ error: "Empty response from the model." }, 502);

  let keywords: unknown;
  try {
    keywords = JSON.parse(textBlock.text).keywords;
  } catch {
    return json({ error: "Could not parse the model's output." }, 502);
  }
  if (!Array.isArray(keywords)) return json({ error: "Model output was not a keyword list." }, 502);

  return json({ keywords });
});
