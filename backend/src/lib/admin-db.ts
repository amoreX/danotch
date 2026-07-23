import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { supabaseUrl } from './supabase.js';

export const ADMIN_OPERATIONS = [
  'bootstrap',
  'webhook',
  'scheduler',
  'fencing',
  'reconciliation',
  'provider',
  'runner',
] as const;
export type AdminOperation = typeof ADMIN_OPERATIONS[number];

const operationKeyNames: Record<AdminOperation, string> = {
  bootstrap: 'SUPABASE_BOOTSTRAP_SECRET_KEY',
  webhook: 'SUPABASE_WEBHOOK_SECRET_KEY',
  scheduler: 'SUPABASE_SCHEDULER_SECRET_KEY',
  fencing: 'SUPABASE_FENCING_SECRET_KEY',
  reconciliation: 'SUPABASE_RECONCILIATION_SECRET_KEY',
  provider: 'SUPABASE_PROVIDER_SECRET_KEY',
  runner: 'SUPABASE_RUNNER_SECRET_KEY',
};

const clients = new Map<AdminOperation, SupabaseClient>();

export function getAdminDb(operation: AdminOperation): SupabaseClient {
  const cached = clients.get(operation);
  if (cached) return cached;

  const operationKey = process.env[operationKeyNames[operation]];
  const developmentFallback = process.env.NODE_ENV === 'production'
    ? undefined
    : process.env.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_SERVICE_KEY;
  const key = operationKey ?? developmentFallback;
  if (!key) {
    throw new Error(
      `Missing ${operationKeyNames[operation]}. `
      + 'Production privileged operations require an operation-specific Supabase secret.',
    );
  }

  const client = createClient(supabaseUrl, key, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  clients.set(operation, client);
  return client;
}

// Deliberately no unrestricted exported client. Each call site must name its
// operation so static tests can enforce the matrix.
