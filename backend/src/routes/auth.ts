import { Router } from 'express';
import { createClient } from '@supabase/supabase-js';
import { supabase } from '../lib/supabase.js';
import { COMPOSIO_APPS } from '../composio/tools.js';

const SUPABASE_URL = process.env.SUPABASE_URL!;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY!;

// Anon client for auth operations (signup/login use anon key)
const anonClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const SUPPORTED_APPS = COMPOSIO_APPS.map(a => a.appType);

function usernameFromEmail(email: string): string {
  return email.split('@')[0];
}

export function createAuthRoutes(): Router {
  const router = Router();

  // Sign up with email + password
  router.post('/signup', async (req, res) => {
    const { email, password, full_name } = req.body;
    console.log(`[auth] POST /signup email=${email} name=${full_name}`);

    if (!email || !password) {
      res.status(400).json({ error: 'email and password are required' });
      return;
    }

    // Create user via admin API (auto-confirms, no email verification needed)
    const { data: adminData, error: adminError } = await supabase.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
    });

    if (adminError || !adminData.user) {
      console.log(`[auth] Signup failed: ${adminError?.message}`);
      res.status(400).json({ error: adminError?.message ?? 'Signup failed' });
      return;
    }

    const userId = adminData.user.id;
    console.log(`[auth] User created: ${userId}`);

    // Now sign them in to get a session with tokens
    const { data: loginData, error: loginError } = await anonClient.auth.signInWithPassword({
      email,
      password,
    });

    if (loginError || !loginData.session) {
      console.log(`[auth] Auto-login failed after signup: ${loginError?.message}`);
      res.status(500).json({ error: 'Account created but login failed — try signing in' });
      return;
    }
    console.log(`[auth] Signup complete, session issued for ${email}`);

    // Create user_profiles row
    const { error: profileError } = await supabase.from('user_profiles').insert({
      id: userId,
      email,
      full_name: full_name || usernameFromEmail(email),
    });

    if (profileError) {
      console.error('[auth] Failed to create profile:', profileError.message);
    }

    // Create connected_apps rows for all supported apps
    const appRows = SUPPORTED_APPS.map((app) => ({
      user_id: userId,
      app_type: app,
      active: false,
    }));
    const { error: appsError } = await supabase.from('connected_apps').insert(appRows);

    if (appsError) {
      console.error('[auth] Failed to create connected_apps:', appsError.message);
    }

    res.json({
      user: {
        id: userId,
        email,
        full_name: full_name || usernameFromEmail(email),
      },
      session: {
        access_token: loginData.session.access_token,
        refresh_token: loginData.session.refresh_token,
        expires_at: loginData.session.expires_at,
      },
    });
  });

  // Log in with email + password
  router.post('/login', async (req, res) => {
    const { email, password } = req.body;
    console.log(`[auth] POST /login email=${email}`);

    if (!email || !password) {
      res.status(400).json({ error: 'email and password are required' });
      return;
    }

    const { data, error } = await anonClient.auth.signInWithPassword({
      email,
      password,
    });

    if (error || !data.session) {
      res.status(401).json({ error: error?.message ?? 'Login failed' });
      return;
    }

    // Fetch profile
    const { data: profile } = await supabase
      .from('user_profiles')
      .select('full_name, avatar_url, plan')
      .eq('id', data.user.id)
      .single();

    res.json({
      user: {
        id: data.user.id,
        email: data.user.email,
        full_name: profile?.full_name ?? usernameFromEmail(email),
        avatar_url: profile?.avatar_url,
        plan: profile?.plan ?? 'free',
      },
      session: {
        access_token: data.session.access_token,
        refresh_token: data.session.refresh_token,
        expires_at: data.session.expires_at,
      },
    });
  });

  // Refresh token
  router.post('/refresh', async (req, res) => {
    const { refresh_token } = req.body;

    if (!refresh_token) {
      res.status(400).json({ error: 'refresh_token is required' });
      return;
    }

    const { data, error } = await anonClient.auth.refreshSession({
      refresh_token,
    });

    if (error || !data.session) {
      res.status(401).json({ error: error?.message ?? 'Refresh failed' });
      return;
    }

    res.json({
      session: {
        access_token: data.session.access_token,
        refresh_token: data.session.refresh_token,
        expires_at: data.session.expires_at,
      },
    });
  });

  // Get current user profile (requires auth)
  router.get('/me', async (req, res) => {
    const header = req.headers.authorization;
    if (!header?.startsWith('Bearer ')) {
      res.status(401).json({ error: 'Unauthorized' });
      return;
    }

    // Decode token to get user ID (without full middleware since this is in auth routes)
    const jwt = await import('jsonwebtoken');
    try {
      const payload = jwt.default.verify(header.slice(7), process.env.SUPABASE_JWT_SECRET!, {
        algorithms: ['HS256'],
      }) as { sub: string };

      const { data: profile, error } = await supabase
        .from('user_profiles')
        .select('*')
        .eq('id', payload.sub)
        .single();

      if (error || !profile) {
        res.status(404).json({ error: 'Profile not found' });
        return;
      }

      res.json({ user: profile });
    } catch {
      res.status(401).json({ error: 'Invalid token' });
    }
  });

  return router;
}
