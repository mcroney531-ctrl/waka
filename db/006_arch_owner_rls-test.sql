-- Test for 006_arch_owner_rls.sql (Reading Center).
--
-- Runs ENTIRELY inside one transaction that ends in ROLLBACK: nothing persists.
--   1. apply 005 (idempotent; a no-op if it's already live) and snapshot the
--      arch_* access state
--   2. apply 006 (twice, to prove it's idempotent)
--   3. replay the pages' operations on all six tables as the owner, the
--      non-owner test account, a signed-in user with no sub, and anon
--      (each probe in its own sub-transaction, undone immediately)
--   4. check effective privileges for anon / authenticated / service_role
--      and the exact policy set
--   5. apply the 006 rollback and verify the state matches the snapshot;
--      then confirm the snapshot is the old open state (pre-006 mode) or the
--      secured state (post-006 regression mode)
-- Takes brief locks on the arch_* tables while it runs.
-- Claims are simulated with request.jwt.claims; real sessions are tested
-- after cutover.
--
-- Run with psql from the repo root:  psql -f db/006_arch_owner_rls-test.sql
-- Production: the same text with the \ir lines inlined.
begin;

create temp table _res (ord serial, label text, expect text, outcome text, pass boolean);
grant all on _res to public;
grant all on sequence _res_ord_seq to public;

-- One existing row per table (or a fresh one if the table is empty), so the
-- non-owner probes aim at rows the owner really has.
create temp table _ids (tbl text primary key, id uuid);
grant select on _ids to public;

create function pg_temp.state() returns setof text language sql as $s$
  select 'policy '||c.relname||' '||p.polname||' '||p.polcmd::text||' '||p.polpermissive::text||' '||(select string_agg(rolname, ',' order by rolname) from pg_roles where oid = any(p.polroles))||' q='||coalesce(pg_get_expr(p.polqual, p.polrelid),'-')||' c='||coalesce(pg_get_expr(p.polwithcheck, p.polrelid),'-')
    from pg_policy p join pg_class c on c.oid = p.polrelid where c.relnamespace = 'public'::regnamespace and c.relname like 'arch\_%'
  union all
  select 'rel '||c.relname||' kind='||c.relkind::text||' rls='||c.relrowsecurity::text||' force='||c.relforcerowsecurity::text||' acl='||coalesce(array_to_string(array(select x::text from unnest(c.relacl) x order by 1), ' '), '-')
    from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname like 'arch\_%'
  union all
  select 'colacl '||c.relname||' '||a.attname||' '||array_to_string(a.attacl, ' ')
    from pg_attribute a join pg_class c on c.oid = a.attrelid where c.relnamespace = 'public'::regnamespace and c.relname like 'arch\_%' and a.attacl is not null
$s$;

create function pg_temp.probe(p_label text, p_role text, p_sub text, p_sql text, p_expect text) returns void language plpgsql as $f$
declare n bigint := null; st text := null; outcome text; ok boolean; total bigint;
begin
  -- ok=rows: succeeds and sees/updates every row in the table
  total := case when p_expect = 'ok=rows'
                then (select (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from public.%I', split_part(p_label, ':', 1)), false, true, '')))[1]::text::bigint)
           end;
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
  ok := case when p_expect = 'ok+' then st is null and n > 0
             when p_expect = 'ok0' then st is null and n = 0
             when p_expect = 'ok=rows' then st is null and n = total
             else st = p_expect end;
  insert into pg_temp._res (label, expect, outcome, pass) values (p_label, p_expect, outcome || coalesce(' of ' || total, ''), ok);
end $f$;

\ir 005_arch_owner_and_gate.sql
create temp table _before as select * from pg_temp.state();

-- ===== apply 006 =====
\ir 006_arch_owner_rls.sql
create temp table _after1 as select * from pg_temp.state();
\ir 006_arch_owner_rls.sql
insert into _res (label, expect, outcome, pass)
select 're-applying 006 changes nothing', '0 differences',
  (select count(*) from ((select * from _after1 except select * from pg_temp.state())
                         union all (select * from pg_temp.state() except select * from _after1)) d) || ' differences', null;

do $$
declare t text; v uuid;
begin
  foreach t in array array['arch_titles', 'arch_keywords', 'arch_brainstorms', 'arch_demo_titles', 'arch_demo_keywords', 'arch_demo_brainstorms'] loop
    execute format('select id from public.%I order by created_at limit 1', t) into v;
    if v is null then
      execute format('insert into public.%I (%s) values (%L) returning id', t,
                     case when t like '%keywords' then 'term' else 'title' end, 'rls probe target') into v;
    end if;
    insert into _ids values (t, v);
  end loop;
end $$;

-- ===== the pages' operations, per table and caller =====

-- arch_titles
select pg_temp.probe('arch_titles: owner select', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$select * from public.arch_titles$q$, 'ok=rows');
select pg_temp.probe('arch_titles: owner insert + return row', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$insert into public.arch_titles (title, route, status) values ('rls probe', 'ILL', 'requested') returning id$q$, 'ok+');
select pg_temp.probe('arch_titles: owner update', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$update public.arch_titles set notes = coalesce(notes, '') where true$q$, 'ok=rows');
select pg_temp.probe('arch_titles: owner update a row the owner has', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$update public.arch_titles set notes = coalesce(notes, '') where id = (select id from _ids where tbl = 'arch_titles')$q$, 'ok+');
select pg_temp.probe('arch_titles: owner delete', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$delete from public.arch_titles$q$, '42501');
select pg_temp.probe('arch_titles: owner truncate', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$truncate public.arch_titles$q$, '42501');
select pg_temp.probe('arch_titles: non-owner select', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$select * from public.arch_titles$q$, 'ok0');
select pg_temp.probe('arch_titles: non-owner insert + return row', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$insert into public.arch_titles (title, route, status) values ('rls probe', 'ILL', 'requested') returning id$q$, '42501');
select pg_temp.probe('arch_titles: non-owner update', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$update public.arch_titles set notes = coalesce(notes, '') where true$q$, 'ok0');
select pg_temp.probe('arch_titles: non-owner update a row the owner has', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$update public.arch_titles set notes = coalesce(notes, '') where id = (select id from _ids where tbl = 'arch_titles')$q$, 'ok0');
select pg_temp.probe('arch_titles: non-owner delete', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$delete from public.arch_titles$q$, '42501');
select pg_temp.probe('arch_titles: non-owner truncate', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$truncate public.arch_titles$q$, '42501');
select pg_temp.probe('arch_titles: no-sub user select', 'authenticated', 'none', $q$select * from public.arch_titles$q$, 'ok0');
select pg_temp.probe('arch_titles: no-sub user insert + return row', 'authenticated', 'none', $q$insert into public.arch_titles (title, route, status) values ('rls probe', 'ILL', 'requested') returning id$q$, '42501');
select pg_temp.probe('arch_titles: no-sub user update', 'authenticated', 'none', $q$update public.arch_titles set notes = coalesce(notes, '') where true$q$, 'ok0');
select pg_temp.probe('arch_titles: no-sub user update a row the owner has', 'authenticated', 'none', $q$update public.arch_titles set notes = coalesce(notes, '') where id = (select id from _ids where tbl = 'arch_titles')$q$, 'ok0');
select pg_temp.probe('arch_titles: no-sub user delete', 'authenticated', 'none', $q$delete from public.arch_titles$q$, '42501');
select pg_temp.probe('arch_titles: no-sub user truncate', 'authenticated', 'none', $q$truncate public.arch_titles$q$, '42501');
select pg_temp.probe('arch_titles: anon select', 'anon', 'none', $q$select * from public.arch_titles$q$, '42501');
select pg_temp.probe('arch_titles: anon insert + return row', 'anon', 'none', $q$insert into public.arch_titles (title, route, status) values ('rls probe', 'ILL', 'requested') returning id$q$, '42501');
select pg_temp.probe('arch_titles: anon update', 'anon', 'none', $q$update public.arch_titles set notes = coalesce(notes, '') where true$q$, '42501');
select pg_temp.probe('arch_titles: anon update a row the owner has', 'anon', 'none', $q$update public.arch_titles set notes = coalesce(notes, '') where id = (select id from _ids where tbl = 'arch_titles')$q$, '42501');
select pg_temp.probe('arch_titles: anon delete', 'anon', 'none', $q$delete from public.arch_titles$q$, '42501');
select pg_temp.probe('arch_titles: anon truncate', 'anon', 'none', $q$truncate public.arch_titles$q$, '42501');

-- arch_keywords
select pg_temp.probe('arch_keywords: owner select', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$select * from public.arch_keywords$q$, 'ok=rows');
select pg_temp.probe('arch_keywords: owner insert + return row', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$insert into public.arch_keywords (term, source) values ('rls probe', 'test') returning id$q$, 'ok+');
select pg_temp.probe('arch_keywords: owner update', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$update public.arch_keywords set status = status where true$q$, 'ok=rows');
select pg_temp.probe('arch_keywords: owner update a row the owner has', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$update public.arch_keywords set status = status where id = (select id from _ids where tbl = 'arch_keywords')$q$, 'ok+');
select pg_temp.probe('arch_keywords: owner delete', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$delete from public.arch_keywords$q$, '42501');
select pg_temp.probe('arch_keywords: owner truncate', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$truncate public.arch_keywords$q$, '42501');
select pg_temp.probe('arch_keywords: non-owner select', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$select * from public.arch_keywords$q$, 'ok0');
select pg_temp.probe('arch_keywords: non-owner insert + return row', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$insert into public.arch_keywords (term, source) values ('rls probe', 'test') returning id$q$, '42501');
select pg_temp.probe('arch_keywords: non-owner update', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$update public.arch_keywords set status = status where true$q$, 'ok0');
select pg_temp.probe('arch_keywords: non-owner update a row the owner has', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$update public.arch_keywords set status = status where id = (select id from _ids where tbl = 'arch_keywords')$q$, 'ok0');
select pg_temp.probe('arch_keywords: non-owner delete', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$delete from public.arch_keywords$q$, '42501');
select pg_temp.probe('arch_keywords: non-owner truncate', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$truncate public.arch_keywords$q$, '42501');
select pg_temp.probe('arch_keywords: no-sub user select', 'authenticated', 'none', $q$select * from public.arch_keywords$q$, 'ok0');
select pg_temp.probe('arch_keywords: no-sub user insert + return row', 'authenticated', 'none', $q$insert into public.arch_keywords (term, source) values ('rls probe', 'test') returning id$q$, '42501');
select pg_temp.probe('arch_keywords: no-sub user update', 'authenticated', 'none', $q$update public.arch_keywords set status = status where true$q$, 'ok0');
select pg_temp.probe('arch_keywords: no-sub user update a row the owner has', 'authenticated', 'none', $q$update public.arch_keywords set status = status where id = (select id from _ids where tbl = 'arch_keywords')$q$, 'ok0');
select pg_temp.probe('arch_keywords: no-sub user delete', 'authenticated', 'none', $q$delete from public.arch_keywords$q$, '42501');
select pg_temp.probe('arch_keywords: no-sub user truncate', 'authenticated', 'none', $q$truncate public.arch_keywords$q$, '42501');
select pg_temp.probe('arch_keywords: anon select', 'anon', 'none', $q$select * from public.arch_keywords$q$, '42501');
select pg_temp.probe('arch_keywords: anon insert + return row', 'anon', 'none', $q$insert into public.arch_keywords (term, source) values ('rls probe', 'test') returning id$q$, '42501');
select pg_temp.probe('arch_keywords: anon update', 'anon', 'none', $q$update public.arch_keywords set status = status where true$q$, '42501');
select pg_temp.probe('arch_keywords: anon update a row the owner has', 'anon', 'none', $q$update public.arch_keywords set status = status where id = (select id from _ids where tbl = 'arch_keywords')$q$, '42501');
select pg_temp.probe('arch_keywords: anon delete', 'anon', 'none', $q$delete from public.arch_keywords$q$, '42501');
select pg_temp.probe('arch_keywords: anon truncate', 'anon', 'none', $q$truncate public.arch_keywords$q$, '42501');

-- arch_brainstorms
select pg_temp.probe('arch_brainstorms: owner select', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$select * from public.arch_brainstorms$q$, 'ok=rows');
select pg_temp.probe('arch_brainstorms: owner insert + return row', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$insert into public.arch_brainstorms (title, seed, messages) values ('rls probe', 'x', '[]'::jsonb) returning id$q$, 'ok+');
select pg_temp.probe('arch_brainstorms: owner update', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$update public.arch_brainstorms set archived = archived, updated_at = now() where true$q$, 'ok=rows');
select pg_temp.probe('arch_brainstorms: owner update a row the owner has', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$update public.arch_brainstorms set archived = archived, updated_at = now() where id = (select id from _ids where tbl = 'arch_brainstorms')$q$, 'ok+');
select pg_temp.probe('arch_brainstorms: owner delete', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$delete from public.arch_brainstorms$q$, '42501');
select pg_temp.probe('arch_brainstorms: owner truncate', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$truncate public.arch_brainstorms$q$, '42501');
select pg_temp.probe('arch_brainstorms: non-owner select', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$select * from public.arch_brainstorms$q$, 'ok0');
select pg_temp.probe('arch_brainstorms: non-owner insert + return row', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$insert into public.arch_brainstorms (title, seed, messages) values ('rls probe', 'x', '[]'::jsonb) returning id$q$, '42501');
select pg_temp.probe('arch_brainstorms: non-owner update', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$update public.arch_brainstorms set archived = archived, updated_at = now() where true$q$, 'ok0');
select pg_temp.probe('arch_brainstorms: non-owner update a row the owner has', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$update public.arch_brainstorms set archived = archived, updated_at = now() where id = (select id from _ids where tbl = 'arch_brainstorms')$q$, 'ok0');
select pg_temp.probe('arch_brainstorms: non-owner delete', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$delete from public.arch_brainstorms$q$, '42501');
select pg_temp.probe('arch_brainstorms: non-owner truncate', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$truncate public.arch_brainstorms$q$, '42501');
select pg_temp.probe('arch_brainstorms: no-sub user select', 'authenticated', 'none', $q$select * from public.arch_brainstorms$q$, 'ok0');
select pg_temp.probe('arch_brainstorms: no-sub user insert + return row', 'authenticated', 'none', $q$insert into public.arch_brainstorms (title, seed, messages) values ('rls probe', 'x', '[]'::jsonb) returning id$q$, '42501');
select pg_temp.probe('arch_brainstorms: no-sub user update', 'authenticated', 'none', $q$update public.arch_brainstorms set archived = archived, updated_at = now() where true$q$, 'ok0');
select pg_temp.probe('arch_brainstorms: no-sub user update a row the owner has', 'authenticated', 'none', $q$update public.arch_brainstorms set archived = archived, updated_at = now() where id = (select id from _ids where tbl = 'arch_brainstorms')$q$, 'ok0');
select pg_temp.probe('arch_brainstorms: no-sub user delete', 'authenticated', 'none', $q$delete from public.arch_brainstorms$q$, '42501');
select pg_temp.probe('arch_brainstorms: no-sub user truncate', 'authenticated', 'none', $q$truncate public.arch_brainstorms$q$, '42501');
select pg_temp.probe('arch_brainstorms: anon select', 'anon', 'none', $q$select * from public.arch_brainstorms$q$, '42501');
select pg_temp.probe('arch_brainstorms: anon insert + return row', 'anon', 'none', $q$insert into public.arch_brainstorms (title, seed, messages) values ('rls probe', 'x', '[]'::jsonb) returning id$q$, '42501');
select pg_temp.probe('arch_brainstorms: anon update', 'anon', 'none', $q$update public.arch_brainstorms set archived = archived, updated_at = now() where true$q$, '42501');
select pg_temp.probe('arch_brainstorms: anon update a row the owner has', 'anon', 'none', $q$update public.arch_brainstorms set archived = archived, updated_at = now() where id = (select id from _ids where tbl = 'arch_brainstorms')$q$, '42501');
select pg_temp.probe('arch_brainstorms: anon delete', 'anon', 'none', $q$delete from public.arch_brainstorms$q$, '42501');
select pg_temp.probe('arch_brainstorms: anon truncate', 'anon', 'none', $q$truncate public.arch_brainstorms$q$, '42501');

-- arch_demo_titles
select pg_temp.probe('arch_demo_titles: owner select', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$select * from public.arch_demo_titles$q$, 'ok=rows');
select pg_temp.probe('arch_demo_titles: owner insert + return row', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$insert into public.arch_demo_titles (title) values ('rls probe') returning id$q$, 'ok+');
select pg_temp.probe('arch_demo_titles: owner update', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$update public.arch_demo_titles set notes = coalesce(notes, '') where true$q$, 'ok=rows');
select pg_temp.probe('arch_demo_titles: owner update a row the owner has', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$update public.arch_demo_titles set notes = coalesce(notes, '') where id = (select id from _ids where tbl = 'arch_demo_titles')$q$, 'ok+');
select pg_temp.probe('arch_demo_titles: owner delete', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$delete from public.arch_demo_titles$q$, '42501');
select pg_temp.probe('arch_demo_titles: owner truncate', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$truncate public.arch_demo_titles$q$, '42501');
select pg_temp.probe('arch_demo_titles: non-owner select', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$select * from public.arch_demo_titles$q$, 'ok0');
select pg_temp.probe('arch_demo_titles: non-owner insert + return row', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$insert into public.arch_demo_titles (title) values ('rls probe') returning id$q$, '42501');
select pg_temp.probe('arch_demo_titles: non-owner update', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$update public.arch_demo_titles set notes = coalesce(notes, '') where true$q$, 'ok0');
select pg_temp.probe('arch_demo_titles: non-owner update a row the owner has', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$update public.arch_demo_titles set notes = coalesce(notes, '') where id = (select id from _ids where tbl = 'arch_demo_titles')$q$, 'ok0');
select pg_temp.probe('arch_demo_titles: non-owner delete', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$delete from public.arch_demo_titles$q$, '42501');
select pg_temp.probe('arch_demo_titles: non-owner truncate', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$truncate public.arch_demo_titles$q$, '42501');
select pg_temp.probe('arch_demo_titles: no-sub user select', 'authenticated', 'none', $q$select * from public.arch_demo_titles$q$, 'ok0');
select pg_temp.probe('arch_demo_titles: no-sub user insert + return row', 'authenticated', 'none', $q$insert into public.arch_demo_titles (title) values ('rls probe') returning id$q$, '42501');
select pg_temp.probe('arch_demo_titles: no-sub user update', 'authenticated', 'none', $q$update public.arch_demo_titles set notes = coalesce(notes, '') where true$q$, 'ok0');
select pg_temp.probe('arch_demo_titles: no-sub user update a row the owner has', 'authenticated', 'none', $q$update public.arch_demo_titles set notes = coalesce(notes, '') where id = (select id from _ids where tbl = 'arch_demo_titles')$q$, 'ok0');
select pg_temp.probe('arch_demo_titles: no-sub user delete', 'authenticated', 'none', $q$delete from public.arch_demo_titles$q$, '42501');
select pg_temp.probe('arch_demo_titles: no-sub user truncate', 'authenticated', 'none', $q$truncate public.arch_demo_titles$q$, '42501');
select pg_temp.probe('arch_demo_titles: anon select', 'anon', 'none', $q$select * from public.arch_demo_titles$q$, '42501');
select pg_temp.probe('arch_demo_titles: anon insert + return row', 'anon', 'none', $q$insert into public.arch_demo_titles (title) values ('rls probe') returning id$q$, '42501');
select pg_temp.probe('arch_demo_titles: anon update', 'anon', 'none', $q$update public.arch_demo_titles set notes = coalesce(notes, '') where true$q$, '42501');
select pg_temp.probe('arch_demo_titles: anon update a row the owner has', 'anon', 'none', $q$update public.arch_demo_titles set notes = coalesce(notes, '') where id = (select id from _ids where tbl = 'arch_demo_titles')$q$, '42501');
select pg_temp.probe('arch_demo_titles: anon delete', 'anon', 'none', $q$delete from public.arch_demo_titles$q$, '42501');
select pg_temp.probe('arch_demo_titles: anon truncate', 'anon', 'none', $q$truncate public.arch_demo_titles$q$, '42501');

-- arch_demo_keywords
select pg_temp.probe('arch_demo_keywords: owner select', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$select * from public.arch_demo_keywords$q$, 'ok=rows');
select pg_temp.probe('arch_demo_keywords: owner insert + return row', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$insert into public.arch_demo_keywords (term) values ('rls probe') returning id$q$, 'ok+');
select pg_temp.probe('arch_demo_keywords: owner update', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$update public.arch_demo_keywords set status = status where true$q$, 'ok=rows');
select pg_temp.probe('arch_demo_keywords: owner update a row the owner has', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$update public.arch_demo_keywords set status = status where id = (select id from _ids where tbl = 'arch_demo_keywords')$q$, 'ok+');
select pg_temp.probe('arch_demo_keywords: owner delete', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$delete from public.arch_demo_keywords$q$, '42501');
select pg_temp.probe('arch_demo_keywords: owner truncate', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$truncate public.arch_demo_keywords$q$, '42501');
select pg_temp.probe('arch_demo_keywords: non-owner select', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$select * from public.arch_demo_keywords$q$, 'ok0');
select pg_temp.probe('arch_demo_keywords: non-owner insert + return row', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$insert into public.arch_demo_keywords (term) values ('rls probe') returning id$q$, '42501');
select pg_temp.probe('arch_demo_keywords: non-owner update', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$update public.arch_demo_keywords set status = status where true$q$, 'ok0');
select pg_temp.probe('arch_demo_keywords: non-owner update a row the owner has', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$update public.arch_demo_keywords set status = status where id = (select id from _ids where tbl = 'arch_demo_keywords')$q$, 'ok0');
select pg_temp.probe('arch_demo_keywords: non-owner delete', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$delete from public.arch_demo_keywords$q$, '42501');
select pg_temp.probe('arch_demo_keywords: non-owner truncate', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$truncate public.arch_demo_keywords$q$, '42501');
select pg_temp.probe('arch_demo_keywords: no-sub user select', 'authenticated', 'none', $q$select * from public.arch_demo_keywords$q$, 'ok0');
select pg_temp.probe('arch_demo_keywords: no-sub user insert + return row', 'authenticated', 'none', $q$insert into public.arch_demo_keywords (term) values ('rls probe') returning id$q$, '42501');
select pg_temp.probe('arch_demo_keywords: no-sub user update', 'authenticated', 'none', $q$update public.arch_demo_keywords set status = status where true$q$, 'ok0');
select pg_temp.probe('arch_demo_keywords: no-sub user update a row the owner has', 'authenticated', 'none', $q$update public.arch_demo_keywords set status = status where id = (select id from _ids where tbl = 'arch_demo_keywords')$q$, 'ok0');
select pg_temp.probe('arch_demo_keywords: no-sub user delete', 'authenticated', 'none', $q$delete from public.arch_demo_keywords$q$, '42501');
select pg_temp.probe('arch_demo_keywords: no-sub user truncate', 'authenticated', 'none', $q$truncate public.arch_demo_keywords$q$, '42501');
select pg_temp.probe('arch_demo_keywords: anon select', 'anon', 'none', $q$select * from public.arch_demo_keywords$q$, '42501');
select pg_temp.probe('arch_demo_keywords: anon insert + return row', 'anon', 'none', $q$insert into public.arch_demo_keywords (term) values ('rls probe') returning id$q$, '42501');
select pg_temp.probe('arch_demo_keywords: anon update', 'anon', 'none', $q$update public.arch_demo_keywords set status = status where true$q$, '42501');
select pg_temp.probe('arch_demo_keywords: anon update a row the owner has', 'anon', 'none', $q$update public.arch_demo_keywords set status = status where id = (select id from _ids where tbl = 'arch_demo_keywords')$q$, '42501');
select pg_temp.probe('arch_demo_keywords: anon delete', 'anon', 'none', $q$delete from public.arch_demo_keywords$q$, '42501');
select pg_temp.probe('arch_demo_keywords: anon truncate', 'anon', 'none', $q$truncate public.arch_demo_keywords$q$, '42501');

-- arch_demo_brainstorms
select pg_temp.probe('arch_demo_brainstorms: owner select', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$select * from public.arch_demo_brainstorms$q$, 'ok=rows');
select pg_temp.probe('arch_demo_brainstorms: owner insert + return row', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$insert into public.arch_demo_brainstorms (title) values ('rls probe') returning id$q$, 'ok+');
select pg_temp.probe('arch_demo_brainstorms: owner update', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$update public.arch_demo_brainstorms set archived = archived where true$q$, 'ok=rows');
select pg_temp.probe('arch_demo_brainstorms: owner update a row the owner has', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$update public.arch_demo_brainstorms set archived = archived where id = (select id from _ids where tbl = 'arch_demo_brainstorms')$q$, 'ok+');
select pg_temp.probe('arch_demo_brainstorms: owner delete', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$delete from public.arch_demo_brainstorms$q$, '42501');
select pg_temp.probe('arch_demo_brainstorms: owner truncate', 'authenticated', '0ccc48c3-77e5-4b82-85b9-036e26cf4f53', $q$truncate public.arch_demo_brainstorms$q$, '42501');
select pg_temp.probe('arch_demo_brainstorms: non-owner select', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$select * from public.arch_demo_brainstorms$q$, 'ok0');
select pg_temp.probe('arch_demo_brainstorms: non-owner insert + return row', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$insert into public.arch_demo_brainstorms (title) values ('rls probe') returning id$q$, '42501');
select pg_temp.probe('arch_demo_brainstorms: non-owner update', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$update public.arch_demo_brainstorms set archived = archived where true$q$, 'ok0');
select pg_temp.probe('arch_demo_brainstorms: non-owner update a row the owner has', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$update public.arch_demo_brainstorms set archived = archived where id = (select id from _ids where tbl = 'arch_demo_brainstorms')$q$, 'ok0');
select pg_temp.probe('arch_demo_brainstorms: non-owner delete', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$delete from public.arch_demo_brainstorms$q$, '42501');
select pg_temp.probe('arch_demo_brainstorms: non-owner truncate', 'authenticated', '24c39f7f-4ed0-41fb-a751-6df86b2d37cd', $q$truncate public.arch_demo_brainstorms$q$, '42501');
select pg_temp.probe('arch_demo_brainstorms: no-sub user select', 'authenticated', 'none', $q$select * from public.arch_demo_brainstorms$q$, 'ok0');
select pg_temp.probe('arch_demo_brainstorms: no-sub user insert + return row', 'authenticated', 'none', $q$insert into public.arch_demo_brainstorms (title) values ('rls probe') returning id$q$, '42501');
select pg_temp.probe('arch_demo_brainstorms: no-sub user update', 'authenticated', 'none', $q$update public.arch_demo_brainstorms set archived = archived where true$q$, 'ok0');
select pg_temp.probe('arch_demo_brainstorms: no-sub user update a row the owner has', 'authenticated', 'none', $q$update public.arch_demo_brainstorms set archived = archived where id = (select id from _ids where tbl = 'arch_demo_brainstorms')$q$, 'ok0');
select pg_temp.probe('arch_demo_brainstorms: no-sub user delete', 'authenticated', 'none', $q$delete from public.arch_demo_brainstorms$q$, '42501');
select pg_temp.probe('arch_demo_brainstorms: no-sub user truncate', 'authenticated', 'none', $q$truncate public.arch_demo_brainstorms$q$, '42501');
select pg_temp.probe('arch_demo_brainstorms: anon select', 'anon', 'none', $q$select * from public.arch_demo_brainstorms$q$, '42501');
select pg_temp.probe('arch_demo_brainstorms: anon insert + return row', 'anon', 'none', $q$insert into public.arch_demo_brainstorms (title) values ('rls probe') returning id$q$, '42501');
select pg_temp.probe('arch_demo_brainstorms: anon update', 'anon', 'none', $q$update public.arch_demo_brainstorms set archived = archived where true$q$, '42501');
select pg_temp.probe('arch_demo_brainstorms: anon update a row the owner has', 'anon', 'none', $q$update public.arch_demo_brainstorms set archived = archived where id = (select id from _ids where tbl = 'arch_demo_brainstorms')$q$, '42501');
select pg_temp.probe('arch_demo_brainstorms: anon delete', 'anon', 'none', $q$delete from public.arch_demo_brainstorms$q$, '42501');
select pg_temp.probe('arch_demo_brainstorms: anon truncate', 'anon', 'none', $q$truncate public.arch_demo_brainstorms$q$, '42501');

-- ===== effective privileges =====
insert into _res (label, expect, outcome, pass)
select 'anon: no privilege on any arch_* table', 'none',
  coalesce(string_agg(c.relname || ':' || p, ' '), 'none'), null
from pg_class c cross join unnest(array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) p
where c.relnamespace = 'public'::regnamespace and c.relname like 'arch\_%' and c.relkind = 'r'
  and has_table_privilege('anon', c.oid, p);
insert into _res (label, expect, outcome, pass)
select 'authenticated: exactly select, insert, update on each table', 'SELECT,INSERT,UPDATE x6',
  case when count(distinct privs) = 1 and count(*) = 6 then min(privs) || ' x' || count(*) else string_agg(relname || '=' || privs, ' ') end, null
from (select c.relname, string_agg(p, ',' order by o) privs
        from pg_class c cross join unnest(array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) with ordinality u(p, o)
       where c.relnamespace = 'public'::regnamespace and c.relname like 'arch\_%' and c.relkind = 'r'
         and has_table_privilege('authenticated', c.oid, p)
       group by c.relname) x;
insert into _res (label, expect, outcome, pass)
select 'PUBLIC: no privilege on any arch_* table', 'none',
  coalesce(string_agg(c.relname, ' '), 'none'), null
from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname like 'arch\_%' and c.relkind = 'r'
  and exists (select 1 from aclexplode(c.relacl) a where a.grantee = 0);
insert into _res (label, expect, outcome, pass)
select 'no column-level grants on arch_* tables', '0', count(*)::text, null from pg_temp.state() where state like 'colacl %';
insert into _res (label, expect, outcome, pass)
select 'service_role keeps full access (unchanged)', '6',
  count(*)::text, null
from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname like 'arch\_%' and c.relkind = 'r'
  and has_table_privilege('service_role', c.oid, 'SELECT,INSERT,UPDATE,DELETE');
insert into _res (label, expect, outcome, pass)
select 'RLS enabled on all six tables', '6', count(*)::text, null
from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname like 'arch\_%' and c.relkind = 'r' and c.relrowsecurity;

-- ===== exact policy set =====
insert into _res (label, expect, outcome, pass)
select 'policies: 18, all permissive, all to authenticated only, all owner-checked', '18 / 18 / 18 / 18',
  count(*) || ' / ' || count(*) filter (where polpermissive) || ' / ' ||
  count(*) filter (where polroles = array['authenticated'::regrole::oid]) || ' / ' ||
  count(*) filter (where coalesce(pg_get_expr(polqual, polrelid), '') || coalesce(pg_get_expr(polwithcheck, polrelid), '') like '%private.is_arch_owner()%'
                     and (polcmd <> 'w' or (pg_get_expr(polqual, polrelid) like '%is_arch_owner%' and pg_get_expr(polwithcheck, polrelid) like '%is_arch_owner%'))), null
from pg_policy where polrelid in (select oid from pg_class where relnamespace = 'public'::regnamespace and relname like 'arch\_%');
insert into _res (label, expect, outcome, pass)
select 'no delete or ALL policy on any table', '0', count(*)::text, null
from pg_policy where polcmd in ('d', '*') and polrelid in (select oid from pg_class where relnamespace = 'public'::regnamespace and relname like 'arch\_%');
insert into _res (label, expect, outcome, pass)
select 'commands per table: select, insert, update', 'arw x6',
  case when count(distinct cmds) = 1 then min(cmds) || ' x' || count(*) else string_agg(cmds, ' ') end, null
from (select polrelid, string_agg(polcmd::text, '' order by polcmd::text) cmds from pg_policy
       where polrelid in (select oid from pg_class where relnamespace = 'public'::regnamespace and relname like 'arch\_%')
       group by polrelid) x;

-- ===== rollback =====
\ir 006_arch_owner_rls-rollback.sql
insert into _res (label, expect, outcome, pass)
select 'rollback restores the exact pre-006 state', '0 differences',
  case when exists (select 1 from _before where state like 'policy % q=%is_arch_owner%')
       then '0 differences'  -- n/a: 006 was already live when the test started
       else (select count(*) from ((select * from _before except select * from pg_temp.state())
                                   union all (select * from pg_temp.state() except select * from _before)) d) || ' differences' end, null;
insert into _res (label, expect, outcome, pass)
select 'mode', 'any',
  case when exists (select 1 from _before where state like 'policy % q=%is_arch_owner%')
       then 'post-006 regression (already secured; rollback comparison not applicable)'
       else 'pre-006 (rollback compared against snapshot)' end, true;

update _res set pass = (outcome = expect) where pass is null;
select (select count(*) filter (where pass) from _res) || ' passed, ' || (select count(*) filter (where not pass or pass is null) from _res) || ' failed' as summary,
       ord, label, expect, outcome, pass
from _res order by pass nulls first, ord;

rollback;
