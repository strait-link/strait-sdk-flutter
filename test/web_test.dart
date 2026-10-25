@TestOn('browser')
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:strait_sdk/strait_sdk.dart';
import 'package:test/test.dart';

// Flutter web (dart2js and dart2wasm): there is no install on the web, so the
// once-per-install deferred check never runs and an open never counts as a
// first launch (the engine would record a website visit as an install). A
// page URL is reported as a web open only when it carries a Strait tap id
// (`strait_click`, appended by the engine when it sends a tap to the web), with
// openId `web-<tap id>` so a reload is de-duplicated. Any other URL still
// reaches onLink for routing but is never reported (it is a page view).
// Run: dart test -p chrome  (and -c dart2wasm)

const device = DeviceFields(
    screenWidth: 390, pixelRatio: 3, language: 'en', timezone: 'Asia/Kolkata');

({
  StraitLinks strait,
  List<(String, Map<String, dynamic>?)> calls,
  MemoryStore store
}) make() {
  final calls = <(String, Map<String, dynamic>?)>[];
  final client = MockClient((req) async {
    calls.add((
      req.url.path,
      req.body.isEmpty ? null : jsonDecode(req.body) as Map<String, dynamic>
    ));
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

/// Let unawaited open reports reach the mock client.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  test('first visit: no deferred check, nothing recorded as an install',
      () async {
    final h = make();
    final events = <LinkEvent>[];
    h.strait.onLink.listen(events.add);
    await h.strait.start();
    await Future<void>.delayed(Duration.zero);
    expect(h.calls.map((c) => c.$1), isNot(contains('/v1/match')));
    expect(h.calls.map((c) => c.$1), isNot(contains('/v1/referrer')));
    expect(events, isEmpty);
  });

  const tap = '3f2a9c1e-7b4d-4e8a-9c0f-1a2b3c4d5e6f';

  test(
      'a landing from a Strait tap is reported once as a web open joined to the tap',
      () async {
    final h = make();
    final events = <LinkEvent>[];
    h.strait.onLink.listen(events.add);
    await h.strait.start(
        initialUrl:
            'https://shop.example.com/p/42?color=red&strait_click=${tap.toUpperCase()}');
    await h.strait.flushOpenReports();
    await settle();
    expect(events.single.matched, isTrue);
    expect(events.single.path, '/p/42');
    expect(events.single.params, {'color': 'red'});
    final opens = h.calls.where((c) => c.$1 == '/v1/open').toList();
    expect(opens, hasLength(1));
    expect(opens.single.$2, {
      'publishableKey': 'st_pub_test_web',
      'openId': 'web-$tap',
      'kind': 'direct',
      'route': 'app_link',
      'appState': 'closed',
      'platform': 'web',
      'url': 'https://shop.example.com/p/42',
      'clickId': tap,
      'matched': true,
      'firstLaunch': false,
      'at': opens.single.$2!['at'],
    });
    expect('web-$tap'.length, 40);
    // Events after the landing are attributed to the tap, like app opens.
    await h.strait.trackEvent('purchase');
    expect(h.calls.lastWhere((c) => c.$1 == '/v1/event').$2!['clickId'], tap);
  });

  test(
      'a reload of the landing sends the same openId (the engine de-duplicates it)',
      () async {
    const landing = 'https://shop.example.com/p/42?strait_click=$tap';
    final first = make();
    await first.strait.start(initialUrl: landing);
    await first.strait.flushOpenReports();
    await settle();
    final reload = make();
    await reload.strait.start(initialUrl: landing);
    await reload.strait.flushOpenReports();
    await settle();
    final ids = [
      first,
      reload
    ].map((h) => h.calls.singleWhere((c) => c.$1 == '/v1/open').$2!['openId']);
    expect(ids, ['web-$tap', 'web-$tap']);
  });

  test('a page URL without a Strait tap id is routed but never reported',
      () async {
    for (final url in [
      'https://shop.example.com/',
      'https://shop.example.com/p/42?color=red',
      'https://shop.example.com/p/42?strait_click=not-a-uuid',
    ]) {
      final h = make();
      final events = <LinkEvent>[];
      h.strait.onLink.listen(events.add);
      await h.strait.start(initialUrl: url);
      await h.strait.flushOpenReports();
      await settle();
      expect(events.single.matched, isTrue, reason: url);
      final paths = h.calls.map((c) => c.$1);
      expect(paths, isNot(contains('/v1/open')), reason: url);
      expect(paths, isNot(contains('/v1/resolve')), reason: url);
      expect(paths, isNot(contains('/v1/match')), reason: url);
      expect(await h.strait.pendingOpenReports(), 0, reason: url);
    }
  });

  test('later URLs follow the same rule', () async {
    final h = make();
    await h.strait.start();
    await h.strait.handleUrl('https://shop.example.com/p/7');
    await h.strait.handleUrl('https://shop.example.com/p/8?strait_click=$tap');
    await h.strait.flushOpenReports();
    await settle();
    final opens = h.calls.where((c) => c.$1 == '/v1/open').toList();
    expect(opens, hasLength(1));
    expect(opens.single.$2!['openId'], 'web-$tap');
    expect(opens.single.$2!['url'], 'https://shop.example.com/p/8');
  });

  test('a short link handed in on the web is looked up but not counted',
      () async {
    final h = make();
    final e = await h.strait.handleUrl('https://acme.strait.link/summer');
    await h.strait.flushOpenReports();
    await settle();
    expect(e.matched, isFalse);
    final resolve = h.calls.singleWhere((c) => c.$1 == '/v1/resolve').$2!;
    expect(resolve.containsKey('openId'), isFalse);
    expect(h.calls.map((c) => c.$1), isNot(contains('/v1/open')));
    expect(await h.strait.pendingOpenReports(), 0);
  });
}
