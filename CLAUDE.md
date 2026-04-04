# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Monorepo Structure

```
app/       — macOS Swift app (notch overlay)
backend/   — Node.js Express backend (Supabase + Claude API)
docs/      — Planning docs (PLAN.md, SCHEMA.md)
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

**macOS accessory app** (no dock icon) that overlays the MacBook notch area. MVVM with SwiftUI reactive bindings. Auth session persisted to `~/.danotch/auth.json`, settings to `~/.danotch/settings.json`. Chat threads/messages persisted to Supabase.

### Core Flow

`DanotchApp` (AppDelegate) → checks `AuthManager.isAuthenticated` → if no: shows `OnboardingView` (centered borderless window) → signup/login → on success: closes window, starts notch. If yes: `NotchWindowController` (NSPanel) → SwiftUI views observing `NotchViewModel` ← `WebSocketServer` (port 7778) + `AgentMonitor` (process scanning)

### Key Components

- **NotchWindowController** (`NotchWindow.swift`): Custom `DanotchPanel` (NSPanel subclass, `canBecomeKey: true`) positioned over the physical notch at `level = .mainMenu + 3`. Three event monitors handle hover-to-expand (with 400ms collapse delay), swipe-back gesture (60px scroll threshold), and mouse tracking. Global keyboard shortcut (⌘+Shift+Space) drops down the notch and focuses the chat input. Escape collapses. Panel won't auto-collapse while chat input is focused (`isChatInputActive`). On expand, calls `restoreOrResetView()` (respects `restoreLastView` setting). Detects notch dimensions via `NSScreen` safe area insets with fallbacks for non-notch Macs. Panel width: 520px (overview) / 540px (task/chat/stats). Window frame: 580x400.

- **AuthManager** (`AuthManager.swift`): Singleton (`AuthManager.shared`) managing auth state. `signup(email, password, fullName)` and `login(email, password)` call backend `/auth/signup` and `/auth/login`. Session (access_token, refresh_token, expiresAt, userId, email, fullName) persisted to `~/.danotch/auth.json`. Exposes `userName`, `accessToken`, `isAuthenticated`. `logout()` clears file and state. **Token refresh**: `ensureValidToken()` checks if token is expired or within 60s of expiring, calls `POST /auth/refresh` with refresh_token, saves new tokens. On refresh failure, auto-logs out. Called on app startup (`loadSession`), before `loadThreadHistory()`, and before `sendChat()`.

- **OnboardingView** (`Views/OnboardingView.swift`): Two-step onboarding flow shown in a centered borderless NSWindow (no close/min/max buttons, dark theme). Step 1: "DANOTCH / WELCOME TO THE NOTCH" + START button. Step 2: Signup form (name, email, password) or login form with toggle. On success calls `onComplete` closure which starts the notch. AppDelegate creates the window via `NSWindow` with `titlebarAppearsTransparent`, hidden standard buttons, `isMovableByWindowBackground`. Temporarily sets activation policy to `.regular` for focus, reverts to `.accessory` after.

- **NotchViewModel**: Central state container. Processes WebSocket JSON events (`status`/`progress`/`done`) into `SubagentTask` model updates. Owns `AgentMonitor`, `NotchSettings`, `NowPlayingMonitor`, and `SystemStatsMonitor` (shared instance used by both StatsPanel and ProcessListPanel). Has `authManager` reference set by AppDelegate after auth. Forwards nested ObservableObjects via Combine. Runs clock timer (1s) and shimmer cycle timer (4s) for activity text rotation. `activityText()` prioritizes streaming text snippet (last 60 chars) over cycling activity steps. New tasks get shuffled goofy loading phrases (`goofyLoadingPhrases`) as activity steps. Has `sendChat(message:)` that POSTs to backend `/api/chat` with Bearer token and `thread_id`, optimistically creates a task (navigates to chat if `openChatOnSend`), captures `thread_id` from response for follow-ups. Thread history: `loadThreadHistory()` fetches `GET /api/threads`, `loadThread(threadId)` fetches messages and creates a SubagentTask from them. Tracks `shouldFocusChatInput`, `isChatInputActive`. `lastViewBeforeCollapse` saved on `resetView()`, restored on expand if `restoreLastView` is enabled via `restoreOrResetView()`.

- **AgentMonitor** (`AgentMonitor.swift`): Standalone `ObservableObject` that scans for AI agent processes every 3s. Currently only displays Claude Code sessions (filtered because Cursor/Codex/Windsurf don't expose prompt data). Enriches each session with project name (from `~/.claude/sessions/{pid}.json` cwd), last user prompt (from conversation JSONL in `~/.claude/projects/`), and working directory (via `lsof`). Can activate the terminal app for a session via `NSWorkspace`. Provides `groupedAgents` computed property for grouped display.

- **WebSocketServer**: Swifter-based on `ws://localhost:7778/ws` with `/health` endpoint. Dispatches parsed JSON to ViewModel on main thread.

