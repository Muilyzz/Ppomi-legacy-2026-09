import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  CLERK_ACCOUNT_REDIRECT,
  CLERK_DEFAULT_ROUTES,
  CLERK_REQUIRED_KEYS,
  SECRETS_THE_OPERATOR_MUST_ADD,
  isClerkConfigured,
  isPlaceholderValue,
  looksLikePublishableKey,
  looksLikeSecretKey,
  readClerkEnv,
} from '../src/lib/clerk-env.ts';

test('placeholder example values are not live Clerk keys', () => {
  assert.equal(isPlaceholderValue('pk_test_REPLACE_ME'), true);
  assert.equal(looksLikePublishableKey('pk_test_REPLACE_ME'), false);
  assert.equal(looksLikeSecretKey('sk_test_REPLACE_ME'), false);
  assert.equal(isClerkConfigured({
    NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY: 'pk_test_REPLACE_ME',
    CLERK_SECRET_KEY: 'sk_test_REPLACE_ME',
  }), false);
});

test('empty env is a documented setup state, not a crash', () => {
  const snapshot = readClerkEnv({});
  assert.equal(snapshot.configured, false);
  assert.deepEqual(snapshot.missing, [...CLERK_REQUIRED_KEYS]);
  assert.deepEqual(SECRETS_THE_OPERATOR_MUST_ADD.map(item => item.name), [...CLERK_REQUIRED_KEYS]);
});

test('shape-valid test keys count as configured; invented junk does not', () => {
  const suffix = 'clerkfake00bridge01';
  const publishable = ['pk', 'test', suffix].join('_');
  const secret = ['sk', 'test', suffix].join('_');
  assert.equal(isClerkConfigured({
    NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY: publishable,
    CLERK_SECRET_KEY: secret,
  }), true);
  assert.equal(isClerkConfigured({
    NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY: 'not-a-clerk-key',
    CLERK_SECRET_KEY: secret,
  }), false);
  assert.equal(isClerkConfigured({
    NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY: publishable,
    CLERK_SECRET_KEY: 'pk_test_wrong_kind_of_key_here',
  }), false);
});

test('embedded routes stay on this Next app', () => {
  assert.equal(CLERK_DEFAULT_ROUTES.NEXT_PUBLIC_CLERK_SIGN_IN_URL, '/sign-in');
  assert.equal(CLERK_DEFAULT_ROUTES.NEXT_PUBLIC_CLERK_SIGN_UP_URL, '/sign-up');
  assert.equal(CLERK_DEFAULT_ROUTES.NEXT_PUBLIC_CLERK_AFTER_SIGN_IN_URL, '/account');
});

test('post-auth redirect is /account in code, not only deprecated AFTER_* env', () => {
  assert.equal(CLERK_ACCOUNT_REDIRECT, '/account');
});
