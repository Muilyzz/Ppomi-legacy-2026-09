-- Shared chat transcripts. Separate from ledger records (ppomi_record_*)
-- and from agent-server memories (ppomi_agent_memories).
--
-- Policy (MZZ-27): Auth + RLS. The signed-in workspace member reads and
-- writes turn JSON the server can see. No client E2E, no wrapped-key
-- gate, no device-approval gate. Agent /v1/session and /v1/responses
-- stay ephemeral; clients persist here.

create table public.ppomi_transcripts (
    workspace_id uuid not null references public.ppomi_workspaces(id),
    id uuid not null,
    created_by_user_id uuid not null,
    created_by_device_id uuid,
    created_at timestamptz not null default statement_timestamp(),
    updated_at timestamptz not null default statement_timestamp(),
    deleted_at timestamptz,
    primary key (workspace_id, id),
    foreign key (workspace_id, created_by_device_id) references public.ppomi_devices(workspace_id, id)
);
create index ppomi_transcripts_current_idx
    on public.ppomi_transcripts (workspace_id, created_at desc, id)
    where deleted_at is null;

create table public.ppomi_transcript_turns (
    workspace_id uuid not null,
    transcript_id uuid not null,
    turn_id uuid not null,
    seq bigint not null check (seq > 0),
    writer_user_id uuid not null,
    writer_device_id uuid,
    payload jsonb not null,
    created_at timestamptz not null default statement_timestamp(),
    primary key (workspace_id, transcript_id, turn_id),
    unique (workspace_id, transcript_id, seq),
    foreign key (workspace_id, transcript_id) references public.ppomi_transcripts(workspace_id, id),
    foreign key (workspace_id, writer_device_id) references public.ppomi_devices(workspace_id, id),
    check (jsonb_typeof(payload) = 'object' and octet_length(payload::text) <= 56000)
);
create index ppomi_transcript_turns_seq_idx
    on public.ppomi_transcript_turns (workspace_id, transcript_id, seq);

alter table public.ppomi_transcripts enable row level security;
alter table public.ppomi_transcript_turns enable row level security;

create function public.ppomi_is_workspace_member(p_workspace uuid)
returns boolean language sql stable security definer set search_path = '' as $$
    select p_workspace is not null and auth.uid() is not null and exists (
        select 1 from public.ppomi_members m
        where m.workspace_id = p_workspace and m.auth_user_id = auth.uid());
$$;

-- Realtime SELECT uses the JWT only. Membership is the boundary — not
-- X-Ppomi-Device, approval, or a wrapped workspace key.
-- The helper is security definer because ppomi_members has no SELECT policy.
create policy ppomi_transcript_read on public.ppomi_transcripts for select to authenticated
    using (public.ppomi_is_workspace_member(workspace_id));
create policy ppomi_transcript_turn_read on public.ppomi_transcript_turns for select to authenticated
    using (public.ppomi_is_workspace_member(workspace_id));

create function public.ppomi_private_member_workspace()
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare v_workspace uuid;
begin
    if auth.uid() is null then
        raise exception using errcode = '42501', message = 'Authenticated user required';
    end if;
    select m.workspace_id into v_workspace
      from public.ppomi_members m
      where m.auth_user_id = auth.uid();
    if v_workspace is null then
        raise exception using errcode = '42501', message = 'Workspace membership required';
    end if;
    return v_workspace;
end;
$$;

create function public.ppomi_private_optional_device_id(p_workspace uuid)
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare v_header text; v_id uuid;
begin
    if p_workspace is null or auth.uid() is null then return null; end if;
    v_header := nullif(current_setting('request.headers', true), '')::json ->> 'x-ppomi-device';
    if v_header is null then return null; end if;
    begin v_id := v_header::uuid;
    exception when others then return null; end;
    if exists (
        select 1 from public.ppomi_devices d
        where d.id = v_id and d.workspace_id = p_workspace
          and d.auth_user_id = auth.uid() and d.revoked_at is null) then
        return v_id;
    end if;
    return null;
end;
$$;

