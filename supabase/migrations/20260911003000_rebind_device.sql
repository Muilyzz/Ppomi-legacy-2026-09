-- Mac 의 첫 구글 로그인: 옛 기기 계정(이메일·비밀번호)이 자기 기기 행을 구글 사용자 것으로 넘기고 그 사용자를 작업 공간 구성원으로 넣는다.
-- 그 뒤 Mac 은 구글 세션 + X-Ppomi-Device 로 같은 기기·같은 작업 공간·같은 기록을 쓴다. 옛 계정에는 기기가 남지 않는다.
create function public.ppomi_rebind_device(p_auth_user_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices;
begin
    v_device := public.ppomi_private_device();
    if p_auth_user_id is null or not exists (select 1 from auth.users where id = p_auth_user_id) then
        raise exception using errcode = '22023', message = 'Unknown user';
    end if;
    insert into public.ppomi_members(workspace_id, auth_user_id) values (v_device.workspace_id, p_auth_user_id)
      on conflict (auth_user_id) do update set workspace_id = excluded.workspace_id, created_at = statement_timestamp();
    update public.ppomi_devices set auth_user_id = p_auth_user_id where id = v_device.id;
    return jsonb_build_object('device', jsonb_build_object('id', v_device.id),
                              'workspace', jsonb_build_object('id', v_device.workspace_id));
end;
$$;
