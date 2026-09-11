const LIMIT = 128 * 1024 * 1024;
const failure = code => Object.assign(new Error(code), {code});

// Each invocation gets an isolated, short-lived heap. Never retain plaintext in
// a worker pool, IndexedDB, CacheStorage or a service worker.
export function decodeLZFSE(bytes, {maxOutputBytes = LIMIT, signal} = {}) {
  if (!(bytes instanceof Uint8Array) || !bytes.length || bytes.length > LIMIT
      || !Number.isSafeInteger(maxOutputBytes) || maxOutputBytes < 1 || maxOutputBytes > LIMIT) return Promise.reject(failure('size'));
  if (signal?.aborted) return Promise.reject(failure('cancelled'));
  return new Promise((resolve, reject) => {
    let worker, timer;
    const finish = (error, result) => {
      clearTimeout(timer); signal?.removeEventListener('abort', abort); worker?.terminate();
      error ? reject(error) : resolve(result);
    };
    const abort = () => finish(failure('cancelled'));
    try {
      worker = new Worker(new URL('./lzfse-worker.js', import.meta.url), {type: 'module'});
      signal?.addEventListener('abort', abort, {once: true});
      timer = setTimeout(() => finish(failure('decompression-timeout')), 20_000);
      worker.onerror = () => finish(failure('decompression'));
      worker.onmessage = ({data}) => {
        if (data?.bytes instanceof Uint8Array && data.bytes.length <= maxOutputBytes) finish(null, data.bytes);
        else finish(failure(data?.code === 'size' ? 'size' : 'decompression'));
      };
      const copy = bytes.slice();
      worker.postMessage({bytes: copy, maxOutputBytes}, [copy.buffer]);
    } catch { finish(failure('decompression')); }
  });
}
