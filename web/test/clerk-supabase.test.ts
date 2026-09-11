import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  RLS_CLERK_SUB_SQL,
  authUidCompatible,
  clerkSubject,
  requiredSupabaseSessionClaims,
  rowOwnedByClerkUser,
  supabaseClerkAccessToken,
  supabaseRole,
} from '../src/lib/clerk-supabase.ts';

const clerkUser = 'user_2AbCdEfGhIjKlMnO';
const otherUser = 'user_2OtherClerkSubject';
const supabaseUuid = '550e8400-e29b-41d4-a716-446655440000';

test('RLS subject is auth.jwt() sub, not auth.uid()', () => {
  assert.equal(RLS_CLERK_SUB_SQL, "(select auth.jwt() ->> 'sub')");
  assert.equal(authUidCompatible(clerkUser), false);
  assert.equal(authUidCompatible(supabaseUuid), true);
  assert.equal(clerkSubject({ sub: clerkUser, role: 'authenticated' }), clerkUser);
  assert.throws(() => clerkSubject({ sub: supabaseUuid, role: 'authenticated' }));
});

test('TO authenticated needs the Clerk session role claim', () => {
  assert.deepEqual(requiredSupabaseSessionClaims(), { role: 'authenticated' });
  assert.equal(supabaseRole({ sub: clerkUser }), 'anon');
  assert.equal(supabaseRole({ sub: clerkUser, role: 'authenticated' }), 'authenticated');
});

test('a Clerk JWT owns only the matching clerk_user_id row', () => {
  const claims = { sub: clerkUser, role: 'authenticated' };
  assert.equal(rowOwnedByClerkUser(claims, clerkUser), true);
  assert.equal(rowOwnedByClerkUser(claims, otherUser), false);
  assert.equal(rowOwnedByClerkUser({ sub: clerkUser }, clerkUser), false);
});

test('Supabase client takes the Clerk session JWT as accessToken', async () => {
  const options = supabaseClerkAccessToken(async () => 'clerk.session.jwt');
  assert.equal(await options.accessToken(), 'clerk.session.jwt');
  assert.equal(await supabaseClerkAccessToken(async () => null).accessToken(), undefined);
});
