// `doctor()` setup check (contract B23, shared-spec ADR 0002): the same finding
// ids and wording in every Strait SDK. `doctorFindings` is pure;
// `StraitLinks.doctor()` (client.dart) does the one GET.

import 'dart:convert';

/// One setup check. [severity] is `ok`, `warn` or `error`; [fix] is empty for `ok`.
class DoctorFinding {
  final String id;
  final String severity;
  final String title;
  final String fix;

  const DoctorFinding({required this.id, required this.severity, required this.title, required this.fix});

  Map<String, String> toJson() => {'id': id, 'severity': severity, 'title': title, 'fix': fix};

  @override
  bool operator ==(Object other) =>
      other is DoctorFinding && other.id == id && other.severity == severity && other.title == title && other.fix == fix;

  @override
  int get hashCode => Object.hash(id, severity, title, fix);

  @override
  String toString() => 'DoctorFinding${jsonEncode(toJson())}';
}

/// The findings in order; [ok] = no `error` finding.
class DoctorReport {
  final bool ok;
  final List<DoctorFinding> findings;

  const DoctorReport({required this.ok, required this.findings});

  Map<String, dynamic> toJson() => {'ok': ok, 'findings': [for (final f in findings) f.toJson()]};

  @override
  String toString() => 'DoctorReport${jsonEncode(toJson())}';
}

/// What the link host answered for the platform's file. [status] null = the
/// request failed (network).
class DoctorFile {
  final int? status;
  final String? body;
  const DoctorFile(this.status, this.body);
}

/// The endpoint's host when it is an `https://` URL with a host, else null.
String? doctorHost(String endpoint) =>
    RegExp(r'^https://([^/?#\s@]+)(?:[/?#]|$)', caseSensitive: false).firstMatch(endpoint.trim())?.group(1)?.toLowerCase();

/// Upper-case, colon-separated, as assetlinks.json writes it.
String _normFp(String s) {
  final hex = s.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
  return [for (var i = 0; i + 1 < hex.length; i += 2) hex.substring(i, i + 2)].join(':');
}

DoctorFinding _ok(String id, String title) => DoctorFinding(id: id, severity: 'ok', title: title, fix: '');
DoctorFinding _err(String id, String title, String fix) => DoctorFinding(id: id, severity: 'error', title: title, fix: fix);

/// The B23 checks, pure: the key, the endpoint, then (when the endpoint is
/// valid and [file] was fetched) the file and the app identity.
/// [platform] is `android` (assetlinks.json) or `ios`
/// (apple-app-site-association). [appId] = Android package / iOS bundle ID,
/// null when unknown. [certSha256] = this build's signing certificate
/// SHA-256 fingerprint(s), any format (Android only). [file] null = not fetched.
DoctorReport doctorFindings({
  required String publishableKey,
  required String endpoint,
  required String platform,
  String? appId,
  List<String> certSha256 = const [],
  DoctorFile? file,
}) {
  final findings = <DoctorFinding>[];
  if (publishableKey.startsWith('st_pub_')) {
    findings.add(_ok('key.ok', 'Publishable key is set'));
  } else if (publishableKey.startsWith('st_live_') || publishableKey.startsWith('st_test_')) {
    findings.add(_err('key.secret', 'This is a secret key, not the publishable key',
        'Use the publishable key (st_pub_…) from Dashboard → Get started, and revoke this secret key in Dashboard → Settings → Secret keys: it has been inside your app.'));
  } else {
    findings.add(_err('key.invalid', 'Not a publishable key', 'Copy the publishable key (st_pub_…) from Dashboard → Get started.'));
  }

  final host = doctorHost(endpoint);
  if (host == null) {
    findings.add(_err('endpoint.invalid', "The endpoint isn't an https link domain",
        'Set endpoint to your link domain from Dashboard → Get started, e.g. https://<handle>.strait.link.'));
  } else if (file != null) {
    findings.addAll(_hostFindings(platform == 'ios', host, appId, certSha256, file));
  }
  return DoctorReport(ok: !findings.any((f) => f.severity == 'error'), findings: findings);
}

List<DoctorFinding> _hostFindings(bool ios, String host, String? appId, List<String> certSha256, DoctorFile file) {
  if (file.status == null) {
    return [
      _err('host.unreachable', "Can't reach $host",
          'Check that endpoint is your link domain (Dashboard → Get started) and that this device is online.')
    ];
  }
  final apps = file.status == 200 ? _listedApps(ios, file.body) : null;
  if (apps == null) {
    return [
      _err('host.file_missing', "$host doesn't serve ${ios ? 'apple-app-site-association' : 'assetlinks.json'}",
          'Use your Strait link domain as endpoint (Dashboard → Get started); Strait serves this file there.')
    ];
  }
  if (apps.isEmpty) {
    return [_err('app.none', 'No ${ios ? 'iOS' : 'Android'} app is set up for $host', 'Add your app in Dashboard → Apps & stores.')];
  }

  final listed = apps.keys.join(', ');
  final app = appId?.trim() ?? '';
  if (app.isEmpty) {
    return [DoctorFinding(id: 'app.unknown', severity: 'warn', title: '$host lists $listed', fix: 'Make sure your app is one of these.')];
  }
  // iOS can't read its Team ID at runtime: match the bundle ID suffix, show the full appID.
  final match = ios ? apps.keys.where((id) => id.endsWith('.$app')).firstOrNull : (apps.containsKey(app) ? app : null);
  if (match == null) {
    return [_err('app.missing', "$host doesn't list $app", 'Add $app in Dashboard → Apps & stores (listed now: $listed).')];
  }

  final out = [_ok('app.listed', '$host lists $match')];
  final certs = ios ? const <String>[] : certSha256.map(_normFp).where((c) => c.isNotEmpty).toList();
  if (certs.isNotEmpty) {
    final fps = apps[match]!;
    out.add(certs.any(fps.contains)
        ? _ok('cert.listed', "This build's signing certificate is listed")
        : _err('cert.missing', "This build's signing certificate isn't listed for $app",
            'Add ${certs.join(', ')} in Dashboard → Apps & stores. Debug, release and Play App Signing keys each have their own fingerprint.'));
  }
  return out;
}

/// Android: package → fingerprints; iOS: full appIDs (value unused), in file
/// order. Null = not the JSON expected.
Map<String, List<String>>? _listedApps(bool ios, String? body) {
  Object? json;
  try {
    json = jsonDecode(body ?? '');
  } catch (_) {
    return null;
  }
  final apps = <String, List<String>>{};
  if (!ios) {
    if (json is! List) return null;
    for (final s in json) {
      final t = s is Map ? s['target'] : null;
      if (t is! Map || t['namespace'] != 'android_app') continue;
      final pkg = t['package_name'];
      if (pkg is! String) continue;
      final fps = t['sha256_cert_fingerprints'];
      (apps[pkg] ??= []).addAll(fps is List ? fps.whereType<String>().map(_normFp) : const []);
    }
    return apps;
  }
  final applinks = json is Map ? json['applinks'] : null;
  final details = applinks is Map ? applinks['details'] : null;
  if (details is! List) return null;
  for (final d in details) {
    if (d is! Map) continue;
    final many = d['appIDs'];
    for (final id in [if (many is List) ...many, d['appID']]) {
      if (id is String) apps[id] = const [];
    }
  }
  return apps;
}
