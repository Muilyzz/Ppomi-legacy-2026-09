import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  CLERK_ACCOUNT_REDIRECT,
  CLERK_DEFAULT_ROUTES,
  CLERK_REQUIRED_KEYS,
  SECRETS_THE_OPERATOR_MUST_ADD,
  describeKeyState,
  isClerkConfigured,
  isPlaceholderValue,
  looksLikePublishableKey,
  looksLikeSecretKey,
  readClerkEnv,
} from '../src/lib/clerk-env.ts';

// Clerk's documentation placeholder domain, encoded the way Clerk encodes a
// publishable key (base64 of `<frontend-api>$`). Not an instance anyone owns.
const placeholderPublishable = 'pk_test_' + Buffer.from('example.clerk.accounts.dev$').toString('base64');
const shapeOnlySecret = 'sk_test_clerkfake00bridge01';

test('placeholder example values are not live Clerk keys', () => {
  assert.equal(isPlaceholderValue('pk_test_REPLACE_ME'), true);
  assert.equal(looksLikePublishableKey('pk_test_REPLACE_ME'), false);
  assert.equal(looksLikeSecretKey('sk_test_REPLACE_ME'), false);
  const snapshot = readClerkEnv({
    NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY: 'pk_test_REPLACE_ME',
    CLERK_SECRET_KEY: 'sk_test_REPLACE_ME',
  });
  assert.equal(snapshot.configured, false);
  assert.deepEqual(snapshot.placeholders, [...CLERK_REQUIRED_KEYS]);
  assert.deepEqual(snapshot.invalid, []);
});

test('empty env is a documented setup state, not a crash', () => {
  const snapshot = readClerkEnv({});
  assert.equal(snapshot.configured, false);
  assert.deepEqual(snapshot.missing, [...CLERK_REQUIRED_KEYS]);
  assert.deepEqual(snapshot.keys, {
    NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY: 'missing',
    CLERK_SECRET_KEY: 'missing',
  });
  assert.deepEqual(SECRETS_THE_OPERATOR_MUST_ADD.map(item => item.name), [...CLERK_REQUIRED_KEYS]);
});

test('a prefix-shaped but undecodable publishable key is invalid, not configured', () => {
  // The fixture the spike accepted; Clerk rejects it with "Publishable key not valid."
  const fixture = 'pk_test_clerkfake00bridge01';
  assert.equal(looksLikePublishableKey(fixture), false);
  const snapshot = readClerkEnv({
    NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY: fixture,
    CLERK_SECRET_KEY: shapeOnlySecret,
  });
  assert.equal(snapshot.configured, false);
  assert.deepEqual(snapshot.invalid, ['NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY']);
  assert.equal(snapshot.keys.NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY, 'invalid');
  assert.equal(snapshot.keys.CLERK_SECRET_KEY, 'valid');
});

test('a key that passes Clerk’s own validator counts as configured; wrong kinds do not', () => {
  assert.equal(looksLikePublishableKey(placeholderPublishable), true);
  assert.equal(isClerkConfigured({
    NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY: placeholderPublishable,
    CLERK_SECRET_KEY: shapeOnlySecret,
  }), true);
  assert.equal(isClerkConfigured({
    NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY: 'not-a-clerk-key',
    CLERK_SECRET_KEY: shapeOnlySecret,
  }), false);
  assert.equal(isClerkConfigured({
    NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY: placeholderPublishable,
    CLERK_SECRET_KEY: 'pk_test_wrong_kind_of_key_here',
  }), false);
  assert.equal(isClerkConfigured({
    NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY: placeholderPublishable,
  }), false);
});

test('the setup panel describes key state without echoing values', () => {
  for (const state of ['missing', 'placeholder', 'invalid', 'valid'] as const) {
    const text = describeKeyState(state);
    assert.ok(text.length > 0);
    assert.doesNotMatch(text, /pk_|sk_/);
  }
});

test('embedded routes stay on this Next app', () => {
  assert.equal(CLERK_DEFAULT_ROUTES.NEXT_PUBLIC_CLERK_SIGN_IN_URL, '/sign-in');
  assert.equal(CLERK_DEFAULT_ROUTES.NEXT_PUBLIC_CLERK_SIGN_UP_URL, '/sign-up');
  assert.equal(CLERK_DEFAULT_ROUTES.NEXT_PUBLIC_CLERK_AFTER_SIGN_IN_URL, '/account');
});

test('post-auth redirect is /account in code, not only deprecated AFTER_* env', () => {
  assert.equal(CLERK_ACCOUNT_REDIRECT, '/account');
});
