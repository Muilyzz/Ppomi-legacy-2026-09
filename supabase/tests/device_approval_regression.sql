-- Run as the migration owner using psql -v ON_ERROR_STOP=1 -f ... .
-- Every fixture and write rolls back. Auth users are synthetic isolated UUIDs.
-- Covers 20260911100000 + 20260911120000 (MZZ-27): Google login + membership auto-approves
-- Windows/web, ledger wrap is automatic (no Mac 승인 button), revoke still cuts access,
-- web devices remain read-only for native mutations.
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
-- PostgREST exposes request headers this way; the resolver picks the device from x-ppomi-device.
create function pg_temp.ppomi_as(p_user uuid, p_device uuid)
returns void language plpgsql as $$
begin
    perform set_config('request.jwt.claim.sub', p_user::text, true);
    perform set_config('request.headers', case when p_device is null then '' else json_build_object('x-ppomi-device', p_device::text)::text end, true);
end;
$$;

insert into auth.users(id) values ('97a00000-0000-4000-8000-000000000001'), ('97a00000-0000-4000-8000-000000000002');

set local role authenticated;
-- Fixed synthetic X25519 public keys (32 bytes, base64). No private key exists for them anywhere.
select pg_temp.ppomi_as('97a00000-0000-4000-8000-000000000001', null);
select pg_temp.ppomi_assert(
    (public.ppomi_register_device('97c00000-0000-4000-8000-000000000001', 'Mac', 'macos', 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=')->'device'->>'approved') = 'true',
    'founder device is approved on first registration');

-- Second device of the same person: Windows is a workspace member immediately (MZZ-27).
select pg_temp.ppomi_as('97a00000-0000-4000-8000-000000000001', '97c00000-0000-4000-8000-000000000002');
select pg_temp.ppomi_assert(
    (public.ppomi_register_device('97c00000-0000-4000-8000-000000000002', 'Windows', 'windows', 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=')->'device'->>'approved') = 'true',
    'windows platform registers as a workspace member');
select pg_temp.ppomi_assert((public.ppomi_context()->'device'->>'approved') = 'true', 'windows device reads its own approved state');
select pg_temp.ppomi_assert((public.ppomi_key_get()->>'found') = 'false', 'new device has no wrapped ledger key yet');
select pg_temp.ppomi_assert((public.ppomi_record_get('97e00000-0000-4000-8000-000000000001')->>'found') = 'false', 'windows device may read record heads without Mac approval');
select pg_temp.ppomi_assert(jsonb_array_length(public.ppomi_devices_pending()) = 0, 'membership registration leaves no pending-approval queue');
select pg_temp.ppomi_expect_error($q$select public.ppomi_device_approve('97c00000-0000-4000-8000-000000000002')$q$, '22023', 'a device cannot approve itself');
select pg_temp.ppomi_assert(jsonb_typeof(public.ppomi_list_documents()) = 'array', 'windows device can use native workspace RPCs');
select pg_temp.ppomi_expect_error($q$select public.ppomi_register_device('97c00000-0000-4000-8000-000000000002', 'Windows', 'linux', 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=')$q$, '22023', 'unknown platform rejected');

-- Key exchange is automatic: the Mac sees the new device as waiting, with no 승인 step.
select pg_temp.ppomi_as('97a00000-0000-4000-8000-000000000001', '97c00000-0000-4000-8000-000000000001');
select pg_temp.ppomi_assert(public.ppomi_devices_waiting() @> '[{"id":"97c00000-0000-4000-8000-000000000002"}]'::jsonb, 'new windows device waits for its wrapped key');
select pg_temp.ppomi_assert(jsonb_array_length(public.ppomi_devices_pending()) = 0, 'owner pending list is empty after membership auto-approve');
select pg_temp.ppomi_expect_error($q$select public.ppomi_device_approve('97c00000-0000-4000-8000-000000000001')$q$, '22023', 'a device cannot approve itself');
select pg_temp.ppomi_expect_error($q$select public.ppomi_device_approve('97c00000-0000-4000-8000-0000000000ff')$q$, 'P0002', 'unknown device cannot be approved');
select pg_temp.ppomi_assert(
    (public.ppomi_key_wrap_put('97c00000-0000-4000-8000-000000000002', '97f00000-0000-4000-8000-000000000001', '{"ledger":"97e00000-0000-4000-8000-000000000001"}',
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=')->>'device') = '97c00000-0000-4000-8000-000000000002',
    'key is wrapped for the windows device without a Mac approval tap');
select pg_temp.ppomi_assert(jsonb_array_length(public.ppomi_devices_waiting()) = 0, 'wrapped device is no longer waiting');
select pg_temp.ppomi_assert(public.ppomi_context()->'devices' @> '[{"id":"97c00000-0000-4000-8000-000000000002","approved":true}]'::jsonb, 'device list reports membership');

select pg_temp.ppomi_as('97a00000-0000-4000-8000-000000000001', '97c00000-0000-4000-8000-000000000002');
select pg_temp.ppomi_assert((public.ppomi_key_get()->>'found') = 'true' and (public.ppomi_key_get()->>'key_id') = '97f00000-0000-4000-8000-000000000001', 'windows device receives its wrapped key');
select pg_temp.ppomi_assert(
    (public.ppomi_register_device('97c00000-0000-4000-8000-000000000002', 'Windows', 'windows', 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=')->'device'->>'approved') = 'true',
    'cold start with the same key keeps membership');
select pg_temp.ppomi_assert((public.ppomi_key_get()->>'found') = 'true', 'cold start with the same key keeps the wrapped copy');

-- A browser is a read-only device: it registers as a member and still never approves or revokes.
select pg_temp.ppomi_as('97a00000-0000-4000-8000-000000000001', '97c00000-0000-4000-8000-000000000003');
select pg_temp.ppomi_assert(
    (public.ppomi_register_device('97c00000-0000-4000-8000-000000000003', '뽀미 웹 브라우저', 'web', 'AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=')->'device'->>'approved') = 'true',
    'web device registers as a workspace member');
select pg_temp.ppomi_expect_error($q$select public.ppomi_devices_pending()$q$, '42501', 'web device cannot list pending devices');
select pg_temp.ppomi_expect_error($q$select public.ppomi_device_approve('97c00000-0000-4000-8000-000000000002')$q$, '42501', 'web device cannot approve');
select pg_temp.ppomi_expect_error($q$select public.ppomi_device_revoke('97c00000-0000-4000-8000-000000000002')$q$, '42501', 'web device cannot revoke');

-- Revocation removes access and the wrapped copy; re-registration is a member again (no Mac tap).
select pg_temp.ppomi_as('97a00000-0000-4000-8000-000000000001', '97c00000-0000-4000-8000-000000000001');
select pg_temp.ppomi_expect_error($q$select public.ppomi_device_revoke('97c00000-0000-4000-8000-000000000001')$q$, '22023', 'a device cannot revoke itself');
select pg_temp.ppomi_assert((public.ppomi_device_revoke('97c00000-0000-4000-8000-000000000002')->'device'->>'revoked') = 'true', 'owner revokes the windows device');
select pg_temp.ppomi_expect_error($q$select public.ppomi_device_revoke('97c00000-0000-4000-8000-000000000002')$q$, 'P0002', 'revoking twice is reported');
select pg_temp.ppomi_as('97a00000-0000-4000-8000-000000000001', '97c00000-0000-4000-8000-000000000002');
select pg_temp.ppomi_expect_error($q$select public.ppomi_context()$q$, '42501', 'revoked device is no longer registered');
select pg_temp.ppomi_assert(
    (public.ppomi_register_device('97c00000-0000-4000-8000-000000000002', 'Windows', 'windows', 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=')->'device'->>'approved') = 'true',
    'revived device is a workspace member again');
select pg_temp.ppomi_assert((public.ppomi_key_get()->>'found') = 'false', 'revived device lost the old wrapped copy');

-- Another person: their first device founds their own workspace and is approved there, not in the first workspace.
select pg_temp.ppomi_as('97a00000-0000-4000-8000-000000000002', null);
select pg_temp.ppomi_assert(
    (public.ppomi_register_device('97c00000-0000-4000-8000-000000000011', 'iPad', 'ios', 'AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM=')->'device'->>'approved') = 'true',
    'another founder is approved in a separate workspace');
select pg_temp.ppomi_expect_error($q$select public.ppomi_device_approve('97c00000-0000-4000-8000-000000000002')$q$, 'P0002', 'a founder cannot approve devices of another workspace');

reset role;
select pg_temp.ppomi_assert((select count(*) from pg_temp.ppomi_test_results) = 32, 'all membership auto-approve checks recorded');
select format('PASS %s membership auto-approve checks (synthetic only, rolled back)', count(*)) from pg_temp.ppomi_test_results;
rollback;
