/// Store sheet (beta; iPhone is beta). Show the app store INSIDE your app for
/// one of your Strait links and keep the deep link for the app being installed.
/// Same flow as sdk-android, sdk-swift and sdk-react-native:
///
///  1. POST /v1/store-sheet records the tap (sent_to 'store_sheet').
///  2. Android: Google Play inline install, then market://, then the Play web
///     page, each with referrer=strait_link=<id>&strait_click=<tap>.
///     iPhone: save this device's match fields for the tap (/v1/match-save),
///     optionally copy the clipboard-boost handoff link, then show the App Store.
///
/// Pure Dart can't start an Intent or show StoreKit, so the app supplies a
/// [StoreSheetOpener] (README "Store sheet" has a MethodChannel version).
///
/// It works only where your app is the host. A link tapped inside another
/// company's app can't open a store sheet there.
library;

/// An Android store Intent: `Intent(action, Uri.parse(data)).setPackage(packageName)` + extras.
class StoreIntent {
  /// 'inline_install' | 'market' | 'web'.
  final String kind;
  final String action;
  final String data;
  final String? packageName;
  final Map<String, Object> extras;
  const StoreIntent(this.kind, this.data, this.packageName, [this.extras = const {}])
      : action = 'android.intent.action.VIEW';

  /// For a MethodChannel.
  Map<String, Object?> toMap() =>
      {'kind': kind, 'action': action, 'data': data, 'packageName': packageName, 'extras': extras};
}

class StoreProduct {
  final String appStoreId;
  final String? campaignToken;
  final String? providerToken;
  final String? customProductPageId;
  const StoreProduct(this.appStoreId, {this.campaignToken, this.providerToken, this.customProductPageId});

  Map<String, Object?> toMap() => {
        'appStoreId': appStoreId,
        if (campaignToken != null) 'campaignToken': campaignToken,
        if (providerToken != null) 'providerToken': providerToken,
        if (customProductPageId != null) 'customProductPageId': customProductPageId,
      };

  @override
  bool operator ==(Object other) =>
      other is StoreProduct &&
      other.appStoreId == appStoreId &&
      other.campaignToken == campaignToken &&
      other.providerToken == providerToken &&
      other.customProductPageId == customProductPageId;

  @override
  int get hashCode => Object.hash(appStoreId, campaignToken, providerToken, customProductPageId);
}

/// 'product_page' (SKStoreProductViewController) or 'overlay' (SKOverlay).
enum StoreSheetStyle { productPage, overlay }

extension StoreSheetStyleWire on StoreSheetStyle {
  String get wire => this == StoreSheetStyle.overlay ? 'overlay' : 'product_page';
}

/// How the app opens a store. Each returns true when something opened.
abstract class StoreSheetOpener {
  /// Start an Android Intent; false when no activity could (ActivityNotFoundException).
  Future<bool> androidIntent(StoreIntent intent);

  /// Show SKStoreProductViewController / SKOverlay.
  Future<bool> iosProduct(StoreProduct product, StoreSheetStyle style);

  /// Write clipboard text (iPhone handoff link, only with copyHandoffLink). Default: not supported.
  Future<bool> writeClipboard(String text) async => false;
}

class StoreSheetOptions {
  final String? androidPackage;
  final String? callerId;
  final String? listing;
  final bool inline;
  final String? appStoreId;
  final String? providerToken;
  final String? customProductPageId;
  final StoreSheetStyle style;
  final bool saveDeviceMatch;

  /// Default false: copying replaces what the user had copied.
  final bool copyHandoffLink;

  const StoreSheetOptions({
    this.androidPackage,
    this.callerId,
    this.listing,
    this.inline = true,
    this.appStoreId,
    this.providerToken,
    this.customProductPageId,
    this.style = StoreSheetStyle.productPage,
    this.saveDeviceMatch = true,
    this.copyHandoffLink = false,
  });
}

class StoreSheetResult {
  final bool opened;

  /// inline_install | market | web | product_page | overlay | none
  final String method;
  final String? clickId;
  final String? linkId;
  final String? referrer;
  final bool matchSaved;
  final bool handoffCopied;

  /// not_found, expired, offline, no_package, no_app_store_id, no_store, not_shown…
  final String? reason;
  const StoreSheetResult(this.opened, this.method,
      {this.clickId, this.linkId, this.referrer, this.matchSaved = false, this.handoffCopied = false, this.reason});

  @override
  String toString() => 'StoreSheetResult(opened: $opened, method: $method, reason: $reason)';
}

const _play = 'com.android.vending';
final _package = RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$');
final _appStoreId = RegExp(r'^[0-9]{1,20}$');
final _handoff = RegExp(r'^https://[^/?#\s]+/h/[A-Za-z0-9_-]{22}$');
const storeSheetCampaignTokenMax = 30;

bool isPackageName(Object? s) => s is String && s.length <= 255 && _package.hasMatch(s);
bool isAppStoreId(Object? s) => s is String && _appStoreId.hasMatch(s);
String _enc(String s) => Uri.encodeQueryComponent(s);

StoreIntent inlineInstallIntent(String pkg, String? referrer, String callerId, [String? listing]) {
  var d = 'https://play.google.com/d?id=${_enc(pkg)}';
  if (referrer != null && referrer.isNotEmpty) d += '&referrer=${_enc(referrer)}';
  if (listing != null && listing.isNotEmpty) d += '&listing=${_enc(listing)}';
  return StoreIntent('inline_install', d, _play, {'overlay': true, 'callerId': callerId});
}