- **SystemStatsMonitor** (`StatsPanel.swift`): Standalone `ObservableObject` owned by ViewModel (single shared instance — `StatsPanel` and `ProcessListPanel` both use `viewModel.statsMonitor` instead of their own `@StateObject`). Samples system metrics every 2s. Reads CPU via `host_processor_info`, RAM via `host_statistics64`, network via `getifaddrs`, disk via `FileManager`. Maintains 40-sample history arrays for sparkline graphs. Also runs `ps -axo` to build a filterable/sortable process list.

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
- `.overview` → left column (time, date, calendar) + right column (grouped Claude Code agents with prompts, chat input bar at bottom)
- `.taskList` → full scrollable agent list (grouped agents + delegated tasks)
- `.agentChat(taskId)` → task detail with chat history, tool calls, draft cards
- `.stats` → bento grid: CPU/RAM arc gauges with sparklines, network up/down with stepped graphs, disk ring, process count, uptime
- `.processList` → sortable process table (by CPU/MEM/name) with app icons, expandable rows, force-quit capability
- `.settings` → app configuration

Top bar has four tabs: `[ HOME ]  AGENTS  |  STATS  [ ⚙ ]` plus battery indicator. Settings tab uses a gear icon (`gearshape` / `gearshape.fill`) with bracket wrapping when active, matching the text tab style.

### View Hierarchy

```
OnboardingView (centered borderless NSWindow, shown on first launch / logged out)
├── welcomeStep ("DANOTCH / WELCOME TO THE NOTCH" + START button)
└── authStep (signup: name+email+password, login: email+password, toggle between)

NotchShellView (root: notch shape, top bar tabs, dot grid background)
├── DotGridView (animated dot matrix, configurable color + opacity via settings)
├── expandedTopBar (HOME / AGENTS / STATS / ⚙ tabs + BatteryView if enabled)
└── expandedContent (routes by viewState)
    ├── NotchContentView (overview + taskList + agentChat routing)
    │   ├── leftColumn ("Hi, {name}" greeting, time, date, calendar, NowPlayingView)
    │   ├── dividerBar
    │   └── mainColumn → overviewRightColumn | agentsColumn | AgentChatView
    │       ├── AgentGroupView (collapsible, passes showLiveState + compactRows from settings)
    │       ├── AgentSessionRow (project name, live state if enabled, last prompt, elapsed, CPU/MEM on hover)
    │       ├── LiveStateView (pulsing dot + icon + label + detail for active tool/thinking/responding states)
    │       ├── NowPlayingView (Apple Music/Spotify polling, positioned by calendarMode)
    │       ├── chatInputBar (TextField + submit button, sends to backend POST /api/chat with auth)
    │       ├── tasksSection (grouped user tasks from chat, clickable → AgentChatView)
    │       ├── AgentRow (WebSocket task rows with status dot, activity text)
    │       └── threadHistory (HISTORY section: past threads from Supabase, threadRow with relative dates)
    ├── StatsPanel (bento grid: ArcGaugeCell, SparklineGraph, network rows, disk ring)
    ├── ProcessListPanel (sorted process table with ProcessIconView, kill actions)
    └── SettingsPanel (scrollable sections: Chat, Display, Agents)
        ├── SettingsSection (titled group with DN styling)
        ├── SettingsToggleRow (icon + title + subtitle + capsule toggle)
        ├── SettingsPickerRow (segmented picker for enum options)
        ├── SettingsSliderRow (slider with percentage label)
        └── SettingsColorRow (color dot presets)
```

