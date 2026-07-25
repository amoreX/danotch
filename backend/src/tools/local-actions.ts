import type { CanonicalTool } from '../providers/types.js';
import type { ActionCoordinator } from '../actions/coordinator.js';

export const localActionTools: CanonicalTool[] = [
  {
    name: 'bash_execute',
    description: 'Request approval to run a shell command inside the signed local macOS VM executor. Node never executes this command.',
    input_schema: {
      type: 'object',
      properties: {
        command: { type: 'string', description: 'Command to run after explicit user approval.' },
      },
      required: ['command'],
    },
  },
];

export async function executeLocalActionTool(
  input: Record<string, unknown>,
  context: {
    runId: string;
    sessionId: string;
    coordinator: ActionCoordinator;
  },
): Promise<string> {
  if (typeof input.command !== 'string' || input.command.length === 0 || input.command.length > 4_096) {
    throw new Error('command is required and must be at most 4096 characters');
  }
  const action = context.coordinator.offerLocalAction({
    runId: context.runId,
    sessionId: context.sessionId,
    actionType: 'shell.execute',
    parameters: { command: input.command },
    summary: summarize(input.command),
  });
  const terminal = await context.coordinator.waitForTerminal(action.id);
  if (terminal.status === 'completed') return terminal.result_json?.slice(0, 8_000) ?? '{}';
  if (terminal.status === 'rejected') return JSON.stringify({ error: 'User rejected local execution' });
  if (terminal.status === 'expired') return JSON.stringify({ error: 'Local execution approval expired' });
  return JSON.stringify({ error: terminal.error ?? 'Local execution failed' });
}

function summarize(command: string): string {
  const safe = command.replace(/[\r\n\t]+/g, ' ').replace(/\s+/g, ' ').trim();
  return `Run locally: ${safe.slice(0, 160)}`;
}
