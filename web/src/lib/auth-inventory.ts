/**
 * Current Supabase Auth call sites. Slice 2–3 migrate these; this spike does not.
 * Keep paths relative to the repo root.
 */

export type AuthSurface = 'mac' | 'ipad' | 'android' | 'windows' | 'hub' | 'agent' | 'scripts';

export type AuthCallSite = {
  surface: AuthSurface;
  path: string;
  mechanism: 'pkce-google' | 'password-grant' | 'token-refresh' | 'bearer-rpc' | 'admin-bootstrap' | 'none';
  notes: string;
};

export const SUPABASE_AUTH_CALL_SITES: readonly AuthCallSite[] = [
  {
    surface: 'mac',
    path: 'Ppomi/Sources/Ppomi/Shared/SupabaseAuth.swift',
    mechanism: 'pkce-google',
    notes: 'Shared PKCE authorize/token/refresh against /auth/v1. Google only. Keychain session.',
  },
  {
    surface: 'mac',
    path: 'Ppomi/Sources/Ppomi/Shared/GoogleAccount.swift',
    mechanism: 'pkce-google',
    notes: 'ASWebAuthenticationSession → exchange → ppomi_register_device / ppomi_rebind_device. Requires JWT sub UUID.',
  },
  {
    surface: 'mac',
    path: 'Ppomi/Sources/Ppomi/Shared/SharedServerClient.swift',
    mechanism: 'token-refresh',
    notes: 'Google refresh_token, or legacy email/password grant + ppomi_context. X-Ppomi-Device header.',
  },
  {
    surface: 'mac',
    path: 'Ppomi/Sources/Ppomi/Shared/SharedServerConfiguration.swift',
    mechanism: 'password-grant',
    notes: 'Legacy device file: url, publishableKey, email, password, deviceId.',
  },
  {
    surface: 'mac',
    path: 'Ppomi/Sources/Ppomi/Views/MeSheet.swift',
    mechanism: 'pkce-google',
    notes: 'Settings account sheet. "Google 계정으로 로그인".',
  },
  {
    surface: 'mac',
    path: 'Ppomi/Sources/Ppomi/PpomiApp.swift',
    mechanism: 'token-refresh',
    notes: 'Starts GoogleAccount sharing and per-device key wrap on launch.',
  },
  {
    surface: 'mac',
    path: 'Ppomi/Sources/Ppomi/Serve/SharedTools.swift',
    mechanism: 'bearer-rpc',
    notes: 'MCP shared_status → ppomi_context.',
  },
  {
    surface: 'mac',
    path: 'Ppomi/Sources/Ppomi/Shared/SharedRecordVault.swift',
    mechanism: 'bearer-rpc',
    notes: 'Encrypted records use the same session + ppomi_context. Server-key/Vault policy (MZZ-27) stays.',
  },
  {
    surface: 'ipad',
    path: 'iPad/Sources/PadAuth.swift',
    mechanism: 'pkce-google',
    notes: 'Same SupabaseAuth PKCE as Mac. Callback ppomi://auth.',
  },
  {
    surface: 'ipad',
    path: 'iPad/Sources/PadBridge.swift',
    mechanism: 'token-refresh',
    notes: 'Refreshes Supabase tokens; all REST calls carry apikey + X-Ppomi-Device.',
  },
  {
    surface: 'ipad',
    path: 'iPad/Sources/PpomiPad.swift',
    mechanism: 'pkce-google',
    notes: 'Viewer chrome login button.',
  },
  {
    surface: 'ipad',
    path: 'iPad/Sources/PadSettings.swift',
    mechanism: 'pkce-google',
    notes: 'Reads PpomiServer.supabaseURL / publishableKey.',
  },
  {
    surface: 'ipad',
    path: 'iPad/Sources/PadVault.swift',
    mechanism: 'bearer-rpc',
    notes: 'Reads Mac-wrapped record ciphertext. Not an auth provider.',
  },
  {
    surface: 'android',
    path: 'Android/app/src/main/java/com/ppomi/androidbridge/SupabaseClient.java',
    mechanism: 'password-grant',
    notes: '/auth/v1/token?grant_type=password from device email/password. Token never given to JS.',
  },
  {
    surface: 'android',
    path: 'Android/app/src/main/java/com/ppomi/androidbridge/SupabaseSettings.java',
    mechanism: 'password-grant',
    notes: 'Imported device config. Rejects service_role / JWT-shaped keys.',
  },
  {
    surface: 'android',
    path: 'Android/app/src/main/java/com/ppomi/androidbridge/SharedTaskController.java',
    mechanism: 'bearer-rpc',
    notes: 'Shared runs/documents over the password-grant client.',
  },
  {
    surface: 'android',
    path: 'Android/app/src/main/java/com/ppomi/androidbridge/VoiceServerClient.java',
    mechanism: 'bearer-rpc',
    notes: 'Agent server calls use the native Supabase access token.',
  },
  {
    surface: 'android',
    path: 'Android/app/src/debug/java/com/ppomi/androidbridge/DebugProvisioningActivity.kt',
    mechanism: 'password-grant',
    notes: 'Debug import of device-specific Supabase settings.',
  },
  {
    surface: 'windows',
    path: 'Ppomi/Sources/Ppomi/Serve/MacBrowser.swift',
    mechanism: 'none',
    notes: 'No Windows Supabase Auth client. Parallels guest is driven by the Mac session.',
  },
  {
    surface: 'hub',
    path: 'hub/',
    mechanism: 'none',
    notes: 'Public catalog + KV footprints. No user session today. This Next app (`web/`) is the Clerk spike.',
  },
  {
    surface: 'agent',
    path: 'agent/server/handler.ts',
    mechanism: 'bearer-rpc',
    notes: 'Bearer Supabase access token → ppomi_context on every request. No service_role.',
  },
  {
    surface: 'agent',
    path: 'agent/scripts/control-model-smoke.ts',
    mechanism: 'password-grant',
    notes: 'Smoke login with device email/password from .ppomi/ssot config.',
  },
  {
    surface: 'agent',
    path: 'agent/scripts/korean-voice-smoke.ts',
    mechanism: 'password-grant',
    notes: 'Same password grant as other agent smokes.',
  },
  {
    surface: 'agent',
    path: 'agent/scripts/playbook-model-smoke.ts',
    mechanism: 'password-grant',
    notes: 'Same password grant as other agent smokes.',
  },
  {
    surface: 'agent',
    path: 'agent/scripts/model-smoke.ts',
    mechanism: 'password-grant',
    notes: 'Same password grant as other agent smokes.',
  },
  {
    surface: 'scripts',
    path: 'scripts/shared-server.py',
    mechanism: 'admin-bootstrap',
    notes: 'CLI admin users + password grant. Management keys stay in the logged-in Supabase CLI, not the repo.',
  },
];

export function sliceNote(surface: AuthSurface): string {
  switch (surface) {
    case 'hub':
      return 'Slice 2: replace the empty hub session with this Next/Clerk app. Do not rewrite footprint APIs here.';
    case 'mac':
    case 'ipad':
      return 'Slice 3: Clerk deep link / token exchange instead of Supabase Google PKCE. Keep X-Ppomi-Device.';
    case 'android':
      return 'Slice 3: replace password-grant device accounts after Clerk user mapping exists.';
    case 'windows':
      return 'No native auth to migrate. Keep driving the guest from the Mac session.';
    case 'agent':
      return 'Slice 2–3: accept a Clerk-backed JWT that still satisfies ppomi_context + device header.';
    case 'scripts':
      return 'Slice 5+: bootstrap against Clerk user ids, not auth.users email/password.';
    default: {
      const exhaustive: never = surface;
      return exhaustive;
    }
  }
}
