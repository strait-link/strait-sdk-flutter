import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:strait_sdk/strait_sdk.dart';
import 'package:test/test.dart';

/// Contract B21 (proposal): a matched deferred reply's `referralCode` reaches
/// the app on the LinkEvent, unchanged, only when it is a valid code.
const pk = 'st_pub_test_appowner01';
const endpoint = 'https://hilltop.links.test';
const handoff = 'https://hilltop.links.test/h/AbCdEfGhIjKlMnOpQrStUv';
const device = DeviceFields(screenWidth: 390, pixelRatio: 3, language: 'en-IN', timezone: 'Asia/Kolkata');
const matched = {
  'matched': true,
  'longUrl': 'https://shop.example/invite',
  'linkId': 'lnk_42',
  'clickId': '3f2a9c1e-7b4d-4e8a-9c0f-1a2b3c4d5e6f',
};

class Clip implements StraitClipboard {
  @override
  Future<bool> hasProbableWebUrl() async => true;
  @override
  Future<String?> readText() async => handoff;
}

StraitLinks make(Map<String, Object> routes, {String platform = 'ios', String? referrer, bool boost = false}) => StraitLinks(
      publishableKey: pk,
      endpoint: endpoint,
      platform: platform,
      deviceFields: () => device,
      storage: MemoryStore(),
      client: MockClient((req) async {
        final p = routes[req.url.path];
        return p == null ? http.Response('', 404) : http.Response(jsonEncode(p), 200);
      }),
      now: () => 1000000,
      installReferrer: referrer == null ? null : () async => referrer,
      clipboard: boost ? Clip() : null,
    );

void main() {
  test('replyReferralCode keeps valid codes exactly, rejects the rest', () {
    for (final c in ['ASHA42', 'a', 'user_12-b', 'x' * 64]) {
      expect(replyReferralCode(c), c);
    }
    for (final c in <Object?>[null, '', 'x' * 65, 'a b', 'me@example.com', '+919999', 'ü', 42, {}, ['A']]) {
      expect(replyReferralCode(c), isNull, reason: '$c');
    }
  });

  test('Android Play referrer', () async {
    final s = make({'/v1/referrer': {...matched, 'matchMethod': 'install_referrer', 'referralCode': 'ASHA42'}},
        platform: 'android', referrer: 'strait_link=lnk_42');
    await s.start();
    final ev = s.events.single;
    expect(ev.route, LinkRoute.installReferrer);
    expect(ev.referralCode, 'ASHA42');
    expect(ev.toJson()['referralCode'], 'ASHA42');
  });

  test('iPhone match', () async {
    final s = make({'/v1/match': {...matched, 'matchMethod': 'exact_ext', 'referralCode': 'RAVI7'}});
    await s.start();
    expect(s.events.single.referralCode, 'RAVI7');
  });

  test('clipboard boost claim and the Paste button', () async {
    final routes = {
      '/v1/handoff/claim': {...matched, 'matchMethod': 'clipboard', 'referralCode': 'ASHA42'},
      '/v1/match': {'matched': false, 'ios': {'deviceMatching': true, 'pasteHandoff': true}},
    };
    final s = make(routes, boost: true);
    await s.start();
    expect(s.events.single.route, LinkRoute.clipboard);
    expect(s.events.single.referralCode, 'ASHA42');
    expect((await s.claimHandoff(handoff)).referralCode, 'ASHA42');
  });

  test('no code, an invalid code or no match: null, and not in toJson', () async {
    for (final reply in <Map<String, Object?>>[
      {...matched},
      {...matched, 'referralCode': 'not valid'},
      {...matched, 'referralCode': null},
      {'matched': false, 'referralCode': 'ASHA42'},
    ]) {
      final s = make({'/v1/match': reply});
      await s.start();
      expect(s.events.single.referralCode, isNull);
      expect(s.events.single.toJson().containsKey('referralCode'), isFalse);
    }
  });

  test('resolveDeferredLink MatchResult carries referralCode', () async {
    final r = await resolveDeferredLink(
      publishableKey: pk,
      endpoint: endpoint,
      platform: 'android',
      device: device,
      installReferrer: 'strait_link=lnk_42',
      client: MockClient((req) async => http.Response(jsonEncode({...matched, 'matchMethod': 'install_referrer', 'referralCode': 'ASHA42'}), 200)),
    );
    expect(r.referralCode, 'ASHA42');
  });
}
