import { createClient } from '@supabase/supabase-js';

export const supabaseUrl = process.env.SUPABASE_URL!;
export const supabasePublishableKey =
  process.env.SUPABASE_PUBLISHABLE_KEY ?? process.env.SUPABASE_ANON_KEY!;

if (!supabaseUrl || !supabasePublishableKey) {
  throw new Error('Missing SUPABASE_URL or SUPABASE_PUBLISHABLE_KEY');
}

// Public auth client only. Database request paths must use createUserDb() so the
// caller JWT reaches PostgREST and RLS remains authoritative.
export const supabaseAuth = createClient(supabaseUrl, supabasePublishableKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});
