import { motion, AnimatePresence } from 'framer-motion';
import { ArrowDown, ExternalLink, ArrowRight } from 'lucide-react';
import { FEATURES } from '../components/Features';
import { useRef, useState, useEffect } from 'react';
import NotchDemo, { type ViewState } from '../components/NotchDemo';

// V7: Split Layout — Fixed black left panel, scrollable white right, red accent
export default function V7Split() {
  const accent = '#E53935';
  const rightRef = useRef<HTMLDivElement>(null);
  const notchSectionRef = useRef<HTMLDivElement>(null);
  const [notchScrolledPast, setNotchScrolledPast] = useState(false);
  const [currentFeature, setCurrentFeature] = useState(0);

  // Scroll to top on mount
  useEffect(() => {
    window.scrollTo(0, 0);
    if (rightRef.current) rightRef.current.scrollTop = 0;
  }, []);

  // Per-feature demo config: view, sequence ID, duration
  const FEATURE_DEMOS: { view: ViewState; sequence?: string; duration: number }[] = [
    { view: 'agents',        duration: 4000 },                              // AI Agent Monitor
    { view: 'chat',          sequence: 'code-exec',    duration: 7000 },    // Local Code Execution
    { view: 'chat',          sequence: 'web-search',   duration: 7000 },    // Web Search
    { view: 'overview',      sequence: 'scheduled',    duration: 4000 },    // Scheduled Tasks
    { view: 'overview',      sequence: 'notif-peek',   duration: 7000 },    // Smart Notifications
    { view: 'overview',      sequence: 'pin-utils',    duration: 8000 },    // Pinnable Utils
  ];

  // Detect when the notch demo section scrolls out of view
  useEffect(() => {
    const observer = new IntersectionObserver(
      ([entry]) => setNotchScrolledPast(!entry.isIntersecting),
      { threshold: 0.1 }
    );
    if (notchSectionRef.current) observer.observe(notchSectionRef.current);
    return () => observer.disconnect();
  }, []);

  // Cycle through features with variable durations
  useEffect(() => {
    if (!notchScrolledPast) return;
    const timeout = setTimeout(() => {
      setCurrentFeature(prev => (prev + 1) % FEATURES.length);
    }, FEATURE_DEMOS[currentFeature]?.duration ?? 4000);
    return () => clearTimeout(timeout);
  }, [notchScrolledPast, currentFeature]);

  return (
    <div className="min-h-screen flex">
      {/* Left Panel — Fixed */}
      <div className="hidden lg:flex w-[45vw] max-w-[580px] bg-black text-white fixed inset-y-0 left-0 flex-col justify-between p-10 z-20 overflow-hidden">
        {/* Geometric shapes */}
        <div className="absolute top-0 right-0 w-[300px] h-[300px] opacity-[0.03]" style={{ background: accent }} />
        <div className="absolute bottom-20 left-10 w-24 h-24 border-2 rotate-45 opacity-10" style={{ borderColor: accent }} />
        <div className="absolute top-1/3 right-16 w-3 h-3 rounded-full opacity-20" style={{ background: accent }} />

        {/* Nav + headline row */}
        <div className="shrink-0">
          <div className="flex items-start gap-12">
            {/* Left: logo + nav links */}
            <div className="shrink-0">
              <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ duration: 0.5 }}>
                <span className="font-mono text-sm tracking-[0.3em] text-white/70">DANOTCH</span>
              </motion.div>

              <nav className="mt-6 space-y-3">
                {['Features', 'How it Works', 'Download'].map((item, i) => (
                  <motion.a
                    key={item}
                    href={`#${item.toLowerCase().replace(/\s+/g, '-')}`}
                    initial={{ opacity: 0, x: -20 }}
                    animate={{ opacity: 1, x: 0 }}
                    transition={{ delay: 0.2 + i * 0.1 }}
                    className="block text-sm text-white/30 hover:text-white transition-colors tracking-wide"
                  >
                    {item}
                  </motion.a>
                ))}
              </nav>
            </div>

            {/* Right: headline (visible when scrolled past notch) */}
            <AnimatePresence>
              {notchScrolledPast && (
                <motion.div
                  initial={{ opacity: 0, x: 10 }}
                  animate={{ opacity: 1, x: 0 }}
                  exit={{ opacity: 0, x: 10 }}
                  transition={{ duration: 0.3 }}
                  className="flex-1"
                >
                  <div className="w-10 h-[3px] mb-3" style={{ background: accent }} />
                  <h2 className="text-3xl xl:text-4xl font-extrabold tracking-tight leading-[1.1]">
                    The notch<br />
                    is now a<br />
                    <span style={{ color: accent }}>command<br />center.</span>
                  </h2>
                </motion.div>
              )}
            </AnimatePresence>
          </div>
        </div>

        {/* Main content area — transitions between headline and notch demo */}
        <div className="my-auto py-6 relative">
          <AnimatePresence mode="wait">
            {!notchScrolledPast ? (
              /* Initial state: Full headline */
              <motion.div
                key="headline"
                initial={{ opacity: 0, y: 30 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, y: -20 }}
                transition={{ duration: 0.4 }}
              >
                <div className="w-12 h-1 mb-8" style={{ background: accent }} />
                <h1 className="text-5xl xl:text-6xl font-bold leading-[1.05] tracking-tight mb-6">
                  The notch<br />
                  is now a<br />
                  <span style={{ color: accent }}>command<br />center.</span>
                </h1>
                <p className="text-white/35 text-base leading-relaxed max-w-sm mb-10">
                  AI agents, Claude chat, scheduled tasks, system stats, music, calendar — all from your MacBook notch.
                </p>

                <div className="flex items-center gap-5">
                  <a
                    href="#"
                    className="inline-flex items-center gap-2 px-7 py-3 text-sm font-semibold text-white transition-all duration-300 hover:brightness-110"
                    style={{ background: accent }}
                  >
                    <ArrowDown className="w-4 h-4" /> Download
                  </a>
                  <a href="#" className="flex items-center gap-2 text-white/30 hover:text-white/60 text-sm transition-colors">
                    <ExternalLink className="w-4 h-4" /> Source
                  </a>
                </div>
              </motion.div>
            ) : (
              /* Scrolled state: feature showcase + notch demo */
              <motion.div
                key="notch-sticky"
                initial={{ opacity: 0, y: 20 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, y: 20 }}
                transition={{ duration: 0.4 }}
                className="flex flex-col"
              >
                {/* Cycling feature card */}
                <div className="mb-3">
                  <div className="h-[62px] relative overflow-hidden">
                    <AnimatePresence mode="wait">
                      <motion.div
                        key={currentFeature}
                        initial={{ opacity: 0, y: 10 }}
                        animate={{ opacity: 1, y: 0 }}
                        exit={{ opacity: 0, y: -10 }}
                        transition={{ duration: 0.3 }}
                        className="flex items-start gap-3 absolute inset-0"
                      >
                        {(() => {
                          const Icon = FEATURES[currentFeature].icon;
                          return (
                            <>
                              <div className="w-9 h-9 rounded-lg flex items-center justify-center shrink-0 mt-0.5" style={{ background: `${accent}15` }}>
                                <Icon className="w-4 h-4" style={{ color: accent }} />
                              </div>
                              <div className="flex-1 min-w-0">
                                <h3 className="text-sm font-semibold text-white tracking-tight">{FEATURES[currentFeature].title}</h3>
                                <p className="text-xs text-white/35 leading-relaxed mt-0.5 line-clamp-2">{FEATURES[currentFeature].description}</p>
                              </div>
                            </>
                          );
                        })()}
                      </motion.div>
                    </AnimatePresence>
                  </div>

                  {/* Feature dots */}
                  <div className="flex gap-1 mt-2">
                    {FEATURES.map((_, i) => (
                      <div key={i} className="h-[3px] rounded-full transition-all duration-300" style={{ width: i === currentFeature ? 20 : 6, backgroundColor: i === currentFeature ? accent : 'rgba(255,255,255,0.12)' }} />
                    ))}
                  </div>
                </div>

                {/* Notch demo */}
                <div className="w-full flex justify-center">
                  <div className="rounded-xl overflow-hidden pb-2 flex justify-center w-full" style={{ background: '#0a0a0a', boxShadow: '0 20px 60px rgba(0,0,0,0.5)' }}>
                    <NotchDemo autoPlay={false} startExpanded compact forceView={FEATURE_DEMOS[currentFeature]?.view} forceSequence={FEATURE_DEMOS[currentFeature]?.sequence} />
                  </div>
                </div>

                {/* Download link */}
                <div className="flex items-center gap-5 mt-4 w-full">
                  <a href="#" className="inline-flex items-center gap-2 px-6 py-2.5 text-sm font-semibold text-white transition-all duration-300 hover:brightness-110" style={{ background: accent }}>
                    <ArrowDown className="w-4 h-4" /> Download
                  </a>
                  <a href="#" className="flex items-center gap-2 text-white/30 hover:text-white/60 text-sm transition-colors">
                    <ExternalLink className="w-4 h-4" /> Source
                  </a>
                </div>
              </motion.div>
            )}
          </AnimatePresence>
        </div>

        {/* Footer on left panel */}
        <div className="shrink-0">
          <p className="text-xs text-white/15 font-mono tracking-wider">macOS 14+ &middot; ARM64 & x86</p>
        </div>
      </div>

      {/* Mobile top bar (visible on small screens) */}
      <div className="lg:hidden fixed top-0 inset-x-0 z-50 bg-black text-white px-6 h-14 flex items-center justify-between">
        <span className="font-mono text-sm tracking-[0.3em] text-white/70">DANOTCH</span>
        <a
          href="#"
          className="text-xs font-semibold px-4 py-1.5 text-white"
          style={{ background: accent }}
        >
          DOWNLOAD
        </a>
      </div>

      {/* Right Panel — Scrollable */}
      <div
        ref={rightRef}
        className="flex-1 lg:ml-[45vw] lg:max-w-none bg-white min-h-screen"
      >
        {/* Mobile hero */}
        <section className="lg:hidden bg-black text-white pt-20 pb-16 px-6 text-center">
          <div className="w-10 h-1 mx-auto mb-6" style={{ background: accent }} />
          <h1 className="text-4xl font-bold leading-tight mb-4 tracking-tight">
            The notch is now a{' '}
            <span style={{ color: accent }}>command center.</span>
          </h1>
          <p className="text-white/40 text-sm mb-8 max-w-md mx-auto">
            AI agents, Claude chat, scheduled tasks, system stats, music, calendar.
          </p>
          <a
            href="#"
            className="inline-flex items-center gap-2 px-6 py-3 text-sm font-semibold text-white"
            style={{ background: accent }}
          >
            <ArrowDown className="w-4 h-4" /> Download
          </a>
        </section>

        {/* Interactive Notch Demo (right panel — scrolls away, then appears on left) */}
        <section ref={notchSectionRef} className="pt-16 lg:pt-24 pb-20 px-8 lg:px-16">
          <motion.div
            initial={{ opacity: 0, y: 40 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.7, delay: 0.4 }}
            className="max-w-2xl"
          >
            <div
              className="rounded-2xl overflow-hidden pt-0 pb-5 flex justify-center relative"
              style={{ background: '#0a0a0a', boxShadow: '0 30px 80px rgba(0,0,0,0.2)' }}
            >
              {/* Animated gradient blobs */}
              <motion.div
                className="absolute pointer-events-none rounded-full blur-[50px]"
                style={{ width: '55%', height: '55%', background: 'rgba(229,57,53,0.35)' }}
                animate={{ top: ['5%', '45%', '15%', '5%'], left: ['5%', '50%', '25%', '5%'] }}
                transition={{ duration: 8, repeat: Infinity, ease: 'easeInOut' }}
              />
              <motion.div
                className="absolute pointer-events-none rounded-full blur-[50px]"
                style={{ width: '50%', height: '50%', background: 'rgba(217,119,87,0.25)' }}
                animate={{ top: ['55%', '5%', '35%', '55%'], left: ['45%', '15%', '65%', '45%'] }}
                transition={{ duration: 10, repeat: Infinity, ease: 'easeInOut' }}
              />
              <motion.div
                className="absolute pointer-events-none rounded-full blur-[40px]"
                style={{ width: '40%', height: '40%', background: 'rgba(212,168,67,0.18)' }}
                animate={{ top: ['25%', '55%', '5%', '25%'], left: ['65%', '5%', '45%', '65%'] }}
                transition={{ duration: 12, repeat: Infinity, ease: 'easeInOut' }}
              />
              <div className="relative z-10">
                <NotchDemo />
              </div>
            </div>
          </motion.div>
        </section>

        {/* Features — horizontal rows */}
        <section id="features" className="px-8 lg:px-16 pb-20">
          <motion.div
            initial={{ opacity: 0 }}
            whileInView={{ opacity: 1 }}
            viewport={{ once: true }}
            className="mb-12"
          >
            <div className="w-8 h-1 mb-4" style={{ background: accent }} />
            <h2 className="text-3xl font-bold tracking-tight text-black">Features</h2>
          </motion.div>

          <div className="space-y-0 border-t border-black/10">
            {FEATURES.map((f, i) => {
              const Icon = f.icon;
              return (
                <motion.div
                  key={f.title}
                  initial={{ opacity: 0, x: 30 }}
                  whileInView={{ opacity: 1, x: 0 }}
                  viewport={{ once: true }}
                  transition={{ delay: i * 0.06, duration: 0.4 }}
                  className="group flex items-start gap-6 py-7 border-b border-black/8 cursor-pointer transition-colors hover:bg-black/[0.02] px-4 -mx-4"
                >
                  <div
                    className="w-11 h-11 rounded-none flex items-center justify-center shrink-0 transition-colors duration-300 group-hover:scale-105"
                    style={{ background: `${accent}10` }}
                  >
                    <Icon className="w-5 h-5 text-black/50 group-hover:text-[#E53935] transition-colors" />
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center justify-between gap-4">
                      <h3 className="text-base font-semibold text-black tracking-tight">{f.title}</h3>
                      <ArrowRight className="w-4 h-4 text-black/15 group-hover:text-[#E53935] transition-all duration-300 group-hover:translate-x-1 shrink-0" />
                    </div>
                    <p className="text-sm text-black/40 leading-relaxed mt-1">{f.description}</p>
                  </div>
                </motion.div>
              );
            })}
          </div>
        </section>

        {/* How it works */}
        <section id="how-it-works" className="px-8 lg:px-16 py-20 bg-black/[0.02]">
          <div className="max-w-2xl">
            <div className="w-8 h-1 mb-4" style={{ background: accent }} />
            <h2 className="text-3xl font-bold tracking-tight text-black mb-12">How it Works</h2>

            <div className="space-y-8">
              {[
                { num: '01', title: 'Install', desc: 'Download and launch. Lives in the menu bar, no dock icon.' },
                { num: '02', title: 'Hover', desc: 'Move your cursor to the notch. It smoothly expands.' },
                { num: '03', title: 'Command', desc: 'Chat, monitor, schedule, browse stats. All right there.' },
              ].map((item, i) => (
                <motion.div
                  key={item.num}
                  initial={{ opacity: 0, y: 15 }}
                  whileInView={{ opacity: 1, y: 0 }}
                  viewport={{ once: true }}
                  transition={{ delay: i * 0.1 }}
                  className="flex items-start gap-6"
                >
                  <span className="text-4xl font-bold shrink-0" style={{ color: `${accent}25` }}>{item.num}</span>
                  <div>
                    <h3 className="text-lg font-bold text-black mb-1">{item.title}</h3>
                    <p className="text-black/40 leading-relaxed">{item.desc}</p>
                  </div>
                </motion.div>
              ))}
            </div>
          </div>
        </section>

        {/* CTA */}
        <section id="download" className="px-8 lg:px-16 py-24">
          <motion.div
            initial={{ opacity: 0 }}
            whileInView={{ opacity: 1 }}
            viewport={{ once: true }}
            className="max-w-xl"
          >
            <div className="w-8 h-1 mb-6" style={{ background: accent }} />
            <h2 className="text-4xl font-bold tracking-tight text-black mb-3 leading-tight">
              Ready to make<br />your notch useful?
            </h2>
            <p className="text-black/35 mb-8">Free, open source, macOS 14 or later.</p>
            <div className="flex items-center gap-5">
              <a
                href="#"
                className="inline-flex items-center gap-2 px-8 py-3.5 text-sm font-semibold text-white transition-all duration-300 hover:brightness-110"
                style={{ background: accent }}
              >
                <ArrowDown className="w-4 h-4" /> Download for Mac
              </a>
              <a href="#" className="flex items-center gap-2 text-black/25 hover:text-black/50 text-sm transition-colors">
                <ExternalLink className="w-4 h-4" /> Source
              </a>
            </div>
          </motion.div>
        </section>

        {/* Footer */}
        <footer className="px-8 lg:px-16 py-8 border-t border-black/5">
          <div className="flex items-center justify-between">
            <span className="font-mono text-xs text-black/20 tracking-wider">DANOTCH</span>
            <span className="text-xs text-black/15">Built for the notch.</span>
          </div>
        </footer>
      </div>
    </div>
  );
}
