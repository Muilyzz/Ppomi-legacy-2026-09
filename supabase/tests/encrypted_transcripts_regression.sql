-- Run as the migration owner using psql -v ON_ERROR_STOP=1 -f ... .
-- Every fixture and write rolls back. Auth users are synthetic isolated UUIDs.
-- Covers 20260911120000_encrypted_transcripts.sql: approved web read/write,
-- pending/anonymous denial, append idempotency, tombstone wipe, workspace isolation.
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
create function pg_temp.ppomi_as(p_user uuid, p_device uuid)
returns void language plpgsql as $$
begin
    perform set_config('request.jwt.claim.sub', p_user::text, true);
    perform set_config('request.headers',
        case when p_device is null then ''
             else json_build_object('x-ppomi-device', p_device::text)::text end, true);
end;
$$;

insert into auth.users(id) values
 ('96a00000-0000-4000-8000-000000000001'),
 ('96a00000-0000-4000-8000-000000000002'),
 ('96a00000-0000-4000-8000-000000000003'),
 ('96a00000-0000-4000-8000-000000000004');
insert into public.ppomi_workspaces(id, name) values
 ('96b00000-0000-4000-8000-000000000001', 'Synthetic transcript A'),
 ('96b00000-0000-4000-8000-000000000002', 'Synthetic transcript B');
insert into public.ppomi_devices(id, workspace_id, auth_user_id, label, platform, revoked_at, approved_at) values
 ('96c00000-0000-4000-8000-000000000001', '96b00000-0000-4000-8000-000000000001',
  '96a00000-0000-4000-8000-000000000001', 'Synthetic Mac', 'macos', null, statement_timestamp()),
 ('96c00000-0000-4000-8000-000000000002', '96b00000-0000-4000-8000-000000000001',
  '96a00000-0000-4000-8000-000000000002', 'Synthetic Web', 'web', null, statement_timestamp()),
 ('96c00000-0000-4000-8000-000000000003', '96b00000-0000-4000-8000-000000000002',
  '96a00000-0000-4000-8000-000000000003', 'Other workspace', 'macos', null, statement_timestamp()),
 ('96c00000-0000-4000-8000-000000000004', '96b00000-0000-4000-8000-000000000001',
  '96a00000-0000-4000-8000-000000000004', 'Pending web', 'web', null, null);
insert into public.ppomi_wrapped_keys(workspace_id, device_id, key_id, records, wrapped, wrapped_by_device_id) values
 ('96b00000-0000-4000-8000-000000000001', '96c00000-0000-4000-8000-000000000001',
  '96f00000-0000-4000-8000-000000000001', '{"ledger":"96e00000-0000-4000-8000-000000000001"}',
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  '96c00000-0000-4000-8000-000000000001'),
 ('96b00000-0000-4000-8000-000000000001', '96c00000-0000-4000-8000-000000000002',
  '96f00000-0000-4000-8000-000000000001', '{"ledger":"96e00000-0000-4000-8000-000000000001"}',
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  '96c00000-0000-4000-8000-000000000001'),
 ('96b00000-0000-4000-8000-000000000002', '96c00000-0000-4000-8000-000000000003',
  '96f00000-0000-4000-8000-000000000002', '{"ledger":"96e00000-0000-4000-8000-000000000002"}',
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  '96c00000-0000-4000-8000-000000000003');

-- Valid AES-GCM envelope shape (ciphertext is opaque; server never decrypts).
create function pg_temp.ppomi_envelope()
returns jsonb language sql as $$
    select '{"version":1,"nonce":"AAAAAAAAAAAA","tag":"AAAAAAAAAAAAAAAAAAAAAA","ciphertext":"dGVzdA"}'::jsonb;
$$;

set local role authenticated;
select pg_temp.ppomi_as('96a00000-0000-4000-8000-000000000001', '96c00000-0000-4000-8000-000000000001');
select pg_temp.ppomi_assert(
    (public.ppomi_transcript_open('96d00000-0000-4000-8000-000000000001', '96f00000-0000-4000-8000-000000000001')->>'id')
      = '96d00000-0000-4000-8000-000000000001',
    'approved native device can open a transcript');
select pg_temp.ppomi_assert(
    (public.ppomi_transcript_open('96d00000-0000-4000-8000-000000000099', '96f00000-0000-4000-8000-000000000001')->>'id')
      = '96d00000-0000-4000-8000-000000000001',
    'open returns the existing live transcript instead of forking');
