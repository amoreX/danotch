import { forwardRef, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { AnimatePresence, motion } from 'framer-motion';
import {
  ArrowDown,
  ArrowUp,
  Bell,
  CalendarDays,
  Check,
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  Clock3,
  Code2,
  Cpu,
  FileText,
  Globe,
  HardDrive,
  Mail,
  MemoryStick,
  Network,
  Pause,
  Send,
  Settings,
  SkipBack,
  SkipForward,
  Sparkles,
} from 'lucide-react';

export type PreviewKind = 'home' | 'chat' | 'connections' | 'scheduled' | 'stats';

interface FeatureItem {
  title: string;
  body: string;
  preview: PreviewKind;
}

const FEATURES: FeatureItem[] = [
  {
    title: 'Chat that acts',
    body: 'Ask from the notch. Perch can search the web, work with local files, and run approved actions without breaking your flow.',
    preview: 'chat',
  },
  {
    title: 'Your apps, connected',
    body: 'Bring Gmail, GitHub, Calendar, and Docs into the conversation. Sensitive actions wait for your approval before they run.',
    preview: 'connections',
  },
  {
    title: 'Scheduled tasks',
    body: 'Conditional alerts only fire when Claude decides the condition is true. No spam, only signal.',
    preview: 'scheduled',
  },
  {
    title: 'Ambient stats',
    body: 'CPU, RAM, network, disk — on arc gauges and sparklines. Pin up to three widgets to the home view.',
    preview: 'stats',
  },
];

function FeatureRow({
  feature,
  active,
  onSelect,
}: {
  feature: FeatureItem;
  active: boolean;
  onSelect: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onSelect}
      onMouseEnter={onSelect}
      onFocus={onSelect}
      aria-pressed={active}
      className="group relative w-full py-5 text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-zinc-950 md:py-6"
    >
      <span className="flex items-start justify-between gap-6">
        <span>
          <span
            className="block leading-tight transition-colors duration-200"
            style={{
              fontWeight: 600,
              fontSize: 'clamp(19px, 1.8vw, 25px)',
              letterSpacing: '-0.04em',
              color: active ? '#09090b' : '#71717a',
              textWrap: 'balance',
            } as React.CSSProperties}
          >
            {feature.title}
          </span>
          <span
            className="mt-3 block max-w-[470px] text-[14px] leading-7 transition-colors duration-200"
            style={{ color: active ? '#52525b' : '#71717a' }}
          >
            {feature.body}
          </span>
        </span>
      </span>
    </button>
  );
}

const glass =
  'preview-glass border border-white/[0.12] bg-white/[0.08] shadow-[inset_0_1px_0_rgba(255,255,255,0.09),0_12px_36px_rgba(0,0,0,0.12)] backdrop-blur-xl';

function TopBar({ active }: { active: PreviewKind }) {
  const todayActive = active === 'home';
  const agentActive = active === 'chat' || active === 'scheduled';

  return (
    <div className="relative flex h-9 items-center justify-between px-3 text-white">
      <div className="flex items-center gap-1.5">
        <span className={`${glass} rounded-full px-3 py-1 text-[10px] font-medium ${
          todayActive ? 'bg-[#253a60]/70' : ''
        }`}>
          Today
        </span>
        <span className={`${glass} flex h-[22px] w-[26px] items-center justify-center rounded-full ${
          agentActive ? 'bg-[#253a60]/70' : ''
        }`}>
          <Sparkles size={11} />
        </span>
      </div>

      <div className="flex items-center gap-1.5">
        <span
          className={`${glass} rounded-full px-3 py-1 text-[10px] font-medium ${
            active === 'stats' ? 'bg-[#253a60]/70' : ''
          }`}
        >
          Stats
        </span>
        <span className={`${glass} relative flex h-[22px] w-[26px] items-center justify-center rounded-full`}>
          <Bell size={11} />
          <span className="absolute right-1 top-1 h-1 w-1 rounded-full bg-red-500" />
        </span>
        <span
          className={`${glass} flex h-[22px] w-[26px] items-center justify-center rounded-full ${
            active === 'connections' ? 'bg-[#253a60]/70' : ''
          }`}
        >
          <Settings size={11} />
        </span>
      </div>
    </div>
  );
}

function TypedText({ text, speed = 28 }: { text: string; speed?: number }) {
  const [length, setLength] = useState(0);

  useEffect(() => {
    const interval = setInterval(() => {
      setLength((current) => {
        if (current >= text.length) {
          clearInterval(interval);
          return current;
        }
        return current + 1;
      });
    }, speed);
    return () => clearInterval(interval);
  }, [speed, text]);

  return (
    <span>
      {text.slice(0, length)}
      {length < text.length && <span className="ml-px inline-block h-[1em] w-px animate-pulse bg-current align-[-0.1em]" />}
    </span>
  );
}

