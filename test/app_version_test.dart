@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:strait_sdk/strait_sdk.dart';
import 'package:test/test.dart';

// td2-23: every call that records an app open or install carries the host app's version and this
// SDK's version (support's first question: "which app version?"). Not /v1/lookup (records nothing,
// the opt-out path) and not /v1/event. Engine rule: 1-64 printable ASCII, anything else dropped.

const device = DeviceFields(screenWidth: 411, pixelRatio: 2.625, language: 'en', timezone: 'Asia/Kolkata');
const token = 'AbCdEfGhIjKlMnOpQrStUv';

class Engine {
  Engine([this.reply]);
  final http.Response Function(String path)? reply;
  bool offline = false;
  final calls = <String>[];
  final bodies = <Map<String, dynamic>>[];
  late final http.Client client = MockClient((req) async {
    if (offline) throw http.ClientException('offline');
    calls.add(req.url.path);
    bodies.add(req.body.isEmpty ? <String, dynamic>{} : jsonDecode(req.body) as Map<String, dynamic>);
    return reply?.call(req.url.path) ?? http.Response(jsonEncode({'matched': false}), 202);
  });

  List<Map<String, dynamic>> of(String path) => [
        for (var i = 0; i < calls.length; i++)
          if (calls[i] == path) bodies[i],
      ];
}

StraitLinks make(Engine e,
        {String platform = 'android', String? appVersion = '4.12.0 (812)', KeyValueStore? storage, String? referrer}) =>
    StraitLinks(
      publishableKey: 'st_pub_test_x',
      endpoint: 'https://acme.strait.link',
      platform: platform,
      deviceFields: () => device,
      storage: storage ?? (MemoryStore()..data['strait.deferredChecked'] = '1'),
      installReferrer: () async => referrer,
      client: e.client,
      now: () => 1800000000000,
      appVersion: appVersion,
    );

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Matcher carriesVersions() =>
    allOf(containsPair('appVersion', '4.12.0 (812)'), containsPair('sdkVersion', straitSdkVersion));
Matcher noVersions() => isNot(anyOf(contains('appVersion'), contains('sdkVersion')));

void main() {
  test('sdkVersion equals the pubspec.yaml version', () {
    final v =
        RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1);
    expect(straitSdkVersion, v);
  });

  group('recording calls carry appVersion + sdkVersion', () {
    test('/v1/resolve (short link) and its /v1/open retry', () async {
      final e = Engine(
          (p) => http.Response(jsonEncode({'matched': true, 'longUrl': 'https://acme.com/x', 'recorded': false}), 200));
      final links = make(e);
      await links.handleUrl('https://acme.strait.link/promo');
      await settle();
      expect(e.of('/v1/resolve').single, carriesVersions());
      expect(e.of('/v1/open').single, carriesVersions());
    });

    test('/v1/open for a link that carries its own destination', () async {
      final e = Engine();
      await make(e).handleUrl('acme://product/42');
      await settle();
      expect(e.of('/v1/open').single, carriesVersions());
    });

    test('an open saved offline is sent later with both fields, and saved without them', () async {
      final e = Engine()..offline = true;
      final s = MemoryStore()..data['strait.deferredChecked'] = '1';
      final links = make(e, storage: s);
      await links.handleUrl('acme://product/42');
      await settle();
      expect(await links.pendingOpenReports(), 1);
      expect(s.data['strait.pendingOpens'], allOf(isNot(contains('appVersion')), isNot(contains('sdkVersion'))));
      e.offline = false;
      await links.flushOpenReports();
      expect(e.of('/v1/open').single, carriesVersions());
    });

    test('/v1/referrer and /v1/match on the first-launch check', () async {
      final e = Engine();
      final links = make(e, storage: MemoryStore(), referrer: 'utm_source=google-play&strait_link=lnk_42');
      await links.start();
      await settle();
      expect(e.of('/v1/referrer').single, carriesVersions());
      expect(e.of('/v1/match').single, carriesVersions());
    });

    test('legacy resolveDeferredLink: /v1/referrer and /v1/match', () async {
      final e = Engine();
      await resolveDeferredLink(
        publishableKey: 'st_pub_test_x',
        endpoint: 'https://acme.strait.link',
        platform: 'android',
        device: device,
        installReferrer: 'strait_link=lnk_42',
        client: e.client,
        appVersion: '4.12.0 (812)',
      );
      expect(e.of('/v1/referrer').single, carriesVersions());
      expect(e.of('/v1/match').single, carriesVersions());
    });

    test('/v1/handoff/claim (paste button)', () async {
      final e = Engine((p) => http.Response(jsonEncode({'matched': true, 'longUrl': 'https://acme.com/x'}), 200));
      await make(e, platform: 'ios').claimHandoff('https://acme.strait.link/h/$token');
      expect(e.of('/v1/handoff/claim').single, carriesVersions());
    });
  });

  group('never sent', () {
    test('on /v1/event', () async {
      final e = Engine((p) => http.Response('{}', 202));
      expect(await make(e).trackEvent('purchase', value: 5), isTrue);
      expect(e.of('/v1/event').single, noVersions());
    });

    test('while opted out: only /v1/lookup goes out, without them', () async {
      final e = Engine((p) => http.Response(jsonEncode({'matched': true, 'longUrl': 'https://acme.com/x'}), 200));
      final links = make(e, storage: MemoryStore());
      await links.setEnabled(false);
      await links.start(initialUrl: 'https://acme.strait.link/promo');
      await links.handleUrl('acme://product/42');
      await links.trackEvent('purchase');
      await links.claimHandoff('https://acme.strait.link/h/$token');
      await settle();
      expect(e.calls, ['/v1/lookup']);
      expect(e.bodies.single, noVersions());
    });
  });

  group('appVersion is cleaned on the device (engine: 1-64 printable ASCII)', () {
    Future<Map<String, dynamic>> sent(String? appVersion) async {
      final e = Engine();
      await make(e, appVersion: appVersion).handleUrl('acme://product/42');
      await settle();
      return e.of('/v1/open').single;
    }

    test('trimmed', () async {
      expect(await sent('  4.12.0 (812)\n'), containsPair('appVersion', '4.12.0 (812)'));
    });

    test('capped at 64 characters', () async {
      expect((await sent('1.${'0' * 100}'))['appVersion'], '1.${'0' * 62}');
    });

    test('left out when empty, missing or not printable ASCII; sdkVersion still sent', () async {
      for (final v in [null, '', '   ', '4.1é', '4.1\u0000']) {
        final body = await sent(v);
        expect(body, isNot(contains('appVersion')), reason: '$v');
        expect(body, containsPair('sdkVersion', straitSdkVersion));
      }
    });
  });
}
