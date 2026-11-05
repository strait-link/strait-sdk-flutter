import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:strait_sdk/strait_sdk.dart';
import 'package:test/test.dart';

// Opt-out (td2-27): setEnabled(false) = no reports, no events, no install matching, kept across
// launches; a link that carries its own destination still reaches onLink (the app's own navigation).
// Port of sdk-react-native/test/opt-out.test.ts.

/// Web builds have no install, so no first-launch check (CHANGELOG 0.9.6); the switch rules are the same.
const onWeb = bool.fromEnvironment('dart.library.js_interop');
const device = DeviceFields(screenWidth: 411, pixelRatio: 2.625, language: 'en', timezone: 'Asia/Kolkata');

class Engine {
  Engine([this.reply]);
  final http.Response Function(String path)? reply;
  final calls = <String>[];
  final bodies = <Map<String, dynamic>>[];
  late final http.Client client = MockClient((req) async {
    calls.add(req.url.path);
    bodies.add(req.body.isEmpty ? <String, dynamic>{} : jsonDecode(req.body) as Map<String, dynamic>);
    return reply?.call(req.url.path) ?? http.Response(jsonEncode({'matched': false}), 202);
  });
}

StraitLinks make(Engine e, KeyValueStore s) => StraitLinks(
      publishableKey: 'st_pub_test_x',
      endpoint: 'https://acme.strait.link',
      platform: 'android',
      deviceFields: () => device,
      storage: s,
      client: e.client,
      now: () => 1800000000000,
    );

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('setEnabled (opt-out)', () {
    test('disabled: sends nothing (no deferred check, no open report, no event, no flush), links still route', () async {
      final e = Engine();
      final s = MemoryStore(); // empty = a first launch: the deferred check is due
      s.data['strait.pendingOpens'] = jsonEncode([
        {'openId': 'o_1', 'kind': 'direct', 'route': 'app_link', 'appState': 'closed', 'platform': 'android', 'matched': true, 'firstLaunch': false, 'at': 1800000000000},
      ]);
      final links = make(e, s);
      await links.setEnabled(false);
      final urls = StreamController<String>(sync: true);
      await links.start(urls: urls.stream);
      urls.add('acme://product/42');
      expect(await links.trackEvent('purchase', value: 5), isFalse);
      await links.flushOpenReports();
      final check = await links.checkDeferred();
      expect(check.matched, isFalse);
      expect(check.reason, 'disabled');
      await settle();
      expect(e.calls, isEmpty);
      expect(links.events.any((l) => l.matched && l.rawUrl == 'acme://product/42'), isTrue);
      expect(await links.pendingOpenReports(), 0); // reports saved before the opt-out are deleted
      if (!onWeb) expect(s.data['strait.deferredChecked'] ?? '', ''); // the check is still due
    });

    test('disabled: a short link still routes through /v1/lookup (records nothing), and nothing else is sent', () async {
      final e = Engine((path) => path == '/v1/lookup'
          ? http.Response(jsonEncode({'matched': true, 'longUrl': 'https://shop.example/p/42?color=red', 'linkId': 'lnk_42', 'slug': 'sale'}), 200)
          : http.Response('{}', 202));
      final s = MemoryStore();
      final links = make(e, s);
      await links.setEnabled(false);
      final urls = StreamController<String>(sync: true);
      await links.start(urls: urls.stream);
      urls.add('https://acme.strait.link/sale?utm_source=sms&secret=1');
      await settle();
      await links.flushOpenReports();
      await settle();
      expect(e.calls, ['/v1/lookup']);
      // Only the key and host + path leave the device: no query, openId, platform, device or app state.
      expect(e.bodies.single, {'publishableKey': 'st_pub_test_x', 'url': 'https://acme.strait.link/sale'});
      final l = links.events.single;
      expect(l.matched, isTrue);
      expect(l.path, '/p/42');
      expect(l.params, {'color': 'red'});
      expect(await links.pendingOpenReports(), 0);
      expect(s.data['strait.lastTap'] ?? '', ''); // no tap remembered
    });

    test('disabled: a lookup miss keeps the engine reason, nothing queued', () async {
      final links = make(Engine((_) => http.Response(jsonEncode({'matched': false, 'reason': 'expired'}), 200)), MemoryStore());
      await links.setEnabled(false);
      final urls = StreamController<String>(sync: true);
      await links.start(urls: urls.stream);
      urls.add('https://acme.strait.link/old');
      await settle();
      expect(links.events.any((l) => !l.matched && l.reason == 'expired'), isTrue);
      expect(await links.pendingOpenReports(), 0);
    });

    test('disabled: an engine without /v1/lookup (404) or no network: reason disabled, nothing queued', () async {
      for (final reply in <http.Response Function(String)>[
        (_) => http.Response(jsonEncode({'error': 'not found'}), 404),
        (_) => throw http.ClientException('offline'),
      ]) {
        final links = make(Engine(reply), MemoryStore());
        await links.setEnabled(false);
        final urls = StreamController<String>(sync: true);
        await links.start(urls: urls.stream);
        urls.add('https://acme.strait.link/sale');
        await settle();
        expect(links.events.any((l) => !l.matched && l.reason == 'disabled'), isTrue);
        expect(await links.pendingOpenReports(), 0);
      }
    });

    test('persists across launches', () async {
      final s = MemoryStore();
      await make(Engine(), s).setEnabled(false);
      final e = Engine();
      final links = make(e, s); // next launch, same storage
      expect(await links.isEnabled(), isFalse);
      await links.start();
      await links.trackEvent('signup');
      await settle();
      expect(e.calls, isEmpty);
    });

    test('setEnabled(true) resumes: the skipped first-launch check runs and events are sent', () async {
      final e = Engine();
      final s = MemoryStore();
      final links = make(e, s);
      await links.setEnabled(false);
      await links.start();
      await settle();
      expect(e.calls, isEmpty);
      await links.setEnabled(true);
      await settle();
      expect(await links.isEnabled(), isTrue);
      if (!onWeb) {
        expect(e.calls, contains('/v1/match'));
        expect(s.data['strait.deferredChecked'], '1');
      }
      expect(await links.trackEvent('purchase'), isTrue);
      expect(e.calls, contains('/v1/event'));
    });
  });
}
