/**
 * Separated liveness and readiness probes.
 *
 * Liveness — process-focused. Returns 200 whenever the Node process is
 * alive and the event loop is not stuck. Load balancers use this to decide
 * whether to restart the container. It must never depend on downstream state.
 *
 * Readiness — dependency-focused. Returns 200 only when all named checks
 * pass. Load balancers use this to decide whether to route traffic. Checks
 * may perform real I/O (DB ping, migration ledger count, etc.).
 */

export interface ReadinessCheckResult {
  ok: boolean;
  detail?: string;
}

export interface ReadinessCheck {
  name: string;
  check: () => Promise<ReadinessCheckResult>;
}

export interface LivenessStatus {
  status: 'live';
  pid: number;
  uptime_seconds: number;
}

export interface ReadinessStatus {
  status: 'ready' | 'not_ready';
  checks: Record<string, ReadinessCheckResult>;
}

export function livenessStatus(): LivenessStatus {
  return {
    status: 'live',
    pid: process.pid,
    uptime_seconds: Math.floor(process.uptime()),
  };
}

export async function readinessStatus(
  checks: readonly ReadinessCheck[],
): Promise<ReadinessStatus> {
  const settled = await Promise.allSettled(
    checks.map(({ name, check }) =>
      check()
        .then((r) => [name, r] as const)
        .catch((e) => [name, { ok: false, detail: e instanceof Error ? e.message : String(e) }] as const),
    ),
  );

  const results: Record<string, ReadinessCheckResult> = {};
  for (const item of settled) {
    if (item.status === 'fulfilled') {
      const [name, result] = item.value;
      results[name] = result;
    }
  }

  const allOk = Object.values(results).every((r) => r.ok);
  return { status: allOk ? 'ready' : 'not_ready', checks: results };
}

/**
 * Build the readiness checks for the production server.
 *
 * These are injected so that tests can supply fakes without real I/O.
 */
export interface ReadinessCheckDeps {
  /** Supabase SupabaseClient or equivalent with .from().select() interface */
  db: { from(table: string): { select(col: string): Promise<{ error: unknown; count: number | null }> } };
  /** True when the device gateway WebSocket server is attached and accepting */
  gatewayReady: () => boolean;
  /** True when at least one critical LLM provider key is configured */
  providerConfigured: () => boolean;
  /** True when live checkout and verified webhook handling are configured */
  billingConfigured: () => boolean;
  /** Expected number of applied migrations (length of sql/ directory) */
  expectedMigrationCount: number;
}

export function buildProductionChecks(deps: ReadinessCheckDeps): ReadinessCheck[] {
  return [
    {
      name: 'migration_ledger',
      async check() {
        const { error, count } = await deps.db
          .from('danotch_schema_migrations')
          .select('count');
        if (error) return { ok: false, detail: String(error) };
        if (count !== deps.expectedMigrationCount) {
          return {
            ok: false,
            detail: `expected ${deps.expectedMigrationCount} migrations, found ${count}`,
          };
        }
        return { ok: true };
      },
    },
    {
      name: 'database',
      async check() {
        const { error } = await deps.db.from('danotch_schema_migrations').select('count');
        if (error) return { ok: false, detail: String(error) };
        return { ok: true };
      },
    },
    {
      name: 'gateway',
      check: async () => {
        const ready = deps.gatewayReady();
        return ready ? { ok: true } : { ok: false, detail: 'gateway not attached' };
      },
    },
    {
      name: 'provider',
      check: async () => {
        const configured = deps.providerConfigured();
        return configured
          ? { ok: true }
          : { ok: false, detail: 'no critical LLM provider configured' };
      },
    },
    {
      name: 'billing',
      check: async () => {
        const configured = deps.billingConfigured();
        return configured
          ? { ok: true }
          : { ok: false, detail: 'Dodo live checkout/webhook configuration is incomplete' };
      },
    },
  ];
}
