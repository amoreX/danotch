import { randomUUID } from 'node:crypto';
import { getAdminDb } from '../lib/admin-db.js';
import { computeNextRun } from './compute-next.js';
import type { NotchBridge } from '../events/notch.js';
import { resolveProviderForUser } from '../billing/entitlements.js';
import { config } from '../config.js';
import { SupabaseQuotaStore, requestQuotaSubject } from '../security/quota-store.js';

const TICK_INTERVAL = 30_000; // 30 seconds
const supabase = new Proxy({} as ReturnType<typeof getAdminDb>, {
  get(_target, property) {
    const client = getAdminDb('scheduler') as unknown as Record<PropertyKey, unknown>;
    const value = client[property];
    return typeof value === 'function' ? value.bind(client) : value;
  },
});

let schedulerTimer: ReturnType<typeof setInterval> | null = null;
const schedulerWorkerId = `scheduler-${randomUUID()}`;
const schedulerQuota = new SupabaseQuotaStore(getAdminDb('scheduler'));

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

export async function tick(notch: NotchBridge, workerId = schedulerWorkerId) {
  try {
    const { data: dueTasks, error } = await supabase.rpc('danotch_claim_due_schedules', {
      p_worker_id: workerId,
      p_limit: 25,
      p_lease_seconds: 180,
    });

    if (error) {
      console.error('[scheduler] Query error:', error.message);
      return;
    }
    if (!dueTasks || dueTasks.length === 0) return;

    console.log(`[scheduler] ${dueTasks.length} due task(s)`);

    for (const task of dueTasks) {
      executeTask(task, notch, workerId).catch((err) => {
        console.error(`[scheduler] Unhandled error in task ${task.id}:`, err);
      });
    }
  } catch (err) {
    console.error('[scheduler] Tick error:', err);
  }
}

async function executeTask(
  task: Record<string, unknown>,
  notch: NotchBridge,
  workerId: string,
) {
  const taskId = task.id as string;
  const userId = task.user_id as string;
  const taskName = task.name as string;
  const prompt = task.prompt as string;
  const notifyUser = task.notify_user as boolean ?? false;
  const leaseToken = task.lease_token as string;
  const nextRun = computeNextRun(
    task.task_type as string,
    task.cron as string | null,
    task.interval_ms as number | null,
  );
  const stopLeaseHeartbeat = startLeaseHeartbeat(taskId, workerId, leaseToken);
  try {
    await schedulerQuota.consume({
      capability: 'scheduler',
      subject: requestQuotaSubject({ userId }),
      idempotencyKey: String(task.last_attempt_id),
    });
  } catch {
    await finishSchedule(taskId, workerId, leaseToken, 'retry', nextRun, {
      status: 'quota_unavailable',
    });
    stopLeaseHeartbeat();
    return;
  }
  if (task.execution_location === 'device_local') {
    await finishSchedule(taskId, workerId, leaseToken, 'queued_local', nextRun, {
      status: 'queued_for_bound_device',
      device_id: task.bound_device_id,
    });
    stopLeaseHeartbeat();
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
    const provider = (await resolveProviderForUser(userId, undefined, getAdminDb('scheduler'))).provider;
    providerName = `${provider.providerName}/${provider.modelId}`;

    // Build system prompt
    let systemPrompt = `You are running a scheduled task inside Perch. The user set this up to run automatically. Be concise and actionable. Task name: "${taskName}".`;

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

  const lastResult = {
    status,
    summary: resultText.slice(0, 500),
    error: errorMsg ?? null,
    notified: shouldNotify,
    provider: providerName,
  };
  const finish = await finishSchedule(
    taskId,
    workerId,
    leaseToken,
    status === 'completed' ? 'completed' : 'retry',
    nextRun,
    lastResult,
  );
  stopLeaseHeartbeat();
  if (finish !== 'updated') return;

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
    .from('danotch_notifications')
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

function startLeaseHeartbeat(taskId: string, workerId: string, leaseToken: string): () => void {
  let stopped = false;
  const timer = setInterval(() => {
    if (stopped) return;
    void supabase.rpc('danotch_renew_schedule_lease', {
      p_task_id: taskId,
      p_worker_id: workerId,
      p_lease_token: leaseToken,
      p_lease_seconds: 180,
    }).then(({ data, error }) => {
      if (error || data !== true) {
        console.error(`[scheduler] Lease renewal failed for ${taskId}; terminal write will be fenced`);
      }
    });
  }, 60_000);
  timer.unref();
  return () => {
    stopped = true;
    clearInterval(timer);
  };
}

async function finishSchedule(
  taskId: string,
  workerId: string,
  leaseToken: string,
  outcome: 'completed' | 'queued_local' | 'retry',
  nextRun: Date,
  result: Record<string, unknown>,
): Promise<string> {
  const { data, error } = await supabase.rpc('danotch_finish_schedule_attempt', {
    p_task_id: taskId,
    p_worker_id: workerId,
    p_lease_token: leaseToken,
    p_outcome: outcome,
    p_next_run_at: nextRun.toISOString(),
    p_last_result: result,
  });
  if (error) {
    console.error(`[scheduler] Could not finish leased task ${taskId}:`, error.message);
    return 'error';
  }
  return String(data);
}
