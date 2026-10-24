import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:strait_sdk/strait_sdk.dart';
import 'package:test/test.dart';

// Every row of shared-spec ADR 0002 (contract B23), word for word.
const pk = 'st_pub_live_abc123';
const ep = 'https://acme.strait.link';
const fp = 'FA:C6:17:45:DC:09:03:78:6F:B9:ED:E6:2A:96:2B:39:9F:73:48:F0:BB:6F:89:9B:83:32:66:75:91:03:3B:9C';
const otherFp = '6B:A3:E4:40:DF:12:16:87:B1:C6:98:7F:E1:9A:4E:28:CF:96:A6:61:38:40:28:00:03:90:56:EA:42:6F:7C:18';
const device = DeviceFields(screenWidth: 393, pixelRatio: 3, language: 'en-IN', timezone: 'Asia/Kolkata');

String assetlinks(List<(String, List<String>)> apps) => jsonEncode([
      for (final (pkg, fps) in apps)
        {
          'relation': ['delegate_permission/common.handle_all_urls'],
          'target': {'namespace': 'android_app', 'package_name': pkg, 'sha256_cert_fingerprints': fps},
        }
    ]);
String aasa(List<String> appIDs) => jsonEncode({
      'applinks': {
        'apps': [],
        'details': appIDs.isEmpty
            ? []
            : [
                {
                  'appIDs': appIDs,
                  'components': [
                    {'/': '/*'}
                  ]
                }
              ],
      }
    });

DoctorFile ok200(String body) => DoctorFile(200, body);
List<String> ids(List<DoctorFinding> f) => [for (final x in f) x.id];
DoctorFinding? byId(List<DoctorFinding> f, String id) => f.where((x) => x.id == id).firstOrNull;
DoctorFinding okF(String id, String title) => DoctorFinding(id: id, severity: 'ok', title: title, fix: '');
DoctorFinding errF(String id, String title, String fix) => DoctorFinding(id: id, severity: 'error', title: title, fix: fix);

