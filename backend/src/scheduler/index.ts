import type { Config } from '../config.js';
import type { Repositories, ScheduleRecord } from '../db/repositories.js';
import type { NotchBridge } from '../events/notch.js';
import type { SecretBroker } from '../ipc/keychain-broker.js';
import { resolveProvider } from '../providers/factory.js';
import { computeNextRun } from './compute-next.js';
import type { LocalComposioService } from '../composio/service.js';
import { executeHostedTool, hostedTools } from '../tools/local.js';
import type { CanonicalContentBlock, CanonicalMessage, CanonicalToolResultBlock } from '../providers/types.js';

export class LocalScheduler {
  private timer?: NodeJS.Timeout;
  private ticking = false;

  constructor(private readonly dependencies: {
    repositories: Repositories;
    broker: SecretBroker;
    events: NotchBridge;
    config: Config;
    composio: LocalComposioService;
  }) {}

  start(): void {
    if (this.timer) return;
    this.timer = setInterval(() => void this.tick(), this.dependencies.config.scheduler.tickMs);
    this.timer.unref();
    void this.tick();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
  }

  async tick(): Promise<void> {
    if (this.ticking) return;
    this.ticking = true;
    try {
      const schedules = this.dependencies.repositories.claimDueSchedules(
        this.dependencies.config.scheduler.claimLimit,
      );
      await Promise.allSettled(schedules.map((schedule) => this.execute(schedule)));
    } finally {
      this.ticking = false;
    }
  }

  private async execute(schedule: ScheduleRecord): Promise<void> {
    const { repositories, broker, events, config, composio } = this.dependencies;
    const preference = repositories.getProvider(schedule.provider_id);
    const runId = repositories.createRun({
      kind: 'schedule',
      scheduleId: schedule.id,
      providerId: preference?.id,
      modelId: schedule.model_id ?? preference?.model_id,
      input: { prompt: schedule.prompt },
    });
    repositories.updateRun(runId, 'running');
    let status = 'completed';
    let output = '';
    try {
      const provider = await resolveProvider(preference, broker, {
        modelId: schedule.model_id,
        baseUrl: schedule.base_url,
      });
      const loaded = await composio.loadTools();
      const safeComposioTools = loaded.tools.filter((tool) => composio.policy(tool.name) === 'read');
      const tools = [...hostedTools, ...safeComposioTools];
      const messages: CanonicalMessage[] = [{ role: 'user', content: schedule.prompt }];
      let usage = { inputTokens: 0, outputTokens: 0 };
      for (let loop = 0; loop < 5; loop += 1) {
        const result = await provider.stream({
          messages,
          tools,
          systemPrompt: config.systemPrompt,
          maxTokens: config.scheduler.maxTokens,
        });
        usage = result.usage;
        const calls = result.content.filter(
          (block): block is Extract<CanonicalContentBlock, { type: 'tool_use' }> =>
            block.type === 'tool_use',
        );
        if (calls.length === 0) {
          output = result.content
            .filter((block): block is Extract<CanonicalContentBlock, { type: 'text' }> => block.type === 'text')
            .map((block) => block.text)
            .join('');
          break;
        }
        messages.push({ role: 'assistant', content: result.content });
        const results: CanonicalToolResultBlock[] = [];
        for (const call of calls) {
          const content = hostedTools.some((tool) => tool.name === call.name)
            ? await executeHostedTool(call.name, call.input)
            : await composio.execute(call.name, call.input, call.id);
          results.push({ type: 'tool_result', tool_use_id: call.id, content: content.slice(0, 8_000) });
        }
        messages.push({ role: 'user', content: results });
      }
      if (!output) throw new Error('Scheduled run exhausted safe tool iterations');
      repositories.updateRun(runId, 'completed', output);
      repositories.addRunEvent(runId, 'run_completed', { usage });
      if (schedule.notify_user) {
        const notification = repositories.createNotification(
          'scheduled_task', schedule.id, schedule.name, output,
        ) as Record<string, unknown>;
        events.send({ type: 'peek_notification', data: notification });
      }
    } catch {
      status = 'failed';
      output = 'Scheduled run failed';
      repositories.updateRun(runId, 'failed', null, output);
      repositories.addRunEvent(runId, 'run_failed', { code: 'provider_failure' });
    }
    repositories.finishSchedule(schedule, status, output, nextAfterCatchUp(schedule, config.scheduler.maxCatchUp));
  }
}

export function nextAfterCatchUp(schedule: ScheduleRecord, maxCatchUp: number, current = new Date()): Date {
  let next = computeNextRun({
    cron: schedule.cron,
    intervalMs: schedule.interval_ms,
    from: new Date(schedule.next_run_at),
  });
  let skipped = 0;
  while (next <= current && skipped < maxCatchUp) {
    next = computeNextRun({ cron: schedule.cron, intervalMs: schedule.interval_ms, from: next });
    skipped += 1;
  }
  if (next <= current) {
    next = computeNextRun({ cron: schedule.cron, intervalMs: schedule.interval_ms, from: current });
  }
  return next;
}
