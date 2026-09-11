-- End-to-end encrypted chat transcripts. Separate from ledger records
-- (ppomi_record_*) and from server-decryptable agent memories
-- (ppomi_agent_memories). The server stores ciphertext only.
--
-- Writes go through client RPCs after the device encrypts. Agent
-- /v1/session and /v1/responses stay ephemeral.
-- Approved enrolled devices — including web — may read and write.
-- Realtime subscribers see INSERT/UPDATE ciphertext; plaintext never
-- leaves the device.

create table public.ppomi_transcripts (
    workspace_id uuid not null references public.ppomi_workspaces(id),
    id uuid not null,
    created_by_device_id uuid not null,
    key_id uuid not null,
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
    writer_device_id uuid not null,
    key_id uuid not null,
    envelope jsonb not null,
    created_at timestamptz not null default statement_timestamp(),
    primary key (workspace_id, transcript_id, turn_id),
    unique (workspace_id, transcript_id, seq),
    foreign key (workspace_id, transcript_id) references public.ppomi_transcripts(workspace_id, id),
    foreign key (workspace_id, writer_device_id) references public.ppomi_devices(workspace_id, id),
    check (jsonb_typeof(envelope) = 'object' and octet_length(envelope::text) <= 56000)
);
create index ppomi_transcript_turns_seq_idx
    on public.ppomi_transcript_turns (workspace_id, transcript_id, seq);

alter table public.ppomi_transcripts enable row level security;
alter table public.ppomi_transcript_turns enable row level security;

-- Realtime and direct SELECT do not carry X-Ppomi-Device. Any approved,
-- non-revoked device of the signed-in account may see workspace ciphertext.
-- Writes still go through RPCs that resolve the header device.
create policy ppomi_transcript_read on public.ppomi_transcripts for select to authenticated
    using (exists (
        select 1 from public.ppomi_devices d
        where d.workspace_id = ppomi_transcripts.workspace_id
          and d.auth_user_id = auth.uid()
          and d.revoked_at is null
          and d.approved_at is not null));
create policy ppomi_transcript_turn_read on public.ppomi_transcript_turns for select to authenticated
    using (exists (
        select 1 from public.ppomi_devices d
        where d.workspace_id = ppomi_transcript_turns.workspace_id
          and d.auth_user_id = auth.uid()
          and d.revoked_at is null
          and d.approved_at is not null));

create function public.ppomi_transcript_envelope_valid(p_envelope jsonb)
returns boolean language sql immutable set search_path = '' as $$
    select p_envelope is not null
       and jsonb_typeof(p_envelope) = 'object'
       and octet_length(p_envelope::text) <= 56000
       and (p_envelope ?& array['version', 'nonce', 'ciphertext', 'tag'])
       and not exists (select 1 from jsonb_object_keys(p_envelope) k
                       where k not in ('version', 'nonce', 'ciphertext', 'tag'))
       and p_envelope->'version' = '1'::jsonb
       and jsonb_typeof(p_envelope->'nonce') = 'string'
       and (p_envelope->>'nonce') ~ '^[A-Za-z0-9_-]{16}$'
       and jsonb_typeof(p_envelope->'tag') = 'string'
       and (p_envelope->>'tag') ~ '^[A-Za-z0-9_-]{22}$'
       and jsonb_typeof(p_envelope->'ciphertext') = 'string'
       and (p_envelope->>'ciphertext') ~ '^[A-Za-z0-9_-]+$'
       and length(p_envelope->>'ciphertext') between 1 and 48000;
$$;

