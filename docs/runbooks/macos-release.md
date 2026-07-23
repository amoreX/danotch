# Runbook: macOS Release

**Scope:** Producing a signed, notarized, stapled Perch.app; publishing to Vercel Blob; updating the stable download manifest; and verifying a clean-machine install.

---

## Prerequisites

- Apple Developer Program membership with a **Developer ID Application** certificate.
- App-specific password for the Apple ID used for notarytool.
- Vercel Blob token with `store:rw` scope for the release store.
- Access to the GitHub repository's **`release`** protected environment (where secrets live).
- A Mac with Xcode 26+ for local testing; CI uses `macos-26`.

---

## Credential Setup (GitHub Secrets — `release` environment)

| Secret | Description |
|--------|-------------|
| `DEVELOPER_ID_CERT_P12` | Base64-encoded `.p12` export of the Developer ID Application cert |
| `DEVELOPER_ID_CERT_PASSWORD` | Passphrase for the `.p12` archive |
| `APPLE_ID` | Apple ID email address |
| `APPLE_ID_PASSWORD` | App-specific password (not the main Apple ID password) |
| `APPLE_TEAM_ID` | 10-character Apple Developer Team ID |
| `VERCEL_BLOB_TOKEN` | Vercel Blob API token |

**Never commit these values. Never share them in Slack or chat. Rotate them immediately if you suspect exposure.**

Configure these non-secret variables in the same protected `release` environment:

| Variable | Description |
|----------|-------------|
| `PERCH_API_BASE_URL` | Public production API origin using HTTPS |
| `PERCH_DEVICE_GATEWAY_URL` | Public production device gateway using WSS |

The release workflow rejects missing, insecure, or reserved example-domain values.

Exporting the cert:
```bash
# On a Mac with the cert in Keychain:
security find-identity -v -p codesigning | grep "Developer ID Application"
# Note the SHA-1 hash and export from Keychain Access > My Certificates > Export
# or via:
security export -k login.keychain-db -t identities -f pkcs12 \
  -P "your-password" -o ~/Desktop/DeveloperID.p12
base64 < ~/Desktop/DeveloperID.p12 | pbcopy   # copy to DEVELOPER_ID_CERT_P12 secret
```

---

## Release via CI (recommended)

1. Ensure CI is green on `main` (all jobs in `security-baseline.yml` and `ci.yml`).
2. Tag the release:
   ```bash
   git tag v1.2.3
   git push origin v1.2.3
   ```
3. The `release-macos.yml` workflow triggers automatically on `v*.*.*` tags.
4. Monitor the **release** environment job. Confirm:
   - All credential checks pass.
   - Notarization returns `"status": "Accepted"`.
   - Stapling and `spctl --assess` pass.
   - The artifact URL and checksum are printed in the workflow summary.
5. Update the stable manifest (see below).

---

## Release via CLI (operator fallback)

Use `app/build.sh` directly only when CI is not available. This should be rare.

```bash
# Import cert into Keychain first (see Credential Setup above)
security import DeveloperID.p12 -P "$CERT_PASSWORD" -T /usr/bin/codesign

export DEVELOPER_ID_CERT="Developer ID Application: Your Name (TEAMID)"
export NOTARIZE=1
export APPLE_ID="you@example.com"
export APPLE_ID_PASSWORD="xxxx-xxxx-xxxx-xxxx"
export APPLE_TEAM_ID="ABCDE12345"
export PERCH_API_BASE_URL="https://your-production-api-host"
export PERCH_DEVICE_GATEWAY_URL="wss://your-production-api-host/api/device-gateway"

cd app
./build.sh
# Outputs Perch-<version>.zip and Perch-<version>.sha256
```

Upload the resulting `.zip` to Vercel Blob manually:
```bash
curl -X PUT "https://blob.vercel-storage.com/releases/v1.2.3/Perch-v1.2.3-signed.zip" \
  -H "Authorization: Bearer $VERCEL_BLOB_TOKEN" \
  -H "x-content-type: application/octet-stream" \
  -H "x-cache-control-max-age: 31536000" \
  --data-binary @Perch-v1.2.3.zip
```

---

## Updating the Stable Manifest

The site's download CTA reads `VITE_DOWNLOAD_URL` at build time. To promote an artifact:

1. Obtain the immutable Vercel Blob URL from the CI summary or manual upload.
2. Set `VITE_DOWNLOAD_URL=<immutable-blob-url>` in the Vercel deployment environment.
3. Trigger a new site deployment (no code change needed — the env var update redeploys).
4. Verify the download CTA now shows the new artifact URL.

**Rollback:** Point `VITE_DOWNLOAD_URL` at the prior notarized artifact's immutable Blob URL and redeploy the site. The prior artifact was never overwritten (content-addressed).

---

## Clean-Machine Install Verification

Before promoting any release, verify on a clean Mac (or a freshly created VM):

1. Download the artifact from the public site URL.
2. Verify the SHA-256:
   ```bash
   shasum -a 256 Perch-v1.2.3-signed.zip
   # compare to the published .sha256 file
   ```
3. Expand the archive and verify Gatekeeper:
   ```bash
   spctl --assess --type execute -vv Perch.app
   # Expected: Perch.app: accepted  source=Notarized Developer ID
   ```
4. Open Perch.app. Confirm:
   - No "damaged or unverified" Gatekeeper dialog.
   - Onboarding / login opens successfully.
   - (Post-U9) Device enrollment completes and the WSS connection is established.

---

## Certificate Compromise Response

If the Developer ID certificate is compromised:

1. **Immediately** revoke the certificate in the Apple Developer portal.
2. Generate a new Developer ID Application certificate and update all secrets.
3. Re-sign and re-notarize the latest release artifact.
4. Publish the new artifact with a patch version bump.
5. Update `VITE_DOWNLOAD_URL` to point at the re-notarized artifact.
6. Document the incident and the revocation date in the change log.

Revoked certificates cause Gatekeeper to reject old artifacts on future OS updates, so timely re-release is important.
