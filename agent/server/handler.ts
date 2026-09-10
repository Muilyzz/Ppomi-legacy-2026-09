import { createCipheriv, createDecipheriv, createHmac, randomBytes } from 'node:crypto';

type Json = Record<string, unknown>;
type Fetcher = typeof fetch;
type Environment = Record<string, string | undefined>;
export interface Memory {
  id: string;
  kind: 'fact' | 'preference' | 'decision' | 'todo' | 'result';
  text: string;
  source: 'user_reported' | 'tool_observed' | 'ai_inferred';
  confidence: number;
  replacesId?: string;
  createdAt: string;
  selection: 'automatic';
}
type MemoryInput = Omit<Memory, 'createdAt' | 'selection'>;
type Context = { workspace: { id: string }; device: { id: string } };
type StoredMemory = { id: string; workspace_id: string; replaces_id: string | null; created_at: string; deleted_at: string | null; envelope: Json };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PATHS = new Set(['/v1/session', '/v1/responses', '/v1/memories/list', '/v1/memories/save', '/v1/memories/delete']);
/** Text chat runs on a flagship model through the Responses proxy; the server picks the model, never the client. */
const TEXT_MODEL = 'gpt-6-astra';
const MODEL_ID = /^[a-zA-Z0-9_.-]{1,100}$/;
const NO_STORE = { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store, private', 'Pragma': 'no-cache', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer' };