create function public.ppomi_transcript_payload_valid(p_payload jsonb, p_turn_id uuid)
returns boolean language plpgsql immutable set search_path = '' as $$
declare v_part jsonb;
begin
    if p_payload is null or p_turn_id is null or jsonb_typeof(p_payload) <> 'object' then
        return false;
    end if;
    if octet_length(p_payload::text) > 56000 then return false; end if;
    if exists (select 1 from jsonb_object_keys(p_payload) k where k not in ('id', 'role', 'parts')) then
        return false;
    end if;
    if p_payload->>'id' is distinct from p_turn_id::text then return false; end if;
    if p_payload->>'role' not in ('user', 'assistant') then return false; end if;
    if jsonb_typeof(p_payload->'parts') <> 'array' then return false; end if;
    if jsonb_array_length(p_payload->'parts') < 1 or jsonb_array_length(p_payload->'parts') > 32 then
        return false;
    end if;
    for v_part in select value from jsonb_array_elements(p_payload->'parts')
    loop
        if jsonb_typeof(v_part) <> 'object' then return false; end if;
        if v_part->>'type' = 'tool' then
            if exists (select 1 from jsonb_object_keys(v_part) k where k not in ('type', 'name', 'state')) then
                return false;
            end if;
            if jsonb_typeof(v_part->'name') <> 'string'
               or char_length(v_part->>'name') not between 1 and 80 then
                return false;
            end if;
            if v_part ? 'state' and (jsonb_typeof(v_part->'state') <> 'string'
               or char_length(v_part->>'state') > 80) then
                return false;
            end if;
        elsif v_part->>'type' in ('text', 'reasoning') then
            if exists (select 1 from jsonb_object_keys(v_part) k where k not in ('type', 'text')) then
                return false;
            end if;
            if jsonb_typeof(v_part->'text') <> 'string' or char_length(v_part->>'text') > 16000 then
                return false;
            end if;
        else
            return false;
        end if;
    end loop;
    return true;
end;
$$;

create function public.ppomi_transcript_open(p_transcript_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_workspace uuid; v_user uuid; v_device uuid; t public.ppomi_transcripts;
begin
    v_workspace := public.ppomi_private_member_workspace();
    v_user := auth.uid();
    v_device := public.ppomi_private_optional_device_id(v_workspace);
    if p_transcript_id is null then
        raise exception using errcode = '22023', message = 'Transcript ID required';
    end if;
    perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(v_workspace::text || ':transcript', 0));
    select * into t from public.ppomi_transcripts
      where workspace_id = v_workspace and deleted_at is null
      order by created_at desc, id limit 1;
    if found then return to_jsonb(t); end if;
    select * into t from public.ppomi_transcripts
      where workspace_id = v_workspace and id = p_transcript_id;
    if found then
        if t.deleted_at is not null then
            raise exception using errcode = 'PT410', message = 'Transcript was deleted';
        end if;
        return to_jsonb(t);
    end if;
    insert into public.ppomi_transcripts(workspace_id, id, created_by_user_id, created_by_device_id)
      values (v_workspace, p_transcript_id, v_user, v_device)
      returning * into t;
    return to_jsonb(t);
end;
$$;

create function public.ppomi_transcript_list()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_workspace uuid;
begin
    v_workspace := public.ppomi_private_member_workspace();
    return jsonb_build_object('transcripts', coalesce((
        select jsonb_agg(jsonb_build_object(
            'id', t.id,
            'workspace_id', t.workspace_id,
            'created_by_user_id', t.created_by_user_id,
            'created_by_device_id', t.created_by_device_id,
            'created_at', t.created_at,
            'updated_at', t.updated_at,
            'last_seq', coalesce((
                select max(s.seq) from public.ppomi_transcript_turns s
                where s.workspace_id = t.workspace_id and s.transcript_id = t.id
                  and s.payload <> '{}'::jsonb), 0)
        ) order by t.created_at desc, t.id)
        from (
            select * from public.ppomi_transcripts
            where workspace_id = v_workspace and deleted_at is null
            order by created_at desc, id limit 50
        ) t
    ), '[]'::jsonb));
end;
$$;

