import { test } from 'node:test';
import assert from 'node:assert/strict';
import { requiresApproval, summarizeAction } from './allowlist.ts';

test('read-only actions do not require approval', () => {
  assert.equal(requiresApproval('GMAIL_FETCH_EMAILS'), false);
  assert.equal(requiresApproval('GITHUB_LIST_REPOSITORY_ISSUES'), false);
  assert.equal(requiresApproval('GOOGLECALENDAR_EVENTS_GET'), false);
  assert.equal(requiresApproval('GOOGLEDOCS_SEARCH_DOCUMENTS'), false);
});

test('mutating actions require approval', () => {
  assert.equal(requiresApproval('GMAIL_SEND_EMAIL'), true);
  assert.equal(requiresApproval('GITHUB_CREATE_AN_ISSUE'), true);
  assert.equal(requiresApproval('GOOGLECALENDAR_DELETE_EVENT'), true);
  assert.equal(requiresApproval('GMAIL_REPLY_TO_THREAD'), true);
});

test('unknown action names fail closed', () => {
  assert.throws(() => requiresApproval('GITHUB_LIST_ISSUES'), /unknown_action/);
});

test('summary names the operation and recipient when present', () => {
  assert.match(summarizeAction('GMAIL_SEND_EMAIL', { recipient_email: 'a@b.com' }), /Gmail Send Email/);
  assert.match(summarizeAction('GMAIL_SEND_EMAIL', { recipient_email: 'a@b.com' }), /a@b\.com/);
  assert.equal(summarizeAction('GITHUB_CREATE_ISSUE', {}).includes('Github Create Issue'), true);
});
