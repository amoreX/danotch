import { CronExpressionParser } from 'cron-parser';

export function computeNextRun(taskType: string, cron?: string | null, intervalMs?: number | null): Date {
  if (taskType === 'poll' && intervalMs) {
    return new Date(Date.now() + intervalMs);
  }

  if (taskType === 'scheduled' && cron) {
    try {
      const interval = CronExpressionParser.parse(cron);
      return interval.next().toDate();
    } catch (e) {
      console.error(`[scheduler] Invalid cron "${cron}":`, e);
      return new Date(Date.now() + 3600_000);
    }
  }

  return new Date(Date.now() + 3600_000);
}

export function isValidCron(cron: string): boolean {
  try {
    CronExpressionParser.parse(cron);
    return true;
  } catch {
    return false;
  }
}

export function cronToHuman(cron: string): string {
  const parts = cron.trim().split(/\s+/);
  if (parts.length !== 5) return cron;

  const [min, hour, dom, mon, dow] = parts;

  if (dom === '*' && mon === '*') {
    const timeStr = hour !== '*' && min !== '*'
      ? `${hour.padStart(2, '0')}:${min.padStart(2, '0')}`
      : null;

    if (dow === '*' && timeStr) return `Daily at ${timeStr}`;
    if (dow === '1-5' && timeStr) return `Weekdays at ${timeStr}`;
    if (dow === '0' && timeStr) return `Sundays at ${timeStr}`;
    if (dow === '1' && timeStr) return `Mondays at ${timeStr}`;
    if (hour === '*' && min.startsWith('*/')) return `Every ${min.slice(2)} minutes`;
    if (min === '0' && hour.startsWith('*/')) return `Every ${hour.slice(2)} hours`;
    if (min === '0' && hour === '*') return `Every hour`;
  }

  return cron;
}

export function scheduleToHuman(taskType: string, cron?: string | null, intervalMs?: number | null): string {
  if (taskType === 'scheduled' && cron) return cronToHuman(cron);
  return `Every ${Math.round((intervalMs ?? 0) / 60000)}m`;
}
