export function signupBrowserCsp(provider: 'turnstile' | 'hcaptcha'): string {
  const scriptSources = provider === 'turnstile'
    ? 'https://challenges.cloudflare.com'
    : 'https://js.hcaptcha.com https://*.hcaptcha.com';
  const widgetSources = provider === 'turnstile'
    ? 'https://challenges.cloudflare.com'
    : 'https://*.hcaptcha.com';
  return [
    "default-src 'none'",
    "base-uri 'none'",
    "object-src 'none'",
    "frame-ancestors 'none'",
    "form-action 'self'",
    `script-src ${scriptSources}`,
    `frame-src ${widgetSources}`,
    `connect-src ${widgetSources}`,
    `style-src 'unsafe-inline'${provider === 'hcaptcha' ? ` ${widgetSources}` : ''}`,
  ].join('; ');
}
