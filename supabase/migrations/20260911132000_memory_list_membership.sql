-- Slice 2b (MZZ-27 / MZZ-28): memory list is membership, not device approval.
-- Decrypt/list uses ppomi_private_member_workspace() like transcripts.
-- Writes still go through ppomi_private_device() until a later slice.

create or replace function public.ppomi_agent_memory_list()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_workspace uuid;
begin
    v_workspace := public.ppomi_private_member_workspace();
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
            where m.workspace_id = v_workspace and m.deleted_at is null
              and not exists (select 1 from public.ppomi_agent_memories child
                where child.workspace_id = m.workspace_id and child.replaces_id = m.id)
            order by m.created_at desc, m.id limit 50) m);
end;
$$;

comment on function public.ppomi_agent_memory_list() is
    'Lists live memory heads for the signed-in workspace member. No device-approval gate. At-rest envelopes are opened here; legacy GCM envelopes are returned for the agent to decrypt.';
