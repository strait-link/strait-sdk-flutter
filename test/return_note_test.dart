import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:strait_sdk/strait_sdk.dart';
import 'package:strait_sdk/src/core.dart' show dayMs, installTapValue, returnNote;
import 'package:test/test.dart';

// B28 (shared-spec ADR 0012): at most three "came back" notes per install (day 1, 7, 30), carrying the
// install's tap id. Port of sdk-react-native/test/return-note.test.ts.

const click = '3f2a9c1e-7b4d-4e8a-9c0f-1a2b3c4d5e6f';
const other = '11111111-2222-4333-8444-555555555555';
const t = 1800000000000;
const device = DeviceFields(screenWidth: 390, pixelRatio: 3, language: 'en', timezone: 'Asia/Kolkata');

class Engine {
  Engine(this.reply);
  final http.Response Function(String path) reply;
  final sent = <({String path, Map<String, dynamic> body})>[];
  late final http.Client client = MockClient((req) async {
    sent.add((path: req.url.path, body: req.body.isEmpty ? <String, dynamic>{} : jsonDecode(req.body) as Map<String, dynamic>));
    return reply(req.url.path);
  });
  List<Map<String, dynamic>> get notes => [for (final x in sent) if (x.body['kind'] == 'return') x.body];
}

http.Response matchReply(String path) => path == '/v1/match'
    ? http.Response(jsonEncode({'matched': true, 'clickId': click.toUpperCase(), 'longUrl': 'https://shop.example/p/1'}), 200)
    : http.Response(jsonEncode({'ok': true}), 202);

StraitLinks make(Engine e, KeyValueStore s, int Function() now) => StraitLinks(
      publishableKey: 'st_pub_test_x',
      endpoint: 'https://acme.strait.link',
      platform: 'ios',
      deviceFields: () => device,
      deviceClass: () => 'phone',
      storage: s,
      client: e.client,
      now: now,
      appVersion: '2.1.0',
    );

Future<void> settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class FailingTapStore extends MemoryStore {
  @override
  Future<void> set(String key, String value) async {
    if (key == 'strait.installTap' && value.contains('"sent":[1]')) throw StateError('disk full');
    return super.set(key, value);
  }
}