**Behavior:**
- `tapAgentNavigates` (default: true) — tapping an agent row opens its detail page
- `expandOnHover` (default: true) — auto-expand panel when hovering over notch

**Display:**
- `showCalendar` (default: true) — show mini calendar in overview
- `largeCalendar` (default: false) — use expanded calendar layout
- `showMusic` (default: true) — show now playing track in overview
- `showBattery` (default: true) — show battery indicator in top bar
- `showDotGrid` (default: true) — show animated dot matrix background

**Agents:**
- `showAgentLiveState` (default: true) — show real-time tool activity for agents
- `compactAgentRows` (default: false) — use smaller rows in agent list

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
5. Read last ~200KB of JSONL via `readSessionState()`:
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
- **CPU override:** If CPU < 0.5% but JSONL says active (responding/thinking/toolUse), override to `.waitingForUser` — prevents stale JSONL from showing false activity

**UI display:**
- Agents grouped by type using `AgentGroupView` with collapsible chevron toggle (when >1 agent)
- Collapse state persisted in `NotchViewModel.collapsedGroups` (survives hover/collapse cycles)
- Each session shows: project name (bold), live state indicator (if active), last prompt (secondary text), elapsed time
- CPU/MEM stats shown on hover or in expanded agents view
- Sorted by most recently active (JSONL modification time) — active sessions float to top

**Detection also runs for (but currently filtered):**
- Cursor: `Cursor.app/Contents/MacOS/Cursor` main process
- Codex: `codex` + `app-server` in args
- Windsurf: `Windsurf.app/Contents/MacOS/Windsurf`

### Chat Input & Tasks

**Chat flow:**
1. User types in `chatInputBar` on HOME tab (or triggered via ⌘+Shift+Space)
2. `sendChat(message:)` in ViewModel creates optimistic `SubagentTask` with `session_id`
3. POSTs to backend `http://localhost:3001/api/chat` with `{ message, session_id }`
4. Backend streams response via WebSocket → existing `processEvent` pipeline updates the task
5. View navigates directly to `AgentChatView` for that task (`.agentChat(sid)`)
6. All agent chat bubbles render as final (bold markdown) — no dimmed intermediate distinction

**Tasks section** appears below Claude Code agent groups in both HOME and AGENTS tabs, styled as a grouped card matching `AgentGroupView`.

### Models

- **DetectedAgent**: id, type, pid, status, cpu, memMB, elapsed, workingDirectory, sessionInfo, appPath, lastPrompt, lastActivityTime, liveState, liveDetail
- **AgentLiveState**: idle, thinking, toolUse(String), responding, waitingForUser — each with `label`, `color`, `icon`. Tool names mapped to human labels via `toolDisplayName()`
- **AgentGroup**: id, type, agents array — with computed `runningCount`, `totalCpu`, `totalMem`
- **AgentType**: claudeCode, cursor, codex, windsurf — each with `icon`, `brandColor`, `rawValue` display name
- **AgentStatus**: running (warning color), idle (disabled color)
- **SubagentTask**: id, task, description, status, toolCallsCount, streamingText, chatHistory, threadId — used for WebSocket-driven tasks and loaded DB threads. `threadId` links to Supabase thread for follow-up messages
- **TaskStatus**: pending, running, completed, failed, cancelled, awaitingApproval

### Settings (`NotchSettings`)

Persisted via JSON file at `~/.danotch/settings.json`. All settings survive app restarts. Each `@Published` property calls `save()` on `didSet`. JSON written with `prettyPrinted` + `sortedKeys`.

**Chat:**
- `openChatOnSend` (default: true) — sending a message navigates to `.agentChat(sid)` instantly vs staying on current page
- `restoreLastView` (default: false) — re-hover restores `lastViewBeforeCollapse` vs always opening home
- `keepOpenInChat` (default: true) — prevents auto-collapse when viewing a conversation (`.agentChat`). Mouse leaving the notch area won't trigger collapse while in a chat view

