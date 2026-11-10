@TestOn('vm')
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:strait_sdk/src/core.dart' show installReferrerField, installReferrerMax;
import 'package:strait_sdk/strait_sdk.dart';
import 'package:test/test.dart';

// B26 (engine ADR 0106, shared-spec ADR 0008): the once-per-install check sends the raw Play install referrer as
// `installReferrer` on the calls that record the install, so the install keeps its utm_* campaign even when the tap
// never went through a Strait link. 1..4096 characters, else left out; never on the record:false re-check, never off
// Android, nothing while switched off.

const device = DeviceFields(screenWidth: 411, pixelRatio: 2.625, language: 'en', timezone: 'Asia/Kolkata');
const ads = 'utm_source=google&utm_medium=cpc&utm_campaign=strait-qa&gclid=Cj0KCQ';
const strait = 'strait_link=lnk_1&strait_click=3f2a9c1e-7b4d-4e8a-9c0f-1a2b3c4d5e6f&utm_source=google-play';

class Engine {
  Engine([this.reply]);
  final http.Response Function(String path)? reply;
  final calls = <String>[];
  final bodies = <Map<String, dynamic>>[];
  late final http.Client client = MockClient((req) async {
    calls.add(req.url.path);
    bodies.add(req.body.isEmpty ? <String, dynamic>{} : jsonDecode(req.body) as Map<String, dynamic>);
    return reply?.call(req.url.path) ?? http.Response(jsonEncode({'matched': false}), 200);
  });
  Map<String, dynamic> of(String path) => bodies[calls.indexOf(path)];
}

StraitLinks make(Engine e, String? referrer, {String platform = 'android', KeyValueStore? storage}) => StraitLinks(
      publishableKey: 'st_pub_test_x',
      endpoint: 'https://acme.strait.link',
      platform: platform,
      deviceFields: () => device,
      storage: storage ?? MemoryStore(),
      installReferrer: () async => referrer,
      client: e.client,
      now: () => 1800000000000,
    );

Future<void> firstLaunch(StraitLinks links) async {
  await links.start();
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('installReferrerField: the raw string when 1..4096 characters, else null', () {
    expect(installReferrerMax, 4096);
    expect(installReferrerField(ads), ads);
    expect(installReferrerField('a' * 4096), 'a' * 4096);
    expect(installReferrerField('a' * 4097), isNull);
    expect(installReferrerField(''), isNull);
    expect(installReferrerField(null), isNull);
  });

  test('a Google Ads install (no strait_link): /v1/match carries the raw referrer', () async {
    final e = Engine();
    await firstLaunch(make(e, ads));
    expect(e.calls, ['/v1/match']);
    expect(e.of('/v1/match'), allOf(containsPair('installReferrer', ads), contains('openId')));
  });

  test('a Strait link install: /v1/referrer carries it; unmatched, the /v1/match fallback too', () async {
    final m = Engine((p) => http.Response(
        jsonEncode(p == '/v1/referrer' ? {'matched': true, 'longUrl': 'https://shop.example/p/1', 'linkId': 'lnk_1'} : {}), 200));
    await firstLaunch(make(m, strait));
    expect(m.of('/v1/referrer'), containsPair('installReferrer', strait));
    final u = Engine();
    await firstLaunch(make(u, strait));
    expect(u.calls, ['/v1/referrer', '/v1/match']);
    expect(u.of('/v1/match'), containsPair('installReferrer', strait));
  });

  test('over 4096 characters, empty or none: not sent', () async {
    for (final r in ['$ads&x=${'a' * 4096}', '', null]) {
      final e = Engine();
      await firstLaunch(make(e, r));
      expect(e.of('/v1/match'), isNot(contains('installReferrer')));
    }
  });

  test('iPhone: never sent', () async {
    final e = Engine();
    await firstLaunch(make(e, ads, platform: 'ios'));
    expect(e.of('/v1/match'), isNot(contains('installReferrer')));
  });

  test('checkDeferred() (record:false, no install): not sent', () async {
    final e = Engine();
    final links = make(e, ads, storage: MemoryStore()..data['strait.deferredChecked'] = '1');
    await links.start();
    await links.checkDeferred();
    expect(e.of('/v1/match'), allOf(containsPair('record', false), isNot(contains('installReferrer'))));
  });

  test('opted out: nothing is sent at all', () async {
    final e = Engine();
    final links = make(e, ads);
    await links.setEnabled(false);
    await firstLaunch(links);
    expect(e.calls, isEmpty);
  });

  test('legacy resolveDeferredLink: /v1/referrer and /v1/match carry it; opted out sends nothing', () async {
    final e = Engine();
    await resolveDeferredLink(
        publishableKey: 'st_pub_test_x', endpoint: 'https://acme.strait.link', platform: 'android',
        device: device, installReferrer: strait, client: e.client);
    expect(e.of('/v1/referrer'), containsPair('installReferrer', strait));
    expect(e.of('/v1/match'), containsPair('installReferrer', strait));
    final off = Engine();
    await resolveDeferredLink(
        publishableKey: 'st_pub_test_x', endpoint: 'https://acme.strait.link', platform: 'android',
        device: device, installReferrer: ads, client: off.client, storage: MemoryStore()..data['strait.enabled'] = '0');
    expect(off.calls, isEmpty);
  });
}
