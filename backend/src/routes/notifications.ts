import { Router } from 'express';
import { requireAuth } from '../middleware/auth.js';
import { supabase } from '../lib/supabase.js';

export function createNotificationRoutes(): Router {
  const router = Router();

  // List notifications
  router.get('/', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    const { data, error } = await supabase
      .from('notifications')
      .select('*')
      .eq('user_id', userId)
      .order('created_at', { ascending: false })
      .limit(50);

    if (error) {
      res.status(500).json({ error: error.message });
      return;
    }
    res.json({ notifications: data ?? [] });
  });

  // Unread count
  router.get('/unread-count', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    const { count, error } = await supabase
      .from('notifications')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', userId)
      .eq('read', false);

    if (error) {
      res.status(500).json({ error: error.message });
      return;
    }
    res.json({ count: count ?? 0 });
  });

  // Mark one as read
  router.post('/:id/read', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    const { error } = await supabase
      .from('notifications')
      .update({ read: true })
      .eq('id', req.params.id)
      .eq('user_id', userId);

    if (error) {
      res.status(500).json({ error: error.message });
      return;
    }
    res.json({ ok: true });
  });

  // Mark all as read
  router.post('/read-all', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    const { error } = await supabase
      .from('notifications')
      .update({ read: true })
      .eq('user_id', userId)
      .eq('read', false);

    if (error) {
      res.status(500).json({ error: error.message });
      return;
    }
    res.json({ ok: true });
  });

  return router;
}
