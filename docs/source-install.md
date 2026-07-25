# Source installation

Perch supports macOS 26 or newer on Apple Silicon. Install from a reviewed Git
clone so tag signatures and source can be inspected before execution:

```bash
git clone https://github.com/unordinarytech/perch.git
cd perch
git checkout vX.Y.Z
git verify-tag vX.Y.Z
./install.sh
```

Do not use `curl | bash`. The installer downloads only the exact Node 24 arm64
archive recorded in `release/node-runtime.env` and accepts it only when its
SHA-256 matches `release/node-runtime.sha256`. Node is embedded in
`~/Applications/Perch.app`; Homebrew Node is never a runtime dependency.

The installer is idempotent and preserves data. It stages builds, backs up an
existing SQLite database, installs the app, source tools, and
`engineering.super.Perch.daemon` user LaunchAgent, then requires an
authenticated local health check before completing.

```bash
perch status
perch doctor
perch update
perch uninstall
```

`perch uninstall` preserves local data and Keychain credentials. Permanent
deletion requires `perch uninstall --purge` and typing `DELETE PERCH`.

## Current release blocker

Installation intentionally stops with a precise error until all of these
reviewed release inputs exist:

- at least one real maintainer fingerprint and exported public key.

The local daemon, native Keychain broker, app discovery/session protocol, and
LaunchAgent template are present. The installer still fails closed until the
release trust root is published.
