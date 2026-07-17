import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { motion, useReducedMotion } from 'framer-motion';
import Button from './Button';

const NAV_SECTIONS = [
  { id: 'home', label: 'Home', href: '#home' },
  { id: 'features', label: 'Features', href: '#features' },
  { id: 'download', label: 'Download', href: '#download' },
  { id: 'contact', label: 'Contact', href: '#contact' },
];

function AppleIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.8-.91.65.03 2.47.26 3.64 1.98l-.09.06c-.22.15-2.19 1.3-2.17 3.88.03 3.08 2.71 4.12 2.75 4.13-.05.13-.42 1.45-1.33 2.56M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 1.05-3.11z" />
    </svg>
  );
}

export function PerchLogo({ className = 'h-7 w-7' }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 48 46"
      aria-hidden="true"
      className={`${className} text-[#211B58]`}
    >
      <path
        d="M25.946 44.938c-.664.845-2.021.375-2.021-.698V33.937a2.26 2.26 0 0 0-2.262-2.262H10.287c-.92 0-1.456-1.04-.92-1.788l7.48-10.471c1.07-1.497 0-3.578-1.842-3.578H1.237c-.92 0-1.456-1.04-.92-1.788L10.013.474c.214-.297.556-.474.92-.474h28.894c.92 0 1.456 1.04.92 1.788l-7.48 10.471c-1.07 1.498 0 3.579 1.842 3.579h11.377c.943 0 1.473 1.088.89 1.83L25.947 44.94z"
        fill="currentColor"
      />
    </svg>
  );
}

const NOTCH = '#111111';
const BAR_HEIGHT = 10;
const SIDE_BAR_WIDTH = 10;
const SHOULDER_SIZE = 8;
const MIDDLE_SHOULDER_OVERLAP = 0.5;
const CENTER_NOTCH_HEIGHT = 56;
const CENTER_NOTCH_PADDING_X = 8;
const CENTER_SECTION_FALLBACK_WIDTH = 86;
const CENTER_INDICATOR_HEIGHT = 40;
const NOTCH_SPRING = { type: 'spring' as const, stiffness: 420, damping: 32 };

// Aligns content with max-w-[1280px] mx-auto px-8 container at any viewport width.
// On narrow viewports the container is full-width so offset = 0 + 32px.
// On wide viewports it's (vw - 1280px) / 2 + 32px.
const CONTAINER_ALIGN = 'calc(max(0px, (100vw - 1280px) / 2) + 32px)';

function NotchCornerShoulder({
  side,
  overlap = 0,
  size = SHOULDER_SIZE,
}: {
  side: 'left' | 'right';
  overlap?: number;
  size?: number;
}) {
  const anchor = side === 'left' ? 'right' : 'left';
  const controlNear = Number((size * 0.447).toFixed(2));
  const controlFar = Number((size - controlNear).toFixed(2));
  const path =
    side === 'left'
      ? `M0 0H${size}V${size}C${size} ${controlNear} ${controlFar} 0 0 0Z`
      : `M${size} 0H0V${size}C0 ${controlNear} ${controlNear} 0 ${size} 0Z`;

  return (
    <motion.svg
      aria-hidden="true"
      className="absolute pointer-events-none"
      viewBox={`0 0 ${size} ${size}`}
      initial={false}
      animate={{ width: size, height: size }}
      transition={NOTCH_SPRING}
      style={{
        top: BAR_HEIGHT,
        [anchor]: overlap ? `calc(100% - ${overlap}px)` : '100%',
        display: 'block',
      }}
    >
      <path d={path} fill={NOTCH} />
    </motion.svg>
  );
}

function NavbarFrameShoulder({ side }: { side: 'left' | 'right' }) {
  const size = SHOULDER_SIZE;
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
        top: BAR_HEIGHT,
        [side]: SIDE_BAR_WIDTH,
        width: size,
        height: size,
        display: 'block',
      }}
    >
      <path d={path} fill={NOTCH} />
    </svg>
  );
}

function NotchRailShoulder({ side }: { side: 'left' | 'right' }) {
  const size = SHOULDER_SIZE;
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
        top: 56,
        width: size,
        height: size,
        display: 'block',
        transform: side === 'left' ? 'rotate(-90deg)' : 'rotate(90deg)',
        transformOrigin: 'center',
      }}
    >
      <path d={path} fill={NOTCH} />
    </svg>
  );
}

