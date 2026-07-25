import { resolve4, resolve6 } from 'node:dns/promises';
import { isIP } from 'node:net';
import type { ProviderPreference } from '../db/repositories.js';
import type { Credential, SecretBroker } from '../ipc/keychain-broker.js';
import { AnthropicProvider } from './anthropic.js';
import { OpenAIProvider } from './openai.js';
import type { LLMProvider, ProviderType } from './types.js';

const OPENROUTER_BASE_URL = 'https://openrouter.ai/api/v1';
const DEEPSEEK_BASE_URL = 'https://api.deepseek.com';

export class ProviderLookupError extends Error {}

/**
 * Create a provider instance from explicit config. Used by verify endpoint and factory.
 */
export function createProvider(
  provider: ProviderType,
  apiKey: string,
  modelId: string,
  baseUrl?: string | null,
): LLMProvider {
  switch (provider) {
    case 'anthropic':
      return new AnthropicProvider(apiKey, modelId);
    case 'openai':
      return new OpenAIProvider(apiKey, modelId);
    case 'openrouter':
      return new OpenAIProvider(apiKey, modelId, OPENROUTER_BASE_URL, 'openrouter');
    case 'deepseek':
      return new OpenAIProvider(apiKey, modelId, baseUrl || DEEPSEEK_BASE_URL, 'deepseek');
    case 'custom':
      if (!baseUrl) throw new ProviderLookupError('Custom provider requires an HTTPS base URL');
      return new OpenAIProvider(apiKey, modelId, baseUrl, 'custom');
    default:
      throw new ProviderLookupError(`Unsupported provider: ${provider as string}`);
  }
}

export async function resolveProvider(
  preference: ProviderPreference | undefined,
  broker: SecretBroker,
  overrides?: { modelId?: string | null; baseUrl?: string | null },
): Promise<LLMProvider> {
  if (!preference) throw new ProviderLookupError('An active provider is required');
  const baseUrl = overrides?.baseUrl ?? preference.base_url;
  if (preference.provider === 'custom') await validateProviderEndpoint(baseUrl ?? '');
  const apiKey = await broker.getCredential(preference.keychain_account as Credential);
  if (!apiKey) throw new ProviderLookupError('Provider credential is not configured');
  return createProvider(
    preference.provider,
    apiKey,
    overrides?.modelId || preference.model_id,
    baseUrl,
  );
}

export async function validateProviderEndpoint(
  value: string,
  lookup: (hostname: string) => Promise<string[]> = resolveAddresses,
): Promise<string> {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new ProviderLookupError('Custom base URL must be a valid HTTPS URL');
  }
  if (
    url.protocol !== 'https:' || url.username || url.password || url.search || url.hash
    || url.port && url.port !== '443'
  ) {
    throw new ProviderLookupError('Custom base URL must be credential-free HTTPS on port 443');
  }
  const hostname = url.hostname.replace(/^\[|\]$/g, '').toLowerCase();
  if (hostname === 'localhost' || hostname.endsWith('.local') || hostname.endsWith('.internal')) {
    throw new ProviderLookupError('Custom base URL must not target local hosts');
  }
  const addresses = isIP(hostname) ? [hostname] : await lookup(hostname);
  if (addresses.length === 0 || addresses.some(isPrivateAddress)) {
    throw new ProviderLookupError('Custom base URL must resolve only to public addresses');
  }
  return url.toString().replace(/\/$/, '');
}

async function resolveAddresses(hostname: string): Promise<string[]> {
  const [v4, v6] = await Promise.all([
    resolve4(hostname).catch(() => []),
    resolve6(hostname).catch(() => []),
  ]);
  return [...v4, ...v6];
}

function isPrivateAddress(address: string): boolean {
  if (address.includes(':')) {
    const normalized = address.toLowerCase();
    return normalized === '::1' || normalized === '::' || normalized.startsWith('fc')
      || normalized.startsWith('fd') || /^fe[89ab]/.test(normalized)
      || normalized.startsWith('2001:db8:');
  }
  const parts = address.split('.').map(Number);
  return parts[0] === 0 || parts[0] === 10 || parts[0] === 127 || parts[0] >= 224
    || (parts[0] === 169 && parts[1] === 254)
    || (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31)
    || (parts[0] === 192 && parts[1] === 168)
    || (parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127)
    || (parts[0] === 192 && parts[1] === 0 && parts[2] === 2)
    || (parts[0] === 198 && parts[1] === 51 && parts[2] === 100)
    || (parts[0] === 203 && parts[1] === 0 && parts[2] === 113);
}
