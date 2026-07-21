# Runbook: Security Rollback

**Scope:** Rolling back a deployed version due to a security incident, failed migration, compromised credential, or a release that must be pulled. Covers both backend and macOS app rollbacks, with explicit constraints on what must NOT be restored.

---

## General Principles

1. **Rollback must not restore insecure capabilities.** Specifically, rolling back can never restore:
   - Hosted shell/child-process execution (`bash_execute` removed in U1).
   - The unauthenticated localhost bridge on port 7778.
   - Plaintext credential storage (`~/.danotch/auth.json`).
   - Broad service-role DB access for public request paths.
   - Ad-hoc or unnotarized macOS artifacts for public distribution.
   - Fail-open action policies or cross-user task visibility.

2. **Content-addressed artifacts enable safe rollback.** Every Vercel Blob artifact has an immutable URL. Rollback repoints the stable manifest to a prior URL — it never overwrites bytes.

3. **Database rollback is forward-only.** Schema migrations are not reversed; only the application layer rolls back.

---

## Backend Rollback

### Decision: can the prior release safely run on the current schema?

- **Expand migrations** (new tables/columns): the prior release ignores them — safe to deploy.
- **Contract migrations** (removed tables/columns): the prior release may error — do not roll back past the release that introduced the contract.

### Steps

1. Identify the target release SHA or image tag (from CI artifacts or the deployment history).
2. Deploy the prior image to the backend service (Render, or your deployment platform).
3. Monitor `/health` for `"db": "ok"` and `"migrations": "verified"`. If either fails, stop and investigate.
4. Watch for RLS-rejection errors in the first 5 minutes of traffic. If present, the schema and code versions are incompatible — escalate.
5. Once stable, revoke any temporary credentials issued during the incident window (see Credential Rotation in `database-rollout.md`).

---

## macOS App Rollback

### Prior artifact is already available (content-addressed on Vercel Blob)

1. Find the prior release's immutable Vercel Blob URL in the CI workflow summary or the Vercel Blob console.
2. Update `VITE_DOWNLOAD_URL` to the prior URL in the Vercel deployment environment.
3. Redeploy the site (no code change; env var update triggers a deploy).
4. Verify the download CTA links to the prior artifact.

### If the prior artifact cannot be used (security floor)

If the prior release violates a security floor (e.g., it contains hosted shell execution or the unauthenticated bridge), it **must not** be re-published. Instead:

1. Set `VITE_DOWNLOAD_URL` to empty / unset, which renders the coming-soon state on the site.
2. Communicate the rollback timeline to users.
3. Produce a patch release that reverts only the specific regression while retaining all hardening from U1–U8.
4. Go through the full release gate: sign, notarize, attest, verify clean-machine install, publish to Blob, update manifest.

---

## Device Protocol Rollback

If the device gateway is rolled back:

1. Existing enrolled device keys remain valid — they live in Keychain.
2. New ticket issuance is unavailable until the gateway is re-deployed.
3. Do not re-enable the localhost bridge. Devices in a disconnected state are expected; they will reconnect when the gateway is restored.
4. Revoke device tickets issued during the incident window if there is any suspicion of ticket compromise.

---

## Credential Compromise Response

| Credential | Immediate action |
|-----------|-----------------|
| Supabase service key | Rotate in Supabase dashboard; update `SUPABASE_SERVICE_KEY` secret; redeploy |
| ANTHROPIC_API_KEY | Revoke in Anthropic console; rotate |
| DEVELOPER_ID_CERT | Revoke in Apple Developer portal; re-sign+notarize latest artifact; re-publish (see macos-release.md) |
| VERCEL_BLOB_TOKEN | Revoke in Vercel dashboard; update secret; re-run release job |
| PROVIDER_KEY_SECRET | Rotate; all stored BYOK keys are re-encrypted on next use if the app supports key migration; otherwise prompt users to re-enter |
| COMPOSIO_API_KEY | Revoke; rotate; existing connections remain valid (they are OAuth-based) |

All rotations must be followed by a forced redeploy of the backend to pick up the new secrets.

---

## Incident Documentation

For any security incident requiring a rollback, record:

- Date/time of discovery and rollback.
- Root cause (brief).
- Versions affected.
- Credentials rotated.
- Evidence preserved (logs, artifacts, attestation records).
- Post-incident action items and owner.

Keep this record in a private incident log, not in this repository.
