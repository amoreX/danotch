import { useState, useEffect, useRef, useCallback } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import {
  Terminal, Clock, Bell, Music, Cpu,
  ChevronDown, ChevronRight, ChevronLeft,
  Settings, Send, Sparkles,
  SkipBack, Play, SkipForward, Pause,
  Hammer, Type, Globe,
  ArrowDown, ArrowUp, HardDrive,
  Trash2, MessageSquare, Eye, Lock, Battery,
  Grid3x3, Activity, Rows3, Calendar, Wifi,
} from 'lucide-react';

// ─── Design tokens (1:1 from Theme.swift DN enum) ───
const DN = {
  black: '#000000',
  surface: '#111111',
  surfaceRaised: '#1A1A1A',
  border: '#222222',
  borderVisible: '#333333',
  textDisabled: '#666666',
  textSecondary: '#999999',
  textPrimary: '#E8E8E8',
  textDisplay: '#FFFFFF',
  accent: '#D71921',
  success: '#4A9E5C',
  warning: '#D4A843',
  claudeOrange: '#D97757',
};

// ─── Demo data ───
const DEMO_AGENTS = [
  { id: 1, project: 'danotch', prompt: 'implement scheduled tasks with notifications...', cpu: 12.3, mem: 245, elapsed: '4m12s', status: 'running' as const, liveState: 'toolUse' as const, liveLabel: 'EDITING FILE', liveDetail: 'Views/NotchContentView.swift' },
  { id: 2, project: 'portfolio-site', prompt: 'fix the responsive layout on mobile...', cpu: 0.1, mem: 180, elapsed: '22m8s', status: 'idle' as const, liveState: 'idle' as const, liveLabel: '', liveDetail: '' },
  { id: 3, project: 'api-server', prompt: 'add rate limiting middleware to all routes', cpu: 8.7, mem: 312, elapsed: '1m44s', status: 'running' as const, liveState: 'responding' as const, liveLabel: 'RESPONDING', liveDetail: 'I\'ll add express-rate-limit to the...' },
];

const DEMO_SCHEDULED = [
  { id: 1, name: 'Stock Price Alert', schedule: 'Every 30 min', enabled: true, lastStatus: 'completed', runCount: 14, notify: true },
  { id: 2, name: 'Daily Email Summary', schedule: 'Daily at 09:00', enabled: true, lastStatus: 'completed', runCount: 7, notify: true },
  { id: 3, name: 'Backup DB', schedule: 'Every 6 hours', enabled: false, lastStatus: 'failed', runCount: 3, notify: false },
];

const DEMO_TASKS = [
  { id: 't1', name: 'Implement Auth Flow', status: 'completed' as const, elapsed: '2m30s' },
  { id: 't2', name: 'Fix WebSocket Reconnect', status: 'running' as const, elapsed: '45s' },
];

const DEMO_CHAT: DemoChatMsg[] = [
  { role: 'user', content: 'Add a delete button to each notification row' },
  { role: 'tool', content: '', toolName: 'Read', toolDetail: 'NotchShellView.swift' },
  { role: 'tool', content: '', toolName: 'Edit', toolDetail: 'NotchShellView.swift' },
  { role: 'assistant', content: 'Done! I\'ve added a trash icon button to each `NotificationRunRow`. It calls `deleteNotification(id)` on the ViewModel and removes it with a fade animation.' },
];

const DEMO_NOTIFICATIONS = [
  { id: 1, title: 'Stock Price Alert', body: 'AAPL dropped below $200 — currently at $197.42', unread: true, time: '2m ago' },
  { id: 2, title: 'Daily Email Summary', body: '3 new emails: 1 from GitHub, 2 from Linear', unread: true, time: '1h ago' },
  { id: 3, title: 'Stock Price Alert', body: 'AAPL is at $201.30 — above threshold', unread: false, time: '3h ago' },
];

const STATS = {
  cpu: 34, ram: 62, netDown: '12.4 MB/s', netUp: '2.1 MB/s',
  disk: 71, diskUsed: '285 GB', diskTotal: '500 GB', processes: 312, uptime: '4d 7h 22m',
};

type DemoChatMsg = { role: 'user' | 'assistant' | 'tool'; content: string; toolName?: string; toolDetail?: string; pending?: boolean };
export type ViewState = 'overview' | 'agents' | 'stats' | 'chat' | 'notifications' | 'settings';
type NotchDisplay = 'expanded' | 'collapsed' | 'peek';
type PinnedWidget = 'calendar' | 'music' | 'ram' | 'network' | 'disk' | 'uptime';

// ─── Demo sequence definitions ───
const CODE_EXEC_CHAT: DemoChatMsg[] = [
  { role: 'user', content: 'Run ls -la in the project directory' },
  { role: 'tool', content: '', toolName: 'bash_execute', toolDetail: 'ls -la', pending: true },
  { role: 'tool', content: '', toolName: 'bash_execute', toolDetail: 'ls -la' },
  { role: 'assistant', content: 'Here\'s your directory listing — 12 files, 3 directories. The largest file is `Package.resolved` at 42KB.' },
];

const WEB_SEARCH_CHAT: DemoChatMsg[] = [
  { role: 'user', content: 'What\'s the current price of AAPL?' },
  { role: 'tool', content: '', toolName: 'web_search', toolDetail: 'AAPL stock price current', pending: true },
  { role: 'tool', content: '', toolName: 'web_search', toolDetail: 'AAPL stock price current' },
  { role: 'tool', content: '', toolName: 'web_fetch', toolDetail: 'finance.yahoo.com/quote/AAPL' },
  { role: 'assistant', content: 'AAPL is trading at **$198.50**, down 1.2% today. The 52-week range is $164.08–$260.10.' },
];

const WIDGET_SETS: PinnedWidget[][] = [
  ['calendar', 'music'],
  ['ram', 'network'],
  ['disk', 'uptime'],
];

