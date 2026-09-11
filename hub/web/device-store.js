import { RecordError, generateDevice, verifyDevice } from './record-crypto.js';

const DB_NAME = 'ppomi.web.record-keys.v1';
const STORE = 'devices';

/** Only non-extractable X25519 handles and public device metadata enter IndexedDB. */
export function createDeviceStore({ indexedDB = globalThis.indexedDB, crypto = globalThis.crypto, locks = globalThis.navigator?.locks } = {}) {
  let database;
  function open() {
    if (database) return database;
    database = new Promise((resolve, reject) => {
      if (!indexedDB) return reject(new RecordError('unsupported'));
      const request = indexedDB.open(DB_NAME, 1);
      const timer = setTimeout(() => reject(new RecordError('storage')), 5000);
      request.onupgradeneeded = () => request.result.createObjectStore(STORE, { keyPath: 'userID' });
      request.onerror = request.onblocked = () => { clearTimeout(timer); reject(new RecordError('storage')); };
      request.onsuccess = () => { clearTimeout(timer); const db = request.result; db.onversionchange = () => { db.close(); database = null; }; resolve(db); };
    });
    database.catch(() => { database = null; });
    return database;
  }
  async function operation(mode, action) {
    const db = await open();
    return new Promise((resolve, reject) => {
      let result;
      try {
        const tx = db.transaction(STORE, mode);
        const request = action(tx.objectStore(STORE));
        request.onsuccess = () => { result = request.result; };
        tx.oncomplete = () => resolve(result);
        tx.onabort = tx.onerror = () => reject(new RecordError('storage'));
      } catch { reject(new RecordError('unsupported')); }
    });
  }
  function exclusive(userID, action) { return locks?.request ? locks.request(`${DB_NAME}:${userID}`, { mode: 'exclusive' }, action) : action(); }
  return {
    loadOrCreate(userID, check = () => {}) {
      return exclusive(userID, async () => {
        check();
        let device = await operation('readonly', store => store.get(userID));
        check();
        if (!device) {
          const created = await generateDevice(userID, crypto);
          check();
          // add, not put: a tab without Web Locks must not overwrite another
          // tab's newly created private key. Read whichever transaction won.
          try { await operation('readwrite', store => store.add(created)); }
          catch (error) {
            if (!(await operation('readonly', store => store.get(userID)))) throw error;
          }
          check();
          device = await operation('readonly', store => store.get(userID));
        }
        check();
        const restored = await verifyDevice(device, userID, crypto);
        check();
        return restored;
      });
    },
    clear(userID) { return exclusive(userID, () => operation('readwrite', store => store.delete(userID))); },
  };
}
