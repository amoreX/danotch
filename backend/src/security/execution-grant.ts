import { createHmac, timingSafeEqual } from 'node:crypto';

export const EXECUTION_GRANT_SIGNED_FIELDS = [
  'grant_id',
  'action_id',
  'action_hash',
  'parameters_hash',
  'registry_version',
  'action_type',
  'normalized_parameters',
  'capabilities',
  'image_digest',
  'workspace_bookmark_id',
  'result_disclosure_policy',
  'session_id',
  'device_key_fingerprint',
  'device_id',
  'fence',
  'expires_at',
  'transition_id',
] as const;

function stable(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(stable);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, child]) => [key, stable(child)]),
    );
  }
  return value;
}

export function stableCanonicalJSON(value: unknown): Buffer {
  return Buffer.from(JSON.stringify(stable(value)));
}

export function canonicalGrantBindings(payload: Record<string, unknown>): Buffer {
  const signed: Record<string, unknown> = {};
  for (const field of EXECUTION_GRANT_SIGNED_FIELDS) {
    if (!(field in payload)) throw new Error(`Missing signed grant field: ${field}`);
    signed[field] = payload[field];
  }
  return stableCanonicalJSON(signed);
}

export function signExecutionGrant(
  payload: Record<string, unknown>,
  grantToken: string,
): string {
  return createHmac('sha256', Buffer.from(grantToken))
    .update(canonicalGrantBindings(payload))
    .digest('base64url');
}

export function verifyExecutionGrantSignature(
  payload: Record<string, unknown>,
  grantToken: string,
  signature: string,
): boolean {
  try {
    const expected = Buffer.from(signExecutionGrant(payload, grantToken), 'base64url');
    const actual = Buffer.from(signature, 'base64url');
    return actual.length === expected.length && timingSafeEqual(actual, expected);
  } catch {
    return false;
  }
}
