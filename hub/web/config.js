// Public client configuration shared with Shared/SupabaseAuth.swift. No admin key.
export const SUPABASE_URL = 'https://nafutfqfbbmknzmyspus.supabase.co';
export const PUBLISHABLE_KEY = 'sb_publishable_diyhnKb7L4C1R5wt9FRoEQ_rQs8b4WX';
export const REDIRECT_URL = 'https://ppomi.muilyzz.com/';
// The agent server the Mac (SupabaseAuth.swift) and Android (VoiceBridgePolicy.java) apps use for text chat: it holds the
// model credentials and verifies the same Supabase session + X-Ppomi-Device header. The browser never holds a gateway key.
export const AGENT_ENDPOINT = 'https://ppomi-agent.vercel.app';
