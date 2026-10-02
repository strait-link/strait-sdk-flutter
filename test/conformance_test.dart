import 'dart:convert';
import 'dart:io';

import 'package:strait_sdk/strait_sdk.dart';
import 'package:test/test.dart';

/// Cross-language contract: the same conformance vectors every Strait SDK
/// asserts (generated from sdk-react-native/src/core.ts).
void main() {
  final v = jsonDecode(File('test/conformance-vectors.json').readAsStringSync())
      as Map<String, dynamic>;

  test('constants', () {
    final c = v['constants'] as Map<String, dynamic>;
    expect(resumeWindowMs, c['RESUME_WINDOW_MS']);
    expect(transientPauseMs, c['TRANSIENT_PAUSE_MS']);
  });

  group('browserScreenWidth', () {
    for (final c in v['screenWidth'] as List) {
      test('${c['logical']}', () {
        expect(browserScreenWidth(c['logical'] as num), c['expected']);
      });
    }
  });

  Map<String, dynamic>? splitJson(SplitUrl? s) => s == null
      ? null
      : {'scheme': s.scheme, 'host': s.host, 'path': s.path, 'params': s.params};

  group('splitUrl', () {
    for (final c in v['splitUrl'] as List) {
      test(jsonEncode(c['input']), () {
        expect(splitJson(splitUrl(c['input'] as String)), c['expected']);
      });
    }
  });

  group('normalizeLinkHosts', () {
    for (final c in v['linkHosts'] as List) {
      test('${c['endpoint']} + ${jsonEncode(c['linkHosts'])}', () {
        expect(
          normalizeLinkHosts(c['endpoint'] as String, (c['linkHosts'] as List).cast<String>()),
          c['expected'],
        );
      });
    }
  });

  group('parseStraitLink', () {
    for (final c in v['referrer'] as List) {
      test(jsonEncode(c['input']), () {
        expect(parseStraitLink(c['input'] as String?), c['expected']);
      });
    }
  });

  group('classifyUrl', () {
    for (final c in v['classify'] as List) {
      test(c['raw'], () {
        final r = classifyUrl(c['raw'] as String, (c['linkHosts'] as List).cast<String>());
        final got = r == null
            ? null
            : {
                'route': r.route.value,
                'needsResolve': r.needsResolve,
                if (!r.needsResolve) ...{'url': r.url, 'path': r.path, 'params': r.params},
              };
        expect(got, c['expected']);
      });
    }
  });

  group('AppStateTracker', () {
    for (final c in v['appState'] as List) {
      test(c['name'], () {
        final t = AppStateTracker();
        final labels = <String>[];
        for (final step in c['steps'] as List) {
          if (step[0] == 'state') {
            t.onState(AppLifecycle.values.byName(step[1] as String), step[2] as int);
          } else {
            labels.add(t.classify(step[1] as int).name);
          }
        }
        expect(labels, c['expected']);
      });
    }
  });
}
