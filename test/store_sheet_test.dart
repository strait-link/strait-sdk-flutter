import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:strait_sdk/strait_sdk.dart';
import 'package:test/test.dart';

const click = '9a1c7e52-4b3d-4f8e-a6d1-0c2b5e7f9a34';
const referrer = 'strait_link=lnk_42&strait_click=$click';
const handoff = 'https://hilltop.strait.link/h/AbCdEfGhIjKlMnOpQrStUv';
const device = DeviceFields(screenWidth: 393, pixelRatio: 3, language: 'en-IN', timezone: 'Asia/Kolkata');

class SpyOpener extends StoreSheetOpener {
  final bool Function(StoreIntent) android;
  final bool ios;
  final intents = <StoreIntent>[];
  final products = <(StoreProduct, StoreSheetStyle)>[];
  final clipboard = <String>[];
  final bool canWrite;
  SpyOpener({bool Function(StoreIntent)? android, this.ios = true, this.canWrite = false})
      : android = android ?? ((_) => true);

  @override
  Future<bool> androidIntent(StoreIntent intent) async {
    intents.add(intent);
    return android(intent);
  }

  @override
  Future<bool> iosProduct(StoreProduct product, StoreSheetStyle style) async {
    products.add((product, style));
    return ios;
  }

  @override
  Future<bool> writeClipboard(String text) async {
    if (!canWrite) return false;
    clipboard.add(text);
    return true;
  }
}

class Engine {
  final Map<String, Object> routes;
  final bool offline;
  final calls = <(String, Map<String, dynamic>?)>[];
  Engine(this.routes, {this.offline = false});
  late final http.Client client = MockClient((req) async {
    calls.add((req.url.path, req.body.isEmpty ? null : jsonDecode(req.body) as Map<String, dynamic>));
    if (offline) throw http.ClientException('offline');
    final p = routes[req.url.path];
    return p == null ? http.Response('{}', 404) : http.Response(jsonEncode(p), 200);
  });
  Map<String, dynamic>? body(String path) {
    for (final c in calls) {
      if (c.$1 == path) return c.$2;
    }
    return null;
  }
}

StraitLinks links(Engine e, String platform) => StraitLinks(
      publishableKey: 'st_pub_test_appowner01',
      endpoint: 'https://hilltop.strait.link',
      platform: platform,
      deviceFields: () => device,
      client: e.client,
      now: () => 1000000,
    );

const androidReply = {
  'ok': true, 'beta': true, 'clickId': click, 'linkId': 'lnk_42',
  'android': {'package': 'shoes.hilltop.app', 'referrer': referrer},
};
Map<String, Object> iosReply([Map<String, Object?> extra = const {}]) => {
      'ok': true, 'beta': true, 'clickId': click, 'linkId': 'lnk_42',
      'ios': {'appStoreId': '6474676842', 'campaignToken': 'autumn-sale', 'deviceMatching': true, 'handoffUrl': null, ...extra},
    };

