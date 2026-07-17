import { type RefObject, useEffect, useRef, useState } from 'react';
import type { MotionValue } from 'framer-motion';
import {
  motion,
  useMotionValueEvent,
  useReducedMotion,
  useScroll,
  useTransform,
} from 'framer-motion';
import Button from './Button';
import { CurrentAppPreview } from './Features';

function AppleIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.8-.91.65.03 2.47.26 3.64 1.98l-.09.06c-.22.15-2.19 1.3-2.17 3.88.03 3.08 2.71 4.12 2.75 4.13-.05.13-.42 1.45-1.33 2.56M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 1.05-3.11z" />
    </svg>
  );
}

function MacOSLaptopPreview({
  previewRef,
  y,
  notchOpen,
}: {
  previewRef: RefObject<HTMLDivElement | null>;
  y: MotionValue<number>;
  notchOpen: boolean;
}) {
  return (
    <motion.div
      ref={previewRef}
      className="macos-ui relative mt-8 w-full overflow-hidden rounded-[16px] bg-[#080808] p-[6px] sm:mt-14 sm:rounded-[28px] sm:p-[10px]"
      style={{
        y,
        willChange: 'transform',
      }}
    >
      <div className="relative aspect-[16/9] overflow-hidden rounded-[13px] bg-[#151515] sm:rounded-[20px]">
        <img
          src="/macos-mojave.jpg"
          alt=""
          aria-hidden="true"
          className="absolute inset-0 h-full w-full object-cover"
        />
        <div className="absolute inset-x-0 top-0 h-[22px] bg-black/15 backdrop-blur-[2px] sm:h-[30px]" />
        <div className="absolute left-3 top-[5px] flex items-center gap-1.5 text-[5px] font-medium text-white/80 sm:left-5 sm:top-[7px] sm:gap-2 sm:text-[7px]">
          <AppleIcon />
          <span>Finder</span>
          <span className="hidden sm:inline">File</span>
          <span className="hidden sm:inline">Edit</span>
          <span className="hidden sm:inline">View</span>
        </div>
        <div className="absolute right-3 top-[6px] flex gap-1 text-[5px] text-white/70 sm:right-5 sm:top-[8px] sm:gap-2 sm:text-[7px]">
          <span>◉</span>
          <span>⌁</span>
          <span>100%</span>
        </div>

        <div className="absolute left-1/2 top-0 z-20 -translate-x-1/2">
          <div className="origin-top scale-[0.42] sm:scale-[0.55] lg:scale-[0.68] xl:scale-[0.82]">
            <CurrentAppPreview
              preview="home"
              withShadow={false}
              open={notchOpen}
              closeBetweenLoops={false}
            />
          </div>
        </div>
      </div>
    </motion.div>
  );
}

