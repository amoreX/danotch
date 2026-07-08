import { Router } from 'express';
import { createClient } from '@supabase/supabase-js';
import { rateLimit } from 'express-rate-limit';
import { supabase } from '../lib/supabase.js';
import { COMPOSIO_APPS } from '../composio/tools.js';
import { requireAuth } from '../middleware/auth.js';

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

  // Limit brute-force attempts on auth endpoints
  const authLimiter = rateLimit({
    windowMs: 15 * 60 * 1000, // 15 minutes
    limit: 20,
    standardHeaders: true,
    legacyHeaders: false,
    skipSuccessfulRequests: true,
    message: { error: 'Too many attempts, please try again later.' },
  });
  router.use(authLimiter);

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

    const trialStartedAt = new Date();
    const trialEndsAt = new Date(trialStartedAt.getTime() + 14 * 24 * 60 * 60 * 1000);

    // Create user_profiles row
    const { error: profileError } = await supabase.from('danotch_user_profiles').insert({
      id: userId,
      email,
      full_name: full_name || usernameFromEmail(email),
      trial_started_at: trialStartedAt.toISOString(),
      trial_ends_at: trialEndsAt.toISOString(),
      billing_status: 'trialing',
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
    const { error: appsError } = await supabase.from('danotch_connected_apps').insert(appRows);

    if (appsError) {
      console.error('[auth] Failed to create connected_apps:', appsError.message);
    }

    res.json({
      user: {
        id: userId,
        email,
        full_name: full_name || usernameFromEmail(email),
        billing_status: 'trialing',
        trial_started_at: trialStartedAt.toISOString(),
        trial_ends_at: trialEndsAt.toISOString(),
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
    const { data: profile, error: profileError } = await supabase
      .from('danotch_user_profiles')
      .select('full_name, avatar_url, plan, billing_status, trial_started_at, trial_ends_at, lifetime_purchased_at')
      .eq('id', data.user.id)
      .single();

    if (profileError || !profile) {
      res.status(404).json({ error: 'Profile not found. Please sign up again.' });
      return;
    }

    res.json({
      user: {
        id: data.user.id,
        email: data.user.email,
        full_name: profile?.full_name ?? usernameFromEmail(email),
        avatar_url: profile?.avatar_url,
        plan: profile?.plan ?? 'free',
        billing_status: profile.billing_status ?? 'trialing',
        trial_started_at: profile.trial_started_at,
        trial_ends_at: profile.trial_ends_at,
        lifetime_purchased_at: profile.lifetime_purchased_at,
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
  router.get('/me', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    const { data: profile, error } = await supabase
      .from('danotch_user_profiles')
      .select('*')
      .eq('id', userId)
      .single();

    if (error || !profile) {
      res.status(404).json({ error: 'Profile not found' });
      return;
    }

    res.json({ user: profile });
  });

  return router;
}
