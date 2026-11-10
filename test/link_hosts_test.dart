import 'package:strait_sdk/src/core.dart';
import 'package:test/test.dart';

/// normalizeLinkHosts and trimTrailingSlashes scan ASCII instead of using RegExp (no regex work in
/// the StraitLinks constructor, H3). They must give what the regex versions gave: the old code is the oracle.
List<String> oracle(String endpoint, List<String> linkHosts) {
  final out = <String>[];
  final bare = RegExp(r'^[a-z0-9.-]+(:\d+)?$', caseSensitive: false);
  for (final h in [endpoint, ...linkHosts]) {
    final t = h.trim();
    final host = splitUrl(h)?.host ?? (bare.hasMatch(t) ? t.toLowerCase() : null);
    if (host != null && !out.contains(host)) out.add(host);
  }
  return out;
}

void main() {
  const inputs = [
    'https://Acme.strait.link', 'https://acme.strait.link/', ' https://acme.strait.link/x?y#z ', 'HTTPS://A.B',
    'go.brand.com', 'GO.Brand.com', 'localhost:3000', 'localhost:', 'localhost:3000x', ':3000', '',
    '   ', '\n', 'go brand.com', 'go.brand.com/path', 'https://', 'https:///path', 'ftp+x.y-z://h.com:8443/p',
    '1http://a.com', 'http:/a.com', 'http//a.com', 'a://b', 'x-y.z', '_a.com', 'a_b.com', 'https://h?q', 'https://h#f',
    'https://user@h.com', 'https://h.com:99', 'été.com', 'https://été.com', 'a.com:\u0661\u0662', 'a.com::1',
    'https://a.com\n', 'a.com\u0085', '\u212A.com', 'https://a.com//', '///', 'a/',
  ];
  test('normalizeLinkHosts matches the RegExp version', () {
    for (final i in inputs) {
      expect(normalizeLinkHosts(i), oracle(i, const []), reason: 'endpoint ${i.codeUnits}');
      final extra = [i, i.toUpperCase()];
      expect(normalizeLinkHosts('https://e.strait.link', extra), oracle('https://e.strait.link', extra), reason: 'linkHosts ${i.codeUnits}');
    }
  });
  test('trimTrailingSlashes matches the RegExp version', () {
    for (final i in inputs) {
      expect(trimTrailingSlashes(i), i.replaceAll(RegExp(r'/+$'), ''), reason: '${i.codeUnits}');
    }
  });
}