void main() {
  group('returnNote (pure)', () {
    test('is due exactly on day 1, 7 and 30, once each', () {
      final s = installTapValue(click, t);
      expect(returnNote(s, t + dayMs - 1), isNull);
      expect(returnNote(s, t + dayMs), (day: 1, clickId: click, openId: 'r1-$click'));
      expect(returnNote(s, t + 2 * dayMs), isNull);
      expect(returnNote(s, t + 7 * dayMs + 5)?.day, 7);
      expect(returnNote(s, t + 30 * dayMs)?.day, 30);
      expect(returnNote(s, t + 31 * dayMs), isNull);
      expect(returnNote(installTapValue(click, t, [1]), t + dayMs), isNull);
    });
    test('anything unreadable is no note', () {
      expect(returnNote(null, t), isNull);
      expect(returnNote('', t), isNull);
      expect(returnNote('{', t + dayMs), isNull);
      expect(returnNote(jsonEncode({'clickId': 'nope', 'at': t}), t + dayMs), isNull);
      expect(returnNote(jsonEncode({'clickId': click, 'at': t + dayMs}), t), isNull);
    });
  });

  group('came-back notes (client)', testOn: 'vm', () {
    test('the install match keeps the tap; day 1 sends one note on start, a second foreground sends nothing', () async {
      var now = t;
      final e = Engine(matchReply);
      final s = MemoryStore();
      final links = make(e, s, () => now);
      await links.start();
      await settle();
      expect(jsonDecode(s.data['strait.installTap']!), {'clickId': click, 'at': t, 'sent': []});
      expect(e.notes, isEmpty); // day 0: nothing
      links.stop();

      now = t + dayMs + 60000;
      final life = StreamController<AppLifecycle>(sync: true);
      final again = make(e, s, () => now);
      await again.start(lifecycle: life.stream);
      await settle();
      life.add(AppLifecycle.active);
      await settle();
      final opens = [for (final x in e.sent) if (x.body['kind'] == 'return') x];
      expect(opens.map((x) => x.path), ['/v1/open']);
      expect(opens.single.body, {
        'publishableKey': 'st_pub_test_x', 'openId': 'r1-$click', 'kind': 'return', 'day': 1, 'clickId': click,
        'platform': 'ios', 'at': now, 'appVersion': '2.1.0', 'sdkVersion': 'flutter/$straitSdkVersion',
      });
      expect((jsonDecode(s.data['strait.installTap']!) as Map)['sent'], [1]);
    });

    test('a later tap never replaces the install tap; a fresh first launch (restored backup) clears it', () async {
      final e = Engine(matchReply);
      final s = MemoryStore();
      s.data['strait.installTap'] = installTapValue(other, t - 40 * dayMs); // a backup of another install
      final urls = StreamController<String>(sync: true);
      final links = make(e, s, () => t);
      await links.start(urls: urls.stream);
      urls.add('acme://p/2?strait_click=$other');
      await settle();
      expect((jsonDecode(s.data['strait.installTap']!) as Map)['clickId'], click);
      expect((jsonDecode(s.data['strait.lastTap']!) as Map)['clickId'], other);
    });

    test('a first launch opened by a link with a tap id keeps that tap', () async {
      final e = Engine((_) => http.Response(jsonEncode({'ok': true}), 202));
      final s = MemoryStore();
      final links = make(e, s, () => t);
      await links.start(initialUrl: 'acme://p/2?strait_click=$click');
      await settle();
      expect(jsonDecode(s.data['strait.installTap']!), {'clickId': click, 'at': t, 'sent': []});
    });

    test('offline: the note is queued and flushed later; opted out: nothing, and the install tap is deleted', () async {
      var now = t + 7 * dayMs;
      var down = true;
      final e = Engine((_) => down ? http.Response('{}', 503) : http.Response(jsonEncode({'ok': true}), 202));
      final s = MemoryStore();
      s.data['strait.deferredChecked'] = '1';
      s.data['strait.installTap'] = jsonEncode({'clickId': click, 'at': t, 'sent': [1]});
      final life = StreamController<AppLifecycle>(sync: true);
      final links = make(e, s, () => now);
      await links.start(lifecycle: life.stream);
      await settle();
      final queued = jsonDecode(s.data['strait.pendingOpens']!) as List;
      expect(queued, [
        allOf(containsPair('type', 'return'), containsPair('openId', 'r7-$click'), containsPair('day', 7), containsPair('clickId', click)),
      ]);
      expect((queued.single as Map).containsKey('publishableKey'), isFalse);
      down = false;
      now += 120000; // past the C1 hold
      await links.flushOpenReports();
      expect(e.sent.last.path, '/v1/open');
      expect(e.sent.last.body, allOf(containsPair('openId', 'r7-$click'), containsPair('kind', 'return'), containsPair('day', 7), containsPair('publishableKey', 'st_pub_test_x')));
      expect(e.sent.last.body.containsKey('type'), isFalse);
      expect(e.sent.last.body.containsKey('deviceClass'), isFalse);
      expect(await links.pendingOpenReports(), 0);

      await links.setEnabled(false);
      expect(s.data['strait.installTap'], '');
      now = t + 30 * dayMs;
      final before = e.sent.length;
      life.add(AppLifecycle.active);
      await settle();
      expect(e.sent.length, before);
    });

    test('a failed "sent" write sends nothing', () async {
      final e = Engine((_) => http.Response(jsonEncode({'ok': true}), 202));
      final s = FailingTapStore();
      s.data['strait.deferredChecked'] = '1';
      s.data['strait.installTap'] = installTapValue(click, t);
      await make(e, s, () => t + dayMs).start();
      await settle();
      expect(e.notes, isEmpty);
    });
  });

  test('web never sends a note', testOn: 'browser', () async {
    final e = Engine((_) => http.Response('{}', 202));
    final s = MemoryStore();
    s.data['strait.installTap'] = installTapValue(click, t);
    await make(e, s, () => t + dayMs).start();
    await settle();
    expect(e.notes, isEmpty);
  });
}
