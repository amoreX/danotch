export function normalizeActionParameters(value: Record<string, unknown>): Record<string, unknown> {
  const normalize = (input: unknown): unknown => {
    if (input === null || typeof input === 'string' || typeof input === 'boolean') return input;
    if (typeof input === 'number') {
      if (!Number.isFinite(input)) throw new Error('Action parameters must contain finite numbers');
      return input;
    }
    if (Array.isArray(input)) return input.map(normalize);
    if (typeof input === 'object') {
      const object = input as Record<string, unknown>;
      const output: Record<string, unknown> = {};
      for (const key of Object.keys(object).sort()) {
        if (key === '__proto__' || key === 'constructor' || key === 'prototype') {
          throw new Error('Unsafe action parameter key');
        }
        if (object[key] !== undefined) output[key] = normalize(object[key]);
      }
      return output;
    }
    throw new Error('Unsupported action parameter value');
  };
  return normalize(value) as Record<string, unknown>;
}