create function public.ppomi_transcript_turns(p_transcript_id uuid, p_after_seq bigint default 0)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_workspace uuid; t public.ppomi_transcripts;
begin
    v_workspace := public.ppomi_private_member_workspace();
    if p_transcript_id is null or p_after_seq is null or p_after_seq < 0 then
        raise exception using errcode = '22023', message = 'Invalid transcript query';
    end if;
    select * into t from public.ppomi_transcripts
      where workspace_id = v_workspace and id = p_transcript_id;
    if not found or t.deleted_at is not null then
        return jsonb_build_object('found', false, 'turns', '[]'::jsonb);
    end if;
    return jsonb_build_object(
        'found', true,
        'transcript_id', t.id,
        'workspace_id', t.workspace_id,
        'deleted', false,
        'turns', coalesce((
            select jsonb_agg(jsonb_build_object(
                'turn_id', s.turn_id,
                'seq', s.seq,
                'writer_user_id', s.writer_user_id,
                'writer_device_id', s.writer_device_id,
                'payload', s.payload,
                'created_at', s.created_at
            ) order by s.seq, s.turn_id)
            from (
                select * from public.ppomi_transcript_turns
                where workspace_id = v_workspace
                  and transcript_id = p_transcript_id
                  and seq > p_after_seq
                  and payload <> '{}'::jsonb
                order by seq, turn_id limit 200
            ) s
        ), '[]'::jsonb));
end;
$$;

create function public.ppomi_transcript_append(
    p_transcript_id uuid, p_turn_id uuid, p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_workspace uuid; v_user uuid; v_device uuid;
        t public.ppomi_transcripts; s public.ppomi_transcript_turns; v_seq bigint;
begin
    v_workspace := public.ppomi_private_member_workspace();
    v_user := auth.uid();
    v_device := public.ppomi_private_optional_device_id(v_workspace);
    if p_transcript_id is null or p_turn_id is null then
        raise exception using errcode = '22023', message = 'Transcript turn identity required';
    end if;
    if not public.ppomi_transcript_payload_valid(p_payload, p_turn_id) then
        raise exception using errcode = '22023', message = 'Invalid transcript payload';
    end if;
    perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(v_workspace::text || ':transcript:' || p_transcript_id::text, 0));
    select * into t from public.ppomi_transcripts
      where workspace_id = v_workspace and id = p_transcript_id for update;
    if not found then
        raise exception using errcode = 'PT404', message = 'Transcript unavailable';
    end if;
    if t.deleted_at is not null then
        raise exception using errcode = 'PT410', message = 'Transcript was deleted';
    end if;
    select * into s from public.ppomi_transcript_turns
      where workspace_id = v_workspace and transcript_id = p_transcript_id and turn_id = p_turn_id;
    if found then
        if s.payload is distinct from p_payload then
            raise exception using errcode = '22023', message = 'Turn identity conflict';
        end if;
        return to_jsonb(s);
    end if;
    select coalesce(max(seq), 0) + 1 into v_seq
      from public.ppomi_transcript_turns
      where workspace_id = v_workspace and transcript_id = p_transcript_id;
    insert into public.ppomi_transcript_turns(
        workspace_id, transcript_id, turn_id, seq, writer_user_id, writer_device_id, payload)
      values (v_workspace, p_transcript_id, p_turn_id, v_seq, v_user, v_device, p_payload)
      returning * into s;
    update public.ppomi_transcripts
      set updated_at = statement_timestamp()
      where workspace_id = v_workspace and id = p_transcript_id;
    return to_jsonb(s);
end;
$$;

create function public.ppomi_transcript_delete(p_transcript_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_workspace uuid; t public.ppomi_transcripts;
begin
    v_workspace := public.ppomi_private_member_workspace();
    if p_transcript_id is null then
        raise exception using errcode = '22023', message = 'Transcript ID required';
    end if;
    perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(v_workspace::text || ':transcript:' || p_transcript_id::text, 0));
    select * into t from public.ppomi_transcripts
      where workspace_id = v_workspace and id = p_transcript_id for update;
    if not found then
        raise exception using errcode = 'PT404', message = 'Transcript unavailable';
    end if;
    if t.deleted_at is null then
        update public.ppomi_transcript_turns
          set payload = '{}'::jsonb
          where workspace_id = v_workspace and transcript_id = p_transcript_id
            and payload <> '{}'::jsonb;
        update public.ppomi_transcripts
          set deleted_at = statement_timestamp(), updated_at = statement_timestamp()
          where workspace_id = v_workspace and id = p_transcript_id;
    end if;
    return jsonb_build_object('deleted', true);
