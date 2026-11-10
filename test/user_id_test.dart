import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:strait_sdk/src/core.dart';
import 'package:strait_sdk/strait_sdk.dart';
import 'package:test/test.dart';

// Contract B27 (shared-spec ADR 0009, engine ADR 0110): setUserId(id) after the app's own sign-in; later
// events carry it on the app.event webhook. Emails and phone numbers are hashed on the device.
// Port of sdk-react-native/test/user-id.test.ts.

const t = 1800000000000;
const device = DeviceFields(screenWidth: 411, pixelRatio: 2.625, language: 'en', timezone: 'Asia/Kolkata');
const offline = 'offline';
const priyaHash = '6bdb7e961d54ddc243ec721e6e211ac0a179b19a9ce2ad52a418198e146e69fe'; // sha256('priya@example.com')
const phoneHash = 'f3a47ce5ce3d4ca8ad15225a245b2759022f79489f5c62719b8c9490f7aab90e'; // sha256('+919876543210'), v15

/// Fake engine: every call answers [route] (a status, or [offline] = no answer).
class Engine {
  Object route = 202;
  final events = <Map<String, dynamic>>[];
  final paths = <String>[];
  late final http.Client client = MockClient((req) async {
    paths.add(req.url.path);
    if (req.url.path == '/v1/event') events.add(jsonDecode(req.body) as Map<String, dynamic>);
    if (route == offline) throw http.ClientException('Network request failed');
    return http.Response('{}', route as int);
  });
}

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

StraitLinks make(Engine e, MemoryStore s) => StraitLinks(
      publishableKey: 'st_pub_test_x',
      endpoint: 'https://links.test',
      platform: 'android',
      deviceFields: () => device,
      storage: s,
      client: e.client,
      now: () => t,
    );

Future<(StraitLinks, Engine, MemoryStore)> started([Object route = 202]) async {
  final e = Engine()..route = route;
  final s = MemoryStore()..data['strait.deferredChecked'] = '1';
  final links = make(e, s);
  await links.start();
  await settle();
  return (links, e, s);
}

