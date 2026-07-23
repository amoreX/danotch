import { Router } from 'express';
import { requireAuth } from '../middleware/auth.js';
import { userDb as supabase } from '../lib/user-db.js';
import { getAdminDb } from '../lib/admin-db.js';
import { encrypt, decrypt } from '../providers/crypto.js';
import { createProvider } from '../providers/factory.js';
import { config } from '../config.js';
import type { ProviderType } from '../providers/types.js';
import { SupabaseQuotaStore, requestQuotaSubject } from '../security/quota-store.js';

const VALID_PROVIDERS: ProviderType[] = ['anthropic', 'openai', 'openrouter'];

const DEFAULT_MODELS = config.defaultModels;

type ModelOption = {
  id: string;
  name: string;
  context_length?: number;
};

export function createProviderRoutes(): Router {
  const router = Router();
  const providerQuota = new SupabaseQuotaStore(getAdminDb('provider'));
  router.use(requireAuth);
  router.use(async (req, res, next) => {
    if (req.method === 'GET' && req.path !== '/models') {
      next();
      return;
    }
    try {
      await providerQuota.consume({
        capability: 'provider',
        subject: requestQuotaSubject({ userId: req.user!.sub }),
      });
      next();
    } catch {
      res.status(503).json({ error: 'Provider operations are temporarily unavailable.' });
    }
  });

  // Get all provider configs for user (keys masked)
  router.get('/', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    console.log(`[provider] GET / userId=${userId}`);

    const { data, error } = await supabase
      .from('danotch_provider_configs')
      .select('id, provider, model_id, is_active, verified_at, created_at, updated_at')
      .eq('user_id', userId)
      .order('is_active', { ascending: false });

    if (error) {
      res.status(500).json({ error: error.message });
      return;
    }

    res.json({ configs: data ?? [] });
  });

  // List available models for the active provider using the saved API key.
  router.get('/models', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    console.log(`[provider] GET /models userId=${userId}`);

    const { data, error } = await getAdminDb('provider')
      .from('danotch_provider_configs')
      .select('provider, api_key_encrypted, model_id')
      .eq('user_id', userId)
      .eq('is_active', true)
      .single();

    if (error || !data) {
      res.json({
        provider: 'anthropic',
        active_model: config.trial.defaultModel,
        models: config.containment.trialsEnabled ? config.trial.allowedModels : [],
      });
      return;
    }

    try {
      const apiKey = decrypt(data.api_key_encrypted);
      const provider = data.provider as ProviderType;
      const models = await fetchProviderModels(provider, apiKey);
      res.json({
        provider,
        active_model: data.model_id,
        models: models.length > 0 ? models : fallbackModels(provider),
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Failed to fetch models';
      console.warn(`[provider] Model list failed: ${msg}`);
      res.status(502).json({
        error: 'Provider models are temporarily unavailable.',
        models: fallbackModels(data.provider as ProviderType),
      });
    }
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
      .from('danotch_provider_configs')
      .update({ is_active: false, updated_at: new Date().toISOString() })
      .eq('user_id', userId);

    // Upsert this provider config
    const { data, error } = await supabase
      .from('danotch_provider_configs')
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
      config: data,
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

      // Update verified_at only if the tested key matches the user's saved config.
      // This prevents marking a stored key as verified when the user was testing a
      // different raw key in the verify form.
      const userId = req.user!.sub;
      const { data: savedConfig } = await getAdminDb('provider')
        .from('danotch_provider_configs')
        .select('api_key_encrypted')
        .eq('user_id', userId)
        .eq('provider', provider)
        .single();

      let matchesStored = false;
      if (savedConfig?.api_key_encrypted) {
        try {
          const storedKey = decrypt(savedConfig.api_key_encrypted);
          matchesStored = storedKey === api_key;
        } catch {
          matchesStored = false;
        }
      }

      if (matchesStored) {
        await getAdminDb('provider')
          .from('danotch_provider_configs')
          .update({ verified_at: new Date().toISOString() })
          .eq('user_id', userId)
          .eq('provider', provider);
      }

      console.log(`[provider] Verified ${provider} key (model: ${modelId})`);
      res.json({ verified: true, model: modelId, response: result.text.slice(0, 50) });
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Verification failed';
      console.log(`[provider] Verification failed for ${provider}: ${msg}`);
      res.status(400).json({ verified: false, error: 'Provider verification failed.' });
    }
  });

  // Activate an existing saved provider without re-entering its API key.
  router.post('/activate', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    const { provider } = req.body;

    if (!provider || !VALID_PROVIDERS.includes(provider)) {
      res.status(400).json({ error: `provider must be one of: ${VALID_PROVIDERS.join(', ')}` });
      return;
    }

    const { data: existing, error: lookupError } = await supabase
      .from('danotch_provider_configs')
      .select('id')
      .eq('user_id', userId)
      .eq('provider', provider)
      .single();

    if (lookupError || !existing) {
      res.status(404).json({ error: 'Provider config not found' });
      return;
    }

    await supabase
      .from('danotch_provider_configs')
      .update({ is_active: false, updated_at: new Date().toISOString() })
      .eq('user_id', userId);

    const { data, error } = await supabase
      .from('danotch_provider_configs')
      .update({ is_active: true, updated_at: new Date().toISOString() })
      .eq('user_id', userId)
      .eq('provider', provider)
      .select('id, provider, model_id, is_active, verified_at, created_at, updated_at')
      .single();

    if (error) {
      res.status(500).json({ error: error.message });
      return;
    }

    console.log(`[provider] Activated ${provider} for user ${userId}`);
    res.json({ config: data });
  });

  // Use server default provider without deleting saved BYOK configs.
  router.post('/default', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    const { error } = await supabase
      .from('danotch_provider_configs')
      .update({ is_active: false, updated_at: new Date().toISOString() })
      .eq('user_id', userId);

    if (error) {
      res.status(500).json({ error: error.message });
      return;
    }

    console.log(`[provider] Using server default for user ${userId}`);
    res.json({ ok: true });
  });

  // Delete provider config
  router.delete('/', requireAuth, async (req, res) => {
    const userId = req.user!.sub;
    const { provider } = req.body;

    const query = supabase
      .from('danotch_provider_configs')
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

async function fetchProviderModels(provider: ProviderType, apiKey: string): Promise<ModelOption[]> {
  switch (provider) {
    case 'openrouter':
      return fetchOpenRouterModels(apiKey);
    case 'openai':
      return fetchOpenAIModels(apiKey);
    case 'anthropic':
      return fetchAnthropicModels(apiKey);
  }
}

async function fetchOpenRouterModels(apiKey: string): Promise<ModelOption[]> {
  const resp = await fetch('https://openrouter.ai/api/v1/models', {
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'User-Agent': 'Perch/1.0',
    },
    signal: AbortSignal.timeout(15_000),
  });
  if (!resp.ok) throw new Error(`OpenRouter models failed (${resp.status})`);
  const json = await resp.json() as { data?: Array<Record<string, unknown>> };
  return (json.data ?? [])
    .map((m) => ({
      id: String(m.id ?? ''),
      name: String(m.name ?? m.id ?? ''),
      context_length: typeof m.context_length === 'number' ? m.context_length : undefined,
    }))
    .filter((m) => m.id.length > 0)
    .sort((a, b) => a.name.localeCompare(b.name));
}

async function fetchOpenAIModels(apiKey: string): Promise<ModelOption[]> {
  const resp = await fetch('https://api.openai.com/v1/models', {
    headers: { Authorization: `Bearer ${apiKey}` },
    signal: AbortSignal.timeout(15_000),
  });
  if (!resp.ok) throw new Error(`OpenAI models failed (${resp.status})`);
  const json = await resp.json() as { data?: Array<Record<string, unknown>> };
  return (json.data ?? [])
    .map((m) => String(m.id ?? ''))
    .filter((id) => id.startsWith('gpt-') || id.startsWith('o'))
    .sort()
    .map((id) => ({ id, name: id }));
}

async function fetchAnthropicModels(apiKey: string): Promise<ModelOption[]> {
  const models: ModelOption[] = [];
  let afterId: string | undefined;

  for (let page = 0; page < 10; page += 1) {
    const url = new URL('https://api.anthropic.com/v1/models');
    url.searchParams.set('limit', '100');
    if (afterId) url.searchParams.set('after_id', afterId);

    const resp = await fetch(url, {
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      },
      signal: AbortSignal.timeout(15_000),
    });
    if (!resp.ok) throw new Error(`Anthropic models failed (${resp.status})`);
    const json = await resp.json() as {
      data?: Array<Record<string, unknown>>;
      has_more?: boolean;
      last_id?: string;
    };

    models.push(...(json.data ?? [])
      .map((m) => ({
        id: String(m.id ?? ''),
        name: String(m.display_name ?? m.id ?? ''),
        context_length: typeof m.max_input_tokens === 'number' ? m.max_input_tokens : undefined,
      }))
      .filter((m) => m.id.length > 0));

    if (!json.has_more || !json.last_id) break;
    afterId = json.last_id;
  }

  return dedupeModels(models);
}

