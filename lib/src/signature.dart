/// Strait deferred-match signature — Dart port of shared-spec/RECIPE.md.
///
/// MUST be byte-identical to the JS reference (server + sdk-web + sdk-react-native).
/// The golden vectors in test/signature-vectors.json are the contract; any drift
/// here silently breaks deferred matching. Two cross-language traps handled below:
///   • h32 uses 32-bit SIGNED wraparound (JS `h |= 0`) → `.toSigned(32)`.
///   • numStr mirrors JS `String(Number)` (no trailing ".0" on whole numbers).
library;

class Signature {
  final String coreRaw;
  final String extRaw;
  final String coreHash;
  final String extHash;

  const Signature({
    required this.coreRaw,
    required this.extRaw,
    required this.coreHash,
    required this.extHash,
  });

  Map<String, String> toMap() => {
        'coreRaw': coreRaw,
        'extRaw': extRaw,
        'coreHash': coreHash,
        'extHash': extHash,
      };
}

class SignatureInputs {
  final num screenWidth;
  final num pixelRatio;
  final String language;
  final String ip;
  final String timezone;

  const SignatureInputs({
    required this.screenWidth,
    required this.pixelRatio,
    required this.language,
    required this.ip,
    required this.timezone,
  });
}

const String _platform = 'universal';

const Map<String, String> _regionMap = {
  'Asia/Kolkata': 'IN',
  'Asia/Karachi': 'PK',
  'Asia/Dhaka': 'BD',
  'America/New_York': 'US',
  'America/Chicago': 'US',
  'America/Denver': 'US',
  'America/Los_Angeles': 'US',
  'Europe/London': 'GB',
  'Europe/Paris': 'EU',
  'Europe/Berlin': 'EU',
  'Asia/Singapore': 'SG',
  'Asia/Dubai': 'AE',
  'Australia/Sydney': 'AU',
};

/// Deterministic 32-bit string hash (Java hashCode → abs → hex). Matches the JS
/// `h32` exactly: iterates UTF-16 code units, wraps at 32 bits signed.
String h32(String s) {
  int h = 0;
  for (int i = 0; i < s.length; i++) {
    h = ((h << 5) - h) + s.codeUnitAt(i);
    h = h.toSigned(32); // JS: h |= 0
  }
  return h.abs().toRadixString(16);
}

/// Mirror JS `String(Number)`: whole numbers print without a decimal point.
String numStr(num n) {
  if (n is int) return n.toString();
  final d = n.toDouble();
  if (d.isFinite && d == d.truncateToDouble()) {
    return d.toInt().toString();
  }
  return d.toString();
}

String regionFromTimezone(String timezone) {
  final tz = timezone == 'Asia/Calcutta' ? 'Asia/Kolkata' : timezone;
  return _regionMap[tz] ?? 'XX';
}

Signature computeSignature(SignatureInputs input) {
  final screenWidth = input.screenWidth.round();
  final pixelRatio = input.pixelRatio;
  final rawLang = input.language.isEmpty ? 'en' : input.language;
  final language =
      (rawLang.length <= 2 ? rawLang : rawLang.substring(0, 2)).toLowerCase();
  final ip = input.ip;

  final coreFields = [
    _platform,
    numStr(screenWidth),
    numStr(pixelRatio),
    language,
    ip,
  ];
  final coreRaw = coreFields.join('|');

  final physWidth = ((screenWidth * pixelRatio) / 8).round() * 8;
  final region = regionFromTimezone(input.timezone);
  final extRaw = [...coreFields, numStr(physWidth), region].join('|');

  return Signature(
    coreRaw: coreRaw,
    extRaw: extRaw,
    coreHash: h32(coreRaw),
    extHash: h32(extRaw),
  );
}
