-- Opaque, encrypted record revisions. No personal payload, filename, key, or
-- plaintext hash is sent to these tables. Existing source records remain local.
create table public.ppomi_record_blobs (
 workspace_id uuid not null references public.ppomi_workspaces(id),
 hash text not null check (hash ~ '^[0-9a-f]{64}$'),
 data text not null, size integer not null check(size between 28 and 409600),
 created_at timestamptz not null default statement_timestamp(),
 primary key(workspace_id,hash)
);
create table public.ppomi_record_heads (
 workspace_id uuid not null references public.ppomi_workspaces(id),
 record_id uuid not null, writer_device_id uuid not null, key_id uuid not null,
 version bigint not null check(version > 0), chunk_ids jsonb not null,
 created_at timestamptz not null default statement_timestamp(),
 updated_at timestamptz not null default statement_timestamp(),
 primary key(workspace_id,record_id),
 foreign key(workspace_id,writer_device_id) references public.ppomi_devices(workspace_id,id)
);
create table public.ppomi_record_revisions (
 workspace_id uuid not null, record_id uuid not null, version bigint not null,
 head jsonb not null, primary key(workspace_id,record_id,version),
 foreign key(workspace_id,record_id) references public.ppomi_record_heads(workspace_id,record_id)
);
create table public.ppomi_record_operations (
 workspace_id uuid not null references public.ppomi_workspaces(id), operation_id uuid not null,
 request jsonb not null, response jsonb not null, primary key(workspace_id,operation_id)
);
alter table public.ppomi_record_blobs enable row level security;
alter table public.ppomi_record_heads enable row level security;
alter table public.ppomi_record_revisions enable row level security;
alter table public.ppomi_record_operations enable row level security;
create policy ppomi_record_blob_read on public.ppomi_record_blobs for select to authenticated
 using(workspace_id=(select public.ppomi_current_workspace_id()));
create policy ppomi_record_head_read on public.ppomi_record_heads for select to authenticated
 using(workspace_id=(select public.ppomi_current_workspace_id()));
create policy ppomi_record_revision_read on public.ppomi_record_revisions for select to authenticated
 using(workspace_id=(select public.ppomi_current_workspace_id()));

