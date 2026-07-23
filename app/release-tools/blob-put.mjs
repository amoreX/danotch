import { readFile } from 'node:fs/promises';
import { put } from '@vercel/blob';

const [file, pathname, contentType, cacheSeconds, overwrite = 'false'] = process.argv.slice(2);
if (!file || !pathname || !contentType || !cacheSeconds) {
  throw new Error(
    'usage: blob-put.mjs <file> <pathname> <content-type> <cache-seconds> [true|false]',
  );
}
if (!process.env.BLOB_READ_WRITE_TOKEN) {
  throw new Error('BLOB_READ_WRITE_TOKEN is required');
}
const cacheControlMaxAge = Number.parseInt(cacheSeconds, 10);
if (!Number.isSafeInteger(cacheControlMaxAge) || cacheControlMaxAge < 60) {
  throw new Error('cache-seconds must be an integer of at least 60');
}
if (!['true', 'false'].includes(overwrite)) {
  throw new Error('overwrite must be true or false');
}

const blob = await put(pathname, await readFile(file), {
  access: 'public',
  addRandomSuffix: false,
  allowOverwrite: overwrite === 'true',
  cacheControlMaxAge,
  contentType,
  token: process.env.BLOB_READ_WRITE_TOKEN,
});
const returnedUrl = new URL(blob.url);
if (
  blob.pathname !== pathname
  || returnedUrl.protocol !== 'https:'
  || !returnedUrl.hostname.endsWith('.public.blob.vercel-storage.com')
  || returnedUrl.pathname.slice(1) !== pathname
  || returnedUrl.search
  || returnedUrl.hash
) {
  throw new Error(`Vercel Blob returned an unexpected URL/pathname for ${pathname}`);
}
process.stdout.write(`${blob.url}\n`);
