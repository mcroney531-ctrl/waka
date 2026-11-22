// Supabase Edge Function: brainstorm-keywords
//
// Conversational keyword brainstorming for the signed-in Waka owner. The
// browser sends the message history each turn; this function checks the
// caller, then calls the Anthropic Messages API SERVER-SIDE (the API key never
// touches the browser) and returns the assistant turn. Claude replies in prose
// and calls the `propose_keywords` tool when it has concrete search terms —
// the browser renders those as one-click chips.
//
// Access (see handler.ts and db/005_arch_owner_and_gate.sql):
//   * the caller must send a signed-in user's JWT; the publishable key alone
//     is refused before anything else happens
//   * public.arch_brainstorm_gate(), called with that JWT, must say the user
//     is on private.arch_owners and within the rate limit
//   * the model, tools, system prompt and max_tokens are fixed here; inputs
//     are size-, count- and type-bounded
// verify_jwt stays ON at the gateway as well.
//
// Secrets: ANTHROPIC_API_KEY (Project Settings -> Edge Functions -> Secrets).
// SUPABASE_URL is provided by the platform. The gate call uses the project's
// publishable key (handler.ts), overridable with WAKA_PUBLISHABLE_KEY.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createHandler } from "./handler.ts";

Deno.serve(createHandler({
  fetch: (input, init) => fetch(input, init),
  env: (name) => Deno.env.get(name),
  log: (msg) => console.error(msg),
}));
