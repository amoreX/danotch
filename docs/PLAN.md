# Danotch — Agent Platform Plan

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

## The Ideas

### 1. BACKGROUND DELEGATED AGENTS (the core)

**What:** You tell Danotch "do X" and it runs an agent in the background. The notch shows progress, tool calls, and asks for approval when needed. This is already mocked in the UI — now make it real.

**Examples:**
- "Search my Gmail for the Airbnb confirmation and add the check-in date to my calendar"
- "Summarize the last 20 messages in #engineering and post a recap"
- "Update Linear ticket GH-142 to done and comment with the PR link"
- "Draft a reply to Sarah's email about the roadmap meeting"

**Implementation:**
1. Backend receives task via REST endpoint or WebSocket message from the notch
2. Spins up a Claude agent with relevant tools (Gmail, Calendar, etc.)
3. Agent executes, streaming progress events back to the notch via WS
4. If the agent produces a draft (email, Slack message), it pauses for approval
5. User approves/rejects from the notch UI → backend continues or cancels

**Why it's cool:** Your laptop notch becomes a command center. Delegate and forget — it'll tap you when it needs you.

**Effort:** Medium-high. Need OAuth flows for each service, tool definitions, approval flow.

---

### 2. AGENT MONITOR (omni-monitoring)

**What:** Danotch watches agents running across ALL your platforms — Claude Code sessions, Cursor background agents, Notion agents, any MCP-connected agent — and surfaces their status in one place.

**How it works:**
- Poll or subscribe to agent status from various sources
- Normalize into a common task model (already have `SubagentTask`)
- Show unified feed in the notch: which agents are running, what they're doing, how long they've been at it

**Sources to monitor:**
- Claude Code (via CLI status / process list)
- Cursor (background agent sessions)
- GitHub Actions (CI/CD as "agents")
- Notion agents (via Notion API)
- Custom agents (anything that speaks the Danotch WS protocol)

**Implementation:**
1. Polling service in backend that checks each source on interval
2. Adapter pattern: each source implements a `AgentSource` interface
3. Merged into unified task stream, pushed to notch via WS
4. Notch shows grouped by source with colored badges

**Why it's cool:** Single pane of glass for everything autonomous running on your behalf. Nobody has this.

**Effort:** Medium. Each source is a separate adapter. Start with Claude Code + GitHub Actions.

---

### 3. PROACTIVE INTELLIGENCE AGENTS

**What:** Agents that run on a schedule or trigger, surfacing info BEFORE you ask.

**Agent ideas:**

#### Morning Briefing Agent
- Runs at 8am (or when you open your laptop)
- Checks: calendar for today, unread priority emails, open Linear tickets, overnight Slack mentions
- Composes a 3-bullet summary, shows in the notch
- "3 meetings today. Sarah needs roadmap feedback by EOD. PR #287 has 2 approvals."

#### Meeting Prep Agent
- Triggers 10 min before each calendar event
- Pulls context: recent emails/Slack with attendees, relevant Linear tickets, last meeting notes
- Shows prep card in notch: "1:1 with Alex in 10m — he mentioned being blocked on the API migration yesterday"

#### PR Watch Agent
- Monitors your open PRs on GitHub
- Notifies via notch when: CI passes/fails, review requested, comments added, approved
- Can auto-draft responses to review comments

#### Inbox Zero Agent
- Continuously triages your inbox
- Categorizes: urgent / needs reply / FYI / spam
- Drafts replies for "needs reply" emails, queues for your approval
- Goal: you never open Gmail, just approve drafts from the notch

**Implementation:**
1. Cron/scheduler in backend (node-cron)
2. Each proactive agent is a scheduled job that runs a Claude agent with tools
3. Results pushed to notch as "suggestion" cards
4. Tap to expand, approve actions, or dismiss

**Why it's cool:** The notch becomes proactive, not reactive. It knows what you need before you do.

**Effort:** Low-medium per agent. The scheduling infra is shared.

---

### 4. WEB & SOCIAL AGENTS

