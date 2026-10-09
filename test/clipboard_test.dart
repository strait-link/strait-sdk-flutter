import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:strait_sdk/strait_sdk.dart';
import 'package:test/test.dart';

/// Contract B19: the iPhone clipboard boost is opt-in, and the SDK never
/// touches the clipboard unless the app turned it on.
const pk = 'st_pub_test_appowner01';
const endpoint = 'https://hilltop.links.test';
const token = 'AbCdEfGhIjKlMnOpQrStUv';
const handoff = 'https://hilltop.links.test/h/$token';
const device = DeviceFields(screenWidth: 390, pixelRatio: 3, language: 'en-IN', timezone: 'Asia/Kolkata');

class SpyClipboard implements StraitClipboard {
  bool probable;
  String? text;
  bool throws;
  int detects = 0;
  int reads = 0;
  SpyClipboard({this.probable = true, this.text = handoff, this.throws = false});

  @override
  Future<bool> hasProbableWebUrl() async {
    detects++;
    if (throws) throw StateError('no pasteboard');
    return probable;
  }

  @override
  Future<String?> readText() async {
    reads++;
    return text;
  }
}

class Engine {
  final Map<String, Object> routes;
  final Map<String, int> status;
  final calls = <MapEntry<String, Map<String, dynamic>?>>[];
  Engine(this.routes, {this.status = const {}});
  late final http.Client client = MockClient((req) async {
    calls.add(MapEntry(req.url.path, req.body.isEmpty ? null : jsonDecode(req.body) as Map<String, dynamic>));
    final code = status[req.url.path];
    if (code != null) return http.Response('{}', code);
    final p = routes[req.url.path];
    return p == null ? http.Response('', 404) : http.Response(jsonEncode(p), 200);
  });
  List<String> get paths => calls.map((c) => c.key).toList();
  Map<String, dynamic>? body(String path) => calls.firstWhere((c) => c.key == path).value;
}

const claimed = {
  'matched': true,
  'longUrl': 'https://shop.example/p/42?color=red',
  'linkId': 'lnk_42',
  'clickId': '3f2a9c1e-7b4d-4e8a-9c0f-1a2b3c4d5e6f',
  'matchMethod': 'clipboard',
};
const noMatch = {'matched': false, 'matchMethod': 'none'};

StraitLinks make(Engine e, {SpyClipboard? clip, bool boost = false, String platform = 'ios', KeyValueStore? storage}) =>
    StraitLinks(
      publishableKey: pk,
      endpoint: endpoint,
      platform: platform,
      deviceFields: () => device,
      storage: storage ?? MemoryStore(),
      client: e.client,
      now: () => 1000000,
      clipboardBoost: boost,
      clipboard: clip,
    );

