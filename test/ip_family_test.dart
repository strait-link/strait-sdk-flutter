@TestOn('vm')
library;

// Contract B24 (engine ADR 0101): the first-launch check asked over IPv6 and found nothing; the engine
// names its IPv4-only URL and the SDK asks once more there, same openId, same fields. Only a match there counts.

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:strait_sdk/strait_sdk.dart';
import 'package:strait_sdk/src/core.dart' show ipv4MatchUrl;
import 'package:test/test.dart';

const pk = 'st_pub_test_appowner01';
const endpoint = 'https://hilltop.links.test';
const v4 = 'https://v4.straitlink.test/v1/match';
const device = DeviceFields(screenWidth: 390, pixelRatio: 3, language: 'en-IN', timezone: 'Asia/Kolkata');
const missV6 = {
  'matched': false,
  'matchMethod': 'none',
  'reasons': ['no_candidate'],
  'ios': {'deviceMatching': true, 'pasteHandoff': false},
  'ipv4Match': v4,
};
const hitV4 = {
  'matched': true,
  'longUrl': 'https://shop.example/p/42',
  'linkId': 'lnk_42',
  'clickId': '3f2a9c1e-7b4d-4e8a-9c0f-1a2b3c4d5e6f',
  'matchMethod': 'exact_ext',
  'reasons': ['exact_ext', 'ip_family'],
};

/// Routes keyed by host + path; `offline` hosts throw.
class Engine {
  final Map<String, Object> routes;
  final Set<String> offline;
  final calls = <({String host, String path, Map<String, dynamic>? body})>[];
  void Function(String host)? onCall;
  Engine(this.routes, {this.offline = const {}});
  late final http.Client client = MockClient((req) async {
    calls.add((
      host: req.url.host,
      path: req.url.path,
      body: req.body.isEmpty ? null : jsonDecode(req.body) as Map<String, dynamic>
    ));
    onCall?.call(req.url.host);
    if (offline.contains(req.url.host)) throw http.ClientException('offline');
    final p = routes['${req.url.host}${req.url.path}'];
    return p == null ? http.Response('', 404) : http.Response(jsonEncode(p), 200);
  });
  List<String> get matchHosts => calls.where((c) => c.path == '/v1/match').map((c) => c.host).toList();
}

class Clip implements StraitClipboard {
  int touched = 0;
  @override
  Future<bool> hasProbableWebUrl() async {
    touched++;
    return true;
  }

  @override
  Future<String?> readText() async {
    touched++;
    return 'https://hilltop.links.test/h/AbCdEfGhIjKlMnOpQrStUv';
  }
}

StraitLinks make(Engine e, {StraitClipboard? clip}) => StraitLinks(
      publishableKey: pk,
      endpoint: endpoint,
      platform: 'ios',
      deviceFields: () => device,
      storage: MemoryStore(),
      client: e.client,
      now: () => 1000000,
      clipboard: clip,
    );

void main() {
  test('same body to the named URL; its match is the answer', () async {
    final e = Engine({'hilltop.links.test/v1/match': missV6, 'v4.straitlink.test/v1/match': hitV4});
    final s = make(e);
    await s.start();
    expect(e.matchHosts, ['hilltop.links.test', 'v4.straitlink.test']);
    final asks = e.calls.where((c) => c.path == '/v1/match').toList();
    expect(asks[1].body, asks[0].body);
    expect(asks[0].body!['openId'], isNotNull);
    final ev = s.events.single;
    expect(ev.matched, isTrue);
    expect(ev.url, 'https://shop.example/p/42');
    expect(ev.linkId, 'lnk_42');
  });

  test('no match there, or the URL unreachable: the first answer stands', () async {
    final a = make(Engine({
      'hilltop.links.test/v1/match': missV6,
      'v4.straitlink.test/v1/match': {'matched': false}
    }));
    await a.start();
    expect(a.events.single.matched, isFalse);
    expect(a.events.single.reason, 'no_match');
    final b = make(Engine({'hilltop.links.test/v1/match': missV6, 'v4.straitlink.test/v1/match': hitV4},
        offline: {'v4.straitlink.test'}));
    await b.start();
    expect(b.events.single.matched, isFalse);
    expect(b.events.single.reason, 'no_match');
  });

  test('no second ask without the field, with a bad URL, or on the read-only checkDeferred()', () async {
    for (final bad in [
      null,
      'http://v4.straitlink.test/v1/match',
      'https://v4.straitlink.test/v1/open',
      '$v4?x=1',
      'javascript:alert(1)',
      '/v1/match'
    ]) {
      final e = Engine({
        'hilltop.links.test/v1/match': {...missV6, 'ipv4Match': bad},
        'v4.straitlink.test/v1/match': hitV4
      });
      await make(e).start();
      expect(e.matchHosts, ['hilltop.links.test'], reason: '$bad');
    }
    final e = Engine({
      'hilltop.links.test/v1/match': missV6,
      'v4.straitlink.test/v1/match': {'matched': false}
    });
    final s = make(e);
    await s.start();
    final before = e.calls.length;
    await s.checkDeferred();
    expect(e.calls.skip(before).map((c) => c.host).toList(), ['hilltop.links.test']);
  });

  test('switched off during the first ask: nothing is sent to the IPv4 URL', () async {
    final e = Engine({'hilltop.links.test/v1/match': missV6, 'v4.straitlink.test/v1/match': hitV4});
    final s = make(e);
    e.onCall = (host) {
      if (host == 'hilltop.links.test') s.setEnabled(false);
    };
    await s.start();
    expect(e.matchHosts.where((h) => h == 'v4.straitlink.test'), isEmpty);
  });

  test('paste handoff (B19) follows the first answer: still runs when the IPv4 ask misses, never when it matches',
      () async {
    final pasteMiss = {...missV6}..['ios'] = {'deviceMatching': true, 'pasteHandoff': true};
    const claimOk = {
      'matched': true,
      'longUrl': 'https://shop.example/x',
      'linkId': 'lnk_1',
      'matchMethod': 'clipboard'
    };
    for (final (second, expectClaim) in [
      (<String, Object>{'matched': false}, true),
      (hitV4, false)
    ]) {
      final clip = Clip();
      final e = Engine({
        'hilltop.links.test/v1/match': pasteMiss,
        'v4.straitlink.test/v1/match': second,
        'hilltop.links.test/v1/handoff/claim': claimOk
      });
      final s = make(e, clip: clip);
      await s.start();
      expect(e.calls.any((c) => c.path == '/v1/handoff/claim'), expectClaim);
      expect(clip.touched > 0, expectClaim);
      expect(s.events.single.route, expectClaim ? LinkRoute.clipboard : LinkRoute.fingerprint);
    }
  });

  test('ipv4MatchUrl accepts only a plain https …/v1/match URL', () {
    expect(ipv4MatchUrl('https://v4.straitlink.in/v1/match'), 'https://v4.straitlink.in/v1/match');
    for (final bad in [
      null,
      1,
      '',
      'https://v4.straitlink.in/v1/match/',
      'https://u:p@v4.straitlink.in/v1/match',
      'https://v4.straitlink.in/v1/match#x',
      'ftp://x/v1/match'
    ]) {
      expect(ipv4MatchUrl(bad), isNull, reason: '$bad');
    }
  });
}
