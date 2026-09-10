-- Device-authenticated shared control records. Workspace membership is an access
-- boundary, not an accounting owner, book, or personal/business RecordScope.
-- Devices execute locally. The database never reassigns or replays a run.

create table public.ppomi_workspaces (
    id uuid primary key default pg_catalog.gen_random_uuid(),
    name text not null check (char_length(name) between 1 and 120),
    created_at timestamptz not null default statement_timestamp()
);

create table public.ppomi_devices (
    id uuid primary key default pg_catalog.gen_random_uuid(),
    workspace_id uuid not null references public.ppomi_workspaces(id),
    auth_user_id uuid not null unique references auth.users(id),
    label text not null check (char_length(label) between 1 and 120),
    platform text not null check (platform in ('macos', 'android')),
    revoked_at timestamptz,
    created_at timestamptz not null default statement_timestamp(),
    unique (workspace_id, id)
);

create table public.ppomi_documents (
    workspace_id uuid not null references public.ppomi_workspaces(id),
    id text not null check (id ~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$'),
    kind text not null check (kind in ('playbook', 'rule')),
    title text not null check (char_length(title) between 1 and 200),
    body jsonb not null check (jsonb_typeof(body) = 'object' and octet_length(body::text) <= 65536),
    version bigint not null check (version > 0),
    archived boolean not null default false,
    created_by_device_id uuid not null,
    updated_by_device_id uuid not null,
    created_at timestamptz not null default statement_timestamp(),
    updated_at timestamptz not null default statement_timestamp(),
    primary key (workspace_id, id),
    foreign key (workspace_id, created_by_device_id) references public.ppomi_devices(workspace_id, id),
    foreign key (workspace_id, updated_by_device_id) references public.ppomi_devices(workspace_id, id)
);

create table public.ppomi_runs (
    id uuid primary key,
    workspace_id uuid not null references public.ppomi_workspaces(id),
    executor_device_id uuid not null,
    created_by_device_id uuid not null,
    request text not null check (char_length(request) between 1 and 2000 and btrim(request) <> ''),
    mode text not null default 'builtin' check (mode = 'builtin'),
    state text not null check (state in ('queued', 'running', 'waiting_approval', 'completed', 'failed', 'cancelled', 'interrupted')),
    version bigint not null check (version > 0),
    summary text not null default '' check (char_length(summary) <= 2000),
    created_at timestamptz not null default statement_timestamp(),
    updated_at timestamptz not null default statement_timestamp(),
    started_at timestamptz,
    finished_at timestamptz,
    unique (workspace_id, id),
    foreign key (workspace_id, executor_device_id) references public.ppomi_devices(workspace_id, id),
    foreign key (workspace_id, created_by_device_id) references public.ppomi_devices(workspace_id, id)
);
create index ppomi_runs_workspace_created_idx on public.ppomi_runs(workspace_id, created_at desc, id);

create table public.ppomi_run_events (
    seq bigint generated always as identity primary key,
    event_id uuid not null,
    workspace_id uuid not null,
    run_id uuid not null,
    device_id uuid not null,
    kind text not null check (kind ~ '^[a-z][a-z0-9_]{0,63}$'),
    state text not null check (state in ('queued', 'running', 'waiting_approval', 'completed', 'failed', 'cancelled', 'interrupted')),
    summary text not null check (char_length(summary) <= 2000),
    data jsonb not null check (jsonb_typeof(data) = 'object' and octet_length(data::text) <= 4096),
    expected_version bigint not null check (expected_version >= 0),
    version bigint not null check (version > 0),
    created_at timestamptz not null default statement_timestamp(),
    unique (workspace_id, event_id),
    foreign key (workspace_id, run_id) references public.ppomi_runs(workspace_id, id),
    foreign key (workspace_id, device_id) references public.ppomi_devices(workspace_id, id)
);
create index ppomi_run_events_run_seq_idx on public.ppomi_run_events(workspace_id, run_id, seq);

-- Stored atomically with each operation. An identical retry returns the original
-- response, even after subsequent changes; a reused ID with other input fails.
create table public.ppomi_operations (
    workspace_id uuid not null references public.ppomi_workspaces(id),
    operation_kind text not null check (operation_kind in ('create_run', 'put_document', 'run_event')),
    operation_id uuid not null,
    request jsonb not null,
    response jsonb not null,
    created_at timestamptz not null default statement_timestamp(),
    primary key (workspace_id, operation_kind, operation_id)
);

create function public.ppomi_private_device()
returns public.ppomi_devices language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices;
begin
    if auth.uid() is null then
        raise exception using errcode = '42501', message = 'Authenticated device required';
    end if;
    select * into v_device from public.ppomi_devices
      where auth_user_id = auth.uid() and revoked_at is null for share;
    if not found then
        raise exception using errcode = '42501', message = 'Active registered device required';
    end if;
    return v_device;
end;
$$;

-- This is the only helper exposed to authenticated users, for SELECT policies.
create function public.ppomi_current_workspace_id()
returns uuid language plpgsql security definer set search_path = '' as $$
begin
    return (public.ppomi_private_device()).workspace_id;
end;
$$;

alter table public.ppomi_workspaces enable row level security;
alter table public.ppomi_devices enable row level security;
alter table public.ppomi_documents enable row level security;
alter table public.ppomi_runs enable row level security;
alter table public.ppomi_run_events enable row level security;
alter table public.ppomi_operations enable row level security;
create policy ppomi_workspace_read on public.ppomi_workspaces for select to authenticated
    using (id = (select public.ppomi_current_workspace_id()));
create policy ppomi_device_read on public.ppomi_devices for select to authenticated
    using (workspace_id = (select public.ppomi_current_workspace_id()));
create policy ppomi_document_read on public.ppomi_documents for select to authenticated
    using (workspace_id = (select public.ppomi_current_workspace_id()));
create policy ppomi_run_read on public.ppomi_runs for select to authenticated
    using (workspace_id = (select public.ppomi_current_workspace_id()));
create policy ppomi_event_read on public.ppomi_run_events for select to authenticated
    using (workspace_id = (select public.ppomi_current_workspace_id()));

create function public.ppomi_private_immutable_event()
returns trigger language plpgsql set search_path = '' as $$
begin
    raise exception using errcode = '55000', message = 'Run events are append-only';
end;
$$;
create trigger ppomi_events_append_only before update or delete on public.ppomi_run_events
    for each row execute function public.ppomi_private_immutable_event();

create function public.ppomi_private_fixed_run_identity()
returns trigger language plpgsql set search_path = '' as $$
begin
    if (new.id, new.workspace_id, new.executor_device_id, new.created_by_device_id, new.request, new.mode, new.created_at)
       is distinct from
       (old.id, old.workspace_id, old.executor_device_id, old.created_by_device_id, old.request, old.mode, old.created_at) then
        raise exception using errcode = '55000', message = 'Run identity and executor are immutable';
    end if;
    return new;
end;
$$;
create trigger ppomi_run_fixed_identity before update on public.ppomi_runs
    for each row execute function public.ppomi_private_fixed_run_identity();

create function public.ppomi_context()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices;
begin
    v_device := public.ppomi_private_device();
    return jsonb_build_object(
      'workspace', (select jsonb_build_object('id', id, 'name', name) from public.ppomi_workspaces where id = v_device.workspace_id),
      'device', jsonb_build_object('id', v_device.id, 'label', v_device.label, 'platform', v_device.platform),
      'devices', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'label', label, 'platform', platform) order by created_at, id), '[]'::jsonb)
                  from public.ppomi_devices where workspace_id = v_device.workspace_id and revoked_at is null));
