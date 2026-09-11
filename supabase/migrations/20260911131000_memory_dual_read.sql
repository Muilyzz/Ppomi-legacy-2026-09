-- Slice 2 (MZZ-28): memory list can open shared at-rest envelopes.
-- Legacy AES-GCM rows (Vercel PPOMI_AGENT_MEMORY_KEY) are returned as stored
-- envelopes; the agent still decrypts those. Writes stay on the old save RPC.
-- Do not drop PPOMI_AGENT_MEMORY_KEY in this slice.

create function public.ppomi_agent_memory_aad(p_workspace uuid, p_id uuid, p_replaces uuid)
returns text language sql immutable set search_path = '' as $$
    select 'ppomi-memory-v1|' || p_workspace::text || '|' || p_id::text || '|' || coalesce(p_replaces::text, '');
$$;

create or replace function public.ppomi_agent_memory_list()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_device public.ppomi_devices;
begin
    v_device := public.ppomi_private_device();
    -- A deleted replacement must never resurrect its old contents in the current list.
    return (select coalesce(jsonb_agg(
        case
            when public.ppomi_transcript_envelope_valid(m.envelope) then
                jsonb_build_object(
                    'id', m.id,
                    'workspace_id', m.workspace_id,
                    'replaces_id', m.replaces_id,
                    'created_at', m.created_at,
                    'deleted_at', m.deleted_at,
                    'payload', public.ppomi_at_rest_open(
                        m.envelope,
                        public.ppomi_agent_memory_aad(m.workspace_id, m.id, m.replaces_id)))
            else to_jsonb(m)
        end
        order by m.created_at desc, m.id), '[]'::jsonb)
      from (select m.* from public.ppomi_agent_memories m
            where m.workspace_id = v_device.workspace_id and m.deleted_at is null
              and not exists (select 1 from public.ppomi_agent_memories child
                where child.workspace_id = m.workspace_id and child.replaces_id = m.id)
            order by m.created_at desc, m.id limit 50) m);
end;
$$;

revoke all on function public.ppomi_agent_memory_aad(uuid, uuid, uuid)
    from public, anon, authenticated;
comment on function public.ppomi_agent_memory_list() is
    'Lists live memory heads. At-rest envelopes are opened here; legacy GCM envelopes are returned for the agent to decrypt.';
