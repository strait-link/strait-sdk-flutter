import 'dart:async';
import 'dart:convert';
import 'dart:math' show Random;

import 'package:http/http.dart' as http;

import 'strait.dart' show DeviceFields;
import 'core.dart';
import 'doctor.dart';
import 'store_sheet.dart';

/// Persistent key/value storage, e.g. a `shared_preferences` wrapper.
abstract class KeyValueStore {
  Future<String?> get(String key);
  Future<void> set(String key, String value);
}

/// In-memory [KeyValueStore] (default; the deferred check then runs every
/// cold start — pass a persistent store in apps).
class MemoryStore implements KeyValueStore {
  final Map<String, String> data = {};

  @override
  Future<String?> get(String key) async => data[key];

  @override
  Future<void> set(String key, String value) async => data[key] = value;
}

/// The app's clipboard, for the iPhone paste handoff (contract B19). Pure
/// Dart can't reach UIPasteboard, so the app supplies this (see README for a
/// MethodChannel version). Used on iOS, once per install, only when the
/// workspace turned on Paste handoff in the dashboard and device matching
/// found nothing (the engine says so live in the `/v1/match` reply).
abstract class StraitClipboard {
  /// No prompt: whether the clipboard probably holds a web URL
  /// (iOS `UIPasteboard.general.detectPatterns(for: [.probableWebURL])`).
  Future<bool> hasProbableWebUrl();

  /// The clipboard text. On iOS this shows the system "Allow Paste" prompt.
  Future<String?> readText();
}

/// direct = the app was opened by a link; deferred = link tapped before install.
enum LinkKind { direct, deferred }

/// One event type for every way a link reaches the app (B9).
class LinkEvent {
  final String id;
  final LinkKind kind;

  /// app_link · custom_scheme · install_referrer · fingerprint · clipboard.
  final LinkRoute route;
  final AppStateAtLink appState;
  final bool matched;

  /// Why it didn't match: not_found, expired, password_protected, network, no_match, …
  final String? reason;

  /// The URL the OS gave the app (direct links).
  final String? rawUrl;

  /// The destination to navigate to.
  final String? url;
  final String? path;
  final Map<String, String>? params;
  final String? linkId;

  /// Deferred links only: the referral code the tap carried (the tap's
  /// `?strait_ref=`, else the link's `referralCode`), when the engine sends
  /// one. Who invited this install; reward them from your server (the
  /// `referral.converted` webhook). Referrals are a preview (contract B21).
  final String? referralCode;

  /// Time spent resolving, ms.
  final int ms;

  /// Epoch ms when the link arrived.
  final int at;

  const LinkEvent({
    required this.id,
    required this.kind,
    required this.route,
    required this.appState,
    required this.matched,
    required this.ms,
    required this.at,
    this.reason,
    this.rawUrl,
    this.url,
    this.path,
    this.params,
    this.linkId,
    this.referralCode,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'route': route.value,
        'appState': appState.name,
        'matched': matched,
        if (reason != null) 'reason': reason,
        if (rawUrl != null) 'rawUrl': rawUrl,
        if (url != null) 'url': url,
        if (path != null) 'path': path,
        if (params != null) 'params': params,
        if (linkId != null) 'linkId': linkId,
        if (referralCode != null) 'referralCode': referralCode,
        'ms': ms,
        'at': at,
      };

  @override
  String toString() => 'LinkEvent${jsonEncode(toJson())}';
}

/// Fired the moment a link arrives, before it's resolved: show an
/// "Opening link…" state until the [LinkEvent] with the same [id] arrives.
class LinkStart {
  final String id;
  final LinkKind kind;
  final AppStateAtLink appState;
  final String? rawUrl;
  final int at;

  const LinkStart({
    required this.id,
    required this.kind,
    required this.appState,
    required this.at,
    this.rawUrl,
  });
}

const _deferredFlag = 'strait.deferredChecked';
const _queueKey = 'strait.pendingOpens';
const _tapKey = 'strait.lastTap';
const _installTimeKey = 'strait.installTime';
const _enabledKey = 'strait.enabled';

/// The engine calls that record an app open or install get `appVersion` + `sdkVersion` (td2-23) at send
/// time. Not /v1/open: an open report is stamped when it is made, so one saved offline and sent after an
/// app update still names the build it happened on. Not /v1/lookup (records nothing) or /v1/event.
const _recordingPaths = {'/v1/resolve', '/v1/referrer', '/v1/match', '/v1/handoff/claim'};

/// True in a web build (dart2js and dart2wasm), the same test as Flutter's `kIsWeb`.
const bool _onWeb = bool.fromEnvironment('dart.library.js_interop');

/// The Strait client: direct links (app_links), deferred links, analytics.
///
/// Port of the React Native `createStrait`. Pure Dart: the app hands it the
/// launch URL, a stream of later URLs and a stream of lifecycle states (see
/// README), so all logic is tested without Flutter.
class StraitLinks {
  /// Workspace publishable key (`st_pub_live_…`), Dashboard → Get started.
  final String publishableKey;

  /// 'ios' | 'android' | 'other'.
  final String platform;

