import Button from './Button';
import { SITE } from './site-config';

function AppleIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.8-.91.65.03 2.47.26 3.64 1.98l-.09.06c-.22.15-2.19 1.3-2.17 3.88.03 3.08 2.71 4.12 2.75 4.13-.05.13-.42 1.45-1.33 2.56M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 1.05-3.11z" />
    </svg>
  );
}

function DownloadCTA() {
  if (!SITE.downloadUrl) {
    return (
      <div
        role="status"
        aria-label="Download coming soon"
        className="inline-flex items-center gap-2 rounded-full border border-white/20 px-6 py-3"
        style={{
          fontFamily: "'IBM Plex Mono', ui-monospace, monospace",
          fontSize: 16,
          fontWeight: 500,
          letterSpacing: '-0.02em',
          color: 'rgba(255,255,255,0.45)',
        }}
      >
        <AppleIcon />
        Coming soon
      </div>
    );
  }

  return (
    <Button href={SITE.downloadUrl} size="xl" external className="w-full sm:w-auto">
      <span className="[&_svg]:size-4">
        <AppleIcon />
      </span>
      Download for Mac
    </Button>
  );
}

export default function Download() {
  return (
    <section
      id="download"
      className="relative overflow-hidden border-t border-zinc-100 bg-[#111111]"
    >
      <div
        aria-hidden="true"
        className="absolute inset-0 bg-cover bg-center"
        style={{ backgroundImage: 'url(/hero-image.jpg)' }}
      />
      <div
        aria-hidden="true"
        className="absolute inset-0"
        style={{ background: 'rgba(0, 0, 0, 0.24)' }}
      />

      <div className="relative mx-auto max-w-[1280px] px-5 py-20 sm:px-8 md:py-40">
        <div className="flex flex-col items-start gap-8">
          <h2
            className="m-0 leading-tight"
            style={{
              fontFamily: "'IBM Plex Mono', ui-monospace, monospace",
              fontWeight: 400,
              fontSize: 'clamp(34px, 8vw, 72px)',
              color: '#ffffff',
              letterSpacing: '0.01em',
              textWrap: 'balance',
            } as React.CSSProperties}
          >
            Make your notch useful.
          </h2>

          <div className="flex w-full flex-col gap-3 sm:w-auto sm:flex-row sm:items-center">
            <DownloadCTA />

            <a
              href={SITE.supportEmail ? `mailto:${SITE.supportEmail}` : '#contact'}
              className="inline-flex w-full items-center justify-center gap-2 rounded-full text-white/55 no-underline hover:bg-white/10 hover:text-white sm:w-auto"
              style={{
                fontFamily: "'IBM Plex Mono', ui-monospace, monospace",
                fontSize: 16,
                fontWeight: 500,
                letterSpacing: '-0.02em',
                height: 48,
                padding: '0 28px',
              }}
            >
              Get in touch
            </a>
          </div>

          {SITE.downloadUrl && (
            <p
              className="m-0 text-white/35"
              style={{
                fontFamily: "'IBM Plex Mono', ui-monospace, monospace",
                fontSize: 12,
                letterSpacing: '-0.01em',
              }}
            >
              macOS 14+ · Apple silicon · Notarized by Apple
            </p>
          )}
        </div>
      </div>
    </section>
  );
}
