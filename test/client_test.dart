import 'dart:async';
import 'dart:convert';

import 'package:strait_sdk/strait_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const pk = 'st_pub_test_appowner01';
const endpoint = 'https://links.test';
const device = DeviceFields(
    screenWidth: 411, pixelRatio: 2.625, language: 'en', timezone: 'Asia/Kolkata');

class Call {
  final String method;
  final String path;
  final Map<String, dynamic>? body;
  Call(this.method, this.path, this.body);
}

/// Fake engine: routes by path, records every call. Unknown path → 404.
class FakeEngine {
  final Map<String, Object> routes;
  final calls = <Call>[];
  FakeEngine(this.routes);

  late final http.Client client = MockClient((req) async {
    calls.add(Call(req.method, req.url.path,
        req.body.isEmpty ? null : jsonDecode(req.body) as Map<String, dynamic>));
    final payload = routes[req.url.path];
    return payload == null
        ? http.Response('', 404)
        : http.Response(jsonEncode(payload), 200);
  });

  Call? find(String path, [String method = 'POST']) {
    for (final c in calls) {
      if (c.path == path && c.method == method) return c;
    }
    return null;
  }
}

/// Controllable phone: URL stream, lifecycle stream, clock (sync delivery,
/// like the platform channel callbacks).
class FakePhone {
  int t = 1000000;
  final urls = StreamController<String>(sync: true);
  final states = StreamController<AppLifecycle>(sync: true);
  void tap(String u) => urls.add(u);
  void setState(AppLifecycle s) => states.add(s);
  void advance(int ms) => t += ms;
}

class Harness {
  final FakePhone phone;
  final FakeEngine engine;
  final StraitLinks strait;
  final events = <LinkEvent>[];
  Harness(this.phone, this.engine, this.strait) {
    strait.onLink.listen(events.add);
  }

  Future<void> start({String? initialUrl}) => strait.start(
      initialUrl: initialUrl, urls: phone.urls.stream, lifecycle: phone.states.stream);
}

Harness make(FakeEngine engine,
    {String? referrer, KeyValueStore? storage, String platform = 'android', FakePhone? phone}) {
  final p = phone ?? FakePhone();
  return Harness(
    p,
    engine,
    StraitLinks(
      publishableKey: pk,
      endpoint: endpoint,
      platform: platform,
      deviceFields: () => device,
      storage: storage ?? MemoryStore(),
      installReferrer: () async => referrer,
      client: engine.client,
      now: () => p.t,
    ),
  );
}

Future<void> flush() => Future<void>.delayed(Duration.zero);

const resolved = {
  '/v1/resolve': {
    'matched': true,
    'longUrl': 'https://shop.example/p/42?color=red',
    'linkId': 'lnk_42',
    'slug': 'sale'
  }
};

