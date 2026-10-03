import 'dart:async';
import 'dart:convert';

import 'package:strait_sdk/strait_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

// Contract B14: every link open is reported exactly once, retried until it
// gets through, and never delays navigation. Plus the B6/B7 revisions.
// Port of sdk-react-native/test/opens.test.ts.

const pk = 'st_pub_test_appowner01';
const endpoint = 'https://links.test';
const click = '3f2a9c1e-7b4d-4e8a-9c0f-1a2b3c4d5e6f';
final openIdRe = RegExp(r'^o_[a-z0-9]+_[a-z0-9]{12}$');
const device = DeviceFields(
    screenWidth: 411, pixelRatio: 2.625, language: 'en', timezone: 'Asia/Kolkata');

/// An engine answer: status + JSON body, or [offline] (no answer) / [hang].
class Reply {
  final int status;
  final Object? body;
  const Reply([this.status = 200, this.body]);
}

const offline = 'offline';
const hang = 'hang';

class Call {
  final String path;
  final Map<String, dynamic>? body;
  Call(this.path, this.body);
}

/// Fake engine whose answer per path can change mid-test. Unknown path → 404.
class FakeEngine {
  final Map<String, Object> routes;
  final calls = <Call>[];
  FakeEngine(this.routes);

  late final http.Client client = MockClient((req) async {
    calls.add(Call(req.url.path,
        req.body.isEmpty ? null : jsonDecode(req.body) as Map<String, dynamic>));
    final r = routes[req.url.path] ?? const Reply(404, {'error': 'not found'});
    if (r == offline) throw http.ClientException('Network request failed');
    if (r == hang) return Completer<http.Response>().future;
    r as Reply;
    return http.Response(jsonEncode(r.body ?? {}), r.status);
  });

  List<Call> of(String path) => calls.where((c) => c.path == path).toList();
}

/// Controllable phone: URL stream, lifecycle stream, clock.
class FakePhone {
  int t = 1800000000000;
  final String platform;
  final String? referrer;
  final urls = StreamController<String>(sync: true);
  final states = StreamController<AppLifecycle>(sync: true);
  FakePhone({this.platform = 'android', this.referrer});
  void tap(String u) => urls.add(u);
  void setState(AppLifecycle s) => states.add(s);
  void advance(int ms) => t += ms;
}

class Harness {
  final FakePhone phone;
  final StraitLinks strait;
  final MemoryStore storage;
  final events = <LinkEvent>[];
  Harness(this.phone, this.strait, this.storage) {
    strait.onLink.listen(events.add);
  }

  Future<void> start({String? initialUrl}) async {
    await strait.start(
        initialUrl: initialUrl, urls: phone.urls.stream, lifecycle: phone.states.stream);
    await Future<void>.delayed(Duration.zero); // deliver replayed events
  }
}

Harness make(FakePhone phone, FakeEngine engine, [MemoryStore? storage]) {
  final s = storage ?? MemoryStore();
  return Harness(
    phone,
    StraitLinks(
      publishableKey: pk,
      endpoint: endpoint,
      platform: phone.platform,
      deviceFields: () => device,
      storage: s,
      installReferrer: () async => phone.referrer,
      client: engine.client,
      now: () => phone.t,
    ),
    s,
  );
}

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const resolvedBody = {
  'matched': true,
  'longUrl': 'https://shop.example/p/42',
  'linkId': 'lnk_42',
  'slug': 'sale',
  'recorded': true,
};
const resolved = Reply(200, resolvedBody);
const accepted = Reply(202, {'ok': true, 'duplicate': false});
const noMatch = Reply(200, {'matched': false, 'matchMethod': 'none'});

/// Storage whose writes (and optionally reads) fail.
class BrokenStore implements KeyValueStore {
  final bool failGet;
  BrokenStore({this.failGet = false});
  @override
  Future<String?> get(String key) async => failGet ? throw StateError('io') : null;
  @override
  Future<void> set(String key, String value) async => throw StateError('full');
}

