import { AsyncLocalStorage } from 'node:async_hooks';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { supabasePublishableKey, supabaseUrl } from './supabase.js';

type UserDbContext = {
  accessToken: string;
  client: SupabaseClient;
};

const userDbContext = new AsyncLocalStorage<UserDbContext>();

export function createUserDb(accessToken: string): SupabaseClient {
  if (!accessToken) throw new Error('Caller access token is required');
  return createClient(supabaseUrl, supabasePublishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });
}

export function runWithUserDb<T>(accessToken: string, callback: () => T): T {
  return userDbContext.run(
    { accessToken, client: createUserDb(accessToken) },
    callback,
  );
}

export function getUserDb(): SupabaseClient {
  const context = userDbContext.getStore();
  if (!context) {
    throw new Error('User database access attempted outside authenticated request context');
  }
  return context.client;
}

export function getCallerAccessToken(): string {
  const context = userDbContext.getStore();
  if (!context) throw new Error('Caller token is unavailable outside authenticated request context');
  return context.accessToken;
}

// Context-bound facade keeps query helpers concise while resolving the client
// at call time (never at module import time).
export const userDb = new Proxy({} as SupabaseClient, {
  get(_target, property) {
    const client = getUserDb() as unknown as Record<PropertyKey, unknown>;
    const value = client[property];
    return typeof value === 'function' ? value.bind(client) : value;
  },
});
