# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Monorepo Structure

```
app/       — macOS Swift app (notch overlay)
backend/   — Node.js Express backend (placeholder)
docs/      — Planning docs (PLAN.md, VIRAL-IDEAS.md)
```

## Build & Run

### App

```bash
cd app
swift run Danotch          # Build and run (debug)
swift build                # Build only (debug)
swift build -c release     # Build release
./build.sh                 # Build release + create Danotch.app bundle (ad-hoc signed)
```

### Backend

```bash
cd backend
npm install
npm run dev                # Starts on :3001
```

No unit tests in either package. App loads mock data at ViewModel init for development.

## App Architecture

**macOS accessory app** (no dock icon) that overlays the MacBook notch area. MVVM with SwiftUI reactive bindings. State is ephemeral — nothing persists across sessions.

### Core Flow

`DanotchApp` (AppDelegate) → `NotchWindowController` (NSPanel) → SwiftUI views observing `NotchViewModel` ← `WebSocketServer` (port 7778)

### Key Components

- **NotchWindowController** (`NotchWindow.swift`): Custom `DanotchPanel` (NSPanel subclass) positioned over the physical notch at `level = .mainMenu + 3`. Three event monitors handle hover-to-expand (with 400ms collapse delay), swipe-back gesture (60px scroll threshold), and mouse tracking. Detects notch dimensions via `NSScreen` safe area insets with fallbacks for non-notch Macs. Panel width: 520px (overview) / 540px (task/chat/stats). Window frame: 580x400.

- **NotchViewModel**: Central state container. Processes WebSocket JSON events (`status`/`progress`/`done`) into `SubagentTask` model updates. Runs clock timer (1s) and shimmer cycle timer (2s) for activity text rotation. All state mutations wrapped in `withAnimation`.

- **WebSocketServer**: Swifter-based on `ws://localhost:7778/ws` with `/health` endpoint. Dispatches parsed JSON to ViewModel on main thread.

- **SystemStatsMonitor** (`StatsPanel.swift`): Standalone `ObservableObject` that samples system metrics every 2s. Reads CPU via `host_processor_info`, RAM via `host_statistics64`, network via `getifaddrs`, disk via `FileManager`. Maintains 40-sample history arrays for sparkline graphs. Also runs `ps -axo` to build a filterable/sortable process list.

### View State Machine

`NotchViewState` enum drives all navigation:
- `.overview` → left column (time, date, calendar) + right column (active tasks, completed strip)
- `.taskList` → full scrollable task list
- `.agentChat(taskId)` → task detail with chat history, tool calls, draft cards
- `.stats` → bento grid: CPU/RAM arc gauges with sparklines, network up/down with stepped graphs, disk ring, process count, uptime
- `.processList` → sortable process table (by CPU/MEM/name) with app icons, expandable rows, force-quit capability
- `.settings` → app configuration

Top bar has four tabs: `[ HOME ]  AGENTS  |  STATS  SET` plus battery indicator.

### View Hierarchy

```
NotchShellView (root: notch shape, top bar tabs, dot grid background)
├── DotGridView (animated dot matrix, mouse-interactive via global NSEvent tracking)
├── expandedTopBar (HOME / AGENTS / STATS / SET tabs + BatteryView)
└── expandedContent (routes by viewState)
    ├── NotchContentView (overview + taskList + agentChat routing)
    │   ├── leftColumn (time display, date, MiniCalendarView, approval cards)
    │   ├── dividerBar
    │   └── mainColumn → overviewRightColumn | agentsColumn | AgentChatView
    ├── StatsPanel (bento grid: ArcGaugeCell, SparklineGraph, network rows, disk ring)
    ├── ProcessListPanel (sorted process table with ProcessIconView, kill actions)
    └── SettingsPanel
```

### Design System

`Theme.swift` — all tokens under `enum DN`. Nothing-inspired dark aesthetic:
- Colors: OLED black surfaces (#000), elevated surface (#111), borders (#222/#333), gray text hierarchy (#666/#999/#E8E8E8/#FFF), signal red accent (#D71921), success green (#4A9E5C), warning yellow (#D4A843)
- Typography: `display()` (monospaced light), `label()` (monospaced ALL CAPS with tracking), `body()` (system default), `mono()` (monospaced data)
- Spacing: 8px base grid (`spaceSM`=8, `spaceMD`=16, `spaceLG`=24)
- Motion: easeOut only, 0.2s micro / 0.35s transitions. No spring/bounce.
- Status colors via `DN.statusColor()`: running=warning, completed=success, awaitingApproval/failed=accent, pending/cancelled=disabled

### Stats Panel Components

- **ArcGaugeCell**: Segmented tick-mark arc (36 ticks, 270° sweep) with color thresholds (green→yellow→red). Background MiniSparkline fill. Used for CPU and RAM.
- **SparklineGraph**: Stepped oscilloscope-style graph with dashed grid lines, gradient fill, and pulsing live-point indicator. Used for network up/down.
- **GlassCell**: ViewModifier adding subtle translucent surface with gradient border (glass morphism on dark bg).
- **ProcessIconView**: Resolves app icons by walking up the binary path to find `.app` bundle, falls back to `NSWorkspace.shared.icon(forFile:)`.

### WebSocket Protocol

```json
{"type": "subagent_event", "session_id": "id", "event_type": "status|progress|done", "data": {...}}
```

- `status`: upsert task (`task`, `description`, `status`, `tool_calls_count`)
- `progress`: tool lifecycle (`type`: tool_start/tool_result/token/thinking_complete)
- `done`: completion (`status`, `result`, `error`)
- `task_summary`: bulk sync with `tasks` array

## Dependencies

**App**: Swifter (1.5.0) for HTTP/WebSocket. Swift 6.0 toolchain, macOS 14+, Swift 5 language mode.

**Backend**: Express (4.x).