function ChatPreview({ step }: { step: number }) {
  return (
    <div className="flex h-full flex-col gap-2.5 px-3 pb-3">
      <div className="flex items-center gap-2">
        <span className={`${glass} flex items-center gap-1 rounded-full px-2.5 py-1 text-[10px] text-white`}>
          <ChevronLeft size={10} />
          Back
        </span>
        <span className="truncate text-[11px] font-semibold text-white/85">Research current pricing</span>
      </div>

      <div className="flex flex-1 flex-col gap-2 overflow-hidden px-1">
        <AnimatePresence>
          {step >= 1 && (
            <motion.div
              key="first-prompt"
              className="ml-auto max-w-[72%] rounded-[14px] rounded-br-[5px] bg-white/[0.13] px-3 py-2 text-[10px] leading-relaxed text-white/90"
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
            >
              Compare current pricing for the best Mac productivity tools.
            </motion.div>
          )}
          {step >= 2 && (
            <motion.div
              key="web-search"
              className={`${glass} flex w-fit items-center gap-2 rounded-full px-3 py-1.5 text-[9px] text-white/65`}
              initial={{ opacity: 0, x: -10 }}
              animate={{ opacity: 1, x: 0 }}
              exit={{ opacity: 0 }}
            >
              <Globe size={11} className="text-cyan-300" />
              <span>{step === 2 ? 'Searching web…' : 'Searched web'}</span>
              {step > 2 && <Check size={10} className="text-emerald-400" />}
            </motion.div>
          )}
          {step >= 3 && (
            <motion.p
              key="first-answer"
              className="m-0 max-w-[88%] text-[10px] leading-[1.55] text-white/80"
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
            >
              Raycast, Alfred, and Things are strong options. Perch is the only one that
              keeps chat, connected apps, and live utilities in the notch.
            </motion.p>
          )}
          {step >= 5 && (
            <motion.div
              key="follow-up"
              className="ml-auto max-w-[66%] rounded-[14px] rounded-br-[5px] bg-white/[0.13] px-3 py-2 text-[10px] text-white/90"
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
            >
              Save that comparison for tomorrow.
            </motion.div>
          )}
          {step >= 6 && (
            <motion.div
              key="scheduled-result"
              className={`${glass} flex w-fit items-center gap-2 rounded-full px-3 py-1.5 text-[9px] text-white/65`}
              initial={{ opacity: 0, x: -10 }}
              animate={{ opacity: 1, x: 0 }}
            >
              <Clock3 size={11} className="text-amber-300" />
              <span>Scheduled for 9:00 AM</span>
              <Check size={10} className="text-emerald-400" />
            </motion.div>
          )}
        </AnimatePresence>
      </div>

      <div className={`${glass} flex items-center gap-2 rounded-full px-2.5 py-2`}>
        <span className="rounded-full border border-white/10 bg-white/[0.06] px-2 py-1 text-[8px] text-white/65">
          Sonnet
        </span>
        <span className={`flex-1 text-[10px] ${step === 0 || step === 4 ? 'text-white/75' : 'text-white/35'}`}>
          {step === 0 ? (
            <TypedText key="pricing-prompt" text="Compare current pricing for the best Mac productivity tools." speed={23} />
          ) : step === 4 ? (
            <TypedText key="save-prompt" text="Save that comparison for tomorrow." speed={27} />
          ) : (
            'Message agent'
          )}
        </span>
        <span className="flex h-6 w-6 items-center justify-center rounded-full bg-[#29466f] text-white">
          <Send size={10} />
        </span>
      </div>
    </div>
  );
}

const integrations = [
  { name: 'Gmail', icon: Mail, connectsAt: 1 },
  { name: 'Calendar', icon: CalendarDays, connectsAt: 2 },
  { name: 'Docs', icon: FileText, connectsAt: 3 },
  { name: 'GitHub', icon: Code2, connectsAt: 0 },
];

function ConnectionsPreview({ step }: { step: number }) {
  return (
    <div className="px-3 pb-3">
      <p className="mb-2 ml-1 mt-0 text-[10px] font-semibold tracking-wide text-white/55">Integrations</p>
      <div className="grid grid-cols-2 gap-2">
        {integrations.map(({ name, icon: Icon, connectsAt }) => {
          const connected = step >= connectsAt;
          return (
          <motion.div
            key={name}
            className={`${glass} flex min-h-[82px] flex-col justify-between rounded-[18px] p-3`}
            animate={{ borderColor: connected ? 'rgba(74,222,128,.28)' : 'rgba(255,255,255,.12)' }}
            transition={{ duration: 0.3 }}
          >
            <div className="flex items-start justify-between">
              <span className="flex h-8 w-8 items-center justify-center rounded-[10px] bg-white/[0.09] text-white">
                <Icon size={15} strokeWidth={1.7} />
              </span>
              <motion.span
                className="h-1.5 w-1.5 rounded-full"
                animate={{
                  backgroundColor: connected ? '#4ade80' : 'rgba(255,255,255,.25)',
                  scale: connected ? [1, 1.8, 1] : 1,
                }}
              />
            </div>
            <div>
              <p className="m-0 text-[11px] font-semibold text-white/90">{name}</p>
              <p className={`mb-0 mt-0.5 text-[8px] ${connected ? 'text-emerald-300/75' : 'text-white/35'}`}>
                {connected ? 'Connected' : step + 1 === connectsAt ? 'Connecting…' : 'Not connected'}
              </p>
            </div>
          </motion.div>
        )})}
      </div>
    </div>
  );
}

