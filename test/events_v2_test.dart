import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:strait_sdk/src/core.dart';
import 'package:strait_sdk/strait_sdk.dart';
import 'package:test/test.dart';

// Contract B13a (shared-spec ADR 0004): trackEvent sends an eventId (the app's order id, else one
// the SDK makes) and keeps events that don't get through in the open-report queue.
// Port of sdk-react-native/test/events-v2.test.ts.

final eventIdRe = RegExp(r'^e_[a-z0-9]+_[a-z0-9]{12}$');
const t = 1800000000000;
const device = DeviceFields(screenWidth: 411, pixelRatio: 2.625, language: 'en', timezone: 'Asia/Kolkata');
const offline = 'offline';

/// Fake engine: per path a status code or [offline] (no answer). Unknown path = 404.
class Engine {
  final Map<String, Object> routes = {'/v1/event': 202, '/v1/open': 202};
  final calls = <(String, Map<String, dynamic>?)>[];

  /// Per path, a reply the test releases later (the status it completes with).
  final Map<String, Future<int>> hold = {};

  late final http.Client client = MockClient((req) async {
    calls.add((req.url.path, req.body.isEmpty ? null : jsonDecode(req.body) as Map<String, dynamic>));
    final held = hold[req.url.path];
    if (held != null) return http.Response('{}', await held);
    final r = routes[req.url.path] ?? 404;
    if (r == offline) throw http.ClientException('Network request failed');
    return http.Response('{}', r as int);
  });

  List<Map<String, dynamic>> get events => calls.where((c) => c.$1 == '/v1/event').map((c) => c.$2!).toList();
  List<Map<String, dynamic>> get opens => calls.where((c) => c.$1 == '/v1/open').map((c) => c.$2!).toList();
}

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class Harness {
  final StraitLinks strait;
  final Engine e;
  final MemoryStore s;
  final StreamController<AppLifecycle> states;
  Harness(this.strait, this.e, this.s, this.states);

  List<dynamic> get queue => jsonDecode(s.data['strait.pendingOpens'] ?? '[]') as List;
}

Future<Harness> make() async {
  final e = Engine();
  final s = MemoryStore()..data['strait.deferredChecked'] = '1';
  final states = StreamController<AppLifecycle>(sync: true);
  final strait = StraitLinks(
    publishableKey: 'st_pub_test_x',
    endpoint: 'https://links.test',
    platform: 'android',
    deviceFields: () => device,
    storage: s,
    client: e.client,
    now: () => t,
  );
  await strait.start(lifecycle: states.stream);
  await settle();
  return Harness(strait, e, s, states);
}

