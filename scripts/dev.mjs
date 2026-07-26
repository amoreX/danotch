#!/usr/bin/env node

import { createHash, randomBytes } from 'node:crypto';
import { existsSync, realpathSync, rmSync } from 'node:fs';
import { cp, mkdir, mkdtemp, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { homedir, platform, tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const scriptPath = fileURLToPath(import.meta.url);
const appDirectory = join(root, 'app');
const backendDirectory = join(root, 'backend');
const siteDirectory = join(root, 'site');
const appBundle = join(appDirectory, 'Perch.app');
const daemonHost = join(appBundle, 'Contents', 'Helpers', 'PerchDaemonHost');
const stackLockDirectory = join(homedir(), 'Library', 'Caches', 'Perch', 'development', 'stack.lock');
const children = new Set();
let stopping = false;
let ownsStackLock = false;

function fail(message) {
  console.error(`ERROR: ${message}`);
  process.exit(1);
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: root,
    env: process.env,
    stdio: 'inherit',
    ...options,
  });
  if (result.error) fail(`${command} could not start: ${result.error.message}`);
  if (result.status !== 0) process.exit(result.status ?? 1);
}

function runChecked(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: root,
    env: process.env,
    stdio: 'inherit',
    ...options,
  });
  if (result.error) throw new Error(`${command} could not start: ${result.error.message}`);
  if (result.status !== 0) throw new Error(`${command} exited with status ${result.status ?? 'unknown'}`);
}

function capture(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: root,
    env: process.env,
    encoding: 'utf8',
    ...options,
  });
  if (result.error) fail(`${command} could not start: ${result.error.message}`);
  if (result.status !== 0) {
    if (result.stderr) process.stderr.write(result.stderr);
    process.exit(result.status ?? 1);
  }
  return result.stdout.trim();
}

function requireCommand(command, guidance) {
  const result = spawnSync('/usr/bin/which', [command], { encoding: 'utf8' });
  if (result.status !== 0) fail(guidance);
}

async function ensurePinnedNode() {
  if (Number(process.versions.node.split('.')[0]) === 24) return;
  if (process.env.PERCH_DEV_NODE_BOOTSTRAPPED === '1') {
    fail(`Pinned Node 24 failed to start; currently running ${process.version}.`);
  }

  const manifestText = await readFile(join(root, 'release', 'node-runtime.env'), 'utf8');
  const manifest = Object.fromEntries(
    manifestText
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => line && !line.startsWith('#'))
      .map((line) => {
        const separator = line.indexOf('=');
        if (separator <= 0) fail('release/node-runtime.env is malformed.');
        return [line.slice(0, separator), line.slice(separator + 1)];
      }),
  );
  const {
    NODE_VERSION: version,
    NODE_PLATFORM: runtimePlatform,
    NODE_ARCHIVE_FORMAT: archiveFormat,
    NODE_BASE_URL: baseURL,
  } = manifest;
  if (!/^24\.\d+\.\d+$/.test(version ?? '')
      || runtimePlatform !== 'darwin-arm64'
      || archiveFormat !== 'tar.gz'
      || baseURL !== 'https://nodejs.org/dist') {
    fail('the pinned development runtime manifest is invalid.');
  }

  const archiveName = `node-v${version}-${runtimePlatform}.${archiveFormat}`;
  const checksumText = await readFile(join(root, 'release', 'node-runtime.sha256'), 'utf8');
  const checksumLine = checksumText
    .split('\n')
    .find((line) => line.trim().endsWith(`  ${archiveName}`));
  const expectedChecksum = checksumLine?.trim().split(/\s+/)[0]?.toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(expectedChecksum ?? '')) {
    fail(`no valid checksum is pinned for ${archiveName}.`);
  }

  const cacheRoot = join(homedir(), 'Library', 'Caches', 'Perch', 'development');
  const runtimeDirectory = join(cacheRoot, `node-v${version}-${runtimePlatform}`);
  const pinnedNode = join(runtimeDirectory, 'bin', 'node');
  if (!existsSync(pinnedNode)) {
    requireCommand('curl', 'curl is required to download the pinned Node 24 development runtime.');
    requireCommand('tar', 'tar is required to unpack the pinned Node 24 development runtime.');
    await mkdir(cacheRoot, { recursive: true, mode: 0o700 });
    const staging = await mkdtemp(join(tmpdir(), 'perch-dev-node.'));
    const archive = join(staging, archiveName);
    const extracted = join(staging, `node-v${version}-${runtimePlatform}`);
    let bootstrapError;
    try {
      console.log(`Downloading verified Node ${version} for Perch development...`);
      runChecked('/usr/bin/curl', [
        '--fail',
        '--show-error',
        '--location',
        '--proto',
        '=https',
        '--tlsv1.2',
        `${baseURL}/v${version}/${archiveName}`,
        '--output',
        archive,
      ]);
      const actualChecksum = createHash('sha256')
        .update(await readFile(archive))
        .digest('hex');
      if (actualChecksum !== expectedChecksum) {
        throw new Error(`checksum verification failed for ${archiveName}`);
      }
      runChecked('/usr/bin/tar', ['-xzf', archive, '-C', staging]);
      if (!existsSync(join(extracted, 'bin', 'node'))) {
        throw new Error('the verified Node archive has an unexpected layout');
      }
      await rm(runtimeDirectory, { recursive: true, force: true });
      await rename(extracted, runtimeDirectory);
    } catch (error) {
      bootstrapError = error;
    } finally {
      await rm(staging, { recursive: true, force: true });
    }
    if (bootstrapError) {
      fail(`could not prepare Node 24: ${bootstrapError.message}`);
    }
  }

  console.log(`Restarting with pinned Node ${version}...`);
  const result = spawnSync(pinnedNode, [scriptPath, ...process.argv.slice(2)], {
    cwd: root,
    env: { ...process.env, PERCH_DEV_NODE_BOOTSTRAPPED: '1' },
    stdio: 'inherit',
  });
  if (result.error) fail(`pinned Node 24 could not start: ${result.error.message}`);
  process.exit(result.status ?? 1);
}