function ScheduledPreview({ step }: { step: number }) {
  const phase = step === 0 ? 'scheduled-start' : step <= 5 ? 'chat' : 'scheduled-result';
  const prompt = 'Check my inbox every morning at 9 and notify me if anything is urgent.';
  const finalList = phase === 'scheduled-result';

  return (
    <AnimatePresence mode="wait">
      <motion.div
        key={phase}
        className="h-full"
        initial={{ opacity: 0, y: 8 }}
        animate={{ opacity: 1, y: 0 }}
        exit={{ opacity: 0, y: -8 }}
        transition={{ duration: 0.22 }}
      >
        {(phase === 'scheduled-start' || phase === 'scheduled-result') && (
          <div className="h-full px-3 pb-3">
            <div className={`${glass} h-full overflow-hidden rounded-[18px]`}>
              <div className="flex items-center gap-2 px-4 pb-2.5 pt-3.5">
                <Clock3 size={11} className="text-amber-300" />
                <span className="text-[10px] font-semibold tracking-wide text-white/55">SCHEDULED</span>
                <span className="text-[9px] text-white/30">{finalList ? 3 : 2}</span>
                <ChevronDown size={10} className="ml-auto text-white/35" />
              </div>
              <div className="mx-3 overflow-hidden rounded-[14px] border border-white/[0.07] bg-white/[0.035]">
                <div className={`${finalList ? 'bg-amber-300/[0.07]' : ''} px-3 py-2.5`}>
                  <div className="flex items-center gap-2">
                    <span className="h-1.5 w-1.5 rounded-full bg-amber-300" />
                    <span className="text-[10px] font-semibold text-white/85">
                      {finalList ? 'Morning inbox check' : 'Morning inbox brief'}
                    </span>
                    <span className="ml-auto text-[8px] text-white/35">Daily at 9:00</span>
                    <ChevronDown size={9} className="text-white/35" />
                  </div>
                  <div className="ml-3.5 mt-2 rounded-[10px] bg-black/20 px-2.5 py-2">
                    <div className="flex items-center gap-1.5 text-[8px]">
                      <Check size={9} className="text-emerald-400" />
                      <span className="text-emerald-300/75">{finalList ? 'Ready' : 'Last run completed'}</span>
                      <span className="ml-auto text-white/25">{finalList ? 'Next: tomorrow, 9:00' : 'Today, 9:00'}</span>
                    </div>
                    <p className="mb-0 mt-1.5 text-[8px] leading-relaxed text-white/45">
                      {finalList
                        ? 'Checks Gmail for urgent messages and sends a notification only when attention is needed.'
                        : 'Found 3 important messages and prepared your inbox brief.'}
                    </p>
                  </div>
                </div>
                <div className="flex items-center gap-2 border-t border-white/[0.07] px-3 py-2.5">
                  <span className="h-1.5 w-1.5 rounded-full bg-amber-300" />
                  <span className="text-[10px] font-medium text-white/65">Price drop watch</span>
                  <span className="ml-auto text-[8px] text-white/30">Every 30 min</span>
                  <ChevronRight size={9} className="text-white/30" />
                </div>
                {finalList && (
                  <motion.div
                    className="flex items-center gap-2 border-t border-white/[0.07] px-3 py-2.5"
                    initial={{ opacity: 0, y: -8 }}
                    animate={{ opacity: 1, y: 0 }}
                  >
                    <span className="h-1.5 w-1.5 rounded-full bg-amber-300" />
                    <span className="text-[10px] font-medium text-white/65">Weekly project recap</span>
                    <span className="ml-auto text-[8px] text-white/30">Friday at 17:00</span>
                    <ChevronRight size={9} className="text-white/30" />
                  </motion.div>
                )}
              </div>
            </div>
          </div>
        )}

        {phase === 'chat' && (
          <div className="flex h-full flex-col gap-2.5 px-3 pb-3">
            <div className="flex items-center gap-2">
              <span className={`${glass} flex items-center gap-1 rounded-full px-2.5 py-1 text-[10px] text-white`}>
                <ChevronLeft size={10} /> Back
              </span>
              <span className="truncate text-[11px] font-semibold text-white/85">
                {step <= 2 ? 'New chat' : 'Morning inbox check'}
              </span>
            </div>
            <div className="relative flex flex-1 flex-col gap-2 overflow-hidden px-1">
              {step <= 2 && (
                <div className="absolute inset-0 flex flex-col items-center justify-center gap-2 text-white/25">
                  <Sparkles size={19} strokeWidth={1.4} />
                  <span className="text-[10px]">Ask Perch anything</span>
                </div>
              )}
              {step >= 3 && (
                <motion.div
                  className="ml-auto max-w-[80%] rounded-[16px] bg-[#29466f]/80 px-3 py-2 text-[10px] leading-relaxed text-white"
                  initial={{ opacity: 0, y: 8 }}
                  animate={{ opacity: 1, y: 0 }}
                >
                  {prompt}
                </motion.div>
              )}
              {step >= 4 && (
                <motion.div
                  className={`${glass} flex items-center gap-2 rounded-[13px] px-2.5 py-2`}
                  initial={{ opacity: 0, x: -8 }}
                  animate={{ opacity: 1, x: 0 }}
                >
                  <span className={`${glass} flex h-6 w-6 items-center justify-center rounded-full text-red-300`}>
                    <Clock3 size={10} />
                  </span>
                  <div className="min-w-0 flex-1">
                    <p className="m-0 text-[10px] font-semibold text-white">
                      {step === 4 ? 'Creating scheduled task…' : 'Created task'}
                    </p>
                    <p className="mb-0 mt-0.5 truncate text-[8px] text-white/35">Daily at 9:00 · notify on urgent email</p>
                  </div>
                  {step === 4 ? (
                    <span className="h-3 w-3 animate-spin rounded-full border border-white/25 border-t-white/80" />
                  ) : (
                    <Check size={11} className="text-emerald-400" />
                  )}
                </motion.div>
              )}
              {step >= 5 && (
                <motion.p
                  className="m-0 max-w-[86%] text-[10px] leading-relaxed text-white/75"
                  initial={{ opacity: 0, y: 6 }}
                  animate={{ opacity: 1, y: 0 }}
                >
                  Done — I’ll check your inbox every morning at 9 and only notify you when something needs attention.
                </motion.p>
              )}
            </div>
            <div className={`${glass} flex items-center gap-2 rounded-full px-2.5 py-2 text-[10px] ${
              step === 2 ? 'text-white/75' : 'text-white/35'
            }`}>
              <span className="rounded-full border border-white/10 bg-white/[0.06] px-2 py-1 text-[8px] text-white/65">Sonnet</span>
              <span className="min-w-0 flex-1 truncate">
                {step === 2 ? <TypedText key="schedule-chat-prompt" text={prompt} speed={19} /> : 'Message agent'}
              </span>
              <motion.span
                className={`flex h-6 w-6 items-center justify-center rounded-full ${
                  step === 2 ? 'bg-[#29466f] text-white' : 'text-white/40'
                }`}
                animate={{ scale: step === 2 ? [1, 0.86, 1] : 1 }}
                transition={{ delay: 1.55, duration: 0.22 }}
              >
                <Send size={10} />
              </motion.span>
            </div>
          </div>
        )}
      </motion.div>
    </AnimatePresence>
  );
}