void main() {
  test('newEventId has the engine eventId shape and is unique', () {
    final a = newEventId(t);
    expect(a, matches(eventIdRe));
    expect(a, matches(RegExp(r'^[A-Za-z0-9_.:-]{1,64}$')));
    expect(newEventId(t), isNot(a));
    expect(newEventId(35, () => 0.999), 'e_z_999999999999');
  });

  group('trackEvent v2 (B13a)', () {
    test("sends the app's eventId (order id) as is", () async {
      final h = await make();
      expect(await h.strait.trackEvent('purchase', value: 499, currency: 'INR', eventId: 'ord_1001'), isTrue);
      expect(h.e.events.first, {
        'publishableKey': 'st_pub_test_x',
        'event': 'purchase',
        'platform': 'android',
        'value': 499,
        'currency': 'INR',
        'eventId': 'ord_1001',
      });
    });

    test('makes an eventId when the app gives none', () async {
      final h = await make();
      await h.strait.trackEvent('signup');
      expect(h.e.events.first['eventId'], matches(eventIdRe));
    });

    test('offline: returns false, keeps the event (no key) and sends it with the same eventId later', () async {
      final h = await make();
      h.e.routes['/v1/event'] = offline;
      expect(await h.strait.trackEvent('purchase', value: 5, currency: 'USD', eventId: 'ord_7'), isFalse);
      await settle();
      expect(h.queue, [
        {
          'type': 'event',
          'at': t,
          'event': 'purchase',
          'platform': 'android',
          'eventId': 'ord_7',
          'value': 5,
          'currency': 'USD'
        }
      ]);
      expect(h.s.data['strait.pendingOpens'], isNot(contains('st_pub_')));
      expect(await h.strait.pendingOpenReports(), 1);
      h.e.routes['/v1/event'] = 202;
      h.states.add(AppLifecycle.active);
      await settle();
      expect(h.e.events.last, {
        'publishableKey': 'st_pub_test_x',
        'event': 'purchase',
        'platform': 'android',
        'value': 5,
        'currency': 'USD',
        'eventId': 'ord_7',
      });
      expect(h.e.opens, isEmpty); // never sent as an open report
      expect(h.queue, isEmpty);
    });

    test('5xx and 429 are kept; another 4xx (bad eventId) is not', () async {
      final h = await make();
      h.e.routes['/v1/event'] = 400;
      expect(await h.strait.trackEvent('c', eventId: 'bad id!'), isFalse);
      await settle();
      h.e.routes['/v1/event'] = 503;
      await h.strait.trackEvent('a');
      h.e.routes['/v1/event'] = 429;
      await h.strait.trackEvent('b');
      await settle();
      expect(h.queue.map((q) => q['event']), ['a', 'b']);
    });

    test(
        'a retried event is sent once per flush and dropped after the engine takes it; opens and events share the queue in order',
        () async {
      final h = await make();
      h.e.routes['/v1/event'] = offline;
      await h.strait.trackEvent('purchase', eventId: 'ord_9');
      await settle();
      // An open report saved earlier by the B14 path sits in the same queue.
      h.s.data['strait.pendingOpens'] = jsonEncode([
        {
          'openId': 'o_1_aaaaaaaaaaaa',
          'kind': 'direct',
          'route': 'app_link',
          'appState': 'closed',
          'platform': 'android',
          'matched': true,
          'firstLaunch': false,
          'at': t
        },
        ...h.queue,
      ]);
      h.e.routes['/v1/event'] = 202;
      await h.strait.flushOpenReports();
      expect(h.e.opens.map((b) => b['openId']), ['o_1_aaaaaaaaaaaa']);
      expect(h.e.events.where((b) => b['eventId'] == 'ord_9'), hasLength(2)); // the failed try + one retry
      expect(h.queue, isEmpty);
    });

    test('the tap id is chosen when the app calls, not at retry time', () async {
      final h = await make();
      const tap = '3f2a9c1e-7b4d-4e8a-9c0f-1a2b3c4d5e6f';
      h.s.data['strait.lastTap'] = jsonEncode({'clickId': tap, 'at': t});
      h.e.routes['/v1/event'] = offline;
      await h.strait.trackEvent('purchase', eventId: 'ord_10');
      await settle();
      expect(h.queue.first['clickId'], tap);
    });
  });

  // Opt-out (td2-27) for queued events: nothing saved before the switch goes out later,
  // and nothing in flight at the switch is saved for later.
  group('opt-out and the event queue', () {
    test('events queued before opt-out are deleted and never sent, even after switching back on', () async {
      final h = await make();
      h.e.routes['/v1/event'] = offline;
      await h.strait.trackEvent('purchase', eventId: 'ord_1');
      await h.strait.trackEvent('signup', eventId: 'ord_2');
      await settle();
      expect(h.queue, hasLength(2));
      h.e.routes['/v1/event'] = 202;
      await h.strait.setEnabled(false);
      expect(h.queue, isEmpty);
      h.states.add(AppLifecycle.active); // resume flush while off
      await h.strait.flushOpenReports();
      await settle();
      await h.strait.setEnabled(true); // back on: flushes, but the old events are gone
      h.states.add(AppLifecycle.active);
      await settle();
      expect(h.e.events.map((b) => b['eventId']), ['ord_1', 'ord_2']); // only the first, failed tries
    });

    test('an event in flight when the person opts out is not kept when it fails', () async {
      final h = await make();
      final reply = Completer<int>();
      h.e.hold['/v1/event'] = reply.future;
      final sent = h.strait.trackEvent('purchase', eventId: 'ord_3');
      await settle();
      await h.strait.setEnabled(false);
      reply.complete(503);
      expect(await sent, isFalse);
      await settle();
      expect(h.queue, isEmpty);
      h.e.hold.clear();
      await h.strait.setEnabled(true);
      await settle();
      expect(h.e.events, hasLength(1)); // the one try before the switch, never retried
    });

    test('a flush running when the person opts out sends nothing more and the rest is deleted', () async {
      final h = await make();
      h.s.data['strait.pendingOpens'] = jsonEncode([
        for (final id in ['ord_4', 'ord_5', 'ord_6'])
          {'type': 'event', 'at': t, 'event': 'purchase', 'platform': 'android', 'eventId': id},
      ]);
      final reply = Completer<int>();
      h.e.hold['/v1/event'] = reply.future;
      final flush = h.strait.flushOpenReports();
      await settle();
      final off = h.strait.setEnabled(false);
      await settle();
      reply.complete(202); // the first one was already on the wire
      await flush;
      await off;
      expect(h.e.events.map((b) => b['eventId']), ['ord_4']);
      expect(h.queue, isEmpty);
      h.e.hold.clear();
      await h.strait.setEnabled(true);
      await settle();
      expect(h.e.events.map((b) => b['eventId']), ['ord_4']);
    });
  });
}
