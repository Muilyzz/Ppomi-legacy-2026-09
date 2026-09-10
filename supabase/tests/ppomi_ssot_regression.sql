-- Run as the migration owner using psql -v ON_ERROR_STOP=1 -f ... .
-- Every fixture and write rolls back. Auth users are synthetic isolated UUIDs.
-- The tests impersonate authenticated/anon roles; helper functions are INVOKER.
begin;

create temporary table ppomi_test_results(label text not null) on commit drop;
grant select, insert on pg_temp.ppomi_test_results to authenticated, anon;

create function pg_temp.ppomi_assert(p_condition boolean, p_label text)
returns void language plpgsql as $$
begin
    if p_condition is not true then raise exception 'FAIL: %', p_label; end if;
    insert into pg_temp.ppomi_test_results(label) values (p_label);
    raise notice 'PASS: %', p_label;
end;
$$;
create function pg_temp.ppomi_expect_error(p_sql text, p_code text, p_label text)
returns void language plpgsql as $$
declare v_caught boolean := false;
begin
    begin
        execute p_sql;
    exception when others then
        if sqlstate <> p_code then
            raise exception 'FAIL: % (expected SQLSTATE %, got %: %)', p_label, p_code, sqlstate, sqlerrm;
        end if;
        v_caught := true;
    end;
    if not v_caught then raise exception 'FAIL: % (operation unexpectedly succeeded)', p_label; end if;
    insert into pg_temp.ppomi_test_results(label) values (p_label);
    raise notice 'PASS: %', p_label;
end;
$$;

insert into auth.users(id) values
 ('99a00000-0000-4000-8000-000000000001'), ('99a00000-0000-4000-8000-000000000002'),
 ('99a00000-0000-4000-8000-000000000003'), ('99a00000-0000-4000-8000-000000000004'),
 ('99a00000-0000-4000-8000-000000000005');
insert into public.ppomi_workspaces(id, name) values
 ('99b00000-0000-4000-8000-000000000001', 'Synthetic A'), ('99b00000-0000-4000-8000-000000000002', 'Synthetic B');
insert into public.ppomi_devices(id, workspace_id, auth_user_id, label, platform, revoked_at) values
 ('99c00000-0000-4000-8000-000000000001', '99b00000-0000-4000-8000-000000000001', '99a00000-0000-4000-8000-000000000001', 'Synthetic Mac', 'macos', null),
 ('99c00000-0000-4000-8000-000000000002', '99b00000-0000-4000-8000-000000000001', '99a00000-0000-4000-8000-000000000002', 'Synthetic Android', 'android', null),
 ('99c00000-0000-4000-8000-000000000003', '99b00000-0000-4000-8000-000000000002', '99a00000-0000-4000-8000-000000000003', 'Other workspace', 'android', null),
 ('99c00000-0000-4000-8000-000000000004', '99b00000-0000-4000-8000-000000000001', '99a00000-0000-4000-8000-000000000004', 'Revoked', 'android', statement_timestamp());

set local role authenticated;
select set_config('request.jwt.claim.sub', '99a00000-0000-4000-8000-000000000001', true);
select pg_temp.ppomi_assert(public.ppomi_context()->'device'->>'id' = '99c00000-0000-4000-8000-000000000001', 'device identity comes from auth.uid');
select pg_temp.ppomi_assert(jsonb_array_length(public.ppomi_context()->'devices') = 2, 'context excludes other workspaces and revoked devices');
select pg_temp.ppomi_assert((select count(*) from public.ppomi_workspaces) = 1, 'workspace SELECT uses RLS');
select pg_temp.ppomi_assert((select count(id) from public.ppomi_devices) = 3, 'device SELECT remains inside workspace');
select pg_temp.ppomi_expect_error('select auth_user_id from public.ppomi_devices', '42501', 'device auth identity column is private');
select pg_temp.ppomi_expect_error('select public.ppomi_private_device()', '42501', 'internal security definer helper cannot be called');
select pg_temp.ppomi_expect_error('select * from public.ppomi_operations', '42501', 'operation replay journal is private');
select pg_temp.ppomi_expect_error('insert into public.ppomi_workspaces(name) values (''forged'')', '42501', 'authenticated INSERT denied');
select pg_temp.ppomi_expect_error('update public.ppomi_devices set revoked_at = null', '42501', 'authenticated UPDATE denied');
select pg_temp.ppomi_expect_error('delete from public.ppomi_runs', '42501', 'authenticated DELETE denied');

