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

## Status (2026-11-22)

**Live in production.** The six tables are owner-only, and the brainstorm
function is gated. The Anthropic key is **deliberately absent**, so the
brainstorm answers "Brainstorm is not configured." Turning it back on is a
separate decision about cost (see "Turning the brainstorm on" below).

| | |
|---|---|
| Repo | `main` at `1e6f78a` (#1 `dc1d88d`, #2 `0942a0b`, #3 `1e6f78a`) |
| Migrations | `20261122195146 arch_owner_and_gate` (005), `20261122213855 arch_owner_rls` (006) |
| Edge function | `brainstorm-keywords` v9, `verify_jwt` on, files byte-identical to `main` |
| Open item | QuickSum's MCP still signs in as the owner (see "One user id" above): tracked in QuickSum's work |

## Rollout record

Every step was approved separately and verified before the next. All
production tests ran in a single transaction that ended in an error, so
nothing persisted. Before/after fingerprints confirmed that every time.

| # | Step | Evidence |
|---|---|---|
| 1 | Merged #1 (sign-in) | Live Pages files byte-identical to `dc1d88d`; both pages loaded signed out, data still open |
| 2 | Owner signed in on the phone | Both pages "✓ Signed in"; existing data loaded; an edit saved |
| 3 | 005 test on production, before applying | 43/43, mode `pre-005`. Access fingerprint `82d9eb35…` and all data hashes identical before and after |
| 4 | Applied 005 (file hash `1762786b…`) | Post-005 test 43/43. The pre-existing access state still matched `82d9eb35…`; only 005's objects were added. The allowlist holds only the owner. Signed-out gate call → `401 42501`, and `private` isn't reachable (`PGRST106`) |
| 5 | Removed `ANTHROPIC_API_KEY`; deployed the function from `aacd9ba` as v9 | Probe before deploying → `500 "not set"`. Deployed source read back and byte-identical. Publishable key or no auth → `401`; forged JWT → `401 Invalid JWT` |
| 5a | Real-session checks on the phone | Owner → "Brainstorm is not configured."; test account → "This account isn't allowed…"; signed out → "Sign in to use the brainstorm." The call log showed 1 owner call and 0 others, and Anthropic was never called |
| 5b | Merged #2, pinned to `4c23db6` | `main` function files byte-identical to v9 |
| 6 | 006 test on production, before applying (with `lock_timeout 3s`, `statement_timeout 60s`) | 156/156, mode `pre-006`. Access fingerprint `f8b3368a…` and all data hashes identical before and after |
| 7 | Applied 006 (file hash `340651b5…`) | Post-006 test 156/156. Exactly 18 owner-only policies; grants `authenticated=arw` only; data hashes unchanged. With the publishable key, select, insert, update and delete on all six tables → `401 42501` (24/24) |
| 8 | Phone checks after 006 | Owner: ledger loads, keyword add and edit persist, saved chats load, `?demo` loads. Signed out: no data. Test account: no data, and its test keyword was refused (confirmed absent in the database) |
| 9 | Merged #3, pinned to `45ea0e0` | `main` = `1e6f78a`; signed-out read still `401` |

## Turning the brainstorm on

Add `ANTHROPIC_API_KEY` under Project Settings → Edge Functions → Secrets.
Then send one brainstorm message as the owner. It should get a reply, and the
call should count against the rate limit (20 per 10 minutes, 100 per day).
No code or database change is needed.

## Setting up a fresh project

The same order applies; adapt the ids:

1. Ship the sign-in pages, then sign in as the owner.
2. Run the 005 test (expect `pre-005`), apply 005, then re-run the test (`post-005`).
3. Deploy the function (`index.ts` and `handler.ts`, `verify_jwt` on), with no Anthropic key yet.
4. Check with real sessions that signed out → `401`, non-owner → `403`, and owner → `503 not configured`.
5. Run the 006 test (`pre-006`), apply 006, then re-run the test (`post-006`).
6. Do the live checks below.
7. Add the Anthropic key when you want the brainstorm.

## Live checks after 006 (real sessions, not simulated claims)

With the publishable key and no session (curl or a private window), check the
HTTP status, not just an empty result:

- `GET`, `POST`, `PATCH` and `DELETE` on all six tables → `401` / `42501`
- `POST /rest/v1/rpc/arch_brainstorm_gate` → `401` / `42501`
- `POST /functions/v1/brainstorm-keywords` → `401` "Sign in to use the brainstorm."

As the **non-owner test account**, in a private tab on the live pages:

- the ledger, keywords, brainstorm list and demo mode are all empty
- adding a keyword (use something unmistakable, like `ZZ-NONOWNER-TEST-DELETE-ME`)
  fails, and the database shows no such row
- sending a brainstorm message → "This account isn't allowed to use the brainstorm."

As the **owner**, on the live pages:

- the ledger and keywords show the existing rows
- adding a keyword and changing its status both persist after a reload
  (there's no delete, so use a real term)
- the brainstorm list shows the saved chats, and `?demo` shows the demo rows

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

## Local verification (Postgres 16 configured like Supabase)

| Check | Result |
|---|---|
| 005 test: pre-005 / post-005 / post-006 | 43/43 in each; rollback = snapshot (0 differences) in pre-005 |
| 006 test: pre-006 / post-006 | 156/156 in each; rollback = snapshot (0 differences) in pre-006 |
| 20 concurrent gate calls with 5 slots left | exactly 5 allowed |
| Mutations (anon EXECUTE, off-by-one limit, no owner check, no `search_path`, anon grants left, DELETE granted, rollback without `grant all`, update without `with check`, stray open policy) | each caught |
| Edge function unit tests (`deno test`) | 46/46 |
