-- Distilled, automatically selected records only. No transcript, conversation or
-- voice-session table. AES-GCM payloads are encrypted by the authenticated agent
-- server; that server can decrypt. This is not end-to-end encryption.
create table public.ppomi_agent_memories (
    workspace_id uuid not null references public.ppomi_workspaces(id),
    id uuid not null,
    created_by_device_id uuid not null,
    envelope jsonb not null,
    request_digest text not null check (request_digest ~ '^[0-9a-f]{64}$'),
    replaces_id uuid,
    created_at timestamptz not null default statement_timestamp(),
    deleted_at timestamptz,
    primary key (workspace_id, id),
    unique (workspace_id, replaces_id),
    foreign key (workspace_id, created_by_device_id) references public.ppomi_devices(workspace_id, id),
    foreign key (workspace_id, replaces_id) references public.ppomi_agent_memories(workspace_id, id),
    check (id is distinct from replaces_id),
    check (jsonb_typeof(envelope) = 'object' and octet_length(envelope::text) <= 20000)
);
create index ppomi_agent_memories_current_idx on public.ppomi_agent_memories(workspace_id, created_at desc, id) where deleted_at is null;
alter table public.ppomi_agent_memories enable row level security;
create policy ppomi_agent_memories_workspace_read on public.ppomi_agent_memories for select to authenticated
    using (workspace_id = (select public.ppomi_current_workspace_id()));

create function public.ppomi_agent_memory_immutable()
returns trigger language plpgsql set search_path = '' as $$
begin
    if tg_op = 'DELETE' then
        raise exception using errcode = '55000', message = 'Memory records use tombstones';
    end if;
    if (new.workspace_id, new.id, new.created_by_device_id, new.request_digest, new.replaces_id, new.created_at)
       is distinct from (old.workspace_id, old.id, old.created_by_device_id, old.request_digest, old.replaces_id, old.created_at)
       or old.deleted_at is not null or new.deleted_at is null or new.envelope <> '{}'::jsonb then
        raise exception using errcode = '55000', message = 'Memory contents and tombstones are immutable';
    end if;
    return new;
end;
$$;
create trigger ppomi_agent_memory_preserve_history before update or delete on public.ppomi_agent_memories
    for each row execute function public.ppomi_agent_memory_immutable();

create function public.ppomi_agent_memory_list()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices;
begin
    v_device := public.ppomi_private_device();
    -- A deleted replacement must never resurrect its old contents in the current list.
    return (select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at desc, m.id), '[]'::jsonb)
      from (select m.* from public.ppomi_agent_memories m
            where m.workspace_id = v_device.workspace_id and m.deleted_at is null
              and not exists (select 1 from public.ppomi_agent_memories child
                where child.workspace_id = m.workspace_id and child.replaces_id = m.id)
            order by m.created_at desc, m.id limit 50) m);
end;
$$;

