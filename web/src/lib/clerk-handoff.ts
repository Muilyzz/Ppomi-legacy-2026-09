export const CLERK_HANDOFF_ORIGIN = 'http://127.0.0.1:17382';
export const CLERK_SHELL_REDIRECT = '/account?from=shell';

export function wantsShellHandoff(search: string): boolean {
  const query = search.startsWith('?') ? search.slice(1) : search;
  return new URLSearchParams(query).get('from') === 'shell';
}

export function clerkAfterAuthUrl(from?: string | null): string {
  return from === 'shell' ? CLERK_SHELL_REDIRECT : '/account';
}

export async function postClerkHandoff(origin: string, token: string): Promise<boolean> {
  try {
    const response = await fetch(`${origin.replace(/\/+$/, '')}/clerk-session`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ clerkSession: token }),
    });
    return response.ok;
  } catch {
    return false;
  }
}
