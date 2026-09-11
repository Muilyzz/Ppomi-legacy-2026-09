-- 새 기기는 '승인 대기'로 등록된다. 기록 키는 소유자가 이미 승인된 기기(Mac)에서 승인한 기기에게만 감싸 준다.
-- 이전에는 구글 계정으로 로그인해 공개키만 올리면 Mac 이 1분 안에 자동으로 키를 감싸 주었다(승인 없음). 그 경로를 닫는다.
-- 승인 전 기기가 할 수 있는 것: 자기 등록 갱신(ppomi_register_device) · 자기 상태 확인(ppomi_context) · 감싼 키 확인(ppomi_key_get → found:false).
-- 기존 기기(이 마이그레이션 이전에 등록된 Mac·iPad·웹)는 모두 승인된 것으로 옮긴다. Windows 실행기가 기기 플랫폼으로 들어온다.
alter table public.ppomi_devices add column approved_at timestamptz;
alter table public.ppomi_devices add column approved_by_device_id uuid;
alter table public.ppomi_devices add constraint ppomi_devices_approved_by_fkey
    foreign key (workspace_id, approved_by_device_id) references public.ppomi_devices(workspace_id, id) on delete set null;
update public.ppomi_devices set approved_at = created_at where approved_at is null;

alter table public.ppomi_devices drop constraint ppomi_devices_platform_check;
alter table public.ppomi_devices add constraint ppomi_devices_platform_check
    check (platform in ('macos', 'android', 'ios', 'web', 'windows'));

-- 승인된 기기만 통과하는 해석기. 읽기 RPC 와 네이티브 변경 RPC 가 이것을 쓴다. PostgREST 로 노출하지 않는다.
create function public.ppomi_private_approved_device()
returns public.ppomi_devices language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices;
begin
    v_device := public.ppomi_private_record_device();
    if v_device.approved_at is null then
        raise exception using errcode = '42501', message = 'Device approval required';
    end if;
    return v_device;
end;
$$;
revoke all on function public.ppomi_private_approved_device() from public, anon, authenticated;

-- 네이티브 변경·구성원·키 공유 RPC 의 공통 관문: 승인된 네이티브 기기.
create or replace function public.ppomi_private_device()
returns public.ppomi_devices language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices;
begin
    v_device := public.ppomi_private_approved_device();
    if v_device.platform = 'web' then
        raise exception using errcode = '42501', message = 'Web devices may only read shared records';
    end if;
    return v_device;
end;
$$;

-- 등록: 인자·응답 모양은 그대로이고 device 에 approved 가 붙는다. 첫 기기(새 작업 공간을 만든 기기)만 스스로 승인된다.
-- 되살린 기기(거절·해지 뒤 재등록)는 다시 승인 대기이며 옛 감싼 사본은 지운다.
create or replace function public.ppomi_register_device(p_device_id uuid, p_label text, p_platform text, p_public_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_workspace uuid; v_device public.ppomi_devices; v_header text; v_request_id uuid; v_request_platform text; v_founder boolean := false;
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
        v_founder := true;
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
        if v_device.revoked_at is not null then
            -- 해지된 기기의 재등록은 새 기기와 같다: 승인을 다시 받고, 옛 사본은 못 쓰게 한다.
            delete from public.ppomi_wrapped_keys where workspace_id = v_workspace and device_id = p_device_id;
            update public.ppomi_devices set revoked_at = null, label = btrim(p_label), public_key = p_public_key,
                approved_at = null, approved_by_device_id = null where id = p_device_id returning * into v_device;
        else
            -- 같은 키로 다시 켜진 기기는 감싼 사본을 그대로 둔다. 공개키가 바뀌었을 때만 옛 사본을 지운다.
            if v_device.public_key is distinct from p_public_key then
                delete from public.ppomi_wrapped_keys where workspace_id = v_workspace and device_id = p_device_id;
            end if;
            update public.ppomi_devices set label = btrim(p_label), public_key = p_public_key where id = p_device_id returning * into v_device;
        end if;
    else
        insert into public.ppomi_devices(id, workspace_id, auth_user_id, label, platform, public_key, approved_at)
          values (p_device_id, v_workspace, auth.uid(), btrim(p_label), p_platform, p_public_key,
                  case when v_founder then statement_timestamp() end) returning * into v_device;
    end if;
    return jsonb_build_object(
      'workspace', (select jsonb_build_object('id', id, 'name', name) from public.ppomi_workspaces where id = v_device.workspace_id),
      'device', jsonb_build_object('id', v_device.id, 'label', v_device.label, 'platform', v_device.platform,
                                   'approved', v_device.approved_at is not null));
end;
$$;

-- 승인 전 기기도 자기 상태를 읽는다: device.approved 가 false 이면 Mac 의 승인을 기다린다. 목록에는 승인 여부가 붙는다.
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

-- 감싼 사본은 승인된 기기 몫만 돌려준다. 승인 전에는 '아직 없음'.
create or replace function public.ppomi_key_get()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices; w public.ppomi_wrapped_keys;
begin
    v_device := public.ppomi_private_record_device();
    if v_device.approved_at is null then return jsonb_build_object('found', false); end if;
    select * into w from public.ppomi_wrapped_keys where workspace_id = v_device.workspace_id and device_id = v_device.id;
    if not found then return jsonb_build_object('found', false); end if;
    return jsonb_build_object('found', true, 'workspace_id', w.workspace_id, 'key_id', w.key_id, 'records', w.records, 'wrapped', w.wrapped);
end;
$$;

-- 암호문 읽기도 승인된 기기만.
create or replace function public.ppomi_record_get(p_record_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare d public.ppomi_devices; h public.ppomi_record_heads;
begin
 d:=public.ppomi_private_approved_device();
 select * into h from public.ppomi_record_heads where workspace_id=d.workspace_id and record_id=p_record_id;
 if not found then return jsonb_build_object('found',false); end if;
 return to_jsonb(h)||jsonb_build_object('found',true);
end; $$;

create or replace function public.ppomi_record_blob_get(p_hash text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare d public.ppomi_devices; b public.ppomi_record_blobs;
begin
 d:=public.ppomi_private_approved_device();
 select * into b from public.ppomi_record_blobs where workspace_id=d.workspace_id and hash=p_hash;
 if not found then raise exception using errcode='P0002',message='Encrypted blob unavailable'; end if;
 return jsonb_build_object('hash',b.hash,'size',b.size,'data',b.data);
end; $$;

-- 키를 가진 기기가 부른다: 승인됐고 공개키는 있는데 아직 감싼 사본이 없는 기기들. 승인 대기 기기는 여기 나오지 않는다.
create or replace function public.ppomi_devices_waiting()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices;
begin
    v_device := public.ppomi_private_device();
    return (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'label', d.label, 'platform', d.platform, 'public_key', d.public_key) order by d.created_at), '[]'::jsonb)
            from public.ppomi_devices d
            where d.workspace_id = v_device.workspace_id and d.revoked_at is null and d.approved_at is not null and d.public_key is not null and d.id <> v_device.id
              and not exists (select 1 from public.ppomi_wrapped_keys w where w.workspace_id = d.workspace_id and w.device_id = d.id));
