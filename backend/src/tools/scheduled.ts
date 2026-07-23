import type { CanonicalTool } from '../providers/types.js';
import { userDb as supabase } from '../lib/user-db.js';
import { getAdminDb } from '../lib/admin-db.js';
import { computeNextRun, isValidCron, isCronAtLeastInterval, cronToHuman, scheduleToHuman } from '../scheduler/compute-next.js';
import { config } from '../config.js';
import { SupabaseQuotaStore, requestQuotaSubject } from '../security/quota-store.js';

const scheduleQuota = new SupabaseQuotaStore(getAdminDb('scheduler'));

// ── Tool Definitions ──

export const scheduledTaskTools: CanonicalTool[] = [
  {
    name: 'create_scheduled_task',
    description:
      'Create a recurring scheduled task that runs automatically. Use this when the user asks you to do something on a schedule, e.g. "check my emails every morning", "summarize my day at 6pm", "remind me every hour". You must translate the user\'s request into a cron expression or poll interval.',
    input_schema: {
      type: 'object',
      properties: {
        name: { type: 'string', description: 'Short descriptive name for the task (e.g. "Morning email summary")' },
        prompt: {
          type: 'string',
          description: 'The prompt that will be sent to Claude each time the task runs. Be specific and self-contained.',
        },
        task_type: {
          type: 'string',
          enum: ['scheduled', 'poll'],
          description: 'scheduled = runs at specific times (cron). poll = runs at fixed intervals.',
        },
        cron: {
          type: 'string',
          description: 'Cron expression for scheduled tasks. 5 fields: minute hour day-of-month month day-of-week. Examples: "0 9 * * *" = 9am daily, "0 9 * * 1-5" = 9am weekdays, "*/30 * * * *" = every 30 min.',
        },
        interval_ms: {
          type: 'number',
          description: 'Interval in milliseconds for poll tasks. E.g. 3600000 = every hour, 1800000 = every 30 min. Minimum 60000 (1 minute).',
        },
        target_app: {
          type: 'string',
          description: 'Optional: the app this task targets (gmail, googlecalendar, googledocs, github). Null for general tasks.',
        },
        notify_user: {
          type: 'boolean',
          description: 'If true, Claude will decide each run whether to actually notify the user (for conditional alerts like "tell me when stock hits X", "notify me if new email from Y"). If false (default), runs silently — results saved but no notification/peek. Set true when user says "notify me when...", "alert me if...", "let me know when...".',
        },
        execution_location: {
          type: 'string',
          enum: ['hosted', 'device_local'],
          description: 'hosted only generates provider output and cannot execute commands. device_local queues work for one explicitly bound Mac.',
        },
        bound_device_id: {
          type: 'string',
          description: 'Required UUID for device_local tasks. Local work never fails over to another device.',
        },
      },
      required: ['name', 'prompt', 'task_type', 'execution_location'],
    },
  },
  {
    name: 'list_scheduled_tasks',
    description: "List all of the user's scheduled tasks with their status, schedule, and next run time.",
    input_schema: {
      type: 'object',
      properties: {},
    },
  },
  {
    name: 'update_scheduled_task',
    description: 'Update an existing scheduled task. Can enable/disable, change the schedule, or modify the prompt.',
    input_schema: {
      type: 'object',
      properties: {
        id: { type: 'string', description: 'The task ID to update' },
        enabled: { type: 'boolean', description: 'Enable or disable the task' },
        name: { type: 'string', description: 'New name' },
        prompt: { type: 'string', description: 'New prompt' },
        cron: { type: 'string', description: 'New cron expression' },
        interval_ms: { type: 'number', description: 'New poll interval in ms' },
      },
      required: ['id'],
    },
  },
  {
    name: 'delete_scheduled_task',
    description: 'Permanently delete a scheduled task.',
    input_schema: {
      type: 'object',
      properties: {
        id: { type: 'string', description: 'The task ID to delete' },
      },
      required: ['id'],
    },
  },
];

// ── Tool Execution Handlers ──