select pg_temp.ppomi_assert(
    (public.ppomi_transcript_append(
        '96d00000-0000-4000-8000-000000000001',
        '96e00000-0000-4000-8000-000000000001',
        '96f00000-0000-4000-8000-000000000001',
        pg_temp.ppomi_envelope())->>'seq') = '1',
    'first encrypted turn is seq 1');
select pg_temp.ppomi_assert(
    (public.ppomi_transcript_append(
        '96d00000-0000-4000-8000-000000000001',
        '96e00000-0000-4000-8000-000000000001',
        '96f00000-0000-4000-8000-000000000001',
        pg_temp.ppomi_envelope())->>'seq') = '1',
    'turn retry is idempotent');
select pg_temp.ppomi_expect_error(
    $q$select public.ppomi_transcript_append(
        '96d00000-0000-4000-8000-000000000001',
        '96e00000-0000-4000-8000-000000000001',
        '96f00000-0000-4000-8000-000000000001',
        '{"version":1,"nonce":"BBBBBBBBBBBB","tag":"AAAAAAAAAAAAAAAAAAAAAA","ciphertext":"dGVzdA"}'::jsonb)$q$,
    '22023', 'same turn id cannot change ciphertext');
select pg_temp.ppomi_assert(
    (public.ppomi_transcript_append(
        '96d00000-0000-4000-8000-000000000001',
        '96e00000-0000-4000-8000-000000000002',
        '96f00000-0000-4000-8000-000000000001',
        pg_temp.ppomi_envelope())->>'seq') = '2',
    'second turn advances seq');
select pg_temp.ppomi_assert(
    jsonb_array_length(public.ppomi_transcript_turns('96d00000-0000-4000-8000-000000000001')->'turns') = 2,
    'list returns both ciphertext turns');
select pg_temp.ppomi_assert(
    jsonb_array_length(public.ppomi_transcript_turns('96d00000-0000-4000-8000-000000000001', 1)->'turns') = 1,
    'list after seq skips earlier turns');
select pg_temp.ppomi_assert(
    (public.ppomi_transcript_turns('96d00000-0000-4000-8000-000000000001')->'turns'->0->>'envelope')
      not like '%hello%' and
    (public.ppomi_transcript_turns('96d00000-0000-4000-8000-000000000001')->'turns'->0->'envelope' ? 'ciphertext'),
    'listed turns expose envelope ciphertext only');
select pg_temp.ppomi_expect_error(
    $q$select public.ppomi_transcript_append(
        '96d00000-0000-4000-8000-000000000001',
        '96e00000-0000-4000-8000-000000000003',
        '96f00000-0000-4000-8000-000000000001',
        '{"version":1,"nonce":"AAA","tag":"AAAAAAAAAAAAAAAAAAAAAA","ciphertext":"dGVzdA"}'::jsonb)$q$,
    '22023', 'invalid envelope rejected');
select pg_temp.ppomi_expect_error(
    $q$select public.ppomi_transcript_open(
        '96d00000-0000-4000-8000-000000000002',
        '96f00000-0000-4000-8000-000000000099')$q$,
    '42501', 'unknown key id cannot open');
select pg_temp.ppomi_expect_error($q$insert into public.ppomi_transcripts
    (workspace_id, id, created_by_device_id, key_id)
    values ('96b00000-0000-4000-8000-000000000001',
            '96d00000-0000-4000-8000-0000000000aa',
            '96c00000-0000-4000-8000-000000000001',
            '96f00000-0000-4000-8000-000000000001')$q$,
    '42501', 'direct transcript insert denied');
select pg_temp.ppomi_expect_error($q$delete from public.ppomi_transcript_turns$q$,
    '42501', 'direct turn delete denied');

-- Approved web devices may read and write (exception vs record writer lock).
select pg_temp.ppomi_as('96a00000-0000-4000-8000-000000000002', '96c00000-0000-4000-8000-000000000002');
select pg_temp.ppomi_assert(
    (public.ppomi_transcript_turns('96d00000-0000-4000-8000-000000000001')->>'found') = 'true',
    'approved web device may read ciphertext turns');
select pg_temp.ppomi_assert(
    (public.ppomi_transcript_append(
        '96d00000-0000-4000-8000-000000000001',
        '96e00000-0000-4000-8000-000000000010',
        '96f00000-0000-4000-8000-000000000001',
        pg_temp.ppomi_envelope())->>'seq') = '3',
    'approved web device may append a turn');
