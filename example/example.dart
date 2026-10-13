// Minimal use: the deferred link on first launch. For the full client (`StraitLinks`,
// direct + deferred links, open reporting) see the README.
import 'package:strait_sdk/strait_sdk.dart';

Future<void> main() async {
  // First launch after install: ask for the deferred link (never throws).
  final result = await resolveDeferredLink(
    publishableKey: 'st_pub_live_…', // Dashboard → Get started; never the secret key
    endpoint: 'https://<your-handle>.strait.link',
    platform: 'android',
    device: DeviceFields(
      screenWidth: portraitScreenWidth(392.7, 872.7),
      pixelRatio: 2.75,
      language: 'en',
      timezone: 'Asia/Kolkata',
    ),
  );
  if (result.matched && result.longUrl != null) print('route to ${result.longUrl}');
}
