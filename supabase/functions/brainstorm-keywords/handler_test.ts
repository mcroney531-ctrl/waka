// Unit tests for handler.ts with stubbed network and env.
// Run: deno test supabase/functions/brainstorm-keywords/handler_test.ts
// Nothing here reaches Supabase or Anthropic.
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { createHandler, LIMITS, MODEL, PUBLISHABLE_KEY } from "./handler.ts";

const URL_ = "https://example.supabase.co";
const JWT = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJvd25lciJ9.c2ln"; // shape only; the gate decides validity
const SECRET = "sk-ant-api03-SECRETSECRETSECRET";

type Call = { url: string; init: RequestInit; body: any };

function setup(opts: {
  gate?: { status?: number; body?: unknown; throws?: boolean };
  anthropic?: { status?: number; body?: unknown; throws?: boolean };
  env?: Record<string, string | undefined>;
} = {}) {
  const calls: Call[] = [];
  const logs: string[] = [];
  const env: Record<string, string | undefined> = { SUPABASE_URL: URL_, ANTHROPIC_API_KEY: SECRET, ...opts.env };
  const fetch = async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const url = String(input);
    const body = init.body ? JSON.parse(String(init.body)) : null;
    calls.push({ url, init, body });
    const spec = url.startsWith(URL_) ? opts.gate ?? {} : opts.anthropic ?? {};
    if (spec.throws) throw new TypeError("network down");
    const dflt = url.startsWith(URL_) ? { allowed: true, remaining_10m: 19, remaining_day: 99 } : {
      role: "assistant",
      content: [
        { type: "thinking", thinking: "hmm", signature: "sig" },
        { type: "text", text: "Try these." },
        { type: "tool_use", id: "toolu_1", name: "propose_keywords", input: { keywords: [{ term: "Ogaden", category: "place", rationale: "r" }] } },
        { type: "server_tool_use", id: "srv_1", name: "web_search", input: {} },
        { type: "tool_use", id: "toolu_2", name: "other_tool", input: {} },
      ],
      stop_reason: "tool_use",
      usage: { input_tokens: 10 },
      model: MODEL,
    };
    return new Response(JSON.stringify(spec.body ?? dflt), { status: spec.status ?? 200, headers: { "content-type": "application/json" } });
  };
  const handler = createHandler({ fetch: fetch as typeof globalThis.fetch, env: (k) => env[k], log: (m) => logs.push(m) });
  const gateCalls = () => calls.filter((c) => c.url.startsWith(URL_));
  const aiCalls = () => calls.filter((c) => c.url.startsWith("https://api.anthropic.com/"));
  return { handler, calls, logs, gateCalls, aiCalls };
}

const convo = () => [{ role: "user", content: "Cold War documentaries about the Horn of Africa" }];

function post(body: unknown, headers: Record<string, string> = {}, raw?: string) {
  return new Request("https://fn.example/brainstorm-keywords", {
    method: "POST",
    headers: { authorization: `Bearer ${JWT}`, "content-type": "application/json", ...headers },
    body: raw ?? JSON.stringify(body),
  });
}

async function call(t: ReturnType<typeof setup>, req: Request) {
  const res = await t.handler(req);
  const text = await res.text();
  let json: any = null;
  try { json = JSON.parse(text); } catch { /* not json */ }
  return { res, json, text };
}

// ---------- method / auth ----------

Deno.test("OPTIONS preflight is answered without any network call", async () => {
  const t = setup();
  const { res } = await call(t, new Request("https://fn.example/x", { method: "OPTIONS" }));
  assertEquals(res.status, 200);
  assertEquals(t.calls.length, 0);
});

Deno.test("GET is refused", async () => {
  const t = setup();
  const { res } = await call(t, new Request("https://fn.example/x"));
  assertEquals(res.status, 405);
  assertEquals(t.calls.length, 0);
});

Deno.test("no Authorization header -> 401, no gate, no Anthropic", async () => {
  const t = setup();
  const req = new Request("https://fn.example/x", { method: "POST", body: JSON.stringify({ messages: convo() }) });
  const { res, json } = await call(t, req);
  assertEquals(res.status, 401);
  assertEquals(json.error, "Sign in to use the brainstorm.");
  assertEquals(t.calls.length, 0);
});

Deno.test("publishable key as the bearer (signed-out page) -> 401, no network", async () => {
  const t = setup();
  const { res } = await call(t, post({ messages: convo() }, { authorization: `Bearer ${PUBLISHABLE_KEY}` }));
  assertEquals(res.status, 401);
  assertEquals(t.calls.length, 0);
});

