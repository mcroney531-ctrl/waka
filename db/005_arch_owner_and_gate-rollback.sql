-- Rollback for 005_arch_owner_and_gate.sql.
--
-- Order matters:
--   1. If 006 (owner-only RLS) is applied, run its rollback first: its
--      policies call private.is_arch_owner(), so this drop would fail.
--   2. Redeploy the previous brainstorm-keywords function (or leave the gated
--      one: without the gate RPC it refuses every call, i.e. fails closed).
--   3. Run this file.
--
-- Leaves the `private` schema and everything Food-planning owns in it
-- (food_owners, is_food_owner) untouched.

drop function if exists public.arch_brainstorm_gate(integer);
drop table if exists private.arch_brainstorm_calls;
drop function if exists private.is_arch_owner();
drop table if exists private.arch_owners;
