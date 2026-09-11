import { SUPABASE_URL, PUBLISHABLE_KEY } from './config.js';
import { AuthError } from './auth-error.js';

const MAX_RESPONSE = 65_536;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isAuthUserID = value => typeof value === 'string' && UUID.test(value);
export const isAuthToken = (value, min = 1) => typeof value === 'string' && value.length >= min && value.length <= 16_384 && !/\s|[\u0000-\u001f\u007f]/u.test(value);
const parse = value => { try { return JSON.parse(value); } catch { return null; } };

/** Server-validated credentials and profile data; callers own session publication and storage. */
export function createAuthClient(options = {}) {
  const fetcher = options.fetch ?? globalThis.fetch.bind(globalThis);
  const now = options.now ?? Date.now;
  const scheduleTimeout = options.setTimeout ?? globalThis.setTimeout;
  const cancelTimeout = options.clearTimeout ?? globalThis.clearTimeout;

  async function request(path, { body, access, empty = false } = {}) {
    const controller = new AbortController();
    const timer = scheduleTimeout(() => controller.abort(), 20_000);
    try {
      const headers = { apikey: PUBLISHABLE_KEY, Accept: 'application/json' };
      if (body !== undefined) headers['Content-Type'] = 'application/json';
      if (access) headers.Authorization = `Bearer ${access}`;
      const response = await fetcher(`${SUPABASE_URL}/auth/v1/${path}`, {
        method: body !== undefined ? 'POST' : 'GET', headers,
        ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
        credentials: 'omit', redirect: 'error', cache: 'no-store', referrerPolicy: 'no-referrer', signal: controller.signal,
      });
      if (!response.ok) throw new AuthError(response.status >= 500 || response.status === 429 ? 'connection' : 'authentication');
      if (empty) return null;
      const reader = response.body?.getReader();
      let text = '';
      if (reader) {
        let size = 0;
        const decoder = new TextDecoder('utf-8', { fatal: true });
        try {
          while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            size += value.byteLength;
            if (size > MAX_RESPONSE) { await reader.cancel(); throw new AuthError('authentication'); }
            text += decoder.decode(value, { stream: true });
          }
          text += decoder.decode();
        } finally { reader.releaseLock(); }
      } else {
        text = await response.text();
        if (new TextEncoder().encode(text).byteLength > MAX_RESPONSE) throw new AuthError('authentication');
      }
      const value = parse(text);
      if (!value || typeof value !== 'object' || Array.isArray(value)) throw new AuthError('authentication');
      return value;
    } catch (error) {
      if (error instanceof AuthError) throw error;
      throw new AuthError('connection');
    } finally { cancelTimeout(timer); }
  }

  async function tokens(grant, body) {
    const value = await request(`token?grant_type=${grant}`, { body });
    if (!isAuthToken(value.access_token, 16) || !isAuthToken(value.refresh_token) || typeof value.expires_in !== 'number'
      || !Number.isFinite(value.expires_in) || value.expires_in <= 0
      || (value.token_type !== undefined && (typeof value.token_type !== 'string' || value.token_type.toLowerCase() !== 'bearer'))) throw new AuthError('authentication');
    return { accessToken: value.access_token, refreshToken: value.refresh_token, expiresAt: Math.floor(now() + Math.min(value.expires_in, 86_400) * 1000) };
  }
  async function verifiedUser(access) {
    const value = await request('user', { access });
    if (!isAuthUserID(value.id) || value.aud !== 'authenticated' || value.is_anonymous === true) throw new AuthError('authentication');
    const metadata = value.user_metadata ?? {};
    const shortText = (text, max) => typeof text === 'string' && text.length <= max ? text : null;
    let avatarURL = shortText(metadata.avatar_url ?? metadata.picture, 2048);
    try { const url = new URL(avatarURL); if (url.protocol !== 'https:' || url.username || url.password) avatarURL = null; } catch { avatarURL = null; }
    return Object.freeze({ id: value.id, email: shortText(value.email, 320), name: shortText(metadata.full_name ?? metadata.name, 200), avatarURL });
  }
  return Object.freeze({
    exchangeCode: (code, verifier) => tokens('pkce', { auth_code: code, code_verifier: verifier }),
    refresh: refreshToken => tokens('refresh_token', { refresh_token: refreshToken }),
    getUser: verifiedUser,
    signOut: accessToken => request('logout?scope=local', { access: accessToken, body: {}, empty: true }),
  });
}
