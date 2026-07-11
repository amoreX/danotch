import { Router } from 'express';
import { requireAuth } from '../middleware/auth.js';
import { listPendingActions, approvePendingAction, rejectPendingAction } from '../actions/pending.js';

export function createActionRoutes(): Router {
  const router = Router();

  router.get('/', requireAuth, async (req, res) => {
    const actions = await listPendingActions(req.user!.sub);
    res.json({ actions });
  });

  router.post('/:id/approve', requireAuth, async (req, res) => {
    const result = await approvePendingAction(req.user!.sub, req.params.id as string);
    if (result.status === 'noop') {
      res.status(409).json({ error: 'Action is not pending (already decided, expired, or not found).' });
      return;
    }
    if (result.status === 'failed') {
      res.status(502).json({ error: result.error ?? 'Execution failed', status: 'failed' });
      return;
    }
    res.json({ status: 'completed', result: result.result });
  });

  router.post('/:id/reject', requireAuth, async (req, res) => {
    const ok = await rejectPendingAction(req.user!.sub, req.params.id as string);
    if (!ok) {
      res.status(409).json({ error: 'Action is not pending (already decided, expired, or not found).' });
      return;
    }
    res.json({ status: 'rejected' });
  });

  return router;
}
