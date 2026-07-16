import Button from './Button';
import { SITE } from './site-config';

function AppleIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.8-.91.65.03 2.47.26 3.64 1.98l-.09.06c-.22.15-2.19 1.3-2.17 3.88.03 3.08 2.71 4.12 2.75 4.13-.05.13-.42 1.45-1.33 2.56M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 1.05-3.11z" />
    </svg>
  );
}

function GitHubIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M12 0C5.374 0 0 5.373 0 12c0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23A11.509 11.509 0 0112 5.803c1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576C20.566 21.797 24 17.3 24 12c0-6.627-5.373-12-12-12z" />
    </svg>
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
     

      <div className="relative max-w-[1280px] mx-auto px-8 py-28 md:py-40">
        <div className="flex flex-col items-start gap-8">
          <h2
            className="m-0 leading-tight"
            style={{
              fontFamily: "'IBM Plex Mono', ui-monospace, monospace",
              fontWeight: 400,
              fontSize: 'clamp(42px, 5vw, 72px)',
              color: '#ffffff',
              letterSpacing: '0.01em',
              textWrap: 'balance',
            } as React.CSSProperties}
          >
            Make your notch useful.
          </h2>

          <div className="flex items-center gap-3">
            <Button href={SITE.downloadUrl} size="xl" external>
              <span className="[&_svg]:size-4">
                <AppleIcon />
              </span>
              Download for Mac
            </Button>

            <a
              href={SITE.githubUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex items-center gap-2 no-underline rounded-full text-white/55 hover:text-white hover:bg-white/10"
              style={{
                fontFamily: "'IBM Plex Mono', ui-monospace, monospace",
                fontSize: 16,
                fontWeight: 500,
                letterSpacing: '-0.02em',
                height: 48,
                padding: '0 28px',
              }}
            >
              <span className="[&_svg]:size-4">
                <GitHubIcon />
              </span>
              View source
            </a>
          </div>
        </div>
      </div>
    </section>
  );
}