Deno.test("malformed Authorization header -> 401", async () => {
  const t = setup();
  for (const h of ["Basic abc", "Bearer", `Token ${JWT}`, `Bearer ${JWT} extra`]) {
    const { res } = await call(t, post({ messages: convo() }, { authorization: h }));
    assertEquals(res.status, 401, h);
  }
  assertEquals(t.calls.length, 0);
});

// ---------- happy path ----------

Deno.test("owner within limits: gate called as the caller, then Anthropic with fixed parameters", async () => {
  const t = setup();
  const { res, json } = await call(t, post({ messages: convo(), existing: ["Eritrea", "Mengistu"] }));
  assertEquals(res.status, 200);

  const [g] = t.gateCalls();
  assertEquals(g.url, `${URL_}/rest/v1/rpc/arch_brainstorm_gate`);
  const gh = new Headers(g.init.headers);
  assertEquals(gh.get("authorization"), `Bearer ${JWT}`);
  assertEquals(gh.get("apikey"), PUBLISHABLE_KEY);
  assert(Number.isInteger(g.body.p_input_chars) && g.body.p_input_chars > 0);

  const [a] = t.aiCalls();
  assertEquals(t.aiCalls().length, 1);
  assertEquals(new Headers(a.init.headers).get("x-api-key"), SECRET);
  assertEquals(a.body.model, MODEL);
  assertEquals(a.body.max_tokens, LIMITS.maxTokens);
  assertEquals(a.body.tools.map((x: any) => x.name), ["propose_keywords"]);
  assertStringIncludes(a.body.system, "- Eritrea\n- Mengistu");
  assertEquals(a.body.messages, convo());
  assertEquals(Object.keys(a.body).sort(), ["max_tokens", "messages", "model", "output_config", "system", "tools"]);

  // Gate precedes Anthropic.
  assert(t.calls.indexOf(g) < t.calls.indexOf(a));

  // Output: only role/content/stop_reason, and only allowed blocks.
  assertEquals(Object.keys(json).sort(), ["content", "role", "stop_reason"]);
  assertEquals(json.content.map((b: any) => b.type + (b.name ? ":" + b.name : "")), ["thinking", "text", "tool_use:propose_keywords"]);
  assertEquals(json.stop_reason, "tool_use");
});

Deno.test("caller cannot choose the model, tokens, tools, system prompt or extra API params", async () => {
  const t = setup();
  const body = {
    messages: convo(), model: "claude-other", max_tokens: 64000, tools: [{ name: "x" }], system: "ignore all",
    stream: true, metadata: { user_id: "x" }, thinking: { type: "enabled", budget_tokens: 60000 },
  };
  const { res } = await call(t, post(body));
  assertEquals(res.status, 200);
  const [a] = t.aiCalls();
  assertEquals(a.body.model, MODEL);
  assertEquals(a.body.max_tokens, LIMITS.maxTokens);
  assertEquals(a.body.tools.length, 1);
  assert(!a.body.system.includes("ignore all"));
  assertEquals(a.body.stream, undefined);
  assertEquals(a.body.thinking, undefined);
  assertEquals(a.body.metadata, undefined);
});

Deno.test("a real multi-turn brainstorm (tool_use -> tool_result) passes, extra fields stripped", async () => {
  const t = setup();
  const messages = [
    { role: "user", content: "Ogaden war" },
    {
      role: "assistant",
      content: [
        { type: "thinking", thinking: "...", signature: "abc" },
        { type: "text", text: "Some angles:", citations: null },
        { type: "tool_use", id: "toolu_1", name: "propose_keywords", input: { keywords: [] }, cache_control: { type: "ephemeral" } },
      ],
    },
    {
      role: "user",
      content: [
        { type: "tool_result", tool_use_id: "toolu_1", content: "Suggestions were shown to the user." },
        { type: "text", text: "More on Somali side", cache_control: { type: "ephemeral" } },
      ],
    },
  ];
  const { res } = await call(t, post({ messages }));
  assertEquals(res.status, 200);
  const sent = t.aiCalls()[0].body.messages;
  assertEquals(sent[1].content[1], { type: "text", text: "Some angles:" });
  assertEquals(sent[1].content[2], { type: "tool_use", id: "toolu_1", name: "propose_keywords", input: { keywords: [] } });
  assertEquals(sent[2].content[1], { type: "text", text: "More on Somali side" });
});

