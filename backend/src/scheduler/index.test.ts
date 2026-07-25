import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { ScheduleRecord } from '../db/repositories.ts';
import { nextAfterCatchUp } from './index.ts';

test('catch-up advancement is bounded and lands in the future', () => {
  const current = new Date('2026-07-25T12:00:00.000Z');
  const schedule = {
    next_run_at: '2026-07-20T12:00:00.000Z',
    interval_ms: 60_000,
    cron: null,
  } as ScheduleRecord;
  const next = nextAfterCatchUp(schedule, 3, current);
  assert.equal(next.getTime(), current.getTime() + 60_000);
});