**Display:**
- `calendarMode` (default: large) — `CalendarMode` enum: `off` / `mini` (one-line strip) / `large` (full grid). Left column layout: time/date → calendar → music, stacked vertically
- `showMusic` (default: true) — `NowPlayingView` in left column below calendar
- `musicSize` (default: mini) — `MusicSize` enum: `mini` (30px art, compact) / `big` (56px art, 2-line title, separate controls row). Big only activates when calendar is mini or off
- `showBattery` (default: true) — battery indicator in top bar
- `showDotGrid` (default: true) — animated dot matrix background
- `dotGridColor` (default: "#FFFFFF") — dot grid color, 8 presets (white, orange, cyan, red, green, yellow, purple, teal). `dotGridSwiftColor` computed property converts hex to `Color`. Also used as accent for music player controls and progress bar
- `dotGridOpacity` (default: 0.6) — dot grid brightness (0.1–1.0)

**Agents:**
- `showAgentLiveState` (default: true) — real-time tool activity indicators. Passed through `AgentGroupView` → `AgentSessionRow`
- `compactAgentRows` (default: false) — smaller rows in agent list. Applied to both agent groups and tasks section

**UI state (also persisted):**
- `collapsedGroups` — Set of collapsed agent group IDs

Settings UI components: `SettingsToggleRow` (capsule toggle), `SettingsPickerRow` (segmented picker for enums), `SettingsSliderRow` (slider with percentage), `SettingsColorRow` (color dot presets).

### Now Playing (`NowPlayingView` + `NowPlayingMonitor`)

