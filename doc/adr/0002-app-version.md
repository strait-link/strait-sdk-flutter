# ADR 0002: app and SDK version on open and install reports

Date: 5 Nov 2026 · Status: accepted · Backlog: td2-23 · Engine half built in parallel (fields `appVersion`, `sdkVersion`)

## Problem
When a customer says "links stopped working", support's first question is "which app version?". Today no
open or install row says which build of the app, or of this SDK, sent it.

## Wire (fixed by the engine)
Two optional body fields on the calls that record an open or install: `/v1/open`, `/v1/resolve`, `/v1/referrer`,
`/v1/match`, `/v1/handoff/claim`. Not on `/v1/lookup` (records nothing; the opt-out path) or `/v1/event`.
Engine keeps 1-64 printable ASCII and silently drops anything else.

## Where `appVersion` comes from
This package is pure Dart (no Flutter, no method channel, no native code), so it can't read the platform's
package info itself. The app already hands it everything platform-specific the same way (`installReferrer`,
`deviceClass`, `doctor(appId:)`), so it takes `appVersion: String?` in the `StraitLinks` constructor; the README
shows `PackageInfo.fromPlatform()`.

Options:
1. **Do nothing:** support keeps guessing.
2. **Depend on `package_info_plus`:** makes the package a Flutter plugin (breaks Dart-server use and the
   `dart test` / dart2wasm CI), adds a native dependency to every app for one string. Rejected.
3. **Native code in a plugin channel:** there is no channel; adding one is the same cost as 2.
4. **Constructor value from the app (chosen):** zero dependencies, a few lines, same pattern as the existing inputs.
   Left out = only `sdkVersion` is sent.

`sdkVersion` is the constant `straitSdkVersion` (exported), pinned to pubspec.yaml's `version` by a test, so a
version bump that forgets it fails CI.

## Design
Added in the one HTTP helper for the recording paths, at send time: queued open reports are saved without
them (nothing new stored on the device) and retries carry them. The helper already refuses every call while
opted out, so neither field leaves the device then. The SDK applies the engine rule too (trim, cap 64, ASCII
only, else omit) so a bad value is never sent.

## Security lens
Spoofing: a client can send any version string; it is support metadata, never trusted for decisions. Data
exposure: an app's public version number, no personal data; off with the opt-out. Abuse / DoS: 64-byte cap.

## Architecture lens
Two small fields per recording call; no new state, storage key or dependency.