end;
$$;

create function public.ppomi_list_runs(p_limit int default 50)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices;
begin
    v_device := public.ppomi_private_device();
    if p_limit is null or p_limit < 1 or p_limit > 200 then
        raise exception using errcode = '22023', message = 'Limit must be between 1 and 200';
    end if;
    return (select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc, r.id), '[]'::jsonb)
      from (select * from public.ppomi_runs where workspace_id = v_device.workspace_id
            order by created_at desc, id limit p_limit) r);
end;
$$;

create function public.ppomi_get_run(p_run_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices; v_run public.ppomi_runs;
begin
    v_device := public.ppomi_private_device();
    select * into v_run from public.ppomi_runs where id = p_run_id and workspace_id = v_device.workspace_id;
    if not found then
        raise exception using errcode = 'P0002', message = 'Run not found in this workspace';
    end if;
    return jsonb_build_object('run', to_jsonb(v_run), 'events',
      (select coalesce(jsonb_agg(to_jsonb(e) order by e.seq), '[]'::jsonb)
         from public.ppomi_run_events e where run_id = p_run_id and workspace_id = v_device.workspace_id));
end;
$$;

create function public.ppomi_create_run(p_run_id uuid, p_executor_device_id uuid, p_request text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices; v_request jsonb; v_op public.ppomi_operations; v_run public.ppomi_runs;
begin
    v_device := public.ppomi_private_device();
    if p_run_id is null or p_executor_device_id is null or p_request is null
       or char_length(p_request) not between 1 and 2000 or btrim(p_request) = '' then
        raise exception using errcode = '22023', message = 'Run ID, executor and request (1..2000 characters) are required';
    end if;
    v_request := jsonb_build_object('run_id', p_run_id, 'executor_device_id', p_executor_device_id, 'request', p_request);
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_device.workspace_id::text || ':create_run:' || p_run_id::text, 0));
    select * into v_op from public.ppomi_operations where workspace_id = v_device.workspace_id and operation_kind = 'create_run' and operation_id = p_run_id;
    if found then
        if v_op.request <> v_request then
            raise exception using errcode = '22023', message = 'Run ID was already used with different input';
        end if;
        return v_op.response;
    end if;
    perform 1 from public.ppomi_devices where id = p_executor_device_id
       and workspace_id = v_device.workspace_id and revoked_at is null for share;
    if not found then
        raise exception using errcode = '42501', message = 'Executor must be an active device in this workspace';
    end if;
    -- UUID collision across workspaces is hidden as an unavailable ID.
    if exists (select 1 from public.ppomi_runs where id = p_run_id) then
        raise exception using errcode = '22023', message = 'Run ID is unavailable';
    end if;
    insert into public.ppomi_runs(id, workspace_id, executor_device_id, created_by_device_id, request, state, version)
      values (p_run_id, v_device.workspace_id, p_executor_device_id, v_device.id, p_request, 'queued', 1) returning * into v_run;
    insert into public.ppomi_run_events(event_id, workspace_id, run_id, device_id, kind, state, summary, data, expected_version, version)
      values (pg_catalog.gen_random_uuid(), v_device.workspace_id, p_run_id, v_device.id, 'created', 'queued', '', '{}'::jsonb, 0, 1);
    insert into public.ppomi_operations(workspace_id, operation_kind, operation_id, request, response)
      values (v_device.workspace_id, 'create_run', p_run_id, v_request, to_jsonb(v_run));
    return to_jsonb(v_run);
