/// Pure, platform-free link logic — a 1:1 port of
/// `sdk-react-native/src/core.ts`. `test/conformance-vectors.json` is the
/// cross-language contract (see `shared-spec/SDK-CONTRACT.md`).
library;

import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:math' show Random;

/// How the app received a link.
enum LinkRoute {
  appLink('app_link'),
  customScheme('custom_scheme'),
  installReferrer('install_referrer'),
  fingerprint('fingerprint');

  const LinkRoute(this.value);

  /// Wire name, identical across SDKs.
  final String value;
}

/// What the app was doing when the link arrived.
enum AppStateAtLink { closed, background, foreground }

/// App lifecycle as the SDK sees it. Map Flutter's `AppLifecycleState`:
/// resumed → active, inactive → inactive, hidden/paused/detached → background.
enum AppLifecycle { active, background, inactive }

/// Screen width as a browser reports it (`screen.width`). Chrome rounds
/// fractional logical widths UP (1080 px at 2.625 = 411.43 → 412). Matching
/// needs the app and the browser at the tap to agree. (B2)
int browserScreenWidth(num logicalWidth) => (logicalWidth - 0.001).ceil();

class SplitUrl {
  final String scheme;
  final String host;
  final String path;
  final Map<String, String> params;

  const SplitUrl({
    required this.scheme,
    required this.host,
    required this.path,
    required this.params,
  });
}

final _urlRe = RegExp(
  r'^([a-z][a-z0-9+.-]*):\/\/([^/?#]*)([^?#]*)(?:\?([^#]*))?',
  caseSensitive: false,
);
final _schemeRe = RegExp(r'^[a-z][a-z0-9+.-]*:\/\/', caseSensitive: false);

/// Split a URL without relying on `Uri` (whose semantics differ). Scheme and
/// host are lower-cased; '+' and %-escapes in the query are decoded; fragment
/// dropped; empty path is '/'; a key without '=' maps to ''. (B12)
SplitUrl? splitUrl(String u) {
  final m = _urlRe.firstMatch(u.trim());
  if (m == null) return null;
  final params = <String, String>{};
  for (final pair in (m.group(4) ?? '').split('&')) {
    if (pair.isEmpty) continue;
    final i = pair.indexOf('=');
    final k = i < 0 ? pair : pair.substring(0, i);
    final v = i < 0 ? '' : pair.substring(i + 1);
    params[_decode(k)] = _decode(v);
  }
  final path = m.group(3)!;
  return SplitUrl(
    scheme: m.group(1)!.toLowerCase(),
    host: m.group(2)!.toLowerCase(),
    path: path.isEmpty ? '/' : path,
    params: params,
  );
}

String _decode(String s) {
  try {
    return Uri.decodeComponent(s.replaceAll('+', ' '));
  } catch (_) {
    return s;
  }
}

/// The hosts that serve this app's short links: the endpoint's host plus any
/// configured link domains, given as URLs (`https://go.brand.com`) or bare
/// hosts (`go.brand.com`). Lower-cased, de-duplicated, order kept; anything
/// else (blank, paths, spaces) is ignored.
List<String> normalizeLinkHosts(String endpoint, [List<String> linkHosts = const []]) {
  final out = <String>[];
  final bare = RegExp(r'^[a-z0-9.-]+(:\d+)?$', caseSensitive: false);
  for (final h in [endpoint, ...linkHosts]) {
    final t = h.trim();
    final host = splitUrl(h)?.host ?? (bare.hasMatch(t) ? t.toLowerCase() : null);
    if (host != null && !out.contains(host)) out.add(host);
  }
  return out;
}

/// The `strait_link` id inside a Play Install Referrer string, or null.
String? parseStraitLink(String? referrer) => _referrerParam(referrer, 'strait_link');

/// The tap id (`strait_click`) inside a Play Install Referrer string, or null.
/// Joins the install to the exact tap that sent the user to the store.
String? parseStraitClick(String? referrer) {
  final v = _referrerParam(referrer, 'strait_click');
  return v != null && _clickIdRe.hasMatch(v) ? v : null;
}

