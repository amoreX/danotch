import { randomUUID } from 'node:crypto';
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

  constructor(private readonly timeoutMs = 10_000) {
    if (this.nativeHost) return;

    // PerchDaemonHost explicitly connects the daemon's stdin/stdout to its
    // framed credential channel. Never guess an inherited descriptor: Node
    // commonly owns fd 4 for an unrelated internal pipe, which silently
    // black-holes Keychain requests.
    this.writer = process.stdout;
    this.reader = createInterface({ input: process.stdin, crlfDelay: Infinity });
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
    const startedAt = Date.now();
    console.error(`[perch-keychain] request id=${id} operation=${operation} credential=${credential}`);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        console.error(
          `[perch-keychain] timeout id=${id} operation=${operation} credential=${credential}`
          + ` elapsed_ms=${Date.now() - startedAt}`,
        );
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
    if (!message.ok) {
      console.error(`[perch-keychain] response id=${message.id} ok=false`);
      pending.reject(new Error('Native credential operation failed'));
    } else {
      console.error(`[perch-keychain] response id=${message.id} ok=true`);
      pending.resolve(message.value);
    }
  }

  private failAll(error: Error): void {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }
}
