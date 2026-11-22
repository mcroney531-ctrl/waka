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

- `arch_titles` — the ledger. Clicking a title opens a detail **modal** with
  route, status, format (VHS/DVD/Other), maker, ISBN, location(s), call number,
  ILL fields, dates, and notes. `keywords` is **deliberately free text**
  (whatever term surfaced the title), not a foreign key into `arch_keywords` —
  a conscious simplification for a solo tracker, not an oversight.
- `arch_keywords` — search terms with an `unsearched` / `searched` status. Each
  term links straight to a WorldCat search for it, and the list sorts by
  newest/oldest/A–Z/Z–A.
- `arch_brainstorms` — saved brainstorm conversations (added with the chat
  module). See "Keyword brainstorm" below.

## Security posture (read before sharing the URL)

The Supabase project URL and publishable key are baked into the pages. That is
by design — they identify the project and are not secrets. Access is decided by
who is signed in:

- **Owner sign-in** (email + password, Supabase Auth; public sign-ups are off).
  Both pages share one session (`auth.js`).
- **Owner-only Row Level Security** on all six `arch_*` tables, demo tables
  included (`db/006_arch_owner_rls.sql`): only the user on Waka's allowlist
  (`private.arch_owners`, `db/005_arch_owner_and_gate.sql`) can read, add or
  edit. Nobody signed out can read or write anything. There is still **no
  delete** anywhere; removal is a soft archive.
- **The brainstorm function** spends only for the signed-in owner, within a
  rate limit (see "Keyword brainstorm" below).

`db/README.md` has the access model, the deployment order, the live owner /
non-owner checks and the rollback procedures. `db/001`–`004` are the history:
the earlier open, no-auth policies that 006 replaces.

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
so nothing is ever truly deleted from the app. Promoted keywords live in
`arch_keywords` regardless of what happens to the chat.

**Under the hood.** The page keeps the message history in the browser and sends
it to the edge function each turn, which relays it to the Anthropic Messages API
with a `propose_keywords` tool (that tool is what produces the chips — chat needs
prose, so the terms come through a tool call rather than a forced-JSON response).

**How the AI stays secure on a static host.** The page cannot call the
Anthropic API directly — that would expose a real API key in public page
source. Instead it invokes a **Supabase Edge Function** (`brainstorm-keywords`,
in `supabase/functions/`) which calls Anthropic **server-side**. The key lives
only as a project secret; the browser never sees it.

**Who can make it spend money.** Only the signed-in owner. `verify_jwt` alone
isn't enough (the public publishable key passes the gateway), so on every call
the function, before it reads the Anthropic key:

1. requires a signed-in user's JWT — the publishable key alone gets `401`;
2. validates the body: at most 200 KB raw and 64,000 characters sent upstream,
   40 messages, 20 blocks a message, 8,000 characters per typed message; only
   `user`/`assistant` roles and the block types the page produces (text,
   thinking, `propose_keywords` calls and their results) — images, documents,
   other tools and extra fields are refused or stripped; at most 1,000 existing
   terms of 200 characters;
3. calls `public.arch_brainstorm_gate()` **with the caller's own JWT**
   (`db/005_arch_owner_and_gate.sql`). The gate checks `private.arch_owners`
   (Waka's own allowlist — not Food-planning's, and never the QuickSum MCP's
   account) and the rate limit — 20 calls per 10 minutes, 100 calls and
   1,000,000 input characters per 24 hours — and records the call. A non-owner
   gets `403`, over the limit `429` with `Retry-After`;
4. only then calls Anthropic, with the model (`claude-opus-5`), tool, system
   prompt and `max_tokens` (4,000) fixed in code — nothing from the request
   can change them — and a 90-second timeout;
5. returns only `role`, `content` (text, thinking, `propose_keywords` calls)
   and `stop_reason`.

Errors are logged as status and error type only, never the key or any part of
it. Tests: `deno test supabase/functions/brainstorm-keywords/handler_test.ts`
(stubbed network) and `psql -f db/005_arch_owner_and_gate-test.sql` (one
transaction, always rolled back).

