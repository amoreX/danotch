import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  validateLocalAction,
  validateLocalCapabilities,
} from './local-executor-registry.ts';

const capabilities = {
  workspace_mode: 'read_only',
  egress_destinations: [],
  sensitive_file_access: false,
  sensitive_output_disclosure: false,
  result_upload: false,
  limits: {
    cpu_count: 1,
    memory_bytes: 268_435_456,
    disk_bytes: 536_870_912,
    process_count: 32,
    output_bytes: 65_536,
    timeout_seconds: 30,
  },
};

test('local executor registry validates exact typed actions and stable hashes', () => {
  const action = validateLocalAction(
    '1',
    'workspace.inspect',
    { path: 'Sources', depth: 2 },
    capabilities,
  );
  assert.equal(action.highRiskShell, false);
  assert.equal(
    action.parametersHash,
    '07bbaf1d3aee2c0305e15e7af82c5604d48ef7c27c056e33ad3be2874a9b1ff7',
  );
  assert.equal(
    action.actionHash,
    '0e17134b73b690ce8a5eafbe33b013ebe8e2e657211b3527c3a85ccbf45d4a70',
  );
  assert.throws(() => validateLocalAction(
    '1',
    'workspace.inspect',
    { path: 'Sources', depth: 2, command: 'id' },
    capabilities,
  ));
  assert.equal(
    validateLocalAction('1', 'shell.execute', { command: 'echo ok' }, capabilities)
      .highRiskShell,
    true,
  );
});

test('network is explicitly unavailable in local executor capabilities', () => {
  assert.throws(() => validateLocalCapabilities({
    ...capabilities,
    egress_destinations: ['example.com:443'],
  }), /network is unavailable/);
});