async function acquireStackLock() {
  await mkdir(dirname(stackLockDirectory), { recursive: true, mode: 0o700 });
  try {
    await mkdir(stackLockDirectory, { mode: 0o700 });
  } catch (error) {
    if (error?.code !== 'EEXIST') throw error;
    const owner = Number.parseInt(
      await readFile(join(stackLockDirectory, 'pid'), 'utf8').catch(() => ''),
      10,
    );
    let ownerIsRunning = false;
    if (Number.isSafeInteger(owner) && owner > 1) {
      try {
        process.kill(owner, 0);
        ownerIsRunning = true;
      } catch {
        ownerIsRunning = false;
      }
    }
    if (ownerIsRunning) {
      fail(`another Perch development stack is already running (pid ${owner}).`);
    }
    await rm(stackLockDirectory, { recursive: true, force: true });
    await mkdir(stackLockDirectory, { mode: 0o700 });
  }
  await writeFile(join(stackLockDirectory, 'pid'), `${process.pid}\n`, { mode: 0o600 });
  ownsStackLock = true;
}

function stop(exitCode = 0) {
  if (stopping) return;
  stopping = true;
  for (const child of children) {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
  }
  const deadline = setTimeout(() => {
    for (const child of children) {
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
    }
    process.exit(exitCode);
  }, 3_000);
  deadline.unref();
  Promise.allSettled(
    [...children].map((child) => new Promise((resolveExit) => {
      if (child.exitCode !== null || child.signalCode !== null) resolveExit();
      else child.once('exit', resolveExit);
    })),
  ).then(() => {
    clearTimeout(deadline);
    process.exit(exitCode);
  });
}

const machineArchitecture = spawnSync('/usr/bin/uname', ['-m'], { encoding: 'utf8' }).stdout.trim();
if (platform() !== 'darwin' || machineArchitecture !== 'arm64') {
  fail('development requires macOS 26+ on Apple Silicon.');
}
await ensurePinnedNode();
await acquireStackLock();
const developmentInstallationSecret = randomBytes(32).toString('base64');
process.on('exit', () => {
  if (ownsStackLock) rmSync(stackLockDirectory, { recursive: true, force: true });
});

requireCommand('swift', 'Swift 6.2 or newer is required through Xcode Command Line Tools.');
requireCommand('codesign', 'codesign is required through Xcode Command Line Tools.');

const nodeBinary = realpathSync(process.execPath);
const nodeRuntime = dirname(dirname(nodeBinary));
const npmBinary = join(nodeRuntime, 'bin', 'npm');
if (!existsSync(npmBinary)) {
  fail(`npm was not found beside the active Node 24 runtime at ${npmBinary}.`);
}
process.env.PATH = `${join(nodeRuntime, 'bin')}:${process.env.PATH ?? ''}`;

console.log('Installing website dependencies...');
run(npmBinary, ['ci', '--prefix', siteDirectory]);

console.log('Building the app and authenticated local daemon...');
run(npmBinary, ['ci', '--prefix', backendDirectory]);
run(npmBinary, ['run', '--prefix', backendDirectory, 'build']);

const daemonStaging = join(appDirectory, '.build', 'daemon-staging-dev');
await rm(daemonStaging, { recursive: true, force: true });
await mkdir(daemonStaging, { recursive: true, mode: 0o700 });
await cp(join(backendDirectory, 'package.json'), join(daemonStaging, 'package.json'));
await cp(join(backendDirectory, 'package-lock.json'), join(daemonStaging, 'package-lock.json'));
run(npmBinary, ['ci', '--prefix', daemonStaging, '--omit=dev']);
await cp(join(backendDirectory, 'dist'), join(daemonStaging, 'dist'), { recursive: true });
await cp(join(appDirectory, 'scripts', 'daemon-entry.mjs'), join(daemonStaging, 'entry.mjs'));

run('/usr/bin/swift', ['build', '--package-path', appDirectory, '--configuration', 'debug']);
const swiftBin = capture('/usr/bin/swift', [
  'build',
  '--package-path',
  appDirectory,
  '--configuration',
  'debug',
  '--show-bin-path',
]);

