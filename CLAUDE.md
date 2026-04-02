# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
swift run Danotch          # Build and run (debug)
swift build                # Build only (debug)
swift build -c release     # Build release
./build.sh                 # Build release + create Danotch.app bundle (ad-hoc signed)
```

No unit tests. Mock data is loaded at ViewModel init for demo/development.

## Architecture

**macOS accessory app** (no dock icon) that overlays the MacBook notch area. MVVM with SwiftUI reactive bindings. State is ephemeral — nothing persists across sessions.

### Core Flow

`DanotchApp` (AppDelegate) → `NotchWindowController` (NSPanel) → SwiftUI views observing `NotchViewModel` ← `WebSocketServer` (port 7778)

### Key Components

- **NotchWindowController** (`NotchWindow.swift`): Custom `DanotchPanel` (NSPanel subclass) positioned over the physical notch. Three event monitors handle hover-to-expand (with 400ms collapse delay), swipe-back gesture (60px scroll threshold), and mouse tracking. Detects notch dimensions via `NSScreen` safe area insets with fallbacks for non-notch Macs.

- **NotchViewModel**: Central state container. Processes WebSocket JSON events (`status`/`progress`/`done`) into `SubagentTask` model updates. Runs clock timer (1s) and shimmer cycle timer (2s) for activity text rotation. All state mutations wrapped in `withAnimation`.

- **WebSocketServer**: Swifter-based on `ws://localhost:7778/ws` with `/health` endpoint. Dispatches parsed JSON to ViewModel on main thread.

### View State Machine

`NotchViewState` enum drives navigation:
- `.overview` → left column (time, date, calendar) + right column (active tasks, completed strip)
- `.taskList` → full scrollable task list
- `.agentChat(taskId)` → task detail with chat history, tool calls, draft cards

View hierarchy: `NotchShellView` (shape, top bar, dot grid background) → `NotchContentView` (two-column layout, state routing) → `AgentChatView`

### Design System

`Theme.swift` — all tokens under `enum DN`. Nothing-inspired dark aesthetic:
- Colors: OLED black surfaces, gray text hierarchy (#666/#999/#E8E8E8/#FFF), signal red accent (#D71921), status colors (warning yellow, success green)
- Typography: `display()` (monospaced light), `label()` (monospaced ALL CAPS with tracking), `body()` (system default), `mono()` (monospaced data)
- Spacing: 8px base grid (`spaceSM`=8, `spaceMD`=16, `spaceLG`=24)
- Motion: easeOut only, 0.2s micro / 0.35s transitions

### WebSocket Protocol

```json
{"type": "subagent_event", "session_id": "id", "event_type": "status|progress|done", "data": {...}}
```

- `status`: upsert task (`task`, `description`, `status`, `tool_calls_count`)
- `progress`: tool lifecycle (`type`: tool_start/tool_result/token/thinking_complete)
- `done`: completion (`status`, `result`, `error`)
- `task_summary`: bulk sync with `tasks` array

### Window Behavior

Panel floats at `level = .mainMenu + 3`, joins all Spaces, non-activating, transparent background. Panel width: 520px (overview) / 540px (task list/chat). Window frame: 580x400.

## Dependencies

Single external: **Swifter** (1.5.0) for HTTP/WebSocket. Swift 6.0 toolchain, macOS 14+, Swift 5 language mode.
