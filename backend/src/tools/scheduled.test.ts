import assert from 'node:assert/strict';
import { test } from 'node:test';
import { loadConfig } from '../config.ts';
import { openDatabase } from '../db/database.ts';
import { Repositories } from '../db/repositories.ts';
import { executeScheduledTool } from './scheduled.ts';

test('chat scheduled tools validate limits and pin provider model and base URL', () => {
  const db = openDatabase(':memory:');
  try {
    const repositories = new Repositories(db);
    const provider = repositories.saveProvider({
      provider: 'custom',
      modelId: 'model-a',
      baseUrl: 'https://models.example/v1',
      keychainAccount: 'provider.custom_openai',
      active: true,
    });
    const dependencies = {
      repositories,
      config: loadConfig({ SCHEDULER_MIN_INTERVAL_MS: '60000' }),
      pinnedProvider: provider,
      modelId: 'model-pinned',
      baseUrl: 'https://models.example/v1',
    };
    const created = JSON.parse(executeScheduledTool('create_scheduled_task', {
      name: 'Daily',
      prompt: 'Summarize',
      task_type: 'scheduled',
      cron: '0 9 * * *',
    }, dependencies)) as Record<string, unknown>;
    const saved = repositories.getSchedule(created.task_id as string)!;
    assert.equal(saved.provider_id, provider.id);
    assert.equal(saved.model_id, 'model-pinned');
    assert.equal(saved.base_url, 'https://models.example/v1');
    assert.throws(() => executeScheduledTool('create_scheduled_task', {
      name: 'Too frequent',
      prompt: 'Poll',
      task_type: 'poll',
      interval_ms: 1_000,
    }, dependencies), /at least 60000/);
    const listed = JSON.parse(executeScheduledTool('list_scheduled_tasks', {}, dependencies));
    assert.equal(listed.tasks[0].provider_id, provider.id);
    assert.equal(JSON.parse(executeScheduledTool('delete_scheduled_task', {
      id: saved.id,
    }, dependencies)).success, true);
  } finally {
    db.close();
  }
});