function Ring({
  value,
  color,
}: {
  value: number;
  color: string;
}) {
  const circumference = 2 * Math.PI * 27;
  return (
    <div className="relative h-[72px] w-[72px]">
      <svg viewBox="0 0 64 64" className="-rotate-90">
        <circle cx="32" cy="32" r="27" fill="none" stroke="rgba(255,255,255,.10)" strokeWidth="5" />
        <motion.circle
          cx="32"
          cy="32"
          r="27"
          fill="none"
          stroke={color}
          strokeWidth="5"
          strokeLinecap="round"
          strokeDasharray={circumference}
          animate={{ strokeDashoffset: circumference * (1 - value / 100) }}
          transition={{ type: 'spring', stiffness: 90, damping: 18 }}
        />
      </svg>
      <motion.span
        key={value}
        className="absolute inset-0 flex items-center justify-center text-[14px] font-semibold text-white"
        initial={{ opacity: 0.4, y: 3 }}
        animate={{ opacity: 1, y: 0 }}
      >
        {value}%
      </motion.span>
    </div>
  );
}

const statFrames = [
  { cpu: 34, memory: 62, down: '12.4 MB/s', up: '2.1 MB/s', storage: 71 },
  { cpu: 57, memory: 65, down: '18.8 MB/s', up: '3.4 MB/s', storage: 71 },
  { cpu: 22, memory: 68, down: '4.2 MB/s', up: '920 KB/s', storage: 72 },
  { cpu: 76, memory: 71, down: '26.1 MB/s', up: '5.8 MB/s', storage: 72 },
];

function StatsPreview({ step }: { step: number }) {
  const frame = statFrames[step % statFrames.length];

  return (
    <div className="grid h-full grid-cols-2 gap-2 px-3 pb-3">
      <div className={`${glass} flex flex-col rounded-[18px] p-3`}>
        <div className="flex items-center gap-1.5 text-white/55">
          <Cpu size={11} className="text-emerald-300" />
          <span className="text-[10px] font-semibold">CPU</span>
        </div>
        <div className="flex flex-1 items-center justify-center">
          <Ring value={frame.cpu} color={frame.cpu > 70 ? '#fb7185' : frame.cpu > 50 ? '#f5ca63' : '#6ee7a8'} />
        </div>
        <span className="text-[8px] text-white/35">of capacity</span>
      </div>
      <div className={`${glass} flex flex-col rounded-[18px] p-3`}>
        <div className="flex items-center gap-1.5 text-white/55">
          <MemoryStick size={11} className="text-amber-300" />
          <span className="text-[10px] font-semibold">Memory</span>
        </div>
        <div className="flex flex-1 items-center justify-center"><Ring value={frame.memory} color="#f5ca63" /></div>
        <span className="text-[8px] text-white/35">{(frame.memory * 0.16).toFixed(1)} of 16 GB</span>
      </div>
      <div className={`${glass} rounded-[18px] p-3`}>
        <div className="mb-2 flex items-center gap-1.5 text-white/55">
          <Network size={11} />
          <span className="text-[10px] font-semibold">Network</span>
        </div>
        <div className="space-y-2 text-[9px]">
          <div className="flex items-center gap-2 text-white/80">
            <ArrowDown size={9} className="text-emerald-300" /> Down
            <motion.span key={frame.down} className="ml-auto text-white/45" initial={{ opacity: 0 }} animate={{ opacity: 1 }}>{frame.down}</motion.span>
          </div>
          <div className="flex items-center gap-2 text-white/80">
            <ArrowUp size={9} className="text-sky-300" /> Up
            <motion.span key={frame.up} className="ml-auto text-white/45" initial={{ opacity: 0 }} animate={{ opacity: 1 }}>{frame.up}</motion.span>
          </div>
        </div>
      </div>
      <div className={`${glass} rounded-[18px] p-3`}>
        <div className="flex items-center gap-1.5 text-white/55">
          <HardDrive size={11} className="text-emerald-300" />
          <span className="text-[10px] font-semibold">Storage</span>
        </div>
        <motion.p key={frame.storage} className="mb-0 mt-3 text-[18px] font-semibold text-white" initial={{ opacity: 0 }} animate={{ opacity: 1 }}>
          {frame.storage}%
        </motion.p>
        <p className="mb-0 mt-1 text-[8px] text-white/35">285 / 500 GB</p>
      </div>
    </div>
  );
}

