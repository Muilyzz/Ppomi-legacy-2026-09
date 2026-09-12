import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { spawn } from "node:child_process";
import {
  clerkAccountSignInUrl,
  clerkSessionToken,
  tokenFromClerkHandoffUrl,
  writeStoredClerkSession,
} from "./clerk-session.ts";

export const CLERK_HANDOFF_PORT = 17382;

export function clerkHandoffOrigin(port = CLERK_HANDOFF_PORT): string {
  return `http://127.0.0.1:${port}`;
}

export function accountOpenCommand(url: string, platform = process.platform): { cmd: string; args: string[] } {
  if (platform === "darwin") return { cmd: "open", args: [url] };
  if (platform === "win32") return { cmd: "cmd", args: ["/c", "start", "", url] };
  return { cmd: "xdg-open", args: [url] };
}

export type ClerkHandoffResult = {
  readonly stored: boolean;
  readonly listening: boolean;
  readonly already?: boolean;
};

function cors(res: ServerResponse, status: number, body: Record<string, unknown>): void {
  const json = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json",
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "POST, OPTIONS",
    "access-control-allow-headers": "content-type",
    "cache-control": "no-store",
    "content-length": Buffer.byteLength(json),
  });
  res.end(json);
}

async function readBody(req: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks).toString("utf8");
}

export function tokenFromHandoffBody(raw: string): string | undefined {
  const text = raw.trim();
  if (text === "") return undefined;
  const fromUrl = tokenFromClerkHandoffUrl(text);
  if (fromUrl) return fromUrl;
  try {
    const parsed = JSON.parse(text) as unknown;
    if (typeof parsed === "string") return parsed.trim() !== "" ? parsed.trim() : undefined;
    return clerkSessionToken(parsed, {});
  } catch {
    return text;
  }
}

function openAccount(url: string, opener?: (url: string) => void): void {
  if (opener) {
    opener(url);
    return;
  }
  const { cmd, args } = accountOpenCommand(url);
  spawn(cmd, args, { stdio: "ignore", detached: true }).unref();
}

export async function listenForClerkHandoff(opts: {
  env?: NodeJS.ProcessEnv;
  port?: number;
  timeoutMs?: number;
  openBrowser?: boolean;
  opener?: (url: string) => void;
} = {}): Promise<ClerkHandoffResult> {
  const env = opts.env ?? process.env;
  const port = opts.port ?? CLERK_HANDOFF_PORT;
  const timeoutMs = opts.timeoutMs ?? 10 * 60 * 1000;
  const accountUrl = clerkAccountSignInUrl(env);

  return await new Promise((resolve, reject) => {
    let done = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const server = createServer((req, res) => {
      void (async () => {
        if (req.method === "OPTIONS") {
          cors(res, 204, {});
          return;
        }
        if (req.method === "GET") {
          cors(res, 200, { listening: true });
          return;
        }
        if (req.method !== "POST") {
          cors(res, 404, { stored: false });
          return;
        }
        const token = tokenFromHandoffBody(await readBody(req));
        try {
          writeStoredClerkSession(token ?? "", env);
        } catch {
          cors(res, 400, { stored: false });
          return;
        }
        cors(res, 200, { stored: true });
        finish({ stored: true, listening: false });
      })().catch(() => {
        cors(res, 400, { stored: false });
      });
    });

    const finish = (value: ClerkHandoffResult): void => {
      if (done) return;
      done = true;
      if (timer !== undefined) clearTimeout(timer);
      server.close();
      resolve(value);
    };

    server.once("error", error => {
      if ((error as NodeJS.ErrnoException).code === "EADDRINUSE") {
        if (opts.openBrowser !== false) openAccount(accountUrl, opts.opener);
        finish({ stored: false, listening: true, already: true });
        return;
      }
      reject(error);
    });

    server.listen(port, "127.0.0.1", () => {
      if (opts.openBrowser !== false) openAccount(accountUrl, opts.opener);
      timer = setTimeout(() => {
        finish({ stored: false, listening: false });
      }, timeoutMs);
    });
  });
}
