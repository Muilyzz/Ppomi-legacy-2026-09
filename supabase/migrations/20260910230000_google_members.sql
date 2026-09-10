-- 구글 계정 로그인: 한 사람(auth 사용자)이 기기를 여럿 가진다. 기기는 요청 헤더 X-Ppomi-Device 로 고른다.
-- 기존 기기(이메일·비밀번호 계정 하나 = 기기 하나)는 헤더 없이 그대로 동작한다. 새 기기는 등록 기기가 만든 일회용 초대로 들어온다.
create extension if not exists pgcrypto with schema extensions;

alter table public.ppomi_devices drop constraint ppomi_devices_auth_user_id_key;
alter table public.ppomi_devices drop constraint ppomi_devices_platform_check;
alter table public.ppomi_devices add constraint ppomi_devices_platform_check check (platform in ('macos', 'android', 'ios'));
create index ppomi_devices_auth_user_idx on public.ppomi_devices(auth_user_id) where revoked_at is null;

create table public.ppomi_invites (
    workspace_id uuid not null references public.ppomi_workspaces(id),
    token_hash text primary key check (token_hash ~ '^[0-9a-f]{64}$'),
    created_by_device_id uuid not null,
    expires_at timestamptz not null,
    used_at timestamptz,
    foreign key (workspace_id, created_by_device_id) references public.ppomi_devices(workspace_id, id)
);
alter table public.ppomi_invites enable row level security;   -- 정책 없음: 아래 함수(security definer)만 만진다

create or replace function public.ppomi_private_device()
returns public.ppomi_devices language plpgsql security definer set search_path = '' as $$
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
$$;

-- 등록 기기가 만드는 초대: 토큰은 한 번만 돌려주고 해시만 남는다. 10분.
create function public.ppomi_create_invite()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices; v_token text; v_expires timestamptz;
begin
    v_device := public.ppomi_private_device();
    v_token := encode(extensions.gen_random_bytes(32), 'hex');
    v_expires := statement_timestamp() + interval '10 minutes';
    delete from public.ppomi_invites where workspace_id = v_device.workspace_id
      and (used_at is not null or expires_at < statement_timestamp());
    insert into public.ppomi_invites(workspace_id, token_hash, created_by_device_id, expires_at)
      values (v_device.workspace_id, encode(sha256(convert_to(v_token, 'UTF8')), 'hex'), v_device.id, v_expires);
    return jsonb_build_object('token', v_token, 'expires_at', v_expires);
end;
$$;

-- 구글로 로그인한 사용자가 초대로 자기 기기를 등록한다. 같은 기기 ID 를 다시 등록하면 되살린다(다른 사람·다른 작업 공간이면 거부).
create function public.ppomi_register_device(p_invite text, p_device_id uuid, p_label text, p_platform text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_invite public.ppomi_invites; v_device public.ppomi_devices;
begin
    if auth.uid() is null then
        raise exception using errcode = '42501', message = 'Authenticated user required';
    end if;
    if p_invite is null or p_invite !~ '^[0-9a-f]{64}$' or p_device_id is null or p_label is null
       or char_length(btrim(p_label)) not between 1 and 120 or p_platform not in ('macos', 'android', 'ios') then
        raise exception using errcode = '22023', message = 'Invalid registration';
    end if;
    select * into v_invite from public.ppomi_invites
      where token_hash = encode(sha256(convert_to(p_invite, 'UTF8')), 'hex') for update;
    if not found or v_invite.used_at is not null or v_invite.expires_at < statement_timestamp() then
        raise exception using errcode = '42501', message = 'Invite invalid or expired';
    end if;
    update public.ppomi_invites set used_at = statement_timestamp() where token_hash = v_invite.token_hash;
    select * into v_device from public.ppomi_devices where id = p_device_id;
    if found then
        if v_device.auth_user_id <> auth.uid() or v_device.workspace_id <> v_invite.workspace_id then
            raise exception using errcode = '42501', message = 'Device belongs elsewhere';
        end if;
        update public.ppomi_devices set revoked_at = null, label = btrim(p_label) where id = p_device_id returning * into v_device;
    else
        insert into public.ppomi_devices(id, workspace_id, auth_user_id, label, platform)
          values (p_device_id, v_invite.workspace_id, auth.uid(), btrim(p_label), p_platform) returning * into v_device;
    end if;
    return jsonb_build_object(
      'workspace', (select jsonb_build_object('id', id, 'name', name) from public.ppomi_workspaces where id = v_device.workspace_id),
      'device', jsonb_build_object('id', v_device.id, 'label', v_device.label, 'platform', v_device.platform));
end;
$$;