end;
$$;

create function public.ppomi_transcript_turn_immutable()
returns trigger language plpgsql set search_path = '' as $$
begin
    if tg_op = 'DELETE' then
        raise exception using errcode = '55000', message = 'Transcript turns use tombstones';
    end if;
    if (new.workspace_id, new.transcript_id, new.turn_id, new.seq, new.writer_user_id,
        new.writer_device_id, new.created_at)
       is distinct from (old.workspace_id, old.transcript_id, old.turn_id, old.seq, old.writer_user_id,
        old.writer_device_id, old.created_at)
       or old.payload = '{}'::jsonb
       or new.payload <> '{}'::jsonb then
        raise exception using errcode = '55000', message = 'Transcript turns are append-only';
    end if;
    return new;
end;
$$;
create trigger ppomi_transcript_turn_preserve
    before update or delete on public.ppomi_transcript_turns
    for each row execute function public.ppomi_transcript_turn_immutable();

create function public.ppomi_transcript_immutable()
returns trigger language plpgsql set search_path = '' as $$
begin
    if tg_op = 'DELETE' then
        raise exception using errcode = '55000', message = 'Transcripts use tombstones';
    end if;
    if (new.workspace_id, new.id, new.created_by_user_id, new.created_by_device_id, new.created_at)
       is distinct from (old.workspace_id, old.id, old.created_by_user_id, old.created_by_device_id, old.created_at)
       or old.deleted_at is not null
       or (new.deleted_at is null and new.updated_at < old.updated_at) then
        raise exception using errcode = '55000', message = 'Transcript identity is immutable';
    end if;
    return new;
end;
$$;
create trigger ppomi_transcript_preserve
    before update or delete on public.ppomi_transcripts
    for each row execute function public.ppomi_transcript_immutable();

revoke all on table public.ppomi_transcripts, public.ppomi_transcript_turns from public, anon, authenticated;
grant select on table public.ppomi_transcripts, public.ppomi_transcript_turns to authenticated;
revoke all on function public.ppomi_is_workspace_member(uuid),
    public.ppomi_private_member_workspace(),
    public.ppomi_private_optional_device_id(uuid),
    public.ppomi_transcript_payload_valid(jsonb, uuid),
    public.ppomi_transcript_open(uuid),
    public.ppomi_transcript_list(),
    public.ppomi_transcript_turns(uuid, bigint),
    public.ppomi_transcript_append(uuid, uuid, jsonb),
    public.ppomi_transcript_delete(uuid),
    public.ppomi_transcript_turn_immutable(),
    public.ppomi_transcript_immutable()
    from public, anon, authenticated;
grant execute on function public.ppomi_is_workspace_member(uuid),
    public.ppomi_transcript_open(uuid),
    public.ppomi_transcript_list(),
    public.ppomi_transcript_turns(uuid, bigint),
    public.ppomi_transcript_append(uuid, uuid, jsonb),
    public.ppomi_transcript_delete(uuid)
    to authenticated;

do $$
begin
    if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
        if not exists (
            select 1 from pg_publication_rel prel
            join pg_class c on c.oid = prel.prrelid
            join pg_namespace n on n.oid = c.relnamespace
            where prel.prpubid = (select oid from pg_publication where pubname = 'supabase_realtime')
              and n.nspname = 'public' and c.relname = 'ppomi_transcripts') then
            execute 'alter publication supabase_realtime add table public.ppomi_transcripts';
        end if;
        if not exists (
            select 1 from pg_publication_rel prel
            join pg_class c on c.oid = prel.prrelid
            join pg_namespace n on n.oid = c.relnamespace
            where prel.prpubid = (select oid from pg_publication where pubname = 'supabase_realtime')
              and n.nspname = 'public' and c.relname = 'ppomi_transcript_turns') then
            execute 'alter publication supabase_realtime add table public.ppomi_transcript_turns';
        end if;
    end if;
end $$;

comment on table public.ppomi_transcripts is
    'Conversation heads. Auth members of the workspace may read and write. Tombstone delete only.';
comment on table public.ppomi_transcript_turns is
    'Append-only conversation turns. Payload is turn JSON the server can read; Realtime pushes the same row.';
