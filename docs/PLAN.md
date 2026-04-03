# Danotch — Plan

The notch is the always-visible nerve center. Agents run in the background, the notch shows you what's happening, and you approve/reject/steer from a 500px dropdown. The entire UX is: **delegate → glance → approve → forget.**

---

## Core Architecture

```
┌──────────────────────────────────────────────┐
│                  NOTCH APP                    │
│  (SwiftUI overlay — already built)           │
│  WebSocket client ← connects to backend      │
└──────────────┬───────────────────────────────┘
               │ ws://localhost:7778
┌──────────────▼───────────────────────────────┐
│               BACKEND (Node/TS)               │
│                                               │
│  ┌─────────┐  ┌──────────┐  ┌─────────────┐ │
│  │ Agent   │  │ Tool     │  │ Event       │ │
│  │ Runner  │  │ Registry │  │ Bus (WS)    │ │
│  └────┬────┘  └────┬─────┘  └──────┬──────┘ │
│       │            │               │         │
│  ┌────▼────────────▼───────────────▼──────┐  │
│  │          Claude Agent SDK              │  │
│  │   (agentic loop, tool use, subagents)  │  │
│  └────────────────────────────────────────┘  │
│       │                                      │
│  ┌────▼────────────────────────────────────┐ │
│  │         Tool Integrations               │ │
│  │  Gmail · Calendar · Slack · Linear ·    │ │
│  │  Notion · GitHub · Twitter · Web Search │ │
│  └─────────────────────────────────────────┘ │
└──────────────────────────────────────────────┘
```

**Stack:**
- **LLM**: Claude (via Anthropic API / Claude Agent SDK)
- **Framework**: Mastra (TS-native agent framework) or raw Claude Agent SDK
- **Integrations**: Composio (pre-built connectors to 200+ services) or direct OAuth
- **Observability**: Langfuse (open-source tracing, cost tracking)
- **Transport**: WebSocket between backend and notch app (already wired)

---

## Implementation Plan

### Phase 1: Global Shortcut + Agent Monitoring (no backend needed)

**1a. Global Keyboard Shortcut**

Drop down the notch from anywhere with a hotkey (e.g. `⌘+Shift+D`).

- `NSEvent.addGlobalMonitorForEvents` for the key combo
- Toggles existing `isExpanded` on `NotchWindowController`
- Bring panel to front if not visible
- Trivial — wires into existing infrastructure

**1b. Agent Process Monitoring**

Detect and display agents running on the system — Claude Code, Cursor, Codex, Flowlens, etc.

- Extend `SystemStatsMonitor` (already runs `ps -axo`) to detect agent processes
- Match process names/commands: `claude`, `cursor`, `codex`, `flowlens`, etc.
- Map detected agents into `SubagentTask` model for display in existing UI
- Show in notch: agent name, status (running/idle), duration, resource usage
- Poll on interval (every 2-5s) alongside existing stats sampling
- No backend required — pure Swift process scanning

**Sources to detect:**
- Claude Code CLI sessions (process name / command line args)
- Cursor background agents (Cursor helper processes)
- Codex CLI sessions
- Flowlens workers
- GitHub Actions (future — needs backend/API)

---

### Phase 2: Backend Setup

Convert the stub backend into a real TypeScript service.

```
backend/
├── src/
│   ├── index.ts              — Express + WS server
│   ├── agent/
│   │   ├── runner.ts         — Agent execution loop (Claude SDK)
│   │   └── tools/            — Tool definitions
│   │       ├── web-search.ts
│   │       └── screen.ts
│   ├── events/
│   │   └── ws.ts             — WebSocket event emitter (talks to notch)
│   └── routes/
│       └── tasks.ts          — REST: create task, list tasks, approve/reject
├── package.json
└── tsconfig.json
```

1. Convert to TypeScript
2. Install `@anthropic-ai/sdk`
3. WebSocket client that connects to app's :7778
4. Express routes for task CRUD and approval flow
5. Agent runner skeleton that streams progress events to the notch

---

### Phase 3: Chat from the Notch

Add a chat button to the notch home screen. Users type a message, it goes to the backend, Claude responds.

**App side:**
- Chat button on overview screen (opens a new view or inline input)
- Text input bar → send message via WebSocket to backend
- Stream response back and display in chat bubbles (reuse `AgentChatView` patterns)

**Backend side:**
- Receive chat message via WS
- Send to Claude API with conversation history
- Stream tokens back to the notch via WS progress events
- Support tool use in responses (agent can take actions mid-chat)

This is the foundation for the "natural language command bar" — type anything, it just works.

---

### Phase 4: Screen-Aware Agent

The notch can see your screen and respond to what's on it. You tell the agent to do something with context from your display.

**How it works:**
- User triggers via chat or hotkey: "help me with what's on screen"
- App captures screenshot via `screencapture` CLI or `CGWindowListCreateImage`
- Image sent to backend (base64 or file path)
- Backend sends to Claude vision API alongside the user's message
- Agent responds with context-aware help

**Use cases:**
- Staring at a stack trace → "debug this"
- On a code review → "summarize the issues in this diff"
- Reading a long doc → "give me the key points"
- Looking at a design → "what's wrong with this layout?"
- Filling out a form → "help me with this"
- Writing an email → "make this sound more professional"

**Implementation:**
- `screencapture -x /tmp/danotch_screen.png` (silent, no click sound)
- Base64 encode → send with chat message to backend
- Backend attaches as image content block in Claude API call
- Can be periodic (opt-in ambient mode) or on-demand (user-triggered)
- Privacy: all local, image never leaves the machine (unless using cloud API)
