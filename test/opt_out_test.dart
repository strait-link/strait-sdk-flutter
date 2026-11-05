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
  final calls = <String>[];
  late final http.Client client = MockClient((req) async {
    calls.add(req.url.path);
    return http.Response(jsonEncode({'matched': false}), 202);
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
      urls.add('https://acme.strait.link/sale'); // a short link needs a lookup, which counts the tap
      expect(await links.trackEvent('purchase', value: 5), isFalse);
      await links.flushOpenReports();
      final check = await links.checkDeferred();
      expect(check.matched, isFalse);
      expect(check.reason, 'disabled');
      await settle();
      expect(e.calls, isEmpty);
      expect(links.events.any((l) => l.matched && l.rawUrl == 'acme://product/42'), isTrue);
      expect(links.events.any((l) => !l.matched && l.reason == 'disabled' && l.rawUrl == 'https://acme.strait.link/sale'), isTrue);
      expect(await links.pendingOpenReports(), 0); // reports saved before the opt-out are deleted
      if (!onWeb) expect(s.data['strait.deferredChecked'] ?? '', ''); // the check is still due
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
