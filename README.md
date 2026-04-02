# Danotch

macOS notch status viewer for delegated agent tasks. Lives in the MacBook notch, expands on hover to show time/weather/date and real-time subagent task progress.

## Requirements

- macOS 14+ (with notch for best experience, floating mode on other Macs)
- Swift 6+ (Command Line Tools or Xcode)

## Quick Start

```bash
# Build and run
swift run Danotch
```

The app hides in the notch with compact info (time + task count). Hover over the notch area to expand it.

## Build Release

```bash
./build.sh
```

Creates a release binary and `Danotch.app` bundle (ad-hoc signed). Run with:

```bash
open Danotch.app
# or
.build/release/Danotch
```

## Development

The app launches with hardcoded mock tasks for immediate UI testing. To send live events, connect a WebSocket client to `ws://localhost:7778/ws` (see protocol below).

## How It Works

### Notch Interaction

- **Compact mode**: Time (left of notch) and task count (right of notch) shown as wings
- **Hover**: Black pill expands down from notch revealing full panel with time, date, weather, and task summary
- **Click "View all"**: Animated transition to task list with status, tools, and duration
- **Click a task**: Detailed agent chat view with tool call history and streaming text
- **Mouse leaves**: 400ms grace period, then collapses back to compact
- **Swipe left**: On task list, swipe gesture (60px threshold) navigates back to overview

### WebSocket Server

Runs on `ws://localhost:7778/ws` with a health check at `/health`. Accepts JSON messages:

```json
{
  "type": "subagent_event",
  "session_id": "abc-123",
  "event_type": "status|progress|done",
  "data": { ... }
}
```

| event_type | Purpose | data fields |
|-----------|---------|-------------|
| `status` | Add/update task | `task`, `description`, `status`, `tool_calls_count` |
| `progress` | Tool calls, tokens | `type` (tool_start/tool_result/token/thinking_complete), `tool_name`, `text` |
| `done` | Task finished | `status`, `result`, `error` |

Also supports `task_summary` type for bulk sync.

## Architecture

```
Sources/
├── DanotchApp.swift         # App entry, AppDelegate (accessory app, no dock icon)
├── NotchWindow.swift        # NSPanel window controller, mouse tracking, screen detection
├── NotchViewModel.swift     # State management, event processing, timers, mock data
├── Models.swift             # SubagentTask, TaskStatus, WeatherInfo
├── Theme.swift              # Design tokens (Nothing-inspired): colors, typography, spacing
├── WebSocketServer.swift    # Swifter WS server on :7778
└── Views/
    ├── NotchShellView.swift   # Root view: notch shape, hover, expand/collapse
    ├── NotchContentView.swift # Content state machine + compact wing views
    ├── AgentChatView.swift    # Individual task detail with chat history
    └── DotGridView.swift      # Animated dot grid background effect
```

### Design

Nothing-inspired dark aesthetic: pure black surfaces, monospace display fonts, 8px spacing grid, and status-mapped accent colors (yellow for running, green for completed, red for awaiting approval).