const homePrompts = [
  'Ask Perch anything…',
  'What is on my calendar today?',
  'Summarize my unread email',
  'Play something focused',
];

function HomePreview({ step }: { step: number }) {
  const progress = [22, 38, 56, 74][step % 4];
  const ram = [54, 58, 61, 57][step % 4];
  const days = Array.from({ length: 18 }, (_, index) => index + 8);
  const weekdays = ['W', 'T', 'F', 'S', 'S', 'M', 'T', 'W', 'T', 'F', 'S', 'S', 'M', 'T', 'W', 'T', 'F', 'S'];

  return (
    <div className="flex h-full flex-col gap-2.5 px-3 pb-3">
      <div className={`${glass} flex items-center rounded-[18px] px-4 py-3`}>
        <div className="flex items-baseline gap-1.5">
          <p className="m-0 text-[28px] font-semibold leading-none tracking-[-1px] text-white">10:41</p>
          <span className="text-[9px] font-semibold text-white/35">AM</span>
        </div>
        <div className="ml-auto text-right">
          <p className="m-0 text-[10px] font-medium text-white/45">Thursday, July 16</p>
          <span className="mt-1 inline-flex rounded-full bg-white/[0.07] px-2 py-0.5 text-[7px] font-semibold text-white/35">
            Edit
          </span>
        </div>
      </div>

      <div className="grid h-[116px] shrink-0 grid-cols-2 gap-2">
        <div className={`${glass} overflow-hidden rounded-[18px] p-3`}>
          <div className="mb-2 flex items-center gap-1.5">
            <CalendarDays size={11} className="text-sky-300" />
            <span className="text-[9px] font-semibold tracking-wide text-white/55">CALENDAR</span>
          </div>
          <p className="mb-1 mt-0 text-[8px] font-medium text-white/30">Jul</p>
          <div className="overflow-hidden">
            <motion.div
              className="flex gap-0.5"
              animate={{ x: -(step % 4) * 8 }}
              transition={{ type: 'spring', stiffness: 120, damping: 20 }}
            >
              {days.map((day, index) => (
                <div
                  key={day}
                  className={`flex h-[26px] w-5 shrink-0 flex-col items-center justify-center rounded-[6px] ${
                    day === 16 ? 'bg-white/[0.1] text-white' : day < 16 ? 'text-white/25' : 'text-white/65'
                  }`}
                >
                  <span className="text-[6px] font-medium opacity-60">{weekdays[index]}</span>
                  <span className="mt-0.5 text-[8px] font-medium">{day}</span>
                </div>
              ))}
            </motion.div>
          </div>
        </div>

        <div className={`${glass} flex flex-col rounded-[18px] p-3`}>
          <div className="flex items-center gap-2.5">
            <div className="h-12 w-12 shrink-0 rounded-[10px] bg-[linear-gradient(135deg,#d97757,#621e34_55%,#121827)]" />
            <div className="min-w-0">
              <p className="m-0 truncate text-[10px] font-semibold text-white/85">Midnight City</p>
              <p className="mb-0 mt-0.5 text-[8px] text-white/35">M83</p>
            </div>
            <div className="ml-auto flex items-center gap-2 text-white/70">
              <SkipBack size={9} />
              <Pause size={12} />
              <SkipForward size={9} />
            </div>
          </div>
          <div className="mt-3 h-1 overflow-hidden rounded-full bg-white/[0.08]">
            <motion.div
              className="h-full rounded-full bg-white/75"
              animate={{ width: `${progress}%` }}
              transition={{ type: 'spring', stiffness: 80, damping: 18 }}
            />
          </div>
          <div className="mt-1.5 flex justify-between text-[7px] text-white/25">
            <span>1:14</span>
            <span>4:03</span>
          </div>
        </div>
      </div>

      <div className="grid h-[64px] shrink-0 grid-cols-3 gap-2">
        <div className={`${glass} flex flex-col justify-between rounded-[15px] px-3 py-2`}>
          <div className="flex items-center gap-1 text-[7px] font-semibold tracking-wide text-white/40">
            <MemoryStick size={8} /> RAM
            <motion.span key={ram} className="ml-auto text-[10px] text-white/80" initial={{ opacity: 0 }} animate={{ opacity: 1 }}>
              {ram}%
            </motion.span>
          </div>
          <div className="h-1 overflow-hidden rounded-full bg-white/[0.08]">
            <motion.div className="h-full rounded-full bg-emerald-300/80" animate={{ width: `${ram}%` }} />
          </div>
        </div>
        <div className={`${glass} flex flex-col justify-between rounded-[15px] px-3 py-2`}>
          <div className="flex items-center gap-1 text-[7px] font-semibold tracking-wide text-white/40">
            <Network size={8} /> NET
          </div>
          <div className="flex items-center gap-2 text-[8px]">
            <span className="text-sky-300">↑ 2.1M</span>
            <span className="text-emerald-300">↓ 12.4M</span>
          </div>
        </div>
        <div className={`${glass} flex flex-col justify-between rounded-[15px] px-3 py-2`}>
          <div className="flex items-center gap-1 text-[7px] font-semibold tracking-wide text-white/40">
            <Clock3 size={8} className="text-amber-300" /> SCHEDULED
            <span className="ml-auto text-[10px] text-white/80">2</span>
          </div>
          <span className="text-[8px] text-white/45">Next · 9:00 AM</span>
        </div>
      </div>

      <div className={`${glass} flex items-center gap-2 rounded-full px-2.5 py-2`}>
        <span className="rounded-full border border-white/10 bg-white/[0.06] px-2 py-1 text-[8px] text-white/65">
          Sonnet
        </span>
        <AnimatePresence mode="wait">
          <motion.span
            key={homePrompts[step % homePrompts.length]}
            className={`flex-1 text-[10px] ${step === 0 ? 'text-white/35' : 'text-white/65'}`}
            initial={{ opacity: 0, y: 4 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -4 }}
          >
            {homePrompts[step % homePrompts.length]}
          </motion.span>
        </AnimatePresence>
        <span className="flex h-6 w-6 items-center justify-center rounded-full bg-[#29466f] text-white">
          <Send size={10} />
        </span>
      </div>
    </div>
  );
}

