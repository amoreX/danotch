import { createHash } from 'node:crypto';
import type { SupabaseClient } from '@supabase/supabase-js';

export type QuotaCapability =
  | 'signup'
  | 'trial'
  | 'provider'
  | 'enrollment'
  | 'oauth'
  | 'scheduler'
  | 'action'
  | 'replay'
  | 'storage';

export interface QuotaRequest {
  capability: QuotaCapability;
  subject: string;
  cost?: number;
  idempotencyKey?: string;
}

export interface QuotaStore {
  consume(request: QuotaRequest): Promise<void>;
}

export class QuotaUnavailableError extends Error {
  readonly code = 'quota_unavailable';
}

export class QuotaExceededError extends Error {
  readonly code = 'quota_exceeded';
  constructor(readonly retryAfterSeconds: number) {
    super('This operation is temporarily unavailable. Please try again later.');
  }
}

export class SupabaseQuotaStore implements QuotaStore {
  constructor(private readonly db: SupabaseClient) {}

  async consume(request: QuotaRequest): Promise<void> {
    const { data, error } = await this.db.rpc('danotch_consume_capability_quota', {
      p_capability: request.capability,
      p_subject_hash: hashQuotaSubject(request.subject),
      p_cost: request.cost ?? 1,
      p_idempotency_key: request.idempotencyKey ?? null,
    });
    if (error || !data) {
      throw new QuotaUnavailableError(error?.message ?? 'Quota storage is unavailable');
    }
    const result = data as { allowed?: boolean; retry_after_seconds?: number };
    if (result.allowed !== true) {
      throw new QuotaExceededError(Math.max(1, Number(result.retry_after_seconds ?? 60)));
    }
  }
}

export function hashQuotaSubject(subject: string): string {
  return createHash('sha256').update(subject.trim().toLowerCase()).digest('hex');
}

export function requestQuotaSubject(input: {
  ip?: string;
  userId?: string;
  email?: string;
  deviceId?: string;
}): string {
  return [
    input.userId ? `user:${input.userId}` : '',
    input.deviceId ? `device:${input.deviceId}` : '',
    input.email ? `email:${input.email}` : '',
    input.ip ? `ip:${input.ip}` : '',
  ].filter(Boolean).join('|') || 'unknown';
}
