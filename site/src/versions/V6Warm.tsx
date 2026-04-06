import { motion } from 'framer-motion';
import { Terminal, Clock, ArrowDown, ExternalLink, Heart } from 'lucide-react';
import { FEATURES } from '../components/Features';

// V6: Warm Minimal — Cream bg, serif headings, orange-rust accent, organic feel
export default function V6Warm() {
  const accent = '#D97757';
  const brown = '#3D2E1E';
  const cream = '#FDFBF7';
  const lightCream = '#FAF6EF';

  return (
    <div className="min-h-screen" style={{ background: cream, color: brown }}>
      {/* Nav */}
      <nav className="fixed top-0 inset-x-0 z-50 bg-[#FDFBF7]/80 backdrop-blur-md">
        <div className="max-w-5xl mx-auto px-6 h-16 flex items-center justify-between">
          <span className="text-sm tracking-[0.2em]" style={{ fontFamily: 'Georgia, serif', color: brown }}>
            Danotch
          </span>
          <div className="flex items-center gap-8">
            <a href="#features" className="text-sm opacity-40 hover:opacity-80 transition-opacity" style={{ color: brown }}>
              Features
            </a>
            <a href="#" className="text-sm opacity-40 hover:opacity-80 transition-opacity" style={{ color: brown }}>
              About
            </a>
            <a
              href="#"
              className="text-sm px-5 py-2 rounded-full transition-all duration-300 hover:shadow-lg"
              style={{ background: accent, color: '#fff' }}
            >
              Download
            </a>
          </div>
        </div>
      </nav>

      {/* Hero */}
      <section className="pt-36 pb-24 px-6">
        <div className="max-w-3xl mx-auto text-center">
          <motion.p
            initial={{ opacity: 0, y: 10 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6 }}
            className="text-sm tracking-wide mb-6 opacity-40"
            style={{ fontFamily: 'Georgia, serif' }}
          >
            A better use for that little black rectangle
          </motion.p>

          <motion.h1
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.7, delay: 0.15 }}
            className="text-5xl md:text-7xl font-normal leading-[1.1] mb-8"
            style={{ fontFamily: 'Georgia, serif', color: brown }}
          >
            Your notch,{' '}
            <span style={{ color: accent }}>thoughtfully</span>{' '}
            reimagined.
          </motion.h1>

          <motion.p
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ delay: 0.4, duration: 0.6 }}
            className="text-lg leading-relaxed max-w-xl mx-auto mb-14 opacity-50"
          >
            Chat with Claude, monitor AI agents, schedule tasks, check your calendar,
            play music, and watch system stats — all from a gentle hover over the notch.
          </motion.p>

          {/* Notch mockup */}
          <motion.div
            initial={{ opacity: 0, y: 30 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.6, duration: 0.7 }}
            className="relative max-w-2xl mx-auto mb-14"
          >
            <div
              className="aspect-[16/10] rounded-3xl overflow-hidden relative"
              style={{
                background: '#1a1a1a',
                boxShadow: '0 25px 80px rgba(61,46,30,0.15), 0 8px 30px rgba(61,46,30,0.1)',
              }}
            >
              {/* Notch shape */}
              <div className="absolute top-0 left-1/2 -translate-x-1/2 w-[200px] h-[34px] bg-black rounded-b-[20px] z-10" />

              {/* Expanded notch content */}
              <div className="absolute top-0 left-1/2 -translate-x-1/2 w-[480px] h-[300px] bg-[#111] rounded-b-3xl overflow-hidden border-b border-x border-white/5">
                <div className="pt-10 px-5 space-y-3">
                  <div className="flex justify-between">
                    <div className="flex gap-6 text-[10px] tracking-widest text-white/30" style={{ fontFamily: 'Georgia, serif' }}>
                      <span className="text-white/80">Home</span>
                      <span>Agents</span>
                      <span>Stats</span>
                    </div>
                    <div className="text-[10px] text-white/20">67%</div>
                  </div>

                  <div className="flex gap-4 mt-2">
                    <div className="w-[140px] shrink-0">
                      <p className="text-3xl font-light tracking-tight text-white/90" style={{ fontFamily: 'Georgia, serif' }}>
                        10:36
                      </p>
                      <p className="text-[9px] tracking-wide text-white/30 mt-1" style={{ fontFamily: 'Georgia, serif' }}>
                        Monday, April 7
                      </p>
                    </div>

                    <div className="flex-1 space-y-2">
                      <div className="text-[8px] tracking-widest text-white/25">AGENTS</div>
                      <div className="bg-white/5 rounded-xl p-2.5">
                        <div className="flex items-center gap-2">
                          <Terminal className="w-3 h-3" style={{ color: accent }} />
                          <span className="text-[10px] text-white/60">Claude Code</span>
                          <span className="text-[9px] text-white/25 ml-auto">active</span>
                        </div>
                      </div>
                      <div className="bg-white/5 rounded-xl p-2.5">
                        <div className="flex items-center gap-2">
                          <Clock className="w-3 h-3 text-white/30" />
                          <span className="text-[10px] text-white/40">Scheduled</span>
                          <span className="text-[9px] text-white/20 ml-auto">2</span>
                        </div>
                      </div>
                      <div className="bg-white/5 rounded-xl px-3 py-2 mt-3">
                        <span className="text-[10px] text-white/15" style={{ fontFamily: 'Georgia, serif' }}>Ask anything...</span>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </motion.div>

          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ delay: 0.9 }}
            className="flex items-center justify-center gap-5"
          >
            <a
              href="#"
              className="px-8 py-3 rounded-full text-sm font-medium transition-all duration-300 hover:shadow-lg hover:scale-[1.02]"
              style={{ background: accent, color: '#fff' }}
            >
              Download for Mac
            </a>
            <a href="#" className="flex items-center gap-2 text-sm opacity-35 hover:opacity-70 transition-opacity" style={{ color: brown }}>
              <ExternalLink className="w-4 h-4" /> Source
            </a>
          </motion.div>
        </div>
      </section>

      {/* Features */}
      <section id="features" className="py-24 px-6" style={{ background: lightCream }}>
        <div className="max-w-5xl mx-auto">
          <motion.div
            initial={{ opacity: 0 }}
            whileInView={{ opacity: 1 }}
            viewport={{ once: true }}
            className="text-center mb-16"
          >
            <p className="text-sm tracking-wide opacity-40 mb-3" style={{ fontFamily: 'Georgia, serif' }}>
              Everything you need
            </p>
            <h2 className="text-3xl md:text-4xl" style={{ fontFamily: 'Georgia, serif', color: brown }}>
              A whole command center,{' '}
              <span style={{ color: accent }}>in the notch.</span>
            </h2>
          </motion.div>

          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-5">
            {FEATURES.map((f, i) => {
              const Icon = f.icon;
              return (
                <motion.div
                  key={f.title}
                  initial={{ opacity: 0, y: 20 }}
                  whileInView={{ opacity: 1, y: 0 }}
                  viewport={{ once: true }}
                  transition={{ delay: i * 0.08, duration: 0.5 }}
                  className="p-6 rounded-2xl transition-all duration-300 cursor-pointer hover:-translate-y-1"
                  style={{
                    background: '#fff',
                    boxShadow: '0 2px 20px rgba(61,46,30,0.06)',
                  }}
                  onMouseEnter={(e) => {
                    e.currentTarget.style.boxShadow = '0 8px 40px rgba(217,119,87,0.12)';
                  }}
                  onMouseLeave={(e) => {
                    e.currentTarget.style.boxShadow = '0 2px 20px rgba(61,46,30,0.06)';
                  }}
                >
                  <div
                    className="w-10 h-10 rounded-xl flex items-center justify-center mb-4"
                    style={{ background: `${accent}12` }}
                  >
                    <Icon className="w-5 h-5" style={{ color: accent }} />
                  </div>
                  <h3 className="font-medium mb-2 text-sm" style={{ color: brown, fontFamily: 'Georgia, serif' }}>
                    {f.title}
                  </h3>
                  <p className="text-sm leading-relaxed opacity-45">{f.description}</p>
                </motion.div>
              );
            })}
          </div>
        </div>
      </section>

      {/* How it works */}
      <section className="py-24 px-6" style={{ background: cream }}>
        <div className="max-w-3xl mx-auto">
          <motion.div
            initial={{ opacity: 0 }}
            whileInView={{ opacity: 1 }}
            viewport={{ once: true }}
            className="text-center mb-14"
          >
            <h2 className="text-3xl" style={{ fontFamily: 'Georgia, serif', color: brown }}>
              Simple as a hover.
            </h2>
          </motion.div>

          <div className="space-y-10">
            {[
              { step: '1', title: 'Install', text: 'Download and launch. It quietly lives in your menu bar.' },
              { step: '2', title: 'Hover', text: 'Move your cursor over the notch. It gently expands into your workspace.' },
              { step: '3', title: 'Enjoy', text: 'Chat with Claude, monitor your agents, schedule tasks, and more.' },
            ].map((item, i) => (
              <motion.div
                key={item.step}
                initial={{ opacity: 0, x: -20 }}
                whileInView={{ opacity: 1, x: 0 }}
                viewport={{ once: true }}
                transition={{ delay: i * 0.12 }}
                className="flex items-start gap-6"
              >
                <span
                  className="text-3xl font-light shrink-0 w-12 h-12 rounded-full flex items-center justify-center"
                  style={{ color: accent, background: `${accent}10`, fontFamily: 'Georgia, serif' }}
                >
                  {item.step}
                </span>
                <div>
                  <h3 className="text-lg mb-1" style={{ fontFamily: 'Georgia, serif', color: brown }}>{item.title}</h3>
                  <p className="opacity-45 leading-relaxed">{item.text}</p>
                </div>
              </motion.div>
            ))}
          </div>
        </div>
      </section>

      {/* CTA */}
      <section className="py-32 px-6 text-center" style={{ background: lightCream }}>
        <motion.div
          initial={{ opacity: 0, y: 20 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true }}
        >
          <h2 className="text-4xl md:text-5xl mb-4 leading-tight" style={{ fontFamily: 'Georgia, serif', color: brown }}>
            Give your notch<br />
            <span style={{ color: accent }}>a purpose.</span>
          </h2>
          <p className="opacity-40 mb-8 text-sm">Free and open source. macOS 14 or later.</p>
          <a
            href="#"
            className="inline-flex items-center gap-2 px-8 py-3.5 rounded-full text-sm font-medium transition-all duration-300 hover:shadow-lg hover:scale-[1.02]"
            style={{ background: accent, color: '#fff' }}
          >
            <ArrowDown className="w-4 h-4" /> Download Danotch
          </a>
        </motion.div>
      </section>

      {/* Footer */}
      <footer className="py-10 px-6" style={{ borderTop: `1px solid ${brown}10` }}>
        <div className="max-w-5xl mx-auto flex items-center justify-between">
          <span className="text-sm opacity-30" style={{ fontFamily: 'Georgia, serif' }}>Danotch</span>
          <span className="text-xs opacity-20 flex items-center gap-1">
            Made with <Heart className="w-3 h-3 inline" style={{ color: accent }} /> for Mac
          </span>
        </div>
      </footer>
    </div>
  );
}