void main() {
  group('pure helpers', () {
    test('inline install, then market, then web; referrer round-trips', () {
      final plan = androidStorePlan('shoes.hilltop.app', referrer, callerId: 'com.partner.app', listing: 'autumn');
      expect(plan.map((i) => i.kind), ['inline_install', 'market', 'web']);
      final u = Uri.parse(plan.first.data);
      expect('${u.origin}${u.path}', 'https://play.google.com/d');
      expect(u.queryParameters['id'], 'shoes.hilltop.app');
      expect(u.queryParameters['referrer'], referrer);
      expect(u.queryParameters['listing'], 'autumn');
      expect(plan.first.packageName, 'com.android.vending');
      expect(plan.first.extras, {'overlay': true, 'callerId': 'com.partner.app'});
      expect(parseStraitClick(u.queryParameters['referrer']), click);
      expect(Uri.parse(plan[1].data).queryParameters['referrer'], referrer);
      expect(androidStorePlan('a.b', referrer).map((i) => i.kind), ['market', 'web']);
      expect(androidStorePlan('a.b', referrer, callerId: 'c.d', inline: false).map((i) => i.kind), ['market', 'web']);
    });

    test('iPhone product: options win, ct clipped to 30', () {
      expect(iosStoreProduct({'appStoreId': 'id1'}), isNull);
      expect(iosStoreProduct({'appStoreId': '1', 'campaignToken': 'c' * 50})!.campaignToken!.length, 30);
      expect(iosStoreProduct({'appStoreId': '1'}, const StoreSheetOptions(appStoreId: '2'))!.appStoreId, '2');
    });
  });

  group('Android', () {
    test('inline sheet with the engine referrer', () async {
      final e = Engine({'/v1/store-sheet': androidReply});
      final o = SpyOpener();
      final r = await links(e, 'android')
          .openStoreSheet('https://hilltop.strait.link/promo', o, const StoreSheetOptions(callerId: 'com.partner.app'));
      expect(r.opened, isTrue);
      expect(r.method, 'inline_install');
      expect(r.referrer, referrer);
      expect(r.clickId, click);
      expect(o.intents, hasLength(1));
      expect(e.body('/v1/store-sheet'),
          {'publishableKey': 'st_pub_test_appowner01', 'url': 'https://hilltop.strait.link/promo', 'platform': 'android'});
    });

    test('falls back to market when the inline sheet cannot start; throwing counts as not started', () async {
      final o = SpyOpener(android: (i) => i.kind == 'inline_install' ? throw StateError('no activity') : true);
      final r = await links(Engine({'/v1/store-sheet': androidReply}), 'android')
          .openStoreSheet('https://hilltop.strait.link/promo', o, const StoreSheetOptions(callerId: 'com.partner.app'));
      expect(r.method, 'market');
    });

    test('offline with androidPackage: store opens, deep link not kept', () async {
      final r = await links(Engine({}, offline: true), 'android').openStoreSheet(
          'https://hilltop.strait.link/promo', SpyOpener(), const StoreSheetOptions(androidPackage: 'shoes.hilltop.app'));
      expect(r.opened, isTrue);
      expect(r.referrer, isNull);
      expect(r.reason, 'offline');
    });

    test('unknown link, no package: nothing opens', () async {
      final r = await links(Engine({'/v1/store-sheet': {'ok': false, 'reason': 'not_found'}}), 'android')
          .openStoreSheet('https://hilltop.strait.link/nope', SpyOpener());
      expect(r.opened, isFalse);
      expect(r.reason, 'no_package');
    });
  });

  group('iPhone (beta)', () {
    test('saves the device match, then shows the product page', () async {
      final e = Engine({'/v1/store-sheet': iosReply(), '/v1/match-save': <String, Object>{}});
      final o = SpyOpener();
      final r = await links(e, 'ios').openStoreSheet('https://hilltop.strait.link/promo', o);
      expect(r.opened, isTrue);
      expect(r.method, 'product_page');
      expect(r.matchSaved, isTrue);
      expect(o.products.single.$1, const StoreProduct('6474676842', campaignToken: 'autumn-sale'));
      expect(e.body('/v1/match-save'), {...device.toJson(), 'linkId': 'lnk_42', 'clickId': click});
    });

    test('device matching off: no match-save; overlay style', () async {
      final e = Engine({'/v1/store-sheet': iosReply({'deviceMatching': false})});
      final r = await links(e, 'ios').openStoreSheet(
          'https://hilltop.strait.link/promo', SpyOpener(), const StoreSheetOptions(style: StoreSheetStyle.overlay));
      expect(r.method, 'overlay');
      expect(r.matchSaved, isFalse);
      expect(e.body('/v1/match-save'), isNull);
    });

    test('handoff link copied only when asked', () async {
      final e = Engine({'/v1/store-sheet': iosReply({'handoffUrl': handoff}), '/v1/match-save': <String, Object>{}});
      final o = SpyOpener(canWrite: true);
      expect((await links(e, 'ios').openStoreSheet('https://hilltop.strait.link/promo', o)).handoffCopied, isFalse);
      final r = await links(e, 'ios')
          .openStoreSheet('https://hilltop.strait.link/promo', o, const StoreSheetOptions(copyHandoffLink: true));
      expect(r.handoffCopied, isTrue);
      expect(o.clipboard, [handoff]);
    });

    test('opener cannot show: not_shown', () async {
      final r = await links(Engine({'/v1/store-sheet': iosReply(), '/v1/match-save': <String, Object>{}}), 'ios')
          .openStoreSheet('https://hilltop.strait.link/promo', SpyOpener(ios: false));
      expect(r.opened, isFalse);
      expect(r.reason, 'not_shown');
    });
  });
}
