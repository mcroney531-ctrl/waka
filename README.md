# Documentary Acquisitions Ledger

A single-file, static tracker for sourcing and archiving rare/old geopolitical
documentaries — titles found via WorldCat and fulfilled through University of
Maryland duplication services or interlibrary loan (ILL). It is the tracking
backend of a larger, task-based build; the ILL email generator and keyword
brainstorm space are separate modules and are **not** part of this repo.

The tracker's job ends at **fulfilled** (title in hand). It intentionally does
not extend into the downstream public archive/publish workflow.

## What this is

- `index.html` — the entire app. React + Babel (in-browser) + `supabase-js`,
  all from CDNs. No build step. Open it, or serve it, and it runs.
- Two tabs: **Titles** (the acquisitions ledger) and **Keywords** (search
  terms to seed WorldCat lookups), in an "archive ledger" / card-catalog visual
  style (Special Elite / Lora / IBM Plex Mono, paper + stamp palette).

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

## Security posture (read before sharing the URL)

This is a personal, single-user, **no-auth** tool. The Supabase project URL and
publishable (anon) key are baked into `index.html`. That is by design — those
values are meant to be public; they are not secrets. Access is governed instead
by Row Level Security on the two `arch_` tables.

**Applied policy** (see `db/001_arch_public_rls_policies.sql`):

- `SELECT`, `INSERT`, `UPDATE` are open (`using (true)`) to the `anon` and
  `authenticated` roles so the browser app can function without a login.
- **No `DELETE` policy exists** — on purpose. The anon key can add and edit rows
  but **cannot delete** them, which caps the worst case to vandalism/edits
  rather than data loss.
- Policies target `anon, authenticated` explicitly rather than the implicit
  `PUBLIC` role (which in Postgres covers every role).

**The accepted tradeoff:** anyone who has the URL (and therefore the public key)
can read and write these two tables. For an unlinked personal tool this is fine.
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

- ILL email generator, keyword-brainstorm chat (separate modules)
- Any authentication / multi-user support
- Normalizing `keywords` into a foreign-key relationship
- Tracking anything past `fulfilled` (archive/publish workflow)
