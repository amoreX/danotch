import { createReadStream } from 'node:fs';

const MAX_BOOTSTRAP_BYTES = 4_096;

function readLine(stream: NodeJS.ReadableStream): Promise<string> {
  return new Promise((resolve, reject) => {
    let value = '';
    const onData = (chunk: Buffer | string) => {
      value += chunk.toString();
      if (Buffer.byteLength(value) > MAX_BOOTSTRAP_BYTES) {
        cleanup();
        reject(new Error('Bootstrap input exceeds limit'));
        return;
      }
      const newline = value.indexOf('\n');
      if (newline >= 0) {
        cleanup();
        resolve(value.slice(0, newline).trim());
      }
    };
    const onEnd = () => {
      cleanup();
      resolve(value.trim());
    };
    const onError = (error: Error) => {
      cleanup();
      reject(error);
    };
    const cleanup = () => {
      stream.off('data', onData);
      stream.off('end', onEnd);
      stream.off('error', onError);
    };
    stream.on('data', onData);
    stream.once('end', onEnd);
    stream.once('error', onError);
  });
}

export async function readInstallationSecret(): Promise<Buffer> {
  const nativeSecret = globalThis.__perchNativeHost?.installationSecret;
  if (nativeSecret !== undefined) return decodeInstallationSecret(nativeSecret);

  let encoded: string;
  try {
    encoded = await readLine(createReadStream('', { fd: 3, autoClose: false }));
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code !== 'EBADF' && code !== 'EINVAL') throw error;
    encoded = await readLine(process.stdin);
  }
  return decodeInstallationSecret(encoded);
}

function decodeInstallationSecret(encoded: string): Buffer {
  const secret = Buffer.from(encoded, 'base64');
  if (secret.byteLength < 32 || secret.byteLength > 128) {
    secret.fill(0);
    throw new Error('Installation secret must be 32-128 bytes encoded as base64');
  }
  return secret;
}
