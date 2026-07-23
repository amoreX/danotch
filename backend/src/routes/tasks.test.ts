import { test } from 'node:test';
import assert from 'node:assert/strict';
import { InMemoryTaskStore } from '../agent/task-store.ts';

test('server generates task IDs when a client does not provide a scoped session ID', () => {
  const store = new InMemoryTaskStore();
  const first = store.createOrUpdate('user-a', undefined, 'first');
  const second = store.createOrUpdate('user-a', undefined, 'second');

  assert.match(first.id, /^[0-9a-f-]{36}$/);
  assert.notEqual(first.id, second.id);
});

test('list/get accessors require the immutable owner ID', () => {
  const store = new InMemoryTaskStore();
  store.createOrUpdate('user-a', 'same', 'A');
  store.createOrUpdate('user-b', 'same', 'B');

  assert.deepEqual(store.list('user-a').map((task) => task.task), ['A']);
  assert.equal(store.get('user-a', 'same')?.ownerId, 'user-a');
  assert.equal(store.get('user-a', 'missing'), undefined);
});