select pg_temp.ppomi_assert((public.ppomi_put_document('test:rule', 'rule', 'First', '{"enabled":true}', 0, '99d00000-0000-4000-8000-000000000001')->>'version')::bigint = 1, 'document creation starts at version 1');
select pg_temp.ppomi_assert((public.ppomi_put_document('test:rule', 'rule', 'Second', '{"enabled":false}', 1, '99d00000-0000-4000-8000-000000000002')->>'version')::bigint = 2, 'document compare-and-set advances version');
select pg_temp.ppomi_assert(public.ppomi_put_document('test:rule', 'rule', 'First', '{"enabled":true}', 0, '99d00000-0000-4000-8000-000000000001')->>'title' = 'First', 'document retry returns original response after later update');
select pg_temp.ppomi_expect_error($q$select public.ppomi_put_document('test:rule', 'rule', 'Changed', '{}', 0, '99d00000-0000-4000-8000-000000000001')$q$, '22023', 'document operation UUID rejects changed input');
select pg_temp.ppomi_expect_error($q$select public.ppomi_put_document('test:rule', 'rule', 'Stale', '{}', 1, '99d00000-0000-4000-8000-000000000003')$q$, '40001', 'stale document write rejects instead of overwriting');
select pg_temp.ppomi_assert((public.ppomi_put_document('test:rule', 'rule', 'Second', '{"enabled":false}', 2, '99d00000-0000-4000-8000-000000000004', true)->>'archived')::boolean, 'document soft archive is versioned');
select pg_temp.ppomi_assert(jsonb_array_length(public.ppomi_list_documents()) = 1, 'document list retains archived record');
select pg_temp.ppomi_expect_error($q$select public.ppomi_put_document('bad/id', 'rule', 'Bad', '{}', 0, '99d00000-0000-4000-8000-000000000005')$q$, '22023', 'document ID cannot be a filesystem path');
select pg_temp.ppomi_expect_error($q$select public.ppomi_put_document('bad', 'rule', 'Bad', '[]', 0, '99d00000-0000-4000-8000-000000000005')$q$, '22023', 'document body must be an object');

select pg_temp.ppomi_assert(public.ppomi_create_run('99e00000-0000-4000-8000-000000000001', '99c00000-0000-4000-8000-000000000002', 'Synthetic fixture task')->>'state' = 'queued', 'Mac creates queued run for Android');
select pg_temp.ppomi_assert(public.ppomi_create_run('99e00000-0000-4000-8000-000000000001', '99c00000-0000-4000-8000-000000000002', 'Synthetic fixture task')->>'version' = '1', 'exact create UUID retry is idempotent');
select pg_temp.ppomi_expect_error($q$select public.ppomi_create_run('99e00000-0000-4000-8000-000000000001', '99c00000-0000-4000-8000-000000000002', 'Changed task')$q$, '22023', 'create UUID rejects changed request');
select pg_temp.ppomi_expect_error($q$select public.ppomi_create_run('99e00000-0000-4000-8000-000000000003', '99c00000-0000-4000-8000-000000000003', 'Other workspace')$q$, '42501', 'cross-workspace executor denied');
select pg_temp.ppomi_expect_error($q$select public.ppomi_create_run('99e00000-0000-4000-8000-000000000003', '99c00000-0000-4000-8000-000000000004', 'Revoked executor')$q$, '42501', 'revoked executor denied');
select pg_temp.ppomi_expect_error($q$select public.ppomi_claim_run('99e00000-0000-4000-8000-000000000001', 1)$q$, '42501', 'creator cannot claim another device execution');
select pg_temp.ppomi_expect_error($q$select public.ppomi_append_run_event('99e00000-0000-4000-8000-000000000001','99f00000-0000-4000-8000-000000000001',1,'cancelled','cancel','','{}')$q$, '42501', 'creator cannot publish executor events');
select pg_temp.ppomi_expect_error('select public.ppomi_list_runs(201)', '22023', 'run query bound enforced');

select set_config('request.jwt.claim.sub', '99a00000-0000-4000-8000-000000000003', true);
select pg_temp.ppomi_assert(jsonb_array_length(public.ppomi_list_runs()) = 0 and jsonb_array_length(public.ppomi_list_documents()) = 0, 'other workspace RPC lists exclude shared records');
select pg_temp.ppomi_assert((select count(*) from public.ppomi_runs) = 0 and (select count(*) from public.ppomi_documents) = 0, 'other workspace direct SELECT uses RLS');
select pg_temp.ppomi_expect_error($q$select public.ppomi_get_run('99e00000-0000-4000-8000-000000000001')$q$, 'P0002', 'cross-workspace run lookup denied');
select pg_temp.ppomi_expect_error($q$select public.ppomi_claim_run('99e00000-0000-4000-8000-000000000001',1)$q$, 'P0002', 'cross-workspace claim denied');

