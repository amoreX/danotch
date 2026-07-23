export type CaptchaProvider = 'turnstile' | 'hcaptcha';

export interface CaptchaConfig {
  provider: CaptchaProvider;
  secret: string;
  expectedHostname?: string;
}

export class CaptchaVerifier {
  constructor(
    private readonly config: CaptchaConfig,
    private readonly fetcher: typeof fetch = fetch,
  ) {}

  async verify(token: string, remoteIp?: string): Promise<boolean> {
    if (!token || !this.config.secret) return false;
    const endpoint = this.config.provider === 'turnstile'
      ? 'https://challenges.cloudflare.com/turnstile/v0/siteverify'
      : 'https://hcaptcha.com/siteverify';
    const form = new URLSearchParams({
      secret: this.config.secret,
      response: token,
    });
    if (remoteIp) form.set('remoteip', remoteIp);
    try {
      const response = await this.fetcher(endpoint, {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: form,
        signal: AbortSignal.timeout(8_000),
      });
      if (!response.ok) return false;
      const result = await response.json() as { success?: boolean; hostname?: string };
      if (result.success !== true) return false;
      return !this.config.expectedHostname || result.hostname === this.config.expectedHostname;
    } catch {
      return false;
    }
  }
}
