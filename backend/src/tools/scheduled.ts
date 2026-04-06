import type Anthropic from '@anthropic-ai/sdk';
import { supabase } from '../lib/supabase.js';
import { computeNextRun, isValidCron, cronToHuman } from '../scheduler/compute-next.js';

// ── Tool Definitions (Anthropic format) ──

export const scheduledTaskTools: Anthropic.Tool[] = [
  {
    name: 'create_scheduled_task',
    description:
      'Create a recurring scheduled task that runs automatically. Use this when the user asks you to do something on a schedule, e.g. "check my emails every morning", "summarize my day at 6pm", "remind me every hour". You must translate the user\'s request into a cron expression or poll interval.',
    input_schema: {
      type: 'object' as const,
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
          description: 'Optional: the app this task targets (gmail, googlecalendar, googledocs, linear). Null for general tasks.',
        },
      },
      required: ['name', 'prompt', 'task_type'],
    },
  },
  {
    name: 'list_scheduled_tasks',
    description: "List all of the user's scheduled tasks with their status, schedule, and next run time.",
    input_schema: {
      type: 'object' as const,
      properties: {},
    },
  },
  {
    name: 'update_scheduled_task',
    description: 'Update an existing scheduled task. Can enable/disable, change the schedule, or modify the prompt.',
    input_schema: {
      type: 'object' as const,
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
      type: 'object' as const,
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
  const name = input.name as string;
  const prompt = input.prompt as string;
  const taskType = input.task_type as string;
  const cron = input.cron as string | undefined;
  const intervalMs = input.interval_ms as number | undefined;
  const targetApp = input.target_app as string | undefined;

  // Validate
  if (!name || !prompt || !taskType) {
    return JSON.stringify({ error: 'name, prompt, and task_type are required' });
  }
  if (taskType === 'scheduled' && (!cron || !isValidCron(cron))) {
    return JSON.stringify({ error: `Invalid or missing cron expression: "${cron}"` });
  }
  if (taskType === 'poll' && (!intervalMs || intervalMs < 60000)) {
    return JSON.stringify({ error: 'poll tasks require interval_ms >= 60000 (1 minute)' });
  }

  const nextRunAt = computeNextRun(taskType, cron, intervalMs);

  const { data, error } = await supabase
    .from('scheduled_tasks')
    .insert({
      user_id: userId,
      name,
      prompt,
      task_type: taskType,
      cron: cron ?? null,
      interval_ms: intervalMs ?? null,
      target_app: targetApp ?? null,
      enabled: true,
      next_run_at: nextRunAt.toISOString(),
    })
    .select('id, name, next_run_at')
    .single();

  if (error) {
    console.error('[tools:scheduled] Create failed:', error.message);
    return JSON.stringify({ error: error.message });
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
    message: `Scheduled task "${name}" created. ${schedule}. Next run: ${nextRunAt.toLocaleString()}.`,
  });
}

async function listTasks(userId: string): Promise<string> {
  const { data, error } = await supabase
    .from('scheduled_tasks')
    .select('id, name, prompt, task_type, cron, interval_ms, enabled, last_run_at, next_run_at, run_count, last_result')
    .eq('user_id', userId)
    .order('created_at', { ascending: false });

  if (error) {
    return JSON.stringify({ error: error.message });
  }

  const tasks = (data ?? []).map((t) => ({
    id: t.id,
    name: t.name,
    prompt: t.prompt,
    schedule: t.task_type === 'scheduled' && t.cron ? cronToHuman(t.cron) : `Every ${Math.round((t.interval_ms ?? 0) / 60000)}m`,
    enabled: t.enabled,
    last_run: t.last_run_at,
    next_run: t.next_run_at,
    run_count: t.run_count,
    last_status: (t.last_result as Record<string, unknown>)?.status ?? null,
  }));

  return JSON.stringify({ tasks, count: tasks.length });
}

async function updateTask(input: Record<string, unknown>, userId: string): Promise<string> {
  const id = input.id as string;

  // Verify ownership
  const { data: existing } = await supabase
    .from('scheduled_tasks')
    .select('id, task_type')
    .eq('id', id)
    .eq('user_id', userId)
    .single();

  if (!existing) {
    return JSON.stringify({ error: 'Task not found' });
  }

  const updates: Record<string, unknown> = { updated_at: new Date().toISOString() };
  if (input.enabled !== undefined) updates.enabled = input.enabled;
  if (input.name) updates.name = input.name;
  if (input.prompt) updates.prompt = input.prompt;
  if (input.cron) {
    if (!isValidCron(input.cron as string)) {
      return JSON.stringify({ error: `Invalid cron: "${input.cron}"` });
    }
    updates.cron = input.cron;
    updates.next_run_at = computeNextRun('scheduled', input.cron as string).toISOString();
  }
  if (input.interval_ms) {
    updates.interval_ms = input.interval_ms;
    updates.next_run_at = computeNextRun('poll', null, input.interval_ms as number).toISOString();
  }

  const { error } = await supabase
    .from('scheduled_tasks')
    .update(updates)
    .eq('id', id)
    .eq('user_id', userId);

  if (error) {
    return JSON.stringify({ error: error.message });
  }

  return JSON.stringify({ success: true, message: `Task updated.` });
}

async function deleteTask(input: Record<string, unknown>, userId: string): Promise<string> {
  const id = input.id as string;

  const { error } = await supabase
    .from('scheduled_tasks')
    .delete()
    .eq('id', id)
    .eq('user_id', userId);

  if (error) {
    return JSON.stringify({ error: error.message });
  }

  return JSON.stringify({ success: true, message: 'Task deleted.' });
}
