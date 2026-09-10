-- Run only after the migration, as the migration owner. All synthetic fixtures
-- and assertions are rolled back; no existing records are altered or read out.
begin;
create temporary table agent_test_results(label text not null) on commit drop;
grant select, insert on pg_temp.agent_test_results to authenticated, anon;
create function pg_temp.agent_assert(condition boolean, label text)
returns void language plpgsql as $$
begin
    if condition is not true then raise exception 'FAIL: %', label; end if;
    insert into pg_temp.agent_test_results values (label);
end;
$$;
create function pg_temp.agent_error(sql text, code text, label text)
returns void language plpgsql as $$
declare caught boolean := false;
begin
    begin execute sql;
    exception when others then
        if sqlstate <> code then raise exception 'FAIL: % (expected %, got %)', label, code, sqlstate; end if;
        caught := true;
    end;
    if not caught then raise exception 'FAIL: % (unexpected success)', label; end if;
    insert into pg_temp.agent_test_results values (label);
end;
$$;
create function pg_temp.agent_envelope()
returns jsonb language sql immutable as $$
    select '{"version":1,"nonce":"AAAAAAAAAAAAAAAA","ciphertext":"syntheticciphertext","tag":"AAAAAAAAAAAAAAAAAAAAAA"}'::jsonb;
$$;

insert into auth.users(id) values
 ('97a00000-0000-4000-8000-000000000001'), ('97a00000-0000-4000-8000-000000000002'),
 ('97a00000-0000-4000-8000-000000000003'), ('97a00000-0000-4000-8000-000000000004');
insert into public.ppomi_workspaces(id,name) values
 ('97b00000-0000-4000-8000-000000000001','Synthetic memory A'), ('97b00000-0000-4000-8000-000000000002','Synthetic memory B');
insert into public.ppomi_devices(id,workspace_id,auth_user_id,label,platform,revoked_at) values
 ('97c00000-0000-4000-8000-000000000001','97b00000-0000-4000-8000-000000000001','97a00000-0000-4000-8000-000000000001','Synthetic Mac','macos',null),
 ('97c00000-0000-4000-8000-000000000002','97b00000-0000-4000-8000-000000000001','97a00000-0000-4000-8000-000000000002','Synthetic Android','android',null),
 ('97c00000-0000-4000-8000-000000000003','97b00000-0000-4000-8000-000000000002','97a00000-0000-4000-8000-000000000003','Other workspace','android',null),
 ('97c00000-0000-4000-8000-000000000004','97b00000-0000-4000-8000-000000000001','97a00000-0000-4000-8000-000000000004','Revoked','android',statement_timestamp());
