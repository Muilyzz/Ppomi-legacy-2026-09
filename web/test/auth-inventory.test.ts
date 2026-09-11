import assert from 'node:assert/strict';
import { test } from 'node:test';
import { IDENTITY_PROVIDERS, providerStatus } from '../src/lib/providers.ts';
import { SUPABASE_AUTH_CALL_SITES, sliceNote } from '../src/lib/auth-inventory.ts';

test('slice 1 IdPs are Google, Apple, Microsoft; email is later', () => {
  assert.deepEqual(
    IDENTITY_PROVIDERS.filter(provider => provider.slice === 1).map(provider => provider.id),
    ['google', 'apple', 'microsoft'],
  );
  assert.equal(providerStatus('email').slice, 'later');
});

test('inventory covers Mac PKCE, Android password grant, and empty Windows/hub auth', () => {
  const on = (surface: typeof SUPABASE_AUTH_CALL_SITES[number]['surface']) =>
    SUPABASE_AUTH_CALL_SITES.filter(site => site.surface === surface);
  assert.ok(on('mac').some(site => site.mechanism === 'pkce-google'));
  assert.ok(on('ipad').some(site => site.mechanism === 'pkce-google'));
  assert.ok(on('android').some(site => site.mechanism === 'password-grant'));
  assert.ok(on('windows').every(site => site.mechanism === 'none'));
  assert.ok(on('hub').every(site => site.mechanism === 'none'));
  assert.ok(on('agent').some(site => site.mechanism === 'bearer-rpc'));
  assert.match(sliceNote('hub'), /Slice 2/);
  assert.match(sliceNote('mac'), /Slice 3/);
});

test('GoogleAccount still expects a UUID sub until slice 3', () => {
  const mac = SUPABASE_AUTH_CALL_SITES.find(site => site.path.endsWith('GoogleAccount.swift'));
  assert.ok(mac?.notes.includes('UUID'));
});