end;
$$;

create function public.ppomi_claim_run(p_run_id uuid, p_expected_version bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices; v_run public.ppomi_runs;
begin
    v_device := public.ppomi_private_device();
    select * into v_run from public.ppomi_runs where id = p_run_id and workspace_id = v_device.workspace_id for update;
    if not found then
        raise exception using errcode = 'P0002', message = 'Run not found in this workspace';
    end if;
    if v_run.executor_device_id <> v_device.id then
        raise exception using errcode = '42501', message = 'Only the assigned executor may claim this run';
    end if;
    if p_expected_version is null or v_run.version <> p_expected_version or v_run.state <> 'queued' then
        raise exception using errcode = '40001', message = 'Run is no longer queued at the expected version; inspect its state before recovery';
    end if;
    update public.ppomi_runs set state = 'running', version = version + 1, started_at = statement_timestamp(), updated_at = statement_timestamp()
      where id = p_run_id returning * into v_run;
    insert into public.ppomi_run_events(event_id, workspace_id, run_id, device_id, kind, state, summary, data, expected_version, version)
      values (pg_catalog.gen_random_uuid(), v_device.workspace_id, p_run_id, v_device.id, 'claimed', 'running', '', '{}'::jsonb, p_expected_version, v_run.version);
    return to_jsonb(v_run);
end;
$$;

create function public.ppomi_append_run_event(
    p_run_id uuid, p_event_id uuid, p_expected_version bigint, p_state text,
    p_kind text, p_summary text, p_data jsonb
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices; v_run public.ppomi_runs; v_event public.ppomi_run_events;
        v_request jsonb; v_op public.ppomi_operations; v_response jsonb; v_allowed boolean;
begin
    v_device := public.ppomi_private_device();
    if p_run_id is null or p_event_id is null or p_expected_version is null or p_expected_version < 1
       or p_state is null or p_state not in ('queued', 'running', 'waiting_approval', 'completed', 'failed', 'cancelled', 'interrupted')
       or p_kind is null or p_kind !~ '^[a-z][a-z0-9_]{0,63}$'
       or p_summary is null or char_length(p_summary) > 2000
       or p_data is null or jsonb_typeof(p_data) <> 'object' or octet_length(p_data::text) > 4096 then
        raise exception using errcode = '22023', message = 'Invalid event input';
    end if;
    if exists (select 1 from jsonb_object_keys(p_data) k
                where k not in ('evidence_sha256', 'evidence_ref', 'local_task_id', 'user_action'))
       or (p_data ? 'evidence_sha256' and (jsonb_typeof(p_data->'evidence_sha256') <> 'string' or (p_data->>'evidence_sha256') !~ '^[0-9a-fA-F]{64}$'))
       or (p_data ? 'evidence_ref' and (jsonb_typeof(p_data->'evidence_ref') <> 'string' or (p_data->>'evidence_ref') !~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$'))
       or (p_data ? 'local_task_id' and (jsonb_typeof(p_data->'local_task_id') <> 'string' or (p_data->>'local_task_id') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'))
       or (p_data ? 'user_action' and jsonb_typeof(p_data->'user_action') <> 'boolean') then
        raise exception using errcode = '22023', message = 'Event data accepts only opaque evidence references, SHA-256, task UUID and user action flag';
    end if;
    v_request := jsonb_build_object('run_id', p_run_id, 'event_id', p_event_id, 'expected_version', p_expected_version,
      'state', p_state, 'kind', p_kind, 'summary', p_summary, 'data', p_data);
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_device.workspace_id::text || ':run_event:' || p_event_id::text, 0));
    select * into v_run from public.ppomi_runs where id = p_run_id and workspace_id = v_device.workspace_id for update;
    if not found then
        raise exception using errcode = 'P0002', message = 'Run not found in this workspace';
    end if;
    if v_run.executor_device_id <> v_device.id then
        raise exception using errcode = '42501', message = 'Only the assigned executor may publish execution events';
    end if;
    select * into v_op from public.ppomi_operations where workspace_id = v_device.workspace_id and operation_kind = 'run_event' and operation_id = p_event_id;
    if found then
        if v_op.request <> v_request then
            raise exception using errcode = '22023', message = 'Event ID was already used with different input';
        end if;
        return v_op.response;
    end if;
    if v_run.version <> p_expected_version then
        raise exception using errcode = '40001', message = 'Run version conflict';
    end if;
    if v_run.state in ('completed', 'failed', 'cancelled') then
        raise exception using errcode = '55000', message = 'Terminal runs are immutable';
    end if;
    v_allowed := p_state = v_run.state;
    if v_run.state = 'queued' then
        -- Starting is exclusively a claim CAS, not an ordinary event.
        v_allowed := p_state in ('queued', 'cancelled');
    elsif v_run.state = 'running' then
        v_allowed := p_state in ('running', 'waiting_approval', 'completed', 'failed', 'cancelled', 'interrupted');
    elsif v_run.state = 'waiting_approval' then
        v_allowed := p_state in ('waiting_approval', 'failed', 'cancelled', 'interrupted')
          or (p_state = 'running' and p_kind = 'approval' and p_data->'user_action' = 'true'::jsonb);
    elsif v_run.state = 'interrupted' then
        v_allowed := p_state in ('interrupted', 'cancelled')
          or (p_state = 'running' and p_kind = 'resume' and p_data->'user_action' = 'true'::jsonb);
    end if;
    if v_allowed is not true then
        raise exception using errcode = '55000', message = 'Run state transition is not allowed; approval and resume require explicit executor user action';
    end if;
    update public.ppomi_runs set state = p_state, summary = p_summary, version = version + 1,
      updated_at = statement_timestamp(),
      finished_at = case when p_state in ('completed', 'failed', 'cancelled', 'interrupted') then statement_timestamp() else null end
      where id = p_run_id returning * into v_run;
    insert into public.ppomi_run_events(event_id, workspace_id, run_id, device_id, kind, state, summary, data, expected_version, version)
      values (p_event_id, v_device.workspace_id, p_run_id, v_device.id, p_kind, p_state, p_summary, p_data, p_expected_version, v_run.version)
      returning * into v_event;
    v_response := jsonb_build_object('run', to_jsonb(v_run), 'event', to_jsonb(v_event));
    insert into public.ppomi_operations(workspace_id, operation_kind, operation_id, request, response)
      values (v_device.workspace_id, 'run_event', p_event_id, v_request, v_response);
    return v_response;
end;
$$;

create function public.ppomi_list_documents()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices;
begin
    v_device := public.ppomi_private_device();
    return (select coalesce(jsonb_agg(to_jsonb(d) order by d.updated_at desc, d.id), '[]'::jsonb)
              from public.ppomi_documents d where workspace_id = v_device.workspace_id);
end;
$$;

create function public.ppomi_put_document(
    p_document_id text, p_kind text, p_title text, p_body jsonb,
    p_expected_version bigint, p_operation_id uuid, p_archived boolean default false
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices; v_doc public.ppomi_documents; v_op public.ppomi_operations; v_request jsonb;
begin
    v_device := public.ppomi_private_device();
    if p_document_id is null or p_document_id !~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$'
       or p_kind is null or p_kind not in ('playbook', 'rule')
       or p_title is null or char_length(p_title) not between 1 and 200
       or p_body is null or jsonb_typeof(p_body) <> 'object' or octet_length(p_body::text) > 65536
       or p_expected_version is null or p_expected_version < 0 or p_operation_id is null or p_archived is null then
        raise exception using errcode = '22023', message = 'Invalid document input';
    end if;
    v_request := jsonb_build_object('document_id', p_document_id, 'kind', p_kind, 'title', p_title,
      'body', p_body, 'expected_version', p_expected_version, 'archived', p_archived);
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_device.workspace_id::text || ':put_document:' || p_operation_id::text, 0));
    select * into v_op from public.ppomi_operations where workspace_id = v_device.workspace_id and operation_kind = 'put_document' and operation_id = p_operation_id;
    if found then
        if v_op.request <> v_request then
            raise exception using errcode = '22023', message = 'Operation ID was already used with different input';
        end if;
        return v_op.response;
    end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_device.workspace_id::text || ':document:' || p_document_id, 0));
    select * into v_doc from public.ppomi_documents where workspace_id = v_device.workspace_id and id = p_document_id for update;
    if found then
        if v_doc.version <> p_expected_version then
            raise exception using errcode = '40001', message = 'Document version conflict';
        end if;
        update public.ppomi_documents set kind = p_kind, title = p_title, body = p_body, archived = p_archived,
          version = version + 1, updated_by_device_id = v_device.id, updated_at = statement_timestamp()
          where workspace_id = v_device.workspace_id and id = p_document_id returning * into v_doc;
    else
        if p_expected_version <> 0 then
            raise exception using errcode = '40001', message = 'Document does not exist at the expected version';
        end if;
        insert into public.ppomi_documents(workspace_id, id, kind, title, body, version, archived, created_by_device_id, updated_by_device_id)
          values (v_device.workspace_id, p_document_id, p_kind, p_title, p_body, 1, p_archived, v_device.id, v_device.id) returning * into v_doc;
    end if;
    insert into public.ppomi_operations(workspace_id, operation_kind, operation_id, request, response)
      values (v_device.workspace_id, 'put_document', p_operation_id, v_request, to_jsonb(v_doc));
    return to_jsonb(v_doc);
end;
$$;

-- PostgreSQL otherwise gives new functions PUBLIC EXECUTE; Supabase may also
-- grant authenticated table writes by default. Remove both explicitly.
revoke all on table public.ppomi_workspaces, public.ppomi_devices, public.ppomi_documents,
  public.ppomi_runs, public.ppomi_run_events, public.ppomi_operations from public, anon, authenticated;
revoke all on sequence public.ppomi_run_events_seq_seq from public, anon, authenticated;
grant select on table public.ppomi_workspaces, public.ppomi_documents, public.ppomi_runs, public.ppomi_run_events to authenticated;
grant select (id, workspace_id, label, platform, revoked_at, created_at) on public.ppomi_devices to authenticated;

revoke all on function public.ppomi_private_device(), public.ppomi_current_workspace_id(),
  public.ppomi_private_immutable_event(), public.ppomi_private_fixed_run_identity(), public.ppomi_context(),
  public.ppomi_list_runs(int), public.ppomi_get_run(uuid), public.ppomi_create_run(uuid,uuid,text),
  public.ppomi_claim_run(uuid,bigint), public.ppomi_append_run_event(uuid,uuid,bigint,text,text,text,jsonb),
  public.ppomi_list_documents(), public.ppomi_put_document(text,text,text,jsonb,bigint,uuid,boolean)
  from public, anon, authenticated;
grant execute on function public.ppomi_current_workspace_id(), public.ppomi_context(),
  public.ppomi_list_runs(int), public.ppomi_get_run(uuid), public.ppomi_create_run(uuid,uuid,text),
  public.ppomi_claim_run(uuid,bigint), public.ppomi_append_run_event(uuid,uuid,bigint,text,text,text,jsonb),
  public.ppomi_list_documents(), public.ppomi_put_document(text,text,text,jsonb,bigint,uuid,boolean)
  to authenticated;

comment on table public.ppomi_workspaces is 'Device access boundary only; does not classify accounting RecordScope or ownership.';
comment on table public.ppomi_run_events is 'Append-only server sequence. Metadata only; raw screenshots and private local paths stay on the executor.';
comment on function public.ppomi_claim_run(uuid,bigint) is 'Claim once at the queued version. On an uncertain response inspect server/local state; never blindly execute again.';
comment on function public.ppomi_append_run_event(uuid,uuid,bigint,text,text,text,jsonb) is 'Executor-only CAS with exact event UUID deduplication. Resume also requires the local client to reject uncertain in-flight actions.';
