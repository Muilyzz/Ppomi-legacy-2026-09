-- Run as the migration owner using psql -v ON_ERROR_STOP=1 -f ... .
-- Every fixture and write rolls back. Auth users are synthetic isolated UUIDs.
-- Covers 20260911100000_device_approval.sql: founder auto-approval, pending devices, owner approval/revocation,
-- key wrapping gated by approval, the Windows platform, and web devices that cannot approve anything.
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
-- Founder: the first device of a new workspace approves itself.
select pg_temp.ppomi_as('97a00000-0000-4000-8000-000000000001', null);
select pg_temp.ppomi_assert(
    (public.ppomi_register_device('97c00000-0000-4000-8000-000000000001', 'Mac', 'macos', 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=')->'device'->>'approved') = 'true',
    'founder device is approved on first registration');

-- Second device of the same person: Windows registers as pending.
select pg_temp.ppomi_as('97a00000-0000-4000-8000-000000000001', '97c00000-0000-4000-8000-000000000002');
select pg_temp.ppomi_assert(
    (public.ppomi_register_device('97c00000-0000-4000-8000-000000000002', 'Windows', 'windows', 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=')->'device'->>'approved') = 'false',
    'windows platform registers as pending');
select pg_temp.ppomi_assert((public.ppomi_context()->'device'->>'approved') = 'false', 'pending device reads its own unapproved state');
select pg_temp.ppomi_assert((public.ppomi_key_get()->>'found') = 'false', 'pending device has no wrapped key');
select pg_temp.ppomi_expect_error($q$select public.ppomi_record_get('97e00000-0000-4000-8000-000000000001')$q$, '42501', 'pending device cannot read record heads');
select pg_temp.ppomi_expect_error($q$select public.ppomi_devices_pending()$q$, '42501', 'pending device cannot list pending devices');
select pg_temp.ppomi_expect_error($q$select public.ppomi_device_approve('97c00000-0000-4000-8000-000000000002')$q$, '42501', 'pending device cannot approve itself');
select pg_temp.ppomi_expect_error($q$select public.ppomi_list_documents()$q$, '42501', 'pending device cannot use native workspace RPCs');
select pg_temp.ppomi_expect_error($q$select public.ppomi_register_device('97c00000-0000-4000-8000-000000000002', 'Windows', 'linux', 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=')$q$, '22023', 'unknown platform rejected');

-- The approved Mac sees the pending device, but the key exchange skips it until approval.
select pg_temp.ppomi_as('97a00000-0000-4000-8000-000000000001', '97c00000-0000-4000-8000-000000000001');
select pg_temp.ppomi_assert(jsonb_array_length(public.ppomi_devices_waiting()) = 0, 'unapproved device is not waiting for a key');
select pg_temp.ppomi_assert(public.ppomi_devices_pending() @> '[{"id":"97c00000-0000-4000-8000-000000000002","platform":"windows"}]'::jsonb, 'owner device lists the pending device');
select pg_temp.ppomi_assert(not (public.ppomi_devices_pending()::text like '%public_key%'), 'pending list carries no key material');
select pg_temp.ppomi_expect_error(
    $q$select public.ppomi_key_wrap_put('97c00000-0000-4000-8000-000000000002', '97f00000-0000-4000-8000-000000000001', '{"ledger":"97e00000-0000-4000-8000-000000000001"}',
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=')$q$,
    '42501', 'key cannot be wrapped for an unapproved device');
select pg_temp.ppomi_expect_error($q$select public.ppomi_device_approve('97c00000-0000-4000-8000-000000000001')$q$, '22023', 'a device cannot approve itself');
select pg_temp.ppomi_expect_error($q$select public.ppomi_device_approve('97c00000-0000-4000-8000-0000000000ff')$q$, 'P0002', 'unknown device cannot be approved');

-- Approval opens the key exchange and the device's access.
select pg_temp.ppomi_assert((public.ppomi_device_approve('97c00000-0000-4000-8000-000000000002')->'device'->>'approved') = 'true', 'owner approves the pending device');
select pg_temp.ppomi_assert((public.ppomi_device_approve('97c00000-0000-4000-8000-000000000002')->'device'->>'approved') = 'true', 'approval retry is idempotent');
select pg_temp.ppomi_assert(jsonb_array_length(public.ppomi_devices_pending()) = 0, 'approved device leaves the pending list');
select pg_temp.ppomi_assert(public.ppomi_devices_waiting() @> '[{"id":"97c00000-0000-4000-8000-000000000002"}]'::jsonb, 'approved device now waits for its wrapped key');
select pg_temp.ppomi_assert(
    (public.ppomi_key_wrap_put('97c00000-0000-4000-8000-000000000002', '97f00000-0000-4000-8000-000000000001', '{"ledger":"97e00000-0000-4000-8000-000000000001"}',
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=')->>'device') = '97c00000-0000-4000-8000-000000000002',
    'key is wrapped for the approved device');
select pg_temp.ppomi_assert(jsonb_array_length(public.ppomi_devices_waiting()) = 0, 'wrapped device is no longer waiting');
select pg_temp.ppomi_assert(public.ppomi_context()->'devices' @> '[{"id":"97c00000-0000-4000-8000-000000000002","approved":true}]'::jsonb, 'device list reports approval');

select pg_temp.ppomi_as('97a00000-0000-4000-8000-000000000001', '97c00000-0000-4000-8000-000000000002');
select pg_temp.ppomi_assert((public.ppomi_context()->'device'->>'approved') = 'true', 'approved device reads its approved state');
select pg_temp.ppomi_assert((public.ppomi_key_get()->>'found') = 'true' and (public.ppomi_key_get()->>'key_id') = '97f00000-0000-4000-8000-000000000001', 'approved device receives its wrapped key');
select pg_temp.ppomi_assert((public.ppomi_record_get('97e00000-0000-4000-8000-000000000001')->>'found') = 'false', 'approved device may read record heads');
select pg_temp.ppomi_assert(
    (public.ppomi_register_device('97c00000-0000-4000-8000-000000000002', 'Windows', 'windows', 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=')->'device'->>'approved') = 'true',
    'cold start with the same key keeps approval');
select pg_temp.ppomi_assert((public.ppomi_key_get()->>'found') = 'true', 'cold start with the same key keeps the wrapped copy');

-- A browser is a read-only device: it registers pending and, even once approved, never approves or revokes.
select pg_temp.ppomi_as('97a00000-0000-4000-8000-000000000001', '97c00000-0000-4000-8000-000000000003');
select pg_temp.ppomi_assert(
    (public.ppomi_register_device('97c00000-0000-4000-8000-000000000003', '뽀미 웹 브라우저', 'web', 'AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=')->'device'->>'approved') = 'false',
    'web device registers as pending');
select pg_temp.ppomi_as('97a00000-0000-4000-8000-000000000001', '97c00000-0000-4000-8000-000000000001');
select pg_temp.ppomi_assert((public.ppomi_device_approve('97c00000-0000-4000-8000-000000000003')->'device'->>'approved') = 'true', 'owner approves the web device');
select pg_temp.ppomi_as('97a00000-0000-4000-8000-000000000001', '97c00000-0000-4000-8000-000000000003');
select pg_temp.ppomi_expect_error($q$select public.ppomi_devices_pending()$q$, '42501', 'web device cannot list pending devices');
select pg_temp.ppomi_expect_error($q$select public.ppomi_device_approve('97c00000-0000-4000-8000-000000000002')$q$, '42501', 'web device cannot approve');
select pg_temp.ppomi_expect_error($q$select public.ppomi_device_revoke('97c00000-0000-4000-8000-000000000002')$q$, '42501', 'web device cannot revoke');

-- Revocation removes access and the wrapped copy; re-registration starts over as pending.
select pg_temp.ppomi_as('97a00000-0000-4000-8000-000000000001', '97c00000-0000-4000-8000-000000000001');
select pg_temp.ppomi_expect_error($q$select public.ppomi_device_revoke('97c00000-0000-4000-8000-000000000001')$q$, '22023', 'a device cannot revoke itself');
select pg_temp.ppomi_assert((public.ppomi_device_revoke('97c00000-0000-4000-8000-000000000002')->'device'->>'revoked') = 'true', 'owner revokes the windows device');
select pg_temp.ppomi_expect_error($q$select public.ppomi_device_revoke('97c00000-0000-4000-8000-000000000002')$q$, 'P0002', 'revoking twice is reported');
select pg_temp.ppomi_as('97a00000-0000-4000-8000-000000000001', '97c00000-0000-4000-8000-000000000002');
select pg_temp.ppomi_expect_error($q$select public.ppomi_context()$q$, '42501', 'revoked device is no longer registered');
select pg_temp.ppomi_assert(
    (public.ppomi_register_device('97c00000-0000-4000-8000-000000000002', 'Windows', 'windows', 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=')->'device'->>'approved') = 'false',
    'revived device waits for approval again');
select pg_temp.ppomi_assert((public.ppomi_key_get()->>'found') = 'false', 'revived device lost the old wrapped copy');

-- Another person: their first device founds their own workspace and is approved there, not in the first workspace.
select pg_temp.ppomi_as('97a00000-0000-4000-8000-000000000002', null);
select pg_temp.ppomi_assert(
    (public.ppomi_register_device('97c00000-0000-4000-8000-000000000011', 'iPad', 'ios', 'AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM=')->'device'->>'approved') = 'true',
    'another founder is approved in a separate workspace');
select pg_temp.ppomi_expect_error($q$select public.ppomi_device_approve('97c00000-0000-4000-8000-000000000002')$q$, 'P0002', 'a founder cannot approve devices of another workspace');

reset role;
select pg_temp.ppomi_assert((select count(*) from pg_temp.ppomi_test_results) = 40, 'all device approval checks recorded');
select format('PASS %s device approval checks (synthetic only, rolled back)', count(*)) from pg_temp.ppomi_test_results;
rollback;