const previewDimensions: Record<FeatureItem['preview'], { width: number; height: number }> = {
  home: { width: 540, height: 360 },
  chat: { width: 540, height: 348 },
  connections: { width: 500, height: 330 },
  scheduled: { width: 540, height: 360 },
  stats: { width: 540, height: 316 },
};

const PreviewPanel = forwardRef<HTMLDivElement, {
  preview: PreviewKind;
  withShadow: boolean;
  step: number;
}>(
  function PreviewPanel({ preview, withShadow, step }, ref) {
  const dimensions = previewDimensions[preview];
  const isPanelCollapsed =
    (preview === 'connections' && step === 5) ||
    (preview === 'home' && step === 4);
  const isNotificationPeek =
    (preview === 'connections' && step >= 6) ||
    (preview === 'home' && step >= 5);
  const panelState = isPanelCollapsed ? 'closed' : isNotificationPeek ? 'peek' : 'open';
  const peekTitle = preview === 'home' ? 'Focus block starts soon' : 'Upcoming meeting';
  const peekBody = preview === 'home'
    ? 'Your focus block begins at 1:00 PM · Music and Do Not Disturb are ready'
    : 'Design review at 2:00 PM · Brief ready in Docs · 3 unread emails';
  const panelBackground = preview === 'home'
    ? 'radial-gradient(circle at 16% 86%, rgba(80,125,166,.30), transparent 42%), radial-gradient(circle at 88% 28%, rgba(108,83,136,.20), transparent 38%), linear-gradient(180deg, #000 0px, #000 30px, rgba(0,0,0,.94) 58px, rgba(5,10,17,.74) 145px, rgba(15,25,35,.38) 74%, rgba(20,31,42,.12) 100%)'
    : 'linear-gradient(180deg, #000 0px, #000 30px, rgba(0,0,0,.92) 58px, rgba(2,5,9,.82) 145px, rgba(5,8,13,.72) 100%)';

  return (
    <motion.div
      ref={ref}
      className={`absolute left-1/2 top-0 overflow-hidden ${
        withShadow
          ? 'backdrop-blur-2xl shadow-[0_28px_70px_rgba(0,0,0,0.38)]'
          : 'preview-performance-mode'
      }`}
      style={{ x: '-50%', zIndex: 10 }}
      initial="closed"
      animate={panelState}
      exit="closed"
      variants={{
        closed: {
          width: 150,
          height: 30,
          borderBottomLeftRadius: 8,
          borderBottomRightRadius: 8,
          transition: {
            width: { type: 'spring', stiffness: 320, damping: 27, mass: 0.6 },
            height: { type: 'spring', stiffness: 250, damping: 25, mass: 0.7 },
            borderBottomLeftRadius: { duration: 0.2 },
            borderBottomRightRadius: { duration: 0.2 },
          },
        },
        open: {
          width: dimensions.width,
          height: dimensions.height,
          borderBottomLeftRadius: 32,
          borderBottomRightRadius: 32,
          transition: {
            width: { type: 'spring', stiffness: 285, damping: 23, mass: 0.66 },
            height: { type: 'spring', stiffness: 205, damping: 20, mass: 0.82 },
            borderBottomLeftRadius: { duration: 0.22 },
            borderBottomRightRadius: { duration: 0.22 },
          },
        },
        peek: {
          width: 360,
          height: 108,
          borderBottomLeftRadius: 14,
          borderBottomRightRadius: 14,
          transition: {
            width: { type: 'spring', stiffness: 280, damping: 24, mass: 0.66 },
            height: { type: 'spring', stiffness: 220, damping: 22, mass: 0.76 },
            borderBottomLeftRadius: { duration: 0.2 },
            borderBottomRightRadius: { duration: 0.2 },
          },
        },
      }}
    >
      <div
        className="pointer-events-none absolute inset-0"
        style={{
          background: panelBackground,
        }}
      />
      <AnimatePresence mode="wait">
        {isNotificationPeek ? (
          <motion.div
            key="notification-peek"
            className="relative z-10 flex h-full flex-col px-3 pb-2 pt-[36px]"
            initial={{ opacity: 0, y: -6 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0 }}
            transition={{ delay: 0.12, duration: 0.2 }}
          >
            <div className="flex items-center gap-2">
              <span className="text-[9px]">❗</span>
              <span className="text-[10px] font-semibold text-white">{peekTitle}</span>
              <span className="ml-auto text-[7px] tracking-wide text-white/35">NOW</span>
            </div>
            <p className="mb-0 mt-1.5 truncate text-[9px] text-white/60">
              {peekBody}
            </p>
            <span className="mt-auto self-end text-[7px] font-semibold tracking-[0.12em] text-white/40">VIEW ALL</span>
          </motion.div>
        ) : !isPanelCollapsed ? (
          <motion.div
            key="expanded-preview"
            className="relative z-10 h-full"
            initial={{ opacity: 0, y: -8, scaleX: 0.96, scaleY: 1.04 }}
            animate={{ opacity: 1, y: 0, scaleX: 1, scaleY: 1 }}
            exit={{ opacity: 0, y: -8, scaleX: 0.97, scaleY: 1.03 }}
            transition={{
              opacity: { duration: 0.14 },
              default: { type: 'spring', stiffness: 260, damping: 22, mass: 0.68, delay: 0.08 },
            }}
          >
            <TopBar active={preview} />
            <div className="h-[calc(100%-36px)] overflow-hidden pt-1">
              <motion.div
                className="h-full"
                initial={{ opacity: 0, y: 14 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, y: -8 }}
                transition={{ type: 'spring', stiffness: 250, damping: 23, mass: 0.72, delay: 0.1 }}
              >
                {preview === 'home' && <HomePreview step={step} />}
                {preview === 'chat' && <ChatPreview step={step} />}
                {preview === 'connections' && <ConnectionsPreview step={step} />}
                {preview === 'scheduled' && <ScheduledPreview step={step} />}
                {preview === 'stats' && <StatsPreview step={step} />}
              </motion.div>
            </div>
          </motion.div>
        ) : null}
      </AnimatePresence>
    </motion.div>
  );
});

