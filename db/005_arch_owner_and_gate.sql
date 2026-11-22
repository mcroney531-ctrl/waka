-- Waka owner allowlist + the brainstorm-keywords call gate.
-- Applies to the "Reading Center" Supabase project (ref fdbkdsracxomwyytfgob).
--
-- ADDITIVE ONLY. It creates new objects and changes no existing table, policy
-- or grant: the six arch_* tables stay exactly as they are (owner-only RLS on
-- those tables is a separate migration, 006). Safe to run more than once.
--
-- What it adds:
--   private.arch_owners            who may use Waka (Waka's own list, separate
--                                  from Food-planning's private.food_owners)
--   private.is_arch_owner()        "is the signed-in user a Waka owner?"
--   private.arch_brainstorm_calls  one row per allowed brainstorm call
--   public.arch_brainstorm_gate()  what the edge function calls, with the
--                                  caller's own JWT, before it spends anything
--                                  on Anthropic: owner check + rate limit
--
-- The `private` schema already exists in production (Food-planning's
-- lockdown created it). Its grants are restated below unchanged: no access
-- for PUBLIC or anon, USAGE for authenticated. It is not in the Data API's
-- exposed schemas (only public and graphql_public are).
--
-- Rollback: 005_arch_owner_and_gate-rollback.sql (run 006's rollback first if
-- 006 has been applied, because its policies call private.is_arch_owner()).

create schema if not exists private;
revoke all on schema private from public;
revoke all on schema private from anon;
grant usage on schema private to authenticated;

-- 1. Allowlist. RLS on with no policies and no client privileges: only its
--    owner (postgres) can read it, i.e. only SECURITY DEFINER code below.
create table if not exists private.arch_owners (
  user_id  uuid primary key references auth.users(id) on delete cascade,
  added_at timestamptz not null default now()
);
alter table private.arch_owners owner to postgres;
alter table private.arch_owners enable row level security;
revoke all on private.arch_owners from public, anon, authenticated, service_role;

-- The human owner only. Never add the QuickSum MCP's identity here: it must
-- run as its own Auth user, which this list does not contain.
insert into private.arch_owners (user_id) values ('0ccc48c3-77e5-4b82-85b9-036e26cf4f53')
on conflict (user_id) do nothing;

-- 2. Ownership check, for RLS policies (006). SECURITY DEFINER only so it can
--    read the allowlist; empty search_path; no arguments, so a caller can only
--    ask about themselves.
create or replace function private.is_arch_owner()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from private.arch_owners
    where user_id = (select auth.uid())
  );
$$;
alter function private.is_arch_owner() owner to postgres;
revoke all on function private.is_arch_owner() from public, anon, service_role;
grant execute on function private.is_arch_owner() to authenticated;

-- 3. Call log for the rate limit. Rows older than two days are pruned by the
--    gate itself, so it stays small.
create table if not exists private.arch_brainstorm_calls (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  called_at   timestamptz not null default now(),
  input_chars integer not null check (input_chars >= 0)
);
create index if not exists arch_brainstorm_calls_user_time
  on private.arch_brainstorm_calls (user_id, called_at);
alter table private.arch_brainstorm_calls owner to postgres;
alter table private.arch_brainstorm_calls enable row level security;
revoke all on private.arch_brainstorm_calls from public, anon, authenticated, service_role;
revoke all on sequence private.arch_brainstorm_calls_id_seq from public, anon, authenticated, service_role;

-- 4. The gate. The edge function calls it through the Data API with the
--    caller's own Authorization header, so auth.uid() is the verified caller:
--      * no JWT / publishable key only -> role anon, which has no EXECUTE
--        (the Data API answers 401/42501 and the function stops)
--      * signed in but not on the allowlist -> {"allowed": false, "reason": "not_owner"}
--      * owner over a limit -> {"allowed": false, "reason": "rate_limited", "retry_after": seconds}
--      * otherwise the call is recorded and {"allowed": true, ...} returned
--    Limits: 20 calls per 10 minutes, 100 calls and 1,000,000 input
--    characters per 24 hours. The edge function independently caps one
--    request at 64,000 characters, and this refuses a claimed size above that.
--    Calls are counted when allowed, before Anthropic is called, so failed
--    upstream calls still count: the limit caps attempts, not just successes.
create or replace function public.arch_brainstorm_gate(p_input_chars integer)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  uid       uuid := (select auth.uid());
  max_chars constant integer := 64000;
  per_10m   constant integer := 20;
  per_day   constant integer := 100;
  chars_day constant bigint  := 1000000;
  n_10m     integer;
  n_day     integer;
  c_day     bigint;
  wait_s    integer;
begin
  if uid is null or not exists (select 1 from private.arch_owners where user_id = uid) then
    return jsonb_build_object('allowed', false, 'reason', 'not_owner');
  end if;

  if p_input_chars is null or p_input_chars < 0 or p_input_chars > max_chars then
    return jsonb_build_object('allowed', false, 'reason', 'bad_input');
  end if;

  -- Serialise this owner's concurrent calls so two requests can't both pass
  -- the count before either is recorded.
  perform 1 from private.arch_owners where user_id = uid for update;

  delete from private.arch_brainstorm_calls where called_at < now() - interval '2 days';

  select count(*) filter (where called_at > now() - interval '10 minutes'),
         count(*),
         coalesce(sum(input_chars), 0)
    into n_10m, n_day, c_day
    from private.arch_brainstorm_calls
   where user_id = uid and called_at > now() - interval '24 hours';

  if n_10m >= per_10m then
    select ceil(extract(epoch from (min(called_at) + interval '10 minutes' - now())))::integer
      into wait_s
      from (select called_at from private.arch_brainstorm_calls
             where user_id = uid and called_at > now() - interval '10 minutes'
             order by called_at desc limit per_10m) recent;
    return jsonb_build_object('allowed', false, 'reason', 'rate_limited', 'retry_after', greatest(wait_s, 1));
  end if;

  if n_day >= per_day or c_day + p_input_chars > chars_day then
    select ceil(extract(epoch from (min(called_at) + interval '24 hours' - now())))::integer
      into wait_s
      from private.arch_brainstorm_calls
     where user_id = uid and called_at > now() - interval '24 hours';
    return jsonb_build_object('allowed', false, 'reason', 'rate_limited', 'retry_after', greatest(coalesce(wait_s, 60), 1));
  end if;

  insert into private.arch_brainstorm_calls (user_id, input_chars) values (uid, p_input_chars);

  return jsonb_build_object('allowed', true,
                            'remaining_10m', per_10m - n_10m - 1,
                            'remaining_day', per_day - n_day - 1);
end;
$$;
alter function public.arch_brainstorm_gate(integer) owner to postgres;
-- New functions in public default to EXECUTE for PUBLIC, and Supabase's
-- default privileges add anon/authenticated/service_role. Keep only authenticated.
revoke all on function public.arch_brainstorm_gate(integer) from public, anon, authenticated, service_role;
grant execute on function public.arch_brainstorm_gate(integer) to authenticated;