// ─── Sparkline mini component ───
function Sparkline({ data, color, height = 20, width = 60 }: { data: number[]; color: string; height?: number; width?: number }) {
  const max = Math.max(...data, 1);
  const stepped: string[] = [];
  for (let i = 0; i < data.length; i++) {
    const x = (i / (data.length - 1)) * width;
    const y = height - (data[i] / max) * height;
    if (i > 0) stepped.push(`${((i - 1) / (data.length - 1)) * width},${y}`);
    stepped.push(`${x},${y}`);
  }
  return (
    <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`} className="overflow-visible">
      <polyline points={stepped.join(' ')} fill="none" stroke={color} strokeWidth="1.5" opacity={0.7} />
      <circle cx={width} cy={height - (data[data.length - 1] / max) * height} r="2" fill={color} opacity={0.9} />
    </svg>
  );
}

// ─── Arc gauge ───
function ArcGauge({ value, label, color, unit, size = 60 }: { value: number; label: string; color: string; unit: string; size?: number }) {
  const ticks = 36;
  const filled = Math.round((value / 100) * ticks);
  const r = size * 0.43;
  const cx = size / 2;
  const cy = size / 2;
  return (
    <div className="flex flex-col items-center gap-1">
      <span style={{ color: DN.textDisabled, fontSize: 7, fontFamily: 'monospace', letterSpacing: 1.5, textTransform: 'uppercase' }}>{label}</span>
      <div className="relative" style={{ width: size, height: size * 0.87 }}>
        <svg width={size} height={size * 0.87} viewBox={`0 0 ${size} ${size * 0.87}`}>
          {Array.from({ length: ticks }).map((_, i) => {
            const angle = 135 + (i / ticks) * 270;
            const rad = (angle * Math.PI) / 180;
            const x1 = cx + (r - 4) * Math.cos(rad), y1 = cy + (r - 4) * Math.sin(rad);
            const x2 = cx + r * Math.cos(rad), y2 = cy + r * Math.sin(rad);
            return <line key={i} x1={x1} y1={y1} x2={x2} y2={y2} stroke={i < filled ? color : 'rgba(255,255,255,0.06)'} strokeWidth={1.5} strokeLinecap="round" opacity={i < filled ? (i >= filled - 3 ? 1 : 0.7) : 1} />;
          })}
        </svg>
        <div className="absolute inset-0 flex flex-col items-center justify-center" style={{ top: 6 }}>
          <span style={{ fontSize: size * 0.27, fontFamily: 'monospace', fontWeight: 300, color: DN.textDisplay }}>{value}</span>
          <span style={{ fontSize: 6, fontFamily: 'monospace', letterSpacing: 1, color: DN.textDisabled, textTransform: 'uppercase' }}>{unit}</span>
        </div>
      </div>
    </div>
  );
}

function PulsingDot({ color, size = 4 }: { color: string; size?: number }) {
  return (
    <motion.div animate={{ opacity: [1, 0.4, 1] }} transition={{ duration: 1, repeat: Infinity, ease: 'easeInOut' }}
      style={{ width: size, height: size, borderRadius: '50%', backgroundColor: color, flexShrink: 0 }} />
  );
}

// ─── Mini widgets for left column (pinnable utils demo) ───
function MiniCalendarWidget({ today, calDays }: { today: number; calDays: (number | null)[] }) {
  return (
    <div>
      <div className="flex items-center justify-between mb-1">
        <span style={{ fontSize: 8, fontFamily: 'monospace', letterSpacing: 1.5, color: DN.textDisabled, textTransform: 'uppercase' }}>{new Date().toLocaleDateString('en-US', { month: 'short' })}</span>
        <span style={{ fontSize: 8, fontFamily: 'monospace', color: DN.textDisabled }}>{new Date().getFullYear()}</span>
      </div>
      <div className="grid grid-cols-7 gap-px">
        {['S', 'M', 'T', 'W', 'T', 'F', 'S'].map((d, i) => (
          <div key={i} className="flex items-center justify-center" style={{ width: 18, height: 14, fontSize: 7, fontFamily: 'monospace', color: DN.textDisabled }}>{d}</div>
        ))}
        {calDays.map((d, i) => (
          <div key={i} className="flex items-center justify-center" style={{ width: 18, height: 16, fontSize: 8, fontFamily: 'monospace', color: d === today ? DN.black : d ? DN.textSecondary : 'transparent', fontWeight: d === today ? 700 : 400, backgroundColor: d === today ? DN.textDisplay : 'transparent', borderRadius: d === today ? '50%' : 0 }}>{d ?? ''}</div>
        ))}
      </div>
    </div>
  );
}

function MiniMusicWidget({ isPlaying, setIsPlaying }: { isPlaying: boolean; setIsPlaying: (v: boolean) => void }) {
  return (
    <div className="flex items-center gap-2 group">
      <div className="w-[30px] h-[30px] rounded flex items-center justify-center shrink-0" style={{ backgroundColor: DN.surface }}><Music size={12} style={{ color: DN.textDisabled }} /></div>
      <div className="flex-1 min-w-0">
        <div className="truncate" style={{ fontSize: 10, color: DN.textPrimary, fontWeight: 500 }}>Blinding Lights</div>
        <div className="truncate" style={{ fontSize: 8, fontFamily: 'monospace', color: DN.textDisabled }}>The Weeknd</div>
      </div>
      <div className="flex items-center gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
        <button className="p-0.5" style={{ color: DN.textSecondary }}><SkipBack size={8} /></button>
        <button className="p-0.5" style={{ color: DN.textSecondary }} onClick={() => setIsPlaying(!isPlaying)}>{isPlaying ? <Pause size={9} /> : <Play size={9} />}</button>
        <button className="p-0.5" style={{ color: DN.textSecondary }}><SkipForward size={8} /></button>
      </div>
    </div>
  );
}

function MiniRAMWidget() {
  return (
    <div className="flex items-center gap-2">
      <ArcGauge value={STATS.ram} label="RAM" color={DN.warning} unit="%" size={44} />
      <div>
        <div style={{ fontSize: 7, fontFamily: 'monospace', color: DN.textDisabled }}>10.2 / 16.0 GB</div>
      </div>
    </div>
  );
}

function MiniNetworkWidget({ sparkData }: { sparkData: { netDown: number[]; netUp: number[] } }) {
  return (
    <div className="space-y-1">
      <div className="flex items-center gap-1.5">
        <ArrowDown size={7} style={{ color: DN.success }} />
        <span style={{ fontSize: 6, fontFamily: 'monospace', letterSpacing: 0.8, color: DN.textDisabled }}>DOWN</span>
        <Sparkline data={sparkData.netDown} color={DN.success} height={12} width={50} />
        <span style={{ fontSize: 8, fontFamily: 'monospace', color: DN.success }}>{STATS.netDown}</span>
      </div>
      <div className="flex items-center gap-1.5">
        <ArrowUp size={7} style={{ color: DN.warning }} />
        <span style={{ fontSize: 6, fontFamily: 'monospace', letterSpacing: 0.8, color: DN.textDisabled }}>UP</span>
        <Sparkline data={sparkData.netUp} color={DN.warning} height={12} width={50} />
        <span style={{ fontSize: 8, fontFamily: 'monospace', color: DN.warning }}>{STATS.netUp}</span>
      </div>
    </div>
  );
}

function MiniDiskWidget() {
  return (
    <div className="flex items-center gap-2">
      <div className="relative" style={{ width: 36, height: 36 }}>
        <svg width={36} height={36}>
          <circle cx={18} cy={18} r={14} fill="none" stroke="rgba(255,255,255,0.06)" strokeWidth={3} />
          <circle cx={18} cy={18} r={14} fill="none" stroke={DN.textSecondary} strokeWidth={3} strokeDasharray={`${(STATS.disk / 100) * 88} 88`} transform="rotate(-90 18 18)" strokeLinecap="round" />
        </svg>
        <div className="absolute inset-0 flex items-center justify-center">
          <HardDrive size={10} style={{ color: DN.textDisabled }} />
        </div>
      </div>
      <div>
        <div style={{ fontSize: 11, fontFamily: 'monospace', fontWeight: 500, color: DN.textPrimary }}>{STATS.disk}%</div>
        <div style={{ fontSize: 7, fontFamily: 'monospace', color: DN.textDisabled }}>{STATS.diskUsed}/{STATS.diskTotal}</div>
      </div>
    </div>
  );
}

function MiniUptimeWidget() {
  return (
    <div className="flex items-center gap-2">
      <Clock size={14} style={{ color: DN.textDisabled }} />
      <div>
        <div style={{ fontSize: 7, fontFamily: 'monospace', letterSpacing: 1, color: DN.textDisabled }}>UPTIME</div>
        <div style={{ fontSize: 12, fontFamily: 'monospace', fontWeight: 500, color: DN.textPrimary }}>{STATS.uptime}</div>
      </div>
    </div>
  );
}

// ─── Main NotchDemo component ───
export default function NotchDemo({ autoPlay = true, startExpanded = false, forceView, forceSequence, compact = false }: {
  autoPlay?: boolean; startExpanded?: boolean; forceView?: ViewState; forceSequence?: string; compact?: boolean;
}) {
  const [isExpanded, setIsExpanded] = useState(startExpanded);
  const [view, setView] = useState<ViewState>(forceView ?? 'overview');
  const [notchDisplay, setNotchDisplay] = useState<NotchDisplay>(startExpanded ? 'expanded' : 'collapsed');
  const [currentTime, setCurrentTime] = useState(new Date());
  const [isPlaying, setIsPlaying] = useState(true);
  const [collapsedSections, setCollapsedSections] = useState<Set<string>>(new Set());
  const [chatInput] = useState('');
  const [typingDemo, setTypingDemo] = useState('');
  const [showTypingCursor, setShowTypingCursor] = useState(false);
  const seqTimers = useRef<ReturnType<typeof setTimeout>[]>([]);
  const userInteracted = useRef(false);
  const [sparkData, setSparkData] = useState(() => ({
    cpu: Array.from({ length: 20 }, () => 20 + Math.random() * 40),
    ram: Array.from({ length: 20 }, () => 50 + Math.random() * 25),
    netDown: Array.from({ length: 12 }, () => Math.random() * 15),
    netUp: Array.from({ length: 12 }, () => Math.random() * 5),
  }));
  const [liveStats, setLiveStats] = useState({ cpu: STATS.cpu, ram: STATS.ram });

  // Animate stats values every 2s
  useEffect(() => {
    const t = setInterval(() => {
      setLiveStats(prev => ({
        cpu: Math.max(5, Math.min(95, prev.cpu + Math.round((Math.random() - 0.5) * 12))),
        ram: Math.max(40, Math.min(85, prev.ram + Math.round((Math.random() - 0.5) * 6))),
      }));
      setSparkData(prev => ({
        cpu: [...prev.cpu.slice(1), 20 + Math.random() * 50],
        ram: [...prev.ram.slice(1), 45 + Math.random() * 30],
        netDown: [...prev.netDown.slice(1), Math.random() * 18],
        netUp: [...prev.netUp.slice(1), Math.random() * 6],
      }));
    }, 2000);
    return () => clearInterval(t);
  }, []);

  // Demo sequence state
  const [demoMessages, setDemoMessages] = useState<DemoChatMsg[] | null>(null);
  const [demoChatTitle, setDemoChatTitle] = useState('');
  const [demoPinnedWidgets, setDemoPinnedWidgets] = useState<PinnedWidget[]>(['calendar', 'music']);
  const [peekTitle, setPeekTitle] = useState('');
  const [demoExpandNotif, setDemoExpandNotif] = useState<number | null>(null);
  const [demoScrollSettings, setDemoScrollSettings] = useState(false);

  // Sync forceView from parent
  useEffect(() => {
    if (forceView !== undefined) {
      setView(forceView);
      setNotchDisplay('expanded');
      setIsExpanded(true);
    }
  }, [forceView]);

  // Run demo sequences
  useEffect(() => {
    // Clear previous sequence timers
    seqTimers.current.forEach(t => clearTimeout(t));
    seqTimers.current = [];

    if (!forceSequence) {
      setDemoMessages(null);
      setDemoChatTitle('');
      setDemoPinnedWidgets(['calendar', 'music']);
      return;
    }

    const schedule = (delay: number, fn: () => void) => {
      seqTimers.current.push(setTimeout(fn, delay));
    };

    if (forceSequence === 'code-exec') {
      setDemoMessages([]);
      setDemoChatTitle('Code Execution');
      schedule(500, () => setDemoMessages([CODE_EXEC_CHAT[0]]));
      schedule(1500, () => setDemoMessages([CODE_EXEC_CHAT[0], CODE_EXEC_CHAT[1]]));
      schedule(3000, () => setDemoMessages([CODE_EXEC_CHAT[0], CODE_EXEC_CHAT[2]]));
      schedule(4000, () => setDemoMessages([CODE_EXEC_CHAT[0], CODE_EXEC_CHAT[2], CODE_EXEC_CHAT[3]]));
    } else if (forceSequence === 'web-search') {
      setDemoMessages([]);
      setDemoChatTitle('Web Search');
      schedule(500, () => setDemoMessages([WEB_SEARCH_CHAT[0]]));
      schedule(1500, () => setDemoMessages([WEB_SEARCH_CHAT[0], WEB_SEARCH_CHAT[1]]));
      schedule(2800, () => setDemoMessages([WEB_SEARCH_CHAT[0], WEB_SEARCH_CHAT[2]]));
      schedule(3800, () => setDemoMessages([WEB_SEARCH_CHAT[0], WEB_SEARCH_CHAT[2], WEB_SEARCH_CHAT[3]]));
      schedule(4800, () => setDemoMessages([WEB_SEARCH_CHAT[0], WEB_SEARCH_CHAT[2], WEB_SEARCH_CHAT[3], WEB_SEARCH_CHAT[4]]));
    } else if (forceSequence === 'scheduled') {
      // Collapse agents and tasks, only show scheduled expanded
      setCollapsedSections(new Set(['agents', 'tasks']));
    } else if (forceSequence === 'notif-peek') {
      // Overview → collapse → peek → expand to notifications
      setNotchDisplay('expanded');
      setView('overview');
      setIsExpanded(true);
      schedule(1200, () => { setNotchDisplay('collapsed'); setIsExpanded(false); });
      schedule(2500, () => { setNotchDisplay('peek'); setPeekTitle('AAPL dropped below $200 — currently at $197.42'); });
      schedule(5000, () => { setNotchDisplay('expanded'); setIsExpanded(true); setView('notifications'); });
    } else if (forceSequence === 'pin-utils') {
      setView('overview');
      setDemoPinnedWidgets(WIDGET_SETS[0]);
      schedule(2500, () => setDemoPinnedWidgets([...WIDGET_SETS[1]]));
      schedule(5000, () => setDemoPinnedWidgets([...WIDGET_SETS[2]]));
    }

    return () => {
      seqTimers.current.forEach(t => clearTimeout(t));
      seqTimers.current = [];
    };
  }, [forceSequence]);

  // Clock
  useEffect(() => {
    const t = setInterval(() => setCurrentTime(new Date()), 1000);
    return () => clearInterval(t);
  }, []);

  // Auto-play tour — rich demo with dropdowns, tabs, chats, typing
  const autoTimers = useRef<ReturnType<typeof setTimeout>[]>([]);

  const clearAutoPlay = () => {
    autoTimers.current.forEach(t => clearTimeout(t));
    autoTimers.current = [];
  };

  const resetToDefault = () => {
    setView('overview');
    setNotchDisplay('expanded');
    setIsExpanded(true);
    setCollapsedSections(new Set());
    setDemoMessages(null);
    setDemoChatTitle('');
    setTypingDemo('');
    setShowTypingCursor(false);
    setDemoPinnedWidgets(['calendar', 'music']);
  };

  const startAutoPlay = useCallback(() => {
    clearAutoPlay();
    userInteracted.current = false;

    const sched = (ms: number, fn: () => void) => {
      autoTimers.current.push(setTimeout(() => { if (!userInteracted.current) fn(); }, ms));
    };

    // Reset state
    resetToDefault();

    // Overview: expand agents, show all sections
    let t = 0;
    sched(t += 500, () => { setIsExpanded(true); setNotchDisplay('expanded'); });

    // Toggle Claude Code open (already open), then collapse it
    sched(t += 2000, () => setCollapsedSections(new Set(['agents'])));
    // Expand scheduled
    sched(t += 1200, () => setCollapsedSections(new Set(['agents', 'tasks'])));
    // Collapse scheduled, expand tasks
    sched(t += 1500, () => setCollapsedSections(new Set(['scheduled'])));
    // Open all
    sched(t += 1200, () => setCollapsedSections(new Set()));

    // Switch to agents tab
    sched(t += 1500, () => setView('agents'));

    // Open a chat
    sched(t += 2000, () => {
      setView('chat');
      setDemoMessages([]);
      setDemoChatTitle('New Chat');
    });

    // Type a message
    sched(t += 500, () => {
      setShowTypingCursor(true);
      const text = 'Notify me when AAPL drops below $190';
      let i = 0;
      const typeInterval = setInterval(() => {
        if (userInteracted.current) { clearInterval(typeInterval); return; }
        if (i < text.length) { setTypingDemo(text.slice(0, i + 1)); i++; }
        else {
          clearInterval(typeInterval);
          autoTimers.current.push(setTimeout(() => {
            if (userInteracted.current) return;
            setShowTypingCursor(false);
            setTypingDemo('');
            setDemoChatTitle('Stock Alert');
            setDemoMessages([{ role: 'user', content: text }]);
          }, 800));
          autoTimers.current.push(setTimeout(() => {
            if (userInteracted.current) return;
            setDemoMessages([
              { role: 'user', content: text },
              { role: 'tool', content: '', toolName: 'create_scheduled_task', toolDetail: 'AAPL price monitor', pending: true },
            ]);
          }, 2000));
          autoTimers.current.push(setTimeout(() => {
            if (userInteracted.current) return;
            setDemoMessages([
              { role: 'user', content: text },
              { role: 'tool', content: '', toolName: 'create_scheduled_task', toolDetail: 'AAPL price monitor' },
            ]);
          }, 3200));
          autoTimers.current.push(setTimeout(() => {
            if (userInteracted.current) return;
            setDemoMessages([
              { role: 'user', content: text },
              { role: 'tool', content: '', toolName: 'create_scheduled_task', toolDetail: 'AAPL price monitor' },
              { role: 'assistant', content: 'Done! I\'ve created a scheduled task that checks AAPL every 30 minutes and notifies you when it drops below $190.' },
            ]);
          }, 4500));
        }
      }, 40);
    });

    // After chat demo, go to stats
    sched(t += 8500, () => { setView('stats'); setDemoMessages(null); setDemoChatTitle(''); });

    // Then notifications
    sched(t += 3000, () => { setView('notifications'); setDemoExpandNotif(null); });
    sched(t += 1000, () => setDemoExpandNotif(0));

    // Then settings — scroll to bottom after a moment
    sched(t += 3000, () => { setView('settings'); setDemoScrollSettings(false); });
    sched(t += 1500, () => setDemoScrollSettings(true));

    // Back to overview with pinnable utils cycling
    sched(t += 3000, () => { setView('overview'); setCollapsedSections(new Set(['agents', 'scheduled', 'tasks'])); setDemoPinnedWidgets(['calendar', 'music']); });
    sched(t += 2000, () => setDemoPinnedWidgets([...WIDGET_SETS[1]]));
    sched(t += 2000, () => setDemoPinnedWidgets([...WIDGET_SETS[2]]));
    sched(t += 2000, () => setDemoPinnedWidgets(['calendar', 'music']));

    // Reset and restart loop
    sched(t += 2000, () => { resetToDefault(); });
    sched(t += 1000, () => startAutoPlay());
  }, []);

  useEffect(() => {
    if (autoPlay && !forceSequence) {
      const t = setTimeout(() => startAutoPlay(), 500);
      return () => { clearTimeout(t); clearAutoPlay(); };
    }
  }, [autoPlay, forceSequence, startAutoPlay]);

  const handleUserInteraction = (newView?: ViewState) => {
    userInteracted.current = true;
    clearAutoPlay();
    setNotchDisplay('expanded');
    if (!isExpanded) setIsExpanded(true);
    if (newView) setView(newView);
  };

  // When mouse leaves the notch, restart autoplay after a delay
  const handleMouseLeave = () => {
    if (!autoPlay || forceSequence) return;
    if (!userInteracted.current) return;
    // Restart autoplay after 3 seconds of no interaction
    const restartTimer = setTimeout(() => {
      startAutoPlay();
    }, 3000);
    autoTimers.current.push(restartTimer);
  };

  const toggleSection = (id: string) => {
    setCollapsedSections(prev => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  };

  const isSectionExpanded = (id: string) => !collapsedSections.has(id);

  const hours = currentTime.getHours();
  const minutes = currentTime.getMinutes().toString().padStart(2, '0');
  const ampm = hours >= 12 ? 'PM' : 'AM';
  const h12 = hours % 12 || 12;
  const dateStr = currentTime.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' }).toUpperCase();
  const today = currentTime.getDate();
  const year = currentTime.getFullYear();
  const month = currentTime.getMonth();
  const firstDay = new Date(year, month, 1).getDay();
  const daysInMonth = new Date(year, month + 1, 0).getDate();
  const calDays: (number | null)[] = Array(firstDay).fill(null);
  for (let d = 1; d <= daysInMonth; d++) calDays.push(d);

  const isHome = view === 'overview';
  const isAgents = view === 'agents' || view === 'chat';
  const isStats = view === 'stats';
  const isNotifs = view === 'notifications';
  const isSettings = view === 'settings';

  // Notch dimensions based on display state
  const baseWidth = compact ? 420 : 520;
  const baseHeight = compact ? 320 : 380;
  const notchWidth = notchDisplay === 'expanded' ? baseWidth : notchDisplay === 'peek' ? (compact ? 280 : 340) : (compact ? 160 : 200);
  const notchHeight = notchDisplay === 'expanded' ? baseHeight : notchDisplay === 'peek' ? 44 : 32;
  const notchRadius = notchDisplay === 'expanded' ? 16 : notchDisplay === 'peek' ? 12 : 8;

  return (
    <div className="flex flex-col items-center">
      <motion.div
        className="relative cursor-pointer select-none overflow-hidden"
        style={{
          backgroundColor: DN.black,
          borderBottomLeftRadius: notchRadius,
          borderBottomRightRadius: notchRadius,
          borderTopLeftRadius: 0, borderTopRightRadius: 0,
          border: notchDisplay === 'expanded' ? `1px solid ${DN.border}` : '1px solid transparent',
          borderTop: 'none',
          pointerEvents: forceSequence ? 'none' : 'auto',
        }}
        animate={{ width: notchWidth, height: notchHeight }}
        transition={{ duration: 0.35, ease: [0.25, 0.1, 0.25, 1] }}
        onMouseEnter={() => { if (!userInteracted.current && !isExpanded) { userInteracted.current = true; setIsExpanded(true); setNotchDisplay('expanded'); } }}
        onMouseLeave={handleMouseLeave}
        onClick={() => { if (!isExpanded) handleUserInteraction(); }}
      >
        {/* Dot grid background */}
        <AnimatePresence>
          {notchDisplay === 'expanded' && (
            <motion.div className="absolute inset-0 pointer-events-none overflow-hidden" initial={{ opacity: 0 }} animate={{ opacity: 0.04 }} exit={{ opacity: 0 }} style={{ zIndex: 0 }}>
              <svg width="100%" height="100%">
                <pattern id="dotgrid" width="16" height="16" patternUnits="userSpaceOnUse"><circle cx="8" cy="8" r="0.8" fill="white" /></pattern>
                <rect width="100%" height="100%" fill="url(#dotgrid)" />
              </svg>
            </motion.div>
          )}
        </AnimatePresence>

        {/* Collapsed state */}
        {notchDisplay === 'collapsed' && (
          <div className="flex items-center justify-center h-full">
            <div className="w-2.5 h-2.5 rounded-full" style={{ backgroundColor: DN.borderVisible }} />
          </div>
        )}

        {/* Peek state — notification preview */}
        <AnimatePresence>
          {notchDisplay === 'peek' && (
            <motion.div
              className="flex items-center gap-2 h-full px-4"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              transition={{ duration: 0.2 }}
            >
              <div className="w-2 h-2 rounded-full shrink-0" style={{ backgroundColor: DN.accent }} />
              <span style={{ fontSize: 9, fontFamily: 'monospace', fontWeight: 600, color: DN.textPrimary }}>Stock Price Alert</span>
              <span className="flex-1 truncate" style={{ fontSize: 9, color: DN.textSecondary }}>{peekTitle}</span>
            </motion.div>
          )}
        </AnimatePresence>

        {/* Expanded content */}
        <AnimatePresence>
          {notchDisplay === 'expanded' && (
            <motion.div
              className="flex flex-col h-full relative"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              transition={{ duration: 0.2, delay: 0.15 }}
              style={{ zIndex: 1 }}
            >
              {/* Top bar */}
              <div className="flex items-center px-3 shrink-0" style={{ height: 32, borderBottom: `1px solid ${DN.border}` }}>
                <div className="flex items-center gap-1">
                  <TabButton active={isHome} onClick={() => handleUserInteraction('overview')} icon={null}>HOME</TabButton>
                  <TabButton active={isAgents} onClick={() => handleUserInteraction('agents')} icon={null}>AGENTS</TabButton>
                </div>
                <div className="flex-1" />
                <div className="flex items-center gap-1">
                  <TabButton active={isStats} onClick={() => handleUserInteraction('stats')} icon={<Cpu size={10} />}>STATS</TabButton>
                  <button onClick={() => handleUserInteraction('notifications')} className="relative flex items-center justify-center w-6 h-6 transition-colors" style={{ color: isNotifs ? DN.textDisplay : DN.textSecondary }}>
                    <Bell size={10} />
                    <div className="absolute top-1 right-1 w-1.5 h-1.5 rounded-full" style={{ backgroundColor: DN.accent }} />
                  </button>
                  <button onClick={() => handleUserInteraction('settings')} className="flex items-center justify-center w-6 h-6 transition-colors" style={{ color: isSettings ? DN.textDisplay : DN.textSecondary }}>
                    <Settings size={10} />
                  </button>
                  <div className="flex items-center gap-1 ml-1">
                    <span style={{ fontSize: 9, fontFamily: 'monospace', color: DN.textSecondary }}>100%</span>
                    <div className="relative" style={{ width: 18, height: 9 }}>
                      <div className="absolute inset-0 rounded-sm" style={{ border: `1px solid ${DN.borderVisible}` }} />
                      <div className="absolute left-0.5 top-0.5 bottom-0.5 rounded-[1px]" style={{ width: '90%', backgroundColor: DN.textPrimary }} />
                    </div>
                  </div>
                </div>
              </div>

              {/* Main content area */}
              <div className="flex-1 overflow-hidden">
                <AnimatePresence mode="wait">
                  {view === 'overview' && <OverviewView key="overview" h12={h12} minutes={minutes} ampm={ampm} dateStr={dateStr} today={today} calDays={calDays} isPlaying={isPlaying} setIsPlaying={setIsPlaying} isSectionExpanded={isSectionExpanded} toggleSection={toggleSection} handleUserInteraction={handleUserInteraction} pinnedWidgets={demoPinnedWidgets} sparkData={sparkData} />}
                  {view === 'agents' && <AgentsView key="agents" isSectionExpanded={isSectionExpanded} toggleSection={toggleSection} handleUserInteraction={handleUserInteraction} />}
                  {view === 'chat' && <ChatView key="chat" onBack={() => handleUserInteraction('agents')} typingDemo={typingDemo} showTypingCursor={showTypingCursor} chatInput={chatInput} messages={demoMessages ?? DEMO_CHAT} chatTitle={demoChatTitle || 'Add Notification Delete'} />}
                  {view === 'stats' && <StatsView key="stats" sparkData={sparkData} liveStats={liveStats} />}
                  {view === 'notifications' && <NotificationsView key="notifications" forceExpanded={demoExpandNotif} />}
                  {view === 'settings' && <SettingsView key="settings" scrollToBottom={demoScrollSettings} />}
                </AnimatePresence>
              </div>
            </motion.div>
          )}
        </AnimatePresence>
      </motion.div>

      <AnimatePresence>
        {notchDisplay === 'collapsed' && !forceSequence && (
          <motion.p initial={{ opacity: 0, y: -5 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }} transition={{ delay: 0.5 }}
            className="mt-4 text-xs" style={{ color: 'rgba(255,255,255,0.3)', fontFamily: 'monospace' }}>
            hover or click to expand
          </motion.p>
        )}
      </AnimatePresence>
    </div>
  );
}

// ─── Tab button ───
function TabButton({ active, onClick, icon, children }: { active: boolean; onClick: () => void; icon: React.ReactNode; children: React.ReactNode }) {
  return (
    <button onClick={onClick} className="flex items-center gap-1 px-1.5 py-0.5 transition-colors"
      style={{ fontSize: 9, fontFamily: 'monospace', letterSpacing: 1.2, color: active ? DN.textDisplay : DN.textSecondary, fontWeight: active ? 600 : 400 }}>
      {icon}
      {active ? `[ ${children} ]` : children}
    </button>
  );
}

// ─── OVERVIEW VIEW ───
function OverviewView({ h12, minutes, ampm, dateStr, today, calDays, isPlaying, setIsPlaying, isSectionExpanded, toggleSection, handleUserInteraction, pinnedWidgets, sparkData }: any) {
  return (
    <motion.div initial={{ opacity: 0, x: -10 }} animate={{ opacity: 1, x: 0 }} exit={{ opacity: 0, x: -10 }} transition={{ duration: 0.2 }} className="flex h-full">
      {/* Left column */}
      <div className="flex flex-col gap-1 px-2.5 py-2" style={{ width: 175, flexShrink: 0 }}>
        <span style={{ fontSize: 11, color: DN.textDisabled }}>Hi, Nihal</span>
        <div className="flex items-baseline gap-1">
          <span style={{ fontSize: 32, fontFamily: 'monospace', fontWeight: 300, color: DN.textDisplay, letterSpacing: -1 }}>{h12}:{minutes}</span>
          <span style={{ fontSize: 9, fontFamily: 'monospace', letterSpacing: 0.8, color: DN.textDisabled }}>{ampm}</span>
        </div>
        <span style={{ fontSize: 9, fontFamily: 'monospace', letterSpacing: 1.2, color: DN.textSecondary }}>{dateStr}</span>

        {/* Pinned widgets */}
        <AnimatePresence mode="wait">
          <motion.div key={(pinnedWidgets as PinnedWidget[]).join(',')} initial={{ opacity: 0, y: 5 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -5 }} transition={{ duration: 0.3 }} className="mt-1 space-y-2">
            {(pinnedWidgets as PinnedWidget[]).map((w: PinnedWidget) => (
              <div key={w}>
                {w === 'calendar' && <MiniCalendarWidget today={today} calDays={calDays} />}
                {w === 'music' && <MiniMusicWidget isPlaying={isPlaying} setIsPlaying={setIsPlaying} />}
                {w === 'ram' && <MiniRAMWidget />}
                {w === 'network' && <MiniNetworkWidget sparkData={sparkData} />}
                {w === 'disk' && <MiniDiskWidget />}
                {w === 'uptime' && <MiniUptimeWidget />}
              </div>
            ))}
          </motion.div>
        </AnimatePresence>
      </div>

      <div style={{ width: 1, backgroundColor: DN.border, margin: '8px 0' }} />

      {/* Right column */}
      <div className="flex-1 flex flex-col overflow-hidden px-2 py-2">
        <div className="flex-1 overflow-y-auto space-y-1.5" style={{ scrollbarWidth: 'none' }}>
          <div className="px-2" style={{ fontSize: 9, fontFamily: 'monospace', letterSpacing: 1.5, color: DN.textSecondary }}>AGENTS</div>
          <SectionCard>
            <SectionHeader icon={<Terminal size={10} style={{ color: DN.claudeOrange }} />} label="CLAUDE CODE" labelColor={DN.claudeOrange} count={DEMO_AGENTS.length} countColor={`${DN.claudeOrange}99`}
              rightContent={<div className="flex items-center gap-1"><PulsingDot color={DN.warning} size={4} /><span style={{ fontSize: 7, fontFamily: 'monospace', letterSpacing: 0.6, color: DN.warning }}>2 ACTIVE</span></div>}
              expanded={isSectionExpanded('agents')} onToggle={() => toggleSection('agents')} />
            <CollapseContent expanded={isSectionExpanded('agents')}><div>{DEMO_AGENTS.map(a => <AgentRow key={a.id} agent={a} onClick={() => handleUserInteraction('chat')} />)}</div></CollapseContent>
          </SectionCard>
          <SectionCard>
            <SectionHeader icon={<Clock size={9} style={{ color: DN.warning }} />} label="SCHEDULED" labelColor={DN.textSecondary} count={DEMO_SCHEDULED.filter(t => t.enabled).length} countColor={DN.textDisabled}
              expanded={isSectionExpanded('scheduled')} onToggle={() => toggleSection('scheduled')} />
            <CollapseContent expanded={isSectionExpanded('scheduled')}><div>{DEMO_SCHEDULED.map(t => <ScheduledRow key={t.id} task={t} />)}</div></CollapseContent>
          </SectionCard>
          <SectionCard>
            <SectionHeader icon={<Sparkles size={10} style={{ color: DN.textSecondary }} />} label="TASKS" labelColor={DN.textSecondary} count={DEMO_TASKS.length} countColor={DN.textDisabled}
              rightContent={<div className="flex items-center gap-1"><PulsingDot color={DN.warning} size={4} /><span style={{ fontSize: 7, fontFamily: 'monospace', letterSpacing: 0.6, color: DN.warning }}>1 ACTIVE</span></div>}
              expanded={isSectionExpanded('tasks')} onToggle={() => toggleSection('tasks')} />
            <CollapseContent expanded={isSectionExpanded('tasks')}><div>{DEMO_TASKS.map(t => <TaskRow key={t.id} task={t} onClick={() => handleUserInteraction('chat')} />)}</div></CollapseContent>
          </SectionCard>
        </div>
        <div className="mt-1.5 flex items-center gap-1.5 rounded-lg px-2 py-1.5" style={{ backgroundColor: DN.surface, border: `1px solid ${DN.border}` }}>
          <Sparkles size={9} style={{ color: DN.textDisabled }} />
          <span className="flex-1" style={{ fontSize: 11, color: DN.textDisabled }}>Ask anything...</span>
          <div className="w-[18px] h-[18px] rounded-full flex items-center justify-center" style={{ backgroundColor: DN.textDisplay }}><Send size={9} style={{ color: DN.black }} /></div>
        </div>
      </div>
    </motion.div>
  );
}

// ─── AGENTS VIEW ───
function AgentsView({ isSectionExpanded, toggleSection, handleUserInteraction }: any) {
  return (
    <motion.div initial={{ opacity: 0, x: 10 }} animate={{ opacity: 1, x: 0 }} exit={{ opacity: 0, x: 10 }} transition={{ duration: 0.2 }}
      className="flex flex-col h-full px-3 py-2 overflow-y-auto gap-1.5" style={{ scrollbarWidth: 'none' }}>
      <div style={{ fontSize: 9, fontFamily: 'monospace', letterSpacing: 1.5, color: DN.textSecondary }}>AGENTS</div>
      <SectionCard>
        <SectionHeader icon={<Terminal size={10} style={{ color: DN.claudeOrange }} />} label="CLAUDE CODE" labelColor={DN.claudeOrange} count={DEMO_AGENTS.length} countColor={`${DN.claudeOrange}99`}
          rightContent={<div className="flex items-center gap-1"><PulsingDot color={DN.warning} size={4} /><span style={{ fontSize: 7, fontFamily: 'monospace', letterSpacing: 0.6, color: DN.warning }}>2 ACTIVE</span></div>}
          expanded={isSectionExpanded('agents')} onToggle={() => toggleSection('agents')} />
        <CollapseContent expanded={isSectionExpanded('agents')}>{DEMO_AGENTS.map(a => <AgentRow key={a.id} agent={a} onClick={() => handleUserInteraction('chat')} />)}</CollapseContent>
      </SectionCard>
      <SectionCard>
        <SectionHeader icon={<Sparkles size={10} style={{ color: DN.textSecondary }} />} label="TASKS" labelColor={DN.textSecondary} count={DEMO_TASKS.length} countColor={DN.textDisabled}
          expanded={isSectionExpanded('tasks')} onToggle={() => toggleSection('tasks')} />
        <CollapseContent expanded={isSectionExpanded('tasks')}>{DEMO_TASKS.map(t => <TaskRow key={t.id} task={t} onClick={() => handleUserInteraction('chat')} />)}</CollapseContent>
      </SectionCard>
      <div className="flex items-center gap-2 mt-1">
        <div className="flex-1 h-px" style={{ backgroundColor: DN.border }} />
        <span style={{ fontSize: 8, fontFamily: 'monospace', letterSpacing: 1, color: DN.textDisabled }}>HISTORY</span>
        <div className="flex-1 h-px" style={{ backgroundColor: DN.border }} />
      </div>
      {[{ name: 'Fix WebSocket Reconnect', time: '2h ago' }, { name: 'Add Dark Mode Toggle', time: 'Yesterday' }, { name: 'Setup Supabase Auth', time: '3 days ago' }].map((t, i) => (
        <button key={i} onClick={() => handleUserInteraction('chat')} className="flex items-center justify-between px-2 py-1.5 rounded transition-colors hover:bg-white/5 w-full text-left">
          <span style={{ fontSize: 11, color: DN.textSecondary }}>{t.name}</span>
          <span style={{ fontSize: 8, fontFamily: 'monospace', color: DN.textDisabled }}>{t.time}</span>
        </button>
      ))}
    </motion.div>
  );
}

// ─── CHAT VIEW ───
function ChatView({ onBack, typingDemo, showTypingCursor, chatInput, messages, chatTitle }: {
  onBack: () => void; typingDemo: string; showTypingCursor: boolean; chatInput: string;
  messages: DemoChatMsg[]; chatTitle: string;
}) {
  return (
    <motion.div initial={{ opacity: 0, x: 10 }} animate={{ opacity: 1, x: 0 }} exit={{ opacity: 0, x: 10 }} transition={{ duration: 0.2 }} className="flex flex-col h-full">
      <div className="flex items-center gap-2 px-3 py-1.5 shrink-0" style={{ borderBottom: `1px solid ${DN.border}` }}>
        <button onClick={onBack} style={{ color: DN.textSecondary }}><ChevronLeft size={14} /></button>
        <div className="w-1.5 h-1.5 rounded-full" style={{ backgroundColor: DN.success }} />
        <span style={{ fontSize: 12, color: DN.textPrimary, fontWeight: 500 }}>{chatTitle}</span>
      </div>
      <div className="flex-1 overflow-y-auto px-3 py-2 space-y-2" style={{ scrollbarWidth: 'none' }}>
        <AnimatePresence>
          {messages.map((msg, i) => (
            <motion.div key={`${i}-${msg.role}-${msg.toolName ?? ''}`} initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: 0.25 }}>
              {msg.role === 'user' && (
                <div className="flex justify-end">
                  <div className="px-2.5 py-1.5 rounded-lg max-w-[80%]" style={{ backgroundColor: DN.surfaceRaised, border: `1px solid ${DN.borderVisible}` }}>
                    <span style={{ fontSize: 11, color: DN.textPrimary, fontWeight: 500 }}>{msg.content}</span>
                  </div>
                </div>
              )}
              {msg.role === 'tool' && (
                <div className="flex items-center gap-1.5 px-1 py-0.5 rounded" style={{ backgroundColor: `${DN.surface}66` }}>
                  <div className="w-3 h-3 flex items-center justify-center">
                    {msg.pending ? (
                      <motion.div animate={{ rotate: 360 }} transition={{ duration: 1, repeat: Infinity, ease: 'linear' }}>
                        <svg width={9} height={9} viewBox="0 0 16 16"><circle cx={8} cy={8} r={6} fill="none" stroke={DN.warning} strokeWidth={2} strokeDasharray="20 20" /></svg>
                      </motion.div>
                    ) : (
                      <svg width={9} height={9} viewBox="0 0 16 16"><circle cx={8} cy={8} r={8} fill={DN.success} /><path d="M5 8l2.5 2.5L11 6" stroke="white" strokeWidth={2} fill="none" /></svg>
                    )}
                  </div>
                  {msg.toolName === 'web_search' ? <Globe size={9} style={{ color: DN.textDisabled }} /> : msg.toolName === 'web_fetch' ? <Globe size={9} style={{ color: DN.textDisabled }} /> : <Hammer size={9} style={{ color: DN.textDisabled }} />}
                  <span style={{ fontSize: 9, fontFamily: 'monospace', color: DN.textSecondary, fontWeight: 500 }}>{msg.toolName}</span>
                  <span style={{ fontSize: 9, fontFamily: 'monospace', color: DN.textDisabled }}>{msg.toolDetail}</span>
                </div>
              )}
              {msg.role === 'assistant' && (
                <div className="pr-4"><span style={{ fontSize: 12, color: DN.textPrimary, lineHeight: 1.5 }}>{msg.content}</span></div>
              )}
            </motion.div>
          ))}
        </AnimatePresence>
      </div>
      <div className="px-3 pb-2">
        <div className="flex items-center gap-1.5 rounded-lg px-2 py-1.5" style={{ backgroundColor: DN.surface, border: `1px solid ${typingDemo || chatInput ? DN.borderVisible : DN.border}` }}>
          <Sparkles size={9} style={{ color: typingDemo ? DN.textSecondary : DN.textDisabled }} />
          <div className="flex-1 relative" style={{ fontSize: 11, color: typingDemo ? DN.textPrimary : DN.textDisabled }}>
            {typingDemo || chatInput || 'Message agent...'}
            {showTypingCursor && <motion.span animate={{ opacity: [1, 0] }} transition={{ duration: 0.5, repeat: Infinity }} className="inline-block ml-px" style={{ width: 1.5, height: 13, backgroundColor: DN.textPrimary, verticalAlign: 'text-bottom' }} />}
          </div>
          {(typingDemo || chatInput) && <div className="w-[18px] h-[18px] rounded-full flex items-center justify-center" style={{ backgroundColor: DN.textDisplay }}><Send size={9} style={{ color: DN.black }} /></div>}
        </div>
      </div>
    </motion.div>
  );
}

// ─── STATS VIEW ───
function StatsView({ sparkData, liveStats }: { sparkData: { cpu: number[]; ram: number[]; netDown: number[]; netUp: number[] }; liveStats: { cpu: number; ram: number } }) {
  const cpuColor = liveStats.cpu > 80 ? DN.accent : liveStats.cpu > 50 ? DN.warning : DN.success;
  const ramColor = liveStats.ram > 85 ? DN.accent : liveStats.ram > 60 ? DN.warning : DN.success;
  return (
    <motion.div initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: 10 }} transition={{ duration: 0.2 }}
      className="p-2.5 space-y-[5px] overflow-y-auto h-full" style={{ scrollbarWidth: 'none' }}>
      <div className="flex gap-[5px]">
        <GlassCell className="flex-1 flex items-center justify-center py-2"><ArcGauge value={liveStats.cpu} label="CPU" color={cpuColor} unit="%" /></GlassCell>
        <GlassCell className="flex-1 flex items-center justify-center py-2"><ArcGauge value={liveStats.ram} label="MEMORY" color={ramColor} unit="%" /></GlassCell>
      </div>
      <div className="flex gap-[5px]">
        <GlassCell className="flex-1 py-1.5 px-2">
          <div className="flex items-center gap-2 py-1">
            <ArrowDown size={9} style={{ color: DN.success }} /><span style={{ fontSize: 7, fontFamily: 'monospace', letterSpacing: 1, color: DN.textDisabled }}>DOWN</span>
            <Sparkline data={sparkData.netDown} color={DN.success} height={14} width={50} />
            <span style={{ fontSize: 9, fontFamily: 'monospace', color: DN.success, fontWeight: 500 }}>{STATS.netDown}</span>
          </div>
          <div className="h-px mx-2" style={{ backgroundColor: 'rgba(255,255,255,0.05)' }} />
          <div className="flex items-center gap-2 py-1">
            <ArrowUp size={9} style={{ color: DN.warning }} /><span style={{ fontSize: 7, fontFamily: 'monospace', letterSpacing: 1, color: DN.textDisabled }}>UP</span>
            <Sparkline data={sparkData.netUp} color={DN.warning} height={14} width={50} />
            <span style={{ fontSize: 9, fontFamily: 'monospace', color: DN.warning, fontWeight: 500 }}>{STATS.netUp}</span>
          </div>
        </GlassCell>
        <GlassCell className="flex flex-col items-center justify-center py-2" style={{ width: 100 }}>
          <span style={{ fontSize: 7, fontFamily: 'monospace', letterSpacing: 1, color: DN.textDisabled }}>DISK</span>
          <div className="relative my-1" style={{ width: 36, height: 36 }}>
            <svg width={36} height={36}>
              <circle cx={18} cy={18} r={15} fill="none" stroke="rgba(255,255,255,0.06)" strokeWidth={3} />
              <circle cx={18} cy={18} r={15} fill="none" stroke={DN.textSecondary} strokeWidth={3} strokeDasharray={`${(STATS.disk / 100) * 94.2} 94.2`} transform="rotate(-90 18 18)" strokeLinecap="round" />
            </svg>
          </div>
          <span style={{ fontSize: 9, fontFamily: 'monospace', color: DN.textPrimary, fontWeight: 500 }}>{STATS.disk}%</span>
          <span style={{ fontSize: 7, fontFamily: 'monospace', color: DN.textDisabled }}>{STATS.diskUsed}/{STATS.diskTotal}</span>
        </GlassCell>
      </div>
      <div className="flex gap-[5px]">
        <GlassCell className="flex-1 flex items-center justify-between px-3 py-2">
          <div>
            <div style={{ fontSize: 7, fontFamily: 'monospace', letterSpacing: 1.2, color: DN.textDisabled }}>PROCESSES</div>
            <div style={{ fontSize: 22, fontFamily: 'monospace', fontWeight: 300, color: DN.textDisplay }}>{STATS.processes}</div>
          </div>
          <div className="flex items-end gap-[2px] h-6">
            {[45, 30, 65, 20, 55].map((v, i) => <div key={i} style={{ width: 4, height: `${v}%`, backgroundColor: v > 50 ? DN.warning : `${DN.textSecondary}80`, borderRadius: 1 }} />)}
          </div>
          <ChevronRight size={9} style={{ color: DN.textDisabled }} />
        </GlassCell>
        <GlassCell className="flex flex-col items-center justify-center py-2" style={{ width: 80 }}>
          <Clock size={10} style={{ color: DN.textDisabled }} />
          <span className="mt-1" style={{ fontSize: 12, fontFamily: 'monospace', fontWeight: 500, color: DN.textPrimary }}>{STATS.uptime}</span>
          <span style={{ fontSize: 6, fontFamily: 'monospace', letterSpacing: 1, color: DN.textDisabled }}>UPTIME</span>
        </GlassCell>
      </div>
    </motion.div>
  );
}

// ─── NOTIFICATIONS VIEW ───
function NotificationsView({ forceExpanded }: { forceExpanded?: number | null }) {
  const [expanded, setExpanded] = useState<number | null>(null);
  useEffect(() => { if (forceExpanded !== undefined) setExpanded(forceExpanded); }, [forceExpanded]);
  return (
    <motion.div initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: 10 }} transition={{ duration: 0.2 }} className="flex flex-col h-full px-3 py-2">
      <div className="flex items-center justify-between mb-2">
        <span style={{ fontSize: 10, fontFamily: 'monospace', letterSpacing: 1.5, color: DN.textSecondary }}>NOTIFICATIONS</span>
        <button className="px-2 py-0.5 rounded" style={{ fontSize: 7, fontFamily: 'monospace', letterSpacing: 0.8, color: DN.textDisabled, border: `1px solid ${DN.border}` }}>MARK ALL READ</button>
      </div>
      <div className="flex-1 overflow-y-auto space-y-1" style={{ scrollbarWidth: 'none' }}>
        {DEMO_NOTIFICATIONS.map((n, i) => (
          <div key={n.id}>
            <button onClick={() => setExpanded(expanded === i ? null : i)} className="w-full flex items-center gap-2 px-2 py-1.5 rounded-md transition-colors"
              style={{ backgroundColor: expanded === i ? `${DN.surface}80` : n.unread ? `${DN.surface}4D` : 'transparent' }}>
              <div className="w-[5px] h-[5px] rounded-full shrink-0" style={{ backgroundColor: n.unread ? DN.accent : 'transparent' }} />
              <span className="flex-1 text-left truncate" style={{ fontSize: 11, color: n.unread ? DN.textPrimary : DN.textSecondary, fontWeight: n.unread ? 500 : 400 }}>{n.title}</span>
              <span style={{ fontSize: 8, fontFamily: 'monospace', color: DN.textDisabled }}>{n.time}</span>
              {expanded === i ? <ChevronDown size={8} style={{ color: DN.textDisabled }} /> : <ChevronRight size={8} style={{ color: DN.textDisabled }} />}
            </button>
            <AnimatePresence>
              {expanded === i && (
                <motion.div initial={{ opacity: 0, height: 0 }} animate={{ opacity: 1, height: 'auto' }} exit={{ opacity: 0, height: 0 }} className="overflow-hidden">
                  <div className="px-4 py-1.5 ml-3" style={{ borderLeft: `1px solid ${DN.border}` }}>
                    <span style={{ fontSize: 11, color: DN.textSecondary, lineHeight: 1.5 }}>{n.body}</span>
                    <div className="flex items-center gap-2 mt-1">
                      <button className="p-0.5" style={{ color: DN.warning }}><Pause size={10} /></button>
                      <button className="p-0.5" style={{ color: DN.accent }}><Trash2 size={9} /></button>
                    </div>
                  </div>
                </motion.div>
              )}
            </AnimatePresence>
          </div>
        ))}
      </div>
    </motion.div>
  );
}

// ─── SETTINGS VIEW ───
function SettingsView({ scrollToBottom }: { scrollToBottom?: boolean }) {
  const scrollRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (scrollToBottom && scrollRef.current) {
      scrollRef.current.scrollTo({ top: scrollRef.current.scrollHeight, behavior: 'smooth' });
    }
  }, [scrollToBottom]);
  const [settings, setSettings] = useState({
    openChatOnSend: true, restoreLastView: false, keepOpenInChat: true,
    showBattery: true, showDotGrid: true, dotGridColor: '#FFFFFF',
    showLiveState: true, compactRows: false,
    pinnedWidgets: ['calendar', 'music'] as string[],
  });
  const toggle = (key: string) => setSettings(s => ({ ...s, [key]: !s[key as keyof typeof s] }));
  const widgets = [
    { id: 'calendar', label: 'Calendar', sub: 'Date grid on overview', icon: <Calendar size={11} /> },
    { id: 'music', label: 'Music Player', sub: 'Now playing controls', icon: <Music size={11} /> },
    { id: 'ram', label: 'RAM Usage', sub: 'Memory usage gauge', icon: <Cpu size={11} /> },
    { id: 'disk', label: 'Disk Usage', sub: 'Storage usage ring', icon: <HardDrive size={11} /> },
    { id: 'network', label: 'Network', sub: 'Upload & download speeds', icon: <Wifi size={11} /> },
    { id: 'uptime', label: 'Uptime', sub: 'System uptime counter', icon: <Clock size={11} /> },
    { id: 'processes', label: 'Processes', sub: 'Running process count', icon: <Activity size={11} /> },
  ];
  const toggleWidget = (id: string) => {
    setSettings(s => {
      const has = s.pinnedWidgets.includes(id);
      if (has) return { ...s, pinnedWidgets: s.pinnedWidgets.filter(w => w !== id) };
      if (s.pinnedWidgets.length >= 2) return s;
      return { ...s, pinnedWidgets: [...s.pinnedWidgets, id] };
    });
  };

  return (
    <motion.div ref={scrollRef} initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: 10 }} transition={{ duration: 0.2 }}
      className="flex flex-col h-full px-3 py-2 overflow-y-auto" style={{ scrollbarWidth: 'none' }}>
      <div className="mb-2" style={{ fontSize: 10, fontFamily: 'monospace', letterSpacing: 1.5, color: DN.textSecondary }}>SETTINGS</div>
      <SettingsGroup label="CHAT">
        <SettingsToggle label="Open chat on send" subtitle="Navigate to chat view" on={settings.openChatOnSend} onToggle={() => toggle('openChatOnSend')} icon={<MessageSquare size={11} />} />
        <SettingsToggle label="Restore last view" subtitle="Re-open last tab on hover" on={settings.restoreLastView} onToggle={() => toggle('restoreLastView')} icon={<Eye size={11} />} />
        <SettingsToggle label="Keep open in chat" subtitle="Don't collapse while chatting" on={settings.keepOpenInChat} onToggle={() => toggle('keepOpenInChat')} icon={<Lock size={11} />} />
      </SettingsGroup>
      <SettingsGroup label="WIDGETS">
        {widgets.map(w => {
          const pinned = settings.pinnedWidgets.includes(w.id);
          const atMax = settings.pinnedWidgets.length >= 2;
          return (
            <div key={w.id} style={{ opacity: !pinned && atMax ? 0.4 : 1 }}>
              <SettingsToggle label={w.label} subtitle={w.sub} on={pinned} onToggle={() => toggleWidget(w.id)} icon={w.icon} />
            </div>
          );
        })}
        <div className="flex justify-center py-1" style={{ backgroundColor: DN.surface }}>
          <span style={{ fontSize: 7, fontFamily: 'monospace', letterSpacing: 0.8, color: DN.textDisabled }}>MAX 2 WIDGETS</span>
        </div>
      </SettingsGroup>
      <SettingsGroup label="DISPLAY">
        <SettingsToggle label="Battery indicator" on={settings.showBattery} onToggle={() => toggle('showBattery')} icon={<Battery size={11} />} />
        <SettingsToggle label="Dot grid" subtitle="Animated background" on={settings.showDotGrid} onToggle={() => toggle('showDotGrid')} icon={<Grid3x3 size={11} />} />
        {settings.showDotGrid && <SettingsColors selected={settings.dotGridColor} onSelect={(c) => setSettings(s => ({ ...s, dotGridColor: c }))} />}
      </SettingsGroup>
      <SettingsGroup label="AGENTS">
        <SettingsToggle label="Live state indicator" subtitle="Show real-time activity" on={settings.showLiveState} onToggle={() => toggle('showLiveState')} icon={<Activity size={11} />} />
        <SettingsToggle label="Compact rows" on={settings.compactRows} onToggle={() => toggle('compactRows')} icon={<Rows3 size={11} />} />
      </SettingsGroup>
    </motion.div>
  );
}

// ─── Shared UI ───
function SectionCard({ children, className }: { children: React.ReactNode; className?: string }) {
  return <div className={`rounded-md overflow-hidden ${className ?? ''}`} style={{ backgroundColor: `${DN.surface}66`, border: `1px solid ${DN.border}` }}>{children}</div>;
}

function CollapseContent({ expanded, children }: { expanded: boolean; children: React.ReactNode }) {
  return (
    <AnimatePresence initial={false}>
      {expanded && (
        <motion.div
          initial={{ height: 0, opacity: 0 }}
          animate={{ height: 'auto', opacity: 1 }}
          exit={{ height: 0, opacity: 0 }}
          transition={{ duration: 0.2, ease: [0.25, 0.1, 0.25, 1] }}
          className="overflow-hidden"
        >
          {children}
        </motion.div>
      )}
    </AnimatePresence>
  );
}

function SectionHeader({ icon, label, labelColor, count, countColor, rightContent, expanded, onToggle }: {
  icon: React.ReactNode; label: string; labelColor: string; count: number; countColor: string; rightContent?: React.ReactNode; expanded: boolean; onToggle: () => void;
}) {
  return (
    <button onClick={onToggle} className="w-full flex items-center gap-2 px-2 py-1.5 transition-colors hover:bg-white/5">
      {icon}
      <span style={{ fontSize: 9, fontFamily: 'monospace', letterSpacing: 1, color: labelColor, fontWeight: 500 }}>{label}</span>
      <span style={{ fontSize: 9, fontFamily: 'monospace', color: countColor }}>{count}</span>
      <div className="flex-1" />
      {rightContent}
      <motion.div animate={{ rotate: expanded ? 0 : -90 }} transition={{ duration: 0.15 }}><ChevronDown size={8} style={{ color: DN.textDisabled }} /></motion.div>
    </button>
  );
}

function AgentRow({ agent, onClick }: { agent: typeof DEMO_AGENTS[0]; onClick: () => void }) {
  const stateColor = agent.liveState === 'toolUse' ? DN.claudeOrange : agent.liveState === 'responding' ? DN.success : DN.textDisabled;
  const stateIcon = agent.liveState === 'toolUse' ? <Hammer size={8} /> : agent.liveState === 'responding' ? <Type size={8} /> : null;
  return (
    <button onClick={onClick} className="w-full text-left px-2 py-1.5 transition-colors hover:bg-white/5" style={{ borderTop: `1px solid ${DN.border}` }}>
      <div className="flex items-center justify-between">
        <span style={{ fontSize: 11, color: DN.textPrimary, fontWeight: 500 }}>{agent.project}</span>
        <span style={{ fontSize: 9, fontFamily: 'monospace', color: DN.textDisabled }}>{agent.elapsed}</span>
      </div>
      {agent.liveState !== 'idle' && <div className="flex items-center gap-1.5 mt-0.5"><PulsingDot color={stateColor} size={4} />{stateIcon && <span style={{ color: stateColor }}>{stateIcon}</span>}<span style={{ fontSize: 8, fontFamily: 'monospace', letterSpacing: 0.8, color: stateColor }}>{agent.liveLabel}</span></div>}
      {agent.liveDetail && <div className="mt-0.5" style={{ fontSize: 8, fontFamily: 'monospace', color: DN.textDisabled, opacity: 0.7 }}>{agent.liveDetail}</div>}
      <div className="truncate mt-0.5" style={{ fontSize: 10, color: DN.textSecondary, lineHeight: 1.3 }}>{agent.prompt}</div>
    </button>
  );
}

function ScheduledRow({ task }: { task: typeof DEMO_SCHEDULED[0] }) {
  return (
    <div className="flex items-center gap-2 px-2 py-1.5" style={{ borderTop: `1px solid ${DN.border}` }}>
      <div className="w-[5px] h-[5px] rounded-full shrink-0" style={{ backgroundColor: task.enabled ? DN.warning : DN.textDisabled }} />
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-1.5">
          <span className="truncate" style={{ fontSize: 10, fontWeight: 500, color: task.enabled ? DN.textPrimary : DN.textDisabled }}>{task.name}</span>
          {task.notify && <Bell size={7} style={{ color: DN.textDisabled }} />}
        </div>
        <span style={{ fontSize: 8, fontFamily: 'monospace', color: DN.textDisabled }}>{task.schedule}</span>
      </div>
      <span style={{ fontSize: 8, fontFamily: 'monospace', color: DN.textDisabled }}>{task.runCount}x</span>
      <span style={{ fontSize: 9, color: task.lastStatus === 'completed' ? DN.success : DN.accent }}>{task.lastStatus === 'completed' ? '\u2713' : '\u2717'}</span>
    </div>
  );
}

function TaskRow({ task, onClick }: { task: typeof DEMO_TASKS[0]; onClick: () => void }) {
  return (
    <button onClick={onClick} className="w-full flex items-center gap-2 px-2 py-1.5 transition-colors hover:bg-white/5 text-left" style={{ borderTop: `1px solid ${DN.border}` }}>
      <PulsingDot color={task.status === 'running' ? DN.warning : DN.success} size={5} />
      <span className="flex-1 truncate" style={{ fontSize: 11, fontWeight: 500, color: DN.textPrimary }}>{task.name}</span>
      <span style={{ fontSize: 9, fontFamily: 'monospace', color: DN.textDisabled }}>{task.elapsed}</span>
    </button>
  );
}

function GlassCell({ children, className, style }: { children: React.ReactNode; className?: string; style?: React.CSSProperties }) {
  return <div className={`rounded-[10px] overflow-hidden ${className ?? ''}`} style={{ background: `linear-gradient(135deg, rgba(255,255,255,0.04), rgba(255,255,255,0.01)), ${DN.surface}8C`, border: '1px solid rgba(255,255,255,0.08)', ...style }}>{children}</div>;
}

function SettingsGroup({ label, children }: { label: string; children: React.ReactNode }) {
  return <div className="mb-2"><div className="mb-1 ml-1" style={{ fontSize: 8, fontFamily: 'monospace', letterSpacing: 1.2, color: DN.textDisabled }}>{label}</div><div className="rounded-lg overflow-hidden" style={{ border: `1px solid ${DN.border}` }}>{children}</div></div>;
}

function SettingsToggle({ label, subtitle, on, onToggle, icon }: { label: string; subtitle?: string; on: boolean; onToggle: () => void; icon?: React.ReactNode }) {
  return (
    <button onClick={onToggle} className="w-full flex items-center gap-2 px-2 py-1.5 transition-colors hover:bg-white/5" style={{ backgroundColor: DN.surface, borderBottom: `1px solid ${DN.border}` }}>
      {icon && <div className="shrink-0 w-4 flex items-center justify-center" style={{ color: on ? DN.textPrimary : DN.textDisabled }}>{icon}</div>}
      <div className="flex-1 min-w-0 text-left"><div style={{ fontSize: 11, color: DN.textPrimary }}>{label}</div>{subtitle && <div style={{ fontSize: 8, fontFamily: 'monospace', color: DN.textDisabled }}>{subtitle}</div>}</div>
      <div className="relative shrink-0 transition-colors" style={{ width: 32, height: 18, borderRadius: 999, backgroundColor: on ? `${DN.success}CC` : DN.borderVisible }}>
        <motion.div className="absolute top-[2px] rounded-full" style={{ width: 14, height: 14, backgroundColor: 'white' }} animate={{ left: on ? 16 : 2 }} transition={{ duration: 0.15 }} />
      </div>
    </button>
  );
}

function SettingsColors({ selected, onSelect }: { selected: string; onSelect: (c: string) => void }) {
  const colors = ['#FFFFFF', '#D97757', '#00B4D8', '#D71921', '#4A9E5C', '#D4A843', '#A855F7', '#10A37F'];
  return (
    <div className="flex items-center justify-between px-2 py-1.5" style={{ backgroundColor: DN.surface, borderBottom: `1px solid ${DN.border}` }}>
      <span style={{ fontSize: 11, color: DN.textPrimary }}>Grid color</span>
      <div className="flex gap-1">
        {colors.map(c => <button key={c} onClick={() => onSelect(c)} className="rounded transition-all" style={{ width: 16, height: 16, backgroundColor: c, border: selected === c ? '2px solid white' : '2px solid transparent', outline: selected === c ? `1px solid ${DN.black}` : 'none' }} />)}
      </div>
    </div>
  );
}