select set_config('request.jwt.claim.sub', '99a00000-0000-4000-8000-000000000004', true);
select pg_temp.ppomi_expect_error('select public.ppomi_context()', '42501', 'revoked device loses RPC access');
select pg_temp.ppomi_expect_error('select * from public.ppomi_workspaces', '42501', 'revoked device loses direct SELECT access');
select set_config('request.jwt.claim.sub', '99a00000-0000-4000-8000-000000000005', true);
select pg_temp.ppomi_expect_error('select public.ppomi_context()', '42501', 'unregistered Auth user is not a device');

select set_config('request.jwt.claim.sub', '99a00000-0000-4000-8000-000000000002', true);
select pg_temp.ppomi_expect_error($q$select public.ppomi_append_run_event('99e00000-0000-4000-8000-000000000001','99f00000-0000-4000-8000-000000000001',1,'running','progress','','{}')$q$, '55000', 'ordinary event cannot bypass queued claim');
select pg_temp.ppomi_assert(public.ppomi_claim_run('99e00000-0000-4000-8000-000000000001', 1)->>'version' = '2', 'assigned executor claims once');
select pg_temp.ppomi_expect_error($q$select public.ppomi_claim_run('99e00000-0000-4000-8000-000000000001',1)$q$, '40001', 'duplicate claim fails without replay');
select pg_temp.ppomi_assert(public.ppomi_append_run_event('99e00000-0000-4000-8000-000000000001','99f00000-0000-4000-8000-000000000001',2,'running','progress','Observed fixture','{}')->'run'->>'version' = '3', 'same-state progress appends once');
select pg_temp.ppomi_expect_error($q$select public.ppomi_append_run_event('99e00000-0000-4000-8000-000000000001','99f00000-0000-4000-8000-000000000001',2,'running','progress','Changed','{}')$q$, '22023', 'event UUID rejects changed content');
select pg_temp.ppomi_expect_error($q$select public.ppomi_append_run_event('99e00000-0000-4000-8000-000000000001','99f00000-0000-4000-8000-000000000099',2,'running','progress','','{}')$q$, '40001', 'stale event version rejects');
select pg_temp.ppomi_expect_error($q$select public.ppomi_append_run_event('99e00000-0000-4000-8000-000000000001','99f00000-0000-4000-8000-000000000099',3,'running','evidence','','{"screenshot":"base64"}')$q$, '22023', 'raw screenshot event data rejected');
select pg_temp.ppomi_expect_error($q$select public.ppomi_append_run_event('99e00000-0000-4000-8000-000000000001','99f00000-0000-4000-8000-000000000099',3,'running','evidence','','{"evidence_ref":"/data/user/private.png"}')$q$, '22023', 'private evidence path rejected');
select pg_temp.ppomi_expect_error($q$select public.ppomi_append_run_event('99e00000-0000-4000-8000-000000000001','99f00000-0000-4000-8000-000000000099',3,'running','evidence','','{"evidence_sha256":null}')$q$, '22023', 'null hash metadata rejected');
select pg_temp.ppomi_assert(public.ppomi_append_run_event('99e00000-0000-4000-8000-000000000001','99f00000-0000-4000-8000-000000000002',3,'waiting_approval','approval_requested','Needs local approval','{}')->'run'->>'version' = '4', 'executor enters approval wait');
select pg_temp.ppomi_expect_error($q$select public.ppomi_append_run_event('99e00000-0000-4000-8000-000000000001','99f00000-0000-4000-8000-000000000003',4,'running','progress','','{}')$q$, '55000', 'approval cannot be bypassed by progress');
select pg_temp.ppomi_expect_error($q$select public.ppomi_append_run_event('99e00000-0000-4000-8000-000000000001','99f00000-0000-4000-8000-000000000003',4,'running','approval','','{"user_action":false}')$q$, '55000', 'approval requires affirmative user action');
select pg_temp.ppomi_assert(public.ppomi_append_run_event('99e00000-0000-4000-8000-000000000001','99f00000-0000-4000-8000-000000000003',4,'running','approval','Approved locally','{"user_action":true}')->'run'->>'version' = '5', 'explicit local approval resumes execution');
select pg_temp.ppomi_assert(public.ppomi_append_run_event('99e00000-0000-4000-8000-000000000001','99f00000-0000-4000-8000-000000000004',5,'interrupted','interrupted','Process stopped','{}')->'run'->>'version' = '6', 'interruption recorded without reassignment');
select pg_temp.ppomi_expect_error($q$select public.ppomi_append_run_event('99e00000-0000-4000-8000-000000000001','99f00000-0000-4000-8000-000000000005',6,'running','progress','','{}')$q$, '55000', 'interruption never resumes automatically');
select pg_temp.ppomi_assert(public.ppomi_append_run_event('99e00000-0000-4000-8000-000000000001','99f00000-0000-4000-8000-00000000000a',6,'interrupted','progress','Checkpoint inspected','{}')->'run'->>'version' = '7', 'interrupted metadata update does not restart work');
select pg_temp.ppomi_assert(public.ppomi_append_run_event('99e00000-0000-4000-8000-000000000001','99f00000-0000-4000-8000-000000000005',7,'running','resume','Explicit safe local checkpoint','{"user_action":true}')->'run'->>'version' = '8', 'explicit executor resume accepted');
select pg_temp.ppomi_assert(public.ppomi_append_run_event('99e00000-0000-4000-8000-000000000001','99f00000-0000-4000-8000-000000000006',8,'completed','completed','Verified fixture','{"evidence_ref":"fixture:result","evidence_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","local_task_id":"99e00000-0000-4000-8000-000000000001"}')->'run'->>'version' = '9', 'completion stores only minimal evidence metadata');
select pg_temp.ppomi_assert(public.ppomi_append_run_event('99e00000-0000-4000-8000-000000000001','99f00000-0000-4000-8000-000000000001',2,'running','progress','Observed fixture','{}')->'run'->>'version' = '3', 'event retry returns original response even after terminal state');
select pg_temp.ppomi_expect_error($q$select public.ppomi_append_run_event('99e00000-0000-4000-8000-000000000001','99f00000-0000-4000-8000-000000000007',9,'running','resume','','{"user_action":true}')$q$, '55000', 'completed run cannot reopen');
select pg_temp.ppomi_assert(jsonb_array_length(public.ppomi_get_run('99e00000-0000-4000-8000-000000000001')->'events') = 9, 'rejections and retries append no duplicate events');
select pg_temp.ppomi_assert((select bool_and(expected_version + 1 = version) from public.ppomi_run_events), 'event versions form single-step commits');
select pg_temp.ppomi_assert(public.ppomi_create_run('99e00000-0000-4000-8000-000000000001', '99c00000-0000-4000-8000-000000000002', 'Synthetic fixture task')->>'state' = 'queued', 'create retry after completion preserves original response');
select pg_temp.ppomi_assert(public.ppomi_get_run('99e00000-0000-4000-8000-000000000001')->'run'->>'state' = 'completed', 'current GET remains authoritative after retry');
select pg_temp.ppomi_assert(public.ppomi_create_run('99e00000-0000-4000-8000-000000000002', '99c00000-0000-4000-8000-000000000002', 'Cancel without running')->>'state' = 'queued', 'second run remains independently queued');
select pg_temp.ppomi_assert(public.ppomi_append_run_event('99e00000-0000-4000-8000-000000000002','99f00000-0000-4000-8000-00000000000b',1,'queued','progress','Inspected queued request','{}')->'run'->>'version' = '2', 'queued metadata update does not claim execution');
select pg_temp.ppomi_assert(public.ppomi_append_run_event('99e00000-0000-4000-8000-000000000002','99f00000-0000-4000-8000-000000000008',2,'cancelled','cancel','Cancelled before execution','{"user_action":true}')->'run'->>'state' = 'cancelled', 'executor can cancel queued work without executing');
select pg_temp.ppomi_expect_error($q$select public.ppomi_append_run_event('99e00000-0000-4000-8000-000000000002','99f00000-0000-4000-8000-000000000009',3,'cancelled','progress','','{}')$q$, '55000', 'terminal same-state progress denied');

