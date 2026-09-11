-- Slice 3 (MZZ-27 / MZZ-28): memory writes and delete are membership +
-- shared at-rest seal, not ppomi_private_device() approval.
-- Clients send plaintext payload; the RPC seals. created_by_device_id is
-- optional attribution (pending/JWT-only members may write).
-- Legacy GCM rows stay dual-read. pgcrypto cannot open GCM, so
-- ppomi_agent_memory_rewrap seals a decrypted leftover in place.
-- Do not drop PPOMI_AGENT_MEMORY_KEY in this slice.

alter table public.ppomi_agent_memories
    alter column created_by_device_id drop not null;

-- Direct SELECT (and Realtime) follow the same membership boundary as the
-- RPCs; ppomi_current_workspace_id() would still require a device header
-- and approval. Rows are at-rest envelopes, never plaintext.
drop policy ppomi_agent_memories_workspace_read on public.ppomi_agent_memories;
create policy ppomi_agent_memories_workspace_read on public.ppomi_agent_memories for select to authenticated
    using (public.ppomi_is_workspace_member(workspace_id));

create function public.ppomi_agent_memory_payload_valid(p_payload jsonb, p_id uuid, p_replaces uuid)
returns boolean language plpgsql immutable set search_path = '' as $$
begin
    if p_payload is null or p_id is null or jsonb_typeof(p_payload) <> 'object' then
        return false;
    end if;
    if octet_length(p_payload::text) > 8000 then return false; end if;
    if exists (select 1 from jsonb_object_keys(p_payload) k
               where k not in ('id', 'kind', 'text', 'source', 'confidence', 'replacesId', 'selection')) then
        return false;
    end if;
    if not (p_payload ?& array['id', 'kind', 'text', 'source', 'confidence', 'replacesId', 'selection']) then
        return false;
    end if;
    if lower(p_payload->>'id') is distinct from p_id::text then return false; end if;
    if p_replaces is null then
        if p_payload->'replacesId' <> 'null'::jsonb then return false; end if;
    elsif lower(p_payload->>'replacesId') is distinct from p_replaces::text then
        return false;
    end if;
    if p_payload->>'kind' not in ('fact', 'preference', 'decision', 'todo', 'result') then
        return false;
    end if;
    if p_payload->>'source' not in ('user_reported', 'tool_observed', 'ai_inferred') then
        return false;
    end if;
    if p_payload->>'selection' <> 'automatic' then return false; end if;
    if jsonb_typeof(p_payload->'text') <> 'string' then return false; end if;
    if btrim(p_payload->>'text') = '' or char_length(p_payload->>'text') > 2000 then
        return false;
    end if;
    if jsonb_typeof(p_payload->'confidence') <> 'number' then return false; end if;
    if (p_payload->>'confidence')::numeric < 0 or (p_payload->>'confidence')::numeric > 1 then
        return false;
    end if;
    return true;
end;
$$;

create function public.ppomi_agent_memory_canonical(p_payload jsonb, p_id uuid, p_replaces uuid)
returns jsonb language sql immutable set search_path = '' as $$
    select jsonb_build_object(
        'id', p_id,
        'kind', p_payload->>'kind',
        'text', p_payload->>'text',
        'source', p_payload->>'source',
        'confidence', p_payload->'confidence',
        'replacesId', to_jsonb(p_replaces),
        'selection', 'automatic');
$$;

create function public.ppomi_agent_memory_digest(
    p_workspace uuid, p_id uuid, p_replaces uuid, p_payload jsonb)
returns text language plpgsql stable security definer set search_path = '' as $$
declare v_canonical jsonb;
begin
    v_canonical := public.ppomi_agent_memory_canonical(p_payload, p_id, p_replaces);
    return encode(extensions.hmac(
        convert_to(
            'ppomi-memory-idempotency-v2|'
            || public.ppomi_agent_memory_aad(p_workspace, p_id, p_replaces)
            || '|' || v_canonical::text,
            'UTF8'),
        public.ppomi_at_rest_master_key(),
        'sha256'), 'hex');
end;
$$;

create function public.ppomi_agent_memory_present(
    p_memory public.ppomi_agent_memories, p_payload jsonb)
returns jsonb language sql immutable set search_path = '' as $$
    select jsonb_build_object(
        'id', p_memory.id,
        'workspace_id', p_memory.workspace_id,
        'replaces_id', p_memory.replaces_id,
        'created_at', p_memory.created_at,
        'deleted_at', p_memory.deleted_at,
        'payload', p_payload);
$$;

