import { Router } from 'express';
import { runChat, runAgent, getTask, getAllTasks } from '../agent/runner.js';
import type { NotchBridge } from '../events/notch.js';

export function createTaskRoutes(notch: NotchBridge): Router {
  const router = Router();

  // List all tasks
  router.get('/tasks', (_req, res) => {
    res.json({ tasks: getAllTasks() });
  });

  // Get a specific task
  router.get('/tasks/:id', (req, res) => {
    const task = getTask(req.params.id);
    if (!task) {
      res.status(404).json({ error: 'Task not found' });
      return;
    }
    res.json({ task });
  });

  // Simple chat (no tools, just Claude API conversation)
  router.post('/chat', async (req, res) => {
    const { message, session_id } = req.body;
    if (!message || typeof message !== 'string') {
      res.status(400).json({ error: 'message is required' });
      return;
    }
    try {
      const task = await runChat(message, notch, session_id);
      res.json({ task: { id: task.id, status: task.status, result: task.result, error: task.error } });
    } catch (err) {
      res.status(500).json({ error: err instanceof Error ? err.message : 'Unknown error' });
    }
  });

  // Agent task (Claude Agent SDK — has tools: Bash, Read, Edit, etc.)
  router.post('/agent', async (req, res) => {
    const { message, session_id, cwd } = req.body;
    if (!message || typeof message !== 'string') {
      res.status(400).json({ error: 'message is required' });
      return;
    }
    try {
      const task = await runAgent(message, notch, { sessionId: session_id, cwd });
      res.json({ task: { id: task.id, status: task.status, result: task.result } });
    } catch (err) {
      res.status(500).json({ error: err instanceof Error ? err.message : 'Unknown error' });
    }
  });

  return router;
}
