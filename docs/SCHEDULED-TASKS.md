# Scheduled Tasks & Notifications — Implementation Plan

Keep it dead simple. No cron libraries, no job queues, no over-engineering.

---

## What We're Building

1. User says "check my emails every morning at 9" in chat → Claude calls `create_scheduled_task` tool → task created
2. Backend runs a loop every 30s, picks up due tasks, runs Claude, saves result
3. Result becomes a notification pushed to the notch app
4. User sees notifications in a notification panel / bell icon
5. Settings shows a read-only dashboard of tasks (toggle, delete)

---

## How Tasks Get Created: Agent Tools

Scheduled tasks are created through **natural language via Claude agent tools** — not manual forms. The agent translates intent into cron expressions and structured task data.

### Flow

```
User: "Every weekday morning at 9, summarize my unread emails"
        ↓
Claude (agent mode) interprets intent, calls tool:
        ↓
create_scheduled_task({
  name: "Morning email summary",
  prompt: "Summarize my unread emails from the last 12 hours",
  task_type: "scheduled",
  cron: "0 9 * * 1-5"
})
        ↓
Tool handler: validates cron, inserts into scheduled_tasks,
              computes next_run_at, returns confirmation
        ↓
Claude responds: "Done — I'll summarize your emails every weekday at 9am.
                  Next run: tomorrow at 9:00 AM"
```

Claude already knows cron syntax natively, so it handles the translation from natural language ("twice a day", "every Monday", "every 30 minutes") to cron.

### Agent Tools

These are registered as tools available to the agent in `runAgent()`:

| Tool | Params | What it does |
|------|--------|-------------|
| `create_scheduled_task` | `name`, `prompt`, `task_type` (scheduled/poll), `cron?`, `interval_ms?`, `target_app?` | Validates, inserts row, computes next_run_at, returns task ID + next run time |
| `list_scheduled_tasks` | *(none)* | Returns user's tasks with name, schedule, enabled, last_run, next_run |
| `update_scheduled_task` | `id`, `enabled?`, `name?`, `prompt?`, `cron?`, `interval_ms?` | Updates fields, recomputes next_run_at if schedule changed |
| `delete_scheduled_task` | `id` | Deletes the task |

Tool implementations live in `src/tools/scheduled.ts`. Each tool receives `userId` from the agent context (same pattern as DB persistence in runner).

### Settings UI Role

The settings panel is a **dashboard, not a creation form**. Shows:
- List of scheduled tasks (name, schedule description, next run, enabled toggle)
- Delete button per task
- "Run Now" button per task for testing
- An "Add" button that just opens the chat with a nudge ("tell me what to schedule")

This keeps the UI minimal — the agent does the heavy lifting.

---

## Phase 1: Backend Scheduler (no UI yet, just the engine)

### Step 1: Install cron parser

We need ONE dependency to parse cron expressions into "next run" times:

```
npm install cron-parser
```

That's it. No job queue, no bull, no agenda. Just a `setInterval` + a cron parser.

### Step 2: Create `src/scheduler/index.ts`

The entire scheduler is ~80 lines:

```
┌──────────────────────────────────────────────────────────┐
│              Scheduler Loop                               │
│                                                           │
│  setInterval(tick, 30_000)                                │
│                                                           │
│  tick():                                                  │
│    1. SELECT * FROM scheduled_tasks                       │
│       WHERE enabled = true AND next_run_at <= NOW()       │
│                                                           │
│    2. For each due task (synchronous, fast):              │
│       a. Update next_run_at immediately (prevents         │
│          next tick from picking it up again)               │
│       b. Fire off executeTask() in background             │
│                                                           │
│  executeTask(taskId):                                     │
│    1. Re-fetch task: SELECT * WHERE id = taskId           │
│       → If not found or enabled = false → SKIP            │
│       (handles delete/disable between tick and execution) │
│                                                           │
│    2. Run Claude with task.prompt                         │
│    3. Save result to last_result, increment run_count     │
│    4. Create notification row                             │
│    5. Push notification via WebSocket                     │
│                                                           │
│    All wrapped in try/catch — failure saves error         │
│    to last_result and still creates error notification    │
└──────────────────────────────────────────────────────────┘
```

Key decisions:
- **No concurrency control needed** — 30s tick is slow enough that tasks won't overlap (Claude calls take 5-15s)
- **If backend restarts**, it just picks up from `next_run_at` — no state lost
- **Each task runs independently** — wrapped in try/catch, failure saves error to `last_result` and still creates a notification (with error status)
- Use existing `runChat()` from runner.ts — scheduled tasks are just automated chat messages

### Step 3: Create `src/scheduler/compute-next.ts`

One function: `computeNextRun(cron: string, lastRun: Date): Date`

Uses `cron-parser` to get the next occurrence after `lastRun`. For `poll` type tasks, just does `new Date(Date.now() + interval_ms)`.

### Step 4: Wire into `index.ts`