class SafeError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) { super(message); }
}
function invalid(): never { throw new SafeError(400, 'invalid_request', '요청 형식을 확인해 주세요. 대화 원문과 비밀정보는 기록하지 않습니다.'); }
function object(value: unknown): Json {
  if (!value || typeof value !== 'object' || Array.isArray(value)) invalid();
  return value as Json;
}
function exactFields(value: Json, allowed: string[], required: string[] = allowed): void {
  if (Object.keys(value).some(key => !allowed.includes(key)) || required.some(key => !(key in value))) invalid();
}
function uuid(value: unknown): string {
  if (typeof value !== 'string' || !UUID.test(value)) invalid();
  return value.toLowerCase();
}
/** Conservative patterns are a second guard; they cannot establish that arbitrary text is non-sensitive. */
function containsSecretOrTranscript(text: string): boolean {
  return /-----BEGIN [A-Z ]*PRIVATE KEY-----|\b(?:sk-(?:proj-)?[A-Za-z0-9_-]{16,}|sb_secret_[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,})\b/.test(text)
    || /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/.test(text)
    || /(?:password|passwd|api[_ -]?key|access[_ -]?token|refresh[_ -]?token|client[_ -]?secret|비밀번호|비번|인증번호|복구\s*코드)\s*(?::|=|은|는|이|가)\s*\S+/i.test(text)
    || /\b\d{6}-[1-8]\d{6}\b/.test(text)
    || (text.match(/^(?:user|assistant|system|사용자|어시스턴트)\s*:/gim)?.length ?? 0) >= 2;
}
function memoryInput(value: unknown): MemoryInput {
  const body = object(value);
  exactFields(body, ['id', 'kind', 'text', 'source', 'confidence', 'replacesId'], ['id', 'kind', 'text', 'source', 'confidence']);
  const id = uuid(body.id), replacesId = body.replacesId === undefined ? undefined : uuid(body.replacesId);
  if (replacesId === id || typeof body.kind !== 'string' || !['fact', 'preference', 'decision', 'todo', 'result'].includes(body.kind)
      || typeof body.source !== 'string' || !['user_reported', 'tool_observed', 'ai_inferred'].includes(body.source)
      || typeof body.text !== 'string' || [...body.text].length > 2000 || !body.text.trim()
      || /[\u0000-\u0008\u000B\u000C\u000E-\u001F]/.test(body.text) || containsSecretOrTranscript(body.text)
      || typeof body.confidence !== 'number' || !Number.isFinite(body.confidence) || body.confidence < 0 || body.confidence > 1) invalid();
  return { id, kind: body.kind as Memory['kind'], text: body.text, source: body.source as Memory['source'], confidence: body.confidence, ...(replacesId ? { replacesId } : {}) };
}
async function boundedJson(source: Request | Response, limit: number): Promise<unknown> {
  const reader = source.body?.getReader();
  if (!reader) invalid();
  let size = 0;
  const chunks: Uint8Array[] = [];
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) { await reader.cancel(); throw new SafeError(413, 'too_large', '요청 또는 응답이 너무 큽니다.'); }
      chunks.push(value);
    }
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch (error) {
    if (error instanceof SafeError) throw error;
    invalid();
  } finally { reader.releaseLock(); }
}
function settings(env: Environment) {
  const url = env.SUPABASE_URL ?? '', publicKey = env.SUPABASE_ANON_KEY ?? env.SUPABASE_PUBLISHABLE_KEY ?? '';
  if (!/^https:\/\/[a-z0-9]{20}\.supabase\.co$/.test(url) || !publicKey || /\s/.test(publicKey))
    throw new SafeError(503, 'not_configured', '공유 서버 연결 설정이 필요합니다.');
  // Reject administrative keys even when the environment variable was misconfigured.
  let isPublic = /^sb_publishable_[A-Za-z0-9_-]{16,}$/.test(publicKey);
  try { isPublic ||= JSON.parse(Buffer.from(publicKey.split('.')[1] ?? '', 'base64url').toString()).role === 'anon'; } catch { /* No credential values in errors. */ }
  if (!isPublic) throw new SafeError(503, 'not_configured', '공유 서버의 공개 연결 키가 필요합니다.');
  return { url, publicKey };
}
function encryptionKey(env: Environment): Buffer {
  const raw = env.PPOMI_AGENT_MEMORY_KEY ?? '';
  if (!/^[A-Za-z0-9+/]{43}=$/.test(raw)) throw new SafeError(503, 'not_configured', '기록 암호화 설정이 필요합니다.');
  const key = Buffer.from(raw, 'base64');
  if (key.length !== 32 || key.toString('base64') !== raw) throw new SafeError(503, 'not_configured', '기록 암호화 설정이 필요합니다.');
  return key;
}
function aad(workspace: string, id: string, replacesId: string | null): Buffer {
  return Buffer.from(JSON.stringify(['ppomi-agent-memory', 1, workspace, id, replacesId]));
}
function encrypt(input: MemoryInput, workspace: string, key: Buffer): { envelope: Json; digest: string } {
  const payload = JSON.stringify({ id: input.id, kind: input.kind, text: input.text, source: input.source, confidence: input.confidence, replacesId: input.replacesId ?? null, selection: 'automatic' });
  const binding = aad(workspace, input.id, input.replacesId ?? null);
  const nonce = randomBytes(12), cipher = createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(binding);
  const encrypted = Buffer.concat([cipher.update(payload, 'utf8'), cipher.final()]);
  return {
    envelope: { version: 1, nonce: nonce.toString('base64url'), ciphertext: encrypted.toString('base64url'), tag: cipher.getAuthTag().toString('base64url') },
    // A keyed digest deduplicates random-nonce encryptions without publishing a plaintext hash.
    digest: createHmac('sha256', key).update('ppomi-memory-idempotency\0').update(binding).update(payload).digest('hex'),
  };
}
function decrypt(row: StoredMemory, workspace: string, key: Buffer): Memory {
  try {
    if (row.workspace_id !== workspace || !UUID.test(row.id) || row.deleted_at !== null || !Number.isFinite(Date.parse(row.created_at))) throw new Error();
    const envelope = row.envelope;
    if (envelope.version !== 1 || typeof envelope.nonce !== 'string' || typeof envelope.ciphertext !== 'string' || typeof envelope.tag !== 'string') throw new Error();
    const decipher = createDecipheriv('aes-256-gcm', key, Buffer.from(envelope.nonce, 'base64url'));
    decipher.setAAD(aad(workspace, row.id, row.replaces_id));
    decipher.setAuthTag(Buffer.from(envelope.tag, 'base64url'));
    const payload = JSON.parse(Buffer.concat([decipher.update(Buffer.from(envelope.ciphertext, 'base64url')), decipher.final()]).toString('utf8')) as Json;
    if (payload.id !== row.id || payload.replacesId !== row.replaces_id || payload.selection !== 'automatic') throw new Error();
    const { selection: _selection, replacesId, ...rest } = payload;
    const validated = memoryInput({ ...rest, ...(replacesId ? { replacesId } : {}) });
    return { ...validated, createdAt: row.created_at, selection: 'automatic' };
  } catch { throw new SafeError(502, 'record_unreadable', '기록의 무결성을 확인하지 못했습니다. 저장 키와 서버 기록을 확인해 주세요.'); }
}