export default function Navbar({ ready = true }: { ready?: boolean }) {
  const reduceMotion = useReducedMotion();
  const [activeSection, setActiveSection] = useState(NAV_SECTIONS[0].id);
  const sectionRefs = useRef<Array<HTMLAnchorElement | null>>([]);
  const scrollLockRef = useRef<string | null>(null);
  const scrollSettleTimerRef = useRef<number | null>(null);
  const [sectionWidths, setSectionWidths] = useState<number[]>(
    NAV_SECTIONS.map(() => CENTER_SECTION_FALLBACK_WIDTH),
  );
  const activeIndex = Math.max(
    NAV_SECTIONS.findIndex((section) => section.id === activeSection),
    0,
  );
  const activeSectionWidth = sectionWidths[activeIndex] ?? CENTER_SECTION_FALLBACK_WIDTH;
  const activeSectionOffset = sectionWidths
    .slice(0, activeIndex)
    .reduce((total, width) => total + width, 0);
  const sectionRowWidth = sectionWidths.reduce((total, width) => total + width, 0);

  useLayoutEffect(() => {
    const measureSectionWidths = () => {
      setSectionWidths((currentWidths) =>
        NAV_SECTIONS.map((_, index) => {
          const width = sectionRefs.current[index]?.getBoundingClientRect().width;
          return width ? Math.ceil(width) : currentWidths[index] ?? CENTER_SECTION_FALLBACK_WIDTH;
        }),
      );
    };

    measureSectionWidths();
    const resizeObserver = new ResizeObserver(measureSectionWidths);

    sectionRefs.current.forEach((element) => {
      if (element) resizeObserver.observe(element);
    });

    window.addEventListener('resize', measureSectionWidths);

    return () => {
      resizeObserver.disconnect();
      window.removeEventListener('resize', measureSectionWidths);
    };
  }, []);

  useEffect(() => {
    const visibility = new Map<string, number>();
    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          visibility.set(entry.target.id, entry.isIntersecting ? entry.intersectionRatio : 0);
        });
        if (scrollLockRef.current) return;

        const nextSection = NAV_SECTIONS.reduce((best, section) => {
          return (visibility.get(section.id) ?? 0) > (visibility.get(best.id) ?? 0) ? section : best;
        }, NAV_SECTIONS[0]);
        setActiveSection((current) => current === nextSection.id ? current : nextSection.id);
      },
      {
        rootMargin: '-12% 0px -12% 0px',
        threshold: [0, 0.15, 0.3, 0.45, 0.6, 0.75, 0.9],
      },
    );

    NAV_SECTIONS.forEach((section) => {
      const element = document.getElementById(section.id);
      if (element) observer.observe(element);
    });

    return () => {
      if (scrollSettleTimerRef.current) window.clearTimeout(scrollSettleTimerRef.current);
      observer.disconnect();
    };
  }, []);

  const handleSectionClick = (event: React.MouseEvent<HTMLAnchorElement>, sectionId: string) => {
    scrollLockRef.current = sectionId;
    if (scrollSettleTimerRef.current) window.clearTimeout(scrollSettleTimerRef.current);
    setActiveSection(sectionId);

    const section = document.getElementById(sectionId);
    if (!section) return;

    event.preventDefault();
    const sectionTop = section.getBoundingClientRect().top + window.scrollY;
    const targetY = sectionTop - (window.innerHeight - section.offsetHeight) / 2;
    window.scrollTo({ top: Math.max(targetY, 0), behavior: 'smooth' });
    scrollSettleTimerRef.current = window.setTimeout(() => {
      scrollLockRef.current = null;
    }, 750);
  };

  return (
    <motion.header
      className="fixed top-0 left-0 right-0 z-50 pointer-events-none"
      initial={false}
      animate={{ opacity: ready ? 1 : 0, y: ready ? 0 : -18 }}
      transition={reduceMotion ? { duration: 0 } : { duration: 0.5, delay: 0.12, ease: [0.16, 1, 0.3, 1] }}
    >
      <div className="pointer-events-auto mx-3 flex h-14 items-center gap-2 rounded-b-[20px] bg-[#111111] px-2.5 md:hidden">
        <a
          href="#home"
          aria-label="Perch home"
          className="flex h-9 w-11 shrink-0 items-center justify-center rounded-full bg-white text-lg font-bold italic no-underline"
        >
          <PerchLogo />
        </a>
        <nav className="flex min-w-0 flex-1 items-center justify-center gap-1" aria-label="Mobile navigation">
          <a href="#features" className="rounded-full px-3 py-2 text-xs text-white/65 no-underline">
            Features
          </a>
          <a href="#download" className="rounded-full px-3 py-2 text-xs text-white/65 no-underline">
            Download
          </a>
        </nav>
        <a
          href="#download"
          aria-label="Download Perch"
          className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-[#7b6af0] text-white no-underline"
        >
          <AppleIcon />
        </a>
      </div>

      <div className="hidden md:block">
      {/* Full-width connecting bar */}
      <div className="absolute top-0 left-0 right-0 h-[10px] bg-[#111111] pointer-events-auto" />
      <NavbarFrameShoulder side="left" />
      <NavbarFrameShoulder side="right" />

      {/* Left notch — bleeds to screen left edge, only bottom-right rounded */}
      <div
        className="absolute top-0 left-0 flex items-center h-14 pointer-events-auto"
        style={{
          background: NOTCH,
          borderRadius: '0 0 28px 0',
          paddingLeft: CONTAINER_ALIGN,
          paddingRight: '8px',
        }}
      >
        <NotchCornerShoulder side="right" />
        <NotchRailShoulder side="left" />
        <a
          href="/"
          className="h-10 w-[88px] inline-flex items-center justify-center rounded-full bg-white no-underline"
          style={{
            background: '#ffffff',
          }}
        >
          <PerchLogo />
        </a>
      </div>

      {/* Center notch — equal 8px pad (matches h-10 buttons' 8px vertical breathing room) */}
      <motion.div
        className="absolute left-1/2 top-0 flex items-center pointer-events-auto overflow-visible"
        initial={false}
        style={{ x: '-50%', background: NOTCH, borderRadius: '0 0 28px 28px' }}
        animate={{
          width: sectionRowWidth + CENTER_NOTCH_PADDING_X * 2,
          height: CENTER_NOTCH_HEIGHT,
          paddingLeft: CENTER_NOTCH_PADDING_X,
          paddingRight: CENTER_NOTCH_PADDING_X,
        }}
        transition={NOTCH_SPRING}
      >
        <NotchCornerShoulder side="left" overlap={MIDDLE_SHOULDER_OVERLAP} />
        <NotchCornerShoulder side="right" overlap={MIDDLE_SHOULDER_OVERLAP} />
        <motion.div
          aria-hidden="true"
          className="absolute rounded-full"
          initial={false}
          animate={{
            left: CENTER_NOTCH_PADDING_X + activeSectionOffset,
            width: activeSectionWidth,
          }}
          transition={NOTCH_SPRING}
          style={{
            top: (CENTER_NOTCH_HEIGHT - CENTER_INDICATOR_HEIGHT) / 2,
            height: CENTER_INDICATOR_HEIGHT,
            background: 'rgba(255,255,255,0.1)',
          }}
        />
        <motion.div
          className="relative z-10 overflow-hidden"
          initial={false}
          animate={{ width: sectionRowWidth }}
          transition={NOTCH_SPRING}
          style={{ height: CENTER_INDICATOR_HEIGHT }}
        >
          <motion.div
            className="flex h-full"
            initial={false}
            animate={{ x: 0 }}
            transition={NOTCH_SPRING}
            style={{ width: sectionRowWidth }}
          >
            {NAV_SECTIONS.map((section, index) => (
              <a
                key={section.id}
                ref={(element) => {
                  sectionRefs.current[index] = element;
                }}
                href={section.href}
                onClick={(event) => handleSectionClick(event, section.id)}
                className={`h-10 px-3.5 flex shrink-0 items-center justify-center rounded-full text-sm no-underline text-white/65 ${
                  index === activeIndex ? '' : 'hover:text-white/90'
                }`}
                style={{
                  letterSpacing: '-0.02em',
                  fontFamily: "'IBM Plex Mono', ui-monospace, monospace",
                }}
              >
                {section.label}
              </a>
            ))}
          </motion.div>
        </motion.div>
      </motion.div>

      {/* Right notch — bleeds to screen right edge, only bottom-left rounded */}
      <div
        className="absolute top-0 right-0 flex items-center gap-2 h-14 pointer-events-auto"
        style={{
          background: NOTCH,
          borderRadius: '0 0 0 28px',
          paddingRight: CONTAINER_ALIGN,
          paddingLeft: '8px',
        }}
      >
        <NotchCornerShoulder side="left" />
        <NotchRailShoulder side="right" />
        <Button href="#download" size="lg">
          <AppleIcon />
          Download
        </Button>
        <a
          href="#contact"
          aria-label="Contact"
          className="h-10 w-10 inline-flex items-center justify-center rounded-full bg-white/10 text-white no-underline transition-colors hover:bg-white/15"
          style={{
            fontFamily: "'IBM Plex Mono', ui-monospace, monospace",
            fontSize: 15,
            fontWeight: 600,
            lineHeight: 1,
          }}
        >
          ?
        </a>
      </div>
      </div>
    </motion.header>
  );
}
