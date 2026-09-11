-- OPTIONAL DRAFT — do not `db push` this in slice 1.
-- MZZ-39 slice 5 will decide how membership FKs leave auth.users.
--
-- Today `ppomi_members.auth_user_id` and `ppomi_devices.auth_user_id` are
-- uuid references to auth.users. Clerk `sub` is text `user_…`, so RLS must
-- compare `(select auth.jwt() ->> 'sub')`, not auth.uid().
--
-- This table is a coexistence map only. It does not replace ppomi_members,
-- does not store identity secrets, and does not hold record-encryption keys
-- (MZZ-27: server-key / Vault remains the at-rest path).

create table if not exists public.ppomi_clerk_identities (
    clerk_user_id text primary key
        check (clerk_user_id ~ '^user_[A-Za-z0-9]{8,}$'),
    auth_user_id uuid unique references auth.users(id),
    created_at timestamptz not null default statement_timestamp(),
    linked_at timestamptz
);

alter table public.ppomi_clerk_identities enable row level security;

-- Proof policy: a Clerk-signed session JWT with role=authenticated can read
-- only the row whose clerk_user_id equals the verified sub claim.
create policy ppomi_clerk_identities_self_read
    on public.ppomi_clerk_identities
    for select
    to authenticated
    using (clerk_user_id = (select auth.jwt() ->> 'sub'));

comment on table public.ppomi_clerk_identities is
    'Draft Clerk sub ↔ auth.users map. Apply only when slice 5 starts backfill.';
