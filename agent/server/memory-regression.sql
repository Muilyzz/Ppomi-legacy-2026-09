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
create function pg_temp.agent_payload(p_id uuid, p_text text, p_replaces uuid default null)
returns jsonb language sql immutable as $$
    select jsonb_build_object(
        'id', p_id,
        'kind', 'fact',
        'text', p_text,
        'source', 'tool_observed',
        'confidence', 1,
        'replacesId', to_jsonb(p_replaces),
        'selection', 'automatic');
$$;

insert into auth.users(id) values
 ('97a00000-0000-4000-8000-000000000001'), ('97a00000-0000-4000-8000-000000000002'),
 ('97a00000-0000-4000-8000-000000000003'), ('97a00000-0000-4000-8000-000000000004'),
 ('97a00000-0000-4000-8000-000000000005');
insert into public.ppomi_workspaces(id,name) values
 ('97b00000-0000-4000-8000-000000000001','Synthetic memory A'), ('97b00000-0000-4000-8000-000000000002','Synthetic memory B');
insert into public.ppomi_members(workspace_id,auth_user_id) values
 ('97b00000-0000-4000-8000-000000000001','97a00000-0000-4000-8000-000000000001'),
 ('97b00000-0000-4000-8000-000000000001','97a00000-0000-4000-8000-000000000002'),
 ('97b00000-0000-4000-8000-000000000002','97a00000-0000-4000-8000-000000000003'),
 ('97b00000-0000-4000-8000-000000000001','97a00000-0000-4000-8000-000000000005');
insert into public.ppomi_devices(id,workspace_id,auth_user_id,label,platform,revoked_at,approved_at) values
 ('97c00000-0000-4000-8000-000000000001','97b00000-0000-4000-8000-000000000001','97a00000-0000-4000-8000-000000000001','Synthetic Mac','macos',null,statement_timestamp()),
 ('97c00000-0000-4000-8000-000000000002','97b00000-0000-4000-8000-000000000001','97a00000-0000-4000-8000-000000000002','Synthetic Android','android',null,statement_timestamp()),
 ('97c00000-0000-4000-8000-000000000003','97b00000-0000-4000-8000-000000000002','97a00000-0000-4000-8000-000000000003','Other workspace','android',null,statement_timestamp()),
 ('97c00000-0000-4000-8000-000000000004','97b00000-0000-4000-8000-000000000001','97a00000-0000-4000-8000-000000000004','Revoked','android',statement_timestamp(),statement_timestamp()),
 ('97c00000-0000-4000-8000-000000000005','97b00000-0000-4000-8000-000000000001','97a00000-0000-4000-8000-000000000005','Pending web','web',null,null);

