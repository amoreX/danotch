import 'dotenv/config';
import express from 'express';
import { NotchBridge } from './events/notch.js';
import { createTaskRoutes } from './routes/tasks.js';
import { createAuthRoutes } from './routes/auth.js';
import { createScheduledRoutes } from './routes/scheduled.js';
import { createNotificationRoutes } from './routes/notifications.js';
import { createAppRoutes } from './routes/apps.js';
import { createProviderRoutes } from './routes/provider.js';
import { createBillingRoutes } from './routes/billing.js';
import { startScheduler, stopScheduler } from './scheduler/index.js';
import { config } from './config.js';

const app = express();
// Webhook signature verification needs the exact raw request bytes, so this
// path gets its own raw-body parser ahead of the global JSON parser. Scoped
// only to /api/billing/webhook — body-parser skips re-parsing a request whose
// body was already consumed by an earlier parser.
app.use('/api/billing/webhook', express.raw({ type: 'application/json' }));
app.use(express.json());

// Request logging
app.use((req, _res, next) => {
  const auth = req.headers.authorization ? '(auth)' : '(no-auth)';
  console.log(`[${new Date().toISOString().slice(11, 19)}] ${req.method} ${req.path} ${auth}`);
  next();
});

// Connect to the notch app's WebSocket server
const notch = new NotchBridge(config.notchWsUrl);
notch.connect();

// Health
app.get('/health', (_req, res) => {
  res.json({ status: 'ok', notch_connected: notch.connected });
});

// Routes
app.use('/auth', createAuthRoutes());
app.use('/api', createTaskRoutes(notch));
app.use('/api/scheduled', createScheduledRoutes());
app.use('/api/notifications', createNotificationRoutes());
app.use('/api/apps', createAppRoutes());
app.use('/api/provider', createProviderRoutes());
app.use('/api/billing', createBillingRoutes());

app.listen(config.port, () => {
  console.log(`[perch-backend] http://localhost:${config.port}`);

  // Start scheduler after server is up
  startScheduler(notch);
});

function shutdown() {
  console.log('\n[perch-backend] Shutting down...');
  stopScheduler();
  notch.disconnect();
  // Force exit — don't wait for dangling connections
  setTimeout(() => process.exit(0), 500);
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
