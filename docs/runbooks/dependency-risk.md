# Dependency Risk Acceptance

Last reviewed: 2026-07-23

`npm audit --omit=dev` reports no high or critical findings. Eight low or
moderate findings remain in the transitive Composio → Mastra → MCP dependency
tree.

Accepted advisories:

- `GHSA-866g-f22w-33x8` affects AI SDK provider utilities through Mastra. Perch
  does not expose the affected utility directly; hosted requests also have
  application, token, spend, concurrency, and scheduler ceilings.
- `GHSA-frvp-7c67-39w9` affects Hono static-file handling on Windows. The Perch
  backend runs in a Linux container and does not expose Mastra's Hono static
  file server.

The npm-proposed remediation downgrades `@composio/anthropic` across a breaking
API boundary. Overriding Hono 1.x with 2.x or AI SDK provider utilities 2.x with
3.x would likewise be an untested major-version substitution. Those changes
are riskier than the currently unreachable paths and are not forced.

CI fails for high or critical advisories. Re-evaluate this acceptance whenever
Composio publishes a compatible dependency update, before enabling additional
Mastra/MCP server surfaces, or within 30 days—whichever happens first.
