# Security Policy

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Email **security@perch.app** with:

- A description of the vulnerability and its potential impact
- Steps to reproduce or proof-of-concept (if safe to share)
- The version of Perch affected (check the app's About screen or the downloaded artifact's checksum)

We aim to acknowledge reports within **2 business days** and provide an initial assessment within **5 business days**.

Coordinated disclosure: please allow us reasonable time to investigate and patch before public disclosure.

## Supported Versions

Only the latest notarized release is actively patched. Older versions may not receive security updates.

## Security Architecture

See [/security](/security) on the public site for a summary of Perch's trust model, credential handling, and local isolation design.

Key properties:

- **Signed and notarized**: every public release is Developer ID signed, Hardened Runtime enabled, notarized by Apple, and stapled. Gatekeeper verification passes on a clean Mac.
- **No hosted shell execution**: the backend cannot invoke child processes or arbitrary shell commands.
- **Local execution isolation**: user-consented local commands run inside a disposable Apple Containerization VM with a workspace-scoped read-only mount, no host credentials, no implicit network, and bounded resources.
- **Tenant isolation**: ordinary requests use a per-caller JWT Supabase client protected by Row Level Security. No service-role credential is available to public request handlers.
- **Credentials in Keychain**: session tokens and device private keys are stored in the macOS Data Protection Keychain, not plaintext files.
- **Authenticated device channel**: the app connects outbound over WSS using HTTPS-issued one-use tickets. The unauthenticated localhost bridge (port 7778) is not present in production releases.

## Disclosure Timeline

| Phase | Target |
|-------|--------|
| Acknowledgement | ≤ 2 business days |
| Initial assessment | ≤ 5 business days |
| Patch for critical issues | ≤ 14 days |
| Public disclosure (coordinated) | After patch is available |

## Out of Scope

- Vulnerabilities in third-party services (Apple, Supabase, Composio, LLM providers) not under our control
- Social engineering attacks against Perch users
- Denial-of-service attacks against the hosted backend (report these separately)
- Issues in versions that are no longer supported
