# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Monorepo Structure

```
app/       — macOS Swift app (notch overlay)
backend/   — Node.js Express backend (placeholder)
docs/      — Planning docs (PLAN.md)
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

No unit tests in either package.

## App Architecture

**macOS accessory app** (no dock icon) that overlays the MacBook notch area. MVVM with SwiftUI reactive bindings. State is ephemeral — nothing persists across sessions.

### Core Flow

`DanotchApp` (AppDelegate) → `NotchWindowController` (NSPanel) → SwiftUI views observing `NotchViewModel` ← `WebSocketServer` (port 7778) + `AgentMonitor` (process scanning)

### Key Components

- **NotchWindowController** (`NotchWindow.swift`): Custom `DanotchPanel` (NSPanel subclass) positioned over the physical notch at `level = .mainMenu + 3`. Three event monitors handle hover-to-expand (with 400ms collapse delay), swipe-back gesture (60px scroll threshold), and mouse tracking. Detects notch dimensions via `NSScreen` safe area insets with fallbacks for non-notch Macs. Panel width: 520px (overview) / 540px (task/chat/stats). Window frame: 580x400.

- **NotchViewModel**: Central state container. Processes WebSocket JSON events (`status`/`progress`/`done`) into `SubagentTask` model updates. Owns `AgentMonitor` and forwards its `objectWillChange` via Combine. Runs clock timer (1s) and shimmer cycle timer (2s) for activity text rotation. All state mutations wrapped in `withAnimation`.

- **AgentMonitor** (`AgentMonitor.swift`): Standalone `ObservableObject` that scans for AI agent processes every 3s. Currently only displays Claude Code sessions (filtered because Cursor/Codex/Windsurf don't expose prompt data). Enriches each session with project name (from `~/.claude/sessions/{pid}.json` cwd), last user prompt (from conversation JSONL in `~/.claude/projects/`), and working directory (via `lsof`). Can activate the terminal app for a session via `NSWorkspace`. Provides `groupedAgents` computed property for grouped display.

- **WebSocketServer**: Swifter-based on `ws://localhost:7778/ws` with `/health` endpoint. Dispatches parsed JSON to ViewModel on main thread.

- **SystemStatsMonitor** (`StatsPanel.swift`): Standalone `ObservableObject` that samples system metrics every 2s. Reads CPU via `host_processor_info`, RAM via `host_statistics64`, network via `getifaddrs`, disk via `FileManager`. Maintains 40-sample history arrays for sparkline graphs. Also runs `ps -axo` to build a filterable/sortable process list.

### Important: Pipe Buffer Deadlock

When using `Process` + `Pipe` in the app, **always read pipe data before calling `waitUntilExit()`**. The `ps` output can exceed the 64KB pipe buffer, causing the child to block on write and `waitUntilExit()` to hang forever. This applies to both `AgentMonitor.runPS()` and `SystemStatsMonitor.readProcessList()`.

```swift
// CORRECT:
let data = pipe.fileHandleForReading.readDataToEndOfFile()
process.waitUntilExit()

// WRONG (deadlocks):
process.waitUntilExit()
let data = pipe.fileHandleForReading.readDataToEndOfFile()
```

### View State Machine

`NotchViewState` enum drives all navigation:
- `.overview` → left column (time, date, calendar) + right column (grouped Claude Code agents with prompts)
- `.taskList` → full scrollable agent list (grouped agents + delegated tasks)
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
    │   ├── leftColumn (time display, date, MiniCalendarView)
    │   ├── dividerBar
    │   └── mainColumn → overviewRightColumn | agentsColumn | AgentChatView
    │       ├── AgentGroupView (collapsible group: header with type icon/count/chevron toggle, contains AgentSessionRows)
    │       ├── AgentSessionRow (project name, live state indicator, last prompt, elapsed, CPU/MEM on hover)
    │       ├── LiveStateView (pulsing dot + icon + label for active tool/thinking/responding states)
    │       └── AgentRow (WebSocket task rows with status dot, activity text)
    ├── StatsPanel (bento grid: ArcGaugeCell, SparklineGraph, network rows, disk ring)
    ├── ProcessListPanel (sorted process table with ProcessIconView, kill actions)
    └── SettingsPanel
