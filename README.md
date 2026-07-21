# Perch

Perch lives in your MacBook notch. Hover near it and it drops down into a little assistant — your time and date, what's playing, system stats, the AI sessions running in your terminal, and a chat box that can actually do things on your machine.

It started as a status viewer for delegated agent tasks. It's now closer to a place where everything ambient about your machine perches above the keyboard, one hover away, instead of buried in a tab you forgot to switch to.

## what's in here

```
app/       — the macOS app, Swift + SwiftUI (the notch overlay)
backend/   — Node + Express, Supabase, multi-provider LLM, Composio integrations
site/      — the landing page, React + Vite + Tailwind
AGENTS.md  — repo guidance for AI coding agents
```

Three separate things. In development the app connects to a local backend; in production the app authenticates and connects outbound over WSS to the hosted control plane. The site is just marketing.

## running it

### the app

```bash
cd app
swift run Perch
```

macOS 26+, Swift 6.2 toolchain. First launch shows onboarding — sign up, pick a model (Perch's default or your own key), optionally connect some apps, grant whatever local access you're comfortable with. After that it disappears into the notch. Hover to bring it back.

For a real `.app` bundle:

```bash
cd app
./build.sh        # builds release + bundles Perch.app (ad-hoc signed)
open Perch.app
```

It runs as an accessory — no dock icon, no menu bar clutter. Just the notch.

### the backend

Requires **Node 24 LTS** (`node --version` should print `v24.x.x`).

```bash
cd backend
npm install
npm run dev       # :3001
```

Copy `backend/.env.example` to `backend/.env` and fill in values. Minimum required: Supabase credentials, `ANTHROPIC_API_KEY` (trial fallback), `PROVIDER_KEY_SECRET` (AES key for BYOK encryption — must be at least 32 characters). `COMPOSIO_API_KEY` if you want app integrations.

For schema migrations, add `SUPABASE_DB_URL` with the Postgres connection string and run:

```bash
cd backend
npm run db:migrate
```

To verify the migration ledger matches the shipped SQL without making changes:

```bash
npm run db:verify
```

All config is env-overridable via `config.ts`. Production startup rejects HTTP origins, localhost endpoints, weak secrets, and missing required vars.

#### tests

```bash
npm test                      # unit + contract tests (no DB required)
npm run test:runtime-policy   # Node permission model verification
npm run test:db               # integration tests (requires SUPABASE_DB_URL)
```

### the site

```bash
cd site
npm install
npm run dev
```

The app and backend have unit and contract tests. The site does not.

## what it actually does

**watches your agents.** If you've got Claude Code running in a terminal, Perch sees it. Project name, the last thing you asked it, what tool it's reaching for right now — reading a file, running a command, searching, thinking. It reads the session JSONL to figure out live state, so the indicator on the row tells you whether it's working or waiting on you. Click a session and it brings that terminal to the front.

**is a chat box that does things.** Type into the notch and it hits the backend, which runs a real tool-use loop. It can run shell commands on your Mac, search the web, fetch a page. If you've connected Gmail, Calendar, Docs, or GitHub through Composio, it can use those too — and when it needs access it doesn't have, it asks, right there in the chat, with a connect/deny button. Conversations are stored locally by the app and sent back as recent context for follow-ups.

**runs things on a schedule.** Ask it to check something every morning, or poll for a condition and only ping you when it's true. Scheduled tasks live on the backend, tick every 30 seconds, and either save their output quietly or push a notification. The conditional ones ("tell me when X drops below Y") only fire when they mean it.

**peeks at you.** When a scheduled task has something worth saying, the notch grows a little and shows the headline without taking over your screen. Hover for the rest, ignore it and it goes away on its own.

**shows you your machine.** CPU and RAM on arc gauges, network up/down as little oscilloscope graphs, disk, uptime, process count. There's a sortable process table if you want to go kill something. And you can pin a few of these — plus a calendar strip and an Apple Music widget — to the home view so they're always there.

**brings your own key.** Use the model the server's configured with, or drop in your own Anthropic, OpenAI, or OpenRouter key. Keys are encrypted at rest. Saved providers can be switched on later without re-entering the key, and returning to the server default does not delete saved BYOK configs.

## the notch itself

- **collapsed** — just two wings around the notch: time on the left, a count on the right
- **hover** — the black pill drops down. tabs across the top: `HOME · AGENTS · STATS · 🔔 · ⚙`
- **home** — greeting, time, date, your pinned widgets, the chat bar
- **agents** — your Claude Code sessions and locally restored chat history
- **stats** — the bento grid of system metrics
- **notifications** — grouped by the task that produced them
- **settings** — chat behavior, display, agents, providers, app connections
- **⌘⇧Space** — drops the notch down anywhere and focuses the chat input
- **mouse leaves** — 400ms grace, then it collapses (it won't collapse on you mid-chat)
- **escape** — collapse now

## how the app and backend talk

**Production:** the app authenticates, enrolls a device key, and connects outbound to the hosted control plane over `wss://`. The backend issues HTTPS tickets; the app upgrades to WSS and the backend pushes durable run events.

**Development only:** the backend connects to a legacy `ws://localhost:7778/ws` bridge on the app. This path is never used in production builds.

```json
{ "type": "subagent_event", "session_id": "abc-123", "event_type": "status|progress|done", "data": { } }
```

| event_type | what it means | fields |
|------------|---------------|--------|
| `status`   | add or update a task | `task`, `description`, `status`, `tool_calls_count`, `title` |
| `progress` | tool lifecycle, tokens | `type` (`tool_start`/`tool_result`/`token`/`text_flush`), `tool_name`, `tool_input`, `text` |
| `done`     | task finished | `status`, `result`, `error` |

There's also `connection_request` (the backend asking for OAuth approval to an app), `notification`, and `peek_notification` (the soft expand). The app answers connection requests with `connection_response` back over the same socket.

## health endpoints

```
GET /health/live   — process-only liveness (always 200 while running)
GET /health/ready  — readiness (200 = all checks pass; 503 = a check failed)
GET /health        — legacy alias (kept for existing monitoring integrations)
```

The readiness check verifies: migration ledger count, database connectivity, device gateway attachment, and critical LLM provider configuration.

## under the hood

The app is MVVM SwiftUI. A `NotchViewModel` holds all the state and turns WebSocket events into model updates. Auth, settings, and conversations persist to JSON in your home directory (`~/.danotch`). Agent detection is a `ps` scan every few seconds plus reading Claude Code's own session files. System stats come straight from the Mach APIs.

The backend is TypeScript ESM. The agent runner is provider-agnostic — same tool-use loop whether you're on Anthropic, OpenAI, or OpenRouter — with a five-iteration cap and app-supplied local history for follow-ups. Supabase stores auth-owned data, scheduled tasks, notifications, connected apps, and encrypted BYOK provider configs. Composio handles the third-party OAuth. A scheduler loop picks up due tasks and runs them without tools.

## the look

Dark, Nothing-inspired. OLED-black surfaces, monospaced display type, an 8px grid, easeOut and nothing bouncy. Status maps to color — yellow when something's running, green when it's done, red when it wants your attention. All the tokens live in `Theme.swift` under `enum DN`. The landing page mirrors the same system in CSS so the demo notch looks like the real one.
