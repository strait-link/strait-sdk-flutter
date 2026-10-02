import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'strait.dart' show DeviceFields;
import 'core.dart';

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

/// direct = the app was opened by a link; deferred = link tapped before install.
enum LinkKind { direct, deferred }

/// One event type for every way a link reaches the app (B9).
class LinkEvent {
  final String id;
  final LinkKind kind;

  /// app_link · custom_scheme · install_referrer · fingerprint.
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

/// The Strait client: direct links (app_links), deferred links, analytics.
///
/// Port of the React Native `createStrait`. Pure Dart: the app hands it the
/// launch URL, a stream of later URLs and a stream of lifecycle states (see
/// README), so all logic is tested without Flutter.
class StraitLinks {
  /// Workspace publishable key (`bk_pub_live_…`), Dashboard → Get started.
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

  final _tracker = AppStateTracker();
  final _events = <LinkEvent>[];
  final _eventCtl = StreamController<LinkEvent>.broadcast();
  final _startCtl = StreamController<LinkStart>.broadcast();
  final _subs = <StreamSubscription<dynamic>>[];
  int _seq = 0;

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
  })  : _base = endpoint.replaceAll(RegExp(r'/+$'), ''),
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
  /// once per install (B6). Wire [urls] to `AppLinks().uriLinkStream` and
  /// [lifecycle] to a `WidgetsBindingObserver`. Never throws.
  Future<void> start({
    String? initialUrl,
    Stream<String>? urls,
    Stream<AppLifecycle>? lifecycle,
  }) async {
    if (lifecycle != null) {
      _subs.add(lifecycle.listen((s) => _tracker.onState(s, _now()), onError: (_) {}));
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
    if (initialUrl != null && initialUrl.isNotEmpty) {
      await handleUrl(initialUrl, appState: AppStateAtLink.closed);
    }
    try {
      if (await _storage.get(_deferredFlag) != '1') {
        await _storage.set(_deferredFlag, '1');
        // Opened by a link on first launch = the user's intent right now.
        if (initialUrl == null || initialUrl.isEmpty) await checkDeferred();
      }
    } catch (_) {
      // Storage failure: skip the deferred check rather than risk re-routing every launch.
    }
  }

  /// Resolve one URL handed to the app. [appState] defaults to the tracker's
  /// label (background / foreground). Never throws (B10).
  Future<LinkEvent> handleUrl(String raw, {AppStateAtLink? appState}) async {
    final t0 = _now();
    final state = appState ?? _tracker.classify(t0);
    final id = _newId(t0);
    _announce(LinkStart(id: id, kind: LinkKind.direct, appState: state, rawUrl: raw, at: t0));
    final c = classifyUrl(raw, _linkHosts);
    if (c == null) {
      return _emit(LinkEvent(
        id: id, kind: LinkKind.direct, route: LinkRoute.appLink, appState: state,
        rawUrl: raw, matched: false, reason: 'invalid_url', ms: _now() - t0, at: t0,
      ));
    }
    if (c.needsResolve) {
      try {
        final r = await _call('POST', '/v1/resolve', {
          'publishableKey': publishableKey,
          'url': raw,
          'platform': platform,
        });
        final matched = r.json['matched'] == true;
        final dest = _destination(matched ? _str(r.json['longUrl']) : null);
        return _emit(LinkEvent(
          id: id, kind: LinkKind.direct, route: LinkRoute.appLink, appState: state,
          rawUrl: raw, matched: matched,
          reason: matched ? null : (_str(r.json['reason']) ?? _str(r.json['error'])),
          url: dest.url, path: dest.path, params: dest.params,
          linkId: _str(r.json['linkId']), ms: _now() - t0, at: t0,
        ));
      } catch (_) {
        return _emit(LinkEvent(
          id: id, kind: LinkKind.direct, route: LinkRoute.appLink, appState: state,
          rawUrl: raw, matched: false, reason: 'network', ms: _now() - t0, at: t0,
        ));
      }
    }
    return _emit(LinkEvent(
      id: id, kind: LinkKind.direct, route: c.route, appState: state, rawUrl: raw,
      matched: true, url: c.url, path: c.path, params: c.params, ms: _now() - t0, at: t0,
    ));
  }

  /// Run the deferred check now (B7, B8). Doesn't touch the once-per-install
  /// flag, so it's safe for debugging. Never throws.
  Future<LinkEvent> checkDeferred() async {
    final t0 = _now();
    final id = _newId(t0);
    _announce(LinkStart(id: id, kind: LinkKind.deferred, appState: AppStateAtLink.closed, at: t0));
    try {
      if (platform == 'android') {
        String? referrer;
        try {
          referrer = await _installReferrer?.call();
        } catch (_) {}
        final linkId = parseStraitLink(referrer);
        if (linkId != null) {
          final r = await _call('POST', '/v1/referrer', {
            'publishableKey': publishableKey,
            'linkId': linkId,
            'platform': 'android',
          });
          if (r.json['matched'] == true) {
            final dest = _destination(_str(r.json['longUrl']));
            return _emit(LinkEvent(
              id: id, kind: LinkKind.deferred, route: LinkRoute.installReferrer,
              appState: AppStateAtLink.closed, matched: true,
              url: dest.url, path: dest.path, params: dest.params,
              linkId: _str(r.json['linkId']) ?? linkId, ms: _now() - t0, at: t0,
            ));
          }
        }
      }
      final r = await _call('POST', '/v1/match', {
        'publishableKey': publishableKey,
        'platform': platform,
        ..._device().toJson(),
      });
      final matched = r.json['matched'] == true;
      final dest = _destination(matched ? _str(r.json['longUrl']) : null);
      return _emit(LinkEvent(
        id: id, kind: LinkKind.deferred, route: LinkRoute.fingerprint,
        appState: AppStateAtLink.closed, matched: matched,
        reason: matched ? null : 'no_match',
        url: dest.url, path: dest.path, params: dest.params,
        linkId: _str(r.json['linkId']), ms: _now() - t0, at: t0,
      ));
    } catch (_) {
      return _emit(LinkEvent(
        id: id, kind: LinkKind.deferred, route: LinkRoute.fingerprint,
        appState: AppStateAtLink.closed, matched: false, reason: 'network',
        ms: _now() - t0, at: t0,
      ));
    }
  }

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
  Future<bool> trackEvent(String name, {num? value, String? currency, String? linkId}) async {
    try {
      return (await _call('POST', '/v1/event', {
        'publishableKey': publishableKey,
        'event': name,
        'platform': platform,
        if (value != null) 'value': value,
        if (currency != null) 'currency': currency,
        if (linkId != null) 'linkId': linkId,
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

  String _newId(int at) => 'evt_${at}_${++_seq}';

  void _announce(LinkStart s) {
    if (!_startCtl.isClosed) _startCtl.add(s);
  }

  LinkEvent _emit(LinkEvent e) {
    _events.add(e);
    if (!_eventCtl.isClosed) _eventCtl.add(e);
    return e;
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
    return _Res(res.statusCode >= 200 && res.statusCode < 300, json);
  }
}

class _Res {
  final bool ok;
  final Map<String, dynamic> json;
  const _Res(this.ok, this.json);
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
