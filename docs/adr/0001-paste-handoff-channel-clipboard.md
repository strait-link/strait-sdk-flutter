# 0001: StraitChannelClipboard, a shipped Paste handoff adapter (B-SDK-06)

Date: 12 Oct 2026. Status: accepted (branch `fix/registry-1012`).

## Problem

Paste handoff (contract B19) asks the clipboard, without the iOS paste prompt, whether
it probably holds a URL, and reads it only if so. This package is pure Dart (no
`flutter` dependency, no plugin code), so every app hand-wrote a `StraitClipboard` and
a native handler from the README. The question must be `detectPatterns(.probableWebURL)`:
the tap page copies the link as plain text, and an iOS 26.5 simulator answers
`hasURLs=false, probableWebURL=true` for that clipboard (probe in
strait-sdk-react-native `test/ios-paste-probe`, ADR 0001 there). Flutter's own
`Clipboard` has only `hasStrings`.

## Options

1. Do nothing: the README already shows a correct native handler. Each app still copies
   a Dart class whose method names must match its Swift by hand.
2. Make the package a Flutter plugin with iOS code: adds a `flutter` dependency and
   native build steps for every user (the package also serves pure Dart). Rejected.
3. Extend what exists (chosen): ship `StraitChannelClipboard(invoke)`, which takes the
   app's `MethodChannel.invokeMethod` and owns the method names (`hasProbableWebUrl`,
   `readText`) the README's Swift answers. Non-bool or missing answers count as "no".
   The README documents a no-native-code `Clipboard.hasStrings()` option and its cost
   (a prompt whenever any text is on the clipboard).

## Security and privacy lens

Unchanged data flow: only a Strait handoff token parsed by `parseHandoffUrl` leaves the
device. A malformed native answer can only make the SDK skip the read (fail closed).

## Architecture and cost

No new dependency, no wire change, one small class plus tests in
`test/clipboard_test.dart`. Real-iPhone check: B-IOS-05.