select set_config('app.ppomi_at_rest_key', 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=', true);

set local role authenticated;
select set_config('request.jwt.claim.sub','97a00000-0000-4000-8000-000000000001',true);
select pg_temp.agent_assert(public.ppomi_agent_memory_list()='[]'::jsonb,'new workspace list empty');
select pg_temp.agent_assert(
    public.ppomi_agent_memory_save(
        '97d00000-0000-4000-8000-000000000001',
        pg_temp.agent_payload('97d00000-0000-4000-8000-000000000001', 'from-vault'))->>'id'
    = '97d00000-0000-4000-8000-000000000001',
    'save returns stable id');
select pg_temp.agent_assert(
    public.ppomi_agent_memory_list()->0->'payload'->>'text' = 'from-vault'
    and not public.ppomi_agent_memory_list()->0 ? 'envelope',
    'write/list round-trip opens an at-rest payload');
select pg_temp.agent_assert(
    (select envelope::text not like '%from-vault%' from public.ppomi_agent_memories
      where id = '97d00000-0000-4000-8000-000000000001'),
    'at-rest dump does not contain the memory text');

select set_config('request.jwt.claim.sub','97a00000-0000-4000-8000-000000000005',true);
select set_config('request.headers','{"x-ppomi-device":"97c00000-0000-4000-8000-000000000005"}',true);
select pg_temp.agent_assert(jsonb_array_length(public.ppomi_agent_memory_list())=1,
    'pending web member may list memories without device approval');
select pg_temp.agent_assert(
    public.ppomi_agent_memory_save(
        '97d00000-0000-4000-8000-000000000021',
        pg_temp.agent_payload('97d00000-0000-4000-8000-000000000021', 'pending-write'))->>'id'
    = '97d00000-0000-4000-8000-000000000021',
    'pending web member may save without device approval');
select set_config('request.headers','',true);
select pg_temp.agent_assert(jsonb_array_length(public.ppomi_agent_memory_list())=2,
    'member JWT without a device header may list memories');
select pg_temp.agent_assert(
    public.ppomi_agent_memory_save(
        '97d00000-0000-4000-8000-000000000022',
        pg_temp.agent_payload('97d00000-0000-4000-8000-000000000022', 'jwt-only-write'))
    ->>'id' = '97d00000-0000-4000-8000-000000000022',
    'member JWT without a device header may save');
select pg_temp.agent_assert(
    (select created_by_device_id is null from public.ppomi_agent_memories
      where id = '97d00000-0000-4000-8000-000000000022'),
    'JWT-only save stores no device attribution');

select set_config('request.jwt.claim.sub','97a00000-0000-4000-8000-000000000001',true);
select pg_temp.agent_assert(
    public.ppomi_agent_memory_save(
        '97d00000-0000-4000-8000-000000000001',
        pg_temp.agent_payload('97d00000-0000-4000-8000-000000000001', 'from-vault'))
    ->'payload'->>'text' = 'from-vault',
    'retry returns original payload');
select pg_temp.agent_assert((select count(*) from public.ppomi_agent_memories)=3,'retry did not duplicate row');
select pg_temp.agent_error(
    $q$select public.ppomi_agent_memory_save(
        '97d00000-0000-4000-8000-000000000001',
        pg_temp.agent_payload('97d00000-0000-4000-8000-000000000001', 'other text'))$q$,
    'PT409','changed content conflicts');
select pg_temp.agent_error(
    $q$select public.ppomi_agent_memory_save(
        '97d00000-0000-4000-8000-000000000001',
        pg_temp.agent_payload('97d00000-0000-4000-8000-000000000001', 'from-vault', '97d00000-0000-4000-8000-000000000002'),
        '97d00000-0000-4000-8000-000000000002')$q$,
    'PT409','changed replacement conflicts');
select pg_temp.agent_error(
    $q$select public.ppomi_agent_memory_save('97d00000-0000-4000-8000-000000000002','{}')$q$,
    '22023','missing payload fields rejected');
select pg_temp.agent_error(
    $q$select public.ppomi_agent_memory_save(
        '97d00000-0000-4000-8000-000000000002',
        pg_temp.agent_payload('97d00000-0000-4000-8000-000000000002', 'x') || '{"extra":true}')$q$,
    '22023','unknown payload field rejected');
select pg_temp.agent_error(
    $q$select public.ppomi_agent_memory_save(
        '97d00000-0000-4000-8000-000000000002',
        jsonb_set(pg_temp.agent_payload('97d00000-0000-4000-8000-000000000002', 'x'), '{kind}', '"note"'))$q$,
    '22023','unknown kind rejected');
select pg_temp.agent_error(
    $q$select public.ppomi_agent_memory_save(
        '97d00000-0000-4000-8000-000000000002',
        jsonb_set(pg_temp.agent_payload('97d00000-0000-4000-8000-000000000002', 'x'), '{confidence}', '1.5'))$q$,
    '22023','confidence out of range rejected');
select pg_temp.agent_error(
    $q$select public.ppomi_agent_memory_save(
        '97d00000-0000-4000-8000-000000000002',
        pg_temp.agent_payload('97d00000-0000-4000-8000-000000000002', 'x'),
        '97d00000-0000-4000-8000-000000000002')$q$,
    '22023','self replacement rejected');
select pg_temp.agent_error(
    $q$select public.ppomi_agent_memory_save(
        '97d00000-0000-4000-8000-000000000002',
        pg_temp.agent_payload('97d00000-0000-4000-8000-000000000002', 'x', '97d00000-0000-4000-8000-000000000099'),
        '97d00000-0000-4000-8000-000000000099')$q$,
    'PT404','unknown replacement target hidden');
select pg_temp.agent_error($q$delete from public.ppomi_agent_memories$q$,'42501','direct delete denied');
select pg_temp.agent_error($q$update public.ppomi_agent_memories set envelope='{}'$q$,'42501','direct update denied');
select pg_temp.agent_error($q$insert into public.ppomi_agent_memories(workspace_id,id,created_by_device_id,envelope,request_digest) values ('97b00000-0000-4000-8000-000000000001','97d00000-0000-4000-8000-000000000003','97c00000-0000-4000-8000-000000000001','{}',repeat('a',64))$q$,'42501','direct insert denied');

select set_config('request.jwt.claim.sub','97a00000-0000-4000-8000-000000000002',true);
select pg_temp.agent_assert(jsonb_array_length(public.ppomi_agent_memory_list())=3,'other workspace member reads record');
select pg_temp.agent_assert(
    public.ppomi_agent_memory_save(
        '97d00000-0000-4000-8000-000000000002',
        pg_temp.agent_payload('97d00000-0000-4000-8000-000000000002', 'replacement', '97d00000-0000-4000-8000-000000000001'),
        '97d00000-0000-4000-8000-000000000001')->>'replaces_id'
    = '97d00000-0000-4000-8000-000000000001',
    'other member replacement preserves parent');
select pg_temp.agent_assert((select count(*) from public.ppomi_agent_memories)=4,'replacement retains history');
select pg_temp.agent_assert(
    public.ppomi_agent_memory_list()->0->>'id'='97d00000-0000-4000-8000-000000000002',
    'current list shows replacement');
select pg_temp.agent_error(
    $q$select public.ppomi_agent_memory_save(
        '97d00000-0000-4000-8000-000000000003',
        pg_temp.agent_payload('97d00000-0000-4000-8000-000000000003', 'fork', '97d00000-0000-4000-8000-000000000001'),
        '97d00000-0000-4000-8000-000000000001')$q$,
    'PT409','history cannot fork');

select set_config('request.jwt.claim.sub','97a00000-0000-4000-8000-000000000003',true);
select pg_temp.agent_assert(public.ppomi_agent_memory_list()='[]'::jsonb,'cross workspace list empty');
select pg_temp.agent_assert((select count(*) from public.ppomi_agent_memories)=0,'RLS hides other workspace ciphertext');
select pg_temp.agent_error($q$select public.ppomi_agent_memory_delete('97d00000-0000-4000-8000-000000000001')$q$,'PT404','cross workspace delete hidden');
select pg_temp.agent_error(
    $q$select public.ppomi_agent_memory_save(
        '97d00000-0000-4000-8000-000000000003',
        pg_temp.agent_payload('97d00000-0000-4000-8000-000000000003', 'x', '97d00000-0000-4000-8000-000000000001'),
        '97d00000-0000-4000-8000-000000000001')$q$,
    'PT404','cross workspace replacement hidden');

select set_config('request.jwt.claim.sub','97a00000-0000-4000-8000-000000000004',true);
select pg_temp.agent_error($q$select public.ppomi_agent_memory_list()$q$,'42501','non-member cannot list memories');
select pg_temp.agent_error($q$select public.ppomi_agent_memory_delete('97d00000-0000-4000-8000-000000000002')$q$,'42501','non-member delete denied');
select pg_temp.agent_error(
    $q$select public.ppomi_agent_memory_save(
        '97d00000-0000-4000-8000-000000000003',
        pg_temp.agent_payload('97d00000-0000-4000-8000-000000000003', 'x'))$q$,
    '42501','non-member save denied');

select set_config('request.jwt.claim.sub','97a00000-0000-4000-8000-000000000001',true);
select pg_temp.agent_assert(public.ppomi_agent_memory_delete('97d00000-0000-4000-8000-000000000002')->>'deleted'='true','delete confirmed');
select pg_temp.agent_assert(public.ppomi_agent_memory_delete('97d00000-0000-4000-8000-000000000002')->>'deleted'='true','delete retry idempotent');
select pg_temp.agent_assert(
    (select count(*) from public.ppomi_agent_memories where deleted_at is null)=2,
    'deleting replacement never resurrects parent');
select pg_temp.agent_assert((select count(*) from public.ppomi_agent_memories)=4,'delete preserves opaque tombstone identity');
select pg_temp.agent_assert(
    (select count(*) from public.ppomi_agent_memories
      where envelope='{}'::jsonb and deleted_at is not null)=2,
    'delete wipes selected record and ancestor ciphertext');
select pg_temp.agent_error(
    $q$select public.ppomi_agent_memory_save(
        '97d00000-0000-4000-8000-000000000002',
        pg_temp.agent_payload('97d00000-0000-4000-8000-000000000002', 'replacement', '97d00000-0000-4000-8000-000000000001'),
        '97d00000-0000-4000-8000-000000000001')$q$,
    'PT410','save retry cannot revive tombstone');

reset role;
set local role anon;
select pg_temp.agent_error($q$select public.ppomi_agent_memory_list()$q$,'42501','anon read denied');
select pg_temp.agent_error($q$select public.ppomi_agent_memory_delete('97d00000-0000-4000-8000-000000000002')$q$,'42501','anon delete denied');
reset role;
select pg_temp.agent_error($q$delete from public.ppomi_agent_memories where workspace_id='97b00000-0000-4000-8000-000000000001'$q$,'55000','history hard delete denied');
select pg_temp.agent_error($q$update public.ppomi_agent_memories set envelope='{}' where workspace_id='97b00000-0000-4000-8000-000000000001' and id='97d00000-0000-4000-8000-000000000001'$q$,'55000','history content immutable');
select pg_temp.agent_error($q$update public.ppomi_agent_memories set deleted_at=null where workspace_id='97b00000-0000-4000-8000-000000000001' and id='97d00000-0000-4000-8000-000000000002'$q$,'55000','tombstone cannot be undone');

-- Leftover GCM: list still returns the stored envelope for the one-shot
-- rewrap script. The agent handler no longer decrypts these rows.
insert into public.ppomi_agent_memories(workspace_id,id,created_by_device_id,envelope,request_digest)
values (
    '97b00000-0000-4000-8000-000000000001',
    '97d00000-0000-4000-8000-000000000010',
    '97c00000-0000-4000-8000-000000000001',
    pg_temp.agent_envelope(),
    repeat('d', 64));
set local role authenticated;
select set_config('request.jwt.claim.sub','97a00000-0000-4000-8000-000000000001',true);
select pg_temp.agent_assert(
    public.ppomi_agent_memory_list()->0 ? 'envelope'
    and not public.ppomi_agent_memory_list()->0 ? 'payload',
    'legacy GCM list row stays an envelope for the agent');
select pg_temp.agent_assert(
    public.ppomi_agent_memory_rewrap(
        '97d00000-0000-4000-8000-000000000010',
        pg_temp.agent_payload('97d00000-0000-4000-8000-000000000010', 'rewrapped'))
    ->'payload'->>'text' = 'rewrapped',
    'rewrap seals leftover GCM as at-rest');
select pg_temp.agent_assert(
    public.ppomi_agent_memory_list()->0->'payload'->>'text' = 'rewrapped'
    and not public.ppomi_agent_memory_list()->0 ? 'envelope',
    'list opens the rewrapped row');
select pg_temp.agent_assert(
    public.ppomi_agent_memory_rewrap(
        '97d00000-0000-4000-8000-000000000010',
        pg_temp.agent_payload('97d00000-0000-4000-8000-000000000010', 'rewrapped'))
    ->'payload'->>'text' = 'rewrapped',
    'rewrap of an at-rest row with the same payload is idempotent');
select pg_temp.agent_error(
    $q$select public.ppomi_agent_memory_rewrap(
        '97d00000-0000-4000-8000-000000000010',
        pg_temp.agent_payload('97d00000-0000-4000-8000-000000000010', 'other'))$q$,
    'PT409', 'rewrap cannot change at-rest contents');
reset role;
select pg_temp.agent_assert(
    not has_function_privilege('authenticated', 'public.ppomi_agent_memory_aad(uuid,uuid,uuid)', 'execute'),
    'clients cannot execute the memory AAD helper');
select pg_temp.agent_assert(
    not has_function_privilege('authenticated', 'public.ppomi_agent_memory_digest(uuid,uuid,uuid,jsonb)', 'execute'),
    'clients cannot execute the memory digest helper');
select pg_temp.agent_assert(
    not has_function_privilege('authenticated', 'public.ppomi_at_rest_seal(jsonb,text)', 'execute'),
    'clients cannot execute the at-rest seal helper');

select count(*) as passed from pg_temp.agent_test_results;
rollback;
