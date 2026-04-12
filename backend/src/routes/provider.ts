import { Router } from 'express';
import { requireAuth } from '../middleware/auth.js';
import { supabase } from '../lib/supabase.js';
import { encrypt } from '../providers/crypto.js';
import { createProvider } from '../providers/factory.js';
import type { ProviderType } from '../providers/types.js';

const VALID_PROVIDERS: ProviderType[] = ['anthropic', 'openai', 'openrouter'];

const DEFAULT_MODELS: Record<ProviderType, string> = {
  anthropic: 'claude-sonnet-4-20250514',
  openai: 'gpt-4o',
  openrouter: 'anthropic/claude-sonnet-4-20250514',
};

function maskKey(key: string): string {
  if (key.length <= 8) return '••••••••';
  return key.slice(0, 7) + '••••' + key.slice(-4);
}

export function createProviderRoutes(): Router {
  const router = Router();

  // Get all provider configs for user (keys masked)
  router.get('/', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    console.log(`[provider] GET / userId=${userId}`);

    const { data, error } = await supabase
      .from('provider_configs')
      .select('id, provider, model_id, is_active, verified_at, created_at, updated_at')
      .eq('user_id', userId)
      .order('is_active', { ascending: false });

    if (error) {
      res.status(500).json({ error: error.message });
      return;
    }

    res.json({ configs: data ?? [] });
  });

  // Create or update provider config
  router.post('/', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    const { provider, api_key, model_id } = req.body;

    if (!provider || !VALID_PROVIDERS.includes(provider)) {
      res.status(400).json({ error: `provider must be one of: ${VALID_PROVIDERS.join(', ')}` });
      return;
    }
    if (!api_key || typeof api_key !== 'string') {
      res.status(400).json({ error: 'api_key is required' });
      return;
    }

    const modelId = model_id || DEFAULT_MODELS[provider as ProviderType];
    const encrypted = encrypt(api_key);

    // Deactivate all other providers for this user
    await supabase
      .from('provider_configs')
      .update({ is_active: false, updated_at: new Date().toISOString() })
      .eq('user_id', userId);

    // Upsert this provider config
    const { data, error } = await supabase
      .from('provider_configs')
      .upsert(
        {
          user_id: userId,
          provider,
          api_key_encrypted: encrypted,
          model_id: modelId,
          is_active: true,
          updated_at: new Date().toISOString(),
        },
        { onConflict: 'user_id,provider' }
      )
      .select('id, provider, model_id, is_active, verified_at, created_at, updated_at')
      .single();

    if (error) {
      console.error(`[provider] Upsert failed:`, error.message);
      res.status(500).json({ error: error.message });
      return;
    }

    console.log(`[provider] User ${userId} → ${provider} (${modelId})`);

    res.json({
      config: { ...data, api_key_masked: maskKey(api_key) },
    });
  });

  // Verify a provider key with a minimal test call
  router.post('/verify', requireAuth, async (req, res) => {
    const { provider, api_key, model_id } = req.body;

    if (!provider || !VALID_PROVIDERS.includes(provider)) {
      res.status(400).json({ error: `provider must be one of: ${VALID_PROVIDERS.join(', ')}` });
      return;
    }
    if (!api_key) {
      res.status(400).json({ error: 'api_key is required' });
      return;
    }

    const modelId = model_id || DEFAULT_MODELS[provider as ProviderType];

    try {
      const p = createProvider(provider as ProviderType, api_key, modelId);
      const result = await p.complete({
        messages: [{ role: 'user', content: 'Say "ok"' }],
        systemPrompt: 'Respond with only "ok".',
        maxTokens: 5,
      });

      // Update verified_at if user already has this provider saved
      const userId = req.user!.sub;
      await supabase
        .from('provider_configs')
        .update({ verified_at: new Date().toISOString() })
        .eq('user_id', userId)
        .eq('provider', provider);

      console.log(`[provider] Verified ${provider} key (model: ${modelId})`);
      res.json({ verified: true, model: modelId, response: result.text.slice(0, 50) });
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Verification failed';
      console.log(`[provider] Verification failed for ${provider}: ${msg}`);
      res.status(400).json({ verified: false, error: msg });
    }
  });

  // Delete provider config
  router.delete('/', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    const { provider } = req.body;

    const query = supabase
      .from('provider_configs')
      .delete()
      .eq('user_id', userId);

    if (provider) {
      query.eq('provider', provider);
    }

    const { error } = await query;
    if (error) {
      res.status(500).json({ error: error.message });
      return;
    }

    console.log(`[provider] Deleted ${provider ?? 'all'} config(s) for user ${userId}`);
    res.json({ ok: true });
  });

  return router;
}
