// Live proof of doctor() against a real link host. Skipped unless
// STRAIT_DOCTOR_LIVE is set, so CI never calls Strait:
//   STRAIT_DOCTOR_LIVE=https://strait-dev.strait.link dart test test/doctor_live_test.dart -r expanded
import 'dart:io';

import 'package:strait_sdk/strait_sdk.dart';
import 'package:test/test.dart';

const fp = 'FA:C6:17:45:DC:09:03:78:6F:B9:ED:E6:2A:96:2B:39:9F:73:48:F0:BB:6F:89:9B:83:32:66:75:91:03:3B:9C';

void main() {
  final endpoint = Platform.environment['STRAIT_DOCTOR_LIVE'];
  final skip = endpoint == null ? 'set STRAIT_DOCTOR_LIVE=<link domain> to run' : null;

  Future<DoctorReport> run(String platform, String appId, [List<String> certSha256 = const []]) async {
    final links = StraitLinks(
      // No real key needed: doctor sends nothing but the GET.
      publishableKey: 'st_pub_live_placeholder',
      endpoint: endpoint!,
      platform: platform,
      deviceFields: () => const DeviceFields(screenWidth: 1, pixelRatio: 1, language: 'en', timezone: 'UTC'),
    );
    print('== $platform doctor(appId: $appId${certSha256.isEmpty ? '' : ', certSha256: $certSha256'})');
    final r = await links.doctor(appId: appId, certSha256: certSha256);
    print('report $r');
    await links.dispose();
    return r;
  }

  List<String> ids(DoctorReport r) => [for (final f in r.findings) f.id];

  test('android com.straitlink.app is listed, with its certificate', () async {
    expect(ids(await run('android', 'com.straitlink.app', [fp])), ['key.ok', 'app.listed', 'cert.listed']);
  }, skip: skip);
  test('ios in.straitlink.reference is listed', () async {
    expect(ids(await run('ios', 'in.straitlink.reference')), ['key.ok', 'app.listed']);
  }, skip: skip);
  test('an unlisted android package is app.missing', () async {
    final r = await run('android', 'com.example.notlisted');
    expect(ids(r), ['key.ok', 'app.missing']);
    expect(r.ok, isFalse);
  }, skip: skip);
  test('an unlisted iOS bundle ID is app.missing', () async {
    expect(ids(await run('ios', 'com.example.notlisted')), ['key.ok', 'app.missing']);
  }, skip: skip);
}
