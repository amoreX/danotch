const FOOTER_SURFACE = '#111111';
const FOOTER_BAR_HEIGHT = 112;
const FOOTER_SHOULDER_SIZE = 34;
const FOOTER_RAIL_SHOULDER_SIZE = 8;
const SIDE_BAR_WIDTH = 10;
const CONTAINER_ALIGN = 'calc(max(0px, (100vw - 1280px) / 2) + 32px)';

function FooterShoulder() {
  const size = FOOTER_SHOULDER_SIZE;
  const controlNear = Number((size * 0.447).toFixed(2));
  const controlFar = Number((size - controlNear).toFixed(2));

  return (
    <svg
      aria-hidden="true"
      className="absolute pointer-events-none"
      viewBox={`0 0 ${size} ${size}`}
      style={{
        right: -size,
        bottom: -1,
        width: size,
        height: size,
        display: 'block',
        zIndex: 2,
      }}
    >
      <path
        d={`M${size} ${size}H0V0C0 ${controlFar} ${controlNear} ${size} ${size} ${size}Z`}
        fill={FOOTER_SURFACE}
      />
    </svg>
  );
}

function FooterRailShoulder({ side }: { side: 'left' | 'right' }) {
  const size = FOOTER_RAIL_SHOULDER_SIZE;
  const controlNear = Number((size * 0.447).toFixed(2));
  const controlFar = Number((size - controlNear).toFixed(2));
  const path =
    side === 'left'
      ? `M0 0H${size}V${size}C${size} ${controlNear} ${controlFar} 0 0 0Z`
      : `M${size} 0H0V${size}C0 ${controlNear} ${controlNear} 0 ${size} 0Z`;

  return (
    <svg
      aria-hidden="true"
      className="absolute pointer-events-none"
      viewBox={`0 0 ${size} ${size}`}
      style={{
        [side]: SIDE_BAR_WIDTH,
        top: -size,
        width: size,
        height: size,
        display: 'block',
        transform: side === 'left' ? 'rotate(180deg)' : 'rotate(-180deg)',
        transformOrigin: 'center',
        zIndex: 2,
      }}
    >
      <path d={path} fill={FOOTER_SURFACE} />
    </svg>
  );
}

export default function Footer() {
  return (
    <footer id="contact" className="bg-white pt-12 md:pt-20">
      <div className="mx-1 rounded-t-[28px] bg-[#111111] px-5 pb-8 pt-10 md:hidden">
        <p className="m-0 text-[clamp(52px,18vw,84px)] leading-none text-white">Perch</p>
        <div className="mt-12 border-t border-white/10 pt-6">
          <a
            href="https://www.unordinary.software/"
            target="_blank"
            rel="noopener noreferrer"
            className="text-xs text-white/70 no-underline hover:text-white"
          >
            Contact us
          </a>
        </div>
      </div>

      <div className="relative hidden h-[clamp(300px,34vw,440px)] overflow-visible md:block">
        <div
          className="absolute inset-x-0 bottom-0"
          style={{ height: FOOTER_BAR_HEIGHT, background: FOOTER_SURFACE }}
        >
          <FooterRailShoulder side="right" />
        </div>

        <div
          className="absolute left-0 flex items-center"
          style={{
            bottom: FOOTER_BAR_HEIGHT,
            height: 'clamp(168px, 19vw, 272px)',
            paddingLeft: CONTAINER_ALIGN,
            paddingRight: '48px',
            paddingTop: 'clamp(32px, 3vw, 52px)',
            paddingBottom: 'clamp(32px, 3vw, 52px)',
            background: FOOTER_SURFACE,
            borderTopRightRadius: 44,
            zIndex: 1,
            boxSizing: 'border-box',
          }}
        >
          <FooterRailShoulder side="left" />
          <FooterShoulder />
          <p
            className="m-0 text-white leading-none select-none"
            style={{
              fontFamily: "'IBM Plex Mono', ui-monospace, monospace",
              fontWeight: 400,
              fontSize: 'clamp(64px, 13vw, 190px)',
              letterSpacing: '0.01em',
            }}
          >
            Perch
          </p>
        </div>

        <div
          className="absolute inset-x-0 bottom-0 flex flex-col gap-4 px-8 py-8 sm:flex-row sm:items-center sm:justify-between"
          style={{
            minHeight: FOOTER_BAR_HEIGHT,
            paddingLeft: CONTAINER_ALIGN,
            paddingRight: CONTAINER_ALIGN,
          }}
        >
          <a
            href="https://www.unordinary.software/"
            target="_blank"
            rel="noopener noreferrer"
            className="text-white/70 no-underline transition-colors hover:text-white"
            style={{ fontFamily: "'IBM Plex Mono', ui-monospace, monospace", fontSize: 13, lineHeight: 1.7, letterSpacing: '-0.02em' }}
          >
            Contact us
          </a>
        </div>
      </div>
    </footer>
  );
}
