# Documentary Acquisitions Ledger

A single-file, static tracker for sourcing and archiving rare/old geopolitical
documentaries — titles found via WorldCat and fulfilled through University of
Maryland duplication services or interlibrary loan (ILL). It is the tracking
backend of a larger, task-based build; the ILL email generator and keyword
brainstorm space are separate modules and are **not** part of this repo.

The tracker's job ends at **fulfilled** (title in hand). It intentionally does
not extend into the downstream public archive/publish workflow.

## What this is

- `index.html` — the tracker. React + Babel (in-browser) + `supabase-js`,
  all from CDNs. No build step. Open it, or serve it, and it runs. Two tabs:
  **Titles** (the acquisitions ledger) and **Keywords** (search terms to seed
  WorldCat lookups).
- `brainstorm.html` — an AI keyword-brainstorm chat (see "Keyword brainstorm"
  below), linked from the ledger header.
- Both share one "archive ledger" / card-catalog visual style (Special Elite /
  Lora / IBM Plex Mono, paper + stamp palette).

## Data layer

The app talks directly to Supabase from the browser via `supabase-js`
(`sb.from('arch_titles')…`). It reuses the existing **Reading Center** Supabase
project (project ref `fdbkdsracxomwyytfgob`); its tables are namespaced with an
`arch_` prefix so they never collide with that project's other tables. Only the
two `arch_` tables are touched.

> Note on lineage: the original prototype read/wrote Supabase indirectly, by
> asking an LLM (with the Supabase MCP server attached) to run the SQL. That
> only works inside the Claude.ai artifact sandbox and adds a ~1–2s round-trip
> per click. This version replaced that with direct `supabase-js` calls — same
> UI and design system, instant reads/writes, and no API key in page source.

### Tables (already live in Supabase)

- `arch_titles` — the ledger. `keywords` is **deliberately free text** (whatever
  term surfaced the title), not a foreign key into `arch_keywords`. That's a
  conscious simplification for a solo tracker, not an oversight.
- `arch_keywords` — search terms with an `unsearched` / `searched` status.
- `arch_brainstorms` — saved brainstorm conversations (added with the chat
  module). See "Keyword brainstorm" below.

## Security posture (read before sharing the URL)

This is a personal, single-user, **no-auth** tool. The Supabase project URL and
publishable (anon) key are baked into the pages. That is by design — those
values are meant to be public; they are not secrets. Access is governed instead
by Row Level Security on the three `arch_` tables.

**Applied policy** (see `db/001_arch_public_rls_policies.sql` and
`db/002_arch_brainstorms_table.sql`):

- `SELECT`, `INSERT`, `UPDATE` are open (`using (true)`) to the `anon` and
  `authenticated` roles so the browser app can function without a login.
- **No `DELETE` policy exists on any table** — on purpose. The anon key can add
  and edit rows but **cannot delete** them, which caps the worst case to
  vandalism/edits rather than data loss. (Removing a saved brainstorm is a soft
  archive via `UPDATE`, not a delete.)
- Policies target `anon, authenticated` explicitly rather than the implicit
  `PUBLIC` role (which in Postgres covers every role).

**The accepted tradeoff:** anyone who has the URL (and therefore the public key)
can read and write these tables. For an unlinked personal tool this is fine.
It was a deliberate call, not a default — and it was reached after ruling out
the alternatives:

- A "shared secret" checked in RLS would be security theater here, because the
  secret would sit in the same public page source.
- Without auth, RLS cannot distinguish "the owner" from "anyone" — the anon role
  is the anon role. So open policies are the honest floor.

**Upgrade path (if this ever gets linked, shared, or goes multi-user):** add
Supabase Auth (magic link is enough for one user) and replace the open policies
with `auth.uid()`-scoped ones. That is the real fix and it does not require
rebuilding the UI. It was left out of this pass on purpose.

## Keyword brainstorm (AI, `brainstorm.html`)

A second page, linked from the ledger header: a **conversation** with Claude
about what to search. Ask ("documentaries on the Rwandan genocide — what should
I search?"), then steer ("more obscure," "focus on the filmmakers," "anything in
French"). Claude replies in prose and, when it has concrete terms, surfaces them
as selectable chips — people, places, events, organizations, alternate/foreign
names, and adjacent topics, each with a one-line rationale. Select the useful
ones and they promote into the tracker's `arch_keywords` table (`source` tagged
`brainstorm: <title>`, status `unsearched`). Terms already tracked are dimmed
and can't be re-added.

**Saved sessions.** Each conversation auto-saves to the `arch_brainstorms` table
and appears in the sidebar to reopen, rename, or remove. Removing is a soft
archive (`archived = true`) — consistent with the no-hard-delete posture below,
so nothing is ever truly deleted via the anon key. Promoted keywords live in
`arch_keywords` regardless of what happens to the chat.

**Under the hood.** The page keeps the message history in the browser and sends
it to the edge function each turn, which relays it to the Anthropic Messages API
with a `propose_keywords` tool (that tool is what produces the chips — chat needs
prose, so the terms come through a tool call rather than a forced-JSON response).

**How the AI stays secure on a static host.** The page cannot call the
Anthropic API directly — that would expose a real API key in public page
source. Instead it invokes a **Supabase Edge Function** (`brainstorm-keywords`,
in `supabase/functions/`) which calls Anthropic **server-side**. The key lives
only as a project secret; the browser never sees it. The function keeps
`verify_jwt` on, so it's reachable only with the project's anon key — the same
posture as the tables.

**One-time setup — set the Anthropic key as a Supabase secret.** The function
is deployed but returns a clear "key not set" message until you do this:

- Supabase dashboard → **Project Settings → Edge Functions → Secrets** → add
  `ANTHROPIC_API_KEY` = your Anthropic API key, **or**
- CLI: `supabase secrets set ANTHROPIC_API_KEY=sk-ant-… --project-ref fdbkdsracxomwyytfgob`

The key must be a real Anthropic **API** key (from console.anthropic.com), which
is separate from a Claude.ai subscription. Model: `claude-opus-5`; cost is a few
cents per brainstorm, billed to that key.

To redeploy the function after editing it: `supabase functions deploy
brainstorm-keywords --project-ref fdbkdsracxomwyytfgob` (or via the dashboard).

## Deploying to GitHub Pages

`index.html` is at the repo root, so Pages can serve it as-is:

1. Merge this branch into the repo's default branch.
2. In the repo: **Settings → Pages → Build and deployment**.
3. Source: **Deploy from a branch**. Branch: your default branch, folder `/ (root)`.
4. Save. The site publishes at `https://mcroney531-ctrl.github.io/waka/`.

No secrets or build configuration are required — everything the page needs is in
the single file. Keep the published URL unlinked/private per the security note
above.

## Explicitly out of scope

- ILL email generator (a separate module, not yet built)
- Any authentication / multi-user support
- Normalizing `keywords` into a foreign-key relationship
- Tracking anything past `fulfilled` (archive/publish workflow)