const contents = join(appBundle, 'Contents');
const macOSDirectory = join(contents, 'MacOS');
const helpersDirectory = join(contents, 'Helpers');
const resourcesDirectory = join(contents, 'Resources');
await rm(appBundle, { recursive: true, force: true });
await mkdir(macOSDirectory, { recursive: true });
await mkdir(helpersDirectory, { recursive: true });
await mkdir(resourcesDirectory, { recursive: true });
await cp(join(swiftBin, 'Perch'), join(macOSDirectory, 'Perch'));
await cp(join(swiftBin, 'PerchDaemonHost'), join(helpersDirectory, 'PerchDaemonHost'));
await cp(join(swiftBin, 'PerchExecutor'), join(helpersDirectory, 'PerchExecutor'));
await cp(join(appDirectory, 'Resources'), resourcesDirectory, { recursive: true });
await rm(join(resourcesDirectory, 'Info.plist'), { force: true });
await cp(nodeRuntime, join(resourcesDirectory, 'DaemonRuntime'), {
  recursive: true,
  dereference: true,
});
await cp(daemonStaging, join(resourcesDirectory, 'Daemon'), {
  recursive: true,
  dereference: true,
});

const infoTemplate = await readFile(join(appDirectory, 'Resources', 'Info.plist'), 'utf8');
const infoPlist = infoTemplate
  .replaceAll('$(DEVELOPMENT_LANGUAGE)', 'en')
  .replaceAll('$(EXECUTABLE_NAME)', 'Perch')
  .replaceAll('$(PRODUCT_BUNDLE_IDENTIFIER)', 'engineering.super.Perch')
  .replaceAll('$(PRODUCT_NAME)', 'Perch')
  .replaceAll('$(MARKETING_VERSION)', '0.0.0-dev')
  .replaceAll('$(CURRENT_PROJECT_VERSION)', '1');
await writeFile(join(contents, 'Info.plist'), infoPlist, { mode: 0o644 });

run('/usr/bin/codesign', [
  '--force', '--options', 'runtime',
  '--entitlements', join(appDirectory, 'NodeRuntime.entitlements'),
  '--sign', '-',
  join(resourcesDirectory, 'DaemonRuntime', 'bin', 'node'),
]);
run('/usr/bin/codesign', [
  '--force', '--options', 'runtime', '--sign', '-',
  join(helpersDirectory, 'PerchDaemonHost'),
]);
run('/usr/bin/codesign', [
  '--force', '--options', 'runtime',
  '--entitlements', join(appDirectory, 'Executor.entitlements'),
  '--sign', '-', join(helpersDirectory, 'PerchExecutor'),
]);
run('/usr/bin/codesign', [
  '--force', '--options', 'runtime',
  '--entitlements', join(appDirectory, 'Perch.entitlements'),
  '--sign', '-', appBundle,
]);
run('/usr/bin/codesign', ['--verify', '--deep', '--strict', appBundle]);

if (!existsSync(daemonHost)) fail('the built native daemon host is missing.');

process.on('SIGINT', () => stop(0));
process.on('SIGTERM', () => stop(0));

const host = spawn(daemonHost, [], {
  cwd: appDirectory,
  env: { PERCH_DEV_INSTALLATION_SECRET: developmentInstallationSecret },
  stdio: ['ignore', 'inherit', 'inherit'],
});
children.add(host);
host.once('error', (error) => {
  console.error(`Local daemon host failed to start: ${error.message}`);
  stop(1);
});
host.once('exit', (code, signal) => {
  children.delete(host);
  if (!stopping) {
    console.error(`Local daemon host stopped unexpectedly (${signal ?? code ?? 'unknown'}).`);
    stop(code || 1);
  }
});

const app = spawn(join(macOSDirectory, 'Perch'), [], {
  cwd: appDirectory,
  env: {
    ...process.env,
    PERCH_DEV_INSTALLATION_SECRET: developmentInstallationSecret,
  },
  stdio: 'inherit',
});
children.add(app);
app.once('error', (error) => {
  console.error(`Perch app failed to start: ${error.message}`);
  stop(1);
});
app.once('exit', (code, signal) => {
  children.delete(app);
  if (!stopping) {
    console.error(`Perch app stopped (${signal ?? code ?? 'unknown'}).`);
    stop(code ?? (signal ? 0 : 1));
  }
});

const site = spawn(npmBinary, ['run', 'dev', '--', '--host', '127.0.0.1'], {
  cwd: siteDirectory,
  env: process.env,
  stdio: 'inherit',
});
children.add(site);
site.once('error', (error) => {
  console.error(`Website dev server failed to start: ${error.message}`);
  stop(1);
});
site.once('exit', (code, signal) => {
  children.delete(site);
  if (!stopping) {
    console.error(`Website dev server stopped (${signal ?? code ?? 'unknown'}).`);
    stop(code || 0);
  }
});

console.log('Perch is opening. Website: http://127.0.0.1:5173');
console.log('Press Ctrl+C to stop the app, daemon, and website.');