const previewStepCounts: Record<PreviewKind, number> = {
  home: 6,
  chat: 7,
  connections: 7,
  scheduled: 7,
  stats: 4,
};

const previewStepDurations: Record<PreviewKind, number> = {
  home: 1600,
  chat: 1700,
  connections: 1350,
  scheduled: 1800,
  stats: 1350,
};

function usePreviewLoop(
  preview: PreviewKind,
  open: boolean,
  autoPlay: boolean,
  closeBetweenLoops: boolean,
) {
  const [step, setStep] = useState(0);
  const [loopOpen, setLoopOpen] = useState(open);

  useEffect(() => {
    const timers: ReturnType<typeof setTimeout>[] = [];
    const count = previewStepCounts[preview];
    const stepDuration = previewStepDurations[preview];
    const schedule = (delay: number, action: () => void) => {
      timers.push(setTimeout(action, delay));
    };
    schedule(0, () => {
      setStep(0);
      setLoopOpen(open);
    });

    if (!open || !autoPlay) {
      return () => timers.forEach(clearTimeout);
    }

    if (!closeBetweenLoops) {
      const interval = setInterval(() => {
        setStep((current) => (current + 1) % count);
      }, stepDuration);
      return () => {
        clearInterval(interval);
        timers.forEach(clearTimeout);
      };
    }

    const runCycle = () => {
      setLoopOpen(true);
      setStep(0);

      for (let nextStep = 1; nextStep < count; nextStep += 1) {
        schedule(nextStep * stepDuration, () => setStep(nextStep));
      }

      const closeAt = count * stepDuration + 400;
      schedule(closeAt, () => setLoopOpen(false));
      schedule(closeAt + 850, runCycle);
    };

    schedule(0, runCycle);
    return () => timers.forEach(clearTimeout);
  }, [autoPlay, closeBetweenLoops, open, preview]);

  return { step, visible: open && loopOpen };
}