end;
$$;

-- 감싼 사본은 승인된 기기에게만 올릴 수 있다.
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
                   and revoked_at is null and approved_at is not null and public_key is not null) then
        raise exception using errcode = '42501', message = 'Target device not approved in workspace';
    end if;
    insert into public.ppomi_wrapped_keys(workspace_id, device_id, key_id, records, wrapped, wrapped_by_device_id)
      values (v_device.workspace_id, p_device_id, p_key_id, p_records, p_wrapped, v_device.id)
      on conflict (workspace_id, device_id) do update set key_id = excluded.key_id, records = excluded.records, wrapped = excluded.wrapped,
        wrapped_by_device_id = excluded.wrapped_by_device_id, updated_at = statement_timestamp();
    return jsonb_build_object('device', p_device_id, 'key_id', p_key_id);
end;
$$;

-- 승인된 네이티브 기기(Mac)가 본다: 같은 작업 공간에서 승인을 기다리는 기기들. 표시용 라벨·플랫폼·등록 시각만.
create function public.ppomi_devices_pending()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices;
begin
    v_device := public.ppomi_private_device();
    return (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'label', d.label, 'platform', d.platform, 'created_at', d.created_at) order by d.created_at), '[]'::jsonb)
            from public.ppomi_devices d
            where d.workspace_id = v_device.workspace_id and d.revoked_at is null and d.approved_at is null and d.id <> v_device.id);
end;
$$;

-- 승인: 사람이 Mac 에서 누른다. 이미 승인된 기기는 그대로 돌려준다(재시도 안전). 자기 자신은 대상이 아니다.
create function public.ppomi_device_approve(p_device_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices; v_target public.ppomi_devices;
begin
    v_device := public.ppomi_private_device();
    if p_device_id is null or p_device_id = v_device.id then
        raise exception using errcode = '22023', message = 'Invalid device';
    end if;
    select * into v_target from public.ppomi_devices
      where id = p_device_id and workspace_id = v_device.workspace_id and revoked_at is null for update;
    if not found then
        raise exception using errcode = 'P0002', message = 'Device not found in this workspace';
    end if;
    if v_target.approved_at is null then
        update public.ppomi_devices set approved_at = statement_timestamp(), approved_by_device_id = v_device.id
          where id = p_device_id returning * into v_target;
    end if;
    return jsonb_build_object('device', jsonb_build_object('id', v_target.id, 'label', v_target.label, 'platform', v_target.platform, 'approved', true));
end;
$$;

-- 거절·해지: 대기 중이든 승인됐든 그 기기를 해지하고 감싼 사본을 지운다. 되살리려면 그 기기가 다시 등록해 승인을 받아야 한다.
create function public.ppomi_device_revoke(p_device_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices; v_target public.ppomi_devices;
begin
    v_device := public.ppomi_private_device();
    if p_device_id is null or p_device_id = v_device.id then
        raise exception using errcode = '22023', message = 'Invalid device';
    end if;
    update public.ppomi_devices set revoked_at = statement_timestamp(), approved_at = null, approved_by_device_id = null
      where id = p_device_id and workspace_id = v_device.workspace_id and revoked_at is null returning * into v_target;
    if not found then
        raise exception using errcode = 'P0002', message = 'Device not found in this workspace';
    end if;
    delete from public.ppomi_wrapped_keys where workspace_id = v_device.workspace_id and device_id = p_device_id;
    return jsonb_build_object('device', jsonb_build_object('id', v_target.id, 'label', v_target.label, 'platform', v_target.platform, 'revoked', true));
end;
$$;

comment on column public.ppomi_devices.approved_at is 'Set by the workspace founder registration or by ppomi_device_approve from an approved native device. Null = waiting for the owner; no record key is wrapped for it.';
