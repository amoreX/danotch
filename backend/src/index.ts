import 'dotenv/config';
import express from 'express';
import { NotchBridge } from './events/notch.js';
import { createTaskRoutes } from './routes/tasks.js';
import { config } from './config.js';

const app = express();
app.use(express.json());

// Connect to the notch app's WebSocket server
const notch = new NotchBridge(config.notchWsUrl);
notch.connect();

// Health
app.get('/health', (_req, res) => {
  res.json({ status: 'ok', notch_connected: notch.connected });
});

// Routes
app.use('/api', createTaskRoutes(notch));

app.listen(config.port, () => {
  console.log(`[danotch-backend] http://localhost:${config.port}`);
  console.log(`  POST /api/chat   — simple Claude conversation`);
  console.log(`  POST /api/agent  — Claude Agent SDK (tools: Bash, Read, Edit...)`);
  console.log(`  GET  /api/tasks  — list all tasks`);
});

process.on('SIGINT', () => {
  notch.disconnect();
  process.exit(0);
});
