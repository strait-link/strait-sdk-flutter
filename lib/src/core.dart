/// Pure, platform-free link logic — a 1:1 port of
/// `sdk-react-native/src/core.ts`. `test/conformance-vectors.json` is the
/// cross-language contract (see `shared-spec/SDK-CONTRACT.md`).
library;

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
String? parseStraitLink(String? referrer) {
  if (referrer == null || referrer.isEmpty) return null;
  for (final pair in referrer.split('&')) {
    final i = pair.indexOf('=');
    if (i < 0 || pair.substring(0, i) != 'strait_link') continue;
    final v = _decode(pair.substring(i + 1));
    return v.isEmpty ? null : v;
  }
  return null;
}

/// Result of [classifyUrl]. When [needsResolve] is true the URL is a short
/// link and [url]/[path]/[params] are null.
class ClassifiedUrl {
  final LinkRoute route;
  final bool needsResolve;
  final String? url;
  final String? path;
  final Map<String, String>? params;

  const ClassifiedUrl._(this.route, this.needsResolve, this.url, this.path, this.params);
}

/// What a URL handed to the app means (B3, B4):
/// - https on a Strait link host → a short link; ask /v1/resolve.
/// - other https → it IS the destination.
/// - yourapp://host/path (browser hand-off) → destination https://host/path.
/// Returns null for anything that isn't a URL.
ClassifiedUrl? classifyUrl(String raw, List<String> linkHosts) {
  final p = splitUrl(raw);
  if (p == null) return null;
  final isWeb = p.scheme == 'https' || p.scheme == 'http';
  if (isWeb && linkHosts.map((h) => h.toLowerCase()).contains(p.host)) {
    return const ClassifiedUrl._(LinkRoute.appLink, true, null, null, null);
  }
  final url = isWeb ? raw.trim() : raw.trim().replaceFirst(_schemeRe, 'https://');
  return ClassifiedUrl._(
    isWeb ? LinkRoute.appLink : LinkRoute.customScheme,
    false,
    url,
    p.path,
    p.params,
  );
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
