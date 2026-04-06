import { Router } from 'express';
import { runChat, getTask, getAllTasks, getThreads, getThreadMessages, deleteThread } from '../agent/runner.js';
import type { NotchBridge } from '../events/notch.js';
import { requireAuth, extractUserId } from '../middleware/auth.js';

export function createTaskRoutes(notch: NotchBridge): Router {
  const router = Router();

  // ── In-memory tasks (real-time state) ──

  router.get('/tasks', (_req, res) => {
    const tasks = getAllTasks();
    console.log(`[tasks] GET /tasks → ${tasks.length} tasks`);
    res.json({ tasks });
  });

  router.get('/tasks/:id', (req, res) => {
    const task = getTask(req.params.id);
    if (!task) {
      console.log(`[tasks] GET /tasks/${req.params.id} → not found`);
      res.status(404).json({ error: 'Task not found' });
      return;
    }
    console.log(`[tasks] GET /tasks/${req.params.id} → ${task.status}`);
    res.json({ task });
  });

  // ── Chat (auth optional — works with or without token) ──

  router.post('/chat', async (req, res) => {
    const { message, session_id, thread_id } = req.body;
    if (!message || typeof message !== 'string') {
      res.status(400).json({ error: 'message is required' });
      return;
    }

    const userId = await extractUserId(req.headers.authorization);
    console.log(`[chat] message="${message.slice(0, 50)}" userId=${userId ?? 'none'} threadId=${thread_id ?? 'new'} sessionId=${session_id ?? 'new'}`);

    try {
      const task = await runChat(message, notch, {
        sessionId: session_id,
        userId,
        threadId: thread_id,
      });
      console.log(`[chat] Done → taskId=${task.id} threadId=${task.threadId} status=${task.status}`);
      res.json({
        task: { id: task.id, status: task.status, result: task.result, error: task.error },
        thread_id: task.threadId,
      });
    } catch (err) {
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
