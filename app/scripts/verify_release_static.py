#!/usr/bin/env python3
"""Fail when local source-distribution invariants drift."""

import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]


def require(path: str, snippets: list[str]) -> None:
    text = (ROOT / path).read_text()
    missing = [snippet for snippet in snippets if snippet not in text]
    if missing:
        raise SystemExit(f"{path} is missing release invariants: {missing}")

def forbid(path: str, snippets: list[str]) -> None:
    text = (ROOT / path).read_text()
    present = [snippet for snippet in snippets if snippet in text]
    if present:
        raise SystemExit(f"{path} contains forbidden hosted-distribution values: {present}")

require("app/project.yml", [
    'macOS: "26.0"',
    "ARCHS: arm64",
    "PerchDaemonHost:",
    "- sdk: Security.framework",
    "Contents/Resources/DaemonRuntime",
    "Contents/Resources/Daemon/entry.mjs",
    "MARKETING_VERSION: $(PERCH_MARKETING_VERSION)",
    "CURRENT_PROJECT_VERSION: $(PERCH_BUILD_NUMBER)",
])
forbid("app/project.yml", [
    "Sparkle",
    "SUFeedURL",
    "SUPublicEDKey",
    "PerchAPIBaseURL",
    "PerchDeviceGatewayURL",
    "CFBundleURLTypes",
])

require("app/Package.swift", [
    '.macOS("26.0")',
    'name: "PerchDaemonHost"',
    '.linkedFramework("Security")',
])
forbid("app/Package.swift", ["Sparkle"])

require("app/DaemonHost/main.swift", [
    "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly",
    "SecTrustedApplicationCreateFromPath",
    "SecAccessCreate",
    "kSecAttrAccess",
    "SecRandomCopyBytes",
    "SecStaticCodeCreateWithPath",
    "SecStaticCodeCheckValidityWithErrors",
    "kSecCSCheckAllArchitectures",
    "kSecCSCheckNestedCode",
    "kSecCSStrictValidate",
    "decodedValue.count == 32",
    "O_NOFOLLOW",
    "fchmod(descriptor, 0o700)",
    "umask(0o077)",
    "runtime discovery",
    "daemon logs",
    '"installation.secret"',
    '"provider.anthropic"',
    '"provider.openai"',
    '"provider.openrouter"',
    '"provider.deepseek"',
    '"provider.custom_openai"',
    '"composio"',
    'process.environment = [:]',
    'process.arguments = [layout.entrypoint.path]',
    '"type": "bootstrap"',
])

require("app/build.sh", [
    "PERCH_NODE_RUNTIME_DIR",
    "PERCH_NODE_SHA256",
    '"$NPM_BINARY" run --prefix "$BACKEND_DIR" build',
    '"$NPM_BINARY" ci --prefix "$STAGING_DIR" --omit=dev',
    "release build requires a non-empty executor manifest signature",
    "NodeRuntime.entitlements",
    "codesign --force --options runtime --sign - \"$BUNDLE_DIR/Helpers/PerchDaemonHost\"",
])
forbid("app/build.sh", [
    "notarytool",
    "Sparkle",
    "PERCH_SPARKLE",
    "VERCEL",
    "BLOB",
])

require("app/Resources/engineering.super.Perch.daemon.plist.template", [
    "engineering.super.Perch.daemon",
    "__PERCH_APP_PATH__/Contents/Helpers/PerchDaemonHost",
    "__PERCH_LOG_PATH__/daemon.log",
])
forbid("app/Resources/Info.plist", [
    "CFBundleURLTypes",
    "PerchAPIBaseURL",
    "PerchDeviceGatewayURL",
    "SUFeedURL",
    "SUPublicEDKey",
])
require("app/NodeRuntime.entitlements", [
    "com.apple.security.cs.allow-jit",
    "com.apple.security.cs.allow-unsigned-executable-memory",
    "com.apple.security.cs.disable-executable-page-protection",
    "com.apple.security.cs.disable-library-validation",
])

print("Local source-distribution invariants verified.")