  final String _base;
  final List<String> _linkHosts;
  final KeyValueStore _storage;
  final Future<String?> Function()? _installReferrer;
  final Future<int?> Function()? _installTime;
  final DeviceFields Function() _device;
  final http.Client _http;
  final bool _ownsHttp;
  final int Function() _now;
  final double Function() _random;

  /// Deprecated and ignored. Whether the SDK tries the paste handoff is the
  /// customer's choice in Dashboard Settings -> iPhone installs, read live
  /// from the engine on every check (no app release needed). Kept so existing
  /// code still compiles.
  @Deprecated('Ignored: the workspace setting (Dashboard Settings -> iPhone installs) decides at runtime.')
  final bool clipboardBoost;
  final StraitClipboard? _clipboard;
  final String? Function()? _deviceClass;
  final String? _appVersion;
  bool _firstLaunch = false;
  /// A direct link arrived in this launch (B6: the first-launch check then stays quiet).
  bool _directArrived = false;

  /// Opt-out switch, read from storage once; unreadable storage = the default (on), like every other read here.
  bool? _enabled;

  /// The first-launch check was skipped because the SDK was off: [setEnabled] true runs it.
  bool _deferredDue = false;

  final _tracker = AppStateTracker();
  final _events = <LinkEvent>[];
  final _eventCtl = StreamController<LinkEvent>.broadcast();
  final _startCtl = StreamController<LinkStart>.broadcast();
  final _subs = <StreamSubscription<dynamic>>[];

  StraitLinks({
    required this.publishableKey,
    required String endpoint,
    required this.platform,
    required DeviceFields Function() deviceFields,
    List<String> linkHosts = const [],
    KeyValueStore? storage,
    Future<String?> Function()? installReferrer,
    Future<int?> Function()? installTime,
    http.Client? client,
    int Function()? now,
    double Function()? random,
    @Deprecated('Ignored: the workspace setting (Dashboard Settings -> iPhone installs) decides at runtime.')
    this.clipboardBoost = false,
    StraitClipboard? clipboard,
    String? Function()? deviceClass,
    String? appVersion,
  })  : _clipboard = clipboard,
        _deviceClass = deviceClass,
        _appVersion = appVersion,
        _base = trimTrailingSlashes(endpoint),
        _linkHosts = normalizeLinkHosts(trimTrailingSlashes(endpoint), linkHosts),
        _storage = storage ?? MemoryStore(),
        _installReferrer = installReferrer,
        _installTime = installTime,
        _device = deviceFields,
        _http = client ?? http.Client(),
        _ownsHttp = client == null,
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        _random = random ?? Random().nextDouble;

  /// `{'deviceClass': 'phone' | 'tablet'}` when the app supplied one (contract
  /// B14), else empty. Anything else, or a throwing callback, sends nothing.
  Map<String, String> _deviceClassField() {
    try {
      final dc = _deviceClass?.call();
      return dc == 'phone' || dc == 'tablet' ? {'deviceClass': dc!} : const {};
    } catch (_) {
      return const {};
    }
  }

  /// Every link event, including ones that happened before you subscribed.
  Stream<LinkEvent> get onLink => Stream<LinkEvent>.multi((c) {
        for (final e in List.of(_events)) {
          c.add(e);
        }
        final sub = _eventCtl.stream.listen(c.add);
        c.onCancel = sub.cancel;
      });

  /// A link just arrived and is being resolved (for a loading state).
  Stream<LinkStart> get onLinkStart => _startCtl.stream;

  /// Events so far, oldest first.
  List<LinkEvent> get events => List.unmodifiable(_events);

  /// Handles the launch link, listens for new ones, runs the deferred check
  /// once per install (B6), and sends saved open reports (B14). Wire [urls]
  /// to `AppLinks().uriLinkStream` and [lifecycle] to a
  /// `WidgetsBindingObserver`. Never throws.
  Future<void> start({
    String? initialUrl,
    Stream<String>? urls,
    Stream<AppLifecycle>? lifecycle,
  }) async {
    _dropStaleTap(_now());
    if (lifecycle != null) {
      _subs.add(lifecycle.listen((s) {
        _tracker.onState(s, _now());
        if (s == AppLifecycle.active) unawaited(flushOpenReports());
      }, onError: (_) {}));
    }
    var skipEcho = initialUrl != null;
    if (urls != null) {
      _subs.add(urls.listen((u) {
        // Some app_links versions also emit the launch link on the stream.
        final echo = skipEcho && u == initialUrl;
        skipEcho = false;
        if (!echo) handleUrl(u);
      }, onError: (_) {}));
    }
    // Web builds (Flutter web) have no install: never a first launch, so no
    // deferred check and no open counted as an install.
    var firstLaunch = false;
    if (!_onWeb) {
      // Unreadable storage counts as "already checked": never risk a stale
      // deferred jump on every launch. Write failures are ignored (never throw).
      String? flag;
      try {
        flag = await _storage.get(_deferredFlag);
      } catch (_) {
        flag = '1';
      }
      // B6a: the install time stored with the flag tells a restored backup of
      // another install from this one (then the check runs again).
      String? stored;
      try {
        stored = await _storage.get(_installTimeKey);
      } catch (_) {}
      int? installed;
      try {
        installed = await _installTime?.call();
      } catch (_) {}
      final s = firstLaunchState(flag, stored, installed);
      if (s.clearFlag) await _write(_deferredFlag, '');
      if (s.storeInstallTime != null) await _write(_installTimeKey, s.storeInstallTime!);
      firstLaunch = s.firstLaunch;
    }
    _firstLaunch = firstLaunch;
    if (initialUrl != null && initialUrl.isNotEmpty) {
      // Opened by a link on first launch = the user's intent right now: no
      // deferred check, but this open still counts as the install's first.
      if (firstLaunch) await _setFlag();
      await _handleUrl(initialUrl, AppStateAtLink.closed, firstLaunch);
    } else if (firstLaunch) {
      if (await isEnabled()) {
        await _firstCheck();
      } else {
        _deferredDue = true; // opted out: not marked done, runs when switched back on
      }
    }
    unawaited(flushOpenReports());
  }

