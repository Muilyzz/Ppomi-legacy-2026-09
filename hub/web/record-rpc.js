import { SUPABASE_URL, PUBLISHABLE_KEY } from './config.js';
import { RecordError, parseExactJSON } from './record-crypto.js';

/**
 * Account-bound record RPC transport. The caller owns device enrollment and
 * aborts signal when the client ends; check must reject an account change.
 * Resolve the device ID at request time, after enrollment has completed.
 */
export function createRecordRPC({ auth, check: checkAccount, getDeviceID, signal,
  fetch: fetcher = globalThis.fetch.bind(globalThis) }) {
  function check() {
    if (signal.aborted) throw new RecordError('cancelled');
    checkAccount();
  }
  return async function rpc(name, args) {
    check();
    const token = await auth.getAccessToken();
    check();
    const controller = new AbortController();
    const abort = () => controller.abort();
    signal.addEventListener('abort', abort, { once: true });
    const timer = setTimeout(abort, 20_000);
    try {
      const response = await fetcher(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json', apikey: PUBLISHABLE_KEY,
          Authorization: `Bearer ${token}`, 'X-Ppomi-Device': getDeviceID() }, body: JSON.stringify(args),
        credentials: 'omit', redirect: 'error', cache: 'no-store', referrerPolicy: 'no-referrer', signal: controller.signal,
      });
      check();
      if (!response.ok) throw new RecordError(response.status === 401 ? 'authentication' : response.status === 403 ? 'permission' : 'connection');
      const reader = response.body?.getReader();
      let text = '', size = 0;
      const max = name === 'ppomi_record_blob_get' ? 600_000 : 128_000;
      const decoder = new TextDecoder('utf-8', { fatal: true });
      if (!reader) throw new RecordError('invalid');
      try {
        while (true) {
          const part = await reader.read();
          check();
          if (part.done) break;
          size += part.value.byteLength;
          if (size > max) { await reader.cancel(); throw new RecordError('invalid'); }
          text += decoder.decode(part.value, { stream: true });
        }
        text += decoder.decode();
      } finally { reader.releaseLock(); }
      const value = parseExactJSON(text);
      if (!value || typeof value !== 'object' || Array.isArray(value)) throw new RecordError('invalid');
      return value;
    } catch (error) {
      check();
      if (error instanceof RecordError) throw error;
      throw new RecordError('connection');
    } finally { clearTimeout(timer); signal.removeEventListener('abort', abort); }
  };
}
