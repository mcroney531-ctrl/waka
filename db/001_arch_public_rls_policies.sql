-- Row Level Security policies for the Documentary Acquisitions Ledger.
-- Applied to the "Reading Center" Supabase project (ref fdbkdsracxomwyytfgob).
-- Scope: ONLY the two arch_* tables. Does not touch any other table.
--
-- Posture (deliberate — see README "Security posture"):
--   * SELECT / INSERT / UPDATE are open to the client-facing roles so the
--     no-auth browser app can function.
--   * NO DELETE policy is defined on purpose -> the anon key cannot wipe rows,
--     which caps the worst-case blast radius to edits/inserts rather than loss.
--   * Policies target anon + authenticated explicitly instead of the implicit
--     PUBLIC role (which in Postgres covers every role).
-- If this tool ever gets linked/shared/multi-user, replace these with
-- auth.uid()-scoped policies behind Supabase Auth.

-- arch_titles ---------------------------------------------------------------
drop policy if exists "arch_titles_select" on public.arch_titles;
drop policy if exists "arch_titles_insert" on public.arch_titles;
drop policy if exists "arch_titles_update" on public.arch_titles;

create policy "arch_titles_select" on public.arch_titles
  for select to anon, authenticated using (true);
create policy "arch_titles_insert" on public.arch_titles
  for insert to anon, authenticated with check (true);
create policy "arch_titles_update" on public.arch_titles
  for update to anon, authenticated using (true) with check (true);

-- arch_keywords -------------------------------------------------------------
drop policy if exists "arch_keywords_select" on public.arch_keywords;
drop policy if exists "arch_keywords_insert" on public.arch_keywords;
drop policy if exists "arch_keywords_update" on public.arch_keywords;

create policy "arch_keywords_select" on public.arch_keywords
  for select to anon, authenticated using (true);
create policy "arch_keywords_insert" on public.arch_keywords
  for insert to anon, authenticated with check (true);
create policy "arch_keywords_update" on public.arch_keywords
  for update to anon, authenticated using (true) with check (true);
