-- Test for 005_arch_owner_and_gate.sql (Reading Center).
--
-- Runs ENTIRELY inside one transaction that ends in ROLLBACK: nothing persists.
--   1. snapshot the access state of everything 005 could touch
--   2. apply 005 (and apply it a second time, to prove it's idempotent)
--   3. call the gate as anon, service_role, signed-in non-owner, owner
--      (each probe in its own sub-transaction, undone immediately)
--   4. drive the rate limits with synthetic call-log rows
--   5. check direct access to the private objects, the function contract,
--      and that Food-planning's objects and the arch_* tables are untouched
--   6. apply the 005 rollback and verify the state matches the snapshot
-- Claims are simulated with request.jwt.claims; the real-JWT path is tested
-- end to end through the deployed edge function.
--
-- Run with psql from the repo root:  psql -f db/005_arch_owner_and_gate-test.sql
-- (\ir includes the migration and rollback files next to this one.)
-- Production run: the same text with the two \ir lines inlined, via the SQL
-- editor or the Supabase MCP, before 005 is applied.
begin;

create temp table _res (ord serial, label text, expect text, outcome text, pass boolean);
grant all on _res to public;
grant all on sequence _res_ord_seq to public;

-- Everything 005 could plausibly change: the arch_* tables' policies and
-- grants, the private schema, and every object in it (Food-planning's too).
create function pg_temp.state() returns setof text language sql as $s$
  select 'policy '||c.relname||' '||p.polname||' '||p.polcmd::text||' '||(select string_agg(rolname, ',' order by rolname) from pg_roles where oid = any(p.polroles))||' q='||coalesce(pg_get_expr(p.polqual, p.polrelid),'-')||' c='||coalesce(pg_get_expr(p.polwithcheck, p.polrelid),'-')
    from pg_policy p join pg_class c on c.oid = p.polrelid
   where (c.relnamespace = 'public'::regnamespace and c.relname like 'arch\_%') or c.relnamespace::regnamespace::text = 'private'
  union all
  select 'rel '||c.relnamespace::regnamespace::text||'.'||c.relname||' kind='||c.relkind::text||' rls='||c.relrowsecurity::text||' owner='||pg_get_userbyid(c.relowner)||' acl='||coalesce(array_to_string(array(select x::text from unnest(c.relacl) x order by 1), ' '), '-')
    from pg_class c
   where (c.relnamespace = 'public'::regnamespace and c.relname like 'arch\_%') or c.relnamespace::regnamespace::text = 'private'
  union all
  select 'fn '||p.oid::regprocedure::text||' definer='||p.prosecdef::text||' owner='||pg_get_userbyid(p.proowner)||' cfg='||coalesce(array_to_string(p.proconfig, ','), '-')||' acl='||coalesce(array_to_string(array(select x::text from unnest(p.proacl) x order by 1), ' '), '-')||' src='||md5(p.prosrc)
    from pg_proc p
   where p.pronamespace::regnamespace::text = 'private' or (p.pronamespace = 'public'::regnamespace and p.proname like 'arch\_%')
  union all
  select 'schema private acl='||coalesce(array_to_string(array(select x::text from unnest(n.nspacl) x order by 1), ' '), '-')
    from pg_namespace n where n.nspname = 'private'
  union all
  select 'food_owners rows='||(select count(*) from private.food_owners)::text
   where to_regclass('private.food_owners') is not null
$s$;

-- Generic probe: run p_sql as p_role with claims for p_sub ('none' = no sub),
-- record sqlstate or row count, then undo.
create function pg_temp.probe(p_label text, p_role text, p_sub text, p_sql text, p_expect text) returns void language plpgsql as $f$
declare n bigint := null; st text := null; outcome text; ok boolean;
begin
  begin
    execute format('set local role %I', p_role);
    perform set_config('request.jwt.claims', case when p_sub = 'none' then json_build_object('role', p_role) else json_build_object('sub', p_sub, 'role', p_role) end::text, true);
    perform set_config('request.jwt.claim.sub', case when p_sub = 'none' then '' else p_sub end, true);
    execute p_sql;
    get diagnostics n = row_count;
    raise exception using errcode = 'P0001', message = 'undo';
  exception
    when sqlstate 'P0001' then null;
    when others then st := sqlstate; n := null;
  end;
  outcome := coalesce(st, 'ok:' || n);
  ok := case when p_expect = 'ok' then st is null
             when p_expect = 'ok+' then st is null and n > 0
             else st = p_expect end;
  insert into pg_temp._res (label, expect, outcome, pass) values (p_label, p_expect, outcome, ok);
end $f$;

-- Gate probe: optional setup (as postgres) to seed the call log, then call
-- the gate as p_role/p_sub. Outcome is "allowed recorded=N", the refusal
-- reason (with a retry_after range check), or the sqlstate. Then undo.
create function pg_temp.gate(p_label text, p_setup text, p_role text, p_sub text, p_chars integer, p_expect text,
                             p_retry_min integer default null, p_retry_max integer default null) returns void language plpgsql as $f$
declare r jsonb; st text := null; outcome text; before_n bigint; after_n bigint; ra integer;
begin
  begin
    if p_setup is not null then execute p_setup; end if;
    select count(*) into before_n from private.arch_brainstorm_calls;
    execute format('set local role %I', p_role);
    perform set_config('request.jwt.claims', case when p_sub = 'none' then json_build_object('role', p_role) else json_build_object('sub', p_sub, 'role', p_role) end::text, true);
    perform set_config('request.jwt.claim.sub', case when p_sub = 'none' then '' else p_sub end, true);
    r := public.arch_brainstorm_gate(p_chars);
    reset role;
    select count(*) into after_n from private.arch_brainstorm_calls;
    ra := (r ->> 'retry_after')::integer;
    outcome := case when (r ->> 'allowed')::boolean
                    then 'allowed recorded=' || (after_n - before_n)
                    else (r ->> 'reason') || ' recorded=' || (after_n - before_n)
                         || case when ra is not null then ' retry_after=' ||
                              case when ra between coalesce(p_retry_min, 1) and coalesce(p_retry_max, 86400) then 'in-range' else ra::text end
                            else '' end end;
    raise exception using errcode = 'P0001', message = 'undo';
  exception
    when sqlstate 'P0001' then null;
    when others then st := sqlstate;
  end;
  outcome := coalesce(st, outcome);
  insert into pg_temp._res (label, expect, outcome, pass) values (p_label, p_expect, outcome, outcome = p_expect);
end $f$;

create temp table _before as select * from pg_temp.state();

-- ===== apply 005 =====
\ir 005_arch_owner_and_gate.sql
create temp table _after1 as select * from pg_temp.state();
\ir 005_arch_owner_and_gate.sql
insert into _res (label, expect, outcome, pass)
select 're-applying 005 changes nothing', '0 differences',
  (select count(*) from ((select * from _after1 except select * from pg_temp.state())
                         union all (select * from pg_temp.state() except select * from _after1)) d) || ' differences', null;

insert into _res (label, expect, outcome, pass)
select '005 leaves every arch_* policy and grant unchanged', '0 differences',
  (select count(*) from ((select * from _before where state like 'policy %' or state like 'rel public.%'
                          except select * from _after1 where state like 'policy %' or state like 'rel public.%')
                         union all
                         (select * from _after1 where state like 'policy %' or state like 'rel public.%'
                          except select * from _before where state like 'policy %' or state like 'rel public.%')) d) || ' differences', null;

insert into _res (label, expect, outcome, pass)
select '005 leaves Food-planning''s private objects unchanged', '0 differences',
  (select count(*) from ((select * from _before where state like '%food%' except select * from _after1 where state like '%food%')
                         union all (select * from _after1 where state like '%food%' except select * from _before where state like '%food%')) d) || ' differences', null;

-- ===== gate: who may call it =====
select pg_temp.gate('anon, no JWT subject', null, 'anon', 'none', 1000, '42501');
select pg_temp.gate('anon claiming the owner''s sub', null, 'anon', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', 1000, '42501');
select pg_temp.gate('service_role', null, 'service_role', 'none', 1000, '42501');
select pg_temp.gate('authenticated without a sub', null, 'authenticated', 'none', 1000, 'not_owner recorded=0');
select pg_temp.gate('signed-in non-owner (test account)', null, 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', 1000, 'not_owner recorded=0');
select pg_temp.gate('signed-in unknown user', null, 'authenticated', gen_random_uuid()::text, 1000, 'not_owner recorded=0');
select pg_temp.gate('owner', null, 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', 1000, 'allowed recorded=1');

-- ===== gate: input bound =====
select pg_temp.gate('owner, 64,000 chars (the cap)', null, 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', 64000, 'allowed recorded=1');
select pg_temp.gate('owner, 64,001 chars', null, 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', 64001, 'bad_input recorded=0');
select pg_temp.gate('owner, negative chars', null, 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', -1, 'bad_input recorded=0');
select pg_temp.gate('owner, null chars', null, 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', null, 'bad_input recorded=0');

-- ===== gate: rate limits =====
select pg_temp.gate('owner, 19 calls in last 10 min -> 20th allowed',
  $$insert into private.arch_brainstorm_calls (user_id, called_at, input_chars)
    select '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', now() - (g || ' seconds')::interval, 100 from generate_series(1, 19) g$$,
  'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', 1000, 'allowed recorded=1');
select pg_temp.gate('owner, 20 calls in last 10 min -> refused',
  $$insert into private.arch_brainstorm_calls (user_id, called_at, input_chars)
    select '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', now() - (g * 20 || ' seconds')::interval, 100 from generate_series(1, 20) g$$,
  'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', 1000, 'rate_limited recorded=0 retry_after=in-range', 1, 600);
select pg_temp.gate('owner, 20 calls 11 min ago -> allowed again',
  $$insert into private.arch_brainstorm_calls (user_id, called_at, input_chars)
    select '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', now() - interval '11 minutes', 100 from generate_series(1, 20) g$$,
  'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', 1000, 'allowed recorded=1');
select pg_temp.gate('owner, 99 calls today -> 100th allowed',
  $$insert into private.arch_brainstorm_calls (user_id, called_at, input_chars)
    select '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', now() - interval '1 hour', 100 from generate_series(1, 99) g$$,
  'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', 1000, 'allowed recorded=1');
select pg_temp.gate('owner, 100 calls today -> refused (~23h wait)',
  $$insert into private.arch_brainstorm_calls (user_id, called_at, input_chars)
    select '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', now() - interval '1 hour', 100 from generate_series(1, 100) g$$,
  'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', 1000, 'rate_limited recorded=0 retry_after=in-range', 82000, 82900);
select pg_temp.gate('owner, 999,500 chars today + 1,000 -> refused',
  $$insert into private.arch_brainstorm_calls (user_id, called_at, input_chars)
    select '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', now() - interval '2 hours', 19990 from generate_series(1, 50) g$$,
  'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', 1000, 'rate_limited recorded=0 retry_after=in-range', 78000, 79300);
select pg_temp.gate('owner, 999,500 chars today + 500 -> allowed',
  $$insert into private.arch_brainstorm_calls (user_id, called_at, input_chars)
    select '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', now() - interval '2 hours', 19990 from generate_series(1, 50) g$$,
  'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', 500, 'allowed recorded=1');
select pg_temp.gate('owner, 150 calls 3 days ago -> ignored and pruned',
  $$insert into private.arch_brainstorm_calls (user_id, called_at, input_chars)
    select '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', now() - interval '3 days', 100 from generate_series(1, 150) g$$,
  'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', 1000, 'allowed recorded=-149');
select pg_temp.gate('another user''s calls don''t count against the owner',
  $$insert into private.arch_brainstorm_calls (user_id, called_at, input_chars)
    select '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', now() - interval '1 minute', 100 from generate_series(1, 120) g$$,
  'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', 1000, 'allowed recorded=1');
select pg_temp.gate('non-owner is refused before the rate limit and never logged',
  $$insert into private.arch_brainstorm_calls (user_id, called_at, input_chars)
    select '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', now() - interval '1 minute', 100 from generate_series(1, 20) g$$,
  'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', 1000, 'not_owner recorded=0');

-- ===== direct access to the private objects =====
select pg_temp.probe('owner reads private.arch_owners', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', 'select * from private.arch_owners', '42501');
select pg_temp.probe('owner adds to private.arch_owners', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $$insert into private.arch_owners (user_id) values ('24c39f7f-4ed0-41fb-a751-6df86b2d37cd')$$, '42501');
select pg_temp.probe('non-owner adds self to private.arch_owners', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $$insert into private.arch_owners (user_id) values ('24c39f7f-4ed0-41fb-a751-6df86b2d37cd')$$, '42501');
select pg_temp.probe('owner reads the call log', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', 'select * from private.arch_brainstorm_calls', '42501');
select pg_temp.probe('owner clears the call log', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', 'delete from private.arch_brainstorm_calls', '42501');
select pg_temp.probe('anon reads private.arch_owners', 'anon', 'none', 'select * from private.arch_owners', '42501');
select pg_temp.probe('anon calls is_arch_owner()', 'anon', 'none', 'select private.is_arch_owner()', '42501');
select pg_temp.probe('service_role calls is_arch_owner()', 'service_role', 'none', 'select private.is_arch_owner()', '42501');
select pg_temp.probe('owner: is_arch_owner() is true', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', 'select 1 where private.is_arch_owner()', 'ok+');
select pg_temp.probe('non-owner: is_arch_owner() is false', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', 'select 1 where not private.is_arch_owner()', 'ok+');
select pg_temp.probe('no sub: is_arch_owner() is false', 'authenticated', 'none', 'select 1 where not private.is_arch_owner()', 'ok+');

-- ===== contract =====
insert into _res (label, expect, outcome, pass)
select 'allowlist is exactly the human owner', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53',
       (select string_agg(user_id::text, ',' order by user_id) from private.arch_owners), null;
insert into _res (label, expect, outcome, pass)
select 'gate: definer, owner postgres, empty search_path, EXECUTE for authenticated only',
       'definer=true owner=postgres cfg=search_path="" acl=authenticated=X/postgres postgres=X/postgres',
       (select substring(state from ' (definer=.*) src=') from pg_temp.state() where state like 'fn arch_brainstorm_gate(integer)%'), null;
insert into _res (label, expect, outcome, pass)
select 'is_arch_owner: definer, owner postgres, empty search_path, EXECUTE for authenticated only',
       'definer=true owner=postgres cfg=search_path="" acl=authenticated=X/postgres postgres=X/postgres',
       (select substring(state from ' (definer=.*) src=') from pg_temp.state() where state like 'fn private.is_arch_owner()%'), null;
insert into _res (label, expect, outcome, pass)
select 'private tables: RLS on, no client privileges',
       'rel private.arch_brainstorm_calls kind=r rls=true owner=postgres acl=postgres=arwdDxt' || case when current_setting('server_version_num')::int >= 170000 then 'm' else '' end || '/postgres; rel private.arch_owners kind=r rls=true owner=postgres acl=postgres=arwdDxt' || case when current_setting('server_version_num')::int >= 170000 then 'm' else '' end || '/postgres',
       (select string_agg(state, '; ' order by state) from pg_temp.state() where state in (select state from pg_temp.state() where state like 'rel private.arch\_brainstorm\_calls %' or state like 'rel private.arch\_owners %')), null;
insert into _res (label, expect, outcome, pass)
select 'call-log sequence: no client privileges', 'postgres only',
       case when (select coalesce(array_to_string(relacl, ' '), '') from pg_class where oid = 'private.arch_brainstorm_calls_id_seq'::regclass) ~ '(anon|authenticated|service_role)='
            then 'client privilege present' else 'postgres only' end, null;
insert into _res (label, expect, outcome, pass)
select 'private schema: no USAGE for anon or PUBLIC', 'authenticated=U/postgres postgres=UC/postgres',
       (select substring(state from 'acl=(.*)') from pg_temp.state() where state like 'schema private%'), null;

-- ===== rollback =====
-- Compared against the snapshot only when 005 wasn't live before the test
-- (pre-005 mode). If it was, the rollback can't return to "before" by design;
-- if 006 is live too, the rollback must refuse (its policies use
-- is_arch_owner()), which is checked instead.
select exists (select 1 from _before where state like 'fn private.is_arch_owner()%') as pre_live,
       exists (select 1 from pg_policy where pg_get_expr(polqual, polrelid) like '%is_arch_owner%') as rls_live \gset
\if :rls_live
do $$
begin
  begin
    drop function private.is_arch_owner();
    insert into pg_temp._res (label, expect, outcome, pass) values ('rollback refuses while 006 policies use is_arch_owner()', '2BP01', 'dropped', false);
  exception when sqlstate '2BP01' then
    insert into pg_temp._res (label, expect, outcome, pass) values ('rollback refuses while 006 policies use is_arch_owner()', '2BP01', '2BP01', true);
  end;
end $$;
\else
\ir 005_arch_owner_and_gate-rollback.sql
insert into _res (label, expect, outcome, pass)
select 'rollback restores the exact pre-005 state', '0 differences',
  case when :'pre_live' then '0 differences'  -- n/a: 005 was already live
       else (select count(*) from ((select * from _before except select * from pg_temp.state())
                                   union all (select * from pg_temp.state() except select * from _before)) d) || ' differences' end, null;
\endif
insert into _res (label, expect, outcome, pass)
select 'mode', 'any', case when :'rls_live' then 'post-006 regression (005 and 006 live)'
                           when :'pre_live' then 'post-005 regression (rollback comparison not applicable)'
                           else 'pre-005 (rollback compared against snapshot)' end, true;

update _res set pass = (outcome = expect) where pass is null;
select (select count(*) filter (where pass) from _res) || ' passed, ' || (select count(*) filter (where not pass or pass is null) from _res) || ' failed' as summary,
       ord, label, expect, outcome, pass
from _res order by pass nulls first, ord;

rollback;