export async function executeScheduledTool(
  toolName: string,
  input: Record<string, unknown>,
  userId: string
): Promise<string> {
  if (toolName !== 'list_scheduled_tasks') {
    try {
      await scheduleQuota.consume({
        capability: 'scheduler',
        subject: requestQuotaSubject({
          userId,
          deviceId: typeof input.bound_device_id === 'string' ? input.bound_device_id : undefined,
        }),
      });
    } catch {
      return JSON.stringify({ error: 'Scheduling quota is temporarily unavailable' });
    }
  }
  switch (toolName) {
    case 'create_scheduled_task':
      return createTask(input, userId);
    case 'list_scheduled_tasks':
      return listTasks(userId);
    case 'update_scheduled_task':
      return updateTask(input, userId);
    case 'delete_scheduled_task':
      return deleteTask(input, userId);
    default:
      return JSON.stringify({ error: `Unknown tool: ${toolName}` });
  }
}

async function createTask(input: Record<string, unknown>, userId: string): Promise<string> {
  if (!config.containment.costlyIntegrationsEnabled) {
    return JSON.stringify({
      error: 'New scheduled tasks are temporarily unavailable.',
      code: 'costly_integrations_frozen',
    });
  }
  const name = input.name as string;
  const prompt = input.prompt as string;
  const taskType = input.task_type as string;
  const cron = input.cron as string | undefined;
  const intervalMs = input.interval_ms as number | undefined;
  const targetApp = input.target_app as string | undefined;
  const notifyUser = (input.notify_user as boolean) ?? false;
  const executionLocation = input.execution_location as string;
  const boundDeviceId = input.bound_device_id as string | undefined;

  // Validate
  if (!name || !prompt || !taskType) {
    return JSON.stringify({ error: 'name, prompt, and task_type are required' });
  }
  if (!['hosted', 'device_local'].includes(executionLocation)) {
    return JSON.stringify({ error: 'execution_location must be hosted or device_local' });
  }
  if (executionLocation === 'device_local' && !boundDeviceId) {
    return JSON.stringify({ error: 'device_local tasks require bound_device_id' });
  }
  if (executionLocation === 'hosted' && boundDeviceId) {
    return JSON.stringify({ error: 'hosted tasks cannot bind a local execution device' });
  }
  if (taskType === 'scheduled' && (!cron || !isValidCron(cron))) {
    return JSON.stringify({ error: `Invalid or missing cron expression: "${cron}"` });
  }
  if (taskType === 'scheduled' && cron && !isCronAtLeastInterval(cron, config.scheduler.minIntervalMs)) {
    return JSON.stringify({ error: 'scheduled tasks cannot run more frequently than the configured minimum' });
  }
  if (taskType === 'poll' && (!Number.isSafeInteger(intervalMs) || (intervalMs ?? 0) < config.scheduler.minIntervalMs)) {
    return JSON.stringify({ error: `poll tasks require interval_ms >= ${config.scheduler.minIntervalMs}` });
  }

  const nextRunAt = computeNextRun(taskType, cron, intervalMs);
  const { data, error } = await supabase
    .from('danotch_scheduled_tasks')
    .insert({
      user_id: userId,
      name,
      prompt,
      task_type: taskType,
      cron: cron ?? null,
      interval_ms: intervalMs ?? null,
      target_app: targetApp ?? null,
      notify_user: notifyUser,
      enabled: true,
      execution_location: executionLocation,
      bound_device_id: boundDeviceId ?? null,
    })
    .select('id, name, next_run_at, execution_location, bound_device_id')
    .single();

  if (error) {
    console.error('[tools:scheduled] Create failed');
    return JSON.stringify({ error: error.message });
  }
  const { error: scheduleError } = await getAdminDb('scheduler')
    .from('danotch_scheduled_tasks')
    .update({ next_run_at: nextRunAt.toISOString() })
    .eq('id', data.id)
    .eq('user_id', userId);
  if (scheduleError) {
    await supabase.from('danotch_scheduled_tasks').delete().eq('id', data.id);
    return JSON.stringify({ error: 'Task could not be scheduled' });
  }

  const schedule = taskType === 'scheduled' && cron
    ? cronToHuman(cron)
    : `Every ${Math.round((intervalMs ?? 0) / 60000)} minutes`;

  return JSON.stringify({
    success: true,
    task_id: data.id,
    name,
    schedule,
    next_run: nextRunAt.toISOString(),
    notify_user: notifyUser,
    execution_location: executionLocation,
    bound_device_id: boundDeviceId ?? null,
    message: `Scheduled task "${name}" created. ${schedule}. ${notifyUser ? 'Will notify you when condition is met.' : 'Runs silently.'} Next run: ${nextRunAt.toLocaleString()}.`,
  });
}

