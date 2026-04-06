import { useState, lazy, Suspense } from 'react';

const versions = [
  { id: 1, name: 'Brutalist', desc: 'Raw neo-brutalism' },
  { id: 2, name: 'Warm', desc: 'Cream & serif organic' },
  { id: 3, name: 'Split', desc: 'Editorial split layout' },
];

const V3 = lazy(() => import('./versions/V3Brutalist'));
const V6 = lazy(() => import('./versions/V6Warm'));
const V7 = lazy(() => import('./versions/V7Split'));

const components = [V3, V6, V7];

export default function App() {
  const [current, setCurrent] = useState(0);
  const [showPicker, setShowPicker] = useState(true);
  const Version = components[current];

  return (
    <div className="relative">
      {/* Version picker overlay */}
      {showPicker && (
        <div className="fixed inset-0 z-[9999] bg-black/95 backdrop-blur-xl flex items-center justify-center">
          <div className="max-w-2xl w-full px-6">
            <h1 className="text-center text-white text-3xl font-light tracking-tight mb-2">
              Danotch Landing Pages
            </h1>
            <p className="text-center text-white/40 text-sm mb-10">
              3 design versions. Pick one to preview.
            </p>

            <div className="grid grid-cols-3 gap-4">
              {versions.map((v, i) => (
                <button
                  key={v.id}
                  onClick={() => { setCurrent(i); setShowPicker(false); }}
                  className="group text-left p-5 rounded-xl border border-white/10 hover:border-white/30 hover:bg-white/5 transition-all cursor-pointer"
                >
                  <div className="text-white/80 font-mono text-xs mb-1">V{v.id}</div>
                  <div className="text-white font-medium text-sm">{v.name}</div>
                  <div className="text-white/30 text-xs mt-1">{v.desc}</div>
                </button>
              ))}
            </div>
          </div>
        </div>
      )}

      {/* Floating version switcher */}
      {!showPicker && (
        <div className="fixed bottom-4 left-1/2 -translate-x-1/2 z-[9999] flex items-center gap-2 bg-black/90 backdrop-blur-xl border border-white/10 rounded-full px-2 py-1.5 shadow-2xl">
          {versions.map((v, i) => (
            <button
              key={v.id}
              onClick={() => setCurrent(i)}
              className={`w-8 h-8 rounded-full text-xs font-mono transition-all cursor-pointer ${
                current === i
                  ? 'bg-white text-black font-bold'
                  : 'text-white/40 hover:text-white hover:bg-white/10'
              }`}
            >
              {v.id}
            </button>
          ))}
          <div className="w-px h-5 bg-white/10 mx-1" />
          <button
            onClick={() => setShowPicker(true)}
            className="text-white/40 hover:text-white text-xs font-mono px-3 py-1 cursor-pointer"
          >
            ALL
          </button>
        </div>
      )}

      {/* Render current version */}
      <Suspense fallback={
        <div className="min-h-screen bg-black flex items-center justify-center">
          <div className="text-white/30 font-mono text-sm">Loading...</div>
        </div>
      }>
        <Version />
      </Suspense>
    </div>
  );
}