String? _referrerParam(String? referrer, String key) {
  if (referrer == null || referrer.isEmpty) return null;
  for (final pair in referrer.split('&')) {
    final i = pair.indexOf('=');
    if (i < 0 || pair.substring(0, i) != key) continue;
    final v = _decode(pair.substring(i + 1));
    return v.isEmpty ? null : v;
  }
  return null;
}

/// A tap id as Strait issues it (uuid); anything else is ignored.
final _clickIdRe = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// Result of [takeClickId].
class ClickIdResult {
  final String url;
  final String? clickId;
  const ClickIdResult(this.url, this.clickId);
}

/// Remove every `strait_click` parameter from a URL's query, keeping the rest
/// of the URL byte-for-byte (fragment included). Returns the cleaned URL and
/// the tap id (null when absent or malformed). The app never sees the tap id.
ClickIdResult takeClickId(String raw) {
  final s = raw.trim();
  final hash = s.indexOf('#');
  final beforeHash = hash < 0 ? s : s.substring(0, hash);
  final frag = hash < 0 ? '' : s.substring(hash);
  final q = beforeHash.indexOf('?');
  if (q < 0) return ClickIdResult(s, null);
  String? clickId;
  final kept = beforeHash.substring(q + 1).split('&').where((pair) {
    final i = pair.indexOf('=');
    if (_decode(i < 0 ? pair : pair.substring(0, i)) != 'strait_click') return true;
    final v = _decode(i < 0 ? '' : pair.substring(i + 1));
    if (_clickIdRe.hasMatch(v)) clickId = v.toLowerCase();
    return false;
  }).toList();
  final query = kept.join('&');
  return ClickIdResult(
      beforeHash.substring(0, q) + (query.isEmpty ? '' : '?$query') + frag, clickId);
}

/// Result of [classifyUrl]. When [needsResolve] is true the URL is a short
/// link and [url]/[path]/[params]/[clickId] are null.
class ClassifiedUrl {
  final LinkRoute route;
  final bool needsResolve;
  final String? url;
  final String? path;
  final Map<String, String>? params;

  /// Tap id from a Strait hand-off (removed from url/params), else null.
  final String? clickId;

  const ClassifiedUrl._(this.route, this.needsResolve, this.url, this.path, this.params,
      [this.clickId]);
}

/// What a URL handed to the app means (B3, B4):
/// - https on a Strait link host → a short link; ask /v1/resolve.
/// - other https → it IS the destination.
/// - yourapp://host/path (browser hand-off) → destination https://host/path.
/// A `strait_click` tap id is removed from the destination and returned apart.
/// Returns null for anything that isn't a URL.
ClassifiedUrl? classifyUrl(String raw, List<String> linkHosts) {
  final p0 = splitUrl(raw);
  if (p0 == null) return null;
  final isWeb = p0.scheme == 'https' || p0.scheme == 'http';
  if (isWeb && linkHosts.map((h) => h.toLowerCase()).contains(p0.host)) {
    return const ClassifiedUrl._(LinkRoute.appLink, true, null, null, null);
  }
  final t = takeClickId(raw);
  final p = splitUrl(t.url)!;
  final url = isWeb ? t.url : t.url.replaceFirst(_schemeRe, 'https://');
  return ClassifiedUrl._(
    isWeb ? LinkRoute.appLink : LinkRoute.customScheme,
    false,
    url,
    p.path,
    p.params,
    t.clickId,
  );
}

/// Open reports waiting to be sent are kept at most this long…
const openQueueMaxAgeMs = 7 * 24 * 60 * 60 * 1000;

/// …and at most this many (oldest dropped first).
const openQueueMax = 100;

/// Prune a pending-report queue: drop reports older than [openQueueMaxAgeMs]
/// (by their `at`), then keep the newest [openQueueMax]. Order is kept.
List<Map<String, dynamic>> pruneOpenQueue(List<Map<String, dynamic>> queue, int now) {
  final fresh = queue.where((r) => now - (r['at'] as num) <= openQueueMaxAgeMs).toList();
  return fresh.length > openQueueMax ? fresh.sublist(fresh.length - openQueueMax) : fresh;
}