**Setup — the Anthropic key as a Supabase secret.** Set it only after the
gated function is deployed:

- Supabase dashboard → **Project Settings → Edge Functions → Secrets** → add
  `ANTHROPIC_API_KEY` = your Anthropic API key, **or**
- CLI: `supabase secrets set ANTHROPIC_API_KEY=sk-ant-… --project-ref fdbkdsracxomwyytfgob`

The key must be a real Anthropic **API** key (from console.anthropic.com), which
is separate from a Claude.ai subscription. Cost is a few cents per brainstorm,
billed to that key. Without it the function answers "Brainstorm is not
configured." (after the owner and rate checks).

To redeploy the function after editing it: `supabase functions deploy
brainstorm-keywords --project-ref fdbkdsracxomwyytfgob` (or via the dashboard).
Deploy `index.ts` and `handler.ts` together, and apply `db/005` first —
without the gate the function refuses every call.

## Install on your phone (PWA)

The ledger is an installable web app: `manifest.webmanifest`, an archive-ledger
icon set (`icons/`), and a small `sw.js` service worker. On the live (HTTPS)
Pages URL, Android Chrome should offer **⋮ → Install app** (a real WebAPK, not a
bookmark shortcut); iOS uses the Safari share sheet → **Add to Home Screen**. It
launches full-screen with the icon, no browser chrome.

**Icon requirements (so Android installs a real WebAPK, not a shortcut).** The
manifest lists **separate** `any` and `maskable` entries at **both** 192×192 and
512×512 — never a combined `"any maskable"` entry (that hits a Chrome WebAPK
icon-resolution bug and silently falls back to a shortcut). The maskable PNGs
pad the logo into the inner ~80% safe zone (art centered on black). All icons
regenerate from `icons/icon-source.png` via `sharp` (see the generator used in
the commit history).
Verify installability from Chrome DevTools → Application → Manifest, or by
checking that the ⋮ menu says "Install app" — not "Add to Home screen". The service worker is deliberately conservative — app pages are
network-first (a deploy is never stuck behind a stale cache) and Supabase
traffic is never cached — so "installed" mostly means home-screen + standalone,
with the shell still loading offline. Service workers only run over HTTPS (or
localhost), so this activates on the Pages URL, not on a `file://` open.

The ledger header also has a **WorldCat ↗** link to the UMD discovery catalog
(`umaryland.on.worldcat.org/discovery`) for quick access while working the list.

## Demo mode (for screen recordings / showing the app)

Open either page with `?demo=1` (e.g. `…/waka/index.html?demo=1`) and the app reads
and writes a separate set of **sample-data** tables — `arch_demo_titles`,
`arch_demo_keywords`, `arch_demo_brainstorms` — instead of the real ones. A small
dashed **Sample data** tag appears in the header, and the Ledger ↔ Brainstorm links
carry `?demo=1` across so you stay in demo mode. The saved-conversations sidebar
is part of the switch, so real chat history never shows up in a demo.

- **Fails closed:** every query goes through one `TBL` lookup, so in demo mode the
  real tables are never referenced. Without the flag the app behaves exactly as
  before.
- **Sample content:** ~24 mainstream-history keywords (Apollo 11, Panama Canal,
  Silk Road…) that are real, searchable WorldCat terms, and 8 well-known
  documentaries (real titles/years/creators, mixed statuses so the tally and
  stamps look alive). OCLC/ISBN are intentionally blank — no invented identifiers.
- **Live edits stick** (the demo tables persist), so you can add a title or promote
  a brainstormed keyword on camera. The brainstorm chat still calls the real edge
  function, so a live chat on a safe topic works.
- **Reset:** re-run `db/004_arch_demo_seed.sql` (owner-run; wipes and reseeds the
  demo tables only). Tables are in `db/003_arch_demo_tables.sql`; RLS is owner-only
  like the real tables, with no delete policy. To remove demo mode entirely, drop
  the three `arch_demo_*` tables.
- It's a client-side switch, **not a security boundary**. The demo tables have the
  same owner-only RLS as the real ones (`db/006`), so demo mode needs the owner
  signed in too.

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
