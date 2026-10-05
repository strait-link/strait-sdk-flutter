# AGENTS.md: Strait Flutter SDK (strait_sdk)

Instructions for AI coding agents (Claude Code, Cursor, Codex, Copilot…) that add this SDK to an app or work on
this repo. Humans: see README.md.

Pure Dart. The app hands it the launch link, a stream of later links and the lifecycle; it resolves short links, runs the deferred check once per install and emits one event per link.

## Install

Not on pub.dev yet: a git dependency, plus the helper packages.

```yaml
# pubspec.yaml
dependencies:
  strait_sdk:
    git:
      url: https://github.com/bazingga08/strait-sdk-flutter
      ref: v0.8.1
```

```sh
flutter pub add app_links shared_preferences play_install_referrer flutter_timezone
```

Native link settings as for any app: Android App Links intent filter (`autoVerify`) for
`https://<handle>.strait.link` plus the custom scheme; iPhone Associated Domains `applinks:<handle>.strait.link`.

## Keys (the rule agents get wrong most)

- **Publishable key** `st_pub_live_…` (Dashboard → Get started): goes in the app. It is the only key this SDK takes (`publishableKey`).
- **Secret key** `st_live_…` (Dashboard → Settings → Secret keys): server only. Never put it in an app: anyone can extract it and change your links.
- Never commit either key's real value to this repo, tests or examples. Use placeholders like `st_pub_live_…`.

## Receive links: the one pattern

```dart
final links = StraitLinks(
  publishableKey: 'st_pub_live_…',        // never the secret key
  endpoint: 'https://acme.strait.link',       // the workspace's link domain
  platform: Platform.isIOS ? 'ios' : Platform.isAndroid ? 'android' : 'other',
  storage: PrefsStore(await SharedPreferences.getInstance()),   // a KeyValueStore
  installReferrer: () async => Platform.isAndroid ? (await PlayInstallReferrer.installReferrer).installReferrer : null,
  deviceFields: () => DeviceFields(/* portraitScreenWidth(...), devicePixelRatio, locale tag, IANA time zone */),
);
links.onLink.listen((e) { if (e.matched && e.path != null) navigate(e.path!, e.params); });  // before start()
final appLinks = AppLinks();
await links.start(
  initialUrl: (await appLinks.getInitialLink())?.toString(),
  urls: appLinks.uriLinkStream.map((u) => u.toString()),
  lifecycle: LifecycleFeed().stream,   // AppLifecycle from WidgetsBindingObserver
);
```

The full `PrefsStore`, `LifecycleFeed` and `deviceFields` code is in the docs. Pass the IANA time zone
(`Asia/Kolkata`) from `flutter_timezone`, never `DateTime.timeZoneName`.

## Verify

Run these; don't assume.

```sh
# 1. The link domain serves the verification files with this app in them
curl https://<handle>.strait.link/.well-known/assetlinks.json              # Android: package + every SHA-256
curl https://<handle>.strait.link/.well-known/apple-app-site-association   # iPhone: TeamID.bundleId
#    (or the free checker: https://straitlink.in/tools/  ·  MCP tool: check_app_links)

# 2. Android verified the host (fresh install). Want: verified
adb shell pm get-app-links <package.name>
```

3. Tap a link from WhatsApp or Gmail on a real phone: the app opens on the right screen and `onLink` fires
   with `matched: true`. The tap and the open appear in Dashboard → Analytics.
4. Deferred (Android): install from a Google Play internal-testing build, tap the link before installing, open
   the app: `onLink` fires with `kind: deferred`, `route: install_referrer`. iPhone install matching is in beta.

If links open the browser: a missing SHA-256 (most often the Play App Signing key from Play Console → App
integrity), a typo in the host, or the app was installed before the files were right (reinstall). See
https://straitlink.in/docs/troubleshooting/.

## Working on this repo

- Test: `dart pub get && dart test` (must pass before any commit; check the exit code).
- The match signature and the pure helpers are pinned by shared golden vectors
  (`test/*vectors*.json`): byte-identical copies live in every app and web SDK (the signature vectors in the
  engine too). Never edit a vector file
  here alone; vectors change only through `shared-spec/` and land in every repo together.
- The package's public identity (name, scope, owner, domain) lives only in `brand.json`; change it with
  `shared-spec/scripts/rename-brand.sh` (all SDKs) or `node scripts/brand.mjs --write`.
- Wire names are part of the contract: query params `strait_click` / `strait_link`, storage keys `strait.*`,
  headers `X-Strait-*`. Don't rename them.
- Brand: Strait (never "Straight"). Don't write superlatives ("best", "cheapest") or speed / match-rate numbers in
  docs or comments. iPhone install matching is in beta.

## More

- Docs for this SDK: https://straitlink.in/docs/sdks/flutter/
- All docs: https://straitlink.in/docs/ · REST API: https://straitlink.in/docs/api/
- Strait from AI tools (MCP server: create links, check App Links files, trace taps): https://straitlink.in/ai/
