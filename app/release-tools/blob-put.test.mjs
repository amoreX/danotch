import assert from 'node:assert/strict';
import { once } from 'node:events';
import { writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import test from 'node:test';

async function invoke(overwrite) {
  const requests = [];
  const server = createServer((request, response) => {
    requests.push(request);
    const pathname = new URL(request.url, 'http://localhost').searchParams.get('pathname');
    response.setHeader('content-type', 'application/json');
    response.end(JSON.stringify({
      url: `https://storeid.public.blob.vercel-storage.com/${pathname}`,
      downloadUrl: `https://storeid.public.blob.vercel-storage.com/${pathname}?download=1`,
      pathname,
      contentType: 'application/xml',
      contentDisposition: 'inline',
      etag: 'test-etag',
    }));
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');

  const file = join(tmpdir(), `perch-blob-${process.pid}-${overwrite}.xml`);
  await writeFile(file, '<rss/>');
  const port = server.address().port;
  const child = spawn(process.execPath, [
    new URL('./blob-put.mjs', import.meta.url).pathname,
    file,
    'updates/appcast.xml',
    'application/xml',
    '60',
    String(overwrite),
  ], {
    env: {
      ...process.env,
      BLOB_READ_WRITE_TOKEN: 'vercel_blob_rw_storeid_test',
      VERCEL_BLOB_API_URL: `http://127.0.0.1:${port}`,
      VERCEL_BLOB_RETRIES: '0',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8').on('data', chunk => { stdout += chunk; });
  child.stderr.setEncoding('utf8').on('data', chunk => { stderr += chunk; });
  const [exitCode] = await once(child, 'exit');
  server.close();

  assert.equal(exitCode, 0, stderr);
  assert.equal(stdout.trim(), 'https://storeid.public.blob.vercel-storage.com/updates/appcast.xml');
  assert.equal(requests.length, 1);
  return requests[0].headers;
}

test('pins stable pathname without a random suffix and controls overwrite', async () => {
  const immutable = await invoke(false);
  assert.equal(immutable['x-add-random-suffix'], '0');
  assert.equal(immutable['x-allow-overwrite'], '0');
  assert.equal(immutable['x-cache-control-max-age'], '60');

  const stable = await invoke(true);
  assert.equal(stable['x-add-random-suffix'], '0');
  assert.equal(stable['x-allow-overwrite'], '1');
  assert.equal(stable['x-cache-control-max-age'], '60');
});