  /// The once-per-install check; marked done only once the engine answered (offline → next launch).
  Future<void> _firstCheck() async {
    final e = await _runDeferred(true);
    if (e.reason == 'disabled') {
      _deferredDue = true; // switched off meanwhile: runs when back on
    } else if (e.reason != 'network') {
      await _setFlag();
    }
  }

  /// Opt-out switch for consent flows (default on, kept in `storage` across
  /// launches). Off: no open reports, no events, no deferred or clipboard
  /// matching, nothing remembered; reports saved earlier and the remembered
  /// tap are deleted. A link that carries its own destination still reaches
  /// [onLink]; a short link is looked up through /v1/lookup, which records nothing (no tap, no open,
  /// no tap id), so it still routes (`reason: 'disabled'` only if that lookup fails). Back on: sending resumes, and a first-launch
  /// check skipped while off runs now. Never throws.
  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    try {
      await _storage.set(_enabledKey, enabled ? '1' : '0');
    } catch (_) {}
    if (!enabled) {
      // Opting out also deletes what was saved to send later.
      await _serial(() => _writeQueue(const []));
      _tapWrite = _tapWrite.then((_) => _storage.set(_tapKey, '')).catchError((_) {});
      await _tapWrite;
      return;
    }
    if (_deferredDue) {
      _deferredDue = false;
      await _firstCheck();
    }
    unawaited(flushOpenReports());
  }

  /// The opt-out switch's current value (see [setEnabled]).
  Future<bool> isEnabled() async {
    if (_enabled == null) {
      String? v;
      try {
        v = await _storage.get(_enabledKey);
      } catch (_) {}
      _enabled ??= v != '0'; // a setEnabled() during the read wins
    }
    return _enabled!;
  }

  Future<void> _setFlag() => _write(_deferredFlag, '1');

  Future<void> _write(String key, String value) async {
    try {
      await _storage.set(key, value);
    } catch (_) {}
  }

  /// Resolve one URL handed to the app. [appState] defaults to the tracker's
  /// label (background / foreground). Reports the open (B14). Never throws (B10).
  Future<LinkEvent> handleUrl(String raw, {AppStateAtLink? appState}) =>
      _handleUrl(raw, appState, false);

