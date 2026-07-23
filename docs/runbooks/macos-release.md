# Runbook: macOS Release

**Scope:** Producing a signed, notarized, stapled Perch.app; publishing signed Sparkle updates and the website pointer to Vercel Blob; and verifying a clean-machine install.

---

## Prerequisites

- Apple Developer Program membership with a **Developer ID Application** certificate.
- App-specific password for the Apple ID used for notarytool.
- Vercel Blob token with `store:rw` scope for the release store.
- Access to the GitHub repository's **`Production`** protected environment (where secrets live).
- A Mac with Xcode 26+ for local testing; CI uses `macos-26`.

---

## Credential Setup (GitHub Secrets — `Production` environment)

| Secret | Description |
|--------|-------------|
| `DEVELOPER_ID_CERT_P12` | Base64-encoded `.p12` export of the Developer ID Application cert |
| `DEVELOPER_ID_CERT_PASSWORD` | Passphrase for the `.p12` archive |
| `APPLE_ID` | Apple ID email address |
| `APPLE_ID_PASSWORD` | App-specific password (not the main Apple ID password) |
| `APPLE_TEAM_ID` | 10-character Apple Developer Team ID |
| `VERCEL_BLOB_TOKEN` | Vercel Blob API token |
| `EXECUTOR_ARTIFACT_SIGNING_KEY_PEM_B64` | Base64 of the PEM P-256 private key matching the public key embedded in `ContainerRuntime.swift` |
| `SPARKLE_ED25519_PRIVATE_KEY` | Private key exported by Sparkle 2.9.4 `generate_keys -x`; pass it only through protected CI |

**Never commit these values. Never share them in Slack or chat. Rotate them immediately if you suspect exposure.**

Configure these non-secret variables in the same protected `Production` environment:

| Variable | Description |
|----------|-------------|
| `PERCH_API_BASE_URL` | Public production API origin using HTTPS |
| `PERCH_DEVICE_GATEWAY_URL` | Public production device gateway using WSS |
| `PERCH_SPARKLE_FEED_URL` | Exact stable public Blob URL ending in `/updates/appcast.xml` |
| `PERCH_SPARKLE_PUBLIC_KEY` | Base64 Ed25519 public key printed by Sparkle `generate_keys` |
| `PERCH_DOWNLOAD_MANIFEST_URL` | Exact stable public Blob URL ending in `/downloads/latest.json` |

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

1. Ensure CI is green on `main` (all jobs in `security-baseline.yml` and `ci.yml`). The release workflow independently checks both workflow conclusions for the tagged commit.
2. Tag the release:
   ```bash
   git tag v1.2.3
   git push origin v1.2.3
   ```
3. The `release-macos.yml` workflow triggers automatically on strict `vX.Y.Z` tags. A manual run checks out the tag supplied in the input rather than the branch used to launch the workflow.
4. Monitor the protected **Production** environment job. Confirm:
   - All credential checks pass.
   - Notarization returns `"status": "Accepted"`.
   - Stapling and `spctl --assess` pass.
   - The P-256 executor manifest verifies before and after the final build.
   - Sparkle's official 2.9.4 tools verify the archive and signed appcast.
   - The immutable archive digest, stable appcast, and stable website pointer are printed in the summary.

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
export PERCH_SPARKLE_FEED_URL="https://<store>.public.blob.vercel-storage.com/updates/appcast.xml"
export PERCH_SPARKLE_PUBLIC_KEY="<base64 Ed25519 public key>"
export EXECUTOR_ARTIFACT_SIGNING_KEY_PEM="/protected/path/executor-p256.pem"

cd app
./build.sh
# Outputs Perch-<version>.zip and Perch-<version>.sha256
```

Do not use the old raw `curl https://blob.vercel-storage.com/...` upload shape. Current Vercel Blob publication is performed by the pinned `@vercel/blob` SDK in `app/release-tools`: immutable archives use `addRandomSuffix: false` and no overwrite; stable appcast/pointer writes use `allowOverwrite: true` and the minimum 60-second cache duration. The protected CI workflow is the supported publication path.

---

## Stable Appcast and Website Pointer

The workflow publishes in this order:

1. Digest-addressed archive and checksum (never overwritten, one-year cache).
2. Signed `updates/appcast.xml` (atomic overwrite, 60-second cache).
3. `downloads/latest.json` website pointer (atomic overwrite, 60-second cache).
4. A fresh download of all three endpoints, including digest and version checks.

Configure the site once with `VITE_DOWNLOAD_MANIFEST_URL` equal to
`PERCH_DOWNLOAD_MANIFEST_URL`. The CTA validates and reads the stable manifest
at runtime, so later releases update the public download without rebuilding the
site. `VITE_DOWNLOAD_URL` remains an optional immutable fallback.

**Rollback:** Regenerate a signed appcast and `latest.json` that point to a compatible prior notarized digest-addressed artifact, then atomically overwrite the stable objects. Never overwrite the prior archive. Protocol-incompatible versions must not be selected.

## Bootstrap of External Signing Material

There are deliberately no sample or generated production keys in the repository.

1. With Sparkle 2.9.4, run `bin/generate_keys -x <protected-private-key-file>`.
2. Put the printed public key in `PERCH_SPARKLE_PUBLIC_KEY` and the exported private value in the protected `SPARKLE_ED25519_PRIVATE_KEY` secret.
3. Create the Blob store, determine the stable public URLs for `updates/appcast.xml` and `downloads/latest.json`, and configure the exact URLs in the `Production` environment.
4. Provision the existing executor P-256 private key matching `ExecutorArtifactManifestVerifier.releasePublicKeyPEM` as base64 PEM in `EXECUTOR_ARTIFACT_SIGNING_KEY_PEM_B64`.

The workflow derives the Ed25519 public key from Sparkle's current 32-byte seed format (and supports Sparkle's legacy 96-byte exported format), then requires an exact match with `PERCH_SPARKLE_PUBLIC_KEY`. It also requires `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` in the built app, checks Sparkle's embedded `sparkle-signatures` block locally and after publication, and runs `sign_update --verify` against both copies.

The workflow fails closed if any value is absent, malformed, points to an example/insecure origin, does not match the embedded public key, or does not resolve to the configured stable Blob URL. Blob publication additionally rejects a returned URL whose public store hostname or pathname differs from the requested no-random-suffix pathname.

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