create function public.ppomi_record_blob_put(p_hash text,p_data text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare d public.ppomi_devices; b bytea; old public.ppomi_record_blobs;
begin
 d:=public.ppomi_private_device();
 if p_hash is null or p_hash !~ '^[0-9a-f]{64}$' or p_data is null or length(p_data)>546136
   or p_data !~ '^[A-Za-z0-9+/]+={0,2}$' then
   raise exception using errcode='22023',message='Invalid encrypted blob'; end if;
 b:=decode(p_data,'base64');
 if octet_length(b) not between 28 and 409600 or encode(sha256(b),'hex')<>p_hash
   or replace(encode(b,'base64'),E'\n','')<>p_data then
   raise exception using errcode='22023',message='Invalid encrypted blob digest or size'; end if;
 insert into public.ppomi_record_blobs(workspace_id,hash,data,size) values(d.workspace_id,p_hash,p_data,octet_length(b)) on conflict do nothing;
 select * into old from public.ppomi_record_blobs where workspace_id=d.workspace_id and hash=p_hash;
 if old.data<>p_data then raise exception using errcode='22023',message='Blob identity conflict'; end if;
 return jsonb_build_object('hash',p_hash,'size',old.size);
end; $$;
create function public.ppomi_record_blob_get(p_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare d public.ppomi_devices; b public.ppomi_record_blobs;
begin
 d:=public.ppomi_private_device();
 select * into b from public.ppomi_record_blobs where workspace_id=d.workspace_id and hash=p_hash;
 if not found then raise exception using errcode='P0002',message='Encrypted blob unavailable'; end if;
 return jsonb_build_object('hash',b.hash,'size',b.size,'data',b.data);
end; $$;
create function public.ppomi_record_get(p_record_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare d public.ppomi_devices; h public.ppomi_record_heads;
begin
 d:=public.ppomi_private_device();
 select * into h from public.ppomi_record_heads where workspace_id=d.workspace_id and record_id=p_record_id;
 if not found then return jsonb_build_object('found',false); end if;
 return to_jsonb(h)||jsonb_build_object('found',true);
end; $$;
create function public.ppomi_record_put(p_record_id uuid,p_expected_version bigint,p_operation_id uuid,p_key_id uuid,p_chunk_ids jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.ppomi_devices; h public.ppomi_record_heads; o public.ppomi_record_operations; r jsonb; reply jsonb;
begin
 d:=public.ppomi_private_device();
 if p_record_id is null or p_operation_id is null or p_key_id is null or p_expected_version is null or p_expected_version<0
   or p_chunk_ids is null or jsonb_typeof(p_chunk_ids)<>'array' then
   raise exception using errcode='22023',message='Invalid encrypted revision'; end if;
 if jsonb_array_length(p_chunk_ids) not between 1 and 1024 or exists(select 1 from jsonb_array_elements(p_chunk_ids) x
   where jsonb_typeof(x)<>'string' or (x#>>'{}') !~ '^[0-9a-f]{64}$') then
   raise exception using errcode='22023',message='Invalid encrypted chunks'; end if;
 r:=jsonb_build_object('writer',d.id,'record_id',p_record_id,'expected_version',p_expected_version,'key_id',p_key_id,'chunk_ids',p_chunk_ids);
 perform pg_advisory_xact_lock(hashtextextended(d.workspace_id::text||':record-op:'||p_operation_id::text,0));
 select * into o from public.ppomi_record_operations where workspace_id=d.workspace_id and operation_id=p_operation_id;
 if found then
   if o.request<>r then raise exception using errcode='22023',message='Operation identity conflict'; end if;
   return o.response;
 end if;
 perform pg_advisory_xact_lock(hashtextextended(d.workspace_id::text||':record:'||p_record_id::text,0));
 if exists(select 1 from jsonb_array_elements_text(p_chunk_ids) x where not exists
   (select 1 from public.ppomi_record_blobs b where b.workspace_id=d.workspace_id and b.hash=x)) then
   raise exception using errcode='22023',message='Encrypted chunks missing'; end if;
 select * into h from public.ppomi_record_heads where workspace_id=d.workspace_id and record_id=p_record_id for update;
 if found then
   if h.writer_device_id<>d.id then raise exception using errcode='42501',message='Only assigned record writer may publish'; end if;
   if h.version<>p_expected_version then raise exception using errcode='40001',message='Record version conflict'; end if;
   update public.ppomi_record_heads set version=version+1,key_id=p_key_id,chunk_ids=p_chunk_ids,updated_at=statement_timestamp()
     where workspace_id=d.workspace_id and record_id=p_record_id returning * into h;
 else
   if p_expected_version<>0 then raise exception using errcode='40001',message='Record version conflict'; end if;
   insert into public.ppomi_record_heads(workspace_id,record_id,writer_device_id,key_id,version,chunk_ids)
     values(d.workspace_id,p_record_id,d.id,p_key_id,1,p_chunk_ids) returning * into h;
 end if;
 reply:=to_jsonb(h)||jsonb_build_object('found',true);
 insert into public.ppomi_record_revisions values(d.workspace_id,p_record_id,h.version,reply);
 insert into public.ppomi_record_operations values(d.workspace_id,p_operation_id,r,reply);
 return reply;
end; $$;
create function public.ppomi_record_immutable() returns trigger language plpgsql set search_path='' as $$
begin raise exception using errcode='55000',message='Encrypted revision history is immutable'; end; $$;
create trigger ppomi_record_blob_immutable before update or delete on public.ppomi_record_blobs for each row execute function public.ppomi_record_immutable();
create trigger ppomi_record_revision_immutable before update or delete on public.ppomi_record_revisions for each row execute function public.ppomi_record_immutable();
create trigger ppomi_record_operation_immutable before update or delete on public.ppomi_record_operations for each row execute function public.ppomi_record_immutable();
revoke all on public.ppomi_record_blobs,public.ppomi_record_heads,public.ppomi_record_revisions,public.ppomi_record_operations from public,anon,authenticated;
grant select on public.ppomi_record_blobs,public.ppomi_record_heads,public.ppomi_record_revisions to authenticated;
revoke all on function public.ppomi_record_blob_put(text,text),public.ppomi_record_blob_get(text),public.ppomi_record_get(uuid),
 public.ppomi_record_put(uuid,bigint,uuid,uuid,jsonb),public.ppomi_record_immutable() from public,anon,authenticated;
grant execute on function public.ppomi_record_blob_put(text,text),public.ppomi_record_blob_get(text),public.ppomi_record_get(uuid),
 public.ppomi_record_put(uuid,bigint,uuid,uuid,jsonb) to authenticated;
