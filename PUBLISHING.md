# Publishing to pub.dev

## Where this stands (12 Oct 2026)

- `strait_sdk` is not on pub.dev yet (the name is free) and the publisher `straitlink.in` does not
  exist yet. The repo is public. The repo variable `PUB_DEV_PUBLISHING` is not set, so the
  v0.8.2 and v0.8.3 release runs passed every check and published nothing, as designed.
- Tag v0.8.3 (`a51a959`): `dart pub publish --dry-run` gives 0 warnings, 299 tests pass,
  `brand.mjs --release` is in sync. It is the version to put up first.
- The founder's steps (about 20 minutes, all by hand, once):
  1. pub.dev, **Sign in** with the Google account that owns straitlink.in, avatar menu,
     **Create publisher**, domain `straitlink.in` (already verified in Search Console, so pub.dev
     only asks to confirm).
  2. Terminal:
     ```sh
     git clone https://github.com/bazingga08/strait-sdk-flutter.git && cd strait-sdk-flutter
     git checkout v0.8.3
     dart pub get && dart pub publish --dry-run   # must say 0 warnings
     dart pub publish                             # browser sign-in, then type y
     ```
  3. pub.dev, `strait_sdk`, **Admin**, **Transfer to publisher**, `straitlink.in`.
  4. Same **Admin** page, **Automated publishing**, **Enable publishing from GitHub Actions**:
     repository `bazingga08/strait-sdk-flutter`, tag pattern `v{{version}}`, leave
     "Require GitHub Actions environment" off. **Update**.
  5. GitHub, strait-sdk-flutter, **Settings**, **Secrets and variables**, **Actions**,
     **Variables**, **New repository variable**: name `PUB_DEV_PUBLISHING`, value `true`
     (or `gh variable set PUB_DEV_PUBLISHING --body true -R bazingga08/strait-sdk-flutter`).
  6. Check: https://pub.dev/packages/strait_sdk shows 0.8.3 and "verified publisher
     straitlink.in". The next tag (v0.8.4) then publishes from Actions with no secret.

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
