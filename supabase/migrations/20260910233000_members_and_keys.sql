-- 구글 계정 = 사람. 작업 공간의 구성원(ppomi_members)이면 어느 기기든 초대 없이 등록한다(QR 없음).
-- 기록 키는 작업 공간마다 하나(ppomi_workspace_keys): Mac 이 올리고, 그 작업 공간의 기기가 받아 간다. 전역 키가 아니다.
create table public.ppomi_members (
    workspace_id uuid not null references public.ppomi_workspaces(id),
    auth_user_id uuid not null references auth.users(id),
    created_at timestamptz not null default statement_timestamp(),
    primary key (workspace_id, auth_user_id)
);
create unique index ppomi_members_user_idx on public.ppomi_members(auth_user_id);   -- 한 사람 = 작업 공간 하나
alter table public.ppomi_members enable row level security;   -- 정책 없음: 함수(security definer)만 만진다

create table public.ppomi_workspace_keys (
    workspace_id uuid primary key references public.ppomi_workspaces(id),
    key_id uuid not null,
    key text not null check (key ~ '^[A-Za-z0-9+/]{43}=$'),          -- 32바이트 base64
    records jsonb not null check (jsonb_typeof(records) = 'object'),   -- 기록 이름 → 기록 ID
    updated_by_device_id uuid not null,
    updated_at timestamptz not null default statement_timestamp(),
    foreign key (workspace_id, updated_by_device_id) references public.ppomi_devices(workspace_id, id)
);
alter table public.ppomi_workspace_keys enable row level security;

drop function public.ppomi_register_device(text, uuid, text, text);
drop function public.ppomi_create_invite();
drop table public.ppomi_invites;

-- 등록 기기(예: 이메일 계정의 Mac)가 구글 사용자를 자기 작업 공간의 구성원으로 넣는다. 다른 작업 공간의 구성원이면 거부(unique index).
create function public.ppomi_link_member(p_auth_user_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices;
begin
    v_device := public.ppomi_private_device();
    if p_auth_user_id is null or not exists (select 1 from auth.users where id = p_auth_user_id) then
        raise exception using errcode = '22023', message = 'Unknown user';
    end if;
    insert into public.ppomi_members(workspace_id, auth_user_id) values (v_device.workspace_id, p_auth_user_id)
      on conflict (workspace_id, auth_user_id) do nothing;
    return jsonb_build_object('workspace', jsonb_build_object('id', v_device.workspace_id), 'member', p_auth_user_id);
end;
$$;

-- 로그인한 사용자가 자기 기기를 등록한다: 구성원이면 그 작업 공간, 기기가 이미 있으면 그 작업 공간, 둘 다 없으면 새 작업 공간.
create function public.ppomi_register_device(p_device_id uuid, p_label text, p_platform text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_workspace uuid; v_device public.ppomi_devices;
begin
    if auth.uid() is null then
        raise exception using errcode = '42501', message = 'Authenticated user required';
    end if;
    if p_device_id is null or p_label is null or char_length(btrim(p_label)) not between 1 and 120
       or p_platform not in ('macos', 'android', 'ios') then
        raise exception using errcode = '22023', message = 'Invalid registration';
    end if;
    select workspace_id into v_workspace from public.ppomi_members where auth_user_id = auth.uid();
    if v_workspace is null then
        select workspace_id into v_workspace from public.ppomi_devices
          where auth_user_id = auth.uid() and revoked_at is null order by created_at limit 1;
    end if;
    if v_workspace is null then
        insert into public.ppomi_workspaces(name) values ('뽀미') returning id into v_workspace;
        insert into public.ppomi_members(workspace_id, auth_user_id) values (v_workspace, auth.uid());
    end if;
    select * into v_device from public.ppomi_devices where id = p_device_id;
    if found then
        if v_device.auth_user_id <> auth.uid() or v_device.workspace_id <> v_workspace then
            raise exception using errcode = '42501', message = 'Device belongs elsewhere';
        end if;
        update public.ppomi_devices set revoked_at = null, label = btrim(p_label) where id = p_device_id returning * into v_device;
    else
        insert into public.ppomi_devices(id, workspace_id, auth_user_id, label, platform)
          values (p_device_id, v_workspace, auth.uid(), btrim(p_label), p_platform) returning * into v_device;
    end if;
    return jsonb_build_object(
      'workspace', (select jsonb_build_object('id', id, 'name', name) from public.ppomi_workspaces where id = v_device.workspace_id),
      'device', jsonb_build_object('id', v_device.id, 'label', v_device.label, 'platform', v_device.platform));
end;
$$;

-- 기록 키: 작업 공간의 기기가 올리고(Mac), 그 작업 공간의 기기가 받는다.
create function public.ppomi_key_put(p_key_id uuid, p_key text, p_records jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices;
begin
    v_device := public.ppomi_private_device();
    if p_key_id is null or p_key is null or p_key !~ '^[A-Za-z0-9+/]{43}=$' or p_records is null or jsonb_typeof(p_records) <> 'object'
       or exists (select 1 from jsonb_each_text(p_records) where value !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
        raise exception using errcode = '22023', message = 'Invalid key';
    end if;
    insert into public.ppomi_workspace_keys(workspace_id, key_id, key, records, updated_by_device_id)
      values (v_device.workspace_id, p_key_id, p_key, p_records, v_device.id)
      on conflict (workspace_id) do update set key_id = excluded.key_id, key = excluded.key, records = excluded.records,
        updated_by_device_id = excluded.updated_by_device_id, updated_at = statement_timestamp();
    return jsonb_build_object('key_id', p_key_id);
end;
$$;

create function public.ppomi_key_get()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices; k public.ppomi_workspace_keys;
begin
    v_device := public.ppomi_private_device();
    select * into k from public.ppomi_workspace_keys where workspace_id = v_device.workspace_id;
    if not found then return jsonb_build_object('found', false); end if;
    return jsonb_build_object('found', true, 'workspace_id', k.workspace_id, 'key_id', k.key_id, 'key', k.key, 'records', k.records);
end;
$$;