create or replace function public.ppomi_agent_memory_immutable()
returns trigger language plpgsql set search_path = '' as $$
begin
    if tg_op = 'DELETE' then
        raise exception using errcode = '55000', message = 'Memory records use tombstones';
    end if;
    if (new.workspace_id, new.id, new.created_by_device_id, new.request_digest, new.replaces_id, new.created_at)
       is distinct from (old.workspace_id, old.id, old.created_by_device_id, old.request_digest, old.replaces_id, old.created_at) then
        raise exception using errcode = '55000', message = 'Memory contents and tombstones are immutable';
    end if;
    if old.deleted_at is not null then
        raise exception using errcode = '55000', message = 'Memory contents and tombstones are immutable';
    end if;
    -- Tombstone: wipe ciphertext. Live rewrite: leftover GCM (or any
    -- non-at-rest envelope) may become a sealed at-rest envelope once.
    if new.deleted_at is not null then
        if new.envelope <> '{}'::jsonb then
            raise exception using errcode = '55000', message = 'Memory contents and tombstones are immutable';
        end if;
        return new;
    end if;
    if not public.ppomi_transcript_envelope_valid(old.envelope)
       and public.ppomi_transcript_envelope_valid(new.envelope) then
        return new;
    end if;
    raise exception using errcode = '55000', message = 'Memory contents and tombstones are immutable';
end;
$$;

create or replace function public.ppomi_agent_memory_list()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_workspace uuid;
begin
    v_workspace := public.ppomi_private_member_workspace();
    return (select coalesce(jsonb_agg(
        case
            when public.ppomi_transcript_envelope_valid(m.envelope) then
                public.ppomi_agent_memory_present(
                    m,
                    public.ppomi_at_rest_open(
                        m.envelope,
                        public.ppomi_agent_memory_aad(m.workspace_id, m.id, m.replaces_id)))
            else to_jsonb(m)
        end
        order by m.created_at desc, m.id), '[]'::jsonb)
      from (select m.* from public.ppomi_agent_memories m
            where m.workspace_id = v_workspace and m.deleted_at is null
              and not exists (select 1 from public.ppomi_agent_memories child
                where child.workspace_id = m.workspace_id and child.replaces_id = m.id)
            order by m.created_at desc, m.id limit 50) m);
end;
$$;

drop function public.ppomi_agent_memory_save(uuid, jsonb, text, uuid);

create function public.ppomi_agent_memory_save(p_id uuid, p_payload jsonb, p_replaces_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    v_workspace uuid;
    v_device uuid;
    v_memory public.ppomi_agent_memories;
    v_canonical jsonb;
    v_digest text;
    v_envelope jsonb;
begin
    v_workspace := public.ppomi_private_member_workspace();
    v_device := public.ppomi_private_optional_device_id(v_workspace);
    if p_id is null or p_id = p_replaces_id
       or not public.ppomi_agent_memory_payload_valid(p_payload, p_id, p_replaces_id) then
        raise exception using errcode = '22023', message = 'Invalid memory payload';
    end if;
    v_canonical := public.ppomi_agent_memory_canonical(p_payload, p_id, p_replaces_id);
    v_digest := public.ppomi_agent_memory_digest(v_workspace, p_id, p_replaces_id, v_canonical);
    perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(v_workspace::text || ':agent_memory', 0));
    select * into v_memory from public.ppomi_agent_memories
      where workspace_id = v_workspace and id = p_id;
    if found then
        if v_memory.request_digest <> v_digest or v_memory.replaces_id is distinct from p_replaces_id then
            raise exception using errcode = 'PT409', message = 'Memory ID already used with different input';
        end if;
        if v_memory.deleted_at is not null then
            raise exception using errcode = 'PT410', message = 'Memory was deleted';
        end if;
        return public.ppomi_agent_memory_present(
            v_memory,
            public.ppomi_at_rest_open(
                v_memory.envelope,
                public.ppomi_agent_memory_aad(v_memory.workspace_id, v_memory.id, v_memory.replaces_id)));
    end if;
    if p_replaces_id is not null then
        perform 1 from public.ppomi_agent_memories
          where workspace_id = v_workspace and id = p_replaces_id and deleted_at is null;
        if not found then raise exception using errcode = 'PT404', message = 'Replacement target unavailable'; end if;
        perform 1 from public.ppomi_agent_memories
          where workspace_id = v_workspace and replaces_id = p_replaces_id;
        if found then raise exception using errcode = 'PT409', message = 'Memory already replaced'; end if;
    end if;
    v_envelope := public.ppomi_at_rest_seal(
        v_canonical,
        public.ppomi_agent_memory_aad(v_workspace, p_id, p_replaces_id));
    insert into public.ppomi_agent_memories(
        workspace_id, id, created_by_device_id, envelope, request_digest, replaces_id)
      values (v_workspace, p_id, v_device, v_envelope, v_digest, p_replaces_id)
      returning * into v_memory;
    return public.ppomi_agent_memory_present(v_memory, v_canonical);
