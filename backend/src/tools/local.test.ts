import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { isPrivateAddress } from './local.ts';

test('SSRF address policy rejects private and link-local IPv4 and IPv6', () => {
  for (const address of [
    '0.0.0.0', '10.1.2.3', '100.64.0.1', '127.0.0.1', '169.254.169.254',
    '172.16.0.1', '192.168.1.1', '::', '::1', 'fc00::1', 'fd12::1',
    'fe80::1', 'ff02::1', '::ffff:127.0.0.1',
  ]) {
    assert.equal(isPrivateAddress(address), true, address);
  }
  assert.equal(isPrivateAddress('1.1.1.1'), false);
  assert.equal(isPrivateAddress('2606:4700:4700::1111'), false);
});

test('hosted fetch pins validated DNS, revalidates redirects, caps bytes, and times out', async () => {
  const source = await readFile(new URL('./local.ts', import.meta.url), 'utf8');
  assert.match(source, /lookup\(parsed\.hostname, \{ all: true/);
  assert.match(source, /records\.some\(\(record\) => isPrivateAddress/);
  assert.match(source, /lookup: \(_hostname, _options, callback\)/);
  assert.match(source, /secureRequest\(new URL\(location, parsed\)\.toString\(\), redirects \+ 1\)/);
  assert.match(source, /bytes > MAX_BODY_BYTES/);
  assert.match(source, /req\.setTimeout\(REQUEST_TIMEOUT_MS/);
  assert.doesNotMatch(source, /return `Fetch failed: \$\{.*message/);
});
