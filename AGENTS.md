# AGENTS.md

Guidance for coding agents working in this repository.

## Product contract

Perch is a free, local-first, open-source macOS 26+ application.

- Do not add accounts, hosted Perch services, billing, trials, entitlements, or
  feature gates.
- Donations are optional and unlock nothing.
- Preserve existing local conversation and display settings; do not import
  hosted-account data.
- Provider and Composio credentials belong only in macOS Keychain.
- The daemon must bind only to authenticated loopback IPC.
- Local mutation and execution must remain explicit, approval-gated, bounded,
  and auditable.
- Installation builds the current clean Git checkout; stable updates still
  require verified signed tags.

## Repository

```text
app/       SwiftUI app, native daemon host, and executor
backend/   TypeScript local daemon and SQLite persistence
site/      React/Vite public website
docs/      source installation and release operations
release/   pinned runtime and maintainer trust metadata
scripts/   update/uninstall commands, verification, and shared shell logic
```

## Build and test

Use Node 24 for `backend/`.

```bash
# Build and start the app, authenticated daemon, and website together
npm run dev
# `npm start` is an alias; Control-C stops all three processes.
```

```bash
cd backend
npm ci
npm run build
npm test
npm run test:db
npm run test:runtime-policy
npm audit --audit-level=low
```

```bash
cd app
swift build
swift test
./build.sh
```

`swift test` requires the XCTest module supplied by a selected full Xcode
installation. Do not weaken tests when only Command Line Tools are selected.

```bash
cd site
npm ci
npm run lint
npm run build
npm audit --audit-level=low
```

Distribution checks:

```bash
bash -n install.sh scripts/update.sh scripts/uninstall.sh scripts/lib/perch-common.sh
python3 app/scripts/verify_release_static.py
plutil -lint app/Resources/engineering.super.Perch.daemon.plist.template
shellcheck install.sh scripts/update.sh scripts/uninstall.sh scripts/lib/perch-common.sh
```

The installer must fail for a dirty or invalid Git checkout, wrong runtime
checksum, symlinked destination, or failed health check. The updater must also
fail for a lightweight tag, unsigned tag, or unknown signer.

## Local architecture

`Perch.app` communicates with the local daemon through a dynamically selected
`127.0.0.1` port. The mode-`0600` discovery file is non-secret. The app
exchanges the installation secret for a short-lived session token through the
native `PerchDaemonHost`; HTTP and WebSocket requests enforce protocol version,
Host, Origin, size, and rate limits.

The native host:

- owns Keychain access;
- launches the pinned bundled Node runtime;
- never places production credentials in arguments or environment variables;
- brokers only the documented framed credential protocol.

Debug development stacks use one ephemeral installation secret shared with the
app and host through their environment so rebuilding an ad-hoc-signed app does
not trigger repeated Keychain ACL prompts. Release builds always read the
installation secret from Keychain.

SQLite stores local, non-secret durable state. Migrations are ordered,
checksummed, transactional, and forward-only. Keep foreign keys, WAL, busy
timeout, restrictive file modes, one-use grants, and idempotent terminal action
results intact.

The app may call only services the user configures:

- Anthropic
- OpenAI
- OpenRouter
- DeepSeek
- custom public HTTPS OpenAI-compatible endpoints
- optional Composio integrations

Each scheduled task pins provider/model/endpoint settings. Never silently fall
back to another provider or a project-owned key.

## Execution safety

Do not execute model-generated commands inside the Node daemon. The daemon may
offer a typed action; the app verifies immutable bindings and obtains explicit
consent; the sandboxed executor consumes a one-use grant.

Maintain:

- exact installation UUID, key fingerprint, and verified workload digest;
- security-scoped workspace bookmarks;
- strict typed action validation;
- no executor network capability;
- bounded input, output, time, memory, and CPU;
- strict nested-code signature and sealed-manifest verification;
- minimal rejection payloads;
- restart-persistent, idempotent terminal results.

When using Swift `Process` with `Pipe`, read pipe data before
`waitUntilExit()` to avoid a full pipe-buffer deadlock.

## Secrets and logging

Never store or emit raw credentials, installation secrets, session tokens,
message bodies, prompts, tool output, or private URLs in SQLite, files, logs,
crash metadata, discovery files, process arguments, or CI output.

Secret-setting APIs accept write-only values. Read APIs return only configured
state and non-secret metadata. Reject unexpected secret-shaped fields in normal
API payloads.

## Distribution

Root `install.sh` and `scripts/update.sh` / `scripts/uninstall.sh` are
user-level, idempotent, and source-first. Updates stage a verified signed tag,
back up SQLite, atomically activate runtime files, and roll back app, daemon,
LaunchAgent, and database on failure. Do not add `curl | bash`, Sparkle,
auto-downloaded app archives, root installation, or silent prerequisite
installation.

The in-app update action launches only the fixed installed command
`~/.local/bin/perch update`, without a shell or user-controlled arguments.

## UI

Keep provider, custom endpoint, Composio, model, scheduled-task model, and
connection controls in Settings. Secret fields must clear after submission and
must never be repopulated from storage. Errors should be actionable without
revealing sensitive values.

Current app behavior:

- onboarding asks for a local display name and one user-owned provider key;
- supported providers are Anthropic, OpenAI, OpenRouter, DeepSeek, and custom
  public HTTPS OpenAI-compatible endpoints;
- the composer shows a compact sparkles model menu with a visible check beside
  the selected model;
- Today widgets support persistent ordering and sizing, handle-only dragging,
  safe mouse-up recovery, and a Reset layout action;
- Command-Shift-Space opens the global quick prompt;
- settings and local conversations persist across app restarts;
- Settings can switch the active provider and return to local onboarding.

## Pull requests

Do not commit unless asked. Keep changes focused and report:

1. user-visible behavior;
2. trust-boundary, privacy, schema, and protocol impact;
3. verification performed and any environment blockers;
4. rollback behavior for storage or distribution changes.
