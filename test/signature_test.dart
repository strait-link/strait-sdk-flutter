import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:strait_sdk/src/signature.dart';

/// Cross-language parity: the SAME golden vectors the server, sdk-web, and
/// sdk-react-native assert against. If Dart drifts from JS here, deferred match
/// breaks silently — so this is the contract.
void main() {
  final vectors = jsonDecode(
    File('test/signature-vectors.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  group('h32 — golden vectors', () {
    for (final v in vectors['h32'] as List) {
      final input = v['input'] as String;
      final expected = v['expected'] as String;
      test('h32(${jsonEncode(input)})', () {
        expect(h32(input), equals(expected));
      });
    }
  });

  group('computeSignature — golden vectors', () {
    for (final v in vectors['signatures'] as List) {
      final name = v['name'] as String;
      final input = v['input'] as Map<String, dynamic>;
      final expected = v['expected'] as Map<String, dynamic>;
      test(name, () {
        final sig = computeSignature(SignatureInputs(
          screenWidth: input['screenWidth'] as num,
          pixelRatio: input['pixelRatio'] as num,
          language: input['language'] as String,
          ip: input['ip'] as String,
          timezone: input['timezone'] as String,
        ));
        expect(sig.coreRaw, equals(expected['coreRaw']));
        expect(sig.extRaw, equals(expected['extRaw']));
        expect(sig.coreHash, equals(expected['coreHash']));
        expect(sig.extHash, equals(expected['extHash']));
      });
    }
  });

  group('numStr — JS String(Number) parity', () {
    test('whole numbers have no trailing .0', () {
      expect(numStr(3), equals('3'));
      expect(numStr(3.0), equals('3'));
      expect(numStr(1176), equals('1176'));
    });
    test('fractional kept minimal', () {
      expect(numStr(2.625), equals('2.625'));
      expect(numStr(2.75), equals('2.75'));
    });
  });

  group('regionFromTimezone', () {
    test('legacy Calcutta alias maps to IN', () {
      expect(regionFromTimezone('Asia/Calcutta'), equals('IN'));
      expect(regionFromTimezone('Asia/Kolkata'), equals('IN'));
    });
    test('unknown timezone is XX', () {
      expect(regionFromTimezone('Antarctica/Troll'), equals('XX'));
    });
  });
}
