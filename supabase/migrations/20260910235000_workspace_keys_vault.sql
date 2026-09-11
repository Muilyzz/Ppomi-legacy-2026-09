-- 기록 키를 일반 컬럼 대신 Supabase Vault 비밀로 둔다: DB 밖 KMS 키로 한 번 더 감싸 백업·덤프·무심한 SQL 조회에 평문이 남지 않는다.
-- 대시보드 소유자와 service_role 은 여전히 풀 수 있다(프로젝트 통째 유출은 못 막는다). 아직 키 행이 없어 데이터 이전은 없다.
alter table public.ppomi_workspace_keys drop column key;
alter table public.ppomi_workspace_keys add column secret_id uuid not null;

create or replace function public.ppomi_key_put(p_key_id uuid, p_key text, p_records jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices; v_row public.ppomi_workspace_keys; v_secret uuid;
begin
    v_device := public.ppomi_private_device();
    if p_key_id is null or p_key is null or p_key !~ '^[A-Za-z0-9+/]{43}=$' or p_records is null or jsonb_typeof(p_records) <> 'object'
       or exists (select 1 from jsonb_each_text(p_records) where value !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
        raise exception using errcode = '22023', message = 'Invalid key';
    end if;
    select * into v_row from public.ppomi_workspace_keys where workspace_id = v_device.workspace_id for update;
    if found then
        perform vault.update_secret(v_row.secret_id, p_key);
        update public.ppomi_workspace_keys
          set key_id = p_key_id, records = p_records, updated_by_device_id = v_device.id, updated_at = statement_timestamp()
          where workspace_id = v_device.workspace_id;
    else
        v_secret := vault.create_secret(p_key, 'ppomi-workspace-key:' || v_device.workspace_id::text, '뽀미 기록 암호화 키');
        insert into public.ppomi_workspace_keys(workspace_id, key_id, records, updated_by_device_id, secret_id)
          values (v_device.workspace_id, p_key_id, p_records, v_device.id, v_secret);
    end if;
    return jsonb_build_object('key_id', p_key_id);
end;
$$;

create or replace function public.ppomi_key_get()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices; k public.ppomi_workspace_keys; v_key text;
begin
    v_device := public.ppomi_private_device();
    select * into k from public.ppomi_workspace_keys where workspace_id = v_device.workspace_id;
    if not found then return jsonb_build_object('found', false); end if;
    select decrypted_secret into v_key from vault.decrypted_secrets where id = k.secret_id;
    if v_key is null then
        raise exception using errcode = 'P0002', message = 'Key secret missing';
    end if;
    return jsonb_build_object('found', true, 'workspace_id', k.workspace_id, 'key_id', k.key_id, 'key', v_key, 'records', k.records);
end;
$$;