  Future<LinkEvent> _handleUrl(String raw, AppStateAtLink? appState, bool firstLaunch) async {
    _directArrived = true;
    final t0 = _now();
    final state = appState ?? _tracker.classify(t0);
    final id = newOpenId(t0);
    final on = await isEnabled();
    _announce(LinkStart(id: id, kind: LinkKind.direct, appState: state, rawUrl: raw, at: t0));
    final c = classifyUrl(raw, _linkHosts);
    if (c == null) {
      return _emit(LinkEvent(
        id: id, kind: LinkKind.direct, route: LinkRoute.appLink, appState: state,
        rawUrl: raw, matched: false, reason: 'invalid_url', ms: _now() - t0, at: t0,
      ));
    }
    // Where a short link goes, recorded nowhere (/v1/lookup): key + host + path, no query; no open
    // report, no tap kept, no retry. Used while opted out, and on the web (F2: /v1/resolve without an
    // openId counts a tap). No answer (offline, or a 404 from an engine without it): [fallback].
    Future<LinkEvent> lookupOnly(String fallback) async {
      Map<String, dynamic> json = const {};
      try {
        final r = await _call('POST', '/v1/lookup', {'publishableKey': publishableKey, 'url': reportUrl(raw).split('?').first}, true);
        if (r.ok) json = r.json;
      } catch (_) {}
      final matched = json['matched'] == true;
      final dest = _destination(matched ? _str(json['longUrl']) : null);
      return _emit(LinkEvent(
        id: id, kind: LinkKind.direct, route: LinkRoute.appLink, appState: state,
        rawUrl: raw, matched: matched, reason: matched ? null : (_str(json['reason']) ?? fallback),
        url: dest.url, path: dest.path, params: dest.params,
        linkId: _str(json['linkId']), ms: _now() - t0, at: t0,
      ));
    }
    if (c.needsResolve && !on) return lookupOnly('disabled');
    // Web: a lookup only; a web open is counted only for a landing that carries a tap id (below).
    if (c.needsResolve && _onWeb) return lookupOnly('network');
    if (c.needsResolve) {
      // The lookup is also the open report (openId); the engine says whether
      // it recorded it, and anything short of that is retried via /v1/open.
      // B18: only host + path (+ utm_source) leave the device or reach storage.
      final sent = reportUrl(raw);
      final base = <String, dynamic>{
        'openId': id, 'kind': 'direct', 'route': 'app_link', 'appState': state.name,
        'platform': platform, 'url': sent, 'matched': false, 'firstLaunch': firstLaunch, 'at': t0,
        ...versionFields(_appVersion),
      };
      try {
        final r = await _call('POST', '/v1/resolve', {
          'publishableKey': publishableKey,
          'url': sent,
          'platform': platform,
          'openId': id,
          'appState': state.name,
          'firstLaunch': firstLaunch,
          'at': t0,
          ..._deviceClassField(),
        });
        final matched = r.json['matched'] == true;
        final reason = matched ? null : (_str(r.json['reason']) ?? _str(r.json['error']));
        final linkId = _str(r.json['linkId']);
        if (matched) _noteTap(replyClickId(r.json['clickId']), t0);
        if (r.json['recorded'] != true) {
          unawaited(_report({
            ...base,
            'matched': matched,
            if (reason != null) 'reason': reason,
            if (linkId != null) 'linkId': linkId,
          }));
        }
        final dest = _destination(matched ? _str(r.json['longUrl']) : null);
        return _emit(LinkEvent(
          id: id, kind: LinkKind.direct, route: LinkRoute.appLink, appState: state,
          rawUrl: raw, matched: matched, reason: reason,
          url: dest.url, path: dest.path, params: dest.params,
          linkId: linkId, ms: _now() - t0, at: t0,
        ));
      } catch (_) {
        // Switched off while the resolve was out (F4): route the way an opted-out tap does.
        if (!await isEnabled()) return lookupOnly('disabled');
        unawaited(_enqueue({...base, 'reason': 'network'}));
        return _emit(LinkEvent(
          id: id, kind: LinkKind.direct, route: LinkRoute.appLink, appState: state,
          rawUrl: raw, matched: false, reason: 'network', ms: _now() - t0, at: t0,
        ));
      }
    }
    if (c.clickId != null && on) _noteTap(c.clickId, t0);
    // Web: the page URL is an open only when it carries the tap id the engine
    // appends when it sends a tap to the web (`strait_click`); one open per tap
    // (openId `web-<tap>`), so a reload or a shared landing URL is de-duplicated
    // by the engine. Any other page URL is a page view: routed, never reported.
    if (on && (!_onWeb || c.clickId != null)) {
      // Navigation never waits for the report.
      unawaited(_report({
        'openId': _onWeb ? 'web-${c.clickId}' : id, 'kind': 'direct', 'route': c.route.value,
        'appState': state.name, 'platform': _onWeb ? 'web' : platform,
        'url': c.url == null ? null : reportUrl(c.url!),
        if (c.clickId != null) 'clickId': c.clickId,
        'matched': true, 'firstLaunch': firstLaunch, 'at': t0,
        ...versionFields(_appVersion),
      }));
    }
    return _emit(LinkEvent(
      id: id, kind: LinkKind.direct, route: c.route, appState: state, rawUrl: raw,
      matched: true, url: c.url, path: c.path, params: c.params, ms: _now() - t0, at: t0,
    ));
  }

  /// Run the deferred check now (B7, B8). Doesn't touch the once-per-install
  /// flag and sends no openId (never adds an install), so it's safe for
  /// debugging. Never throws.
  Future<LinkEvent> checkDeferred() => _runDeferred(false);

