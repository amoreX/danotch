import Button from './Button';
import { SITE } from './site-config';

function AppleIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.8-.91.65.03 2.47.26 3.64 1.98l-.09.06c-.22.15-2.19 1.3-2.17 3.88.03 3.08 2.71 4.12 2.75 4.13-.05.13-.42 1.45-1.33 2.56M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 1.05-3.11z" />
    </svg>
  );
}

export default function Download() {
  return (
    <section id="download" className="relative overflow-hidden border-t border-zinc-100 bg-[#111111]">
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

      <div className="relative mx-auto max-w-[1280px] px-5 py-20 sm:px-8 md:py-32">
        <div className="max-w-3xl">
          <h2 className="m-0 font-mono text-[clamp(34px,8vw,72px)] font-normal leading-tight tracking-[0.01em] text-white">
            Make your notch useful.
          </h2>

          <div className="mt-8 flex flex-col items-start gap-3">
            <Button href={SITE.repositoryUrl} size="xl" external className="w-full sm:w-auto">
              <AppleIcon />
              Download on your Mac
            </Button>
            <p className="m-0 text-sm text-white/65">
              Everything runs locally on your Mac. Install with one command.
            </p>
          </div>
        </div>
      </div>
    </section>
  );
}
