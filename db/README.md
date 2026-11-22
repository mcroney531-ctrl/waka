# Waka data access (Reading Center, `fdbkdsracxomwyytfgob`)

Waka (the Documentary Acquisitions Ledger) keeps its data in six `arch_*`
tables in the shared Reading Center project, and has one edge function,
`brainstorm-keywords`, that spends on an Anthropic key.

| File | What it is |
|---|---|
| `001`–`004` | History: tables, the old **open** policies, demo tables and seed |
| [`005_arch_owner_and_gate.sql`](005_arch_owner_and_gate.sql) | Waka's owner allowlist, `is_arch_owner()`, the brainstorm rate-limit gate. Additive. |
| [`006_arch_owner_rls.sql`](006_arch_owner_rls.sql) | Owner-only RLS on all six tables, demo ones included |
| `*-rollback.sql` | Exact reversal of each (006's restores the old open state: emergency only) |
| `*-test.sql` | One transaction, always rolled back; reports pass/fail per check |

## Access model (after 005 + 006)

- **Allowlist.** `private.arch_owners` holds the human owner's Auth user id
  (`0ccc48c3-…`). It's Waka's own list, separate from Food-planning's
  `private.food_owners`. RLS on, no policies, no client privileges.
- **One user id, no shared list.** The check is "is `auth.uid()` this one id".
  Nothing else is granted to any other account. QuickSum's headless MCP
  currently signs in *as* that same user, so to the database it is the owner:
  that's a credential-isolation issue (a leaked MCP credential would reach
  Waka), not something a policy can tell apart. It doesn't block 005 or 006 —
  today the same tables are open to anyone with the public key — but Waka isn't
  fully isolated until the MCP has its own Auth user (QuickSum's track), which
  is never added here.
- **Ownership check.** `private.is_arch_owner()`: `SECURITY DEFINER`, owner
  `postgres`, empty `search_path`, no arguments (uses `auth.uid()` from the
  verified JWT). `EXECUTE` for `authenticated` only.
- **Tables.** On each of `arch_titles`, `arch_keywords`, `arch_brainstorms`
  and the three `arch_demo_*` tables:
  - owner-only select, insert, update policies, `to authenticated`,
    written as `(select private.is_arch_owner())`
  - no delete policy (removal is the `archived` flag)
  - `anon`: no privileges. `authenticated`: select, insert, update only.
    `service_role`: unchanged.
  - 006 fails if any other policy is left on these tables: policies are
    OR'ed, so one stray permissive policy would reopen a table.
- **Brainstorm function.** Requires a signed-in JWT, bounds the input, then
  calls `public.arch_brainstorm_gate()` with the caller's JWT. The gate checks
  the allowlist and the rate limit (20 calls / 10 min; 100 calls and 1,000,000
  input characters / 24 h) and records the call. The function reads the
  Anthropic key only after the gate allows the call. Details in the main
  README, "Keyword brainstorm".
- **Demo mode** (`?demo`) reads the `arch_demo_*` tables, so it now needs the
  owner signed in too.

## Prerequisites

1. **Anthropic key removed** (`ANTHROPIC_API_KEY` deleted from the project's
   Edge Function secrets) until step 6 below. Without it the current function
   refuses every call before spending anything.
2. **Before calling Waka fully secured:** the QuickSum MCP on its own Auth
   user (see "One user id" above). Not a blocker for the steps below.

## Deployment order (each step needs approval; verify before the next)

| # | Step | Verify |
|---|---|---|
| 1 | Merge the sign-in PR (Pages deploys `index.html`, `brainstorm.html`, `auth.js`, `sw.js` `dal-v5`) | Live files match the merge commit; signed-out pages still work (old open policies) |
| 2 | Owner signs in on each device (ledger and brainstorm) | "✓ Signed in" on both pages; reads/writes still work |
| 3 | Run `005_arch_owner_and_gate-test.sql` on production (rolled back) | `0 failed`, mode `pre-005` |
| 4 | Apply 005 (additive: no existing table, policy or grant changes) | Re-run its test: `0 failed`, mode `post-005`. **Real tokens**, from the live page's console (below): owner → `allowed`; non-owner → `not_owner`; signed out → refused |
| 5 | Deploy `brainstorm-keywords` (`index.ts` + `handler.ts`, `verify_jwt` on), key still removed | Real tokens: signed out → `401`; non-owner → `403`; owner → `503 "Brainstorm is not configured."` Then merge the PR as the record |
| 6 | Restore a valid `ANTHROPIC_API_KEY` | Owner brainstorm works; 21st call in 10 min → `429` |
| 7 | Run `006_arch_owner_rls-test.sql` on production (rolled back) | `0 failed`, mode `pre-006` |
| 8 | Apply 006 | Live checks below |

### Real-token checks (steps 4–5)

On the live `brainstorm.html`, open the browser console. `sb` is the page's
own client, so these use the real session token, and nothing to copy or paste
contains a secret:

```js
// step 4: the gate itself (records one call when allowed)
await sb.rpc('arch_brainstorm_gate', { p_input_chars: 0 })
// step 5: the function
await sb.functions.invoke('brainstorm-keywords', { body: { messages: [{ role: 'user', content: 'test' }] } })
```

Run each signed in as the owner, signed in as the non-owner test account, and
signed out. Expected results are in the table.

## Live checks after 006 (real sessions, not simulated claims)

With the publishable key and no session (curl or a private window):

- `GET /rest/v1/arch_keywords?select=id&limit=1` → `401`/`42501`, for all six tables
- `POST` an insert, `PATCH` an update, `DELETE` → `42501`
- `POST /rest/v1/rpc/arch_brainstorm_gate` → `401`/`42501`
- `POST /functions/v1/brainstorm-keywords` → `401` "Sign in to use the brainstorm."

As the **non-owner test account** (`24c39f7f-…`), signed in on the live pages:

- the ledger, keywords and brainstorm list are empty; demo mode is empty
- adding a keyword or title shows an error, and no row appears for the owner
- sending a brainstorm message → "This account isn't allowed to use the brainstorm."

As the **owner**, on the live pages:

- the ledger and keywords show the existing rows (102 keywords today);
  add, edit and archive work; the brainstorm list shows the saved chats
- a brainstorm turn works and its chips add keywords
- `?demo` shows the demo rows

## If something breaks: fix forward first

Reopening the tables to anonymous access is **not** the default rollback.
Prefer, in order:

1. **Owner locked out / data missing on the page.** The data is never at risk:
   the Supabase dashboard (Table editor, SQL editor) runs as `postgres` and
   isn't subject to RLS. Check the signed-in user id matches
   `private.arch_owners` (`select * from private.arch_owners;` in the SQL
   editor) and the page shows "✓ Signed in". Fix the allowlist or the session.
2. **One page workflow fails** (a query the policies don't allow). Add the
   missing owner-only policy or grant for that one operation (still
   `to authenticated using ((select private.is_arch_owner()))`), or switch
   that feature off, rather than reopening a table.
3. **The brainstorm misbehaves or spends unexpectedly.** Delete the
   `ANTHROPIC_API_KEY` secret: every call then stops before Anthropic. Tighten
   the limits in `public.arch_brainstorm_gate()` if needed.

Full rollbacks, last resort only:

- **006** (`006_arch_owner_rls-rollback.sql`): restores the old open
  policies and `grant all` to `anon` and `authenticated`, exactly as captured
  from production on 2026-11-22. Makes all six tables publicly readable and
  writable again; use only if none of the above works, and remove the
  Anthropic key at the same time.
- **Function**: don't redeploy the old version (v7) with a working key: it
  spends for anyone with the publishable key. Leave the gated version; with
  005 rolled back it refuses every call (fails closed).
- **005** (`005_arch_owner_and_gate-rollback.sql`): after 006's rollback.
  It refuses to run while 006's policies use `is_arch_owner()`. Leaves
  `private` and Food-planning's objects alone.

## Verification so far (local Postgres 16 configured like Supabase)

| Check | Result |
|---|---|
| 005 test: pre-005 / post-005 / post-006 | 43/43 in each; rollback = snapshot (0 differences) in pre-005 |
| 006 test: pre-006 / post-006 | 156/156 in each; rollback = snapshot (0 differences) in pre-006 |
| 20 concurrent gate calls with 5 slots left | exactly 5 allowed |
| Mutations (anon EXECUTE, off-by-one limit, no owner check, no `search_path`, anon grants left, DELETE granted, rollback without `grant all`, update without `with check`, stray open policy) | each caught |
| Edge function unit tests (`deno test`) | 46/46 |
