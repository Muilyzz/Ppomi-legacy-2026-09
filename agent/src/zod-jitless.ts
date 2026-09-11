// The hub page runs under script-src 'self' (no 'unsafe-eval'): zod must never probe `new Function` for its JIT fast path.
// zod reads the flag when a schema is built, so this module is the web entry's first import — before any of our or the
// SDKs' schemas exist.
import { z } from "zod";

z.config({ jitless: true });
