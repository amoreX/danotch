import { randomUUID } from 'node:crypto';
import { chmodSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

export interface DiscoveryRecord {
  port: number;
  pid: number;
  protocolVersion: number;
  instanceId: string;
}

export function writeDiscoveryFile(path: string, value: DiscoveryRecord): void {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${process.pid}.${randomUUID()}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(value)}\n`, { encoding: 'utf8', mode: 0o600, flag: 'wx' });
  chmodSync(temporary, 0o600);
  renameSync(temporary, path);
  chmodSync(path, 0o600);
}

export function removeDiscoveryFile(path: string, instanceId: string): void {
  try {
    const current = JSON.parse(readFileSync(path, 'utf8')) as { instanceId?: string };
    if (current.instanceId === instanceId) rmSync(path);
  } catch {
    // Missing, malformed, or newly replaced discovery files are not ours.
  }
}
