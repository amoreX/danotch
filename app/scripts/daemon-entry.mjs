import { createInterface } from 'node:readline';

const MAX_LINE_BYTES = 64 * 1024;
const MAX_VALUE_BYTES = 16 * 1024;
const ALLOWED_CREDENTIALS = new Set([
  'installation.secret',
  'provider.anthropic',
  'provider.openai',
  'provider.openrouter',
  'provider.deepseek',
  'provider.custom_openai',
  'composio',
]);

for (const method of ['log', 'info', 'debug']) {
  console[method] = (...args) => console.error(...args);
}

const lines = createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
  terminal: false,
});

let bootstrapResolve;
let bootstrapReject;
const bootstrap = new Promise((resolve, reject) => {
  bootstrapResolve = resolve;
  bootstrapReject = reject;
});
const pending = new Map();
let nextID = 1;
let bootstrapped = false;

function fail(message) {
  const error = new Error(message);
  if (!bootstrapped) bootstrapReject(error);
  for (const request of pending.values()) request.reject(error);
  pending.clear();
  process.exitCode = 1;
  lines.close();
}

lines.on('line', (line) => {
  if (Buffer.byteLength(line, 'utf8') > MAX_LINE_BYTES) {
    fail('native host line too large');
    return;
  }

  let message;
  try {
    message = JSON.parse(line);
  } catch {
    fail('invalid native host JSON');
    return;
  }

  if (!bootstrapped) {
    if (
      message?.type !== 'bootstrap'
      || typeof message.installationSecret !== 'string'
      || Buffer.byteLength(message.installationSecret, 'utf8') > MAX_VALUE_BYTES
    ) {
      fail('invalid native host bootstrap');
      return;
    }
    bootstrapped = true;
    bootstrapResolve(message.installationSecret);
    return;
  }

  if (typeof message?.id !== 'string' || typeof message.ok !== 'boolean') {
    fail('invalid native host response');
    return;
  }
  const request = pending.get(message.id);
  if (!request) {
    fail('unexpected native host response');
    return;
  }
  pending.delete(message.id);
  if (message.ok) {
    if (message.value !== undefined && typeof message.value !== 'string') {
      request.reject(new Error('invalid native host value'));
    } else {
      request.resolve(message.value);
    }
  } else {
    request.reject(new Error(typeof message.error === 'string' ? message.error : 'credential operation failed'));
  }
});

lines.on('close', () => {
  if (!bootstrapped || pending.size > 0) fail('native host channel closed');
});

function credentialRequest(operation, credential, value) {
  if (!['get', 'set', 'delete'].includes(operation)) {
    return Promise.reject(new Error('invalid credential operation'));
  }
  if (!ALLOWED_CREDENTIALS.has(credential)) {
    return Promise.reject(new Error('credential not allowed'));
  }
  if (operation === 'set') {
    if (typeof value !== 'string' || Buffer.byteLength(value, 'utf8') > MAX_VALUE_BYTES) {
      return Promise.reject(new Error('invalid credential value'));
    }
  } else if (value !== undefined) {
    return Promise.reject(new Error('value only allowed for set'));
  }

  const id = `node-${nextID++}`;
  const message = { id, operation, credential };
  if (value !== undefined) message.value = value;
  const encoded = `${JSON.stringify(message)}\n`;
  if (Buffer.byteLength(encoded, 'utf8') > MAX_LINE_BYTES) {
    return Promise.reject(new Error('credential request too large'));
  }

  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    process.stdout.write(encoded, 'utf8', (error) => {
      if (error) {
        pending.delete(id);
        reject(error);
      }
    });
  });
}

const installationSecret = await bootstrap;
const nativeHost = Object.freeze({
  installationSecret,
  getCredential: (credential) => credentialRequest('get', credential),
  setCredential: (credential, value) => credentialRequest('set', credential, value),
  deleteCredential: (credential) => credentialRequest('delete', credential),
});

Object.defineProperty(globalThis, '__perchNativeHost', {
  value: nativeHost,
  configurable: false,
  enumerable: false,
  writable: false,
});

await import('./dist/index.js');
