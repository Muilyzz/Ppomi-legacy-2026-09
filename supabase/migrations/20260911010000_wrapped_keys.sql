-- 기록 키는 서버에 평문으로 없다. 기기마다 X25519 공개키를 등록하고, 키를 가진 기기(Mac)가 아직 못 받은 기기의 공개키로 감싼 사본만 올린다.
-- 받는 기기는 자기 비밀키로 푼다. Vault 의 키 행과 비밀은 지운다. 기기를 빼면 그 기기의 사본 한 줄을 지우면 된다.
alter table public.ppomi_devices add column public_key text check (public_key is null or public_key ~ '^[A-Za-z0-9+/]{43}=$');

create table public.ppomi_wrapped_keys (
    workspace_id uuid not null references public.ppomi_workspaces(id),
    device_id uuid not null,
    key_id uuid not null,
    records jsonb not null check (jsonb_typeof(records) = 'object'),
    wrapped text not null check (wrapped ~ '^[A-Za-z0-9+/]+={0,2}$' and length(wrapped) between 60 and 400),
    wrapped_by_device_id uuid not null,
    updated_at timestamptz not null default statement_timestamp(),
    primary key (workspace_id, device_id),
    foreign key (workspace_id, device_id) references public.ppomi_devices(workspace_id, id) on delete cascade,
    foreign key (workspace_id, wrapped_by_device_id) references public.ppomi_devices(workspace_id, id)
);
alter table public.ppomi_wrapped_keys enable row level security;   -- 정책 없음: 아래 함수만 만진다

drop function public.ppomi_key_put(uuid, text, jsonb);
drop function public.ppomi_key_get();
drop table public.ppomi_workspace_keys;
do $$ begin
    delete from vault.secrets where name like 'ppomi-workspace-key:%';
exception when others then raise notice 'vault secret not deleted: %', sqlerrm; end $$;

drop function public.ppomi_register_device(uuid, text, text);
create function public.ppomi_register_device(p_device_id uuid, p_label text, p_platform text, p_public_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_workspace uuid; v_device public.ppomi_devices;
begin
    if auth.uid() is null then
        raise exception using errcode = '42501', message = 'Authenticated user required';
    end if;
    if p_device_id is null or p_label is null or char_length(btrim(p_label)) not between 1 and 120
       or p_platform not in ('macos', 'android', 'ios')
       or p_public_key is null or p_public_key !~ '^[A-Za-z0-9+/]{43}=$' then
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
    if found and v_device.auth_user_id <> auth.uid() then
        raise exception using errcode = '42501', message = 'Device belongs elsewhere';
    end if;
    if found and v_device.workspace_id <> v_workspace then
        delete from public.ppomi_devices where id = p_device_id;   -- 구성원 자리가 옮겨졌다: 참조 없는 기기 행만 따라간다
        v_device := null;
    end if;
    if v_device.id is not null then
        update public.ppomi_devices set revoked_at = null, label = btrim(p_label), public_key = p_public_key where id = p_device_id returning * into v_device;
        -- 공개키가 바뀐 기기의 옛 사본은 못 푼다: 지워서 다시 받게 한다
        delete from public.ppomi_wrapped_keys where workspace_id = v_workspace and device_id = p_device_id;
    else
        insert into public.ppomi_devices(id, workspace_id, auth_user_id, label, platform, public_key)
          values (p_device_id, v_workspace, auth.uid(), btrim(p_label), p_platform, p_public_key) returning * into v_device;
    end if;
    return jsonb_build_object(
      'workspace', (select jsonb_build_object('id', id, 'name', name) from public.ppomi_workspaces where id = v_device.workspace_id),
      'device', jsonb_build_object('id', v_device.id, 'label', v_device.label, 'platform', v_device.platform));
end;
$$;

-- 키를 가진 기기가 부른다: 같은 작업 공간에서 공개키는 있는데 아직 감싼 사본이 없는 기기들.
create function public.ppomi_devices_waiting()
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

create function public.ppomi_key_wrap_put(p_device_id uuid, p_key_id uuid, p_records jsonb, p_wrapped text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices;
begin
    v_device := public.ppomi_private_device();
    if p_device_id is null or p_key_id is null or p_records is null or jsonb_typeof(p_records) <> 'object'
       or p_wrapped is null or p_wrapped !~ '^[A-Za-z0-9+/]+={0,2}$' or length(p_wrapped) not between 60 and 400
       or exists (select 1 from jsonb_each_text(p_records) where value !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
        raise exception using errcode = '22023', message = 'Invalid wrapped key';
    end if;
    if not exists (select 1 from public.ppomi_devices where id = p_device_id and workspace_id = v_device.workspace_id and revoked_at is null and public_key is not null) then
        raise exception using errcode = '42501', message = 'Target device not in workspace';
    end if;
    insert into public.ppomi_wrapped_keys(workspace_id, device_id, key_id, records, wrapped, wrapped_by_device_id)
      values (v_device.workspace_id, p_device_id, p_key_id, p_records, p_wrapped, v_device.id)
      on conflict (workspace_id, device_id) do update set key_id = excluded.key_id, records = excluded.records, wrapped = excluded.wrapped,
        wrapped_by_device_id = excluded.wrapped_by_device_id, updated_at = statement_timestamp();
    return jsonb_build_object('device', p_device_id, 'key_id', p_key_id);
end;
$$;

-- 부르는 기기 자기 몫의 감싼 사본.
create function public.ppomi_key_get()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices; w public.ppomi_wrapped_keys;
begin
    v_device := public.ppomi_private_device();
    select * into w from public.ppomi_wrapped_keys where workspace_id = v_device.workspace_id and device_id = v_device.id;
    if not found then return jsonb_build_object('found', false); end if;
    return jsonb_build_object('found', true, 'workspace_id', w.workspace_id, 'key_id', w.key_id, 'records', w.records, 'wrapped', w.wrapped);
end;
$$;
