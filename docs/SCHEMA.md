# Danotch Backend Schema & Architecture

## Overview

Everything lives in **Supabase** (Postgres + Auth + RLS) except smart memory which uses **mem0 Cloud**. The backend (Node/TS) is the single API surface — the Swift app and any future clients never talk to Supabase or mem0 directly.

```
┌─────────────┐     ┌──────────────────┐     ┌──────────────┐
│  Swift App  │────▶│  Backend (Node)  │────▶│   Supabase   │
│  (notch UI) │◀────│  Express + WS    │────▶│  (Postgres)  │
└─────────────┘     │                  │────▶│              │
                    │  - REST API      │     └──────────────┘
                    │  - WebSocket     │
                    │  - Agent runner  │     ┌──────────────┐
                    │  - Scheduler     │────▶│  mem0 Cloud  │
                    │                  │     │  (memory)    │
                    │                  │     └──────────────┘
                    │                  │
                    │                  │     ┌──────────────┐
                    │                  │────▶│  Composio    │
                    │                  │     │  (app OAuth) │
                    │                  │     └──────────────┘
                    │                  │
                    │                  │     ┌──────────────┐
                    │                  │────▶│   Indexer     │
                    │                  │     │  (separate)   │
                    └──────────────────┘     └──────────────┘
```

---

## 1. Auth

Supabase Auth handles everything. Two methods:

- **Google OAuth** — Supabase OAuth provider, redirect-based flow
- **Email + Password** — Supabase `signUp` / `signInWithPassword`

Backend verifies JWTs on every request:

```typescript
// Every protected endpoint
const user = verifyToken(req.headers.authorization) 
// Returns { sub: userId, email, ... } from Supabase JWT
```

WebSocket auth via query param: `ws://localhost:7778/ws?token=<JWT>`

The `user_id` (UUID) from `sub` claim flows through the entire system — into Composio calls, mem0 queries, indexer requests, scheduled tasks.

---

## 2. Database Tables (Supabase Postgres)

### `user_profiles`

Created on first login. Central user record.

```sql
CREATE TABLE user_profiles (
  id              UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email           TEXT NOT NULL,
  full_name       TEXT,
  avatar_url      TEXT,
  
  -- Onboarding
  onboarding_step TEXT DEFAULT 'welcome',  -- welcome, connect_apps, indexing, done
  setup_status    TEXT DEFAULT 'pending',   -- pending, in_progress, completed, failed
  
  -- Preferences
  preferences     JSONB DEFAULT '{}',
  -- e.g. { "timezone": "America/Los_Angeles", "notification_frequency": "realtime" }
  
  -- Usage / billing
  plan            TEXT DEFAULT 'free',      -- free, pro, enterprise
  daily_cost_usd  REAL DEFAULT 0,
  cost_reset_date DATE DEFAULT CURRENT_DATE,
  
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_user_profiles_email ON user_profiles(email);
```

---

### `connected_apps`

One row per connected app per user. Composio manages the actual OAuth tokens — we just store metadata.

```sql
CREATE TABLE connected_apps (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
  
  app_type          TEXT NOT NULL,           -- gmail, googlecalendar, googledocs, linear
  composio_conn_id  TEXT,                    -- Composio connected_account_id (their UUID)
  integration_id    TEXT,                    -- Composio integration ID used for OAuth
  
  status            TEXT DEFAULT 'active',   -- active, disconnected, error
  account_email     TEXT,                    -- e.g. which Google account
  scopes            TEXT[],                  -- OAuth scopes granted
  
  connected_at      TIMESTAMPTZ DEFAULT NOW(),
  last_synced_at    TIMESTAMPTZ,            -- last successful indexing
  disconnected_at   TIMESTAMPTZ,
  
  metadata          JSONB DEFAULT '{}',      -- app-specific data
  
  UNIQUE(user_id, app_type)
);

CREATE INDEX idx_connected_apps_user ON connected_apps(user_id);
CREATE INDEX idx_connected_apps_type ON connected_apps(user_id, app_type);
```

**App types (initial):**
| app_type | Composio App | Notes |
|----------|-------------|-------|
| `gmail` | `GMAIL` | Read, send, draft |
| `googlecalendar` | `GOOGLECALENDAR` | Events CRUD |
| `googledocs` | `GOOGLEDOCS` | Create, edit docs |
| `linear` | `LINEAR` | Issues, projects |

