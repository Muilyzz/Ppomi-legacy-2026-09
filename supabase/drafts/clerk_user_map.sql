-- OPTIONAL DRAFT — do not `db push` this in slice 1. Lives in supabase/drafts/,
-- never in supabase/migrations/. MZZ-39 slice 5 decides how membership FKs
-- leave auth.users and applies a reviewed version of this file.
--
-- Today `ppomi_members.auth_user_id` and `ppomi_devices.auth_user_id` are
-- uuid references to auth.users. A third-party subject (Clerk `user_…`) is
-- text. Supabase's auth.uid() casts the `sub` claim to uuid, so for such a
-- token it always raises 22P02 (invalid input syntax for type uuid) — it never
-- returns NULL. Every existing `if auth.uid() is null` guard is pre-empted by
-- that error, so RLS and RPCs for third-party sessions must read
-- (select auth.jwt() ->> 'iss') and (select auth.jwt() ->> 'sub') instead.
--
-- This table is a coexistence map only: (issuer, subject) → auth.users row.
-- Vendor-neutral on purpose (the IdP has changed once already). It does not
-- replace ppomi_members, stores no identity secrets (no emails, no tokens),
-- and holds no record-encryption keys (MZZ-27: server-key / Vault stays the
-- at-rest path). Identity is not a RecordScope: nothing here decides
-- personal/business ownership (docs/record-scopes.md).

create table if not exists public.ppomi_identity_subjects (
    -- JWT `iss`, e.g. https://<app>.clerk.accounts.dev or a custom Clerk domain.
    issuer text not null
        check (issuer ~ '^https://[A-Za-z0-9.-]+(/[^[:space:]]*)?$' and length(issuer) <= 255),
    -- JWT `sub` as issued by that issuer; opaque, compared as text.
    subject text not null
        check (length(subject) between 1 and 255 and subject !~ '[[:space:]]'),
    -- Link to the GoTrue user while both planes coexist. Deleting the GoTrue
    -- user must not fail on this row and must not delete the identity.
    auth_user_id uuid unique references auth.users(id) on delete set null,
    created_at timestamptz not null default statement_timestamp(),
    linked_at timestamptz,
    primary key (issuer, subject)
);

alter table public.ppomi_identity_subjects enable row level security;

-- Proof policy: a third-party session JWT with role=authenticated reads only
-- the row whose (issuer, subject) equal its verified iss/sub claims. A GoTrue
-- session has its own issuer and a uuid sub, so it matches nothing here.
create policy ppomi_identity_subjects_self_read
    on public.ppomi_identity_subjects
    for select
    to authenticated
    using (issuer = (select auth.jwt() ->> 'iss')
       and subject = (select auth.jwt() ->> 'sub'));

-- No insert/update/delete policy: the slice 5 backfill writes through a
-- security definer RPC or the service role, never from a browser session.

comment on table public.ppomi_identity_subjects is
    'Draft (issuer, subject) ↔ auth.users map for third-party sessions. Apply only when slice 5 starts backfill.';
