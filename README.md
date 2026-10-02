# strait_sdk (Flutter / Dart)

Deferred deep linking for Flutter — the user taps your link, installs the app,
and lands on the right screen. No clipboard paste banner.

Part of [Strait](../). The match signature is a Dart port of
[`shared-spec`](../shared-spec) and is checked against the **same golden vectors**
as the server, web, and React Native SDKs (run by `dart test` in CI) — so the
signature can never drift across languages.

## Use

```dart
import 'package:strait_sdk/strait_sdk.dart';
import 'dart:ui';
import 'dart:io' show Platform;

final view = PlatformDispatcher.instance.views.first;
final device = DeviceFields(
  screenWidth: (view.physicalSize.width / view.devicePixelRatio).round(),
  pixelRatio: view.devicePixelRatio,
  language: PlatformDispatcher.instance.locale.languageCode,
  timezone: DateTime.now().timeZoneName, // see note below
);

final result = await resolveDeferredLink(
  publishableKey: 'bk_pub_live_…', // Dashboard → Get started → Publishable key
  endpoint: 'https://go.yourbrand.com',
  platform: Platform.isIOS ? 'ios' : 'android',
  device: device,
  installReferrer: await readPlayInstallReferrer(), // Android only; null otherwise
);

if (result.matched && result.longUrl != null) {
  // route to result.longUrl!
}
```

> **Publishable key:** Dashboard → Get started → Publishable key (`bk_pub_live_…`).
> It's safe to include in your app. Never put your secret key (`bk_live_…`) in an app.

> **Timezone:** the signature needs the IANA name (e.g. `Asia/Kolkata`). Get it
> from a plugin like `flutter_timezone`; `DateTime.timeZoneName` is an
> abbreviation on some platforms and won't match. Pass the IANA string.

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

The golden-vector suite (`test/signature_test.dart`) enforces byte-for-byte
parity with the other SDKs.
