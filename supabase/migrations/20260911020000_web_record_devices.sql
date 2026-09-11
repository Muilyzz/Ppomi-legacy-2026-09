-- Browser records are read-only. Keep the native RPC contracts, workspace
-- ownership, RLS policies and table grants unchanged.
-- This is a device-platform gate, not proof of device possession: the existing
-- account JWT plus X-Ppomi-Device protocol remains the authentication boundary.
-- A separate enrollment/possession protocol is needed to constrain a stolen
-- account token across arbitrary HTTP clients.

alter table public.ppomi_devices drop constraint ppomi_devices_platform_check;
alter table public.ppomi_devices add constraint ppomi_devices_platform_check
    check (platform in ('macos', 'android', 'ios', 'web'));

-- Preserve the existing account/header/revocation resolver for the four read
-- RPCs. Do not expose this SECURITY DEFINER helper through PostgREST.
CREATE OR REPLACE FUNCTION public.ppomi_private_record_device()
 RETURNS public.ppomi_devices
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_device public.ppomi_devices; v_header text; v_id uuid; v_count int;
begin
    if auth.uid() is null then
        raise exception using errcode = '42501', message = 'Authenticated device required';
    end if;
    v_header := nullif(current_setting('request.headers', true), '')::json ->> 'x-ppomi-device';
    if v_header is not null then
        begin v_id := v_header::uuid;
        exception when others then raise exception using errcode = '42501', message = 'Device header invalid'; end;
        select * into v_device from public.ppomi_devices
          where id = v_id and auth_user_id = auth.uid() and revoked_at is null for share;
    else
        select count(*) into v_count from public.ppomi_devices where auth_user_id = auth.uid() and revoked_at is null;
        if v_count > 1 then
            raise exception using errcode = '42501', message = 'Device header required';
        end if;
        select * into v_device from public.ppomi_devices
          where auth_user_id = auth.uid() and revoked_at is null for share;
    end if;
    if not found then
        raise exception using errcode = '42501', message = 'Active registered device required';
    end if;
    return v_device;
end;
$function$;

revoke all on function public.ppomi_private_record_device() from public, anon, authenticated;

-- Every existing mutation, membership/key-sharing RPC and table SELECT policy
-- continues through the native-only helper. Newly added RPCs default to this gate.
create or replace function public.ppomi_private_device()
returns public.ppomi_devices language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices;
begin
    v_device := public.ppomi_private_record_device();
    if v_device.platform = 'web' then
        raise exception using errcode = '42501', message = 'Web devices may only read shared records';
    end if;
    return v_device;
end;
$$;

-- Read responses and workspace filters are unchanged.
CREATE OR REPLACE FUNCTION public.ppomi_context()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_device public.ppomi_devices;
begin
    v_device := public.ppomi_private_record_device();
    return jsonb_build_object(
      'workspace', (select jsonb_build_object('id', id, 'name', name) from public.ppomi_workspaces where id = v_device.workspace_id),
      'device', jsonb_build_object('id', v_device.id, 'label', v_device.label, 'platform', v_device.platform),
      'devices', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'label', label, 'platform', platform) order by created_at, id), '[]'::jsonb)
                  from public.ppomi_devices where workspace_id = v_device.workspace_id and revoked_at is null));
end;
$function$;

CREATE OR REPLACE FUNCTION public.ppomi_key_get()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_device public.ppomi_devices; w public.ppomi_wrapped_keys;
begin
    v_device := public.ppomi_private_record_device();
    select * into w from public.ppomi_wrapped_keys where workspace_id = v_device.workspace_id and device_id = v_device.id;
    if not found then return jsonb_build_object('found', false); end if;
    return jsonb_build_object('found', true, 'workspace_id', w.workspace_id, 'key_id', w.key_id, 'records', w.records, 'wrapped', w.wrapped);
end;
$function$;

