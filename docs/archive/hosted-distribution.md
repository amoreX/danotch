# Archived hosted-distribution runbooks

Archived: 2026-07-25. These controls are retained for security history and are
not the current Perch distribution procedure.

## Former macOS binary release

The previous workflow built an arm64 `Perch.app`, signed nested helpers and the
app with Developer ID plus Hardened Runtime, notarized and stapled it, verified
Gatekeeper, signed Sparkle artifacts with Ed25519, and published
digest-addressed archives, checksums, `appcast.xml`, and `latest.json` to Vercel
Blob. Protected CI held Developer ID, Apple notarization, executor-manifest,
Sparkle, and Blob credentials. Releases required successful main CI,
monotonically increasing build numbers, architecture/entitlement inspection,
secret scanning, provenance attestation, and clean-machine verification.

The rollback process repointed stable Blob objects to an immutable prior
notarized artifact, never overwrote archive bytes, and refused releases below
security floors. Certificate compromise required immediate Apple revocation,
credential rotation, re-signing, re-notarization, and a patch release.

## Former hosted-service rollback

Backend rollback was application-only and forward-schema-aware: expand
migrations could tolerate an older app, while contract migrations prohibited
rollback. Operators monitored health and RLS isolation and rotated credentials
after incidents. Device rollback never re-enabled the unauthenticated localhost
bridge. Hosted shell execution, plaintext credentials, broad public
service-role access, fail-open action policy, and unnotarized public artifacts
were permanent security floors.

Incident records included discovery and rollback times, affected versions,
rotated credentials, evidence hashes, and follow-up owners, stored privately.

## Why archived

Perch now defines source installation and signed-tag updates. Sparkle and Vercel
Blob publication are not part of that contract. Current procedures are in
`docs/source-install.md`, `docs/release-policy.md`, and
`docs/runbooks/security-rollback.md`.
