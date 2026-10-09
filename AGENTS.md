# AGENTS.md: Strait Flutter SDK (strait_sdk)

Instructions for AI coding agents (Claude Code, Cursor, Codex, Copilot…) that add this SDK to an app or work on
this repo. Humans: see README.md.

Pure Dart. The app hands it the launch link, a stream of later links and the lifecycle; it resolves short links, runs the deferred check once per install and emits one event per link.

## Install

**Not on pub.dev yet** (`flutter pub add strait_sdk` fails until it is published). Use a git
dependency, plus the helper packages. Don't invent a pub.dev version or switch to a hosted dependency.

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

## Stop and ask the human (an agent can't do these)

Stop, say exactly what you need and why, and wait. Don't guess, fake or skip these:

1. **Account and keys.** Signing up at https://app.straitlink.in and copying the publishable key
   (`st_pub_live_…`) and, for server code, the secret key. There is no signup API. Ask the human to paste
   the publishable key; never ask for or handle the secret key in app code.
2. **The workspace handle.** The `<handle>` in `https://<handle>.strait.link` (Dashboard). Don't make one up.
3. **Dashboard app settings.** Android package name, every SHA-256 signing fingerprint (including the Play
   App Signing key from Play Console → App integrity), the custom scheme, and for iPhone the Apple Team ID
   and bundle ID. There is no settings API yet, so even when the checker below finds the problem, the human
   fixes it in Dashboard → Settings.
4. **Signing and store builds.** Release keystores, Play Console internal-testing uploads, Xcode signing and
   the Associated Domains capability.
5. **A real phone.** The final tap test (steps 4 to 6 below) needs a person with a device.

## Receive links: the one pattern

```dart
final links = StraitLinks(
  publishableKey: 'st_pub_live_…',        // never the secret key
  endpoint: 'https://hilltop.strait.link',   // the workspace's link domain
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

Run these; don't assume. Steps 1 to 3 need no phone, so run them in a loop after every config change
until they pass, then hand over to the human for steps 4 to 6.

```sh
# 1. Keyless App Links / Universal Links checker (no key; 10 per minute). Want: no "error" findings
curl "https://strait.link/v1/tools/app-links?domain=<handle>.strait.link"

# 2. Dry-run a tap without recording it or counting it toward the plan. Want: the decision and
#    location you expect for each user agent (not "blocked", "not_live" or "expired")
curl "https://strait.link/v1/simulate?url=https://<handle>.strait.link/<slug>&ua=android&publishableKey=st_pub_live_…"
curl "https://strait.link/v1/simulate?url=https://<handle>.strait.link/<slug>&ua=whatsapp-android&publishableKey=st_pub_live_…"
```

```sh
# 3. The link domain serves the verification files with this app in them
curl https://<handle>.strait.link/.well-known/assetlinks.json              # Android: package + every SHA-256
curl https://<handle>.strait.link/.well-known/apple-app-site-association   # iPhone: TeamID.bundleId
#    (or the free checker: https://straitlink.in/tools/  ·  MCP tool check_app_links, once the MCP server is published)

# 4. Android verified the host (fresh install). Want: verified
adb shell pm get-app-links <package.name>
```

5. Tap a link from WhatsApp or Gmail on a real phone: the app opens on the right screen and `onLink` fires
   with `matched: true`. The tap and the open appear in Dashboard → Analytics.
6. Deferred (Android): install from a Google Play internal-testing build, tap the link before installing, open
   the app: `onLink` fires with `kind: deferred`, `route: install_referrer`. iPhone install matching is in beta.

If links open the browser: a missing SHA-256 (most often the Play App Signing key from Play Console → App
integrity), a typo in the host, or the app was installed before the files were right (reinstall). See
https://straitlink.in/docs/troubleshooting/.

## Working on this repo

- Test: `dart pub get && dart test` (must pass before any commit; check the exit code).
- The match signature and the pure helpers are pinned by shared golden vectors
  (`test/*vectors*.json`): byte-identical copies live in every SDK and the engine. Never edit a vector file
  here alone; vectors change only through `shared-spec/` and land in every repo together.
- The package's public identity (name, scope, owner, domain) lives only in `brand.json`; change it with
  `shared-spec/scripts/rename-brand.sh` (all SDKs) or `node scripts/brand.mjs --write`.
- Wire names are part of the contract: query params `strait_click` / `strait_link`, storage keys `strait.*`,
  headers `X-Strait-*`. Don't rename them.
- Brand: Strait (never "Straight"). Don't write superlatives ("best", "cheapest") or speed / match-rate numbers in
  docs or comments. iPhone install matching is in beta.

## Support

support@straitlink.in (replies within 1 working day, IST) or a GitHub issue on this repo. Security issues go
to security@straitlink.in, never a public issue (SECURITY.md).

## More

- Docs for this SDK: https://straitlink.in/docs/sdks/flutter/
- All docs: https://straitlink.in/docs/ · REST API: https://straitlink.in/docs/api/
- Strait from AI tools (MCP server: create links, check App Links files, trace taps): https://straitlink.in/ai/
