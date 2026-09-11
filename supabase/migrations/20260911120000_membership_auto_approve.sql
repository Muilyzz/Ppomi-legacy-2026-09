-- MZZ-27: Google 로그인 + 작업 공간 구성원이면 새 기기는 바로 연결된다. Mac 기기 승인은 온보딩 관문이 아니다.
-- 대화·에이전트·공유 작업·문서는 Auth + RLS(+ 서버 키). 장부 wrapped-key 는 키를 가진 기존 기기가
-- 자동으로 감싼다(승인 버튼 없이 ppomi_devices_waiting). 해지(revoke) 만 기기를 끊는다.
-- 20260911100000 이 남긴 대기 행은 여기서 승인으로 옮기고, 승인 검사도 구성원 기기로 되돌린다.

update public.ppomi_devices
    set approved_at = coalesce(approved_at, created_at)
    where revoked_at is null and approved_at is null;

-- 등록된(해지되지 않은) 구성원 기기면 충분하다. approved_at 은 등록 시각이며 로그인/대화/일반 RPC 를 막지 않는다.
create or replace function public.ppomi_private_approved_device()
returns public.ppomi_devices language plpgsql security definer set search_path = '' as $$
begin
    return public.ppomi_private_record_device();
end;
$$;
revoke all on function public.ppomi_private_approved_device() from public, anon, authenticated;

-- 등록·재등록 모두 즉시 승인. 해지 뒤 다시 오면 옛 감싼 사본은 지우고 새 기기로 받는다.
create or replace function public.ppomi_register_device(p_device_id uuid, p_label text, p_platform text, p_public_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_workspace uuid; v_device public.ppomi_devices; v_header text; v_request_id uuid; v_request_platform text;
begin
    if auth.uid() is null then
        raise exception using errcode = '42501', message = 'Authenticated user required';
    end if;
    if p_device_id is null or p_label is null or char_length(btrim(p_label)) not between 1 and 120
       or p_platform is null or p_platform not in ('macos', 'android', 'ios', 'web', 'windows')
       or p_public_key is null or p_public_key !~ '^[A-Za-z0-9+/]{43}=$' then
        raise exception using errcode = '22023', message = 'Invalid registration';
    end if;
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
        delete from public.ppomi_devices where id = p_device_id;
        v_device := null;
    end if;
    if v_device.id is not null then
        if v_device.revoked_at is not null then
            delete from public.ppomi_wrapped_keys where workspace_id = v_workspace and device_id = p_device_id;
            update public.ppomi_devices set revoked_at = null, label = btrim(p_label), public_key = p_public_key,
                approved_at = statement_timestamp(), approved_by_device_id = null where id = p_device_id returning * into v_device;
        else
            if v_device.public_key is distinct from p_public_key then
                delete from public.ppomi_wrapped_keys where workspace_id = v_workspace and device_id = p_device_id;
            end if;
            update public.ppomi_devices set label = btrim(p_label), public_key = p_public_key,
                approved_at = coalesce(approved_at, statement_timestamp())
              where id = p_device_id returning * into v_device;
        end if;
    else
        insert into public.ppomi_devices(id, workspace_id, auth_user_id, label, platform, public_key, approved_at)
          values (p_device_id, v_workspace, auth.uid(), btrim(p_label), p_platform, p_public_key, statement_timestamp())
          returning * into v_device;
    end if;
    return jsonb_build_object(
      'workspace', (select jsonb_build_object('id', id, 'name', name) from public.ppomi_workspaces where id = v_device.workspace_id),
      'device', jsonb_build_object('id', v_device.id, 'label', v_device.label, 'platform', v_device.platform,
                                   'approved', v_device.approved_at is not null));
end;
$$;

create or replace function public.ppomi_context()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices;
begin
    v_device := public.ppomi_private_record_device();
    return jsonb_build_object(
      'workspace', (select jsonb_build_object('id', id, 'name', name) from public.ppomi_workspaces where id = v_device.workspace_id),
      'device', jsonb_build_object('id', v_device.id, 'label', v_device.label, 'platform', v_device.platform,
                                   'approved', v_device.approved_at is not null),
      'devices', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'label', label, 'platform', platform, 'approved', approved_at is not null)
                                            order by created_at, id), '[]'::jsonb)
                  from public.ppomi_devices where workspace_id = v_device.workspace_id and revoked_at is null));
end;
$$;

-- 장부 키: 등록된 기기의 감싼 사본. 없으면 found:false (Mac 이 켜져 자동 교환할 때까지). 승인 여부로 숨기지 않는다.
create or replace function public.ppomi_key_get()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices; w public.ppomi_wrapped_keys;
begin
    v_device := public.ppomi_private_record_device();
    select * into w from public.ppomi_wrapped_keys where workspace_id = v_device.workspace_id and device_id = v_device.id;
    if not found then return jsonb_build_object('found', false); end if;
    return jsonb_build_object('found', true, 'workspace_id', w.workspace_id, 'key_id', w.key_id, 'records', w.records, 'wrapped', w.wrapped);
end;
$$;

create or replace function public.ppomi_devices_waiting()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices;
begin
    v_device := public.ppomi_private_device();
    return (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'label', d.label, 'platform', d.platform, 'public_key', d.public_key) order by d.created_at), '[]'::jsonb)
            from public.ppomi_devices d
            where d.workspace_id = v_device.workspace_id and d.revoked_at is null and d.public_key is not null and d.id <> v_device.id
              and not exists (select 1 from public.ppomi_wrapped_keys w where w.workspace_id = d.workspace_id and w.device_id = d.id));
end;
$$;

create or replace function public.ppomi_key_wrap_put(p_device_id uuid, p_key_id uuid, p_records jsonb, p_wrapped text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices;
begin
    v_device := public.ppomi_private_device();
    if p_device_id is null or p_key_id is null or p_records is null or jsonb_typeof(p_records) <> 'object'
       or p_wrapped is null or p_wrapped !~ '^[A-Za-z0-9+/]+={0,2}$' or length(p_wrapped) not between 60 and 400
       or exists (select 1 from jsonb_each_text(p_records) where value !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
        raise exception using errcode = '22023', message = 'Invalid wrapped key';
    end if;
    if not exists (select 1 from public.ppomi_devices where id = p_device_id and workspace_id = v_device.workspace_id
                   and revoked_at is null and public_key is not null) then
        raise exception using errcode = '42501', message = 'Target device not in workspace';
    end if;
    insert into public.ppomi_wrapped_keys(workspace_id, device_id, key_id, records, wrapped, wrapped_by_device_id)
      values (v_device.workspace_id, p_device_id, p_key_id, p_records, p_wrapped, v_device.id)
      on conflict (workspace_id, device_id) do update set key_id = excluded.key_id, records = excluded.records, wrapped = excluded.wrapped,
        wrapped_by_device_id = excluded.wrapped_by_device_id, updated_at = statement_timestamp();
    return jsonb_build_object('device', p_device_id, 'key_id', p_key_id);
end;
$$;

comment on column public.ppomi_devices.approved_at is
    'Set on registration (Google login + workspace membership). Null only for revoked or pre-MZZ-27 leftover rows; it does not gate login, chat or general RPCs. Ledger wrapped-key delivery is separate (ppomi_devices_waiting).';
comment on function public.ppomi_device_approve(uuid) is
    'Optional leftover admin: mark a device approved. New registrations already set approved_at.';
comment on function public.ppomi_device_revoke(uuid) is
    'Revoke a device and drop its wrapped record key. Re-registration auto-approves again (MZZ-27).';
