import { test } from 'node:test';
import assert from 'node:assert/strict';
import { InMemoryTaskStore } from './task-store.ts';

test('task IDs are owner-scoped and cannot collide across users', () => {
  const store = new InMemoryTaskStore();
  const a = store.createOrUpdate('user-a', 'shared-session', 'A message');
  const b = store.createOrUpdate('user-b', 'shared-session', 'B message');

  assert.equal(a.ownerId, 'user-a');
  assert.equal(b.ownerId, 'user-b');
  assert.notEqual(a, b);
  assert.equal(store.get('user-a', 'shared-session')?.task, 'A message');
  assert.equal(store.get('user-b', 'shared-session')?.task, 'B message');
});

test('task owner is immutable and owner-scoped reads do not leak', () => {
  const store = new InMemoryTaskStore();
  const task = store.createOrUpdate('user-a', 'task-a', 'secret');

  assert.equal(store.get('user-b', task.id), undefined);
  assert.deepEqual(store.list('user-b'), []);
  assert.equal(
    Object.getOwnPropertyDescriptor(task, 'ownerId')?.writable,
    false,
  );
});
