import { execFileSync } from 'node:child_process';

export function launchThroughDependency() {
  return execFileSync(process.execPath, ['-e', 'process.exit(0)']);
}
