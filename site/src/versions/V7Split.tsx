import { motion } from 'framer-motion';
import { Terminal, Clock, ArrowDown, ExternalLink, ArrowRight } from 'lucide-react';
import { FEATURES } from '../components/Features';
import { useRef } from 'react';

// V7: Split Layout — Fixed black left panel, scrollable white right, bold geometric, red accent
export default function V7Split() {
  const accent = '#E53935';
  const rightRef = useRef<HTMLDivElement>(null);

  return (
    <div className="min-h-screen flex">
      {/* Left Panel — Fixed */}
      <div className="hidden lg:flex w-[45vw] max-w-[580px] bg-black text-white fixed inset-y-0 left-0 flex-col justify-between p-10 z-20 overflow-hidden">
        {/* Geometric shapes */}
        <div className="absolute top-0 right-0 w-[300px] h-[300px] opacity-[0.03]" style={{ background: accent }} />
        <div className="absolute bottom-20 left-10 w-24 h-24 border-2 rotate-45 opacity-10" style={{ borderColor: accent }} />
        <div className="absolute top-1/3 right-16 w-3 h-3 rounded-full opacity-20" style={{ background: accent }} />

        {/* Nav */}
        <div>
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ duration: 0.5 }}
          >
            <span className="font-mono text-sm tracking-[0.3em] text-white/70">DANOTCH</span>
          </motion.div>

          <nav className="mt-12 space-y-4">
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

        {/* Headline */}
        <div className="my-auto py-16">
          <motion.div
            initial={{ opacity: 0, y: 30 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.7, delay: 0.3 }}
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
          </motion.div>

          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ delay: 0.8 }}
            className="flex items-center gap-5"
          >
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
          </motion.div>
        </div>

        {/* Footer on left panel */}
        <div>
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

        {/* Notch mockup */}
        <section className="pt-16 lg:pt-24 pb-20 px-8 lg:px-16">
          <motion.div
            initial={{ opacity: 0, y: 40 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.7, delay: 0.4 }}
            className="max-w-2xl"
          >
            <div
              className="aspect-[16/10] bg-[#0a0a0a] rounded-xl overflow-hidden relative"
              style={{ boxShadow: '0 30px 80px rgba(0,0,0,0.2)' }}
            >
              {/* Notch shape */}
              <div className="absolute top-0 left-1/2 -translate-x-1/2 w-[180px] h-[30px] bg-black rounded-b-[18px] z-10" />

              {/* Expanded notch */}
              <div className="absolute top-0 left-1/2 -translate-x-1/2 w-[420px] h-[260px] bg-black rounded-b-2xl border-b border-x border-white/10 overflow-hidden">
                <div className="pt-9 px-4 space-y-2.5">
                  <div className="flex justify-between">
                    <div className="flex gap-5 text-[9px] font-mono tracking-widest text-white/25">
                      <span className="text-white/80">[ HOME ]</span>
                      <span>AGENTS</span>
                      <span>STATS</span>
                    </div>
                    <div className="text-[9px] font-mono text-white/15">67%</div>
                  </div>

                  <div className="flex gap-3 mt-1.5">
                    <div className="w-[120px] shrink-0">
                      <p className="text-2xl font-extralight tracking-tight text-white">10:36</p>
                      <p className="text-[7px] font-mono tracking-widest text-white/25 mt-0.5">MON, APR 7</p>
                    </div>
                    <div className="flex-1 space-y-1.5">
                      <div className="text-[7px] font-mono tracking-widest text-white/20">AGENTS</div>
                      <div className="bg-white/5 rounded-lg p-2 border border-white/5">
                        <div className="flex items-center gap-1.5">
                          <Terminal className="w-2.5 h-2.5" style={{ color: accent }} />
                          <span className="text-[9px] text-white/60 font-mono">CLAUDE CODE</span>
                        </div>
                      </div>
                      <div className="bg-white/5 rounded-lg p-2 border border-white/5">
                        <div className="flex items-center gap-1.5">
                          <Clock className="w-2.5 h-2.5 text-yellow-500/60" />
                          <span className="text-[9px] text-white/40 font-mono">SCHEDULED</span>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
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