#### Web Search Agent
- "What's the latest on the OpenAI drama?" → agent searches, reads articles, summarizes
- Shows result in notch as a compact card
- Can go deep: "find me flights SFO to JFK under $300 next weekend"

#### Twitter/X Monitor Agent
- Track keywords, accounts, or trending topics
- "Watch for any tweets about our product launch"
- Summarizes relevant tweets, shows in notch feed
- Can draft replies for your approval

#### Research Agent
- "Research the competitive landscape for AI code editors"
- Runs for 5-10 minutes, searches web, reads pages, compiles report
- Pushes progress to notch, final report as expandable card

**Implementation:**
- Web search: Brave Search API or Tavily (built for agents)
- Twitter: X API v2 (search/stream endpoints)
- Research: multi-step agent with web_search + web_read tools
- All results flow through the same WS event protocol

**Why it's cool:** Your notch is a research assistant that works while you work.

**Effort:** Low (web search), Medium (Twitter), Medium-high (deep research).

---

### 5. QUICK ACTIONS FROM THE NOTCH

**What:** Tiny actions you can fire from the notch without context-switching.

- **Quick capture:** Type a thought → agent routes it (task to Linear, note to Notion, reminder to Calendar)
- **Quick reply:** See an email notification → type reply in notch → agent sends it
- **Quick delegate:** Highlight text anywhere on screen → keyboard shortcut → notch captures it as a task

**Implementation:**
1. Add a text input to the notch UI (the input bar is already mocked)
2. Backend receives text, uses Claude to classify intent and route
3. Classification: is this a task? a reply? a note? a question?
4. Route to appropriate agent/tool

**Why it's cool:** The notch becomes a universal command line for your digital life.

**Effort:** Medium. The routing/classification is the interesting part.

---

### 6. AGENT MEMORY & CONTEXT

**What:** Agents remember past interactions and build up knowledge about you.

- What emails you approve vs reject → learns your voice
- What tasks you delegate often → suggests proactively
- Your preferences: "always CC mike on design emails", "I prefer window seats"
- Project context: "the Q2 roadmap is in this Notion page", "Sarah owns the API migration"

**Implementation:**
- Vector store (local SQLite + embeddings, or Chroma)
- Agent memory fed as context on each run
- Preference extraction: after each approval/rejection, agent notes the pattern

**Why it's cool:** Agents get better the more you use them. Feels like a PA that actually knows you.

**Effort:** Medium. Embedding + retrieval pipeline, preference learning.

---

## What to Build First (Priority Order)

| Phase | What | Why |
|-------|------|-----|
| **1** | Backend infra: Claude Agent SDK, WS events, one real tool (Gmail or web search) | Proves the loop works end-to-end |
| **2** | Quick actions input bar + intent routing | Makes the notch interactive, not just a display |
| **3** | 2-3 proactive agents (morning brief, meeting prep, PR watch) | Biggest "wow" factor — the notch comes alive |
| **4** | Agent monitor (Claude Code + GitHub Actions) | Differentiator — nobody has unified agent monitoring |
| **5** | Web/social agents (search, Twitter) | Expands utility |
| **6** | Memory & context | Makes everything smarter over time |

## Phase 1 Specifics

The minimum to get real agents flowing:

```
backend/
├── src/
│   ├── index.ts              — Express + WS server
│   ├── agent/
│   │   ├── runner.ts         — Agent execution loop (Claude SDK)
│   │   └── tools/            — Tool definitions
│   │       ├── gmail.ts
│   │       ├── web-search.ts
│   │       └── calendar.ts
│   ├── events/
│   │   └── ws.ts             — WebSocket event emitter (talks to notch)
│   └── routes/
│       └── tasks.ts          — REST: create task, list tasks, approve/reject
├── package.json
└── tsconfig.json
```

1. Convert backend to TypeScript
2. Install `@anthropic-ai/sdk` (or Claude Agent SDK)
3. Implement one tool (web search via Tavily — no OAuth needed)
4. Wire agent progress events to existing WS protocol
5. Test: send a task from the notch → agent runs → results appear in notch

That's the spark. Everything else builds on top.