void main() {
  test('default: the clipboard is never touched (start + checkDeferred)', () async {
    final clip = SpyClipboard();
    final e = Engine({'/v1/match': noMatch, '/v1/handoff/claim': claimed});
    final s = make(e, clip: clip);
    await s.start();
    await s.checkDeferred();
    expect(clip.detects, 0);
    expect(clip.reads, 0);
    expect(e.paths, isNot(contains('/v1/handoff/claim')));
  });

  test('boost on but not iOS: the clipboard is never touched', () async {
    final clip = SpyClipboard();
    final s = make(Engine({'/v1/match': noMatch}), clip: clip, boost: true, platform: 'android');
    await s.start();
    expect(clip.detects + clip.reads, 0);
  });

  test('boost on: the debug checkDeferred never touches the clipboard', () async {
    final clip = SpyClipboard();
    final s = make(Engine({'/v1/match': noMatch}), clip: clip, boost: true, storage: MemoryStore()..data['strait.deferredChecked'] = '1');
    await s.start();
    await s.checkDeferred();
    expect(clip.detects + clip.reads, 0);
  });

  test('boost on, no web URL detected: readText is never called', () async {
    final clip = SpyClipboard(probable: false);
    final e = Engine({'/v1/match': noMatch});
    await make(e, clip: clip, boost: true).start();
    expect(clip.detects, 1);
    expect(clip.reads, 0);
    expect(e.paths, ['/v1/match']);
  });

  test('boost on, clipboard holds another URL: no claim, signal match runs', () async {
    final clip = SpyClipboard(text: 'https://evil.example/h/$token');
    final e = Engine({'/v1/match': noMatch});
    await make(e, clip: clip, boost: true).start();
    expect(clip.reads, 1);
    expect(e.paths, ['/v1/match']);
  });

  test('boost on, handoff link: exact claim, route clipboard, tap remembered (B16)', () async {
    final storage = MemoryStore();
    final e = Engine({'/v1/handoff/claim': claimed, '/v1/match': noMatch});
    final s = make(e, clip: SpyClipboard(), boost: true, storage: storage);
    await s.start();
    await Future<void>.delayed(Duration.zero);
    expect(e.paths, isNot(contains('/v1/match')));
    final b = e.body('/v1/handoff/claim')!;
    expect(b['publishableKey'], pk);
    expect(b['token'], token);
    expect(b['platform'], 'ios');
    expect(b['openId'], startsWith('o_'));
    expect(b.keys, isNot(contains('screenWidth')));
    final ev = s.events.single;
    expect(ev.kind, LinkKind.deferred);
    expect(ev.route, LinkRoute.clipboard);
    expect(ev.matched, isTrue);
    expect(ev.path, '/p/42');
    expect(ev.linkId, 'lnk_42');
    expect(storage.data['strait.deferredChecked'], '1');
    expect(storage.data['strait.lastTap'], contains('3f2a9c1e-7b4d-4e8a-9c0f-1a2b3c4d5e6f'));
  });

  test('claim refused (used/expired): falls back to /v1/match with the same openId', () async {
    final e = Engine({
      '/v1/handoff/claim': {'matched': false, 'reason': 'handoff_used'},
      '/v1/match': noMatch,
    });
    final s = make(e, clip: SpyClipboard(), boost: true);
    await s.start();
    expect(e.paths, ['/v1/handoff/claim', '/v1/match']);
    expect(e.body('/v1/match')!['openId'], e.body('/v1/handoff/claim')!['openId']);
    expect(s.events.single.route, LinkRoute.fingerprint);
  });

  test('claim unanswered (5xx): network, checked again next launch', () async {
    final storage = MemoryStore();
    final e = Engine({'/v1/match': noMatch}, status: {'/v1/handoff/claim': 503});
    final s = make(e, clip: SpyClipboard(), boost: true, storage: storage);
    await s.start();
    expect(s.events.single.reason, 'network');
    expect(storage.data['strait.deferredChecked'], isNull);
  });

  test('a throwing clipboard adapter never breaks the deferred check', () async {
    final e = Engine({'/v1/match': noMatch});
    final s = make(e, clip: SpyClipboard(throws: true), boost: true);
    await s.start();
    expect(e.paths, ['/v1/match']);
  });

  group('claimHandoff (paste button)', () {
    test('handoff text claims it', () async {
      final e = Engine({'/v1/handoff/claim': claimed});
      final s = make(e);
      final ev = await s.claimHandoff(' $handoff\n');
      expect(ev.matched, isTrue);
      expect(ev.route, LinkRoute.clipboard);
      expect(e.body('/v1/handoff/claim')!['token'], token);
    });

    test('other text: not_handoff, no network call', () async {
      final e = Engine({'/v1/handoff/claim': claimed});
      final ev = await make(e).claimHandoff('hello');
      expect(ev.matched, isFalse);
      expect(ev.reason, 'not_handoff');
      expect(e.calls, isEmpty);
    });

    test('refused claim reports the engine reason', () async {
      final e = Engine({'/v1/handoff/claim': {'matched': false, 'reason': 'handoff_expired'}});
      final ev = await make(e).claimHandoff(handoff);
      expect(ev.reason, 'handoff_expired');
    });

    test('no answer: network', () async {
      final e = Engine({}, status: {'/v1/handoff/claim': 500});
      expect((await make(e).claimHandoff(handoff)).reason, 'network');
    });
  });
}