set local role anon;
select pg_temp.ppomi_expect_error('select public.ppomi_context()', '42501', 'anon cannot call context RPC even with a spoofed claim setting');
select pg_temp.ppomi_expect_error('select * from public.ppomi_runs', '42501', 'anon cannot read table');

reset role;
select pg_temp.ppomi_expect_error($q$update public.ppomi_runs set executor_device_id = '99c00000-0000-4000-8000-000000000001' where id = '99e00000-0000-4000-8000-000000000001'$q$, '55000', 'database trigger enforces immutable executor');
select pg_temp.ppomi_expect_error($q$update public.ppomi_run_events set summary = 'rewritten' where run_id = '99e00000-0000-4000-8000-000000000001'$q$, '55000', 'database trigger prevents event rewrite');
select pg_temp.ppomi_expect_error($q$delete from public.ppomi_run_events where run_id = '99e00000-0000-4000-8000-000000000001'$q$, '55000', 'database trigger prevents event deletion');
select pg_temp.ppomi_assert((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname like 'ppomi_%' and p.prosecdef and p.proconfig @> array['search_path=""']) = 10,
  'every SECURITY DEFINER function locks its search_path');

select jsonb_build_object('result', 'passed', 'assertions', count(*), 'fixture_cleanup', 'transaction_rollback') as ppomi_regression_result
  from pg_temp.ppomi_test_results;
rollback;
