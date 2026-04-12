import { Composio } from '@composio/core';
import { AnthropicProvider } from '@composio/anthropic';
import { config } from '../config.js';

let composio: InstanceType<typeof Composio> | null = null;

export function getComposio() {
  if (!composio) {
    if (!config.composio.apiKey) {
      throw new Error('COMPOSIO_API_KEY not set');
    }
    composio = new Composio({
      apiKey: config.composio.apiKey,
      provider: new AnthropicProvider(),
    }) as any;
  }
  return composio!;
}

export function isComposioConfigured(): boolean {
  return !!config.composio.apiKey;
}
