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
    expect(openQueueMax, c['OPEN_QUEUE_MAX']);
    expect(openQueueMaxAgeMs, c['OPEN_QUEUE_MAX_AGE_MS']);
    expect(attributionWindowMs, c['ATTRIBUTION_WINDOW_MS']);
    expect(c.keys, unorderedEquals([
      'RESUME_WINDOW_MS', 'TRANSIENT_PAUSE_MS', 'OPEN_QUEUE_MAX', 'OPEN_QUEUE_MAX_AGE_MS',
      'ATTRIBUTION_WINDOW_MS'
    ]));
  });

  group('eventClickId (B15)', () {
    for (final c in v['eventClickId'] as List) {
      test('${c['name']}', () {
        expect(eventClickId(c['stored'] as String?, c['now'] as int, c['explicit'] as String?),
            c['expected']);
      });
    }
  });

  group('replyClickId (B16)', () {
    for (final c in v['replyClickId'] as List) {
      test('${c['name']}', () {
        expect(replyClickId(c['reply'], c['fallback'] as String?), c['expected']);
      });
    }
  });

  group('parseHandoffUrl (B19)', () {
    for (final c in v['parseHandoffUrl'] as List) {
      test('${c['name']}', () {
        expect(parseHandoffUrl(c['text'] as String?, (c['linkHosts'] as List).cast<String>()),
            c['expected']);
      });
    }
  });

  group('reportUrl (B18)', () {
    for (final c in v['reportUrl'] as List) {
      test(jsonEncode(c['input']), () {
        expect(reportUrl(c['input'] as String), c['expected']);
      });
    }
  });

  group('staleTap (B18)', () {
    for (final c in v['staleTap'] as List) {
      test('${c['name']}', () {
        expect(staleTap(c['stored'] as String?, c['now'] as int), c['expected']);
      });
    }
  });

  group('browserScreenWidth', () {
    for (final c in v['screenWidth'] as List) {
      test('${c['logical']}', () {
        expect(browserScreenWidth(c['logical'] as num), c['expected']);
      });
    }
  });

  group('portraitScreenWidth', () {
    for (final c in v['portraitScreenWidth'] as List) {
      test('${c['width']}x${c['height']}', () {
        expect(portraitScreenWidth(c['width'] as num, c['height'] as num), c['expected']);
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

  group('parseStraitClick', () {
    for (final c in v['referrerClick'] as List) {
      test(jsonEncode(c['input']), () {
        expect(parseStraitClick(c['input'] as String?), c['expected']);
      });
    }
  });

  group('takeClickId', () {
    for (final c in v['takeClickId'] as List) {
      test(c['input'], () {
        final r = takeClickId(c['input'] as String);
        expect({'url': r.url, 'clickId': r.clickId}, c['expected']);
      });
    }
  });

  group('pruneOpenQueue', () {
    for (final c in v['openQueue'] as List) {
      test(c['name'], () {
        final queue = (c['queue'] as List).cast<Map<String, dynamic>>();
        expect(pruneOpenQueue(queue, c['now'] as int).map((r) => r['openId']).toList(),
            c['expected']);
      });
    }
  });

  group('shouldRetryReport', () {
    for (final c in v['retry'] as List) {
      test('${c['status']}', () {
        expect(shouldRetryReport(c['status'] as int?), c['expected']);
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
                if (!r.needsResolve)
                  ...{'url': r.url, 'path': r.path, 'params': r.params, 'clickId': r.clickId},
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
