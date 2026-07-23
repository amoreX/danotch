import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ACTION_REGISTRY_VERSION, classifyAction } from './registry.ts';
import { GMAIL_TOOLS } from '../composio/apps/gmail.ts';
import { GCAL_TOOLS } from '../composio/apps/gcal.ts';
import { GDOCS_TOOLS } from '../composio/apps/gdocs.ts';
import { GITHUB_TOOLS } from '../composio/apps/github.ts';

test('every curated Composio action has an exact registry entry', () => {
  for (const actions of [GMAIL_TOOLS, GCAL_TOOLS, GDOCS_TOOLS, GITHUB_TOOLS]) {
    for (const action of actions) {
      const decision = classifyAction(action, {
        registryVersion: ACTION_REGISTRY_VERSION,
        metadataValidated: true,
      });
      assert.notEqual(decision.kind, 'deny', `${action} must be classified`);
    }
  }
});

test('unknown, version-mismatched, and metadata-failed actions deny', () => {
  assert.deepEqual(
    classifyAction('GMAIL_TOTALLY_UNKNOWN', {
      registryVersion: ACTION_REGISTRY_VERSION,
      metadataValidated: true,
    }),
    { kind: 'deny', reason: 'unknown_action' },
  );
  assert.deepEqual(
    classifyAction('GMAIL_FETCH_EMAILS', {
      registryVersion: '999',
      metadataValidated: true,
    }),
    { kind: 'deny', reason: 'registry_version_mismatch' },
  );
  assert.deepEqual(
    classifyAction('GMAIL_FETCH_EMAILS', {
      registryVersion: ACTION_REGISTRY_VERSION,
      metadataValidated: false,
    }),
    { kind: 'deny', reason: 'metadata_validation_failed' },
  );
});

test('registry distinguishes read actions from approval-required actions exactly', () => {
  assert.equal(
    classifyAction('GMAIL_FETCH_EMAILS', {
      registryVersion: ACTION_REGISTRY_VERSION,
      metadataValidated: true,
    }).kind,
    'read',
  );
  assert.equal(
    classifyAction('GMAIL_SEND_EMAIL', {
      registryVersion: ACTION_REGISTRY_VERSION,
      metadataValidated: true,
    }).kind,
    'approval',
  );
});
