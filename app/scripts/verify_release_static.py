#!/usr/bin/env python3
"""Fail CI when direct-distribution release invariants drift."""

import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]


def require(path: str, snippets: list[str]) -> None:
    text = (ROOT / path).read_text()
    missing = [snippet for snippet in snippets if snippet not in text]
    if missing:
        raise SystemExit(f"{path} is missing release invariants: {missing}")


require("app/project.yml", [
    "exactVersion: 2.9.4",
    "product: Sparkle",
    "SUFeedURL: $(PERCH_SPARKLE_FEED_URL)",
    "SUPublicEDKey: $(PERCH_SPARKLE_PUBLIC_KEY)",
    "SURequireSignedFeed: true",
    "SUVerifyUpdateBeforeExtraction: true",
    "MARKETING_VERSION: $(PERCH_MARKETING_VERSION)",
    "CURRENT_PROJECT_VERSION: $(PERCH_BUILD_NUMBER)",
])
require("app/Sources/DanotchApp.swift", [
    'Button("Check for Updates…")',
    "updates.checkForUpdates()",
])
require("app/Sources/UpdateController.swift", [
    "SPUStandardUpdaterController",
    "startingUpdater: configurationError == nil",
    'url.scheme?.lowercased() == "https"',
])
require("app/Sources/Views/NotchShellView.swift", [
    "viewModel.connectionState.requiresUpdate",
    'Button("Check for Updates")',
])
require(".github/workflows/release-macos.yml", [
    "ref: ${{ env.RELEASE_TAG }}",
    "git merge-base --is-ancestor",
    "Require successful main CI for release commit",
    "EXECUTOR_ARTIFACT_SIGNING_KEY_PEM_B64",
    "SPARKLE_ED25519_PRIVATE_KEY",
    "sparkle_public_key.swift",
    "generate_appcast",
    "<sparkle:version>$BUILD_NUMBER</sparkle:version>",
    "sparkle-signatures:",
    "sign_update",
    "XPCServices/Installer.xpc",
    "--preserve-metadata=entitlements",
    "Versions/B/Autoupdate",
    "Versions/B/Updater.app",
    "Inspect final public endpoints",
])
require("app/release-tools/package.json", ['"@vercel/blob": "2.6.1"'])
require("app/release-tools/blob-put.mjs", [
    "addRandomSuffix: false",
    "allowOverwrite:",
    "cacheControlMaxAge",
])
require("app/release-tools/blob-put.test.mjs", [
    "'x-add-random-suffix'",
    "'x-allow-overwrite'",
    "'x-cache-control-max-age'",
])
require("site/src/components/site-config.ts", [
    "VITE_DOWNLOAD_MANIFEST_URL",
])
require("site/src/components/Download.tsx", [
    "downloadManifestUrl",
    "invalid release manifest",
    "cache: 'no-store'",
])

print("Direct-distribution release invariants verified.")
