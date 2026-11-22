-- Rollback for 006_arch_owner_rls.sql: restores the previous OPEN state
-- exactly (as captured from production on 2026-11-22): open select / insert /
-- update policies for anon + authenticated, no delete policy, and full table
-- privileges for anon and authenticated ("grant all" also restores MAINTAIN
-- on Postgres 17). Emergency use only — it makes all six tables readable and
-- writable by anyone with the public key again.
-- Leaves 005 (allowlist, gate) in place; roll that back separately, after this.

drop policy if exists arch_titles_select on public.arch_titles;
drop policy if exists arch_titles_insert on public.arch_titles;
drop policy if exists arch_titles_update on public.arch_titles;
create policy arch_titles_select on public.arch_titles for select to anon, authenticated using (true);
create policy arch_titles_insert on public.arch_titles for insert to anon, authenticated with check (true);
create policy arch_titles_update on public.arch_titles for update to anon, authenticated using (true) with check (true);
grant all on public.arch_titles to anon, authenticated;

drop policy if exists arch_keywords_select on public.arch_keywords;
drop policy if exists arch_keywords_insert on public.arch_keywords;
drop policy if exists arch_keywords_update on public.arch_keywords;
create policy arch_keywords_select on public.arch_keywords for select to anon, authenticated using (true);
create policy arch_keywords_insert on public.arch_keywords for insert to anon, authenticated with check (true);
create policy arch_keywords_update on public.arch_keywords for update to anon, authenticated using (true) with check (true);
grant all on public.arch_keywords to anon, authenticated;

drop policy if exists arch_brainstorms_select on public.arch_brainstorms;
drop policy if exists arch_brainstorms_insert on public.arch_brainstorms;
drop policy if exists arch_brainstorms_update on public.arch_brainstorms;
create policy arch_brainstorms_select on public.arch_brainstorms for select to anon, authenticated using (true);
create policy arch_brainstorms_insert on public.arch_brainstorms for insert to anon, authenticated with check (true);
create policy arch_brainstorms_update on public.arch_brainstorms for update to anon, authenticated using (true) with check (true);
grant all on public.arch_brainstorms to anon, authenticated;

drop policy if exists arch_demo_titles_select on public.arch_demo_titles;
drop policy if exists arch_demo_titles_insert on public.arch_demo_titles;
drop policy if exists arch_demo_titles_update on public.arch_demo_titles;
create policy arch_demo_titles_select on public.arch_demo_titles for select to anon, authenticated using (true);
create policy arch_demo_titles_insert on public.arch_demo_titles for insert to anon, authenticated with check (true);
create policy arch_demo_titles_update on public.arch_demo_titles for update to anon, authenticated using (true) with check (true);
grant all on public.arch_demo_titles to anon, authenticated;

drop policy if exists arch_demo_keywords_select on public.arch_demo_keywords;
drop policy if exists arch_demo_keywords_insert on public.arch_demo_keywords;
drop policy if exists arch_demo_keywords_update on public.arch_demo_keywords;
create policy arch_demo_keywords_select on public.arch_demo_keywords for select to anon, authenticated using (true);
create policy arch_demo_keywords_insert on public.arch_demo_keywords for insert to anon, authenticated with check (true);
create policy arch_demo_keywords_update on public.arch_demo_keywords for update to anon, authenticated using (true) with check (true);
grant all on public.arch_demo_keywords to anon, authenticated;

drop policy if exists arch_demo_brainstorms_select on public.arch_demo_brainstorms;
drop policy if exists arch_demo_brainstorms_insert on public.arch_demo_brainstorms;
drop policy if exists arch_demo_brainstorms_update on public.arch_demo_brainstorms;
create policy arch_demo_brainstorms_select on public.arch_demo_brainstorms for select to anon, authenticated using (true);
create policy arch_demo_brainstorms_insert on public.arch_demo_brainstorms for insert to anon, authenticated with check (true);
create policy arch_demo_brainstorms_update on public.arch_demo_brainstorms for update to anon, authenticated using (true) with check (true);
grant all on public.arch_demo_brainstorms to anon, authenticated;