export function CurrentAppPreview({
  preview,
  withShadow = true,
  open = true,
  autoPlay = true,
  closeBetweenLoops = true,
}: {
  preview: PreviewKind;
  withShadow?: boolean;
  open?: boolean;
  autoPlay?: boolean;
  closeBetweenLoops?: boolean;
}) {
  const { step, visible } = usePreviewLoop(preview, open, autoPlay, closeBetweenLoops);

  return (
    <div className="relative h-[366px] w-[540px] select-none">
      <AnimatePresence mode="wait" initial={false}>
        {visible && (
          <PreviewPanel
            key={`perch-preview-${preview}`}
            preview={preview}
            withShadow={withShadow}
            step={step}
          />
        )}
      </AnimatePresence>

      <div className="pointer-events-none absolute left-1/2 top-0 z-30 h-[30px] w-[150px] -translate-x-1/2 rounded-b-[12px] bg-black" />
    </div>
  );
}

function FeatureDesktopCard({ preview }: { preview: PreviewKind }) {
  const cardRef = useRef<HTMLDivElement>(null);
  const [previewScale, setPreviewScale] = useState(0.65);

  useLayoutEffect(() => {
    const card = cardRef.current;
    if (!card) return;

    const measure = () => {
      const inset = Math.min(32, card.clientWidth * 0.08);
      setPreviewScale(Math.min(1, Math.max(0.42, (card.clientWidth - inset) / 540)));
    };
    const firstFrame = requestAnimationFrame(measure);
    const observer = new ResizeObserver(measure);
    observer.observe(card);

    return () => {
      cancelAnimationFrame(firstFrame);
      observer.disconnect();
    };
  }, []);

  return (
    <div
      ref={cardRef}
      className="relative mx-auto aspect-[680/470] w-full max-w-[680px] overflow-hidden rounded-[18px] bg-cover bg-center sm:rounded-[24px]"
      style={{ backgroundImage: "url('/macos-mojave.jpg')" }}
    >
      <div className="absolute inset-x-0 top-0 flex justify-center">
        <div
          className="h-[366px] w-[540px] shrink-0 origin-top"
          style={{ transform: `scale(${previewScale})` }}
        >
          <CurrentAppPreview preview={preview} withShadow={false} />
        </div>
      </div>
    </div>
  );
}

export default function Features() {
  const [activeIndex, setActiveIndex] = useState(0);
  const featureRowRefs = useRef<Array<HTMLDivElement | null>>([]);
  const activeFeature = FEATURES[activeIndex];

  useEffect(() => {
    const mobileQuery = window.matchMedia('(max-width: 1023px)');
    let observer: IntersectionObserver | null = null;

    const observeMobileRows = () => {
      observer?.disconnect();
      observer = null;
      if (!mobileQuery.matches) return;

      observer = new IntersectionObserver(
        (entries) => {
          const focused = entries
            .filter((entry) => entry.isIntersecting)
            .sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];
          if (!focused) return;

          const index = Number((focused.target as HTMLElement).dataset.featureIndex);
          if (Number.isFinite(index)) setActiveIndex(index);
        },
        {
          rootMargin: '-34% 0px -44% 0px',
          threshold: [0, 0.25, 0.5, 0.75],
        },
      );

      featureRowRefs.current.forEach((row) => {
        if (row) observer?.observe(row);
      });
    };

    observeMobileRows();
    mobileQuery.addEventListener('change', observeMobileRows);
    return () => {
      observer?.disconnect();
      mobileQuery.removeEventListener('change', observeMobileRows);
    };
  }, []);

  return (
    <section id="features" className="bg-white">
      <div className="mx-auto max-w-[1280px] px-5 py-20 sm:px-8 md:py-32">
        <div className="mb-10 max-w-2xl">
          <h2
            className="text-3xl md:text-[2.6rem] m-0 leading-[1.1]"
            style={{
              fontWeight: 400,
              letterSpacing: '0.01em',
              color: '#0a0a0a',
              textWrap: 'balance',
            } as React.CSSProperties}
          >
            One hover does a lot.
          </h2>
          <p
            className="mb-0 mt-5 text-zinc-500"
            style={{ maxWidth: 560, fontSize: 16, lineHeight: 1.75 }}
          >
            Perch keeps the useful stuff close, without turning your desktop into another dashboard.
          </p>
        </div>

        <div className="grid items-start gap-10 lg:grid-cols-[minmax(300px,0.78fr)_minmax(540px,1.22fr)] lg:gap-16">
          <div>
            {FEATURES.map((feature, index) => (
              <div
                key={feature.title}
                ref={(element) => {
                  featureRowRefs.current[index] = element;
                }}
                data-feature-index={index}
                className="flex min-h-[clamp(180px,22vh,230px)] items-center lg:min-h-0"
              >
                <FeatureRow
                  feature={feature}
                  active={index === activeIndex}
                  onSelect={() => setActiveIndex(index)}
                />
              </div>
            ))}
          </div>

          <div className="sticky top-[68px] z-10 order-first lg:order-none lg:top-24">
            <FeatureDesktopCard preview={activeFeature.preview} />
          </div>
        </div>
      </div>
    </section>
  );
}
