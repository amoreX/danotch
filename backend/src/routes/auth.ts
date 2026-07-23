import { Router } from 'express';
import { rateLimit } from 'express-rate-limit';
import { supabaseAuth } from '../lib/supabase.js';
import { createUserDb, userDb } from '../lib/user-db.js';
import { getAdminDb } from '../lib/admin-db.js';
import { requireAuth } from '../middleware/auth.js';
import { config } from '../config.js';
import { CaptchaVerifier } from '../security/captcha.js';
import {
  QuotaExceededError,
  SupabaseQuotaStore,
  hashQuotaSubject,
  requestQuotaSubject,
  type QuotaStore,
} from '../security/quota-store.js';
import { provisionVerifiedUser } from '../security/verified-provisioning.js';
import { isEmailVerified } from '../security/identity-state.js';

const GENERIC_SIGNUP_MESSAGE = 'If this address can be registered, a verification email has been sent.';
const GENERIC_RESEND_MESSAGE = 'If this address has a pending registration, a new email has been sent.';
const GENERIC_LOGIN_ERROR = 'Unable to sign in with those credentials.';

function usernameFromEmail(email: string): string {
  return email.split('@')[0];
}

export function createAuthRoutes(dependencies: {
  quota?: QuotaStore;
  verifyCaptcha?: (token: string, ip?: string) => Promise<boolean>;
} = {}): Router {
  const router = Router();
  const quota = dependencies.quota ?? new SupabaseQuotaStore(getAdminDb('bootstrap'));
  const captcha = new CaptchaVerifier(config.captcha);
  const verifyCaptcha = dependencies.verifyCaptcha ?? ((token, ip) => captcha.verify(token, ip));
  const loginLimiter = rateLimit({
    windowMs: config.authRateLimit.windowMs,
    limit: config.authRateLimit.login,
    standardHeaders: true,
    legacyHeaders: false,
    message: { error: GENERIC_LOGIN_ERROR, code: 'rate_limited' },
  });
  const refreshLimiter = rateLimit({
    windowMs: config.authRateLimit.windowMs,
    limit: config.authRateLimit.refresh,
    standardHeaders: true,
    legacyHeaders: false,
    message: { error: 'Session refresh is temporarily unavailable.', code: 'rate_limited' },
  });

  router.get('/signup/browser', (req, res) => {
    const email = typeof req.query.email === 'string' ? req.query.email : '';
    const captchaScript = config.captcha.provider === 'turnstile'
      ? 'https://challenges.cloudflare.com/turnstile/v0/api.js'
      : 'https://js.hcaptcha.com/1/api.js';
    const captchaClass = config.captcha.provider === 'turnstile' ? 'cf-turnstile' : 'h-captcha';
    res.type('html').send(`<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Create Perch account</title><script src="${captchaScript}" async defer></script></head><body style="background:#050505;color:#fff;font:16px system-ui;max-width:440px;margin:60px auto;padding:24px"><h1>Create your Perch account</h1><p>Email verification is required before a trial or integrations are enabled.</p><form method="post" action="/auth/signup" enctype="application/x-www-form-urlencoded"><input name="full_name" autocomplete="name" placeholder="Full name" required style="display:block;width:100%;margin:12px 0;padding:12px"><input name="email" type="email" autocomplete="email" value="${escapeHtml(email)}" placeholder="Email" required style="display:block;width:100%;margin:12px 0;padding:12px"><input name="password" type="password" autocomplete="new-password" minlength="10" placeholder="Password" required style="display:block;width:100%;margin:12px 0;padding:12px"><div class="${captchaClass}" data-sitekey="${escapeHtml(config.captcha.siteKey)}"></div><button style="margin-top:18px;padding:12px 18px">Send verification email</button></form></body></html>`);
  });

  // Public Supabase signup. No privileged auto-confirm and no session/trial is
  // issued before the email link is followed and provisioning succeeds.
  router.post('/signup', async (req, res) => {
    if (!config.containment.publicSignupEnabled) {
      res.status(503).json({
        error: 'New account registration is temporarily unavailable.',
        code: 'signup_frozen',
      });
      return;
    }
    const { email, password, full_name } = req.body;
    const captchaToken = req.body.captcha_token
      ?? req.body['cf-turnstile-response']
      ?? req.body['h-captcha-response'];

    if (typeof email !== 'string' || typeof password !== 'string' || password.length < 10) {
      res.status(202).json({ message: GENERIC_SIGNUP_MESSAGE, state: 'check_email' });
      return;
    }
    const emailDomain = email.trim().toLowerCase().split('@')[1] ?? '';
    if (config.signup.blockedDomains.has(emailDomain)) {
      res.status(202).json({ message: GENERIC_SIGNUP_MESSAGE, state: 'check_email' });
      return;
    }
    const captchaValid = await verifyCaptcha(String(captchaToken ?? ''), req.ip);
    if (!captchaValid) {
      res.status(202).json({ message: GENERIC_SIGNUP_MESSAGE, state: 'check_email' });
      return;
    }
    try {
      await Promise.all([
        quota.consume({
          capability: 'signup',
          subject: requestQuotaSubject({ ip: req.ip }),
        }),
        quota.consume({
          capability: 'signup',
          subject: requestQuotaSubject({ email }),
        }),
      ]);
    } catch (error) {
      if (error instanceof QuotaExceededError) res.setHeader('Retry-After', error.retryAfterSeconds);
      res.status(503).json({ message: GENERIC_SIGNUP_MESSAGE, state: 'check_email' });
      return;
    }
    const emailHash = hashQuotaSubject(email);
    const { error: enrollmentError } = await getAdminDb('bootstrap')
      .from('danotch_signup_enrollments')
      .upsert({
        email_hash: emailHash,
        requested_at: new Date().toISOString(),
        status: 'pending',
      }, { onConflict: 'email_hash' });
    if (enrollmentError) {
      res.status(503).json({ message: GENERIC_SIGNUP_MESSAGE, state: 'check_email' });
      return;
    }
    const { data: signupData } = await supabaseAuth.auth.signUp({
      email: email.trim().toLowerCase(),
      password,
      options: {
        emailRedirectTo: `${config.publicBaseUrl}/auth/verified`,
        data: { full_name: typeof full_name === 'string' ? full_name.trim().slice(0, 120) : '' },
      },
    });
    if (signupData.user?.id) {
      await getAdminDb('bootstrap').from('danotch_signup_enrollments').update({
        user_id: signupData.user.id,
        status: signupData.session ? 'blocked' : 'pending',
      }).eq('email_hash', emailHash);
    }
    const browserRequest = req.is('application/x-www-form-urlencoded');
    if (browserRequest) {
      res.type('html').status(202).send(browserStatePage(
        'Check your email',
        'Open the verification link on any device, then return to Perch and sign in.',
      ));
      return;
    }
    res.status(202).json({ message: GENERIC_SIGNUP_MESSAGE, state: 'check_email' });
  });

  // Log in with email + password
  router.post('/login', loginLimiter, async (req, res) => {
    const { email, password } = req.body;
    if (!email || !password) {
      res.status(401).json({ error: GENERIC_LOGIN_ERROR, code: 'invalid_credentials' });
      return;
    }

    const { data, error } = await supabaseAuth.auth.signInWithPassword({
      email,
      password,
    });

    if (error?.code === 'email_not_confirmed') {
      res.status(403).json({
        error: 'Verify your email before signing in.',
        code: 'email_verification_required',
        state: 'check_email',
      });
      return;
    }
    if (error || !data.session) {
      res.status(401).json({ error: GENERIC_LOGIN_ERROR, code: 'invalid_credentials' });
      return;
    }
    if (!data.user || !isEmailVerified(data.user)) {
      res.status(403).json({
        error: 'Verify your email before signing in.',
        code: 'email_verification_required',
        state: 'check_email',
      });
      return;
    }

    try {
      await provisionVerifiedUser(data.user);
    } catch {
      res.status(503).json({
        error: 'Your account is verified but setup is not complete. Try again.',
        code: 'provisioning_retry_required',
        state: 'repair_provisioning',
      });
      return;
    }

    const { data: profile, error: profileError } = await createUserDb(data.session.access_token)
      .from('danotch_user_profiles')
      .select('full_name, avatar_url, plan, billing_status, trial_started_at, trial_ends_at, lifetime_purchased_at')
      .eq('id', data.user.id)
      .single();

    if (profileError || !profile) {
      res.status(503).json({
        error: 'Your account setup could not be completed. Try again.',
        code: 'provisioning_retry_required',
        state: 'repair_provisioning',
      });
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

  router.get('/verified', (req, res) => {
    const failed = req.query.error || req.query.error_code;
    res.type('html').status(failed ? 400 : 200).send(browserStatePage(
      failed ? 'Verification link expired' : 'Email verified',
      failed
        ? 'Return to Perch to resend the email or change the address.'
        : 'Return to Perch and sign in. This works even when you opened the link on another device.',
    ));
  });

  router.post('/resend', async (req, res) => {
    const email = typeof req.body?.email === 'string' ? req.body.email.trim().toLowerCase() : '';
    const token = String(req.body?.captcha_token ?? '');
    if (email && await verifyCaptcha(token, req.ip)) {
      try {
        await quota.consume({
          capability: 'signup',
          subject: requestQuotaSubject({ ip: req.ip, email }),
        });
        await supabaseAuth.auth.resend({
          type: 'signup',
          email,
          options: { emailRedirectTo: `${config.publicBaseUrl}/auth/verified` },
        });
      } catch {
        // Anti-enumeration: quota, provider, and account-existence outcomes are
        // intentionally indistinguishable.
      }
    }
    res.status(202).json({ message: GENERIC_RESEND_MESSAGE, state: 'check_email' });
  });

  router.post('/change-email', requireAuth, async (req, res) => {
    const email = typeof req.body?.email === 'string' ? req.body.email.trim().toLowerCase() : '';
    const bearer = req.headers.authorization?.replace(/^Bearer\s+/i, '') ?? '';
    if (!email || !bearer) {
      res.status(400).json({ error: 'A valid new email is required.' });
      return;
    }
    const { error } = await createUserDb(bearer).auth.updateUser(
      { email },
      { emailRedirectTo: `${config.publicBaseUrl}/auth/verified` },
    );
    if (error) {
      res.status(202).json({ message: GENERIC_RESEND_MESSAGE, state: 'check_email' });
      return;
    }
    res.status(202).json({ message: GENERIC_RESEND_MESSAGE, state: 'check_email' });
  });

  router.post('/complete-verification', requireAuth, async (req, res) => {
    const bearer = req.headers.authorization?.replace(/^Bearer\s+/i, '') ?? '';
    const { data, error } = await supabaseAuth.auth.getUser(bearer);
    if (error || !data.user || !isEmailVerified(data.user)) {
      res.status(403).json({ state: 'check_email', code: 'email_verification_required' });
      return;
    }
    try {
      await provisionVerifiedUser(data.user);
      res.json({ state: 'ready' });
    } catch {
      res.status(503).json({ state: 'repair_provisioning', code: 'provisioning_retry_required' });
    }
  });

  // Refresh token
  router.post('/refresh', refreshLimiter, async (req, res) => {
    const { refresh_token } = req.body;

    if (!refresh_token) {
      res.status(400).json({ error: 'refresh_token is required' });
      return;
    }

    const { data, error } = await supabaseAuth.auth.refreshSession({
      refresh_token,
    });

    if (error || !data.session) {
      const upstreamStatus = Number((error as { status?: unknown } | null)?.status ?? 0);
      if (upstreamStatus >= 500) {
        res.status(503).json({
          error: 'Session refresh is temporarily unavailable.',
          code: 'refresh_unavailable',
        });
        return;
      }
      res.status(401).json({
        error: 'Session refresh failed.',
        code: 'invalid_refresh_token',
      });
      return;
    }
    if (!data.user || !isEmailVerified(data.user)) {
      res.status(403).json({ error: 'Email verification required.', code: 'email_verification_required' });
      return;
    }
    try {
      await provisionVerifiedUser(data.user);
    } catch {
      res.status(503).json({ error: 'Account setup is incomplete.', code: 'provisioning_retry_required' });
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
    const { data: profile, error } = await userDb
      .from('danotch_user_profiles')
      .select('id, email, full_name, avatar_url, plan, created_at, trial_started_at, trial_ends_at, lifetime_purchased_at, billing_status')
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

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (character) => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;',
  }[character] ?? character));
}

function browserStatePage(title: string, message: string): string {
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${escapeHtml(title)}</title></head><body style="background:#050505;color:#fff;font:16px system-ui;max-width:520px;margin:80px auto;padding:24px"><h1>${escapeHtml(title)}</h1><p>${escapeHtml(message)}</p><p style="color:#888">You may close this tab.</p></body></html>`;
}
