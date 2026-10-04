# Publishing to pub.dev

The package name (`<slug>_sdk`), homepage, repository and copyright holder come from
`brand.json`. Nothing else in this repo types them (`scripts/brand.mjs` also renames
`lib/<name>.dart` and every `package:<name>/` import when the name changes).

## One-time owner setup

1. **Pick the brand.** From the workspace root (the folder holding every SDK repo): `shared-spec/scripts/rename-brand.sh … --final --apply`
   (or edit `brand.json`, set `"final": true`, run `node scripts/brand.mjs --write`).
   Commit. Check the name is free: `https://pub.dev/packages/<name>`.
2. **Make the GitHub repo public.**
3. **Verified publisher (recommended):** pub.dev → sign in with the Google
   account that owns straitlink.in → *Create publisher* → verify the domain (a DNS TXT record via Google
   Search Console). Packages then show "verified publisher <domain>".
4. **First version by hand** (pub.dev only allows automated publishing for a package
   that already exists):
   ```sh
   dart pub publish --dry-run   # must say 0 warnings
   dart pub publish             # opens a browser to sign in, then uploads
   ```
   Then on pub.dev → the package → *Admin* → transfer it to the verified publisher.
5. **Turn on automated publishing:** pub.dev → package → *Admin* → *Automated
   publishing* → *Enable publishing from GitHub Actions*: repository
   `<owner>/<repo>`, tag pattern `v{{version}}`. (Optionally require a GitHub
   environment.)
6. **Switch the workflow on:** GitHub repo → *Settings → Secrets and variables →
   Actions → Variables → New repository variable*: `PUB_DEV_PUBLISHING` = `true`.
   No secret is needed — pub.dev trusts the workflow's OIDC token.

## Every release

1. Bump `version:` in pubspec.yaml, add a `## X.Y.Z` entry to CHANGELOG.md, commit.
2. `dart pub publish --dry-run` → 0 warnings (tests and repo tooling are excluded by `.pubignore`).
3. `git tag vX.Y.Z && git push origin main vX.Y.Z`.
4. *Actions → Release*: version check → analyze → tests → brand check → dry run →
   publish (only when `PUB_DEV_PUBLISHING` is `true`).
