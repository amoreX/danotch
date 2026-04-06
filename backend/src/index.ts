import 'dotenv/config';
import express from 'express';
import { NotchBridge } from './events/notch.js';
import { createTaskRoutes } from './routes/tasks.js';
import { createAuthRoutes } from './routes/auth.js';
import { createScheduledRoutes } from './routes/scheduled.js';
import { createNotificationRoutes } from './routes/notifications.js';
import { startScheduler, stopScheduler } from './scheduler/index.js';
import { config } from './config.js';

const app = express();
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

app.listen(config.port, () => {
  console.log(`[danotch-backend] http://localhost:${config.port}`);

  // Start scheduler after server is up
  startScheduler(notch);
});

process.on('SIGINT', () => {
  stopScheduler();
  notch.disconnect();
  process.exit(0);
});

process.on('SIGTERM', () => {
  stopScheduler();
  notch.disconnect();
  process.exit(0);
});
