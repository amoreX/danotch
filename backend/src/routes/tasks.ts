import { Router } from 'express';
import { rateLimit } from 'express-rate-limit';
import { runChat, getTask, getAllTasks, getThreads, getThreadMessages, deleteThread } from '../agent/runner.js';
import type { NotchBridge } from '../events/notch.js';
import { requireAuth } from '../middleware/auth.js';
import { EntitlementError } from '../billing/entitlements.js';

export function createTaskRoutes(notch: NotchBridge): Router {
  const router = Router();

  // ── Durable owner-scoped runs ──

  router.get('/tasks', requireAuth, async (req, res) => {
    const tasks = await getAllTasks(req.user!.sub);
    res.json({ tasks });
  });

  router.get('/tasks/:id', requireAuth, async (req, res) => {
    const taskId = req.params.id as string;
    const task = await getTask(req.user!.sub, taskId);
    if (!task) {
      res.status(404).json({ error: 'Task not found' });
      return;
    }
    res.json({ task });
  });

  // ── Chat (requires auth) ──
  // Authentication is mandatory: unauthenticated callers must not create tasks,
  // resolve providers, expose tools, or consume the server trial key.

  const chatLimiter = rateLimit({
    windowMs: 60 * 1000, // 1 minute
    limit: 30,
    standardHeaders: true,
    legacyHeaders: false,
    message: { error: 'Too many chat requests, please slow down.' },
  });

  router.post('/chat', chatLimiter, requireAuth, async (req, res) => {
    const { message, session_id, conversation_id, model_id, device_id } = req.body;
    if (!message || typeof message !== 'string') {
      res.status(400).json({ error: 'message is required' });
      return;
    }
    if (
      device_id !== undefined
      && (typeof device_id !== 'string'
        || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(device_id))
    ) {
      res.status(400).json({ error: 'device_id must be a UUID' });
      return;
    }
    if (
      session_id !== undefined
      && (typeof session_id !== 'string'
        || session_id.length > 128
        || !/^[A-Za-z0-9_-]+$/.test(session_id))
    ) {
      res.status(400).json({ error: 'session_id must be a safe opaque identifier' });
      return;
    }

    const history = Array.isArray(req.body.history)
      ? req.body.history
          .filter((m: unknown): m is { role: 'user' | 'assistant'; content: string } => {
            if (!m || typeof m !== 'object') return false;
            const item = m as Record<string, unknown>;
            return (item.role === 'user' || item.role === 'assistant') && typeof item.content === 'string';
          })
          .slice(-24)
      : [];

    const userId = req.user!.sub;
    try {
      const task = await runChat(message, notch, {
        sessionId: session_id,
        userId,
        conversationId: conversation_id,
        modelId: typeof model_id === 'string' ? model_id : undefined,
        deviceId: typeof device_id === 'string' ? device_id : undefined,
        idempotencyKey: typeof session_id === 'string' ? session_id : undefined,
        history,
      });
      console.log(`[chat] Request completed with status=${task.status}`);
      res.json({
        task: { id: task.id, status: task.status, result: task.result, error: task.error },
        thread_id: task.threadId,
        conversation_id: task.threadId,
      });
    } catch (err) {
      // Entitlement failures (trial expired, provider key required) are a
      // deterministic 402 the client can act on, not a generic 500.
      if (err instanceof EntitlementError) {
        const httpStatus = err.code === 'operational' ? 503 : 402;
        res.status(httpStatus).json({ error: err.message, code: err.code });
        return;
      }
      console.error('[chat] Request failed');
      res.status(500).json({ error: 'The request could not be completed.' });
    }
  });

  // ── Threads (requires auth) ──

  router.get('/threads', requireAuth, async (req, res) => {
    const threads = await getThreads(req.user!.sub);
    res.json({ threads });
  });

  router.get('/threads/:id', requireAuth, async (req, res) => {
    const messages = await getThreadMessages(req.user!.sub, req.params.id as string);
    res.json({ messages });
  });

  router.delete('/threads/:id', requireAuth, async (req, res) => {
    const ok = await deleteThread(req.user!.sub, req.params.id as string);
    if (!ok) { res.status(500).json({ error: 'Failed to delete' }); return; }
    res.json({ ok: true });
  });

  return router;
}