void main() {
  group('sha256Hex (FIPS 180-4, also under dart2js / dart2wasm)', () {
    // Expected values from Node's crypto.createHash('sha256').
    final cases = {
      '': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      'abc': 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      'a' * 55: '9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318',
      'a' * 56: 'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a',
      'a' * 64: 'ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb',
      'a' * 200: 'c2a908d98f5df987ade41b5fce213067efbcc21ef2240212a41e54b5e7c28ae5',
      'josé@example.com': 'b0a53cf19e34d05b57bced7365c6b00ddbe38d62957e863de2a66a56c3b42cea',
      '日本語': '77710aedc74ecfa33685e33a6c7df5cc83004da1bdcef7fb280f5c2b2e97e0a5',
      '\u{1F600}x': '10f5e9cdd01d869815a52f43599f9c372ffa4b41cda11b5180da85dc0928333c',
      'a\uD800b': '05087813392efc16fe8ff448920c6328e53af865df39419436659d9ffda90f7b', // lone surrogate = U+FFFD
    };
    var i = 0;
    cases.forEach((input, hex) => test('#${i++}', () => expect(sha256Hex(input), hex)));
  });

  group('userIdField', () {
    test('keeps an opaque id, trimmed', () {
      expect(userIdField('  user_4821 '), (userId: 'user_4821', userIdHashed: false));
    });
    test('hashes an email, lower-cased and trimmed', () {
      expect(userIdField(' Priya@Example.COM '), (userId: priyaHash, userIdHashed: true));
    });
    test('hashes a phone number as + and its digits (v15, shared-spec ADR 0010)', () {
      expect(userIdField('+91 98765-43210'), (userId: phoneHash, userIdHashed: true));
      for (final p in ['(+91) 98765 43210', '0091 98765 43210', '+91\u00A098765\u00A043210', '\u202A+91 98765 43210\u202C',
          '+91\u201398765\u201343210', 'tel:+91-98765-43210', '\uFF0B\uFF19\uFF11 \uFF19\uFF18\uFF17\uFF16\uFF15 \uFF14\uFF13\uFF12\uFF11\uFF10']) {
        expect(userIdField(p), (userId: phoneHash, userIdHashed: true), reason: p);
      }
      expect(userIdField('\u096F\u096E\u096D\u096C\u096B\u096A\u0969\u0968\u0967\u0966'), (userId: sha256Hex('9876543210'), userIdHashed: true));
      expect(userIdField('Priya\uFF20Example.com'), (userId: sha256Hex('priya\uFF20example.com'), userIdHashed: true));
      for (final id in ['98765+43210', '+91 98765 43210 ext 12', 'TEL:1234567', '98765_43210']) {
        expect(userIdField(id), (userId: id, userIdHashed: false), reason: id);
      }
    });
    test("trims JavaScript's whitespace set: U+FEFF and U+3000 go, U+0085 and U+200B stay", () {
      expect(userIdField('\uFEFF\u3000user_4821\u00A0'), (userId: 'user_4821', userIdHashed: false));
      expect(userIdField('\u0085user_4821'), (userId: '\u0085user_4821', userIdHashed: false));
      expect(userIdField('user_4821\u200B'), (userId: 'user_4821\u200B', userIdHashed: false));
    });
    test('drops empty, too long, control characters and null', () {
      for (final bad in [null, '', '   ', 'x' * (userIdMax + 1), 'a\nb']) {
        expect(userIdField(bad), isNull);
      }
      expect(userIdField('x' * userIdMax), (userId: 'x' * userIdMax, userIdHashed: false));
    });
  });

  group('setUserId (B27)', () {
    test('events after setUserId carry it; setUserId(null) stops it; never on other calls', () async {
      final (links, e, _) = await started();
      await links.trackEvent('open_cart');
      links.setUserId('user_4821');
      await links.trackEvent('purchase');
      links.setUserId(null);
      await links.trackEvent('after_logout');
      expect(e.events[0].containsKey('userId'), isFalse);
      expect(e.events[1], containsPair('userId', 'user_4821'));
      expect(e.events[1], containsPair('userIdHashed', false));
      expect(e.events[1]['event'], 'purchase');
      expect(e.events[2].containsKey('userId'), isFalse);
      expect(e.events[2].containsKey('userIdHashed'), isFalse);
    });

    test('an email never leaves the device: only its hash is sent, and only the hash is queued', () async {
      final (links, e, s) = await started(offline);
      links.setUserId('Priya@Example.com');
      expect(await links.trackEvent('purchase'), isFalse);
      await settle();
      expect(e.events[0], containsPair('userId', priyaHash));
      expect(e.events[0], containsPair('userIdHashed', true));
      expect(jsonEncode(e.events[0]).toLowerCase(), isNot(contains('priya')));
      expect(s.data['strait.pendingOpens'], contains(priyaHash));
      expect(s.data.values.join('|').toLowerCase(), isNot(contains('priya'))); // nothing raw stored anywhere
    });

    test('the id at the time of the event is the one sent, even when the event is sent later', () async {
      final (links, e, s) = await started(offline);
      links.setUserId('user_1');
      await links.trackEvent('purchase', eventId: 'ord_1');
      links.setUserId('user_2');
      await settle();
      final queued = (jsonDecode(s.data['strait.pendingOpens']!) as List).single as Map;
      expect(queued['userId'], 'user_1');
      e.route = 202;
      await links.flushOpenReports();
      expect(e.events.last, containsPair('eventId', 'ord_1'));
      expect(e.events.last, containsPair('userId', 'user_1'));
    });

    test('the id is read when trackEvent is called: a setUserId right after it never changes that event', () async {
      final (links, e, _) = await started();
      links.setUserId('user_1');
      final a = links.trackEvent('purchase', eventId: 'ord_1');
      links.setUserId(null);
      final b = links.trackEvent('refund_ask', eventId: 'ord_2');
      links.setUserId('user_2');
      await Future.wait([a, b]);
      final byId = {for (final ev in e.events) ev['eventId']: ev};
      expect(byId['ord_1'], containsPair('userId', 'user_1'));
      expect(byId['ord_2']!.containsKey('userId'), isFalse);
    });

    test('opting out clears it; setUserId while off is ignored; back on sends nothing until set again', () async {
      final (links, e, _) = await started();
      links.setUserId('user_4821');
      await links.setEnabled(false);
      links.setUserId('user_9');
      await links.setEnabled(true);
      await links.trackEvent('purchase');
      expect(e.events, hasLength(1));
      expect(e.events[0].containsKey('userId'), isFalse);
    });

    test('a bad value clears the previous id instead of sending it', () async {
      final (links, e, _) = await started();
      links.setUserId('user_1');
      links.setUserId('x' * (userIdMax + 1));
      await links.trackEvent('purchase');
      expect(e.events[0].containsKey('userId'), isFalse);
    });

    test('not stored: the id is never written to storage', () async {
      final (links, _, s) = await started();
      links.setUserId('user_4821');
      await links.trackEvent('purchase');
      await settle();
      expect(s.data.values.join('|'), isNot(contains('user_4821')));
    });
  });

  group('setUserId before start (B27)', () {
    test('a stored opt-out drops an id set before the switch was read', () async {
      final e = Engine();
      final s = MemoryStore()
        ..data['strait.deferredChecked'] = '1'
        ..data['strait.enabled'] = '0';
      final links = make(e, s);
      links.setUserId('user_4821');
      await settle();
      await links.setEnabled(true);
      await links.trackEvent('purchase');
      expect(e.events, hasLength(1));
      expect(e.events[0].containsKey('userId'), isFalse);
    });

    test('a stored "on" keeps an id set before start', () async {
      final e = Engine();
      final s = MemoryStore()..data['strait.deferredChecked'] = '1';
      final links = make(e, s);
      links.setUserId('user_4821');
      await links.start();
      await links.trackEvent('purchase');
      expect(e.events.single, containsPair('userId', 'user_4821'));
    });
  });
}
