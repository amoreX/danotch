# Runbook: local security rollback

Rollback must not restore unauthenticated IPC, hosted shell execution,
plaintext credentials, broad service-role access, fail-open actions, or a
schema-incompatible runtime.

## Failed install or update

The installer owns rollback once activation starts:

1. stop the new per-user LaunchAgent;
2. restore the previous `Perch.app` and installed source by same-volume rename;
3. remove SQLite WAL/SHM files and restore the consistent pre-update backup;
4. restore the prior LaunchAgent and bootstrap it;
5. leave backup evidence under the Perch application-support directory.

Do not delete the backup until the prior runtime is healthy and the user has
validated data.

## Published bad tag

Never move, delete-and-recreate, or force-update the tag. Fix forward on main
and publish a signed patch tag. If exploitation risk is immediate, document
that the affected tag is revoked and tell users to stop the daemon until the
patch is available. Automatic downgrade is prohibited unless a maintainer has
proved schema compatibility and paired it with the correct database backup.

## Key or runtime compromise

- Remove a compromised fingerprint through the key-rotation procedure in
  `docs/maintainer-keys.md`, publish revocation, and sign the recovery release
  with an independently verified key.
- Replace a compromised Node archive version and digest together after
  verifying Node's signed checksum publication.
- Rotate exposed provider or installation credentials and inspect logs and CI
  artifacts for secret material.

Record timeline, affected tags, hashes, credentials rotated, user actions, and
follow-up owners in the private incident log. Historical hosted rollback
controls remain in `docs/archive/hosted-distribution.md`.
