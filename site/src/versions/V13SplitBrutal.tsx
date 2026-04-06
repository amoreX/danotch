import { motion } from 'framer-motion';
import { Terminal, Clock, ArrowDown, ExternalLink, ArrowRight, Zap } from 'lucide-react';
import { FEATURES } from '../components/Features';
import { useRef } from 'react';

// V13: Split + Brutal — Split layout with brutalist raw styling
// Fixed left panel from V7, thick borders/harsh shadows/mono uppercase from V3
export default function V13SplitBrutal() {
  const accent = '#FF3B30';
  const offWhite = '#F5F0EB';
  const rightRef = useRef<HTMLDivElement>(null);

  return (
    <div className="min-h-screen flex">
      {/* Left Panel — Fixed, brutalist off-white */}
      <div className="hidden lg:flex w-[45vw] max-w-[580px] fixed inset-y-0 left-0 flex-col justify-between p-10 z-20 overflow-hidden" style={{ background: offWhite, borderRight: '4px solid black' }}>
        {/* Geometric shapes — thick bordered squares */}
        <div className="absolute top-8 right-8 w-[200px] h-[200px] border-4 border-black opacity-[0.04]" />
        <div className="absolute bottom-20 left-10 w-20 h-20 border-4 border-black rotate-12 opacity-[0.06]" />
        <div className="absolute top-1/3 right-20 w-4 h-4 border-2 border-black opacity-10" style={{ background: accent }} />

        {/* Nav */}
        <div>
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ duration: 0.5 }}
          >
            <span className="font-mono text-sm font-black tracking-[0.3em] text-black/70">DANOTCH</span>
          </motion.div>

          <nav className="mt-12 space-y-4">
            {['FEATURES', 'HOW IT WORKS', 'DOWNLOAD'].map((item, i) => (
              <motion.a
                key={item}
                href={`#${item.toLowerCase().replace(/\s+/g, '-')}`}
                initial={{ opacity: 0, x: -20 }}
                animate={{ opacity: 1, x: 0 }}
                transition={{ delay: 0.2 + i * 0.1 }}
                className="block font-mono text-xs font-bold uppercase tracking-widest text-black/30 hover:text-[#FF3B30] transition-colors"
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
            <div className="w-16 h-1.5 mb-8 bg-black" />
            <h1 className="text-5xl xl:text-7xl font-black leading-[0.9] tracking-tighter mb-6 text-black">
              THE NOTCH
              <br />
              IS NOW A
              <br />
              <span style={{ color: accent }}>COMMAND
              <br />
              CENTER.</span>
            </h1>
            <p className="font-mono text-sm text-black/40 leading-relaxed max-w-sm mb-10 border-l-4 border-black pl-4">
              AI agents. Claude chat. Scheduled tasks. System stats. Music. Calendar. All crammed in your notch.
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
              className="inline-flex items-center gap-2 font-mono text-xs font-black uppercase tracking-wider px-7 py-3.5 text-white transition-all active:translate-x-1 active:translate-y-1"
              style={{ background: accent, border: '3px solid black', boxShadow: '4px 4px 0px 0px black' }}
            >
              <ArrowDown className="w-4 h-4" /> DOWNLOAD
            </a>
            <a href="#" className="flex items-center gap-2 font-mono text-xs font-bold uppercase tracking-wider text-black/30 hover:text-black/60 transition-colors">
              <ExternalLink className="w-4 h-4" /> SOURCE
            </a>
          </motion.div>
        </div>

        {/* Footer on left panel */}
        <div>
          <p className="font-mono text-[10px] text-black/20 tracking-widest uppercase">macOS 14+ &middot; ARM64 & x86</p>
        </div>
      </div>

      {/* Mobile top bar */}
      <div className="lg:hidden fixed top-0 inset-x-0 z-50 px-6 h-14 flex items-center justify-between border-b-4 border-black" style={{ background: offWhite }}>
        <span className="font-mono text-sm font-black tracking-[0.3em]">DANOTCH</span>
        <a
          href="#"
          className="font-mono text-[10px] font-black uppercase tracking-widest px-4 py-1.5 text-white"
          style={{ background: accent, border: '2px solid black' }}
        >
          GET IT
        </a>
      </div>

      {/* Right Panel — Scrollable, white with brutal styling */}
      <div
        ref={rightRef}
        className="flex-1 lg:ml-[45vw] lg:max-w-none bg-white min-h-screen"
      >
        {/* Mobile hero */}
        <section className="lg:hidden pt-20 pb-16 px-6 text-center border-b-4 border-black" style={{ background: offWhite }}>
          <div className="w-12 h-1.5 bg-black mx-auto mb-6" />
          <h1 className="text-4xl font-black leading-tight mb-4 tracking-tighter">
            THE NOTCH IS NOW A{' '}
            <span style={{ color: accent }}>COMMAND CENTER.</span>
          </h1>
          <p className="font-mono text-xs text-black/40 mb-8 max-w-md mx-auto uppercase tracking-wider">
            AI agents. Claude chat. Scheduled tasks. System stats. Music. Calendar.
          </p>
          <a
            href="#"
            className="inline-flex items-center gap-2 font-mono text-xs font-black uppercase tracking-wider px-6 py-3 text-white"
            style={{ background: accent, border: '3px solid black', boxShadow: '4px 4px 0px 0px black' }}
          >
            <ArrowDown className="w-4 h-4" /> DOWNLOAD
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
              className="aspect-[16/10] bg-black overflow-hidden relative"
              style={{ border: '4px solid black', boxShadow: `8px 8px 0px 0px ${accent}` }}
            >
              <div className="absolute top-0 left-1/2 -translate-x-1/2 w-[180px] h-[30px] bg-black rounded-b-[18px] z-10" />
              <div className="absolute top-0 left-1/2 -translate-x-1/2 w-[420px] h-[260px] bg-black rounded-b-2xl border-b-2 border-x-2 border-[#333] overflow-hidden">
                <div className="pt-9 px-4 space-y-2.5">
                  <div className="flex justify-between">
                    <div className="flex gap-5 text-[9px] font-mono font-bold tracking-widest text-white/25">
                      <span className="text-[#FF3B30]">[ HOME ]</span>
                      <span>AGENTS</span>
                      <span>STATS</span>
                    </div>
                    <div className="text-[9px] font-mono font-bold text-white/15">67%</div>
                  </div>
                  <div className="flex gap-3 mt-1.5">
                    <div className="w-[120px] shrink-0">
                      <p className="text-2xl font-black tracking-tight text-white font-mono">10:36</p>
                      <p className="text-[7px] font-mono font-bold tracking-widest text-white/25 mt-0.5">THU, APR 3</p>
                    </div>
                    <div className="flex-1 space-y-1.5">
                      <div className="text-[7px] font-mono font-bold tracking-widest text-white/20">AGENTS</div>
                      <div className="bg-white/5 p-2 border border-white/10">
                        <div className="flex items-center gap-1.5">
                          <Terminal className="w-2.5 h-2.5" style={{ color: accent }} />
                          <span className="text-[9px] text-white/60 font-mono font-bold">CLAUDE CODE</span>
                        </div>
                      </div>
                      <div className="bg-white/5 p-2 border border-white/10">
                        <div className="flex items-center gap-1.5">
                          <Clock className="w-2.5 h-2.5 text-yellow-500/60" />
                          <span className="text-[9px] text-white/40 font-mono font-bold">SCHEDULED</span>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </motion.div>
        </section>

        {/* Features — horizontal rows, brutalist styling */}
        <section id="features" className="px-8 lg:px-16 pb-20">
          <motion.div
            initial={{ opacity: 0 }}
            whileInView={{ opacity: 1 }}
            viewport={{ once: true }}
            className="mb-12"
          >
            <div className="inline-block font-mono text-xs font-bold uppercase tracking-[0.3em] bg-black text-white px-3 py-1 mb-4">
              FEATURES
            </div>
            <h2 className="text-3xl md:text-4xl font-black tracking-tighter text-black">WHAT IT DOES*</h2>
            <p className="font-mono text-xs text-black/30 mt-1">*Spoiler: a lot.</p>
          </motion.div>

          <div className="space-y-0 border-t-4 border-black">
            {FEATURES.map((f, i) => {
              const Icon = f.icon;
              return (
                <motion.div
                  key={f.title}
                  initial={{ opacity: 0, x: 30 }}
                  whileInView={{ opacity: 1, x: 0 }}
                  viewport={{ once: true }}
                  transition={{ delay: i * 0.06, duration: 0.4 }}
                  className="group flex items-start gap-6 py-6 cursor-pointer transition-all px-4 -mx-4 border-b-2 border-black hover:bg-black hover:text-white"
                >
                  <div className="w-11 h-11 border-3 border-black flex items-center justify-center shrink-0 transition-all duration-300 group-hover:border-[#FF3B30] group-hover:bg-[#FF3B30]" style={{ border: '3px solid black' }}>
                    <Icon className="w-5 h-5 text-black/50 group-hover:text-white transition-colors" />
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center justify-between gap-4">
                      <h3 className="font-mono text-sm font-black uppercase tracking-wider">{f.title}</h3>
                      <ArrowRight className="w-4 h-4 text-black/10 group-hover:text-[#FF3B30] transition-all duration-300 group-hover:translate-x-1 shrink-0" />
                    </div>
                    <p className="text-sm text-black/40 group-hover:text-white/50 leading-relaxed mt-1 transition-colors">{f.description}</p>
                  </div>
                  <Zap className="w-5 h-5 shrink-0 text-black/5 group-hover:text-[#FF3B30] transition-colors" />
                </motion.div>
              );
            })}
          </div>
        </section>

        {/* How it works */}
        <section id="how-it-works" className="px-8 lg:px-16 py-20 border-t-4 border-black" style={{ background: offWhite }}>
          <div className="max-w-2xl">
            <div className="inline-block font-mono text-xs font-bold uppercase tracking-[0.3em] bg-[#FF3B30] text-white px-3 py-1 mb-4">
              HOW
            </div>
            <h2 className="text-3xl md:text-4xl font-black tracking-tighter text-black mb-12">DEAD SIMPLE.</h2>

            <div className="space-y-0">
              {[
                { num: '01', title: 'DOWNLOAD', desc: 'Grab the app. Launch it. It hides in your menu bar like a good utility.' },
                { num: '02', title: 'HOVER', desc: 'Move your mouse to the notch. It expands. That\'s literally it.' },
                { num: '03', title: 'USE IT', desc: 'Chat with Claude. Monitor agents. Schedule stuff. Play music. Go wild.' },
              ].map((item, i) => (
                <motion.div
                  key={item.num}
                  initial={{ opacity: 0, x: -30 }}
                  whileInView={{ opacity: 1, x: 0 }}
                  viewport={{ once: true }}
                  transition={{ delay: i * 0.1 }}
                  className="flex items-start gap-6 p-5 -mt-1 border-4 border-black hover:bg-black hover:text-white transition-colors group cursor-pointer"
                >
                  <span className="text-4xl font-black shrink-0 font-mono" style={{ color: accent }}>{item.num}</span>
                  <div>
                    <h3 className="font-mono font-black text-lg tracking-wider mb-1">{item.title}</h3>
                    <p className="text-black/40 group-hover:text-white/50 leading-relaxed transition-colors">{item.desc}</p>
                  </div>
                </motion.div>
              ))}
            </div>
          </div>
        </section>

        {/* CTA */}
        <section id="download" className="px-8 lg:px-16 py-24 bg-[#FF3B30] text-white">
          <motion.div
            initial={{ opacity: 0 }}
            whileInView={{ opacity: 1 }}
            viewport={{ once: true }}
            className="max-w-xl"
          >
            <div className="w-16 h-1.5 bg-white mb-6" />
            <h2 className="text-4xl md:text-5xl font-black tracking-tighter text-white mb-3 leading-tight">
              STOP WASTING
              <br />
              YOUR NOTCH.
            </h2>
            <p className="font-mono text-xs text-white/60 mb-8 uppercase tracking-wider">Free. Open source. No account needed. macOS 14+.</p>
            <div className="flex items-center gap-5">
              <a
                href="#"
                className="inline-flex items-center gap-2 font-mono text-sm font-black uppercase tracking-wider px-8 py-4 bg-white text-[#FF3B30] transition-all active:translate-x-1 active:translate-y-1"
                style={{ border: '4px solid black', boxShadow: '6px 6px 0px 0px black' }}
              >
                <ArrowDown className="w-4 h-4" /> DOWNLOAD FOR MAC
              </a>
              <a href="#" className="flex items-center gap-2 font-mono text-xs font-bold uppercase tracking-wider text-white/50 hover:text-white transition-colors">
                <ExternalLink className="w-4 h-4" /> SOURCE
              </a>
            </div>
          </motion.div>
        </section>

        {/* Footer */}
        <footer className="px-8 lg:px-16 py-8 border-t-4 border-black" style={{ background: offWhite }}>
          <div className="flex items-center justify-between">
            <span className="font-mono text-xs font-black tracking-widest text-black/40">DANOTCH</span>
            <span className="font-mono text-[10px] text-black/20 uppercase tracking-widest">NO RIGHTS RESERVED &copy; 2026</span>
          </div>
        </footer>
      </div>
    </div>
  );
}