select pg_temp.ppomi_assert(
    jsonb_array_length(public.ppomi_transcript_list()) = 1,
    'approved web device may list live transcripts');

-- Pending web cannot read or write.
select pg_temp.ppomi_as('96a00000-0000-4000-8000-000000000004', '96c00000-0000-4000-8000-000000000004');
select pg_temp.ppomi_expect_error(
    $q$select public.ppomi_transcript_turns('96d00000-0000-4000-8000-000000000001')$q$,
    '42501', 'pending device cannot read turns');
select pg_temp.ppomi_expect_error(
    $q$select public.ppomi_transcript_append(
        '96d00000-0000-4000-8000-000000000001',
        '96e00000-0000-4000-8000-000000000011',
        '96f00000-0000-4000-8000-000000000001',
        pg_temp.ppomi_envelope())$q$,
    '42501', 'pending device cannot append');
select pg_temp.ppomi_assert((select count(*) from public.ppomi_transcripts) = 0,
    'pending device RLS hides transcript heads');
select pg_temp.ppomi_assert((select count(*) from public.ppomi_transcript_turns) = 0,
    'pending device RLS hides transcript turns');

-- Cross-workspace isolation.
select pg_temp.ppomi_as('96a00000-0000-4000-8000-000000000003', '96c00000-0000-4000-8000-000000000003');
select pg_temp.ppomi_assert(
    (public.ppomi_transcript_turns('96d00000-0000-4000-8000-000000000001')->>'found') = 'false',
    'cross workspace transcript hidden');
select pg_temp.ppomi_assert(jsonb_array_length(public.ppomi_transcript_list()) = 0,
    'cross workspace list is empty');
select pg_temp.ppomi_assert((select count(*) from public.ppomi_transcripts) = 0,
    'transcript RLS isolates workspaces');
select pg_temp.ppomi_assert((select count(*) from public.ppomi_transcript_turns) = 0,
    'turn RLS isolates workspaces');

-- Tombstone wipes ciphertext and hides the conversation.
select pg_temp.ppomi_as('96a00000-0000-4000-8000-000000000002', '96c00000-0000-4000-8000-000000000002');
select pg_temp.ppomi_assert((public.ppomi_transcript_delete('96d00000-0000-4000-8000-000000000001')->>'deleted') = 'true',
    'approved web device may tombstone');
select pg_temp.ppomi_assert((public.ppomi_transcript_delete('96d00000-0000-4000-8000-000000000001')->>'deleted') = 'true',
    'tombstone retry is idempotent');
select pg_temp.ppomi_assert(jsonb_array_length(public.ppomi_transcript_list()) = 0,
    'tombstoned transcript leaves the list');
select pg_temp.ppomi_assert(
    (public.ppomi_transcript_turns('96d00000-0000-4000-8000-000000000001')->>'found') = 'false',
    'tombstoned transcript turns are hidden');
select pg_temp.ppomi_assert(
    (select bool_and(envelope = '{}'::jsonb) from public.ppomi_transcript_turns
      where transcript_id = '96d00000-0000-4000-8000-000000000001'),
    'tombstone clears turn ciphertext');
select pg_temp.ppomi_expect_error(
    $q$select public.ppomi_transcript_append(
        '96d00000-0000-4000-8000-000000000001',
        '96e00000-0000-4000-8000-000000000020',
        '96f00000-0000-4000-8000-000000000001',
        pg_temp.ppomi_envelope())$q$,
    'PT410', 'cannot append to a tombstoned transcript');
select pg_temp.ppomi_expect_error(
    $q$select public.ppomi_transcript_open(
        '96d00000-0000-4000-8000-000000000001',
        '96f00000-0000-4000-8000-000000000001')$q$,
    'PT410', 'open refuses a tombstoned id when no live transcript remains');

reset role;
set local role anon;
select pg_temp.ppomi_expect_error(
    $q$select public.ppomi_transcript_list()$q$,
    '42501', 'anonymous RPC denied');
reset role;
select pg_temp.ppomi_expect_error($q$delete from public.ppomi_transcripts$q$,
    '55000', 'transcript history immutable even for owner');
select pg_temp.ppomi_expect_error($q$delete from public.ppomi_transcript_turns$q$,
    '55000', 'turn history immutable even for owner');
select pg_temp.ppomi_assert(
    not exists (
        select 1 from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname like 'ppomi_transcript%'
          and has_function_privilege('anon', p.oid, 'execute')),
    'anon cannot execute transcript RPCs');

select count(*) as passed from pg_temp.ppomi_test_results;
rollback;
