import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import type { NextFunction, Request, Response } from 'express';

interface Session {
  hash: Buffer;
  expiresAt: number;
}

const digest = (value: string | Buffer) => createHash('sha256').update(value).digest();

export class SessionManager {
  private readonly installationDigest: Buffer;
  private readonly sessions = new Map<string, Session>();

  constructor(installationSecret: Buffer, private readonly ttlMs: number) {
    this.installationDigest = digest(installationSecret);
    installationSecret.fill(0);
  }

  exchange(encodedSecret: unknown): { token: string; expiresAt: string } | undefined {
    if (typeof encodedSecret !== 'string' || encodedSecret.length > 256) return undefined;
    const candidate = Buffer.from(encodedSecret, 'base64');
    const candidateDigest = digest(candidate);
    candidate.fill(0);
    if (!timingSafeEqual(candidateDigest, this.installationDigest)) return undefined;

    const token = randomBytes(32).toString('base64url');
    const key = digest(token).toString('hex');
    const expiresAt = Date.now() + this.ttlMs;
    this.sessions.set(key, { hash: digest(token), expiresAt });
    this.sweep();
    return { token, expiresAt: new Date(expiresAt).toISOString() };
  }

  authenticate(token: string | undefined): boolean {
    if (!token || token.length > 128) return false;
    const key = digest(token).toString('hex');
    const session = this.sessions.get(key);
    if (!session || session.expiresAt <= Date.now()) {
      if (session) this.sessions.delete(key);
      return false;
    }
    return timingSafeEqual(session.hash, digest(token));
  }

  middleware = (req: Request, res: Response, next: NextFunction): void => {
    const value = req.headers.authorization;
    const token = typeof value === 'string' && value.startsWith('Bearer ') ? value.slice(7) : undefined;
    if (!this.authenticate(token)) {
      res.status(401).json({ error: 'Valid local session token required' });
      return;
    }
    next();
  };

  close(): void {
    this.installationDigest.fill(0);
    for (const session of this.sessions.values()) session.hash.fill(0);
    this.sessions.clear();
  }

  private sweep(): void {
    const timestamp = Date.now();
    for (const [key, session] of this.sessions) {
      if (session.expiresAt <= timestamp) this.sessions.delete(key);
    }
  }
}
