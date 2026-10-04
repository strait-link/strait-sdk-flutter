# strait_sdk (Flutter / Dart)

Deep linking for Flutter: verified links and custom schemes open the right
screen, and deferred links survive the install (the user taps your link,
installs the app, and lands on the right screen). No clipboard paste banner.

Part of [Strait](https://straitlink.in). The match signature is a Dart port of
the shared Strait signature recipe and is checked against the **same golden vectors**
as the server, web, and React Native SDKs (run by `dart test` in CI) — so the
signature can never drift across languages.

## Install

<!-- brand:install -->
```sh
dart pub add strait_sdk      # Flutter apps: flutter pub add strait_sdk
```
<!-- /brand:install -->

Not on pub.dev yet. Until it is, add it as a git dependency in `pubspec.yaml`:

```yaml
dependencies:
  strait_sdk:
    git:
      url: https://github.com/bazingga08/strait-sdk-flutter
      ref: v0.7.1
```

Pure Dart (no Flutter dependency), so it works in Flutter apps and Dart servers alike.

## Use (recommended): `StraitLinks`

`StraitLinks` is pure Dart. Your app hands it the launch URL, a stream of
later URLs and a stream of lifecycle states; it resolves short links, labels
the app state, runs the deferred check once per install, and emits one
`LinkEvent` for every case. Typical wiring with
[`app_links`](https://pub.dev/packages/app_links),
[`shared_preferences`](https://pub.dev/packages/shared_preferences),
[`play_install_referrer`](https://pub.dev/packages/play_install_referrer) and
[`flutter_timezone`](https://pub.dev/packages/flutter_timezone):

```dart
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui';

import 'package:app_links/app_links.dart';
import 'package:strait_sdk/strait_sdk.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:play_install_referrer/play_install_referrer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the once-per-install flag and unsent open reports.
class PrefsStore implements KeyValueStore {
  PrefsStore(this.prefs);
  final SharedPreferences prefs;
  @override
  Future<String?> get(String key) async => prefs.getString(key);
  @override
  Future<void> set(String key, String value) => prefs.setString(key, value);
}

/// Feeds Flutter lifecycle changes to the SDK.
class LifecycleFeed with WidgetsBindingObserver {
  final _ctl = StreamController<AppLifecycle>.broadcast(sync: true);
  Stream<AppLifecycle> get stream => _ctl.stream;
  LifecycleFeed() { WidgetsBinding.instance.addObserver(this); }
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) => _ctl.add(switch (s) {
        AppLifecycleState.resumed => AppLifecycle.active,
        AppLifecycleState.inactive => AppLifecycle.inactive,
        _ => AppLifecycle.background, // hidden, paused, detached
      });
}

Future<StraitLinks> startStrait() async {
  WidgetsFlutterBinding.ensureInitialized();
  final timezone = await FlutterTimezone.getLocalTimezone(); // IANA, e.g. Asia/Kolkata
  final strait = StraitLinks(
    publishableKey: 'st_pub_live_…', // Dashboard → Get started
    endpoint: 'https://<your-handle>.strait.link',
    linkHosts: const ['links.yourbrand.com'], // extra custom domains, if any
    platform: Platform.isIOS ? 'ios' : Platform.isAndroid ? 'android' : 'other',
    storage: PrefsStore(await SharedPreferences.getInstance()),
    installReferrer: () async =>
        Platform.isAndroid ? (await PlayInstallReferrer.installReferrer).installReferrer : null,
    deviceFields: () {
      final view = PlatformDispatcher.instance.views.first;
      return DeviceFields(
        // Portrait (shorter-side) logical width, rounded like the browser (contract B2, B17).
        screenWidth: portraitScreenWidth(view.physicalSize.width / view.devicePixelRatio,
            view.physicalSize.height / view.devicePixelRatio),
        pixelRatio: view.devicePixelRatio,
        language: PlatformDispatcher.instance.locale.toLanguageTag(),
        timezone: timezone,
      );
    },
  );

  // Subscribe before start() so nothing is missed (past events replay anyway).
  strait.onLinkStart.listen((s) { /* show "Opening link…" until event s.id */ });
  strait.onLink.listen((e) {
    if (e.matched && e.path != null) {
      // navigate to e.path with e.params; e.appState is closed/background/foreground
    }
  });

  final appLinks = AppLinks();
  final initial = await appLinks.getInitialLink();
  await strait.start(
    initialUrl: initial?.toString(),
    urls: appLinks.uriLinkStream.map((u) => u.toString()),
    lifecycle: LifecycleFeed().stream,
  );
  return strait;
}
```

Notes:

- `app_links` 6+ also emits the launch link on `uriLinkStream`; `start()`
  ignores that first echo, so the launch link is handled once.
- Analytics: `strait.trackEvent('purchase', value: 49.99, currency: 'USD', linkId: e.linkId)`.
  The event carries the tap id of the last attributed link open for 7 days, so
  the dashboard can place revenue on that tap's channel and A/B variant
  (B15/B16). Every attributed open supplies one: a browser hand-off, a Play
  install, or the engine's reply to a verified short link or a deferred match.
  A newer open replaces the older tap. Pass `clickId:` to set it yourself.
- Fingerprint debug: `strait.reportFingerprint()` then `strait.compareFingerprint()`.
- `strait.checkDeferred()` re-runs the deferred check (debugging); it doesn't
  touch the once-per-install flag and never records an install.
- `flutter_timezone` 4.x returns a `TimezoneInfo`; use `.identifier`.

### What Strait records automatically (no extra code)

Every time a link opens the app, the SDK reports it once (contract B14):

| How the app opened | Reported via | Joined to |
|---|---|---|
| Verified link tapped in WhatsApp, Gmail, Messages… | `/v1/resolve` (the lookup is the report) | the link; also counted as a tap |
| Browser handed off to the app (`yourapp://…`) | `/v1/open` | the exact tap (`strait_click`, removed before your app sees the URL) |
| First open after a Play install | `/v1/referrer` | the exact tap that sent the user to the store |
| First open after an App Store install | `/v1/match` | the matched tap |
| Your own https links | `/v1/open` | host + path (plus `utm_source`, if any); the query and fragment never leave the device (B18) |

Reports that can't be sent (offline, server busy) are saved in `storage`
(key `strait.pendingOpens`, so pass a persistent `KeyValueStore`) and retried
on the next `start()`, whenever the `lifecycle` stream reports `active`, and
after any report that gets through, for up to 7 days (max 100). The engine
de-duplicates by open id (`LinkEvent.id`), so nothing is counted twice.
Navigation never waits for a report. The first launch of an install is marked
as such, so dashboards can tell **new users** (installed and opened) from
**existing users** (already had the app). The deferred check is only marked
done once the server answered, so an offline first launch is retried on the
next launch. Debugging: `await strait.pendingOpenReports()` (count waiting)
and `await strait.flushOpenReports()` (send now).

### `LinkEvent`

| Field | Meaning |
|---|---|
| `kind` | `direct` (app opened by a link) / `deferred` (tapped before install) |
| `route` | `app_link`, `custom_scheme`, `install_referrer`, `fingerprint` (`route.value`) |
| `appState` | `closed`, `background`, `foreground` |
| `matched`, `reason` | `reason`: `not_found`, `expired`, `password_protected`, `no_match`, `network`, `invalid_url` |
| `rawUrl` | the URL the OS handed the app |
| `url`, `path`, `params` | the destination to navigate to |
| `linkId`, `ms`, `at`, `id` | link id, resolve time (ms), arrival time (epoch ms), id shared with `LinkStart` |

## Use (legacy): `resolveDeferredLink`

Still supported for apps that only want the deferred match:

```dart
final result = await resolveDeferredLink(
  publishableKey: 'st_pub_live_…',
  endpoint: 'https://<your-handle>.strait.link',
  platform: Platform.isIOS ? 'ios' : 'android',
  device: device, // DeviceFields as above
  installReferrer: referrer, // Android only; null otherwise
);
if (result.matched && result.longUrl != null) { /* route */ }
```

> **Publishable key:** Dashboard → Get started → Publishable key (`st_pub_live_…`).
> It's safe to include in your app. Never put your secret key (`st_live_…`) in an app.

> **Timezone:** the signature needs the IANA name (e.g. `Asia/Kolkata`). Get it
> from a plugin like `flutter_timezone`; `DateTime.timeZoneName` is an
> abbreviation on some platforms and won't match. Pass the IANA string.

## SDK contract

Implements every behaviour in
the Strait SDK contract:
B1 (publishableKey on every call) · B2 (`browserScreenWidth`) · B3 (short links
→ `/v1/resolve`, engine reason reported) · B4 (`classifyUrl`, tap id removed via
`takeClickId`) · B5 (`AppStateTracker`) · B6 (once per install,
skipped-but-marked on a link launch, marked only once the engine answered) ·
B7 (Install Referrer → `/v1/referrer` with `parseStraitClick`, else
`/v1/match`) · B8 (iOS `/v1/match`) · B9 (one `LinkEvent` type, replay,
`onLinkStart`) · B10 (never throws) · B11 (`jsonEncode`) · B12 (`splitUrl`, no
`Uri` parsing) · B13 (`trackEvent`, `reportFingerprint`, `compareFingerprint`)
· B14 (every open reported once, `strait.pendingOpens` retry queue,
`pendingOpenReports`, `flushOpenReports`) · B15 (events carry the remembered
tap id, `strait.lastTap`, `eventClickId`) · B16 (the tap id from the
`/v1/resolve`, `/v1/match` and `/v1/referrer` replies, `replyClickId`) · B17
(portrait screen width, `portraitScreenWidth`) · B18 (reported and queued URLs
carry no query or fragment except `utm_source`, `reportUrl`; expired remembered
taps are deleted, `staleTap`). Both shared vector files (conformance v6) are
asserted in `dart test`.

## How it matches

| Platform | Method | Precision |
|----------|--------|-----------|
| Android  | Play Install Referrer (`strait_link`) | deterministic (`install_referrer`) |
| Android (no referrer) / iOS | server-side device fingerprint | probabilistic |

`resolveDeferredLink` never throws — returns `MatchResult.none` on any error.
The client sends only coarse device fields; the **server** adds the observed IP
and computes the signature.

## Test

```sh
dart pub get && dart test
```

`test/signature_test.dart` (signature) and `test/conformance_test.dart`
(URL / referrer / app-state logic) enforce byte-for-byte parity with the other
SDKs; `test/client_test.dart` covers the client scenarios with a fake engine and
fake lifecycle; `test/opens_test.dart` covers open reporting (B14).