CREATE OR REPLACE FUNCTION public.ppomi_record_get(p_record_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare d public.ppomi_devices; h public.ppomi_record_heads;
begin
 d:=public.ppomi_private_record_device();
 select * into h from public.ppomi_record_heads where workspace_id=d.workspace_id and record_id=p_record_id;
 if not found then return jsonb_build_object('found',false); end if;
 return to_jsonb(h)||jsonb_build_object('found',true);
end; $function$;

CREATE OR REPLACE FUNCTION public.ppomi_record_blob_get(p_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare d public.ppomi_devices; b public.ppomi_record_blobs;
begin
 d:=public.ppomi_private_record_device();
 select * into b from public.ppomi_record_blobs where workspace_id=d.workspace_id and hash=p_hash;
 if not found then raise exception using errcode='P0002',message='Encrypted blob unavailable'; end if;
 return jsonb_build_object('hash',b.hash,'size',b.size,'data',b.data);
end; $function$;

-- Registration keeps the same four arguments and response shape.
CREATE OR REPLACE FUNCTION public.ppomi_register_device(p_device_id uuid, p_label text, p_platform text, p_public_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_workspace uuid; v_device public.ppomi_devices; v_header text; v_request_id uuid; v_request_platform text;
begin
    if auth.uid() is null then
        raise exception using errcode = '42501', message = 'Authenticated user required';
    end if;
    if p_device_id is null or p_label is null or char_length(btrim(p_label)) not between 1 and 120
       or p_platform is null or p_platform not in ('macos', 'android', 'ios', 'web')
       or p_public_key is null or p_public_key !~ '^[A-Za-z0-9+/]{43}=$' then
        raise exception using errcode = '22023', message = 'Invalid registration';
    end if;
    -- A registered browser can refresh only its own enrollment. Native clients
    -- retain their existing registration behavior, including headerless setup.
    v_header := nullif(current_setting('request.headers', true), '')::json ->> 'x-ppomi-device';
    if v_header is not null then
        begin v_request_id := v_header::uuid;
        exception when others then raise exception using errcode = '42501', message = 'Device header invalid'; end;
        select platform into v_request_platform from public.ppomi_devices
          where id = v_request_id and auth_user_id = auth.uid();
        if v_request_platform = 'web' and (p_device_id <> v_request_id or p_platform <> 'web') then
            raise exception using errcode = '42501', message = 'Web enrollment cannot change device permissions';
        end if;
    end if;
    -- Serialize retries for one device, including its first registration.
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('ppomi-register:' || p_device_id::text, 0));
    select workspace_id into v_workspace from public.ppomi_members where auth_user_id = auth.uid();
    if v_workspace is null then
        select workspace_id into v_workspace from public.ppomi_devices
          where auth_user_id = auth.uid() and revoked_at is null order by created_at limit 1;
    end if;
    if v_workspace is null then
        insert into public.ppomi_workspaces(name) values ('뽀미') returning id into v_workspace;
        insert into public.ppomi_members(workspace_id, auth_user_id) values (v_workspace, auth.uid());
    end if;
    select * into v_device from public.ppomi_devices where id = p_device_id for update;
    if found and v_device.auth_user_id <> auth.uid() then
        raise exception using errcode = '42501', message = 'Device belongs elsewhere';
    end if;
    if v_device.id is not null and ((v_device.platform = 'web') <> (p_platform = 'web')) then
        raise exception using errcode = '42501', message = 'Device platform permissions are immutable';
    end if;
    if v_device.id is not null and v_device.workspace_id <> v_workspace then
        delete from public.ppomi_devices where id = p_device_id;   -- 구성원 자리가 옮겨졌다: 참조 없는 기기 행만 따라간다
        v_device := null;
    end if;
    if v_device.id is not null then
        -- A cold launch with the same key must retain the already wrapped key.
        -- Only a changed public key invalidates the old recipient ciphertext.
        if v_device.public_key is distinct from p_public_key then
            delete from public.ppomi_wrapped_keys where workspace_id = v_workspace and device_id = p_device_id;
        end if;
        update public.ppomi_devices set revoked_at = null, label = btrim(p_label), public_key = p_public_key where id = p_device_id returning * into v_device;
    else
        insert into public.ppomi_devices(id, workspace_id, auth_user_id, label, platform, public_key)
          values (p_device_id, v_workspace, auth.uid(), btrim(p_label), p_platform, p_public_key) returning * into v_device;
    end if;
    return jsonb_build_object(
      'workspace', (select jsonb_build_object('id', id, 'name', name) from public.ppomi_workspaces where id = v_device.workspace_id),
      'device', jsonb_build_object('id', v_device.id, 'label', v_device.label, 'platform', v_device.platform));
end;
$function$;
