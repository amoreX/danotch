# Source installation

Perch supports macOS 26 or newer on Apple Silicon. Install from a reviewed Git
clone so the source can be inspected before execution:

```bash
git clone https://github.com/unordinarytech/perch.git
cd perch
./install.sh
```

The installer builds the exact clean commit currently checked out. It refuses
local modifications or untracked files. Do not use `curl | bash`: cloning first
keeps the installed source inspectable. The installer downloads only the exact
Node 24 arm64 archive recorded in `release/node-runtime.env` and accepts it only
when its SHA-256 matches `release/node-runtime.sha256`. Node is embedded in
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

Updates continue to use verified stable release tags when one is available.
