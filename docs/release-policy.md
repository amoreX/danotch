# Release policy

## Stable releases

Stable versions use semantic `vMAJOR.MINOR.PATCH` tags. Every stable tag must:

- be an annotated tag on the protected main branch;
- be signed by a reviewed key in `release/maintainer-gpg-fingerprints.txt`;
- pass daemon, app, site, installer, security, and SBOM workflows;
- pin the embedded Node 24 Apple Silicon archive by exact version and SHA-256;
- document schema/protocol compatibility and rollback behavior.

The project distributes reviewed source, not prebuilt app archives. Users clone
the canonical HTTPS repository and run `./install.sh` from a clean checkout.
GitHub source archives are not an installation input because they do not retain
the inspectable Git commit metadata required by the installer.

## Promotion procedure

1. Merge through protected review with all required CI green.
2. Confirm the maintainer allowlist and exported public keys are current.
3. Update the runtime manifest only from Node's signed checksum publication.
4. Create an annotated signed tag: `git tag -s vX.Y.Z -m "Perch vX.Y.Z"`.
5. Push the tag without force and verify the tag workflow and generated SBOM.
6. On a clean Apple Silicon Mac, clone the tag, run the installer, verify
   `perch doctor`, update from the previous release, then uninstall both with
   and without purge.

Release tags are immutable. A bad release receives a new patch tag; maintainers
never move or replace a published tag.

## Update and rollback contract

`perch update` fetches the canonical repository over HTTPS, selects the newest
stable tag, checks its annotated signature against the currently trusted
allowlist, builds in staging, makes a consistent SQLite backup, and atomically
swaps the app and daemon. Failure of daemon bootstrap, authenticated health, or
migration readiness restores the old runtime and matching database backup.

Downgrades are refused automatically because an older runtime may not understand
the current schema. Security rollback is forward-fix only when an older release
falls below a security floor.

## Key and dependency incidents

Compromised signing keys follow `docs/maintainer-keys.md`. Dependency changes
remain lockfile-pinned and pass audit gates. SBOM artifacts are generated for
every stable tag and retained with CI provenance. No release secret may appear
in repository files, workflow logs, process arguments, or artifacts.
