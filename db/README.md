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
- **Not the QuickSum MCP.** QuickSum's headless MCP must sign in as its own
  Auth user, which is never added here. Until it is moved off the shared owner
  account it would pass this check — see "Prerequisites".
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

1. **QuickSum MCP on its own Auth user** (QuickSum's track). Until then the
   MCP signs in as the owner and so would pass `is_arch_owner()`.
2. **Anthropic key stays invalid or removed** until step 5 below is done and
   verified. Don't restore a working key before the gated function is live.

## Deployment order (each step needs approval; verify before the next)

| # | Step | Verify |
|---|---|---|
| 1 | Merge the sign-in PR (Pages deploys `index.html`, `brainstorm.html`, `auth.js`, `sw.js` `dal-v5`) | Live files match the merge commit; signed-out pages still work (old open policies) |
| 2 | Owner signs in on each device (ledger and brainstorm) | "✓ Signed in" on both pages; reads/writes still work |
| 3 | Run `005_arch_owner_and_gate-test.sql` on production (rolled back) | `0 failed`, mode `pre-005` |
| 4 | Apply 005 | Re-run its test: `0 failed`, mode `post-005` |
| 5 | Deploy `brainstorm-keywords` (`index.ts` + `handler.ts`, `verify_jwt` on) | Signed out / publishable key → `401`; non-owner → `403`; owner → reaches the key check (`503 not configured` while the key is invalid) |
| 6 | Restore a valid `ANTHROPIC_API_KEY` | Owner brainstorm works; 21st call in 10 min → `429` |
| 7 | Run `006_arch_owner_rls-test.sql` on production (rolled back) | `0 failed`, mode `pre-006` |
| 8 | Apply 006 | Live checks below |

The QuickSum MCP isolation (prerequisite 1) has to be done before step 4.

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

## Rollback

- **006** (`006_arch_owner_rls-rollback.sql`): restores the old open
  policies and `grant all` to `anon` and `authenticated`, exactly as captured
  from production on 2026-11-22. Makes the six tables public again: use only
  if the owner is locked out and can't be fixed forward.
- **Function**: redeploy the previous version (v7) only together with an
  invalid or removed Anthropic key, because v7 spends for anyone with the
  publishable key. Simpler: leave the gated version; with 005 rolled back
  it refuses every call (fails closed).
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
