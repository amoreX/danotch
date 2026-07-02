import DodoPayments from 'dodopayments';
import { config } from '../config.js';

let client: DodoPayments | null = null;

export function isCheckoutConfigured(): boolean {
  return Boolean(config.dodo.apiKey && config.dodo.productId && config.dodo.returnUrl);
}

export function isWebhookConfigured(): boolean {
  return Boolean(config.dodo.webhookKey);
}

/**
 * Lazily-constructed singleton client. Callers must check isCheckoutConfigured()
 * / isWebhookConfigured() before invoking checkout or webhook operations —
 * this helper does not itself gate on config presence.
 */
export function getDodoClient(): DodoPayments {
  if (!client) {
    client = new DodoPayments({
      bearerToken: config.dodo.apiKey,
      environment: config.dodo.environment === 'live_mode' ? 'live_mode' : 'test_mode',
      webhookKey: config.dodo.webhookKey,
    });
  }
  return client;
}