/// Conversion events carry the tap id of the most recent attributed link
/// open for this long (contract B15).
const attributionWindowMs = 7 * 24 * 60 * 60 * 1000;

/// Storage value for the remembered tap (key `strait.lastTap`):
/// `{"clickId":…,"at":<epoch ms>}`.
String rememberTap(String clickId, int at) =>
    jsonEncode({'clickId': clickId.toLowerCase(), 'at': at});

/// The `clickId` a conversion event sends (contract B15): a non-empty
/// [explicit] wins; otherwise the remembered tap ([stored], see [rememberTap])
/// when it is a valid tap id opened at most [attributionWindowMs] before
/// [now] (and not after it). Anything unreadable means no tap.
String? eventClickId(String? stored, int now, [String? explicit]) {
  if (explicit != null && explicit.isNotEmpty) return explicit;
  if (stored == null || stored.isEmpty) return null;
  Object? tap;
  try {
    tap = jsonDecode(stored);
  } catch (_) {
    return null;
  }
  if (tap is! Map) return null;
  final clickId = tap['clickId'];
  final at = tap['at'];
  if (clickId is! String || !_clickIdRe.hasMatch(clickId)) return null;
  if (at is! num || !at.isFinite) return null;
  final age = now - at;
  return age >= 0 && age <= attributionWindowMs ? clickId.toLowerCase() : null;
}

/// The tap id to remember after an attributed open the engine answered
/// (contract B16): the reply's `clickId` when it is a valid tap id
/// (lower-cased); else [fallback] when valid (a tap id the SDK already knew,
/// e.g. the Play referrer's — so an older engine that returns none keeps B15);
/// else null, which forgets the remembered tap (the newer touch wins).
String? replyClickId(Object? reply, [String? fallback]) {
  if (reply is String && _clickIdRe.hasMatch(reply)) return reply.toLowerCase();
  if (fallback != null && _clickIdRe.hasMatch(fallback)) return fallback.toLowerCase();
  return null;
}

/// Whether a failed report should be kept for retry: no answer, 429 or 5xx.
bool shouldRetryReport(int? status) => status == null || status == 429 || status >= 500;

final _rng = Random();

/// A unique id for one link open (the engine de-duplicates retries by it).
String newOpenId(int now, [double Function()? random]) {
  final next = random ?? _rng.nextDouble;
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final r = StringBuffer();
  for (var i = 0; i < 12; i++) {
    r.write(chars[(next() * 36).floor()]);
  }
  return 'o_${now.toRadixString(36)}_$r';
}

/// A link arriving this soon after the app came back to the front came "from background".
const resumeWindowMs = 2000;

/// Pauses shorter than this are Android delivering the link, not the user leaving.
const transientPauseMs = 1000;

/// Tracks app lifecycle to label a link delivered while the app is running
/// (B5). Android wraps link delivery in a brief pause/resume, and the link can
/// arrive before or after the resume: a pause under [transientPauseMs] is that
/// delivery (app was on screen); a longer one means the user had left.
class AppStateTracker {
  AppLifecycle _state = AppLifecycle.active;
  double _backgroundAt = double.negativeInfinity;
  double _resumeAt = double.negativeInfinity;
  double _backgroundFor = 0;

  void onState(AppLifecycle s, int now) {
    if (s != AppLifecycle.active && _state == AppLifecycle.active) {
      _backgroundAt = now.toDouble();
    }
    if (s == AppLifecycle.active && _state != AppLifecycle.active) {
      _resumeAt = now.toDouble();
      _backgroundFor = now - _backgroundAt;
    }
    _state = s;
  }

  /// Label for a link delivered (while running) at [now].
  AppStateAtLink classify(int now) {
    double? away;
    if (_state != AppLifecycle.active) {
      away = now - _backgroundAt;
    } else if (now - _resumeAt <= resumeWindowMs) {
      away = _backgroundFor;
    }
    return away != null && away >= transientPauseMs
        ? AppStateAtLink.background
        : AppStateAtLink.foreground;
  }
}
