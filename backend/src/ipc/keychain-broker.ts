import { randomUUID } from 'node:crypto';
import { createReadStream, createWriteStream, fstatSync } from 'node:fs';
import { createInterface, type Interface } from 'node:readline';

export const CREDENTIALS = [
  'provider.anthropic',
  'provider.openai',
  'provider.openrouter',
  'provider.deepseek',
  'provider.custom_openai',
  'composio',
] as const;
export type Credential = typeof CREDENTIALS[number];
const allowedCredentials = new Set<string>(CREDENTIALS);

export interface SecretBroker {
  getCredential(credential: Credential): Promise<string | undefined>;
  setCredential(credential: Credential, value: string): Promise<void>;
  deleteCredential(credential: Credential): Promise<void>;
  close(): void;
}

interface FallbackResponse {
  id: string;
  ok: boolean;
  value?: string;
  error?: string;
}

interface Pending {
  resolve(value: string | undefined): void;
  reject(error: Error): void;
  timer: NodeJS.Timeout;
}

export class KeychainBroker implements SecretBroker {
  private readonly nativeHost = globalThis.__perchNativeHost;
  private readonly reader?: Interface;
  private readonly writer?: NodeJS.WritableStream;
  private readonly pending = new Map<string, Pending>();

  constructor(fd = 4, private readonly timeoutMs = 10_000) {
    if (this.nativeHost) return;

    let input: NodeJS.ReadableStream;
    try {
      fstatSync(fd);
      input = createReadStream('', { fd, autoClose: false });
      this.writer = createWriteStream('', { fd, autoClose: false });
    } catch {
      input = process.stdin;
      this.writer = process.stdout;
    }
    this.reader = createInterface({ input, crlfDelay: Infinity });
    this.reader.on('line', (line) => this.receive(line));
    this.reader.on('close', () => this.failAll(new Error('Native credential channel closed')));
  }

  getCredential(credential: Credential): Promise<string | undefined> {
    this.validateCredential(credential);
    if (this.nativeHost) return this.nativeHost.getCredential(credential);
    return this.call('get', credential);
  }

  async setCredential(credential: Credential, value: string): Promise<void> {
    this.validateCredential(credential);
    if (typeof value !== 'string' || value.length === 0 || Buffer.byteLength(value) > 16_384) {
      throw new Error('Invalid credential value');
    }
    if (this.nativeHost) {
      await this.nativeHost.setCredential(credential, value);
      return;
    }
    await this.call('set', credential, value);
  }

  async deleteCredential(credential: Credential): Promise<void> {
    this.validateCredential(credential);
    if (this.nativeHost) {
      await this.nativeHost.deleteCredential(credential);
      return;
    }
    await this.call('delete', credential);
  }

  close(): void {
    this.reader?.close();
    this.failAll(new Error('Native credential channel closed'));
  }

  private validateCredential(credential: string): void {
    if (!allowedCredentials.has(credential)) throw new Error('Credential not allowed');
  }

  private call(
    operation: 'get' | 'set' | 'delete',
    credential: Credential,
    value?: string,
  ): Promise<string | undefined> {
    if (!this.writer) return Promise.reject(new Error('Native credential channel unavailable'));
    const id = randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error('Native credential operation timed out'));
      }, this.timeoutMs);
      timer.unref();
      this.pending.set(id, { resolve, reject, timer });
      const message: Record<string, unknown> = { id, operation, credential };
      if (value !== undefined) message.value = value;
      this.writer!.write(`${JSON.stringify(message)}\n`, (error) => {
        if (!error) return;
        clearTimeout(timer);
        this.pending.delete(id);
        reject(new Error('Native credential channel unavailable'));
      });
    });
  }

  private receive(line: string): void {
    if (Buffer.byteLength(line) > 65_536) {
      this.failAll(new Error('Native credential frame exceeds limit'));
      return;
    }
    let message: FallbackResponse;
    try {
      message = JSON.parse(line) as FallbackResponse;
    } catch {
      return;
    }
    const pending = this.pending.get(message.id);
    if (!pending) return;
    this.pending.delete(message.id);
    clearTimeout(pending.timer);
    if (!message.ok) pending.reject(new Error('Native credential operation failed'));
    else pending.resolve(message.value);
  }

  private failAll(error: Error): void {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }
}
