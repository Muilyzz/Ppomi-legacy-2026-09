import { SUPABASE_URL, REDIRECT_URL } from './config.js';
import { createAuthClient, isAuthToken, isAuthUserID } from './auth-client.js';
import { AuthError } from './auth-error.js';
// Preserve the existing public auth module interface.
export { SUPABASE_URL, PUBLISHABLE_KEY, REDIRECT_URL } from './config.js';
export { AuthError } from './auth-error.js';

export const SESSION_STORAGE_KEY = 'ppomi.web.auth.session.v1';
export const PKCE_STORAGE_KEY = 'ppomi.web.auth.pkce.v1';
const LOCK_NAME = 'ppomi.web.auth.session.v1';
const parse = value => { try { return JSON.parse(value); } catch { return null; } };
const base64url = bytes => btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');

/**
 * clearSecrets is an awaited UI-owned hook for private caches, vault keys and
 * pending record requests. Events and public snapshots never contain tokens.
 * Browser storage is not a Keychain; do not store native identity/vault secrets here.
 */
export function createAuth(options = {}) {
  const storage = options.storage ?? globalThis.localStorage;
  const transactions = options.transactionStorage ?? globalThis.sessionStorage;
  const crypto = options.crypto ?? globalThis.crypto;
  const location = options.location ?? globalThis.location;
  const history = options.history ?? globalThis.history;
  const eventTarget = options.eventTarget ?? globalThis.window;
  const locks = options.locks ?? globalThis.navigator?.locks;
  const now = options.now ?? Date.now;
  const client = createAuthClient({ fetch: options.fetch, now });
  const clearSecrets = options.clearSecrets ?? (async () => {});
  const listeners = new Set(options.onChange ? [options.onChange] : []);
  let current = null, currentRaw = null, generation = 0, loadFlight = null, refreshFlight = null, disposed = false;
  let cleanup = Promise.resolve();

  function read(store, key) {
    try { return store.getItem(key); } catch { throw new AuthError('storage'); }
  }
  function write(store, key, value) {
    try { value === null ? store.removeItem(key) : store.setItem(key, value); }
    catch { throw new AuthError('storage'); }
  }
  function stored(raw) {
    const value = parse(raw);
    return value?.formatVersion === 1 && isAuthToken(value.accessToken, 16) && isAuthToken(value.refreshToken)
      && Number.isSafeInteger(value.expiresAt) && value.expiresAt > 0 && value.expiresAt <= now() + 86_400_000
      && isAuthUserID(value.userId) ? value : null;
  }
  function snapshot() { return current ? Object.freeze({ user: current.user, expiresAt: current.expiresAt }) : null; }
  function emit(type, reason) {
    const event = Object.freeze({ type, reason, user: current?.user ?? null });
    for (const listener of listeners) { try { listener(event); } catch { /* UI cannot prevent invalidation. */ } }
  }
  function check(epoch, expectedRaw) {
    if (disposed || epoch !== generation || (expectedRaw !== undefined && read(storage, SESSION_STORAGE_KEY) !== expectedRaw)) throw new AuthError('cancelled');
  }
  function queueCleanup(reason, previousUserId, nextUserId = null) {
    // A later explicit cleanup can recover from a failed hook; session publication
    // still waits for this call to finish successfully.
    cleanup = cleanup.catch(() => {}).then(() => clearSecrets({ reason, previousUserId, nextUserId })).catch(() => { throw new AuthError('cleanup'); });
    cleanup.catch(() => {});
    return cleanup;
  }
  function invalidate(reason, { remove = true, previousUserId = current?.user.id ?? null, nextUserId = null, eraseSecrets = true } = {}) {
    generation++;
    current = null;
    currentRaw = null;
    loadFlight = null;
    refreshFlight = null;
    let storageError;
    if (remove) { try { write(storage, SESSION_STORAGE_KEY, null); } catch (error) { storageError = error; } }
    emit('signed-out', reason);
    const work = eraseSecrets ? queueCleanup(reason, previousUserId, nextUserId) : cleanup;
    return work.then(() => { if (storageError) throw storageError; });
  }
  const exclusive = operation => locks?.request ? locks.request(LOCK_NAME, { mode: 'exclusive' }, operation) : operation();

  async function publish(candidate, user, epoch, raw, reason) {
    check(epoch, raw);
    await cleanup;
    check(epoch, raw);
    const serialized = JSON.stringify({ formatVersion: 1, ...candidate, userId: user.id });
    write(storage, SESSION_STORAGE_KEY, serialized);
    currentRaw = serialized;
    current = { ...candidate, user };
    emit('signed-in', reason);
    return snapshot();
  }
  function callback() {
    const url = new URL(location.href);
    const hash = new URLSearchParams(url.hash.slice(1));
    const names = ['code', 'error', 'error_code', 'error_description'];
    if (!names.some(key => url.searchParams.has(key)) && !['access_token', 'refresh_token', ...names].some(key => hash.has(key))) return null;
    if (url.origin + url.pathname !== REDIRECT_URL) throw new AuthError('unavailable');
    // Strip callback material before any network await; never copy it into redirect_to.
    history.replaceState(null, '', REDIRECT_URL);
    const raw = read(transactions, PKCE_STORAGE_KEY);
    write(transactions, PKCE_STORAGE_KEY, null);
    const transaction = parse(raw);
    const code = url.searchParams.get('code');
    if (url.hash || url.searchParams.getAll('code').length !== 1 || names.slice(1).some(key => url.searchParams.has(key))
      || !isAuthToken(code) || code.length > 4096 || transaction?.formatVersion !== 1
      || !/^[A-Za-z0-9_-]{43}$/.test(transaction.verifier) || !Number.isSafeInteger(transaction.createdAt)
      || transaction.createdAt > now() || now() - transaction.createdAt > 600_000) throw new AuthError('authentication');
    return { code, verifier: transaction.verifier };
  }

  function loadSession() {
    if (loadFlight) return loadFlight;
    const epoch = generation;
    const operation = exclusive(async () => {
      check(epoch);
      await cleanup;
      check(epoch);
      let raw = read(storage, SESSION_STORAGE_KEY);
      let candidate = stored(raw);
      try {
        const pending = callback();
        if (pending) {
          // Any callback is a new identity boundary, even if it returns the same user.
          current = null;
          currentRaw = null;
          check(epoch, raw);
          write(storage, SESSION_STORAGE_KEY, null);
          raw = null;
          emit('signed-out', 'account-change');
          await queueCleanup('account-change', candidate?.userId ?? null);
          check(epoch, raw);
          candidate = await client.exchangeCode(pending.code, pending.verifier);
          const user = await client.getUser(candidate.accessToken);
          return await publish(candidate, user, epoch, raw, 'callback');
        }
        if (!candidate) {
          await invalidate(raw === null ? 'no-session' : 'invalid-session');
          return null;
        }
        current = null;
        if (candidate.expiresAt <= now() + 60_000) {
          const refreshed = await client.refresh(candidate.refreshToken);
          candidate = { ...refreshed, userId: candidate.userId };
        }
        const user = await client.getUser(candidate.accessToken);
        if (user.id !== candidate.userId) throw new AuthError('authentication');
        return await publish({ accessToken: candidate.accessToken, refreshToken: candidate.refreshToken, expiresAt: candidate.expiresAt }, user, epoch, raw, 'restored');
      } catch (error) {
        if (epoch === generation) {
          current = null;
          if (error instanceof AuthError && error.code === 'authentication') await invalidate('invalid-session', { previousUserId: candidate?.userId ?? null });
        }
        throw error;
      }
    });
    loadFlight = operation;
    operation.finally(() => { if (loadFlight === operation) loadFlight = null; }).catch(() => {});
    return operation;
  }

  async function getAccessToken() {
    if (disposed) throw new AuthError('cancelled');
    if (loadFlight) await loadFlight;
    if (current && read(storage, SESSION_STORAGE_KEY) !== currentRaw) {
      const next = stored(read(storage, SESSION_STORAGE_KEY));
      await invalidate('external-session', { remove: false, nextUserId: next?.userId ?? null, eraseSecrets: !next || next.userId !== current.user.id });
    }
    if (!current) await loadSession();
    if (!current) throw new AuthError('authentication');
    if (current.expiresAt > now() + 60_000) return current.accessToken;
    if (!refreshFlight) {
      // loadSession re-reads storage under the browser lock. Another tab may have
      // already rotated the refresh token while this tab waited for the lock.
      const operation = loadSession();
      refreshFlight = operation;
      operation.finally(() => { if (refreshFlight === operation) refreshFlight = null; }).catch(() => {});
    }
    await refreshFlight;
    if (!current || current.expiresAt <= now()) throw new AuthError('authentication');
    return current.accessToken;
  }

  async function signIn() {
    if (disposed) throw new AuthError('cancelled');
    const url = new URL(location.href);
    if (url.origin + url.pathname !== REDIRECT_URL || !crypto?.subtle) throw new AuthError('unavailable');
    const clearing = invalidate('sign-in');
    const epoch = generation;
    await clearing;
    check(epoch);
    history.replaceState(null, '', REDIRECT_URL);
    write(transactions, PKCE_STORAGE_KEY, null);
    const verifier = base64url(crypto.getRandomValues(new Uint8Array(32)));
    const challenge = base64url(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))));
    check(epoch);
    write(transactions, PKCE_STORAGE_KEY, JSON.stringify({ formatVersion: 1, verifier, createdAt: now() }));
    const authorize = new URL(`${SUPABASE_URL}/auth/v1/authorize`);
    authorize.search = new URLSearchParams({ provider: 'google', redirect_to: REDIRECT_URL, code_challenge: challenge, code_challenge_method: 's256', prompt: 'select_account' }).toString();
    location.assign(authorize.href);
  }
  async function signOut() {
    let previous = current;
    if (!previous) { try { previous = stored(read(storage, SESSION_STORAGE_KEY)); } catch { /* Still invalidate memory and private caches. */ } }
    const pending = invalidate('sign-out', { previousUserId: current?.user.id ?? previous?.userId ?? null });
    let storageError;
    try { write(transactions, PKCE_STORAGE_KEY, null); } catch (error) { storageError = error; }
    await pending;
    if (storageError) throw storageError;
    // Local clearing always wins, including offline logout. Revoke this browser's
    // session only; family members' native sessions must remain signed in.
    if (previous?.accessToken) {
      try { await client.signOut(previous.accessToken); } catch { /* Local logout remains complete. */ }
    }
  }
  function onStorage(event) {
    if (event.storageArea && event.storageArea !== storage) return;
    if (event.key !== null && event.key !== SESSION_STORAGE_KEY) return;
    const next = stored(event.newValue);
    const previousUserId = current?.user.id ?? null;
    invalidate('external-session', { remove: false, previousUserId, nextUserId: next?.userId ?? null, eraseSecrets: !next || next.userId !== previousUserId }).catch(() => {});
    emit('session-changed', 'external-session');
  }
  eventTarget?.addEventListener('storage', onStorage);
  return Object.freeze({
    loadSession, signIn, signOut, getAccessToken,
    getUser: () => current?.user ?? null,
    subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); },
    dispose() { disposed = true; generation++; current = null; currentRaw = null; listeners.clear(); eventTarget?.removeEventListener('storage', onStorage); },
  });
}