---

### `threads`

Conversation history. One thread per chat session.

```sql
CREATE TABLE threads (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
  
  title       TEXT,                          -- auto-generated or user-set
  summary     TEXT,                          -- LLM-generated thread summary
  
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  updated_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_threads_user ON threads(user_id);
CREATE INDEX idx_threads_updated ON threads(user_id, updated_at DESC);
```

---

### `messages`

Individual messages within threads. Separate table (not JSONB array) for queryability and pagination.

```sql
CREATE TABLE messages (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  thread_id   UUID NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
  
  role        TEXT NOT NULL,                 -- user, assistant, tool, system
  content     TEXT,                          -- message text / markdown
  
  -- Tool-specific
  tool_name   TEXT,                          -- e.g. "gmail", "bash", "memory_search"
  tool_input  JSONB,                         -- tool call parameters
  tool_output JSONB,                         -- tool result
  
  -- Draft/approval
  draft       JSONB,                         -- { type, title, preview, recipient, params }
  draft_status TEXT,                         -- pending, approved, rejected (NULL if not a draft)
  
  -- Token tracking
  input_tokens  INT,
  output_tokens INT,
  
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_messages_thread ON messages(thread_id, created_at);
CREATE INDEX idx_messages_user ON messages(user_id);
```

---

### `scheduled_tasks`

Proactive / recurring tasks. The backend runs a scheduler that polls this table.

```sql
CREATE TABLE scheduled_tasks (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
  
  -- What to do
  name        TEXT NOT NULL,                 -- "Morning email summary"
  prompt      TEXT NOT NULL,                 -- The prompt to send to agent
  task_type   TEXT NOT NULL,                 -- scheduled, poll, event_driven
  
  -- Schedule (cron-style for scheduled, interval for polling)
  cron        TEXT,                          -- "0 8 * * *" (8am daily) — for scheduled
  interval_ms INT,                           -- 600000 (10min) — for poll type
  
  -- Targeting
  target_app  TEXT,                          -- gmail, googlecalendar, etc. (NULL = general)
  
  -- State
  enabled     BOOLEAN DEFAULT TRUE,
  last_run_at TIMESTAMPTZ,
  next_run_at TIMESTAMPTZ,
  last_result JSONB,                         -- { status, summary, error }
  run_count   INT DEFAULT 0,
  
  -- Plan-based throttling
  -- free: min interval 60min, max 5 tasks
  -- pro:  min interval 10min, max 50 tasks
  
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  updated_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_scheduled_user ON scheduled_tasks(user_id);
CREATE INDEX idx_scheduled_next ON scheduled_tasks(enabled, next_run_at)
  WHERE enabled = TRUE;
```

**Task types:**

| type | example | how it runs |
|------|---------|-------------|
| `scheduled` | "Summarize emails at 8am" | Cron expression, runs once at scheduled time |
| `poll` | "Check Gmail every 10min" | Interval-based, backend polls and diffs |
| `event_driven` | "When new Linear issue assigned" | Webhook-triggered (future, via Composio triggers) |

**Plan limits:**

| | Free | Pro |
|---|---|---|
| Max scheduled tasks | 5 | 50 |
| Min poll interval | 60 min | 10 min |
| Scheduled runs/day | 10 | unlimited |

---

### `index_state`

Tracks what's been indexed per user per app, for incremental reindexing.

```sql
CREATE TABLE index_state (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
  app_type        TEXT NOT NULL,              -- gmail, googledocs, etc.
  
  status          TEXT DEFAULT 'pending',     -- pending, running, completed, failed
  last_indexed_at TIMESTAMPTZ,
  items_indexed   INT DEFAULT 0,
  
  -- For incremental indexing
  sync_cursor     TEXT,                       -- app-specific cursor/token for pagination
  content_hashes  JSONB DEFAULT '{}',         -- { item_id: hash } for change detection
  
  error           TEXT,
  
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW(),
  
  UNIQUE(user_id, app_type)
);

CREATE INDEX idx_index_state_user ON index_state(user_id);
```

---

### `action_approvals`

Pending approval requests for sensitive actions (sending email, creating issues, etc.).

