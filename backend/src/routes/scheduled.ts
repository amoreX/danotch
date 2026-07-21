import { Router } from 'express';
import { requireAuth } from '../middleware/auth.js';
import { userDb as supabase } from '../lib/user-db.js';
import { getAdminDb } from '../lib/admin-db.js';
import { computeNextRun, scheduleToHuman } from '../scheduler/compute-next.js';
import { validateScheduledPatch } from './scheduled-policy.js';
import { SupabaseQuotaStore, requestQuotaSubject } from '../security/quota-store.js';

const scheduleQuota = new SupabaseQuotaStore(getAdminDb('scheduler'));

export function createScheduledRoutes(): Router {
  const router = Router();
  router.use(requireAuth);
  router.use(async (req, res, next) => {
    if (req.method === 'GET') {
      next();
      return;
    }
    try {
      await scheduleQuota.consume({
        capability: 'scheduler',
        subject: requestQuotaSubject({ userId: req.user!.sub }),
      });
      next();
    } catch {
      res.status(503).json({ error: 'Scheduling quota is temporarily unavailable.' });
    }
  });

  // List user's scheduled tasks
  router.get('/', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    console.log(`[scheduled] GET / userId=${userId}`);

    const { data, error } = await supabase
      .from('danotch_scheduled_tasks')
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
    const validation = validateScheduledPatch(req.body);
    if (!validation.ok) {
      res.status(400).json({ error: validation.error });
      return;
    }
    const updates = validation.updates;
    let nextRunAt: string | undefined;

    console.log(`[scheduled] PATCH /${taskId} userId=${userId}`, updates);

    // If re-enabling or changing schedule, recompute next_run_at
    if (updates.enabled === true || updates.cron || updates.interval_ms) {
      const { data: existing } = await supabase
        .from('danotch_scheduled_tasks')
        .select('task_type, cron, interval_ms')
        .eq('id', taskId)
        .eq('user_id', userId)
        .single();

      if (existing) {
        const cron = updates.cron ?? existing.cron;
        const interval = updates.interval_ms ?? existing.interval_ms;
        try {
          nextRunAt = computeNextRun(existing.task_type, cron, interval).toISOString();
        } catch {
          res.status(400).json({ error: 'Invalid schedule' });
          return;
        }
      }
    }

    updates.updated_at = new Date().toISOString();

    const { error } = await supabase
      .from('danotch_scheduled_tasks')
      .update(updates)
      .eq('id', taskId)
      .eq('user_id', userId);

    if (error) {
      res.status(500).json({ error: error.message });
      return;
    }
    if (nextRunAt) {
      const { error: schedulingError } = await getAdminDb('scheduler')
        .from('danotch_scheduled_tasks')
        .update({ next_run_at: nextRunAt })
        .eq('id', taskId)
        .eq('user_id', userId);
      if (schedulingError) {
        res.status(503).json({ error: 'Task updated but could not be rescheduled' });
        return;
      }
    }
    if (updates.enabled === false) {
      await getAdminDb('scheduler')
        .from('danotch_scheduled_tasks')
        .update({
          run_state: 'cancelled',
          lease_owner: null,
          lease_token: null,
          lease_expires_at: null,
          retry_at: null,
        })
        .eq('id', taskId)
        .eq('user_id', userId);
    } else if (updates.enabled === true) {
      await getAdminDb('scheduler')
        .from('danotch_scheduled_tasks')
        .update({ run_state: 'ready', attempt_count: 0, retry_at: null })
        .eq('id', taskId)
        .eq('user_id', userId);
    }
    res.json({ ok: true });
  });

  // Delete
  router.delete('/:id', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    const taskId = req.params.id as string;
    console.log(`[scheduled] DELETE /${taskId} userId=${userId}`);

    const { error } = await supabase
      .from('danotch_scheduled_tasks')
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

    const { error } = await getAdminDb('scheduler')
      .from('danotch_scheduled_tasks')
      .update({
        next_run_at: new Date().toISOString(),
        run_state: 'ready',
        attempt_count: 0,
        retry_at: null,
      })
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
