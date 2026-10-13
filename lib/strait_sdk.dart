/// Deep-linking SDK for Dart and Flutter.
library;

export 'src/signature.dart';
// The conformance helpers in src/core.dart stay internal; tests import them from src/.
export 'src/core.dart' show AppLifecycle, AppStateAtLink, LinkRoute, portraitScreenWidth;
export 'src/client.dart';
export 'src/store_sheet.dart';
export 'src/strait.dart';
