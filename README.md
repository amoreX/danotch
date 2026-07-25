# Perch

Perch is a free, open-source macOS notch assistant for developers. It monitors
local coding agents, provides system utilities, runs AI conversations and
scheduled tasks, and can connect user-owned third-party accounts.

Perch has no account, subscription, checkout, trial, hosted control plane, or
project-owned AI key. Every feature is available locally. Donations are
optional and unlock nothing.

## Requirements

- Apple Silicon Mac running macOS 26 or newer
- Xcode 26 or newer, including command-line tools
- XcodeGen
- Git with GPG signature verification

The installer downloads the exact checksum-pinned Node 24 arm64 runtime. Node
does not need to be installed globally.

## Install

Install only from an annotated, signed stable release tag:

```bash
git clone https://github.com/unordinarytech/perch.git
cd perch
git checkout vX.Y.Z
./install.sh
```

The installer verifies the release signer against the reviewed allowlist,
builds from source, ad-hoc signs the local bundle, installs
`~/Applications/Perch.app`, and starts a per-user LaunchAgent. It does not
require root and does not delete existing data or credentials.

Until maintainer fingerprints are published in
`release/maintainer-gpg-fingerprints.txt`, installation intentionally fails
closed. See [the source-install guide](docs/source-install.md).

After installation:

```bash
perch update
perch uninstall
perch uninstall --purge
```

`--purge` permanently removes local data and Keychain entries after explicit
confirmation. Normal uninstall preserves them.

## Configure

Open Perch Settings to configure:

- Anthropic
- OpenAI
- OpenRouter
- DeepSeek
- a custom public HTTPS OpenAI-compatible endpoint
- optional Composio API and auth-configuration IDs for Gmail, Google Calendar,
  Google Docs, and GitHub

Provider and Composio keys are sent directly to the native daemon host and
stored in macOS Keychain. They are not stored in SQLite, app settings, logs,
URLs, or process arguments. Conversations can select a configured model, and
each scheduled task pins its own provider, model, and optional custom endpoint.

First-run onboarding asks for a local display name and one provider key, then
selects that provider's recommended model. Provider and model changes remain
available in Settings. **Command-Shift-Space** opens or closes the quick prompt
globally. Local logout returns to onboarding while preserving saved providers,
conversations, and settings on the Mac.

Perch continues to use existing on-Mac conversation and display settings. It
does not import hosted account data.

## Architecture

```text
Perch.app (SwiftUI)
  │ authenticated loopback HTTP/WebSocket
  ▼
PerchDaemonHost (Swift, Keychain broker)
  │ launches bundled, pinned Node 24
  ▼
local TypeScript daemon ── SQLite
  │
  ├─ user-selected LLM provider
  ├─ optional Composio
  └─ approval-gated PerchExecutor
```

- The daemon is a non-root per-user LaunchAgent.
- It binds only to dynamic `127.0.0.1`; there is no inbound internet listener.
- Discovery is mode `0600` and contains no secret.
- Local sessions require Host, Origin, and short-lived token validation.
- Durable actions use immutable approval bindings and one-use grants.
- Mutating integration tools require explicit approval.
- Scheduled runs expose safe provider and integration tools, never arbitrary
  Node process execution.

See [SECURITY.md](SECURITY.md) for the trust model.

## Development

With Xcode Command Line Tools providing Swift 6.2, run the complete local stack
from the repository root:

```bash
npm run dev
```

This builds the real app and daemon bundle, starts the native Keychain-backed
daemon host, opens Perch, and serves the website at
`http://127.0.0.1:5173`. Press Control-C to stop the daemon and website.
`npm start` is an alias for the same command. The launcher automatically
downloads and verifies the repository's pinned Node 24 runtime when the active
Node version is older; it does not replace the system Node installation.

To verify components independently, the backend requires Node 24:

```bash
cd backend
npm ci
npm run build
npm test
npm run test:db
npm run test:runtime-policy
```

Build the macOS components:

```bash
cd app
swift build
swift test
./build.sh
```

Build the website:

```bash
cd site
npm ci
npm run lint
npm run build
```

Full XCTest execution requires a selected full Xcode installation. Source
installation additionally requires a signed release tag; development branch
builds are intentionally not installable through `install.sh`.

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md),
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), and [SECURITY.md](SECURITY.md).

Licensed under the [Apache License 2.0](LICENSE).