async function listTasks(userId: string): Promise<string> {
  const { data, error } = await supabase
    .from('danotch_scheduled_tasks')
    .select('id, name, prompt, task_type, cron, interval_ms, enabled, notify_user, execution_location, bound_device_id, run_state, last_run_at, next_run_at, run_count, last_result')
    .eq('user_id', userId)
    .order('created_at', { ascending: false });

  if (error) {
    return JSON.stringify({ error: error.message });
  }

  const tasks = (data ?? []).map((t) => ({
    id: t.id,
    name: t.name,
    prompt: t.prompt,
    schedule: scheduleToHuman(t.task_type, t.cron, t.interval_ms),
    enabled: t.enabled,
    last_run: t.last_run_at,
    next_run: t.next_run_at,
    run_count: t.run_count,
    execution_location: t.execution_location,
    bound_device_id: t.bound_device_id,
    run_state: t.run_state,
    last_status: (t.last_result as Record<string, unknown>)?.status ?? null,
  }));

  return JSON.stringify({ tasks, count: tasks.length });
}

async function updateTask(input: Record<string, unknown>, userId: string): Promise<string> {
  const id = input.id as string;

  // Verify ownership
  const { data: existing } = await supabase
    .from('danotch_scheduled_tasks')
    .select('id, task_type')
    .eq('id', id)
    .eq('user_id', userId)
    .single();

  if (!existing) {
    return JSON.stringify({ error: 'Task not found' });
  }

  const updates: Record<string, unknown> = { updated_at: new Date().toISOString() };
  let nextRunAt: string | undefined;
  if (input.enabled !== undefined) updates.enabled = input.enabled;
  if (input.name) updates.name = input.name;
  if (input.prompt) updates.prompt = input.prompt;
  if (input.cron) {
    if (!isValidCron(input.cron as string) || !isCronAtLeastInterval(input.cron as string, config.scheduler.minIntervalMs)) {
      return JSON.stringify({ error: `Invalid cron: "${input.cron}"` });
    }
    updates.cron = input.cron;
    nextRunAt = computeNextRun('scheduled', input.cron as string).toISOString();
  }
  if (input.interval_ms) {
    if (!Number.isSafeInteger(input.interval_ms) || (input.interval_ms as number) < config.scheduler.minIntervalMs) {
      return JSON.stringify({ error: `interval_ms must be at least ${config.scheduler.minIntervalMs}` });
    }
    updates.interval_ms = input.interval_ms;
    nextRunAt = computeNextRun('poll', null, input.interval_ms as number).toISOString();
  }

  const { error } = await supabase
    .from('danotch_scheduled_tasks')
    .update(updates)
    .eq('id', id)
    .eq('user_id', userId);

  if (error) {
    return JSON.stringify({ error: error.message });
  }
  if (nextRunAt) {
    const { error: scheduleError } = await getAdminDb('scheduler')
      .from('danotch_scheduled_tasks')
      .update({ next_run_at: nextRunAt })
      .eq('id', id)
      .eq('user_id', userId);
    if (scheduleError) return JSON.stringify({ error: 'Task updated but could not be rescheduled' });
  }

  return JSON.stringify({ success: true, message: `Task updated.` });
}

async function deleteTask(input: Record<string, unknown>, userId: string): Promise<string> {
  const id = input.id as string;

  const { error } = await supabase
    .from('danotch_scheduled_tasks')
    .delete()
    .eq('id', id)
    .eq('user_id', userId);

  if (error) {
    return JSON.stringify({ error: error.message });
  }

  return JSON.stringify({ success: true, message: 'Task deleted.' });
}