/// Not the first launch.
MemoryStore returning() => MemoryStore()..data['strait.deferredChecked'] = '1';

void main() {
  group('browser hand-off (custom scheme) with a tap id', () {
    test('reports the open with its tap id; the app never sees the tap id', () async {
      final phone = FakePhone();
      final engine = FakeEngine({'/v1/open': accepted});
      final h = make(phone, engine, returning());
      await h.start();
      phone.setState(AppLifecycle.background);
      phone.advance(5000);
      phone.setState(AppLifecycle.active);
      phone.advance(200);
      phone.tap('straitlink://shop.example/p/42?color=red&strait_click=$click');
      await settle();
      final e = h.events.last;
      expect(e.route, LinkRoute.customScheme);
      expect(e.url, 'https://shop.example/p/42?color=red');
      expect(e.params, {'color': 'red'});
      expect(e.appState, AppStateAtLink.background);
      expect(e.id, matches(openIdRe));
      expect(engine.of('/v1/open'), hasLength(1));
      expect(engine.of('/v1/open')[0].body, {
        'publishableKey': pk,
        'openId': e.id,
        'kind': 'direct',
        'route': 'custom_scheme',
        'appState': 'background',
        'platform': 'android',
        'url': 'https://shop.example/p/42?color=red',
        'clickId': click,
        'matched': true,
        'firstLaunch': false,
        'at': e.at,
      });
    });

    test('navigation never waits for the report', () async {
      final h = make(FakePhone(), FakeEngine({'/v1/open': hang}), returning());
      await h.start(initialUrl: 'straitlink://shop.example/p/1?strait_click=$click');
      expect(h.events, hasLength(1));
      expect(h.events[0].url, 'https://shop.example/p/1');
    });

    test("the customer's own https link is reported too (no tap id)", () async {
      final engine = FakeEngine({'/v1/open': accepted});
      await make(FakePhone(), engine, returning()).start(initialUrl: 'https://shop.example/p/9');
      await settle();
      final body = engine.of('/v1/open')[0].body!;
      expect(body['route'], 'app_link');
      expect(body['url'], 'https://shop.example/p/9');
      expect(body['appState'], 'closed');
      expect(body.containsKey('clickId'), isFalse);
    });
  });

  group('short link (verified App Link from WhatsApp/Gmail): the lookup is the report', () {
    test('sends openId + app state with /v1/resolve, and nothing else once recorded', () async {
      final engine = FakeEngine({'/v1/resolve': resolved, '/v1/open': accepted});
      final h = make(FakePhone(), engine, returning());
      await h.start(initialUrl: 'https://links.test/sale');
      await settle();
      final body = engine.of('/v1/resolve')[0].body!;
      expect(body['openId'], h.events[0].id);
      expect(body['appState'], 'closed');
      expect(body['firstLaunch'], false);
      expect(body['at'], h.events[0].at);
      expect(engine.of('/v1/open'), isEmpty);
    });

    test('engine answered but could not record → retried via /v1/open with the same openId',
        () async {
      final engine = FakeEngine({
        '/v1/resolve': Reply(200, {...resolvedBody}..['recorded'] = false),
        '/v1/open': accepted,
      });
      final h = make(FakePhone(), engine, returning());
      await h.start(initialUrl: 'https://links.test/sale');
      await settle();
      expect(h.events[0].matched, isTrue);
      final body = engine.of('/v1/open')[0].body!;
      expect(body['openId'], h.events[0].id);
      expect(body['route'], 'app_link');
      expect(body['url'], 'https://links.test/sale');
      expect(body['matched'], true);
      expect(body['linkId'], 'lnk_42');
    });

    test('offline: saved, then sent (same openId) when the app comes back with network',
        () async {
      final phone = FakePhone();
      final engine = FakeEngine({'/v1/resolve': offline, '/v1/open': offline});
      final h = make(phone, engine, returning());
      await h.start();
      phone.tap('https://links.test/sale');
      await settle();
      expect(h.events.last.matched, isFalse);
      expect(h.events.last.reason, 'network');
      expect(await h.strait.pendingOpenReports(), 1);
      // network returns; user leaves and comes back
      engine.routes['/v1/open'] = accepted;
      phone.setState(AppLifecycle.background);
      phone.advance(10000);
      phone.setState(AppLifecycle.active);
      await settle();
      final sent =
          engine.of('/v1/open').where((c) => c.body!['openId'] == h.events.last.id).toList();
      final body = sent.last.body!;
      expect(body['route'], 'app_link');
      expect(body['url'], 'https://links.test/sale');
      expect(body['matched'], false);
      expect(body['reason'], 'network');
      expect(await h.strait.pendingOpenReports(), 0);
    });
  });

  group('the retry queue', () {
    test('keeps reports on 5xx / 429, drops them on 4xx', () async {
      final phone = FakePhone();
      final engine = FakeEngine({'/v1/open': const Reply(503)});
      final h = make(phone, engine, returning());
      await h.start();
      phone.tap('straitlink://a.b/1');
      await settle();
      expect(await h.strait.pendingOpenReports(), 1);
      engine.routes['/v1/open'] = const Reply(429);
      await h.strait.flushOpenReports();
      expect(await h.strait.pendingOpenReports(), 1);
      engine.routes['/v1/open'] = const Reply(400, {'error': 'bad'});
      await h.strait.flushOpenReports();
      expect(await h.strait.pendingOpenReports(), 0);
    });

    test('survives an app restart (stored), and is sent on the next start', () async {
      final storage = returning();
      final phone1 = FakePhone();
      final first = make(phone1, FakeEngine({'/v1/open': offline}), storage);
      await first.start();
      phone1.tap('straitlink://a.b/1');
      phone1.tap('straitlink://a.b/2');
      await settle();
      expect(await first.strait.pendingOpenReports(), 2);
      first.strait.stop();

      final e2 = FakeEngine({'/v1/open': accepted});
      final second = make(FakePhone(), e2, storage);
      await second.start();
      await settle();
      expect(e2.of('/v1/open').map((c) => c.body!['url']), ['https://a.b/1', 'https://a.b/2']);
      expect(await second.strait.pendingOpenReports(), 0);
    });

    test('a successful report also sends anything saved earlier', () async {
      final phone = FakePhone();
      final engine = FakeEngine({'/v1/open': offline});
      final h = make(phone, engine, returning());
      await h.start();
      phone.tap('straitlink://a.b/old');
      await settle();
      engine.routes['/v1/open'] = accepted;
      phone.tap('straitlink://a.b/new');
      await settle();
      expect(await h.strait.pendingOpenReports(), 0);
      expect(
          engine
              .of('/v1/open')
              .where((c) => c.body!['url'] == 'https://a.b/old')
              .map((c) => c.body!['openId'])
              .toSet(),
          hasLength(1));
    });

    test('every open has its own id', () async {
      final phone = FakePhone();
      final h = make(phone, FakeEngine({'/v1/open': accepted}), returning());
      await h.start();
      for (var i = 0; i < 5; i++) {
        phone.tap('straitlink://a.b/$i');
      }
      await settle();
      expect(h.events.map((e) => e.id).toSet(), hasLength(5));
    });
  });

  group('first launch and the deferred check (B6/B7 revised)', () {
    test('first launch opened by a link: no deferred check, and the open counts as the install',
        () async {
      final engine = FakeEngine({'/v1/resolve': resolved});
      final h = make(FakePhone(), engine);
      await h.start(initialUrl: 'https://links.test/sale');
      expect(engine.of('/v1/resolve')[0].body!['firstLaunch'], true);
      expect(engine.of('/v1/referrer'), isEmpty);
      expect(engine.of('/v1/match'), isEmpty);
      expect(h.storage.data['strait.deferredChecked'], '1');
    });

    test('Play referrer: sends the tap id and the openId', () async {
      final engine = FakeEngine({
        '/v1/referrer': const Reply(200, {
          'matched': true,
          'longUrl': 'https://shop.example/p/42',
          'linkId': 'lnk_42',
          'matchMethod': 'install_referrer',
        })
      });
      final h = make(
          FakePhone(referrer: 'utm_source=google-play&strait_link=lnk_42&strait_click=$click'),
          engine);
      await h.start();
      expect(engine.of('/v1/referrer')[0].body, {
        'publishableKey': pk,
        'linkId': 'lnk_42',
        'clickId': click,
        'platform': 'android',
        'openId': h.events[0].id,
        'at': h.events[0].at,
      });
      expect(h.events[0].kind, LinkKind.deferred);
      expect(h.events[0].route, LinkRoute.installReferrer);
      expect(h.events[0].matched, isTrue);
    });

    test('fingerprint (iOS): sends the openId', () async {
      final engine = FakeEngine({'/v1/match': noMatch});
      final h = make(FakePhone(platform: 'ios'), engine);
      await h.start();
      expect(engine.of('/v1/match')[0].body, {
        'publishableKey': pk,
        'platform': 'ios',
        ...device.toJson(),
        'openId': h.events[0].id,
        'at': h.events[0].at,
      });
    });

    test('offline: not marked done, so the next launch checks again', () async {
      final storage = MemoryStore();
      final first = make(FakePhone(), FakeEngine({'/v1/match': offline}), storage);
      await first.start();
      expect(first.events[0].kind, LinkKind.deferred);
      expect(first.events[0].reason, 'network');
      expect(storage.data['strait.deferredChecked'], isNull);

      final e2 = FakeEngine({'/v1/match': noMatch});
      await make(FakePhone(), e2, storage).start();
      expect(e2.of('/v1/match'), hasLength(1));
      expect(storage.data['strait.deferredChecked'], '1');

      final e3 = FakeEngine({'/v1/match': noMatch});
      await make(FakePhone(), e3, storage).start();
      expect(e3.of('/v1/match'), isEmpty); // once per install
    });

    test('server error (5xx) counts as not answered', () async {
      final storage = MemoryStore();
      final h = make(FakePhone(), FakeEngine({'/v1/match': const Reply(502)}), storage);
      await h.start();
      expect(h.events[0].reason, 'network');
      expect(storage.data['strait.deferredChecked'], isNull);
    });

    test('the debug re-check never records an install (no openId)', () async {
      final engine = FakeEngine({'/v1/match': noMatch});
      final h = make(FakePhone(), engine, returning());
      await h.start();
      await h.strait.checkDeferred();
      expect(engine.of('/v1/match'), hasLength(1));
      expect(engine.of('/v1/match')[0].body!.containsKey('openId'), isFalse);
      expect(engine.of('/v1/match')[0].body!.containsKey('at'), isFalse);
    });

    test('unreadable storage = already checked (no deferred jump); write failures never throw',
        () async {
      StraitLinks strait(FakeEngine engine, KeyValueStore store) => StraitLinks(
            publishableKey: pk,
            endpoint: endpoint,
            platform: 'android',
            deviceFields: () => device,
            storage: store,
            client: engine.client,
            now: () => 1800000000000,
          );
      final engine = FakeEngine({'/v1/match': noMatch, '/v1/resolve': resolved});
      await strait(engine, BrokenStore(failGet: true)).start();
      expect(engine.of('/v1/match'), isEmpty);
      final e2 = FakeEngine({'/v1/match': noMatch});
      await expectLater(strait(e2, BrokenStore()).start(), completes);
      final e3 = FakeEngine({'/v1/resolve': resolved});
      await expectLater(
          strait(e3, BrokenStore()).start(initialUrl: 'https://links.test/sale'), completes);
    });
  });

  test('newOpenId: o_<base36 ms>_<12 × [a-z0-9]>', () {
    expect(newOpenId(1800000000000), matches(openIdRe));
    expect(newOpenId(1800000000000, () => 0), 'o_${1800000000000.toRadixString(36)}_aaaaaaaaaaaa');
    expect(newOpenId(35, () => 0.999), 'o_z_999999999999');
  });
}
