@TestOn('browser')
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:strait_sdk/strait_sdk.dart';
import 'package:test/test.dart';

// Flutter web (dart2js and dart2wasm): there is no install on the web, so the
// once-per-install deferred check never runs and an open never counts as a
// first launch (the engine would record a website visit as an install). Links
// in the page URL still open, are reported and attribute events.
// Run: dart test -p chrome  (and -c dart2wasm)

const device = DeviceFields(screenWidth: 390, pixelRatio: 3, language: 'en', timezone: 'Asia/Kolkata');

({StraitLinks strait, List<(String, Map<String, dynamic>?)> calls, MemoryStore store}) make() {
  final calls = <(String, Map<String, dynamic>?)>[];
  final client = MockClient((req) async {
    calls.add((req.url.path, req.body.isEmpty ? null : jsonDecode(req.body) as Map<String, dynamic>));
    return http.Response(jsonEncode({'ok': true, 'matched': false}), 200);
  });
  final store = MemoryStore();
  final strait = StraitLinks(
    publishableKey: 'st_pub_test_web',
    endpoint: 'https://acme.strait.link',
    platform: 'other',
    deviceFields: () => device,
    storage: store,
    client: client,
  );
  return (strait: strait, calls: calls, store: store);
}

void main() {
  test('first visit: no deferred check, nothing recorded as an install', () async {
    final h = make();
    final events = <LinkEvent>[];
    h.strait.onLink.listen(events.add);
    await h.strait.start();
    await Future<void>.delayed(Duration.zero);
    expect(h.calls.map((c) => c.$1), isNot(contains('/v1/match')));
    expect(h.calls.map((c) => c.$1), isNot(contains('/v1/referrer')));
    expect(events, isEmpty);
  });

  test('a link in the page URL opens and is reported, never as a first launch', () async {
    final h = make();
    final events = <LinkEvent>[];
    h.strait.onLink.listen(events.add);
    await h.strait.start(initialUrl: 'https://shop.example.com/p/42?color=red&strait_click=3f2a9c1e-7b4d-4e8a-9c0f-1a2b3c4d5e6f');
    await h.strait.flushOpenReports();
    expect(events.single.matched, isTrue);
    expect(events.single.path, '/p/42');
    final opens = h.calls.where((c) => c.$1 == '/v1/open').toList();
    expect(opens, isNotEmpty);
    expect(opens.first.$2!['firstLaunch'], isFalse);
    expect(opens.first.$2!['clickId'], '3f2a9c1e-7b4d-4e8a-9c0f-1a2b3c4d5e6f');
  });
}
