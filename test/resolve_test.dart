import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:strait_sdk/src/strait.dart';

const key = 'st_pub_test_0123456789abcdef0123456789abcdef';

const device = DeviceFields(
  screenWidth: 393,
  pixelRatio: 3,
  language: 'en-IN',
  timezone: 'Asia/Kolkata',
);

void main() {
  group('parseStraitLink', () {
    test('extracts strait_link from a referrer', () {
      expect(parseStraitLink('utm_source=x&strait_link=lnk_42'), equals('lnk_42'));
    });
    test('null when absent', () {
      expect(parseStraitLink('utm_source=x'), isNull);
      expect(parseStraitLink(null), isNull);
      expect(parseStraitLink(''), isNull);
    });
  });

  group('resolveDeferredLink — Android deterministic', () {
    test('uses /v1/referrer when referrer carries a strait_link', () async {
      late Uri called;
      late Map<String, dynamic> body;
      final client = MockClient((req) async {
        called = req.url;
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({'matched': true, 'longUrl': 'https://app/x', 'matchMethod': 'install_referrer'}),
          200,
        );
      });
      final r = await resolveDeferredLink(
        publishableKey: key,
        endpoint: 'https://go.example.com/',
        platform: 'android',
        device: device,
        installReferrer: 'strait_link=lnk_42',
        client: client,
      );
      expect(r.matchMethod, equals('install_referrer'));
      expect(called.path, equals('/v1/referrer'));
      expect(body['publishableKey'], equals(key));
      expect(body.containsKey('appId'), isFalse);
      expect(body['linkId'], equals('lnk_42'));
    });

    test('falls back to /v1/match when referrer lookup misses', () async {
      final paths = <String>[];
      final client = MockClient((req) async {
        paths.add(req.url.path);
        if (req.url.path == '/v1/referrer') {
          return http.Response(jsonEncode({'matched': false, 'matchMethod': 'none'}), 200);
        }
        return http.Response(
          jsonEncode({'matched': true, 'longUrl': 'https://app/y', 'matchMethod': 'exact_ext'}),
          200,
        );
      });
      final r = await resolveDeferredLink(
        publishableKey: key,
        endpoint: 'https://go.example.com',
        platform: 'android',
        device: device,
        installReferrer: 'strait_link=lnk_x',
        client: client,
      );
      expect(r.matchMethod, equals('exact_ext'));
      expect(paths, equals(['/v1/referrer', '/v1/match']));
    });
  });

  group('resolveDeferredLink — iOS fingerprint', () {
    test('posts device fields + publishableKey to /v1/match', () async {
      late Map<String, dynamic> body;
      final client = MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({'matched': true, 'longUrl': 'https://app/z', 'matchMethod': 'exact_ext'}),
          200,
        );
      });
      final r = await resolveDeferredLink(
        publishableKey: key,
        endpoint: 'https://go.example.com',
        platform: 'ios',
        device: device,
        client: client,
      );
      expect(r.longUrl, equals('https://app/z'));
      expect(body['publishableKey'], equals(key));
      expect(body.containsKey('appId'), isFalse);
      expect(body['platform'], equals('ios'));
      expect(body['screenWidth'], equals(393));
    });

    test('never throws on network error', () async {
      final client = MockClient((_) async => throw Exception('offline'));
      final r = await resolveDeferredLink(
        publishableKey: key,
        endpoint: 'https://go.example.com',
        platform: 'ios',
        device: device,
        client: client,
      );
      expect(r.matched, isFalse);
      expect(r.matchMethod, equals('none'));
    });
  });
}
