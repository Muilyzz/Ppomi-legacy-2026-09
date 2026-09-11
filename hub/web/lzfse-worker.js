// Dedicated worker; its own response CSP permits WebAssembly compilation only.
const LIMIT = 128 * 1024 * 1024;
self.onmessage = async ({data}) => {
  let instance, source = 0, destination = 0;
  try {
    const {bytes, maxOutputBytes} = data;
    if (!(bytes instanceof Uint8Array) || !bytes.length || bytes.length > LIMIT
      || !Number.isSafeInteger(maxOutputBytes) || maxOutputBytes < 1 || maxOutputBytes > LIMIT) throw new Error('size');
    const response = await fetch(new URL('./vendor/lzfse.wasm', import.meta.url), {credentials: 'omit', cache: 'no-cache'});
    if (!response.ok) throw new Error('decoder');
    ({instance} = await WebAssembly.instantiate(await response.arrayBuffer(), {
      env: {emscripten_notify_memory_growth() {}},
      // No file descriptors or logging capability are exposed to the decoder.
      wasi_snapshot_preview1: {fd_close: () => 0, fd_write: () => 52, fd_seek: () => 52},
    }));
    const e = instance.exports; e._initialize?.();
    source = e.malloc(bytes.length); if (!source) throw new Error('size');
    new Uint8Array(e.memory.buffer, source, bytes.length).set(bytes); bytes.fill(0);
    let capacity = Math.min(maxOutputBytes, Math.max(64 * 1024, bytes.length * 3));
    for (;;) {
      destination = e.malloc(capacity); if (!destination) throw new Error('size');
      const length = e.ppomi_decode(destination, capacity, source, bytes.length);
      if (length >= 0) {
        const result = new Uint8Array(e.memory.buffer, destination, length).slice();
        self.postMessage({bytes: result}, [result.buffer]); break;
      }
      new Uint8Array(e.memory.buffer, destination, capacity).fill(0); e.free(destination); destination = 0;
      if (length !== -2) throw new Error('decompression');
      if (capacity === maxOutputBytes) throw new Error('size');
      capacity = Math.min(maxOutputBytes, capacity * 2);
    }
  } catch (error) { self.postMessage({code: error?.message === 'size' ? 'size' : 'decompression'}); }
  finally {
    if (instance) new Uint8Array(instance.exports.memory.buffer).fill(0);
    self.close();
  }
};