  /// The deferred check. [record] (the once-per-install run) sends the openId
  /// so the engine records this first open + install exactly once; the debug
  /// re-check sends record:false instead, so the engine adds no install.
  Future<LinkEvent> _runDeferred(bool record) async {
    final t0 = _now();
    final id = newOpenId(t0);
    if (!await isEnabled()) {
      return LinkEvent(
        id: id, kind: LinkKind.deferred, route: LinkRoute.fingerprint,
        appState: AppStateAtLink.closed, matched: false, reason: 'disabled', ms: 0, at: t0,
      );
    }
    final tag = record ? {'openId': id, 'at': t0} : const <String, Object>{'record': false};
    // B6: a link that arrived before or while this once-per-install check ran is
    // what the person wants now. The check's answer (a match, no_match or
    // network) is returned but not delivered: it would pull the app off that
    // link's screen to a stale pre-install destination. The engine has still
    // counted (and attributed) the install. Nor is a start signal sent once a
    // link is here, since no event may follow it (a loading state would never end).
    bool quiet() => record && _directArrived;
    if (!quiet()) {
      _announce(LinkStart(id: id, kind: LinkKind.deferred, appState: AppStateAtLink.closed, at: t0));
    }
    LinkEvent done(LinkEvent e) => quiet() ? e : _emit(e);
    // No answer, 429 or 5xx = try again next launch (reported as 'network').
    Future<_Res> answered(String path, Map<String, dynamic> body) async {
      final r = await _call('POST', path, body);
      if (shouldRetryReport(r.status)) throw StateError('HTTP ${r.status}');
      return r;
    }

    // The workspace's live paste-handoff choice, from this check's /v1/match
    // reply only (never stored; the next check asks again).
    var pasteOn = false;
    // Signal matching (B7 referrer / B8 match). Returns the event, not emitted.
    Future<LinkEvent> signal() async {
      // B26: the raw Play referrer rides on the calls that record the install, so the install keeps its campaign.
      String? installReferrer;
      if (platform == 'android') {
        String? referrer;
        try {
          referrer = await _installReferrer?.call();
        } catch (_) {}
        if (record) installReferrer = installReferrerField(referrer);
        final linkId = parseStraitLink(referrer);
        if (linkId != null) {
          final clickId = parseStraitClick(referrer);
          final r = await answered('/v1/referrer', {
            'publishableKey': publishableKey,
            'linkId': linkId,
            if (clickId != null) 'clickId': clickId,
            'platform': 'android',
            ...tag,
            if (installReferrer != null) 'installReferrer': installReferrer,
          });
          if (r.json['matched'] == true) {
            if (record) _noteTap(replyClickId(r.json['clickId'], clickId), t0);
            final dest = _destination(_str(r.json['longUrl']));
            return LinkEvent(
              id: id, kind: LinkKind.deferred, route: LinkRoute.installReferrer,
              appState: AppStateAtLink.closed, matched: true,
              url: dest.url, path: dest.path, params: dest.params,
              linkId: _str(r.json['linkId']) ?? linkId,
              referralCode: replyReferralCode(r.json['referralCode']), ms: _now() - t0, at: t0,
            );
          }
        }
      }
      final body = {
        'publishableKey': publishableKey,
        'platform': platform,
        ..._device().toJson(),
        ...tag,
        if (installReferrer != null) 'installReferrer': installReferrer,
      };
      var r = await answered('/v1/match', body);
      pasteOn = pasteHandoffOn(r.json);
      // B24 (engine ADR 0101): asked over IPv6 and nothing found, the engine names its IPv4-only URL;
      // ask once more there (same openId, same fields). Only a match there replaces the first answer.
      final v4 = record && r.json['matched'] != true ? ipv4MatchUrl(r.json['ipv4Match']) : null;
      if (v4 != null) {
        try {
          final again = await answered(v4, body);
          if (again.json['matched'] == true) r = again;
        } catch (_) {}
      }
      final matched = r.json['matched'] == true;
      if (record && matched) _noteTap(replyClickId(r.json['clickId']), t0);
      final dest = _destination(matched ? _str(r.json['longUrl']) : null);
      return LinkEvent(
        id: id, kind: LinkKind.deferred, route: LinkRoute.fingerprint,
        appState: AppStateAtLink.closed, matched: matched,
        reason: matched ? null : 'no_match',
        url: dest.url, path: dest.path, params: dest.params,
        linkId: _str(r.json['linkId']),
        referralCode: matched ? replyReferralCode(r.json['referralCode']) : null, ms: _now() - t0, at: t0,
      );
    }

    LinkEvent result;
    try {
      result = await signal();
    } catch (_) {
      result = LinkEvent(
        id: id, kind: LinkKind.deferred, route: LinkRoute.fingerprint,
        appState: AppStateAtLink.closed, matched: false, reason: 'network',
        ms: _now() - t0, at: t0,
      );
    }
    // B19: device matching first; the clipboard only when the engine answered
    // with no match AND the workspace has Paste handoff on (reply.ios), on
    // iOS, on the once-per-install check (never the debug re-check). No answer
    // = the choice is unknown: the clipboard stays untouched and the check
    // runs again next launch. Same openId across both attempts, one event.
    // Once a link is here the result won't be delivered: don't read the
    // clipboard (that shows iOS's paste prompt for nothing). Nor once the app
    // switched Strait off during the check (F7): no paste prompt for an opted-out person.
    if (result.matched || quiet() || !(record && pasteOn && platform == 'ios' && _clipboard != null) || !await isEnabled()) {
      return done(result);
    }
    final token = await _handoffToken(() => quiet() || _enabled == false);
    if (token == null) return done(result);
    try {
      final c = await answered('/v1/handoff/claim', {
        'publishableKey': publishableKey,
        'token': token,
        'platform': 'ios',
        ...tag,
      });
      if (c.json['matched'] != true) return done(result); // not claimable: keep the match result
      _noteTap(replyClickId(c.json['clickId']), t0);
      final dest = _destination(_str(c.json['longUrl']));
      return done(LinkEvent(
        id: id, kind: LinkKind.deferred, route: LinkRoute.clipboard,
        appState: AppStateAtLink.closed, matched: true,
        url: dest.url, path: dest.path, params: dest.params,
        linkId: _str(c.json['linkId']),
        referralCode: replyReferralCode(c.json['referralCode']), ms: _now() - t0, at: t0,
      ));
    } catch (_) {
      return done(LinkEvent(
        id: id, kind: LinkKind.deferred, route: LinkRoute.clipboard,
        appState: AppStateAtLink.closed, matched: false, reason: 'network',
        ms: _now() - t0, at: t0,
      ));
    }
  }

