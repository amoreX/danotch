import express, { type Express, type Request, type Response, type NextFunction } from 'express';
import { randomUUID } from 'node:crypto';
import type { loadConfig } from './config.js';
import type { DeviceService } from './devices/device-service.js';
import type { DeviceGateway } from './events/device-gateway.js';
import type { NotchBridge } from './events/notch.js';
import { livenessStatus, readinessStatus, type ReadinessCheck } from './health.js';
import { requireAuth } from './middleware/auth.js';
import { createActionRoutes } from './routes/actions.js';
import { createAppRoutes } from './routes/apps.js';
import { createAuthRoutes } from './routes/auth.js';
import { createBillingRoutes } from './routes/billing.js';
import { createDeviceRoutes } from './routes/devices.js';
import { createNotificationRoutes } from './routes/notifications.js';
import { createProviderRoutes } from './routes/provider.js';
import { createRunRoutes } from './routes/runs.js';
import { createScheduledRoutes } from './routes/scheduled.js';
import { createTaskRoutes } from './routes/tasks.js';
import type { QuotaStore } from './security/quota-store.js';

export interface AppDependencies {
  config: ReturnType<typeof loadConfig>;
  notch: NotchBridge;
  devices: DeviceService;
  gateway: DeviceGateway;
  quota: QuotaStore;
  readinessChecks: readonly ReadinessCheck[];
}

/** Append a correlation ID to every response and res.locals for downstream use. */
function correlationMiddleware(req: Request, res: Response, next: NextFunction): void {
  const inbound = req.headers['x-request-id'];
  const id =
    typeof inbound === 'string' && /^[\w\-]{8,64}$/.test(inbound)
      ? inbound
      : randomUUID();
  res.locals['correlationId'] = id;
  res.setHeader('X-Request-ID', id);
  next();
}

/** Structured request log that never emits auth tokens or body content. */
function requestLogger(req: Request, res: Response, next: NextFunction): void {
  const cid = (res.locals['correlationId'] as string | undefined) ?? '-';
  const auth = req.headers.authorization ? '(bearer)' : '(no-auth)';
  console.log(
    `[${new Date().toISOString().slice(0, 19)}Z] ${req.method} ${req.path} ${auth} rid=${cid}`,
  );
  next();
}

export function createApp(dependencies: AppDependencies): Express {
  const { config } = dependencies;
  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', config.trustProxy);

  // Correlation IDs must be set before any other middleware touches res.
  app.use(correlationMiddleware);

  // Raw body for billing webhook before JSON parsing.
  app.use('/api/billing/webhook', express.raw({ type: '*/*', limit: '256kb' }));
  app.use(express.json({ limit: config.jsonBodyLimit }));

  // Security headers on every response.
  app.use((_req, res, next) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader(
      'Content-Security-Policy',
      "default-src 'none'; frame-ancestors 'none'",
    );
    if (config.isProduction) {
      res.setHeader(
        'Strict-Transport-Security',
        'max-age=31536000; includeSubDomains',
      );
    }
    next();
  });

  app.use(requestLogger);

  // ── Health probes ───────────────────────────────────────────────────────────

  /**
   * Liveness — process-only. Restart the container if this fails.
   * Never checks downstream dependencies.
   */
  app.get('/health/live', (_req, res) => {
    res.json(livenessStatus());
  });

  /**
   * Readiness — dependency checks. Stop routing traffic if this fails.
   * Checks migration ledger, database reachability, gateway, and provider.
   */
  app.get('/health/ready', async (_req, res) => {
    const result = await readinessStatus(dependencies.readinessChecks);
    res.status(result.status === 'ready' ? 200 : 503).json(result);
  });

  /** Backward-compatible alias — kept for existing monitoring integrations. */
  app.get('/health', (_req, res) => {
    res.json({ status: 'ok', notch_connected: dependencies.notch.connected });
  });

  // ── Application routes ──────────────────────────────────────────────────────

  app.use('/auth', createAuthRoutes());
  app.use('/api/devices', createDeviceRoutes({
    service: dependencies.devices,
    requireAuth,
    freshAuthMaxAgeMs: config.deviceGateway.freshAuthMaxAgeMs,
    quota: dependencies.quota,
    onDeviceInvalidated: ({ userId, deviceId }) => {
      if (deviceId) dependencies.gateway.closeDevice(userId, deviceId);
      else dependencies.gateway.closeUser(userId);
    },
  }));
  app.use('/api', createTaskRoutes(dependencies.notch));
  app.use('/api/runs', createRunRoutes({ requireAuth }));
  app.use('/api/scheduled', createScheduledRoutes());
  app.use('/api/notifications', createNotificationRoutes());
  app.use('/api/apps', createAppRoutes());
  app.use('/api/provider', createProviderRoutes());
  app.use('/api/billing', createBillingRoutes());
  app.use('/api/actions', createActionRoutes());

  return app;
}
