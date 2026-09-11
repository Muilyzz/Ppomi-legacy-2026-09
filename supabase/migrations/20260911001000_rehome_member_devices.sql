-- 순서가 어긋나도 붙는다: 아이패드가 먼저 로그인해 빈 작업 공간이 생긴 뒤 Mac 이 연결하면, 구성원 자리를 Mac 의 작업 공간으로 옮기고
-- 그 사람의 기기는 다음 등록 때 따라 옮긴다(참조가 없는 새 기기 행만). 빈 작업 공간은 남아도 해가 없다.
create or replace function public.ppomi_link_member(p_auth_user_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices;
begin
    v_device := public.ppomi_private_device();
    if p_auth_user_id is null or not exists (select 1 from auth.users where id = p_auth_user_id) then
        raise exception using errcode = '22023', message = 'Unknown user';
    end if;
    insert into public.ppomi_members(workspace_id, auth_user_id) values (v_device.workspace_id, p_auth_user_id)
      on conflict (auth_user_id) do update set workspace_id = excluded.workspace_id, created_at = statement_timestamp();
    return jsonb_build_object('workspace', jsonb_build_object('id', v_device.workspace_id), 'member', p_auth_user_id);
end;
$$;

create or replace function public.ppomi_register_device(p_device_id uuid, p_label text, p_platform text)
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
    if found and v_device.auth_user_id <> auth.uid() then
        raise exception using errcode = '42501', message = 'Device belongs elsewhere';
    end if;
    if found and v_device.workspace_id <> v_workspace then
        delete from public.ppomi_devices where id = p_device_id;   -- 구성원 자리가 옮겨졌다: 참조 없는 기기 행만 따라간다(참조가 있으면 FK 가 막는다)
        v_device := null;
    end if;
    if v_device.id is not null then
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
