/** Placeholder tokens documented in `.env.example`. Never treat these as live keys. */
const PLACEHOLDER = /REPLACE_ME|your[_-]?clerk|placeholder|\bxxx+\b/i;
const PUBLISHABLE = /^pk_(test|live)_[A-Za-z0-9]{16,}$/;
const SECRET = /^sk_(test|live)_[A-Za-z0-9]{16,}$/;

export const CLERK_REQUIRED_KEYS = [
  'NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY',
  'CLERK_SECRET_KEY',
] as const;

export const CLERK_ROUTE_KEYS = [
  'NEXT_PUBLIC_CLERK_SIGN_IN_URL',
  'NEXT_PUBLIC_CLERK_SIGN_UP_URL',
  'NEXT_PUBLIC_CLERK_AFTER_SIGN_IN_URL',
  'NEXT_PUBLIC_CLERK_AFTER_SIGN_UP_URL',
] as const;

export const CLERK_LATER_KEYS = ['CLERK_WEBHOOK_SECRET'] as const;

export const CLERK_DEFAULT_ROUTES = {
  NEXT_PUBLIC_CLERK_SIGN_IN_URL: '/sign-in',
  NEXT_PUBLIC_CLERK_SIGN_UP_URL: '/sign-up',
  NEXT_PUBLIC_CLERK_AFTER_SIGN_IN_URL: '/account',
  NEXT_PUBLIC_CLERK_AFTER_SIGN_UP_URL: '/account',
} as const;

export type ClerkRequiredKey = (typeof CLERK_REQUIRED_KEYS)[number];

export type ClerkEnvSnapshot = {
  configured: boolean;
  missing: ClerkRequiredKey[];
  placeholders: ClerkRequiredKey[];
};

export function isPlaceholderValue(value: string | undefined): boolean {
  return !value || PLACEHOLDER.test(value);
}

export function looksLikePublishableKey(value: string | undefined): boolean {
  return Boolean(value && PUBLISHABLE.test(value) && !isPlaceholderValue(value));
}

export function looksLikeSecretKey(value: string | undefined): boolean {
  return Boolean(value && SECRET.test(value) && !isPlaceholderValue(value));
}

export function readClerkEnv(env: NodeJS.Dict<string> = process.env): ClerkEnvSnapshot {
  const publishable = env.NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY;
  const secret = env.CLERK_SECRET_KEY;
  const missing: ClerkRequiredKey[] = [];
  const placeholders: ClerkRequiredKey[] = [];
  if (!publishable) missing.push('NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY');
  else if (isPlaceholderValue(publishable) || !PUBLISHABLE.test(publishable)) {
    placeholders.push('NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY');
  }
  if (!secret) missing.push('CLERK_SECRET_KEY');
  else if (isPlaceholderValue(secret) || !SECRET.test(secret)) {
    placeholders.push('CLERK_SECRET_KEY');
  }
  return {
    configured: missing.length === 0 && placeholders.length === 0
      && looksLikePublishableKey(publishable) && looksLikeSecretKey(secret),
    missing,
    placeholders,
  };
}

export function isClerkConfigured(env: NodeJS.Dict<string> = process.env): boolean {
  return readClerkEnv(env).configured;
}

/** Secrets a human must paste into `.env.local`. This spike never invents values. */
export const SECRETS_THE_OPERATOR_MUST_ADD = [
  {
    name: 'NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY',
    where: 'Clerk Dashboard → API Keys → Publishable key (pk_test_… or pk_live_…)',
  },
  {
    name: 'CLERK_SECRET_KEY',
    where: 'Clerk Dashboard → API Keys → Secret key (sk_test_… or sk_live_…). Server only.',
  },
] as const;
