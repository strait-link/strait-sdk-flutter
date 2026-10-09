import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'strait.dart' show DeviceFields;
import 'core.dart';
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

/// The app's clipboard, for the iPhone clipboard boost (contract B19). Pure
/// Dart can't reach UIPasteboard, so the app supplies this (see README for a
/// MethodChannel version). Used only when `clipboardBoost` is true, on iOS,
/// once per install.
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
  final DeviceFields Function() _device;
  final http.Client _http;
  final bool _ownsHttp;
  final int Function() _now;

  /// iPhone clipboard boost (B19). Default false: the clipboard is never touched.
  final bool clipboardBoost;
  final StraitClipboard? _clipboard;
  bool _firstLaunch = false;

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
    http.Client? client,
    int Function()? now,
    this.clipboardBoost = false,
    StraitClipboard? clipboard,
  })  : _clipboard = clipboard,
        _base = endpoint.replaceAll(RegExp(r'/+$'), ''),
        _linkHosts = normalizeLinkHosts(
            endpoint.replaceAll(RegExp(r'/+$'), ''), linkHosts),
        _storage = storage ?? MemoryStore(),
        _installReferrer = installReferrer,
        _device = deviceFields,
        _http = client ?? http.Client(),
        _ownsHttp = client == null,
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

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
    // Unreadable storage counts as "already checked": never risk a stale
    // deferred jump on every launch. Write failures are ignored (never throw).
    String? flag;
    try {
      flag = await _storage.get(_deferredFlag);
    } catch (_) {
      flag = '1';
    }
    final firstLaunch = flag != '1';
    _firstLaunch = firstLaunch;
    if (initialUrl != null && initialUrl.isNotEmpty) {
      // Opened by a link on first launch = the user's intent right now: no
      // deferred check, but this open still counts as the install's first.
      if (firstLaunch) await _setFlag();
      await _handleUrl(initialUrl, AppStateAtLink.closed, firstLaunch);
    } else if (firstLaunch) {
      // Marked done only once the engine answered: offline → next launch.
      final e = await _runDeferred(true);
      if (e.reason != 'network') await _setFlag();
    }
    unawaited(flushOpenReports());
  }

  Future<void> _setFlag() async {
    try {
      await _storage.set(_deferredFlag, '1');
    } catch (_) {}
  }

  /// Resolve one URL handed to the app. [appState] defaults to the tracker's
  /// label (background / foreground). Reports the open (B14). Never throws (B10).
  Future<LinkEvent> handleUrl(String raw, {AppStateAtLink? appState}) =>
      _handleUrl(raw, appState, false);

  Future<LinkEvent> _handleUrl(String raw, AppStateAtLink? appState, bool firstLaunch) async {
    final t0 = _now();
    final state = appState ?? _tracker.classify(t0);
    final id = newOpenId(t0);
    _announce(LinkStart(id: id, kind: LinkKind.direct, appState: state, rawUrl: raw, at: t0));
    final c = classifyUrl(raw, _linkHosts);
    if (c == null) {
      return _emit(LinkEvent(
        id: id, kind: LinkKind.direct, route: LinkRoute.appLink, appState: state,
        rawUrl: raw, matched: false, reason: 'invalid_url', ms: _now() - t0, at: t0,
      ));
    }
    if (c.needsResolve) {
      // The lookup is also the open report (openId); the engine says whether
      // it recorded it, and anything short of that is retried via /v1/open.
      // B18: only host + path (+ utm_source) leave the device or reach storage.
      final sent = reportUrl(raw);
      final base = <String, dynamic>{
        'openId': id, 'kind': 'direct', 'route': 'app_link', 'appState': state.name,
        'platform': platform, 'url': sent, 'matched': false, 'firstLaunch': firstLaunch, 'at': t0,
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
        unawaited(_enqueue({...base, 'reason': 'network'}));
        return _emit(LinkEvent(
          id: id, kind: LinkKind.direct, route: LinkRoute.appLink, appState: state,
          rawUrl: raw, matched: false, reason: 'network', ms: _now() - t0, at: t0,
        ));
      }
    }
    if (c.clickId != null) _noteTap(c.clickId, t0);
    // Navigation never waits for the report.
    unawaited(_report({
      'openId': id, 'kind': 'direct', 'route': c.route.value, 'appState': state.name,
      'platform': platform, 'url': c.url == null ? null : reportUrl(c.url!),
      if (c.clickId != null) 'clickId': c.clickId,
      'matched': true, 'firstLaunch': firstLaunch, 'at': t0,
    }));
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
  /// so the engine records this first open + install exactly once.
  Future<LinkEvent> _runDeferred(bool record) async {
    final t0 = _now();
    final id = newOpenId(t0);
    final tag = record ? {'openId': id, 'at': t0} : const <String, Object>{};
    _announce(LinkStart(id: id, kind: LinkKind.deferred, appState: AppStateAtLink.closed, at: t0));
    // No answer, 429 or 5xx = try again next launch (reported as 'network').
    Future<_Res> answered(String path, Map<String, dynamic> body) async {
      final r = await _call('POST', path, body);
      if (shouldRetryReport(r.status)) throw StateError('HTTP ${r.status}');
      return r;
    }

    try {
      if (platform == 'android') {
        String? referrer;
        try {
          referrer = await _installReferrer?.call();
        } catch (_) {}
        final linkId = parseStraitLink(referrer);
        if (linkId != null) {
          final clickId = parseStraitClick(referrer);
          final r = await answered('/v1/referrer', {
            'publishableKey': publishableKey,
            'linkId': linkId,
            if (clickId != null) 'clickId': clickId,
            'platform': 'android',
            ...tag,
          });
          if (r.json['matched'] == true) {
            if (record) _noteTap(replyClickId(r.json['clickId'], clickId), t0);
            final dest = _destination(_str(r.json['longUrl']));
            return _emit(LinkEvent(
              id: id, kind: LinkKind.deferred, route: LinkRoute.installReferrer,
              appState: AppStateAtLink.closed, matched: true,
              url: dest.url, path: dest.path, params: dest.params,
              linkId: _str(r.json['linkId']) ?? linkId,
              referralCode: replyReferralCode(r.json['referralCode']), ms: _now() - t0, at: t0,
            ));
          }
        }
      }
      // B19: the clipboard boost, only when the app opted in, on iOS, on the
      // once-per-install check (never the debug re-check).
      if (record && clipboardBoost && platform == 'ios' && _clipboard != null) {
        final token = await _handoffToken();
        if (token != null) {
          final c = await answered('/v1/handoff/claim', {
            'publishableKey': publishableKey,
            'token': token,
            'platform': 'ios',
            ...tag,
          });
          if (c.json['matched'] == true) {
            _noteTap(replyClickId(c.json['clickId']), t0);
            final dest = _destination(_str(c.json['longUrl']));
            return _emit(LinkEvent(
              id: id, kind: LinkKind.deferred, route: LinkRoute.clipboard,
              appState: AppStateAtLink.closed, matched: true,
              url: dest.url, path: dest.path, params: dest.params,
              linkId: _str(c.json['linkId']),
              referralCode: replyReferralCode(c.json['referralCode']), ms: _now() - t0, at: t0,
            ));
          }
        }
      }
      final r = await answered('/v1/match', {
        'publishableKey': publishableKey,
        'platform': platform,
        ..._device().toJson(),
        ...tag,
      });
      final matched = r.json['matched'] == true;
      if (record && matched) _noteTap(replyClickId(r.json['clickId']), t0);
      final dest = _destination(matched ? _str(r.json['longUrl']) : null);
      return _emit(LinkEvent(
        id: id, kind: LinkKind.deferred, route: LinkRoute.fingerprint,
        appState: AppStateAtLink.closed, matched: matched,
        reason: matched ? null : 'no_match',
        url: dest.url, path: dest.path, params: dest.params,
        linkId: _str(r.json['linkId']),
        referralCode: matched ? replyReferralCode(r.json['referralCode']) : null, ms: _now() - t0, at: t0,
      ));
    } catch (_) {
      return _emit(LinkEvent(
        id: id, kind: LinkKind.deferred, route: LinkRoute.fingerprint,
        appState: AppStateAtLink.closed, matched: false, reason: 'network',
        ms: _now() - t0, at: t0,
      ));
    }
  }

  /// B19 steps 1-3: detect without a prompt, read only when a web URL is
  /// likely (this shows iOS's paste prompt), keep only a Strait handoff token.
  Future<String?> _handoffToken() async {
    try {
      final clip = _clipboard!;
      if (!await clip.hasProbableWebUrl()) return null;
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
    if (token == null) {
      return _emit(LinkEvent(
        id: id, kind: LinkKind.deferred, route: LinkRoute.clipboard,
        appState: AppStateAtLink.closed, matched: false, reason: 'not_handoff',
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
    _tapWrite = _tapWrite.then((_) => _storage.set(_tapKey, value)).catchError((_) {});
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
        await _writeQueue(pruneOpenQueue([...await _readQueue(), report], _now()));
      });

  /// POST /v1/open; the HTTP status, or null when there was no answer.
  Future<int?> _sendReport(Map<String, dynamic> report) async {
    try {
      return (await _call('POST', '/v1/open', {'publishableKey': publishableKey, ...report}))
          .status;
    } catch (_) {
      return null;
    }
  }

  /// Report an open now; keep it for retry if it doesn't get through.
  Future<void> _report(Map<String, dynamic> report) async {
    final status = await _sendReport(report);
    if (shouldRetryReport(status)) {
      await _enqueue(report);
    } else {
      unawaited(flushOpenReports()); // the network works: send anything saved earlier
    }
  }

  /// Open reports saved while offline, waiting to be sent (debugging).
  Future<int> pendingOpenReports() => _serial(() async => (await _readQueue()).length);

  /// Send saved open reports now (also happens on start and on resume).
  /// Never throws.
  Future<void> flushOpenReports() => _flushing ??= _serial(() async {
        final queue = pruneOpenQueue(await _readQueue(), _now());
        final keep = <Map<String, dynamic>>[];
        var offline = false;
        for (final rep in queue) {
          // Once one gets no answer at all, keep the rest for later.
          if (offline) {
            keep.add(rep);
            continue;
          }
          final status = await _sendReport(rep);
          offline = status == null;
          if (shouldRetryReport(status)) keep.add(rep);
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

  /// Conversion / revenue event. Resolves true when accepted. Never throws.
  /// Carries the tap id of the last attributed link open (≤7 days, contract
  /// B15) unless you pass [clickId] yourself.
  Future<bool> trackEvent(String name,
      {num? value, String? currency, String? linkId, String? clickId}) async {
    try {
      await _tapWrite;
      String? stored;
      try {
        stored = await _storage.get(_tapKey);
      } catch (_) {}
      if (staleTap(stored, _now())) _dropStaleTap(_now());
      final tap = eventClickId(stored, _now(), clickId);
      return (await _call('POST', '/v1/event', {
        'publishableKey': publishableKey,
        'event': name,
        'platform': platform,
        if (value != null) 'value': value,
        if (currency != null) 'currency': currency,
        if (linkId != null) 'linkId': linkId,
        if (tap != null) 'clickId': tap,
      })).ok;
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

  /// Store sheet (beta; iPhone is beta): show the app store inside your app
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
        url: url,
        options: options,
        opener: opener,
      );
    } catch (_) {
      return const StoreSheetResult(false, 'none', reason: 'error');
    }
  }

  Future<_Res> _call(String method, String path, [Map<String, dynamic>? body]) async {
    final uri = Uri.parse('$_base$path');
    final res = body == null
        ? await _http.get(uri)
        : await _http.post(uri,
            headers: {'Content-Type': 'application/json'}, body: jsonEncode(body));
    Map<String, dynamic> json;
    try {
      final d = jsonDecode(res.body);
      json = d is Map<String, dynamic> ? d : <String, dynamic>{};
    } catch (_) {
      json = <String, dynamic>{};
    }
    return _Res(res.statusCode >= 200 && res.statusCode < 300, res.statusCode, json);
  }
}

class _Res {
  final bool ok;
  final int status;
  final Map<String, dynamic> json;
  const _Res(this.ok, this.status, this.json);
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
