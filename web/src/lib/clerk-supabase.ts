/**
 * Clerk ↔ Supabase identity bridge.
 *
 * Clerk `sub` is `user_<id>`, not a UUID. `auth.uid()` casts `sub` to uuid, so for
 * a Clerk token it always raises `22P02 invalid input syntax for type uuid` — it
 * never returns NULL, and pre-empts every `if auth.uid() is null` guard. RLS must
 * read `auth.jwt()->>'iss'` and `auth.jwt()->>'sub'`.
 *
 * Preferred path: Supabase third-party Clerk (JWKS). The old Clerk JWT template
 * that shared the project's JWT secret is deprecated (2025-04-01).
 */

export const CLERK_USER_ID = /^user_[A-Za-z0-9]{8,}$/;
export const SUPABASE_AUTH_UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export const RLS_CLERK_SUB_SQL = "(select auth.jwt() ->> 'sub')";
export const RLS_CLERK_ROLE_SQL = "(select auth.jwt() ->> 'role')";

export type ClerkSupabaseClaims = {
  sub: string;
  role?: string;
  o?: { id?: string; rol?: string };
};

export type SupabasePostgresRole = 'authenticated' | 'anon';

export function isClerkUserId(value: string): boolean {
  return CLERK_USER_ID.test(value);
}

export function isSupabaseAuthUuid(value: string): boolean {
  return SUPABASE_AUTH_UUID.test(value);
}

/** `auth.uid()` can only represent a UUID. Clerk subjects are not UUIDs. */
export function authUidCompatible(sub: string): boolean {
  return isSupabaseAuthUuid(sub);
}

export function clerkSubject(claims: ClerkSupabaseClaims): string {
  if (!isClerkUserId(claims.sub)) {
    throw new Error('Clerk sub must be a Clerk user id (user_…)');
  }
  return claims.sub;
}

export function supabaseRole(claims: ClerkSupabaseClaims): SupabasePostgresRole {
  return claims.role === 'authenticated' ? 'authenticated' : 'anon';
}

export function rowOwnedByClerkUser(claims: ClerkSupabaseClaims, clerkUserId: string): boolean {
  return supabaseRole(claims) === 'authenticated' && clerkSubject(claims) === clerkUserId;
}

/**
 * Shape passed to `createClient(url, anonKey, { accessToken })`.
 * The callback must return the live Clerk session JWT (not a Supabase Auth token).
 */
export type SupabaseClerkClientOptions = {
  accessToken: () => Promise<string | undefined>;
};

export function supabaseClerkAccessToken(
  getSessionJwt: () => Promise<string | null | undefined>,
): SupabaseClerkClientOptions {
  return {
    accessToken: async () => (await getSessionJwt()) ?? undefined,
  };
}

/** Session-token claims Clerk must emit after "Connect with Supabase". */
export function requiredSupabaseSessionClaims(): { role: 'authenticated' } {
  return { role: 'authenticated' };
}
