// Which Composio tool calls require explicit user approval before executing.
//
// Read-only actions (fetch/list/get/search/read) run directly. Actions that
// create external side effects a user would want to review — sending mail,
// posting, deleting, modifying resources — become pending draft actions that
// only execute after the user approves the exact stored payload.

const MUTATING_VERBS = [
  'SEND',
  'CREATE',
  'DELETE',
  'UPDATE',
  'REMOVE',
  'ADD',
  'REPLY',
  'FORWARD',
  'MERGE',
  'CLOSE',
  'DRAFT',
  'POST',
  'MOVE',
  'TRASH',
  'MODIFY',
];

const READ_VERBS = ['FETCH', 'LIST', 'GET', 'SEARCH', 'READ', 'RETRIEVE', 'FIND'];

/**
 * A Composio action requires approval when its name contains a mutating verb
 * token and no purely-read verb. Tool names look like GMAIL_SEND_EMAIL,
 * GITHUB_CREATE_ISSUE, GMAIL_FETCH_EMAILS.
 */
export function requiresApproval(toolName: string): boolean {
  const tokens = toolName.toUpperCase().split('_');
  const hasMutating = tokens.some((t) => MUTATING_VERBS.includes(t));
  if (!hasMutating) return false;
  // "GET_DRAFT" style read that happens to include a read verb is not mutating.
  const hasRead = tokens.some((t) => READ_VERBS.includes(t));
  return !hasRead;
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
