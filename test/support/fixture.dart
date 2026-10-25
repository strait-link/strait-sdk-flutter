// Reads a JSON file next to the tests on the VM (dart:io) and in the browser
// (the test runner serves the test folder), so the shared vectors also run
// under `dart test -p chrome` (dart2js and dart2wasm).
export 'fixture_io.dart' if (dart.library.js_interop) 'fixture_web.dart';
