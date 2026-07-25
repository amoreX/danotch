import { execFileSync } from 'node:child_process';

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

console.log('Node permission policy denied direct and dynamic process launches.');
