import type { Config } from '../config.js';
import type { ProviderPreference, Repositories } from '../db/repositories.js';
import type { CanonicalTool } from '../providers/types.js';
import { isCronAtLeastInterval, isValidCron, scheduleToHuman } from '../scheduler/compute-next.js';

export const scheduledTaskTools: CanonicalTool[] = [
  {
    name: 'create_scheduled_task',
    description: 'Create a recurring local scheduled task using cron or a fixed polling interval.',
    input_schema: {
      type: 'object',
      properties: {
        name: { type: 'string', description: 'Short task name.' },
        prompt: { type: 'string', description: 'Self-contained prompt run each time.' },
        task_type: { type: 'string', enum: ['scheduled', 'poll'] },
        cron: { type: 'string', description: 'Five-field cron for scheduled tasks.' },
        interval_ms: { type: 'number', description: 'Fixed interval for poll tasks.' },
        notify_user: { type: 'boolean' },
      },
      required: ['name', 'prompt', 'task_type'],
    },
  },
  {
    name: 'list_scheduled_tasks',
    description: 'List local scheduled tasks and their pinned provider settings.',
    input_schema: { type: 'object', properties: {} },
  },
  {
    name: 'update_scheduled_task',
    description: 'Update a local scheduled task.',
    input_schema: {
      type: 'object',
      properties: {
        id: { type: 'string' },
        enabled: { type: 'boolean' },
        name: { type: 'string' },
        prompt: { type: 'string' },
        cron: { type: 'string' },
        interval_ms: { type: 'number' },
        notify_user: { type: 'boolean' },
      },
      required: ['id'],
    },
  },
  {
    name: 'delete_scheduled_task',
    description: 'Permanently delete a local scheduled task.',
    input_schema: {
      type: 'object',
      properties: { id: { type: 'string' } },
      required: ['id'],
    },
  },
];

export function executeScheduledTool(
  name: string,
  input: Record<string, unknown>,
  dependencies: {
    repositories: Repositories;
    config: Config;
    pinnedProvider: ProviderPreference;
    modelId?: string;
    baseUrl?: string;
  },
): string {
  switch (name) {
    case 'create_scheduled_task':
      return create(input, dependencies);
    case 'list_scheduled_tasks':
      return list(dependencies.repositories);
    case 'update_scheduled_task':
      return update(input, dependencies);
    case 'delete_scheduled_task':
      return remove(input, dependencies.repositories);
    default:
      throw new Error('Unknown scheduled task tool');
  }
}

function create(
  input: Record<string, unknown>,
  dependencies: Parameters<typeof executeScheduledTool>[2],
): string {
  const { repositories, config, pinnedProvider } = dependencies;
  if (repositories.listSchedules().length >= 100) return output({ error: 'Scheduled task limit reached' });
  const name = text(input.name, 'name', 200);
  const prompt = text(input.prompt, 'prompt', 100_000);
  const taskType = input.task_type === 'poll' ? 'poll'
    : input.task_type === 'scheduled' ? 'scheduled' : fail('task_type is invalid');
  const schedule = validateSchedule(taskType, input.cron, input.interval_ms, config);
  const task = repositories.saveSchedule({
    name,
    prompt,
    taskType,
    cron: schedule.cron,
    intervalMs: schedule.intervalMs,
    providerId: pinnedProvider.id,
    modelId: dependencies.modelId ?? pinnedProvider.model_id,
    baseUrl: dependencies.baseUrl ?? pinnedProvider.base_url,
    notifyUser: input.notify_user === true,
  });
  return output({
    success: true,
    task_id: task.id,
    name: task.name,
    schedule: scheduleToHuman(task.task_type, task.cron, task.interval_ms),
    next_run: task.next_run_at,
    provider_id: task.provider_id,
    model_id: task.model_id,
    base_url: task.base_url,
  });
}

function list(repositories: Repositories): string {
  return output({
    tasks: repositories.listSchedules().map((task) => ({
      id: task.id,
      name: task.name,
      prompt: task.prompt,
      schedule: scheduleToHuman(task.task_type, task.cron, task.interval_ms),
      enabled: task.enabled === 1,
      notify_user: task.notify_user === 1,
      next_run: task.next_run_at,
      last_run: task.last_run_at,
      run_count: task.run_count,
      last_status: task.last_status,
      provider_id: task.provider_id,
      model_id: task.model_id,
      base_url: task.base_url,
    })),
  });
}

function update(
  input: Record<string, unknown>,
  dependencies: Parameters<typeof executeScheduledTool>[2],
): string {
  const id = text(input.id, 'id', 128);
  const existing = dependencies.repositories.getSchedule(id);
  if (!existing) return output({ error: 'Scheduled task not found' });
  const patch: Record<string, unknown> = {};
  if (input.name !== undefined) patch.name = text(input.name, 'name', 200);
  if (input.prompt !== undefined) patch.prompt = text(input.prompt, 'prompt', 100_000);
  if (input.enabled !== undefined) {
    if (typeof input.enabled !== 'boolean') fail('enabled must be boolean');
    patch.enabled = input.enabled;
  }
  if (input.notify_user !== undefined) {
    if (typeof input.notify_user !== 'boolean') fail('notify_user must be boolean');
    patch.notify_user = input.notify_user;
  }
  if (input.cron !== undefined && input.interval_ms !== undefined) {
    fail('Only one schedule type may be changed at a time');
  }
  if (input.cron !== undefined) {
    const value = validateSchedule('scheduled', input.cron, undefined, dependencies.config);
    patch.task_type = 'scheduled';
    patch.cron = value.cron;
    patch.interval_ms = null;
  }
  if (input.interval_ms !== undefined) {
    const value = validateSchedule('poll', undefined, input.interval_ms, dependencies.config);
    patch.task_type = 'poll';
    patch.cron = null;
    patch.interval_ms = value.intervalMs;
  }
  const task = dependencies.repositories.patchSchedule(id, patch);
  return output({ success: true, task_id: task!.id, next_run: task!.next_run_at });
}

function remove(input: Record<string, unknown>, repositories: Repositories): string {
  const id = text(input.id, 'id', 128);
  return repositories.deleteSchedule(id)
    ? output({ success: true, task_id: id })
    : output({ error: 'Scheduled task not found' });
}

function validateSchedule(
  type: 'scheduled' | 'poll',
  cronInput: unknown,
  intervalInput: unknown,
  config: Config,
): { cron: string | null; intervalMs: number | null } {
  if (type === 'scheduled') {
    const cron = text(cronInput, 'cron', 200);
    if (!isValidCron(cron) || !isCronAtLeastInterval(cron, config.scheduler.minIntervalMs)) {
      fail('Cron is invalid or runs too frequently');
    }
    return { cron, intervalMs: null };
  }
  if (!Number.isSafeInteger(intervalInput) || (intervalInput as number) < config.scheduler.minIntervalMs) {
    fail(`interval_ms must be at least ${config.scheduler.minIntervalMs}`);
  }
  return { cron: null, intervalMs: intervalInput as number };
}

function text(value: unknown, field: string, max: number): string {
  if (typeof value !== 'string' || value.length === 0 || value.length > max) {
    fail(`${field} is required and must be at most ${max} characters`);
  }
  return value as string;
}

function fail(message: string): never {
  throw new Error(message);
}

const output = (value: unknown) => JSON.stringify(value).slice(0, 8_000);
