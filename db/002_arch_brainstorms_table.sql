-- Saved keyword-brainstorm conversations.
-- Applied to the "Reading Center" Supabase project (ref fdbkdsracxomwyytfgob).
-- Namespaced arch_* so it never collides with the project's other tables.

create table if not exists public.arch_brainstorms (
  id uuid primary key default gen_random_uuid(),
  title text not null default 'Untitled brainstorm',
  seed text,
  messages jsonb not null default '[]'::jsonb,  -- the Anthropic-shaped message history
  archived boolean not null default false,       -- soft-delete: "removed" chats stay but are hidden
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.arch_brainstorms enable row level security;

-- Same posture as arch_titles / arch_keywords: open select/insert/update to the
-- client-facing roles, NO delete policy. "Removing" a saved chat is a soft
-- archive (update archived=true), so the anon key can never hard-delete rows.
drop policy if exists "arch_brainstorms_select" on public.arch_brainstorms;
drop policy if exists "arch_brainstorms_insert" on public.arch_brainstorms;
drop policy if exists "arch_brainstorms_update" on public.arch_brainstorms;

create policy "arch_brainstorms_select" on public.arch_brainstorms
  for select to anon, authenticated using (true);
create policy "arch_brainstorms_insert" on public.arch_brainstorms
  for insert to anon, authenticated with check (true);
create policy "arch_brainstorms_update" on public.arch_brainstorms
  for update to anon, authenticated using (true) with check (true);
