import { Bot, Clock, Bell, Music, Terminal, Globe, Calendar, Cpu } from 'lucide-react';

export const FEATURES = [
  {
    icon: Bot,
    title: 'AI Agent Monitor',
    description: 'See every Claude Code, Cursor, and Codex session running on your Mac. Live state, current tool, project name.',
  },
  {
    icon: Terminal,
    title: 'Local Code Execution',
    description: 'Run bash commands, check files, execute scripts — all from the notch. Claude runs code directly on your machine.',
  },
  {
    icon: Globe,
    title: 'Web Search',
    description: 'Search the web and fetch pages in real-time. Get current prices, news, weather — anything that needs fresh data.',
  },
  {
    icon: Clock,
    title: 'Scheduled Tasks',
    description: 'Tell Claude to check your emails every morning or alert you when a stock hits a price. Natural language scheduling.',
  },
  {
    icon: Bell,
    title: 'Smart Notifications',
    description: 'Conditional alerts that peek from the notch. Claude decides when to notify you — no spam, only signal.',
  },
  {
    icon: Music,
    title: 'Now Playing',
    description: 'Apple Music and Spotify integration. See what\'s playing, control playback — right from the notch.',
  },
  {
    icon: Calendar,
    title: 'Mini Calendar',
    description: 'Compact or full calendar view. See today\'s date at a glance without switching apps.',
  },
  {
    icon: Cpu,
    title: 'System Stats',
    description: 'CPU, RAM, network, disk — beautiful arc gauges and sparkline graphs. Process list with force-quit.',
  },
];
