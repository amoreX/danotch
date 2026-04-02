# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run Commands

```bash
swift run Danotch          # Build and run (debug)
swift build                # Build only (debug)
swift build -c release     # Build release
./build.sh                 # Build release + create Danotch.app bundle (ad-hoc signed)
```

To test with mock WebSocket events (requires a running app instance):
```bash
npm install ws && node test.js
```

There are no unit tests. The test harness (`test.js`) sends simulated subagent events over WebSocket to `ws://localhost:7778/ws`.

## Architecture

**macOS accessory app** (no dock icon) that overlays the MacBook notch area. MVVM with SwiftUI reactive bindings.

### Core Flow

`DanotchApp` (AppDelegate) → creates `NotchWindowController` → hosts SwiftUI views observing `NotchViewModel` ← receives events from `WebSocketServer`

### Key Components

- **NotchWindowController** (`NotchWindow.swift`): Custom `NSPanel` positioned over the physical notch. Handles mouse tracking (hover to expand, leave to collapse with 400ms delay), swipe-back gesture detection (60px threshold on scroll), and dynamic panel resizing per view state. Detects actual notch dimensions via `NSScreen` safe area insets.

- **NotchViewModel**: Central state container. Processes WebSocket events (`status`/`progress`/`done`) into task model updates. Runs clock and shimmer animation timers. All mutations wrapped in `withAnimation(.snappy)`. State is ephemeral — nothing persists across sessions. Loads mock tasks on init for demo mode.

- **WebSocketServer**: Swifter-based server on port 7778. Routes: `/ws` (WebSocket events), `/health` (health check). Dispatches parsed JSON to ViewModel on main thread.

### View State Machine

Navigation is driven by `NotchViewState` enum:
- `.overview` → time/weather/date + task summary (OverviewPanel, inside NotchContentView)
- `.taskList` → scrollable task list (NotchContentView)
- `.agentChat(taskId)` → single task detail with chat history (AgentChatView)

View hierarchy: `NotchShellView` (shape/hover) → `NotchContentView` (state routing) → panel views

### Design System

`Theme.swift` defines tokens under `enum DN`: Nothing-inspired dark aesthetic with monospace display fonts, 8px spacing grid, and status-mapped colors (running=yellow, completed=green, awaiting_approval=red). All typography, spacing, and color constants live here.

### Window Behavior

The panel floats above the menu bar (`level = .mainMenu + 3`), joins all Spaces, is non-activating and transparent. Three event monitors (global, local, scroll) drive hover/collapse behavior. Panel size animates between states.

## Dependencies

Single external dependency: [Swifter](https://github.com/nicklama/swifter-websocket) for HTTP/WebSocket server. Swift 6.0 toolchain, macOS 14+ target, compiled with Swift 5 language mode.
