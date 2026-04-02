# Danotch

macOS notch status viewer for delegated agent tasks. Lives in the MacBook notch, expands on hover to show time/weather/date and real-time subagent task progress.

## Structure

```
app/       — macOS Swift app (notch overlay)
backend/   — Node.js Express backend
```

## Quick Start

### App (macOS notch overlay)

```bash
cd app
swift run Danotch
```

Hover over the notch area to expand. Mock data loads automatically for development.

### Backend

```bash
cd backend
npm install
npm run dev
```

### Build Release

```bash
cd app
./build.sh
open Danotch.app
```

## How It Works

### Notch Interaction

- **Compact mode**: Time (left of notch) and task count (right of notch) shown as wings
- **Hover**: Black pill expands down from notch revealing full panel with time, date, weather, and task summary
- **Click "View all"**: Animated transition to task list with status, tools, and duration
- **Click a task**: Detailed agent chat view with tool call history and streaming text
- **Mouse leaves**: 400ms grace period, then collapses back to compact
- **Swipe left**: On task list, swipe gesture (60px threshold) navigates back to overview

### WebSocket Protocol

The app runs a WebSocket server on `ws://localhost:7778/ws` (with `/health` endpoint). Accepts JSON messages:

```json
{"type": "subagent_event", "session_id": "abc-123", "event_type": "status|progress|done", "data": {...}}
```

| event_type | Purpose | data fields |
|-----------|---------|-------------|
| `status` | Add/update task | `task`, `description`, `status`, `tool_calls_count` |
| `progress` | Tool calls, tokens | `type` (tool_start/tool_result/token/thinking_complete), `tool_name`, `text` |
| `done` | Task finished | `status`, `result`, `error` |

Also supports `task_summary` type for bulk sync.

### Design

Nothing-inspired dark aesthetic: pure black surfaces, monospace display fonts, 8px spacing grid, and status-mapped accent colors (yellow for running, green for completed, red for awaiting approval).