set local role authenticated;
select set_config('request.jwt.claim.sub','97a00000-0000-4000-8000-000000000001',true);
select pg_temp.agent_assert(public.ppomi_agent_memory_list()='[]'::jsonb,'new workspace list empty');
select pg_temp.agent_assert(public.ppomi_agent_memory_save('97d00000-0000-4000-8000-000000000001',pg_temp.agent_envelope(),repeat('a',64))->>'id'='97d00000-0000-4000-8000-000000000001','save returns stable id');
select pg_temp.agent_assert(public.ppomi_agent_memory_save('97d00000-0000-4000-8000-000000000001',jsonb_set(pg_temp.agent_envelope(),'{nonce}','"BBBBBBBBBBBBBBBB"'),repeat('a',64))->'envelope'->>'nonce'='AAAAAAAAAAAAAAAA','retry returns original ciphertext');
select pg_temp.agent_assert((select count(*) from public.ppomi_agent_memories)=1,'retry did not duplicate row');
select pg_temp.agent_error($q$select public.ppomi_agent_memory_save('97d00000-0000-4000-8000-000000000001',pg_temp.agent_envelope(),repeat('b',64))$q$,'PT409','changed content digest conflicts');
select pg_temp.agent_error($q$select public.ppomi_agent_memory_save('97d00000-0000-4000-8000-000000000001',pg_temp.agent_envelope(),repeat('a',64),'97d00000-0000-4000-8000-000000000002')$q$,'PT409','changed replacement conflicts');
select pg_temp.agent_error($q$select public.ppomi_agent_memory_save('97d00000-0000-4000-8000-000000000002','{}',repeat('a',64))$q$,'22023','missing envelope fields rejected');
select pg_temp.agent_error($q$select public.ppomi_agent_memory_save('97d00000-0000-4000-8000-000000000002',pg_temp.agent_envelope() || '{"text":"raw"}',repeat('a',64))$q$,'22023','plaintext envelope field rejected');
select pg_temp.agent_error($q$select public.ppomi_agent_memory_save('97d00000-0000-4000-8000-000000000002',jsonb_set(pg_temp.agent_envelope(),'{version}','2'),repeat('a',64))$q$,'22023','unknown envelope version rejected');
select pg_temp.agent_error($q$select public.ppomi_agent_memory_save('97d00000-0000-4000-8000-000000000002',jsonb_set(pg_temp.agent_envelope(),'{nonce}','null'),repeat('a',64))$q$,'22023','null nonce rejected');
select pg_temp.agent_error($q$select public.ppomi_agent_memory_save('97d00000-0000-4000-8000-000000000002',pg_temp.agent_envelope(),'plain')$q$,'22023','invalid digest rejected');
select pg_temp.agent_error($q$select public.ppomi_agent_memory_save('97d00000-0000-4000-8000-000000000002',pg_temp.agent_envelope(),repeat('b',64),'97d00000-0000-4000-8000-000000000002')$q$,'22023','self replacement rejected');
select pg_temp.agent_error($q$select public.ppomi_agent_memory_save('97d00000-0000-4000-8000-000000000002',pg_temp.agent_envelope(),repeat('b',64),'97d00000-0000-4000-8000-000000000099')$q$,'PT404','unknown replacement target hidden');
select pg_temp.agent_error($q$delete from public.ppomi_agent_memories$q$,'42501','direct delete denied');
select pg_temp.agent_error($q$update public.ppomi_agent_memories set envelope='{}'$q$,'42501','direct update denied');
select pg_temp.agent_error($q$insert into public.ppomi_agent_memories(workspace_id,id,created_by_device_id,envelope,request_digest) values ('97b00000-0000-4000-8000-000000000001','97d00000-0000-4000-8000-000000000003','97c00000-0000-4000-8000-000000000001','{}',repeat('a',64))$q$,'42501','direct insert denied');
select set_config('request.jwt.claim.sub','97a00000-0000-4000-8000-000000000002',true);
select pg_temp.agent_assert(jsonb_array_length(public.ppomi_agent_memory_list())=1,'other workspace member reads record');
select pg_temp.agent_assert(public.ppomi_agent_memory_save('97d00000-0000-4000-8000-000000000002',pg_temp.agent_envelope(),repeat('b',64),'97d00000-0000-4000-8000-000000000001')->>'replaces_id'='97d00000-0000-4000-8000-000000000001','other member replacement preserves parent');
select pg_temp.agent_assert((select count(*) from public.ppomi_agent_memories)=2,'replacement retains history');
select pg_temp.agent_assert(jsonb_array_length(public.ppomi_agent_memory_list())=1 and public.ppomi_agent_memory_list()->0->>'id'='97d00000-0000-4000-8000-000000000002','current list shows replacement');
select pg_temp.agent_error($q$select public.ppomi_agent_memory_save('97d00000-0000-4000-8000-000000000003',pg_temp.agent_envelope(),repeat('c',64),'97d00000-0000-4000-8000-000000000001')$q$,'PT409','history cannot fork');
select set_config('request.jwt.claim.sub','97a00000-0000-4000-8000-000000000003',true);
select pg_temp.agent_assert(public.ppomi_agent_memory_list()='[]'::jsonb,'cross workspace list empty');
select pg_temp.agent_assert((select count(*) from public.ppomi_agent_memories)=0,'RLS hides other workspace ciphertext');
select pg_temp.agent_error($q$select public.ppomi_agent_memory_delete('97d00000-0000-4000-8000-000000000001')$q$,'PT404','cross workspace delete hidden');
select pg_temp.agent_error($q$select public.ppomi_agent_memory_save('97d00000-0000-4000-8000-000000000003',pg_temp.agent_envelope(),repeat('c',64),'97d00000-0000-4000-8000-000000000001')$q$,'PT404','cross workspace replacement hidden');
select set_config('request.jwt.claim.sub','97a00000-0000-4000-8000-000000000004',true);
select pg_temp.agent_error($q$select public.ppomi_agent_memory_list()$q$,'42501','revoked device read denied');
select pg_temp.agent_error($q$select public.ppomi_agent_memory_delete('97d00000-0000-4000-8000-000000000002')$q$,'42501','revoked device delete denied');
select pg_temp.agent_error($q$select public.ppomi_agent_memory_save('97d00000-0000-4000-8000-000000000003',pg_temp.agent_envelope(),repeat('c',64))$q$,'42501','revoked device save denied');
select set_config('request.jwt.claim.sub','97a00000-0000-4000-8000-000000000001',true);
select pg_temp.agent_assert(public.ppomi_agent_memory_delete('97d00000-0000-4000-8000-000000000002')->>'deleted'='true','delete confirmed');
select pg_temp.agent_assert(public.ppomi_agent_memory_delete('97d00000-0000-4000-8000-000000000002')->>'deleted'='true','delete retry idempotent');
select pg_temp.agent_assert(public.ppomi_agent_memory_list()='[]'::jsonb,'deleting replacement never resurrects parent');
select pg_temp.agent_assert((select count(*) from public.ppomi_agent_memories)=2,'delete preserves opaque tombstone identity');
select pg_temp.agent_assert((select count(*) from public.ppomi_agent_memories where envelope='{}'::jsonb and deleted_at is not null)=2,'delete wipes selected record and ancestor ciphertext');
select pg_temp.agent_error($q$select public.ppomi_agent_memory_save('97d00000-0000-4000-8000-000000000002',pg_temp.agent_envelope(),repeat('b',64),'97d00000-0000-4000-8000-000000000001')$q$,'PT410','save retry cannot revive tombstone');
reset role;
set local role anon;
select pg_temp.agent_error($q$select public.ppomi_agent_memory_list()$q$,'42501','anon read denied');
select pg_temp.agent_error($q$select public.ppomi_agent_memory_delete('97d00000-0000-4000-8000-000000000002')$q$,'42501','anon delete denied');
reset role;
select pg_temp.agent_error($q$delete from public.ppomi_agent_memories where workspace_id='97b00000-0000-4000-8000-000000000001'$q$,'55000','history hard delete denied');
select pg_temp.agent_error($q$update public.ppomi_agent_memories set envelope='{}' where workspace_id='97b00000-0000-4000-8000-000000000001' and id='97d00000-0000-4000-8000-000000000001'$q$,'55000','history content immutable');
select pg_temp.agent_error($q$update public.ppomi_agent_memories set deleted_at=null where workspace_id='97b00000-0000-4000-8000-000000000001' and id='97d00000-0000-4000-8000-000000000002'$q$,'55000','tombstone cannot be undone');
select count(*) as passed from pg_temp.agent_test_results;
rollback;