`NowPlayingMonitor` is an `ObservableObject` owned by the ViewModel (lives for the app's lifetime). Polls Apple Music and Spotify every 2s via `osascript` on a background thread. Fetches: track name, artist, play/pause state, playback position, duration, and album artwork.

**Artwork:** Exported via osascript `raw data of artwork 1 of current track` to `/tmp/danotch_art.png`. Only re-fetched when track changes (keyed by track name). Displayed as `NSImage` in the view.

**Music detection:** Checks `if application "Music" is running` before talking to it (prevents launching the app). Falls back to Spotify.

**Two display modes** controlled by `musicSize` setting:
- **Mini:** 30px album art, track + artist inline, controls appear on hover (opacity toggle, no layout shift)
- **Big:** 56px album art, larger text (2-line track name), progress bar, centered playback controls below (opacity toggle on hover, space always reserved)

**Playback controls:** Previous, play/pause, next — send commands via `osascript` (`tell application "Music" to playpause` etc.). Control color uses the user's `dotGridColor` accent. Progress bar fill also uses accent color.

**Layout:** Always positioned below calendar in the left column. No background — floats with the rest of the content.

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

TypeScript ESM service (`"type": "module"`). Run with `npm run dev` (tsx watch). Uses Supabase for auth + persistence.

### Structure

```
backend/src/
├── index.ts          — Express on :3001, request logging middleware, connects NotchBridge
├── config.ts         — All config: port, model, max turns, permission mode (env-overridable)
├── prompts.ts        — System prompts: CHAT_SYSTEM_PROMPT (plain text/markdown only) + AGENT_SYSTEM_PROMPT (tool-aware)
├── types.ts          — Task, ChatMessage, WebSocket event types
├── lib/
│   └── supabase.ts   — Supabase service-role client (bypasses RLS)
├── middleware/
│   └── auth.ts       — requireAuth (via supabase.auth.getUser), extractUserId (optional auth)
├── agent/
│   └── runner.ts     — Two modes: runChat() + runAgent(), DB persistence, thread management
├── events/
│   └── notch.ts      — WebSocket client to notch app :7778, auto-reconnect every 3s
└── routes/
    ├── auth.ts       — Signup (admin.createUser + auto-login), login, refresh, /me
    └── tasks.ts      — Chat/agent endpoints (auth optional), thread CRUD (auth required)
```

### Auth

- **Signup** (`POST /auth/signup`): Uses `supabase.auth.admin.createUser()` with `email_confirm: true` (auto-confirms, no email verification). Then `signInWithPassword()` to get session tokens. Creates `user_profiles` row + 4 `connected_apps` rows (gmail, googlecalendar, googledocs, linear — all `active: false`).
- **Login** (`POST /auth/login`): `signInWithPassword()`, returns tokens + profile.
- **Token verification**: `supabase.auth.getUser(token)` — works with both HS256 and ES256 JWTs (Supabase may use either depending on project config).
- **Auth middleware**: `requireAuth` blocks unauthenticated requests. `extractUserId` is non-blocking optional extraction for chat/agent endpoints (they work with or without auth).

### Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `GET` | `/health` | No | Health check + notch connection status |
| `POST` | `/auth/signup` | No | Create account (email+password) |
| `POST` | `/auth/login` | No | Sign in |
| `POST` | `/auth/refresh` | No | Refresh JWT tokens |
| `GET` | `/auth/me` | Yes | Current user profile |
| `POST` | `/api/chat` | Optional | Claude conversation (no tools), persists to DB if authed |
| `POST` | `/api/agent` | Optional | Claude Agent SDK (tools), persists to DB if authed |
| `GET` | `/api/tasks` | No | List in-memory tasks |
| `GET` | `/api/tasks/:id` | No | Get specific in-memory task |
| `GET` | `/api/threads` | Yes | List conversation threads from DB |
| `GET` | `/api/threads/:id` | Yes | Get thread messages from DB |
| `DELETE` | `/api/threads/:id` | Yes | Delete thread + messages |

### Agent Runner

Two execution modes in `runner.ts`:

- **`runChat(message, notch, { sessionId?, userId?, threadId? })`** — Direct Anthropic API call with streaming. No tools. Uses `CHAT_SYSTEM_PROMPT`. When `userId` is present: creates/reuses thread in Supabase, saves user message (awaited), saves assistant response with metadata (fire-and-forget via `dbSave()`). On error: saves failed message with partial content + error details.

- **`runAgent(message, notch, { sessionId?, cwd?, userId?, threadId? })`** — Uses `@anthropic-ai/claude-agent-sdk` `query()` function. Full Claude Code capabilities. Uses `AGENT_SYSTEM_PROMPT`. Same DB persistence pattern as chat. Accumulates `toolsUsed` array, saved in metadata on completion or error.

**DB persistence pattern**: User message save is `await`ed (must be in DB before streaming). Assistant message save is fire-and-forget (`dbSave()` wraps in `.catch()` — never blocks streaming). On errors, partial content + tools_used + error message are all saved with `status: "failed"` and `partial: true` in metadata.

**Message metadata in DB**:
- Success: `{ status: "completed", model, input_tokens, output_tokens, tools_used }`
- Failure: `{ status: "failed", error, model, partial, tools_used }`

Both modes also store tasks in-memory (`Map<string, Task>`) and push status/progress/done events through `NotchBridge` to the app's existing WebSocket protocol.

**Thread queries**: `getThreads(userId)`, `getThreadMessages(userId, threadId)`, `deleteThread(userId, threadId)` — all scoped by userId.

### Request Logging

All requests logged with timestamp, method, path, and auth status. Route handlers log detailed info (message preview, userId, threadId, result status).

### Config (`config.ts`)

All settings env-overridable:
- `PORT` — server port (default: 3001)
- `NOTCH_WS_URL` — notch app WebSocket (default: ws://localhost:7778/ws)
- `CLAUDE_MODEL` — agent SDK model (default: claude-sonnet-4-20250514)
- `CLAUDE_API_MODEL` — direct API model (default: claude-sonnet-4-20250514)
- `MAX_TURNS` — agent max turns (default: 10)
- `MAX_TOKENS` — API max tokens (default: 4096)
- `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_KEY`, `SUPABASE_JWT_SECRET` — Supabase credentials (in `.env`, gitignored)

## Dependencies

**App**: Swifter (1.5.0) for HTTP/WebSocket. Swift 6.0 toolchain, macOS 14+, Swift 5 language mode.

**Backend**: Express (4.x), `@anthropic-ai/sdk`, `@anthropic-ai/claude-agent-sdk`, `@supabase/supabase-js`, `jsonwebtoken`, ws, uuid. TypeScript with tsx for dev.
