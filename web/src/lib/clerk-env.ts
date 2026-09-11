import { isPublishableKey } from '@clerk/shared/keys';

/** Placeholder tokens documented in `.env.example`. Never treat these as live keys. */
const PLACEHOLDER = /REPLACE_ME|your[_-]?clerk|placeholder|\bxxx+\b/i;
/** Clerk publishes no stricter public shape for secret keys than prefix + opaque token. */
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

/** DoD: Google (or any Clerk IdP) sign-in lands on /account. Set in components, not only env. */
export const CLERK_ACCOUNT_REDIRECT = '/account';

export type ClerkRequiredKey = (typeof CLERK_REQUIRED_KEYS)[number];

/**
 * `invalid` is a value that is neither empty nor a documented placeholder but
 * fails Clerk's own shape check. Clerk would throw "Publishable key not valid."
 * on every matched route, so it must keep the app in setup mode instead.
 */
export type ClerkKeyState = 'missing' | 'placeholder' | 'invalid' | 'valid';

export type ClerkEnvSnapshot = {
  configured: boolean;
  missing: ClerkRequiredKey[];
  placeholders: ClerkRequiredKey[];
  invalid: ClerkRequiredKey[];
  keys: Record<ClerkRequiredKey, ClerkKeyState>;
};

export function isPlaceholderValue(value: string | undefined): boolean {
  return !value || PLACEHOLDER.test(value);
}

/** Clerk's validator: prefix, base64 Frontend API domain, `$` terminator. */
export function looksLikePublishableKey(value: string | undefined): boolean {
  return Boolean(value) && !isPlaceholderValue(value) && isPublishableKey(value);
}

export function looksLikeSecretKey(value: string | undefined): boolean {
  return Boolean(value && SECRET.test(value) && !isPlaceholderValue(value));
}

function keyState(value: string | undefined, valid: (value: string) => boolean): ClerkKeyState {
  if (!value) return 'missing';
  if (isPlaceholderValue(value)) return 'placeholder';
  return valid(value) ? 'valid' : 'invalid';
}

/** Evaluate per call: pages and middleware read the live process env, never a build-time snapshot. */
export function readClerkEnv(env: NodeJS.Dict<string> = process.env): ClerkEnvSnapshot {
  const keys: Record<ClerkRequiredKey, ClerkKeyState> = {
    NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY: keyState(env.NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY, isPublishableKey),
    CLERK_SECRET_KEY: keyState(env.CLERK_SECRET_KEY, value => SECRET.test(value)),
  };
  const withState = (state: ClerkKeyState): ClerkRequiredKey[] =>
    CLERK_REQUIRED_KEYS.filter(key => keys[key] === state);
  return {
    configured: CLERK_REQUIRED_KEYS.every(key => keys[key] === 'valid'),
    missing: withState('missing'),
    placeholders: withState('placeholder'),
    invalid: withState('invalid'),
    keys,
  };
}

export function isClerkConfigured(env: NodeJS.Dict<string> = process.env): boolean {
  return readClerkEnv(env).configured;
}

/** Human-readable state for the setup panel. Never renders the value itself. */
export function describeKeyState(state: ClerkKeyState): string {
  switch (state) {
    case 'missing':
      return '없음';
    case 'placeholder':
      return '예시 값 그대로';
    case 'invalid':
      return '형식이 맞지 않음 (Clerk 검증 실패)';
    case 'valid':
      return '확인됨';
    default: {
      const exhaustive: never = state;
      return exhaustive;
    }
  }
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
