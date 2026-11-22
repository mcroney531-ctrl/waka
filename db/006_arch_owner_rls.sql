-- Owner-only Row Level Security for all six arch_* tables (Waka).
-- Applies to the "Reading Center" Supabase project (ref fdbkdsracxomwyytfgob).
--
-- Requires 005_arch_owner_and_gate.sql (private.is_arch_owner()).
-- Apply only after both Waka pages ship sign-in (PR "Add owner sign-in") and
-- the owner has signed in on each device: from this point the signed-out
-- pages can't read or write anything, demo mode included.
--
-- For each table (the three real ones and the three demo ones):
--   * the old open policies (anon + authenticated, using (true)) are replaced
--     by owner-only ones with the same names, for the operations the pages
--     use: select, insert, update
--   * still no delete policy; removal stays a soft archive
--   * anon loses every privilege; authenticated keeps only select, insert,
--     update (no DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN)
--   * service_role and postgres are unchanged
-- The tables have no sequences (uuid keys), so there are no sequence grants.
-- Policies are written as (select private.is_arch_owner()) so the check runs
-- once per statement, not once per row.
--
-- Idempotent. Rollback: 006_arch_owner_rls-rollback.sql.

do $$
begin
  if to_regprocedure('private.is_arch_owner()') is null then
    raise exception 'apply 005_arch_owner_and_gate.sql first';
  end if;
end $$;

-- arch_titles: owner may select, insert, update; nobody may delete.
drop policy if exists arch_titles_select on public.arch_titles;
drop policy if exists arch_titles_insert on public.arch_titles;
drop policy if exists arch_titles_update on public.arch_titles;
create policy arch_titles_select on public.arch_titles
  for select to authenticated using ((select private.is_arch_owner()));
create policy arch_titles_insert on public.arch_titles
  for insert to authenticated with check ((select private.is_arch_owner()));
create policy arch_titles_update on public.arch_titles
  for update to authenticated using ((select private.is_arch_owner())) with check ((select private.is_arch_owner()));
alter table public.arch_titles enable row level security;
revoke all on public.arch_titles from anon, authenticated;
grant select, insert, update on public.arch_titles to authenticated;

-- arch_keywords: owner may select, insert, update; nobody may delete.
drop policy if exists arch_keywords_select on public.arch_keywords;
drop policy if exists arch_keywords_insert on public.arch_keywords;
drop policy if exists arch_keywords_update on public.arch_keywords;
create policy arch_keywords_select on public.arch_keywords
  for select to authenticated using ((select private.is_arch_owner()));
create policy arch_keywords_insert on public.arch_keywords
  for insert to authenticated with check ((select private.is_arch_owner()));
create policy arch_keywords_update on public.arch_keywords
  for update to authenticated using ((select private.is_arch_owner())) with check ((select private.is_arch_owner()));
alter table public.arch_keywords enable row level security;
revoke all on public.arch_keywords from anon, authenticated;
grant select, insert, update on public.arch_keywords to authenticated;

-- arch_brainstorms: owner may select, insert, update; nobody may delete.
drop policy if exists arch_brainstorms_select on public.arch_brainstorms;
drop policy if exists arch_brainstorms_insert on public.arch_brainstorms;
drop policy if exists arch_brainstorms_update on public.arch_brainstorms;
create policy arch_brainstorms_select on public.arch_brainstorms
  for select to authenticated using ((select private.is_arch_owner()));
create policy arch_brainstorms_insert on public.arch_brainstorms
  for insert to authenticated with check ((select private.is_arch_owner()));
create policy arch_brainstorms_update on public.arch_brainstorms
  for update to authenticated using ((select private.is_arch_owner())) with check ((select private.is_arch_owner()));
alter table public.arch_brainstorms enable row level security;
revoke all on public.arch_brainstorms from anon, authenticated;
grant select, insert, update on public.arch_brainstorms to authenticated;

-- arch_demo_titles: owner may select, insert, update; nobody may delete.
drop policy if exists arch_demo_titles_select on public.arch_demo_titles;
drop policy if exists arch_demo_titles_insert on public.arch_demo_titles;
drop policy if exists arch_demo_titles_update on public.arch_demo_titles;
create policy arch_demo_titles_select on public.arch_demo_titles
  for select to authenticated using ((select private.is_arch_owner()));
create policy arch_demo_titles_insert on public.arch_demo_titles
  for insert to authenticated with check ((select private.is_arch_owner()));
create policy arch_demo_titles_update on public.arch_demo_titles
  for update to authenticated using ((select private.is_arch_owner())) with check ((select private.is_arch_owner()));
alter table public.arch_demo_titles enable row level security;
revoke all on public.arch_demo_titles from anon, authenticated;
grant select, insert, update on public.arch_demo_titles to authenticated;

-- arch_demo_keywords: owner may select, insert, update; nobody may delete.
drop policy if exists arch_demo_keywords_select on public.arch_demo_keywords;
drop policy if exists arch_demo_keywords_insert on public.arch_demo_keywords;
drop policy if exists arch_demo_keywords_update on public.arch_demo_keywords;
create policy arch_demo_keywords_select on public.arch_demo_keywords
  for select to authenticated using ((select private.is_arch_owner()));
create policy arch_demo_keywords_insert on public.arch_demo_keywords
  for insert to authenticated with check ((select private.is_arch_owner()));
create policy arch_demo_keywords_update on public.arch_demo_keywords
  for update to authenticated using ((select private.is_arch_owner())) with check ((select private.is_arch_owner()));
alter table public.arch_demo_keywords enable row level security;
revoke all on public.arch_demo_keywords from anon, authenticated;
grant select, insert, update on public.arch_demo_keywords to authenticated;

-- arch_demo_brainstorms: owner may select, insert, update; nobody may delete.
drop policy if exists arch_demo_brainstorms_select on public.arch_demo_brainstorms;
drop policy if exists arch_demo_brainstorms_insert on public.arch_demo_brainstorms;
drop policy if exists arch_demo_brainstorms_update on public.arch_demo_brainstorms;
create policy arch_demo_brainstorms_select on public.arch_demo_brainstorms
  for select to authenticated using ((select private.is_arch_owner()));
create policy arch_demo_brainstorms_insert on public.arch_demo_brainstorms
  for insert to authenticated with check ((select private.is_arch_owner()));
create policy arch_demo_brainstorms_update on public.arch_demo_brainstorms
  for update to authenticated using ((select private.is_arch_owner())) with check ((select private.is_arch_owner()));
alter table public.arch_demo_brainstorms enable row level security;
revoke all on public.arch_demo_brainstorms from anon, authenticated;
grant select, insert, update on public.arch_demo_brainstorms to authenticated;

-- Policies are OR'ed, so one leftover permissive policy (any name) would
-- reopen a table. Fail the whole migration unless exactly the 18 owner-only
-- policies above remain on these tables.
do $$
declare extra text;
begin
  select string_agg(c.relname || '.' || p.polname, ', ') into extra
    from pg_policy p join pg_class c on c.oid = p.polrelid
   where c.relnamespace = 'public'::regnamespace
     and c.relname in ('arch_titles', 'arch_keywords', 'arch_brainstorms',
                       'arch_demo_titles', 'arch_demo_keywords', 'arch_demo_brainstorms')
     and not (p.polname = c.relname || '_' || case p.polcmd when 'r' then 'select' when 'a' then 'insert' when 'w' then 'update' end
              and p.polroles = array['authenticated'::regrole::oid]
              and p.polpermissive);
  if extra is not null then
    raise exception 'unexpected policies on arch_* tables: %', extra;
  end if;
end $$;