StoreIntent marketIntent(String pkg, [String? referrer]) => StoreIntent('market',
    'market://details?id=${_enc(pkg)}${referrer != null && referrer.isNotEmpty ? '&referrer=${_enc(referrer)}' : ''}', _play);

StoreIntent playWebIntent(String pkg, [String? referrer]) => StoreIntent(
    'web',
    'https://play.google.com/store/apps/details?id=${_enc(pkg)}'
        '${referrer != null && referrer.isNotEmpty ? '&referrer=${_enc(referrer)}' : ''}',
    null);

/// The Android Intents to try, in order. Inline only with a valid callerId.
List<StoreIntent> androidStorePlan(String pkg, String? referrer,
    {String? callerId, bool inline = true, String? listing}) => [
      if (inline && isPackageName(callerId)) inlineInstallIntent(pkg, referrer, callerId!, listing),
      marketIntent(pkg, referrer),
      playWebIntent(pkg, referrer),
    ];

/// The iPhone product from the engine's `ios` reply and the options (options win).
StoreProduct? iosStoreProduct(Map<String, dynamic>? ios, [StoreSheetOptions o = const StoreSheetOptions()]) {
  final id = o.appStoreId ?? ios?['appStoreId'];
  if (!isAppStoreId(id)) return null;
  final ct = ios?['campaignToken'];
  return StoreProduct(id as String,
      campaignToken: ct is String
          ? (ct.length > storeSheetCampaignTokenMax ? ct.substring(0, storeSheetCampaignTokenMax) : ct)
          : null,
      providerToken: o.providerToken,
      customProductPageId: o.customProductPageId);
}

typedef StoreSheetCall = Future<({bool ok, int status, Map<String, dynamic> json})> Function(
    String path, Map<String, dynamic> body);

Future<bool> _attempt(Future<bool> Function() f) async {
  try {
    return await f();
  } catch (_) {
    return false;
  }
}

/// The flow behind `StraitLinks.openStoreSheet` (exported for tests and custom clients).
Future<StoreSheetResult> runStoreSheet({
  required StoreSheetCall call,
  required String publishableKey,
  required String platform,
  required Map<String, dynamic> Function() device,
  required String url,
  required StoreSheetOptions options,
  required StoreSheetOpener opener,
}) async {
  if (platform != 'android' && platform != 'ios') {
    return const StoreSheetResult(false, 'none', reason: 'unsupported_platform');
  }
  String? reason;
  var reply = <String, dynamic>{};
  try {
    final r = await call('/v1/store-sheet', {'publishableKey': publishableKey, 'url': url, 'platform': platform});
    if (r.ok && r.json['ok'] == true) {
      reply = r.json;
    } else {
      reason = r.json['reason'] is String ? r.json['reason'] as String : 'http_${r.status}';
    }
  } catch (_) {
    reason = 'offline';
  }
  final clickId = reply['clickId'] is String ? reply['clickId'] as String : null;
  final linkId = reply['linkId'] is String ? reply['linkId'] as String : null;

  if (platform == 'android') {
    final android = reply['android'] is Map ? (reply['android'] as Map).cast<String, dynamic>() : null;
    final referrer = android?['referrer'] is String ? android!['referrer'] as String : null;
    final pkg = options.androidPackage ?? android?['package'];
    if (!isPackageName(pkg)) {
      return StoreSheetResult(false, 'none', clickId: clickId, linkId: linkId, referrer: referrer, reason: 'no_package');
    }
    for (final i in androidStorePlan(pkg as String, referrer,
        callerId: options.callerId, inline: options.inline, listing: options.listing)) {
      if (await _attempt(() => opener.androidIntent(i))) {
        return StoreSheetResult(true, i.kind, clickId: clickId, linkId: linkId, referrer: referrer, reason: reason);
      }
    }
    return StoreSheetResult(false, 'none',
        clickId: clickId, linkId: linkId, referrer: referrer, reason: reason ?? 'no_store');
  }

  final ios = reply['ios'] is Map ? (reply['ios'] as Map).cast<String, dynamic>() : null;
  final product = iosStoreProduct(ios, options);
  if (product == null) {
    return StoreSheetResult(false, 'none', clickId: clickId, linkId: linkId, reason: reason ?? 'no_app_store_id');
  }
  var matchSaved = false;
  if (options.saveDeviceMatch && ios?['deviceMatching'] == true && clickId != null && linkId != null) {
    try {
      matchSaved = (await call('/v1/match-save', {...device(), 'linkId': linkId, 'clickId': clickId})).ok;
    } catch (_) {
      matchSaved = false;
    }
  }
  var handoffCopied = false;
  final h = ios?['handoffUrl'];
  if (options.copyHandoffLink && h is String && _handoff.hasMatch(h)) {
    handoffCopied = await _attempt(() => opener.writeClipboard(h));
  }
  final shown = await _attempt(() => opener.iosProduct(product, options.style));
  return StoreSheetResult(shown, shown ? options.style.wire : 'none',
      clickId: clickId,
      linkId: linkId,
      matchSaved: matchSaved,
      handoffCopied: handoffCopied,
      reason: shown ? reason : (reason ?? 'not_shown'));
}
