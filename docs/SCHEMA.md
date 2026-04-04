# Danotch Backend Schema & Architecture

## Overview

Everything lives in **Supabase** (Postgres + Auth + RLS). The backend (Node/TS) is the single API surface — the Swift app and any future clients never talk to Supabase directly.

```
┌─────────────┐     ┌──────────────────┐     ┌──────────────┐
│  Swift App  │────▶│  Backend (Node)  │────▶│   Supabase   │
│  (notch UI) │◀────│  Express + WS    │────▶│  (Postgres)  │
└─────────────┘     │                  │     └──────────────┘
                    │  - REST API      │
                    │  - WebSocket     │     ┌──────────────┐
                    │  - Agent runner  │────▶│  Composio    │
                    │  - Scheduler     │     │  (app OAuth) │
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

The `user_id` (UUID) from `sub` claim flows through the entire system — into Composio calls, scheduled tasks, notifications.

---

## 2. Database Tables (Supabase Postgres)

### `user_profiles`

Created on first login. Central user record. On signup, backend also creates one `connected_apps` row per supported app (all inactive by default).

```sql
CREATE TABLE user_profiles (
  id              UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email           TEXT NOT NULL,
  full_name       TEXT,
  avatar_url      TEXT,
  
  -- Usage / billing
  plan            TEXT DEFAULT 'free',      -- free, pro, enterprise
  daily_cost_usd  REAL DEFAULT 0,
  cost_reset_date DATE DEFAULT CURRENT_DATE,
  
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_user_profiles_email ON user_profiles(email);
```

**On signup trigger** (backend or Supabase function):

```sql
-- Auto-create connected_apps rows for all supported apps
INSERT INTO connected_apps (user_id, app_type, active) VALUES
  (NEW.id, 'gmail', FALSE),
  (NEW.id, 'googlecalendar', FALSE),
  (NEW.id, 'googledocs', FALSE),
  (NEW.id, 'linear', FALSE);
```

---

### `connected_apps`

One row per app per user. Created at signup (all inactive). Composio manages the actual OAuth tokens — we just store connection metadata.

```sql
CREATE TABLE connected_apps (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
  
  app_type          TEXT NOT NULL,           -- gmail, googlecalendar, googledocs, linear
  composio_conn_id  TEXT,                    -- Composio connected_account_id (their UUID)
  integration_id    TEXT,                    -- Composio integration ID used for OAuth
  
  active            BOOLEAN DEFAULT FALSE,   -- whether the app is connected and usable
  account_email     TEXT,                    -- e.g. which Google account
  
  connected_at      TIMESTAMPTZ,            -- when OAuth was completed
  disconnected_at   TIMESTAMPTZ,
  
  metadata          JSONB DEFAULT '{}',      -- app-specific data
  
  UNIQUE(user_id, app_type)
);

CREATE INDEX idx_connected_apps_user ON connected_apps(user_id);
CREATE INDEX idx_connected_apps_active ON connected_apps(user_id, active) WHERE active = TRUE;
```

**App types (initial):**
| app_type | Composio App | Notes |
|----------|-------------|-------|
| `gmail` | `GMAIL` | Read, send, draft |
| `googlecalendar` | `GOOGLECALENDAR` | Events CRUD |
| `googledocs` | `GOOGLEDOCS` | Create, edit docs |
| `linear` | `LINEAR` | Issues, projects |

**Connection flow:**
1. User taps "Connect" on an app → backend calls Composio to get OAuth URL
2. User completes OAuth → Composio callback
3. Backend sets `active = TRUE`, stores `composio_conn_id`, `account_email`, `connected_at`
4. Disconnect: sets `active = FALSE`, `disconnected_at`, clears `composio_conn_id`

---

### `threads`

Conversation history. One thread per chat session.

```sql
CREATE TABLE threads (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
  
  title       TEXT,                          -- auto-generated or user-set
  
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  updated_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_threads_user ON threads(user_id);
CREATE INDEX idx_threads_updated ON threads(user_id, updated_at DESC);
```

---

### `messages`

Individual messages within threads. Two roles only: `user` and `assistant`. Tool usage, draft cards, and token counts are stored as metadata on the assistant message.

```sql
CREATE TABLE messages (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  thread_id   UUID NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
  
  role        TEXT NOT NULL,                 -- user, assistant
  content     TEXT,                          -- message text / markdown
  
  -- Everything else lives in metadata
  metadata    JSONB DEFAULT '{}',
  -- For assistant messages, metadata can include:
  -- {
  --   "tools_used": [
  --     { "name": "gmail", "action": "GMAIL_LIST_EMAILS", "input": {...}, "output": {...} },
  --     { "name": "web_search", "query": "..." }
  --   ],
  --   "draft": { "type": "email", "title": "...", "preview": "...", "recipient": "...", "params": {...} },
  --   "draft_status": "pending" | "approved" | "rejected",
  --   "input_tokens": 1234,
  --   "output_tokens": 567,
  --   "model": "claude-sonnet-4-20250514"
  -- }
  
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

### `notifications`

Output from scheduled tasks, proactive results, and system messages. Pushed to notch app via WebSocket when connected, stored here for later retrieval.

```sql
CREATE TABLE notifications (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
  
  source      TEXT NOT NULL,                 -- scheduled_task, system
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

## 3. Proactive System

The backend runs a **scheduler loop** that checks `scheduled_tasks` for due tasks.

### Architecture

```
Backend Process
  └── Scheduler (setInterval, runs every 30s)
        ├── Query: SELECT * FROM scheduled_tasks WHERE enabled AND next_run_at <= NOW()
        ├── For each due task:
        │   ├── Run agent with task.prompt (scoped to user_id)
        │   ├── Agent has access to connected apps
        │   ├── Store result in last_result
        │   ├── Create notification row
        │   ├── Update last_run_at, next_run_at, run_count
        │   └── Push notification to user via WebSocket (if connected)
        └── Plan-based throttling enforced at query time
```

### Poll-type tasks (e.g. "check Gmail every 10min")

```
Scheduler picks up poll task
  → Agent fetches recent emails via Composio
  → Compares against last_result to find new items
  → If new items: summarizes + creates notification
  → Updates last_result with current state
```

---

## 4. User ID Flow

```
Supabase Auth (JWT with sub: userId)
        │
        ▼
  Backend verifyToken() → userId (UUID)
        │
        ├──▶ Supabase queries:     .eq('user_id', userId)
        ├──▶ Composio actions:     entity_id = userId
        ├──▶ Agent tools:          userId in context (via closure or AsyncLocalStorage)
        ├──▶ Scheduled tasks:      userId from scheduled_tasks row
        └──▶ WebSocket sessions:   mapped userId ↔ socket for push notifications
```

---

## 5. Backend API Surface

### Auth
| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/auth/signup` | Email+password signup (proxies Supabase), creates profile + connected_apps rows |
| `POST` | `/auth/login` | Email+password login |
| `POST` | `/auth/google` | Google OAuth initiation |
| `POST` | `/auth/refresh` | Refresh JWT |
| `GET` | `/auth/me` | Current user profile |

### Profile
| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/profile` | Get user profile + connected apps |
| `PATCH` | `/api/profile` | Update name, avatar, etc. |

### Connected Apps
| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/apps` | List all apps for user (active and inactive) |
| `POST` | `/api/apps/:app/connect` | Get Composio OAuth URL |
| `POST` | `/api/apps/:app/disconnect` | Disconnect app (sets active=false) |

### Chat / Agent
| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/chat` | Simple chat (no tools) |
| `POST` | `/api/agent` | Agent with tools |
| `GET` | `/api/threads` | List threads |
| `GET` | `/api/threads/:id` | Get thread with messages |
| `DELETE` | `/api/threads/:id` | Delete thread |

### Scheduled Tasks
| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/tasks` | List scheduled tasks |
| `POST` | `/api/tasks` | Create scheduled task |
| `PATCH` | `/api/tasks/:id` | Update task (enable/disable, edit) |
| `DELETE` | `/api/tasks/:id` | Delete task |
| `POST` | `/api/tasks/:id/run` | Run task immediately |

### Notifications
| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/notifications` | List notifications |
| `POST` | `/api/notifications/:id/read` | Mark as read |

---

## 6. Agent Tool Availability

Tools available to the agent depend on which apps are active:

```typescript
const TOOL_REQUIREMENTS: Record<string, string> = {
  gmail:          'gmail',
  googlecalendar: 'googlecalendar',
  googledocs:     'googledocs',
  linear:         'linear',
};

// Always available (no connection needed)
const CORE_TOOLS = [
  'web_search',        // Web search
  'web_fetch',         // Fetch URL content
  'ask_user',          // Ask user a question (pushes to notch)
];

function getAvailableTools(activeApps: string[]): Tool[] {
  const tools = [...CORE_TOOLS];
  for (const [tool, requiredApp] of Object.entries(TOOL_REQUIREMENTS)) {
    if (activeApps.includes(requiredApp)) {
      tools.push(tool);
    }
  }
  return tools;
}
```

---

## 7. Full Table Summary

| Table | Purpose | Key Relations |
|-------|---------|--------------|
| `user_profiles` | User account, plan | auth.users (Supabase) |
| `connected_apps` | Composio app connections (pre-created per user) | user_profiles |
| `threads` | Conversation sessions | user_profiles |
| `messages` | Chat messages (user + assistant, tools in metadata) | threads, user_profiles |
| `scheduled_tasks` | Proactive/recurring tasks | user_profiles |
| `notifications` | Push notifications from scheduled tasks | user_profiles |

**External:**
| Service | Purpose |
|---------|---------|
| Supabase Auth | JWT auth, Google OAuth, email/password |
| Composio | OAuth token management, app API execution |

---

## 8. Environment Variables

```env
# Supabase
SUPABASE_URL=https://xxx.supabase.co
SUPABASE_ANON_KEY=eyJ...
SUPABASE_SERVICE_KEY=eyJ...         # Server-side only, bypasses RLS
SUPABASE_JWT_SECRET=xxx             # For JWT verification

# Composio
COMPOSIO_API_KEY=xxx
COMPOSIO_INTEGRATION_GMAIL=xxx     # Integration IDs for each app
COMPOSIO_INTEGRATION_GCAL=xxx
COMPOSIO_INTEGRATION_GDOCS=xxx
COMPOSIO_INTEGRATION_LINEAR=xxx

# Anthropic
ANTHROPIC_API_KEY=sk-ant-xxx
```