void main() {
  group('doctorFindings: key', () {
    DoctorFinding run(String key) =>
        doctorFindings(publishableKey: key, endpoint: 'not a url', platform: 'android').findings.first;

    test('key.ok for st_pub_', () {
      expect(run(pk), okF('key.ok', 'Publishable key is set'));
    });
    for (final k in ['st_live_x', 'st_test_x']) {
      test('key.secret for $k', () {
        expect(
            run(k),
            errF('key.secret', 'This is a secret key, not the publishable key',
                'Use the publishable key (st_pub_…) from Dashboard → Get started, and revoke this secret key in Dashboard → Settings → Secret keys: it has been inside your app.'));
      });
    }
    for (final k in ['', 'bk_pub_x', 'pub_live_x']) {
      test('key.invalid for "$k"', () {
        expect(run(k),
            errF('key.invalid', 'Not a publishable key', 'Copy the publishable key (st_pub_…) from Dashboard → Get started.'));
      });
    }
  });

  group('doctorFindings: endpoint', () {
    for (final e in ['http://acme.strait.link', 'acme.strait.link', 'https://', 'https:///x', '']) {
      test('endpoint.invalid for "$e", no host checks', () {
        final r = doctorFindings(publishableKey: pk, endpoint: e, platform: 'ios', file: ok200(aasa(['T.a'])));
        expect(r.findings, [
          okF('key.ok', 'Publishable key is set'),
          errF('endpoint.invalid', "The endpoint isn't an https link domain",
              'Set endpoint to your link domain from Dashboard → Get started, e.g. https://<handle>.strait.link.'),
        ]);
        expect(r.ok, isFalse);
      });
    }
  });

  for (final platform in ['android', 'ios']) {
    group('doctorFindings: host checks ($platform)', () {
      final file = platform == 'android' ? 'assetlinks.json' : 'apple-app-site-association';
      DoctorReport run(DoctorFile? f) =>
          doctorFindings(publishableKey: pk, endpoint: '$ep/', platform: platform, file: f);

      test('no file (not fetched): key and endpoint checks only', () {
        expect(ids(run(null).findings), ['key.ok']);
      });

      test('host.unreachable when the GET failed', () {
        final r = run(const DoctorFile(null, null));
        expect(ids(r.findings), ['key.ok', 'host.unreachable']);
        expect(
            r.findings[1],
            errF('host.unreachable', "Can't reach acme.strait.link",
                'Check that endpoint is your link domain (Dashboard → Get started) and that this device is online.'));
        expect(r.ok, isFalse);
      });

      for (final f in [
        const DoctorFile(404, ''),
        const DoctorFile(200, '<html>hi</html>'),
        DoctorFile(200, platform == 'android' ? '{}' : '[]'),
        const DoctorFile(200, null),
      ]) {
        test('host.file_missing for ${f.status} ${f.body}', () {
          final r = run(f);
          expect(ids(r.findings), ['key.ok', 'host.file_missing']);
          expect(
              r.findings[1],
              errF('host.file_missing', "acme.strait.link doesn't serve $file",
                  'Use your Strait link domain as endpoint (Dashboard → Get started); Strait serves this file there.'));
        });
      }

      test('app.none when the file lists no app', () {
        final r = run(ok200(platform == 'android' ? '[]' : aasa([])));
        expect(
            r.findings[1],
            errF('app.none', 'No ${platform == 'android' ? 'Android' : 'iOS'} app is set up for acme.strait.link',
                'Add your app in Dashboard → Apps & stores.'));
        expect(r.ok, isFalse);
      });
    });
  }

  group('doctorFindings: Android app and certificate', () {
    final body = assetlinks([
      ('com.acme.app', [fp]),
      ('com.acme.other', [otherFp]),
    ]);
    DoctorReport run(String? appId, [List<String> certSha256 = const []]) => doctorFindings(
        publishableKey: pk, endpoint: ep, platform: 'android', appId: appId, certSha256: certSha256, file: ok200(body));

    test('app.listed + cert.listed, ok', () {
      final r = run('com.acme.app', [fp.toLowerCase().replaceAll(':', '')]);
      expect(r.findings, [
        okF('key.ok', 'Publishable key is set'),
        okF('app.listed', 'acme.strait.link lists com.acme.app'),
        okF('cert.listed', "This build's signing certificate is listed"),
      ]);
      expect(r.ok, isTrue);
    });

    test('cert.missing when this build is signed with another app’s fingerprint', () {
      final r = run('com.acme.app', [otherFp]);
      expect(
          byId(r.findings, 'cert.missing'),
          errF('cert.missing', "This build's signing certificate isn't listed for com.acme.app",
              'Add $otherFp in Dashboard → Apps & stores. Debug, release and Play App Signing keys each have their own fingerprint.'));
      expect(r.ok, isFalse);
    });

    test('no certificate check when the certificate is unknown', () {
      expect(ids(run('com.acme.app').findings), ['key.ok', 'app.listed']);
    });

    test('app.missing lists what is there, no certificate check', () {
      expect(run('com.acme.nope', [fp]).findings.skip(1), [
        errF('app.missing', "acme.strait.link doesn't list com.acme.nope",
            'Add com.acme.nope in Dashboard → Apps & stores (listed now: com.acme.app, com.acme.other).'),
      ]);
    });

    test('app.unknown (warn) when the package is unknown; ok stays true', () {
      for (final appId in [null, '', '  ']) {
        final r = run(appId, [fp]);
        expect(r.findings.skip(1), [
          const DoctorFinding(
              id: 'app.unknown',
              severity: 'warn',
              title: 'acme.strait.link lists com.acme.app, com.acme.other',
              fix: 'Make sure your app is one of these.'),
        ]);
        expect(r.ok, isTrue);
      }
    });
  });

  group('doctorFindings: iOS app', () {
    final body = aasa(['TEAM123456.com.acme.app', 'TEAM123456.com.acme.clip']);
    DoctorReport run(String? appId, [List<String> certSha256 = const []]) => doctorFindings(
        publishableKey: pk, endpoint: ep, platform: 'ios', appId: appId, certSha256: certSha256, file: ok200(body));

    test('app.listed matches the bundle ID suffix and shows the full appID; no certificate check on iOS', () {
      final r = run('com.acme.app', [fp]);
      expect(r.findings.skip(1), [okF('app.listed', 'acme.strait.link lists TEAM123456.com.acme.app')]);
      expect(r.ok, isTrue);
    });

    test('a bundle ID that is only a partial suffix is not listed', () {
      expect(byId(run('acme.app').findings, 'app.missing'), isNull); // ".acme.app" is a real dot suffix
      expect(byId(run('me.app').findings, 'app.missing')?.title, "acme.strait.link doesn't list me.app");
    });

    test('app.missing', () {
      expect(
          byId(run('in.other.app').findings, 'app.missing'),
          errF('app.missing', "acme.strait.link doesn't list in.other.app",
              'Add in.other.app in Dashboard → Apps & stores (listed now: TEAM123456.com.acme.app, TEAM123456.com.acme.clip).'));
    });

    test('app.unknown', () {
      expect(run(null).findings.skip(1), [
        const DoctorFinding(
            id: 'app.unknown',
            severity: 'warn',
            title: 'acme.strait.link lists TEAM123456.com.acme.app, TEAM123456.com.acme.clip',
            fix: 'Make sure your app is one of these.'),
      ]);
    });

    test('reads the older `paths` style (appID string) too', () {
      final old = jsonEncode({
        'applinks': {
          'apps': [],
          'details': [
            {
              'appID': 'TEAM123456.com.acme.app',
              'paths': ['*']
            }
          ]
        }
      });
      final r = doctorFindings(publishableKey: pk, endpoint: ep, platform: 'ios', appId: 'com.acme.app', file: ok200(old));
      expect(ids(r.findings), ['key.ok', 'app.listed']);
    });
  });

  group('StraitLinks.doctor()', () {
    StraitLinks make(String platform, http.Client client, {String endpoint = ep}) => StraitLinks(
        publishableKey: pk, endpoint: endpoint, platform: platform, deviceFields: () => device, client: client);
    (MockClient, List<Uri>) respond(int status, String body) {
      final urls = <Uri>[];
      return (
        MockClient((req) async {
          urls.add(req.url);
          return http.Response(body, status);
        }),
        urls
      );
    }

    test('Android: one GET of assetlinks.json, returns the report', () async {
      final (client, urls) = respond(200, assetlinks([('com.acme.app', [fp])]));
      final r = await make('android', client).doctor(appId: 'com.acme.app', certSha256: [fp]);
      expect(urls.map((u) => u.toString()), ['https://acme.strait.link/.well-known/assetlinks.json']);
      expect(r.ok, isTrue);
      expect(ids(r.findings), ['key.ok', 'app.listed', 'cert.listed']);
    });

    test('iOS: one GET of apple-app-site-association', () async {
      final (client, urls) = respond(200, aasa(['TEAM123456.com.acme.app']));
      final r = await make('ios', client, endpoint: '$ep/').doctor(appId: 'com.acme.app');
      expect(urls.map((u) => u.toString()), ['https://acme.strait.link/.well-known/apple-app-site-association']);
      expect(ids(r.findings), ['key.ok', 'app.listed']);
    });

    test('no appId: app.unknown', () async {
      final (client, _) = respond(200, aasa(['TEAM123456.com.acme.app']));
      expect(ids((await make('ios', client).doctor()).findings), ['key.ok', 'app.unknown']);
    });

    test('never throws: a failing request is host.unreachable', () async {
      final client = MockClient((_) async => throw http.ClientException('offline'));
      final r = await make('android', client).doctor(appId: 'com.acme.app');
      expect(ids(r.findings), ['key.ok', 'host.unreachable']);
      expect(r.ok, isFalse);
    });

    test('an invalid endpoint makes no request', () async {
      final (client, urls) = respond(200, '[]');
      final r = await make('android', client, endpoint: 'http://acme.strait.link').doctor();
      expect(urls, isEmpty);
      expect(ids(r.findings), ['key.ok', 'endpoint.invalid']);
    });

    test('platform "other": key and endpoint checks only, no request', () async {
      final (client, urls) = respond(200, '[]');
      final r = await make('other', client).doctor();
      expect(urls, isEmpty);
      expect(ids(r.findings), ['key.ok']);
    });

    test('logs each finding with the [Strait doctor] prefix (debug builds: asserts on)', () async {
      final (client, _) = respond(404, '');
      final lines = <String>[];
      await runZoned(() => make('android', client).doctor(),
          zoneSpecification: ZoneSpecification(print: (_, __, ___, line) => lines.add(line)));
      expect(lines, [
        '[Strait doctor] ok key.ok: Publishable key is set',
        "[Strait doctor] error host.file_missing: acme.strait.link doesn't serve assetlinks.json. Fix: Use your Strait link domain as endpoint (Dashboard → Get started); Strait serves this file there.",
      ]);
    });
  });
}