end;
$$;

create or replace function public.ppomi_agent_memory_delete(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_workspace uuid; v_memory public.ppomi_agent_memories;
begin
    v_workspace := public.ppomi_private_member_workspace();
    if p_id is null then raise exception using errcode = '22023', message = 'Memory ID required'; end if;
    perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(v_workspace::text || ':agent_memory', 0));
    select * into v_memory from public.ppomi_agent_memories
      where workspace_id = v_workspace and id = p_id for update;
    if not found then raise exception using errcode = 'PT404', message = 'Memory unavailable'; end if;
    with recursive ancestors as (
        select id, replaces_id from public.ppomi_agent_memories
          where workspace_id = v_workspace and id = p_id
        union all
        select parent.id, parent.replaces_id from public.ppomi_agent_memories parent
          join ancestors child on parent.id = child.replaces_id
         where parent.workspace_id = v_workspace
    )
    update public.ppomi_agent_memories
      set deleted_at = statement_timestamp(), envelope = '{}'::jsonb
      where workspace_id = v_workspace and id in (select id from ancestors) and deleted_at is null;
    return jsonb_build_object('deleted', true);
end;
$$;

create function public.ppomi_agent_memory_rewrap(p_id uuid, p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
    v_workspace uuid;
    v_memory public.ppomi_agent_memories;
    v_canonical jsonb;
    v_opened jsonb;
begin
    v_workspace := public.ppomi_private_member_workspace();
    if p_id is null then raise exception using errcode = '22023', message = 'Memory ID required'; end if;
    perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(v_workspace::text || ':agent_memory', 0));
    select * into v_memory from public.ppomi_agent_memories
      where workspace_id = v_workspace and id = p_id for update;
    if not found then raise exception using errcode = 'PT404', message = 'Memory unavailable'; end if;
    if v_memory.deleted_at is not null then
        raise exception using errcode = 'PT410', message = 'Memory was deleted';
    end if;
    if not public.ppomi_agent_memory_payload_valid(p_payload, p_id, v_memory.replaces_id) then
        raise exception using errcode = '22023', message = 'Invalid memory payload';
    end if;
    v_canonical := public.ppomi_agent_memory_canonical(p_payload, p_id, v_memory.replaces_id);
    if public.ppomi_transcript_envelope_valid(v_memory.envelope) then
        v_opened := public.ppomi_at_rest_open(
            v_memory.envelope,
            public.ppomi_agent_memory_aad(v_memory.workspace_id, v_memory.id, v_memory.replaces_id));
        if v_opened is distinct from v_canonical then
            raise exception using errcode = 'PT409', message = 'Memory ID already used with different input';
        end if;
        return public.ppomi_agent_memory_present(v_memory, v_opened);
    end if;
    update public.ppomi_agent_memories
      set envelope = public.ppomi_at_rest_seal(
            v_canonical,
            public.ppomi_agent_memory_aad(v_workspace, p_id, v_memory.replaces_id))
      where workspace_id = v_workspace and id = p_id
      returning * into v_memory;
    return public.ppomi_agent_memory_present(v_memory, v_canonical);
end;
$$;

revoke all on function public.ppomi_agent_memory_payload_valid(jsonb, uuid, uuid),
    public.ppomi_agent_memory_canonical(jsonb, uuid, uuid),
    public.ppomi_agent_memory_digest(uuid, uuid, uuid, jsonb),
    public.ppomi_agent_memory_present(public.ppomi_agent_memories, jsonb),
    public.ppomi_agent_memory_save(uuid, jsonb, uuid),
    public.ppomi_agent_memory_rewrap(uuid, jsonb)
    from public, anon, authenticated;
grant execute on function public.ppomi_agent_memory_save(uuid, jsonb, uuid),
    public.ppomi_agent_memory_delete(uuid),
    public.ppomi_agent_memory_list(),
    public.ppomi_agent_memory_rewrap(uuid, jsonb)
    to authenticated;

comment on function public.ppomi_agent_memory_save(uuid, jsonb, uuid) is
    'Inserts a distilled memory for the signed-in workspace member. Seals with the shared at-rest helper. No device-approval gate. Device header is optional attribution.';
comment on function public.ppomi_agent_memory_delete(uuid) is
    'Tombs a memory and its ancestors for the signed-in workspace member. No device-approval gate.';
comment on function public.ppomi_agent_memory_rewrap(uuid, jsonb) is
    'Seals a leftover GCM memory as an at-rest envelope. Identity and digest stay put. Dual-read remains until leftovers are gone.';
comment on function public.ppomi_agent_memory_list() is
    'Lists live memory heads for the signed-in workspace member. At-rest envelopes are opened here; leftover GCM envelopes are returned for the agent to decrypt and rewrap.';