```sql
CREATE TABLE action_approvals (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
  thread_id   UUID REFERENCES threads(id) ON DELETE SET NULL,
  message_id  UUID REFERENCES messages(id) ON DELETE SET NULL,
  
  action_type TEXT NOT NULL,                 -- gmail_send, gmail_draft, calendar_create, linear_create_issue
  app_type    TEXT NOT NULL,                 -- gmail, googlecalendar, linear
  
  -- What the agent wants to do
  params      JSONB NOT NULL,                -- Full action parameters
  preview     JSONB NOT NULL,                -- { title, body_preview, recipient, ... } for UI display
  
  -- Resolution
  status      TEXT DEFAULT 'pending',        -- pending, approved, rejected, expired
  resolved_at TIMESTAMPTZ,
  edited_params JSONB,                       -- If user edited before approving
  
  expires_at  TIMESTAMPTZ DEFAULT NOW() + INTERVAL '1 hour',
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_approvals_user ON action_approvals(user_id, status)
  WHERE status = 'pending';
```

**Actions requiring approval:**

| action_type | app | trigger |
|-------------|-----|---------|
| `gmail_send` | gmail | Sending an email |
| `gmail_draft` | gmail | Creating a draft |
| `gmail_reply` | gmail | Replying to a thread |
| `calendar_create` | googlecalendar | Creating an event |
| `linear_create_issue` | linear | Creating an issue |
| `googledocs_create` | googledocs | Creating a document |

---

## 3. Memory Layer (mem0 Cloud)

mem0 handles the "smart" memory — automatically extracting facts from conversations, deduplicating, and enabling semantic search. Supabase stores raw threads/messages; mem0 stores distilled knowledge.

### Integration

```typescript
import MemoryClient from 'mem0ai';

const mem0 = new MemoryClient({ apiKey: process.env.MEM0_API_KEY });

// After each conversation turn, feed the exchange to mem0
await mem0.add(
  [
    { role: "user", content: userMessage },
    { role: "assistant", content: assistantResponse }
  ],
  { user_id: userId }
);

// Agent's memory_search tool
const results = await mem0.search(query, { user_id: userId, limit: 10 });

// Get all memories for a user (settings page, etc.)
const all = await mem0.getAll({ user_id: userId });

// User deletes a memory
await mem0.delete(memoryId);
```

### What gets stored in mem0 vs Supabase

| Data | Where | Why |
|------|-------|-----|
| Raw conversation messages | Supabase `messages` | Full history, pagination, audit |
| Extracted facts/preferences | mem0 | "User prefers dark mode", "Works at Acme Corp" |
| Connected app data (indexed) | Indexer (vector store) | Semantic search over emails, docs, etc. |
| Thread metadata | Supabase `threads` | Listing, ordering, summaries |

### Memory in agent context

On each agent run, inject relevant memories into the system prompt:

```typescript
const memories = await mem0.search(userMessage, { user_id: userId, limit: 5 });
const memoryContext = memories.map(m => `- ${m.memory}`).join('\n');

const systemPrompt = `
...
## What you know about this user:
${memoryContext}
...
`;
```

---

## 4. Indexer Service (Separate Process)

Runs as a separate Node service. The backend proxies requests to it. Responsible for fetching data from connected apps via Composio and storing embeddings for semantic search.

```
Backend ──(HTTP)──▶ Indexer Service ──▶ Composio (fetch data)
                                    ──▶ Vector Store (store embeddings)
```

### What gets indexed

| App | What | How |
|-----|------|-----|
| Gmail | Last 90 days of emails (subject, body, sender, date) | Composio `GMAIL_LIST_EMAILS` + `GMAIL_GET_EMAIL` |
| Google Calendar | Next 30 + past 30 days of events | Composio `GOOGLECALENDAR_LIST_EVENTS` |
| Google Docs | All accessible docs (title, content) | Composio `GOOGLEDOCS_LIST_DOCS` + content fetch |
| Linear | Open issues, recent closed issues, comments | Composio `LINEAR_LIST_ISSUES` |

### Vector store options

Since we're already on Supabase, use **pgvector** extension in the same Postgres instance:

```sql
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE indexed_content (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
  app_type    TEXT NOT NULL,
  
  -- Source reference
  external_id TEXT NOT NULL,                 -- Gmail message ID, Doc ID, Issue ID, etc.
  source_url  TEXT,                          -- Direct link to the item
  
  -- Content
  title       TEXT,
  content     TEXT NOT NULL,                 -- Raw text content
  embedding   VECTOR(1536),                  -- OpenAI text-embedding-3-small (1536 dims)
  
  -- Metadata for filtering
  author      TEXT,
  item_date   TIMESTAMPTZ,                   -- When the original item was created/sent
  content_hash TEXT,                          -- For change detection on reindex
  
  metadata    JSONB DEFAULT '{}',            -- App-specific fields
  
  indexed_at  TIMESTAMPTZ DEFAULT NOW(),
  
  UNIQUE(user_id, app_type, external_id)
);

-- HNSW index for fast similarity search
CREATE INDEX idx_content_embedding ON indexed_content
  USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);

CREATE INDEX idx_content_user_app ON indexed_content(user_id, app_type);
CREATE INDEX idx_content_date ON indexed_content(user_id, item_date DESC);
```

### Indexer endpoints (internal, backend-only)

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/index/app/:app` | Index a specific app for a user |
| `POST` | `/index/all` | Index all connected apps |
| `POST` | `/reindex/app/:app` | Incremental reindex (uses sync_cursor + content_hash) |
| `GET` | `/search` | Semantic search: `?q=...&user_id=...&app=...&limit=10` |
| `GET` | `/health` | Health check |

---

## 5. Proactive System

The backend runs a **scheduler loop** that checks `scheduled_tasks` for due tasks.

### Architecture

```
Backend Process
  └── Scheduler (setInterval, runs every 30s)
        ├── Query: SELECT * FROM scheduled_tasks WHERE enabled AND next_run_at <= NOW()
        ├── For each due task:
        │   ├── Run agent with task.prompt (scoped to user_id)
        │   ├── Agent has access to connected apps + memory
        │   ├── Store result in last_result
        │   ├── Update last_run_at, next_run_at, run_count
        │   └── Push notification to user via WebSocket (if connected)
        └── Plan-based throttling enforced at query time
```

### Poll-type tasks (e.g. "check Gmail every 10min")

```
Scheduler picks up poll task
  → Agent fetches recent emails via Composio
  → Compares against last_result to find new items
  → If new items: summarizes + pushes notification to notch app
  → Updates last_result with current state
