import 'dart:convert';
import 'package:http/http.dart' as http;

import 'core.dart';

export 'core.dart' show parseStraitLink;

/// Coarse, privacy-clean device fields the server hashes into a match signature.
/// (The server adds the IP it observes; the client never sends one.)
class DeviceFields {
  final int screenWidth;
  final num pixelRatio;
  final String language;
  final String timezone;

  const DeviceFields({
    required this.screenWidth,
    required this.pixelRatio,
    required this.language,
    required this.timezone,
  });

  Map<String, dynamic> toJson() => {
        'screenWidth': screenWidth,
        'pixelRatio': pixelRatio,
        'language': language,
        'timezone': timezone,
      };
}

class MatchResult {
  final bool matched;
  final String? longUrl;
  final String? linkId;

  /// install_referrer | exact_ext | exact_core | none
  final String matchMethod;

  const MatchResult({
    required this.matched,
    required this.matchMethod,
    this.longUrl,
    this.linkId,
  });

  static const none = MatchResult(matched: false, matchMethod: 'none');

  factory MatchResult.fromJson(Map<String, dynamic> j) => MatchResult(
        matched: j['matched'] == true,
        matchMethod: (j['matchMethod'] as String?) ?? 'none',
        longUrl: j['longUrl'] as String?,
        linkId: j['linkId'] as String?,
      );
}

/// Resolve the deferred deep link this device clicked before installing.
///   • Android with a `strait_link` install referrer → /v1/referrer (exact).
///   • otherwise → /v1/match (fingerprint).
/// [publishableKey] is your workspace publishable key (`st_pub_live_…` or
/// `st_pub_test_…`) from Dashboard → Get started. It is safe to ship in apps;
/// never pass your secret key (`st_live_…`).
/// Never throws; returns [MatchResult.none] on any error.
Future<MatchResult> resolveDeferredLink({
  required String publishableKey,
  required String endpoint,
  required String platform,
  required DeviceFields device,
  String? installReferrer,
  http.Client? client,
}) async {
  final ownsClient = client == null;
  final c = client ?? http.Client();
  final base = endpoint.replaceAll(RegExp(r'/+$'), '');

  Future<MatchResult> post(String path, Map<String, dynamic> body) async {
    try {
      final res = await c.post(
        Uri.parse('$base$path'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
      if (res.statusCode < 200 || res.statusCode >= 300) return MatchResult.none;
      return MatchResult.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    } catch (_) {
      return MatchResult.none;
    }
  }

  try {
    if (platform == 'android') {
      final linkId = parseStraitLink(installReferrer);
      if (linkId != null) {
        final r = await post('/v1/referrer', {
          'publishableKey': publishableKey,
          'linkId': linkId,
          'platform': platform,
        });
        if (r.matched) return r;
      }
    }
    return await post('/v1/match', {
      'publishableKey': publishableKey,
      'platform': platform,
      ...device.toJson(),
    });
  } finally {
    if (ownsClient) c.close();
  }
}
