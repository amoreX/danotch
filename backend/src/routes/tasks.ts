import { Router } from 'express';
import { rateLimit } from 'express-rate-limit';
import { runChat, getTask, getAllTasks, getThreads, getThreadMessages, deleteThread } from '../agent/runner.js';
import type { NotchBridge } from '../events/notch.js';
import { requireAuth } from '../middleware/auth.js';
import { EntitlementError } from '../billing/entitlements.js';

export function createTaskRoutes(notch: NotchBridge): Router {
  const router = Router();

  // ── In-memory tasks (real-time state) ──

  router.get('/tasks', requireAuth, (_req, res) => {
    const tasks = getAllTasks();
    console.log(`[tasks] GET /tasks → ${tasks.length} tasks`);
    res.json({ tasks });
  });

  router.get('/tasks/:id', requireAuth, (req, res) => {
    const taskId = req.params.id as string;
    const task = getTask(taskId);
    if (!task) {
      console.log(`[tasks] GET /tasks/${taskId} → not found`);
      res.status(404).json({ error: 'Task not found' });
      return;
    }
    console.log(`[tasks] GET /tasks/${taskId} → ${task.status}`);
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
    const { message, session_id, conversation_id, model_id } = req.body;
    if (!message || typeof message !== 'string') {
      res.status(400).json({ error: 'message is required' });
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
    console.log(`[chat] message="${message.slice(0, 50)}" userId=${userId} conversationId=${conversation_id ?? 'new'} history=${history.length} sessionId=${session_id ?? 'new'}`);

    try {
      const task = await runChat(message, notch, {
        sessionId: session_id,
        userId,
        conversationId: conversation_id,
        modelId: typeof model_id === 'string' ? model_id : undefined,
        history,
      });
      console.log(`[chat] Done → taskId=${task.id} conversationId=${task.threadId} status=${task.status}`);
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
      console.error(`[chat] Error:`, err);
      res.status(500).json({ error: err instanceof Error ? err.message : 'Unknown error' });
    }
  });

  // ── Threads (requires auth) ──

  router.get('/threads', requireAuth, async (req, res) => {
    console.log(`[threads] GET /threads userId=${req.user!.sub}`);
    const threads = await getThreads(req.user!.sub);
    console.log(`[threads] → ${threads.length} threads`);
    res.json({ threads });
  });

  router.get('/threads/:id', requireAuth, async (req, res) => {
    console.log(`[threads] GET /threads/${req.params.id} userId=${req.user!.sub}`);
    const messages = await getThreadMessages(req.user!.sub, req.params.id as string);
    console.log(`[threads] → ${messages.length} messages`);
    res.json({ messages });
  });

  router.delete('/threads/:id', requireAuth, async (req, res) => {
    console.log(`[threads] DELETE /threads/${req.params.id} userId=${req.user!.sub}`);
    const ok = await deleteThread(req.user!.sub, req.params.id as string);
    if (!ok) { res.status(500).json({ error: 'Failed to delete' }); return; }
    res.json({ ok: true });
  });

  return router;
}