```

### Notification delivery

When a proactive task produces output:
1. If user's notch app is connected via WebSocket → push immediately
2. Store in a `notifications` table for later retrieval

```sql
CREATE TABLE notifications (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
  
  source      TEXT NOT NULL,                 -- scheduled_task, proactive, system
  source_id   UUID,                          -- scheduled_task.id if applicable
  
  title       TEXT NOT NULL,
  body        TEXT,
  action_url  TEXT,                          -- deep link or external URL
  
  read        BOOLEAN DEFAULT FALSE,
  
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_notifications_user ON notifications(user_id, read, created_at DESC);
```

---

## 6. User ID Flow

```
Supabase Auth (JWT with sub: userId)
        │
        ▼
  Backend verifyToken() → userId (UUID)
        │
        ├──▶ Supabase queries:     .eq('user_id', userId)
        ├──▶ Composio actions:     entity_id = userId
        ├──▶ mem0 calls:           user_id = userId
        ├──▶ Indexer requests:     payload.user_id = userId (backend injects, never trust client)
        ├──▶ Agent tools:          userId in context (via closure or AsyncLocalStorage)
        ├──▶ Scheduled tasks:      userId from scheduled_tasks row
        └──▶ WebSocket sessions:   mapped userId ↔ socket for push notifications
```

---

## 7. Backend API Surface (Updated)

### Auth
| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/auth/signup` | Email+password signup (proxies Supabase) |
| `POST` | `/auth/login` | Email+password login |
| `POST` | `/auth/google` | Google OAuth initiation |
| `POST` | `/auth/refresh` | Refresh JWT |
| `GET` | `/auth/me` | Current user profile |

### Profile
| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/profile` | Get user profile + connected apps |
| `PATCH` | `/api/profile` | Update preferences, name, etc. |

### Connected Apps
| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/apps` | List connected apps for user |
| `POST` | `/api/apps/:app/connect` | Get Composio OAuth URL |
| `POST` | `/api/apps/:app/disconnect` | Disconnect app |
| `GET` | `/api/apps/:app/status` | Check connection status |

### Chat / Agent
| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/chat` | Simple chat (no tools) |
| `POST` | `/api/agent` | Agent with tools |
| `GET` | `/api/threads` | List threads |
| `GET` | `/api/threads/:id` | Get thread with messages |
| `DELETE` | `/api/threads/:id` | Delete thread |

### Memory
| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/memory` | List all memories (from mem0) |
| `GET` | `/api/memory/search?q=...` | Search memories |
| `DELETE` | `/api/memory/:id` | Delete a memory |

### Indexing
| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/index/all` | Index all connected apps |
| `POST` | `/api/index/:app` | Index specific app |
| `POST` | `/api/reindex/:app` | Incremental reindex |
| `GET` | `/api/index/status` | Index state per app |
| `GET` | `/api/search?q=...&app=...` | Search indexed content |

### Scheduled Tasks
| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/tasks` | List scheduled tasks |
| `POST` | `/api/tasks` | Create scheduled task |
| `PATCH` | `/api/tasks/:id` | Update task (enable/disable, edit) |
| `DELETE` | `/api/tasks/:id` | Delete task |
| `POST` | `/api/tasks/:id/run` | Run task immediately |

### Approvals
| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/approvals` | List pending approvals |
| `POST` | `/api/approvals/:id/approve` | Approve (with optional edits) |
| `POST` | `/api/approvals/:id/reject` | Reject |

### Notifications
| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/notifications` | List notifications |
| `POST` | `/api/notifications/:id/read` | Mark as read |

---

## 8. Agent Tool Availability

Tools available to the agent depend on connected apps:

```typescript
const TOOL_REQUIREMENTS: Record<string, string> = {
  gmail:          'gmail',
  googlecalendar: 'googlecalendar',
  googledocs:     'googledocs',
  linear:         'linear',
};

// Always available (no connection needed)
const CORE_TOOLS = [
  'memory_search',     // Search mem0 memories
  'content_search',    // Search indexed content (pgvector)
  'web_search',        // Web search (Exa or similar)
  'web_fetch',         // Fetch URL content
  'ask_user',          // Ask user a question (pushes to notch)
  'request_approval',  // Request approval for sensitive action
];

function getAvailableTools(connectedApps: string[]): Tool[] {
  const tools = [...CORE_TOOLS];
  for (const [tool, requiredApp] of Object.entries(TOOL_REQUIREMENTS)) {
    if (connectedApps.includes(requiredApp)) {
      tools.push(tool);
    }
  }
  return tools;
}
```

---

## 9. Full Table Summary

| Table | Purpose | Key Relations |
|-------|---------|--------------|
| `user_profiles` | User account, prefs, plan | auth.users (Supabase) |
| `connected_apps` | Composio app connections | user_profiles |
| `threads` | Conversation sessions | user_profiles |
| `messages` | Individual chat messages | threads, user_profiles |
| `scheduled_tasks` | Proactive/recurring tasks | user_profiles |
| `index_state` | Per-app indexing progress | user_profiles |
| `indexed_content` | Vector embeddings (pgvector) | user_profiles |
| `action_approvals` | Pending sensitive actions | user_profiles, threads, messages |
| `notifications` | Push notifications queue | user_profiles |

**External:**
| Service | Purpose |
|---------|---------|
| Supabase Auth | JWT auth, Google OAuth, email/password |
| Composio | OAuth token management, app API execution |
| mem0 Cloud | Smart memory (fact extraction, semantic search) |
| pgvector | Indexed content semantic search |

---

## 10. Environment Variables

```env
# Supabase
SUPABASE_URL=https://xxx.supabase.co
SUPABASE_ANON_KEY=eyJ...
SUPABASE_SERVICE_KEY=eyJ...         # Server-side only, bypasses RLS
SUPABASE_JWT_SECRET=xxx             # For JWT verification

# mem0
MEM0_API_KEY=m0-xxx

# Composio
COMPOSIO_API_KEY=xxx
COMPOSIO_INTEGRATION_GMAIL=xxx     # Integration IDs for each app
COMPOSIO_INTEGRATION_GCAL=xxx
COMPOSIO_INTEGRATION_GDOCS=xxx
COMPOSIO_INTEGRATION_LINEAR=xxx

# Anthropic
ANTHROPIC_API_KEY=sk-ant-xxx

# Indexer
INDEXER_URL=http://127.0.0.1:3002
INDEXER_AUTH_TOKEN=xxx              # Shared secret between backend + indexer

# OpenAI (for embeddings)
OPENAI_API_KEY=sk-xxx               # text-embedding-3-small for pgvector
```