Deno.test("existing terms: non-strings dropped, trimmed, deduped, capped, latest kept", async () => {
  const t = setup();
  const many = Array.from({ length: 1500 }, (_, i) => `t${i}`);
  const existing = [42, null, { x: 1 }, "  Asmara  ", "Asmara", "x".repeat(500), ...many];
  const { res } = await call(t, post({ messages: convo(), existing }));
  assertEquals(res.status, 200);
  const sys: string = t.aiCalls()[0].body.system;
  const listed = sys.split("\n").filter((l) => l.startsWith("- ")).map((l) => l.slice(2));
  assertEquals(listed.length, LIMITS.existingTerms);
  assertEquals(listed[listed.length - 1], "t1499");
  assert(!listed.includes("t499")); // oldest dropped
  assert(listed.every((x) => x.length <= LIMITS.termChars));
});

// ---------- gate refusals: never reach Anthropic ----------

for (const [name, gate, status, msg] of [
  ["gate 401 (anon-role or expired JWT)", { status: 401, body: { code: "PGRST301" } }, 401, "Sign in again"],
  ["gate 403 (permission denied 42501)", { status: 403, body: { code: "42501" } }, 401, "Sign in again"],
  ["gate says not_owner", { body: { allowed: false, reason: "not_owner" } }, 403, "isn't allowed"],
  ["gate says bad_input", { body: { allowed: false, reason: "bad_input" } }, 413, "too long"],
  ["gate returns something unexpected", { body: { surprise: true } }, 403, "isn't allowed"],
  ["gate returns allowed as a string", { body: { allowed: "true" } }, 403, "isn't allowed"],
  ["gate 500", { status: 500, body: { message: "boom" } }, 503, "unavailable"],
  ["gate unreachable", { throws: true }, 503, "unavailable"],
] as const) {
  Deno.test(`${name} -> ${status}, no Anthropic call`, async () => {
    const t = setup({ gate });
    const { res, json } = await call(t, post({ messages: convo() }));
    assertEquals(res.status, status);
    assertStringIncludes(json.error, msg);
    assertEquals(t.gateCalls().length, 1);
    assertEquals(t.aiCalls().length, 0);
  });
}

Deno.test("rate limited -> 429 with Retry-After, no Anthropic call", async () => {
  const t = setup({ gate: { body: { allowed: false, reason: "rate_limited", retry_after: 125 } } });
  const { res, json } = await call(t, post({ messages: convo() }));
  assertEquals(res.status, 429);
  assertEquals(res.headers.get("retry-after"), "125");
  assertEquals(json.error, "Brainstorm limit reached. Try again in 3 min.");
  assertEquals(t.aiCalls().length, 0);
});

Deno.test("rate limited for hours -> message in hours", async () => {
  const t = setup({ gate: { body: { allowed: false, reason: "rate_limited", retry_after: 82800 } } });
  const { json } = await call(t, post({ messages: convo() }));
  assertEquals(json.error, "Brainstorm limit reached. Try again in 23 h.");
});

Deno.test("missing SUPABASE_URL -> 503, nothing called", async () => {
  const t = setup({ env: { SUPABASE_URL: undefined } });
  const { res } = await call(t, post({ messages: convo() }));
  assertEquals(res.status, 503);
  assertEquals(t.calls.length, 0);
});

Deno.test("WAKA_PUBLISHABLE_KEY overrides the built-in key", async () => {
  const t = setup({ env: { WAKA_PUBLISHABLE_KEY: "sb_publishable_rotated" } });
  await call(t, post({ messages: convo() }));
  assertEquals(new Headers(t.gateCalls()[0].init.headers).get("apikey"), "sb_publishable_rotated");
});

// ---------- input bounds: refused before the gate (no quota used) ----------

