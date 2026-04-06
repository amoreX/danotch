import { motion } from 'framer-motion';
import { ArrowDown, ExternalLink, Terminal, Clock, Zap } from 'lucide-react';
import { FEATURES } from '../components/Features';

// V3: Neo-Brutalist — Off-white bg, thick borders, rotated cards, harsh shadows, red accent
export default function V3Brutalist() {
  return (
    <div className="min-h-screen bg-[#F5F0EB] text-black selection:bg-[#FF3B30] selection:text-white">
      {/* Nav */}
      <nav className="fixed top-0 inset-x-0 z-50 bg-[#F5F0EB] border-b-4 border-black">
        <div className="max-w-6xl mx-auto px-6 h-16 flex items-center justify-between">
          <span className="font-mono font-black text-lg tracking-tight">DANOTCH</span>
          <div className="hidden md:flex items-center gap-8">
            <a href="#features" className="font-mono text-xs font-bold uppercase tracking-widest hover:text-[#FF3B30] transition-colors">Features</a>
            <a href="#how" className="font-mono text-xs font-bold uppercase tracking-widest hover:text-[#FF3B30] transition-colors">How</a>
            <a href="#" className="font-mono text-xs font-bold uppercase tracking-widest hover:text-[#FF3B30] transition-colors">GitHub</a>
          </div>
          <a
            href="#"
            className="font-mono text-xs font-black uppercase tracking-widest bg-black text-[#F5F0EB] px-5 py-2.5 border-2 border-black hover:bg-[#FF3B30] hover:border-[#FF3B30] transition-colors"
          >
            GET IT
          </a>
        </div>
      </nav>

      {/* Hero */}
      <section className="pt-36 pb-24 px-6">
        <div className="max-w-5xl mx-auto">
          <motion.div
            initial={{ opacity: 0, y: 40 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.5 }}
          >
            <div className="inline-block font-mono text-xs font-bold uppercase tracking-[0.3em] bg-[#FF3B30] text-white px-3 py-1 mb-8 -rotate-1">
              macOS App
            </div>
          </motion.div>

          <motion.h1
            initial={{ opacity: 0, y: 50 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6, delay: 0.1 }}
            className="text-6xl md:text-8xl lg:text-[9rem] font-black leading-[0.85] tracking-tighter mb-8"
          >
            THE NOTCH
            <br />
            <span className="text-[#FF3B30]">DOES</span>
            <br />
            THINGS.
          </motion.h1>

          <motion.p
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ delay: 0.4 }}
            className="font-mono text-sm md:text-base max-w-xl text-black/60 leading-relaxed mb-12 border-l-4 border-black pl-4"
          >
            AI agent monitor. Claude chat. Scheduled tasks. Notifications. Music. System stats. Calendar.
            All crammed into your MacBook's notch. Because why not.
          </motion.p>

          {/* Notch Mockup — brutalist style */}
          <motion.div
            initial={{ opacity: 0, rotate: -2 }}
            animate={{ opacity: 1, rotate: 0 }}
            transition={{ delay: 0.5, duration: 0.6 }}
            className="relative max-w-2xl mb-14"
          >
            <div className="aspect-[16/10] bg-black rounded-none border-4 border-black overflow-hidden relative shadow-[8px_8px_0px_0px_#FF3B30]">
              {/* Notch */}
              <div className="absolute top-0 left-1/2 -translate-x-1/2 w-[200px] h-[34px] bg-black rounded-b-2xl z-10" />

              {/* Expanded notch content */}
              <div className="absolute top-0 left-1/2 -translate-x-1/2 w-[480px] h-[290px] bg-black rounded-b-2xl border-b-2 border-x-2 border-[#333] overflow-hidden">
                <div className="pt-10 px-5 space-y-3">
                  <div className="flex justify-between items-center">
                    <div className="flex gap-4 text-[10px] font-mono font-bold tracking-widest text-white/40">
                      <span className="text-[#FF3B30]">[ HOME ]</span>
                      <span>AGENTS</span>
                      <span>STATS</span>
                    </div>
                    <div className="text-[10px] font-mono font-bold text-white/30">67%</div>
                  </div>

                  <div className="flex gap-4 mt-2">
                    <div className="w-[130px] shrink-0">
                      <p className="text-3xl font-black tracking-tight text-white">11:42</p>
                      <p className="text-[8px] font-mono font-bold tracking-widest text-white/40 mt-1">THU, APR 3</p>
                    </div>

                    <div className="flex-1 space-y-2">
                      <div className="text-[8px] font-mono font-bold tracking-widest text-white/40">AGENTS</div>
                      <div className="bg-white/5 rounded-none p-2.5 border border-white/10">
                        <div className="flex items-center gap-2">
                          <Terminal className="w-3 h-3 text-[#FF3B30]" />
                          <span className="text-[10px] text-white/70 font-mono font-bold">CLAUDE CODE</span>
                          <span className="text-[9px] text-[#FF3B30] font-mono font-bold ml-auto">RUN</span>
                        </div>
                      </div>
                      <div className="bg-white/5 rounded-none p-2.5 border border-white/10">
                        <div className="flex items-center gap-2">
                          <Clock className="w-3 h-3 text-yellow-500" />
                          <span className="text-[10px] text-white/70 font-mono font-bold">SCHEDULED</span>
                          <span className="text-[9px] text-white/30 font-mono ml-auto">2</span>
                        </div>
                      </div>
                      <div className="bg-white/5 rounded-none px-3 py-2 border border-white/10 mt-2">
                        <span className="text-[10px] text-white/20 font-mono">Ask anything_</span>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </motion.div>

          <motion.div
            initial={{ opacity: 0, y: 10 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.8 }}
            className="flex flex-wrap gap-4"
          >
            <a
              href="#"
              className="inline-flex items-center gap-2 font-mono text-sm font-black uppercase tracking-wider bg-black text-[#F5F0EB] px-8 py-4 border-4 border-black hover:bg-[#FF3B30] hover:border-[#FF3B30] transition-colors shadow-[4px_4px_0px_0px_black] hover:shadow-[4px_4px_0px_0px_#FF3B30] active:shadow-none active:translate-x-1 active:translate-y-1"
            >
              <ArrowDown className="w-4 h-4" />
              DOWNLOAD NOW
            </a>
            <a
              href="#"
              className="inline-flex items-center gap-2 font-mono text-sm font-black uppercase tracking-wider bg-transparent text-black px-8 py-4 border-4 border-black hover:bg-black hover:text-[#F5F0EB] transition-colors"
            >
              <ExternalLink className="w-4 h-4" />
              SOURCE
            </a>
          </motion.div>
        </div>
      </section>

      {/* Features */}
      <section id="features" className="py-24 px-6 bg-black text-white">
        <div className="max-w-6xl mx-auto">
          <motion.div
            initial={{ opacity: 0, y: 20 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true }}
            className="mb-16"
          >
            <div className="inline-block font-mono text-xs font-bold uppercase tracking-[0.3em] bg-[#FF3B30] text-white px-3 py-1 mb-4">
              Features
            </div>
            <h2 className="text-4xl md:text-6xl font-black tracking-tighter">
              WHAT IT DOES*
            </h2>
            <p className="font-mono text-xs text-white/40 mt-2">*Spoiler: a lot.</p>
          </motion.div>

          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-0">
            {FEATURES.map((f, i) => (
              <motion.div
                key={f.title}
                initial={{ opacity: 0, y: 30, rotate: 0 }}
                whileInView={{ opacity: 1, y: 0, rotate: 0 }}
                whileHover={{ rotate: i % 2 === 0 ? -2 : 2, scale: 1.03 }}
                viewport={{ once: true }}
                transition={{ delay: i * 0.08, duration: 0.4 }}
                className="p-6 border border-white/10 hover:border-[#FF3B30] hover:bg-[#FF3B30]/5 transition-all cursor-pointer group"
              >
                <div className="w-10 h-10 border-2 border-white/20 group-hover:border-[#FF3B30] flex items-center justify-center mb-4 transition-colors">
                  <f.icon className="w-5 h-5 text-white/70 group-hover:text-[#FF3B30] transition-colors" />
                </div>
                <h3 className="font-mono font-black text-sm uppercase tracking-wider mb-2 group-hover:text-[#FF3B30] transition-colors">{f.title}</h3>
                <p className="text-xs text-white/40 leading-relaxed">{f.description}</p>
              </motion.div>
            ))}
          </div>
        </div>
      </section>

      {/* How it works */}
      <section id="how" className="py-24 px-6 border-t-4 border-black">
        <div className="max-w-4xl mx-auto">
          <motion.div
            initial={{ opacity: 0, y: 20 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true }}
            className="mb-16"
          >
            <div className="inline-block font-mono text-xs font-bold uppercase tracking-[0.3em] bg-black text-[#F5F0EB] px-3 py-1 mb-4">
              How
            </div>
            <h2 className="text-4xl md:text-6xl font-black tracking-tighter">
              DEAD SIMPLE.
            </h2>
          </motion.div>

          <div className="space-y-0">
            {[
              { step: '01', title: 'DOWNLOAD', text: 'Grab the app. Launch it. It hides in your menu bar like a good utility.' },
              { step: '02', title: 'HOVER', text: 'Move your mouse to the notch. It expands. That\'s literally it.' },
              { step: '03', title: 'USE IT', text: 'Chat with Claude. Monitor agents. Schedule stuff. Play music. Check stats. Go wild.' },
            ].map((item, i) => (
              <motion.div
                key={item.step}
                initial={{ opacity: 0, x: -40 }}
                whileInView={{ opacity: 1, x: 0 }}
                viewport={{ once: true }}
                transition={{ delay: i * 0.12, duration: 0.5 }}
                className="flex items-start gap-6 p-6 border-4 border-black -mt-1 hover:bg-black hover:text-[#F5F0EB] transition-colors group cursor-pointer"
              >
                <span className="text-5xl font-black text-[#FF3B30] shrink-0 font-mono">{item.step}</span>
                <div>
                  <h3 className="font-mono font-black text-xl tracking-wider mb-1">{item.title}</h3>
                  <p className="text-black/60 group-hover:text-white/60 leading-relaxed transition-colors">{item.text}</p>
                </div>
                <Zap className="w-6 h-6 shrink-0 ml-auto text-black/10 group-hover:text-[#FF3B30] transition-colors" />
              </motion.div>
            ))}
          </div>
        </div>
      </section>

      {/* CTA */}
      <section className="py-32 px-6 bg-[#FF3B30] text-white">
        <motion.div
          initial={{ opacity: 0, y: 20 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true }}
          className="max-w-4xl mx-auto text-center"
        >
          <h2 className="text-5xl md:text-7xl font-black tracking-tighter mb-8">
            STOP WASTING
            <br />
            YOUR NOTCH.
          </h2>
          <p className="font-mono text-sm text-white/70 mb-10 max-w-md mx-auto">
            Free. Open source. No account needed. Just download and go.
          </p>
          <a
            href="#"
            className="inline-flex items-center gap-3 font-mono text-base font-black uppercase tracking-wider bg-white text-[#FF3B30] px-10 py-5 border-4 border-white hover:bg-black hover:text-white hover:border-black transition-colors shadow-[6px_6px_0px_0px_black] active:shadow-none active:translate-x-1.5 active:translate-y-1.5"
          >
            <ArrowDown className="w-5 h-5" />
            DOWNLOAD DANOTCH
          </a>
          <p className="font-mono text-xs text-white/50 mt-6">macOS 14+ &middot; Apple Silicon & Intel</p>
        </motion.div>
      </section>

      {/* Footer */}
      <footer className="border-t-4 border-black py-8 px-6 bg-[#F5F0EB]">
        <div className="max-w-6xl mx-auto flex flex-col sm:flex-row items-center justify-between gap-4">
          <span className="font-mono font-black text-sm">DANOTCH</span>
          <div className="flex items-center gap-6 font-mono text-xs text-black/40">
            <a href="#" className="hover:text-[#FF3B30] transition-colors uppercase font-bold">GitHub</a>
            <a href="#" className="hover:text-[#FF3B30] transition-colors uppercase font-bold">Twitter</a>
            <span>&copy; 2026 &mdash; NO RIGHTS RESERVED</span>
          </div>
        </div>
      </footer>
    </div>
  );
}