/** Injectable transport/configuration keeps tests offline. No requests, tokens or sessions are retained. */
export function createHandler(dependencies: { fetch?: Fetcher; env?: Environment } = {}) {
  const transport = dependencies.fetch ?? fetch;
  return async function handle(request: Request): Promise<Response> {
    try {
      const path = new URL(request.url).pathname;
      if (!PATHS.has(path)) throw new SafeError(404, 'not_found', '지원하지 않는 요청입니다.');
      if (request.method !== 'POST') throw new SafeError(405, 'method_not_allowed', 'POST 요청만 허용합니다.');
      if (request.headers.has('origin')) throw new SafeError(403, 'native_only', '앱의 보안 연결을 사용해 주세요.');
      const auth = request.headers.get('authorization') ?? '';
      if (!/^Bearer [A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(auth) || auth.length > 8192)
        throw new SafeError(401, 'unauthenticated', '등록된 기기의 인증이 필요합니다.');
      const env = dependencies.env ?? process.env, config = settings(env);
      async function rpc(name: string, body: Json): Promise<unknown> {
        let response: Response;
        try {
          response = await transport(`${config.url}/rest/v1/rpc/${name}`, { method: 'POST', redirect: 'error', signal: AbortSignal.timeout(20_000),
            headers: { apikey: config.publicKey, Authorization: auth, 'Content-Type': 'application/json' }, body: JSON.stringify(body), cache: 'no-store' });
        } catch { throw new SafeError(502, 'server_unavailable', '공유 서버에 연결하지 못했습니다.'); }
        if (!response.ok) {
          await response.body?.cancel();
          if (response.status === 401 || response.status === 403) throw new SafeError(response.status, 'unauthorized', '기기 인증 또는 기록 접근 권한을 확인해 주세요.');
          if (response.status === 409 || response.status === 410) throw new SafeError(409, 'conflict', '같은 기록 ID가 이미 사용되었거나 기록이 변경·삭제되었습니다.');
          if (response.status === 404) throw new SafeError(404, 'not_found', '기록을 찾지 못했습니다.');
          if (response.status === 429) throw new SafeError(429, 'rate_limited', '잠시 후 다시 시도해 주세요.');
          throw new SafeError(502, 'server_unavailable', '공유 서버에서 요청을 처리하지 못했습니다.');
        }
        return boundedJson(response, 1_100_000);
      }
      const context = await rpc('ppomi_context', {}) as Context;
      if (!context?.workspace || !UUID.test(context.workspace.id) || !context.device || !UUID.test(context.device.id))
        throw new SafeError(401, 'unauthorized', '등록된 기기의 인증을 확인하지 못했습니다.');
      if (!(request.headers.get('content-type') ?? '').toLowerCase().startsWith('application/json')) invalid();
      const body = object(await boundedJson(request, path === '/v1/responses' ? 1_000_000 : 16_384));   // a Responses turn carries instructions, tools and history
      let result: unknown;
      if (path === '/v1/session') {
        exactFields(body, ['mode', 'responses'], []);
        if (body.mode !== undefined && body.mode !== 'voice' && body.mode !== 'text') invalid();
        if (body.responses !== undefined && typeof body.responses !== 'boolean') invalid();
        const textMode = body.mode === 'text';
        const key = env.OPENAI_API_KEY ?? '', model = env.OPENAI_REALTIME_MODEL ?? 'gpt-realtime-2.1', textModel = env.OPENAI_TEXT_MODEL ?? TEXT_MODEL;
        if (!key || /\s/.test(key) || !MODEL_ID.test(model) || !MODEL_ID.test(textModel)) throw new SafeError(503, 'not_configured', '에이전트 서버 설정이 필요합니다.');
        if (textMode && body.responses === true) {
          // A client that can drive the Responses loop through its native bridge gets the flagship text model; no secret is minted.
          return new Response(JSON.stringify({ transport: 'responses', model: textModel }), { status: 200, headers: NO_STORE });
        }
        const safetyIdentifier = createHmac('sha256', encryptionKey(env)).update('ppomi-voice-safety\0').update(JSON.stringify([context.workspace.id, context.device.id])).digest('hex');
        let response: Response;
        try {
          response = await transport('https://api.openai.com/v1/realtime/client_secrets', { method: 'POST', redirect: 'error', signal: AbortSignal.timeout(20_000),
            headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json',
              'OpenAI-Safety-Identifier': safetyIdentifier }, cache: 'no-store',
            body: JSON.stringify({ expires_after: { anchor: 'created_at', seconds: 60 }, session: { type: 'realtime', model, tracing: null,
              ...(textMode ? { output_modalities: ['text'], audio: { input: { transcription: null, turn_detection: null } } }
                : { audio: { input: { transcription: { model: 'gpt-4o-mini-transcribe' } }, output: { voice: 'marin' } } }) } }) });   // a call logs both sides
        } catch { throw new SafeError(502, 'voice_unavailable', '에이전트 연결을 준비하지 못했습니다.'); }
        if (!response.ok) { await response.body?.cancel(); throw new SafeError(502, 'voice_unavailable', '에이전트 연결을 준비하지 못했습니다.'); }
        const secret = object(await boundedJson(response, 65_536));
        if (typeof secret.value !== 'string' || !/^ek_[A-Za-z0-9_-]{8,4096}$/.test(secret.value) || secret.value === key)
          throw new SafeError(502, 'voice_unavailable', '임시 에이전트 연결 정보를 확인하지 못했습니다.');
        result = { clientSecret: secret.value, model };
      } else if (path === '/v1/responses') {
        // Proxy one non-streaming Responses call for the bundled text chat. The key, model and storage policy stay here.
        const key = env.OPENAI_API_KEY ?? '', textModel = env.OPENAI_TEXT_MODEL ?? TEXT_MODEL;
        if (!key || /\s/.test(key) || !MODEL_ID.test(textModel)) throw new SafeError(503, 'not_configured', '에이전트 서버 설정이 필요합니다.');
        if (!('input' in body) || body.stream === true) invalid();
        const { model: _clientModel, stream: _stream, store: _store, previous_response_id: _previous, ...rest } = body;
        const safetyIdentifier = createHmac('sha256', encryptionKey(env)).update('ppomi-text-safety\0').update(JSON.stringify([context.workspace.id, context.device.id])).digest('hex');
        let response: Response;
        try {
          response = await transport('https://api.openai.com/v1/responses', { method: 'POST', redirect: 'error', signal: AbortSignal.timeout(110_000),
            headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', 'OpenAI-Safety-Identifier': safetyIdentifier }, cache: 'no-store',
            body: JSON.stringify({ ...rest, model: textModel, stream: false, store: false }) });
        } catch { throw new SafeError(502, 'model_unavailable', '모델 응답을 받지 못했습니다.'); }
        if (!response.ok) {
          await response.body?.cancel();
          if (response.status === 429) throw new SafeError(429, 'rate_limited', '잠시 후 다시 시도해 주세요.');
          throw new SafeError(502, 'model_unavailable', `모델 응답 실패(${response.status})`);
        }
        result = object(await boundedJson(response, 2_000_000));
      } else if (path === '/v1/memories/list') {
        exactFields(body, []);
        const key = encryptionKey(env), rows = await rpc('ppomi_agent_memory_list', {});
        if (!Array.isArray(rows) || rows.length > 50) throw new SafeError(502, 'invalid_response', '저장 기록 응답을 확인하지 못했습니다.');
        result = { records: rows.map(row => decrypt(row as StoredMemory, context.workspace.id, key)) };
      } else if (path === '/v1/memories/save') {
        const input = memoryInput(body), key = encryptionKey(env);
        const encrypted = encrypt(input, context.workspace.id, key);
        const row = await rpc('ppomi_agent_memory_save', { p_id: input.id, p_envelope: encrypted.envelope, p_request_digest: encrypted.digest, p_replaces_id: input.replacesId ?? null });
        result = { record: decrypt(row as StoredMemory, context.workspace.id, key) };
      } else {
        exactFields(body, ['id']);
        const deleted = await rpc('ppomi_agent_memory_delete', { p_id: uuid(body.id) });
        if (!deleted || (deleted as Json).deleted !== true) throw new SafeError(502, 'invalid_response', '기록 삭제를 확인하지 못했습니다.');
        result = { deleted: true };
      }
      return new Response(JSON.stringify(result), { status: 200, headers: NO_STORE });
    } catch (error) {
      const safe = error instanceof SafeError ? error : new SafeError(500, 'internal_error', '요청을 처리하지 못했습니다.');
      return new Response(JSON.stringify({ error: { code: safe.code, message: safe.message } }), { status: safe.status, headers: NO_STORE });
    }
  };
}

export const handleRequest = createHandler();
