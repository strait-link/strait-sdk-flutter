// Minimal use of the pure-Dart helpers. For the full client (`StraitLinks`,
// direct + deferred links, open reporting) see the README.
import 'package:strait_sdk/strait_sdk.dart';

Future<void> main() async {
  // Classify an incoming URL: a short link needs resolving, anything else is a destination.
  final link = classifyUrl('https://go.yourbrand.com/launch', ['go.yourbrand.com']);
  print('needs resolve: ${link?.needsResolve}');

  // First launch after install: ask for the deferred link (never throws).
  final result = await resolveDeferredLink(
    publishableKey: 'st_pub_live_…', // Dashboard → Get started; never the secret key
    endpoint: 'https://go.yourbrand.com',
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
