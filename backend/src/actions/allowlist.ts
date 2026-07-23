import { ACTION_REGISTRY_VERSION, classifyAction } from './registry.js';

/**
 * Compatibility helper for callers that only need the approval bit. Unknown
 * actions throw instead of silently becoming read-only.
 */
export function requiresApproval(toolName: string): boolean {
  const decision = classifyAction(toolName, {
    registryVersion: ACTION_REGISTRY_VERSION,
    metadataValidated: true,
  });
  if (decision.kind === 'deny') {
    throw new Error(`External action denied: ${decision.reason}`);
  }
  return decision.kind === 'approval';
}

/**
 * A stable, human-readable summary of a pending action for the approval UI.
 * Non-sensitive: names the operation and, when present, the target/recipient.
 */
export function summarizeAction(toolName: string, input: Record<string, unknown>): string {
  const recipient =
    (input.recipient_email as string) ||
    (input.to as string) ||
    (input.channel as string) ||
    (input.owner as string) ||
    (input.repo as string) ||
    '';
  const label = toolName
    .toLowerCase()
    .replace(/_/g, ' ')
    .replace(/\b\w/g, (c) => c.toUpperCase());
  return recipient ? `${label} → ${recipient}` : label;
}
