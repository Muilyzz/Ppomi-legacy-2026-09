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
select pg_temp.ppomi_assert(public.ppomi_record_get('98e00000-0000-4000-8000-000000000001')->>'found'='false', 'missing record is explicit');
select pg_temp.ppomi_assert(public.ppomi_record_blob_put('bd913ff68243d41b9611b2690dfbf2b0f6e42ea14536a98232af60e9f64ffdaa','eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eA==')->>'size'='40', 'cipher blob digest checked');
select pg_temp.ppomi_assert(public.ppomi_record_blob_put('bd913ff68243d41b9611b2690dfbf2b0f6e42ea14536a98232af60e9f64ffdaa','eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eA==')->>'size'='40', 'blob retry is idempotent');
select pg_temp.ppomi_assert(public.ppomi_record_blob_get('bd913ff68243d41b9611b2690dfbf2b0f6e42ea14536a98232af60e9f64ffdaa')->>'data'='eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eA==', 'blob read matches written ciphertext');
select pg_temp.ppomi_expect_error($q$select public.ppomi_record_blob_put('bd913ff68243d41b9611b2690dfbf2b0f6e42ea14536a98232af60e9f64ffdaa','AAAA')$q$, '22023', 'invalid blob size rejected');
select pg_temp.ppomi_expect_error($q$select public.ppomi_record_blob_put('0000000000000000000000000000000000000000000000000000000000000000','eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eA==')$q$, '22023', 'wrong digest rejected');
select pg_temp.ppomi_expect_error($q$select public.ppomi_record_blob_put('bd913ff68243d41b9611b2690dfbf2b0f6e42ea14536a98232af60e9f64ffdaa','***')$q$, '22023', 'invalid base64 rejected');
select pg_temp.ppomi_assert(public.ppomi_record_put('98e00000-0000-4000-8000-000000000001',0,'98f00000-0000-4000-8000-000000000001','98e00000-0000-4000-8000-000000000002','["bd913ff68243d41b9611b2690dfbf2b0f6e42ea14536a98232af60e9f64ffdaa"]')->>'version'='1', 'initial CAS creates revision 1');
select pg_temp.ppomi_assert(public.ppomi_record_put('98e00000-0000-4000-8000-000000000001',0,'98f00000-0000-4000-8000-000000000001','98e00000-0000-4000-8000-000000000002','["bd913ff68243d41b9611b2690dfbf2b0f6e42ea14536a98232af60e9f64ffdaa"]')->>'version'='1', 'operation retry is idempotent');
select pg_temp.ppomi_assert(public.ppomi_record_put('98e00000-0000-4000-8000-000000000001',1,'98f00000-0000-4000-8000-000000000002','98e00000-0000-4000-8000-000000000002','["bd913ff68243d41b9611b2690dfbf2b0f6e42ea14536a98232af60e9f64ffdaa"]')->>'version'='2', 'CAS advances revision');
select pg_temp.ppomi_assert(public.ppomi_record_put('98e00000-0000-4000-8000-000000000001',0,'98f00000-0000-4000-8000-000000000001','98e00000-0000-4000-8000-000000000002','["bd913ff68243d41b9611b2690dfbf2b0f6e42ea14536a98232af60e9f64ffdaa"]')->>'version'='1', 'old operation returns original receipt');
select pg_temp.ppomi_assert(public.ppomi_record_get('98e00000-0000-4000-8000-000000000001')->>'version'='2', 'GET remains current after old retry');
select pg_temp.ppomi_expect_error($q$select public.ppomi_record_put('98e00000-0000-4000-8000-000000000001',0,'98f00000-0000-4000-8000-000000000003','98e00000-0000-4000-8000-000000000002','["bd913ff68243d41b9611b2690dfbf2b0f6e42ea14536a98232af60e9f64ffdaa"]')$q$, '40001', 'stale CAS cannot overwrite');
select pg_temp.ppomi_expect_error($q$select public.ppomi_record_put('98e00000-0000-4000-8000-000000000001',1,'98f00000-0000-4000-8000-000000000001','98e00000-0000-4000-8000-000000000002','["bd913ff68243d41b9611b2690dfbf2b0f6e42ea14536a98232af60e9f64ffdaa"]')$q$, '22023', 'same operation cannot change request');
select pg_temp.ppomi_expect_error($q$select public.ppomi_record_put('98e00000-0000-4000-8000-000000000001',2,'98f00000-0000-4000-8000-000000000003','98e00000-0000-4000-8000-000000000002','[]')$q$, '22023', 'empty chunk list rejected');
select pg_temp.ppomi_expect_error($q$select public.ppomi_record_put('98e00000-0000-4000-8000-000000000001',2,'98f00000-0000-4000-8000-000000000003','98e00000-0000-4000-8000-000000000002','[5]')$q$, '22023', 'nonstring chunk rejected');
select pg_temp.ppomi_expect_error($q$select public.ppomi_record_put('98e00000-0000-4000-8000-000000000001',2,'98f00000-0000-4000-8000-000000000003','98e00000-0000-4000-8000-000000000002','["0000000000000000000000000000000000000000000000000000000000000000"]')$q$, '22023', 'missing chunk rejected');
select pg_temp.ppomi_assert((select count(*) from public.ppomi_record_revisions)=2, 'history contains only committed revisions');
select pg_temp.ppomi_expect_error($q$delete from public.ppomi_record_blobs$q$, '42501', 'ppomi_record_blobs direct writes denied');
select pg_temp.ppomi_expect_error($q$delete from public.ppomi_record_heads$q$, '42501', 'ppomi_record_heads direct writes denied');
select pg_temp.ppomi_expect_error($q$delete from public.ppomi_record_revisions$q$, '42501', 'ppomi_record_revisions direct writes denied');
select pg_temp.ppomi_expect_error($q$select * from public.ppomi_record_operations$q$, '42501', 'operation receipts private');
select set_config('request.jwt.claim.sub','99a00000-0000-4000-8000-000000000002',true);
select pg_temp.ppomi_assert(public.ppomi_record_get('98e00000-0000-4000-8000-000000000001')->>'version'='2', 'other member may read ciphertext head');
select pg_temp.ppomi_expect_error($q$select public.ppomi_record_put('98e00000-0000-4000-8000-000000000001',2,'98f00000-0000-4000-8000-000000000004','98e00000-0000-4000-8000-000000000002','["bd913ff68243d41b9611b2690dfbf2b0f6e42ea14536a98232af60e9f64ffdaa"]')$q$, '42501', 'other device cannot replace assigned writer');
select set_config('request.jwt.claim.sub','99a00000-0000-4000-8000-000000000003',true);
select pg_temp.ppomi_assert(public.ppomi_record_get('98e00000-0000-4000-8000-000000000001')->>'found'='false', 'cross workspace head hidden');
select pg_temp.ppomi_expect_error($q$select public.ppomi_record_blob_get('bd913ff68243d41b9611b2690dfbf2b0f6e42ea14536a98232af60e9f64ffdaa')$q$, 'P0002', 'cross workspace ciphertext hidden');
select pg_temp.ppomi_assert((select count(*) from public.ppomi_record_blobs)=0, 'ppomi_record_blobs RLS isolates workspaces');
select pg_temp.ppomi_assert((select count(*) from public.ppomi_record_heads)=0, 'ppomi_record_heads RLS isolates workspaces');
select pg_temp.ppomi_assert((select count(*) from public.ppomi_record_revisions)=0, 'ppomi_record_revisions RLS isolates workspaces');
select set_config('request.jwt.claim.sub','99a00000-0000-4000-8000-000000000004',true);
select pg_temp.ppomi_expect_error($q$select public.ppomi_record_get('98e00000-0000-4000-8000-000000000001')$q$, '42501', 'revoked device loses access');
reset role;
set local role anon;
select pg_temp.ppomi_expect_error($q$select public.ppomi_record_get('98e00000-0000-4000-8000-000000000001')$q$, '42501', 'anonymous RPC denied');
reset role;
select pg_temp.ppomi_expect_error($q$delete from public.ppomi_record_blobs$q$, '55000', 'ppomi_record_blobs history immutable even for owner');
select pg_temp.ppomi_expect_error($q$delete from public.ppomi_record_revisions$q$, '55000', 'ppomi_record_revisions history immutable even for owner');
select pg_temp.ppomi_expect_error($q$delete from public.ppomi_record_operations$q$, '55000', 'ppomi_record_operations history immutable even for owner');
select count(*) as passed from pg_temp.ppomi_test_results;
rollback;
