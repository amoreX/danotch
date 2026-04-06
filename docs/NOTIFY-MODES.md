# Notification Modes for Scheduled Tasks

## The Problem

Right now every scheduled task run creates a notification and (eventually) peeks. But most runs are background work — "write me a poem every 2min" doesn't need to interrupt the user. Only **conditional** tasks need to peek — "tell me when AAPL hits $200".

## The Solution: One New Field

Add `notify_user` to the scheduled task. Two modes:

| `notify_user` | Behavior | Example |
|---|---|---|
| `false` (default) | **Silent.** Runs in background, saves result to DB, no notification, no peek. User can check results by expanding the task on HOME. | "Write me a love poem every 2min" |
| `true` | **Conditional notify.** Runs in background, but Claude decides whether to notify. If yes → notification created + peek animation on notch. | "Notify me when AAPL drops below $200" |

## How Conditional Notify Works

When `notify_user = true`, the scheduler modifies the prompt to include a decision instruction:

```
Original prompt: "Check if AAPL stock is below $200"

Modified prompt sent to Claude:
"Check if AAPL stock is below $200

IMPORTANT: After checking, you must decide whether to notify the user.
- If the condition IS met, start your response with [NOTIFY] and explain what happened.
- If the condition is NOT met, start your response with [SKIP] and briefly note the current state.
Only use [NOTIFY] when the user actually needs to know."
```

The scheduler then checks the response:
- Starts with `[NOTIFY]` → create notification + push peek to notch
- Starts with `[SKIP]` → save result silently, no notification, no peek

This is dead simple — no new AI calls, no extra logic. Claude already understands conditional instructions. The `[NOTIFY]`/`[SKIP]` prefix is stripped before saving.

## Changes Required

### Backend

**1. DB: Add column to `scheduled_tasks`**

Run in Supabase SQL Editor:
```sql
ALTER TABLE scheduled_tasks ADD COLUMN notify_user BOOLEAN DEFAULT FALSE;
```

All existing tasks default to `false` (silent).

**2. Tool definition (`src/tools/scheduled.ts`)**
Add one param to `create_scheduled_task`:
```
notify_user: {
  type: "boolean",
  description: "If true, Claude will decide whether to notify the user based on the result. 
    Use for conditional alerts (stock price, weather threshold, etc.). 
    If false (default), runs silently in background."
}
```

Claude will set this to `true` when the user says things like "notify me when...", "alert me if...", "let me know when...".

**3. Scheduler (`src/scheduler/index.ts`)**
In `executeTask()`:
- If `notify_user = false` → save result to `last_result`, do NOT create notification, do NOT push WebSocket
- If `notify_user = true` → wrap prompt with the `[NOTIFY]/[SKIP]` instruction, check response prefix:
  - `[NOTIFY]` → strip prefix, save result, create notification, push peek event via WebSocket
  - `[SKIP]` → strip prefix, save result silently

**4. WebSocket: New peek event type**
```json
{
  "type": "peek_notification",
  "data": {
    "id": "notif-uuid",
    "title": "AAPL Alert",
    "body": "AAPL just dropped to $198.50 — below your $200 threshold.",
    "source_id": "task-uuid"
  }
}
```

### Swift App

**5. Handle `peek_notification` WebSocket event**
In `processEvent()`:
- On receiving `peek_notification`:
  - Expand the notch briefly (2-3 seconds)
  - Show a compact peek bar at the bottom of the notch with: red dot + title + body preview
  - Auto-collapse after 3s unless user hovers
  - Add to notifications list as unread

**6. ScheduledTaskRow: Show mode indicator**
- Silent tasks: no extra indicator (current behavior)
- Notify tasks: small bell icon next to the schedule text

That's it. No new tables, no new endpoints, no complex logic. One boolean field + a prompt wrapper + a prefix check.

## Implementation Order

```
1. ALTER TABLE (add notify_user column)
2. Update tool definition (add notify_user param)
3. Update scheduler executeTask() (silent vs conditional logic)
4. Add peek WebSocket event type
5. Handle peek in Swift (expand notch + peek bar)
6. Show bell icon on notify tasks in ScheduledTaskRow
```

Steps 1-4 are backend only. Steps 5-6 are Swift only.
