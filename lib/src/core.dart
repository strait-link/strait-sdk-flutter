/// Pure, platform-free link logic — a 1:1 port of
/// `sdk-react-native/src/core.ts`. `test/conformance-vectors.json` is the
/// cross-language contract (see `shared-spec/SDK-CONTRACT.md`).
library;

import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:math' show Random, max, min;

/// How the app received a link.
enum LinkRoute {
  appLink('app_link'),
  customScheme('custom_scheme'),
  installReferrer('install_referrer'),
  fingerprint('fingerprint'),
  clipboard('clipboard');

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

/// The `screenWidth` device field (B17): the screen's SHORTER side, as a
/// browser reports it. Safari's `screen.width` at the tap is the portrait width
/// whatever the orientation, so an app first launched in landscape (844×390)
/// still reports 390.
int portraitScreenWidth(num logicalWidth, num logicalHeight) =>
    browserScreenWidth(logicalWidth < logicalHeight ? logicalWidth : logicalHeight);

/// The `deviceClass` sent with open reports and the store sheet (contract B14,
/// engine ADR 0039), from the screen's shorter side in logical pixels:
/// `'tablet'` from 600 (Android's sw600dp rule), else `'phone'`; null when
/// unknown (0, negative, NaN). In Flutter:
/// `deviceClassForSize(view.physicalSize.shortestSide / view.devicePixelRatio)`.
String? deviceClassForSize(num shortestSide) {
  if (!shortestSide.isFinite || shortestSide <= 0) return null;
  return shortestSide >= 600 ? 'tablet' : 'phone';
}

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
/// configured link domains, given as URLs (`https://go.hilltop.example`) or bare
/// hosts (`go.hilltop.example`). Lower-cased, de-duplicated, order kept; anything
/// else (blank, paths, spaces) is ignored.
List<String> normalizeLinkHosts(String endpoint, [List<String> linkHosts = const []]) {
  final out = <String>[];
  for (final h in [endpoint, ...linkHosts]) {
    final t = h.trim();
    final host = _schemeHost(t) ?? (_isBareHost(t) ? t.toLowerCase() : null);
    if (host != null && !out.contains(host)) out.add(host);
  }
  return out;
}

// normalizeLinkHosts and trimTrailingSlashes run in the StraitLinks constructor, on the UI isolate
// at app start. An isolate's first RegExp costs ~0.2-0.5 ms, so these are plain ASCII scans with
// the same rules as the regexes they replace (H3).
bool _asciiLetter(int c) => (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7a;
bool _asciiDigit(int c) => c >= 0x30 && c <= 0x39;

/// `splitUrl(u)?.host`: the lower-cased host of `scheme://host…`, or null when `u` has no scheme.
String? _schemeHost(String u) {
  if (u.isEmpty || !_asciiLetter(u.codeUnitAt(0))) return null;
  var i = 1;
  while (i < u.length && (_asciiLetter(u.codeUnitAt(i)) || _asciiDigit(u.codeUnitAt(i)) || '+.-'.contains(u[i]))) {
    i++;
  }
  if (!u.startsWith('://', i)) return null;
  var end = i + 3;
  while (end < u.length && !'/?#'.contains(u[end])) {
    end++;
  }
  return u.substring(i + 3, end).toLowerCase();
}

/// `^[a-z0-9.-]+(:\d+)?$`, case-insensitive.
bool _isBareHost(String t) {
  var i = 0;
  while (i < t.length && (_asciiLetter(t.codeUnitAt(i)) || _asciiDigit(t.codeUnitAt(i)) || t[i] == '.' || t[i] == '-')) {
    i++;
  }
  if (i == 0) return false;
  if (i == t.length) return true;
  if (t[i] != ':' || i + 1 == t.length) return false;
  for (var j = i + 1; j < t.length; j++) {
    if (!_asciiDigit(t.codeUnitAt(j))) return false;
  }
  return true;
}

/// `s.replaceAll(RegExp(r'/+$'), '')`.
String trimTrailingSlashes(String s) {
  var end = s.length;
  while (end > 0 && s.codeUnitAt(end - 1) == 0x2f) {
    end--;
  }
  return s.substring(0, end);
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

/// The deep link inside an old Firebase Dynamic Links long link (contract B22):
/// `https://<x>.page.link/?link=<url>&…` → `<url>`. Only on a `*.page.link`
/// host, only at the root path, only when `link` is an absolute http(s) URL with
/// a host. Anything else → null (a page.link short link is resolved by the engine).
String? pageLinkLongLink(SplitUrl p) {
  if (!p.host.endsWith('.page.link') || (p.path != '/' && p.path != '')) return null;
  final link = p.params['link'];
  if (link == null || link.isEmpty) return null;
  final inner = splitUrl(link);
  if (inner == null || (inner.scheme != 'https' && inner.scheme != 'http') || inner.host.isEmpty) {
    return null;
  }
  return link.trim();
}

/// What a URL handed to the app means (B3, B4, B22):
/// - https on a Strait link host → a short link; ask /v1/resolve (web: /v1/lookup). Except an
///   FDL long link on a `*.page.link` link host (B22): its `link=` value IS the
///   destination, read on the device with no network call.
/// - other https → it IS the destination.
/// - yourapp://host/path (browser hand-off) → destination https://host/path.
/// A `strait_click` tap id is removed from the destination and returned apart.
/// Returns null for anything that isn't a URL.
ClassifiedUrl? classifyUrl(String raw, List<String> linkHosts) {
  final p0 = splitUrl(raw);
  if (p0 == null) return null;
  final isWeb = p0.scheme == 'https' || p0.scheme == 'http';
  if (isWeb && linkHosts.map((h) => h.toLowerCase()).contains(p0.host)) {
    final long = pageLinkLongLink(p0);
    if (long != null) {
      final inner = classifyUrl(long, const []);
      if (inner != null && !inner.needsResolve) {
        return ClassifiedUrl._(
            LinkRoute.appLink, false, inner.url, inner.path, inner.params, inner.clickId);
      }
    }
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

/// This SDK's version, sent as `sdkVersion` = `flutter/<it>` with every open and install report
/// (td2-23, B25). Kept equal to pubspec.yaml's `version` by a test.
const String straitSdkVersion = '0.10.8';

/// The longest Play install referrer the engine reads (engine ADR 0106); a longer one is not sent.
const int installReferrerMax = 4096;

/// B26: the raw Play install referrer as sent in `installReferrer` on the calls that record the install: the
/// string itself when 1..4096 characters, else null (not sent). The engine keeps only its five utm_* tags.
String? installReferrerField(String? referrer) =>
    referrer != null && referrer.isNotEmpty && referrer.length <= installReferrerMax ? referrer : null;

/// `appVersion` + `sdkVersion` for a call that records an open or install (td2-23). The engine
/// keeps 1-64 printable ASCII and drops anything else; the app version gets the same rule here:
/// trimmed and capped at 64, else left out.
Map<String, String> versionFields(String? appVersion) {
  var v = appVersion?.trim() ?? '';
  if (v.length > 64) v = v.substring(0, 64).trimRight();
  return {
    if (v.isNotEmpty && RegExp(r'^[\x20-\x7E]+$').hasMatch(v)) 'appVersion': v,
    // B25 (shared-spec ADR 0007): the SDK names itself, so the engine can tell it from Android/Swift with the same number.
    'sdkVersion': 'flutter/$straitSdkVersion',
  };
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

/// True when the remembered tap ([stored], see [rememberTap]) is set but can
/// no longer be used: unreadable, malformed, or opened more than
/// [attributionWindowMs] before [now] (or after it). The SDK then deletes it
/// instead of keeping it on the device (contract B18).
bool staleTap(String? stored, int now) =>
    stored != null && stored.isNotEmpty && eventClickId(stored, now) == null;

/// The URL an SDK reports to the engine (`/v1/open`, `/v1/resolve`) or saves
/// in the open queue (contract B18): the query string and fragment are
/// removed, except the first `utm_source` pair, kept byte for byte, because
/// the engine reads it for channel attribution. The engine keeps nothing else
/// from the query: it stores host + path only. Mirrors the engine's query
/// reading: the query is what sits before any '#', between the first and
/// second '?'.
String reportUrl(String url) {
  final hash = url.indexOf('#');
  final noFragment = hash < 0 ? url : url.substring(0, hash);
  final q = noFragment.indexOf('?');
  if (q < 0) return noFragment;
  final base = noFragment.substring(0, q);
  final query = noFragment.substring(q + 1).split('?').first;
  for (final pair in query.split('&')) {
    final eq = pair.indexOf('=');
    if ((eq >= 0 ? pair.substring(0, eq) : pair) == 'utm_source') return '$base?$pair';
  }
  return base;
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

final RegExp _referralCodeRe = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// The referral code in a matched deferred reply (`/v1/referrer`, `/v1/match`,
/// `/v1/handoff/claim`), or null (contract B21, proposal). Only a valid code
/// (1-64 letters, digits, - or _) counts, kept exactly as sent; anything else,
/// or an engine that sends no `referralCode`, gives null.
String? replyReferralCode(Object? reply) =>
    reply is String && _referralCodeRe.hasMatch(reply) ? reply : null;

/// Whether a failed report should be kept for retry: no answer, 429 or 5xx.
bool shouldRetryReport(int? status) => status == null || status == 429 || status >= 500;

/// C1 backoff: the first hold after a 429/5xx is 15-30 s; each one in a row doubles it, up to [retryMaxMs].
const retryBaseMs = 30000;

/// C1 backoff: never hold the queue longer than 1 hour (Retry-After included).
const retryMaxMs = 3600000;

final _retryAfterRe = RegExp(r'^[0-9]{1,9}$');

/// How long to hold the open/event queue after the [failures]-th 429/5xx
/// answer in a row (contract B14, C1). Exponential with equal jitter:
/// step = min([retryMaxMs], [retryBaseMs] × 2^(failures−1)), wait
/// floor(step/2 + random × step/2), so phones that failed together spread
/// out. A [retryAfter] in whole seconds (1-9 ASCII digits, spaces trimmed; an
/// HTTP date or anything else is ignored) is a floor. The result never
/// exceeds [retryMaxMs]. [random] is in [0, 1] (the platform's random number).
int retryDelayMs(int failures, String? retryAfter, double random) {
  final n = failures.clamp(1, 17);
  final half = min(retryMaxMs, retryBaseMs * (1 << (n - 1))) / 2;
  final r = random.clamp(0.0, 1.0);
  final backoff = (half + r * half).floor();
  final s = retryAfter?.trim();
  final server = s != null && _retryAfterRe.hasMatch(s) ? min(int.parse(s), retryMaxMs ~/ 1000) * 1000 : 0;
  return min(retryMaxMs, max(backoff, server));
}

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

/// A unique id for one conversion event when the app gives none (contract
/// B13a): the engine stores an eventId once, so a retried send is never
/// counted twice. Same shape as [newOpenId].
String newEventId(int now, [double Function()? random]) => 'e${newOpenId(now, random).substring(1)}';

/// What `start()` does with the once-per-install flag (contract B6a, shared-spec ADR 0003):
/// [firstLaunch] = run the deferred check / count this launch as the install's first;
/// [clearFlag] = set `strait.deferredChecked` to '' first (the storage came back from
/// another install); then write [storeInstallTime] to `strait.installTime` (null = leave it).
typedef FirstLaunchState = ({bool firstLaunch, bool clearFlag, String? storeInstallTime});

/// B6a: storage restored from a backup of another install (Android Auto Backup, a restored
/// phone) brings back `strait.deferredChecked`. The app's install time, stored next to it,
/// tells: a different stored time = a new install, so the check runs again. No stored time
/// (an app updated from an older SDK) = adopt it, never a new install. Unknown install time
/// (null, 0, negative, not finite) = the B6 rule alone.
FirstLaunchState firstLaunchState(String? flag, String? storedInstallTime, num? installTime) {
  final t = installTime != null && installTime.isFinite && installTime >= 1 ? '${installTime.truncate()}' : null;
  final stored = storedInstallTime == null || storedInstallTime.isEmpty ? null : storedInstallTime;
  if (flag != '1') return (firstLaunch: true, clearFlag: false, storeInstallTime: t != null && t != stored ? t : null);
  if (t == null || t == stored) return (firstLaunch: false, clearFlag: false, storeInstallTime: null);
  if (stored == null) return (firstLaunch: false, clearFlag: false, storeInstallTime: t);
  return (firstLaunch: true, clearFlag: true, storeInstallTime: t);
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

/// A paste-handoff token as the tap page mints it: 128 random bits,
/// base64url (contract B19).
final _handoffToken = RegExp(r'^[A-Za-z0-9_-]{22}$');
final _handoffUrl =
    RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#\s]+)/h/([^/?#\s]*)/?(?:[?#]\S*)?$');

/// The engine's IPv4-only match URL in an unmatched first-launch `/v1/match` reply (contract B24,
/// engine ADR 0101), or null. Only an https URL whose path is exactly `/v1/match` (no query, no
/// fragment, no credentials).
String? ipv4MatchUrl(Object? value) {
  if (value is! String || value.length > 200 || !value.startsWith('https://')) return null;
  final u = Uri.tryParse(value);
  if (u == null || u.scheme != 'https' || u.host.isEmpty || u.path != '/v1/match' || u.hasQuery || u.hasFragment || u.userInfo.isNotEmpty) {
    return null;
  }
  return value;
}

/// Whether a `/v1/match` reply says to try the paste handoff (contract B19):
/// the workspace's live choice in Dashboard Settings -> iPhone installs,
/// `reply.ios.pasteHandoff`. Only an unmatched reply counts, and a missing
/// field (an older engine) means off. Read on every check, never stored, so a
/// dashboard change applies without an app release.
bool pasteHandoffOn(Object? reply) {
  if (reply is! Map) return false;
  if (reply['matched'] == true) return false;
  final ios = reply['ios'];
  return ios is Map && ios['pasteHandoff'] == true;
}

/// The handoff token inside text read from the clipboard (contract B19), or
/// null. Only a Strait handoff link counts: `https://<link host>/h/<token>`,
/// where the host is one of this app's link hosts ([normalizeLinkHosts]), the
/// path is exactly `/h/<22 base64url chars>` (one trailing slash allowed), and
/// the whole text (trimmed) is that one URL. A query or fragment after it is
/// ignored. Scheme and host compare case-insensitively; path and token are
/// case-sensitive. Anything else gives null and nothing is sent.
String? parseHandoffUrl(String? text, List<String> linkHosts) {
  if (text == null) return null;
  final s = text.trim();
  if (s.isEmpty || s.length > 2048) return null;
  final m = _handoffUrl.firstMatch(s);
  if (m == null || m.group(1)!.toLowerCase() != 'https') return null;
  final host = m.group(2)!.toLowerCase();
  if (!linkHosts.any((h) => h.toLowerCase() == host)) return null;
  final token = m.group(3)!;
  return _handoffToken.hasMatch(token) ? token : null;
}

/// The longest user id the SDK sends (after trimming); a longer one is not sent (engine ADR 0110).
const int userIdMax = 128;

final _control = RegExp(r'[\x00-\x1f\x7f]');

/// [s] trimmed with JavaScript's `String.prototype.trim` set (contract B27): Dart's own trim also strips U+0085.
String _jsTrim(String s) {
  bool ws(int c) =>
      (c >= 0x09 && c <= 0x0d) || c == 0x20 || c == 0xa0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200a) ||
      c == 0x2028 || c == 0x2029 || c == 0x202f || c == 0x205f || c == 0x3000 || c == 0xfeff;
  var a = 0, b = s.length;
  while (a < b && ws(s.codeUnitAt(a))) {
    a++;
  }
  while (b > a && ws(s.codeUnitAt(b - 1))) {
    b--;
  }
  return s.substring(a, b);
}

/// B27 (shared-spec ADR 0009, ADR 0010): what `setUserId(id)` sends with later events, or null (nothing sent).
/// In this order: trimmed (JavaScript's whitespace set); empty or longer than [userIdMax] UTF-16 units =
/// null; an email (any `@`, `＠` or `﹫`) is sent as the SHA-256 hex of its lower-case form, a phone number
/// ([phoneNumberForm]) as the SHA-256 hex of its canonical form: `userIdHashed: true`, the raw value never
/// leaves the device; holding a control character = null; else the trimmed id.
({String userId, bool userIdHashed})? userIdField(String? id) {
  if (id == null) return null;
  final t = _jsTrim(id);
  if (t.isEmpty || t.length > userIdMax) return null;
  if (t.codeUnits.any((c) => c == 0x40 || c == 0xff20 || c == 0xfe6b)) {
    return (userId: sha256Hex(t.toLowerCase()), userIdHashed: true);
  }
  final phone = phoneNumberForm(t);
  if (phone != null) return (userId: sha256Hex(phone), userIdHashed: true);
  if (_control.hasMatch(t)) return null;
  return (userId: t, userIdHashed: false);
}

/// The zero of each run of ten decimal digits B27 reads: ASCII, Arabic-Indic, Eastern Arabic-Indic, Devanagari,
/// Bengali, Gurmukhi, Gujarati, Oriya, Tamil, Telugu, Kannada, Malayalam, full-width.
const _digitZeros = [0x30, 0x660, 0x6f0, 0x966, 0x9e6, 0xa66, 0xae6, 0xb66, 0xbe6, 0xc66, 0xce6, 0xd66, 0xff10];

/// Characters a written phone number may hold between its digits (B27 v15): spaces, dashes (incl. Japanese ー),
/// dots, brackets, slashes, invisible marks.
bool _isPhoneSeparator(int c) =>
    c == 0x20 || c == 0x28 || c == 0x29 || c == 0x2d || c == 0x2e || c == 0x2f || c == 0xa0 ||
    (c >= 0x2000 && c <= 0x2015) || (c >= 0x202a && c <= 0x202f) || c == 0x205f || c == 0x2060 ||
    (c >= 0x2066 && c <= 0x2069) || c == 0xad || c == 0x61c || c == 0x30fc || c == 0xff70 || c == 0x2212 ||
    c == 0x3000 || c == 0xfeff || c == 0xff08 || c == 0xff09 || (c >= 0xff0d && c <= 0xff0f);

/// B27 v15 (shared-spec ADR 0010): the canonical form of a phone number, or null when [t] is not one. After an
/// optional `tel:` (any ASCII case), [t] may hold only decimal digits (any [_digitZeros] run), separators and one
/// `+` / `＋` before the first digit, with 8-15 digits (8-17 when they start with the international `00` and there
/// is no `+`). Form: `+` and the digits when written with `+`; `+` and the digits after `00`; else the digits (ASCII).
String? phoneNumberForm(String t) {
  final units = t.codeUnits;
  final tel = units.length >= 4 && units.take(4).every((c) => c < 0x80) && t.substring(0, 4).toLowerCase() == 'tel:';
  var plus = false;
  final digits = StringBuffer();
  for (final c in tel ? units.skip(4) : units) {
    final zero = _digitZeros.where((z) => c >= z && c <= z + 9).firstOrNull;
    if (zero != null) {
      digits.write(c - zero);
    } else if ((c == 0x2b || c == 0xff0b) && !plus && digits.isEmpty) {
      plus = true;
    } else if (!_isPhoneSeparator(c)) {
      return null;
    }
  }
  final d = digits.toString();
  final zeroZero = !plus && d.startsWith('00');
  if (d.length < 8 || d.length > (zeroZero ? 17 : 15)) return null;
  return plus ? '+$d' : zeroZero ? '+${d.substring(2)}' : d;
}

const _k = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, //
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/// SHA-256 of the UTF-8 bytes of [s], lower-case hex (FIPS 180-4; port of the React Native SDK's, so no
/// new dependency). Every word is kept to 32 bits with `& 0xffffffff`, never by 64-bit overflow, so it
/// gives the same answer on the VM, dart2js (JS numbers) and dart2wasm.
String sha256Hex(String s) {
  final bytes = [...utf8.encode(s)];
  final bits = bytes.length * 8;
  bytes.add(0x80);
  while (bytes.length % 64 != 56) {
    bytes.add(0);
  }
  // 64-bit big-endian length; ids are far below 2^32 bits, so the high word is 0.
  bytes.addAll([0, 0, 0, 0, (bits >> 24) & 255, (bits >> 16) & 255, (bits >> 8) & 255, bits & 255]);
  const m = 0xffffffff;
  int rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & m;
  final h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  final w = List<int>.filled(64, 0);
  for (var o = 0; o < bytes.length; o += 64) {
    for (var i = 0; i < 16; i++) {
      final j = o + 4 * i;
      w[i] = ((bytes[j] << 24) | (bytes[j + 1] << 16) | (bytes[j + 2] << 8) | bytes[j + 3]) & m;
    }
    for (var i = 16; i < 64; i++) {
      final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & m;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], k = h[7];
    for (var i = 0; i < 64; i++) {
      final ch = (e & f) ^ ((e ^ m) & g);
      final t1 = (k + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ch + _k[i] + w[i]) & m;
      final t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) & m;
      k = g;
      g = f;
      f = e;
      e = (d + t1) & m;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & m;
    }
    final v = [a, b, c, d, e, f, g, k];
    for (var i = 0; i < 8; i++) {
      h[i] = (h[i] + v[i]) & m;
    }
  }
  return h.map((v) => v.toRadixString(16).padLeft(8, '0')).join();
}