export default function Hero({ ready = true }: { ready?: boolean }) {
  const reduceMotion = useReducedMotion();
  const sectionRef = useRef<HTMLElement>(null);
  const laptopRef = useRef<HTMLDivElement>(null);
  const [laptopTravel, setLaptopTravel] = useState(0);
  const [notchOpen, setNotchOpen] = useState(true);
  const notchOpenRef = useRef(true);
  const { scrollYProgress: mediaScrollProgress } = useScroll({
    target: sectionRef,
    offset: ['start start', 'end start'],
  });
  const rawMediaY = useTransform(mediaScrollProgress, [0, 1], [0, 300]);
  const laptopY = useTransform(
    mediaScrollProgress,
    [0, 0.5],
    [0, Math.max(160, laptopTravel)],
  );

  useMotionValueEvent(mediaScrollProgress, 'change', (progress) => {
    const shouldBeOpen = progress < 0.25;
    if (shouldBeOpen === notchOpenRef.current) return;
    notchOpenRef.current = shouldBeOpen;
    setNotchOpen(shouldBeOpen);
  });

  useEffect(() => {
    const section = sectionRef.current;
    const laptop = laptopRef.current;
    if (!section || !laptop) return;

    const measure = () => {
      let top = 0;
      let node: HTMLElement | null = laptop;

      while (node && node !== section) {
        top += node.offsetTop;
        node = node.offsetParent as HTMLElement | null;
      }

      const travelPastHero = section.clientHeight - top + 48;
      setLaptopTravel(Math.max(0, travelPastHero));
    };

    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(section);
    observer.observe(laptop);
    window.addEventListener('resize', measure);

    return () => {
      observer.disconnect();
      window.removeEventListener('resize', measure);
    };
  }, []);

  return (
    <section
      ref={sectionRef}
      id="home"
      className="relative h-[680px] w-full overflow-hidden bg-[#111111] sm:h-[calc(100dvh+200px)] sm:min-h-[760px]"
    >
      <motion.div
        aria-hidden="true"
        className="absolute inset-0"
      initial={false}
      animate={{ opacity: ready ? 1 : 0.65 }}
      transition={reduceMotion ? { duration: 0 } : { duration: 0.7, ease: 'easeOut' }}
        style={{ y: rawMediaY, height: 'calc(100% + 300px)', willChange: 'transform' }}
      >
        <img
          src="/hero-image.jpg"
          alt=""
          aria-hidden="true"
          className="absolute inset-0 h-full w-full scale-150 object-cover object-center"
        />

        {/* Purple tint overlay */}
        <div
          aria-hidden="true"
          style={{
            position: 'absolute',
            inset: 0,
            background: 'rgba(107, 88, 228, 0)',
            mixBlendMode: 'overlay',
            pointerEvents: 'none',
          }}
        />

        {/* Bottom fade */}
        <div
          aria-hidden="true"
          style={{
            position: 'absolute',
            inset: '60% 0 0 0',
            background: 'linear-gradient(to bottom, transparent, rgba(0,0,0,0.3))',
            pointerEvents: 'none',
          }}
        />
      </motion.div>

      {/* Tagline — same container as navbar and all sections */}
      <div className="absolute inset-0 flex items-start pt-24 sm:pt-[clamp(96px,12vh,150px)]">
        <div className="mx-auto w-full max-w-[1280px] px-5 sm:px-8">
          <motion.h1
            initial={false}
            animate={{ opacity: ready ? 1 : 0, y: ready ? 0 : 24 }}
            transition={reduceMotion ? { duration: 0 } : { duration: 0.6, delay: 0.24, ease: [0.16, 1, 0.3, 1] }}
            style={{
              fontSize: 'clamp(36px, 8.5vw, 82px)',
              fontWeight: 400,
              color: '#ffffff',
              lineHeight: 1.05,
              letterSpacing: '0.01em',
              margin: 0,
            }}
          >
            Perch lives
            <br />
            in your notch.
          </motion.h1>

          {/* Download CTA */}
          <motion.div
            className="mt-8 sm:mt-16"
            initial={false}
            animate={{ opacity: ready ? 1 : 0, y: ready ? 0 : 18 }}
            transition={reduceMotion ? { duration: 0 } : { duration: 0.55, delay: 0.36, ease: [0.16, 1, 0.3, 1] }}
          >
            <Button href="#download" size="xl">
              <span className="[&_svg]:size-4">
                <AppleIcon />
              </span>
              Get Perch For Mac
            </Button>
          </motion.div>

          <motion.div
            initial={false}
            animate={{ opacity: ready ? 1 : 0, y: ready ? 0 : 28 }}
            transition={reduceMotion ? { duration: 0 } : { duration: 0.7, delay: 0.5, ease: [0.16, 1, 0.3, 1] }}
          >
            <MacOSLaptopPreview
              previewRef={laptopRef}
              y={laptopY}
              notchOpen={notchOpen}
            />
          </motion.div>
        </div>
      </div>

      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-x-0 bottom-0 z-40 h-[120px] sm:bottom-auto sm:top-[100dvh] sm:h-[200px]"
        style={{
          background:
            'linear-gradient(to bottom, rgba(255,255,255,0) 0%, rgba(255,255,255,0.16) 24%, rgba(255,255,255,0.78) 72%, #ffffff 100%)',
        }}
      />
    </section>
  );
}
