# Runbook: signed source release

The active macOS release is a signed source tag, not a hosted binary. Follow
`docs/release-policy.md`.

1. Verify required CI on the exact main-branch commit.
2. Confirm the pinned Node manifest against Node's signed `SHASUMS256.txt`.
3. Confirm local daemon and app compatibility resources are present.
4. Create and push an annotated signed `vX.Y.Z` tag.
5. Verify the SBOM workflow and clean-machine source install.
6. Exercise update from the previous stable version and automatic rollback with
   a deliberately failing readiness probe.

Do not publish Vercel Blob app archives or Sparkle feeds. The retired procedure
and its security controls are preserved in `docs/archive/hosted-distribution.md`.
