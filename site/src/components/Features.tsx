import { Bot, Clock, Bell, Terminal, Globe, LayoutGrid } from 'lucide-react';

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
    icon: LayoutGrid,
    title: 'Pinnable Utils',
    description: 'Pin any 2 widgets to your notch: CPU, RAM, network, calendar, music, uptime. Your command center, your layout.',
  },
];
