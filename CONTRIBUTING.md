# Contributing to Perch

Thank you for helping improve Perch. Contributions are accepted under the
Apache License 2.0.

## Before opening a change

- Use an issue or discussion for substantial behavior, protocol, migration, or
  security-design changes.
- Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).
- Never commit credentials, tokens, private URLs, user data, signing keys, or
  generated local databases.
- Keep local-first boundaries intact: the daemon binds only to `127.0.0.1`,
  secrets belong in Keychain, and destructive actions require explicit consent.

## Development

Requirements are macOS 26+, Apple Silicon, Xcode 26+, Swift, XcodeGen, and Node
24. Use the exact package-manager lockfiles.

```bash
cd backend && npm ci && npm test && npm run build
cd ../app && swift test && swift build
cd ../site && npm ci && npm run lint && npm run build
cd .. && bash -n install.sh update.sh uninstall.sh scripts/lib/perch-common.sh
```

Distribution changes must also pass ShellCheck. Changes to SQLite migrations
must include forward-migration, backup/rollback, and integration coverage.

## Pull requests

Keep pull requests focused and explain:

1. the user-visible problem and intended behavior;
2. security, privacy, schema, and protocol impact;
3. tests run and any tests not run;
4. rollback behavior for storage or distribution changes.

Maintainers may request smaller commits or a design note for changes spanning
trust boundaries. Release tags and maintainer-key changes require maintainer
review under [docs/release-policy.md](docs/release-policy.md).

## Developer Certificate of Origin

By contributing, you certify the Developer Certificate of Origin 1.1. Add a
`Signed-off-by: Name <email>` trailer to each commit with `git commit -s`.
This attests that you have the right to submit the contribution under this
project's license; it is not a copyright assignment.