  /// B19 steps 1-3: detect without a prompt, read only when a web URL is
  /// likely (this shows iOS's paste prompt), keep only a Strait handoff token.
  /// `skip()` true after the prompt-free detect (a link arrived meanwhile) = no read, no prompt.
  Future<String?> _handoffToken(bool Function() skip) async {
    try {
      final clip = _clipboard!;
      if (!await clip.hasProbableWebUrl() || skip()) return null;
      return parseHandoffUrl(await clip.readText(), _linkHosts);
    } catch (_) {
      return null;
    }
  }

  /// Paste-button alternative (B19): claim a handoff link the user pasted
  /// with your own paste control (no prompt: the tap is the consent). Text
  /// that isn't a Strait handoff link gives `matched: false, reason:
  /// 'not_handoff'` without a network call. Never throws.
  Future<LinkEvent> claimHandoff(String? text) async {
    final t0 = _now();
    final id = newOpenId(t0);
    _announce(LinkStart(id: id, kind: LinkKind.deferred, appState: AppStateAtLink.closed, at: t0));
    final token = parseHandoffUrl(text, _linkHosts);
    if (token == null || !await isEnabled()) {
      return _emit(LinkEvent(
        id: id, kind: LinkKind.deferred, route: LinkRoute.clipboard,
        appState: AppStateAtLink.closed, matched: false, reason: token == null ? 'not_handoff' : 'disabled',
        ms: _now() - t0, at: t0,
      ));
    }
    try {
      final r = await _call('POST', '/v1/handoff/claim', {
        'publishableKey': publishableKey,
        'token': token,
        'platform': platform,
        'openId': id,
        'firstLaunch': _firstLaunch,
        'at': t0,
      });
      if (shouldRetryReport(r.status)) throw StateError('HTTP ${r.status}');
      final matched = r.json['matched'] == true;
      if (matched) _noteTap(replyClickId(r.json['clickId']), t0);
      final dest = _destination(matched ? _str(r.json['longUrl']) : null);
      return _emit(LinkEvent(
        id: id, kind: LinkKind.deferred, route: LinkRoute.clipboard,
        appState: AppStateAtLink.closed, matched: matched,
        reason: matched ? null : (_str(r.json['reason']) ?? 'handoff_unknown'),
        url: dest.url, path: dest.path, params: dest.params,
        linkId: _str(r.json['linkId']),
        referralCode: matched ? replyReferralCode(r.json['referralCode']) : null, ms: _now() - t0, at: t0,
      ));
    } catch (_) {
      return _emit(LinkEvent(
        id: id, kind: LinkKind.deferred, route: LinkRoute.clipboard,
        appState: AppStateAtLink.closed, matched: false, reason: 'network',
        ms: _now() - t0, at: t0,
      ));
    }
  }

  // ── Remembered tap (B15): the tap id of the last attributed link open, sent
  // with conversion events. An attributed open without a known tap id (short
  // link, fingerprint match) forgets it: the newer touch wins. Writes are
  // chained so a trackEvent right after an open sees it; failures are ignored.
  Future<void> _tapWrite = Future<void>.value();

  void _noteTap(String? clickId, int at) {
    final value = clickId != null ? rememberTap(clickId, at) : '';
    // Checked inside the chain: a reply that lands after setEnabled(false) keeps no tap.
    _tapWrite = _tapWrite.then((_) async {
      if (await isEnabled()) await _storage.set(_tapKey, value);
    }).catchError((_) {});
  }

  /// B18: delete an expired remembered tap instead of only ignoring it.
  /// Re-read inside the write chain so a newer tap written meanwhile is never lost.
  void _dropStaleTap(int now) {
    _tapWrite = _tapWrite.then((_) async {
      if (staleTap(await _storage.get(_tapKey), now)) await _storage.set(_tapKey, '');
    }).catchError((_) {});
  }

  // ── Open reports (B14): every open is reported once; failures are saved in
  // storage and retried. Queue operations run one at a time (storage is async).
  Future<void> _queueOp = Future<void>.value();
  Future<void>? _flushing;

  Future<T> _serial<T>(Future<T> Function() fn) {
    final p = _queueOp.then((_) => fn());
    _queueOp = p.then((_) {}, onError: (_) {});
    return p;
  }

