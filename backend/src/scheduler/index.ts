import { supabase } from '../lib/supabase.js';
import { computeNextRun } from './compute-next.js';
import type { NotchBridge } from '../events/notch.js';
import { getProviderForUser } from '../providers/factory.js';
import { config } from '../config.js';

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
  const notifyUser = task.notify_user as boolean ?? false;

  // Re-fetch to check it still exists and is enabled
  const { data: fresh } = await supabase
    .from('scheduled_tasks')
    .select('id, enabled')
    .eq('id', taskId)
    .single();

  if (!fresh || !fresh.enabled) {
    console.log(`[scheduler] Task ${taskId} skipped (deleted or disabled)`);
    return;
  }

  console.log(`[scheduler] Running task "${taskName}" (notify=${notifyUser}) for user ${userId}`);

  let resultText = '';
  let status = 'completed';
  let errorMsg: string | undefined;
  let shouldNotify = false;

  // Resolve the user's LLM provider (BYOK or server fallback)
  let providerName = 'unknown';
  try {
    const provider = await getProviderForUser(userId);
    providerName = `${provider.providerName}/${provider.modelId}`;

    // Build system prompt
    let systemPrompt = `You are running a scheduled task inside Danotch. The user set this up to run automatically. Be concise and actionable. Task name: "${taskName}".`;

    // For conditional notify tasks, add [NOTIFY]/[SKIP] instruction
    let actualPrompt = prompt;
    if (notifyUser) {
      const conditionWords = /\b(if|when|unless|threshold|above|below|reaches|exceeds|drops|falls|greater|less|more than|fewer)\b/i;
      const isConditional = conditionWords.test(prompt);

      if (isConditional) {
        actualPrompt = `${prompt}\n\nIMPORTANT: Evaluate the condition in the task. If the condition IS met, start your response with [NOTIFY]. If NOT met, start with [SKIP] and briefly note the current state.`;
      } else {
        actualPrompt = `${prompt}\n\nStart your response with [NOTIFY] — the user wants to be notified with your output.`;
      }
    }

    const result = await provider.complete({
      messages: [{ role: 'user', content: actualPrompt }],
      systemPrompt,
      maxTokens: config.api.maxTokens,
    });

    resultText = result.text;

    // Parse [NOTIFY]/[SKIP] prefix for conditional tasks
    if (notifyUser) {
      if (resultText.startsWith('[NOTIFY]')) {
        shouldNotify = true;
        resultText = resultText.slice('[NOTIFY]'.length).trimStart();
      } else if (resultText.startsWith('[SKIP]')) {
        shouldNotify = false;
        resultText = resultText.slice('[SKIP]'.length).trimStart();
      } else {
        shouldNotify = true;
      }
    }
  } catch (err) {
    status = 'failed';
    errorMsg = err instanceof Error ? err.message : 'Unknown error';
    resultText = errorMsg;
    console.error(`[scheduler] Task "${taskName}" failed (${providerName}):`, errorMsg);
  }

  // Update task state
  await supabase
    .from('scheduled_tasks')
    .update({
      last_run_at: new Date().toISOString(),
      run_count: (task.run_count as number ?? 0) + 1,
      last_result: {
        status,
        summary: resultText.slice(0, 500),
        error: errorMsg ?? null,
        notified: shouldNotify,
        provider: providerName,
      },
    })
    .eq('id', taskId);

  if (!notifyUser) {
    console.log(`[scheduler] Task "${taskName}" ${status} via ${providerName} (silent)`);
    return;
  }

  if (!shouldNotify) {
    console.log(`[scheduler] Task "${taskName}" ${status} via ${providerName} (condition not met)`);
    return;
  }

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

  console.log(`[scheduler] Task "${taskName}" ${status} via ${providerName}, notification + peek`);

  if (notifData) {
    notch.send({
      type: 'peek_notification' as any,
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