void main() {
  group('direct links', () {
    test('app closed: a verified link resolves the short URL (B1, B3)', () async {
      final h = make(FakeEngine(resolved));
      await h.start(initialUrl: 'https://links.test/sale');
      await flush();
      expect(h.events, hasLength(1));
      final e = h.events.single;
      expect(e.kind, LinkKind.direct);
      expect(e.route, LinkRoute.appLink);
      expect(e.appState, AppStateAtLink.closed);
      expect(e.matched, isTrue);
      expect(e.rawUrl, 'https://links.test/sale');
      expect(e.url, 'https://shop.example/p/42?color=red');
      expect(e.path, '/p/42');
      expect(e.params, {'color': 'red'});
      expect(e.linkId, 'lnk_42');
      final body = h.engine.find('/v1/resolve')!.body!;
      expect(body['publishableKey'], pk);
      expect(body['url'], 'https://links.test/sale');
      expect(body['platform'], 'android');
      expect(body.containsKey('appId'), isFalse);
    });

    test('app in background: classified as background', () async {
      final h = make(FakeEngine(resolved));
      await h.start();
      h.phone.setState(AppLifecycle.background);
      h.phone.advance(60000);
      h.phone.setState(AppLifecycle.active);
      h.phone.advance(300);
      h.phone.tap('https://links.test/sale');
      await flush();
      await flush();
      expect(h.events.last.kind, LinkKind.direct);
      expect(h.events.last.appState, AppStateAtLink.background);
      expect(h.events.last.matched, isTrue);
    });

    test('link delivered before the app reports active (real Android order)', () async {
      final h = make(FakeEngine(resolved));
      await h.start();
      h.phone.setState(AppLifecycle.background);
      h.phone.advance(60000);
      h.phone.tap('https://links.test/sale');
      h.phone.setState(AppLifecycle.active);
      await flush();
      await flush();
      expect(h.events.last.appState, AppStateAtLink.background);
    });

    test('app on screen: the brief delivery pause is not "background"', () async {
      final h = make(FakeEngine(resolved));
      await h.start();
      h.phone.advance(30000);
      h.phone.setState(AppLifecycle.background);
      h.phone.advance(40);
      h.phone.tap('https://links.test/sale');
      h.phone.advance(30);
      h.phone.setState(AppLifecycle.active);
      await flush();
      await flush();
      expect(h.events.last.appState, AppStateAtLink.foreground);
    });

    test('app on screen: classified as foreground', () async {
      final h = make(FakeEngine(resolved));
      await h.start();
      h.phone.advance(30000);
      h.phone.tap('https://links.test/sale');
      await flush();
      await flush();
      expect(h.events.last.appState, AppStateAtLink.foreground);
    });

    test('custom scheme hand-off carries the destination, no network call (B4)', () async {
      final h = make(FakeEngine({}));
      await h.start(initialUrl: 'straitlink://shop.example/p/42?color=red');
      await flush();
      final e = h.events.first;
      expect(e.route, LinkRoute.customScheme);
      expect(e.appState, AppStateAtLink.closed);
      expect(e.matched, isTrue);
      expect(e.url, 'https://shop.example/p/42?color=red');
      expect(e.path, '/p/42');
      expect(e.params, {'color': 'red'});
      expect(h.engine.calls.where((c) => c.path == '/v1/resolve'), isEmpty);
    });

    test('an expired short link is reported with the engine reason', () async {
      final h = make(FakeEngine({
        '/v1/resolve': {'matched': false, 'reason': 'expired'}
      }));
      await h.start(initialUrl: 'https://links.test/old');
      await flush();
      expect(h.events.first.route, LinkRoute.appLink);
      expect(h.events.first.matched, isFalse);
      expect(h.events.first.reason, 'expired');
    });

    test('network failure → matched:false reason network, never throws (B10)', () async {
      final p = FakePhone();
      final strait = StraitLinks(
        publishableKey: pk,
        endpoint: endpoint,
        platform: 'ios',
        deviceFields: () => device,
        client: MockClient((_) async => throw Exception('offline')),
        now: () => p.t,
      );
      final e = await strait.handleUrl('https://links.test/sale');
      expect(e.matched, isFalse);
      expect(e.reason, 'network');
      final d = await strait.checkDeferred();
      expect(d.matched, isFalse);
      expect(d.reason, 'network');
      expect(await strait.trackEvent('x'), isFalse);
      expect(await strait.reportFingerprint(), isNull);
    });

    test('late subscribers still receive events that already happened', () async {
      final p = FakePhone();
      final strait = StraitLinks(
        publishableKey: pk,
        endpoint: endpoint,
        platform: 'android',
        deviceFields: () => device,
        client: FakeEngine({}).client,
        now: () => p.t,
      );
      await strait.start(initialUrl: 'straitlink://shop.example/cart');
      final late = <LinkEvent>[];
      strait.onLink.listen(late.add);
      await flush();
      expect(late, hasLength(1));
      expect(late.first.path, '/cart');
    });

    test('onLinkStart fires before the event, with the same id (B9)', () async {
      final h = make(FakeEngine(resolved));
      final order = <String>[];
      h.strait.onLinkStart.listen((s) => order.add('start:${s.id}:${s.rawUrl}'));
      h.strait.onLink.listen((e) => order.add('event:${e.id}'));
      await h.start(initialUrl: 'https://links.test/sale');
      await flush();
      final id = h.events.single.id;
      expect(order, ['start:$id:https://links.test/sale', 'event:$id']);
    });

    test('launch link echoed on the URL stream is handled once', () async {
      final h = make(FakeEngine({}));
      final start = h.start(initialUrl: 'straitlink://shop.example/cart');
      h.phone.tap('straitlink://shop.example/cart');
      await start;
      await flush();
      expect(h.events.where((e) => e.kind == LinkKind.direct), hasLength(1));
    });
  });

  group('deferred links (installed after tapping)', () {
    const referrerHit = {
      '/v1/referrer': {
        'matched': true,
        'longUrl': 'https://shop.example/promo/DIWALI20',
        'linkId': 'lnk_7',
        'matchMethod': 'install_referrer'
      }
    };

    test('first launch: Play install referrer → the tapped link (B7)', () async {
      final h = make(FakeEngine(referrerHit), referrer: 'utm_source=google-play&strait_link=lnk_7');
      await h.start();
      await flush();
      final e = h.events.first;
      expect(e.kind, LinkKind.deferred);
      expect(e.route, LinkRoute.installReferrer);
      expect(e.appState, AppStateAtLink.closed);
      expect(e.matched, isTrue);
      expect(e.url, 'https://shop.example/promo/DIWALI20');
      expect(e.path, '/promo/DIWALI20');
      expect(e.linkId, 'lnk_7');
      final body = h.engine.find('/v1/referrer')!.body!;
      expect(body['publishableKey'], pk);
      expect(body['linkId'], 'lnk_7');
    });

    test('runs only once per install (B6)', () async {
      final storage = MemoryStore();
      await make(FakeEngine(referrerHit), referrer: 'strait_link=lnk_7', storage: storage).start();
      final second = make(FakeEngine(referrerHit), referrer: 'strait_link=lnk_7', storage: storage);
      await second.start();
      await flush();
      expect(second.events.where((e) => e.kind == LinkKind.deferred), isEmpty);
      expect(second.engine.calls, isEmpty);
    });

    test('no referrer link → fingerprint match, not matched when nothing found', () async {
      final h = make(FakeEngine({
        '/v1/match': {'matched': false, 'matchMethod': 'none'}
      }), referrer: 'utm_source=google-play&utm_medium=organic');
      await h.start();
      await flush();
      expect(h.events.first.kind, LinkKind.deferred);
      expect(h.events.first.route, LinkRoute.fingerprint);
      expect(h.events.first.matched, isFalse);
      final body = h.engine.find('/v1/match')!.body!;
      expect(body, {
        'publishableKey': pk,
        'platform': 'android',
        ...device.toJson(),
        'openId': h.events.first.id,
        'at': h.events.first.at,
      });
    });

    test('referrer lookup misses → falls back to /v1/match', () async {
      final h = make(FakeEngine({
        '/v1/referrer': {'matched': false},
        '/v1/match': {'matched': true, 'longUrl': 'https://shop.example/x', 'linkId': 'lnk_9'},
      }), referrer: 'strait_link=lnk_7');
      await h.start();
      await flush();
      expect(h.engine.calls.map((c) => c.path), ['/v1/referrer', '/v1/match']);
      expect(h.events.first.route, LinkRoute.fingerprint);
      expect(h.events.first.matched, isTrue);
      expect(h.events.first.linkId, 'lnk_9');
    });

    test('iOS goes straight to /v1/match with device fields (B8)', () async {
      final h = make(FakeEngine({
        '/v1/match': {'matched': true, 'longUrl': 'https://shop.example/x?a=1'}
      }), platform: 'ios', referrer: 'strait_link=lnk_7');
      await h.start();
      await flush();
      expect(h.engine.calls.map((c) => c.path), ['/v1/match']);
      expect(h.engine.calls.first.body!['platform'], 'ios');
      expect(h.engine.calls.first.body!['screenWidth'], 411);
      expect(h.events.first.params, {'a': '1'});
    });

    test('first launch opened by a link skips the deferred check but marks it', () async {
      final storage = MemoryStore();
      final h = make(FakeEngine(referrerHit), referrer: 'strait_link=lnk_7', storage: storage);
      await h.start(initialUrl: 'straitlink://shop.example/cart');
      await flush();
      expect(h.events.map((e) => e.kind), [LinkKind.direct]);
      expect(await storage.get('strait.deferredChecked'), '1');
    });
  });

  group('fingerprint check + events (B13)', () {
    test('reports the app side and reads the comparison', () async {
      final h = make(FakeEngine({
        '/v1/debug/fingerprint': {'extHash': 'abc', 'coreHash': 'def', 'inputs': {}}
      }));
      final report = await h.strait.reportFingerprint();
      expect(report!['extHash'], 'abc');
      expect(h.engine.find('/v1/debug/fingerprint')!.body,
          {'publishableKey': pk, 'origin': 'app', ...device.toJson()});
      final cmp = await h.strait.compareFingerprint();
      expect(cmp!['coreHash'], 'def');
      expect(h.engine.find('/v1/debug/fingerprint', 'GET'), isNotNull);
    });

    test('trackEvent sends the publishable key', () async {
      final h = make(FakeEngine({
        '/v1/event': {'ok': true}
      }));
      expect(await h.strait.trackEvent('purchase', value: 49.99, currency: 'USD', linkId: 'lnk_42'),
          isTrue);
      expect(h.engine.calls.last.body, {
        'publishableKey': pk,
        'event': 'purchase',
        'platform': 'android',
        'value': 49.99,
        'currency': 'USD',
        'linkId': 'lnk_42',
      });
    });
  });

  group('conversion events carry the tap id (B15/B16)', () {
    const tap = '3f2a9c1e-7b4d-4e8a-9c0f-1a2b3c4d5e6f';
    const other = '11111111-2222-4333-8444-555555555555';
    const day = 24 * 60 * 60 * 1000;
    Map<String, dynamic>? eventBody(FakeEngine e) =>
        e.calls.where((c) => c.path == '/v1/event').lastOrNull?.body;

    test('a browser hand-off tap is remembered and attached to a purchase', () async {
      final store = MemoryStore();
      final h = make(FakeEngine({'/v1/event': {'ok': true}, '/v1/open': {'ok': true}}), storage: store);
      await h.start(initialUrl: 'straitlink://shop.example/p/42?strait_click=$tap');
      h.phone.advance(day);
      await h.strait.trackEvent('purchase', value: 5, currency: 'USD');
      expect(eventBody(h.engine)!['clickId'], tap);
      expect(jsonDecode(store.data['strait.lastTap']!), {'clickId': tap, 'at': 1000000});
    });

    test('not after 7 days', () async {
      final h = make(FakeEngine({'/v1/event': {'ok': true}, '/v1/open': {'ok': true}}));
      await h.start(initialUrl: 'straitlink://shop.example/p/42?strait_click=$tap');
      h.phone.advance(7 * day + 1);
      await h.strait.trackEvent('purchase');
      expect(eventBody(h.engine)!.containsKey('clickId'), isFalse);
    });

    test('an explicit clickId overrides the remembered tap', () async {
      final h = make(FakeEngine({'/v1/event': {'ok': true}, '/v1/open': {'ok': true}}));
      await h.start(initialUrl: 'straitlink://shop.example/p/42?strait_click=$tap');
      await h.strait.trackEvent('purchase', clickId: other);
      expect(eventBody(h.engine)!['clickId'], other);
    });

    test('no remembered tap: no clickId', () async {
      final h = make(FakeEngine({'/v1/event': {'ok': true}, '/v1/match': {'matched': false}}));
      await h.start();
      await h.strait.trackEvent('signup');
      expect(eventBody(h.engine)!.containsKey('clickId'), isFalse);
    });

    test('the Play referrer tap is remembered on a deferred install', () async {
      final h = make(
          FakeEngine({
            '/v1/event': {'ok': true},
            '/v1/referrer': {'matched': true, 'longUrl': 'https://shop.example/p/7', 'linkId': 'lnk_7'}
          }),
          referrer: 'strait_link=lnk_7&strait_click=$tap');
      await h.start();
      await h.strait.trackEvent('purchase');
      expect(eventBody(h.engine)!['clickId'], tap);
    });

    test('a newer short-link open with no tap id in the reply (older engine) forgets the older tap', () async {
      final h = make(FakeEngine({...resolved, '/v1/event': {'ok': true}, '/v1/open': {'ok': true}}));
      await h.start(initialUrl: 'straitlink://shop.example/p/42?strait_click=$tap');
      await h.strait.handleUrl('https://links.test/sale');
      await h.strait.trackEvent('purchase');
      expect(eventBody(h.engine)!.containsKey('clickId'), isFalse);
    });

    test('B16: a short-link open remembers the tap id the engine returns, replacing the older tap', () async {
      final store = MemoryStore();
      final h = make(
          FakeEngine({
            '/v1/resolve': {...resolved['/v1/resolve']!, 'recorded': true, 'clickId': tap.toUpperCase()},
            '/v1/event': {'ok': true},
            '/v1/open': {'ok': true},
          }),
          storage: store);
      await h.start(initialUrl: 'straitlink://shop.example/p/42?strait_click=$other');
      h.phone.advance(1000);
      await h.strait.handleUrl('https://links.test/sale');
      await h.strait.trackEvent('purchase');
      expect(eventBody(h.engine)!['clickId'], tap);
      expect(jsonDecode(store.data['strait.lastTap']!), {'clickId': tap, 'at': 1001000});
    });

    test('B16: a fingerprint match remembers the tap id the engine returns', () async {
      final h = make(FakeEngine({
        '/v1/event': {'ok': true},
        '/v1/match': {'matched': true, 'longUrl': 'https://shop.example/p/9', 'linkId': 'lnk_9', 'clickId': tap},
      }));
      await h.start();
      await h.strait.trackEvent('purchase');
      expect(eventBody(h.engine)!['clickId'], tap);
    });

    test("B16: the referrer reply's tap id wins over the parsed one", () async {
      final h = make(
          FakeEngine({
            '/v1/event': {'ok': true},
            '/v1/referrer': {'matched': true, 'longUrl': 'https://shop.example/p/7', 'linkId': 'lnk_7', 'clickId': tap}
          }),
          referrer: 'strait_link=lnk_7&strait_click=$other');
      await h.start();
      await h.strait.trackEvent('purchase');
      expect(eventBody(h.engine)!['clickId'], tap);
    });

    test('B16: a malformed reply tap id counts as none (forgets)', () async {
      final h = make(FakeEngine({
        '/v1/resolve': {...resolved['/v1/resolve']!, 'clickId': 'nope'},
        '/v1/event': {'ok': true},
        '/v1/open': {'ok': true},
      }));
      await h.start(initialUrl: 'straitlink://shop.example/p/42?strait_click=$tap');
      await h.strait.handleUrl('https://links.test/sale');
      await h.strait.trackEvent('purchase');
      expect(eventBody(h.engine)!.containsKey('clickId'), isFalse);
    });

    test('unreadable storage never blocks the event', () async {
      final h = make(FakeEngine({'/v1/event': {'ok': true}, '/v1/open': {'ok': true}}),
          storage: _BrokenStore());
      await h.start(initialUrl: 'straitlink://x.example/?strait_click=$tap');
      expect(await h.strait.trackEvent('purchase'), isTrue);
      expect(eventBody(h.engine)!.containsKey('clickId'), isFalse);
    });
  });
}

class _BrokenStore implements KeyValueStore {
  @override
  Future<String?> get(String key) async => throw StateError('io');
  @override
  Future<void> set(String key, String value) async => throw StateError('io');
}