create function public.ppomi_agent_memory_save(p_id uuid, p_envelope jsonb, p_request_digest text, p_replaces_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices; v_memory public.ppomi_agent_memories;
begin
    v_device := public.ppomi_private_device();
    if p_id is null or p_id = p_replaces_id or p_request_digest is null or p_request_digest !~ '^[0-9a-f]{64}$'
       or p_envelope is null or jsonb_typeof(p_envelope) <> 'object' or octet_length(p_envelope::text) > 20000 then
        raise exception using errcode = '22023', message = 'Invalid encrypted memory';
    end if;
    if not (p_envelope ?& array['version', 'nonce', 'ciphertext', 'tag'])
       or exists (select 1 from jsonb_object_keys(p_envelope) k where k not in ('version','nonce','ciphertext','tag'))
       or p_envelope->'version' <> '1'::jsonb
       or jsonb_typeof(p_envelope->'nonce') <> 'string' or (p_envelope->>'nonce') !~ '^[A-Za-z0-9_-]{16}$'
       or jsonb_typeof(p_envelope->'tag') <> 'string' or (p_envelope->>'tag') !~ '^[A-Za-z0-9_-]{22}$'
       or jsonb_typeof(p_envelope->'ciphertext') <> 'string' or (p_envelope->>'ciphertext') !~ '^[A-Za-z0-9_-]+$'
       or length(p_envelope->>'ciphertext') not between 1 and 18000 then
        raise exception using errcode = '22023', message = 'Invalid encrypted memory envelope';
    end if;
    -- Serialize saves and tombstones within a workspace so concurrent replacements
    -- cannot fork history, and retries cannot revive a deleted record.
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_device.workspace_id::text || ':agent_memory', 0));
    select * into v_memory from public.ppomi_agent_memories where workspace_id = v_device.workspace_id and id = p_id;
    if found then
        if v_memory.request_digest <> p_request_digest or v_memory.replaces_id is distinct from p_replaces_id then
            raise exception using errcode = 'PT409', message = 'Memory ID already used with different input';
        end if;
        if v_memory.deleted_at is not null then
            raise exception using errcode = 'PT410', message = 'Memory was deleted';
        end if;
        -- Nonces are random. A keyed content digest permits exact logical retries;
        -- the original authenticated ciphertext is returned without any overwrite.
        return to_jsonb(v_memory);
    end if;
    if p_replaces_id is not null then
        perform 1 from public.ppomi_agent_memories where workspace_id = v_device.workspace_id and id = p_replaces_id and deleted_at is null;
        if not found then raise exception using errcode = 'PT404', message = 'Replacement target unavailable'; end if;
        perform 1 from public.ppomi_agent_memories where workspace_id = v_device.workspace_id and replaces_id = p_replaces_id;
        if found then raise exception using errcode = 'PT409', message = 'Memory already replaced'; end if;
    end if;
    insert into public.ppomi_agent_memories(workspace_id, id, created_by_device_id, envelope, request_digest, replaces_id)
      values (v_device.workspace_id, p_id, v_device.id, p_envelope, p_request_digest, p_replaces_id) returning * into v_memory;
    return to_jsonb(v_memory);
end;
$$;

create function public.ppomi_agent_memory_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices; v_memory public.ppomi_agent_memories;
begin
    v_device := public.ppomi_private_device();
    if p_id is null then raise exception using errcode = '22023', message = 'Memory ID required'; end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_device.workspace_id::text || ':agent_memory', 0));
    select * into v_memory from public.ppomi_agent_memories where workspace_id = v_device.workspace_id and id = p_id for update;
    if not found then raise exception using errcode = 'PT404', message = 'Memory unavailable'; end if;
    -- Explicit deletion clears the selected record and every earlier revision's
    -- ciphertext atomically. Opaque tombstones/digests preserve no-resurrection
    -- and idempotency guards; ordinary replacements retain their full history.
    with recursive ancestors as (
        select id, replaces_id from public.ppomi_agent_memories where workspace_id = v_device.workspace_id and id = p_id
        union all
        select parent.id, parent.replaces_id from public.ppomi_agent_memories parent
          join ancestors child on parent.id = child.replaces_id where parent.workspace_id = v_device.workspace_id
    )
    update public.ppomi_agent_memories set deleted_at = statement_timestamp(), envelope = '{}'::jsonb
      where workspace_id = v_device.workspace_id and id in (select id from ancestors) and deleted_at is null;
    return jsonb_build_object('deleted', true);
end;
$$;

revoke all on table public.ppomi_agent_memories from public, anon, authenticated;
grant select on table public.ppomi_agent_memories to authenticated;
revoke all on function public.ppomi_agent_memory_immutable(), public.ppomi_agent_memory_list(),
    public.ppomi_agent_memory_save(uuid,jsonb,text,uuid), public.ppomi_agent_memory_delete(uuid) from public, anon, authenticated;
grant execute on function public.ppomi_agent_memory_list(), public.ppomi_agent_memory_save(uuid,jsonb,text,uuid),
    public.ppomi_agent_memory_delete(uuid) to authenticated;
comment on table public.ppomi_agent_memories is 'Encrypted distilled records automatically selected during voice sessions. No transcript/session storage. Server holds encryption key; not E2EE.';