  Future<List<Map<String, dynamic>>> _readQueue() async {
    try {
      final v = jsonDecode(await _storage.get(_queueKey) ?? '[]');
      if (v is! List) return [];
      // B18: reports saved by an older SDK may hold a full URL; strip it here
      // so the next write leaves no query or fragment on the device.
      return v.whereType<Map<String, dynamic>>().map((rep) {
        final url = rep['url'];
        return url is String ? {...rep, 'url': reportUrl(url)} : rep;
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeQueue(List<Map<String, dynamic>> q) async {
    try {
      await _storage.set(_queueKey, jsonEncode(q));
    } catch (_) {}
  }

  Future<void> _enqueue(Map<String, dynamic> report) => _serial(() async {
        if (!await isEnabled()) return;
        await _writeQueue(pruneOpenQueue([...await _readQueue(), report], _now()));
      });

  // C1: after a 429/5xx the queue waits retryDelayMs (exponential, jittered, at least the
  // Retry-After) before it sends again; any other answer ends the wait. No answer adds none.
  int _failures = 0;
  int _holdUntil = 0;

  /// POST /v1/open (or /v1/event for a saved event, B13a); the HTTP status,
  /// or null when there was no answer.
  Future<int?> _sendReport(Map<String, dynamic> report) async {
    try {
      final _Res res;
      if (report['type'] == 'event') {
        final event = {'publishableKey': publishableKey, ...report}
          ..remove('type')
          ..remove('at');
        res = await _call('POST', '/v1/event', event);
      } else {
        // B14: deviceClass is added at send time, never saved in the queue.
        res = await _call('POST', '/v1/open', {'publishableKey': publishableKey, ...report, ..._deviceClassField()});
      }
      if (shouldRetryReport(res.status)) {
        _holdUntil = _now() + retryDelayMs(++_failures, res.retryAfter, _random());
      } else {
        _failures = _holdUntil = 0;
      }
      return res.status;
    } catch (_) {
      return null;
    }
  }

  /// Report an open (or an event) now; keep it for retry if it doesn't get
  /// through. The HTTP status, or null when there was no answer.
  Future<int?> _report(Map<String, dynamic> report) async {
    final status = await _sendReport(report);
    if (shouldRetryReport(status)) {
      await _enqueue(report);
    } else {
      unawaited(flushOpenReports()); // the network works: send anything saved earlier
    }
    return status;
  }

  /// Open reports and events saved while offline, waiting to be sent (debugging).
  Future<int> pendingOpenReports() => _serial(() async => (await _readQueue()).length);

  /// Send saved open reports now (also happens on start and on resume).
  /// Never throws.
  Future<void> flushOpenReports() => _flushing ??= _serial(() async {
        if (!await isEnabled()) return;
        if (_now() < _holdUntil) return; // C1: the server asked us to wait
        final queue = pruneOpenQueue(await _readQueue(), _now());
        final keep = <Map<String, dynamic>>[];
        var stop = false;
        for (final rep in queue) {
          // Once one gets no answer, a 429 or a 5xx, keep the rest for later.
          if (stop) {
            keep.add(rep);
            continue;
          }
          stop = shouldRetryReport(await _sendReport(rep));
          if (stop) keep.add(rep);
        }
        await _writeQueue(keep);
      }).whenComplete(() => _flushing = null);

  /// Send this app's fingerprint to the engine (debug comparison with the
  /// browser). Returns the engine's JSON, or null on network failure.
  Future<Map<String, dynamic>?> reportFingerprint() async {
    try {
      return (await _call('POST', '/v1/debug/fingerprint', {
        'publishableKey': publishableKey,
        'origin': 'app',
        ..._device().toJson(),
      })).json;
    } catch (_) {
      return null;
    }
  }

  /// Engine's comparison of the app and browser fingerprints on this network,
  /// or null on network failure.
  Future<Map<String, dynamic>?> compareFingerprint() async {
    try {
      return (await _call('GET',
              '/v1/debug/fingerprint?publishableKey=${Uri.encodeComponent(publishableKey)}'))
          .json;
    } catch (_) {
      return null;
    }
  }

  /// Setup check for debug builds (contract B23): your key, your endpoint and
  /// whether the link host's `/.well-known/assetlinks.json` (Android) or
  /// `/.well-known/apple-app-site-association` (iOS) lists [appId] (your
  /// package / bundle ID, e.g. from `package_info_plus`; left out = the
  /// findings list what the host has) and, on Android, this build's signing
  /// certificate [certSha256] (any case, with or without colons). One GET;
  /// never runs by itself; never throws. Prints each finding with
  /// `[Strait doctor]` when asserts are on (debug builds only).
  Future<DoctorReport> doctor({String? appId, List<String> certSha256 = const []}) async {
    final mobile = platform == 'android' || platform == 'ios';
    DoctorFile? file;
    if (mobile && doctorHost(_base) != null) {
      final path = platform == 'android' ? 'assetlinks.json' : 'apple-app-site-association';
      try {
        final res = await _http.get(Uri.parse('$_base/.well-known/$path')).timeout(const Duration(seconds: 10));
        file = DoctorFile(res.statusCode, res.body);
      } catch (_) {
        file = const DoctorFile(null, null);
      }
    }
    final report = doctorFindings(
      publishableKey: publishableKey,
      endpoint: _base,
      platform: mobile ? platform : 'android',
      appId: appId,
      certSha256: certSha256,
      file: file,
    );
    assert(() {
      for (final f in report.findings) {
        print('[Strait doctor] ${f.severity} ${f.id}: ${f.title}${f.fix.isEmpty ? '' : '. Fix: ${f.fix}'}');
      }
      return true;
    }());
    return report;
  }

  /// Conversion / revenue event. Resolves true when accepted. Never throws.
  /// Carries the tap id of the last attributed link open (≤7 days, contract
  /// B15) unless you pass [clickId] yourself. Pass your order id as [eventId]:
  /// the engine stores each eventId once (else the SDK makes one). False = not
  /// accepted now; when the network or the server was the reason, the event is
  /// kept and sent later with the open reports (contract B13a).
  Future<bool> trackEvent(String name,
      {num? value, String? currency, String? linkId, String? clickId, String? eventId}) async {
    if (!await isEnabled()) return false;
    try {
      await _tapWrite;
      String? stored;
      try {
        stored = await _storage.get(_tapKey);
      } catch (_) {}
      final at = _now();
      if (staleTap(stored, at)) _dropStaleTap(at);
      final tap = eventClickId(stored, at, clickId);
      // B13a: built once (tap id chosen now), with an eventId so a retry is
      // stored once. Saved for retry without the publishable key.
      final status = await _report({
        'type': 'event',
        'at': at,
        'event': name,
        'platform': platform,
        'eventId': eventId == null || eventId.isEmpty ? newEventId(at) : eventId,
        if (value != null) 'value': value,
        if (currency != null) 'currency': currency,
        if (linkId != null) 'linkId': linkId,
        if (tap != null) 'clickId': tap,
      });
      return status != null && status >= 200 && status < 300;
    } catch (_) {
      return false;
    }
  }

  /// Stop listening for URLs and lifecycle changes.
  void stop() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }

  /// [stop], close the streams, and close the HTTP client if the SDK made it.
  Future<void> dispose() async {
    stop();
    if (_ownsHttp) _http.close();
    await _eventCtl.close();
    await _startCtl.close();
  }

  void _announce(LinkStart s) {
    if (!_startCtl.isClosed) _startCtl.add(s);
  }

  LinkEvent _emit(LinkEvent e) {
    _events.add(e);
    if (!_eventCtl.isClosed) _eventCtl.add(e);
    return e;
  }

  /// Store sheet (new): show the app store inside your app
  /// for one of your short links and keep the deep link for the app being
  /// installed. [opener] starts the Intent / shows StoreKit (README "Store
  /// sheet"). Never throws.
  Future<StoreSheetResult> openStoreSheet(String url, StoreSheetOpener opener,
      [StoreSheetOptions options = const StoreSheetOptions()]) async {
    try {
      return await runStoreSheet(
        call: (path, body) async {
          final r = await _call('POST', path, body);
          return (ok: r.ok, status: r.status, json: r.json);
        },
        publishableKey: publishableKey,
        platform: platform,
        device: () => _device().toJson(),
        deviceClass: _deviceClassField()['deviceClass'],
        url: url,
        options: options,
        opener: opener,
      );
    } catch (_) {
      return const StoreSheetResult(false, 'none', reason: 'error');
    }
  }

  /// Every engine call goes through here: while opted out nothing leaves the device, except
  /// [lookupOnly] (/v1/lookup: where a short link goes, recorded nowhere, engine ADR 0083).
  Future<_Res> _call(String method, String path, [Map<String, dynamic>? body, bool lookupOnly = false]) async {
    if (!lookupOnly && !await isEnabled()) throw StateError('disabled');
    // `path` on the endpoint, or an absolute URL (the engine's IPv4-only match URL, B24).
    final absolute = path.startsWith('https://');
    final uri = Uri.parse(absolute ? path : '$_base$path');
    // td2-23 (open reports carry their own, stamped when made).
    if (body != null && _recordingPaths.contains(absolute ? uri.path : path)) {
      body = {...body, ...versionFields(_appVersion)};
    }
    // A stalled reply must not hang start() or the open queue: like the Android
    // SDK's 10 s timeouts, it throws into the existing 'network' path.
    final res = await (body == null
            ? _http.get(uri)
            : _http.post(uri,
                headers: {'Content-Type': 'application/json'}, body: jsonEncode(body)))
        .timeout(const Duration(seconds: 10));
    Map<String, dynamic> json;
    try {
      final d = jsonDecode(res.body);
      json = d is Map<String, dynamic> ? d : <String, dynamic>{};
    } catch (_) {
      json = <String, dynamic>{};
    }
    return _Res(res.statusCode >= 200 && res.statusCode < 300, res.statusCode, json, res.headers['retry-after']);
  }
}

class _Res {
  final bool ok;
  final int status;
  final Map<String, dynamic> json;
  final String? retryAfter;
  const _Res(this.ok, this.status, this.json, [this.retryAfter]);
}

class _Dest {
  final String? url;
  final String? path;
  final Map<String, String>? params;
  const _Dest([this.url, this.path, this.params]);
}

_Dest _destination(String? url) {
  if (url == null || url.isEmpty) return const _Dest();
  final p = splitUrl(url);
  return p == null ? _Dest(url) : _Dest(url, p.path, p.params);
}

String? _str(Object? v) => v is String ? v : null;
