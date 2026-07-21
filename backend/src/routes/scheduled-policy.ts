const EDITABLE_FIELDS = new Set([
  'enabled',
  'name',
  'prompt',
  'cron',
  'interval_ms',
  'notify_user',
  'target_app',
]);

type PatchResult =
  | { ok: true; updates: Record<string, unknown> }
  | { ok: false; error: string };

export function validateScheduledPatch(body: unknown): PatchResult {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return { ok: false, error: 'PATCH body must be an object' };
  }

  const input = body as Record<string, unknown>;
  const fields = Object.keys(input);
  if (fields.length === 0) {
    return { ok: false, error: 'At least one editable field is required' };
  }

  const rejected = fields.filter((field) => !EDITABLE_FIELDS.has(field));
  if (rejected.length > 0) {
    return { ok: false, error: `Protected or unknown fields: ${rejected.join(', ')}` };
  }

  if (input.enabled !== undefined && typeof input.enabled !== 'boolean') {
    return { ok: false, error: 'enabled must be a boolean' };
  }
  if (input.notify_user !== undefined && typeof input.notify_user !== 'boolean') {
    return { ok: false, error: 'notify_user must be a boolean' };
  }
  for (const field of ['name', 'prompt', 'cron'] as const) {
    if (input[field] !== undefined && (typeof input[field] !== 'string' || input[field].length === 0)) {
      return { ok: false, error: `${field} must be a non-empty string` };
    }
  }
  if (
    input.interval_ms !== undefined
    && (typeof input.interval_ms !== 'number'
      || !Number.isSafeInteger(input.interval_ms)
      || input.interval_ms < 60_000)
  ) {
    return { ok: false, error: 'interval_ms must be an integer of at least 60000' };
  }
  if (
    input.target_app !== undefined
    && input.target_app !== null
    && (typeof input.target_app !== 'string' || input.target_app.length === 0)
  ) {
    return { ok: false, error: 'target_app must be a non-empty string or null' };
  }

  return { ok: true, updates: { ...input } };
}
