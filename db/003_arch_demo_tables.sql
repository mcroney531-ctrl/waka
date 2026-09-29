-- Demo-mode twins of the three arch_ tables, used when the app is opened with ?demo=1.
-- Applied to the "Reading Center" Supabase project (ref fdbkdsracxomwyytfgob).
-- Structural clones (columns, defaults, check constraints, indexes). Holds sample data only.
create table if not exists public.arch_demo_titles     (like public.arch_titles     including all);
create table if not exists public.arch_demo_keywords   (like public.arch_keywords   including all);
create table if not exists public.arch_demo_brainstorms(like public.arch_brainstorms including all);

alter table public.arch_demo_titles      enable row level security;
alter table public.arch_demo_keywords    enable row level security;
alter table public.arch_demo_brainstorms enable row level security;

-- Same posture as the real tables: open select/insert/update to client roles, NO delete policy.
do $$
declare t text;
begin
  foreach t in array array['arch_demo_titles','arch_demo_keywords','arch_demo_brainstorms'] loop
    execute format('drop policy if exists %I on public.%I', t||'_select', t);
    execute format('drop policy if exists %I on public.%I', t||'_insert', t);
    execute format('drop policy if exists %I on public.%I', t||'_update', t);
    execute format('create policy %I on public.%I for select to anon, authenticated using (true)', t||'_select', t);
    execute format('create policy %I on public.%I for insert to anon, authenticated with check (true)', t||'_insert', t);
    execute format('create policy %I on public.%I for update to anon, authenticated using (true) with check (true)', t||'_update', t);
  end loop;
end $$;