function fallbackModels(provider: ProviderType): ModelOption[] {
  return (ProviderConfigFallback[provider] ?? []).map(([id, name]) => ({ id, name }));
}

function dedupeModels(models: ModelOption[]): ModelOption[] {
  const seen = new Set<string>();
  return models.filter((model) => {
    if (seen.has(model.id)) return false;
    seen.add(model.id);
    return true;
  });
}

const ProviderConfigFallback: Record<ProviderType, [string, string][]> = {
  anthropic: [
    ['claude-fable-5', 'Claude Fable 5'],
    ['claude-opus-4-8', 'Claude Opus 4.8'],
    ['claude-sonnet-4-6', 'Claude Sonnet 4.6'],
    ['claude-haiku-4-5-20251001', 'Claude Haiku 4.5'],
    ['claude-opus-4-7', 'Claude Opus 4.7'],
    ['claude-opus-4-6', 'Claude Opus 4.6'],
    ['claude-sonnet-4-5-20250929', 'Claude Sonnet 4.5'],
  ],
  openai: [
    ['gpt-5', 'GPT-5'],
    ['gpt-5-mini', 'GPT-5 mini'],
    ['gpt-4o', 'GPT-4o'],
  ],
  openrouter: [
    ['anthropic/claude-sonnet-4-6', 'Claude Sonnet 4.6'],
    ['anthropic/claude-opus-4-8', 'Claude Opus 4.8'],
    ['anthropic/claude-haiku-4-5', 'Claude Haiku 4.5'],
    ['openai/gpt-5', 'GPT-5'],
    ['google/gemini-2.5-pro', 'Gemini 2.5 Pro'],
  ],
};
