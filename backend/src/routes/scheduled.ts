import { Router } from 'express';
import { requireAuth } from '../middleware/auth.js';
import { supabase } from '../lib/supabase.js';
import { computeNextRun, scheduleToHuman } from '../scheduler/compute-next.js';

export function createScheduledRoutes(): Router {
  const router = Router();

  // List user's scheduled tasks
  router.get('/', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    console.log(`[scheduled] GET / userId=${userId}`);

    const { data, error } = await supabase
      .from('scheduled_tasks')
      .select('*')
      .eq('user_id', userId)
      .order('created_at', { ascending: false });

    if (error) {
      res.status(500).json({ error: error.message });
      return;
    }

    const tasks = (data ?? []).map((t) => ({
      ...t,
      schedule_human: scheduleToHuman(t.task_type, t.cron, t.interval_ms),
    }));

    console.log(`[scheduled] → ${tasks.length} tasks`);
    res.json({ tasks });
  });

  // Toggle enable/disable
  router.patch('/:id', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    const taskId = req.params.id as string;
    const updates = req.body;

    console.log(`[scheduled] PATCH /${taskId} userId=${userId}`, updates);

    // If re-enabling or changing schedule, recompute next_run_at
    if (updates.enabled === true || updates.cron || updates.interval_ms) {
      const { data: existing } = await supabase
        .from('scheduled_tasks')
        .select('task_type, cron, interval_ms')
        .eq('id', taskId)
        .eq('user_id', userId)
        .single();

      if (existing) {
        const cron = updates.cron ?? existing.cron;
        const interval = updates.interval_ms ?? existing.interval_ms;
        updates.next_run_at = computeNextRun(existing.task_type, cron, interval).toISOString();
      }
    }

    updates.updated_at = new Date().toISOString();

    const { error } = await supabase
      .from('scheduled_tasks')
      .update(updates)
      .eq('id', taskId)
      .eq('user_id', userId);

    if (error) {
      res.status(500).json({ error: error.message });
      return;
    }
    res.json({ ok: true });
  });

  // Delete
  router.delete('/:id', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    const taskId = req.params.id as string;
    console.log(`[scheduled] DELETE /${taskId} userId=${userId}`);

    const { error } = await supabase
      .from('scheduled_tasks')
      .delete()
      .eq('id', taskId)
      .eq('user_id', userId);

    if (error) {
      res.status(500).json({ error: error.message });
      return;
    }
    res.json({ ok: true });
  });

  // Run immediately (for testing)
  router.post('/:id/run', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    const taskId = req.params.id as string;
    console.log(`[scheduled] POST /${taskId}/run userId=${userId}`);

    // Just reset next_run_at to now — the scheduler will pick it up
    const { error } = await supabase
      .from('scheduled_tasks')
      .update({ next_run_at: new Date().toISOString() })
      .eq('id', taskId)
      .eq('user_id', userId);

    if (error) {
      res.status(500).json({ error: error.message });
      return;
    }
    res.json({ ok: true, message: 'Task will run on next scheduler tick (~30s)' });
  });

  return router;
}
