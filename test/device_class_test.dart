import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:strait_sdk/strait_sdk.dart';
import 'package:test/test.dart';

// Contract B14 deviceClass (engine ADR 0039): sent with /v1/resolve, /v1/open
// and /v1/store-sheet when the app supplies 'phone' or 'tablet'.

const device = DeviceFields(screenWidth: 411, pixelRatio: 2.625, language: 'en', timezone: 'Asia/Kolkata');

class Engine {
  final Map<String, Object> routes; // path -> JSON body, or 'offline'
  final calls = <(String, Map<String, dynamic>)>[];
  Engine(this.routes);
  late final http.Client client = MockClient((req) async {
    calls.add((req.url.path, req.body.isEmpty ? <String, dynamic>{} : jsonDecode(req.body) as Map<String, dynamic>));
    final r = routes[req.url.path];
    if (r == null) return http.Response('{}', 404);
    if (r == 'offline') throw http.ClientException('offline');
    return http.Response(jsonEncode(r), req.url.path == '/v1/open' ? 202 : 200);
  });
  List<Map<String, dynamic>> of(String path) => [for (final c in calls) if (c.$1 == path) c.$2];
}

class NoOpener extends StoreSheetOpener {
  @override
  Future<bool> androidIntent(StoreIntent intent) async => true;
  @override
  Future<bool> iosProduct(StoreProduct product, StoreSheetStyle style) async => true;
}

StraitLinks links(Engine e, String? Function()? deviceClass, {MemoryStore? storage}) => StraitLinks(
      publishableKey: 'st_pub_test_appowner01',
      endpoint: 'https://links.test',
      platform: 'android',
      deviceFields: () => device,
      storage: storage ?? (MemoryStore()..data['strait.deferredChecked'] = '1'),
      client: e.client,
      now: () => 1800000000000,
      deviceClass: deviceClass,
    );

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const resolved = {'matched': true, 'longUrl': 'https://shop.example/p/42', 'linkId': 'lnk_42', 'recorded': true};

void main() {
  test('Flutter glue: deviceClassForSize of the shorter side in logical px', () {
    expect(deviceClassForSize(390), 'phone');
    expect(deviceClassForSize(599.9), 'phone');
    expect(deviceClassForSize(600), 'tablet');
    expect(deviceClassForSize(0), isNull);
    expect(deviceClassForSize(double.nan), isNull);
  });

  test('short link: /v1/resolve and its offline retry via /v1/open carry it', testOn: 'vm', () async {
    final e = Engine({'/v1/resolve': 'offline'});
    final s = links(e, () => 'tablet');
    await s.start(initialUrl: 'https://links.test/sale');
    await settle();
    expect(e.of('/v1/resolve').single['deviceClass'], 'tablet');
    e.routes['/v1/open'] = {'ok': true};
    await s.flushOpenReports();
    final open = e.of('/v1/open').last;
    expect(open['reason'], 'network');
    expect(open['deviceClass'], 'tablet');
  });

  test('direct open via /v1/open carries it; the saved queue never does', testOn: 'vm', () async {
    final storage = MemoryStore()..data['strait.deferredChecked'] = '1';
    final e = Engine({'/v1/open': 'offline'});
    await links(e, () => 'phone', storage: storage).start(initialUrl: 'https://shop.example/p/9');
    await settle();
    expect(e.of('/v1/open').first['deviceClass'], 'phone');
    expect(storage.data['strait.pendingOpens'], contains('openId'));
    expect(storage.data['strait.pendingOpens'], isNot(contains('deviceClass')));
  });

  test('none, invalid or throwing: left out, the link still resolves', () async {
    for (final dc in <String? Function()?>[null, () => null, () => 'watch', () => throw StateError('x')]) {
      final e = Engine({'/v1/resolve': resolved});
      final s = links(e, dc);
      final got = <LinkEvent>[];
      s.onLink.listen(got.add);
      await s.start(initialUrl: 'https://links.test/sale');
      await settle();
      expect(got.last.matched, isTrue);
      expect(e.of('/v1/resolve').single.containsKey('deviceClass'), isFalse);
    }
  });

  test('store sheet sends it', () async {
    final e = Engine({'/v1/store-sheet': {'ok': false, 'reason': 'not_found'}});
    await links(e, () => 'tablet').openStoreSheet('https://links.test/promo', NoOpener());
    expect(e.of('/v1/store-sheet').single['deviceClass'], 'tablet');
  });
}
