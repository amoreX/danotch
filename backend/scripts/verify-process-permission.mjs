import { execFileSync } from 'node:child_process';
import { launchThroughDependency } from './process-launch-fixture.mjs';

function expectDenied(label, launch) {
  try {
    launch();
    throw new Error(`${label} unexpectedly launched a child process`);
  } catch (error) {
    if (error?.code !== 'ERR_ACCESS_DENIED') throw error;
  }
}

expectDenied('direct launch', () => {
  execFileSync(process.execPath, ['-e', 'process.exit(0)']);
});

const dynamicModule = await import('node:child_process');
expectDenied('dynamic launch', () => {
  dynamicModule.spawnSync(process.execPath, ['-e', 'process.exit(0)']);
});

expectDenied('dependency-mediated launch', launchThroughDependency);
console.log('Node permission policy denied direct, dynamic, and dependency-mediated process launches.');
