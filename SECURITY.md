# Security Policy

## Report privately

Do not open a public issue for a suspected vulnerability. Email
**security@perch.app** with the affected signed tag, macOS version, impact, and
the minimum safe reproduction. Do not include real credentials or another
person's data. Encrypt especially sensitive evidence with a maintainer key from
[docs/maintainer-keys.md](docs/maintainer-keys.md) once one is published.

We target acknowledgement within two business days, an initial assessment
within five, and a critical fix within fourteen. Please coordinate disclosure
until a fix or mitigation is available. If the reporting address fails, open a
public issue containing no vulnerability detail and ask for a private channel.

## Supported releases

Only the newest stable `vX.Y.Z` release tag is supported. A release is eligible
for installation only when it is annotated, has a valid signature, and its
signer is in the repository's reviewed fingerprint allowlist. Branch builds,
lightweight tags, unsigned archives, and ad-hoc binaries from another machine
are unsupported.

## Local-first trust model

Perch's distribution contract is source-first:

- Users inspect a clone and run `./install.sh`; the project does not promote
  `curl | bash`.
- The installer accepts only macOS 26+ on Apple Silicon and embeds a
  checksum-pinned Node 24 arm64 runtime. It never relies on Homebrew Node at
  runtime.
- The daemon is a non-root per-user LaunchAgent and binds only to `127.0.0.1`.
  Its mode-`0600` discovery file is private to the user; capabilities require
  the authenticated local session protocol.
- Provider and installation secrets belong in macOS Keychain. SQLite stores
  non-secret local state under `~/Library/Application Support/Perch`.
- Updates build a verified tag in staging, back up SQLite, atomically replace
  runtime files, and restore both runtime and database backup when startup or
  migration health checks fail.
- Uninstall preserves data and Keychain entries unless the user explicitly
  requests and confirms `--purge`.
- User-approved code execution must remain inside the documented Apple
  Containerization boundary with scoped workspace access and bounded resources.

The installer builds only a clean Git checkout and refuses incomplete daemon,
native-host, or LaunchAgent resources. Stable updates remain fail-closed until
a maintainer fingerprint allowlist is published.

## Threats in scope

- forged or rollback release tags, compromised dependency downloads, and
  updater time-of-check/time-of-use errors;
- another local process or malicious website invoking daemon capabilities;
- symlink, path, permission, or LaunchAgent injection in install/update flows;
- SQLite corruption, unsafe migration, lost rollback data, or secret leakage
  into SQLite, logs, process arguments, crash reports, or CI output;
- sandbox/container escape, consent bypass, workspace overreach, or unexpected
  network access;
- malicious prompt or tool output that causes an action beyond explicit user
  authorization.

Reports about an upstream service are useful when Perch's integration worsens
the impact. Pure upstream outages, social engineering without a Perch flaw, and
unsupported modified builds are generally out of scope.

## Response and history

Maintainers preserve relevant logs and hashes privately, rotate exposed
credentials, publish a signed fixed tag, and document user action without
revealing exploit details prematurely. Security floors are forward-only:
rollback must not restore unauthenticated IPC, plaintext secrets, hosted shell
execution, or an incompatible schema. Historical hosted-distribution controls
are retained under `docs/archive/` for audit context.
