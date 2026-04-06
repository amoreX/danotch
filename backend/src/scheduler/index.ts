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

  try {
    // Build system prompt
    let systemPrompt = `You are running a scheduled task inside Danotch. The user set this up to run automatically. Be concise and actionable. Task name: "${taskName}".`;

    // For conditional notify tasks, add [NOTIFY]/[SKIP] instruction
    let actualPrompt = prompt;
    if (notifyUser) {
      // Check if the prompt implies a condition (contains words like "if", "when", "threshold", "above", "below", "reaches")
      const conditionWords = /\b(if|when|unless|threshold|above|below|reaches|exceeds|drops|falls|greater|less|more than|fewer)\b/i;
      const isConditional = conditionWords.test(prompt);

      if (isConditional) {
        actualPrompt = `${prompt}\n\nIMPORTANT: Evaluate the condition in the task. If the condition IS met, start your response with [NOTIFY]. If NOT met, start with [SKIP] and briefly note the current state.`;
      } else {
        // Non-conditional notify task — always notify (e.g. "give me fun facts", "write me a poem")
        actualPrompt = `${prompt}\n\nStart your response with [NOTIFY] — the user wants to be notified with your output.`;
      }
    }

    const response = await anthropic.messages.create({
      model: config.api.model,
      max_tokens: config.api.maxTokens,
      system: systemPrompt,
      messages: [{ role: 'user', content: actualPrompt }],
    });

    resultText = response.content
      .filter((b): b is Anthropic.TextBlock => b.type === 'text')
      .map((b) => b.text)
      .join('');

    // Parse [NOTIFY]/[SKIP] prefix for conditional tasks
    if (notifyUser) {
      if (resultText.startsWith('[NOTIFY]')) {
        shouldNotify = true;
        resultText = resultText.slice('[NOTIFY]'.length).trimStart();
      } else if (resultText.startsWith('[SKIP]')) {
        shouldNotify = false;
        resultText = resultText.slice('[SKIP]'.length).trimStart();
      } else {
        // No prefix — default to notify (safer)
        shouldNotify = true;
      }
    }
    // Silent tasks (notify_user=false) never notify
  } catch (err) {
    status = 'failed';
    errorMsg = err instanceof Error ? err.message : 'Unknown error';
    resultText = errorMsg;
    console.error(`[scheduler] Task "${taskName}" failed:`, errorMsg);
  }

  // Update task state (always, regardless of mode)
  await supabase
    .from('scheduled_tasks')
    .update({
      last_run_at: new Date().toISOString(),
      run_count: (task.run_count as number ?? 0) + 1,
      last_result: { status, summary: resultText.slice(0, 500), error: errorMsg ?? null, notified: shouldNotify },
    })
    .eq('id', taskId);

  // Only create notification + push if: notify_user=false (silent background save) OR notify_user=true AND shouldNotify
  if (!notifyUser) {
    // Silent mode — no notification, no peek. Just log.
    console.log(`[scheduler] Task "${taskName}" ${status} (silent)`);
    return;
  }

  if (!shouldNotify) {
    // Conditional mode but condition not met — skip notification
    console.log(`[scheduler] Task "${taskName}" ${status} (condition not met, skipped notification)`);
    return;
  }

  // Create notification (only for notify_user=true AND condition met)
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

  console.log(`[scheduler] Task "${taskName}" ${status}, notification + peek`);

  // Push peek notification via WebSocket
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