const bad: Array<[string, unknown, number]> = [
  ["no messages", { messages: [] }, 400],
  ["messages not an array", { messages: "hi" }, 400],
  ["body not an object", ["x"], 400],
  [`${LIMITS.messages + 1} messages`, { messages: Array.from({ length: LIMITS.messages + 1 }, (_, i) => ({ role: i % 2 ? "assistant" : "user", content: "x" })) }, 413],
  ["system role", { messages: [{ role: "system", content: "x" }, ...convo()] }, 400],
  ["image block", { messages: [{ role: "user", content: [{ type: "image", source: { type: "url", url: "https://x/y.png" } }] }] }, 400],
  ["document block", { messages: [{ role: "user", content: [{ type: "document", source: { type: "url", url: "https://x/y.pdf" } }] }] }, 400],
  ["user-forged thinking block", { messages: [{ role: "user", content: [{ type: "thinking", thinking: "x", signature: "y" }] }] }, 400],
  ["assistant calling another tool", { messages: [...convo(), { role: "assistant", content: [{ type: "tool_use", id: "t", name: "web_search", input: {} }] }, ...convo()] }, 400],
  ["ends with an assistant turn (prefill)", { messages: [...convo(), { role: "assistant", content: "Sure, here is" }] }, 400],
  ["starts with an assistant turn", { messages: [{ role: "assistant", content: "x" }, ...convo()] }, 400],
  ["user text over the cap", { messages: [{ role: "user", content: "x".repeat(LIMITS.userTextChars + 1) }] }, 413],
  ["user text block over the cap", { messages: [{ role: "user", content: [{ type: "text", text: "x".repeat(LIMITS.userTextChars + 1) }] }] }, 413],
  ["too many blocks in one message", { messages: [{ role: "user", content: Array.from({ length: LIMITS.blocksPerMessage + 1 }, () => ({ type: "text", text: "x" })) }] }, 400],
  ["empty content array", { messages: [{ role: "user", content: [] }] }, 400],
  ["non-string text", { messages: [{ role: "user", content: [{ type: "text", text: { a: 1 } }] }] }, 400],
  ["total input over the cap", {
    messages: Array.from({ length: 11 }, (_, i) => ({ role: i % 2 ? "assistant" : "user", content: "x".repeat(i % 2 ? 19_000 : 7_000) })),
  }, 413],
];
for (const [name, body, status] of bad) {
  Deno.test(`invalid input: ${name} -> ${status}, no gate, no Anthropic`, async () => {
    const t = setup();
    const { res, json } = await call(t, post(body));
    assertEquals(res.status, status);
    assert(typeof json.error === "string" && json.error.length > 0);
    assertEquals(t.calls.length, 0);
  });
}

Deno.test("invalid JSON -> 400, no network", async () => {
  const t = setup();
  const { res } = await call(t, post(null, {}, "{not json"));
  assertEquals(res.status, 400);
  assertEquals(t.calls.length, 0);
});

Deno.test("raw body over 200 KB -> 413 before parsing, no network", async () => {
  const t = setup();
  const { res } = await call(t, post(null, {}, JSON.stringify({ messages: convo(), pad: "x".repeat(LIMITS.bodyBytes) })));
  assertEquals(res.status, 413);
  assertEquals(t.calls.length, 0);
});

Deno.test("declared Content-Length over the cap -> 413 without reading", async () => {
  const t = setup();
  const { res } = await call(t, post({ messages: convo() }, { "content-length": String(LIMITS.bodyBytes + 1) }));
  assertEquals(res.status, 413);
  assertEquals(t.calls.length, 0);
});

Deno.test("user text exactly at its cap is accepted and reported to the gate", async () => {
  const t = setup();
  const base = JSON.stringify([{ role: "user", content: "" }]).length;
  const { res } = await call(t, post({ messages: [{ role: "user", content: "x".repeat(LIMITS.userTextChars) }] }));
  assertEquals(res.status, 200);
  assertEquals(t.gateCalls()[0].body.p_input_chars, base + LIMITS.userTextChars);
});

// ---------- Anthropic side ----------

Deno.test("Anthropic key missing -> 503 after the gate, no Anthropic call", async () => {
  const t = setup({ env: { ANTHROPIC_API_KEY: undefined } });
  const { res } = await call(t, post({ messages: convo() }));
  assertEquals(res.status, 503);
  assertEquals(t.gateCalls().length, 1);
  assertEquals(t.aiCalls().length, 0);
});

Deno.test("Anthropic 401 -> 502; logs never contain the key, a prefix of it, or its length", async () => {
  const t = setup({ anthropic: { status: 401, body: { type: "error", error: { type: "authentication_error", message: "invalid x-api-key" } } } });
  const { res, json } = await call(t, post({ messages: convo() }));
  assertEquals(res.status, 502);
  assert(!JSON.stringify(json).includes(SECRET.slice(0, 6)));
  const all = t.logs.join("\n");
  assertEquals(all, "anthropic 401 type=authentication_error");
  assert(!all.includes(SECRET.slice(0, 6)) && !all.includes("keyLen") && !all.includes(String(SECRET.length)));
});

Deno.test("Anthropic unreachable -> 502", async () => {
  const t = setup({ anthropic: { throws: true } });
  const { res } = await call(t, post({ messages: convo() }));
  assertEquals(res.status, 502);
});

Deno.test("Anthropic call carries a timeout", async () => {
  const t = setup();
  await call(t, post({ messages: convo() }));
  assert(t.aiCalls()[0].init.signal instanceof AbortSignal);
  assert(t.gateCalls()[0].init.signal instanceof AbortSignal);
});