create function public.ppomi_transcript_require_key(p_device public.ppomi_devices, p_key_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
    if p_key_id is null then
        raise exception using errcode = '22023', message = 'Transcript key required';
    end if;
    if not exists (
        select 1 from public.ppomi_wrapped_keys w
        where w.workspace_id = p_device.workspace_id
          and w.device_id = p_device.id
          and w.key_id = p_key_id) then
        raise exception using errcode = '42501', message = 'Wrapped transcript key required';
    end if;
end;
$$;

create function public.ppomi_transcript_open(p_transcript_id uuid, p_key_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare d public.ppomi_devices; t public.ppomi_transcripts;
begin
    d := public.ppomi_private_approved_device();
    if p_transcript_id is null then
        raise exception using errcode = '22023', message = 'Transcript ID required';
    end if;
    perform public.ppomi_transcript_require_key(d, p_key_id);
    perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(d.workspace_id::text || ':transcript', 0));
    select * into t from public.ppomi_transcripts
      where workspace_id = d.workspace_id and deleted_at is null
      order by created_at desc, id limit 1;
    if found then return to_jsonb(t); end if;
    select * into t from public.ppomi_transcripts
      where workspace_id = d.workspace_id and id = p_transcript_id;
    if found then
        if t.deleted_at is not null then
            raise exception using errcode = 'PT410', message = 'Transcript was deleted';
        end if;
        return to_jsonb(t);
    end if;
    insert into public.ppomi_transcripts(workspace_id, id, created_by_device_id, key_id)
      values (d.workspace_id, p_transcript_id, d.id, p_key_id)
      returning * into t;
    return to_jsonb(t);
end;
$$;

create function public.ppomi_transcript_list()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare d public.ppomi_devices;
begin
    d := public.ppomi_private_approved_device();
    return coalesce((
        select jsonb_agg(jsonb_build_object(
            'id', t.id,
            'workspace_id', t.workspace_id,
            'created_by_device_id', t.created_by_device_id,
            'key_id', t.key_id,
            'created_at', t.created_at,
            'updated_at', t.updated_at,
            'last_seq', coalesce((
                select max(s.seq) from public.ppomi_transcript_turns s
                where s.workspace_id = t.workspace_id and s.transcript_id = t.id
                  and s.envelope <> '{}'::jsonb), 0)
        ) order by t.created_at desc, t.id)
        from (
            select * from public.ppomi_transcripts
            where workspace_id = d.workspace_id and deleted_at is null
            order by created_at desc, id limit 50
        ) t
    ), '[]'::jsonb);
end;
$$;

create function public.ppomi_transcript_turns(p_transcript_id uuid, p_after_seq bigint default 0)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare d public.ppomi_devices; t public.ppomi_transcripts;
begin
    d := public.ppomi_private_approved_device();
    if p_transcript_id is null or p_after_seq is null or p_after_seq < 0 then
        raise exception using errcode = '22023', message = 'Invalid transcript query';
    end if;
    select * into t from public.ppomi_transcripts
      where workspace_id = d.workspace_id and id = p_transcript_id;
    if not found or t.deleted_at is not null then
        return jsonb_build_object('found', false, 'turns', '[]'::jsonb);
    end if;
    return jsonb_build_object(
        'found', true,
        'transcript_id', t.id,
        'workspace_id', t.workspace_id,
        'key_id', t.key_id,
        'deleted', false,
        'turns', coalesce((
            select jsonb_agg(jsonb_build_object(
                'turn_id', s.turn_id,
                'seq', s.seq,
                'writer_device_id', s.writer_device_id,
                'key_id', s.key_id,
                'envelope', s.envelope,
                'created_at', s.created_at
            ) order by s.seq, s.turn_id)
            from (
                select * from public.ppomi_transcript_turns
                where workspace_id = d.workspace_id
                  and transcript_id = p_transcript_id
                  and seq > p_after_seq
                  and envelope <> '{}'::jsonb
                order by seq, turn_id limit 200
            ) s
        ), '[]'::jsonb));
end;
$$;

create function public.ppomi_transcript_append(
    p_transcript_id uuid, p_turn_id uuid, p_key_id uuid, p_envelope jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare d public.ppomi_devices; t public.ppomi_transcripts; s public.ppomi_transcript_turns; v_seq bigint;
begin
    d := public.ppomi_private_approved_device();
    if p_transcript_id is null or p_turn_id is null then
        raise exception using errcode = '22023', message = 'Transcript turn identity required';
    end if;
    perform public.ppomi_transcript_require_key(d, p_key_id);
    if not public.ppomi_transcript_envelope_valid(p_envelope) then
        raise exception using errcode = '22023', message = 'Invalid encrypted transcript envelope';
    end if;
    perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(d.workspace_id::text || ':transcript:' || p_transcript_id::text, 0));
    select * into t from public.ppomi_transcripts
      where workspace_id = d.workspace_id and id = p_transcript_id for update;
    if not found then
        raise exception using errcode = 'PT404', message = 'Transcript unavailable';
    end if;
    if t.deleted_at is not null then
        raise exception using errcode = 'PT410', message = 'Transcript was deleted';
    end if;
    select * into s from public.ppomi_transcript_turns
      where workspace_id = d.workspace_id and transcript_id = p_transcript_id and turn_id = p_turn_id;
    if found then
        if s.key_id is distinct from p_key_id or s.envelope is distinct from p_envelope then
            raise exception using errcode = '22023', message = 'Turn identity conflict';
        end if;
        return to_jsonb(s);
    end if;
    select coalesce(max(seq), 0) + 1 into v_seq
      from public.ppomi_transcript_turns
      where workspace_id = d.workspace_id and transcript_id = p_transcript_id;
    insert into public.ppomi_transcript_turns(
        workspace_id, transcript_id, turn_id, seq, writer_device_id, key_id, envelope)
      values (d.workspace_id, p_transcript_id, p_turn_id, v_seq, d.id, p_key_id, p_envelope)
      returning * into s;
    update public.ppomi_transcripts
      set updated_at = statement_timestamp()
      where workspace_id = d.workspace_id and id = p_transcript_id;
    return to_jsonb(s);
end;
$$;

create function public.ppomi_transcript_delete(p_transcript_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare d public.ppomi_devices; t public.ppomi_transcripts;
begin
    d := public.ppomi_private_approved_device();
    if p_transcript_id is null then
        raise exception using errcode = '22023', message = 'Transcript ID required';
    end if;
    perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(d.workspace_id::text || ':transcript:' || p_transcript_id::text, 0));
    select * into t from public.ppomi_transcripts
      where workspace_id = d.workspace_id and id = p_transcript_id for update;
    if not found then
        raise exception using errcode = 'PT404', message = 'Transcript unavailable';
    end if;
    if t.deleted_at is null then
        update public.ppomi_transcript_turns
          set envelope = '{}'::jsonb
          where workspace_id = d.workspace_id and transcript_id = p_transcript_id
            and envelope <> '{}'::jsonb;
        update public.ppomi_transcripts
          set deleted_at = statement_timestamp(), updated_at = statement_timestamp()
          where workspace_id = d.workspace_id and id = p_transcript_id;
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
    if (new.workspace_id, new.transcript_id, new.turn_id, new.seq, new.writer_device_id, new.key_id, new.created_at)
       is distinct from (old.workspace_id, old.transcript_id, old.turn_id, old.seq, old.writer_device_id, old.key_id, old.created_at)
       or old.envelope = '{}'::jsonb
       or new.envelope <> '{}'::jsonb then
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
    if (new.workspace_id, new.id, new.created_by_device_id, new.key_id, new.created_at)
       is distinct from (old.workspace_id, old.id, old.created_by_device_id, old.key_id, old.created_at)
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
revoke all on function public.ppomi_transcript_envelope_valid(jsonb),
    public.ppomi_transcript_require_key(public.ppomi_devices, uuid),
    public.ppomi_transcript_open(uuid, uuid),
    public.ppomi_transcript_list(),
    public.ppomi_transcript_turns(uuid, bigint),
    public.ppomi_transcript_append(uuid, uuid, uuid, jsonb),
    public.ppomi_transcript_delete(uuid),
    public.ppomi_transcript_turn_immutable(),
    public.ppomi_transcript_immutable()
    from public, anon, authenticated;
grant execute on function public.ppomi_transcript_open(uuid, uuid),
    public.ppomi_transcript_list(),
    public.ppomi_transcript_turns(uuid, bigint),
    public.ppomi_transcript_append(uuid, uuid, uuid, jsonb),
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
    'E2E conversation heads. Ciphertext lives on turns; server cannot read plaintext. Tombstone delete only.';
comment on table public.ppomi_transcript_turns is
    'Append-only E2E conversation turns. Clients encrypt before upload; Realtime pushes ciphertext.';