```

### Agent Monitoring

`AgentMonitor` detects running AI agents via `ps -eo pid,pcpu,rss,etime,args`. Currently only Claude Code sessions are displayed (others filtered out since they don't expose prompt data).

**Claude Code detection:**
- Matches `*/claude` binary with `--session-id` flag in args
- Status: CPU > 1.0% = running (yellow), else idle (gray)
- Multiple sessions shown individually (keyed by PID)
- Clicking a row activates the terminal app (Ghostty → iTerm → Kitty → Terminal)

**Claude Code enrichment pipeline:**
1. Read `~/.claude/sessions/{pid}.json` → get `cwd` and `sessionId`
2. Fallback: resolve cwd via `lsof -a -p PID -d cwd -Fn`
3. Extract project name from cwd (last path component)
4. Find conversation JSONL at `~/.claude/projects/{project-dir}/{sessionId}.jsonl`
5. Read last ~50KB of JSONL via `readSessionState()`:
   - Parse in reverse to find last `type: "user"` message → last prompt
   - Clean prompt text: strip `[Image...]` refs, HTML tags, newlines, truncate to 120 chars
   - Parse last entries to determine live state via `parseLiveState()`
   - Get file modification time as `lastActivityTime` for sort ordering

**Live state detection** (from JSONL tail via `parseLiveState()`):
- `AgentLiveState` enum determines what the session is currently doing:
  - `.thinking` — last entry is `type: "user"` (agent processing) — brain icon, yellow
  - `.toolUse(name)` — last assistant message has `tool_use` content block — hammer icon, orange. Tool names mapped to display labels: Bash→"RUNNING COMMAND", Read→"READING FILE", Edit→"EDITING FILE", Grep→"SEARCHING", Glob→"FINDING FILES", Agent→"RUNNING AGENT", etc.
  - `.responding` — assistant streaming text (`stop_reason: null`) or after `tool_result` — text cursor icon, green
  - `.waitingForUser` — assistant finished (`stop_reason: "end_turn"`) — no indicator shown
  - `.idle` — no conversation data — no indicator shown
- `liveDetail` extracted via `extractToolDetail()` from tool input parameters:
  - Bash → the command string (truncated to 80 chars)
  - Read/Write/Edit → the file path
  - Grep → the search pattern
  - Glob → the glob pattern
  - Agent → the agent description
  - WebSearch → the query
  - Responding → trailing snippet of the response text
- Displayed via `LiveStateView`: pulsing dot + SF Symbol icon + uppercase label + detail line (mono, dimmed)
- Note: thinking text is redacted in JSONL (always empty), so `.thinking` state has no detail

**UI display:**
- Agents grouped by type using `AgentGroupView` with collapsible chevron toggle (when >1 agent)
- Each session shows: project name (bold), live state indicator (if active), last prompt (secondary text), elapsed time
- CPU/MEM stats shown on hover or in expanded agents view
- Sorted by most recently active (JSONL modification time) — active sessions float to top

**Detection also runs for (but currently filtered):**
- Cursor: `Cursor.app/Contents/MacOS/Cursor` main process
- Codex: `codex` + `app-server` in args
- Windsurf: `Windsurf.app/Contents/MacOS/Windsurf`

### Models

- **DetectedAgent**: id, type, pid, status, cpu, memMB, elapsed, workingDirectory, sessionInfo, appPath, lastPrompt, lastActivityTime, liveState, liveDetail
- **AgentLiveState**: idle, thinking, toolUse(String), responding, waitingForUser — each with `label`, `color`, `icon`. Tool names mapped to human labels via `toolDisplayName()`
- **AgentGroup**: id, type, agents array — with computed `runningCount`, `totalCpu`, `totalMem`
- **AgentType**: claudeCode, cursor, codex, windsurf — each with `icon`, `brandColor`, `rawValue` display name
- **AgentStatus**: running (warning color), idle (disabled color)
- **SubagentTask**: id, task, description, status, toolCallsCount, streamingText, chatHistory — used for WebSocket-driven tasks from the backend
- **TaskStatus**: pending, running, completed, failed, cancelled, awaitingApproval

### Design System

`Theme.swift` — all tokens under `enum DN`. Nothing-inspired dark aesthetic:
- Colors: OLED black surfaces (#000), elevated surface (#111), borders (#222/#333), gray text hierarchy (#666/#999/#E8E8E8/#FFF), signal red accent (#D71921), success green (#4A9E5C), warning yellow (#D4A843)
- Agent brand colors: Claude orange (#D97757), Cursor blue (#00B4D8), Codex green (#10A37F), Windsurf teal (#00C896)
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

## Backend Architecture

TypeScript ESM service (`"type": "module"`). Run with `npm run dev` (tsx watch).

### Structure

```
backend/src/
├── index.ts          — Express on :3001, connects NotchBridge
├── config.ts         — All config: port, model, max turns, system prompt (env-overridable)
├── types.ts          — Task, ChatMessage, WebSocket event types
├── agent/
│   └── runner.ts     — Two modes: runChat() (Anthropic API) + runAgent() (Claude Agent SDK)
├── events/
│   └── notch.ts      — WebSocket client to notch app :7778, auto-reconnect every 3s
└── routes/
    └── tasks.ts      — REST endpoints
```

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check + notch connection status |
| `POST` | `/api/chat` | Simple Claude conversation (no tools) |
| `POST` | `/api/agent` | Claude Agent SDK — has tools: Bash, Read, Edit, Grep, Glob, etc. |
| `GET` | `/api/tasks` | List all tasks |
| `GET` | `/api/tasks/:id` | Get specific task |

### Agent Runner

Two execution modes in `runner.ts`:

- **`runChat(message, notch, sessionId?)`** — Direct Anthropic API call with streaming. No tools. Good for quick Q&A. Streams tokens to notch via WebSocket progress events.

- **`runAgent(message, notch, { sessionId?, cwd? })`** — Uses `@anthropic-ai/claude-agent-sdk` `query()` function. Full Claude Code capabilities (Bash, Read, Write, Edit, Grep, Glob). Iterates the async generator for `SDKMessage` events (assistant messages, tool use, stream events, results). Streams all progress to notch.

Both modes store tasks in-memory (`Map<string, Task>`) and push status/progress/done events through `NotchBridge` to the app's existing WebSocket protocol.

### Config (`config.ts`)

All settings env-overridable:
- `PORT` — server port (default: 3001)
- `NOTCH_WS_URL` — notch app WebSocket (default: ws://localhost:7778/ws)
- `CLAUDE_MODEL` — agent SDK model (default: claude-sonnet-4-20250514)
- `CLAUDE_API_MODEL` — direct API model (default: claude-sonnet-4-20250514)
- `MAX_TURNS` — agent max turns (default: 10)
- `MAX_TOKENS` — API max tokens (default: 4096)

## Dependencies

**App**: Swifter (1.5.0) for HTTP/WebSocket. Swift 6.0 toolchain, macOS 14+, Swift 5 language mode.

**Backend**: Express (4.x), `@anthropic-ai/sdk`, `@anthropic-ai/claude-agent-sdk`, ws, uuid. TypeScript with tsx for dev.
