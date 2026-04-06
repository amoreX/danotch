import { supabase } from '../lib/supabase.js';
import { computeNextRun } from './compute-next.js';
import type { NotchBridge } from '../events/notch.js';
import Anthropic from '@anthropic-ai/sdk';
import { config } from '../config.js';

const anthropic = new Anthropic();

const TICK_INTERVAL = 30_000; // 30 seconds

let schedulerTimer: ReturnType<typeof setInterval> | null = null;

export function startScheduler(notch: NotchBridge) {
  console.log('[scheduler] Started (tick every 30s)');
  schedulerTimer = setInterval(() => tick(notch), TICK_INTERVAL);
  schedulerTimer.unref(); // Don't keep process alive
  tick(notch);
}

export function stopScheduler() {
  if (schedulerTimer) {
    clearInterval(schedulerTimer);
    schedulerTimer = null;
  }
}

async function tick(notch: NotchBridge) {
  try {
    // Fetch all due tasks
    const { data: dueTasks, error } = await supabase
      .from('scheduled_tasks')
      .select('*')
      .eq('enabled', true)
      .lte('next_run_at', new Date().toISOString());

    if (error) {
      console.error('[scheduler] Query error:', error.message);
      return;
    }
    if (!dueTasks || dueTasks.length === 0) return;

    console.log(`[scheduler] ${dueTasks.length} due task(s)`);

    for (const task of dueTasks) {
      // Immediately update next_run_at to prevent double-pickup on next tick
      const nextRun = computeNextRun(task.task_type, task.cron, task.interval_ms);
      await supabase
        .from('scheduled_tasks')
        .update({ next_run_at: nextRun.toISOString() })
        .eq('id', task.id);

      // Fire-and-forget execution
      executeTask(task, notch).catch((err) => {
        console.error(`[scheduler] Unhandled error in task ${task.id}:`, err);
      });
    }
  } catch (err) {
    console.error('[scheduler] Tick error:', err);
  }
}

async function executeTask(task: Record<string, unknown>, notch: NotchBridge) {
  const taskId = task.id as string;
  const userId = task.user_id as string;
  const taskName = task.name as string;
  const prompt = task.prompt as string;

  // Re-fetch to check it still exists and is enabled (handles delete/disable race)
  const { data: fresh } = await supabase
    .from('scheduled_tasks')
    .select('id, enabled')
    .eq('id', taskId)
    .single();

  if (!fresh || !fresh.enabled) {
    console.log(`[scheduler] Task ${taskId} skipped (deleted or disabled)`);
    return;
  }

  console.log(`[scheduler] Running task "${taskName}" for user ${userId}`);

  let resultText = '';
  let status = 'completed';
  let errorMsg: string | undefined;

  try {
    // Run Claude with the task prompt
    const response = await anthropic.messages.create({
      model: config.api.model,
      max_tokens: config.api.maxTokens,
      system: `You are running a scheduled task inside Danotch. The user set this up to run automatically. Be concise and actionable in your response. Task name: "${taskName}".`,
      messages: [{ role: 'user', content: prompt }],
    });

    resultText = response.content
      .filter((b): b is Anthropic.TextBlock => b.type === 'text')
      .map((b) => b.text)
      .join('');
  } catch (err) {
    status = 'failed';
    errorMsg = err instanceof Error ? err.message : 'Unknown error';
    resultText = errorMsg;
    console.error(`[scheduler] Task "${taskName}" failed:`, errorMsg);
  }

  // Update task state
  await supabase
    .from('scheduled_tasks')
    .update({
      last_run_at: new Date().toISOString(),
      run_count: (task.run_count as number ?? 0) + 1,
      last_result: { status, summary: resultText.slice(0, 500), error: errorMsg ?? null },
    })
    .eq('id', taskId);

  // Create notification
  const { data: notifData } = await supabase
    .from('notifications')
    .insert({
      user_id: userId,
      source: 'scheduled_task',
      source_id: taskId,
      title: taskName,
      body: resultText.slice(0, 1000),
    })
    .select('id, created_at')
    .single();

  console.log(`[scheduler] Task "${taskName}" ${status}, notification created`);

  // Push notification via WebSocket
  if (notifData) {
    notch.send({
      type: 'notification' as any,
      data: {
        id: notifData.id,
        title: taskName,
        body: resultText.slice(0, 500),
        source: 'scheduled_task',
        source_id: taskId,
        status,
        created_at: notifData.created_at,
      },
    } as any);
  }
}