```typescript
import { startScheduler } from './scheduler/index.js';
// After app.listen:
startScheduler(notch);
```

### Step 5: Create `src/routes/scheduled.ts`

CRUD endpoints for scheduled tasks:

| Method | Path | What it does |
|--------|------|-------------|
| `GET` | `/api/scheduled` | List user's scheduled tasks |
| `POST` | `/api/scheduled` | Create a scheduled task |
| `PATCH` | `/api/scheduled/:id` | Update (enable/disable, edit prompt/cron) |
| `DELETE` | `/api/scheduled/:id` | Delete |
| `POST` | `/api/scheduled/:id/run` | Run immediately (for testing) |

All require auth. Validation:
- `cron` must be valid (parse it, reject if error)
- `name` and `prompt` required
- `task_type` must be `scheduled` or `poll`
- For `poll`, `interval_ms` required and >= 60000 (1min)

---

## Phase 2: Notifications Backend

### Step 6: Create `src/routes/notifications.ts`

| Method | Path | What it does |
|--------|------|-------------|
| `GET` | `/api/notifications` | List user's notifications (newest first, limit 50) |
| `POST` | `/api/notifications/:id/read` | Mark as read |
| `POST` | `/api/notifications/read-all` | Mark all as read |
| `GET` | `/api/notifications/unread-count` | Just the count (for badge) |

### Step 7: WebSocket push

When scheduler creates a notification, also push it to the notch app via WebSocket:

```json
{
  "type": "notification",
  "data": {
    "id": "uuid",
    "title": "Email Summary",
    "body": "You have 3 new emails...",
    "source": "scheduled_task",
    "created_at": "2026-04-05T09:00:00Z"
  }
}
```

The notch app already has a WebSocket connection — just add a new event type.

---

## Phase 3: Swift App UI

### Step 8: Notification bell in top bar

Add a bell icon next to the gear icon in `expandedTopBar`:
- Shows unread count badge (red dot or number)
- Clicking opens notification panel (new `NotchViewState.notifications`)
- Fetches `GET /api/notifications` on open
- Each notification row: title, body preview, timestamp, read/unread dot
- Tapping marks as read
- "Mark all read" button

### Step 9: Scheduled tasks dashboard in Settings

Add a "SCHEDULED" section in SettingsPanel (read-only dashboard, not a creation form):
- List of user's scheduled tasks with name, human-readable schedule, next run time
- Enable/disable toggle per task
- Delete button
- "Run Now" button for testing
- "Add" button that opens HOME tab chat with prefilled prompt nudge (e.g. "What would you like me to schedule?")

### Step 10: Handle notification WebSocket events

In `NotchViewModel`, handle the new `notification` event type from WebSocket:
- Add to a `@Published var notifications: [NotificationItem]` array
- Increment unread badge count
- Optional: play a subtle sound or flash the notch

---

## Phase 4: Presets (nice-to-have, not blocking)

Common scheduled task templates the user can pick from:

| Preset | Prompt | Schedule |
|--------|--------|----------|
| Morning Briefing | "Summarize my unread emails and today's calendar" | `0 9 * * *` (9am daily) |
| Email Check | "Check for new important emails and summarize" | Every 30min |
| EOD Recap | "Summarize what happened today across all my apps" | `0 18 * * 1-5` (6pm weekdays) |
| Weekly Review | "Give me a weekly summary of emails, tasks, and meetings" | `0 10 * * 1` (Mon 10am) |

These are just pre-filled name + prompt + cron — user can edit before saving.

---

## Implementation Order

```
Backend:
  1. npm install cron-parser
  2. src/scheduler/compute-next.ts  (cron → next Date)
  3. src/tools/scheduled.ts         (agent tool handlers: create/list/update/delete)
  4. Register tools in runAgent()   (add to agent's tool definitions)
  5. src/scheduler/index.ts         (30s tick loop)
  6. src/routes/scheduled.ts        (REST CRUD for settings dashboard)
  7. src/routes/notifications.ts    (list + read)
  8. Wire into index.ts
  9. Test: chat "schedule a daily email summary at 9am", verify DB row + scheduler picks it up

Swift app:
  10. NotificationItem model + ViewModel state
  11. Handle "notification" WebSocket event
  12. Notification bell + panel UI
  13. Scheduled task dashboard in settings (read-only list + toggle + delete)
  14. "Add" button → opens chat
  15. Presets (optional)
```

Steps 1-9 are backend-only (testable via chat + curl). Steps 10-15 are Swift UI.

---

## What We're NOT Doing (for now)

- **No event-driven tasks** — only cron and interval for now. Webhooks/Composio triggers later.
- **No plan-based throttling** — enforce limits later when billing exists
- **No retry logic** — if a task fails, it just saves the error and moves to next_run_at
- **No task dependencies** — each task is independent
- **No approval flow in scheduled tasks** — they just run and report results
- **No Composio integration yet** — scheduled tasks use the same `runChat()` as manual chat (web search, general questions). App-specific stuff (check Gmail) comes when Composio is connected.
