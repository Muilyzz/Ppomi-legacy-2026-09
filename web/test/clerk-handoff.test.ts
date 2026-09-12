import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  CLERK_HANDOFF_ORIGIN,
  CLERK_SHELL_REDIRECT,
  clerkAfterAuthUrl,
  postClerkHandoff,
  wantsShellHandoff,
} from '../src/lib/clerk-handoff.ts';

test('shell sign-in keeps /account?from=shell so the Mac app can collect the JWT', () => {
  assert.equal(clerkAfterAuthUrl('shell'), CLERK_SHELL_REDIRECT);
  assert.equal(clerkAfterAuthUrl(undefined), '/account');
  assert.equal(clerkAfterAuthUrl('web'), '/account');
  assert.equal(wantsShellHandoff('?from=shell'), true);
  assert.equal(wantsShellHandoff('from=shell&x=1'), true);
  assert.equal(wantsShellHandoff(''), false);
  assert.equal(CLERK_HANDOFF_ORIGIN, 'http://127.0.0.1:17382');
});

test('handoff POST never puts the JWT in the URL and treats a down listener as failure', async () => {
  const previous = globalThis.fetch;
  const seen: { url: string; body: string }[] = [];
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    seen.push({ url: String(input), body: String(init?.body) });
    return new Response(JSON.stringify({ stored: true }), { status: 200 });
  }) as typeof fetch;
  try {
    assert.equal(await postClerkHandoff('http://127.0.0.1:17382/', 'clerk.session.jwt'), true);
    assert.deepEqual(seen, [{
      url: 'http://127.0.0.1:17382/clerk-session',
      body: JSON.stringify({ clerkSession: 'clerk.session.jwt' }),
    }]);
  } finally {
    globalThis.fetch = previous;
  }
  assert.equal(await postClerkHandoff('http://127.0.0.1:9', 'clerk.session.jwt'), false);
});
