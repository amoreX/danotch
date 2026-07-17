import { useEffect, useState } from 'react';
import Navbar from './components/Navbar';
import Hero from './components/Hero';
import Features from './components/Features';
import Download from './components/Download';
import Footer from './components/Footer';

export default function PerchSite() {
  const [ready, setReady] = useState(false);

  useEffect(() => {
    const firstFrame = requestAnimationFrame(() => setReady(true));
    return () => cancelAnimationFrame(firstFrame);
  }, []);

  return (
    <div className="bg-white min-h-screen">
      <div className="pointer-events-none fixed bottom-0 left-0 top-0 z-50 w-1 bg-[#111111] md:w-[10px]" />
      <div className="pointer-events-none fixed bottom-0 right-0 top-0 z-50 w-1 bg-[#111111] md:w-[10px]" />
      <Navbar ready={ready} />
      <main>
        <Hero ready={ready} />
        <Features />
        <Download />
      </main>
      <Footer />
    </div>
  );
}
