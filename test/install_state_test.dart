@TestOn('vm')
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:strait_sdk/src/core.dart';
import 'package:strait_sdk/strait_sdk.dart';
import 'package:test/test.dart';

// Contract B6a (shared-spec ADR 0003): storage restored from a backup of another install
// (Android Auto Backup, a restored phone) must not skip the once-per-install deferred check.
// Port of sdk-react-native/test/install-state.test.ts. VM only: a web build has no install.

const tOld = 1780000000000;
const tNew = 1790000000000;
const device = DeviceFields(
    screenWidth: 390, pixelRatio: 3, language: 'en', timezone: 'Asia/Kolkata');

/// Fake engine: /v1/match answers [match] (or no answer when [offline]); anything else 202.
class Engine {
  final bool offline;
  final calls = <(String, Map<String, dynamic>?)>[];
  Engine({this.offline = false});

  late final http.Client client = MockClient((req) async {
    final body = req.body.isEmpty ? null : jsonDecode(req.body) as Map<String, dynamic>;
    calls.add((req.url.path, body));
    if (req.url.path == '/v1/match') {
      if (offline) throw http.ClientException('Network request failed');
      return http.Response(jsonEncode({'matched': false}), 200);
    }
    return http.Response(jsonEncode({'ok': true}), 202);
  });

  List<Map<String, dynamic>?> get matches =>
      calls.where((c) => c.$1 == '/v1/match').map((c) => c.$2).toList();
}

Future<List<LinkEvent>> launch(MemoryStore s, Engine e, [Future<int?> Function()? installTime]) async {
  final strait = StraitLinks(
    publishableKey: 'st_pub_test_x',
    endpoint: 'https://links.test',
    platform: 'ios',
    deviceFields: () => device,
    storage: s,
    client: e.client,
    now: () => 1800000000000,
    installTime: installTime,
  );
  final events = <LinkEvent>[];
  strait.onLink.listen(events.add);
  await strait.start();
  await Future<void>.delayed(Duration.zero);
  return events;
}

MemoryStore store([Map<String, String> init = const {}]) => MemoryStore()..data.addAll(init);

void main() {
  test('firstLaunchState: normal launch, SDK upgrade, restored storage, first launch', () {
    expect(firstLaunchState('1', '$tNew', tNew), (firstLaunch: false, clearFlag: false, storeInstallTime: null));
    expect(firstLaunchState('1', null, tNew), (firstLaunch: false, clearFlag: false, storeInstallTime: '$tNew'));
    expect(firstLaunchState('1', '$tOld', tNew), (firstLaunch: true, clearFlag: true, storeInstallTime: '$tNew'));
    expect(firstLaunchState(null, null, tNew), (firstLaunch: true, clearFlag: false, storeInstallTime: '$tNew'));
    expect(firstLaunchState('1', '$tOld', null), (firstLaunch: false, clearFlag: false, storeInstallTime: null));
    expect(firstLaunchState('1', '$tOld', double.nan), (firstLaunch: false, clearFlag: false, storeInstallTime: null));
    expect(firstLaunchState('1', '$tOld', double.infinity), (firstLaunch: false, clearFlag: false, storeInstallTime: null));
  });

  group('start() with installTime (B6a)', () {
    test('storage restored from another install: the deferred check runs again and counts the install', () async {
      final s = store({'strait.deferredChecked': '1', 'strait.installTime': '$tOld'});
      final e = Engine();
      final events = await launch(s, e, () async => tNew);
      expect(e.matches, hasLength(1));
      expect(e.matches.first!['openId'], startsWith('o_'));
      expect(events.map((x) => x.kind), [LinkKind.deferred]);
      expect(s.data['strait.deferredChecked'], '1');
      expect(s.data['strait.installTime'], '$tNew');
      // and only once: the next launch is a normal one
      await launch(s, e, () async => tNew);
      expect(e.matches, hasLength(1));
    });

    test('app updated from an SDK without installTime: adopts the time, no new install', () async {
      final s = store({'strait.deferredChecked': '1'});
      final e = Engine();
      expect(await launch(s, e, () async => tNew), isEmpty);
      expect(e.matches, isEmpty);
      expect(s.data['strait.installTime'], '$tNew');
    });

    test('restored storage + offline first launch: the flag stays cleared, so the next launch retries', () async {
      final s = store({'strait.deferredChecked': '1', 'strait.installTime': '$tOld'});
      await launch(s, Engine(offline: true), () async => tNew);
      expect(s.data['strait.deferredChecked'], '');
      final e = Engine();
      await launch(s, e, () async => tNew);
      expect(e.matches, hasLength(1));
      expect(s.data['strait.deferredChecked'], '1');
    });

    test('installTime missing, throwing or invalid: behaves as before (no reset)', () async {
      for (final it in <Future<int?> Function()?>[
        null,
        () async => throw StateError('no package info'),
        () async => 0,
        () async => -5,
        () async => null,
      ]) {
        final s = store({'strait.deferredChecked': '1', 'strait.installTime': '$tOld'});
        final e = Engine();
        await launch(s, e, it);
        expect(e.matches, isEmpty);
        expect(s.data['strait.installTime'], '$tOld');
      }
    });

    test('a fresh install stores its install time with the flag', () async {
      final s = store();
      final e = Engine();
      await launch(s, e, () async => tNew);
      expect(e.matches, hasLength(1));
      expect(s.data['strait.installTime'], '$tNew');
      expect(s.data['strait.deferredChecked'], '1');
    });
  });
}
