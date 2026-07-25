# Maintainer release keys

Perch stable releases use annotated OpenPGP-signed Git tags. Install and update
scripts trust only full primary-key fingerprints listed in
`release/maintainer-gpg-fingerprints.txt`.

## Initial key publication

No maintainer fingerprint is published yet. This is intentional fail-closed
configuration, not a sample value: source installation and updates remain
blocked until maintainers complete this procedure.

1. Create a dedicated offline-capable OpenPGP signing key. Keep its primary key
   offline and use a release-signing subkey where practical.
2. Verify the full primary fingerprint through at least two independent
   maintainer channels.
3. Add the uppercase, unspaced full primary fingerprint to
   `release/maintainer-gpg-fingerprints.txt`.
4. Export the minimal public key to `release/keys/<fingerprint>.asc`.
5. Review the fingerprint and exported key in a protected pull request.
6. Merge the key before creating the first installable release tag.

Never add short key IDs, email addresses as identity, private keys, revocation
certificates, or generated placeholder fingerprints.

## Rotation and revocation

Add and review a replacement key in a release signed by an already trusted key
before using it. Keep the old fingerprint during a transition release. Remove
the old fingerprint in a later signed release.

For compromise, publish the revocation immediately, remove the fingerprint,
rotate any related credentials, and issue a new signed release through a
separately verified key. Existing clients must not trust a newly introduced key
solely because an untrusted tag contains it.

## Operator verification

```bash
git fetch --tags origin
git cat-file -t refs/tags/v1.2.3   # must print: tag
git verify-tag --raw v1.2.3
```

The `VALIDSIG` primary fingerprint must exactly match an uncommented line in
the allowlist. The updater applies the allowlist from the currently installed
trusted release, preventing a candidate update from replacing its own trust
root.
